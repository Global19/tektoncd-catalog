#!/usr/bin/env bash
#
# This will runs the E2E tests on OpenShift
#
set -e

# Maximin number of parallel tasks run at the same time
# # start from 0 so 4 => 5
MAX_NUMBERS_OF_PARALLEL_TASKS=4

# This is needed on openshift CI since HOME is read only and if we don't cache,
# it takes over 15s every kubectl query without caching.
KUBECTL_CMD="kubectl --cache-dir=/tmp/cache"

# Give these tests the priviliged rights
PRIVILEGED_TESTS="buildah buildpacks buildpacks-phases jib-gradle kaniko kythe-go s2i"

# Skip those tests when they really can't work in OpenShift
SKIP_TESTS="docker-build orka-full"

# Service Account used for image builder
SERVICE_ACCOUNT=builder

# Pipelines Catalog Repository
PIPELINES_CATALOG_URL=${PIPELINES_CATALOG_URL:-https://github.com/openshift/pipelines-catalog/}
PIPELINES_CATALOG_REF=${PIPELINES_CATALOG_REF:-origin/master}
PIPELINES_CATALOG_DIRECTORY=./openshift/pipelines-catalog
PIPELINES_CATALOG_IGNORE=""
PIPELINES_CATALOG_PRIVILIGED_TASKS="s2i-* buildah-pr"

function check-service-endpoints() {
  service=${1}
  namespace=${2}
  echo "-----------------------"
  echo "checking ${namespace}/${service} service endpoints"
  count=0
  while [[ -z $(${KUBECTL_CMD} get endpoints ${service} -n ${namespace} -o jsonpath='{.subsets}') ]]; do
    # retry for 15 mins
    sleep 10
    if [[ $count -gt 90 ]]; then
      echo ${namespace}/${service} endpoints unavailable
      exit 1
    fi
    echo waiting for ${namespace}/${service} endpoints
    count=$(( count+1 ))
  done
}

# Create some temporary file to work with, we will delete them right after exiting
TMPF2=$(mktemp /tmp/.mm.XXXXXX)
TMPF=$(mktemp /tmp/.mm.XXXXXX)
clean() { rm -f ${TMP} ${TMPF2}; }
trap clean EXIT

source $(dirname $0)/../test/e2e-common.sh
cd $(dirname $(readlink -f $0))/..

# Install CI
[[ -z ${LOCAL_CI_RUN} ]] && install_pipeline_crd

# list tekton-pipelines-webhook service endpoints
check-service-endpoints "tekton-pipelines-webhook" "tekton-pipelines"

CURRENT_TAG=$(git describe --tags 2>/dev/null || true)
if [[ -n ${CURRENT_TAG} ]];then
    PIPELINES_CATALOG_REF=origin/release-$(echo ${CURRENT_TAG}|sed -e 's/.*\(v[0-9]*\.[0-9]*\).*/\1/')
fi

# Add PIPELINES_CATALOG in here so we can do the CI all together.
# We checkout the repo in ${PIPELINES_CATALOG_DIRECTORY}, merge them in the main
# repos and launch the tests.
function pipelines_catalog() {
    local ptest parent parentWithVersion

    [[ -d ${PIPELINES_CATALOG_DIRECTORY} ]] || \
        git clone ${PIPELINES_CATALOG_URL} ${PIPELINES_CATALOG_DIRECTORY}

    pushd ${PIPELINES_CATALOG_DIRECTORY} >/dev/null && \
        git reset --hard ${PIPELINES_CATALOG_REF} &&
        popd >/dev/null

    # NOTE(chmouel): The functions doesnt support argument so we can't just leave the test in
    # ${PIPELINES_CATALOG_DIRECTORY} we need to have it in the top dir, TODO: fix the functions
    for ptest in ${PIPELINES_CATALOG_DIRECTORY}/task/*/*/tests;do
        parent=$(dirname $(dirname ${ptest}))
        base=$(basename ${parent})
        in_array ${base} ${PIPELINES_CATALOG_IGNORE} && { echo "Skipping: ${base}"; continue ;}
        [[ -d ./task/${base} ]] || cp -a ${parent} ./task/${base}

        # TODO(chmouel): Add S2I Images as PRIVILEGED_TESTS, that's not very
        # flexible and we may want to find some better way.
        in_array ${base} ${PIPELINES_CATALOG_PRIVILIGED_TASKS} && \
            PRIVILEGED_TESTS="${PRIVILEGED_TESTS} ${base}"
    done
}

# in_array function: https://www.php.net/manual/en/function.in-array.php :-D
function in_array() {
    param=$1;shift
    for elem in $@;do
        [[ $param == $elem ]] && return 0;
    done
    return 1
}

function test_privileged {
    local cnt=0
    local task_to_tests=""

    # Run the privileged tests
    for runtest in $@;do
        btest=$(basename $(dirname $(dirname $runtest)))
        in_array ${btest} ${SKIP_TESTS} && { echo "Skipping: ${btest}"; continue ;}

        # Add here the pre-apply-taskrun-hook function so we can do our magic to add the serviceAccount on the TaskRuns,
        function pre-apply-taskrun-hook() {
            cp ${TMPF} ${TMPF2}
            python3 openshift/e2e-add-service-account.py ${SERVICE_ACCOUNT} < ${TMPF2} > ${TMPF}
            oc adm policy add-scc-to-user privileged system:serviceaccount:${tns}:${SERVICE_ACCOUNT} || true
        }
        unset -f pre-apply-task-hook || true

        task_to_tests="${task_to_tests} task/${runtest}/*/tests"

        if [[ ${cnt} == "${MAX_NUMBERS_OF_PARALLEL_TASKS}" ]];then
            echo "---"
            echo "Running privileged test: ${task_to_tests}"
            echo "---"

            test_task_creation ${task_to_tests}

            cnt=0
            task_to_tests=""
            continue
        fi

        cnt=$((cnt+1))
    done

    # Remaining task
    if [[ -n ${task_to_tests} ]];then
        echo "---"
        echo "Running privileged test: ${task_to_tests}"
        echo "---"

        test_task_creation ${task_to_tests}
    fi
}

function test_non_privileged {
    local cnt=0
    local task_to_tests=""

    # Run the non privileged tests
    for runtest in $@;do
        btest=$(basename $(dirname $(dirname $runtest)))
        in_array ${btest} ${SKIP_TESTS} && { echo "Skipping: ${btest}"; continue ;}
        in_array ${btest} ${PRIVILEGED_TESTS} && continue # We did them previously

        # Make sure the functions are not set anymore here or this will get run.
        unset -f pre-apply-taskrun-hook || true
        unset -f pre-apply-task-hook || true

        task_to_tests="${task_to_tests} ${runtest}"

        if [[ ${cnt} == "${MAX_NUMBERS_OF_PARALLEL_TASKS}" ]];then
            echo "---"
            echo "Running non privileged test: ${task_to_tests}"
            echo "---"

            test_task_creation ${task_to_tests}

            cnt=0
            task_to_tests=""
            continue
        fi

        cnt=$((cnt+1))
    done

    # Remaining task
    if [[ -n ${task_to_tests} ]];then
        echo "---"
        echo "Running non privileged test: ${task_to_tests}"
        echo "---"

        test_task_creation ${task_to_tests}
    fi
}

# Checkout Pipelines Catalog and test
pipelines_catalog

# Test if yamls can install
until test_yaml_can_install; do
  echo "-----------------------"
  echo 'retry test_yaml_can_install'
  echo "-----------------------"
  sleep 5
done
test_non_privileged $(\ls -1 -d task/*/*/tests)
test_privileged ${PRIVILEGED_TESTS}

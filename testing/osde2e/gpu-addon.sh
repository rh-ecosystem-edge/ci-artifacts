#!/bin/sh

if ! [[ -d  $ARTIFACT_DIR ]] ; then
    echo "FATAL: osde2e tests requires '/test-run-results' to exist"
    exit 1
fi

JUNIT_DIR=/test-run-results

BURN_RUNTIME_SEC=600

JUNIT_HEADER_TEMPLATE='<?xml version="1.0" encoding="utf-8"?>
<testsuite errors="NUM_ERRORS" failures="NUM_ERRORS" name="TEST_TARGET_SHORT" tests="1" time="RUNTIME" timestamp="TIMESTAMP">
    <testcase name="TEST_TARGET_SHORT" time="RUNTIME">
        <CASE_OUTPUT_TAG>
'

JUNIT_FOOTER_TEMPLATE='
        </CASE_OUTPUT_TAG>
    </testcase>
</testsuite>
'

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $THIS_DIR/../prow/gpu-operator.sh source

function exit_and_abort() {
    echo "====== Test failed. Aborting."
    must_gather
    tar_artifacts
    exit 1
}

function run_test() {
    TARGET=${1:-}
    TARGET_SHORT=$(echo $TARGET | awk '{print $1"_"$2}')
    echo "====== Running toolbox '$TARGET_SHORT'"
    # Make sure a new junit is generated for this run
    export FILE_POSTFIX=0
    JUNIT_FILE_NAME=$(echo $TARGET | awk -v target=$TARGET_SHORT '{print "junit_"target}')
    JUNIT_FILE="${JUNIT_DIR}/${JUNIT_FILE_NAME}_${FILE_POSTFIX}.xml"
    while [ -f $JUNIT_FILE ]; do
        FILE_POSTFIX=$((FILE_POSTFIX + 1))
        JUNIT_FILE="${JUNIT_DIR}/${JUNIT_FILE_NAME}_${FILE_POSTFIX}.xml"
    done
    echo "====== JUnit report for '$TARGET_SHORT' -> ${JUNIT_FILE}"
    RUNTIME_FILE="${JUNIT_DIR}/runtime"
    OUTPUT_FILE="${JUNIT_DIR}/output"

    trap trap_run_test EXIT

    cat > ${JUNIT_FILE} <<EOF
$JUNIT_HEADER_TEMPLATE
EOF

    /usr/bin/time -o ${RUNTIME_FILE} ./run_toolbox.py ${TARGET} > $OUTPUT_FILE

    trap_run_test
}

function trap_run_test() {
    finalize_junit
    must_gather
    tar_artifacts
}

function must_gather() {
    echo "====== Running must gather"
    collect_must_gather
    echo "====== Done must gather"
}

function finalize_junit() {
    STATUS=$?

    trap - EXIT

    cat $OUTPUT_FILE

    echo "====== Finalizing JUnit report"

    # Replace '<' and '>' with '**' in output so it won't break the XML
    sed  -i 's/[<>]/\*\*/g' $OUTPUT_FILE
    # Replace '&' with '@' output so it won't break the XML
    sed  -i 's/[&]/@/g' $OUTPUT_FILE
    set -x
    RUNTIME="$(cat ${RUNTIME_FILE} | egrep -o '[0-9:.]+elapsed' | sed 's/elapsed//')"

    sed -i "s/RUNTIME/${RUNTIME}/g" "${JUNIT_FILE}"
    sed -i "s/TEST_TARGET_SHORT/${TARGET_SHORT}/g" "${JUNIT_FILE}"
    sed -i "s/TIMESTAMP/$(date -Is)/g" "${JUNIT_FILE}"

    cat $OUTPUT_FILE >> $JUNIT_FILE
    cat >> "${JUNIT_FILE}" <<EOF  
    $JUNIT_FOOTER_TEMPLATE
EOF

    rm -rf ${RUNTIME_FILE}
    rm -rf ${OUTPUT_FILE}

    set +x
    if [[ $STATUS == 0 ]]; then
        sed -i 's/NUM_ERRORS/0/g' "${JUNIT_FILE}"
        sed -i 's/CASE_OUTPUT_TAG/system-out/g' "${JUNIT_FILE}"
    else
        sed -i 's/NUM_ERRORS/1/g' "${JUNIT_FILE}"
        sed -i 's/CASE_OUTPUT_TAG/failure/g' "${JUNIT_FILE}"
        exit_and_abort
    fi
}

function tar_artifacts() {
    TARBALL_TMP="${JUNIT_DIR}/ci-artifacts.tar.gz"
    TARBALL="${ARTIFACT_DIR}/ci-artifacts.tar.gz"
    echo "====== Archiving ci-artifacts..."
    tar -czf ${TARBALL_TMP} ${ARTIFACT_DIR}
    mv $TARBALL_TMP $TARBALL
    echo "====== Archive Done."
}

echo "====== Starting OSDE2E tests..."

echo "Using ARTIFACT_DIR=$ARTIFACT_DIR."
echo "Using JUNIT_DIR=$JUNIT_DIR"
CLUSTER_ID=$(oc get secrets ci-secrets -n osde2e-ci-secrets -o json | jq -r '.data|.["CLUSTER_ID"]' | base64 -d)
echo "CLUSTER_ID=${CLUSTER_ID:-}"
OCM_ENV=$(oc get secrets ci-secrets -n osde2e-ci-secrets -o json | jq -r '.data|.["ENV"]' | base64 -d)
echo "OCM_ENV=${OCM_ENV:-}"

OCM_REFRESH_TOKEN=$(oc get secrets ci-secrets -n osde2e-ci-secrets -o json | jq -r '.data|.["ocm-token-refresh"]' | base64 -d)
echo "OCM_REFRESH_TOKEN=$(echo ${OCM_REFRESH_TOKEN} | cut -c1-6)...."

echo "====== Installing RHODS"
run_test "ocm_addon install --ocm_addon_id=managed-odh --ocm_refresh_token=${OCM_REFRESH_TOKEN} --ocm_url=${OCM_ENV} --ocm_cluster_id=${CLUSTER_ID} --wait_for_ready_state=True"

echo "===== Installing GPU AddOn"
run_test "ocm_addon install --ocm_addon_id=gpu-operator-certified-addon --ocm_refresh_token=${OCM_REFRESH_TOKEN} --ocm_url=${OCM_ENV} --ocm_cluster_id=${CLUSTER_ID}"

echo "====== Waiting for gpu-operator..."
run_test "gpu_operator wait_deployment"
echo "====== Operator found."

echo "====== Running burn test for $((BURN_RUNTIME_SEC/60)) minutes ..."
run_test "gpu_operator run_gpu_burn --runtime=${BURN_RUNTIME_SEC}"

must_gather
tar_artifacts
echo "====== Finished all jobs."

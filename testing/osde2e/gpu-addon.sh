#!/bin/sh

if ! [[ -d  $ARTIFACT_DIR ]] ; then
    echo "FATAL: osde2e tests requires '/test-run-results' to exist"
    exit 1
fi

JUNIT_DIR=/test-run-results

ADDON_NAMESPACE=redhat-nvidia-gpu-addon

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

JUNIT_MUST_GATHER_PRINTF_TEMPLATE='<?xml version="1.0" encoding="utf-8"?>
<testsuite failures="%d" name="gpu_addon_must_gather" tests="1" timestamp="%s">
    <testcase name="must_gather" time="%s">
        %s
    </testcase>
</testsuite>'

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $THIS_DIR/../prow/gpu-operator.sh source

function exit_and_abort() {
    echo "====== Test failed. Aborting."
    must_gather
    addon_must_gather
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
}

function must_gather() {
    echo "====== Running must gather"
    collect_must_gather
    echo "====== Done must gather"
}

function report_must_gather_junit() {
    # https://llg.cubic.org/docs/junit/
    if [[ $1 == 0 ]]; then
        failures=0
        output="<system-out>${2}</system-out>"
    else
        failures=1
        output="<failure>${2}</failure>"
    fi

    time="$3"
    timestamp=$(date --iso-8601=seconds)
    printf "$JUNIT_MUST_GATHER_PRINTF_TEMPLATE" "$failures" "$timestamp" "$time" "$output" > "${JUNIT_DIR}/junit_must_gather_0.xml"
}

function addon_must_gather() {

    start=$SECONDS
    echo "Running the GPU Add-on must-gather"

    addon_csv=$(oc get csv -n $ADDON_NAMESPACE -o name | grep nvidia-gpu-addon || true)
    addon_must_gather_image=$(oc get "$addon_csv" -n $ADDON_NAMESPACE -o jsonpath='{.spec.relatedImages[?(@.name == "must-gather")].image}' --ignore-not-found || true)

    if [[ ! "$addon_must_gather_image" ]]; then
        report_must_gather_junit 1 "Failed to find a GPU Add-on must-gather image" "$(($SECONDS - start))s"
        return
    fi

    tmp_dir="$(mktemp -d -t gpu-addon_XXXX)"

    echo "Add-on must-gather image: $addon_must_gather_image"
    oc adm must-gather --image="$addon_must_gather_image" --dest-dir="${tmp_dir}" &> /dev/null

    if [[ "$(ls "${tmp_dir}"/*/* 2>/dev/null | wc -l)" == 0 ]]; then
        report_must_gather_junit 1 "GPU add-on must-gather image failed to must-gather anything" "$(($SECONDS - start))s"
        return
    fi

    img_dirname=$(dirname "$(ls "${tmp_dir}"/*/* | head -1)")
    mv "$img_dirname"/* "$tmp_dir"
    rmdir "$img_dirname"

    expected_files=(
        "cluster-scoped-resources/console.openshift.io/consoleplugins/"
        "cluster-scoped-resources/operators.coreos.com/operators/"
        "namespaces/redhat-nvidia-gpu-addon/monitoring.coreos.com/prometheuses/"
        "namespaces/redhat-nvidia-gpu-addon/nfd.openshift.io/nodefeaturediscoveries/"
        "namespaces/redhat-nvidia-gpu-addon/nvidia.addons.rh-ecosystem-edge.io/gpuaddons/"
        "namespaces/redhat-nvidia-gpu-addon/operators.coreos.com/catalogsources/"
        "namespaces/redhat-nvidia-gpu-addon/operators.coreos.com/subscriptions/"
        "namespaces/redhat-nvidia-gpu-addon/pods/"
        "namespaces/redhat-nvidia-gpu-addon/redhat-nvidia-gpu-addon.yaml"
    )

    missing_files=()
    for file in "${expected_files[@]}"
    do
        if [[ "$(ls -1 "$tmp_dir/$file" 2>/dev/null | wc -l)" == 0 ]]; then
            missing_files+=("$file")
        fi
    done

    if [[ ${#missing_files[@]}  != 0 ]]; then
        missing_files_text=$(IFS=, ; echo "${missing_files[*]}")
        report_must_gather_junit 1 "Not found or empty: $missing_files_text" "$(($SECONDS - start))s"
    else
        report_must_gather_junit 0 "Success. Found all expected files. Must-gather image: $addon_must_gather_image" "$(($SECONDS - start))s"
    fi

    echo "Copying add-on must-gather results to ${ARTIFACT_DIR}..."
    mv "$tmp_dir"/* "$ARTIFACT_DIR"

    rmdir "$tmp_dir"
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

ocm login --token=${OCM_REFRESH_TOKEN} --url=${OCM_ENV}


################
# OSDE2E env specific workarounds
################

if [[ ${OCM_ENV} != "prod" ]]; then # (int)egration / (stage)ing
    echo "====== Skipping RHODS install"
else
    echo "====== Installing RHODS"
    run_test "ocm_addon install --ocm_addon_id=managed-odh --ocm_url=${OCM_ENV} --ocm_cluster_id=${CLUSTER_ID} --ocm_addon_params='[{\"id\":\"notification-email\",\"value\":\"example@example.com\"}]' --wait_for_ready_state=True"
fi

##### End - Should be removed and updated once RHODS is not required.

echo "===== Installing GPU AddOn"
run_test "ocm_addon install --ocm_addon_id=nvidia-gpu-addon --ocm_url=${OCM_ENV} --ocm_cluster_id=${CLUSTER_ID} --wait_for_ready_state=False"


# Wait for NFD labels
echo "====== Waiting for NFD labels..."
run_test "nfd wait_labels"
echo "====== NFD labels found."


echo "====== Waiting for gpu-operator..."
run_test "gpu_operator wait_deployment"
echo "====== Operator found."

echo "====== Running burn test for $((BURN_RUNTIME_SEC/60)) minutes ..."
run_test "gpu_operator run_gpu_burn --runtime=${BURN_RUNTIME_SEC}"

must_gather
addon_must_gather
tar_artifacts
echo "====== Finished all jobs."

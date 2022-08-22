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
    must_gather
    addon_must_gather
    tar_artifacts
}

function must_gather() {
    echo "====== Running must gather"
    collect_must_gather
    echo "====== Done must gather"
}

function addon_must_gather() {
    run_in_sub_shell() {
        echo "Running the GPU Add-on must-gather image ..."
        ADDON_NAMESPACE=redhat-nvidia-gpu-addon
        ADDON_CSV=$(oc get csv -n $ADDON_NAMESPACE -o custom-columns=NAME:.metadata.name --no-headers | grep nvidia-gpu-addon 2> /dev/null || true)
        MUST_GATHER_IMAGE=$(oc get csv $ADDON_CSV -n $ADDON_NAMESPACE -o jsonpath='{.spec.relatedImages[?(@.name == "must-gather")].image}' --ignore-not-found)

        TMP_DIR="$(mktemp -d -t gpu-addon_XXXX)"

        if [[ "$MUST_GATHER_IMAGE" ]]; then
            echo "Add-on must-gather image: $MUST_GATHER_IMAGE"

            oc adm must-gather --image="$MUST_GATHER_IMAGE" --dest-dir="${TMP_DIR}" &> /dev/null

            # TODO: Verify the must-gather script collects at least the following files/resources (???):
            # - directory that corresponds to the must-gather image
            # │   ├── cluster-scoped-resources
            # │   │   ├── console.openshift.io
            # │   │   │   └── consoleplugins
            # │   │   │       └── console-plugin-nvidia-gpu.yaml
            # │   │   └── operators.coreos.com
            # │   │       └── operators
            # │   │           ├── gpu-operator-certified.redhat-nvidia-gpu-addon.yaml
            # │   │           ├── nvidia-gpu-addon-operator.redhat-nvidia-gpu-addon.yaml
            # │   │           ├── ose-nfd.redhat-nvidia-gpu-addon.yaml
            # │   │           └── ose-prometheus-operator.redhat-nvidia-gpu-addon.yaml
            # │   ├── namespaces
            # │   │   └── redhat-nvidia-gpu-addon
            # │   │       ├── apps
            # │   │       │   ├── daemonsets.yaml
            # │   │       │   ├── deployments.yaml
            # │   │       │   ├── replicasets.yaml
            # │   │       │   └── statefulsets.yaml
            # │   │       ├── apps.openshift.io
            # │   │       │   └── deploymentconfigs.yaml
            # │   │       ├── autoscaling
            # │   │       │   └── horizontalpodautoscalers.yaml
            # │   │       ├── batch
            # │   │       │   ├── cronjobs.yaml
            # │   │       │   └── jobs.yaml
            # │   │       ├── build.openshift.io
            # │   │       │   ├── buildconfigs.yaml
            # │   │       │   └── builds.yaml
            # │   │       ├── core
            # │   │       │   ├── configmaps.yaml
            # │   │       │   ├── endpoints.yaml
            # │   │       │   ├── events.yaml
            # │   │       │   ├── persistentvolumeclaims.yaml
            # │   │       │   ├── pods.yaml
            # │   │       │   ├── replicationcontrollers.yaml
            # │   │       │   ├── secrets.yaml
            # │   │       │   └── services.yaml
            # │   │       ├── discovery.k8s.io
            # │   │       │   └── endpointslices.yaml
            # │   │       ├── image.openshift.io
            # │   │       │   └── imagestreams.yaml
            # │   │       ├── monitoring.coreos.com
            # │   │       │   └── prometheuses
            # │   │       │       └── gpuaddon-prometheus.yaml
            # │   │       ├── networking.k8s.io
            # │   │       │   └── networkpolicies.yaml
            # │   │       ├── nfd.openshift.io
            # │   │       │   └── nodefeaturediscoveries
            # │   │       │       └── ocp-gpu-addon.yaml
            # │   │       ├── nvidia.addons.rh-ecosystem-edge.io
            # │   │       │   └── gpuaddons
            # │   │       │       └── nvidia-gpu-addon.yaml
            # │   │       ├── operators.coreos.com
            # │   │       │   ├── catalogsources
            # │   │       │   │   └── addon-nvidia-gpu-addon-catalog.yaml
            # │   │       │   └── subscriptions
            # │   │       │       ├── gpu-operator-certified.yaml
            # │   │       │       ├── nvidia-gpu-addon-operator.yaml
            # │   │       │       ├── ose-nfd-stable-addon-nvidia-gpu-addon-catalog-redhat-nvidia-gpu-addon.yaml
            # │   │       │       └── ose-prometheus-operator-beta-addon-nvidia-gpu-addon-catalog-redhat-nvidia-gpu-addon.yaml
            # │   │       ├── pods
            # │   │       │   ├── addon-nvidia-gpu-addon-catalog-XXXX
            # │   │       │   ├── alertmanager-gpuaddon-alertmanager-XXXX
            # │   │       │   ├── console-plugin-nvidia-gpu-XXXX
            # │   │       │   ├── controller-manager-XXXX
            # │   │       │   ├── gpu-feature-discovery-XXXX
            # │   │       │   ├── gpu-operator-XXXX
            # │   │       │   ├── nfd-controller-manager-XXXX
            # │   │       │   ├── nfd-master-XXXX
            # │   │       │   ├── nfd-worker-XXXX
            # │   │       │   ├── nvidia-container-toolkit-daemonset-XXXX
            # │   │       │   ├── nvidia-cuda-validator-XXXX
            # │   │       │   ├── nvidia-dcgm-exporter-XXXX
            # │   │       │   ├── nvidia-dcgm-XXXX
            # │   │       │   ├── nvidia-device-plugin-daemonset-XXXX
            # │   │       │   ├── nvidia-device-plugin-validator-XXXX
            # │   │       │   ├── nvidia-driver-daemonset-XXXX
            # │   │       │   ├── nvidia-node-status-exporter-XXXX
            # │   │       │   ├── nvidia-operator-validator-XXXX
            # │   │       │   ├── prometheus-gpuaddon-prometheus-XXXX
            # │   │       │   └── prometheus-operator-XXXX
            # │   │       ├── policy
            # │   │       │   └── poddisruptionbudgets.yaml
            # │   │       ├── redhat-nvidia-gpu-addon.yaml
            # │   │       └── route.openshift.io
            # │   │           └── routes.yaml

            if [[ "$(ls "${TMP_DIR}"/*/* 2>/dev/null | wc -l)" == 0 ]]; then
                echo "GPU add-on must-gather image failed to must-gather anything ..."
            else
                img_dirname=$(dirname "$(ls "${TMP_DIR}"/*/* | head -1)")
                mv "$img_dirname"/* $TMP_DIR
                rmdir "$img_dirname"

                # extract ARTIFACT_EXTRA_LOGS_DIR from 'source toolbox/_common.sh' without sourcing it directly
                export TOOLBOX_SCRIPT_NAME=toolbox/gpu-operator/must-gather.sh
                COMMON_SH=$(source toolbox/_common.sh;
                            echo "8<--8<--8<--";
                            # only evaluate these variables from _common.sh
                            env | egrep "(^ARTIFACT_EXTRA_LOGS_DIR=)"
                         )
                ENV=$(echo "$COMMON_SH" | sed '0,/8<--8<--8<--/d') # keep only what's after the 8<--
                eval $ENV

                echo "Copying add-on must-gather results to $ARTIFACT_EXTRA_LOGS_DIR ..."
                cp -r "$TMP_DIR"/* "$ARTIFACT_EXTRA_LOGS_DIR"

                rmdir "$TMP_DIR"
            fi
        else
            echo "Failed to find the GPU Add-on must-gather image ..."
        fi
    }

    # run the function above in a subshell to avoid polluting the local `env`.
    typeset -fx run_in_sub_shell
    bash -c run_in_sub_shell
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

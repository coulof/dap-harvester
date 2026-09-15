#!/usr/bin/env bash
#
# teardown.sh — Clean up nested Harvester E2E test resources on hosting Harvester
#
set -euo pipefail

KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/op-prg2-harvester.yaml}"
NAMESPACE="florian"
VM_NAME="${1:-test-harvester-sample-01}"
IMAGE_NAME="${2:-e2e-test-iso}"

echo "[+] Cleaning up E2E test resources in namespace '$NAMESPACE'..."

if kubectl --kubeconfig "$KUBECONFIG_HOST" get vm "$VM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "    Deleting VM '$VM_NAME'..."
    kubectl --kubeconfig "$KUBECONFIG_HOST" delete vm "$VM_NAME" -n "$NAMESPACE" --wait=true
fi

for pvc in "${VM_NAME}-disk-0" "${VM_NAME}-disk-1"; do
    if kubectl --kubeconfig "$KUBECONFIG_HOST" get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "    Deleting PVC '$pvc'..."
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete pvc "$pvc" -n "$NAMESPACE" --wait=true || true
    fi
done

if [[ "${CLEAN_IMAGE:-false}" == "true" ]]; then
    if kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "    Deleting VirtualMachineImage '$IMAGE_NAME'..."
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" --wait=true || true
    fi
fi

echo "[✓] Teardown complete."

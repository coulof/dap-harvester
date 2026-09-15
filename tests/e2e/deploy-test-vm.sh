#!/usr/bin/env bash
#
# deploy-test-vm.sh — Deploy a nested Harvester sample node on hosting Harvester
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/op-prg2-harvester.yaml}"
NAMESPACE="florian"
VM_NAME="${1:-test-harvester-sample-01}"
IMAGE_NAME="${2:-e2e-test-iso}"
NETWORK_NAME="harvester-public/vlan2179-public"

if [[ ! -f "$KUBECONFIG_HOST" ]]; then
    echo "[-] Error: Kubeconfig '$KUBECONFIG_HOST' not found." >&2
    exit 1
fi

echo "[+] Step 1: Checking VirtualMachineImage '$IMAGE_NAME' in namespace '$NAMESPACE'..."
IMAGE_SC=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.storageClassName}' 2>/dev/null || echo "")

if [[ -z "$IMAGE_SC" ]]; then
    echo "[-] Error: VirtualMachineImage '$IMAGE_NAME' not found or not imported in $NAMESPACE." >&2
    echo "    Please run upload-image.sh first." >&2
    exit 1
fi

echo "    Image StorageClass: $IMAGE_SC"

# Check if VM already exists
if kubectl --kubeconfig "$KUBECONFIG_HOST" get vm "$VM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "[!] Existing VM '$VM_NAME' found. Deleting for clean test run..."
    kubectl --kubeconfig "$KUBECONFIG_HOST" delete vm "$VM_NAME" -n "$NAMESPACE" --wait=true
    sleep 5
fi

# Clean any existing PVCs for this VM
for pvc in "${VM_NAME}-disk-0" "${VM_NAME}-disk-1"; do
    if kubectl --kubeconfig "$KUBECONFIG_HOST" get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete pvc "$pvc" -n "$NAMESPACE" --wait=true || true
    fi
done

echo "[+] Step 2: Creating VirtualMachine manifest for '$VM_NAME'..."
cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
  labels:
    harvesterhci.io/creator: harvester
    harvesterhci.io/os: linux
  annotations:
    harvesterhci.io/vmRunStrategy: RerunOnFailure
    harvesterhci.io/volumeClaimTemplates: '[{"metadata":{"name":"${VM_NAME}-disk-0","annotations":{"harvesterhci.io/imageId":"${NAMESPACE}/${IMAGE_NAME}"}},"spec":{"accessModes":["ReadWriteMany"],"resources":{"requests":{"storage":"8Gi"}},"volumeMode":"Block","storageClassName":"${IMAGE_SC}"}},{"metadata":{"name":"${VM_NAME}-disk-1"},"spec":{"accessModes":["ReadWriteMany"],"resources":{"requests":{"storage":"150Gi"}},"volumeMode":"Block","storageClassName":"harvester-longhorn"}}]'
spec:
  runStrategy: RerunOnFailure
  template:
    metadata:
      labels:
        harvesterhci.io/vmName: ${VM_NAME}
    spec:
      architecture: amd64
      domain:
        cpu:
          cores: 8
          sockets: 1
          threads: 1
          model: host-passthrough
        memory:
          guest: 24Gi
        resources:
          limits:
            cpu: "8"
            memory: 24Gi
          requests:
            cpu: "1"
            memory: 16Gi
        machine:
          type: q35
        firmware:
          bootloader:
            efi:
              secureBoot: false
        features:
          acpi:
            enabled: true
        devices:
          disks:
          - name: rootdisk
            bootOrder: 1
            disk:
              bus: virtio
          - name: cdrom-iso
            bootOrder: 2
            cdrom:
              bus: sata
          interfaces:
          - name: default
            model: virtio
            bridge: {}
          inputs:
          - name: tablet
            type: tablet
            bus: usb
      networks:
      - name: default
        multus:
          networkName: ${NETWORK_NAME}
      volumes:
      - name: cdrom-iso
        persistentVolumeClaim:
          claimName: ${VM_NAME}-disk-0
      - name: rootdisk
        persistentVolumeClaim:
          claimName: ${VM_NAME}-disk-1
      terminationGracePeriodSeconds: 120
EOF

echo "[+] Step 3: Waiting for VirtualMachineInstance '$VM_NAME' to enter Running phase..."
for i in {1..60}; do
    PHASE=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Running" ]]; then
        VMI_NODE=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')
        echo "[✓] VirtualMachineInstance '$VM_NAME' is Running on node '$VMI_NODE'."
        echo "    The nested VM is booting from ISO and executing unattended installation."
        exit 0
    fi
    echo "    Waiting for VMI... current phase: '${PHASE:-Pending}' (attempt $i/60)"
    sleep 5
done

echo "[-] Error: Timeout waiting for VMI to become Running." >&2
exit 1

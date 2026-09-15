#!/usr/bin/env bash
#
# upload-image.sh — Register and upload remastered Harvester ISO to hosting Harvester
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/op-prg2-harvester.yaml}"
NAMESPACE="florian"
IMAGE_NAME="${1:-e2e-test-iso}"
ISO_PATH="${2:-$SCRIPT_DIR/harvester-v1.8.2-e2e-create.iso}"

if [[ ! -f "$ISO_PATH" ]]; then
    echo "[-] Error: ISO file '$ISO_PATH' not found." >&2
    exit 1
fi

if [[ ! -f "$KUBECONFIG_HOST" ]]; then
    echo "[-] Error: Kubeconfig '$KUBECONFIG_HOST' not found." >&2
    exit 1
fi

echo "[+] Step 1: Checking credentials for hosting Harvester..."
CURRENT_CTX=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config current-context)
CLUSTER_NAME=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.contexts[?(@.name=='$CURRENT_CTX')].context.cluster}")
USER_NAME=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.contexts[?(@.name=='$CURRENT_CTX')].context.user}")
TOKEN=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.users[?(@.name=='$USER_NAME')].user.token}")
SERVER_URL=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}")

if [[ -z "$TOKEN" ]] || [[ -z "$SERVER_URL" ]]; then
    echo "[-] Error: Failed to extract server URL or token from $KUBECONFIG_HOST" >&2
    exit 1
fi

echo "    Host Server: $SERVER_URL"
echo "    Namespace:   $NAMESPACE"
echo "    Image Name:  $IMAGE_NAME"

# Calculate file size in bytes
FILE_SIZE=$(stat -f %z "$ISO_PATH" 2>/dev/null || stat -c %s "$ISO_PATH")
echo "    File Size:   ${FILE_SIZE} bytes"

# Check if image already exists
if kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    STATUS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Imported")].status}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "True" ]]; then
        STORAGE_CLASS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.storageClassName}')
        echo "[✓] Image '$IMAGE_NAME' is already imported in $NAMESPACE (StorageClass: $STORAGE_CLASS)."
        exit 0
    else
        echo "[!] Existing image found in unready state. Deleting..."
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" --wait=true
        sleep 5
    fi
fi

echo "[+] Step 2: Creating VirtualMachineImage CR in namespace $NAMESPACE..."
cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ${IMAGE_NAME}
  namespace: ${NAMESPACE}
  labels:
    harvesterhci.io/image-type: iso
spec:
  displayName: ${IMAGE_NAME}.iso
  sourceType: upload
  targetStorageClassName: harvester-longhorn
  storageClassParameters:
    numberOfReplicas: "3"
    staleReplicaTimeout: "30"
    migratable: "true"
EOF

# Wait for Harvester to initialize backing image data source
echo "[+] Step 3: Waiting for upload endpoint initialization..."
sleep 10

UPLOAD_URL="${SERVER_URL}/v1/harvester/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${IMAGE_NAME}?action=upload&size=${FILE_SIZE}"

echo "[+] Step 4: Streaming ISO upload to Harvester API ($ISO_PATH)..."
echo "    Endpoint: $UPLOAD_URL"
curl -k -f --http1.1 --progress-bar \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "chunk=@${ISO_PATH}" \
    "${UPLOAD_URL}"

echo ""
echo "[+] Step 5: Waiting for image to be imported into Longhorn storage..."
for i in {1..60}; do
    STATUS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Imported")].status}' 2>/dev/null || echo "")
    PROGRESS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.progress}' 2>/dev/null || echo "0")
    if [[ "$STATUS" == "True" ]]; then
        STORAGE_CLASS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.storageClassName}')
        echo "[✓] VirtualMachineImage '$IMAGE_NAME' successfully imported!"
        echo "    StorageClass: $STORAGE_CLASS"
        exit 0
    fi
    echo "    Import progress: ${PROGRESS}%... (attempt $i/60)"
    sleep 5
done

echo "[-] Error: Timeout waiting for image to be imported." >&2
exit 1

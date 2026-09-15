#!/usr/bin/env bash
#
# remote-build-and-upload.sh — Build and upload remastered Harvester ISO directly on hosting Harvester
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECONFIG_HOST="${KUBECONFIG:-$HOME/.kube/op-prg2-harvester.yaml}"
NAMESPACE="florian"
IMAGE_NAME="${1:-e2e-test-iso}"
CONFIG_NAME="${2:-config-test-create.yaml}"
MODE="${3:-create}"
BUILDER_POD="e2e-iso-builder"
UPLOADER_POD="e2e-iso-uploader"

CURRENT_CTX=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config current-context)
CLUSTER_NAME=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.contexts[?(@.name=='$CURRENT_CTX')].context.cluster}")
USER_NAME=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.contexts[?(@.name=='$CURRENT_CTX')].context.user}")
TOKEN=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.users[?(@.name=='$USER_NAME')].user.token}")
SERVER_URL=$(kubectl --kubeconfig "$KUBECONFIG_HOST" config view --raw -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}")

echo "[+] Step 1: Syncing scripts and configs to hosting Harvester (namespace: $NAMESPACE)..."
kubectl --kubeconfig "$KUBECONFIG_HOST" create configmap e2e-scripts -n "$NAMESPACE" \
  --from-file=remaster-iso.sh="$REPO_ROOT/provisioning/vmedia/remaster-iso.sh" \
  --from-file=config-test-create.yaml="$SCRIPT_DIR/config-test-create.yaml" \
  --from-file=config-test-join.yaml="$SCRIPT_DIR/config-test-join.yaml" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -

echo "[+] Step 2: Ensuring build workspace PVC exists..."
cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: e2e-build-workspace
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 30Gi
  storageClassName: harvester-longhorn
EOF

# Check if builder pod already succeeded
BUILDER_PHASE=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get pod "$BUILDER_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$BUILDER_PHASE" != "Succeeded" ]]; then
  # Clean up any stale pods
  kubectl --kubeconfig "$KUBECONFIG_HOST" delete pod "$BUILDER_POD" "$UPLOADER_POD" -n "$NAMESPACE" --now >/dev/null 2>&1 || true

  echo "[+] Step 3: Launching in-cluster ISO builder pod ($BUILDER_POD)..."
  cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${BUILDER_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  volumes:
  - name: workspace
    persistentVolumeClaim:
      claimName: e2e-build-workspace
  - name: scripts
    configMap:
      name: e2e-scripts
      defaultMode: 0755
  containers:
  - name: builder
    image: registry.suse.com/bci/bci-base:latest
    command:
    - /bin/bash
    - -c
    - |
      set -eo pipefail
      echo "[1/4] Installing native tools (xorriso, mtools, dosfstools, go, git, curl, gawk, wget)..."
      zypper in -y --no-recommends xorriso mtools dosfstools go git curl gawk wget

      echo "[2/4] Setting up harvester-cmdline Go binary..."
      if [ ! -f /workspace/bin/harvester-cmdline ]; then
        mkdir -p /workspace/bin
        rm -rf /workspace/tmp-remaster
        git clone https://github.com/coulof/harvester-iso-remaster.git /workspace/tmp-remaster
        (cd /workspace/tmp-remaster && go build -mod=vendor -o /workspace/bin/harvester-cmdline ./cmd/harvester-cmdline)
        rm -rf /workspace/tmp-remaster
      fi
      cp /workspace/bin/harvester-cmdline /usr/local/bin/harvester-cmdline
      chmod +x /usr/local/bin/harvester-cmdline

      echo "[3/4] Checking source Harvester ISO..."
      mkdir -p /workspace/tmp
      rm -rf /workspace/tmp/*
      find /workspace -maxdepth 1 -name "harvester-v1.8.2-*.iso" ! -name "harvester-v1.8.2-amd64.iso" -delete
      ISO_SIZE=\$(stat -c %s /workspace/harvester-v1.8.2-amd64.iso 2>/dev/null || echo "0")
      if [ "\$ISO_SIZE" -lt 8000000000 ]; then
        echo "      Source ISO missing or incomplete (\${ISO_SIZE} bytes). Downloading official v1.8.2 ISO via wget..."
        rm -f /workspace/harvester-v1.8.2-amd64.iso
        wget --tries=5 --timeout=30 -O /workspace/harvester-v1.8.2-amd64.iso \
          https://releases.rancher.com/harvester/v1.8.2/harvester-v1.8.2-amd64.iso
      else
        echo "      Source ISO cached (size: \$(stat -c %s /workspace/harvester-v1.8.2-amd64.iso) bytes)."
      fi

      echo "[4/4] Remastering Harvester ISO (${MODE} mode with ${CONFIG_NAME})..."
      OUTPUT_ISO="/workspace/harvester-v1.8.2-${IMAGE_NAME}.iso"
      rm -f "\$OUTPUT_ISO"
      TMPDIR=/workspace/tmp /scripts/remaster-iso.sh \
        --source-iso /workspace/harvester-v1.8.2-amd64.iso \
        --config-file "/scripts/${CONFIG_NAME}" \
        --mode "${MODE}" \
        --output-iso "\$OUTPUT_ISO"

      echo "[✓] ISO built successfully at \$OUTPUT_ISO"
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    - name: scripts
      mountPath: /scripts
    resources:
      limits:
        cpu: "4"
        memory: "8Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

  echo "[+] Step 4: Waiting for ISO builder pod to complete..."
  kubectl --kubeconfig "$KUBECONFIG_HOST" wait --for=condition=Ready pod/"$BUILDER_POD" -n "$NAMESPACE" --timeout=60s
  kubectl --kubeconfig "$KUBECONFIG_HOST" logs -f "$BUILDER_POD" -n "$NAMESPACE"
else
  echo "[✓] Builder pod already completed successfully. Reusing built ISO."
fi

# Wait for pod phase Succeeded
for i in {1..30}; do
    PHASE=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get pod "$BUILDER_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Succeeded" ]]; then
        echo "[✓] Builder pod finished successfully."
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete pod "$BUILDER_POD" -n "$NAMESPACE" --now >/dev/null 2>&1 || true
        break
    elif [[ "$PHASE" == "Failed" ]]; then
        echo "[-] Error: Builder pod failed." >&2
        kubectl --kubeconfig "$KUBECONFIG_HOST" logs "$BUILDER_POD" -n "$NAMESPACE" --tail=50
        exit 1
    fi
    sleep 3
done

echo "[+] Step 5: Creating fresh VirtualMachineImage '$IMAGE_NAME'..."
# Clean any stale image
kubectl --kubeconfig "$KUBECONFIG_HOST" delete virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" --now >/dev/null 2>&1 || true
sleep 3

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

echo "[+] Step 6: Launching uploader pod ($UPLOADER_POD)..."
cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_HOST" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${UPLOADER_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  volumes:
  - name: workspace
    persistentVolumeClaim:
      claimName: e2e-build-workspace
  containers:
  - name: uploader
    image: registry.suse.com/bci/bci-base:latest
    env:
    - name: TOKEN
      value: "${TOKEN}"
    - name: SERVER_URL
      value: "${SERVER_URL}"
    - name: NAMESPACE
      value: "${NAMESPACE}"
    - name: IMAGE_NAME
      value: "${IMAGE_NAME}"
    command:
    - /bin/bash
    - -c
    - |
      set -eo pipefail
      OUTPUT_ISO="/workspace/harvester-v1.8.2-${IMAGE_NAME}.iso"
      FILE_SIZE=\$(stat -c %s "\$OUTPUT_ISO")
      echo "Streaming ISO to Harvester API (size: \${FILE_SIZE} bytes)..."
      UPLOAD_URL="\${SERVER_URL}/v1/harvester/harvesterhci.io.virtualmachineimages/\${NAMESPACE}/\${IMAGE_NAME}?action=upload&size=\${FILE_SIZE}"

      # Wait a few seconds for backing image data source to initialize
      sleep 5

      curl -k -f --http1.1 --progress-bar \
        -H "Authorization: Bearer \${TOKEN}" \
        -F "chunk=@\${OUTPUT_ISO}" \
        "\${UPLOAD_URL}"

      echo "[✓] Upload completed."
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    resources:
      limits:
        cpu: "2"
        memory: "4Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
EOF

echo "[+] Step 7: Following upload pod logs..."
kubectl --kubeconfig "$KUBECONFIG_HOST" wait --for=condition=Ready pod/"$UPLOADER_POD" -n "$NAMESPACE" --timeout=60s
kubectl --kubeconfig "$KUBECONFIG_HOST" logs -f "$UPLOADER_POD" -n "$NAMESPACE"

# Wait for VirtualMachineImage to report Imported
echo "[+] Step 8: Verifying image import state in Longhorn..."
for i in {1..40}; do
    STATUS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Imported")].status}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "True" ]]; then
        STORAGE_CLASS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.storageClassName}')
        echo ""
        echo "================================================================="
        echo "[✓] SUCCESS: VirtualMachineImage '$IMAGE_NAME' is READY!"
        echo "================================================================="
        echo "    StorageClass: $STORAGE_CLASS"
        echo "================================================================="
        # Cleanup uploader pod
        kubectl --kubeconfig "$KUBECONFIG_HOST" delete pod "$UPLOADER_POD" -n "$NAMESPACE" --now >/dev/null 2>&1 || true
        exit 0
    fi
    PROGRESS=$(kubectl --kubeconfig "$KUBECONFIG_HOST" get virtualmachineimage "$IMAGE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.progress}' 2>/dev/null || echo "0")
    echo "    Import progress: ${PROGRESS}% (attempt $i/40)..."
    sleep 5
done

echo "[-] Error: Timeout waiting for image to be imported." >&2
exit 1

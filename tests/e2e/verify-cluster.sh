#!/usr/bin/env bash
#
# verify-cluster.sh — Poll nested Harvester VIP until control plane is Ready
#
set -euo pipefail

VIP="${1:-10.144.98.240}"
NODE_IP="${2:-10.144.98.241}"
MAX_MINUTES="${3:-15}"

echo "================================================================="
echo "[+] Starting Harvester Nested Cluster Readiness Verification"
echo "================================================================="
echo "    Target Cluster VIP:  https://${VIP}"
echo "    Expected Node IP:    ${NODE_IP}"
echo "    Timeout:             ${MAX_MINUTES} minutes"
echo "================================================================="

START_TIME=$(date +%s)
MAX_SECONDS=$((MAX_MINUTES * 60))
RETRY_INTERVAL=10

echo "[*] Polling https://${VIP}/ping (Harvester VIP readiness probe)..."

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [[ $ELAPSED -gt $MAX_SECONDS ]]; then
        echo "[-] Error: Timed out after ${MAX_MINUTES} minutes waiting for https://${VIP}/ping" >&2
        exit 1
    fi

    # Probe /ping with 3s timeout
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "https://${VIP}/ping" 2>/dev/null || true)
    if [[ -z "$HTTP_CODE" ]]; then
        HTTP_CODE="000"
    fi

    if [[ "$HTTP_CODE" == "200" ]]; then
        MINUTES=$((ELAPSED / 60))
        SECONDS=$((ELAPSED % 60))
        echo ""
        echo "================================================================="
        echo "[✓] SUCCESS: Harvester Nested Control Plane is ONLINE and HEALTHY!"
        echo "================================================================="
        echo "    VIP Endpoint:   https://${VIP}"
        echo "    HTTP Status:    200 OK"
        echo "    Elapsed Time:   ${MINUTES}m ${SECONDS}s"
        echo "================================================================="
        exit 0
    fi

    echo -n "."
    sleep $RETRY_INTERVAL
done

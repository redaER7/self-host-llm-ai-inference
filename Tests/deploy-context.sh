#!/usr/bin/env bash
# deploy-context.sh — patch vLLM manifest and restart for a given context length.
#
# Usage:
#   bash Tests/deploy-context.sh <max-model-len> [namespace] [manifest]
#
# Examples:
#   bash Tests/deploy-context.sh 8192
#   bash Tests/deploy-context.sh 32768 beta
#   bash Tests/deploy-context.sh 131072 beta case_beta/kserve/llm-inference-service-config-workload.yaml
#
# Environment:
#   LLM_URL    — health-check endpoint (default: https://llm.yacodata.com/v1/models)

set -euo pipefail

MAX_MODEL_LEN="${1:?Usage: deploy-context.sh <max-model-len> [namespace] [manifest]}"
NAMESPACE="${2:-beta}"
MANIFEST="${3:-case_beta/kserve/llm-inference-service-config-workload.yaml}"
HEALTH_URL="${LLM_URL:-https://llm.yacodata.com/v1/models}"
PATCHED="/tmp/llm-workload-patched-${MAX_MODEL_LEN}.yaml"

echo "=== deploy-context.sh ==="
echo "  max-model-len : ${MAX_MODEL_LEN}"
echo "  namespace     : ${NAMESPACE}"
echo "  manifest      : ${MANIFEST}"
echo "  health URL    : ${HEALTH_URL}"
echo ""

# ── 1. Patch manifest ────────────────────────────────────────────────────
echo "1. Patching manifest with --max-model-len ${MAX_MODEL_LEN}"
cp "${MANIFEST}" "${PATCHED}"

# Replace the value on the line following --max-model-len
sed -i '' "/--max-model-len/{n;s/\"[0-9]*\"/\"${MAX_MODEL_LEN}\"/}" "${PATCHED}"
echo "   Patched copy: ${PATCHED}"

# ── 2. Apply ─────────────────────────────────────────────────────────────
echo ""
echo "2. Applying patched manifest"
kubectl apply -f "${PATCHED}" -n "${NAMESPACE}"

# ── 3. Wait for rollout ──────────────────────────────────────────────────
echo ""
echo "3. Waiting for rollout (up to 25 min) ..."
kubectl rollout status deployment -n "${NAMESPACE}" --timeout=25m

# ── 4. Poll health ───────────────────────────────────────────────────────
echo ""
echo "4. Polling ${HEALTH_URL} (up to 5 min) ..."
for i in $(seq 1 30); do
    if curl -sf "${HEALTH_URL}" > /dev/null 2>&1; then
        echo ""
        echo "✓ Model ready. You can now run:"
        echo "  python3 Tests/bench_matrix.py"
        exit 0
    fi
    printf "  waiting... (%d/30)\r" "$i"
    sleep 10
done

echo ""
echo "ERROR: model not ready after 5 minutes."
exit 1

#!/usr/bin/env bash
# Load sweep for Practise 2 — ramps concurrency against the AI Gateway and
# records per-request timing to CSV.
#
# Uses STREAMING requests and curl's time_starttransfer as TTFT proxy
# (time to first token ≈ time to first byte on a streaming SSE response),
# time_total as end-to-end latency.
#
# Usage:
#   bash 02_load_sweep.sh https://llm.yacodata.com "Qwen/Qwen3-8B" /tmp/sweep.csv
#
# Output CSV: concurrency, req_idx, http_code, ttfb_s, total_s
# Needs: curl, jq (only to validate the endpoint beforehand).
set -u

BASE_URL="${1:?usage: $0 <base-url> <model> <out-csv>}"
MODEL="${2:?usage: $0 <base-url> <model> <out-csv>}"
OUT="${3:?usage: $0 <base-url> <model> <out-csv>}"

PROMPT="Write a short paragraph about GPU memory bandwidth and why it matters for LLM decoding."
BODY=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" \
  '{model:$m, messages:[{role:"user",content:$p}], max_tokens:200, temperature:0, stream:true}')

echo "concurrency,req_idx,http_code,ttfb_s,total_s" > "$OUT"

one_request() {
  local conc="$1" idx="$2"
  local code ttfb total
  read -r code ttfb total <<< "$(
    curl -s -o /dev/null -N -X POST "${BASE_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "x-ai-eg-model: ${MODEL}" \
      -d "$BODY" \
      -w "%{http_code} %{time_starttransfer} %{time_total}"
  )"
  echo "${conc},${idx},${code},${ttfb},${total}" >> "$OUT"
}

for conc in 1 2 4 8; do
  echo "--- concurrency=${conc} ---"
  for i in $(seq 1 "$conc"); do
    one_request "$conc" "$i" &
  done
  wait
done

echo "wrote $OUT"
column -s, -t "$OUT" | head -20
echo "..."
echo "TIP: plot ttfb_s/total_s vs concurrency; saturation (flat tok/s in Grafana + growing queue depth) = backpressure, not degradation."

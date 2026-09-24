#!/usr/bin/env bash
# Repeatability check for Practise 4 — sends the SAME prompt N times
# (temperature 0, fixed max_tokens, non-streaming) and reports whether the
# replies are byte-identical via sha256.
#
# Usage:
#   bash 03_repeatability_check.sh https://llm.yacodata.com "Qwen/Qwen3-8B" "Explain thermal throttling in one sentence." 5
#
# Needs: curl, jq, sha256sum.
set -u

BASE_URL="${1:?usage: $0 <base-url> <model> <prompt> <n>}"
MODEL="${2:?usage: $0 <base-url> <model> <prompt> <n>}"
PROMPT="${3:?usage: $0 <base-url> <model> <prompt> <n>}"
N="${4:?usage: $0 <base-url> <model> <prompt> <n>}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "prompt: $PROMPT"
echo "model:  $MODEL (temperature=0, $N repetitions)"
echo ""

for i in $(seq 1 "$N"); do
  curl -s -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "x-ai-eg-model: ${MODEL}" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" \
      '{model:$m, messages:[{role:"user",content:$p}], max_tokens:100, temperature:0, stream:false}')" \
    | jq -r '.choices[0].message.content // .error.message // "NO_CONTENT"' \
    > "$TMPDIR/reply_$i.txt"
  echo "run $i: $(sha256sum < "$TMPDIR/reply_$i.txt" | cut -c1-12) $(wc -c < "$TMPDIR/reply_$i.txt" | tr -d ' ') bytes"
done

echo ""
if [ "$(sha256sum "$TMPDIR"/reply_*.txt | awk '{print $1}' | sort -u | wc -l)" -eq 1 ]; then
  echo "RESULT: all $N replies BYTE-IDENTICAL (greedy + fixed config => statistical reproducibility on this path)."
else
  echo "RESULT: replies DIFFER — inspect, then discuss why:"
  echo "  diff $TMPDIR/reply_1.txt $TMPDIR/reply_2.txt"
  echo "  Candidates: temp>0, continuous-batching arrival order, parallel reduction order."
  echo "  Interview line: 'bitwise needs deterministic flags + pinned stack; first ask whether the team needs bitwise or statistical.'"
fi
echo ""
echo "Sample reply:"
head -c 400 "$TMPDIR/reply_1.txt"; echo ""

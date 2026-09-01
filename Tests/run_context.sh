#!/usr/bin/env bash
set -euo pipefail
# ── vars (edit these) ──
MODEL="Qwen/Qwen3.8-27B"
GPU="RTX PRO 6000 Blackwell"
CONTEXT="8192"
URL="https://llm.yacodata.com/v1/chat/completions"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/venv/bin/activate"
fi

# derive results dir exactly as bench_matrix does (host-aware)
RESULTS_DIR="$(cd "$SCRIPT_DIR" && python3 -c 'import sys; from bench_matrix import get_results_dir; print(get_results_dir(sys.argv[1], sys.argv[2]))' "$MODEL" "$URL")"
mkdir -p "$RESULTS_DIR"
SANITIZED="$(cd "$SCRIPT_DIR" && python3 -c 'from bench_matrix import sanitize; import sys; print(sanitize(sys.argv[1]))' "$MODEL")"
TS="$(date +%Y%m%d-%H%M%S)"
SAFE_CTX="${CONTEXT//,/-}"
LOG="$RESULTS_DIR/Logs-${SANITIZED}-${SAFE_CTX}-${TS}.log"

# parse --contexts list for menu index (dedicated context → first entry)
IDX=1
if [[ "$CONTEXT" == *","* ]]; then
  IFS=',' read -ra CTXS <<< "$CONTEXT"
  # for a dedicated run the menu is built from the same list, so first entry is the target;
  # keep IDX=1 (strictly first) — extensible if you later want CTXS[0] selection logic
  IDX=1
fi

echo "Results dir: $RESULTS_DIR"
echo "Log: $LOG"
( cd "$SCRIPT_DIR" && printf '%s\n' "$IDX" | python3 bench_matrix.py --url "$URL" --contexts "$CONTEXT" --model "$MODEL" --gpu "$GPU" --resume > "$LOG" 2>&1 & )
echo "PID $! -> $LOG"

#!/usr/bin/env bash
set -euo pipefail

# Configure MIG partitions on an A100 GPU.
# Run as root on the GPU node AFTER NVIDIA drivers are installed.
#
# Usage:
#   bash configure-mig.sh [--profiles 1g.10gb,3g.40gb] [--reset]
#
# Default profiles: 1g.10gb (Qwen 2.5 7B) + 3g.40gb (Llama 3 70B)

PROFILES="1g.10gb,3g.40gb"
RESET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --profiles) PROFILES="$2"; shift 2 ;;
    --reset)    RESET=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if ! command -v nvidia-smi &>/dev/null; then
  echo "ERROR: nvidia-smi not found. NVIDIA drivers required."
  exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "Found $GPU_COUNT GPU(s)"

if [[ "$RESET" == "true" ]]; then
  echo "Resetting all MIG partitions"
  nvidia-smi mig -dgi -R 2>/dev/null || true
fi

echo "Creating MIG partitions: $PROFILES"
IFS=',' read -ra PROFILES_ARRAY <<< "$PROFILES"
nvidia-smi mig -cgi "${PROFILES_ARRAY[*]}" -C

echo "Verifying MIG configuration"
nvidia-smi mig -lgi

echo "MIG partitions ready"

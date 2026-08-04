#!/usr/bin/env bash
set -euo pipefail

# Configure MIG partitions on an A100 GPU with persistence across reboots.
# Run as root on the GPU node AFTER NVIDIA drivers are installed.
#
# Usage:
#   bash configure-mig.sh [--profiles 2g.10gb,3g.20gb] [--reset] [--install]
#
# Default profiles: 2g.10gb (Qwen 2.5 7B) + 3g.20gb (Qwen 2.5 14B)
# Persistence: installs systemd service for boot-time restore via nvidia-smi

PROFILES="2g.10gb,3g.20gb"
RESET=false
INSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --profiles) PROFILES="$2"; shift 2 ;;
    --reset)    RESET=true; shift ;;
    --install)  INSTALL=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if ! command -v nvidia-smi &>/dev/null; then
  echo "ERROR: nvidia-smi not found. NVIDIA drivers required."
  exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "Found $GPU_COUNT GPU(s)"

# --- Reset existing MIG partitions if requested ---
if [[ "$RESET" == "true" ]]; then
  echo "Resetting all MIG partitions..."
  nvidia-smi mig -dci 2>/dev/null || true
  nvidia-smi mig -dgi 2>/dev/null || true
fi

# --- Apply MIG configuration ---
echo "Creating MIG partitions: ${PROFILES}"
IFS=',' read -ra PROFILES_ARRAY <<< "$PROFILES"
nvidia-smi mig -cgi "${PROFILES_ARRAY[*]}" -C

echo "Verifying MIG configuration"
nvidia-smi -L

# --- Install systemd service for persistence ---
if [[ "$INSTALL" == "true" ]]; then
  echo "Installing systemd service for MIG persistence..."

  cat > /etc/systemd/system/nvidia-mig-config.service <<EOF
[Unit]
Description=Apply NVIDIA MIG Configuration
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'nvidia-smi mig -dci 2>/dev/null; nvidia-smi mig -dgi 2>/dev/null; nvidia-smi mig -cgi ${PROFILES} -C'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nvidia-mig-config.service
  echo "Systemd service installed and enabled."
  echo "MIG partitions will be restored automatically on boot."
fi

echo ""
echo "MIG partitions ready."

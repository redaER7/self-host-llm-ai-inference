#!/usr/bin/env bash
set -euo pipefail

# Case beta — delegates to the shared WireGuard GPU setup script.
# Usage:
#   export CP_NODE_IP=89.167.109.193
#   bash case_beta/wireguard-setup.sh

export WG_ADDRESS="${WG_ADDRESS:-10.8.0.2/24}"
exec "$(dirname "$0")/../wireguard/gpu-setup.sh"

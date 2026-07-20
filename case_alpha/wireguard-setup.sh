#!/usr/bin/env bash
set -euo pipefail

# Case alpha — delegates to the shared WireGuard GPU setup script.
# Uses a different WireGuard address than beta (10.8.0.3 vs 10.8.0.2).
#
# Usage:
#   export CP_NODE_IP=89.167.109.193
#   bash case_alpha/wireguard-setup.sh

export WG_ADDRESS="${WG_ADDRESS:-10.8.0.3/24}"
exec "$(dirname "$0")/../wireguard/gpu-setup.sh"
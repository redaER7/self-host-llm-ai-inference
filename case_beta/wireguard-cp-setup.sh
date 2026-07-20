#!/usr/bin/env bash
set -euo pipefail

# Case beta — delegates to the shared WireGuard CP setup script.
# Run this first, before setting up the GPU client.

exec "$(dirname "$0")/../wireguard/cp-setup.sh"


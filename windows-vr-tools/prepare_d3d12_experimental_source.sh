#!/usr/bin/env bash
# Prepare the pinned isolated modern-DXMT runtime profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec bash "$ROOT/windows-vr-tools/prepare_d3d12_profile.sh" "$@"

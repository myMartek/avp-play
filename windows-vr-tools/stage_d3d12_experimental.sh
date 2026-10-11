#!/usr/bin/env bash
# Stage a build-receipt-matched modern-DXMT D3D12 closure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec bash "$ROOT/windows-vr-tools/stage_d3d12_profile.sh" "$@"

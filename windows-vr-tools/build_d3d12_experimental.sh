#!/usr/bin/env bash
# Receipt-backed opt-in build for the isolated modern-DXMT D3D12 profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec bash "$ROOT/windows-vr-tools/build_d3d12_profile.sh" "$@"


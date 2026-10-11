#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dxmt_dir="${1:-$repo_root/runtime-source/dxmt}"
overlay="$repo_root/windows-vr-ngx/patches/0001-dxmt-ngxsreye.patch"
patch --batch -p1 -d "$dxmt_dir" < "$overlay"
availability_overlay="$repo_root/windows-vr-ngx/patches/0002-dxmt-visionos-temporal-unavailable.patch"
patch --batch -p1 -d "$dxmt_dir" < "$availability_overlay"
cp "$repo_root/windows-vr-ngx/src/WVRMetalFXWMTBridge.h" "$dxmt_dir/src/winemetal/unix/WVRMetalFXWMTBridge.h"
cp "$repo_root/windows-vr-ngx/src/WVRMetalFXWMTBridge.inc" "$dxmt_dir/src/winemetal/unix/WVRMetalFXWMTBridge.inc"
cp "$repo_root/windows-vr-ngx/include/WindowsVRNGX.h" "$dxmt_dir/src/nvngx/WindowsVRNGX.h"
cp "$repo_root/windows-vr-metal/Sources/WindowsVRMetalABI/include/WindowsVRMetalC.h" "$dxmt_dir/src/winemetal/unix/WindowsVRMetalC.h"

echo "Overlay source applied. No build or install was run."

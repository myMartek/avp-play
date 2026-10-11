#!/bin/bash
# Source build recipe only. This file has NOT been executed.
# The caller must explicitly opt in; do not run it for static inspection.
set -euo pipefail
if [[ "${AVPPLAY_ALLOW_RUNTIME_BUILD:-0}" != "1" ]]; then
    echo "Runtime build requires explicit opt-in: set AVPPLAY_ALLOW_RUNTIME_BUILD=1." >&2
    exit 1
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${AVPPLAY_RUNTIME_SOURCE:-$task_root/runtime-source}"
d3d12_profile="${AVPPLAY_D3D12_PROFILE_SOURCE:-$task_root/runtime-source-d3d12-experimental}"
if [[ "${AVPPLAY_ENABLE_D3D12:-0}" == "1" ]]; then
    [[ -f "$d3d12_profile/AVPPLAY_D3D12_SOURCE_PROVENANCE.json" ]] || {
        echo "Prepare the isolated D3D12 profile before the native runtime build." >&2; exit 1;
    }
    runtime_root="$d3d12_profile"
    export AVPPLAY_RUNTIME_SOURCE="$runtime_root"
    python3 - "$task_root/windows-vr-tools/sources.lock.json" "$d3d12_profile/AVPPLAY_D3D12_SOURCE_PROVENANCE.json" <<'PY'
import json, pathlib, sys
lock=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
receipt=json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
pin=next(item for item in lock["sources"] if item["name"] == "dxmt-d3d12-experimental")
if receipt.get("sourceRevision") != pin["revision"] or receipt.get("sourceUrl") != pin["url"]:
    raise SystemExit("D3D12 source profile does not match its locked 3Shain DXMT pin.")
PY
fi
if [[ ! -d "$runtime_root" ]]; then
    echo "Prepare the pinned runtime source overlay first." >&2
    exit 1
fi
if ! xcrun --sdk xros --show-sdk-path >/dev/null 2>&1; then
    echo "The selected Xcode does not provide an xros SDK; install/select full Xcode before building the visionOS runtime." >&2
    exit 1
fi
if [[ ! -d "$runtime_root/toolchains/llvm-project/llvm" ]]; then
    echo "Missing LLVM source at runtime-source/toolchains/llvm-project/llvm; fetch/build the external LLVM dependency first." >&2
    exit 1
fi
if [[ ! -d "$runtime_root/toolchains/llvm-ios-build/include" || ! -d "$runtime_root/toolchains/llvm-ios-build/lib" ]]; then
    echo "Missing LLVM headers/libraries at runtime-source/toolchains/llvm-ios-build; provide a visionOS-targeted LLVM build before compiling FEX or DXMT." >&2
    exit 1
fi
shopt -s nullglob
llvm_archives=("$runtime_root/toolchains/llvm-ios-build/lib/"*.a)
if (( ${#llvm_archives[@]} == 0 )); then
    echo "No LLVM static archives found under runtime-source/toolchains/llvm-ios-build/lib." >&2
    exit 1
fi
# Each script is the generated xros retarget, not the original iOS script.
bash "$runtime_root/build/gnutls-ios/build.sh"
bash "$runtime_root/build/ffmpeg/build.sh"
bash "$runtime_root/build/fex-ios/build.sh"
bash "$runtime_root/build/ntdll-unix/build.sh"
bash "$runtime_root/build/wineserver/build.sh"
bash "$runtime_root/build/win32u-unix/build.sh"
if [[ "${AVPPLAY_ENABLE_D3D12:-0}" != "1" ]]; then
    bash "$runtime_root/build/dxmt-ios/build.sh"
# Upstream DXMT's script only refreshes a pre-existing combined archive; create
# its initial native closure explicitly, without reusing an iOS archive.
if [[ ! -f "$runtime_root/build/dxmt-ios/libdxmt_unix.a" ]]; then
    echo "DXMT build did not produce build/dxmt-ios/libdxmt_unix.a." >&2
    exit 1
fi
xcrun --sdk xros libtool -static -o "$runtime_root/app/Madeira/libdxmt_combined.a" \
    "$runtime_root/build/dxmt-ios/libdxmt_unix.a" "${llvm_archives[@]}"
fi
cp "$runtime_root/toolchains/gnutls-ios/lib/libgnutls.a" "$runtime_root/app/Madeira/libgnutls.a"
cp "$runtime_root/toolchains/gnutls-ios/lib/libhogweed.a" "$runtime_root/app/Madeira/libhogweed.a"
cp "$runtime_root/toolchains/gnutls-ios/lib/libnettle.a" "$runtime_root/app/Madeira/libnettle.a"
cp "$runtime_root/toolchains/gnutls-ios/lib/libgmp.a" "$runtime_root/app/Madeira/libgmp.a"
if [[ "${AVPPLAY_ENABLE_D3D12:-0}" != "1" ]]; then
    python3 "$task_root/windows-vr-tools/resource_receipt.py" native --runtime-source "$runtime_root"
fi
# The modern native receipt is recorded after its same-source graphics archive
# and guest DLLs have actually completed in build_wine_guest_resources.sh.
# PE-side Wine/DXMT/OpenXR/OpenComposite compilation and resources are separate
# Windows target build recipes. No native platform marker rewriting is used.

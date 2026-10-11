#!/usr/bin/env bash
# Opt-in PE Wine/DXMT resource build from the pinned Madeira overlay; never runs Wine.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${AVPPLAY_RUNTIME_SOURCE:-$repo_root/runtime-source}"
if [[ "${AVPPLAY_ALLOW_RUNTIME_BUILD:-0}" != "1" || "${AVPPLAY_BUILD_WINE_PE:-0}" != "1" ]]; then
    echo "Set AVPPLAY_ALLOW_RUNTIME_BUILD=1 and AVPPLAY_BUILD_WINE_PE=1 to build PE resources." >&2
    exit 1
fi
if [[ ! -d "$runtime_root" || ! -f "$runtime_root/AVPPLAY_SOURCE_PROVENANCE.json" ]]; then
    echo "Missing prepared pinned Madeira overlay or source provenance: $runtime_root" >&2
    exit 1
fi
if [[ -z "${AVPPLAY_LLVM_MINGW_ROOT:-}" || "$AVPPLAY_LLVM_MINGW_ROOT" != /* || ! -d "$AVPPLAY_LLVM_MINGW_ROOT" ]]; then
    echo "Set AVPPLAY_LLVM_MINGW_ROOT to the absolute path of the pinned LLVM-MinGW toolchain." >&2
    exit 1
fi
if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1 || ! command -v bison >/dev/null 2>&1; then
    echo "PE resource build requires Meson, Ninja, and bison 3 or newer." >&2
    exit 1
fi
bison_version="$(bison --version | awk 'NR == 1 {print $4}')"
bison_major="${bison_version%%.*}"
if [[ ! "$bison_major" =~ ^[0-9]+$ ]] || (( bison_major < 3 )); then
    echo "Wine PE build requires bison 3 or newer (found ${bison_version:-unknown})." >&2
    exit 1
fi

pinned_toolchain="$runtime_root/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
created_link=0
if [[ -e "$pinned_toolchain" || -L "$pinned_toolchain" ]]; then
    if [[ ! -d "$pinned_toolchain" ]]; then
        echo "Refusing non-directory LLVM-MinGW path: $pinned_toolchain" >&2
        exit 1
    fi
    pinned_real="$(cd "$pinned_toolchain" && pwd -P)"
    external_real="$(cd "$AVPPLAY_LLVM_MINGW_ROOT" && pwd -P)"
    if [[ "$pinned_real" != "$external_real" ]]; then
        echo "The pinned Madeira toolchain path resolves somewhere other than AVPPLAY_LLVM_MINGW_ROOT." >&2
        exit 1
    fi
else
    mkdir -p "$(dirname "$pinned_toolchain")"
    ln -s "$AVPPLAY_LLVM_MINGW_ROOT" "$pinned_toolchain"
    created_link=1
fi
cleanup() {
    if (( created_link )); then rm -f "$pinned_toolchain"; fi
}
trap cleanup EXIT

wine_farm="$runtime_root/app/Madeira/arm64ec-windows"
mkdir -p "$wine_farm"
for tool in arm64ec-w64-mingw32-strip; do
    if [[ ! -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/$tool" ]]; then
        echo "LLVM-MinGW is missing $tool under AVPPLAY_LLVM_MINGW_ROOT/bin." >&2
        exit 1
    fi
done

# These are Madeira's pinned PE build entry points documented at its lock revision.
bash "$runtime_root/build/wine-pe/build-ntdll.sh"
bash "$runtime_root/build/wine-pe/build-modules.sh" \
    cryptsp d3dx11_43 msvcp110 msvcr110 xaudio2_7
# Madeira's documented ARM64EC FEX PE translator is part of the guest DLL farm.
bash "$runtime_root/build/fex-arm64ec/build.sh"

if [[ "${AVPPLAY_ENABLE_D3D12:-0}" != "1" ]]; then
# Madeira docs/BUILDING.md records this DXMT ARM64EC Meson/Ninja route.
dxmt_root="$runtime_root/dxmt"
dxmt_build="$dxmt_root/build-arm64ec"
if [[ ! -f "$dxmt_build/build.ninja" ]]; then
    meson setup "$dxmt_build" "$dxmt_root" \
        -Dbuildtype=release \
        -Dwine_build_path=../../wine/build-arm64ec \
        --cross-file="$dxmt_root/build-arm64ec-win.txt"
fi
ninja -C "$dxmt_build" src/winemetal/winemetal.dll src/d3d11/d3d11.dll
cp "$dxmt_build/src/winemetal/winemetal.dll" "$wine_farm/winemetal.dll"
cp "$dxmt_build/src/d3d11/d3d11.dll" "$wine_farm/d3d11.dll"
fi

for required in "$runtime_root/app/Madeira/aarch64-windows" "$runtime_root/app/Madeira/nls" "$runtime_root/app/Madeira/legal"; do
    if [[ ! -d "$required" ]]; then
        echo "Pinned Madeira source is missing its required resource directory: $required" >&2
        exit 1
    fi
done
if [[ "${AVPPLAY_ENABLE_D3D12:-0}" == "1" ]]; then
    AVPPLAY_ALLOW_RUNTIME_BUILD=1 AVPPLAY_ENABLE_D3D12=1 \
        bash "$repo_root/windows-vr-tools/build_d3d12_experimental.sh"
    # Compatibility pathname for the generic resource ledger only. This is the
    # freshly built modern archive, never an old baseline or relabeled platform.
    cp "$runtime_root/app/Madeira/libdxmt_d3d12_combined.a" "$runtime_root/app/Madeira/libdxmt_combined.a"
    python3 "$repo_root/windows-vr-tools/resource_receipt.py" native --runtime-source "$runtime_root"
fi

python3 "$repo_root/windows-vr-tools/resource_receipt.py" guest \
    --runtime-source "$runtime_root" \
    --resource-source "$runtime_root/app/Madeira"
echo "Built and recorded pinned Madeira PE/DXMT guest resources. Wine was not executed."

#!/usr/bin/env bash
# Opt-in PE Wine/DXMT resource build from the pinned Madeira overlay; never runs Wine.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${AVPPLAY_RUNTIME_SOURCE:-$repo_root/runtime-source}"
# Homebrew keeps Bison keg-only; use its supported host generator without
# changing the user's shell profile or the system-provided Bison.
for bison_directory in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin; do
    if [[ -x "$bison_directory/bison" ]]; then
        export PATH="$bison_directory:$PATH"
        break
    fi
done
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
llvm_runtime_bin="$AVPPLAY_LLVM_MINGW_ROOT/arm64ec-w64-mingw32/bin"
for tool in arm64ec-w64-mingw32-strip; do
    if [[ ! -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/$tool" ]]; then
        echo "LLVM-MinGW is missing $tool under AVPPLAY_LLVM_MINGW_ROOT/bin." >&2
        exit 1
    fi
done
export PATH="$AVPPLAY_LLVM_MINGW_ROOT/bin:$PATH"

# These are Madeira's pinned PE build entry points documented at its lock revision.
# Wine's ARM64EC default disables a few system programs even though their
# Makefile.in files support PE targets. Enable the actual ARM64EC targets so
# the farm contains native ARM64EC binaries rather than borrowed ARM64 files.
wine_build="$runtime_root/wine/build-arm64ec"
if ! grep -Fq 'programs/wineboot/arm64ec-windows/wineboot.exe:' "$wine_build/Makefile" 2>/dev/null; then
    mkdir -p "$wine_build"
    (
        cd "$wine_build"
        enable_wineboot=arm64ec enable_services=arm64ec enable_rpcss=arm64ec \
            enable_winedevice=arm64ec enable_plugplay=arm64ec \
            PATH="$AVPPLAY_LLVM_MINGW_ROOT/bin:$PATH" \
            ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer
    )
fi
bash "$runtime_root/build/wine-pe/build-ntdll.sh"
JOBS="${AVPPLAY_BUILD_JOBS:-4}" bash "$runtime_root/build/wine-pe/build-modules.sh" \
    cryptsp d3dx11_43 msvcp110 msvcr110 xaudio2_7 \
    kernel32 kernelbase advapi32 shell32 shlwapi version user32 gdi32 \
    setupapi newdev wininet ws2_32 ole32 rpcrt4 secur32 bcrypt msvcrt winmm \
    apisetschema mswsock dnsapi iphlpapi winhttp \
    ucrtbase userenv ntoskrnl.exe cfgmgr32 combase coml2 mpr msacm32 sechost shcore win32u
# Create the four core Wine executables as ARM64EC PE files, then strip only
# debug sections before placing them in the guest farm.
core_program_targets=(
    programs/wineboot/arm64ec-windows/wineboot.exe
    programs/services/arm64ec-windows/services.exe
    programs/winedevice/arm64ec-windows/winedevice.exe
    programs/rpcss/arm64ec-windows/rpcss.exe
)
make -C "$wine_build" -j"${AVPPLAY_BUILD_JOBS:-4}" "${core_program_targets[@]}"
for target in "${core_program_targets[@]}"; do
    output="$wine_farm/$(basename "$target")"
    cp "$wine_build/$target" "$output.tmp"
    "$AVPPLAY_LLVM_MINGW_ROOT/bin/arm64ec-w64-mingw32-strip" --strip-debug "$output.tmp"
    mv "$output.tmp" "$output"
done
# The pinned aarch64 farm is missing Wine's winedevice service. Build that
# target from the same Wine source and place the unmodified PE in its farm.
wine_aarch64_build="$runtime_root/wine/build-avp-aarch64"
if ! grep -Fq 'programs/winedevice/aarch64-windows/winedevice.exe:' \
    "$wine_aarch64_build/Makefile" 2>/dev/null; then
    mkdir -p "$wine_aarch64_build"
    (
        cd "$wine_aarch64_build"
        enable_winedevice=aarch64 PATH="$AVPPLAY_LLVM_MINGW_ROOT/bin:$PATH" \
            ../configure --enable-archs=aarch64 --without-x --disable-tests
    )
fi
aarch64_winedevice_target=programs/winedevice/aarch64-windows/winedevice.exe
make -C "$wine_aarch64_build" -j"${AVPPLAY_BUILD_JOBS:-4}" "$aarch64_winedevice_target"
cp "$wine_aarch64_build/$aarch64_winedevice_target" \
    "$runtime_root/app/Madeira/aarch64-windows/winedevice.exe"
# Madeira's documented ARM64EC FEX PE translator is part of the guest DLL farm.
bash "$runtime_root/build/fex-arm64ec/build.sh"
# FEX is linked against the pinned ARM64EC libc++ and libunwind DLLs. Ship
# those exact target runtimes beside the translator, never host or x64 variants.
for runtime_dll in libc++.dll libunwind.dll; do
    runtime_source="$llvm_runtime_bin/$runtime_dll"
    if [[ ! -f "$runtime_source" || -L "$runtime_source" ]]; then
        echo "Pinned LLVM-MinGW ARM64EC runtime DLL is missing or not a regular file: $runtime_source" >&2
        exit 1
    fi
    cp "$runtime_source" "$wine_farm/$runtime_dll"
done
# Carry the toolchain distribution's license with its runtime DLLs.
llvm_license="$AVPPLAY_LLVM_MINGW_ROOT/LICENSE.TXT"
if [[ ! -s "$llvm_license" || -L "$llvm_license" ]]; then
    echo "Pinned LLVM-MinGW license is missing or unsafe: $llvm_license" >&2
    exit 1
fi
cp "$llvm_license" "$runtime_root/app/Madeira/legal/LLVM-MinGW-LICENSE.TXT"

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

cp "$runtime_root/dxmt/LICENSE" "$runtime_root/app/Madeira/legal/DXMT-LICENSE"

python3 "$repo_root/windows-vr-tools/resource_receipt.py" guest \
    --runtime-source "$runtime_root" \
    --resource-source "$runtime_root/app/Madeira"
echo "Built and recorded pinned Madeira PE/DXMT guest resources. Wine was not executed."

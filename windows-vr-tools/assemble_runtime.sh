#!/usr/bin/env bash
# Source-to-app assembly. Never run without explicit build opt-in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${AVPPLAY_ALLOW_RUNTIME_BUILD:-0}" != "1" ]]; then
    echo "Assembly builds are disabled. Set AVPPLAY_ALLOW_RUNTIME_BUILD=1 to opt in." >&2
    exit 1
fi

require_value() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Set the required input $name before assembly." >&2
        exit 1
    fi
}
require_absolute() {
    local name="$1"
    case "${!name}" in
        /*) ;;
        *) echo "$name must be an absolute path." >&2; exit 1 ;;
    esac
}

for name in AVPPLAY_WINE_PREFIX_TEMPLATE AVPPLAY_WINE_PREFIX_PROVENANCE AVPPLAY_LLVM_MINGW_ROOT AVPPLAY_BUILD_ROOT AVPPLAY_DEVELOPMENT_TEAM; do
    require_value "$name"
done
for name in AVPPLAY_WINE_PREFIX_TEMPLATE AVPPLAY_WINE_PREFIX_PROVENANCE AVPPLAY_LLVM_MINGW_ROOT AVPPLAY_BUILD_ROOT; do
    require_absolute "$name"
done
for tool in python3 git cmake ninja xcodegen xcodebuild xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required assembly tool: $tool." >&2
        exit 1
    fi
done
cmake_version="$(cmake --version | awk 'NR == 1 {print $3}')"
cmake_major="${cmake_version%%.*}"
cmake_minor="${cmake_version#*.}"
cmake_minor="${cmake_minor%%.*}"
if (( cmake_major < 3 || (cmake_major == 3 && cmake_minor < 28) )); then
    echo "CMake 3.28 or newer is required for visionOS system-name support (found $cmake_version)." >&2
    exit 1
fi

runtime_source="${AVPPLAY_RUNTIME_SOURCE:-$ROOT/runtime-source}"
d3d12_enabled="${AVPPLAY_ENABLE_D3D12:-0}"
case "$d3d12_enabled" in 0|1) ;; *) echo "AVPPLAY_ENABLE_D3D12 must be 0 or 1." >&2; exit 1 ;; esac
if [[ "$d3d12_enabled" == 1 && "${AVPPLAY_BUILD_WINE_PE:-0}" != 1 ]]; then
    echo "D3D12 opt-in requires AVPPLAY_BUILD_WINE_PE=1 so ARM64EC DXMT DLLs use the matching pinned source." >&2
    exit 1
fi
d3d12_profile="${AVPPLAY_D3D12_PROFILE_SOURCE:-$ROOT/runtime-source-d3d12-experimental}"
source_cache="${AVPPLAY_SOURCE_CACHE_ROOT:-$ROOT/third-party}"
case "$runtime_source" in /*) ;; *) echo "AVPPLAY_RUNTIME_SOURCE must be absolute." >&2; exit 1 ;; esac
case "$source_cache" in /*) ;; *) echo "AVPPLAY_SOURCE_CACHE_ROOT must be absolute." >&2; exit 1 ;; esac
if [[ ! -f "$AVPPLAY_WINE_PREFIX_TEMPLATE" || -L "$AVPPLAY_WINE_PREFIX_TEMPLATE" ]]; then
    echo "Wine prefix template must be a regular non-symlink archive created outside this tool." >&2
    exit 1
fi
if [[ ! -s "$AVPPLAY_WINE_PREFIX_PROVENANCE" || -L "$AVPPLAY_WINE_PREFIX_PROVENANCE" ]]; then
    echo "Set AVPPLAY_WINE_PREFIX_PROVENANCE to a nonempty provenance JSON file." >&2
    exit 1
fi
if [[ ! -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/x86_64-w64-mingw32-clang++" ]]; then
    echo "LLVM-MinGW is missing at AVPPLAY_LLVM_MINGW_ROOT." >&2
    exit 1
fi
if [[ "${AVPPLAY_BUILD_WINE_PE:-0}" == "1" ]]; then
    for tool in meson bison; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Missing PE resource build tool: $tool." >&2; exit 1; }
    done
    for tool in arm64ec-w64-mingw32-strip; do
        [[ -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/$tool" ]] || { echo "LLVM-MinGW is missing $tool." >&2; exit 1; }
    done
else
    require_value AVPPLAY_WINE_RESOURCE_SOURCE
    case "$AVPPLAY_WINE_RESOURCE_SOURCE" in /*) ;; *) echo "AVPPLAY_WINE_RESOURCE_SOURCE must be absolute." >&2; exit 1 ;; esac
    [[ -d "$AVPPLAY_WINE_RESOURCE_SOURCE" ]] || { echo "Wine resource source is missing." >&2; exit 1; }
fi
if [[ -e "$runtime_source" ]]; then
    if [[ "${AVPPLAY_REUSE_PREPARED_SOURCE:-0}" != "1" ]]; then
        echo "Prepared source exists; set AVPPLAY_REUSE_PREPARED_SOURCE=1 or choose a fresh AVPPLAY_RUNTIME_SOURCE." >&2
        exit 1
    fi
elif [[ "${AVPPLAY_REUSE_PREPARED_SOURCE:-0}" == "1" ]]; then
    echo "AVPPLAY_REUSE_PREPARED_SOURCE=1 was set, but the source path does not exist." >&2
    exit 1
fi
if [[ ! -d "$AVPPLAY_BUILD_ROOT" ]]; then mkdir -p "$AVPPLAY_BUILD_ROOT"; fi
BUILD_ROOT="$(cd "$AVPPLAY_BUILD_ROOT" && pwd -P)"
GUEST_STAGE="$BUILD_ROOT/guest-stage"
NATIVE_RECEIPT="$runtime_source/AVPPLAY_NATIVE_BUILD_RECEIPT.json"
if ! xcrun --sdk xros --show-sdk-path >/dev/null 2>&1; then
    echo "The selected Xcode does not provide an xros SDK; install/select full Xcode before assembly." >&2
    exit 1
fi
python3 "$ROOT/windows-vr-tools/resource_receipt.py" validate-prefix \
    --template "$AVPPLAY_WINE_PREFIX_TEMPLATE" \
    --provenance "$AVPPLAY_WINE_PREFIX_PROVENANCE"
if [[ "${AVPPLAY_BUILD_WINE_PE:-0}" == "1" ]]; then
    bison_version="$(bison --version | awk 'NR == 1 {print $4}')"
    bison_major="${bison_version%%.*}"
    if [[ ! "$bison_major" =~ ^[0-9]+$ ]] || (( bison_major < 3 )); then
        echo "Wine PE build requires bison 3 or newer (found ${bison_version:-unknown})." >&2
        exit 1
    fi
fi

# Source acquisition and preparation are resumable and preserve existing trees.
if [[ "$d3d12_enabled" == 1 ]]; then
    python3 "$ROOT/windows-vr-tools/fetch_sources.py" --cache-root "$source_cache" --include-d3d12-experimental
else
    python3 "$ROOT/windows-vr-tools/fetch_sources.py" --cache-root "$source_cache"
fi
prepare_args=(--source "$source_cache/madeira" --output "$runtime_source")
if [[ -e "$runtime_source" ]]; then prepare_args+=(--reuse-existing); fi
python3 "$ROOT/windows-vr-tools/prepare_runtime.py" "${prepare_args[@]}"
if [[ "$d3d12_enabled" == 1 ]]; then
    case "$d3d12_profile" in /*) ;; *) echo "AVPPLAY_D3D12_PROFILE_SOURCE must be absolute." >&2; exit 1 ;; esac
    export AVPPLAY_ENABLE_D3D12=1 AVPPLAY_D3D12_PROFILE_SOURCE="$d3d12_profile"
    export AVPPLAY_RUNTIME_SOURCE="$runtime_source"
    bash "$ROOT/windows-vr-tools/prepare_d3d12_experimental_source.sh"
    runtime_source="$d3d12_profile"
    NATIVE_RECEIPT="$runtime_source/AVPPLAY_NATIVE_BUILD_RECEIPT.json"
fi

MADEIRA_LICENSE="${AVPPLAY_MADEIRA_LICENSE:-$runtime_source/LICENSE}"
OPENCOMPOSITE_LICENSE="${AVPPLAY_OPENCOMPOSITE_LICENSE:-$source_cache/opencomposite/LICENSE}"
OPENXR_LICENSE="${AVPPLAY_OPENXR_LICENSE:-$source_cache/openxr/LICENSE}"
for license in "$MADEIRA_LICENSE" "$OPENCOMPOSITE_LICENSE" "$OPENXR_LICENSE"; do
    if [[ ! -s "$license" || -L "$license" ]]; then
        echo "Required nonempty upstream license file is missing or unsafe: $license" >&2
        exit 1
    fi
done

export AVPPLAY_RUNTIME_SOURCE="$runtime_source"
export AVPPLAY_LLVM_MINGW_ROOT
export AVPPLAY_LLVM_TOOLCHAINS_ROOT="${AVPPLAY_LLVM_TOOLCHAINS_ROOT:-$BUILD_ROOT/llvm-toolchains}"
AVPPLAY_ALLOW_RUNTIME_BUILD=1 bash "$ROOT/windows-vr-tools/prepare_llvm.sh" build
AVPPLAY_ALLOW_RUNTIME_BUILD=1 bash "$ROOT/windows-vr-tools/build_runtime.sh"

# Build both x64 Windows guest DLLs into one staging tree with the documented
# LLVM-MinGW route. OpenComposite and the app-owned OpenXR runtime stay separate.
cmake -S "$ROOT/windows-vr-openxr" -B "$BUILD_ROOT/openxr-mingw" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/windows-vr-openxr/cmake/toolchains/llvm-mingw-x64.cmake" \
    -DLLVM_MINGW_ROOT="$AVPPLAY_LLVM_MINGW_ROOT" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPENXR_SDK_SOURCE_ROOT="$source_cache/openxr" \
    -DWINDOWS_VR_GUEST_STAGE="$GUEST_STAGE/WindowsVR/Guest/x64"
cmake --build "$BUILD_ROOT/openxr-mingw" --config Release

opencomposite_d3d12_args=(-DWINDOWS_VR_ENABLE_D3D12=OFF)
if [[ "$d3d12_enabled" == 1 ]]; then
    opencomposite_d3d12_args=(-DWINDOWS_VR_ENABLE_D3D12=ON)
fi
cmake -S "$ROOT/windows-vr-openvr" -B "$BUILD_ROOT/opencomposite-mingw" -G Ninja \
    -DWINDOWS_VR_USE_LLVM_MINGW=ON \
    -DLLVM_MINGW_ROOT="$AVPPLAY_LLVM_MINGW_ROOT" \
    -DOPENCOMPOSITE_SOURCE_ROOT="$source_cache/opencomposite" \
    -DOPENCOMPOSITE_STAGE_ROOT="$GUEST_STAGE" \
    "${opencomposite_d3d12_args[@]}"
cmake --build "$BUILD_ROOT/opencomposite-mingw" --target package_opencomposite --config Release

if [[ "${AVPPLAY_BUILD_WINE_PE:-0}" == "1" ]]; then
    AVPPLAY_ALLOW_RUNTIME_BUILD=1 AVPPLAY_BUILD_WINE_PE=1 \
        bash "$ROOT/windows-vr-tools/build_wine_guest_resources.sh"
    WINE_RESOURCE_SOURCE="$runtime_source/app/Madeira"
else
    WINE_RESOURCE_SOURCE="$AVPPLAY_WINE_RESOURCE_SOURCE"
fi
stage_args=(
    --source "$WINE_RESOURCE_SOURCE"
    --runtime-source "$runtime_source"
    --native-receipt "$NATIVE_RECEIPT"
    --guest-stage "$GUEST_STAGE"
    --prefix-template "$AVPPLAY_WINE_PREFIX_TEMPLATE"
    --prefix-provenance "$AVPPLAY_WINE_PREFIX_PROVENANCE"
    --madeira-license "$MADEIRA_LICENSE"
    --opencomposite-license "$OPENCOMPOSITE_LICENSE"
    --openxr-license "$OPENXR_LICENSE"
    --reuse-existing
)
if [[ "$d3d12_enabled" == 1 ]]; then
    D3D12_STAGE="$BUILD_ROOT/d3d12-stage"
    export AVPPLAY_D3D12_STAGE_ROOT="$D3D12_STAGE"
    export AVPPLAY_D3D12_NATIVE_ARCHIVE="$d3d12_profile/app/Madeira/libdxmt_d3d12_combined.a"
    export AVPPLAY_D3D12_BUILD_RECEIPT="$d3d12_profile/AVPPLAY_D3D12_BUILD_RECEIPT.json"
    export AVPPLAY_D3D12_PROFILE_SOURCE="$d3d12_profile"
    bash "$ROOT/windows-vr-tools/stage_d3d12_experimental.sh"
    stage_args+=(--d3d12-stage "$D3D12_STAGE" --d3d12-native-archive "$AVPPLAY_D3D12_NATIVE_ARCHIVE")
    export AVPPLAY_DXMT_LINK_FLAG="-Wl,-force_load,\"$AVPPLAY_D3D12_NATIVE_ARCHIVE\""
else
    export AVPPLAY_DXMT_LINK_FLAG=-ldxmt_combined
fi
python3 "$ROOT/windows-vr-tools/stage_resources.py" "${stage_args[@]}"

xcodegen generate --spec "$ROOT/visionos-windows-vr/project.yml" \
    --project "$ROOT/visionos-windows-vr"
xcodebuild \
    -project "$ROOT/visionos-windows-vr/VisionOSWindowsVR.xcodeproj" \
    -scheme VisionOSWindowsVR \
    -configuration Debug \
    -destination 'generic/platform=visionOS' \
    -derivedDataPath "$BUILD_ROOT/xcode-derived" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$AVPPLAY_DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY='Apple Development' \
    AVPPLAY_DXMT_LINK_FLAG="$AVPPLAY_DXMT_LINK_FLAG" \
    build

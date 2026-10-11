#!/bin/bash
# Fetch and configure the externally pinned LLVM source for Madeira's native
# visionOS toolchain. This does not run LLVM tests.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: prepare_llvm.sh [fetch|configure|build]

  fetch      Fetch and verify the locked LLVM commit only.
  configure  (default) Fetch source, build host llvm-tblgen, configure xros.
  build      Configure as above, then build the visionOS LLVM libraries.

The `build` mode compiles LLVM but never runs its test suites.
USAGE
}
mode="${1:-configure}"
case "$mode" in
    fetch|configure|build) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="$repo_root/runtime-source"
lock_file="$repo_root/windows-vr-tools/llvm.lock.json"
if [[ ! -d "$runtime_root" ]]; then
    echo "Prepare the pinned runtime source overlay first: $runtime_root is missing." >&2
    exit 1
fi

read_lock() {
    python3 - "$lock_file" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
PY
}
llvm_url="$(read_lock url)"
llvm_revision="$(read_lock revision)"
runtime_toolchains="$runtime_root/toolchains"
toolchains_input="${AVPPLAY_LLVM_TOOLCHAINS_ROOT:-$runtime_toolchains}"
if [[ "$toolchains_input" != /* ]]; then
    echo "AVPPLAY_LLVM_TOOLCHAINS_ROOT must be an absolute path." >&2
    exit 1
fi
mkdir -p "$toolchains_input"
toolchains="$(cd "$toolchains_input" && pwd -P)"
if [[ "$toolchains" != "$runtime_toolchains" ]]; then
    mkdir -p "$runtime_toolchains"
    for name in llvm-project llvm-host-build llvm-ios-build; do
        link="$runtime_toolchains/$name"
        target="$toolchains/$name"
        if [[ -L "$link" ]]; then
            if [[ "$(readlink "$link")" != "$target" ]]; then
                echo "Refusing mismatched toolchain symlink: $link" >&2
                exit 1
            fi
        elif [[ -e "$link" ]]; then
            echo "Refusing to replace existing toolchain path: $link" >&2
            exit 1
        else
            ln -s "$target" "$link"
        fi
    done
fi
llvm_source="$toolchains/llvm-project"
host_build="$toolchains/llvm-host-build"
visionos_build="$toolchains/llvm-ios-build"

if [[ ! -d "$llvm_source/.git" ]]; then
    if [[ -e "$llvm_source" ]]; then
        echo "Refusing to replace non-Git LLVM source path: $llvm_source" >&2
        exit 1
    fi
    staging="$toolchains/.llvm-project-fetch.$$"
    if [[ -e "$staging" ]]; then
        echo "Refusing to reuse existing staging path: $staging" >&2
        exit 1
    fi
    trap 'rm -rf "$staging"' EXIT
    git init "$staging"
    git -C "$staging" remote add origin "$llvm_url"
    git -C "$staging" config remote.origin.promisor true
    git -C "$staging" config remote.origin.partialclonefilter blob:none
    git -C "$staging" -c protocol.version=2 fetch --depth=1 --filter=blob:none origin "$llvm_revision"
    git -C "$staging" checkout --detach FETCH_HEAD
    actual="$(git -C "$staging" rev-parse HEAD)"
    if [[ "$actual" != "$llvm_revision" ]]; then
        echo "Fetched LLVM commit mismatch: expected $llvm_revision, got $actual." >&2
        exit 1
    fi
    mv "$staging" "$llvm_source"
    trap - EXIT
else
    actual="$(git -C "$llvm_source" rev-parse HEAD)"
    if [[ "$actual" != "$llvm_revision" ]]; then
        echo "LLVM source is at $actual, expected locked commit $llvm_revision." >&2
        exit 1
    fi
    if [[ -n "$(git -C "$llvm_source" status --porcelain)" ]]; then
        echo "LLVM source has local changes; refusing to configure a modified source tree." >&2
        exit 1
    fi
fi

if [[ "$mode" == "fetch" ]]; then
    echo "Verified LLVM source at $llvm_revision. No configure or build was run."
    exit 0
fi

for tool in cmake ninja xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool." >&2
        exit 1
    fi
done
if ! xcrun --sdk xros --show-sdk-path >/dev/null 2>&1; then
    echo "The selected Xcode does not provide the xros SDK; install/select full Xcode first." >&2
    exit 1
fi
cmake_version="$(cmake --version | awk 'NR == 1 {print $3}')"
cmake_major="${cmake_version%%.*}"
cmake_minor="${cmake_version#*.}"
cmake_minor="${cmake_minor%%.*}"
if (( cmake_major < 3 || (cmake_major == 3 && cmake_minor < 28) )); then
    echo "CMake 3.28 or newer is required for visionOS system-name support (found $cmake_version)." >&2
    exit 1
fi

# Native host TableGen is required before the cross-target LLVM configure.
# Keep this build tree distinct from the xros target build tree.
cmake -S "$llvm_source/llvm" -B "$host_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD=Native \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF
cmake --build "$host_build" --target llvm-tblgen --parallel
host_tblgen="$host_build/bin/llvm-tblgen"
if [[ ! -x "$host_tblgen" ]]; then
    echo "Host TableGen bootstrap did not produce $host_tblgen." >&2
    exit 1
fi

# Reconstructs Madeira's recorded LLVM cache and retargets iOS 17 to visionOS
# 27. `LLVM_NATIVE_TOOL_DIR` prevents target configuration from attempting to
# execute an xros TableGen binary on the build host.
cmake -S "$llvm_source/llvm" -B "$visionos_build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_HOST_TRIPLE=arm64-apple-xros27.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-xros27.0 \
    -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_NATIVE_TOOL_DIR="$host_build/bin" \
    -DLLVM_TABLEGEN="$host_tblgen"

if [[ "$mode" == "build" ]]; then
    cmake --build "$visionos_build" --parallel
    shopt -s nullglob
    archives=("$visionos_build/lib/"*.a)
    if (( ${#archives[@]} == 0 )); then
        echo "LLVM build produced no static archives under $visionos_build/lib." >&2
        exit 1
    fi
    echo "LLVM visionOS archives built at $visionos_build/lib. Tests were not run."
else
    echo "LLVM source verified, host llvm-tblgen built, and xros build configured. No visionOS LLVM libraries were built."
fi

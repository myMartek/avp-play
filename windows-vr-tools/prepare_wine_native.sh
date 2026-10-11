#!/usr/bin/env bash
# Generate Wine's host-side configure headers and tools needed by the
# project-owned xros native source builds. This never starts Wine or a guest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME="${AVPPLAY_RUNTIME_SOURCE:-$ROOT/runtime-source}"
WINE="$RUNTIME/wine"
BUILD="$WINE/build-macos"
JOBS="${AVPPLAY_BUILD_JOBS:-4}"
MINGW_ROOT="${AVPPLAY_LLVM_MINGW_ROOT:-}"

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "AVPPLAY_BUILD_JOBS must be a positive integer." >&2
    exit 2
fi
for tool in make xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing Wine bootstrap tool: $tool" >&2; exit 1; }
done
if ! command -v bison >/dev/null 2>&1 || [[ "$(bison --version | awk 'NR == 1 {print $4}')" != 3.* && "$(bison --version | awk 'NR == 1 {print $4}')" != 4.* ]]; then
    for bison_bin in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin; do
        if [[ -x "$bison_bin/bison" ]]; then
            export PATH="$bison_bin:$PATH"
            break
        fi
    done
fi
command -v bison >/dev/null 2>&1 || { echo "Missing Wine bootstrap tool: Bison 3 or newer." >&2; exit 1; }
bison_version="$(bison --version | awk 'NR == 1 {print $4}')"
bison_major="${bison_version%%.*}"
if [[ ! "$bison_major" =~ ^[0-9]+$ ]] || (( bison_major < 3 )); then
    echo "Wine configure requires Bison 3.0 or newer (found ${bison_version:-unknown})." >&2
    exit 1
fi
if [[ ! -x "$WINE/configure" || ! -f "$WINE/server/Makefile.in" ]]; then
    echo "Pinned Wine source is incomplete under $WINE." >&2
    exit 1
fi
if [[ -n "$MINGW_ROOT" ]]; then
    if [[ "$MINGW_ROOT" != /* || ! -x "$MINGW_ROOT/bin/aarch64-w64-mingw32-clang" ]]; then
        echo "AVPPLAY_LLVM_MINGW_ROOT must contain bin/aarch64-w64-mingw32-clang." >&2
        exit 1
    fi
    export PATH="$MINGW_ROOT/bin:$PATH"
fi
if ! command -v aarch64-w64-mingw32-clang >/dev/null 2>&1; then
    echo "Wine host configure on Apple Silicon requires aarch64-w64-mingw32-clang from the pinned LLVM-MinGW bundle on PATH." >&2
    exit 1
fi

if [[ ! -f "$BUILD/config.status" ]]; then
    # A failed prerequisite check may leave a partial configure tree. Preserve
    # it and rerun configure in place; configure rewrites its generated files.
    mkdir -p "$BUILD"
    (
        cd "$BUILD"
        "$WINE/configure" --without-x --disable-tests --enable-winegstreamer
    )
fi

# Regenerate the top Makefile even if an earlier configure stopped after
# generating config.status but before producing it.
(cd "$BUILD" && ./config.status Makefile)

# Build only host code generators and the WIDL headers needed by the native
# adapter sources. These targets do not invoke wineserver, wineboot, or any
# Windows program.
idl_headers=()
while IFS= read -r header_target; do
    idl_headers+=("$header_target")
done < <(awk '/^include\/[^:]+\.h:/ { sub(/:.*/, ""); print }' "$BUILD/Makefile" | sort -u)
make -C "$BUILD" -j"$JOBS" \
    tools/winebuild/winebuild \
    tools/widl/widl \
    "${idl_headers[@]}" \
    include/dwrite.h \
    include/dwrite_3.h \
    include/mfobjects.h \
    include/mftransform.h \
    include/objidlbase.h \
    include/objidl.h \
    include/propidl.h \
    include/oaidl.h \
    include/oleidl.h \
    include/exdisp.h \
    include/docobj.h \
    include/dcommon.h \
    include/strmif.h \
    include/dxgiformat.h \
    include/amvideo.h \
    include/shldisp.h \
    include/dwrite_2.h \
    include/control.h \
    include/shtypes.h \
    include/dwrite_1.h \
    include/propsys.h \
    include/shobjidl.h \
    include/d2d1.h \
    include/structuredquerycondition.h \
    include/comcat.h \
    include/d3d10_1.h \
    include/mediaobj.h \
    include/objectarray.h \
    include/d3d10.h \
    include/shobjidl_core.h \
    include/dxgi.h \
    include/dxgitype.h \
    include/unknwn.h \
    include/wtypes.h \
    include/wtypesbase.h

required=(
    "$BUILD/include/config.h"
    "$WINE/include/wine/server_protocol.h"
    "$BUILD/tools/winebuild/winebuild"
    "$BUILD/tools/widl/widl"
    "$BUILD/include/dwrite.h"
    "$BUILD/include/dwrite_3.h"
    "$BUILD/include/mfobjects.h"
    "$BUILD/include/mftransform.h"
    "$BUILD/include/objidlbase.h"
    "$BUILD/include/objidl.h"
    "$BUILD/include/propidl.h"
    "$BUILD/include/oaidl.h"
    "$BUILD/include/oleidl.h"
    "$BUILD/include/exdisp.h"
    "$BUILD/include/docobj.h"
    "$BUILD/include/dcommon.h"
    "$BUILD/include/strmif.h"
    "$BUILD/include/dxgiformat.h"
    "$BUILD/include/amvideo.h"
    "$BUILD/include/shldisp.h"
    "$BUILD/include/dwrite_2.h"
    "$BUILD/include/control.h"
    "$BUILD/include/shtypes.h"
    "$BUILD/include/dwrite_1.h"
    "$BUILD/include/propsys.h"
    "$BUILD/include/shobjidl.h"
    "$BUILD/include/d2d1.h"
    "$BUILD/include/structuredquerycondition.h"
    "$BUILD/include/comcat.h"
    "$BUILD/include/d3d10_1.h"
    "$BUILD/include/mediaobj.h"
    "$BUILD/include/objectarray.h"
    "$BUILD/include/d3d10.h"
    "$BUILD/include/shobjidl_core.h"
    "$BUILD/include/dxgi.h"
    "$BUILD/include/dxgitype.h"
    "$BUILD/include/unknwn.h"
    "$BUILD/include/wtypes.h"
    "$BUILD/include/wtypesbase.h"
)
for path in "${required[@]}"; do
    if [[ ! -s "$path" ]]; then
        echo "Wine configure/bootstrap did not produce required generated input: $path" >&2
        exit 1
    fi
done
echo "Wine host configure headers and code generators are ready at $BUILD; no Wine runtime was executed."

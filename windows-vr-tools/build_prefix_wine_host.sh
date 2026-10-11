#!/usr/bin/env bash
# Build the pinned Madeira Wine host loader for the local clean-prefix task.
# This compiles Wine and the selected 64-bit Windows modules. It does not create a prefix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MADEIRA="${AVPPLAY_MADEIRA_SOURCE_ROOT:-/private/tmp/avp-play-build-sources/madeira}"
BUILD_ROOT="${AVPPLAY_PREFIX_BUILD_ROOT:-/private/tmp/avp-play-builds/prefix-wine-host}"
SOURCE_ROOT="$BUILD_ROOT/wine-source"
BUILD="$BUILD_ROOT/build"
LLVM_ROOT="${AVPPLAY_LLVM_MINGW_ROOT:-/private/tmp/avp-play-build-sources/llvm-mingw-20260421-ucrt-macos-universal}"
JOBS="${AVPPLAY_BUILD_JOBS:-4}"
HOST_ARCH="${AVPPLAY_PREFIX_HOST_ARCH:-arm64}"
PATCH_FILE="$ROOT/windows-vr-tools/patches/0001-prefix-host-optional-ios-hooks.patch"

case "$HOST_ARCH" in
    arm64)
        HOST_TRIPLE="aarch64-apple-darwin"
        PE_TRIPLE="aarch64-windows"
        PE_COMPILER="aarch64-w64-mingw32-clang"
        CONFIGURE_ARGS=(--without-x --disable-tests)
        ;;
    x86_64)
        # Configure this as a cross build from the Apple Silicon build tools.
        # Wine's native ARM64 build supplies the host tools required by that mode.
        HOST_TRIPLE="x86_64-apple-darwin"
        PE_TRIPLE="x86_64-windows"
        PE_COMPILER="x86_64-w64-mingw32-clang"
        NATIVE_WINE_TOOLS="${AVPPLAY_PREFIX_NATIVE_WINE_TOOLS:-/private/tmp/avp-play-builds/prefix-wine-host-fixed/build}"
        [[ -x "$NATIVE_WINE_TOOLS/tools/winebuild/winebuild" && -x "$NATIVE_WINE_TOOLS/tools/widl/widl" ]] || {
            echo "x86_64 cross configure needs native Wine tools at $NATIVE_WINE_TOOLS" >&2; exit 1;
        }
        CONFIGURE_ARGS=(--build=aarch64-apple-darwin --host=x86_64-apple-darwin --enable-win64
                        --with-wine-tools="$NATIVE_WINE_TOOLS" --without-x --without-freetype --disable-tests)
        ;;
    *) echo "AVPPLAY_PREFIX_HOST_ARCH must be arm64 or x86_64." >&2; exit 2 ;;
esac

[[ "$MADEIRA" == /* && "$BUILD_ROOT" == /* && "$LLVM_ROOT" == /* ]] || {
    echo "Madeira, build, and LLVM paths must be absolute." >&2; exit 2;
}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "AVPPLAY_BUILD_JOBS must be a positive integer." >&2; exit 2; }
[[ -x "$LLVM_ROOT/bin/$PE_COMPILER" ]] || {
    echo "Pinned llvm-mingw bundle is missing its $PE_TRIPLE compiler: $LLVM_ROOT" >&2; exit 1;
}

expected_madeira="$(python3 - "$ROOT/windows-vr-tools/sources.lock.json" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(item["revision"] for item in lock["sources"] if item["name"] == "madeira"))
PY
)"
actual_madeira="$(git -C "$MADEIRA" rev-parse HEAD)"
expected_wine="$(git -C "$MADEIRA" ls-tree HEAD wine | awk '{print $3}')"
actual_wine="$(git -C "$MADEIRA/wine" rev-parse HEAD)"
[[ "$actual_madeira" == "$expected_madeira" && "$actual_wine" == "$expected_wine" ]] || {
    echo "Madeira or Wine source does not match its pinned source revisions." >&2; exit 1;
}

mkdir -p "$BUILD_ROOT"
if [[ ! -d "$SOURCE_ROOT" ]]; then
    cp -R "$MADEIRA/wine" "$SOURCE_ROOT"
    patch -p1 -d "$SOURCE_ROOT" < "$PATCH_FILE"
elif [[ ! -f "$SOURCE_ROOT/.prefix-overlay-receipt.json" ]]; then
    echo "Existing Wine source copy lacks an overlay receipt; choose a fresh build root." >&2; exit 1;
fi
[[ -f "$SOURCE_ROOT/configure" ]] || { echo "Wine source copy is incomplete: $SOURCE_ROOT" >&2; exit 1; }

# Madeira's pinned Wine source has two explicit relative includes for this
# project-owned config header. Keep the Wine checkout untouched and place the
# exact pinned header in the corresponding location inside the private copy.
MADEIRA_CFG="$MADEIRA/build/madeira_cfg.h"
OVERLAY_CFG="$BUILD_ROOT/build/madeira_cfg.h"
[[ -f "$MADEIRA_CFG" ]] || { echo "Pinned Madeira config header is missing: $MADEIRA_CFG" >&2; exit 1; }
mkdir -p "$BUILD_ROOT/build"
if [[ ! -f "$OVERLAY_CFG" ]]; then
    cp "$MADEIRA_CFG" "$OVERLAY_CFG"
fi
cmp -s "$MADEIRA_CFG" "$OVERLAY_CFG" || {
    echo "Wine overlay config header differs from pinned Madeira input." >&2; exit 1;
}
python3 - "$SOURCE_ROOT/.prefix-overlay-receipt.json" "$PATCH_FILE" "$MADEIRA_CFG" "$expected_wine" <<'PY'
import hashlib, json, pathlib, sys
out, patch, cfg, wine_rev = sys.argv[1:]
def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
payload = {"wineSourceRevision": wine_rev, "optionalHookOverlaySha256": sha(patch),
           "madeiraConfigHeaderSha256": sha(cfg)}
path = pathlib.Path(out)
if path.exists():
    if json.loads(path.read_text(encoding="utf-8")) != payload:
        raise SystemExit("Existing Wine overlay receipt does not match pinned inputs.")
else:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/opt/bison/bin:$LLVM_ROOT/bin:$PATH"
command -v xcrun >/dev/null 2>&1 || { echo "Xcode command line tools are unavailable." >&2; exit 1; }
command -v bison >/dev/null 2>&1 || { echo "Bison is unavailable." >&2; exit 1; }
bison_version="$(bison --version | awk 'NR == 1 {print $4}')"
[[ "$bison_version" == 3.* ]] || { echo "Wine host configure requires Bison 3.x; found $bison_version." >&2; exit 1; }

mkdir -p "$BUILD"
if [[ ! -f "$BUILD/config.status" || ! -f "$BUILD/Makefile" ]]; then
    (
        cd "$BUILD"
        if [[ "$HOST_ARCH" == x86_64 ]]; then
            CC="xcrun clang -arch x86_64" CXX="xcrun clang++ -arch x86_64" \
                "$SOURCE_ROOT/configure" "${CONFIGURE_ARGS[@]}"
        else
            "$SOURCE_ROOT/configure" "${CONFIGURE_ARGS[@]}"
        fi
    ) 2>&1 | tee "$BUILD_ROOT/configure.log"
fi

make -C "$BUILD" -j"$JOBS" 2>&1 | tee "$BUILD_ROOT/build.log"
if [[ "$HOST_ARCH" == x86_64 ]]; then
    HOST_WINE="$BUILD/loader/wine"
else
    HOST_WINE="$BUILD/wine"
fi
[[ -x "$HOST_WINE" && -x "$BUILD/programs/wineboot/$PE_TRIPLE/wineboot.exe" ]] || {
    echo "Wine build did not produce the $HOST_ARCH host loader and $PE_TRIPLE wineboot.exe." >&2; exit 1;
}

if [[ -e "$BUILD/wineboot" || -L "$BUILD/wineboot" ]]; then
    actual_launcher="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BUILD/wineboot")"
    expected_launcher="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOST_WINE")"
    if [[ "$actual_launcher" != "$expected_launcher" && "$HOST_ARCH" == x86_64 && -L "$BUILD/wineboot" && \
          "$actual_launcher" == "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BUILD/wine")" ]]; then
        rm "$BUILD/wineboot"
        ln -s "${HOST_WINE#"$BUILD/"}" "$BUILD/wineboot"
    elif [[ "$actual_launcher" != "$expected_launcher" ]]; then
        echo "Refusing to replace an existing non-matching wineboot launcher." >&2; exit 1;
    fi
else
    ln -s "${HOST_WINE#"$BUILD/"}" "$BUILD/wineboot"
fi

wine_version="$("$HOST_WINE" --version)"
python3 - "$BUILD_ROOT/wine-host-build-receipt.json" "$MADEIRA" "$expected_madeira" "$actual_wine" \
    "$BUILD" "$PATCH_FILE" "$MADEIRA_CFG" "$wine_version" "$HOST_ARCH" "$PE_TRIPLE" <<'PY'
import hashlib, json, os, pathlib, sys
out, madeira, madeira_rev, wine_rev, build, patch, madeira_cfg, version, host_arch, pe_triple = sys.argv[1:]
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()
host_arch = host_arch
wine = os.path.realpath(os.path.join(build, "loader", "wine") if host_arch == "x86_64" else os.path.join(build, "wine"))
payload = {
    "schemaVersion": 1,
    "madeiraRevision": madeira_rev,
    "wineSourceRevision": wine_rev,
    "sourcePath": madeira,
    "hostBuildRoot": os.path.realpath(build),
    "hostArchitecture": host_arch,
    "windowsArchitecture": pe_triple,
    "buildCommand": "make -j${AVPPLAY_BUILD_JOBS:-4}",
    "optionalHookOverlay": "windows-vr-tools/patches/0001-prefix-host-optional-ios-hooks.patch",
    "optionalHookOverlaySha256": sha(patch),
    "madeiraConfigHeaderSha256": sha(madeira_cfg),
    "wineVersion": version.strip(),
    "wineBinary": wine,
    "wineBinarySha256": sha(wine),
    "winebootBinary": os.path.realpath(os.path.join(build, "programs", "wineboot", pe_triple, "wineboot.exe")),
}
payload["configureCommand"] = (
    "CC='xcrun clang -arch x86_64' CXX='xcrun clang++ -arch x86_64' wine/configure --build=aarch64-apple-darwin --host=x86_64-apple-darwin --enable-win64 --with-wine-tools="
    + os.environ.get("AVPPLAY_PREFIX_NATIVE_WINE_TOOLS", "/private/tmp/avp-play-builds/prefix-wine-host-fixed/build")
    + " --without-x --without-freetype --disable-tests"
    if host_arch == "x86_64" else "wine/configure --without-x --disable-tests"
)
payload["configureArguments"] = ( ["--build=aarch64-apple-darwin", "--host=x86_64-apple-darwin", "--enable-win64", "--with-wine-tools=" + os.environ.get("AVPPLAY_PREFIX_NATIVE_WINE_TOOLS", "/private/tmp/avp-play-builds/prefix-wine-host-fixed/build"), "--without-x", "--without-freetype", "--disable-tests"]
    if host_arch == "x86_64" else ["--without-x", "--disable-tests"] )
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
echo "Pinned $HOST_ARCH host Wine build is ready at $BUILD; no prefix, test, or game was run by this build helper."

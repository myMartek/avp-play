#!/usr/bin/env bash
# Build a clean prefix archive by running Madeira's pinned snapshot script with
# the matching Wine host tools, then record verifiable archive provenance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MADEIRA="${AVPPLAY_MADEIRA_SOURCE_ROOT:-/private/tmp/avp-play-build-sources/madeira}"
BUILD_ROOT="${AVPPLAY_PREFIX_BUILD_ROOT:-/private/tmp/avp-play-builds/prefix-wine-host}"
WINE_BUILD_ROOT="${AVPPLAY_PREFIX_WINE_BUILD_ROOT:-$BUILD_ROOT/build}"
OUTPUT_ROOT="${AVPPLAY_PREFIX_OUTPUT_ROOT:-$BUILD_ROOT/artifact}"
WINE_BIN="${AVPPLAY_PREFIX_WINE_BIN:-}"
WINEBOOT_BIN="${AVPPLAY_PREFIX_WINEBOOT_BIN:-}"
SNAPSHOT_SCRIPT="$MADEIRA/tools/build-prefix-snapshot.sh"

for value in "$MADEIRA" "$BUILD_ROOT" "$WINE_BUILD_ROOT" "$OUTPUT_ROOT"; do
    [[ "$value" == /* ]] || { echo "All prefix source/build/output paths must be absolute." >&2; exit 2; }
done
[[ -x "$WINE_BIN" ]] || { echo "Set AVPPLAY_PREFIX_WINE_BIN to the built, pinned Wine host executable." >&2; exit 2; }
[[ -x "$WINEBOOT_BIN" ]] || { echo "Set AVPPLAY_PREFIX_WINEBOOT_BIN to the wineboot launcher from that Wine build." >&2; exit 2; }
[[ -f "$SNAPSHOT_SCRIPT" ]] || { echo "Pinned Madeira prefix script is missing: $SNAPSHOT_SCRIPT" >&2; exit 1; }

expected_madeira="$(python3 - "$ROOT/windows-vr-tools/sources.lock.json" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(item["revision"] for item in lock["sources"] if item["name"] == "madeira"))
PY
)"
actual_madeira="$(git -C "$MADEIRA" rev-parse HEAD)"
expected_wine="$(git -C "$MADEIRA" ls-tree HEAD wine | awk '{print $3}')"
actual_wine="$(git -C "$MADEIRA/wine" rev-parse HEAD)"
[[ "$actual_madeira" == "$expected_madeira" ]] || { echo "Madeira source is not at the locked revision $expected_madeira." >&2; exit 1; }
[[ -n "$expected_wine" && "$actual_wine" == "$expected_wine" ]] || { echo "Wine submodule does not match the pinned Madeira gitlink." >&2; exit 1; }
BUILD_RECEIPT="$BUILD_ROOT/wine-host-build-receipt.json"
[[ -s "$BUILD_RECEIPT" ]] || { echo "Missing receipt from the pinned host-Wine build: $BUILD_RECEIPT" >&2; exit 1; }

mkdir -p "$BUILD_ROOT" "$OUTPUT_ROOT"
for artifact in "$OUTPUT_ROOT/prefix-template.tar.gz" "$OUTPUT_ROOT/prefix-template-provenance.json"; do
    [[ ! -e "$artifact" && ! -L "$artifact" ]] || { echo "Refusing to overwrite existing prefix artifact: $artifact" >&2; exit 1; }
done

wine_version="$("$WINE_BIN" --version)"
[[ -n "${wine_version//[[:space:]]/}" ]] || { echo "Wine did not report a version." >&2; exit 1; }
wine_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WINE_BIN")"
wineboot_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WINEBOOT_BIN")"
[[ "$wine_real" == "$wineboot_real" ]] || { echo "Wine and wineboot must resolve to the same pinned host loader." >&2; exit 1; }
wine_build_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$WINE_BUILD_ROOT")"
[[ "$wine_real" == "$wine_build_real/"* ]] || { echo "Wine must be built inside AVPPLAY_PREFIX_WINE_BUILD_ROOT; system Wine installations are not accepted." >&2; exit 1; }
python3 - "$BUILD_RECEIPT" "$wine_real" "$wine_version" "$actual_wine" \
    "$ROOT/windows-vr-tools/patches/0001-prefix-host-optional-ios-hooks.patch" <<'PY'
import hashlib, json, os, pathlib, sys
receipt_path, wine_path, version, wine_revision, overlay_path = sys.argv[1:]
receipt=json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))
def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""): h.update(block)
    return h.hexdigest()
if (receipt.get("schemaVersion") != 1
    or receipt.get("wineSourceRevision") != wine_revision
    or receipt.get("wineBinary") != os.path.realpath(wine_path)
    or receipt.get("wineVersion") != version.strip()
    or receipt.get("wineBinarySha256") != sha(wine_path)
    or receipt.get("optionalHookOverlaySha256") != sha(overlay_path)):
    raise SystemExit("Host Wine binary does not match its pinned source build receipt.")
PY

INVOCATION="$OUTPUT_ROOT/upstream-invocation"
mkdir "$INVOCATION"
mkdir -p "$INVOCATION/tools" "$INVOCATION/app/Madeira"
cp "$SNAPSHOT_SCRIPT" "$INVOCATION/tools/build-prefix-snapshot.sh"
cmp -s "$SNAPSHOT_SCRIPT" "$INVOCATION/tools/build-prefix-snapshot.sh" || { echo "Could not preserve the pinned prefix script byte-for-byte." >&2; exit 1; }

echo "Running pinned Madeira prefix creation script with $wine_version"
(
    cd "$INVOCATION"
    WINE="$WINE_BIN" WINEBOOT="$WINEBOOT_BIN" \
        bash tools/build-prefix-snapshot.sh
) 2>&1 | tee "$OUTPUT_ROOT/prefix-creation.log"

GENERATED="$INVOCATION/app/Madeira/prefix-template.tar.gz"
[[ -s "$GENERATED" ]] || { echo "Pinned snapshot script did not produce a nonempty prefix archive." >&2; exit 1; }
python3 "$ROOT/windows-vr-tools/sanitize_prefix_snapshot.py" \
    --source "$GENERATED" --output "$OUTPUT_ROOT/prefix-template.tar.gz" \
    --receipt "$OUTPUT_ROOT/prefix-portability-receipt.json"

python3 - "$SNAPSHOT_SCRIPT" "$OUTPUT_ROOT/prefix-template.tar.gz" "$OUTPUT_ROOT/prefix-template-provenance.json" \
    "$expected_madeira" "$actual_wine" "$wine_version" "$WINE_BIN" "$WINEBOOT_BIN" "$wine_real" "$wineboot_real" "$BUILD_RECEIPT" "$OUTPUT_ROOT/prefix-portability-receipt.json" <<'PY'
import hashlib, json, os, pathlib, platform, sys
script, archive, out, madeira, wine_rev, version, wine, wineboot, wine_real, wineboot_real, build_receipt, portability = sys.argv[1:]
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()
payload = {
    "schemaVersion": 1,
    "originUrl": "https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/tools/build-prefix-snapshot.sh",
    "madeiraRevision": madeira,
    "wineSourceRevision": wine_rev,
    "templateSha256": sha(archive),
    "creationCommand": "bash tools/build-prefix-snapshot.sh",
    "wineExecuted": True,
    "wineVersion": version.strip(),
    "wineBinary": str(pathlib.Path(wine).absolute()),
    "wineBinaryResolved": wine_real,
    "winebootBinary": str(pathlib.Path(wineboot).absolute()),
    "winebootBinaryResolved": wineboot_real,
    "snapshotScriptSha256": sha(script),
    "hostArchitecture": platform.machine(),
    "archiveSha256": sha(archive),
    "wineHostBuildReceiptSha256": sha(build_receipt),
    "postProcessing": json.loads(pathlib.Path(portability).read_text()),
    "wineHostArchitecture": json.loads(pathlib.Path(build_receipt).read_text()).get("hostArchitecture"),
    "initializationEnvironmentOverrides": {"WINEDLLOVERRIDES": os.environ.get("WINEDLLOVERRIDES", "")},
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 "$ROOT/windows-vr-tools/resource_receipt.py" validate-prefix \
    --template "$OUTPUT_ROOT/prefix-template.tar.gz" \
    --provenance "$OUTPUT_ROOT/prefix-template-provenance.json"
echo "Created Wine-generated prefix archive and provenance under $OUTPUT_ROOT"

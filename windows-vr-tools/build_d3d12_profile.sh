#!/usr/bin/env bash
# Build the pinned visionOS-native DXMT closure and matching ARM64EC Wine DLLs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="${AVPPLAY_D3D12_PROFILE_SOURCE:-$ROOT/runtime-source-d3d12-experimental}"
MADEIRA="${AVPPLAY_RUNTIME_SOURCE:-$ROOT/runtime-source}"
BUILD_ROOT="${AVPPLAY_D3D12_BUILD_ROOT:-${AVPPLAY_BUILD_ROOT:-}}"

[[ "${AVPPLAY_ALLOW_RUNTIME_BUILD:-0}" == "1" && "${AVPPLAY_ENABLE_D3D12:-0}" == "1" ]] || {
    echo "Set AVPPLAY_ALLOW_RUNTIME_BUILD=1 and AVPPLAY_ENABLE_D3D12=1 to build D3D12." >&2; exit 1;
}
[[ -d "$PROFILE/dxmt" && -f "$PROFILE/AVPPLAY_D3D12_SOURCE_PROVENANCE.json" ]] || {
    echo "Prepare the pinned D3D12 profile first: $PROFILE" >&2; exit 1;
}
[[ -f "$PROFILE/AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json" ]] || {
    echo "Missing applied-source adaptation receipt; prepare a fresh D3D12 profile." >&2; exit 1;
}
[[ "$BUILD_ROOT" == /* && -d "$BUILD_ROOT" ]] || {
    echo "Set AVPPLAY_D3D12_BUILD_ROOT (or AVPPLAY_BUILD_ROOT) to an existing absolute build directory." >&2; exit 1;
}
for tool in xcrun meson ninja python3 git; do command -v "$tool" >/dev/null 2>&1 || { echo "Missing D3D12 build tool: $tool" >&2; exit 1; }; done
xcrun --sdk xros --show-sdk-path >/dev/null

NATIVE_SOURCE="$PROFILE/dxmt"
NATIVE_BUILD="$BUILD_ROOT/dxmt-d3d12-meson"
NATIVE_FILE="$BUILD_ROOT/dxmt-d3d12-xros-native.ini"
LLVM_SOURCE="$MADEIRA/toolchains/llvm-project"
LLVM_BUILD="$MADEIRA/toolchains/llvm-ios-build"
WINE_BUILD="$MADEIRA/wine/build-arm64ec"
GUEST_FARM="$PROFILE/app/Madeira/arm64ec-windows"
NATIVE_ARCHIVE="$PROFILE/app/Madeira/libdxmt_d3d12_combined.a"
BUILD_RECEIPT="$PROFILE/AVPPLAY_D3D12_BUILD_RECEIPT.json"

[[ -d "$LLVM_SOURCE/llvm" && -d "$LLVM_BUILD/include" && -d "$LLVM_BUILD/lib" ]] || {
    echo "Build the locked visionOS LLVM dependency with prepare_llvm.sh build first." >&2; exit 1;
}
[[ -d "$WINE_BUILD" ]] || { echo "Missing pinned Wine ARM64EC build tree: $WINE_BUILD" >&2; exit 1; }
[[ -f "$NATIVE_SOURCE/build-arm64ec.txt" ]] || {
    echo "Pinned DXMT source lacks its ARM64EC Meson cross file: $NATIVE_SOURCE/build-arm64ec.txt" >&2; exit 1;
}
[[ -n "${AVPPLAY_LLVM_MINGW_ROOT:-}" && "$AVPPLAY_LLVM_MINGW_ROOT" == /* ]] || {
    echo "Set AVPPLAY_LLVM_MINGW_ROOT to the pinned LLVM-MinGW bundle root." >&2; exit 1;
}
for tool in arm64ec-w64-mingw32-gcc arm64ec-w64-mingw32-g++ arm64ec-w64-mingw32-ar arm64ec-w64-mingw32-strip arm64ec-w64-mingw32-windres; do
    [[ -x "$AVPPLAY_LLVM_MINGW_ROOT/bin/$tool" ]] || { echo "LLVM-MinGW lacks $tool." >&2; exit 1; }
done
[[ ! -e "$NATIVE_BUILD" && ! -e "$NATIVE_FILE" && ! -e "$NATIVE_ARCHIVE" && ! -e "$BUILD_RECEIPT" ]] || {
    echo "D3D12 build output exists; choose a fresh AVPPLAY_D3D12_BUILD_ROOT and profile. No existing archive is reused." >&2; exit 1;
}
for dll in d3d11.dll d3d12.dll dxgi.dll winemetal.dll; do
    [[ ! -e "$GUEST_FARM/$dll" ]] || { echo "Refusing to replace existing profile DLL: $GUEST_FARM/$dll" >&2; exit 1; }
done
python3 - "$ROOT" "$PROFILE" <<'PY'
import hashlib, json, pathlib, sys
root, profile = map(pathlib.Path, sys.argv[1:])
source_path=profile/"AVPPLAY_D3D12_SOURCE_PROVENANCE.json"
adaptation_path=profile/"AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json"
source=json.loads(source_path.read_text(encoding="utf-8")); adaptation=json.loads(adaptation_path.read_text(encoding="utf-8"))
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if source.get("profileId") != "dxmt-d3d12-experimental-e94c312f5c054263acf261cfa109edf13e757587": raise SystemExit("Unexpected D3D12 source profile pin.")
if adaptation.get("sourceProvenanceSha256") != sha(source_path) or adaptation.get("nativeSourceTreeSha256") != source.get("nativeSourceTreeSha256"): raise SystemExit("D3D12 native adaptation receipt is stale.")
for name, expected in source.get("integrationInputsSha256", {}).items():
    if sha(root/name) != expected: raise SystemExit(f"D3D12 profile input changed after preparation: {name}")
h=hashlib.sha256()
for path in sorted((profile/"dxmt").rglob("*")):
    if not path.is_file() or ".git" in path.parts: continue
    rel=path.relative_to(profile/"dxmt").as_posix().encode(); h.update(len(rel).to_bytes(8,"big")); h.update(rel); h.update(path.stat().st_size.to_bytes(8,"big"))
    with path.open("rb") as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b""): h.update(chunk)
if h.hexdigest() != source.get("nativeSourceTreeSha256"): raise SystemExit("D3D12 source tree changed after preparation.")
PY
mkdir -p "$BUILD_ROOT" "$GUEST_FARM" "$PROFILE/app/Madeira" "$BUILD_ROOT/d3d12-generated"
export PATH="$AVPPLAY_LLVM_MINGW_ROOT/bin:$PATH"

cat > "$NATIVE_FILE" <<MESON
[binaries]
c = ['xcrun', '--sdk', 'xros', 'clang']
cpp = ['xcrun', '--sdk', 'xros', 'clang++']
ar = ['xcrun', '--sdk', 'xros', 'ar']
strip = ['xcrun', '--sdk', 'xros', 'strip']

[properties]
sys_root = 'xros'
needs_exe_wrapper = true

[built-in options]
c_args = ['-target', 'arm64-apple-xros27.0', '-DDXMT_VISIONOS=1', '-D__wine_unix_call_funcs=dxmt_winemetal_unix_call_funcs', '-D__wine_unix_call_wow64_funcs=dxmt_winemetal_unix_call_wow64_funcs']
cpp_args = ['-target', 'arm64-apple-xros27.0', '-DDXMT_VISIONOS=1', '-I$BUILD_ROOT/d3d12-generated', '-D__wine_unix_call_funcs=dxmt_winemetal_unix_call_funcs', '-D__wine_unix_call_wow64_funcs=dxmt_winemetal_unix_call_wow64_funcs']
c_link_args = ['-target', 'arm64-apple-xros27.0']
cpp_link_args = ['-target', 'arm64-apple-xros27.0']
MESON

# One Meson graph gives the guest PE targets the pinned LLVM-MinGW cross-file
# and gives native targets the xros compiler. Source lists and object commands
# are discovered from this revision's own Meson introspection/compile database.
meson setup "$NATIVE_BUILD" "$NATIVE_SOURCE" \
    --cross-file="$NATIVE_SOURCE/build-arm64ec.txt" \
    --native-file="$NATIVE_FILE" \
    -Dbuildtype=release \
    -Dwine_build_path="$WINE_BUILD" \
    -Dnative_llvm_path="$LLVM_BUILD" \
    -Denable_d3d12=true \
    -Dvisionos_native=true \
    -Dbuild_airconv_for_windows=false \
    -Denable_tests=false

python3 - "$NATIVE_BUILD" "$NATIVE_SOURCE" "$NATIVE_ARCHIVE" "$GUEST_FARM" "$LLVM_BUILD" "$BUILD_RECEIPT" "$PROFILE" "$MADEIRA" "$ROOT" <<'PY'
import hashlib, json, os, pathlib, shlex, shutil, subprocess, sys
build, source, archive, guest, llvm_build, receipt_path, profile, madeira, root = map(pathlib.Path, sys.argv[1:])

def run(args, **kwargs): subprocess.run(args, check=True, **kwargs)
def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""): h.update(chunk)
    return h.hexdigest()
def regular(path, label):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size: raise SystemExit(f"Missing/nonempty {label}: {path}")
def target_outputs(target):
    values = []
    for key in ("filename", "outputs"):
        value = target.get(key, [])
        values.extend(value if isinstance(value, list) else [value])
    return [str(v) for v in values if v]
def target_sources(target):
    values = []
    for group in target.get("target_sources", []):
        values.extend(group.get("sources", []))
    paths = []
    for item in values:
        path = pathlib.Path(item)
        if not path.is_absolute(): path = source / path
        paths.append(path.resolve())
    return paths
def discover_targets():
    raw = subprocess.check_output(["meson", "introspect", "--targets", str(build)], text=True)
    targets = json.loads(raw)
    def has_output(target, basename):
        return any(pathlib.PurePath(value).name == basename for value in target_outputs(target))
    airconv = [t for t in targets if t.get("type") == "static library" and has_output(t, "libairconv.a")]
    parser = [t for t in targets if t.get("type") == "static library" and has_output(t, "libDXBCParserNative.a")]
    if len(airconv) != 1 or len(parser) != 1:
        raise SystemExit("Meson did not expose exactly one native libairconv.a and libDXBCParserNative.a for this profile.")
    unix_targets = [t for t in targets if any("/src/winemetal/unix/" in p.as_posix() for p in target_sources(t))]
    unix_sources = sorted({p for t in unix_targets for p in target_sources(t) if p.is_file()})
    if not unix_sources:
        raise SystemExit("Meson introspection found no winemetal Unix source list in the configured profile.")
    guest_targets = {}
    for dll, source_dir in (("d3d11.dll", "/src/d3d11/"), ("d3d12.dll", "/src/d3d12/"),
                            ("dxgi.dll", "/src/dxgi/"), ("winemetal.dll", "/src/winemetal/")):
        found = [t for t in targets if has_output(t, dll) and any(source_dir in p.as_posix() for p in target_sources(t))]
        if len(found) != 1:
            raise SystemExit(f"Meson did not expose exactly one matching guest target for {dll}.")
        guest_targets[dll] = found[0]
    return targets, airconv[0], parser[0], unix_sources, guest_targets

targets, airconv_target, parser_target, unix_sources, guest_targets = discover_targets()
# Generator outputs are not standalone Meson introspection targets. Read the
# actual Ninja graph and build its exact production-metallib output rule.
ninja_targets=subprocess.check_output(["ninja","-C",str(build),"-t","targets","all"],text=True)
references=[]
for row in ninja_targets.splitlines():
    name=row.rsplit(": ",1)[0]
    if pathlib.PurePath(name).name == "dxmt_command.metallib": references.append(name)
if len(references) != 1: raise SystemExit("Expected one xros production command metallib rule in the pinned graph.")
run(["ninja","-C",str(build),references[0]])
metallib_reference=pathlib.Path(references[0])
if not metallib_reference.is_absolute(): metallib_reference=build/metallib_reference
regular(metallib_reference, "xros-compiled metallib reference")
platform_header = build.parent / "d3d12-generated/wvr_metallib_platform.h"
run([sys.executable, str(root/"windows-vr-openxr/native-d3d12/generate_metallib_platform.py"),
     "--reference", str(metallib_reference), "--output", str(platform_header)])
regular(platform_header, "generated xros metallib metadata header")
# Build the two actual Meson static targets; generators run from this graph.
for target in (airconv_target, parser_target):
    outputs=target_outputs(target)
    if not outputs: raise SystemExit("Native Meson target has no output.")
    output=pathlib.Path(outputs[0]); output=output if output.is_absolute() else build/output
    run(["ninja", "-C", str(build), output.relative_to(build).as_posix()])

compile_db = json.loads((build / "compile_commands.json").read_text(encoding="utf-8"))
needed = {p.resolve() for p in unix_sources}
object_paths = []
compiled_sources = set()
for entry in compile_db:
    source_file = pathlib.Path(entry["file"])
    if not source_file.is_absolute(): source_file = pathlib.Path(entry["directory"]) / source_file
    source_file = source_file.resolve()
    if source_file not in needed: continue
    argv = entry.get("arguments") or shlex.split(entry["command"])
    if "arm64-apple-xros27.0" not in " ".join(argv): continue
    run(argv, cwd=entry["directory"])
    try: out = pathlib.Path(argv[argv.index("-o") + 1])
    except (ValueError, IndexError): raise SystemExit(f"Meson compiler command has no output object for {source_file}.")
    if not out.is_absolute(): out = pathlib.Path(entry["directory"]) / out
    regular(out, "native winemetal object")
    object_paths.append(out); compiled_sources.add(source_file)
if compiled_sources != needed:
    missing = sorted(str(p) for p in needed - compiled_sources)
    raise SystemExit("Missing xros Meson compile commands for native winemetal sources: " + ", ".join(missing))

def output_path(target, basename):
    candidates = [pathlib.Path(value) for value in target_outputs(target) if pathlib.PurePath(value).name == basename]
    if len(candidates) != 1: raise SystemExit(f"Meson target {target.get('name')} has no unique {basename} output.")
    path = candidates[0]
    return path if path.is_absolute() else build / path
archives = [output_path(airconv_target, "libairconv.a"), output_path(parser_target, "libDXBCParserNative.a")]
for path in archives: regular(path, "native Meson compiler archive")
llvm_archives = sorted((llvm_build / "lib").glob("*.a"))
if not llvm_archives: raise SystemExit(f"No archives in the locked visionOS LLVM build: {llvm_build / 'lib'}")
archive.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["xcrun", "--sdk", "xros", "libtool", "-static", "-o", str(archive),
                *map(str, object_paths), *map(str, archives), *map(str, llvm_archives)], check=True)
regular(archive, "combined native DXMT archive")

# Build all four PE modules from this exact modern DXMT Meson graph.
for dll in ("d3d11.dll", "d3d12.dll", "dxgi.dll", "winemetal.dll"):
    output=output_path(guest_targets[dll],dll)
    run(["ninja", "-C", str(build), output.relative_to(build).as_posix()])
    post=[t for t in targets if any(pathlib.PurePath(v).name == dll+".postproc" for v in target_outputs(t))]
    if len(post) != 1: raise SystemExit(f"Missing unique Wine builtin postprocessor for {dll}.")
    output=output_path(post[0],dll+".postproc")
    run(["ninja", "-C", str(build), output.relative_to(build).as_posix()])
for dll, target in guest_targets.items():
    source_file = output_path(target, dll)
    regular(source_file, f"ARM64EC {dll}")
    shutil.copy2(source_file, guest / dll)
    regular(guest / dll, f"copied ARM64EC {dll}")

# The profile's exported table names/count are checked from the artifact, not
# copied from a declarative readiness flag. These are symbol reads, not execution.
nm = subprocess.check_output(["xcrun", "--sdk", "xros", "nm", "-gU", str(archive)], text=True)
required_symbols = ("_dxmt_winemetal_unix_call_funcs", "_dxmt_winemetal_unix_call_wow64_funcs",
                    "_wvr_dxmt_d3d12_unix_call_count_v1", "_wvr_dxmt_d3d12_transport_abi_v1")
missing_symbols = [symbol for symbol in required_symbols if symbol not in nm]
if missing_symbols: raise SystemExit("Native archive is missing dispatch exports: " + ", ".join(missing_symbols))
sys.path.insert(0, str(root / "windows-vr-tools"))
from stage_resources import pe_machine
for dll in guest.glob("*.dll"):
    if pe_machine(dll) != 0xA641: raise SystemExit(f"Expected ARM64EC PE machine 0xA641: {dll}")

source_receipt_path = profile / "AVPPLAY_D3D12_SOURCE_PROVENANCE.json"
adaptation_path = profile / "AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json"
source_receipt = json.loads(source_receipt_path.read_text(encoding="utf-8"))
adaptation = json.loads(adaptation_path.read_text(encoding="utf-8"))
if source_receipt.get("unixCallTable", {}).get("expectedEntryCount") != 148:
    raise SystemExit("D3D12 profile dispatch table count does not match the native loader's 148-entry contract.")
def profile_source_hash(directory):
    h = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or ".git" in path.parts: continue
        rel = path.relative_to(directory).as_posix().encode(); h.update(len(rel).to_bytes(8, "big")); h.update(rel)
        h.update(path.stat().st_size.to_bytes(8, "big"))
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""): h.update(chunk)
    return h.hexdigest()
actual_tree_hash = profile_source_hash(profile / "dxmt")
if actual_tree_hash != source_receipt.get("nativeSourceTreeSha256") or actual_tree_hash != adaptation.get("nativeSourceTreeSha256"):
    raise SystemExit("D3D12 source tree changed after the source/adaptation receipts were prepared.")
llvm_lock = json.loads((root / "windows-vr-tools/llvm.lock.json").read_text(encoding="utf-8"))
llvm_source = madeira / "toolchains/llvm-project"
actual_llvm_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=llvm_source, text=True).strip()
if actual_llvm_revision != llvm_lock["revision"]:
    raise SystemExit("LLVM source revision does not match windows-vr-tools/llvm.lock.json.")
llvm_mingw_root = pathlib.Path(os.environ["AVPPLAY_LLVM_MINGW_ROOT"])
llvm_mingw_tools = ("arm64ec-w64-mingw32-gcc", "arm64ec-w64-mingw32-g++", "arm64ec-w64-mingw32-ar", "arm64ec-w64-mingw32-strip", "arm64ec-w64-mingw32-windres")
llvm_mingw_hashes = {name: sha(llvm_mingw_root / "bin" / name) for name in llvm_mingw_tools}
madeira_lock = json.loads((root / "windows-vr-tools/sources.lock.json").read_text(encoding="utf-8"))
madeira_revision = next(s["revision"] for s in madeira_lock["sources"] if s["name"] == "madeira")
artifacts = {"native/libdxmt_d3d12_combined.a": sha(archive)}
for dll in ("d3d11.dll", "d3d12.dll", "dxgi.dll", "winemetal.dll"):
    artifacts[f"guest/arm64ec-windows/{dll}"] = sha(guest / dll)
receipt = {
 "schemaVersion": 1, "profileId": source_receipt["profileId"],
 "sourceProvenanceSha256": sha(source_receipt_path), "nativeAdaptationReceiptSha256": sha(adaptation_path),
 "nativeSourceTreeSha256": actual_tree_hash, "sourceRevision": source_receipt["sourceRevision"],
 "madeiraRevision": madeira_revision, "llvmSourceRevision": actual_llvm_revision,
 "llvmTarget": llvm_lock["target"], "llvmMingwRelease": "20260421", "llvmMingwExpectedReleaseArchiveSha256": "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7", "llvmMingwToolArtifactsSha256": llvm_mingw_hashes,
 "xrosMetallibReferenceSha256": sha(metallib_reference), "xrosMetallibPlatformHeaderSha256": sha(platform_header),
 "nativeArchive": "libdxmt_d3d12_combined.a",
 "unixCallTable": source_receipt["unixCallTable"], "dispatchTableExpectedEntryCount": source_receipt["unixCallTable"]["expectedEntryCount"], "exportedDispatchSymbols": list(required_symbols),
 "transportABI": source_receipt["transportABI"], "artifactsSha256": artifacts,
 "shaderPlatformHeaderSha256": sha(platform_header),
 "buildCommandsCompleted": ["Meson native DXMT targets", "xros archive link", "Meson ARM64EC d3d11/d3d12/dxgi/winemetal targets"],
}
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "Built receipt-backed D3D12 DXMT native archive and ARM64EC guest DLL closure. No Wine guest was run."

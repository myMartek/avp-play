#!/usr/bin/env bash
# Create the pinned modern-DXMT profile while retaining Madeira's runtime tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CACHE="${AVPPLAY_SOURCE_CACHE_ROOT:-$ROOT/third-party}"
BASE="${AVPPLAY_RUNTIME_SOURCE:-$ROOT/runtime-source}"
SOURCE="$CACHE/dxmt-d3d12-experimental"
OUTPUT="${AVPPLAY_D3D12_PROFILE_SOURCE:-$ROOT/runtime-source-d3d12-experimental}"
PATCH="$ROOT/windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch"
[[ "${AVPPLAY_ENABLE_D3D12:-0}" == 1 ]] || { echo "Set AVPPLAY_ENABLE_D3D12=1." >&2; exit 1; }
[[ -f "$BASE/AVPPLAY_SOURCE_PROVENANCE.json" ]] || { echo "Prepare the pinned Madeira overlay first: $BASE" >&2; exit 1; }
[[ -d "$SOURCE/.git" ]] || { echo "Fetch the locked modern DXMT source first." >&2; exit 1; }
[[ -s "$PATCH" ]] || { echo "Missing native source port: $PATCH" >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Profile exists; choose a fresh AVPPLAY_D3D12_PROFILE_SOURCE." >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "$(dirname "$OUTPUT")/.d3d12-profile.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
WORK="$STAGE/profile"
python3 - "$ROOT" "$BASE" "$SOURCE" "$WORK" <<'PY'
import hashlib, json, pathlib, shutil, subprocess, sys
root, base, source, work = map(pathlib.Path, sys.argv[1:])
lock = json.loads((root / "windows-vr-tools/sources.lock.json").read_text(encoding="utf-8"))
def pin(name): return next(x for x in lock["sources"] if x["name"] == name)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def tree_sha(directory):
    h = hashlib.sha256()
    for p in sorted(directory.rglob("*")):
        if not p.is_file() or ".git" in p.parts: continue
        rel = p.relative_to(directory).as_posix().encode(); h.update(len(rel).to_bytes(8,"big")); h.update(rel); h.update(p.stat().st_size.to_bytes(8,"big"))
        with p.open("rb") as f:
            for chunk in iter(lambda:f.read(1024*1024),b""): h.update(chunk)
    return h.hexdigest()
madeira, dxmt = pin("madeira"), pin("dxmt-d3d12-experimental")
rev = subprocess.check_output(["git","rev-parse","HEAD"],cwd=source,text=True).strip()
if rev != dxmt["revision"]: raise SystemExit(f"DXMT source is {rev}; expected {dxmt['revision']}.")
if subprocess.check_output(["git","status","--porcelain","--untracked-files=no"],cwd=source,text=True).strip(): raise SystemExit("Modern DXMT source cache has tracked changes.")
base_prov = json.loads((base/"AVPPLAY_SOURCE_PROVENANCE.json").read_text(encoding="utf-8"))
if base_prov.get("sourceRevision") != madeira["revision"]: raise SystemExit("Madeira baseline source pin mismatch.")
def ignore_base_artifacts(directory, names):
    result=[]
    for name in names:
        path=pathlib.Path(directory)/name
        if name == ".git" or (path.is_dir() and (name == "obj" or name.startswith("build-"))): result.append(name)
        elif path.is_file() and name.endswith((".o", ".a")): result.append(name)
    return result
shutil.copytree(base,work,symlinks=True,ignore=ignore_base_artifacts)
guest_farm=work/"app/Madeira/arm64ec-windows"
if guest_farm.exists(): shutil.rmtree(guest_farm)
guest_farm.mkdir(parents=True)
dest=work/"dxmt"
if dest.exists(): shutil.rmtree(dest)
def ignore_build_artifacts(directory,names):
    ignored=[]
    for name in names:
        path=pathlib.Path(directory)/name
        if name == "obj" and path.is_dir(): ignored.append(name)
        elif name.startswith("build-") and path.is_dir(): ignored.append(name)
        elif name.endswith((".o",".a")) and path.is_file(): ignored.append(name)
    return ignored
shutil.copytree(source,dest,symlinks=True,ignore=ignore_build_artifacts)
patches=[

 "windows-vr-openxr/patches/0002-dxmt-d3d12-wvr-queue.patch",
 "windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch",
 "windows-vr-openxr/patches/0004-dxmt-modern-d3d11-wvr.patch",
 "windows-vr-openxr/patches/0005-dxmt-xros-metallib-target.patch",
 "windows-vr-openxr/patches/0006-dxmt-arm64ec-native-build.patch",
]
subprocess.run(["git","init","--quiet"],cwd=dest,check=True)
for rel in patches:
    path=root/rel
    if not path.is_file() or not path.stat().st_size: raise SystemExit(f"Missing pinned overlay: {path}")
    subprocess.run(["git","apply",str(path)],cwd=dest,check=True)
wine_patch="windows-runtime-plugin/d3d12/0001-embedded-dxmt-dispatch.patch"
subprocess.run(["git","init","--quiet"],cwd=work,check=True)
subprocess.run(["git","apply",str(root/wine_patch)],cwd=work,check=True)
headers=[
 ("windows-vr-openxr/include/WindowsVRD3D11ContextExt.h","src/d3d11/WindowsVRD3D11ContextExt.h"),
 ("windows-vr-openxr/include/WindowsVRD3D12CommandQueueExt.h","src/d3d12/WindowsVRD3D12CommandQueueExt.h"),
 ("windows-vr-openxr/include/WindowsVRD3D11ContextExt.h","src/d3d12/WindowsVRD3D11ContextExt.h"),
 ("windows-vr-openxr/include/WindowsVRWMTBridge.h","src/d3d12/WindowsVRWMTBridge.h"),
 ("windows-vr-openxr/include/WindowsVRWMTBridge.h","src/dxmt/WindowsVRWMTBridge.h"),
 ("windows-vr-openxr/include/WindowsVRWMTBridge.h","src/winemetal/WindowsVRWMTBridge.h"),
 ("windows-vr-native/include/WindowsVRCompositorBridge.h","src/winemetal/WindowsVRCompositorBridge.h"),
 ("windows-vr-native/include/WindowsVRCompositorBridge.h","src/winemetal/unix/WindowsVRCompositorBridge.h"),
 ("windows-vr-ngx/src/WVRMetalFXWMTBridge.h","src/winemetal/unix/WVRMetalFXWMTBridge.h"),
 ("windows-vr-ngx/src/WVRMetalFXWMTBridge.inc","src/winemetal/unix/WVRMetalFXWMTBridge.inc"),
 ("windows-vr-ngx/include/WindowsVRNGX.h","src/nvngx/WindowsVRNGX.h"),
 ("windows-vr-metal/Sources/WindowsVRMetalABI/include/WindowsVRMetalC.h","src/winemetal/unix/WindowsVRMetalC.h"),
]
for src,dst in headers:
    source_path=root/src; target=dest/dst
    if not source_path.is_file(): raise SystemExit(f"Missing shared header: {source_path}")
    target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source_path,target)
llvm=json.loads((root/"windows-vr-tools/llvm.lock.json").read_text(encoding="utf-8"))
inputs=[*patches,wine_patch,*[x for x,_ in headers],"windows-runtime-plugin/WindowsVRRuntimePlugin.mm","native-d3d12/wvr_dxmt_d3d12_native_abi.h","windows-vr-openxr/native-d3d12/generate_metallib_platform.py","windows-vr-openxr/src/WindowsVROpenXR.cpp","windows-vr-openxr/CMakeLists.txt","windows-vr-openvr/patches/0002-direct3d-openxr-build.patch","windows-vr-openvr/CMakeLists.txt","windows-vr-native/Sources/WindowsVRCompositorBridge.mm","windows-vr-tools/sources.lock.json","windows-vr-tools/llvm.lock.json","windows-vr-tools/prepare_d3d12_experimental_source.sh","windows-vr-tools/prepare_d3d12_profile.sh","windows-vr-tools/build_d3d12_experimental.sh","windows-vr-tools/build_d3d12_profile.sh","windows-vr-tools/stage_d3d12_experimental.sh","windows-vr-tools/stage_d3d12_profile.sh","windows-vr-tools/stage_resources.py"]
profile_id=f"dxmt-d3d12-experimental-{dxmt['revision']}"
provenance={"schemaVersion":1,"profileId":profile_id,"sourceUrl":dxmt["url"],"sourceRevision":dxmt["revision"],"madeiraBaselineUrl":madeira["url"],"madeiraBaselineRevision":madeira["revision"],"madeiraOverlayProvenanceSha256":sha(base/"AVPPLAY_SOURCE_PROVENANCE.json"),"llvmSourceUrl":llvm["url"],"llvmSourceRevision":llvm["revision"],"llvmTarget":llvm["target"],"integrationInputsSha256":{x:sha(root/x) for x in inputs},"transportABI":{"wmtRequestABI":1,"wmtSubmitABI":2,"d3d12QueueABI":1},"unixCallTable":{"version":1,"expectedEntryCount":148,"nativeTable":"dxmt_winemetal_unix_call_funcs","wow64Table":"dxmt_winemetal_unix_call_wow64_funcs","countSymbol":"wvr_dxmt_d3d12_unix_call_count_v1","abiSymbol":"wvr_dxmt_d3d12_transport_abi_v1"},"nativeSourceTreeSha256":tree_sha(dest),"sourcePreparationStatus":"pinned-source-overlays-applied-unbuilt"}
p=work/"AVPPLAY_D3D12_SOURCE_PROVENANCE.json"; p.write_text(json.dumps(provenance,indent=2,sort_keys=True)+"\n",encoding="utf-8")
adaptation={"schemaVersion":1,"profileId":profile_id,"sourceProvenanceSha256":sha(p),"sourceRevision":dxmt["revision"],"madeiraRevision":madeira["revision"],"llvmSourceRevision":llvm["revision"],"nativeSourceTreeSha256":provenance["nativeSourceTreeSha256"],"appliedPortSourcesSha256":{"windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch":provenance["integrationInputsSha256"]["windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch"]},"transportABI":provenance["transportABI"],"unixCallTable":provenance["unixCallTable"],"status":"source-port-recorded-build-not-run"}
(work/"AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json").write_text(json.dumps(adaptation,indent=2,sort_keys=True)+"\n",encoding="utf-8")
(work/"D3D12-SOURCE-PROFILE.md").write_text("Isolated profile retains Madeira's FEX/Wine/app overlay and replaces only DXMT with the locked 3Shain D3D12 source plus pinned project overlays. The source-port receipt records applied source inputs only; it is not a successful binary or runtime validation.\n",encoding="utf-8")
PY
[[ ! -e "$OUTPUT" ]] || { echo "Output appeared during preparation; refusing to replace it." >&2; exit 1; }
mv "$WORK" "$OUTPUT"
rm -rf "$STAGE"
trap - EXIT
echo "Prepared isolated D3D12 source profile at $OUTPUT; no compiler was invoked."

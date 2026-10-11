#!/usr/bin/env bash
# Stage only the exact archive/DLL closure recorded by a successful D3D12 build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="${AVPPLAY_D3D12_PROFILE_SOURCE:-$ROOT/runtime-source-d3d12-experimental}"
ADAPTATION="${AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT:-$PROFILE/AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json}"
BUILD_RECEIPT="${AVPPLAY_D3D12_BUILD_RECEIPT:-$PROFILE/AVPPLAY_D3D12_BUILD_RECEIPT.json}"
NATIVE_ARCHIVE="${AVPPLAY_D3D12_NATIVE_ARCHIVE:-$PROFILE/app/Madeira/libdxmt_d3d12_combined.a}"
STAGE_ROOT="${AVPPLAY_D3D12_STAGE_ROOT:-}"
[[ "${AVPPLAY_ENABLE_D3D12:-0}" == 1 ]] || { echo "Set AVPPLAY_ENABLE_D3D12=1 to stage D3D12 resources." >&2; exit 1; }
[[ "$STAGE_ROOT" == /* ]] || { echo "Set AVPPLAY_D3D12_STAGE_ROOT to a fresh absolute path." >&2; exit 1; }
python3 - "$ROOT" "$PROFILE" "$ADAPTATION" "$BUILD_RECEIPT" "$NATIVE_ARCHIVE" "$STAGE_ROOT" <<'PY'
import hashlib, json, pathlib, shutil, sys, tempfile
root, profile, adaptation_path, build_path, archive, stage_root = map(pathlib.Path, sys.argv[1:])

def fail(message): raise SystemExit(message)
def regular(path, label):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0: fail(f"{label} must be a nonempty regular file: {path}")
def sha(path):
    regular(path, "Hash input")
    h=hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b""): h.update(chunk)
    return h.hexdigest()
def read_json(path,label):
    regular(path,label)
    try: value=json.loads(path.read_text(encoding="utf-8"))
    except (OSError,UnicodeError,json.JSONDecodeError) as exc: fail(f"Cannot read {label}: {exc}")
    if not isinstance(value,dict): fail(f"{label} must be a JSON object.")
    return value
source_path=profile/"AVPPLAY_D3D12_SOURCE_PROVENANCE.json"
source=read_json(source_path,"D3D12 source provenance")
adaptation=read_json(adaptation_path,"D3D12 native adaptation receipt")
build=read_json(build_path,"D3D12 binary build receipt")
profile_id="dxmt-d3d12-experimental-e94c312f5c054263acf261cfa109edf13e757587"
if source.get("profileId") != profile_id or source.get("sourceRevision") != "e94c312f5c054263acf261cfa109edf13e757587": fail("Unexpected D3D12 source profile pin.")
if adaptation.get("schemaVersion") != 1 or adaptation.get("profileId") != profile_id or adaptation.get("sourceProvenanceSha256") != sha(source_path): fail("Source adaptation receipt is missing or stale.")
if build.get("schemaVersion") != 1 or build.get("profileId") != profile_id or build.get("sourceProvenanceSha256") != sha(source_path) or build.get("nativeAdaptationReceiptSha256") != sha(adaptation_path): fail("D3D12 build receipt does not match the source/adaptation receipts.")
if source.get("unixCallTable",{}).get("expectedEntryCount") != 148 or build.get("dispatchTableExpectedEntryCount") != 148 or build.get("exportedDispatchSymbols") != ["_dxmt_winemetal_unix_call_funcs","_dxmt_winemetal_unix_call_wow64_funcs","_wvr_dxmt_d3d12_unix_call_count_v1","_wvr_dxmt_d3d12_transport_abi_v1"]: fail("D3D12 dispatch table exports/count contract do not match the embedded Wine profile.")
if build.get("nativeSourceTreeSha256") != source.get("nativeSourceTreeSha256") or build.get("unixCallTable") != source.get("unixCallTable") or build.get("transportABI") != source.get("transportABI"): fail("D3D12 build uses a different source tree or transport/table ABI.")
inputs=source.get("integrationInputsSha256",{})
required={
 "windows-vr-openxr/patches/0002-dxmt-d3d12-wvr-queue.patch","windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch","windows-vr-openxr/patches/0004-dxmt-modern-d3d11-wvr.patch","windows-vr-openxr/patches/0005-dxmt-xros-metallib-target.patch",
 "windows-vr-openxr/patches/0006-dxmt-arm64ec-native-build.patch","windows-runtime-plugin/d3d12/0001-embedded-dxmt-dispatch.patch",
 "windows-vr-openxr/include/WindowsVRD3D11ContextExt.h","windows-vr-openxr/include/WindowsVRD3D12CommandQueueExt.h","windows-vr-openxr/include/WindowsVRWMTBridge.h",
 "windows-vr-native/include/WindowsVRCompositorBridge.h","windows-vr-ngx/src/WVRMetalFXWMTBridge.h","windows-vr-ngx/src/WVRMetalFXWMTBridge.inc","windows-vr-ngx/include/WindowsVRNGX.h",
 "windows-vr-metal/Sources/WindowsVRMetalABI/include/WindowsVRMetalC.h","windows-runtime-plugin/WindowsVRRuntimePlugin.mm","native-d3d12/wvr_dxmt_d3d12_native_abi.h","windows-vr-openxr/native-d3d12/generate_metallib_platform.py","windows-vr-openxr/src/WindowsVROpenXR.cpp","windows-vr-openxr/CMakeLists.txt","windows-vr-openvr/patches/0002-direct3d-openxr-build.patch","windows-vr-openvr/CMakeLists.txt","windows-vr-native/Sources/WindowsVRCompositorBridge.mm","windows-vr-tools/sources.lock.json","windows-vr-tools/llvm.lock.json",
 "windows-vr-tools/prepare_d3d12_experimental_source.sh","windows-vr-tools/prepare_d3d12_profile.sh","windows-vr-tools/build_d3d12_experimental.sh","windows-vr-tools/build_d3d12_profile.sh","windows-vr-tools/stage_d3d12_experimental.sh","windows-vr-tools/stage_d3d12_profile.sh","windows-vr-tools/stage_resources.py"
}
if set(inputs) != required: fail("Source profile does not record the complete D3D12 integration input set.")
for name,expected in inputs.items():
    if sha(root/name) != expected: fail(f"D3D12 source input changed after preparation: {name}")

def tree_sha(directory):
    h=hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or ".git" in path.parts: continue
        rel=path.relative_to(directory).as_posix().encode(); h.update(len(rel).to_bytes(8,"big")); h.update(rel); h.update(path.stat().st_size.to_bytes(8,"big"))
        with path.open("rb") as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b""): h.update(chunk)
    return h.hexdigest()
if tree_sha(profile/"dxmt") != source.get("nativeSourceTreeSha256"): fail("Modern DXMT source tree changed after preparation.")
regular(archive,"Modern native DXMT archive")
with archive.open("rb") as stream:
    if stream.read(8) != b"!<arch>\n": fail("D3D12 native input is not a static archive.")
artifacts=build.get("artifactsSha256",{})
if artifacts.get("native/libdxmt_d3d12_combined.a") != sha(archive): fail("The selected native archive does not match the successful D3D12 build receipt.")
source_dlls=profile/"app/Madeira/arm64ec-windows"
dll_hashes={}
for name in ("d3d11.dll","d3d12.dll","dxgi.dll","winemetal.dll"):
    path=source_dlls/name
    if artifacts.get(f"guest/arm64ec-windows/{name}") != sha(path): fail(f"ARM64EC {name} does not match the same-source build receipt.")
    dll_hashes[name]=sha(path)
    sys.path.insert(0,str(root/"windows-vr-tools"))
from stage_resources import is_arm64ec_pe
    
for name in dll_hashes:
    if not is_arm64ec_pe(source_dlls/name): fail(f"{name} is not an ARM64EC PE or valid AMD64+CHPE Wine builtin.")
if stage_root.exists(): fail(f"Refusing to replace existing D3D12 stage: {stage_root}")
stage_root.parent.mkdir(parents=True,exist_ok=True)
staging=pathlib.Path(tempfile.mkdtemp(prefix=".d3d12-stage-",dir=stage_root.parent))
try:
    guest=staging/"Runtime/arm64ec-windows"; guest.mkdir(parents=True)
    for name in dll_hashes: shutil.copy2(source_dlls/name,guest/name)
    win=staging/"WindowsVR"; exp=win/"D3D12Experimental"; exp.mkdir(parents=True)
    shutil.copy2(source_path,exp/"AVPPLAY_D3D12_SOURCE_PROVENANCE.json")
    shutil.copy2(adaptation_path,exp/"AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json")
    shutil.copy2(build_path,exp/"AVPPLAY_D3D12_BUILD_RECEIPT.json")
    capabilities={"schemaVersion":1,"direct3D11":True,"direct3D12":True,"d3d12TransportABI":1,"sourceProfileId":profile_id,"sourceRevision":source["sourceRevision"],"sourceProfileReceiptSha256":sha(source_path)}
    cap=win/"GraphicsCapabilities.json"; cap.write_text(json.dumps(capabilities,separators=(",",":"))+"\n",encoding="utf-8")
    profile_receipt={"schemaVersion":1,"profileId":profile_id,"sourceRevision":source["sourceRevision"],"madeiraBaselineRevision":source["madeiraBaselineRevision"],"llvmSourceRevision":source["llvmSourceRevision"],"sourceProvenanceSha256":sha(source_path),"nativeAdaptationReceiptSha256":sha(adaptation_path),"buildReceiptSha256":sha(build_path),"nativeArchiveName":"libdxmt_d3d12_combined.a","nativeArchiveSha256":sha(archive),"nativeSourceTreeSha256":source["nativeSourceTreeSha256"],"unixCallTable":source["unixCallTable"],"transportABI":source["transportABI"],"guestArtifactsSha256":dll_hashes,"graphicsCapabilitiesSha256":sha(cap),"supportLevel":"source-matched-build-receipt"}
    profile_receipt_path=exp/"AVPPLAY_DXMT_D3D12_PROFILE.json"
    profile_receipt_path.write_text(json.dumps(profile_receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    (staging/"AVPPLAY_D3D12_STAGE_RECEIPT.json").write_text(json.dumps({"schemaVersion":1,"buildReceiptSha256":sha(build_path),"nativeArchiveSha256":sha(archive),"profileReceiptSha256":sha(profile_receipt_path),"graphicsCapabilitiesSha256":sha(cap)},indent=2,sort_keys=True)+"\n",encoding="utf-8")
    staging.replace(stage_root)
finally:
    if staging.exists(): shutil.rmtree(staging)
print(f"Staged matched D3D12 native/ARM64EC source closure at {stage_root}.")
PY

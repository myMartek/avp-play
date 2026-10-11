#!/usr/bin/env python3
"""Transactionally stage validated Wine and Windows VR resources; execute no binaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile

from resource_receipt import GUEST_RECEIPT_NAME, sha256_file, validate_receipts

ROOT = Path(__file__).resolve().parents[1]
WINE_TOOLS = {
    "wineboot.exe", "services.exe", "winedevice.exe", "explorer.exe",
    "conhost.exe", "rundll32.exe", "start.exe", "plugplay.exe",
    "rpcss.exe", "winecfg.exe",
}
REQUIRED_BUILTINS = {
    "ntdll.dll", "kernel32.dll", "kernelbase.dll", "wineboot.exe",
    "services.exe", "winedevice.exe", "rpcss.exe",
}
FORBIDDEN = ("steamclient", "codex", "test", "probe", "canary", "hello", "triangle", "cube", "thumper")
MAX_ARCHIVE_MEMBERS = 250_000
MAX_ARCHIVE_UNPACKED = 20 * 1024**3
MAX_ARCHIVE_FILE = 8 * 1024**3
WINDOWS_RESERVED = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$", re.IGNORECASE)


def fail(message):
    raise SystemExit(message)


def regular_file(path, description):
    if path.is_symlink() or not path.is_file():
        fail(f"{description} must be a regular file: {path}")
    return path


def regular_tree(root, description):
    if root.is_symlink() or not root.is_dir():
        fail(f"{description} must be a real directory: {root}")
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            fail(f"{description} contains a symlink or special file: {path}")


def portable_member_name(raw):
    if not raw or "\x00" in raw or "\\" in raw or raw.startswith("/"):
        fail(f"Wine prefix template contains a non-portable path: {raw!r}")
    path = PurePosixPath(raw)
    parts = path.parts
    raw_parts = raw.rstrip("/").split("/")
    if not parts or path.is_absolute() or not raw_parts or any(part in ("", ".", "..") for part in raw_parts):
        fail(f"Wine prefix template contains an unsafe path: {raw!r}")
    for part in parts:
        if (part.endswith((" ", ".")) or any(ord(char) < 32 or char in '<>:"|?*' for char in part)
                or WINDOWS_RESERVED.match(part)):
            fail(f"Wine prefix template contains a non-portable path component: {raw!r}")
    lowered = tuple(part.casefold() for part in parts)
    if any(any(term in part for term in FORBIDDEN) for part in lowered):
        fail(f"Wine prefix template contains an excluded path: {raw}")
    return lowered


def validate_prefix_archive(template):
    regular_file(template, "Wine prefix template")
    if template.stat().st_size == 0:
        fail("Wine prefix template is empty; supply an explicit clean Wine prefix archive.")
    try:
        with tarfile.open(template, "r:gz") as archive:
            members = archive.getmembers()
            if not members:
                fail("Wine prefix template is empty; supply an explicit clean Wine prefix archive.")
            if len(members) > MAX_ARCHIVE_MEMBERS:
                fail("Wine prefix template has too many archive members.")
            total_size = 0
            seen = {}
            files = set()
            directories = set()
            for member in members:
                key = portable_member_name(member.name.rstrip("/") if member.isdir() else member.name)
                if key in seen:
                    fail(f"Wine prefix template contains duplicate/case-colliding paths: {member.name}")
                seen[key] = member.name
                if member.pax_headers and any(k.lower() in {"path", "linkpath", "gnu.sparse.map", "gnu.sparse.size"}
                                              for k in member.pax_headers):
                    fail(f"Wine prefix template uses unsafe PAX metadata: {member.name}")
                if member.issym() or member.islnk():
                    fail("Wine prefix template must omit host symlinks and hardlinks; runtime creates its own drive links.")
                if (getattr(member, "sparse", None) is not None or member.isdev() or member.isfifo()
                        or not (member.isfile() or member.isdir())):
                    fail(f"Wine prefix template contains a special archive entry: {member.name}")
                if member.isfile():
                    if member.size < 0 or member.size > MAX_ARCHIVE_FILE:
                        fail(f"Wine prefix template contains an oversized file: {member.name}")
                    total_size += member.size
                    files.add(key)
                else:
                    directories.add(key)
            if total_size > MAX_ARCHIVE_UNPACKED:
                fail("Wine prefix template exceeds the maximum uncompressed size.")
            for key in files:
                for index in range(1, len(key)):
                    if key[:index] in files:
                        fail(f"Wine prefix template has a file used as a directory: {seen[key[:index]]}")
            layouts = [(), ("prefix",)]
            valid_layout = False
            for base in layouts:
                required_files = {base + ("system.reg",), base + ("user.reg",)}
                required_dirs = {base + ("drive_c", "windows", "system32")}
                member_sizes = {portable_member_name(member.name): member.size for member in members if member.isfile()}
                if (required_files.issubset(files) and required_dirs.issubset(directories)
                        and all(member_sizes.get(required, 0) > 0 for required in required_files)):
                    valid_layout = True
                    break
            if not valid_layout:
                fail("Wine prefix template must contain nonempty system.reg/user.reg and drive_c/windows/system32, at root or under upstream's prefix/ archive directory.")
    except (OSError, tarfile.TarError, EOFError) as exc:
        fail(f"Cannot read Wine prefix template as a safe gzip tar archive: {exc}")


def pe_machine(path):
    with path.open("rb") as stream:
        dos = stream.read(64)
        if len(dos) != 64 or dos[:2] != b"MZ":
            return None
        offset = int.from_bytes(dos[0x3C:0x40], "little")
        if offset < 64 or offset > 16 * 1024 * 1024:
            return None
        stream.seek(offset)
        header = stream.read(6)
        if len(header) != 6 or header[:4] != b"PE\0\0":
            return None
        return int.from_bytes(header[4:6], "little")


def require_license(path, label):
    regular_file(path, f"{label} license")
    if path.stat().st_size == 0:
        fail(f"{label} license is empty: {path}")


def validate_prefix_provenance(path, template, expected_revision):
    regular_file(path, "Wine prefix template provenance")
    try:
        provenance = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"Cannot read Wine prefix template provenance {path}: {exc}")
    if not isinstance(provenance, dict):
        fail("Wine prefix template provenance must be a JSON object.")
    if (provenance.get("schemaVersion") != 1
            or provenance.get("madeiraRevision") != expected_revision
            or provenance.get("templateSha256") != sha256_file(template)
            or provenance.get("originUrl") != "https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/tools/build-prefix-snapshot.sh"
            or provenance.get("creationCommand") != "bash tools/build-prefix-snapshot.sh"
            or provenance.get("wineExecuted") is not True
            or not isinstance(provenance.get("wineVersion"), str)
            or not provenance["wineVersion"].strip()):
        fail("Prefix provenance must identify the pinned upstream Wine-generated snapshot, matching archive hash, and Wine version.")
    return provenance


def tree_hashes(runtime_root, guest_root):
    result = {}
    for label, root in (("Runtime", runtime_root), ("WindowsVR", guest_root)):
        for path in root.rglob("*"):
            if path.is_symlink() or not path.is_file():
                if path.is_dir() and not path.is_symlink():
                    continue
                fail(f"Staged resources contain a symlink or special file: {path}")
            relative = path.relative_to(root).as_posix()
            if label == "Runtime" and relative == "AVPPLAY_RESOURCE_STAGE.json":
                continue
            result[f"{label}/{relative}"] = sha256_file(path)
    return dict(sorted(result.items()))


def validate_existing_stage(output, guest_output, template, prefix_provenance,
                            native_receipt_path, source, license_files, d3d12_inputs):
    manifest_path = output / "AVPPLAY_RESOURCE_STAGE.json"
    if (output.is_symlink() or guest_output.is_symlink() or not output.is_dir()
            or not guest_output.is_dir() or manifest_path.is_symlink() or not manifest_path.is_file()):
        fail("Existing staged resource trees have no reusable stage manifest; choose fresh Resources paths.")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"Cannot read existing resource stage manifest: {exc}")
    expected_inputs = {
        "prefixTemplateSha256": sha256_file(template),
        "prefixProvenanceSha256": sha256_file(prefix_provenance),
        "nativeReceiptSha256": sha256_file(native_receipt_path),
        "guestReceiptSha256": sha256_file(source / GUEST_RECEIPT_NAME),
        "licensesSha256": {name: sha256_file(path) for name, path in sorted(license_files.items())},
        "d3d12Inputs": d3d12_inputs,
    }
    if manifest.get("inputs") != expected_inputs or manifest.get("filesSha256") != tree_hashes(output, guest_output):
        fail("Existing staged resource trees do not match current prefix, license, or build inputs; refusing reuse.")


def validate_guest_tree(guest_root):
    regular_tree(guest_root, "WindowsVR guest stage")
    required = {
        guest_root / "Guest/x64/OpenComposite/bin/vrclient_x64.dll": 0x8664,
        guest_root / "Guest/x64/wvr_openxr.dll": 0x8664,
    }
    for path, expected_machine in required.items():
        regular_file(path, "Required x64 guest runtime DLL")
        if pe_machine(path) != expected_machine:
            fail(f"Guest DLL is not a valid x64 PE image: {path}")
    arm64ec_root = guest_root / "Guest/arm64ec"
    if arm64ec_root.exists():
        pair = [arm64ec_root / "OpenComposite/bin/vrclient_x64.dll", arm64ec_root / "wvr_openxr.dll"]
        if any(not path.is_file() or path.is_symlink() or pe_machine(path) != 0xA641 for path in pair):
            fail("An ARM64EC guest package must contain matching ARM64EC OpenComposite and OpenXR PE DLLs.")


def validate_d3d12_stage(stage_root, native_archive):
    regular_tree(stage_root, "D3D12 receipt-backed stage")
    regular_file(native_archive, "D3D12 native archive")
    source_dir = stage_root / "WindowsVR/D3D12Experimental"
    source_path = source_dir / "AVPPLAY_D3D12_SOURCE_PROVENANCE.json"
    adaptation_path = source_dir / "AVPPLAY_D3D12_NATIVE_ADAPTATION_RECEIPT.json"
    build_path = source_dir / "AVPPLAY_D3D12_BUILD_RECEIPT.json"
    profile_path = source_dir / "AVPPLAY_DXMT_D3D12_PROFILE.json"
    capabilities_path = stage_root / "WindowsVR/GraphicsCapabilities.json"
    stage_receipt_path = stage_root / "AVPPLAY_D3D12_STAGE_RECEIPT.json"
    def load(path, label):
        regular_file(path, label)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            fail(f"Cannot read {label}: {exc}")
        if not isinstance(value, dict):
            fail(f"{label} must be a JSON object.")
        return value
    source = load(source_path, "D3D12 source profile receipt")
    adaptation = load(adaptation_path, "D3D12 native adaptation receipt")
    build = load(build_path, "D3D12 build receipt")
    profile = load(profile_path, "D3D12 package provenance receipt")
    capabilities = load(capabilities_path, "D3D12 GraphicsCapabilities.json")
    stage_receipt = load(stage_receipt_path, "D3D12 stage receipt")
    profile_id = "dxmt-d3d12-experimental-e94c312f5c054263acf261cfa109edf13e757587"
    source_hash = sha256_file(source_path)
    adaptation_hash = sha256_file(adaptation_path)
    build_hash = sha256_file(build_path)
    profile_hash = sha256_file(profile_path)
    archive_hash = sha256_file(native_archive)
    if (source.get("schemaVersion") != 1 or source.get("profileId") != profile_id
            or source.get("sourceRevision") != "e94c312f5c054263acf261cfa109edf13e757587"):
        fail("D3D12 source receipt does not identify the locked 3Shain DXMT profile.")
    table = source.get("unixCallTable", {})
    if (table.get("version") != 1 or table.get("expectedEntryCount") != 148
            or table.get("nativeTable") != "dxmt_winemetal_unix_call_funcs"
            or table.get("wow64Table") != "dxmt_winemetal_unix_call_wow64_funcs"
            or table.get("countSymbol") != "wvr_dxmt_d3d12_unix_call_count_v1"
            or table.get("abiSymbol") != "wvr_dxmt_d3d12_transport_abi_v1"):
        fail("D3D12 source profile has a different native/WOW64 dispatch-table contract.")
    if (adaptation.get("schemaVersion") != 1 or adaptation.get("profileId") != profile_id
            or adaptation.get("sourceProvenanceSha256") != source_hash
            or adaptation.get("nativeSourceTreeSha256") != source.get("nativeSourceTreeSha256")
            or adaptation.get("appliedPortSourcesSha256", {}).get("windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch")
               != source.get("integrationInputsSha256", {}).get("windows-vr-openxr/patches/0003-dxmt-d3d12-visionos-native.patch")):
        fail("D3D12 source adaptation receipt is stale or not bound to the native port patch.")
    if (build.get("schemaVersion") != 1 or build.get("profileId") != profile_id
            or build.get("sourceProvenanceSha256") != source_hash
            or build.get("nativeAdaptationReceiptSha256") != adaptation_hash
            or build.get("nativeSourceTreeSha256") != source.get("nativeSourceTreeSha256")
            or build.get("sourceRevision") != source.get("sourceRevision")
            or build.get("madeiraRevision") != source.get("madeiraBaselineRevision")
            or build.get("llvmSourceRevision") != source.get("llvmSourceRevision")
            or build.get("nativeArchive") != "libdxmt_d3d12_combined.a"
            or build.get("dispatchTableExpectedEntryCount") != 148
            or build.get("unixCallTable") != source.get("unixCallTable")
            or build.get("transportABI") != source.get("transportABI")
            or build.get("exportedDispatchSymbols") != [
                "_dxmt_winemetal_unix_call_funcs", "_dxmt_winemetal_unix_call_wow64_funcs",
                "_wvr_dxmt_d3d12_unix_call_count_v1", "_wvr_dxmt_d3d12_transport_abi_v1"]):
        fail("D3D12 build receipt does not match its source/adaptation and exported dispatch table.")
    artifacts = build.get("artifactsSha256", {})
    if artifacts.get("native/libdxmt_d3d12_combined.a") != archive_hash:
        fail("The native archive selected for app linking differs from the successful D3D12 build receipt.")
    with native_archive.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            fail("D3D12 native input is not a static archive.")
    guest_root = stage_root / "Runtime/arm64ec-windows"
    expected_guest = {"d3d11.dll", "d3d12.dll", "dxgi.dll", "winemetal.dll"}
    if not guest_root.is_dir() or {path.name for path in guest_root.iterdir()} != expected_guest:
        fail("D3D12 stage must contain exactly the matching ARM64EC d3d11/d3d12/dxgi/winemetal DLL closure.")
    for name in sorted(expected_guest):
        path = guest_root / name
        regular_file(path, "D3D12 ARM64EC guest DLL")
        if pe_machine(path) != 0xA641:
            fail(f"D3D12 package requires an ARM64EC Wine builtin: {path}")
        if artifacts.get(f"guest/arm64ec-windows/{name}") != sha256_file(path):
            fail(f"Staged ARM64EC {name} does not match the D3D12 build receipt.")
    if (profile.get("schemaVersion") != 1 or profile.get("profileId") != profile_id
            or profile.get("sourceProvenanceSha256") != source_hash
            or profile.get("nativeAdaptationReceiptSha256") != adaptation_hash
            or profile.get("buildReceiptSha256") != build_hash
            or profile.get("nativeArchiveSha256") != archive_hash
            or profile.get("guestArtifactsSha256") != {name: sha256_file(guest_root / name) for name in sorted(expected_guest)}
            or profile.get("graphicsCapabilitiesSha256") != sha256_file(capabilities_path)
            or profile.get("unixCallTable") != source.get("unixCallTable")
            or profile.get("transportABI") != source.get("transportABI")):
        fail("D3D12 package receipt does not match the staged binaries/profile.")
    expected_capabilities = {
        "schemaVersion": 1,
        "direct3D11": True,
        "direct3D12": True,
        "d3d12TransportABI": 1,
        "sourceProfileId": profile_id,
        "sourceRevision": source.get("sourceRevision"),
        "sourceProfileReceiptSha256": source_hash,
    }
    if capabilities != expected_capabilities:
        fail("D3D12 capability marker is missing the exact source pin/profile receipt contract.")
    if (stage_receipt.get("schemaVersion") != 1
            or stage_receipt.get("buildReceiptSha256") != build_hash
            or stage_receipt.get("nativeArchiveSha256") != archive_hash
            or stage_receipt.get("profileReceiptSha256") != profile_hash
            or stage_receipt.get("graphicsCapabilitiesSha256") != sha256_file(capabilities_path)):
        fail("D3D12 stage receipt does not match the actual archive, profile receipt, and capability marker.")
    return {
        "stageReceiptSha256": sha256_file(stage_receipt_path),
        "nativeArchiveSha256": archive_hash,
        "sourceProfileReceiptSha256": source_hash,
        "buildReceiptSha256": build_hash,
    }


def validate_wine_resources(source):
    regular_tree(source, "Madeira Wine resource source")
    for relative in ("arm64ec-windows", "aarch64-windows", "nls", "legal"):
        if not (source / relative).is_dir():
            fail(f"Required Wine resource directory is missing: {source / relative}")
    if not any(path.is_file() for path in (source / "nls").rglob("*")):
        fail("Wine NLS resource directory is empty.")
    if not any(path.is_file() for path in (source / "legal").rglob("*")):
        fail("Wine legal resource directory is empty.")
    for farm in ("arm64ec-windows", "aarch64-windows"):
        farm_root = source / farm
        names = {}
        for path in farm_root.iterdir():
            if path.is_symlink() or not path.is_file():
                fail(f"Wine builtin farm contains a symlink, directory, or special file: {path}")
            key = path.name.casefold()
            if key in names:
                fail(f"Wine builtin farm contains case-colliding files: {path.name}")
            names[key] = path
        missing = sorted(REQUIRED_BUILTINS - set(names))
        if missing:
            fail(f"Wine builtin farm {farm} is missing required files: {', '.join(missing)}")
        graphics_required = {"d3d11.dll", "winemetal.dll"} if farm == "arm64ec-windows" else set()
        if not graphics_required.issubset(names):
            fail("ARM64EC resource farm must include the matching-overlay DXMT d3d11.dll and winemetal.dll.")
        for name in REQUIRED_BUILTINS | graphics_required:
            if names[name].stat().st_size == 0:
                fail(f"Required Wine builtin is empty: {names[name]}")
        for name, path in names.items():
            if (path.suffix.casefold() == ".dll" or name in WINE_TOOLS) and any(term in name for term in FORBIDDEN):
                fail(f"Wine builtin farm contains an excluded test/game resource: {path}")


def copy_builtins(source, destination):
    for farm in ("arm64ec-windows", "aarch64-windows"):
        farm_output = destination / farm
        farm_output.mkdir()
        for path in (source / farm).iterdir():
            name = path.name.casefold()
            if path.suffix.casefold() == ".dll" or name in WINE_TOOLS:
                shutil.copy2(path, farm_output / path.name)
        names = {path.name.casefold() for path in farm_output.iterdir()}
        missing = sorted(REQUIRED_BUILTINS - names)
        if missing:
            fail(f"Staged Wine builtin farm {farm} is incomplete: {', '.join(missing)}")
    shutil.copytree(source / "nls", destination / "nls")
    shutil.copytree(source / "legal", destination / "legal")


def transactional_stage(source, template, prefix_provenance, guest_root, output,
                       license_files, native_receipt_path, d3d12_stage=None, d3d12_inputs=None):
    guest_output = output.parent / "WindowsVR"
    if output.exists() or guest_output.exists():
        fail("Resource output already exists; use --reuse-existing only for a receipt-matched prior stage.")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".windows-vr-stage-", dir=output.parent))
    staged_runtime = staging / "Runtime"
    staged_guest = staging / "WindowsVR"
    try:
        staged_runtime.mkdir()
        staged_guest.mkdir()
        shutil.copy2(template, staged_runtime / "prefix-template.tar.gz")
        shutil.copy2(prefix_provenance, staged_runtime / "prefix-template-provenance.json")
        shutil.copy2(native_receipt_path, staged_runtime / "AVPPLAY_NATIVE_BUILD_RECEIPT.json")
        shutil.copy2(source / GUEST_RECEIPT_NAME, staged_runtime / GUEST_RECEIPT_NAME)
        ca_bundle = source / "cacert.pem"
        if ca_bundle.exists():
            regular_file(ca_bundle, "Madeira CA bundle")
            if ca_bundle.stat().st_size == 0:
                fail("Madeira CA bundle is empty.")
            shutil.copy2(ca_bundle, staged_runtime / "cacert.pem")
        copy_builtins(source, staged_runtime)
        shutil.copytree(guest_root, staged_guest, dirs_exist_ok=True)
        if d3d12_stage is not None:
            shutil.copytree(d3d12_stage / "Runtime/arm64ec-windows",
                            staged_runtime / "arm64ec-windows", dirs_exist_ok=True)
            capabilities = d3d12_stage / "WindowsVR/GraphicsCapabilities.json"
            profile_dir = d3d12_stage / "WindowsVR/D3D12Experimental"
            if (staged_guest / "GraphicsCapabilities.json").exists() or (staged_guest / "D3D12Experimental").exists():
                fail("D3D12 capability/profile resources collide with existing WindowsVR resources.")
            shutil.copy2(capabilities, staged_guest / "GraphicsCapabilities.json")
            shutil.copytree(profile_dir, staged_guest / "D3D12Experimental")
        for name, path in license_files.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        manifest = {
            "schemaVersion": 1,
            "inputs": {
                "prefixTemplateSha256": sha256_file(template),
                "prefixProvenanceSha256": sha256_file(prefix_provenance),
                "nativeReceiptSha256": sha256_file(native_receipt_path),
                "guestReceiptSha256": sha256_file(source / GUEST_RECEIPT_NAME),
                "licensesSha256": {name: sha256_file(path) for name, path in sorted(license_files.items())},
                "d3d12Inputs": d3d12_inputs,
            },
            "filesSha256": tree_hashes(staged_runtime, staged_guest),
        }
        (staged_runtime / "AVPPLAY_RESOURCE_STAGE.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        # Commit both sibling trees only after all input validation and copies succeed.
        os.replace(staged_runtime, output)
        try:
            os.replace(staged_guest, guest_output)
        except Exception:
            os.replace(output, staged_runtime)
            raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "runtime-source/app/Madeira")
    parser.add_argument("--runtime-source", type=Path, required=True,
                        help="Prepared Madeira overlay whose native archives are covered by the receipt")
    parser.add_argument("--native-receipt", type=Path, required=True,
                        help="Receipt emitted after the native visionOS archive build")
    parser.add_argument("--output", type=Path, default=ROOT / "visionos-windows-vr/Resources/Runtime")
    parser.add_argument("--guest-stage", type=Path, required=True,
                        help="Combined stage root containing WindowsVR/Guest/x64 artifacts")
    parser.add_argument("--prefix-template", type=Path, required=True,
                        help="Explicit clean prefix archive; this tool never creates or runs Wine prefixes")
    parser.add_argument("--prefix-provenance", type=Path, required=True,
                        help="JSON provenance for an externally created pinned Madeira prefix snapshot")
    parser.add_argument("--d3d12-stage", type=Path,
                        help="Optional receipt-backed modern DXMT/ARM64EC closure created by stage_d3d12_experimental.sh")
    parser.add_argument("--d3d12-native-archive", type=Path,
                        help="The exact libdxmt_d3d12_combined.a selected by the app linker; required with --d3d12-stage")
    parser.add_argument("--reuse-existing", action="store_true",
                        help="Reuse existing output only when its stage manifest matches these exact inputs")
    parser.add_argument("--madeira-license", type=Path, required=True,
                        help="Madeira license file to include with Runtime/legal resources")
    parser.add_argument("--opencomposite-license", type=Path, required=True,
                        help="OpenComposite GPL license file to include in WindowsVR/Legal")
    parser.add_argument("--openxr-license", type=Path, required=True,
                        help="Khronos OpenXR-SDK license file to include in WindowsVR/Legal")
    args = parser.parse_args()

    source = args.source.resolve()
    runtime_source = args.runtime_source.resolve()
    output = args.output.absolute()
    guest_root = args.guest_stage.resolve() / "WindowsVR"
    template = args.prefix_template.absolute()
    prefix_provenance = args.prefix_provenance.absolute()
    native_receipt_path = args.native_receipt.absolute()
    licenses = {
        "Runtime/legal/Madeira-LICENSE": args.madeira_license.absolute(),
        "WindowsVR/Legal/OpenComposite/LICENSE": args.opencomposite_license.absolute(),
        "WindowsVR/Legal/OpenXR-SDK/LICENSE": args.openxr_license.absolute(),
    }
    for label, path in (("Madeira", licenses["Runtime/legal/Madeira-LICENSE"]),
                        ("OpenComposite", licenses["WindowsVR/Legal/OpenComposite/LICENSE"]),
                        ("OpenXR-SDK", licenses["WindowsVR/Legal/OpenXR-SDK/LICENSE"])):
        require_license(path, label)
    validate_prefix_archive(template)
    native_receipt, _ = validate_receipts(source, runtime_source, native_receipt_path)
    validate_prefix_provenance(prefix_provenance, template, native_receipt["source"]["sourceRevision"])
    validate_wine_resources(source)
    validate_guest_tree(guest_root)
    if (args.d3d12_stage is None) != (args.d3d12_native_archive is None):
        fail("--d3d12-stage and --d3d12-native-archive must be supplied together.")
    d3d12_stage = args.d3d12_stage.resolve() if args.d3d12_stage else None
    d3d12_inputs = validate_d3d12_stage(d3d12_stage, args.d3d12_native_archive.resolve()) if d3d12_stage else None
    guest_output = output.parent / "WindowsVR"
    if output.exists() or guest_output.exists():
        if not args.reuse_existing:
            fail("Resource output already exists; pass --reuse-existing to verify and resume a matching stage.")
        validate_existing_stage(output, guest_output, template, prefix_provenance,
                                native_receipt_path, source, licenses, d3d12_inputs)
        print(f"Verified existing staged resources at {output.parent}; no code was executed.")
        return
    transactional_stage(source, template, prefix_provenance, guest_root, output,
                        licenses, native_receipt_path, d3d12_stage, d3d12_inputs)
    print(f"Staged validated Wine and Windows VR resources at {output.parent}; no code was executed.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Record and validate matching Madeira native and Windows resource builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from prepare_runtime import project_patch_hashes

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "windows-vr-tools/sources.lock.json"
PROVENANCE_NAME = "AVPPLAY_SOURCE_PROVENANCE.json"
NATIVE_RECEIPT_NAME = "AVPPLAY_NATIVE_BUILD_RECEIPT.json"
GUEST_RECEIPT_NAME = "AVPPLAY_GUEST_BUILD_RECEIPT.json"
NATIVE_ARCHIVES = (
    "app/Madeira/libntdll_unix.a",
    "app/Madeira/libwineserver.a",
    "app/Madeira/libwin32u_unix.a",
    "app/Madeira/libdxmt_combined.a",
    "app/Madeira/libgnutls.a",
    "app/Madeira/libhogweed.a",
    "app/Madeira/libnettle.a",
    "app/Madeira/libgmp.a",
    "app/Madeira/libavformat.a",
    "app/Madeira/libavcodec.a",
    "app/Madeira/libswresample.a",
    "app/Madeira/libavutil.a",
    "FEX/build-ios/FEXCore/Source/libFEXCore.a",
    "FEX/build-ios/FEXCore/Source/libFEXCore_Base.a",
    "FEX/build-ios/FEXCore/Source/libJemallocLibs.a",
    "FEX/build-ios/External/fmt/libfmt.a",
    "FEX/build-ios/External/cephes/libcephes_128bit.a",
    "FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a",
    "FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a",
)
WINE_TOOLS = {
    "wineboot.exe", "services.exe", "winedevice.exe", "explorer.exe",
    "conhost.exe", "rundll32.exe", "start.exe", "plugplay.exe", "ntoskrnl.exe",
    "rpcss.exe", "winecfg.exe",
}
LLVM_MINGW_PIN = {
    "release": "20260421",
    "archive": "llvm-mingw-20260421-ucrt-macos-universal.tar.xz",
    "archiveSha256": "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7",
    "arm64ecRuntimeDlls": ["libc++.dll", "libunwind.dll"],
}


def fail(message):
    raise SystemExit(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pe_machine(path):
    """Read the bounded COFF machine field without loading or executing a PE."""
    try:
        size = path.stat().st_size
        with path.open("rb") as stream:
            if size < 0x40:
                return None
            stream.seek(0x3C)
            raw_offset = stream.read(4)
            if len(raw_offset) != 4:
                return None
            pe_offset = int.from_bytes(raw_offset, "little")
            if pe_offset < 0x40 or pe_offset > size - 6:
                return None
            stream.seek(pe_offset)
            if stream.read(4) != b"PE\0\0":
                return None
            machine = stream.read(2)
            return int.from_bytes(machine, "little") if len(machine) == 2 else None
    except (OSError, OverflowError, ValueError):
        return None


def fex_translator_build(runtime_root, resource_source):
    # LLVM reports the effective ARM64EC architecture for AMD64 images with
    # CHPE metadata too; validate that metadata rather than only the raw field.
    from stage_resources import is_arm64ec_pe
    build_relative = "FEX/build-arm64ec-avp/Bin/libarm64ecfex.dll"
    guest_relative = "arm64ec-windows/xtajit64.dll"
    build_artifact = runtime_root / build_relative
    guest_artifact = resource_source / guest_relative
    ensure_regular_nonempty(build_artifact, "Fresh ARM64EC FEX translator build output")
    ensure_regular_nonempty(guest_artifact, "ARM64EC FEX translator guest resource")
    if not is_arm64ec_pe(build_artifact) or not is_arm64ec_pe(guest_artifact):
        fail("FEX translator build and packaged xtajit64.dll must both be native ARM64EC PE files.")
    build_hash = sha256_file(build_artifact)
    if sha256_file(guest_artifact) != build_hash:
        fail("Packaged xtajit64.dll is not byte-identical to this overlay's fresh FEX build output.")
    return {
        "buildArtifact": build_relative,
        "guestResource": guest_relative,
        "sha256": build_hash,
    }


def aarch64_winedevice_build(runtime_root, resource_source):
    build_relative = "wine/build-avp-aarch64/programs/winedevice/aarch64-windows/winedevice.exe"
    guest_relative = "aarch64-windows/winedevice.exe"
    build_artifact = runtime_root / build_relative
    guest_artifact = resource_source / guest_relative
    ensure_regular_nonempty(build_artifact, "Fresh AArch64 Wine winedevice build output")
    ensure_regular_nonempty(guest_artifact, "AArch64 Wine winedevice guest resource")
    if pe_machine(build_artifact) != 0xAA64 or pe_machine(guest_artifact) != 0xAA64:
        fail("AArch64 Wine winedevice build and packaged resource must use the ARM64 PE machine type.")
    build_hash = sha256_file(build_artifact)
    if sha256_file(guest_artifact) != build_hash:
        fail("Packaged AArch64 winedevice.exe is not byte-identical to this overlay's Wine build output.")
    return {
        "buildArtifact": build_relative,
        "guestResource": guest_relative,
        "sha256": build_hash,
    }


def read_json(path, description):
    if path.is_symlink() or not path.is_file():
        fail(f"{description} must be a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"Cannot read {description} {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{description} must contain a JSON object: {path}")
    return value


def pinned_source():
    lock = read_json(LOCK_PATH, "source lock")
    matches = [item for item in lock.get("sources", []) if item.get("name") == "madeira"]
    if len(matches) != 1:
        fail("Source lock must contain exactly one Madeira source.")
    return matches[0]


def overlay_provenance(runtime_root):
    pinned = pinned_source()
    provenance_path = runtime_root / PROVENANCE_NAME
    provenance = read_json(provenance_path, "Madeira source provenance")
    if (provenance.get("schemaVersion") != 1
            or provenance.get("sourceRevision") != pinned["revision"]
            or provenance.get("sourceUrl") != pinned["url"]):
        fail("Prepared Madeira overlay provenance does not match the source lock.")
    if provenance.get("integrationPatchSha256") != project_patch_hashes():
        fail("Prepared overlay integration sources/headers changed; prepare a fresh overlay before recording or staging binaries.")
    return pinned, provenance, sha256_file(provenance_path)


def ensure_regular_nonempty(path, description):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        fail(f"{description} must be a nonempty regular file: {path}")


def write_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_native(args):
    runtime_root = args.runtime_source.resolve()
    pinned, provenance, provenance_hash = overlay_provenance(runtime_root)
    artifacts = {}
    for relative in NATIVE_ARCHIVES:
        path = runtime_root / relative
        ensure_regular_nonempty(path, "Native Madeira archive")
        artifacts[relative] = sha256_file(path)
    receipt = {
        "schemaVersion": 1,
        "source": {
            "name": "madeira",
            "sourceUrl": pinned["url"],
            "sourceRevision": pinned["revision"],
            "overlayProvenanceSha256": provenance_hash,
            "integrationPatchSha256": provenance.get("integrationPatchSha256", {}),
        },
        "native": {"artifactsSha256": artifacts},
    }
    output = args.output.absolute() if args.output else runtime_root / NATIVE_RECEIPT_NAME
    write_json_atomic(output, receipt)
    print(f"Recorded native Madeira build provenance at {output}")


def guest_resource_files(source):
    files = {}
    for farm in ("arm64ec-windows", "aarch64-windows"):
        farm_root = source / farm
        if farm_root.is_symlink() or not farm_root.is_dir():
            fail(f"Required Wine builtin farm is missing: {farm_root}")
        for path in farm_root.iterdir():
            if path.is_file() and (path.suffix.casefold() == ".dll" or path.name.casefold() in WINE_TOOLS):
                if path.is_symlink():
                    fail(f"Guest resource must not be a symlink: {path}")
                files[path.relative_to(source).as_posix()] = sha256_file(path)
    for relative in ("nls", "legal"):
        directory = source / relative
        if directory.is_symlink() or not directory.is_dir():
            fail(f"Required Madeira resource directory is missing: {directory}")
        for path in directory.rglob("*"):
            if path.is_symlink():
                fail(f"Guest resource must not be a symlink: {path}")
            if path.is_file():
                files[path.relative_to(source).as_posix()] = sha256_file(path)
    ca_bundle = source / "cacert.pem"
    if ca_bundle.exists():
        ensure_regular_nonempty(ca_bundle, "Madeira CA bundle")
        files[ca_bundle.relative_to(source).as_posix()] = sha256_file(ca_bundle)
    return dict(sorted(files.items()))


def write_guest(args):
    from stage_resources import is_arm64ec_pe
    runtime_root = args.runtime_source.resolve()
    source = args.resource_source.resolve()
    pinned, provenance, provenance_hash = overlay_provenance(runtime_root)
    native_receipt_path = args.native_receipt.resolve() if args.native_receipt else runtime_root / NATIVE_RECEIPT_NAME
    native_receipt = read_json(native_receipt_path, "Native Madeira build receipt")
    if (native_receipt.get("schemaVersion") != 1
            or native_receipt.get("source", {}).get("sourceRevision") != pinned["revision"]
            or native_receipt.get("source", {}).get("overlayProvenanceSha256") != provenance_hash):
        fail("Native receipt and prepared Madeira overlay do not have matching source provenance.")
    native_artifacts = native_receipt.get("native", {}).get("artifactsSha256", {})
    for relative in NATIVE_ARCHIVES:
        path = runtime_root / relative
        ensure_regular_nonempty(path, "Native Madeira archive")
        if native_artifacts.get(relative) != sha256_file(path):
            fail(f"Native Madeira archive changed after its receipt was recorded: {relative}")
    translator = fex_translator_build(runtime_root, source)
    aarch64_device = aarch64_winedevice_build(runtime_root, source)
    for name in LLVM_MINGW_PIN["arm64ecRuntimeDlls"]:
        runtime_dll = source / "arm64ec-windows" / name
        ensure_regular_nonempty(runtime_dll, "Pinned LLVM-MinGW ARM64EC runtime DLL")
        if not is_arm64ec_pe(runtime_dll):
            fail(f"LLVM-MinGW runtime dependency must be an ARM64EC PE file: {runtime_dll}")
    guest = {
        "source": {
            "sourceUrl": pinned["url"],
            "sourceRevision": pinned["revision"],
            "overlayProvenanceSha256": provenance_hash,
        },
        "nativeReceiptSha256": sha256_file(native_receipt_path),
        "resourcesSha256": guest_resource_files(source),
    }
    receipt = {"schemaVersion": 1, "source": guest["source"],
               "nativeReceiptSha256": guest["nativeReceiptSha256"],
               "guest": {
                   "resourcesSha256": guest["resourcesSha256"],
                   "fexTranslator": translator,
                   "wineAarch64Device": aarch64_device,
                   "llvmMingw": LLVM_MINGW_PIN,
               }}
    output = args.output.absolute() if args.output else source / GUEST_RECEIPT_NAME
    write_json_atomic(output, receipt)
    print(f"Recorded Windows guest resource provenance at {output}")


def validate_receipts(source, runtime_root, native_receipt_path):
    pinned, _, provenance_hash = overlay_provenance(runtime_root)
    native_receipt_path = native_receipt_path.resolve()
    native = read_json(native_receipt_path, "Native Madeira build receipt")
    native_source = native.get("source", {})
    if (native.get("schemaVersion") != 1
            or native_source.get("sourceRevision") != pinned["revision"]
            or native_source.get("sourceUrl") != pinned["url"]
            or native_source.get("overlayProvenanceSha256") != provenance_hash):
        fail("Native receipt is stale or belongs to a different pinned Madeira overlay.")
    native_artifacts = native.get("native", {}).get("artifactsSha256", {})
    if set(native_artifacts) != set(NATIVE_ARCHIVES):
        fail("Native receipt does not contain the required native archive closure.")
    for relative, expected in native_artifacts.items():
        path = runtime_root / relative
        ensure_regular_nonempty(path, "Native Madeira archive")
        if sha256_file(path) != expected:
            fail(f"Native Madeira archive no longer matches its receipt: {relative}")

    guest_path = source / GUEST_RECEIPT_NAME
    guest = read_json(guest_path, "Windows guest resource receipt")
    guest_source = guest.get("source", {})
    if (guest.get("schemaVersion") != 1
            or guest_source.get("sourceRevision") != pinned["revision"]
            or guest_source.get("sourceUrl") != pinned["url"]
            or guest_source.get("overlayProvenanceSha256") != provenance_hash
            or guest.get("nativeReceiptSha256") != sha256_file(native_receipt_path)):
        fail("Windows guest receipt is stale or does not match the current native build receipt.")
    expected_files = guest.get("guest", {}).get("resourcesSha256")
    actual_files = guest_resource_files(source)
    if not isinstance(expected_files, dict) or expected_files != actual_files:
        fail("Windows guest resource files do not match their recorded build receipt.")
    expected_translator = fex_translator_build(runtime_root, source)
    if guest.get("guest", {}).get("fexTranslator") != expected_translator:
        fail("Windows guest receipt does not bind xtajit64.dll to the fresh FEX build output.")
    expected_aarch64_device = aarch64_winedevice_build(runtime_root, source)
    if guest.get("guest", {}).get("wineAarch64Device") != expected_aarch64_device:
        fail("Windows guest receipt does not bind aarch64 winedevice.exe to the fresh Wine build output.")
    if guest.get("guest", {}).get("llvmMingw") != LLVM_MINGW_PIN:
        fail("Windows guest receipt does not identify the pinned LLVM-MinGW runtime dependency source.")
    for name in LLVM_MINGW_PIN["arm64ecRuntimeDlls"]:
        runtime_dll = source / "arm64ec-windows" / name
        ensure_regular_nonempty(runtime_dll, "Pinned LLVM-MinGW ARM64EC runtime DLL")
        from stage_resources import is_arm64ec_pe
        if not is_arm64ec_pe(runtime_dll):
            fail(f"LLVM-MinGW runtime dependency must be an ARM64EC PE file: {runtime_dll}")
    return native, guest


def validate_prefix(args):
    from stage_resources import validate_prefix_archive, validate_prefix_provenance

    template = args.template.absolute()
    provenance = args.provenance.absolute()
    validate_prefix_archive(template)
    pinned = pinned_source()
    validate_prefix_provenance(provenance, template, pinned["revision"])
    print("Wine prefix archive structure and pinned provenance are valid; no code was executed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prefix = subparsers.add_parser("validate-prefix", help="validate an external prefix and provenance before building")
    prefix.add_argument("--template", type=Path, required=True)
    prefix.add_argument("--provenance", type=Path, required=True)
    prefix.set_defaults(function=validate_prefix)
    native = subparsers.add_parser("native", help="record the native archive closure")
    native.add_argument("--runtime-source", type=Path, required=True)
    native.add_argument("--output", type=Path)
    native.set_defaults(function=write_native)
    guest = subparsers.add_parser("guest", help="record matching Windows guest resources")
    guest.add_argument("--runtime-source", type=Path, required=True)
    guest.add_argument("--resource-source", type=Path, required=True)
    guest.add_argument("--native-receipt", type=Path)
    guest.add_argument("--output", type=Path)
    guest.set_defaults(function=write_guest)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()

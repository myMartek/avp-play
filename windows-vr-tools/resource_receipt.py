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
)
WINE_TOOLS = {
    "wineboot.exe", "services.exe", "winedevice.exe", "explorer.exe",
    "conhost.exe", "rundll32.exe", "start.exe", "plugplay.exe",
    "rpcss.exe", "winecfg.exe",
}


def fail(message):
    raise SystemExit(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
               "guest": {"resourcesSha256": guest["resourcesSha256"]}}
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

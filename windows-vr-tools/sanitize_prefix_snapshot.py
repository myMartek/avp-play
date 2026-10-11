#!/usr/bin/env python3
"""Make a Wine-generated snapshot portable without following host links."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def sanitize(source, output, receipt):
    if source.is_symlink() or not source.is_file():
        raise SystemExit("Source snapshot must be a regular archive.")
    if output.exists() or receipt.exists():
        raise SystemExit("Choose fresh portable archive and receipt paths.")
    output.parent.mkdir(parents=True, exist_ok=True)
    removed = []
    removed_metadata = []
    folders = {"Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"}
    try:
        with output.open("xb") as destination:
            with tarfile.open(source, "r:gz") as original, tarfile.open(fileobj=destination, mode="w:gz", format=tarfile.USTAR_FORMAT) as portable:
                for member in original:
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or ".." in path.parts or "\\" in member.name:
                        raise SystemExit("Nonportable path in source prefix snapshot.")
                    # BSD tar may serialize macOS extended attributes as
                    # AppleDouble sidecars. These are host packaging metadata,
                    # not Wine registry or Windows prefix files.
                    if any(part.startswith("._") or part == ".DS_Store" for part in path.parts):
                        removed_metadata.append(member.name)
                        continue
                    if member.issym() or member.islnk():
                        removed.append(member.name)
                        if path.parts[:-1] == ("prefix", "drive_c", "users", "madeira") and path.name in folders:
                            directory = tarfile.TarInfo(member.name)
                            directory.type = tarfile.DIRTYPE
                            directory.mode = 0o755
                            directory.mtime = int(member.mtime)
                            portable.addfile(directory)
                        continue
                    if not (member.isfile() or member.isdir()):
                        raise SystemExit("Special file in source prefix snapshot.")
                    # Recreate only format-required long-path PAX fields;
                    # discard host-specific xattrs, ACLs, and ownership names.
                    member.pax_headers = {}
                    member.mtime = int(member.mtime)
                    member.uname = member.gname = ""
                    member.uid = member.gid = 0
                    stream = original.extractfile(member) if member.isfile() else None
                    try:
                        portable.addfile(member, stream)
                    finally:
                        if stream:
                            stream.close()
        payload = {
            "schemaVersion": 1,
            "operation": "remove-host-links-without-dereferencing",
            "archiveFormat": "ustar",
            "sourceArchiveSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "portableArchiveSha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "removedLinkNames": removed,
            "removedHostMetadataNames": removed_metadata,
        }
        receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    except BaseException:
        output.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    sanitize(args.source, args.output, args.receipt)

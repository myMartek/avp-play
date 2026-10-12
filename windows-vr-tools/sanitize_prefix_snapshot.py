#!/usr/bin/env python3
"""Make a Wine-generated snapshot portable without following host links."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tarfile
import tempfile


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitize(source, output, receipt):
    if source.is_symlink() or not source.is_file():
        raise SystemExit("Source snapshot must be a regular archive.")
    if output.exists() or output.is_symlink() or receipt.exists() or receipt.is_symlink():
        raise SystemExit("Choose fresh portable archive and receipt paths.")
    output.parent.mkdir(parents=True, exist_ok=True)
    removed = []
    removed_metadata = []
    folders = {"Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"}
    created_output = False
    try:
        with output.open("xb") as destination:
            created_output = True
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
                    # USTAR is required by the native extractor; discard
                    # host-specific PAX fields, xattrs, ACLs, and ownership.
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
            "sourceArchiveSha256": sha256_file(source),
            "portableArchiveSha256": sha256_file(output),
            "removedLinkNames": removed,
            "removedHostMetadataNames": removed_metadata,
        }
        receipt.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".prefix-receipt-", dir=receipt.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, indent=2, sort_keys=True)
                stream.write("\n")
            # Publish a complete receipt without overwriting a racing writer
            # or following a link created since the initial path check.
            os.link(temporary, receipt)
        finally:
            Path(temporary).unlink(missing_ok=True)
    except BaseException:
        if created_output:
            output.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    sanitize(args.source, args.output, args.receipt)

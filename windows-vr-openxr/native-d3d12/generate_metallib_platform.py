#!/usr/bin/env python3
"""Generate shader-container target constants from this build's xros metallib.

Run only as part of an explicitly authorized build after xcrun --sdk xros metal
and metallib have produced the reference library. Never use a downloaded macOS
or iOS shader library as a visionOS platform template.
"""
import argparse
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.reference.is_symlink() or not args.reference.is_file():
        raise SystemExit("The xros compiler reference must be a regular metallib file.")
    with args.reference.open("rb") as source:
        header = source.read(16)
    if len(header) != 16 or header[:4] != b"MTLB":
        raise SystemExit("The xros compiler reference has no supported metallib header.")
    platform, version_major, version_minor = struct.unpack_from("<HHH", header, 4)
    library_type, operating_system = struct.unpack_from("<BB", header, 10)
    os_major, os_minor = struct.unpack_from("<HH", header, 12)
    if library_type != 0 or version_major != 2:
        raise SystemExit("This source writer supports executable metallib version 2 containers only.")
    # 0x8001 / 0x81 are the upstream desktop-only defaults, not xros metadata.
    if platform == 0x8001 or operating_system == 0x81:
        raise SystemExit("A macOS shader library cannot serve as an xros target reference.")
    text = "\n".join([
        "#pragma once",
        "// Generated from this build's xcrun --sdk xros compiler output.",
        f"#define WVR_METALLIB_TARGET_PLATFORM {platform}u",
        f"#define WVR_METALLIB_TARGET_OS {operating_system}u",
        f"#define WVR_METALLIB_TARGET_OS_MAJOR {os_major}u",
        f"#define WVR_METALLIB_TARGET_OS_MINOR {os_minor}u",
        f"#define WVR_METALLIB_REFERENCE_VERSION_MAJOR {version_major}u",
        f"#define WVR_METALLIB_REFERENCE_VERSION_MINOR {version_minor}u",
        "",
    ])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate a separate visionOS source/build-script overlay; do not build it.

Upstream source caches remain unchanged. This mechanical SDK retargeting is
unverified and cannot establish that upstream private API use works on visionOS.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def ignore_cache_files(directory, names):
    ignored = {".git", "tests", "unittests", "research", "build-ios", "build-arm64ec", "build-macos", "obj"}
    return [name for name in names if name in ignored or name.endswith((".a", ".o"))]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "runtime-source")
    parser.add_argument("--source", type=Path, default=ROOT / "third-party/madeira",
                        help="Pinned Madeira source; use a local cache outside cloud-synced Documents when needed")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if output.exists():
        raise SystemExit("Output exists; choose a new directory. Existing source is never reset or removed.")
    lock = json.loads((ROOT / "windows-vr-tools/sources.lock.json").read_text())
    expected = next(item["revision"] for item in lock["sources"] if item["name"] == "madeira")
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if actual != expected:
        raise SystemExit("Madeira source revision does not match the lock file.")
    required = ["FEX/FEXCore/include", "wine/dlls/ntdll", "dxmt/src/nvngx"]
    if any(not (source / path).exists() for path in required):
        raise SystemExit("Acquire pinned recursive source dependencies first.")
    shutil.copytree(source, output, ignore=ignore_cache_files, symlinks=True)
    # Isolate git apply from the enclosing project's repository and keep its
    # normal path traversal protections enabled.
    subprocess.run(["git", "init", "--quiet"], cwd=output, check=True)
    # Only build machinery is retargeted. Never change FEX core instructions or
    # blindly relabel prebuilt iOS Mach-O archives as visionOS binaries.
    for path in (output / "build").rglob("*.sh"):
        original = path.read_text()
        updated = original.replace("--sdk iphoneos", "--sdk xros").replace("-sdk iphoneos", "-sdk xros")
        updated = updated.replace("-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_SYSTEM_NAME=visionOS")
        updated = updated.replace("-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_OSX_SYSROOT=xros")
        updated = updated.replace("-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0")
        updated = updated.replace("-miphoneos-version-min=17.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-miphoneos-version-min=18.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-target arm64-apple-ios17.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-target arm64-apple-ios18.0", "-target arm64-apple-xros27.0")
        # Keep output folder names stable for upstream relative includes. The
        # generated directory has no pre-existing iOS objects or CMake cache.
        path.write_text(updated)
    # Extend only the generated build-system platform allowlist. FEX's Apple
    # source path already uses APPLE; its top-level allowlist predates visionOS.
    fex_cmake = output / "FEX/CMakeLists.txt"
    fex_configuration = fex_cmake.read_text()
    fex_cmake.write_text(fex_configuration.replace(
        'OR CMAKE_SYSTEM_NAME STREQUAL "iOS"))',
        'OR CMAKE_SYSTEM_NAME STREQUAL "iOS" OR CMAKE_SYSTEM_NAME STREQUAL "visionOS"))'
    ))
    overlay_dirs = [
        (ROOT / "windows-runtime-plugin/patches", output),
        (ROOT / "windows-vr-ngx/patches", output / "dxmt"),
        (ROOT / "windows-vr-openxr/patches", output / "dxmt")
    ]
    for directory, patch_root in overlay_dirs:
        if directory.exists():
            for patch in sorted(directory.glob("*.patch")):
                # Applies source edits only; no dry run, build, or executable probe.
                if patch_root != output:
                    subprocess.run(["git", "init", "--quiet"], cwd=patch_root, check=True)
                subprocess.run(["git", "apply", str(patch)], cwd=patch_root, check=True)
    supplemental = {
        ROOT / "windows-vr-ngx/src/WVRMetalFXWMTBridge.h": output / "dxmt/src/winemetal/unix/WVRMetalFXWMTBridge.h",
        ROOT / "windows-vr-ngx/src/WVRMetalFXWMTBridge.inc": output / "dxmt/src/winemetal/unix/WVRMetalFXWMTBridge.inc",
        ROOT / "windows-vr-ngx/include/WindowsVRNGX.h": output / "dxmt/src/nvngx/WindowsVRNGX.h",
        ROOT / "windows-vr-metal/Sources/WindowsVRMetalABI/include/WindowsVRMetalC.h": output / "dxmt/src/winemetal/unix/WindowsVRMetalC.h"
    }
    for original, destination in supplemental.items():
        if not original.exists():
            raise SystemExit(f"Missing project source: {original}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)
    transport_headers = [
        (ROOT / "windows-vr-openxr/include/WindowsVRD3D11ContextExt.h", "src/d3d11/WindowsVRD3D11ContextExt.h"),
        (ROOT / "windows-vr-openxr/include/WindowsVRWMTBridge.h", "src/winemetal/WindowsVRWMTBridge.h"),
        (ROOT / "windows-vr-native/include/WindowsVRCompositorBridge.h", "src/winemetal/WindowsVRCompositorBridge.h"),
        (ROOT / "windows-vr-native/include/WindowsVRCompositorBridge.h", "src/winemetal/unix/WindowsVRCompositorBridge.h"),
    ]
    for original, relative_destination in transport_headers:
        destination = output / "dxmt" / relative_destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)
    (output / "VISIONOS-SOURCE-NOTICE.md").write_text(
        "Generated from pinned Madeira source. Build scripts target xros 27; native archives must be rebuilt. "
        "No build or runtime validation is implied. Preserve upstream licenses.\n"
    )
    print(f"Prepared source overlay at {output}. No build or test was performed.")

if __name__ == "__main__":
    main()

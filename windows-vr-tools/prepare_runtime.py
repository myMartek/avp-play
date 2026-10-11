#!/usr/bin/env python3
"""Generate a separate visionOS source/build-script overlay; do not build it.

Upstream source caches remain unchanged. This mechanical SDK retargeting is
unverified and cannot establish that upstream private API use works on visionOS.
"""
import argparse
import atexit
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def ignore_cache_files(directory, names):
    # Preserve the pinned source graph, including disabled test metadata:
    # Wine's makedep parses test Makefile.in files even with --disable-tests.
    # Build flags and resource staging prevent tests from running or shipping.
    ignored = {".git", "research", "build-ios", "build-arm64ec", "build-macos", "obj"}
    return [name for name in names if name in ignored or name.endswith((".a", ".o"))]


def project_patch_hashes():
    directories = (
        ROOT / "windows-runtime-plugin/patches",
        ROOT / "windows-vr-ngx/patches",
        ROOT / "windows-vr-openxr/patches",
        ROOT / "windows-vr-openvr/patches",
    )
    hashes = {}
    for directory in directories:
        if directory.exists():
            for patch in sorted(directory.glob("*.patch")):
                # The baseline applies only the D3D11 transport patch here.
                # Modern DXMT patches have their own profile source-tree and
                # integration-input receipts; changing them must not invalidate
                # an unchanged Madeira/FEX/Wine baseline source overlay.
                if (directory == ROOT / "windows-vr-openxr/patches"
                        and patch.name != "0001-dxmt-wvr-frame-bridge.patch"):
                    continue
                hashes[patch.relative_to(ROOT).as_posix()] = hashlib.sha256(patch.read_bytes()).hexdigest()
    # Transport headers and copied adapter sources are ABI inputs too. Reusing
    # an overlay after only a header changed would mix incompatible host/guest code.
    additional_inputs = (
        "windows-vr-openxr/include/WindowsVRD3D11ContextExt.h",
        "windows-vr-openxr/include/WindowsVRD3D12CommandQueueExt.h",
        "windows-vr-openxr/include/WindowsVRWMTBridge.h",
        "windows-vr-native/include/WindowsVRCompositorBridge.h",
        "windows-vr-ngx/src/WVRMetalFXWMTBridge.h",
        "windows-vr-ngx/src/WVRMetalFXWMTBridge.inc",
        "windows-vr-ngx/include/WindowsVRNGX.h",
        "windows-vr-metal/Sources/WindowsVRMetalABI/include/WindowsVRMetalC.h",
        "windows-vr-openxr/src/WindowsVROpenXR.cpp",
        "windows-vr-openxr/CMakeLists.txt",
        "windows-vr-tools/prepare_runtime.py",
        "windows-vr-tools/prepare_wine_native.sh",
        "windows-runtime-plugin/d3d12/0001-embedded-dxmt-dispatch.patch",
    )
    for relative in additional_inputs:
        source = ROOT / relative
        if not source.is_file():
            raise SystemExit(f"Missing integration source input: {source}")
        hashes[relative] = hashlib.sha256(source.read_bytes()).hexdigest()
    return dict(sorted(hashes.items()))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "runtime-source")
    parser.add_argument("--source", type=Path, default=ROOT / "third-party/madeira",
                        help="Pinned Madeira source; use a local cache outside cloud-synced Documents when needed")
    parser.add_argument("--reuse-existing", action="store_true",
                        help="Reuse an existing prepared overlay only when its pinned provenance matches")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if output.exists() and not args.reuse_existing:
        raise SystemExit("Output exists; use --reuse-existing to verify and reuse it. Existing source is never reset or removed.")
    lock = json.loads((ROOT / "windows-vr-tools/sources.lock.json").read_text())
    pinned = next(item for item in lock["sources"] if item["name"] == "madeira")
    expected = pinned["revision"]
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if actual != expected:
        raise SystemExit("Madeira source revision does not match the lock file.")
    if output.exists():
        provenance_path = output / "AVPPLAY_SOURCE_PROVENANCE.json"
        try:
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SystemExit(f"Existing overlay has no readable source provenance: {exc}") from exc
        if (provenance.get("schemaVersion") != 1 or provenance.get("sourceUrl") != pinned["url"]
                or provenance.get("sourceRevision") != expected
                or provenance.get("integrationPatchSha256") != project_patch_hashes()):
            raise SystemExit("Existing overlay provenance does not match the locked source and current integration patches.")
        print(f"Reusing pinned source overlay at {output}; no build or test was performed.")
        return
    required = ["FEX/FEXCore/include", "wine/dlls/ntdll", "dxmt/src/nvngx"]
    if any(not (source / path).exists() for path in required):
        raise SystemExit("Acquire pinned recursive source dependencies first.")
    final_output = output
    final_output.parent.mkdir(parents=True, exist_ok=True)
    staging_root = Path(tempfile.mkdtemp(prefix=".runtime-source-prepare-", dir=final_output.parent))
    atexit.register(shutil.rmtree, staging_root, ignore_errors=True)
    output = staging_root / "overlay"
    shutil.copytree(source, output, ignore=ignore_cache_files, symlinks=True)
    wine_version = (source / "wine/VERSION").read_text(encoding="utf-8").strip()
    (output / "app/Madeira/AVPPlayWineBuild.c").write_text(
        "/* Generated from the locked Wine source version. */\n"
        f"const char wine_build[] = {json.dumps(wine_version)};\n",
        encoding="utf-8",
    )
    # Isolate git apply from the enclosing project's repository and keep its
    # normal path traversal protections enabled.
    subprocess.run(["git", "init", "--quiet"], cwd=output, check=True)
    # Only build machinery is retargeted. Never change FEX core instructions or
    # blindly relabel prebuilt iOS Mach-O archives as visionOS binaries.
    for path in (output / "build").rglob("*.sh"):
        original = path.read_text()
        updated = original.replace("--sdk iphoneos", "--sdk xros").replace("-sdk iphoneos", "-sdk xros")
        updated = updated.replace("-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_SYSTEM_PROCESSOR=arm64")
        updated = updated.replace("-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_OSX_SYSROOT=xros")
        updated = updated.replace("-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0")
        updated = updated.replace("-miphoneos-version-min=17.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-miphoneos-version-min=18.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-target arm64-apple-ios17.0", "-target arm64-apple-xros27.0")
        updated = updated.replace("-target arm64-apple-ios18.0", "-target arm64-apple-xros27.0")
        # Keep output folder names stable for upstream relative includes. The
        # generated directory has no pre-existing iOS objects or CMake cache.
        path.write_text(updated)
    fex_revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD:FEX"], cwd=source, text=True
    ).strip()
    fex_build_script = output / "build/fex-ios/build.sh"
    fex_build_script.write_text(fex_build_script.read_text().replace(
        "-DENABLE_CCACHE=ON",
        "-DENABLE_CCACHE=OFF -DTUNE_CPU=generic -DFEX_IOS_HOST_BUILD=ON "
        f"-DOVERRIDE_VERSION=FEX-{fex_revision[:7]} -DOVERRIDE_HASH={fex_revision}"
    ).replace(
        "--target FEXCore FEXCore_Base",
        "--target FEXCore FEXCore_Base JemallocLibs"
    ))
    fex_pe_script = output / "build/fex-arm64ec/build.sh"
    fex_pe_config = fex_pe_script.read_text()
    if "-DMINGW_TRIPLE=" not in fex_pe_config:
        fex_pe_config = fex_pe_config.replace(
            "-DENABLE_CCACHE=ON \\",
            "-DENABLE_CCACHE=OFF -DMINGW_TRIPLE=arm64ec-w64-mingw32 "
            "-DTUNE_CPU=generic -DENABLE_LTO=OFF -DFEX_IOS_HOST_BUILD=ON "
            f"-DOVERRIDE_VERSION=FEX-{fex_revision[:7]} -DOVERRIDE_HASH={fex_revision} \\",
        )
    if "-DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST" not in fex_pe_config:
        fex_pe_config = fex_pe_config.replace(
            "-DBUILD_TESTING=OFF",
            "-DCMAKE_C_FLAGS=-DFEX_IOS_HOST "
            '"-DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -D__USE_MINGW_ANSI_STDIO=1 '
            '-D__USE_MINGW_ACCESS -fno-lto" '
            "-DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST -DBUILD_TESTING=OFF",
            1,
        )
        if "-DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST" not in fex_pe_config:
            raise SystemExit("Could not inject the ARM64EC FEX cross-compiler flags into build/fex-arm64ec/build.sh")
    if "-DMINGW_TRIPLE=arm64ec-w64-mingw32" not in fex_pe_config:
        raise SystemExit("Could not select the ARM64EC LLVM-MinGW triple in build/fex-arm64ec/build.sh")
    fex_pe_toolchain = output / "build/fex-arm64ec/avp_toolchain.cmake"
    fex_pe_toolchain.write_text(
        'include("${CMAKE_CURRENT_LIST_DIR}/../../FEX/Data/CMake/toolchain_mingw.cmake")\n'
        'set(CMAKE_CXX_STANDARD_LIBRARIES '
        '"'
        '${CMAKE_CURRENT_LIST_DIR}/../../toolchains/llvm-mingw-20260421-ucrt-macos-universal/'
        'arm64ec-w64-mingw32/lib/libc++.dll.a '
        '${CMAKE_CURRENT_LIST_DIR}/../../toolchains/llvm-mingw-20260421-ucrt-macos-universal/'
        'arm64ec-w64-mingw32/lib/libunwind.dll.a" CACHE STRING "" FORCE)\n'
        'set(CMAKE_CXX_STANDARD_LIBRARIES "${CMAKE_CXX_STANDARD_LIBRARIES} '
        '${CMAKE_CURRENT_LIST_DIR}/../../toolchains/llvm-mingw-20260421-ucrt-macos-universal/'
        'arm64ec-w64-mingw32/lib/libmingwex.a" CACHE STRING "" FORCE)\n'
        # FEX's ARM64EC C++ code references the Windows UCRT spelling of
        # snprintf/access directly. The compiler driver normally supplies
        # this archive, but the target's `-static` option suppresses the
        # needed EC thunk archive members, so make the pinned UCRT explicit.
        'set(CMAKE_CXX_STANDARD_LIBRARIES "${CMAKE_CXX_STANDARD_LIBRARIES} '
        '${CMAKE_CURRENT_LIST_DIR}/../../toolchains/llvm-mingw-20260421-ucrt-macos-universal/'
        'arm64ec-w64-mingw32/lib/libucrtbase.a" CACHE STRING "" FORCE)\n'
        # The ARM64EC LLVM-MinGW toolchain's libc++.a is incomplete for the
        # APIs FEX uses; the matching libc++.dll import library supplies them.
        # `-nostdlib++` is applied to this target below, so do not also request
        # `-static-libstdc++` here (that would pull libc++.a and duplicate
        # exports from libc++.dll.a). Keep the C/SEH runtimes static.
        'set(CMAKE_SHARED_LINKER_FLAGS "-static -static-libgcc -Wl,--file-alignment=4096,/mllvm:-align-loops=1" CACHE STRING "" FORCE)\n'
        'set(CMAKE_EXE_LINKER_FLAGS "-static -static-libgcc -Wl,--file-alignment=4096,/mllvm:-align-loops=1" CACHE STRING "" FORCE)\n'
    )
    fex_pe_cmake = output / "FEX/Source/Windows/ARM64EC/CMakeLists.txt"
    fex_pe_cmake.write_text(fex_pe_cmake.read_text().replace(
        "target_link_options(arm64ecfex PRIVATE -static)",
        "target_link_options(arm64ecfex PRIVATE -static -nostdlib++)",
    ))
    fex_pe_config = fex_pe_config.replace(
        '-DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake"',
        '-DCMAKE_TOOLCHAIN_FILE="$R/build/fex-arm64ec/avp_toolchain.cmake"',
    )
    fex_pe_config = fex_pe_config.replace(
        'B="$R/FEX/build-arm64ec"', 'B="$R/FEX/build-arm64ec-avp"'
    )
    fex_pe_script.write_text(fex_pe_config)
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
    patch_hashes = {}
    for directory, patch_root in overlay_dirs:
        if directory.exists():
            for patch in sorted(directory.glob("*.patch")):
                # The experimental queue, mobile/native port, modern D3D11
                # bridge, and xros metallib overlays belong only to the pinned
                # modern DXMT profile; never apply them to Madeira baseline.
                if directory == ROOT / "windows-vr-openxr/patches" and patch.name != "0001-dxmt-wvr-frame-bridge.patch":
                    continue
                patch_hashes[patch.relative_to(ROOT).as_posix()] = hashlib.sha256(patch.read_bytes()).hexdigest()
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
    provenance = {
        "schemaVersion": 1,
        "sourceUrl": pinned["url"],
        "sourceRevision": expected,
        "integrationPatchSha256": project_patch_hashes(),
    }
    (output / "AVPPLAY_SOURCE_PROVENANCE.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output / "VISIONOS-SOURCE-NOTICE.md").write_text(
        "Generated from pinned Madeira source. Build scripts target xros 27; native archives must be rebuilt. "
        "No build or runtime validation is implied. Preserve upstream licenses.\n"
    )
    output.replace(final_output)
    print(f"Prepared source overlay at {final_output}. No build or test was performed.")

if __name__ == "__main__":
    main()

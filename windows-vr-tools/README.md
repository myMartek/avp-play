# Pinned source acquisition and visionOS preparation

The lock records the Madeira dependency tree, Valve OpenVR headers, and ALVR
tracking reference used by the local Windows VR integration. `fetch_sources.py`
only downloads source. `prepare_runtime.py` creates an independent `runtime-source`
tree, removes cached native iOS archives from the copy, retargets upstream native
build scripts to xros 27, and applies project-owned integration patches. Neither
script compiles dependencies or runs games/tests. The source preparation step is
unverified until it is actually executed; the build recipe itself remains
unverified even after source preparation.

Upstream native library builds require external LLVM and Windows cross-compilation
toolchains described in Madeira's `docs/BUILDING.md`. PE DLLs and native archives
are different: ARM64EC Windows builtins can be packaged as Windows guest modules,
but native iOS archives must be rebuilt for visionOS. Do not relabel their Mach-O
platform or use binary header rewriting to make them link.

Build execution has been authorized toward the first packaged app, but the
build script has not been run. Full Xcode with the visionOS SDK and an external
LLVM source/build are required first; the current host has only Command Line
Tools, and neither LLVM path is part of the pinned source lock. Tests, game
launches, and device runs remain deferred. Recursive source acquisition can
contain upstream test data; those executables are not run or packaged.

The dependency caches retain upstream licenses. They are ignored by this
repository; source/build recipes and project-owned adapters are tracked separately.
No NVIDIA proprietary model, game files, or purchase-check bypass is distributed.

## Deferred assembly order

After build execution is explicitly authorized:

1. Acquire pinned sources with `fetch_sources.py`, then prepare a fresh source overlay with `prepare_runtime.py`. The latter applies source edits; it does not build.
2. Install/select full Xcode with the xros SDK. The source lock does not acquire LLVM; `prepare_llvm.sh` uses separate `toolchains/llvm-project`, `llvm-host-build`, and `llvm-ios-build` trees. `prepare_llvm.sh fetch` acquires and verifies the pinned commit; `configure` also builds a host `llvm-tblgen` and configures the visionOS 27 target; `build` additionally compiles the target LLVM archives (no tests). Set `AVPPLAY_LLVM_TOOLCHAINS_ROOT` to an absolute external-volume directory when the project volume lacks space; the script exposes the three expected paths under `runtime-source/toolchains/` as symlinks and refuses conflicting paths. Then use the opt-in `build_runtime.sh` to rebuild Madeira's other native archives. Build Windows Wine/DXMT guest modules separately; the guest and host WMT ABI must come from the same prepared overlay.
3. Build `windows-vr-openvr/` and `windows-vr-openxr/` with their documented Windows toolchain, using one staging prefix. The resulting tree must contain `WindowsVR/Guest/x64/OpenComposite/bin/vrclient_x64.dll` and `WindowsVR/Guest/x64/wvr_openxr.dll`.
4. Supply a clean nonempty Wine prefix template and stage resources using `stage_resources.py --guest-stage <combined-stage-root>`. The script refuses unsafe templates and existing outputs. Its default output creates the sibling `Resources/Runtime` and `Resources/WindowsVR` trees required by XcodeGen.
5. Generate `visionos-windows-vr/project.yml` with XcodeGen, configure signing, then build/install through Xcode. A script-capable JIT helper must be paired with the headset.

These instructions and their configure/build steps have not been run. In particular,
archive inspection did not establish a usable prefix template, external LLVM
source/build are absent, the full Xcode/xros SDK is being installed, and platform
compatibility is unverified. Keep the large LLVM build on a volume with adequate
free space; it must not compete with the active Xcode download. Do not infer successful compilation from source
preparation or toolchain-directory presence alone.

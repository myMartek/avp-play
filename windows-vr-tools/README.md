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

Assembly is explicitly gated by `AVPPLAY_ALLOW_RUNTIME_BUILD=1`. `AVPPLAY_BUILD_WINE_PE=1` additionally opts into the pinned Wine ARM64EC PE and DXMT build recipe. Neither script invokes Wine or guest executables. XcodeGen expands `${AVPPLAY_RUNTIME_SOURCE}` in `project.yml`; the assembler exports it, and manual project generation must export the same absolute prepared-overlay path. Native archives and guest resources carry a shared-source provenance receipt covering integration patches, transported headers, adapter sources, and the OpenXR source; staging refuses mismatched or stale closures.

Full Xcode with the visionOS SDK, an external LLVM-MinGW bundle, and the clean user-supplied Wine prefix template are required inputs. Neither LLVM path is part of the pinned source lock. Recursive source acquisition can contain upstream test data; those executables are not run or packaged. Tests, game launches, and device runs remain deferred.

The dependency caches retain upstream licenses. They are ignored by this
repository; source/build recipes and project-owned adapters are tracked separately.
No NVIDIA proprietary model, game files, or purchase-check bypass is distributed.

## Deferred assembly order

The assembly path has three restartable states: a fresh source tree is acquired and prepared; a prepared tree is reused only with `AVPPLAY_REUSE_PREPARED_SOURCE=1`; an existing staged resource pair is reused only with its exact stage manifest. Choose a fresh absolute `AVPPLAY_RUNTIME_SOURCE` to start over; no existing overlay or Resources tree is silently reset.

A complete assembly needs a clean upstream prefix archive and its provenance JSON, an externally extracted LLVM-MinGW bundle, a build volume, an Apple development team, and the three upstream license files. Madeira's locked build record identifies [`llvm-mingw-20260421-ucrt-macos-universal.tar.xz`](https://github.com/mstorsjo/llvm-mingw/releases/tag/20260421), SHA-256 `bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7`; extract it and point `AVPPLAY_LLVM_MINGW_ROOT` at its root. The default licenses are `runtime-source/LICENSE`, `third-party/opencomposite/LICENSE`, and `third-party/openxr/LICENSE`; set `AVPPLAY_MADEIRA_LICENSE`, `AVPPLAY_OPENCOMPOSITE_LICENSE`, or `AVPPLAY_OPENXR_LICENSE` when the source uses another path. To opt into building PE resources from the prepared pinned overlay, set `AVPPLAY_BUILD_WINE_PE=1`; otherwise supply a matching `AVPPLAY_WINE_RESOURCE_SOURCE` containing its generated `AVPPLAY_GUEST_BUILD_RECEIPT.json`.

```sh
export AVPPLAY_ALLOW_RUNTIME_BUILD=1
export AVPPLAY_RUNTIME_SOURCE="/absolute/path/to/runtime-source"
export AVPPLAY_SOURCE_CACHE_ROOT="/absolute/path/to/source-cache"
# export AVPPLAY_REUSE_PREPARED_SOURCE=1  # set only when runtime-source already exists
export AVPPLAY_WINE_PREFIX_TEMPLATE="/absolute/path/to/clean-prefix-template.tar.gz"
export AVPPLAY_WINE_PREFIX_PROVENANCE="/absolute/path/to/prefix-template-provenance.json"
export AVPPLAY_LLVM_MINGW_ROOT="/absolute/path/to/llvm-mingw"
export AVPPLAY_BUILD_ROOT="/absolute/path/to/external-build-volume/avp-play"
export AVPPLAY_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export AVPPLAY_BUILD_WINE_PE=1          # omit only when supplying matching external guest resources
bash windows-vr-tools/assemble_runtime.sh
```

The opt-in PE recipe uses the pinned Madeira commands at revision `48f976429c189f8396e23d251d8a82f43c705922`: `bash build/wine-pe/build-ntdll.sh`, `bash build/wine-pe/build-modules.sh cryptsp d3dx11_43 msvcp110 msvcr110 xaudio2_7`, `bash build/fex-arm64ec/build.sh`, then `meson setup dxmt/build-arm64ec dxmt -Dbuildtype=release -Dwine_build_path=../../wine/build-arm64ec --cross-file=dxmt/build-arm64ec-win.txt` and `ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll src/d3d11/d3d11.dll`. The build wrapper uses these same paths and never executes Wine. Madeira documents the Wine PE steps and DXMT route in [`docs/BUILDING.md`](https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/docs/BUILDING.md); exact scripts: [`build-ntdll.sh`](https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/build/wine-pe/build-ntdll.sh), [`build-modules.sh`](https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/build/wine-pe/build-modules.sh), and [`build/fex-arm64ec/build.sh`](https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/build/fex-arm64ec/build.sh). The recipe reuses the pinned source farm for aarch64 builtins/NLS/legal assets and adds the newly built ARM64EC ntdll/modules, FEX translator and DXMT DLLs. It does not invent aarch64 PE files.

A clean source-only prefix is not available upstream at this lock revision. [`tools/build-prefix-snapshot.sh`](https://raw.githubusercontent.com/willfaust/Madeira/48f976429c189f8396e23d251d8a82f43c705922/tools/build-prefix-snapshot.sh) creates registry files by running `wineboot --init`, then normalizes and strips the resulting prefix; it is not a static skeleton/registry copy recipe. The assembler and staging tool never run Wine. A user must supply a clean archive created outside this tooling and a JSON provenance record with `schemaVersion: 1`, `madeiraRevision: "48f976429c189f8396e23d251d8a82f43c705922"`, the archive's actual `templateSha256`, `originUrl` set to the pinned raw `tools/build-prefix-snapshot.sh` URL, `creationCommand: "bash tools/build-prefix-snapshot.sh"`, `wineExecuted: true`, and the actual `wineVersion`. The metadata is a provenance contract, not proof of cleanliness; staging still checks archive structure, portable paths, exclusions and registry/skeleton presence. Do not fabricate registries or mark an unverified archive as clean.

The native build writes `runtime-source/AVPPLAY_NATIVE_BUILD_RECEIPT.json` after requiring hashes for the pinned native archive closure. The guest builder writes `app/Madeira/AVPPLAY_GUEST_BUILD_RECEIPT.json`, binding guest resource hashes to the exact native receipt and shared overlay provenance. `stage_resources.py` consumes both receipts, verifies every native archive and PE/NLS/legal resource hash, stages all three upstream licenses, and commits Runtime/WindowsVR together. It emits `Runtime/AVPPLAY_RESOURCE_STAGE.json`; reruns use `--reuse-existing` only if both complete trees and every template/provenance/license/build input still match. Native and guest build outputs may be resumed in the same prepared overlay; a failed resource stage does not expose partial Resources trees.

The staging command can also be used independently after the guest DLLs and provenance receipts are present:

```sh
python3 windows-vr-tools/stage_resources.py \
  --source /absolute/path/to/matching-overlay/app/Madeira \
  --runtime-source /absolute/path/to/matching-overlay \
  --native-receipt /absolute/path/to/matching-overlay/AVPPLAY_NATIVE_BUILD_RECEIPT.json \
  --guest-stage /absolute/path/to/guest-stage \
  --prefix-template /absolute/path/to/clean-prefix-template.tar.gz \
  --prefix-provenance /absolute/path/to/prefix-template-provenance.json \
  --madeira-license /absolute/path/to/matching-overlay/LICENSE \
  --opencomposite-license /absolute/path/to/opencomposite/LICENSE \
  --openxr-license /absolute/path/to/openxr/LICENSE
```

Required assembly tools are `python3`, Git, CMake, Ninja, XcodeGen, `xcodebuild`, and `xcrun`, plus a selected Xcode with the xros SDK. PE mode additionally needs Meson, bison 3+, and the pinned LLVM-MinGW cross tools. Keep `AVPPLAY_BUILD_ROOT` outside the checkout on a volume with adequate space. XcodeGen embeds the staged resource directories; signing needs a valid team and is not proof of runtime/device compatibility. No builds or staging were executed for this change.

## Experimental D3D12 transport source profile

The D3D12 queue transport is isolated from the existing source-only D3D11 baseline. `sources.lock.json` pins `dxmt-d3d12-experimental` to `3Shain/dxmt` revision `e94c312f5c054263acf261cfa109edf13e757587`; that source contains `src/d3d12` while `enable_d3d12` is off. The locked Madeira revision `48f976429c189f8396e23d251d8a82f43c705922` uses `willfaust/dxmt` revision `db546ee466ad50ec6463edb5fa183de11db43761`, which has no D3D12 implementation. Standard Madeira preparation skips the D3D12/modern-profile patches; it never substitutes the experimental source or applies the modern mobile-native port to baseline DXMT.

`fetch_sources.py --include-d3d12-experimental` acquires the extra source pin. `prepare_d3d12_experimental_source.sh` starts from the prepared Madeira runtime overlay, keeps its Wine/FEX/app sources, replaces only `dxmt/` with the clean pinned 3Shain checkout, applies the modern D3D11/D3D12/mobile/build overlays `0002`–`0006` and the profile-specific embedded-Wine dispatch patch (not legacy WMT/NGX overlays), copies all shared headers, and writes source/adaptation receipts. Patch `0005` selects xros AIR/metallib generation; the build derives container metadata from an xros metallib produced by that same build, not guessed constants. The fetched cache and baseline runtime overlay remain unchanged.

The new queue overlay implements the frozen `IMTLD3D12CommandQueueExt` contract in `windows-vr-openxr/include/WindowsVRD3D12CommandQueueExt.h`. It uses the actual DXMT `MTLD3D12Resource::texture->current()->texture()` path; signals a producer `MTLSharedEvent` on the same DIRECT queue after earlier queue work; submits through WMT V2; retains guest COM and Metal resource leases; and queues a consumer-event wait on reacquisition. Controls go through WMT V1. It accepts single-sample 2D/array RGBA8/BGRA8 targets, explicit slices, and bounded per-eye subrectangles no larger than the published producer dimensions. Static/repeated releases keep the latest consumer ticket; reacquisition waits before writes. The caller must release the submitted images in `D3D12_RESOURCE_STATE_COMMON`, as the frozen interface contract requires.

`prepare_d3d12_experimental_source.sh` now prepares a complete isolated runtime overlay: it copies the already-prepared locked Madeira app/FEX/Wine source tree, replaces only `dxmt/` with the pinned 3Shain tree, applies the modern Windows VR overlays `0002`–`0006` and the embedded-Wine binder patch, and copies every shared transport/Metal header. It creates a source-only provenance receipt with exact Madeira/DXMT/LLVM pins, source tree hash, integration input hashes, transport ABI, and native/WOW64 table names/version. A separate adaptation receipt records the applied native source patch; it does not claim compilation or runtime support. The ordinary `runtime-source` and `libdxmt_combined.a` stay the D3D11 baseline.

`build_d3d12_experimental.sh` is the explicit gated build entry point. It configures the pinned source's actual Meson ARM64EC cross file (`build-arm64ec.txt`) together with an xros native compiler file, uses the locked visionOS LLVM source/build and the prepared Madeira Wine ARM64EC tree, and discovers native airconv/DXBCParser sources and targets from Meson introspection/compile commands instead of hand-maintained source lists. It builds a distinct `libdxmt_d3d12_combined.a` plus ARM64EC `d3d11.dll`, `d3d12.dll`, `dxgi.dll`, and `winemetal.dll` from that same source tree. The binary build receipt is written only after the Meson/link commands finish and actual archive/DLL hashes, architecture, and required dispatch exports are read back. The profile rebuilds Madeira common native libraries from its own patched Wine source, not the baseline tree. A byte-identical conventional archive pathname is recorded in the generic resource ledger; app linking selects only the modern archive, never both libraries.

D3D12 assembly requires `AVPPLAY_ENABLE_D3D12=1`, `AVPPLAY_BUILD_WINE_PE=1`, the extra pinned DXMT fetch, and a fresh profile/build root. The x64 OpenComposite configure receives `WINDOWS_VR_ENABLE_D3D12=ON`; the existing x64 OpenXR client remains in the shared guest stage. The app linker selects only the modern archive with `AVPPLAY_DXMT_LINK_FLAG=-Wl,-force_load,<profile>/app/Madeira/libdxmt_d3d12_combined.a`, preserving the baseline `-ldxmt_combined` behavior when D3D12 is off and keeping modern dispatch/compiler symbols from being dead-stripped. `stage_d3d12_experimental.sh` verifies the selected archive and all four guest DLLs against the actual build receipt, then writes the source-pin profile receipt and `WindowsVR/GraphicsCapabilities.json`. `stage_resources.py --d3d12-stage ... --d3d12-native-archive ...` revalidates that receipt before copying the closure into `Runtime/arm64ec-windows/` and the capability/profile receipt beside the x64 clients.

All modern source patches and the embedded-Wine binder patch are required before profile preparation. The linked table/ABI handshake is checked independently of package JSON; unported 32-bit graphics paths fail closed. The pinned backend reports Shader Model 5.1 and rejects DXIL; no Shader Model 6, mesh shader or ray-tracing support is claimed. No source preparation, Meson configure, build, compiler, test, linter, patch applicability check, or runtime validation was run for this change. The recipe records no synthetic binary hash or ready flag; successful binary receipts can only be created by actually completing its commands. visionOS device/runtime compatibility remains unvalidated.



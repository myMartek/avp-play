# Experimental DXMT Direct3D 12 path

This is a source integration, not a built or validated game-compatibility claim.
No tests, builds, compiler runs, patch applicability checks, or app/game launches
are authorized for this implementation pass.

## Separate from the D3D11 baseline

The locked Madeira source uses `willfaust/dxmt` revision
`db546ee466ad50ec6463edb5fa183de11db43761`, which has no D3D12 frontend.
Upstream `3Shain/dxmt` revision `e94c312f5c054263acf261cfa109edf13e757587`
contains a D3D12 frontend; its source mobile port and rebuilt Wine/WMT binding are profile-specific and not interchangeable
with Madeira's fork. The upstream revision is an explicit experimental source
input, not an unpinned replacement for the existing D3D11 overlay.

## Guest and host contract

- A manifest uses `"graphics": "direct3D12"` and the existing
  `"backend": "windowsWineFEX"`. This is additive to schema version 1.
- The headset library/profiles and Mac transfer retain that exact graphics choice;
  they do not rewrite D3D12 to D3D11.
- The guest uses `XR_KHR_D3D12_enable`, D3D12 graphics requirements, the application's
  device and DIRECT command queue, and D3D12 swapchain resource records.
- The project queue interface is `IMTLD3D12CommandQueueExt`, IID
  `08e6b53f-ede5-4524-90b8-3445ef059b1e`, declared in
  `windows-vr-openxr/include/WindowsVRD3D12CommandQueueExt.h`.
- Color resources must be released in `D3D12_RESOURCE_STATE_COMMON`. Submission
  is ordered after earlier rendering on the bound queue; reacquisition orders
  a native consumer-event wait before subsequent writes on that queue.
- DXMT resolves its own resource into a real Metal texture. Guest COM pointers
  never become native Objective-C pointers. Slices/rectangles pass through the
  existing fixed-width WMT V2 record and native V2 compositor lease.
- The native compositor consumes color textures identically whether the guest
  frontend was D3D11 or D3D12. This does not implement composition depth,
  positional reprojection, frame generation, or temporal super resolution.

Applications remain responsible for their own transitions and cross-queue
synchronization. A runtime cannot infer unfinished writes on unrelated queues.

## Fail-closed launch capability

The optional export `windows_vr_graphics_capabilities_v1` advertises packaged
implementation bits: bit 0 is D3D11, bit 1 is experimental D3D12. Older V1 plugins
without the export are treated as D3D11-only. This is not a performance or
compatibility result.

The native host checks an app-bundled `WindowsVR/GraphicsCapabilities.json`
assembly contract (bounded regular file, schema version 1, explicit boolean `direct3D11` and `direct3D12`,
`d3d12TransportABI` 1), together with the matching ARM64EC `d3d11.dll`, `d3d12.dll`,
`dxgi.dll`, and `winemetal.dll` and the linked native count/ABI handshake. A marker alone is not a graphics backend, and must not be
created manually to bypass incomplete native/guest integration. The staging
pipeline must only emit it for a coherent package backed by provenance receipts.

The launcher blocks missing packages before JIT startup. The plugin independently
checks again during preflight and execution. A missing package never consumes a
session or silently selects D3D11. `WVR_GRAPHICS_API` is host-controlled; game
manifest environment values cannot override it. `WINEDLLOVERRIDES` is also host-controlled so stale prefix/game graphics DLLs cannot replace the compiled package.

## Source implementation checkpoint

Implemented in source:

- D3D12 extension discovery, graphics requirements, optional DLL loading,
  feature-level queries, adapter/device/queue identity checks, and DIRECT queue
  bindings in the guest OpenXR runtime.
- DEFAULT/COMMON color swapchains, typed D3D12 image enumeration, and the existing
  static/FIFO/frame/exit/input lifecycle through the queue interface.
- A pinned upstream DXMT queue overlay with real texture extraction, shared-event
  submission/reacquisition ordering, array/rect metadata, repeated static-image
  submission, canonical COM identity, and compositor-bound Metal device selection.
- An opt-in D3D12 OpenComposite source profile that excludes unnecessary Vulkan
  and OpenGL dependencies. The default remains D3D11-only.
- Isolated transactional source preparation and a future receipt-gated staging
  contract. Native launch capability checks the marker, pinned profile receipt,
  ARM64EC PE machines and actual guest DLL hashes.

The missing mobile/native integration is now implemented in source:

- `0003-dxmt-d3d12-visionos-native.patch` ports frameworks/runtime headers,
  remaps managed storage to shared memory, targets xros AIR, exports native
  tables/count/ABI, and gates unavailable desktop/temporal/Mach-sharing features.
- `0004-dxmt-modern-d3d11-wvr.patch` retains D3D11 Ext2/Ext3 on the modern source,
  using the same V2 GPU submission path as D3D12.
- `0005-dxmt-xros-metallib-target.patch` derives shader-container target metadata
  from the build's actual xros production metallib through
  `native-d3d12/generate_metallib_platform.py`; it does not guess visionOS enums.
- `0006-dxmt-arm64ec-native-build.patch` selects ARM64EC Wine import-library paths
  and an embedded native static target instead of desktop Wine dylibs.
- `windows-runtime-plugin/d3d12/0001-embedded-dxmt-dispatch.patch` binds the
  profile's rebuilt Wine Unix side to the modern archive, checking ABI/count and
  refusing unported 32-bit D3D9/WOW64 graphics calls.

Modern control/frame slots are **146/147**, in a native table with **148** entries;
the baseline has separate **151/152** extensions. Those tables must never mix.
Both embedded Wine and the native plugin verify the actual linked count/ABI.

`build_d3d12_experimental.sh` now invokes the real, gated `build_d3d12_profile.sh`,
not a permanent blocker stub. The profile preserves Madeira Wine/FEX/app sources,
applies modern patches 0002–0006 and the embedded-dispatch patch, rebuilds common
native libraries from the profile, and builds the matching native shader/WMT
archive plus four ARM64EC D3D11/D3D12/DXGI/winemetal DLLs. It discovers source lists
from the pinned Meson graph, builds exact Ninja outputs and Wine builtin
postprocessors, and records binary hashes only after actual successful commands.
Legacy frame/NGX overlays are not mixed into the modern profile.

The modern native archive is `libdxmt_d3d12_combined.a`; app linking force-loads
one modern archive, never modern and baseline together. A byte-identical
conventional pathname is used only for the generic resource ledger. OpenComposite
uses the explicit D3D11/D3D12-only profile, without unsupported Vulkan/OpenGL DLL
imports. Builtins stage under `Runtime/arm64ec-windows/`; x64 XR/OpenComposite
clients remain under `WindowsVR/Guest/x64/`.

Future authorized assembly opts in with `AVPPLAY_ENABLE_D3D12=1`,
`AVPPLAY_BUILD_WINE_PE=1`, and `AVPPLAY_ALLOW_RUNTIME_BUILD=1`, alongside normal
assembler inputs. It requires a Mac with Xcode/xros SDK, the pinned toolchains,
clean external prefix/provenance, legal notices and signing inputs. Source
preparation is transactional and does not reset the baseline or caches.

No preparation script, build, compiler, executable probe, or game ran during this
pass; no binary, capability marker, adaptation receipt, or build receipt was
produced. Editing tools emitted automatic Python syntax diagnostics.

### Upstream feature limits are not removed by a native port

The pinned D3D12 backend reports **Shader Model 5.1** and explicitly rejects DXIL
with `E_NOTIMPL`. Its initial route is **DXBC**, not Shader Model 6. Ray tracing,
mesh shaders, arbitrary D3D12 API coverage and universal game support are not
promised. Unavailable desktop capture/display management, cross-process Metal
sharing and visionOS temporal MetalFX calls fail closed. Composition depth,
frame generation, guest-pass foveation, D3D12 NGX/DLSS and finite XR wait-timeout
conformance remain unsupported. Initial launch is x64 Wine/FEX and one session
per app process; cooperative exit is not forced Wine thread termination.

## Remaining evidence

Native/guest build coherence, visionOS shader and Metal API availability,
upstream D3D12 API coverage, signing/JIT behavior, game startup, controller input,
correct stereo output, resource lifetimes, and performance require future
explicitly authorized build/device work. No D3D12 title is labeled compatible.

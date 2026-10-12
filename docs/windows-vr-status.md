# Windows VR implementation status

## Launch-free review (2026-10-12)

The implementation is an experimental contribution seeking further development
and Vision Pro testing by someone with a paid Apple Developer account. No Windows
VR game, signed headset installation, JIT session, controller session, or
performance benchmark has been tested on a headset. The checks below are offline
regressions and compilation, not game/runtime validation.

The PR branch incorporates upstream `main` through `9b654ca` (AVP Play 1.1.8).
It follows `CONTRIBUTING.md` with English/German `L()` strings and regression tests.
Local transfer validation is separated from device operations so its ownership,
path, manifest, and architecture checks can be exercised without a headset.

- Mac core: 160 tests, two skipped, zero failures; the two Keychain mutation
  tests were excluded separately.
- Windows VR contracts and localization: nine tests, zero failures.
- Python packaging/source-pin regressions: fifteen tests, zero failures, using
  synthetic PE headers, archives, and local Git repositories.
- Python parsing, shell syntax, and whitespace checks passed.
- The complete bilingual visionOS app builds unsigned using the previously
  compiled native/guest libraries. This pass did not rebuild or execute Wine/FEX.
- The original `core/tools/make-app.sh` release build also passes; its local
  ad-hoc-signed Mac app was packaged without a Klepton toolchain archive.

Source preparation now rejects local changes and mismatched/uninitialized
recursive submodules. Prefix limits are enforced while iterating headers;
sanitizer hashes stream and receipt publication does not overwrite another
writer's file. Older prepared source receipts intentionally fail reuse when the
preparation inputs change; rebuild them rather than rewriting their hashes.

The dated build record below describes the earlier local assembly.

## Current build checkpoint (2026-10-11)

The complete unsigned Windows VR app built successfully with Xcode 27 for
arm64 visionOS 27, including its validated Runtime and WindowsVR resource folders.
The saved artifact is `dist/windows-vr-2026-10-11/AVP Play VR.app`, with build logs,
file hashes, and native/guest/graphics/staging receipts beside it. See
[the local build handoff](windows-vr-local-build.md).

The build includes source-built Wine native archives, FEX core and ARM64EC
translator, the translator's LLVM-MinGW runtime DLLs, the real Wine-generated
portable prefix, x64 OpenXR/OpenComposite clients, and modern DXMT D3D11/D3D12
native/guest libraries. The graphics receipt covers the four executable graphics
DLLs; Wine's data-only API-set schema is preserved separately. Common runtime and
fresh graphics profiles use identical common-overlay provenance and native binder
sources; the final graphics binaries are recorded in the common resource ledger.

Signing is blocked by the selected Personal Team's missing certificate private
key. No signed/installable product is established. No tests, benchmarks, game
launches, installations, or device runs were performed. Compilation and package
validation do not establish JIT/device compatibility, game support, or near-native
performance.

The existing Quest and Linux ARM64 installation paths are kept separate.
Windows changes do not imply new compatibility labels for those games.

## Experimental D3D12 continuation

The D3D12 guest OpenXR path, DXMT queue/WMT source overlay, manifest/transfer/UI
support and fail-closed package capability plumbing are implemented in source.
See [windows-vr-d3d12.md](windows-vr-d3d12.md) for the exact contract and checkpoint.
The newer upstream DXMT source is pinned separately; the D3D11 baseline is not
silently upgraded. The mobile storage/framework/shader port, embedded Wine
binding, modern D3D11 bridge, native/guest build recipes and assembly integration
are implemented in source. The old permanent build blocker is removed. The guest OpenXR/OpenComposite DLLs have compiled with D3D12 enabled. The modern native/guest DXMT closure has compiled and passed receipt-backed staging; headset behavior remains unverified. The pinned upstream D3D12 route supports Shader Model 5.1/DXBC,
not DXIL/Shader Model 6, ray tracing or mesh shaders. Tests and runtime validation remain deferred.

## Runtime completion pass

The first x64/D3D11 color-stereo path now also includes cooperative exit,
pre-JIT resource/PE checks, isolated per-game prefixes, a versioned array/region
submission path, static swapchains, tracking-loss/focus handling, and source/native/
guest coherence receipts. The V1 COM and WMT layouts remain frozen; the optional
Ext3 interface and V2 transport carry explicit slices and subrectangles. One Luna
worker completed provisioning; another was rate-limited with incomplete transport
edits, which were finished and source-reviewed by the parent. No execution result
is implied by that source review.

The provisioning scripts can rebuild the critical ARM64EC Wine/FEX/DXMT modules
from the prepared pinned overlay. The clean prefix is generated with the upstream `wineboot --init` script.
`create_prefix_snapshot.sh` invokes the real Wine build and removes host-specific
links and archive metadata through `sanitize_prefix_snapshot.py`. The documented assembler targets a Mac with Xcode/xros. Its component build commands, resource staging, and unsigned app link have completed. Signing and device/runtime verification remain outstanding.

## Implemented in source

| Area | Implementation |
|---|---|
| Headset library | Local versioned storage, imported manifests, folder bookmarks, selection/removal, stale-bookmark refresh, corruption refusal |
| Launch profiles | Named per-game profiles, exact JSON argv editing, default-compatible profile decoding, persistent spatial render scale |
| Mac transfer | `avpplay windows stage`, explicit ownership attestation, x64 PE/schema/path checks, bounded local hashing and sequential direct copies, resume journal, immutable content generations, manifest copied last |
| Transfer discovery | Headset launcher lists completed app-container transfers and can save them to its local library |
| Diagnostics | Separate Wine process status and native queue counters, versioned JSON export, actual OS/build/hardware identifier where available, explicit unmeasured metrics, environment values omitted |
| Native adapter | Preflight before JIT/session consumption, x64/package rejection, isolated game-ID-hashed prefixes, private guest mappings, startup cancellation/cooperative exit, environment restoration, live-guest lifetime protection |
| OpenXR | D3D11 stereo/frame/session/space/action/haptic surface, core string/name calls, graphics-requirements enforcement, FIFO/static image ownership, retained last release, optional array/packed-region submission, focused action states, cooperative STOPPING/EXITING |
| Compositor lifecycle | Target/tracking/controller/haptic invalidation, retained in-flight leases, ordered consumer tickets, bounded outstanding tickets, atomic target-generation submission checks, owned last-frame snapshots between guest updates |
| Spatial scaling | Uniform reduced per-eye producer dimensions and ordinary Metal bilinear presentation; 100% keeps exact-size copies. Explicit BGRA8 sRGB is mapped through guest DXGI and DXMT transport |
| Pause/resume | Native stale state is cleared; guest paused frames request no rendering. Same-format/same-size target generations are refreshed; incompatible geometry reports session loss |
| Assembly | Explicit opt-in assembler, separate native/Windows resource inputs, clean-prefix archive validation, builtin/guest/license checks, transactional resource staging, XcodeGen/development-signing configuration |

Primary implementation paths:

- `visionos-windows-vr/Sources/LauncherModel.swift` and `ContentView.swift`
- `visionos-windows-vr/Sources/Rendering/`
- `windows-vr/Sources/WindowsVRCore/WindowsVRLibrary.swift`
- `windows-vr/Sources/WindowsVRCore/WindowsVRCompatibilityReport.swift`
- `core/Sources/AVPPlayCore/WindowsGameTransfer.swift`
- `windows-runtime-plugin/WindowsVRRuntimePlugin.mm`
- `windows-vr-native/Sources/WindowsVRCompositorBridge.mm`
- `windows-vr-openxr/src/WindowsVROpenXR.cpp` and its DXMT overlay
- `windows-vr-tools/stage_resources.py` and `assemble_runtime.sh`

## Entry points

For user-owned local Windows files, see [the Mac transfer guide](windows-vr-transfer.md).
The receiving bundle ID in the research app project is
`org.avpplay.visionos-windows-vr`, not the Mac companion's bundle identifier.
No store acquisition or DRM bypass was added. The CLI is implemented; a Windows
workflow in the Mac SwiftUI game catalog is not delivered.

For assembly instructions, see [the toolchain guide](../windows-vr-tools/README.md).
It requires an Apple-silicon Mac with full Xcode/xros SDK, external toolchains,
a clean prefix archive, Windows Wine/DXMT builtin resources compiled from the
matching prepared overlay, license inputs, signing/provisioning, and space.
The assembler does not manufacture the prefix. Its opt-in PE mode rebuilds critical Wine/FEX/DXMT guest modules and records matching resource hashes; pinned base PE/NLS/legal resources are still required.
Its opt-in flag is not authorization to run it under a no-testing instruction.

## Explicit limits and unfinished work

- No Windows VR title has been selected and established as compatible by this
  continuation. First-game acceptance, controller correctness, JIT/device
  compatibility, sustained play, saves, latency, and performance remain unknown.
- The unsigned app and matching resource package are built. Signing and headset
  runtime verification remain outstanding; a successful build is not runtime readiness.
- Madeira still owns one native runtime session per app process. Stop now requests
  cooperative OpenXR exit and can cancel startup at safe boundaries; it does not
  forcibly kill a Wine thread. A guest that ignores the request still requires app
  restart. Access and ownership remain retained until actual Wine exit.
  Launch acceptance and active Wine are not evidence of game readiness.
- Baseline packaging is x64/D3D11; transfer also accepts explicit D3D12 manifests without claiming execution support. Experimental D3D12 packaging has an explicit modern-profile build/staging route; its binaries have compiled and passed final receipt-backed staging. ARM64EC games need a separately matched
  package; Vulkan, arbitrary SteamVR drivers, and broad game support are
  not delivered by this path. Existing Klepton ARM64 support remains independent.
- The guest OpenXR implementation is limited, not conformant. Color array slices
  and packed subrectangles are implemented through Ext3/V2; composition depth,
  stage bounds, MSAA, optional extensions, and advanced controller-profile behavior
  remain unsupported. Finite image-wait timeouts
  are not enforceable through the current transport.
- The compositor holds owned copies of the last valid eye colors between guest
  updates; it clears output before the first valid frame or after target
  invalidation. Re-presenting a snapshot does not count as a newly rendered frame.
  Depth-correct/pose-aware reprojection and deadline/rate-mismatch behavior still
  need further implementation and device evaluation.
- Spatial scaling has no established image-quality or GPU-benefit result.
  Temporal MetalFX SR remains unavailable on the initial visionOS SDK target.
  A separate supported temporal backend and proven eye/resource routing are needed
  before temporal NGX/SR can be exposed; bilinear scaling is not DLSS.
- Guest-render-pass foveation and stereo frame generation remain research work,
  not features completed by launcher toggles or a final compositor blit.
- Transfer journals record successful copy operations and local hashes, not
  remote hash verification. Remote presence/size helps detect erased files but
  cannot establish their byte integrity. Keep the app closed while transferring.
  Old generations consume device storage until explicitly removed.
- Source/binary license obligations still apply to the upstream runtime stack.
  No game assets, credentials, NVIDIA models, or proprietary NGX binaries are
  distributed by this implementation.

These are remaining engineering and delivery gates, not a request to run tests.

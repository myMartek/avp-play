# Project-owned OpenXR guest runtime

`src/WindowsVROpenXR.cpp` is a Windows PE OpenXR runtime entry point. It
negotiates with the Khronos loader and routes the app's stereo D3D11 swapchain
resources through the project DXMT extension to the native CompositorServices
bridge. DXMT resolves guest resources to Metal textures on the Unix host; guest
resource pointers do not cross the WMT transport boundary.

## Source and package

The runtime consumes the pinned Khronos headers in `third-party/openxr` and the
project-local ABIs in `include/WindowsVRD3D11ContextExt.h` and
`include/WindowsVRD3D12CommandQueueExt.h`. Configure the CMake project on Windows
with MSVC or cross-compile x64 on macOS with the optional LLVM-MinGW toolchain
file described below. Both routes provide Windows D3D11/D3D12/DXGI headers and
import libraries. The default stage is
`stage/WindowsVR/Guest/x64/wvr_openxr.dll` for each MSVC configuration; pass
`-DWINDOWS_VR_GUEST_STAGE=<shared-guest-stage>` to stage beside
`OpenComposite/bin/vrclient_x64.dll`. The loader manifest is
`runtime/WindowsVRRuntime.json`; the package assembler must copy it to the
architecture-specific runtime directory and resolve `library_path` to the
staged DLL according to the Wine guest path. The app runtime plugin regenerates
the final manifest for its mapped guest directory.

This guest DLL links Windows SDK `d3d11`, `d3d12`, and `dxgi`. `WMTWindowsVRBridgeCallV1`
is host-only and is intentionally not imported by the PE runtime. Target startup
queries the existing D3D11 context extension and independently probes the D3D12
DIRECT-queue extension. It advertises `XR_KHR_D3D12_enable` only after that
backend returns valid targets; when D3D11 discovery is unavailable, initialized
D3D12 queue discovery supplies targets instead. Runtime and session targets come from
those extension calls, never from guessed dimensions or cross-API pointer casts.

## Implemented surface and limits

The source provides the core runtime calls needed for the D3D11 and D3D12 stereo paths: instance/system and stereo-view enumeration, OPAQUE blend mode, VIEW/LOCAL spaces, frame wait/begin/end, session state events, path/action creation and sync, left/right controller sampling, haptic forwarding, single-layer stereo projection submission, and swapchain image management. The dispatch table also exposes `xrResultToString`, `xrStructureTypeToString`, and `xrGetInputSourceLocalizedName`. String-to-enum helpers return recognized core names and a stable unknown-name fallback; localized input names are English path-derived labels, not OS-localized device/profile strings.

Swapchain acquisition, waits, and releases are tracked in FIFO order. Submission
selects the latest released image, including a static image or a previously
released image reused by later frames; acquired images cannot be submitted.
Static-image swapchains have one image and one acquisition. D3D11 array slices
(up to 16) and packed subrectangles use the separately queried Ext3 interface
`d9e15e9c-7c99-4b09-8dd8-628d3cf004a7`, WMT V2 call slot 152, and native V2
leases. D3D12 committed swapchain images use the explicitly queried application
DIRECT queue interface `08e6b53f-ede5-4524-90b8-3445ef059b1e`; its frame payload
carries stereo array slices and subrectangles without changing the
D3D11 Ext2/Ext3 vtables or WMT V1 layout. D3D12 images are DEFAULT-heap resources
created in COMMON with ALLOW_RENDER_TARGET. The runtime validates that the
binding queue is DIRECT, belongs to the exact supplied device, and meets the
queried adapter LUID and feature level. The D3D12 queue worker receives a
consumer wait before a released image is reused. Both graphics requirements
functions must be queried before creating the corresponding session; one active
guest XR session is supported. Frame sequencing requires one successful
`xrWaitFrame` before `xrBeginFrame`, then consumes that wait at `xrEndFrame`.
Exit requests transition through STOPPING; `xrEndSession` then reports EXITING
rather than restarting the session. Non-exit stops return to READY after IDLE.
A sticky native exit flag is observed independently of pose validity by
`xrPollEvent`/`xrWaitFrame`; the host can request STOPPING/EXITING even after
compositor closure. This does not terminate a guest process that ignores XR
exit. Tracking/target visibility changes de-focus action sampling and tracking
loss returns non-rendering frames rather than inventing poses. Paused native
targets yield a paced non-rendering frame; after same-sized resume, guest target
generations are refreshed without guessing a new format. A geometry/format
change reports session loss rather than using incompatible textures. The
headset uses explicit BGRA8 sRGB color, which the guest maps to its matching
DXGI sRGB format.

Action types are validated as the five supported enum values rather than as an integer interval. Suggested bindings must match the action's declared hand subactions and supported input/output path kind. Input action snapshots are restricted to bound, active, connected subactions; absent/inactive sources report inactive zero/default state, while a null subaction query aggregates eligible left/right sources. Unsupported controller components are not synthesized. Haptics target all eligible bound roles for a null subaction path.

This is an early, deliberately limited OpenXR implementation, not full conformance. Depth-composition layers, multisampled swapchains, stage bounds, hand tracking, hand joints, velocity prediction, visibility masks, controller profiles beyond the current component mapping, and many optional extensions are unsupported. The DXMT image-wait ABI has no timeout parameter, so a finite OpenXR swapchain wait timeout cannot currently be enforced by the transport. Unknown instance extensions and unsupported function names fail explicitly. There is no completed Wine/FEX execution stack or packaged Windows VR game environment here. This source was not built or runtime-validated as part of this change; loader/runtime initialization does not establish that a game launched, rendered, or is running.

Preserve the Khronos OpenXR-SDK license and the project's DXMT patch/source licenses in redistributed packages.

## macOS x64 cross-build

The project includes `cmake/toolchains/llvm-mingw-x64.cmake`, which consumes an
already-extracted LLVM-MinGW macOS bundle. It is not Homebrew's host LLVM
installation: on the audited host, Homebrew LLVM 21 is at
`/opt/homebrew/opt/llvm@21`, and its binaries are not on `PATH`. The Windows
cross compiler and MinGW sysroot are still separate dependencies.

For reproducible setup, the repository's Madeira build record pins the
official [LLVM-MinGW 20260421 macOS universal release](https://github.com/mstorsjo/llvm-mingw/releases/tag/20260421)
with SHA-256 `bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7`.
After extracting that release to a local toolchain directory and verifying its
hash, configure and build the DLL with:

```sh
cmake -S windows-vr-openxr -B build/openxr-mingw -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/windows-vr-openxr/cmake/toolchains/llvm-mingw-x64.cmake" \
  -DLLVM_MINGW_ROOT="$PWD/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
cmake --build build/openxr-mingw --config Release
```

The following build record concerns earlier D3D11-only sources; the current
D3D12 extension and queue transport were not built or exercised. D3D12 device
creation is dynamically resolved so missing D3D12 DLLs do not prevent the XR
DLL from loading for the baseline D3D11 path.

The earlier x64 guest DLL was cross-built on macOS on 2026-10-10 with this route. The
artifact staged at
`/private/tmp/avp-play-builds/openxr/stage/WindowsVR/Guest/x64/wvr_openxr.dll`
was identified as a PE32+ x86-64 DLL. Compilation completed with nonfatal
warnings; no runtime or device validation was performed. The toolchain bundle
is not checked in and the CMake file does not download or install it.

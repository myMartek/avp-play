# Project-owned OpenXR guest runtime

`src/WindowsVROpenXR.cpp` is a Windows PE OpenXR runtime entry point. It
negotiates with the Khronos loader and routes the app's stereo D3D11 swapchain
resources through the project DXMT extension to the native CompositorServices
bridge. DXMT resolves guest resources to Metal textures on the Unix host; guest
resource pointers do not cross the WMT transport boundary.

## Source and package

The runtime consumes the pinned Khronos headers in `third-party/openxr` and the
project-local ABI in `include/WindowsVRD3D11ContextExt.h`. Configure the CMake
project on Windows with MSVC or cross-compile x64 on macOS with the optional
LLVM-MinGW toolchain file described below. Both routes provide Windows D3D11/
DXGI headers and import libraries. The default stage is
`stage/WindowsVR/Guest/x64/wvr_openxr.dll` for each MSVC configuration; pass
`-DWINDOWS_VR_GUEST_STAGE=<shared-guest-stage>` to stage beside
`OpenComposite/bin/vrclient_x64.dll`. The loader manifest is
`runtime/WindowsVRRuntime.json`; the package assembler must copy it to the
architecture-specific runtime directory and resolve `library_path` to the
staged DLL according to the Wine guest path. The app runtime plugin regenerates
the final manifest for its mapped guest directory.

This guest DLL links only Windows SDK `d3d11` and `dxgi`. `WMTWindowsVRBridgeCallV1`
is host-only and is intentionally not imported by the PE runtime. Initial
target discovery creates a temporary default D3D11 device and queries
`IMTLD3D11ContextExt2`; session work uses the application's DXMT device/context.
If that extension is unavailable, runtime initialization fails instead of
falling back to guessed targets.

## Implemented surface and limits

The current source provides stereo primary view configuration, OPAQUE blend
mode, VIEW/LOCAL spaces, `xrLocateViews`/`xrLocateSpace`, session state events,
basic left/right controller action sampling and haptic forwarding, and
single-layer stereo projection submission. It waits for a strictly newer host
predicted tracking timestamp with a bounded timeout and uses that timestamp as
the OpenXR frame time. It validates compositor target generation and requires
full-size per-eye subimages matching the published target before submitting.

This is an early compatibility surface, not a complete Khronos runtime.
Depth-composition layers, array/multiview swapchains, stage bounds, hand
tracking, hand joints, controller profiles beyond the current path-to-button
mapping, velocity prediction, visibility masks, and many optional extensions
are unsupported. Unknown instance extensions and unsupported function names
fail explicitly. There is no completed Wine/FEX execution stack or packaged
Windows VR game environment here, and this source has not been built or
runtime-validated. A successful loader/runtime initialization does not mean a
game launched, rendered, or is running.

Preserve the Khronos OpenXR-SDK license and the project's DXMT patch/source
licenses in redistributed packages.

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

The x64 guest DLL was cross-built on macOS on 2026-10-10 with this route. The
artifact staged at
`/private/tmp/avp-play-builds/openxr/stage/WindowsVR/Guest/x64/wvr_openxr.dll`
was identified as a PE32+ x86-64 DLL. Compilation completed with nonfatal
warnings; no runtime or device validation was performed. The toolchain bundle
is not checked in and the CMake file does not download or install it.

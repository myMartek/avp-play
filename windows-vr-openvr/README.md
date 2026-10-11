# OpenComposite guest package

This directory packages the upstream OpenComposite OpenXR branch as an
OpenVR-to-OpenXR compatibility layer. It does not implement or copy OpenVR
interface vtables. Source is pinned in `opencomposite.lock.json` to
[`znixian/OpenOVR`](https://gitlab.com/znixian/OpenOVR), commit
`cff07db75c4823afe93ed7027b03d5f7bc86f164` on the `openxr` branch. OpenComposite
is GPL-3.0-or-later; its generated OpenVR headers retain their upstream MIT
license. Preserve upstream notices and include the GPL license when
redistributing the resulting package.

## Package shape

The CMake packaging target stages the upstream output at:

```text
stage/WindowsVR/Guest/x64/OpenComposite/bin/vrclient_x64.dll
```

An optional ARM64EC build uses a separate root:

```text
stage/WindowsVR/Guest/arm64ec/OpenComposite/bin/vrclient_x64.dll
```

The two files have the same upstream filename and must never share a directory.
The Wine launcher must inspect the guest executable's PE machine type and select
the matching package. It must fail closed when that architecture's package is
absent; do not load the x64 DLL into an ARM64EC guest or silently fall back.
ARM64EC packaging is opt-in with `WINDOWS_VR_BUILD_ARM64EC=ON` and depends on a
Visual Studio/CMake toolchain that supports the ARM64EC generator platform.

The project-owned `wvr_openxr.dll` and its runtime JSON are supplied by the
separate WindowsVR OpenXR runtime package, not by this upstream build. At guest
launch, the runtime integration maps the selected package root to
`C:\\windows-vr-runtime\\x64` (or the architecture-specific equivalent),
provides its runtime manifest through `XR_RUNTIME_JSON`, and sets
`VR_OVERRIDE=C:\\windows-vr-runtime\\x64\\OpenComposite`. These are internal
per-process Wine environment values. Do not write host-wide OpenXR registry
settings. Do not put reserved runtime-selection variables in user-editable game
manifest environment values.

`VR_OVERRIDE` points at the `OpenComposite` root whose `bin` directory contains
`vrclient_x64.dll`; `XR_RUNTIME_JSON` points at the exact project-owned OpenXR
runtime manifest. The runtime package must verify both the architecture-specific
OpenComposite DLL and runtime manifest before launch.

## Building on Windows or macOS

The default build uses a Windows host with Visual Studio C++ tools, CMake 3.25
or newer, Git, and the upstream OpenComposite submodule dependencies. Configure
this directory with the Visual Studio generator and build the
`package_opencomposite` target. Enable `WINDOWS_VR_BUILD_ARM64EC=ON` only when
the selected Visual Studio toolchain supports ARM64EC.

An opt-in x64 cross-build from macOS uses the same LLVM-MinGW release and
toolchain file described in the OpenXR runtime README. The pinned
`third-party/opencomposite` checkout must be initialized at the commit recorded
in `OPENCOMPOSITE_COMMIT`; the cross path verifies that commit and does not
fetch source. Example:

```sh
cmake -S windows-vr-openvr -B build/opencomposite-mingw -G Ninja \
  -DWINDOWS_VR_USE_LLVM_MINGW=ON \
  -DLLVM_MINGW_ROOT="$PWD/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
cmake --build build/opencomposite-mingw --target package_opencomposite --config Release
```

The upstream `RuntimeSwitcher.csproj` is included only by CMake's
`include_external_msproject`, which CMake documents as ignored for non-Visual
Studio generators. The cross-build therefore packages the OpenComposite DLL
without its optional Windows GUI switcher. Cross-building is implemented but
not yet built or validated here; ARM64EC remains on the Visual Studio route.

For a one-off game that does not honor `VR_OVERRIDE`, an experienced user may
choose to deploy a matching OpenComposite `openvr_api.dll` beside their own game
executable following upstream guidance. This project does not modify game
directories, download game files, bypass Steam purchase checks, or provide
proprietary content.

## Runtime status

This package is a compatibility bridge, not a Windows execution environment.
It does not include Wine/FEX binaries, a Windows OpenXR runtime, or proprietary
games. Actual Windows VR game execution depends on the separate Wine/FEX process
launcher, the project-owned OpenXR runtime, the visionOS compositor bridge, and
the required native dependencies. Until those pieces are present and report
their state, a packaged DLL must not be presented as proof that a game launched,
rendered, or is running.

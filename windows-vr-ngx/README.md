# WindowsVR NGX temporal SR source overlay

This directory is an opt-in source overlay for the pinned DXMT tree at
`third-party/madeira/dxmt` (`db546ee466ad50ec6463edb5fa183de11db43761`). It
adapts DXMT's existing `nvngx` Super Sampling entry points and its existing
D3D11 resource unwrapping path. It is not a stand-alone `nvngx.dll`, does not
provide a second implementation of NVIDIA's proprietary NGX ABI, and does not
bundle NVIDIA headers or model data.

The checked-in DXMT `nvngx.hpp` declares a project-local, compatibility ABI.
Its `NVNGXParameter` vtable and several export signatures are not the official
NVIDIA SDK ABI. This overlay intentionally stays on that exact pinned DXMT
surface. Games that require another NGX SDK ABI revision remain unsupported
until a compatible, licensed header/runtime contract is added. DLSS model
weights are NVIDIA proprietary assets; the MetalFX adapter does not reproduce
or include them. This path invokes Apple's MetalFX temporal scaler, which is
API compatibility and not execution of NVIDIA's learned model.

The installed visionOS 27 SDK explicitly marks `MTLFXTemporalScaler`
unavailable on visionOS. The Swift C ABI therefore returns
`WVRMetalFXStatusUnsupported` at creation on that platform, and the DXMT host
overlay reports temporal-scaler support as false before NGX feature creation.
This MetalFX-backed NGX SR route cannot run on the M2 Vision Pro/visionOS 27
target; a different supported temporal SR backend would be required. This is
separate from the still-missing per-game eye-route proof described below.

## Intended flow

1. A native VR host explicitly opts in and registers the eye-routing callback
   with DXMT. The callback must map the current D3D11 context and exact NGX
   output resource to left or right eye using an authoritative game/runtime
   association. If no callback is registered, or it cannot resolve an eye,
   feature creation/evaluation fails with unsupported status.
2. DXMT's existing NGX adapter reads Color, Depth, MotionVectors, Output,
   ExposureTexture, jitter, reset, flags, and motion scales from its supported
   parameter subset. `D3D11ResourceCommon::texture()` continues to unwrap the
   actual DXMT COM resources; no guest pointer is cast to a host Metal object.
3. DXMT's WMT Unix dispatch receives host-native Metal texture, command-buffer,
   and device objects. A wrapper there calls the `WindowsVRMetal` C ABI. The
   feature token and routed eye are included in the scaler cache identity so
   histories cannot be shared between NGX handles or eyes.
4. The Swift endpoint creates independent MetalFX histories per eye. This
   source overlay includes no Frame Generation implementation and makes no
   claim that an SR adapter can provide FG.

The callback API is only a contract in this overlay; this repository does not
yet provide or register a working callback from its OpenXR runtime. That
runtime learns which exact resources are the left and right projection inputs
at `xrEndFrame`, potentially after NGX has evaluated, and those projection
resources may be intermediates relative to the NGX output. Therefore the
existing OpenXR path cannot prove a generic NGX output-to-eye mapping and the
adapter remains fail-closed until a game profile or future guest/runtime hook
supplies an explicit association before evaluation. A profile must identify
the output resource for each eye (and keep its association valid for the
evaluation); matching dimensions, pixel formats, array slices, or the most
recent compositor submission is not sufficient. If a game uses one shared
output resource or provides no unambiguous eye-specific resources, this
per-eye temporal adapter cannot be enabled for that game.

Foveated or variable-rate inputs also remain unsupported unless the caller
resolves them into coherent uniform-raster color/depth/motion resources first.

## Overlay contents and application

`patches/0001-dxmt-ngxsreye.patch` carries the DXMT-side changes for the pinned
source. The application script applies the patch directly, then copies bridge
sources into the DXMT tree; it does not preflight patch applicability, build,
or install anything. The script has not been run. Hosts include
`include/WindowsVRNGX.h` and register the explicit opt-in and eye route before
creating NGX features. The bridge implementation in
`src/WVRMetalFXWMTBridge.inc` calls the existing `WindowsVRMetal` C ABI with
genuine native Metal objects.

The patches are source adaptation recipes, not a verified runtime artifact.
One patch-applicability dry-run was performed before the latest edits. The
first patch has since been applied to a temporary integration copy; the full
patch sequence has not been built or verified. The native Objective-C++
compositor bridge compiled for arm64 visionOS 27. Direct Swift compilation
produced a visionOS C ABI that returns unsupported and a macOS 14 temporal
endpoint; the MetalFX temporal implementation cannot be used on visionOS
because its SDK marks the API unavailable. No tests, benchmarks, runtime
probes, app launches, or installs were performed. The project configuration
links the static DXMT archive into
`WindowsRuntimePlugin` and declares the dynamic `WindowsVRMetal` product there;
actual symbol resolution remains unverified because no build was performed.
The patch changes private DXMT D3D11 interface and WMT structure layouts, so
the guest DXMT code, host WMT implementation, and runtime/plugin image must be
rebuilt together. Mixing these modified private interfaces with prebuilt DXMT
components is unsupported.

## Remaining compatibility and ownership work

- When validation is authorized, apply both patches and verify the native
  bridge against the pinned DXMT/Madeira build and supported macOS SDKs.
- Define and implement a game-by-game parameter/resource contract, including
  a pre-evaluation eye route for the exact NGX output resource, subrects,
  exposure, motion-vector sign/scale, reset events, and whether resources are
  separate per eye. Missing or ambiguous fields must fail closed. The current
  OpenXR `xrEndFrame` association is too late to serve as this route by itself.
- Add lifecycle handling for NGX feature release and DXMT WMT object release;
  the bridge keeps its Swift adapter alive for the WMT handle lifetime.
- DXMT's WMT command-buffer encode call is currently void at its guest-facing
  boundary. A native bridge rejection can be detected in the Unix host handler,
  but the existing call chain does not report it back as an NGX evaluation
  result. Production integration must make this error visible or ensure all
  unsupported configurations are rejected during feature creation/evaluation.
- Confirm how output composition and per-eye command ordering are synchronized
  with the actual VR host. The caller owns command submission and resource
  lifetime.
- Obtain any NVIDIA SDK headers only through their official licensed
  distribution if a future adapter needs a different official ABI. Do not
  copy those headers into this repository without rights to redistribute them.

## References

- [DXMT NGX source at the pinned revision](https://github.com/3Shain/DXMT/tree/db546ee466ad50ec6463edb5fa183de11db43761/src/nvngx)
- [DXMT vendor extensions](https://github.com/3Shain/DXMT/wiki/Vendor-Extensions)
- [CodeWeavers CrossOver 26 advanced settings](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26)
- [Apple MetalFX temporal scaler](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscaler)

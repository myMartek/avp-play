# WindowsVRMetal

`WindowsVRMetal` is a Swift package containing an opt-in MetalFX temporal
super-resolution endpoint for Windows graphics translation work on SDKs that
expose that API. Its package platforms are visionOS 1, macOS 14, and iOS 17.
Apple's visionOS 27 SDK explicitly marks `MTLFXTemporalScaler` unavailable on
visionOS. The visionOS C ABI therefore remains present but returns
`WVRMetalFXStatusUnsupported`; no spatial-scaling substitute or fake temporal
SR is provided. The native temporal implementation is compiled only for
non-visionOS targets where the SDK exposes the required MetalFX API.

`StereoTemporalSuperResolution` creates two separate `MTLFXTemporalScaler`
instances so left and right eyes keep independent histories. The first encoded
frame for each eye automatically resets that eye's history; callers can request
another reset after scene cuts or other history-invalidating events. Calls on the
adapter are serialized, but the caller must also preserve execution order across
command buffers (for example, by using one ordered command queue or explicit
synchronization). The caller must construct it with `enabled: true`, supply configured pixel formats and fixed
input/output dimensions, provide current per-eye color, depth, and input-resolution
motion textures, and encode work into its own command buffer. By default, automatic
exposure is disabled and each frame must provide a 1x1 `R16Float` exposure texture.
Set `autoExposureEnabled` in the fixed configuration to use MetalFX automatic
exposure; in that mode the adapter rejects a supplied exposure texture. Apple's
public documentation specifies `R16Float`, not `R32Float`, for an explicit exposure
texture. The adapter checks texture type, sample count, dimensions, formats,
device identity, scaler-required usage flags, nonaliasing backing resources, and
finite jitter/motion scale values before encoding. MetalFX has no frame-time
input, so the endpoint does not invent or validate a synthetic timing value.
The caller remains
responsible for resource lifetime, queue synchronization, and presenting the result.

`WindowsVRMetalC.h` defines a small C ABI for a native host-side caller. The
`WVRMetalFXSRCreateV1` entry point requires both explicit feature opt-in and an
explicit confirmation that the caller can route resources by eye. It returns
unsupported when either is absent. Metal object pointers passed through this ABI
are unretained Objective-C references; the caller must keep them alive through
encoding and must provide genuine Metal objects from the same process/device.
The ABI does not turn Windows COM resource pointers into Metal textures.

The source-level DXMT NGX Super Resolution adapter in `../windows-vr-ngx`
translates a limited DXMT-local NGX parameter subset. Its eye-routing callback
is not registered by the OpenXR runtime because that runtime cannot prove which
eye an arbitrary NGX output resource represents. On macOS/iOS targets where the
SDK exposes MetalFX temporal scaling, the adapter remains fail-closed until a
game profile or guest/runtime hook provides that exact association before
evaluation. On visionOS, the native endpoint rejects creation regardless of
eye routing because MetalFX temporal scaling is unavailable there. This does
not provide a stand-alone Windows DLL, general ABI compatibility, game
resource discovery, compatibility reporting, or NVIDIA's proprietary model.
No Frame Generation path is included. Each supported game's motion vectors,
depth, jitter, exposure, history reset, and resource ownership still need an
explicit mapping; unsupported or incomplete mappings disable the feature and
use the game's regular render path.

Motion vectors must be valid for the current eye at input resolution and follow
MetalFX's documented sign and scale conventions. The descriptor is configured
for input-resolution motion vectors. Foveated or variable-rate textures are not
accepted as a meaningful temporal input unless the caller has already resolved
them into a uniform raster with coherent depth and motion data.

Outstanding work includes validating the MetalFX endpoint against supported
macOS/iOS SDKs; confirming texture usage requirements and accepted format
combinations; wiring a real translation-layer caller; and mapping game-specific
NGX resources and history events. The M2 Vision Pro running visionOS 27 cannot
use this MetalFX temporal endpoint; a separate compatible temporal SR backend
would be required before evaluating that path. M5 work remains a later,
separate target. The Swift sources were compiled directly for arm64 macOS 14
and visionOS 27, but the SwiftPM product and application link were not built,
and no runtime execution occurred.

## Public API references

- [MTLFXTemporalScalerDescriptor](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor): device support query, descriptor configuration, and scaler creation.
- [MTLFXTemporalScaler](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscaler): texture inputs and command-buffer encoding.
- [MTLFXTemporalScalerBase](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase): jitter, depth convention, motion-vector scale, history reset, and exposure input.
- [Exposure texture](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase/exposuretexture): `R16Float`, 1x1 exposure texture convention.

#ifndef WINDOWS_VR_METAL_C_H
#define WINDOWS_VR_METAL_C_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* Opaque pointers are unretained Objective-C Metal objects owned by the caller. */
typedef void *WVRMetalFXHandle;

enum WVRMetalFXStatus {
    WVRMetalFXStatusSuccess = 0,
    WVRMetalFXStatusInvalidArgument = 1,
    WVRMetalFXStatusUnsupported = 2,
    WVRMetalFXStatusCreationFailed = 3,
    WVRMetalFXStatusFrameRejected = 4
};

enum WVRMetalFXEye {
    WVRMetalFXEyeLeft = 0,
    WVRMetalFXEyeRight = 1
};

/* Pixel format integers are MTLPixelFormat raw values from the same SDK. */
int32_t WVRMetalFXSRCreateV1(
    void *metal_device,
    uint32_t input_width,
    uint32_t input_height,
    uint32_t output_width,
    uint32_t output_height,
    uint32_t color_format,
    uint32_t depth_format,
    uint32_t motion_format,
    uint32_t output_format,
    uint8_t auto_exposure_enabled,
    uint8_t opt_in_enabled,
    uint8_t explicit_eye_routing_available,
    WVRMetalFXHandle *out_handle
);

int32_t WVRMetalFXSREncodeV1(
    WVRMetalFXHandle handle,
    uint32_t eye,
    void *color_texture,
    void *depth_texture,
    void *motion_texture,
    void *output_texture,
    void *exposure_texture,
    void *command_buffer,
    float jitter_x,
    float jitter_y,
    float motion_scale_x,
    float motion_scale_y,
    uint8_t depth_is_reversed,
    uint8_t reset_history
);

void WVRMetalFXSRDestroyV1(WVRMetalFXHandle handle);

#if defined(__cplusplus)
}
#endif

#endif

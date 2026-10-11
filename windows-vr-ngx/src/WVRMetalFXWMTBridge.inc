#import "WVRMetalFXWMTBridge.h"

extern MTLPixelFormat to_metal_pixel_format(enum WMTPixelFormat format);

/* This class adapts WMT's host-side object lifetime to the Swift C endpoint.
 * The WMT host owns the wrapper; the wrapper owns the retained Swift handle.
 * It deliberately does not implement or expose a Windows DLL ABI. */
@implementation WVRMetalFXScalerBox

- (instancetype)initWithDevice:(id<MTLDevice>)device
                           info:(const struct WMTFXTemporalScalerInfo *)info {
    self = [super init];
    if (!self) return nil;

    int32_t status = WVRMetalFXSRCreateV1(
        (__bridge void *)device,
        info->input_width,
        info->input_height,
        info->output_width,
        info->output_height,
        (uint32_t)to_metal_pixel_format(info->color_format),
        (uint32_t)to_metal_pixel_format(info->depth_format),
        (uint32_t)to_metal_pixel_format(info->motion_format),
        (uint32_t)to_metal_pixel_format(info->output_format),
        info->auto_exposure ? 1 : 0,
        1, /* NGX callback already confirmed explicit host opt-in. */
        info->eye_routing_available ? 1 : 0,
        &_adapter);
    if (status != WVRMetalFXStatusSuccess || !_adapter) {
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_adapter) WVRMetalFXSRDestroyV1(_adapter);
    [super dealloc];
}

- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      color:(id<MTLTexture>)color
                     output:(id<MTLTexture>)output
                      depth:(id<MTLTexture>)depth
                     motion:(id<MTLTexture>)motion
                   exposure:(id<MTLTexture>)exposure
                      props:(const struct WMTFXTemporalScalerProps *)props {
    if (!_adapter || !props || props->eye_index > WVRMetalFXEyeRight) return NO;
    int32_t status = WVRMetalFXSREncodeV1(
        _adapter,
        props->eye_index,
        (__bridge void *)color,
        (__bridge void *)depth,
        (__bridge void *)motion,
        (__bridge void *)output,
        (__bridge void *)exposure,
        (__bridge void *)commandBuffer,
        props->jitter_offset_x,
        props->jitter_offset_y,
        props->motion_vector_scale_x,
        props->motion_vector_scale_y,
        props->depth_reversed ? 1 : 0,
        props->reset ? 1 : 0);
    return status == WVRMetalFXStatusSuccess;
}
@end

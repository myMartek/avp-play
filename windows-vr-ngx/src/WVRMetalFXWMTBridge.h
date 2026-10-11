#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <stdint.h>
#include "../winemetal.h"
#include "WindowsVRMetalC.h"

/* WMT Unix-side wrapper. These functions receive host-native Objective-C
 * objects only; never pass Windows/guest COM pointers here. */
@interface WVRMetalFXScalerBox : NSObject {
@private
    WVRMetalFXHandle _adapter;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                           info:(const struct WMTFXTemporalScalerInfo *)info;
- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      color:(id<MTLTexture>)color
                     output:(id<MTLTexture>)output
                      depth:(id<MTLTexture>)depth
                     motion:(id<MTLTexture>)motion
                   exposure:(id<MTLTexture>)exposure
                      props:(const struct WMTFXTemporalScalerProps *)props;
@end

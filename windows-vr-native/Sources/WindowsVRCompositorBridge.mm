#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>

#include "WindowsVRCompositorBridge.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <set>

namespace {
constexpr size_t kQueueCapacity = 3;
constexpr uint64_t kMaxOutstandingTickets = kQueueCapacity * 2;

struct QueuedFrame {
    uint64_t ticket = 0;
    uint64_t producerFrameID = 0;
    uint64_t producerTimestampNanoseconds = 0;
    __strong id<MTLTexture> left = nil;
    __strong id<MTLTexture> right = nil;
    __strong id<MTLSharedEvent> readyEvent = nil;
    uint64_t readyValue = 0;
    uint32_t leftSlice = 0, leftX = 0, leftY = 0, leftWidth = 0, leftHeight = 0;
    uint32_t rightSlice = 0, rightX = 0, rightY = 0, rightWidth = 0, rightHeight = 0;
};

class BridgeState {
public:
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    __strong id<MTLDevice> device = nil;
    __strong id<MTLSharedEvent> consumerEvent = nil;
    std::array<QueuedFrame, kQueueCapacity> queue;
    size_t head = 0;
    size_t count = 0;
    uint64_t nextTicket = 1;
    uint64_t lastSignaledTicket = 0;
    uint64_t outstandingLeases = 0;
    std::set<uint64_t> completedTickets;
    WVRRenderTargetInfoV1 targets = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRRenderTargetInfoV1),
        0,
        {0, 0}, {0, 0}, {0, 0}, {0, 0}
    };
    std::array<uint32_t, WVR_COMPOSITOR_VIEW_COUNT> drawableWidth{0, 0};
    std::array<uint32_t, WVR_COMPOSITOR_VIEW_COUNT> drawableHeight{0, 0};
    float renderScale = 1.0f;
    bool compositorPaused = true;
    WVRFrameTrackingV1 tracking = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRFrameTrackingV1),
        0,
        0,
        0,
        {0}, {{0}, {0}}, {{0}, {0}}, {{0}, {0}}, {0, 0}
    };
    WVRCompositorStatsV1 stats = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRCompositorStatsV1),
        0, 0, 0, 0, 0, 0
    };
    std::array<WVRControllerStateV1, 2> controllers{};
    std::array<WVRHapticRequestV1, 2> haptics{};
    std::array<bool, 2> hapticPending{false, false};
    uint64_t nextHapticSequence = 1;
    bool sessionExitRequested = false;
};

BridgeState &state() {
    static BridgeState bridge;
    return bridge;
}

void clearSlot(QueuedFrame &slot) {
    slot = QueuedFrame{};
}

void markTicketCompleteLocked(BridgeState &bridge, uint64_t ticket) {
    if (ticket <= bridge.lastSignaledTicket) return;
    bridge.completedTickets.insert(ticket);
    while (bridge.lastSignaledTicket != UINT64_MAX &&
           bridge.completedTickets.erase(bridge.lastSignaledTicket + 1) != 0) {
        ++bridge.lastSignaledTicket;
    }
    if (bridge.consumerEvent) {
        bridge.consumerEvent.signaledValue = bridge.lastSignaledTicket;
    }
    ++bridge.stats.completedFrames;
}

void dropHeadLocked(BridgeState &bridge) {
    if (bridge.count == 0) return;
    QueuedFrame &slot = bridge.queue[bridge.head];
    markTicketCompleteLocked(bridge, slot.ticket);
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count;
    ++bridge.stats.droppedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
}

uint32_t producerExtent(uint32_t drawableExtent, float scale) {
    if (drawableExtent == 0) return 0;
    return std::max<uint32_t>(1, static_cast<uint32_t>(
        std::floor(static_cast<double>(drawableExtent) * static_cast<double>(scale))));
}

void invalidateTargetsLocked(BridgeState &bridge) {
    const bool changed = bridge.drawableWidth[0] != 0 || bridge.drawableWidth[1] != 0 ||
                         bridge.targets.width[0] != 0 || bridge.targets.width[1] != 0;
    while (bridge.count > 0) dropHeadLocked(bridge);
    bridge.drawableWidth = {0, 0};
    bridge.drawableHeight = {0, 0};
    bridge.compositorPaused = true;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        bridge.targets.width[eye] = 0;
        bridge.targets.height[eye] = 0;
        bridge.targets.pixelFormat[eye] = 0;
    }
    if (changed) ++bridge.targets.generation;
}

void updateTargetsLocked(BridgeState &bridge,
                         uint32_t leftWidth, uint32_t leftHeight, uint32_t leftPixelFormat,
                         uint32_t rightWidth, uint32_t rightHeight, uint32_t rightPixelFormat) {
    const uint32_t drawableWidth[2] = {leftWidth, rightWidth};
    const uint32_t drawableHeight[2] = {leftHeight, rightHeight};
    const uint32_t pixelFormat[2] = {leftPixelFormat, rightPixelFormat};
    uint32_t producerWidth[2]{};
    uint32_t producerHeight[2]{};
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        producerWidth[eye] = producerExtent(drawableWidth[eye], bridge.renderScale);
        producerHeight[eye] = producerExtent(drawableHeight[eye], bridge.renderScale);
    }

    bool changed = false;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        changed |= bridge.drawableWidth[eye] != drawableWidth[eye] ||
                   bridge.drawableHeight[eye] != drawableHeight[eye] ||
                   bridge.targets.width[eye] != producerWidth[eye] ||
                   bridge.targets.height[eye] != producerHeight[eye] ||
                   bridge.targets.pixelFormat[eye] != pixelFormat[eye];
    }
    if (!changed) {
        bridge.compositorPaused = false;
        return;
    }

    while (bridge.count > 0) dropHeadLocked(bridge);
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        bridge.drawableWidth[eye] = drawableWidth[eye];
        bridge.drawableHeight[eye] = drawableHeight[eye];
        bridge.targets.width[eye] = producerWidth[eye];
        bridge.targets.height[eye] = producerHeight[eye];
        bridge.targets.pixelFormat[eye] = pixelFormat[eye];
    }
    bridge.compositorPaused = false;
    ++bridge.targets.generation;
}

void clearTrackingLocked(BridgeState &bridge) {
    bridge.tracking.flags = 0;
    bridge.tracking.timestampNanoseconds = 0;
    std::fill_n(bridge.tracking.originFromDevice, 16, 0.0f);
    bridge.tracking.originFromDevice[0] = 1.0f;
    bridge.tracking.originFromDevice[5] = 1.0f;
    bridge.tracking.originFromDevice[10] = 1.0f;
    bridge.tracking.originFromDevice[15] = 1.0f;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        std::fill_n(bridge.tracking.deviceFromEye[eye], 16, 0.0f);
        std::fill_n(bridge.tracking.projection[eye], 16, 0.0f);
        std::fill_n(bridge.tracking.frustumTangents[eye], 4, 0.0f);
    }
    std::fill_n(bridge.tracking.depthRange, 2, 0.0f);
    for (size_t role = 0; role < WVR_COMPOSITOR_VIEW_COUNT; ++role) {
        WVRControllerStateV1 &controller = bridge.controllers[role];
        controller = WVRControllerStateV1{};
        controller.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
        controller.structSize = sizeof(WVRControllerStateV1);
        controller.role = static_cast<uint32_t>(role);
        controller.originFromController[0] = 1.0f;
        controller.originFromController[5] = 1.0f;
        controller.originFromController[10] = 1.0f;
        controller.originFromController[15] = 1.0f;
        bridge.haptics[role] = WVRHapticRequestV1{};
        bridge.hapticPending[role] = false;
    }
}

bool validTexture(id<MTLTexture> texture, id<MTLDevice> device,
                  uint32_t width, uint32_t height, uint32_t pixelFormat) {
    return texture != nil && texture.device == device &&
           texture.textureType == MTLTextureType2D && texture.sampleCount == 1 &&
           texture.width == width && texture.height == height &&
           static_cast<uint32_t>(texture.pixelFormat) == pixelFormat;
}

int32_t submitStereoFrame(const WVRSubmitStereoFrameV1 *frame,
                          uint64_t expectedGeneration,
                          bool checkGeneration,
                          uint64_t *outCompositorTicket) {
    if (!frame || !outCompositorTicket || frame->abiVersion != WVR_COMPOSITOR_ABI_VERSION ||
        frame->structSize < sizeof(WVRSubmitStereoFrameV1) || !frame->leftTexture ||
        !frame->rightTexture || !frame->producerReadyEvent) {
        return WVRCompositorStatusInvalidArgument;
    }

    id<MTLTexture> left = (__bridge id<MTLTexture>)frame->leftTexture;
    id<MTLTexture> right = (__bridge id<MTLTexture>)frame->rightTexture;
    id<MTLSharedEvent> readyEvent = (__bridge id<MTLSharedEvent>)frame->producerReadyEvent;

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.device || !bridge.consumerEvent) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusDeviceNotBound;
    }
    if ((checkGeneration && expectedGeneration != bridge.targets.generation) ||
        bridge.targets.width[0] == 0 || bridge.targets.height[0] == 0 ||
        bridge.targets.width[1] == 0 || bridge.targets.height[1] == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (!validTexture(left, bridge.device, bridge.targets.width[0], bridge.targets.height[0],
                      bridge.targets.pixelFormat[0]) ||
        !validTexture(right, bridge.device, bridge.targets.width[1], bridge.targets.height[1],
                      bridge.targets.pixelFormat[1]) || readyEvent.device != bridge.device) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (bridge.nextTicket == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusUnsupportedABI;
    }
    if (bridge.nextTicket - bridge.lastSignaledTicket - 1 >= kMaxOutstandingTickets) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }

    if (bridge.count == kQueueCapacity) dropHeadLocked(bridge);
    const size_t tail = (bridge.head + bridge.count) % kQueueCapacity;
    QueuedFrame &slot = bridge.queue[tail];
    slot.ticket = bridge.nextTicket++;
    slot.producerFrameID = frame->producerFrameID;
    slot.producerTimestampNanoseconds = frame->producerTimestampNanoseconds;
    slot.left = left;
    slot.right = right;
    slot.readyEvent = readyEvent;
    slot.readyValue = frame->producerReadyValue;
    slot.leftWidth = static_cast<uint32_t>(left.width);
    slot.leftHeight = static_cast<uint32_t>(left.height);
    slot.rightWidth = static_cast<uint32_t>(right.width);
    slot.rightHeight = static_cast<uint32_t>(right.height);
    *outCompositorTicket = slot.ticket;
    ++bridge.count;
    ++bridge.stats.submittedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

} // namespace

@interface WVRFrameLease : NSObject
@property(nonatomic) uint64_t ticket;
@property(nonatomic) uint64_t producerFrameID;
@property(nonatomic) uint64_t producerTimestampNanoseconds;
@property(nonatomic, strong) id<MTLTexture> left;
@property(nonatomic, strong) id<MTLTexture> right;
@property(nonatomic, strong) id<MTLSharedEvent> readyEvent;
@property(nonatomic) uint64_t readyValue;
@property(nonatomic) uint32_t leftSlice, leftX, leftY, leftWidth, leftHeight;
@property(nonatomic) uint32_t rightSlice, rightX, rightY, rightWidth, rightHeight;
@end
@implementation WVRFrameLease
@end

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_bind_metal_device_v1(void *opaqueDevice) {
    if (!opaqueDevice) return WVRCompositorStatusInvalidArgument;
    id<MTLDevice> device = (__bridge id<MTLDevice>)opaqueDevice;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.device != device) {
        const bool targetsLive = bridge.drawableWidth[0] != 0 || bridge.drawableWidth[1] != 0;
        if (targetsLive || bridge.count != 0 || bridge.outstandingLeases != 0 ||
            !bridge.completedTickets.empty()) {
            os_unfair_lock_unlock(&bridge.lock);
            return WVRCompositorStatusIncompatibleTexture;
        }
        id<MTLSharedEvent> event = [device newSharedEvent];
        if (!event) {
            os_unfair_lock_unlock(&bridge.lock);
            return WVRCompositorStatusDeviceNotBound;
        }
        event.label = @"Windows VR compositor consumption";
        event.signaledValue = bridge.lastSignaledTicket;
        bridge.device = device;
        bridge.consumerEvent = event;
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_metal_device_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    void *result = bridge.device ? (__bridge_retained void *)bridge.device : nullptr;
    os_unfair_lock_unlock(&bridge.lock);
    return result;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_release_object_v1(void *object) {
    if (object) CFRelease((CFTypeRef)object);
}

extern "C" WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_consumer_event_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    void *result = bridge.consumerEvent ? (__bridge_retained void *)bridge.consumerEvent : nullptr;
    os_unfair_lock_unlock(&bridge.lock);
    return result;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_set_render_scale_v1(float scale) {
    if (!std::isfinite(scale) || scale <= 0.0f || scale > 1.0f) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.renderScale = scale;
    if (bridge.drawableWidth[0] != 0 && bridge.drawableHeight[0] != 0 &&
        bridge.drawableWidth[1] != 0 && bridge.drawableHeight[1] != 0) {
        updateTargetsLocked(bridge,
                            bridge.drawableWidth[0], bridge.drawableHeight[0], bridge.targets.pixelFormat[0],
                            bridge.drawableWidth[1], bridge.drawableHeight[1], bridge.targets.pixelFormat[1]);
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_request_session_exit_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.sessionExitRequested = true;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_reset_session_exit_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.sessionExitRequested = false;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_pause_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    invalidateTargetsLocked(bridge);
    clearTrackingLocked(bridge);
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_targets_v1(
    uint32_t leftWidth, uint32_t leftHeight, uint32_t leftPixelFormat,
    uint32_t rightWidth, uint32_t rightHeight, uint32_t rightPixelFormat) {
    const bool allZero = leftWidth == 0 && leftHeight == 0 && leftPixelFormat == 0 &&
                         rightWidth == 0 && rightHeight == 0 && rightPixelFormat == 0;
    if (allZero) {
        BridgeState &bridge = state();
        os_unfair_lock_lock(&bridge.lock);
        invalidateTargetsLocked(bridge);
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    if (leftWidth == 0 || leftHeight == 0 || rightWidth == 0 || rightHeight == 0) {
        return WVRCompositorStatusInvalidArgument;
    }

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    updateTargetsLocked(bridge, leftWidth, leftHeight, leftPixelFormat,
                        rightWidth, rightHeight, rightPixelFormat);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_targets_v1(
    WVRRenderTargetInfoV1 *outInfo) {
    if (!outInfo || outInfo->structSize < sizeof(WVRRenderTargetInfoV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outInfo = bridge.targets;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_readiness_v1(
    WVRCompositorReadinessV1 *outReadiness) {
    if (!outReadiness || outReadiness->structSize < sizeof(WVRCompositorReadinessV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    outReadiness->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outReadiness->structSize = sizeof(WVRCompositorReadinessV1);
    outReadiness->metalDeviceBound = bridge.device ? 1u : 0u;
    outReadiness->stereoTargetsPublished =
        bridge.targets.width[0] > 0 && bridge.targets.height[0] > 0 &&
        bridge.targets.width[1] > 0 && bridge.targets.height[1] > 0 ? 1u : 0u;
    outReadiness->trackedHeadPoseAvailable =
        (bridge.tracking.flags & WVRDevicePoseTracked) != 0 ? 1u : 0u;
    outReadiness->reserved = 0;
    outReadiness->trackingTimestampNanoseconds = bridge.tracking.timestampNanoseconds;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t *outCompositorTicket) {
    return submitStereoFrame(frame, 0, false, outCompositorTicket);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_for_generation_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t targetGeneration,
    uint64_t *outCompositorTicket) {
    return submitStereoFrame(frame, targetGeneration, true, outCompositorTicket);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v2(
    const WVRSubmitStereoFrameV2 *frame, uint64_t *outCompositorTicket) {
    if (!frame || !outCompositorTicket || frame->abiVersion != WVR_COMPOSITOR_ABI_VERSION_V2 ||
        frame->structSize < sizeof(WVRSubmitStereoFrameV2) || !frame->leftTexture ||
        !frame->rightTexture || !frame->producerReadyEvent || frame->targetGeneration == 0) {
        return WVRCompositorStatusInvalidArgument;
    }
    id<MTLTexture> left = (__bridge id<MTLTexture>)frame->leftTexture;
    id<MTLTexture> right = (__bridge id<MTLTexture>)frame->rightTexture;
    id<MTLSharedEvent> readyEvent = (__bridge id<MTLSharedEvent>)frame->producerReadyEvent;
    auto validSource = [](id<MTLTexture> texture, id<MTLDevice> device, uint32_t slice,
                          uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                          uint32_t pixelFormat) {
        const bool supportedType = texture.textureType == MTLTextureType2D ||
                                   texture.textureType == MTLTextureType2DArray;
        const uint32_t sliceCount = texture.textureType == MTLTextureType2D ? 1u :
                                    static_cast<uint32_t>(texture.arrayLength);
        return texture && texture.device == device && supportedType && texture.sampleCount == 1 &&
               slice < sliceCount && width > 0 && height > 0 &&
               x <= texture.width && y <= texture.height &&
               width <= texture.width - x && height <= texture.height - y &&
               static_cast<uint32_t>(texture.pixelFormat) == pixelFormat;
    };
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.device || !bridge.consumerEvent) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusDeviceNotBound;
    }
    if (frame->targetGeneration != bridge.targets.generation ||
        bridge.targets.width[0] == 0 || bridge.targets.height[0] == 0 ||
        bridge.targets.width[1] == 0 || bridge.targets.height[1] == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (!validSource(left, bridge.device, frame->leftSlice, frame->leftX, frame->leftY,
                     frame->leftWidth, frame->leftHeight, bridge.targets.pixelFormat[0]) ||
        !validSource(right, bridge.device, frame->rightSlice, frame->rightX, frame->rightY,
                     frame->rightWidth, frame->rightHeight, bridge.targets.pixelFormat[1]) ||
        frame->leftWidth > bridge.targets.width[0] || frame->leftHeight > bridge.targets.height[0] ||
        frame->rightWidth > bridge.targets.width[1] || frame->rightHeight > bridge.targets.height[1] ||
        readyEvent.device != bridge.device) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (bridge.nextTicket == 0 ||
        bridge.nextTicket - bridge.lastSignaledTicket - 1 >= kMaxOutstandingTickets) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    if (bridge.count == kQueueCapacity) dropHeadLocked(bridge);
    const size_t tail = (bridge.head + bridge.count) % kQueueCapacity;
    QueuedFrame &slot = bridge.queue[tail];
    slot.ticket = bridge.nextTicket++;
    slot.producerFrameID = frame->producerFrameID;
    slot.producerTimestampNanoseconds = frame->producerTimestampNanoseconds;
    slot.left = left; slot.right = right; slot.readyEvent = readyEvent;
    slot.readyValue = frame->producerReadyValue;
    slot.leftSlice = frame->leftSlice; slot.leftX = frame->leftX; slot.leftY = frame->leftY;
    slot.leftWidth = frame->leftWidth; slot.leftHeight = frame->leftHeight;
    slot.rightSlice = frame->rightSlice; slot.rightX = frame->rightX; slot.rightY = frame->rightY;
    slot.rightWidth = frame->rightWidth; slot.rightHeight = frame->rightHeight;
    *outCompositorTicket = slot.ticket;
    ++bridge.count; ++bridge.stats.submittedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v1(
    WVRAcquiredStereoFrameV1 *outFrame) {
    if (!outFrame || outFrame->structSize < sizeof(WVRAcquiredStereoFrameV1)) {
        return WVRCompositorStatusInvalidArgument;
    }

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.count == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }

    while (bridge.count > 1) dropHeadLocked(bridge);
    QueuedFrame &slot = bridge.queue[bridge.head];
    if (slot.leftSlice != 0 || slot.rightSlice != 0 || slot.leftX != 0 || slot.leftY != 0 ||
        slot.rightX != 0 || slot.rightY != 0 || slot.left.textureType != MTLTextureType2D ||
        slot.right.textureType != MTLTextureType2D || slot.leftWidth != slot.left.width ||
        slot.leftHeight != slot.left.height || slot.rightWidth != slot.right.width || slot.rightHeight != slot.right.height) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusUnsupportedABI;
    }
    WVRFrameLease *lease = [WVRFrameLease new];
    lease.ticket = slot.ticket;
    lease.producerFrameID = slot.producerFrameID;
    lease.producerTimestampNanoseconds = slot.producerTimestampNanoseconds;
    lease.left = slot.left;
    lease.right = slot.right;
    lease.readyEvent = slot.readyEvent;
    lease.readyValue = slot.readyValue;
    lease.leftSlice = slot.leftSlice; lease.leftX = slot.leftX; lease.leftY = slot.leftY;
    lease.leftWidth = slot.leftWidth; lease.leftHeight = slot.leftHeight;
    lease.rightSlice = slot.rightSlice; lease.rightX = slot.rightX; lease.rightY = slot.rightY;
    lease.rightWidth = slot.rightWidth; lease.rightHeight = slot.rightHeight;

    outFrame->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outFrame->structSize = sizeof(WVRAcquiredStereoFrameV1);
    outFrame->compositorTicket = lease.ticket;
    outFrame->producerFrameID = lease.producerFrameID;
    outFrame->producerTimestampNanoseconds = lease.producerTimestampNanoseconds;
    outFrame->lease = (__bridge_retained void *)lease;
    outFrame->leftTexture = (__bridge void *)lease.left;
    outFrame->rightTexture = (__bridge void *)lease.right;
    outFrame->producerReadyEvent = (__bridge void *)lease.readyEvent;
    outFrame->producerReadyValue = lease.readyValue;
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count;
    ++bridge.outstandingLeases;
    ++bridge.stats.acquiredFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v2(
    WVRAcquiredStereoFrameV2 *outFrame) {
    if (!outFrame || outFrame->structSize < sizeof(WVRAcquiredStereoFrameV2))
        return WVRCompositorStatusInvalidArgument;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.count == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    while (bridge.count > 1) dropHeadLocked(bridge);
    QueuedFrame &slot = bridge.queue[bridge.head];
    WVRFrameLease *lease = [WVRFrameLease new];
    lease.ticket = slot.ticket;
    lease.producerFrameID = slot.producerFrameID;
    lease.producerTimestampNanoseconds = slot.producerTimestampNanoseconds;
    lease.left = slot.left; lease.right = slot.right;
    lease.readyEvent = slot.readyEvent; lease.readyValue = slot.readyValue;
    lease.leftSlice = slot.leftSlice; lease.leftX = slot.leftX; lease.leftY = slot.leftY;
    lease.leftWidth = slot.leftWidth; lease.leftHeight = slot.leftHeight;
    lease.rightSlice = slot.rightSlice; lease.rightX = slot.rightX; lease.rightY = slot.rightY;
    lease.rightWidth = slot.rightWidth; lease.rightHeight = slot.rightHeight;
    outFrame->abiVersion = WVR_COMPOSITOR_ABI_VERSION_V2;
    outFrame->structSize = sizeof(WVRAcquiredStereoFrameV2);
    outFrame->compositorTicket = lease.ticket;
    outFrame->producerFrameID = lease.producerFrameID;
    outFrame->producerTimestampNanoseconds = lease.producerTimestampNanoseconds;
    outFrame->lease = (__bridge_retained void *)lease;
    outFrame->leftTexture = (__bridge void *)lease.left;
    outFrame->rightTexture = (__bridge void *)lease.right;
    outFrame->producerReadyEvent = (__bridge void *)lease.readyEvent;
    outFrame->producerReadyValue = lease.readyValue;
    outFrame->leftSlice = lease.leftSlice; outFrame->leftX = lease.leftX; outFrame->leftY = lease.leftY;
    outFrame->leftWidth = lease.leftWidth; outFrame->leftHeight = lease.leftHeight;
    outFrame->rightSlice = lease.rightSlice; outFrame->rightX = lease.rightX; outFrame->rightY = lease.rightY;
    outFrame->rightWidth = lease.rightWidth; outFrame->rightHeight = lease.rightHeight;
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count; ++bridge.outstandingLeases; ++bridge.stats.acquiredFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_release_acquired_frame_v1(void *opaqueLease) {
    if (!opaqueLease) return;
    WVRFrameLease *lease = (__bridge_transfer WVRFrameLease *)opaqueLease;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    markTicketCompleteLocked(bridge, lease.ticket);
    if (bridge.outstandingLeases > 0) --bridge.outstandingLeases;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_frame_tracking_v1(
    uint64_t timestampNanoseconds, uint32_t flags,
    const float *originFromDevice16, const float *deviceFromEye32,
    const float *projection32, const float *frustumTangents8, const float *depthRange2) {
    if (!originFromDevice16 || !deviceFromEye32 || !projection32 ||
        !frustumTangents8 || !depthRange2) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    bridge.tracking.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    bridge.tracking.structSize = sizeof(WVRFrameTrackingV1);
    bridge.tracking.flags = flags;
    bridge.tracking.timestampNanoseconds = timestampNanoseconds;
    std::copy(originFromDevice16, originFromDevice16 + 16, bridge.tracking.originFromDevice);
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        std::copy(deviceFromEye32 + eye * 16, deviceFromEye32 + (eye + 1) * 16,
                  bridge.tracking.deviceFromEye[eye]);
        std::copy(projection32 + eye * 16, projection32 + (eye + 1) * 16,
                  bridge.tracking.projection[eye]);
        std::copy(frustumTangents8 + eye * 4, frustumTangents8 + (eye + 1) * 4,
                  bridge.tracking.frustumTangents[eye]);
    }
    std::copy(depthRange2, depthRange2 + 2, bridge.tracking.depthRange);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_frame_tracking_v1(
    WVRFrameTrackingV1 *outTracking) {
    if (!outTracking || outTracking->structSize < sizeof(WVRFrameTrackingV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outTracking = bridge.tracking;
    if (bridge.sessionExitRequested) {
        outTracking->flags |= WVRDevicePoseSessionExitRequested;
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_controller_state_v1(
    uint32_t role, WVRControllerStateV1 *outState) {
    if (role >= WVR_COMPOSITOR_VIEW_COUNT || !outState ||
        outState->structSize < sizeof(WVRControllerStateV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outState = bridge.controllers[role];
    outState->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outState->structSize = sizeof(WVRControllerStateV1);
    outState->role = role;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_controller_state_v1(
    uint32_t role, uint32_t flags, uint64_t timestampNanoseconds,
    const float *originFromController16, uint64_t buttons,
    float trigger, float grip, float thumbstickX, float thumbstickY) {
    if (role > WVRControllerRoleRight || !originFromController16 ||
        !std::isfinite(trigger) || !std::isfinite(grip) ||
        !std::isfinite(thumbstickX) || !std::isfinite(thumbstickY)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    WVRControllerStateV1 &controller = bridge.controllers[role];
    controller.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    controller.structSize = sizeof(WVRControllerStateV1);
    controller.role = role;
    controller.flags = flags;
    controller.timestampNanoseconds = timestampNanoseconds;
    std::copy(originFromController16, originFromController16 + 16, controller.originFromController);
    controller.buttons = buttons;
    controller.trigger = std::clamp(trigger, 0.0f, 1.0f);
    controller.grip = std::clamp(grip, 0.0f, 1.0f);
    controller.thumbstickX = std::clamp(thumbstickX, -1.0f, 1.0f);
    controller.thumbstickY = std::clamp(thumbstickY, -1.0f, 1.0f);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_haptic_v1(
    uint32_t role, float amplitude, float frequencyHz, float durationSeconds,
    uint64_t *outSequence) {
    if (role > WVRControllerRoleRight || !outSequence ||
        !std::isfinite(amplitude) || !std::isfinite(frequencyHz) ||
        !std::isfinite(durationSeconds)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        *outSequence = 0;
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoHapticAvailable;
    }
    WVRHapticRequestV1 &request = bridge.haptics[role];
    request.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    request.structSize = sizeof(WVRHapticRequestV1);
    request.role = role;
    request.reserved = 0;
    request.sequence = bridge.nextHapticSequence++;
    request.amplitude = std::clamp(amplitude, 0.0f, 1.0f);
    request.frequencyHz = std::clamp(frequencyHz, 0.0f, 1000.0f);
    request.durationSeconds = std::clamp(durationSeconds, 0.01f, 1.0f);
    request.reservedFloat = 0.0f;
    bridge.hapticPending[role] = true;
    *outSequence = request.sequence;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_take_haptic_v1(
    uint32_t role, WVRHapticRequestV1 *outRequest) {
    if (role > WVRControllerRoleRight || !outRequest ||
        outRequest->structSize < sizeof(WVRHapticRequestV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.hapticPending[role]) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoHapticAvailable;
    }
    *outRequest = bridge.haptics[role];
    bridge.hapticPending[role] = false;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_stats_v1(
    WVRCompositorStatsV1 *outStats) {
    if (!outStats || outStats->structSize < sizeof(WVRCompositorStatsV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outStats = bridge.stats;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

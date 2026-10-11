#ifndef WINDOWS_VR_COMPOSITOR_BRIDGE_H
#define WINDOWS_VR_COMPOSITOR_BRIDGE_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__)
#define WVR_COMPOSITOR_EXPORT __attribute__((visibility("default")))
#else
#define WVR_COMPOSITOR_EXPORT
#endif

#define WVR_COMPOSITOR_ABI_VERSION 1u
#define WVR_COMPOSITOR_ABI_VERSION_V2 2u
#define WVR_COMPOSITOR_VIEW_COUNT 2u

typedef enum WVRCompositorStatusV1 {
    WVRCompositorStatusOK = 0,
    WVRCompositorStatusInvalidArgument = -1,
    WVRCompositorStatusDeviceNotBound = -2,
    WVRCompositorStatusInvalidTexture = -3,
    WVRCompositorStatusIncompatibleTexture = -4,
    WVRCompositorStatusNoFrameAvailable = -5,
    WVRCompositorStatusUnsupportedABI = -6,
    WVRCompositorStatusNoHapticAvailable = -7
} WVRCompositorStatusV1;

typedef enum WVRDevicePoseFlagsV1 {
    WVRDevicePoseTracked = 1u << 0,
    WVRDevicePosePredicted = 1u << 1,
    WVRDevicePoseSessionExitRequested = 1u << 2
} WVRDevicePoseFlagsV1;

/// Describes the producer's per-eye swapchain dimensions and the current
/// compositor target generation. At the default render scale of 1.0 these are
/// the drawable view dimensions. A host-selected scale below 1.0 advertises
/// proportionally smaller producer dimensions; the native compositor spatially
/// scales those frames into the full drawable views. Eye index 0 maps to
/// drawable.views[0]; eye index 1 maps to drawable.views[1].
typedef struct WVRRenderTargetInfoV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t generation;
    uint32_t width[WVR_COMPOSITOR_VIEW_COUNT];
    uint32_t height[WVR_COMPOSITOR_VIEW_COUNT];
    uint32_t pixelFormat[WVR_COMPOSITOR_VIEW_COUNT];
    uint32_t reserved[2];
} WVRRenderTargetInfoV1;

typedef struct WVRCompositorReadinessV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t metalDeviceBound;
    uint32_t stereoTargetsPublished;
    uint32_t trackedHeadPoseAvailable;
    uint32_t reserved;
    uint64_t trackingTimestampNanoseconds;
} WVRCompositorReadinessV1;

/// Predicted head pose and the exact per-eye render geometry for one frame.
/// Matrices are column-major. deviceFromEye follows CompositorServices' view
/// transform convention: originFromDevice * deviceFromEye = originFromEye.
/// Frustum tangent order is left, right, top, bottom, matching Apple ARKit's
/// CompositorServices API. `depthRange` order is far, near as supplied by Apple.
typedef struct WVRFrameTrackingV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t flags;
    uint32_t reserved;
    uint64_t timestampNanoseconds;
    float originFromDevice[16];
    float deviceFromEye[WVR_COMPOSITOR_VIEW_COUNT][16];
    float projection[WVR_COMPOSITOR_VIEW_COUNT][16];
    float frustumTangents[WVR_COMPOSITOR_VIEW_COUNT][4];
    float depthRange[2];
} WVRFrameTrackingV1;

typedef enum WVRControllerRoleV1 {
    WVRControllerRoleLeft = 0,
    WVRControllerRoleRight = 1
} WVRControllerRoleV1;

typedef enum WVRControllerPoseFlagsV1 {
    WVRControllerPoseTracked = 1u << 0,
    WVRControllerPosePredicted = 1u << 1,
    WVRControllerConnected = 1u << 2
} WVRControllerPoseFlagsV1;

/// Latest tracked accessory and sampled physical input for one hand. Matrix is
/// column-major and maps controller-local coordinates into the ARKit origin.
/// Button bits: 0 primary, 1 secondary, 2 menu, 3 stick click, 4 trigger click,
/// 5 grip click, 6 trigger touched, 7 grip touched.
typedef struct WVRControllerStateV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t role;
    uint32_t flags;
    uint64_t timestampNanoseconds;
    float originFromController[16];
    uint64_t buttons;
    float trigger;
    float grip;
    float thumbstickX;
    float thumbstickY;
    float reserved[2];
} WVRControllerStateV1;

/// Single-slot, latest-wins haptic request. Frequency is advisory; Apple
/// GameController haptics currently maps this to intensity/sharpness.
typedef struct WVRHapticRequestV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint32_t role;
    uint32_t reserved;
    uint64_t sequence;
    float amplitude;
    float frequencyHz;
    float durationSeconds;
    float reservedFloat;
} WVRHapticRequestV1;

/// A stereo submission. Texture and event pointers are borrowed on entry; the
/// bridge retains them only when it returns WVRCompositorStatusOK. Textures must be
/// 2D, single-sample textures on the compositor's Metal device, and must match
/// the current producer dimensions and MTLPixelFormat. If producer dimensions
/// are below drawable dimensions, the compositor spatially scales the frame.
typedef struct WVRSubmitStereoFrameV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t producerFrameID;
    uint64_t producerTimestampNanoseconds;
    void *leftTexture;
    void *rightTexture;
    void *producerReadyEvent;
    uint64_t producerReadyValue;
} WVRSubmitStereoFrameV1;

/// A lease returned by acquireLatest. Resource pointers are borrowed from lease
/// and remain valid until releaseAcquiredFrame is called.
typedef struct WVRAcquiredStereoFrameV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t compositorTicket;
    uint64_t producerFrameID;
    uint64_t producerTimestampNanoseconds;
    void *lease;
    void *leftTexture;
    void *rightTexture;
    void *producerReadyEvent;
    uint64_t producerReadyValue;
} WVRAcquiredStereoFrameV1;

/// Versioned array-slice/subrectangle submission. Unlike V1, the source
/// textures may be 2D arrays; each eye names a valid slice and nonempty region.
typedef struct WVRSubmitStereoFrameV2 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t producerFrameID;
    uint64_t producerTimestampNanoseconds;
    void *leftTexture;
    void *rightTexture;
    void *producerReadyEvent;
    uint64_t producerReadyValue;
    uint64_t targetGeneration;
    uint32_t leftSlice;
    uint32_t leftX;
    uint32_t leftY;
    uint32_t leftWidth;
    uint32_t leftHeight;
    uint32_t rightSlice;
    uint32_t rightX;
    uint32_t rightY;
    uint32_t rightWidth;
    uint32_t rightHeight;
} WVRSubmitStereoFrameV2;

typedef struct WVRAcquiredStereoFrameV2 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t compositorTicket;
    uint64_t producerFrameID;
    uint64_t producerTimestampNanoseconds;
    void *lease;
    void *leftTexture;
    void *rightTexture;
    void *producerReadyEvent;
    uint64_t producerReadyValue;
    uint32_t leftSlice;
    uint32_t leftX;
    uint32_t leftY;
    uint32_t leftWidth;
    uint32_t leftHeight;
    uint32_t rightSlice;
    uint32_t rightX;
    uint32_t rightY;
    uint32_t rightWidth;
    uint32_t rightHeight;
} WVRAcquiredStereoFrameV2;

/// Returns a retained id<MTLDevice> as an opaque pointer. Release it with
/// wvr_compositor_release_object_v1. The returned device is the exact device
/// used by Compositor Services' LayerRenderer.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_bind_metal_device_v1(void *device);
WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_metal_device_v1(void);
WVR_COMPOSITOR_EXPORT void wvr_compositor_release_object_v1(void *object);

/// Returns a retained MTLSharedEvent. Producers wait for compositorTicket on
/// this event before reusing a submitted texture. Release with release_object.
WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_consumer_event_v1(void);

/// Selects producer resolution relative to the current drawable sizes. The
/// default is 1.0 (exact-size rendering); values in (0, 1) advertise smaller
/// guest targets and enable native ordinary-Metal spatial scaling. Apply this
/// between guest sessions because existing swapchains are invalidated when the
/// effective producer dimensions change. This is a native-host API and does not
/// change the fixed-width Wine/WMT transport record.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_set_render_scale_v1(float scale);

/// Invalidates targets and queued frames and clears published tracking,
/// controller, and pending haptic state. Already-acquired frame leases remain
/// alive and are completed only after their consuming GPU command buffer ends.
WVR_COMPOSITOR_EXPORT void wvr_compositor_pause_v1(void);
/// Sticky cooperative stop signal. It remains set across pause and pose updates
/// until the parent explicitly resets it. It requests XR STOPPING/EXITING; it
/// does not terminate a process or promise that a session can restart.
WVR_COMPOSITOR_EXPORT void wvr_compositor_request_session_exit_v1(void);
WVR_COMPOSITOR_EXPORT void wvr_compositor_reset_session_exit_v1(void);

/// Updates current drawable dimensions and formats. A changed output or
/// producer target invalidates queued submissions; generation protects a guest
/// from submitting swapchains created for an earlier target configuration.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_targets_v1(
    uint32_t leftWidth, uint32_t leftHeight, uint32_t leftPixelFormat,
    uint32_t rightWidth, uint32_t rightHeight, uint32_t rightPixelFormat);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_targets_v1(WVRRenderTargetInfoV1 *outInfo);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_readiness_v1(
    WVRCompositorReadinessV1 *outReadiness);

/// Enqueues a stereo GPU frame without blocking. The queue holds at most three
/// frames and drops/releases the oldest queued frame when full. Tickets are
/// signaled in order only when a queued frame is safely dropped or an acquired
/// frame's consuming GPU work has completed. On success, outCompositorTicket is
/// monotonic and may be waited on via the consumer event.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t *outCompositorTicket);
/// Same submission with an atomic target-generation check for WMT/DXMT callers.
/// The legacy V1 entry point remains available for existing native callers.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_for_generation_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t targetGeneration,
    uint64_t *outCompositorTicket);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v2(
    const WVRSubmitStereoFrameV2 *frame, uint64_t *outCompositorTicket);

/// Removes the newest queued frame and drops stale queued frames. Returns
/// NoFrameAvailable when the queue is empty. Returned pointers are borrowed from
/// the lease; call releaseAcquiredFrame only after GPU work using them completes.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v1(
    WVRAcquiredStereoFrameV1 *outFrame);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v2(
    WVRAcquiredStereoFrameV2 *outFrame);
WVR_COMPOSITOR_EXPORT void wvr_compositor_release_acquired_frame_v1(void *lease);

/// Publishes ARKit's predicted head pose plus the compositor's per-eye view
/// transforms, projection matrices, and frustum angles for the same predicted
/// frame time. Arrays are flat, contiguous, and column-major. A zero flags value
/// marks the head pose unavailable. Pause/invalidation clears the timestamp and
/// all geometry; consumers must not use zeroed geometry as a projection.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_frame_tracking_v1(
    uint64_t timestampNanoseconds, uint32_t flags,
    const float *originFromDevice16,
    const float *deviceFromEye32,
    const float *projection32,
    const float *frustumTangents8,
    const float *depthRange2);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_frame_tracking_v1(WVRFrameTrackingV1 *outTracking);

/// Reads the latest controller sample. A successful call can still have flags
/// zero when the selected controller is disconnected or its pose is untracked.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_controller_state_v1(
    uint32_t role, WVRControllerStateV1 *outState);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_controller_state_v1(
    uint32_t role, uint32_t flags, uint64_t timestampNanoseconds,
    const float *originFromController16, uint64_t buttons,
    float trigger, float grip, float thumbstickX, float thumbstickY);

/// Enqueues a bounded, latest-wins haptic request for the selected hand. The
/// caller never waits for hardware. `take_haptic` consumes at most one request.
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_haptic_v1(
    uint32_t role, float amplitude, float frequencyHz, float durationSeconds,
    uint64_t *outSequence);
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_take_haptic_v1(
    uint32_t role, WVRHapticRequestV1 *outRequest);

/// Diagnostic counters are advisory and do not report game or rendering status.
typedef struct WVRCompositorStatsV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    uint64_t submittedFrames;
    uint64_t acquiredFrames;
    uint64_t droppedFrames;
    uint64_t completedFrames;
    uint32_t queuedFrames;
    uint32_t reserved;
} WVRCompositorStatsV1;
WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_stats_v1(WVRCompositorStatsV1 *outStats);

#if defined(__cplusplus)
}
#endif

#endif /* WINDOWS_VR_COMPOSITOR_BRIDGE_H */

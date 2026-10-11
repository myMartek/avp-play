#pragma once

#include <stdint.h>
#include "WindowsVRCompositorBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(DXMT_NATIVE)
#define WVR_WMT_IMPORT __declspec(dllimport)
#else
#define WVR_WMT_IMPORT
#endif

typedef enum WMTWindowsVRRequestKindV1 {
  WMTWindowsVRRequestTargets = 1,
  WMTWindowsVRRequestReadiness = 2,
  WMTWindowsVRRequestTracking = 3,
  WMTWindowsVRRequestController = 4,
  WMTWindowsVRRequestHaptic = 5,
  WMTWindowsVRRequestSubmitStereo = 6,
} WMTWindowsVRRequestKindV1;

// Fixed-width, pointer-free request/result record shared by the 32-bit WOW64
// and 64-bit Wine Unix dispatch tables. Texture/event fields are host WMT
// object IDs and are only interpreted by winemetal_unix.c on the host side.
#pragma pack(push, 4)
typedef struct WMTWindowsVRRequestV1 {
  uint32_t abiVersion;
  uint32_t structSize;
  uint32_t kind;
  uint32_t role;
  int32_t status;
  uint32_t reserved;
  uint64_t commandBuffer;
  uint64_t leftTexture;
  uint64_t rightTexture;
  uint64_t producerEvent;
  uint64_t producerValue;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint64_t targetGeneration;
  uint64_t compositorTicket;
  uint64_t consumerEvent; // retained native MTLSharedEvent as WMT object ID
  WVRRenderTargetInfoV1 targets;
  WVRCompositorReadinessV1 readiness;
  WVRFrameTrackingV1 tracking;
  WVRControllerStateV1 controller;
  float hapticAmplitude;
  float hapticFrequencyHz;
  float hapticDurationSeconds;
  uint64_t hapticSequence;
} WMTWindowsVRRequestV1;
#pragma pack(pop)

// Added at the end of the existing Winemetal Unix-call ABI table. The runtime
// never calls native compositor functions directly from the Wine guest.
WVR_WMT_IMPORT int32_t WMTWindowsVRBridgeCallV1(WMTWindowsVRRequestV1 *request);

#pragma pack(push, 4)
typedef struct WMTWindowsVRRequestV2 {
  uint32_t abiVersion;
  uint32_t structSize;
  int32_t status;
  uint32_t reserved;
  uint64_t commandBuffer;
  uint64_t producerEvent;
  uint64_t producerValue;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint64_t targetGeneration;
  uint64_t leftTexture;
  uint64_t rightTexture;
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
  uint64_t compositorTicket;
  uint64_t consumerEvent;
} WMTWindowsVRRequestV2;
#pragma pack(pop)

WVR_WMT_IMPORT int32_t WMTWindowsVRBridgeCallV2(WMTWindowsVRRequestV2 *request);
#if defined(__cplusplus)
static_assert(sizeof(WMTWindowsVRRequestV2) == 136, "WMT V2 fixed-width transport layout changed");
#else
_Static_assert(sizeof(WMTWindowsVRRequestV2) == 136, "WMT V2 fixed-width transport layout changed");
#endif

#ifdef __cplusplus
}
#endif

#pragma once

#include <cstdint>
#include "d3d11.h"

inline constexpr GUID kWVRD3D11ContextExt2IID = {0xbc8694b6, 0xa18f, 0x48d8, {0xbc, 0xe1, 0x90, 0xda, 0x0b, 0x6b, 0x7f, 0x42}};
inline constexpr GUID kWVRD3D11ContextExt3IID = {0xd9e15e9c, 0x7c99, 0x4b09, {0x8d, 0xd8, 0x62, 0x8d, 0x3c, 0xf0, 0x04, 0xa7}};

// Private DXMT adapter interface shared by the project-owned OpenXR runtime
// and the generated DXMT source overlay. The compositor sees actual Metal
// objects only in the Unix WMT dispatch; guest ID3D11Resource pointers never
// cross that boundary as native pointers.
struct WVRDXMTTargetInfoV1 {
  uint32_t width[2];
  uint32_t height[2];
  uint32_t pixelFormat[2]; // Producer swapchain MTLPixelFormat raw values.
  uint64_t generation;
};

struct WVRDXMTSubmitFrameV1 {
  ID3D11Resource *left;
  ID3D11Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
};

struct WVRDXMTSubmitFrameV2 {
  ID3D11Resource *left;
  ID3D11Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint32_t leftArraySlice;
  uint32_t leftX;
  uint32_t leftY;
  uint32_t leftWidth;
  uint32_t leftHeight;
  uint32_t rightArraySlice;
  uint32_t rightX;
  uint32_t rightY;
  uint32_t rightWidth;
  uint32_t rightHeight;
};

enum WVRDXMTControllerRoleV1 {
  WVRDXMTControllerRoleLeft = 0,
  WVRDXMTControllerRoleRight = 1
};

enum WVRDXMTControllerButtonV1 {
  WVRDXMTButtonPrimary = 1ull << 0,
  WVRDXMTButtonSecondary = 1ull << 1,
  WVRDXMTButtonMenu = 1ull << 2,
  WVRDXMTButtonThumbstickClick = 1ull << 3,
  WVRDXMTButtonTriggerClick = 1ull << 4,
  WVRDXMTButtonGripClick = 1ull << 5,
  WVRDXMTButtonTriggerTouch = 1ull << 6,
  WVRDXMTButtonGripTouch = 1ull << 7
};

// Must match native WVRDevicePoseFlagsV1; the guest header has no dependency
// on Objective-C/native compositor resource types.
enum WVRDXMTTrackingFlagsV1 : uint32_t {
  WVRDXMTDevicePoseTracked = 1u << 0,
  WVRDXMTDevicePosePredicted = 1u << 1,
  WVRDXMTDevicePoseSessionExitRequested = 1u << 2
};

struct WVRDXMTTrackingV1 {
  uint32_t flags;
  uint64_t timestampNanoseconds;
  float originFromDevice[16];
  float deviceFromEye[2][16];
  float frustumTangents[2][4];
};

struct WVRDXMTControllerV1 {
  uint32_t role;
  uint32_t flags;
  uint64_t timestampNanoseconds;
  float originFromController[16];
  uint64_t buttons;
  float trigger;
  float grip;
  float thumbstickX;
  float thumbstickY;
};

struct WVRDXMTHapticV1 {
  uint32_t role;
  float amplitude;
  float frequencyHz;
  float durationSeconds;
};

// S_OK means the native compositor accepted the queued stereo submission or
// wait. It does not imply that the GPU completed or that a frame was displayed.

struct __declspec(uuid("bc8694b6-a18f-48d8-bce1-90da0b6b7f42")) IMTLD3D11ContextExt2
    : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTargets(WVRDXMTTargetInfoV1 *targets) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTracking(WVRDXMTTrackingV1 *tracking) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRController(uint32_t role, WVRDXMTControllerV1 *controller) = 0;
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRHaptic(const WVRDXMTHapticV1 *haptic) = 0;
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRFrame(const WVRDXMTSubmitFrameV1 *frame) = 0;
  virtual HRESULT STDMETHODCALLTYPE WaitWindowsVRImage(ID3D11Resource *resource) = 0;
};

// Optional, separately queried interface; Ext2's published vtable is frozen.
struct __declspec(uuid("d9e15e9c-7c99-4b09-8dd8-628d3cf004a7")) IMTLD3D11ContextExt3
    : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRFrameV2(const WVRDXMTSubmitFrameV2 *frame) = 0;
};

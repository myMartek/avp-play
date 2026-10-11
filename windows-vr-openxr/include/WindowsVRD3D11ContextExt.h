#pragma once

#include <cstdint>
#include "d3d11.h"

// Private DXMT adapter interface shared by the project-owned OpenXR runtime
// and the generated DXMT source overlay. The compositor sees actual Metal
// objects only in the Unix WMT dispatch; guest ID3D11Resource pointers never
// cross that boundary as native pointers.
struct WVRDXMTTargetInfoV1 {
  uint32_t width[2];
  uint32_t height[2];
  uint32_t pixelFormat[2]; // MTLPixelFormat raw values from the host bridge.
  uint64_t generation;
};

struct WVRDXMTSubmitFrameV1 {
  ID3D11Resource *left;
  ID3D11Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
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

#pragma once
#include "d3d12.h"
#include "WindowsVRD3D11ContextExt.h"

inline constexpr GUID kWVRD3D12CommandQueueExtIID = {0x08e6b53f, 0xede5, 0x4524, {0x90, 0xb8, 0x34, 0x45, 0xef, 0x05, 0x9b, 0x1e}};

// Optional project-owned DXMT queue interface. Never reinterpret guest COM
// pointers as Metal objects. The implementation resolves resources inside DXMT
// and uses the fixed-width WMT V2 submission and native consumer event.
struct WVRDXMTD3D12SubmitFrameV1 {
  ID3D12Resource *left;
  ID3D12Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint32_t leftArraySlice, leftX, leftY, leftWidth, leftHeight;
  uint32_t rightArraySlice, rightX, rightY, rightWidth, rightHeight;
};

struct __declspec(uuid("08e6b53f-ede5-4524-90b8-3445ef059b1e")) IMTLD3D12CommandQueueExt : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTargets(WVRDXMTTargetInfoV1 *targets) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTracking(WVRDXMTTrackingV1 *tracking) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRController(uint32_t role, WVRDXMTControllerV1 *controller) = 0;
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRHaptic(const WVRDXMTHapticV1 *haptic) = 0;
  // Images are released in D3D12_RESOURCE_STATE_COMMON on this DIRECT queue.
  // Accepted submissions are ordered after prior queue work. Reacquisition
  // enqueues a consumer-event wait before any subsequent writes on this queue.
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRFrame(const WVRDXMTD3D12SubmitFrameV1 *frame) = 0;
  virtual HRESULT STDMETHODCALLTYPE WaitWindowsVRImage(ID3D12Resource *resource) = 0;
};

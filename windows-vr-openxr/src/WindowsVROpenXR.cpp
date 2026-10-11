#define XR_USE_GRAPHICS_API_D3D11
#define XR_USE_GRAPHICS_API_D3D12
#define XR_NO_PROTOTYPES
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include <WindowsVRD3D11ContextExt.h>
#include <WindowsVRD3D12CommandQueueExt.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cctype>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#if defined(_WIN32)
#define WVR_EXPORT extern "C" __declspec(dllexport)
#else
#define WVR_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
// Keep an explicit IID so this source also links with MinGW's COM headers,
// which require a separate __CRT_UUID_DECL specialization for __uuidof().
inline constexpr GUID kIIDMTLD3D11ContextExt2 = {
    0xbc8694b6, 0xa18f, 0x48d8, {0xbc, 0xe1, 0x90, 0xda, 0x0b, 0x6b, 0x7f, 0x42}};
inline constexpr GUID kIIDMTLD3D11ContextExt3 = {
    0xd9e15e9c, 0x7c99, 0x4b09, {0x8d, 0xd8, 0x62, 0x8d, 0x3c, 0xf0, 0x04, 0xa7}};
inline constexpr GUID kIIDMTLD3D12CommandQueueExt = {
    0x08e6b53f, 0xede5, 0x4524, {0x90, 0xb8, 0x34, 0x45, 0xef, 0x05, 0x9b, 0x1e}};
constexpr uint64_t kMagicInstance = 0x575652494e535431ull;
constexpr uint64_t kMagicSession = 0x5756525345535331ull;
constexpr uint64_t kMagicSwapchain = 0x5756525357504331ull;
constexpr uint64_t kMagicSpace = 0x5756525350414331ull;
constexpr uint64_t kMagicActionSet = 0x5756524143535431ull;
constexpr uint64_t kMagicAction = 0x5756524143544e31ull;
constexpr uint32_t kViewCount = 2;
constexpr uint32_t kImageCount = 3;
constexpr XrDuration kMaximumWait = 100'000'000;
constexpr uint32_t kControllerLeft = 0;
constexpr uint32_t kControllerRight = 1;

struct Instance;
struct Session;
struct Swapchain;
struct Space;
struct ActionSet;
struct Action;
struct Image {
  ID3D11Texture2D *texture11 = nullptr;
  ID3D12Resource *resource12 = nullptr;
  bool acquired = false;
  bool waited = false;
  uint64_t lastReleasedFrame = 0;
  uint64_t releaseOrder = 0;
};

struct SessionEvent {
  XrSessionState state = XR_SESSION_STATE_UNKNOWN;
  XrTime time = 0;
};

struct ControllerSample {
  WVRDXMTControllerV1 left{};
  WVRDXMTControllerV1 right{};
};

struct ActionValue {
  bool boolean = false;
  float scalar = 0.0f;
  XrVector2f vector{};
  XrTime lastChangeTime = 0;
  bool changed = false;
};

struct Instance {
  uint64_t magic = kMagicInstance;
  XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
  XrSystemId system = 1;
  bool graphicsRequirementsQueried = false;
  bool d3d11Enabled = false;
  bool d3d12Enabled = false;
  bool d3d12BackendAvailable = false;
  bool d3d12GraphicsRequirementsQueried = false;
  LUID d3d12AdapterLuid{};
  D3D_FEATURE_LEVEL d3d12MinFeatureLevel = D3D_FEATURE_LEVEL_11_0;
  WVRDXMTTargetInfoV1 targets{};
  std::mutex mutex;
  std::unordered_map<std::string, XrPath> paths;
  std::unordered_map<XrPath, std::string> pathStrings;
  std::vector<std::unique_ptr<ActionSet>> actionSets;
  std::vector<std::unique_ptr<Action>> actions;
  std::unordered_map<XrPath, XrPath> interactionProfiles;
  std::unordered_map<XrPath, XrAction> bindings;
  uint64_t nextPath = 1;
};
struct Session {
  uint64_t magic = kMagicSession;
  Instance *instance = nullptr;
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *context = nullptr;
  IMTLD3D11ContextExt2 *dxmt = nullptr;
  IMTLD3D11ContextExt3 *dxmtExt3 = nullptr;
  ID3D12Device *device12 = nullptr;
  ID3D12CommandQueue *queue12 = nullptr;
  IMTLD3D12CommandQueueExt *dxmtQueue12 = nullptr;
  bool d3d12 = false;
  std::atomic<bool> begun{false};
  bool frameWaited = false;
  bool frameBegun = false;
  std::atomic<bool> exitRequested{false};
  uint64_t frameIndex = 0;
  XrTime predictedTime = 0;
  XrTime lastWaitTrackingTime = 0;
  std::atomic<XrSessionState> state{XR_SESSION_STATE_IDLE};
  std::mutex eventMutex;
  bool actionSetsAttached = false;
  std::vector<XrActionSet> attachedActionSets;
  std::vector<XrActionSet> activeActionSets;
  std::unordered_map<XrActionSet, XrPath> activeSetSubactions;
  ControllerSample controllers{};
  std::vector<SessionEvent> events;
  std::vector<Swapchain *> swapchains;
};

HRESULT GetSessionTargets(Session *session, WVRDXMTTargetInfoV1 *targets) {
  return session->d3d12 ? session->dxmtQueue12->GetWindowsVRTargets(targets)
                        : session->dxmt->GetWindowsVRTargets(targets);
}
HRESULT GetSessionTracking(Session *session, WVRDXMTTrackingV1 *tracking) {
  return session->d3d12 ? session->dxmtQueue12->GetWindowsVRTracking(tracking)
                        : session->dxmt->GetWindowsVRTracking(tracking);
}
HRESULT GetSessionController(Session *session, uint32_t role, WVRDXMTControllerV1 *controller) {
  return session->d3d12 ? session->dxmtQueue12->GetWindowsVRController(role, controller)
                        : session->dxmt->GetWindowsVRController(role, controller);
}
HRESULT SubmitSessionHaptic(Session *session, const WVRDXMTHapticV1 *haptic) {
  return session->d3d12 ? session->dxmtQueue12->SubmitWindowsVRHaptic(haptic)
                        : session->dxmt->SubmitWindowsVRHaptic(haptic);
}
HRESULT WaitSessionImage(Session *session, Image &image) {
  if (session->d3d12)
    return image.resource12 ? session->dxmtQueue12->WaitWindowsVRImage(image.resource12) : E_INVALIDARG;
  return image.texture11 ? session->dxmt->WaitWindowsVRImage(image.texture11) : E_INVALIDARG;
}

struct Swapchain {
  uint64_t magic = kMagicSwapchain;
  Session *session = nullptr;
  XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
  std::vector<Image> images;
  std::deque<uint32_t> acquiredImages;
  uint64_t nextReleaseOrder = 1;
  uint32_t nextImage = 0;
  bool staticImageAcquired = false;
  uint64_t targetGeneration = 0;
};
struct Space {
  uint64_t magic = kMagicSpace;
  Session *session = nullptr;
  XrReferenceSpaceType type = XR_REFERENCE_SPACE_TYPE_LOCAL;
  XrPosef poseInReferenceSpace{{0,0,0,1},{0,0,0}};
  XrAction action = XR_NULL_HANDLE;
  XrPath subactionPath = XR_NULL_PATH;
  XrPosef poseInActionSpace{{0,0,0,1},{0,0,0}};
};
struct ActionSet {
  uint64_t magic = kMagicActionSet;
  Instance *instance = nullptr;
  std::string name;
  uint32_t priority = 0;
  std::vector<XrAction> actions;
};
struct Action {
  uint64_t magic = kMagicAction;
  ActionSet *set = nullptr;
  std::string name;
  XrActionType type = XR_ACTION_TYPE_BOOLEAN_INPUT;
  std::vector<XrPath> subactionPaths;
  std::vector<XrPath> bindingPaths;
  std::unordered_map<uint32_t, ActionValue> values;
};
std::mutex g_mutex;
std::mutex g_handleMutex;
std::unordered_set<const void *> g_liveHandles;
std::vector<std::unique_ptr<Instance>> g_instances;
std::vector<std::unique_ptr<Session>> g_sessions;
std::vector<std::unique_ptr<Swapchain>> g_swapchains;
std::vector<std::unique_ptr<Space>> g_spaces;
std::atomic<uint64_t> g_frameID{1};

void RegisterHandle(const void *handle) { std::lock_guard<std::mutex> lock(g_handleMutex); g_liveHandles.insert(handle); }
void UnregisterHandle(const void *handle) { std::lock_guard<std::mutex> lock(g_handleMutex); g_liveHandles.erase(handle); }
bool IsLiveHandle(const void *handle) { if (!handle) return false; std::lock_guard<std::mutex> lock(g_handleMutex); return g_liveHandles.contains(handle); }
Instance *GetInstance(XrInstance h) { auto *p = reinterpret_cast<Instance *>(h); return IsLiveHandle(p) && p->magic == kMagicInstance ? p : nullptr; }
Session *GetSession(XrSession h) { auto *p = reinterpret_cast<Session *>(h); return IsLiveHandle(p) && p->magic == kMagicSession ? p : nullptr; }
Swapchain *GetSwapchain(XrSwapchain h) { auto *p = reinterpret_cast<Swapchain *>(h); return IsLiveHandle(p) && p->magic == kMagicSwapchain ? p : nullptr; }
Space *GetSpace(XrSpace h) { auto *p = reinterpret_cast<Space *>(h); return IsLiveHandle(p) && p->magic == kMagicSpace ? p : nullptr; }
ActionSet *GetActionSet(XrActionSet h) { auto *p = reinterpret_cast<ActionSet *>(h); return IsLiveHandle(p) && p->magic == kMagicActionSet ? p : nullptr; }
Action *GetAction(XrAction h) { auto *p = reinterpret_cast<Action *>(h); return IsLiveHandle(p) && p->magic == kMagicAction ? p : nullptr; }

uint32_t RoleForPath(Instance *instance, XrPath path) {
  if (!instance || path == XR_NULL_PATH) return UINT32_MAX;
  auto found = instance->pathStrings.find(path);
  if (found == instance->pathStrings.end()) return UINT32_MAX;
  if(found->second=="/user/hand/left"||found->second.rfind("/user/hand/left/",0)==0)return kControllerLeft;
  if(found->second=="/user/hand/right"||found->second.rfind("/user/hand/right/",0)==0)return kControllerRight;
  return UINT32_MAX;
}

XrPath UserPathForRole(Instance *instance, uint32_t role) {
  const char *text = role == kControllerLeft ? "/user/hand/left" : "/user/hand/right";
  auto found = instance->paths.find(text);
  if (found != instance->paths.end()) return found->second;
  const XrPath path = instance->nextPath++;
  instance->paths.emplace(text, path);
  instance->pathStrings.emplace(path, text);
  return path;
}

uint64_t ButtonForBinding(const std::string &binding);

bool ActionAllowsRole(Action *action, uint32_t role) {
  if (!action || !action->set || !action->set->instance) return false;
  return action->subactionPaths.empty() ||
      std::any_of(action->subactionPaths.begin(), action->subactionPaths.end(),
          [&](XrPath path) { return RoleForPath(action->set->instance, path) == role; });
}

bool ActionHasBindingForRole(Action *action, uint32_t role) {
  if (!action || !action->set || !action->set->instance) return false;
  Instance *instance=action->set->instance;
  for(XrPath path:action->bindingPaths){
    if(RoleForPath(instance,path)!=role)continue;
    auto found=instance->pathStrings.find(path);if(found==instance->pathStrings.end())continue;
    const std::string&name=found->second;
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT&&ButtonForBinding(name)!=0)return true;
    if(action->type==XR_ACTION_TYPE_FLOAT_INPUT&&
        (name.find("/input/trigger/value")!=std::string::npos||name.find("/input/squeeze/value")!=std::string::npos||name.find("/input/grip/value")!=std::string::npos||ButtonForBinding(name)!=0))return true;
    if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT&&name.find("/input/thumbstick")!=std::string::npos)return true;
    if(action->type==XR_ACTION_TYPE_POSE_INPUT&&name.find("/pose")!=std::string::npos)return true;
    if(action->type==XR_ACTION_TYPE_VIBRATION_OUTPUT&&name.find("/output/haptic")!=std::string::npos)return true;
  }
  return false;
}

uint32_t ActionRole(Action *action) {
  if (!action || !action->set || !action->set->instance) return UINT32_MAX;
  Instance *instance = action->set->instance;
  for (XrPath path : action->bindingPaths) {
    uint32_t role = RoleForPath(instance, path);
    if (role != UINT32_MAX) return role;
  }
  for (XrPath path : action->subactionPaths) {
    uint32_t role = RoleForPath(instance, path);
    if (role != UINT32_MAX) return role;
  }
  return UINT32_MAX;
}

bool ActionSetIsActive(Session *session,ActionSet *set) {
  if(!session||!set||!session->actionSetsAttached)return false;
  const XrActionSet handle=reinterpret_cast<XrActionSet>(set);
  return std::find(session->activeActionSets.begin(),session->activeActionSets.end(),handle)!=session->activeActionSets.end();
}

uint64_t ButtonForBinding(const std::string &binding) {
  if(binding.find("/input/a/click")!=std::string::npos||binding.find("/input/primary/click")!=std::string::npos)return 1ull<<0;
  if(binding.find("/input/b/click")!=std::string::npos||binding.find("/input/secondary/click")!=std::string::npos)return 1ull<<1;
  if(binding.find("/input/menu/click")!=std::string::npos)return 1ull<<2;
  if(binding.find("/input/thumbstick/click")!=std::string::npos)return 1ull<<3;
  if(binding.find("/input/trigger/click")!=std::string::npos)return 1ull<<4;
  if(binding.find("/input/squeeze/click")!=std::string::npos||binding.find("/input/grip/click")!=std::string::npos)return 1ull<<5;
  if(binding.find("/input/trigger/touch")!=std::string::npos)return 1ull<<6;
  if(binding.find("/input/squeeze/touch")!=std::string::npos||binding.find("/input/grip/touch")!=std::string::npos)return 1ull<<7;
  return 0;
}

ActionValue SampleAction(Action *action,uint32_t role,const WVRDXMTControllerV1 &controller) {
  ActionValue value{};
  value.lastChangeTime=static_cast<XrTime>(controller.timestampNanoseconds);
  if(action->type==XR_ACTION_TYPE_POSE_INPUT){value.boolean=(controller.flags&5u)==5u;return value;}
  Instance*instance=action->set->instance;
  bool hasFloatValue=false,hasVectorValue=false;
  for(XrPath bindingPath:action->bindingPaths){
    if(RoleForPath(instance,bindingPath)!=role)continue;
    auto path=instance->pathStrings.find(bindingPath);if(path==instance->pathStrings.end())continue;
    const std::string&name=path->second;
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT){
      const uint64_t bit=ButtonForBinding(name);
      if(bit)value.boolean=value.boolean||((controller.buttons&bit)!=0);
    } else if(action->type==XR_ACTION_TYPE_FLOAT_INPUT){
      float candidate=0.0f;
      if(name.find("/input/trigger/value")!=std::string::npos)candidate=controller.trigger;
      else if(name.find("/input/squeeze/value")!=std::string::npos||name.find("/input/grip/value")!=std::string::npos)candidate=controller.grip;
      else {const uint64_t bit=ButtonForBinding(name);if(bit)candidate=(controller.buttons&bit)?1.0f:0.0f;else continue;}
      if(!hasFloatValue||std::fabs(candidate)>std::fabs(value.scalar))value.scalar=candidate;
      hasFloatValue=true;
    } else if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT&&name.find("/input/thumbstick")!=std::string::npos){
      const float magnitude=controller.thumbstickX*controller.thumbstickX+controller.thumbstickY*controller.thumbstickY;
      const float current=value.vector.x*value.vector.x+value.vector.y*value.vector.y;
      if(!hasVectorValue||magnitude>current)value.vector={controller.thumbstickX,controller.thumbstickY};
      hasVectorValue=true;
    }
  }
  return value;
}

bool ControllerConnected(const WVRDXMTControllerV1 &controller){return (controller.flags&4u)!=0;}

void UpdateActionSnapshot(Action *action,uint32_t role,const WVRDXMTControllerV1 &controller) {
  ActionValue next=SampleAction(action,role,controller);auto old=action->values.find(role);
  if(old==action->values.end())next.changed=true;
  else {
    const ActionValue&previous=old->second;
    next.changed=next.boolean!=previous.boolean||next.scalar!=previous.scalar||next.vector.x!=previous.vector.x||next.vector.y!=previous.vector.y;
    if(!next.changed)next.lastChangeTime=previous.lastChangeTime;
  }
  action->values[role]=next;
}

XrTime MonotonicTimeNanoseconds() {
  return static_cast<XrTime>(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count());
}

void QueueSessionState(Session *session, XrSessionState state, XrTime time = 0) {
  std::lock_guard<std::mutex> lock(session->eventMutex);
  if (session->state == state) return;
  session->state = state;
  if (!time && (session->dxmt || session->dxmtQueue12)) {
    WVRDXMTTrackingV1 tracking{};
    if (SUCCEEDED(GetSessionTracking(session, &tracking))) time=static_cast<XrTime>(tracking.timestampNanoseconds);
  }
  constexpr size_t kSessionEventCapacity = 16;
  if (session->events.size() == kSessionEventCapacity) session->events.erase(session->events.begin());
  session->events.push_back({state, time ? time : MonotonicTimeNanoseconds()});
}

bool ObserveSessionExitRequest(Session *session) {
  if (!session || (!session->dxmt && !session->dxmtQueue12)) return false;
  WVRDXMTTrackingV1 tracking{};
  if (FAILED(GetSessionTracking(session, &tracking))) return false;
  if ((tracking.flags & WVRDXMTDevicePoseSessionExitRequested) != 0) {
    if (!session->exitRequested) {
      session->exitRequested = true;
      QueueSessionState(session, session->begun ? XR_SESSION_STATE_STOPPING : XR_SESSION_STATE_EXITING,
                        static_cast<XrTime>(tracking.timestampNanoseconds));
    }
    return true;
  }
  if (!session->begun || session->exitRequested || session->state == XR_SESSION_STATE_LOSS_PENDING) return session->exitRequested;
  WVRDXMTTargetInfoV1 targets{};
  const bool visible = SUCCEEDED(GetSessionTargets(session, &targets)) &&
      targets.width[0] != 0 && targets.width[1] != 0 && targets.height[0] != 0 && targets.height[1] != 0;
  const bool focused = visible && (tracking.flags & 1u) != 0;
  if (!focused && session->state == XR_SESSION_STATE_FOCUSED) QueueSessionState(session, XR_SESSION_STATE_VISIBLE);
  if (!visible && session->state != XR_SESSION_STATE_SYNCHRONIZED) QueueSessionState(session, XR_SESSION_STATE_SYNCHRONIZED);
  if (visible && session->state == XR_SESSION_STATE_SYNCHRONIZED) QueueSessionState(session, XR_SESSION_STATE_VISIBLE);
  if (focused && session->state != XR_SESSION_STATE_FOCUSED) QueueSessionState(session, XR_SESSION_STATE_FOCUSED);
  return false;
}

// D3D12 is optional. A static d3d12.dll import would prevent the same XR DLL
// from loading in an otherwise complete D3D11-only Wine package.
HRESULT CreateOptionalD3D12Device(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID iid, void **out) {
  if (!out) return E_POINTER;
  *out = nullptr;
  using CreateDeviceFunction = HRESULT (WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
  static std::once_flag once;
  static HMODULE module = nullptr;
  static CreateDeviceFunction createDevice = nullptr;
  std::call_once(once, [] {
    module = LoadLibraryExW(L"d3d12.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module) createDevice = reinterpret_cast<CreateDeviceFunction>(GetProcAddress(module, "D3D12CreateDevice"));
  });
  return createDevice ? createDevice(adapter, level, iid, out) : E_NOINTERFACE;
}

bool SupportsD3D12FeatureLevel(ID3D12Device *device, D3D_FEATURE_LEVEL minimum) {
  D3D12_FEATURE_DATA_FEATURE_LEVELS levels{};
  levels.NumFeatureLevels = 1;
  levels.pFeatureLevelsRequested = &minimum;
  return device && SUCCEEDED(device->CheckFeatureSupport(D3D12_FEATURE_FEATURE_LEVELS, &levels, sizeof(levels))) &&
      levels.MaxSupportedFeatureLevel >= minimum;
}

bool ValidTargets(const WVRDXMTTargetInfoV1 &targets) {
  return targets.width[0] && targets.height[0] && targets.width[1] &&
      targets.height[1] && targets.generation;
}

bool QueryTargets(WVRDXMTTargetInfoV1 &targets, bool &d3d12Available) {
  // Query both backends; retain D3D11 as the preferred target source while
  // independently establishing whether the D3D12 queue extension is present.
  WVRDXMTTargetInfoV1 targets11{};
  WVRDXMTTargetInfoV1 targets12{};
  bool d3d11Available=false;
  d3d12Available=false;
  ID3D11Device *device11=nullptr;
  ID3D11DeviceContext *context11=nullptr;
  D3D_FEATURE_LEVEL feature11{};
  if(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,
      D3D11_SDK_VERSION,&device11,&feature11,&context11)) && device11 && context11) {
    IMTLD3D11ContextExt2 *extension11=nullptr;
    if(SUCCEEDED(context11->QueryInterface(kIIDMTLD3D11ContextExt2,
        reinterpret_cast<void**>(&extension11))) && extension11) {
      d3d11Available=SUCCEEDED(extension11->GetWindowsVRTargets(&targets11)) && ValidTargets(targets11);
      extension11->Release();
    }
    context11->Release();
    device11->Release();
  } else {
    if(context11) context11->Release();
    if(device11) device11->Release();
  }

  ID3D12Device *device12=nullptr;
  ID3D12CommandQueue *queue12=nullptr;
  IMTLD3D12CommandQueueExt *extension12=nullptr;
  const char *selectedGraphics=std::getenv("WVR_GRAPHICS_API");
  const bool discoverD3D12=!selectedGraphics||std::strcmp(selectedGraphics,"direct3D12")==0;
  if(discoverD3D12&&SUCCEEDED(CreateOptionalD3D12Device(nullptr,D3D_FEATURE_LEVEL_11_0,
      IID_PPV_ARGS(&device12))) && device12) {
    D3D12_COMMAND_QUEUE_DESC desc{};
    desc.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
    if(SUCCEEDED(device12->CreateCommandQueue(&desc,IID_PPV_ARGS(&queue12))) && queue12 &&
       SUCCEEDED(queue12->QueryInterface(kIIDMTLD3D12CommandQueueExt,
           reinterpret_cast<void**>(&extension12))) && extension12) {
      d3d12Available=SUCCEEDED(extension12->GetWindowsVRTargets(&targets12)) && ValidTargets(targets12);
    }
  }
  if(extension12) extension12->Release();
  if(queue12) queue12->Release();
  if(device12) device12->Release();
  if(d3d11Available) targets=targets11;
  else if(d3d12Available) targets=targets12;
  return d3d11Available || d3d12Available;
}

XrResult EnumerateOne(const void *value, uint32_t cap, uint32_t *count, void *out, size_t itemSize) {
  if (!count) return XR_ERROR_VALIDATION_FAILURE;
  *count = 1;
  if (cap == 0) return XR_SUCCESS;
  if (!out) return XR_ERROR_VALIDATION_FAILURE;
  std::memcpy(out, value, itemSize);
  return cap < 1 ? XR_ERROR_SIZE_INSUFFICIENT : XR_SUCCESS;
}

DXGI_FORMAT FormatForMetal(uint32_t format) {
  // MTLPixelFormatBGRA8Unorm and MTLPixelFormatRGBA8Unorm raw values.
  if (format == 80) return DXGI_FORMAT_B8G8R8A8_UNORM;
  if (format == 81) return DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
  if (format == 70) return DXGI_FORMAT_R8G8B8A8_UNORM;
  if (format == 71) return DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
  return DXGI_FORMAT_UNKNOWN;
}

XrQuaternionf QuaternionFromMatrix(const float *m) {
  XrQuaternionf q{};
  const float trace = m[0] + m[5] + m[10];
  if (trace > 0.0f) {
    const float s = std::sqrt(trace + 1.0f) * 2.0f;
    q.w = 0.25f * s; q.x = (m[6] - m[9]) / s; q.y = (m[8] - m[2]) / s; q.z = (m[1] - m[4]) / s;
  } else if (m[0] > m[5] && m[0] > m[10]) {
    const float s = std::sqrt(1.0f + m[0] - m[5] - m[10]) * 2.0f;
    q.w = (m[6] - m[9]) / s; q.x = 0.25f * s; q.y = (m[4] + m[1]) / s; q.z = (m[8] + m[2]) / s;
  } else if (m[5] > m[10]) {
    const float s = std::sqrt(1.0f + m[5] - m[0] - m[10]) * 2.0f;
    q.w = (m[8] - m[2]) / s; q.x = (m[4] + m[1]) / s; q.y = 0.25f * s; q.z = (m[9] + m[6]) / s;
  } else {
    const float s = std::sqrt(1.0f + m[10] - m[0] - m[5]) * 2.0f;
    q.w = (m[1] - m[4]) / s; q.x = (m[8] + m[2]) / s; q.y = (m[9] + m[6]) / s; q.z = 0.25f * s;
  }
  return q;
}

XrPosef PoseFromMatrix(const float *m) {
  XrPosef p{};
  p.orientation = QuaternionFromMatrix(m);
  p.position = {m[12], m[13], m[14]};
  return p;
}

void MultiplyColumnMajor(const float *a, const float *b, float *out) {
  for (int c=0;c<4;c++) for (int r=0;r<4;r++) {
    out[c*4+r] = 0;
    for (int k=0;k<4;k++) out[c*4+r] += a[k*4+r] * b[c*4+k];
  }
}

void MatrixFromPose(const XrPosef &pose, float *m) {
  const float x=pose.orientation.x,y=pose.orientation.y,z=pose.orientation.z,w=pose.orientation.w;
  const float xx=x*x, yy=y*y, zz=z*z, xy=x*y, xz=x*z, yz=y*z, wx=w*x, wy=w*y, wz=w*z;
  const float rowMajor[16]={1-2*(yy+zz),2*(xy-wz),2*(xz+wy),pose.position.x,
      2*(xy+wz),1-2*(xx+zz),2*(yz-wx),pose.position.y,
      2*(xz-wy),2*(yz+wx),1-2*(xx+yy),pose.position.z,
      0,0,0,1};
  for(int row=0;row<4;row++)for(int column=0;column<4;column++)m[column*4+row]=rowMajor[row*4+column];
}

void InvertRigid(const float *m,float *out) {
  for(int c=0;c<3;c++)for(int r=0;r<3;r++)out[c*4+r]=m[r*4+c];
  out[3]=out[7]=out[11]=0;out[15]=1;
  for(int r=0;r<3;r++)out[12+r]=-(out[r]*m[12]+out[4+r]*m[13]+out[8+r]*m[14]);
}

XrPosef ComposePose(const XrPosef &a,const XrPosef &b) {
  float am[16],bm[16],result[16];MatrixFromPose(a,am);MatrixFromPose(b,bm);MultiplyColumnMajor(am,bm,result);return PoseFromMatrix(result);
}

XrPosef RelativePose(const XrPosef &originFromSpace,const XrPosef &originFromBase) {
  float base[16],space[16],inverse[16],relative[16];MatrixFromPose(originFromBase,base);MatrixFromPose(originFromSpace,space);InvertRigid(base,inverse);MultiplyColumnMajor(inverse,space,relative);return PoseFromMatrix(relative);
}

bool OriginFromSpace(Session *session,Space *space,const WVRDXMTTrackingV1 &tracking,XrPosef &pose,uint32_t &flags) {
  flags=0;
  if(space->action!=XR_NULL_HANDLE){
    Action*action=GetAction(space->action);if(!action)return false;
    uint32_t role=space->subactionPath==XR_NULL_PATH?ActionRole(action):RoleForPath(session->instance,space->subactionPath);
    if(role==UINT32_MAX||!ActionAllowsRole(action,role)||!ActionHasBindingForRole(action,role)||!ActionSetIsActive(session,action->set))return false;
    auto activePath=session->activeSetSubactions.find(reinterpret_cast<XrActionSet>(action->set));
    if(activePath!=session->activeSetSubactions.end()&&activePath->second!=XR_NULL_PATH&&RoleForPath(session->instance,activePath->second)!=role)return false;
    WVRDXMTControllerV1 controller{};
    if(FAILED(GetSessionController(session, role, &controller))||(controller.flags&5u)!=5u)return false;
    pose=ComposePose(PoseFromMatrix(controller.originFromController),space->poseInActionSpace);
  } else {
    if((tracking.flags&1u)==0)return false;
    XrPosef origin{{0,0,0,1},{0,0,0}};
    if(space->type==XR_REFERENCE_SPACE_TYPE_VIEW)origin=PoseFromMatrix(tracking.originFromDevice);
    pose=ComposePose(origin,space->poseInReferenceSpace);
  }
  flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|
        XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
  return true;
}

XrResult XRAPI_CALL EnumerateInstanceExtensionProperties(const char *layerName, uint32_t cap, uint32_t *count, XrExtensionProperties *out) {
  if (layerName && layerName[0] != '\0') return XR_ERROR_API_LAYER_NOT_PRESENT;
  if (!count) return XR_ERROR_VALIDATION_FAILURE;
  WVRDXMTTargetInfoV1 targets{};
  bool d3d12Available=false;
  (void)QueryTargets(targets,d3d12Available);
  const uint32_t extensionCount=d3d12Available?2u:1u;
  *count=extensionCount;
  if (cap==0) return XR_SUCCESS;
  if (!out) return XR_ERROR_VALIDATION_FAILURE;
  const char *names[2]={XR_KHR_D3D11_ENABLE_EXTENSION_NAME,XR_KHR_D3D12_ENABLE_EXTENSION_NAME};
  const uint32_t versions[2]={XR_KHR_D3D11_enable_SPEC_VERSION,XR_KHR_D3D12_enable_SPEC_VERSION};
  const uint32_t written=std::min(cap,extensionCount);
  for(uint32_t n=0;n<written;n++) {
    if(out[n].type!=XR_TYPE_EXTENSION_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    std::strncpy(out[n].extensionName,names[n],XR_MAX_EXTENSION_NAME_SIZE-1);
    out[n].extensionVersion=versions[n];
  }
  return cap<extensionCount?XR_ERROR_SIZE_INSUFFICIENT:XR_SUCCESS;
}
XrResult XRAPI_CALL EnumerateApiLayerProperties(uint32_t, uint32_t *count, XrApiLayerProperties *) { if (!count) return XR_ERROR_VALIDATION_FAILURE; *count=0; return XR_SUCCESS; }
XrResult XRAPI_CALL CreateInstance(const XrInstanceCreateInfo *info, XrInstance *out) {
  if (!info || !out || info->type != XR_TYPE_INSTANCE_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
  if(info->enabledApiLayerCount!=0)return XR_ERROR_API_LAYER_NOT_PRESENT;
  if (XR_VERSION_MAJOR(info->applicationInfo.apiVersion) != 1 ||
      (XR_VERSION_MAJOR(info->applicationInfo.apiVersion) == 1 && XR_VERSION_MINOR(info->applicationInfo.apiVersion) > 0))
    return XR_ERROR_API_VERSION_UNSUPPORTED;
  bool d3d11Enabled = false;
  bool d3d12Enabled = false;
  for (uint32_t i=0;i<info->enabledExtensionCount;i++) {
    if (!info->enabledExtensionNames || !info->enabledExtensionNames[i]) return XR_ERROR_VALIDATION_FAILURE;
    if (std::strcmp(info->enabledExtensionNames[i], XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0) d3d11Enabled = true;
    else if (std::strcmp(info->enabledExtensionNames[i], XR_KHR_D3D12_ENABLE_EXTENSION_NAME) == 0) d3d12Enabled = true;
    else return XR_ERROR_EXTENSION_NOT_PRESENT;
  }
  auto p=std::make_unique<Instance>();
  p->d3d11Enabled = d3d11Enabled;
  p->d3d12Enabled = d3d12Enabled;
  std::strncpy(p->properties.runtimeName,"AVP Play Windows VR",XR_MAX_RUNTIME_NAME_SIZE-1);
  p->properties.runtimeVersion=XR_MAKE_VERSION(0,1,0);
  if (!QueryTargets(p->targets,p->d3d12BackendAvailable)) return XR_ERROR_RUNTIME_FAILURE;
  if(d3d12Enabled&&!p->d3d12BackendAvailable)return XR_ERROR_EXTENSION_NOT_PRESENT;
  Instance *raw=p.get(); { std::lock_guard<std::mutex> l(g_mutex); g_instances.push_back(std::move(p)); } RegisterHandle(raw);
  *out=reinterpret_cast<XrInstance>(raw); return XR_SUCCESS;
}
XrResult XRAPI_CALL DestroyInstance(XrInstance h) {
  auto *p=GetInstance(h); if(!p) return XR_ERROR_HANDLE_INVALID;
  std::lock_guard<std::mutex> l(g_mutex);
  if(std::any_of(g_sessions.begin(),g_sessions.end(),[p](const auto&session){return session->instance==p;}))return XR_ERROR_CALL_ORDER_INVALID;
  for(auto&action:p->actions){UnregisterHandle(action.get());action->magic=0;}
  for(auto&set:p->actionSets){UnregisterHandle(set.get());set->magic=0;}
  UnregisterHandle(p);p->magic=0;
  g_instances.erase(std::remove_if(g_instances.begin(),g_instances.end(),[p](auto &x){return x.get()==p;}),g_instances.end()); return XR_SUCCESS;
}
XrResult XRAPI_CALL GetInstanceProperties(XrInstance h, XrInstanceProperties *out) {
  auto *p=GetInstance(h);
  if(!p) return XR_ERROR_HANDLE_INVALID;
  if(!out || out->type != XR_TYPE_INSTANCE_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
  // These are the only output fields defined by XrInstanceProperties. Preserve
  // the caller's type and any recognized output-chain storage.
  std::memcpy(out->runtimeName, p->properties.runtimeName, XR_MAX_RUNTIME_NAME_SIZE);
  out->runtimeVersion = p->properties.runtimeVersion;
  return XR_SUCCESS;
}
XrResult XRAPI_CALL GetSystem(XrInstance h,const XrSystemGetInfo *info,XrSystemId *out) { auto *p=GetInstance(h); if(!p||!info||!out||info->formFactor!=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) return XR_ERROR_FORM_FACTOR_UNSUPPORTED; *out=p->system; return XR_SUCCESS; }
XrResult XRAPI_CALL GetSystemProperties(XrInstance h,XrSystemId sys,XrSystemProperties *out) { auto *p=GetInstance(h); if(!p||sys!=p->system) return XR_ERROR_SYSTEM_INVALID;if(!out||out->type!=XR_TYPE_SYSTEM_PROPERTIES)return XR_ERROR_VALIDATION_FAILURE;out->systemId=sys;out->vendorId=0x415650;std::strncpy(out->systemName,"Windows VR Headset",XR_MAX_SYSTEM_NAME_SIZE-1);out->graphicsProperties.maxSwapchainImageHeight=static_cast<uint32_t>(std::min<uint64_t>(16384,2ull*std::max(p->targets.height[0],p->targets.height[1])));out->graphicsProperties.maxSwapchainImageWidth=static_cast<uint32_t>(std::min<uint64_t>(16384,2ull*std::max(p->targets.width[0],p->targets.width[1])));out->graphicsProperties.maxLayerCount=1;out->trackingProperties.orientationTracking=XR_TRUE;out->trackingProperties.positionTracking=XR_TRUE;return XR_SUCCESS; }
XrResult XRAPI_CALL EnumerateViewConfigurations(XrInstance h,XrSystemId sys,uint32_t cap,uint32_t *count,XrViewConfigurationType *out) { auto*p=GetInstance(h); if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID; XrViewConfigurationType t=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO; return EnumerateOne(&t,cap,count,out,sizeof(t)); }
XrResult XRAPI_CALL GetViewConfigurationProperties(XrInstance h,XrSystemId sys,XrViewConfigurationType type,XrViewConfigurationProperties*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;if(!out||out->type!=XR_TYPE_VIEW_CONFIGURATION_PROPERTIES)return XR_ERROR_VALIDATION_FAILURE;out->viewConfigurationType=type;out->fovMutable=XR_FALSE;return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateViewConfigurationViews(XrInstance h,XrSystemId sys,XrViewConfigurationType type,uint32_t cap,uint32_t*count,XrViewConfigurationView*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO||!count)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;*count=2;if(cap==0)return XR_SUCCESS;if(cap<2)return XR_ERROR_SIZE_INSUFFICIENT;if(!out)return XR_ERROR_VALIDATION_FAILURE;for(uint32_t i=0;i<2;i++){if(out[i].type!=XR_TYPE_VIEW_CONFIGURATION_VIEW)return XR_ERROR_VALIDATION_FAILURE;out[i].recommendedImageRectWidth=p->targets.width[i];out[i].maxImageRectWidth=p->targets.width[i];out[i].recommendedImageRectHeight=p->targets.height[i];out[i].maxImageRectHeight=p->targets.height[i];out[i].recommendedSwapchainSampleCount=1;out[i].maxSwapchainSampleCount=1;}return XR_SUCCESS;}

XrResult XRAPI_CALL CreateSession(XrInstance ih,const XrSessionCreateInfo *info,XrSession*out){
  auto*i=GetInstance(ih);
  if(!i||!info||!out||info->type!=XR_TYPE_SESSION_CREATE_INFO||info->systemId!=i->system)return XR_ERROR_SYSTEM_INVALID;
  if(!info->next)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
  const auto *bindingHeader=static_cast<const XrBaseInStructure*>(info->next);
  {std::lock_guard<std::mutex>lock(g_mutex);if(!g_sessions.empty())return XR_ERROR_LIMIT_REACHED;}

  if(bindingHeader->type==XR_TYPE_GRAPHICS_BINDING_D3D11_KHR){
    if(!i->d3d11Enabled)return XR_ERROR_EXTENSION_NOT_PRESENT;
    if(!i->graphicsRequirementsQueried)return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    const auto *binding=reinterpret_cast<const XrGraphicsBindingD3D11KHR*>(bindingHeader);
    if(!binding->device||binding->device->GetFeatureLevel()<D3D_FEATURE_LEVEL_11_0)
      return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    ID3D11DeviceContext*context=nullptr;
    binding->device->GetImmediateContext(&context);
    if(!context)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    IMTLD3D11ContextExt2*ext=nullptr;
    if(FAILED(context->QueryInterface(kIIDMTLD3D11ContextExt2,reinterpret_cast<void**>(&ext)))){
      context->Release();return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    IMTLD3D11ContextExt3*ext3=nullptr;
    (void)context->QueryInterface(kIIDMTLD3D11ContextExt3,reinterpret_cast<void**>(&ext3));
    WVRDXMTTargetInfoV1 currentTargets{};
    if(FAILED(ext->GetWindowsVRTargets(&currentTargets))||
       currentTargets.generation!=i->targets.generation){
      if(ext3)ext3->Release();ext->Release();context->Release();return XR_ERROR_RUNTIME_FAILURE;
    }
    auto s=std::make_unique<Session>();
    s->instance=i;s->device=binding->device;s->device->AddRef();s->context=context;s->dxmt=ext;s->dxmtExt3=ext3;
    Session*raw=s.get();QueueSessionState(raw,XR_SESSION_STATE_READY);
    {std::lock_guard<std::mutex>l(g_mutex);g_sessions.push_back(std::move(s));}
    RegisterHandle(raw);*out=reinterpret_cast<XrSession>(raw);return XR_SUCCESS;
  }

  if(bindingHeader->type==XR_TYPE_GRAPHICS_BINDING_D3D12_KHR){
    if(!i->d3d12Enabled)return XR_ERROR_EXTENSION_NOT_PRESENT;
    if(!i->d3d12GraphicsRequirementsQueried)return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    const auto *binding=reinterpret_cast<const XrGraphicsBindingD3D12KHR*>(bindingHeader);
    if(binding->next||!binding->device||!binding->queue)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    const LUID deviceAdapterLuid=binding->device->GetAdapterLuid();
    if(!SupportsD3D12FeatureLevel(binding->device,i->d3d12MinFeatureLevel)||
       deviceAdapterLuid.LowPart!=i->d3d12AdapterLuid.LowPart||
       deviceAdapterLuid.HighPart!=i->d3d12AdapterLuid.HighPart)
      return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    const D3D12_COMMAND_QUEUE_DESC queueDesc=binding->queue->GetDesc();
    if(queueDesc.Type!=D3D12_COMMAND_LIST_TYPE_DIRECT||(queueDesc.NodeMask!=0&&queueDesc.NodeMask!=1))return XR_ERROR_GRAPHICS_DEVICE_INVALID;

    ID3D12Device*queueDevice=nullptr;
    if(FAILED(binding->queue->GetDevice(IID_PPV_ARGS(&queueDevice)))||!queueDevice)
      return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    IUnknown*deviceIdentity=nullptr;
    IUnknown*queueDeviceIdentity=nullptr;
    const bool identitiesAvailable=
        SUCCEEDED(binding->device->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(&deviceIdentity)))&&deviceIdentity&&
        SUCCEEDED(queueDevice->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(&queueDeviceIdentity)))&&queueDeviceIdentity;
    const bool sameDevice=identitiesAvailable&&deviceIdentity==queueDeviceIdentity;
    if(deviceIdentity)deviceIdentity->Release();
    if(queueDeviceIdentity)queueDeviceIdentity->Release();
    queueDevice->Release();
    if(!sameDevice)return XR_ERROR_GRAPHICS_DEVICE_INVALID;

    IMTLD3D12CommandQueueExt*ext=nullptr;
    if(FAILED(binding->queue->QueryInterface(kIIDMTLD3D12CommandQueueExt,reinterpret_cast<void**>(&ext)))||!ext)
      return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    WVRDXMTTargetInfoV1 currentTargets{};
    if(FAILED(ext->GetWindowsVRTargets(&currentTargets))||
       currentTargets.generation!=i->targets.generation){ext->Release();return XR_ERROR_RUNTIME_FAILURE;}
    auto s=std::make_unique<Session>();
    s->instance=i;s->device12=binding->device;s->device12->AddRef();
    s->queue12=binding->queue;s->queue12->AddRef();s->dxmtQueue12=ext;s->d3d12=true;
    Session*raw=s.get();QueueSessionState(raw,XR_SESSION_STATE_READY);
    {std::lock_guard<std::mutex>l(g_mutex);g_sessions.push_back(std::move(s));}
    RegisterHandle(raw);*out=reinterpret_cast<XrSession>(raw);return XR_SUCCESS;
  }
  return XR_ERROR_GRAPHICS_DEVICE_INVALID;
}
XrResult XRAPI_CALL DestroySession(XrSession h){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(s->begun)return XR_ERROR_SESSION_RUNNING;
  if(!s->swapchains.empty())return XR_ERROR_CALL_ORDER_INVALID;
  std::lock_guard<std::mutex>l(g_mutex);
  for(auto it=g_spaces.begin();it!=g_spaces.end();){
    if((*it)->session==s){UnregisterHandle(it->get());(*it)->magic=0;it=g_spaces.erase(it);}else ++it;
  }
  UnregisterHandle(s);s->magic=0;
  if(s->dxmtExt3)s->dxmtExt3->Release();
  if(s->dxmtQueue12)s->dxmtQueue12->Release();
  if(s->dxmt)s->dxmt->Release();
  if(s->context)s->context->Release();
  if(s->device)s->device->Release();
  if(s->queue12)s->queue12->Release();
  if(s->device12)s->device12->Release();
  g_sessions.erase(std::remove_if(g_sessions.begin(),g_sessions.end(),[s](auto&x){return x.get()==s;}),g_sessions.end());
  return XR_SUCCESS;
}
XrResult XRAPI_CALL BeginSession(XrSession h,const XrSessionBeginInfo*info){auto*s=GetSession(h);if(!s||!info)return XR_ERROR_HANDLE_INVALID;if(info->type!=XR_TYPE_SESSION_BEGIN_INFO)return XR_ERROR_VALIDATION_FAILURE;if(info->primaryViewConfigurationType!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;if(s->begun||s->state!=XR_SESSION_STATE_READY||s->exitRequested)return XR_ERROR_SESSION_NOT_READY;s->begun=true;QueueSessionState(s,XR_SESSION_STATE_SYNCHRONIZED);QueueSessionState(s,XR_SESSION_STATE_VISIBLE);return XR_SUCCESS;}
XrResult XRAPI_CALL EndSession(XrSession h){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;if(!s->begun)return XR_ERROR_SESSION_NOT_RUNNING;s->begun=false;s->frameWaited=false;if(s->exitRequested){QueueSessionState(s,XR_SESSION_STATE_EXITING);}else{if(s->state!=XR_SESSION_STATE_STOPPING)QueueSessionState(s,XR_SESSION_STATE_STOPPING);QueueSessionState(s,XR_SESSION_STATE_IDLE);QueueSessionState(s,XR_SESSION_STATE_READY);}return XR_SUCCESS;}
XrResult XRAPI_CALL RequestExitSession(XrSession h){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!s->begun)return XR_ERROR_SESSION_NOT_RUNNING;if(s->exitRequested)return XR_ERROR_CALL_ORDER_INVALID;s->exitRequested=true;QueueSessionState(s,XR_SESSION_STATE_STOPPING);return XR_SUCCESS;}
XrResult XRAPI_CALL CreateReferenceSpace(XrSession h,const XrReferenceSpaceCreateInfo*info,XrSpace*out){auto*s=GetSession(h);if(!s||!info||!out)return XR_ERROR_HANDLE_INVALID;if(info->type!=XR_TYPE_REFERENCE_SPACE_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;if(info->referenceSpaceType!=XR_REFERENCE_SPACE_TYPE_LOCAL&&info->referenceSpaceType!=XR_REFERENCE_SPACE_TYPE_VIEW)return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;auto p=std::make_unique<Space>();p->session=s;p->type=info->referenceSpaceType;p->poseInReferenceSpace=info->poseInReferenceSpace;Space*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_spaces.push_back(std::move(p));}RegisterHandle(raw);*out=reinterpret_cast<XrSpace>(raw);return XR_SUCCESS;}
XrResult XRAPI_CALL DestroySpace(XrSpace h){auto*p=GetSpace(h);if(!p)return XR_ERROR_HANDLE_INVALID;std::lock_guard<std::mutex>l(g_mutex);UnregisterHandle(p);p->magic=0;g_spaces.erase(std::remove_if(g_spaces.begin(),g_spaces.end(),[p](auto&x){return x.get()==p;}),g_spaces.end());return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateSwapchainFormats(XrSession h,uint32_t cap,uint32_t*count,int64_t*out){auto*s=GetSession(h);if(!s||!count)return XR_ERROR_HANDLE_INVALID;DXGI_FORMAT f=FormatForMetal(s->instance->targets.pixelFormat[0]);if(f==DXGI_FORMAT_UNKNOWN)return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;int64_t fmt=f;return EnumerateOne(&fmt,cap,count,out,sizeof(fmt));}
XrResult XRAPI_CALL CreateSwapchain(XrSession h,const XrSwapchainCreateInfo*info,XrSwapchain*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||!out||info->type!=XR_TYPE_SWAPCHAIN_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;
  const XrSwapchainCreateFlags supportedFlags=XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT;
  const XrSwapchainUsageFlags supportedUsage=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT|
      XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT|XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
  if(info->next||(info->usageFlags&~supportedUsage)!=0||
     (info->createFlags&~supportedFlags)!=0||info->arraySize==0||info->arraySize>16||
     info->faceCount!=1||info->mipCount!=1||info->sampleCount!=1||
     !(info->usageFlags&XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT))return XR_ERROR_FEATURE_UNSUPPORTED;
  DXGI_FORMAT format=FormatForMetal(s->instance->targets.pixelFormat[0]);
  if(format==DXGI_FORMAT_UNKNOWN||info->format!=format)return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
  WVRDXMTTargetInfoV1 targets{};
  if(FAILED(GetSessionTargets(s, &targets))||targets.generation!=s->instance->targets.generation)return XR_ERROR_RUNTIME_FAILURE;
  const uint64_t maximumWidth=std::min<uint64_t>(16384,2ull*std::max(targets.width[0],targets.width[1]));
  const uint64_t maximumHeight=std::min<uint64_t>(16384,2ull*std::max(targets.height[0],targets.height[1]));
  if(info->width==0||info->height==0||info->width>maximumWidth||info->height>maximumHeight)return XR_ERROR_SWAPCHAIN_RECT_INVALID;
  if(!s->d3d12&&!s->dxmtExt3&&(info->arraySize!=1||
     !((info->width==targets.width[0]&&info->height==targets.height[0])||
       (info->width==targets.width[1]&&info->height==targets.height[1]))))return XR_ERROR_FEATURE_UNSUPPORTED;
  auto p=std::make_unique<Swapchain>();p->session=s;p->info=*info;p->targetGeneration=targets.generation;
  p->images.resize((info->createFlags&XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT)?1:kImageCount);
  if(s->d3d12){
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type=D3D12_HEAP_TYPE_DEFAULT;
    heap.CreationNodeMask=1;
    heap.VisibleNodeMask=1;
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width=info->width;
    desc.Height=info->height;
    desc.DepthOrArraySize=static_cast<UINT16>(info->arraySize);
    desc.MipLevels=1;
    desc.Format=format;
    desc.SampleDesc.Count=1;
    desc.Layout=D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    for(auto&image:p->images){
      if(FAILED(s->device12->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,
          D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&image.resource12)))||!image.resource12){
        for(auto&allocated:p->images)if(allocated.resource12)allocated.resource12->Release();
        return XR_ERROR_RUNTIME_FAILURE;
      }
    }
  }else{
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width=info->width;desc.Height=info->height;desc.MipLevels=1;desc.ArraySize=info->arraySize;
    desc.Format=format;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;
    desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    for(auto&image:p->images){
      if(FAILED(s->device->CreateTexture2D(&desc,nullptr,&image.texture11))||!image.texture11){
        for(auto&allocated:p->images)if(allocated.texture11)allocated.texture11->Release();
        return XR_ERROR_RUNTIME_FAILURE;
      }
    }
  }
  Swapchain*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_swapchains.push_back(std::move(p));s->swapchains.push_back(raw);}
  RegisterHandle(raw);*out=reinterpret_cast<XrSwapchain>(raw);return XR_SUCCESS;
}

XrResult XRAPI_CALL DestroySwapchain(XrSwapchain h){
  auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;
  for(auto&i:p->images)if(i.acquired)return XR_ERROR_CALL_ORDER_INVALID;
  for(auto&i:p->images){
    if(p->session->d3d12&&i.releaseOrder==0)continue;
    if(FAILED(WaitSessionImage(p->session,i)))return XR_ERROR_RUNTIME_FAILURE;
  }
  std::lock_guard<std::mutex>l(g_mutex);
  for(auto&i:p->images){if(i.texture11)i.texture11->Release();if(i.resource12)i.resource12->Release();}
  UnregisterHandle(p);p->magic=0;auto*s=p->session;
  if(s)s->swapchains.erase(std::remove(s->swapchains.begin(),s->swapchains.end(),p),s->swapchains.end());
  g_swapchains.erase(std::remove_if(g_swapchains.begin(),g_swapchains.end(),[p](auto&x){return x.get()==p;}),g_swapchains.end());
  return XR_SUCCESS;
}
XrResult XRAPI_CALL EnumerateSwapchainImages(XrSwapchain h,uint32_t cap,uint32_t*count,XrSwapchainImageBaseHeader*out){
  auto*p=GetSwapchain(h);if(!p||!count)return XR_ERROR_HANDLE_INVALID;
  *count=static_cast<uint32_t>(p->images.size());if(cap==0)return XR_SUCCESS;
  if(cap<p->images.size())return XR_ERROR_SIZE_INSUFFICIENT;if(!out)return XR_ERROR_VALIDATION_FAILURE;
  for(uint32_t i=0;i<p->images.size();i++){
    if(p->session->d3d12){
      auto*x=reinterpret_cast<XrSwapchainImageD3D12KHR*>(reinterpret_cast<char*>(out)+i*sizeof(XrSwapchainImageD3D12KHR));
      if(x->type!=XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR)return XR_ERROR_VALIDATION_FAILURE;
      x->texture=p->images[i].resource12;
    }else{
      auto*x=reinterpret_cast<XrSwapchainImageD3D11KHR*>(reinterpret_cast<char*>(out)+i*sizeof(XrSwapchainImageD3D11KHR));
      if(x->type!=XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR)return XR_ERROR_VALIDATION_FAILURE;
      x->texture=p->images[i].texture11;
    }
  }
  return XR_SUCCESS;
}
XrResult XRAPI_CALL AcquireSwapchainImage(XrSwapchain h,const XrSwapchainImageAcquireInfo*info,uint32_t*out){auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO||!out)return XR_ERROR_VALIDATION_FAILURE;if((p->info.createFlags&XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT)&&p->staticImageAcquired)return XR_ERROR_CALL_ORDER_INVALID;for(uint32_t n=0;n<p->images.size();n++){uint32_t i=(p->nextImage+n)%p->images.size();if(!p->images[i].acquired){auto&image=p->images[i];image.acquired=true;image.waited=false;p->staticImageAcquired=true;p->acquiredImages.push_back(i);p->nextImage=(i+1)%p->images.size();*out=i;return XR_SUCCESS;}}return XR_ERROR_CALL_ORDER_INVALID;}
XrResult XRAPI_CALL WaitSwapchainImage(XrSwapchain h,const XrSwapchainImageWaitInfo*info){
  auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO||(info->timeout<0&&info->timeout!=XR_INFINITE_DURATION))return XR_ERROR_VALIDATION_FAILURE;
  if(p->acquiredImages.empty())return XR_ERROR_CALL_ORDER_INVALID;
  auto pending=std::find_if(p->acquiredImages.begin(),p->acquiredImages.end(),[&](uint32_t index){return !p->images[index].waited;});
  if(pending==p->acquiredImages.end())return XR_ERROR_CALL_ORDER_INVALID;
  const uint32_t index=*pending;auto&image=p->images[index];
  if(!image.acquired)return XR_ERROR_CALL_ORDER_INVALID;
  if(FAILED(WaitSessionImage(p->session,image)))return XR_ERROR_RUNTIME_FAILURE;
  image.waited=true;return XR_SUCCESS;
}
XrResult XRAPI_CALL ReleaseSwapchainImage(XrSwapchain h,const XrSwapchainImageReleaseInfo*info){auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO)return XR_ERROR_VALIDATION_FAILURE;if(p->acquiredImages.empty())return XR_ERROR_CALL_ORDER_INVALID;const uint32_t index=p->acquiredImages.front();auto&image=p->images[index];if(!image.acquired||!image.waited)return XR_ERROR_CALL_ORDER_INVALID;image.acquired=false;image.waited=false;image.lastReleasedFrame=p->session->frameIndex;image.releaseOrder=p->nextReleaseOrder++;p->acquiredImages.pop_front();return XR_SUCCESS;}
XrResult XRAPI_CALL WaitFrame(XrSession h,const XrFrameWaitInfo*info,XrFrameState*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_FRAME_WAIT_INFO||!out||out->type!=XR_TYPE_FRAME_STATE)return XR_ERROR_VALIDATION_FAILURE;
  ObserveSessionExitRequest(s);
  if(!s->begun||s->exitRequested||s->state==XR_SESSION_STATE_STOPPING)return XR_ERROR_SESSION_NOT_RUNNING;
  if(s->frameWaited||s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;
  WVRDXMTTrackingV1 tracking{};
  WVRDXMTTargetInfoV1 currentTargets{};
  if (FAILED(GetSessionTargets(s, &currentTargets))) return XR_ERROR_RUNTIME_FAILURE;
  if (!currentTargets.width[0] || !currentTargets.width[1] ||
      !currentTargets.height[0] || !currentTargets.height[1]) {
    // A paused renderer cannot promise valid renderable targets.
    s->predictedTime = s->predictedTime > 0 ? s->predictedTime + 11'111'111 : MonotonicTimeNanoseconds();
    out->predictedDisplayTime = s->predictedTime;
    out->predictedDisplayPeriod = 11'111'111;
    out->shouldRender = XR_FALSE;
    s->frameWaited = true;
    s->frameIndex++;
    std::this_thread::sleep_for(std::chrono::milliseconds(11));
    return XR_SUCCESS;
  }
  if (currentTargets.generation != s->instance->targets.generation) {
    const auto &previous = s->instance->targets;
    bool sameGeometry = true;
    for (uint32_t eye = 0; eye < kViewCount; ++eye) {
      sameGeometry = sameGeometry && currentTargets.width[eye] == previous.width[eye] &&
          currentTargets.height[eye] == previous.height[eye] && currentTargets.pixelFormat[eye] == previous.pixelFormat[eye];
    }
    if (!sameGeometry) {
      s->exitRequested = true;
      QueueSessionState(s, XR_SESSION_STATE_LOSS_PENDING);
      return XR_ERROR_SESSION_LOST;
    }
    s->instance->targets = currentTargets;
    for (auto *swapchain : s->swapchains) swapchain->targetGeneration = currentTargets.generation;
    s->lastWaitTrackingTime = 0;
    s->predictedTime = 0;
  }
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::nanoseconds(kMaximumWait);
  do {
    if(FAILED(GetSessionTracking(s, &tracking)))return XR_ERROR_RUNTIME_FAILURE;
    if((tracking.flags&1u)!=0 && tracking.timestampNanoseconds>s->lastWaitTrackingTime)break;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while(std::chrono::steady_clock::now()<deadline);
  if((tracking.flags&1u)==0||tracking.timestampNanoseconds<=s->lastWaitTrackingTime){
    ObserveSessionExitRequest(s);
    if(s->exitRequested)return XR_ERROR_SESSION_NOT_RUNNING;
    const XrTime nextTime=s->predictedTime>0?s->predictedTime+11'111'111:MonotonicTimeNanoseconds();
    s->predictedTime=std::max(nextTime,static_cast<XrTime>(tracking.timestampNanoseconds));
    out->predictedDisplayTime=s->predictedTime;out->predictedDisplayPeriod=11'111'111;out->shouldRender=XR_FALSE;
    s->frameWaited=true;s->frameIndex++;return XR_SUCCESS;
  }
  // Do not compare host compositor timestamps to guest steady_clock: Wine's
  // clock epoch need not match CACurrentMediaTime. Freshness is established by
  // observing a strictly newer host timestamp within the bounded wait above.
  s->lastWaitTrackingTime=static_cast<XrTime>(tracking.timestampNanoseconds);
  const XrTime previousTime=s->predictedTime;
  s->predictedTime=std::max(s->lastWaitTrackingTime,previousTime>0?previousTime+1:s->lastWaitTrackingTime);
  s->frameIndex++;
  XrDuration period=11'111'111;
  if(previousTime>0&&s->predictedTime>previousTime){
    const XrTime observed=s->lastWaitTrackingTime-previousTime;
    if(observed>=4'000'000&&observed<=50'000'000)period=observed;
  }
  out->predictedDisplayTime=s->predictedTime;
  out->predictedDisplayPeriod=period;
  out->shouldRender=XR_TRUE;
  s->frameWaited=true;
  return XR_SUCCESS;
}
XrResult XRAPI_CALL BeginFrame(XrSession h,const XrFrameBeginInfo*info){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_FRAME_BEGIN_INFO)return XR_ERROR_VALIDATION_FAILURE;if(!s->begun||s->exitRequested||s->state==XR_SESSION_STATE_STOPPING)return XR_ERROR_SESSION_NOT_RUNNING;if(!s->frameWaited||s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;s->frameBegun=true;return XR_SUCCESS;}
XrResult XRAPI_CALL EndFrame(XrSession h,const XrFrameEndInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_FRAME_END_INFO)return XR_ERROR_VALIDATION_FAILURE;
  if(!s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;
  s->frameBegun=false;
  s->frameWaited=false;
  if(info->displayTime!=s->predictedTime)return XR_ERROR_TIME_INVALID;
  if(info->next)return XR_ERROR_FEATURE_UNSUPPORTED;
  if(info->layerCount==0)return XR_SUCCESS;
  if(info->layerCount!=1||!info->layers||info->environmentBlendMode!=XR_ENVIRONMENT_BLEND_MODE_OPAQUE)return XR_ERROR_LAYER_INVALID;
  auto*layer=reinterpret_cast<const XrCompositionLayerProjection*>(info->layers[0]);
  if(!layer||layer->type!=XR_TYPE_COMPOSITION_LAYER_PROJECTION||layer->next||layer->viewCount!=2||!layer->views)return XR_ERROR_LAYER_INVALID;
  auto*compositionSpace=GetSpace(layer->space);if(!compositionSpace||compositionSpace->session!=s)return XR_ERROR_HANDLE_INVALID;
  WVRDXMTTargetInfoV1 targets{};
  if(FAILED(GetSessionTargets(s, &targets)))return XR_ERROR_RUNTIME_FAILURE;
  
  WVRDXMTSubmitFrameV2 extended{};extended.targetGeneration=targets.generation;extended.frameID=g_frameID.fetch_add(1);extended.timestampNanoseconds=static_cast<uint64_t>(info->displayTime);
  WVRDXMTD3D12SubmitFrameV1 d3d12Frame{};
  d3d12Frame.targetGeneration=extended.targetGeneration;
  d3d12Frame.frameID=extended.frameID;
  d3d12Frame.timestampNanoseconds=extended.timestampNanoseconds;
  bool needsExt3=false;
  for(uint32_t eye=0;eye<2;eye++){
    const auto&v=layer->views[eye];
    if(v.type!=XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW||v.next)return XR_ERROR_FEATURE_UNSUPPORTED;
    auto*sw=GetSwapchain(v.subImage.swapchain);
    if(!sw||sw->session!=s||v.subImage.imageArrayIndex>=sw->info.arraySize||sw->targetGeneration!=targets.generation)return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    const auto&rect=v.subImage.imageRect;
    const int64_t rectRight=static_cast<int64_t>(rect.offset.x)+rect.extent.width;
    const int64_t rectBottom=static_cast<int64_t>(rect.offset.y)+rect.extent.height;
    if(rect.offset.x<0||rect.offset.y<0||rect.extent.width<=0||rect.extent.height<=0||
       rectRight>sw->info.width||rectBottom>sw->info.height||
       static_cast<uint32_t>(rect.extent.width)>targets.width[eye]||
       static_cast<uint32_t>(rect.extent.height)>targets.height[eye])return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    needsExt3|=sw->info.arraySize>1||rect.offset.x!=0||rect.offset.y!=0||
       rect.extent.width!=static_cast<int32_t>(sw->info.width)||rect.extent.height!=static_cast<int32_t>(sw->info.height)||
       static_cast<uint32_t>(rect.extent.width)!=targets.width[eye]||static_cast<uint32_t>(rect.extent.height)!=targets.height[eye];

    auto image=sw->images.end();
    for(auto candidate=sw->images.begin();candidate!=sw->images.end();++candidate){
      if(candidate->releaseOrder==0)continue;
      if(image==sw->images.end()||candidate->releaseOrder>image->releaseOrder)image=candidate;
    }
    if(image==sw->images.end()||image->acquired)return XR_ERROR_CALL_ORDER_INVALID;
    if(s->d3d12){
      if(!image->resource12||image->texture11)return XR_ERROR_LAYER_INVALID;
      if(eye==0){d3d12Frame.left=image->resource12;d3d12Frame.leftArraySlice=v.subImage.imageArrayIndex;d3d12Frame.leftX=static_cast<uint32_t>(rect.offset.x);d3d12Frame.leftY=static_cast<uint32_t>(rect.offset.y);d3d12Frame.leftWidth=static_cast<uint32_t>(rect.extent.width);d3d12Frame.leftHeight=static_cast<uint32_t>(rect.extent.height);}
      else{d3d12Frame.right=image->resource12;d3d12Frame.rightArraySlice=v.subImage.imageArrayIndex;d3d12Frame.rightX=static_cast<uint32_t>(rect.offset.x);d3d12Frame.rightY=static_cast<uint32_t>(rect.offset.y);d3d12Frame.rightWidth=static_cast<uint32_t>(rect.extent.width);d3d12Frame.rightHeight=static_cast<uint32_t>(rect.extent.height);}
    }else{
      if(!image->texture11||image->resource12)return XR_ERROR_LAYER_INVALID;
      if(eye==0){extended.left=image->texture11;extended.leftArraySlice=v.subImage.imageArrayIndex;extended.leftX=static_cast<uint32_t>(rect.offset.x);extended.leftY=static_cast<uint32_t>(rect.offset.y);extended.leftWidth=static_cast<uint32_t>(rect.extent.width);extended.leftHeight=static_cast<uint32_t>(rect.extent.height);}
      else{extended.right=image->texture11;extended.rightArraySlice=v.subImage.imageArrayIndex;extended.rightX=static_cast<uint32_t>(rect.offset.x);extended.rightY=static_cast<uint32_t>(rect.offset.y);extended.rightWidth=static_cast<uint32_t>(rect.extent.width);extended.rightHeight=static_cast<uint32_t>(rect.extent.height);}
    }
  }
  if(s->d3d12){
    if(!d3d12Frame.left||!d3d12Frame.right)return XR_ERROR_LAYER_INVALID;
    return SUCCEEDED(s->dxmtQueue12->SubmitWindowsVRFrame(&d3d12Frame))?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;
  }
  if(!extended.left||!extended.right)return XR_ERROR_LAYER_INVALID;
  if(needsExt3){
    if(!s->dxmtExt3)return XR_ERROR_FEATURE_UNSUPPORTED;
    return SUCCEEDED(s->dxmtExt3->SubmitWindowsVRFrameV2(&extended))?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;
  }
  WVRDXMTSubmitFrameV1 frame{};frame.left=extended.left;frame.right=extended.right;frame.targetGeneration=targets.generation;frame.frameID=extended.frameID;frame.timestampNanoseconds=extended.timestampNanoseconds;
  HRESULT hr=s->dxmt->SubmitWindowsVRFrame(&frame);
  return SUCCEEDED(hr)?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;
}
XrResult XRAPI_CALL LocateViews(XrSession h,const XrViewLocateInfo*info,XrViewState*state,uint32_t cap,uint32_t*count,XrView*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_VIEW_LOCATE_INFO||!state||state->type!=XR_TYPE_VIEW_STATE||!count||info->viewConfigurationType!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VALIDATION_FAILURE;
  auto*base=GetSpace(info->space);if(!base||base->session!=s)return XR_ERROR_HANDLE_INVALID;
  WVRDXMTTrackingV1 t{};if(FAILED(GetSessionTracking(s, &t)))return XR_ERROR_RUNTIME_FAILURE;
  *count=2;if(cap==0)return XR_SUCCESS;if(cap<2)return XR_ERROR_SIZE_INSUFFICIENT;if(!out)return XR_ERROR_VALIDATION_FAILURE;
  XrPosef originFromBase{};uint32_t baseFlags=0;if(!OriginFromSpace(s,base,t,originFromBase,baseFlags)){state->viewStateFlags=0;return XR_SUCCESS;}
  state->viewStateFlags=baseFlags;
  for(uint32_t i=0;i<2;i++){
    if(out[i].type!=XR_TYPE_VIEW)return XR_ERROR_VALIDATION_FAILURE;
    float originEyeMatrix[16];MultiplyColumnMajor(t.originFromDevice,t.deviceFromEye[i],originEyeMatrix);
    const XrPosef originFromEye=PoseFromMatrix(originEyeMatrix);
    out[i].pose=RelativePose(originFromEye,originFromBase);
    out[i].fov.angleLeft=-std::atan(std::fabs(t.frustumTangents[i][0]));
    out[i].fov.angleRight=std::atan(std::fabs(t.frustumTangents[i][1]));
    out[i].fov.angleUp=std::atan(std::fabs(t.frustumTangents[i][2]));
    out[i].fov.angleDown=-std::atan(std::fabs(t.frustumTangents[i][3]));
  }
  return XR_SUCCESS;
}
XrResult XRAPI_CALL PollEvent(XrInstance h,XrEventDataBuffer*out){
  auto*instance=GetInstance(h);if(!instance)return XR_ERROR_HANDLE_INVALID;
  if(!out||out->type!=XR_TYPE_EVENT_DATA_BUFFER)return XR_ERROR_VALIDATION_FAILURE;
  std::lock_guard<std::mutex> globalLock(g_mutex);
  for(auto&entry:g_sessions){auto*session=entry.get();if(session->instance!=instance)continue;ObserveSessionExitRequest(session);std::lock_guard<std::mutex> eventLock(session->eventMutex);if(session->events.empty())continue;
    const SessionEvent event=session->events.front();session->events.erase(session->events.begin());
    auto*changed=reinterpret_cast<XrEventDataSessionStateChanged*>(out);
    changed->type=XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;changed->next=nullptr;changed->session=reinterpret_cast<XrSession>(session);changed->state=event.state;changed->time=event.time;return XR_SUCCESS;
  }
  return XR_EVENT_UNAVAILABLE;
}

XrResult XRAPI_CALL EnumerateReferenceSpaces(XrSession h,uint32_t capacity,uint32_t*count,XrReferenceSpaceType*out){
  if(!GetSession(h))return XR_ERROR_HANDLE_INVALID;
  const XrReferenceSpaceType supported[2]={XR_REFERENCE_SPACE_TYPE_VIEW,XR_REFERENCE_SPACE_TYPE_LOCAL};
  if(!count)return XR_ERROR_VALIDATION_FAILURE;*count=2;if(capacity==0)return XR_SUCCESS;if(!out)return XR_ERROR_VALIDATION_FAILURE;if(capacity<2)return XR_ERROR_SIZE_INSUFFICIENT;std::memcpy(out,supported,sizeof(supported));return XR_SUCCESS;
}
XrResult XRAPI_CALL GetReferenceSpaceBoundsRect(XrSession h,XrReferenceSpaceType type,XrExtent2Df*out){
  if(!GetSession(h))return XR_ERROR_HANDLE_INVALID;if(type!=XR_REFERENCE_SPACE_TYPE_STAGE)return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;if(!out)return XR_ERROR_VALIDATION_FAILURE;return XR_SPACE_BOUNDS_UNAVAILABLE;
}
XrResult XRAPI_CALL StringToPath(XrInstance h,const char*text,XrPath*out){
  auto*i=GetInstance(h);if(!i)return XR_ERROR_HANDLE_INVALID;if(!text||!out)return XR_ERROR_VALIDATION_FAILURE;
  const size_t length=std::strlen(text);if(length==0||length>=XR_MAX_PATH_LENGTH||text[0]!='/'||std::strstr(text,"//")||std::strchr(text,' '))return XR_ERROR_PATH_FORMAT_INVALID;
  std::lock_guard<std::mutex>lock(i->mutex);auto found=i->paths.find(text);if(found!=i->paths.end()){*out=found->second;return XR_SUCCESS;}const XrPath path=i->nextPath++;i->paths.emplace(text,path);i->pathStrings.emplace(path,text);*out=path;return XR_SUCCESS;
}
XrResult XRAPI_CALL PathToString(XrInstance h,XrPath path,uint32_t capacity,uint32_t*count,char*out){
  auto*i=GetInstance(h);if(!i)return XR_ERROR_HANDLE_INVALID;if(!count||path==XR_NULL_PATH)return XR_ERROR_PATH_INVALID;std::lock_guard<std::mutex>lock(i->mutex);auto found=i->pathStrings.find(path);if(found==i->pathStrings.end())return XR_ERROR_PATH_UNSUPPORTED;const uint32_t required=static_cast<uint32_t>(found->second.size()+1);*count=required;if(capacity==0)return XR_SUCCESS;if(!out)return XR_ERROR_VALIDATION_FAILURE;if(capacity<required)return XR_ERROR_SIZE_INSUFFICIENT;std::memcpy(out,found->second.c_str(),required);return XR_SUCCESS;
}

XrResult XRAPI_CALL ResultToString(XrInstance h,XrResult result,char buffer[XR_MAX_RESULT_STRING_SIZE]){
  auto*instance=GetInstance(h);if(!instance)return XR_ERROR_HANDLE_INVALID;if(!buffer)return XR_ERROR_VALIDATION_FAILURE;
  const char*name="XR_RESULT_UNKNOWN";
  switch(result){
    case XR_SUCCESS:name="XR_SUCCESS";break;case XR_TIMEOUT_EXPIRED:name="XR_TIMEOUT_EXPIRED";break;
    case XR_SESSION_LOSS_PENDING:name="XR_SESSION_LOSS_PENDING";break;case XR_EVENT_UNAVAILABLE:name="XR_EVENT_UNAVAILABLE";break;
    case XR_SPACE_BOUNDS_UNAVAILABLE:name="XR_SPACE_BOUNDS_UNAVAILABLE";break;case XR_SESSION_NOT_FOCUSED:name="XR_SESSION_NOT_FOCUSED";break;
    case XR_FRAME_DISCARDED:name="XR_FRAME_DISCARDED";break;case XR_ERROR_VALIDATION_FAILURE:name="XR_ERROR_VALIDATION_FAILURE";break;
    case XR_ERROR_RUNTIME_FAILURE:name="XR_ERROR_RUNTIME_FAILURE";break;case XR_ERROR_OUT_OF_MEMORY:name="XR_ERROR_OUT_OF_MEMORY";break;
    case XR_ERROR_API_VERSION_UNSUPPORTED:name="XR_ERROR_API_VERSION_UNSUPPORTED";break;case XR_ERROR_INITIALIZATION_FAILED:name="XR_ERROR_INITIALIZATION_FAILED";break;
    case XR_ERROR_FUNCTION_UNSUPPORTED:name="XR_ERROR_FUNCTION_UNSUPPORTED";break;case XR_ERROR_FEATURE_UNSUPPORTED:name="XR_ERROR_FEATURE_UNSUPPORTED";break;
    case XR_ERROR_EXTENSION_NOT_PRESENT:name="XR_ERROR_EXTENSION_NOT_PRESENT";break;case XR_ERROR_LIMIT_REACHED:name="XR_ERROR_LIMIT_REACHED";break;
    case XR_ERROR_SIZE_INSUFFICIENT:name="XR_ERROR_SIZE_INSUFFICIENT";break;case XR_ERROR_HANDLE_INVALID:name="XR_ERROR_HANDLE_INVALID";break;
    case XR_ERROR_INSTANCE_LOST:name="XR_ERROR_INSTANCE_LOST";break;case XR_ERROR_SESSION_RUNNING:name="XR_ERROR_SESSION_RUNNING";break;
    case XR_ERROR_SESSION_NOT_RUNNING:name="XR_ERROR_SESSION_NOT_RUNNING";break;case XR_ERROR_SESSION_LOST:name="XR_ERROR_SESSION_LOST";break;
    case XR_ERROR_SYSTEM_INVALID:name="XR_ERROR_SYSTEM_INVALID";break;case XR_ERROR_PATH_INVALID:name="XR_ERROR_PATH_INVALID";break;
    case XR_ERROR_PATH_COUNT_EXCEEDED:name="XR_ERROR_PATH_COUNT_EXCEEDED";break;case XR_ERROR_PATH_FORMAT_INVALID:name="XR_ERROR_PATH_FORMAT_INVALID";break;
    case XR_ERROR_PATH_UNSUPPORTED:name="XR_ERROR_PATH_UNSUPPORTED";break;case XR_ERROR_LAYER_INVALID:name="XR_ERROR_LAYER_INVALID";break;
    case XR_ERROR_LAYER_LIMIT_EXCEEDED:name="XR_ERROR_LAYER_LIMIT_EXCEEDED";break;case XR_ERROR_SWAPCHAIN_RECT_INVALID:name="XR_ERROR_SWAPCHAIN_RECT_INVALID";break;
    case XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED:name="XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED";break;case XR_ERROR_ACTION_TYPE_MISMATCH:name="XR_ERROR_ACTION_TYPE_MISMATCH";break;
    case XR_ERROR_SESSION_NOT_READY:name="XR_ERROR_SESSION_NOT_READY";break;case XR_ERROR_SESSION_NOT_STOPPING:name="XR_ERROR_SESSION_NOT_STOPPING";break;
    case XR_ERROR_TIME_INVALID:name="XR_ERROR_TIME_INVALID";break;case XR_ERROR_REFERENCE_SPACE_UNSUPPORTED:name="XR_ERROR_REFERENCE_SPACE_UNSUPPORTED";break;
    case XR_ERROR_FILE_ACCESS_ERROR:name="XR_ERROR_FILE_ACCESS_ERROR";break;case XR_ERROR_FILE_CONTENTS_INVALID:name="XR_ERROR_FILE_CONTENTS_INVALID";break;
    case XR_ERROR_FORM_FACTOR_UNSUPPORTED:name="XR_ERROR_FORM_FACTOR_UNSUPPORTED";break;case XR_ERROR_FORM_FACTOR_UNAVAILABLE:name="XR_ERROR_FORM_FACTOR_UNAVAILABLE";break;
    case XR_ERROR_API_LAYER_NOT_PRESENT:name="XR_ERROR_API_LAYER_NOT_PRESENT";break;case XR_ERROR_CALL_ORDER_INVALID:name="XR_ERROR_CALL_ORDER_INVALID";break;
    case XR_ERROR_GRAPHICS_DEVICE_INVALID:name="XR_ERROR_GRAPHICS_DEVICE_INVALID";break;case XR_ERROR_RUNTIME_UNAVAILABLE:name="XR_ERROR_RUNTIME_UNAVAILABLE";break;case XR_ERROR_POSE_INVALID:name="XR_ERROR_POSE_INVALID";break;
    case XR_ERROR_INDEX_OUT_OF_RANGE:name="XR_ERROR_INDEX_OUT_OF_RANGE";break;case XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED:name="XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED";break;
    case XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED:name="XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED";break;case XR_ERROR_NAME_INVALID:name="XR_ERROR_NAME_INVALID";break;
    case XR_ERROR_ACTIONSET_NOT_ATTACHED:name="XR_ERROR_ACTIONSET_NOT_ATTACHED";break;case XR_ERROR_ACTIONSETS_ALREADY_ATTACHED:name="XR_ERROR_ACTIONSETS_ALREADY_ATTACHED";break;
    case XR_ERROR_LOCALIZED_NAME_INVALID:name="XR_ERROR_LOCALIZED_NAME_INVALID";break;case XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING:name="XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING";break;
    default:break;
  }
  std::snprintf(buffer,XR_MAX_RESULT_STRING_SIZE,"%s",name);return XR_SUCCESS;
}

XrResult XRAPI_CALL StructureTypeToString(XrInstance h,XrStructureType type,char buffer[XR_MAX_STRUCTURE_NAME_SIZE]){
  auto*instance=GetInstance(h);if(!instance)return XR_ERROR_HANDLE_INVALID;if(!buffer)return XR_ERROR_VALIDATION_FAILURE;
  const char*name="XR_TYPE_UNKNOWN";
#define MAP_STRUCTURE(value) case value:name=#value;break
  switch(type){
    MAP_STRUCTURE(XR_TYPE_API_LAYER_PROPERTIES);MAP_STRUCTURE(XR_TYPE_EXTENSION_PROPERTIES);MAP_STRUCTURE(XR_TYPE_INSTANCE_CREATE_INFO);
    MAP_STRUCTURE(XR_TYPE_INSTANCE_PROPERTIES);MAP_STRUCTURE(XR_TYPE_SYSTEM_GET_INFO);MAP_STRUCTURE(XR_TYPE_SYSTEM_PROPERTIES);
    MAP_STRUCTURE(XR_TYPE_VIEW_CONFIGURATION_PROPERTIES);MAP_STRUCTURE(XR_TYPE_VIEW_CONFIGURATION_VIEW);MAP_STRUCTURE(XR_TYPE_VIEW);MAP_STRUCTURE(XR_TYPE_SESSION_CREATE_INFO);
    MAP_STRUCTURE(XR_TYPE_SESSION_BEGIN_INFO);MAP_STRUCTURE(XR_TYPE_REFERENCE_SPACE_CREATE_INFO);MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_CREATE_INFO);
    MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO);MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO);
    MAP_STRUCTURE(XR_TYPE_FRAME_WAIT_INFO);MAP_STRUCTURE(XR_TYPE_FRAME_STATE);MAP_STRUCTURE(XR_TYPE_FRAME_BEGIN_INFO);MAP_STRUCTURE(XR_TYPE_FRAME_END_INFO);
    MAP_STRUCTURE(XR_TYPE_COMPOSITION_LAYER_PROJECTION);MAP_STRUCTURE(XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW);MAP_STRUCTURE(XR_TYPE_COMPOSITION_LAYER_QUAD);MAP_STRUCTURE(XR_TYPE_VIEW_LOCATE_INFO);
    MAP_STRUCTURE(XR_TYPE_VIEW_STATE);MAP_STRUCTURE(XR_TYPE_EVENT_DATA_BUFFER);MAP_STRUCTURE(XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING);
    MAP_STRUCTURE(XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED);MAP_STRUCTURE(XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING);
    MAP_STRUCTURE(XR_TYPE_EVENT_DATA_EVENTS_LOST);MAP_STRUCTURE(XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED);
    MAP_STRUCTURE(XR_TYPE_SPACE_LOCATION);MAP_STRUCTURE(XR_TYPE_SPACE_VELOCITY);MAP_STRUCTURE(XR_TYPE_ACTION_SPACE_CREATE_INFO);
    MAP_STRUCTURE(XR_TYPE_ACTION_SET_CREATE_INFO);MAP_STRUCTURE(XR_TYPE_ACTION_CREATE_INFO);MAP_STRUCTURE(XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING);
    MAP_STRUCTURE(XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO);MAP_STRUCTURE(XR_TYPE_INTERACTION_PROFILE_STATE);MAP_STRUCTURE(XR_TYPE_ACTIONS_SYNC_INFO);
    MAP_STRUCTURE(XR_TYPE_ACTION_STATE_GET_INFO);MAP_STRUCTURE(XR_TYPE_ACTION_STATE_BOOLEAN);MAP_STRUCTURE(XR_TYPE_ACTION_STATE_FLOAT);
    MAP_STRUCTURE(XR_TYPE_ACTION_STATE_VECTOR2F);MAP_STRUCTURE(XR_TYPE_ACTION_STATE_POSE);MAP_STRUCTURE(XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO);
    MAP_STRUCTURE(XR_TYPE_HAPTIC_ACTION_INFO);MAP_STRUCTURE(XR_TYPE_HAPTIC_VIBRATION);MAP_STRUCTURE(XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR);
    MAP_STRUCTURE(XR_TYPE_GRAPHICS_BINDING_D3D11_KHR);MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR);
    MAP_STRUCTURE(XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR);MAP_STRUCTURE(XR_TYPE_GRAPHICS_BINDING_D3D12_KHR);MAP_STRUCTURE(XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR);
    default:break;
  }
#undef MAP_STRUCTURE
  std::snprintf(buffer,XR_MAX_STRUCTURE_NAME_SIZE,"%s",name);return XR_SUCCESS;
}

XrResult XRAPI_CALL GetInputSourceLocalizedName(XrSession h,const XrInputSourceLocalizedNameGetInfo*info,uint32_t capacity,uint32_t*count,char*buffer){
  auto*session=GetSession(h);if(!session)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_INPUT_SOURCE_LOCALIZED_NAME_GET_INFO||!count)return XR_ERROR_VALIDATION_FAILURE;
  constexpr XrInputSourceLocalizedNameFlags validFlags=XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT|XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT|XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT;
  if(info->whichComponents==0||(info->whichComponents&~validFlags)!=0)return XR_ERROR_VALIDATION_FAILURE;
  auto path=session->instance->pathStrings.find(info->sourcePath);
  if(info->sourcePath==XR_NULL_PATH||path==session->instance->pathStrings.end())return XR_ERROR_PATH_UNSUPPORTED;
  const uint32_t role=RoleForPath(session->instance,info->sourcePath);if(role==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;
  const bool left=role==kControllerLeft;
  std::vector<std::string> parts;
  if(info->whichComponents&XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT)parts.push_back(left?"Left Hand":"Right Hand");
  if(info->whichComponents&XR_INPUT_SOURCE_LOCALIZED_NAME_INTERACTION_PROFILE_BIT)parts.push_back("Controller");
  if(info->whichComponents&XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT){
    std::string component="Input";const size_t input=path->second.find("/input/");
    if(input!=std::string::npos){component=path->second.substr(input+7);std::replace(component.begin(),component.end(),'/',' ');}
    for(char&character:component)if(character=='_')character=' ';
    if(!component.empty())component[0]=static_cast<char>(std::toupper(static_cast<unsigned char>(component[0])));
    parts.push_back(component);
  }
  std::string localized;
  for(const auto&part:parts){if(!localized.empty())localized.push_back(' ');localized+=part;}
  const uint32_t required=static_cast<uint32_t>(localized.size()+1);*count=required;
  if(capacity==0)return XR_SUCCESS;if(capacity<required)return XR_ERROR_SIZE_INSUFFICIENT;if(!buffer)return XR_ERROR_VALIDATION_FAILURE;
  std::memcpy(buffer,localized.c_str(),required);return XR_SUCCESS;
}

XrResult XRAPI_CALL CreateActionSpace(XrSession h,const XrActionSpaceCreateInfo*info,XrSpace*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_ACTION_SPACE_CREATE_INFO||!out)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_POSE_INPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;if(info->subactionPath!=XR_NULL_PATH&&std::find(a->subactionPaths.begin(),a->subactionPaths.end(),info->subactionPath)==a->subactionPaths.end())return XR_ERROR_PATH_UNSUPPORTED;
  auto p=std::make_unique<Space>();p->session=s;p->action=info->action;p->subactionPath=info->subactionPath;p->poseInActionSpace=info->poseInActionSpace;Space*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_spaces.push_back(std::move(p));}RegisterHandle(raw);*out=reinterpret_cast<XrSpace>(raw);return XR_SUCCESS;
}

XrResult XRAPI_CALL LocateSpace(XrSpace spaceHandle,XrSpace baseHandle,XrTime time,XrSpaceLocation*out){
  auto*space=GetSpace(spaceHandle);auto*base=GetSpace(baseHandle);if(!space||!base)return XR_ERROR_HANDLE_INVALID;if(space->session!=base->session)return XR_ERROR_HANDLE_INVALID;if(time<=0||!out||out->type!=XR_TYPE_SPACE_LOCATION)return XR_ERROR_VALIDATION_FAILURE;
  auto*s=space->session;WVRDXMTTrackingV1 tracking{};if(FAILED(GetSessionTracking(s, &tracking)))return XR_ERROR_RUNTIME_FAILURE;
  XrPosef originFromSpace{},originFromBase{};uint32_t spaceFlags=0,baseFlags=0;
  if(!OriginFromSpace(s,space,tracking,originFromSpace,spaceFlags)||!OriginFromSpace(s,base,tracking,originFromBase,baseFlags)){out->locationFlags=0;return XR_SUCCESS;}
  out->pose=RelativePose(originFromSpace,originFromBase);out->locationFlags=spaceFlags&baseFlags;
  if(out->next){auto*velocity=static_cast<XrSpaceVelocity*>(out->next);if(velocity->type==XR_TYPE_SPACE_VELOCITY){velocity->velocityFlags=0;velocity->linearVelocity={0,0,0};velocity->angularVelocity={0,0,0};}}
  return XR_SUCCESS;
}

std::string BoundedName(const char*value,size_t capacity){const char*end=static_cast<const char*>(std::memchr(value,'\0',capacity));return end?std::string(value,end):std::string();}

XrResult XRAPI_CALL CreateActionSet(XrInstance h,const XrActionSetCreateInfo*info,XrActionSet*out){
  auto*i=GetInstance(h);if(!i)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_ACTION_SET_CREATE_INFO||!out)return XR_ERROR_VALIDATION_FAILURE;std::string name=BoundedName(info->actionSetName,sizeof(info->actionSetName));if(name.empty())return XR_ERROR_NAME_INVALID;
  auto set=std::make_unique<ActionSet>();set->instance=i;set->name=name;set->priority=info->priority;ActionSet*raw=set.get();{std::lock_guard<std::mutex>lock(i->mutex);i->actionSets.push_back(std::move(set));}RegisterHandle(raw);*out=reinterpret_cast<XrActionSet>(raw);return XR_SUCCESS;
}
XrResult XRAPI_CALL DestroyActionSet(XrActionSet h){auto*set=GetActionSet(h);if(!set)return XR_ERROR_HANDLE_INVALID;if(!set->actions.empty())return XR_ERROR_CALL_ORDER_INVALID;Instance*i=set->instance;std::lock_guard<std::mutex>lock(i->mutex);UnregisterHandle(set);set->magic=0;i->actionSets.erase(std::remove_if(i->actionSets.begin(),i->actionSets.end(),[set](const auto&value){return value.get()==set;}),i->actionSets.end());return XR_SUCCESS;}
XrResult XRAPI_CALL CreateAction(XrActionSet h,const XrActionCreateInfo*info,XrAction*out){
  auto*set=GetActionSet(h);if(!set)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_ACTION_CREATE_INFO||!out)return XR_ERROR_VALIDATION_FAILURE;std::string name=BoundedName(info->actionName,sizeof(info->actionName));if(name.empty())return XR_ERROR_NAME_INVALID;
  switch(info->actionType){
    case XR_ACTION_TYPE_BOOLEAN_INPUT:
    case XR_ACTION_TYPE_FLOAT_INPUT:
    case XR_ACTION_TYPE_VECTOR2F_INPUT:
    case XR_ACTION_TYPE_POSE_INPUT:
    case XR_ACTION_TYPE_VIBRATION_OUTPUT: break;
    default: return XR_ERROR_ACTION_TYPE_MISMATCH;
  }
  if(info->countSubactionPaths&&!info->subactionPaths)return XR_ERROR_VALIDATION_FAILURE;auto action=std::make_unique<Action>();action->set=set;action->name=name;action->type=info->actionType;
  for(uint32_t n=0;n<info->countSubactionPaths;n++){
    auto subaction=set->instance->pathStrings.find(info->subactionPaths[n]);
    if(subaction==set->instance->pathStrings.end()||(subaction->second!="/user/hand/left"&&subaction->second!="/user/hand/right"))return XR_ERROR_PATH_UNSUPPORTED;
    if(std::find(action->subactionPaths.begin(),action->subactionPaths.end(),info->subactionPaths[n])!=action->subactionPaths.end())return XR_ERROR_VALIDATION_FAILURE;
    action->subactionPaths.push_back(info->subactionPaths[n]);
  }
  Action*raw=action.get();{std::lock_guard<std::mutex>lock(set->instance->mutex);set->instance->actions.push_back(std::move(action));set->actions.push_back(reinterpret_cast<XrAction>(raw));}RegisterHandle(raw);*out=reinterpret_cast<XrAction>(raw);return XR_SUCCESS;
}
XrResult XRAPI_CALL DestroyAction(XrAction h){auto*action=GetAction(h);if(!action)return XR_ERROR_HANDLE_INVALID;Instance*i=action->set->instance;std::lock_guard<std::mutex>lock(i->mutex);UnregisterHandle(action);action->magic=0;action->set->actions.erase(std::remove(action->set->actions.begin(),action->set->actions.end(),h),action->set->actions.end());for(auto it=i->bindings.begin();it!=i->bindings.end();)if(it->second==h)it=i->bindings.erase(it);else ++it;i->actions.erase(std::remove_if(i->actions.begin(),i->actions.end(),[action](const auto&value){return value.get()==action;}),i->actions.end());return XR_SUCCESS;}
XrResult XRAPI_CALL SuggestInteractionProfileBindings(XrInstance h,const XrInteractionProfileSuggestedBinding*info){
  auto*i=GetInstance(h);if(!i)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING||(info->countSuggestedBindings&&!info->suggestedBindings))return XR_ERROR_VALIDATION_FAILURE;
  auto profile=i->pathStrings.find(info->interactionProfile);
  if(profile==i->pathStrings.end()||profile->second.rfind("/interaction_profiles/",0)!=0)return XR_ERROR_PATH_UNSUPPORTED;
  for(uint32_t n=0;n<info->countSuggestedBindings;n++){
    const auto&suggestion=info->suggestedBindings[n];Action*a=GetAction(suggestion.action);
    if(!a||a->set->instance!=i)return XR_ERROR_HANDLE_INVALID;
    auto binding=i->pathStrings.find(suggestion.binding);
    if(binding==i->pathStrings.end())return XR_ERROR_PATH_UNSUPPORTED;
    const uint32_t role=RoleForPath(i,suggestion.binding);
    if(role==UINT32_MAX||binding->second.find(a->type==XR_ACTION_TYPE_VIBRATION_OUTPUT?"/output/":"/input/")==std::string::npos||!ActionAllowsRole(a,role))return XR_ERROR_PATH_UNSUPPORTED;
    for(uint32_t previous=0;previous<n;previous++)if(info->suggestedBindings[previous].binding==suggestion.binding)return XR_ERROR_VALIDATION_FAILURE;
  }
  std::lock_guard<std::mutex>lock(i->mutex);
  for(uint32_t n=0;n<info->countSuggestedBindings;n++){
    const auto&binding=info->suggestedBindings[n];i->bindings[binding.binding]=binding.action;
    auto*a=GetAction(binding.action);
    if(std::find(a->bindingPaths.begin(),a->bindingPaths.end(),binding.binding)==a->bindingPaths.end())a->bindingPaths.push_back(binding.binding);
  }
  const XrPath left=UserPathForRole(i,kControllerLeft),right=UserPathForRole(i,kControllerRight);
  i->interactionProfiles[left]=info->interactionProfile;i->interactionProfiles[right]=info->interactionProfile;return XR_SUCCESS;
}
XrResult XRAPI_CALL AttachSessionActionSets(XrSession h,const XrSessionActionSetsAttachInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO||(info->countActionSets&&!info->actionSets))return XR_ERROR_VALIDATION_FAILURE;if(s->actionSetsAttached)return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
  for(uint32_t n=0;n<info->countActionSets;n++){auto*set=GetActionSet(info->actionSets[n]);if(!set||set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(std::find(s->attachedActionSets.begin(),s->attachedActionSets.end(),info->actionSets[n])!=s->attachedActionSets.end())return XR_ERROR_VALIDATION_FAILURE;s->attachedActionSets.push_back(info->actionSets[n]);}
  s->actionSetsAttached=true;return XR_SUCCESS;
}
XrResult XRAPI_CALL GetCurrentInteractionProfile(XrSession h,XrPath userPath,XrInteractionProfileState*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_INTERACTION_PROFILE_STATE)return XR_ERROR_VALIDATION_FAILURE;if(RoleForPath(s->instance,userPath)==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;auto found=s->instance->interactionProfiles.find(userPath);out->interactionProfile=found==s->instance->interactionProfiles.end()?XR_NULL_PATH:found->second;return XR_SUCCESS;}
XrResult XRAPI_CALL SyncActions(XrSession h,const XrActionsSyncInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_ACTIONS_SYNC_INFO||(info->countActiveActionSets&&!info->activeActionSets))return XR_ERROR_VALIDATION_FAILURE;
  if(!s->actionSetsAttached)return XR_ERROR_ACTIONSET_NOT_ATTACHED;
  std::vector<XrActionSet> activeSets;std::unordered_map<XrActionSet,XrPath> activeSubactions;
  for(uint32_t n=0;n<info->countActiveActionSets;n++){
    const auto&active=info->activeActionSets[n];auto*set=GetActionSet(active.actionSet);
    if(!set||set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;
    if(std::find(s->attachedActionSets.begin(),s->attachedActionSets.end(),active.actionSet)==s->attachedActionSets.end())return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    if(std::find(activeSets.begin(),activeSets.end(),active.actionSet)!=activeSets.end())return XR_ERROR_VALIDATION_FAILURE;
    if(active.subactionPath!=XR_NULL_PATH){
      auto path=s->instance->pathStrings.find(active.subactionPath);
      if(path==s->instance->pathStrings.end()||(path->second!="/user/hand/left"&&path->second!="/user/hand/right"))return XR_ERROR_PATH_UNSUPPORTED;
    }
    activeSets.push_back(active.actionSet);activeSubactions.emplace(active.actionSet,active.subactionPath);
  }
  ObserveSessionExitRequest(s);
  if(!s->begun||s->state!=XR_SESSION_STATE_FOCUSED){
    s->activeActionSets.clear();s->activeSetSubactions.clear();s->controllers=ControllerSample{};
    return XR_SESSION_NOT_FOCUSED;
  }
  ControllerSample controllers{};
  if(FAILED(GetSessionController(s,kControllerLeft,&controllers.left))||FAILED(GetSessionController(s,kControllerRight,&controllers.right)))return XR_ERROR_RUNTIME_FAILURE;
  s->activeActionSets.swap(activeSets);s->activeSetSubactions.swap(activeSubactions);s->controllers=controllers;
  for(auto&setPtr:s->instance->actionSets){
    auto*set=setPtr.get();if(!ActionSetIsActive(s,set))continue;
    for(XrAction handle:set->actions){
      auto*action=GetAction(handle);if(!action||action->type==XR_ACTION_TYPE_VIBRATION_OUTPUT)continue;
      for(uint32_t role:{kControllerLeft,kControllerRight}){
        bool applicable=ActionAllowsRole(action,role)&&ActionHasBindingForRole(action,role);
        auto activePath=s->activeSetSubactions.find(reinterpret_cast<XrActionSet>(set));
        if(activePath!=s->activeSetSubactions.end()&&activePath->second!=XR_NULL_PATH&&RoleForPath(s->instance,activePath->second)!=role)applicable=false;
        if(applicable)UpdateActionSnapshot(action,role,role==kControllerLeft?s->controllers.left:s->controllers.right);
      }
    }
  }
  return XR_SUCCESS;
}

XrResult GetActionSnapshot(Session*s,const XrActionStateGetInfo*info,XrActionType expected,Action*&action,ActionValue&value,bool&active){
  if(!info||info->type!=XR_TYPE_ACTION_STATE_GET_INFO)return XR_ERROR_VALIDATION_FAILURE;
  action=GetAction(info->action);
  if(!action||action->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;
  if(action->type!=expected)return XR_ERROR_ACTION_TYPE_MISMATCH;
  if(info->subactionPath!=XR_NULL_PATH&&
      std::find(action->subactionPaths.begin(),action->subactionPaths.end(),info->subactionPath)==action->subactionPaths.end())return XR_ERROR_PATH_UNSUPPORTED;
  const bool setActive=s->state==XR_SESSION_STATE_FOCUSED&&ActionSetIsActive(s,action->set);
  auto activePath=s->activeSetSubactions.find(reinterpret_cast<XrActionSet>(action->set));
  const uint32_t requestedRole=info->subactionPath==XR_NULL_PATH?UINT32_MAX:RoleForPath(s->instance,info->subactionPath);
  if(info->subactionPath!=XR_NULL_PATH&&requestedRole==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;
  active=false;
  for(uint32_t role:{kControllerLeft,kControllerRight}){
    if(requestedRole!=UINT32_MAX&&requestedRole!=role)continue;
    if(!ActionAllowsRole(action,role)||!ActionHasBindingForRole(action,role))continue;
    if(activePath!=s->activeSetSubactions.end()&&activePath->second!=XR_NULL_PATH&&RoleForPath(s->instance,activePath->second)!=role)continue;
    const auto&controller=role==kControllerLeft?s->controllers.left:s->controllers.right;
    if(!setActive||!ControllerConnected(controller))continue;
    auto found=action->values.find(role);
    if(found==action->values.end())found=action->values.emplace(role,SampleAction(action,role,controller)).first;
    const ActionValue&candidate=found->second;
    if(action->type==XR_ACTION_TYPE_POSE_INPUT&&!candidate.boolean)continue;
    active=true;
    value.changed=value.changed||candidate.changed;
    value.lastChangeTime=std::max(value.lastChangeTime,candidate.lastChangeTime);
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT||action->type==XR_ACTION_TYPE_POSE_INPUT){
      value.boolean=value.boolean||candidate.boolean;
    } else if(action->type==XR_ACTION_TYPE_FLOAT_INPUT){
      if(std::fabs(candidate.scalar)>std::fabs(value.scalar))value.scalar=candidate.scalar;
    } else if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT){
      const float candidateMagnitude=candidate.vector.x*candidate.vector.x+candidate.vector.y*candidate.vector.y;
      const float valueMagnitude=value.vector.x*value.vector.x+value.vector.y*value.vector.y;
      if(candidateMagnitude>valueMagnitude)value.vector=candidate.vector;
    }
  }
  if(!active)value=ActionValue{};
  return XR_SUCCESS;
}

XrResult XRAPI_CALL GetActionStateBoolean(XrSession h,const XrActionStateGetInfo*info,XrActionStateBoolean*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_BOOLEAN)return XR_ERROR_VALIDATION_FAILURE;Action*a;ActionValue v{};bool active;XrResult result=GetActionSnapshot(s,info,XR_ACTION_TYPE_BOOLEAN_INPUT,a,v,active);if(XR_FAILED(result))return result;out->currentState=active&&v.boolean;out->changedSinceLastSync=active&&v.changed;out->lastChangeTime=v.lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStateFloat(XrSession h,const XrActionStateGetInfo*info,XrActionStateFloat*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_FLOAT)return XR_ERROR_VALIDATION_FAILURE;Action*a;ActionValue v{};bool active;XrResult result=GetActionSnapshot(s,info,XR_ACTION_TYPE_FLOAT_INPUT,a,v,active);if(XR_FAILED(result))return result;out->currentState=active?v.scalar:0;out->changedSinceLastSync=active&&v.changed;out->lastChangeTime=v.lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStateVector2f(XrSession h,const XrActionStateGetInfo*info,XrActionStateVector2f*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_VECTOR2F)return XR_ERROR_VALIDATION_FAILURE;Action*a;ActionValue v{};bool active;XrResult result=GetActionSnapshot(s,info,XR_ACTION_TYPE_VECTOR2F_INPUT,a,v,active);if(XR_FAILED(result))return result;out->currentState=active?v.vector:XrVector2f{0,0};out->changedSinceLastSync=active&&v.changed;out->lastChangeTime=v.lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStatePose(XrSession h,const XrActionStateGetInfo*info,XrActionStatePose*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_POSE)return XR_ERROR_VALIDATION_FAILURE;Action*a;ActionValue v{};bool active;XrResult result=GetActionSnapshot(s,info,XR_ACTION_TYPE_POSE_INPUT,a,v,active);if(XR_FAILED(result))return result;out->isActive=active&&v.boolean;return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateBoundSourcesForAction(XrSession h,const XrBoundSourcesForActionEnumerateInfo*info,uint32_t capacity,uint32_t*count,XrPath*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO||!count)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;*count=static_cast<uint32_t>(a->bindingPaths.size());if(capacity==0)return XR_SUCCESS;if(capacity<*count)return XR_ERROR_SIZE_INSUFFICIENT;if(*count&&!out)return XR_ERROR_VALIDATION_FAILURE;std::copy(a->bindingPaths.begin(),a->bindingPaths.end(),out);return XR_SUCCESS;}
XrResult XRAPI_CALL ApplyHapticFeedback(XrSession h,const XrHapticActionInfo*info,const XrHapticBaseHeader*feedback){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_HAPTIC_ACTION_INFO||!feedback||feedback->type!=XR_TYPE_HAPTIC_VIBRATION)return XR_ERROR_VALIDATION_FAILURE;
  auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_VIBRATION_OUTPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;
  if(info->subactionPath!=XR_NULL_PATH&&std::find(a->subactionPaths.begin(),a->subactionPaths.end(),info->subactionPath)==a->subactionPaths.end())return XR_ERROR_PATH_UNSUPPORTED;
  const auto*vibration=reinterpret_cast<const XrHapticVibration*>(feedback);
  if(!std::isfinite(vibration->amplitude)||vibration->amplitude<0.0f||vibration->amplitude>1.0f||
      (vibration->duration<0&&vibration->duration!=XR_MIN_HAPTIC_DURATION)||
      !std::isfinite(vibration->frequency)||(vibration->frequency!=XR_FREQUENCY_UNSPECIFIED&&vibration->frequency<=0.0f))return XR_ERROR_VALIDATION_FAILURE;
  bool submitted=false;
  for(uint32_t role:{kControllerLeft,kControllerRight}){
    if(info->subactionPath!=XR_NULL_PATH&&RoleForPath(s->instance,info->subactionPath)!=role)continue;
    if(!ActionAllowsRole(a,role)||!ActionHasBindingForRole(a,role))continue;
    WVRDXMTHapticV1 request{};request.role=role;request.amplitude=vibration->amplitude;request.frequencyHz=vibration->frequency;
    request.durationSeconds=vibration->duration==XR_MIN_HAPTIC_DURATION?0.05f:std::min(static_cast<float>(vibration->duration/1.0e9),5.0f);
    if(FAILED(SubmitSessionHaptic(s, &request)))return XR_ERROR_RUNTIME_FAILURE;submitted=true;
  }
  return submitted?XR_SUCCESS:XR_ERROR_PATH_UNSUPPORTED;
}
XrResult XRAPI_CALL StopHapticFeedback(XrSession h,const XrHapticActionInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_HAPTIC_ACTION_INFO)return XR_ERROR_VALIDATION_FAILURE;
  auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_VIBRATION_OUTPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;
  if(info->subactionPath!=XR_NULL_PATH&&std::find(a->subactionPaths.begin(),a->subactionPaths.end(),info->subactionPath)==a->subactionPaths.end())return XR_ERROR_PATH_UNSUPPORTED;
  bool submitted=false;
  for(uint32_t role:{kControllerLeft,kControllerRight}){
    if(info->subactionPath!=XR_NULL_PATH&&RoleForPath(s->instance,info->subactionPath)!=role)continue;
    if(!ActionAllowsRole(a,role)||!ActionHasBindingForRole(a,role))continue;
    WVRDXMTHapticV1 request{};request.role=role;if(FAILED(SubmitSessionHaptic(s, &request)))return XR_ERROR_RUNTIME_FAILURE;submitted=true;
  }
  return submitted?XR_SUCCESS:XR_ERROR_PATH_UNSUPPORTED;
}

XrResult XRAPI_CALL EnumerateEnvironmentBlendModes(XrInstance h,XrSystemId sys,XrViewConfigurationType type,uint32_t cap,uint32_t*count,XrEnvironmentBlendMode*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;const XrEnvironmentBlendMode mode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;return EnumerateOne(&mode,cap,count,out,sizeof(mode));}

XrResult XRAPI_CALL GetGraphicsRequirementsD3D12KHR(XrInstance h,XrSystemId sys,XrGraphicsRequirementsD3D12KHR*out){
  auto*i=GetInstance(h);
  if(!i||sys!=i->system)return XR_ERROR_SYSTEM_INVALID;
  if(!out||out->type!=XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR)return XR_ERROR_VALIDATION_FAILURE;
  if(!i->d3d12Enabled)return XR_ERROR_EXTENSION_NOT_PRESENT;
  if(!i->d3d12BackendAvailable)return XR_ERROR_RUNTIME_FAILURE;
  ID3D12Device*device=nullptr;
  if(FAILED(CreateOptionalD3D12Device(nullptr,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))||!device){
    if(device)device->Release();return XR_ERROR_RUNTIME_FAILURE;
  }
  const LUID adapterLuid=device->GetAdapterLuid();
  const D3D_FEATURE_LEVEL minimumFeatureLevel=D3D_FEATURE_LEVEL_11_0;
  device->Release();
  out->adapterLuid=adapterLuid;
  out->minFeatureLevel=minimumFeatureLevel;
  i->d3d12AdapterLuid=adapterLuid;
  i->d3d12MinFeatureLevel=minimumFeatureLevel;
  i->d3d12GraphicsRequirementsQueried=true;
  return XR_SUCCESS;
}

XrResult XRAPI_CALL GetGraphicsRequirementsD3D11KHR(XrInstance h,XrSystemId sys,XrGraphicsRequirementsD3D11KHR*out){
  auto*i=GetInstance(h);if(!i||sys!=i->system)return XR_ERROR_SYSTEM_INVALID;
  if(!out||out->type!=XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR)return XR_ERROR_VALIDATION_FAILURE;
  if(!i->d3d11Enabled)return XR_ERROR_EXTENSION_NOT_PRESENT;
  ID3D11Device*device=nullptr;ID3D11DeviceContext*context=nullptr;D3D_FEATURE_LEVEL feature{};
  HRESULT hr=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,&feature,&context);
  if(FAILED(hr)||!device){if(context)context->Release();if(device)device->Release();return XR_ERROR_RUNTIME_FAILURE;}
  IDXGIDevice*dxgiDevice=nullptr;IDXGIAdapter*adapter=nullptr;DXGI_ADAPTER_DESC desc{};
  if(SUCCEEDED(device->QueryInterface(__uuidof(IDXGIDevice),reinterpret_cast<void**>(&dxgiDevice)))&&
     SUCCEEDED(dxgiDevice->GetAdapter(&adapter))&&SUCCEEDED(adapter->GetDesc(&desc)))out->adapterLuid=desc.AdapterLuid;
  else {if(adapter)adapter->Release();if(dxgiDevice)dxgiDevice->Release();if(context)context->Release();device->Release();return XR_ERROR_RUNTIME_FAILURE;}
  adapter->Release();dxgiDevice->Release();if(context)context->Release();device->Release();
  out->minFeatureLevel=D3D_FEATURE_LEVEL_11_0;i->graphicsRequirementsQueried=true;return XR_SUCCESS;
}

#define MAP_XR(apiName, functionName) if (std::strcmp(name,#apiName)==0) { *out=reinterpret_cast<PFN_xrVoidFunction>(&functionName); return XR_SUCCESS; }
XrResult XRAPI_CALL GetInstanceProcAddr(XrInstance instance,const char*name,PFN_xrVoidFunction*out){if(!name||!out)return XR_ERROR_VALIDATION_FAILURE;*out=nullptr;if(instance!=XR_NULL_HANDLE&&!GetInstance(instance))return XR_ERROR_HANDLE_INVALID;if(instance==XR_NULL_HANDLE&&std::strcmp(name,"xrGetInstanceProcAddr")!=0&&std::strcmp(name,"xrEnumerateInstanceExtensionProperties")!=0&&std::strcmp(name,"xrEnumerateApiLayerProperties")!=0&&std::strcmp(name,"xrCreateInstance")!=0)return XR_ERROR_FUNCTION_UNSUPPORTED;
  if(std::strcmp(name,"xrGetD3D12GraphicsRequirementsKHR")==0 && !GetInstance(instance)->d3d12Enabled)
    return XR_ERROR_FUNCTION_UNSUPPORTED;
  if(std::strcmp(name,"xrGetD3D11GraphicsRequirementsKHR")==0 && !GetInstance(instance)->d3d11Enabled)
    return XR_ERROR_FUNCTION_UNSUPPORTED;
  MAP_XR(xrGetInstanceProcAddr,GetInstanceProcAddr)
  MAP_XR(xrEnumerateInstanceExtensionProperties,EnumerateInstanceExtensionProperties) MAP_XR(xrEnumerateApiLayerProperties,EnumerateApiLayerProperties) MAP_XR(xrCreateInstance,CreateInstance) MAP_XR(xrDestroyInstance,DestroyInstance)
  MAP_XR(xrGetInstanceProperties,GetInstanceProperties) MAP_XR(xrResultToString,ResultToString) MAP_XR(xrStructureTypeToString,StructureTypeToString) MAP_XR(xrGetSystem,GetSystem) MAP_XR(xrGetSystemProperties,GetSystemProperties) MAP_XR(xrEnumerateViewConfigurations,EnumerateViewConfigurations) MAP_XR(xrGetViewConfigurationProperties,GetViewConfigurationProperties) MAP_XR(xrEnumerateViewConfigurationViews,EnumerateViewConfigurationViews) MAP_XR(xrEnumerateEnvironmentBlendModes,EnumerateEnvironmentBlendModes)
  MAP_XR(xrPollEvent,PollEvent) MAP_XR(xrCreateSession,CreateSession) MAP_XR(xrDestroySession,DestroySession) MAP_XR(xrBeginSession,BeginSession) MAP_XR(xrEndSession,EndSession) MAP_XR(xrRequestExitSession,RequestExitSession) MAP_XR(xrGetInputSourceLocalizedName,GetInputSourceLocalizedName)
  MAP_XR(xrEnumerateReferenceSpaces,EnumerateReferenceSpaces) MAP_XR(xrGetReferenceSpaceBoundsRect,GetReferenceSpaceBoundsRect) MAP_XR(xrCreateReferenceSpace,CreateReferenceSpace) MAP_XR(xrCreateActionSpace,CreateActionSpace) MAP_XR(xrLocateSpace,LocateSpace) MAP_XR(xrDestroySpace,DestroySpace)
  MAP_XR(xrStringToPath,StringToPath) MAP_XR(xrPathToString,PathToString) MAP_XR(xrCreateActionSet,CreateActionSet) MAP_XR(xrDestroyActionSet,DestroyActionSet) MAP_XR(xrCreateAction,CreateAction) MAP_XR(xrDestroyAction,DestroyAction) MAP_XR(xrSuggestInteractionProfileBindings,SuggestInteractionProfileBindings) MAP_XR(xrAttachSessionActionSets,AttachSessionActionSets) MAP_XR(xrGetCurrentInteractionProfile,GetCurrentInteractionProfile)
  MAP_XR(xrSyncActions,SyncActions) MAP_XR(xrGetActionStateBoolean,GetActionStateBoolean) MAP_XR(xrGetActionStateFloat,GetActionStateFloat) MAP_XR(xrGetActionStateVector2f,GetActionStateVector2f) MAP_XR(xrGetActionStatePose,GetActionStatePose) MAP_XR(xrEnumerateBoundSourcesForAction,EnumerateBoundSourcesForAction) MAP_XR(xrApplyHapticFeedback,ApplyHapticFeedback) MAP_XR(xrStopHapticFeedback,StopHapticFeedback)
  MAP_XR(xrEnumerateSwapchainFormats,EnumerateSwapchainFormats) MAP_XR(xrCreateSwapchain,CreateSwapchain) MAP_XR(xrDestroySwapchain,DestroySwapchain) MAP_XR(xrEnumerateSwapchainImages,EnumerateSwapchainImages) MAP_XR(xrAcquireSwapchainImage,AcquireSwapchainImage) MAP_XR(xrWaitSwapchainImage,WaitSwapchainImage) MAP_XR(xrReleaseSwapchainImage,ReleaseSwapchainImage)
  MAP_XR(xrWaitFrame,WaitFrame) MAP_XR(xrBeginFrame,BeginFrame) MAP_XR(xrEndFrame,EndFrame) MAP_XR(xrLocateViews,LocateViews) MAP_XR(xrGetD3D11GraphicsRequirementsKHR,GetGraphicsRequirementsD3D11KHR) MAP_XR(xrGetD3D12GraphicsRequirementsKHR,GetGraphicsRequirementsD3D12KHR)
  return XR_ERROR_FUNCTION_UNSUPPORTED;
}
#undef MAP_XR
} // namespace

WVR_EXPORT XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo*loader,XrNegotiateRuntimeRequest*request){if(!loader||!request||loader->structType!=XR_LOADER_INTERFACE_STRUCT_LOADER_INFO||request->structType!=XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST||loader->maxInterfaceVersion<XR_CURRENT_LOADER_RUNTIME_VERSION)return XR_ERROR_INITIALIZATION_FAILED;request->runtimeInterfaceVersion=XR_CURRENT_LOADER_RUNTIME_VERSION;request->runtimeApiVersion=std::min(loader->maxApiVersion,XR_API_VERSION_1_0);request->getInstanceProcAddr=GetInstanceProcAddr;return XR_SUCCESS;}

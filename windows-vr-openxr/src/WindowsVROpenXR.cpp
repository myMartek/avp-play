#define XR_USE_GRAPHICS_API_D3D11
#define XR_NO_PROTOTYPES
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include <WindowsVRD3D11ContextExt.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <chrono>
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
struct Image { ID3D11Texture2D *texture = nullptr; bool acquired = false; uint64_t lastReleasedFrame = 0; };

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
  bool d3d11Enabled = false;
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
  bool begun = false;
  bool frameBegun = false;
  uint64_t frameIndex = 0;
  XrTime predictedTime = 0;
  XrTime lastWaitTrackingTime = 0;
  XrSessionState state = XR_SESSION_STATE_IDLE;
  std::mutex eventMutex;
  bool actionSetsAttached = false;
  std::vector<XrActionSet> attachedActionSets;
  std::vector<XrActionSet> activeActionSets;
  std::unordered_map<XrActionSet, XrPath> activeSetSubactions;
  ControllerSample controllers{};
  std::vector<SessionEvent> events;
  std::vector<Swapchain *> swapchains;
};
struct Swapchain {
  uint64_t magic = kMagicSwapchain;
  Session *session = nullptr;
  XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
  std::vector<Image> images;
  uint32_t nextImage = 0;
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
  if (found->second.rfind("/user/hand/left", 0) == 0) return kControllerLeft;
  if (found->second.rfind("/user/hand/right", 0) == 0) return kControllerRight;
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

uint32_t ActionRole(Action *action) {
  if (!action || !action->set || !action->set->instance) return UINT32_MAX;
  Instance *instance=action->set->instance;
  for(XrPath path:action->bindingPaths){uint32_t role=RoleForPath(instance,path);if(role!=UINT32_MAX)return role;}
  for(XrPath path:action->subactionPaths){uint32_t role=RoleForPath(instance,path);if(role!=UINT32_MAX)return role;}
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
  ActionValue value{};value.lastChangeTime=static_cast<XrTime>(controller.timestampNanoseconds);
  if(action->type==XR_ACTION_TYPE_POSE_INPUT){value.boolean=(controller.flags&5u)==5u;return value;}
  Instance*instance=action->set->instance;
  for(XrPath bindingPath:action->bindingPaths){
    if(RoleForPath(instance,bindingPath)!=role)continue;
    auto path=instance->pathStrings.find(bindingPath);if(path==instance->pathStrings.end())continue;
    const std::string&name=path->second;
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT){const uint64_t bit=ButtonForBinding(name);if(bit)value.boolean=(controller.buttons&bit)!=0;}
    else if(action->type==XR_ACTION_TYPE_FLOAT_INPUT){
      if(name.find("/input/trigger/value")!=std::string::npos)value.scalar=controller.trigger;
      else if(name.find("/input/squeeze/value")!=std::string::npos||name.find("/input/grip/value")!=std::string::npos)value.scalar=controller.grip;
      else {const uint64_t bit=ButtonForBinding(name);if(bit)value.scalar=(controller.buttons&bit)?1.0f:0.0f;}
    } else if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT){
      if(name.find("/input/thumbstick")!=std::string::npos){value.vector={controller.thumbstickX,controller.thumbstickY};}
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
  session->state = state;
  if (!time && session->dxmt) {
    WVRDXMTTrackingV1 tracking{};
    if (SUCCEEDED(session->dxmt->GetWindowsVRTracking(&tracking))) time=static_cast<XrTime>(tracking.timestampNanoseconds);
  }
  session->events.push_back({state, time ? time : MonotonicTimeNanoseconds()});
}

bool QueryTargets(WVRDXMTTargetInfoV1 &targets) {
  // The D3D11 device is the guest-side DXMT entry point. Use a temporary
  // default device so enumeration can read the compositor target contract
  // before the application creates its session graphics binding. The WMT
  // request ABI remains host-only and is never imported by this PE runtime.
  ID3D11Device *device=nullptr;ID3D11DeviceContext *context=nullptr;D3D_FEATURE_LEVEL feature{};
  if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,&feature,&context))||!device||!context){if(context)context->Release();if(device)device->Release();return false;}
  IMTLD3D11ContextExt2 *extension=nullptr;
  const HRESULT query=context->QueryInterface(kIIDMTLD3D11ContextExt2,reinterpret_cast<void**>(&extension));
  bool available=false;
  if(SUCCEEDED(query)&&extension){available=SUCCEEDED(extension->GetWindowsVRTargets(&targets));extension->Release();}
  context->Release();device->Release();
  return available&&targets.width[0]&&targets.height[0]&&targets.width[1]&&targets.height[1]&&targets.generation;
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
  if (format == 70) return DXGI_FORMAT_R8G8B8A8_UNORM;
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
    if(role==UINT32_MAX)return false;
    WVRDXMTControllerV1 controller{};
    if(FAILED(session->dxmt->GetWindowsVRController(role,&controller))||(controller.flags&5u)!=5u)return false;
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
  XrExtensionProperties prop{XR_TYPE_EXTENSION_PROPERTIES};
  std::strncpy(prop.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME, XR_MAX_EXTENSION_NAME_SIZE - 1);
  prop.extensionVersion = XR_KHR_D3D11_enable_SPEC_VERSION;
  return EnumerateOne(&prop, cap, count, out, sizeof(prop));
}
XrResult XRAPI_CALL EnumerateApiLayerProperties(uint32_t, uint32_t *count, XrApiLayerProperties *) { if (!count) return XR_ERROR_VALIDATION_FAILURE; *count=0; return XR_SUCCESS; }
XrResult XRAPI_CALL CreateInstance(const XrInstanceCreateInfo *info, XrInstance *out) {
  if (!info || !out || info->type != XR_TYPE_INSTANCE_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
  if(info->enabledApiLayerCount!=0)return XR_ERROR_API_LAYER_NOT_PRESENT;
  if (XR_VERSION_MAJOR(info->applicationInfo.apiVersion) != 1 ||
      (XR_VERSION_MAJOR(info->applicationInfo.apiVersion) == 1 && XR_VERSION_MINOR(info->applicationInfo.apiVersion) > 0))
    return XR_ERROR_API_VERSION_UNSUPPORTED;
  bool d3d11Enabled = false;
  for (uint32_t i=0;i<info->enabledExtensionCount;i++) {
    if (!info->enabledExtensionNames || !info->enabledExtensionNames[i]) return XR_ERROR_VALIDATION_FAILURE;
    if (std::strcmp(info->enabledExtensionNames[i], XR_KHR_D3D11_ENABLE_EXTENSION_NAME) == 0) d3d11Enabled = true;
    else return XR_ERROR_EXTENSION_NOT_PRESENT;
  }
  auto p=std::make_unique<Instance>();
  p->d3d11Enabled = d3d11Enabled;
  std::strncpy(p->properties.runtimeName,"AVP Play Windows VR",XR_MAX_RUNTIME_NAME_SIZE-1);
  p->properties.runtimeVersion=XR_MAKE_VERSION(0,1,0);
  if (!QueryTargets(p->targets)) return XR_ERROR_RUNTIME_FAILURE;
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
XrResult XRAPI_CALL GetSystemProperties(XrInstance h,XrSystemId sys,XrSystemProperties *out) { auto *p=GetInstance(h); if(!p||sys!=p->system) return XR_ERROR_SYSTEM_INVALID;if(!out||out->type!=XR_TYPE_SYSTEM_PROPERTIES)return XR_ERROR_VALIDATION_FAILURE;out->systemId=sys;out->vendorId=0x415650;std::strncpy(out->systemName,"Windows VR Headset",XR_MAX_SYSTEM_NAME_SIZE-1);out->graphicsProperties.maxSwapchainImageHeight=std::max(p->targets.height[0],p->targets.height[1]);out->graphicsProperties.maxSwapchainImageWidth=std::max(p->targets.width[0],p->targets.width[1]);out->graphicsProperties.maxLayerCount=1;out->trackingProperties.orientationTracking=XR_TRUE;out->trackingProperties.positionTracking=XR_TRUE;return XR_SUCCESS; }
XrResult XRAPI_CALL EnumerateViewConfigurations(XrInstance h,XrSystemId sys,uint32_t cap,uint32_t *count,XrViewConfigurationType *out) { auto*p=GetInstance(h); if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID; XrViewConfigurationType t=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO; return EnumerateOne(&t,cap,count,out,sizeof(t)); }
XrResult XRAPI_CALL GetViewConfigurationProperties(XrInstance h,XrSystemId sys,XrViewConfigurationType type,XrViewConfigurationProperties*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;if(!out||out->type!=XR_TYPE_VIEW_CONFIGURATION_PROPERTIES)return XR_ERROR_VALIDATION_FAILURE;out->viewConfigurationType=type;out->fovMutable=XR_FALSE;return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateViewConfigurationViews(XrInstance h,XrSystemId sys,XrViewConfigurationType type,uint32_t cap,uint32_t*count,XrViewConfigurationView*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO||!count)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;*count=2;if(cap==0)return XR_SUCCESS;if(cap<2)return XR_ERROR_SIZE_INSUFFICIENT;if(!out)return XR_ERROR_VALIDATION_FAILURE;for(uint32_t i=0;i<2;i++){if(out[i].type!=XR_TYPE_VIEW_CONFIGURATION_VIEW)return XR_ERROR_VALIDATION_FAILURE;out[i].recommendedImageRectWidth=p->targets.width[i];out[i].maxImageRectWidth=p->targets.width[i];out[i].recommendedImageRectHeight=p->targets.height[i];out[i].maxImageRectHeight=p->targets.height[i];out[i].recommendedSwapchainSampleCount=1;out[i].maxSwapchainSampleCount=1;}return XR_SUCCESS;}

XrResult XRAPI_CALL CreateSession(XrInstance ih,const XrSessionCreateInfo *info,XrSession*out){
  auto*i=GetInstance(ih);if(!i||!info||!out||info->type!=XR_TYPE_SESSION_CREATE_INFO||info->systemId!=i->system)return XR_ERROR_SYSTEM_INVALID;
  if(!i->d3d11Enabled)return XR_ERROR_EXTENSION_NOT_PRESENT;
  auto *binding=reinterpret_cast<const XrGraphicsBindingD3D11KHR*>(info->next);
  if(!binding||binding->type!=XR_TYPE_GRAPHICS_BINDING_D3D11_KHR||!binding->device)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
  ID3D11DeviceContext*context=nullptr;binding->device->GetImmediateContext(&context);if(!context)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
  IMTLD3D11ContextExt2*ext=nullptr;if(FAILED(context->QueryInterface(kIIDMTLD3D11ContextExt2,reinterpret_cast<void**>(&ext)))){context->Release();return XR_ERROR_GRAPHICS_DEVICE_INVALID;}
  WVRDXMTTargetInfoV1 currentTargets{};
  if (FAILED(ext->GetWindowsVRTargets(&currentTargets)) || currentTargets.generation != i->targets.generation) {
    ext->Release(); context->Release(); return XR_ERROR_RUNTIME_FAILURE;
  }
  auto s=std::make_unique<Session>();s->instance=i;s->device=binding->device;s->device->AddRef();s->context=context;s->dxmt=ext;
  Session*raw=s.get();QueueSessionState(raw,XR_SESSION_STATE_READY);
  {std::lock_guard<std::mutex>l(g_mutex);g_sessions.push_back(std::move(s));}RegisterHandle(raw);
  *out=reinterpret_cast<XrSession>(raw);return XR_SUCCESS;
}
XrResult XRAPI_CALL DestroySession(XrSession h){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(s->begun)return XR_ERROR_SESSION_RUNNING;if(!s->swapchains.empty())return XR_ERROR_CALL_ORDER_INVALID;std::lock_guard<std::mutex>l(g_mutex);for(auto it=g_spaces.begin();it!=g_spaces.end();){if((*it)->session==s){UnregisterHandle(it->get());(*it)->magic=0;it=g_spaces.erase(it);}else ++it;}UnregisterHandle(s);s->magic=0;if(s->dxmt)s->dxmt->Release();if(s->context)s->context->Release();if(s->device)s->device->Release();g_sessions.erase(std::remove_if(g_sessions.begin(),g_sessions.end(),[s](auto&x){return x.get()==s;}),g_sessions.end());return XR_SUCCESS;}
XrResult XRAPI_CALL BeginSession(XrSession h,const XrSessionBeginInfo*info){auto*s=GetSession(h);if(!s||!info)return XR_ERROR_HANDLE_INVALID;if(info->type!=XR_TYPE_SESSION_BEGIN_INFO)return XR_ERROR_VALIDATION_FAILURE;if(info->primaryViewConfigurationType!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;if(s->begun||s->state!=XR_SESSION_STATE_READY)return XR_ERROR_SESSION_NOT_READY;s->begun=true;QueueSessionState(s,XR_SESSION_STATE_SYNCHRONIZED);QueueSessionState(s,XR_SESSION_STATE_VISIBLE);QueueSessionState(s,XR_SESSION_STATE_FOCUSED);return XR_SUCCESS;}
XrResult XRAPI_CALL EndSession(XrSession h){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;if(!s->begun)return XR_ERROR_SESSION_NOT_RUNNING;s->begun=false;QueueSessionState(s,XR_SESSION_STATE_STOPPING);QueueSessionState(s,XR_SESSION_STATE_IDLE);return XR_SUCCESS;}
XrResult XRAPI_CALL RequestExitSession(XrSession h){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!s->begun)return XR_ERROR_SESSION_NOT_RUNNING;QueueSessionState(s,XR_SESSION_STATE_EXITING);return XR_SUCCESS;}
XrResult XRAPI_CALL CreateReferenceSpace(XrSession h,const XrReferenceSpaceCreateInfo*info,XrSpace*out){auto*s=GetSession(h);if(!s||!info||!out)return XR_ERROR_HANDLE_INVALID;if(info->type!=XR_TYPE_REFERENCE_SPACE_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;if(info->referenceSpaceType!=XR_REFERENCE_SPACE_TYPE_LOCAL&&info->referenceSpaceType!=XR_REFERENCE_SPACE_TYPE_VIEW)return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;auto p=std::make_unique<Space>();p->session=s;p->type=info->referenceSpaceType;p->poseInReferenceSpace=info->poseInReferenceSpace;Space*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_spaces.push_back(std::move(p));}RegisterHandle(raw);*out=reinterpret_cast<XrSpace>(raw);return XR_SUCCESS;}
XrResult XRAPI_CALL DestroySpace(XrSpace h){auto*p=GetSpace(h);if(!p)return XR_ERROR_HANDLE_INVALID;std::lock_guard<std::mutex>l(g_mutex);UnregisterHandle(p);p->magic=0;g_spaces.erase(std::remove_if(g_spaces.begin(),g_spaces.end(),[p](auto&x){return x.get()==p;}),g_spaces.end());return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateSwapchainFormats(XrSession h,uint32_t cap,uint32_t*count,int64_t*out){auto*s=GetSession(h);if(!s||!count)return XR_ERROR_HANDLE_INVALID;DXGI_FORMAT f=FormatForMetal(s->instance->targets.pixelFormat[0]);if(f==DXGI_FORMAT_UNKNOWN)return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;int64_t fmt=f;return EnumerateOne(&fmt,cap,count,out,sizeof(fmt));}
XrResult XRAPI_CALL CreateSwapchain(XrSession h,const XrSwapchainCreateInfo*info,XrSwapchain*out){auto*s=GetSession(h);if(!s||!info||!out)return XR_ERROR_HANDLE_INVALID;if(info->type!=XR_TYPE_SWAPCHAIN_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;if(info->arraySize!=1||info->faceCount!=1||info->mipCount!=1||info->sampleCount!=1||!(info->usageFlags&XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT))return XR_ERROR_FEATURE_UNSUPPORTED;DXGI_FORMAT format=FormatForMetal(s->instance->targets.pixelFormat[0]);if(info->format!=format)return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;WVRDXMTTargetInfoV1 targets{};if(FAILED(s->dxmt->GetWindowsVRTargets(&targets))||targets.generation!=s->instance->targets.generation)return XR_ERROR_RUNTIME_FAILURE;if(info->width!=targets.width[0]||info->height!=targets.height[0])return XR_ERROR_SWAPCHAIN_RECT_INVALID;auto p=std::make_unique<Swapchain>();p->session=s;p->info=*info;p->targetGeneration=targets.generation;p->images.resize(kImageCount);D3D11_TEXTURE2D_DESC d{};d.Width=info->width;d.Height=info->height;d.MipLevels=1;d.ArraySize=1;d.Format=(DXGI_FORMAT)info->format;d.SampleDesc.Count=1;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;for(auto&image:p->images)if(FAILED(s->device->CreateTexture2D(&d,nullptr,&image.texture))||!image.texture){for(auto&allocated:p->images)if(allocated.texture)allocated.texture->Release();return XR_ERROR_RUNTIME_FAILURE;}Swapchain*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_swapchains.push_back(std::move(p));s->swapchains.push_back(raw);}RegisterHandle(raw);*out=reinterpret_cast<XrSwapchain>(raw);return XR_SUCCESS;}
XrResult XRAPI_CALL DestroySwapchain(XrSwapchain h){auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;for(auto&i:p->images)if(i.acquired)return XR_ERROR_CALL_ORDER_INVALID;std::lock_guard<std::mutex>l(g_mutex);for(auto&i:p->images)if(i.texture)i.texture->Release();UnregisterHandle(p);p->magic=0;auto*s=p->session;if(s)s->swapchains.erase(std::remove(s->swapchains.begin(),s->swapchains.end(),p),s->swapchains.end());g_swapchains.erase(std::remove_if(g_swapchains.begin(),g_swapchains.end(),[p](auto&x){return x.get()==p;}),g_swapchains.end());return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateSwapchainImages(XrSwapchain h,uint32_t cap,uint32_t*count,XrSwapchainImageBaseHeader*out){auto*p=GetSwapchain(h);if(!p||!count)return XR_ERROR_HANDLE_INVALID;*count=(uint32_t)p->images.size();if(cap==0)return XR_SUCCESS;if(cap<p->images.size())return XR_ERROR_SIZE_INSUFFICIENT;if(!out)return XR_ERROR_VALIDATION_FAILURE;for(uint32_t i=0;i<p->images.size();i++){auto*x=reinterpret_cast<XrSwapchainImageD3D11KHR*>(reinterpret_cast<char*>(out)+i*sizeof(XrSwapchainImageD3D11KHR));if(x->type!=XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR)return XR_ERROR_VALIDATION_FAILURE;x->texture=p->images[i].texture;}return XR_SUCCESS;}
XrResult XRAPI_CALL AcquireSwapchainImage(XrSwapchain h,const XrSwapchainImageAcquireInfo*,uint32_t*out){auto*p=GetSwapchain(h);if(!p||!out)return XR_ERROR_HANDLE_INVALID;for(uint32_t n=0;n<p->images.size();n++){uint32_t i=(p->nextImage+n)%p->images.size();if(!p->images[i].acquired){p->images[i].acquired=true;p->nextImage=(i+1)%p->images.size();*out=i;return XR_SUCCESS;}}return XR_ERROR_CALL_ORDER_INVALID;}
XrResult XRAPI_CALL WaitSwapchainImage(XrSwapchain h,const XrSwapchainImageWaitInfo*info){auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;auto it=std::find_if(p->images.begin(),p->images.end(),[](const Image&i){return i.acquired;});if(it==p->images.end())return XR_ERROR_CALL_ORDER_INVALID;HRESULT hr=p->session->dxmt->WaitWindowsVRImage(it->texture);return SUCCEEDED(hr)?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;}
XrResult XRAPI_CALL ReleaseSwapchainImage(XrSwapchain h,const XrSwapchainImageReleaseInfo*){auto*p=GetSwapchain(h);if(!p)return XR_ERROR_HANDLE_INVALID;for(auto&i:p->images)if(i.acquired){i.acquired=false;i.lastReleasedFrame=p->session->frameIndex;return XR_SUCCESS;}return XR_ERROR_CALL_ORDER_INVALID;}
XrResult XRAPI_CALL WaitFrame(XrSession h,const XrFrameWaitInfo*info,XrFrameState*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_FRAME_WAIT_INFO||!out||out->type!=XR_TYPE_FRAME_STATE)return XR_ERROR_VALIDATION_FAILURE;
  if(!s->begun||s->frameBegun)return XR_ERROR_SESSION_NOT_RUNNING;
  WVRDXMTTrackingV1 tracking{};
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::nanoseconds(kMaximumWait);
  do {
    if(FAILED(s->dxmt->GetWindowsVRTracking(&tracking)))return XR_ERROR_RUNTIME_FAILURE;
    if((tracking.flags&1u)!=0 && tracking.timestampNanoseconds>s->lastWaitTrackingTime)break;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while(std::chrono::steady_clock::now()<deadline);
  if((tracking.flags&1u)==0||tracking.timestampNanoseconds<=s->lastWaitTrackingTime)return XR_ERROR_RUNTIME_FAILURE;
  // Do not compare host compositor timestamps to guest steady_clock: Wine's
  // clock epoch need not match CACurrentMediaTime. Freshness is established by
  // observing a strictly newer host timestamp within the bounded wait above.
  s->lastWaitTrackingTime=static_cast<XrTime>(tracking.timestampNanoseconds);
  const XrTime previousTime=s->predictedTime;
  s->predictedTime=s->lastWaitTrackingTime;
  s->frameIndex++;
  XrDuration period=11'111'111;
  if(previousTime>0&&s->predictedTime>previousTime){
    const XrTime observed=s->predictedTime-previousTime;
    if(observed>=4'000'000&&observed<=50'000'000)period=observed;
  }
  out->predictedDisplayTime=s->predictedTime;
  out->predictedDisplayPeriod=period;
  out->shouldRender=XR_TRUE;
  return XR_SUCCESS;
}
XrResult XRAPI_CALL BeginFrame(XrSession h,const XrFrameBeginInfo*info){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_FRAME_BEGIN_INFO)return XR_ERROR_VALIDATION_FAILURE;if(!s->begun||s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;s->frameBegun=true;return XR_SUCCESS;}
XrResult XRAPI_CALL EndFrame(XrSession h,const XrFrameEndInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_FRAME_END_INFO||!s->frameBegun)return XR_ERROR_CALL_ORDER_INVALID;
  s->frameBegun=false;
  if(info->displayTime!=s->predictedTime)return XR_ERROR_TIME_INVALID;
  if(info->next)return XR_ERROR_FEATURE_UNSUPPORTED;
  if(info->layerCount==0)return XR_SUCCESS;
  if(info->layerCount!=1||!info->layers||info->environmentBlendMode!=XR_ENVIRONMENT_BLEND_MODE_OPAQUE)return XR_ERROR_LAYER_INVALID;
  auto*layer=reinterpret_cast<const XrCompositionLayerProjection*>(info->layers[0]);
  if(!layer||layer->type!=XR_TYPE_COMPOSITION_LAYER_PROJECTION||layer->next||layer->viewCount!=2||!layer->views)return XR_ERROR_LAYER_INVALID;
  auto*compositionSpace=GetSpace(layer->space);if(!compositionSpace||compositionSpace->session!=s)return XR_ERROR_HANDLE_INVALID;
  WVRDXMTTargetInfoV1 targets{};
  if(FAILED(s->dxmt->GetWindowsVRTargets(&targets)))return XR_ERROR_RUNTIME_FAILURE;
  ID3D11Resource*eyes[2]{};
  for(uint32_t eye=0;eye<2;eye++){
    const auto&v=layer->views[eye];
    if(v.type!=XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW||v.next)return XR_ERROR_FEATURE_UNSUPPORTED;
    auto*sw=GetSwapchain(v.subImage.swapchain);
    if(!sw||sw->session!=s||v.subImage.imageArrayIndex!=0||sw->targetGeneration!=targets.generation)return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    const auto&rect=v.subImage.imageRect;
    if(rect.offset.x!=0||rect.offset.y!=0||rect.extent.width!=(int32_t)sw->info.width||rect.extent.height!=(int32_t)sw->info.height)return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    if(sw->info.width!=targets.width[eye]||sw->info.height!=targets.height[eye])return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    auto image=std::find_if(sw->images.begin(),sw->images.end(),[&](const Image&i){return !i.acquired&&i.lastReleasedFrame==s->frameIndex;});
    if(image==sw->images.end())return XR_ERROR_CALL_ORDER_INVALID;
    eyes[eye]=image->texture;
  }
  if(eyes[0]==eyes[1])return XR_ERROR_LAYER_INVALID;
  WVRDXMTSubmitFrameV1 frame{};frame.left=eyes[0];frame.right=eyes[1];frame.targetGeneration=targets.generation;frame.frameID=g_frameID.fetch_add(1);frame.timestampNanoseconds=static_cast<uint64_t>(info->displayTime);
  HRESULT hr=s->dxmt->SubmitWindowsVRFrame(&frame);
  return SUCCEEDED(hr)?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;
}
XrResult XRAPI_CALL LocateViews(XrSession h,const XrViewLocateInfo*info,XrViewState*state,uint32_t cap,uint32_t*count,XrView*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;
  if(!info||info->type!=XR_TYPE_VIEW_LOCATE_INFO||!state||state->type!=XR_TYPE_VIEW_STATE||!count||info->viewConfigurationType!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VALIDATION_FAILURE;
  auto*base=GetSpace(info->space);if(!base||base->session!=s)return XR_ERROR_HANDLE_INVALID;
  WVRDXMTTrackingV1 t{};if(FAILED(s->dxmt->GetWindowsVRTracking(&t)))return XR_ERROR_RUNTIME_FAILURE;
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
  for(auto&entry:g_sessions){auto*session=entry.get();if(session->instance!=instance)continue;std::lock_guard<std::mutex> eventLock(session->eventMutex);if(session->events.empty())continue;
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

XrResult XRAPI_CALL CreateActionSpace(XrSession h,const XrActionSpaceCreateInfo*info,XrSpace*out){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_ACTION_SPACE_CREATE_INFO||!out)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_POSE_INPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;
  auto p=std::make_unique<Space>();p->session=s;p->action=info->action;p->subactionPath=info->subactionPath;p->poseInActionSpace=info->poseInActionSpace;Space*raw=p.get();{std::lock_guard<std::mutex>l(g_mutex);g_spaces.push_back(std::move(p));}RegisterHandle(raw);*out=reinterpret_cast<XrSpace>(raw);return XR_SUCCESS;
}

XrResult XRAPI_CALL LocateSpace(XrSpace spaceHandle,XrSpace baseHandle,XrTime time,XrSpaceLocation*out){
  auto*space=GetSpace(spaceHandle);auto*base=GetSpace(baseHandle);if(!space||!base)return XR_ERROR_HANDLE_INVALID;if(space->session!=base->session)return XR_ERROR_HANDLE_INVALID;if(time<=0||!out||out->type!=XR_TYPE_SPACE_LOCATION)return XR_ERROR_VALIDATION_FAILURE;
  auto*s=space->session;WVRDXMTTrackingV1 tracking{};if(FAILED(s->dxmt->GetWindowsVRTracking(&tracking)))return XR_ERROR_RUNTIME_FAILURE;
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
  if(info->actionType<XR_ACTION_TYPE_BOOLEAN_INPUT||info->actionType>XR_ACTION_TYPE_VIBRATION_OUTPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;
  if(info->countSubactionPaths&&!info->subactionPaths)return XR_ERROR_VALIDATION_FAILURE;auto action=std::make_unique<Action>();action->set=set;action->name=name;action->type=info->actionType;
  for(uint32_t n=0;n<info->countSubactionPaths;n++){if(RoleForPath(set->instance,info->subactionPaths[n])==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;action->subactionPaths.push_back(info->subactionPaths[n]);}
  Action*raw=action.get();{std::lock_guard<std::mutex>lock(set->instance->mutex);set->instance->actions.push_back(std::move(action));set->actions.push_back(reinterpret_cast<XrAction>(raw));}RegisterHandle(raw);*out=reinterpret_cast<XrAction>(raw);return XR_SUCCESS;
}
XrResult XRAPI_CALL DestroyAction(XrAction h){auto*action=GetAction(h);if(!action)return XR_ERROR_HANDLE_INVALID;Instance*i=action->set->instance;std::lock_guard<std::mutex>lock(i->mutex);UnregisterHandle(action);action->magic=0;action->set->actions.erase(std::remove(action->set->actions.begin(),action->set->actions.end(),h),action->set->actions.end());for(auto it=i->bindings.begin();it!=i->bindings.end();)if(it->second==h)it=i->bindings.erase(it);else ++it;i->actions.erase(std::remove_if(i->actions.begin(),i->actions.end(),[action](const auto&value){return value.get()==action;}),i->actions.end());return XR_SUCCESS;}
XrResult XRAPI_CALL SuggestInteractionProfileBindings(XrInstance h,const XrInteractionProfileSuggestedBinding*info){
  auto*i=GetInstance(h);if(!i)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING||(info->countSuggestedBindings&&!info->suggestedBindings))return XR_ERROR_VALIDATION_FAILURE;
  auto profile=i->pathStrings.find(info->interactionProfile);if(profile==i->pathStrings.end()||profile->second.rfind("/interaction_profiles/",0)!=0)return XR_ERROR_PATH_UNSUPPORTED;
  for(uint32_t n=0;n<info->countSuggestedBindings;n++){Action*a=GetAction(info->suggestedBindings[n].action);if(!a||a->set->instance!=i)return XR_ERROR_HANDLE_INVALID;auto binding=i->pathStrings.find(info->suggestedBindings[n].binding);if(binding==i->pathStrings.end()||RoleForPath(i,info->suggestedBindings[n].binding)==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;}
  std::lock_guard<std::mutex>lock(i->mutex);for(uint32_t n=0;n<info->countSuggestedBindings;n++){const auto&binding=info->suggestedBindings[n];i->bindings[binding.binding]=binding.action;auto*a=GetAction(binding.action);if(a&&std::find(a->bindingPaths.begin(),a->bindingPaths.end(),binding.binding)==a->bindingPaths.end())a->bindingPaths.push_back(binding.binding);}const XrPath left=UserPathForRole(i,kControllerLeft),right=UserPathForRole(i,kControllerRight);i->interactionProfiles[left]=info->interactionProfile;i->interactionProfiles[right]=info->interactionProfile;return XR_SUCCESS;
}
XrResult XRAPI_CALL AttachSessionActionSets(XrSession h,const XrSessionActionSetsAttachInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO||(info->countActionSets&&!info->actionSets))return XR_ERROR_VALIDATION_FAILURE;if(s->actionSetsAttached)return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
  for(uint32_t n=0;n<info->countActionSets;n++){auto*set=GetActionSet(info->actionSets[n]);if(!set||set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(std::find(s->attachedActionSets.begin(),s->attachedActionSets.end(),info->actionSets[n])!=s->attachedActionSets.end())return XR_ERROR_VALIDATION_FAILURE;s->attachedActionSets.push_back(info->actionSets[n]);}
  s->actionSetsAttached=true;return XR_SUCCESS;
}
XrResult XRAPI_CALL GetCurrentInteractionProfile(XrSession h,XrPath userPath,XrInteractionProfileState*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_INTERACTION_PROFILE_STATE)return XR_ERROR_VALIDATION_FAILURE;if(RoleForPath(s->instance,userPath)==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;auto found=s->instance->interactionProfiles.find(userPath);out->interactionProfile=found==s->instance->interactionProfiles.end()?XR_NULL_PATH:found->second;return XR_SUCCESS;}
XrResult XRAPI_CALL SyncActions(XrSession h,const XrActionsSyncInfo*info){
  auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_ACTIONS_SYNC_INFO||(info->countActiveActionSets&&!info->activeActionSets))return XR_ERROR_VALIDATION_FAILURE;if(!s->actionSetsAttached)return XR_ERROR_ACTIONSET_NOT_ATTACHED;
  s->activeActionSets.clear();s->activeSetSubactions.clear();for(uint32_t n=0;n<info->countActiveActionSets;n++){auto*set=GetActionSet(info->activeActionSets[n].actionSet);if(!set||set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(std::find(s->attachedActionSets.begin(),s->attachedActionSets.end(),info->activeActionSets[n].actionSet)==s->attachedActionSets.end())return XR_ERROR_ACTIONSET_NOT_ATTACHED;if(info->activeActionSets[n].subactionPath!=XR_NULL_PATH&&RoleForPath(s->instance,info->activeActionSets[n].subactionPath)==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;s->activeActionSets.push_back(info->activeActionSets[n].actionSet);s->activeSetSubactions[info->activeActionSets[n].actionSet]=info->activeActionSets[n].subactionPath;}
  if(FAILED(s->dxmt->GetWindowsVRController(kControllerLeft,&s->controllers.left))||FAILED(s->dxmt->GetWindowsVRController(kControllerRight,&s->controllers.right)))return XR_ERROR_RUNTIME_FAILURE;
  for(auto&setPtr:s->instance->actionSets){auto*set=setPtr.get();if(!ActionSetIsActive(s,set))continue;for(XrAction handle:set->actions){auto*action=GetAction(handle);if(!action||action->type==XR_ACTION_TYPE_VIBRATION_OUTPUT)continue;for(uint32_t role:{kControllerLeft,kControllerRight}){bool applicable=action->subactionPaths.empty()||std::any_of(action->subactionPaths.begin(),action->subactionPaths.end(),[&](XrPath path){return RoleForPath(s->instance,path)==role;});auto activePath=s->activeSetSubactions[reinterpret_cast<XrActionSet>(set)];if(activePath!=XR_NULL_PATH&&RoleForPath(s->instance,activePath)!=role)applicable=false;if(applicable)UpdateActionSnapshot(action,role,role==kControllerLeft?s->controllers.left:s->controllers.right);}}}
  return XR_SUCCESS;
}

bool GetActionSnapshot(Session*s,const XrActionStateGetInfo*info,XrActionType expected,Action*&action,uint32_t&role,ActionValue*&value,bool&active){
  if(!info||info->type!=XR_TYPE_ACTION_STATE_GET_INFO)return false;action=GetAction(info->action);if(!action||action->set->instance!=s->instance||action->type!=expected)return false;if(info->subactionPath!=XR_NULL_PATH&&!action->subactionPaths.empty()&&std::find(action->subactionPaths.begin(),action->subactionPaths.end(),info->subactionPath)==action->subactionPaths.end())return false;role=RoleForPath(s->instance,info->subactionPath);if(role==UINT32_MAX)role=ActionRole(action);if(role==UINT32_MAX)return false;active=ActionSetIsActive(s,action->set);auto activePath=s->activeSetSubactions.find(reinterpret_cast<XrActionSet>(action->set));if(activePath!=s->activeSetSubactions.end()&&activePath->second!=XR_NULL_PATH&&RoleForPath(s->instance,activePath->second)!=role)active=false;const auto&controller=role==kControllerLeft?s->controllers.left:s->controllers.right;active=active&&ControllerConnected(controller);auto found=action->values.find(role);if(found==action->values.end()){ActionValue initial=SampleAction(action,role,controller);found=action->values.emplace(role,initial).first;}value=&found->second;return true;
}
XrResult XRAPI_CALL GetActionStateBoolean(XrSession h,const XrActionStateGetInfo*info,XrActionStateBoolean*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_BOOLEAN)return XR_ERROR_VALIDATION_FAILURE;Action*a;uint32_t role;ActionValue*v;bool active;if(!GetActionSnapshot(s,info,XR_ACTION_TYPE_BOOLEAN_INPUT,a,role,v,active))return XR_ERROR_ACTION_TYPE_MISMATCH;out->currentState=active&&v->boolean;out->changedSinceLastSync=active&&v->changed;out->lastChangeTime=v->lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStateFloat(XrSession h,const XrActionStateGetInfo*info,XrActionStateFloat*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_FLOAT)return XR_ERROR_VALIDATION_FAILURE;Action*a;uint32_t role;ActionValue*v;bool active;if(!GetActionSnapshot(s,info,XR_ACTION_TYPE_FLOAT_INPUT,a,role,v,active))return XR_ERROR_ACTION_TYPE_MISMATCH;out->currentState=active?v->scalar:0;out->changedSinceLastSync=active&&v->changed;out->lastChangeTime=v->lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStateVector2f(XrSession h,const XrActionStateGetInfo*info,XrActionStateVector2f*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_VECTOR2F)return XR_ERROR_VALIDATION_FAILURE;Action*a;uint32_t role;ActionValue*v;bool active;if(!GetActionSnapshot(s,info,XR_ACTION_TYPE_VECTOR2F_INPUT,a,role,v,active))return XR_ERROR_ACTION_TYPE_MISMATCH;out->currentState=active?v->vector:XrVector2f{0,0};out->changedSinceLastSync=active&&v->changed;out->lastChangeTime=v->lastChangeTime;out->isActive=active;return XR_SUCCESS;}
XrResult XRAPI_CALL GetActionStatePose(XrSession h,const XrActionStateGetInfo*info,XrActionStatePose*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!out||out->type!=XR_TYPE_ACTION_STATE_POSE)return XR_ERROR_VALIDATION_FAILURE;Action*a;uint32_t role;ActionValue*v;bool active;if(!GetActionSnapshot(s,info,XR_ACTION_TYPE_POSE_INPUT,a,role,v,active))return XR_ERROR_ACTION_TYPE_MISMATCH;out->isActive=active&&v->boolean;return XR_SUCCESS;}
XrResult XRAPI_CALL EnumerateBoundSourcesForAction(XrSession h,const XrBoundSourcesForActionEnumerateInfo*info,uint32_t capacity,uint32_t*count,XrPath*out){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO||!count)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;*count=static_cast<uint32_t>(a->bindingPaths.size());if(capacity==0)return XR_SUCCESS;if(capacity<*count)return XR_ERROR_SIZE_INSUFFICIENT;if(*count&&!out)return XR_ERROR_VALIDATION_FAILURE;std::copy(a->bindingPaths.begin(),a->bindingPaths.end(),out);return XR_SUCCESS;}
XrResult XRAPI_CALL ApplyHapticFeedback(XrSession h,const XrHapticActionInfo*info,const XrHapticBaseHeader*feedback){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_HAPTIC_ACTION_INFO||!feedback||feedback->type!=XR_TYPE_HAPTIC_VIBRATION)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_VIBRATION_OUTPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;uint32_t role=info->subactionPath==XR_NULL_PATH?ActionRole(a):RoleForPath(s->instance,info->subactionPath);if(role==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;const auto*vibration=reinterpret_cast<const XrHapticVibration*>(feedback);if(vibration->amplitude<0.0f||vibration->amplitude>1.0f||(vibration->duration<0&&vibration->duration!=XR_MIN_HAPTIC_DURATION)||vibration->frequency<XR_FREQUENCY_UNSPECIFIED)return XR_ERROR_VALIDATION_FAILURE;WVRDXMTHapticV1 request{};request.role=role;request.amplitude=vibration->amplitude;request.frequencyHz=vibration->frequency;request.durationSeconds=vibration->duration==XR_MIN_HAPTIC_DURATION?0.05f:std::min(static_cast<float>(vibration->duration/1.0e9),5.0f);return SUCCEEDED(s->dxmt->SubmitWindowsVRHaptic(&request))?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;}
XrResult XRAPI_CALL StopHapticFeedback(XrSession h,const XrHapticActionInfo*info){auto*s=GetSession(h);if(!s)return XR_ERROR_HANDLE_INVALID;if(!info||info->type!=XR_TYPE_HAPTIC_ACTION_INFO)return XR_ERROR_VALIDATION_FAILURE;auto*a=GetAction(info->action);if(!a||a->set->instance!=s->instance)return XR_ERROR_HANDLE_INVALID;if(a->type!=XR_ACTION_TYPE_VIBRATION_OUTPUT)return XR_ERROR_ACTION_TYPE_MISMATCH;uint32_t role=info->subactionPath==XR_NULL_PATH?ActionRole(a):RoleForPath(s->instance,info->subactionPath);if(role==UINT32_MAX)return XR_ERROR_PATH_UNSUPPORTED;WVRDXMTHapticV1 request{};request.role=role;return SUCCEEDED(s->dxmt->SubmitWindowsVRHaptic(&request))?XR_SUCCESS:XR_ERROR_RUNTIME_FAILURE;}

XrResult XRAPI_CALL EnumerateEnvironmentBlendModes(XrInstance h,XrSystemId sys,XrViewConfigurationType type,uint32_t cap,uint32_t*count,XrEnvironmentBlendMode*out){auto*p=GetInstance(h);if(!p||sys!=p->system)return XR_ERROR_SYSTEM_INVALID;if(type!=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;const XrEnvironmentBlendMode mode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;return EnumerateOne(&mode,cap,count,out,sizeof(mode));}

XrResult XRAPI_CALL GetGraphicsRequirementsD3D11KHR(XrInstance h,XrSystemId sys,XrGraphicsRequirementsD3D11KHR*out){
  auto*i=GetInstance(h);if(!i||sys!=i->system)return XR_ERROR_SYSTEM_INVALID;if(!out||out->type!=XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR)return XR_ERROR_VALIDATION_FAILURE;
  ID3D11Device*device=nullptr;ID3D11DeviceContext*context=nullptr;D3D_FEATURE_LEVEL feature{};HRESULT hr=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,&feature,&context);if(FAILED(hr)||!device){if(context)context->Release();if(device)device->Release();return XR_ERROR_RUNTIME_FAILURE;}
  IDXGIDevice*dxgiDevice=nullptr;IDXGIAdapter*adapter=nullptr;DXGI_ADAPTER_DESC desc{};if(SUCCEEDED(device->QueryInterface(__uuidof(IDXGIDevice),reinterpret_cast<void**>(&dxgiDevice)))&&SUCCEEDED(dxgiDevice->GetAdapter(&adapter))&&SUCCEEDED(adapter->GetDesc(&desc)))out->adapterLuid=desc.AdapterLuid;else {if(adapter)adapter->Release();if(dxgiDevice)dxgiDevice->Release();if(context)context->Release();device->Release();return XR_ERROR_RUNTIME_FAILURE;}
  adapter->Release();dxgiDevice->Release();if(context)context->Release();device->Release();out->minFeatureLevel=D3D_FEATURE_LEVEL_11_0;return XR_SUCCESS;
}

#define MAP_XR(apiName, functionName) if (std::strcmp(name,#apiName)==0) { *out=reinterpret_cast<PFN_xrVoidFunction>(&functionName); return XR_SUCCESS; }
XrResult XRAPI_CALL GetInstanceProcAddr(XrInstance instance,const char*name,PFN_xrVoidFunction*out){if(!name||!out)return XR_ERROR_VALIDATION_FAILURE;*out=nullptr;if(instance!=XR_NULL_HANDLE&&!GetInstance(instance))return XR_ERROR_HANDLE_INVALID;
  MAP_XR(xrGetInstanceProcAddr,GetInstanceProcAddr)
  MAP_XR(xrEnumerateInstanceExtensionProperties,EnumerateInstanceExtensionProperties) MAP_XR(xrEnumerateApiLayerProperties,EnumerateApiLayerProperties) MAP_XR(xrCreateInstance,CreateInstance) MAP_XR(xrDestroyInstance,DestroyInstance)
  MAP_XR(xrGetInstanceProperties,GetInstanceProperties) MAP_XR(xrGetSystem,GetSystem) MAP_XR(xrGetSystemProperties,GetSystemProperties) MAP_XR(xrEnumerateViewConfigurations,EnumerateViewConfigurations) MAP_XR(xrGetViewConfigurationProperties,GetViewConfigurationProperties) MAP_XR(xrEnumerateViewConfigurationViews,EnumerateViewConfigurationViews) MAP_XR(xrEnumerateEnvironmentBlendModes,EnumerateEnvironmentBlendModes)
  MAP_XR(xrPollEvent,PollEvent) MAP_XR(xrCreateSession,CreateSession) MAP_XR(xrDestroySession,DestroySession) MAP_XR(xrBeginSession,BeginSession) MAP_XR(xrEndSession,EndSession) MAP_XR(xrRequestExitSession,RequestExitSession)
  MAP_XR(xrEnumerateReferenceSpaces,EnumerateReferenceSpaces) MAP_XR(xrGetReferenceSpaceBoundsRect,GetReferenceSpaceBoundsRect) MAP_XR(xrCreateReferenceSpace,CreateReferenceSpace) MAP_XR(xrCreateActionSpace,CreateActionSpace) MAP_XR(xrLocateSpace,LocateSpace) MAP_XR(xrDestroySpace,DestroySpace)
  MAP_XR(xrStringToPath,StringToPath) MAP_XR(xrPathToString,PathToString) MAP_XR(xrCreateActionSet,CreateActionSet) MAP_XR(xrDestroyActionSet,DestroyActionSet) MAP_XR(xrCreateAction,CreateAction) MAP_XR(xrDestroyAction,DestroyAction) MAP_XR(xrSuggestInteractionProfileBindings,SuggestInteractionProfileBindings) MAP_XR(xrAttachSessionActionSets,AttachSessionActionSets) MAP_XR(xrGetCurrentInteractionProfile,GetCurrentInteractionProfile)
  MAP_XR(xrSyncActions,SyncActions) MAP_XR(xrGetActionStateBoolean,GetActionStateBoolean) MAP_XR(xrGetActionStateFloat,GetActionStateFloat) MAP_XR(xrGetActionStateVector2f,GetActionStateVector2f) MAP_XR(xrGetActionStatePose,GetActionStatePose) MAP_XR(xrEnumerateBoundSourcesForAction,EnumerateBoundSourcesForAction) MAP_XR(xrApplyHapticFeedback,ApplyHapticFeedback) MAP_XR(xrStopHapticFeedback,StopHapticFeedback)
  MAP_XR(xrEnumerateSwapchainFormats,EnumerateSwapchainFormats) MAP_XR(xrCreateSwapchain,CreateSwapchain) MAP_XR(xrDestroySwapchain,DestroySwapchain) MAP_XR(xrEnumerateSwapchainImages,EnumerateSwapchainImages) MAP_XR(xrAcquireSwapchainImage,AcquireSwapchainImage) MAP_XR(xrWaitSwapchainImage,WaitSwapchainImage) MAP_XR(xrReleaseSwapchainImage,ReleaseSwapchainImage)
  MAP_XR(xrWaitFrame,WaitFrame) MAP_XR(xrBeginFrame,BeginFrame) MAP_XR(xrEndFrame,EndFrame) MAP_XR(xrLocateViews,LocateViews) MAP_XR(xrGetD3D11GraphicsRequirementsKHR,GetGraphicsRequirementsD3D11KHR)
  return XR_ERROR_FUNCTION_UNSUPPORTED;
}
#undef MAP_XR
} // namespace

WVR_EXPORT XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo*loader,XrNegotiateRuntimeRequest*request){if(!loader||!request||loader->structType!=XR_LOADER_INTERFACE_STRUCT_LOADER_INFO||request->structType!=XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST||loader->maxInterfaceVersion<XR_CURRENT_LOADER_RUNTIME_VERSION)return XR_ERROR_INITIALIZATION_FAILED;request->runtimeInterfaceVersion=XR_CURRENT_LOADER_RUNTIME_VERSION;request->runtimeApiVersion=std::min(loader->maxApiVersion,XR_API_VERSION_1_0);request->getInstanceProcAddr=GetInstanceProcAddr;return XR_SUCCESS;}

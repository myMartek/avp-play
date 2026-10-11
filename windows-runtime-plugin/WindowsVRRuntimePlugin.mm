#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <unistd.h>

#include <atomic>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "WindowsVRRuntimePlugin.h"
#include "WindowsVRCompositorBridge.h"
#include "WineProcessBridge.h"
#include "WineServerBridge.h"
#include "JITAllocator.h"
#include "FEXBridge.h"

extern "C" __attribute__((visibility("default")))
const uint32_t windows_vr_runtime_abi_version = WINDOWS_VR_RUNTIME_ABI_VERSION;

namespace {

enum class RuntimeState : int32_t {
    idle = 0,
    preparing = 1,
    startingWineServer = 2,
    launchingWine = 3,
    running = 4,
    stopping = 5,
    stopped = 6,
    failed = 7,
};

struct LaunchRequest {
    std::string backend;
    std::string graphics;
    std::string gameDirectory;
    std::string executablePath;
    std::vector<std::string> arguments;
    std::vector<std::pair<std::string, std::string>> environment;
};

std::mutex g_mutex;
std::atomic<RuntimeState> g_state{RuntimeState::idle};
std::atomic<bool> g_launchConsumed{false};
std::string g_lastError;

void SetError(const std::string &message, RuntimeState state = RuntimeState::failed) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_lastError = message;
    }
    g_state.store(state, std::memory_order_release);
}

bool IsString(id value) { return [value isKindOfClass:[NSString class]]; }

bool ReadString(NSDictionary *dict, NSString *key, std::string &out, bool required = true) {
    id value = dict[key];
    if (!value && !required) { out.clear(); return true; }
    if (!IsString(value)) return false;
    const char *utf8 = [value UTF8String];
    if (!utf8 || std::strlen(utf8) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return false;
    out.assign(utf8);
    return out.find('\0') == std::string::npos;
}

bool IsContainedPath(const std::string &candidate, const std::string &root) {
    NSString *candidatePath = [[NSString stringWithUTF8String:candidate.c_str()] stringByResolvingSymlinksInPath];
    NSString *rootPath = [[NSString stringWithUTF8String:root.c_str()] stringByResolvingSymlinksInPath];
    if (!candidatePath || !rootPath) return false;
    NSString *prefix = [rootPath hasSuffix:@"/"] ? rootPath : [rootPath stringByAppendingString:@"/"];
    return [candidatePath isEqualToString:rootPath] || [candidatePath hasPrefix:prefix];
}

bool IsSafeRelativePath(const std::string &relative) {
    if (relative.empty() || relative.front() == '/' || relative.front() == '\\' ||
        relative.find('\0') != std::string::npos || relative.find(':') != std::string::npos)
        return false;
    size_t start = 0;
    while (start <= relative.size()) {
        size_t end = relative.find_first_of("/\\", start);
        std::string part = relative.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}

bool ReadPEMachine(const std::string &path, uint16_t &machine) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    unsigned char dos[64] = {};
    unsigned char header[6] = {};
    bool ok = std::fread(dos, 1, sizeof(dos), file) == sizeof(dos) && dos[0] == 'M' && dos[1] == 'Z';
    uint32_t offset = static_cast<uint32_t>(dos[0x3c]) |
                      (static_cast<uint32_t>(dos[0x3d]) << 8) |
                      (static_cast<uint32_t>(dos[0x3e]) << 16) |
                      (static_cast<uint32_t>(dos[0x3f]) << 24);
    if (ok && offset <= (16u << 20) && std::fseek(file, static_cast<long>(offset), SEEK_SET) == 0 &&
        std::fread(header, 1, sizeof(header), file) == sizeof(header) &&
        header[0] == 'P' && header[1] == 'E' && header[2] == 0 && header[3] == 0) {
        machine = static_cast<uint16_t>(header[4] | (header[5] << 8));
    } else {
        ok = false;
    }
    std::fclose(file);
    return ok;
}

bool IsAllowedEnvironmentKey(const std::string &key) {
    if (key.empty() || !((key[0] >= 'A' && key[0] <= 'Z') || (key[0] >= 'a' && key[0] <= 'z') || key[0] == '_'))
        return false;
    for (char c : key) {
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_')) return false;
    }
    auto starts = [&key](const char *prefix) { return key.rfind(prefix, 0) == 0; };
    return key != "HOME" && key != "WINEPREFIX" && key != "WINESERVERSOCKET" &&
           key != "VR_OVERRIDE" && key != "XR_RUNTIME_JSON" &&
           key != "WVR_REQUIRE_COMPOSITOR_DEVICE" &&
           key != "WINEDLLPATH" && !starts("DYLD_") && !starts("WINE_IOS_JIT_") &&
           !starts("MADEIRA_");
}

bool InstallGuestOpenXRRuntime(uint16_t machine, NSString *driveC, std::string &runtimeABI,
                               std::string &error) {
    // OpenComposite currently ships only an x64 guest build. ARM64EC is a
    // separate package and may only be selected for an ARM64EC PE image.
    if (machine == 0x8664) runtimeABI = "x64";
    else if (machine == 0xA641) runtimeABI = "arm64ec";
    else {
        error = "No OpenComposite/OpenXR runtime package is available for this PE machine type.";
        return false;
    }

    NSString *guestRoot = [[[NSBundle mainBundle] resourceURL] URLByAppendingPathComponent:
        [NSString stringWithFormat:@"WindowsVR/Guest/%s", runtimeABI.c_str()]].path;
    NSString *openComposite = [guestRoot stringByAppendingPathComponent:@"OpenComposite"];
    NSString *clientDLL = [openComposite stringByAppendingPathComponent:@"bin/vrclient_x64.dll"];
    NSString *runtimeDLL = [guestRoot stringByAppendingPathComponent:@"wvr_openxr.dll"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *clientInfo = [fm attributesOfItemAtPath:clientDLL error:nil];
    NSDictionary *runtimeInfo = [fm attributesOfItemAtPath:runtimeDLL error:nil];
    if (![clientInfo[NSFileType] isEqualToString:NSFileTypeRegular] ||
        ![runtimeInfo[NSFileType] isEqualToString:NSFileTypeRegular]) {
        error = "The app bundle is missing the selected guest OpenXR package (OpenComposite client and wvr_openxr.dll required).";
        return false;
    }
    const uint16_t expectedMachine = machine;
    uint16_t clientMachine = 0, runtimeMachine = 0;
    if (!ReadPEMachine(clientDLL.fileSystemRepresentation, clientMachine) ||
        !ReadPEMachine(runtimeDLL.fileSystemRepresentation, runtimeMachine)) {
        error = "The bundled OpenComposite client or wvr_openxr.dll is not a readable PE image.";
        return false;
    }
    if (clientMachine != expectedMachine || runtimeMachine != expectedMachine) {
        error = "The bundled OpenComposite client and wvr_openxr.dll must both match the selected game's PE machine type.";
        return false;
    }

    NSString *guestRuntime = [[driveC stringByAppendingPathComponent:@"windows-vr-runtime"]
        stringByAppendingPathComponent:[NSString stringWithUTF8String:runtimeABI.c_str()]];
    NSString *guestOpenComposite = [guestRuntime stringByAppendingPathComponent:@"OpenComposite"];
    NSString *guestRuntimeDLL = [guestRuntime stringByAppendingPathComponent:@"wvr_openxr.dll"];
    NSError *fsError = nil;
    if (![fm createDirectoryAtPath:guestRuntime withIntermediateDirectories:YES attributes:nil error:&fsError]) {
        error = fsError.localizedDescription.UTF8String ?: "Could not create the private guest OpenXR runtime directory.";
        return false;
    }
    // Never replace prefix-owned files or follow an existing prefix symlink.
    if ([fm fileExistsAtPath:guestOpenComposite] || [fm fileExistsAtPath:guestRuntimeDLL]) {
        error = "The private guest OpenXR runtime destination already exists; refusing to replace it.";
        return false;
    }
    if (![fm createSymbolicLinkAtPath:guestOpenComposite withDestinationPath:openComposite error:&fsError] ||
        ![fm createSymbolicLinkAtPath:guestRuntimeDLL withDestinationPath:runtimeDLL error:&fsError]) {
        [fm removeItemAtPath:guestRuntime error:nil];
        error = fsError.localizedDescription.UTF8String ?: "Could not map the app-bundled guest OpenXR runtime into the Wine prefix.";
        return false;
    }

    NSString *manifestPath = [guestRuntime stringByAppendingPathComponent:@"runtime.json"];
    NSDictionary *manifest = @{
        @"file_format_version": @"1.0.0",
        @"runtime": @{
            @"name": @"AVP Play Windows VR Runtime",
            @"library_path": [NSString stringWithFormat:@"C:\\windows-vr-runtime\\%@\\wvr_openxr.dll",
                               [NSString stringWithUTF8String:runtimeABI.c_str()]],
            @"functions": @{ @"xrNegotiateLoaderRuntimeInterface": @"xrNegotiateLoaderRuntimeInterface" }
        }
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:&fsError];
    if (!json || ![json writeToFile:manifestPath options:NSDataWritingAtomic error:&fsError]) {
        [fm removeItemAtPath:guestRuntime error:nil];
        error = fsError.localizedDescription.UTF8String ?: "Could not write the private guest OpenXR runtime manifest.";
        return false;
    }

    setenv("VR_OVERRIDE", ("C:\\windows-vr-runtime\\" + runtimeABI + "\\OpenComposite").c_str(), 1);
    setenv("XR_RUNTIME_JSON", ("C:\\windows-vr-runtime\\" + runtimeABI + "\\runtime.json").c_str(), 1);
    return true;
}

std::vector<std::string> g_gameEnvironmentKeys;

void ClearGameEnvironment(bool hadFEX) {
    std::lock_guard<std::mutex> lock(g_mutex);
    for (const auto &key : g_gameEnvironmentKeys) unsetenv(key.c_str());
    g_gameEnvironmentKeys.clear();
    unsetenv("WINE_IOS_JIT_RX");
    unsetenv("WINE_IOS_JIT_RW");
    unsetenv("WINE_IOS_JIT_SIZE");
    unsetenv("MADEIRA_JIT_WRITE_OFFSET");
    unsetenv("MADEIRA_USE_ARM64EC");
    unsetenv("WVR_REQUIRE_COMPOSITOR_DEVICE");
    if (hadFEX) fex_shutdown();
}

void CleanupLaunch(const std::string &mountPath, bool hadFEX) {
    if (!mountPath.empty()) [[NSFileManager defaultManager] removeItemAtPath:
        [NSString stringWithUTF8String:mountPath.c_str()] error:nil];
    ClearGameEnvironment(hadFEX);
}

bool ParseRequest(const char *json, LaunchRequest &request, std::string &error) {
    if (!json) { error = "Launch request is null."; return false; }
    NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&parseError] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        error = parseError.localizedDescription.UTF8String ?: "Launch request is not a JSON object.";
        return false;
    }
    NSDictionary *dict = object;
    NSNumber *schema = dict[@"schemaVersion"];
    if (![schema isKindOfClass:[NSNumber class]] || schema.intValue != 1 ||
        !ReadString(dict, @"backend", request.backend) ||
        !ReadString(dict, @"graphics", request.graphics) ||
        !ReadString(dict, @"gameDirectory", request.gameDirectory) ||
        !ReadString(dict, @"executablePath", request.executablePath)) {
        error = "Launch request has a missing field or unsupported schema.";
        return false;
    }
    NSArray *arguments = dict[@"arguments"];
    if (![arguments isKindOfClass:[NSArray class]] || arguments.count > 64) {
        error = "Launch request arguments must be an array containing at most 64 strings.";
        return false;
    }
    for (id argument in arguments) {
        if (!IsString(argument)) { error = "Every launch argument must be a string."; return false; }
        const char *utf8 = [argument UTF8String];
        if (!utf8 || std::strlen(utf8) != [argument lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) {
            error = "Launch arguments must be valid UTF-8 without embedded NUL bytes.";
            return false;
        }
        request.arguments.emplace_back(utf8);
    }
    NSDictionary *environment = dict[@"environment"] ?: @{};
    if (![environment isKindOfClass:[NSDictionary class]] || environment.count > 128) {
        error = "Launch environment must be an object containing at most 128 entries.";
        return false;
    }
    for (id key in environment) {
        id value = environment[key];
        if (!IsString(key) || !IsString(value)) { error = "Environment names and values must be strings."; return false; }
        std::string name([key UTF8String] ?: "");
        std::string text([value UTF8String] ?: "");
        if (!IsAllowedEnvironmentKey(name) || text.find('\0') != std::string::npos) {
            error = "Launch environment contains a reserved name or invalid value.";
            return false;
        }
        request.environment.emplace_back(std::move(name), std::move(text));
    }
    return true;
}

int32_t RunRequest(LaunchRequest request) {
    g_state.store(RuntimeState::preparing, std::memory_order_release);
    if (request.graphics != "direct3D11") {
        SetError("This Madeira integration has a Direct3D 11 path only; Vulkan was not selected or emulated.");
        return -1;
    }

    NSURL *gameURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:request.gameDirectory.c_str()]];
    NSURL *executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:request.executablePath.c_str()]];
    if (!IsContainedPath(request.executablePath, request.gameDirectory)) {
        SetError("Executable path escapes the selected game directory.");
        return -1;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:executableURL.path error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
        SetError("The selected executable is missing or is not a regular file.");
        return -1;
    }

    uint16_t machine = 0;
    if (!ReadPEMachine(request.executablePath, machine)) {
        SetError("The selected file is not a readable PE executable.");
        return -1;
    }
    const bool nativeARM64 = request.backend == "nativeARM64";
    if (request.backend != "nativeARM64" && request.backend != "windowsWineFEX") {
        SetError("Requested backend is not supported by the Madeira adapter.");
        return -1;
    }
    if (nativeARM64 ? (machine != 0xAA64 && machine != 0xA641) : (machine != 0x8664 && machine != 0x014c)) {
        SetError("Executable architecture does not match the explicitly selected backend.");
        return -1;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *prefix = [documents stringByAppendingPathComponent:@"wine"];
    NSString *driveC = [prefix stringByAppendingPathComponent:@"drive_c"];
    madeira_seed_prefix_if_needed(prefix.fileSystemRepresentation);
    NSString *systemRegistry = [prefix stringByAppendingPathComponent:@"system.reg"];
    NSString *system32 = [driveC stringByAppendingPathComponent:@"windows/system32"];
    NSString *dosDevicesC = [[prefix stringByAppendingPathComponent:@"dosdevices"] stringByAppendingPathComponent:@"c:"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL prefixReady = [fileManager fileExistsAtPath:systemRegistry] &&
                       [fileManager fileExistsAtPath:system32] &&
                       [fileManager fileExistsAtPath:dosDevicesC];
    if (!prefixReady) {
        SetError("Madeira could not seed a usable Wine prefix. Bundle prefix-template.tar.gz and its system32 runtime resources in the host app.");
        return -1;
    }
    WVRCompositorReadinessV1 compositorReadiness{};
    compositorReadiness.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    compositorReadiness.structSize = sizeof(compositorReadiness);
    if (wvr_compositor_copy_readiness_v1(&compositorReadiness) != WVRCompositorStatusOK ||
        !compositorReadiness.metalDeviceBound || !compositorReadiness.stereoTargetsPublished) {
        SetError("The immersive compositor must publish its Metal device and stereo targets before Wine starts.");
        return -1;
    }
    std::string runtimeABI;
    std::string runtimeError;
    if (!InstallGuestOpenXRRuntime(machine, driveC, runtimeABI, runtimeError)) {
        SetError(runtimeError);
        return -1;
    }

    uint64_t jitRX = 0, jitRW = 0, jitSize = 0;
    // Both Windows backends execute unsigned guest pages through Madeira's
    // debugger-mediated JIT preparation. Native ARM64 skips FEX, not the JIT
    // debugger requirement.
    jit_arm_trap_fallback();
    struct kinfo_proc processInfo = {};
    size_t processInfoSize = sizeof(processInfo);
    int query[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    bool liveDebugger = sysctl(query, 4, &processInfo, &processInfoSize, nullptr, 0) == 0 &&
                        (processInfo.kp_proc.p_flag & P_TRACED) != 0;
    if (!jit_check_debugged() || !liveDebugger) {
        SetError("Madeira requires its script-capable debugger to remain attached for Windows guest execution.");
        return -1;
    }
    if (!nativeARM64) {
        if (!fex_initialize()) {
            SetError("Madeira FEXCore initialization failed while preparing its dual-mapped JIT pool.");
            return -1;
        }
        if (!fex_get_jit_pool_info(&jitRX, &jitRW, &jitSize) || !jitRX || !jitRW || !jitSize) {
            fex_shutdown();
            SetError("Madeira FEXCore initialized without a usable dual-mapped JIT pool.");
            return -1;
        }
    }
    NSString *mountRoot = [driveC stringByAppendingPathComponent:@"windows-vr"];
    NSString *mountName = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *mountPath = [mountRoot stringByAppendingPathComponent:mountName];
    const std::string mountPathUTF8(mountPath.UTF8String ?: "");
    NSError *fsError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:mountRoot withIntermediateDirectories:YES attributes:nil error:&fsError] ||
        ![[NSFileManager defaultManager] createSymbolicLinkAtPath:mountPath withDestinationPath:gameURL.path error:&fsError]) {
        if (!nativeARM64) fex_shutdown();
        SetError(fsError.localizedDescription.UTF8String ?: "Could not map the selected game directory into Wine's C drive.");
        return -1;
    }

    NSString *relative = [executableURL.path substringFromIndex:gameURL.path.length];
    while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
    std::string winExecutable = "C:\\windows-vr\\" + std::string(mountName.UTF8String) + "\\";
    std::string winRelative(relative.UTF8String ?: "");
    for (char &c : winRelative) if (c == '/') c = '\\';
    winExecutable += winRelative;
    std::string winWorkingDirectory = "C:\\windows-vr\\" + std::string(mountName.UTF8String);

    {
        std::lock_guard<std::mutex> lock(g_mutex);
        for (const auto &key : g_gameEnvironmentKeys) unsetenv(key.c_str());
        g_gameEnvironmentKeys.clear();
        for (const auto &entry : request.environment) {
            setenv(entry.first.c_str(), entry.second.c_str(), 1);
            g_gameEnvironmentKeys.push_back(entry.first);
        }
    }
    char address[32];
    if (!nativeARM64) {
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitRX));
        setenv("WINE_IOS_JIT_RX", address, 1);
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitRW));
        setenv("WINE_IOS_JIT_RW", address, 1);
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitSize));
        setenv("WINE_IOS_JIT_SIZE", address, 1);
        std::snprintf(address, sizeof(address), "0x%llx", static_cast<unsigned long long>(jitRW - jitRX));
        setenv("MADEIRA_JIT_WRITE_OFFSET", address, 1);
    } else {
        unsetenv("WINE_IOS_JIT_RX");
        unsetenv("WINE_IOS_JIT_RW");
        unsetenv("WINE_IOS_JIT_SIZE");
        unsetenv("MADEIRA_JIT_WRITE_OFFSET");
    }
    setenv("MADEIRA_USE_ARM64EC", nativeARM64 ? "0" : "1", 1);
    setenv("WVR_REQUIRE_COMPOSITOR_DEVICE", "1", 1);

    std::vector<const char *> argv;
    argv.reserve(request.arguments.size());
    for (const auto &argument : request.arguments) argv.push_back(argument.c_str());
    if (wine_process_configure_launch(winExecutable.c_str(), winWorkingDirectory.c_str(),
                                      static_cast<int>(argv.size()), argv.data(), nativeARM64 ? 1 : 0) != 0) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira rejected the exact executable and argv profile.");
        return -1;
    }

    g_state.store(RuntimeState::startingWineServer, std::memory_order_release);
    if (wineserver_start(prefix.fileSystemRepresentation) != 0) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira failed to create its wineserver thread.");
        return -1;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
    while (wineserver_is_running() && !wineserver_is_ready() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (!wineserver_is_ready()) {
        wineserver_stop(); // Madeira's bridge joins the server thread before returning.
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira wineserver did not become ready before the startup deadline.");
        return -1;
    }

    g_state.store(RuntimeState::launchingWine, std::memory_order_release);
    wine_exit_status_reset();
    if (wine_process_start(prefix.fileSystemRepresentation) != 0) {
        wineserver_stop();
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira failed to start its Wine process thread.");
        return -1;
    }
    g_state.store(RuntimeState::running, std::memory_order_release);
    while (wine_process_is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // WineProcessBridge joins wineserver from its guest thread before reporting stopped.
    uint32_t crashStatus = 0;
    const bool guestCrashed = wine_crash_exit_status(&crashStatus) != 0;
    CleanupLaunch(mountPathUTF8, !nativeARM64);
    if (guestCrashed) {
        char message[96];
        std::snprintf(message, sizeof(message), "Wine reported guest NTSTATUS 0x%08x.", crashStatus);
        SetError(message);
        return -1;
    }
    SetError("", RuntimeState::stopped);
    return 0;
}

} // namespace

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_launch_v1(const char *request_json) {
    LaunchRequest request;
    std::string error;
    if (!ParseRequest(request_json, request, error)) {
        SetError(error);
        return EINVAL;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    RuntimeState state = g_state.load(std::memory_order_acquire);
    if (state == RuntimeState::preparing || state == RuntimeState::startingWineServer ||
        state == RuntimeState::launchingWine || state == RuntimeState::running) {
        g_lastError = "Madeira supports one active Wine session per app process.";
        return EBUSY;
    }
    if (g_launchConsumed.exchange(true, std::memory_order_acq_rel)) {
        g_lastError = "Madeira's FEX JIT pool and Wine process bridge are one-session resources; restart the app before another launch.";
        return EALREADY;
    }
    g_lastError.clear();
    g_state.store(RuntimeState::preparing, std::memory_order_release);
    try {
        std::thread(RunRequest, std::move(request)).detach();
    } catch (...) {
        g_lastError = "Could not create the native launch worker.";
        g_state.store(RuntimeState::failed, std::memory_order_release);
        return EAGAIN;
    }
    return 0;
}

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_stop_v1(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    RuntimeState state = g_state.load(std::memory_order_acquire);
    if (state == RuntimeState::running || state == RuntimeState::launchingWine ||
        state == RuntimeState::startingWineServer || state == RuntimeState::preparing) {
        g_lastError = "Madeira exposes no safe terminate/join API for a live Wine guest; let the guest exit naturally.";
        return EBUSY;
    }
    return 0;
}

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_status_v1(void) {
    return static_cast<int32_t>(g_state.load(std::memory_order_acquire));
}

extern "C" __attribute__((visibility("default"))) uint64_t
windows_vr_last_error_v1(char *buffer, uint64_t capacity) {
    std::lock_guard<std::mutex> lock(g_mutex);
    const uint64_t required = g_lastError.size() + 1;
    if (buffer && capacity) {
        const size_t copied = std::min<size_t>(g_lastError.size(), static_cast<size_t>(capacity - 1));
        std::memcpy(buffer, g_lastError.data(), copied);
        buffer[copied] = 0;
    }
    return required;
}

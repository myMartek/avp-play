#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <unistd.h>
#import <CommonCrypto/CommonDigest.h>

#include <atomic>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <exception>
#include <mutex>
#include <map>
#include <optional>
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

// Optional symbols are provided only by the modern profile-specific native
// DXMT archive. A resource marker cannot turn a baseline archive into D3D12.
extern "C" size_t wvr_dxmt_d3d12_unix_call_count_v1(void) __attribute__((weak_import));
extern "C" uint32_t wvr_dxmt_d3d12_transport_abi_v1(void) __attribute__((weak_import));

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
    std::string gameID;
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
std::atomic<bool> g_stopRequested{false};
std::string g_lastError;
// The Wine bridge uses the process environment. Restore host values on every
// startup failure and natural exit rather than deleting inherited settings.
std::map<std::string, std::optional<std::string>> g_originalEnvironment;

void SetLaunchEnvironment(const char *key, const char *value) {
    if (g_originalEnvironment.find(key) == g_originalEnvironment.end()) {
        const char *original = getenv(key);
        g_originalEnvironment.emplace(key, original ? std::optional<std::string>(original) : std::nullopt);
    }
    if (value) setenv(key, value, 1);
    else unsetenv(key);
}

struct LaunchScope {
    NSString *guestRuntimeDirectory = nil;
    ~LaunchScope() {
        // If the supervisor faults while Wine still runs, process-lifetime
        // retention is safer than tearing down the guest's environment/mappings.
        if (wine_process_is_running()) return;
        if (guestRuntimeDirectory) [[NSFileManager defaultManager] removeItemAtPath:guestRuntimeDirectory error:nil];
        for (const auto &entry : g_originalEnvironment) {
            if (entry.second) setenv(entry.first.c_str(), entry.second->c_str(), 1);
            else unsetenv(entry.first.c_str());
        }
        g_originalEnvironment.clear();
    }
};

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

bool ReadPEInfo(const std::string &path, uint16_t &machine, bool &arm64ec) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    arm64ec = false;
    if (std::fseek(file, 0, SEEK_END) != 0) { std::fclose(file); return false; }
    const long fileLength = std::ftell(file);
    auto readAt = [file, fileLength](uint64_t offset, void *buffer, size_t count) {
        if (fileLength < 0 || offset > static_cast<uint64_t>(fileLength) ||
            count > static_cast<uint64_t>(fileLength) - offset || offset > static_cast<uint64_t>(LONG_MAX)) return false;
        return std::fseek(file, static_cast<long>(offset), SEEK_SET) == 0 &&
               std::fread(buffer, 1, count, file) == count;
    };
    auto u16 = [](const unsigned char *p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); };
    auto u32 = [](const unsigned char *p) {
        return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
    };
    auto u64 = [&u32](const unsigned char *p) {
        return static_cast<uint64_t>(u32(p)) | (static_cast<uint64_t>(u32(p + 4)) << 32);
    };
    unsigned char dos[64] = {};
    bool ok = readAt(0, dos, sizeof(dos)) && dos[0] == 'M' && dos[1] == 'Z';
    const uint32_t peOffset = ok ? u32(dos + 0x3c) : 0;
    unsigned char coff[24] = {};
    ok = ok && peOffset >= sizeof(dos) && peOffset <= (16u << 20) && readAt(peOffset, coff, sizeof(coff)) &&
         coff[0] == 'P' && coff[1] == 'E' && coff[2] == 0 && coff[3] == 0;
    if (ok) {
        machine = u16(coff + 4);
        const uint16_t sectionCount = u16(coff + 6);
        const uint16_t optionalSize = u16(coff + 20);
        std::vector<unsigned char> optional(optionalSize);
        ok = optionalSize >= 112 && readAt(static_cast<uint64_t>(peOffset) + 24, optional.data(), optional.size());
        if (ok && machine == 0xA641) {
            arm64ec = true;
        } else if (ok && machine == 0x8664 && u16(optional.data()) == 0x20b &&
                   u32(optional.data() + 108) > 10 && optionalSize >= 200) {
            const uint64_t imageBase = u64(optional.data() + 24);
            const uint32_t imageSize = u32(optional.data() + 56);
            const uint32_t headersSize = u32(optional.data() + 60);
            const uint32_t loadRVA = u32(optional.data() + 192);
            const uint32_t loadSize = u32(optional.data() + 196);
            struct Section { uint32_t va, span, rawSize, rawOffset; };
            std::vector<Section> sections;
            const uint64_t sectionTable = static_cast<uint64_t>(peOffset) + 24 + optionalSize;
            for (uint16_t index = 0; index < sectionCount && ok; ++index) {
                unsigned char raw[40] = {};
                ok = readAt(sectionTable + static_cast<uint64_t>(index) * 40, raw, sizeof(raw));
                if (ok) {
                    const uint32_t virtualSize = u32(raw + 8), va = u32(raw + 12), rawSize = u32(raw + 16);
                    sections.push_back({va, std::max(virtualSize, rawSize), rawSize, u32(raw + 20)});
                }
            }
            auto rvaToOffset = [&](uint32_t rva, uint32_t count, uint64_t &offset) {
                if (rva < headersSize && static_cast<uint64_t>(rva) + count <= headersSize) {
                    offset = rva;
                    return offset + count <= static_cast<uint64_t>(fileLength);
                }
                for (const auto &section : sections) {
                    if (rva >= section.va && static_cast<uint64_t>(rva) + count <=
                            static_cast<uint64_t>(section.va) + section.span) {
                        const uint64_t delta = rva - section.va;
                        if (delta + count <= section.rawSize) {
                            offset = static_cast<uint64_t>(section.rawOffset) + delta;
                            return offset + count <= static_cast<uint64_t>(fileLength);
                        }
                    }
                }
                return false;
            };
            uint64_t loadOffset = 0;
            unsigned char loadConfig[0xD0] = {};
            if (ok && imageSize && loadRVA && loadSize >= sizeof(loadConfig) &&
                rvaToOffset(loadRVA, sizeof(loadConfig), loadOffset) && readAt(loadOffset, loadConfig, sizeof(loadConfig)) &&
                u32(loadConfig) >= sizeof(loadConfig)) {
                const uint64_t metadataVA = u64(loadConfig + 0xC8);
                if (metadataVA >= imageBase && metadataVA - imageBase < imageSize) {
                    uint64_t metadataOffset = 0;
                    unsigned char version[4] = {};
                    if (rvaToOffset(static_cast<uint32_t>(metadataVA - imageBase), sizeof(version), metadataOffset) &&
                        readAt(metadataOffset, version, sizeof(version))) {
                        const uint32_t value = u32(version);
                        arm64ec = value == 1 || value == 2;
                    }
                }
            }
        }
    }
    std::fclose(file);
    return ok;
}

bool ReadPEMachine(const std::string &path, uint16_t &machine) {
    bool arm64ec = false;
    return ReadPEInfo(path, machine, arm64ec);
}

bool IsARM64ECPE(const std::string &path) {
    uint16_t machine = 0;
    bool arm64ec = false;
    return ReadPEInfo(path, machine, arm64ec) && arm64ec;
}

bool IsX64PE(const std::string &path) {
    uint16_t machine = 0;
    bool arm64ec = false;
    return ReadPEInfo(path, machine, arm64ec) && machine == 0x8664 && !arm64ec;
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
           key != "WVR_REQUIRE_COMPOSITOR_DEVICE" && key != "WVR_GRAPHICS_API" &&
           key != "WINEDLLPATH" && key != "WINEDLLOVERRIDES" && !starts("DYLD_") && !starts("WINE_IOS_JIT_") &&
           !starts("MADEIRA_");
}

bool InstallGuestOpenXRRuntime(uint16_t machine, bool gameARM64EC, NSString *driveC, std::string &runtimeABI,
                               LaunchScope &scope, std::string &error) {
    // OpenComposite currently ships only an x64 guest build. ARM64EC is a
    // separate package and may only be selected for an ARM64EC PE image.
    if (machine == 0x8664 && !gameARM64EC) runtimeABI = "x64";
    else if (machine == 0xA641 || (machine == 0x8664 && gameARM64EC)) runtimeABI = "arm64ec";
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
        ![runtimeInfo[NSFileType] isEqualToString:NSFileTypeRegular] ||
        !IsContainedPath(clientDLL.fileSystemRepresentation, guestRoot.fileSystemRepresentation) ||
        !IsContainedPath(runtimeDLL.fileSystemRepresentation, guestRoot.fileSystemRepresentation)) {
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
    const bool packageARM64EC = IsARM64ECPE(clientDLL.fileSystemRepresentation) &&
                                IsARM64ECPE(runtimeDLL.fileSystemRepresentation);
    const bool packageMachineMatches = gameARM64EC ?
        ((clientMachine == 0x8664 || clientMachine == 0xA641) &&
         (runtimeMachine == 0x8664 || runtimeMachine == 0xA641)) :
        (clientMachine == expectedMachine && runtimeMachine == expectedMachine);
    if (!packageMachineMatches || packageARM64EC != gameARM64EC ||
        (runtimeABI == "x64" && (!IsX64PE(clientDLL.fileSystemRepresentation) ||
                                 !IsX64PE(runtimeDLL.fileSystemRepresentation)))) {
        error = "The bundled OpenComposite client and wvr_openxr.dll must both match the selected game's PE machine type.";
        return false;
    }

    // A previous app process may have exited without cleanup. Never reuse its
    // mappings, overwrite prefix-owned content, or bind this bundle to old DLLs.
    NSString *sessionName = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *guestRelative = [NSString stringWithFormat:@"windows-vr-runtime/%@/%s", sessionName, runtimeABI.c_str()];
    NSString *guestRuntime = [driveC stringByAppendingPathComponent:guestRelative];
    NSString *runtimeParent = [driveC stringByAppendingPathComponent:@"windows-vr-runtime"];
    NSDictionary *parentInfo = [fm attributesOfItemAtPath:runtimeParent error:nil];
    if (parentInfo && ![parentInfo[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        error = "The private guest runtime parent must be a directory, not a symlink or file.";
        return false;
    }
    scope.guestRuntimeDirectory = [runtimeParent stringByAppendingPathComponent:sessionName];
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
            @"library_path": [NSString stringWithFormat:@"C:\\windows-vr-runtime\\%@\\%s\\wvr_openxr.dll",
                               sessionName, runtimeABI.c_str()],
            @"functions": @{ @"xrNegotiateLoaderRuntimeInterface": @"xrNegotiateLoaderRuntimeInterface" }
        }
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:&fsError];
    if (!json || ![json writeToFile:manifestPath options:NSDataWritingAtomic error:&fsError]) {
        [fm removeItemAtPath:guestRuntime error:nil];
        error = fsError.localizedDescription.UTF8String ?: "Could not write the private guest OpenXR runtime manifest.";
        return false;
    }

    const std::string guestWindowsPath = "C:\\windows-vr-runtime\\" + std::string(sessionName.UTF8String) + "\\" + runtimeABI;
    SetLaunchEnvironment("VR_OVERRIDE", (guestWindowsPath + "\\OpenComposite").c_str());
    SetLaunchEnvironment("XR_RUNTIME_JSON", (guestWindowsPath + "\\" + "runtime.json").c_str());
    return true;
}

void ClearGameEnvironment(bool hadFEX) {
    // LaunchScope restores inherited process values after the guest has exited.
    if (hadFEX) fex_shutdown();
}

void CleanupLaunch(const std::string &mountPath, bool hadFEX) {
    if (!mountPath.empty()) [[NSFileManager defaultManager] removeItemAtPath:
        [NSString stringWithUTF8String:mountPath.c_str()] error:nil];
    ClearGameEnvironment(hadFEX);
}

bool ParseRequest(const char *json, LaunchRequest &request, std::string &error) {
    if (!json) { error = "Launch request is null."; return false; }
    if (strnlen(json, 1024 * 1024 + 1) > 1024 * 1024) {
        error = "Launch request exceeds the one MiB limit.";
        return false;
    }
    NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&parseError] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        error = parseError.localizedDescription.UTF8String ?: "Launch request is not a JSON object.";
        return false;
    }
    NSDictionary *dict = object;
    NSNumber *schema = dict[@"schemaVersion"];
    if (![schema isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID() || schema.doubleValue != 1.0 ||
        !ReadString(dict, @"backend", request.backend) ||
        !ReadString(dict, @"graphics", request.graphics) ||
        !ReadString(dict, @"gameDirectory", request.gameDirectory) ||
        !ReadString(dict, @"executablePath", request.executablePath)) {
        error = "Launch request has a missing field or unsupported schema.";
        return false;
    }
    if (!ReadString(dict, @"gameID", request.gameID, false) || request.gameID.size() > 4096 ||
        (dict[@"gameID"] && request.gameID.empty())) {
        error = "Optional gameID must be a nonempty UTF-8 string of at most 4096 bytes.";
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
        if (std::strlen(utf8) > 4096) {
            error = "An individual launch argument exceeds Madeira's 4096-byte limit.";
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
        const char *keyUTF8 = [key UTF8String];
        const char *valueUTF8 = [value UTF8String];
        if (!keyUTF8 || !valueUTF8 ||
            std::strlen(keyUTF8) != [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding] ||
            std::strlen(valueUTF8) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) {
            error = "Environment names and values must be UTF-8 without embedded NUL bytes.";
            return false;
        }
        std::string name(keyUTF8);
        std::string text(valueUTF8);
        if (!IsAllowedEnvironmentKey(name)) {
            error = "Launch environment contains a reserved name or invalid value.";
            return false;
        }
        request.environment.emplace_back(std::move(name), std::move(text));
    }
    return true;
}

// Capability is an app-bundled assembly contract, never supplied by a game.
// The package builder emits this only for a coherent native/guest D3D12 closure.
bool SHA256File(const char *path, std::string &hex) {
    FILE *file = std::fopen(path, "rb");
    if (!file) return false;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536];
    size_t count;
    while ((count = std::fread(buffer, 1, sizeof(buffer), file)) != 0)
        CC_SHA256_Update(&context, buffer, static_cast<CC_LONG>(count));
    const bool ok = std::ferror(file) == 0;
    std::fclose(file);
    if (!ok) return false;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    char encoded[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {};
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index)
        std::snprintf(encoded + index * 2, 3, "%02x", digest[index]);
    hex = encoded;
    return true;
}

bool IsModernDXMTNativeProfile() {
    return wvr_dxmt_d3d12_unix_call_count_v1 && wvr_dxmt_d3d12_transport_abi_v1 &&
           wvr_dxmt_d3d12_unix_call_count_v1() == 148 && wvr_dxmt_d3d12_transport_abi_v1() == 1;
}

bool ValidateD3D12Package() {
    if (!IsModernDXMTNativeProfile()) return false;
    NSURL *resources = [NSBundle mainBundle].resourceURL;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *markerPath = [resources URLByAppendingPathComponent:@"WindowsVR/GraphicsCapabilities.json"].path;
    NSDictionary *attributes = [fm attributesOfItemAtPath:markerPath error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [attributes[NSFileSize] unsignedLongLongValue] > 65536 ||
        !IsContainedPath(markerPath.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "")) return false;
    NSData *data = [NSData dataWithContentsOfFile:markerPath];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) return false;
    NSDictionary *marker = object;
    if (![marker[@"schemaVersion"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)marker[@"schemaVersion"]) == CFBooleanGetTypeID() ||
        [marker[@"schemaVersion"] doubleValue] != 1.0 ||
        ![marker[@"d3d12TransportABI"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)marker[@"d3d12TransportABI"]) == CFBooleanGetTypeID() ||
        [marker[@"d3d12TransportABI"] doubleValue] != 1.0 ||
        ![marker[@"direct3D12"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)marker[@"direct3D12"]) != CFBooleanGetTypeID() ||
        ![marker[@"direct3D12"] boolValue] ||
        ![marker[@"direct3D11"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)marker[@"direct3D11"]) != CFBooleanGetTypeID() ||
        ![marker[@"direct3D11"] boolValue]) return false;
    NSString *receiptPath = [resources URLByAppendingPathComponent:@"WindowsVR/D3D12Experimental/AVPPLAY_DXMT_D3D12_PROFILE.json"].path;
    NSDictionary *receiptInfo = [fm attributesOfItemAtPath:receiptPath error:nil];
    if (![receiptInfo[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [receiptInfo[NSFileSize] unsignedLongLongValue] > 65536 ||
        !IsContainedPath(receiptPath.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "")) return false;
    NSData *receiptData = [NSData dataWithContentsOfFile:receiptPath];
    id receiptObject = receiptData ? [NSJSONSerialization JSONObjectWithData:receiptData options:0 error:nil] : nil;
    if (![receiptObject isKindOfClass:[NSDictionary class]]) return false;
    NSDictionary *receipt = receiptObject;
    if (![receipt[@"profileId"] isEqual:@"dxmt-d3d12-experimental-e94c312f5c054263acf261cfa109edf13e757587"] ||
        ![receipt[@"sourceRevision"] isEqual:@"e94c312f5c054263acf261cfa109edf13e757587"] ||
        ![receipt[@"guestArtifactsSha256"] isKindOfClass:[NSDictionary class]]) return false;
    std::string markerHash;
    if (!SHA256File(markerPath.fileSystemRepresentation, markerHash) ||
        ![receipt[@"graphicsCapabilitiesSha256"] isEqual:[NSString stringWithUTF8String:markerHash.c_str()]]) return false;
    for (NSString *relative in @[@"Runtime/arm64ec-windows/d3d11.dll", @"Runtime/arm64ec-windows/d3d12.dll", @"Runtime/arm64ec-windows/dxgi.dll",
                                 @"Runtime/arm64ec-windows/winemetal.dll"]) {
        NSString *path = [resources URLByAppendingPathComponent:relative].path;
        NSDictionary *info = [fm attributesOfItemAtPath:path error:nil];
        uint16_t machine = 0;
        if (![info[NSFileType] isEqualToString:NSFileTypeRegular] ||
            !IsContainedPath(path.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "") ||
            !IsARM64ECPE(path.fileSystemRepresentation ?: "")) return false;
        std::string artifactHash;
        if (!SHA256File(path.fileSystemRepresentation, artifactHash) ||
            ![receipt[@"guestArtifactsSha256"][relative.lastPathComponent]
                isEqual:[NSString stringWithUTF8String:artifactHash.c_str()]]) return false;
    }
    return true;
}

bool HasD3D12Package() {
    // A signed app bundle is immutable during a process lifetime. Avoid hashing
    // the DLL closure on every SwiftUI capability reevaluation.
    static const bool available = ValidateD3D12Package();
    return available;
}

int32_t PreflightRequest(LaunchRequest &request, std::string &error) {
    if ((wvr_dxmt_d3d12_unix_call_count_v1 || wvr_dxmt_d3d12_transport_abi_v1) && !IsModernDXMTNativeProfile()) {
        error = "The linked modern DXMT native archive has an incompatible dispatch table or transport ABI.";
        return ENOTSUP;
    }
    if (request.backend != "windowsWineFEX" || (request.graphics != "direct3D11" && request.graphics != "direct3D12")) {
        error = "The assembled first runtime supports x64 Wine/FEX with Direct3D 11 or an explicitly packaged experimental DXMT Direct3D 12 backend. Native ARM64/ARM64EC needs a separate matching guest package.";
        return ENOTSUP;
    }
    if (request.graphics == "direct3D11" && IsModernDXMTNativeProfile() && !HasD3D12Package()) {
        error = "The linked modern DXMT archive has no matching D3D11/D3D12 guest package.";
        return ENOTSUP;
    }
    if (request.graphics == "direct3D12" && !HasD3D12Package()) {
        error = "Experimental DXMT D3D12 is not packaged with a matching native/guest transport. No D3D11 fallback was selected.";
        return ENOTSUP;
    }
    NSString *folder = [[NSString stringWithUTF8String:request.gameDirectory.c_str()] stringByResolvingSymlinksInPath];
    NSString *executable = [[NSString stringWithUTF8String:request.executablePath.c_str()] stringByResolvingSymlinksInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *folderAttributes = [fm attributesOfItemAtPath:folder error:nil];
    NSDictionary *executableAttributes = [fm attributesOfItemAtPath:executable error:nil];
    if (![folder isAbsolutePath] || ![executable isAbsolutePath] ||
        ![folderAttributes[NSFileType] isEqualToString:NSFileTypeDirectory] ||
        ![executableAttributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        !IsContainedPath(executable.fileSystemRepresentation ?: "", folder.fileSystemRepresentation ?: "")) {
        error = "The game folder and executable must be readable local files with the executable contained inside the folder.";
        return EINVAL;
    }
    request.gameDirectory = folder.fileSystemRepresentation ?: "";
    request.executablePath = executable.fileSystemRepresentation ?: "";
    NSString *relative = [executable substringFromIndex:folder.length];
    while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
    if (!IsSafeRelativePath(relative.UTF8String ?: "") || [relative lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 350) {
        error = "The executable's relative Windows path is unsafe or exceeds the upstream launch-path buffer.";
        return EINVAL;
    }
    uint16_t machine = 0;
    if (!IsX64PE(request.executablePath)) {
        error = "The first Windows VR runtime requires a readable x64 (AMD64) PE executable.";
        return ENOTSUP;
    }
    NSURL *resources = [NSBundle mainBundle].resourceURL;
    for (NSString *path in @[@"Runtime/prefix-template.tar.gz",
                            @"Runtime/arm64ec-windows/ntdll.dll", @"Runtime/arm64ec-windows/kernel32.dll",
                            @"Runtime/arm64ec-windows/kernelbase.dll", @"Runtime/arm64ec-windows/wineboot.exe",
                            @"Runtime/arm64ec-windows/d3d11.dll", @"Runtime/arm64ec-windows/winemetal.dll",
                            @"Runtime/arm64ec-windows/services.exe", @"Runtime/arm64ec-windows/rpcss.exe"]) {
        NSString *resourcePath = [resources URLByAppendingPathComponent:path].path;
        NSDictionary *attributes = [fm attributesOfItemAtPath:resourcePath error:nil];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] == 0 ||
            !IsContainedPath(resourcePath.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "")) {
            error = "Required app-bundled runtime resource is missing, empty, or unsafe: " + std::string(path.UTF8String ?: "");
            return ENOENT;
        }
    }
    for (NSString *path in @[@"Runtime/nls", @"Runtime/legal"]) {
        NSString *resourcePath = [resources URLByAppendingPathComponent:path].path;
        NSDictionary *attributes = [fm attributesOfItemAtPath:resourcePath error:nil];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeDirectory] ||
            !IsContainedPath(resourcePath.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "")) {
            error = "Required runtime resource directory is missing or unsafe: " + std::string(path.UTF8String ?: "");
            return ENOENT;
        }
    }
    for (NSString *path in @[@"WindowsVR/Guest/x64/OpenComposite/bin/vrclient_x64.dll", @"WindowsVR/Guest/x64/wvr_openxr.dll"]) {
        NSString *resourcePath = [resources URLByAppendingPathComponent:path].path;
        NSDictionary *attributes = [fm attributesOfItemAtPath:resourcePath error:nil];
        uint16_t guestMachine = 0;
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
            !IsContainedPath(resourcePath.fileSystemRepresentation ?: "", resources.path.fileSystemRepresentation ?: "") ||
            !IsX64PE(resourcePath.fileSystemRepresentation ?: "") ||
            !ReadPEMachine(resourcePath.fileSystemRepresentation ?: "", guestMachine) || guestMachine != machine) {
            error = "Required guest runtime DLL is absent or does not match the x64 game: " + std::string(path.UTF8String ?: "");
            return ENOENT;
        }
    }
    return 0;
}

int32_t RunRequest(LaunchRequest request) {
    LaunchScope scope;
    g_state.store(RuntimeState::preparing, std::memory_order_release);
    if ((request.graphics != "direct3D11" && request.graphics != "direct3D12") ||
        (request.graphics == "direct3D12" && !HasD3D12Package())) {
        SetError("The requested graphics backend is not packaged; no graphics fallback was selected.");
        return -1;
    }

    NSURL *gameURL = [[NSURL fileURLWithPath:[NSString stringWithUTF8String:request.gameDirectory.c_str()]] URLByResolvingSymlinksInPath];
    NSURL *executableURL = [[NSURL fileURLWithPath:[NSString stringWithUTF8String:request.executablePath.c_str()]] URLByResolvingSymlinksInPath];
    request.gameDirectory = gameURL.path.fileSystemRepresentation ?: "";
    request.executablePath = executableURL.path.fileSystemRepresentation ?: "";
    NSDictionary *gameAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:gameURL.path error:nil];
    if (![gameAttributes[NSFileType] isEqualToString:NSFileTypeDirectory] || request.gameDirectory.empty()) {
        SetError("The selected game folder is missing or is not a directory.");
        return -1;
    }
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
    bool gameARM64EC = false;
    if (!ReadPEInfo(request.executablePath, machine, gameARM64EC)) {
        SetError("The selected file is not a readable PE executable.");
        return -1;
    }
    const bool nativeARM64 = request.backend == "nativeARM64";
    if (request.backend != "nativeARM64" && request.backend != "windowsWineFEX") {
        SetError("Requested backend is not supported by the Madeira adapter.");
        return -1;
    }
    if (nativeARM64 ? (machine != 0xAA64 && machine != 0xA641 && !(machine == 0x8664 && gameARM64EC)) :
                      (machine != 0x8664 && machine != 0x014c) || (!nativeARM64 && gameARM64EC)) {
        SetError("Executable architecture does not match the explicitly selected backend.");
        return -1;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // Keep registry state, saves, and runtime dependencies isolated per game.
    // Hash identity without changing it or accepting it as a filesystem path.
    NSString *prefix = nil;
    if (request.gameID.empty()) {
        prefix = [documents stringByAppendingPathComponent:@"wine"]; // legacy V1 clients
    } else {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(request.gameID.data(), static_cast<CC_LONG>(request.gameID.size()), digest);
        char key[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {};
        for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index)
            std::snprintf(key + index * 2, 3, "%02x", digest[index]);
        NSString *prefixRoot = [documents stringByAppendingPathComponent:@"WindowsVR/Prefixes"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *rootInfo = [fm attributesOfItemAtPath:prefixRoot error:nil];
        if (!IsContainedPath(prefixRoot.fileSystemRepresentation ?: "", documents.fileSystemRepresentation ?: "") ||
            (rootInfo && ![rootInfo[NSFileType] isEqualToString:NSFileTypeDirectory])) {
            SetError("The per-game prefix parent is not a safe directory.");
            return -1;
        }
        NSError *directoryError = nil;
        if (![fm createDirectoryAtPath:prefixRoot withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            SetError(directoryError.localizedDescription.UTF8String ?: "Could not create the private prefix parent.");
            return -1;
        }
        prefix = [prefixRoot stringByAppendingPathComponent:[NSString stringWithUTF8String:key]];
        NSDictionary *existingInfo = [fm attributesOfItemAtPath:prefix error:nil];
        if (existingInfo && ![existingInfo[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            SetError("The per-game Wine prefix is not a safe directory.");
            return -1;
        }
    }
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
    if (!InstallGuestOpenXRRuntime(machine, gameARM64EC, driveC, runtimeABI, scope, runtimeError)) {
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
    NSDictionary *mountInfo = [fileManager attributesOfItemAtPath:mountRoot error:nil];
    if (mountInfo && ![mountInfo[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        if (!nativeARM64) fex_shutdown();
        SetError("The game mount parent must be a directory, not a symlink or file.");
        return -1;
    }
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
    if (!IsSafeRelativePath(relative.UTF8String ?: "")) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Executable must have an unambiguous relative Windows path inside the selected game folder.");
        return -1;
    }
    std::string winExecutable = "C:\\windows-vr\\" + std::string(mountName.UTF8String) + "\\";
    std::string winRelative(relative.UTF8String ?: "");
    for (char &c : winRelative) if (c == '/') c = '\\';
    winExecutable += winRelative;
    std::string winWorkingDirectory = "C:\\windows-vr\\" + std::string(mountName.UTF8String);

    for (const auto &entry : request.environment) {
        SetLaunchEnvironment(entry.first.c_str(), entry.second.c_str());
    }
    char address[32];
    if (!nativeARM64) {
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitRX));
        SetLaunchEnvironment("WINE_IOS_JIT_RX", address);
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitRW));
        SetLaunchEnvironment("WINE_IOS_JIT_RW", address);
        std::snprintf(address, sizeof(address), "%llx", static_cast<unsigned long long>(jitSize));
        SetLaunchEnvironment("WINE_IOS_JIT_SIZE", address);
        std::snprintf(address, sizeof(address), "0x%llx", static_cast<unsigned long long>(jitRW - jitRX));
        SetLaunchEnvironment("MADEIRA_JIT_WRITE_OFFSET", address);
    } else {
        SetLaunchEnvironment("WINE_IOS_JIT_RX", nullptr);
        SetLaunchEnvironment("WINE_IOS_JIT_RW", nullptr);
        SetLaunchEnvironment("WINE_IOS_JIT_SIZE", nullptr);
        SetLaunchEnvironment("MADEIRA_JIT_WRITE_OFFSET", nullptr);
    }
    SetLaunchEnvironment("MADEIRA_USE_ARM64EC", nativeARM64 ? "0" : "1");
    SetLaunchEnvironment("WVR_REQUIRE_COMPOSITOR_DEVICE", "1");
    SetLaunchEnvironment("WVR_GRAPHICS_API", request.graphics.c_str());
    SetLaunchEnvironment("WINEDLLOVERRIDES", "d3d11,d3d12,dxgi,winemetal=b");

    std::vector<const char *> argv;
    argv.reserve(request.arguments.size());
    for (const auto &argument : request.arguments) argv.push_back(argument.c_str());
    if (wine_process_configure_launch(winExecutable.c_str(), winWorkingDirectory.c_str(),
                                      static_cast<int>(argv.size()), argv.data(), nativeARM64 ? 1 : 0) != 0) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira rejected the exact executable and argv profile.");
        return -1;
    }

    if (g_stopRequested.load(std::memory_order_acquire)) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("", RuntimeState::stopped);
        return 0;
    }
    g_state.store(RuntimeState::startingWineServer, std::memory_order_release);
    if (wineserver_start(prefix.fileSystemRepresentation) != 0) {
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("Madeira failed to create its wineserver thread.");
        return -1;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
    while (wineserver_is_running() && !wineserver_is_ready() && !g_stopRequested.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (g_stopRequested.load(std::memory_order_acquire)) {
        wineserver_stop();
        CleanupLaunch(mountPathUTF8, !nativeARM64);
        SetError("", RuntimeState::stopped);
        return 0;
    }
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
    g_state.store(g_stopRequested.load(std::memory_order_acquire) ? RuntimeState::stopping : RuntimeState::running, std::memory_order_release);
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
windows_vr_preflight_v1(const char *request_json) {
    @autoreleasepool {
        LaunchRequest request;
        std::string error;
        int32_t status = ParseRequest(request_json, request, error) ? PreflightRequest(request, error) : EINVAL;
        std::lock_guard<std::mutex> lock(g_mutex);
        g_lastError = error;
        return status;
    }
}

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_launch_v1(const char *request_json) {
    LaunchRequest request;
    std::string error;
    if (!ParseRequest(request_json, request, error)) {
        // A rejected caller must not change an already-running guest to failed.
        std::lock_guard<std::mutex> lock(g_mutex);
        g_lastError = error;
        return EINVAL;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    const int32_t preflightStatus = PreflightRequest(request, error);
    if (preflightStatus != 0) {
        g_lastError = error;
        return preflightStatus;
    }
    RuntimeState state = g_state.load(std::memory_order_acquire);
    if (state == RuntimeState::preparing || state == RuntimeState::startingWineServer ||
        state == RuntimeState::launchingWine || state == RuntimeState::running || state == RuntimeState::stopping) {
        g_lastError = "Madeira supports one active Wine session per app process.";
        return EBUSY;
    }
    if ((request.graphics != "direct3D11" && request.graphics != "direct3D12") ||
        (request.backend != "windowsWineFEX" && request.backend != "nativeARM64")) {
        g_lastError = "The selected backend or graphics API is unsupported; no session was consumed.";
        return ENOTSUP;
    }
    if (g_launchConsumed.exchange(true, std::memory_order_acq_rel)) {
        g_lastError = "Madeira's FEX JIT pool and Wine process bridge are one-session resources; restart the app before another launch.";
        return EALREADY;
    }
    g_lastError.clear();
    g_stopRequested.store(false, std::memory_order_release);
    wvr_compositor_reset_session_exit_v1();
    g_state.store(RuntimeState::preparing, std::memory_order_release);
    try {
        std::thread([request = std::move(request)]() mutable {
            @autoreleasepool {
                try {
                    @try {
                        RunRequest(std::move(request));
                    } @catch (NSException *exception) {
                        SetError(exception.reason.UTF8String ?: "Native runtime worker raised an exception.");
                    }
                } catch (const std::exception &exception) {
                    SetError(exception.what());
                } catch (...) {
                    SetError("Native runtime worker raised an unknown exception.");
                }
            }
        }).detach();
    } catch (...) {
        g_lastError = "Could not create the native launch worker.";
        g_state.store(RuntimeState::idle, std::memory_order_release);
        g_launchConsumed.store(false, std::memory_order_release);
        return EAGAIN;
    }
    return 0;
}

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_stop_v1(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    RuntimeState state = g_state.load(std::memory_order_acquire);
    if (wine_process_is_running() || state == RuntimeState::running || state == RuntimeState::launchingWine ||
        state == RuntimeState::startingWineServer || state == RuntimeState::preparing || state == RuntimeState::stopping) {
        g_stopRequested.store(true, std::memory_order_release);
        wvr_compositor_request_session_exit_v1();
        if (wine_process_is_running()) g_state.store(RuntimeState::stopping, std::memory_order_release);
        g_lastError = "Cooperative exit requested. Waiting for the OpenXR guest and Wine process to exit; no thread was forcibly terminated.";
        return EINPROGRESS;
    }
    return 0;
}

extern "C" __attribute__((visibility("default"))) int32_t
windows_vr_status_v1(void) {
    const RuntimeState status = g_state.load(std::memory_order_acquire);
    if ((status == RuntimeState::failed || status == RuntimeState::stopped) && wine_process_is_running()) {
        return static_cast<int32_t>(g_stopRequested.load(std::memory_order_acquire) ? RuntimeState::stopping : RuntimeState::running);
    }
    return static_cast<int32_t>(status);
}

extern "C" __attribute__((visibility("default"))) uint32_t
windows_vr_graphics_capabilities_v1(void) {
    @autoreleasepool {
        if (wvr_dxmt_d3d12_unix_call_count_v1 || wvr_dxmt_d3d12_transport_abi_v1)
            return IsModernDXMTNativeProfile() && HasD3D12Package() ? (WINDOWS_VR_GRAPHICS_D3D11 | WINDOWS_VR_GRAPHICS_D3D12) : 0u;
        return WINDOWS_VR_GRAPHICS_D3D11;
    }
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

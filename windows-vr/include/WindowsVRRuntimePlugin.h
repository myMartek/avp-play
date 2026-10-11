#ifndef WINDOWS_VR_RUNTIME_PLUGIN_H
#define WINDOWS_VR_RUNTIME_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version 1 of the optional app-bundled runtime plugin ABI.
#define WINDOWS_VR_RUNTIME_ABI_VERSION 1u

/// The plugin must enqueue the selected backend's launch and return promptly. It returns zero
/// only after accepting that launch request; nonzero values identify rejection or failure.
/// `request_json` is UTF-8 JSON with schemaVersion, backend, graphics, gameDirectory,
/// executablePath, arguments, optional gameID (isolated prefix identity), and optional environment.
/// Zero confirms enqueueing, not game readiness.
/// The plugin must reject unsupported backends instead of selecting a fallback.
typedef int32_t (*windows_vr_launch_v1_fn)(const char *request_json);

/// Requests cooperative exit. Zero means stopped; EINPROGRESS means requested but still live.
typedef int32_t (*windows_vr_stop_v1_fn)(void);

/// Required exported ABI version symbol. It must equal WINDOWS_VR_RUNTIME_ABI_VERSION.
extern const uint32_t windows_vr_runtime_abi_version;

/// Required exported versioned entry points.
int32_t windows_vr_launch_v1(const char *request_json);
/// Optional V1 addition: validates game and bundled resources without launching,
/// initializing JIT/Wine, or consuming a session. Error is available via last_error.
int32_t windows_vr_preflight_v1(const char *request_json);
/// Optional addition. Bits describe packaged implementation, not measured game compatibility.
/// Bit 0 = D3D11; bit 1 = experimental D3D12. Missing export means D3D11 only.
#define WINDOWS_VR_GRAPHICS_D3D11 (1u << 0)
#define WINDOWS_VR_GRAPHICS_D3D12 (1u << 1)
uint32_t windows_vr_graphics_capabilities_v1(void);
int32_t windows_vr_stop_v1(void);

/// Native state: 0 idle, 1 preparing, 2 wineserver startup, 3 launching,
/// 4 running, 5 stopping, 6 stopped, 7 failed.
int32_t windows_vr_status_v1(void);
/// Copies a NUL-terminated error description, returning bytes required including NUL.
uint64_t windows_vr_last_error_v1(char *buffer, uint64_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* WINDOWS_VR_RUNTIME_PLUGIN_H */

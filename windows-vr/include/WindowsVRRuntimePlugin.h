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
/// executablePath, arguments, and optional environment. Zero confirms enqueueing, not game readiness.
/// The plugin must reject unsupported backends instead of selecting a fallback.
typedef int32_t (*windows_vr_launch_v1_fn)(const char *request_json);

/// Stops the active request. Returns zero only when stop completed successfully.
typedef int32_t (*windows_vr_stop_v1_fn)(void);

/// Required exported ABI version symbol. It must equal WINDOWS_VR_RUNTIME_ABI_VERSION.
extern const uint32_t windows_vr_runtime_abi_version;

/// Required exported versioned entry points.
int32_t windows_vr_launch_v1(const char *request_json);
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

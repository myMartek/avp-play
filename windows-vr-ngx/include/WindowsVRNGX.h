#ifndef WINDOWS_VR_NGX_H
#define WINDOWS_VR_NGX_H

#include <windows.h>
#include <d3d11.h>

#ifdef __cplusplus
extern "C" {
#endif

/* DXMT-specific registration API added by this overlay. The caller must
 * install it before NGX feature creation. `host_opted_in` is the VR host's
 * explicit user setting. The callback must return TRUE only when it can prove
 * the exact NGX output resource belongs to the returned eye for this context;
 * matching dimensions/formats or a compositor's later submission is not
 * proof. This overlay does not yet provide an OpenXR implementation of the
 * callback, so the adapter stays unavailable unless a host/profile supplies
 * this association explicitly. */
typedef BOOL (*WVRNGXEyeRouteCallback)(
    ID3D11DeviceContext *context,
    ID3D11Resource *output,
    UINT *out_eye_index
);

void NVSDK_NGX_WVR_SetEyeRouter(
    WVRNGXEyeRouteCallback callback,
    BOOL host_opted_in
);

#ifdef __cplusplus
}
#endif

#endif

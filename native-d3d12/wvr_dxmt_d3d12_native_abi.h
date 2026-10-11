#ifndef WVR_DXMT_D3D12_NATIVE_ABI_H
#define WVR_DXMT_D3D12_NATIVE_ABI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* DXMT's winemetal dispatch tables, exported by the pinned native archive. */
extern const void *dxmt_winemetal_unix_call_funcs[];
extern const void *dxmt_winemetal_unix_call_wow64_funcs[];

/* Host-side archive handshake. Table count follows the actual compiled table. */
size_t wvr_dxmt_d3d12_unix_call_count_v1(void);
unsigned int wvr_dxmt_d3d12_transport_abi_v1(void);

#ifdef __cplusplus
}
#endif

#endif

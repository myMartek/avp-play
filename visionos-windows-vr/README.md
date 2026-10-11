# visionOS Windows VR research shell

This is a native SwiftUI visionOS research app with a launcher window and a `CompositorLayer` immersive scene. It imports a JSON manifest, asks the user to select the game folder explicitly, validates the manifest, and calls one persistent `NativePluginWindowsRuntime` from `WindowsVRCore`. The runtime loader accepts a signed `WindowsRuntimePlugin.framework` only from the app's `Frameworks` directory. The embedded plugin adapter invokes Madeira's Wine/FEX bridges. Pinned OpenComposite implements the OpenVR boundary; a project-owned D3D11 OpenXR runtime forwards tracking, controllers and stereo textures through a DXMT/Wine host extension to the native compositor. These are unverified source implementations and build recipes. Native archives and guest runtime DLLs have not been built or bundled.

After requesting debugger/JIT preparation, the app opens the immersive scene and waits up to 12 seconds for the compositor to bind its Metal device, publish stereo targets, and supply a fresh tracked head pose. It then dispatches to the embedded runtime plugin. If the plugin accepts the request, the UI shows its native status; a reported Wine process is explicitly labeled as active with game readiness and rendering unknown. There is no game-ready or rendered-frame callback, and the app never claims that launch acceptance means a running VR game.

The selected game-folder security scope remains open while a launch is pending or accepted. Imports are disabled throughout that time. A completed or failed native session releases the folder scope and marks the app restart-required because the native plugin owns a single session slot. If stopping returns `EBUSY`, the accepted session remains active and the UI instructs the user to let the guest exit naturally or restart.

## Compositor and controller bridge

The immersive renderer uses CompositorServices `LayerRenderer` timing, drawable eye views, Metal textures, and predicted ARKit device/accessory poses. `windows-vr-native/include/WindowsVRCompositorBridge.h` defines the C ABI consumed through the project-owned DXMT/OpenXR adapter. It exports:

- `wvr_compositor_bind_metal_device_v1`, `wvr_compositor_publish_targets_v1`, `wvr_compositor_copy_targets_v1`, and `wvr_compositor_copy_readiness_v1` for renderer/device setup.
- `wvr_compositor_submit_stereo_frame_v1`, `wvr_compositor_acquire_latest_stereo_frame_v1`, `wvr_compositor_release_acquired_frame_v1`, `wvr_compositor_copy_consumer_event_v1`, and `wvr_compositor_copy_stats_v1` for bounded stereo GPU-texture handoff. The queue holds three frames, drops stale queued frames, and retires consumer-event values in ticket order.
- `wvr_compositor_publish_frame_tracking_v1` and `wvr_compositor_copy_frame_tracking_v1` for predicted head pose, per-eye transforms/projections, frustum angles, and timestamp.
- `wvr_compositor_publish_controller_state_v1`, `wvr_compositor_copy_controller_state_v1`, `wvr_compositor_submit_haptic_v1`, and `wvr_compositor_take_haptic_v1` for tracked spatial-controller pose/actions and bounded haptic requests.

The controller provider adapts GameController spatial accessories through ARKit `AccessoryTrackingProvider`, samples normalized button/trigger/grip/stick inputs, and best-effort routes haptics through CoreHaptics. Its API shape was cross-checked against the checked-in ALVR visionOS source; ALVR is not a build or runtime dependency. The Windows OpenXR adapter consumes this ABI through a Wine Unix-call transport; guest COM pointers are resolved by DXMT before native Metal objects reach the compositor. Incoming eye textures must be single-sample 2D Metal textures on the compositor's exact `MTLDevice`, with the published target dimensions and pixel formats. This renderer presently copies compatible submitted textures directly into compositor eye slices or presents black when no compatible frame exists; it does not synthesize a scene or provide game readiness.

## Current limits

- Source adapters, source overlays and build recipes are included. Wine/FEX/DXMT native archives require real visionOS builds, and OpenComposite/OpenXR DLLs require a Windows toolchain. No binaries are supplied. Initial graphics support is D3D11; Vulkan/D3D12 are not implemented.
- JIT preparation requests the app's Madeira debugger script through the configured StikDebug/StikJIT URL scheme. That helper must be installed and paired; debugger attachment alone does not mean FEX JIT memory is prepared or that execution will succeed.
- A native per-eye MetalFX temporal scaling endpoint exists in `../windows-vr-metal`, but a DXMT NGX Super Resolution overlay forwards validated host resources to it. Proven per-eye resource routing remains a per-game integration requirement. The UI correctly labels upscaling as unavailable. Frame generation and guest-pipeline foveation remain planned.
- The sample manifest is metadata only. Supply a game you are legally entitled to use and select its containing folder in the app.

## Project setup

The XcodeGen project consumes the sibling Swift packages at `../windows-vr` and `../windows-vr-metal` and targets visionOS 27.0 for M2-class hardware as the initial research target. Project generation and compilation have not been performed. If future build execution is authorized, install XcodeGen separately if needed, generate the project from this directory, and configure a development signing team in Xcode; the project does not hardcode a paid team.

The current user constraint prohibits tests, builds, benchmarks, probes, app launches, and installs. All source is unverified. Upstream source caches were acquired; no native runtime was compiled and no game was imported or executed. An earlier agent performed one patch applicability dry-run, contrary to the constraint; subsequent patch edits remain unverified.

No privileged entitlements or local-network permission are declared. Add a local-network usage description only if a real feature later needs local networking, with a concrete rationale.

## Manifest shape

See [`Examples/sample-manifest.json`](Examples/sample-manifest.json). The example uses the `windowsWineFEX` backend and `direct3D11` graphics enum values. The selected folder is used as the base for `executableRelativePath`. `WindowsGameManifest.validate()` checks the manifest, and the bridge checks that the selected executable is a regular file inside that folder before dispatching a request to an available plugin. The app itself does not load the game executable.

## Source and resource preparation

See `../windows-vr-tools/README.md`. Source overlays must be prepared separately; never reuse native iOS archives for visionOS. Stage Wine resources under `Resources/Runtime` and the combined guest build outputs under `Resources/WindowsVR/Guest/x64`. XcodeGen deliberately requires those folders rather than silently generating an app without its runtime. A clean nonempty prefix template is still required. Preserve upstream license/source notices when distributing runtime binaries. The native adapter allows one game session per app process; exit/relaunch starts a new session.

# WindowsVRCore

`WindowsVRCore` is a Swift 5.9 package that defines the data and API boundary for a future Windows VR runtime. It supports macOS 14, iOS 17, and visionOS 1.

The package currently provides:

- `WindowsGameManifest`, with schema version 1, safe relative executable path validation, backend and graphics API choices, and launch arguments.
- `WindowsRuntime`, plus `UnavailableWindowsRuntime`, which always reports `integrationMissing` instead of pretending to launch a game.
- Per-eye frame metadata for image size, depth (including reversed device depth), current-to-previous motion vectors, and temporal jitter. Call `validate()` before passing metadata to a graphics adapter.
- Upscaler options that permit an explicit DLSS super-resolution to MetalFX temporal scaling mapping. Frame generation and foveation are fixed as unavailable.

`NativePluginWindowsRuntime` looks only in the containing app's `Frameworks` directory, resolves symlinks before checking containment, checks the embedded framework's code signature, and opens it with `RTLD_NOW | RTLD_LOCAL`. It resolves the versioned ABI in [`include/WindowsVRRuntimePlugin.h`](include/WindowsVRRuntimePlugin.h). The launch function receives UTF-8 JSON with exactly these fields: `schemaVersion`, selected `backend` and `graphics`, absolute `gameDirectory` and `executablePath`, and `arguments`. The plugin must enqueue only the requested backend and return promptly; zero means it accepted the request, while nonzero is returned as a launch error. Acceptance confirms enqueueing only; it does not mean the game is ready or rendering. The plugin must reject unsupported backends instead of selecting a fallback. The current Madeira adapter reports `EBUSY` if asked to stop a live guest because its process bridge has no safe terminate/join API; it reports success after a guest has already stopped. The framework stays loaded for the app process lifetime. The app must embed a signed plugin that supplies the requested Wine/FEX or native ARM64 runtime and graphics adapter. The project-owned adapter source is in [`windows-runtime-plugin`](../windows-runtime-plugin/README.md); no runtime framework has been built or embedded, so without a plugin the bridge reports `integrationMissing`.

The package does not include a Direct3D translation layer, JIT, process launcher, or MetalFX adapter. The manifest and rendering types describe integration points only; they do not launch or render games by themselves.

Example manifest construction:

```swift
let manifest = try WindowsGameManifest(
    id: "sample-game",
    title: "Sample Game",
    executableRelativePath: "Game/Game.exe",
    backend: .windowsWineFEX,
    graphics: .direct3D11,
    launchArguments: [],
    schemaVersion: WindowsGameManifest.supportedSchemaVersion
)
```

The unavailable runtime validates the manifest and then throws `WindowsRuntimeError.integrationMissing` from `launch`; `stop` throws the same error.

# Local Windows VR on Vision Pro: engineering plan

Date: 2026-10-10. Status: source implementation and unverified integration roadmap. The repository now contains a native headset launcher/compositor, Madeira Wine/FEX adapter, Windows OpenXR runtime, pinned OpenComposite packaging, DXMT host-transport overlays and a MetalFX/NGX Super Resolution source overlay. A native compositor bridge object has compiled for arm64 visionOS 27; no runtime binaries have been linked or launched, no game has run, and near-native performance is unmeasured. The visionOS 27 SDK marks MetalFX temporal scaling unavailable, so the current MetalFX NGX path cannot provide Super Resolution on the first M2 target.

## Objective and performance contract

Build a headset app that launches legitimately owned Windows VR games and executes them locally, with translated game code, native ARM64 compatibility libraries, GPU rendering through Metal, and direct integration with the visionOS compositor. Retain the existing ARM64 Linux/Android path when a compatible native build is available.

“Near native” is a measured objective, not an architecture guarantee. Native means a native ARM64 implementation on the same headset, at matching settings, resolution, and scene complexity. Desktop PC performance is not the comparison. For closed-source Windows games without an ARM64 counterpart, report actual frame times and translation costs rather than inventing a native-equivalence percentage.

Track separately: simulation rate, newly rendered stereo frames, interpolated frames, compositor presentation rate, CPU/GPU time, missed deadlines, input-to-display latency estimates, memory, startup compilation, and sustained thermal behavior. Choose refresh targets from the actual device capabilities. At 90 Hz the frame interval is 11.11 ms; at 120 Hz it is 8.33 ms. Reserve compositor and synchronization headroom instead of assigning the entire interval to the game. Frame generation never counts as improved simulation throughput.

First target: M2 Apple Vision Pro on visionOS 27, recording the exact OS build in every result. M5 support and comparisons follow later; do not extrapolate M5 demonstrations to M2. Query the headset's available refresh rates rather than assuming 120 Hz. Initially support one modest Direct3D 11 VR title; the title is still to be selected. A synthetic Windows VR scene precedes the commercial game. Expand after deferred M2 validation establishes a repeatable baseline.

## Evidence and the architectural choice

- [Madeira](https://github.com/willfaust/Madeira) documents a single-process iPhone runtime using ARM64EC Wine, FEX, and Metal-backed Direct3D. It is a research starting point, not established visionOS VR support. Its [build record](https://github.com/willfaust/Madeira/blob/main/docs/BUILDING.md) contains reproducibility caveats that need rechecking against a pinned checkout.
- [Steam Frame documentation](https://partner.steamgames.com/doc/steamhardware/steamframe/compatibility) describes native ARM64 Linux, Proton for Windows, and FEX for x86. Borrow its native-library/translated-game split and test strategy; do not assume its Linux binaries execute unchanged on visionOS.
- [StikDebug-visionos](https://github.com/rebelancap/StikDebug-visionos) documents on-device debugger-assisted JIT on visionOS 26/27. A [developer follow-up](https://www.reddit.com/r/VisionPro/comments/1v7zsv4/sidestore_for_visionos_and_native_gaming_ports/) reports MeloNX working. Verify the exact device/OS/runtime combination before depending on it.
- [Klepton](https://github.com/shinyquagsire23/Klepton) supplies an existing ARM64 relinking and graphics compatibility model. This repository's `recipes/alyx.json` and `third-party/xrizer/README.md` describe the Linux ARM64 Alyx and OpenVR-to-OpenXR path.
- [ALVR's visionOS client](https://github.com/alvr-org/alvr-visionos) is useful for headset presentation and input references; its PC streaming design does not provide local Windows execution.

Primary Windows path: adapt Madeira's mobile Apple runtime and JIT allocator, using native Wine with FEX translating guest instructions. Use Steam Frame's Linux/Proton/FEX stack as a reference implementation and diagnostic comparison host. Preserve Klepton's ARM64 Linux path as an independent execution backend. A Linux x86 backend is a later experiment requiring its own syscall, loader, and graphics adaptation; it is not a prerequisite for Windows support.

Avoid a whole Windows/macOS/SteamOS virtual machine as the main performance architecture. Avoid porting the complete desktop SteamVR compositor initially. Implement the VR interfaces that games need and present through visionOS.

## Proposed component boundaries

Source components (unbuilt and unverified):

- `visionos-windows-vr/`, `windows-vr/`: launcher, signing-aware plugin loader, JIT helper request and manifest/runtime contracts.
- `windows-runtime-plugin/`, `windows-vr-tools/`: actual Madeira bridge calls, pinned sources, visionOS source overlays and future build/resource recipes.
- `windows-vr-native/`: native compositor texture queue, tracking, controllers and haptics.
- `windows-vr-openxr/`, `windows-vr-openvr/`: guest D3D11 OpenXR implementation, DXMT host transport and pinned OpenComposite packaging.
- `windows-vr-metal/`, `windows-vr-ngx/`: per-eye MetalFX temporal scaling and DXMT NGX interception source. Generic eye identification is not assumed; enable only with proven resource routing.

No native/guest runtime binaries are delivered. Launch acceptance and Wine process status do not establish game readiness or rendered output.

| Component | Responsibility |
|---|---|
| Mac companion, extending AVP Play | Ownership-aware acquisition, pinned recipes/toolchains, app builds, signing, installation, asset transfer, diagnostics |
| Native headset host | Library, launch configuration, lifecycle, storage, input, immersive-space management, performance overlay |
| Windows execution backend | Madeira-derived Wine/FEX integration, JIT allocation protocol, exceptions, synchronization, PE loading, runtime dependencies |
| ARM64 execution backend | Existing Klepton Linux/Android support; native-build preference per recipe |
| Windows VR bridge | OpenVR-compatible entry points and an OpenXR provider where needed; native/guest ABI transitions; pose, actions, stereo submission |
| Metal renderer bridge | D3D texture access, GPU synchronization, compositor submission, later upscaling and foveation |
| Performance and capability service | Device/OS checks, honest metrics, per-game profiles, graphics/JIT fallback selection |

The headset process owns the native GPU device and presentation. The translated game accesses Windows-facing APIs through native bridges. Define a stereo-frame contract early: eye color/depth resources, motion vectors if available, render poses, projection matrices, view rectangles, timestamps, color space, jitter, exposure, and completion synchronization. Optional fields must be explicitly unavailable rather than guessed.

Existing Linux xrizer is not a drop-in Windows DLL. Evaluate a Windows-facing OpenVR replacement, OpenComposite-style integration, or a new forwarding shim. Select only after checking API coverage, licensing, and D3D-to-native-Metal texture access. OpenXR paths need a Windows-compatible loader/runtime boundary too.

## Phase 0: reproducibility, baseline, and capabilities (validation deferred)

1. Audit and pin Madeira plus all recursive forks; document intended build/toolchain requirements and license obligations before importing code. Keep research dependencies isolated from the existing installer. Build reproducibility remains unverified.
2. Inventory the actual shipped Klepton fork and describe the future Alyx baseline procedure; no benchmark has been run.
3. Define a future capability matrix for M2/visionOS 27 covering JIT, development signing, memory/address-space entitlements, compositor foveation, MetalFX, and controllers. Treat free-account signing and memory permissions as separate validation items. Record M5 capabilities later as a separate profile.
4. Document Proton/FEX comparison cases for a future ARM64 Linux development host. The host is a debugging reference, not proof of headset performance.

Deferred validation gate: pinned inputs, reproducible build instructions, hardware/OS capability inventory, a measured Alyx run, and explicit unsupported capabilities. None of these runtime/build checks has been performed as part of this planning update. No promise of broad game support.

## Phase 1: visionOS JIT and CPU execution (implementation unverified)

Plan a minimal debuggable headset probe that integrates the current JIT preparation protocol. Future validation should cover native generated code first, then the Madeira/FEX allocator: allocation, executable/writable aliases, repeated writes, instruction-cache synchronization, large code pools, multithreading, exceptions, app suspension, fresh launch, debugger interruptions, and recovery.

Measure one-time setup costs separately from ongoing translation and debugger traffic. Batch code-pool preparation where the verified protocol permits it; do not add a debugger round trip to every translated block. Never persist translated code across versions without a supported, verified signing/execution mechanism.

Deferred validation gate: FEX runs CPU correctness checks reliably on device, with measured translation overhead and documented launch requirements. No probe or on-device execution has been performed, so this implementation remains unverified. If the JIT path proves unavailable, continue ARM64 work and treat Windows execution as blocked at this milestone; interpretation is a diagnostic fallback, not a claimed high-performance solution.

## Phase 2: Windows and Metal, without VR (implementation unverified)

Port the necessary native Wine/FEX/DXMT portions to the visionOS target. Establish PE loading, threads, exceptions, filesystem, audio, controller input, and resource cleanup. Validate existing single-process adaptations rather than assuming desktop Wine process behavior is available.

Plan support for a small D3D11 test program and then one lightweight Windows game. Deferred validation must cover texture formats, shader translation, synchronization, and native Metal resource access. Cache shaders within supported APIs. Enable a Vulkan/MoltenVK path only for titles whose requirements justify it; D3D12 is a separate later compatibility milestone.

Deferred validation gate: repeatable on-device rendering with correct output, stable memory, measured CPU/GPU costs, and a recoverable launch/exit cycle. No rendering implementation has been exercised.

## Phase 3: direct VR bridge (implementation unverified)

Implement the chosen Windows VR boundary and a synthetic stereo scene. Connect predicted poses, projection, controller actions/haptics, tracking loss, pause/resume, and compositor pacing. Own the frame loop on the headset and align guest render waits with compositor scheduling.

Present GPU-resident eye textures without CPU readback. Copies are allowed when required for correctness, but measure and reduce them. Use explicit synchronization between game rendering and presentation. Preserve correct coordinate systems, stereo alignment, color space, and depth conventions.

Deferred validation gate: correct tracked stereo and inputs with bounded frame queues and stable timing. A flat Windows scene rendered into two arbitrary windows is not acceptance. No headset presentation or input path has been validated.

## Phase 4: first Windows VR game and launcher (implementation unverified)

Choose a modest x64/D3D11 title without kernel anti-cheat or mandatory external launch services. Use legal purchases and supported authentication; never bypass ownership or DRM. Start with local game data and add store acquisition after execution works. Future validation should cover loading, 30-minute gameplay, saves, clean exit/relaunch, input, and device lifecycle. The title and its compatibility remain unverified.

Add per-game profiles and versioned compatibility reports to the Mac companion/headset launcher. Keep known-good ARM64 targets independent of Windows backend changes. Add bounded asset transfer so the Mac need not retain complete game data; the headset still requires installation space.

Deferred validation gate: one end-to-end Windows VR game, published test configuration and raw metrics, reproducible installation, and regressions checked against Alyx. No game has been installed or run. Extend coverage across engines only afterward.

## Phase 5: Metal upscaling and pipeline interception (implementation unverified)

DLSS compatibility is an API-interoperability project, not execution of NVIDIA's proprietary DLSS model on Apple GPUs. NVIDIA describes DLSS Super Resolution as using NVIDIA-trained AI models ([NVIDIA DLSS](https://developer.nvidia.com/rtx/dlss)); the model/runtime and their terms are distinct from the application-facing NGX/DLSS API contract. A compatibility layer can intercept the game's supported NGX calls and translate their inputs and outputs to a different backend. The [DXMT vendor-extension notes](https://github.com/3Shain/dxmt/wiki/Vendor-Extensions) document a subset of `nvapi64.dll`/`nvngx.dll` compatibility and DLSS Super Resolution mapped to MetalFX Temporal Scaler on Apple Silicon. [CrossOver 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26) likewise documents DLSS powered by MetalFX when in-game DLSS is enabled and the D3DMetal or DXMT backend is active. These are precedents for supported Mac configurations, not proof that the code, API coverage, entitlements, or performance transfer to visionOS or this repository.

The source overlay now contains a narrow NGX/DLSS Super Resolution interception path and a native MetalFX endpoint. However, the installed visionOS 27 SDK explicitly marks `MTLFXTemporalScaler` unavailable on visionOS. The C ABI now returns unsupported there, and the DXMT overlay must report the temporal feature unsupported before creation; no SR path is available on the M2 Vision Pro through MetalFX. The first-target plan therefore needs a separate temporal SR backend that is supported on visionOS, or must defer temporal SR. On macOS/iOS targets where MetalFX is available, retain the limited adapter and its fail-closed feature queries. Preserve the game-visible API behavior where implemented, but do not describe this as running NVIDIA's proprietary model or as image-quality-equivalent DLSS. Apple documents [MetalFX upscaling and interpolation](https://developer.apple.com/videos/play/wwdc2025/211/); availability must be checked for each platform.

Treat Super Resolution as the first and only initial DLSS-compatible feature. Frame Generation is a separate API surface and frame-pacing problem; do not assume an SR shim also supports it, or that a MetalFX interpolator can transparently satisfy an NVIDIA FG contract. Plan it only as a later, separate compatibility investigation with its own inputs, presentation semantics, latency limits, and opt-out. Ray Reconstruction and other NGX features are also out of scope unless separately specified.

Own interception at the graphics translation and VR submission boundaries. Begin with adjustable per-eye render resolution and spatial upscaling. Add temporal upscaling only when correct eye-specific depth, motion vectors, jitter, exposure, history resets, and resolution conventions can be obtained. Maintain separate histories for each eye; never share one temporal history across stereo views. Final color alone cannot provide those signals reliably. Prefer explicit game/engine adapters or compatible upscaler API hooks over guessing resources from every draw call.

Plan game-resource discovery and extraction only for titles the user legitimately owns, using the game's supported installation files and authentication. Do not bundle or redistribute game assets, NGX/DLSS binaries, NVIDIA model data, or other proprietary content. Confirm the relevant game's license and the compatibility components' licenses before designing any extraction or packaging flow; ownership of a game does not automatically grant redistribution rights.

Keep separate eye histories, handle scene cuts and disocclusions, and separate UI where possible. Compare image quality and measured GPU savings against the unmodified path. Feature toggles and fallback are per-game.

Deferred validation gate: positive net GPU benefit at acceptable stereo image quality, without a latency regression or inflated frame-rate claims. The compositor bridge object compiled, but the MetalFX temporal endpoint cannot compile for visionOS because the SDK marks the API unavailable; its visionOS C ABI is gated to return unsupported. The DXMT availability overlay, eye resource routing, and all performance and image-quality claims remain unverified. A visionOS-compatible temporal SR backend is required before M2 temporal-SR evaluation.

## Phase 6: foveated rendering inside the guest render pipeline (implementation unverified)

Apple exposes system-provided [variable rasterization rate maps through Compositor Services](https://developer.apple.com/documentation/compositorservices/layerrenderer/capabilities/supportsfoveation). Do not assume unrestricted eye-gaze coordinates are available. Query capabilities and use the system map through supported APIs.

Adding foveation to a final blit only reduces that blit's work. To reduce the game's expensive shading, adapt eligible guest render passes themselves. Investigate binding rasterization-rate maps in the Metal translation backend and reconciling compressed render coordinates with full-resolution sampling, postprocessing, depth, motion vectors, and temporal histories. This may require shader and engine-specific changes.

First establish correct foveation in a controlled scene. Then support selected forward-rendered game passes; extend to deferred rendering and screen-space effects with explicit compatibility checks. Prefer foveation before upscaling in the initial research schedule, but test both ordering options with correct coordinate conversion. Do not blindly feed nonuniformly rasterized images to a temporal scaler.

Deferred validation gate: actual reduction in guest GPU rendering cost; correct center/periphery quality during gaze/head movement; no invalid temporal history, stereo mismatch, or unsupported raw eye-tracking dependency. No foveation implementation has been validated.

## Phase 7: experimental VR frame generation (implementation unverified)

After stable pacing and upscaling, evaluate MetalFX interpolation separately from the OS compositor's own reprojection. Use stereo-consistent inputs and preserve the compositor's pose/time contract. Avoid uncontrolled stacking of interpolation and reprojection.

Test depth/motion completeness, transparent particles, controller/hands, rapid head turns, disocclusion, UI, and temporal delay. Interpolation may require a later frame and thus add latency; measure the effect before exposing it for immersive play. Support runtime opt-out and immediate fallback.

Deferred validation gate: demonstrated visual improvement with acceptable measured latency and stereo behavior. Report rendered, generated, and presented rates separately. If quality or timing is inadequate, ship upscaling/foveation without frame generation. No frame generation path has been implemented or measured.

## Deferred validation and delivery

When validation is authorized and scheduled, automate CPU/ABI and graphics correctness probes, shader/resource lifetime checks, frame-contract checks, and resume/relaunch checks. Use real headset runs for JIT, controllers, visual correctness, pacing, memory limits, and sustained performance; simulator results alone are insufficient. No builds, benchmarks, executable probes, app launches, or installs were performed. One agent performed an earlier patch applicability dry-run contrary to the no-testing instruction; no further checks were authorized and later source edits remain unverified.

For each future performance change capture identical scene/settings before and after: CPU/GPU median and tail frame times, missed frames, game render rate, memory, startup compilation, and a sustained run. Repeat when changes or variance justify it. Keep reference images and motion sequences for stereo/upscaling/foveation quality. All such results remain outstanding.

Initial delivery is a development-signed research app with reproducible setup. A free Apple account may cover some probes while seven-day provisioning and memory capabilities remain separate constraints. Do not assume a production App Store route or an entitlement that removes all JIT restrictions.

This repository's MIT license does not automatically cover imported GPL/AGPL runtime components. Establish appropriate component licensing and source distribution before sharing binaries. No game files or credentials are distributed.

## Remaining delivery gates

Source implementation is not proof of an executable product. Native visionOS compilation, Windows guest DLL compilation, clean Wine resource staging, signing, JIT helper/device compatibility, loader/runtime completeness and on-device correctness remain deferred under the no-testing constraint. First establish one D3D11 game on M2; broaden compatibility only from actual results. Engine-specific NGX eye routing, guest-render-pass foveation and VR frame generation are later milestones. Neither a paid account nor an app-side account-check change provides unrestricted JIT.

# Local Windows VR build handoff — 2026-10-11

The complete **unsigned** Debug app built successfully for arm64 visionOS 27
with Xcode 27. This is a compiled research build, not established SteamVR game
compatibility or measured near-native performance. No tests, app/game launches,
device installations, or benchmarks were performed.

## Saved output

- App: `dist/windows-vr-2026-10-11/AVP Play VR.app`
- Build summary and file hashes: `dist/windows-vr-2026-10-11/build-summary.json`
- Native, guest, graphics, resource-stage receipts and the successful Xcode log
  are saved alongside the app.
- Generated project: `visionos-windows-vr/VisionOSWindowsVR.xcodeproj`
- Validated resources: `visionos-windows-vr/Resources/Runtime` and `WindowsVR`

The saved app includes the Wine prefix, Wine builtin resources, source-built
ARM64EC translator and its C++ runtime dependencies, x64 OpenXR/OpenComposite
clients, modern D3D11/D3D12 graphics DLLs, and licenses. The native runtime and
graphics libraries are linked into its frameworks. The graphics package supports
the pinned backend's SM5.1/DXBC scope; DXIL/SM6, ray tracing, mesh shaders,
temporal super resolution, stereo frame generation, and guest-render-pass
foveation are not established features.

## Next step: restore signing

The selected Personal Team's certificate has no available private key. The
unsigned app cannot be installed on the headset. Resolve that account state
through Apple Developer Support, or add a different Apple Account in Xcode and
try its Personal Team. Creating another certificate in the current blocked
account has already failed; deleting a local certificate cannot recover its key.

Open the generated project in Xcode. Select a valid team under Signing &
Capabilities for the app and both local framework targets. The saved project
already selects the modern graphics archive; do not regenerate it without the
runtime-source and graphics-link environment variables.

After a usable certificate is available, a build-only command is:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project visionos-windows-vr/VisionOSWindowsVR.xcodeproj \
  -scheme VisionOSWindowsVR -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath .build-windows-vr-signed \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Automatic 'CODE_SIGN_IDENTITY=Apple Development' build
```

Signing alone does not establish that JIT or the runtime works on visionOS 27.
Device execution and game acceptance remain separate work requiring permission
to run them.

## Build inputs currently on this Mac

The generated project references build caches outside cloud-synced Documents:

- Common native/Wine/FEX source and binaries:
  `/private/tmp/avp-play-builds/final-modern-v4`
- Receipt-backed graphics source and archive:
  `/private/tmp/avp-play-builds/final-graphics-v5`
- Final client and Xcode build outputs:
  `/private/tmp/avp-play-builds/final-package-v2`
- Clean prefix and provenance:
  `/private/tmp/avp-play-builds/prefix-wine-host-x86_64-v8/artifact-portable`
- Pinned dependency sources: `/private/tmp/avp-play-build-sources`
- Shared visionOS LLVM libraries: `/private/tmp/avp-play-native-toolchains`

Keep these caches while using this generated project. They are temporary paths;
if removed, rebuild with [the assembly recipe](../windows-vr-tools/README.md)
and regenerate the project. The copied app and receipts under `dist` do not
depend on those paths merely to be retained as artifacts.

The final common and graphics profiles have identical common-overlay provenance
and native Wine binder source. The graphics build uses the completed common
profile's Wine build tools and shared LLVM libraries. Its four compiled DLLs and
archive were copied into the common resource ledger before native/guest receipts
were written; staging verified their hashes against the separate graphics receipt.
No old source receipt was rewritten to mark failed compilation successful.

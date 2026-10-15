# Surreal Touch builds

The controller preference is in Settings → Controllers. Standard Controllers remains the default. The global choice becomes the initial mode in newly built games; each game can override it in its Vision Pro launcher without another rebuild. Pairing happens on Vision Pro.

The matching runtime change is in `myMartek/Klepton`, branch `avp-play`. This Mac app requires that modified runtime for Surreal mode. It detects the generator option and all backend files and rejects an incompatible toolchain instead of silently producing a Standard-only game. It never changes a custom toolchain choice for you.

## Build this Mac app

```sh
cd core
swift test
tools/make-app.sh
```

The resulting app is `dist/AVP Play.app`. `--controller-mode standard|surreal` is also accepted by the CLI's install/job commands. Old saved jobs remain compatible and default to Standard.

## Prepare a custom runtime

A source-only Klepton clone needs the existing third-party binaries described in its BUILDING.md. The published AVP Play toolchain contains those binaries and its license notices. Use the source snapshot matching that published release, and preserve its `toolchain.json` compatibility history in your separate working copy with `modified: true`. The snapshot repository and release package use different commit histories; do not treat the source repository's commit count as the published toolchain number.

Use a separate working copy of that matching runtime, with the graphics prebuilts and a `modified: true` toolchain manifest. Select it through the existing per-game custom toolchain picker. Do not overwrite an installed official package or include the reference-only OpenSurreal checkout.

For example, using the CLI built by this app:

```sh
core/.build/debug/avpplay toolchain use beatsaber140 --toolchain /absolute/path/to/Klepton
```

That command deliberately selects the custom toolchain for one game; it is a setup instruction, not something the implementation runs automatically. Keep the game's current recipe/version and bundle prefix. To return to the normal toolchain later, use the existing toolchain picker or `toolchain use <id> --newest`.

## Update an existing game without downloading it again

With its required files already cached and the compatible custom toolchain selected, open the game's page and click **Rebuild Controllers**. This queues only `.build`, using the existing installer, bundle ID and signing team. Installation over the existing app preserves its data container; no uninstall, stage, save restore or fetch is added. The initial choice is taken from Mac settings at job creation. Changing that preference does not force all existing games to update.

The button is disabled if data, device/signing setup or compatible runtime is missing. Normal Install/Update still reuses verified cached files, and pins/custom toolchains keep their existing selection behavior. Signature renewal preserves the built default from the prior local product where available; a saved headset preference always wins.

See the runtime's `docs/SURREAL.md` for pairing, calibration, simulator commands, source/license provenance and the physical hardware test checklist. Physical connection and buttons were confirmed on Vision Pro, and the tester reported good hand-derived position and improved sensor-only rotation. Native positional tracking, fast-motion accuracy and physical haptics remain unverified.

## Release packaging

`ToolchainPackager.pack` packages committed runtime sources plus its existing explicit graphics-prebuilt list. The new files are ordinary `visionos/Sources` files explicitly included by `gen_xcodeproj.py`; no optional package resolution or unlicensed dependency is needed at game build time. A round-trip archive/install test verifies their inclusion. Official release maintainers should commit these runtime changes into their release-producing history, package using the existing `avpplay toolchain pack` command, and supply the resulting archive to `AVPPLAY_TOOLCHAIN_ARCHIVE` when running `make-app.sh`.

A custom build should use a separate runtime copy. Do not replace an official archive while retaining its unchanged identity or checksum. Physical game installation still uses AVP Play's normal signing flow and the user's existing bundle identity.

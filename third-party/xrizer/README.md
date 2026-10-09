# xrizer, as AVP Play uses it

Half-Life: Alyx talks to its headset through OpenVR. [xrizer](https://github.com/Supreeeme/xrizer) (GPL-3.0)
translates OpenVR to OpenXR, which is what Klepton's runtime on the Vision Pro provides. The recipe for
Half-Life: Alyx downloads a ready-built copy of it, an aarch64 Linux `vrclient.so`, from this repository's releases:

    https://github.com/myMartek/avp-play/releases/tag/xrizer-0989a7f-avpplay1

That file is upstream xrizer at the revision in `xrizer.rev` with two small changes. Everything needed to build it
again is in this folder; the release also carries the complete patched source as an archive.

| File | What it is |
| --- | --- |
| `xrizer.rev` | the upstream commit the build is made from |
| `xrizer-frame-timing.py` | change 1: `IVRCompositor::GetFrameTiming` reports the measured frame time instead of constants, so the game's automatic quality level works |
| `xrizer-interstitials.py` | change 2: the game's loading-screen messages are handed to the host instead of being dropped |
| `build-xrizer.sh` | fetches upstream at that commit, applies both changes, builds `xrizer/bin/linuxarm64/vrclient.so` |

## Building it yourself

The build runs on Debian 13 for arm64 — the same C library as Steam Linux Runtime 4, which the game runs in. On a
Mac that is a small virtual machine, for example with [Lima](https://lima-vm.io), with this folder shared writable:

    ./build-xrizer.sh

The script installs what it needs (compiler, Rust, Vulkan and Wayland headers), builds, and leaves the result in
`xrizer/` next to itself. To use your own build instead of the download, put that `xrizer` folder into the game's
folder in the library; the recipe names the file it checks for.

The two changes are published under xrizer's own licence, GPL-3.0.

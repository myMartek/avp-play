# Third-party software

AVP Play itself (this repository) is MIT-licensed and has no third-party code dependencies beyond Apple's
system frameworks for the original Mac companion. The separate experimental Windows VR runtime has optional third-party source dependencies described below.

The **toolchain package** that ships inside the app (`klepton-toolchain-<version>-<commit>.tar.gz`) contains:

| Component | Licence | Where its licence text is |
|---|---|---|
| [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas and contributors, with this project's changes – complete source | MIT | `LICENSE` in the package |
| [ANGLE](https://chromium.googlesource.com/angle/angle) (prebuilt, with the patches in `angle-patches/`) | BSD 3-Clause | `third-party-licenses/ANGLE-LICENSE.txt` |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (prebuilt) | Apache 2.0 | `third-party-licenses/MoltenVK-LICENSE.txt` |

Klepton's own tree carries further third-party parts (for example a font, an HRTF data set and a CA
certificate table); they are part of the upstream project and are passed on unchanged.

**Not included**, and provided by you where a recipe needs them:

- game files of any kind,
- Meta's `ovr-platform-util`,
- Steam Linux Runtime 4 (arm64), which the Half-Life: Alyx recipe needs. From version 1.0.8 on the app downloads it
  from Valve's own server (`repo.steampowered.com`) on your Mac; it is not passed on by this project.

## xrizer

From version 1.0.8 on, the Half-Life: Alyx recipe downloads a build of [xrizer](https://github.com/Supreeeme/xrizer) (OpenVR on top of
OpenXR, GPL-3.0) from this repository's releases. It is upstream xrizer at a pinned commit with two small changes;
the build script, both changes and the commit are in [`third-party/xrizer`](third-party/xrizer), and the release
carries the complete patched source next to the binary. It is a separate program that the game loads on the
headset; it is not part of the app or the toolchain package.

## Experimental Windows VR / DXMT D3D12

The optional D3D12 source profile fetches [DXMT](https://github.com/3Shain/dxmt)
at `e94c312f5c054263acf261cfa109edf13e757587`, separately from Madeira's
pinned DXMT fork. Its D3D12 source headers carry CodeWeavers contributor notices
and LGPL-2.1-or-later terms; retain upstream `LICENSE`, `COPYING.LIB`, source
notices, and all submodule licenses. Project integration overlays do not replace
upstream licensing obligations with this repository's MIT license.

No D3D12 runtime binaries or game assets are delivered by this source pass.
Before redistributing a built Wine/FEX/DXMT/OpenComposite closure, satisfy each
component's license and corresponding-source obligations and ship the actual
pinned modifications. The source profile and remaining mobile-runtime integration
limits are documented in [`docs/windows-vr-d3d12.md`](docs/windows-vr-d3d12.md).

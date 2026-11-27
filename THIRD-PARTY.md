# Third-party software

AVP Play itself (this repository) is MIT-licensed and has no third-party code dependencies beyond Apple's
system frameworks. It contains code adapted from one other project:

| Component | Licence | Where its licence text is |
|---|---|---|
| Parts of the installer of [Glovebox](https://github.com/glovebox-vr/glovebox) by the Glovebox contributors: the setup help that floats next to Xcode, the App Store and Device Hub (`core/Sources/AVPPlayApp/SetupGuide.swift`) and its drawings (`SetupArt.swift`), and the outline of the setup assistant (`SetupAssistant.swift`) | MIT | `third-party-licenses/Glovebox-LICENSE.txt`; the app shows it under Settings › Software used |

The **toolchain package** that ships inside the app (`klepton-toolchain-<version>-<commit>.tar.gz`) contains:

| Component | Licence | Where its licence text is |
|---|---|---|
| [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas and contributors, with this project's changes – complete source | MIT | `LICENSE` in the package |
| [ANGLE](https://chromium.googlesource.com/angle/angle) (prebuilt, with the patches in `angle-patches/`) | BSD 3-Clause | `third-party-licenses/ANGLE-LICENSE.txt` |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (prebuilt) | Apache 2.0 | `third-party-licenses/MoltenVK-LICENSE.txt` |

From the toolchain release that follows 232 on, the package also contains, as source that is compiled with the
runtime:

| Component | Licence | Where its licence text is |
|---|---|---|
| [Fossilize](https://github.com/ValveSoftware/Fossilize) by Valve (library sources at `556da9f`), with the [RapidJSON](https://github.com/Tencent/rapidjson) and [miniz](https://github.com/richgel999/miniz) copies it carries and the Khronos Vulkan headers | MIT (Vulkan headers: Apache 2.0 or MIT) | `vendor-fossilize/LICENSE`, `vendor-fossilize/rapidjson/license.txt`, `vendor-fossilize/miniz/LICENSE`, each header's own notice |
| Parts of [Glovebox](https://github.com/glovebox-vr/glovebox) by the Glovebox contributors: the Vulkan pipeline recorder and replayer and their hooks, the tool that rebuilds a pipeline list from a player's own game files, the pipeline recipe for Half-Life: Alyx (references into the game's shader files, no shader code), and the Steam connection, sign-in and Steam Cloud sync (`visionos/SteamCloudKit`, from Glovebox's `SteamLauncherKit`) | MIT | `visionos/SteamCloudKit/LICENSE-Glovebox.txt`; each file names its origin |

From toolchain release 933 on, the package also contains, as source that is compiled with the runtime:

| Component | Licence | Where its licence text is |
|---|---|---|
| The VP8 decoder of [libvpx](https://chromium.googlesource.com/webm/libvpx) by the WebM Project authors, ported to C (`runtime/media/kl_vp8.c`) – plays a game's WebM video clips | BSD 3-Clause | `third-party-licenses/libvpx-LICENSE` |

From toolchain release 944 on, the package also contains, as a built library:

| Component | Licence | Where its licence text is |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) 9.0.2 by the FFmpeg developers, decoders and demuxers only (`KleptonFFmpeg.framework`, built from the pinned release tarball by the toolchain's `tools/ffmpeg_build.sh`, with its small change in `tools/ffmpeg/visionos.patch`) – plays MKV, AVI, WebM, TS, WMV and OGV films in Bigscreen Beta. It is embedded in Bigscreen Beta's app only, as its own framework that the game loads at run time, so it can be replaced | LGPL 2.1 or later (no GPL or non-free parts) | `third-party-licenses/FFmpeg-COPYING.LGPLv2.1`, and `COPYING.LGPLv2.1` inside the framework |

From toolchain release 315 on, the package also contains, as source that is compiled on your Mac the first time
a Unity game's shader list is built:

| Component | Licence | Where its licence text is |
|---|---|---|
| [SMOL-V](https://github.com/aras-p/smol-v) by Aras Pranckevičius (`smolv.cpp`, `smolv.h` at `55000ef`, with one marked change) – decodes the encoding Unity stores a game's Vulkan shaders in | public domain or MIT, at your choice | `vendor-smolv/LICENSE.txt` |

Klepton's own tree carries further third-party parts (for example a font, an HRTF data set and a CA
certificate table); they are part of the upstream project and are passed on unchanged.

**Not included**, and provided by you where a recipe needs them:

- game files of any kind,
- Meta's `ovr-platform-util`,
- Steam Linux Runtime 4 (arm64), which the Half-Life: Alyx recipe needs. From version 1.0.8 on the app downloads it
  from Valve's own server (`repo.steampowered.com`) on your Mac; it is not passed on by this project.

## Beat Saber mods

From toolchain release 824 on (AVP Play 1.8.0), the package also carries the Beat Saber modding community's mods,
prebuilt for Beat Saber 1.45.3, with their sources and the changes made for the Vision Pro in Klepton's
`ports/scotland2`. The port to the Vision Pro is [naldo29's](https://github.com/naldo29/beat-saber-with-custom-song-support)
(MIT). A Beat Saber build with mods carries:

| Mod | Authors | Licence |
|---|---|---|
| [Scotland2](https://github.com/sc2ad/scotland2) 0.1.7 – mod loader | sc2ad | MIT |
| [beatsaber-hook](https://github.com/QuestPackageManager/beatsaber-hook) 9.3.0 – modding library | QuestPackageManager (sc2ad and contributors) | MIT |
| [custom-types](https://github.com/QuestPackageManager/Il2CppQuestTypePatching) 0.21.2 – modding library | QuestPackageManager | MIT |
| [Flamingo](https://github.com/QuestPackageManager/Flamingo) 1.2.1 – hooking library | QuestPackageManager | MIT |
| [paper2](https://github.com/Fernthedev/paperlog) 4.8.0 – logging | Fernthedev | no licence stated |
| [reflect-cpp](https://github.com/kodenamekrak/reflectcpp-qpm) 0.25.0 – library | kodenamekrak | MIT |
| [tinyxml2](https://github.com/MillzyDev/NDK-tinyxml2) 10.0.0 – library | Lee Thomason, packaged by MillzyDev | zlib |
| [BSML](https://github.com/bsq-ports/Quest-BSML) 0.6.5 – menu framework | bsq-ports | no licence file in the repository yet |
| [Lapiz](https://github.com/raineaeternal/Lapiz) 0.3.7 – modding library | raineaeternal | MIT |
| [SongCore](https://github.com/raineaeternal/Quest-SongCore) 1.3.5 – custom songs | raineaeternal | MIT |
| [PlaylistCore](https://github.com/Metalit/PlaylistCore) 1.7.2 – playlists | Metalit | GPL-3.0 |
| [SongDownloader](https://github.com/darknight1050/SongDownloader) 0.9.1 – song downloads | darknight1050 | GPL-3.0 |
| [BeatSaverPlusPlus](https://github.com/bsq-ports/BeatSaverPlusPlus) 0.2.4 – BeatSaver access | bsq-ports | MIT |
| [WebUtils](https://github.com/bsq-ports/WebUtils) 0.6.9 – web requests | bsq-ports | no licence file in the repository yet |
| [SongDetails](https://github.com/bsq-ports/SongDetails) 1.0.5 – song database | bsq-ports | no licence file in the repository yet |
| [MetaCore](https://github.com/Metalit/MetaCore) 2.0.6 – modding library | Metalit | no licence file in the repository yet |
| [MetaCoreBS](https://github.com/Metalit/MetaCoreBS) 1.0.1 – modding library | Metalit | no licence file in the repository yet |
| [Unicode](https://github.com/Metalit/UnicodeQuest) 0.1.8 – text in all scripts | Metalit | no licence file in the repository yet |
| [PlayerDataKeeper](https://github.com/Metalit/PlayerDataKeeper) 0.2.7 – save backups | Metalit | no licence file in the repository yet |
| [BetterSongSearch](https://github.com/bsq-ports/BetterSongSearchQuest) 2.3.0 – song search | bsq-ports | MIT |
| [Airbuds Search (as Apple Music Search)](https://github.com/zilewang7/Beat-Saber-Airbuds-Search) 2.0.2 – songs from your listening history | zilewang7, based on Spotify Search by TychoTheTaco; Apple Music history by this project | no licence file in the repository yet |

The search mod reads the player's Apple Music history on the headset instead of Airbuds (a change of this project).
Where a repository has no licence file yet, its authors said MIT is what they want. The mods' authors asked to be
named where players see it: the game's start window (Settings › Mods) and AVP Play (Settings › Software used) list
them as here.

## Skyrim VR on Apple Vision Pro

The Skyrim VR recipe is built with [Skyrim VR on Apple Vision Pro](https://github.com/gseddon/Skyrim-VR-Vision-Pro)
by gseddon (MIT; it builds on VeRantyx's VXRuntime, on [xrizer](https://github.com/Supreeeme/xrizer) (GPL-3.0), on
Klepton's OpenXR code (MIT) and on parts of Wine and FFmpeg (LGPL-2.1-or-later); its `THIRD_PARTY_NOTICES.md` lists
them). Nothing of it is part of the app or of the toolchain package: when you install the game, AVP Play fetches the
source at the commit the recipe names (from <https://github.com/myMartek/Skyrim-VR-Vision-Pro>, a fork that carries
the adapter for AVP Play until it is part of the original) and builds it on your Mac. The game's translated program
is made from your own game files there and stays on your Mac and your headset.

## GTA Vice City through reVC

The Vice City recipe is built with [reVC for visionOS](https://github.com/LowRiderXR/revc-visionos-app) by
LowRiderXR (MIT for its own code: the app around the engine, its renderer and scripts). It runs **reVC**, the
reverse-engineered Grand Theft Auto: Vice City engine of the re3 project, in LowRiderXR's visionOS port
[revc-visionos](https://github.com/LowRiderXR/revc-visionos). **The original reVC repository has no licence:** the
re3 project's authors state that they do not feel in a position to give the engine one, and the port grants none
either. AVP Play uses it as it is published. Grand Theft Auto and Vice City are trademarks of Take-Two Interactive;
neither this project nor reVC is affiliated with or endorsed by Rockstar Games or Take-Two.

Nothing of it is part of the app or of the toolchain package: when you install the game, AVP Play fetches the app's
source at the commit the recipe names (from <https://github.com/myMartek/revc-visionos-app>, a fork that carries the
adapter for AVP Play, the start window, the settings page and performance panel of AVP Play's games and MetalFX
upscaling, all MIT like the app; the panel's drawing and GPU count come from Klepton, MIT) and builds it on your Mac.

**Downloaded and built on your Mac by that build, not passed on by this project:** the engine (revc-visionos with
[librw-visionos](https://github.com/LowRiderXR/librw-visionos), MIT; {fmt}, MIT; dr_mp3, public domain or MIT-0;
libogg, libopus and opusfile, BSD-3-Clause) at the release tag the project's `setup.sh` names, and from the project's
GitHub release, checked against its SHA-256 sums, prebuilt ANGLE (BSD-3-Clause, with a Klepton patch, MIT) and OpenAL
Soft (LGPL-2.0-or-later, with its HRTF data under Apache-2.0). The project's `THIRD_PARTY_NOTICES.md` has every
licence text. The game's files come from your own Steam copy of GTA Vice City (app 12110) and stay on your Mac and
your headset.

## Jedi Outcast and Jedi Academy through JKXR

The two recipes are built with [JKXR](https://github.com/Team-Beef-Studios/JKXR) by Team Beef (GPL-2.0, like
[OpenJK](https://github.com/JACoders/OpenJK) and the engine it continues), in its port to the Vision Pro. Nothing of
it is part of the app or of the toolchain package: when you install one of the games, AVP Play fetches the source at
the commit the recipe names (from <https://github.com/myMartek/JKXR>, a fork that carries the visionOS port, the
adapter for AVP Play, the start window and the performance panel of AVP Play's games; the panel's drawing and GPU
count come from Klepton, MIT) and builds it on your Mac.

**Built on your Mac from that source, not passed on by this project:** both games' engines, the libraries that come
with the source (among them gl4es, MIT; libpng, libjpeg, libzip and minizip under their own licences) and the VR add-ons of the
port; the app links prebuilt ANGLE frameworks from the same repository (BSD-3-Clause, with a foveation patch). The
build uses cmake (BSD-3-Clause) and XcodeGen (MIT) from Homebrew where they are installed, otherwise it downloads
each once from its project's GitHub release and checks it against a SHA-256 written in the adapter. The game's files
come from your own Steam copies (apps 6030 and 6020); only their folder `base` is kept, on your Mac and your headset.
The app's icon and start picture are the game's own from Valve's image server, fetched on your Mac.

## Half-Life through LambdaVision

The Half-Life recipe is built with [LambdaVision](https://github.com/illixion/halflife-visionos) by illixion
(GPL-3.0): the [Xash3D-FWGS](https://github.com/FWGS/xash3d-fwgs) engine (GPL-3.0) with Half-Life's game code from
[hlsdk-portable](https://github.com/FWGS/hlsdk-portable) (Valve's Half Life 1 SDK licence), drawn on Metal through
[ANGLE](https://chromium.googlesource.com/angle/angle) (BSD-3-Clause), with illixion's Swift packages
[RAVESDK](https://github.com/illixion/RAVESDK), [RAVEEngine](https://github.com/illixion/RAVEEngine) and
[DebugTrace](https://github.com/illixion/DebugTrace) (MIT). Half-Life is a trademark of Valve Corporation; neither
this project nor LambdaVision is affiliated with or endorsed by Valve.

Nothing of it is part of the app or of the toolchain package: when you install the game, AVP Play fetches the source
at the commit the recipe names (from <https://github.com/myMartek/halflife-visionos>, a fork that carries the adapter
for AVP Play, the start window of AVP Play's games, PS VR2 Sense controller support and each eye drawn from its true
pose, all GPL-3.0 like the project) and builds it on your Mac.

**Downloaded on your Mac by that build, not passed on by this project:** the three Swift packages at the commits the
fork pins, the engine's sources at the commits the project's `VisionPort/setup.sh` names (with MoltenVK, Apache-2.0),
and from the fork's GitHub release, checked against their SHA-256 sums, the compiled engine pieces built from exactly
those sources (ANGLE, libxash, the Opposing Force and Blue Shift ports). The game's files come from your own Steam
copy of Half-Life (app 70, the build from before the 25th Anniversary Update) and stay on your Mac and your headset.

## Minecraft: Java Edition with Vivecraft

The Minecraft recipe builds on [vivecraft-visionos](https://github.com/rebelancap/vivecraft-visionos) by rebelancap
(MIT), the port of Minecraft: Java Edition with the VR mod [Vivecraft](https://github.com/Vivecraft/VivecraftMod)
(LGPL-3.0) to the Vision Pro: the game and its mods are compiled ahead of time into a program for Apple's chips. The
app around it is built with this project's toolchain, the Klepton fork
([Klepton](https://github.com/shinyquagsire23/Klepton), MIT). Nothing of the game or of the port is part of the app
or of the toolchain package: when you install the game, AVP Play fetches the builder at the commit the recipe names
(from <https://github.com/myMartek/vivecraft-visionos>, a fork of the port) and builds the game's parts on your Mac
from what Mojang's servers deliver. They stay on your Mac and your headset.

The fork carries this project's changes to the port, all in the same licences as the files they change: the build
script for AVP Play (`tools/avpplay/`, MIT), one more Vivecraft patch (no seated play mode on the Vision Pro,
LGPL-3.0 like Vivecraft), the bake's capture of the classes Mixin generates on demand, the option defaults (render
distance 5, simulation distance 8, the HUD in front of close blocks) and a small helper that keeps the game's window
invisible while the build runs it on the Mac (MIT).

**Downloaded and built on your Mac by that build, not passed on by this project:** Oracle GraalVM JDK 25.0.4 (GraalVM
Free Terms and Conditions; the build's log names them when it fetches it), CMake (BSD-3-Clause) and Ninja (Apache-2.0)
for the build itself, and the sources of the game's native libraries – OpenAL Soft (LGPL-2.0-or-later), LWJGL
(BSD-3-Clause), FreeType (FreeType License), libffi (MIT), shaderc, SPIRV-Tools and SPIRV-Cross (Apache-2.0),
glslang (BSD-3-Clause and others), PojavLauncherTeam's LTW (LGPL-3.0) and Simple Voice Chat's codecs (Opus, RNNoise
and Speex under BSD-style licences, LAME under LGPL-2.0), each at the commit or with the checksum the build pins. The
game's own picture on the game's page is fetched from Mojang's resource server and checked against its name; it is
not part of the app either.

The toolchain package carries the app around the game (Klepton's `visionos/` for this target, MIT) and the licence
texts the game's app shows (`visionos/Licenses/vivecraft/`), no part of the game.

The built game holds, besides Minecraft itself (Minecraft EULA; it needs a Microsoft account that owns Minecraft:
Java Edition), Vivecraft and the mods the port brings – among them Sodium (Polyform Shield 1.0.0), Lithium,
Krypton, ImmediatelyFast and Cloth Config (LGPL-3.0), Fabric (Apache-2.0) and LWJGL (BSD-3-Clause). The port's
`THIRD-PARTY.md` lists every part with its version and licence, and the notices and licence texts are inside the
game's app (`Licenses/`). Some of the mods may not be passed on (Simple Voice Chat: all rights reserved; Entity
Culling: tr7zw Protective License) – one reason more why only your own Mac builds the game. Minecraft is a trademark of Microsoft/Mojang; this project is not affiliated with or
endorsed by Microsoft, Mojang Studios or the Vivecraft project.

## xrizer

From version 1.0.8 on, the Half-Life: Alyx recipe downloads a build of [xrizer](https://github.com/Supreeeme/xrizer) (OpenVR on top of
OpenXR, GPL-3.0) from this repository's releases. It is upstream xrizer at a pinned commit with two small changes;
the build script, both changes and the commit are in [`third-party/xrizer`](third-party/xrizer), and the release
carries the complete patched source next to the binary. It is a separate program that the game loads on the
headset; it is not part of the app or the toolchain package.

# Third-party software

AVP Play itself (this repository) is MIT-licensed and has no third-party code dependencies beyond Apple's
system frameworks.

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
| [BSML](https://github.com/bsq-ports/Quest-BSML) 0.6.5 – menu framework | bsq-ports | MIT (per the authors; no licence file in the repository yet) |
| [Lapiz](https://github.com/raineaeternal/Lapiz) 0.3.7 – modding library | raineaeternal | MIT |
| [SongCore](https://github.com/raineaeternal/Quest-SongCore) 1.3.5 – custom songs | raineaeternal | MIT |
| [PlaylistCore](https://github.com/Metalit/PlaylistCore) 1.7.2 – playlists | Metalit | GPL-3.0 |
| [SongDownloader](https://github.com/darknight1050/SongDownloader) 0.9.1 – song downloads | darknight1050 | GPL-3.0 |
| [BeatSaverPlusPlus](https://github.com/bsq-ports/BeatSaverPlusPlus) 0.2.4 – BeatSaver access | bsq-ports | MIT |
| [WebUtils](https://github.com/bsq-ports/WebUtils) 0.6.9 – web requests | bsq-ports | MIT (per the authors; no licence file in the repository yet) |
| [SongDetails](https://github.com/bsq-ports/SongDetails) 1.0.5 – song database | bsq-ports | MIT (per the authors; no licence file in the repository yet) |
| [MetaCore](https://github.com/Metalit/MetaCore) 2.0.6 – modding library | Metalit | MIT (per the authors; no licence file in the repository yet) |
| [MetaCoreBS](https://github.com/Metalit/MetaCoreBS) 1.0.1 – modding library | Metalit | MIT (per the authors; no licence file in the repository yet) |
| [Unicode](https://github.com/Metalit/UnicodeQuest) 0.1.8 – text in all scripts | Metalit | MIT (per the authors; no licence file in the repository yet) |
| [PlayerDataKeeper](https://github.com/Metalit/PlayerDataKeeper) 0.2.7 – save backups | Metalit | MIT (per the authors; no licence file in the repository yet) |
| [BetterSongSearch](https://github.com/bsq-ports/BetterSongSearchQuest) 2.3.0 – song search | bsq-ports | MIT |
| [Airbuds Search (as Apple Music Search)](https://github.com/zilewang7/Beat-Saber-Airbuds-Search) 2.0.2 – songs from your listening history | zilewang7, based on Spotify Search by TychoTheTaco; Apple Music history by this project | MIT (per the authors; no licence file in the repository yet) |

The search mod reads the player's Apple Music history on the headset instead of Airbuds (a change of this project).
Where a repository has no licence file yet, its authors said MIT is what they want. The mods' authors asked to be
named where players see it: the game's start window (Settings › Mods) and AVP Play (Settings › Software used) list
them as here.

## xrizer

From version 1.0.8 on, the Half-Life: Alyx recipe downloads a build of [xrizer](https://github.com/Supreeeme/xrizer) (OpenVR on top of
OpenXR, GPL-3.0) from this repository's releases. It is upstream xrizer at a pinned commit with two small changes;
the build script, both changes and the commit are in [`third-party/xrizer`](third-party/xrizer), and the release
carries the complete patched source next to the binary. It is a separate program that the game loads on the
headset; it is not part of the app or the toolchain package.

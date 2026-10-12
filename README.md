# AVP Play

AVP Play is a Mac app that installs VR games **you already own** on your Apple Vision Pro.

It downloads your purchased Quest games from Meta with your own account, translates them on your Mac with the
[Klepton](https://github.com/shinyquagsire23/Klepton) toolchain, signs them with your own Apple developer
account and copies them to your headset. No game content is distributed with this project, and nothing is
downloaded that Meta does not confirm you have purchased.

> **Status: first public release.** It has been built and used by one person, on one Mac with one Vision Pro.
> Expect rough edges, and please report what happens on your setup.

## What you need

| | |
|---|---|
| Mac | Apple silicon, macOS 14 or later, with [Xcode](https://apps.apple.com/app/xcode/id497799835) and its visionOS platform installed |
| Headset | Apple Vision Pro, paired with Xcode, Developer Mode on, on the same Wi-Fi as the Mac |
| Apple account | A paid [Apple Developer Program](https://developer.apple.com/programs/) membership. Free teams do not work: the entitlements the games need are missing. |
| Meta account | The account that owns the games, and Meta's own command-line tool [`ovr-platform-util`](https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/) (used only to sign in). You download it from Meta's page; the app finds the download and sets it up. |
| Controllers | Whatever the game needs – most of these games expect tracked controllers. An ordinary game controller (DualSense, Xbox, …) also works together with your hands: the hands show where they are and pinch to grab, the controller adds both sticks and the buttons. Moss is set up for this. |
| Disk space | Games are large. Asgard's Wrath 2 alone is about 34 GB on the Mac and again on the headset. |

## Install

1. Download `AVP-Play-<version>.dmg` from the [latest release](../../releases/latest), open it and drag
   **AVP Play** into Applications.
2. Open AVP Play. The **Setup** page checks the five things it needs (Xcode, Vision Pro, Apple developer team,
   Meta account, toolchain) and tells you what to do for each one that is missing. The toolchain comes with the
   app and installs itself.
   For the Meta account, the app opens Meta's download page for its sign-in tool; once the file is in your
   Downloads folder the app picks it up by itself – you do not have to move it or make it executable.
3. Pick a game under **Games** and click **Install**. The **Jobs** page shows the steps. A job can be
   interrupted at any point and resumed later; nothing that was downloaded or copied is lost.

Not everything set up yet? A game's files can be downloaded as soon as its account is signed in – **Download
Files Now** on the game's page needs neither Xcode nor a developer team nor the headset. Building and installing
follow once Setup is complete, without downloading again.

Every installed game opens with the same start window: its picture, its name, **Start** and **Settings**.

The app speaks English and German. It follows macOS; you can choose a language in its settings (⌘,).

**Your disk space.** The page *Data* lists what has been downloaded, game by game and down to the file, and
removes it again. Under Settings › Downloads you can keep the downloads on another disk, for example an external
one; what is already there moves over, with a progress bar. While that disk is not connected, nothing is
downloaded or installed. The folders there are named after identifiers; a text file beside them, `AVP Play –
Index.txt`, says which folder is which game, and a game's page shows its folder in Finder.

**Your saved games.** AVP Play copies what a game has saved from the Vision Pro to your Mac: after you quit the
game, every few hours while the app is open, and on a button. Each change is kept as a copy of its own, so
nothing is overwritten, and the copies stay when you remove the game from the headset – which a free Apple
account, with its three apps at a time, makes you do. Install the game again and it gets its saved games back,
if it has none on the headset; a button on the game's page puts a copy back on request. The copies never leave
your Mac: they are kept in `AVP Play Saved Games` next to your downloads folder if you have chosen one, otherwise
with the app's data. This covers games that come as an Android app – all Meta Store games, Doom 3,
Counter-Strike – and not yet the ones that run as Linux programs (Half-Life: Alyx, which has Steam Cloud
instead). Settings › Saved Games turns the automatic part off.

**Cable or Wi-Fi.** Games are copied to the headset over whatever connects it to the Mac. With a USB cable on
the Developer Strap macOS uses the cable by itself, and copying is many times faster; Setup, the sidebar and the
progress line of a job say which connection is in use.

**Your list of games.** The games you have downloaded, the ones in your Meta account and your favourites can be
written to a text file (*Data* › Export Game List, or the list the overview shows with *Installed*, *Downloaded,
Not Installed* or *Favourites* set) – to pass on, for example to this project, so that it knows which games
people have that do not run yet. It is only a list: no game files, nothing about your account or device.

**Updates.** Once a day the app asks GitHub whether a newer release exists and offers to install it. It replaces
itself only with a version that is signed by the same developer and notarised by Apple. You can turn the check
off in the settings.

## Games

A game needs a *recipe*: a small JSON file that names the exact build, its files and their checksums. The
recipes in [`recipes/`](recipes) are:

| Game | Source | Notes |
|---|---|---|
| Asgard's Wrath 2 | Meta Store | text and voices follow the headset's language; voice packs are an optional tick |
| Batman: Arkham Shadow | Meta Store | optional voice languages |
| Beat Saber | Meta Store | purchased song packs are downloaded and unlocked; the current version (1.45) is drawn at the display's full resolution with foveated rendering (on by default); edge smoothing (2x/4x) is a setting in the game's start window, off by default |
| Moss | Meta Store | |
| Walkabout Mini Golf | Meta Store | purchased courses and content packs are unlocked; the first start compiles shaders for a few minutes |
| SUPERHOT VR | Meta Store | |
| Steam Link | Meta Store | streams SteamVR from a PC on your network |
| Marvel's Deadpool VR | Meta Store | about 51 GB; the first start compiles shaders for several minutes |
| Alien: Rogue Incursion | Meta Store | about 14 GB; lowers its own resolution a little under load; loading screens flicker |
| Assassin's Creed Nexus VR | Meta Store | about 29 GB; edges shimmer somewhat, passthrough is not supported |
| Eye of the Temple | Meta Store | the whip is drawn thanks to a fix a user sent in |
| Resident Evil 4 | Meta Store | about 8.5 GB; runs with a fix a user sent in |
| Skydance's BEHEMOTH | Meta Store | about 28 GB; runs with fixes users sent in; the first start builds shaders behind the loading screen for several minutes |
| Maestro | Meta Store | song packs you bought are unlocked (checked with one pack); others are skipped; edge smoothing as a setting, off by default |
| Star Wars: Tales from the Galaxy's Edge | Meta Store | about 7 GB; runs with a fix a user sent in and the project's own |
| BattleGlide | Meta Store | early-access build (0.4.1) |
| Counter-Strike (Team Beef's CSVR) | free port + your own Counter-Strike files | the game data is fetched from your Steam account; your own servers can be listed per game |
| Doom 3 (Doom3Quest) | free port + your own Doom 3 files | `pak000`–`pak008.pk4` from your copy of Doom 3 – fetched from your Steam account, or from a folder you choose |
| Half-Life: Alyx | your own Steam copy (Linux build) | the game (about 73 GB) is fetched from your Steam account; the app downloads Steam Linux Runtime (from Valve) and xrizer (from this repository) itself; a German fan voice-over from the game's Steam Workshop is an optional tick, and the game's start window on the Vision Pro switches between English and German |

These nineteen are marked **Verified**: the project has tested them on a Vision Pro. The app also lists every other
Quest title from the Meta Store – some 17,000, loaded page by page as you scroll. What you see on each is a label:

| Label | Meaning |
|---|---|
| **Verified** | tested by the project, with a recipe in this repository |
| **Community Verified** | more users report that it runs than that it does not, or it runs with a fix a user sent in that the project has taken over but not tested itself |
| **Untested** | nobody has reported yet, or the reports are tied |
| **Incompatible** | more users report that it does not run, or the project has looked at it and knows why it cannot – the game's page then says why |

If you own a game, you can try it: the app looks up its files with your account and builds it – with the
toolchain's own entry for that game where there is one, otherwise with a generic one that only goes by the
engine. Each verified game needed its own adjustments before it ran, so expect an untested game not to start.
Afterwards say how it went with one click (that is what the labels are made of), or let an AI coding assistant
try to fix it ("Fix with AI") and send the fix in for review.

All nineteen were installed with this app on the author's headset. "Community Verified" means exactly what it
says: reports from users, not a guarantee. A recipe is tied to one build of a game; other builds need
their own recipe.

## How it handles your accounts

- **Meta sign-in** runs through Meta's own tool. AVP Play is only the window in front of it: what you type goes
  to that tool and is not stored. The access token Meta returns is kept in the macOS keychain and nowhere else.
  It is sent only to Meta, only as a request header, and never appears in logs.
- **Steam sign-in** (optional, for Doom 3 and Half-Life: Alyx) runs through Valve's own tool, SteamCMD. The app
  downloads it straight from Valve, checks before every start that the program is signed by Valve, and gives it a
  folder of its own, apart from a Steam you may have installed. Your password and Steam Guard code go to that tool
  only. SteamCMD remembers the sign-in in that folder – this is the one credential that is not in the keychain,
  because Valve's tool keeps it itself; "Sign Out" deletes the folder. Before anything is requested the app asks
  Steam whether your account owns the game, and Steam itself only hands out what it does. You do not need Steam
  installed. Valve ships SteamCMD as an Intel program, so a Mac that has never run one needs Apple's Rosetta once;
  the Setup page says so and installs it at the click of a button.
- **Steam Cloud saves for Half-Life: Alyx** (optional, new and still rough) are the one sign-in that happens on
  the headset: in the game's settings there you type your Steam name and password and confirm in the Steam app.
  The password goes to Steam, encrypted, and is not stored; the session Steam returns stays in the headset's
  keychain. Nothing of it reaches your Mac, this project or anyone else. At each start the saves on the headset
  and in your Steam Cloud are brought in step, in both directions, and a save is never replaced without a copy of
  it being kept. Sign out or switch it off in the same place.
- **Pictures** of games whose files are not on your Mac yet come from the game's public page in the Meta Store
  (meta.com): only for games you are looking at, two at a time, without your Meta sign-in or cookies. A small
  copy is kept in a cache (`~/Library/Caches/AVPPlay`) that the *Data* page can empty; Settings › Pictures turns
  this off. Games whose store page names no picture keep a coloured tile with their name.
- **Ownership** is asked of Meta before anything is downloaded, and once a day so the app can show which games
  are yours. A game that counted as not owned is asked about again within the hour, and **Check Purchase** on a
  game's page asks right away. Add-on content is downloaded only for purchases Meta confirms. Bought
  something later? **Sync DLCs** on the game's page asks again, downloads what is new and adds it to the installed
  game without building it again.
- **Shaders ahead of time.** Where the project has a list of the shader combinations a game uses (Half-Life: Alyx,
  Walkabout Mini Golf), the Vision Pro compiles them before the game starts – once, with a progress bar – instead
  of one at a time in the middle of play. Such a list holds no shader code, only where each shader lies in the
  game's files; your Mac builds the archive from your own copy of the game, and it goes to your own headset only.
- **Requests to Meta** stop at the first unexpected answer. The app never tries a file to see whether Meta will
  serve it.
- **Which version of a game:** a game's page has a menu of versions. At the top are the ones the project has
  tested and keeps a recipe for – the recommended one, and for some games an earlier one (Beat Saber 1.40.8
  beside 1.45) – and below them the other versions the Meta Store names for a game you own, marked as untested.
  For that list the app asks Meta which versions there are – at most once in twenty hours per verified game, and
  for other games when you open their page – with the query the store's own apps use (it is not a documented
  developer interface). Nothing changes on the headset until you install. Files that did not change between two
  versions are taken from the copy on your Mac instead of being downloaded again. Beat Saber's song packs move to
  another version with it; songs that are newer than the tested version are not fetched until the project has
  tested a version that has them.
- **Apple signing** uses the team you are signed in with in Xcode. The app reads the list of teams from Xcode's
  settings and nothing else.
- **The project's own service** (`avpplay.martek.de`) holds the list of further games and what users report about
  them. The app sends it what you search for and the identifiers of games whose page you open; a report you
  choose to send says which game and build, and whether it works. It never receives your Meta sign-in or
  anything about your account or device, and you can turn it off in the settings.
- **There is a little telemetry**, purely out of curiosity about how much AVP Play is used and which games
  people actually install with it. Once a day the app tells the project's service that it is in use, with its
  version number, and once per game that you have installed it. Neither message carries an identifier of you,
  your Mac or your Vision Pro, and the service keeps nothing but totals per day. You can turn it off under
  Settings › Online catalogue.
- There is no account with this project. The only other connection the app makes is the daily question to
  GitHub about a newer release, which you can turn off as well.

## Build it yourself

```bash
git clone https://github.com/myMartek/avp-play.git
cd avp-play/core
swift test                      # the library's tests
tools/make-app.sh               # builds ../dist/AVP Play.app (ad-hoc signed, for this Mac only)
```

`make-app.sh` puts the newest `dist/klepton-toolchain-*.tar.gz` (with the `.json` file next to it) into the
app. Download both from a release and place them in `dist/`, or point `AVPPLAY_TOOLCHAIN_ARCHIVE` at the
archive. `tools/make-release.sh` builds the disk image; with `AVPPLAY_SIGN_IDENTITY` and
`AVPPLAY_NOTARY_PROFILE` set it signs and notarises it.

The repository:

| | |
|---|---|
| `core/Sources/AVPPlayCore` | the library: recipes, the local library of files, Meta client, device control, install steps, jobs, toolchain packages |
| `core/Sources/AVPPlayApp` | the Mac app (SwiftUI) |
| `core/Sources/avpplay` | a command-line tool with the same functions |
| `recipes/` | the recipes |

The format of the recipes is described in [docs/recipes.md](docs/recipes.md); how to report a problem or
contribute in [CONTRIBUTING.md](CONTRIBUTING.md). Code comments are mostly German; everything a user sees is in
English and German.

## The toolchain

Games are translated by a fork of [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas (MIT),
extended for the games above. The toolchain package that ships with the app contains that fork's complete
source together with prebuilt ANGLE and MoltenVK libraries and their licence texts; see
[THIRD-PARTY.md](THIRD-PARTY.md).

## Experimental local Windows VR

The separate Windows VR research app has source implementations for a visionOS
launcher/compositor, a Madeira Wine/FEX adapter, a D3D11 guest OpenXR runtime,
and OpenComposite packaging. An [experimental DXMT D3D12 source path](docs/windows-vr-d3d12.md)
adds guest bindings, queue transport, the native mobile port and explicit
matching native/guest build recipes. Launch remains gated on actual package
artifacts. It is **not a released or validated Windows game
runtime** and does not change the existing Quest or Linux ARM64 installer.

See [the implementation status](docs/windows-vr-status.md),
[engineering plan](docs/windows-vr-plan.md), and
[source integration guide](docs/windows-vr-integration.md). An unsigned visionOS 27 app and validated runtime package have built locally.
Signing, JIT/device compatibility, and game execution remain delivery gates;
source code is not evidence of performance or game compatibility.

## Thanks to Glovebox

[Glovebox](https://github.com/glovebox-vr/glovebox) brings Half-Life: Alyx to the Apple Vision Pro on its own, and
its developers published all of it under the MIT licence. A good part of how Half-Life: Alyx runs here was worked
out there first. Thank you – for the work, and for making it open.

What this project took over from Glovebox, each named in the source where it lives:

- **Shaders prepared before the game starts.** The game's Vulkan pipelines are compiled while the start window is
  still up, with Valve's [Fossilize](https://github.com/ValveSoftware/Fossilize), instead of one at a time in the
  middle of play. The method, the recorder and replayer, the recipe format and Glovebox's own pipeline list for
  the game are theirs. The list holds no shader code, only where each shader is in your own copy of the game;
  your Mac rebuilds it from that copy.
- **Steam Cloud saves.** The connection to Steam, the sign-in and the two-way sync of saves are parts of
  Glovebox's `SteamLauncherKit`, with its rules for never replacing a save by something it did not come from.
- **Graphics settings that fit those shaders:** its detail settings for the game, a lighter final pass onto the
  display, and textures that stream in faster.
- **A frame is handed over when the graphics chip has finished it**, rather than the game waiting for that.
- **Free Apple accounts.** That a free account is enough for a game this large – Apple grants it the extra
  memory – is something Glovebox showed.

These changes are in the toolchain's source and come to the app with its next toolchain release.

## Legal

AVP Play is an independent open-source project. It is **not affiliated with, endorsed by or supported by Apple,
Meta, or the publishers of any game**. Apple Vision Pro, Meta Quest and the names of the games are trademarks
of their respective owners.

It is meant for one thing: playing games you have bought, on a headset you own. It contains no game content and
does not remove or bypass purchase checks – it asks Meta what you own and installs only that. Whether using
your purchases this way is permitted by the terms of the stores and games involved is for you to check; you use
this software at your own risk. See [LICENSE](LICENSE) (MIT) for the terms of this project itself.

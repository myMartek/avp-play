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
| Meta account | The account that owns the games, and Meta's own command-line tool [`ovr-platform-util`](https://developers.meta.com/horizon/resources/publish-reference-platform-command-line-utility/) (used to sign in, to look up the files of a game nobody has tested yet, and as a second way to download a file when Meta's direct address refuses it). You download it from Meta's page; the app finds the download and sets it up. |
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
   interrupted at any point and resumed later; nothing that was downloaded or copied is lost. Several jobs
   run one after another, from the bottom of the list upwards; drag a waiting job to change when its turn is.

Not everything set up yet? A game's files can be downloaded as soon as its account is signed in – **Download
Files Now** on the game's page needs neither Xcode nor a developer team nor the headset. Building and installing
follow once Setup is complete, without downloading again.

Every installed game opens with the same start window: its picture, its name, **Start** and **Settings**.
Settings holds the picture's dials – foveated rendering, resolution, and edge smoothing where a game can take
it: for a Vulkan game that smooths its edges by itself with fewer than four samples the choice appears after the
game has run once. A Vulkan game also gets *Foveated rendering* as a choice of five (Off, Light, Medium, Strong, Very strong; from toolchain 485 *Strong* has a smaller sharp middle and a finer edge)
once it has run: the edge of the picture is drawn more coarsely, the middle stays as it is. Under *Advanced*,
*Display output* says how finely the finished picture is put on the display;
it starts at *Light*, which leaves the graphics chip more time for the game. *Frame rate* offers *Up to 100*, the
default, and *Up to 120*, which is smoother where the game manages it and the Vision Pro's display can do it; when
a game cannot keep up, the Vision Pro halves the rate for a while (100 to 50, 120 to 60). Mixed-reality games have
no such choice: their room shows only in the space that runs at up to 100. Where a game shows a player name it
takes from the headset's account and cannot change itself, Settings has a *Player name* field for it. *Advanced*
› *Test* holds switches for behaviour that is built in but not the default (for instance the sound block size from
before toolchain 478, – from toolchain 507 – one head pose for a whole frame of a game that talks to Meta's own
interface, or – from toolchain 507 – a second implementation of everything between a game's sound interface and
the output, *Sound: the new audio path*); each one applies from the next start.

**How a game is running** (from toolchain 507). In every game, hold **Create** and **Options** on the controllers
together for a second: a small panel appears just above the middle of the view, and the same again puts it away.
It shows the last second in numbers – frames a second and the rate the display runs at, shaders that had to be
compiled and ones that were only fetched, how busy the graphics chip is and how long it works on one frame of the
game, the processor's load and its busiest thread, memory, heat, the size of the picture – and the last minute as
three graphs: frame rate, load, shaders. A dip in the frame rate with a red bar under it was a shader being
compiled. The panel is in English and is drawn into the game's picture, so it is as sharp as *Display output*
makes that. Nothing is measured before the panel is first shown. *Advanced* › *Test* › *Show performance in the
headset from the start* has it there when the game opens. So that a game does not open its menu along with the
panel, one of the two buttons alone reaches the game a quarter of a second after you press it.

**Trying the new pose and audio implementations in every game** (from version 1.1.15 with toolchain 507). The
toolchain carries a second implementation of two things every game runs on – the head pose a game gets for a frame,
and everything between a game's sound and the output – as test switches that are off. *Settings › Experimental*
in this app has one switch for both: with it on, every game you install or update has them switched on from the
start, as if the old ones were gone; in a game each can still be turned off under *Advanced › Test*. Games that
are already installed then show "Update available", and **Update All** on the Games page rebuilds them – the same
again after you turn the setting off. Saved games and data are kept. A game with a toolchain of its own choosing
is left as it is, and renewing a signature keeps what a build had.

**MetalFX upscaling** (prepared; takes effect with a toolchain that has it). Below 100% *Resolution* a game draws
a smaller picture that is stretched to the display. Klepton's compositor can do that stretch with Apple's MetalFX
spatial scaler instead of a linear one – a sharper picture for a little graphics time – and has a switch for it in
the game (*Settings › Rendering › MetalFX upscaling*, off). *Settings › Experimental › MetalFX* in this app switches
it on from the start in every game you install or update, the same way as the switch above; off, the default,
changes nothing. At 100% there is nothing to upscale, so switching it on also sets the resolution a game starts at
to 75% (a slider below the switch; a value you choose there counts, and switching off brings back the one from before,
or 100%); what you choose in a game itself counts there, also after an update. It works in every game – Vulkan and GL,
through Meta's own interface or OpenXR (Half-Life: Alyx, Steam Link, Doom 3, Walkabout, Beat Saber 1.45), with foveated
rendering on, too; only a picture that cannot be scaled safely keeps the linear stretch, and the game's log says why.
The metrics panel in the headset (Create + Options held for a second) shows the resolution the game renders at,
whether MetalFX is upscaling and on which path, and the resolution after it; with the panel shown, a short tap of
Create + Options together switches MetalFX on and off while the game runs. The bundled toolchain 507 does not have
it yet; until one does, the setting says so and games are built as usual.

**XR prediction** (a game's page › *Test*; takes effect with a toolchain that has it). Newer toolchains give a game
its head pose without prediction by default – one pose per frame, as it is when the frame starts, on every path
(OpenXR and Meta's own interface). The option switches the old behaviour back on for that game, which predicts the
head to the moment the picture is shown; it applies from the next install or update, to every build, and in the game
it stays switchable under *Settings › Advanced › Test*. `avpplay install --xr-prediction` does the same. Toolchain 507
always predicts.

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
Not Installed*, *Favourites* or *Favourites Not Downloaded* set) – to pass on, for example to this project, so
that it knows which games people have that do not run yet. It is only a list: no game files, nothing about your
account or device. *Favourites Not Downloaded* is also the quick way to see what of your favourites is still to
fetch to this Mac.

**Mixed reality.** The overview's *Mixed Reality* filter shows the games whose mixed-reality mode works with AVP
Play – your own room around the game. At the moment these are TRIANGLE STRATEGY, Demeo and Richie's Plank
Experience.

**Updates.** Once a day the app asks GitHub whether a newer release exists and offers to install it. It replaces
itself only with a version that is signed by the same developer and notarised by Apple. You can turn the check
off in the settings.

## Games

A game needs a *recipe*: a small JSON file that names the exact build, its files and their checksums. The
recipes in [`recipes/`](recipes) are:

| Game | Source | Notes |
|---|---|---|
| Asgard's Wrath 2 | Meta Store | text and voices follow the headset's language; voice packs are an optional tick; the first start compiles shaders for several minutes, on the game's own screen |
| Batman: Arkham Shadow | Meta Store | optional voice languages; from toolchain 478 drawn at 4608 pixels an eye and full resolution with foveated rendering at *Strong* (before: 3072 at 70 %) – both are settings in the game's start window, and a copy installed earlier takes the new defaults once |
| Beat Saber | Meta Store | purchased song packs are downloaded and unlocked; the current version (1.45) is drawn at the display's full resolution with foveated rendering (on by default); edge smoothing (2x/4x) is a setting in the game's start window, off by default |
| Moss | Meta Store or Steam | from toolchain 485 drawn at the display's own resolution (4608 pixels an eye) with foveated rendering at *Strong*, 16x anisotropic filtering and a frame on every second refresh of the display (an even 60 of 120); before, it ran at about 45 frames a second. A copy installed earlier takes the new picture once. If you bought it on Steam instead, choose **Purchased from: Steam** on its page (from toolchain 507): the app fetches the Android build Steam ships (for Steam Frame, about 2.7 GB) from your Steam account; jump is Cross, attack is Circle or Square. No older versions for the Steam copy, and its saved games are separate |
| Walkabout Mini Golf | Meta Store or Steam | purchased courses and content packs are unlocked; the first start compiles shaders for a few minutes. If you bought it on Steam instead, choose **Purchased from: Steam** on its page: the app then fetches the Android build Steam ships (for Steam Frame) from your Steam account and unlocks the add-ons Steam confirms for it. No older versions for the Steam copy |
| SUPERHOT VR | Meta Store | |
| Steam Link | Meta Store | streams SteamVR from a PC on your network; asks for the local network when it opens – allow it, or the PC waits for a connection (before toolchain 380 a new install was never asked); from 380 its requests to Steam's servers get through and its start window closes once the stream is up, thanks to fixes a user sent in |
| Marvel's Deadpool VR | Meta Store | about 51 GB; the first start compiles shaders for several minutes; edge smoothing at 4x and, from toolchain 478, foveated rendering at *Medium* by default (settings in the game's start window) |
| Alien: Rogue Incursion | Meta Store | about 14 GB; lowers its own resolution a little under load; loading screens flicker |
| Assassin's Creed Nexus VR | Meta Store | about 29 GB; edges shimmer somewhat, passthrough is not supported |
| Eye of the Temple | Meta Store | the whip is drawn thanks to a fix a user sent in |
| Resident Evil 4 | Meta Store | about 8.5 GB; runs with a fix a user sent in |
| Skydance's BEHEMOTH | Meta Store | about 28 GB; runs with fixes users sent in; the first start builds shaders behind the loading screen for several minutes |
| Maestro | Meta Store | song packs you bought are unlocked (checked with one pack); others are skipped; edge smoothing as a setting, off by default |
| Star Wars: Tales from the Galaxy's Edge | Meta Store | about 7 GB; runs with a fix a user sent in and the project's own |
| BattleGlide | Meta Store | early-access build (0.4.1) |
| TRIANGLE STRATEGY | Meta Store | about 7.5 GB; its mixed-reality mode works – your room shows around the playing field; runs with a fix a user sent in |
| Demeo | Meta Store | about 4.3 GB; its mixed-reality mode works – your room shows around the board; it cannot sign in to its maker's account service (that needs Meta's own sign-in proof) and plays with a local player, whose name you set in the start window; playing online with others has not been tried |
| Vampire: The Masquerade – Justice | Meta Store | about 7 GB |
| Red Matter 2 | Meta Store | about 9 GB; changes its picture's resolution with the load |
| Tetris Effect: Connected | Meta Store | about 2.2 GB; drawn at the display's own resolution (a setting in the game's start window) |
| Pistol Whip | Meta Store | about 1.6 GB; runs with fixes users sent in |
| Counter-Strike (Team Beef's CSVR) | free port + your own Counter-Strike files | the game data is fetched from your Steam account; your own servers can be listed per game |
| Doom 3 (Doom3Quest) | free port + your own Doom 3 files | `pak000`–`pak008.pk4` from your copy of Doom 3 – fetched from your Steam account, or from a folder you choose |
| Half-Life: Alyx | your own Steam copy (Linux build) | the game (about 73 GB) is fetched from your Steam account; the app downloads Steam Linux Runtime (from Valve) and xrizer (from this repository) itself; a German fan voice-over from the game's Steam Workshop is an optional tick, and the game's start window on the Vision Pro switches between English and German; from toolchain 478 the eyes of characters no longer flash in solid colours, and on the Vision Pro with the M5 the presets *Balanced* (the default) and *Sharp* in the game's start window draw the largest picture with detailed textures at an even half of the display rate (50 pictures a second), *Balanced* with strong foveated rendering and without bloom and ambient occlusion – found by play on one headset; how warm it gets over a long session is not measured yet. Frame cadence, effects and texture memory are settings under *Custom*, a frame-rate readout can be switched on, and a copy installed earlier keeps a custom set as it was. On the first Vision Pro (M2) the two presets are the same with the picture one size smaller; nobody has run them there yet |

These twenty-two are marked **Verified**: the project has tested them on a Vision Pro. The app also lists every other
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

A game is built with the newest toolchain. From version 1.1.12 its page lets you choose another one for it: an
older package – one still on your Mac, or one that came with an earlier release, which the app downloads from
this repository's releases and checks before it installs it – or a working copy that an AI assistant changed
while fixing the game, shown as "(modified)". The game then stays on that toolchain when the app gets a newer
one, when the game is updated and when its signature is renewed. The app removes older toolchains by itself to
save disk space; one that is chosen for a game stays, and a switch in Settings turns the tidying off.

All twenty-two were installed with this app on the author's headset. "Community Verified" means exactly what it
says: reports from users, not a guarantee. A recipe is tied to one build of a game; other builds need
their own recipe.

## How it handles your accounts

- **Meta sign-in** runs through Meta's own tool. AVP Play is only the window in front of it: what you type goes
  to that tool and is not stored. The access token Meta returns is kept in the macOS keychain and nowhere else.
  It is sent only to Meta, only as a request header, and never appears in logs.
- **Meta's tool** takes the token only as a command-line argument. While it lists a game's files, or downloads
  one that Meta's direct address refuses with HTTP 404 (it is tried once, then the job stops with the tool's
  reason), other programs of the same macOS user could see the token. Its own log goes to a folder that is deleted
  afterwards. When the tool answers "Cannot find apk with ID" – Meta does that to some accounts after many
  downloads – the app asks Meta for the build's details instead. That query is not in Meta's developer
  documentation (it is the one the public library OculusGraphQLApiLib calls `GetBinaryDetails`); only the files'
  IDs, names and sizes are read from the answer.
- **Steam sign-in** (optional, for Doom 3, Half-Life: Alyx and a Steam copy of Walkabout Mini Golf) runs through Valve's own tool, SteamCMD. The app
  downloads it straight from Valve, checks before every start that the program is signed by Valve, and gives it a
  folder of its own, apart from a Steam you may have installed. Your password and Steam Guard code go to that tool
  only. SteamCMD remembers the sign-in in that folder – this is the one credential that is not in the keychain,
  because Valve's tool keeps it itself; "Sign Out" deletes the folder. Before anything is requested the app asks
  Steam whether your account owns the game, and Steam itself only hands out what it does. You do not need Steam
  installed. Valve ships SteamCMD as an Intel program, so a Mac that has never run one needs Apple's Rosetta once;
  the Setup page says so and installs it at the click of a button.
- **A game bought on Steam instead of at Meta** (Walkabout Mini Golf and, from toolchain 507, Moss). When you open such a game for the
  first time, or click "Check Purchase", the app asks Meta first and then Steam. Found at Meta: it stays with
  Meta. Found only on Steam: it switches to Steam by itself. Found nowhere: it stays with Meta. You can also choose
  yourself under "Purchased from". The two copies are different builds with saves of their own; the app does not
  install one over the other – remove the installed one first (the headset deletes its saves with it; copies this
  app has already fetched stay on your Mac).
- **Steam Cloud saves for Half-Life: Alyx** (optional, new and still rough) are the one sign-in that happens on
  the headset: in the game's settings there you type your Steam name and password and confirm in the Steam app.
  The password goes to Steam, encrypted, and is not stored; the session Steam returns stays in the headset's
  keychain. Nothing of it reaches your Mac, this project or anyone else. At each start the saves on the headset
  and in your Steam Cloud are brought in step, in both directions, and a save is never replaced without a copy of
  it being kept. Sign out or switch it off in the same place.
- **Pictures** of games whose files are not on your Mac yet come from the game's public page in the Meta Store
  (meta.com): only for games you are looking at, two at a time, without your Meta sign-in or cookies. A small
  copy is kept in a cache (`~/Library/Caches/AVPPlay`) that the *Data* page can empty; Settings › Pictures turns
  this off. A few store pages show no picture to a visitor who is not signed in (Richie's Plank Experience);
  for such a game the picture comes from the project's catalogue service, which is asked only when the catalogue
  names one. Other games without a picture keep a coloured tile with their name. When a game is installed, its
  icon and start picture come from the store page too, and from the catalogue service when the page gave none.
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
  settings and nothing else. One thing it may add to your Mac: if your signing certificate is there but Apple's
  intermediate certificate that issued it is not (a key that came from a backup or another Mac), nothing can be
  signed. The app then fetches that one certificate from apple.com, checks with macOS that it issued yours and
  leads to Apple's root, and adds it to your login keychain.
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

A test copy of a game can sit next to the installed one: give it its own identifier and a name to tell it apart,
for example `avpplay install moss --team <team ID> --bundle-id com.example.test.moss --display-suffix " (Test)"`
(or `--display-name <name>` for a whole new name). Signatures are remembered per identifier
(`.signing/<identifier>.json` in the game's folder), so the test copy doesn't replace the game's own; `renew`,
`saves` and `servers push` without `--bundle-id` keep using the game's own installation (`.signing.json`, as before).

### A test copy next to the installed game (command line only)

The command-line tool can install a second copy of a game under its own bundle ID, with its own name on the
Vision Pro, without touching the installed game:

```bash
avpplay install <id> --team <team ID> --bundle-id com.example.test.<target> --display-suffix " (Test)"
```

`--display-name <name>` replaces the app's name entirely, `--display-suffix <text>` appends to it; both are
passed to the toolchain as `KLEPTON_DISPLAY_OVERRIDE` / `KLEPTON_DISPLAY_SUFFIX`. Left out, the name stays as
usual. The signature of each installation is remembered per bundle ID (`.signing/<bundle ID>.json` in the
game's folder); `.signing.json` stays the record of the installed game itself, so `renew`, `saves` and
`servers push` without `--bundle-id` keep working on it. The Mac app has no setting for any of this.

The format of the recipes is described in [docs/recipes.md](docs/recipes.md); how to report a problem or
contribute in [CONTRIBUTING.md](CONTRIBUTING.md). Code comments are mostly German; everything a user sees is in
English and German.

## The toolchain

Games are translated by a fork of [Klepton](https://github.com/shinyquagsire23/Klepton) by Max Thomas (MIT),
extended for the games above. The toolchain package that ships with the app contains that fork's complete
source together with prebuilt ANGLE and MoltenVK libraries and their licence texts; see
[THIRD-PARTY.md](THIRD-PARTY.md).

The fork is also a repository: [myMartek/Klepton](https://github.com/myMartek/Klepton), branch `avp-play`, with one
commit per toolchain that shipped with a release (tagged `toolchain-N`). Changes to the runtime are welcome there
as pull requests.

## Thanks to rebelancap

[rebelancap](https://github.com/rebelancap) keeps a Klepton fork of their own and offered its fixes to this one
([issue 16](https://github.com/myMartek/avp-play/issues/16)). From toolchain 478 a large part of them is in: fixed
foveated rendering for Vulkan games, a loader and a translator that cope with very large Unreal libraries, a wider
Android and Unreal surface for games not seen here yet, fixes to the OpenGL path, controller haptics that no longer
run on the thread that draws, sound handed over in blocks of 256 frames, sound that stops at once when the Digital
Crown is pressed, and answers to some 160 calls of Meta's headset interface that stopped a game here before. What changes how a game already listed
here behaves is a switch under *Test* until it has been seen on a headset. From toolchain 507 the fork's audio path
is in whole, beside the one that has shipped: the switch *Sound: the new audio path* picks it for a game, and it is
off unless you turn it on. The rest of the fork's work on head poses and the compositor is to follow. Thank you.

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
- **The eyes of characters no longer flash in solid colours** (toolchain 379). Glovebox found why: the game's eye
  shader reads past the end of a table, which a PC graphics card answers with zeros and Apple's with whatever lies
  there. Its rewrite of that shader is used here, widened from the one variant it names to the six the game has.
- **Smaller things** (toolchain 379): the game's files stay out of the headset's backup, where they would
  otherwise take their full size – for every game, not only this one; the game's video settings survive a
  visionOS update; the log of the run before the last is kept; a left-handed player's "Weapon Hand" setting moves
  the controls to the other controller (with the xrizer build the recipe downloads from then on); and the Mac app fetches a
  missing Apple intermediate certificate, described under Apple signing above.

These changes are in the toolchain's source and come to the app with its next toolchain release.

## Legal

AVP Play is an independent open-source project. It is **not affiliated with, endorsed by or supported by Apple,
Meta, or the publishers of any game**. Apple Vision Pro, Meta Quest and the names of the games are trademarks
of their respective owners.

It is meant for one thing: playing games you have bought, on a headset you own. It contains no game content and
does not remove or bypass purchase checks – it asks Meta what you own and installs only that. Whether using
your purchases this way is permitted by the terms of the stores and games involved is for you to check; you use
this software at your own risk. See [LICENSE](LICENSE) (MIT) for the terms of this project itself.

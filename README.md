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

Every installed game opens with the same start window: its picture, its name, **Start** and **Settings**.

The app speaks English and German. It follows macOS; you can choose a language in its settings (⌘,).

**Updates.** Once a day the app asks GitHub whether a newer release exists and offers to install it. It replaces
itself only with a version that is signed by the same developer and notarised by Apple. You can turn the check
off in the settings.

## Games

A game needs a *recipe*: a small JSON file that names the exact build, its files and their checksums. The
recipes in [`recipes/`](recipes) are:

| Game | Source | Notes |
|---|---|---|
| Asgard's Wrath 2 | Meta Store | optional language packs |
| Batman: Arkham Shadow | Meta Store | optional voice languages |
| Beat Saber 1.40.8 | Meta Store | purchased song packs are downloaded and unlocked |
| Moss | Meta Store | |
| Walkabout Mini Golf | Meta Store | purchased courses are unlocked |
| Doom 3 (Doom3Quest) | free port + your own Doom 3 files | you provide `pak000`–`pak008.pk4` from your copy of Doom 3 |
| Half-Life: Alyx | your own Steam copy (Linux build) | you also provide Steam Linux Runtime and xrizer as folders; see the recipe |

These seven are marked **Verified**: the project has tested them on a Vision Pro. The app also lists every other
Quest title from the Meta Store – some 17,000, loaded page by page as you scroll. What you see on each is a label:

| Label | Meaning |
|---|---|
| **Verified** | tested by the project, with a recipe in this repository |
| **Community Verified** | more users report that it runs than that it does not |
| **Untested** | nobody has reported yet, or the reports are tied |
| **Incompatible** | more users report that it does not run |

If you own a game, you can try it: the app looks up its files with your account and builds it – with the
toolchain's own entry for that game where there is one, otherwise with a generic one that only goes by the
engine. Each verified game needed its own adjustments before it ran, so expect an untested game not to start.
Afterwards say how it went with one click (that is what the labels are made of), or let an AI coding assistant
try to fix it ("Fix with AI") and send the fix in for review.

All seven were installed with this app on the author's headset. "Community Verified" means exactly what it
says: reports from users, not a guarantee. A recipe is tied to one build of a game; other builds need
their own recipe.

## How it handles your accounts

- **Meta sign-in** runs through Meta's own tool. AVP Play is only the window in front of it: what you type goes
  to that tool and is not stored. The access token Meta returns is kept in the macOS keychain and nowhere else.
  It is sent only to Meta, only as a request header, and never appears in logs.
- **Ownership** is asked of Meta before anything is downloaded, and once a day so the app can show which games
  are yours. Add-on content is downloaded only for purchases Meta confirms.
- **Requests to Meta are throttled** and stop at the first unexpected answer. The app never tries a file to see
  whether Meta will serve it.
- **Apple signing** uses the team you are signed in with in Xcode. The app reads the list of teams from Xcode's
  settings and nothing else.
- **The project's own service** (`avpplay.martek.de`) holds the list of further games and what users report about
  them. The app sends it what you search for and the identifiers of games whose page you open; a report you
  choose to send says which game and build, and whether it works. It never receives your Meta sign-in or
  anything about your account or device, and you can turn it off in the settings.
- There is no telemetry and no account with this project. The only other connection the app makes is the daily
  question to GitHub about a newer release, which you can turn off as well.

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

## Legal

AVP Play is an independent open-source project. It is **not affiliated with, endorsed by or supported by Apple,
Meta, or the publishers of any game**. Apple Vision Pro, Meta Quest and the names of the games are trademarks
of their respective owners.

It is meant for one thing: playing games you have bought, on a headset you own. It contains no game content and
does not remove or bypass purchase checks – it asks Meta what you own and installs only that. Whether using
your purchases this way is permitted by the terms of the stores and games involved is for you to check; you use
this software at your own risk. See [LICENSE](LICENSE) (MIT) for the terms of this project itself.

# Recipes

A recipe tells AVP Play exactly which build of a game it installs: which files belong to it, where each one
comes from, how large it is and what its checksum is. Recipes live in [`recipes/`](../recipes) as one JSON file
per game and ship inside the app.

A recipe is **not** enough to make a new game work. The translating toolchain has to support the game too: it
needs a *target* for it, and most games so far needed changes to the runtime before they ran. A recipe for a
game without a working target only produces an app that does not start. See [CONTRIBUTING](../CONTRIBUTING.md).

Recipes never contain game content, credentials or account data – only identifiers, sizes and checksums.

## Shape

```jsonc
{
  "schema": 1,
  "id": "moss",                       // also the file name: recipes/moss.json
  "title": "Moss",
  "package": "com.polyarc.MossGame",  // the Android package of the game
  "versionName": "1.0.3.151047",      // shown to the user
  "versionCode": 151047,              // the build this recipe is for
  "store": { "appId": "1654565391314903" },   // Meta Store app; {} for a game that is not from the store
  "toolchain": { "target": "moss", "minCommit": "6d185aa" },
  "files": [ … ],
  "addons": { … },                    // optional
  "trees": [ … ],                     // optional, for games that are folders rather than an APK
  "icon": { "steamAppId": "9050" },   // optional: take the icon from the local Steam library
  "mixedReality": true,               // optional: the game's mixed-reality mode works (the overview's filter)
  "assetFiles": [ … ],                // optional: asset packs the runtime reports as installed, see below
  "status": { "playability": "reported", "download": "proven", "notes": [ … ] }
}
```

`toolchain.target` names the target in the toolchain; `minCommit` is the oldest toolchain state the recipe works
with. The app refuses to build with an older toolchain.

`icon.steamClientIcon` (40 lowercase hex digits, only together with `steamAppId`) is the hash of the game's client icon in its
Steam entry. Older games have no library pictures on Steam; for them the app takes the largest picture of that icon
(fetched from Steam's CDN, kept in the library as `steam-icon.png`) as the app icon, after the game's own picture,
the Meta Store and the local Steam library.

### A toolchain of the game's own

Nearly every game is built with the project's toolchain, the Klepton fork. A game that is neither an Android nor a
Linux program cannot be: it needs a toolchain of another kind, and its recipe says so.

```jsonc
"toolchain": {
  "target": "skyrimvr",
  "minCommit": "0123456",
  "kind": "vxruntime",          // which kind of toolchain builds this game; absent for every Klepton game
  "title": "VXRuntime",         // optional: what the app calls that toolchain; absent: the kind stands there
  "source": {                   // optional: where the app fetches that toolchain from
    "repository": "https://github.com/<owner>/<name>",
    "commit": "0123456789abcdef0123456789abcdef01234567",   // all 40 characters; minCommit is its beginning
    "version": 410,             // the number stamped into the built app; a larger one in a later recipe offers an update
    "path": "tools/avpplay_toolchain"   // the folder in the repository that holds visionos/run.sh; absent: its root
  }
}
```

- A game with a `kind` is only ever built with a toolchain that says it is of that kind (`"kind"` in its
  `toolchain.json`), and such a toolchain builds nothing else. The game's page offers no Klepton package for it,
  and no other game is offered its toolchain.
- The app never shows such a toolchain's number bare: it counts another project's states, not Klepton's. The
  game's page, the Remote and every status line put the `title` in front (“VXRuntime 434”) and say that the game
  is built with a toolchain of its own.
- With `source`, the app fetches exactly that commit as part of the game's first job, into
  `~/.avpplay/toolchains/<kind>-<version>-<commit>` (not under “Application Support”: these build tools do not
  survive a blank in a path), checks that it got that commit, and writes the toolchain's description itself. The
  recipe therefore pins the toolchain state as it pins the game's files. Without `source`, the toolchain has to be
  chosen by hand: `avpplay toolchain use <id> --toolchain <folder>`, which also overrides a `source`.
- Such a toolchain is a folder that keeps AVP Play's contract with a toolchain: `visionos/run.sh device` builds and
  installs and ends with the line `BUILD SUCCEEDED`, `visionos/stage_sync.py` mirrors and copies the game's folder
  trees, `visionos/targets.py` has a `TARGETS` row for the target, and `visionos/gen_xcodeproj.py` names the build
  options it honours. The row may name where the trees go on the device (`devicetree`, a path below `Documents/`),
  which is where the app reads the copy's progress.
- Mods of a toolchain. A toolchain that can build its game with mods names `KLEPTON_GAME_MODS` in
  `visionos/gen_xcodeproj.py` and brings two more files. `visionos/mods.json` describes the sets the player can
  switch on (`schema` 1; `sets` with `id`, `title`, `about`, `default`, `macRun`, `downloadBytes` and the `mods` of
  each; `source` with the name of the site the files come from and, where the player's own key can fetch them, the
  environment variable it is handed over in). `visionos/mods_fetch.py` gets the files of the chosen sets onto the
  Mac: AVP Play runs it before the build with `KLEPTON_GAME_MODS=<ids>`, shows its lines `@@mods total|n`,
  `@@mods have|name|how`, `@@mods need|name|page` and `@@mods done|n` in its own words, draws
  `@@mods progress|name|bytes here|bytes in all` (a download with the key, about once a second) as the bar of a file, and takes exit status 2 as
  "the player has not downloaded everything yet". Where a file needs the player, the script opens the page in the
  browser and waits for the file; when the player cancels the job, AVP Play ends the script with SIGTERM, and the
  script ends whatever it started. `source.key` may carry a `hint`: which of the things on the key's page is the key. `run.sh device` then builds with the sets in `KLEPTON_GAME_MODS` (empty: none) and
  `stage_sync.py` puts their files on the device. AVP Play holds no mod files; the key, if the player stored one
  (`avpplay mods <id> --set-key`, or the Mods box), stays in the keychain and reaches only that script.

### Game parts built on the user's Mac

A game whose program is not delivered ready-made names a builder: a script in a public repository that makes the
game's parts on the user's own Mac, before the toolchain builds the app. Minecraft: Java Edition is the first – its
client comes from Mojang's servers and is compiled there ahead of time. Such a game is still built with the usual
toolchain (its target is of the kind `macho`); the builder is a field of its own.

```jsonc
"builder": {
  "source": {                   // one exact state, named like a game's own toolchain
    "repository": "https://github.com/<owner>/<name>",
    "commit": "0123456789abcdef0123456789abcdef01234567",   // all 40 characters
    "version": 1,               // counts the builder's states; with the commit it names the parts in the library
    "path": "tools/parts"       // optional: the folder in the repository that holds tools/avpplay/build_parts.sh
  },
  "notes": [                    // what the user is told before the first build: how long, what the Mac needs, what they will see
    { "en": "…", "de": "…" }
  ]
}
```

- The app fetches exactly that commit into `~/.avpplay/builders/<id>-<version>-<commit>` and checks that it got it.
  A folder on this Mac can stand in for it while a builder is being worked on:
  `avpplay builder use <id> --builder <folder>` (back with `--recipe`); `avpplay builder <id>` shows what applies.
- The builder is entered through `tools/avpplay/build_parts.sh`, as the leader of a process group of its own, with
  `AVPPLAY_WORK` (an absolute folder without blanks for everything it downloads and builds, kept between runs:
  `~/.avpplay/builders/work/<id>`) and `AVPPLAY_OUT` (the zip to write). It prints `STAGE <i>/<n> <short name>` when
  a step begins (`… (already done)` for one it skips) and anything else as plain lines; success is exit status 0
  with a last line `PARTS <path> <sha256>`, a failure ends with `FAILED <i>/<n> <short name>: <sentence>` and
  `LOG <path>`. Steps that are finished are skipped on the next run. `build_parts.sh --check` only tests what the
  Mac needs and prints one line per problem (status 1 if any); the app runs it first and shows the lines.
- Two optional lines feed the progress display (a builder may print neither; then the job shows “Step i of n” and
  the time in it):
  - `PLAN <name>:<seconds>[:<flags>] …` once, before the first `STAGE` line: every step in order with how many seconds
    it took on the builder's reference Mac in the state its work folder is in; flag `d` = its result is there (it
    will be skipped), `n` = its time is mostly a download.
  - `PROGRESS <done> <total> <unit>[ <w1>,<w2>,…]` within the running step, at most about once a second. Units:
    `files`, `bytes`, `entries`, `libraries` (counted work), `parts` (done = parts finished; the list gives each
    part's reference seconds), `seconds` (a timed wait: done = seconds behind it when the line was written, total =
    its expected length). An unknown unit is shown as plain numbers.
  - `WAIT <reason>` / `WAIT end` while the build waits for the user. Known reason: `screen-locked` – the game runs on
    the Mac for a moment and cannot while the screen is locked. The job then asks the user to unlock the Mac and holds
    the estimate still; the app keeps the display awake while a game's parts are built, against the idle lock.

  A line with a leading blank is the builder quoting a tool's output and never one of these; a line that does not
  parse is plain text. The reference times are the builder's; the app scales them by how fast this Mac turns out to
  be (`BuildProgress` in `AVPPlayCore`).
- The build is part of the job's step “Download files”, so “Build Parts Only” works without Xcode, a team or the
  headset. The job shows the step that runs in plain words (“Step 6 of 20: Downloading Minecraft from Mojang”, the
  builder's short name small beside it), a bar for the whole build with the time left, a bar for the step – a real
  one where the builder counts, an indeterminate one with the time against the usual time where it does not – and
  the list of all steps. The Remote shows the same for a job on the Mac. Everything the builder says is kept in
  `.last-parts.log` in the game's folder; a failure names the step in plain words, the builder's reason and that
  log. Cancelling the job sends SIGTERM to the whole group and SIGKILL to what is left after five seconds.
- The result is checked against the checksum the builder named and kept in the game's folder in the library as
  `<id>-parts-<version>-<commit>.zip` (`<id>-parts-local.zip` from a folder chosen by hand, which is built anew for
  every job). A new builder state makes a new file and removes the old one; a new game version is a new folder.
  The toolchain is told where it lies: `KLEPTON_MACHO_IPA=<absolute path>`.
- Nothing is copied to the device afterwards when the recipe has nothing that belongs into the app's data folder:
  the game's files travel inside its app.

Two more fields belong to such a game:

```jsonc
"gameAccount": {                // the game asks for its owner itself; no store confirms ownership to AVP Play
  "title": { "en": "You need …", "de": "Du brauchst …" },
  "notes": [ { "en": "…", "de": "…" } ]     // what counts, where the sign-in happens, where it is kept (1–6)
},
"icon": {
  "archive": {                  // pictures inside the parts archive; each the path of an entry, or the end of one after a “/”
    "icon": "assets/objects/f0/f006…",       // the game's own icon (any format the system reads, .icns too)
    "background": "assets/objects/6a/6a84…"  // optional: a picture of the game that goes behind it
  }
}
```

`gameAccount` is shown at the top of the game's page, on the Mac and on the Remote, and the overview says “Sign-in
in the game” where other games name their store. From `icon.archive` the app makes the picture of the tile and the
page on this Mac, once the parts are built; before that the tile shows the game's name on a plain ground. The
project ships no picture of such a game.

## Files

```jsonc
{
  "name": "main.151047.com.polyarc.MossGame.obb",
  "role": "main-obb",        // apk, main-obb, patch-obb, content-bundle, audio, audio-locale,
                             // language-pack, video, manifest, game-data
  "id": "8254815691289807",  // Meta's ID of the file; "" for files that do not come from Meta
  "size": 2671234567,
  "sha256": "…",
  "required": true,          // false: optional, e.g. one language
  "dest": "android-files/Android/obb/com.polyarc.MossGame",   // where it goes in the app's data on the headset
  "localName": "moss.apk",   // optional: the file's name at its destination, where that differs
  "locale": "de-DE",         // optional: the language an optional file belongs to
  "title": { "en": "…", "de": "…" },   // optional: offer an optional file as a tick of its own
  "clearable": true,         // optional: take the file off the headset again when it is unticked
  "source": { … }            // optional, see below
}
```

Without `source`, a file comes from the Meta Store: it is downloaded by its `id` with the user's own account,
after Meta has confirmed that the account owns the game. A file is never requested "to see whether it works".

`source` is for everything else:

| `kind` | Meaning |
|---|---|
| `url` | Public and free to download, such as an open-source port. `url` is required, and so is `sha256`. |
| `user` | The user provides the file from their own copy of the game. It is never downloaded. |

`hint` tells the user where the file comes from. It can be a single string or one per language:
`{ "en": "…", "de": "…" }`. The same holds for the entries of `status.notes`.

Optional files with a `locale` appear in the app as languages the user can tick. A known `size` lets the app
say how large each one is.

An optional file without a `locale` appears as a tick of its own when it has a `title`; its `hint` is the
explanation shown under it. Half-Life: Alyx offers a fan-made German voice-over this way. Such a file is only
fetched when it is ticked.

`clearable` is for an optional file the game can do without at any time. Nothing in an app's data on the headset
can be deleted from the Mac, only overwritten: when the file is no longer ticked, the app replaces it there
with an empty one, which frees its space. Use it only where the game's own app treats an empty file as a
missing one and removes it – that is code in the toolchain, not something a recipe can ask for by itself.

## Add-on content

Two patterns exist, because games handle purchases inside the game differently:

| `kind` | How it works | Example |
|---|---|---|
| `purchase-list` | The content is already in the game's files; the game asks which parts were bought. The app asks Meta for the account's purchases and puts only that list on the headset. | Walkabout Mini Golf |
| `delivered-assets` | Each purchase is a separate file that Meta only delivers to buyers. `items` maps each store SKU to its file (`sku`, `name`, `id`, optional `size`, `sha256`, `group`); the app downloads the files of confirmed purchases only. | Beat Saber |

`dest` is where the list or the files go on the headset.

## Asset-file list

Some games ask the platform which of their asset packs are installed, and only use a pack it reports. Marvel's
Deadpool VR does this for its `.lang` voice packs: they can be on disk, but unless they are reported, every
language except the default stays greyed out. `assetFiles` names those packs:

```jsonc
"assetFiles": [
  { "id": "26412782438311256", "file": "de.lang", "size": 3256791074, "tag": "de" },
  { "id": "26412784368311063", "file": "es-mx.lang", "size": 3247674165, "tag": "es-MX", "meta": "1.0.40.356975.Quest" }
]
```

| Field | Meaning |
|---|---|
| `id` | The store's asset ID of the pack. Digits only, above 0, at most 64 bits. |
| `file` | The pack's file, relative to the game's OBB folder on the device (`android-files/Android/obb/<package>`). |
| `size` | Its exact size in bytes. The runtime reports the pack as installed only when the file has exactly this size. |
| `tag` | Optional: the language tag (`[A-Za-z0-9_-]`, up to 31 characters). Without it, the file name up to its first dot. |
| `meta` | Optional: the store's metadata of the pack (`[A-Za-z0-9._+-]`, up to 63 characters). Without it, the recipe's `versionName`. |

On every install and update (the step that copies the data to the device, which also runs when add-ons or
optional content are synced), AVP Play writes `Documents/android-files/klepton-asset-files.txt` into the game's
data container. The file has one line per entry, after a comment line naming AVP Play as its writer:

```
# Written by AVP Play from the game's recipe on every install and update. Do not edit.
# store-3240283705987790 versionCode 8742
asset 26412782438311256 de.lang 3256791074 de meta=1.0.40.356975.Quest
```

The toolchain's runtime reads it (myMartek/Klepton #25). The list is written to a temporary file and renamed
before it is copied, so a half-written list never goes to the device.

A recipe is rejected when it is loaded if the list breaks the rules the runtime applies: more than 32 entries,
an empty list, a duplicate `id` or `file`, a `file` that is absolute or has empty, `.` or `..` components,
blanks or backslashes, a `size` of 0 or less, a non-numeric `id`, or a `tag` or `meta` outside the characters
above. If the recipe lists the same ID as one of its `files`, both sizes must agree.

**A game without `assetFiles` gets no list.** That includes a newer store build the project has not tested: its
recipe is derived from the tested one, but its asset IDs and exact sizes are not known, so it has no `assetFiles`.
A list already on the device from an earlier install is handled by who wrote it:

- **Written by AVP Play** (its first line begins with `# Written by AVP Play`): emptied, so the runtime no longer
  reports packs whose IDs and sizes belong to another build. devicectl can copy into the game's container but not
  delete there, so the list is replaced by an empty file, the same way withdrawn content is taken off the device.
  The runtime then still finds a list, with no entries, and reports no asset file as installed. Once empty, the
  file is left alone on later installs.
- **Anything else** (no such header, or the first line is something else): left as it is. Someone put it there on
  purpose, and it is not AVP Play's to change.
- **Cannot be read** (the folder cannot be listed, or copying the file to the Mac fails): left as it is, since
  nothing shows it is ours.

Only the header line is checked; AVP Play copies the file to the Mac to read it, which changes nothing on the
device. The install log says when a list was emptied, left alone as foreign, or could not be read. Failing to
empty a list is reported too, but does not stop the install. A recipe with `assetFiles` always writes its list,
whatever was there before.

## Folder trees

Some games are not an APK but a folder of files from the user's own purchase, sometimes with a runtime next to
it. A tree names such a folder; the user points the app at it and the app keeps a copy:

```jsonc
{
  "name": "game",
  "role": "game",            // game, sysroot or xrizer – each role once
  "source": { "kind": "user", "hint": { "en": "…", "de": "…" } },
  "markers": [ { "path": "bin/linuxarm64/hlvr", "size": 16073672, "sha256": "…" } ]
}
```

`markers` are a few files that identify the right version of the folder. A folder is accepted when all markers
are present with the stated size and checksum.

## Status

`playability` is `untested`, `reported` (a user says it runs) or `verified`. `download` says how well the file
list has been confirmed: `proven` (every file checked by checksum from a clean download), `partial`, `listed`,
or `special` for games that are not downloaded from Meta. Be honest here – the app shows these to users.

## Rules for names

`id`, file names, `localName` and tree names must be plain names: no `/`, no `\`, not starting with a dot. A
recipe that breaks this is rejected when it is loaded. Meta file IDs are digits only.

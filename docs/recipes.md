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

**A game without `assetFiles` gets no list, and an existing one on the device is left alone.** AVP Play cannot
tell whether it wrote such a file itself, so it neither replaces nor empties it. The same holds for a newer store
build the project has not tested: its recipe is derived from the tested one, but its asset IDs and exact sizes
are not known, so it has no `assetFiles`.

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

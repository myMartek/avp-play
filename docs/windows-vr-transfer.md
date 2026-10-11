# Windows game transfer from the Mac companion

`avpplay windows stage` copies a game folder that you already have locally to the installed AVP Play app on a paired Vision Pro. It is a file-transfer command only: it does not acquire games, query a store, authenticate to a store, unlock content, or bypass DRM. You must explicitly attest that you own the files with `--owned`.

The transfer contract accepts a schema-version-1 Windows game manifest using `backend: "windowsWineFEX"` and `graphics: "direct3D11"` or `"direct3D12"`, and an x64 PE executable. D3D12 files can be transferred without asserting that the destination app contains the matching experimental DXMT runtime; the headset checks that package before launch. Other backends/graphics and non-AMD64 executables are rejected; there is no fallback. The manifest format has no architecture field, so x64 is checked from the executable's PE header.

## Command

Run from the `core` Swift package directory (or use the equivalent package invocation for your checkout):

```text
swift run avpplay windows stage --from "/path/to/Game" --manifest "/path/to/game-manifest.json" --bundle-id com.example.AVPPlay --owned [--device DEVICE-UDID]
```

`--device` is optional only when there is one reachable paired Vision Pro. `--bundle-id` identifies the already installed AVP Play app whose app-data container receives the files. The target app must not be running. The command fails closed if it is not installed, the app's container URL is unknown, or its process is running.

A schema-1 manifest uses the same fields as the headset sample, for example:

```json
{
  "id": "example.game-id",
  "title": "Example game",
  "executableRelativePath": "Game.exe",
  "backend": "windowsWineFEX",
  "graphics": "direct3D11",
  "launchArguments": [],
  "schemaVersion": 1
}
```

`environment` is accepted as an optional string-to-string object. The executable path must name a regular file in the selected source folder. The manifest's `id` is a restricted single path component and becomes the game-folder name.

## Transfer behavior and safety

- The destination is `Documents/WindowsVR/Games/<manifest-id>/<content-generation>/` inside the selected app-data container. Each regular source file is copied sequentially, at its own source path, through the existing `DeviceControl.copy` / `xcrun devicectl device copy to` API. The game tree is not staged as a second local copy on the Mac.
- Each immutable content generation is derived from the manifest and all source-file sizes/digests. Changed content goes into a new folder instead of replacing files beside an old completion marker. The validated input manifest is copied as `manifest.json` only after all game files, making it the completion marker. If the input manifest lives inside the game folder, it is excluded from the ordinary file list and still sent last. A different source-root `manifest.json` is rejected rather than overwritten.
- Schema, backend, graphics, executable, path components, and Windows case-insensitive path collisions are checked locally. Absolute/traversal/drive/ADS/control-character paths, special files, symbolic links, and paths resolving outside the selected folder are refused. Hidden regular files are included. The scan is capped at 100,000 files; the manifest is capped at 1 MiB.
- File SHA-256 is read from the local source in 1 MiB chunks. Progress reports source hashing and file-by-file transfer completion; `devicectl`'s existing synchronous copy call does not provide byte-level live progress. Ctrl-C can interrupt the process; only a successful copy with a stable source digest is recorded, so interrupted/unrecorded files are recopied on resume.
- The local resume journal is stored under `~/Library/Application Support/AVPPlay/WindowsGameTransfers/`. Its key scopes it to the selected device, target bundle ID, and canonical source-folder path. Per-file journal entries include size and SHA-256 and are saved only after the copy command succeeds and the source still hashes identically. Both a matching local journal digest and remote file presence/size are required before a prior file is counted as resumed. A missing or truncated remote listing causes conservative recopying, not a false completion.

The journal records successful `devicectl` copy operations and local source digests. `DeviceControl` exposes no remote file hashing/readback API, so this command cannot prove that bytes still present on the headset match the journal if someone later modifies or removes them there. Resume is therefore not a remote integrity audit. Open the research headset app and use **Mac transfers → Refresh transferred games**, then select the completed generation and optionally save it to the library. Old generations consume headset storage until removed through Files; there is no automatic deletion. Keep the target app closed for the whole transfer; the app is checked before copying, but the current copy API cannot lock out a concurrent launch. The manifest marker means the copy sequence completed, not that the Windows runtime or game has been validated.

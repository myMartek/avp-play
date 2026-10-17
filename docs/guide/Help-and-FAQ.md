🏠 [Übersicht / Overview](README.md) · 🇩🇪 [Deutsche Fassung](Hilfe-und-FAQ.md)

# Help and FAQ

Problems that have come up more than once – with fixes you can do yourself. When a job stops, first look at the **What Went Wrong** box under **Jobs**: it usually already says what to do.

**Contents:** [Setup and Apple account](#setup-and-apple-account) · [Connecting the Vision Pro](#connecting-the-vision-pro) · [Downloads, Meta and Steam](#downloads-meta-and-steam) · [A game won't start or runs badly](#a-game-wont-start-or-runs-badly) · [In the game](#in-the-game) · [What doesn't work](#what-doesnt-work) · [Reporting a problem](#reporting-a-problem)

---

## Setup and Apple account

### "Xcode's build tool finds no Apple account" (No Accounts) – but I am signed in
Xcode sometimes lists the account as signed in but cannot use it.
1. Open Xcode › **Settings › Accounts**.
2. **Sign the account out and back in** (just checking it is listed is not enough).
3. In AVP Play, click **Resume** on the job.

### "Xcode is no longer signed in"
As above: sign in again in Xcode under **Settings › Accounts**, then **Resume**.

### Does it work with a free Apple account?
Yes. Limits: a game opens for **7 days**, then it has to be signed again. At most **3 apps** from your account on the Vision Pro at once (apps you installed yourself with Xcode count too). At most **10 new games per week**. A very large game may fail on memory with a free account. More under [Setup](Setup.md#apple-account-free-or-paid).

### My game won't open any more after 7 days
That is the free Apple account's limit. Fix: install the game again in AVP Play (saved games stay). Easier: turn on **Settings › Renew signatures** – the app then does it by itself while the Vision Pro is on and on the same Wi-Fi.

### "Apple refused the installation: … only 3 apps at a time"
Remove an app from the Vision Pro (press and hold its icon › **Remove App**), then **Resume**. Let the app back up its saved games first (game page › **Fetch Now**) – removing deletes them on the Vision Pro.

### "… only 10 new apps within 7 days"
Apple sets this limit for free accounts. Wait until the oldest registration is 7 days old.

### The game is installed but won't open: "untrusted developer"
On the Vision Pro: **Settings › General › VPN & Device Management**, choose your Apple account, tap **Trust**. Needed once per account.

### "Apple is waiting for you to accept updated terms"
Sign in at [developer.apple.com/account](https://developer.apple.com/account), accept the agreement, then **Resume**.

### "The identifier already belongs to another developer team"
The game was installed before with a different Apple account. In AVP Play, enter another prefix under **Settings › Advanced** and install again. The Vision Pro then treats the game as a new app.

### macOS asks for the keychain password while building
Type your Mac password and click **Always Allow** with the mouse.

---

## Connecting the Vision Pro

### "The Vision Pro is not reachable"
Turn on the Vision Pro, put it on or unlock it, on the **same Wi-Fi** as the Mac. The very first time it has to be paired with Xcode – see [Setup](Setup.md#3-connect-the-vision-pro-once).

### "The Vision Pro is locked"
Put it on, unlock it, **Resume**.

### Copying to the Vision Pro is slow or breaks off
- With a **USB cable on the Developer Strap** it is much faster; the app uses the cable by itself.
- Break-offs usually happen because the Vision Pro went to sleep. Keep it awake, **Resume** – whatever was copied is skipped.

### "… is currently running on the Vision Pro. Installing would quit the game."
Quit the game on the Vision Pro (Digital Crown), then **Resume**. The app waits on purpose so your saved game isn't lost.

### "The game could not be started" or "not enough free space on the Vision Pro"
Usually the Vision Pro's storage is full. On the Vision Pro, check **Settings › General › Storage** and remove apps you don't need. Big games need their full size again on the Vision Pro (Asgard's Wrath 2 about 34 GB).

### Steam Link connects, but the picture never arrives
Steam Link needs the **Local Network** permission. The Vision Pro asks the first time you open it – tap **Allow**. If you declined: **Settings › Privacy & Security › Local Network** and turn on Steam Link.

---

## Downloads, Meta and Steam

### "Meta won't deliver this file (HTTP 404)"
For add-on content you haven't bought, the app skips the file and carries on. For main files it tries once more through Meta's own tool by itself. If both fail, the job says why.

### "Not owned", although I bought the game
- Click **Check Purchase** on the game's page – a new purchase sometimes takes a few minutes.
- Bought with another Meta account? Sign in with that account under **Setup**.
- Bought on Steam? Sign in to Steam and **Check Purchase** again.

### Meta rejects the sign-in / "Please sign in again"
Sign in again under **Setup › Meta Account**, then **Resume**.

### macOS blocks Meta's tool "ovr-platform-util"
**System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to *ovr-platform-util*. In the app, **Try Again**.

### Steam sign-in: "Bad CPU type" or a note about Rosetta
Valve only makes SteamCMD for Intel Macs. Under **Setup › Steam Account** click **Install Rosetta** (or run `softwareupdate --install-rosetta --agree-to-license` in Terminal), then reopen AVP Play.

### "That does not look like a Steam account name"
It means the name you **sign in** to Steam with – not your profile name.

### I bought new song packs / DLCs
Game page › **Sync DLCs**. Restart the game afterwards.

### My Mac is out of space
- **Data**: remove old or unneeded downloads.
- **Data › Downloads Folder › Change …**: move to an external drive.
- **Settings › Toolchains**: keep automatic tidying on.

### Can I download before everything is set up?
Yes: **Download Only** on the game's page only needs the account the game was bought with.

### My own fixed version is gone after an update
On the game's page, under **Toolchain**, keep the game on your toolchain.

---

## A game won't start or runs badly

### An untested game stays black, closes, or shows no text
Every verified game needed its own adjustments – so untested games often don't work. Since 1.3.0, untested games get somewhat safer default settings; still, trying is an experiment. What you can do:
- Report what happens under **How does it run?** – it helps everyone.
- Try **Fix with AI …** (see [A game's page](Game-Page.md#fix-with-ai)).
- Report a problem on GitHub (see below).

### The first start takes very long ("Preparing graphics")
Normal. On the first start the game translates its graphics – that can take a few minutes. After that it is quick.

### The game stutters the first time I visit a level
The first time, each new graphic is translated. On the next visit it is smooth. In Batman: Arkham Shadow and Moss this now happens in the background (switchable under **Advanced › Test** in the settings).

### The frame rate drops to 50 (or 60)
The Vision Pro halves the frame rate when a game can't keep up. Try:
- Keep **Frame rate: Up to 100** (default).
- Lower the **Resolution** and turn on **MetalFX** (right below Resolution).
- Under **Advanced**, set **Display output** to *Light*.
- **Foveated rendering** at *Strong* or *Very strong*.
- In Half-Life: Alyx, the graphics preset *Smooth* or *Balanced*.

The [performance panel](Controls.md#performance-panel) shows what's behind it.

### After an update a game closes right at the start
That was a bug in an older version. Update AVP Play and rebuild the game with **Update**. The first start afterwards takes a bit longer.

### Marvel's Deadpool VR hangs on the loading screen
Rare. Quit the game and start it again – it usually goes through. If it happens often: in the game's settings turn on **Advanced › Diagnostics › Record what the game waits for** and send the log with a report.

### Asgard's Wrath 2 goes black after the shader screen
With a current toolchain, the "compiling shaders" screen stays until everything is done – several minutes on the first start. Just let it run.

---

## In the game

### How do I quit a game? There is no Home button
Press the **Digital Crown**. The game ends shortly after. There is no pausing in the background – every start is a fresh start.

### The room isn't recognised at start
Look around briefly so the game sees enough of the room. After 8 seconds a card asks: **Measure room** or **Stationary / seated**. In a new room, simply measure again. More under [Play area](Play-Area.md).

### I want to play without a play area
In the start window turn off **Settings › Play area** – or in AVP Play under **Settings › Play area** for all new games. See [Play area](Play-Area.md#turning-it-off).

### "Measuring the room needs the permission to sense your surroundings"
On the Vision Pro: **Settings › Privacy & Security › Surroundings** and allow the game.

### Walkabout: others can't hear me
Turn on **Microphone** in the game's settings and allow the Vision Pro's prompt.

### Demeo shows a generic player name
Demeo can't sign in to its maker's account service and plays with a local player. Set the name in the settings under **Player name**.

### Half-Life: Alyx – where do I sign in for Steam Cloud?
In the game on the Vision Pro: **Settings › Steam Cloud**. Enter your Steam account name and password and confirm in the Steam app on your phone.

### Are my saved games safe?
AVP Play fetches saved games to the Mac by itself (after every game and every few hours). When you reinstall, they come back automatically if the Vision Pro has none. Careful: removing an app on the Vision Pro deletes its saved games there – the copies on the Mac stay. Half-Life: Alyx uses Steam Cloud.

---

## What doesn't work

- **32-bit games** (e.g. République VR): the Vision Pro's chip cannot run 32-bit code. Can't be fixed.
- **2D apps** such as Spotify, WhatsApp or YouTube: AVP Play is for VR games only.
- **Pausing in the background**: every start is a fresh start.
- **Mixed reality** only in the games set up for it (filter *Mixed Reality*).
- Games labelled **Incompatible**: the game's page says why.

---

## Reporting a problem

1. In AVP Play: **Help › Report a Problem …** – or **Report This Problem …** in a stopped job.
2. Click **Copy and Open GitHub** and paste the report into a new issue.

The report contains no names, accounts, device identifiers or folder paths. The app itself sends nothing.

For problems in a game, the log from the Vision Pro helps: start window › **Settings › Advanced › Diagnostics › Export log**.

👉 [Issues on GitHub](https://github.com/myMartek/avp-play/issues)

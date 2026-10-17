🏠 [Übersicht / Overview](README.md) · 🇩🇪 [Deutsche Fassung](Erste-Schritte.md)

# Getting started

## What is AVP Play?

AVP Play is an app for the Mac. It takes VR games you bought for the Meta Quest and turns them into apps for your Apple Vision Pro.

That happens in four steps – the app does all of them for you:

1. **Check:** The app asks Meta (or Steam) whether you own the game. Only then does it continue.
2. **Download:** The game files are downloaded to your Mac with your own account.
3. **Build:** Your Mac translates the game for the Vision Pro and signs the app with your Apple account ("signing" is Apple's way of saying who made an app).
4. **Copy:** The finished app is copied to your Vision Pro. You find it there like any other app.

AVP Play does not hand out any games itself. You only get what you bought.

![The game list in AVP Play](images/en/games-overview.jpg)

## What you need

| | |
|---|---|
| **Mac** | A Mac with an Apple chip (M1 or newer), macOS 14 or later |
| **Xcode** | Apple's free developer app from the App Store, with its visionOS add-on |
| **Apple Vision Pro** | On the same Wi-Fi as the Mac, with Developer Mode on |
| **Apple account** | Your normal Apple ID is enough (free). The paid developer membership removes a few limits – see [Setup](Setup.md#apple-account-free-or-paid). |
| **Meta account** | The account you bought the Quest games with |
| **Steam account** *(optional)* | Only for games you bought on Steam (e.g. Half-Life: Alyx, Doom 3) |
| **Disk space** | A lot. A big game needs 10 to 75 GB on the Mac and the same again on the Vision Pro. An external drive for the Mac works too. |
| **Controllers** | Most games need the PlayStation VR2 Sense controllers. An ordinary game controller (DualSense, Xbox) works together with your hands. |

## How to begin

1. **Get the app:** Download `AVP-Play-1.3.0.dmg` from the [download page](https://github.com/myMartek/avp-play/releases/latest). Open it and drag **AVP Play** into **Applications**.
2. **Open the app:** On first launch the app shows the **Setup** page. It shows for every item whether it is fine (green tick) or what is missing. How to do each item is on the [Setup](Setup.md) page.
3. **Pick a game:** Under **Games**, pick a game and click **Install**. More under [Finding and filtering games](Games-and-Filters.md).
4. **Wait:** Under **Jobs** you see how far the installation is. Big games take a while the first time.
5. **Play:** Put on the Vision Pro and open the game. A start window appears with **Start** and **Settings**. More under [On the Vision Pro](On-the-Vision-Pro.md).

![A game's start window on the Vision Pro](images/en/vp-start-window-room.jpg)

## Which games work?

Not every Quest game works. Each game needs small adjustments before it runs on the Vision Pro. The labels in the app tell you how well a game runs:

- **Verified** (blue): The project tested the game on a Vision Pro.
- **Community Verified** (green): More people report "works" than "doesn't work".
- **Untested** (gray): No reports yet. You may try it – but it may well not start.
- **Incompatible** (red): Reported not to work.

If a game doesn't work, see [Help and FAQ](Help-and-FAQ.md).

## Next

➡️ [Setup](Setup.md)

# Übergabe: Moonshot „Tag Eins“, Stand 27. Oktober 2026

Diese Datei hält fest, was in der Cloud-Session gemacht wurde, was halb fertig ist und wie es auf dem Mac
weitergeht. Der Plan selbst steht in [`moonshot.md`](moonshot.md).

## Warum die Arbeit hier endet

Die Cloud-Session lief in einem Linux-Container ohne Swift, Xcode, Signierzertifikat und Vision Pro. Dort lässt
sich die App weder bauen noch testen, und ein Release (Developer-ID-Signatur, Beglaubigung, DMG) geht nur auf dem
Mac. Deshalb wird ab hier auf dem Mac weitergearbeitet.

## Branches

| Branch | Basis | Inhalt | Stand |
|---|---|---|---|
| `claude/charming-hypatia-bk0hrt` | `main` | `moonshot.md` (der Plan) und diese Datei | gepusht |
| `ci/macos-build` | `main` | `.github/workflows/build.yml`: `swift build` und `swift test` auf `macos-26` bei jedem Push und Pull Request | gepusht, erster Lauf lief beim Ende der Session noch (Run 40421259702) |
| `feat/menubar` | `ci/macos-build` | Schritt 0: Logik und Tests der Menüleiste, **ohne Oberfläche**, plus diese Datei | gepusht, **nicht kompiliert** |

Auf dem Mac:

```bash
git fetch origin
git checkout feat/menubar
cd core && swift build && swift test
```

Noch nicht angelegt: der Integrationsbranch `moonshot` und die Branches `moonshot/<kennung>` aus dem Plan.

## Zu prüfen: der CI-Lauf

- Ergebnis von [Run 40421259702](https://github.com/myMartek/avp-play/actions/runs/40421259702) ansehen.
- Ist er rot, liegt es wahrscheinlich am Runner und nicht am Code: Gibt es `macos-26` nicht oder ist das Xcode dort zu
  alt, `runs-on` auf das neueste verfügbare Image setzen. Die Zeile „Using …“ im Schritt *Newest Xcode* zeigt, welches
  Xcode genommen wurde.
- Hat er zu lange gebraucht oder taugt er nicht, den Branch einfach löschen. Er ist von nichts abhängig, außer dass
  `feat/menubar` auf ihm aufbaut (dann `feat/menubar` auf `main` rebasen und den CI-Commit weglassen).
- Taugt er, als eigenen Pull Request nach `main` bringen, vor `feat/menubar`.

## Schritt 0: Menüleiste, Stand im Einzelnen

### Fertig (auf `feat/menubar`, nicht kompiliert)

**`core/Sources/AVPPlayCore/MenuBar.swift`**

- `MenuBarPreferences`
  - Schlüssel `menuBarShow` (Standard `true`) und `menuBarKeepRunning` (Standard `false`)
  - `load(defaults:)` und `save(defaults:)`
  - `staysInMenuBar`: nur wenn beides an ist; ohne Symbol läuft nie etwas unsichtbar weiter
  - `terminatesWithLastWindow` ist die Antwort für `applicationShouldTerminateAfterLastWindowClosed`
- `MenuBarStatus`: leitet die Zeilen des Menüleisten-Fensters aus dem Zustand ab
  - Zustand: laufender Auftrag mit Schritt und Bytes, wartende und angehaltene Aufträge, Gerät, Fernsteuerung,
    Erneuerung
  - Ausgaben: `percent` (Zahl neben dem Symbol), `needsAttention`, `jobLine`, `jobDetail`, `deviceLine`,
    `remoteLine`, `renewalLine(now:)`
  - `nextExpiry(in: RenewalReport?)`: die früheste Frist aus dem letzten Erneuerungslauf
- Alle Texte auf Englisch und Deutsch.

**`core/Tests/AVPPlayCoreTests/MenuBarTests.swift`** prüft:
- Standardwerte und Speichern,
- „Weiterlaufen braucht Symbol“,
- Fortschritt mit und ohne Größe, Begrenzung auf 0 bis 100 %,
- Leerlauf, angehaltene Aufträge und Erneuerungszeilen,
- deutsche Texte und die früheste Frist.

Mögliche Stolperstellen beim ersten `swift test`:
- `RenewalReport` und `RenewalOutcome` werden in den Tests mit ihren memberwise-Initialisierern gebaut. Die sind
  `internal`, was mit `@testable import` reicht.
- Liefert `InstallStep.stage.title` einen anderen Text als „Copy data to the device“, den erwarteten Text im Test
  anpassen.

### Offen: die Oberfläche in der App

Alles hier ist entworfen, aber noch nicht geschrieben.

**1. Neue Datei `core/Sources/AVPPlayApp/MenuBar.swift`**

```swift
import AppKit
import AVPPlayCore
import ServiceManagement
import SwiftUI

extension AppModel {
    /// Der Zustand für das Fenster der Menüleiste.
    func menuBarStatus(remote: RemoteServer) -> MenuBarStatus {
        let running = runningJob.flatMap { id in jobs.first { $0.id == id } }
        let progress = runningJob.flatMap { copyProgress[$0] }
        let job = running.map { MenuBarStatus.RunningJob(title: $0.recipe.title, step: progress?.step ?? $0.current,
                                                           done: progress?.done, total: progress?.total) }
        let remoteState: MenuBarStatus.Remote =
            !remote.enabled ? .off
            : remote.problem.map { .problem($0) }
            ?? (remote.connected.isEmpty ? .waiting : .connected(remote.connected.count))
        let renewal = (usesFreeTeam || renewInBackground)
            ? MenuBarStatus.Renewal(inBackground: renewInBackground, intervalHours: renewIntervalHours,
                                    lastRun: renewalReport?.ran, nextExpiry: MenuBarStatus.nextExpiry(in: renewalReport))
            : nil
        return MenuBarStatus(job: job, waiting: queued.count,
                             failed: jobs.filter { phase(of: $0) == .stopped }.count,
                             deviceName: device?.name, remote: remoteState, renewal: renewal)
    }
}

/// Das Symbol in der Menüleiste: die Brille, beim Arbeiten mit dem Fortschritt daneben.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteServer
    var body: some View {
        let status = model.menuBarStatus(remote: remote)
        HStack(spacing: 4) {
            Image(systemName: status.needsAttention ? "exclamationmark.triangle" : "visionpro")
            if let percent = status.percent { Text("\(percent) %") }
        }
    }
}

/// Das Fenster unter dem Symbol: Auftrag, Gerät, Fernsteuerung, Erneuerung und die wichtigsten Knöpfe.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteServer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.menuBarStatus(remote: remote)
        VStack(alignment: .leading, spacing: 10) {
            Text("AVP Play").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.jobLine).font(.callout.weight(.medium)).lineLimit(2)
                if let detail = status.jobDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if status.job != nil {
                    if let f = status.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Divider()
            Label(status.deviceLine, systemImage: "visionpro").font(.callout)
            Label(status.remoteLine, systemImage: "dot.radiowaves.left.and.right").font(.callout)
            if let line = status.renewalLine() { Label(line, systemImage: "signature").font(.callout) }
            Divider()
            HStack {
                Button(L("Open AVP Play", "AVP Play öffnen")) { showMain() }.keyboardShortcut(.defaultAction)
                Button(L("Check Again", "Neu prüfen")) { model.refresh() }.disabled(model.refreshing)
                Spacer()
                Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func showMain(section: AppSection? = nil) {
        if let section { model.section = section }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// „Bei der Anmeldung öffnen“ über `SMAppService`.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on: Bool) throws { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
}
```

**2. `core/Sources/AVPPlayApp/App.swift`**

Im Struct `AVPPlayApp`:

```swift
@AppStorage(MenuBarPreferences.showKey) private var menuBarShow = true

// in body, nach der Window-Szene:
MenuBarExtra(isInserted: $menuBarShow) {
    MenuBarPanel().environmentObject(model).environmentObject(remote).environment(\.locale, L10n.locale)
} label: {
    MenuBarLabel().environmentObject(model).environmentObject(remote)
}
.menuBarExtraStyle(.window)
```

Im `AppDelegate`:

- `applicationShouldTerminateAfterLastWindowClosed` gibt `MenuBarPreferences.load().terminatesWithLastWindow`
  zurück statt `true`.
- In `applicationDidFinishLaunching` auf Fensterereignisse hören:
  - Bei `NSWindow.willCloseNotification` des Hauptfensters (Kennung enthält `"main"`, wie in `Snapshot.capture`) und
    `MenuBarPreferences.load().staysInMenuBar`: `NSApp.setActivationPolicy(.accessory)`, damit das Dock-Symbol
    verschwindet.
  - Bei `NSWindow.didBecomeKeyNotification` des Hauptfensters: `NSApp.setActivationPolicy(.regular)`.
- In `applicationShouldTerminate` vor `alert.runModal()` `NSApp.activate(ignoringOtherApps: true)` aufrufen. Sonst
  liegt die Rückfrage „Es läuft noch ein Auftrag“ beim Beenden aus der Menüleiste hinter anderen Fenstern.

In `RootView`, im `.task`: Wird das Fenster aus der Menüleiste neu geöffnet, entsteht `RootView` neu, und der
Startblock liefe noch einmal (Katalog neu laden, Update-Check, …). Abhilfe:

- In `AppModel` ein `var launched = false` anlegen.
- Im `.task`: `guard !model.launched else { model.refresh(); return }`, dann `model.launched = true`, dann der
  bisherige Block.

Die Watcher (`startDeviceWatch`, `startSaveWatch`) schützen sich schon selbst.

**3. `core/Sources/AVPPlayApp/SettingsView.swift`**: neuer Abschnitt `Section(L("Menu Bar", "Menüleiste"))`

- `Toggle(L("Show AVP Play in the menu bar", "AVP Play in der Menüleiste zeigen"))`, über
  `@AppStorage(MenuBarPreferences.showKey) var menuBarShow = true`.
- `Toggle(L("Keep running in the menu bar when the window is closed", "In der Menüleiste weiterlaufen, wenn das Fenster geschlossen ist"))`,
  über `@AppStorage(MenuBarPreferences.keepRunningKey) var menuBarKeepRunning = false`, `.disabled(!menuBarShow)`.
- `Toggle(L("Open at login", "Bei der Anmeldung öffnen"))` über `LoginItem`.
  - Fehler aus `register()` als Text darunter zeigen.
  - Bei `needsApproval` einen Knopf zeigen, der `SMAppService.openSystemSettingsLoginItems()` aufruft.
- Ein erklärender Satz: Mit geschlossenem Fenster laufen Aufträge weiter, die Fernsteuerung bleibt aus AVP Play
  Remote erreichbar, und die Erneuerung im Hintergrund läuft wie bisher.

**4. Snapshot-Modus** (`Snapshot.runIfRequested` in `App.swift`): nach `capture("5-einstellungen", dir)` das Panel
offscreen fotografieren.

- `NSHostingView(rootView: MenuBarPanel().environmentObject(model).environmentObject(AppDelegate.remote))` in ein
  randloses `NSWindow` setzen.
- `alphaValue = 0`, `orderFront`, kurz warten.
- `capture("5-menueleiste", dir, window: window)`, dann `orderOut`.

### Zu testen (nur auf dem Mac möglich)

- [ ] `swift build` und `swift test` grün.
- [ ] Symbol erscheint und verschwindet mit der Einstellung.
- [ ] Fenster schließen, während „Weiterlaufen“ aus ist: Das Programm endet wie bisher.
- [ ] Fenster schließen, während „Weiterlaufen“ an ist:
  - [ ] Das Dock-Symbol verschwindet.
  - [ ] Ein laufender Auftrag läuft weiter.
  - [ ] AVP Play Remote bleibt verbunden.
- [ ] Prozentzahl neben dem Symbol beim Laden und Kopieren; ohne bekannte Größe ein Balken ohne Zahl.
- [ ] „AVP Play öffnen“ aus der Menüleiste:
  - [ ] Das Fenster kommt wieder.
  - [ ] Das Dock-Symbol ist zurück.
  - [ ] Der Katalog wird nicht neu geladen; Suche und Filter bleiben.
- [ ] „Beenden“ aus der Menüleiste mit laufendem Auftrag: Die Rückfrage erscheint im Vordergrund.
- [ ] „Bei der Anmeldung öffnen“, sowohl aus `/Applications` als auch mit dem ad-hoc signierten Bau aus `make-app.sh`.
- [ ] Mit kostenlosem Apple-Konto: Die Zeile zur Erneuerung erscheint und stimmt.
- [ ] Englisch und Deutsch (Sprachwahl in den Einstellungen).
- [ ] `--snapshot` erzeugt `5-menueleiste.png`.

### Bekannte Lücke

Wird AVP Play bei der Anmeldung gestartet, öffnet sich das Fenster. Für den Betrieb als unsichtbares Gerät wäre ein
Start nur in der Menüleiste besser. `SMAppService.mainApp` übergibt keine Argumente, also braucht es dafür eine
eigene Idee, zum Beispiel einen kleinen Login-Helper. Das gehört zu `s4-appliance`, nicht in Schritt 0.

## Release 1.5.5 mit der Menüleiste

Das letzte Release ist **v1.5.4** (Toolchain 778, `ccb7287`). Wie bisher auf dem Mac:

1. `feat/menubar` (nach `ci/macos-build`) nach `main` mergen.
2. Release bauen:
   ```bash
   cd core
   AVPPLAY_APP_VERSION=1.5.5 \
   AVPPLAY_SIGN_IDENTITY="Developer ID Application: …" \
   AVPPLAY_NOTARY_PROFILE=… \
   tools/make-release.sh
   ```
   Der Standardwert in `make-release.sh` steht noch auf `1.1.16`; die Version immer über die Umgebung setzen oder den
   Standard nachziehen.
3. Tag `v1.5.5`, Release „AVP Play 1.5.5“, `AVP-Play-1.5.5.dmg` anhängen.

Vorschlag für den Text, im Stil der bisherigen Releases:

```markdown
**AVP Play in the menu bar**
- AVP Play now has an icon in the menu bar. It shows the running job with its progress, whether the Vision Pro is
  reachable, whether AVP Play Remote is connected and, with a free Apple account, when the next game runs out.
- New in **Settings › Menu Bar**: *Keep running in the menu bar when the window is closed*. Then closing the window
  no longer quits AVP Play: jobs keep going, AVP Play Remote stays connected, and the Dock icon goes away until you
  open the window again. It is off unless you switch it on.
- *Open at login* starts AVP Play when you sign in to your Mac.

**Toolchain**
- Unchanged: 778 (`ccb7287`). Installed games need no update.
```

## Stand aller Punkte aus `moonshot.md`

| Kennung | Stand | Nächster Schritt |
|---|---|---|
| Schritt 0 (Menüleiste) | Logik und Tests fertig, Oberfläche entworfen (oben) | Oberfläche schreiben, testen, Release 1.5.5 |
| `d30-host` | nicht begonnen | Spike in myMartek/Klepton: macOS-Wirt, Beat Saber headless bis ins Hauptmenü |
| `d30-fingerprint` | nicht begonnen | Extraktor in `AVPPlayCore`; geht ohne Headset und lässt sich gut zuerst angehen |
| `d30-remote` | nicht begonnen | Eigenes Mini-Projekt mit `RemoteImmersiveSpace`, braucht Mac und Vision Pro |
| `s1-mac-host`, `s1-headless`, `s1-debug`, `s1-remote` | nicht begonnen | hängen an `d30-host` bzw. `d30-remote` |
| `s2-fingerprint`, `s2-coverage`, `s2-unlock` | nicht begonnen | hängen an `d30-fingerprint`; `s2-coverage` und `s2-unlock` brauchen den Katalogdienst `avpplay.martek.de` (nicht in diesem Repository) |
| `s2-agent`, `s2-judge`, `s2-nightshift` | nicht begonnen | hängen an `s1-headless` |
| `s2-engines` | nicht begonnen | Arbeit in myMartek/Klepton (`runtime/guest/kl_il2cpp.c`, `kl_ue4.c`, `visionos/targets.py`) |
| `s2-publicmap` | nicht begonnen | hängt an `s2-coverage` und am Katalogdienst |
| `s3-framegen`, `s3-textures`, `s3-hands` | nicht begonnen | Arbeit in myMartek/Klepton; Test nur auf der Vision Pro |
| `s4-appliance` | Teil 1 ist Schritt 0 | danach Wake-on-LAN (avp-play-remote) und Start nur in der Menüleiste |
| `s4-library` | nicht begonnen | Arbeit in myMartek/avp-play-remote |
| `s4-streaming` | nicht begonnen | Arbeit in myMartek/Klepton (Dateizugriffe der Runtime) und hier (Gegenstelle auf dem Mac) |

Vorgeschlagene Reihenfolge auf dem Mac:
1. Schritt 0 fertig und ausliefern.
2. `d30-fingerprint` (geht ohne Headset).
3. `d30-host`.
4. `d30-remote`.

Die Branch-Regeln aus `moonshot.md` gelten weiter: ein Branch `moonshot/<kennung>` pro Punkt, der Branch `moonshot`
führt die fertigen zusammen.

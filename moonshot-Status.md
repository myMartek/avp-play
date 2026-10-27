# Moonshot „Tag Eins“: Umsetzungsstand

Der Plan steht in [`moonshot.md`](moonshot.md). Diese Datei sagt pro Punkt, wie weit er ist, was gemacht wurde, was
noch fehlt und **was Marcel testen oder entscheiden muss**. Sie ersetzt die `HANDOFF.md` der Cloud-Session.

Stand: 27. Oktober 2026.

## Übersicht

| Kennung | Stand | Wartet auf Marcel? |
|---|---|---|
| Schritt 0 (Menüleiste) | **veröffentlicht in AVP Play 1.5.5** | Test der offenen Punkte unten |
| CI (`ci/macos-build`) | Workflow da; erster Lauf blieb mit Xcode 26.6 im Compiler hängen, Diagnose-Lauf läuft | nein |
| `d30-fingerprint` | **Extraktor fertig, getestet, auf 59 APKs gelaufen**, erste Abdeckungskarte da | Entscheidung: als PR nach `main`? |
| `d30-host` | **erreicht**: Beat Saber 1.45 ohne Headset auf dem Mac bis ins Hauptmenü, mit Bildern, per Skript | nein |
| `d30-remote` | **Spike gebaut**, SDK-Antwort da; Test braucht Mac + Vision Pro | **ja: Test in der Brille** |
| `s2-coverage` | **Prognose fertig** (Kern, CLI, Spielseite), auf geprüften Spielen gegengeprüft | **ja: Spielseite ansehen** |
| `s4-appliance` | **Start nur in der Menüleiste** bei der Anmeldung gebaut | **ja: Test mit Ab-/Anmelden** |
| `s1-headless` | Laborlauf-Skript mit Methoden-Aufrufen, Tastendrücken, Einstellungen (Fork) | nein |
| übrige `s1-*`, `s2-*`, `s3-*`, `s4-*` | nicht begonnen | – |

## Branches

| Branch | Inhalt |
|---|---|
| `moonshot/main` | der Plan, diese Datei, die Abdeckungskarte; führt fertige Punkte zusammen |
| `moonshot/d30-fingerprint` | Fingerabdruck-Extraktor und Abdeckungskarte (Code + Tests) |
| `moonshot/d30-remote` | Spike `spikes/d30-remote` (Mac-App mit `RemoteImmersiveSpace`) |
| `moonshot/s2-coverage` | Prognose für ungetestete Spiele (auf `moonshot/d30-fingerprint`) |
| `moonshot/s4-appliance` | Start nur in der Menüleiste (auf `main`) |
| `ci/macos-build` | `.github/workflows/build.yml`: `swift build` + `swift test` auf `macos-26` |
| Klepton-Fork (privat): `moonshot/d30-host` | `tools/lab_run.sh` + `tools/lab/beatsaber145-menu.txt`; Sicherung in myMartek/klepton-fork |
| `claude/charming-hypatia-bk0hrt` | alter Stand der Cloud-Session; kann gelöscht werden |

**Abweichung vom Plan:** Der Plan nennt den Sammelbranch `moonshot` und die Punkte `moonshot/<kennung>`. Git erlaubt
nicht beides zugleich (ein Branch `moonshot` und Branches darunter). Der Sammelbranch heißt deshalb `moonshot/main`.

## Schritt 0: AVP Play in der Menüleiste

**Stand:** veröffentlicht am 27.10. als [AVP Play 1.5.5](https://github.com/myMartek/avp-play/releases/tag/v1.5.5)
(avp-play #92, Build 416, Toolchain 778 unverändert, signiert und beglaubigt). Wiki: Einstellungen › Die Menüleiste
(DE/EN). Backend unverändert.

Gemacht:
- `core/Sources/AVPPlayCore/MenuBar.swift`: `MenuBarPreferences` und `MenuBarStatus`, 8 Tests.
- `core/Sources/AVPPlayApp/MenuBar.swift`: Symbol mit Prozentzahl, Fenster mit Auftrag, Gerät, Fernsteuerung,
  Erneuerung, Knöpfe „AVP Play öffnen“, „Neu prüfen“, „Beenden“, „Aufträge“; Einstellungsabschnitt „Menüleiste“
  mit „Bei der Anmeldung öffnen“ (`SMAppService`).
- `App.swift`: Dock-Symbol weg beim Schließen (nur mit „Weiterlaufen“), zurück mit dem Fenster; Startblock läuft
  nur einmal; Rückfrage beim Beenden kommt nach vorn; `--snapshot` fotografiert Panel und Einstellungsabschnitt.

Auf dem Mac geprüft (von mir, mit einer Kopie unter eigener Bundle-ID neben dem echten AVP Play):
- [x] Symbol erscheint; Fenster unter dem Symbol öffnet per Klick.
- [x] „Weiterlaufen“ an: Fenster schließen → Prozess läuft weiter, Dock-Symbol weg.
- [x] „AVP Play öffnen“ → Fenster und Dock-Symbol zurück, Panel schließt sich (Fehler dabei gefunden und behoben),
      Suche und Filter bleiben erhalten.
- [x] „Weiterlaufen“ aus: Fenster schließen beendet das Programm wie bisher.
- [x] „Beenden“ aus der Menüleiste beendet das Programm.
- [x] Englisch und Deutsch; `--snapshot` erzeugt beide Bilder.

**Muss Marcel testen (mit 1.5.5):**
- [ ] Mit laufendem Auftrag: Fenster schließen → Auftrag läuft weiter; Prozentzahl neben dem Symbol beim Laden
      und Kopieren; ohne bekannte Größe ein Balken ohne Zahl.
- [ ] Mit laufendem Auftrag „Beenden“ aus der Menüleiste: Rückfrage erscheint im Vordergrund.
- [ ] AVP Play Remote bleibt verbunden, während das Fenster zu ist.
- [ ] „Bei der Anmeldung öffnen“ (habe ich nicht eingeschaltet, um keine Anmeldeobjekte auf deinem Mac anzulegen).
- [ ] Mit kostenlosem Apple-Konto: Zeile zur Erneuerung erscheint und stimmt.

Bekannte Lücke: Beim Start über die Anmeldung öffnet sich das Fenster. Ein Start nur in der Menüleiste gehört zu
`s4-appliance`.

## CI

- Erster Lauf (Run 40421259702): Runner `macos-26` nimmt **Xcode 26.6 (Swift 6.3.3)**; `swift build` hing nach
  `[46/72] Compiling AVPPlayCore Updater.swift` bis zum Zeitlimit von 40 Minuten. Mit Xcode 27 (Swift 6.4) auf dem
  Mac baut dasselbe in Sekunden. Vermutlich ein Ausdruck, an dem der ältere Typprüfer endlos rechnet – das trifft
  auch jeden, der AVP Play mit Xcode 26 aus dem Quellcode baut.
- Diagnose-Lauf auf `ci/macos-build` (Commit `37e62b8`): `-solver-expression-time-threshold=60` lässt den
  Typprüfer nach einer Minute mit Datei und Zeile abbrechen. Ergebnis: siehe unten, sobald da.
- Danach: die Stelle so umschreiben, dass Swift 6.3 sie schnell prüft, und CI als eigenen PR nach `main`.

## `d30-fingerprint`: Fingerabdruck-Extraktor und erste Abdeckungskarte

**Stand:** fertig für den Spike. Branch `moonshot/d30-fingerprint` (auf `main` mit 1.5.5), 9 neue Tests,
`swift test` 349 grün.

Gemacht:
- `core/Sources/AVPPlayCore/Fingerprint.swift`: `Fingerprint.make(apk:)` liest ein APK (über `unzip`) und liefert
  nur Namen: Engine und Fassung (Unity inkl. Unity 6, Unreal), il2cpp/Mono, Vulkan/GLES, XR-Schnittstellen
  (Plattform-SDK, OVRPlugin, VrApi, OpenXR) mit ihren Funktionen – **fest eingebunden** (ELF-Importe) getrennt von
  **nur genannt** (Strings, z. B. Unitys P/Invoke-Hülle) –, OpenXR-Erweiterungen, Bibliotheken, Middleware,
  `uses-feature`/Berechtigungen/Oculus-`meta-data` (Werte nur bei Geräteangaben, nie Schlüssel), Java-Pakete aus dem
  Dex-Code, JNI-Klassenpfade. ELF- und Dex-Leser selbst geschrieben, keine Fremdabhängigkeit.
- `core/Sources/AVPPlayCore/Coverage.swift`: `RuntimeInterface.scan(klepton:)` liest, welche Namen die
  Klepton-Quelle nennt; `Coverage`/`CoverageMatrix` vergleichen, ordnen die Lücken nach Unlock-Wert und fassen das
  Plattform-SDK nach Bereichen zusammen (Markdown, JSON).
- CLI: `avpplay fingerprint <apk>…` und `avpplay coverage --klepton <Ordner> <apk|Ordner>… [--markdown] [--json]`.
- Gelaufen auf allen 59 APKs auf deiner externen Platte (77 s); die Karte der 50 APKs mit Rezept liegt in
  [`moonshot-abdeckung.md`](moonshot-abdeckung.md). Die übrigen (deine Entwürfe) habe ich nicht in den Branch
  gelegt, weil sie zeigen, was du gekauft hast.

Was die erste Karte sagt (Klepton `ccb7287` = Toolchain 778):
- **Unreal-Spiele binden das Plattform-SDK fest ein**, Unity-Spiele nennen es nur (P/Invoke). Bei Unreal fehlen der
  Runtime jeweils ~95 eingebundene `ovr_*`-Funktionen, und zwar immer dieselben Bereiche: **Leaderboard,
  Achievement, User (Listen), Voip, CloudStorage, DataStore, Net/Packet, Matchmaking, Room**. Dann kommen
  UserProof (7 Spiele), AssetFile (4–5), GroupPresence/Invite (4).
- **Wichtig:** Auch verifizierte Spiele (Vader I–III, Moss, Red Matter, Medal of Honor) haben diese Lücken und laufen.
  „Fehlt“ heißt also „landet beim allgemeinen Ersatz“, nicht „bricht“. Welche Lücken ein Spiel wirklich
  aufhalten, sagt erst ein Lauf mit Protokoll (`plat_hit` in `kl_ovrplat.c`) – das ist `s1-headless`.
- OVRPlugin ist gut abgedeckt (552 Namen in der Runtime); VrApi wird nicht nachgebildet, aber nur Elixir ruft es
  direkt (4 Funktionen) und läuft trotzdem.
- OpenXR-Erweiterungen, die Spiele erfragen und die Runtime nicht nennt: vor allem `XR_EXT_hand_tracking`,
  `XR_EXT_eye_gaze_interaction` (Unreal), bei Unity 6 viele neue (`XR_EXT_future`, `XR_EXT_spatial_*`,
  `XR_META_foveation_eye_tracked`). Erweiterungen fremder Hersteller (Varjo, Microsoft, …) zählen nicht, die hat die
  Quest auch nicht.

Grenzen (bewusst, für den Spike):
- „Genannt“ in der Runtime heißt nicht „umgesetzt“ (auch eine bewusste Absage ist genannt, ebenso ein Name in einem
  Kommentar).
- Unity-Spiele zeigen die ganze Plattform-Hülle (~650 genannte, 0 eingebundene); dort sagt die Karte wenig.

**Entscheidung für Marcel:**
- [ ] Soll der Extraktor (ohne die Karte) als eigener PR nach `main`? Er ändert in der App nichts, nur Bibliothek
      und CLI. Der Plan sieht das vor („Was für sich allein nützt, geht zusätzlich als eigener Pull Request“).

Nächste Schritte (für `s2-fingerprint`/`s2-coverage`/`s2-unlock`):
- Den Fingerabdruck beim Laden eines Spiels erstellen und neben dem APK ablegen (lokal).
- Hochladen nur mit Zustimmung (Einstellung, wie die Telemetrie) – braucht den Katalogdienst, nicht in diesem Repo.
- Prognose auf der Spielseite eines ungetesteten Spiels (`s2-coverage`).
- Die echten Aufrufe aus Laufprotokollen dazunehmen, sobald `s1-headless` steht; dann wird aus „genannt“ „gerufen“.

## `d30-host`: Beat Saber ohne Headset auf dem Mac bis ins Hauptmenü

**Stand:** erreicht am 27.10. Die Frage „Ist Säule 1 machbar?“ ist beantwortet: **ja, und vieles davon gibt es
schon.** Klepton hat seit Langem einen macOS-Wirt (`build_run_host.sh`, ANGLE und MoltenVK für macOS); frühere
Sitzungen haben damit Demeo bis in die Lobby und Premium Bowling bis ins Menü gebracht.

Gemacht:
- Beat Saber 1.45 (deine Kopie, Ziel `beatsaber140`) in einem eigenen Fork-Worktree `klepton-fork-d30`,
  Branch `moonshot/d30-host` (auf `release-538` = Toolchain 778).
- Über die Managed-Probe (`KL_PROBE_SCRIPT`, ruft die C#-Methoden des Spiels auf) klickt ein Skript die
  Erststart-Bildschirme durch: Sprache, Region, Datenschutz, EULA, Gesundheitswarnung, Hinweis auf explizite
  Inhalte. Nach **38 Sekunden** steht das Hauptmenü (Solo, Online, Kampagne, Party), offline, ohne Headset, ohne
  Mensch. 4200 Bilder gepumpt, kein unimplementierter Aufruf.
- `tools/lab_run.sh <ziel> <skript> <ordner>`: ein Laborlauf mit Eingabeskript; legt `run.txt`, `guest.log`,
  verkleinerte Bilder und `summary.txt` in einen Ordner. Das ist der erste Baustein von `s1-headless`
  (Plan: `avpplay lab run <spiel>`).

Grenzen und was für `s1-headless` noch fehlt:
- Eingaben gehen nur über C#-Methoden (Unity/IL2CPP). **Synthetische Kopf- und Controllerposen** fehlen noch
  (das Log sagt „never had a controller“); Unreal- und native Spiele brauchen einen anderen Weg.
- Bildzeiten pro Frame werden noch nicht ausgegeben.
- Kein Netz (absichtlich), keine Foveation, kein Headset-Compositor: Schärfe und Anzeige bleiben Brillensache.

## `d30-remote`: der Mac rendert, die Vision Pro zeigt

**Stand:** Spike gebaut (`spikes/d30-remote` auf `moonshot/d30-remote`), baut mit Xcode 27, startet auf dem Mac
(„Entfernte Räume: unterstützt“). **Nicht in der Brille getestet.**

Die wichtigste Antwort kommt schon aus dem macOS-27-SDK:
- **Geht vom Mac aus:** Bild in die Brille (`RemoteImmersiveSpace` + Compositor Services), Kopfposition
  (`WorldTrackingProvider`), Schauen + Pinch mit Strahl und Handpose (`onSpatialEvent`).
- **Geht nicht vom Mac aus:** Handskelett (`HandTrackingProvider` ist auf macOS gesperrt) und
  **PS-VR2-Controller** (`AccessoryTrackingProvider` ebenso).
- Folge: Spiele mit Controllern brauchen für `s1-remote` eine Gegenstelle auf der Brille, die Controller und
  Hände liest und an den Mac schickt (passt in AVP Play Remote). Das Limit „3 Apps, 7 Tage“ fiele für das Bild
  trotzdem, weil auf der Brille nur diese eine App läuft.

**Muss Marcel testen:** `spikes/d30-remote/README.md` hat die Liste (Würfel steht im Raum, Bildabstand,
Vorlauf, Pinch zählt, gefühlte Latenz).

## `s2-coverage`: Prognose für ungetestete Spiele

**Stand:** fertig auf `moonshot/s2-coverage`, `swift test` 351 grün. Nicht in einem Release.

Die rohe Lückenzahl aus `d30-fingerprint` täuscht (geprüfte Spiele haben dieselben Lücken). Die Prognose vergleicht
darum mit den **geprüften Spielen**:
- `ReferenceFingerprint`: Merkmale (Engine, Hauptfassung, il2cpp/Mono, Vulkan/GLES, XR-Schnittstellen, Middleware),
  fest eingebundene Funktionen, Quest-Erweiterungen. Die 46 geprüften Spiele aus deinem Bestand liegen als
  `recipes/fingerprints/verified.json` bei (190 KB, nur Namen); `make-app.sh` packt sie ins Programm.
- `Prognosis`: die drei ähnlichsten geprüften Spiele (Jaccard); **ungewöhnlich** ist, was das Spiel fest einbindet
  oder erfragt und weder die Runtime noch ein geprüftes Spiel kennt (OVRPlugin, OpenXR, VrApi, Erweiterungen).
  Daraus „gute Aussichten“ / „möglich“ / „eher nicht“. Unbekannte Plattform-Aufrufe ändern die Aussicht nicht,
  sie werden als „Online-Funktionen können fehlen (Leaderboard, …)“ genannt. Nur 32-Bit oder VrApi direkt = läuft nicht.
- **Gegenprobe** (jedes geprüfte Spiel gegen die übrigen 45): 34 gute Aussichten, 12 möglich, **0 „eher nicht“**.
- Deine ungetesteten Spiele: 8 von 9 „gute Aussichten“, Eleven Table Tennis „möglich“. **Grenze:** Gods of Gravity
  (inkompatibel wegen Metas Nutzernachweis) und VRChat (Anti-Cheat) kommen auch auf „gute Aussichten“ – solche
  Server-Sperren sieht man im APK nicht. Für als inkompatibel gemeldete Spiele zeigt die Seite keine Prognose.
- Spielseite: im Kasten „Dieses Spiel hat noch niemand getestet“ steht die Prognose, sobald das APK auf dem Mac
  liegt; aufklappbar die ähnlichen Spiele und was der Toolchain unbekannt ist. Der Fingerabdruck wird neben dem APK
  zwischengespeichert (`<apk>.fingerprint.json`), die Namen der Toolchain einmal aus ihren Quellen gelesen.
- CLI: `avpplay references --out <datei>`, `avpplay prognosis --klepton <ordner> --references <datei> <apk>…`.

**Muss Marcel testen/entscheiden:**
- [ ] Die Prognose auf der Seite eines geladenen, ungetesteten Spiels ansehen (Text, Farben, Aufklappen). Ich habe
      die Ansicht nicht mit deinem Bestand gestartet, weil ein Testbau dabei mit deinem Meta-Zugang Besitzabfragen
      stellen und nach dem Schlüsselbund fragen würde. Gebaut und mit CLI/Tests geprüft ist sie.
- [ ] Ob die Fingerabdrücke der geprüften Spiele (nur Namen) so im öffentlichen Repo liegen dürfen. Der Plan erlaubt
      das ausdrücklich; der Branch ist schon gepusht.

## `s4-appliance`: Start nur in der Menüleiste

**Stand:** gebaut auf `moonshot/s4-appliance` (auf `main` mit 1.5.5). Nicht in einem Release.

- Öffnet macOS AVP Play bei der Anmeldung (Anmeldeobjekt, auch über `SMAppService`) und ist „In der Menüleiste
  weiterlaufen“ an, startet es ohne Fenster und ohne Dock-Symbol. Erkannt am Öffnen-Ereignis
  (`keyAELaunchedAsLogInItem`).
- Der Startblock (Katalog, Geräte- und Spielstandwache, Update-Check) liegt jetzt in `AppModel.startUp()` und
  läuft auch ohne Fenster – damit AVP Play Remote die Spiele sieht.
- Geprüft: normaler Start und `--snapshot` unverändert.

**Muss Marcel testen:**
- [ ] „Bei der Anmeldung öffnen“ + „Weiterlaufen“ an, abmelden, anmelden: nur das Symbol erscheint, kein Fenster;
      AVP Play Remote verbindet sich und sieht die Spiele; „AVP Play öffnen“ zeigt das Fenster mit geladenem Katalog.
- [ ] Dasselbe mit „Weiterlaufen“ aus: Fenster erscheint wie bisher.

Offen in `s4-appliance`: Wake-on-LAN aus der Brille (in AVP Play Remote), Erneuerung aus der Menüleiste steuern.

## `s1-headless`: Laborlauf

- `tools/lab_run.sh` (Fork, `moonshot/d30-host`) kann jetzt drei Arten von Schritten: Aufrufe in das C# des Spiels,
  **Controller-Drücke** (`poke <zeit>:<TASTE>`, über das vorhandene `KL_OVRP_POKE`, geht für jede Engine) und
  Einstellungen (`env KL_OVRP_HEAD=…`). Kopfpose für Läufe ohne Brille gibt es schon (`KL_OVRP_HEAD`).
- Fund: `poke f<bild>` zählt Vulkan-Bilder; bei GL-Spielen (Beat Saber 1.45) greift es nie – dort Sekunden angeben.
- Noch offen: `avpplay lab run <spiel>` in AVP Play. Dafür fehlt im Toolchain-Paket die Mac-Fassung von ANGLE (es
  bringt nur die visionOS-Teile mit); Bildzeiten pro Frame im Ergebnis; Controller-**Posen** über die Zeit.

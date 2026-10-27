# Moonshot „Tag Eins“: Umsetzungsstand

Der Plan steht in [`moonshot.md`](moonshot.md). Diese Datei sagt pro Punkt, wie weit er ist, was gemacht wurde, was
noch fehlt und **was Marcel testen oder entscheiden muss**. Sie ersetzt die `HANDOFF.md` der Cloud-Session.

Stand: 27. Oktober 2026.

## Übersicht

| Kennung | Stand | Wartet auf Marcel? |
|---|---|---|
| Schritt 0 (Menüleiste) | **veröffentlicht in AVP Play 1.5.5** | Test der offenen Punkte unten |
| CI | **verworfen** (27.10.): kein CI; geprüft wird lokal mit Xcode 27 und vor jedem Release mit `make check` | nein |
| `d30-fingerprint` | **Extraktor fertig, getestet, auf 59 APKs gelaufen**, erste Abdeckungskarte da | Entscheidung: als PR nach `main`? |
| `d30-host` | **erreicht**: Beat Saber 1.45 ohne Headset auf dem Mac bis ins Hauptmenü, mit Bildern, per Skript | nein |
| `s1-remote` | **Beat Saber vom Mac in die Brille gebaut** (`KleptonRemote.app` + `KleptonRelay` auf der Brille); auf dem Mac ohne Brille durchgeprüft bis ins Hauptmenü | **ja: heute Abend in der Brille testen** (Anleitung unten) |
| `d30-remote` | **in der Brille gesehen** (27.10.): Würfel steht im Raum; schwarze Kacheln am Rand im Mixed-Modus (Grenze des Mac-Wegs) | ja: einmal kurz öffnen für Bildabstand/Vorlauf |
| `s2-coverage` | **Prognose fertig** (Kern, CLI, Spielseite), auf geprüften Spielen gegengeprüft | **ja: Spielseite ansehen** |
| `s2-fingerprint` | **Teilen per Opt-in fertig** (App + Katalogdienst-Endpunkt, privat, nicht ausgerollt) | **ja: Freigabe + Rollout** |
| `s2-unlock` | **Roadmap fertig** (`avpplay unlock`), lokal mit 59 Fingerabdrücken durchgespielt | hängt an Rollout |
| `s4-appliance` | **Start nur in der Menüleiste** bei der Anmeldung gebaut | **ja: Test mit Ab-/Anmelden** |
| `s1-headless` | **fertig**: `avpplay lab run <spiel>` mit Eingabeskript (Aufrufe, Drücke, **Posen**), Bildzeiten pro Frame, Laborpaket (ANGLE + MoltenVK für den Mac) | nein (Freigabe für das Laborpaket als Download erst beim Release) |
| `s2-judge` | **Bildprüfung fertig** (`avpplay lab judge`): schwarz, einfarbig, magenta, ein Auge, Stillstand, angehalten; an Beat Saber und Demeo gegengeprüft | nein (Urteil per Bildmodell offen, braucht einen API-Schlüssel) |
| `s2-engines` | **Analyse**: 94 Schalter sind pro Spiel gesetzt, Kandidaten für Engine-Regeln benannt | nein (Umsetzung braucht Brillen-Tests) |
| übrige `s1-*`, `s2-*`, `s3-*`, `s4-*` | nicht begonnen | – |

## Branches

| Branch | Inhalt |
|---|---|
| `moonshot/main` | der Plan, diese Datei, die Abdeckungskarte; führt fertige Punkte zusammen |
| `moonshot/d30-fingerprint` | Fingerabdruck-Extraktor und Abdeckungskarte (Code + Tests) |
| `moonshot/d30-remote` | Spike `spikes/d30-remote` (Mac-App mit `RemoteImmersiveSpace`) |
| `moonshot/s2-coverage` | Prognose für ungetestete Spiele (auf `moonshot/d30-fingerprint`) |
| `moonshot/s4-appliance` | Start nur in der Menüleiste (auf `main`) |
| `moonshot/s2-fingerprint` | Teilen der Fingerabdrücke + `avpplay unlock` (auf `moonshot/s2-coverage`) |
| privates Repo: `moonshot/s2-fingerprint` (Worktree `BeatSaberVR/qi-s2-fingerprint`) | Katalogdienst: `POST /api/v1/fingerprints`, `GET /api/v1/fingerprints/summary`; nicht in `main`, nicht ausgerollt |
| ~~`ci/macos-build`~~ | gelöscht (lokal und auf GitHub, samt aller Läufe) |
| Klepton-Fork (privat): `moonshot/s1-remote` (auf `moonshot/d30-host`, Worktree `QuestInstaller/klepton-fork-d30`) | `KleptonRemote.app` (`mains/KleptonRemote.swift`, `runtime/gfx/kl_remote_mtl.m`, `tools/remote/`), Relay-App `spikes/relay`; Sicherung in myMartek/klepton-fork |
| Klepton-Fork (privat): `moonshot/d30-host` | `tools/lab_run.sh` + `tools/lab/beatsaber145-menu.txt`; Sicherung in myMartek/klepton-fork |
| Klepton-Fork (privat): `moonshot/s1-headless` (auf `moonshot/s1-remote`, Worktree `QuestInstaller/klepton-fork-d30`) | Bildzeiten (`KL_FRAME_TIMES`), Posen (`KL_OVRP_POSE`), `lab_run.sh` mit `pose`, `--link`, Vulkan-Augen; Sicherung in myMartek/klepton-fork |
| `moonshot/s1-headless` (auf `main` mit 1.5.5, Worktree `QuestInstaller/avp-play-s1headless`) | `avpplay lab run/pack/install/judge` (`LabRun.swift`, `LabJudge.swift`, 9 Tests) |
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

- **Verworfen am 27.10. (Marcels Entscheidung).** Die Cloud-Session hatte den Workflow angelegt, weil sie keinen Mac
  hat. Auf GitHubs `macos-26`-Runner gab es nur Xcode 26.6, und Swift 6.3 blieb im Bau von `AVPPlayCore` hängen.
  Nutzen zu gering: Rezepte und Klepton prüft der Lauf nicht, gebaut und getestet wird lokal mit Xcode 27, vor
  jedem Release läuft `make check`.
- Branch `ci/macos-build`, Worktree und alle sechs Läufe sind gelöscht; auf GitHub gibt es keinen Workflow mehr.
- Folge für Cloud-Sessions: sie können nicht selbst bauen; ihr Stand muss hier auf dem Mac gebaut und getestet werden.

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

## `s1-remote`: Beat Saber vom Mac in die Brille

**Stand (27.10.):** gebaut und auf dem Mac ohne Brille durchgeprüft, **noch nicht in der Brille**.
- `KleptonRemote.app` = Kleptons Mac-Programm (`m_boot`) mit `KL_REMOTE=1`: eine SwiftUI-App öffnet einen
  `RemoteImmersiveSpace` (voll) in der gekoppelten Brille, gibt Kopfposition und Augengeometrie der Brille an das
  Spiel und zeichnet dessen Bild mit derselben Umrechnung wie auf der Brille (`kl_reproject`) in den Raum. Das Spiel
  startet erst, wenn die Brille vermessen ist (wie `primeDisplay` auf dem Gerät).
- Beat Saber 1.45 läuft über OpenXR; das Bild kommt als Projektionsebene. Foveation im Spiel ist auf dem Mac aus
  (`KL_VRR=0`), die Brille foveiert selbst.
- **Eingabe:** macOS bekommt keine Controller und kein Handskelett. Deshalb:
  - **KleptonRelay** (auf der Brille installiert): liest die Sense-Controller per GameController, auch im
    Hintergrund, und schickt Knöpfe, Abzüge und Sticks per UDP an den Mac (Bonjour `_klrelay._udp`).
  - Ohne Posen hängen beide Controller vor dem Kopf und zeigen dahin, wo du hinschaust: Menüs gehen per Blick +
    Abzug.
  - **Hinschauen + Pinch** = rechter Abzug auf dem Blickstrahl (ohne Relay).
  - Posen gibt ARKit nur einer App mit eigenem immersiven Raum. Der „Posen-Test“ im Relay öffnet einen – was dann
    mit dem Mac-Raum passiert, ist die offene Frage (vermutlich schließt er sich).
- **Selbsttest ohne Brille** (`KL_REMOTE_SELFTEST=<ordner> tools/remote/run.sh` + `python3
  tools/remote/relay_test.py`): Bild kommt im Compositor an; ein Relay-Abzug drückt „Continue“ im
  Sicherheitshinweis, Beat Saber zeigt das Hauptmenü mit rechtem Controller und Laserpointer.
- Spielstand: `build/remote/bs-state` (Sprache, Region, EULA usw. per `lab_run` weggeklickt); den
  Sicherheitshinweis zeigt Beat Saber bei jedem Start.

**Muss Marcel testen (heute Abend):**
1. Auf der Brille **Klepton Relay** öffnen (Lokales-Netzwerk-Abfrage erlauben). Zeigt es „Links/Rechts“ mit
   Werten und unter „Mac“ „Klepton Remote“?
2. Am Mac im Fenster **Klepton Remote – beatsaber140** auf „In der Vision Pro öffnen“. Die App läuft schon; ob ihr
   Fenster aufging, konnte ich bei gesperrtem Mac nicht sehen. Fehlt es: App beenden und in
   `QuestInstaller/klepton-fork-d30` neu starten mit `tools/remote/run.sh`. Brille vorher wie für „Mac Virtual
   Display“ koppeln. Log: `build/remote/beatsaber140.log`.
3. Nach ~1 s Vermessung startet Beat Saber (Sicherheitshinweis). Mit Kopf zielen, Abzug drücken (oder hinschauen +
   pinchen) → Hauptmenü.
4. Berichten: Bild stabil beim Kopfdrehen? Gefühlte Verzögerung? Kommen Abzug/Stick an, obwohl das Relay im
   Hintergrund ist (Zeile „Im Hintergrund“ im Relay)? Werte im Mac-Fenster (Bilder Brille / Spielbilder / Vorlauf).
5. Danach im Relay „Posen-Test“: Was passiert mit dem Mac-Raum? Kommen Posen an (Zeile „Posen“)?

**Was fehlt:** Controller-Posen neben dem Mac-Raum (der Kern für Lieder spielen), Ton (läuft auf dem Mac, nicht in
der Brille), Haptik, ein Startweg aus AVP Play. **Alyx:** auf dem Mac nicht machbar ohne großes Projekt – Kleptons
Linux-Pfad ist auf dem Mac nur bis zum glibc-Loader erprobt, Alyx lief dort nie (72 GB, Source 2, xrizer).

## `d30-remote`: der Mac rendert, die Vision Pro zeigt

**Stand:** Spike gebaut (`spikes/d30-remote` auf `moonshot/d30-remote`), baut mit Xcode 27, startet auf dem Mac
(„Entfernte Räume: unterstützt“). **Erster Test in der Brille am 27.10.** (`b1e7b49`):
- Würfel erscheint und steht fest im Raum, Kopfposition läuft. Zwei Fehler dabei gefunden und behoben: die
  Foveation-Karte fehlte im Render-Durchgang (Würfel verzerrt, wirkte 1 cm nah), und die Krone ließ die Mac-App
  abstürzen (`endSubmission` ohne Ziel).
- PS-VR2-Controller: der Mac sieht nichts davon – bestätigt.
- **Offen:** schwarze Kacheln am Rand des Würfels, obwohl durchsichtig gelöscht wird (auf der Brille selbst hat
  genau das bei Triangle Strategy geholfen, Klepton `6c8b7c3`). Vermutung: beim Bild vom Mac geht das Alpha
  unterwegs verloren, der Raum erscheint nur in Kacheln ganz ohne Tiefe. Für Spiele in voller Immersion egal, für
  Mixed-Reality-Spiele über den Mac ein Problem.
- Auf macOS gibt es für den entfernten Raum nur „stufenlos“ (Krone) und „voll“, kein „gemischt“.

Die wichtigste Antwort kommt schon aus dem macOS-27-SDK:
- **Geht vom Mac aus:** Bild in die Brille (`RemoteImmersiveSpace` + Compositor Services), Kopfposition
  (`WorldTrackingProvider`), Schauen + Pinch mit Strahl und Handpose (`onSpatialEvent`).
- **Geht nicht vom Mac aus:** Handskelett (`HandTrackingProvider` ist auf macOS gesperrt) und
  **PS-VR2-Controller** (`AccessoryTrackingProvider` ebenso).
- Folge: Spiele mit Controllern brauchen für `s1-remote` eine Gegenstelle auf der Brille, die Controller und
  Hände liest und an den Mac schickt (passt in AVP Play Remote). Das Limit „3 Apps, 7 Tage“ fiele für das Bild
  trotzdem, weil auf der Brille nur diese eine App läuft.

- 16-Bit-Farbe mit Alpha ändert an den Kacheln nichts, Foveation aus (0 Karten im Protokoll) auch nicht; alle
  Varianten öffnen (`1b88278`). **Ergebnis:** beim Bild vom Mac zeigt die Brille den Raum nur in Kacheln ohne
  jeden Inhalt, das Alpha innerhalb einer Kachel zählt nicht. Aus der App heraus nicht zu beheben, soweit
  getestet. Folge für `s1-remote`: Spiele in voller Immersion gehen, Mixed-Reality-Spiele über den Mac bekommen
  schwarze Kacheln an den Rändern.

- Bild beim schnellen Kopfdrehen stabil, Pinch wird gezählt (Marcel, 27.10.).

**Muss Marcel testen:** nur noch Bildabstand und Vorlauf – die App schreibt sie jetzt alle 5 s ins Protokoll,
ein Öffnen von ein paar Sekunden reicht. App: `spikes/d30-remote/make-app.sh`,
dann `.build/D30Remote.app`.

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

**Stand (27.10.):** fertig, auf dem Mac geprüft. Nicht in einem Release.

So geht es (in AVP Play, ohne Brille):

```bash
avpplay lab install klepton-lab-mac.tar.gz
avpplay lab run beatsaber140 --script tools/lab/beatsaber145-menu.txt
```

- **Eingabeskript** (`tools/lab_run.sh` im Fork), eine Zeile je Schritt: Aufrufe in das C# des Spiels
  (`<bild>:<Klasse>::<Methode>`), Controller-Drücke (`poke <zeit>:<TASTE>`), **Controller-Posen über die Zeit**
  (`pose <zeit>:<L|R>:x,y,z[,gieren,nicken,rollen]`, neu: `KL_OVRP_POSE`, die Hand fährt geradlinig zum nächsten
  Schlüsselbild, mit Geschwindigkeit) und Einstellungen (`env NAME=WERT`).
- **Ergebnisordner:** Protokoll, Bilder (GL: ein Auge; Vulkan: beide), `frames.csv` mit jedem Frame des Spiels
  (neu: `KL_FRAME_TIMES`, gezählt an `xrEndFrame`, OVRPlugins `EndFrame` und `eglSwapBuffers`) und eine
  Zusammenfassung mit Rate, Median, p95, p99, längster Lücke und Hängern. Frames, in die ein gespeichertes PNG fiel,
  zählen nicht mit (ein PNG kostet bis zu einer Sekunde).
- **Laborpaket:** ANGLE und MoltenVK für den Mac, ohne Symbole und neu signiert, 18,5 MB
  (`avpplay lab pack --from <Fork> --to <Ordner>`). Es steckt bewusst nicht im Toolchain-Paket (das wüchse bei
  jedem Update um zwei Drittel für eine Funktion, die wenige brauchen). **Offen:** wo es zum Herunterladen liegt
  (z. B. als Datei einer GitHub-Veröffentlichung); bis dahin von Hand installieren.
- **Nur Toolchains ab diesem Stand** haben `tools/lab_run.sh`; eine ältere sagt das, bevor etwas läuft.
- **Geprüft:** Beat Saber 1.45 über `avpplay lab run` vom Sprachbildschirm ins Hauptmenü (3296 Frames, Median
  5,1 ms); Demeo (Vulkan, Store-Spiel) bis zum Datenschutzhinweis; Posen sichtbar (der Laser zieht über das Menü).
- **Was es nicht kann:** Netz (immer offline), Bildschärfe und alles am Display der Brille; Unreal-Spiele zählen
  keine Bilder, für sie gilt `--seconds`.

## `s2-judge`: Bildprüfung

**Stand (27.10.):** fertig ohne Bildmodell. `avpplay lab run` schreibt nach jedem Lauf `judge.json`,
`avpplay lab judge <ordner>` beurteilt einen früheren.

- Jedes Bild wird auf 64 × 64 gemessen: **schwarz**, **einfarbig** (ein Löschen ohne Zeichnen, weiß, rosa),
  **magenta** (fehlende Texturen oder Shader) oder Inhalt; bei Vulkan beide Augen.
- Das Urteil sieht auf das letzte Drittel: angehalten (fehlender Aufruf, Absturz), kein Bild, kaputtes Bild,
  **ein Auge**, Stillstand (ruhiges Menü oder Hänger), Bild.
- **Gegengeprüft** mit dem, was ich auf den Bildern sehe: Beat Saber ins Menü → Bild; Beat Saber mit
  `KL_GL_MSRTT=0` → kein Bild (wirklich schwarz); Demeo am Datenschutzhinweis → Stillstand (stimmt: es wartet auf
  eine Eingabe).
- **Offen:** ob ein Menü erreicht ist oder das Bild verzerrt ist, kann nur ein Bildmodell sagen. Das braucht einen
  API-Schlüssel und schickt Bilder des Spiels nach außen – deine Entscheidung, nicht gebaut.

## `s2-fingerprint` und `s2-unlock`: Teilen und Roadmap

**Stand:** fertig auf `moonshot/s2-fingerprint` (App, öffentlich) und auf dem privaten Branch `moonshot/s2-fingerprint`
(Katalogdienst). **Nicht ausgerollt, nicht veröffentlicht.**

App:
- Einstellungen › Online-Katalog: **„Fingerabdrücke ungetesteter Spiele mit dem Projekt teilen“**, aus, solange
  niemand es einschaltet (wie die Telemetrie). Ist es an, schickt die App den Fingerabdruck eines Builds einmal,
  wenn die Seite eines ungetesteten Spiels die Prognose rechnet.
- Was geht: Engine, Grafik, Schnittstellen, fest eingebundene Funktionen, Erweiterungen, Middleware, Gerätemerkmale
  (`SharedFingerprint`). Was nie geht: Paketname, Berechtigungen, Java-Pakete, bloß genannte Namen, etwas über den
  Nutzer. Ein Test hält die Schlüssel fest.
- `avpplay unlock --klepton <ordner>` holt die Summen vom Dienst und listet, was der Runtime fehlt, nach Zahl der
  Spiele; `avpplay fingerprint --shared <apk>` zeigt, was das Teilen schicken würde.

Katalogdienst (privat, Go):
- `POST /api/v1/fingerprints`: ein Build einmal; nur Namen aus festem Zeichenvorrat, bekannte Familien und Engines,
  unbekannte Felder abgelehnt, Middleware nur aus der Liste der App, 60 pro Stunde und Absender.
- `GET /api/v1/fingerprints/summary`: pro Funktion und Erweiterung die Zahl der Spiele (neuester Build je Spiel),
  ohne Spielnamen. Tests grün.

Durchgespielt (lokal, Dienst auf 127.0.0.1, nichts nach außen): alle 59 Fingerabdrücke von deiner Platte
angenommen (einer erst nach einer Korrektur: Leerzeichen am Ende eines Namens im Manifest des Spiels). Die Roadmap
daraus, Toolchain 778:
- Erweiterungen: `XR_EXT_hand_tracking` (14 Spiele), `XR_EXT_eye_gaze_interaction` (10), `XR_EXT_palm_pose` (8),
  `XR_OCULUS_audio_device_guid` (8), `XR_META_foveation_eye_tracked` (7) …
- Funktionen: VrApi-Reste in 3 Spielen, Kamera-Funktionen von OVRPlugin in einem.
- Plattform-Bereiche (Online): Leaderboard (23), Achievement, User, Voip (22), CloudStorage, DataStore, Net (21) …

**Muss Marcel entscheiden:**
- [ ] Ob die Endpunkte so in den Katalogdienst dürfen; dann privaten Branch nach `main` und beim nächsten Rollout mit.
- [ ] Der Text der Einstellung (DE/EN) und dass sie aus ist, bis man sie einschaltet.

## `s2-engines`: welche Anpassungen eigentlich Engine-Regeln sind

**Stand:** nur Analyse, kein Code. Ein Skript hat die Runtime (Toolchain 778) nach Schaltern durchsucht, die für
bestimmte Spiele von selbst an sind: **94 solche Schalter**. Gegen die Fingerabdrücke der betroffenen Spiele
gelegt, sehen einige nach einer Regel für eine ganze Engine-Generation aus statt nach Einzelfällen:

| Schalter | Spiele | was sie gemeinsam haben | mögliche Regel |
|---|---|---|---|
| `KL_GLFB_COPYIMAGE_EMU` | 9 | alle bekannten: Unreal | Unreal auf GLES |
| `KL_OVRP_GL_ARRAY` | 5 | alle: Unreal | Unreal auf GLES mit OVRPlugin |
| `KL_GLFB_SHARED_MIGRATE` | 6 | alle bekannten: Unreal | Unreal auf GLES |
| `KL_OVRP_PASSTHROUGH` | 9 | überwiegend Unity 6, Mixed Reality | Manifest verlangt Passthrough |
| `KL_OVRP_ADAPTER_PHYS` + `KL_VK_PARK_INSTANCE` | 6 | Unity 6 mit OculusXR (Walkabout, Demeo, Arkham …) | Unity 6 + OculusXR-Plugin + Vulkan |
| `KL_OVRP_VERSION` | 7 | Unity 6 / 2022 | aus der OVRPlugin-Fassung des Spiels (die liest `targets.py` schon) |
| `KL_ELF_TLSDESC` | 7 | – | aus den ELF-Relokationen des Spiels ablesbar |

Nächster Schritt (braucht Tests auf dem Mac **und** in der Brille, deshalb nicht allein gemacht): je Regel die
Erkennung in `_generic_row()` (`targets.py`) bzw. in der Runtime, dann alle geprüften Spiele dieser Engine auf dem
Mac durchlaufen lassen (`tools/lab_run.sh`) und mindestens zwei in der Brille ansehen. So bekäme ein neues Spiel
dieser Generation die Anpassungen, ohne eine eigene Zeile.

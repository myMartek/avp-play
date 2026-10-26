# Moonshot „Tag Eins“

> **Nordstern:** Jedes Quest-Spiel, das du besitzt, läuft spätestens am Tag nach dem Kauf auf deiner Vision Pro.
> Es läuft besser als auf der Quest, und kein Mensch musste dafür eine Zeile Code schreiben.

Dieser Plan beschreibt, wie AVP Play in zwölf Monaten vom Installer zu einem System wird, das Spiele weitgehend
selbst portiert. Er enthält die Punkte, die am 26. Oktober 2026 aus der Ideensammlung ausgewählt wurden (21 von 27).
Die nicht gewählten Punkte stehen am Ende, damit sie später wieder aufgegriffen werden können.

Ausgangslage: Laden, Übersetzen, Signieren und Installieren sind gelöst. Der Engpass ist das, was `CONTRIBUTING.md`
„the real work“ nennt: Jedes neue Spiel braucht ein Target und meist Handarbeit in der Runtime (`kl_ovrplat.c`,
`kl_jni.c`, `kl_il2cpp.c`, `targets.py`). Heute gibt es 49 Rezepte, im Meta Store mehrere tausend Titel.

## Leitplanken

Sie gelten für jeden Punkt dieses Plans und werden nicht verhandelt:

- **Nur, was man besitzt.** Die Besitzprüfung bleibt vor jedem Download. Laborläufe nutzen nur die eigenen Käufe
  des jeweiligen Rechners.
- **Kein Spielinhalt verlässt je einen Rechner.** Geteilt werden Code, Rezepte, Fingerabdrücke (Namen von
  Funktionen und Klassen), Absturzsignaturen und Steuerungsprofile.
- **Alles, was geteilt wird, ist Opt-in**, sichtbar und in den Einstellungen abschaltbar, wie heute die Telemetrie.
- **KI-Patches kommen erst nach menschlicher Prüfung** in eine signierte Toolchain.
- Wie bisher: Jeder sichtbare Text auf Englisch und Deutsch (`L("…", "…")`), jedes neue Verhalten mit Test,
  `swift test` muss durchlaufen, Layout wird mit `--snapshot` geprüft.

## Arbeitsweise und Branches

- **Jeder Punkt bekommt einen eigenen Branch**, benannt nach seiner Kennung: `moonshot/<kennung>`, zum Beispiel
  `moonshot/s1-mac-host`. Er zweigt von `main` ab, oder vom Branch des Punkts, auf dem er aufbaut.
- **Der Branch `moonshot` führt die fertigen Punkte zusammen.** Ein Punkt kommt dorthin, wenn er seine
  Fertig-Kriterien erfüllt und `swift test` durchläuft. `moonshot` wird regelmäßig mit `main` abgeglichen.
- **Was für sich allein nützt, geht zusätzlich als eigener Pull Request nach `main`** und in ein normales Release.
  Das gilt zuerst für die Menüleiste (Schritt 0), später zum Beispiel für den Fingerabdruck-Extraktor.
- Arbeit an der Runtime geschieht in [myMartek/Klepton](https://github.com/myMartek/Klepton) (Branch `avp-play`),
  Arbeit an der Brillen-App in [myMartek/avp-play-remote](https://github.com/myMartek/avp-play-remote). Dort heißen
  die Branches genauso (`moonshot/<kennung>`), damit zusammengehörige Änderungen sich finden lassen.

## Schritt 0: AVP Play in der Menüleiste

**Branch:** `feat/menubar` · **Ziel:** eigenes Release, so bald wie möglich · **Herkunft:** Teil von `s4-appliance`

Der erste Schritt, weil er klein ist, sofort nützt und das Fundament für „Der Mac rückt in den Hintergrund“ legt.

Heute endet die App, sobald das letzte Fenster geschlossen wird (`applicationShouldTerminateAfterLastWindowClosed`
in `core/Sources/AVPPlayApp/App.swift` gibt `true` zurück). Damit endet auch der Server für die Fernsteuerung
(`RemoteServer`): Wer das Fenster schließt, verliert die Verbindung zur Brille.

Umfang:

- Ein Symbol in der Menüleiste (`MenuBarExtra`) mit:
  - laufendem Auftrag und Fortschritt, sonst „Keine Aufträge“,
  - Verbindungsstatus der Vision Pro und der Fernsteuerung,
  - Stand der automatischen Erneuerung (aus `RenewalReport`), etwa „Nächste Erneuerung in 3 Std.“,
  - „AVP Play öffnen“, „Neu prüfen“ und „Beenden“.
- Eine Einstellung **„In der Menüleiste weiterlaufen, wenn das Fenster geschlossen ist“**. Ist sie an, bleibt die
  App nach dem Schließen des Fensters aktiv, verschwindet aus dem Dock (`setActivationPolicy(.accessory)`) und kehrt
  beim Öffnen des Fensters dorthin zurück (`.regular`). Ist sie aus, bleibt alles wie heute.
- Optional eine Einstellung **„Bei der Anmeldung starten“** (`SMAppService.mainApp`), nur in der Menüleiste.
- Die Rückfrage beim Beenden mit laufendem Auftrag gilt auch für „Beenden“ in der Menüleiste.

Fertig, wenn: das Fenster geschlossen werden kann, ohne dass Aufträge oder die Fernsteuerung abbrechen; beide
Sprachen vorhanden sind; Tests für die Einstellungslogik existieren; die Snapshots des Menüs geprüft sind; und ein
Pull Request nach `main` offen ist.

## Die ausgewählten Punkte

### Säule 1: Klepton auf zwei Wirten

Die Runtime läuft zusätzlich auf dem Mac. Der Mac ist arm64 wie die Quest, und ANGLE und MoltenVK gibt es auch für
macOS. Diese Säule ist das Fundament für Säule 2.

| Kennung | Punkt | Baut auf | Fertig, wenn |
|---|---|---|---|
| `s1-mac-host` | **macOS-Fassung der Runtime.** Dieselbe Spiel-ABI und dieselben JNI-, OVR- und OpenXR-Shims, macOS als Wirt darunter. Ein Fix gilt für beide Wirte. | – | Ein verifiziertes Spiel startet auf dem Mac aus derselben Klepton-Quelle wie auf visionOS. |
| `s1-headless` | **Prüfstand ohne Headset.** Spiele laufen ohne Fenster: synthetische Kopf- und Controllerposen, Offscreen-Rendering, jeder N-te Frame wird gespeichert. | `s1-mac-host` | `avpplay lab run <spiel>` startet ein Spiel, spielt ein Eingabeskript ab und legt Log, Frames und Frame-Zeiten ab. |
| `s1-remote` | **Der Mac rendert, die Vision Pro zeigt an** (`RemoteImmersiveSpace`, macOS 26). Kein Signieren pro Spiel, kein Limit von 3 Apps und 7 Tagen, kein Headset-Speicher. Ein dritter Weg neben Installation und Fernsteuerung. | `s1-mac-host` | Ein verifiziertes Spiel ist so in der Brille spielbar, mit Controllern und gemessener Latenz. |
| `s1-debug` | **Fehlersuche auf dem Mac** mit lldb und Instruments statt über Logs vom Gerät. | `s1-mac-host` | Eine Anleitung in der Toolchain und ein Fix, der so gefunden wurde. |

### Säule 2: Ein Portierungslabor, das selbstständig arbeitet

Aus dem Handbuch in `core/Sources/AVPPlayApp/FixWithAI.swift` wird eine Maschine.

| Kennung | Punkt | Baut auf | Fertig, wenn |
|---|---|---|---|
| `s2-fingerprint` | **Kompatibilitäts-Fingerabdruck.** Lokale Analyse der APK: Engine, Grafik-API und Extensions, importierte OVR- und OpenXR-Funktionen, JNI-Aufrufe, Middleware. Nur Namen, kein Inhalt; Upload nur mit Zustimmung. | – | Der Extraktor liegt in `AVPPlayCore`, ist getestet und auf allen Spielen mit Rezept gelaufen. |
| `s2-coverage` | **Abdeckungskarte und Prognose vor dem Download.** Fingerabdruck gegen die Schnittstelle der Runtime: „Startet wahrscheinlich. Es fehlt `ovr_Voip_*`, ohne das geht der Chat nicht.“ | `s2-fingerprint` | Die Seite eines ungetesteten Spiels zeigt die Prognose und was fehlt. |
| `s2-unlock` | **Roadmap nach Unlock-Wert.** „Implementiere `ovr_Room_*` → 212 Spiele kommen eine Stufe weiter.“ | `s2-fingerprint` | Der Katalogdienst liefert eine sortierte Liste fehlender Funktionen mit der Zahl der betroffenen Spiele. |
| `s2-agent` | **Agentenschleife mit Eskalationsleiter.** Bauen, starten, beobachten, Hypothese, Patch in einer Sandbox, wiederholen. Reihenfolge: Konfiguration, allgemeiner Shim, Engine-Adapter, zuletzt Code für ein einzelnes Spiel. Ergebnis: PR gegen Klepton und Rezeptentwurf; ein Mensch prüft. | `s1-headless` | Der Agent bringt ein bisher ungetestetes Spiel ohne Hilfe ins Hauptmenü und öffnet den PR. |
| `s2-judge` | **Ein Vision-Modell beurteilt die Frames:** schwarz, nur ein Auge, verzerrt, Menü erreicht? Dazu ein Eingabeskript, das die ersten Minuten anspielt. | `s1-headless` | Auf den verifizierten Spielen stimmt das Urteil mit dem eines Menschen überein. |
| `s2-engines` | **Engine-Adapter für Unity und Unreal.** Targets werden aus dem Fingerabdruck generiert; ein Spiel braucht höchstens noch Abweichungen von der Engine-Vorgabe. | – | Ein neues Unity-Spiel läuft ohne eigenes Target. |
| `s2-nightshift` | **Die Nachtschicht.** Wer möchte, gibt seinen Mac nachts für Laborläufe frei, nur mit den eigenen Spielen. Den Mac verlassen nur Fingerabdrücke, Absturzsignaturen und Fixes. | `s2-agent` | Eine Einstellung schaltet es ein, die App zeigt, was lief und was geteilt wurde. |
| `s2-publicmap` | **Öffentliche Kompatibilitätskarte** im Stil von ProtonDB: welche Spiele laufen, was fehlt, woran gearbeitet wird. | `s2-coverage` | Die Seite ist öffentlich erreichbar und wird aus dem Katalogdienst gespeist. |

### Säule 3: Spatial Remaster

MetalFX und Foveation sind schon da. Gewählt sind die drei Punkte, die das Bild und die Steuerung verbessern.

| Kennung | Punkt | Baut auf | Fertig, wenn |
|---|---|---|---|
| `s3-framegen` | **Frame-Generierung aus AppSpaceWarp.** Bewegungsvektoren und Tiefe, die viele Spiele für Metas AppSW liefern, für temporales Hochskalieren und Zwischenbilder: 72 Hz werden zu 90 oder 100 Hz. | – | Ein Spiel mit AppSW läuft sichtbar flüssiger, abschaltbar im Startfenster. |
| `s3-textures` | **Neue Texturen, lokal erzeugt.** Beim Bauen rechnet der Mac die ASTC- und ETC2-Texturen mit einem ML-Modell hoch. Aus der eigenen Kopie, nur lokal, nie geteilt, abschaltbar. | – | Eine Option pro Spiel, die das beim Bauen tut; Vorher-nachher-Vergleich in der Doku. |
| `s3-hands` | **Handsteuerung für jedes Spiel.** Gesten werden zu Controllerzuständen, mit einem Geister-Controller in der Hand. Profile pro Spiel sind Daten, die Community teilt sie, umlegen geht in der Brille. | – | Zehn Spiele ohne eigene Handsteuerung sind mit den Händen spielbar und tragen den Filter „Hand Tracking“. |

### Säule 4: Der Mac rückt in den Hintergrund

| Kennung | Punkt | Baut auf | Fertig, wenn |
|---|---|---|---|
| `s4-appliance` | **Der Mac als unsichtbares Gerät.** Die Menüleiste ist Schritt 0. Danach: Wake-on-LAN aus der Brille (in AVP Play Remote) und die Erneuerung der Signaturen aus der Menüleiste steuern. Den Hintergrunddienst für die Erneuerung gibt es schon (`BackgroundService`, `RenewalAgent`). | Schritt 0 | Ein Mac im Ruhezustand lässt sich aus der Brille wecken, und ein Spiel startet, ohne dass jemand am Mac war. |
| `s4-library` | **Die Bibliothek im Raum.** AVP Play Remote wird zur Hauptoberfläche: Spiele stehen als Objekte im Regal im Wohnzimmer, ein Griff startet sie. | – | Die Bibliothek ist in AVP Play Remote als Raumansicht verfügbar. |
| `s4-streaming` | **Streaming-Speicher.** Ein virtuelles Dateisystem in Klepton lädt Daten erst bei Bedarf vom Mac, mit LRU-Cache auf dem Headset. Spielen nach den ersten 2 GB statt nach 70 GB. | – | Half-Life: Alyx startet, bevor alle Daten auf dem Headset liegen. |

### Die ersten 30 Tage

Die drei Spikes laufen parallel zu Schritt 0. Jeder liefert für sich eine Antwort, auch wenn der Rest später kommt.

| Kennung | Spike | Klärt |
|---|---|---|
| `d30-host` | Beat Saber ohne Headset auf dem Mac bis ins Hauptmenü, mit gespeicherten Frames. | Ob Säule 1 machbar ist. |
| `d30-fingerprint` | Fingerabdruck-Extraktor in `AVPPlayCore`, angewendet auf alle Spiele mit Rezept; daraus die erste Abdeckungsmatrix. | Welche Shims den größten Unlock-Wert haben. |
| `d30-remote` | Ein vom Mac gerenderter Würfel über `RemoteImmersiveSpace`, mit Handtracking und PS-VR2-Controllern in der Brille. | Ob das Limit von 3 Apps und 7 Tagen fallen kann (`s1-remote`). |

## Zeitplan

| Zeitraum | Schwerpunkt | Punkte |
|---|---|---|
| Monat 1 | Menüleiste ausliefern, Machbarkeit klären | Schritt 0, `d30-host`, `d30-fingerprint`, `d30-remote` |
| Monate 2 bis 3 | Fundament | `s1-mac-host`, `s1-headless`, `s1-debug`, `s2-fingerprint`, `s2-coverage` |
| Monate 4 bis 6 | Das Labor | `s2-agent`, `s2-judge`, `s2-engines`, `s2-unlock`, `s1-remote` (Beta) |
| Monate 7 bis 9 | Remaster und Streaming | `s3-framegen`, `s3-hands`, `s3-textures`, `s4-streaming`, `s2-nightshift` (Beta) |
| Monate 10 bis 12 | Skalierung und Erlebnis | `s4-library`, `s4-appliance`, `s2-publicmap`, 1.0 „Tag Eins“ |

## Woran der Erfolg gemessen wird

- **500+** spielbare Titel statt 49
- **Unter 48 Stunden** vom ersten Bericht „ungetestet“ bis „Community Verified“
- **Unter 30 Minuten** menschliche Arbeit pro neuem Spiel, im Wesentlichen das Review
- **Unter 60 Sekunden** vom Klick bis zum ersten Frame im Mac-gerenderten oder gestreamten Modus

## Risiken

1. **Recht und Plattformen.** Nutzungsbedingungen von Meta und Apple; Apple könnte Remote-Rendering oder den
   Developer-Weg einschränken. Gegenmittel: die Leitplanken ohne Ausnahme, rechtliche Beratung früh.
2. **Eingaben über Remote-Rendering** sind ungeklärt. Deshalb `d30-remote` im ersten Monat.
3. **Qualität und Sicherheit der Agenten-Patches.** Code, der auf fremden Macs läuft, braucht eine Sandbox,
   Review-Pflicht und eine signierte Toolchain.
4. **Ohne Regressionsnetz** (`s2-golden` ist nicht gewählt) fallen Fehler, die neue Shims in alten Spielen
   verursachen, erst bei Spielern auf. Sobald `s1-headless` steht, sollte das neu bewertet werden.
5. **Was nie gehen wird:** Kernel-Anti-Cheat und Spiele, die strikt an Metas Server gebunden sind. Sie werden
   ehrlich als „inkompatibel“ geführt.

## Nicht gewählt, für später

| Kennung | Punkt |
|---|---|
| `s2-golden` | Regressionsnetz mit Referenz-Frames bei jedem Toolchain-Commit |
| `s3-scene` | Metas Scene API auf ARKit-Szenenrekonstruktion abbilden |
| `s3-platform` | Plattform-Brücke zu GameKit, Game Center und SharePlay mit Spatial Personas |
| `s3-subtitles` | Live-Untertitel und Übersetzung per On-Device-Spracherkennung |
| `s3-a11y` | Sitzmodus, Einhandmodus und Drehen in Stufen über die Runtime |
| `s4-saves` | Spielstände mit Versionen wie in Time Machine |

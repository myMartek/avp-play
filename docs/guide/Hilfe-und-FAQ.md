🏠 [Übersicht / Overview](README.md) · 🇬🇧 [English version](Help-and-FAQ.md)

# Hilfe und FAQ

Hier stehen Probleme, die schon öfter vorgekommen sind – mit Lösungen zum Selbermachen. Wenn ein Auftrag stehen bleibt, schau zuerst in den Kasten **Woran es lag** unter **Aufträge**: Dort steht meist schon, was zu tun ist.

**Inhalt:** [Einrichtung und Apple-Konto](#einrichtung-und-apple-konto) · [Vision Pro verbinden](#vision-pro-verbinden) · [Laden, Meta und Steam](#laden-meta-und-steam) · [Spiel startet nicht oder läuft schlecht](#spiel-startet-nicht-oder-läuft-schlecht) · [Im Spiel](#im-spiel) · [Was nicht geht](#was-nicht-geht) · [Problem melden](#problem-melden)

---

## Einrichtung und Apple-Konto

### „Xcode findet kein Apple-Konto“ (No Accounts) – aber ich bin angemeldet
Xcode zeigt das Konto manchmal als angemeldet an, kann es aber nicht benutzen.
1. Xcode öffnen › **Einstellungen › Accounts**.
2. Das Konto **abmelden und wieder anmelden** (nur nachsehen reicht nicht).
3. In AVP Play beim Auftrag auf **Fortsetzen** klicken.

### „Xcode ist nicht mehr angemeldet“
Wie oben: in Xcode unter **Einstellungen › Accounts** neu anmelden, dann **Fortsetzen**.

### Geht das mit einem kostenlosen Apple-Konto?
Ja. Grenzen: Ein Spiel öffnet sich **7 Tage**, dann muss es neu signiert werden. Höchstens **3 Apps** deines Kontos gleichzeitig auf der Vision Pro (auch Apps, die du selbst mit Xcode installiert hast, zählen mit). Höchstens **10 neue Spiele pro Woche**. Ein sehr großes Spiel kann mit dem kostenlosen Konto am Speicher scheitern. Mehr unter [Einrichtung](Einrichtung.md#apple-konto-kostenlos-oder-bezahlt).

### Mein Spiel öffnet sich nach 7 Tagen nicht mehr
Das ist die Grenze des kostenlosen Apple-Kontos. Lösung: das Spiel in AVP Play noch einmal installieren (Spielstände bleiben). Bequemer: **Einstellungen › Signaturen erneuern** einschalten – dann macht die App das von selbst, solange die Vision Pro an und im selben WLAN ist.

### „Apple hat die Installation abgelehnt: … nur 3 Apps gleichzeitig“
Auf der Vision Pro eine App entfernen (Symbol gedrückt halten › **App entfernen**), dann **Fortsetzen**. Vorher die Spielstände sichern lassen (Spielseite › **Jetzt holen**) – das Entfernen löscht sie auf der Vision Pro.

### „… nur 10 neue Apps innerhalb von 7 Tagen“
Diese Grenze setzt Apple beim kostenlosen Konto. Warten, bis die älteste Anmeldung 7 Tage alt ist.

### Das Spiel ist installiert, öffnet sich aber nicht: „nicht vertrauenswürdiger Entwickler“
Auf der Vision Pro: **Einstellungen › Allgemein › VPN & Geräteverwaltung**, dein Apple-Konto wählen, **Vertrauen** antippen. Einmal pro Konto nötig.

### „Apple wartet darauf, dass du neue Bedingungen akzeptierst“
Auf [developer.apple.com/account](https://developer.apple.com/account) anmelden, die Vereinbarung bestätigen, dann **Fortsetzen**.

### „Die Kennung gehört schon einem anderen Entwicklerteam“
Das Spiel wurde früher mit einem anderen Apple-Konto installiert. In AVP Play unter **Einstellungen › Erweitert** ein anderes Präfix eintragen und neu installieren. Die Vision Pro sieht das Spiel dann als neue App.

### macOS fragt beim Bauen nach dem Passwort für den Schlüsselbund
Dein Mac-Passwort eingeben und mit der Maus auf **Immer erlauben** klicken.

---

## Vision Pro verbinden

### „Die Vision Pro ist nicht erreichbar“
Vision Pro einschalten, aufsetzen oder entsperren, im **selben WLAN** wie der Mac. Beim allerersten Mal muss sie mit Xcode gekoppelt werden – siehe [Einrichtung](Einrichtung.md#3-vision-pro-verbinden-einmalig).

### „Die Vision Pro ist gesperrt“
Aufsetzen, entsperren, **Fortsetzen**.

### Das Kopieren auf die Vision Pro ist langsam oder bricht ab
- Mit **USB-Kabel am Developer Strap** geht es viel schneller; die App nutzt das Kabel von selbst.
- Abbrüche passieren meist, weil die Vision Pro eingeschlafen ist. Wach halten, **Fortsetzen** – schon Kopiertes wird übersprungen.

### „… läuft gerade auf der Vision Pro. Eine Installation würde das Spiel beenden.“
Das Spiel auf der Vision Pro beenden (Digital Crown), dann **Fortsetzen**. Die App wartet absichtlich, damit dein Spielstand nicht verloren geht.

### „Das Spiel konnte nicht gestartet werden“ oder „nicht genug freier Platz auf der Vision Pro“
Meist ist der Speicher der Vision Pro voll. Auf der Vision Pro unter **Einstellungen › Allgemein › Speicher** nachsehen und Apps entfernen, die du nicht brauchst. Große Spiele brauchen ihre volle Größe noch einmal auf der Vision Pro (Asgard's Wrath 2 etwa 34 GB).

### Steam Link verbindet sich, aber das Bild kommt nicht
Steam Link braucht die Erlaubnis für das **lokale Netzwerk**. Die Vision Pro fragt beim ersten Öffnen danach – **Erlauben** antippen. Falls abgelehnt: **Einstellungen › Datenschutz & Sicherheit › Lokales Netzwerk** und Steam Link einschalten.

---

## Laden, Meta und Steam

### „Meta liefert diese Datei nicht (HTTP 404)“
Bei Zusatzinhalten, die du nicht gekauft hast, überspringt die App die Datei und macht weiter. Bei den Hauptdateien versucht sie es von selbst noch einmal über Metas eigenes Werkzeug. Klappt beides nicht, steht der Grund im Auftrag.

### „Nicht im Besitz“, obwohl ich das Spiel gekauft habe
- Auf der Spielseite **Kauf prüfen** klicken – ein neuer Kauf braucht manchmal ein paar Minuten.
- Mit einem anderen Meta-Konto gekauft? Unter **Einrichtung** mit diesem Konto anmelden.
- Bei Steam gekauft? Steam anmelden und **Kauf prüfen** noch einmal.

### Meta lehnt die Anmeldung ab / „Bitte neu anmelden“
Unter **Einrichtung › Meta-Konto** neu anmelden, dann **Fortsetzen**.

### macOS blockiert Metas Werkzeug „ovr-platform-util“
**Systemeinstellungen › Datenschutz & Sicherheit**, nach unten scrollen, bei *ovr-platform-util* **Dennoch öffnen** klicken. In der App **Noch einmal**.

### Steam-Anmeldung: „Bad CPU type“ oder Hinweis auf Rosetta
Valve liefert SteamCMD nur für Intel-Macs. Unter **Einrichtung › Steam-Konto** auf **Rosetta installieren** klicken (oder im Terminal `softwareupdate --install-rosetta --agree-to-license`), dann AVP Play neu öffnen.

### „Das sieht nicht nach einem Steam-Kontonamen aus“
Gemeint ist der Name, mit dem du dich bei Steam **anmeldest** – nicht dein Profilname.

### Ich habe neue Song-Pakete / DLCs gekauft
Spielseite › **DLCs abgleichen**. Danach das Spiel neu starten.

### Auf meinem Mac ist kein Platz mehr
- **Datenverwaltung**: alte oder nicht mehr gebrauchte Downloads entfernen.
- **Datenverwaltung › Ordner für Downloads › Ändern …**: auf eine externe Festplatte umziehen.
- **Einstellungen › Toolchains**: automatisches Aufräumen eingeschaltet lassen.

### Kann ich schon laden, bevor alles eingerichtet ist?
Ja: **Nur herunterladen** auf der Spielseite braucht nur das Konto, mit dem das Spiel gekauft wurde.

### Meine selbst reparierte Fassung ist nach einem Update weg
Auf der Spielseite unter **Toolchain** das Spiel auf deiner Toolchain festhalten.

---

## Spiel startet nicht oder läuft schlecht

### Ein ungetestetes Spiel bleibt schwarz, schließt sich oder zeigt keinen Text
Jedes geprüfte Spiel brauchte eigene Anpassungen – ungetestete Spiele laufen deshalb oft nicht. Seit 1.3.0 bekommen ungetestete Spiele etwas sicherere Grundeinstellungen; trotzdem gilt: Ausprobieren ist ein Versuch. Was du tun kannst:
- Unter **Wie läuft es?** melden, was passiert – das hilft allen.
- **Mit KI reparieren …** ausprobieren (siehe [Spielseite](Spielseite.md#mit-ki-reparieren)).
- Ein Problem auf GitHub melden (siehe unten).

### Der erste Start dauert sehr lange („Grafik wird vorbereitet“)
Normal. Beim ersten Start übersetzt das Spiel seine Grafik – das kann einige Minuten dauern. Danach geht es schnell.

### Das Spiel ruckelt beim ersten Besuch eines Levels
Beim ersten Mal wird jede neue Grafik übersetzt. Beim nächsten Besuch ist es flüssig. Bei Batman: Arkham Shadow und Moss passiert das inzwischen im Hintergrund (in den Einstellungen unter **Erweitert › Test** ein- und ausschaltbar).

### Die Bildrate fällt auf 50 (oder 60)
Die Vision Pro halbiert die Bildrate, wenn ein Spiel nicht mitkommt. Probiere:
- **Bildrate: Bis 100** (Standard) lassen.
- **Auflösung** senken und **MetalFX** einschalten (direkt unter der Auflösung).
- Unter **Erweitert** die **Ausgabe aufs Display** auf *Leicht* stellen.
- **Foveated Rendering** auf *Stark* oder *Sehr stark*.
- Bei Half-Life: Alyx die Grafik-Voreinstellung *Flüssig* oder *Ausgewogen*.

Die [Leistungsanzeige](Steuerung.md#leistungsanzeige) zeigt, woran es liegt.

### Nach einem Update schließt sich ein Spiel gleich beim Start
Das war ein Fehler in einer älteren Version. AVP Play aktualisieren und das Spiel über **Aktualisieren** neu bauen. Der erste Start danach dauert etwas länger.

### Marvel's Deadpool VR hängt im Ladebildschirm
Kommt selten vor. Spiel beenden und neu starten – meist geht es dann. Wenn es öfter passiert: In den Einstellungen des Spiels **Erweitert › Diagnose › Aufzeichnen, worauf das Spiel wartet** einschalten und das Protokoll mit einer Meldung schicken.

### Asgard's Wrath 2 wird nach dem Shader-Bildschirm schwarz
Mit aktueller Toolchain bleibt der Bildschirm „Shader werden übersetzt“ stehen, bis alles fertig ist – beim ersten Start mehrere Minuten. Einfach laufen lassen.

---

## Im Spiel

### Wie beende ich ein Spiel? Es gibt keine Home-Taste
**Digital Crown** drücken. Das Spiel beendet sich kurz darauf. Es gibt kein Pausieren im Hintergrund – jeder Start ist ein Neustart.

### Der Raum wird beim Start nicht erkannt
Kurz umsehen, damit das Spiel genug vom Raum sieht. Nach 8 Sekunden fragt eine Karte: **Raum vermessen** oder **Stationär / sitzend**. In einem neuen Raum einfach neu vermessen. Mehr unter [Spielbereich](Spielbereich.md).

### Ich will ohne Spielbereich spielen
Im Startfenster **Einstellungen › Spielbereich** ausschalten – oder in AVP Play unter **Einstellungen › Spielbereich** für alle neuen Spiele. Siehe [Spielbereich](Spielbereich.md#ausschalten).

### „Zum Vermessen braucht das Spiel die Erlaubnis, die Umgebung zu erfassen“
Auf der Vision Pro: **Einstellungen › Datenschutz & Sicherheit › Umgebung** und das Spiel erlauben.

### Walkabout: Andere hören mich nicht
In den Einstellungen des Spiels **Mikrofon** einschalten und die Frage der Vision Pro erlauben.

### Demeo zeigt einen allgemeinen Spielernamen
Demeo kann sich nicht beim Konto des Herstellers anmelden und spielt mit einem lokalen Spieler. Den Namen legst du in den Einstellungen unter **Spielername** fest.

### Half-Life: Alyx – wo melde ich mich für die Steam Cloud an?
Im Spiel auf der Vision Pro: **Einstellungen › Steam Cloud**. Steam-Kontoname und Passwort eingeben und in der Steam-App auf dem Handy bestätigen.

### Sind meine Spielstände sicher?
AVP Play holt die Spielstände von selbst auf den Mac (nach jedem Spiel und alle paar Stunden). Beim Neuinstallieren kommen sie automatisch zurück, wenn auf der Vision Pro keine sind. Achtung: Wer eine App auf der Vision Pro entfernt, löscht dort ihre Spielstände – die Kopien auf dem Mac bleiben. Half-Life: Alyx nutzt die Steam Cloud.

---

## Was nicht geht

- **32-Bit-Spiele** (z. B. République VR): Der Chip der Vision Pro kann kein 32-Bit. Nicht lösbar.
- **2D-Apps** wie Spotify, WhatsApp oder YouTube: AVP Play ist nur für VR-Spiele.
- **Pausieren im Hintergrund**: Jeder Start ist ein Neustart.
- **Mixed Reality** nur bei den Spielen, die dafür eingerichtet sind (Filter *Mixed Reality*).
- Spiele mit dem Etikett **Inkompatibel**: Auf der Spielseite steht, warum.

---

## Problem melden

1. In AVP Play: **Hilfe › Ein Problem melden …** – oder im angehaltenen Auftrag **Dieses Problem melden …**.
2. **Kopieren und GitHub öffnen** klicken und den Bericht in ein neues Issue einfügen.

Der Bericht enthält keine Namen, Konten, Gerätekennungen oder Ordnerpfade. Die App schickt selbst nichts.

Für Probleme im Spiel hilft das Protokoll von der Vision Pro: Startfenster › **Einstellungen › Erweitert › Diagnose › Protokoll weitergeben**.

👉 [Issues auf GitHub](https://github.com/myMartek/avp-play/issues)

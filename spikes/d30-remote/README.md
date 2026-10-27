# Spike d30-remote: der Mac rendert, die Vision Pro zeigt

Teil von [`moonshot.md`](../../moonshot.md) (`d30-remote`, Vorarbeit für `s1-remote`). Eine kleine Mac-App öffnet
mit `RemoteImmersiveSpace` (macOS 26) einen Raum in der gekoppelten Vision Pro und rendert dort mit Metal einen
Würfel. Sie liest die Kopfposition der Brille über `ARKitSession(device:)` und zählt Pinch-Ereignisse.

## Was das SDK schon vorher sagt (macOS 27 SDK, Xcode 27)

| Aus der Brille auf dem Mac | verfügbar? | Beleg |
|---|---|---|
| Bild in die Brille (Compositor Services, Metal) | ja | `RemoteImmersiveSpace`, `CompositorLayer` (macOS 26) |
| Kopfposition | ja | `WorldTrackingProvider` (`macOS 26.0`) |
| Schauen + Pinch (Strahl, Handpose beim Pinch, Hand) | ja | `LayerRenderer.onSpatialEvent`, `SpatialEventCollection.Event` |
| Handskelett (alle Gelenke) | **nein** | `HandTrackingProvider`: `@available(macOS, unavailable)` |
| PS-VR2-Controller im Raum | **nein** | `AccessoryTrackingProvider`, `Accessory`: `@available(macOS, unavailable)` |
| Direkter Pinch (Hand berührt Objekt) | nein | `SpatialEventCollection.Event.Kind.directPinch` auf macOS nicht verfügbar |

Folge für `s1-remote`: Spiele mit Controllern brauchen eine kleine Gegenstelle **auf der Brille**, die Controller
(GameController + `AccessoryTrackingProvider`) und Hände (`HandTrackingProvider`) liest und an den Mac schickt –
etwa als Teil von AVP Play Remote. Das Bild selbst kann der Mac liefern, ohne Signieren pro Spiel und ohne
Headset-Speicher.

## Bauen und starten

```bash
cd spikes/d30-remote
./make-app.sh
open .build/D30Remote.app
```

Vorher: die Vision Pro mit dem Mac koppeln (wie für „Mac Virtual Display“) und die Brille aufsetzen.

## Erster Test in der Brille (27.10.)

- Würfel erscheint, steht fest im Raum, Kopfposition läuft. Erst war er verzerrt und wirkte ganz nah: die Foveation-
  Karte fehlte im Render-Durchgang (behoben). Die Krone ließ die Mac-App abstürzen: `endSubmission` ohne Ziel
  (behoben).
- PS-VR2-Controller: der Mac sieht nichts davon (wie nach SDK erwartet).
- **Offen:** schwarze Kacheln am Rand des Würfels, obwohl durchsichtig gelöscht wird. Auf der Brille selbst hat das
  Löschen mit Alpha 0 dasselbe Bild bei Triangle Strategy behoben (Klepton `6c8b7c3`); beim Bild vom Mac geht das
  Alpha vermutlich unterwegs verloren, und der Raum erscheint nur in Kacheln ganz ohne Tiefe. Zum Eingrenzen gibt es
  im Fenster „Voll (ohne Raum)“ und „Farbe 16 Bit mit Alpha“.
- Auf macOS gibt es für `RemoteImmersiveSpace` nur `.progressive` (Krone, Raum sichtbar) und `.full`; `.mixed` ist
  dort nicht verfügbar.

## Was zu prüfen ist (nur mit Mac und Vision Pro)

- [x] „In der Vision Pro öffnen“ zeigt in der Brille einen farbigen Würfel etwa 1 m vor dir, der sich dreht und
      beim Kopfdrehen im Raum stehen bleibt.
- [ ] Im Fenster auf dem Mac: „Kopfposition“ zählt hoch (verfolgt), „Bildabstand“ (Ziel 11 ms bei 90 Hz bzw.
      10 ms bei 100 Hz), „Vorlauf bis zur Anzeige“ (wie weit vor der Anzeige der Mac das Bild abgibt).
- [ ] Pinch (Daumen und Zeigefinger) zählt „Pinch-Ereignisse“ hoch; „Letztes Ereignis“ zeigt Hand und Position.
- [ ] Gefühlte Latenz beim schnellen Kopfdrehen: bleibt der Würfel ruhig?
- [x] Ein PS-VR2-Controller in der Brille: sieht der Mac irgendetwas davon? (Nein.)
- [ ] Schwarze Kacheln: mit „Farbe 16 Bit mit Alpha“ weg? Mit „Voll (ohne Raum)“ unsichtbar (schwarz auf schwarz)?

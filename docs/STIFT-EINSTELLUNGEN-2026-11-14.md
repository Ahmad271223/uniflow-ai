# Stift dünner, Einstellungen je Stift, eigene Stifte – 14.11.2026

Zweig `editor/stift-feiner` (von develop `1c2fd03a`). Kein Push, kein Merge.

## 1. Dünner (Commit `8ec41864`, für Build 42)

**Grenzen von PencilKit** (gemessen in `StiftStaerkeTests`):

| Werkzeug | Tinte | Grenzen (Seitenpunkte) |
|---|---|---|
| Stift | `.pen` | 0,88 bis 25,6 |
| Fineliner | `.monoline` | 0,5 bis 4 |
| Textmarker | `.marker` | ab 7,5 |

Bei Seitenbreite (iPad hochkant) ist 1 Seitenpunkt = 1,38 Bildschirmpunkte.

**Warum der Stift dicker wirkt:** Er wird breiter, je fester man drückt. Der Fineliner bleibt immer gleich breit.

**Neue Stufen:**
- Stift: 0,88 · 2 · 3,5 · 6 · 10
- Fineliner: 0,5 · 0,8 · 1,5 · 2,5 · 4
- Textmarker: 7,5 · 10 · 15 · 22 · 30

Zwei alte Stufen wirkten nicht:
- Fineliner 6 wurde still auf 4 begrenzt, gleich der Stufe davor.
- Textmarker 6 wurde still auf 7,5 angehoben.

Gespeicherte Werte außerhalb der Grenzen fallen beim Laden auf den nächsten gültigen Wert.

**Simulator:** Er zeichnet Striche unter etwa 2 Punkten gar nicht. Bilder der feinen Stufen gibt es deshalb nur am
iPad.

## 2. Einstellungen je Stift

Erreichbar über das Feld „Farbe und Stärke“ → „Einstellungen …“. Das Blatt erscheint im selben Feld, nicht als
zweites Blatt; das ist am Mac sicher.

- **Art des Stifts erklärt:**
  - Stift: „Wird breiter, je fester du aufdrückst“.
  - Fineliner: „Fein und immer gleich breit – am besten für kleine Schrift“.
  - Beim dünnsten Stift erscheint ein Hinweis mit Knopf „Zum Fineliner“.
- **Stärke stufenlos:** Schieber, dazu „−“/„+“ in feinen Schritten (unter 2: 0,1 · bis 6: 0,25 · darüber 1) und die
  Zahl. Immer innerhalb der Grenzen von PencilKit.
- **Deckkraft:** 10 bis 100 %. Geht in die Tinte und bleibt beim Sichern, im Browser und auf dem iPhone erhalten.
- **Glättung als Stufenregler** Aus · Leicht · Normal (gilt für alle Stifte dieses iPads).
- **Vorschau:** Probestrich in Farbe, Stärke und Deckkraft, so groß wie bei Seitenbreite.
- **„Zurücksetzen“** stellt den Stift auf den ersten Start zurück.
- VoiceOver: Stärke und Glättung lassen sich je Wischen um einen Schritt verstellen.

**Bewusst weggelassen – Linienart gepunktet/gestrichelt:** PencilKit kennt keine Strichmuster. Man müsste jeden
Strich beim Absetzen in viele Einzelstriche zerlegen. Dann sähe er beim Schreiben anders aus als danach, der Radierer
nähme einzelne Stücke, und im Abgleich mit Browser und iPhone wären es viele Striche statt einer.

## 3. Eigene Stifte

- „Als eigenen Stift merken“ speichert Werkzeug, Farbe, Stärke und Deckkraft. Bis zu 8 Stifte, je Gerät.
- Sie stehen in der Werkzeugleiste zwischen den Stiften und dem Lineal, als Farbpunkt mit Strich in ihrer Stärke.
- Antippen nimmt den Stift. Entfernen geht über langes Drücken oder im Blatt über den Papierkorb.
- In der schwebenden Palette (Apples Palette) erscheinen sie nicht.

## Vorschlag, nicht umgesetzt

**Standard für neue Nutzer:** Fineliner 0,8 als erster Schreibstift statt Stift 2. Das ist feiner und unabhängig vom
Druck. Dafür ist die Zustimmung des Inhabers nötig.

**Befund – Fineliner wird beim Speichern zum Stift:** PencilKits eigenes Speicherformat liefert einen
Fineliner-Strich (`.monoline`) als Stift (`.pen`) zurück. Im JSON steht `pkInk` richtig.
- Gespeicherte Fineliner-Striche erscheinen nach dem Neuladen also als Stift. Gesehen im Simulator, am iPad nicht
  geprüft.
- Behebung wäre: beim Laden die Tinte aus `pkInk` wiederherstellen.
- Das ändert das Aussehen bereits gespeicherter Notizen; es wäre wieder das ursprüngliche Aussehen. Darum hier nicht
  geändert.

## Tests (einzelne Klassen; volle Suite erst nach Entwarnung)

- `PenSettingsTests` (6):
  - alte Stärken fallen auf gültige;
  - Schritte und Zahlen;
  - Deckkraft in Tinte und JSON;
  - eigene Stifte anlegen, nehmen, entfernen, nach Neustart da;
  - das Blatt mit Hinweis, Fineliner, Glättung und Zurücksetzen;
  - Leiste mit eigenen Stiften.
- `StiftStaerkeTests` (4): Grenzen; jede Stufe in den Grenzen und verschieden; feine, halbdurchsichtige Striche mit
  Rückgängig, Radierer, Lasso, Sichern und Neuladen; Bild-Szenario.
- Grün: `EditorToolbarTests`, `EditorVerbesserungTests`, `DocumentTabsHeaderAppTests`, `ViewTypeDepthAppTests`,
  `UndoStrokesAppTests`, `PencilSmoothingTests`.

Bilder des Blatts: `~/Studora-Builds/stift/blatt/`.

## Nachtrag 17.11.2026 – feiner, Füller, Textmarker (Zweig `editor/leiste-stifte-17-11`)

Gemessen mit echten Strichen im Simulator (iPadOS 27.2, gleichmäßiger Druck; 1 pt = 0,353 mm):

| Werkzeug | Stufen | gezeichnet |
|---|---|---|
| Stift | 0,88 · 2 · 3,5 · 6 · 10 | 0,88 und 2 zeichnen beide rund 2,2 pt (0,8 mm); dünner kann diese Tinte nicht |
| Fineliner | **0,25 · 0,35** · 0,5 · 0,8 · 1,5 · 2,5 · 4 | das Doppelte der Zahl: 0,5 pt (0,18 mm) · 0,7 pt (0,25 mm) · 1,0 pt (0,35 mm) … |
| Füller (neu) | 1 · 1,5 · 2,5 · 4 · 6,5 | Grundstrich rund ein Drittel der Zahl: 0,32 · 0,48 · 0,8 · 1,3 · 2,0 pt; mit Druck kräftiger |
| Textmarker | 7,5 · 10 · 15 · 22 · 30 | etwa die Zahl (15 → 14 pt), je nach Haltung des Stifts schmaler |

- Die feinen Fineliner-Stufen sind fester Bestandteil; der Schieber reicht bis 0,18. Unter 0,25 wird der Strich bei
  100 % Zoom nicht mehr dünner, nur blasser (weniger als ein Bildpunkt des iPad).
- Fineliner und Füller nehmen dünnere Breiten an, als PencilKit meldet (`EditorToolState.inkLimits`). Alles wirkt
  schon während des Strichs; nach dem Absetzen wird nichts ersetzt.
- Der Füller ist ein eigenes Werkzeug (Tinte `fountainPen`); im Speicherformat steht `tool: "fountain"` – so liest
  und schreibt es schon die Store-Version 1.0.4 und der Browser.
- Textmarker: ohne eigene Einstellung jetzt 50 % Deckkraft. Mit 100 % legte PencilKit ihn fast deckend über den Text.
- Vorgabe für neue Nutzer mit einer Zeile umstellbar: `EditorToolState.firstStart` (`.classic` wie bisher, `.fine`
  = Fineliner schwarz 0,5 als erster Stift).

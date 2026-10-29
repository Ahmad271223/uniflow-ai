# Messung PDF-Editor im Simulator (Schritt 1)

Stand 28.10.2026 · Zweig `wip/editor-1` (mit `origin/develop` ad5df7f zusammengeführt) · Plan:
`docs/PENCILKIT-ANALYSE-PLAN.md` (P0-2, Abschnitt 7) · Abnahmeliste für das Gerät: `docs/EDITOR-ABNAHME.md`.

Gemessen wurde nur im **Simulator**. Am Editor wurde nichts geändert; neu ist nur der Messtest
`apps/apple/UniFlowTests/EditorScaleTests.swift`. Schritte meint die Reihenfolge des Inhabers:
1 Abnahmeliste und Messung · 2 Härtungen · 3 Drehen ohne Verrutschen · 4 Speicherlast · 5 Seitenwerkzeuge ·
6 Objekt-Werkzeuge.

## 1. Kurzfassung

Gemessen unter wechselnder, oft hoher Last des Macs (Lastmittel 40–600 auf 8 Kernen, siehe Abschnitt 2); Zeiten sind darum
Obergrenzen, Größen und Zählwerte sind genau. Die drei Läufe stimmen gut überein, auch der Lauf mit der niedrigsten
Last (V2) ist kaum schneller.

| Bereich | Ergebnis im Simulator | Bewertung |
|---|---|---|
| Große PDFs (100 / 250 / 500 Seiten) | Öffnen ≤ 0,06 s, erste Seite ≤ 0,2 s, Blättern bis zum Ende ohne Hänger; nach dem Blättern leben immer 10 Overlays und 10 Canvas, egal wie viele Seiten; Speicher wächst nicht mit der Seitenzahl | gut (M8) |
| Seite drehen / Leerseite bei 500 Seiten | 0,12–0,16 s bis die Seite wieder geladen ist (in einem weiteren Lauf einmal 0,63 s) | gut (M10) |
| Schreiben | Umrechnung einer vollen Seite (300 Striche) nach einem Strich 0,05–0,09 s, im Hintergrund; Hauptthread während Umrechnung und Speicherrunden meist nur 2–6 ms am Stück belegt | gut (M7) |
| Rückgängig über Seiten | auch für Seiten ohne Overlay und für eine volle Seite: richtiger Stand, Sprung zur Seite, je Schritt unter 0,06 s; nach erneutem Öffnen gespeichert | gut (M9) |
| **Speicherrunde** | schickt immer das ganze Dokument (rund 1,5 KB je Strich): 6 000 Striche 3–4,4 s, 15 000 Striche 7–14 s, 30 000 Striche 13–16 s; über 80 % davon im lokalen Backend, das den Text zweimal liest | **zu langsam** (M1, Schritt 4) |
| **Versionsverlauf** | jede Runde legt eine volle Kopie ab; 100 dichte Seiten: Datenbank nach drei Runden 221 MB, mit 30 Versionen hochgerechnet über 1,3 GB für ein Dokument | **zu groß** (M2, Schritt 4) |
| Speicherspitze | während einer Runde mit 30 000 Strichen 410–600 MB; beim schnellen Blättern über volle Seiten 530–590 MB | am Gerät prüfen (M1, M4) |
| Erneut öffnen eines dichten Dokuments | 15 000 Striche: 6–9 s, davon 4,3–5,7 s das Lesen des gespeicherten Stands; Oberfläche bleibt bedienbar | langsam (M3, Schritt 4) |
| Schnelles Blättern über volle Seiten | Striche erscheinen verzögert (Median 0,23–2,7 s, bis 2,8 s), weil auch schon weggescrollte Seiten fertig geladen werden | verbesserbar (M4, Schritt 4) |
| Zoom-Schärfe | im Simulator wird die Tinte beim Zoomen nicht neu gezeichnet (Kante 0,5 → 5 px), die PDF schon (1 px) | am Gerät prüfen (M5) |
| Gemischte Formate | eine A0-Seite im Dokument macht alle A4-Seiten winzig (147 statt 830 pt breit), Zoom reicht dann nur bis etwa Fensterbreite | Mangel (M6, Schritt 5) |

Ein Fehler, der sofort behoben werden musste, wurde nicht gefunden; am Editor ist nichts geändert. Pencil-Latenz,
Handballen und echter Speicherdruck sind im Simulator nicht messbar (Abschnitt 6) – dafür ist die Abnahmeliste am
Gerät da.

## 2. Rahmen

| Angabe | Wert |
|---|---|
| Datum | 28.10.2026, 01:40–03:25 Uhr |
| Rechner | Mac mit Apple M3 (8 Kerne), 16 GB, macOS 27.0.1, Xcode 27.1 (27A9275) |
| Simulator | iPad Pro 11 Zoll (M5, 12 GB), iOS 27.0 (24A434), Fenster 834 × 1210 pt, Bildschirmfaktor 2 |
| Last | **hoch und wechselnd**: auf demselben Mac liefen gleichzeitig zwei weitere Simulatoren anderer Sitzungen und weitere Builds. Lastmittel (1 min) während der Messungen 40–600 bei 8 Kernen (E 500–600, V1 85–195, V2 40–200), Werte je Test in Abschnitt 3. Gestartet wurde jeder Lauf erst bei einem Lastmittel unter 300; danach stieg es durch die anderen Sitzungen zeitweise wieder |
| Läufe | E = Einzellauf nur `EditorScaleTests` (Stand vor dem Zusammenführen; Editor-Code identisch) · V1, V2 = zwei volle Läufe aller App-Tests direkt nacheinander auf dem Endstand. Dazu ein Probelauf und drei volle Läufe auf Zwischenständen (einer auf develop a7c2e81, zwei auf 7d4d9ca); ihre Werte liegen im selben Bereich, Ausreißer stehen im Text |

**Testergebnis der Läufe.** E: 9 Tests, 1 übersprungen (200 Seiten nur auf Anforderung), alle anderen grün.
V1: 493 App-Tests, 2 übersprungen, alle `EditorScaleTests` grün; abgestürzt ist
`StudyPlanLocalAppTests.testAddPackageViaDialogCheckOffAndDashboard` (Ausnahme im Fokus-System von UIKit beim Schließen
eines Dialogs). Dieser Test war auch in einem Lauf einer anderen Sitzung ohne die `EditorScaleTests` rot und lief danach
hier fünfmal allein und einmal direkt nach den `EditorScaleTests` grün. V2: 493 App-Tests, 2 übersprungen, alle grün.

**Methode.** Der Test geht den echten Weg der App: `DocumentStore` mit dem lokalen Backend (SQLite) in einem
Temp-Ordner, Kurs und Datei wie nach dem ersten Öffnen aus Stud.IP angemeldet, `PDFEditorController` als Inhalt eines
eigenen Fensters in Bildschirmgröße. PDFKit setzt die Seiten-Overlays (`PDFPageOverlayViewProvider`, je sichtbarer
Seite ein `PKCanvasView`) selbst ein, so wie in der App. Alle Daten sind erfunden: PDFs aus `UIGraphicsPDFRenderer`
(A4, Titel, 14 Textzeilen, Vektordiagramm, jede dritte Seite ein Foto), Handschrift mit festem Startwert (je Strich
14–24 Punkte, wechselnder Druck, meist Stift, jeder 9. Bleistift, jeder 15. Textmarker).

| Größe | Wie gemessen |
|---|---|
| Zeit | `DispatchTime` (monoton) |
| Speicher | `phys_footprint` aus `task_info` (dieselbe Zahl wie „Memory“ in Xcode), Spitze alle 5 ms auf eigenem Thread |
| Hauptthread | ein Task auf dem MainActor schläft je 10 ms; was darüber hinausgeht, war der Hauptthread belegt (oder der Mac ausgelastet). Arbeit des Tests selbst (Testdaten, Auswertung) ist ausgenommen |
| Blättern | Scroll-Ansicht der PDFView je 16 ms um eine Viertel-Fensterhöhe (etwa 13 Seiten/s, gibt die Dauer vor) |
| Freigabe | schwache Verweise auf jedes je angelegte Overlay und seine Canvas; gezählt wird, was nach dem Blättern noch lebt |
| Speicherrunde | ein Strich mehr auf Seite 1, dann `DocumentStore.pause()`: genau eine Runde (`PUT` des ganzen Dokuments ans lokale Backend, das Stand und Versionskopie schreibt) |
| Zoom-Schärfe | Bild des Fensters (`drawHierarchy`), Breite der Kante einer 2-pt-PDF-Linie und eines Tintenstrichs (Pixel zwischen 15 und 85 % Helligkeit, Median über 15 Spalten) |

**Grenzen im Test.** Zeiten hängen an der Last. Zeitgrenzen im Test sind deshalb nur Hänger-Grenzen, mindestens
zehnfach über den Werten unter dieser Last (Ausnahme: das Zeitlimit fürs durchgehende Blättern liegt beim 5- bis
16-fachen, weil dort der feste Takt des Tests die Dauer vorgibt – 500 Seiten mindestens 31 s – und sie sich mit der Last
kaum ändert); hart geprüft wird, was nicht von der Last abhängt (alle Seiten erreicht,
Overlays und Canvas freigegeben, Striche vollständig, Stand nach dem erneuten Öffnen). Es gibt keinen Test nach Art von
`testManyForeignLayersStayFastAndAreReleased` (Plan B12).

## 3. Messwerte

Zeiten in Sekunden, Speicher in MB (`phys_footprint` des ganzen Testprozesses; alle Tests laufen im selben Prozess,
darum ist der Ausgangswert je Test verschieden).

### 3.1 Öffnen und Blättern (100, 250, 500 Seiten)

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 509–504 | 115–109 | 83–75 |
| 100 S.: Öffnen (`DocumentStore.load`), s | 0,01 | 0,01 | 0,01 |
| 100 S.: Editor bis erste Seite geladen, s | 0,14 | 0,16 | 0,20 |
| 100 S.: Blättern bis zum Ende, s | 7,3 | 7,4 | 7,3 |
| 100 S.: Seiten mit Overlay | 100 | 100 | 100 |
| 100 S.: Overlays noch lebendig danach | 10 | 10 | 10 |
| 100 S.: Canvas noch lebendig danach | 10 | 10 | 10 |
| 100 S.: Speicher Spitze beim Blättern, MB | 274 | 322 | 322 |
| 100 S.: Speicher nach dem Blättern, MB | 258 | 313 | 300 |
| 100 S.: Zuwachs durch Blättern, MB | 112 | 120 | 108 |
| 100 S.: Hauptthread beim Blättern, längster Block, ms | 8 | 13 | 10 |
| Lastmittel (1 min) bei Beginn–Ende | 504–505 | 109–90 | 75–62 |
| 250 S.: Öffnen (`DocumentStore.load`), s | 0,04 | 0,04 | 0,04 |
| 250 S.: Editor bis erste Seite geladen, s | 0,05 | 0,05 | 0,08 |
| 250 S.: Blättern bis zum Ende, s | 18,4 | 18,5 | 18,4 |
| 250 S.: Seiten mit Overlay | 250 | 250 | 250 |
| 250 S.: Overlays noch lebendig danach | 10 | 10 | 10 |
| 250 S.: Canvas noch lebendig danach | 10 | 10 | 10 |
| 250 S.: Speicher Spitze beim Blättern, MB | 290 | 337 | 335 |
| 250 S.: Speicher nach dem Blättern, MB | 232 | 278 | 275 |
| 250 S.: Zuwachs durch Blättern, MB | -18,3 | -18,5 | -22,1 |
| 250 S.: Hauptthread beim Blättern, längster Block, ms | 17 | 19 | 18 |
| Lastmittel (1 min) bei Beginn–Ende | 505–548 | 90–85 | 62–42 |
| 500 S.: Öffnen (`DocumentStore.load`), s | 0,05 | 0,06 | 0,05 |
| 500 S.: Editor bis erste Seite geladen, s | 0,07 | 0,09 | 0,08 |
| 500 S.: Blättern bis zum Ende, s | 36,9 | 37,0 | 36,9 |
| 500 S.: Seiten mit Overlay | 500 | 500 | 500 |
| 500 S.: Overlays noch lebendig danach | 10 | 10 | 10 |
| 500 S.: Canvas noch lebendig danach | 10 | 10 | 10 |
| 500 S.: Speicher Spitze beim Blättern, MB | 280 | 315 | 315 |
| 500 S.: Speicher nach dem Blättern, MB | 260 | 293 | 296 |
| 500 S.: Zuwachs durch Blättern, MB | 26,5 | 17,6 | 14,5 |
| 500 S.: Hauptthread beim Blättern, längster Block, ms | 12 | 14 | 11 |
| 500 S.: Seite drehen bis wieder geladen, s | 0,12 | 0,14 | 0,14 |
| 500 S.: Leerseite einfügen bis geladen, s | 0,13 | 0,16 | 0,15 |
| 500 S.: Hauptthread beim Drehen, längster Block, ms | 92 | 104 | 101 |

### 3.2 Dichtes Skript: Umrechnen, Journal, Speicherrunde (je Seite 300 Striche)

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 521–513 | 193–120 | 140–83 |
| Umrechnung + Journal je volle Seite, s | 0,07 | 0,07 | 0,09 |
| 20 S.: ein Strich mehr auf voller Seite (Umrechnung + Journal), s | 0,05 | 0,05 | 0,07 |
| 20 S.: Striche im Dokument | 6001 | 6001 | 6001 |
| 20 S.: Dokument einer Runde (JSON), MB | 8,7 | 8,7 | 8,7 |
| 20 S.: davon `pkdrawing` (Base64), MB | 4,2 | 4,2 | 4,2 |
| 20 S.: Journal auf der Platte, MB | 8,7 | 8,7 | 8,7 |
| 20 S.: **eine Speicherrunde, s** | 3,3 | 3,0 | 4,4 |
| 20 S.: Hauptthread während der Runde, längster Block, ms | 2 | 2 | 3 |
| 20 S.: Speicher Spitze während der Runde, MB | – | 174 | 180 |
| 20 S.: Datenbank-Datei, MB | – | 19,0 | 19,0 |
| 20 S.: Datenbank-WAL, MB | – | 19,2 | 19,2 |
| 20 S.: Versionen im Verlauf (Anzahl) | 1 | 1 | 1 |
| 20 S.: Versionen zusammen, MB | 9,4 | 9,4 | 9,4 |
| 50 S.: ein Strich mehr auf voller Seite (Umrechnung + Journal), s | 0,07 | 0,07 | 0,09 |
| 50 S.: Striche im Dokument | 15002 | 15002 | 15002 |
| 50 S.: Dokument einer Runde (JSON), MB | 21,8 | 21,8 | 21,8 |
| 50 S.: davon `pkdrawing` (Base64), MB | 10,4 | 10,4 | 10,4 |
| 50 S.: Journal auf der Platte, MB | 21,8 | 21,8 | 21,8 |
| 50 S.: **eine Speicherrunde, s** | 7,7 | 6,9 | 9,8 |
| 50 S.: Hauptthread während der Runde, längster Block, ms | 2 | 2 | 3 |
| 50 S.: Speicher Spitze während der Runde, MB | – | 273 | 271 |
| 50 S.: Datenbank-Datei, MB | – | 56,6 | 56,6 |
| 50 S.: Datenbank-WAL, MB | – | 47,2 | 47,2 |
| 50 S.: Versionen im Verlauf (Anzahl) | 2 | 2 | 2 |
| 50 S.: Versionen zusammen, MB | 32,8 | 32,8 | 32,8 |
| 100 S.: ein Strich mehr auf voller Seite (Umrechnung + Journal), s | 0,07 | 0,06 | 0,06 |
| 100 S.: Striche im Dokument | 30003 | 30003 | 30003 |
| 100 S.: Dokument einer Runde (JSON), MB | 43,5 | 43,5 | 43,5 |
| 100 S.: davon `pkdrawing` (Base64), MB | 20,9 | 20,9 | 20,9 |
| 100 S.: Journal auf der Platte, MB | 43,5 | 43,5 | 43,5 |
| 100 S.: **eine Speicherrunde, s** | 14,9 | 13,2 | 13,9 |
| 100 S.: Hauptthread während der Runde, längster Block, ms | 3 | 2 | 3 |
| 100 S.: Speicher Spitze während der Runde, MB | – | 410 | 411 |
| 100 S.: Datenbank-Datei, MB | – | 127 | 127 |
| 100 S.: Datenbank-WAL, MB | – | 94,4 | 94,4 |
| 100 S.: Versionen im Verlauf (Anzahl) | 3 | 3 | 3 |
| 100 S.: Versionen zusammen, MB | 79,7 | 79,7 | 79,7 |

**Aufteilung einer Runde bei 50 Seiten (15 000 Striche, 21,8 MB), nachgestellt mit denselben Schritten:**

| Schritt | E | V1 | V2 |
|---|---|---|---|
| Gerät: Dokument serialisieren, s | 1,1 | 0,86 | 1,5 |
| lokales Backend: JSON prüfen (`objectBody`), s | 1,2 | 1,1 | 1,8 |
| lokales Backend: noch einmal lesen (`PyJSON.parse`), s | 3,5 | 3,1 | 4,4 |
| lokales Backend: als Text schreiben (`dumps`), s | 0,90 | 0,81 | 1,0 |
| Rest: SQLite (alter Stand, Stand, Version, kürzen), s | 0,97 | 0,96 | 0,96 |
| gemessene Runde zum Vergleich, s | 7,7 | 6,9 | 9,8 |

### 3.3 Volle Seiten blättern, anspringen, erneut öffnen (50 Seiten × 300 Striche)

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 548–568 | 85–138 | 42–49 |
| Speicherrunde (15 000 Striche), s | 8,4 | 14,1 | 7,3 |
| Blättern bis zum Ende, s | 4,7 | 6,6 | 4,7 |
| Laden bis Striche sichtbar, Median, ms | 289 | 2740 | 234 |
| Laden bis Striche sichtbar, 95. Perzentil, ms | 1239 | 2820 | 1168 |
| Seiten aus dem Bild, bevor ihre Striche da waren (von 50) | 42 | 44 | 33 |
| Overlays und Canvas noch lebendig danach | 9 | 9 | 9 |
| Speicher Spitze beim Blättern, MB | 532 | 591 | 542 |
| Hauptthread beim Blättern, längster Block, ms | 301 | 24 | 9 |
| volle Seite anspringen bis Striche da, Median aus 5, s | 0,37 | 0,42 | 0,39 |
| **erneut öffnen (`DocumentStore.load`), s** | 6,0 | 8,7 | 6,2 |
| davon gespeicherten Stand abrufen (GET), s | 4,3 | 5,7 | 4,5 |
| Hauptthread beim erneuten Öffnen, längster Block, ms | – | 43 | 22 |
| danach Editor bis erste volle Seite mit Strichen, s | 0,14 | 0,16 | 0,22 |

### 3.4 Rückgängig und Wiederholen über Seiten

Je ein Strich auf Seite 2, 9 und 30 (Seite 30 vorher schon mit 300 Strichen), dann weit weg geblättert, bis keine
der drei Seiten mehr ein Overlay hatte. Zeit vom Tippen bis die Seite mit dem erwarteten Stand im Bild ist.

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 568–580 | 138–138 | 49–49 |
| Rückgängig Seite 30 (volle Seite, ohne Overlay), s | 0,03 | 0,04 | 0,03 |
| Rückgängig Seite 9 (ohne Overlay), s | 0,05 | 0,04 | 0,04 |
| Rückgängig Seite 2 (ohne Overlay), s | 0,04 | 0,04 | 0,04 |
| Wiederholen Seite 30 (volle Seite), s | 0,04 | 0,04 | 0,04 |

### 3.5 Zoom bis zum Maximum (6-fach der eingepassten Breite)

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 580–595 | 138–150 | 49–79 |
| eingepasst: Kante PDF-Linie, px | 1 | 1 | 1 |
| eingepasst: Kante Tinte, px | 0,5 | 0,5 | 0,5 |
| eingepasst: Dicke Tinte, px | 3 | 3 | 3 |
| 2-fach: Kante PDF-Linie, px | 1 | 1 | 1 |
| 2-fach: Kante Tinte, px | 2 | 2 | 2 |
| 2-fach: Dicke Tinte, px | 5 | 5 | 5 |
| 4-fach: Kante PDF-Linie, px | 0 | 0 | 0 |
| 4-fach: Kante Tinte, px | 3 | 3 | 3 |
| 4-fach: Dicke Tinte, px | 11 | 11 | 11 |
| 6-fach: Kante PDF-Linie, px | 1 | 1 | 1 |
| 6-fach: Kante Tinte, px | 5 | 5 | 5 |
| 6-fach: Dicke Tinte, px | 16 | 16 | 16 |
| 2-fach: Overlay folgt dem Zoom nach, s | 0,05 | 0,05 | 0,06 |
| 2-fach: Hauptthread beim Zoomen, längster Block, ms | 178 | 167 | 183 |
| 2-fach: Zuwachs Speicher, MB | -25,5 | -26,3 | 3,4 |
| 4-fach: Overlay folgt dem Zoom nach, s | 0,05 | 0,06 | 0,05 |
| 4-fach: Hauptthread beim Zoomen, längster Block, ms | 150 | 177 | 158 |
| 4-fach: Zuwachs Speicher, MB | 9,1 | 10,9 | 6,0 |
| 6-fach: Overlay folgt dem Zoom nach, s | 0,05 | 0,06 | 0,05 |
| 6-fach: Hauptthread beim Zoomen, längster Block, ms | 163 | 183 | 164 |
| 6-fach: Zuwachs Speicher, MB | 31,8 | 0,4 | -0,0 |

### 3.6 Eingefügte Seiten A6 bis A0 (zwischen zwei A4-Seiten)

| Wert | E | V1 | V2 |
|---|---|---|---|
| Lastmittel (1 min) bei Beginn–Ende | 513–509 | 120–115 | 83–83 |
| Zoom eingepasst für alle Seiten (`scaleFactor`) | 0,247 | 0,247 | 0,247 |
| A6: Breite im Fenster, pt | 74 | 74 | 74 |
| A6 im Bild: Speicher, MB | 118 | 169 | 164 |
| A4: Breite im Fenster, pt | 147 | 147 | 147 |
| A4 im Bild: Speicher, MB | 172 | 224 | 221 |
| A2: Breite im Fenster, pt | 294 | 294 | 294 |
| A2 im Bild: Speicher, MB | 242 | 183 | 148 |
| A1 quer: Breite im Fenster, pt | 589 | 589 | 589 |
| A1 quer im Bild: Speicher, MB | 138 | 185 | 184 |
| A0 quer: Breite im Fenster, pt | 832 | 832 | 832 |
| A0 quer im Bild: Speicher, MB | 137 | 184 | 183 |

## 4. Befunde

Nummern M1–M10 (Messung), damit sie sich nicht mit B1–B17 und F1–F7 des Plans überschneiden. M1–M6 sind Mängel,
M7–M10 bestätigen, dass etwas trägt. Behoben wurde keiner: keiner ist ein klarer kleiner Fehler, alle betreffen
Umbauten späterer Schritte oder brauchen erst den Gerätetest.

| Nr. | Befund | Beleg | Planschritt |
|---|---|---|---|
| **M1** | **Speicherrunde wächst mit dem ganzen Dokument** (bestätigt B4). Je Strich rund 1,5 KB JSON, davon knapp die Hälfte `pkdrawing` (Base64). Eine Runde dauerte bei 6 000 Strichen (8,7 MB) 3,0–4,4 s, bei 15 000 (21,8 MB) 6,9–14,1 s, bei 30 000 (43,5 MB) 13,2–16,0 s – auch wenn sich nur eine Seite geändert hat. Über 80 % davon im lokalen Backend: `PUT …/annotations` prüft den Text mit `objectBody` (JSONValue) und liest ihn danach ein zweites Mal mit `PyJSON.parse`, schreibt ihn mit `dumps` zurück und liest dabei in SQLite den alten Stand ganz mit (nur bei Konflikt gebraucht). Der Speicher steigt während einer Runde um das 7- bis 11-fache der Dokumentgröße (Spitze 410–600 MB bei 43,5 MB, mehrere Kopien als Wertebaum und Text). Der Hauptthread bleibt frei | 3.2; SyncEngine.swift:544 (`buildRoot`); AnnotationEndpoints.swift:54-65, 147-160; LocalHTTP.swift:86-93 | Schritt 4 (P0-9) |
| **M2** | **Versionsverlauf speichert je Runde eine volle Kopie.** 100 dichte Seiten: nach drei Runden Datenbank-Datei 127 MB plus WAL 94 MB, Versionen 80 MB. Da nach jeder Schreibpause von 1,2 s eine Runde läuft, sind die 30 Plätze schnell voll: hochgerechnet 30 × 43,5 MB ≈ 1,3 GB für dieses eine Dokument, bei 6 000 Strichen ≈ 260 MB. Ob der Container im iCloud-Backup landet, wurde nicht geprüft | 3.2; AnnotationEndpoints.swift:18, 132-145 | Schritt 4 (P0-9; Entscheidung 3 des Inhabers: Versionen seltener) |
| **M3** | **Erneut öffnen eines dichten Dokuments dauert Sekunden:** 15 000 Striche 5,9–8,7 s, davon 4,3–5,7 s für das Lesen des gespeicherten Stands (lokales Backend parst 23 MB Text, die App die Antwort), der Rest vor allem das Journal (21,8 MB). Die Oberfläche bleibt dabei bedienbar (längster Block 6–43 ms); bis dahin zeigt der Editor aber nichts. Danach ist die erste volle Seite in rund 0,1 s da | 3.3; SyncEngine.swift:238-268; AnnotationEndpoints.swift:42-52 | Schritt 4 (mit M1) |
| **M4** | **Schnelles Blättern über volle Seiten: Striche erscheinen verzögert.** Median 230–290 ms, in einem Lauf 2 740 ms, 95. Perzentil bis 2 820 ms; 33–44 von 50 Seiten waren schon wieder aus dem Bild, bevor ihre Striche da waren. Ursache laut Code: `loadContent` hält das Overlay bis zum Ende fest und dekodiert auch Seiten, die schon weggescrollt sind; alle Ladevorgänge laufen nacheinander durch denselben Store/`InkProcessor`, die sichtbare Seite wartet hinten. Speicherspitze dabei 510–590 MB. Die Freigabe stimmt: danach leben 9 Overlays | 3.3; PDFEditorController.swift:521-530; DocumentStore.swift:87, 410-423 | Schritt 4 (Leistung; kleiner Eingriff, am Gerät prüfen) |
| **M5** | **Zoom-Schärfe (B13) im Simulator: Tinte wird nicht neu gezeichnet.** Kante der Tinte 0,5 / 2 / 3 / 5 px bei 1-, 2-, 4- und 6-fach, die PDF-Linie bleibt bei 1 px; die Ebenen der Canvas behalten `contentsScale` 2. Lage und Dicke stimmen (das Overlay folgt dem Zoom in 0,05 s). Beim Setzen eines neuen Zooms ist der Hauptthread in allen Läufen 140–210 ms am Stück belegt (Sprung auf die Stufe, keine Pinch-Geste; am Gerät mit Instruments ansehen) | 3.5; PDFEditorController.swift:115-121 | Plan-Schritt 3 (P0-10), beim Inhaber Schritt 4 – erst nach Abnahmeliste 5.1 am Gerät |
| **M6** | **Gemischte Seitengrößen: Einpassen auf die breiteste Seite.** Mit einer A0-Seite im Dokument gilt für alle Seiten der Zoom 0,247 statt 1,383: A4 erscheint 147 pt breit (statt 830 pt), A6 74 pt. Das Maximum (6-fach dieser Einpassung) reicht für A4 nur bis rund 880 pt, also etwa Fensterbreite. Seit das iPad selbst Whiteboards bis A0 einfügen kann (Mehr → Leere Seite danach → Anderes Format), trifft das jedes Skript, in das man eine solche Seite einfügt | 3.6; PDFEditorController.swift:362-382; Geometry.swift:42-47 | Schritt 5 (P1-1, Seitenformate) |
| M7 | Schreiben belastet den Hauptthread nicht: Umrechnung einer vollen Seite nach einem Strich 0,04–0,09 s im Hintergrund, Umrechnung + Journal je volle Seite 0,07–0,09 s; während Umrechnung und Speicherrunden längster Block meist 2–6 ms, einzelne Ausreißer unter Last bis 100 ms | 3.2 | – (trägt Schritt 2: Obergrenze beim Sichern ist billig) |
| M8 | Große PDFs: Öffnen ≤ 0,06 s, erste Seite ≤ 0,2 s; Blättern über 100/250/500 Seiten erreicht jede Seite; danach leben 10 Overlays und 10 Canvas (3 sichtbar, 6 geparkt, eines hält noch PDFKit oder ein laufender Ladevorgang) – die `PKCanvasView` werden also freigegeben, auch von der Palette; Speicher nach 500 Seiten nicht höher als nach 100 | 3.1 | – |
| M9 | Rückgängig über Seiten ohne Overlay funktioniert: richtiger Stand, Sprung zur Seite, je Schritt ≤ 0,06 s auch für eine volle Seite; Wiederholen ebenso; Stand nach erneutem Öffnen gespeichert. Neuer Test, vorher gab es dafür keinen | 3.4; PDFEditorController.swift:596-645 | – |
| M10 | Strukturwechsel bei 500 Seiten (Drehen, Leerseite): meist 0,12–0,17 s bis die Seite wieder geladen ist, Hauptthread 70–130 ms am Stück; in einem Zwischenlauf 0,63 s mit 0,52 s am Stück beim Setzen des neuen Anzeige-PDFs. Plan 1.4 Punkt 4 befürchtete mehr; am Gerät mit Abnahmeliste 7.4 nachsehen | 3.1; DisplayLayout.swift:41-71 | – (Schritt 3 wird nicht vom Neuaufbau begrenzt) |

## 5. Bewertung gegen Abschnitt 7 des Plans und Folgerungen

### 5.1 Lastfälle (Plan 7.3)

| Lastfall | Einschätzung im Plan | Messung | Urteil |
|---|---|---|---|
| Schreibverzögerung | Hauptthread kaum belastet, Latenz bestimmt PencilKit | Hauptthread frei (M7); Latenz nicht messbar | bestätigt, Gerät offen |
| Speicher | sichtbare + 6 geparkte Overlays | genau so: 9–10 leben nach jedem Blättern (M8) | bestätigt |
| Große PDFs | lazy, Strukturwechsel kopiert alle Seiten auf dem Hauptthread | Öffnen und Blättern unauffällig; Strukturwechsel meist 0,1–0,2 s bei 500 Seiten (M10) | bestätigt, kein Handlungsbedarf |
| Viele Striche | je Seite linear, je Speicherrunde linear im ganzen Dokument | je volle Seite 0,06–0,09 s; Runde rund 0,3–0,4 s je MB Dokument, auch bei niedriger Last kaum weniger (M1) | bestätigt, **Runde ist das Problem** |
| Schnelles Blättern und Zoomen | Laden asynchron, Gerät n. g. | leere und normale Seiten ohne Verzögerung; volle Seiten verzögert (M4); Tinte beim Zoom unscharf im Simulator (M5) | teilweise |
| Mehrere Ebenen | Umschalten teuer (B12) | nicht neu gemessen (kein weiterer Zeittest dieser Art) | offen |
| Speichern im Hintergrund | Hintergrund-Aufgabe sichert und lädt hoch | eine Runde dauert bei dichten Dokumenten Sekunden; ob iPadOS genug Hintergrundzeit gibt, zeigt nur das Gerät (Abnahmeliste 10.6) | offen |
| Abstürze und Datenverlust | Restfenster = Entprellung + Umrechnung (B3) | Umrechnung + Journal einer vollen Seite unter 0,1 s; das Fenster bestimmt allein die fehlende Obergrenze (B3) | bestätigt |

### 5.2 Vorgeschlagene Grenzwerte (Plan 7.6, Punkt 3)

| Vorschlag | Messung | Urteil |
|---|---|---|
| Speicherrunde < 300 ms bei 300 Seiten | eine Runde kostet rund 0,3–0,4 s je MB Dokument (bei jeder gemessenen Last). 300 ms entsprechen also höchstens etwa 1 MB, rund 650 Strichen im ganzen Dokument – egal wie viele Seiten die PDF hat. Jedes ernsthaft beschriebene Skript liegt darüber | **nicht erreicht** (M1) |
| kein Hänger > 50 ms auf dem Hauptthread während des Schreibens | beim Umrechnen und Speichern meist 2–6 ms; Blöcke über 50 ms beim Öffnen (bis 160 ms), beim Setzen eines Zooms (140–210 ms), beim Strukturwechsel (70–520 ms) und vereinzelt beim Blättern (bis 650 ms in einem Lauf) – nicht beim Schreiben selbst | im Simulator eingehalten; Gerät mit Instruments prüfen |
| Spitzenspeicher < 1 GB auf dem kleinsten iPad | Prozess höchstens 600 MB (Runde mit 30 000 Strichen) und 590 MB (Blättern über volle Seiten) | im Simulator eingehalten, Gerät offen (Abschnitt 6) |
| Volle Läufe ohne parallele Simulatoren (7.6 Punkt 4) | ging nicht: andere Sitzungen nutzten den Mac gleichzeitig | Werte als Obergrenzen lesen |

### 5.3 Folgerungen für die Schritte 2 bis 4

**Schritt 2 – Härtungen (P0-3 bis P0-6).**

- P0-3 Obergrenze beim Sichern ist billig: Umrechnung und Journal einer vollen Seite kosten unter 0,1 s im Hintergrund
  (M7). „Spätestens alle 2 s“ belastet auch beim Dauerschreiben kaum. Die Obergrenze gilt nur für das Journal; der
  Upload bleibt entkoppelt (höchstens eine Runde gleichzeitig), denn eine Runde dauert bei dichten Dokumenten länger
  als 2 s (M1). Test mit Strichtakt 100 ms wie im Plan, ohne Zeitgrenze unter Last.
- P0-4 Formatschutz und P0-5 Herkunftsstempel sind keine Leistungsfrage.
- P0-6 zwei Fenster: im Simulator nicht gemessen; zuerst Abnahmeliste 13.5 am Gerät.

**Schritt 3 – Drehen ohne Verrutschen (P0-7, P0-8).**

- Der Neuaufbau nach dem Drehen kostet bei 500 Seiten meist 0,1–0,2 s (M10); das Mitdrehen der Objekte wird vom
  Umrechnen der einen Seite bestimmt (unter 0,1 s bei 300 Strichen). Kein Leistungsrisiko.
- Jedes Drehen löst eine volle Speicherrunde aus (M1); bei dichten Dokumenten Sekunden, aber im Hintergrund. Bis
  Schritt 4 heißt das nur: der Status steht länger auf „Speichert…“.

**Schritt 4 – Speicherlast (P0-9; P0-10 nach Gerätetest).** Reihenfolge nach Wirkung:

1. **Versionsverlauf (M2):** seltener (Plan 5.5: höchstens eine Version je 5 min plus beim Schließen) senkt den
   Plattenbedarf von bis zu 30 vollen Kopien auf wenige und spart je Runde das zweite Schreiben. Vertragsänderung in
   Python und Swift gemeinsam (Entscheidung 3 des Inhabers).
2. **Lesen im lokalen Backend (M1):** `PyJSON.parse` ist mit gut 40 % der größte Einzelposten einer Runde, das
   vorgeschaltete zweite Lesen mit `objectBody` kostet ein weiteres Sechstel. Prüfen und Lesen in einem Durchgang und
   ein schnelleres `PyJSON.parse` gehen ohne Vertragsänderung; der gespeicherte Text muss gleich bleiben (Parität mit
   `json.dumps`, Fixtures). Den alten Stand nur bei einem Konflikt ganz lesen.
3. **Ablage je Seite** (Plan 5.5 „Datenmenge“) erst, wenn 1 und 2 nicht reichen: dann kostet eine Runde nur die
   geänderte Seite. Vertragsänderung, Python zuerst.
4. Erneut öffnen (M3) profitiert von 2 und 3 (dasselbe Lesen); danach erneut messen.
5. Laden weggescrollter Seiten abbrechen (M4): klein, aber am Eingabeweg – nur mit Gerätetest.
6. Zoom-Schärfe (M5, P0-10): nur, wenn Abnahmeliste 5.1 am Gerät unscharf ist.
7. Zielwerte für die nächste Messung legt der Inhaber fest (Plan 9, Punkt 8). Vorschlag: Runde bei 15 000 Strichen
   unter 1 s auf einem Mac ohne fremde Last, Verlauf höchstens 5 Kopien je Dokument.

**Für Schritt 5:** M6 (Einpassen bei gemischten Formaten) gehört zu P1-1; Vorschlag: Einpassen und Zoomgrenzen je
Seite oder an der häufigsten Seitenbreite statt an der breitesten – vorher prüfen, wie sich der Web-Editor verhält.

## 6. Was der Simulator nicht zeigen kann

- **Pencil-Latenz und Schreibgefühl:** kein Pencil, keine Vorhersage, keine 120-Hz-Anzeige; die Striche im Test sind
  programmatisch gesetzt. Abnahmeliste 1.1–1.4.
- **Handballen, Doppeltippen, Squeeze, Hover:** Systemverhalten am Gerät. Abnahmeliste Abschnitt 2.
- **Echter Speicherdruck:** der Simulator ist ein Mac-Prozess ohne Jetsam-Grenze; `phys_footprint` enthält einen Teil
  des Grafikspeichers nicht, und unter Speicherdruck des Macs springen die Werte (ein Messpunkt fiel auf 63 MB bei
  828 MB `resident_size`). Ob ein iPad mit 4 GB die Spitzen aus 3.3 übersteht, zeigt nur das Gerät (Abnahmeliste 11).
- **Zeichnen der Tinte auf der GPU des iPads:** die Kantenmessung beim Zoom (M5) zeigt das Verhalten im Simulator;
  PencilKit kann am Gerät anders kacheln. Abnahmeliste 5.1.
- **Bildrate und Ruckler:** gemessen wird nur, ob der Hauptthread blockiert, nicht die Anzeige. Am Gerät mit
  Instruments „Animation Hitches“ (Abnahmeliste 15).
- **Geschwindigkeit von Flash-Speicher und CPU des iPads, Wärme:** die Zeiten hier sind Größenordnungen auf einem
  stark belasteten Mac.
- **Hintergrund und Beenden durch iPadOS:** Hintergrundzeit, Abbruch durch das System und zwei Fenster mit demselben
  Dokument (B11) prüft nur die Abnahmeliste (10, 13.5).
- **Echte Vorlesungs-PDFs:** große eingebettete Bilder und Schriften können Öffnen, Blättern und Speicher stärker
  belasten als die erfundenen Seiten.

## 7. Wiederholen

```
cd apps/apple && xcodegen generate
xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow \
  -destination "platform=iOS Simulator,name=<freier iPad-Simulator>" \
  -only-testing:UniFlowTests/EditorScaleTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO | grep EditorMessung
```

Jede Zeile hat die Form `[EditorMessung] <Test> | <Name> = <Wert> <Einheit>`, dazu das Lastmittel bei Beginn und Ende
jedes Tests. Der Test mit 200 Seiten × 300 Strichen läuft nur mit `TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=gross` vor dem
Befehl (dauert unter Last mehrere Minuten). Ohne andere Simulatoren auf dem Mac messen, sonst die Last mit angeben.
Die `EditorScaleTests` verlängern einen vollen App-Lauf um rund drei Minuten.

## 8. Nachtrag Schritt 2: Obergrenze beim Sichern (P0-3)

Stand 28.10.2026, Zweig `wip/editor-2`, gleicher Mac und Simulator wie oben; Lastmittel (1 min) 30–230.

**Verhalten.** Der Store rechnet nach 0,25 s Pause um und sichert ins Journal (wie bisher). Neu: Wird ohne Pause
weitergeschrieben, verarbeitet er spätestens 2 s nach der ersten noch nicht gesicherten Änderung (`SaveTiming`,
`DocumentStore.processWhileWriting`). Dabei gilt:

- **Journal ja, Upload nein:** Eine Upload-Runde schickt immer das ganze Dokument und dauert bei dichten Dokumenten
  Sekunden (M1). Bei einer Runde alle 2 s liefe also ständig eine. Deshalb hält die SyncEngine Runden zurück, solange
  geschrieben wird (`updatePage(…holdUpload: true)`). Eine schon laufende Runde endet normal, eine weitere beginnt
  nicht. Freigegeben wird nach der nächsten Schreibpause sowie bei Export, Teilen, Hintergrund und Schließen
  (`requestUpload`/`syncNow`).
- **Ein Durchgang je Obergrenze:** Was während der Umrechnung dazukommt, wartet auf die nächste Obergrenze oder die
  Pause. Sonst liefe die Umrechnung bei Dauerschreiben ohne Ende mit, sobald sie für eine volle Seite länger dauert als
  der Abstand zweier Striche (älteres iPad). Ohne diese Grenze waren es im Simulator 9 statt 4 Journal-Schreibvorgänge
  in 10 s und 0,14 s statt 0,08 s je Verarbeitung.
- **Datenverlust-Fenster:** höchstens etwa 2 s plus eine Umrechnung statt „bis zur letzten Pause“ (B3).

**Messung** (`EditorScaleTests.testContinuousWritingOnDenseDocument50Pages`: 50 volle Seiten mit 15 000 Strichen,
gesichert, dann 10 s lang alle 100 ms ein Strich auf der vollen Seite 1; dazu `EditorHardeningStep2Tests`):

| Wert | Messläufe (4) |
|---|---|
| erster Journal-Eintrag beim Dauerschreiben (3 Seiten, Takt 100 ms) | 2,05–2,18 s |
| Verarbeitungen durch die Obergrenze in 10 s | 4 |
| je Verarbeitung (volle Seite mit 300–400 Strichen, Umrechnung + Journal, Hintergrund) | 0,05–0,08 s |
| Journal-Schreibvorgänge in 10 s | 4 |
| Upload-Runden während des Schreibens | 0 |
| Hauptthread beim Dauerschreiben, längster Block | 3,6–4,7 ms |
| nach der Pause bis „Gespeichert“ (eine Runde mit dem ganzen Dokument, 21,8 MB) | 6,4–11,5 s |
| Upload-Runden nach der Pause | 1 |

**Bewertung.** Die Obergrenze kostet bei Dauerschreiben auf einer vollen Seite etwa 0,08 s alle 2 s im Hintergrund,
also rund 4 % eines Kerns. Den Hauptthread belastet sie nicht. Upload-Runden laufen wie vor Schritt 2 erst nach einer
Pause; ihre Dauer (M1) senkt erst Schritt 4. Am Gerät: Abnahmeliste 18.1–18.3.

**Weitere Härtungen ohne Messung** (Tests mit Gegenprobe in `EditorHardeningStep2Tests` und `SyncEngineHardeningTests`):

- **P0-4 Formatschutz:** Notizen mit `version` > 2 öffnen nur zum Ansehen, im Journal wie auf dem Server. Kommt ein
  solcher Stand erst während der Sitzung (409), werden keine Uploads mehr gemacht und es wird nichts
  zusammengeführt. Schon Geschriebenes bleibt im Journal.
- **P0-5 Herkunftsstempel:** `origin` wird beim ersten Speichern gesetzt, nur im lokalen Backend und nur, wenn die
  Quelle seit dem Öffnen unverändert ist. S7 entfernt einen alten Stempel, wenn ein Dokument ohne Notizen eine neue
  Fassung bekommt.
- **P0-6 Zwei Fenster:** `OpenDocuments` je Container. Zeigt das erste Fenster das Dokument, öffnet das zweite nur
  zum Ansehen. Zeigt es das Dokument nicht mehr, übernimmt das neue Fenster; das alte sichert vorher Ausstehendes und
  schreibt danach nichts mehr. Gegenprobe ohne Verzeichnis: das zweite Fenster ersetzt die Seite des ersten im
  Journal.

## 9. Nachtrag Schritt 3: Drehen ohne Verrutschen (P0-7) und fremde Zeichnung (P0-8)

Stand 29.10.2026, Zweig `wip/editor-3`.

**P0-7.** Notizobjekte stehen in Punkten der angezeigten Seite. Beim Drehen um 90 Grad im Uhrzeigersinn wird jedes
Objekt als Ganzes mitgedreht: Ursprung (x, y) einer Seite mit angezeigter Größe W × H → (H − y, x), Drehung + 90 Grad;
Punkte, Breite, Höhe, Maßstab und unbekannte Felder bleiben. Eine Regel für alle Objektarten (Striche, Formen, Text,
Bilder, Textmarker), weil Konva und `StrokeConverter.stroke(from:)` dieselbe Reihenfolge rechnen (skalieren, drehen,
verschieben).

- Web: `app/static/pagerotate.js` (`rotateObjects`), eingebunden in `rotatePage`. Rückgängig dreht jetzt Seite **und**
  Notizen zurück (vorher stellte `restorePages` nur die Seitenliste wieder her).
- iPad: `PageRotation.rotate` und `PageOrder.rotate` im Kern, `DocumentStore.rotatePage` über `applyPageStructure`
  (ausstehende Striche zuerst verarbeitet, ein Schreibvorgang für Seite und Seitenliste). Die native Zeichnung dreht
  mit derselben Abbildung mit (`StrokeConverter.rotatedNative`); neue Signaturen nur für Striche, deren Signatur vor
  dem Drehen gültig war.
- Gemeinsame Fälle: `packages/shared-contracts/fixtures/rotate/cases.json` (Web: `tests/js/rotate.test.mjs`, Kern:
  `SharedFixtureTests`). Node ist auf dem Mac nicht installiert; die Fälle liefen gegen `pagerotate.js` mit
  JavaScriptCore (`jsc -m`), alle 7 gleich.
- Dreht der Browser eine Seite, kann er `pkdrawing` nicht mitdrehen: die Signaturen passen dann nicht mehr, und das
  iPad baut die Striche aus dem JSON auf (wie bei jeder Browser-Änderung an einem Strich).
- Android (`apps/android/core`) dreht noch ohne Objekte; gleiche Fixture verwenden, sobald dort gedreht wird.

**P0-8.** Ist die gespeicherte native Zeichnung neuer, als dieses Gerät lesen kann (unbekanntes Format oder
`requiredContentVersion` über dem, was das laufende iPadOS kann: iOS 17 → 2, 17.5 → 3, 26 → 4, 27 → 5; nicht
`PKContentVersion.latest`, das ist der Stand des SDK), zeigt es den Aufbau aus den Objekten und lässt `pkdrawing` beim
Speichern bytegleich stehen (`StrokeConverter.isForeign`, `InkPageState.keepsForeignNative`). Kaputte Daten im
bekannten Format (kein Base64, nicht dekodierbar, Strichzahl passt nicht) werden wie bisher ersetzt
(`AuditRunde11PencilTests`).
Das andere Gerät behält für unveränderte Striche sein Pinselbild (v2 prüft je Strich). Preis: auf diesem Gerät wird
die eigene native Zeichnung der Seite so lange nicht gespeichert; seine Striche erscheinen nach dem Wiederöffnen im
JSON-Aufbau. Ob `PKDrawing(data:)` neuere Inhalte liest (so ist `requiredContentVersion` gedacht) oder wirft, ist ungeprüft;
wirft es, wird die Zeichnung wie kaputte Daten ersetzt. Gerätetest 19.5.

**Tests.** `EditorStep3Tests` (6, App), `PageOrderTests` (+3) und `SharedFixtureTests.testRotateCasesMatchWebEditor`
(Kern). Gegenprobe: ohne Mitdrehen der Objekte bzw. ohne Durchreichen werden 3 der 6 App-Tests rot.

## 10. Nachtrag Schritt 4: Speicherlast (P0-9)

Stand 29.10.2026, Zweig `wip/editor-4`, gleicher Mac und Simulator; Lastmittel am Ende 61/30/20.

**Änderungen.**

1. **Versionsverlauf seltener (M2, Vertragsänderung in Python und Swift gemeinsam):** `PUT …/annotations` legt
   höchstens alle 5 Minuten eine Version an (`VERSION_EVERY_S = 300`, Abstand in Ortszeit ohne Zone wie
   `datetime.fromisoformat`; Uhr zurückgestellt → Version). Mit `?snapshot=true` kommen der **ersetzte und der neue**
   Stand in den Verlauf. Die Apps senden das beim Schließen und in der Runde direkt nach einem Konflikt, damit die
   verworfene Fassung des anderen Geräts wiederherstellbar bleibt (Prüfpunkt 431). Wiederherstellen läuft über
   denselben Weg. Die letzten 30 Versionen bleiben. Ist beim Schließen nichts offen, wurde seit dem letzten Snapshot
   aber gespeichert, sendet das iPad den Stand dafür noch einmal (`SyncEngine.syncNow(snapshot:)`), der Web-Editor
   ebenso (`flush(true)` in `destroy`). Tests: `tests/test_annotation_versions.py`, `AnnotationVersionTests`,
   `SyncEngineTests.testSnapshot…`, Fixture `library-files.json` (Schleife mit `snapshot=true` für die Grenze 30).
2. **Einmal lesen (M1):** `PUT` liest den Text nur noch einmal mit `PyJSON` (vorher zusätzlich `objectBody`); nur
   wenn es kein Objekt ist, noch einmal für dieselbe 422 wie FastAPI.
3. **Alten Stand nur bei Konflikt:** aus SQLite wird nur die Versionsnummer gelesen, der gespeicherte Text nur bei
   einem Konflikt oder einem Snapshot.
4. **`PyJSON` schneller:** Leerraum ohne Liste je Zeichen, Texte ohne Escape direkt aus den Bytes, kleine Objekte ohne
   Wörterbuch, `dumps` schreibt Texte ohne Maskierung am Stück. Gemessen (18 MB, Debug): Lesen 2,8 s → 0,9 s,
   Schreiben 0,50 s → 0,44 s; Text byte-gleich zum alten Leser.

**Messung** (`EditorScaleTests.testDenseScriptSaveRounds100PagesWith300Strokes`, 100 Seiten × 300 Striche):

| Wert | vorher (Abschnitt 3.2) | Schritt 4 |
|---|---|---|
| eine Speicherrunde (ganzes Dokument, 43,5 MB) | 13,2–16,0 s | 4,4 s |
| Versionen im Verlauf nach dem Test | eine volle Kopie je Runde | 1 (die erste Runde) |
| Datenbank-Datei + WAL | 127 + 94 MB | 80 + 47 MB |
| Speicherspitze während der Runde | 410–600 MB | 380 MB |
| Hauptthread während der Runde, längster Block | frei | 1,1 ms |
| ein Strich mehr auf voller Seite (Umrechnung + Journal) | 0,04–0,09 s | 0,04 s |

**Offen.** Die Runde schickt weiter das ganze Dokument. Eine Ablage je Seite (Plan 5.5, Punkt 3) wäre der nächste
Schritt und eine Vertragsänderung mit Python zuerst; nach dieser Messung (4,4 s im Hintergrund, Hauptthread frei)
nicht nötig für V1. M4 (Laden weggescrollter Seiten abbrechen) und M5/P0-10 (Zoom-Schärfe) nur nach dem Gerätetest
(Abnahmeliste 5.1, 6).


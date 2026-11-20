# Arbeitsspeicher iPad/iPhone – Zwischenstand (20.11.2026, Zweig `app/speicher`)

Auftrag des Inhabers (20.11.2026): „iPads dürfen nie abstürzen wegen zu hohem Arbeitsspeicher, den wir einnehmen –
kontrolliere das.“ Ziel: kleinste Geräte, iPad 9 (A13, 3 GB) und iPad Air 4 (4 GB).

Basis: `origin/release/1.0.7` @ 54dae5a6. **Stand: nur Durchsicht des Codes, noch keine Messung, noch keine
Code-Änderung.** Die Sitzung endete wegen Kontowechsel; dieses Blatt ist die Übergabe an den Nachfolger.

## 1. Neuer Befund des Inhabers (für den Nachfolger, noch nicht untersucht)

> „Mit dem Finger das Blatt bewegen (scrollen) hakt, seit die Schrift beim Zoomen mitzoomt.“

Verdacht (release/1.0.7 @ 54dae5a6, `apps/apple/UniFlow/Editor/PDFEditorController.swift`, `PageInkView`):
- `followViewport()` läuft bei **jeder** Änderung von `contentOffset` (KVO in `didMoveToWindow`, je Overlay). Zeigt die
  Zeichenfläche nur einen Ausschnitt (Zoom > 4), wandert der Ausschnitt beim Scrollen mit (`apply(_:coverMoves:false)`
  → `Self.place(canvas, …)`): PencilKit zeichnet die Striche des neuen Ausschnitts neu – das kann beim Scrollen haken.
  Außerdem rechnet `viewportInPage()` je Bild die Vorfahrenkette durch.
- Pinch-Hilfsfläche (`showPinchUnderlay`): legt eine zweite PencilKit-Fläche mit **allen** Strichen der Seite an
  (ganze Seite bis 4-fach) – teuer beim Beginn einer Zoomgeste.
- Messvorschlag: Hauptthread-Blockaden beim Scrollen mit 300 Strichen/Seite bei Zoom 1, 4, 6, 10 messen
  (`EditorScaleTests.Hauptthread`, `scrollThrough`), Zahl der `windowMoves` je Sekunde zählen; Gegenprobe mit
  `PencilTuning.sharpInkWindow = false`.

## 2. Was schon gut ist (vorhandene Vorkehrungen, gefunden)

- Reiter: im Speicher liegt immer nur das aktive Dokument (`DocumentTabList`); andere Reiter sind leichte Einträge.
- Editor: geparkte Seiten-Overlays höchstens 6 bzw. 6 A4-Flächen (`parkedLimit`, `parkedAreaLimit`); beim Parken
  zurück auf Bildschirmauflösung; Speicherwarnung gibt geparkte Overlays und fremde Ebenen frei
  (`PDFEditorController.didReceiveMemoryWarning`).
- Seitenminiaturen: höchstens 60 (`ThumbnailCache`), Speicherwarnung behält nur sichtbare (`PageSidebar`).
- Bibliotheks-Vorschauen: `NSCache` mit 300 Stück / 96 MB (`UFThumbnails`).
- Eigene PDF-Instanz der Miniaturen wird bei Speicherwarnung freigegeben (`DocumentStore` → `offscreenPDF.release()`).
- Texterkennung rendert je Seite einzeln im `autoreleasepool`, Bildseite höchstens 4000 px (`VisionPageOCR`).
- Fingerabdruck einer Datei liest in 1-MB-Blöcken (`ContentHash.file`).
- Eingefügte Bilder werden auf höchstens 2400 px verkleinert (`ObjectClipboard.normalized`).
- Lösung daneben (`SolutionSideViewer`): weggescrollte Overlays werden freigegeben.

## 3. Risiken (aus dem Code, noch nicht gemessen) – nach Gewicht

Rechnung: Bildpunkte × 4 Byte. iPad 9: Bildschirm 2x. Grenze für eine App auf 3-GB-iPads grob 1,4–1,8 GB (am Gerät
mit `os_proc_available_memory()` prüfen; im Simulator gibt es keine Grenze und GPU-Speicher wird nicht mitgezählt).

1. **Zeichenfläche: ganze Seite bis Zoom 4 ohne Flächengrenze** (`PageInkView.inkLayout`: bis `wholePageZoom` = 4
   immer die ganze Seite, `inkPixelBudget` greift erst darüber). A4 bei Zoom 4: 32 Mio. px ≈ 128 MB (so gewollt).
   **A0-Seite** (eingefügt oder Whiteboard) bei Zoom 3: 2384 × 3370 × 9 × 4 ≈ 289 Mio. px ≈ **1,16 GB**, bei Zoom 4
   ≈ 514 Mio. px ≈ **2 GB** – je Zeichenfläche. Ob PencilKit wirklich die ganze Fläche belegt (oder nur Kacheln im
   Bild), ist zu messen; die Rechnung im Code (`parkedAreaLimit`: „A0 quer 35 Kacheln, etwa 140 MB“) deutet auf
   Kacheln über die ganze Fläche. War so auch schon vor 1.0.7 (`renderScale` limit 8 = Zoom 4). Vorschlag: auch unter
   Zoom 4 die Flächengrenze anwenden (Zoomstufe senken), auf 3-GB-Geräten mit kleinerem Budget.
2. **Mehrere Flächen je Seite gleichzeitig**: eigene Tinte + fremde Lösung (`foreignInk`) + Korrektur
   (`correctionView.ink`) nutzen dasselbe Layout, je bis 132 MB; dazu Pinch-Hilfsfläche (bis 132 MB) und beim
   Zoomwechsel kurz die alten Kacheln unter dem Deckbild. Zwei sichtbare Seiten: grob bis ~1 GB GPU-Speicher.
3. **Mensa-Fotos**: `AsyncImage` lädt und dekodiert das ganze Foto, gezeigt in 76 × 76 pt. Ein 2–4-MP-Foto kostet
   8–16 MB dekodiert, eine Liste mit 20 Gerichten 160–320 MB. Vorschlag: eigener Lader mit Verkleinern beim Dekodieren
   (`CGImageSourceCreateThumbnailAtIndex`, `kCGImageSourceThumbnailMaxPixelSize` = Anzeigegröße × Bildschirm),
   `NSCache` mit Grenze, leeren bei Speicherwarnung. Sichtbar: nichts (gleiche Schärfe).
4. **Skriptsuche-Index** (`ScriptSearch.IndexCache`, UniFlowCore): bis 20 Indizes je Datenbank, jeder mit allen
   Seitentexten und Wortzählungen eines Moduls; ohne Größengrenze, ohne Speicherwarnung. Ein Modul mit 10 × 300 Seiten
   ≈ 30–60 MB je Index. Vorschlag: Grenze nach Textbytes, `purge()` bei Speicherwarnung (über `LocalBackendHost`).
5. **Datei-Eingang-Hochladen** (`AccountCourseFileIntake.upload`, UniFlowCore): baut den multipart-Körper im
   Speicher (Datei bis 80 MB wird in `Data` kopiert, dann noch einmal in `URLRequest.httpBody`). Vorschlag: Körper in
   eine Temp-Datei schreiben (Blöcke à 1 MB) und `URLSession.upload(for:fromFile:)`; dazu Protokoll
   `ServiceHTTPTransport` um eine Methode mit Datei-Körper erweitern (Standard-Umsetzung liest die Datei → Testattrappen
   bleiben gleich). `StudiNowAI.swift` nicht anfassen (anderer Helfer).
6. **Seitentexte lesen** (`AppDocumentTools.pdfPageTexts`, `LocalBackendHost.swift`): alle Seiten in einer Schleife
   ohne `autoreleasepool` – bei 300–500 Seiten wachsen PDFKit-Seitenobjekte bis zum Ende. Vorschlag: `autoreleasepool`
   je Seite. Der Datei-Eingang liest dafür alle Seitentexte, braucht aber nur die ersten 3.
7. **Bilder der Notizen** (`DocumentStore.images`): Wörterbuch ohne Grenze für die Lebensdauer des Dokuments, je Bild
   bis 2400 px ≈ 23 MB dekodiert. Vorschlag: bei Speicherwarnung leeren (sichtbare Bildansichten halten ihr Bild
   selbst; vorher prüfen, dass die Seite fehlende Bilder per `loadImage` neu holt).
8. **Text-Objekte bis 8-fach** (`objectScaleLimit` = 8): ein Textfeld kostet Bildpunkte im Quadrat des Faktors. Auf
   3-GB-Geräten evtl. 6 – **sichtbar** (Text bei > 600 % minimal weicher), nur mit Okay des Inhabers.
9. Kleinere: `RecordingLibrary.thumbnails` ohne Grenze; `NSCache` ohne Grenzen in `AISupport` (BlocksBox) und
   `MathLayout`; Bibliotheks-Vorschau lädt für ein Vorschaubild die ganze PDF in den Speicher (`UFThumbnails.image`,
   `api.data`), mehrere gleichzeitig möglich.
10. Empfehlung ohne Code: Berechtigung `com.apple.developer.kernel.increased-memory-limit` (höhere Grenze auf iPads)
    – braucht die Fähigkeit im Apple-Entwicklerkonto und ein neues Profil; nur mit dem Inhaber.

## 4. Geplanter Umbau (noch nicht begonnen)

- Neue Datei `UniFlow/Services/MemoryBudget.swift`: Geräteklasse aus `ProcessInfo.physicalMemory` (für Tests
  einspritzbar) und `os_proc_available_memory()` beim Start; Budgets je Klasse:
  - ≤ 3,5 GB (iPad 9): Zeichenfläche ~16 Mio. px (64 MB), geparkte Overlays 3, Miniaturen 30, Vorschauen 48 MB,
    Mensa-Bilder 20 MB, Skript-Index 24 MB Text.
  - ≤ 5 GB (iPad Air 4): Zeichenfläche 24 Mio. px, geparkt 4, Miniaturen 45, Vorschauen 64 MB.
  - darüber: alles wie heute (Editor unverändert).
- Zentrale Stelle `MemoryPressure` (Speicherwarnung + `DispatchSource.makeMemoryPressureSource`): Caches melden sich
  mit einer Freigabe-Funktion an; misst `phys_footprint` vor/nach (DEBUG-Protokoll).
- Tests: Speicherwarnung leert Caches; Budgets bei simulierten 3 GB; kein Leck nach Öffnen/Schließen von 5 Dokumenten
  (schwache Verweise auf `DocumentStore`/`PDFEditorController`); vorhandene Messhilfen in
  `UniFlowTests/EditorScaleTests.swift` (`Speicher.footprintBytes`, `Hauptthread`, `scrollThrough`) wiederverwenden.

## 5. Messungen

Noch keine. Vorhandene Werte aus `docs/EDITOR-MESSUNG.md` (28.10.2026, Simulator): Blättern 100–500 Seiten Spitze
280–337 MB, dichte Seiten 530–590 MB, Speicherrunde 30 000 Striche 410–600 MB; Overlays nach dem Blättern 10.
Simulator-Klon (`xcrun simctl clone "iPad (A16)" fix-speicher`) und iPad-9-Simulator noch nicht angelegt.

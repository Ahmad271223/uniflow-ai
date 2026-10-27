# PDF-Editor der Apple-App: Analyse und Plan (PencilKit)

Stand 27.10.2026 · Grundlage `origin/develop` (bc7e075) · **nur Analyse und Plan, kein Code geändert.**
Die App heißt im Code UniFlow; im Auftrag des Inhabers auch „Studora“. Umsetzung erst nach Freigabe durch den Inhaber.

**Leseschlüssel**

- Stand: **V** = vollständig · **T** = teilweise · **G** = nur geplant (Vertrag, Doku oder Server da, Client fehlt) ·
  **–** = fehlt
- **n. g.** = nicht geprüft (nicht am Gerät gelaufen oder aus dem Repo nicht belegbar). Nichts davon ist erfunden;
  wo eine Aussage auf Apple-Verhalten außerhalb des Repos beruht, steht das dabei.
- Belege als `Datei:Zeile`. Die vollständigen Pfade stehen in **Anhang A**.
- Aufwand (Schätzung inkl. Tests, ohne Gerätetest): **S** ≤ 1 Tag · **M** 2–4 Tage · **L** 1–2 Wochen · **XL** > 2 Wochen.

## Kurzfassung

1. **Die App nutzt schon genau die geforderte Kombination:** PDFKit (`PDFView`) mit `PDFPageOverlayViewProvider` und
   je sichtbarer Seite ein `PKCanvasView` (PDFEditorController.swift:149, 308, 434-454). Sie ist sauber gebaut
   (Seitenpunkte, Overlay-Wiederverwendung, Stift scrollt nie, dokumentweites Rückgängig, Schreiben getrennt von
   Sichern und Hochladen). **Empfehlung: beibehalten**, keine eigene Canvas-Engine, keine zweite Editor-Architektur.
2. **Die größte Lücke ist nicht PencilKit, sondern alles neben der Tinte:** Text, Haftnotizen, Formen und Bilder sind
   auf dem iPad nur sichtbar, nicht bearbeitbar (PageObjects.swift:221-232; DocumentStore.swift:562-578); das Lasso
   erfasst nur Striche; Seitenoperationen wie Umsortieren, Duplizieren, Vorlage oder Format wechseln fehlen.
3. **Nie am Gerät geprüft:** Schreibgefühl, Handballen, Palette, Doppeltippen, Zoom-Schärfe der Tinte
   (MAC-IPAD-CHECKLISTE.md:3; ENTWICKLUNGSSTAND.md:37). Das ist der erste P0-Schritt.
4. **Skalierungsrisiko beim Speichern:** Jede Speicherrunde sendet das ganze Dokument, das lokale Backend schreibt es
   vollständig und legt zusätzlich eine volle Versionskopie ab (30 werden behalten) – bei großen, dicht beschriebenen
   Skripten nicht gemessen (SyncEngine.swift:424-432, 495-504; AnnotationEndpoints.swift:17-18, 132-145).
5. **Kleines Datenverlust-Fenster:** Die Entprellung beim Sichern hat keine Obergrenze; bei Dauerschreiben kann der
   neueste Stand länger nur im Speicher liegen (DocumentStore.swift:414-425). Der Web-Editor hat Obergrenzen
   (editor.js:573, 577).
6. **Seitendrehung verschiebt Notizen gegenüber dem PDF-Inhalt** (Web und iPad gleich, „Notizen behalten ihre
   Koordinaten“, DocumentStore.swift:550-560; editor.js:808).
7. **Formatschutz fehlt:** Die Regel „neuere Version nur lesen“ ist nicht umgesetzt (shared-contracts/README.md:26-27);
   der Web-Editor würde ein Dokument mit `version: 3` als Altformat leer einlesen (editor.js:172-187).
8. **Geräte-Abgleich fehlt auf dem iPad bewusst** (V1 ohne Konto, Migrations.swift:12-15); Vertrag G2, Python und
   Kotlin-Kern sind da. Die Regeln für neue PDF-Fassungen (S7) gibt es nur in Swift (FileVersions.swift:3-4).
9. **Community** (CloudKit: veröffentlichen, finden, laden, zurückziehen, melden, blockieren, Lerngruppen) ist gebaut,
   aber nur mit iCloud-Container echt testbar; **Kommentare/Fragen je Seite gibt es nirgends.**
10. **Android** zeichnet nur Striche, ohne Objekt-Transformation, Breiten je Punkt, eingefügte Seiten oder Drehung
    (DocumentScreen.kt:270-283; AnnotationDocument.kt:66) – für V2 relevant.

**Empfohlene Reihenfolge:** (0) Bestandsliste, Gerätetest und Messungen → (1) kleine P0-Härtungen (Obergrenze beim
Sichern, Formatschutz, Herkunftsstempel, Doppel-Fenster, Drehung) → (2) Speicherlast nach Messung senken →
(3) P1: Seitenwerkzeuge und Navigation, dann Objektschicht (Text, Haftnotiz, Objekt-Lasso), geteilte Ansicht,
Ebenen → (4) V2: S7 als gemeinsamer Vertrag, G2-Sync-Client, Android-Darstellung → (5) P2: Kommentare,
Handschrift zu Text, Pencil-Gesten, eigene Palette.

---

## 1. Analyse der Apple-App

### 1.1 Rahmen

| Punkt | Stand | Beleg |
|---|---|---|
| Plattform | nur iPad (`TARGETED_DEVICE_FAMILY: "2"`), App-Ziel `platform: iOS` | project.yml:21, 33 |
| Mindestversion | **iPadOS 17.0** (App und Kern-Paket) | project.yml:7; Package.swift:11 |
| Mehrere Fenster | erlaubt (`UIApplicationSupportsMultipleScenes: true`) | project.yml:80 |
| Betriebsart V1 | ohne PC-Server; ein lokales Backend beantwortet dieselben Endpunkte wie `app/server.py` | AUFTRAG-APPSTORE-V1.md:21-34 |
| Editor V1 | Apple-Editor (PencilKit + PDFKit); ein „UniFlow-Editor 1:1 wie im Web“ war für V2 geplant | AUFTRAG-APPSTORE-V1.md:11-12, 35-38 |
| Schreiben nur mit Plus | Free = nur ansehen und exportieren, Herabstufen löscht nie | Entitlements.swift:193-197; DocumentView.swift:169-174 |
| Build/Test | CI auf `macos-15` (Simulator); SDK-Version des Entwickler-Macs **n. g.** | apple.yml:53 |

### 1.2 Architektur

```
DocumentView (SwiftUI: Leisten, Menüs, Seitenleiste, geteilte Ansicht, Banner)
 └ PDFEditorView (UIViewControllerRepresentable)
    └ PDFEditorController ── PDFView (PDFKit: Anzeige, Scrollen, Zoom, Suche)
         │                    pageOverlayViewProvider = self, isInMarkupMode = true
         └ je sichtbare Seite: PageInkView (Overlay, Inhalt in Seitenpunkten)
              ├ foreignView  fremde Lösungen (ForeignLayerView, je Ebene ein PKCanvasView nur zur Anzeige)
              ├ objectsView  Vorlage, Text, Formen, Bilder (PageObjectsView, nur Anzeige)
              └ canvas       InkCanvasView (PKCanvasView, eigene Stifteingabe)
DocumentStore (@MainActor) ── InkProcessor (actor) ── StrokeConverter (PencilKit <-> gemeinsames JSON)
 └ SyncEngine (actor) ── LocalJournal (Dateien je Seite, atomar ersetzt)
                       └ AnnotationTransport ── lokales Backend (SQLite) bzw. eigener PC-Server (nur Debug)
```

Belege: Schichten und Reihenfolge PDFEditorController.swift:25-31, 80-86; Controller 141-149, 302-309;
DocumentStore 169-174, 202-203; InkProcessor DocumentStore.swift:87-107; SyncEngine.swift:131-146; Journal
LocalJournal.swift:30-35 und BlobStore.swift:11-33; Transport APIClient.swift:181-205 und
DocumentStore.swift:111-136; lokales Backend AnnotationEndpoints.swift:3-13.

### 1.3 Genutzte PencilKit- und PDFKit-Funktionen

| API | Wofür | Beleg |
|---|---|---|
| `PDFView` (`singlePageContinuous`, vertikal, `usePageViewController(false)`, `autoScales` nur fürs erste Einpassen) | durchgehendes Scrollen, Zoom | PDFEditorController.swift:302-307, 357-371 |
| `PDFPageOverlayViewProvider` (`overlayViewFor`, `willEndDisplayingOverlayView`) | Overlay je Seite, Wiederverwendung | PDFEditorController.swift:149, 308, 434-468 |
| `isInMarkupMode = true` | Overlays bekommen die Stifteingabe, keine Textauswahl | PDFEditorController.swift:309 |
| `PDFDocument.findString`, `highlightedSelections` | Suche | DocumentStore.swift:582-592; PDFEditorController.swift:756-759 |
| `PDFPage.copy()`, `rotation`, eigene Leerseiten | Anzeige-PDF nach `pageOrder` | DisplayLayout.swift:41-71 |
| `PKCanvasView` (kein eigenes Scrollen/Zoomen, `drawingPolicy`) | Schreiben je Seite | PDFEditorController.swift:70-79, 239-245, 499-505 |
| `PKToolPicker` (eine Palette, unsichtbarer Anker, `stateAutosaveName`, `colorUserInterfaceStyle = .light`) | Stifte, Radierer, Lasso, Lineal, Farben | PDFEditorController.swift:6-10, 312-317, 778-782 |
| `PKCanvasViewDelegate` (Änderung, Beginn/Ende des Werkzeugs) | Sichern, Rückgängig, kein Neuladen mitten im Strich | PDFEditorController.swift:640-663 |
| `PKDrawing`, `PKStroke`, `PKStrokePath`, `PKStrokePoint`, `maskedPathRanges`, `interpolatedPoints` | Umrechnung ins gemeinsame Format | StrokeConverter.swift:200-227, 416-482 |
| Tintenarten ab iPadOS 17 (`monoline`, `fountainPen`, `watercolor`, `crayon`) | wiederherstellbar über `pkInk` | StrokeConverter.swift:104, 243-251 |
| `PKDrawing.dataRepresentation()` / `PKDrawing(data:)` | native Zeichnung `pkdrawing` je Seite | StrokeConverter.swift:114-117, 406-408 |

**Nicht genutzt** (Suche im ganzen App-Code ohne Treffer): `UIPencilInteraction` (Doppeltippen, Squeeze),
`UIHoverGestureRecognizer`, `UIScribbleInteraction`, eigene Paletten-Einträge, `PKContentVersion`/
`maximumSupportedContentVersion`, `PDFAnnotation`, `PDFThumbnailView`, `UIKeyCommand` (nur ein Kürzel ⌘K in
AppShell.swift:449). Der frühere Plan nannte `UIPencilInteraction` (NATIVE-IPAD-PLAN.md:13), umgesetzt ist es nicht.

### 1.4 Ausdrücklich geprüft: `PDFPageOverlayViewProvider` plus ein `PKCanvasView` je Seite

**Was die App heute tut – genau dieses Muster:**

- Der Controller ist der Overlay-Lieferant und wird vor dem Dokument gesetzt (PDFEditorController.swift:149, 308).
- Je Seite entsteht ein `PageInkView` mit drei Schichten in **Seitenpunkten** (Ursprung oben links, ohne Zoom); passt
  PDFKit die Overlay-Größe an, skaliert ein Transform den Inhalt (PDFEditorController.swift:25-31, 115-121;
  Geometry.swift:6-37). Die Canvas scrollt und zoomt nie selbst (PDFEditorController.swift:74-79).
- Overlays werden wiederverwendet (bis zu 6 geparkt) und tragen die Generation des Seitenaufbaus, damit nach
  Einfügen oder Drehen kein altes Overlay auftaucht (PDFEditorController.swift:34-36, 164-165, 434-468).
- Stift scrollt nie: Scroll- und Pinch-Gesten von PDFKit nehmen nur Finger an; im Modus „Finger zeichnet“ scrollen
  zwei Finger (PDFEditorController.swift:384-392).
- Eine Palette für alle Seiten an einem unsichtbaren Erstantwortgeber, damit sie beim Wegscrollen nicht schließt
  (PDFEditorController.swift:6-10, 290-292, 312-317); in der geteilten Ansicht teilen sich beide Dokumente Palette
  und Verlauf (DocumentView.swift:22-27, 341-347).
- Immer helles Erscheinungsbild, damit schwarze Tinte im Dunkelmodus schwarz bleibt (PDFEditorController.swift:29-30,
  67, 73).
- Laden asynchron; früh gezeichnete Striche gehen nicht verloren; während eines Strichs wird nie neu geladen
  (PDFEditorController.swift:508-554, 651-663).

**Bewertung:** Das ist der von Apple für PDFKit vorgesehene Weg (Overlay-API ab iPadOS 16; Angabe aus dem Plan
NATIVE-IPAD-PLAN.md:30-32) und im Code sorgfältig abgesichert. Die Simulator-Tests belegen Seitenkoordinaten,
Overlay in Seitenpunkten und Overlay-Anforderung durch PDFKit (PDFLayoutTests.swift:36-66).

**Schwächen und offene Punkte dieses Musters (alle n. g. am Gerät):**

1. **Zoom-Schärfe:** Die Canvas wird per Transform vergrößert (PDFEditorController.swift:115-121). Ob PencilKit bei
   400–600 % scharf nachzeichnet, ist unbekannt; die Tests bilden die Canvas über `PKDrawing.image` nach, weil
   `CALayer.render` die PencilKit-Kacheln nicht erfasst (InkSnapshot.swift:4-7). Ausweg, falls unscharf: Canvas in
   Ansichtsgröße mit eigenem `zoomScale` statt Transform (die Zeichnung bleibt dabei in Seitenpunkten) – erst nach
   Messung entscheiden.
2. **Seitengrenzen:** Ein Strich, ein Lasso oder das Lineal wirken nur auf einer Seite. Das ist auch im Web so
   (eine Konva-Bühne je Seite, editor.js:389-410) und für Vorlesungsfolien vertretbar.
3. **Lineal mit vielen Beobachtern:** Jede Seiten-Canvas beobachtet die Palette (PDFEditorController.swift:503-504);
   ob das Lineal dann auf mehreren sichtbaren Seiten gleichzeitig erscheint, ist n. g.
4. **Strukturänderung baut alles neu:** Einfügen, Drehen, Papierkorb erzeugen ein neues Anzeige-PDF mit Kopien
   aller Seiten und verwerfen alle Overlays (DisplayLayout.swift:41-71; PDFEditorController.swift:404-430). Bei
   100–500 Seiten n. g.
5. **Viele Canvas-Ansichten bei fremden Ebenen:** Jede eingeblendete fremde Lösung bekommt je Seite ein eigenes
   `PKCanvasView` (SolutionLayer.swift:116, 146-158); Umschalten baut alle neu (PDFEditorController.swift:181-187,
   472-484).

**Alternativen im Vergleich:**

| Variante | Vorteil | Nachteil | Urteil |
|---|---|---|---|
| **A – heute:** PDFView + Overlay-Provider + `PKCanvasView` je Seite | Apple-Weg, PDFKit kachelt, sucht und zoomt; Speicher je Seite begrenzt; Koordinaten je Seite wie im Datenmodell | Striche nicht seitenübergreifend; Overlay-Lebenszyklus anspruchsvoll (gelöst) | **beibehalten und härten** |
| B – ein `PKCanvasView` über dem ganzen Dokument | seitenübergreifende Striche, ein Lasso | PDF selbst zeichnen, riesige Zeichnung (500 Seiten), Umrechnung je Seite, PDFKit-Suche/Text weg, jede Speicherung über alle Striche | nein |
| C – `PDFAnnotation` (Ink) in der PDF | PDFKit-eigen | schreibt in die PDF (Originale bleiben beim Hochschulserver), PencilKit-Qualität und gemeinsames Format weg | nein |
| D – eigene PDF-Ansicht (Scroll-View, Kachel-Ebene) + `PKCanvasView` je Seite | volle Kontrolle über Zoom-Schärfe | viel Eigenbau, Suche, Auswahl, Bedienungshilfen neu | nur, falls A am Gerät scheitert |

### 1.5 Ablauf: Schreiben → Sichern → Hochladen

| Schritt | Thread | Beleg |
|---|---|---|
| 1. PencilKit meldet eine geänderte Zeichnung; der Editor gibt sie sofort an den Store | Haupt | PDFEditorController.swift:640-649 |
| 2. Store merkt nur die neueste Zeichnung je Seite und kehrt sofort zurück; nach **0,25 s** Ruhe Verarbeitung | Haupt | DocumentStore.swift:414-425 |
| 3. Umrechnung PencilKit → JSON mit drei-Wege-Regel und Strich-Identität | Hintergrund (actor) | DocumentStore.swift:87-107, 435-460; StrokeConverter.swift:277-410 |
| 4. `SyncEngine.updatePage`: neue Revision, sofort ins Journal (atomar) | Hintergrund (actor) | SyncEngine.swift:287-297; BlobStore.swift:25-33 |
| 5. Nach **1,2 s** ein Upload (höchstens einer gleichzeitig), bestätigt werden genau die gesendeten Revisionen | Hintergrund | SyncEngine.swift:194-203, 404-468 |
| 6. 409 → objektweise Zusammenführung (Basis = letzter bestätigter Stand), erneut senden | Hintergrund | SyncEngine.swift:455-463, 538-621 |
| App in den Hintergrund / Ansicht verdeckt / Schließen: alles Ausstehende sofort | Haupt + Hintergrund | DocumentStore.swift:637-680 |
| Öffnen: Journal laden, ungesendete Seiten wiederherstellen, beschädigte Dateien melden | Hintergrund | SyncEngine.swift:238-268; DocumentStore.swift:273-279 |

### 1.6 Rückgängig und Wiederholen

PencilKits eigener Verlauf ist abgeschaltet (er hinge an einer Canvas, die beim Scrollen verschwindet,
PDFEditorController.swift:12-23). Der Editor führt Schnappschüsse je Seitenschlüssel in einem dokumentweiten
`UndoManager` mit 150 Schritten (PDFEditorController.swift:267, 567-632). Im Ansichtsmodus und ohne Plus nimmt das
System-Rückgängig nichts zurück (PDFEditorController.swift:247-257). Fremde Änderungen löschen den Verlauf der Seite,
damit nichts Gelöschtes zurückkommt (PDFEditorController.swift:538-542, 556-565).

### 1.7 Seitenstruktur

Anzeige nach `pageOrder` wie im Web: PDF-Seiten mit Zusatzdrehung, Leerseiten mit sechs Vorlagen, Platzhalter für
im Browser eingefügte Bild-/PDF-Seiten, Papierkorb (DisplayLayout.swift:5-9; PageOrder.swift:3-11, 14). Auf dem iPad
gibt es: Leerseite danach einfügen (Größe wie die Seite davor), drehen, in den Papierkorb, wiederherstellen,
Lesezeichen (PDFEditorController.swift:670-734; DocumentStore.swift:522-560; DocumentView.swift:502-529). Notizbücher
und Whiteboards ohne PDF öffnen ebenfalls (DocumentStore.swift:254-265).

### 1.8 Ebenen, Ansichtsmodus, Tarif

- „Meine Notizen“ ein-/ausblenden; ausgeblendet = nur ansehen, kein Schreibweg (PDFEditorController.swift:196-208;
  DocumentStore.swift:227-236).
- Fremde Lösungen als eigene Schicht über der PDF und unter den eigenen Notizen, einzeln ein-/ausblendbar, Vorschau
  ohne Original, Entfernen (DocumentView.swift:571-622; SolutionLayer.swift:7-78, 101-179).
- Neue Original-Fassung während das Dokument offen ist: nur noch ansehen bis zum Neuöffnen (DocumentStore.swift:189-193,
  497-503).

### 1.9 Befunde der Apple-App

| Nr. | Befund | Beleg |
|---|---|---|
| B1 | Text, Haftnotizen, Formen, Bilder **nur sichtbar**; Text anlegen nur per Dialog an fester Stelle oben links, danach nicht bearbeitbar oder verschiebbar | PageObjects.swift:221-232, 288-319; DocumentStore.swift:562-578; DocumentView.swift:266-275 |
| B2 | Lasso erfasst nur PencilKit-Striche; die Objektschicht liegt unter der Canvas und nimmt keine Eingabe an | PDFEditorController.swift:83-85; PageObjects.swift:231 |
| B3 | Entprellung beim Sichern **ohne Obergrenze**: jede neue Änderung verschiebt die Verarbeitung um 0,25 s | DocumentStore.swift:419-424 (Web dagegen: Entwurf spätestens nach 1,5 s, Senden spätestens nach 20 s, editor.js:573, 577) |
| B4 | Jede Speicherrunde: ganzes Dokument bauen und senden; lokal volle Kopie plus Versionszeile, 30 Versionen behalten | SyncEngine.swift:424-432, 495-504; AnnotationEndpoints.swift:17-18, 132-145 |
| B5 | Seite drehen behält die Koordinaten der Notizen; danach liegen sie über anderem PDF-Inhalt | DocumentStore.swift:550-560; editor.js:808; SolutionGeometry.swift:36-42 |
| B6 | PencilKit zeichnet einen Strich nicht in der gespeicherten Breite (im Simulator gemessen: Stift 3 → 2 pt, 8 → 12 pt, Bleistift 4 → 6,8 pt). Web und PDF-Export zeichnen die gespeicherte Breite – iPad-Striche sehen dort vermutlich anders aus (Folgerung, für Export und Web **n. g.**) | ForeignInkWidthTests.swift:6-8; SolutionLayer.swift:105-108; PDFExporter.swift:206-213; editor.js:538 |
| B7 | Druck, Neigung und Zeit stehen nur in `pkdrawing`; im JSON nur Breiten je Punkt. Aus JSON neu gebaute Striche haben Kraft 1, Azimut 0, Höhe 90° | StrokeConverter.swift:217-221, 433-438; annotations.schema.json:75 |
| B8 | Keine Textauswahl im PDF (Markup-Modus): kein Markieren von PDF-Text, kein „Als Karteikarte“ | PDFEditorController.swift:309; OFFEN-V1.md:49 |
| B9 | Im Browser eingefügte Bild-/PDF-Seiten nur als Platzhalter | PDFEditorController.swift:520; DisplayLayout.swift:7-8 |
| B10 | Seitenoperationen fehlen: umsortieren, duplizieren, leeren, Vorlage/Format wechseln, Einfügen vor/am Ende, Formate A6–A2 und Whiteboards bis A0 | PageOrder.swift:3-11 (nur Einfügen/Papierkorb/Wiederherstellen); PDFEditorController.swift:692-693; STAND-MAC-SITZUNG.md:561-567 |
| B11 | Dasselbe Dokument in zwei Fenstern: Mehrfenster ist an, eine Sperre für doppelt geöffnete Dokumente wurde nicht gefunden (zwei Stores auf demselben Journal) – **n. g.** | project.yml:80; DocumentView.swift:131-137 |
| B12 | Fremde Ebenen: Umschalten baut alle Ebenen auf allen Overlays neu; der Zeittest kippt unter Last | PDFEditorController.swift:181-187, 472-484; audit/RUNDE-08-221-250.md:78-81; IPAD-OHNE-PC.md:533-536 |
| B13 | Zoom-Schärfe der Tinte nicht geprüft (siehe 1.4) | PDFEditorController.swift:115-121; InkSnapshot.swift:4-7 |
| B14 | Native Zeichnung einer neueren iPadOS-Version, die dieses Gerät nicht lesen kann, wird aus JSON neu gebaut; schreibt man danach auf dieser Seite, wird `pkdrawing` mit dem neu gebauten Stand **überschrieben** (Verhalten von `PKDrawing(data:)` mit neueren Inhalten **n. g.**) | StrokeConverter.swift:114-117, 397-408 |
| B15 | Versionsverlauf (30 Stände) liegt im Backend, keine Oberfläche (auch nicht im Web) | AnnotationEndpoints.swift:68-83; app/server.py:697-709 |
| B16 | Keine Gliederung, keine Dokumentnotiz, kein Eingabefeld „Gehe zu Seite“; Vollbild blendet nur die Navigationsleiste aus | DocumentView.swift:212-219, 736-771 (Web: views-doc.js:28, 39; editor.js:815, 845-857) |
| B17 | Doku teils veraltet: Vertrags-README sagt „Text, Formen, Bilder … iPad: erhalten, noch nicht sichtbar“, das Schema „nur_web_editor_v1“, der Auftrag „PencilKit-Tinten außer Stift/Bleistift/Marker werden als Stift gespeichert“ – heute zeigt das iPad Objekte an und speichert `pkInk` | shared-contracts/README.md:47-49; annotations.schema.json:73-77; AUFTRAG-APPSTORE-V1.md:40-42; StrokeConverter.swift:463 |

---

## 2. Vergleich mit Web, Android und Windows

### 2.1 Implementierungen im Überblick

| | Apple (iPad) | Web | Android | Windows |
|---|---|---|---|---|
| Darstellung | PDFKit + PencilKit je Seite | pdf.js + Konva-Bühne je Seite, Live-Canvas, pdf-lib für Export (editor.js:1-2, 12-14, 389-410) | `PdfRenderer` als Bild einer Seite + Compose-Canvas (DocumentScreen.kt:74-91, 232-288) | Tauri-Fenster mit mitgeliefertem Python-Backend, **dieselbe Web-Oberfläche** (windows/README.md:7-9, 26-28) |
| Eingabe | PencilKit (System-Handballen, `drawingPolicy`) | Pointer-Events, eigene Handballen-Heuristik, Druck → Breite, Vorhersage (editor.js:260, 625-632) | Compose-Pointer, „Nur Stift“ (DocumentScreen.kt:234-268) | wie Web (Windows Ink über WebView2, **n. g.**) |
| Datenmodell | gemeinsames JSON v2 + `pkdrawing` | gemeinsames JSON v2 | gemeinsames JSON v2 (unbekannte Felder bleiben) | wie Web |
| Lokal sichern | Journal je Seite mit Revision | IndexedDB-Entwurf (editor.js:17-23, 573-577) | Entwurf + WorkManager (android/README.md:15) | wie Web, Daten im lokalen Backend |
| Zusammenführen | `AnnotationMerge` (Swift) | `merge.js` (Referenz) | `AnnotationMerge.kt` | `merge.js` |
| Gemeinsame Fälle | `fixtures/merge/cases.json`: 11 Seiten- und 18 Dokumentfälle (Zählung aus der Datei), geprüft in Swift (`SharedFixtureTests`), Kotlin (`SharedFixtureTest.kt`) und für das Web (`tests/js/merge.test.mjs`, `tests/test_merge_contract.py`) (shared-contracts/README.md:9-12; IPAD-OHNE-PC.md:528-529) | | | |

### 2.2 Funktionsmatrix

Spalte Windows: gleiche Web-Oberfläche im Tauri-Fenster; am Gerät **n. g.**

| Nr. | Funktion | Apple | Web | Android | Windows | Belege, Bemerkung |
|---|---|---|---|---|---|---|
| **Anzeige und Navigation** | | | | | | |
| 1 | PDF durchgehend scrollen | V | V | T (eine Seite, Knöpfe) | = Web | PDFEditorController.swift:302-304; editor.js:389-410; DocumentScreen.kt:182-185, 204-206 |
| 2 | Zoomen, Notizen bleiben an ihrer Stelle | V (Gerät n. g.) | V | – | = Web | Geometry.swift:41-65; HardeningSolutionEditorTests.swift:360; editor.js:917-925; DocumentScreen.kt:232-234 |
| 3 | Seitenübersicht mit Miniaturen inkl. Notizen | V | V | – | = Web | DocumentView.swift:900-978; editor.js:820-843 |
| 4 | Seiten per Ziehen umsortieren | – | V | – | = Web | editor.js:812, 823-824 |
| 5 | Lesezeichen | V | V | – | = Web | DocumentStore.swift:522-530; DocumentView.swift:880-889 |
| 6 | Gliederung | – (bleibt erhalten) | V | – | = Web | editor.js:815 |
| 7 | Volltextsuche im PDF | V | V | – | = Web | DocumentStore.swift:582-592; editor.js:930 |
| 8 | Seitenzahl eingeben | – | V | T (vor/zurück) | = Web | editor.js:244 |
| 9 | Einzelseite / horizontal | – | V | (nur Einzelseite) | = Web | editor.js:344, 419, 895-905 |
| 10 | Vollbild | T | V | – | = Web | DocumentView.swift:212-219; editor.js:926 |
| 11 | Zwei Dokumente nebeneinander (Übung + Skript) | V (Plus) | V | – | = Web | DocumentView.swift:188-205, 776-825; views-doc.js:43-80 |
| 12 | Passende Skriptstelle vorschlagen | V | V | – | = Web | DocumentView.swift:407-431; views-doc.js:86 |
| 13 | Zuletzt gelesene Seite merken | V | V | n. g. | = Web | DocumentView.swift:144-153; views-doc.js:37 |
| **Schreiben und Werkzeuge** | | | | | | |
| 14 | Stift mit Druck, Neigung, Vorhersage | V (System) | T (Druck → Breite, Neigung nur Bleistift) | T (feste Breite) | = Web | editor.js:625; Ink.kt:9-15 |
| 15 | Stifttypen | V (7 PencilKit-Tinten) | V (4) | T (Stift, Rot, Blau, Marker) | = Web | StrokeConverter.swift:104, 232-239; editor.js:33; Ink.kt:9-15 |
| 16 | Freie Farben, Strichstärken | V (Palette) | V (8 + eigene, 0,5–40) | – (fest) | = Web | editor.js:34-35, 351 |
| 17 | Textmarker | V | V (Multiplizieren) | T (gelb fest) | = Web | StrokeConverter.swift:100-101, 255-264; PDFExporter.swift:172-181 |
| 18 | Radierer | V (Pixel und Strich) | V (teilweise, ganzer Strich, Objekte; 3 Größen) | T (ganzer Strich) | = Web | StrokeConverter.swift:412-421; editor.js:732-751; DocumentScreen.kt:242-251 |
| 19 | Lasso | T (nur Striche) | V (alle Objekte, kopieren, duplizieren, Farbe, Breite) | – | = Web | editor.js:357, 753-761 |
| 20 | Lineal | V (Palette, Gerät n. g.) | V | – | = Web | editor.js:935-952 |
| 21 | Formen | T (nur Anzeige) | V (6 Arten) | – | = Web | PageObjects.swift:66-109; editor.js:356, 727-730 |
| 22 | Textfelder mit Format | T (anlegen fest, nicht bearbeitbar) | V | – (Hinweis) | = Web | DocumentStore.swift:562-578; editor.js:353-355, 764-781; Ink.kt:101-105 |
| 23 | Haftnotizen | T (nur Anzeige) | V | – | = Web | editor.js:765 |
| 24 | Bild einfügen / einfügen aus Zwischenablage | T (nur Anzeige) | V | – | = Web | DocumentStore.swift:400-410; editor.js:782-791 |
| 25 | Rückgängig / Wiederholen | V (dokumentweit, 150) | V (150) | – | = Web | PDFEditorController.swift:267; editor.js:561-565 |
| 26 | „Nur Stift“ / Finger zeichnet | V | V | V | = Web | PDFEditorController.swift:239-245; editor.js:864; DocumentScreen.kt:201, 239 |
| 27 | Handballen | V (System, Gerät n. g.) | V (Heuristik) | n. g. | = Web | editor.js:260 |
| 28 | Pencil-Doppeltippen, Squeeze, Hover | n. g. (kein eigener Code) | – | – | – | Abschnitt 1.3 |
| 29 | Handschrift zu Text | T (Scribble nur in Textfeldern des Systems) | – | – | – | – |
| 30 | Schreiblupe (Zoom-Ansicht) | – | V | – | = Web | editor.js:953-957 |
| 31 | Tastaturkürzel | T (⌘Z/⇧⌘Z über den Verlauf) | V | – | = Web | PDFEditorController.swift:247-257; editor.js:1021-1035 |
| 32 | Werkzeugleiste anpassen | – (Systempalette) | V | – | = Web | editor.js:910 |
| **Seiten** | | | | | | |
| 33 | Leere Seite mit Vorlage | V (6 Vorlagen, danach) | V (vor/nach/Ende) | – | = Web | PDFEditorController.swift:679-702; editor.js:794, 874 |
| 34 | Seite drehen | V (Notizen verrutschen, B5) | V (ebenso) | – | = Web | DocumentStore.swift:550-560; editor.js:808 |
| 35 | Papierkorb, wiederherstellen | V | V | – | = Web | PageOrder.swift:103-173; editor.js:809-810 |
| 36 | Seite duplizieren, leeren, Vorlage/Format wechseln | – | V | – | = Web | editor.js:796, 807, 811, 813 |
| 37 | PDF-Seiten importieren, Bild als Seite | – (Platzhalter) | V | – | = Web | editor.js:816-817; PDFEditorController.swift:520 |
| 38 | Notizbuch/Whiteboard ohne PDF | V (Formate A6–A0 fehlen) | V | n. g. | = Web | DocumentStore.swift:254-265; formats.js:4-16 |
| **Ebenen und Community** | | | | | | |
| 39 | Eigene Notizen ausblenden (nur ansehen) | V | – | – | – | PDFEditorController.swift:196-208 |
| 40 | Fremde Lösung als Ebene, einzeln schaltbar | V | – | – | – | DocumentView.swift:571-622 |
| 41 | Lösung als Datei teilen/importieren (nur eigene Notizen, verschlüsselt) | V | – | – | – | LOESUNGEN-TEILEN.md:11-23, 58-110 |
| 42 | Community (veröffentlichen, finden, laden, zurückziehen, melden, blockieren, Lerngruppen) | V (CloudKit; echt nur mit Container, n. g.) | T (Dienst-Seite: eigene Veröffentlichungen, Sperren, Moderation) | – | – | CommunityCloudKit.swift:246-422; VERTRAEGE-KONTO-SYNC.md:222-263; OFFEN-V1.md:55-56 |
| 43 | Kommentare/Fragen je Seite oder Aufgabe | – | – | – | – | keine Treffer im Code |
| **Speichern und Abgleich** | | | | | | |
| 44 | Automatisch lokal sichern | V | V | V | = Web | Abschnitt 1.5; editor.js:570-577 |
| 45 | Offline arbeiten | V | T (Entwurf, kein Service Worker) | T | = Web | PLATTFORM-STAND-2026-10-26.md:26, 43 |
| 46 | Drei-Wege-Zusammenführung nach gemeinsamen Fällen | V | V | V | = Web | AnnotationMerge.swift:3-22; merge.js:1-8; AnnotationMerge.kt:102-141 |
| 47 | Konflikt der Seitenreihenfolge sichtbar | V | V | V | = Web | DocumentView.swift:1193-1196; editor.js:133 |
| 48 | Abgleich zwischen Geräten über Konto (G2) | – (V1 bewusst) | V (gehosteter Dienst) | T (Kern-Client) | – (lokales Backend) | Migrations.swift:12-15; VERTRAEGE-KONTO-SYNC.md:190-220 |
| 49 | Versionsverlauf mit Wiederherstellen | G (Backend ja, Oberfläche nein) | G | – | G | AnnotationEndpoints.swift:68-83 |
| 50 | Neue PDF-Fassung, Notizen umhängen | V (nur iPad) | – (PC behält alte Seitenzahlen) | – | – | NoteTransfer.swift:3-16; FileVersions.swift:3-4 |
| 51 | PDF-Export mit Notizen | V (ganzes Dokument, Seite; Vektor) | V (+ Bereich, ohne Notizen, Drucken) | – | = Web | PDFExporter.swift:5-46; editor.js:889-894, 989 |
| 52 | Dokumentnotiz (Freitext) | – (bleibt erhalten) | V | – | = Web | views-doc.js:28, 39 |
| 53 | KI-Tutor | – (V1 bewusst) | V | – | = Web | AUFTRAG-APPSTORE-V1.md:44-45; editor.js:971 |
| 54 | Audio-Aufnahme zur Seite | – | V | – | = Web | editor.js:960-969 |

### 2.3 Was anderswo besser ist

- **Web:** echtes Objekt-Bearbeiten (Text mit Schrift, Größe, Format, Ausrichtung, Hintergrund; Formen; Bilder;
  Haftnotizen), Lasso über alle Objektarten mit Kopieren/Duplizieren/Farbe/Breite, alle Seitenoperationen inkl.
  Umsortieren per Ziehen und Formaten, Gliederung und Dokumentnotiz, Schreiblupe, eigenes Lineal mit Einrasten,
  Export mit Seitenbereich und „ohne Notizen“, Tastaturkürzel, anpassbare Werkzeugleiste, Obergrenzen beim Sichern
  (Belege in 2.2).
- **Android:** nichts Wesentliches besser; einfache, robuste Entwurfs-Nachlieferung über WorkManager
  (android/README.md:15, 25-47).
- **Apple ist besser bei:** Tintenqualität und Latenz (System), Handballen (System), Ebenen und Ansichtsmodus,
  Lösung teilen und Community, neue PDF-Fassungen mit umgehängten Notizen, Journal mit Revisionen und sichtbarem
  Speicherstatus, Härtetests.

### 2.4 Was plattformübergreifend gleich sein soll

| Gleich auf allen Plattformen | Heute | Beleg |
|---|---|---|
| Notizformat v2 (Objekte, `pageOrder`, Papierkorb, Lesezeichen, Gliederung, Notiz), unbekannte Felder bleiben | ja | annotations.schema.json:5-72; shared-contracts/README.md:24-30 |
| Koordinaten: Punkte der angezeigten Seite, Ursprung oben links, ohne Zoom | ja (Web, iPad); Android ohne Transformation | Geometry.swift:6-8; editor.js:2; AnnotationDocument.kt:66 |
| Zusammenführungsregeln und Konfliktanzeige | ja (drei Sprachen, gleiche Fälle) | merge.js:1-8 |
| Werkzeug ↔ Tinte, Marker-Deckkraft | ja | StrokeConverter.swift:232-264 |
| Vorlagen-Geometrie (Abstände, Farben) | ja (iPad gegen Web getestet) | PageOrder.swift:175-253; PageOrderTests.swift:183-236 |
| Seitenformate (A6–A2, Whiteboards, Grenzen 100–3400 pt) | nur Web | formats.js:4-21 |
| Aussehen beim Export (Strich, Marker, Bleistift gestrichelt) | ja, Export bildet `makeInkShape` nach | PDFExporter.swift:172-181 |
| Regel beim Drehen, Regel bei neuen PDF-Fassungen | Drehen gleich (aber verrutscht, B5); Fassungen nur iPad | B5; FileVersions.swift:3-4 |
| Statusbegriffe (Gespeichert, Offline, Konflikt) | ähnlich | SyncEngine.swift:56-66; editor.js:575 |

**Nicht gleich sein muss:** die Bedienung (native Palette auf Apple, eigene Leisten im Web) und die
PencilKit-Pinselstruktur (nur Apple, als Zusatz `pkdrawing`).

---

## 3. Fehlende und übernehmbare Funktionen

| Funktion | Vorbild | Übernahme in die Apple-App | Begründung |
|---|---|---|---|
| Textfelder bearbeiten (Schrift, Größe, Farbe, fett/kursiv/unterstrichen, Ausrichtung, Hintergrund, Zeilenabstand) | editor.js:353-355, 764-781 | **nativ nachbauen** (UITextView, gleiche JSON-Felder wie `DEFAULT_TEXT`, editor.js:59) | Datenmodell und Anzeige existieren schon (PageObjects.swift:114-147, 288-304) |
| Haftnotiz | editor.js:765 | nativ (Text mit Hintergrund `#fff7a8`) | Sonderfall von Text |
| Objekt-Lasso (Text, Formen, Bilder) | editor.js:753-761 | nativ, getrennt vom PencilKit-Lasso | PencilKit erfasst nur `PKStroke` |
| Formen | editor.js:727-730 | nativ (gleiche Formarten) | Anzeige existiert (PageObjects.swift:66-109) |
| Bild einfügen, Screenshot einfügen | editor.js:782-791 | nativ (Fotos, Zwischenablage → `POST /api/files/{id}/assets`, lokal vorhanden) | AnnotationEndpoints.swift:87-101 |
| Seiten umsortieren, duplizieren, leeren, Vorlage/Format wechseln, vor/nach/Ende einfügen | editor.js:792-813, 874 | **im Kern** `PageOrder` als reine Funktionen, gegen das Web getestet | Muster existiert (PageOrder.swift:73-173; PageOrderTests.swift) |
| Bild-/PDF-Seiten aus dem Web anzeigen | editor.js:816-817 | nativ (Asset laden, als `PDFPage`/Bild) | heute Platzhalter (B9) |
| Gliederung, Dokumentnotiz, Seitenzahl eingeben | editor.js:815, 243; views-doc.js:39 | nativ (Seitenleiste, Notizspalte) | Felder bleiben schon erhalten |
| Export: Seitenbereich, ohne Notizen | editor.js:889-894 | nativ (`PDFExporter.render(pageIndices:)` kann es schon) | PDFExporter.swift:16-19 |
| Tastaturkürzel | editor.js:1021-1035 | System (`.keyboardShortcut`, `UIKeyCommand`) | iPad mit Tastatur |
| Schreiblupe | editor.js:953-957 | P2, nur wenn am Gerät gewünscht | PDFKit-Zoom ersetzt sie teilweise |
| Lineal | editor.js:935-952 | **nicht übernehmen**, PencilKit-Lineal nutzen | Systemfunktion |
| Handballen-Heuristik, Canvas-Speichergrenze, Konva-Puffer-Patch | editor.js:27-46, 260 | **nicht übernehmen** | Safari-spezifisch |
| KI-Tutor, PDF-Text für KI | editor.js:225-233, 971 | **nicht in V1** | Entscheidung des Inhabers (AUFTRAG-APPSTORE-V1.md:44-45) |
| Audio-Aufnahme | editor.js:960-969 | P2, Entscheidung des Inhabers | Datenschutz, Speicher |

---

## 4. PencilKit-Erweiterungsplan

### 4.1 Leitplanken

1. **PencilKit bleibt die Grundlage** für Tinte, Radierer, Lasso der Striche, Lineal und Palette. Keine eigene
   Canvas-Engine, keine Änderung an Eingabeweg oder Rendering der Tinte.
2. **Erweiterungen als eigene Bausteine** neben der Canvas, nie in `InkCanvasView` hinein. Die Objektschicht gibt es
   schon (`PageObjectsView`); sie wird bearbeitbar, die Canvas bleibt, wie sie ist.
3. **Kein Notizverlust:** jede neue Schreibfunktion geht über `DocumentStore` → `SyncEngine.updatePage` (Journal mit
   Revision), nach `settlePending()` (DocumentStore.swift:709-720) – derselbe Weg wie `addText`
   (DocumentStore.swift:562-578). `StrokeConverter.update` übernimmt Nicht-Strich-Objekte unverändert
   (StrokeConverter.swift:387-391), Tinte und Objekte kommen sich also nicht in die Quere.
4. **Gleiches JSON wie das Web** für jedes neue Objekt; Felder aus `addNode`/`DEFAULT_TEXT` (editor.js:59, 500-531).
5. **Tarif und Ansichtsmodus** gelten auch für neue Werkzeuge (`writable`, PDFEditorController.swift:230-231;
   `isWritable`, DocumentStore.swift:235-236).

### 4.2 Bausteine

| Baustein | Inhalt | Anknüpfung |
|---|---|---|
| E1 Speicher-Härtung | Obergrenze der Entprellung, Formatschutz, Herkunftsstempel, Doppel-Fenster-Sperre, Schutz fremder nativer Daten | DocumentStore, StrokeConverter, AnnotationDocument |
| E2 Objektschicht | Text, Haftnotiz, Formen, Bilder anlegen, wählen, verschieben, skalieren, drehen, formatieren, löschen; eigener Verlauf je Seite | `PageObjectsView` → bearbeitbar; Geometrie aus `ObjectGeometry` (PageObjects.swift:7-219) |
| E3 Werkzeugmodus | Umschalter **Tinte** (PencilKit, unverändert) / **Objekte** (Canvas ohne Eingabe, Objektschicht nimmt Gesten an) – wie `setOwnNotesVisible` (PDFEditorController.swift:104-110) | Controller, eigene kleine Leiste |
| E4 Seitenwerkzeuge | `PageOrder` um verschieben, duplizieren, leeren, Vorlage/Format erweitern; Ziehen in der Miniaturleiste | PageOrder.swift; DocumentView.swift:905-978 |
| E5 Navigation | Seitenzahl, Gliederung, Dokumentnotiz, Vollbild | DocumentView |
| E6 Ebenen | „Original ausblenden“, fremde Ebenen per Unterschied statt Neuaufbau, eine Anzeige-Canvas je Seite für alle fremden Ebenen | PDFEditorController.swift:181-187, 472-484 |
| E7 Pencil-Interaktion | Doppeltippen/Squeeze nur dort, wo die Systempalette sie nicht schon behandelt; Hover-Vorschau für Objektwerkzeuge | erst nach Gerätetest |
| E8 Handschrift zu Text | Lasso-Auswahl → Bild → Texterkennung → Textobjekt | P2, Qualität n. g. |

**Eingabe-Aufteilung (wichtigster Punkt für das Schreibgefühl):** Die Canvas liegt oben (PDFEditorController.swift:83-85).
Im Modus **Tinte** bleibt alles wie heute. Im Modus **Objekte** bekommt die Canvas keine Eingabe
(`isUserInteractionEnabled = false`, wie im Ansichtsmodus), die Objektschicht nimmt Tippen, Ziehen und Zwei-Finger-
Gesten; Scrollen mit dem Finger bleibt bei PDFKit. Nach dem Platzieren eines Textfelds springt der Modus zurück zur
Tinte. Damit berührt die Erweiterung PencilKit nicht.

**Rückgängig für Objekte:** eigene Ziele je Seite, z. B. Schlüssel `<seite>#objekte`, damit ein Objekt-Schritt nie die
Zeichnung zurücksetzt und umgekehrt (heute setzt ein Tinten-Schritt die ganze `PKDrawing`,
PDFEditorController.swift:583-593).

### 4.3 A. PDF und Vorlesung

| Thema | Stand Apple | Vorschlag |
|---|---|---|
| Beschriften | V Tinte, T Text (B1) | E2 Objektschicht |
| Durchgehende Navigation | V Scrollen; – Seitenzahl, Gliederung | E5 |
| Seitenübersicht mit Vorschaubildern | V (Miniaturen mit Notizen, 60 im Speicher, DocumentView.swift:984-994) | Umsortieren, Seitenmenü (E4) |
| Vorlesung und Übung verknüpfen, verlustfrei wechseln | V Skriptvorschlag und geteilte Ansicht (Plus); jedes Dokument eigener Store, Wechsel sichert vorher (DocumentView.swift:341-347, 822) | Verknüpfung **merken**: optionales Feld `links` im Dokument (Abschnitt 5.3); „zuletzt daneben geöffnet“ anbieten |
| Zwei Dokumente nebeneinander | V | zusätzlich iPadOS-Fenster prüfen (B11) |
| Zoomen ohne verrutschende Zeichnungen | V im Simulator (Seitenpunkte; fremde Ebenen bei 0,25–4 getestet, HardeningSolutionEditorTests.swift:360-380) | Gerätetest, Schärfe (B13) |
| Notizen je Seite | T (Lesezeichen; Text fest) | zuerst Haftnotiz (existiert im Web und im Format), Seitennotiz-Feld nur bei Bedarf |
| Eigene leere Seiten | V (6 Vorlagen, danach) | Formate A6–A2 und Whiteboards, vor/nach/Ende (E4) |
| Ebenen Original / eigene Notizen / Community | T: eigene und fremde schaltbar, Original nicht | „Original ausblenden“ (weiße Fläche unter der Objektschicht im Overlay), E6 |

### 4.4 B. Werkzeuge

| Werkzeug | PencilKit liefert | Selbst bauen | Stand Apple | Vorschlag |
|---|---|---|---|---|
| Stifte, Farben, Strichstärken | ja (Palette, inkl. eigener Farben) | nein | V | so lassen |
| Textmarker | ja | nein | V | Breite/Deckkraft gegen Web messen (B6) |
| Radierer | ja (Pixel und Strich) | Objekt-Radierer für Text/Formen | V / – | Objekt-Radierer im Modus Objekte |
| Lasso | ja, nur Striche | Objekt-Lasso | T | E2 |
| Lineal | ja | nein | V (n. g.) | Gerätetest (1.4 Punkt 3) |
| Formen | nein | ja | T | E2, gleiche Formarten wie Web |
| Textfelder | nein | ja | T | E2 |
| Rückgängig | ja, aber abgeschaltet (hing an der Canvas) | eigener Verlauf je Seite existiert | V | um Objekt-Schritte erweitern |
| Handschrift zu Text | Scribble nur in Texteingaben des Systems | Umwandeln von Strichen in Text | T | E8 (Vision-Texterkennung auf gerenderter Auswahl), P2 |
| Doppeltippen, Squeeze, Hover | System-Verhalten der Palette, in dieser Anordnung n. g. | eigene Aktionen nur für Objektwerkzeuge | n. g. | E7 nach Gerätetest |
| Eigene Werkzeugleiste | Systempalette; eigene Einträge in der Palette laut Apple-Dokumentation erst ab iPadOS 18 (`PKToolPickerCustomItem`, im Repo nicht prüfbar) | kleine eigene Leiste für Objekt-Werkzeuge | – | eigene Leiste ab 17, Paletten-Einträge hinter `#available` |
| Tastatur und Handschrift im selben Dokument | – | Textobjekte und Tinte auf derselben Seite (Format kann das schon) | T | E2 + Kürzel |

### 4.5 iPadOS-Version

Mindestversion bleibt **17.0** (project.yml:7). Alles, was danach kommt (Squeeze ab 17.5, Paletten-Einträge ab 18
laut Apple), nur hinter `if #available`. Ob die Mindestversion angehoben wird, entscheidet der Inhaber. Vor dem Einsatz
neuer APIs die SDK-Version des Macs prüfen (n. g.).

---

## 5. Notizformat und Sync-Architektur

### 5.1 Heutiges Format (C): `annotations.data`, Version 2

| Teil | Inhalt | Beleg |
|---|---|---|
| Wurzel | `version: 2`, `zoom`, `note`, `bookmarks`, `outline`, `deletedPages`, `pageOrder`, `pages`; unbekannte Felder müssen erhalten bleiben | annotations.schema.json:1-30; AnnotationDocument.swift:3-18 |
| `pageOrder[]` | `key`, `type` (pdf/blank/asset), `index` (1-basiert), `rotation`, `template`, `w`, `h` | annotations.schema.json:16-30 |
| `pages[key].objects[]` | `stroke`, `text`, `shape`, `image`; Lage `x, y, rotation, scaleX, scaleY` (skalieren → drehen → verschieben); Strich `tool, color, width, widths[], opacity, points[]`, iPad zusätzlich `pkInk`, `source` | annotations.schema.json:53-71 |
| `pages[key].pkdrawing` | native Zeichnung Base64 mit `objectsSig`, `strokeIds`; ab v2 `strokeSigs` je Strich: ein im Browser geänderter Strich wird allein neu aufgebaut | AnnotationDocument.swift:92-151; StrokeConverter.swift:6-25 |
| `origin` | Herkunftsstempel (Inhalts-Hash, Seitenzahl, Fassung) – **nur nach einer neuen Original-Fassung** | NoteTransfer.swift:15-16, 142-143 |
| Speicherort | ein JSON-Text je Datei in `annotations(file_id)`, 30 Versionen in `annotation_versions` | db.py:54-66; AnnotationEndpoints.swift:132-145 |
| Dokument-ID | `file_id` der Hochschule (z. B. Stud.IP-Datei-ID); PDF-Fingerabdruck SHA-256 der Original-Bytes für Community und Herkunft | UniStore.swift:130-133; DocumentStore.swift:602-612 |

### 5.2 Befunde zum Format

| Nr. | Befund | Folge | Beleg |
|---|---|---|---|
| F1 | Regel „neuere `version` nur lesen“ nicht umgesetzt; Web-`migrate` behandelt alles außer `version: 2` als Altformat | ein v3-Dokument erschiene im Web leer und würde beim nächsten Strich überschrieben | shared-contracts/README.md:26-27; editor.js:172-187 |
| F2 | Druck, Neigung, Zeitstempel nur in `pkdrawing` | außerhalb von Apple nur Breiten je Punkt; nach einer Web-Änderung verliert der Strich auf dem iPad seinen Druckverlauf | StrokeConverter.swift:217-221; annotations.schema.json:75 |
| F3 | Strichbreite: PencilKit-Darstellung ≠ gespeicherte Breite | Web/Export weichen ab (B6) | ForeignInkWidthTests.swift:6-8 |
| F4 | `origin` nur nach neuer Fassung | Zuordnung Notizen ↔ PDF-Fassung erst ab der zweiten Fassung prüfbar | DocumentStore.swift:497-503 |
| F5 | Drehung ändert die Bedeutung der Koordinaten | Notizen verrutschen (B5) | SolutionGeometry.swift:36-42 |
| F6 | Native Daten anderer iPadOS-Versionen können überschrieben werden | Pinselbild geht verloren (B14) | StrokeConverter.swift:114-117 |
| F7 | Neue Fassungen umhängen nur in Swift | nach einem Geräte-Abgleich könnten PC und iPad verschieden zuordnen | FileVersions.swift:3-4 |

### 5.3 Vorschlag: gemeinsames Annotationsmodell (bleibt Version 2)

**Zwei Schichten je Seite, wie heute, mit klaren Rollen:**

1. **Kanonisch, alle Plattformen:** `objects` (Vektordaten). Maßgeblich für Bearbeiten, Zusammenführen, Export und
   jede Darstellung ohne PencilKit.
2. **Nativ, nur Apple:** `pkdrawing` v2. Maßgeblich für die Darstellung auf Apple (Druck, Neigung, Pinsel), je Strich
   gültig über `strokeSigs`. Wird nie geteilt (Lösungspakete lassen es weg, LOESUNGEN-TEILEN.md:107) und nie von
   anderen Plattformen geschrieben.

**Ergänzungen, alle optional und rückwärtskompatibel** (neue optionale Felder sind keine neue Version,
shared-contracts/README.md:17-21; Web, Swift und Kotlin reichen unbekannte Felder durch, editor.js:174-175;
AnnotationDocument.kt:12-15):

| Feld | Ort | Zweck | Schreibt | Liest |
|---|---|---|---|---|
| `origin {sha256, pages, version}` | Wurzel | Dokumentzuordnung **immer** setzen (beim ersten Speichern), nicht erst nach neuer Fassung | alle | alle (Prüfung beim Öffnen wie DocumentStore.swift:499-503) |
| `pressures[]` (0…1 je Punkt) | Strich | Druck plattformübergreifend; gleiche Länge wie Punkte, sonst ignorieren | Apple aus `PKStrokePoint.force`, Web aus Pointer-Druck | Web, Android, Export (Breitenverlauf); Apple beim Neuaufbau aus JSON statt Kraft 1 |
| `pkdrawing.requiredContentVersion` | Seite | lesbare native Daten erkennen; nicht lesbare **unverändert durchreichen** statt überschreiben | Apple | Apple |
| `links[] {key, fileId, pdfPage, kind}` | Wurzel | Übung ↔ Skript merken | Apple, Web | Apple, Web |
| `pages[key].note` | Seite | Seitennotiz, nur falls Haftnotizen nicht reichen | später | später |

**Regeln dazu:**

- Arrays je Punkt (`widths`, `pressures`) werden beim Teilen eines Strichs (Pixel-Radierer, Teil-Radierer im Web)
  mitgeteilt; Web tut das heute für `widths` (editor.js:744), für `pressures` müsste es nachziehen.
- **Breitenfrage (F3) erst messen**, dann entscheiden: (a) Darsteller ohne PencilKit rechnen Striche mit
  `source: "pencilkit"` und `pkInk` über eine gemessene Tabelle um, oder (b) Apple schreibt die sichtbare Breite und
  rechnet beim Neuaufbau zurück. Beides ändert den Vertrag; Fixtures zuerst.
- **Vor jeder späteren Version 3** muss F1 auf allen Plattformen umgesetzt sein.
- Drehen (F5): als **Bearbeitungsschritt** lösen, nicht als Formatänderung – beim Drehen einer Seite werden ihre
  Objekte mitgedreht (Abbildung existiert: SolutionGeometry.swift:52-64); bei Strichen mit `pkdrawing` über
  `PKStroke.transform`. Web und iPad gleich, mit gemeinsamem Fixture.
- Größe: `pkdrawing` je Seite erst messen (Abschnitt 7.6), dann über Kompression oder eigene Ablage entscheiden.

### 5.4 Heutige Synchronisation (D)

| Ebene | Stand | Beleg |
|---|---|---|
| Gerät: Journal je Seite mit Revision, Basis für Konflikte, Bestätigungen | V | LocalJournal.swift:3-35; SyncEngine.swift:131-146 |
| Gerät ↔ lokales Backend (V1) bzw. PC-Server (nur Debug) per `base_version` und 409 | V | APIClient.swift:181-205; AnnotationEndpoints.swift:5-13 |
| Konto (G1) | Vertrag und Python V; iPad – (V1 ohne Konto, M13) | VERTRAEGE-KONTO-SYNC.md:130-155; AUFGABENTEILUNG-APPLE-PC.md:91 |
| Geräte-Abgleich (G2): Spalten, Trigger, Tombstones, `GET /api/sync/changes`, `POST /api/sync/push`; Notizen wie `PUT …/annotations` | Python V, Kotlin-Kern V, iPad – (M14) | VERTRAEGE-KONTO-SYNC.md:190-220; app/sync.py:245-264; AUFGABENTEILUNG-APPLE-PC.md:92 |
| Hochschul-PDFs | lädt jedes Gerät selbst, nicht im Sync; eigene Dokumente mit Inhalt „folgen später“ | VERTRAEGE-KONTO-SYNC.md:199-202 |
| Status und Gründe sichtbar (offline, PIN, Zugriff, Serverfehler, Konflikte, Reihenfolge) | V | SyncEngine.swift:39-120; DocumentView.swift:1185-1239 |

### 5.5 Vorschlag Sync-Architektur

**Grundsatz:** Der Editor schreibt weiter nur über `SyncEngine` ins **lokale** Backend. Der Abgleich zwischen Geräten
läuft eine Ebene darunter (Datenbank ↔ Dienst), wie im Android-Kern. So bleibt der erprobte Schreibweg unverändert.

```
PencilKit-Canvas ─► DocumentStore ─► SyncEngine ─► lokales Backend (SQLite, annotations)
                                                        │
                                       G2-Client (neu)  ▼  Push/Pull mit base_version je Datei
                                                   UniFlow-Dienst (gehostet, Konto)
```

| Thema | Vorschlag |
|---|---|
| Dokument-IDs | `file_id` der Hochschule + `origin.sha256`; eigene Notizbücher brauchen vor dem Abgleich eine weltweit eindeutige ID (VERTRAEGE-KONTO-SYNC.md:201) |
| Bildschirmgrößen, Zoom, Gerätedrehung | keine Rolle: alles in Seitenpunkten (Geometry.swift:6-37); Zoomregeln nur Anzeige (Geometry.swift:39-65) |
| PDF-Koordinaten | wie heute; Drehung als Bearbeitungsschritt (5.3); Android muss Transformation und Breiten anwenden |
| Offline | wie heute (Journal, lokales Backend); G2-Client mit Warteschlange und Wiederholung |
| Automatisches Speichern | wie heute plus Obergrenze der Entprellung (B3) |
| Konflikte | G2 meldet bei Notizen `conflict` mit `data/version` (app/sync.py:253-254); der Client führt mit `mergeDocument` zusammen – dafür eine **eigene Server-Basis je Datei** speichern (die Basis im Journal gilt gegenüber dem lokalen Backend, nicht gegenüber dem Dienst) |
| Änderung, während das Dokument offen ist | G2-Client meldet geänderte Datei → offener Store holt neu (`remoteChanged`, DocumentStore.swift:486-495); Neuladen nie mitten im Strich (PDFEditorController.swift:534-535) |
| Wiederherstellung | Journal + Meldung beschädigter Dateien (V); zusätzlich Verlauf in der Oberfläche |
| Versionierung und Verlauf | Versionen seltener, aber länger: z. B. höchstens eine je 5 min plus beim Schließen (Vertragsänderung in Python und Swift gemeinsam); Wiederherstellen über `SyncEngine`, nie am Journal vorbei |
| Datenmenge | erst messen; wenn nötig Ablage und Abgleich **je Seite** (neue G2-Entität), Python zuerst |
| Neue PDF-Fassungen | S7-Regeln (PageMatch, NoteTransfer) als gemeinsamer Vertrag mit Fixtures, bevor Geräte abgleichen |
| Sicherheit | Sitzungs-Token nur im Schlüsselbund, nie in Logs oder Fehlermeldungen (heute kürzen Fehlermeldungen Antworttexte nur, APIClient.swift:200-203) |

### 5.6 E. Community

| Thema | Stand | Beleg |
|---|---|---|
| Nur eigene Notizen teilen, nie die PDF; verschlüsselt mit Schlüssel aus den PDF-Bytes | V | LOESUNGEN-TEILEN.md:58-110 |
| Veröffentlichen (Modul, Lerngruppe, anonym), finden, laden, zurückziehen, melden, blockieren, Lerngruppen mit Code/QR | V (CloudKit; echt nur mit Container und Developer Program) | CommunityCloudKit.swift:246-422; LOESUNGEN-TEILEN.md:230-300; OFFEN-V1.md:55-56 |
| Ebenen einblenden und umschalten | V | DocumentView.swift:571-622 |
| Private Notizen standardmäßig privat | V (nichts wird ohne Teilen-Dialog hochgeladen) | LOESUNGEN-TEILEN.md:11-23 |
| Berechtigung | Kenntnis der Kurs-ID oder des Kursnamens (Entscheidung Inhaber) | LOESUNGEN-TEILEN.md:254 |
| Plattformübergreifend | CloudKit nur Apple; Dienst G4 (Python) gebaut; Android/Windows ohne Client | VERTRAEGE-KONTO-SYNC.md:222-263 |
| Kommentare/Fragen je Seite oder Aufgabe | – | – |

**Vorschlag:** (1) Community-Ebenen effizienter (E6) und „Lösungen vergleichen“ (zwei Ebenen nebeneinander
einblenden). (2) Kommentare/Fragen erst nach Entscheidung des Inhabers zur Moderation: eigener Datensatz je Lösung oder
je `fingerprint + PDF-Seite`, Melden und Blockieren wie bei Lösungen, Text begrenzt, nie Klarnamen. (3) Später hinter
`CommunityService` auf den Dienst G4 wechseln, damit Android/Windows teilnehmen. (4) `pkdrawing` bleibt aus Paketen
draußen (fremde Binärdaten nicht dekodieren); die Breite fremder Striche stimmt schon (ForeignInkWidthTests.swift).

---

## 6. Priorisierte Reihenfolge

### 6.1 Plan

| ID | Funktion | Bereits vorhanden? | Technisch möglich? | Empfohlene Umsetzung | Aufwand | Risiko | Priorität |
|---|---|---|---|---|---|---|---|
| P0-1 | Gerätetest Schreiben, Zoom, Handballen, Palette, Lineal, Doppeltippen | Checkliste ja, nie durchgeführt (MAC-IPAD-CHECKLISTE.md:3) | ja (Inhaber mit iPad und Pencil) | Checkliste 1–18 abarbeiten, Instruments (Zeitprofil, Speicher), Ergebnisse in `STAND-MAC-SITZUNG.md` | M | hoch, wenn ausgelassen | P0 |
| P0-2 | Messung große Dokumente (100–500 Seiten, 10 000+ Striche) | nein (Tests 4–10 Seiten, Mock-Server) | ja | Leistungstest mit echtem lokalem Backend: Zeit je Speicherrunde, Dokumentgröße, Spitzenspeicher, Strukturwechsel | M | mittel | P0 |
| P0-3 | Obergrenze beim Sichern | nein (B3) | ja | spätestens alle ~2 s verarbeiten, auch bei Dauerschreiben; Test mit Strichtakt 100 ms | S | niedrig | P0 |
| P0-4 | Formatschutz „neuere Version nur lesen“ | Regel ja, Code nein (F1) | ja | Swift, Web, Kotlin: `version > 2` → Ansichtsmodus, nie speichern; Fixture | S | niedrig | P0 |
| P0-5 | Herkunftsstempel immer | teilweise (F4) | ja | `origin` beim ersten Speichern; Prüfung beim Öffnen wie heute | S | niedrig | P0 |
| P0-6 | Gleiches Dokument in zwei Fenstern | nein (B11, n. g.) | ja | Verzeichnis offener Dokumente je Container; zweites Fenster nur ansehen oder gleicher Store | S–M | mittel | P0 |
| P0-7 | Drehen ohne Verrutschen | nein (B5) | ja | Objekte beim Drehen mitdrehen (SolutionGeometry), Web gleich, gemeinsames Fixture | M | mittel (Zusammenführung bei gleichzeitiger Änderung) | P0 |
| P0-8 | Fremde native Daten nicht überschreiben | nein (B14) | ja, Verhalten von PencilKit n. g. | `requiredContentVersion` merken, unlesbare Striche durchreichen | M | mittel | P0 |
| P0-9 | Speicherlast je Runde senken (nach P0-2) | nein (B4) | ja, Vertragsänderung | Versionen seltener; bei Bedarf Ablage je Seite | M–L | mittel (Parität Python/Swift) | P0 |
| P0-10 | Zoom-Schärfe (nach P0-1) | n. g. (B13) | ja | falls unscharf: Canvas-Zoom statt Transform, mit Lagetests | M | mittel | P0 |
| P0-11 | S7-Regeln als gemeinsamer Vertrag | nur Swift (F7) | ja | Fixtures, Python-Referenz, dann Kotlin | M | mittel | P0 (vor V2-Sync) |
| P0-12 | G2-Sync-Client iPad für Notizen | Vertrag, Python, Kotlin ja; iPad nein | ja, braucht Konto (G1) und Hosting | Datenbank-Ebene wie Android, eigene Server-Basis je Datei, Benachrichtigung offener Dokumente | L–XL | hoch | P0 (V2) |
| P1-1 | Seitenwerkzeuge: umsortieren, duplizieren, leeren, Vorlage/Format, vor/nach/Ende, Formate A6–A0 | nein (B10) | ja | `PageOrder` erweitern (gegen editor.js:792-813), Ziehen in Miniaturen | M | niedrig (A0: Speicher n. g.) | P1 |
| P1-2 | Navigation: Seitenzahl, Gliederung, Dokumentnotiz, Vollbild | teilweise (B16) | ja | Seitenleiste mit Reitern wie Web, Notizspalte | M | niedrig | P1 |
| P1-3 | Asset-Seiten aus dem Web anzeigen | Platzhalter (B9) | ja | Asset laden, als PDF-Seite/Bild einsetzen | M | niedrig | P1 |
| P1-4 | Werkzeugmodus Tinte/Objekte (Grundlage für P1-5 bis P1-7) | nein | ja | E3, Canvas ohne Eingabe im Objektmodus | M | mittel (Schreibgefühl, am Gerät prüfen) | P1 |
| P1-5 | Textfelder anlegen und bearbeiten | teilweise (B1) | ja | E2 mit UITextView (Scribble automatisch), gleiche Felder wie Web | L | mittel | P1 |
| P1-6 | Haftnotizen | Anzeige | ja | auf P1-5 aufbauen | S | niedrig | P1 |
| P1-7 | Objekt-Lasso (Text, Formen, Bilder) | nein (B2) | ja | E2, getrennt vom PencilKit-Lasso | L | mittel | P1 |
| P1-8 | Geteilte Ansicht: Verknüpfung merken | Ansicht ja, Verknüpfung nein | ja | Feld `links`, „zuletzt daneben“ | S–M | niedrig | P1 |
| P1-9 | Community-Ebenen effizient, „Original ausblenden“, Lösungen vergleichen | teilweise (B12) | ja | E6: Unterschied statt Neuaufbau, eine Anzeige-Canvas je Seite | M | niedrig | P1 |
| P1-10 | Plattformübergreifende Darstellung: Breiten (F3), Druck (`pressures`) | nein | ja, Vertragsänderung | messen, Fixture, alle Darsteller | M–L | mittel | P1 |
| P1-11 | Android: Transformation, Breiten, Seitenaufbau, Text/Formen anzeigen | nein (DocumentScreen.kt:270-283) | ja | Darstellung nach Vertrag, gemeinsame Fixtures | M–L | mittel | P1 (V2) |
| P1-12 | Verlauf anzeigen und wiederherstellen | Backend ja (B15) | ja | in der Dokumentinformation, über `SyncEngine` | M | mittel | P1 |
| P1-13 | Doku nachziehen (B17) | – | ja | README, Schema-Hinweise, Auftrag | S | niedrig | P1 |
| P2-1 | Formen zeichnen | Anzeige | ja | E2 | M | niedrig | P2 |
| P2-2 | Bilder einfügen, Zwischenablage | Anzeige | ja | Fotos/Einfügen → Assets | M | niedrig | P2 |
| P2-3 | Handschrift zu Text | nein | ja, Qualität für deutsche Handschrift n. g. | E8 | M | mittel | P2 |
| P2-4 | Pencil: Doppeltippen, Squeeze, Hover für Objektwerkzeuge | n. g. | ja (Squeeze ab 17.5 laut Apple) | E7 nach Gerätetest | S–M | niedrig | P2 |
| P2-5 | Eigene Einträge in der Palette | nein | ab iPadOS 18 laut Apple, n. g. | hinter `#available` | M | mittel | P2 |
| P2-6 | Tastaturkürzel wie Web | teilweise | ja | `UIKeyCommand`/`.keyboardShortcut` | S | niedrig | P2 |
| P2-7 | PDF-Text markieren (Textmarker an Zeilen), Textauswahl | nein (B8) | ja | Umschalter Textauswahl; Marker als Objekt an Auswahl-Rechtecken | M | mittel | P2 |
| P2-8 | Kommentare/Fragen je Seite oder Aufgabe | nein | ja (CloudKit, später G4) | Datensatz + Melden/Blockieren | L | hoch (Moderation, Richtlinie 1.2) | P2 |
| P2-9 | Export: Seitenbereich, ohne Notizen | teilweise | ja | `PDFExporter.render(pageIndices:)` nutzen | S | niedrig | P2 |
| P2-10 | Schreiblupe, Audio-Aufnahme | nein | ja | nur nach Wunsch des Inhabers | M | niedrig | P2 |
| P2-11 | Gleichzeitiges Bearbeiten in Lerngruppen (live) | nein | ja, aufwendig | nicht vor stabilem G2 | XL | hoch | P2 |

### 6.2 Reihenfolge in Schritten

| Schritt | Inhalt | Voraussetzung |
|---|---|---|
| 0 | Bestandsliste der heutigen Editor-Funktionen (Abschnitt 2.2) als Abnahmeliste festhalten; P0-1 Gerätetest; P0-2 Messung | iPad, Pencil, Mac; Inhaber |
| 1 | P0-3, P0-4, P0-5, P0-6 (kleine Härtungen) | – |
| 2 | P0-7 und P0-8 (mit Web-Gegenstück und Fixtures) | Schritt 1 |
| 3 | P0-9 und P0-10 je nach Messergebnis | Schritt 0 |
| 4 | P1-1, P1-2, P1-3, P1-13 (Seiten und Navigation, geringes Risiko) | Schritt 1 |
| 5 | P1-4 → P1-5 → P1-6 → P1-7 (Objektschicht), danach P1-8, P1-9, P1-12 | Gerätetest des Werkzeugmodus |
| 6 | V2: P0-11, P0-12, P1-10, P1-11 | Entscheidung Hosting, Konto (G1) |
| 7 | P2 nach Wunsch des Inhabers | – |

---

## 7. Performance- und Kompatibilitätsbewertung

### 7.1 Vorhandene Härte- und Leistungstests

| Test | Prüft | Grenze | Ergebnis laut Repo | Bewertung |
|---|---|---|---|---|
| `HardeningSolutionEditorTests.testForeignLayerLandsOnMarkerPixelExact…` (:259) | fremde Ebene pixelgenau bei `/Rotate` 90/270, CropBox, Zusatzdrehung, Leerseiten | 0,75 pt (Referenz) | grün in den Läufen A und D (audit/RUNDE-08-221-250.md:76-87) | gut; nur fremde Ebenen, Bild über `PKDrawing.image` |
| `…testZoomDoesNotChangeForeignGeometry` (:360) | Lage bei Zoom 0,25–4 | ~2/Zoom + 0,5 | grün | gut; Gerät n. g. |
| `…testOwnNotesAndJournalUnchanged…`, `…ScrollingInViewModeWritesNothing`, `…HiddenOwnNotesBlockEveryWritePath`, `…SystemUndoWhileOwnNotesHidden…` (:425, 473, 539, 585) | Ansichtsmodus schreibt nie, Journal bytegleich | – | grün | gut |
| `…testShareImmediatelyAfterStrokeContainsStroke` (:611); `HardeningExportTests.testLastStrokeIncluded…`, `…ExportWaitsForRunningInkConversion` (:950, 968) | letzter Strich ist beim Teilen/Export dabei | – | grün | gut |
| `…testManyForeignLayersStayFastAndAreReleased` (:700) | 30 Ebenen × 120 Striche auf 4 Seiten | anzeigen < 4 s, eine umschalten < 1,5 s | unter Last 1,511 / 1,556 s und 1,52 / 1,64 s, ohne Last grün (audit/RUNDE-08-221-250.md:78-84; IPAD-OHNE-PC.md:533-536) | **Warnsignal:** Umschalten baut alles neu (B12) |
| `…testMemoryWarningUnloadsForeignLayersCleanly` (:745) | Speicherwarnung gibt geparkte fremde Ebenen frei | – | grün | gut; eigene Canvas bleiben (bis 6 geparkt) |
| `StrokeConverterTests.testThousandStrokesProcessQuickly` (:104) | 1000 Striche auf einer Seite | Änderung < 10 s | Zeit nur auf der Konsole, nicht im Repo | Grenze sehr großzügig |
| `SyncEngineTests.test1000Strokes` / `test5000Strokes` (:24-52) | 1000/5000 Striche sichern und hochladen | < 60 s | grün | Mock-Server und Speicher statt Platte/SQLite |
| `HardeningExportTests.testLongDocument150Pages…` (:645) | Export 150 Seiten | < 15 s, < 250 MB Spitze, < 30 MB Datei | grün | gut für Export, nicht für den Editor |
| `HardeningSolutionRoundTripTests.testExtremeValuesDisplayWithoutCrash` (:809) | Extremwerte (bis größte Gleitkommazahl) ohne Absturz | – | grün | teilweise: PencilKit-Darstellung wird von `layer.render` nicht erfasst (InkSnapshot.swift:4-7) |
| Kern: `SyncEngineTests` (Absturz nach Bestätigung, Neustart, Schreibfehler), `DataSafetyTests` | kein Verlust bei Absturz, 401/403/5xx, Browser-Löschungen | – | Kern 465–478 Tests grün (audit/RUNDE-08-221-250.md:72; IPAD-OHNE-PC.md:531) | gut |
| `PDFLayoutTests` (:36-66) | Seitengeometrie, Overlay in Seitenpunkten, Overlay-Anforderung | – | grün | gut |

**Was fehlt:** Editor mit 100–500 Seiten; Speicherrunde gegen das echte lokale Backend; Latenz, Bildrate und Speicher am
Gerät; schnelles Blättern über viele Seiten; zwei Fenster; A0-Whiteboard; Laufzeitwerte werden nirgends abgelegt.

### 7.2 Kosten je Strich

| Schritt | Thread | Aufwand wächst mit | Beleg |
|---|---|---|---|
| PencilKit zeichnet und meldet | System / Haupt | – | PDFEditorController.swift:640-649 |
| `canvasChanged`: letzten Stand merken | Haupt | konstant | DocumentStore.swift:414-425 |
| Umrechnung + Signatur der ganzen Seite + `dataRepresentation()` | Hintergrund | Striche **der Seite** | StrokeConverter.swift:277-410 |
| Journal: Seite (inkl. Base64-`pkdrawing`) atomar schreiben | Hintergrund | Größe **der Seite** | SyncEngine.swift:287-297, 692-701 |
| Upload: Wurzel aus **allen** Seiten bauen, serialisieren, senden | Hintergrund | Größe **des Dokuments** | SyncEngine.swift:424-432, 495-504 |
| Lokales Backend: parsen, speichern, Versionszeile, Kürzen auf 30 | Hintergrund | Größe **des Dokuments** × 2 | AnnotationEndpoints.swift:148-174, 132-145 |

Grobe Größenordnung (Schätzung, **nicht gemessen**): ein Strich ~0,5–1 KB JSON plus native Daten; ein voll
beschriebenes Skript mit 100 Seiten à 400 Strichen läge im zweistelligen MB-Bereich – dann je Speicherrunde zweimal
diese Menge auf der Platte und bis zu 30 volle Kopien im Verlauf. Deshalb P0-2 vor allem anderen.

### 7.3 Bewertung je Lastfall

| Lastfall | Einschätzung | Beleg / offen |
|---|---|---|
| Schreibverzögerung | Hauptthread wird beim Schreiben kaum belastet; Latenz bestimmt PencilKit (Planwert „ca. 9 ms“ nicht gemessen) | DocumentStore.swift:169-174; NATIVE-IPAD-PLAN.md:11 |
| Speicher | Overlays: sichtbare + 6 geparkte; Miniaturen höchstens 60; fremde Ebenen bei Speicherwarnung frei | PDFEditorController.swift:164-165; DocumentView.swift:994; PDFEditorController.swift:488-491 |
| Große PDFs (100–500 Seiten) | Anzeige lazy durch PDFKit; Strukturwechsel kopiert alle Seiten auf dem Hauptthread | DisplayLayout.swift:41-71 – **n. g.** |
| Viele Striche | je Seite linear; je Speicherrunde linear im ganzen Dokument | 7.2 – **n. g.** |
| Schnelles Blättern und Zoomen | Laden asynchron, Neuladen nie im Strich, Zoom bleibt beim Drehen relativ | PDFEditorController.swift:508-554; Geometry.swift:50-58 – Gerät **n. g.** |
| Mehrere Ebenen | funktional sicher, Umschalten teuer | B12 |
| Speichern im Hintergrund | Hintergrund-Aufgabe sichert und lädt hoch | DocumentStore.swift:637-656 |
| Abstürze und Datenverlust | Journal mit Revision je Seite, Wiederherstellung beim Öffnen; Restfenster = Entprellung + Umrechnung (B3) | SyncEngine.swift:131-146, 238-268 |

### 7.4 Stabilste Kombination

**PDFKit `PDFView` + `PDFPageOverlayViewProvider` + ein `PKCanvasView` je sichtbarer Seite, Overlay-Wiederverwendung,
eine gemeinsame `PKToolPicker`, eigener Verlauf je Seitenschlüssel, Umrechnung und Sichern abseits des Hauptthreads** –
also die heutige Architektur (Abschnitt 1.4, Variante A). Sie trennt Eingabe, Darstellung und Speicherung sauber und
ist durch Tests abgesichert. Zu härten sind nur: Zoom-Schärfe (P0-10), Kosten bei Strukturwechseln und fremden
Ebenen (P1-9), Speicherlast je Runde (P0-9). PencilKit gibt es nur auf Apple-Plattformen; deshalb bleibt `objects` die
gemeinsame Wahrheit und `pkdrawing` ein reiner Apple-Zusatz.

### 7.5 Kompatibilität

| Thema | Stand | Beleg |
|---|---|---|
| iPadOS 17.0+ für alle genutzten APIs (Overlay-API ab 16, neue Tinten ab 17 laut Apple) | V | project.yml:7; StrokeConverter.swift:103-104 |
| Notizformat zwischen Web, iPad, Android | V für Striche; Android ohne Transformation | annotations.schema.json; AnnotationDocument.kt:66 |
| `pkdrawing` v1/v2 alt und neu lesbar, Zusammenführung behält v2 | V | DataSafetyTests.swift:8-56; AnnotationMerge.swift:76-86; merge.js:61-67 |
| Native Daten zwischen iPadOS-Versionen | **n. g.** (B14) | – |
| Windows (WebView2), Android-Stifte | **n. g.** am Gerät | PLATTFORM-STAND-2026-10-26.md:71 |
| Dunkelmodus (Tinte bleibt dunkel auf weiß) | V | PDFEditorController.swift:29-30 |
| Mac | kein eigenes Ziel im Projekt | project.yml:21 |

### 7.6 Messplan (für P0-1 und P0-2)

1. Testdokumente selbst erzeugen (wie in den Härtetests): 100, 300, 500 Seiten; 0, 2 000, 10 000, 40 000 Striche;
   gemischte Seitengrößen, `/Rotate`.
2. Messen und im Repo ablegen: Dauer Umrechnung je Seite, Journal-Schreiben, Upload-Runde; Dokumentgröße (JSON,
   Anteil `pkdrawing`); Spitzenspeicher beim Öffnen, Blättern, Zoomen; Dauer eines Strukturwechsels; Bildrate beim
   Scrollen (Instruments am Gerät).
3. Vorschlag für Grenzwerte (Entscheidung Inhaber): Speicherrunde < 300 ms bei 300 Seiten; kein Hänger > 50 ms auf
   dem Hauptthread während des Schreibens; Spitzenspeicher < 1 GB auf dem kleinsten unterstützten iPad.
4. Volle Testläufe nur nacheinander und ohne parallele Simulatoren (audit/RUNDE-08-221-250.md:85-86).

---

## 8. Sicherheitsregeln für die spätere Umsetzung

1. **Eigener Feature-Zweig** je Paket (`wip/…`) von `origin/develop`; nie `main`; Commit-Titel mit `[skip ci]`;
   pushen und zusammenführen nur nach Freigabe des Inhabers.
2. **Bestehende Funktionen vorher festhalten:** Funktionsmatrix (2.2) als Abnahmeliste, dazu Bildschirmfotos der
   Dokumentansicht im Simulator. Nach jeder Änderung dieselbe Liste prüfen.
3. **Tests vorher und nachher:** Kern (`swift test`) und App voll, nacheinander, ohne parallele Simulatoren; neue
   Funktion nur mit neuem Test; Härtetests nie lockern (Grenzen bleiben, audit/RUNDE-08-221-250.md:82).
4. **Keine destruktiven Befehle:** kein `git reset --hard`, kein `push --force`, kein Löschen von Containern,
   Datenbanken, Journalen oder Simulatoren mit Nutzerdaten; Aufräumen nur in eigenen Temp-Ordnern.
5. **Keine Nutzerdaten überschreiben:** Migrationen idempotent und ohne Löschen (Muster: DocumentStore.swift:52-77);
   Formatänderungen nur rückwärtskompatibel, unbekannte Felder bleiben; Vertrag zuerst (Python, Fixtures), dann Swift,
   Web, Kotlin; Tests nur mit erfundenen Daten im Temp-Ordner.
6. **Keine Tokens, Passwörter, PINs in Logs, Fehlermeldungen, Fixtures oder Commits;** nie Zugangsdaten eintippen
   (der Inhaber meldet sich selbst an); vor jedem Commit nach Geheimnissen suchen; `.env`, `data/`, `logs/`,
   `backup/`, `tools/seed-testdata.py` nie einchecken.
7. **Simulator-Builds ad hoc signiert** (`CODE_SIGN_IDENTITY=-`).
8. **Schreibgefühl schützen:** jede Änderung am Eingabeweg am Gerät mit Pencil prüfen, bevor sie auf `develop` kommt.
9. **Neue iPadOS-APIs nur hinter `#available`**, Mindestversion nur nach Entscheidung des Inhabers.
10. **Nichts vortäuschen:** Ungeprüftes als „nicht geprüft“ kennzeichnen; gesperrte Plus-Funktionen zeigen ein Schloss.

---

## 9. Nicht geprüft und offene Entscheidungen

**Nicht geprüft** (aus dem Repo nicht belegbar oder nie am Gerät gelaufen): Schreibgefühl, Latenz, Handballen, Palette,
Doppeltippen, Squeeze, Hover; Lineal mit mehreren Seiten-Canvas; Zoom-Schärfe; Verhalten von `PKDrawing(data:)` bei
Inhalten neuerer iPadOS-Versionen; Editor mit 100–500 Seiten; Dokumentgrößen; zwei Fenster mit demselben Dokument;
A0-Whiteboards; Breite von iPad-Strichen im Web und im Export; Windows- und Android-Stifte; Community mit echtem
iCloud-Container; Qualität einer Handschrift-Erkennung für Deutsch; SDK-Version des Entwickler-Macs.

**Entscheidungen des Inhabers:**

1. Auftrag V2 sah einen zweiten Apple-Editor „1:1 wie im Web“ vor (AUFTRAG-APPSTORE-V1.md:12). Mit „PencilKit bleibt
   die Grundlage“ empfiehlt dieser Plan, stattdessen die Objektwerkzeuge in den PencilKit-Editor zu bringen. Gilt das?
2. Drehen: Objekte beim Drehen mitdrehen (ändert Web und iPad gleich)?
3. Versionsverlauf: seltener, aber länger aufbewahren (ändert Python und Swift)?
4. Druck plattformübergreifend (`pressures`) und Lösung der Breitenfrage nach Messung?
5. Mindestversion iPadOS 17 behalten oder anheben?
6. Kommentare/Fragen in der Community – ja/nein, Moderation?
7. Hosting für Konto und Geräte-Abgleich (Voraussetzung für P0-12).
8. Grenzwerte für die Leistungsmessung (7.6).

---

## Anhang A: Dateien

| Kurzname | Pfad |
|---|---|
| project.yml | `apps/apple/project.yml` |
| Package.swift | `apps/apple/Packages/UniFlowCore/Package.swift` |
| PDFEditorController.swift | `apps/apple/UniFlow/Editor/PDFEditorController.swift` |
| PageObjects.swift | `apps/apple/UniFlow/Editor/PageObjects.swift` |
| PageTemplates.swift | `apps/apple/UniFlow/Editor/PageTemplates.swift` |
| DisplayLayout.swift | `apps/apple/UniFlow/Editor/DisplayLayout.swift` |
| SolutionLayer.swift | `apps/apple/UniFlow/Editor/SolutionLayer.swift` |
| PDFExporter.swift | `apps/apple/UniFlow/Editor/PDFExporter.swift` |
| StrokeConverter.swift | `apps/apple/UniFlow/Models/StrokeConverter.swift` |
| DocumentStore.swift | `apps/apple/UniFlow/Services/DocumentStore.swift` |
| APIClient.swift | `apps/apple/UniFlow/Services/APIClient.swift` |
| CommunityCloudKit.swift | `apps/apple/UniFlow/Services/CommunityCloudKit.swift` |
| DocumentView.swift | `apps/apple/UniFlow/Views/DocumentView.swift` |
| AppShell.swift | `apps/apple/UniFlow/Design/AppShell.swift` |
| Entitlements.swift | `apps/apple/UniFlow/Purchases/Entitlements.swift` |
| SyncEngine.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/SyncEngine.swift` |
| LocalJournal.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalJournal.swift` |
| BlobStore.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/BlobStore.swift` |
| AnnotationDocument.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AnnotationDocument.swift` |
| AnnotationMerge.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AnnotationMerge.swift` |
| PageOrder.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/PageOrder.swift` |
| Geometry.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Geometry.swift` |
| SolutionGeometry.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Solutions/SolutionGeometry.swift` |
| UniStore.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/UniStore.swift` |
| Migrations.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Store/Migrations.swift` |
| AnnotationEndpoints.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Endpoints/AnnotationEndpoints.swift` |
| FileVersions.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/FileVersions/FileVersions.swift` |
| NoteTransfer.swift | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/FileVersions/NoteTransfer.swift` |
| HardeningSolutionEditorTests.swift | `apps/apple/UniFlowTests/HardeningSolutionEditorTests.swift` |
| HardeningExportTests.swift | `apps/apple/UniFlowTests/HardeningExportTests.swift` |
| HardeningSolutionRoundTripTests.swift | `apps/apple/UniFlowTests/HardeningSolutionRoundTripTests.swift` |
| StrokeConverterTests.swift | `apps/apple/UniFlowTests/StrokeConverterTests.swift` |
| ForeignInkWidthTests.swift | `apps/apple/UniFlowTests/ForeignInkWidthTests.swift` |
| PDFLayoutTests.swift | `apps/apple/UniFlowTests/PDFLayoutTests.swift` |
| InkSnapshot.swift | `apps/apple/UniFlowTests/InkSnapshot.swift` |
| SyncEngineTests.swift | `apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/SyncEngineTests.swift` |
| DataSafetyTests.swift | `apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/DataSafetyTests.swift` |
| PageOrderTests.swift | `apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/PageOrderTests.swift` |
| editor.js | `app/static/editor.js` |
| merge.js | `app/static/merge.js` |
| formats.js | `app/static/formats.js` |
| views-doc.js | `app/static/views-doc.js` |
| app/server.py, app/sync.py, db.py | `app/server.py`, `app/sync.py`, `app/db.py` |
| DocumentScreen.kt | `apps/android/app/src/main/kotlin/de/uniflow/android/ui/screens/DocumentScreen.kt` |
| Ink.kt | `apps/android/app/src/main/kotlin/de/uniflow/android/Ink.kt` |
| AnnotationDocument.kt | `apps/android/core/src/main/kotlin/de/uniflow/core/AnnotationDocument.kt` |
| AnnotationMerge.kt | `apps/android/core/src/main/kotlin/de/uniflow/core/AnnotationMerge.kt` |
| android/README.md, windows/README.md | `apps/android/README.md`, `apps/windows/README.md` |
| annotations.schema.json, shared-contracts/README.md | `packages/shared-contracts/` |
| apple.yml | `.github/workflows/apple.yml` |
| übrige `*.md` ohne Pfad | `docs/` |

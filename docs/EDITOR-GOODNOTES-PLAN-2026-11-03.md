# Editor wie aus einem Guss – Plan nach dem Vorbild GoodNotes (03.11.2026)

Stand: Recherche und Plan, noch kein Produktionscode geändert. Mockups (hell und dunkel) liegen in der Mac-Sitzung unter
`/private/tmp/claude-501/-Users-ahmadfakih-uniflow-ai/b2e6b52d-8140-52f8-a368-082b8202c588/scratchpad/editor-plan/`
(`1-werkzeugleiste-stift-*.png`, `2-zoomfenster-hell.png`, `3-lasso-seitenleiste-*.png`, Quelle `mockup.html`).

## Kurzfassung

Du hast recht: Heute arbeiten **drei Bedienflächen nebeneinander**. Da ist Apples schwebende Palette (`PKToolPicker`). Dazu kommt
unsere Navigationsleiste mit elf Knöpfen: Seiten, Rückgängig, Suchen, KI, Geteilt, Nur Stift, Tinte/Objekte, Ebenen,
Teilen und Mehr. Die dritte ist die Objektleiste unten (`ObjectToolbar`) mit eigenem Werkzeugsatz und eigener Farbauswahl.
Die Palette gehört nicht uns. Sie hängt am Erstantwortgeber und verschwindet, sobald ein Textfeld, Menü oder die PDF-Ansicht den
Fokus nimmt. Wir holen sie heute mit bis zu zehn Wiederholungen zurück (`restorePickerSoon`). Stift und Formen haben
verschiedene Farbwelten, und es gibt zwei Lassos: das von PencilKit für Tinte und unseres für Objekte.

GoodNotes macht das anders. Es zeigt **eine eigene Werkzeugleiste oben**: Lasso, Stift, Textmarker, Radierer, Formen, Text,
Bild/Elemente, Laserpointer und Zoom-Fenster. Die Optionen des aktiven Werkzeugs erscheinen direkt an der Leiste. Rückgängig
und Wiederholen sitzen in derselben Leiste. Ein Lesemodus-Schalter blendet die ganze Werkzeugleiste aus. GoodNotes nutzt dafür
nicht einmal PencilKit, sondern eine eigene Swift-Tinten-Engine (Metal, auf dem Web per WebAssembly).

**Vorschlag:** Wir behalten PencilKit als Tinten-Engine, weil das Notizformat mit dem Web, die Druckdaten und Scribble daran
hängen. Apples Palette ersetzen wir durch **unsere eigene Werkzeugleiste**. Sie setzt `canvas.tool` auf allen Seiten direkt.
PencilKit braucht dafür keine Systempalette.
- Ein gemeinsamer Werkzeugzustand (`EditorTools`) gilt für alle Seiten und für beide Seiten der geteilten Ansicht.
- Es gibt drei Stärken und drei Farben direkt in der Leiste, ein Optionsfenster beim zweiten Tippen und Favoriten.
- Ein einziges Lasso wählt Tinte und Objekte zugleich. Der Schalter „Tinte/Objekte“ fällt weg, die Objektwerkzeuge
  (Text, Haftnotiz, Formen) werden normale Werkzeuge in derselben Leiste.

Damit entfallen die meisten heutigen Reparaturen rund um die Palette:
- Anker als Erstantwortgeber
- Wiederholungsschleife
- Fenstersuche nach Menüs
- „Palette schließt Menüs“

**Aufwand gesamt:** rund 14–20 Arbeitstage in sieben Schritten. Jeder Schritt ist für sich auslieferbar. Die Schritte 1–4
ergeben nach etwa 8–11 Tagen das „ein Werkzeug“-Gefühl:
1. eigene Leiste
2. Optionsfenster und Pencil-Gesten
3. Seitenleiste mit „+“
4. Objektwerkzeuge in derselben Leiste

Lasso für alles, Formerkennung und Zoom-Fenster kommen danach. Handschrift-zu-Text ist eine spätere Ausbaustufe.

## 1. Was GoodNotes macht (mit Quellen)

Hinweis zu den Quellen: Die Hilfeseiten von GoodNotes (support.goodnotes.com) sperren automatische Abrufe. Die Angaben dort
stammen aus den Suchergebnis-Auszügen dieser offiziellen Seiten. „Ungeprüft“ heißt, dass ich keine Quelle gefunden habe.

| Thema | GoodNotes 6/7 | Quelle |
|---|---|---|
| Aufbau oben | Drei Reihen: Dokument-Tabs, Navigationsleiste (Bibliothek, Modus Handschrift/Tippen/Aufnahme, Lesemodus) und die Schreib-Werkzeugleiste. Nutzer beklagen den Platzverlust durch die immer sichtbaren Tabs. | https://goodnotes-team.notion.site/Get-to-know-the-main-interface-26fb740273d28122b4a8f3e6c9c5219b , https://feedback.goodnotes.com/forums/191274-customer-suggestions-for-goodnotes/suggestions/49314599-hiding-the-tabs-bar-and-navigation-bar-while-editi |
| Werkzeuge | Lasso (immer an erster Stelle), Stift, Textmarker, Radierer, Klebeband, Formen, Text, Bild, Elemente/Sticker, Laserpointer, Zoom-Fenster, Lineal, Zeitmesser. Die Leiste lässt sich waagerecht wischen. | https://support.goodnotes.com/hc/en-us/articles/7353727934223 , https://support.goodnotes.com/hc/en-us/articles/8900755183631 |
| Anpassbare Leiste | Seit 7.0.14: Werkzeuge ausblenden (landen im Überlauf) und umsortieren. Lasso ist fest. Die Einstellung gilt für alle Notizbücher. | https://support.goodnotes.com/hc/en-us/articles/8900755183631 |
| Rückgängig/Wiederholen | Als Knöpfe in der Leiste, standardmäßig links, per Einstellung rechts. Mit zwei Fingern doppelt tippen = Rückgängig, mit drei Fingern = Wiederholen. | https://goodnoteseducation.zendesk.com/hc/en-us/articles/13879710125711-Customize-the-toolbar |
| Werkzeugoptionen | Das aktive Werkzeug zeigt ein Kontextmenü. Stiftarten Füller (druckempfindlich), Kugelschreiber (ohne Druck) und Pinsel. Spitzenschärfe und Druckempfindlichkeit regelbar. Farbfelder anpassbar und verschiebbar. | https://support.goodnotes.com/hc/en-us/articles/7353756785679-Write-and-customize-ink-with-the-Pen-tool |
| Favoriten-Stifte | Ganze Stift-Einstellungen als Favoriten fehlen in GoodNotes und werden von Nutzern gewünscht. Notability hat seit 2020 eine eigene Favoritenleiste mit bis zu 8 Stiften. | https://feedback.goodnotes.com/forums/191274-customer-suggestions-for-goodnotes/suggestions/9870099--favorites-pens-as-tools , https://9to5mac.com/?p=664955 |
| Radierer | Präzise, Standard oder ganzer Strich. Filter nach Stift, Textmarker und Klebeband. „Automatisch abwählen“ geht nach dem Absetzen zum vorigen Werkzeug zurück. | https://support.goodnotes.com/hc/en-us/articles/7353718249231-Erase-content-with-the-Eraser-tool |
| Formerkennung | Strich zeichnen und halten, dann rastet er als Form oder Gerade ein. „Snap to endpoints“ verbindet Striche. Der Textmarker zieht mit „Draw and Hold“ gerade Linien. | https://www.goodnotes.com/blog/shape-recognition , https://feedback.goodnotes.com/forums/191274-customer-suggestions-for-goodnotes-apple/suggestions/50632331-straightening-for-the-highlighter-tool |
| Lasso | Wählt Handschrift, Markierungen, Textfelder und Bilder (je Art abschaltbar). Verschieben, Größe ändern, Drehen, Farbe ändern, Ausschneiden/Kopieren. „Umwandeln“ macht aus Handschrift Text oder eine Formel. Bildschirmfoto der Auswahl. | https://support.goodnotes.com/hc/en-us/articles/7353695644175 , https://support.goodnotes.com/hc/en-us/articles/10779390143247 |
| Zoom-Fenster | Ein Schreibstreifen unten mit beweglichem Rahmen auf der Seite: Je kleiner der Rahmen, desto stärker die Vergrößerung. Am Zeilenende springt er automatisch weiter (Rand einstellbar). Beim Wechsel z. B. aufs Lasso schließt er. | https://support.goodnotes.com/hc/en-us/articles/7353756826383 |
| Seitenleiste | Reiter „Seiten“ (Miniaturen mit Menü, z. B. „Zur Gliederung“) und „Gliederung“. | https://support.goodnotes.com/hc/en-us/articles/7353757101071-Create-an-outline |
| „+“ am Dokumentende | Ungeprüft (nach Erinnerung erscheint nach der letzten Seite ein „+“). | – |
| Scrollrichtung | Senkrecht oder waagerecht, je Dokument und als Standard. | https://support.goodnotes.com/hc/en-us/articles/7353695996559-Change-the-scrolling-direction-in-Goodnotes |
| Lesemodus | Symbol in der Navigationsleiste. Die Werkzeugleiste verschwindet, Links und Aufnahme gehen weiter. | https://support.goodnotes.com/hc/en-us/articles/7353757120655-Use-Read-Only-Mode-to-navigate-without-editing |
| Handballen | Einstellung „Stift & Handballenerkennung“ mit Schreibhaltung und Empfindlichkeit. Der Apple Pencil braucht keine Einrichtung. Ob es einen eigenen Schalter „Mit dem Finger zeichnen“ gibt, ist ungeprüft. | https://support.goodnotes.com/hc/en-us/articles/7353727026959 |
| Pencil-Gesten | Doppeltippen folgt der Systemeinstellung. Squeeze (Pencil Pro) öffnet eine eigene, nicht anpassbare Schnellpalette. | https://developer.apple.com/documentation/applepencil/handling-squeezes-from-apple-pencil |
| Technik | Eigene Swift-Tinten-Engine (Metal auf iOS, WebGL im Web, derselbe Swift-Code per WebAssembly). Kein PencilKit. | https://swift.org/blog/bringing-goodnotes-to-web-with-swift/ , https://web.dev/case-studies/goodnotes |

**Zum Vergleich:**
- **Notability:** frei umsortierbare Werkzeuge, ein Werkzeug lässt sich mehrfach mit verschiedenen Stilen anlegen, dazu eine
  verschiebbare Favoritenleiste (https://support.gingerlabs.com/hc/en-us/articles/6735217964570-Three-ways-to-customize-your-tools).
- **Apple Freeform:** eine schwebende Palette im Systemstil. Ob es wirklich `PKToolPicker` ist, sagt Apple nicht; Freeform hat
  Werkzeuge über den öffentlichen Satz hinaus (https://developer.apple.com/forums/thread/742347). Freeform ist eine
  Leinwand-App, kein Seitendokument. Die schwebende Palette passt dort, in einem Seitenheft wirkt sie aufgesetzt.

## 2. Was wir heute haben – und wo es reibt

Code: `apps/apple/UniFlow/Views/DocumentView.swift` (Leiste, Seitenleiste, `ObjectToolbar`) und
`apps/apple/UniFlow/Editor/PDFEditorController.swift` (Palette, Overlays, Verlauf). Dazu `ObjectEditing.swift` mit den
Objektwerkzeugen und dem eigenen Lasso.

| Thema | GoodNotes | StudiNow heute | Reibung |
|---|---|---|---|
| Werkzeugwahl | eigene Leiste oben, immer an derselben Stelle | Apples schwebende Palette, frei verschiebbar, hängt am Erstantwortgeber (`ToolPickerAnchor`) | verschwindet bei Textfeld, Menü, Blatt, App-Wechsel und PDF-Textauswahl; Rückholschleife mit 10 Versuchen (`restorePickerSoon`) |
| Tinte vs. Objekte | ein Werkzeugsatz | Schalter „Tinte/Objekte“; im Objektmodus eine zweite Leiste unten (`ObjectToolbar`), der Stift schreibt dann nicht | zwei Modi, zwei Leisten, zwei Farbauswahlen (Palette vs. Menü mit 6 Farben) |
| Lasso | ein Lasso für alles | PencilKit-Lasso (nur Tinte) **und** eigenes Lasso (nur Objekte) | Tinte und Text lassen sich nicht zusammen verschieben |
| Optionen | am Werkzeug, in der Leiste | in Apples Palette (Farbrad, Stärke), nicht anpassbar | keine Voreinstellungen, keine Favoriten, keine Verbindung zu unseren Webfarben |
| Rückgängig | in der Leiste | in der Leiste **und** in der Palette (zwei Knöpfe für dasselbe) | doppelte Symbole |
| Lesemodus | ein Schalter, Leiste weg | „Meine Notizen ausblenden“ im Ebenen-Menü = nur ansehen | schwer zu finden; Palette verschwindet ohne Erklärung |
| Finger/Stift | Handballen-Einstellung | „Nur Stift / Finger zeichnet“ als eigener Leistenknopf | gehört in die Werkzeugoptionen bzw. Einstellungen |
| Seitenleiste | Miniaturen und Gliederung | Miniaturen und Lesezeichen (`PageSidebar`); Gliederung als eigenes Blatt; Seiten einfügen über Mehr → Menü | kein „+“ am Ende; Einfügen über verschachtelte Menüs |
| Geteilte Ansicht | – | eine Palette für beide Dokumente (`ownsToolPicker: false`), gemeinsamer Verlauf | funktioniert, ist aber eng an die Palette gekoppelt |
| Pencil-Doppeltippen/Squeeze | eigene Schnellpalette | nur Systemverhalten über die Palette; die App hat dafür keinen eigenen Code (EDITOR-ABNAHME 2.3/2.4) | ohne Palette fiele das weg und muss nachgebaut werden |

**Frühere Beschwerden und was dahintersteckt** (Commits zu `apps/apple/UniFlow/Editor`, `docs/EDITOR-ABNAHME.md`):

| Beschwerde | Fix-Commit | Ursache |
|---|---|---|
| Palette verschwindet | e6ef15a, 753cac3, 4662a18, 85ba672 | Palette hängt am Erstantwortgeber. Jeder Fokuswechsel nimmt sie weg, die Rückholung fängt sich neue Nebenwirkungen ein („Palette schließt Menüs“). |
| Tinte flackert beim Zoomen | e9b2902, d394122 | Canvas je Seite zoomt selbst. Das ist nicht von der Palette verursacht und bleibt Thema der Render-Schicht. |
| Leiste springt nach jedem Strich | 85ba672 | Speicherstatus änderte die Breite der Leiste |
| „pixelig“ (Text/Tinte) | 38fd434, 9a8c6ec | Render-Auflösung der Overlays |
| doppelte Symbole | 52d8f65 | Apples Seitenleisten-Knopf neben unserem „Seiten“; ebenso Rückgängig doppelt (Palette + Leiste) |
| Seite einfügen schließt die Leiste | – | Blatt oder Menü nimmt den Fokus, die Palette geht; heute per Rückholschleife |

Fazit: Rund die Hälfte der Editor-Reparaturen der letzten Wochen betraf **die Palette selbst**. Mit einer eigenen Leiste
fallen diese Fehler nicht nur weg, die Ursache gibt es dann gar nicht mehr.

## 3. Architektur: „verschweißt“

### 3.1 Grundsatz

- **PencilKit bleibt** für Tinte, Druck und Neigung, Radieren, Scribble und Speichern. Das Notizformat ändert sich nicht:
  `StrokeConverter` und `packages/shared-contracts/annotations.schema.json` mit `tool` ∈ pen/fountain/pencil/marker und `pkInk`
  für die genaue Tintenart.
- **`PKToolPicker` fällt weg.** Jede `PKCanvasView` bekommt ihr Werkzeug direkt (`canvas.tool = …`). Dafür braucht es weder
  Palette noch Erstantwortgeber. Damit entfallen `ToolPickerAnchor`, `restorePicker*`, `otherWindowOpen`, `pickerWanted` und
  `ToolPickerHolder`.
- **Ein Werkzeugzustand** `EditorTools` (ObservableObject, eine Instanz je Fenster, wie heute `ToolPickerHolder`):
  - `active`: lasso | pen | highlighter | eraser | shape | text | sticky | image | laser | zoomWindow | markup
  - `penPresets[3]`, `highlighterPresets[3]`: Art, Farbe, Stärke
  - `eraser`: Pixel oder Strich, nur Textmarker
  - Gespeichert in `UserDefaults`, statt `stateAutosaveName`
  - Der Controller beobachtet den Zustand und setzt beim Wechsel `tool` auf allen lebenden **und** geparkten Canvas. Neue
    Overlays übernehmen ihn in `makeOverlay` (heute `c.tool = toolPicker.selectedTool`). Die geteilte Ansicht teilt sich
    dieselbe Instanz, so wie heute die Palette.
- **Werkzeuge ohne Tinte** (Text, Haftnotiz, Form, Bild, Lasso, Text markieren) schalten die Zeichen-Gesten der Canvas ab
  (`drawingGestureRecognizer.isEnabled = false`). `ObjectEditing` übernimmt dann die Eingabe, wie heute im Objektmodus.
  Ein eigener „Objektmodus“ ist dafür nicht mehr nötig.

### 3.2 Was wir durch den Wegfall der Palette verlieren und wie wir es ersetzen

| Bisher von der Palette | Ersatz |
|---|---|
| Farbrad und Deckkraft | Farbfelder in der Leiste. Im Optionsfenster 15 Farben plus „Weitere …“ mit `ColorPicker` (SwiftUI, entspricht `UIColorPickerViewController`, inkl. Pipette und Deckkraft) |
| Lineal | `PKCanvasView.isRulerActive` lässt sich ohne Palette setzen. Schalter im Optionsfenster, gilt auf der Canvas der aktuellen Seite. Offene Frage aus Abnahme 1.11: ein Lineal je sichtbarer Seite; es reicht, es nur auf der aktuellen Seite einzuschalten. |
| sieben Tintenarten | drei Stiftarten wie im Web-Format: Kugelschreiber = `.monoline`/`.pen`, Füller = `.fountainPen`, Bleistift = `.pencil`, dazu der Textmarker = `.marker`. Wasserfarbe und Wachsmalstift gibt es im Web nicht; sie würden ohnehin auf `pen` abgebildet. Optional später unter „Weitere Stifte“. |
| Pencil-Doppeltippen | eigene `UIPencilInteraction` am Editor. `UIPencilInteraction.preferredTapAction` gibt es seit iOS 12.1, die neue Tap-Methode mit Hover-Position seit iOS 17.5. Wir befolgen die Systemeinstellung: Radierer ↔ letztes Werkzeug, Farbauswahl öffnen, zuletzt benutzte Werkzeuge |
| Squeeze (Pencil Pro) | `didReceiveSqueeze` (ab iOS 17.5): kleine Schnellpalette an der Stiftspitze mit den Favoriten (hover-Position aus dem Ereignis). Unter 17.5 entfällt es (Ziel ist iOS 17.0). |
| Rückgängig in der Palette | entfällt (es bleibt der Knopf in unserer Leiste, ⌘Z, Wischen mit drei Fingern). Die doppelten Symbole sind damit erledigt. |
| Barrierefreiheit der Palette | unsere Knöpfe brauchen Bezeichnungen, Werte („Stift, Blau, mittel“), `isSelected`, Dynamic Type im Optionsfenster, große Hit-Flächen (≥ 44 pt) und Tastaturkürzel (`UIKeyCommand`: P Stift, E Radierer, L Lasso, wie in Freeform/GoodNotes). |
| Mac („Designed for iPad“) | unverändert, die Maus schreibt immer (`isMac`) |

Zwischenweg zum Vergleich: Seit iPadOS 18 nimmt `PKToolPicker` eigene Werkzeuge (`PKToolPickerCustomItem`) und einen
Zusatzknopf (`accessoryItem`) auf. Das würde die Fokusprobleme aber **nicht** lösen, denn die Palette hängt weiter am
Erstantwortgeber. Außerdem verlangt es iOS 18, unser Ziel ist 17.0. Deshalb ist es nicht empfohlen.

### 3.3 Leiste (siehe Mockup 1)

Die bisherige Navigationsleiste und die Objektleiste werden zu **einer** Leiste, von links nach rechts:

1. Zurück (bzw. Logo-Menü), Seitenleiste ein/aus, Titel mit „Seite x von y“
2. Werkzeuge: Stift, Textmarker, Radierer, Lasso, Form, Text, Haftnotiz, Bild, Laserpointer, Zoom-Fenster
   - Am Stift und am Textmarker zeigt ein Farbstrich die aktuelle Farbe
   - Erstes Tippen wählt das Werkzeug, zweites Tippen öffnet die Optionen
3. **Schnellwahl des aktiven Werkzeugs:** 3 Stärken + 3 Farben. Gedrückt halten ersetzt den Platz durch die aktuelle
   Einstellung.
4. Rückgängig, Wiederholen
5. KI, Geteilt, Ebenen, Teilen, Mehr. Suchen, Lesezeichen, Seiten-Aktionen und „Nur Stift“ wandern in „Mehr“ oder die
   Einstellungen.
6. Speicherstatus (feste Breite), Schalter **Stift | Lesen** (= Lesemodus wie GoodNotes; heißt bisher „Meine Notizen
   ausblenden“)

Schmale Fenster (Split View, Slide Over, Stage Manager): Die Werkzeuggruppe bleibt, KI/Geteilt/Ebenen/Teilen gehen in „Mehr“,
die Schnellwahl schrumpft auf die aktuelle Farbe. Die Leiste wird ein eigenes UIView bzw. SwiftUI-View oberhalb des
Editors, keine `ToolbarItem`s der Navigationsleiste. Nur so steuern wir Breite und Überlauf selbst; das „Springen“ der
Leiste aus 85ba672 kann dann nicht mehr auftreten.

Barrierefreiheit: Jede Taste bekommt `accessibilityLabel` und `accessibilityValue`. Die Leiste ist ein
`accessibilityContainer` „Werkzeuge“. VoiceOver kann die Leiste nutzen, die Seite wird bei aktivem VoiceOver nur gelesen.

### 3.4 Ein Lasso für Tinte und Objekte (Mockup 3)

`PKLassoTool` lässt sich nicht von außen abfragen (keine API für die Auswahl). Deshalb erweitern wir **unser** Lasso aus
`ObjectEditing` (`PageObjectEdit.inLasso`) auf PencilKit-Striche:

- Wählt Striche aus, deren Punkte zu einem Mindestanteil, etwa 60 %, im Polygon liegen. Die Punkte kommen aus
  `PKStroke.path` nach `transform`.
- Verschieben und Größe ändern: Die neuen Striche entstehen als Kopie mit `PKStroke(ink:path:transform:mask:)`, der neue
  Stand geht als **ein** Rückgängig-Schritt in den Seitenverlauf (`registerUndo`). Text und Formen laufen wie bisher über
  die Objekttransformation.
- Kontextmenü: Ausschneiden, Kopieren, Farbe, Löschen, **KI fragen** (Bild der Auswahl an die KI-Hilfe; schließt an die
  vorhandene „KI erklärt“ an). „In Text umwandeln“ kommt später mit Vision (`VNRecognizeTextRequest`) über das gerenderte
  Bild der Auswahl.
- Drehen gibt es in einer späteren Stufe. `stroke.transform` kann es, das Web-Format braucht dafür eine Transformation.
  `editierbar_ueberall` nennt „Objekt-Transformation“ schon; das Schema prüfen wir vorher.

### 3.5 Rückgängig für alles

Der Seitenverlauf über `documentUndo` mit Seitenschlüssel bleibt und deckt schon Tinte, Objekte und Seitenaktionen ab.
Neu kommen dazu:
- Lasso-Verschiebungen als ein Schritt
- Formerkennung als ein Schritt (Strich → Form)

Der Verlauf der Korrektur (`correctionUndo`) bleibt getrennt; die Leiste zeigt im Korrekturmodus dessen Rückgängig.

### 3.6 Seitenleiste mit „+“ (Mockup 3)

`ThumbnailStrip` bekommt am Ende eine Kachel „+“ (leere Seite nach der letzten, Vorlage wie die aktuelle Seite; langes
Drücken öffnet die Vorlagen). Außerdem bekommt jede Miniatur ein Kontextmenü: Davor/Danach einfügen, Drehen, In den
Papierkorb, Lesezeichen, Zur Gliederung.

Das Einfügen läuft dann ohne Menü, also ohne Fokuswechsel. Die Beschwerde „Einfügen schließt die Leiste“ hat damit keinen
Anlass mehr, und mit der eigenen Leiste gibt es ohnehin nichts mehr zu schließen.

Später kommen Umsortieren per Ziehen und ein Reiter „Gliederung“ in der Seitenleiste dazu, statt eines eigenen Blatts.

### 3.7 Zoom-Fenster (Mockup 2) – machbar, aber eigene Stufe

Unten liegt eine zweite `PKCanvasView` (der Streifen). Ihr Inhalt wird als Ausschnitt der Seiten-Canvas abgebildet:
- Striche im Streifen werden mit der Rahmen-Transformation (Skalierung und Verschiebung) in die Seiten-Canvas übernommen und
  dort gespeichert.
- Der Streifen zeigt die vorhandenen Striche des Rahmens vergrößert an, über eine nur lesende Kopie per
  `drawing.transformed(using:)`.
- Zeilenende-Taste und automatisches Weiterrücken sind Geometrie.

Risiken:
- Doppelte Canvas kostet Speicher; nur eine Seite ist betroffen, also vertretbar.
- Die Druckwerte müssen beim Verkleinern sauber mitgehen; die Strichbreite skaliert mit.
- Der Rückgängig-Schritt muss genau einer bleiben.

Aufwand 3–4 Tage. Nach den Grundschritten.

### 3.8 Formerkennung („zeichnen und halten“)

Nach einem Strich ohne Bewegung für 0,5 s beim letzten Punkt wird erkannt: Gerade, Rechteck, Ellipse, Dreieck, Pfeil.
Der Strich wird durch eine **Tinte**-Form ersetzt, also einen neuen PKStroke mit idealer Geometrie. Er bleibt damit ein
Strich im Web-Format und braucht keinen neuen Objekttyp.

Die Erkennung selbst ist eine kleine Geometrie-Routine. Sie lässt sich gut testen und gehört in `UniFlowCore`, damit das
Web sie später nachbauen kann. Ein Schalter im Optionsfenster schaltet sie ein oder aus. Auch der Textmarker zeichnet
damit gerade Linien.

## 4. Schritte (jeder für sich auslieferbar)

| # | Schritt | Inhalt | Aufwand | Risiko |
|---|---|---|---|---|
| 1 | **Eigene Werkzeugleiste, Palette aus** | `EditorTools` und `EditorToolbar`. Stift, Textmarker und Radierer setzen `canvas.tool` auf allen Overlays (live und geparkt), in der geteilten Ansicht auf beiden. 3 Stärken + 3 Farben in der Leiste. Rückgängig/Wiederholen. Schalter Stift/Lesen (= `ownNotesVisible`). Palette und Rückholschleife ausbauen. Bisherige Objektwerkzeuge vorerst über „Objekte“ in der neuen Leiste erreichbar. | 3–4 Tage | mittel: Werkzeug muss auf geparkte und neue Overlays durchschlagen. Messung M8 (Speicher) und Abnahme 1.9/1.10/13.2 neu prüfen. |
| 2 | **Optionsfenster, Favoriten, Pencil-Gesten** | Zweites Tippen öffnet Stiftart, Stärke, Farben, `ColorPicker`, Lineal (`isRulerActive`). „Als Favorit anheften“. `UIPencilInteraction` für Doppeltippen nach Systemeinstellung, Squeeze-Schnellpalette ab 17.5. Tastenkürzel. VoiceOver-Texte. | 2–3 Tage | gering bis mittel: Doppeltippen ohne Palette muss genau die Systemeinstellung befolgen; Test nur am Gerät (Abnahme 2.3/2.4). |
| 3 | **Seitenleiste mit „+“ und Miniatur-Menü** | „+“ am Ende, Kontextmenü je Miniatur, Gliederung als Reiter | 1–2 Tage | gering |
| 4 | **Objektwerkzeuge in die Leiste, Objektmodus weg** | Text, Haftnotiz, Form, Bild, Text markieren als normale Werkzeuge. Canvas-Gesten aus, solange eines aktiv ist. `ObjectToolbar` entfällt; Farbe kommt aus der Schnellwahl (gleiche Farbliste für Tinte und Objekte). | 2 Tage | mittel: Gesten-Vorrang zwischen PDFView, Canvas und ObjectEditing (heute über `objects.isActive`) |
| 5 | **Ein Lasso für Tinte und Objekte** | Strich-Auswahl per Polygon, Verschieben/Größe als ein Rückgängig-Schritt, Kontextmenü inkl. „KI fragen“ | 2–3 Tage | mittel: Strich-Kopien müssen `pkInk`, Druck und Breiten verlustfrei erhalten (Tests wie `AuditRunde11PencilTests`) |
| 6 | **Formerkennung** | Zeichnen und halten, Gerade beim Textmarker, Schalter | 1–2 Tage | gering |
| 7 | **Zoom-Fenster** (Ausbaustufe) | Schreibstreifen unten, Rahmen auf der Seite, Weiterrücken | 3–4 Tage | mittel |
| später | Handschrift → Text, Laserpointer, Drehen im Lasso, waagerechtes Blättern, anpassbare Leiste | je 1–3 Tage | – |

**Summe Schritte 1–7:** etwa 14–20 Tage. Davon ergeben die Schritte 1–4 mit 8–11 Tagen schon den Editor „aus einem Guss“.

Reihenfolge-Logik:
- Schritt 1 nimmt die größte Fehlerquelle (Palette) heraus und liefert sofort sichtbar „eine Leiste“.
- Die Schritte 2 und 3 holen nach, was die Palette konnte, und das „+“.
- Schritt 4 entfernt den zweiten Modus.
- Die Schritte 5–7 sind neue Fähigkeiten auf derselben Grundlage.

## 5. Randbedingungen, die jeder Schritt einhält

- **Notizformat unverändert** (Schema, `StrokeConverter`, Web liest alles weiter). Neue Stiftarten werden nur über die
  vorhandenen `tool`-Werte plus `pkInk` gespeichert.
- **Geteilte Ansicht:** ein Werkzeugzustand für beide Dokumente, gemeinsamer Verlauf wie heute; beim Schließen entfernt
  jedes Dokument seine Einträge.
- **Nur ansehen** (Free, ausgeblendete Notizen, alte Fassung, anderes Fenster, neueres Format): Die Leiste zeigt „Lesen“
  fest und die Werkzeuge gesperrt mit Schloss bzw. Hinweis, statt einfach zu verschwinden (Abnahme 12.x, 18.4, 18.8 anpassen).
- **Korrekturmodus:** dieselbe Leiste; die Werkzeuge wirken auf die Korrektur-Canvas (`correctionView.ink`), Rückgängig auf
  `correctionUndo`.
- **Linkshänder:** Das Optionsfenster öffnet zur freien Hand; die Seitenleiste bleibt auf der Seite der freien Hand.
- **Mac:** Die Maus schreibt immer; Tastenkürzel helfen dort am meisten.
- **Abnahme:** `docs/EDITOR-ABNAHME.md` Abschnitte 1, 2, 8, 12, 13 und 21 werden mit Schritt 1/2/4 umgeschrieben (Palette →
  Leiste). Messung M8 (geparkte Canvas) muss nach Schritt 1 gleich bleiben: Ohne Palette hält niemand mehr Canvas fest, eher
  besser.

## 6. Offene Fragen an dich

1. Stiftarten: reichen Kugelschreiber, Füller, Bleistift und Textmarker (wie im Web), oder sollen Wasserfarbe und
   Wachsmalstift unter „Weitere“ bleiben?
2. „Nur Stift“: in die Einstellungen verschieben (GoodNotes-Weg) oder ins Optionsfenster des Stifts?
3. Zoom-Fenster und Formerkennung: Welches zuerst?
4. Leiste anpassbar (wie GoodNotes 7) jetzt schon oder erst nach Rückmeldungen?

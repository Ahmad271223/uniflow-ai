# Textblöcke „wie Word“, Notizzettel, Klappkarten, Verweise, Tabelle – 25.11.2026

Auftrag des Inhabers vom 25.11.2026 (wörtlich im Auftrag der Hauptsitzung): Auf blanko und linierten Seiten Text
tippen, „immer richtig formatiert“, mehrere Blöcke, alte Blöcke gedrückt halten und verschieben/verkleinern, dicker,
andere Schriftart, auf liniert immer auf den Zeilen, „sehr Word-ähnlich“. Dazu schönere Notizzettel,
Klappkarten zum Abfragen (gehen in der Community mit) und „ein sehr gutes Excel“.

**Nachtrag des Inhabers am selben Tag (in dieser Sitzung):** zusätzlich **Verweise** auf Dokument + Seite („wenn man
ein Wort anklickt oder einen Punkt … dann direkt die Seite daneben geöffnet wird, wenn nicht schon offen, und wenn
offen, wird automatisch auf die Seite geschickt, wo der Verweis hinzeigt“), und: **„ich korrigiere mich, auch das
alles ab Pro AI bitte“** (vorher: Textblöcke ab Plus).

## 0. Tarif: alles Neue ab Pro AI

- Eine Regel, eine Zeile: `UFRichNotes.minimumPlan = .proAI` (`Purchases/Entitlements.swift`). Die Probewoche zählt
  wie Pro AI.
- **Plus behält genau, was es in 1.0.7 hat:** einfaches Textfeld und gelbe Haftnotiz. So habe ich „das alles ab
  Pro AI“ gelesen – zahlenden Plus-Nutzern wird nichts weggenommen, was heute live ist.
- **Plus sieht das Neue mit Schloss** („Text wie in Word 🔒 ab Pro AI“), Antippen öffnet die Tarifwahl.
- **Vorhandene Blöcke** (aus der Probewoche, vom anderen Gerät, aus der Community) bleiben in jedem Tarif sichtbar
  und exportierbar; mit Plus kann man sie weiter verschieben, löschen und ihren Text ändern (die Formatierung der
  Wörter bleibt dabei erhalten) – nur neu formatieren nicht. Free: nur ansehen (wie bisher).
- **Noch offen (Inhaber):** Auf den Tarifkarten und im Vergleich steht das Neue noch **nicht** (bewusst kein
  `UFFeature`: das wäre ein Versprechen im Store und Teil des Vertrags mit dem Dienst). Text dafür freigeben.

Basis: `release/1.0.7-b47` @ `9a5983d8` (Stand der eingereichten 1.0.7). Nichts gepusht, nichts eingereicht, kein
Server, keine Website. Frühestens für 1.0.8.

## 1. Was es schon gab (Bestand, am Code geprüft)

| Thema | Stand in 1.0.7 |
|---|---|
| Textwerkzeug | Ja, einfach: Werkzeug „Text“ legt ein Textfeld an (Arial 14, 220 breit). **Eine** Formatierung für das ganze Feld; in der App nur Farbe und Schrift größer/kleiner. Kein Fett für einzelne Wörter, keine Schriftart, kein Markieren, nichts rastet auf Linien. |
| Notizzettel | Ja, einfach: „Haftnotiz“ = Textfeld mit gelbem Hintergrund (ein Rechteck mit runden Ecken). Keine Muster, keine Größen. |
| Seitenvorlagen | Leer, liniert, kariert, gepunktet, Millimeter, Cornell (`PageOrder.templates`). Liniert/Cornell: erste Linie bei 60 pt, Abstand 24 pt (`TemplateGeometry`). |
| Speicherformat | `AnnotationDocument` (gemeinsam mit Web/Windows): `pageOrder`, `pages[key].objects`. Objekttypen: `stroke`, `text`, `shape`, `image`. Unbekannte **Felder** bleiben überall erhalten (`JSONValue`). |
| Community | `SolutionBuilder`/`SolutionPackage` übertragen die Objekte einer Seite. **Wichtig:** `SolutionValidator` lehnt unbekannte Objekt-**Typen** ab – beim Teilen und beim Öffnen. Ein neuer Typ würde geteilte Lösungen bei allen mit älterer App unlesbar machen. |
| Tarif | Schreiben im Editor (Stift **und** Objektwerkzeuge) gibt es schon nur ab Plus (`UFFeatureMatrix.notes(plan:).canEdit`, `PDFEditorController.writable`). Ohne Plus: Leiste mit Schloss, Notizen bleiben lesbar. |
| iPhone | Kein Editor. Die Leseansicht (`PhoneDocumentReader`) zeigt die Notizen vom iPad. |
| Klappkarten, Tabelle | Gab es nicht. |

**Folgerung für alle vier Teile:** Neue Dinge werden als **zusätzliche Felder an vorhandenen Objekttypen** gespeichert,
nicht als neue Typen. So zeigen ältere Apps (bis 1.0.7), der Web-Editor und Windows sie in einfacher Form weiter,
nichts geht beim Abgleich verloren, und die Community überträgt sie ohne Änderung am Dienst.

## 2. Plan

| Teil | Inhalt | Zweig | Stand |
|---|---|---|---|
| 1 | Textblöcke „wie Word“ | `editor/textbloecke` | **fertig** (siehe 3) |
| 2 | Notizzettel wie echte Klebezettel (Farben, Muster, Größen) | `editor/notizzettel` (auf Teil 1) | siehe 4 |
| 3 | Klappkarten zum Abfragen (verdecken Getipptes und Gezeichnetes, Antippen deckt auf) | `editor/klappkarten` (auf Teil 2) | siehe 5 |
| 5 | Verweise auf Dokument + Seite (Wort oder Punkt antippen → Dokument daneben auf der Stelle) | `editor/verweise` (auf Teil 3) | siehe 7 |
| 4 | Tabellenkalkulation | noch kein Zweig | **wartet auf Antworten des Inhabers** (siehe 6) |

## 3. Teil 1: Textblöcke „wie Word“

### Was geht

- **Tippen auf blanko, liniert, Cornell und auf PDF-Seiten.** Werkzeug „Text“ wählen, auf die Seite tippen, schreiben
  (Tastatur, Diktat, Scribble mit dem Pencil). Der Block reicht bis zum rechten Seitenrand und bricht selbst um.
- **Mehrere Blöcke je Seite**, frei nebeneinander und untereinander.
- **Auf linierten Seiten immer auf den Zeilen.** Jede Zeile hat genau den Abstand der Linien (24 pt), die Grundlinie
  sitzt auf der Linie – auch mit gemischten Schriftgrößen (eine sehr große Zeile nimmt zwei Linien), nach dem
  Umbrechen, nach Verschieben, nach Ändern der Breite, nach Duplizieren und Einfügen. Schon beim Ziehen springt der
  Block zeilenweise; waagerecht bleibt er frei.
- **Auf blanko frei**, aber sauber gesetzt (fester Zeilenabstand 1,3).
- **Formatieren wie in Word** (Leiste „Text“ unten, sobald Text gewählt ist oder getippt wird): fett, kursiv,
  unterstrichen, durchgestrichen, **markieren** (5 Textmarker-Farben), Schriftfarbe (6), **Schriftart** (11:
  Arial, Times New Roman, Georgia, Courier New, Helvetica Neue, Avenir Next, Palatino, Schreibmaschine, Handschrift,
  Filzstift, Tafel), **Schriftgröße** (10–48 und A−/A+), Ausrichtung links/mittig/rechts, Aufzählung und Nummerierung
  (Eingabetaste setzt die Liste fort, auf einem leeren Punkt endet sie).
  - Beim Tippen wirkt die Leiste auf den **markierten Text**; ohne Markierung auf das, was als Nächstes getippt wird.
  - Ist ein ganzer Block gewählt (nicht im Tippen), wirkt sie auf den ganzen Block.
  - Mit Tastatur: ⌘B, ⌘I, ⌘U.
- **Alte Blöcke gedrückt halten (3 Sekunden)** greift sie: Der Block ist ausgewählt (Rahmen, vier Anfasser, Leiste
  „Text“) und folgt sofort dem Finger. Loslassen, dann an einer Ecke ziehen ändert die Breite (der Text bricht neu um),
  der Papierkorb in der Leiste löscht. Die Zeit steht in **einer Zeile** (`ObjectEditing.holdSeconds`).
  - Mit „Text“, „Haftnotiz“ oder „Auswählen“ greift Finger **und** Stift.
  - Beim Schreiben mit dem Stift greift der **Finger** (Einstellung „Nur Stift“, also Finger blättert). Der Stift
    selbst greift dann nicht – er schreibt.
- **Bearbeiten:** Mit „Text“ auf einen vorhandenen Block tippen oder mit „Auswählen“ doppelt tippen.
- **Rückgängig/Wiederholen:** Ein neuer Block ist **ein** Schritt (vorher zwei, und ein leeres Feld blieb unsichtbar
  auf der Seite liegen). Ein leer gelassener neuer Block hinterlässt nichts.
- **Export, Drucken, Vorschau:** derselbe Zeilensatz; der Text steht als Text in der PDF (durchsuchbar).
- **Suche, KI, Karteikarten:** lesen weiter den ganzen Text des Blocks.
- **Lasso, Kopieren/Einfügen, Duplizieren, nach vorne/hinten:** wie bei den bisherigen Textfeldern.
- **Geräteabgleich:** Blöcke sind normale Objekte der Seite und gehen mit.
- **Community:** Blöcke gehen beim Teilen mit und sehen beim Empfänger mit neuer App genauso aus (gleicher Satz).
- **iPhone:** Die Leseansicht zeigt die Blöcke genauso, auf den Linien.
- **Tarif:** ab Pro AI (Abschnitt 0). Plus: einfaches Textfeld wie bisher, Leiste mit Schloss. Free: kein Schreiben;
  vorhandene Blöcke bleiben sichtbar und exportierbar.

### Was nicht geht bzw. anders ist

- **Ältere Apps (bis 1.0.7), Web-Editor, Windows** zeigen einen Block als normales Textfeld in **einer** Formatierung
  (die, in der die meisten Zeichen stehen), mit dem richtigen Zeilenabstand, aber ohne Fett/Markierung einzelner
  Wörter. Nichts geht verloren. Ändert jemand dort den Text, gilt danach für diesen Block die eine Formatierung.
- **Ausrichtung gilt für den ganzen Block**, nicht je Absatz. Für einen zentrierten Titel über linkem Text: zwei Blöcke.
- **Listen** sind Zeichen im Text („• “, „1. “): kein automatisches Neu-Nummerieren, wenn man mitten in der Liste
  eine Zeile löscht; kein hängender Einzug in der zweiten Zeile eines Punkts.
- **Keine Tabellen, Bilder oder Formeln im Block** (Bilder gibt es als eigenes Objekt; Tabelle ist Teil 4).
- **Kariert, gepunktet, Millimeter:** kein Einrasten (bestellt war liniert). Lässt sich nachziehen.
- **Gedrehte Seiten:** Ein Block, der mit der Seite gedreht wurde, rastet nicht mehr ein.
- **Anfasser ändern die Breite**, nicht die Schriftgröße (die Schrift stellt man in der Leiste ein) – so bleibt der Text
  beim Ziehen lesbar und auf den Linien.
- **Dokument daneben (geteilte Ansicht):** Dort kann man wie bisher auswählen, verschieben und formatieren, aber
  keine neuen Texte anlegen (galt schon vorher für Text und Formen).
- **Nicht am Gerät geprüft:** Lage der Leiste über der Bildschirmtastatur, Gefühl des langen Drückens (3 s) und
  Scribble. Im Simulator mit echten Berührungen getestet, aber der Inhaber sollte es am iPad ausprobieren.

### Technik (für die nächste Sitzung)

- **Format** (Kern `TextBlock.swift`, `packages/shared-contracts/annotations.schema.json`): Objekt `type: "text"` mit
  `block: 1`, `runs: [{text, bold?, italic?, underline?, strike?, mark?, fill?, fontFamily?, fontSize?}]` (nur
  Abweichungen von der Grundformatierung; gültig nur, wenn aneinandergereiht = `text`), `strike`, `mark`,
  `snap: "lines"`. Einrasten ist reine Rechnung im Kern (`snappedY`), keine Schriftmaße.
- **Ein Zeilensatz** (`TextBlockRender.Layout`, TextKit 1 mit eigener Zeilenhöhe über
  `layoutManager(_:shouldSetLineFragmentRect:…)`) für Anzeige (`TextBlockView` in `PageObjectsView`), Tippen
  (`UITextView` mit demselben Satz), Messen (`ObjectGeometry.textSize`) und Export (`ObjectGeometry.draw`).
- **Editor:** `TextBlockEditing.swift` (Tippen, Formatieren, Listen, langes Drücken), `TextFormatBar.swift` (Leiste),
  Änderungen in `ObjectEditing.swift` (Anlegen, Einrasten beim Greifen/Skalieren/Speichern), `PageObjects.swift`,
  `EditorToolbar.swift`/`DocumentView.swift` (Stand der Leiste über `EditorToolState.textFormatChanged` →
  `EditorBridge.textFormat`).
- Einfache Textfelder aus dem Web und Haftnotizen bleiben, was sie sind, solange man sie nicht formatiert.
- Kein Fremdpaket: alles mit TextKit von Apple gebaut. Kein Lizenzhinweis nötig.

### Tests und Bilder

- Kern: `TextBlockTests` (14) – Format, Abschnitte, ältere App ändert Text, Einrasten, Listen, Community-Prüfung.
- App: `TextBlockAppTests` (15) – Zeilen auf den Linien (auch gemischte Größen), Tippen mit Formatierung über echte
  Berührungen, Format ohne Auswahl, vorhandenen Block bearbeiten, altes Textfeld bleibt einfach, ganze Blöcke
  formatieren mit Rückgängig, Listen, Verschieben/Breite/Duplizieren bleiben auf den Linien, langes Drücken greift und
  zieht, Regeln fürs Greifen, **Tarif-Regel, Plus behält das einfache Textfeld, ohne Schreiben nichts**, Export.
  Grün im iPad- und im iPhone-Simulator (dort zusätzlich `IPhoneReaderTests`).
- Bilder: `TextBlockBilderAppTests` (4, nur mit `TEST_RUNNER_UF_SCREENSHOT_DIR`) → `~/Studora-Builds/textbloecke/bilder/`
  (iPad liniert, Block gewählt mit Leiste, Tippen, blanko, iPhone-Leseansicht, Export als Bild und PDF, Plus mit
  Schloss); im iPhone-Simulator erzeugt: `~/Studora-Builds/textbloecke/bilder-iphone/`.

## 4. Teil 2: Notizzettel wie echte Klebezettel

Zweig `editor/notizzettel` (auf Teil 1).

### Was geht

- Werkzeug **„Haftnotiz“** legt einen Zettel an, der wie ein echter Klebezettel aussieht: Papier mit leichtem Verlauf
  und Schatten, Schrift „Handschrift“.
- **Auswahl** (zweites Tippen auf das Werkzeug, je Gerät gemerkt): **6 Farben** (Gelb, Rosa, Grün, Blau, Orange,
  Lila), **4 Aussehen** (Klebezettel, mit Klebestreifen, mit Pinnnadel, Ecke geknickt), **4 Papiere** (blanko,
  liniert, kariert, gepunktet), **3 Größen** (klein 120, mittel 165, groß 230 pt; etwa quadratisch, wächst mit dem
  Text).
- Auf **liniertem Zettelpapier** sitzt der Text auf den Linien des Zettels.
- **Vorhandene Zettel umgestalten:** Zettel wählen → Leiste „Text“ → Knopf „Zettel“ (Farbe, Aussehen, Papier,
  Größe). Das geht auch mit den alten gelben Haftnotizen. Ein Rückgängig-Schritt je Änderung.
- Der Text auf dem Zettel ist ein Textblock: fett, markieren, Farbe, Schriftart, Größe, Listen wie in Teil 1.
- Verschieben, Größe (Anfasser: bleibt in seiner Form), langes Drücken, Lasso, Kopieren, Duplizieren, Rückgängig,
  Export/Drucken, Geräteabgleich, Community, iPhone-Leseansicht: wie Textblöcke.
- **Tarif:** ab Pro AI. Plus: die gelbe Haftnotiz wie in 1.0.7; die Auswahl zeigt ein Schloss.

### Was nicht geht bzw. anders ist

- **Ältere Apps, Web, Windows:** zeigen ein farbiges Rechteck mit dem Text (ohne Klebestreifen, Papier, Schatten;
  so hoch wie der Text). Nichts geht verloren.
- Zettel liegen wie alle Objekte **unter der Handschrift** (man kann darauf schreiben; sie verdecken keine Striche).
- Kein schräges Aufkleben und keine eigenen Fotos/Bilder als Muster (ließe sich nachziehen).
- Kariert/gepunktet: der Text richtet sich dort nicht am Raster aus (nur liniert).

### Technik

- Format (Kern `StickyNote.swift`): Haftnotiz des gemeinsamen Formats (`type: "text"` mit `bg`) plus
  `note: {look, paper}`, `minHeight`, `block: 1`. Anfasser skalieren `width` und `minHeight` (`PageObjectEdit.scale`).
- Aussehen: `StickyNoteRender.draw` (eine Routine für Anzeige, Tippen – `StickyNoteBackdrop` unter der Textansicht –
  und Export); Innenabstand und Zeilenraster je Objekt in `TextBlockRender.insets`/`step`.
- Auswahl: `StickyNoteOptions` (Werkzeug), `EditorPalette.stickyChoice`, Menü in `TextFormatBar`.
- Tests: Kern `StickyNoteTests` (6), App `StickyNoteAppTests` (4), dazu in `TextBlockAppTests`
  `testNotizzettelAnlegenUndUmgestalten`, `testPlusBehaeltDieGelbeHaftnotiz`. Bilder 10–13 in
  `~/Studora-Builds/textbloecke/bilder/`.

## 5. Teil 3: Klappkarten zum Abfragen

Zweig `editor/klappkarten` (auf Teil 2).

### Was geht

- Neues Werkzeug **„Klappkarte“** (Auge mit Strich, bei den Objektwerkzeugen): **über eine Stelle ziehen** verdeckt
  genau sie; **antippen** legt eine Karte in fester Größe an (Wort, Zeile, Absatz). Das Werkzeug bleibt gewählt, damit
  man mehrere Stellen nacheinander verdeckt.
- Die Karte liegt **über allem**: PDF, getipptem Text **und Handschrift** (eigene Schicht über der Zeichenfläche).
- **Antippen deckt auf, noch einmal antippen verdeckt wieder** (kurzes Umklappen). Aufgedeckt bleibt ein gestrichelter
  Rahmen, damit man sieht, wo man zum Verdecken tippt. Beim Antippen entsteht kein Strich.
  Der Zustand wird **nicht gespeichert**: beim nächsten Öffnen ist alles wieder verdeckt.
- **Auswahl** (zweites Tippen auf das Werkzeug, je Gerät gemerkt): **6 Farben**, **5 Muster** (einfarbig, gestreift,
  gepunktet, kariert, Fragezeichen), **3 Größen** fürs Antippen; gezogen wird jede Größe.
- Mit **„Auswählen“** antippen wählt die Karte (statt aufzuklappen): verschieben, Größe an den Ecken (das Muster
  bleibt gleich fein), Farbe, Muster, Größe im Menü „Klappkarte“, löschen. Langes Drücken greift auch Karten.
  Rückgängig je Schritt.
- **Community:** Karten gehen beim Teilen automatisch mit (Objekte der Seite). Beim Empfänger liegen sie über der
  Handschrift und klappen beim Antippen auf – in der Ansicht „Lösung daneben“ und in der Vorschau verdeckt.
- **iPhone:** In der Leseansicht klappen die Karten beim Antippen auf und zu.
- **Export, Drucken:** Karten werden verdeckt gezeichnet (so sieht die Seite aus).
- **Tarif:** Anlegen und Gestalten ab Pro AI. **Aufklappen kann jeder** (Free, Plus, Empfänger in der Community).

### Was nicht geht bzw. anders ist

- **Ältere Apps (bis 1.0.7), Web, Windows:** zeigen ein farbiges Rechteck. Es verdeckt dort getippten Text und die PDF,
  liegt aber **unter** der Handschrift und lässt sich **nicht aufklappen** (nur verschieben/löschen). Wer Karten in der
  Community teilt, sollte wissen: Empfänger mit alter App sehen an der Stelle nur das Rechteck.
- Auf einer Karte kann man nicht schreiben (die Berührung gehört der Karte); zum Schreiben darunter Karte verschieben.
- „Alle aufdecken / alle verdecken“ gibt es noch nicht als Knopf (Code dafür ist da: `coverAll`).
- Karten ohne Text darauf (kein „Frage vorn, Antwort hinten“ – dafür gibt es die Karteikarten).
- Gedruckt bleibt verdeckt; ein Druck „mit Lösungen“ fehlt.

### Technik

- Format (Kern `FlipCover.swift`): `type: "shape"`, `shape: "rect"`, deckende `fill`, Zusatzfeld `cover: {pattern}`.
  Größe ändert `width`/`height` (nicht den Maßstab).
- Anzeige: zweite `PageObjectsView` der Art `.covers` über der Zeichenfläche (`PageInkView.coversView`,
  `ForeignLayerView.coversView`); die Schicht darunter reicht Inhalt und Vorschauen weiter (`top`). `CoverView`,
  `CoverRender`.
- Antippen: `CoverTapper` (ein Erkenner an der PDF-Ansicht; nimmt nur Berührungen auf einer Karte) im Editor
  (aus mit Objektwerkzeug), in der iPhone-Leseansicht und in `SolutionSideController`.
- Export: `PageRenderer.drawObjects` zeichnet Karten zuletzt (`FlipCover.coversLast`), ebenso `SolutionPreview.image`.
- Werkzeug: `ObjectEditing.Tool.cover`, `EditorToolState.Tool.cover`, `CoverOptions`, `EditorPalette.coverChoice`.
- Tests: Kern `FlipCoverTests` (5); App in `TextBlockAppTests`: `testKlappkarteLiegtUeberDerHandschriftUndKlapptBeimAntippen`,
  `testKlappkarteAnlegenWaehlenUmgestalten`, `testKlappkartenAnlegenAbProAIAufklappenImmer`,
  `testKlappkarteImExportUndInDerCommunity`. Bilder 14–19.

## 6. Teil 4: Tabelle („Excel“) – gebaut am 26.11.2026

**Antworten des Inhabers (26.11.2026):** Ort: *beides* (Kasten auf der Seite und eigene Datei). Umfang: *Formeln,
Sortieren und Filtern, Diagramme, Farben und Rahmen*. Excel-Dateien (.xlsx): *gar nicht*. Bausteine: „suche offene
repos und opensource projekte dazu checke die lizenz will kein veröffentliche und das für 39.99 anbieten“.
Auf Nachfrage (26.11.): „nein das zu pro ai mit rein“ – die Tabelle wird nicht einzeln verkauft, sie gehört zu
Pro AI. So ist es gebaut. Es wurde kein Preis geändert und nichts zum Kaufen gebaut.

### 6.1 Lizenzprüfung (26.11.2026, an den Quellen geprüft: LICENSE-Dateien bzw. GitHub)

Bedingung: geschlossener Quelltext, Verkauf im App Store, nichts veröffentlichen. Also nur MIT, BSD, Apache-2.0 u. ä.

| Baustein | Lizenz | Urteil |
|---|---|---|
| SimpleSpread / SpreadsheetCore (Swift) | MIT | erlaubt; verlangt aber iOS 26, ein einzelner Pfleger, erst seit 09/2026 |
| IronCalc (Rust) | MIT oder Apache-2.0 | erlaubt; kein Anschluss für Swift, Rust im Bau nötig, noch vor Version 1 |
| Formula.js, fast-formula-parser (JavaScript) | MIT | erlaubt; nur über eine JavaScript-Brücke, kein Neuberechnen |
| nicklockwood/Expression (Swift) | MIT | erlaubt; rechnet nur Ausdrücke, keine Zellen und Bereiche |
| bannzai/SpreadsheetView (Swift, Gitter) | MIT | erlaubt; nur Anzeige, seit 2020 nicht gepflegt |
| DGCharts (Diagramme) | Apache-2.0 | erlaubt; nicht nötig |
| Swift Charts (Apple) | Teil von iOS | erlaubt, keine Pflicht |
| HyperFormula | GPL-3.0 oder gekauft | **nicht erlaubt** (GPL verlangt Offenlegung) |
| Handsontable | nur nicht-kommerziell frei | **nicht erlaubt** |
| o-spreadsheet (Odoo) | LGPL-3.0 | **nicht erlaubt** |
| EtherCalc / SocialCalc | CPAL | **nicht erlaubt** |
| AAChartKit-Swift | MIT-Hülle um Highcharts (Kauf-Lizenz) | **nicht erlaubt** |
| LibreOffice Calc | MPL/LGPL, riesig | praktisch nicht nutzbar |

**Entscheidung (Claude):** Alles selbst geschrieben, **kein Fremdbaustein eingebaut**. Rechenwerk, Gitter und Diagramme
sind eigener Code auf Apples Bordmitteln. Damit gibt es keine Lizenzpflicht, keinen Eintrag im Lizenz-Dialog, nichts
zu veröffentlichen, und die Tabelle passt in das eigene Notizformat (Abgleich, Community, Export). Die erlaubten
Projekte wären nur dann einen zweiten Blick wert, wenn einmal echte Excel-Dateien gelesen werden sollen.

### 6.2 Was gebaut ist

- **Kasten auf der Seite:** Werkzeug „Tabelle“ (Objektleiste) → Stelle antippen → Tabelle liegt auf der Seite, die
  große Ansicht geht auf. Wie jedes Objekt verschieben, größer/kleiner ziehen, kopieren, löschen. Doppeltipp oder
  „Bearbeiten“ in der Leiste öffnet die große Ansicht wieder. Auf Wunsch zeigt der Kasten Tabelle + Diagramm, nur die
  Tabelle oder nur das Diagramm.
- **Eigene Datei:** Bibliothek → Neu → „Tabelle“. Das ist ein Notizbuch (A4 quer), dessen erste Seite die Tabelle
  trägt; beim Öffnen erscheint gleich die große Ansicht. „Fertig“ zeigt die Seite mit der Tabelle – dort kann man
  daneben schreiben und zeichnen. In der Bibliothek steht die Datei als Notizbuch mit dem Namen „Tabelle“.
- **Große Ansicht:** Eingabezeile wie in Excel (Zelle, **fx** mit 43 Funktionen samt Erklärung, Text/Formel), Gitter
  mit A B C / 1 2 3. Antippen wählt, Doppeltipp tippt, die zwei Punkte an der Auswahl ziehen sie größer, Kopf antippen
  wählt Spalte/Zeile, am Rand im Kopf ziehen ändert Breite/Höhe, zwei Finger zoomen. Beim Tippen einer Formel setzt
  Antippen einer Zelle ihren Namen ein; die gelesenen Zellen sind farbig umrandet. Eingabe = nächste Zeile (am Ende
  wächst die Tabelle), Tab = nächste Spalte. Mit Tastatur: Pfeile, einfach lostippen, Entf, ⌘C/X/V/Z/B/I/D/A.
  Widerrufen/Wiederholen (80 Schritte).
- **Formeln:** deutsch wie in Excel (`=SUMME(A1:A5)`, `;` zwischen Angaben, Komma als Dezimalzeichen); englische Namen
  und der Punkt gehen genauso. Rechnen + − × ÷ ^ %, Vergleiche, Text verketten mit `&`, feste Bezüge mit `$`.
  Funktionen: SUMME, MITTELWERT, MIN, MAX, ANZAHL, ANZAHL2, ANZAHLLEEREZELLEN, PRODUKT, MEDIAN, STABW, STABWN,
  VARIANZ, WENN, WENNFEHLER, UND, ODER, NICHT, RUNDEN, ABRUNDEN, AUFRUNDEN, GANZZAHL, ABS, WURZEL, POTENZ, REST, EXP,
  LN, LOG, LOG10, PI, SIN, COS, TAN, SUMMEWENN, ZÄHLENWENN, MITTELWERTWENN, SUMMENPRODUKT, SVERWEIS, KGRÖSSTE,
  KKLEINSTE, RANG, VERKETTEN, LÄNGE, LINKS, RECHTS, TEIL, GROSS, KLEIN, GLÄTTEN, WERT, ISTLEER, ISTZAHL, ISTTEXT,
  ISTFEHLER. Fehler erklären sich in einfachen Worten (`#DIV/0!`, `#WERT!`, `#NAME?`, `#BEZUG!`, `#ZIRKEL!` …).
  Zeilen/Spalten einfügen oder löschen und Kopieren passen die Formeln an.
- **Sortieren und Filtern:** nach der Spalte der aktiven Zelle auf- oder absteigend (Kopfzeile bleibt, Leeres unten,
  Formeln der Zeile gehen mit). Filter je Spalte: Werte an- und abwählen; gefilterte Zeilen fehlen auch auf der Seite
  und im Diagramm.
- **Farben und Rahmen:** fett, kursiv, Textfarbe, Zellfarbe, Ausrichtung, Zahlenformat (Zahl, Prozent, Euro, Text,
  Nachkommastellen), Rahmen außen / alle Linien / unten / keiner, Kopfzeile an/aus.
- **Diagramme:** Balken, Linien, Kreis aus der Auswahl; Titel, Art und Bereich änderbar; bis zu 6 je Tabelle.
- **Tarif:** anlegen und bearbeiten ab Pro AI (`UFRichNotes`, wie alles Neue); ansehen kann jeder, auch am iPhone und
  in geteilten Lösungen.

### 6.3 Technik

- **Format:** Objekt `type: "text"` mit Zusatzfeld `sheet` (kein neuer Objekttyp – `SolutionValidator`). `text` trägt
  die angezeigten Werte als Ersatztext (Tabulator/Zeilen): ältere Apps, Web und Windows zeigen die Zahlen als Text.
  `packages/shared-contracts/annotations.schema.json` beschreibt das Feld.
- **Kern** (`UniFlowCore`): `Sheet.swift` (Zellen, Aussehen, Zeilen/Spalten, Kopieren, Sortieren, Filtern, Speichern,
  `SheetObject`), `SheetFormula.swift` (Zerlegen, Baum, Rechnen, Funktionen, Bezüge umschreiben), `SheetChart.swift`.
- **App:** `SheetRender.swift` (Zellen und Diagramme zeichnen – derselbe Code für Seite, Export, große Ansicht;
  `SheetBoxView`), `SheetEditing.swift` (Werkzeug, Öffnen, Sichern, eigene Datei), `SheetEditorModel.swift`,
  `SheetGridView.swift` (zeichnet nur den sichtbaren Ausschnitt), `SheetEditorView.swift`.
- **Flüssig bleiben:** Gerechnet wird nur beim Anzeigen einer Tabelle. Der Kasten zeichnet nur den sichtbaren Teil;
  seine Auflösung ist begrenzt (`SheetBoxView.pixelBudget`), damit eine riesige Tabelle keinen Speicher frisst.
- **Grenzen der ersten Fassung:** 500 Zeilen × 52 Spalten. Kein Datum als Rechenwert (ein Datum ist Text), keine
  verbundenen Zellen, kein Zeilenumbruch in der Zelle, keine .xlsx-Dateien, keine Matrixformeln. Tippen direkt auf
  der Seite gibt es nicht – bearbeitet wird in der großen Ansicht. Am iPhone nur ansehen (wie alle Notizen dort).
  Web und Windows zeigen den Ersatztext; ändert dort jemand den Text, gewinnt beim nächsten Bearbeiten am iPad die
  Tabelle.

### 6.4 Tests und Bilder (26.11.2026)

- Kern: `SheetTests` 20 grün (Formeln, Bezüge umschreiben, Zeilen/Spalten, Sortieren, Filtern, Diagramm, Speichern,
  Community-Prüfung). Ganze Kern-Sammlung: 1857 Tests, 0 Fehler, 16 übersprungen.
- App, iPad-Simulator: `SheetAppTests` 7 grün (Seite und Export per Bildpunkt geprüft, Werkzeug + große Ansicht +
  Sichern + ein Schritt zurück, Sperre ohne Pro AI, eigene Datei, Gitter mit echten Berührungen: antippen, Doppeltipp,
  Zelle in die Formel tippen, Auswahl ziehen, mit dem Finger rollen). Zusammen mit elf benachbarten Editor-Klassen
  (TextBlock, StickyNote, EditorPalette, EditorStepEFHK, EditorToolbarLayout, AuditRunde0910, IPhoneReader, EditorStep6,
  BildGroesse, HardeningSolutionEditor, SolutionSideViewer): 142 grün (Lauf vor dem siebten Tabellen-Test).
- App, iPhone-Simulator: 51 grün (SheetAppTests, TextBlockAppTests, StickyNoteAppTests, IPhoneReaderTests).
- **Nicht gelaufen:** die ganze App-Testsammlung, die Mac-Tests (`tools/mac-test.sh`), nichts am echten Gerät.
  Bildschirmtastatur, Stift und das Gefühl beim Tippen kann nur der Inhaber am iPad beurteilen.
- Bilder: `~/Studora-Builds/textbloecke/bilder/23-ipad-tabelle-auf-der-seite.png`, `24-ipad-tabelle-grosse-ansicht.png`,
  `25-ipad-tabelle-formel-filter-kreis.png`, `26-iphone-tabelle-lesen.png`.

### 6.5 Testfassung fürs iPad (vorbereitet, NICHT aufgespielt)

- Eigener Zweig `test/ipad-editor-whisper-tabelle` @ `a7eecb3c` (mit KI-Hilfe, Stand 26.11.2026 09:12) = Stand auf dem iPad (`test/ipad-editor-whisper` @
  `88e732c1`: Editor-Neuheiten, Whisper, Handballen-Abwehr, Korrektur „Schreiben zittert“) + `editor/tabelle`.
  Ordner `~/Studora-Builds/wt-kombi-tabelle`, ohne Konflikte gemischt. `test/ipad-editor-whisper` selbst ist unberührt.
- Im Simulator 65 Tests grün (Sheet, TextBlock, EditorHandballen, EditorAusschnittRundung, EditorPalette); Kern 1860 grün.
- Gerätefassung gebaut: `~/Studora-Builds/dd-kombi-tabelle-geraet/Build/Products/Release-iphoneos/UniFlow.app`, 1.0.7 (49).
- Aufspielen nur mit dem Okay des Inhabers; danach der Handballen-Sitzung Bescheid geben, damit ihre nächste Fassung
  von diesem Zweig ausgeht.

### 6.6 KI-Hilfe für Tabellen und Diagramme (26.11.2026)

Auftrag des Inhabers (26.11.2026): „soll auch Diagramme durch KI und Tabellen mit Hilfe KI machen können … für Pro AI
Nutzer“.

- **Bedienung:** In der großen Ansicht steht vorn in der Leiste der Knopf **KI**. Antippen → Wunsch in eigenen Worten
  tippen (oder einen der vier Vorschläge antippen) → „Los“. Die KI bekommt die Tabelle und den Wunsch und baut Zellen
  (Text, Zahlen, Formeln) und Diagramme hinein. Unter der Eingabezeile steht danach, was sie getan hat. Alles
  zusammen ist **ein** Schritt: „Widerrufen“ nimmt es zurück.
- **Beispiele:** „Notenübersicht mit Schnitt“, „Lernplan für 4 Wochen“, „Rechne in Spalte D Note mal LP aus“,
  „Mach aus dieser Tabelle ein Kreisdiagramm“.
- **Tarif:** Die große Ansicht gibt es nur mit Pro AI, damit auch die KI-Hilfe. Jede Anfrage zählt wie eine Frage an
  die KI (Credits wie bisher, es werden keine Beträge gezeigt). Die Einwilligung zur KI fragt der vorhandene Weg ab.
- **Technik:** Kein neuer Weg im Dienst, **kein Server-Update**: Die App schickt eine gewöhnliche Frage an die
  KI-Hilfe (`POST /api/ai/tutor`, Modus `ask`; Tabelle im Seiteninhalt, Auftrag als Frage – beides in den Grenzen von
  `AIPrompts.tutor`: Frage ≤ 1000 Zeichen, Inhalt ≤ 9000). Der Auftrag verlangt ein JSON-Objekt
  `{neu, zellen, diagramme, hinweis}`. Gelesen wird großzügig (`SheetAI.parse`: JSON, auch in Markdown-Zäunen oder mit
  Sätzen drumherum; Zeilenlisten; ersatzweise eine Markdown-Tabelle), eingesetzt streng (`SheetAI.apply`: nur Zellen in
  den Grenzen, Formeln rechnet das eigene Rechenwerk, unbekannte Funktionen werden gezählt und gemeldet).
  Dateien: `UniFlowCore/SheetAI.swift`, `SheetEditorModel.runAI`, `SheetEditorView.aiPanel`, `SheetEditing.openSheet`.
- **Tests:** `SheetAITests` 3 (Auftrag passt in die Grenzen, sechs Arten von Antworten, Einsetzen), `SheetAppTests`
  jetzt 8 (KI baut Tabelle + Diagramm in einem Schritt, Diagramm aus vorhandener Tabelle, unbrauchbare Antwort,
  Fehler des Dienstes; die große Ansicht hängt am echten Weg der KI-Hilfe). Bilder `27-ipad-tabelle-ki-wunsch.png`,
  `28-ipad-tabelle-ki-ergebnis.png`.
- **Ehrlich:** Im Simulator gibt es keine KI. Die Tests und Bild 28 arbeiten mit einer **vorgegebenen** Antwort. Wie gut
  die echte KI den Auftrag befolgt (sie ist als Tutor eingestellt und schreibt sonst Erklärungen), zeigt erst der Test
  am iPad. Verlässlicher wäre eine eigene Aufgabe „Tabelle“ im Dienst mit festem Antwort-Format – das wäre ein
  Server-Update und braucht das Okay des Inhabers. Der Credits-Stand in der App aktualisiert sich erst bei der
  nächsten Anzeige (die große Ansicht hat keinen Zugriff auf die Kostenzeile).

## 7. Teil 5: Verweise auf Dokument + Seite

Zweig `editor/verweise` (auf Teil 3). Nachtrag des Inhabers vom 25.11.2026.

### Was geht

- Neues Werkzeug **„Verweis“** (Kettenglied, bei den Objektwerkzeugen), zwei Schritte:
  1. **Stelle festlegen:** antippen (ein blauer **Punkt**) oder **über ein Wort ziehen** (zart blau hinterlegt und
     unterstrichen wie ein Link) – egal ob das Wort getippt oder mit dem Stift geschrieben ist.
  2. **Ziel antippen:** genau die Stelle, auf die der Verweis zeigen soll – im **Dokument daneben** (geteilte
     Ansicht) oder auf einer **anderen Seite desselben Dokuments** (hinblättern, antippen).
  Unten steht, was gerade dran ist („Stelle antippen …“ / „Jetzt das Ziel antippen …“), mit „Abbrechen“ und „Fertig“.
- **Folgen:** Verweis antippen (beim Schreiben oder Lesen, ohne Objektwerkzeug):
  - anderes Dokument, **noch nicht offen** → es öffnet sich **daneben** auf der Seite, die Stelle leuchtet kurz auf;
  - anderes Dokument, **schon daneben offen** → es **springt** zur Seite (ohne neu zu laden), die Stelle leuchtet auf;
  - selbes Dokument → blättert zur Seite, die Stelle leuchtet auf;
  - Verweis im Dokument daneben, der ins Hauptdokument zeigt → das Hauptdokument blättert.
- Gemerkt wird: Dokument, Seite (fest über den Seitenschlüssel – bleibt richtig, wenn Seiten eingefügt oder
  umsortiert werden), genaue Stelle auf der Seite, Titel und Seitenzahl für die Beschriftung
  („Verweis auf Skript Zellbiologie, Seite 4“).
- Verweise liegen **über der Handschrift** (wie Klappkarten). Mit „Auswählen“ wählt Antippen den Verweis (statt ihm
  zu folgen): verschieben, Größe, löschen; langes Drücken greift ihn. Rückgängig je Schritt.
- Export/Drucken zeichnen Punkt bzw. Unterstreichung mit. Geräteabgleich und Community: gehen als Objekte der
  Seite mit.
- **iPhone:** Verweise im selben Dokument blättern in der Leseansicht zur Seite.
- **Tarif:** Anlegen ab Pro AI. **Folgen kann jeder**; das Öffnen daneben braucht wie bisher die geteilte Ansicht
  (ab Plus) – ohne sie erscheint die Tarifwahl.

### Was nicht geht bzw. anders ist

- **Ziel in einem anderen Dokument nur über „daneben“:** Zum Anlegen muss das Zieldokument daneben offen sein.
  Eine Auswahl „Dokument aus der Bibliothek + Seitenzahl eintippen“ gibt es nicht (ließe sich nachziehen).
- **Kein Verweis am einzelnen getippten Wort im Text selbst:** Der Verweis ist ein eigener Bereich über dem Wort.
  Bricht der Textblock später anders um, bleibt der Bereich an seiner Stelle und muss nachgeschoben werden.
- **iPhone:** Verweise auf **andere** Dokumente tun in der Leseansicht nichts (dort gibt es kein „daneben“).
- **Community:** Der Verweis geht mit, aber das Ziel ist ein Dokument aus der eigenen Bibliothek. Beim Empfänger
  klappt er nur, wenn er dasselbe Dokument hat (gleiche Datei aus demselben Stud.IP-Kurs); sonst erscheint „… ist
  auf diesem Gerät nicht vorhanden“. In der Ansicht „Lösung daneben“ wird Verweisen nicht gefolgt.
- **Ältere Apps, Web, Windows:** zeigen einen dünnen blauen Rahmen, ohne Funktion.
- In der exportierten PDF ist der Verweis ein Bild, kein anklickbarer Link.
- Wird das Zieldokument gelöscht, zeigt der Verweis ins Leere (Hinweis beim Antippen).

### Technik

- Format (Kern `PageLink.swift`): `type: "shape"`, `shape: "rect"` (blauer Rahmen ohne Füllung) mit
  `link: {file, title, page, pdfPage?, pageNumber, x, y, shape: point|area}`. `TopObjects` = Klappkarten + Verweise
  (Schicht über der Handschrift, zuletzt gezeichnet).
- Editor (`PageLinks.swift`): `LinkRender`/`LinkView`, Anlegen über `LinkPick` am gemeinsamen Werkzeugstand
  (`EditorToolState.linkPick` – beide Hälften der geteilten Ansicht sehen ihn), `LinkTargetPicker` (Tipp im Dokument
  daneben), `ObjectEditing.beginLink/finishLink/cancelLink`, Folgen `PDFEditorController.followLink/showLinkTarget/flash`.
- Dokumentansicht: `EditorBridge.linkRequest` → `DocumentView.openLink` (öffnet `Companion` bzw. findet den Editor
  daneben über `EditorToolState.otherEditor` und ruft `showLinkTarget`).
- Antippen: derselbe `CoverTapper` wie bei den Klappkarten (`onLink`).
- Genauer Startpunkt beim Ziehen (Klappkarte, Verweis): `ObjectEditing.panDown`.
- Tests: Kern `PageLinkTests` (4); App in `TextBlockAppTests`: `testVerweisImSelbenDokumentAnlegenUndFolgen`,
  `testVerweisInsDokumentDaneben`, `testVerweiseAnlegenAbProAIFolgenImmerUndExport`; der ganze Weg in der echten
  Dokumentansicht in `TextBlockBilderAppTests.test7IPadVerweise` (Bilder 20–22).

## 8. Gesamtstand und was der Inhaber prüfen sollte

| Zweig (lokal, gestapelt) | Inhalt |
|---|---|
| `editor/textbloecke` | Teil 1 + Tarif-Regel `UFRichNotes` |
| `editor/notizzettel` | + Teil 2 |
| `editor/klappkarten` | + Teil 3 |
| `editor/verweise` | + Teil 5 |
| `editor/tabelle` | + Teil 4 Tabelle (enthält alles, 26.11.2026) |

Nichts ist gepusht, nichts eingereicht, kein Server, keine Website. Arbeitsordner `~/Studora-Builds/wt-textbloecke`.

**Am iPad ausprobieren, bevor es ausgeliefert wird** (im Simulator mit echten Berührungen getestet, aber nicht am Gerät):
1. Tippen mit der Bildschirmtastatur: Sitzt die Leiste „Text“ über der Tastatur? Fühlt sich das Tippen auf den
   Linien richtig an?
2. Langes Drücken: Sind 3 Sekunden richtig oder zu lang? (eine Zeile: `ObjectEditing.holdSeconds`)
3. Schreiben mit dem Stift neben/auf Blöcken, Zetteln, Klappkarten: bleibt der Editor flüssig?
4. Klappkarten mit Finger und Stift antippen; Verweis antippen mit Dokument daneben.
5. Scribble (mit dem Pencil in einen Block schreiben).

**Offen für den Inhaber:**
- Text für die Tarifkarten (das Neue steht dort noch nicht).
- Teil 4 (Tabelle) ist gebaut (Abschnitt 6), aber noch nicht am iPad ausprobiert. Sie gehört zu Pro AI, kein Einzelverkauf (Antwort des Inhabers 26.11.).
- Web-Editor/Windows zeigen alles nur in einfacher Form – soll das dort auch gebaut werden?

## 9. Prüfläufe am 25.11.2026 (Stand `editor/verweise`)

| Lauf | Ergebnis |
|---|---|
| Kern (`swift test`, alles) | 1837 Tests, 0 Fehler (16 übersprungen); davon neu: `TextBlockTests` 14, `StickyNoteTests` 6, `FlipCoverTests` 5, `PageLinkTests` 4 |
| Python + Web (`tools/tests-schnell.sh`) | 4081 bestanden, **1 rot unter Last**: `tests/test_web_overview.py::test_overview_answers_what_to_do_today` – einzeln grün, auch auf `release/1.0.7-b47`; hat mit dem Editor nichts zu tun. Node: 472 bestanden |
| App, iPad-Simulator (52 Testdateien rund um Editor, Tarife, Community, Export, Leseansicht) | 511 Tests, 29 übersprungen (Bilder-/Messläufe ohne Schalter), **1 rot unter Last**: `EditorScaleTests/testTinteSpringtNichtBeimWechselAufDenAusschnitt` (zählt Messbilder in 1,6 s; 10 statt > 10). Einzeln wiederholt: 4 von 5 grün, das eine Rot bei Rechnerlast 53 |
| App, iPhone-Simulator (`TextBlockAppTests`, `StickyNoteAppTests`, `TextBlockBilderAppTests`, `IPhoneReaderTests`, `EditorStep6Tests`, `EditorPaletteTests`, `PlusWritingLockTests`, `SolutionSharingTests`) | 93 Tests, 0 Fehler |

Neue App-Tests: `TextBlockAppTests` 24 (Textblöcke, Notizzettel, Klappkarten, Verweise, Tarif), `StickyNoteAppTests` 4,
`TextBlockBilderAppTests` 7 (nur mit `TEST_RUNNER_UF_SCREENSHOT_DIR`; prüfen den Weg in der echten Dokumentansicht).

**Nicht gelaufen:** die ganze App-Testsammlung (nur die betroffenen Dateien), Mac-Tests (`tools/mac-test.sh`),
kein Build fürs Gerät, kein Test am echten iPad.

Bilder: `~/Studora-Builds/textbloecke/bilder/` (1–22, iPad und iPhone-Ansicht), `…/bilder-iphone/` (im iPhone-Simulator erzeugt).

## 10. Testfassung auf dem iPad des Inhabers

Seit **25.11.2026, 18:07** liegt auf dem iPad des Inhabers („StudiNow“, iPad A16) eine gemeinsame Testfassung 1.0.7 (49),
Release, per `devicectl`, mit seinem Okay („Ja, Testfassung“, „Ja, aufspielen“): Zweig `test/ipad-editor-whisper`
@ `a03251fe` = `editor/verweise` (alles aus dieser Unterlage) + `app/whisper-mitschrift` (die Whisper-Fassung, die er
gerade prüft – sie sollte nicht verschwinden). Zusammenführen ohne Konflikte; im Simulator 55 Tests grün
(`TextBlockAppTests`, `StickyNoteAppTests`, `WhisperViewsAppTests`, `EditorStep6Tests`, `PlusWritingLockTests`).
Arbeitsordner `~/Studora-Builds/wt-kombi`, Bau `~/Studora-Builds/dd-kombi-geraet`. Nicht bei Apple, kein TestFlight.

Sein Ergebnis steht aus (Punkte in Abschnitt 8). Spielt jemand danach eine reine Whisper-Fassung auf, sind die
Editor-Neuheiten wieder weg vom iPad.

## 11. Erste Rückmeldung vom iPad (25.11.2026 abends) und Korrektur

Inhaber: „man kann Notizzettel nicht verschieben … der blaue Kasten zum Verschieben drumherum verzögert stark und
Notizzettel geht nicht mit“.

- **Nachgestellt** (`TextBlockAppTests.testNotizzettelLaesstSichBeimTippenVerschieben`): Wird am Zettel gezogen,
  **während noch getippt wird** (Tastatur offen), bewegte sich nur der Auswahlrahmen und der ruhende, unsichtbare
  Zettel darunter – der sichtbare Zettel ist beim Tippen die Textansicht, und die blieb stehen. Ein gerade neu
  angelegter Zettel (noch nicht gespeichert, nicht ausgewählt) ließ sich gar nicht greifen.
  Ein **ausgewählter** Zettel ohne Tippen folgte dem Finger im Simulator sauber
  (`testNotizzettelFolgtDemFingerBeimVerschieben`).
- **Behoben:** Der Text, in dem getippt wird, folgt dem Finger (Zettel und Textblöcke): `ObjectEditing.editorGrip`
  (greift die Textansicht auch ohne Auswahl), `placeEditor(like:)` (Vorschau und gespeicherter Stand), Abgleich nach
  jedem Speichern in `commit`. Das Tippen geht dabei weiter; ein neuer Zettel merkt sich die Stelle und wird mit dem
  Text dort gespeichert. Auf linierten Seiten weiter zeilenweise.
- **Nicht nachstellbar:** das starke Nachlaufen des Rahmens selbst. Vermutung: die Textansicht hat die Berührung
  zuerst bekommen. Nach der Korrektur am iPad erneut prüfen; bleibt es, am Gerät messen.
- Tests danach: `TextBlockAppTests` 26 grün (iPad und iPhone), dazu 84 weitere Editor-Tests am iPad grün.
- Die korrigierte gemeinsame Fassung (`test/ipad-editor-whisper` @ `7c658ec5`) liegt seit 25.11.2026, 18:28 auf dem
  iPad des Inhabers (sein Okay „Ja, aufspielen“). Seine Antwort zum Nachlaufen steht aus.

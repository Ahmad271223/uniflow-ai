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

## 6. Teil 4: Tabelle – offene Fragen an den Inhaber

Vor dem Bauen zu klären (siehe Fragen im Bericht der Sitzung):

1. **Wo lebt die Tabelle?** (a) Als Kasten auf einer Seite (wie ein Textblock, verschieben/Größe) oder (b) als eigene
   Datei in der Bibliothek (eigener Bildschirm wie Excel) oder beides?
2. **Was heißt „sehr gut“?** Formeln (SUMME, MITTELWERT, WENN …)? Zahlenformate, Sortieren, Diagramme?
3. **Excel-Dateien (.xlsx) öffnen und speichern?** Das ist der größte Brocken.
4. **Community:** Soll eine Tabelle auf einer Seite beim Teilen mitgehen (als Bild der Tabelle bei älteren Apps)?
5. **Fremdbaustein erlaubt?** Für Formeln/xlsx gibt es Bausteine mit MIT/Apache-Lizenz; sie müssten geprüft und im
   Lizenz-Dialog (kommt mit `app/whisper-mitschrift`) eingetragen werden.

<!-- Bestandsaufnahme Web-Editor, erstellt 25.10.2026 aus dem Quelltext (Stand develop). Teil von WEB-IPAD-PARITAET.md. -->
# Inventar: Web-PDF-/Notizeditor (UniFlow Editor 2.0)

**Dateien** (alle Zeilenangaben als `Datei:Zeile`):
- `app/static/editor.js` (1046 Zeilen, Klasse `PdfEditor` ab Z. 61)
- `app/static/editor.css` (137 Zeilen)
- `app/static/merge.js` (64 Zeilen)
- `app/static/views-doc.js` (170 Zeilen)
- Ergänzend: `app/static/style.css` (Dokumentansicht, Split, Theme-Variablen), `app/server.py` (Endpunkte), `app/ai.py` (Tutor-Modi), `packages/shared-contracts/annotations.schema.json` und `.../fixtures/documents/web-editor.json` (Datenvertrag)

**Bibliotheken** (lazy geladen): pdf.js `./vendor/pdf.min.mjs?v=3` mit Worker (editor.js:12), Konva `./vendor/konva.min.js` 9.3.16 mit Puffer-Patch `patchKonva` (editor.js:38-45, 77), pdf-lib `./vendor/pdf-lib.min.js` erst beim Export (editor.js:966).

---

## A) Werkzeugleisten und Bedienelemente (in Reihenfolge)

### A1 Hauptleiste `.ed-bar.ed-main` (editor.js:193-220)
Klick-Verdrahtung: `[data-tool]` → `setTool(t, true)` (editor.js:239), `[data-act]` → `action(act, btn)` (editor.js:240, Map editor.js:843-853).

| # | Name / Icon | Funktion | Optionen | Datei:Zeile |
|---|---|---|---|---|
| **Linke Gruppe `.ed-left`** |||||
| 1 | Seitenleiste / `panel-left` | `toggleSide()`: Seitenleiste auf/zu | Tabs siehe A4 | editor.js:195, 345, 846 |
| 2 | Im Dokument suchen / `search` | Such-Popover `searchPop` | – | editor.js:196, 850, 854 |
| 3 | KI-Assistent / `sparkles` | blendet `.ed-ai` ein/aus | siehe A5 | editor.js:197, 848 |
| **Werkzeuggruppe `.ed-tools`** |||||
| 4 | Lasso (L) / `lasso` | Auswahlwerkzeug | Kontextleiste A2 | editor.js:200 |
| 5 | Stift (P) / `pen` | Freihandstift; kommt man vom Textmarker zurück, wird der letzte Stifttyp wiederhergestellt | 4 Stifttypen | editor.js:201, 606 |
| 6 | Textmarker / `highlighter` | setzt `penType="marker"`, Werkzeug intern `pen` | – | editor.js:202, 605 |
| 7 | Radierer (E) / `eraser` | Radieren | 3 Größen, 3 Modi | editor.js:203 |
| 8 | Text (T) / `type` | Textfeld setzen | Schrift/Format | editor.js:204 |
| 9 | Formen (S) / `square` | Formen zeichnen | 6 Formarten | editor.js:205 |
| 10 | Bild einfügen / `image` | Bild per Klick auf die Seite | – | editor.js:206 |
| 11 | Haftnotiz / `note` | Haftnotiz per Klick | Farbfelder | editor.js:207 |
| 12 | PDF-Text markieren (für KI) / `text-select` | Rechteck über PDF-Text ziehen → Text geht in das KI-Panel | – | editor.js:208 |
| 13 | Verschieben (Leertaste) / `hand` | Hand: Ansicht ziehen | – | editor.js:209 |
| 14 | Trenner `.ed-sep` | – | – | editor.js:210 |
| 15 | Zubehör / `more` + `chevron-down`(12) | Popover `accessoriesPop` | siehe A7 | editor.js:211, 887 |
| **Rechte Gruppe `.ed-right`** |||||
| 16 | Status-Pill `.ed-status` | Speicherstatus: Punkt plus Text, `data-state` saving/offline/saved | Texte siehe B „Autosave" | editor.js:214, 574 |
| 17 | Eingabe-Umschalter `.ed-peninput` | schaltet `penInput` zwischen `pen_only` und `all` um; `PUT /api/settings` | Anzeige `pen`+„Stift" (aktiv) oder `hand`+„Finger" | editor.js:215, 446, 845 |
| 18 | Seite hinzufügen / `page-plus` | Popover `addPagePop` | siehe A7 | editor.js:216, 855 |
| 19 | Teilen und Exportieren / `download` | Popover `exportPop` | siehe A7 | editor.js:217, 865 |
| 20 | Mehr / `more` | Popover `morePop` | siehe A7 | editor.js:218, 871 |

- Aktiv-Markierung: `updateToolButtons()`. Bei `penType==="marker"` leuchtet „Textmarker", nicht „Stift" (editor.js:442).
- Werkzeuge lassen sich über `prefs.hidden` ausblenden (editor.js:343).

### A2 Kontextleiste `.ed-bar.ed-ctx` (editor.js:221, Aufbau `renderCtx` editor.js:348-384)
**Immer sichtbar (links):** Rückgängig (`undo`, Tooltip „Strg+Z") und Wiederholen (`redo`, „Strg+Y") (editor.js:221). Beide gehen über `delegate` an den zuletzt aktiven Editor, wichtig in der geteilten Ansicht (editor.js:846).

Gemeinsamer Farbblock `sw()` (editor.js:350): 8 Farbfelder `SWATCHES` = `#1d2130, #5b6170, #9aa0ae, #e5322d, #22a55b, #9a2a2a, #2b5df0, #f5b400` (editor.js:34) plus Feld „Eigene Farbe" (`input type=color`).

| Werkzeug | Elemente in Reihenfolge | Optionen | Datei:Zeile |
|---|---|---|---|
| **pen** | (a) Stifttypen: Kugelschreiber `pen`, Füller `fountain`, Bleistift `pencil`, Textmarker `highlighter` (`data-pen`). (b) 3 Breiten-Presets `data-w`. (c) Regler „Strichstärke". (d) nur beim Marker: Regler „Deckkraft" (`circle`-Icon). (e) Farbfelder | Presets `WIDTHS=[1.2, 2.5, 5]` mit Balkenvorschau `height=min(12, 2+w*1.6)px`; Regler 0.5–40, Schritt 0.5; Deckkraft 0.1–1, Schritt 0.05. Ein Typwechsel setzt `PEN_DEFAULTS` | editor.js:351, 363-369 |
| **eraser** | (a) Größen Klein/Mittel/Groß (`data-esize`, Punktvorschau `s/2+6 px`). (b) Segment Teilweise / Ganzer Strich / Objekte (`data-emode`). (c) Hinweis „Radiert nur deine Notizen, nie das Original-PDF." | Größen 10/18/34 px; Modi `partial`/`whole`/`object`; gespeichert in `localStorage["ed-eraser"]` | editor.js:352, 370-371, 445 |
| **text** (auch wenn eine Auswahl Text enthält) | (a) Schriftart-Select (jede Option in ihrer eigenen Schrift), Schriftgröße (Zahl), Textfarbe. (b) Fett `bold`, Kursiv `italic`, Unterstrichen `underline`. (c) Ausrichtung `align-left`/`align-center`/`align-right`. (d) Zeilenabstand „↕"-Select, Hintergrundfarbe plus „Kein Hintergrund" (`x`, `data-act=nobg`), Transparenz-Regler | Schriften `FONTS` = Arial, Helvetica, Segoe UI, Verdana, Georgia, Times New Roman, Courier New, Comic Sans MS, Cambria Math (editor.js:24); Größe 6–120; Zeilenabstand 1 / 1.25 / 1.5 / 2; Hintergrund-Default im Picker `#ffffff`; Transparenz 0.1–1 | editor.js:353-355, 374-381 |
| **shape** | (a) Formarten `data-shape`: Linie `line`, Pfeil `arrow`, Rechteck `square`, Kreis/Ellipse `circle`, Dreieck `triangle`, Polygon `layers` (Tooltip „Klicks, Doppelklick beendet"). (b) Strichstärke-Regler (`pen`-Icon), Transparenz. (c) Farbfelder. (d) „Füllung"-Farbwahl plus „Keine Füllung" (`data-act=nofill`) | Strichstärke 0.5–20, Schritt 0.5; Transparenz 0.1–1; Füllungs-Default im Picker `#ffffff`; Formart `rect` voreingestellt (editor.js:66) | editor.js:356, 372-373 |
| **lasso** mit Auswahl | „N ausgewählt", Duplizieren (`copy`), Kopieren (`copy`), Ausschneiden (`eraser`-Icon), Löschen (`trash`). Ist das erste Objekt ein Strich oder eine Form, zusätzlich Breiten-Regler, Deckkraft und Farbfelder | Breite 0.5–40; Deckkraft 0.1–1 | editor.js:357 |
| **lasso** ohne Auswahl | Hinweis „Umkreise Notizen mit dem Lasso oder ziehe ein Rechteck…" | – | editor.js:357 |
| **image** | Hinweis (Klick oder Strg+V) und Button „Bild wählen" (`data-act=image`) | – | editor.js:358, 849 |
| **sticky** | Hinweis und Farbfelder `data-sticky` | Default `#fff7a8` | editor.js:359, 367 |
| **textselect** | Hinweis „Ziehe ein Rechteck über PDF-Text…" | – | editor.js:360 |
| **hand** | Hinweis „Ziehen zum Verschieben, Strg+Mausrad oder zwei Finger zum Zoomen." | – | editor.js:361 |

Auffälligkeiten:
- Der Text-Zweig wird vor `shape`/`lasso` geprüft. Enthält eine Lasso-Auswahl Text, erscheinen deshalb die Textregler statt Duplizieren/Kopieren/Löschen (editor.js:353).
- Das Feld „Eigene Farbe" bei der Haftnotiz (`data-sticky-custom`) hat keinen Listener und ist wirkungslos (editor.js:350/367).
- Nach jedem `renderCtx` wird `onToolState` aufgerufen (Werkzeug-Sync in der geteilten Ansicht, editor.js:383).

### A3 Seiten-Pill unten `.ed-pageinfo` (editor.js:236)
| Element | Funktion | Datei:Zeile |
|---|---|---|
| `chevron-left` (14) `prev` | vorige Seite | editor.js:847 |
| „Seite" + Zahlenfeld `.ed-pageno` (min 1) | `onchange` → `goToPage(n-1)` | editor.js:243 |
| „/" + `.ed-pagecount` | Seitenzahl | editor.js:400 |
| `chevron-right` `next` | nächste Seite | editor.js:847 |
| Trenner | – | – |
| Kleiner `zoom-out` | Zoom ÷ 1.2 | editor.js:847 |
| `.ed-zoom` | Anzeige „120%" | editor.js:897 |
| Größer `zoom-in` | Zoom × 1.2 | editor.js:847 |
| Seitenbreite `fit` | `fitWidth()` | editor.js:895 |
| Vollbild `maximize` | `toggleFullscreen()` (setzt Body-Klasse `fullscreen-doc`) | editor.js:902 |

### A4 Seitenleiste `.ed-side` (editor.js:223, Inhalt `renderSide` editor.js:801-822)
Kopf: Segment mit Seiten (`file`), Gliederung (`list`), Aufnahmen (`sync`) über `data-side` (editor.js:241), dazu Schließen (`x` 16, editor.js:242).
- **Seiten** (editor.js:804-808): Raster aus Miniaturen. Jede hat ein Canvas (Höhe 110), ein Lesezeichen-Badge (`bookmark` 12), die Fußzeile „N · Vorlagenname" bei Leerseiten und den Button „Seitenmenü" (`chevron-down` 14) → `pageMenu` (editor.js:826). Klick springt zur Seite, Drag&Drop sortiert um.
- **Gliederung** (editor.js:809-816): Kopf „Gliederung & Lesezeichen" mit „+" (`data-act=addoutline`). Einträge zeigen Icon `bookmark` bzw. `list`, einen editierbaren Titel (`contenteditable`), „S. n" und Entfernen (`x` 12). Darunter folgt der Block „PDF-Gliederung" aus `pdf.getOutline()`.
- **Aufnahmen** (editor.js:817-821): Button Aufnehmen/Stopp (`circle`, aktiv rot `.rec-on`) und Hinweistext (Mikrofon-Freigabe, Erlaubnis, „Transkription … nicht verfügbar"). Die Liste zeigt Titel, Löschen (`trash`), `<audio controls>` sowie „Seite n · Datum".

### A5 KI-Panel `.ed-ai` (editor.js:225-233)
Kopf „KI-Tutor" (`sparkles`), Seitenanzeige `.ed-ai-page`, Schließen. Darunter:
- **Modus**-Select mit 10 Optionen: explain „Markiertes erklären", explain_simple „Einfach erklären", summary „Seite zusammenfassen", terms „Fachbegriffe definieren", steps „Aufgabe schrittweise lösen", hints „Nur Hinweise geben", check „Meine Lösung prüfen", similar „Ähnliche Aufgabe erstellen", flashcards „Karteikarten erstellen", quiz „Quizfragen erstellen".
- „Markierter Text" (Textarea, 3 Zeilen).
- „Meine Lösung" (4 Zeilen, nur bei `check` sichtbar, editor.js:246).
- „Frage (optional)".
- Checkbox „Aktuelle Seite als Kontext mitgeben" (voreingestellt an).
- Button „Fragen" (editor.js:245), darunter die Ausgabe.

### A6 Zoom-Ansicht `.ed-zoomwin` (editor.js:235)
Kopf „Zoom-Ansicht" mit dem Hinweis „Schreibe hier, der Text erscheint an der markierten Stelle der Seite.", dazu die Buttons `data-zw`: Nach links (`chevron-left`), Nach rechts (`chevron-right`), Nächste Zeile (`chevron-down`), Schließen (`x`) (editor.js:247, 933). Darunter liegt das Schreib-Canvas `.ed-zw-canvas`.

### A7 Popover-Menüs (`.ed-pop`, Positionierung `showPop` editor.js:840)
Schließen bei Pointerdown außerhalb (editor.js:340) und mit Escape (editor.js:1005).

| Menü | Einträge in Reihenfolge | Datei:Zeile |
|---|---|---|
| **Im Dokument suchen** | Eingabe „Suchbegriff… (Enter)", Trefferliste (Links „S. n …Kontext…") | editor.js:854, 906 |
| **Seite hinzufügen** | Segment Vor dieser / Nach dieser (Default) / Letzte Seite. Unterkopf „Neue Vorlagen" mit Hinweis „Vorlagen übernehmen, wenn möglich, die Größe der aktuellen Seite." Vorlagen-Raster: Aktuelle Vorlage, Leer, Liniert, Kariert, Gepunktet, Millimeter, Cornell. Liste: Bild (`image`), PDF-Seiten importieren (`file-text`), Aktuelle Seite duplizieren (`copy`) | editor.js:855-864 |
| **Teilen und Exportieren** | Unterkopf „Zusammenarbeit": „Teilen…" (`users`, deaktiviert, „vorbereitet"). Unterkopf „Exportieren": Checkbox „Ohne Notizen exportieren", Diese Seite exportieren (`file`), Ausgewählte Seiten… (`list`), Alle exportieren (`download`), Drucken (`file-text`) | editor.js:865-870 |
| **Mehr** | Unterkopf „Seite „n"": Zu Favoriten hinzufügen / Aus Favoriten entfernen (`bookmark`), Seite kopieren (`copy`), Seite drehen (`rotate`), Seite zur Gliederung hinzufügen (`list`), Vorlage wechseln (`grid`), Gehe zu Seite (1 – N) (`arrow-right`), Seite leeren (`eraser`, danger), Seite in den Papierkorb legen (`trash`, danger), nur wenn vorhanden: „Papierkorb (n) – wiederherstellen" (`rotate`). Unterkopf „Einstellungen" (`data-pref`): Scrollrichtung (`move`) Vertikal/Horizontal; Seitenleiste (`panel-left`) Links/Rechts; Stylus- & Handballenerkennung (`pen`) „Finger darf schreiben" / „Nur Stift schreibt, Finger navigiert"; Dokumentbearbeitung (`file`) Fortlaufend / Einzelne Seite; dazu „Werkzeugleiste anpassen" (`settings`) | editor.js:871-884 |
| **Papierkorb** | je gelöschte Seite „Notizseite" bzw. „PDF-Seite n wiederherstellen" mit Uhrzeit, danach „Papierkorb leeren" (danger) | editor.js:885 |
| **Werkzeugleiste anpassen** | Checkboxen Lasso, Stift, Radierer, Text, Formen, Bild, Haftnotiz, PDF-Text markieren, Hand (Textmarker fehlt in der Liste) und der Hinweis „Stiftfarben und -stärken merkt sich die Kontextleiste automatisch." | editor.js:886 |
| **Zubehör** | Aufnehmen / Aufnahme stoppen (`circle`), Aufnahmen anzeigen (`sync`), Zoom-Ansicht (Zusatz „(aus)", wenn aktiv; `zoom-in`), Lineal (Zusatz „(aus)"; `line`), Zeitmesser (`clock`), leerer Unterkopf als Trenner, Werkzeugleiste anpassen (`settings`) | editor.js:887 |
| **Seitenmenü** (Miniatur) | Kopf „Seite „n"": Favoriten-Toggle, „Seite kopieren (duplizieren)", Seite drehen, Seite zur Gliederung hinzufügen, Vorlage wechseln, Gehe zu Seite (1 – N), Seite leeren, Seite in den Papierkorb legen | editor.js:826-838 |
| **Vorlage wechseln** | Raster mit Leer, Liniert, Kariert, Gepunktet, Millimeter, Cornell | editor.js:839 |

### A8 Umgebende Leisten der Dokumentansicht (views-doc.js)
- **Kopfleiste `.doc-top`** (views-doc.js:22-26), in dieser Reihenfolge:
  - Menü (`menu`, nur ≤900 px)
  - Zurück (`chevron-left` + „Dokumente")
  - Tabs `#docTabs` (aus `localStorage["uniflow-doc-tabs"]`, max. 12; je Tab mit `file-text`, Titel und Schließen-x; views-doc.js:105-111)
  - „Erledigt" (`check`, nur mit `?task=`)
  - Status-Select neu/gelesen/erledigt
  - Favorit (`star`, Farbe `--warn` bzw. `--muted`)
  - Notizen (`note`)
  - Geteilt (`columns`)
  - Vollbild (`maximize`)
- **Vollbild-Ausgang** `#fsExit` „Vollbild beenden" (views-doc.js:27).
- **Pane-B-Leiste** `.pane-bar`: `book`-Icon, Titel, „Schließen" (views-doc.js:70).
- **Split-Trenner** `#splitHandle` (views-doc.js:28, 50-55).
- **Notizfläche** `#paneN`: Kopf „Eigene Notizen" mit „gespeichert"-Anzeige und Textarea (views-doc.js:28, 39).
- **Skript-Hinweis** `.script-hint`: `book`, „Passende Skriptstelle [zu Aufgabe X]", Titel · Seite, Buttons „Öffnen" (`columns`) und Ausblenden (`x`) (views-doc.js:96).
- **Zeitmesser-Widget**: Segment Stoppuhr/Countdown/Pomodoro, Schließen, große Zeitanzeige, Countdown-Chips 5/15/25/45/60 min, Pomodoro-Zeile „Arbeiten/Pause · Runde n · 25/5 min", Buttons Start/Pause und Zurücksetzen. Ist das Widget zu und läuft die Zeit, erscheint die Pill `#timerPill` (views-doc.js:149-170).

---

## B) Funktionen

### B1 Stifttypen
- Defaults `PEN_DEFAULTS` (editor.js:32): pen Breite 2.2 / Deckkraft 1; fountain 2.6 / 1; pencil 1.8 / 0.75; marker 16 / 0.35.
- Beim Werkzeugwechsel auf `pen` werden die Defaults gesetzt, außer die Werte kamen per `applyToolState` (dann `_penCustom`) (editor.js:609, 444).
- Darstellung:
  - Kugelschreiber, Füller und Bleistift ab 2 Punkten als `Konva.Shape` `makeInkShape` mit variabler Breite je Segment und quadratischen Mittelpunkt-Kurven (editor.js:537-555).
  - Bei Deckkraft < 1 oder ohne `widths` wird ein einzelner Pfad mit mittlerer Breite gezeichnet (editor.js:540, 545).
  - Bleistift ist gestrichelt `[1.5, 1.2]` (editor.js:543, 506, 627).
  - Ein Einzelpunkt wird als Kreis gezeichnet (editor.js:544).
  - Marker: `Konva.Line` mit `globalCompositeOperation: "multiply"`, Tension 0 (andere Linien 0.25 bei < 24 Punkten), `hitStrokeWidth=max(12, width)` (editor.js:505).

### B2 Druck- und Breitenmodell `penWidth` (editor.js:624)
- Druck: `ev.pressure` bei `pointerType==="pen"` und Druck > 0, sonst 0.5 (editor.js:641).
- Geschwindigkeit `sp=min(1, speed/2.2)` mit `speed = Abstand/dt` in Seitenpunkten pro ms (editor.js:629).
- Formeln:
  - Marker: konstant `base`.
  - Füller: `base*(0.45+1.1*pr)*(1.15-0.5*sp)`.
  - Bleistift: `tilt=min(1, hypot(tiltX, tiltY)/60)`, `base*(0.8+0.3*pr+0.9*tilt)`.
  - Kugelschreiber: `base*(0.9+0.2*pr)*(1.03-0.1*sp)`.
  - Glättung `prev*0.65 + w*0.35`.
- Positionsglättung (nicht bei Marker und Lineal): `p = last + (p-last)*0.6`. Mindestabstand `0.35/zoom` (editor.js:628-629). Am Ende wird der Rohpunkt angehängt, wenn er mehr als `0.3/zoom` entfernt ist (editor.js:631).
- Live-Zeichnung auf `canvas.ed-live` mit Coalesced Events (editor.js:667-668). Vorhersage auf `canvas.ed-predict` mit bis zu 3 `getPredictedEvents` (editor.js:630, 669). Bei Deckkraft < 1 wird der ganze Pfad neu gezeichnet (editor.js:629).
- Gespeichert werden `width` als Mittelwert (2 Nachkommastellen) und `widths[]` nur, wenn kein Marker und die Spannweite > 0.05 ist. Punkte werden auf 2 Stellen gerundet; ein Ein-Punkt-Strich wird zu 2 Punkten (+0.05) (editor.js:631).
- Stifteingabe läuft über native Pointer-Events am Seitenelement mit `setPointerCapture`. Das Pointer-Handling von Konva (Stage-Pointerdown) übernimmt die Striche nicht (editor.js:637-678, 684).
- Ausstehender Zoom wird vor dem Strich abgeschlossen (`flushZoom`, editor.js:656). `html.ed-inking` wird während des Strichs gesetzt (editor.js:658).

### B3 Handballenerkennung (editor.js:257-331)
- `PALM_AFTER_PEN=500` ms, `PAN_SLOP=8` px (editor.js:259).
- Eine Berührung gilt als Handballen, wenn der Stift unten ist, das Abheben weniger als 500 ms zurückliegt oder die Kontaktfläche > 90×90 px ist (editor.js:263, 277). Was beim Stift-Aufsetzen schon aufliegt, wird als Ballen markiert (editor.js:268).
- `allowPointer`: Touch ist blockiert bei `pen_only`, bei Stift unten, bis 1200 ms nach Stiftkontakt und bei mehr als einem Pointer. Bei der Maus zählt nur die linke Taste (editor.js:618).
- Unterdrückt werden Safari-Markierung, Lupe, Kontextmenü und Gesten-Zoom (editor.js:316-326). Ausnahmen: Werkzeuge text/sticky/image und Eingabefelder.
- Sicherheitsnetze: `window` pointerup/cancel beendet den Strich (editor.js:328-329). `visibilitychange`, `blur` und `pagehide` setzen die Eingabe zurück und speichern den Entwurf (editor.js:330-331).

### B4 Nur-Stift- vs. Finger-Modus
- Startwert: `opts.penInput` aus `settings.pen_input`, sonst „all" (editor.js:70, views-doc.js:37).
- Automatik: Beim ersten Stiftkontakt wird auf `pen_only` geschaltet, sofern nicht manuell gesetzt (`_penManual`). Status: „Apple Pencil erkannt – Finger scrollt und zoomt", dazu `PUT /api/settings {pen_input:"pen_only"}` (editor.js:271).
- Manuell über den Button (editor.js:845) oder „Mehr → Stylus- & Handballenerkennung" (editor.js:883); beide speichern per `PUT /api/settings`.
- Bei `pen_only` (ebenso Hand-Werkzeug oder Leertaste) gilt:
  - 1 Finger scrollt mit Trägheit: Fling, wenn der Weg > 30 px und die letzte Bewegung < 60 ms her ist; Abklingen 0.94 je 16 ms (editor.js:286-287, 298-301, 312, 898).
  - 2 Finger zoomen per Pinch (siehe B21).
  - 2 Finger verwerfen außerdem den Finger-Strich der ersten Berührung (editor.js:283).

### B5 Radierer (editor.js:729-747)
- Radius `eraserSize/2/zoom + 1` in Seitenpunkten.
- **Teilweise** (`partial`): Strichpunkte im Radius (plus halbe Strichbreite) werden entfernt, der Rest wird in Teilstriche zerlegt, `widths` bleiben erhalten (editor.js:737-741).
- **Ganzer Strich** (`whole`): Strich oder Form (Linien-basiert) wird entfernt, wenn der Segmentabstand < r + Breite/2 ist (`distSeg`, editor.js:743-744, 1034).
- **Objekte** (`object`): entfernt Nicht-Strich-Objekte (Text, Form, Bild), deren Bounding-Box getroffen wird (editor.js:733).
- Rechteck- und Ellipse-Formen haben keine `points()` und lassen sich daher nur im Objekt-Modus radieren (editor.js:736).
- Ein Radiervorgang ist ein Undo-Schritt (Snapshot vorher, editor.js:660, 649).
- Hover-Cursor: Kreis in `eraserSize` px mit Rand `#888` (editor.js:334).

### B6 Lasso, Auswahl, Bearbeiten
- **Freihand-Lasso**: Polygon (gestrichelt `#4f5bd5`). Ausgewählt wird jedes Objekt, dessen Bounding-Box-Mittelpunkt im Polygon liegt (`pointInPoly`) (editor.js:690, 711, 753, 1035).
- **Rechteck**: Shift+Ziehen. Ausgewählt wird, was vollständig innen liegt; Box > 3×3 (editor.js:690, 712, 754).
- **Klick** auf ein Objekt wählt es aus, Shift+Klick schaltet um (nur auf derselben Seite) (editor.js:718, 751).
- **Verschieben/Skalieren/Drehen**: `Konva.Transformer` mit rotateEnabled, keepRatio false, padding 4, anchorSize 9, Rand/Anker `#4f5bd5` und 8 Ankern (editor.js:436). Objekte sind nur im Lasso-Modus `draggable`, der Objekt-Layer hört nur dann auf Ereignisse (editor.js:612). Nach dragend/transformend schreibt `syncNode` zurück. Bei Text wird scaleX zur Breite (min. 40) und scaleY zur Schriftgröße (6–200) (editor.js:528, 531-536).
- **Kopieren** (`copySelection`, interne Zwischenablage, editor.js:756).
- **Einfügen** `paste(offset=20)` auf die aktuelle Seite, danach Lasso-Auswahl (editor.js:757). Ausgelöst über das Paste-Ereignis, wenn kein Bild in der Zwischenablage liegt (editor.js:782).
- **Duplizieren** = Kopieren + Einfügen mit Versatz 18 (editor.js:758).
- **Ausschneiden** (editor.js:846, 1001), **Löschen** (editor.js:755).
- **Eigenschaften ändern** über `applyToSelection` (Farbe, Breite mit proportional skalierten `widths`, Deckkraft, Füllung) (editor.js:617).
- **Textstil** auf ausgewählte Texte über `setTextStyle` (editor.js:615).

### B7 Formen (editor.js:694, 706, 714, 721-727)
- Arten: line, arrow (Spitze `max(8, strokeWidth*3)`, Füllung = Strichfarbe), rect, ellipse, triangle, polygon.
- Polygon: Klicks setzen Punkte, Vorschau folgt der Maus. Doppelklick (editor.js:719) oder Escape (editor.js:1005) beendet; mindestens 3 Punkte.
- Gespeichert wird nur, wenn Breite > 2 ist oder Punkte vorhanden sind (editor.js:714).
- Beim Wechsel auf das Formen-Werkzeug wird die Deckkraft auf 1 gesetzt (editor.js:610). Hit-Breite 12 (editor.js:513).

### B8 Textfelder (editor.js:761-772)
- Erzeugen: Klick auf eine leere Stelle der Seite (`e.target===stage`) → Objekt mit `textStyle`. `DEFAULT_TEXT`: Arial, 14, `#1d2130`, Breite 220, lineHeight 1.25, links, kein Hintergrund, Deckkraft 1 (editor.js:58, 691).
- Bearbeiten über eine Textarea-Überlagerung `.ed-textedit` mit den Objektstilen (editor.js:767). Abschluss mit Blur oder Strg/Cmd+Enter, Abbruch mit Escape. Ein leerer Text löscht das Objekt.
- Doppelklick/-tipp auf bestehenden Text öffnet die Bearbeitung (editor.js:511), praktisch nur im Lasso-Modus, weil der Layer sonst nicht hört.
- Konva-Darstellung: Group aus Rect (Hintergrund, cornerRadius 3) und Text (padding 4, Umbruch nach Wörtern) (editor.js:508-511).
- Formatierung: Schrift, Größe, Farbe, B/I/U, Ausrichtung, Hintergrund, Zeilenabstand und Deckkraft (siehe A2). Tastenkürzel Strg+B/I/U (editor.js:1003).

### B9 Haftnotizen (editor.js:762)
Textobjekt mit `bg=stickyColor` (Default `#fff7a8`), Breite 170, Größe 13 und Versatz −10/−10 zum Klickpunkt.

### B10 Bilder
- Einfügen über:
  - Klick auf die Seite mit dem Bild-Werkzeug (Position merken, Dateiauswahl) (editor.js:693, 849)
  - Button „Bild wählen"
  - Screenshot per Strg+V (editor.js:782)
- Upload: `POST /api/files/{id}/assets` (FormData `upload`) → `{url}` (editor.js:777-779).
- Platzierung: skaliert auf maximal 50 % der Seitenbreite, Default-Position `(w*0.25, 60)`; danach Lasso-Auswahl (editor.js:780).
- Bild als eigene Seite (`imageAsPage`): neue Leerseite in Größe der aktuellen Seite, Bild eingepasst mit 40 Rand bei (20,20) (editor.js:798).
- **Zuschnitt**: Das Modell kennt `o.crop`, angewendet über `node.crop(o.crop)` (editor.js:522). Eine Zuschnitt-UI gibt es nicht.

### B11 Lineal (editor.js:911-926)
- Ein/aus über das Zubehör-Menü.
- Konva-Gruppe auf dem `tmp`-Layer: Länge 400, Höhe 34, Teilstriche alle 10 (lang alle 50), Winkelanzeige und Drehknopf (Kreis r 11 am rechten Ende). Startet in Bildmitte und folgt der aktuellen Seite (editor.js:890).
- Bedienung mit Finger oder Maus, nicht mit dem Stift (editor.js:264):
  - 1 Finger verschiebt.
  - 2 Finger drehen und verschieben.
  - Ziehen am Knopf dreht.
  - Einrasten auf Vielfache von 45° bei < 2° Abstand (editor.js:923).
  - Trefferzone: Maus ohne Rand (die Kante bleibt zeichenbar), Touch mit 12/zoom Rand (editor.js:914).
- Stiftführung (`rulerProject`): Beginnt ein Strich im Band −16…6 bzw. 28…50 quer zum Lineal (längs −10…len+10), wird er auf die Kante −3 bzw. 37 projiziert (editor.js:926, 627-628).

### B12 Zoom-Ansicht (editor.js:929-933)
- Unterer Bereich mit Canvas, das einen Ausschnitt der aktuellen Seite in Faktor 3 zeigt. Start: x 40, y 60, w 260, h 70; w/h werden aus der Größe des Bereichs neu berechnet.
- Auf der Seite markiert ein gestricheltes Rechteck den Ausschnitt.
- Schreiben im Canvas erzeugt Striche auf der Seite. Der Radierer funktioniert ebenfalls; jedes andere Werkzeug schaltet auf Stift.
- Nähert sich der Strich dem rechten Rand (< 12), springt der Ausschnitt automatisch nach rechts.
- Buttons: links/rechts in 45 %-Schritten der Breite; „Nächste Zeile" geht 80 % der Höhe nach unten und setzt x auf 40.
- Das Rechteck ist `draggable`, liegt aber auf dem nicht hörenden `tmp`-Layer. Ziehen wirkt daher vermutlich nicht.

### B13 Seitenverwaltung (editor.js:785-798)
- **Leerseite einfügen** (`addBlankPage`): Schlüssel `"b"+uid`, Größe = `baseW/baseH` der aktuellen Seite (Default 595×842). Position vor/nach der aktuellen Seite oder am Ende (editor.js:786-787, 857-862). „Aktuelle Vorlage" nimmt bei einer Leerseite deren Vorlage und dupliziert bei einer PDF-Seite.
- **Vorlagen** `TEMPLATES` (editor.js:25), Zeichnung in `renderTemplate` (editor.js:485-495):
  - Leer.
  - Liniert und Cornell: Linien ab y=60, Abstand 24 pt.
  - Kariert und Gepunktet: Raster 14.17 pt (5 mm).
  - Millimeter: Raster 2.835 pt, jede 10. Linie 1.2 statt 0.5.
  - Cornell zusätzlich: senkrechte Linie bei x=150, waagerechte bei H−150 (`#b9c2d6`, 1.4), Beschriftungen „Stichworte", „Notizen", „Zusammenfassung".
  - Hintergrund `#ffffff`, bei Cornell `#fffdf7`.
- **PDF-Seiten importieren**: `POST /api/files/{id}/assets?kind=pdf` → jede Seite als `type:"asset"` mit Schlüssel `"a"+uid` (editor.js:797). Gerendert wird per `assetDoc` (fetch der Asset-URL, Cache) (editor.js:496).
- **Duplizieren**: neuer Schlüssel `p{index}c{uid}` bzw. `b{uid}`, Objekte mit neuen IDs (editor.js:788).
- **Drehen**: +90° (`rotation` im pageOrder-Eintrag) (editor.js:789).
- **Löschen**: in `deletedPages` (Papierkorb), nicht möglich bei nur einer Seite; Status „Seite in den Papierkorb gelegt (Mehr → Papierkorb)" (editor.js:790). Wiederherstellen (editor.js:791), Papierkorb leeren (editor.js:885).
- **Seite leeren** mit Bestätigungsdialog (editor.js:792, 837).
- **Umsortieren** per HTML5-Drag&Drop der Miniaturen (editor.js:805, 793).
- **Vorlage wechseln** (`setTemplate`): macht auch aus einer PDF-Seite eine Leerseite (`delete p.index`). Der PDF-Inhalt verschwindet, die Notizen bleiben (editor.js:794).
- **Lesezeichen/Favoriten**: `{key, title:"Seite n"}` (editor.js:795). **Gliederung**: Titel per `prompt` (editor.js:796); Titel inline editierbar, löschbar (editor.js:813-814). **PDF-Gliederung**: bis 60 Einträge (editor.js:825).
- **Gehe zu Seite** per `prompt` (editor.js:837).
- Alle Strukturänderungen laufen über `commitPages` und lassen sich rückgängig machen.

### B14 Miniaturen-Seitenleiste (editor.js:804-808, 823-824)
- Raster mit 2 Spalten.
- Lazy-Rendering per IntersectionObserver (`rootMargin` 300px): PDF-/Asset-Seite per pdf.js mit Canvas-Höhe 110; Leerseite als vereinfachtes Vorlagenmuster.
- Aktive Seite hervorgehoben, Lesezeichen-Badge.

### B15 Suche im PDF-Text (editor.js:906-907)
- Text je Seite aus `getTextContent()`, mit Leerzeichen verbunden und gecacht.
- Groß-/Kleinschreibung egal, erster Treffer je Seite mit 30/40 Zeichen Kontext.
- Durchsucht nur Seiten vom Typ `pdf`, keine Asset- oder Leerseiten.

### B16 PDF-Text markieren (editor.js:695, 713, 908)
- Rechteck (gelb). Die Textelemente im Rechteck werden nach Zeilen (y/4) und x sortiert und zusammengesetzt.
- Ergebnis landet im KI-Feld „Markierter Text", das Panel öffnet sich.
- Nur auf `pdf`-Seiten.

### B17 KI-Tutor (editor.js:947-962)
- Anfrage: `POST /api/ai/tutor` mit Body `{file_id, page (PDF-Index oder null), mode, selection, question, own_solution, page_text}`.
- `quiz` wird als `mode:"similar"` gesendet, an die Frage wird „Erstelle 5 Quizfragen mit Lösungen zur Seite." angehängt.
- Kontext:
  - PDF-Seite: `pageText`.
  - Leerseite: die Textobjekte plus „[Handschrift auf Notizseiten kann nicht gelesen werden]".
  - Fehlt `page_text`, liest der Server selbst per pypdf (server.py:475-476).
- Server-Modi in ai.py:167-177: explain, explain_simple, summary, steps, hints, check, similar, terms, flashcards. Fehlt der Modus, gilt explain.
- Antwort `{answer, cards}`:
  - Bei `flashcards` werden Karten angezeigt, dazu der Button „Karteikarten speichern (n)" → `POST /api/flashcards {file_id, cards}` (server.py:504).
  - Sonst Markdown-Render `md()` (editor.js:1038-1046) und der Button „Als Textfeld einfügen": Textobjekt bei (20,20), bg `#e8eeff`, Breite `min(320, w-40)`, Größe 11, Zeichen `*#/`` entfernt (editor.js:959).

### B18 Audioaufnahme (editor.js:936-944, 817-821)
- `getUserMedia({audio:true})` mit `MediaRecorder`; Status „● Aufnahme läuft…".
- Beim Stoppen: `POST /api/files/{id}/recordings` mit FormData `upload` (aufnahme.webm), `page`, `duration` (server.py:1505; Titel serverseitig „Aufnahme TT.MM. HH:MM").
- Liste: `GET /api/files/{id}/recordings`. Löschen: `DELETE /api/recordings/{id}` (server.py:1499, 1520).

### B19 Export und Drucken (editor.js:965-994)
- Basis pdf-lib:
  - PDF-Seiten werden aus den Originalbytes (`pdfBytes`) kopiert.
  - Asset-Seiten aus dem per fetch geladenen Asset-PDF.
  - Leerseiten werden neu angelegt, die Vorlage als Vektor gezeichnet (`drawTemplatePdf`, Farbe `rgb(.85,.87,.91)`, editor.js:994).
- Drehung per `setRotation`.
- Notizen werden gerastert: unsichtbare Konva-Stage in Skalierung 2 → PNG, über die ganze Seite gelegt (editor.js:980-986).
- Optionen:
  - „Ohne Notizen exportieren"
  - Diese Seite
  - Ausgewählte Seiten (`prompt` „1-3,5", `parseRange` editor.js:1037)
  - Alle exportieren
  - Drucken: Blob-URL in neuem Fenster, dann `print()`
- Dateiname: `Name (Seite 1,2).pdf` bzw. `Name (annotiert).pdf`.
- Auffälligkeit: Bei gedrehten Seiten wird das PNG (mit getauschten Maßen) ohne Drehung auf `getSize()` gelegt, beide Zweige sind identisch (editor.js:985-986). Mögliche Verzerrung.

### B20 Rückgängig / Wiederholen (editor.js:559-568)
- Stack mit maximal 150 Einträgen. Drei Arten:
  - Seiten-Snapshot `{key, before, after}` (`commit`)
  - Strich-Hinzufügen `{key, id, addJson}` (günstig, `unAdd`/`reAdd`)
  - Seitenstruktur `{pages:true, before, after, snapPages}`
- Jede neue Änderung leert `future`. Eine Server-Zusammenführung leert die ganze Historie (editor.js:148).
- Lesezeichen, Gliederung, Dokumentnotiz und Zoom sind nicht rückgängig zu machen.

### B21 Zoom, Pinch, Seitenbreite (editor.js:893-901)
- Bereich 0.3–6, Default 1.2 (gespeichert in `model.zoom`).
- Buttons ×/÷1.2. Strg/Cmd+Mausrad ×1.1/0.9 am Cursor (editor.js:254). Strg+/−/0.
- Seitenbreite: `(clientWidth-40)/page.w`. `fitPage` ist definiert, wird aber nicht genutzt (editor.js:896).
- Ein Ankerpunkt bleibt beim Zoomen stehen.
- Der Zoom wirkt sofort als CSS-Skalierung; Stage und PDF werden nach 220 ms scharf neu gezeichnet (editor.js:410-412).
- Pinch: CSS-`transform` auf `.ed-pages`, Übernahme beim Loslassen (editor.js:899-901).
- Zoom setzt `dirty` und speichert nach 2.5 s (editor.js:893).

### B22 Scrollrichtung, Einzelseite, Seitenleiste links/rechts
- Gespeichert in `prefs` in `localStorage["ed-prefs"]` als `{scroll, single, sidebar, hidden[]}` (editor.js:72, 343-344).
- Horizontal: `.ed-scroll.horizontal` stellt die Seiten in einer Zeile dar.
- Einzelseite (`showSingle`): blendet die anderen Seiten aus; Blättern mit Pfeil links/rechts (editor.js:418, 892, 1007).
- Aktuelle Seite: die letzte Seite, deren Oberkante oberhalb von scrollTop + 1/3 der Höhe liegt (horizontal: Mitte der Breite) (editor.js:891).
- Überscroll-Polster: 60 % der Ansicht je Seite. `clampView` mit Rand 12/10 und 200-ms-Ease-out (editor.js:415-417).

### B23 Vollbild
- `document.body.classList.toggle("fullscreen-doc")`, keine Fullscreen-API (editor.js:902, views-doc.js:33-34). Auslösbar auch mit F11.
- Blendet App-Sidebar, Header und `.doc-top` aus und zeigt „Vollbild beenden" (style.css:230, 445-446).

### B24 Tastenkürzel (`onKey` editor.js:997-1009)
Der Listener hängt an `.ed-scroll` (tabindex 0, editor.js:255). Ignoriert wird bei Textbearbeitung und Fokus in INPUT/TEXTAREA/SELECT.

| Taste | Aktion |
|---|---|
| Strg/Cmd+Z | Rückgängig |
| Strg/Cmd+Shift+Z | Wiederholen |
| Strg/Cmd+Y | Wiederholen |
| Strg/Cmd+C | Auswahl kopieren |
| Strg/Cmd+X | Ausschneiden |
| Strg/Cmd+D | Duplizieren |
| Strg/Cmd+V | Einfügen (Paste-Ereignis am Container: Bild aus der Zwischenablage oder interne Zwischenablage, editor.js:256, 782) |
| Strg/Cmd + `+` oder `=` | Zoom × 1.2 |
| Strg/Cmd + `-` | Zoom ÷ 1.2 |
| Strg/Cmd + 0 | Seitenbreite |
| Strg/Cmd+B / I / U | Fett / Kursiv / Unterstrichen umschalten |
| Entf / Rücktaste | Auswahl löschen |
| Escape | Auswahl aufheben, Popover schließen, Polygon beenden |
| V oder L | Lasso |
| P | Stift (Typ Kugelschreiber) |
| H | Textmarker (nicht die Hand!) |
| E | Radierer |
| T | Text |
| S | Formen |
| Bild ab / Bild auf | nächste / vorige Seite |
| Pfeil rechts / links | nächste / vorige Seite (nur im Einzelseitenmodus) |
| F11 | Vollbild (Body-Klasse) |
| Leertaste gedrückt halten | temporäre Hand (Fokus im Editor nötig, editor.js:338-339) |
| Strg/Cmd+Mausrad | Zoom am Cursor (editor.js:254) |
| In der Textbearbeitung | Escape bricht ab, Strg/Cmd+Enter übernimmt (editor.js:771) |
| Im Suchfeld | Enter sucht (editor.js:854) |
| Global (app.js:28) | Strg/Cmd+K fokussiert die App-Suche |

### B25 Autosave, Entwürfe, Zusammenführung, Offline (editor.js:16-22, 102-154, 569-600)
- **IndexedDB** `lernapp-editor` v2 mit den Stores `drafts` (keyPath `fileId`) und `thumbs` (keyPath `key`) (editor.js:18).
- **Laden** (`loadModel`, editor.js:102-124): `GET /api/files/{id}/annotations` (Server-Default `{data:{version:2,pages:{},zoom:1.2}, updated_at:null, version:0}`, server.py:365-371) und der IDB-Entwurf.
  - Entwurf ungesendet und Version ≥ Server: Entwurf gilt.
  - Entwurf ungesendet, aber älter: `mergeInto` (Drei-Wege, Basis = `draft.basePages`). Status „Offline-Notizen mit neuerem Stand zusammengeführt" (editor.js:99).
  - Sonst gilt der Serverstand.
- **Ändern** (`markDirty`): Status „Speichert…", `scheduleSave` (1200 ms), lokaler Entwurf spätestens nach 1.5 s (`_draftSoon`; beim Schreiben um 300 ms verschoben) (editor.js:569-573).
- **`_saveTick`**: wartet, solange der Stift unten ist (bis 15 s) und bis 900 ms nach dem Abheben (höchstens 20 s gesamt). Dann IDB-Entwurf und `flush` (editor.js:576).
- **`flush`** (editor.js:577-600): `PUT /api/files/{id}/annotations?base_version=N` mit dem ganzen Modell.
  - Antwort 409 `{detail, version, data}`: `applyServerMerge` (Seiten neu aufbauen bzw. geänderte Seiten neu laden; Status „Mit anderem Gerät zusammengeführt") und Neuversuch, höchstens 3 Konflikte.
  - Erfolg `{ok, version}`: neue Basis. Wurde während des Sendens weitergeschrieben, wird neu geplant, sonst Entwurf mit `dirty:false` und Status „Gespeichert".
  - Fehler: Status „Offline – wird nachgeholt", Neuversuch alle 15 s. Das `online`-Ereignis löst `flush` aus (editor.js:100).
  - Server: atomar mit `BEGIN IMMEDIATE`, Versionshistorie mit 30 Ständen (server.py:374-394).
- **Schließen** (`destroy`): Entwurf sofort schreiben, `flush` mit maximal 1.5 s Wartezeit (editor.js:1010-1019).
- Auffälligkeit: Der Thumbnail-Cache wird mit dem Schlüssel `fileId:pageKey` gelöscht (editor.js:596), angelegt wird er aber als `fileId:chdate:width` (editor.js:1024). Das Löschen wirkt also nicht.

### B26 Aufgabenkontext für die Skriptsuche
- `taskContext()` (editor.js:156-169): nur auf PDF-Seiten.
  - Zeilen nach y gruppieren (Toleranz 4).
  - Überschriften per Regex `^(Aufgabe|Übung|Uebung|Exercise|Problem)/s*(/d+(?:[.,]/d+)?)` finden.
  - Ziel-y: der letzte Strich, wenn er höchstens 120 s alt ist, sonst die Bildmitte.
  - Block von der passenden Überschrift bis zur nächsten.
  - Ergebnis `{page, label, text, key}`.
- `setupScriptHint` (views-doc.js:85-104):
  - Nur bei Übungsdokumenten: `doc_type` uebung/loesung/klausur oder Namens-Regex (views-doc.js:81).
  - 2.5 s nach Strich, Seitenwechsel oder Scrollen.
  - Text ≥ 40 Zeichen → `POST /api/related {file_id, text}` (server.py:1316), Cache pro Key.
  - Zeigt den besten Treffer; „Öffnen" lädt ihn in die geteilte Ansicht (`openSplit(file_id, page)`), Ausblenden gilt pro Aufgabe.

### B27 Einbindung `mountDoc` und geteilte Ansicht (views-doc.js)
- **`viewDoc`** (views-doc.js:12-83):
  - Lädt `GET /api/files/{id}`, sendet `POST /api/files/{id}/opened` und setzt per `PATCH` den Status „gelesen", wenn er „neu" war.
  - `GET /api/settings` liefert `pen_input` und `hand`.
  - Bei Seitenwechsel (Debounce 800 ms): `POST /files/{id}/opened {last_page}`.
  - Notizfläche → `model.note` (Debounce 600 ms, `markDirty`).
  - Favorit: `POST /files/{id}/favorite`. Erledigt: `POST /tasks/{id}/status`.
- **`mountDoc`** (views-doc.js:119-138):
  - PDF-Erkennung über `local_path`, Name oder Mime.
  - Notizbuch: `kind` notebook/whiteboard oder kein Pfad bei Kurs `__user__`. Dann `url:null`, also eine Leerseite `b1` 595×842 (editor.js:185).
  - Editor-Optionen: `fileId`, `name`, `url=/api/files/{id}/content`, `penInput`, `onPage`, `onStatus` (schreibt `.ed-status` und in Pane A zusätzlich `#docStatus`), `onAccessory` (timer → `toggleTimer(true)`).
  - Der Editor kommt vor `load()` in `state.editors`.
  - Danach `restoreState(docTabs.state[id])` oder `goToPage(page-1)` nach 300 ms. `getState` speichert app.js:65 beim Routenwechsel.
  - Fallback `docFallback` bei Fehlern oder wenn nach 2.5 s keine Seite gerendert ist: Browser-Viewer-Iframe, neuer Tab, Neu laden, Diagnose.
  - Andere Dateitypen: Text als `pre`, Bild als `img`, sonst Download.
- **Geteilt** (views-doc.js:41-80):
  - `pickDocument`-Modal: PDFs, gleiches Modul zuerst, max. 60, Suche.
  - Pane B mit `pane:"B"`. Werkzeugzustand von A nach B per `applyToolState` und `onToolState`.
  - Leisten von B per CSS ausgeblendet (style.css:450). Undo/Redo in A wirken auf den zuletzt berührten Editor (`delegate`/`onActive`).
  - Das Skript liegt auf der Seite der freien Hand: `hand-right` → B links. Spalten `${pct}% 10px minmax(0,1fr)` plus ` 300px` mit Notizen; `pct` aus `localStorage["doc-split"]`, Default 35, 20–65, per Trenner ziehbar.
  - Beim Schließen wird B im Hintergrund zerstört (Speichern läuft weiter).

### B28 Render-Performance
- Warteschlange rendert immer nur eine Seite, die zur Bildmitte nächste zuerst, mit 8 s Timeout (editor.js:48-57).
- Rendern wird gedrosselt bei Fling, schnellem Scrollen, Pinch oder Schreiben (bis 1.5 s pro Happen) (editor.js:473-474).
- Aufbau 300 px vor dem Sichtbereich, Abbau außerhalb von 100 % Abstand (editor.js:403-404). Beim schnellen Wischen wird verzögert (editor.js:420-428).
- JPEG-Vorschau 360 px breit, Qualität 0.7, als Seitenhintergrund (editor.js:477-484).
- Pixellimit iOS 4.5 MP, sonst 12 MP; DPR maximal 2 (editor.js:26-30). Ungenutzte Layer mit Pixelratio 0.2 (editor.js:412).

---

## C) Datenmodell (Annotation-Dokument v2)

```jsonc
{
  "version": 2,
  "zoom": 1.2,                 // zuletzt genutzter Zoom
  "note": "",                  // Dokumentnotiz (Notizfläche)
  "bookmarks": [{ "key": "p2", "title": "Seite 2" }],
  "outline":   [{ "key": "b…", "title": "Abschnitt 1" }],
  "deletedPages": [{ "entry": { /* pageOrder-Eintrag */ }, "objects": [ ], "at": 1730000000000, "pos": 3 }],
  "pageOrder": [
    { "key": "p1", "type": "pdf", "index": 1, "rotation": 90 },
    { "key": "b<uid>", "type": "blank", "template": "lined", "w": 595, "h": 842 },
    { "key": "a<uid>", "type": "asset", "assetUrl": "/api/assets/<fileId>/<hex>.pdf", "index": 1, "w": 595, "h": 842 }
  ],
  "pages": { "<key>": { "objects": [ ], "pkdrawing": { } } },
  "…": "unbekannte Felder bleiben erhalten (migrate spreizt m)"
}
```

- **migrate** (editor.js:171-188):
  - Für v2 mit `pageOrder` bleiben `pages` und `pageOrder` unverändert.
  - Sonst (Altformat v1) wird je PDF-Seite i `pages["p"+i]` aus `m.pages[i].strokes` gebaut. Alte Striche haben `{tool, color, pts:[[x,y]]}` normiert 0–1; daraus wird ein Strich mit Breite 14 und Deckkraft .35 (Marker) bzw. 2.2 (Stift).
  - Alte `notes` `{x,y,text}` werden zu Text mit bg `#fff7a8` und Breite 160.
  - Fehlt `pageOrder`, wird `p1…pn` angelegt, ohne PDF `b1` (blank 595×842).
  - Randfall: Ein v2-Dokument ohne `pageOrder`, aber mit `pN`-Seiten, verliert deren Objekte (gelesen werden nur numerische Schlüssel).
- **Seitenschlüssel**:
  - `p{i}`: PDF-Seite.
  - `p{i}c{uid}`: duplizierte PDF-Seite.
  - `b{uid}`: Leerseite, Bild-Seite oder Duplikat.
  - `a{uid}`: importierte Asset-PDF-Seite.
  - `uid` = 8 Zeichen Zufall (Basis 36) + 4 Zeichen Zeit (editor.js:7).
- **pageOrder-Felder**: `key`, `type` (pdf | blank | asset), `index` (pdf und asset, 1-basiert), `rotation` (0/90/180/270), `template` (blank: blank | lined | grid | dotted | mm | cornell), `w`/`h` (blank und asset).
- **Objekte** (gemeinsam: `id`, `type`, `x`, `y`, `rotation`, `scaleX`, `scaleY`, `opacity`; Seitenpunkte ohne Zoom, Ursprung oben links):
  - `stroke`: `tool` (pen | fountain | pencil | marker), `color`, `width` (Mittelwert), optional `widths[]` (je Punkt), `points[x0,y0,…]`; vom iPad zusätzlich `source`.
  - `text`: `text`, `width`, `fontFamily`, `fontSize`, `fill`, `bold`, `italic`, `underline`, `align`, `bg` ("" = kein Hintergrund), `lineHeight`, `opacity`. Haftnotiz = Text mit `bg`.
  - `shape`: `shape` (rect | ellipse | triangle | polygon | line | arrow), `stroke`, `strokeWidth`, `fill` ("" = keine Füllung), `opacity`.
    - rect, ellipse, triangle: `x`, `y`, `width`, `height`.
    - line, arrow: `x:0`, `y:0`, `points:[x0,y0,x1,y1]`, `width=|dx|+|dy|`.
    - polygon: `points`, `width:1`, `height:1` (editor.js:723, 726).
  - `image`: `src` (Asset-URL), `width`, `height`, optional `crop`, `opacity`.
- **IDB-Entwurf**: `{fileId, data, version, dirty, savedAt, dirtyKeys[], struct, meta, basePages{key: JSON|null}}` (editor.js:573, 576, 595).
- **Vergleichsstand** `snap()`: `{pages:{key: JSON}, order: JSON([pageOrder, deletedPages]), meta: JSON([note, bookmarks, outline])}` (editor.js:126).
- **mergeInto** (editor.js:129-140):
  - Geänderte Seiten werden per `mergePage(base, local, server)` zusammengeführt.
  - Bei geänderter Struktur gewinnen lokales `pageOrder` und `deletedPages`.
  - Bei geänderten Metadaten gewinnen lokale `note`, `bookmarks` und `outline`.
- **merge.js** (Regeln wie in `AnnotationMerge.swift`; Testfälle `packages/shared-contracts/fixtures/merge/cases.json`):
  - `stableStringify` vergleicht mit sortierten Schlüsseln (merge.js:10-14).
  - `objectId` = `o.id`, sonst `"~"+JSON` (merge.js:18).
  - `mergeObjects` (merge.js:20-41):
    - Nur auf einer Seite geändert: diese Änderung gilt.
    - Neu auf einer Seite: wird übernommen.
    - Gelöscht und auf der anderen Seite unverändert: gelöscht.
    - Gelöscht, aber auf der anderen Seite geändert: bleibt erhalten (Konflikt).
    - Auf beiden Seiten verschieden geändert: lokal gewinnt (Konflikt).
    - Reihenfolge: zuerst die Serverreihenfolge, dann lokal neue Objekte.
  - `mergePage` (merge.js:44-64):
    - Ganze Seite identisch: Kurzschluss.
    - Sonst Seitenfelder (außer `objects`/`pkdrawing`) nach denselben Regeln, Objekte per `mergeObjects`.
    - `pkdrawing` bleibt nur, wenn es exakt zu den Ergebnisobjekten passt.
- **Server-Antworten**: GET `{data, updated_at, version}`; PUT `{ok, version}`; 409 `{detail, version, data}`; Assets `{url:"/api/assets/{fileId}/{name}", name}` (erlaubt .png .jpg .jpeg .gif .webp .svg .pdf, max. 15 MB; server.py:415-429).
- **localStorage**: `ed-prefs`, `ed-eraser`, `uniflow-doc-tabs`, `doc-split`.

---

## D) Visuelles Design (editor.css, exakte Werte)

**Theme-Variablen** (style.css:3-10):
- Hell: `--accent #4f5bd5`, `--accent-soft #eceefc`, `--accent-text #3a45b4`, `--surface #fff`, `--surface-2 #f1f3f9`, `--line #e5e8f0`, `--line-strong #d3d8e4`, `--text #171a26`, `--text-2 #4b5168`, `--muted #7a8199`, `--bad #d64545`, `--r 12px`, `--r-lg 16px`, `--sh 0 4px 16px rgba(20,24,40,.06)`, `--sh-lg 0 16px 40px rgba(20,24,40,.14)`.
- Dunkel: `--accent #7b86f0`, `--surface #171a23` (style.css:14-18).

**Container `.ed`** (editor.css:2): Flex-Spalte, `min-height 70vh`, Radius `var(--r)`, 1px Rand `--line`. Gesamter Editor `user-select:none`, außer Eingabefeldern und KI-Panel (editor.css:117-119).

**Hauptleiste** (editor.css:4-16, 121, 126):
- Höhe 50px, bei `pointer:coarse` 56px. Padding `.35rem .6rem`, gap `.4rem`, kein Umbruch, horizontal scrollbar ohne sichtbaren Balken.
- Hintergrund `linear-gradient(90deg, var(--accent) 0%, #6a5ce6 60%, #7b61ea 100%)`, Schrift `#fff`, `inset 0 -1px 0 rgba(255,255,255,.12)`. Dunkel: `linear-gradient(90deg, #4b55c9, #5a4fcf)` (editor.css:33).
- Gruppen: `rgba(255,255,255,.12)`, Radius 12px, Padding 3px, gap 2px. Die rechte Gruppe ist transparent (gap .25rem). Die Werkzeuggruppe ist zentriert (`margin 0 auto`).
- Buttons: Radius 9px. Hover `rgba(255,255,255,.18)`, `:active scale(.96)`. Aktiv: Hintergrund `#fff`, Farbe `--accent`, Schatten `0 2px 8px rgba(0,0,0,.18)`.
- Allgemeine Buttons `.ed button`: min. 34×34px, Padding `.3rem .45rem`, `.88rem`, Radius 9px. Bei ≤900px 36px, bei `coarse` 40px (editor.css:21, 112, 133).
- Status-Pill: `.74rem`, `rgba(255,255,255,.14)`, Radius 999px, Breite 170px. Punkt 6px: gespeichert `#7cf2a8`, speichert `#ffd166`, offline `#ff8a8a`. Bei ≤1100px nur noch Punkt (14px Breite, Schriftgröße 0).
- Trenner: 1×22px `rgba(255,255,255,.35)`, in der Kontextleiste `--line`.
- Eingabe-Button: Padding `.3rem .6rem`, Label `.78rem/600`, bei ≤700px nur Icon (editor.css:113-114).

**Kontextleiste** (editor.css:17-32, 122-125):
- Höhe 50px (coarse 56), Hintergrund `--surface`, Schatten `0 2px 6px rgba(20,24,40,.04)`, z-index 2, kein Umbruch, horizontal scrollbar.
- Gruppen: `--surface-2`, Radius 11px, Padding 3px.
- Buttons: Farbe `--text-2`, Hover `--surface`. Aktiv: `--surface`, `--accent-text`, Schatten `0 1px 3px rgba(20,24,40,.12)`.
- Segment-Buttons 28px, `.8rem`. Labels `.78rem`, `--muted`.
- Regler 90px breit, `accent-color --accent`. Farbwahl 28×28, Radius 8. Select und Zahlenfeld 30px hoch, Radius 8, `.82rem`; Zahlenfeld 60px breit.
- Farbfeld-Container: 34px hoch, Radius 11, gap `.4rem`.
- Farbfeld: 22px rund, Rand 2px `#fff`, Ring `0 0 0 1px rgba(0,0,0,.08)`, Hover `scale(1.12)`. Aktiv: `0 0 0 2px var(--surface-2), 0 0 0 4px var(--accent)`, `scale(1.05)`. Coarse 28px.
- Eigene Farbe: 24px, gestrichelt `--line-strong`, `conic-gradient(#e5322d, #f5b400, #22a55b, #2b5df0, #9a2a2a, #e5322d)`.
- Breiten-Buttons 34px (coarse 40) mit Balken 16px breit, Radius 3px, `currentColor`. Radierer-Punkt rund, Deckkraft .5.

**Arbeitsfläche** (editor.css:35-49):
- `.ed-scroll`: Hintergrund `#62656d` (dunkel `#0b0d12`), Padding 12px, `overscroll-behavior:contain`, `overflow-anchor:none`.
- Cursor: Stift crosshair, Radierer cell, Text/Haftnotiz text, Lasso/Formen/Textauswahl/Bild crosshair, Hand oder Leertaste grab.
- Seiten-Container `.ed-pages`: Flex-Spalte, gap 14px. Horizontal: Zeile, `align-items:flex-start`.
- `.ed-page`: weiß, Schatten `0 2px 10px rgba(0,0,0,.35)`. Schichten: `canvas.ed-pdf`, `div.ed-stage` (Konva), `canvas.ed-live`, `canvas.ed-predict` (`pointer-events:none`).
- Seitennummer `.ed-pagelabel`: rechts −2px, unten −18px, `.7rem`, `#ddd`.
- Text-Overlay `.ed-textedit`: z 5, Rand 1px gestrichelt `--accent`, Hintergrund = Objekt-bg oder `rgba(255,255,255,.9)`.

**Schwebende Elemente:**
- **Seiten-Pill** (editor.css:109-111, 129-131, 136): absolut, `left:50%`, `bottom:14px`, `translateX(-50%)`, z 6, Radius 999px, Padding `.2rem .55rem`. Hintergrund `color-mix(in srgb, var(--surface) 90%, transparent)` mit `backdrop-filter: blur(10px)`, Schatten `--sh`, `.82rem`. Seitenfeld 38px, transparent, 600. Buttons 26px (coarse 36). Zoomanzeige min. 44px. Beim Schreiben: Deckkraft .2, `pointer-events:none`.
- **Stift-Cursor `.ed-cursor`** (editor.css:46, editor.js:334): `position:fixed`, Rand 1.5px (Farbe inline: Stiftfarbe bzw. `#888`), rund, `translate(-50%,-50%)`, z 3, Deckkraft .7. Größe: Radierer = `eraserSize` px, Stift = `max(2, width*zoom)` px.
- **Popover `.ed-pop`** (editor.css:72-90): absolut, z 30, Radius 14px, Schatten `--sh-lg`, min. 280px, max. `min(420px, 92%)`, max. Höhe 70vh, Animation `fade .12s` (4px nach oben einblenden).
  - Kopf zentriert, Gewicht 650. Unterkopf `.72rem` in Großbuchstaben, Sperrung `.04em`.
  - Menü-Buttons 38px, Radius 8, `.88rem`, Hover `--surface-2`; danger in `--bad`.
  - Zeilen `.86rem`. „Wo"-Segment 30px.
  - Vorlagenraster 3 Spalten. Vorlagenvorschau 56×72px, Rand `#d9dde8`, CSS-Muster: Liniert alle 8px; Kariert 8px; Millimeter 4px in `#e6e9f0`; Gepunktet 8px Punkte `#c9ced9`; Cornell mit Randlinie bei 14px in `#b9c2d6`; „Aktuelle Vorlage" als Verlauf `accent-soft` → weiß.
- **Lineal** (Konva, editor.js:912): Fläche `rgba(79,91,213,.14)`, Rand `#4f5bd5` (1/zoom), Radius 5. Teilstriche `#4f5bd5`, 6/12 hoch. Winkeltext 11px fett `#4f5bd5`. Knopf r 11, `#4f5bd5`, Deckkraft .9.
- **Zoom-Ansicht** (editor.css:93-96): Rand oben, `--surface-2`. Kopf `.82rem`, Buttons 26px. Körper 180px hoch, weiß. Canvas crosshair. Markierungsrahmen auf der Seite: `#4f5bd5`, 1.5/zoom, Strichel `[6,3]/zoom`, Füllung `rgba(79,91,213,.05)` (editor.js:930).
- **Auswahlgrafik**: Lasso `#4f5bd5`, Strichel `[6,4]/zoom`, Füllung `rgba(79,91,213,.08)`. Rechteck-Auswahl Strichel `[4,3]`, Füllung `.06`. Textauswahl Füllung `rgba(255,200,0,.25)`, Rand `#d98a00`. Transformer `#4f5bd5`, Anker 9, Padding 4 (editor.js:436, 690, 695).

**Seitenleiste** (editor.css:51-70):
- Breite 0, geöffnet 230px, Übergang `width .15s`. Bei ≤900px Overlay mit 210px und `--sh-lg`. Rechts angeordnet: `order:3` mit linkem Rand.
- Kopf: Padding `.4rem .5rem`, Segment-Buttons 28px (min. 40).
- Miniaturen: Raster 2 Spalten, gap `.6rem .4rem`, `.72rem`. Bild mit Rand 2px `--line`, Radius 4, min. 60px; aktiv `--accent`; beim Ziehen darüber `--accent-soft`. Lesezeichen oben 2 / rechts 4 in `--accent`. Menü-Button 22px.
- Gliederungszeilen `.84rem` mit Linie unten. Mini-Buttons 24px, `.75rem`. Aufnahme aktiv in `--bad`.

**KI-Panel** (editor.css:98-107): 320px breit (≤900px Overlay mit `min(320px, 92%)`), Padding `.6rem`, gap `.4rem`, `.88rem`. Felder `.85rem`, Radius 8. Ausgabe mit Zeilenhöhe 1.45; Code-Blöcke in `--surface-2`. Karteikarten in `--surface-2`, Radius 8.

**Dokumentansicht** (style.css):
- `.doc-top` 46px hoch (coarse 52). Tabs 32px (38), max. 210px; aktiver Tab `--accent-soft`/`--accent-text` (style.css:433-452).
- `.doc-panes` als Grid, gap/Padding `.4rem` (style.css:220).
- Split-Trenner: Balken 4×48px `--line-strong`, Hover `--accent` (style.css:492-494).
- Skript-Hinweis: absolut oben 120px, rechts 22px, z 30, max. `min(440px, 80%)`, linker Rand 3px `--accent`, Radius 12, Blur 8px, `.82rem`; beim Schreiben Deckkraft .25 (style.css:495-498).
- Vollbild-Ausgang: fixiert oben 10 / rechts 12, z 40, als Pill (style.css:446).
- Zeitmesser: fixiert rechts/unten 1rem, 260px breit, Radius `--r-lg`, z 45; Pill in `--accent` (style.css:318-321).

---

## Weitere Auffälligkeiten
- „Duplizieren" und „Kopieren" nutzen beide das Icon `copy`, „Ausschneiden" das Icon `eraser` (editor.js:357).
- `.ed:fullscreen` ist in der CSS definiert (editor.css:3), die Fullscreen-API wird aber nicht verwendet.
- Die Taste `h` wählt den Textmarker; das Hand-Werkzeug hat keine eigene Taste, nur die Leertaste.
- Die Funktion „Teilen…" ist deaktiviert und als „vorbereitet" markiert.
- `getState` speichert Scrollpositionen, `restoreState` stellt sie nicht wieder her (editor.js:903-904).

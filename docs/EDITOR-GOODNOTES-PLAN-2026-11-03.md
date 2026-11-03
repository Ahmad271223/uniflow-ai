# Editor wie aus einem Guss – Apples Palette bleibt, unsere Teile arbeiten mit ihr (03.11.2026)

Stand: überarbeitet nach deiner Entscheidung vom 03.11.2026. **Apples Palette (`PKToolPicker`) bleibt.** Unsere eigenen
Teile wandern in die Palette oder richten sich nach ihr. Die Schritte A bis D sind im Code umgesetzt und getestet, aber
noch nicht committet. Ab Schritt E folgt der Plan.

**Nachbesserung nach deinem Gerätetest (iPad A16, iPadOS 27, Pencil), 03.11.2026 abends:**
1. *Der Finger schrieb, Blättern ging nicht.* Ursache: Die Zeichenflächen standen auf der Eingabeart `.default`, damit der
   Schalter der Palette gilt. `.default` folgt der iPadOS-Einstellung „Nur mit Apple Pencil zeichnen“, die auf deinem
   iPad aus ist. Behoben: Standard ist wieder **„Nur Stift“** (`.pencilOnly`: der Finger blättert, zoomt, markiert
   Text), unser Schalter **„Nur Stift / Finger zeichnet“** steht wieder in der Leiste, und der Schalter der Palette ist
   ausgeblendet (`showsDrawingPolicyControls = false`). An unseren Schalter anbinden lässt er sich nicht: Er schreibt nur
   die iPadOS-Einstellung `UIPencilInteraction.prefersPencilOnlyDrawing`, die eine App ausschließlich lesen kann.
2. *Keine Pfeile, Formen, kein Text in der Palette.* Im Simulator (iOS 27.2) tragen Palette und `toolItems` die fünf
   Einträge; der gespeicherte Stand unter „uniflow.toolpicker“ entfernt sie nicht (geprüft). Sie standen aber **am Ende**
   der Palette, hinter Lineal und Apples fünf weiteren Stiften (Bleistift, Wachs, Füller, Kalligrafie, Wasserfarbe). Die
   Palette zeigt nur so viele Werkzeuge, wie in ihre Breite passen (im Simulator hochkant sechs, quer etwa zehn), der
   Rest erst nach waagerechtem Wischen – im Bild der Palette aus dem Simulator (Abschnitt 5a) ist das zu sehen. Behoben:
   Unsere Einträge stehen jetzt **direkt hinter Stift, Fineliner, Textmarker, Radierer und Lasso**, in der Reihenfolge
   Form, Text, Haftnotiz, Auswählen, Text markieren; Lineal und die weiteren Stifte folgen dahinter (nichts fehlt). Quer
   sind damit alle fünf ohne Wischen zu sehen, hochkant die Form, der Rest nach einem kurzen Wischen nach links. Die
   Bilder der Einträge zeichnet der Editor wie Apples Stifte (heller Körper mit Kontur, Symbol oben; im Simulator
   nachgesehen). Zur Sicherheit prüft der Editor
   zur Laufzeit, ob die sichtbare Palette die Einträge wirklich trägt (`EditorPalette.hasCustomItems`); wenn nicht, kommen
   die alte Objektleiste und „Tinte/Objekte“ zurück – niemand bleibt ohne Formen und Text. Dazu die Geräte-Probe
   `EditorDeviceProbeTests.testPaletteOnTheDevice` (nur mit `UF_DEVICE_PROBE=1`, Abschnitt 5a) und das Startargument
   `-UFPaletteProbe 1` in der App; beide schreiben den Stand der Palette ins Protokoll.
3. *Markierter PDF-Text kam nicht mehr in der KI-Hilfe an.* Zwei Ursachen: Mit Punkt 1 erreichte der Finger die PDF gar
   nicht (die Zeichenfläche nahm ihn als Strich). Und die neue Rückholung der Palette nahm der PDF-Ansicht den Fokus,
   sobald die Palette weg war – dabei verschwand die Textauswahl. Behoben: Solange PDF-Text ausgewählt ist oder PDFKit
   dafür den Fokus hält, wartet der Editor (`Blocker.pdfSelection`) und holt die Palette erst zurück, wenn die Auswahl
   aufgehoben ist (`PDFViewSelectionChanged`). Test `testPDFSelectionSurvivesThePaletteAndReachesTheAI` deckt den Weg
   über `EditorBridge.askTutor` („KI erklärt“, „KI löst“) und das Mitschicken beim Senden ab.

Die erste Fassung schlug eine eigene Werkzeugleiste anstelle der Palette vor. Das ist verworfen. Die Mockups von damals
zeigen noch diese eigene Leiste und gelten deshalb nur noch für die Seitenleiste mit „+“ (Mockup 3) und das Zoom-Fenster
(Mockup 2). Sie liegen unter `/private/tmp/claude-501/-Users-ahmadfakih-uniflow-ai/b2e6b52d-8140-52f8-a368-082b8202c588/scratchpad/editor-plan/`.

## Kurzfassung

Bisher arbeiteten drei Bedienflächen nebeneinander:
- **Apples Palette**
- **unsere Navigationsleiste** mit Rückgängig/Wiederholen, „Nur Stift“ und „Tinte/Objekte“
- **unsere Objektleiste unten** mit einem eigenen Werkzeugsatz

Dabei gab es zwei Rückgängig-Knöpfe und zwei Schalter für „Finger zeichnet“. Der Schalter der Palette war sogar
wirkungslos, weil wir die Eingabeart der Zeichenflächen fest gesetzt hatten.

Seit heute ist die Palette der Ort für alle Werkzeuge:

- **A – Unsere Werkzeuge stehen in der Palette (ab iPadOS 18):**
  - Neue Einträge: Objekte auswählen (Antippen oder Lasso), Text, Haftnotiz, Form (Rechteck, Ellipse, Linie, Pfeil) und
    Text markieren.
  - Wer einen dieser Einträge wählt, ist im Objektmodus. Wer einen Stift, Radierer oder Lasso von Apple wählt, verlässt ihn
    wieder. Der Knopf „Tinte/Objekte“ fällt dadurch weg.
  - Unter iPadOS 17 bleibt die bisherige Objektleiste. Die App läuft weiter ab iOS 17.0, die neuen Teile hängen an
    `#available(iOS 18.0, *)`.
- **B – Palette statt Doppelknöpfe:**
  - Rückgängig und Wiederholen kommen aus der Palette, die Knöpfe oben sind am iPad weg (am Mac bleiben sie). Die
    Objektleiste hat eigene Knöpfe für Objektaktionen.
  - „Nur Stift / Finger zeichnet“ bleibt **unser** Schalter in der Leiste (siehe Nachbesserung 1); der Schalter der Palette
    ist ausgeblendet.
  - Beide Wege nutzen **einen** Verlauf für Striche, Objekte und neu eingefügte Seiten. Eingefügte Seiten ließen sich vorher
    gar nicht rückgängig machen.
- **C – Farben kommen aus der Palette:**
  - Text und Formen übernehmen beim Wechsel vom Stift dessen Farbe, solange man im Eintrag keine eigene gewählt hat. Die
    Formstärke stellt man im Eintrag ein.
  - „Text markieren“ nimmt die Farbe des Textmarkers. Ist sie hell, wird Unter- und Durchstreichen wie im Web rot.
- **D – Die Palette bleibt sicherer sichtbar:**
  - Die Schleife mit zehn Wiederholungen ist ersetzt. Der Editor wartet jetzt auf das Ereignis, das die Palette verdeckt
    hielt: Tastatur oder Textfeld fertig, Blatt hat den Bildschirm verlassen, Menüfenster zu, Fenster wieder vorn.
  - Verlässt eine Seite mit Fokus die Anzeige, etwa beim Neuaufbau nach „Seite einfügen“, geht der Fokus an den Anker. Die
    Palette schließt sich dann nicht mehr.

**Dabei gefunden und behoben:** Steht die Palette auf einem eigenen Eintrag, liefert PencilKit ein Werkzeug, das eine
Zeichenfläche nicht kennt. Bekam eine neue Seite dieses Werkzeug, stürzte die App ab („Unknown PKTool type“, im Test
nachgestellt). Neue Seiten bekommen deshalb immer das letzte Werkzeug von Apple (`canvasTool`).

**Noch offen:** Schritt E (Seitenleiste mit „+“) und die Ausbaustufen F bis I mit zusammen etwa 7 bis 12 Tagen.
Abschnitt 4 nennt die Schritte im Einzelnen.

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

## 2. GoodNotes und StudiNow im Vergleich

| Thema | GoodNotes | StudiNow vorher | StudiNow seit 03.11.2026 (Apples Palette bleibt) |
|---|---|---|---|
| Werkzeugwahl | eigene Leiste oben, Lasso fest vorn | Apples Palette für Tinte, dazu Objektleiste unten mit eigenem Werkzeugsatz und Schalter „Tinte/Objekte“ | **eine Palette**: Apples Werkzeuge zuerst, unsere fünf dahinter (ab iPadOS 18); unter iPadOS 17 wie vorher |
| Werkzeugoptionen | Kontextmenü am Werkzeug | Palette für Tinte, Menü mit 6 Farben für Objekte | Popover der Palette auch für unsere Einträge: Farbe (Text, Form), Stärke (Form), Formart bzw. Antippen/Lasso |
| Farben | je Werkzeug | Objekte immer Rot, Markieren immer Gelb | Objekte nehmen die Stiftfarbe (bis man im Eintrag eine eigene wählt), Markieren die Textmarkerfarbe |
| Rückgängig | in der Leiste, Gesten mit zwei/drei Fingern | oben **und** in der Palette (doppelt), eingefügte Seiten nicht rückgängig | Palette (iPad) bzw. Leiste (Mac), dazu in der Objektleiste; ein Verlauf für Striche, Objekte und eingefügte Seiten |
| Finger/Stift | Einstellung Handballenerkennung | eigener Knopf „Nur Stift“, Schalter der Palette ohne Wirkung | unser Knopf „Nur Stift / Finger zeichnet“ (Standard: nur Stift), Schalter der Palette ausgeblendet |
| Palette sichtbar | Leiste immer da | verschwand bei Fokuswechsel, Rückholung mit 10 Versuchen über 10 s | Rückholung auf Ereignisse; Fokus bleibt beim Neuaufbau |
| Pencil-Doppeltippen/Squeeze | eigene Schnellpalette | Systemverhalten der Palette | unverändert System; laut Apple erscheinen eigene Einträge auch in der Squeeze-Palette (am Gerät prüfen) |
| Seitenleiste | Miniaturen, Gliederung | Miniaturen, Lesezeichen | unverändert (Schritt E) |
| Lasso | eins für alles | Apples Lasso (Tinte) und unser Objekt-Lasso getrennt | beide jetzt in derselben Palette; Zusammenlegen ist Schritt G |
| Schloss-Symbole | – | zwei gleiche Schlösser (Schreiben Plus, Geteilt Plus) | nur noch „Schreiben (Plus)“ mit Schloss; „Geteilt (Plus)“ mit dem Teilungssymbol, die Sperre nennt der Text |

## 3. Was im Code geändert ist (03.11.2026, nicht committet)

| Datei | Änderung |
|---|---|
| `apps/apple/UniFlow/Editor/EditorPalette.swift` (neu) | Palette mit Apples Werkzeugen plus unseren fünf Einträgen (`PKToolPickerCustomItem`, `#available(iOS 18.0, *)`), Reihenfolge: Apples Hauptwerkzeuge, unsere Einträge, Apples weitere Stifte. Schalter der Palette fürs Fingerzeichnen aus. Optionen im Popover (`PaletteOptionsController`). Dazu `PaletteSync` (Stift-, Marker- und Objektfarben), `EditorPalette.Blocker` (was die Palette verdeckt halten darf, inkl. PDF-Textauswahl), `WindowExitSentinel` (meldet, wenn ein Blatt weg ist), `hasCustomItems` (Laufzeitprüfung) und `describe` (Protokoll für die Probe). |
| `apps/apple/UniFlow/Editor/PDFEditorController.swift` | Reagiert auf die Auswahl in der Palette (`toolPickerSelectedToolItemDidChange`, unter 17 `toolPickerSelectedToolDidChange`). Objektmodus, Rücksprung zum Stift, wo Objekte nicht gehen (nur ansehen, Korrektur-Modus). Die andere Hälfte der geteilten Ansicht pausiert. Weitere Punkte: `canvasTool` gegen den Absturz, Eingabeart `.pencilOnly`/`.anyInput` nach unserem Schalter (nie `.default`), Rückgängig für eingefügte, duplizierte und angehängte Seiten, Rückholung der Palette auf Ereignisse (auch: Auswahl von PDF-Text aufgehoben), Fokus an den Anker beim Verwerfen von Seiten, `toolsInPalette` zur Laufzeit, Startargument `-UFPaletteProbe 1`. |
| `apps/apple/UniFlow/Editor/ObjectEditing.swift` | „Text markieren“ fragt die Farbe beim Editor ab. Werkzeugwechsel des Editors gehen an die Palette. |
| `apps/apple/UniFlow/Editor/CorrectionMode.swift` | Korrektur-Zeichenfläche bekommt `canvasTool` |
| `apps/apple/UniFlow/Views/DocumentView.swift` | Die Palette kommt aus `EditorPalette.makePicker()`. „Nur Stift / Finger zeichnet“ bleibt oben; Rückgängig/Wiederholen oben nur am Mac; „Tinte/Objekte“ nur, wenn die Palette unsere Einträge nicht trägt (`bridge.toolsInPalette`). Die Objektleiste zeigt mit Einträgen in der Palette nur Auswahl- und Markieraktionen, dazu Rückgängig/Wiederholen und „Fertig“ beim Markieren. Das zweite Schloss ist weg. |
| `apps/apple/UniFlowTests/EditorPaletteTests.swift` (neu) | 18 Tests zu den Schritten A bis D und zur Nachbesserung (Abschnitt 6) |
| `apps/apple/UniFlowTests/EditorDeviceProbeTests.swift` (neu) | Geräte-Probe der Palette, nur mit `UF_DEVICE_PROBE=1` |

**Speicher (Hinweis aus der Robustheitsprüfung, kleinere höchste Render-Auflösung bei ≤ 4 GB):** nicht umgesetzt. In
`docs/EDITOR-MESSUNG.md` (3.5) kostet Zoomen nur wenig zusätzlichen Speicher: 6-fach +0 bis +32 MB. Die Spitzen von 410
bis 590 MB entstehen beim schnellen Blättern über volle Seiten und in Speicherrunden mit vielen Strichen. In beiden Fällen
laufen die Seiten mit Bildschirmauflösung, nicht mit der höchsten Stufe. Eine kleinere Obergrenze würde Schärfe beim
Hineinzoomen kosten und die gemessene Spitze nicht senken. Wenn, dann setzen wir bei der Zahl geparkter Seiten
(`parkedLimit`, `parkedAreaLimit`) an, nach einer Messung am Gerät mit 4 GB.

## 4. Nächste Schritte (jeder für sich auslieferbar)

| # | Schritt | Inhalt | Aufwand | Risiko |
|---|---|---|---|---|
| A–D | erledigt | siehe oben | – | am Gerät prüfen (Abschnitt 5) |
| E | Seitenleiste mit „+“ | „+“-Kachel nach der letzten Miniatur (leere Seite wie die letzte, langes Drücken: Vorlagen). Kontextmenü je Miniatur: davor/danach einfügen, drehen, Papierkorb, Lesezeichen, zur Gliederung. Einfügen ist jetzt schon rückgängig machbar. | 1–2 Tage | gering |
| F | Palette-Zusatzknopf | `PKToolPicker.accessoryItem` (iPadOS 18) für einen häufigen Weg, z. B. „KI fragen“ oder „Seiten“, damit der Weg nicht zur Leiste oben führt | 0,5 Tage | gering |
| G | Ein Lasso für Tinte und Objekte | Unser Eintrag „Objekte auswählen → Lasso“ wählt zusätzlich Striche (Punkte von `PKStroke.path` im Polygon) und verschiebt beides als **einen** Rückgängig-Schritt. Apples Lasso bleibt für Ausschneiden, Kopieren und Farbe der Striche. | 2–3 Tage | mittel: Striche verlustfrei kopieren (`pkInk`, Druck, Breiten; Tests wie `AuditRunde11PencilTests`) |
| H | Formerkennung | Zuerst am Gerät prüfen, ob PencilKit „zeichnen und halten“ in unseren Zeichenflächen schon kann (Notizen-App kann es). Sonst eine eigene Erkennung nach dem Strich, die den Strich durch eine ideale Form als Strich ersetzt, damit das Web-Format gleich bleibt. | 1–2 Tage | gering |
| I | Zoom-Fenster | Schreibstreifen unten (zweite Zeichenfläche), Rahmen auf der Seite, Striche mit der Rahmen-Umrechnung in die Seite, ein Rückgängig-Schritt je Strich. Als eigener Eintrag in der Palette. | 3–4 Tage | mittel |

Summe E bis I: etwa 7 bis 12 Tage. Empfohlene Reihenfolge: E, F, G, dann H oder I nach deiner Wahl.

## 5a. Geräte-Probe der Palette (für den Koordinator)

Test: `EditorDeviceProbeTests.testPaletteOnTheDevice`. Läuft nur mit der Umgebungsvariable `UF_DEVICE_PROBE=1` (Xcode:
Schema → Test → Arguments → Environment; xcodebuild: `TEST_RUNNER_UF_DEVICE_PROBE=1`), sonst übersprungen. Er öffnet ein
eigenes kleines Dokument (nichts aus deinen Containern), zeigt die Palette und schreibt jede Zeile mit „[Probe]“ ins
Protokoll: `toolItems` mit Kennungen, gewähltes Werkzeug, `hasCustomItems`, `isVisible`, `showsDrawingPolicyControls`,
die iPadOS-Einstellung „Nur mit Apple Pencil zeichnen“, Eingabeart und Werkzeug der Zeichenflächen, die Fenster der
Szene. Dazu hängt er ein Bild der Palette an den Testbericht (Xcode: Bericht → Anhänge). In der App dasselbe über das
Startargument `-UFPaletteProbe 1` (Schema → Run → Arguments): eine Sekunde nach dem Öffnen eines Dokuments steht der
Stand in der Konsole.

## 5. Am echten iPad prüfen (Pencil, kein Simulator)

1. **Palette (iPadOS 18 und neuer):**
   - Quer: hinter Stift, Fineliner, Textmarker, Radierer und Lasso stehen Form, Text, Haftnotiz, Auswählen und Text
     markieren; dahinter Lineal und die weiteren Stifte (nach Wischen). Hochkant: Form sichtbar, der Rest nach einem
     Wischen nach links.
   - Ein zweites Tippen auf „Form“ bzw. „Objekte auswählen“ öffnet das Popover mit der Art. Farbe und Stärke lassen sich
     dort ändern.
   - Text, Haftnotiz und Form legen Objekte an, der Stift schreibt währenddessen nicht.
   - Stift wählen: Der Pencil schreibt wieder.
2. **„Nur Stift / Finger zeichnet“ in der Leiste:** Standard „Nur Stift“: der Pencil schreibt, ein Finger blättert und
   zoomt, langes Drücken wählt PDF-Text. „Finger zeichnet“: ein Finger schreibt, zwei Finger blättern. Die Palette zeigt
   keinen eigenen Schalter mehr.
3. **Rückgängig der Palette:**
   - nach Strich, nach Text/Form, nach „Leere Seite einfügen“ (die Seite geht in den Papierkorb, Wiederholen holt sie
     zurück)
   - im Korrektur-Modus: nimmt nur die Korrektur zurück
   - nach einer Auswahl mit Apples Lasso: tut die Palette dann noch etwas?
4. **Palette kommt zurück:**
   - nach KI-Hilfe-Eingabe (Tastatur zu)
   - nach Suche, Gliederung, Marker-Blatt, „Teilen“-Menü, „Mehr“-Menü und App-Wechsel
   - nach „Seite einfügen“ über Mehr und über das Menü der Miniatur
   - Dabei darf sich kein offenes Menü von selbst schließen.
5. **Text markieren:** Text auswählen, „Markieren“ in Textmarkerfarbe, „Fertig“ bringt Stift und Palette zurück.
6. **Doppeltippen (Pencil 2/Pro):** wirkt wie eingestellt, auch wenn gerade ein eigener Eintrag gewählt ist.
7. **Squeeze (Pencil Pro):** Erscheinen unsere Einträge in der kleinen Palette an der Spitze?
8. **Geteilte Ansicht:** Mit „Text“ in der Palette schreibt die andere Hälfte nicht. Mit Stift wieder in beiden.
9. **iPadOS 17 (falls ein Gerät da ist):**
   - Objektleiste unten mit Werkzeugen.
   - „Tinte/Objekte“ oben.
   - Objekte in der Stiftfarbe.
10. **Mac („Designed for iPad“):** Rückgängig/Wiederholen und „Nur Stift“ stehen oben, die Maus schreibt.

`docs/EDITOR-ABNAHME.md` Abschnitte 1.5/1.6 („Nur Stift“), 8.1/8.3 (Rückgängig oben) und 21 (Objektwerkzeuge über
„Tinte/Objekte“) beschreiben noch die alte Bedienung. Ich passe sie an, sobald du die Bedienung am Gerät freigibst.

## 6. Tests

`EditorPaletteTests` mit 18 Tests:
- Palette enthält Apples Werkzeuge vollständig, unsere fünf direkt hinter Stift, Fineliner, Textmarker, Radierer und Lasso (Form an Platz 6, Text an Platz 7); der Speichername entfernt sie nicht.
- Bilder sind mindestens 150 pt hoch und haben VoiceOver-Namen.
- Zuordnung von Eintrag zu Werkzeug.
- Objektmodus über die Palette an und aus.
- Rücksprung zum Stift bei „nur ansehen“ und beim Öffnen.
- Geteilte Ansicht pausiert, kein Absturz auf neuen Seiten.
- Farben und Stärke aus der Palette, eigene Farbe bleibt.
- Objektmodus von außen nimmt Stiftfarbe und -stärke.
- Markierfarbe.
- Standard „Nur Stift“ (`.pencilOnly`), nie `.default`; Schalter der Palette aus.
- PDF-Textauswahl bleibt stehen, während die Palette weg ist; `askTutor` liefert den markierten Text (auch im Werkzeug „Text markieren“); nach dem Aufheben kommt die Palette zurück.
- Hält PDFKit den Fokus ohne Auswahl (langes Drücken im Gang, Rest nach dem Neuaufbau), wartet der Editor zweimal kurz und holt den Fokus dann zurück.
- Seite einfügen → Rückgängig/Wiederholen im gemeinsamen Verlauf.
- Reihenfolge der Hindernisse.
- Nur echte Eingabefelder warten auf die Tastatur: PDFKit-Textauswahl und nicht bearbeitbarer Text nicht, sonst käme die Palette nach Antippen der PDF nie zurück.
- Blatt-Markierung meldet sich genau einmal.
- Palette kommt nach einem Blatt zurück.
- Fokus bleibt beim Seiten-Neuaufbau.

Dazu laufen die bestehenden Editor-Tests (Ergebnisse im Bericht der Sitzung).

# Editor verbessern – 10.11.2026

Auftrag des Inhabers nach der Analyse vom 10.11. („okay dann alles verbessern“). Zweig `editor/verbessern` (von
`develop` fe88f9c1), Arbeitsordner `~/Studora-Builds/wt-editor`. Nichts hochgeladen, App Store Connect nicht angefasst.

## Was neu ist

| # | Verbesserung | Wie | Dateien |
|---|---|---|---|
| 1 | **Schnelles Blättern**: Handschrift voller Seiten erscheint sofort | Seiten, die schon wieder aus dem Bild sind, laden nicht zu Ende; sie laden beim Wiederanzeigen. Gemessen (Simulator, 50 Seiten × 300 Striche): bis sichtbar Median **27 ms** (vorher 230–290 ms), längstes **129 ms** (vorher bis 2,8 s), keine Seite mehr „vorbeigescrollt, bevor geladen“ | `Editor/PDFEditorController.swift` (`loadContent`, `wantsContent`) |
| 2 | **Suche in eigenen Notizen**: Textfelder und Haftnotizen, Handschrift, eingescannte Seiten | Textfelder sofort; Handschrift und Scans liest Apples Texterkennung (Vision) im Hintergrund, sichtbare Seite zuerst, Fortschritt im Suchfenster. Gelesenes bleibt, solange das Dokument offen ist; nur geänderte Seiten werden neu gelesen. Treffer nach Art gruppiert | `Editor/NoteSearch.swift` (neu), `Services/DocumentStore.swift`, `Views/DocumentView.swift` (`SearchSheet`) |
| 3 | **Menüleiste** (Mac, iPad mit Tastatur ab iPadOS 26, Übersicht beim Halten von Cmd) | Menü „Dokument“ (Suchen ⌘F, Gehe zu Seite ⌥⌘G, erste/letzte Seite, Seitenbreite, Bild einfügen, Schreiblupe ⌥⌘Y), „Werkzeuge“ (⌘1 Stift … ⌘8 Auswählen), „Ablage“: Als PDF sichern ⇧⌘S, Teilen, Drucken ⌘P | `Editor/EditorCommands.swift` (neu), `UniFlowApp.swift` |
| 4 | **Tasten im Dokument** | Entf/Rückschritt löscht die Auswahl, Esc beendet den Objektmodus, ⌘C/⌘X/⌘V/⌘D (Bearbeiten-Menü) auf der Auswahl; ruhen beim Tippen und wenn fixiert | `Editor/EditorPointerInput.swift`, `Editor/EditorMouseSupport.swift` |
| 5 | **Rechtsklick** (Mac) | Auf leerer Stelle: Text hier, Haftnotiz hier, Einfügen, Bild einfügen, leere Seite danach, Seite drehen, Bereich/Seite an KI. Auf Objekt oder Strich: Ausschneiden, Kopieren, Duplizieren, Löschen, Größer, Kleiner, nach vorne/hinten | `Editor/EditorMouseSupport.swift` (neu) |
| 6 | **Sichern und Drucken** | „Teilen“ → „Als PDF sichern …“ (iPad: Dateien, Mac: Fenster „Sichern“) und „Drucken …“ (Druckdialog des Systems); vorher wie bisher der Hinweis „nur privat“ | `Views/DocumentView.swift`, `Editor/EditorCommands.swift`, `Views/SolutionViews.swift` |
| 7 | **Bilder einfügen** | Aus Fotos, aus Dateien/Finder, per Ziehen aus Finder/Fotos/anderen Apps auf eine Stelle der Seite, per Einfügen aus der Zwischenablage. Hochladen wie im Web-Editor (`POST /api/files/{id}/assets`), höchstens halbe Seitenbreite | `Editor/ObjectClipboard.swift` (neu), `Editor/EditorMouseSupport.swift`, `Services/DocumentStore.swift` (`uploadNoteImage`) |
| 8 | **Kopieren, Einfügen, Duplizieren** | Objekte und Handschrift; Text aus anderen Apps wird zum Textfeld; Textfelder gehen auch als einfacher Text in die Zwischenablage | `Editor/ObjectClipboard.swift` |
| 9 | **Ein Lasso für Handschrift und Objekte** | Das Lasso unter „Auswählen“ greift jetzt auch Striche (mind. 60 % im Lasso). Verschieben (mit Vorschau), Größe (Pinch bzw. Menü), Löschen, Kopieren gemeinsam | `Editor/ObjectEditing.swift`, `Editor/ObjectClipboard.swift`, `Editor/PDFEditorController.swift` (`replaceInk`) |
| 10 | **Schreiblupe** (Zoom-Fenster) | Unten ein breiter Streifen zeigt einen blauen Rahmen der Seite dreifach vergrößert. Geschriebenes landet verkleinert im Rahmen (ein Rückgängig-Schritt je Strich). Am rechten Rand rückt der Rahmen weiter, am Zeilenende in die nächste Zeile; Pfeile zum Verschieben. Nur Stift und Textmarker; Radieren auf der Seite | `Editor/WritingMagnifier.swift` (neu); „Mehr“ → „Schreiblupe“, Menü „Dokument“ |
| 11 | **Mauszeiger je Werkzeug** | Textcursor bei Text/Haftnotiz, Fadenkreuz bei Formen, Lasso, Bereich; Kreis beim Radierer mit „Maus schreibt“ | `Editor/EditorMouseSupport.swift` |
| 12 | **Mac: Werkzeug wählen schaltet „Maus schreibt“ ein** | Wer am Mac per Menü/⌘-Ziffer einen Stift wählt, schreibt danach mit der Maus (vorher blätterte sie weiter) | `Views/DocumentView.swift` (`EditorBridge.choose`) |
| 14 | **In neuem Fenster öffnen** (11.11.) | „Mehr“ → „In neuem Fenster öffnen“ (⌥⌘N) und in der Spalte „Daneben“ das Fenster-Symbol: Übung bzw. Lösung/Skript öffnet als eigenes Fenster mit der ganzen App (Mac: frei verschieben, auch auf einen zweiten Bildschirm; iPad: Stage Manager/Split View). Das Dokument schließt dabei im alten Fenster, damit es im neuen beschreibbar bleibt | `Editor/DocumentWindows.swift` (neu), `UniFlowApp.swift`, `Views/DocumentView.swift`, `project.yml` (`NSUserActivityTypes`) |
| 15 | **Präsentieren** (11.11.) | „Mehr“ → „Präsentieren“ (⌥⌘P): ohne Leisten, Palette und Seitenspalten, jede Seite ganz im Bild; Pfeile, Leertaste, Bild auf/ab und Präsentations-Klicker blättern seitenweise; unten klein Seitenzahl, ◀ ▶ und „Beenden“ (Esc). Neue Fenstergröße (Vollbild, Beamer) passt die Seite neu ein | `Editor/EditorPresentation.swift` (neu), `Editor/PDFEditorController.swift`, `Views/DocumentView.swift` |
| 13 | **Texte am Mac** | 82 Texte sagten am Mac „auf diesem iPad“; dort jetzt „auf diesem Mac“ usw. Am iPad unverändert | `Design/UFDevice.swift` (neu), 25 Ansichten |

**Dabei gefunden und behoben:** Absturz beim Neuzeichnen der Objekte einer Seite (`PageObjectsView.show`): Es
wurden erst alle Ebenen entfernt, auch die der Text-Ansichten, danach die Ansichten selbst; das Entfernen lief über
das Fokus-System in eine Ansicht ohne Ebene (EXC_BAD_ACCESS). Aufgetreten im Test beim Verschieben eines Textfelds
zusammen mit Handschrift. Jetzt erst Ansichten, dann Ebenen (`Editor/PageObjects.swift`).

## Nicht umgesetzt (mit Grund)

| Punkt | Grund |
|---|---|
| Dichte Dokumente schneller öffnen / Speicherrunde nur geänderte Seiten (M1, M3) | Braucht eine Änderung am Speicherformat zusammen mit Web-Editor und Python-Server (Ablage je Seite). Eigener Auftrag, nicht nebenbei. |
| Eigene Ebenen (z. B. „Lösungsweg“ ausblendbar) | Neues Feld im gemeinsamen Notizformat; Web-Editor und Lösungen-Teilen müssten es kennen. Erst entscheiden, dann gemeinsam umsetzen. |
| Seite einfügen/drehen ohne Neuaufbau des Anzeige-PDFs (M10) | Gemessen 0,1–0,6 s bei 500 Seiten; der Umbau (Seiten im laufenden Dokument tauschen, Overlays je Index) trifft den heikelsten Teil des Editors. Nutzen klein, Risiko groß. |
| Dokument mit der Kamera scannen | Bräuchte die Kamera-Berechtigung (neuer Text im Datenschutz und für die Prüfung). Fotos und Dateien gehen schon. |
| Bilder auf anderen Geräten | Eingefügte Bilder liegen wie im Web beim jeweiligen Speicher; auf einem zweiten Gerät zeigt der Editor sie erst, wenn der Speicher sie hat (wie bisher bei Bildern aus dem Web). |

## Tests

Neu: `UniFlowTests/EditorVerbesserungTests.swift`, 20 Tests (Blättern, Suche mit echter Texterkennung eines
Scans, Werkzeuge, Tasten, Zwischenablage, Lasso, Bild hochladen, Kontextmenü, Mauszeiger, Sichern/Drucken,
Schreiblupe, Mac-Texte).

| Lauf | Ergebnis | Protokoll |
|---|---|---|
| iPad-Simulator, alle App-Tests (Klon „iPad Editor Verb“ von 4495AA80) | 1.442 Tests, 18 übersprungen (wie bisher), 1 Testfall rot: `KIAbnahmeLUHAppTests.test3ProAIUeberDenDienst` („Aufgabe lösen“ nicht gefunden) | `~/Studora-Builds/verb-full.log` |
| **iPad-Simulator, alle App-Tests, Endstand 11.11.** (mit Fenster und Präsentation) | **1.445 Tests, 18 übersprungen (wie bisher), 0 Fehler** | `~/Studora-Builds/verb-full2.log` |
| Mac: 9 Klassen mit angepassten Gerätetexten (Lehrende, Dateien laden, Abnahme, OpenAI-Schlüssel, Uni-Anmeldung, Aufnahmen, Probe) | 81 Tests, 1 übersprungen; nur `AbnahmeV1AppTests.testLegacyItem…` rot (Schlüsselbund −25308, Umgebung) | `~/Studora-Builds/verb-mac3.log` |
| Mac: Editor, Mac-Bedienung, Lehrende, Bedienungshilfen, Messung, Karteikarten, Community | 129 Tests, 4 übersprungen, 0 Fehler nach Anpassung der Gerätetexte | `~/Studora-Builds/verb-mac2.log` |
| derselbe Testfall einzeln | `KIAbnahmeLUHAppTests` 4 von 4 grün → schwankt nur im langen Lauf, berührt den Editor nicht | `~/Studora-Builds/verb-ki.log` |
| Mac („Designed for iPad“): EditorVerbesserung, MacBedienung, EditorPalette, EditorFreeze, EditorStep6, EditorStepEFHK | 79 Tests, 2 übersprungen (Mac-Ausnahmen wie bisher), 0 Fehler | `~/Studora-Builds/verb-mac.log` |
| Messung schnelles Blättern (`EditorScaleTests`) | grün, Werte oben | `~/Studora-Builds/verb-1.log` |

## Mac-Prüfliste (11.11.2026, von Hand mit Maus und Tastatur in der Testversion)

Debug-Build als „Designed for iPad“ auf diesem Mac gestartet (Demo-Inhalte), mit echter Maus und echten Tasten bedient.

| Punkt | Ergebnis |
|---|---|
| Menüleiste „Ablage“ (Neues Fenster, Als PDF sichern, Teilen, Drucken), „Dokument“, „Werkzeuge“ | da und wirksam |
| Stift/Textmarker per Menü, Farbe und Strichstärke (neu am Mac, Apples Palette erscheint dort nicht) | Rot/dick und gelber Textmarker auf der Seite |
| Zeichnen mit der Maus, Rückgängig (Menü und ⌘Z), Entf, ⌘W | geht |
| Rechtsklick auf leere Stelle („Text hier“ usw.) und auf ein Textfeld (Ausschneiden … Nach hinten), Duplizieren | geht (vorher kam das Menü von PencilKit bzw. der PDF – behoben) |
| Suche | Treffer, Sprung zur Seite |
| Präsentation ⌥⌘P, Pfeil, Leertaste, Esc | geht (Esc kam vorher nicht an, Reiterleiste blieb sichtbar, danach leere Ansicht – behoben) |
| Schreiblupe | geht mit echter Maus (vorher: Rahmen zu groß – behoben) |
| In neuem Fenster öffnen (Menü und Symbol in „Daneben“) | zweites Fenster mit dem Dokument, beschreibbar |
| Drucken | Mac-Druckdialog mit Vorschau samt Handschrift (abgebrochen) |
| Als PDF sichern | Mac-Fenster „Sichern unter“ (abgebrochen) |
| Fenster beim Neustart | werden wiederhergestellt; einmal kam dasselbe Dokument in zwei Fenstern, das zweite dann „nur ansehen“ (gewollter Schutz) |
| Ziehen aus dem Finder | nur per Test geprüft (Finder-Zugriff nicht angefragt) |
| Kauf/Wiederherstellen (Sandbox), Mit Apple anmelden | **ungeprüft** – Konten des Inhabers nötig |

## Vorgabe ab 11.11.2026: iPad nicht anfassen

Entscheidung des Inhabers: Am iPad ändert sich nichts mehr, nur Mac (und iPhone) kommen dazu. Die Demo bleibt, wie sie
ist (Link auf der Uni-Anmeldeseite; ein Versuch „Demo nur über fünfmal Logo“ wurde verworfen). Die Korrekturen aus der
Mac-Handprüfung wirken nur am Mac (`PDFEditorController.isMac`): Rechtsklick-Menü, Farbe/Strichstärke, Esc beendet die
Präsentation, Reiterleiste in der Präsentation aus, Seite oben nach der Präsentation, Rahmen der Schreiblupe gegenüber
der Anzeige, Übertragen der Schreiblupe ohne „Werkzeug fertig“. Am iPad verhalten sich diese Stellen wie im Commit
`baddff02`.

## Mac ohne Demo wie ein neuer Nutzer (11.11.2026)

Debug-Build, Konto zurückgesetzt, keine Demo. Durchgeklickt: Begrüßung (Mac-Texte), „Mit Apple anmelden“ (Apples
Fenster erscheint, abgebrochen), Tarifwahl, Hochschulwahl (LUH), Anmeldeseiten Stud.IP (LUH WebSSO), QIS und Uni-Mail
(SOGo) laden in der App, Übersicht ohne Demo („Stud.IP verbinden“, echte Mensa), Einstellungen mit Karte „Uni-Zugang“
(Felder, „Speichern“, „überall gleich“, „Schlüsselbund dieses Macs“), „Sync“ ohne Zugang meldet „Zuerst den Uni-Zugang
… speichern“.

Repariert, nur am Mac: Texte mit „Apple Pencil“ bzw. „iOS … Schlüssel-Symbol“ (jetzt Maus/Trackpad bzw. Passwörter-App
des Mac, `UFDevice.adapt`); „Plus holen“ öffnete den Reiter „plan“ = Lernzeit statt der Tarife – am Mac jetzt die
Tarifwahl. Auf Wunsch des Inhabers (11.11.2026, einzige Ausnahme von „iPad nicht anfassen“) gilt die Korrektur von
„Plus holen“ auch am iPad (`UFSidebar.upgradeTarget`, Test `testUpgradeButtonOpensThePlansOnIPadAndMac`, am alten Stand
rot).

Schlüsselbund am Mac: `AbnahmeV1AppTests` (Schlüsselbund) am Mac grün; der frühere Fehler −25308 kam vom gesperrten Mac.

Inhaber prüft mit eigenem Konto (TestFlight am Mac): Anmeldung Stud.IP/QIS/Uni-Mail mit LUH-ID (Tippen in die Felder),
Uni-Zugang speichern und „Sync“ (Dateien, Noten, Mails), Mit Apple anmelden, Kauf und „Käufe wiederherstellen“ in der
Sandbox (im Debug-Test fehlte Pro AI auf der Tarifseite: „konnte nicht geladen werden“).

## Von Hand prüfen (am iPad mit Pencil und am Mac)

1. iPad: großes Skript schnell durchblättern – Handschrift erscheint ohne Verzögerung.
2. Suchen: ein Wort aus der eigenen Handschrift, aus einem Textfeld, aus einem eingescannten Blatt.
3. Auswählen → Lasso um Handschrift und ein Textfeld, verschieben, Pinch, Papierkorb; Rückgängig.
4. „Mehr“ → „Bild aus Fotos …“; Bild aus Fotos in der Split View auf die Seite ziehen.
5. „Mehr“ → „Schreiblupe“: in eine enge Lücke eines Übungsblatts schreiben; Rahmen rückt weiter.
6. Mac: Menüleiste „Dokument“/„Werkzeuge“, ⌘1–⌘8, Rechtsklick auf Seite und Objekt, Bild aus dem Finder ziehen,
   ⇧⌘S Sichern, ⌘P Drucken, Mauszeiger bei Text/Formen.
7. „Daneben öffnen“ → Fenster-Symbol: Lösung als eigenes Fenster; zweites Fenster neben das erste bzw. auf den
   zweiten Bildschirm ziehen; beide beschreibbar.
8. „Präsentieren“: Fenster auf Beamer, ⌃⌘F Vollbild, mit Pfeilen/Klicker blättern, Esc.

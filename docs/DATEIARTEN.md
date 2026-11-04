# Dateiarten jenseits der PDF (Stand 04.11.2026)

Word (.docx), PowerPoint (.pptx), Audio (.mp3/.m4a) und Video-Links sind in StudiNow vollwertige Inhalte: ihr Text
steht Suche, Skriptsuche, KI-Hilfe und Wochentests genauso zur Verfügung wie die Seiten einer PDF. Dieses Dokument
sagt ehrlich, was geht und was nicht. Fixture und Tests: `packages/shared-contracts/fixtures/office-text/`
(`tools/gen-office-fixture.py`), geprüft von `tests/test_office_text.py` (Python), `OfficeTextTests` (Kern),
`tests/js/filekinds.test.mjs` (Web) und `TextDocumentAppTests` (App).

## Was geht

| Art | Text | Anzeige iPad | Anzeige Web | Suche, KI-Hilfe, Wochentests |
|---|---|---|---|---|
| PDF | Textebene, bei Bedarf Texterkennung (Vision bzw. Tesseract) | Editor mit Notizen | Editor | ja (wie bisher) |
| Word .docx | Absätze aus `word/document.xml`, auch Tabellenzellen und Textkästen, Tabulator und Zeilenumbruch im Absatz | Textansicht (Seiten blätterbar) mit KI-Hilfe daneben; Original als Vorschau | Word-Ansicht (`app/docx_view.py`, nur ansehen) | ja |
| PowerPoint .pptx | je Folie eine Seite in der Reihenfolge der Präsentation; Notizen der Folie als Anhang „Notizen:“; Platzhalter für Foliennummer, Datum, Kopf- und Fußzeile ausgelassen | Textansicht („Folie n von m“) mit KI-Hilfe; Original als Vorschau | Textansicht mit „Folie n“ je Abschnitt, Original zum Herunterladen | ja |
| Audio .mp3/.m4a | Transkript **nur auf dem iPad**, nur auf Wunsch („Transkript erstellen“, Deutsch oder Englisch), Spracherkennung auf dem Gerät (`SFSpeechRecognizer`, `requiresOnDeviceRecognition`) | Textansicht des Transkripts mit KI-Hilfe; ohne Transkript die Erklärung und der Knopf | Hinweis und Download, kein Transkript | ja, sobald das Transkript besteht (Suche, KI-Hilfe, Wochentest-Kontext); als Quelle der Skriptsuche je Modul nicht (wie am PC) |
| Video-Links (YouTube, Opencast, TIB AV-Portal, Videodateien in Stud.IP, Courseware) | kein Text | „Videos & Links“ im Modulordner der Bibliothek: Titel, Herkunft, Dauer; Abspielen im vorhandenen Aufzeichnungs-Player, Links im Browser; kein Download von selbst | Bereich Aufzeichnungen wie bisher | nein |

Seitenbildung Word (gleich in Python `app/extract.py` und Kern `OfficeText`): leere Absätze fallen weg; eine neue
Seite beginnt vor einer Überschrift (Formatvorlage `Heading…`/`Überschrift…`/`Title`, oder `outlineLvl`), wenn die
Seite schon 3000 Zeichen hat; vor jedem Absatz, wenn sie 6000 Zeichen hat; vor einem echten Seitenumbruch immer. Ein
Transkript wird nach denselben Regeln in Seiten geteilt (eine Zeile je Satz).

Antworten: `GET /api/files/{id}/pagetext` und die Seitentreffer von `GET /api/search` tragen zusätzlich
`kind` (`pdf | docx | pptx | audio`, sonst `null`); die Form ist sonst unverändert. `files.kind` in der Bibliothek bleibt
`pdf | image | file | notebook | whiteboard`; Symbol und Beschriftung einer `file` kommen aus dem Namen
(`filekinds.js`, `LibraryStyle.displayKind`).

## Was nicht geht

- Altes Word/PowerPoint (.doc, .ppt), Excel, OpenDocument, Keynote/Pages: keine Textextraktion (Vorschau auf dem iPad mit
  QuickLook, im Web nur Download).
- Bilder in Word/PowerPoint werden nicht erkannt (keine OCR auf eingebettete Bilder); eine Folie nur aus Bildern bleibt eine
  leere Seite.
- Formeln (OMML), SmartArt, Diagramme: nur der enthaltene Text, nicht die Struktur.
- Notizen und Markierungen wie im PDF-Editor gibt es in der Textansicht nicht (nur Lesen, Blättern, Text markieren und
  kopieren).
- Audio: kein Transkript am PC oder im Dienst; auf dem iPad nur, wenn das Sprachpaket für die Erkennung auf dem Gerät
  installiert ist (Einstellungen › Allgemein › Tastatur › Diktier-Sprachen). Qualität hängt von Aufnahme und Sprache ab, es
  gibt keine Sprecherzuordnung und keine Zeitmarken. Ein zweiter Lauf (andere Sprache) ersetzt das Transkript.
- Video: kein Transkript, keine Untertitel, keine Erkennung neuer Plattformen; verlinkt wird nur, was `RecordingLibrary`
  schon kennt.
- ZIP64, verschlüsselte oder makrohaltige Office-Pakete werden nicht gelesen (Fehler „nicht lesbar“, keine Seiten).

## Datenschutz

- An die KI des Nutzers (eigenes ChatGPT, `docs/KI-CHATGPT-PLAN.md`) geht nur Text: der Seitentext bzw. die Markierung,
  die Frage, Kurs- und Dateiname. **Nie die Datei selbst**, kein Word-Paket, keine Folien, keine Audio-Datei.
- Das Transkript entsteht auf dem Gerät (Apple-Spracherkennung ohne Internet, `NSSpeechRecognitionUsageDescription` in
  `Info.plist`) und liegt als `<Datei>.transkript.txt` neben der Aufnahme im App-Container (ohne iCloud-Backup wie die
  Stud.IP-Dateien). Es wird nie automatisch erstellt.
- Videos gehören den Lehrenden: nur privat ansehen, kein Teilen; Links öffnen im Browser des Nutzers.

## Technik

- Python: `app/extract.py` (`docx_pages`, `pptx_pages`, `pages_from_paragraphs`, `text_kind`, `is_text_source`), nur
  `zipfile` und `xml.etree`; `app/scriptsearch.py` liest Word/PowerPoint wie PDF (`_extract_pages`, `_sources`,
  `find_pages` mit `kind`), `app/filestream.py` indiziert sie beim Durchreichen, `app/weekly.py` nimmt sie als Quellen.
- Kern: `LocalBackend/Search/ZipReader.swift` (Zentralverzeichnis, stored und DEFLATE über `SolutionDeflate`),
  `OfficeText.swift` (XMLParser, gleiche Regeln), `ScriptSearch.readPages`/`canRead` (PDF über das Werkzeug der App,
  Office im Kern, Audio über das Transkript), `/pagetext` und `findPages` mit `kind`, `WeeklyCore.moduleFileIDs` und
  `WeeklyIndex.isPDF` mit allen Textquellen.
- App: `Views/Library/TextDocumentView.swift` (Textansicht und Transkript-Aufforderung), `Services/AudioTranscriber.swift`,
  `Views/Library/LibraryVideoLinks.swift`; `LibFile.opensAsText` entscheidet in `LibraryView` (Views.swift).
- Web: `app/static/filekinds.js`, `views-lib.js` (Symbole), `views-doc.js` (PowerPoint-Seiten, Audio-Hinweis).

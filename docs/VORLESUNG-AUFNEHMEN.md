# Vorlesung aufnehmen (iPad), Stand 04.11.2026

Vorbild der Konkurrenz: „Record your lectures and get AI-generated summaries, key points, and study materials.“
Regeln des Inhabers: Aufnahme und Mitschrift bleiben auf dem Gerät; an die KI geht nur Text, nie Audio, und nur nach
dem Antippen (0 Aufrufe ohne Klick); nichts versprechen, was nicht läuft.

## Was es tut

- **Aufnehmen** im Moduldetail, Reiter „Aufzeichnungen“, Karte „Eigene Aufnahmen“ (seit heute auch ohne Stud.IP, der
  Reiter erscheint in jedem lokalen Container). Dialog: Termin aus dem Stundenplan (der gerade laufende Termin des Moduls
  ist vorgewählt, `GET /api/recordings/own/suggest`), Titel, Sprache der Mitschrift (Deutsch, Englisch), dann Start, Pause,
  Fortsetzen, „Stopp und speichern“ mit Pegel und Dauer. Die Aufnahme läuft mit gesperrtem Bildschirm weiter
  (`UIBackgroundModes` audio, Kategorie `.record`); eine Unterbrechung (Anruf) hält sie an, weiter geht es auf Antippen.
- **Datei**: m4a (AAC 64 kbit/s, Eingangsrate des Mikrofons) unter `<Container>/recordings/eigene/<id>.m4a`,
  Dateischutz nach dem ersten Entsperren; daneben `<id>.txt` mit der Mitschrift (`[mm:ss] Text` je Abschnitt).
- **Mitschrift auf dem Gerät**: `SFSpeechRecognizer` mit `requiresOnDeviceRecognition = true`, live während der
  Aufnahme in Anläufen von etwa einer Minute (neuer Anlauf an einer Sprechpause nach 60 s, spätestens nach 75 s);
  die Segmente aller Anläufe werden mit Zeitversatz zu Abschnitten (`TranscriptSections.build`: Schnitt nach 60 s an der
  nächsten Segmentgrenze oder an einer Pause ≥ 1,5 s ab 20 s Länge). Ohne Erlaubnis oder ohne geladenes Sprachpaket wird
  nur aufgenommen; „Mitschrift nachholen“ erkennt die ganze Datei später (`SFSpeechURLRecognitionRequest`, ebenfalls nur
  auf dem Gerät).
- **Ansicht einer Aufnahme**: Abspielen (AVAudioPlayer), Abschnitte mit Zeitmarken (antippen springt), Umbenennen, Löschen
  (Datei, Mitschrift und Eintrag).
- **KI auf Wunsch** (nur mit verbundenem ChatGPT): „Zusammenfassen“, „Kernpunkte“, „Karteikarten“ schicken den **Text**
  eines Teils der Mitschrift an `POST /api/ai/tutor` (`page_text`, ohne Datei). Der Prompt nimmt höchstens 9000 Zeichen
  (`AIPrompts.tutor`), darum ist eine lange Mitschrift in Teile geteilt (`TranscriptSections.chunks`), der Nutzer wählt den
  Teil. Karteikarten werden mit `POST /api/flashcards` gespeichert, erst nach Durchsicht.
- **Suche**: `GET /api/search` liefert zusätzlich `recordings` (nur mit Treffern, sonst bleibt die Antwort wie am PC):
  Titel, Modul, Abschnittsbeginn, Ausschnitt; die App zeigt den Treffer und öffnet das Modul.
- **Nicht** Quelle gemeinsamer Wochentests: die werden über den Material-Abdruck zwischen Studierenden geteilt
  (docs/GEMEINSAME-WOCHENTESTS.md); eine persönliche Mitschrift würde den Abdruck jedes Nutzers verschieden machen.
  Wer die Mitschrift für Fragen nutzen will, nimmt die KI-Hilfe in der Aufnahme.

## Kern (UniFlowCore, läuft auch unter Linux)

- `Opencast/OwnRecording.swift`: `TranscriptSection`, `TranscriptSegment`, `TranscriptSections` (build, format, parse,
  timestamp, plainText, chunks), `RecordingEventSuggestion` (laufender Termin mit 15 Minuten Toleranz; abgewählte,
  ausgefallene und verschobene Termine zählen nicht), `OwnRecordingFiles`, `OwnRecordingStore` (Tabelle `own_recordings`,
  nur auf dem Gerät, bei Bedarf angelegt wie `opencast_videos`).
- `LocalBackend/Endpoints/OwnRecordingEndpoints.swift` (`LocalBackend.standardModules`):
  `GET/POST /api/recordings/own`, `GET /api/recordings/own/suggest?date=&time=`, `GET/PATCH/DELETE /api/recordings/own/{id}`.
  Der Python-Dienst kennt diese Pfade nicht (Aufnahmen sind reine Gerätedaten).
- Abweichung in `SearchEndpoints`: Schlüssel `recordings` nur mit Treffern.

## App

- `Services/LectureRecorder.swift`: AVAudioEngine-Tap → AVAudioFile (AAC) und Spracherkennung; `TapSink` außerhalb des
  Hauptthreads; Erlaubnisse (`requestMicrophone`, `requestSpeech`), `transcribe(url:language:)`.
- `Views/Recordings/LectureRecorderViews.swift`: `OwnRecordingsSection` (in `RecordingsPanel`), `LectureRecordDialog`,
  `OwnRecordingDetail`, `OwnRecordingPlayer`. Suche: `ShellState.search` (Treffer `recordings`).
- Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `UIBackgroundModes` audio.
  **Achtung:** `xcodegen generate` schreibt die Info.plist aus `project.yml` (`info.properties`) neu; die drei Einträge
  müssen dort ebenfalls stehen, sonst verschwinden sie beim nächsten Generieren (project.yml war für diese Arbeit gesperrt,
  offener Punkt).
- `PrivacyInfo.xcprivacy`: keine neue API mit Begründungspflicht, keine neue Datenart (Kommentar ergänzt);
  `docs/release/DATENSCHUTZ.md` Abschnitte 3 und 8a.

## Am echten iPad prüfen (im Simulator nicht möglich)

1. Erste Aufnahme: Systemdialoge Mikrofon und Spracherkennung mit den Texten aus der Info.plist.
2. Mitschrift erscheint live; unter Einstellungen → Allgemein → Tastatur → Diktieren muss das Sprachpaket geladen sein,
   sonst „Ohne Mitschrift“ mit Hinweis.
3. Bildschirm sperren und App in den Hintergrund: Dauer läuft weiter, Datei wächst; Anruf hält an, „Fortsetzen“ geht.
4. 90 Minuten: Speicher und Akku beobachten, Abschnitte etwa je Minute, Datei etwa 40 MB.
5. „Mitschrift nachholen“ bei einer Aufnahme ohne Erkennung.
6. Mit verbundenem ChatGPT: Zusammenfassen/Kernpunkte/Karteikarten nur nach Antippen, Teil-Auswahl bei langen Mitschriften.

## Tests

- Kern: `OwnRecordingTests` (Abschnitte aus synthetischen Segmenten, Pausenregel, Zeitversatz, Textform hin und zurück,
  Termin-Vorschlag, Endpunkte mit Dateiablage und ohne, Suche, Routen).
- App: `OwnRecordingsAppTests` (Ablage im Container, Karte und Zeilen in der gehosteten Ansicht, Hilfsfunktionen; kein
  Mikrofon im Simulator).
- Python: `tests/test_release_texts.py`, `tests/test_rechtstexte.py`, `tests/test_site.py` nach `tools/gen-site.py`.

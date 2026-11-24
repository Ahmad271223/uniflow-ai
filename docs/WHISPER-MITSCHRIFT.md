# Bessere Mitschrift mit Whisper (für 1.0.8), Stand 24.11.2026

Auftrag des Inhabers 24.11.2026: „baue das schon mal komplett fertig für 1.0.8“ – nach der Analyse, wo WhisperKit in
StudiNow etwas bringt. Zweig `app/whisper-mitschrift` (Worktree `~/Studora-Builds/wt-whisper`), aufgesetzt auf
`release/1.0.7-b47` @ `9a5983d8`. Nicht in 1.0.7, nichts hochgeladen, nichts gepusht.

## Was es tut

Die Erkennung von Apple bleibt, wie sie ist (docs/VORLESUNG-AUFNEHMEN.md, docs/DATEIARTEN.md): live beim Aufnehmen und
ohne Download. Neu ist ein zweiter Weg mit einem Sprachmodell auf dem Gerät (Whisper über WhisperKit, CoreML):

| Stelle | Vorher | Neu |
|---|---|---|
| Eigene Aufnahme (Moduldetail → Aufzeichnungen → Eigene Aufnahmen) | Mitschrift von Apple, „Mitschrift nachholen“ | zusätzlich „Genauer erkennen“ bzw. „Mitschrift erstellen“ mit Whisper |
| Uni-Aufzeichnung (Stud.IP/Opencast), **geladen** | keine Mitschrift | Knopf „Mitschrift erstellen“ an der Zeile; danach lesen, durchsuchen, KI-Hilfe wie bei eigenen Aufnahmen |
| Audio-Datei in der Bibliothek (mp3, m4a) | „Transkript erstellen“ mit Apple | mit geladenem Sprachmodell automatisch Whisper |
| Einstellungen → Module | – | Karte „Bessere Mitschrift“: Sprachmodell laden, wechseln, löschen |

- **Alles auf dem Gerät.** Ton und Text verlassen das Gerät nicht. Geladen wird nur das Sprachmodell, einmalig, vom
  Modell-Verzeichnis `argmaxinc/whisperkit-coreml` bei Hugging Face (dazu das Wörterbuch des Modells von
  `openai/whisper-…` ebenfalls bei Hugging Face). Dabei sieht Hugging Face die IP-Adresse – das steht im Dialog.
- **Zwei Modelle:** „Genau“ (`openai_whisper-large-v3-v20240930_626MB`, 626 MB) und „Kompakt“
  (`openai_whisper-small_216MB`, 216 MB). „Genau“ wird nur angeboten, wenn WhisperKit es für das Gerät freigibt
  (`WhisperKit.recommendedModels().supported`); das empfohlene trägt die Marke „Empfohlen“.
- **Lange Aufnahmen:** die Tonspur wird in Stücken von 3 Minuten gelesen (nie die ganze Datei im Speicher) und Stück für
  Stück erkannt. Nach jedem Stück steht der Zwischenstand in der Datenbank (`transcript_status = partial`). „Anhalten“
  oder ein Abbruch verliert nichts: „Weiter erkennen“ macht am Ende des letzten Abschnitts weiter.
- **App muss vorn bleiben:** CoreML darf im Hintergrund nicht auf den Grafikchip. Die Erkennung wartet dann und läuft
  weiter, sobald StudiNow wieder vorn ist; solange sie läuft, bleibt der Bildschirm an.
- **Aufräumen:** Steuerzeichen von Whisper, Wiederholungs-Schleifen und Sätze, die Whisper bei Stille erfindet
  („Untertitel der Amara.org-Community“ u. Ä.), fallen weg (`WhisperSlices`).
- **Suche und KI-Hilfe** unverändert: die Mitschrift liegt in derselben Tabelle (`own_recordings`) und Textdatei wie
  bisher; „Zusammenfassen“, „Kernpunkte“, „Karteikarten“ schicken wie bisher nur den Text eines Teils, nur nach Antippen.

## Entscheidungen, die ich für den Bau getroffen habe (vom Inhaber noch zu bestätigen)

1. **Für alle Tarife.** Die Aufnahme selbst hat heute keine Tarif-Sperre und Whisper kostet StudiNow nichts (läuft auf
   dem Gerät). Die KI-Hilfe mit der Mitschrift bleibt wie bisher an Pro AI gebunden. Soll die genauere Mitschrift nur
   Plus oder Pro AI bekommen, ist das eine Stelle (`WhisperFeature`), dazu eine Zeile in der Tarif-Tabelle.
2. **Schalter** `WhisperFeature.isEnabled` (an). Aus = keine Karte, keine Knöpfe, kein Download.
3. **Download direkt bei Hugging Face.** Alternative: die zwei Modelle auf dem eigenen Server ablegen
   (`WhisperKitConfig.modelEndpoint`/`modelRepo` sind dafür vorgesehen) – dann sieht kein Dritter die IP-Adresse, aber
   der Server trägt je Nutzer bis zu 626 MB Verkehr.
4. **Uni-Videos nur, wenn sie geladen sind** (Knopf „Laden“ gibt es schon). Ein Stream wird nicht mitgeschnitten.
5. **Live beim Aufnehmen bleibt Apple.** Whisper erkennt nach der Aufnahme aus der Datei.

## Vor einer Veröffentlichung nötig (nicht erledigt, braucht den Inhaber)

- **Datenschutzerklärung** (Abschnitt zu Aufnahmen): ergänzen, dass auf Wunsch ein Sprachmodell von Hugging Face
  (Hugging Face, Inc., USA) geladen wird und dabei die IP-Adresse übertragen wird; dass Mitschriften jetzt auch aus
  geladenen Uni-Aufzeichnungen entstehen und nur auf dem Gerät liegen. Vorschlag:
  „Auf Wunsch lädt die App einmalig ein Sprachmodell (Whisper) vom Modell-Verzeichnis Hugging Face (Hugging Face, Inc.,
  USA). Dabei wird wie bei jedem Abruf deine IP-Adresse an Hugging Face übertragen; Inhalte von dir werden nicht
  gesendet. Mit dem Modell wandelt die App eigene Aufnahmen, Audio-Dateien und geladene Uni-Aufzeichnungen
  ausschließlich auf dem Gerät in Text um.“
- **Hinweis zum Urheberrecht** bei Uni-Aufzeichnungen: die Mitschrift ist wie das Video nur für den eigenen Gebrauch
  (steht sinngemäß schon beim Bereich „Aufzeichnungen“; die Mitschrift lässt sich nicht teilen).
- **Lizenz**: WhisperKit steht unter der MIT-Lizenz (Copyright 2024 argmax, inc.), die Whisper-Modelle von OpenAI
  ebenfalls. Der Lizenztext muss mit der App ausgeliefert oder verlinkt werden (z. B. unter „Hilfe & Rechtliches“);
  eine solche Seite gibt es in der App noch nicht.
- **App-Store-Text und Prüfhinweise** für 1.0.8 (neue Funktion, Download nach der Installation).
- **Am echten iPad und iPhone messen**: Dauer und Wärme bei 90 Minuten, Arbeitsspeicher mit „Genau“ auf einem älteren
  Gerät, Verhalten bei gesperrtem Bildschirm. Im Simulator rechnet nur der Prozessor des Mac; die Zahlen unten sagen
  nichts über ein iPad.

## Aufbau

- Kern (`Packages/UniFlowCore`, ohne WhisperKit, läuft auch unter Linux):
  - `Opencast/WhisperTranscript.swift`: `WhisperModels` (Auswahl, Vorschlag je Gerät), `WhisperSlices` (Stücke,
    Aufräumen, Weitermachen), `WhisperRawSegment`.
  - `Opencast/OwnRecording.swift`: Spalten `transcript_engine` (`apple` | `whisper`) und `source_video_id`
    (`Kurs|Video` wie `OpencastEntry.id`), per `ALTER TABLE` nachgetragen; Mitschriften zu Uni-Aufzeichnungen stehen
    nicht unter „Eigene Aufnahmen“.
  - `LocalBackend/Endpoints/OwnRecordingEndpoints.swift`: `GET /api/recordings/own/video?id=`,
    `GET /api/recordings/own/videos`, `POST` mit `source_video_id`, `PATCH` mit `transcript_engine`.
- App:
  - `UniFlow/Services/WhisperMitschrift.swift`: `WhisperFeature`, `WhisperAudio` (Tonspur aus Audio **und** Video über
    `AVAssetReader`, 16 kHz mono), `WhisperEngine` (geladenes Modell), `WhisperModelStore` (laden, einrichten, löschen;
    Ordner `Application Support/Whisper`, von der Gerätesicherung ausgenommen), `WhisperJobs` (eine Aufnahme nach der
    anderen, Zwischenstand, Anhalten).
  - `UniFlow/Views/Recordings/WhisperViews.swift`: Karte, Dialog, Zeile je Modell, Fortschritt, Knopf am Video.
  - Eingehängt in `LectureRecorderViews.swift` (Ansicht einer Aufnahme), `RecordingsViews.swift` (Zeile eines Videos),
    `AudioTranscriber.swift` (Audio-Dateien), `SettingsPage.swift` (Bereich „Module“).
- Fremdpaket: `https://github.com/argmaxinc/WhisperKit`, fest auf **1.1.1** (`project.yml`), gebunden wird nur das
  Produkt `WhisperKit`. Es ist das erste und einzige Fremdpaket der App.

## Tests

- Kern: `WhisperTranscriptTests` (9) und zwei neue in `OwnRecordingTests`; voller Kern-Lauf 1819 Tests, 0 rot.
- App (iPad-Simulator): `WhisperViewsAppTests` (10) – Stand der Modelle auf der Platte, Knöpfe in jedem Stand, Karte,
  Mitschrift zu einem Video; zusammen mit `OwnRecordingsAppTests` 16 Tests, 0 rot.
- **Echte Erkennung** (`WhisperLiveTests`, nur auf Wunsch, siehe Kopf der Datei): lädt ein Modell und wandelt eine
  deutsche Probe-Vorlesung um (5:17 min, vom Mac gesprochen, `~/Studora-Builds/whisper-probe/vorlesung.m4a`), prüft
  Zeiten, Fortschritt, erwartete Wörter und das Weitermachen.
  Die Ergebnisse stehen unter „Probelauf“.

## Probelauf (iPad-Simulator auf dem Mac, 24.11.2026)

| Modell | Download | 5:17 min Ton | Abschnitte | Auffällig |
|---|---|---|---|---|
| Kompakt (216 MB) | 18 s | 159 s | 5 | „Tyler-Polynom“ statt Taylor, „Mittelwärtssatz“ einmal; sonst sauber, auch „Gradient-Descent“, „Machine Learning“ |
| Genau (626 MB) | 32 s | 142 s | 11 | „Mittelwertsatz“, „Graphen“, „Learning Rate“, Satzzeichen und Großschreibung richtig; „Teilor-Polynom“ (die Mac-Stimme spricht Taylor so) |

Beide Läufe: Zeiten aufsteigend und bis ans Ende der Datei, Fortschritt bis 100 %, keine Steuerzeichen, keine erfundenen
Zeilen; Weitermachen ab der Hälfte beginnt nicht bei null und behält die fertigen Abschnitte. Die Mitschriften liegen
unter `~/Studora-Builds/whisper-probe/klein.txt` und `gross.txt`.

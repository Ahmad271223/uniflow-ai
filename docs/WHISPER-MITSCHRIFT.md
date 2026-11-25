# Bessere Mitschrift mit Whisper (für 1.0.8), Stand 25.11.2026

Auftrag des Inhabers 24.11.2026: „baue das schon mal komplett fertig für 1.0.8“ – nach der Analyse, wo WhisperKit in
StudiNow etwas bringt. Zweig `app/whisper-mitschrift` (Worktree `~/Studora-Builds/wt-whisper`), aufgesetzt auf
`release/1.0.7-b47` @ `9a5983d8`. Nicht in 1.0.7, nichts hochgeladen, nichts gepusht.

**Auf dem iPad des Inhabers** (Kabel/WLAN, `devicectl`, mit seinem Okay vom 24.11.): Testfassung 1.0.7 (49), Release,
aus diesem Zweig – zuerst `871264cd` (24.11. abends), seit 25.11. 09:05 `9da803b9` mit Fachwörter-Hilfe und Lizenzen.
Seit 25.11. 15:24 liegt die Fassung mit Suche und Sprung ins Video (`4a89ef7b`) auf dem iPad.
Nicht bei Apple, kein TestFlight. Der Inhaber prüft dort Dauer, Wärme und Textgüte; sein Ergebnis steht noch aus.

**Rückmeldung des Inhabers vom iPad (iPad A16, 25.11.2026):** Der Sprung ins Uni-Video landet an der richtigen
Stelle. Ein ganzes Video braucht 5 bis 10 Minuten, je nach Länge. Noch offen: welches Modell er geladen hat („Genau“
oder „Kompakt“ – die Frage hat er nicht verstanden), ob das iPad warm wird, ob die Fachwörter stimmen.

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
- **Fachwörter-Hilfe** (Auftrag des Inhabers 24.11. abends: „mach das“): Whisper bekommt je Stück eine kurze Liste
  von Fachbegriffen aus den Vorlesungen und Skripten des Moduls (nur Dateien, die auf dem Gerät liegen; Seitentexte
  der Skriptsuche, ohne KI, ohne Netz). Damit schreibt es „Taylor-Polynom“ statt „Tyler-/Teilor-Polynom“. Weil nur
  rund zehn Begriffe in die Vorgabe passen, liest die App im Skript mit: zu dem, was zuletzt gesagt wurde, sucht sie
  die passende Seite und nimmt deren Begriffe und die der Seite danach; ohne Treffer die wichtigsten des Moduls.
  Für alle Tarife, kostet keine Credits. Schalter `WhisperFeature.usesVocabulary`.
- **Suche in der Mitschrift und Sprung ins Video** (Auftrag des Inhabers 25.11.: „Ja, einbauen“): in der Ansicht einer
  Mitschrift steht ein Suchfeld. Wort oder Wortfolge eintippen → Treffer mit Ausschnitt und Zeitmarke statt der ganzen
  Mitschrift (Groß-/Kleinschreibung und Umlaute egal). Zeitmarke antippen → die eigene Aufnahme springt dorthin; bei
  einer geladenen Uni-Aufzeichnung läuft das **Video in derselben Ansicht** an dieser Stelle (bleibt oben stehen,
  während die Mitschrift darunter scrollt). Die Stelle eines Treffers ist geschätzt (anteilig im Abschnitt, 4 Sekunden
  Vorlauf), weil eine Mitschrift nur Anfang und Ende eines Abschnitts kennt. Vorher gab es weder Suche noch Sprung ins
  Video. Ohne Netz, ohne KI, alle Tarife.
- **KI-Hilfe** unverändert: die Mitschrift liegt in derselben Tabelle (`own_recordings`) und Textdatei wie
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

6. **Fachwörter-Hilfe ohne Schalter für den Nutzer** und ohne Anzeige der Liste; ein Satz in der Karte sagt, dass es
   sie gibt. Begriffe kommen nur aus Dateien der Art „Vorlesung“ und „Skript“ (wie die Skriptsuche), nicht aus
   Übungsblättern.
7. **„Text glätten“ mit der KI (Pro AI) ist nicht gebaut.** Vorschlag vom 24.11.: als Knopf je Abschnitt neben
   „Zusammenfassen“, nie automatisch (Credits, Risiko erfundener Inhalte, Text verlässt das Gerät); das Original
   bleibt. Der Inhaber hat bisher nur die Fachwörter-Hilfe bestellt.

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
- **Lizenz** – erledigt 25.11.: Einstellungen → Hilfe & Rechtliches → „Lizenzen“ (`OpenSourceDialog`, `UFOpenSource`)
  nennt WhisperKit (Copyright (c) 2024 argmax, inc.) und die Whisper-Modelle (Copyright (c) 2022 OpenAI) mit dem
  Wortlaut der MIT-Lizenz. Gebunden wird nur das Produkt `WhisperKit` (mit `ArgmaxCore` aus demselben Paket).
- **Datenschutzerklärung zur Fachwörter-Hilfe**: nichts Neues nach außen – die Begriffe entstehen auf dem Gerät aus
  Dateien, die schon dort liegen, und gehen nur an das Modell auf dem Gerät. Ein Satz dazu schadet nicht.
- **App-Store-Text und Prüfhinweise** für 1.0.8 (neue Funktion, Download nach der Installation).
- **Am echten iPad und iPhone messen**: Dauer und Wärme bei 90 Minuten, Arbeitsspeicher mit „Genau“ auf einem älteren
  Gerät, Verhalten bei gesperrtem Bildschirm. Im Simulator rechnet nur der Prozessor des Mac; die Zahlen unten sagen
  nichts über ein iPad.

## Aufbau

- Kern (`Packages/UniFlowCore`, ohne WhisperKit, läuft auch unter Linux):
  - `Opencast/WhisperTranscript.swift`: `WhisperModels` (Auswahl, Vorschlag je Gerät), `WhisperSlices` (Stücke,
    Aufräumen, Weitermachen), `WhisperRawSegment`.
  - ebenda `WhisperVocabulary` (Wörter eines Seitentexts, Gewicht als Fachbegriff, Vorgabe-Satz, Erkennen einer
    nachgesprochenen Vorgabe) und `WhisperGlossary` (Begriffe je Seite, „welche Seite passt zum Gesagten“).
  - `Opencast/TranscriptSearch.swift`: Treffer einer Suche in den Abschnitten (Ausschnitt, geschätzte Stelle).
  - `Opencast/OwnRecording.swift`: Spalten `transcript_engine` (`apple` | `whisper`) und `source_video_id`
    (`Kurs|Video` wie `OpencastEntry.id`), per `ALTER TABLE` nachgetragen; Mitschriften zu Uni-Aufzeichnungen stehen
    nicht unter „Eigene Aufnahmen“.
  - `LocalBackend/Endpoints/OwnRecordingEndpoints.swift`: `GET /api/recordings/own/video?id=`,
    `GET /api/recordings/own/videos`, `POST` mit `source_video_id`, `PATCH` mit `transcript_engine`,
    `POST /api/recordings/own/vocabulary` (`{id | file_id, text?}` → `{terms, files}`; Glossar je Modul und Stand der
    Dateien im Zwischenspeicher `GlossaryCache`, Seitentexte ohne Texterkennung, höchstens 1500 Seiten).
- App:
  - `UniFlow/Services/WhisperMitschrift.swift`: `WhisperFeature`, `WhisperAudio` (Tonspur aus Audio **und** Video über
    `AVAssetReader`, 16 kHz mono), `WhisperEngine` (geladenes Modell), `WhisperModelStore` (laden, einrichten, löschen;
    Ordner `Application Support/Whisper`, von der Gerätesicherung ausgenommen), `WhisperJobs` (eine Aufnahme nach der
    anderen, Zwischenstand, Anhalten).
    Fachwörter: `WhisperEngine.prompt` macht aus der Liste Wortteile und kürzt auf `maxPromptTokens` (40);
    `WhisperJobs.Vocabulary` fragt vor jedem Stück mit dem zuletzt Erkannten nach.
  - `UniFlow/Views/Recordings/WhisperViews.swift`: Karte, Dialog, Zeile je Modell, Fortschritt, Knopf am Video.
  - `LectureRecorderViews.swift`: `OwnRecordingDetail` mit Suchfeld, `TranscriptHitRow`, `TranscriptVideoPlayer`
    (AVPlayer erst beim ersten Sprung, über `UFAVPlayer`); Knöpfe unten auf dem iPhone ohne Symbole (vorher
    abgeschnitten: „Umb…“, „Lös…“).
  - Eingehängt in `LectureRecorderViews.swift` (Ansicht einer Aufnahme), `RecordingsViews.swift` (Zeile eines Videos),
    `AudioTranscriber.swift` (Audio-Dateien), `SettingsPage.swift` (Bereich „Module“).
- Fremdpaket: `https://github.com/argmaxinc/WhisperKit`, fest auf **1.1.1** (`project.yml`), gebunden wird nur das
  Produkt `WhisperKit`. Es ist das erste und einzige Fremdpaket der App.

## Fachwörter-Hilfe: was die Messung gezeigt hat (24.11.2026)

- **Der Rahmen ist klein.** WhisperKit rechnet Vorgabe und erkannten Text zusammen in 224 Wortteile je 30 Sekunden Ton
  (`Constants.maxTokenContext`). Mit 40 Begriffen (179 Wortteile) dauerte die Probe doppelt so lang (325 s statt
  159 s) und 30 Sekunden Text fehlten. Darum höchstens 40 Wortteile – das sind etwa 7 bis 12 Begriffe.
- **Falsche Stille.** Mit Vorgabe hielt WhisperKit ein Fenster fälschlich für Stille (`firstTokenLogProbThreshold`)
  und ließ 30 Sekunden aus. Mit Vorgabe ist diese Prüfung deshalb aus; ohne Vorgabe bleibt sie wie bisher.
- **Stille mit Vorgabe:** Probe mit 45 Sekunden Stille mitten in der Aufnahme – nichts erfunden, nichts verloren.
  Spricht Whisper die Liste nach, fällt das Segment weg (`WhisperVocabulary.isEcho`); Anmerkungen in eckigen Klammern
  („[Präsidentin]“ am Ende einer Probe) entfernt `WhisperSlices.clean`.
- **Tempo:** unverändert (Kompakt 159–165 s mit, 159 s ohne; Genau 214 s mit, 240 s ohne – der Mac war beim zweiten
  Lauf stärker ausgelastet).
- **Grenzen:** Begriffe gibt es nur, wenn die Aufnahme zu einem Modul gehört und dessen Vorlesungen/Skripte geladen
  sind. Ein Begriff muss im Modul mindestens zweimal vorkommen. Die Auswahl ist eine Faustregel (Bindestrich-Begriffe,
  Namen und Fremdwörter an der Schreibweise, Abkürzungen, lange Zusammensetzungen), kein Wörterbuch. Mit echten
  Skripten des Inhabers ist sie noch nicht geprüft.

## Tests

- Kern: `WhisperTranscriptTests` (15, davon 6 zur Fachwörter-Hilfe) und drei neue in `OwnRecordingTests`; voller
  Kern-Lauf 25.11.: 1826 Tests, 0 rot.
- App (iPad-Simulator): `WhisperViewsAppTests` (14) – Stand der Modelle auf der Platte, Knöpfe in jedem Stand, Karte,
  Mitschrift zu einem Video, Antwort der Wortlisten-Route, Lizenz-Dialog; mit `OwnRecordingsAppTests` und
  `EinstellungenKlarAppTests` 32 Tests, 0 rot.
- Ganze iPad-Reihe 24.11. (2217 Tests): 134 rot, alle außerhalb der Mitschrift (Editor, Bilder, Abnahmen) mit dem
  bekannten Bild unter Last (`InvalidTransition`, „Zeit abgelaufen“).
- Wiederholung der 37 betroffenen Klassen allein (25.11., Stand mit Fachwörter-Hilfe): 402 Tests, 1 rot –
  `StoreScreenshotTests/test01Uebersicht` („Diese Prüfungen solltest du anmelden“ fehlt). Derselbe Test ist auf dem
  unveränderten `release/1.0.7-b47` @ `9a5983d8` genauso rot: er rechnet mit dem heutigen Datum (Meldezeitraum) und hat
  mit der Mitschrift nichts zu tun. Gehört vor dem nächsten Store-Bild-Lauf angesehen.
- iPhone-Simulator (25.11.): `WhisperViewsAppTests`, `OwnRecordingsAppTests`, `EinstellungenKlarAppTests` 32 Tests,
  0 rot; Bilder in iPhone-Breite unter `~/Studora-Builds/whisper-probe/bilder-iphone/`.
- Schneller Lauf (`tools/tests-schnell.sh`, 25.11.): pytest 4081 grün, 1 rot
  (`tests/test_web_overview.py::test_overview_answers_what_to_do_today`, am 24.11. schon auf `server/probe-vorab` rot,
  Web-Übersicht des Dienstes, nicht Teil dieses Zweigs); node 472 grün.
- Mac („Designed for iPad“, `tools/mac-test.sh`, 25.11. 14:18): `WhisperViewsAppTests` und `OwnRecordingsAppTests`
  20 Tests, 0 rot. Die echte Erkennung mit einem Modell ist am Mac nicht gelaufen (nur die Ansichten und der Stand
  der Modelle).
- Schneller Lauf nach Suche und Sprung (25.11. nachmittags): pytest 4082 grün, 0 rot; node 472 grün. Kern 1833 grün.
- Suche und Sprung (25.11.): Kern `TranscriptSearchTests` (7); App `WhisperViewsAppTests` jetzt 17 (Treffer statt
  ganzer Mitschrift, „Leeren“, Video erscheint beim Antippen einer Zeitmarke, Player entsteht erst bei Bedarf) – iPad
  35, iPhone 23, Mac 23 Tests, 0 rot. Sprung mit echter Datei (`WhisperLiveTests/testJumpLandsAtTheRightPlaceAndPlays`):
  Ziel 61 s, steht bei 61,0 s und läuft. Mit einem echten Uni-Video (mp4) ist der Sprung nur am Gerät zu prüfen.
- **Echte Erkennung** (`WhisperLiveTests`, nur auf Wunsch, siehe Kopf der Datei): lädt ein Modell und wandelt eine
  deutsche Probe-Vorlesung um (5:17 min, vom Mac gesprochen, `~/Studora-Builds/whisper-probe/vorlesung.m4a`), prüft
  Zeiten, Fortschritt, erwartete Wörter und das Weitermachen. Mit `UF_WHISPER_SCRIPT` (Seiten eines Skripts als
  Text, `~/Studora-Builds/whisper-probe/skript.txt`) liest der Lauf wie die App im Skript mit.
  Die Ergebnisse stehen unter „Probelauf“.

## Probelauf (iPad-Simulator auf dem Mac, 24.11.2026)

| Modell | Download | 5:17 min Ton | Abschnitte | Auffällig |
|---|---|---|---|---|
| Kompakt (216 MB) | 18 s | 159 s | 5 | „Tyler-Polynom“ statt Taylor, „Mittelwärtssatz“ einmal; sonst sauber, auch „Gradient-Descent“, „Machine Learning“ |
| Genau (626 MB) | 32 s | 142 s | 11 | „Mittelwertsatz“, „Graphen“, „Learning Rate“, Satzzeichen und Großschreibung richtig; „Teilor-Polynom“ (die Mac-Stimme spricht Taylor so) |

Mit Fachwörter-Hilfe (Probe-Skript mit acht Seiten, dieselbe Aufnahme):

| Modell | Dauer | Taylor-Polynom | Mittelwertsatz | Gradient Descent | Auffällig |
|---|---|---|---|---|---|
| Kompakt ohne | 159 s | 0 von 4 („Tyler-“, „Ptylo-“) | 2 von 6 | 1 von 2 | – |
| Kompakt mit | 159 s | 4 von 4 | 5 von 6 | 2 von 2 | zweimal „Pollenom“ statt Polynom (vorher richtig) |
| Genau ohne | 142 s / 240 s | 0 von 4 („Teilor-“) | 6 von 6 | 1 von 2 | – |
| Genau mit | 214 s | 4 von 4 | 6 von 6 | 2 von 2 | – |

Im ersten Stück steht „Mittelwertsatz“ beim kleinen Modell einmal falsch: dort gab es noch nichts Gesagtes, die Liste
bestand aus den wichtigsten Begriffen des ganzen Skripts, und „Mittelwertsatz“ passte nicht mehr in den Rahmen. Ab dem
zweiten Stück wählt die App die Begriffe der passenden Seite.

Beide Läufe: Zeiten aufsteigend und bis ans Ende der Datei, Fortschritt bis 100 %, keine Steuerzeichen, keine erfundenen
Zeilen; Weitermachen ab der Hälfte beginnt nicht bei null und behält die fertigen Abschnitte. Die Mitschriften liegen
unter `~/Studora-Builds/whisper-probe/klein.txt` und `gross.txt`.

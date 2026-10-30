# Bericht der Cloud-Sitzung vom 30.10.2026

Diese Sitzung lief in einem Linux-Container (Cloud, x86_64, 4 Kerne, 15 GB RAM), nicht auf einem Mac. Darum konnte
sie alles prüfen, was ohne Xcode geht: Python, Generatoren, JS, Swift-Kern (in Docker mit Swift 6.1.3). Die iPad-App
selbst (SwiftUI, Simulator, `xcodebuild`) braucht weiter einen Mac. Dieser Bericht ersetzt die Abschnitte 1 und 5 der
`UEBERGABE-MAC-NEUE-SITZUNG-2026-10-30.md`, der Rest dort gilt weiter.

## 1. Was heute passiert ist

| Schritt | Ergebnis |
| --- | --- |
| `wip/lernplan-woche` → `develop` übernommen (Merge `ea88dfe`) | pytest 568 ×2, Generatoren 21, JS 31, Kern 754 ×2 grün; **App-Lauf steht aus** (siehe 4). Der Inhaber hat die Übernahme ohne App-Lauf ausdrücklich freigegeben. |
| Wackliger Test `test_push_creates_with_mapping_and_pull_with_cursor` behoben (`7ddb1f3`) | Ursache: der Pull-Cursor ist ein Millisekunden-Zeitstempel, eine Änderung in derselben Millisekunde bekam denselben Stempel und fiel beim nächsten Abruf durch (`> cursor`). In einer engen Nachstellung ging in 18 % der Durchläufe eine Änderung verloren. Behebung in `app/sync.py`: der Abruf wartet (meist unter 1 ms, höchstens 100 ms), bis die Uhr über den Cursor hinaus ist. Kein neues Format, keine Prüfdaten, kein Swift. Neuer Test `test_pull_cursor_never_in_current_millisecond`. Nach der Änderung 0 von 2000. |
| Hintergrund-Wochentests, Kern-Teil (`0252597`) | Siehe 2. |
| `node --test tests/js/*.test.mjs` | 31 von 31 grün. Offener Punkt aus der Übergabe erledigt. Hinweis: Node 22 braucht die Dateien einzeln, der Ordner allein geht nicht. |
| Übergabe-Doku | Dieser Bericht, dazu `docs/WOCHENTESTS.md` ergänzt. |

Stand nach dieser Sitzung (alles gepusht auf `develop`):

| Prüfung | Ergebnis |
| --- | --- |
| pytest | 573 (568 + 1 Sync + 4 Wochentest). 6 von 7 Läufen grün; ein Lauf während des parallelen Swift-Builds hatte einen Fehler, dessen Name nicht gesichert wurde. 4 Läufe danach in Folge grün. |
| Generatoren `--check` | 21 / 21 |
| JS | 31 / 31 |
| Swift-Kern (Linux, Swift 6.1.3) | 756 / 756, zweimal. 11 weitere Tests (`ChatGPTSessionTests`, Schlüsselbund) laufen nur auf Apple-Geräten, auf dem Mac also 767. |
| iPad-App (`xcodebuild`, 558 Tests) | **nicht geprüft, braucht Mac** |

Zum Merge-Commit `ea88dfe`: Autor steht auf „Claude“, nicht auf `abcdefg34a` (ein `--amend` setzt nur den Committer).
Ändern ginge nur per Force-Push, den die Regeln verbieten. Alle weiteren Commits haben die richtige Identität. GitHub
zeigt die Commits dieser Sitzung als „Unverified“; das ist rein kosmetisch.

## 2. Neu: Entscheidung für den Hintergrundlauf der Wochentests

Befund: Das Gerüst für Hintergrundläufe um 8, 15 und 20 Uhr gibt es schon (`BackgroundSchedule`,
`BackgroundSyncController`), aber nur für den Stud.IP- und Learnweb-Abgleich. Der Wochentest-Takt hängt dort nicht
dran; auf dem iPad läuft er nur im Vordergrund. Außerdem fehlt auf dem iPad der `Weekly.tick` nach dem Abgleich, den
der PC in `_full_sync` hat.

Gebaut (reine Logik, ohne iOS, gegen dieselben Prüfdaten):

- Python `app/weekly.py`: `slot_at_or_after`, `next_slot`, `background_snapshot(conn, now)`,
  `background_decision(snap, now, ai, busy)`.
- Swift-Kern `LocalBackend/Weekly/WeeklyBackground.swift`: `slot(atOrAfter:)`, `nextSlot`, `snapshot`, `decide`.
- Ergebnis: `{"action": off | no_ai | busy | limit | run | idle, "due": [Plan-IDs], "next_at": Zeit oder null}`.
  - `due` ist genau die Bedingung aus `tick` und `_claim`: offen, `publish_at <= now`, weniger als 3 Versuche, keine
    laufende Sperre.
  - `next_at` ist der nächste Termin aus 8/15/20 Uhr, an dem es etwas zu tun geben kann: nach `publish_at`, nach einer
    Sperre, bei „run“ der nächste Termin (wartende oder fehlgeschlagene Pläne), bei „limit“ morgen 8 Uhr. Null, wenn
    kein offener Plan mit Versuchen übrig ist oder `auto_tests` aus ist.
  - Naive Ortszeit mit Kalendertagen wie `BackgroundSchedule`: um die Zeitumstellung bleibt es bei 8:00 Ortszeit.
- Prüfdaten `weekly.json`: 10 Schritte `background` im Ablauf (vor/nach Plan, aus, keine KI, beschäftigt,
  veröffentlicht) und 90 erfundene Fälle `background_cases` (Termingrenzen auf die Sekunde, Monats- und
  Jahreswechsel, beide Zeitumstellungen, Sperre, 2 und 3 Versuche, Tageslimit mit und ohne Wiederverwendung).
- Tests: Python 4 neue (`test_weekly.py`), Swift 2 neue (`WeeklyFixtureTests`, darunter ein Abgleich von `nextSlot`
  mit `BackgroundSchedule.next` in Europe/Berlin). Absichtlicher Fehler (`>=` → `>`) wird von 9 Fällen gefunden.

Nachtrag (später am 30.10., zweite Cloud-Sitzung): die Punkte 1–5 sind gebaut, der Kern geprüft, die App ungeprüft
(kein Xcode in der Cloud; Syntax mit `swiftc -parse`). Stand je Punkt:

1. **Erledigt (ungeprüft in der App):** `StudIPSync.autoPlan(host:newFiles:weekly:)` ruft nach `StudyAutoPlan.afterSync`
   auch `WeeklyAutoTick.run` (Stud.IP und Hildesheim), nur nach einem vollen Abgleich (`weekly: scope == .full`), nicht
   im kurzen Hintergrundlauf. Hat der Takt etwas veröffentlicht, kommt `.uniflowWeeklyChanged`.
2. **Erledigt (ungeprüft in der App):** `BackgroundSyncController.performRun` wertet im langen Lauf
   `WeeklyBackground.decision(ctx)` (Kern: `snapshot` + `decide`, `ai`/`busy` aus dem Kontext) aus und startet bei
   `run` den Takt (`weeklyTick`, Tests: Attrappe), auch wenn das Gate den Abgleich übersprang (abgelaufene Sitzung,
   Schalter aus); nicht ohne Container, nicht beim Wechsel, nicht neben einem laufenden Abgleich.
3. **Erledigt (ungeprüft in der App):** `schedule()` bestellt den langen Lauf auch bei ausgeschaltetem Abgleich, wenn
   `next_at` gesetzt und die KI verbunden ist (der kurze wird abbestellt); eingeschaltet frühester Beginn = Minimum aus
   `BackgroundSchedule.next` und `next_at` (`WeeklyBackground.date`, Berliner Zeit über `BerlinClock.utcSeconds`).
4. **Erledigt und im Kern geprüft:** `CancellationError`, `URLError.cancelled` und ein abgebrochener Task
   (`Task.isCancelled`, auch wenn die Anbindung den Fehler als `AIError` verpackt) werfen aus `processClaimed` weiter,
   `processPlan` löst nur die Sperre, `Weekly.ask` stellt im abgebrochenen Task keine Anfrage mehr,
   `WeeklyAutoTick.run` liefert `.cancelled`. Kein Rückruf in Python nötig: die Prüfdaten und Fixture-Vergleiche sind
   unverändert. Drei neue Kern-Tests in `WeeklyAutoTickTests` (Abbruch mit beiden Fehlern, `Task.cancel` während der
   KI-Anfrage, Entscheidung und Termin für die App).
5. **Erledigt (ungeprüft in der App):** `BackgroundNotice.weeklyTest` („Neuer Wochentest verfügbar“, ohne Fach oder
   Inhalt) nach denselben Regeln wie die Mitteilung zu neuen Dateien; Satz in `BackgroundSyncCard.timingText`; neue
   App-Tests `testLongRunRunsTheWeeklyStepEvenWithoutSessionTheShortRunNever`,
   `testScheduleOrdersTheLongRunForWeeklyTestsEvenWhenOff` (`BackgroundSyncAppTests`) und
   `testAutoPlanAfterSyncRunsTheWeeklyTick` (`WeeklyAppTests`) – laufen erst auf dem Mac.
6. **Offen:** auf dem Gerät über Tage beobachten; wann iOS wirklich startet, lässt sich nicht testen.

## 3. Wie die App aufgebaut ist (Kurzfassung der Analyse)

**Prinzip:** Python ist die Referenz. 21 Generatoren führen den echten Python-Code mit erfundenen Daten und
eingefrorener Uhr aus und schreiben Prüfdaten nach `packages/shared-contracts/` (3,1 MB). Swift (und Kotlin) müssen
dieselben Antworten und Tabellen byte-gleich liefern. Darum lässt sich der Kern ohne Mac prüfen.

| Teil | Umfang | Rolle |
| --- | --- | --- |
| Python-Server `app/` | 58 Module, 21.400 Zeilen, 146 Endpunkte in `server.py` + 4 Router (Konto 18, Community 38, Billing 10, Bibliothek 9); 32 Tabellen in `db.py` plus weitere je Modul | Einzelplatz-PC, Windows-Desktop (PyInstaller + Tauri), gehosteter Dienst (`LERNAPP_MODE=hosted`, eine DB je Konto) |
| Swift-Kern `UniFlowCore` | 123 Dateien, 30.300 Zeilen; `LocalBackend` beantwortet 118 `/api`-Pfade lokal | Läuft auf iOS, macOS und Linux; ohne fremde Pakete |
| iPad-App `UniFlow/` | 93 Dateien, 33.900 Zeilen; nur iPad (`TARGETED_DEVICE_FAMILY 2`), Mac über „Designed for iPad“; Name „Studora“, Bundle `de.uniflow.ai`, Version 0.2.0 | PDFKit, PencilKit, StoreKit 2, CloudKit, BackgroundTasks, WebKit |
| Android `apps/android` | 4.700 Zeilen + 2.900 Test (119 Tests) | Client für Dienst/PC; nur im Docker-Bild gebaut, nie auf Gerät; V2 |
| Web `app/static` | 5.400 Zeilen (editor.js 174 KB), pdf.js, Konva, pdf-lib | Oberfläche am PC |
| Tests | pytest 573, Kern 767 (Linux 756), App 558, JS 31, Android 119 | CI auf GitHub ist seit 25.10. gesperrt (Abrechnung), daher `[skip ci]` und nur lokale Läufe |

**Datenfluss ohne PC (App-Store-V1):** Anmeldung in der WebView bei Stud.IP → `StudIPClient` (JSON:API) →
`UniStore`/`UniDownloads` in die lokale SQLite (Schema byte-gleich zu `db.py`) → `UniRules.classify` ordnet Fach, Art
und Lehrwoche zu → `StudyAutoPlan.afterSync` plant die Woche (nur Lehrwoche N, plus Skriptrest nach dem Marker der
Vorwoche) → die Oberfläche fragt über `LocalRouter` dieselben `/api`-Pfade wie am PC. KI geht direkt vom Gerät an
OpenAI über das ChatGPT-Abo des Nutzers. Community über CloudKit. Echte Platzhalter auf dem iPad: `POST /api/sync`,
`GET /api/services`, `POST /api/grades/sync`, `GET /api/qis/documents/{id}`.

## 4. Was funktionieren wird, und wie

Nach Code und Tests fertig und geprüft (ohne Gerät):

- Stud.IP-Abgleich (mit 150 echten LUH-Dateien geprüft), Learnweb/Hildesheim (ohne Netz), Stundenplan 1:1 aus dem
  Stud.IP-Kalender, Suche offline, Karteikarten (Plus), Noten aus QIS (ohne Bescheinigungen), Opencast,
  Fristen/Erinnerungen, Demo-Inhalte.
- Lernplan nach der Regel vom 30.10. (Python und Swift gegen dieselben Prüfdaten, Szenario „lehrwoche“).
- Wochentests mit Marker: 15 Aufgaben (4/6/5), eine Klausuraufgabe, Veröffentlichung 24 h nach Vorlesungsende, Warten
  auf erwartete Unterlagen bis 48 h, Nachtrag, Rangliste, Probeklausur; Testaufgabe im Lernplan öffnet den gemeinsamen
  Test. Takt im Vordergrund alle 10 min, nur mit KI.
- Editor-Schritte 3–6 (Pencil, Seiten drehen mit Notizen, Lösungen-Editor, verschlüsseltes Teilen, Versionsverlauf).
- Abos Free und Plus über StoreKit 2; Konto-Anbindung an den Dienst ist vorbereitet, aber unsichtbar ohne Dienst-Adresse.
- Barrierefreiheit: 152 Angaben in der App, VoiceOver-Namen, Textgrößen bis Accessibility3.

Nur mit Vorbehalt, weil die Prüfung mit echten Diensten fehlt:

- KI: alles mit simulierter KI geprüft. Nie mit echter KI auf echtem Skript. Braucht die Client-ID von OpenAI.
- Hildesheim: Zählwerte weichen ab (iPad 195, PC 539 Dateien); die Bitten an die PC-Sitzung stehen in
  `STAND-MAC-SITZUNG.md` ab Zeile 1411.
- QIS auf dem iPad: der Inhaber hat 0 Leistungen, also kein echter Test möglich.

## 5. Was noch fehlt

| Punkt | Wer | Stand |
| --- | --- | --- |
| **Voller App-Lauf ×2 auf `develop` (ea88dfe und neuer)** | Mac-Sitzung | Erster Schritt. Beachten: nach Abgleich wird automatisch geplant, App-Tests, die danach Pakete zählen, könnten abweichen. Lastabhängige Tests einzeln wiederholen (`AuditRunde11AppTests.testDiagnosisWithManyFilesKeepsTheMainThreadFree`, `HardeningSolutionEditorTests.testManyForeignLayersStayFastAndAreReleased`). |
| Hintergrund-Wochentests, App-Teil | Mac-Sitzung | Liste in Abschnitt 2 |
| Apple Developer Program | Inhaber | Anmeldung am 28.10. abgelehnt. Ohne Freigabe kein TestFlight, keine Einreichung, kein „Mit Apple anmelden“, keine CloudKit-Community. |
| Echter ChatGPT-Test | Inhaber | Client-ID von OpenAI nötig |
| Test mit echten Daten und Pencil am iPad | Inhaber + Mac-Sitzung | Stud.IP, QIS, CAS, Pencil-Abnahme (`EDITOR-ABNAHME.md`) |
| Word-Import | später | Ansehen reicht laut Inhaber |
| Android: Seite drehen mit Notizen | PC-Sitzung | `rotate/cases.json` |
| Flaky unter Last | Cloud- oder PC-Sitzung | Ein pytest-Lauf von 7 fiel unter Last; Name nicht gesichert. Nächster Lauf unter Last mit `-rf`, dann gezielt. |
| Alte Branches von Ahmad271223 | Inhaber | Durchsehen, dann schließen (erst nach Ja) |
| Rechtstexte, Kosten, Verträge | Inhaber | Platzhalterseite in `PlanPickerView`, `[[Name]]` usw. in `docs/release/`, Server/Domain/Mail, Datenschutz, Impressum, Anfragen an LUH und Hildesheim |
| Offene Entscheidungen | Inhaber | Geteilter Wochentest gegen das Kontingent? Plus-Kontingent 3 oder 6? (`GEMEINSAME-WOCHENTESTS.md`, `ABO-SYSTEM.md`) |
| Veraltete Doku | irgendwann | `README.md` (noch `claude -p`, KI-Wochenplan), `RELEASE-READINESS.md`, `ENTWICKLUNGSSTAND.md`, `WEB-IPAD-PARITAET.md` (Stand 25.10.), Kommentare in `LocalBackend/Endpoints/Pending/`, `AUFTRAG-APPSTORE-V1.md` §4/§5 gegen §6 |
| Einziges TODO im Code | V2 | `BillingServiceLink.swift:11` (Kaufprüfung beim Dienst) |

## 6. So prüft eine Cloud-Sitzung den Swift-Kern ohne Mac

```bash
docker pull mirror.gcr.io/library/swift:6.1-noble
```

```bash
docker run --rm -v "$PWD":/repo -v /tmp/swiftbuild:/build -w /repo/apps/apple/Packages/UniFlowCore mirror.gcr.io/library/swift:6.1-noble bash -c 'apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --scratch-path /build 2>&1 | tail -5'
```

Docker Hub selbst bremst (429), der Spiegel `mirror.gcr.io` geht. `download.swift.org` ist im Netz der Umgebung
gesperrt, ein Ubuntu-Paket gibt es nicht; darum Docker.

## 7. Nachtrag: App-Lauf auf dem Mac (30.10.2026, abends)

Stand `develop` mit `ae844ad` und `8f8cb8c`, Xcode 27.2, Simulator „iPad“ (iPad Pro 11 M5, iOS 27.2). Ausnahme von der
Regel: Der Inhaber hat den Lauf im Akkubetrieb freigegeben; auf dem Netzteil lief er nicht.

- Build beim ersten Versuch fehlerfrei. Voller App-Lauf ×2: je 563 Tests, 0 Fehler, 2 übersprungen (`EditorScaleTests`
  und `RealSheetSolutionE2ETests`, beide nur auf Anforderung).
- Fehler in `performRun` behoben: Bei ausgeschaltetem Abgleich nannte das Gate nur `.disabled`, der Wochentest lief
  dadurch auch neben einem laufenden Abgleich und beim Wechsel. Der Test dafür schlug vor der Änderung fehl.
- Drei Tests passten nicht mehr zur Regel vom 30.10. (Unterlagen aus Woche 1 und 2, geplant wurde Woche 3). Angepasst
  wurden die Testdaten, nicht die Logik; `slotted` ist jetzt genau 2 statt mindestens 4.
- Hand-Prüfung im Simulator (per vorübergehendem UI-Test):
  - **ChatGPT verbinden:** Karte, Zustimmung, Systemabfrage und echte Anmeldeseite von `auth.openai.com` gehen auf;
    Abbrechen zeigt „Anmeldung abgebrochen.“ Die Anmeldung selbst ist ungeprüft (nur der Inhaber).
  - **Freigabe nachholen:** nicht geprüft. Der Knopf erscheint nur bei verbundenem Konto ohne Freigabe.
  - **Hintergrundlauf:** Der Simulator kann ihn nicht starten: `submitTaskRequest` liefert
    `BGTaskSchedulerErrorDomain` Code 1 („not available on this platform“), danach meldet das Log „No task request …
    has been scheduled“, der Handler wird nie erreicht. Das ist kein Fehler der App. Dafür gibt es jetzt auf der Karte
    den Debug-Knopf „Langen Hintergrundlauf starten (Debug)“ (`perform(.processing)`, derselbe Lauf). Im Simulator
    zeigte die Karte danach „übersprungen: keine gültige Anmeldung“. Der Start durch iOS selbst geht nur am Gerät.
- `CFBundleName` ist jetzt „Studora“, die Systemabfrage nennt im Simulator „Studora“.
- Neu (Entscheidung des Inhabers): `LoginReminder`. Liegt die letzte Anmeldung bei der Hochschule 6 Stunden zurück,
  fragt die App beim Öffnen; sonst kommt eine vorgemerkte Mitteilung am nächsten Termin 8/15/20 Uhr, nur mit
  eingeschaltetem Schalter „Benachrichtigen“. Mitteilung und Frage sind nur in Tests geprüft, nicht von Hand.
- Stand am Ende: Kern 776 ×2 (vor Debug-Knopf und `CFBundleName`), App 564 ×2.
- Hinweise für die nächste Sitzung: `xcode-select` zeigt hier auf die Command Line Tools, darum
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` setzen. Im Lauf mit `test-without-building` fielen die 19
  Kauf-Tests durch, mit `xcodebuild test` waren sie grün; Grund nicht geklärt, darum `xcodebuild test` nehmen.

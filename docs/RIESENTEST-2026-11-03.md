# Riesentest 03./04.11.2026: findet die App immer alles? (synthetische Hochschulen, Python und Swift)

Stand 04.11.2026, Branch `develop`, auf dem Mac des Inhabers (MacBook Pro, 18 Kerne, 48 GB). Frage des Inhabers: Findet
die App immer alles aus Stud.IP (LUH) und QIS sowie aus Learnweb/LSF (Hildesheim), auch wenn sich viele verschiedene
Studierende mit verschiedenen Studiengängen anmelden?

**Harte Regel, eingehalten: keine einzige Anfrage an eine echte Hochschule.** Alles lief gegen *nachgebildete*
Hochschulen (Abschnitt 1). Im Python-Lauf ist jeder Verbindungsaufbau im Prozess gesperrt (`socket.getaddrinfo`,
`urllib.request.urlopen` werfen), die Stud.IP-Adresse heißt `studip.synth.invalid` (die Endung `.invalid` löst nie auf);
im Swift-Kern und in der App antworten nur Transporte aus der Konto-Datei, `URLSession` kommt nicht vor.

---

## 1. Was gebaut wurde

| Werkzeug | Was es tut |
| --- | --- |
| `tools/lasttest-uni-synth.py` | Erzeugt N erfundene Studierende: 75 % LUH (Stud.IP + QIS), 25 % Hildesheim (Learnweb + LSF), 13 Studiengänge (Informatik, Elektrotechnik, Maschinenbau, Mechatronik, Wirtschaftswissenschaften, Lehramt Mathe/Physik, Biomedizintechnik, Informatik mit Nebenfach BWL; Erziehungswissenschaft, Psychologie, Lehramt Grundschule, Wirtschaftsinformatik, Informationsmanagement), je 1–8 Semester, 8–25 Kurse (jedes 37. Konto „schwer“: 60–200 Kurse über 8 Semester wie das echte LUH-Konto), 50–1 500 Dateien je Konto. Je Konto eine JSON-Datei mit allen Antworten je Adresse (Stud.IP JSON:API, Flat-Dateiansicht für den PC, Kalender-ICS, Schwarzes Brett HTML/RSS, QIS-Seiten, Learnweb-REST, LSF-Seiten und iCal) plus die Erwartung („was muss am Ende in der Datenbank stehen“). |
| `tools/riesentest-python.py` | Lässt die **echten** PC-Abgleiche laufen (`studip_sync.run_studip_sync`, `hildesheim.run_sync`) mit einer Playwright-Attrappe, je Konto eigener Datenordner wie im Dienst; prüft danach die Datenbank gegen die Erwartung; `--parallel 8` startet 8 Prozesse. |
| `RiesentestSynthTests` (UniFlowCore) | Derselbe Ablauf im Swift-Kern wie `StudIPSync.perform` in der App (Kurse, Auswahl, Dateilisten, Downloads über `UniDownloads`, Stundenplan `StudIPScheduleStore`, Ergänzungen `StudIPExtras`, Schwarzes Brett, Lerntexte `StudIPTexts`, QIS `QISGradesSync`, Module wie beim nächsten Lesen) bzw. `HildesheimSync`; `RIESENTEST_PARALLEL=8` gleichzeitig. |
| `RiesentestSynthAppTests` (UniFlowTests, Simulator) | Der echte `StudIPSync` der App über den `ContainerManager` (Container, Schlüsselbund, Cookies, Lauf, Zusammenfassung) für 20 LUH-Konten. |
| `tools/riesentest-compare.py` | Zusammenfassung der Läufe und Paritätsvergleich Python ↔ Swift je Konto (gleiche Zahlen, gleiche Modulnamen). |

Was die Nachbildung enthält (je Konto zufällig, aber reproduzierbar mit `--seed`):

- **Kurstitel wie an der LUH**: „Grundlagen der Elektrotechnik I“, „Übung zu …“, „Übung: …“, „Übungen zur …“, „Übung zur Vorlesung …“, „… - Übung“, „… – Gruppenübung Tranche 3“, „Hörsaalübung …“, „Zentralübung …“, „Gruppenübung zu … (Tranche B)“, „Gruppenübungen zu …, Tranche 2“, „Tutorium …“, „Tutorien …“, „… (Tutorium Gruppe 4)“, „Fragestunde …“, „Fragestunde zur Vorlesung …“, „Übung … - Gruppe 7“, „Vorlesung und Übung …“, „12345 …“, „… (für Maschinenbau)“, „… (Vorlesung)“, dazu Praktikum/Seminar/Projektseminar/Labor/Proseminar/Blockseminar als eigene Fächer und „Einführungsveranstaltung Erstsemester …“/„Begrüßung …“ (kein Modul). Learnweb-Titel „WiSe 2026/27: 9072 Einführung in …“.
- **Dateibäume**: Wurzel plus bis zu 6 Unterordner („Vorlesung“, „Übungsblätter“, „Lösungen“, „Woche 1“ …, „Folien (Handout)“), tiefer verschachtelt, ein Ordner mit 620 Dateien (mehrere JSON:API-Seiten), eine Kette 8 Ebenen tief, gesperrte Ordner (403) und entfernte Ordner (404), Ordner ohne Namen; Dateinamen mit Umlauten, zerlegtem Umlaut (NFD), Klammern, doppelten Leerzeichen, Schrägstrich, Punkt am Ende, „.versteckt“, „CON“, 190 Zeichen, Emoji, japanisch, Null-Byte, leerer Name, „x.PDF“; gleicher Name zweimal im selben Ordner und in zwei Ordnern; PDF/PPTX/DOCX/MP4/ZIP/PNG/JPG/XLSX/TXT/PY/IPYNB mit realistischen Größen (MP4 bis 800 MB laut Liste; geliefert wird bis 1 KB, einzelne 2 MB); nicht herunterladbare Dateien, Links („Link/Webadresse“), Änderungszeit als Zahl.
- **Termine**: je Kursslot wöchentliche Einzeltermine über das Semester ohne Weihnachtspause, je aktivem Kurs ein Ausfall (`is-cancelled`) und ein Ersatztermin; Kurszeiten (`seminar-cycle-dates`) und eigene Einträge im Stud.IP-Stundenplan; der eigene Kalender (`events.ics`) mit genau einer Übungsgruppe je Kurs, ein Kurs ganz ohne Kalenderbindung, Konten ohne Kalender (alte Stud.IP-Fassung).
- **Ankündigungen** mit Fristen („Abgabe … bis zum 14.11.2026, 23:59 Uhr“, „… fällt aus“, „Klausur … um 9 Uhr im Hörsaal F 303“, „verlegt“, „Raumwechsel“), 10 000-Zeichen-Text, HTML/Script/Tabellen im Text, leerer Titel; Stud.IP-weite News, Nachrichten (Posteingang), Aktivitäten, Sprechstunden-Buchung, Semester und vorlesungsfreie Zeiten; Courseware-Aufgaben mit Fristen, Courseware-Seiten, Wiki, Forum (30 % der Kurse ohne Forum: 404); Schwarzes Brett (2 Themen, RSS); QIS-Notenspiegel über die Seitenkette der LUH; Learnweb-Kalenderfristen, Ankündigungsforen, verborgene Kurse, Kurs ohne Rechte (Moodle-Exception); LSF-Stundenplan als iCal (BYDAY, EXDATE, Platzhalter-Bemerkung), LSF-Notenspiegel.
- **Störfälle**: 429 auf eine Ordnerliste, 503 auf eine Dateiliste (je einmal, danach ok), Sitzungsablauf mitten im Lauf (nach 40–80 Anfragen nur noch 401), Kurs ohne `start-semester`, Kurs doppelt in der Liste, leerer Kurstitel, Kurs „unbegrenzt“ aus einem alten Semester, kaputtes UTF-8 in einer Ordnerliste, Ergänzungs-Endpunkte 404, Kalender 404, leere Antwort statt Datei, Webseite statt Datei, viele parallele Gruppen.

Geprüft wird je Konto (gleiche Punkte in Python und Swift): alle erwarteten Kurse da; Fach und Art jedes Kurses wie
erwartet; je Fach genau ein Modul, jeder aktive Kurs hängt am Modul seines Fachs; **jede Datei der Nachbildung in der
Datenbank** oder durch eine Regel erklärt (altes Semester, gesperrter Ordner, auf dem iPad: tiefer als 6 Ebenen und
Videos); alle ladbaren Dateien geladen und auf der Platte; keine Datei im falschen Kurs, keine verbotene, keine
überzählige; jede Stundenplan-Serie genau einmal und nur aus aktiven Kursen, Zahl der Serien wie erwartet; alle
Einzeltermine und alle Ausfälle da; jede geplante Frist in den Ankündigungen erkannt (Tag und Art), Courseware-Fristen
in `deadlines`; Semester/Nachrichten/Brett gespeichert; Notenspiegel-Zeilen wie erwartet; Learnweb-Fristen und
-Ankündigungen, LSF-Serien und -Ausfälle, Learnweb-Dateien; `sync_log` ok; kein Absturz, kein „database is locked“,
Lauf im Budget (Python 90 s, Swift 60 s je Konto).

## 2. Was NICHT getestet wurde

- **Keine echte Hochschule** (Regel des Inhabers): kein Abruf bei studip.uni-hannover.de, qis.verwaltung.uni-hannover.de,
  uni-hildesheim.de, lsf.uni-hildesheim.de. Die Nachbildung folgt dem, was die App heute erwartet (JSON:API-Felder,
  Seitenaufbau wie `apps/apple/DebugStub/erststart` und die Fixtures). Weicht das echte Stud.IP davon ab, sieht dieser
  Test es nicht.
- Kein WebSSO/CAS-Login, keine Cookies (die Attrappe gilt immer als angemeldet; Ablauf mitten im Lauf ist nachgestellt).
- Kein echtes Netz: keine Zeitüberschreitungen, kein Wi-Fi-Wechsel, keine großen Downloads (Inhalt bis 1 KB, einzelne 2 MB).
- Keine Playwright-Klickpfade (QIS der LUH am PC, Learnweb-Sitzung ohne Schlüssel): am PC ist nur der Tabellen-Parser
  des Notenspiegels geprüft, auf dem iPad die ganze Seitenkette (`QISClient`).
- Keine Oberfläche (die App-Schicht läuft als XCTest im Simulator, ohne Anzeige), kein Hintergrundlauf (BGTask).
- Kein gemieteter Server: der Dienst (V2) lief in-process (Abschnitt 5), V1 hat keinen Server.
- Opencast-Aufzeichnungen nur als „kein Plugin“ (404), Blubber ist aus.

## 3. Zahlen

Alle Läufe am 03./04.11.2026 auf dem Mac des Inhabers, gleiche Nachbildung (`--seed`), Python = PC-Abgleich,
Swift-Kern = Abgleich wie auf dem iPad, iPad-App = echter `StudIPSync` der App im Simulator.

| Lauf | Konten | ok | Abstürze | „locked“ | Wanduhr s | parallel | RSS MB | je Konto Median s | p95 s | max s | über Budget | Anfragen | Dateien in DB | geladen |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Python | 50 | 50 | 0 | 0 | 9,8 | 1 | 124 | 0,13 | 0,54 | 0,66 | 0 | 22 420 | 14 649 | 14 122 |
| Python | 200 | 199 | 0 | 0 | 30,9 | 1 | 176 | 0,09 | 0,43 | 0,62 | 0 | 83 126 | 50 851 | 48 138 |
| Python | 1 000 | 995 | 0 | 0 | 185,8 | 1 | 198 | 0,11 | 0,48 | 2,54 | 0 | 403 448 | 245 481 | 230 251 |
| Python | 1 000 | 995 | 0 | 0 | 196,5 | 8 | 146 | 0,87 | 3,97 | 12,87 | 0 | 403 448 | 245 481 | 230 251 |
| Swift-Kern | 50 | 50 | 0 | 0 | 26,7 | 1 | 111 | 0,29 | 2,04 | 2,82 | 0 | 21 400 | 14 702 | 13 672 |
| Swift-Kern | 200 | 199 | 0 | 0 | 113,3 | 1 | 158 | 0,28 | 1,89 | 7,97 | 0 | 79 274 | 51 002 | 46 616 |
| Swift-Kern | 1 000 | 995 | 0 | 0 | 844,1 | 1 | 190 | 0,28 | 1,67 | 172,38 | 2 | 383 534 | 246 024 | 223 360 |
| Swift-Kern | 1 000 | 995 | 0 | 0 | 431,0 | 8 | 249 | 0,39 | 2,05 | 84,23 | 15 | 383 534 | 246 024 | 223 360 |
| iPad-App (Simulator) | 20 | 20 | 0 | 0 | 27,5 | 1 | – | 0,76 | 5,46 | 5,46 | 0 | 10 524 | 7 332 | 6 654 |

- **Kein Absturz, kein „database is locked“** in keinem Lauf, auch nicht mit 8 Prozessen.
- **Nicht ok (5 von 1 000, Python und Swift dieselben Konten):** nur Hildesheim, nur `lsf_series_count` (je 1–2 Serien
  weniger als erwartet) und einmal `lsf_cancellations` (4 statt 6). Ursache ist die bekannte Zusammenfassung zweier
  LSF-Veranstaltungen mit gleichem Titel zur gleichen Zeit (Abschnitt 4, Beobachtungen): beide Seiten gleich, die
  Erwartung der Nachbildung zählt sie getrennt. Keine Datei, kein Kurs, keine Frist fehlt.
- **Über Budget (Swift, 60 s je Konto):** nacheinander 2 Konten (126 s und 172 s, beide „huge_tree“ bzw. viele Anfragen
  mit 429-Wiederholungen und `ensure_modules` bei sehr vielen Kursen), mit 8 parallel 15 Konten (Plattenkonkurrenz,
  `downloads` und `hildesheim` steigen). Kein Abbruch, alles vollständig. Auf dem iPad läuft ein Konto allein.
- **Parität Python ↔ Swift (1 000 Konten):** 920 Konten in allen Zahlen und Modulnamen gleich, **0 Konten mit anderen
  Modulnamen**. Die Abweichungen sind alle erklärt (ein Konto kann in zwei Gruppen stehen):
  - 44 Konten mit Sitzungsablauf: das iPad bricht sauber ab (Stundenplan, Termine, Ankündigungen 0), der PC läuft weiter;
  - 27 Konten ohne Kalender: „Vorlesung und Übung X“ mit zwei Kurszeiten wird auf dem iPad zur Gruppenwahl (2 Serien weniger);
  - 10 Konten mit wenigen Courseware-Fristen Unterschied (Budget 200 Anfragen, andere Kursreihenfolge, holt der nächste Lauf nach).
- **iPad-App ↔ PC (20 Konten):** 18 identisch, die 2 Abweichungen sind die Konten mit Sitzungsablauf (Absicht).
- Phasen: am PC dominieren `store_files` (Hash, `commit` mit fsync je Datei) und `downloads`; auf dem iPad `downloads`,
  bei 1 000 Konten nacheinander auch `ensure_modules` (195 s Summe, fast alles in den beiden schweren Konten).

## 4. Gefundene Defekte und was geändert wurde

Alle Änderungen klein, mit Regressionstests (`tests/test_riesentest_regressions.py`, `RiesentestRegressionTests.swift`)
und wo nötig neu erzeugten Paritäts-Fixtures (`fixtures/hildesheim/expected.json`, `fixtures/local-backend/timetable-logic.json`,
`fixtures/local-backend/study-modules.json` für `LocalModulesTests.testClassifyLikePython`).

| Nr. | Befund | Wo | Änderung |
| --- | --- | --- | --- |
| 1 | **Fach-Zuordnung verfehlt gängige LUH-Titel**: „Übung zur Vorlesung X“ und „Fragestunde zur Vorlesung X“ wurden zum Fach „Vorlesung X“ (eigenes Modul neben „X“); „Tutorien X“ bekam Art `vorlesung` statt `tutorium`; „Übung X - Gruppe 7“ wurde Fach „X - Gruppe 7“; „Vorlesung und Übung X“ wurde Fach „und Übung X“ mit Art `uebung`. Folge: ein Fach als zwei bis drei Module, Übungsblätter im falschen Modul. | PC `app/studip_sync.py classify`, iPad `UniRules.classify` | Muster ergänzt: „zur Vorlesung“ nach der Art-Angabe, „Vorlesung und/+/& Übung“ vorne (Art `vorlesung`), „- Gruppe N“ und „(Gruppe N)“ hinten, `Tutori(um|en)`. Fixture-Fälle dazu. |
| 2 | **Prüfungstermin als Raumhinweis**: „Die Klausur findet am 12.02.2027 um 9 Uhr im Hörsaal F 303 statt“ bekam die Art `raum` (Chip „Raum 12.02.“ statt „Prüfung 12.02.“), ebenso „Abgabe im Raum 101 bis zum 12.11.“ → `raum` statt `frist`. | `app/announcements.py KINDS`, `Announcements.swift kinds` | Vorrang: Ausfall, Verlegung, **Frist, Prüfung**, Raum, Online (vorher Raum vor Frist/Prüfung). |
| 3 | **iPad ließ Kurse ohne Startsemester beim ersten Abgleich still weg** (Vorkurse, Dauerveranstaltungen ohne `start-semester`): weder ausgewählt noch als „früheres Semester“ gespeichert; der PC holt sie. Spätere Abgleiche hätten sie von selbst dazugenommen, nur der erste nicht. | `StudIPImport.defaultSelection` | Kurse ohne Startsemester zählen wie das jüngste Semester. |
| 4 | **iPad ließ „unbegrenzt“ laufende Kurse aus alten Semestern still weg** (Endsemester `null`, z. B. Fachschaft, Dauerkurs; ebenso ein zweisemestriger Kurs bis ins laufende Semester): nach der Semesterregel aktuell (der PC holt Dateien, Termine, Ankündigungen), auf dem iPad weder „jüngstes Semester“ noch „früher“ – kein Kurs in der Datenbank, kein Hinweis. In jedem synthetischen LUH-Konto fehlte so genau ein Kurs mit allen Dateien, Terminen, Ausfällen und Fristen. | `StudIPImport.selection`/`defaultSelection`, `StudIPSync` gibt `clock.today` mit | Auswahl nach der Semesterregel (`Semesters.isCurrent == true`, sonst wie bisher jüngstes Semester); später neu belegte Dauerkurse kommen von selbst dazu, abgelaufene nur als Hinweis. |
| 5 | **Einzeltermine zählten als parallele Gruppen** (PC und iPad, ohne Kalender bzw. bei Kursen ohne künftige Kalendertermine): eine Vorlesung mit zwei Serien und einem Nachholtermin galt als „3 parallele Gruppen“ und kam nicht in den Stundenplan; ein Blockseminar aus Einzelterminen ebenso. | `timetable.studip_entries`, `LocalTimetableImport.studipEntries` | Nur wöchentliche Serien zählen für die Gruppenregel; Einzeltermine werden übernommen. Fixture `timetable-logic.json` neu (Blockseminar jetzt übernommen, offene Gruppen 7 → 4). |
| 6 | **Kein zweiter Versuch bei 429/5xx der JSON:API**: ein einzelnes 429 (zu viele Anfragen) auf eine Ordnerliste ließ auf dem iPad den ganzen Kurs für diesen Lauf aus (`affectsOnlyItem`), am PC den Ordner; Downloads und Learnweb hatten die Wiederholung schon. | `StudIPClient.perform`, `UniRetry.isTransient`; PC `studip_sync.api_get` | 429 und 5xx werden bis zu zweimal wiederholt (1,5 s, 3 s), 403/404 nicht; jeder Versuch zählt zur Anfragegrenze. |

Beobachtungen ohne Änderung (bewusst oder nicht schädlich):

- Der PC lädt für nicht herunterladbare Dateien (die Flat-Ansicht kennt `is-downloadable` nicht) bei jedem Abgleich den
  `sendfile.php`-Rückfall und protokolliert einen Download-Fehler; nichts geht verloren, es ist nur Lärm im Protokoll.
- Das iPad liest Ordner nur bis Ebene 6 (`StudIPClient.walk`), der PC alle (Flat-Ansicht): Dateien tiefer als 6 Ebenen
  fehlen auf dem iPad. In der Nachbildung 2 Dateien je betroffenem Konto; in echten Kursen kaum zu erwarten.
- Das iPad lädt Videos in Kursordnern nicht von selbst (`OpencastFileVideos`, Aufzeichnungen auf Wunsch), der PC schon.
- Kaputtes UTF-8 in einer Ordnerliste: am PC fällt nur die Ordnerstruktur dieses Kurses aus (Dateien kommen aus der
  Flat-Ansicht), auf dem iPad der ganze Kurs für diesen Lauf (`badResponse`); nichts wird gelöscht.
- Ein Ersatztermin, der genau im Zeitfenster einer *fremden* Übungsgruppe liegt, lässt am PC diese Gruppe als eigene
  gelten (Einzeltermine werden nach Kurs, Wochentag und Uhrzeit zusammengefasst; das iPad entscheidet je Kurszeit). Sehr
  selten, nur bei identischer Uhrzeit.
- `HildesheimSync` meldet einen Lauf mit einem unlesbaren Learnweb-Kurs als nicht ok (`sync_log.ok = 0`, Kurs in der
  Meldung), der PC als ok mit Protokollzeile. Absicht laut Code; die Zahlen der übrigen Kurse sind gleich.
- Zwei LSF-Veranstaltungen mit gleichem Titel zur gleichen Zeit werden zu einer Serie (Schlüssel ohne Nummer), auf
  beiden Seiten gleich.
- iPad: Übungs-/Tutoriums-/Laborkurse mit zwei Kurszeiten gelten ohne Kalenderentscheidung schon als Gruppen (Absicht,
  Kommentar in `StudIPSchedule.timetable`), der PC erst ab drei. Dazu zählt das iPad die Art aus dem ganzen Titel
  (`StudIPSchedule.titleArt` → `UniRules.eventKind`): ein Kurs „Vorlesung und Übung X“ mit zwei Kurszeiten (Mo Vorlesung,
  Do Übung) wird ohne Kalender als „2 parallele Gruppen“ zur Auswahl gestellt, am PC übernommen. Mit Kalender (Normalfall
  an der LUH) entscheiden beide gleich.
- Lerntexte (Courseware, Wiki, Forum) haben ein Budget von 200 Anfragen je Abgleich; bei Konten mit vielen aktiven
  Kursen reicht es nicht für alle, und weil das iPad die Kurse anders sortiert (jüngstes Semester, Titel absteigend)
  als der PC (Reihenfolge der Kursliste), bekommen beide verschiedene Kurse ab: wenige Courseware-Fristen je Lauf
  unterschiedlich, beim nächsten Abgleich nachgeholt.
- **8 Python-Prozesse parallel sind nicht schneller als einer** (1 000 Konten: 197 s statt 186 s Wanduhr): die Phase
  `store_files` (je Datei Download, Hash, `conn.commit()` mit fsync) stieg von 100 s auf 842 s Summe über alle Prozesse,
  die Platte serialisiert die fsyncs. Betrifft nur den PC-Abgleich mit Downloads (der Dienst streamt Dateien und
  schreibt sie nicht); eine Sammel-Transaktion je Kurs wäre die Abhilfe, wenn es je stören sollte.
- Sitzungsablauf mitten im Lauf: das iPad bricht sauber ab (`needsLogin`, Dateien bis dahin bleiben), der PC läuft mit
  401-Antworten weiter und protokolliert je Teil einen Fehler; beide ohne Absturz, nichts gelöscht.

## 5. Dienst (V2) und Konten

V1 (iPad) hat keinen Server (Anmeldung mit Apple auf dem Gerät), nichts zu messen. Für den gehosteten Dienst wurde
`tools/lasttest-dienst.py` mit 1 000 Konten in-process ausgeführt (kein gemieteter Server, keine Kosten):

Lasttest Dienst (hosted, in-process) – 1000 Konten, 10000 Dateien, Gesamtlaufzeit 157.2 s, RSS 93.5 MB

| Schritt                                   | Anzahl | Median ms | p95 ms | Gesamt s | Bemerkung                                     |
| --- | --- | --- | --- | --- | --- |
| Grundlast GET /api/account/info (ohne DB) | 50     | 2.0       | 3.1    | 0.12     |                                               |
| 1 Registrieren (POST register)            | 1000   | 41.2      | 57.9   | 43.49    | 0 Fehler; Tarife 0.63 s                       |
| 2 init_db je Konto                        | 1000   | 19.4      | 21.2   | 19.66    |                                               |
| 2 10 Dateien einfuegen je Konto           | 1000   | 1.0       | 1.2    | 1.06     | 10000 Dateien                                 |
| 3 Lesen gesamt                            | 6000   | 3.6       | 5.6    | 23.58    | Fehler 0 (0.0 %)                              |
| 3   GET /api/account/me                   | 1000   | 5.3       | 5.8    | 5.37     |                                               |
| 3   GET /api/entitlements                 | 1000   | 3.2       | 3.6    | 3.27     |                                               |
| 3   GET /api/modules                      | 1000   | 3.4       | 3.9    | 3.49     |                                               |
| 3   GET /api/files                        | 1000   | 3.7       | 4.2    | 3.83     |                                               |
| 3   GET /api/dashboard                    | 1000   | 5.4       | 6.0    | 5.43     |                                               |
| 3   GET /api/billing/plans                | 1000   | 2.2       | 2.4    | 2.2      |                                               |
| 4 Notizen Plus (PUT annotations)          | 3000   | 5.0       | 7.2    | 15.83    | Status {200: 3000}                            |
| 4 Notizen Probe (Zusatz)                  | 5000   | 4.9       | 9.6    | 29.22    | Status {200: 5000}                            |
| 4 Notizen Free (erwartet 403)             | 2000   | 5.5       | 8.6    | 11.51    | 403 plan_required: 2000                       |
| 5 jobs.enqueue weekly                     | 1000   | 0.9       |        | 0.9      |                                               |
| 5 jobs.work_once (weekly.tick echt)       | 1000   | 8.6       | 9.6    | 8.73     | 114.5 Jobs/s; {'done': 1000}                  |
| 5 jobs.schedule_due (1 Fenster)           | 1000   | 0.0       |        | 0.01     | zweiter Aufruf: 0 in 0.001 s                  |
| 6 Gleichzeitig 8 Threads                  | 400    | 25.9      | 77.2   | 1.61     | 247.9 Anfr./s; Fehler 0; locked 0 (+0 im Log) |

| Groesse               | Wert                                                                                                                  |
| --- | --- |
| accounts.db (mit WAL) | 1744.0 KB                                                                                                             |
| Zeilen accounts.db    | {"users": 1000, "sessions": 1000, "entitlements": 1000, "sync_jobs": 2000, "rate_limits": 996, "verify_tokens": 1000} |
| Konto-Datenbanken     | 1000 Stueck, zusammen 312.5 MB, je 320.0 KB                                                                           |
| Datenordner gesamt    | 314.52 MB                                                                                                             |
| RSS (ru_maxrss)       | 93.5 MB                                                                                                               |

Alle 6 000 Lese-Anfragen, 10 000 Notizen und 1 000 Wochentest-Jobs ohne Fehler, 0 × „database is locked“ (auch bei 8 Threads);
Registrieren ist mit 41 ms je Konto der teuerste Schritt (Passwort-Hash). Vergleich mit 100 Konten am 30.10.: gleiche
Größenordnung je Anfrage (`docs/LASTTEST-DIENST-2026-10-30.md`), die Konto-Datenbank bleibt 320 KB je Konto. Zahlen eines
Prozesses auf diesem Mac, nicht eines gemieteten Servers (siehe `docs/LASTTEST-PLAN-GROSS.md`).

## 6. Was bleibt

- Der Test gegen die **echten** Hochschulen steht aus und bleibt es, bis der Inhaber ihn ausdrücklich freigibt
  (schonend, lesend, ein Konto, keine Parallelität). Die Nachbildung kann Felder enthalten, die Stud.IP anders liefert.
- Der Lauf im Hintergrund (BGTask, 30 s) und der echte Simulator-Durchlauf mit Oberfläche sind nicht Teil dieses Tests.
- Am PC könnte die Flat-Ansicht durch `is-downloadable` aus der JSON:API ergänzt werden, damit der Rückfall über
  `sendfile.php` entfällt (nur Protokoll-Lärm).
- Ordner tiefer als 6 Ebenen auf dem iPad (siehe Beobachtungen): Grenze anheben oder aus der Flat-Ansicht ergänzen,
  falls so etwas je in echten Kursen auftaucht. **Erledigt 04.11.2026:** Grenze auf 12 Ebenen angehoben, auf beiden
  Seiten gleich (`StudIPClient.maxFolderDepth`, `MAX_FOLDER_DEPTH` in app/studip_sync.py), Schleifenschutz über `seen`
  unverändert; Tests `StudIPRobustReadTests.testFoldersDeeperThanSixLevelsAreReadUpToTheLimit` und
  `tests/test_studip_robust_read.py::test_folder_paths_read_deeper_than_six_levels_up_to_the_limit`.
- Wiederholung: `python tools/lasttest-uni-synth.py --accounts 1000 --out <ordner>`, dann
  `.venv/bin/python tools/riesentest-python.py --dir <ordner> --out py.json --parallel 8`,
  `RIESENTEST_DIR=<ordner> RIESENTEST_OUT=swift.json RIESENTEST_PARALLEL=8 swift test --filter RiesentestSynthTests`
  (in `apps/apple/Packages/UniFlowCore`), für die App
  `TEST_RUNNER_RIESENTEST_DIR=<ordner> TEST_RUNNER_RIESENTEST_OUT=app.json xcodebuild test … -only-testing:UniFlowTests/RiesentestSynthAppTests`,
  danach `python tools/riesentest-compare.py --python py.json --swift swift.json --app app.json --compare py.json swift.json`.

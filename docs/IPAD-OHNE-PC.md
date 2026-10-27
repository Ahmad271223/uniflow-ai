# UniFlow auf dem iPad ohne PC: Stand, Serverabhängigkeiten, Architektur, Reihenfolge

Stand 25.10.2026, `develop`. Vorgabe des Inhabers: Die fertige iPad-App funktioniert für jeden Studenten **ohne PC,
MacBook oder Python-Server**. Stud.IP-Anmeldung, Import und Abgleich laufen auf dem iPad; Dashboard, Module,
Kalender, Lernplanung, PDF-Editor und Suche funktionieren lokal und offline. Der Windows-Server dient nur noch der
Entwicklung und dem Vergleich. Zentrale Onlinedienste nur für Community und Konten, nie der PC des Studenten.
Keine kostenpflichtigen Dienste ohne Zustimmung, keine Änderungen an `main`. Vorrang für Abos und ersten Start hat
`docs/AUFTRAG-APPSTORE-V1.md`.

Grundlage: Codeanalyse mit vier Lesern, Architekturentwurf und Gegenprüfung (25.10.2026). Diese Datei wird nach
jedem Umsetzungsschritt fortgeschrieben (Abschnitt 2 und 7).

## 1. Tarife (Entscheidung vom 25.10.2026)

| | Free (0 €) | Plus (1,99 €/Monat, 1 Woche gratis) |
|---|---|---|
| Stud.IP verbinden und abgleichen, Dokumente öffnen und durchsuchen | ✓ | ✓ |
| Fächer und Module geordnet, Stundenplan | ✓ | ✓ |
| Lernkalender und **Lernplanung** (Lernplan, Lernkombination, freie Zeitfenster, Nachholen, Woche retten) | ✓ | ✓ |
| Zeitmesser, vorhandene Notizen ansehen und als PDF exportieren | ✓ | ✓ |
| **Schreiben mit Apple Pencil**, Seiten einfügen/drehen/Papierkorb, Lesezeichen | – | ✓ |
| **Community** (Lösungen teilen und ansehen) | – | ✓ als Datei (S9) und online über CloudKit (S9b, nur mit Developer Program) |
| Übung und Skript nebeneinander mit Skriptsuche, eigene Karteikarten | – | ✓ |

Pro und alle KI-Funktionen entfallen vorerst. Umgesetzt auf `develop` (Tarifwahl, Berechtigungen, StoreKit-Test).

## 2. Stand heute: was ohne PC läuft

Stand nach **S3** (Zweig `wip/s3-dokumente-3`, nachgebessert in `wip/s3-dokumente-3-fix`; auf den neuen `develop`
gesetzt in `wip/int-s345`, also zusammen mit den Härtetest-Behebungen von „Lösung teilen“ und PDF-Export und der
Hochschul-Regel der Datenbank): Die App startet im lokalen Modus. `session.api` zeigt
auf das lokale Backend (`uniflow-local://device/`, Datenbank seit der Hochschulwahl je Apple-Nutzer und Hochschule
im Container `Application Support/UniFlowContainers/<uuid>/db/uniflow.sqlite`, vorher `Application Support/UniFlow/db/`;
Dateischutz `completeUntilFirstUserAuthentication`, im Backup). Die Datenbank gehört einer Hochschule wie am PC
(`settings.university` = Hochschule des Containers; eine Datenbank einer anderen Uni öffnet sich nicht,
`UniversityMismatch` wie `app/db.py`; Datentrennung: `docs/AUFTRAG-HILDESHEIM-IPAD.md`, Stand iPad). Der Stud.IP-Abgleich der App (`StudIPSync`) schreibt
Kurse und Dateien jetzt wie `app/studip_sync.py` in diese Datenbank (`StudIPLibrary`: gleiche IDs, Felder,
Standardwerte, `sync_log`). Die Dateien erscheinen in **Dokumente & Notizen** (seit dem Zusammenführen mit S4 nach
Fach in Modulordnern, siehe unten; dazu „Neu aus Stud.IP“, Typ-Chips, Suche im Seitenkopf der Bibliothek, Zuletzt,
Favoriten), unter **Meine Module** und auf der **Übersicht** unter „Neu aus Stud.IP“; jede PDF öffnet sich im Editor
und lässt sich mit dem
Apple Pencil beschreiben, **offline** – die Notizen liegen in der lokalen Datenbank (Versionen, Konflikt wie am PC)
und bleiben nach einem Neustart erhalten. Was ein Abgleich vor S3 schon geladen hatte (`index.json`), wird beim
ersten Start übernommen, ohne neu zu laden. Die Statusleiste oberhalb der Seiten zeigt nur noch den Abgleichstand und
Fehler mit „Erneut versuchen“; den Knopf „Stud.IP-Dateien ansehen“ gibt es lokal nicht mehr (StudIPView bleibt in
den Einstellungen erreichbar), und über dem geöffneten Dokument steht weder Karte noch Leiste (der Editor bekommt die
ganze Höhe). Öffnen zählt wie im Web (`POST /api/files/{id}/opened`: „Zuletzt“, gesehen). Wie `run_sync` hält ein
Fehler eines Kurses (z. B. ohne Dateibereich) oder einer Datei den Abgleich nicht an; der nächste Abgleich holt die
Datei nach. Die Kopie der Original-PDF, die der Editor öffnet (`sources/<quelle>/pdf`), und die Vorschaubilder liegen
nicht im iCloud-Backup (Entscheidung 6); „Abmelden und Dateien löschen“ entfernt auch die Kopien des Editors,
Dokumente und Notizen bleiben. Der eigene PC-Server ist nur in Debug-Builds unter Einstellungen → Entwicklung
erreichbar.

Kurse ohne Modul (seit S3, nach dem Zusammenführen mit S4 nur noch Kurse ohne Fach oder mit der Art „sonstiges“, z. B.
eine Begrüßung): Sie sind Ordner in Dokumente (Pfad `c<Kurs-ID>`, alle Dokumente des Kurses ohne Unterordner nach
Art, der Schnellzugriff nennt den Kurs statt „Eigene Notizen“) und stehen in „Meine Module“ als Liste, solange es kein
einziges Modul gibt. Das ist eine bewusste Abweichung vom Web (dort stehen Dateien von Kursen ohne Modul nur unter
„Neu“, „Zuletzt“ und in der Suche); mit eigenem Server bleibt alles wie im Web. Welche Kurse abgeglichen werden, wählt
man lokal in Einstellungen → Stud.IP. Geprüft (S3): App-Tests mit festen, erfundenen Stud.IP-Antworten gegen das lokale Backend
(Abgleich → Dokumente, Kursordner, Kursliste → Editor → Strich speichern → Neustart), dazu im Simulator mit erfundenen
Daten in der lokalen Datenbank: Übersicht und Dokumente „Neu aus Stud.IP“, „Zuletzt“, Kursordner in Dokumente, „Deine
Stud.IP-Kurse“ in Meine Module, Öffnen im Editor ohne Netz. Nicht geprüft: echtes Stud.IP, echtes iPad und Schreiben
mit dem Apple Pencil in der Oberfläche (im Simulator nur per Test auf `DocumentStore`-Ebene).

Stand nach **S4** (Zweig `wip/s4-module-3`, nachgebessert in `wip/s4-module-3-fix`, gebaut auf dem Stand nach S9 ohne
S3 und S5): Fach und Art eines Kurses
(`studip_sync.classify`), Art und Lehrwoche einer Datei (`study.effective_type`, `week_hint`, `enrich_file`) und die
Semesterwochen (`semester_start`, `week_index`, `week_label`; die Lehrwoche einer Datei seit der Abnahme vom 26.10.2026
an einer Stelle, `study.file_week` bzw. `LocalModules.week`, für Moduldetail, Lernplan, Unterlagen zum Termin und
Aufzeichnungen) sind ohne KI nach Swift portiert
(`UniFlowCore/LocalBackend/Study`), dazu `ensure_modules`, `module_detail`, `modules_overview` und alle
Module-Endpunkte. „Meine Module“ und das Moduldetail mit Wochen kommen damit aus der lokalen Datenbank. Geprüft: im Kern
gegen Ausgaben von Python (`study-modules.json`: 59 Kurstitel, 67 Dateien für die Art, 43 für die Lehrwoche,
Semesterwochen an 10 Stichtagen, 44 Anfragen an die Module-Endpunkte auf einer erfundenen Seed-Datenbank mit
denselben Antworten und Tabellen danach); in der App im Simulator mit erfundenen Seed-Daten (Antworten über den
`APIClient` sowie „Meine Module“ und das Moduldetail gezeichnet und per Texterkennung gelesen). Auf einem echten
iPad ist S4 noch nicht geprüft. Wie in Python werden Vorlesung, Übung, Gruppenübung, Tutorium und
Fragestunden eines Fachs ein Modul; eine „Hörsaalübung …“ oder „Zentralübung …“ bleibt ein eigenes Modul (`classify`
entfernt diese Vorsilbe nicht; Entscheidung des Inhabers, Python unverändert). Anlegen und Umordnen gehen über
`POST /api/modules` und `POST /api/courses/{id}/module` (ohne PC seit dem Zusammenführen mit S3 in Einstellungen →
„Module“), ein Modul ändern auch im Moduldetail über „Modul“ (Name, Farbe, Priorität, Klausurtermin). Die Unterlagen zu einem Termin des
Stundenplans (`timetable.materials_for_event`) liefert S4 ebenfalls (`LocalModules.eventMaterials`, gegen Python
geprüft); der Stundenplan aus S5 ruft sie beim Zusammenführen auf. Die Woche eines Termins folgt dabei derselben Regel
wie die einer Datei (zuerst in Python korrigiert, `study.day_week`): Ein Termin zwischen Stichtag und
Vorlesungsbeginn zeigt die Unterlagen „Vor Vorlesungsbeginn“, nicht mehr die des älteren Semesters. Die
KI-Zusammenfassung einer Woche
(„Zusammenfassen“) ist ohne PC ausgeblendet, das Wochenthema bleibt ohne KI-Analyse leer.

Stand nach dem **Zusammenführen von S3 und S4** (Zweig `wip/int-s345-s4`, auf `wip/int-s345`): Der Stud.IP-Abgleich
ordnet jetzt ein. `StudIPLibrary.storeCourses` setzt Fach und Art jedes Kurses mit `StudyClassify.classify` wie
`upsert_course` (nur solange leer, eine Änderung des Nutzers bleibt); beim nächsten Lesen von Bibliothek, Übersicht
oder Modulen legt `ensure_modules` je Fach ein Modul an (`LocalModules.ensureModules`, eine Fassung für alle drei; die
Platzhalter von S3 in `LocalLibrary` sind entfernt, die Einordnung der Dateien kommt aus `StudyClassify.enrichFile`).
Damit stehen echte Stud.IP-Dateien in **Dokumente & Notizen** im Modulordner ihres Fachs mit Unterordnern nach Art
(Vorlesung, Übung, Lösung, Skript, Klausur), in **Meine Module** und im **Moduldetail** nach Lehrwoche. Einstellungen →
**„Module“** gibt es jetzt auch ohne PC (Module mit ihren Kursen, Art und Modul je Kurs, „Ohne Modul“, Modul anlegen,
automatische Zuordnung, aktiv), ohne die Wochentests (keine KI); auf Meine Module führt „Module verwalten“ dorthin.
Geprüft: im Kern gegen Python – `library-files.json` vergleicht jetzt auch `doc_type`, `sub_label` und `week_hint`,
`studip-import.json` läuft mit dem echten `classify` und hat den neuen Teil `classified` (Abgleich mit sieben
erfundenen Kursen, danach `/api/library`, `/api/modules`, `/api/modules/{id}` je Modul und `/api/courses` mit denselben
Antworten und Tabellen wie `app/server.py`, `StudIPLibraryTests.testImportThenModulesMatchPython`); in der App mit
festen, erfundenen Stud.IP-Antworten über `StudIPSync` (`LocalDocumentsAppTests.testSyncSortsDocumentsBySubjectAndWeek`:
ein Modul je Fach, Wochen und Arten im Moduldetail, Kursordner nur für die Begrüßung, eine eigene Zuordnung übersteht
den nächsten Abgleich) und der Reiter „Module“ ohne PC gezeichnet und per Texterkennung gelesen
(`LocalModulesAppTests.testSettingsModulesTabLocally`). Nicht geprüft: echtes Stud.IP, echtes iPad. Wie in Python
stellt `ensure_modules` eine gelöste Zuordnung („– kein Modul –“) eines Kurses mit Fach beim nächsten Lesen wieder
her; dauerhaft ohne Modul bleibt ein Kurs nur ohne Fach oder mit der Art „sonstiges“.

Stand nach **S5** (Zweig `wip/s5-stundenplan-2`, ohne S3/S4): Der **Stundenplan aus Stud.IP** läuft ohne PC. Nach
jedem Datei-Abgleich lädt die App (`StudIPScheduleSync`, ein Aufruf in `StudIPSync`) die Kurszeiten
(`users/{id}/schedule`: seminar-cycle-dates mit Rhythmus, Zeitraum und Ausfällen), die eigenen Einträge
(schedule-entries) und die Einzeltermine der abgeglichenen Kurse (`courses/{id}/events`, alle Seiten) und legt sie in
der Datenbank ab: `studip_events` und `studip_schedule_entries` wie `app/studip_sync.py`, dazu die nur auf dem Gerät
vorhandene Tabelle `studip_cycle_dates` (`StudIPScheduleStore`). Danach übernimmt `auto_import` wie am PC alle
eindeutigen Termine in den Stundenplan; Kurszeiten ersetzen für ihren Kurs die aus Einzelterminen abgeleiteten Serien,
Einzeltermine außerhalb der Kurszeiten (z. B. Klausur, Blocktermin) bleiben wie in Python, Ausfälle laut Stud.IP
werden zu Ausnahmen „Ausfall laut Stud.IP“. Die nur auf dem Gerät vorhandene Tabelle `studip_timetable_links`
(`StudIPScheduleImport`) merkt sich, welcher Stud.IP-Eintrag welche Serie wurde: Ausfälle, die Stud.IP erst später
meldet, kommen bei jedem Abgleich in die vorhandene Serie (auch in die gewählte Gruppe), zurückgenommene entfallen,
Tage, die der Nutzer geändert oder zurückgesetzt hat, bleiben; eine gelöschte oder umbenannte Serie legt der Abgleich
nicht wieder an (zurückholen über die Importvorschau). **Parallele Übungsgruppen** bleiben offen: „Stundenplan
importieren → Aus Stud.IP übernehmen“ zeigt sie wie in der Web-App orange mit „n parallele Gruppen – nur deine Gruppe
auswählen“, die gewählte Gruppe kommt mit ihren Ausfällen dazu (wechselt der Nutzer die Gruppe, entfallen die Ausfälle
der alten). Schon übernommene Termine sind dort aus Stud.IP nicht vorausgewählt, damit „Übernehmen“ eigene Änderungen
(Zeit, Raum, Art) nicht zurücksetzt. Ist aus einer Gruppe gewählt, meldet der Abgleich sie nicht mehr als offen.
Fehler beim Termin-Abruf brechen den Datei-Abgleich nie ab; die Zusammenfassung nennt sie („Kurszeiten nicht geladen“,
„Termine von n Kursen nicht geladen“, bei Netz- oder Zeitlimitfehlern „Stud.IP nicht erreichbar“, danach wird nichts
mehr abgefragt), Nichtgeladenes bleibt wie zuletzt gespeichert. Woche, Tag, Termine anlegen/ändern/löschen (Serie,
ab Datum, einzeln), Teilnahme, Ausnahmen, freie Fenster mit Terminen, Fahrtzeit und Lernslots, Konflikte mit
Lernslots, ICS-Import und die Termine von heute in der Übersicht sind 1:1-Ports von `app/timetable.py` (Antworten exakt
gegen Python geprüft). Import aus PDF, Bild oder Text braucht KI und meldet lokal „KI-Funktionen gibt es in dieser
Version nicht.“ (die Auswahl im Importdialog bleibt bis zur Release-Bereinigung sichtbar). Unterlagen zum Termin
blieben in S5 allein leer (noch keine Dateien mit Einordnung, gefüllt seit dem Zusammenführen mit S3/S4, siehe unten);
Lernslots neu legen (`/api/timetable/reslot`) gehört zu S6. Grenzen: Teilt der Nutzer eine Serie „ab Datum“, bekommt
nur der alte Teil spätere Ausfälle; die Gruppenwahl in der Vorschau ordnet wie in der Web-App über Titel und Wochentag
zu (liegt die Vorlesung desselben Kurses am selben Tag, würde sie ersetzt).

Stand nach dem **Zusammenführen von S3, S4 und S5** (Zweig `wip/int-s345-s5`, auf `wip/int-s345-s4`): Ein
Stud.IP-Abgleich füllt jetzt Dokumente und Stundenplan in einem Lauf. `StudIPSync.run` lädt nach den Downloads den
Stundenplan derselben Kurse (`StudIPScheduleSync` mit demselben lokalen Backend wie der Datei-Abgleich); die
Zusammenfassung nennt beides, `sync_log` wie `run_sync` „n neue/geaenderte Dateien, m Stundenplan-Termine“. Die Kurse
schreibt ein gemeinsamer Weg (`StudIPLibrary.storeCourses`, Fach und Art mit `StudyClassify.classify`, nur solange leer);
der eigene UPSERT von S5 mit der Art aus dem Kurstitel ist entfernt. `auto_import` legt zuerst die Module an
(`ensure_modules`): Vorher bekamen die Termine eines neuen Kurses beim ersten Abgleich kein Modul (das legte erst die
nächste Seite an, und ein späterer Abgleich übernimmt nur neue Termine), damit blieben ihre Unterlagen zum Termin
dauerhaft leer. Zuerst in Python korrigiert (`app/timetable.py`, `tests/test_timetable.py`), dann portiert. Die
Unterlagen zum Termin (`/api/timetable/event-materials/{id}` und die Antwort von `/attendance`) kommen aus
`LocalModules.eventMaterials` (S4), die Semesterwoche dabei aus `StudyWeeks`; „Meine Module“ zeigt den nächsten Termin
eines Moduls (`next_event` aus `LocalTimetable.occurrences`, wie in Python auch heute schon beendete Termine, denn
`modules_overview` vergleicht das Ende mit „00:00“). Für `difflib` gibt es nur noch einen Port (`SequenceMatcher` in
`ModuleGuess`, gegen `study-modules.json` und `timetable-logic.json` geprüft; `PySequenceMatcher` und die zweite
Fassung von `guess_module` sind entfernt). Mit dem Hochschul-Stand von `develop` liest `parse_ics` den Wochentag aus
BYDAY (LSF-Export der Uni Hildesheim, mehrere Tage werden mehrere Serien mit ihren Ausfällen) und liefert `uid` und
`description`; `apply_import` liefert die IDs neuer Serien (`ids`) und legt die Ausfälle selbst an, der LSF-Import am PC
behält dabei seine eigene Notiz „fällt aus laut LSF“. Die Swift-Fassung von `parse_ics` und `apply_import` folgt dem;
geprüft gegen `timetable-logic.json` (neue BYDAY-Fälle) und die Hildesheim-Beispiele
(`packages/shared-contracts/fixtures/hildesheim`). Geprüft im Kern: `timetable-logic.json` hat jetzt Stud.IP-Dateien
in den Modulen, die Unterlagen zum Termin und `GET /api/modules` werden mit Inhalt gegen `app/server.py` verglichen,
`auto_import` auch für einen eben gespeicherten Kurs mit Fach. In der App:
`TimetableLocalAppTests.testStudIPSyncFillsDocumentsTimetableAndEventMaterials` – Abgleich mit festen, erfundenen
Stud.IP-Antworten → Dokumente nach Fach und Lehrwoche → Stundenplan mit Kurszeiten, Ausfall, Einzelterminen (Serie und
Klausur) und eigenem Eintrag → Unterlagen zum Termin über die Endpunkte und im Termin-Panel im Fenster (Texte über den
Bedienungshilfen-Baum) → nächster Termin in „Meine Module“; ein zweiter Abgleich lädt und übernimmt nichts doppelt.
Nicht geprüft: echtes Stud.IP, echtes iPad, Tippen auf einen Termin in der gezeichneten Woche.

Stand nach dem **Abgleich mit der PC-Sitzung** (Zweig `wip/int-s345-py`; Python-Commits 61a9927 und 46ec3d1 auf
`develop`, S3/S4/S5 waren auf dem älteren Python portiert): Jede Änderung in `app/*.py` ist gegen den Swift-Port
geprüft. `parse_ics` (BYDAY, mehrere Tage, EXDATE-Listen) und `apply_import` (`ids`) waren schon nachgezogen. Neu am
Ende von `timetable-logic.json`: eine erfundene Kalenderdatei im Aufbau des LSF-Exports über Vorschau und Übernahme,
die Wochen mit den Ausfällen und ein zweiter Import derselben Datei ohne Doppelte, gegen `app/server.py` verglichen;
`testHildesheimLSFExportInTimetable` prüft die Erwartungen aus `fixtures/hildesheim` im Stundenplan des lokalen
Backends (Donnerstags-Kurs am Donnerstag 29.10. statt am Montag aus DTSTART, Ausfall an Heiligabend, Ausfälle je
Wochentag, jeder genau einmal). In Python prüft `test_lsf_export_cancellations_exactly_once`, dass LSF-Import und
ICS-Import die Ausfälle nur einmal anlegen. `safe_name` macht Dateinamen jetzt NFC, `StudIPImport.safeFileName` ebenso
(gegen `safe_names` in `studip-import.json`); der Name in der Datenbank bleibt wie geliefert. Auf Apple-Systemen
zerlegt Foundation Namen in Datei-URLs ohnehin wieder (gemessen unter macOS: Datei und gespeicherter Pfad sind NFD),
APFS findet beide Formen. Jeder Kurs in eigener Transaktion gilt im iPad-Abgleich schon (Dateiliste je Kurs, jeder
Download einzeln). Den Semesterfilter aus der `.env` gibt es auf dem iPad nicht (Kursauswahl). `university` in
`settings` stammt schon von `develop`. **Nicht nachgezogen**, weil Hildesheim und die Hochschulwahl der Inhaber entscheidet:
`/api/services` ohne `university`, `universities`, `university_next` und `learnweb`, `/api/learnweb/token`, Learnweb
(auch NFC der Datei-IDs), CAS, LSF-Abruf und `lsf.import_plan` (Quelle `lsf`) sowie `qis.parse_grade_rows`. Diese
Funktion ändert am PC auch die LUH-Tabelle: Zeilen ohne Note und ohne Status sowie „Prüfung vorhanden“ ohne Note
fallen weg, und die Spalten „Bezeichnung“ und „Leistung“ gelten als Text. `QISParser.grades` ist dafür nicht
angepasst.

Stand nach dem **Zusammenführen mit dem PC-Kern** (Zweig `wip/v1-pc` auf `develop` bc407b9 mit dem Hildesheim-Kern der
PC-Sitzung in `UniFlowCore/Hildesheim/`): Zu jeder Aufgabe gibt es eine Fassung.
- **Kurse und Dateien**: `UniStore` (`UniStore.swift`) wie `upsert_course` und `store_course_files`, für Stud.IP
  (`StudIPLibrary` enthält nur noch Stud.IP-Eigenes: Zeilen aus der JSON:API, Protokoll, Abmelden, Übernahme von vor
  S3) und Learnweb (`HildesheimSync`). Weil im Kern kein Netz in einer Transaktion läuft, ist `store_course_files`
  aufgeteilt: `storeFiles` → Download → `markDownloaded`. Die S3-Regel „neue Fassung erst mit dem Download“ gilt damit
  auch für Learnweb; `HildesheimSync` legt wie `sync_learnweb` zuerst alle Kurse an und dann je Kurs die Dateien (eine
  unlesbare Dateiliste betrifft nur ihren Kurs). Der Learnweb-Autor wird wie in `files_from_contents` gespeichert.
- **Inhalts-Hash** für gemeinsame Wochentests: `content_sha256` beim Download wie `testshare.file_sha256`
  (`TestShare.contentHash(file:)`, 1-MB-Blöcke über `SolutionSHA256.Hasher`), im selben Schritt wie die neue Fassung;
  in der App außerhalb des Hauptthreads. Die beim Start übernommenen Dateien von vor S3 bleiben ohne Hash (dann liest
  `material_fingerprint` die Datei selbst).
- **Download wie `stream_download`**: eine abgerissene Verbindung oder Zeitüberschreitung wird bis zu zweimal
  wiederholt (`UniRetry`, 1,5 s und 3 s Pause), HTTP-Fehler und Abbruch nicht; kommt eine Webseite statt der Datei,
  wird nichts gespeichert (`UniStore.isWebPage`), bei Stud.IP betrifft das nur diese Datei.
- **Regeln**: `UniRules.classify` (der Port mit `PyRegex` aus S4; `StudyClassify.classify` entfernt),
  `UniRules.kindPattern` (die Art-Muster, auch für `StudIPSchedule`), `UniRules.fileKind` (`StudIPLibrary.fileKind`
  entfernt), `UniRules.eventKind` = `guess_kind` (`StudIPSchedule.guessKind` entfernt, Teilwortsuche nach Codepunkten
  wie Pythons `in`).
- **Stundenplan**: ein Port von `parse_ics` (`LocalTimetableImport.parseICS` mit UTC/TZID und UNTIL mit Uhrzeit);
  `LSFCalendar` liest den LSF-Export darüber, `UniStore.importPlan` folgt `lsf.import_plan` mit `enrich` (Modul
  geraten) und `apply_import` statt eines eigenen INSERT.
- **Python**: Der Konflikt in `store_course_files` ist mit beiden Seiten gelöst (Streaming, Wiederholung und Hash der
  PC-Sitzung; neue Fassung erst mit dem Download aus S3). `test_failed_download_of_new_version_is_retried` prüft jetzt
  auch den Hash. `library-files.json` und `studip-import.json` sind neu erzeugt (`content_sha256`); der Generator
  schreibt Pfade immer mit „/“ (unter Windows entstand „\“).
- Aufgefallen, nicht geändert (Regel für alle Quellen, Entscheidung des Inhabers): `classify("Übung zur X")` ergibt am
  PC und im Port das Fach „r X“, weil `(zu|zur|:)?` zuerst „zu“ trifft.
Geprüft: Kern (`UniStoreTests`, `HildesheimSyncTests`, `HildesheimFixtureTests`, `StudIPLibraryTests` gegen
`studip-import.json` mit Hash), App (`LocalDocumentsAppTests` mit Hash je Fassung), Python. Die dünne
Hildesheim-Schicht der App (URLSession-Transport, Anmeldung, Ablauf, „Uni & Noten“) folgte auf `wip/v1-pc-hi`
(Abschnitt „Uni Hildesheim in der App“ unten).

**Nachbesserung der Zusammenführung** (Zweig `wip/int-s345-fix`): Endet ein Stud.IP-Abgleich auf dem Gerät (fertig,
gescheitert oder mit abgelaufener Sitzung), laden die offenen Seiten neu (`StudIPSync.finishedRuns`, `ufReload`), wie
nach einem Sync des PC-Servers; vorher blieben Übersicht, Dokumente & Notizen, Meine Module und Stundenplan bis zum
nächsten Seitenwechsel auf dem alten (beim ersten Verbinden leeren) Stand. Eine Zeitüberschreitung oder ein
Verbindungsabbruch beim Lesen der Dateiliste eines Kurses überspringt nur diesen Kurs (wie `run_sync` „Fehler bei
Dateiliste“, wie bei den Downloads); vorher endete der ganze Lauf vor dem ersten Download und dem Stundenplan. Läuft die
Sitzung erst beim Stundenplan ab, bleiben die Dateien und `sync_log` meldet den Datei-Abgleich, der Lauf endet aber mit
„Erneut anmelden“ statt still als fertig. Im Kern gibt es Sperrzeiten nur noch in `LocalTimetable.blocked` (die zweite,
von Python abweichende Fassung aus dem Platzhalter ist entfernt), `needle in hay` und `str.strip()` nur noch in `PyText`
und den Python-Wahrheitswert eines JSON-Werts nur noch in `LocalModules.truthy`. Geprüft in der App mit
`testOpenPageReloadsWhenStudIPSyncEnds` (Seite im Fenster, Abgleich mit festen, erfundenen Antworten, Texte über den
Bedienungshilfen-Baum), `testTransportErrorWhileListingOneCourseDoesNotStopTheSync` und
`testSessionExpiringDuringTimetableAsksForLogin`, im Kern mit `testBlockedTimesConvertWeekdayLikePython`.

Stand nach **S6** (Zweig `wip/s6-lernplan-2`, auf `wip/int-s345-py`): Die **Lernlogik läuft ohne PC**. `app/study.py`
ist 1:1 nach Swift portiert (`UniFlowCore/LocalBackend/Study`): `StudyPlan` (Status mit `refresh_statuses`,
`_derive_status`, `set_task_status`; Planung mit `_est`, `_units`, `_module_score`, `generate_packages`, `_next_tasks`,
`_insert_package`, `_recalc_package`; Zeitslots `assign_slots`, `reslot_day`; Uhrzeit von Hand `set_package_time`;
`feasibility`), `StudyCalendar` (`calendar`, `open_tasks`, Paket mit Aufgaben, `dashboard`) und `StudyReschedule`
(`_capacity`, `suggest_reschedule`, `_suggest_text`, `apply_moves`, `move_package`, `rescue_week`, `skip_tasks`). Er nutzt
die Bausteine aus S4/S5 und rechnet nichts doppelt: Semesterwochen aus `StudyWeeks`, Dateien mit Einordnung, Wochenthema
und Module aus `LocalModules`, Termine aus `LocalTimetable.occurrences`, freie Fenster (Termine, Sperrzeiten, Fahrtzeit,
gelegte Lernslots) aus `LocalFreeWindows`. Alle Pfade des Lernkalenders sind echt (`StudyEndpoints`, jede Anfrage eine
Transaktion wie `db.cursor()`): `GET /api/calendar`, `POST /api/calendar/generate`, `GET /api/calendar/feasibility`,
`POST /api/calendar/suggest` und `/apply`, `GET /api/tasks/open`, `POST /api/tasks/skip`, `GET /api/tasks/history`,
`POST /api/tasks/{id}/status`, `PATCH/DELETE /api/tasks/{id}`, `POST /api/packages`, `GET/PATCH/DELETE
/api/packages/{id}`, `POST /api/packages/{id}/tasks`, `POST /api/timetable/reslot` und `GET /api/dashboard` vollständig
(Lernpakete von heute mit Aufgaben, Woche, Module, Nachholen, nächste Termine mit Klausuren, Lernpaketen und
Wochentests; neue Dateien aus S3, Termine und freie Fenster von heute aus S5 unverändert). Die Platzhalter
`PendingStudyEndpoints`, `PendingTimetableEndpoints` und der Übersicht sind entfernt. Im lokalen Modus geht damit:
„+ Lernpaket“ → „Neues Lernpaket“ (Tag, Modul, Titel, Beginn, Dauer), „Plan erstellen“ nach der Lernkombination (Free)
mit den Paketen in den freien Fenstern neben den Terminen, Aufgaben abhaken, bearbeiten, löschen, Pakete verschieben,
„Uhrzeit“, „Neu einplanen“, „Bewusst überspringen“, „Woche retten“, die Übersicht mit den Lernpaketen von heute und
Termine und Lernblöcke im Stundenplan. **Ohne Testaufgaben** (Entscheidung 2): `tests_per_subject` ist in neuen
Datenbanken 0 (`app/db.py` und `Migrations.defaultSettings`); ohne PC bieten Lernkombination (Vorlagen ohne Test und
Wiederholung, keine Felder dafür, gespeichert wird immer 0), „Lernplan erstellen“, „Aufgabe hinzufügen“ und
„Vorlesung nacharbeiten“ in einer freien Zeit keinen Wochentest mehr an, der Untertitel des Lernkalenders nennt keine
Tests. Keine KI-Aufrufe (`/api/tasks/{id}/start-test` bleibt 404 „Wochentests gibt es in dieser Version nicht.“). Mit
eigenem Server bleibt die Oberfläche wie im Web.

Zuerst in Python korrigiert (Entscheidung 1, `tests/test_study_plan.py`, jeder Test scheitert ohne die Korrektur),
dann portiert: `PATCH /api/packages/{id}` speichert die **Uhrzeit** (`start_time`/`end_time`; vorher ignoriert, so
wirkten „Uhrzeit“ und „Beginn (optional)“ weder im Web noch auf dem iPad, Prüfbericht S1); Aufgaben mit Uhrzeit rücken
mit, ohne Ende gilt die geplante Dauer, ein leerer Beginn nimmt die Uhrzeit weg, eine ungültige Uhrzeit gibt 400. Ein
Paket, dessen Aufgaben alle verschoben oder gelöscht sind, bleibt „verschoben“ (vorher machte `refresh_statuses` es
wieder „geplant“: ein leeres Paket belegte sein Zeitfenster und stand unter „Nächste Termine“). „Ersetzen“ beim
Planen löscht nur noch nicht begonnene Pakete (vorher auch solche mit erledigter Aufgabe). Verschieben eines fehlenden
Pakets und Überspringen einer fehlenden Aufgabe geben 404 statt 500 (beim Überspringen bleibt dann nichts halb
geändert). `assign_slots` legt ein Paket **am Stück in das erste freie Fenster**, in dem es Platz hat (vorher begann es
im aktuellen Fenster und endete hinter dem nächsten Termin, z. B. 08:00–13:00 über einer Vorlesung 10:00–11:30; der
Stundenplan meldete einen Konflikt, den „Lernslots neu legen“ nicht lösen konnte, und ein späteres kurzes Paket nutzte
die Lücke davor nicht); passt es in keines, werden seine Aufgaben wie bisher verteilt. Bewusste Abweichungen des
iPads: falsche Datumsangaben (Query, `date`, `start`, `dates`) 422 statt 500; Zeiträume von Kalender und Planung sowie
`horizon` höchstens 3660 Tage (Python kennt keine Grenze); `task_ids` in `suggest` muss eine Liste sein.

Nachgebessert nach der Prüfung von S6 (`wip/s6-lernplan-2-fix`; wieder zuerst in Python mit Tests in
`tests/test_study_plan.py`, die ohne die Korrektur scheitern, dann portiert und im Szenario „nachgebessert“ von
`study-plan.json` verglichen): „Uhrzeit“ kürzt ein Paket nie mehr vor seine letzte Aufgabe (der Dialog schickt Beginn +
geplante Dauer, die keine Pausen zählt; vorher wurde ein gelegtes Paket mit 45 + 30 Minuten 08:00–09:15, die zweite
Aufgabe lief bis 09:30, und das nächste Paket lag darin); Web und App belegen die Dauer mit Ende − Beginn vor. Ein
leeres Paket hat keine Uhrzeit mehr (vorher zeichneten die Raster den leeren Block weiter, und ein neues Paket bekam
dieselbe Uhrzeit) und steht nicht unter „ohne Uhrzeit“. „Ersetzen“ nimmt nur automatisch erstellte, nicht begonnene
Pakete und leere Pakete, tageweise (ein Tag mit begonnenem oder eigenem Paket oder mit neu eingeplanter Aufgabe bleibt
ganz), und nur, wenn es etwas zu planen gibt (vorher verschwanden eigene Pakete aus „+ Lernpaket“ und mit „Woche
retten“ verschobene Aufgaben, auch ohne neue Planung); der Dialog sagt „Automatisch erstellte, noch nicht begonnene
Pakete …“. „Plan erstellen“ plant keine Tage vor heute (die Wochenansicht schlägt den Montag vor; vorher waren die
Pakete von Montag und Dienstag am Mittwoch sofort nachzuholen). „Uhrzeiten vergeben“ in Woche und Tag schickt die Tage
mit und `only_unset` an `POST /api/timetable/reslot`: nur Pakete ohne Uhrzeit bekommen eine, von Hand gesetzte bleiben
(vorher tat der Knopf der Woche nichts, der des Tages legte alle Uhrzeiten neu); „Lernslots neu legen“ bei Konflikten
legt weiter alles neu. Freie Zeit: „Passende Übung“/„Vorlesung nacharbeiten“ bekommt den Beginn des angetippten
Fensters (statt den ganzen Tag neu zu legen), „Lerneinheit automatisch einplanen“ legt ein Paket genau in dieses
Fenster (`window_start`/`window_end` an `POST /api/calendar/generate`, `study.plan_window`, ganze Dateien; vorher „0
Lernpakete erstellt“, sobald am Tag ein Paket lag). Ein verschobenes Paket mit Uhrzeit behält sie, wenn sie am neuen
Tag frei ist, sonst bekommt es ein freies Fenster (vorher konnte es über einer Vorlesung liegen). Nur iPad: der
Geräte-Schritt 1 (`PRAGMA user_version`) setzt `tests_per_subject` einer älteren Datenbank einmal auf 0, „Test
starten“ erscheint ohne PC nicht; `refreshStatuses` liest alle Pakete mit einer Abfrage statt einer je Paket (3000
Pakete mit 9000 Aufgaben, Debug-Build auf dem Mac: Übersicht 0,05 s statt laut Prüfung 1,49 s) und läuft in der
Übersicht nur einmal. Aufgeräumt: die toten Platzhalter-Helfer in `PendingSupport.swift`, der eigene Wochenbeginn der
Übersicht (`StudyWeeks.monday`), doppelte Datums- und Tagesgrenzen-Prüfung (`LocalTimetable.day(status:)`,
`LocalTimetable.span`).

Geprüft im Kern: `study-plan.json` aus `tools/gen-study-fixture.py` – erfundene Seed-Datenbank (Module mit Priorität,
Klausurtermin, ohne Wochentest, eines inaktiv, ein Kurs mit Fach ohne Modul, ein inaktiver Kurs; Stud.IP-Dateien in den
Lehrwochen 0 bis 2, eine am 25.10. in der doppelten Stunde; Analysen mit Dauer, Titel und Themen; Stundenplan mit
Ausnahmen; Lernpakete vergangener Tage; ein Wochentest mit Ergebnis), eingefrorene Uhr Europe/Berlin am Freitag
23.10.2026 mit einem Plan über die Zeitumstellung am Sonntag, später weitergestellt auf Mittwoch 28.10. mit neuen
Dateien; 84 Schritte (Planen, auch mit Wochentest und Wiederholung, ohne Lerntage und ohne offene Unterlagen;
Zeitslots neben Terminen; Uhrzeit von Hand und Konflikt mit „Lernslots neu legen“; Abhaken; Bearbeiten; Verschieben;
Neu einplanen; Woche retten; Überspringen; Verlauf; Machbarkeit mit Hinweisen; Übersicht; Module), danach die Tabellen
`study_packages`, `study_tasks`, `task_history`, `modules` und die Dateien sowie `_derive_status` für alle 64
Kombinationen der Aufgabenstatus, je vergangen und nicht; dazu das Szenario „nachgebessert“ (eigene Datenbank mit
demselben Seed, Mittwoch 28.10., 38 Schritte: freies Fenster, Plan ab Montag, Uhrzeit von Hand, Verschieben mit und
ohne freie Uhrzeit, „Uhrzeiten vergeben“, leeres Paket, Ersetzen mit und ohne etwas zu planen). `LocalStudyPlanTests`
vergleicht jede Antwort und die Tabellen exakt mit `app/server.py`, dazu „Plan
erstellen“ neben Terminen ohne Konflikt und die 422-Fälle. In der App (`StudyPlanLocalAppTests`, Simulator, Bedienung
über den Bedienungshilfen-Baum): im Lernkalender „Lernpaket“ → Dialog „Neues Lernpaket“ → Titel getippt → „Anlegen“
(Paket mit dem ersten Modul in der Datenbank, danach im Lernkalender sichtbar) → im Lernpaket „Als erledigt
markieren“ (Aufgabe und Paket erledigt) → Übersicht „Heute für dich geplant“ mit dem Paket und „1 / 1“; „Plan
erstellen“ → „Erstellen“ legt die Pakete neben Vorlesung, Übung und Fahrtzeit, ohne Konflikt und ohne Testaufgabe, der
Stundenplan zeigt Termine und Lernblöcke; die Lernkombination zeigt keinen Wochentest und speichert 0. Seit der
Nachbesserung außerdem: „Uhrzeiten vergeben“ der Wochenansicht gibt dem ohne Beginn angelegten Paket 08:00–09:00;
„Plan erstellen“ am Mittwoch ab Montag lässt Montag und Dienstag leer, nichts ist nachzuholen; „Lerneinheit
automatisch einplanen“ in der freien Zeit 16:00–18:00 legt dort ein Paket neben ein vorhandenes; „Uhrzeit“ →
„Speichern“ in einem gelegten Paket mit zwei Aufgaben schickt 08:00–09:30 und die Aufgaben bleiben darin; eine
Testaufgabe zeigt ohne PC kein „Test starten“. Nicht geprüft: echtes iPad, Ziehen und Ablegen im Kalender, die
Zeitauswahl „Beginn“ beim Anlegen in der Oberfläche (nur über die Endpunkte), „Passende Übung“/„Vorlesung
nacharbeiten“ in der Oberfläche (nur der Endpunkt), Planen mit echten Stud.IP-Daten.

**S6 auf dem Stand mit dem PC-Kern** (Zweig `wip/v1-s6`: die fünf S6-Commits auf `wip/v1-pc`): Beim Übernehmen
stießen nur die Aufräumarbeiten beider Seiten aneinander – `PendingStudyEndpoints`, `PendingTimetableEndpoints` und
der Übersichts-Platzhalter entfallen mit S6, die übrigen toten Helfer in `PendingSupport.swift` ebenso (die
Nachbesserung der Zusammenführung hatte `LocalPending.blocked` und `truthy` schon entfernt); im Stundenplan-Test
bleiben beide Tests (Sperrzeiten wie Python, kein Platzhalter mehr). S6 nutzt die Bausteine des neuen Stands und
rechnet nichts doppelt: den Python-Wahrheitswert nur aus `LocalModules.truthy` (das entfernte
`LocalTimetable.truthy` und die Weiterleitung `StudyPlan.truthy` gibt es nicht mehr), `a or b` aus
`LocalTimetable.or` auch bei `reslot`, Fach und Art der App-Test-Daten aus `UniRules.classify`. Alle Fixtures sind
mit den Generatoren neu erzeugt und unverändert (`tests_per_subject` 0 aus `app/db.py`), `LocalBackendCoverageTests`
zählt weiter 12 Platzhalter. Geprüft: Kern 330/0 (`swift test`), App 221/0 (`xcodebuild test`, Simulator
C40B7FE0), Python 124 passed, alle Generatoren `--check` aktuell; `StudyPlanLocalAppTests` (7) und
`LocalStudyPlanTests` (7) je dreimal grün. Auf `develop` (Datentrennung, Hochschulwahl, Hildesheim; Zweig
`wip/v1-final`) zählt `LocalBackendCoverageTests` 11 Platzhalter, weil `GET /api/grades` dort schon echt ist; Pakete,
Aufgaben und Einstellungen des Lernplans liegen wie alle Tabellen in der Datenbank des Containers (Apple-Nutzer,
Hochschule), ein Wechsel der Hochschule zeigt den Lernplan der anderen.

Stand nach **S7** (Zweig `wip/v1-s6-s7`, auf `wip/v1-s6`): **Suche und Skriptsuche laufen offline**, und eine **neue
Original-Fassung einer Datei mit Notizen** behält die Notizen.

*Suche und Skriptsuche.* `GET /api/search`, `POST /api/related` und `GET /api/files/{id}/pagetext` sind echt
(`SearchEndpoints`; die Platzhalter sind entfernt, `LocalBackendCoverageTests` zählt jetzt 9, auf `develop` mit
`GET /api/grades` 8). `app/scriptsearch.py`
ist 1:1 portiert (`UniFlowCore/LocalBackend/Search/ScriptSearch.swift`: `normalize` mit zerlegten Umlauten, `tokens`
mit Stoppwörtern und Wortstamm, BM25 mit Mindestgüte und Abstand zum Durchschnitt, Druckfassung derselben Folie nicht
doppelt, `_snippet`, Index je Modul im Zwischenspeicher je Datenbank; Durchschnitt für die Mindestgüte wie
Pythons `sum()` kompensiert über die sortierte Liste, `PyMath.sum`, damit die Schwelle bitgleich ist). Die
Seitentexte stehen wie am PC in `page_texts` (je Datei und Seite mit der Änderungszeit der Datei, dazu die Suchform);
gelesen werden sie auf dem Gerät mit PDFKit (`LocalDocumentTools.pdfPageTexts`, nie auf dem Hauptthread), und zwar
**beim Download** (jede geladene PDF, Stud.IP und Learnweb, schon aus der geladenen Datei vor dem Ersetzen) und **beim
Öffnen** eines Dokuments, das noch keine hat. Zuerst in Python erweitert bzw. korrigiert (`tests/test_search.py`, jeder
Test scheitert ohne seine Änderung): `/api/search` sucht außer in Dateien und Modulen jetzt auch in **Aufgaben des
Lernplans** (`tasks`: Titel, Tag, Modul) und in **Seitentexten** (`pages`: Seite mit Ausschnitt, nur Texte der
aktuellen Fassung von Dateien, die vorhanden sind – nach „Dateien löschen“ kein Treffer, der sich nicht öffnen lässt –,
gelesen wird dabei nichts; `scriptsearch.find_pages`); die Web-App zeigt beides in der Suche der Kopfzeile. Die
Seitensuche vergleicht die **Suchform** (`search_form`: `normalize`, klein, NFC; neue Spalte `page_texts.search`, ältere
Zeilen bekommen sie bei der ersten Suche, ältere Tabellen die Spalte über `ensure_table` bzw. `Migrations`): SQLite
`lower()` und `LIKE` kennen nur ASCII, „übersicht“ fand „Übersicht …“ nicht, und zerlegte Umlaute passten nicht. Die Begriffe eines Treffers der Skriptsuche stehen bei gleicher Häufigkeit in der
Reihenfolge der Anfrage (vorher in der Reihenfolge einer Python-Menge, also je Lauf verschieden – so ließ sich die
Antwort weder vergleichen noch wiederholen). In der App zeigt die Suche der Kopfzeile Module, Dateien, Aufgaben (führt
zur Tagesansicht) und Seiten (öffnet das Dokument an dieser Seite; `#/doc/<id>?page=n` springt jetzt auch auf dem
iPad zur Seite). Bewusste Abweichungen: `/pagetext` liest den gespeicherten Text (am PC jedes Mal neu mit pypdf;
gleiche Antwort), eine unlesbare Datei meldet in `error` einen eigenen Text statt der Meldung von pypdf; ein `text`,
der kein Text ist, und falsche Zahlen in `page` antworten mit 422 statt 500; der Index-Zwischenspeicher gilt auch für
den Ablageort (am PC fehlte eine später geladene Datei bis zum Neustart im Index), je Modul läuft höchstens ein Aufbau
(weitere Anfragen warten darauf), und er endet zwischen zwei Dateien, wenn keine Anfrage mehr wartet; **Seitentreffer
der Suche gibt es auf dem iPad für jede geladene und jede geöffnete PDF** (Übungsblätter, Lösungen, eigene PDFs), am PC
nur für die Vorlesungs- und Skript-PDFs der Module (`index_all` nach dem Abgleich) und für Blätter, zu denen die
Skriptsuche mit `page` lief – gleiche Datenbank, gleiche Antwort, aber auf dem iPad stehen mehr Seitentexte darin.
Grenze: pypdf und PDFKit lesen
denselben PDF-Text nicht immer gleich (Zeilenumbrüche, Ligaturen, zerlegte Umlaute) – darum vergleicht die Fixture mit
festen Seitentexten, und Treffer können am PC und auf dem iPad für dieselbe PDF verschieden ausfallen.

*Neue Original-Fassung mit erhaltenen Notizen.* Python hat dafür **keine Regel** (am PC überschreibt
`store_course_files` die Datei, die Notizen bleiben an den alten Seitenzahlen, neue Seiten fehlen in der
Seitenliste); der Entwurf gilt darum nur auf dem Gerät (`UniFlowCore/FileVersions`):
- **Wann:** Liefert Stud.IP (`StudIPSync`) oder Learnweb (`HildesheimSync`; beide über `UniDownloads`, auf `develop`
  derselbe Weg für jede geladene Datei) für eine Datei eine
  neue Fassung mit anderem Inhalt (`content_sha256` der geladenen Datei ≠ gespeicherter; ohne gespeicherten Hash zählt
  der Inhalt der alten Datei) und hat die Datei **Notizen** (Objekte auf einer Seite, eingefügte, gedrehte,
  umgestellte oder gelöschte Seiten, Lesezeichen, Gliederung, Dokumentnotiz – mehr als die automatische Seitenliste),
  dann vor dem Ersetzen: die alte PDF wird aufbewahrt (`FileVersionKeeper.prepare`, Kopie unter
  `<Container>/StudIP/Fassungen/<Datei>/<Hash>.pdf` bzw. `<Container>/Learnweb/Fassungen/…`, auf APFS ein Klon; ohne iCloud-Backup nach Entscheidung 6;
  **nie gelöscht**, auch nicht von „Abmelden und Dateien löschen“, denn Stud.IP liefert nur noch die neue). Lässt sie
  sich nicht sichern, wird die Datei nicht ersetzt (wie ein gescheiterter Download, der nächste Abgleich versucht es
  erneut). Gleicher Inhalt mit neuem Datum: nichts. **Ohne Notizen** wird ersetzt wie bisher; eine nur automatisch
  angelegte Seitenliste wird dabei geleert, damit der Editor neue Seiten zeigt.
- **Seiten zuordnen** (`PageMatch`, vor dem Ersetzen und außerhalb jeder Transaktion, einmal für Datei und Kopien):
  Seitentexte der alten Fassung (gespeichert in `page_texts` oder mit PDFKit aus der aufbewahrten Kopie) und der neuen
  (aus der geladenen Datei), verglichen als Wörter (normalisiert wie die Skriptsuche, Ziffernfolgen als „#“, damit
  Seitenzahl und Datum in der Fußzeile nicht zählen). 1. gleich (sicher): beide Seitenfolgen ausgerichtet (derselbe
  difflib-Port über die Seiten, `get_matching_blocks`, ohne autojunk); ein gemeinsamer Block zählt, wenn er eine Seite
  enthält, deren Text in beiden Fassungen genau einmal vorkommt; darin sind eindeutige Seiten sicher, mehrfach
  vorkommende („Platz für Notizen“, Gliederung, „Fragen?“, Seiten, die sich nur in Zahlen unterscheiden) nur mit beiden
  Nachbarn im selben Block; eindeutige Seiten außerhalb der Blöcke folgen ihrem Text. 2. wiederholt (zu prüfen): übrige
  mehrfach vorkommende Seiten nach ihrer Lage (gleicher Abstand zur nächsten zugeordneten Seite davor, dann danach).
  Vorher wurden gleiche Seiten nur der Reihe nach vergeben und galten als sicher: kam ein Kapitel mit eigener
  Notizseite dazu, standen die Notizen der folgenden Notizseiten ohne Hinweis eine Notizseite zu früh. 3. ähnlich:
  `SequenceMatcher.ratio()` derselbe difflib-Port wie für die Module (`ModuleGuess`, für beliebige Folgen; Vorfilter
  `real_quick_ratio` aus den Längen und `quick_ratio` aus vorberechneten Häufigkeiten, `ratio()` nur für die fünf
  besten Kandidaten je Seite mit einem Index je neuer Seite) ab 0,6 wie `difflib.get_close_matches`, vergeben nach
  höchster Ähnlichkeit, dann kleinerem Abstand der Seitenzahlen (zu prüfen). 4. Position (zu prüfen): Seiten ohne Text
  (Scans, Leerseiten) im selben Abstand zur nächsten zugeordneten Seite davor oder danach, zuerst auf eine Seite ohne
  Text, dann auch Scan auf Text und umgekehrt. Alles andere ist entfernt (alte Seite) bzw. neu. Ohne lesbaren alten
  Text oder wenn eine Fassung gar keinen Text hat (Scan): Seite für Seite, alle zu prüfen.
- **Notizen umhängen** (`NoteTransfer`, `FileVersionKeeper.commit` nach dem Ersetzen der Datei, **eine Transaktion**
  mit `markDownloaded`, den Seitentexten der neuen Fassung, `file_versions` und den neuen Notizen; endet die App vorher
  oder scheitert ein Schritt, bleibt die Datenbank beim alten Stand, der Abgleich zählt die Datei als nicht geladen,
  und der nächste lädt sie erneut und nimmt die schon aufbewahrte alte PDF): Seiten
  behalten Schlüssel und Inhalt, nur `index` in `pageOrder` und im Papierkorb zeigt auf die neue Seite; **unveränderte
  Seiten 1:1, verschobene folgen ihrem Text**, eingefügte Seiten gehen mit ihrer Seite, neue Seiten bekommen einen
  eigenen Eintrag; ohne eigene Umstellung gilt die Reihenfolge der neuen Fassung, sonst bleibt die des Nutzers.
  **Entfernte Seiten** verschwinden aus dem Dokument, ihre Notizen bleiben **auf der alten Fassung**. Neue Version der
  Notizen mit Verlauf wie `PUT …/annotations`; Herkunftsstempel `origin` (Hash, Seitenzahl, Nummer der Fassung).
  Kopien („Duplizieren“; `UniStore.sharingCopies`: derselbe Ablageort wie die Datei oder nach „Dateien löschen“
  keiner mehr bei gleicher Download-Adresse) bekommen die neue Fassung mit: `markDownloaded` hängt sie an den neuen
  Ablageort (auch bei neuem Dateinamen) mit dem Ladezeitpunkt, ihre Notizen werden ebenso umgehängt, ihre
  Seitentexte verworfen (sie gehören zur alten Fassung).
- **Alte Fassung:** Tabelle `file_versions` (nur auf dem Gerät, bei Bedarf angelegt): Kennzeichen, aufbewahrte PDF,
  Notizen zum Zeitpunkt der neuen Fassung, Zuordnung mit zu prüfenden Seiten. Endpunkte (`FileVersionEndpoints`, am PC
  404): `GET /api/files/{id}/versions` (mit `notice`), `POST …/versions/seen`, `GET …/versions/{n}/content` und
  `…/annotations`; `PUT …/annotations` 409 (nur zum Ansehen). Der Editor öffnet sie unter `<id>/versions/<n>` mit
  eigenem Journal und Zwischenspeicher.
- **Im Dokument:** über der Seite „Neue Fassung aus Stud.IP – Notizen übernommen (n Seiten prüfen)“ (n = Seiten mit
  Notizen, deren Text sich geändert hat, die mit gleichem Text mehrfach vorkommen oder nur nach Position zugeordnet
  sind, und Seiten mit Notizen, die es nur noch in der alten Fassung gibt), darunter welche („Geänderte Seite 4 ·
  Unsicher zugeordnet: Seite 6 · Nur in der alten Fassung: Seite 7“; `check` nennt dazu die Art der Zuordnung), mit
  „Alte Fassung“ (öffnet sie im Vollbild, nur ansehen) und „OK“ (Hinweis gesehen); danach bleiben die alten Fassungen
  unter „Mehr → Alte Fassungen“ erreichbar. **Geteilte Lösungen** hängen am Fingerabdruck der Original-Bytes: eine
  Lösung zur alten Fassung erscheint auf der aufbewahrten alten Fassung (gleiche Bytes), nicht auf der neuen.
- **Editor-Zwischenspeicher** `sources/<quelle>/pdf` wird jetzt erneuert, sobald sich die Datei geändert hat (Stand
  `downloaded_at|content_sha256` aus `GET /api/files/{id}` neben der Kopie; ohne Antwort gilt die Kopie). Kommt eine
  neue Fassung, während das Dokument offen ist, und erreicht der neue Stand der Notizen den Editor (Zusammenführen
  beim Speichern; `SyncEngine` meldet jetzt auch eine Änderung nur der Wurzel), prüft er **zuerst** den
  Herkunftsstempel: andere PDF, also bleibt die Anzeige, wie sie ist (die neue Seitenliste passt nicht zur angezeigten
  PDF), nur noch ansehen mit „Neue Fassung angekommen – Dokument neu öffnen“. Striche, die bis dahin noch auf eine in
  der neuen Fassung entfernte Seite gingen, schreibt `PUT …/annotations` in den Abzug der alten Fassung
  (`FileVersions.keepLateNotes`, solange ein Hinweis offen ist), die Seite steht dann unter „Nur in der alten
  Fassung“.
Grenzen (ehrlich): Seitengrößen werden nicht verglichen (gleicher Text auf anders großer Seite gilt als gleich, die
Notizen stehen dann an denselben Koordinaten); eine Seite, die sich nur in Zahlen unterscheidet und sonst nur einmal
vorkommt, gilt als unverändert (z. B. ein korrigierter Zahlenwert); ob eine mehrfach vorkommende Seite zum Kapitel
davor oder danach gehört, lässt sich am Text nicht erkennen (bei Gleichstand gilt die Seite davor, die Zuordnung ist zu
prüfen); nach „Dateien löschen“ findet sich eine Learnweb-Kopie nicht mehr, wenn sich die Download-Adresse mit der
neuen Fassung ändert (Revision in der Adresse; eine Kopie verweist sonst nirgends auf ihr Original); späte Striche in
der alten Fassung sieht eine schon einmal geöffnete alte Fassung erst nach dem Leeren ihres Journals (ihre Version
bleibt 1); die Seitentexte liegen wie am PC in der Datenbank und damit im Backup (Entscheidung 6 sieht sie außerhalb
vor – offen: eigene Zwischenspeicher-Datenbank ohne Backup). Beim Learnweb-Abgleich greift dasselbe über
`UniDownloads` (die App gibt `HildesheimSync` PDFKit als `tools`).

Geprüft im Kern: `search.json` aus dem neuen `tools/gen-search-fixture.py` (erfundene Module, Kurse, Dateien mit PDFs
aus festen Zeilen, die pypdf liest, Analysen, Lernpakete; `page_texts` genau mit dem Text von pypdf): 42 Anfragen an
die drei Endpunkte (Suche mit Groß-/Kleinschreibung, Umlauten wie SQLite, `%%`, zu kurz, fehlend; Skriptsuche mit
Text und Seite, Mindestgüte, Druckfassung, gekürztem Text, ohne Modul, ohne Skripte; Seitentext mit allen
Grenzfällen) mit exakt denselben Antworten wie `app/server.py`, `tokens`, `normalize` und `_snippet` für erfundene
Texte (`LocalSearchTests`), dazu Lesen mit PDFKit nur einmal und neu bei neuer Fassung; Seitenzuordnung, Umhängen,
alte Fassung, Kopien, Endpunkte (`PageMatchTests`, `NoteTransferTests`, `FileVersionKeeperTests`) und der
Learnweb-Abgleich mit neuer Fassung (`testNewLearnwebVersionKeepsOldVersionAndMovesNotes`). In der App
(`NewVersionSearchAppTests`, Simulator, feste erfundene Stud.IP-Antworten, PDFs mit UIKit erzeugt, PDFKit liest die
Seitentexte): Datei mit Strichen auf Seite 2 und 3 bekommt eine neue Fassung mit eingefügter Folie und geänderter
letzter Seite → Striche auf Seite 3 und 4, Editor zeigt die neue PDF, der Hinweis nennt „1 Seite prüfen“ und „Geänderte
Seite 4“, die alte Fassung öffnet sich mit den alten Notizen, eine Lösung zur alten Fassung erscheint nur dort, nach
„Dateien löschen“ bleibt sie; ohne Notizen einfach ersetzt; im Fenster (Bedienungshilfen-Baum) Hinweis, „Alte
Fassung“ (3 Seiten, „Alte Fassung – nur ansehen“), „Schließen“, „OK“; Suche findet den Text einer Seite offline, die
Kopfzeile zeigt „… · Seite 2“ mit Sprung zur Seite und eine Aufgabe mit Weg zur Tagesansicht. Kern 349/0, App 225/0,
Python 126 passed, alle Generatoren `--check` aktuell; die neuen Tests je dreimal grün. Nicht geprüft: echtes Stud.IP,
echtes iPad, echte Vorlesungsfolien (Text aus PDFKit großer Skripte, Laufzeit), Learnweb in der App.

S7 nachgebessert (Zweig `wip/v1-s6-fix`, Befunde der Prüfung): gleiche Seiten (Notiz-, Gliederungs-, „Fragen?“-Seiten,
Seiten nur mit anderen Zahlen) werden über die Ausrichtung der Seitenfolgen und ihre Nachbarn zugeordnet und sind
sonst zu prüfen (`testRepeatedNotesPagesFollowTheirChapter`, `testPagesDifferingOnlyInNumbersAreChecked`,
`testRepeatedNotesPagesKeepTheirChapterThroughKeeper`); Scan in einer Fassung: Seite für Seite statt alles entfernt
(`testScannedVersionMapsByPosition`, `testScannedNewVersionKeepsNotesByPosition`); Zuordnung vor dem Ersetzen und
außerhalb der Transaktion, einmal für alle Kopien, Vorfilter ohne Index je Paar (150 Seiten zu 250 Wörtern im
Debug-Build 0,7 s, `testLargeScriptMatchesQuickly`); `markDownloaded`, Seitentexte, alte Fassung und Notizen in einer
Transaktion, Abbruch und Fehler heilen mit dem nächsten Abgleich (`testInterruptedOrFailedCommitHealsWithNextSync`);
Kopien bei neuem Dateinamen und nach „Dateien löschen“ (`testRenamedNewVersionMovesCopyAlong`,
`testCopyAfterForgetDownloadsGetsNotesMoved`), ohne alte Seitentexte (`testCopyDropsStalePageTexts`); offenes
Dokument behält seine Anzeige, späte Striche auf entfernten Seiten kommen zur alten Fassung
(`testLateStrokesOnRemovedPageGoToOldVersion`, `testRootOnlyChangeIsReported`, in der App
`testNewVersionWhileOpenKeepsDisplayAndLateStrokesReachOldVersion`, `testNoticeSeparatesChangedFromUnsurePages`);
Skriptsuche mit Pythons `sum()` (`testPythonSumIsCompensated`), Index je Modul einmal und abbrechbar
(`testIndexBuildIsSharedAndStopsWhenNobodyWaits`), `normalize` ohne zerlegte Umlaute sofort zurück; Seitensuche mit
Suchform und nur für vorhandene Dateien zuerst in Python (`tests/test_search.py`: drei neue Tests, ohne die Änderung
rot), `search.json` mit 47 Anfragen und `search_form`; `s[a:b]` und `str.find` nur noch in `PyText`
(`testCodepointSliceAndFind`). Kern 365/0, App 227/0 (zweimal nacheinander), Python 129 passed, alle Generatoren
`--check` aktuell, die betroffenen Tests je dreimal grün. Nicht geprüft: echtes Stud.IP, echtes iPad, große echte
Skripte mit PDFKit.

Stand nach dem **Port vom PC-Stand 26.10.2026** (Zweig `wip/port-ferien`, auf `develop` 9ccca68; die drei als
`XCTExpectFailure` festgehaltenen Abweichungen aus dem Zusammenführen sind damit nachgezogen, nur die G2-Sync-Spalten
bleiben eine erwartete Abweichung). **Nachgezogen** (1:1 aus Python, nichts doppelt):
- **Feiertage und vorlesungsfreie Zeit** (`app/holidays.py` → `Holidays`): Ostern, Feiertage Niedersachsen, `SEMESTERS`
  je Hochschule mit Pausen (die eine Tabelle, `Migrations.defaultTerm` liest sie), `day_marks`, `default_term`,
  `lecture_free`, `calendar_extras`. `occurrences` lässt Serien ohne eigenen Zeitraum (Uni-Arten) an Feiertagen, in
  Pausen und in der vorlesungsfreien Zeit ausfallen (`exception` „vorlesungsfrei“ mit `note`, Hochschule aus
  `settings.university`); Bemerkungen aus `event_notes` stehen als `note`; `apply_import` löscht `event_notes` mit
  der Serie. `merge_weekly` mit 14-Tage-Schritt und `exdates` war schon nachgezogen; `auto_import` trägt die Ausfälle
  bestehender Stud.IP-Serien über die Verknüpfung (`StudIPScheduleImport.refresh`) nach.
- **Fristen und Ankündigungen**: `week_grid`, `calendar` und `dashboard` liefern je Tag `marks`, `deadlines` und
  `notices`, die Übersicht `upcoming` mit Frist-Einträgen (überfällige der letzten 6 Wochen zuerst, `deadline_id`,
  `url`) und `announcements`; `GET /api/deadlines`, `GET /api/announcements` wie `server.py`. Learnweb
  (`LearnwebDeadlines.swift`, `LearnwebAPI.deadlines`/`.announcements`): `deadline_kind`, `local_iso`,
  `short_deadline_title`, `deadlines_from_events`, beide Kalender-Quellen seitenweise, Ankündigungsforen mit Schlüssel
  (REST) und mit der Sitzung (Forumsseiten, bekannte Diskussionen nicht erneut); `HildesheimSync` nach den Dateien
  wie `run_sync` (`store_deadlines`, `sync_announcements`; ein Fehler dort stoppt den Lauf nicht, nach „kein Kurs
  lesbar“ wird nichts mehr gefragt). `Announcements` (`app/announcements.py`): `html_to_text`, `extract_dates`,
  Forumsseiten-Parser mit der Tiefe von Pythons `HTMLParser` (der `HTMLTokenizer` kennt dafür selbstschließende Tags),
  `make`/`from_*`, `store`, `known_discussions`, `recent`, `by_day`. Stud.IP: `courses/{id}/news` je Kurs im
  Stundenplan-Abruf (`StudIPScheduleStore`), Ablage wie `announcements.store` mit `course_ids`. LSF: `note_text`,
  `is_placeholder`, `event_notes`, Platzhalter einmalig „nicht besuchen“ (`PlanResult.placeholders`).
- **Oberfläche** wie `views-tt.js`/`views-plan.js`/`app.js`: Legende „Feiertag / vorlesungsfrei“, „Frist (Learnweb)“,
  „Hinweis aus Ankündigung“; grüne Tage und Chips (`UFDayExtraChips`) im Stundenplan, im Lernkalender (Woche, Monat,
  Tag, Mini-Kalender mit roten und blauen Punkten); in der Übersicht Fristen unter „Nächste Termine“ (Tippen öffnet
  nur http/https) und die Karte „Ankündigungen“ (aufklappbar, Link ins Learnweb bzw. Stud.IP). Die Spalten der
  Übersicht folgen `.grid > * { min-width: 0 }` (PC-Korrektur vom 26.10.): die rechte bleibt ein Drittel, lange
  Titel kürzen mit „…“ statt die linke Spalte schmal zu drücken.
- **Vertrag pageOrder** (`merge.js` → `AnnotationMerge.mergeDocument`, `mergePageOrder`, `mergeTrash`,
  `mergeField`): Seiten bleiben wie `mergePage`; Reihenfolge nur einer Seite gilt, beide verträglich → eingefügte
  Seiten hinter ihrem Vorgänger (Server zuerst), beide verschieden → dieses Gerät, `orderConflict` und ein Konflikt;
  Papierkorb vereinigt; Felder nach der Feldregel (fehlend und null gleich wie `same()`). `SyncEngine` gibt
  `mergeRootMeta` die Seiten vor dem Abgleich mit und meldet `SyncIssue.seitenreihenfolge` („Seitenreihenfolge auf
  beiden Geräten geändert – die Reihenfolge dieses Geräts gilt“, `SyncIssueBadge` mit „Verstanden“). Die 18
  `documentCases` aus `cases.json` laufen in `SharedFixtureTests`; doppelte IDs, lokal gewinnt und v2 ohne
  Signaturvergleich sind unverändert.
Geprüft: Kern 478 Tests grün (G2-Spalten als erwartete Abweichung), Fixtures mit allen `tools/gen-*.py` neu erzeugt
und `--check` grün (nur `app-paths.json` bekam die Quelle `CommunityCloudKit.swift` dazu), Python 291 grün, App
voll zweimal hintereinander grün (318 Tests, 1 übersprungen). Aufgefallen, nicht geändert:
`HardeningSolutionEditorTests.testManyForeignLayersStayFastAndAreReleased` misst die Zeit für „eine von 30 Ebenen
ausblenden“ gegen 1,5 s und lag unter Last zweimal knapp darüber (1,52 s und 1,64 s); allein und abwechselnd mit dem
Stand vor dem Port (9ccca68) gleich schnell, der Editor ist hier unverändert. Fixture-Tests gegen `fixtures/hildesheim/expected.json` (`learnweb-deadlines`, `deadline-kinds`,
`deadline-titles`, `local-iso`, `nds-holidays`, `day-marks`, `announcement-dates`, `forum-discussion`, `forum-view`,
`forum-announcement`, `lsf-notes`), Abgleichstests mit erfundenen Antworten (zweiter Lauf ohne Doppelte), Stud.IP-News
mit Löschen je gelesenem Kurs, Endpunkte wie der Server, Reihenfolge-Konflikt im `SyncEngine`. **Nicht geprüft**: mit
echtem Learnweb/Stud.IP (Fristen und Foren), die Chips auf einem echten iPad.

| Bereich | Stand | Was fehlt |
|---|---|---|
| Lokales Backend (Router, Transport-Weiche) | **fertig (S2)**, alle App-Pfade beantwortet (seit S7 80); **S3**: Bibliothek, Kurse, Dateien, Datei-Inhalt, Notizen, Bilder, Ordner, Notizbücher echt; **S4**: Module echt; **S5**: Stundenplan echt; **S6**: Lernkalender, Pakete, Aufgaben, `reslot`, Übersicht echt; **S7**: Suche, Skriptsuche, Seitentext, alte Fassungen echt | Karteikarten, Uni & Noten, Hintergrund (8 Platzhalter); **M8**: Karteikarten echt, übrig Uni & Noten und Hintergrund (5 Platzhalter) |
| Einstellungen (Lernzeit, Lernkombination, Verfügbarkeit), Semester | **lokal echt (S2)**: `GET/PUT /api/settings` (mit `university` und `university_next` wie `server.py`; `PUT` prüft `university`, schreibt es aber nie), `GET/PUT /api/terms` | Hochschule wählen und wechseln auf dem iPad (`docs/AUFTRAG-HILDESHEIM-IPAD.md`) |
| Stud.IP-Abgleich in die Datenbank | **lokal echt (S3)**: Kurse (Titel, Nummer, Semester; Fach und Art mit `classify` seit dem Zusammenführen mit S4, nur solange leer), Dateien (Name, Größe, Typ, Änderungszeit, Ordnerpfad, Art pdf/image/file, Status „neu“), Downloads mit Pfad **relativ zum App-Container**, `sync_log`; idempotent, Nutzerfelder (Status, gesehen, Favorit, Ordner, Titel) und Notizen bleiben; umbenannte Dateien behalten ihre ID, in Stud.IP gelöschte bleiben stehen (wie Python); Fehler eines Kurses oder einer Datei (HTTP, unerwartete Antwort, beim Lesen der Dateiliste auch Zeitüberschreitung und Verbindungsabbruch) überspringen nur diese wie in Python, ist kein Kurs lesbar, gilt der Lauf als gescheitert; nach jedem Lauf laden die offenen Seiten neu; eine neue Fassung (Größe, Typ, Änderungszeit) gilt erst mit ihrem Download – scheitert er oder bricht der Lauf vorher ab, lädt der nächste Abgleich sie (in `app/studip_sync.py` ebenso korrigiert, in `store_course_files`, das am PC auch der Learnweb-Abgleich für Hildesheim nutzt; Test in `tests/test_regressions.py`); Downloads gehen direkt in eine Datei (nicht in den Arbeitsspeicher), eine abgerissene Verbindung wird bis zu zweimal wiederholt, danach überspringt eine Zeitüberschreitung nur diese Datei, eine Webseite statt der Datei wird nicht gespeichert; Inhalts-Hash `content_sha256` je geladener Fassung; geschrieben über `UniStore`, dieselbe Fassung wie für Learnweb; gegen `run_sync` geprüft (`studip-import.json`, 6 Durchgänge, dazu `classified` mit Modulen danach) | `author` (die JSON:API liefert keinen Namen); große Dateien werden immer automatisch geladen (Entscheidung „über 100 MB nur auf Wunsch“ noch ohne Oberfläche; eine Datei, die länger als 10 Minuten lädt, scheitert bei jedem Abgleich erneut, hält die übrigen aber nicht auf); kein ETag/If-Modified-Since; kein Netz und abgelaufene Sitzung brechen den Lauf ab (schon gelesene Kurse und geladene Dateien bleiben gespeichert; läuft die Sitzung erst beim Stundenplan ab, endet der Lauf mit „Erneut anmelden“); alte Datei bleibt nach Umbenennen liegen (wie Python); abgewählte Kurse bleiben mit ihren Dateien in Dokumente (ausblenden über `courses.active` noch ohne Oberfläche) |
| Notizen beim Wechsel PC ↔ lokal | **getrennt (S2)**, **lokal gespeichert (S3)**: Journal und PDF-Zwischenspeicher je Datenquelle, Notizen lokal in `annotations`/`annotation_versions` | Übernahme vom PC (Entwicklung) |
| Erster Start (Mit Apple anmelden, Tarifwahl, Konto löschen) | **nativ fertig** (echte Apple-Anmeldung braucht das Developer Program) | – |
| Stud.IP-Anmeldung auf der echten Seite, Sitzung im Schlüsselbund, Ablauf erkennen | **nativ fertig** | Navigationsgrenzen und Fehlermeldungen in der Webansicht; Logout beendet die Sitzung nicht beim Server; stilles Erneuern; OAuth2 (Freigabe LUH) |
| Dokumente & Notizen | **lokal echt (S3)**: `GET /api/library`, Kursordner je Stud.IP-Kurs ohne Modul, Ordner anlegen/umbenennen/löschen, Notizbuch/Whiteboard anlegen, eigene PDF und Bilder importieren (Ablage `<Container>/files/Eigene Dokumente`, im Backup; Bild → PDF-Seite mit UIKit), Titel, Ordner, Papierkorb, Wiederherstellen, Duplizieren (Kopien von Stud.IP-Dateien teilen sich deren Datei und öffnen sich nach „Abmelden und Dateien löschen“ und dem nächsten Abgleich wieder mit ihren Notizen), endgültig löschen (nur eigene; entfernt auch die PDF-Kopie des Editors, das Journal und die Vorschaubilder auf dem Gerät); **S4**: Modulordner je Fach mit Unterordnern nach Art, Einordnung `doc_type`/`sub_label`/`week_hint` wie `study.enrich_file` (gegen Python verglichen) | Prüfung auf einem echten iPad |
| Übersicht | **lokal echt (S6)**: `/api/dashboard` wie `study.dashboard` – Lernpakete von heute mit Aufgaben, Woche, Module, Nachholen, nächste Termine; „Neu aus Stud.IP“ (`new_files`, `new_total`), „Gesehen“ (`mark-seen`), letzter Abgleich (S3); Termine und freie Fenster von heute (S5); seit dem Port vom PC-Stand 26.10. Learnweb-Fristen in „Nächste Termine“ (überfällige zuerst, Link nur http/https) und die Karte „Ankündigungen“ (`announcements`), `GET /api/deadlines`, `GET /api/announcements` | Prüfung auf einem echten iPad |
| Abgaben & Prüfungen (erkannt) | **nur auf dem Gerät, lokal echt**: Kurzklausuren, Kurztests, Testate, Abgaben, Assignments, Klausuren und Anmeldefristen aus den Seitentexten der PDFs (`page_texts`), Dateinamen und Ankündigungen (Stud.IP-News, Learnweb-Foren) ohne KI (`DueDetection`): Schlüsselwort und Datum nah beieinander (Satz bzw. Tabellenzeile; Überschrift mit Unterpunkten wie „◼ Kurzklausurtermin“ / „❑ Datum: …“; Testate im Semesterplan mit Spalte „Testate“: „T1: … 16.11 bis 19.11.“ am ersten Tag, Ende in der Bezeichnung), englisch klein „test“ nur mit Prüfungsbezug, Zeitraum nach „Klausuren“/„Prüfungen“ kein Klausurtag (mit Anmeldung davor: Anmeldung bis zum Ende), Jahr aus dem laufenden Semester (`Holidays`, `terms`), alte Semester und Dokumente mit anderem Semester im Kopf fallen weg; Tabellen `due_hits`, `due_choices`, `due_meta` bei Bedarf angelegt, neu nach jedem Abgleich und beim Lesen neuer Seitentexte, PDFs ohne Seitentexte (vor S7 geladen) werden nach dem Abgleich nachgelesen; gleiche Termine (Modul, Tag, Art) zusammengeführt, Learnweb-Fristen und Klausurtermine des Moduls nicht doppelt. Anzeige als Frist-Chip im Lernkalender und Stundenplan, unter „Nächste Termine“, Liste „Abgaben & Prüfungen“ auf der Übersicht und im Moduldetail („in N Tagen“, „erkannt in Datei, S. n“, Antippen öffnet die PDF-Seite bzw. Ankündigung); „Stimmt nicht“ bleibt gemerkt, bestätigen, Uhrzeit ändern. Erinnerungen (Einstellungen, Vorgabe aus, Erlaubnis erst beim Einschalten): 3 Tage, 1 Tag, Morgen 8:00, mit Uhrzeit 2 Stunden vorher, höchstens 60, Kennungen je Container | mit echten Dateien prüfen, ob Treffer fehlen oder falsch sind; Hintergrundabgleich (S8) plant noch nicht selbst neu |
| Einordnung ohne KI: Fach, Art, Lehrwoche, Semesterwochen | **Kern fertig (S4)**: `UniRules.classify` (seit dem Zusammenführen mit dem PC-Kern die eine Fassung für alle Quellen), `StudyClassify.effectiveType`/`weekHint`, `StudyWeeks` (Stichtag und Woche 0 zuerst in Python korrigiert), `ModuleGuess` (`timetable.guess_module` mit `difflib`, seit dem Zusammenführen mit S5 die einzige Fassung, auch für den Stundenplan-Import); Regeln wie Pythons `re` (`PyRegex`: `\b`, `\w`, `\s`, `re.I` Zeichen für Zeichen, nicht wie ICU); **angebunden**: `classify` beim Stud.IP-Abgleich (`StudIPLibrary.classify`), `enrichFile` in Bibliothek und Moduldetail | Vorsilbe „Hörsaalübung“/„Zentralübung“ bleibt im Fach (wie Python, Entscheidung des Inhabers) |
| Module und Kurse | **Kursliste echt (S3)**: `GET /api/courses` (in „Meine Module“ als „Deine Stud.IP-Kurse“, solange es kein Modul gibt), `PATCH /api/courses/{id}` (Art in Einstellungen → „Module“; Fach, aktiv, Testminuten ohne Oberfläche); **Module lokal echt (S4)**: `GET/POST /api/modules`, `GET/PATCH/DELETE /api/modules/{id}`, `POST /api/modules/auto-assign`, `POST /api/courses/{id}/module`; gleiche Antworten und Tabellen wie Python auf einer Seed-Datenbank; Seiten „Meine Module“ und Moduldetail im Simulator mit Seed-Daten geprüft, mit Daten aus dem Stud.IP-Abgleich im App-Test; Einstellungen → „Module“ ohne PC (Anlegen, Zuordnen, automatische Zuordnung, ohne Wochentests); KI-Zusammenfassung der Woche ohne PC ausgeblendet; **nächster Termin** `next_event` aus dem Stundenplan seit dem Zusammenführen mit S5 | Wochenthema bleibt ohne KI-Analyse leer; Prüfung auf einem echten iPad (Module in der Übersicht seit S6) |
| Aufzeichnungen (Opencast) | **lokal echt (Opencast)**, nur an Hochschulen mit Stud.IP (LUH): Abruf im Stud.IP-Abgleich nach dem Stundenplan, je gewähltem Kurs die Seite `media/index` (Pausen und Anfragegrenze der JSON:API; Kurse ohne Plugin – HTTP 500 „navigation item … not found“ – sind kein Fehler und werden erst nach 7 Tagen erneut gefragt; ein Fehler überspringt nur seinen Kurs; Anmeldeseite = „Erneut anmelden“; „kein Opencast“ über den Kursüberblick nur, wenn die Antwort sicher der Kursüberblick des Kurses ist – eine Zwischenseite mit HTTP 200 zählt als nicht lesbar –, und ein Kurs mit Reiter wird nur durch die ausdrückliche Meldung des Plugins zu „kein Opencast“), Ablage in der Datenbank des Containers (`opencast_courses`, `opencast_videos`, nur auf dem Gerät, bei Bedarf angelegt wie `studip_cycle_dates`); geordnet nach Fach (Modul des Kurses) und Lehrwoche mit denselben Regeln und Beschriftungen wie die Dokumente im Moduldetail (`LocalModules.week`, `StudyWeeks`, `StudyClassify.enrichFile`; Datum und Uhrzeit im Titel zählen nicht als Nummer, auch „06.11“, „06/11/2026“, „2026_11_06“, „6. November“, „08.15 Uhr“); Bereich „Aufzeichnungen“ im Moduldetail mit Hinweis „N Aufzeichnungen“ in den Wochenblöcken, Kurse ohne Modul unter „Meine Module“; Abspielen im App-Player (AVPlayer, Stream 720p bzw. geladene Datei, Qualität wählbar, gemerkte Stelle in der Datenbank), Ersatzweg Stud.IP-Player-Seite in der Webansicht; Laden nur auf Wunsch (Entscheidung 7: über 100 MB oder unbekannte Größe nur nach ausdrücklicher Bestätigung, Platz geprüft), Ablage `<Container>/StudIP/Aufzeichnungen` ohne Backup (kein Download in einen gelöschten Container, „Daten dieser Hochschule löschen“ hält laufende Downloads an), Abbrechen/Fortsetzen in der Fassung des abgebrochenen Downloads, auch nach einem Neustart (veraltete Fortsetzungsdaten werden verworfen; antwortet der Videoserver nicht oder mit einem Fehler, kommt eine Meldung statt der Rückfrage), „Dateien löschen“ entfernt auch die Videos; „Passende Aufzeichnung“ im Dokument und im Lernpaket nur bei sicherem Treffer (gleiches Fach und gleiche Lehrwoche bei Vorlesung, Übung, Lösung und Skript oder ein eindeutiges Thema aus dem Videotitel ohne Wörter einer Art wie „Exercise“, „Großübung“; Organisatorisches nie) | am Gerät prüfen: Streaming ohne Anmeldung am Opencast-Host, Größe per HEAD, Player-Seite in der Webansicht; Themenwörter ohne Wortstamm-Kürzung (die Skriptsuche aus S7 kann sie später ersetzen) |
| Kurszeiten (seminar-cycle-dates) | **lokal echt (S5)**: Abruf nach dem Datei-Abgleich, Ablage `studip_cycle_dates`, Übernahme mit Rhythmus, Zeitraum und Ausfällen; Gruppenauswahl in der Importvorschau wie in der Web-App | Rhythmen außer wöchentlich/zweiwöchentlich nur mit Hinweis „bitte prüfen“ |
| Einzeltermine (course-events) | **lokal echt (S5)**: Swift-Abruf (`StudIPClient.courseEvents`, alle Seiten, abgesagte ohne), Ablage `studip_events`; ein Fehler je Kurs lässt dessen alte Termine stehen | – |
| QIS (Noten) | **Kern fertig** (Parser), nicht angebunden | Webansicht, Ablage, Anzeige |
| Stundenplan | **lokal echt (S5)**: alle `/api/timetable/*` (Woche, Tag, Termine, Ausnahmen, Teilnahme, freie Fenster, Unterlagen, ICS- und Stud.IP-Import, Konflikte, Auto-Status), heutige Termine und freie Fenster in der Übersicht; ICS mit UTC/TZID/EXDATE (Korrektur zuerst in Python, `tests/test_timetable.py`) und BYDAY (LSF); **Unterlagen zum Termin** aus den Stud.IP-Dateien des Moduls seit dem Zusammenführen mit S3/S4; Lernslots neu legen (`reslot`) seit S6 | KI-Import entfällt |
| Lernkalender | **lokal echt (S6)**: Kalender, Lernpakete anlegen/verschieben/löschen, Uhrzeit, Aufgaben abhaken/bearbeiten/löschen/überspringen, Plan erstellen nach der Lernkombination mit Zeitslots in den freien Fenstern, Machbarkeit, Neu einplanen, Woche retten, Verlauf; ohne Wochentests (`tests_per_subject` 0, keine KI); gegen Python geprüft (`study-plan.json`), in der App mit erfundenen Daten im Simulator | Ziehen und Ablegen im Kalender und echtes iPad nicht geprüft |
| PDF-Editor mit Apple Pencil | **lokal echt (S3)**: Original aus dem Stud.IP-Abgleich oder Import über `/api/files/{id}/content` (Bytes der lokalen Datei, Kopfzeilen wie `server.py`), Notizen über `/api/files/{id}/annotations` lokal mit `base_version`-Konflikt und 30 Versionen; offline; „Lösung teilen“ nutzt die unveränderten Original-Bytes (`DocumentStore.originalPDFURL`, geprüft); **S7**: Skriptsuche und Seitentext lokal, neue Original-Fassung mit erhaltenen Notizen, PDF-Zwischenspeicher wird nach einer neuen Fassung erneuert | der PDF-Zwischenspeicher `sources/<quelle>/pdf` (seit S3 ohne Backup) ist eine zweite vollständige Kopie der Datei (je Duplikat eine weitere; ein APFS-Klon statt der Kopie fehlt, das Schreiben läuft abseits des Hauptthreads); Seitengröße beim Zuordnen einer neuen Fassung nicht verglichen |
| Suche, Skriptsuche | **lokal echt (S7)**: `/api/search` (Dateien, Module, Aufgaben, Seitentexte; zuerst in Python erweitert), `/api/related` (Port von `scriptsearch.py`), `/api/files/{id}/pagetext`; Seitentexte mit PDFKit in `page_texts`, gefüllt beim Download und beim Öffnen; gegen Python geprüft (`search.json`) | Seitentexte im Backup der Datenbank (Entscheidung 6: außerhalb); pypdf und PDFKit lesen Text nicht immer gleich |
| Geänderte Original-PDF bei vorhandenen Notizen | **lokal echt (S7)**: alte PDF aufbewahrt (nie gelöscht), Seiten über den Seitentext neu zugeordnet (`PageMatch`, difflib-Port), Notizen umgehängt, entfernte Seiten auf der alten Fassung, Hinweis im Dokument mit Weg zur alten Fassung, Kopien mit; Stud.IP in der App, Learnweb im Kern (`HildesheimSync`, `versions`) | Learnweb in der App (Hildesheim-Schicht); Seitengröße nicht verglichen; echtes iPad |
| Hintergrundabgleich | **lokal (S8, Zweig `wip/s8-hintergrund`)**: kurzer Lauf `BGAppRefreshTask` (neue Kurse, Dateilisten, Stundenplan; keine Downloads, keine Aufzeichnungen, keine Noten) und langer `BGProcessingTask` mit Netz (wie beim Öffnen, also auch neue Dateien laden), beide frühestens zum nächsten Zeitpunkt 8, 15 oder 20 Uhr Ortszeit, neu geplant beim Start, beim Wechsel in den Hintergrund und nach jedem Lauf (ein schon bestellter, nicht späterer Termin bleibt stehen); nur auf dem Container des angemeldeten Nutzers und der gewählten Hochschule, nicht während eines Wechsels oder der Einrichtung, nie neben einem laufenden Abgleich; nur mit gültiger Sitzung (nie eine Anmeldeseite, nie gemerkte Zugangsdaten; abgelaufen: einmal „Bitte bei Stud.IP anmelden“); Ablauf der Zeit bricht sauber ab (halbe Dateien nie sichtbar); Mitteilung „N neue Dateien aus Stud.IP/Learnweb“ ohne Dateinamen, Erlaubnis erst über den Schalter; Karte „Im Hintergrund abgleichen“ in den Einstellungen mit dem letzten Hintergrundlauf | am Gerät prüfen: wann iOS die Aufgaben wirklich startet (mehrere Tage protokollieren), wie lange die Stud.IP-Sitzung hält, Learnweb bei gesperrtem iPad (Schlüssel nur entsperrt lesbar), Mitteilungen auf dem Sperrbildschirm; Ankündigungen sind auf dem iPad noch nicht portiert |
| Zeitmesser | **nativ fertig** | Mitteilung bei Ablauf im Hintergrund |
| Community „Lösungen teilen“ | **lokal fertig (S9, Zweig `wip/loesung-teilen`)**: im Editor „Lösung teilen …“ (nur eigene Notizen, verschlüsseltes Paket `*.uniflowsolution`, Vorschau ohne Original), Import über „Öffnen in“/„Lösung importieren …“, Anzeige als eigene, nicht bearbeitbare Ebene über der eigenen PDF, „Meine geteilten Lösungen“; PDF-Export davon getrennt und nur privat. **Online programmiert (S9b, Zweig `wip/community-cloudkit`)**: `CloudKitCommunityService` hinter `CommunityService` (öffentliche CloudKit-Datenbank, Container `iCloud.de.uniflow.ai`): veröffentlichen mit Sichtbarkeit Modul (Kurs-Schlüssel aus `files.course_id`) / Lerngruppe (Beitrittscode, QR) / anonym, Treffer im Dokument („n Lösungen aus der Community zu diesem Blatt“, Laden und anzeigen über denselben Importweg), Bereich „Community“ im Moduldetail nach Lehrwoche, Zurückziehen, Melden, Blockieren, Pseudonym und Sperrliste in den Einstellungen (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 7) | **nur mit Developer Program**: iCloud-Container anlegen, `Config/Team.xcconfig` mit `UF_CLOUDKIT_CONTAINER`, Schema/Indizes im CloudKit Dashboard, echte Läufe im Simulator; ohne Team meldet die App „Community nicht verfügbar“. Die Berechtigung ist nur so stark wie die Kenntnis der Kurs-ID (kein signierter Beleg der Hochschule); Moderation der Meldungen (Inhaber) |

Tarife (seit der Nachbesserung von S3 auch durchgesetzt, vorher griff die Plus-Sperre nirgends): Lesen, Öffnen,
Durchsuchen, vorhandene Notizen ansehen und als PDF exportieren sind Free, ebenso PDF- und Bild-Import zum Lesen. Mit
Free (und nach dem Herabstufen) ist der Editor nur zum Ansehen: der Stift schreibt nicht, Text, Seiten einfügen,
drehen, Papierkorb, Lesezeichen und Rückgängig sind gesperrt; ein Schloss „Schreiben (Plus)“ in der Leiste und
„Nur ansehen – Schreiben mit Plus“ unten führen zur Sperrkarte mit „Mit Plus freischalten“. Ebenso gesperrt (Schloss):
Notizbuch und Whiteboard anlegen im Dialog „Neu“ und die geteilte Ansicht „Übung und Skript nebeneinander“. Beim
Herabstufen wird ein eben gezeichneter Strich noch gesichert, danach nichts mehr (auch nicht über Rückgängig des
Systems); die Notizen bleiben vollständig erhalten (`PDFEditorController.canEdit`, `DocumentStore.canEdit` aus
`UFFeatureMatrix.notes(plan:)`, `PlusWritingLockTests`). Die Sperre sitzt in der App; das lokale Backend kennt keinen
Tarif. Im Simulator angesehen (Free, erfundenes Dokument): Hinweis unten und Schloss der geteilten Ansicht in der
Leiste; nicht angesehen: Schloss im Dialog „Neu“ und die Sperrkarte selbst.

## 3. Serverabhängigkeiten

Die iPad-App ruft **80 verschiedene Endpunkte** auf (Methode + Pfad, Liste per grep über `apps/apple/UniFlow` in
`packages/shared-contracts/fixtures/local-backend/app-paths.json`, erzeugt mit `tools/gen-local-backend-fixture.py`;
neu seit S3: `POST /api/files/{id}/opened` beim Öffnen eines Dokuments wie im Web, für „Zuletzt“ und „gesehen“; neu
seit S7: `GET /api/files/{id}` (Stand des PDF-Zwischenspeichers), `GET /api/files/{id}/versions` und
`POST …/versions/seen`).
Das lokale Backend beantwortet **jeden** davon (`LocalBackendCoverageTests`):

- **echt lokal (S2):** `GET/PUT /api/settings`, `GET/PUT /api/terms`; freie Zeitfenster in `/api/timetable/week`,
  `/api/timetable/day` und `today.free` von `/api/dashboard` (Port von `timetable.free_windows`, seit S5 mit Terminen,
  Fahrtzeit und Lernslots, `LocalFreeWindowsTests` gegen `timetable-free.json`); die feste Dienste-Liste in `GET /api/services`
  (`SERVICES` aus `app/server.py`, exakt verglichen).
- **echt lokal (S3), Antworten wie `app/server.py` bei gleicher Datenbank** (`LocalLibraryFixtureTests` gegen
  `library-files.json`, 114 Anfragen samt Tabellen und Dateien danach): `GET /api/library` (mit
  `ensure_modules`), `GET /api/courses`, `PATCH /api/courses/{id}`, `GET /api/files`, `GET/PATCH /api/files/{id}`,
  `GET /api/files/{id}/content`, `GET/PUT /api/files/{id}/annotations`, `GET .../annotations/versions`,
  `POST .../annotations/restore/{v}`, `POST /api/files/{id}/assets`, `GET /api/assets/{id}/{name}`,
  `POST /api/files/mark-seen`, `POST /api/files/{id}/opened`, `POST /api/files/{id}/favorite`,
  `POST/PATCH/DELETE /api/folders`, `POST /api/notebooks`, `PATCH /api/library/files/{id}`, `GET /api/sync/status`
  (Protokoll der Abgleiche auf dem Gerät); in `/api/dashboard` `new_files`, `new_total`, `last_sync`.
  Die Einordnung der Dateien (`doc_type`, `sub_label`, `week_hint`) wird seit dem Zusammenführen mit S4 mit
  verglichen. Bewusste Abweichungen: Notizen für ein Dokument, das es lokal nicht
  gibt, antworten mit 409 ohne `version` statt 500 (die App behält sie im Journal); falsche Zahlen 422 statt 500;
  `local_path` relativ zum App-Container statt absolut. In `app/server.py` korrigiert (zuerst in Python, Test in
  `tests/test_regressions.py`): „Endgültig löschen“ einer Kopie löschte die gemeinsame PDF-Datei des Originals.
- **echt lokal (S4):** die Module: `GET/POST /api/modules`, `GET/PATCH/DELETE /api/modules/{id}`,
  `POST /api/modules/auto-assign`, `POST /api/courses/{id}/module` (`ModulesEndpoints`, `LocalModulesEndpointTests`
  gegen `study-modules.json`; nach einem Abgleich mit erfundenen Stud.IP-Daten `classified` in `studip-import.json`).
- **echt lokal (S5), Antworten wie `app/server.py` bei gleicher Datenbank** (`LocalTimetableTests` gegen
  `timetable-logic.json` aus `tools/gen-timetable-fixture.py`: knapp 50 Anfragen mit eingefrorener Uhr am Tag der
  Zeitumstellung, Tabellen danach, ICS-Fälle, `auto_import`): `GET /api/timetable/week`, `/day`, `/events`, `/free`,
  `/conflicts`, `/auto-status`, `/event-materials/{id}`, `POST/PATCH/DELETE /api/timetable/events`,
  `POST /api/timetable/attendance`, `/exceptions`, `/import/preview` (Quellen `studip` und `ics`), `/import/confirm`;
  `today.events`/`today.free` in `/api/dashboard`. Stud.IP-Abruf und Ablage: `StudIPScheduleStoreTests` (Kern) und
  `TimetableLocalAppTests` (App) mit erfundenen JSON:API-Antworten (`fixtures/studip-schedule`). Bewusste
  Abweichungen: Import aus `pdf`, `image`, `text` antwortet nach den Prüfungen von Python (400 „PDF fehlt“, „Bild
  fehlt“, „Nur Bilddateien“) mit 404 „KI-Funktionen gibt es in dieser Version nicht.“; falsche Datumsangaben in der
  Query 422 statt 500; `conflicts?days=` höchstens 3660; auf dem Gerät ersetzen
  Kurszeiten die aus Einzelterminen abgeleiteten Serien ihres Kurses (ohne Kurszeiten genau wie Python), und ein
  vollständig geladener Kurs ersetzt seine gespeicherten Einzeltermine (Python lässt veraltete stehen); der Abgleich
  nutzt die Verknüpfung `studip_timetable_links` (siehe oben), und `/auto-status` zählt Gruppen aus Kurszeiten nicht
  mehr, aus denen schon eine Kurszeit im Stundenplan steht (ohne Kurszeiten wie Python). In `app/timetable.py`
  korrigiert (zuerst in Python, `tests/test_timetable.py`): ICS-Zeiten mit „Z“ (UTC) und `TZID` werden in Berliner
  Ortszeit umgerechnet, `EXDATE` und `UNTIL` mit Uhrzeit werden beachtet, Ausfälle werden beim Import zu Ausnahmen,
  ein erneuter Import einer vorhandenen Serie entfernt nicht mehr gemeldete Ausfälle derselben Quelle; `tzdata` steht
  fest in `requirements.txt` (Windows hat keine Zeitzonendatenbank, `TZID=America/New_York` wäre sonst Berliner Zeit;
  auf dem PC einmal `pip install -r requirements.txt`).
- **echt lokal (S6), Antworten wie `app/server.py` bei gleicher Datenbank** (`LocalStudyPlanTests` gegen
  `study-plan.json` aus `tools/gen-study-fixture.py`: 84 Schritte mit eingefrorener, weitergestellter Uhr über die
  Zeitumstellung, Tabellen danach): `GET /api/calendar`, `POST /api/calendar/generate`, `GET /api/calendar/feasibility`,
  `POST /api/calendar/suggest`, `POST /api/calendar/apply`, `GET /api/tasks/open`, `POST /api/tasks/skip`,
  `GET /api/tasks/history`, `POST /api/tasks/{id}/status`, `PATCH/DELETE /api/tasks/{id}`, `POST /api/packages`,
  `GET/PATCH/DELETE /api/packages/{id}`, `POST /api/packages/{id}/tasks`, `POST /api/timetable/reslot`,
  `GET /api/dashboard` (vollständig). Bewusste Abweichungen: falsche Datumsangaben 422 statt 500, Zeiträume und
  `horizon` höchstens 3660 Tage. In `app/study.py` und `app/server.py` korrigiert (zuerst in Python,
  `tests/test_study_plan.py`): Uhrzeit von Lernpaketen gespeichert, leere Pakete bleiben „verschoben“, Ersetzen behält
  begonnene Pakete, 404 statt 500 für fehlendes Paket/fehlende Aufgabe, Pakete am Stück im ersten freien Fenster;
  `tests_per_subject` Standard 0.
- **echt lokal (S7), Antworten wie `app/server.py` bei gleicher Datenbank** (`LocalSearchTests` gegen `search.json`
  aus `tools/gen-search-fixture.py`, 42 Anfragen mit festen Seitentexten): `GET /api/search` (mit `tasks` und `pages`,
  zuerst in Python ergänzt), `POST /api/related`, `GET /api/files/{id}/pagetext`. Nur auf dem Gerät (am PC 404):
  `GET /api/files/{id}/versions`, `POST …/versions/seen`, `GET …/versions/{n}/content`, `GET/PUT …/versions/{n}/annotations`
  (alte Original-Fassungen, siehe Abschnitt 2). `GET /api/files/{id}` ruft die App jetzt auch selbst auf (Stand des
  PDF-Zwischenspeichers).
- **Platzhalter in Server-Form** bis zur Portierung (leere Listen bzw. Objekte mit denselben Feldern wie
  `app/server.py` bei leerer Datenbank): Uni & Noten (außer `GET /api/grades`, seit `wip/v1-pc-hi` der Port von
  `qis.summary`), `/api/bg` – 5 Pfade der App (Karteikarten seit M8 echt, `FlashcardEndpoints`). Einträge nach ID gibt es dort noch nicht (404 wie am PC). Ein
  echter Endpunkt ersetzt den Platzhalter automatisch (`LocalRoute.placeholder`).
- **bewusst entfallen:** KI (`/api/ai/tutor`), Wochentests (`/api/tests/*` außer der leeren Liste,
  `/api/tasks/{id}/start-test`), Zugänge (`PUT /api/credentials/*`; `GET` liefert „kein Zugang“): 404 mit Meldung.
  QIS-Abruf (`/api/grades/sync`) 404 „kommt in einer späteren Version“, `/api/sync` 409 (Stud.IP gleicht die App
  direkt ab).

Die Seiten „Tests & Wiederholung“ und „Uni & Noten“ zeigen lokal weiter den leeren Zustand (keine KI, QIS folgt);
an der Uni Hildesheim zeigt „Uni & Noten“ seit `wip/v1-pc-hi` den Notenspiegel aus dem LSF (nur die Leistungstabelle).

| Bereich | Endpunkte | Ziel | Stand |
|---|---|---|---|
| Übersicht, Dateien als gesehen | `/api/dashboard`, `/api/files/mark-seen` | lokal (Free) | **lokal (S6)**; neue Dateien und `mark-seen` seit S3, Termine von heute seit S5 |
| Module und Kurse | `/api/modules*`, `/api/courses*` (9) | lokal (Free) | Kurse lokal (S3), **Module lokal (S4)** |
| Bibliothek, Ordner, Notizbücher, Favoriten | `/api/library*`, `/api/folders*`, `/api/notebooks`, `/api/files/{id}/favorite` (7) | lokal (Free; Notizbücher Plus) | **lokal (S3)** |
| Datei-Inhalt und Notizen | `/api/files/{id}/content`, `/annotations` (GET/PUT, Versionen), `/assets` | lokal (Lesen Free, Schreiben Plus) | **lokal (S3)** |
| Lernkalender, Pakete, Aufgaben, Zeitfenster | `/api/calendar*`, `/api/tasks*`, `/api/packages*`, `/api/timetable/reslot` (16) | lokal (Free) | **lokal (S6)** |
| Stundenplan, Termine, Import, Konflikte | `/api/timetable/*` (12) | lokal (Free) | **lokal (S5)**, `reslot` seit S6 |
| Einstellungen, Semester | `/api/settings`, `/api/terms` | lokal | **lokal (S2)** |
| Suche, Skriptsuche | `/api/search`, `/api/related`, `/api/files/{id}/pagetext` | lokal | **lokal (S7)** |
| Alte Original-Fassungen | `/api/files/{id}/versions*` | nur auf dem Gerät | **lokal (S7)** |
| Abgaben & Prüfungen (erkannt), Erinnerungen | `/api/due`, `/api/due/refresh`, `/api/due/backfill`, `/api/due/{id}` | nur auf dem Gerät | **lokal**; erkannte Termine auch in `/api/calendar`, `/api/timetable/week`, `/api/dashboard`, `/api/deadlines` |
| Abgleich und Status | `/api/sync`, `/api/sync/status`, `/api/bg` | lokal als Stud.IP-Abgleich | Abgleich in der App (S3), Protokoll lokal |
| Karteikarten | `/api/flashcards*` (4) | lokal (Plus), eigenes Anlegen ohne KI | **lokal (M8)**: Liste mit `file_id`/`due`, Anlegen, Leitner-Bewertung, Löschen wie `app/server.py` (`flashcards.json`, `tools/gen-flashcards-fixture.py`); Seite „Karteikarten“ statt „Tests & Wiederholung“ |
| Uni & Noten | `/api/services`, `/api/grades*`, `/api/qis/*` | Dienste-Liste lokal; QIS auf dem Gerät (später) | Dienste lokal, `GET /api/grades` lokal (Hildesheim: LSF-Notenspiegel über `HildesheimSync`), QIS (LUH) offen |
| Zugänge | `/api/credentials*` | entfällt (keine Passwörter in der App) | entfallen |
| Tests, KI | `/api/tests*`, `/api/ai/tutor`, `/api/tasks/{id}/start-test` | entfällt (keine KI) | entfallen |
| Community, Konto | – | CloudKit (öffentliche Datenbank, S9b; Konto = iCloud auf dem iPad) | Lösung als Datei (S9); online programmiert, echter Lauf erst mit Developer Program |

**Was nach S3 bis S7 ohne PC noch nicht geht** (ehrlich): Wochentests (KI, entfallen) und die Übernahme der Notizen
und Pläne vom PC. Karteikarten und QIS-Noten der LUH gibt es auf dem Gerät; der Hintergrundabgleich S8 ist
programmiert, am Gerät noch nicht beobachtet. Keiner dieser Punkte braucht im
App-Store-Betrieb einen PC; sie sind nur noch nicht portiert. Die Uni Hildesheim (Learnweb, LSF, CAS) läuft seit
`wip/v1-pc-hi` auf dem iPad; ein Test mit einem echten Konto steht noch aus.

**Uni Hildesheim in der App** (Zweig `wip/v1-pc-hi`, Einzelheiten in `docs/AUFTRAG-HILDESHEIM-IPAD.md`, Abschnitt
„Hildesheim in der App“): Der Abgleich ist die Fassung des Kerns (`HildesheimSync`), die App liefert nur Transport
(`URLSessionUniTransport`, Cookies aus dem Datenspeicher der Webansicht des Containers), Anmeldung (CAS im WKWebView,
nur vorausfüllen; Learnweb-Schlüssel aus dem Moodle-SSO im Schlüsselbund) und Ablauf (`HildesheimConnection`: beim
Öffnen höchstens alle 30 Minuten, auf Knopfdruck, Noten höchstens alle 20 Stunden). Die Seiten lesen dieselben
Tabellen wie für Stud.IP: Learnweb-Dateien in Dokumente & Notizen und Module (`files.local_path` = `Learnweb/files/…`
relativ zum Container), LSF-Serien im Stundenplan (vorlesungsfreie Tage als Ausfall), Leistungen unter „Uni & Noten“.
Statt „Stud.IP verbinden“ stehen die Karten „Learnweb verbinden“/„LSF verbinden“ und danach die Statusleiste
(„Learnweb: 16:30 ok“, „LSF: Anmeldung nötig“) über den Seiten und auf der Übersicht. Geprüft ohne Netz: App-Tests mit
`URLProtocol`-Stub und lokalen Seiten (`HildesheimAppTests`), Kern- und Python-Tests. Seit S7 (auf `develop` in
`wip/v1-final`) laufen Seitentexte und neue Fassungen beim Learnweb-Abgleich über denselben Weg wie bei Stud.IP
(`UniDownloads`, alte Fassungen unter `Learnweb/Fassungen` im Container).

## 4. Architektur

1. **Lokales Backend:** Es beantwortet dieselben `/api/`-Pfade mit derselben JSON-Form wie `app/server.py`. Die
   fertigen 1:1-Ansichten bleiben unverändert. Angeschlossen wird es über ein Transport-Protokoll im `APIClient`
   (die beiden URLSession-Aufrufe werden zu `transport.send`); die Basis-URL `uniflow-local://device/` trennt den
   Zwischenspeicher von Serverdaten.
2. **SQLite ohne Fremdpaket:** iOS-System-SQLite3; im Kern unter Linux über eine `systemLibrary` (CI braucht
   `libsqlite3-dev`). Schema wörtlich aus `app/db.py` (Generator), Migrationen 1:1 wie `db.py`. Ein Actor mit einer
   Verbindung; **kein `await` innerhalb einer Transaktion** (Actors sind reentrant). Datenbank mit Dateischutz
   `completeUntilFirstUserAuthentication`.
3. **Python bleibt die Referenz:** Logik wird nach Swift portiert, Ergebnisgleichheit über Fixtures, die
   `tools/gen-logic-fixtures.py` mit eingefrorener Uhr aus Python erzeugt. Korrekturen zuerst in Python.
4. **Stud.IP-Abgleich in die lokale Datenbank:** wiederaufnehmbar, Fehler nur je Kurs/Datei, Versionen über chdate,
   Größe und SHA-256, Downloads als Datei statt im Arbeitsspeicher. Dateien erscheinen in Dokumente & Notizen,
   Modulen und Übersicht und öffnen sich direkt im UniFlow-Editor (keine eigene Stud.IP-Liste als Hauptoberfläche).
5. **Neue Original-Fassung:** Notizen bekommen einen Herkunftsstempel (Hash, Seitenzahl, Seitenfingerabdruck);
   beim Wechsel werden Seiten über den Inhalt neu zugeordnet, die alte Fassung wird aufbewahrt, der Nutzer sieht
   einen Hinweis.
6. **Hintergrund:** Abgleich sicher beim Start und Wiederöffnen; BGAppRefresh „frühestens 8/15/20 Uhr“ ohne
   Versprechen fester Zeiten – sinnvoll erst mit längerer Sitzung bzw. OAuth2.
7. **Community „Lösungen teilen“:** Nur die eigene Anmerkungsebene wird veröffentlicht (Vorschau, Bestätigen,
   Zurückziehen), angezeigt direkt im Editor über der eigenen Original-PDF des Betrachters. Zuordnung über den
   SHA-256 der Original-PDF; der Hash ist **kein Besitznachweis**. Deshalb zusätzlich: Prüfung auf dem Gerät, dass
   die Datei aus dem eigenen Stud.IP-Abgleich stammt und ihr Kurs in den eigenen Kursen liegt; Inhalt verschlüsselt
   mit einem Schlüssel, der aus den Bytes der Original-PDF abgeleitet ist (wer die Datei nicht hat, kann nichts
   lesen); Melden und Blockieren (App Store 1.2); Hinweis auf die Prüfungsordnung. Eine echte Prüfung der
   Kursmitgliedschaft auf dem Dienst ginge nur mit Mitwirkung der Hochschule (z. B. signierter Beleg), denn
   Stud.IP-Cookies oder -Tokens dürfen nie an einen Dienst.
   **Umgesetzt in S9 (ohne Dienst):** Paketformat, Verschlüsselung (AES-256-GCM, Schlüssel per HKDF-SHA256 aus den
   vollständigen PDF-Bytes, Kopf als AAD), Teilen als Datei, Import, Anzeige im Editor, Schnittstelle
   `CommunityService` mit der Umsetzung „nicht verbunden“. Noch offen: die Prüfung „Datei stammt aus dem eigenen
   Stud.IP-Abgleich“ (braucht S3) sowie Melden/Blockieren und die Berechtigungsprüfung auf dem Dienst.
   Nachgebessert (`wip/loesung-teilen-fix`): präparierte Dateien bringen die App nicht mehr zum Absturz
   (Formatversion), Zusatzfelder ohne Authentifizierung werden abgewiesen, Bilder mit zu großen Pixelmaßen ebenso,
   eine gleiche Lösungs-ID verdrängt keine vorhandene Lösung, ausgeblendete eigene Notizen sind wirklich nur zum
   Ansehen, unlesbare Importe bleiben nicht als Dauermeldung liegen.
   Härtetests auf `develop` behoben: Ansichtsmodus schreibt nie (auch nicht über Rückgängig des Systems), Export
   wartet auf ausstehende Tinte, gemischte Seitengrößen, lange Titel, kein leeres Paket, Extremwerte sicher
   (`HardeningExportTests`, `HardeningSolutionEditorTests`, `HardeningSolutionRoundTripTests`). Seit S3 kommt die
   Plus-Sperre dazu: mit Free ist der Editor wie im Ansichtsmodus nur zum Ansehen (`canEdit` neben `ownNotesVisible`).
   **S9b (Zweig `wip/community-cloudkit`, Entscheidung des Inhabers vom 26.10.2026: CloudKit für V1, später
   Supabase):** Online-Community als `CloudKitCommunityService` hinter `CommunityService` (der Kern bleibt ohne
   CloudKit, der Dienst ist tauschbar). Sichtbarkeit Modul / Lerngruppe / anonym, Kurs-Schlüssel statt Kurs-ID, Melden,
   Blockieren, Zurückziehen, Pseudonym. Grenzen ehrlich: nur Apple-Geräte (CloudKit), Berechtigung = Kenntnis der
   Kurs-ID (kein Beleg der Hochschule), echte Läufe erst mit Developer Program; Tests gegen ein nachgebildetes CloudKit.
   Einzelheiten und Grenzen: `docs/LOESUNGEN-TEILEN.md`.

## 5. Reihenfolge der Umsetzung

Zuerst der größte Nutzen: Dokumente öffnen und mit dem Pencil schreiben ohne PC.

| Schritt | Inhalt | Abnahme ohne PC |
|---|---|---|
| S1 | SQLite-Schicht, Schema, Migrationen, gemeinsame Uhr | Tests im Kern grün (macOS und Linux) |
| S2 | Transport-Weiche und Router; Journal-Namensraum je Datenquelle; **Übernahme der eigenen Notizen und Pläne vom PC** (Entwicklung, noch offen); gültige leere Antworten für noch nicht portierte Pfade | Seiten laden lokal ohne Fehler; Wechsel PC ↔ lokal verliert keine Notizen (**umgesetzt bis auf die Übernahme**) |
| S3 | Stud.IP-Dateien in die Datenbank; Endpunkte Bibliothek, Datei-Inhalt, Notizen; Editor lokal (**umgesetzt**, `wip/s3-dokumente-3`; nachgebessert in `wip/s3-dokumente-3-fix`: neue Fassung erst mit dem Download, Kopien nach „Dateien löschen“, Plus-Sperre für Schreiben und Notizbücher, Downloads als Datei) | Stud.IP verbinden → Dokumente erscheinen → im Editor öffnen und schreiben, offline (**App-Test mit festen Stud.IP-Antworten grün**, `LocalDocumentsAppTests`; echtes Stud.IP und Gerät offen) |
| S4 | Fach, Art, Lehrwoche ohne KI (`classify`, `effective_type`, `week_hint`); Module-Endpunkte: **umgesetzt** (`wip/s4-module-3`): Port von `classify`, `effective_type`, `week_hint`, `enrich_file`, Semesterwochen (Stichtag und Woche 0 vorher in Python korrigiert), `ensure_modules`, `module_detail`, `modules_overview`, `guess_module`; alle Module-Endpunkte; im Kern gegen Python, in der App mit Seed-Daten im Simulator geprüft; mit S3 zusammengeführt in `wip/int-s345-s4` (`classify` beim Abgleich, eine Fassung von `ensure_modules`, Einstellungen → „Module“ ohne PC) | Fächer geordnet, Moduldetail mit Wochen (**mit Seed-Daten im Simulator und mit Daten aus dem Stud.IP-Abgleich im App-Test erfüllt**, feste erfundene Stud.IP-Antworten; echtes Stud.IP und echtes iPad offen) |
| S5 | Stundenplan: Kurszeiten und Einzeltermine aus Stud.IP, `timetable.py`-Port; **umgesetzt** (`wip/s5-stundenplan-2`): Abruf nach dem Datei-Abgleich (`StudIPScheduleSync`), Ablage und `auto_import` (`StudIPScheduleStore`), alle `/api/timetable/*` außer `reslot` (S6), Gruppenauswahl in der Importvorschau, ICS mit UTC/TZID/EXDATE (zuerst in Python korrigiert); mit S3 und S4 zusammengeführt in `wip/int-s345-s5` (Abgleich füllt Dokumente und Stundenplan, Unterlagen zum Termin, nächster Termin je Modul, ein difflib-Port, `ensure_modules` vor `auto_import`) | Stundenplan aus Stud.IP (**im Simulator mit erfundenen Stud.IP-Antworten geprüft**: Woche zeigt die Kurse, Ausfälle, Gruppen zur Auswahl; seit dem Zusammenführen ein App-Test über den ganzen Ablauf bis zu den Unterlagen im Termin-Panel; mit echtem Stud.IP noch nicht) |
| S6 | Lernlogik (`study.py`): lesen, verschieben, planen; Übersicht, Kalender; **umgesetzt** (`wip/s6-lernplan-2`): Port von `study.py` auf die Bausteine aus S4/S5, alle `/api/calendar*`, `/api/tasks*`, `/api/packages*`, `/api/timetable/reslot` und `/api/dashboard` vollständig; zuerst in Python korrigiert: Uhrzeit von Lernpaketen, leere Pakete, Ersetzen, 404 statt 500, Pakete am Stück neben Terminen; ohne Testaufgaben (`tests_per_subject` 0); auf den Stand mit dem PC-Kern gesetzt in `wip/v1-s6` | Lernplan erstellen, Aufgaben abhaken, Übersicht (**App-Test im Simulator mit erfundenen Daten grün**: Lernpaket über den Dialog, im Lernkalender, abhaken, Übersicht; Plan erstellen neben Terminen ohne Konflikt; echtes iPad offen) |
| S7 | Neue Original-Fassung mit erhaltenen Notizen; Suche und Skriptsuche; **umgesetzt** (`wip/v1-s6-s7`): Port von `scriptsearch.py` und `/api/search` (zuerst in Python um Aufgaben und Seitentexte erweitert, Begriffe in fester Reihenfolge), Seitentexte mit PDFKit; alte Fassung aufbewahren, Seiten über den Text zuordnen, Notizen umhängen, Hinweis mit alter Fassung (Entwurf, Python hat dafür keine Regel) | Notizen überleben neue PDF; Suche offline (**App-Tests im Simulator mit erfundenen Stud.IP-Antworten grün**: Notizen auf den passenden Seiten, Hinweis, alte Fassung öffnet sich; Suche findet Text einer PDF ohne Netz; echtes iPad offen) |
| S8 | Hintergrundabgleich; **umgesetzt** (`wip/s8-hintergrund`): `BGAppRefreshTask` nur mit den Listen, `BGProcessingTask` mit Netz für die Downloads, frühestens 8/15/20 Uhr Ortszeit (`BackgroundSchedule`), Sperren und Regeln im Kern (`BackgroundSyncGate`, `BackgroundSyncState`, `BackgroundTaskRun`), Lauf auf dem offenen Container (`BackgroundSyncController`), Karte in den Einstellungen | Abgleich beim Öffnen und, wenn iPadOS es erlaubt, im Hintergrund (**Kern- und App-Tests mit erfundenen Daten grün**: Termine über Tage und Zeitumstellungen, gefälschter und echter Abgleich, Ablauf mitten im Download, abgelaufene Sitzung ohne Anmeldeseite, Trennung je Container; echtes iPad über mehrere Tage offen) |
| S9 | Community „Lösungen teilen“: **lokaler Teil umgesetzt** (`wip/loesung-teilen`, nachgebessert in `wip/loesung-teilen-fix`: robuste Formatversion, keine Zusatzfelder, Pixelgrenze für Bilder, gleiche Lösungs-ID verdrängt nichts, Ansichtsmodus schreibt nichts, unlesbare Importe werden entfernt, Entschlüsseln abseits des Hauptthreads; `docs/LOESUNGEN-TEILEN.md`): Lösung als Datei teilen (nur eigene Notizen), importieren, im Editor als Ebene ansehen, lokal zurückziehen. **Online-Teil programmiert (S9b, `wip/community-cloudkit`)**: CloudKit hinter `CommunityService` | lokal: Lösung als Datei teilen, auf zweitem iPad mit derselben PDF ansehen (**Tests grün**); online: veröffentlichen, finden, laden, zurückziehen, melden, blockieren, Lerngruppen (**Tests gegen nachgebildetes CloudKit grün**; echter Lauf **offen**, braucht Developer Program und iCloud-Container) |
| S10 | Anmeldung härten, Release-Bereinigung, Demo-Modus für die App-Prüfung, Abnahmeliste | Abnahme nach AUFTRAG 2a und dieser Datei |

Nach jedem Schritt: bauen, Unit-Tests, Prüfung „funktioniert auf einem iPad ohne Windows-PC“, Abschnitt 2 dieser
Datei fortschreiben.

## 6. Hochschul-Freigaben (vom Inhaber zu klären)

- **ZQS/elsa:** schriftliche Erlaubnis für den Abruf über die JSON:API durch eine App für andere Studierende
  (Abrufmuster nennen); OAuth2-Client mit PKCE und Lebensdauer von Sitzung und Refresh-Token; ob Teilen der eigenen
  Anmerkungsebene innerhalb eines Kurses in Ordnung ist. Entwurf: `docs/ANFRAGE-STUDIP-ZUGANG.md`.
- **LUH:** Erlaubnis für den App Store nach Richtlinie 5.2.2 (Nutzung der Hochschuldienste und Namen), dazu nach
  5.2.3 für Opencast-Aufzeichnungen samt Download auf das Gerät (Laden auf Wunsch, `RecordingLibrary`).
- **Uni Hildesheim** (ergänzt bei der Abnahme 26.10.2026, die App bietet sie in der Hochschulwahl an): Erlaubnis nach
  5.2.2 für CAS, Learnweb über den Dienst der offiziellen Moodle-App (`moodle_mobile_app`, Schema `moodlemobile`), LSF
  und den Namen. Bis zur Freigabe ggf. im Release ausblenden (Entscheidung des Inhabers); Entscheidung 5 („Nur LUH“)
  ist durch den Code überholt und muss bestätigt oder geändert werden.
- **LUIS:** Anmeldung in der eingebetteten Webansicht als Übergang zulässig oder nur `ASWebAuthenticationSession`.
- **Datenschutz und Urheberrecht:** Datenschutzerklärung; lokale Speicherung der Skripte; Teilen eigener
  Anmerkungen über fremden Folien; Hinweis zu bewerteten Abgaben (Prüfungsämter).
- **Messung am Gerät (ohne Freigabe):** Wie lange hält die Stud.IP-Sitzung? Liefert Stud.IP ETag oder
  Last-Modified?

## 7. Entscheidungen des Inhabers

**Entschieden am 25.10.2026** (Vorschläge 1–7 bestätigt):

1. **Python-Korrekturen** (Stichtag des Semesterbeginns, gespeicherte Uhrzeit von Lernpaketen, ICS mit UTC/TZID)
   werden als Fehlerbehebung auch in der Web-App übernommen – zuerst in Python, danach portiert. (Uhrzeit von
   Lernpaketen umgesetzt in S6, dazu die beim Portieren gefundenen Fehler, siehe Abschnitt 2.)
2. **Lernplan ohne Testaufgaben** (keine KI): Standard `tests_per_subject` = 0, in Python und auf dem iPad
   (umgesetzt in S6; bestehende Datenbanken am PC behalten ihren Wert).
3. **Demo-Modus** für die App-Prüfung nur über einen versteckten Schalter für Prüfer; sonst keine Beispieldaten.
4. **Eigener Server** (Entwicklungsmodus) nur in Debug-Builds; im Release nicht erreichbar.
5. **Nur LUH** in V1. Seitdem auf `develop`: Hochschulen strikt getrennt und Hildesheim am PC
   (`docs/HILDESHEIM.md`), Auftrag für die iPad-App in `docs/AUFTRAG-HILDESHEIM-IPAD.md`; auf dem iPad bisher nur die
   Hochschul-Regel der lokalen Datenbank (`settings.university`, `UniversityMismatch`).
6. **Backup:** Notizen, Plan und Einstellungen ins iCloud-Backup; Stud.IP-Dateien, alte Fassungen und Seitentexte
   ausgenommen.
7. **Große Dateien** (z. B. Videos über 100 MB) werden nur auf Wunsch geladen. Umgesetzt für die Opencast-Aufzeichnungen
   (`RecordingDownloadPolicy`); Stud.IP-Dateien lädt der Abgleich weiterhin alle (Oberfläche dafür fehlt noch).

**Offen:**

8. **Community-Dienst:** **Entschieden (26.10.2026): CloudKit für V1** (gehört zum Developer Program, 99 €/Jahr),
   später Supabase – darum alles hinter `CommunityService`. Programmiert in S9b (`wip/community-cloudkit`); der Knopf
   „In der Community veröffentlichen“ ist aktiv, sobald der Build einen iCloud-Container hat (`Config/Team.xcconfig`,
   `UF_CLOUDKIT_CONTAINER`), sonst „nicht verfügbar“ und kein Menüpunkt „Community“. **Entschieden (26.10.2026):**
   die Kenntnis der Kurs-ID oder des Kursnamens reicht als Berechtigung (kein Beleg der Hochschule; eigene Dokumente
   über den Modulnamen), die Moderation macht der Inhaber im CloudKit Dashboard (Anleitung in
   `docs/LOESUNGEN-TEILEN.md`, Abschnitt 7). Offen: Container und Schema im Developer Program anlegen, Löschfristen,
   Nutzungsbedingungen/Datenschutzerklärung mit der Community.

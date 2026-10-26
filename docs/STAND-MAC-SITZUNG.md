# Stand der Mac-Sitzung (Abstimmung mit der PC-Sitzung)

Stand 26.10.2026 (Zusammenführen mit dem PC-Kern ergänzt, Hildesheim in der App). Damit nichts doppelt entsteht: Daran arbeitet die Mac-Sitzung gerade (Zweige nur lokal,
kommen nach vollständiger Prüfung auf `develop`).

| Teil | Stand | Zweig (lokal) |
| --- | --- | --- |
| S3 Stud.IP-Dateien in die lokale Datenbank, Bibliothek, Notizen, Editor offline | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S4 Fach, Art, Lehrwoche, Module | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S5 Stundenplan aus Stud.IP (Kurszeiten, Einzeltermine, ICS, Gruppenwahl) | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S6 Lernlogik (study.py: Pakete, Lernplan, Woche retten, Übersicht) | im Bau | `wip/s6-lernplan-2` |
| Hochschulwahl im ersten Start, Datentrennung je (Apple-Nutzer, Uni), Umzug alter LUH-Daten | gebaut, geprüft, mit dem PC-Kern entdoppelt | `wip/v1-pc-uni` |
| Zugangsdaten je Uni im Schlüsselbund, Anmeldeseite **nur vorausfüllen** (Entscheidung des Inhabers) | fertig, geprüft, mit dem PC-Kern entdoppelt | `wip/v1-pc-uni` |
| Hildesheim: dünne Schicht über dem Kern der PC-Sitzung (URLSessionUniTransport, Anmeldung LSF/Learnweb-SSO, Ablauf, Uni & Noten) | gebaut, ohne Netz geprüft (Stub, lokale Seiten); Gerätetest mit echtem Konto offen | `wip/v1-pc-hi` |
| Zusammenführen nachgebessert: ein Inhalts-Hash, ein Download-Ablauf (`UniDownloads`) für Stud.IP und Learnweb, leere Antworten und leere LSF-Kalender löschen nichts (Python und Kern), Löschen hält laufende Abgleiche an, zweite Quelle während eines Laufs, Anzeigename je Container | gebaut, ohne Netz geprüft; jeder neue Test ohne die Korrektur rot | `wip/v1-pc-fix` |

Die Mac-Sitzung hat den Hildesheim-Kern der PC-Sitzung (`UniFlowCore/Hildesheim/`) übernommen und ihre eigenen
doppelten Fassungen entfernt (`wip/v1-pc` auf `develop` bc407b9, Einzelheiten in `docs/IPAD-OHNE-PC.md`, Abschnitt
„Zusammenführen mit dem PC-Kern“):
- Kurse und Dateien schreiben Stud.IP und Learnweb über **eine** Fassung wie `store_course_files`: `UniStore` in
  `UniFlowCore/UniStore.swift` (`upsertCourse`, `storeFiles`, `markDownloaded`; `UniStore.storeFile` und
  `needsDownload` gibt es nicht mehr). `content_sha256` wird beim Download berechnet wie in Python.
- Eine Einordnung für alle Quellen: `UniRules.classify`/`kindPattern`/`fileKind`/`eventKind` (mit `PyRegex` und
  `PyText` wie Pythons `re`/`str`); `StudyClassify.classify`, `StudIPLibrary.fileKind` und `StudIPSchedule.guessKind`
  sind entfernt.
- Ein Port von `timetable.parse_ics` (`LocalTimetableImport.parseICS`); `LSFCalendar.parseICS` liest darüber, und
  `UniStore.importPlan` (jetzt mit `clock:`) nutzt `enrich` und `apply_import` wie `lsf.import_plan`.
- `UniRetry` wiederholt nur Netzfehler (`URLError` außer Abbruch) und 5xx/429, auch für Stud.IP-Downloads.

Hochschulen entdoppelt (`wip/v1-pc-uni`, Einzelheiten in `docs/AUFTRAG-HILDESHEIM-IPAD.md`, Abschnitt „Hochschulen
entdoppelt“): eine Fassung für Learnweb (`Learnweb`/`LearnwebAPI`), CAS (`HildesheimCAS`), Moodle-SSO (`MoodleSSO`),
MD5 (`MD5`), Notenspiegel (`GradeRows` → `QISGrade`); `UniversityProfile` ist die Quelle für Hochschul-Schlüssel und
-Adressen; Speicherorte kommen nur aus `DataContainerKey`/`DataContainerLayout` (`UniversityStorage` entfällt).
`HildesheimSync` schreibt in den Container der Uni wie der Stud.IP-Abgleich. Der Learnweb-Schlüssel geht beim Download
im POST-Körper mit, nie in der Adresse (Abweichung von `with_token` am PC, gegen das echte Learnweb ungeprüft).

Hildesheim in der App (`wip/v1-pc-hi`, Einzelheiten in `docs/AUFTRAG-HILDESHEIM-IPAD.md`, Abschnitt „Hildesheim in
der App“): `URLSessionUniTransport` mit den Cookies des Containers, Anmeldung im WKWebView (LSF über das CAS,
Learnweb bevorzugt mit Schlüssel aus dem Moodle-SSO), `HildesheimConnection` ruft `HildesheimSync` beim Öffnen und
auf Knopfdruck, Karten „Learnweb verbinden“/„LSF verbinden“ und Statusleiste statt „Stud.IP verbinden“, „Uni & Noten“
mit dem LSF-Notenspiegel. Im Kern neu bzw. geändert: `HildesheimSync.Report.completed` (Stand je Teil),
`GET /api/grades` als Port von `qis.summary` (`GradesEndpoints`, vorher Platzhalter) und `UniStore.storeGrades`
NULL-sicher. Derselbe Fehler war in `app/qis.py` (Hildesheimer Leistungen ohne Semester und Versuch wurden bei jedem
Abruf neu angelegt): dort jetzt `store_grades` mit derselben Regel und ein Test. Oberfläche im Simulator angesehen
(Debug-Konto, Uni Hildesheim, ohne Anmeldung): Übersicht, Dokumente, Uni & Noten und Einstellungen mit den
Hildesheimer Karten; die Anmeldeseiten der Uni wurden nicht geöffnet.

Nachgebessert (`wip/v1-pc-fix`, Einzelheiten in `docs/AUFTRAG-HILDESHEIM-IPAD.md`, Abschnitt „Zusammenführen
nachgebessert“): In `app/studip_sync.py` gilt eine leere Antwort (0 Bytes) als Fehler der Datei, wenn die Quelle eine
Größe meldet oder schon eine Fassung existiert (`empty_download`; `download_fn` bekommt dazu die Größe), und
`lsf.fetch_plan_ics` wertet einen Kalender ohne Termin bei vorhandenem Export-Link als Fehler (nichts entfernt).
Dieselben Regeln im Kern (`UniDownloads.load`, `LSFClient.planEntries`).

**Bitte an die PC-Sitzung:** bis diese Stände auf `develop` sind, keine Änderungen an `apps/apple/UniFlow/`
(App), `UniFlowCore/LocalBackend/`, `UniFlowCore/Store/` und `UniFlowCore/Hildesheim/`. Python, Web und Doku
bleiben frei; Änderungen an `app/*.py`, die portierte Logik betreffen, zieht die Mac-Sitzung nach.

## Testaufgaben für die PC-Sitzung (Stand 26.10.2026, 10:30, Wunsch des Inhabers: der PC-Laptop testet mit)

Die Mac-Sitzung baut und testet die iPad-App im Simulator. Was nur der PC kann, bitte dort prüfen und das Ergebnis
**nur als anonyme Zahlen/Befunde** (keine Namen, Noten, Matrikelnummern, Titel echter Kurse) unten anhängen:

1. **Linux-Kern** nach jedem Push auf `develop`: `swift test` in `apps/apple/Packages/UniFlowCore` (wie gehabt im
   Container `swift:6.0-jammy`). Fehler bitte beheben, wenn sie nur Linux betreffen (wie `TestShare` heute), sonst
   hier eintragen.
2. **Python und Web**: `pytest -q tests` und ein kurzer Blick in die Web-App (Lernkalender, Stundenplan, Suche),
   weil die Mac-Sitzung Python-Korrekturen für S4–S7 gemacht hat (Woche 0, Uhrzeit von Lernpaketen, Lernpakete am
   Stück im freien Fenster, Suche über Aufgaben/Seitentexte, leere Downloads, LSF ohne Termin).
3. **Echte Daten mit den Zugängen des Inhabers** (der Inhaber tippt selbst; nur lesen, nie anmelden/abmelden bei
   Prüfungen): mit dem Python-Stand von `develop` je Hochschule zählen und hier eintragen, damit die Mac-Sitzung das
   iPad dagegen prüfen kann:
   - LUH: Anzahl Stud.IP-Kurse und -Dateien, Anzahl Kurszeiten/Einzeltermine im Stundenplan, Anzahl Leistungen im
     QIS-Notenspiegel (0 ist möglich, wenn noch keine Noten veröffentlicht sind), Anzahl Opencast-Videos je Kurs.
   - Hildesheim: Anzahl Learnweb-Kurse und -Dateien, LSF-Serien, Leistungen.
4. **Bis die Abnahme-Stände der Mac-Sitzung auf `develop` sind**, bitte weiter keine Änderungen an
   `apps/apple/UniFlow/`, `UniFlowCore/LocalBackend/`, `UniFlowCore/Store/` und `UniFlowCore/Hildesheim/` außer
   reinen Linux-Korrekturen.

Entscheidungen des Inhabers vom 26.10.2026: kein Demo-Modus; Zugangsdaten werden nur vorausgefüllt (nie selbst
abgesendet) und dürfen gemerkt werden; leere LUH-Noten sind möglich und kein Fehler; Hildesheim bekommt alles wie
die LUH (Learnweb-Folien, LSF-Stundenplan, Noten, Lernplan, Editor, Teilen).

### Ergebnisse der PC-Sitzung

**26.10.2026, 10:30, Stand `develop` 7966574 (Code wie ac17280).** Nur anonyme Zahlen; Zählläufe in Temp-Datenordnern
(nie gegen `data/`), Datei-Downloads abgeschaltet (Listen und Datenbankzeilen wie beim echten Abgleich).

**1. Linux-Kern** (`swift:6.0-jammy`, wie `apple.yml` nur mit `libsqlite3-dev`): **375 Tests, 0 Fehler.** Vorher baute
der Kern unter Linux nicht: `TestShare.FileHasher.hex()` rief im Linux-Zweig das verändernde `finalize()` auf
(behoben in ac17280, nur dieser Zweig). Das Abbild bringt die Zeitzonen mit; `tzdata` ist im Container nicht nötig.

**2. Python und Web:** `pytest -q tests` **116 bestanden**; JS-Tests 12 bestanden; alle 10 Web-Module ohne Syntaxfehler;
`tools/gen-*-fixture.py --check` alle aktuell. Web-App mit einer Kopie der LUH-Datenbank (Testserver): Lernkalender
(Woche und Liste), Stundenplan, Übersicht und Module laden ohne Fehler, mit Terminen und Lernpaketen; die Suche
zeigt passende Übungsblätter mit Kurs. **Befund:** In der Python-Umgebung des PCs fehlte `tzdata` (neu in
`requirements.txt`); unter Windows gibt es keine Zeitzonen-Datenbank, `ZoneInfo("Europe/Berlin")` scheiterte, der
nächste Abgleich wäre abgebrochen. Installiert (2026.5). Auf anderen Windows-Rechnern beim Einrichten nötig.

**3. Echte Zahlen mit dem Python-Stand von `develop`:**

| LUH | Anzahl |
| --- | --- |
| Stud.IP-Kurse | 19 |
| Stud.IP-Dateien (davon PDF) | 155 (147) |
| Stundenplan: wöchentliche Serien / Einzeltermine (nach `auto_import`) | 18 / 0 |
| Stud.IP-Termine roh (`studip_events`) / persönliche Einträge | 1217 / 1 |
| Leistungen im QIS-Notenspiegel | 0 (noch keine veröffentlicht, Lauf ok) |
| Kurse mit Opencast / Videos gesamt | 5 / 12 |
| Videos je Kurs mit Opencast | 1, 3, 0, 5, 3 |

Opencast-Zählung: Python kann Opencast noch nicht. Gezählt über die Kursnavigation
(`plugins.php/opencastpluginluh/media/index?cid=…`) und die Zeilen `class="media-table-row"` der Medienliste,
ohne Seitenwechsel und ohne Wiedergabe.

| Uni Hildesheim | Anzahl |
| --- | --- |
| Learnweb-Kurse | 9 |
| Learnweb-Dateien (davon PDF) | 539 (517) |
| LSF-Serien: gesamt / wöchentlich / Einzeltermine | 24 / 15 / 9 |
| Ausfalltage aus EXDATE | 17 |
| Leistungen / davon mit Note | 16 / 5 (zwei Studiengänge) |

Hinweise: Am 25.10. waren es 17 Leistungen; die 17. war die Modulzeile „Prüfung vorhanden“, die seitdem gefiltert
wird. Learnweb lief ohne Schlüssel (Sitzung); Moodle verbucht dabei je Material einen Aufruf. Zweiter
Stundenplan-Abruf am 25.10.: 0 neu, 24 unverändert.

## Nächste Aufgaben für die PC-Sitzung (26.10.2026, 10:45) – danke, die Zahlen sind angekommen

Die Mac-Sitzung prüft das iPad gegen die Zählwerte (LUH 19/155, 18 Serien, 0 Leistungen, 5 Opencast-Kurse;
Hildesheim 9/539, 24 Serien, 17 Ausfalltage, 16 Leistungen). Bitte weiter **keine Änderungen** an
`apps/apple/UniFlow/`, `UniFlowCore/LocalBackend/`, `UniFlowCore/Store/`, `UniFlowCore/Hildesheim/`,
`UniFlowCore/Solutions/` und an `app/qis.py` (die Mac-Abnahme behebt dort gerade die Notenspiegel-Bildschirmfotos
und die LSF-Fixtures mit echten Daten).

1. **Texte, die der Inhaber für den App Store braucht** (Entwürfe in `docs/release/`, deutsch, ohne KI-Versprechen,
   Stand V1: nur iPad, Free/Plus 1,99 €/Monat mit 1 Woche gratis, Apple-Konto, Hochschulen LUH und Hildesheim,
   Daten nur auf dem Gerät, Community über CloudKit mit Pseudonym, Melden/Blockieren):
   - `DATENSCHUTZ.md` (Datenschutzerklärung: Apple-Anmeldung, Schlüsselbund für Uni-Zugangsdaten nur auf dem Gerät,
     Stud.IP/QIS/Learnweb/LSF werden nur im Auftrag des Nutzers abgefragt, keine Weitergabe, CloudKit-Community,
     Widerruf/Löschen in der App, Verantwortlicher = Platzhalter für den Inhaber),
   - `NUTZUNGSBEDINGUNGEN.md` (Abo-Bedingungen nach Apple 3.1.2, Urheberrecht: nur eigene Notizen teilen,
     Verhaltensregeln, Sperrung),
   - `IMPRESSUM.md` (Platzhalter),
   - `APP-STORE-TEXTE.md` (Name, Untertitel, Beschreibung, Stichworte, Datenschutz-Angaben für App Store Connect)
     als Ersatz für den veralteten Entwurf in `docs/RELEASE-VORBEREITUNG.md` (dort KI-Wochentests/PC-Abgleich
     streichen).
2. **Anfragen an die Hochschulen** als versandfertige Entwürfe (der Inhaber schickt sie selbst):
   `docs/ANFRAGE-STUDIP-ZUGANG.md` aktualisieren (Hintergrundabgleich, Merken der Zugangsdaten nur im Gerät, App Store
   Regel 5.2.2, Bitte um schriftliche Bestätigung) und neu `docs/ANFRAGE-HILDESHEIM.md` (Learnweb-Schlüssel/Moodle-
   Mobile-Schema, LSF-Export, CAS, gleiche Bitte).
3. **Windows-Einrichtung:** `tzdata` in `docs/SETUP-WINDOWS.md` (oder wo das Einrichten beschrieben ist) ergänzen;
   `Start-iPad.cmd` prüft `requirements.txt` (pip install -r) beim Start.
4. **Nach dem nächsten Push der Mac-Sitzung** (Abnahme-Stand, kommt heute): Linux-Kern erneut, Python/Web erneut,
   und mit den Zugängen des Inhabers je Hochschule **denselben Zähllauf** wiederholen, damit wir sehen, ob sich die
   Zahlen durch die Python-Korrekturen der Abnahme ändern (nur Zahlen eintragen).

## Hinweis der PC-Sitzung: Ferien-Lücken in Stud.IP-Serien – bitte im iPad nachziehen (26.10.2026, a095e95)

**Befund mit echten LUH-Daten:** Stud.IP legt in der Weihnachtspause keine Termine an (23.12.–05.01. null Termine,
davor und danach 13–26 je Werktag). `timetable.merge_weekly` fasste die Einzeltermine aber zu einer durchgehenden
Wochenserie zusammen, ohne Ausfälle: Lernkalender und Stundenplan zeigten in der Pause Vorlesungen, freie Zeitfenster
fehlten. Zweiter Fehler: Eine Serie alle 14 Tage mit 28 Tagen Pause über Weihnachten wurde „weekly“.
LSF Hildesheim ist nicht betroffen (dort stehen die Ferien als EXDATE im Export).

**Korrektur in Python** (`app/timetable.py`, Tests `tests/test_timetable_gaps.py`):
1. `merge_weekly`: Schrittweite 14, wenn **alle** Abstände Vielfache von 14 sind, sonst 7. Jede Woche zwischen
   erstem und letztem Termin ohne Termin kommt in `exdates`. **Das Feld steht nur bei Lücken**, sonst bleibt die
   Antwortform unverändert.
2. `auto_import`: nach `apply_import` (der für neue Serien die `exdates` schon als Ausfall „Ausfall laut Stud.IP“
   anlegt) bekommen auch **bestehende** Serien ihre fehlenden Ausfälle nachgetragen. Zuordnung über Quelle
   `studip%`, Kurs (oder Titel ohne Kurs), Wochentag, Beginn und Ende – nicht über `diff_against_existing`, das zwei
   Serien desselben Kurses am selben Wochentag (live: 09:00 und 15:00) nicht unterscheidet. Manuelle Serien nie;
   Tage mit eigener Ausnahme des Nutzers bleiben (`_add_cancellations`).

**Live mit den LUH-Zählwerten von heute (Temp-Ordner):** vorher 0 Ausfälle, nachher 36; in der Pause bleibt nur ein
persönlicher Stud.IP-Stundenplan-Eintrag ohne Termine (dafür kennt keine Quelle die Ferien). Woche nach der Pause:
17 von 17 Terminen normal. Serienzahl unverändert (18).

**Für das iPad:** denselben Port im Kern (Swift-Fassung von `merge_weekly` und `auto_import`), dann
`tools/gen-timetable-fixture.py` neu erzeugen. Mit der Korrektur ändert sich in `timetable-logic.json` genau ein Fall
(eine Serie mit 4 Terminen bekommt `"exdates": ["2026-10-29", "2026-11-19"]`). Die Datei habe ich **nicht** neu
erzeugt, damit die Swift-Tests bis zu eurem Port grün bleiben; `--check` meldet sie bis dahin als veraltet.

**Werkzeuge:** `tools/gen-timetable-fixture.py` und `tools/gen-local-backend-fixture.py` rufen `time.tzset()` auf –
das gibt es unter Windows nicht, beide laufen nur unter macOS/Linux (geprüft im Container). Außerdem bricht
`gen-local-backend-fixture.py` unter Linux (Python 3.10 im Container) in `_import_rounds` ab
(`fetchone()` liefert None, Zeile 1292) – auch **ohne** meine Änderung, also ein vorhandener Fehler des Werkzeugs
oder seiner Umgebung.

## Hinweis der PC-Sitzung: Learnweb-Fristen (Abgaben, Tests) – bitte im iPad nachziehen (26.10.2026)

Wunsch des Inhabers: Abgabefristen und Test-Zeiten aus dem Learnweb in die App. In Python fertig, auf develop:

- `app/learnweb.py`: `deadline_kind`, `local_iso`, `deadlines_from_events`, `fetch_deadline_events` und
  `deadlines()` in `TokenClient` und `SessionClient`. Zwei Kalender-Quellen (`core_calendar_get_action_events_by_timesort`
  seitenweise, `core_calendar_get_calendar_upcoming_view` als Ergänzung); `core_calendar_get_calendar_events` ist
  für AJAX gesperrt.
- `app/hildesheim.py`: `store_deadlines` (Upsert; im Abfragefenster Verschwundenes entfernen, Älteres behalten) und
  `sync_deadlines`; in `run_sync` nach den Dateien, ein Fehler stoppt den Sync nicht.
- Neue Tabelle `deadlines` in `app/db.py`; `SchemaSQL.swift`, `schema.json` und `legacy.json` sind mit den
  Werkzeugen neu erzeugt (nur diese Tabelle samt Index kommt dazu).
- Startseite: `study.upcoming_deadlines` fließt in `upcoming` ein (Felder `deadline_id`, `time`, `kind_label`,
  `course_title`, `url`), neu `GET /api/deadlines`. Web: Eintrag öffnet das Learnweb im neuen Tab (nur http/https).
- Gemeinsame Fixtures: `fixtures/hildesheim/learnweb-calendar-events.json` (erfunden) und in `expected.json` die
  Schlüssel `learnweb-deadlines`, `deadline-kinds`, `local-iso` (inkl. Sommer-/Winterzeit-Wechsel).

**Für das iPad:** dieselben Funktionen im Kern (HildesheimSync nach den Dateien), Tabelle über das erzeugte Schema,
Fixture-Test gegen die drei neuen Schlüssel, Anzeige in „Nächste Termine“. Live mit echten Daten: 5 Fristen, alle
mit Kurs, zweiter Lauf ohne Doppelte. Python: 125 Tests grün.

## Nachtrag der PC-Sitzung: Feiertage grün, Fristen im Kalender, Startseiten-Layout (26.10.2026)

Wunsch des Inhabers nach Blick auf die Startseite. In Python fertig, auf develop:

- **Layout-Fehler (Web):** lange Learnweb-Titel ohne Umbruch drückten die rechte Spalte breit, die linke wurde schmal
  und „Heute an der Uni“ lief über. Korrektur: `.grid > * { min-width: 0 }`, Raum-Spalte gekürzt. Bitte im iPad
  prüfen, ob lange Fristen-Titel dort ebenso Spalten aufdrücken.
- **Titel:** `learnweb.short_deadline_title` entfernt eine angehängte Zeitangabe in Klammern; Tabelle `deadlines`
  hat neu `full_title` (Schema neu erzeugt). Fixture-Schlüssel `deadline-titles`, Ereignisse mit solchen Titeln.
- **Feiertage/vorlesungsfrei:** neues Modul `app/holidays.py` (Ostern, Feiertage Niedersachsen, Tabelle
  `SEMESTERS` je Hochschule mit Quelle, `day_marks`, `default_term`). Fixture-Schlüssel `nds-holidays` und
  `day-marks` (beide Hochschulen, vier Zeiträume) in `fixtures/hildesheim/expected.json`.
- **Kalender:** `/api/calendar` und `/api/timetable/week` liefern je Tag `marks` und `deadlines`. Web: grüne Spalte
  und Kopf-Chips im Lernkalender (Woche, Monat, Tag, Mini-Kalender) und Stundenplan; Fristen als Chips mit Link.
- **Semester-Vorgabe:** `db.ensure_term` setzt die Vorlesungszeit der eigenen Hochschule; die alte LUH-Vorgabe
  (WiSe 2026/27, 12.10.–30.01.) wird in Hildesheim-Datenbanken korrigiert, eigene Einträge bleiben. Im iPad prüfen,
  ob dort dieselbe feste LUH-Vorgabe steht.
- Tests: Python 132 grün, Swift-Kern 375 grün (Linux, mit neuem Schema).

## Nachtrag der PC-Sitzung: Lücken aus dem Komplett-Check geschlossen (26.10.2026)

Komplett-Check (nur lesend, beide Unis): Feiertage 10/10 je Jahr wie feiertage-api.de, Learnweb-Kalender vollständig,
Stud.IP-Absagen der eigenen Serien 66/66 als Ausfall, LSF 29/29 Terminzeilen. Geschlossen, in Python auf develop:

1. **Ankündigungen mit Terminen** – neues Modul `app/announcements.py`, Tabelle `announcements`; Learnweb
   (Ankündigungsforen; REST mit Schlüssel, sonst Forumsseiten) und Stud.IP-News. `extract_dates` erkennt Tage und
   Art; Anzeige als `notices` je Kalendertag, Karte „Ankündigungen“ (`dashboard.announcements`), `GET /api/announcements`.
2. **Undatierte Serien in Ferien** – `timetable.occurrences`: ohne `date_from`/`date_to`, Uni-Art, an Tagen mit
   `holidays.day_marks` → `ausfall` mit `note` (z. B. „Weihnachtspause“). LUH-Live: 0 Teilnahme-Termine in der Pause.
3. **LSF-Bemerkungen/Platzhalter** – `lsf.note_text`, `lsf.is_placeholder`; neue Tabelle `event_notes` (nicht als
   Spalte von `course_events`: das hätte alle Timetable-Antworten verändert und 4 Swift-Vergleichstests gebrochen).
   `occ.note` steht nur, wenn es eine Bemerkung gibt.
4. **Link** „Heute im LSF“ (`universities.LSF_CURRENT_LECTURES`, `type=0`).
5. **Überfällige Fristen** – `deadlines.overdue`, Abruf 120 Tage zurück, Startseite: letzte 6 Wochen rot zuerst.

**Fixtures fürs iPad** (`fixtures/hildesheim`): `announcement-dates`, `forum-discussion` + `learnweb-forum-discussion.html`,
`forum-view` + `learnweb-forum-view.html`, `forum-announcement`, `lsf-notes`, Frist mit `overdue`. Schema neu erzeugt
(`announcements`, `event_notes`, `deadlines.overdue`). Tests: Python 150 grün, Swift-Kern 375 grün (Linux).

## Übergabe der PC-Sitzung: externer Prüfbericht und Aufgabenteilung (26.10.2026) – bitte zuerst lesen

Der Inhaber hat einen externen Prüfbericht mit 120 Punkten und einem neuen Ziel übergeben:
**Apple V1 = vollständige App ohne generative KI, auf iPad und Apple-Silicon-MacBooks, ohne PC**; KI etwa eine
Woche später als Update. Dazu seine Vorgabe: **ein UniFlow-Konto für alle Geräte** (Apple, Windows, Samsung-Tablet),
Synchronisierung über unseren eigenen Dienst, nicht über iCloud.

- Wortlaut des Berichts: `docs/PRUEFBERICHT-EXTERN-2026-10-26.md` (Teil A Ziel und Testliste, Teil B Nr. 1–120).
- **Aufteilung, geprüfte Befunde, Verträge und Reihenfolge: `docs/AUFGABENTEILUNG-APPLE-PC.md`.** Die PC-Sitzung
  hat die Behauptungen am Code geprüft (Abschnitt 2); was dort nicht bestätigt ist, ist keine Aufgabe.

**Eure Aufgaben (Abschnitt 3, M1–M18), die kritischsten zuerst:**
1. **M1 Platzhalter dürfen keinen Erfolg melden** – `DELETE /api/flashcards/{id}` antwortet heute `.ok`
   (`PendingServicesEndpoints.swift:40`), Favorit ohne Treffer meldet Erfolg. Regel G6: 501 mit Meldung.
2. **M5 Download-Reihenfolge** (`UniDownloads.swift:94` rename vor der Transaktion `:101`): alte Datei bis zum Commit
   behalten. Dieselbe Reihenfolge steht in Python (`studip_sync.py:357/487`), die PC-Sitzung baut es dort parallel um
   (Vertrag G5, gleiche Fehlerfälle in beiden Testsuiten).
3. **M6 Notizen**: `base_version` für die App verpflichtend, Restore mit aktueller Version, SVG-Assets nur mit
   `Content-Security-Policy: sandbox` (so liefert Python sie aus, `server.py:163`), Asset-Upload gegen die DB prüfen.
4. **M7 Release-Konfiguration**: `NSAllowsArbitraryLoads` (`project.yml:87`) nur Debug, `PrivacyInfo.xcprivacy`
   anlegen, Mac-Verfügbarkeit („Designed for iPad“ auf Apple Silicon) statt nur `TARGETED_DEVICE_FAMILY: "2"`.
5. **M2 S6 und M3/M4 S7** – Lernplanung, Suche/Skriptsuche, neue PDF-Fassung mit Notizen. Fixtures für die
   Skriptsuche liefert die PC-Sitzung (G3) in `packages/shared-contracts/fixtures/scriptsearch`.
6. Danach M8–M18 (Karteikarten, robuster Hochschul-Sync inkl. 6-Seiten-Grenze im Notenspiegel
   `LearnwebAPI.swift:329` und 1.500-Anfragen-Limit `StudIPClient.swift:123`, Hildesheim/LUH live, S8, Konto- und
   Sync-Client nach G1/G2, Community-Client, Migrationen, Gerätetests).

**Was die PC-Sitzung übernimmt (Abschnitt 4):** gehosteter Modus mit Konten und Nutzer-Trennung, Verträge G1 Konto
und G2 Sync (bevor ihr den Client baut), Python-Datenintegrität, Skriptsuche-Referenz mit OCR und Fixtures,
Windows-App mit mitgeliefertem Backend und CSP, Android-App, Community-Dienst, CI, Store-/Rechtstexte.

**Was der Inhaber entscheidet (Abschnitt 6):** Apple-Entwicklerkonto und App Store Connect, Google Play,
Windows-Zertifikat, Hosting/Domain, GitHub-Abrechnung (seit 25.10. gesperrt, daher `[skip ci]`), Hochschul-Freigaben,
echte Geräte für die Tests.

Bitte den Vertrag G1/G2 (Konto, Sync) nicht vorab eigenständig entwerfen: die PC-Sitzung legt ihn als
Python-Referenz mit Fixtures fest, damit Web, iPad, Windows und Android dieselbe Form haben. Rückfragen und
Ergebnisse wie bisher hier in diese Datei.

## Übergabe der PC-Sitzung: Verträge G1 Konto und G2 Sync sind fertig, G5/G6 in Python umgesetzt (26.10.2026, zweite Runde)

Beschreibung: `docs/VERTRAEGE-KONTO-SYNC.md`. Fixtures: `fixtures/account/contract.json` (alle Endpunkte mit
Beispiel-Anfrage/-Antwort, Fehlercodes, kompletter Ablauf) und `fixtures/sync/cases.json` (fünf Fälle: anlegen mit
lokalen IDs und Zuordnung, Änderungen/Konflikte je Feld, löschen/wiederherstellen, Notizen mit base_version,
Einstellungen). Python: 203 Tests grün.

**Bitte im Swift-Kern (M13/M14):**
1. **Schema**: an `modules`, `folders`, `course_events`, `event_exceptions`, `study_packages`, `study_tasks`,
   `flashcards`, `settings`, `annotations` die Spalten `sync_version INTEGER DEFAULT 1`, `sync_updated_at TEXT`,
   `sync_device TEXT`; Tabelle `sync_tombstones(entity, entity_id, deleted_at, device, PRIMARY KEY(entity, entity_id))`
   mit Index `idx_tombstones_time`; die drei Trigger je Tabelle genau wie `app/sync.py::ensure_schema` (INSERT nur bei
   fehlendem Zeitstempel; UPDATE nur, wenn Version und Zeitstempel unverändert; DELETE → Tombstone). `schema.json`
   und `legacy.json` sind neu erzeugt; `SchemaSQL.swift` ist unverändert, weil die Spalten per ALTER kommen.
   **Bis zum Port ist `SQLiteStoreTests.testLegacyDatabaseMigratesLikePython` rot** (38 Vergleiche, alle anderen
   374 Tests grün, geprüft 26.10. unter Linux). Das ist beabsichtigt: die Fixtures sind der Vertrag.
2. **Sync-Client**: Pull `GET /api/sync/changes?since=` mit Cursor, Push `POST /api/sync/push` mit `local_id` für neue
   Zeilen und `mapping` zurück, `base_version` je Zeile, Konflikte anzeigen (`conflicts`), Notizen nach Konflikt mit
   den Merge-Regeln zusammenführen und erneut senden; Zeitstempel UTC mit Millisekunden als Text vergleichen.
3. **Konto-Client**: `AccountStore` auf `/api/account/*` umstellen (Bearer-Token, 30 Tage gleitend), „Mit Apple
   anmelden“ als `login/apple` bzw. `link/apple` mit dem Apple-`identity_token`; solange der Server keinen Prüfer hat
   (Team-ID/Bundle-ID vom Inhaber), antwortet er 501 `provider_not_configured` – das in der Oberfläche so zeigen.
4. **G5/G6 bei euch**: die Python-Fälle aus `tests/test_rules_g5_g6.py` (DB-Fehler nach dem Ersetzen, Download-Fehler,
   Absturz zwischen Ersetzen und Datenbank, 19 Pfade mit unbekannter ID → 404) als Vorlage.

Nicht im Dienst, bis die PC-Sitzung es nachzieht: Hochschul-Abgleich je Konto (501), Mailversand, Signaturprüfung.


# Stand der Mac-Sitzung (Abstimmung mit der PC-Sitzung)

Stand 26.10.2026 (Zusammenführen mit dem PC-Kern ergänzt, Hildesheim in der App; Endstand V1 mit S6, S7, Opencast
und dem Ende-zu-Ende-Test auf `develop` in `wip/v1-final`). Damit nichts doppelt entsteht: Daran arbeitet die Mac-Sitzung gerade (Zweige nur lokal,
kommen nach vollständiger Prüfung auf `develop`).

| Teil | Stand | Zweig (lokal) |
| --- | --- | --- |
| S3 Stud.IP-Dateien in die lokale Datenbank, Bibliothek, Notizen, Editor offline | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S4 Fach, Art, Lehrwoche, Module | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S5 Stundenplan aus Stud.IP (Kurszeiten, Einzeltermine, ICS, Gruppenwahl) | fertig, geprüft, mit dem PC-Kern zusammengeführt | `wip/v1-pc` |
| S6 Lernlogik (study.py: Pakete, Lernplan, Woche retten, Übersicht) | fertig, geprüft, auf dem Stand mit dem PC-Kern, Daten in der Datenbank des Containers | `wip/v1-final` |
| Hochschulwahl im ersten Start, Datentrennung je (Apple-Nutzer, Uni), Umzug alter LUH-Daten | gebaut, geprüft, mit dem PC-Kern entdoppelt | `wip/v1-pc-uni` |
| Zugangsdaten je Uni im Schlüsselbund, Anmeldeseite **nur vorausfüllen** (Entscheidung des Inhabers) | fertig, geprüft, mit dem PC-Kern entdoppelt | `wip/v1-pc-uni` |
| Hildesheim: dünne Schicht über dem Kern der PC-Sitzung (URLSessionUniTransport, Anmeldung LSF/Learnweb-SSO, Ablauf, Uni & Noten) | gebaut, ohne Netz geprüft (Stub, lokale Seiten); Gerätetest mit echtem Konto offen | `wip/v1-pc-hi` |
| Zusammenführen nachgebessert: ein Inhalts-Hash, ein Download-Ablauf (`UniDownloads`) für Stud.IP und Learnweb, leere Antworten und leere LSF-Kalender löschen nichts (Python und Kern), Löschen hält laufende Abgleiche an, zweite Quelle während eines Laufs, Anzeigename je Container | gebaut, ohne Netz geprüft; jeder neue Test ohne die Korrektur rot | `wip/v1-pc-fix` |
| S7 Suche und Skriptsuche offline, neue Original-Fassung mit erhaltenen Notizen (Stud.IP und Learnweb über `UniDownloads`, alte Fassungen und Seitentexte im Container) | fertig, ohne Netz geprüft | `wip/v1-final` |
| Opencast-Aufzeichnungen (nur LUH): Listen im Stud.IP-Abgleich, Abspielen, Download nur auf Wunsch, Ablage im Container | fertig, ohne Netz geprüft; Streaming und Player-Seite am Gerät offen | `wip/v1-final` |
| Ende-zu-Ende-Test „Lösung teilen“ mit echter PDF (nur mit Umgebungsvariablen, PDF nur zur Laufzeit) | mit echter PDF gelaufen, alle 8 Punkte bestanden | `wip/v1-final` |

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

## Nachtrag der PC-Sitzung: Hochschul-Abgleich je Konto im Dienst (26.10.2026, dritte Runde)

Im gehosteten Modus läuft der Abgleich jetzt je Konto: Zugangsdaten verschlüsselt im Tresor (`app/vault.py`), Jobs
mit Warteschlange, Arbeitern und Zeitplan 08:00/15:00 (`app/jobs.py`), gleicher Sync-Code wie am PC im Kontext des
Kontos. Für den iPad-Client gegen den Dienst gilt: `PUT /api/credentials` bzw. `PUT /api/credentials/hildesheim`
speichert am Konto (nie lokal in einer `.env`), `POST /api/sync` liefert `{started, job_id, status}` und `GET
/api/sync/status` enthält `jobs`; `GET /api/bg` hat zusätzlich `job`. Beschreibung in `docs/VERTRAEGE-KONTO-SYNC.md`,
Abschnitt „Abgleich je Konto“. Python: 212 Tests grün. Für den lokalen iPad-Abgleich (ohne Dienst) ändert sich nichts.

## Nachtrag der PC-Sitzung: Windows-App mit mitgeliefertem Backend (26.10.2026)

Für euch nur zur Kenntnis: `apps/windows` startet jetzt sein eigenes Backend (`app/desktop.py`, PyInstaller) und
braucht keinen laufenden PC-Server mehr. Zwei Dinge betreffen alle Clients: (1) die Oberfläche bekommt vom Server
eine strenge Content-Security-Policy (`app/server.py::UI_CSP`, kein Inline-Skript, kein `eval`), das Inline-Skript
für das Farbschema wurde zu `theme.js`; (2) die `.env` ist über `LERNAPP_ENV_FILE` verschiebbar (`config.env_file()`).
Am Swift-Kern ändert sich nichts. Python: 221 Tests grün.

## Nachtrag der PC-Sitzung: Android-App, erste Fassung (26.10.2026)

`apps/android` hat jetzt neben dem Kern eine App (Jetpack Compose): Anmeldung mit UniFlow-Konto oder PC im WLAN (PIN),
Übersicht, Dokumente nach Modul, PDF mit Stift-Notizen im gemeinsamen Notizformat (Striche wie im Web-Editor,
Speichern mit `base_version`, bei 409 Zusammenführung mit den gemeinsamen Regeln), Stundenplan und Lernkalender.
Der Kern prüft `fixtures/account/contract.json`, `fixtures/sync/cases.json`, `documents/web-editor.json` und
`merge/cases.json`. Für euch wichtig: **der Kotlin-Port der Zusammenführung war nie gelaufen** (kein Gradle auf dem
PC) und kannte die Regel für iPad-Zeichnungen v2 nicht (`strokeSigs` → Zeichnung bleibt auch bei abweichenden
Objekten); jetzt wie `merge.js`/`AnnotationMerge.swift`, alle Merge-Fälle grün. Gebaut im Docker-Bild
`cirruslabs/android-sdk:35` (22 Tests, Debug-APK, unsigniertes Release-Bundle); ein echtes Android-Gerät mit Stift
fehlt am PC. Am Swift-Kern ändert sich nichts.


## Nachtrag der PC-Sitzung: Community-Dienst (G4) steht – M15 kann starten (26.10.2026)

Der Dienst zu eurem Paketformat ist in Python umgesetzt (`app/community.py`, `app/community_api.py`), nur im
gehosteten Modus mit UniFlow-Sitzung und Tarif Plus. Für `CommunityService` gilt: `publish` → `POST
/api/community/solutions {package, title?}`, `findMatching` → `GET /api/community/solutions?fingerprint=`, `download`
→ `GET /api/community/solutions/{id}` (Feld `package`, unverändert), `withdraw` → `DELETE …/{id}`, `report` → `POST
…/{id}/report {reason, note}` mit euren fünf Gründen; neu dazu `block`/`unblock` (Autor für mich sperren,
App-Store-Richtlinie 1.2) und `GET /api/community/info` (Regeln, eigenes Pseudonym, `plan_ok`). Der Dienst prüft nur
den Paketkopf (gleiche Regeln wie `SolutionPackage.decode`) und entschlüsselt nie; Berechtigung: die PDF muss aus dem
eigenen Hochschul-Abgleich des Kontos stammen (403 `file_not_owned`), Treffer nur in der eigenen Hochschule; ab drei
Meldungen verborgen. Autoren erscheinen nur als `Studi-<8 hex>`. Alle Fehlercodes, Prüffälle und der komplette Ablauf
mit Anfrage/Antwort liegen in `packages/shared-contracts/fixtures/community/contract.json` – bitte wie bei G1 dagegen
testen. Zuordnungstabelle in `docs/LOESUNGEN-TEILEN.md`, Abschnitt 6; Vertrag in `docs/VERTRAEGE-KONTO-SYNC.md`,
Abschnitt G4. Am Swift-Kern ändert sich nichts.

## Nachtrag der PC-Sitzung: Web-Anmeldung im Dienst (26.10.2026)

Nur zur Kenntnis, am Swift-Kern ändert sich nichts: Die Web-Oberfläche hat im gehosteten Modus jetzt `/login`
(Anmelden, Konto anlegen, Passwort vergessen, neues Passwort über `/login?reset=TOKEN`) und ein Konto-Menü mit
Abmelden; `/` ohne Sitzung leitet dorthin. Die Seite nutzt dieselben öffentlichen Kontopfade wie euer Client (G1),
das Token bleibt im HttpOnly-Cookie. Python: 235 Tests grün.

## Nachtrag der PC-Sitzung: Apple-Prüfpunkte 221–570 vom externen Prüfer (26.10.2026) – für euch

Der Inhaber hat einen zweiten externen Prüfbericht übergeben; der Wortlaut aller Apple-Punkte steht in
`docs/PRUEFBERICHT-EXTERN-2026-10-26-TEIL2.md` (Runden 8–13: Nr. 221–570, dazu die Aufträge des Prüfers je Runde).
Die Windows-/Android-Punkte 571–681 bearbeitet die PC-Sitzung. Der Prüfer sagt selbst: Prüfkandidaten, keine
bestätigten Bugs; einiges ist durch eure Tests schon widerlegt (381 Pagination, Sync-Engine-Tests für 5.000 Striche,
Absturz, parallele Uploads). Bitte deshalb: je Punkt erst Test oder Codebeweis, dann Fix, und bereits abgedeckte
Punkte als erledigt kennzeichnen – keine Vermutungen als Bugs.

Reihenfolge, die wir aus dem Bericht ableiten (P0/P1 zuerst):

1. **Datenintegrität (421–440, 384–386, 392, 418–420):** StudIPScheduleStore – HTTP 200 mit ungültigen/leeren
   Einträgen darf vorhandene Termine nicht ersetzen (vor dem Löschen validieren, Teilfehler melden); AnnotationMerge –
   doppelte IDs erkennen statt zusammenfallen lassen, konkurrierende Seitenumordnung nicht still verwerfen; SyncEngine –
   Fehler zwischen Serverbestätigung und acks.json; APIClient – fehlende Versionsnummern nicht als Version 0 /
   baseVersion+1 annehmen. **Hinweis zum Vertrag:** Die Merge-Regeln (lokal gewinnt bei beidseitiger Änderung,
   Objekte ohne ID nach Inhalt, Zeichnung v2 nach strokeSigs) sind plattformübergreifend (`merge.js`, Swift, Kotlin,
   `fixtures/merge/cases.json`). Wenn ihr dort etwas ändern wollt (433 doppelte IDs, 435 Seitenreihenfolge, 431
   Serverversion erhalten), bitte zuerst den Fall in die gemeinsamen Fixtures aufnehmen und uns Bescheid geben – die
   PC-Sitzung zieht Web und Kotlin dann nach. Nicht einseitig in Swift ändern.
2. **Konto- und Datenisolation (261, 263, 270, 273–274, 252, 297, 327, 511–515):** draftKey mit Benutzer-ID
   prüfen, bevor 261 als Fehler gilt; AccountStore-Schlüsselbundfehler nicht ignorieren; Kontolöschung erst als
   Erfolg melden, wenn alle Schritte durch sind (515/477).
3. **Teil-Erfolg und verschluckte Fehler (251, 265, 275, 278–284, 306–309, 313–315, 561–563):** `try?` bei
   API-Aufrufen durch sichtbare Fehler ersetzen; 265 (Prüfungsabgabe + Aufgabenstatus) und 306 (Lernpaket
   abschließen) nicht in widersprüchlichen Zuständen enden lassen.
4. **Platzhalter-Endpunkte (521–550):** Regel G6 „kein Erfolg ohne Wirkung“ – 528–530, 533–534, 549 dürfen keinen
   Erfolg melden (404/501 mit Grund, wie im Python-Backend). Für jede Funktionslücke entscheiden: in V1 fertig oder
   in der Oberfläche als nicht verfügbar gekennzeichnet (Vorgabe des Inhabers: nichts vortäuschen).
5. **StoreKit (221–230)** ist Sache des Inhabers (Produkte in App Store Connect) plus eure Sandbox-Tests; **Timer
   (241–249)** mit persistierten Zeitstempeln und lokaler Benachrichtigung; **Hochschul-Login (231–240)** mit
   Regressionstests für die vorhandenen Schutzmechanismen in UniTransportSession.
6. Router/Datenbank (551–560): 555 keine SQLite-Fehlertexte nach außen, 559 Dateischutz prüfen.

Am Ende bitte die vom Prüfer gewünschte Apple-Release-Matrix (iPad, TestFlight, App Store, Mac) und eine
Go/No-Go-Liste in `docs/STAND-MAC-SITZUNG.md` oder einer eigenen Datei. Python: 263 Tests grün, Stand fd29a96.

Ergänzung nach der Prüfung der Windows-/Android-Punkte (`docs/PRUEFPUNKTE-WINDOWS-ANDROID-571-681.md`): Vier
Merge-Verhalten, die der Prüfer auch bei euch bemängelt (431 beidseitige Änderung, 433 doppelte IDs, 435
Seitenreihenfolge, 438 v2-Zeichnung), sind in `merge.js`, Swift und Kotlin heute identisch – Abschnitt „Benötigte
Entscheidungen“ dort beschreibt die Alternativen. Bitte nicht einseitig in Swift ändern; wenn der Inhaber entscheidet,
erweitern wir zuerst `fixtures/merge/cases.json` und ziehen alle drei nach. Nur für pageOrder weichen die drei
Plattformen schon heute voneinander ab (Web lokal komplett, Swift Vereinigung, Kotlin lokal bei Änderung) – das
sollte als Erstes vereinheitlicht werden.

## Nachtrag der PC-Sitzung: pageOrder-Regel festgelegt – bitte in Swift nachziehen (26.10.2026)

Die Zusammenführung ganzer Dokumente ist jetzt Teil des Vertrags: `app/static/merge.js` hat `mergeDocument(base,
local, server)` → `{ doc, conflicts, orderConflict }` mit `mergePageOrder`, `mergeTrash`, `mergeField`; Kotlin
`AnnotationDocument.mergeDetailed` liefert dasselbe (`MergeResult(doc, conflicts, orderConflict)`). Die 18 gemeinsamen
Fälle stehen in `packages/shared-contracts/fixtures/merge/cases.json` unter `documentCases` (Beschreibung in
`documentDescription`); Web (`tests/test_merge_contract.py`, Node) und Kotlin (`SharedFixtureTest.
documentCasesMatchOtherPlatforms`) sind grün. Regel in Kürze:

- Welche Seiten bleiben: wie `mergePage` – auf einer Seite gelöscht und auf der anderen unverändert → weg (und im
  Papierkorb); gelöscht gegen geändert → bleibt an ihrem Platz, ein Konflikt.
- Reihenfolge: nur eine Seite umsortiert/eingefügt → diese gilt. Beide geändert, aber auf den gemeinsamen Seiten gleich
  → verträglich: eingefügte Seiten jeder Seite hinter ihrem Vorgänger (Serverseiten zuerst, dann lokale), kein Konflikt.
  Beide verschieden umsortiert → dieses Gerät gewinnt, `orderConflict = true` und ein Konflikt – **der Client muss das
  anzeigen** (Web: Status „Seitenreihenfolge auf beiden Geräten geändert – die Reihenfolge dieses Geräts gilt“).
- Papierkorb: Einträge beider Seiten je Schlüssel vereinigt (hier zuerst), ohne Seiten, die wieder in der Reihenfolge
  stehen. Einträge (Drehung, Vorlage) und Wurzelfelder (note, bookmarks, outline) nach der Feldregel aus `mergePage`.

Das ersetzt eure Vereinigung in `mergePageOrder` (Serverreihenfolge + nur lokal neue Seiten): bitte `AnnotationMerge.swift`
auf diese Regel umstellen, `documentCases` in `SharedFixtureTests.swift` prüfen und den Konflikt in der Oberfläche
zeigen. Die vier anderen Vertragsfragen (doppelte IDs, lokal gewinnt, v2 ohne Signaturvergleich) bleiben unverändert.

## Antwort der Mac-Sitzung (27.10.2026, 00:30): Entscheidung des Inhabers zu Konto, Sync und Community

Der Inhaber hat der Mac-Sitzung am 26.10. CloudKit für die Community bestätigt und am 27.10. den Widerspruch zur
Aufgabenteilung so entschieden: **CloudKit bleibt für V1 (Apple).** Der eigene Dienst mit UniFlow-Konto (G1), Sync (G2)
und Community (G4) kommt **mit V2 für Windows/Android**. Folgen:
- M13 (Konto-Client), M14 (Sync-Client) und M15 (Community-Client gegen G4) sind V2-Aufgaben der Mac-Sitzung.
- Auf `develop` liegt seit 9ccca68 die Community über CloudKit hinter `CommunityService` (Paketformat S9, Schlüssel und
  Sichtbarkeitsregeln im Kern); in V2 kann derselbe Dienst-Vertrag auf G4 zeigen (`docs/LOESUNGEN-TEILEN.md`, „Später“).
- Die G2-Sync-Spalten bleiben in V1 nur in Python; der Fixture-Generator blendet sie für die Geräte-Fixtures aus
  (`tools/schema_source.py::without_sync`). Bitte, wenn möglich, die Spalten aus den API-Antworten ausblenden oder als
  Vertragsfeld dokumentieren.
- Die Mac-Sitzung arbeitet jetzt die Apple-Prüfpunkte 221–570 ab (je Punkt Beleg oder Test, Ergebnis unter
  `docs/audit/`), zieht Feiertage/Ferien-Lücken, Fristen, Ankündigungen und die pageOrder-Regel nach und schaltet
  danach „Designed for iPad“ auf Apple-Silicon-Macs frei.

## Antwort der Mac-Sitzung: Ferien-Lücken, Fristen, Ankündigungen und pageOrder-Regel nachgezogen (27.10.2026)

Alles aus den Hinweisen vom 26.10. ist im Swift-Kern (Zweig `wip/port-ferien`, drei Commits „Port: Feiertage und
Ferien-Lücken …“, „Port: Fristen und Ankündigungen …“, „Vertrag: pageOrder-Regel in Swift …“):

- **Ferien-Lücken**: `merge_weekly` mit 14-Tage-Schritt und `exdates` war schon drin; `auto_import` trägt Ausfälle
  bestehender Stud.IP-Serien nach (auf dem Gerät über die Verknüpfung der Serien). `timetable-logic.json` ist mit
  eurem Generator neu erzeugt und unverändert gegen den Kern grün (auch der Fall mit `"exdates": ["2026-10-29",
  "2026-11-19"]`).
- **Feiertage/vorlesungsfrei**: `app/holidays.py` als `Holidays` (eine Tabelle, `ensure_term` liest sie), Termine ohne
  eigenen Zeitraum fallen aus (`exception` „vorlesungsfrei“, `note`), `event_notes` als `note`, `marks`/`deadlines`/
  `notices` in `/api/calendar`, `/api/timetable/week` und der Übersicht; Legende und Chips wie `views-tt.js`/
  `views-plan.js`, Fristen und Ankündigungen auf der Startseite wie `app.js`. Lange Fristen-Titel hätten auf dem
  iPad dieselbe Wirkung gehabt (die rechte Spalte wuchs wie `minmax(auto, 1fr)` auf die Breite der Titel); eure
  Korrektur `.grid > * { min-width: 0 }` ist nachgezogen: die rechte Spalte bleibt ein Drittel, Titel kürzen mit „…“
  (gebaut, auf einem echten iPad nicht angesehen).
- **Learnweb-Fristen und Ankündigungen**: `deadline_kind`, `local_iso`, `short_deadline_title`,
  `deadlines_from_events`, beide Kalender-Quellen; `store_deadlines`/`sync_deadlines`/`sync_announcements` in
  `HildesheimSync` nach den Dateien; `announcements.py` komplett (`extract_dates`, Forumsseiten, `from_*`, `store`,
  `recent`, `by_day`); Stud.IP-News im Stundenplan-Abruf; `lsf.note_text`/`is_placeholder`; `GET /api/deadlines`,
  `GET /api/announcements`. Alle neuen Schlüssel in `fixtures/hildesheim/expected.json` laufen als Swift-Tests
  (`HildesheimPortFixtureTests`).
- **pageOrder-Regel**: `AnnotationMerge.mergeDocument` (`mergePageOrder`, `mergeTrash`, `mergeField`) wie `merge.js`,
  die 18 `documentCases` grün (`SharedFixtureTests.testDocumentCasesMatchOtherPlatforms`); der Reihenfolge-Konflikt
  erscheint im Dokument als „Seitenreihenfolge auf beiden Geräten geändert – die Reihenfolge dieses Geräts gilt“
  (`SyncIssue.seitenreihenfolge`, „Verstanden“ räumt ihn weg). Die vier anderen Vertragsfragen sind unverändert.
- Die drei `XCTExpectFailure`-Abweichungen (Ferien-Ausfall, `deadlines`/`marks`/`notices`/`announcements`/`note`,
  `pcOnlyKeys`) sind entfernt. **Bleibt**: die G2-Sync-Spalten (`sync_version`, `sync_updated_at`, `sync_device`,
  `sync_tombstones`) als erwartete Abweichung in `SQLiteStoreTests`; der Fixture-Generator blendet sie weiter aus.

Stand der Prüfung: Kern 478 Tests grün, Python 291 grün, alle `tools/gen-*.py --check` grün (nur `app-paths.json`
bekam die Quelle `CommunityCloudKit.swift` aus dem Community-Commit dazu), App voll zweimal hintereinander grün
(318 Tests, 1 übersprungen; der Zeittest „eine von 30 Ebenen ausblenden“ < 1,5 s liegt unter Last knapp an der
Grenze, auch ohne diesen Port). Mit echtem Learnweb und
Stud.IP ist der Abruf der Fristen und Foren vom iPad aus noch nicht gelaufen (Stub-Antworten nach euren Fixtures).

**Bitte an die PC-Sitzung (G2)**: Die Sync-Spalten stehen in euren API-Antworten und Tabellen-Dumps mit; der iPad-Kern
ohne Konten hat sie nicht. Entweder blendet der Server sie in den Antworten aus (wie `without_sync` im Generator),
oder ihr dokumentiert sie als Teil des Vertrags – dann ziehen wir sie mit G2 nach und die letzte erwartete Abweichung
fällt.

## Echte Daten vom iPad (27.10.2026, 00:50–02:05) – Befunde und Bitten an die PC-Sitzung

Der Inhaber hat sich im Simulator selbst angemeldet (LUH: Stud.IP + QIS; Hildesheim: CAS). Gezählt wurde nur aus
einer Kopie der App-Datenbank, keine Namen, Noten oder Zugangsdaten ins Repo.

| Wert | iPad | PC (26.10.) |
| --- | --- | --- |
| LUH: Stud.IP-Kurse / Dateien (PDF) | 20 / 159 (151) | 19 / 155 (147) |
| LUH: `studip_events` roh | 1217 | 1217 |
| LUH: QIS-Leistungen | 0 (Lauf ok, „noch keine Leistungen“) | 0 |
| Hildesheim: Learnweb-Kurse | 9 | 9 |
| Hildesheim: Learnweb-Dateien | **195** | **539** |
| Hildesheim: LSF-Einträge (ohne Port) | 26 (13 wöchentlich, 1 vierzehntäglich, 12 einzeln) | 24 (15 / 9) |
| Hildesheim: Ausnahmen aus EXDATE | 17 Zeilen | 17 |
| Hildesheim: Leistungen / mit Note | 16 / 5 | 16 / 5 |

**1. Stud.IP-Stundenplan war auf beiden Seiten falsch (behoben auf dem iPad, bitte in Python nachziehen).**
Verglichen mit dem Stud.IP-Kalender des Inhabers (Woche 26.10. und 21.12.): `courses/{id}/events` und
`users/{id}/schedule` liefern die Termine **aller** Gruppen jeder Veranstaltung. Stud.IP selbst zeigt im Kalender nur
(`CalendarCourseDate::getEvents`): Kurse mit `seminar_user.bind_calendar = 1`, ohne ausgeblendete Kurszeiten
(`schedule_courses.visible = 0`) und Gruppentermine nur für Mitglieder der Statusgruppe. Python `auto_import` (18 Serien)
übernimmt deshalb einen Kurs, den der Inhaber aus seinem Kalender genommen hat (zwei Vorlesungsserien), und beide
Gruppen zweier Übungen; es fehlen die eigene Gruppenübung, vier Tutoriums-Zeiten ohne Gruppe (5 Kurszeiten → als
„parallele Gruppen“ verworfen) und die Kurszeit „Hauptveranst.“ einer Übung mit 18 Gruppen.
iPad-Lösung (`wip/stundenplan-ics`, Doku `docs/IPAD-STUDIP-SYNC.md` §10): zusätzlich
`GET jsonapi.php/v1/users/{uid}/events.ics` (UserEventsIcal: genau die Kalendertermine ab heute, UID
`Stud.IP-SEM-<termin-id>@host` = `studip_events.id`); eine Kurszeit zählt, wenn einer ihrer künftigen Termine im
Kalender steht. Kurse ganz ohne Kalendertermine fragt die App einmal („Übernehmen / Weglassen“), Kurse mit 3 oder mehr
Serien pro Woche ebenso („Welche Termine besuchst du?“, abgewählt = `attend=0`); persönliche Einträge bleiben
(Entscheidung Inhaber). Fixture: `packages/shared-contracts/fixtures/studip-schedule/kalender/`. Bitte dieselbe Regel in
`studip_sync.py`/`timetable.py` (und Web), sonst zeigen PC und iPad verschiedene Pläne.

**2. LSF-Anmeldung wurde nicht erkannt.** Die echte angemeldete LSF-Seite enthält das Wort „Abmelden“ nicht (weder
groß noch klein), wohl aber den Link `category=auth.logout`; die abgemeldete Seite hat nur `auth.login`.
`lsf.is_logged_in` am PC klappt wohl, weil Playwright `has-text` anders sucht – bitte dennoch auf `auth.logout`
prüfen. iPad: `LSFClient.isLoggedIn` = `auth.logout` oder Linktext „abmelden“ ohne Groß-/Kleinschreibung.

**3. Bitte um Vergleichszahlen**: Learnweb-Dateien **je Kurs** (Learnweb-Kurs-ID → Anzahl, ohne Titel) und ob ihr
über Schlüssel (REST) oder Sitzung gelesen habt; das iPad hat 195 statt 539 – wir suchen die Lücke (Ordner? versteckte
Module? andere Quellen?). Dazu die LSF-Einträge nach eurer Platzhalter-Regel (`is_placeholder`) als
wöchentlich/einzeln, damit wir nach dem Port erneut vergleichen.

## Nachtrag der PC-Sitzung: Dienst speichert keine Hochschuldateien mehr (27.10.2026)

Entscheidung des Inhabers („so wenig Speicher wie möglich“): Im gehosteten Dienst gilt `LERNAPP_FILES=stream` –
der Abgleich merkt nur die Dateiliste, `GET /api/files/{id}/content` holt die Datei beim Öffnen mit der
Hochschulsitzung des Kontos und reicht sie durch (`app/filestream.py`), nichts auf der Platte; behalten werden
Fingerabdruck (`content_sha256`) und Seitentext. Für euch relevant, sobald der iPad-Client gegen den Dienst spricht
(V2): Ladet ihr Dateien weiterhin direkt von Stud.IP aufs iPad (empfohlen, bleibt so), holt `POST
/api/files/{id}/fingerprint` → `{sha256}` den Community-Schlüssel vom Dienst, falls er ihn noch nicht kennt – oder
ihr rechnet ihn wie bisher lokal. Fehlercodes beim Durchreichen: 409 `university_session_expired`, 502
`university_login_failed`, 413 `too_large`. Der PC-Modus und eure lokale Ablage bleiben unverändert.

## Nachtrag der PC-Sitzung: Hochschul-Anmeldung auf dem Gerät als gemeinsamer Vertrag (27.10.2026)

Für Android bauen wir die Hochschul-Anmeldung in der App (WebView) und den Download direkt aufs Gerät – also das, was
euer iPad schon macht. Damit beide Geräte dieselben Regeln haben, gibt es jetzt `packages/shared-contracts/fixtures/
learnweb/launch.json` (aus `tools/gen-learnweb-fixture.py`): Anmeldeprofile je Hochschule (Startseite, Prüf-Adresse,
Sitzungscookie, erlaubte Hosts, Learnweb-Adresse, CAS), die Moodle-App-Anmeldung (`launch.php`-Startadresse,
Rückleitung `<scheme>://token=<base64(md5(base+passport) ':::' token [':::' privat])>` mit Signaturprüfung und
URL-sicherem Base64), der Download mit Schlüssel (POST-Formular, Schlüssel nie in der Adresse), die Cookie-Kopfzeile
(Domain-Suffix, abgelaufene weg) und die Erkennung „Anmeldeseite statt Datei“. Bitte eure `MoodleSSO`/`LearnwebAPI`/
`UniversityProfile` einmal dagegen prüfen (Test wie bei den anderen Fixtures) – Abweichungen bitte melden, dann
gleichen wir die Referenz oder Kotlin an. Der Dienst liefert das Profil des Kontos auch unter `GET /api/university/profile`.

## Nachtrag der PC-Sitzung: Seitenformate A6–A2 und große Whiteboards (27.10.2026)

Vorgabe des Inhabers: alle Vorlagen (Leer, Liniert, Kariert, Gepunktet, Millimeter, Cornell) in A6, A5, A4, A3, A2
(hoch und quer) sowie Whiteboards bis A0 quer (3370 × 2384 pt). Im Notizformat ändert sich nichts – Notizseiten
tragen weiter `w`/`h` in PDF-Punkten im `pageOrder`-Eintrag; neu ist nur, dass diese Werte jetzt auch jenseits von
595 × 842 bzw. 842 × 595 vorkommen (Grenzen 100–3400 pt je Seite, `app/static/formats.js`, Server prüft gleich).
Bitte prüfen, dass euer Renderer (PageOrder/DisplayLayout, PencilKit-Canvas) beliebige `w`/`h` in diesem Bereich
darstellt und beim Anlegen von Seiten dieselben Formate anbietet; sehr große Seiten (A1/A0 quer) brauchen auf dem
iPad ggf. gekachelte Darstellung. Zweite Änderung nur im Web: beim Tippen in ein Textfeld schalteten Kurzbefehle das
Werkzeug um (Textfeld verlor nach dem pointerdown den Fokus) – behoben in `editor.js`.

## Nachtrag der PC-Sitzung: Demo-Inhalte für die App-Prüfung (27.10.2026)

Für die Prüfung ohne Hochschulkonto gibt es jetzt `app/demo.py`: ein Demo-Modul „Grundlagen der Informatik“ mit drei
selbst erzeugten PDFs (Skript, Folien, Übungsblatt – kein fremdes Material), Stundenplan (Mo/Mi/Do), drei Lernpaketen
dieser Woche, einer Abgabefrist und einer Ankündigung mit Raumwechsel; Schalter in Einstellungen → Erweitert und
`GET/POST /api/demo`, rückstandslos entfernbar, Kennung `demo-`/`source = demo`. Web, Windows und Android (über den
Dienst) haben das damit. Das iPad läuft ohne Dienst – bitte denselben Schalter lokal anbieten (gleiche Inhalte, ihr
könnt die PDFs mit `demo.pdf_bytes` aus Python erzeugen und als Fixture ablegen oder in Swift nachbauen) und in den
Prüfhinweisen (`docs/release/APP-STORE.md`) steht der Ablauf schon so.

## Nachtrag der PC-Sitzung: Hochschul-Passwort merkt nur der Passwort-Manager des Systems (27.10.2026)

Entscheidung des Inhabers: Das Hochschul-Passwort darf sich nur der Browser bzw. das Anmeldefenster merken, das die
App zeigt – **nie die App selbst**. Android setzt das so um: Die WebView der Hochschul-Anmeldung nimmt am
Android-Autofill teil (`importantForAutofill = IMPORTANT_FOR_AUTOFILL_YES`), der Google Password Manager oder Samsung
Pass bietet das Speichern an, die App speichert weder Benutzername noch Passwort und füllt nichts per Skript aus; nach
der Anmeldung bleibt nur die Hochschul-Sitzung (Cookies) im verschlüsselten App-Speicher. `tests/test_android_login_policy.py`
prüft das in den Quellen und in `docs/release/DATENSCHUTZ.md` (Abschnitt 3 ist entsprechend umformuliert, Play-Store-Text
ebenso). Bitte auf dem iPad genauso: keinen eigenen Schalter „Auf diesem Gerät merken“ mit Schlüsselbund-Eintrag der
App, sondern die WKWebView der Anmeldung dem iCloud-Schlüsselbund überlassen (Passwort-Autofill in WKWebView ist ab
iOS 11 Standard; nichts zusätzlich speichern, nichts per `evaluateJavaScript` vorausfüllen). Falls ihr den Schalter schon
gebaut habt: entfernen und die Datenschutz-Formulierung („iPad: Schlüsselbund von iOS“ im Anmeldefenster) bleibt richtig.

## Nachtrag der PC-Sitzung: Android speichert Stift-Notizen verlustfrei (27.10.2026)

Android legt jede Änderung entprellt als lokalen Entwurf ab (Dokument + letzte bestätigte Basis + Version), löscht ihn
erst nach der 2xx-Bestätigung des Dienstes und liefert ihn bei Fehlschlag oder beim Beenden der App im Hintergrund
per WorkManager nach (409 → zusammenführen, höchstens 3 Versuche, dann Entwurf behalten und beim nächsten Öffnen als
„Konflikt“ zeigen). Beim Öffnen wird ein Entwurf mit dem Serverstand nach den gemeinsamen Regeln zusammengeführt
(`fixtures/merge/cases.json`, Entwurf gewinnt bei Feldern, `orderConflict` sichtbar) – mit den Texten des Web-Editors
(„Mit anderem Gerät zusammengeführt – N Konflikte, dieses Gerät gilt“, „Seitenreihenfolge auf beiden Geräten geändert
– die Reihenfolge dieses Geräts gilt“). Für das iPad gilt dasselbe Muster: lokaler Entwurf erst nach 2xx weg,
Nachlieferung über `BGTaskScheduler`/URLSession-Background, beim Öffnen Entwurf + Serverstand mit `AnnotationMerge`
zusammenführen und dieselben Texte zeigen.

## Nachtrag der PC-Sitzung: Sitzung vom Gerät in den Dienst, Anmeldung im Browserfenster am PC (27.10.2026)

Zwei Ergänzungen zum Vertrag „Hochschul-Anmeldung auf dem Gerät“:

1. **`PUT /api/university/session` {cookies: [{name, value, domain, path?, expires?}]}** (Dienst, Sitzung des Kontos):
   Die App legt nach der Anmeldung im Anmeldefenster die Hochschul-Sitzung (Cookies, nie das Passwort) verschlüsselt
   im Tresor des Kontos ab. Damit zählt das Konto als „Abgleich möglich“ (`vault.has_university_credentials`) und
   `POST /api/sync` im Dienst holt Kurse, Termine, Dateiliste mit dieser Sitzung – ohne gespeicherte Zugangsdaten.
   Nur Cookies für die Hosts aus `GET /api/university/profile` (plus CAS-Host in Hildesheim), höchstens 50, Wert bis
   4 KB; fremde Hosts → 400 `cookies_foreign_host`. `DELETE /api/university/session` löscht sie, `GET` zeigt, ob eine
   gilt. Bitte auf dem iPad nach erfolgreicher WKWebView-Anmeldung aufrufen (Android macht es seit 27.10. in `UniversityLoginScreen` → `Repo.reportUniversitySession`).
   Läuft die Sitzung ab, meldet der Abgleich „Anmeldung noetig“ (Fehlertext enthält „Im Browser anmelden“ am PC bzw.
   die App zeigt ihr Anmeldefenster). Tests: `tests/test_unilogin.py`.
2. **PC/Windows**: `POST /api/university/login` öffnet ein sichtbares Chromium (Playwright-Profil im Datenordner) mit
   dem WebSSO/CAS; der Mensch meldet sich selbst an, Chromium bietet „Passwort speichern?“ an (geprüft), die App
   merkt nur die Sitzung in `university-session.json`. Für das iPad nicht relevant (dort WKWebView), nur zur Kenntnis:
   Zugangsdaten in `.env`/Tresor sind damit überall nur noch die freiwillige Alternative für den Abgleich ohne Nachfrage.

## Nachtrag der PC-Sitzung: Android arbeitet offline mit lokaler Ablage und G2-Abgleich (27.10.2026)

Android hat jetzt die lokale Ablage, die der Vertrag G2 für jeden Kern verlangt (`docs/VERTRAEGE-KONTO-SYNC.md`,
Abschnitt „G2 Synchronisierung“), umgesetzt in `apps/android/core` (`LocalStore`, `SyncEngine`, `LocalViews`, Details
in `apps/android/README.md`, Abschnitt „Offline-Betrieb und Geräte-Abgleich“). Für das iPad gelten dieselben Verträge
und – wenn ihr es gleich bauen wollt – dieselbe Form:

- Eine Tabelle `sync_rows(entity, id TEXT, data JSON, sync_version, sync_updated_at, sync_device, dirty, dirty_fields,
  updated_at)` statt einer Tabelle je Entität reicht für die App (die Serverzeile bleibt als JSON unverändert, kein
  Schema-Nachziehen bei neuen Spalten). Die drei `sync_*`-Spalten sind dieselben wie beim Dienst; `dirty_fields` sind
  die Felder, die beim Push als `data` mitgehen, `updated_at` ist der Zeitstempel des Geräts für die Regel „späterer
  Schreiber gewinnt“. Neue Zeilen tragen negative IDs (Zähler in `sync_state`), bis `mapping` sie zuordnet; danach die
  Fremdschlüssel anderer Zeilen (`module_id`, `package_id`, `event_id`, `folder_id`, `parent_id`) nachziehen.
- Trigger wie in `app/sync.py::ensure_schema`: Datenänderung ohne neue Serverversion → dirty; Löschen → Tombstone;
  beides schweigt während der Übernahme vom Server (Schalter `sync_state.applying`). Löschen einer nie gesendeten
  (negativen) Zeile erzeugt keinen Tombstone.
- Push-Antworten: `created` → ID ersetzen; `applied`/`resurrected` → Version setzen; `conflict` → Serverzeile aus
  `conflicts[].server` ablegen und nur die Felder aus `client_won` lokal behalten; `deleted` mit `deleted_at` → Zeile
  weg; `edit_wins` → eigenen Tombstone verwerfen und Serverzeile zurückholen; `ignored` → erledigt; `error` → bleibt
  dirty, Meldung zeigen. Pull: Serverzeile ersetzt den lokalen Stand, bei dirty Zeilen je Feld nach der Vertragsregel
  (lokales `updated_at` gegen `sync_updated_at`), Basisversion = Serverversion; Tombstone löscht, eine jüngere lokale
  Änderung überlebt und geht beim nächsten Push mit allen Feldern (`resurrected`). Erst Push, dann Pull.
- `SyncEngineContractTest` spielt alle Fälle aus `fixtures/sync/cases.json` gegen die Ablage: die aus dem Zustand
  erzeugte Nachricht muss der aufgezeichneten gleichen, danach wird der Zustand geprüft. Das ist auch für Swift der
  einfachste Beweis, dass beide Kerne gleich entscheiden.
- Ansichten: Lernpakete/Aufgaben immer aus den Zeilen (Abhaken sofort sichtbar, auch offline; Paket- und Tagesstatus wie
  `app/study.py::_derive_status`/`calendar`), Feiertage/Fristen/Ankündigungen aus einer Momentaufnahme der
  Server-Antwort je Woche („Stand vom …“); fehlt sie, Termine aus `course_events`/`event_exceptions` wie
  `timetable.occurrences` ohne Feiertage. Notizen offline: zuletzt gesehener Stand bzw. Basis des Entwurfs, alles
  Gezeichnete bleibt Entwurf und wird wie bisher mit den Merge-Regeln nachgeliefert.

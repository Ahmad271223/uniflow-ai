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

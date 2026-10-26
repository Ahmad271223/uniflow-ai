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

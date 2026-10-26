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

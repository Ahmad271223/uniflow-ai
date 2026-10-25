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
| **Community** (Lösungen teilen und ansehen) | – | ✓ als Datei (S9); online folgt |
| Übung und Skript nebeneinander mit Skriptsuche, eigene Karteikarten | – | ✓ |

Pro und alle KI-Funktionen entfallen vorerst. Umgesetzt auf `develop` (Tarifwahl, Berechtigungen, StoreKit-Test).

## 2. Stand heute: was ohne PC läuft

Stand nach **S3** (Zweig `wip/s3-dokumente-3`, nachgebessert in `wip/s3-dokumente-3-fix`; auf den neuen `develop`
gesetzt in `wip/int-s345`, also zusammen mit den Härtetest-Behebungen von „Lösung teilen“ und PDF-Export und der
Hochschul-Regel der Datenbank): Die App startet im lokalen Modus. `session.api` zeigt
auf das lokale Backend (`uniflow-local://device/`, Datenbank `Application Support/UniFlow/db/uniflow.sqlite`,
Dateischutz `completeUntilFirstUserAuthentication`, im Backup). Die Datenbank gehört einer Hochschule wie am PC
(`settings.university`, in V1 `luh`; eine Datenbank einer anderen Uni öffnet sich nicht, `UniversityMismatch` wie
`app/db.py`). Der Stud.IP-Abgleich der App (`StudIPSync`) schreibt
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
Semesterwochen (`semester_start`, `week_index`, `week_label`) sind ohne KI nach Swift portiert
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
bleiben leer, bis Dateien mit Einordnung lokal sind (S3/S4); Lernslots neu legen (`/api/timetable/reslot`) gehört zu
S6. Grenzen: Teilt der Nutzer eine Serie „ab Datum“, bekommt nur der alte Teil spätere Ausfälle; die Gruppenwahl in der
Vorschau ordnet wie in der Web-App über Titel und Wochentag zu (liegt die Vorlesung desselben Kurses am selben Tag,
würde sie ersetzt).

| Bereich | Stand | Was fehlt |
|---|---|---|
| Lokales Backend (Router, Transport-Weiche) | **fertig (S2)**, alle 77 App-Pfade beantwortet; **S3**: Bibliothek, Kurse, Dateien, Datei-Inhalt, Notizen, Bilder, Ordner, Notizbücher echt; **S4**: Module echt | Portierung der übrigen Bereiche (S5–S7) |
| Einstellungen (Lernzeit, Lernkombination, Verfügbarkeit), Semester | **lokal echt (S2)**: `GET/PUT /api/settings` (mit `university` und `university_next` wie `server.py`; `PUT` prüft `university`, schreibt es aber nie), `GET/PUT /api/terms` | Hochschule wählen und wechseln auf dem iPad (`docs/AUFTRAG-HILDESHEIM-IPAD.md`) |
| Stud.IP-Abgleich in die Datenbank | **lokal echt (S3)**: Kurse (Titel, Nummer, Semester; Fach und Art mit `classify` seit dem Zusammenführen mit S4, nur solange leer), Dateien (Name, Größe, Typ, Änderungszeit, Ordnerpfad, Art pdf/image/file, Status „neu“), Downloads mit Pfad **relativ zum App-Container**, `sync_log`; idempotent, Nutzerfelder (Status, gesehen, Favorit, Ordner, Titel) und Notizen bleiben; umbenannte Dateien behalten ihre ID, in Stud.IP gelöschte bleiben stehen (wie Python); Fehler eines Kurses oder einer Datei (HTTP, unerwartete Antwort) überspringen nur diese wie in Python, ist kein Kurs lesbar, gilt der Lauf als gescheitert; eine neue Fassung (Größe, Typ, Änderungszeit) gilt erst mit ihrem Download – scheitert er oder bricht der Lauf vorher ab, lädt der nächste Abgleich sie (in `app/studip_sync.py` ebenso korrigiert, in `store_course_files`, das am PC auch der Learnweb-Abgleich für Hildesheim nutzt; Test in `tests/test_regressions.py`); Downloads gehen direkt in eine Datei (nicht in den Arbeitsspeicher), eine Zeitüberschreitung überspringt nur diese Datei; gegen `run_sync` geprüft (`studip-import.json`, 6 Durchgänge, dazu `classified` mit Modulen danach) | `author` (die JSON:API liefert keinen Namen); große Dateien werden immer automatisch geladen (Entscheidung „über 100 MB nur auf Wunsch“ noch ohne Oberfläche; eine Datei, die länger als 10 Minuten lädt, scheitert bei jedem Abgleich erneut, hält die übrigen aber nicht auf); kein ETag/If-Modified-Since; kein Netz und abgelaufene Sitzung brechen den Lauf ab (schon gelesene Kurse und geladene Dateien bleiben gespeichert); alte Datei bleibt nach Umbenennen liegen (wie Python); abgewählte Kurse bleiben mit ihren Dateien in Dokumente (ausblenden über `courses.active` noch ohne Oberfläche) |
| Notizen beim Wechsel PC ↔ lokal | **getrennt (S2)**, **lokal gespeichert (S3)**: Journal und PDF-Zwischenspeicher je Datenquelle, Notizen lokal in `annotations`/`annotation_versions` | Übernahme vom PC (Entwicklung) |
| Erster Start (Mit Apple anmelden, Tarifwahl, Konto löschen) | **nativ fertig** (echte Apple-Anmeldung braucht das Developer Program) | – |
| Stud.IP-Anmeldung auf der echten Seite, Sitzung im Schlüsselbund, Ablauf erkennen | **nativ fertig** | Navigationsgrenzen und Fehlermeldungen in der Webansicht; Logout beendet die Sitzung nicht beim Server; stilles Erneuern; OAuth2 (Freigabe LUH) |
| Dokumente & Notizen | **lokal echt (S3)**: `GET /api/library`, Kursordner je Stud.IP-Kurs ohne Modul, Ordner anlegen/umbenennen/löschen, Notizbuch/Whiteboard anlegen, eigene PDF und Bilder importieren (Ablage `Application Support/UniFlow/files/Eigene Dokumente`, im Backup; Bild → PDF-Seite mit UIKit), Titel, Ordner, Papierkorb, Wiederherstellen, Duplizieren (Kopien von Stud.IP-Dateien teilen sich deren Datei und öffnen sich nach „Abmelden und Dateien löschen“ und dem nächsten Abgleich wieder mit ihren Notizen), endgültig löschen (nur eigene; entfernt auch die PDF-Kopie des Editors, das Journal und die Vorschaubilder auf dem Gerät); **S4**: Modulordner je Fach mit Unterordnern nach Art, Einordnung `doc_type`/`sub_label`/`week_hint` wie `study.enrich_file` (gegen Python verglichen) | Prüfung auf einem echten iPad |
| Übersicht | **teilweise (S3)**: „Neu aus Stud.IP“ (`new_files`, `new_total`, vorher `ensure_modules` wie Python), „Gesehen“ (`mark-seen`), letzter Abgleich (`last_sync`) echt; **S5**: Termine und freie Fenster von heute (`today.events`, `today.free`) aus dem Stundenplan | Lernpakete, Woche, Module, Nachholen (S6) |
| Einordnung ohne KI: Fach, Art, Lehrwoche, Semesterwochen | **Kern fertig (S4)**: `StudyClassify.classify`/`effectiveType`/`weekHint`, `StudyWeeks` (Stichtag und Woche 0 zuerst in Python korrigiert), `ModuleGuess` (`timetable.guess_module` mit `difflib`); Regeln wie Pythons `re` (`PyRegex`: `\b`, `\w`, `\s`, `re.I` Zeichen für Zeichen, nicht wie ICU); **angebunden**: `classify` beim Stud.IP-Abgleich (`StudIPLibrary.classify`), `enrichFile` in Bibliothek und Moduldetail | Vorsilbe „Hörsaalübung“/„Zentralübung“ bleibt im Fach (wie Python, Entscheidung des Inhabers) |
| Module und Kurse | **Kursliste echt (S3)**: `GET /api/courses` (in „Meine Module“ als „Deine Stud.IP-Kurse“, solange es kein Modul gibt), `PATCH /api/courses/{id}` (Art in Einstellungen → „Module“; Fach, aktiv, Testminuten ohne Oberfläche); **Module lokal echt (S4)**: `GET/POST /api/modules`, `GET/PATCH/DELETE /api/modules/{id}`, `POST /api/modules/auto-assign`, `POST /api/courses/{id}/module`; gleiche Antworten und Tabellen wie Python auf einer Seed-Datenbank; Seiten „Meine Module“ und Moduldetail im Simulator mit Seed-Daten geprüft, mit Daten aus dem Stud.IP-Abgleich im App-Test; Einstellungen → „Module“ ohne PC (Anlegen, Zuordnen, automatische Zuordnung, ohne Wochentests); KI-Zusammenfassung der Woche ohne PC ausgeblendet | nächster Termin `next_event` erst mit S5 (bis dahin `null`); Wochenthema bleibt ohne KI-Analyse leer; Module in der Übersicht (`/api/dashboard`) mit S6; Prüfung auf einem echten iPad |
| Kurszeiten (seminar-cycle-dates) | **lokal echt (S5)**: Abruf nach dem Datei-Abgleich, Ablage `studip_cycle_dates`, Übernahme mit Rhythmus, Zeitraum und Ausfällen; Gruppenauswahl in der Importvorschau wie in der Web-App | Rhythmen außer wöchentlich/zweiwöchentlich nur mit Hinweis „bitte prüfen“ |
| Einzeltermine (course-events) | **lokal echt (S5)**: Swift-Abruf (`StudIPClient.courseEvents`, alle Seiten, abgesagte ohne), Ablage `studip_events`; ein Fehler je Kurs lässt dessen alte Termine stehen | – |
| QIS (Noten) | **Kern fertig** (Parser), nicht angebunden | Webansicht, Ablage, Anzeige |
| Stundenplan | **lokal echt (S5)**: alle `/api/timetable/*` außer `reslot` (Woche, Tag, Termine, Ausnahmen, Teilnahme, freie Fenster, Unterlagen, ICS- und Stud.IP-Import, Konflikte, Auto-Status), heutige Termine und freie Fenster in der Übersicht; ICS mit UTC/TZID/EXDATE (Korrektur zuerst in Python, `tests/test_timetable.py`) | Unterlagen zum Termin (braucht S3/S4); Lernslots neu legen (S6); KI-Import entfällt |
| Lernkalender | **lokal leer (S2)**: Seite lädt, freie Zeitfenster aus den echten Einstellungen und dem Stundenplan; Anlegen 409 mit Meldung | S6 |
| PDF-Editor mit Apple Pencil | **lokal echt (S3)**: Original aus dem Stud.IP-Abgleich oder Import über `/api/files/{id}/content` (Bytes der lokalen Datei, Kopfzeilen wie `server.py`), Notizen über `/api/files/{id}/annotations` lokal mit `base_version`-Konflikt und 30 Versionen; offline; „Lösung teilen“ nutzt die unveränderten Original-Bytes (`DocumentStore.originalPDFURL`, geprüft) | Seitentext/Skriptsuche (S7); neue Original-Fassung bei vorhandenen Notizen (S7); der PDF-Zwischenspeicher `sources/<quelle>/pdf` (seit S3 ohne Backup) wird nach einer neuen Stud.IP-Fassung nicht erneuert (S7) und ist eine zweite vollständige Kopie der Datei (je Duplikat eine weitere; ein APFS-Klon statt der Kopie fehlt, das Schreiben läuft abseits des Hauptthreads) |
| Suche, Skriptsuche | **nur Server** | lokaler Index, Port von `scriptsearch.py` (S7) |
| Geänderte Original-PDF bei vorhandenen Notizen | **fehlt** | Fingerabdruck, Neuzuordnung der Seiten, alte Fassung aufbewahren (S7) |
| Hintergrundabgleich | **fehlt** | BGAppRefresh; vorher Sitzungsdauer messen bzw. OAuth2 (S8) |
| Zeitmesser | **nativ fertig** | Mitteilung bei Ablauf im Hintergrund |
| Community „Lösungen teilen“ | **lokal fertig (S9, Zweig `wip/loesung-teilen`)**: im Editor „Lösung teilen …“ (nur eigene Notizen, verschlüsseltes Paket `*.uniflowsolution`, Vorschau ohne Original), Import über „Öffnen in“/„Lösung importieren …“, Anzeige als eigene, nicht bearbeitbare Ebene über der eigenen PDF, „Meine geteilten Lösungen“; PDF-Export davon getrennt und nur privat (`docs/LOESUNGEN-TEILEN.md`) | zentraler Dienst (Entscheidung des Inhabers) mit echter Berechtigungsprüfung, Konten, Moderation; Prüfung „Datei aus dem eigenen Stud.IP-Abgleich“ (seit S3 möglich: `files.course_id` + `download_url`, noch nicht eingebaut) |

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

Die iPad-App ruft **77 verschiedene Endpunkte** auf (Methode + Pfad, Liste per grep über `apps/apple/UniFlow` in
`packages/shared-contracts/fixtures/local-backend/app-paths.json`, erzeugt mit `tools/gen-local-backend-fixture.py`;
neu seit S3: `POST /api/files/{id}/opened` beim Öffnen eines Dokuments wie im Web, für „Zuletzt“ und „gesehen“).
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
  Query 422 statt 500; `conflicts?days=` höchstens 3660; Unterlagen zum Termin leer bis S3/S4; auf dem Gerät ersetzen
  Kurszeiten die aus Einzelterminen abgeleiteten Serien ihres Kurses (ohne Kurszeiten genau wie Python), und ein
  vollständig geladener Kurs ersetzt seine gespeicherten Einzeltermine (Python lässt veraltete stehen); der Abgleich
  nutzt die Verknüpfung `studip_timetable_links` (siehe oben), und `/auto-status` zählt Gruppen aus Kurszeiten nicht
  mehr, aus denen schon eine Kurszeit im Stundenplan steht (ohne Kurszeiten wie Python). In `app/timetable.py`
  korrigiert (zuerst in Python, `tests/test_timetable.py`): ICS-Zeiten mit „Z“ (UTC) und `TZID` werden in Berliner
  Ortszeit umgerechnet, `EXDATE` und `UNTIL` mit Uhrzeit werden beachtet, Ausfälle werden beim Import zu Ausnahmen,
  ein erneuter Import einer vorhandenen Serie entfernt nicht mehr gemeldete Ausfälle derselben Quelle; `tzdata` steht
  fest in `requirements.txt` (Windows hat keine Zeitzonendatenbank, `TZID=America/New_York` wäre sonst Berliner Zeit;
  auf dem PC einmal `pip install -r requirements.txt`).
- **Platzhalter in Server-Form** bis zur Portierung (leere Listen bzw. Objekte mit denselben Feldern wie
  `app/server.py` bei leerer Datenbank): Übersicht ohne Dateien und Termine von heute (Lernpakete, Woche, Module: S6),
  Lernkalender/Pakete/Aufgaben und `/api/timetable/reslot` (S6), Karteikarten, Uni & Noten, Suche und Skriptsuche
  (`/api/search`, `/api/related`, `/api/files/{id}/pagetext`: S7), `/api/bg`. Einträge nach ID gibt es dort noch
  nicht (404 wie am PC), **Anlegen** (Lernpakete) antwortet mit **409** und klarer
  Meldung. Ein echter Endpunkt ersetzt den Platzhalter automatisch (`LocalRoute.placeholder`).
- **bewusst entfallen:** KI (`/api/ai/tutor`), Wochentests (`/api/tests/*` außer der leeren Liste,
  `/api/tasks/{id}/start-test`), Zugänge (`PUT /api/credentials/*`; `GET` liefert „kein Zugang“): 404 mit Meldung.
  QIS-Abruf (`/api/grades/sync`) 404 „kommt in einer späteren Version“, `/api/sync` 409 (Stud.IP gleicht die App
  direkt ab).

Die Seiten „Tests & Wiederholung“ und „Uni & Noten“ zeigen lokal weiter den leeren Zustand (keine KI, QIS folgt).

| Bereich | Endpunkte | Ziel | Stand |
|---|---|---|---|
| Übersicht, Dateien als gesehen | `/api/dashboard`, `/api/files/mark-seen` | lokal (Free) | neue Dateien und `mark-seen` lokal (S3), Termine von heute (S5), Rest S6 |
| Module und Kurse | `/api/modules*`, `/api/courses*` (9) | lokal (Free) | Kurse lokal (S3), **Module lokal (S4)** |
| Bibliothek, Ordner, Notizbücher, Favoriten | `/api/library*`, `/api/folders*`, `/api/notebooks`, `/api/files/{id}/favorite` (7) | lokal (Free; Notizbücher Plus) | **lokal (S3)** |
| Datei-Inhalt und Notizen | `/api/files/{id}/content`, `/annotations` (GET/PUT, Versionen), `/assets` | lokal (Lesen Free, Schreiben Plus) | **lokal (S3)** |
| Lernkalender, Pakete, Aufgaben, Zeitfenster | `/api/calendar*`, `/api/tasks*`, `/api/packages*`, `/api/timetable/reslot` (16) | lokal (Free) | Platzhalter (S6) |
| Stundenplan, Termine, Import, Konflikte | `/api/timetable/*` (12) | lokal (Free) | **lokal (S5)**, außer `reslot` (S6) |
| Einstellungen, Semester | `/api/settings`, `/api/terms` | lokal | **lokal (S2)** |
| Suche, Skriptsuche | `/api/search`, `/api/related`, `/api/files/{id}/pagetext` | lokal | Platzhalter (S7) |
| Abgleich und Status | `/api/sync`, `/api/sync/status`, `/api/bg` | lokal als Stud.IP-Abgleich | Abgleich in der App (S3), Protokoll lokal |
| Karteikarten | `/api/flashcards*` | lokal (Plus), eigenes Anlegen ohne KI | Platzhalter |
| Uni & Noten | `/api/services`, `/api/grades*`, `/api/qis/*` | Dienste-Liste lokal; QIS auf dem Gerät (später) | Dienste lokal, QIS offen |
| Zugänge | `/api/credentials*` | entfällt (keine Passwörter in der App) | entfallen |
| Tests, KI | `/api/tests*`, `/api/ai/tutor`, `/api/tasks/{id}/start-test` | entfällt (keine KI) | entfallen |
| Community, Konto | – | zentraler Dienst (Entscheidung) | Lösung als Datei (S9) |

**Was nach S3, S4 und S5 ohne PC noch nicht geht** (ehrlich): Wochentests (KI, entfallen), nächster Termin eines Moduls
und Unterlagen im Stundenplan (S5), Lernplan und Kalender mit Inhalt (S6),
Suche und Skriptsuche (S7), neue Original-Fassung mit erhaltenen Notizen (S7),
Hintergrundabgleich (S8), QIS-Noten, Übernahme der Notizen und Pläne vom PC, die Uni Hildesheim auf dem iPad
(Learnweb, LSF, CAS; Auftrag der PC-Sitzung in `docs/AUFTRAG-HILDESHEIM-IPAD.md`, am PC fertig). Keiner dieser
Punkte braucht im App-Store-Betrieb einen PC; sie sind nur noch nicht portiert.

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
   Einzelheiten und Grenzen: `docs/LOESUNGEN-TEILEN.md`.

## 5. Reihenfolge der Umsetzung

Zuerst der größte Nutzen: Dokumente öffnen und mit dem Pencil schreiben ohne PC.

| Schritt | Inhalt | Abnahme ohne PC |
|---|---|---|
| S1 | SQLite-Schicht, Schema, Migrationen, gemeinsame Uhr | Tests im Kern grün (macOS und Linux) |
| S2 | Transport-Weiche und Router; Journal-Namensraum je Datenquelle; **Übernahme der eigenen Notizen und Pläne vom PC** (Entwicklung, noch offen); gültige leere Antworten für noch nicht portierte Pfade | Seiten laden lokal ohne Fehler; Wechsel PC ↔ lokal verliert keine Notizen (**umgesetzt bis auf die Übernahme**) |
| S3 | Stud.IP-Dateien in die Datenbank; Endpunkte Bibliothek, Datei-Inhalt, Notizen; Editor lokal (**umgesetzt**, `wip/s3-dokumente-3`; nachgebessert in `wip/s3-dokumente-3-fix`: neue Fassung erst mit dem Download, Kopien nach „Dateien löschen“, Plus-Sperre für Schreiben und Notizbücher, Downloads als Datei) | Stud.IP verbinden → Dokumente erscheinen → im Editor öffnen und schreiben, offline (**App-Test mit festen Stud.IP-Antworten grün**, `LocalDocumentsAppTests`; echtes Stud.IP und Gerät offen) |
| S4 | Fach, Art, Lehrwoche ohne KI (`classify`, `effective_type`, `week_hint`); Module-Endpunkte: **umgesetzt** (`wip/s4-module-3`): Port von `classify`, `effective_type`, `week_hint`, `enrich_file`, Semesterwochen (Stichtag und Woche 0 vorher in Python korrigiert), `ensure_modules`, `module_detail`, `modules_overview`, `guess_module`; alle Module-Endpunkte; im Kern gegen Python, in der App mit Seed-Daten im Simulator geprüft; mit S3 zusammengeführt in `wip/int-s345-s4` (`classify` beim Abgleich, eine Fassung von `ensure_modules`, Einstellungen → „Module“ ohne PC) | Fächer geordnet, Moduldetail mit Wochen (**mit Seed-Daten im Simulator und mit Daten aus dem Stud.IP-Abgleich im App-Test erfüllt**, feste erfundene Stud.IP-Antworten; echtes Stud.IP und echtes iPad offen) |
| S5 | Stundenplan: Kurszeiten und Einzeltermine aus Stud.IP, `timetable.py`-Port; **umgesetzt** (`wip/s5-stundenplan-2`): Abruf nach dem Datei-Abgleich (`StudIPScheduleSync`), Ablage und `auto_import` (`StudIPScheduleStore`), alle `/api/timetable/*` außer `reslot` (S6), Gruppenauswahl in der Importvorschau, ICS mit UTC/TZID/EXDATE (zuerst in Python korrigiert) | Stundenplan aus Stud.IP (**im Simulator mit erfundenen Stud.IP-Antworten geprüft**: Woche zeigt die Kurse, Ausfälle, Gruppen zur Auswahl; mit echtem Stud.IP noch nicht) |
| S6 | Lernlogik (`study.py`): lesen, verschieben, planen; Übersicht, Kalender | Lernplan erstellen, Aufgaben abhaken, Übersicht |
| S7 | Neue Original-Fassung mit erhaltenen Notizen; Suche und Skriptsuche | Notizen überleben neue PDF; Suche offline |
| S8 | Hintergrundabgleich (nach Messung der Sitzungsdauer bzw. OAuth2) | Abgleich beim Öffnen und, wenn iPadOS es erlaubt, im Hintergrund |
| S9 | Community „Lösungen teilen“: **lokaler Teil umgesetzt** (`wip/loesung-teilen`, nachgebessert in `wip/loesung-teilen-fix`: robuste Formatversion, keine Zusatzfelder, Pixelgrenze für Bilder, gleiche Lösungs-ID verdrängt nichts, Ansichtsmodus schreibt nichts, unlesbare Importe werden entfernt, Entschlüsseln abseits des Hauptthreads; `docs/LOESUNGEN-TEILEN.md`): Lösung als Datei teilen (nur eigene Notizen), importieren, im Editor als Ebene ansehen, lokal zurückziehen; Online-Teil nach Entscheidung zum Dienst | lokal: Lösung als Datei teilen, auf zweitem iPad mit derselben PDF ansehen (**Tests grün**); online: veröffentlichen, finden, zurückziehen, melden (**offen**) |
| S10 | Anmeldung härten, Release-Bereinigung, Demo-Modus für die App-Prüfung, Abnahmeliste | Abnahme nach AUFTRAG 2a und dieser Datei |

Nach jedem Schritt: bauen, Unit-Tests, Prüfung „funktioniert auf einem iPad ohne Windows-PC“, Abschnitt 2 dieser
Datei fortschreiben.

## 6. Hochschul-Freigaben (vom Inhaber zu klären)

- **ZQS/elsa:** schriftliche Erlaubnis für den Abruf über die JSON:API durch eine App für andere Studierende
  (Abrufmuster nennen); OAuth2-Client mit PKCE und Lebensdauer von Sitzung und Refresh-Token; ob Teilen der eigenen
  Anmerkungsebene innerhalb eines Kurses in Ordnung ist. Entwurf: `docs/ANFRAGE-STUDIP-ZUGANG.md`.
- **LUH:** Erlaubnis für den App Store nach Richtlinie 5.2.2 (Nutzung der Hochschuldienste und Namen).
- **LUIS:** Anmeldung in der eingebetteten Webansicht als Übergang zulässig oder nur `ASWebAuthenticationSession`.
- **Datenschutz und Urheberrecht:** Datenschutzerklärung; lokale Speicherung der Skripte; Teilen eigener
  Anmerkungen über fremden Folien; Hinweis zu bewerteten Abgaben (Prüfungsämter).
- **Messung am Gerät (ohne Freigabe):** Wie lange hält die Stud.IP-Sitzung? Liefert Stud.IP ETag oder
  Last-Modified?

## 7. Entscheidungen des Inhabers

**Entschieden am 25.10.2026** (Vorschläge 1–7 bestätigt):

1. **Python-Korrekturen** (Stichtag des Semesterbeginns, gespeicherte Uhrzeit von Lernpaketen, ICS mit UTC/TZID)
   werden als Fehlerbehebung auch in der Web-App übernommen – zuerst in Python, danach portiert.
2. **Lernplan ohne Testaufgaben** (keine KI): Standard `tests_per_subject` = 0, in Python und auf dem iPad.
3. **Demo-Modus** für die App-Prüfung nur über einen versteckten Schalter für Prüfer; sonst keine Beispieldaten.
4. **Eigener Server** (Entwicklungsmodus) nur in Debug-Builds; im Release nicht erreichbar.
5. **Nur LUH** in V1. Seitdem auf `develop`: Hochschulen strikt getrennt und Hildesheim am PC
   (`docs/HILDESHEIM.md`), Auftrag für die iPad-App in `docs/AUFTRAG-HILDESHEIM-IPAD.md`; auf dem iPad bisher nur die
   Hochschul-Regel der lokalen Datenbank (`settings.university`, `UniversityMismatch`).
6. **Backup:** Notizen, Plan und Einstellungen ins iCloud-Backup; Stud.IP-Dateien, alte Fassungen und Seitentexte
   ausgenommen.
7. **Große Dateien** (z. B. Videos über 100 MB) werden nur auf Wunsch geladen.

**Offen:**

8. **Community-Dienst:** CloudKit (gehört zum Developer Program, 99 €/Jahr) oder Supabase (ca. 25 USD/Monat) –
   entscheidet der Inhaber später; bis dahin wird die Community nur vorbereitet (ohne echten Dienst). Seit S9 läuft
   „Lösung teilen“ als Datei ohne Dienst (Plus); der Knopf „In der Community veröffentlichen“ bleibt deaktiviert
   („Community-Dienst noch nicht verbunden“). Vor dem Einschalten braucht es eine echte Berechtigungsprüfung (signierter
   Beleg der Hochschule oder OAuth2-Scope) und Moderation (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 7).

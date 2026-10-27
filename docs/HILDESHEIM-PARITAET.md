# Hildesheim-Gleichheit: jede LUH-Funktion auch für die Universität Hildesheim

Stand 26.10.2026, Zweig `wip/erststart-noten` (Mac-Sitzung). Geprüft ohne Netz mit erfundenen Daten: App-Tests im
Simulator gegen Stub-Antworten (`UniFlowTests/HildesheimParityAppTests.swift`, `HildesheimAppTests.swift`,
`FirstStartAppTests.swift`, `QISAppTests.swift`) und der erste Start im Simulator gegen lokale Nachbildungen der
Anmeldeseiten und Antworten beider Hochschulen (`apps/apple/DebugStub/erststart`, Startargumente
`-UFOnboarding login -UFUniversity hildesheim -UFLoginStub <ordner>`). Gegen die echten Seiten der Universitäten wurde
nichts aufgerufen; was nur mit echter Anmeldung geht, steht unten.

Lesart: **LUH** = Quelle an der Leibniz Universität Hannover, **Hildesheim** = Quelle an der Universität Hildesheim.
Alles ab der Datenbank (Dokumente, Module, Stundenplan, Lernplan, Editor, Suche, Teilen, Einstellungen) ist eine
Fassung für beide Hochschulen; die Quellen schreiben über `UniStore` in dieselben Tabellen.

| Funktion | LUH | Hildesheim | geprüft wie |
| --- | --- | --- | --- |
| Erster Start: Apple → Tarif → Hochschule → Anmeldeseiten → Erstabgleich → Übersicht | Stud.IP, danach QIS (`FirstLoginStep.steps(.luh)`) | CAS für das Learnweb (Moodle-SSO-Schlüssel wie bisher), danach LSF über dieselbe CAS-Sitzung (`steps(.hildesheim)`) | `FirstStartAppTests` (Schritte, „Später anmelden“, Zeilen des Erstabgleichs, LUH bis Übersicht und Noten); Simulator mit Nachbildungen beider Hochschulen (Bildschirmfotos `erststart-shots/`) |
| „Später anmelden“ → Karten „… verbinden“ auf der Übersicht | Karte „Stud.IP verbinden“ | Karten „Learnweb verbinden“ / „LSF verbinden“ (`HildesheimSourcesBar`) | `FirstStartAppTests.testLaterWithoutLoginShowsTheConnectCards`, `UFDataMode.current` |
| Anmeldung: Passwort merkt nur iOS (seit 27.10.2026), die App füllt nichts vor, speichert nichts und schickt nie ab; Hinweis `UniversityLoginHint` unter dem Fenster | Stud.IP-Login/WebSSO, QIS (kein Rückgriff mehr auf die LUH-ID aus Stud.IP) | CAS für Learnweb und LSF | `UniversityLoginPolicyTests` (echte WKWebView mit der App-Konfiguration, auch manipulierte Seiten; echte Anmeldeansichten mit den Nachbildungen; Quellen), `UniversityTokenStoreTests` (Learnweb-Schlüssel, einmalige Löschung alter Einträge) |
| Dokumente in „Dokumente & Notizen“ nach Fach (Modul) | Stud.IP-Kurse → `classify` | Learnweb-Kurse „WiSe 2026/27: 9072 Titel“ → Semester, Nummer, Titel → `classify` | `HildesheimParityAppTests` (`/api/library`, `/api/courses`: Fächer „Einführung in die Erziehungswissenschaft“, „Bildungssoziologie“) |
| Lehrwoche je Datei (Moduldetail „Woche N“) | Stud.IP-Ordner, Dateiname, Änderungszeit | Learnweb-Abschnitt „1“, „2“ → Ordner „Woche N“ (`Learnweb.filesFromContents`) | `HildesheimParityAppTests` (`studip_folder` „Woche 1“/„Woche 2“, `/api/modules/{id}`), Kern `HildesheimFixtureTests` |
| Meine Module (Dateizahl, Wochen, Dateien je Art) | ja | ja, dieselben Endpunkte | `HildesheimParityAppTests` (`file_count` 3, Moduldetail mit `weeks` und `files`) |
| Stundenplan (Serien, Ausfälle) | Stud.IP-Kurszeiten und Einzeltermine (`StudIPScheduleSync`) | LSF-iCal: BYDAY statt DTSTART, EXDATE als „fällt aus laut LSF“ (`UniStore.importPlan`) | `HildesheimParityAppTests` (Dienstag 10:00, Donnerstag 14:00, nicht Montag; Ausfall 22.12. und 24.12.), `HildesheimAppTests` |
| Stundenplan importieren (ICS, eigene Termine) | zusätzlich „aus Stud.IP“ | ICS und eigene Termine; der LSF-Plan kommt vom Abgleich | `AbnahmeV1AppTests`, `HildesheimParityAppTests` (`TimetableImportDialog.sources`) |
| Übersicht (Neu aus …, Termine heute, Kennzahlen) | „Neu aus Stud.IP“ | „Neu aus Learnweb“ (`UFSourceText.newFiles`) | `HildesheimParityAppTests` (`/api/dashboard` `new_total` 4), `AbnahmeV1AppTests` |
| Lernplan / Lernkalender / Woche retten | ja | ja (dieselbe `study`-Logik auf den Learnweb-Materialien neben den LSF-Terminen) | `HildesheimParityAppTests` (`POST /api/calendar/generate` → Pakete in der Woche ab 26.10.) |
| Editor (PDF öffnen, Notizen, Export) | Dateien unter `StudIP/files/…` | Dateien unter `Learnweb/files/…` (relativ zum Container) | `HildesheimParityAppTests` (`/api/files/{id}/content` liefert die PDF), Notizen über `/api/files/{id}/annotations`; Editor-Logik quellenunabhängig (`EditorFeatureTests`) |
| Neue Fassung einer Datei mit erhaltenen Notizen | `UniDownloads` (S7) | dieselbe `UniDownloads`-Fassung im Kern | `HildesheimParityAppTests.testNewLearnwebVersionKeepsNotes` (alte Fassung bleibt, drei Seiten, Notiz auf der passenden Seite) |
| Suche (Dateiname, Modul, Seitentext) | ja | ja, Seitentexte beim Learnweb-Download (PDFKit über `AppDocumentTools`) | `HildesheimParityAppTests` (`/api/search?q=sozialisation` findet die Seite, `q=bildungssozio` das Modul) |
| Noten (Uni & Noten: Schnitt, Leistungen, Abruf, leer ist kein Fehler) | **neu:** QIS auf dem Gerät (`QISConnection`, `QISClient`), „Noten abrufen“, höchstens alle 20 h, asi und Stammdaten nie gespeichert | LSF-Notenspiegel im Abgleich (`HildesheimSync.syncGrades`), „Noten abrufen“ | `QISLUHTests` (Kern), `QISAppTests`, `HildesheimParityAppTests` (Schnitt 1,94, 2 bestanden, keine Stammdaten) |
| Lösung teilen / empfangene Lösung ansehen | ja | ja (Datei-Fingerabdruck, Container der Hochschule) | `SolutionSharingTests`, `HardeningSolution*Tests` (quellenunabhängig; Container je Hochschule in `DataSeparationAppTests`) |
| Statusleiste / Sync-Knopf der Kopfzeile | Stud.IP-Stand, „Jetzt abgleichen“ | „Learnweb: 10:00 ok“, „LSF: 10:00 ok“, Meldungen des Laufs, „Jetzt abgleichen“ | `HildesheimParityAppTests`, `HildesheimAppTests.testStatusTexts` |
| Einstellungen: Quellen verbinden / abmelden | Karte „Stud.IP & QIS“ (**neu**, `LUHSourcesCard`) | Karte „Learnweb & LSF“ (`HildesheimSourcesCard`) | Simulator (Einstellungen beider Hochschulen angesehen); `QISAppTests.testSignOutRemovesOnlyTheQISSession`, `HildesheimParityAppTests.testSignOutKeepsDataAndDeleteRemovesOnlyHildesheim` |
| Abmelden behält Dateien, Stundenplan, Noten | ja | ja | `HildesheimParityAppTests`, `HildesheimAppTests.testExpiredSessionsAskForLoginAndSignOutKeepsTheData` |
| Daten dieser Hochschule löschen / Konto löschen | ja | ja (nur der eigene Container) | `HildesheimParityAppTests` (leerer Speicher danach), `DataSeparationAppTests` |
| Seitenleiste „Uni & Noten“ | ja (**neu** lokal) | ja | `AbnahmeV1AppTests.testSidebarShowsOnlyAreasWithAFunctionOnTheDevice` |
| Hochschulwahl-Text ohne „folgt später“ | „QIS: Notenspiegel“ | „LSF: Stundenplan und Notenspiegel“ | `QISAppTests.testUniversityPickerAndSidebarNoLongerPromiseQISForLater` |
| Aufzeichnungen (Opencast) | ja (Stud.IP-Plugin) | **nur LUH** (bewusste Ausnahme): das Learnweb bietet keine; die Seite sagt das ehrlich, kein „kommt später“ | `RecordingsAppTests`; Text in `RecordingsViews.swift` |

## Nur mit echten Anmeldungen prüfbar (Inhaber)

- Ob das echte QIS der LUH die Seitenfolge „Meine Funktionen → Mein Studium → Notenspiegel → Abschluss → Leistungen“
  so liefert, wie `QISPage`/`QISCollector` sie lesen (Aufbau aus `docs/QIS-STUDIP-STRUKTUR.md`; Stub und Tests
  bilden ihn nach). Der Inhaber hat aktuell 0 Leistungen: dann steht „Im QIS sind noch keine Noten veröffentlicht.“
- Ob die QIS-Sitzung der Webansicht (Sitzungs-Cookie ohne Ablaufdatum) einen App-Neustart überlebt; sonst meldet
  die App „QIS: Anmeldung nötig“ und bietet die Anmeldung an (Passwort tippt der Mensch oder setzt iOS ein).
- Hildesheim: Moodle-SSO-Schema `moodlemobile`, Schlüssel im POST-Körper an `pluginfile.php`, echte CAS-Weiterleitung
  Learnweb → LSF ohne zweites Passwort (siehe `docs/AUFTRAG-HILDESHEIM-IPAD.md`, „Offen“).
- Zählwerte gegen die PC-Sitzung (`docs/OFFEN-V1.md`, Punkt 5).

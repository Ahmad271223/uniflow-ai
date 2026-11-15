# Build-Herkunft der Apple-App (StudiNow für iPad und iPhone, Builds 21 bis heute)

Stand 15.11.2026 (angelegt 08.11.2026, Audit P46-01/P47-04). Welcher Git-Commit steckt in welchem hochgeladenen Build? Fehlerbehebungen nach
einem Build gelten **nicht** für diesen Build. `tests/test_release_build_provenance.py` prüft diese Datei gegen
`apps/apple/project.yml` und `docs/release/APP-STORE.md` und – auf dem Mac des Inhabers, wo `~/Studora-Builds` liegt –
die Export-Ordner gegen die Commits.

Aktueller Stand in project.yml: Build 44 (Version 1.0.4, `MARKETING_VERSION` und `CURRENT_PROJECT_VERSION`). In der Prüfung bei Apple: 1.0.4 mit Build 42 seit 15.11.2026 10:13. Build 43 liegt nur intern in TestFlight.
Veröffentlicht: 1.0.3 mit Build 35 aus `ce6df886` (13.11.2026 23:53), davor 1.0.2 mit Build 31 und 1.0.1 mit Build 30.

## Builds

Zeiten MEZ. „Commit“ ist der Commit, aus dem der Export-Ordner `~/Studora-Builds/export-bNN` per `git archive` entstand
(geprüft am 08.11.2026: Ordner und Commit sind Datei für Datei gleich, bis auf die beim Bauen erzeugten Dateien, siehe
unten). Alle Builds: Release, Team 78MQGF36BD, Bundle-ID `de.uniflow.ai`. Hochschulen: bis Build 39
`UF_SHIPPED_UNIVERSITIES=luh` (nur LUH), ab Build 40 `luh hildesheim` (LUH und Universität Hildesheim). Geräte: bis
Build 38 nur iPad, ab Build 39 iPad und iPhone.

| Build | Commit | Datum | Status | Inhalt |
|---|---|---|---|---|
| 21 | `44ba7cc5` | 08.11.2026 00:30 | hochgeladen (TestFlight), nicht eingereicht | Bibliothek liest vor dem Öffnen einer „nicht geladenen“ Datei frisch nach |
| 22 | `10f76288` | 08.11.2026 00:48 | hochgeladen (TestFlight), nicht eingereicht | Bibliothek liest ihre Liste nach jedem Abgleich neu |
| 23 | `6cccffc5` | 08.11.2026 01:07 | hochgeladen (TestFlight), nicht eingereicht | Stud.IP-Abgleich lädt Dateien ohne Ablageort in jedem vollen Lauf nach |
| 24 | `d4accf67` | 08.11.2026 01:34 | hochgeladen (TestFlight), nicht eingereicht | Dokument sofort über die Kennung öffnen; voller Abgleich vor Stufe d |
| 25 | `d08cae54` | 08.11.2026 01:51 | am 08.11.2026 als Version 1.0 zur Prüfung gegeben und von Apple freigegeben, nie veröffentlicht; am 10.11.2026 00:27 zurückgezogen und durch Build 30 ersetzt; TestFlight weiter verfügbar | Bibliothek ohne „Dokument wählen“ beim Öffnen; Community-Beiträge erscheinen sofort |
| 26 | – | – | nie gebaut und nie hochgeladen (Nummer übersprungen) | – |
| 27 | `b328ebdd` | 09.11.2026 01:40 | gebaut (Archiv), nur auf das iPad des Inhabers installiert, nie hochgeladen | Build 25 plus Bugfixes, siehe unten |
| 28 | `7d1a8fb3` | 09.11.2026 12:08 | gebaut (Archiv), auf das iPad des Inhabers installiert, noch nicht hochgeladen | Build 27 plus Händigkeit/Seitentausch, Strich sofort gesichert (P60-F1), Erledigung beim Abgleich (P73-F6), Audits 58–87, siehe unten |
| 29 | – | 09.11.2026 | nie gebaut und nie hochgeladen: interner Stand auf develop (Build 28 plus Mac-Parität, Community-Zustand iPad/Mac über iCloud, gerätelokale Einstellungen); nicht in Build 30, Inhalt steckt in Build 31 | docs/paritaet/MAC-B28-2026-11-09.md, COMMUNITY-UND-ABGLEICH-2026-11-09.md |
| 30 | `3b81464a` | 10.11.2026 00:03 | veröffentlicht: Version 1.0.1, von Apple freigegeben und am 10.11.2026 vom Inhaber veröffentlicht (READY_FOR_DISTRIBUTION; vorher WAITING_FOR_REVIEW seit 10.11.2026 00:27), zugleich TestFlight; hochgeladen 10.11.2026 00:06 vom Zweig `release/1.0-b30`; Freigabe von Hand | Build 28 (`7d1a8fb3`) plus nur Jahresabos (Plus 19,99 €, Pro AI 39,99 € im Jahr, keine Monatsabos mehr) und Credit-Text 0,9 Cent, sonst nichts; docs/release/ABO-NUR-JAHR-2026-11-09.md |
| 31 | `0324eb3d` | 10.11.2026 19:28 | veröffentlicht: Version 1.0.2, von Apple freigegeben und am 11.11.2026 veröffentlicht (READY_FOR_SALE; eingereicht 10.11.2026 20:45); TestFlight | Build 30 plus Mac-Parität und Mac-Bedienung, Community-Zustand iPad/Mac über iCloud, gerätelokale Einstellungen; QIS (angemeldete Prüfungen, Bescheinigungen mit abgelaufener Anmeldung); Lernblöcke nur in freier Zeit; Antwort auf die Übungsfrage für jedes Vorkommen; Uni-Zugang einmal speichern („überall gleich“ oder je Portal); ein Sync für Stud.IP, QIS und Uni-Mail; Wochenkopf ohne Umbruch des Datums; „Nachrichten“ mit Sprechblase statt zweitem Brief |
| 32 | `95943d32` | 11.11.2026 | nur TestFlight, nie eingereicht: Version 1.0.2; stürzte auf iPads beim Öffnen eines Dokuments ab (Stapelüberlauf in `DocumentView.body`), am 11.11.2026 aus der Gruppe „LUH-Tester“ genommen | Build 31 plus Mac-Version (Tastatur/Maus, eigenes Fenster, Präsentieren), Editor (Suche in Notizen, Bilder, ein Lasso, Schreiblupe), Benachrichtigungen bei Noten/Nachrichten, Erinnerungen ab Plus, kein Centbetrag bei Credits, Studienverlauf zählt angemeldete Prüfungen und Wahlfächer, Versuche ehrlich, QIS-Anmeldung im Sync und Bescheinigungsliste, schnellerer Sync, PDF-Absturz (iPadOS 26.5) entschärft, KI-Stopp und ziehbare KI-Leiste, Import in Ordner, Listenansicht |
| 33 | `1c911fa5` | 11.11.2026 23:52 | nur TestFlight, nie eingereicht: Version 1.0.3, ersetzt durch Build 35 | Build 32 plus Absturzkorrektur `DocumentView` (Stapel 1220 → 435 KB, Schutztest `ViewTypeDepthAppTests`), Stift-Palette kommt nach Chat/KI-Frage zurück; Tests: Vorlage-iPad 1504 grün, iPad 9 (Simulator) 960 grün |
| 34 | `6be58cd3` | 12.11.2026 17:31 | nur TestFlight, nie eingereicht: Version 1.0.3, ersetzt durch Build 35 | Build 33 plus feste Werkzeugleiste (oben/unten/schwebend), Schlösser für Free/Plus, eine Apple-Anmeldung (Dienst-Konto für alle, Widerruf beim Löschen – braucht Server-Deploy und Apple-Schlüssel), Datentrennung bei anderem Stud.IP-Benutzer, Jetzt-Linie im Stundenplan, Planer öffnet richtiges Modul, Import in eigene/neue Ordner auf allen Wegen, Noten/LP nur aus QIS, Studienverlauf höhere Semester, Profil-Kreis entfernt; Tests: iPad 1547 (1 zeitabhängiger Test einzeln grün), Kern 1442, JS 440, Python grün |
| 35 | `ce6df886` | 13.11.2026 00:47 | veröffentlicht: Version 1.0.3 am 13.11.2026 23:53 (von Apple freigegeben, vom Inhaber von Hand veröffentlicht; eingereicht 13.11.2026 00:53); TestFlight intern und „LUH-Tester“ | Build 34 plus Kopfzeile mit Reitern und Werkzeugen (Vollbild-Schreiben), Studiengruppen nach Wahl, Fächer für den Lernkalender, QIS-Leser nach echtem LUH-Notenspiegel (Prf.Art, anerkannt 0,0, neuester Eintrag), zusammengesetzte Modultitel, Autofill QIS, „Diese Seite auslesen“; Tests: Kern 1462, Python 3106 (bekannte Browser-Tests ausgenommen), JS 440, iPad 1558 im Gesamtlauf plus gezielte Nachläufe der korrigierten Klassen grün |
| 36 | `d606ceda` | 13.11.2026 09:15 | hochgeladen (TestFlight), Version 1.0.4, nicht eingereicht; intern und „LUH-Tester“ (Beta-Prüfung bei Apple seit 13.11.2026 09:16) | Änderungen nach `ce6df886`: Smart Planner 2.0 (Lernziele), eigene Wochen je Modul, Uni Hildesheim (im Release aus), kurzer KI-Hinweis, Beschreibung „Lernmanagementsystem“ |
| 37 | `6f1eff9d` | 13.11.2026 13:21 | hochgeladen (TestFlight), Version 1.0.4, nicht eingereicht; intern sofort, „LUH-Tester“ nach der Beta-Prüfung (wartet auf Build 36) | Build 36 plus KI-Mails (Pro AI), Probe-Karte nach Kauf weg, KI erklärt einfacher, Startseite aufgeräumt, letzte 15 Dokumente, Stift-Glättung und Formen, Blatt daneben, abgewählte Fächer nie geplant, Community-Fehler |
| 38 | `ba427849` | 13.11.2026 16:17 | hochgeladen (TestFlight), Version 1.0.4, nicht eingereicht; intern sofort, „LUH-Tester“ nach der Beta-Prüfung (wartet auf Build 36) | Build 37 plus neuer App-Einstieg, Haken „erledigt“ je Datei und Woche, QIS direkt zur Prüfungsanmeldung, bessere KI-Karteikarten |
| 39 | `5d6b6a45` | 13.11.2026 23:49 | hochgeladen (TestFlight), Version 1.0.4, erstmals iPad + iPhone, nicht eingereicht; intern und „LUH-Tester“ (extern IN_BETA_TESTING seit 23:51) | Build 38 plus iPhone-Version, Rückgängig holt nie Gelöschtes zurück, Formen erkennen am Gerät, „+ Seite“, Seiten im Notizblatt löschen mit Papierkorb, Uni-Mail neu anmelden statt „keine JSON-Antwort“, Erledigt-Haken über alle Geräte |
| 40 | `aefee598` | 14.11.2026 13:41 | hochgeladen (TestFlight), Version 1.0.4, iPad + iPhone, **erstmals LUH und Universität Hildesheim** (`UFShippedUniversities` = `luh hildesheim`), nicht eingereicht (Inhaber wartet auf die Mac-Reparatur in Build 41); intern und „LUH-Tester“ | Build 39 plus Hildesheim im Store-Build, Store-Texte und Bilder für 1.0.4, neue Anschrift in den Rechtstexten |
| 41 | `6923136b` | 14.11.2026 19:01 | nur TestFlight: Version 1.0.4, am 14.11.2026 19:56 zur Prüfung eingereicht (nach dem Server-Update für die Geräte-Regel, ausgerollt 19:55, `DEPLOY-DIENST-2026-11-14.md`) und am 14.11.2026 21:54 zurückgezogen (Version DEVELOPER_REJECTED; Entscheidung des Inhabers „Ja, mit Build 42“): am echten iPhone waren im Lernkalender die Karten unter dem Kalender gequetscht, die Zeitachse des neuen Wochenrasters lief bis 26 Uhr (alte Lernpakete mit Ende „25:15“) und ein Einstiegs-Bildschirm war halb leer; ersetzt durch Build 42; iPad + iPhone, LUH und Universität Hildesheim (`UFShippedUniversities` = `luh hildesheim`); TestFlight: hochgeladen 19:01, von Apple als VALID gemeldet 19:46, Testhinweis gesetzt, intern und „LUH-Tester“ (am 14.11.2026 intern und extern IN_BETA_TESTING, Beta-Prüfung WAITING_FOR_REVIEW); Tag `ios-1.0.4-b41` | Build 40 plus Mac-Reparatur (`ufSheet`/`ufFullScreenCover`/`ufPopover`, kein Absturz beim Öffnen von Blättern), Hildesheim (Wochen nach Sitzungsdatum, Studiengang selbst wählen inkl. Begleitfach, früheres Studium getrennt, „Was studierst du?“ mit 176 Einträgen und Kurzform-Suche, LSF-Link, neuer Leser für Studienordnung mit Modulhandbuch, Grundstock 108 Kataloge / 2 204 Module, Register 119), iPhone-Wochenraster im Lernkalender, Geräte-Regel (Free gilt für ein Gerät, Plus-Hinweis; greift seit dem Server-Update vom 14.11.2026 19:55), Griff der geteilten Ansicht reagiert erst ab 4 pt, Store-Texte 1.0.4 angepasst |
| 42 | `fc66fba4` | 15.11.2026 10:11 | eingereicht: Version 1.0.4 am 15.11.2026 10:13 neu zur Prüfung gegeben (App Store WAITING_FOR_REVIEW, Freigabe nach der Prüfung von Hand), ersetzt den zurückgezogenen Build 41; Texte und Bilder unverändert vom 14.11.2026; Server seit 15.11.2026 01:17 auf demselben Commit (`DEPLOY-DIENST-2026-11-15.md`); iPad + iPhone, LUH und Universität Hildesheim (`UFShippedUniversities` = `luh hildesheim`); Archiv in der Nacht zum 15.11.2026 gebaut, drei Upload-Versuche in der Nacht scheiterten an fehlender Internetverbindung; TestFlight: hochgeladen 10:11, von Apple als VALID gemeldet 10:12, Testhinweis gesetzt, intern und „LUH-Tester“ (intern und extern IN_BETA_TESTING, Beta-Prüfung WAITING_FOR_REVIEW); Tag `ios-1.0.4-b42` | Build 41 plus iPhone-Layout (Zeitachse aller Kalender-Raster höchstens bis 24 Uhr, Karten im Lernkalender am iPhone untereinander, Einstieg ohne leere Hälfte, Wochenkopf im Modul bricht um; neue Prüfer in `LayoutWidthAuditTests`), Lernplaner (keine Lernpakete nach der Lernzeit oder nach 24:00, Altbestand „25:15“ wird repariert; Swift und Python), Stift (dünnste Stufen: Stift 0,88, Fineliner 0,5/0,8/1,5/2,5/4, Textmarker 7,5 …; wirkungslose Stufen behoben), Werkzeuge (Netzfehler bei App Store Connect werden wiederholt); Tests: Python 3564 (`test_modules_race` wackelig, einzeln grün), JS 456, Swift-Kern 1565, iPad 1802, iPhone 139, alle ohne Fehler |
| 43 | `e2e26e56` | 15.11.2026 19:41 | nur TestFlight, nur interne Gruppe „Intern (Inhaber)“ (Okay des Inhabers „Über TestFlight“); NICHT an „LUH-Tester“, keine Beta-Prüfung, nicht eingereicht. Der Dienst läuft noch auf `fc66fba4`: Credits kaufen, KI-Chat mit Plus und der Abgleich je Uni-Konto brauchen das Server-Update und die zwei Credit-Produkte bei Apple | Build 42 plus Abgleich je Uni-Konto, Stift feiner und Stift-Einstellungen, Video und Lernseiten, Lernplaner (Fächer, Wochenwunsch, keine Doppelplanung), Kopieren-Knopf unter KI-Antworten, KI-Credits zum Nachkaufen (Plus nur KI-Chat), Erst-Abgleich mit Fortschritt, Hildesheim-Nachzug (112 Kataloge), Mac-Test-Abschottung, Testläufe schnell/voll. Kompletter Lauf auf `196858bc`: Dienst 3673, Browser 459, Kern 1617, iPad 1822 (3 abgestürzte Tests in `fa92ac40` repariert und einzeln grün), iPhone 146 |
| 44 | – | 15.11.2026 | noch nicht hochgeladen; develop nach Build 43 | Änderungen nach `e2e26e56` |

### Build 25 (als 1.0 freigegeben, nie veröffentlicht, am 10.11.2026 zurückgezogen)

Build 25 war vom 08.11.2026 an als Version 1.0 in der Prüfung und wurde freigegeben („Pending Developer Release“,
Freigabe von Hand), aber nie veröffentlicht. Am 10.11.2026 00:27 hat der Inhaber die Freigabe zurückziehen lassen;
dieselbe Versionsseite heißt jetzt 1.0.1 und trägt Build 30.

- Quelle: `git archive d08cae54` nach `~/Studora-Builds/export-b25` (develop, Nacht 07./08.11.2026, Commit 08.11. 01:51).
  Beim endgültigen Einreichen um 10:05 stand develop auf `c372db24`; zwischen `d08cae54` und `c372db24` hat sich unter
  `apps/apple/` nichts geändert (nur Dienst und Doku: 1 Credit = 0,9 Cent).
- Archiv: `~/Studora-Builds/StudiNow-25.xcarchive`, erstellt 08.11.2026 01:55 (`xcodebuild archive`, Protokoll
  `b25-archive.log` nennt `export-b25/apps/apple`), `CFBundleVersion` 25, `UFShippedUniversities` = `luh`, keine
  ATS-Ausnahme, `PrivacyInfo.xcprivacy` im Bundle (Stand 07.11.: fünf Datenarten).
- Hochgeladen 08.11.2026 02:08–02:10 mit `xcodebuild -exportArchive` (Protokoll `b25-upload.log`, „Uploaded UniFlow“,
  „EXPORT SUCCEEDED“). Signierung beim Export mit dem Distributionszertifikat; die Entitlements des Archivs selbst sind
  noch die der Entwicklung (`get-task-allow`).
- Vor dem Archiv lokal geprüft: `b25-test.log` (Abnahme-Auswahl: AbnahmeV1, AbnahmeV1LUHRelease, BackArrow,
  LayoutWidthAudit, LibraryShelf, LocalDocuments, StudIPDownloadGap – 74 Tests, 2 übersprungen, 0 Fehler).
- **GitHub Actions:** Der Lauf „Apple“ für `d08cae54` (Run 42431686238) ist rot, weil der Linux-Job schon beim
  Übersetzen scheitert (Linux-Foundation, nicht iOS); der iPad-Job wurde übersprungen. Für Build 25 gibt es also
  **keinen** CI-Nachweis, nur die lokalen Läufe oben.

### Build 27 (ersetzt durch Build 28)

Build 27 = Build 25 plus die Änderungen unter `apps/apple/` seit `d08cae54`, Stand 08.11.2026 21:15:

| Commit | Änderung |
|---|---|
| `afc919cc` | Mac („Designed for iPad“): Absturz in `UFGridLayout` bei unendlicher Breite behoben; Testbundle mit Stub und Fixtures |
| `c3ea0e60` | Build-Nummer 27 |
| `994377ea` | Lernplan ordnet nur neue Dokumente ein, statt die Woche neu zu planen |
| `a6add585` | Kauf trägt mit Anmeldung immer das Konto-Token, späte Kaufprüfung nach Kontowechsel verworfen (Audit P36) |
| (Audit 46/47) | Datenschutz-Manifest mit Geräte-ID, Text der Spracherkennung nennt auch „Transkript erstellen“ |

Dazu kommen weitere Swift-Korrekturen aus den laufenden Audits bis `b328ebdd` (develop, 09.11.2026). **Stand
09.11.2026 (Audit P68-01):** `~/Studora-Builds/export-b27` ist Datei für Datei der Export von `b328ebdd` (geprüft mit
`_export_differences` aus `tests/test_release_build_provenance.py`, 0 Abweichungen; `StudiNow-27.commit` = `b328ebdd`),
daraus `StudiNow-27.xcarchive` vom 09.11.2026 01:40 (`b27-archive.log`: „ARCHIVE SUCCEEDED“, `CFBundleVersion` 27,
`UFShippedUniversities` = `luh`); vorher lokal `b27-test.log`: **1365 Tests, 18 übersprungen, 0 Fehler**. Das frühere
Archiv vom 08.11. 19:44 (aus `c3ea0e60`) ist damit ersetzt. Noch nicht hochgeladen. Kommt vor dem Upload noch eine
Änderung unter `apps/apple/` dazu, gilt wieder: neu aus dem dann aktuellen Commit bauen und die Zeile 27 oben anpassen. Wird Build 27 einmal
hochgeladen, ist die Nummer verbraucht; jede weitere Änderung braucht Build 28.

### Build 28 (ersetzt durch Build 30)

Build 28 = Build 27 plus die Änderungen bis `7d1a8fb3` (develop, 09.11.2026): Schreibhand und Seiten tauschen
(`e5050f50`, `5160860b`, `4e9aea98`), Strich sofort gesichert (P60-F1, `f5a31bf8`), nur geänderte Felder beim Abgleich
(P73-F6, `83e7d910`, `a6d25a73`), Prüfungsknopf QIS/LSF (`7e175276`), Studienverlauf verschieben (`07254389`),
Probe-Anzeige aus einer Quelle (`3992573b`), Übernahme-Kontingent je Konto (`6859265f`) und die Swift-Korrekturen der
Audits 58–87. **Stand 09.11.2026:** `~/Studora-Builds/export-b28` ist Datei für Datei der Export von `7d1a8fb3`
(`tools/pruefe-build-herkunft.sh 28 7d1a8fb3`: keine Abweichung; `StudiNow-28.commit` = `7d1a8fb3`), daraus
`StudiNow-28.xcarchive` (`b28-archive.log`: „ARCHIVE SUCCEEDED“, Version 1.0, `CFBundleVersion` 28,
`UFShippedUniversities` = `luh`, Team 78MQGF36BD); vorher lokal `b28-test.log` auf demselben Commit: **1387 Tests,
18 übersprungen, 0 Fehler**. Nie hochgeladen: der Inhaber hat am 09.11.2026 entschieden, nur noch Jahresabos anzubieten; dafür gibt es Build 30.

### Build 30 (Version 1.0.1, in der Prüfung seit 10.11.2026)

Build 30 = Build 28 (`7d1a8fb3`, alle iPad-Korrekturen) plus genau zwei Dinge: nur noch Jahresabos (Entscheidung des
Inhabers vom 09.11.2026: Plus 19,99 €, Pro AI 39,99 € im Jahr, Monatsabos werden nicht mehr angeboten; ein früherer
Kauf eines Monatsabos gilt weiter als Kauf des Tarifs) und der Credit-Text „1 Credit sind 0,9 Cent“. Die Mac- und
Community-Änderungen des internen Stands 29 sind **nicht** enthalten. Unter `apps/apple/` außerhalb der Tests ändern
sich gegenüber Build 28 nur `Purchases/{Plans,PurchaseStore,Entitlements}.swift`, `Views/Onboarding/PlanPickerView.swift`,
`Views/Settings/{SettingsPage,TrialBanner}.swift`, `Services/StudoraAccountLink.swift` (Kommentar),
`UniFlowCore/Account/InviteRewards.swift` sowie Build-Nummer und Versionsnummer in `project.yml`. Einzelheiten:
`docs/release/ABO-NUR-JAHR-2026-11-09.md`.

- **Version 1.0.1:** Entscheidung des Inhabers vom 09.11.2026 („nenn das 1.01“). Version 1.0 (Build 25) wurde nie
  veröffentlicht; der erste Stand im Store heißt damit 1.0.1.
- **Quelle:** Commit `3b81464a` auf dem Zweig `release/1.0-b30` (von `7d1a8fb3` abgezweigt, nicht von develop; in develop
  eingemischt). `3b81464a` = `5d418339` plus nur `MARKETING_VERSION: "1.0.1"` und zwei Doku-Dateien.
  `~/Studora-Builds/export-b30` ist Datei für Datei der Export dieses Commits (`tools/pruefe-build-herkunft.sh 30
  3b81464a`: keine Abweichung; `StudiNow-30.commit` = `3b81464a`).
- **Archiv:** `StudiNow-30.xcarchive` vom 10.11.2026 00:03 (`b30-archive.log`: „ARCHIVE SUCCEEDED“, Version 1.0.1,
  `CFBundleVersion` 30, `UFShippedUniversities` = `luh`, Team 78MQGF36BD, nur iPad). Das erste Archiv aus `5d418339`
  (noch Version 1.0) liegt als `StudiNow-30-v1.0-5d418339.xcarchive` daneben und wurde nie hochgeladen.
- **Tests vor dem Einreichen (iPad-Simulator, alle Tests):** auf `5d418339` `b30-test-5d418339.log` und auf `3b81464a`
  `b30-test.log`: je **1392 Tests, 18 übersprungen, 0 Fehler**. Ein Test auf dem iPad des Inhabers fand vor dem
  Einreichen **nicht** statt (iPad nicht erreichbar).
- **Hochgeladen** 10.11.2026 00:06 (`b30-upload.log`: „Upload succeeded“, „EXPORT SUCCEEDED“), von Apple verarbeitet
  (VALID).
- **Eingereicht** 10.11.2026 00:27 MEZ: Versionsseite von 1.0 auf 1.0.1 umbenannt, Build 30 angehängt, Beschreibung und
  Prüfhinweise mit den Jahresabos (`docs/release/APP-STORE.md`), Einreichung `ea7010a8-79cc-4cf4-be0c-5a3107de459e`,
  Zustand WAITING_FOR_REVIEW, Freigabe von Hand (nichts erscheint ohne den Inhaber im Store). Zugleich in der
  TestFlight-Gruppe „LUH-Tester“ zur Beta-Prüfung.
- **Abos in App Store Connect:** beide Monatsabos aus dem Verkauf genommen (10.11.2026); Jahrespreise in allen Ländern
  zum **11.11.2026** geplant (Deutschland Plus 19,99 €, Pro AI 39,99 €; kein Land wird teurer). Bis dahin zeigt StoreKit
  noch 21,99 € und 41,99 €.

### Build 31 (Version 1.0.2, eingereicht)

- **Quelle:** `git archive 0324eb3d` nach `~/Studora-Builds/export-b31` (`tools/pruefe-build-herkunft.sh 31 0324eb3d`:
  keine Abweichung; `StudiNow-31.commit` = `0324eb3d`). Inhalt gegenüber Build 30: siehe Tabelle.
- **Tests:** `b31-test.log` auf `0324eb3d`: **1422 Tests, 18 übersprungen, 0 Fehler** (iPad-Simulator, alle App-Tests).
  App-Kern seit dem letzten grünen Kernlauf (1412 Tests, Stand `68ae7a2b`) unverändert.
- **Archiv:** `StudiNow-31.xcarchive` (`b31-archive.log`: „ARCHIVE SUCCEEDED“), Version 1.0.2, `CFBundleVersion` 31,
  `UFShippedUniversities` = `luh`.
- **Hochgeladen** 10.11.2026 19:28 (`b31-upload.log`: „Upload succeeded“, „EXPORT SUCCEEDED“).
- **TestFlight:** VALID um 19:33; Testhinweis „StudiNow 1.0.2 …“ (de-DE); Gruppe „LUH-Tester“, zur Beta-Prüfung
  gegeben (WAITING_FOR_BETA_REVIEW); intern („Intern (Inhaber)“) sofort IN_BETA_TESTING.
- **Eingereicht** 10.11.2026 20:45 MEZ, nachdem 1.0.1 veröffentlicht war: Versionsseite 1.0.2 neu (Texte von 1.0.1 übernommen,
  Passwort-Satz in Beschreibung und Prüfhinweisen, „Neue Funktionen“, siehe `APP-STORE.md`), Build 31, Freigabe von Hand,
  Zustand WAITING_FOR_REVIEW. Vorher: Datenschutzerklärung mit „Uni-Zugang“ auf studinow.app hochgeladen; App-Verfügbarkeit
  neu angelegt (alle Länder außer China; in der EU erst nach dem Händlerstatus des Inhabers). Mit echten LUH-Konten am iPad noch nicht geprüft (Uni-Zugang speichern, Sync aller Portale).

## Commit eines Archivs nachweisen

1. **Export-Ordner gegen Commit:** `tools/pruefe-build-herkunft.sh 25 d08cae54` packt `git archive d08cae54` in einen
   leeren Ordner und vergleicht mit `~/Studora-Builds/export-b25`. Erlaubt sind nur die beim Bauen erzeugten Dateien
   `apps/apple/Config/Team.xcconfig`, `apps/apple/UniFlow.xcodeproj`, `apps/apple/UniFlow/Info.plist` und
   `apps/apple/Packages/UniFlowCore/.swiftpm`; jede andere Abweichung heißt: anderer Stand.
2. **Archiv gegen Export-Ordner:** `grep -m1 export-b25/apps/apple ~/Studora-Builds/b25-archive.log`.
3. **Build-Nummer im Archiv:**
   `/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" ~/Studora-Builds/StudiNow-25.xcarchive/Info.plist`
   und in der App selbst `.../Products/Applications/UniFlow.app/Info.plist` (`CFBundleVersion`, `UFShippedUniversities`).
4. **Upload:** `b25-upload.log` endet mit „Uploaded UniFlow“; in App Store Connect (TestFlight → iOS-Builds) steht
   dieselbe Build-Nummer 25 unter Version 1.0.

So bauen (wie Build 21 bis 25): `git archive <commit> | tar -x -C ~/Studora-Builds/export-bNN`,
`Config/Team.xcconfig` hineinkopieren, `xcodegen generate`, `xcodebuild archive` (Release, generic/platform=iOS) nach
`~/Studora-Builds/StudiNow-NN.xcarchive`, dann `xcodebuild -exportArchive` mit Upload. Nie aus einem Arbeitsordner mit
uncommitteten Änderungen bauen. Empfehlung: nach dem Upload einen Git-Tag `ios-1.0-bNN` auf den Commit setzen.

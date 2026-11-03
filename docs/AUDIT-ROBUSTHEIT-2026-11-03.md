# Audit Robustheit vor dem App-Store-Start (03.11.2026)

Frage: Was kann auf echten iPads mit echten, großen Daten abstürzen, Daten verlieren, hängen oder sich schlecht
verhalten? Maßstab ist ein echtes LUH-Konto: rund 1000 Dateien (5,5 GB), 212 Kurse über 8 Semester, 27 Nachrichten,
125 Anzeigen am Schwarzen Brett.

Geprüft: Speicherweg von Notizen und Tinte (DocumentStore, SyncEngine-Journal, StrokeConverter), Downloads
(`UniDownloads`), Datenbank (Transaktionen, Migrationen, WAL), Container-Wechsel, Speicher voll, Hintergrundabgleich,
erzwungene Entpackungen (`!`, `try!`, `as!`, Indizes), `@EnvironmentObject` in Dialogen, große Datenmengen
(Abfragen, Vorschaubilder, Editor laut `docs/EDITOR-MESSUNG.md`), Nebenläufigkeit (doppelte Abgleiche, ChatGPT-Token)
und Datenschutz in Protokollen und temporären Dateien seit `docs/SICHERHEITSKORREKTUREN-2026-11-03.md`.

Kurzfassung: Der Speicherweg der Notizen und die Downloads sind sorgfältig gebaut (atomares Ersetzen, Journal mit
gemeldeten Schreibfehlern, Rücksprung bei gescheitertem Eintrag); ein Datenverlust-Pfad wurde nicht gefunden. Gefunden
und behoben wurden vier Fehler: ChatGPT-Verbindung galt bei zwei gleichzeitigen KI-Anfragen als abgelaufen, eine
Stud.IP/LSF-Sitzungskennung landete öffentlich im Systemprotokoll, Vorschaubilder der Bibliothek wuchsen ohne Grenze im
Speicher, und der Konto-Export blieb dauerhaft im gemeinsamen tmp-Ordner. Größter offener Punkt war die nicht-lazy
Bibliotheksliste bei Bereichen mit Hunderten Dateien (P2).

**Stand Nachtrag (03.11.2026, abends):** P2-1, P2-2, P3-1 bis P3-5 und P3-7 sind umgesetzt und getestet (Tabelle
„Nachtrag“ unten). P2-3 bleibt eine Gerätemessung; die Empfehlung für den Editor steht dort. Offen bleiben nur P3-6
(Index, für V1 nicht nötig) und P3-8 (Absicherung `people[index]`, heute durch den Aufrufer gesichert).

## Behoben (mit Tests)

| # | Fund | Ort | Korrektur | Test |
|---|---|---|---|---|
| F1 | **ChatGPT: zwei gleichzeitige KI-Anfragen kurz vor Tokenablauf erneuerten beide mit demselben Refresh-Token.** OpenAI rotiert es; die zweite Erneuerung bekam `invalid_grant`, `markReauth` setzte `needsReauth`, die Verbindung galt als abgelaufen („bitte neu verbinden“), obwohl die erste Erneuerung gelungen war. Dazu: `return state.credentials!.accessToken` konnte nach einem Trennen während der Erneuerung abstürzen bzw. das Trennen wurde durch die späte Antwort rückgängig gemacht (Zugangsdaten wieder gespeichert). Belegt: der neue Test schlägt ohne Korrektur mit `chatgpt_login_needed` fehl. | `Packages/UniFlowCore/Sources/UniFlowCore/AI/ChatGPTSession.swift:139, 303-331, 359` | `refreshOnce()`: höchstens eine Erneuerung, weitere Aufrufer warten auf dieselbe (`refreshing: Task`); nach der Antwort nur übernehmen, wenn noch dasselbe Refresh-Token gespeichert ist; kein `!` mehr. | `ChatGPTSessionTests.testConcurrentAccessTokenRefreshesOnce`, `testDisconnectDuringRefreshDoesNotRestoreCredentials` |
| F2 | **Sitzungskennung im Systemprotokoll.** Die LSF-Anmeldung protokolliert `url.path` mit `privacy: .public`. LSF (HIS) hängt die Sitzung als `;jsessionid=…` an den Pfad, und `URL.path` liefert sie mit (geprüft: `/qisserver/rds;jsessionid=ABC123.lsf1`). Jede sysdiagnose enthielt damit eine gültige LSF-Sitzung. | `apps/apple/UniFlow/Services/HildesheimConnection.swift:726` | Neues `HildesheimCAS.loggablePath(_:)` entfernt Pfad-Parameter (`;…`) aus jedem Abschnitt; das Protokoll nutzt es. | `AuditRobustheit20261103Tests.testLoggablePathDropsSessionParameters` |
| F3 | **Vorschaubilder der Bibliothek ohne Speichergrenze.** `UFThumbnails.memory` war ein Wörterbuch, das jede je gezeichnete Vorschau des Containers hielt (220 × 311 px, Maßstab 1 → 274 KB je Bild, gemessen). Bei 1000 Dateien (Bereich „Neu“ nach dem ersten Abgleich, Filterchips über alle Dateien) rund 270 MB, die nie frei wurden. Außerdem lud und zeichnete jede Kachel ihre PDF auch dann noch, wenn sie schon nicht mehr zu sehen war. | `apps/apple/UniFlow/Views/Library/LibraryPage.swift:798-863` | `NSCache` mit `countLimit` 300 und `totalCostLimit` 96 MB (Kosten = Bitmap-Bytes); Herausgefallenes kommt von der Platte (`thumbs/*.jpg`). Nach dem Plattentreffer: abgebrochene Aufgabe (`Task.isCancelled`) lädt keine PDF mehr. | `AuditRobustheit20261103AppTests.testThumbnailsSkipCancelledTilesAndCacheWithLimit` |
| F4 | **Konto-Export (ZIP mit allen Kontodaten) dauerhaft im gemeinsamen tmp-Ordner.** `studinow-export.zip` lag direkt in `tmp/`, an `AppTemp` vorbei: kein Aufräumen beim Start, nicht mit „Konto löschen“/„Daten dieser Hochschule löschen“, sichtbar für jedes nächste Konto auf dem iPad. | `apps/apple/UniFlow/Services/StudoraAccountLink.swift:222, 232` | `StudoraAccountLink.exportFileURL()` legt die Datei über `AppTemp.file("konto-export", …)` in den Teilen-Ordner des Containers. | `AuditRobustheit20261103AppTests.testAccountExportLivesInContainerTempFolder` |

Zusätzlich neu: `LargeDataScaleTests` (Kern) baut ein Konto wie oben (212 Kurse, 8 Semester, 30 Module, 1000 Dateien,
10 000 Seitentexte) und prüft, dass die Seiten der App mit 200 antworten und schnell sind (Messwerte unten).

Testläufe: Kern `swift test` 894 Tests, 0 Fehler (8 übersprungen wie bisher). App (eigener Simulator
FF296413-…, Abgeleitete Daten `scratchpad/dd-robust`): `AuditRobustheit20261103AppTests`, `LocalDocumentsAppTests`,
`ShareExportTests`, `DemoAppTests`, `PlusWritingLockTests`, `StudoraAccountAppTests` – 59 Tests grün. Neue App-Testdatei
erfordert `xcodegen generate` (Projekt ist nicht eingecheckt).

## Nachtrag: offene Funde umgesetzt (03.11.2026, abends)

| # | Fund | Ort | Korrektur | Test |
|---|---|---|---|---|
| P2-1 | **Bibliothek rendert alle Kacheln und Zeilen auf einmal.** Belegt: Bereich „Neu“ mit 500 Dateien startete vorher **500** Vorschau-Ladevorgänge (Kacheln und Liste), jetzt **24** (Kacheln, iPad quer 1180 × 820) bzw. **10** (Liste). | `apps/apple/UniFlow/Views/Library/LibraryPage.swift:385-410` (`itemsView`, `gridColumns`) | Raster `LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16)`, Liste `LazyVStack(spacing: 0)` im bestehenden `ScrollView` von `UFContent`. Kacheln entstehen erst nahe am Bild, ihr `.task` (Vorschau) startet beim Erscheinen und bricht beim Verschwinden ab; `UFThumbnails` überspringt abgebrochene seit F3. Optik unverändert: gleiche Spaltenzahl, Spaltenbreite, Zeilenhöhe und Lage jeder Zelle wie `UFGridLayout(spacing: 16, minWidth: 150)` (geprüft bei 700, 900 und 1128,8 pt Breite, Abweichung < 0,5 pt). | `AuditRobustheit20261103AppTests.testLibraryWith500FilesLoadsOnlyVisibleThumbnails` (schlug vor der Korrektur mit 500 > 120 fehl), `testLazyGridPlacesTilesLikeTheOldGrid` |
| P2-2 | **Zweiter Abgleich desselben Containers nach Wechsel A → B → A.** | `apps/apple/UniFlow/Services/DataContainers.swift:140-167` (`ContainerRuns`), `:383-385` (`activate`); `StudIPSync.swift:522-525`; `HildesheimConnection.swift:383-392`; `Packages/UniFlowCore/Sources/UniFlowCore/UniDownloads.swift:36-129` | Drei Sperren: (1) `ContainerRuns` merkt je Ablageordner (Stud.IP- bzw. Learnweb-Ordner des Containers), welches Abgleich-Objekt gerade läuft; `StudIPSync.run(client:)` und `HildesheimConnection.run` beginnen keinen zweiten Lauf, solange ein anderes Objekt desselben Containers läuft (Rückgabe `nil` wie bei „läuft schon“). (2) Der Abgleich-Anstoß am Ende von `activate` prüft `isSyncing(key)` (kennt auch abgelöste Objekte) und stößt dann nichts an; der nächste Wechsel in den Vordergrund holt ihn nach. (3) `UniDownloads` hat je Lauf einen eigenen Zwischenordner `.laden/<Lauf>`; `begin()` entfernt nur Reste abgebrochener Läufe (auch die alte Ablage direkt in `.laden`), nie den Ordner eines laufenden; `end()` entfernt den eigenen und `.laden` nur, wenn leer (`rmdir`). Das laufende Objekt wird bewusst nicht wiederverwendet: es hängt am alten `ActiveContainer` (eigene Datenbankverbindung). | `DataSeparationAppTests.testSwitchingBackDuringARunningSyncStartsNoSecondRun`; Kern `AuditRobustheit20261103Tests.testSecondRunDoesNotRemoveTheTempFolderOfARunningRun` (zweiter `begin()` mitten im Download des ersten) |
| P2-3 | **Editor-Speicherspitze am ältesten iPad.** Nicht messbar ohne Gerät; nicht umgesetzt (Editor-Dateien bearbeitet gerade ein anderer Auftrag). | – | Empfehlung siehe P2-3 unten. | – |
| P3-1 | **Erste Suche füllt die Suchform aller alten Seitentexte in einer Transaktion.** | `Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Search/ScriptSearch.swift:436-459` (`backfillSearchForms`), `Endpoints/SearchEndpoints.swift:24` | `ScriptSearch.backfillSearchForms(db, chunk: 500)`: eigene kurze Transaktionen zu je 500 Zeilen mit `Task.yield()` dazwischen, vor der Transaktion der Suche aufgerufen; danach findet `findPages` keine leeren Zeilen mehr (sein Nachfüllen bleibt nur als Rest-Sicherung). Andere Anfragen kommen zwischen den Stücken an die eine Verbindung. Python (`find_pages` am PC) unverändert: dort trifft es keine iPad-Nutzer. | Kern `AuditRobustheit20261103Tests.testBackfillOfSearchFormsRunsInChunksAndLetsOtherRequestsThrough` (ein zweiter Aufrufer sieht Zwischenstände), `testSearchEndpointFindsOldPageTexts`; `LocalSearchTests` unverändert grün |
| P3-2 | **WAL schrumpft nicht.** | `Packages/UniFlowCore/Sources/UniFlowCore/Store/SQLiteDatabase.swift:336-344` | `PRAGMA journal_size_limit=8388608` (8 MB, `SQLiteConnection.journalSizeLimit`) beim Öffnen jeder Verbindung: nach einem Checkpoint kürzt SQLite die `-wal`-Datei beim nächsten Schreiben auf höchstens 8 MB. | Kern `testDatabaseLimitsTheWriteAheadLog` (24 MB WAL nach einer Runde, nach dem nächsten Schreiben ≤ 8 MB) |
| P3-3 | **Mehrere Fenster teilen Navigation und Zustand.** | `apps/apple/UniFlow/UniFlowApp.swift:54-150, 191-261` (`SceneObjects`, `SceneRegistry`); `Views/Timer/StudyTimer.swift:286` | `UFRouter`, `ShellState`, `UFToastCenter`, `UFOverlay` legt jedes Fenster selbst an (`SceneObjects`, `@StateObject` je Szene); Dialog-Host, Meldungen und `onOpenURL` hängen am Fenster. Gemeinsam bleiben Konto, Container, Sitzung, Abgleich, Zeitmesser und Hintergrundabgleich. `SceneRegistry` (schwach gehalten) kennt alle offenen Fenster und das zuletzt aktive: die Frage „Bitte neu anmelden“ erscheint einmal im aktiven Fenster, nach einem Abgleich des StudiNow-Kontos lädt jedes Fenster neu; Debug-Startparameter gelten nur für das erste Fenster. Der Zeitmesser meldet sich im jeweils aktiven Fenster. | `AuditRobustheit20261103AppTests.testEachWindowHasItsOwnNavigationToastsAndDialogs` |
| P3-4 | **Swift-6-Warnungen zu geteilten Variablen.** | `Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Weekly/WeeklyMore.swift:130-161` | `extra` entsteht im Block von `WeeklyGate.shared.run`, die Transaktion bekommt `let`-Kopien (`finalCtx`, `finalRes`). `swift build`: keine Warnung mehr in `WeeklyMore.swift` (vorher 4). | Kern-Testlauf (Verhalten unverändert) |
| P3-5 | **Sehr lange Stud.IP-Texte als ein `Text`.** | `apps/apple/UniFlow/Design/UFComponents.swift:1021-1077` (`UFLongText`); `Views/NewsCard.swift:143-146`, `Views/Services/BulletinCard.swift:146`, `Views/Modules/StudIPTextsCard.swift:246` | `UFLongText`: bis 4000 Zeichen ein `Text` wie bisher; längere Texte in Abschnitten in einem `LazyVStack` (Trennung nur an Zeilenenden, ab 2000 Zeichen vor der nächsten Leerzeile, spätestens ab 4000 an jedem Zeilenende). Zeilenabstand an den Nahtstellen gleich (je Abschnitt halbe Zeilenluft oben und unten durch `ufFont`), jeder Abschnitt auswählbar, VoiceOver liest der Reihe nach. Blubber-Beiträge (`StudIPTextsCard.swift:194`) bleiben ein `Text` je Beitrag (kurz, zu einem Element zusammengefasst). | `AuditRobustheit20261103AppTests.testLongTextIsSplitAtLineEndsOnly`, `testReaderShowsVeryLongTextInParagraphsInOrder` (50 000 Zeichen im Leser einer Anzeige); `NewsCardAppTests`, `BulletinAppTests`, `StudIPTextsAppTests` unverändert grün (ihre Texte liegen unter 4000 Zeichen) |
| P3-7 | **Hilfe für gehostete Ansichtstests.** | `apps/apple/UniFlowTests/HostedEnvironment.swift` | `hostWithEnvironment(_:api:size:studip:)` setzt alle neun Umgebungsobjekte der Wurzel (`AccountStore`, `ContainerManager`, `Session`, `StudIPSync`, `UFRouter`, `ShellState`, `UFToastCenter`, `UFOverlay`, `StudyTimer`) sowie Dialog- und Meldungs-Host; eigene Temp-Ordner, UserDefaults-Suite und Schlüsselbund-Dienste, Aufräumen am Testende. Dazu `wait`, `pump`, `labels()` und `accessibilityAutomation`. Alle neuen Ansichtstests dieses Nachtrags hosten darüber. | die Tests oben |

Neue Dateien: `apps/apple/UniFlowTests/HostedEnvironment.swift` (danach `xcodegen generate` in `apps/apple`).

Testläufe Nachtrag: Kern `swift test` 898 Tests, 0 Fehler (8 übersprungen wie bisher). App (Simulator FF296413-…,
Abgeleitete Daten `scratchpad/dd-robust2`): `AuditRobustheit20261103AppTests`, `LocalDocumentsAppTests`,
`NewsCardAppTests`, `BulletinAppTests`, `StudIPTextsAppTests`, `DataSeparationAppTests`, `AuditRunde0910AppTests`,
`TimetableLocalAppTests` – 78 Tests grün. Ganze `UniFlowTests` (ohne
`UniversityLoginPolicyTests/testTypingAndSubmittingKeepsNothingInTheApp`): 708 Tests, 5 übersprungen, 3 Tests rot, keiner
durch diesen Nachtrag: `NoServerStateTests.testNotConnectedShowsCardAndPlainText` und
`testNoPromisesForWeeklyTestsAndNoSoonBadges` erwarten „Noch keine Tests.“, `ConnectStudIPCard.swift` sagt nach der
laufenden UX-Überarbeitung (anderer Auftrag, noch nicht eingecheckt) „Tests erstellt StudiNow mit deinem ChatGPT …“;
`AbnahmeV1AppTests.testSidebarShowsOnlyAreasWithAFunctionOnTheDevice` (Zeile 59) setzt einen Simulator ohne Konto
voraus – auf FF296413 ist seit 19:30 ein Konto mit Container angemeldet, und der lokale Build hat einen iCloud-Container
(`UFCloudKitContainer`), also ist die Community verbunden.

## Messwerte große Datenmenge (Kern, Debug-Build, Mac)

`LargeDataScaleTests.testHotRoutesWithLargeAccount`, 212 Kurse, 1000 Dateien, 10 000 Seitentexte mit Suchform:

| Route | Zeit |
|---|---|
| `/api/dashboard` | 0,017 s |
| `/api/library` | 0,007 s |
| `/api/modules`, `/api/modules/1` | 0,012 s, 0,001 s |
| `/api/courses` | 0,013 s |
| `/api/older-semesters` | 0,012 s |
| `/api/due` erster Aufruf / danach | 0,32 s / 0,000 s |
| `/api/search` (Treffer / kein Treffer) | 0,028 s / 0,014 s |

`EXPLAIN QUERY PLAN` der Zählung je Kurs (`SELECT COUNT(*) FROM files f WHERE f.course_id=c.id`,
`OlderSemesters.swift:82-83`, `FilesEndpoints.swift:18`): `SCAN f` je Kurs, also 212 × 1000 Zeilen – bei dieser
Größe trotzdem 13 ms. Ein Index ist für V1 nicht nötig (siehe P3-6). Ein iPad ist grob 2–4× langsamer als der Mac im
Debug-Build; alles bleibt unter 0,1 s außer der Termin-Erkennung (läuft nach Abgleichen, Ergebnis gemerkt).

## P1 – vor dem Release

Keine offenen P1-Funde nach den Korrekturen F1–F4. (F1 und F3 wären P1/P2 gewesen.)

## P2 – bald, spätestens vor großen Konten

**P2-1 Bibliothek rendert alle Kacheln und Zeilen eines Bereichs auf einmal.** *Erledigt (Nachtrag): `LazyVGrid`/`LazyVStack`, 24 statt 500 Vorschauen.*
`apps/apple/UniFlow/Views/Library/LibraryPage.swift:371-377`: Raster über `UFGridLayout` (eigenes `Layout`, nie lazy),
Liste über `VStack`. Jede Kachel startet sofort ihr `.task` für die Vorschau. Im Bereich „Neu“ nach dem ersten Abgleich
(`build`, Zeile 186: alle Dateien mit Status „neu“), bei Filterchips über alle Dateien und in großen Kursordnern sind
das Hunderte bis 1000 Aufgaben: jede lädt die ganze PDF über das lokale Backend (gemappt, `FilesEndpoints.swift:90`),
öffnet sie mit `PDFDocument(data:)` und zeichnet Seite 1; dazu liest `inkThumbnail` (Zeile 868) das ganze Journal der
Datei. Folge: Minuten Hintergrund-CPU, Akku, und die Bitmaps bleiben zusätzlich in `@State` jeder Kachel (F3 begrenzt
nur den gemeinsamen Speicher). Korrektur: Liste auf `LazyVStack`, Raster auf `LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)])`
(Optik prüfen), dann greift auch die Abbruchprüfung aus F3; zusätzlich Vorschau aus der Datei statt aus den Bytes
(`PDFDocument(url:)` über `LocalFiles.url(stored:)`). Bis dahin: Bereich „Neu“ auf z. B. 200 Einträge mit
„Mehr anzeigen“ begrenzen.

**P2-2 Zweiter Abgleich desselben Containers nach einem Hin- und Rückwechsel.** *Erledigt (Nachtrag): `ContainerRuns`, Prüfung in `activate`, Zwischenordner je Lauf.*
`apps/apple/UniFlow/Services/DataContainers.swift:330-357`: `activate` legt für den Container ein neues `StudIPSync`
an und ruft `runIfDue()`; die Sperre `isRunning` gilt nur je Objekt. Läuft der Abgleich des alten Objekts für
denselben Container noch (Wechsel A → B → A während eines langen Abgleichs), starten zwei Läufe auf denselben Ordner.
`UniDownloads.begin()` (`Packages/UniFlowCore/Sources/UniFlowCore/UniDownloads.swift:87-93`) löscht dabei den
Zwischenordner `.laden` des laufenden Abgleichs: dessen Downloads scheitern („Datei nicht gespeichert“). Kein
Datenverlust (atomares `rename`, alte Fassung bleibt), aber Fehlermeldungen und doppelte Last. Korrektur: im
`Task` am Ende von `activate` und in `StudIPSync.run`/`HildesheimConnection.run` zusätzlich
`containers.isSyncing(key)` prüfen (die Liste `syncs` kennt das alte Objekt), bzw. beim Wechsel `stopSyncs(oldKey)`
wie beim Löschen.

**P2-3 Editor-Speicherspitze bei dichten Dokumenten am Gerät messen.** *Offen (Gerätemessung); Empfehlung direkt darunter.*
Laut `docs/EDITOR-MESSUNG.md` (Abschnitt 10) Spitze 380 MB während einer Speicherrunde mit 43,5 MB Dokument, beim
schnellen Blättern über volle Seiten 510–590 MB (M4 offen). Auf iPads mit 4 GB RAM liegt die Jetsam-Grenze grob bei
1,5–2 GB; zusammen mit P2-1 (Bibliothek im Hintergrund) und Aufnahmen kann es eng werden. Korrektur: Abnahmeliste 5.1/18
am ältesten unterstützten iPad mit Instruments (Allocations, Memory-Warnings); M4 (Laden weggescrollter Seiten
abbrechen) umsetzen, falls die Spitze dort über 1 GB liegt.

*Nachtrag (Empfehlung für den Editor-Auftrag, Editor-Dateien hier nicht geändert):* Eine Obergrenze der
Zeichenauflösung über `ProcessInfo.processInfo.physicalMemory` wäre billig (`PDFEditorController.renderScale(screen:zoom:limit:)`,
heute `limit: 8`, also Bildschirm 2 × Stufe 4), trifft laut `docs/EDITOR-MESSUNG.md` 3.5 aber nicht die Spitze: Zoomen
bis 6-fach kostete höchstens 32 MB. Die Spitzen kommen aus der Speicherrunde (380 MB) und dem schnellen Blättern
(510–590 MB, M4). Darum in dieser Reihenfolge: (1) M4 – in `loadContent(into:)` (`PDFEditorController.swift`, rund
Zeile 823) nach `await store.objects(…)` prüfen, ob das Overlay noch im Bild ist (nicht in `parked`), sonst
`store.drawing(…)` gar nicht erst dekodieren; (2) `didReceiveMemoryWarning` (rund Zeile 800) gibt heute nur fremde
Ebenen geparkter Seiten frei – dort auch deren Zeichnung leeren (`canvas.drawing = PKDrawing()`, `loaded = false`, beim
Zurückscrollen lädt `loadContent` neu); (3) erst wenn die Gerätemessung auf 4-GB-iPads über 1 GB zeigt:
`limit: ProcessInfo.processInfo.physicalMemory <= 4 << 30 ? 6 : 8` (Tinte bei 6-fachem Zoom minimal weicher, M5).

## P3 – Pflege

**P3-1 Erste Suche mit alten Seitentexten blockiert die Datenbank.** *Erledigt (Nachtrag): `backfillSearchForms` in Stücken zu 500 Zeilen.* `Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Search/ScriptSearch.swift:415-418`
füllt beim ersten Suchen alle `page_texts.search IS NULL` nach, in derselben Transaktion. Gemessen mit 10 000
Seiten: 5,3 s (Debug, Mac); solange wartet jede andere Anfrage der App (eine Verbindung, `SQLiteDatabase` ist ein
Actor). Betrifft nur Datenbanken vom PC bzw. aus Builds vor der Spalte; neue Zeilen schreibt `ScriptSearch.swift:172`
mit Suchform. Korrektur: Nachfüllen einmalig in Stücken zu 500 Zeilen nach dem Öffnen (eigene Transaktionen) statt in
der Suche.

**P3-2 WAL wächst und schrumpft nicht.** *Erledigt (Nachtrag): `journal_size_limit` 8 MB.* `Packages/UniFlowCore/Sources/UniFlowCore/Store/SQLiteDatabase.swift:336`
setzt `journal_mode=WAL`, aber kein `journal_size_limit`. Nach Editor-Runden mit großen Dokumenten bleibt die
`-wal`-Datei 47–94 MB groß (EDITOR-MESSUNG 3.2/10). Korrektur: `PRAGMA journal_size_limit=16777216` nach dem Öffnen.

**P3-3 Mehrere Fenster teilen Navigation und Zustand.** *Erledigt (Nachtrag): `SceneObjects` je Fenster.* `UIApplicationSupportsMultipleScenes: true`
(`apps/apple/project.yml:87`), aber `router`, `shell`, `toast`, `overlay` sind `@StateObject` der App
(`apps/apple/UniFlow/UniFlowApp.swift:76-79`): zwei Fenster springen gemeinsam zwischen Seiten, Meldungen erscheinen
in beiden. Dokumente sind abgesichert (`OpenDocuments`). Korrektur: diese vier je Szene anlegen (in `RootView`) oder für
V1 nur eine Szene erlauben.

**P3-4 Swift-6-Warnungen zu geteilten Variablen.** *Erledigt (Nachtrag).* `Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Weekly/WeeklyMore.swift:139-158`
(`extra`, `promptCtx`, `res` in `WeeklyGate.shared.run { … }` bzw. `transaction`). Heute kein Wettlauf (der Block läuft
einmal nacheinander), wird im Swift-6-Modus aber ein Fehler. Korrektur: `extra` in den Block holen, `let`-Kopien an die
Transaktion geben.

**P3-5 Sehr lange Stud.IP-Texte als ein `Text`.** *Erledigt (Nachtrag): `UFLongText`.* Volltexte bis 50 000 Zeichen (`StudIPTexts.maxText`) werden als ein
`Text(...).textSelection(.enabled)` gesetzt (`apps/apple/UniFlow/Views/Modules/StudIPTextsCard.swift:194, 246`).
Layout eines so langen Textes kostet am iPad spürbar Hauptthread. Korrektur: nach Absätzen in `LazyVStack` teilen.

**P3-6 Index für Dateien je Kurs.** *Offen (für V1 nicht nötig, Schemaänderung zuerst in `app/db.py`).* Kein Index auf `files(course_id)` (Schema aus `app/db.py`,
`Store/SchemaSQL.swift:22`). Heute unkritisch (oben). Wenn Konten mit mehreren tausend Dateien kommen:
`CREATE INDEX IF NOT EXISTS ix_files_course ON files(course_id)` zuerst in `app/db.py`, dann `gen-swift-schema.py`.

**P3-7 Tests mit fehlendem `@EnvironmentObject`.** *Erledigt (Nachtrag): `hostWithEnvironment`.* Gesucht wurde nach Dialogen (`.sheet`, `.fullScreenCover`,
`.ufModal`), deren Inhalt ein Umgebungsobjekt liest, das der Präsentierende nicht hat. Ergebnis: in der App kein Fund –
alle neun Umgebungsobjekte (`AccountStore`, `ContainerManager`, `Session`, `StudIPSync`, `UFRouter`, `ShellState`,
`UFToastCenter`, `UFOverlay`, `StudyTimer`) werden nur an der Wurzel gesetzt (`UniFlowApp.swift:64-80`), außen um
`UFModalHost`, Toast und Zeitmesser; Sheets erben sie, es gibt keinen `UIHostingController` und kein `present` mit
SwiftUI-Inhalt (nur `UIActivityViewController`, `LibraryDialogs.swift:532`). Der heutige Absturz (`UFReloadModifier`)
war ein Test, der eine Ansicht ohne diese Objekte gerendert hat. Korrektur: im Testziel eine Hilfe
`hostWithEnvironment(_:)`, die alle neun setzt, und neue Ansichtstests nur darüber.

**P3-8 Erzwungene Entpackungen.** *Offen (nur der billige `guard` für leeres `people`; heute durch den Aufrufer gesichert).* 65 Stellen mit `!` in App und Kern durchgesehen (`try!` nur für feste Regex in
`HildesheimText.swift:9`, `WeeklyIndex.swift:7`; `preconditionFailure` nur für feste Muster in `PyText.swift:49, 87`;
`fatalError` nur in `init(coder:)`). Alle übrigen sind durch Aufbau gesichert (nicht leere Literale, vorher geprüfte
Schlüssel, `filter` davor). Einzige echte Absturzstelle war `ChatGPTSession.swift` (F1). Indizes: `people[index]` in
`CommunityChannelView.swift:727` ist durch das Schließen des Lesers vor dem Entfernen gesichert; bei leerem `people`
würde es abstürzen – der Aufrufer übergibt nie eine leere Liste, ein `guard` im `init` wäre billig.

## Ohne Befund (geprüft)

- **Downloads abgebrochen / App beendet:** `.part` im Zwischenordner, `rename` ersetzt atomar, alte Fassung als Klon
  bis zum Datenbank-Eintrag, beim nächsten Lauf `begin()` räumt auf (`UniDownloads.swift:103-153`). Speicher voll
  wird erkannt und gemeldet (`StudIPSync.swift:651`, `DeviceStorage.isFull`).
- **Notizen:** Journal-Schreibfehler werden je Seite gemerkt, wiederholt und angezeigt (`SyncEngine.swift:926-995`);
  Sichern beim Wechsel in den Hintergrund mit Hintergrundzeit (`DocumentStore.swift:966-978`); `settlePending`
  wartet laufende Umrechnungen ab. Zwei Fenster mit demselben Dokument: `OpenDocuments`.
- **Datenbank:** Migration in einer Transaktion, falsche Hochschule bricht ohne Änderung ab (`Migrations.swift:191-252`),
  `busy_timeout` 5 s, WAL, Fremdschlüssel an. Dateischutz `completeUntilFirstUserAuthentication` für Ordner,
  Datenbank und Downloads (Hintergrundabgleich bei gesperrtem Gerät möglich). Learnweb-Schlüssel ist bewusst
  `WhenUnlocked`; der Hintergrund überspringt ihn bei gesperrtem Gerät (`BackgroundSync.swift:261`,
  `HildesheimConnection.swift:487`).
- **Doppelte Abgleiche im selben Container-Objekt:** Vordergrund, Zeitplan, „Jetzt abgleichen“ und Hintergrund prüfen
  `isRunning` vor und nach dem einzigen `await` (`StudIPSync.swift:516-524`, `HildesheimConnection.swift:375-383`);
  Hintergrund zusätzlich `containers.isSyncing` (`BackgroundSync.swift:489`). Lücke nur beim Wechsel (P2-2).
- **Protokolle:** nur drei `Logger`; Fehlertexte des lokalen Backends `.private` (`LocalRouter.swift:222`),
  Wochentest-Takt ohne personenbezogene Inhalte; kein `print` außerhalb von `#if DEBUG`-Beispieldaten
  (`CalendarSample.swift:72`). Einziger Fund F2.
- **URL-Schema `uniflow://`:** nur Lösungsdateien und Gruppenbeitritt mit Rückfrage (Sicherheitskorrektur 6/7);
  Links aus fremdem Text nur `http(s)` (`SafeLinks`).
- **Dateien außerhalb des Containers:** Teilen-Dateien über `AppTemp` je Container; einzige Ausnahme war F4.

## Geänderte und neue Dateien

- `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/AI/ChatGPTSession.swift` (F1)
- `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Hildesheim/HildesheimCAS.swift` (F2, `loggablePath`)
- `apps/apple/UniFlow/Services/HildesheimConnection.swift` (F2)
- `apps/apple/UniFlow/Views/Library/LibraryPage.swift` (F3, nur `UFThumbnails`)
- `apps/apple/UniFlow/Services/StudoraAccountLink.swift` (F4)
- Tests: `Packages/UniFlowCore/Tests/UniFlowCoreTests/ChatGPTSessionTests.swift` (2 neu),
  `AuditRobustheit20261103Tests.swift` (neu), `LargeDataScaleTests.swift` (neu),
  `apps/apple/UniFlowTests/AuditRobustheit20261103AppTests.swift` (neu)

Nachtrag (offene Funde):

- Kern: `UniDownloads.swift` (P2-2), `LocalBackend/Search/ScriptSearch.swift` und `LocalBackend/Endpoints/SearchEndpoints.swift`
  (P3-1), `Store/SQLiteDatabase.swift` (P3-2), `Store/Migrations.swift` (nur Kommentar), `LocalBackend/Weekly/WeeklyMore.swift` (P3-4)
- App: `UniFlow/Views/Library/LibraryPage.swift` (P2-1, nur `itemsView` und `gridColumns`), `UniFlow/Services/DataContainers.swift`,
  `UniFlow/Services/StudIPSync.swift`, `UniFlow/Services/HildesheimConnection.swift` (P2-2), `UniFlow/UniFlowApp.swift`,
  `UniFlow/Views/Timer/StudyTimer.swift` (P3-3), `UniFlow/Design/UFComponents.swift`, `UniFlow/Views/NewsCard.swift`,
  `UniFlow/Views/Services/BulletinCard.swift`, `UniFlow/Views/Modules/StudIPTextsCard.swift` (P3-5)
- Tests: `UniFlowTests/HostedEnvironment.swift` (neu, P3-7), `UniFlowTests/AuditRobustheit20261103AppTests.swift` (5 neu),
  `UniFlowTests/DataSeparationAppTests.swift` (1 neu), Kern `AuditRobustheit20261103Tests.swift` (4 neu)

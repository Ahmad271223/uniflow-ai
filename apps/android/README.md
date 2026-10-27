# UniFlow für Android

**Stand 27.10.2026:** Kern und App vorhanden. Die App ist ein Client des UniFlow-Servers: des gehosteten Dienstes
(UniFlow-Konto, Vertrag G1) oder des eigenen PCs im WLAN (`serve.py --lan`, PIN). Sie zeigt Übersicht, Dokumente,
Stundenplan und Lernkalender und schreibt Stift-Notizen im gemeinsamen Notizformat auf PDFs. Alles liegt in einer
lokalen Ablage (SQLite) und wird mit dem Dienst über den Geräte-Abgleich G2 abgeglichen; ohne Netz zeigt die App den
letzten Stand („Stand vom …“) und sendet Änderungen nach, sobald der Dienst erreichbar ist. Gebaut und getestet im
Docker-Bild `ghcr.io/cirruslabs/android-sdk:35`; auf einem echten Gerät noch nicht geprüft (kein Android-Gerät am PC).

## Aufbau

| Modul | Inhalt | Tests |
| --- | --- | --- |
| `core` (Kotlin/JVM, ohne Android) | `ApiClient` (HttpURLConnection, Bearer-Token oder PIN-Cookie), `AccountApi` (G1), `SyncApi` (G2), `AnnotationDocument` (gemeinsames Notizformat, verlustfrei), `AnnotationStore` (base_version, 409 → Zusammenführung → erneut senden), `AnnotationMerge` (Drei-Wege-Regeln), Modelle für Bibliothek, Stundenplan, Lernkalender, Übersicht, lokale Ablage `LocalStore` (SQLite über `SqlDb`, G2-Spalten und Trigger wie beim Dienst, Tombstones, Cursor, Momentaufnahmen), `SyncEngine` (Push/Pull mit Konfliktregeln je Feld), `LocalViews` (Ansichten aus der Ablage) | gegen `packages/shared-contracts/fixtures`: `account/contract.json` (jeder aufgezeichnete Ablauf, Anfrage und Antwort), `sync/cases.json` (als Nachrichten und gegen die Ablage: `SyncEngineContractTest`), `documents/web-editor.json`, `merge/cases.json`; `LocalStoreTest` (Rundlauf, Trigger, Neustart; echtes SQLite über sqlite-jdbc), `LocalViewsTest` |
| `app` (Jetpack Compose, minSdk 26) | Anmeldung (Konto oder PC+PIN), Übersicht, Dokumente nach Modul, PDF mit Stift (`PdfRenderer` + Compose-Canvas, Stift/Rot/Blau/Marker/Radierer, „Nur Stift“), Stundenplan (Woche, Feiertage grün, Fristen, Hinweise), Lernkalender (Woche, Aufgaben abhaken), Hochschul-Anmeldung in der WebView mit Direkt-Download (`UniversityLoginScreen`, `UniversityStore`, `FetchPolicy`, `PdfBoxPageText`), lokaler Notiz-Entwurf mit Nachlieferung (`Draft`, `DraftStore`, `DraftKeeper`, `DraftUploadRules`, `DraftUploadWorker`), Offline-Betrieb (`AndroidSqlDb`, `Stand`, `OfflineRules`, `SyncPushWorker`, `rememberStand`/`StandHinweis`) | reine Regeln ohne Gerät: `RulesTest` (Adressen, Datum), `InkTest` (Stiftgeometrie, Farben, Breite/Deckkraft, Seitenmaß, fremde Objekte), `PdfRulesTest` (PDF-Prüfung), `PdfCacheTest` (atomare Ablage), `AnnotationSessionTest` (serialisiertes Speichern, Entwurf erst nach 2xx weg), `DraftStoreTest` (Entwurf atomar und wiederherstellbar), `DraftRestoreTest` (Entwurf + Serverstand nach `fixtures/merge/cases.json`), `DraftUploadRulesTest` (Nachlieferung: Erfolg/Wiederholung/Abbruch nach Antwortcode), `SyncRulesTest` (Abgleich abwarten), `FetchPolicyTest` (direkt oder Dienst), `PageTextRulesTest` (Grenzen des Seitentexts), `UniversityRulesTest` (Karte „Hochschule“), `OfflineRulesTest` (wann die Ablage einspringt, Text „Stand vom …“) |

Sitzung: Token oder PIN liegen in `EncryptedSharedPreferences` (Android-Schlüsselbund), nie Passwörter. Öffentliche
Adressen nur über https; http nur für private Netze (PC im WLAN). PDFs kommen unverändert vom Server und liegen im
Cache des Geräts (`cache/pdf/<id>-<chdate>.pdf`); übernommen wird nur, was mit `%PDF-` beginnt und groß genug ist
(`PdfRules`), der Download geht erst in eine `.part`-Datei. Eine beschädigte Cache-Datei wird gelöscht und neu geladen.
Abmelden verwirft die Sitzung sofort, der Server-Logout läuft im Hintergrund (5 s Timeout). „Abgleich starten“ fragt
wie `pollBg` im Web `/api/bg` ab, bis der Job fertig ist, und lädt die Übersicht dann neu; die Dokumentliste lädt beim
Zurückkehren in den Vordergrund (ON_RESUME) neu. Beim Neuladen bleibt der bisherige Inhalt stehen, bis die Antwort da ist.

Notizen: Koordinaten in PDF-Punkten wie im Web-Editor, Striche mit denselben Feldern (`type: stroke, tool, color,
width, points, opacity, …`). Speichern mit `base_version`; bei 409 holt `AnnotationStore` den Serverstand, führt je
Seite mit den gemeinsamen Regeln zusammen (Striche beider Geräte bleiben) und sendet erneut. Ein älterer Serverstand
ersetzt nie den lokalen, ungesendeten Stand: `AnnotationSession` serialisiert alle Speichervorgänge (Seitenwechsel ist
währenddessen gesperrt), legt Striche, die während des Sendens dazukommen, auf den bestätigten Stand und sendet sie
nach; beim Verlassen der Ansicht, beim Zurück-Gesten und wenn die App in den Hintergrund geht (ON_STOP) wird gesendet,
Fehler bleiben sichtbar. Ein einzelner Stifttipp wird wie im Web-Editor als kurzer Strich gespeichert; gespeicherte
Farben nur als `#RRGGBB` (sonst Standardfarbe), Breite und Deckkraft werden beim Zeichnen begrenzt. Objekte anderer
Art (Text, Formen, Bilder, Haftnotizen des Web-Editors) werden nicht gezeichnet, aber mit Hinweis angezeigt und beim
Speichern unverändert erhalten.

Verlustfrei: Jede Änderung wird entprellt (500 ms) als Entwurf im App-Speicher abgelegt (`files/drafts/<id>.json`,
`DraftStore`: Schreiben in `.tmp` mit fsync, dann umbenennen – nie ein halber Entwurf), mit Dokument, letzter
bestätigter Basis und deren Version. Gelöscht wird der Entwurf erst, wenn der Dienst das Speichern bestätigt hat (2xx).
Scheitert ein Sendeversuch oder geht die App in den Hintergrund (ON_STOP), plant `DraftUploadWorker` (WorkManager, nur
mit Netz, exponentieller Abstand ab 30 s, eindeutig je Datei, `REPLACE`) die Nachlieferung ein; beim App-Start werden
liegen gebliebene Entwürfe eingeplant (`KEEP`). Der Worker nimmt das Konto-Token aus derselben Sitzung wie die Ansicht
(`EncryptedSharedPreferences`), die WorkManager-Daten enthalten nur die Datei-ID. 409 löst `AnnotationStore.save` auf
(Serverstand holen, zusammenführen, erneut senden, höchstens 3 Versuche); bleibt es dabei, behält der Worker den Entwurf
mit `conflict` (`DraftUploadRules`: 2xx → Erfolg, kein Netz/5xx/408/429 → Wiederholung, 409/401/4xx → Abbruch, Entwurf
bleibt). Beim nächsten Öffnen führt `AnnotationSession.loaded` einen vorhandenen Entwurf mit dem Serverstand nach den
gemeinsamen Regeln zusammen (`AnnotationDocument.mergeDetailed`, `fixtures/merge/cases.json`: Entwurf gewinnt bei
Feldern, Seitenreihenfolge-Konflikt sichtbar), sendet ihn gleich und zeigt wie der Web-Editor „… mit anderem Gerät
zusammengeführt, N Konflikte, dieses Gerät gilt“ bzw. „Seitenreihenfolge auf beiden Geräten geändert – die Reihenfolge
dieses Geräts gilt“; ein vom Worker aufgegebener Entwurf erscheint als „Konflikt“. Kleiner Status im Dokument:
„Entwurf gespeichert“ / „wird gesendet“ / „gesendet“ / „Entwurf gespeichert – wird nachgeliefert“ / „Konflikt“.

## Offline-Betrieb und Geräte-Abgleich (G2)

Die App liest jede Ansicht zuerst aus der lokalen Ablage und holt dann den frischen Stand vom Dienst; fällt der Dienst
aus (kein Netz, 5xx, Zeitüberschreitung – nicht 401/404), bleibt der gespeicherte Stand mit dem Hinweis „Stand vom
27.10.2026, 14:03 – keine Verbindung“ stehen (`OfflineRules`, `rememberStand`, `StandHinweis`). Beim ersten Start ohne
Netz gibt es keinen Stand, dann erscheint wie bisher die Fehlermeldung mit „Erneut versuchen“.

**Ablage** (`files/uniflow-local.db`, `LocalStore` im Kern über `SqlDb`; Android: `AndroidSqlDb` mit
`android.database.sqlite`, JVM-Test: sqlite-jdbc):

- `sync_rows(entity, id, data, sync_version, sync_updated_at, sync_device, dirty, dirty_fields, updated_at)`: eine
  Zeile je G2-Entität und ID (`modules`, `folders`, `course_events`, `event_exceptions`, `study_packages`,
  `study_tasks`, `flashcards`, `settings`; Notizen laufen weiter über `AnnotationStore` und die Entwürfe). `data` ist
  die Serverzeile als JSON, die drei `sync_*`-Spalten sind dieselben wie beim Dienst. Lokale Änderungen setzen `dirty`,
  `dirty_fields` (nur diese Felder gehen beim Push mit) und `updated_at` (Zeitstempel dieses Geräts für die Regel
  „späterer Schreiber gewinnt“); neue Zeilen haben negative IDs bis zur Zuordnung durch den Server.
- Trigger wie in `app/sync.py::ensure_schema`: eine Datenänderung ohne neue Serverversion markiert die Zeile als dirty,
  ein Löschen schreibt einen Tombstone (`sync_tombstones`) – außer während der Übernahme vom Server (`sync_state.applying`),
  die Version und Zeitstempel selbst setzt.
- `sync_state` (Cursor der letzten Antwort, Gerätekennung, letzter Abgleich, Zähler der lokalen IDs) und `snapshots`
  (Momentaufnahmen der Server-Antworten mit Zeitpunkt: Bibliothek `/api/library` mit `download_url`, `content_sha256`,
  `source` je Datei, Übersicht, je Stundenplan-Woche, je Kalenderbereich, zuletzt gesehener Notizstand je Datei).

**Abgleich** (`SyncEngine`, `Repo.syncNow`, nie zwei Läufe gleichzeitig): erst Push aller dirty Zeilen und Tombstones
(Eltern vor Kindern; neue Zeilen mit `local_id` und allen Feldern, geänderte mit `id`, `base_version`, `updated_at` und
nur den geänderten Feldern, Einstellungen mit `local_id` = Schlüssel), dann Pull mit dem Cursor. Antworten werden nach
`fixtures/sync/cases.json` übernommen: `created` ersetzt die lokale ID auch in Fremdschlüsseln anderer Zeilen,
`applied`/`resurrected` setzen die Version, `conflict` legt den Serverstand ab und behält die Felder aus `client_won`,
`deleted` (Tombstone war neuer) entfernt die Zeile, `edit_wins` verwirft die lokale Löschung und holt die Serverzeile
zurück, `ignored` (private Einstellung) ist erledigt, `error` bleibt dirty und wird gemeldet. Beim Pull ersetzt die
Serverzeile den lokalen Stand; ist die Zeile lokal dirty, gilt die Regel des Vertrags je Feld (`updated_at` des Geräts
gegen `sync_updated_at` des Servers), die Basisversion wird die des Servers. Ein Tombstone löscht die Zeile; eine
jüngere lokale Änderung überlebt und wird beim nächsten Push mit allen Feldern wiederhergestellt. Der Abgleich läuft
beim Laden der Übersicht und des Lernkalenders; `SyncPushWorker` (WorkManager, nur mit Netz, ein Name) liefert liegen
gebliebene Änderungen nach jeder lokalen Änderung und beim App-Start nach.

**Ansichten** (`LocalViews`): Lernpakete und Aufgaben kommen immer aus den G2-Zeilen (Abhaken schreibt
`study_tasks.status`/`done_at` nur lokal und ist sofort sichtbar; Paket- und Tagesstatus wie `app/study.py`,
Lerntage aus `settings.free_days`); Feiertage, Fristen, Ankündigungen und berechnete Termine kommen aus der
Momentaufnahme des Bereichs. Fehlt die (Woche nie online geöffnet), werden die Termine aus `course_events` und
`event_exceptions` berechnet (wie `timetable.occurrences`, ohne Feiertage und Semestergrenzen; der Hinweis sagt das).
Solange noch nie abgeglichen wurde (kein Cursor), zählt nur die Momentaufnahme – so läuft es auch am PC im WLAN.
Dokumente: Dateiliste aus der Momentaufnahme, PDF aus dem Cache, Notizen aus dem zuletzt gesehenen Stand bzw. der
Basis des Entwurfs; was offline gezeichnet wird, bleibt Entwurf (`files/drafts`) und wird wie bisher nachgeliefert.
Abmelden leert die Ablage (ein anderes Konto erbt nichts); liegen noch ungesendete Änderungen, warnt die Übersicht und
verlangt ein zweites Tippen. Offene Änderungen stehen unter dem Stand-Hinweis („2 Änderungen werden gesendet, sobald …“).

Nicht lokal: Hochschul-Abgleich (`POST /api/sync`, braucht den Dienst), Fingerabdruck- und Seitentextmeldung, Konto.
Abgehakte Aufgaben gehen als G2-Feldänderung an den Dienst, nicht mehr über `POST /api/tasks/{id}/status` (nur noch als
Rückfall, wenn die Ablage die Aufgabe nicht kennt); `task_history` schreibt der Dienst dafür nicht, den Paketstatus
leitet er beim nächsten Aufruf selbst ab.

## Hochschul-Anmeldung auf dem Gerät

Nach der Anmeldung meldet die App die Sitzung (nur Cookies, nie das Passwort, nie den Learnweb-Schlüssel) mit `PUT /api/university/session` an den Dienst (`Repo.reportUniversitySession`, `DeviceSyncApi.reportSession`); der Abgleich im Dienst (Kurse, Termine, Dateiliste) läuft damit ohne gespeicherte Zugangsdaten, bis die Hochschule die Sitzung beendet – dann zeigt die App das Anmeldefenster erneut.

Hochschuldateien können direkt auf das Gerät geladen werden, ohne dass der Dienst sie herunterlädt – wie auf dem iPad.

**Ablauf**

1. Übersicht → Karte „Hochschule“ → „Anmelden“ (Route `uni-login`). Die App holt das Profil der Hochschule des Kontos
   vom Dienst (`GET /api/university/profile`, `DeviceSyncApi.profile()`), ohne Verbindung das eingebaute Profil
   (`UniversityProfile.builtIn`); gleicht der Dienst eine andere Hochschule als die gemerkte, wird die gemerkte nachgezogen.
2. `UniversityLoginScreen` zeigt die Anmeldeseite der Hochschule selbst (`profile.loginUrl`: Stud.IP/WebSSO der LUH bzw.
   CAS Hildesheim) in einer WebView, JavaScript und DOM-Speicher an (WebSSO/CAS brauchen sie). Adressen, die
   `profile.allows` nicht erlaubt (fremde Hosts, http), öffnet sie nicht und zeigt „Nur Seiten deiner Hochschule“.
   Zugangsdaten tippt der Mensch; die App füllt nichts vor und speichert kein Passwort.
3. Nach jeder fertigen Seite liest die App die Cookies der Profil-Hosts (`CookieManager.getCookie`,
   `UniversitySession.parseCookieHeader`). Erkennt `profile.loggedIn(cookies, url)` die Anmeldung (Sitzungscookie da,
   keine Anmeldeseite mehr), wird die Sitzung gespeichert. Hildesheim: anschließend lädt die WebView den Moodle-Launch
   (`Learnweb.launchUrl` mit einem Passport pro Bildschirm); die Rückleitung `uniflow://token=…` liefert den
   Learnweb-Schlüssel (`Learnweb.parseLaunchToken`), der in die Sitzung kommt. Dann zurück zur Übersicht.
4. Öffnen einer PDF (`Repo.pdf`): `FetchPolicy.decide(file, session)` – mit nicht abgelaufener Sitzung, `download_url`
   (https) und Quelle `studip`/`learnweb` lädt das Gerät direkt (`DirectDownload.request/fetch`, 120 s Timeout), prüft
   `%PDF-` und legt die Datei wie bisher atomar im Cache ab (`PdfCache`). Liefert die Hochschule eine Anmeldeseite
   (`SessionExpired`), wird die Sitzung als abgelaufen markiert; dann – wie bei jedem anderen Fehler des Direktwegs –
   kommt die Datei über den Dienst (`/api/files/{id}/content`), damit niemand blockiert ist. Ohne Sitzung, für eigene
   Dateien (`own`) und aus dem Cache läuft alles wie bisher. Im Dokument steht nach einem Direkt-Download kurz
   „Direkt von Stud.IP geladen“ bzw. „Direkt aus dem Learnweb geladen“.
5. Nach einem Direkt-Download meldet das Gerät dem Dienst im Hintergrund (`AppScope`) nur den Fingerabdruck
   (`Sha256.hex` → `PUT /api/files/{id}/fingerprint`) und den Seitentext (`PdfBoxPageText` mit PdfBox-Android →
   `PUT /api/files/{id}/pagetext`, höchstens 2000 Seiten, je 20000 Zeichen, `PageTextRules`), nie die Datei. Lehnt der
   Dienst den Fingerabdruck ab (Datei liegt schon beim Dienst, andere Fassung bekannt), folgt kein Seitentext. Fehler
   werden nur protokolliert.

**Was gespeichert wird:** `UniversityStore` legt je Hochschule eine `UniversitySession` (Cookies der WebView, bei
Hildesheim der Learnweb-Schlüssel, Zeitpunkt, `expired`) in `EncryptedSharedPreferences` (`uniflow.university`) ab –
nie Benutzername oder Passwort. „Abmelden“ auf der Karte löscht die Sitzung und alle Cookies und den DOM-Speicher der
WebView (die App nutzt die WebView nur für diese Anmeldung). Abmelden vom UniFlow-Konto löscht alle Hochschul-Sitzungen
des Geräts, damit ein anderes Konto sie nicht erbt. Der Cache (`cache/pdf/`) bleibt.

**Offen**

- Passwort merken: übernimmt der Passwort-Manager des Systems im Anmeldefenster (WebView mit Android-Autofill:
  Google Password Manager, Samsung Pass). Die App speichert nie Benutzername oder Passwort und füllt nichts
  selbst aus – Entscheidung des Inhabers vom 27.10.2026; am Gerät prüfen, dass der Autofill-Dialog erscheint
- Gerätetest: WebSSO der LUH und CAS Hildesheim in der WebView, Moodle-Rückleitung `uniflow://`, Cookie-Erkennung,
  Direkt-Download und Seitentext großer PDFs sind nur auf einem echten Gerät prüfbar (kein Android-Gerät am PC). Im
  JVM-Test geprüft: `FetchPolicy`, `PageTextRules`, `PdfCache`, `UniversityRules`.
- `profile.loggedIn` entscheidet nur nach Cookie und Adresse; `loggedInCheckUrl` wird noch nicht nachgeprüft. Eine
  fälschlich gespeicherte Sitzung heilt sich beim ersten Download selbst (SessionExpired → Rückfall auf den Dienst).
- Download und Fingerabdruck halten die Datei im Speicher (Grenze 300 MB wie beim Dienst), kein Streaming.

## Bauen und testen

Ohne Android Studio, im Docker-Bild (so wurde es hier geprüft):

```bash
# aus dem Repo-Wurzelverzeichnis; das Layout /w/apps + /w/packages muss erhalten bleiben (die Kern-Tests lesen ../../packages/shared-contracts/fixtures)
docker run --rm -v "$PWD:/src:ro" -v uniflow-gradle:/root/.gradle ghcr.io/cirruslabs/android-sdk:35 bash -c "mkdir -p /w; cp -r /src/apps /w/apps; cp -r /src/packages /w/packages; cd /w/apps/android && ./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug --no-daemon"
```

Unter Windows (PowerShell) den absoluten Pfad statt `$PWD` angeben, z. B. `-v C:/Users/<name>/studip-lernapp:/src:ro`.

Mit Android Studio: `apps/android` öffnen (JDK 17 oder 21, SDK 35). Workflow `.github/workflows/android.yml`: Kern-Tests,
App-Tests, Debug-APK und `bundleRelease` (unsigniert) als Artefakt `uniflow-android`.

## Play Store

- `app/build.gradle.kts`: `applicationId de.uniflow.android`, `versionCode`/`versionName`, Release mit R8 und
  Ressourcen-Schrumpfen, `bundle { language { enableSplit = false } }`.
- Signierung: `apps/android/keystore.properties` (nicht in Git) mit `storeFile`, `storePassword`, `keyAlias`,
  `keyPassword` oder Umgebungsvariablen `UNIFLOW_STOREFILE`, `UNIFLOW_STOREPASSWORD`, `UNIFLOW_KEYALIAS`,
  `UNIFLOW_KEYPASSWORD`. Ohne Angaben baut `bundleRelease` unsigniert; den Upload-Schlüssel erzeugt der Inhaber
  (`keytool -genkeypair -v -keystore uniflow-upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000`)
  und registriert ihn in der Play Console (App-Signatur durch Google).
- Noch offen für die Veröffentlichung: Play-Console-Konto, Datenschutzerklärung (`docs/release/`), Screenshots,
  Test auf echten Geräten mit Stift (Samsung S Pen), Abo-Produkte (Google Play Billing) am UniFlow-Konto.

## Noch nicht in der App

- Offline anlegen oder ändern von Modulen, Lernpaketen, Terminen, Karteikarten und Einstellungen: die Ablage und der
  Abgleich können es (`LocalStore.insertLocal`/`update`/`delete`, alle Fixture-Fälle), die Oberfläche bietet bisher nur
  das Abhaken von Aufgaben an. Feiertage, Fristen und Ankündigungen gibt es offline nur für Wochen, die schon einmal
  online geöffnet waren (Momentaufnahme); der Gerätetest des Offline-Betriebs (Flugmodus, WorkManager-Nachlieferung)
  steht noch aus.
- Eigene Notizbücher und Importe, Karteikarten, Noten, Community.
- Hochschul-Abgleich (Kurse, Termine, Dateiliste) startet nur den Job auf dem Server (`POST /api/sync`) und wartet auf
  `/api/bg`; nur der Download der Dateien läuft mit Hochschul-Sitzung direkt auf dem Gerät (siehe oben).
- Gerätetest WorkManager: Entwurf, Nachlieferung und Konfliktanzeige sind im JVM-Test geprüft (`DraftStoreTest`,
  `DraftRestoreTest`, `DraftUploadRulesTest`, `AnnotationSessionTest`); dass der Worker auf einem echten Gerät nach dem
  Beenden der App im Hintergrund und nach Netzverlust tatsächlich läuft (Doze, Hersteller-Akkuschoner), ist nur am Gerät
  prüfbar.

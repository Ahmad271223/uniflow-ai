# UniFlow für Android

**Stand 26.10.2026:** Kern und App vorhanden. Die App ist ein Client des UniFlow-Servers: des gehosteten Dienstes
(UniFlow-Konto, Vertrag G1) oder des eigenen PCs im WLAN (`serve.py --lan`, PIN). Sie zeigt Übersicht, Dokumente,
Stundenplan und Lernkalender und schreibt Stift-Notizen im gemeinsamen Notizformat auf PDFs. Gebaut und getestet im
Docker-Bild `ghcr.io/cirruslabs/android-sdk:35`; auf einem echten Gerät noch nicht geprüft (kein Android-Gerät am PC).

## Aufbau

| Modul | Inhalt | Tests |
| --- | --- | --- |
| `core` (Kotlin/JVM, ohne Android) | `ApiClient` (HttpURLConnection, Bearer-Token oder PIN-Cookie), `AccountApi` (G1), `SyncApi` (G2), `AnnotationDocument` (gemeinsames Notizformat, verlustfrei), `AnnotationStore` (base_version, 409 → Zusammenführung → erneut senden), `AnnotationMerge` (Drei-Wege-Regeln), Modelle für Bibliothek, Stundenplan, Lernkalender, Übersicht | gegen `packages/shared-contracts/fixtures`: `account/contract.json` (jeder aufgezeichnete Ablauf, Anfrage und Antwort), `sync/cases.json`, `documents/web-editor.json`, `merge/cases.json` |
| `app` (Jetpack Compose, minSdk 26) | Anmeldung (Konto oder PC+PIN), Übersicht, Dokumente nach Modul, PDF mit Stift (`PdfRenderer` + Compose-Canvas, Stift/Rot/Blau/Marker/Radierer, „Nur Stift“), Stundenplan (Woche, Feiertage grün, Fristen, Hinweise), Lernkalender (Woche, Aufgaben abhaken), Hochschul-Anmeldung in der WebView mit Direkt-Download (`UniversityLoginScreen`, `UniversityStore`, `FetchPolicy`, `PdfBoxPageText`) | reine Regeln ohne Gerät: `RulesTest` (Adressen, Datum), `InkTest` (Stiftgeometrie, Farben, Breite/Deckkraft, Seitenmaß, fremde Objekte), `PdfRulesTest` (PDF-Prüfung), `PdfCacheTest` (atomare Ablage), `AnnotationSessionTest` (serialisiertes Speichern), `SyncRulesTest` (Abgleich abwarten), `FetchPolicyTest` (direkt oder Dienst), `PageTextRulesTest` (Grenzen des Seitentexts), `UniversityRulesTest` (Karte „Hochschule“) |

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

## Hochschul-Anmeldung auf dem Gerät

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

- Passwort merken und vorausfüllen wie auf dem iPad (Schalter „Auf diesem Gerät merken“, Android-Schlüsselbund): noch
  nicht; jede Anmeldung tippt der Mensch vollständig.
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

- Offline-Betrieb mit lokaler Datenbank und Geräte-Sync über G2 (der Kern kann die Nachrichten, die Ablage fehlt).
- Eigene Notizbücher und Importe, Karteikarten, Noten, Community.
- Hochschul-Abgleich (Kurse, Termine, Dateiliste) startet nur den Job auf dem Server (`POST /api/sync`) und wartet auf
  `/api/bg`; nur der Download der Dateien läuft mit Hochschul-Sitzung direkt auf dem Gerät (siehe oben).
- Speichern, wenn das System die App im Hintergrund beendet: es wird bei ON_STOP gesendet, aber ohne WorkManager nicht
  garantiert zu Ende geführt (kein lokaler Entwurf).

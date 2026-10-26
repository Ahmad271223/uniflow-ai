# UniFlow für Android

**Stand 26.10.2026:** Kern und App vorhanden. Die App ist ein Client des UniFlow-Servers: des gehosteten Dienstes
(UniFlow-Konto, Vertrag G1) oder des eigenen PCs im WLAN (`serve.py --lan`, PIN). Sie zeigt Übersicht, Dokumente,
Stundenplan und Lernkalender und schreibt Stift-Notizen im gemeinsamen Notizformat auf PDFs. Gebaut und getestet im
Docker-Bild `ghcr.io/cirruslabs/android-sdk:35`; auf einem echten Gerät noch nicht geprüft (kein Android-Gerät am PC).

## Aufbau

| Modul | Inhalt | Tests |
| --- | --- | --- |
| `core` (Kotlin/JVM, ohne Android) | `ApiClient` (HttpURLConnection, Bearer-Token oder PIN-Cookie), `AccountApi` (G1), `SyncApi` (G2), `AnnotationDocument` (gemeinsames Notizformat, verlustfrei), `AnnotationStore` (base_version, 409 → Zusammenführung → erneut senden), `AnnotationMerge` (Drei-Wege-Regeln), Modelle für Bibliothek, Stundenplan, Lernkalender, Übersicht | gegen `packages/shared-contracts/fixtures`: `account/contract.json` (jeder aufgezeichnete Ablauf, Anfrage und Antwort), `sync/cases.json`, `documents/web-editor.json`, `merge/cases.json` |
| `app` (Jetpack Compose, minSdk 26) | Anmeldung (Konto oder PC+PIN), Übersicht, Dokumente nach Modul, PDF mit Stift (`PdfRenderer` + Compose-Canvas, Stift/Rot/Blau/Marker/Radierer, „Nur Stift“), Stundenplan (Woche, Feiertage grün, Fristen, Hinweise), Lernkalender (Woche, Aufgaben abhaken) | reine Regeln ohne Gerät: `RulesTest` (Adressen, Datum), `InkTest` (Stiftgeometrie, Farben, Breite/Deckkraft, Seitenmaß, fremde Objekte), `PdfRulesTest` (PDF-Prüfung), `AnnotationSessionTest` (serialisiertes Speichern), `SyncRulesTest` (Abgleich abwarten) |

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
- Hochschul-Abgleich startet nur den Job auf dem Server (`POST /api/sync`) und wartet auf `/api/bg`; Zugangsdaten werden
  in der Web-Oberfläche oder am Konto hinterlegt.
- Speichern, wenn das System die App im Hintergrund beendet: es wird bei ON_STOP gesendet, aber ohne WorkManager nicht
  garantiert zu Ende geführt (kein lokaler Entwurf).

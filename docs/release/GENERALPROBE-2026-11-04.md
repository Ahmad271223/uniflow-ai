# Generalprobe App-Store-Build StudiNow 1.0 (Build 3), 04.11.2026

Trockenlauf ohne Upload. Archiv aus dem Arbeitsstand `develop` (inkl. nicht eingecheckter Änderungen anderer Agenten):
`~/Studora-Builds/dryrun/StudiNow.xcarchive` (Release, arm64, Xcode 27.2, iPadOS-SDK 27.2, `** ARCHIVE SUCCEEDED **`,
80 Warnungen, keine Fehler). Logs: `~/Studora-Builds/dryrun/archive-run1.log`, `export-run1.log`, `export-dev-run2.log`.

## Ergebnis

| Punkt | | Befund |
|---|---|---|
| `xcodegen generate` + Release-Archiv | ✔ | Team 78MQGF36BD, Entitlements gesetzt, Vorab-Skript "Team prüfen" grün |
| Export `app-store-connect` / `destination export` | ✘ | `export-run1.log`: keine Apple-ID in Xcode, kein Zertifikat „Apple Distribution“, App-Store-Profil vom 31.10. ohne Associated Domains (Fix 1) |
| Ersatz-Export (Entwicklungssignatur, nur Strukturprüfung) | ✔ | `~/Studora-Builds/dryrun/export-dev/StudiNow.ipa`, 9,1 MB gepackt, 20,6 MB entpackt |
| CFBundleDisplayName / CFBundleName | ✔ | StudiNow / StudiNow |
| Version / Build | ✔ | 1.0 / 3 (Fix 3: Build 3 nur, wenn noch nie hochgeladen) |
| ITSAppUsesNonExemptEncryption | ✔ | false (Begründung in project.yml, APP-STORE.md „Weitere Angaben“) |
| NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription | ✔ | vorhanden; Nutzung: LectureRecorder, AudioTranscriber |
| NSPhotoLibraryAddUsageDescription | ✘ | fehlt, aber Teilen-Menüs bieten „Bild sichern“ an (QR-PNG `InviteView.swift:455`, Downloads `UniWebView.swift:272`, `UFShare`/`ActivityView`). Ohne den Schlüssel beendet iOS die App beim Antippen (Fix 2) |
| Weitere Usage-Texte | ✔ | PhotosPicker (läuft außerhalb der App, kein Text nötig); keine Kamera, Kontakte, Standort, EventKit, Face ID, Bonjour. Mitteilungen nur lokal. NWListener nur auf 127.0.0.1 (ChatGPT-Anmeldung), kein Text für lokales Netz nötig |
| UIBackgroundModes / BGTaskSchedulerPermittedIdentifiers | ✔ | audio, fetch, processing / `de.uniflow.ai.sync.refresh`, `.files` |
| Keine ATS-Ausnahme, kein NSLocalNetworkUsageDescription | ✔ | kein `NSAppTransportSecurity` im Release (Debug-Skript greift nicht) |
| URL-Schemes | ✔ | nur `uniflow` (Deep Links, Einladung); kein Debug-Schema |
| Entitlements (Archiv) | ✔ | applesignin, iCloud.de.uniflow.ai + CloudKit, ubiquity-kvstore `78MQGF36BD.de.uniflow.ai`, applinks:studinow.app; kein aps-environment (keine Push) |
| get-task-allow false | – | Archiv mit Entwicklungsprofil: true (normal). Wird beim App-Store-Export entfernt; nach Fix 1 prüfen |
| PrivacyInfo.xcprivacy | ✔ | im Bundle; Gründe CA92.1 (UserDefaults, nur eigene Suite), C617.1 (Datei-Zeitstempel), E174.1 (freier Speicher); keine Bootzeit-/Tastatur-APIs im Code; Datenarten UserID + OtherUserContent, verknüpft, kein Tracking = APP-STORE.md „App-Datenschutz“; StudiNow-Dienst aus (`StudoraServiceURL` fehlt, `BillingServiceLink.isEnabled = false`) |
| App-Icon 1024 ohne Alpha | ✔ | `AppIcon-1024.png` hasAlpha no; `Assets.car` enthält AppIcon (1024, MultiSized) |
| Debug-Funktionen im Release | ✔ | alle `UF…`-Startparameter (UFPlan, UFDemo, UFNoServer, UFServer, UFLoginStub, UFRoute/UFAction usw.) unter `#if DEBUG`; außerhalb nur `UFNoStudIPSync`/`UFRoute`-Prüfungen, die Funktionen abschalten. Reiter „Entwicklung“: `Session.ownServerAvailable` = false im Release, `SettingsNav` filtert `dev`, `localKeys` ohne `dev`, Deep Link auf `tab=dev` fällt auf „Zugang & Darstellung“ zurück. Der Text des Reiters ist einkompiliert, aber nicht erreichbar |
| Keine .storekit-Datei im Bundle | ✔ | nur im Testziel; Bundle: Binary, Assets.car, 2 Icon-PNGs, Inter-Schrift + Lizenz, PrivacyInfo |
| Bitcode / Swift Support / Frameworks | ✔ | kein `__LLVM`-Segment; iOS 17 → kein SwiftSupport nötig; keine eingebetteten Frameworks (UniFlowCore statisch) |
| Mindestversion / `#available` | ✔ | MinimumOSVersion 17.0; Prüfungen auf 16/17.5/18/26/27 kompilieren gegen 17.0 |
| Bildschirmfotos | ✔ | `~/Studora-Builds/appstore-screenshots`: 40 PNG, 2064×2752 bzw. 2752×2064 (iPad 13"), ohne Alpha |

## Korrekturen

1. **Signierung (Inhaber, Mac):** Xcode → Settings → Accounts: Apple-ID des Teams 78MQGF36BD anmelden; „Manage
   Certificates“ → „+“ → Apple Distribution. Altes Profil „iOS Team Store Provisioning Profile: de.uniflow.ai“
   (31.10.2026, ohne Associated Domains) in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` löschen;
   Xcode erzeugt es beim Export mit `-allowProvisioningUpdates` neu. Associated Domains ist für die App-ID bereits an
   (Entwicklungsprofil vom 04.11. enthält es).
2. **`apps/apple/project.yml`**, `targets.UniFlow.info.properties`, ergänzen (Koordinator):
   `NSPhotoLibraryAddUsageDescription: StudiNow sichert ein Bild, das du im Teilen-Menü mit „Bild sichern“ auswählst, in deinen Fotos.`
   Danach `xcodegen generate`. PrivacyInfo bleibt unverändert (keine Datenerfassung).
3. **Build-Nummer:** War Build 3 (Archiv `~/Studora-Builds/StudiNow.xcarchive` vom 04.11. 01:25) schon in App Store
   Connect, `CURRENT_PROJECT_VERSION` in `project.yml` auf `"4"` setzen.

## Restschritte des Inhabers für den echten Upload

1. App Store Connect: App-Eintrag StudiNow (Bundle-ID `de.uniflow.ai`, SKU, Primärsprache Deutsch), Abos laut
   APP-STORE.md „In-App-Käufe“, App-Datenschutz laut Tabelle, Exportkontrolle, Altersfreigabe.
2. CloudKit-Konsole: Schema (`apps/apple/Config/cloudkit-schema.ckdb`) für iCloud.de.uniflow.ai nach Production
   übernehmen (sonst schlägt die Community im App-Store-Build fehl).
3. `studinow.app/.well-known/apple-app-site-association` online prüfen (Team-ID + `de.uniflow.ai`, Pfad `/i/*`).
4. Fixes 1–3, dann auf sauberem, eingechecktem Stand: `xcodegen generate`, Archiv wie oben, Export zur Kontrolle mit
   `~/Studora-Builds/export-appstore.plist` und `codesign -d --entitlements :-` (get-task-allow fehlt,
   icloud-container-environment = Production), erst dann Upload mit
   `xcodebuild -exportArchive -archivePath <Archiv> -exportOptionsPlist ~/Studora-Builds/upload-appstore.plist -exportPath <Ordner> -allowProvisioningUpdates`
   oder Xcode Organizer → Distribute App.
5. Prüfhinweise aus APP-STORE.md „Hinweise für die App-Prüfung“ eintragen (Demo-Link unten auf der Anmeldeseite),
   Bildschirmfotos aus `~/Studora-Builds/appstore-screenshots` hochladen, Build auswählen, zur Prüfung einreichen.

# Übergabe 14.11.2026, 00:15 – Stand von StudiNow für die nächste Sitzung

Diese Datei ist für eine neue Claude-Sitzung, auch in einem anderen Konto, die ohne Vorwissen weitermacht. Sie fasst
die Arbeit vom 13.11.2026 zusammen: die Hauptsitzung und 17 Nebensitzungen. Alles liegt in Git auf `develop` und ist
gepusht. Lies zusätzlich das Gedächtnis unter `~/.claude/projects/-Users-ahmadfakih-uniflow-ai/memory/`, zuerst
`MEMORY.md`.

## 1. Inhaber und Umgang

- **Inhaber:** Ahmad Fakih (Firma „IT solutions by Ahmad Fakih“, `support@studinow.app`). Er ist **kein Entwickler**.
- **Sprache:** Antworte immer auf **einfachem Deutsch**, kurz, ohne Fachjargon. Er schreibt schnell und mit Tippfehlern.
  Lies wohlwollend, und frag nur bei echten Weichen nach.
- **Produkt:** StudiNow, ein Lernmanagementsystem für Hochschulen. Heute ist nur die **LUH Hannover** angebunden. Es
  gibt iPad (Hauptprodukt), Mac („Designed for iPad“), iPhone (seit Build 39), PC/Web und Windows über den Python-Dienst.
- **Wie er arbeitet:** Er schickt Screenshots vom echten iPad. Fehler daraus haben Vorrang. Er will viel parallel (mehrere
  Sitzungen), aber kein Durcheinander.

## 2. Stand bei Apple (14.11.2026, 00:00)

| Was | Stand |
|---|---|
| App Store | **1.0.3 (Build 35) live seit 13.11.2026 23:53** in 174 Ländern, auch Deutschland. Davor 1.0.2 (Build 31). |
| TestFlight | Builds 36, 37, 38, 39 (alle Version 1.0.4). **Build 39 = erstmals iPad + iPhone**, intern und Gruppe „LUH-Tester“ freigegeben. |
| 1.0.4 | **Noch nicht eingereicht.** Der Inhaber will erst die iPhone-Version selbst testen. Sobald Apple eine Version mit iPhone veröffentlicht hat, lässt sich das iPhone nicht mehr entfernen. |
| Abos | Jahresabos Plus 19,99 €, Pro AI 39,99 € (APPROVED). Monatsabos aus dem Verkauf genommen, das ist gewollt. |
| App | App-ID `6830632088`, Bundle `de.uniflow.ai`, Team `78MQGF36BD`. Gruppe „LUH-Tester“ `3541cafb-8a8c-4766-bb7a-bf29ef622cde`. Öffentlicher Link: https://testflight.apple.com/join/XTzTMRpn |

In App Store Connect liegt ein alter Stand „1.0 PREPARE_FOR_SUBMISSION“. Den **nie einreichen**.

## 3. Stand im Code

- **`develop`:** gepusht. Build-Liste in `docs/release/BUILD-HERKUNFT.md`. `apps/apple/project.yml`: `MARKETING_VERSION
  1.0.4`, `CURRENT_PROJECT_VERSION 40`. Tags `ios-1.0.4-b36` bis `ios-1.0.4-b39`.
- **Build 39 = Commit `5d6b6a45`.** Getestet: iPad 1766, Swift-Kern 1531, Python 3498 und JS 450, alle grün.
- **Server** (`app.studinow.app`, Hetzner): seit 13.11.2026 16:32 auf `d0d178b6`. Ablauf und Rückweg stehen in
  `docs/release/DEPLOY-DIENST-2026-11-13-2.md`. Der Code nach `d0d178b6` braucht den Server nicht neu, die Änderungen
  betreffen nur die App.
- **Offene Zweige, nicht in develop:**
  - `release/store-1.0.4`: Texte, Bildschirmfotos (iPad + iPhone) und Abschreib-Liste
    `docs/release/EINREICHUNG-1-0-4.md` für die Einreichung von 1.0.4. Gepusht.
  - `windows/store-2026-11-13`: Microsoft-Store-Paket (MSIX, über GitHub Actions gebaut, grün). Gepusht. Für den Store
    fehlt nur das Partner-Center-Konto des Inhabers.
  - Etwa 20 alte Zweige vom 2. bis 11.11. (`worktree-agent-*`, `analyse/*`, `windows/1.0`, `feature/iphone`,
    `paritaet/*`): Reste, deren Inhalt längst anders in develop kam. **Nicht mischen.**

## 4. Was am 13.11. dazukam (Builds 36–39)

| Bereich | Neu |
|---|---|
| Lernen | Smart Planner 2.0 (Lernziele), eigene Wochen je Modul. Abgewählte Fächer werden **nie** geplant („Mathe 1“-Fehler). Haken „erledigt“ je Datei und Woche, über alle Geräte und im Lernstand. |
| QIS | „Im QIS anmelden“ navigiert direkt zum Modul. Die App klickt **nie** selbst auf Anmelden oder Abmelden. |
| KI | Erklärt einfacher (Kernidee, einfache Wörter, Beispiel). Uni-Mail „Mit KI verbessern“ (Pro AI, 50 je Monat, ohne Credits). Bessere Karteikarten. KI-Hinweis kurz („Okay, los“). |
| Editor | Kopfzeile mit letzten 15 Dokumenten, Stift-Glättung Aus/Leicht/Normal, „Formen erkennen“ (am Gerät repariert). Rückgängig holt nie Gelöschtes zurück. Blatt daneben mit eine Notiz je Datei, „+ Seite“ mit Papierwahl, „…“ mit Seite löschen, Papierkorb und ganzem Blatt löschen. Community-Lösung auf eigener PDF bzw. richtigem Papier. |
| Sonst | Neuer App-Einstieg (Willkommen, Rundgang, Fragen, Probe/Tarife). Startseite aufgeräumt. Probe-Karte verschwindet nach Kauf von Pro AI. Uni-Mail meldet sich neu an statt „keine JSON-Antwort“. iPhone-Version (ohne Editor, PDFs lesen, KI ja). Uni Hildesheim eingebaut, aber im Release versteckt. |
| Texte | Beschreibungen beginnen mit „StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland – zum Start mit voller Anbindung an die Leibniz Universität Hannover.“ Der Name des Inhabers steht nicht mehr in der App, nur im Impressum und in der Datenschutzerklärung, wo er Pflicht ist. |

## 5. Nächste Schritte (in dieser Reihenfolge)

1. **Rückmeldung des Inhabers zu Build 39 abwarten.** Auf seinem iPad (A16) ist der Stand von Build 39 per Kabel
   installiert. Er soll prüfen:
   - Rückgängig: Strich zeichnen, Rückgängig, an derselben Stelle neu zeichnen. Nur der neue Strich darf bleiben.
   - „Formen erkennen“ mit Stillhalten am Ende.
   - „+ Seite“, „…“ → Seite löschen, Papierkorb.
   - **Das X bei einer Community-Lösung daneben.** Im Simulator nie nachstellbar. Offene Rückfrage an ihn: Finger oder
     Stift? Wie geöffnet? Reagiert sonst etwas?
   - Uni-Mail, KI-Mail, KI-Erklärung.
2. **iPhone:** Der Inhaber testet Build 39 auf einem iPhone über TestFlight. Erst nach seinem „passt“ 1.0.4 einreichen.
3. **1.0.4 einreichen** (nur mit ausdrücklichem Okay):
   - in App Store Connect Version 1.0.4 anlegen;
   - Texte aus `docs/release/EINREICHUNG-1-0-4.md` (Zweig `release/store-1.0.4`) eintragen;
   - Bildschirmfotos iPad 13" und iPhone 6,9" hochladen;
   - Build 39 wählen, Prüfhinweise eintragen, einreichen;
   - Freigabe danach von Hand (`releaseType MANUAL`), also erst nach seinem Okay veröffentlichen.

   Dafür vorher `release/store-1.0.4` in develop mischen und `tests/test_release_texts.py` grün halten.
4. **Microsoft Store:** Der Inhaber legt sein Partner-Center-Konto selbst an (developer.microsoft.com/store/register). Dann
   die drei Werte in `store.json` eintragen und das Paket einreichen. Anleitung auf `windows/store-2026-11-13`. Seine
   Zugangsdaten **nie selbst eingeben**.
5. **Uni Hildesheim** freischalten erst, wenn jemand mit echtem Hildesheim-Konto Anmeldung, Dateien und Noten geprüft
   hat. Danach `UF_SHIPPED_UNIVERSITIES` erweitern.
6. **Mac-Version online bringen** (Wunsch des Inhabers 14.11., „komplett online, wenn sie fertig ist“). Die Mac-Version
   ist keine eigene App, sondern die iPad-App auf Macs mit Apple-Chip („Designed for iPad“). Ablauf:
   - Build 39 bzw. den Stand von 1.0.4 auf einem Mac mit Apple-Chip prüfen: Start, Übersicht, Einstellungen,
     Editor mit Maus und Trackpad, Uni-Mail, KI, Abo-Kauf. Mac-Tests und Fixe gab es ab Build 27 (`afc919cc`); den
     Bericht in `docs/release/APP-STORE.md` (Hinweis „Mac“) lesen.
   - Ist alles in Ordnung, dann in App Store Connect unter **Preise und Verfügbarkeit → „iPhone- und iPad-Apps auf
     Apple-Silicon-Macs“ = verfügbar** setzen. Das geht nicht per API, sondern im Browser. Der Inhaber klickt selbst
     oder gibt ausdrücklich frei.
   - Die Plattform **macOS** (alter Entwurf „1.0 PREPARE_FOR_SUBMISSION“) **nie einreichen**.
7. **Apple-Schlüssel „Sign in with Apple“** für den Widerruf beim Konto-Löschen legt der Inhaber selbst an
   (`LERNAPP_APPLE_SIGNIN_KEY_ID` und `…_KEY_FILE` in `deploy/.env` auf dem Server). Ohne ihn geht das Löschen trotzdem,
   nur ohne Widerruf bei Apple.

## 6. Wie man baut, testet und hochlädt

Immer `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` setzen. In zsh `$VAR:` hinter Variablen vermeiden,
also `${C}:pfad` statt `$C:pfad`, weil `:a` sonst als Modifikator gilt.

- **Tests:**
  - Python: `.venv/bin/python -m pytest -q -p no:cacheprovider --ignore=tests/test_pwa.py`
  - Browser-Logik: `node --test tests/js/`
  - Swift-Kern: im Ordner `apps/apple/Packages/UniFlowCore` `swift test`
  - iPad-App: im Ordner `apps/apple` `xcodegen generate -q` und dann
    `xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "id=<SIM>" -only-testing:UniFlowTests -derivedDataPath ~/Studora-Builds/dd-test`
  - **Simulator:** immer einen Klon von `4495AA80-7860-4F6F-9FCD-C83CCED19021` nehmen
    (`xcrun simctl clone 4495AA80-… "Name"`). Frische Simulatoren haben kein StoreKit-Setup und keine deutsche Sprache.
  - **Wacklig unter Last** (einzeln grün):
    - `test_modules_race.py::test_merge_duplicate_modules_keeps_everything`;
    - Playwright-Webtests (`test_web_overview`, `test_web_hosted_e2e`, `test_web_studyplan`);
    - `SyncAllPortalsTests.testUniMailRunsSideBySideWithQIS`.
- **Release-Fallen:**
  - Tests laufen in Debug, der Release-Bau bricht bei Code, der nur unter `#if DEBUG` existiert (passiert am 13.11. beim
    neuen Einstieg).
  - `ProcessInfo.systemUptime` und `mach_absolute_time` sind verboten (Required-Reason-API, PrivacyInfo-Test).
    Stattdessen `CACurrentMediaTime()`.
- **Build bauen und hochladen:**
  1. Commit X, dann `git archive X | tar -x -C ~/Studora-Builds/export-bNN` und `apps/apple/Config/Team.xcconfig` dorthin
     kopieren.
  2. Im Ordner `export-bNN/apps/apple`: `xcodegen generate -q`, dann archivieren:
     `xcodebuild archive … -configuration Release -destination generic/platform=iOS -archivePath ~/Studora-Builds/StudiNow-NN.xcarchive UF_SHIPPED_UNIVERSITIES=luh -allowProvisioningUpdates -authenticationKeyPath ~/Studora-Builds/private_keys/AuthKey_93BHUZGTCD.p8 -authenticationKeyID 93BHUZGTCD -authenticationKeyIssuerID a5fea04a-eb9b-4e3e-9442-b5ab1e0462a6`
  3. Hochladen: `xcodebuild -exportArchive -archivePath … -exportPath … -exportOptionsPlist ~/Studora-Builds/ExportOptions-upload.plist` mit
     denselben Schlüssel-Angaben.
     - **`errSecInternalComponent` beim Signieren:** einfach wiederholen. Der Schlüsselbund war gesperrt oder fragte; im
       Zweifel den Inhaber bitten, am Mac „Immer erlauben“ zu klicken.
  4. Danach `tools/testflight_nachlauf.py` (Buildnummer und Testhinweis darin anpassen), gegebenenfalls
     `tools/testflight_beta_einreichen.py`.
  5. Danach in `docs/release/BUILD-HERKUNFT.md` die Zeile mit Commit und Status eintragen, die nächste Zeile als „noch
     nicht hochgeladen“ anlegen, `project.yml` Build +1, `docs/release/APP-STORE.md` Zeile „Version, Build“ und in
     `tests/test_release_build_provenance.py` die Liste der Exporte ergänzen. Dann Tag `ios-1.0.4-bNN` setzen und pushen.
- **App Store Connect per API:** `.venv/bin/python tools/asc.py GET|POST|PATCH <pfad> ['<json>']`. Den Schlüssel nie
  committen.
- **Direkt aufs Gerät per Kabel:**
  - Entwicklermodus am Gerät an;
  - `xcodebuild build … -configuration Release -destination "id=<UDID>" -allowProvisioningDeviceRegistration …`;
  - `xcrun devicectl device install app --device <UDID> <App>`;
  - Geräte anzeigen: `xcrun devicectl list devices`. iPad des Inhabers: `00008120-000E309830814032`.
- **Server-Update:** nur mit ausdrücklicher Freigabe. Ablauf: Backup, `git archive <commit> | ssh …`, `docker compose up -d --build`,
  `dienst-check.sh`. Details in `docs/release/DEPLOY-DIENST-2026-11-13-2.md`. SSH-Schlüssel: `~/.ssh/studinow_server`.

## 7. Feste Regeln

- **Uni-Zugangsdaten:** Passwörter nur im Schlüsselbund des Geräts, nie auf dem Server. Keine echten Logins mit
  fremden Zugangsdaten.
- **QIS-Skript:** klickt nie Prüfungsan- oder -abmeldung und nie Logout. Keine Namen, Adressen, Geburtsdaten oder
  Matrikelnummern lesen oder speichern. QIS-Dokumente nur auf Tipp des Nutzers erzeugen.
- **Noten** nur aus dem QIS: jede bestandene Leistung zählt, die LP-Summe ist überall gleich.
- **Freigabe nötig für:** Veröffentlichen, Einreichen, Server-Deploy und Website-Upload nur mit ausdrücklichem Okay
  im Chat. Kein Push auf `main`. `develop` nur nach grünen Tests pushen.
- **Bestehende Funktionen:** Das iPad ist das Hauptprodukt. Keine Funktionen dort verlieren.
- **SwiftUI-Tiefe:** `ViewTypeDepthAppTests` begrenzt die Tiefe. Neue Ansichten als eigene kleine View-Typen bauen und
  eintragen, `DocumentView.body` nicht wachsen lassen (Build 32 stürzte an einem Stapelüberlauf ab).
- **Swift und Python** bleiben über Fixtures gleich (`packages/shared-contracts`, `tools/gen-*.py`).
- **Nebensitzungen** arbeiten in eigenen Worktrees bzw. Zweigen. Den Hauptordner `~/uniflow-ai` nie auf einen anderen
  Zweig umstellen. Gemischt wird zentral, nach vollem Testlauf.
- **Der Mac** ist schnell überlastet. Volle iPad-Läufe nacheinander, nicht parallel.

## 8. Nebensitzungen vom 13.11. (alle fertig, Ergebnisse in develop, wenn nicht anders gesagt)

| Sitzung | Ergebnis |
|---|---|
| Uni Hildesheim + eigene Wochen; Moduldetail-Haken | in develop; Haken-Abgleich `fe57dc99` |
| Smart Planner 2.0 | Lernziele; Reparatur abgewählter Fächer `c1b3d2f5` |
| Community, Lasttest 20.000, Windows-Lücken | 4 Community-Fehler, Lasttest lokal (`docs/COMMUNITY-LASTTEST-BERICHT.md`), `docs/WINDOWS-LUECKEN.md`, Lernziele und Konto löschen am PC, Server-Update 11:07 |
| Startseite, letzte 15 Dokumente, Stift | Startseite, Reiter, Glättung, Rückgängig-Reparatur `cb7da78c` (`docs/RUECKGAENGIG-2026-11-13.md`) |
| Geteilte Ansicht | Blatt daneben, Druck, „+ Seite“ `f517ac24`, Kopfzeile mit Seite löschen und Papierkorb `28162121`; X nicht nachstellbar |
| QIS (verbundenes iPad) | Direktlink zur Prüfungsanmeldung `2318a4f4` |
| KI-Karteikarten | bessere Karten `b0fa2e21` |
| Neuer App-Einstieg | `bd6c551a` (Release-Fix `ba427849`) |
| Formen erkennen | Eckenerkennung am Gerät `4c7c5800`/`e2cfd821` |
| iPhone-Version | Zweig `iphone/universal` in develop (`3aa9edba`), Bericht `docs/IPHONE-STAND-2026-11-11.md` |
| iPhone-Bilder und Store-Texte | Zweig `release/store-1.0.4`, **nicht** in develop |
| Windows/Microsoft Store | Zweig `windows/store-2026-11-13`, **nicht** in develop |

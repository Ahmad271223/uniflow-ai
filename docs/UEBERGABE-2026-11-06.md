# Übergabe StudiNow, Stand 06.11.2026 (für die nächste Claude-Sitzung / das andere Konto)

Lies diese Datei zuerst. Sie fasst zusammen, wo das Projekt steht, was offen ist und welche Regeln gelten.
Ausführlich: `docs/START-DIENST-CHECKLISTE.md` (Server), `docs/UNI-MAIL-2026-11-05.md`, `docs/LEHRENDE-KONTAKTE-2026-11-06.md`,
`docs/BESCHEINIGUNGEN-2026-11-06.md`, `docs/AUTOMATISCH-ANMELDEN-2026-11-06.md`, `docs/KI-GANZES-DOKUMENT-2026-11-05.md`.

## 1. Stand der Zweige

| Zweig | Commit | Inhalt |
|---|---|---|
| `develop` | `adb145a` + diese Datei | iPad-App **Build 1.0 (9)**, Web/Windows, Dienst. Alle Tests grün (pytest 1734, node 430, swift test 1245, UniFlowTests iPad 1166) |
| `feature/iphone` | `db3cf9d` (**WIP**) | Merge von develop **3e6de7d** (Stand Build 6) + begonnene iPhone-Anpassungen für Raumfinder, Uni-Mail, Zurück-Pfeil. **Tests nicht vollständig gelaufen** (Agent wegen Kontingent angehalten) |
| `main` | alt | nicht benutzt; Releases kommen aus develop |

Arbeitsordner: iPad/develop `/Users/ahmadfakih/uniflow-ai`, iPhone `/Users/ahmadfakih/uniflow-ai-iphone` (eigener git worktree).

## 2. Was in Build 7 neu ist (gegenüber Build 5/6)

Neues Logo überall; Zurück-Pfeil auf jeder Seite außer Übersicht; Raumfinder (LUH, Google-Maps-Route); Uni-Mail + Uni-Kalender
(SOGo, LUH und Uni Hildesheim, live bestätigt); Lehrende mit E-Mail/Sprechstunde (LUH, Stud.IP JSON:API live bestätigt);
Termin-Detail im Stundenplan (Raum → sofort Fußweg-Route, alle Lehrenden, Mail an einzelne/alle); Bescheinigungen (LUH QIS,
HsH + Hildesheim PLuS über HISinOne) und HsH-Noten auf dem iPad; **Automatisch anmelden** (Uni-Passwort nur im Schlüsselbund
dieses iPads, ThisDeviceOnly, nicht in iCloud); **Dienst speichert keine Uni-Passwörter mehr** (410, Tresor geleert);
KI ganzes Dokument (höhere Ausgabegrenzen, gekürzte Antwort statt Fehler, Überblick über alle Abschnitte); Dialoge scrollen;
Demo ohne Dauer-Ladehinweis.

## 3. Was der Inhaber (Ahmad) selbst tun muss

1. **Build 9 hochladen:** Xcode → Window → Organizer → `StudiNow 1.0 (9)` (Archiv `~/Studora-Builds/StudiNow-9.xcarchive`)
   → Distribute App → App Store Connect → Upload. Build 5 bis 8 **nicht** einreichen. Build 9 = Build 7 + Lineal-Wahl (links/rechts/beide) in der geteilten Ansicht, Lineal-Fehler aus Build 8 behoben.
   (Upload per `xcodebuild -exportArchive` scheitert mit „Failed to Use Accounts“ – nur über den Organizer.)
2. **CloudKit-Schema** in der CloudKit-Konsole (icloud.developer.apple.com) von Development nach **Production** übernehmen,
   sonst gehen Lösung teilen/Community im App Store nicht (`docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md`).
3. **App Store Connect** (App-ID 6830632088, Bundle de.uniflow.ai): nur die **iOS**-Version nutzen, der alte macOS-1.0-Entwurf
   wird NICHT eingereicht. Beschreibung, Keywords, URLs (https://studinow.app/datenschutz, /support), Altersfreigabe,
   App-Datenschutz, Prüfhinweis (Demo: „Ohne Hochschulkonto ansehen (Demo)“), Bildschirmfotos `~/Studora-Builds/appstore-screenshots/`
   (Name „Tobi“), Abo **Plus** (de.uniflow.plus.monthly) mit Prüf-Bildschirmfoto + Hinweis anhängen.
   **Pro AI** (de.uniflow.proai.monthly) erst einreichen, wenn ein Sandbox-Kauf + KI-Frage über TestFlight geklappt hat.
4. **E-Mail beim Händlerstatus** (Rechtsträger) in App Store Connect ändern (hat der Inhaber angekündigt).
5. **Strato:** `studinow.ai` → A-Eintrag 75.2.60.5, AAAA löschen (oder Weiterleitung auf https://studinow.app); Alias
   `no-reply@studinow.app` am Postfach support@ anlegen.
6. **Website** neu hochladen: Netlify-Projekt `startling-longma-7d7cdf` → Deploys → Ordner `uniflow-ai/site` hineinziehen
   (neues Logo, Texte zu Passwörtern).
7. **Mit echten Konten testen** (Testlisten in den Docs aus Abschnitt 0): Uni-Mail senden/antworten (LUH, Hildesheim),
   Automatisch anmelden (Uni-Mail-Formular und HsH-IdP sind geraten), Bescheinigungen HsH/Hildesheim (Job+Poll nie ausgelöst),
   Lehrenden-Nachricht über Stud.IP, Google-Maps-Route, Mac-Start (Designed for iPad).
8. Optional später: AWS-Bedrock-Schlüssel (Claude als 2. KI-Anbieter) – nötig, bevor viele Pro-AI-Nutzer kommen.

## 4. Offene Arbeit für die nächste Sitzung (Reihenfolge)

1. **iPhone fertig machen** in `/Users/ahmadfakih/uniflow-ai-iphone`: Stand `db3cf9d` prüfen (bauen, IPhone*Tests, Breiten-Audit,
   volle UniFlowTests auf iPhone- und iPad-Simulator), dann **develop `adb145a` + diese Datei nachmergen** (Build 7: Lehrende,
   Termin-Detail, Bescheinigungen, Automatisch anmelden, Logo überall, Dialog-Scroll, Hildesheim-Mail) und iPhone-gerecht machen.
2. Nach dem Upload: ASC-Metadaten ausfüllen (Abschnitt 3.3), Plus-Abo anhängen, einreichen.
3. Später (Inhaber-Wunsch): HsH-Mail (kein SOGo), Lehrende + Raumfinder für HsH und Hildesheim.
4. Mit wachsenden Nutzern: `LERNAPP_AI_BUDGET_EUR` (heute 50 €, Standard) und `LERNAPP_AI_TRIAL_BUDGET_EUR` anheben,
   Server vergrößern (Hetzner CX23 → 4/8 vCPU), Claude/Bedrock einschalten.

## 5. Server (KI-Dienst)

- `https://app.studinow.app` = Hetzner CX23 Helsinki, IPv4 2.29.122.54, Ubuntu 26.04, Docker Compose (app, jobs, caddy).
- Zugang vom Mac: `ssh -i ~/.ssh/studinow_server root@2.29.122.54` (Schlüssel liegt nur auf dem Mac).
- Code liegt unter `/srv/uniflow/app` (per `git archive HEAD | ssh … tar -x`), Stand in `/srv/uniflow/app/VERSION-COMMIT`.
- Ausrollen: lokal committen, dann
  `git archive HEAD | ssh -i ~/.ssh/studinow_server root@2.29.122.54 'tar -x -C /srv/uniflow/app'` und auf dem Server
  `cd /srv/uniflow/app/deploy && ./backup.sh && docker compose up -d --build`.
- `.env` liegt nur auf dem Server (`/srv/uniflow/app/deploy/.env`, 600). Der Inhaber hat OpenAI-Schlüssel und STRATO-Passwort
  **selbst** eingetragen – nie anzeigen, nie in Chat/Repo/Log. Prüfen nur mit `grep -c "^NAME=.\+"`.
- Sicherung täglich 03:30 (systemd-Timer), Archive in `/srv/uniflow/backups`.
- KI: OpenAI `gpt-6-luna` aktiv; Test 06.11.: 4 ganze Dokumente (195 Seiten) = 11 Credits, real 2,4 Cent.

## 6. Regeln (vom Inhaber festgelegt, unbedingt einhalten)

- Deutsch mit dem Inhaber, kurz und klar.
- **Uni-Passwörter nie auf unserem Server**; auf dem iPad nur im Schlüsselbund (ThisDeviceOnly), abschaltbar, beim Abmelden löschen.
- Nie selbst Passwörter, API-Schlüssel, Bank-/Steuerdaten eintippen; Anmeldungen macht der Inhaber im Browser-Fenster selbst.
- Uni-Systeme nur **lesend** erkunden (nichts absenden, nichts anmelden, keine Mail öffnen/senden); persönliche Daten nie in
  Code, Fixtures oder Logs (Fixtures erfunden, z. B. example.org).
- DNS-/Domain-Änderungen speichert der Inhaber selbst (der Auto-Modus blockt das).
- Agenten committen/pushen nie; der Koordinator committet gezielt (`git add` nur die eigenen Dateien), vorher
  pytest, `node --test tests/js/`, `swift test` (UniFlowCore) und UniFlowTests (iPad-Simulator) laufen lassen.
- Bauen: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` im selben Befehl wie `xcrun simctl …`;
  nie `CODE_SIGNING_ALLOWED=NO`; Simulator-Vorlage `4495AA80-7860-4F6F-9FCD-C83CCED19021` klonen und danach löschen;
  `apps/apple/Config/Team.xcconfig` ist gitignored und muss in Export-Ordner kopiert werden; `xcodegen` in `apps/apple`.
- iPad des Inhabers: UDID `00008120-000E309830814032`; installieren mit
  `xcrun devicectl device install app --device <UDID> <App>` (iPad muss entsperrt sein).
- Release-Archiv immer aus sauberem `git archive HEAD`-Export bauen; `CURRENT_PROJECT_VERSION` in `apps/apple/project.yml` hochzählen.
- KI-Mischung: 75 % OpenAI, 25 % Claude Sonnet 5.5 (Bedrock eu-central-1, noch ohne Schlüssel), DeepSeek aus;
  Pro AI 100 Credits = höchstens 1 € je Monat; Tarife: Free (ohne Community/KI), Plus 1,99 €, Pro AI 3,99 €.

## 7. Wo was liegt (außerhalb des Repos, nur auf dem Mac)

`~/Studora-Builds/`: Archive (`StudiNow-7.xcarchive`), `ExportOptions-upload.plist`, Bildschirmfotos, Website-Zip,
Struktur-Notizen der echten Uni-Seiten (anonymisiert): `sogo/`, `lehrende/`, `bescheinigungen/`, `hsh/`, `hildesheim/`;
Logo-Quellen `logo/` (Original, `scharf.py`, `neu/`); Server-Vorlagen `server/` (ohne Geheimnisse).

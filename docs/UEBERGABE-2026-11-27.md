# Übergabe 27.11.2026, 22:15 – StudiNow 1.0.8 eingereicht, 1.0.9 in Arbeit

Für die nächste Claude-Sitzung (auch ein anderes Claude-Konto). Lies das ganz, bevor du etwas tust. Stand aller
Zahlen: 27.11.2026 22:15. Sprache mit dem Inhaber: **Deutsch, einfache Worte.**

## 1. Wo was liegt

| Was | Wo |
|---|---|
| Haupt-Repo | `~/uniflow-ai` (Zweig `main` ist alt; gearbeitet wird in Worktrees) |
| Worktrees | `~/Studora-Builds/wt-*` (je Zweig ein Ordner, siehe Abschnitt 4) |
| Release 1.0.8 | `~/Studora-Builds/wt-108-alles`, Zweig `release/1.0.8-alles` |
| Gedächtnis früherer Sitzungen | `~/.claude/projects/-Users-ahmadfakih-uniflow-ai/memory/` (`MEMORY.md` ist das Inhaltsverzeichnis; wichtig: `mac-fenster-sperre-1-0-7.md`, `tarife-credits-neu.md`, `uni-goettingen-einbau.md`) |
| App Store Connect (Schnittstelle) | `tools/asc.py` im Repo, Schlüssel `~/Studora-Builds/private_keys/AuthKey_93BHUZGTCD.p8` (nur auf diesem Mac, nie committen) |
| Server | `ssh -i ~/.ssh/studinow_server root@46.225.32.3`, Code unter `/srv/uniflow/app`, `deploy/docker-compose.yml`, Prüfung `bash deploy/dienst-check.sh --no-mail --verbose`, Sicherung `bash deploy/backup.sh` |
| Website | Netlify, Upload `tools/site-hochladen.sh` (Token in `private_keys`), Quelle `docs/release/STARTSEITE.md` → `tools/gen-site.py` |
| Team-Einstellungen | `~/Studora-Builds/wt-b47/apps/apple/Config/Team.xcconfig` (fürs Bauen in einen Export-Ordner kopieren; fehlt sie, landet `[[TEAMID]]` in der Website) |
| GitHub | `https://github.com/Ahmad271223/uniflow-ai` – **öffentlich!** Nie Geheimnisse committen. Der Inhaber sollte es auf „privat“ stellen (nur er kann das). |

## 2. Builds und Versionen (das wichtigste Bild)

Die Build-Nummer zählt über alle Versionen weiter. Liste mit Commits: `docs/release/BUILD-HERKUNFT.md`.

| Build | Version | Commit / Tag | Stand |
|---|---|---|---|
| 46, 47 | 1.0.7 | `ios-1.0.7-b46/b47` | hochgeladen, nie eingereicht |
| **48** | **1.0.7** | `ios-1.0.7-b48` (c474bbd4) | **im App Store** (seit 25./26.11.) |
| 49 | 1.0.8 | `ios-1.0.8-b49` (bbb7e05c) | bei Apple, **nie einreichen** (Datei-Eingang noch an) |
| 50 | 1.0.8 | `ios-1.0.8-b50` (51571948) | bei Apple, ersetzt (ohne Göttingen) |
| 51 | 1.0.8 | `ios-1.0.8-b51` (9a34bb32) | gebaut, Upload hing (AWAITING_UPLOAD) und wurde abgebrochen – nicht bei Apple |
| **52** | **1.0.8** | `ios-1.0.8-b52` (**67430b23**) | **am 27.11. 17:07 eingereicht, WAITING_FOR_REVIEW**, Freigabe **von Hand** |

- **1.0.8 (Build 52)** enthält: Universität Göttingen (Stud.IP, Mensa), neue Tarife (Plus 1,99 €/Monat, Pro AI 3,99 €/Monat
  oder 39,99 €/Jahr mit 120 Credits, Bachelor+Master-Paket 39,99 € für 5 Jahre, Probe 7 Tage Plus + 25 Credits, KI nur
  mit Credits, Einladungen ohne Belohnung), Mitschrift (Whisper auf dem Gerät), Editor-Neuheiten ab **Plus**
  (Textblöcke, Notizzettel, Klappkarten, Verweise), Abgleich zweimal am Tag (Uni-Mail alle 30 min), Absturzmeldungen,
  viele Korrekturen (Fenster-Sperre am Mac, Zittern beim Zoom, Handballen, Studienverlauf-LP, QIS-Lücken, Göttingen-Befunde).
  Ohne: Tabelle, Kalender/Countdown/Widget, Göttingen-Mail/FlexNow/Hintergrund-Anmeldung.
- **1.0.9** = nächstes Update, noch kein Release-Zweig. Teile siehe Abschnitt 4.
- Bei Apple mit 1.0.8 eingereicht: neue Käufe `de.uniflow.plus.fuenfjahre` (IAP 6839975359, nicht verlängerndes Abo;
  das **erste** dieser Art ging nur über die ASC-Website zusammen mit der Version), „160 Credits“, neue deutsche und
  englische Abo-Texte. Monatsabos sind wieder im Verkauf. `de.uniflow.plus.yearly` (19,99) ist **noch** im Verkauf.

## 3. Server (live)

- Läuft seit 27.11. 21:18 auf `sicherheit/1.0.9` @ `1ea8e7fc` (= release `502c00e4` + Sicherheitspunkte; Datei
  `/srv/uniflow/app/VERSION-COMMIT`). Ablauf, Backups, Rückweg: `docs/release/DEPLOY-DIENST-2026-11-27.md`.
- Enthält Göttingen, neue Tarife (120 Credits, Probe 25, Pakete 80/160, Paket 5 Jahre), Absturzmeldungen (eigene Datei
  `/data/crash_reports.db`), Testkauf des Pakets nur 1 Tag, Credits auch für Test-Bewertung und Mail-KI, Probe-Credits
  einmal. System-Sicherheitsupdates + Neustart am 27.11. 18:56.
- Auf dem Server nur mit **ausdrücklichem Okay** des Inhabers etwas einspielen; vorher `backup.sh`, danach
  `dienst-check.sh` und im laufenden Dienst nachprüfen.

## 4. Zweige (alle auf GitHub gepusht, Stand 27.11. 22:15)

| Zweig | Commit | Für | Stand |
|---|---|---|---|
| `release/1.0.8-alles` | siehe GitHub | 1.0.8 | eingereicht als Build 52 (67430b23); danach nur Unterlagen |
| `sicherheit/1.0.9` | a3c2f490 | 1.0.9 | Server-Teil live; App-Teil: Prüfsummen der Mitschrift-Modelle (`WhisperModelIntegrity`), feste Paketversion swift-argument-parser 1.8.2, Test-Korrektur Studienverlauf. Kern 1978, App 29, Server 4160 grün |
| `editor/tabelle-109` | b19c4e19 (Ordner `wt-tabelle-109`) | 1.0.9 | Tabelle („Excel“) ab Plus, KI darin mit Credits; Spalten/Zeilen ziehen, automatisch breiter, einfügen/löschen. SheetAppTests 20/20, Mac 83/0; volle iPad-/iPhone-Läufe liefen noch (Editor-Sitzung) |
| `app/kalender-countdown-nachrichten` | 9ed67b98 | 1.0.9 | iPad 2368/5 rot (4 Editor-Messläufe, 1 Store-Bild); iPhone/Kern liefen noch (Kalender-Sitzung); Entscheidungen des Inhabers in jener Sitzung |
| `uni/goettingen` | 4fdabd40 | 1.0.9 | Hintergrund-Anmeldung Göttingen (Inhaber „Ja, freigeben“). Vorher einmal mit **falschem** Passwort echt testen (Sperre vermeiden) |
| `uni/goettingen-mail` | 3b29bef4 | 1.0.9 | Uni-Mail Göttingen über IMAP/SMTP (GWDG); nur gegen Nachbildung getestet – **Echttest mit Konto des Inhabers fehlt** |
| `uni/goettingen-flexnow` | cc080234 | 1.0.9 | angemeldete Prüfungen + Abmeldefrist aus FlexNow (nur lesen); **Echttest fehlt** |
| `site/1.0.8-veroeffentlichung` | 08dce397 (Ordner `wt-site-108-final`) | Website zu 1.0.8 | fertig, nur `[[DATUM]]` (Erscheinungsdatum) offen |
| `tarif/credits-neu`, `app/abruf-zweimal-taeglich`, `site/tarife-neu`, `site/1.0.8-rechtstexte` | – | schon in release bzw. in `site/1.0.8-veroeffentlichung` | nur zur Nachverfolgung |

Uncommittet: `wt-tabelle-109` hatte 1 uncommittete Datei (Editor-Sitzung arbeitete noch).

## 5. Was als Nächstes zu tun ist (Reihenfolge)

1. **Apple-Status prüfen** (`tools/asc.py GET /v1/appStoreVersions/ea26da7f-c26e-4fbb-b639-0a04f0c34502`).
   - Abgelehnt: Grund lesen (`/v1/reviewSubmissions?filter[app]=6830632088`, Resolution Center im Browser), dem Inhaber
     erklären, beheben, Build 53, nur mit seinem Okay neu einreichen.
   - **PENDING_DEVELOPER_RELEASE (genehmigt):** Inhaber hat bereits „Ja, dann hochladen“ gesagt für die Website:
     a) in `wt-site-108-final` `[[DATUM]]` in `docs/release/STARTSEITE.md` durch das Datum ersetzen, `tools/gen-site.py`,
     `pytest tests/test_site.py tests/test_rechtstexte.py` grün, `tools/site-hochladen.sh`; live prüfen.
     b) Inhaber Bescheid geben: er drückt selbst „Veröffentlichen“ in App Store Connect.
     c) Nach der Veröffentlichung: `de.uniflow.plus.yearly` aus dem Verkauf nehmen (Länder leeren über
     `subscriptionAvailabilities`; Bestandskunden verlängern weiter). Dann BUILD-HERKUNFT Zeile 52 „veröffentlicht“.
2. **Echter Gerätetest von Build 52** auf dem iPhone „Akho“ (00008130-001151941AC0001C) – Inhaber schließt es an, dann
   `xcrun devicectl device install app --device <UDID> ~/Studora-Builds/dd-geraet-b52/Build/Products/Release-iphoneos/UniFlow.app`.
   Am iPad „StudiNow“ (00008120-000E309830814032) ist Build 52 schon drauf.
3. **1.0.9 zusammenstellen** (erst wenn der Inhaber es will): neuer Zweig `release/1.0.9` von `release/1.0.8-alles`,
   einmischen: `sicherheit/1.0.9`, `editor/tabelle-109`, `app/kalender-countdown-nachrichten`, `uni/goettingen` (4fdabd40),
   `uni/goettingen-mail`, `uni/goettingen-flexnow` – jeweils mit Freigabe-Zitat des Inhabers. Göttingen-Mail/FlexNow und
   die Hintergrund-Anmeldung vorher mit seinem echten Konto testen (er meldet sich selbst an). `MARKETING_VERSION` 1.0.9,
   Build 53. Volltests: `b52-voll.sh` als Vorlage (iPad Simulator 1D5D98E1, iPhone 3B936266 bzw. D9056895 für StoreKit),
   Kern `swift test`, Server `tools/tests-schnell.sh`, Mac `tools/mac-test.sh` mit `caffeinate` und `$HOME`-Pfaden.
4. **Offen beim Inhaber** (nur er kann/entscheidet): GitHub privat stellen; ZQS-Mail für Stud.IP-OAuth abschicken
   (`anschreiben/ZQS-OAUTH-ANFRAGE-2026-11-26.md`); CloudKit-Schema nach Production; Apple-Fragen Altersfreigabe (bis
   15.01.2027) und China (bis 31.01.2027); Absturzmeldungen weiter „von selbst an“ oder erst fragen; Sicherung des
   gelöschten Kontos (`/root/rettung-2026-11-24`, bis ~24.12. entscheiden – **nicht löschen**).

## 6. Regeln des Inhabers (immer)

- Deutsch, einfache Worte. Nie Passwörter eingeben – der Inhaber meldet sich selbst an (Browser der App, Uni-Seiten).
- Server, Website, Push, Einreichen, Käufe bei Apple ändern: **nur mit seinem ausdrücklichen Okay**, und Okay gilt nur für
  das, wofür es gegeben wurde. Nie etwas kaufen. Nie „Konto löschen“ am echten Gerät/Konto des Inhabers testen.
- Freigaben, die eine andere Sitzung weitergibt, im Verlauf jener Sitzung nachprüfen
  (`mcp__ccd_session_mgmt__search_session_transcripts`).
- In den Release-Zweig mischt nur die Build-Sitzung; andere Sitzungen schicken Zweig + Freigabe-Zitat + Testzahlen.
- Keine unbestätigten Zahlen veröffentlichen (Website: nur „Über 500 Downloads“). Konten ≠ Downloads.
- Server nur lesend abfragen, nur Zahlen, keine Namen/Mails – außer er sagt „Liste zeigen“.
- Lösungen in der Community immer neben dem eigenen Dokument, Original-Hintergrund, Original-Schrift.
- „Schrift als Bild“ nicht ausliefern ohne sein Okay am Gerät; „Text glätten“ nicht bauen, wenn er es nicht bestellt.
- Commits enden mit `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## 7. Bekannte Eigenheiten

- Upload zu Apple: `xcodebuild -exportArchive … -exportOptionsPlist ~/Studora-Builds/ExportOptions-upload.plist
  -allowProvisioningUpdates -authenticationKeyPath …AuthKey_93BHUZGTCD.p8 -authenticationKeyID 93BHUZGTCD
  -authenticationKeyIssuerID a5fea04a-eb9b-4e3e-9442-b5ab1e0462a6` (über das Xcode-Konto: „Failed to Use Accounts“).
  Hängt er über 10 min bei AWAITING_UPLOAD, abbrechen und neu starten.
- Nach einem Merge mit neuen/gelöschten Swift-Dateien vor dem Test `xcodegen generate` (sonst „Build input file cannot be found“).
- Mac-Lauf: ~60 rote Tests sind bekannt (Anmelde-/Editor-Tests mit nachgestellten Berührungen); vergleichen mit
  `~/Studora-Builds/b52-mac-voll.log`. Nie zwei Mac-Läufe gleichzeitig.
- StoreKit-Tests im Simulator 3B936266 zeigen keine Preise (Simulator-Eigenheit); D9056895 nehmen.
- Test `StoreScreenshotTests/test01Uebersicht` ist seit 1.0.7 rot (bekannt).

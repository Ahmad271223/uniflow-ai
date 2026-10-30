# Studora (Repo `uniflow-ai`)

Stand 30.10.2026, Zweig `develop`. Die App heißt in allen sichtbaren Texten **Studora**; Repository, Ordner und
Kennungen (`de.uniflow.ai`, `UniFlowCore`) heißen weiter UniFlow.

## 1. Was ist das

Studora holt die Unterlagen aus den Systemen der Hochschule (LUH: Stud.IP und QIS; Uni Hildesheim: Learnweb, LSF und
CAS), ordnet jede Datei nach Fach, Art und Lehrwoche, baut daraus den Stundenplan und den Lernplan, stellt pro Modul
und Lehrwoche einen Wochentest zusammen und lässt die PDFs lesen, markieren und mit Stift beschreiben. Dazu kommen
Karteikarten, Noten, eine Community zum Teilen von Lösungen und ein Studora-Konto, das die Geräte eines Nutzers
verbindet.

Grundsatz: Jedes Gerät hat seine Daten selbst und arbeitet auch ohne Internet. Der Studora-Dienst verbindet die Geräte
eines Kontos und die Studierenden einer Hochschule; er ist nicht die Voraussetzung dafür, dass die App läuft
(`docs/ARCHITEKTUR-ZIEL-2026-10-29.md`).

Entscheidungen des Inhabers vom 30.10.2026 (`docs/PLAN-WEB-ZUERST-2026-10-30.md`): zuerst die **Web-Version über den
eigenen Dienst**, Windows über den **Microsoft Store**, iPad und Mac **vorerst als Web-App** (das Apple Developer
Program wurde am 28.10. abgelehnt); sobald Apple freigibt, laden iPad- und Mac-Nutzer die App aus dem App Store und
melden sich mit ihrem Studora-Konto an, der Rest wird übernommen.

### Was die App kann (Stand des Codes)

| Bereich | Stand |
| --- | --- |
| Abgleich mit der Hochschule | Stud.IP (WebSSO, JSON-API, Ordner, Dateien, Termine, Opencast), Learnweb und LSF (CAS). Am PC zweimal täglich (8:00, 15:00), auf dem iPad im Hintergrund um 8, 15 und 20 Uhr. Dateityp und Lehrwoche kommen aus Ordner und Dateiname (`app/study.py`, Swift `UniRules`). |
| Stundenplan | 1:1 aus dem Stud.IP-Kalender bzw. LSF, Ausfälle, Ausnahmen, freie Fenster, Sperrzeiten, ICS-Import. |
| Lernplan | Regel des Inhabers vom 30.10.: je Tag nur der Stoff seiner Lehrwoche, dazu der Skriptrest nach dem Seitenmarker der Vorwoche. Läuft automatisch nach jedem Abgleich (`study.auto_plan_week`, iPad `StudyAutoPlan.afterSync`). Der frühere KI-Wochenplan ist entfernt. |
| Wochentests mit Seitenmarker | „Vorlesung bis hier“ im Skript setzen; 15 Aufgaben (4 leicht, 6 mittel, 5 schwer), genau eine Altklausuraufgabe, wenn es eine Altklausur gibt; Veröffentlichung 24 h nach der Vorlesung, gleiche Version für alle mit gleichem Stoffstand, Nachtrag, Rangliste, Probeklausur auf Anfrage. Auf dem iPad auch im Hintergrund (8, 15, 20 Uhr), im Dienst als Job je Konto. `docs/WOCHENTESTS.md`. |
| Dokumente und Editor | Web: pdf.js und Konva, Stift mit Druck, Text, Formen, Bilder, Haftnotizen, Lasso, Seitenwerkzeuge, Versionsverlauf, Export. iPad: PDFKit und PencilKit, gleiche Notizdatei. Seite drehen mit Notizen, Lösungen-Editor, verschlüsseltes Teilen (`docs/EDITOR-ABNAHME.md`). |
| Karteikarten | Anlegen, Wiederholung nach Leitner; auf dem iPad ab Plus. |
| Uni und Noten | QIS-Notenspiegel und Bescheinigungen (LUH), LSF-Noten (Hildesheim), Kacheln aller Uni-Dienste. |
| Community | Lösungen als verschlüsseltes Paket teilen (nur mit der Original-PDF lesbar), auf die eigene PDF projizieren, Likes, Kommentare an der Stelle, Rangliste für den Inhaber. Web und Windows über den Dienst (`app/community_api.py`); iPad heute über CloudKit, Umstellung auf den Dienst geplant. |
| Konto und Abgleich | Studora-Konto (E-Mail, Google; Apple erst nach der Apple-Freigabe), Geräte, Datenexport, Konto löschen (G1). Abgleich der Daten zwischen Geräten eines Kontos (G2): Dienst, Windows und Android fertig, iPad noch ohne G2-Client. |
| Abos | Free, Plus, Pro Connect, Pro AI (`app/plans.py`). Jedes neue Konto hat 7 Tage Probe mit allen Rechten, danach Tarifwahl, ohne Wahl Free. Bezahlung im Web und unter Windows über Stripe, in der Apple-App über den App Store, Microsoft Store später. `docs/ABO-SYSTEM.md`. |
| KI | Drei Wege: (1) am eigenen PC die Claude Code CLI (`claude -p`, Modell über `CLAUDE_MODEL`); (2) **Sign in with ChatGPT**, das ChatGPT-Abo des Nutzers, am PC, unter Windows und auf dem iPad, ohne vorab vergebene Client-ID (dynamische Registrierung); im gehosteten Dienst erst nach der Freigabe durch OpenAI; (3) **Studora-KI** im Dienst (Pro AI, `app/ai_backend.py`, Budget je Konto). Alle KI-Funktionen sind nur mit simulierter KI geprüft, nie mit echter KI auf echtem Skript. `docs/KI-CHATGPT-PLAN.md`. |

## 2. Betriebsarten

| Betriebsart | Was läuft | Stand 30.10.2026 |
| --- | --- | --- |
| **Eigener PC** (`serve.py`) | Python-Server (FastAPI) und Web-Oberfläche im Browser unter `http://localhost:8765`; Abgleich per Aufgabenplanung; KI über `claude -p` oder das ChatGPT-Abo. Mit `serve.py --lan` auch im WLAN für ein iPad (PIN). | Täglich vom Inhaber benutzt, pytest 598 grün. |
| **Windows-App** (`apps/windows`, Tauri 2, Backend als PyInstaller-Paket, Version 0.4.9) | Dieselbe Oberfläche und Datenbank wie `serve.py`, ohne Python auf dem PC; Konto und Community über den Dienst; Hochschul-Anmeldung im Fenster der App. | Für den eigenen Gebrauch benutzbar (Installer ohne Signatur, SmartScreen warnt). MSIX für den Store baut; Partner-Center-Werte, Screenshots und öffentliche Datenschutzerklärung fehlen. Kein Test auf einem fremden Windows-Rechner. `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md`. |
| **iPad und Mac, native App** (`apps/apple`, SwiftUI; Mac über „Designed for iPad“) | Ohne PC: lokale Datenbank, Stud.IP und Learnweb direkt vom Gerät, Editor mit Apple Pencil, Lernplan, Wochentests, Community über CloudKit, KI über das ChatGPT-Abo, Abos Free und Plus über StoreKit 2. | Build fehlerfrei, App 564 Tests im iPad-Simulator (Mac, 30.10.), Swift-Kern 776. **Nie auf einem echten iPad oder Mac gelaufen.** Apple Developer Program abgelehnt (28.10.): kein TestFlight, keine Einreichung, kein „Mit Apple anmelden“, kein CloudKit im Betrieb. Darum vorerst Web-App. |
| **Web-App über den Dienst** (`app/static`, `LERNAPP_MODE=hosted`) | Anmeldung mit dem Studora-Konto im Browser; installierbar („Zum Home-Bildschirm“ auf dem iPad, „Zum Dock“ auf dem Mac, „Installieren“ in Edge/Chrome, `app/static/pwa.js`); Service Worker mit Offline-Rückfall für Oberfläche, zuletzt geöffnete PDFs und Listen (`sw.js`, `sw-policy.js`); Änderungen ohne Netz scheitern mit Code `offline`. Hochschul-Abgleich durch den Dienst nur mit ausdrücklicher Zustimmung je Konto (`PUT /api/credentials` mit `consent: true`). Wochentests mit der Studora-KI, Probe und Stripe. | Gebaut und mit pytest (inkl. echtem Chromium-Lauf in `tests/test_pwa.py`) und JS-Tests geprüft. **Nie in Safari auf einem iPad oder Mac geprüft.** Notizen ohne Netz zwischenspeichern und nachsenden fehlt noch. |
| **Studora-Dienst** (`deploy/`) | Docker-Image, Caddy mit HTTPS, Backups, Löschfristen; Konto (G1), Abgleich (G2), Community (G4), Billing, Jobs für Hochschul-Abgleich und Wochentests; eine SQLite-Datenbank je Konto. | Code und Hosting-Paket fertig, lokal in Docker geprüft. **Nie auf einem Server in Betrieb.** Server, Domain, Mail-Anbieter, Stripe-Konto und Rechtstexte muss der Inhaber beschaffen (`docs/release/BETRIEB.md`). |
| **Android** (`apps/android`) | Client für den Dienst oder den PC im WLAN: Übersicht, Dokumente mit Stift, Stundenplan, Lernkalender, Offline-Stand, Abgleich G2. | 119 Tests im Docker-Bild, nie auf einem Gerät. Zweite Version (V2). |

## 3. Einrichtung (eigener PC)

1. `.env.example` nach `.env` kopieren und Zugangsdaten eintragen: LUH `STUDIP_USER`/`STUDIP_PASSWORD`, Hildesheim
   `HILDESHEIM_USER`/`HILDESHEIM_PASSWORD` (Hochschule auch unter Einstellungen → Zugang & Darstellung). Die Datei
   bleibt nur auf dem PC.
2. Abhängigkeiten: `python -m venv .venv`, dann `pip install -r requirements.txt -r requirements-dev.txt` und
   `playwright install chromium`.
3. Login einmal sichtbar testen:
   ```bash
   .venv\Scripts\python.exe sync.py --show --no-ai
   ```
   Ein Browserfenster meldet sich an und lädt die Dateien nach `data/files/`. Bei Problemen: `logs/login-fehler.png`.
4. Automatik (Aufgabenplanung 8:00 und 15:00 Uhr; mit `-Autostart` startet der Server bei der Anmeldung):
   ```bash
   powershell -ExecutionPolicy Bypass -File scripts\install_schedule.ps1
   ```
5. Server starten: `.venv\Scripts\python.exe serve.py`, dann <http://localhost:8765>.
6. iPad im WLAN: `Start-iPad.cmd` (oder `serve.py --lan`), auf dem iPad `http://<PC-IP>:8765` öffnen, PIN aus den
   Einstellungen eingeben. Im eduroam sehen sich die Geräte nicht; mobiler Hotspot am PC hilft.
7. KI: entweder Claude Code installieren (`claude` im PATH, Modell in der `.env`: `CLAUDE_MODEL=sonnet`,
   `CLAUDE_MODEL_MATERIAL=haiku`) oder unter Einstellungen → Erweitert „ChatGPT verbinden“ (eigenes ChatGPT-Abo,
   Token nur auf diesem Rechner in `chatgpt-auth.json`). Ohne beides laufen Abgleich, Lernplan, Editor und Noten weiter;
   es entstehen keine Wochentests.

Befehle:

```bash
.venv\Scripts\python.exe sync.py             # Abgleich, Analyse, Lernplan der Woche, fällige Wochentests
.venv\Scripts\python.exe sync.py --no-ai     # nur Dateien holen (ohne Analyse, Lernplan und Tests)
.venv\Scripts\python.exe sync.py --plan      # Lernplan der Woche neu bauen
.venv\Scripts\python.exe sync.py --tests     # fehlende Wochentests erzeugen (braucht KI)
.venv\Scripts\python.exe sync.py --qis       # Noten und Bescheinigungen jetzt abrufen (sonst alle 20 h)
.venv\Scripts\python.exe sync.py --reanalyze # Dateien erneut einordnen
```

Hinweise: Der Login geht über den WebSSO-Link der LUH (Shibboleth). Dateien, die in Stud.IP erst nach einer
Zustimmung zu Nutzungsbedingungen geöffnet werden dürfen, liefern `403`; einmal in Stud.IP öffnen, dann lädt der
nächste Abgleich sie. Gleichnamige Dateien in einem Kurs bekommen lokal ein Suffix mit der Datei-ID.

Dienst und Windows-App: Betrieb des Dienstes in `docs/release/BETRIEB.md` (`deploy/.env.example` nach `deploy/.env`,
`docker compose up`), Windows-App in `apps/windows/README.md` (Workflow `windows.yml`; GitHub Actions sind seit 25.10.
wegen der Abrechnung gesperrt, alle Commits tragen `[skip ci]`).

## 4. Tests

Python ist die Referenz. 21 Generatoren (`tools/gen-*.py`) führen den Python-Code mit erfundenen Daten und
eingefrorener Uhr aus und schreiben Prüfdaten nach `packages/shared-contracts/`; Swift und Kotlin müssen dieselben
Antworten byte-gleich liefern. Darum lässt sich der Kern ohne Mac prüfen.

| Prüfung | Befehl | Stand 30.10.2026 |
| --- | --- | --- |
| Python | `.venv/bin/python -m pytest -q` | 598 grün |
| Generatoren | `for g in tools/gen-*.py; do .venv/bin/python $g --check; done` | 21 / 21 |
| Web (JS) | `node --test tests/js/*.test.mjs` (Node 22, Dateien einzeln nennen) | 38 grün |
| Swift-Kern `UniFlowCore` | `swift test` in `apps/apple/Packages/UniFlowCore`; ohne Mac in Docker (`swift:6.1-noble`, Anleitung in `docs/BERICHT-CLOUD-SITZUNG-2026-10-30.md` Abschnitt 6) | 776 auf dem Mac, 761 unter Linux (Schlüsselbund- und ChatGPT-Sitzungstests nur auf Apple) |
| iPad-App | `xcodebuild test` im Simulator „iPad“ (Mac, Xcode; `apps/apple/README.md`) | 564 grün, zweimal |
| Android | Gradle im Docker-Bild `ghcr.io/cirruslabs/android-sdk:35` | 119 grün |

Regel des Inhabers: volle Zyklen (Generatoren, pytest, Kern ×2, App ×2), absichtlich eingebaute Fehler müssen von
den Tests gefunden werden. GitHub Actions laufen seit dem 25.10. nicht (Abrechnung, `docs/GITHUB-ABRECHNUNG.md`); alle
Zahlen oben stammen aus lokalen Läufen (Cloud-Container, Mac).

Ungeprüft bleibt: echte KI auf echtem Skript, echtes iPad mit Apple Pencil, Web-App in Safari, der Dienst auf einem
Server, Hintergrundläufe durch iOS (im Simulator nicht möglich).

## 5. Aufbau

| Pfad | Zweck |
| --- | --- |
| `app/server.py` | FastAPI-Backend (`/api/...`), Einzelplatz und gehosteter Modus (`LERNAPP_MODE=hosted`) |
| `app/studip_sync.py`, `app/learnweb.py`, `app/lsf.py`, `app/cas.py`, `app/qis.py` | Hochschulen: Stud.IP, Learnweb, LSF, CAS-Login, QIS-Noten |
| `app/study.py`, `app/timetable.py`, `app/weekly.py`, `app/testshare.py` | Einordnung und Lernplan, Stundenplan, Wochentests mit Seitenmarker, gemeinsamer Testschlüssel |
| `app/ai.py`, `app/chatgpt_login.py`, `app/ai_backend.py` | KI über `claude -p`, Sign in with ChatGPT, Studora-KI mit Kostenkontrolle |
| `app/accounts.py`, `app/account_api.py`, `app/sync.py`, `app/sync_client.py`, `app/community*.py` | Konto (G1), Geräte-Abgleich (G2) Dienst- und Client-Seite, Community (G4) |
| `app/plans.py`, `app/entitlements.py`, `app/billing*.py`, `app/stripe_billing.py`, `app/apple_store.py` | Tarife, Rechte, Probe, Stripe, Apple-Belege |
| `app/jobs.py`, `app/vault.py`, `app/mail.py`, `app/retention.py` | Dienst: Job-Warteschlange, verschlüsselter Tresor für Uni-Zugangsdaten, Mail, Löschfristen |
| `app/static/` | Web-Oberfläche: `app.js`, `editor.js`, `views-*.js`, `pwa.js`, `sw.js`, `sw-policy.js`, `login.html` |
| `apps/apple/` | iPad-App (`UniFlow/`), Swift-Kern (`Packages/UniFlowCore`, lokales Backend mit denselben `/api`-Pfaden) |
| `apps/windows/` | Tauri-Fenster, PyInstaller-Backend, MSIX für den Store |
| `apps/android/` | Kotlin-Kern und Compose-App |
| `packages/shared-contracts/` | Schemas, API-Verträge, Prüfdaten für alle Plattformen |
| `deploy/` | Dockerfile, docker-compose, Caddyfile, Backup-Skripte und systemd-Timer |
| `tools/` | Generatoren der Prüfdaten, `gen-parity.py` |
| `tests/`, `tests/js/` | pytest, Node-Tests |
| `data/`, `logs/` | Datenbank `lernapp.db`, Dateien, Browserprofil; `sync.log`, `ai.log`, Fehler-Screenshots |

## 6. Dokumentation

| Datei | Inhalt |
| --- | --- |
| `RELEASE-READINESS.md` | Was gebaut, geprüft und offen ist; was bis zur Veröffentlichung fehlt |
| `docs/ENTWICKLUNGSSTAND.md` | Stand nach Phasen mit Testläufen |
| `docs/BERICHT-CLOUD-SITZUNG-2026-10-30.md` | Bericht des 30.10.: Architektur, Testzahlen, Nachtrag Mac |
| `docs/PLAN-WEB-ZUERST-2026-10-30.md` | Plan Web zuerst, Entscheidungen des Inhabers vom 30.10. |
| `docs/ARCHITEKTUR-ZIEL-2026-10-29.md` | Geräte, Dienst, Datenbank, Abgleich |
| `docs/UEBERGABE-MAC-NEUE-SITZUNG-2026-10-30.md` | Einrichtung und Regeln für die Mac-Sitzung |
| `docs/WOCHENTESTS.md`, `docs/GEMEINSAME-WOCHENTESTS.md` | Seitenmarker, Ablauf, Hintergrundlauf, Dienst; gemeinsamer Testschlüssel |
| `docs/KI-CHATGPT-PLAN.md` | Sign in with ChatGPT, OpenAI-Zulassung, Stand 30.10. |
| `docs/ABO-SYSTEM.md` | Tarife, Rechte, Probe und Stripe |
| `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` | Windows-App, Microsoft Store, was der Inhaber beschaffen muss |
| `docs/release/` | Betrieb des Dienstes, Rechtstexte (Entwürfe mit Platzhaltern), Store-Texte |
| `docs/EDITOR-ABNAHME.md`, `docs/MAC-IPAD-CHECKLISTE.md` | Abnahme am echten iPad mit Apple Pencil |
| `docs/HILDESHEIM.md`, `docs/HILDESHEIM-PARITAET.md` | Uni Hildesheim |
| `docs/SICHERHEIT.md`, `docs/SICHERHEITSKONZEPT-KONTEN.md`, `docs/VERTRAEGE-KONTO-SYNC.md` | Sicherheit, Konten, Verträge G1/G2/G4 |
| `WEB-IPAD-PARITAET.md` | Checkliste Web ↔ iPad je Funktion (Stand 25.10., veraltet) |

# UniFlow für Windows (Tauri + mitgeliefertes Backend)

**Stand 26.10.2026:** Die App bringt ihr Backend mit. Kein `Start-iPad.cmd`, kein Python auf dem PC nötig.

## Aufbau

- `backend/` – PyInstaller-Paket des Python-Servers (`uniflow-backend.spec`, Einstieg `entry.py` → `app/desktop.py`).
  Ordner-Paket (`dist/uniflow-backend/`), Chromium für Playwright als `ms-playwright` daneben (legt der Workflow hinein).
- `src-tauri/` – das Fenster (Rust, Tauri 2). Beim Start wird `backend/uniflow-backend.exe` aus den Ressourcen
  gestartet, mit der eigenen Prozess-ID als Elternprozess. Das Backend bindet einen freien Port auf `127.0.0.1`
  (der Port ist offen, bevor die Datei existiert), schreibt `%LOCALAPPDATA%\de.uniflow.desktop\backend.json` und übergibt den
  Socket an uvicorn. Das Fenster wechselt nur dorthin, wenn die Datei die PID des gerade gestarteten Backends nennt
  (keine alte Datei, kein fremder Prozess) und die URL genau `http://127.0.0.1:<port>/` lautet; endet das Backend
  vorher, zeigt die Startseite sofort den Fehler mit Hinweis auf das Protokoll. Beim Schließen wird das Backend
  beendet; es endet außerdem selbst, sobald das Fenster weg ist (`app/desktop.py::watch_parent`; unter Unix gilt
  auch ein nicht abgeholter Zombie als beendet). Die exe hat keine Konsole: `stdout`/`stderr` gehen nach
  `logs\backend.log`, ein Fehler beim Start steht dort und beendet den Prozess mit Code 1 (kein Fehlerfenster).
- `dist/` – Startseite des Fensters (`index.html`, `start.js`, `start.css`), ohne Inline-Skripte. Im Entwicklungsmodus
  wechselt sie nur zu `serve.py`, wenn `/api/account/info` mit Status 200 und JSON mit `mode` antwortet.
- `scripts/` – `check-backend.ps1` (gepacktes Backend starten, Zustandsdatei gegen PID/URL prüfen, API und CSP
  abfragen) und `check-installer.ps1` (Installer still installieren, Dateien prüfen, Backend-Test, still deinstallieren).
- `app-icon.png` – Quelle der Windows-Icons (1024×1024, Kopie des App-Icons); `npx tauri icon app-icon.png` erzeugt
  `src-tauri/icons/` (nicht eingecheckt).
- Version: `package.json`, `src-tauri/tauri.conf.json` und `src-tauri/Cargo.toml` müssen dieselbe Version nennen
  (Test `test_windows_app_versions_match`); der Installer heißt danach.
- Daten, Protokolle und `.env` liegen unter `%LOCALAPPDATA%\de.uniflow.desktop` (`data`, `logs`, `.env`), getrennt vom
  Programmordner `%LOCALAPPDATA%\UniFlow`, in den der Installer schreibt. Der Datenordner heißt wie der `identifier` in
  `tauri.conf.json`; „App-Daten entfernen“ beim Deinstallieren meint genau ihn, sonst bleiben die Daten liegen. Bis
  0.3.0 lagen beide im selben Ordner; dabei kam es beim Start zu „WinError 183“ beim Anlegen von `logs` (27.10.2026).
  Alte Daten (`data`, `.env`) zieht das Backend beim ersten Start einmal in den neuen Ordner um (`desktop.migrate_legacy`);
  hält ein altes Backend die Datenbank noch offen, startet es einmal mit dem alten Ordner. Jeder Startfehler endet mit
  Code 1 und einem Eintrag in `logs\backend.log` (oder `%TEMP%\uniflow-backend-start.log`), nie mit dem Fehlerfenster
  von PyInstaller.
- **Sicherungen:** Beim Start sichert das Backend jede Datenbank nach `%LOCALAPPDATA%\UniFlow-Sicherungen`
  (`lernapp-<Datum>.db`, höchstens alle 6 Stunden, die neuesten 10 bleiben; `desktop.backup_databases`). Der Ordner
  liegt bewusst außerhalb von `de.uniflow.desktop`: Wer beim Deinstallieren „Anwendungsdaten löschen“ anhakt, verliert
  den Datenordner (Kurse, Dateien, Notizen, Hochschul-Sitzung) – Befund 27.10.2026 –, die Sicherungen bleiben.
  Wiederherstellen: App beenden, Sicherung nach `%LOCALAPPDATA%\de.uniflow.desktop\data\lernapp.db` kopieren, App
  starten (Dateien und Hochschul-Sitzung kommen mit dem nächsten Abgleich wieder).
  Dieselbe Oberfläche, Datenbank und derselbe Abgleich wie `serve.py`; ein bestehender Datenordner im Projekt wird
  nicht übernommen (eigene Installation = eigener Datenordner).

## Sicherheit

- Content-Security-Policy: die Oberfläche kommt vom Backend und bekommt dort eine strenge Richtlinie
  (`app/server.py::UI_CSP`: nur eigene Skripte, kein `eval`, nicht einbettbar); die Startseite des Fensters hat ihre
  eigene in `tauri.conf.json` (`csp` nicht mehr `null`). Die Oberfläche hat keinen Zugriff auf Tauri-Befehle
  (`capabilities/default.json`: nur `core:default` für die Startseite).
- Das Backend hört nur auf `127.0.0.1`; Zugriff aus dem WLAN gibt es in der Windows-App nicht (dafür `serve.py --lan`).
- Signierung des Installers erst vor einer Veröffentlichung (Zertifikat kauft der Inhaber); bis dahin warnt
  SmartScreen beim ersten Start.

## Bauen

Workflow `.github/workflows/windows.yml` (Windows-Runner; läuft bei `push` auf `develop` mit Änderungen unter
`apps/windows/**`, `app/**`, `requirements.txt` oder am Workflow, sonst von Hand): Python 3.12 → Tests
`tests/test_desktop.py` → `playwright install chromium` → PyInstaller → Chromium ins Paket (bricht ab, wenn kein
`chromium-*` da ist) → `scripts/check-backend.ps1` → Icons aus `app-icon.png` → `npx tauri build` (NSIS, aktueller
Benutzer) → `scripts/check-installer.ps1` (still installieren nach `%LOCALAPPDATA%\UniFlow`, prüfen, deinstallieren).
Artefakt `uniflow-windows`: `UniFlow_<version>_x64-setup.exe`.

Lokal (Backend allein, ohne Rust):

```bash
.venv/Scripts/python.exe -m PyInstaller apps/windows/backend/uniflow-backend.spec --noconfirm --distpath apps/windows/backend/dist
```

```bash
apps/windows/backend/dist/uniflow-backend/uniflow-backend.exe --state %TEMP%\uniflow.json --base %TEMP%\uniflow-base
```

Dann steht die URL in der Zustandsdatei (oder: `pwsh apps/windows/scripts/check-backend.ps1 -Exe <exe>` macht Start,
Abfrage und Ende in einem). Für das Fenster braucht es Rust (`rustup`) und `npm install` in `apps/windows`,
dann `npx tauri dev` (ohne Paket verbindet sich die Startseite mit `serve.py` auf Port 8765) oder `npx tauri build`.

## Browserfenster in der App

Seit 0.3.9 erscheinen Links („Im Stud.IP öffnen“, Fristen, Dienste) und das Anmeldefenster der Hochschule als Fenster
der App (WebView2), nicht als Edge oder Chrome. Das Tauri-Fenster holt dafür beim Backend Aufträge ab
(`GET /api/desktop/commands`, lange Abfrage; `app/desktop_windows.py`) und meldet den Zustand jedes Fensters zurück
(`POST /api/desktop/windows/{id}/state`). Beim Anmeldefenster liefert es jede Sekunde die Cookies der Hochschul-Adressen;
das Backend prüft damit die Anmeldung (`unilogin.check_cookies`: Stud.IP `users/me`, Learnweb `/my/`), merkt die Sitzung
und lässt das Fenster schließen. Die Cookies des Fensters bleiben im WebView2-Profil der App (`EBWebView`), die
Hochschule bleibt also meist bis zum Ablauf angemeldet. Ohne Fenster-Agent (serve.py am PC, ältere App) wie bisher:
Systembrowser für Links, Chromium von Playwright für die Anmeldung. App-Fenster öffnen nur http(s).

Noch offen: WebView2 bietet in diesem Fenster kein „Passwort speichern?“ an (das Chromium von Playwright tat das);
dafür müsste die App die WebView2-Einstellung `IsPasswordAutosaveEnabled` setzen (webview2-com). Bis dahin tippt
der Mensch das Hochschul-Passwort, wenn die Sitzung abgelaufen ist.

## Hochschul-Anmeldung ohne Passwort in der App

Einstellungen → Zugang → „Im Browser anmelden“ öffnet das Anmeldefenster der Hochschule (sichtbares Chromium von
Playwright mit eigenem Profil unter `%LOCALAPPDATA%\de.uniflow.desktop\data\browser-profile*`). Der Mensch meldet sich selbst
an; Chromium bietet „Passwort speichern?“ an und füllt beim nächsten Mal vor (geprüft 27.10.2026, Eintrag in
`Login Data`, DPAPI-verschlüsselt). Die App merkt nur die Sitzung (`university-session.json` im Datenordner) und
nutzt sie für den Abgleich und das Öffnen von Dateien (`app/unilogin.py`, `POST /api/university/login`,
`GET/DELETE /api/university/session`). Ist die Sitzung abgelaufen, meldet der Abgleich „Anmeldung nötig“.
Zugangsdaten in der `.env` sind nur noch eine freiwillige Alternative für den Abgleich ohne Nachfrage.

## Microsoft Store

MSIX-Paket fuer den Store (Store signiert und verteilt Updates selbst): `msix/README.md`, gebaut im selben Workflow
(Artefakt `uniflow-windows-msix`). Was in Partner Center einzurichten ist, steht dort.

Zweiter Start (Doppelklick bei laufender App): das Einzelinstanz-Plugin holt das offene Fenster nach vorn, es gibt nie
zwei Backends auf derselben Datenbank (seit 0.3.6).

## KI über das eigene ChatGPT-Konto

Einstellungen → Erweitert → „KI über mein ChatGPT“ → „ChatGPT verbinden“: die Anmeldung bei OpenAI läuft in einem
Fenster der App (Sign in with ChatGPT, OAuth mit PKCE, Rückleitung auf `127.0.0.1`; ohne Fenster-Agent im Standardbrowser), das Zugriffstoken liegt danach
nur in `%LOCALAPPDATA%\de.uniflow.desktop\data\chatgpt-auth.json`. Mit gewähltem Modell und eingeschaltetem Schalter
laufen Erklärungen im Editor, Analysen und Lernpläne über das ChatGPT-Abo statt über Claude Code; Bilder und PDF-Seiten
liest weiter nur Claude. „Trennen“ löscht das Token. Details: `docs/KI-CHATGPT-PLAN.md`, Abschnitt 3a.

## Offen


- Automatische Updates (Tauri-Updater braucht einen signierten Endpunkt) und Code-Signing.
- Größe: Chromium macht den Großteil des Installers aus (etwa 150 MB gepackt).

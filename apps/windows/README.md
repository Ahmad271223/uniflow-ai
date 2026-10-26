# UniFlow für Windows (Tauri + mitgeliefertes Backend)

**Stand 26.10.2026:** Die App bringt ihr Backend mit. Kein `Start-iPad.cmd`, kein Python auf dem PC nötig.

## Aufbau

- `backend/` – PyInstaller-Paket des Python-Servers (`uniflow-backend.spec`, Einstieg `entry.py` → `app/desktop.py`).
  Ordner-Paket (`dist/uniflow-backend/`), Chromium für Playwright als `ms-playwright` daneben (legt der Workflow hinein).
- `src-tauri/` – das Fenster (Rust, Tauri 2). Beim Start wird `backend/uniflow-backend.exe` aus den Ressourcen
  gestartet, mit der eigenen Prozess-ID als Elternprozess. Das Backend bindet einen freien Port auf `127.0.0.1`
  (der Port ist offen, bevor die Datei existiert), schreibt `%LOCALAPPDATA%\UniFlow\backend.json` und übergibt den
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
- Daten, Protokolle und `.env` liegen unter `%LOCALAPPDATA%\UniFlow` (`data`, `logs`, `.env`), nie im Programmordner.
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

## Offen

- Automatische Updates (Tauri-Updater braucht einen signierten Endpunkt) und Code-Signing.
- Größe: Chromium macht den Großteil des Installers aus (etwa 150 MB gepackt).

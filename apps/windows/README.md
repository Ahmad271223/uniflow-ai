# UniFlow für Windows (Tauri)

**Stand 25.10.2026: angelegt, nicht gebaut.** Auf dem Entwicklungs-PC fehlt Rust, und GitHub Actions war beim
Anlegen gesperrt (Kontingent). Gebaut wird über den manuell startbaren Workflow `.github/workflows/windows.yml`
(Windows-Runner, Minuten zählen doppelt).

## Ansatz

Ein Tauri-2-Fenster öffnet die bestehende Weboberfläche des lokalen Servers (`http://127.0.0.1:8765`). Dadurch gibt
es keinen zweiten Code für Windows: dieselben Dateien wie im Browser, dieselbe Stifteingabe (Pointer Events mit
Windows Ink), dieselben Notizen. Läuft der Server nicht, zeigt das Fenster eine Anleitung (`dist/index.html`).

Passt zum vorhandenen Frontend, weil es nur relative Pfade (`/api/...`) nutzt und vom Server ausgeliefert wird.
Die Herkunftsprüfung des Servers erlaubt Anfragen von `127.0.0.1` (gleiche Herkunft).

## Nächste Schritte

1. Workflow einmal starten, Installer (`*.exe`, NSIS) aus den Artefakten testen.
2. `Cargo.lock` aus dem ersten Build übernehmen (reproduzierbare Builds).
3. Später: Server als mitgelieferter Hintergrundprozess (PyInstaller-Paket) statt `Start-iPad.cmd`.
4. Signierung (Code-Signing-Zertifikat) erst vor einer Veröffentlichung, nach Freigabe.

## Bauen (mit Rust und Node)

```bash
npm install --prefix apps/windows
```

```bash
npx --prefix apps/windows tauri icon apps/apple/UniFlow/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png -o apps/windows/src-tauri/icons
```

```bash
npm --prefix apps/windows run tauri build
```

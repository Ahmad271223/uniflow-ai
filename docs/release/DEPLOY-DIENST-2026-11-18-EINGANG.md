# Dienst-Update 18.11.2026 – Datei-Eingang

Auftrag des Inhabers (18.11.2026): „ich mache die texte in datenschutz selber lade die ganzen funktionen alles schonmal hoch“.

## Was

Auf dem Server lief `fc66fba4` (Build 42, seit 15.11.2026 01:17). Ausgerollt wird **genau dieser Stand plus nur der
Datei-Eingang** (Zweig `server/b42-plus-eingang`), nicht `develop`: dort liegen 38 weitere Server-Änderungen, u. a. die
KI-Credits mit dem neuen Credit-Wert, die noch kein Okay zum Ausrollen haben.

| Datei | Was |
|---|---|
| `app/intake_api.py` | `POST /api/intake/check`, `POST /api/intake/file`: mit Konto, je Tag begrenzt, Weitergabe an den Eingang |
| `app/intake_server.py` | Programm des Eingangs (läuft auf dem eigenen Server; im Dienst nur für das Ticket gebraucht) |
| `app/server.py` | Router eingebunden, Upload-Grenze für `/api/intake/file` |
| `deploy/.env` | `LERNAPP_INTAKE_URL=http://10.0.0.3:8780`, `LERNAPP_INTAKE_SECRET` (gleich wie auf dem Eingang) |

- Datenbanken: neue Tabelle `intake_days` in `accounts.db` (nur Zähler je Konto und Tag, wird beim ersten Aufruf angelegt).
- Keine bestehende Route ändert sich. Alte Apps rufen die neuen Routen nie auf.
- Eingang: Hetzner CPX12 `ubuntu-2gb-nbg1-1`, privat `10.0.0.3`, Netz `studinow-intern`; läuft seit 18.11. 12:58.

## Ablauf

1. Backup: `ssh … root@46.225.32.3 'bash /srv/uniflow/app/deploy/backup.sh'`
2. Code: `git archive <commit> | ssh … 'tar -x -C /srv/uniflow/app && echo <commit> > /srv/uniflow/app/VERSION-COMMIT'`
3. `.env`: Adresse und Geheimnis setzen (Geheimnis direkt vom Eingang zum Dienst, ohne Anzeige)
4. `cd /srv/uniflow/app/deploy && docker compose up -d --build`, dann `docker compose ps`, Logs, `./dienst-check.sh --no-mail --verbose`
5. Prüfen: `/login` 200; `POST /api/intake/check` ohne Anmeldung 401; aus dem Container `forward(...)` mit leerer Liste → 200

**Zurück:** `git archive fc66fba4 | ssh … 'tar -x -C /srv/uniflow/app'`, die zwei `LERNAPP_INTAKE_*`-Zeilen leeren,
`docker compose up -d --build`. (Die neuen Dateien `app/intake_*.py` bleiben liegen, sind ohne Router aber wirkungslos.)

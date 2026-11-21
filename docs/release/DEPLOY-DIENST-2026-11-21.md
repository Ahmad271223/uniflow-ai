# Dienst-Update 21.11.2026 – ausgerollt 13:41 (Wissensbank)

Stand: `55ac3f3f` (Zweig `release/1.0.7`, Merge von `server/wissensbank`). Auf dem Server lief vorher `2a238f0f`.
Ausgerollt auf Freigabe des Inhabers vom 21.11.2026 im Chat („Ja, Server-Update“ auf die Frage, ob der Server auf den
neuen Stand gebracht und die Wissensbank dort eingeschaltet werden darf). Anlass: Der Inhaber will die Wissensbank
selbst am iPad testen (Testfassung per Kabel, Build 46 noch nicht hochgeladen).

## Was sich im Dienst-Code ändert (`2a238f0f` → `55ac3f3f`)

| Datei | Was |
|---|---|
| `app/wissensbank.py`, `app/wissensbank_pruefen.py` | neu: StudiNow-Wissensbank (nur LUH, Pro AI), Prüf-Werkzeug |
| `app/ai_relay.py` | KI-Hilfe fragt zuerst die Wissensbank (nur wenn die App Angaben zur Stelle schickt) |
| `app/billing_api.py`, `app/credits.py` | Feld `wissensbank` in den Berechtigungen, Zweck `tutor:wissensbank` (1 Credit) |
| `app/account_export.py`, `app/accounts.py` | Export und Löschen umfassen die neuen Tabellen |
| `app/server.py` | Router eingebunden |
| `deploy/.env.example`, `tools/wissensbank-hochladen.sh` | Schalter, Upload-Skript |

- Datenbank: neue Tabellen `wissensbank_*` in `accounts.db` (werden beim ersten Zugriff angelegt).
- `deploy/.env` auf dem Server: `LERNAPP_WISSENSBANK=1` ergänzt (Kopie des Stands davor:
  `.env.vor-wissensbank-2026-11-21`). Aktiv ist die Wissensbank erst, wenn `katalog.json` in `/data/wissensbank` liegt
  (Upload durch den Inhaber mit `tools/wissensbank-hochladen.sh`).
- Wirkung für die App im Store (1.0.6, Build 45): keine. Sie schickt keine Angaben zur Stelle (`wissensbank` in der
  Anfrage); Antworten aus der Wissensbank bekommt nur eine App mit dem Stand von 1.0.7.

## Tests (auf `55ac3f3f`)

- Python voll: **4007 bestanden**, 4 übersprungen, 2 erwartet rot, 0 Fehler (7:12 min).
- App im Simulator (Auswahl): `WissensbankAppTests`, `CreditsDisplayAppTests`, `PageExplainAppTests`,
  `UndoStrokesAppTests`, `EditorDeviceFixesTests`: 38 Tests, 0 Fehler. Auf dem Zweig `server/wissensbank` davor: 25
  Klassen der KI-Hilfe, 180 Tests, 0 Fehler; Swift-Kern 1770 Tests, 0 Fehler (Stand `a4640600`).
- Der volle App-Lauf für Build 46 steht noch aus.

## Ablauf

1. Backup: `uniflow-2026-11-21_1334.tar.gz` (190 MB, 25 Datenbanken).
2. Code übertragen und neu gebaut (`git archive 55ac3f3f | ssh … 'tar -x -C /srv/uniflow/app && cd … && docker compose up -d --build'`).
3. Geprüft: `uniflow-app` und `uniflow-jobs` healthy, `dienst-check.sh --no-mail --verbose`: alle Prüfungen bestanden.
4. Schalter gesetzt, Dienst neu gestartet: „Schalter True, aktiv False“ (Bibliothek noch nicht hochgeladen).
5. **Zurück, falls etwas nicht geht:** Schalter in `deploy/.env` auf 0 und `docker compose up -d`; ganz zurück:
   Schritt 2 mit `2a238f0f`.
6. Bibliothek hochgeladen (14:00, `tools/wissensbank-hochladen.sh`, auf Wunsch des Inhabers „Mach du das“ von der
   Hauptsitzung ausgeführt): 2 266 Dateien im Volume; Prüfung im Container: „Stand 2026-11-20: 29 Fächer, 1065
   Einheiten, 26571 Abschnitte, davon 12788 mit Folien-/Aufgabentext. Schalter an.“ Danach „Schalter True, aktiv True“.

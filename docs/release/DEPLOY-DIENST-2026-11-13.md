# Dienst-Update 13.11.2026 – ausgerollt 11:07

Zweig `deploy/dienst-2026-11-13` (Worktree `~/Studora-Builds/wt-deploy`) = `develop` (f0964d1f) + Zweig
`community/test-last-windows` (bis 3bb9b9d9) + Cache-Nummern vereinheitlicht (52c0d3b9). `develop` selbst ist nicht
verändert. Ausrollen nur mit Freigabe des Inhabers.

## Warum jetzt

- Die Website (seit 13.11. 09:47 live) beschreibt „Konto löschen“ im Web und unter Windows und das Mitkündigen eines
  Karten-Abos. Beides läuft erst nach diesem Update.
- Version 1.0.3 (Build 35) ist bei Apple in der Prüfung und erwartet laut `BUILD-HERKUNFT.md` (Build 34/35) den neuen
  Dienst: eine Apple-Anmeldung für alles und Widerruf bei Apple beim Löschen. Apple prüft „Konto löschen“ regelmäßig.

## Was mit diesem Update auf den Server kommt

Letzter bekannter Stand auf dem Server: `cc5f2c89` (10.11. abends, vom Inhaber ausgerollt; ohne Lesezugriff auf den
Server nicht nachgeprüft). Seitdem im Dienst-Code (`app/`, ohne Merges):

| Bereich | Was |
|---|---|
| Konten | Eine Apple-Anmeldung für alles, Widerruf bei Apple beim Löschen (braucht den Apple-Schlüssel, siehe unten), Datentrennung bei anderem Stud.IP-Benutzer |
| Konto löschen | im Web (Kontofenster) und in der Windows-App; ein Karten-Abo (Stripe) endet dabei sofort |
| Community | 4 Fehler behoben (gesperrte Nutzer, doppeltes Melden, Kommentar als Zahl, Bearbeiten nach Sperre); Feed 124 → 8 Datenbankabfragen |
| Smart Planner 2.0 | Lernziele (`/api/goals`, `/api/sessions`), im Web und unter Windows mit eigener Ansicht |
| Module | eigene Wochen je Modul |
| QIS, Studienverlauf | Noten nur aus QIS, echter LUH-Notenspiegel, angemeldete Prüfungen, Bescheinigungen, Studienverlauf höhere Semester |
| Erinnerungen | an Abgaben und Klausuren erst ab Plus |
| Dokumente | Import in jeden Ordner |
| KI-Hinweis | kurz, Knopf „Okay, los“ |

Datenbanken: nur ergänzende Änderungen (neue Tabellen und Spalten legt der Dienst beim Start selbst an), nichts wird
gelöscht oder umgebaut.

## Einstellungen (`deploy/.env` auf dem Server)

Neu und optional, nur für den Widerruf bei Apple beim Löschen (ohne sie geht das Löschen trotzdem, das Protokoll sagt,
dass nicht widerrufen wurde):

```
LERNAPP_APPLE_TEAM_ID=78MQGF36BD
LERNAPP_APPLE_SIGNIN_KEY_ID=<Key-ID aus Apple Developer → Keys → „Sign in with Apple“>
LERNAPP_APPLE_SIGNIN_KEY_FILE=<Pfad der .p8-Datei im Container>
```

Den Schlüssel legt nur der Inhaber im Apple-Developer-Konto an (einmal herunterladbar). Stripe ist nicht eingerichtet;
das Mitkündigen greift erst, wenn es Karten-Abos gibt.

## Tests auf diesem Stand (13.11.2026)

- Python (`.venv/bin/python -m pytest`): **3.483 bestanden**, 5 übersprungen, 2 erwartet rot, keiner rot
- Browser-Logik (`node --test tests/js/`): **450 / 450** (neu: einheitliche Cache-Nummern)
- Swift-Kern: unverändert gegenüber `develop` (dort zuletzt 1.496 / 0 Fehler)
- Nicht geprüft: Python 3.12 im Server-Image (lokal 3.13, kein 3.12 auf dem Mac; der Bau in Schritt 2 startet den
  Dienst mit 3.12 – Schritt 3 zeigt, ob er läuft); ein echter Lauf gegen den Server.

## Ablauf (auf dem Mac, im Ordner `~/Studora-Builds/wt-deploy`)

1. **Backup auf dem Server** (Abschnitt 9 in `BETRIEB.md`):
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 '/srv/uniflow/app/deploy/backup.sh'`
2. **Code übertragen und neu bauen** (der Server ist kein Git-Ordner; `deploy/.env` und die Daten bleiben):
   `git archive HEAD | ssh -i ~/.ssh/studinow_server root@46.225.32.3 'tar -x -C /srv/uniflow/app && cd /srv/uniflow/app/deploy && docker compose up -d --build'`
3. **Prüfen:**
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'cd /srv/uniflow/app/deploy && docker compose ps && docker compose logs --tail=50 app && ./dienst-check.sh --no-mail --verbose'`
   dazu im Browser: `https://app.studinow.app` anmelden, Lernkalender → Lernziele, Kontofenster zeigt „Konto löschen“
   (nicht ausführen), Community öffnen.
4. **Zurück, falls etwas nicht geht:** denselben Schritt 2 mit dem alten Stand: `git archive cc5f2c89 | ssh …`
   (die neuen Spalten stören den alten Code nicht).

Danach: Zweig `deploy/dienst-2026-11-13` in `develop` mischen (oder `develop` neu ausrollen, sobald er beides enthält),
damit Server und `develop` wieder gleich sind.

## Ergebnis

Ausgerollt am 13.11.2026 um 11:07 (Berlin) auf Bitte des Inhabers („starte du bitte“), Stand `21ecc168`:

- Vorher lief nachweislich `cc5f2c89` (Dateien `server.py`, `accounts.py`, `community.py` gleich).
- Backup vorher: `/srv/uniflow/backups/uniflow-2026-11-13_1106.tar.gz` (8,2 MB, 15 Datenbanken).
  Hinweis: `backup.sh` ist auf dem Server nicht ausführbar markiert, Aufruf mit `bash …/backup.sh`.
- Bau und Start ohne Fehler, `app` und `jobs` „healthy“, Python 3.12.16 im Container.
- `dienst-check.sh`: alle Prüfungen bestanden (Container, Platte 3 %, RAM 10 %, Zertifikat 82 Tage, Jobs, Löschlauf,
  Backup, Kopie außer Haus, `/login` 200).
- Von außen: `account-delete.js`, `views-goals.js`, `goals-logic.js` 200; `app.js` enthält „Konto löschen“;
  `/api/goals` und Community-Fragen 401 (Route da, Anmeldung nötig); `/api/billing/plans` 200.
- Nicht geprüft: Abläufe mit einem echten Konto (Anmelden, Lernziele anlegen, Konto löschen).
- Apple-Schlüssel für den Widerruf beim Löschen ist noch nicht eingetragen (`LERNAPP_APPLE_*` leer).
- `develop` ist seitdem weiter (`119b2e9f`, KI-Erklärungen einfacher, `app/ai.py`, `app/doc_explain.py`) und noch
  nicht auf dem Server. Zusammenführen mit diesem Zweig geht ohne Konflikt (Probe-Merge 13.11.).

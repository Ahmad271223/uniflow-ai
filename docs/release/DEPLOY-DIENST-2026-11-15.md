# Dienst-Update 15.11.2026 – ausgerollt 01:17

Stand: `fc66fba4` (Zweig `release/b42-kandidat`, Tag `ios-1.0.4-b42`) – derselbe Commit wie Build 42. Auf dem Server lief
seit 14.11.2026 19:55 `6923136b` (siehe `DEPLOY-DIENST-2026-11-14.md`). Ausrollen nur mit Freigabe des Inhabers.

## Warum

Am echten iPhone (14.11.2026 abends, Build 41) lief die Zeitachse des neuen Wochenrasters bis 26 Uhr: alte Lernpakete
hatten ein Ende wie „25:15“. Die Einreichung von 1.0.4 mit Build 41 wurde darum am 14.11.2026 um 21:54 zurückgezogen.
Build 42 behebt den Fehler in der App; der Dienst plant dieselben Lernpakete für PC, Web und den Abgleich und braucht
dieselbe Regel, sonst entstehen dort weiter Uhrzeiten nach Mitternacht.

## Was sich im Dienst-Code ändert (`6923136b` → `fc66fba4`)

| Datei | Was |
|---|---|
| `app/study.py` | Lernpaket-Zeiten: nie nach der Lernzeit und nie nach 24:00. Was an einem Tag in kein Fenster passt, bekommt keine Uhrzeit mehr „hinter dem letzten Block“; bei der automatischen Planung kommt es auf den nächsten Lerntag (ein ganzes Paket wird verlegt, ein Rest wird ein eigenes Paket). `repair_times` repariert den Altbestand (Ende „25:15“, Ende vor Beginn) |

- Nur diese eine Datei; `deploy/` und die Abhängigkeiten sind unverändert. `deploy/.env`: nichts Neues.
- Datenbanken: keine neue Tabelle, keine neue Spalte.
- Reparatur des Altbestands: läuft mit jedem Lernkalender und jeder Planung. Automatisch erzeugte, unberührte Pakete ab
  heute werden neu eingeplant; alle anderen (von Hand geändert, begonnen, erledigt, vergangen) werden nur gekappt (Ende
  höchstens 24:00). Gelöscht wird nichts.

## Tests (auf `fc66fba4`)

- Python: **3.564 bestanden** (1 bekannter wackeliger Test, `test_modules_race`, einzeln grün)
- Browser-Logik (`node --test tests/js/`): **456 / 456**
- Swift-Kern **1.565**, iPad-App **1.802** und iPhone **139** Tests ohne Fehler (Build 42)

## Ablauf (auf dem Mac, im Projektordner `~/uniflow-ai`)

1. **Backup auf dem Server**:
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'bash /srv/uniflow/app/deploy/backup.sh'`
2. **Code übertragen und neu bauen** (der Server ist kein Git-Ordner; `deploy/.env` und die Daten bleiben):
   `git archive fc66fba4 | ssh -i ~/.ssh/studinow_server root@46.225.32.3 'tar -x -C /srv/uniflow/app && cd /srv/uniflow/app/deploy && docker compose up -d --build'`
3. **Prüfen:**
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'cd /srv/uniflow/app/deploy && docker compose ps && docker compose logs --tail=50 app && ./dienst-check.sh --no-mail --verbose'`
   Danach im Lernkalender (Web oder App): kein Lernpaket endet nach 24:00, keines liegt nach der Lernzeit.
4. **Zurück, falls etwas nicht geht:** Schritt 2 mit dem alten Stand: `git archive 6923136b | ssh …`

## Ergebnis

Ausgerollt am 15.11.2026 um 01:17 (Berlin) auf Freigabe des Inhabers vom 14.11.2026 abends („Ja, beides“: Server-Update
und Einreichung von Build 42). Ausgerollt wurde `fc66fba4`, derselbe Commit wie Build 42.

- Backup vorher: `/srv/uniflow/backups/uniflow-2026-11-15_0115.tar.gz` (114 MB, 17 Datenbanken)
- Bau und Start ohne Fehler, `app` und `jobs` „healthy“
- `dienst-check.sh`: alle Prüfungen bestanden
- Von außen: `/login` 200, `/api/billing/plans` 200
- Zurück: `git archive 6923136b | ssh …` wie oben
- Danach: Build 42 am 15.11.2026 um 10:11 zu TestFlight, Version 1.0.4 um 10:13 neu zur Prüfung eingereicht
  (`docs/release/BUILD-HERKUNFT.md`)

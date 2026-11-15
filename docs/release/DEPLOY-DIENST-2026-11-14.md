# Dienst-Update 14.11.2026 – ausgerollt 19:55

Stand: `6923136b` (Zweig `release/b41-kandidat`, Tag `ios-1.0.4-b41`) – derselbe Commit wie Build 41. Auf dem Server lief
seit 13.11.2026 16:32 `d0d178b6` (siehe `DEPLOY-DIENST-2026-11-13-2.md`). Ausrollen nur mit Freigabe des Inhabers.

## Warum

Build 41 (Version 1.0.4, am 14.11.2026 um 19:56 zur Prüfung eingereicht) braucht den neuen Dienst für die
**Geräte-Regel**: StudiNow Free gilt für ein Gerät, Plus bekommt auf dem zweiten Gerät einen Hinweis. Ohne das Update
fehlt in den Antworten des Dienstes das Feld `device`, und die App zeigt den Hinweis nie. So steht die Regel in der
Beschreibung, im Text „Neue Funktionen“ und in den Prüfhinweisen (Abschnitt „Devices“, `docs/release/APP-STORE.md`);
darum kam das Update vor der Einreichung.

Dazu am PC und im Web: Studienverlauf für die Universität Hildesheim (Studiengang selbst wählen, früheres Studium
getrennt) und der Haken „erledigt“ je Datei im Abgleich zwischen den Geräten.

## Was sich im Dienst-Code ändert (`d0d178b6` → `6923136b`)

| Datei | Was |
|---|---|
| `app/device_limit.py` (neu) | Geräte-Regel: Free gilt für ein Gerät (`blocked` auf dem zweiten), Plus-Hinweis (`hint_plus`), Pro AI und laufende Probe ohne Einschränkung; nur für Apps mit der Kopfzeile `X-StudiNow-Caps: device_limit`; Web und Windows zählen nicht als Gerät |
| `app/account_api.py` | Feld `device` bei Anmeldung und Konto-Abfrage; neue Route `POST /api/account/device/primary` („Dieses Gerät stattdessen nutzen“), nur für Apple-Apps mit der Fähigkeit |
| `app/accounts.py` | Spalten `primary_device_id`, `primary_device_name`, `primary_device_set_at` an `users`; die Migration läuft nur, wenn es die Tabelle `users` gibt; „Konto löschen“ leert das Hauptgerät |
| `app/account_export.py` | Datenauskunft nennt das Hauptgerät |
| `app/billing_api.py` | `GET /api/entitlements` liefert mit der Kopfzeile zusätzlich `device` |
| `app/db.py`, `app/server.py`, `app/study.py`, `app/sync_client.py` | Haken „erledigt“ je Datei im Geräte-Abgleich (Einträge `file_done:<Datei-ID>` in den Einstellungen, Auslöser `trg_file_done_*`), offene Lernaufgaben ziehen mit; abgewählte Fächer werden dabei nicht wieder eingeplant |
| `app/study_plan.py`, `app/study_catalog.py`, `app/study_catalog_hildesheim.py` (neu), `app/catalog_formats/hildesheim.py` | Hildesheim: Studiengang selbst wählen (auch Begleitfach), früheres Studium getrennt, Suche nach Wörtern und Kurzformen, LSF-Link, neuer Leser für „Studienordnung inklusive Modulhandbuch“ |
| `app/static/app.js`, `app/static/study-plan.js`, `app/static/study-plan-logic.js` | Studienverlauf im Web dazu |

- Abwärtsverträglich: ältere Apps (1.0.3, Builds 36 bis 40), die Web-Oberfläche und die Windows-App schicken die
  Kopfzeile nicht; ihre Antworten bleiben wie vorher (kein Feld `device`), und sie werden nie Hauptgerät.
- Der Dienst sperrt keine Daten-Anfragen: `blocked` ist eine Auskunft für die App. Konto, Abo und Abmelden bleiben in
  jedem Zustand erreichbar.
- Datenbanken: in `/data/accounts.db` drei neue Spalten an `users` (oben); in den Datenbanken der Konten die Auslöser
  `trg_file_done_*` und Einträge `file_done:<Datei-ID>` für schon erledigte Dateien. Keine neue Tabelle, nichts wird
  gelöscht.
- `deploy/` und die Abhängigkeiten: keine Änderung. `deploy/.env`: nichts Neues.

## Tests (14.11.2026, auf `6923136b`)

- Python: **3.557 bestanden** (1 bekannter wackeliger Test, `test_modules_race`, einzeln grün)
- Browser-Logik (`node --test tests/js/`): **456 / 456**
- Swift-Kern **1.564**, iPad-App **1.794** und iPhone **134** Tests ohne Fehler (Build 41)
- Nicht geprüft: die Geräte-Regel mit einem echten Konto auf zwei echten Geräten und mit einem echten Kauf.

## Ablauf (auf dem Mac, im Projektordner `~/uniflow-ai`)

1. **Backup auf dem Server**:
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'bash /srv/uniflow/app/deploy/backup.sh'`
2. **Code übertragen und neu bauen** (der Server ist kein Git-Ordner; `deploy/.env` und die Daten bleiben):
   `git archive 6923136b | ssh -i ~/.ssh/studinow_server root@46.225.32.3 'tar -x -C /srv/uniflow/app && cd /srv/uniflow/app/deploy && docker compose up -d --build'`
3. **Prüfen:**
   `ssh -i ~/.ssh/studinow_server root@46.225.32.3 'cd /srv/uniflow/app/deploy && docker compose ps && docker compose logs --tail=50 app && ./dienst-check.sh --no-mail --verbose'`
   Danach mit Build 41:
   - mit einem Free-Konto auf einem zweiten Gerät anmelden: Hinweis „StudiNow Free gilt für ein Gerät“ mit „Pro AI
     ansehen“, „Dieses Gerät stattdessen nutzen“ und „Abmelden“;
   - „Dieses Gerät stattdessen nutzen“ antippen: dieses Gerät läuft, das andere zeigt den Hinweis beim nächsten Kontakt;
   - mit Plus auf dem zweiten Gerät: einmaliger Hinweis, die App läuft weiter.
4. **Zurück, falls etwas nicht geht:** Schritt 2 mit dem alten Stand: `git archive d0d178b6 | ssh …`

## Ergebnis

Ausgerollt am 14.11.2026 um 19:55 (Berlin) auf Freigabe des Inhabers im Chat („Ja, beides“: Server-Update und
Einreichung von 1.0.4). Ausgerollt wurde `6923136b`, derselbe Commit wie Build 41.

- Backup vorher: `/srv/uniflow/backups/uniflow-2026-11-14_1952.tar.gz` (114 MB, 17 Datenbanken, 2 weitere Dateien)
- Bau und Start ohne Fehler, `app` und `jobs` „healthy“
- `dienst-check.sh`: alle Prüfungen bestanden
- Von außen: `/login` 200, `/api/billing/plans` 200; `POST /api/account/device/primary` ohne Anmeldung 401 (die Route
  ist da)
- `/data/accounts.db`: die Spalten `primary_device_id`, `primary_device_name`, `primary_device_set_at` sind angelegt;
  14 Konten, 0 mit Hauptgerät
- Nicht geprüft: die Geräte-Regel mit einem echten Konto auf zwei echten Geräten und mit einem echten Kauf
- Zurück: `git archive d0d178b6 | ssh …` wie oben; der alte Stand verträgt die neuen Spalten
- Danach: Version 1.0.4 mit Build 41 um 19:56 zur Prüfung eingereicht (`docs/release/BUILD-HERKUNFT.md`)
- Nachtrag 15.11.2026: Die Einreichung mit Build 41 wurde am 14.11.2026 um 21:54 zurückgezogen; der Server läuft seit
  15.11.2026 01:17 auf `fc66fba4` (`DEPLOY-DIENST-2026-11-15.md`), 1.0.4 ist mit Build 42 neu eingereicht

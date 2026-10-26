# Verträge G1 (UniFlow-Konto) und G2 (Geräte-Synchronisierung) – Python-Referenz, Stand 26.10.2026

Beide Verträge sind in Python umgesetzt und mit Fixtures festgehalten; Swift (iPad/Mac) und Kotlin (Android) bauen
ihre Clients danach und prüfen gegen dieselben Dateien:

- G1: `packages/shared-contracts/fixtures/account/contract.json` (Regeln, Prüf-Fälle, alle Endpunkte mit
  Beispiel-Anfrage und -Antwort, Fehlercodes, kompletter Ablauf). Referenz `app/accounts.py`, `app/account_api.py`,
  erzeugt mit `tools/gen-account-fixture.py`.
- G2: `packages/shared-contracts/fixtures/sync/cases.json` (Regeln, fünf Fälle mit Push-Eingaben und erwarteten
  Antworten). Referenz `app/sync.py`, erzeugt mit `tools/gen-sync-fixture.py`.
- Dazu umgesetzt: G5 Download-Reihenfolge (`studip_sync.store_course_files`, `tests/test_rules_g5_g6.py`) und G6
  „kein Erfolg ohne Wirkung“ (404 statt `ok`/`null` bei unbekannter ID, 501 mit Grund für nicht verfügbare Pfade).

## Betriebsarten

| | `LERNAPP_MODE=local` (Standard) | `LERNAPP_MODE=hosted` |
| --- | --- | --- |
| Nutzer | eine Person am eigenen PC | viele Konten (`accounts.db` neben den Nutzerordnern) |
| Zugang | PC frei, WLAN mit PIN | jede `/api`-Anfrage mit Sitzung (Bearer-Token oder Cookie), sonst 401 |
| Daten | `data/` bzw. `data/unis/<key>` | `data/users/<UniFlow-ID>/` (LUH) bzw. `.../unis/<key>`, eigene SQLite je Konto |
| Hochschule | `UNIVERSITY` in der `.env` | am Konto (`POST /api/account/university`); `PUT /api/settings {university}` → 400 `use_account` |
| Hochschul-Abgleich, Zugangsdaten | `.env`, Hintergrundlauf des PCs | je Konto: Tresor + Dienst-Jobs (Abschnitt „Abgleich je Konto“) |
| WLAN-Zugang, KI | wie bisher | 501 `not_available_hosted` mit Grund (KI mit dem KI-Update) |

Die Trennung je Konto ist strukturell: jedes Konto hat eine eigene Datenbankdatei und einen eigenen Dateiordner
(`config.data_dir()` aus dem Nutzerkontext der Anfrage). Es gibt keine Abfrage, die eine `user_id` vergessen könnte.
`tests/test_accounts.py::test_users_are_isolated_in_their_own_databases` prüft über alle GET-Pfade, dass Nutzer B
nichts von Nutzer A sieht und auf dessen IDs 404 bekommt; `test_hosted_requires_session_on_every_api_path` prüft 401
auf jedem Pfad ohne Sitzung.

### Betrieb (gehostet)

```
LERNAPP_MODE=hosted
LERNAPP_DATA_DIR=/srv/uniflow/data          # accounts.db, users/<id>/..., users-deleted/
LERNAPP_ALLOWED_HOSTS=app.example.de        # Host-Kopfzeile (Schutz gegen DNS-Rebinding)
LERNAPP_HTTPS=1                             # Sitzungs-Cookie nur über https (Secure)
```

HTTPS kommt von einem Reverse-Proxy (nginx/Caddy) vor uvicorn; der Proxy setzt `Host` durch und beendet TLS. Die
Herkunftsprüfung (`same_origin_guard`) bleibt aktiv: Änderungen aus dem Browser nur mit `Origin` = `Host`; native Apps
senden kein `Origin`. Betriebsbefehle: `python -m app.accounts list`, `reset-token <email>` (Reset-Token, solange
kein Mailversand eingerichtet ist; `accounts.reset_sender` nimmt eine Versandfunktion), `purge` (Konten, die seit
30 Tagen gelöscht sind, endgültig entfernen; per Cron täglich).

## Abgleich je Konto (gehostet)

- **Tresor** (`app/vault.py`): die Hochschul-Zugangsdaten eines Kontos liegen als einzelne Werte wie in der `.env`
  (`STUDIP_USER`, `STUDIP_PASSWORD`, `HILDESHEIM_USER`, `HILDESHEIM_PASSWORD`, `QIS_SAME_AS`, `LEARNWEB_TOKEN`, …)
  in `accounts.db`, jeder Wert mit AES-256-GCM verschlüsselt. Schlüssel je Konto per HKDF-SHA256 aus dem
  Dienst-Geheimnis `LERNAPP_SECRET_KEY` (32 Byte, base64 oder hex); ohne Angabe erzeugt der Dienst beim ersten Start
  `secret.key` neben den Nutzerordnern. Die Konto-ID ist als AAD gebunden. Geheimnis und Datenbank getrennt
  aufbewahren: ein Datenbank-Abzug allein gibt nichts preis. Warum kein Schlüssel aus dem Nutzerpasswort: der Abgleich
  läuft zweimal täglich ohne den Nutzer. Löschen der Zugangsdaten (`clear`) beendet den automatischen Abgleich.
- **Gleicher Code wie am PC**: `config.credentials()`, `own_credentials()`, `secret()`, `set_env()` lesen und
  schreiben im Dienst den Tresor des Kontos der Anfrage bzw. des Jobs (`config.set_env_context`), nie die `.env`.
  Browser-Profile, Protokolle und QIS-Dokumente liegen unter `users/<id>/…` (`studip_sync._profile_dir`,
  `hildesheim._profile_dir`, `qis._doc_dir`, `config.log_dir`).
- **Jobs** (`app/jobs.py`): Tabelle `sync_jobs` in `accounts.db` (`queued | running | done | failed`), Arbeiter holen
  Jobs atomar ab, höchstens ein laufender Job je Konto, ein Job setzt den Kontext des Kontos und ruft
  `studip_sync.run_sync()` (LUH: Stud.IP, Hildesheim: Learnweb + LSF) oder `qis.run()`. Zeitplan
  `LERNAPP_SYNC_TIMES` (Standard `08:00,15:00`, Ortszeit des Servers): je Uhrzeit einmal am Tag ein Job für jedes
  aktive Konto mit Zugangsdaten, auch nach Neustart nur einmal (`schedule_marks`). Beim Start werden verwaiste
  „laufende“ Jobs (älter als 6 h) als abgebrochen markiert.
- **Betrieb**: im API-Prozess (`LERNAPP_JOBS=inproc`, Standard) oder getrennt `python -m app.jobs` mit
  `LERNAPP_JOBS=off` für die API. `LERNAPP_JOB_WORKERS` (Standard 2) = gleichzeitige Browser, je etwa 300 MB; Playwright
  mit Chromium muss auf dem Server installiert sein (`playwright install chromium`).
- **Endpunkte** (je Konto): `GET/PUT /api/credentials` (LUH-ID), `PUT /api/credentials/{service}` (Hildesheim,
  QIS, `clear`, `same_as`), `PUT /api/learnweb/token`, `POST /api/sync` → `{started, job_id, status, already}` oder
  400 `credentials_missing`, `POST /api/grades/sync` ebenso, `GET /api/sync/status` → `{bg, log, jobs}`, `GET /api/bg`
  → `{running, task, message, job}`. Die Web-Oberfläche braucht dafür keine Änderung (gleiche Form wie am PC).

## G1 Konto

- **Identität:** UniFlow-ID (32 Hex-Zeichen). E-Mail + Passwort (mind. 10, höchstens 200 Zeichen, nicht die
  E-Mail), scrypt-Hash (n=2^14, r=8, p=1, 16-Byte-Salz). „Mit Apple/Google anmelden“ verknüpft die
  Anbieter-Kennung (`subject`) mit der UniFlow-ID (`identities`); ein neues Konto darüber nimmt die gelieferte
  E-Mail (Relay-Adressen erlaubt) und braucht die Hochschule. Ohne eingerichteten Prüfer der Signatur antwortet der
  Server 501 `provider_not_configured`; es wird nie ein ungeprüftes Token angenommen. Prüfer einhängen:
  `accounts.identity_verifiers["apple"] = fn(identity_token) -> {"subject", "email"}` (Apple: Team-ID/Bundle-ID,
  JWKS von appleid.apple.com; Google: Client-ID) – braucht die Daten des Inhabers.
- **Sitzungen:** Token 32 Byte (urlsafe), gespeichert als SHA-256; 30 Tage gleitend; `logout`, `logout-all` (andere
  Geräte), Liste unter `/me`. Browser: Cookie `uniflow_session` (HttpOnly, SameSite=Lax, Secure bei HTTPS). Apps:
  `Authorization: Bearer <token>`.
- **Fehlversuche:** 8 je Konto und je Adresse → 10 Minuten `locked` (429), gezählt in der Datenbank.
- **Reset:** Token 30 Minuten, einmalig, beendet alle Sitzungen; die Antwort auf `reset-request` ist immer gleich.
- **Löschen:** sofort gesperrt (alle Sitzungen weg, Adresse frei), Nutzerordner nach `users-deleted/`, endgültig nach
  30 Tagen (`purge`). Mit Passwort, bei reinen Apple/Google-Konten ohne.
- **Fehlerform:** `{"detail": "<Meldung>", "code": "<stabil>"}`; Codes in `contract.json` → `errors`.
- **Endpunkte:** `POST register`, `login`, `login/{apple|google}`, `link/{apple|google}`, `logout`, `logout-all`,
  `password`, `password/reset-request`, `password/reset`, `university`, `delete`; `GET me`, `GET info` (öffentlich).

## G2 Synchronisierung

- **Spalten** an jeder synchronisierten Tabelle: `sync_version` (zählt je Änderung hoch), `sync_updated_at` (UTC,
  `YYYY-MM-DDTHH:MM:SS.mmmZ`), `sync_device` (Gerät der letzten Änderung, NULL = Server/Web). **SQLite-Trigger** pflegen
  sie bei INSERT (Zeitstempel, wenn keiner mitkommt), UPDATE (Version +1, Zeitstempel, Gerät NULL – nur wenn die
  Anweisung Version und Zeitstempel nicht selbst setzt) und DELETE (Zeile in `sync_tombstones(entity, entity_id,
  deleted_at, device)`). Dadurch bleiben alle Schreibpfade der App unverändert. **Der Swift- und der Kotlin-Kern
  brauchen dieselben Spalten und Trigger** in ihrer lokalen Datenbank (`SchemaSQL.swift` ist neu erzeugt, die
  Trigger stehen in `app/sync.py::ensure_schema`).
- **Entitäten** (Reihenfolge = Eltern vor Kindern): `modules`, `folders`, `course_events`, `event_exceptions`,
  `study_packages`, `study_tasks`, `flashcards`, `settings` (Schlüssel `key`; nie `lan_pin`, `university`),
  `annotations` (Schlüssel `file_id`). Eigene Dokumente mit Inhalt (Notizbücher, importierte PDFs) folgen später;
  Hochschul-PDFs lädt jedes Gerät selbst (`files`, `courses` nicht im Sync).
- **Abruf:** `GET /api/sync/changes?since=<cursor>` → `{cursor, changes: {entity: [Zeilen inkl. sync_*]}, tombstones}`.
  Ohne `since` alles. Der Cursor ist der größte gesehene Zeitstempel; Clients entfernen Doppelte über Version.
- **Senden:** `POST /api/sync/push {device_id, items: [{entity, id | local_id, base_version, updated_at, data}],
  deletes: [{entity, id, deleted_at}]}` → `{results, mapping, conflicts, server_time}`.
  - neue Zeile: `id` weglassen, `local_id` negativ → `created` mit Server-ID in `mapping`; Fremdschlüssel mit
    negativen IDs (`module_id`, `package_id`, `event_id`, `folder_id`, `parent_id`) werden im selben Push aufgelöst.
  - `base_version` = Serverversion → `applied`. Sonst `conflict`: je Feld gewinnt der spätere Schreiber (`updated_at`
    des Clients gegen `sync_updated_at` des Servers), `client_won` nennt die Felder, `conflicts` beide Stände.
  - Löschen: `deleted_at` ≥ letzte Serveränderung → `deleted` (Tombstone), sonst `edit_wins` (Zeile bleibt).
    Eine Änderung mit `updated_at` nach dem Tombstone → `resurrected`.
  - `annotations`: wie `PUT /api/files/{id}/annotations` – `base_version` muss stimmen, sonst `conflict` mit
    `data`/`version`; der Client führt mit den Regeln aus `fixtures/merge/cases.json` zusammen und sendet erneut.
    Unbekannte Datei → `unknown_file`.
  - `settings`: `local_id` = Schlüssel, `data.value`; private Schlüssel → `ignored`.
- Beide Endpunkte gibt es auch im Einzelplatzmodus (iPad ↔ PC im WLAN); im Dienst gelten sie je Konto.

## Noch offen (nächste Schritte der PC-Sitzung)

- Mailversand für Reset und E-Mail-Bestätigung (`email_verified`).
- Apple-/Google-Signaturprüfung, sobald Team-ID/Client-ID vorliegen.
- Web-Oberfläche: Anmeldeseite für den gehosteten Modus (heute nur API; der PC-Modus braucht keine).
- Sync für eigene Dokumente mit Inhalt; Abo-Prüfung serverseitig (StoreKit/Play) am Konto.

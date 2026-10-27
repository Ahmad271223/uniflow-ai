# Verträge G1 (UniFlow-Konto), G2 (Geräte-Synchronisierung) und G4 (Community) – Python-Referenz, Stand 26.10.2026

Die drei Verträge sind in Python umgesetzt und mit Fixtures festgehalten; Swift (iPad/Mac) und Kotlin (Android) bauen
ihre Clients danach und prüfen gegen dieselben Dateien:

- G1: `packages/shared-contracts/fixtures/account/contract.json` (Regeln, Prüf-Fälle, alle Endpunkte mit
  Beispiel-Anfrage und -Antwort, Fehlercodes, kompletter Ablauf). Referenz `app/accounts.py`, `app/account_api.py`,
  erzeugt mit `tools/gen-account-fixture.py`.
- G2: `packages/shared-contracts/fixtures/sync/cases.json` (Regeln, fünf Fälle mit Push-Eingaben und erwarteten
  Antworten). Referenz `app/sync.py`, erzeugt mit `tools/gen-sync-fixture.py`.
- G4: `packages/shared-contracts/fixtures/community/contract.json` (Regeln, Paket-Prüffälle, Fehlercodes, kompletter
  Ablauf mit Anfrage und Antwort). Referenz `app/community.py`, `app/community_api.py`, erzeugt mit
  `tools/gen-community-fixture.py`; Paketformat in `docs/LOESUNGEN-TEILEN.md`.
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
- **Dateien ohne Speicherung** (`LERNAPP_FILES=stream`, Standard im Dienst; `store` wie am PC): Der Abgleich merkt
  nur die Dateiliste (`files` ohne `local_path`); `GET /api/files/{id}/content` holt die Datei beim Öffnen mit der
  Hochschulsitzung des Kontos (`STUDIP_COOKIES` aus dem Abgleich bzw. `LEARNWEB_TOKEN`, beides im Tresor) und reicht
  sie durch (`app/filestream.py`): nichts auf der Platte, Zwischenspeicher im Arbeitsspeicher (8 Dateien, 256 MB,
  15 min), dabei `content_sha256` und `page_texts` (Suche) abgelegt. Abgelaufene Stud.IP-Sitzung → einmal neu anmelden
  (Playwright, Profil des Kontos), sonst 409 `university_session_expired`; Anmeldung schlägt fehl → 502
  `university_login_failed`; zu groß (300 MB) → 413. `POST /api/files/{id}/fingerprint` → `{sha256, source}` liefert
  den Community-Schlüssel auch für Geräte, die die Datei direkt von der Hochschule laden (iPad). Eigene Dokumente
  (`course_id = __user__`) werden weiter gespeichert – sie sind Inhalt des Nutzers, keine Hochschuldatei.
- **Jobs** (`app/jobs.py`): Tabelle `sync_jobs` in `accounts.db` (`queued | running | done | failed`), Arbeiter holen
  Jobs atomar ab, höchstens ein laufender Job je Konto, ein Job setzt den Kontext des Kontos und ruft
  `studip_sync.run_sync()` (LUH: Stud.IP, Hildesheim: Learnweb + LSF) oder `qis.run()`. Zeitplan
  `LERNAPP_SYNC_TIMES` (Standard `08:00,15:00`, Ortszeit des Servers): je Uhrzeit einmal am Tag ein Job für jedes
  aktive Konto mit Zugangsdaten, auch nach Neustart nur einmal (`schedule_marks`). Beim Start werden verwaiste
  „laufende“ Jobs (älter als 6 h) als abgebrochen markiert.
- **Löschfristen** (`app/retention.py`, täglich ab `LERNAPP_RETENTION_TIME`, Standard 04:00, im Zeitplan der Jobs):
  eigenes Zugriffsprotokoll `logs/access/access-YYYY-MM-DD.log` (Zeit, IP, Methode, Pfad ohne Abfrageteil, Status,
  Dauer, Browser-Kennung) 14 Tage (`LERNAPP_RETENTION_ACCESS_DAYS`); Abgleich-Protokolle und Fehlerbilder in
  `users/<id>/logs` sowie `sync_log` je Konto 90 Tage (`LERNAPP_RETENTION_SYNC_DAYS`, Logdateien werden zeilenweise
  gekürzt); `sync_jobs`/`schedule_marks` 90 Tage; abgelaufene oder beendete Sitzungen, verbrauchte Reset-Token und
  Fehlversuchszähler täglich; gelöschte Konten nach 30 Tagen (`accounts.purge_deleted`). Ergebnis je Lauf in
  `logs/retention.log`; von Hand `python -m app.retention [--dry-run]`. **uvicorn ohne eigenes Zugriffsprotokoll
  starten** (`--no-access-log`), sonst gilt die Frist dort nicht; Protokolle des Hosters per Vertrag auf 14 Tage.
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
- **Web-Anmeldung** (`app/static/login.html`, `login.js`): `/login` mit Anmelden, Konto anlegen (Hochschule, Passwortregeln
  aus `/api/account/info`), Passwort vergessen (Antwort immer gleich) und neues Passwort über den Link `/login?reset=TOKEN`
  (danach alle Geräte abgemeldet). Nur die öffentlichen Kontopfade, kein Inline-Skript (gleiche CSP wie die App), das
  Token bleibt im HttpOnly-Cookie. Im Dienst leitet `/` ohne Sitzung nach `/login`, `/login` mit Sitzung nach `/`; eine
  abgelaufene Sitzung (401) führt in der App zur Anmeldeseite. Abmelden und „Andere Geräte abmelden“ im Konto-Menü
  hinter dem Avatar. Am PC gibt es die Seite nicht (`/login` → `/`). Tests `tests/test_web_login.py`.
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
    `data`/`version`; der Client führt mit den Regeln aus `fixtures/merge/cases.json` zusammen und sendet erneut
    (`cases` = Seite, `documentCases` = ganzes Dokument mit Seitenreihenfolge, Papierkorb und Wurzelfeldern; Referenz
    `app/static/merge.js::mergeDocument`, Kotlin `AnnotationDocument.mergeDetailed`; beide verschieden umsortiert →
    dieses Gerät gewinnt, `orderConflict` muss der Client anzeigen).
    Unbekannte Datei → `unknown_file`.
  - `settings`: `local_id` = Schlüssel, `data.value`; private Schlüssel → `ignored`.
- Beide Endpunkte gibt es auch im Einzelplatzmodus (iPad ↔ PC im WLAN); im Dienst gelten sie je Konto.

## G4 Community

- **Nur gehostet** und nur mit Tarif Plus (`users.plan = plus`, optional `plan_until`; heute per `python -m
  app.accounts plan <email> plus [bis]`, später aus den Store-Käufen), sonst 403 `plan_required`; im Einzelplatzmodus
  501 `not_hosted`. Sitzung wie bei G1 (Bearer oder Cookie).
- **Berechtigung „Datei aus dem eigenen Hochschul-Abgleich“**: Veröffentlichen, Suchen und Laden nur, wenn in der
  Datenbank des Kontos eine Datei mit `content_sha256 = Fingerabdruck` liegt, die aus dem Abgleich stammt
  (`course_id ≠ __user__`, `download_url` gesetzt, nicht gelöscht); sonst 403 `file_not_owned`. Treffer gibt es nur
  innerhalb derselben Hochschule. Das ersetzt nicht den Beleg der Kursmitgliedschaft durch die Hochschule
  (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 7), beschränkt die Community aber auf Dateien, die das Konto selbst über
  Stud.IP oder Learnweb bekommen hat – wer die PDF nicht hat, kann das Paket ohnehin nicht öffnen.
- **Paket**: der Dienst speichert das Paket `uniflow-solution` Version 1 unverändert
  (`community/<solutionId>.uniflowsolution` neben den Nutzerordnern) und prüft nur Form und Kopf wie
  `SolutionPackage.decode`: genaue Feldmengen, UUID, Datum, `document.sha256` 64 Hex, `pages` 1…2000 (0 = „ohne eigene
  Notizen“), `plaintextBytes` = Chiffrat − 16, Salz 32 B, Nonce 12 B, Grenze rund 65 MB (413 `too_large`); Fehlercodes
  `not_a_solution`, `unsupported_version`, `package_invalid`. Er entschlüsselt nie (Schlüssel aus der Original-PDF).
- **Pseudonym** `Studi-<8 hex>` = HMAC-SHA256(Dienst-Geheimnis, Konto-ID), stabil je Konto; Antworten enthalten nie
  Konto-ID oder E-Mail.
- **Ablage** `community.db` (`solutions`, `reports`, `blocks`, `bans`), Status `active | withdrawn | hidden |
  removed`. Erneutes Veröffentlichen derselben `solutionId` durch den Autor aktualisiert (`republished: true`, Titel
  bleibt ohne neuen), durch ein anderes Konto 409 `solution_exists`; verborgene oder entfernte Lösungen nimmt der
  Dienst nicht erneut an (403 `solution_blocked`). Zurückziehen löscht die Paketdatei; `mine` zeigt sie weiter als
  `withdrawn`.
- **Melden**: Grund aus `foreignMaterial | gradedSubmission | offensive | spam | other`, Notiz bis 500 Zeichen, eine
  Meldung je Konto und Lösung (409 `already_reported`), eigene Lösung 400 `own_solution`; ab 3 Meldungen verschiedener
  Konten `hidden`, bis die Moderation entscheidet. **Sperren** (App-Store-Richtlinie 1.2): `block` blendet alle
  Lösungen des Pseudonyms für dieses Konto aus, `unblock` hebt es auf. **Moderation** (`users.role = admin`,
  `python -m app.accounts role <email> admin`): Warteschlange (gemeldet, verborgen, entfernt – mit Gründen), Aktionen
  `hide | restore | remove | ban_author | unban_author`; `restore` löscht die Meldungen, `remove` und `ban_author`
  löschen die Paketdateien, `ban_author` nimmt alle Lösungen des Autors aus der Suche und verhindert weiteres
  Veröffentlichen (403 `author_banned`).
- **Endpunkte**: `GET /api/community/info` → Regeln, eigenes Pseudonym, `plan_ok`, `admin`; `POST
  /api/community/solutions {package, title?}` → 201 `{solution_id, published_at, pseudonym, republished}`; `GET
  /api/community/solutions?fingerprint=<sha256>` → `{solutions: [Kopfdaten mit pseudonym, mine, reported_by_me,
  downloads]}` (nur `active`, ohne gesperrte und verbannte Autoren); `GET /api/community/solutions/{id}` → `{package,
  solution}` (zählt `downloads`, außer bei der eigenen); `DELETE /api/community/solutions/{id}` → `{withdrawn,
  already}` (403 `not_owner`); `GET /api/community/mine`; `POST …/{id}/report {reason, note}` → `{reported, hidden,
  reports}`; `POST …/{id}/block` → `{blocked}`; `DELETE /api/community/blocks/{pseudonym}`; `GET
  /api/community/blocks`; `GET /api/community/moderation`; `POST …/{id}/moderate {action, reason?}`.
- **Web**: die Seite „Community“ zeigt im Dienst die eigenen Veröffentlichungen (zurückziehen), gesperrte Autoren
  (aufheben) und für Admins die Moderation; am PC erklärt sie, dass die Community nur im Dienst läuft. Veröffentlichen,
  suchen, laden, melden und sperren macht der iPad-Client im Editor (M15).

## Noch offen (nächste Schritte der PC-Sitzung)

- Mailversand für Reset und E-Mail-Bestätigung (`email_verified`).
- Apple-/Google-Signaturprüfung, sobald Team-ID/Client-ID vorliegen.
- Sync für eigene Dokumente mit Inhalt; Abo-Prüfung serverseitig (StoreKit/Play) am Konto (setzt dann `plan`).
- Community: Betrieb und Nutzungsbedingungen (Inhaber), Löschfristen, Beleg der Kursmitgliedschaft durch die Hochschule.

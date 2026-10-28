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
LERNAPP_PUBLIC_URL=https://app.example.de   # Basis aller Links in Mails (Reset-Link, Willkommensmail)

# Mailversand (app/mail.py): off | log | smtp. Ohne Angabe: log am PC und im Dienst ohne SMTP-Host, sonst smtp.
LERNAPP_MAIL=smtp
LERNAPP_SMTP_HOST=smtp.example.de           # ohne Host: Mails landen in logs/mail.log (Modus log)
LERNAPP_SMTP_PORT=587                       # 587 = STARTTLS (Standard), 465 = SSL
LERNAPP_SMTP_USER=postausgang               # leer = ohne Anmeldung
LERNAPP_SMTP_PASSWORD=...
LERNAPP_MAIL_FROM="UniFlow <no-reply@app.example.de>"   # Standard: SMTP-Nutzer bzw. no-reply@<Host der PUBLIC_URL>

# „Mit Google/Apple anmelden“ (app/social_login.py): erlaubte Client-IDs (aud), kommagetrennt; ohne Eintrag ist der
# Anbieter nicht eingerichtet (501 provider_not_configured). Web-Client-ID nur für die Anmeldeseite im Browser.
LERNAPP_GOOGLE_CLIENT_IDS=<android-client-id>,<ios-client-id>
LERNAPP_GOOGLE_WEB_CLIENT_ID=<web-client-id>            # zählt automatisch als erlaubt
LERNAPP_APPLE_CLIENT_IDS=<bundle-id>,<services-id>      # iPad: Bundle-ID; Web: Services-ID
LERNAPP_APPLE_WEB_CLIENT_ID=<services-id>
```

Mails: `send` wirft nie; ein Versandfehler steht in `logs/mail.log` (ohne Token), die API antwortet trotzdem 200. Im
Modus `log` steht die ganze Mail samt Reset-Link in `mail.log` (so lässt sich der Link im Betrieb ohne SMTP holen).
Vorlagen (Deutsch, nur Text): Passwort zurücksetzen (`<PUBLIC_URL>/login?reset=<token>`, 30 Minuten) und Willkommen
nach der Registrierung (nur Information, keine Pflichtbestätigung). Der Server hängt `mail.send_reset` beim Start im
gehosteten Modus als `accounts.reset_sender` ein (`server.wire_hosted_services`, Lifespan). Tests `tests/test_mail.py`.

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
- **Geräte-Abgleich** (Android/iPad laden die Hochschuldatei selbst – eigene Hochschul-Anmeldung in der App, Download
  mit der Sitzung des Geräts – und melden dem Dienst nur abgeleitete Daten, nie die Datei): `GET /api/university/profile`
  → Anmeldeprofil der Hochschule des Kontos (`key`, `name`, `launch_scheme`, `login_url`, `logged_in_check_url`,
  `session_cookie`, `hosts`, `file_host`, `learnweb_base`, `cas_base`; Werte wie `fixtures/learnweb/launch.json` →
  `profiles`, Hildesheim mit `HILDESHEIM_LEARNWEB_URL` des Kontos als Überschreibung, kein Netz-Probing).
  `PUT /api/files/{id}/fingerprint {sha256}` → `{sha256, source: geraet}` setzt `content_sha256`, wenn noch leer
  (gleicher Wert → ok, anderer → 409 `fingerprint_mismatch`, kein 64-Hex → 400 `fingerprint_invalid`).
  `PUT /api/files/{id}/pagetext {pages: [...]}` → `{pages}` legt `page_texts` mit `chdate` der Datei ab (1…2000
  Seiten, je ≤ 20 000 Zeichen, sonst 400 `pagetext_invalid`); danach nutzen `GET …/pagetext`, `/api/search` und
  `/api/related` den Text (im Dienst gilt eine Hochschuldatei mit Quelle als vorhanden). Beides nur für
  Hochschuldateien ohne Datei beim Dienst (eigenes Dokument → 400 `not_university_file`, Datei auf der Platte → 400
  `file_stored`, unbekannte ID → 404); ein Konto meldet nur Dateien seiner eigenen Datenbank. `GET /api/library` und
  `GET /api/files` liefern je Datei `download_url`, `content_sha256` und `source` (`studip | learnweb | own`), nie
  Tokens oder Passwörter. Restrisiko falscher Meldungen: Spam in der Community (ein Paket ohne die passende PDF ist
  für niemanden lesbar), kein Datenzugriff. Tests `tests/test_device_sync_api.py`.
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
  Anbieter-Kennung (`subject`) mit der UniFlow-ID (`identities`, mit der vom Anbieter gelieferten Adresse); ein
  neues Konto darüber nimmt die gelieferte E-Mail (Relay-Adressen erlaubt) und braucht die Hochschule. Die Prüfung der
  ID-Tokens macht `app/social_login.py` (siehe „Mit Google/Apple anmelden“ unten); ohne Client-IDs antwortet der
  Server 501 `provider_not_configured`; es wird nie ein ungeprüftes Token angenommen. Für Tests und Fixtures bleibt
  `accounts.identity_verifiers["apple"] = fn(identity_token[, nonce=...]) -> {"subject", "email", "email_verified"}`.
- **Sitzungen:** Token 32 Byte (urlsafe), gespeichert als SHA-256; 30 Tage gleitend; `logout`, `logout-all` (andere
  Geräte), Liste unter `/me` (`sessions[]` mit `id`, `device_name`, `last_seen_at`, `current`), **ein Gerät abmelden:
  `DELETE /api/account/sessions/{id}`** (seit 28.10.2026; nur eigene, sonst 404 `session_not_found`; die eigene
  Sitzung löscht auch das Cookie, `current: true`). „Zuletzt gesehen“ wird höchstens einmal je Minute geschrieben.
  Apps senden bei der Anmeldung `device_name` (Windows: „Studora für Windows“, iPad z. B. „iPad von …“), damit die
  Liste verständlich ist. Browser: Cookie `uniflow_session` (HttpOnly, SameSite=Lax, Secure bei HTTPS). Apps:
  `Authorization: Bearer <token>`.
- **Web-Anmeldung** (`app/static/login.html`, `login.js`): `/login` mit Anmelden, Konto anlegen (Hochschule, Passwortregeln
  aus `/api/account/info`), Passwort vergessen (Antwort immer gleich) und neues Passwort über den Link `/login?reset=TOKEN`
  (danach alle Geräte abgemeldet). Nur die öffentlichen Kontopfade, kein Inline-Skript (gleiche CSP wie die App), das
  Token bleibt im HttpOnly-Cookie. Im Dienst leitet `/` ohne Sitzung nach `/login`, `/login` mit Sitzung nach `/`; eine
  abgelaufene Sitzung (401) führt in der App zur Anmeldeseite. Abmelden und „Andere Geräte abmelden“ im Konto-Menü
  hinter dem Avatar. Am PC gibt es die Seite nicht (`/login` → `/`). Tests `tests/test_web_login.py`.
- **Fehlversuche:** 8 je Adresse, 50 je IP (seit 28.10.2026; vorher 8 je IP, das hätte im Hochschulnetz mit NAT alle
  hinter einer IP gesperrt) → 10 Minuten `locked` (429), gezählt in der Datenbank.
- **Reset:** Token 30 Minuten, einmalig, beendet alle Sitzungen und bestätigt die Adresse; die Antwort auf
  `reset-request` ist immer gleich.
- **E-Mail bestätigen (seit 28.10.2026):** Die Willkommensmail enthält `/login?verify=<token>` (48 Stunden, einmalig,
  nur für die aktuelle Adresse). `POST verify-email {token}` geht ohne Sitzung → `{ok, user}`; ungültig/abgelaufen
  → 400 `verify_invalid`. `POST verify-email/resend` (mit Sitzung) schickt einen neuen Link, schon bestätigt →
  `already: true`. `user.email_verified` steht in jeder Konto-Antwort. Community veröffentlichen erst danach (403
  `email_unverified`); alles andere geht vorher. Apple/Google-Konten mit bestätigter Adresse des Anbieters sind sofort
  bestätigt.
- **Grenzen (seit 28.10.2026, 429 `rate_limited` mit `Retry-After`):** Registrieren 30/Stunde je IP (auch vergebene
  Adressen zählen), Reset 30/Stunde je IP und 3/Stunde je Adresse (die zweite still: gleiche Antwort, keine Mail),
  Bestätigungslink erneut 5/Stunde je Konto, Export 3/Tag je Konto. IP-Grenzen großzügig wegen NAT im Hochschulnetz.
  Betreiber ändert sie mit `LERNAPP_LIMIT_<NAME>=Anzahl/Minuten` (z. B. `LERNAPP_LIMIT_REGISTER_IP=60/60`).
  `email_taken` (409) bleibt, weil die Registrierung sofort anmeldet; das Ausprobieren begrenzt die IP-Grenze.
- **Datenexport (seit 28.10.2026):** `GET export` (mit Sitzung) → ZIP mit `LIESMICH.txt`, `konto.json` (Konto,
  Sitzungen, Anmeldewege, Käufe, Nutzung, KI-Nutzung, Abgleich-Aufträge, Hochschul-Zugangsdaten nur mit Namen und
  Benutzername, Passwörter/Schlüssel/Cookies als „gespeichert“), `daten/` (Nutzerordner, SQLite-Dateien konsistent
  kopiert, ohne Browser-Profile), `community/` (eigene Lösungen mit Paketen, Meldungen, Sperrliste),
  `testbibliothek.json`. Referenz `app/account_export.py`.
- **Löschen:** sofort gesperrt (alle Sitzungen weg, Adresse frei), Nutzerordner nach `users-deleted/`, endgültig nach
  30 Tagen (`purge`). Mit Passwort, bei reinen Apple/Google-Konten ohne.
- **Fehlerform:** `{"detail": "<Meldung>", "code": "<stabil>"}`; Codes in `contract.json` → `errors`.
- **Endpunkte:** `POST register`, `login`, `login/{apple|google}`, `link/{apple|google}`, `logout`, `logout-all`,
  `password`, `password/reset-request`, `password/reset`, `verify-email` (öffentlich), `verify-email/resend`,
  `university`, `delete`; `GET me`, `GET export`, `GET info`, `GET providers` (öffentlich).

### Mit Google / Apple anmelden (für die Apps und die Web-Anmeldeseite)

- **Einrichtung (Inhaber):** `LERNAPP_GOOGLE_CLIENT_IDS` / `LERNAPP_APPLE_CLIENT_IDS` (Betrieb, oben). Google: die
  Client-IDs aus der Google-Cloud-Konsole (Android, iOS, Web). Apple: Bundle-ID der iPad-App und die Services-ID für
  das Web; „Sign in with Apple“ in der App-ID aktivieren, Domain für die Services-ID bestätigen. Ohne Eintrag sind die
  Buttons unsichtbar (Web) bzw. der Endpunkt antwortet 501.
- **`GET /api/account/providers`** (öffentlich) → `{"google": bool, "apple": bool, "google_web_client_id": str|null,
  "apple_web_client_id": str|null}`. Die Apps blenden die Buttons nach den Bool-Werten ein; die Web-Client-IDs sind nur
  für die Anmeldeseite im Browser.
- **`POST /api/account/login/google`** bzw. **`/login/apple`** (öffentlich), Body `{"id_token": "<JWT vom SDK>",
  "university": "luh|hildesheim", "nonce": "<falls beim SDK gesetzt>", "email": "<nur Rückfall>", "device_id",
  "device_name"}`. Antwort wie `/login`: `{"user", "token", "created"}` (201 bei neuem Konto, sonst 200), Browser
  bekommt dasselbe Cookie `uniflow_session`. Ablauf: bekannte Kennung → Sitzung; sonst vom Anbieter bestätigte E-Mail
  eines bestehenden Kontos → verknüpfen und anmelden; sonst neues Konto ohne Passwort (Passwort-Login gesperrt, bis
  per „Passwort vergessen“ eines gesetzt ist). `university` ist nur für ein neues Konto nötig; `email` nur, wenn das
  Token keine Adresse enthält (Apple liefert sie bei jeder Anmeldung, als Relay-Adresse). Alte Clients dürfen weiter
  `identity_token` schicken.
- **Fehler:** 401 `token_invalid` (Signatur, Ablauf, `iss`, `aud`, `nonce`), 501 `provider_not_configured`, 400
  `university_unknown` / `email_required`, 409 `email_taken` (Adresse unbestätigt und schon vergeben) /
  `identity_taken` (`link`: Kennung gehört zu einem anderen Konto), 404 `provider_unknown`.
- **Prüfung (Server):** JWKS von `https://www.googleapis.com/oauth2/v3/certs` bzw. `https://appleid.apple.com/auth/keys`
  (urllib, 1 Stunde Cache, bei unbekannter `kid` einmal frisch), RS256/ES256 mit `cryptography`, `iss`
  (`accounts.google.com` / `https://accounts.google.com`, `https://appleid.apple.com`), `aud` ∈ Client-IDs, `exp`
  (60 s Toleranz), `nonce` (Wert oder dessen SHA-256, wie das iOS-SDK es liefert). iPad: `ASAuthorizationAppleIDProvider`
  mit zufälliger Nonce, SHA-256 davon in die Anfrage, Roh-Nonce an den Server; `identityToken` als `id_token`.
- **Web:** Anmeldeseite lädt bei eingerichteten Anbietern das Google-Identity-Skript (`accounts.google.com/gsi/client`)
  bzw. Apples JS-SDK (`appleid.cdn-apple.com`, Popup) – nur `/login` bekommt dafür die erweiterte CSP `LOGIN_CSP`
  (script-/style-/connect-/frame-src um `accounts.google.com`, `appleid.cdn-apple.com`, `appleid.apple.com`); die
  App-Seiten behalten `UI_CSP` ohne fremde Hosts. Ein neues Konto nimmt die Hochschule aus der Auswahl im Reiter
  „Konto anlegen“. Verknüpfen im Konto-Menü (`link/{provider}`) gibt es im Web noch nicht.
- **Löschen** (`delete`) entfernt die Verknüpfungen mit; danach legt dieselbe Kennung ein neues Konto an.
  Tests `tests/test_social_login.py`.

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
- **Abruf:** `GET /api/sync/changes?since=<cursor>&limit=<1…2000>` → `{cursor, changes: {entity: [Zeilen inkl.
  sync_*]}, tombstones, has_more}`. Ohne `since` alles. **Seitenweise (seit 28.10.2026):** je Tabelle höchstens
  `limit` Zeilen; wird eine Tabelle abgeschnitten, gilt für alle Tabellen und Tombstones die kleinste abgeschnittene
  Zeit als Grenze, geliefert wird alles bis einschließlich der Grenze (gleiche Zeitstempel am Ende vollständig),
  `cursor` = Grenze, `has_more: true`. **Clients rufen weiter ab, solange `has_more` true ist.** Vorher war der Cursor
  das Maximum über alle Tabellen; bei mehr als 2.000 Änderungen in einer Tabelle gingen Zeilen verloren. Der Cursor
  bleibt ein Zeitstempel (undurchsichtig behandeln); Clients entfernen Doppelte über Version.
- **Senden:** `POST /api/sync/push {device_id, items: [{entity, id | local_id, base_version, updated_at, data}],
  deletes: [{entity, id, deleted_at}]}` → `{results, mapping, conflicts, server_time}`.
  - neue Zeile: `id` weglassen, `local_id` negativ → `created` mit Server-ID in `mapping`; Fremdschlüssel mit
    negativen IDs (`module_id`, `package_id`, `event_id`, `folder_id`, `parent_id`) werden im selben Push aufgelöst.
  - **`op_id` (seit 28.10.2026, optional, empfohlen):** je Eintrag eine eindeutige ID (8–100 Zeichen `[A-Za-z0-9._:-]`,
    z. B. UUID), beim Wiederholen derselben Änderung dieselbe. Der Server merkt sich das Ergebnis; eine Wiederholung
    (Antwort verloren, Neustart) bekommt dasselbe Ergebnis mit `repeated: true` und dieselbe `mapping`-Zuordnung, statt
    eine neue Zeile doppelt anzulegen. Fehler (`error`) werden nicht gemerkt. Frist 90 Tage (`app/retention.py`).
    Ohne `op_id` legt eine Wiederholung eine zweite Zeile an. Fälle: `abruf-in-seiten`, `wiederholt-senden-op-id` in
    `fixtures/sync/cases.json`.
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
- **Client-Regeln (Windows-App seit 28.10.2026, `app/sync_client.py`; das iPad muss genauso arbeiten):**
  - Lauf = **abrufen → senden → abrufen**. Vor dem ersten Senden wird immer abgerufen, damit Zeilen, die beide Geräte
    aus demselben Stud.IP angelegt haben, nicht doppelt im Konto landen.
  - **Zuordnung** lokale ID ↔ ID im Dienst je Zeile (`sync_link_map`: `remote_version`, `local_version`, bei Notizen
    `base` = zuletzt abgeglichenes Dokument). Lokal geändert = `sync_version` ≠ `local_version`.
  - **Fachliche Schlüssel** für Zeilen ohne Zuordnung (Vergleich ohne Groß-/Kleinschreibung, Fremdschlüssel als
    lokale IDs): `modules` Name + Semester; `folders` Name + Eltern + Modul; `course_events` Kurs-ID (sonst Titel) +
    Wochentag + Beginn + Ende + `date_from` + Art; `event_exceptions` Termin + Datum + Art; `study_packages` Datum +
    Modul + Titel (sonst Fach); `study_tasks` Paket + Art + Titel + Datei; `flashcards` Frage + Datei; `settings`
    Schlüssel; `annotations` `file_id`. Gibt es die Zeile hier schon, gilt der spätere Stand (`sync_updated_at`).
  - Angewendete Zeilen und Tombstones bekommen `sync_device = "~dienst"` und werden nie zurückgesendet.
  - **Notizen:** lokal geändert und im Dienst neuer → `mergeDocument(base, lokal, Dienst)` (gemeinsame Fälle), Ergebnis
    mit `base_version` = Version im Dienst senden; Antwort `conflict` → erneut zusammenführen und senden (höchstens
    zweimal je Lauf). Notizen zu einer Hochschuldatei schicken `file: {name, mime, course_id, course_title,
    semester}` mit; kennt der Dienst die Datei nicht, legt er Kurs und Datei als Kopfzeile ohne Adresse an (sonst
    `unknown_file`). Gibt es die Datei auf dem Gerät noch nicht, wartet die Notiz und wird bei jedem Lauf neu versucht.
  - **Nur auf dem Gerät:** Einstellungen `lan_pin`, `university`, `demo_content`, `semester_rule_applied`,
    `pen_input` und alles mit token/secret/passw im Namen; `study_tasks.test_id` (Tests sind nicht im Abgleich).
  - `op_id` = `<Gerät>.<Tabelle>.<lokale ID>.<sync_version>`: dieselbe Änderung hat bei Wiederholung dieselbe ID.
  - Tarif Free: Notizen bleiben lokal (`plan_required`), alles andere gleicht ab.
- Beide Endpunkte gibt es auch im Einzelplatzmodus (iPad ↔ PC im WLAN); im Dienst gelten sie je Konto.

## G4 Community

- **Nur gehostet** und nur mit Tarif Plus (`users.plan = plus`, optional `plan_until`; heute per `python -m
  app.accounts plan <email> plus [bis]`, später aus den Store-Käufen), sonst 403 `plan_required`. Sitzung wie bei G1
  (Bearer oder Cookie). Die Windows-App (Einzelplatz) leitet `/api/community/...` mit dem Token des verbundenen
  Studora-Kontos an den Dienst weiter (`app/service_link.py`); ohne Konto 409 `not_linked`, Dienst nicht erreichbar
  502 `service_unreachable`, Konto einer anderen Hochschule 409 `university_mismatch`. 501 `not_hosted` antwortet
  nur noch der Community-Router selbst, wenn er ohne Dienst läuft.
- **Stelle eines Kommentars:** `page_key` = Seitenschlüssel im Paket, `anchor` = 0..1 von links oben in der Anzeige
  des Absenders (Koordinaten der Objekte geteilt durch `displaySize`); Empfänger mit anderer Drehung bilden sie wie
  die Objekte ab (`docs/LOESUNGEN-TEILEN.md`, Abschnitt 6a). Testvektoren für Pakete:
  `packages/shared-contracts/fixtures/solutions/vectors.json`.
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

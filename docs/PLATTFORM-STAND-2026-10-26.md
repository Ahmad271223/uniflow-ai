# Nicht-Apple-Plattform: Vorschlag des Inhabers vom 26.10.2026 gegen den Stand von develop

Der Vorschlag „UniFlow als gemeinsame, geräteübergreifende Studienplattform mit persönlichen Konten“ (Onboarding,
Plattformen, Ausbau der Webversion, Mehrbenutzerfähigkeit, Produktregeln) wurde Punkt für Punkt mit dem Code auf
`develop` (Stand fd29a96) abgeglichen. Ergebnis: Die Architektur ist weitgehend gebaut (Konten, gehosteter Modus,
Tresor, Abgleich je Konto, Geräte-Sync, Community, Tarife, Löschung, Fristen, Rechtsseiten); offen sind vor allem
Betrieb, Mailversand, Datenexport, PWA/Offline im Web und die Android-Offline-Ablage.

## 1. Onboarding (Registrieren → Hochschule → Hochschulkonto → Dashboard)

| Schritt | Stand | Wo |
|---|---|---|
| 1 Registrieren/Anmelden (E-Mail + Passwort, später Apple/Google) | **umgesetzt**: Web-Anmeldeseite `/login` mit Registrieren, Anmelden, Passwort vergessen, Reset-Link; Apple/Google als Anmeldewege vorbereitet (501 `provider_not_configured`, bis Team-/Client-ID vorliegen) | `app/account_api.py`, `app/static/login.html`, G1 in `docs/VERTRAEGE-KONTO-SYNC.md` |
| 2 Universität wählen (Hildesheim, LUH) | **umgesetzt**: Pflichtfeld bei der Registrierung, Wechsel über `POST /api/account/university` (getrennte Datenordner je Hochschule) | `app/accounts.py::set_university`, `config.data_dir_for` |
| 3 Hochschulkonto verbinden (optional) | **umgesetzt**: Zugangsdaten verschlüsselt am Konto (`PUT /api/credentials…`), Abgleich als Dienst-Job 08:00/15:00; ohne Verbindung eigene Dateien und Lernpläne nutzbar | `app/vault.py`, `app/jobs.py` |
| 4 Persönliches Dashboard | **umgesetzt**: jede Anfrage läuft im Kontext des Kontos (`hosted_guard`), eigener Datenordner und eigene Datenbank je Konto und Hochschule | `app/server.py::hosted_guard`, `config.set_user_context` |
| Ohne Registrierung kein Datenbereich | **umgesetzt**: im Dienst 401 auf jedem `/api`-Pfad ohne Sitzung, `/` leitet zu `/login` | `tests/test_accounts.py::test_hosted_requires_session_on_every_api_path`, `tests/test_web_login.py` |

## 2. Plattformen

| Plattform | Vorschlag | Stand |
|---|---|---|
| Windows | Web-App + installierbare Desktop-App | **Desktop-App gebaut** (Tauri 2 mit mitgeliefertem Backend, NSIS-Installer über Workflow); Web-App im Browser läuft gegen den Dienst |
| Android-Handy/-Tablet | Play-Store-App | **erste native App** (Compose: Konto, Dokumente, PDF mit Stift, Stundenplan, Lernkalender), Release-Bundle unsigniert; **offen**: Offline-Ablage mit G2-Sync, Karteikarten, Noten, Community, Gerätetest, Play Console |
| iPad / Mac | native Apple-App | Mac-Sitzung (eigener Kern, `apps/apple`), Konto-/Sync-Client M13/M14 nach denselben Verträgen |
| Linux / Browser | Web-App, optional installierbar | Web-App läuft in Chrome, Edge, Firefox, Safari (CSP ohne fremde Hosts, Schrift lokal); **offen**: PWA-Installierbarkeit und Offline (Manifest vorhanden, kein Service Worker) |

Hinweis des Vorschlags „PWA allein ist keine Play-Store-App“: so umgesetzt – Android ist eine native App auf dem
Kotlin-Kern, kein Web-Wrapper.

## 3. Ausbau der Webversion – Abgleich der Tabelle

| Bereich | Vorschlag | Stand |
|---|---|---|
| Registrierung | E-Mail, Passwort, Bestätigung, Zurücksetzen | Registrierung, Passwortregeln, Zurücksetzen (Token 30 min) **umgesetzt**; **E-Mail-Bestätigung offen** (Spalte `email_verified` vorhanden, Versandweg `accounts.reset_sender` noch ohne Anbieter) |
| Login | sichere Sitzungen, Abmelden, Geräteverwaltung | **umgesetzt**: Token nur gehasht, 30 Tage gleitend, HttpOnly-Cookie im Web, Bearer in Apps, `logout`, `logout-all`, Sitzungsliste mit Gerätenamen unter `/me`, Sperre nach 8 Fehlversuchen |
| Benutzerkonten | eigene ID und eigene Daten | **umgesetzt**: UniFlow-ID (32 Hex), Datenordner `users/<id>` je Konto |
| Hochschulwahl | Hildesheim oder LUH | **umgesetzt** (`config.KNOWN_UNIVERSITIES`) |
| Hochschulverbindung | je Nutzer eigene Anmeldung und Tokens | **umgesetzt**: Tresor je Konto (AES-256-GCM, Schlüssel je Konto), eigenes Browserprofil je Konto |
| Dateien | – | **Dienst speichert keine Hochschuldateien** (27.10., `LERNAPP_FILES=stream`): nur Dateiliste, Fingerabdruck, Seitentext; Inhalt wird beim Öffnen mit der Hochschulsitzung durchgereicht (`app/filestream.py`). Geräte halten ihre Kopie lokal (iPad, Android, Windows) |
| Datenbank | alles dem richtigen Konto zuordnen | **umgesetzt, anders als vorgeschlagen**: statt einer gemeinsamen PostgreSQL-Datenbank mit `user_id` in jeder Zeile hat jedes Konto eine **eigene SQLite-Datenbank** in seinem Ordner; die Zuordnung ist damit physisch (keine vergessene WHERE-Bedingung möglich). Zentrale Tabellen nur für Konten, Sitzungen, Jobs, Community. Entscheidung: bleibt so, solange der Dienst auf einem Server läuft; PostgreSQL erst bei mehreren API-Servern (siehe Abschnitt 5) |
| Cloud-Synchronisierung | Abgleich zwischen allen Geräten | **umgesetzt** (G2): Versionsspalten, Trigger, Tombstones, `GET /api/sync/changes`, `POST /api/sync/push`, je Feld letzter Schreiber, Löschen/Wiederherstellen, Notizen mit `base_version` und Konflikt-Zusammenführung; Clients: Kotlin-Kern (SyncApi), Swift (M14) |
| Offline-Nutzung | lokal arbeiten, später synchronisieren | iPad: lokales Journal + Sync-Engine (Mac); Android: **offen** (Room-Ablage mit G2); Web: **offen** (Service Worker) |
| PDF-Editor | Touch, Maus, Tastatur, Stift | Web-Editor (Maus/Touch/Stift, Handballen), Android-Stift, iPad PencilKit; gemeinsames Notizformat und Zusammenführung (`merge.js`, Swift, Kotlin, Fixtures) |
| Community | nutzerübergreifend mit Berechtigungen | **umgesetzt** (G4): nur PDFs aus dem eigenen Hochschul-Abgleich, nur eigene Hochschule, Pseudonyme, Melden/Sperren/Moderation, Tarif Plus |
| Tarife | Free/Plus plattformübergreifend | **Berechtigung am Konto** (`plan`, `plan_until`, serverseitig geprüft); **offen**: Übernahme der Käufe aus App Store/Play (Belegprüfung) statt Kommandozeile |
| Datenschutz | Export, Kontolöschung, sichere Speicherung | Kontolöschung (sofort gesperrt, nach 30 Tagen weg) und Löschfristen **umgesetzt**; Rechtsseiten im Dienst; **Datenexport als Gesamtpaket offen** (heute PDF-Export und Geräteabgleich) |
| Serverbetrieb | Hosting, Backups, Monitoring, Skalierung | **offen – Entscheidung des Inhabers**: Anbieter/Standort, Auftragsverarbeitung, Backups der Konto-Ordner, Monitoring; Code ist vorbereitet (`LERNAPP_MODE=hosted`, Jobs getrennt startbar, `--no-access-log`) |

## 4. Produktregeln – Stand

1. Registrierung verpflichtend: **ja** im Dienst (Einzelplatz-PC bleibt ohne Konto – gewollt).
2. Universität verpflichtend, nur Hildesheim und LUH: **ja**.
3. Hochschulkonto optional: **ja** (eigene Dateien, Stundenplan von Hand, Lernpläne ohne Abgleich).
4. Ein Konto, mehrere Geräte: **ja** (Sitzungen je Gerät, `logout-all`).
5. Hochschulen logisch getrennt: **ja** (eigener Ordner und eigene Datenbank je Hochschule unter dem Konto; Wechsel vermischt nichts).
6. Persönliche Daten privat, Community nur nach Veröffentlichung: **ja** (Pseudonym, verschlüsselte Pakete, zurückziehen).
7. Offline-Änderungen später synchronisieren, keine stille Überschreibung: **Vertrag umgesetzt** (Konflikt 409 → Drei-Wege-Zusammenführung, Tombstones); offline-Warteschlangen je Client: iPad vorhanden, Android/Web offen.
8. Dieselbe Registrierung für iPad/Mac: **ja**, G1 ist der Vertrag für alle Clients (Fixture `fixtures/account/contract.json`).

## 5. Tests aus dem Vorschlag (Abschnitt 7) – was es schon gibt

| Gefordert | Vorhanden |
|---|---|
| Zwei Nutzer gleichzeitig / derselben Uni / verschiedener Unis | `tests/test_accounts.py::test_users_are_isolated_in_their_own_databases`, `tests/test_community.py` (LUH vs. Hildesheim), `tests/test_hosted_sync.py` |
| Zugriff auf fremde Dateien | Datenordner je Konto; `test_hosted_requires_session_on_every_api_path`; Community `file_not_owned` |
| Login auf mehreren Geräten | `test_register_login_sessions_and_lockout`; „Andere Sitzungen beenden“ im Konto-Vertrag (`tests/test_account_contract.py`) |
| Offline-Bearbeitung, gleichzeitige Änderungen | `tests/test_sync.py`, Fixture `fixtures/sync/cases.json`, Merge-Fixtures auf drei Plattformen |
| Kontolöschung | `test_delete_account_locks_and_retires_data`, `tests/test_retention.py` (30 Tage) |
| Hochschulwechsel | `POST /api/account/university` (Ablauf „Hochschule wechseln“ in `fixtures/account/contract.json`, `tests/test_account_contract.py`) |
| Android-/Windows-Darstellung | nur Simulator/Build-Tests; **echte Geräte offen** |

## 6. Benötigte Entscheidungen (Inhaber)

1. Hosting-Anbieter und Standort (EU), Backups, Monitoring; danach Platzhalter in `docs/release/`.
2. Mail-Anbieter für Bestätigung und Passwort-Reset.
3. Apple-Team-ID/Google-Client-ID für „Mit Apple/Google anmelden“.
4. Belegprüfung der Käufe (App Store Server API, Play Developer API) → setzt `plan` am Konto.
5. PWA/Offline im Web (Service Worker) – ja/nein für V1.
6. GitHub Actions wieder freischalten (Abrechnung), damit Windows-/Android-Workflows laufen.

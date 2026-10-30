# Lasttest Dienst (gehostet) – 30.10.2026

Erster Lasttest aus `PLAN-WEB-ZUERST-2026-10-30.md` Stufe A („100 Konten, 1000 Dateien“). Ohne echten Server: das
Skript `tools/lasttest-dienst.py` ruft die FastAPI-App im selben Prozess auf (ASGI-Aufruf wie `tests/conftest.py`),
mit `LERNAPP_MODE=hosted`, eigenem Temp-Datenordner, ohne Zeitplan und ohne Arbeiter-Threads (`LERNAPP_JOBS=off`).
Gemessen wird also die Arbeit der App selbst (Python, SQLite, Dateien), **nicht** Netz, TLS (Caddy), uvicorn und auch
nicht der Browser-Abgleich mit Stud.IP (Playwright wird nicht gestartet).

Aufruf: `.venv/bin/python tools/lasttest-dienst.py` (Standard 100 Konten, 10 Dateien je Konto, 8 Threads, Laufzeit
etwa 40 Sekunden). Optionen: `--accounts`, `--files`, `--threads`, `--reads-per-thread`, `--budget` (Sekunden,
Standard 540; wird es knapp, kürzt das Skript Punkt 5 und 6 und sagt es), `--out datei.json`, `--keep`.
Läuft auf dem Mac und in der Cloud, nur Standardbibliothek plus `requirements.txt`.

## 1. Umgebung

| Was | Wert |
| --- | --- |
| Rechner | Cloud-Sitzung, Linux, 4 CPUs, 16 GB RAM (keine Angabe zum Plattentyp) |
| Python / SQLite | 3.13.17 / 3.45.1, FastAPI 0.162.0 |
| Stand | Branch `develop`, 30.10.2026 abends |
| Zugriffsweg | in-process ASGI, Host `test`, je Anfrage ein eigener `asyncio.run` (Grundlast siehe erste Tabellenzeile) |
| Konten | 100: 50 Probe (7 Tage Pro AI), 30 Plus (`end_trial` + `set_plan`), 20 Free (`end_trial`); 3 von 4 LUH, jedes 4. Hildesheim |
| Registrierung | je Konto eine andere Client-Adresse (Grenze `register_ip` ist 30 je Stunde und Adresse) |

## 2. Ergebnisse (100 Konten, zwei Läufe)

Zeiten je Anfrage in Millisekunden, gemessen mit `time.perf_counter` um den ASGI-Aufruf. „Gesamt“ ist die Summe
der Einzelzeiten des Schritts.

| Schritt | Anzahl | Median ms (Lauf 1 / 2) | p95 ms (1 / 2) | Gesamt s (1 / 2) | Fehler |
| --- | --- | --- | --- | --- | --- |
| Grundlast `GET /api/account/info` (ohne Datenbank) | 50 | 2,3 / 4,0 | 3,0 / 7,2 | 0,14 / 0,24 | 0 |
| 1 Registrieren `POST /api/account/register` | 100 | 107,8 / 105,4 | 127,0 / 122,7 | 10,95 / 10,72 | 0 |
| 1 Tarife setzen (`end_trial`, `set_plan`, 50 Konten) | 50 | – | – | 0,15 / 0,20 | 0 |
| 2 `db.init_db()` je Konto (neue Konto-Datenbank) | 100 | 54,1 / 53,3 | 74,9 / 66,7 | 5,66 / 5,54 | 0 |
| 2 Kurs + 10 Dateien einfügen je Konto | 100 | 2,7 / 2,5 | 3,9 / 3,7 | 0,29 / 0,29 | 0 |
| 3 Lesen gesamt (6 Pfade × 100 Konten) | 600 | 6,0 / 5,8 | 11,1 / 10,5 | 3,92 / 3,86 | 0 (0,0 %) |
| 3 `GET /api/account/me` (erste Anfrage je Konto, enthält `init_db`) | 100 | 8,3 / 8,5 | 11,7 / 11,5 | 0,88 / 0,88 | 0 |
| 3 `GET /api/entitlements` | 100 | 4,8 / 4,9 | 6,3 / 6,3 | 0,53 / 0,53 | 0 |
| 3 `GET /api/modules` | 100 | 5,4 / 5,4 | 6,9 / 6,7 | 0,58 / 0,56 | 0 |
| 3 `GET /api/files` (10 Dateien) | 100 | 6,1 / 5,9 | 7,9 / 7,7 | 0,63 / 0,61 | 0 |
| 3 `GET /api/dashboard` | 100 | 9,1 / 8,8 | 11,5 / 11,5 | 0,95 / 0,92 | 0 |
| 3 `GET /api/billing/plans` | 100 | 3,3 / 3,3 | 4,7 / 4,7 | 0,35 / 0,35 | 0 |
| 4 Notizen Plus `PUT /api/files/{id}/annotations` | 300 | 8,6 / 8,7 | 10,8 / 11,0 | 2,63 / 2,67 | 0, alle 200 |
| 4 Notizen Probe (Zusatz, Pro-AI-Rechte) | 500 | 8,3 / 8,2 | 10,4 / 9,9 | 4,30 / 4,22 | 0, alle 200 |
| 4 Notizen Free (erwartet 403) | 200 | 5,5 / 5,4 | 6,6 / 7,4 | 1,12 / 1,12 | 200 × `403 plan_required` (richtig) |
| 5 `jobs.enqueue(uid, "weekly", "scheduled")` | 100 | 2,3 / 2,5 je Job | – | 0,23 / 0,25 | 0 |
| 5 `jobs.work_once()` bis leer (echtes `weekly.tick`) | 100 | 15,0 / 12,5 je Job | 20,1 / 19,2 | 1,55 / 1,37 | 0; 64 / 73 Jobs je Sekunde |
| 5 `jobs.schedule_due(…, times=["08:00"])` | 100 Jobs | 2,5 / 2,6 je Konto | – | 0,25 / 0,26 | zweiter Aufruf gleiches Fenster: 0 Jobs, 1 ms |
| 6 Gleichzeitig 8 Threads × 50 Lese-Anfragen | 400 | 56,2 / 53,7 | 224,8 / 281,1 | 3,81 / 4,28 (Wanduhr) | 0; 105 / 94 Anfragen je Sekunde; **0 × „database is locked“** |

Gesamtlaufzeit des Skripts: 35,6 s und 35,7 s. Beide Läufe liegen eng beieinander, die Zahlen sind belastbar für
diese Maschine.

### Größe am Ende (100 Konten, 1000 Dateien, 800 Notizen, 200 Jobs)

| Was | Wert |
| --- | --- |
| `accounts.db` (nach Schließen aller Verbindungen, ohne WAL-Rest) | 328 KB; Zeilen: 100 users, 100 sessions, 100 entitlements, 200 sync_jobs, 99 rate_limits, 100 verify_tokens |
| Konto-Datenbanken `users/<id>/…/lernapp.db` | 100 Stück, je 320 KB (80 Seiten à 4 KB), zusammen 31,25 MB |
| Datenordner gesamt | 31,9 MB |
| RSS des Prozesses (`ru_maxrss`, Spitze) | 111–142 MB (ohne Browser) |

Die 320 KB je Konto sind fast nur Schema: 41 Tabellen und 29 Indizes (`app/db.py` SCHEMA plus `weekly.ensure_schema`),
die Daten des Tests (1 Kurs, 10 Dateien, 10 Notizen) machen davon wenige Seiten aus.

## 3. Zusatzläufe (nicht Teil des Pflichtlaufs, gleiche Maschine)

**500 Konten, 5000 Dateien** (`--accounts 500`, Laufzeit 170 s): alle Werte je Anfrage bleiben praktisch gleich –
Registrieren Median 105,6 ms, Lesen Median 6,3 ms / p95 13,1 ms, `/api/account/me` 10,9 ms, Notizen Plus 8,8 ms,
`work_once` 14,6 ms je Job (64 Jobs/s), `schedule_due` 2,4 ms je Konto (1,2 s für 500). 8 Threads: Median 67,9 ms,
p95 306 ms, 83 Anfragen/s, 0 Fehler, 0 „locked“. `accounts.db` 960 KB (1,9 KB je Konto), Konto-Datenbanken 156 MB.
Die Kosten je Anfrage wachsen also zwischen 100 und 500 Konten nicht; `accounts.db` wird über Indizes gelesen.

**32 Threads × 25 Lese-Anfragen** (100 Konten): 800 Anfragen in 9,7 s = 82 Anfragen/s, Median 192 ms, **p95 1,47 s**,
0 Fehler, 0 „database is locked“. Mehr Threads bringen keinen höheren Durchsatz, nur längere Wartezeiten: ein
Python-Prozess (GIL) ist bei etwa 80–105 einfachen Anfragen je Sekunde ausgelastet.

**`claim_next` auf großer Warteschlange** (Mikro-Benchmark außerhalb des Repos: 5000 Konten per SQL, 200 000 alte Jobs,
2000 wartende `sync`-Jobs, `accounts.db` 41 MB): `claim_next` 28–79 ms je Aufruf, auch wenn die Hochschulgrenzen
greifen und die Abfrage alle 2000 Kandidaten verwerfen muss; `enqueue` für 5000 Konten 11,7 s (2,3 ms je Konto);
`bg_state` 1,1 ms. Die Abfrage in `app/jobs.py:141–162` skaliert also ausreichend (SQLite nutzt `idx_jobs_status`; nur die
Teilabfrage zum Abstand je Hochschule scannt `users`, bei 5000 Zeilen unkritisch).

## 4. Was die Zahlen bedeuten

- **Registrieren kostet etwa 105 ms CPU je Konto**, fast alles scrypt (n = 2¹⁴): einmal Hash in `accounts.register`,
  einmal Prüfung in `accounts.login`, das `account_api.register` direkt danach aufruft (`app/account_api.py:89–91`).
  Ein Prozess schafft damit höchstens ~9 Registrierungen je Sekunde. Für den Start reicht das; bei einem Ansturm
  (Hörsaal) wäre `accounts.create_session` statt `login` nach dem Registrieren eine halbe Ersparnis.
- **Erste Anfrage eines Kontos nach einem Neustart** kostet +55 ms (`db.init_db()` in `hosted_guard`,
  `app/server.py:185–188`, einmal je Konto je Prozess). Danach liegen alle Lese-Anfragen bei 3–9 ms, Notizen bei 8–9 ms.
- **Keine Sperrfehler.** Weder 8 noch 32 Threads haben ein „database is locked“ ausgelöst: `accounts.db` wird je
  Anfrage nur gelesen (Sitzung, Tarif), geschrieben wird dort nur einmal je Minute je Sitzung (`last_seen`,
  `app/accounts.py:348–351`), beim Registrieren und von den Jobs. Jedes Konto hat seine eigene Datenbank, Schreiben an
  Notizen konkurriert nie zwischen Konten.
- **Jobs ohne Marker sind billig** (12–15 ms): `weekly.tick` findet keine Vorlesungsmarker und tut wenig. Ein echter
  Lauf mit Markern und Studora-KI ist um Größenordnungen teurer (KI-Antwort je Test mehrere Sekunden) und wurde hier
  nicht gemessen.
- **Ein Prozess, ein Kern.** Unter Last (8 Threads) steigt der Median von 6 auf 55 ms und p95 auf ~250 ms, der
  Durchsatz bleibt bei ~100 Anfragen/s. Das ist die Grenze des einen uvicorn-Prozesses, nicht die der Datenbank.

## 5. Hochrechnung auf 5000 Konten

**Alles in diesem Abschnitt ist Hochrechnung** aus den Messwerten oben (100 und 500 Konten) und den Grenzen im Code,
nicht gemessen. Annahmen: gleicher Rechner-Typ (ein Kern je Prozess etwa wie hier), 5000 Konten, davon an einem
normalen Tag 10 % gleichzeitig aktiv (500), je aktiver Nutzer eine Anfrage alle 10 Sekunden.

| Größe | Rechnung | Ergebnis | Bewertung |
| --- | --- | --- | --- |
| Lese-Last normal | 500 aktive × 0,1 Anfragen/s | 50 Anfragen/s | Ein API-Prozess trägt ~90–100/s: reicht, aber ohne Reserve für Spitzen (Vorlesungsbeginn, Klausurwoche). 2 Prozesse empfohlen. |
| Lese-Last Spitze | 2000 aktive × 0,2 Anfragen/s | 400 Anfragen/s | Braucht 4–5 API-Prozesse (Kerne). Mit 2 Kernen: Wartezeiten im Sekundenbereich (siehe 32-Thread-Lauf). |
| Registrierung Startwoche | 5000 × 105 ms | ~9 Minuten CPU | Unkritisch, wenn verteilt. Spitze: 9 je Sekunde je Prozess. **Achtung:** Grenze `register_ip` 30/h je Adresse (`app/accounts.py:39`) – hinter einem eduroam-NAT wäre der 31. Student in der Stunde gesperrt (429). Vor dem Start `LERNAPP_LIMIT_REGISTER_IP` anheben (z. B. `300/60`). |
| Erste Anfrage nach Neustart | 5000 × 55 ms | 4,6 Minuten CPU, verteilt über die ersten Anfragen | Unkritisch; je Prozess einmal. |
| `accounts.db` | 1,9 KB je Konto + Jobs (~200 B je Job, 2 je Tag, 90 Tage Aufbewahrung `app/retention.py:30`) | ~10 MB Konten + ~180 MB Jobs | Unkritisch für SQLite. Mikro-Benchmark mit 41 MB / 200 000 Jobs: alle Abfragen unter 80 ms. |
| Konto-Datenbanken | 5000 × 320 KB (leer) | **1,6 GB nur Schema**, dazu Inhalte | Platte und Backup (`deploy/backup.sh` kopiert alles) einplanen; mit Notizen (Stift-Striche, Versionsverlauf bis 30 Fassungen) eher 5–50 MB je aktivem Konto → 10–50 GB realistisch. |
| `last_seen`-Schreiben | 500 aktive Sitzungen, je 1 UPDATE je Minute | ~8 Schreibvorgänge/s auf `accounts.db` | Unkritisch (WAL). Bei 5000 gleichzeitig aktiven: 83/s, immer noch im Rahmen. |
| Zeitfenster `schedule_due` | 5000 × 2,3 ms `enqueue` + Tresor-Prüfung je Konto mit Zugangsdaten | ~12 s je Fenster für das Anlegen (gemessen im Mikro-Benchmark) | Unkritisch; läuft im Zeitplan-Thread alle 30 s. Hinweis: `vault.users_with_credentials()` wird je Fenster zweimal aufgerufen (`app/jobs.py:331` und über `active_users_without_credentials` in `app/jobs.py:284`), je Konto mit Zugangsdaten eine Verbindung und AES-Entschlüsselung – bei 5000 Konten geschätzt 2 × 5–10 s zusätzlich. |
| Wochentest-Jobs ohne KI-Arbeit | 5000 × 15 ms | ~75 s je Fenster mit einem Arbeiter | Unkritisch. **Mit** KI (Marker gesetzt, Tests fällig): je Test mehrere Sekunden KI-Zeit; bei 1000 fälligen Tests und 2 Arbeitern grob 1–2 Stunden – nicht gemessen. |
| **Hochschul-Abgleich durch den Dienst** | Grenze `uni_limits`: 2 gleichzeitig **und 15 s Abstand** je Hochschule (`app/jobs.py:125–138`) → höchstens 240 Starts je Stunde je Hochschule, unabhängig von der Arbeiterzahl | 4000 LUH-Konten mit Zugangsdaten: **~17 Stunden je Fenster**; zwei Fenster am Tag (08:00, 15:00) gehen nicht auf | **Der Engpass bei 5000 Konten.** Realistisch sind mit den heutigen Grenzen ~500 Konten mit Dienst-Abgleich je Hochschule (etwa 2 Stunden je Fenster). Dazu RAM: je Browser 300–500 MB (`deploy/docker-compose.yml:36`). |
| RAM API-Prozess | 110–140 MB gemessen ohne Browser | je API-Prozess ~150–300 MB | 2 API-Prozesse + 2 Browser-Arbeiter ≈ 1,5–2 GB: passt in die 2560 MB aus `docker-compose.yml`, mehr Arbeiter nicht. |

## 6. Engpässe und Beobachtungen im Code (nicht geändert)

| Nr. | Stelle | Beobachtung | Vorschlag |
| --- | --- | --- | --- |
| 1 | `deploy/Dockerfile:56`, `deploy/.env.example:126` | uvicorn läuft als **ein** Prozess ohne `--workers`, und die Browser-Arbeiter laufen standardmäßig **im selben Prozess** (`LERNAPP_JOBS=inproc`). Gemessen: ein Prozess trägt ~90–100 Anfragen/s; ein laufender Playwright-Abgleich im selben Prozess nimmt der API CPU und Speicher weg. | Für den Start: `uvicorn --workers 2` (bei 2 Kernen) und die Jobs in einen eigenen Container `python -m app.jobs` mit `LERNAPP_JOBS=off` für die API (im `.env.example` schon beschrieben). Hinweis im Code bleibt gültig: die Grenze `LERNAPP_LIMIT_API_PER_MIN` gilt dann je Prozess (`app/server.py:127–152`). |
| 2 | `app/jobs.py:125–138` (`uni_limits`), `app/jobs.py:141–162` (`claim_next`) | 15 s Abstand je Hochschule = höchstens 240 Abgleiche je Stunde je Hochschule, egal wie viele Arbeiter. Gewollt (Schonung P9), aber bei vielen Konten mit Zugangsdaten läuft die Warteschlange nie leer. | Vor dem Start festlegen, wie viele Konten der Dienst-Abgleich tragen soll (Richtwert 500 je Hochschule). Darüber hinaus: Abstand nach Rücksprache mit LUH/Hildesheim senken (`LERNAPP_UNI_GAP_S`), oder Konten über den Tag verteilen (mehr Zeitfenster statt zwei), oder Web-Nutzer laden selbst hoch (Entscheidung 1 im Plan). |
| 3 | `app/accounts.py:144–156` (`cursor()`) | Jede Anfrage öffnet eine neue Verbindung zu `accounts.db` (Sitzung), eine zweite für den Tarif (`app/entitlements.py:19–28` → `billing.connect`) und eine dritte für die Konto-Datenbank, jede mit `PRAGMA journal_mode=WAL`. `accounts.cursor()` und `db.connect()` (`app/db.py:426–433`) setzen **keinen** `timeout` (SQLite-Standard 5 s), `billing.connect()` dagegen 15 s. Im Test ohne Folgen (0 Sperrfehler), die Kosten stecken in den 3–9 ms. | Einheitlich `timeout=15` wie in `billing.connect`, damit ein langer Schreibvorgang (z. B. `purge_deleted`) nicht nach 5 s zu `database is locked` in einer Anfrage führt. Verbindungen wiederverwenden wäre die größere Änderung; erst nötig, wenn ein Prozess über ~100 Anfragen/s hinaus soll. |
| 4 | `app/db.py` SCHEMA + `app/weekly.py:177` (`ensure_schema`) | Eine leere Konto-Datenbank hat 320 KB (41 Tabellen, 29 Indizes, 80 Seiten). Bei 5000 Konten 1,6 GB nur Schema; `init_db` 55 ms je Konto. | Hinnehmbar. Für Backups zählt es (`deploy/backup.sh`); `PRAGMA page_size=1024` beim Anlegen würde es auf etwa ein Viertel senken, ist aber eine Migration und nicht dringend. |
| 5 | `app/account_api.py:89–91` | Registrieren hasht das Passwort und prüft es sofort wieder (`accounts.login`), zweimal scrypt ≈ 2 × 50 ms. | `accounts.create_session` direkt nach `register` nutzen: halbiert die CPU-Zeit je Registrierung. Klein. |
| 6 | `app/accounts.py:39` (`register_ip` 30/60) | Hinter einem gemeinsamen NAT (eduroam, Hörsaal) ist nach 30 Registrierungen je Stunde Schluss (429). Kein Leistungs-, aber ein Startproblem. | Vor dem Start `LERNAPP_LIMIT_REGISTER_IP=300/60` setzen und beobachten. |
| 7 | `app/jobs.py:319–339` (`schedule_due`) | Je Fenster ein `enqueue` je Konto = eine Verbindung je Konto (2,3 ms); `vault.users_with_credentials()` zweimal je Fenster (siehe oben). Bei 5000 Konten ~12 s + 2 × Tresor-Durchlauf. | Hinnehmbar. Wenn es stört: Ergebnis von `users_with_credentials()` einmal holen und an `active_users_without_credentials` übergeben; `enqueue` in einer Verbindung für alle Konten. |
| 8 | `app/server.py:73`, `:185–188` (`_user_dbs_ready`) und `app/db.py:408–425` (`schema_once`) | Mengen wachsen je Prozess mit der Zahl der Konten (5000 Einträge, einige hundert KB). | Unkritisch; nur erwähnt, weil sie nie geleert werden. |

Nicht bestätigt werden konnte ein Engpass in `accounts.db`: alle Abfragen laufen über Indizes (`token_hash`,
`users.id`, `idx_jobs_status`), und 200 000 Job-Zeilen änderten die Zeiten nicht spürbar.

## 7. Empfehlungen vor dem Start

1. **Zwei Prozesse für die API, Jobs getrennt.** `uvicorn --workers 2` (2 Kerne) und `python -m app.jobs` als eigener
   Container/Prozess mit `LERNAPP_JOB_WORKERS=2`, in der API `LERNAPP_JOBS=off`. Dann stört kein Browser die API, und
   ein Absturz eines Abgleichs legt die API nicht lahm. Speicher: 2 × ~250 MB API + 2 × 400 MB Browser + Caddy.
2. **Dienst-Abgleich begrenzen.** Mit den heutigen Hochschul-Grenzen (2 gleichzeitig, 15 s Abstand) trägt der Dienst
   etwa 500 Konten mit Zugangsdaten je Hochschule und Fenster. Mehr nur nach Absprache mit den Hochschulen, dann
   `LERNAPP_UNI_GAP_S` senken und `LERNAPP_JOB_WORKERS` sowie RAM erhöhen (je Arbeiter 300–500 MB).
3. **Grenzen für den Start setzen:** `LERNAPP_LIMIT_REGISTER_IP=300/60` (NAT), `LERNAPP_LIMIT_API_PER_MIN` bei 600
   lassen (normale Nutzung liegt bei wenigen Anfragen je Minute).
4. **SQLite-Zeitlimit vereinheitlichen** (`timeout=15` in `accounts.cursor` und `db.connect`), bevor viele Konten
   schreiben. Kleine Änderung, verhindert seltene 500er bei langen Schreibvorgängen.
5. **Platte und Backup:** 320 KB je Konto leer, realistisch 5–50 MB je aktivem Konto. Für 5000 Konten 50 GB Platte
   und ein Backup, das nicht jede Nacht alles kopiert (Snapshots nach Konto-Änderung, siehe `deploy/backup_snapshot.py`).
6. **Monitoring:** p95 der API (Ziel unter 100 ms ohne Last, unter 500 ms unter Last), Länge der Job-Warteschlange
   (`SELECT COUNT(*) FROM sync_jobs WHERE status='queued'`), Alter des ältesten wartenden Jobs, Plattenplatz,
   RSS je Prozess, Zähler für `database is locked` im Log (im Test 0).
7. **Nächster Lasttest** gegen den echten Dienst (uvicorn + Caddy, HTTPS, von außen) mit denselben Schritten, dazu
   ein Lauf mit gesetzten Vorlesungsmarkern und KI-Attrappe, um die Wochentest-Jobs mit Arbeit zu messen, und ein
   Abgleich mit Playwright für ein Konto (Zeit und Speicher je Abgleich), damit die Hochrechnung in Abschnitt 5 eine
   gemessene Grundlage bekommt.

## 8. Was nicht gemessen wurde

- Netz, TLS, uvicorn, Caddy – alles lief im selben Prozess ohne Socket.
- Hochschul-Abgleich mit Browser (Playwright): nicht gestartet; die 300–500 MB je Browser stammen aus
  `deploy/docker-compose.yml`, die Dauer eines Abgleichs ist nicht bekannt.
- Wochentests mit Arbeit (Marker, KI, Kontingente): `weekly.tick` lief echt, fand aber keine Marker.
- Stripe, Apple-Belege, Community, Testbibliothek, Datei-Streaming (`filestream.py`), Upload von Hand.
- Verhalten mit mehreren Prozessen auf einer `accounts.db` (zweiter uvicorn-Worker, getrennter Job-Prozess): die
  Threads im Test teilen sich einen Prozess; echte Prozess-Konkurrenz auf WAL-Dateien wurde nicht erzeugt.
- Langzeitwachstum (Monate), Löschfristen (`retention.py`) unter Last, Wiederherstellung aus Backups.

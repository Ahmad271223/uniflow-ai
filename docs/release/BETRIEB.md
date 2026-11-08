# Betrieb des gehosteten Dienstes (Hosting-Paket `deploy/`) – Entwurf, Stand 27.10.2026

Schritt für Schritt vom leeren VPS zum laufenden StudiNow-Dienst (`LERNAPP_MODE=hosted`): ein Server in der EU,
Docker, ein Container mit der App (uvicorn, intern auf 8765) und Caddy davor (TLS von Let's Encrypt, Ports 80/443).
Grundlage: `docs/VERTRAEGE-KONTO-SYNC.md` (Betrieb, Tresor, Jobs, Löschfristen) und
`docs/LIVE-BLOCKER-TEST-2026-10-25.md` (Serverplanung nach Nutzerzahl).

**Was geprüft ist und was nicht:**

- Lokal geprüft (Docker Desktop, 27.10.2026): Image baut (`deploy/Dockerfile`, 3,5 Minuten, 1,99 GB wegen
  Chromium), Container startet im gehosteten Modus und ist nach 7 Sekunden `healthy`, `/login` 200, `/` → 302
  `/login`, `/datenschutz` 200, `/api/account/me` ohne Sitzung 401, Registrierung über `POST /api/account/register`
  201, `python -m app.accounts list` und `python -m app.retention --dry-run` im Container, Chromium startet als
  Nutzer `uniflow`, Backup-Skript liefert ein lesbares Archiv mit `accounts.db` und `users/<id>/lernapp.db`,
  `docker compose config` ohne Fehler, `caddy validate` meldet „Valid configuration“, `tests/test_deploy.py` grün.
- **Erst auf dem Server prüfbar:** Caddy mit echter Domain (Zertifikat, HTTP→HTTPS), Hochschul-Abgleich mit
  Chromium im Container (Speicher, Zeitplan 08:00/15:00), Backup-Timer, Löschfristen um 04:00, Update-Ablauf.
- **Nicht im Paket:** Mail-Anbieter (Passwort-vergessen-Mails), Store-Konten (Apple/Google), Vertrag zur
  Auftragsverarbeitung mit dem Hoster, Ausfüllen der Platzhalter in den Rechtstexten, Monitoring-Dienst,
  PostgreSQL/Object Storage (laut Serverplanung erst ab V2-Wachstum; der Dienst läuft heute mit SQLite je Konto).

## Dateien des Pakets

| Datei | Zweck |
|---|---|
| `deploy/Dockerfile` | Image: Python 3.12 slim, Abhängigkeiten aus `requirements.txt`, Chromium für Playwright (nur Chromium, mit Systembibliotheken), unprivilegierter Nutzer `uniflow` (UID 1000), `/data` und `/logs`, Healthcheck auf `/login`, Start mit uvicorn (`--proxy-headers --no-access-log`) |
| `.dockerignore` (Repo-Wurzel) | hält `data/`, `logs/`, `.venv`, `apps/`, `backup/`, `.git`, Datenbanken und `.env` aus dem Image |
| `deploy/docker-compose.yml` | Dienste `app` (nur intern, Volumes `uniflow-data`, `uniflow-logs`, Speichergrenze 2,5 GB, `/dev/shm` 512 MB für Chromium) und `caddy` (80/443, Volume `caddy-data` für Zertifikate) |
| `deploy/Caddyfile` | Domain aus `UNIFLOW_DOMAIN`, HSTS, `X-Content-Type-Options`, Referrer-Policy (nur wo die App keine setzt), Upload-Grenze 320 MB (App: 300 MB), lange Timeouts für Abgleich und große Dateien, kein Caddy-Zugriffsprotokoll |
| `deploy/.env.example` | alle Variablen mit Erklärung → nach `deploy/.env` kopieren (ist per `.gitignore` ausgeschlossen) |
| `deploy/backup.sh`, `deploy/backup_snapshot.py` | tägliches Backup als `tar.gz` nach `/srv/uniflow/backups`, Datenbanken konsistent über die SQLite-Backup-API, 14 Tage Aufbewahrung |
| `deploy/uniflow-backup.service`, `.timer` | systemd-Zeitplan 03:30 (vor den Löschfristen um 04:00) |
| `tests/test_deploy.py` | prüft das Paket ohne Docker (Variablen, Ports, Ausschlüsse, Backup-Skript) |

## 1. Server bestellen

- **Größe für den Start:** 2 vCPU, 4 GB RAM, 40 GB SSD reichen laut Serverplanung bis etwa 1.000 registrierte
  Nutzer (Hetzner CX23 oder vergleichbar, ca. 4–6 € netto/Monat; IONOS VPS ähnlich). Mehr Nutzer: Tabelle
  „Hosting nach Nutzerzahl“ in `docs/LIVE-BLOCKER-TEST-2026-10-25.md`. Der Abgleich mit Chromium braucht je
  gleichzeitigem Lauf 300–500 MB – `LERNAPP_JOB_WORKERS=2` passt zu 4 GB; bei 8 GB kann es 4 sein.
- **Standort EU** (Hetzner: Nürnberg/Falkenstein/Helsinki; IONOS: Deutschland). Hoster und Standort in die
  Datenschutzerklärung (`[[Hoster]]`, `[[Serverstandort]]`), **Vertrag zur Auftragsverarbeitung**
  (Art. 28 DSGVO) in der Hoster-Konsole abschließen.
- Betriebssystem: Debian 12 oder Ubuntu 24.04 LTS. Beim Bestellen einen **SSH-Schlüssel** hinterlegen, kein
  Passwort-Login. Firewall des Hosters: nur 22 (SSH), 80 und 443 offen.
- Kostenrahmen Start: Server ca. 5 €, Domain ca. 1–2 €/Monat, Backup-Speicher (z. B. Hetzner Storage Box 1 TB
  ca. 4 €) – zusammen **rund 10–15 € netto im Monat**. Mailversand und Store-Konten kommen dazu (nicht im Paket).

## 2. DNS

Beim Domain-Anbieter einen **A-Eintrag** (IPv4 des Servers) und einen **AAAA-Eintrag** (IPv6) für den Hostnamen
anlegen, z. B. `app.example.de`. Prüfen: `dig +short app.example.de` muss die Server-IP liefern, bevor Caddy
startet – sonst scheitert die Zertifikatsausstellung und Let's Encrypt zählt Fehlversuche.

## 3. Server vorbereiten (einmalig, als root per SSH)

```bash
apt update && apt upgrade -y
apt install -y ca-certificates curl git ufw unattended-upgrades
# Docker (offizielles Repository, enthält docker compose v2)
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
# Firewall: nur SSH, HTTP, HTTPS
ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw --force enable
# Zeitzone (Zeitplan 08:00/15:00 und Löschfristen 04:00 gelten in Ortszeit des Containers, TZ=Europe/Berlin)
timedatectl set-timezone Europe/Berlin
mkdir -p /srv/uniflow/backups && chmod 700 /srv/uniflow/backups
```

Hinweis: `get.docker.com` ist das offizielle Installationsskript von Docker; wer es nicht blind ausführen will,
folgt der Anleitung „Install Docker Engine on Debian/Ubuntu“ auf docs.docker.com (gleiches Ergebnis).

## 4. Repository klonen (privat → Deploy-Key)

Das Repository ist privat. Auf dem Server einen eigenen Schlüssel nur zum Lesen anlegen:

```bash
ssh-keygen -t ed25519 -N "" -C "uniflow-server" -f /root/.ssh/uniflow_deploy
cat /root/.ssh/uniflow_deploy.pub     # → GitHub: Repository → Settings → Deploy keys → Add (nur Lesen)
printf 'Host github.com\n  IdentityFile /root/.ssh/uniflow_deploy\n  IdentitiesOnly yes\n' >> /root/.ssh/config
git clone -b develop git@github.com:<Konto>/<Repository>.git /srv/uniflow/app
```

Zweig: solange `main` nicht den Stand des Dienstes trägt, `develop` (Entscheidung in `docs/release/README.md`
bzw. der Repo-Notiz zu `main` vs. `develop`).

## 5. `deploy/.env` ausfüllen

```bash
cd /srv/uniflow/app/deploy
cp .env.example .env && chmod 600 .env
openssl rand -base64 32        # → LERNAPP_SECRET_KEY
nano .env
```

Pflicht: `UNIFLOW_DOMAIN`, `UNIFLOW_ACME_EMAIL`, `LERNAPP_ALLOWED_HOSTS` (= Domain), `LERNAPP_SECRET_KEY`.
Der Schlüssel verschlüsselt die Hochschul-Zugangsdaten aller Konten (Tresor, `app/vault.py`). **Sofort in den
Passwort-Manager** – verloren heißt: alle Tresor-Werte unlesbar, jeder Nutzer muss seine Zugangsdaten neu
eingeben. Er gehört nie ins Backup-Archiv und nie ins Repository. Alle übrigen Variablen sind in
`.env.example` erklärt; die Löschfristen (14/90 Tage) müssen zur Datenschutzerklärung passen.

## 6. Starten

```bash
cd /srv/uniflow/app/deploy
docker compose config -q            # Datei und .env stimmig?
docker compose up -d --build        # Image bauen (ca. 5 Minuten, lädt Chromium), App und Caddy starten
docker compose ps                   # app muss "healthy" werden (Startphase 30 s), caddy "running"
docker compose logs -f app          # Strg+C beendet nur die Anzeige
```

Prüfen von außen (eigener Rechner): `https://app.example.de/login` zeigt die Anmeldeseite,
`http://app.example.de` leitet auf https um, `https://app.example.de/datenschutz` die Datenschutzerklärung.
Erste Zertifikatsausstellung dauert wenige Sekunden; schlägt sie fehl: `docker compose logs caddy` (meist DNS
noch nicht umgestellt oder Port 80 blockiert).

## 7. Erstes Konto, Admin und Tarif (CLI)

Konten entstehen über die Anmeldeseite (Registrieren). Verwaltung im Container mit `python -m app.accounts`:

```bash
cd /srv/uniflow/app/deploy
docker compose exec app python -m app.accounts list                       # alle Konten
docker compose exec app python -m app.accounts role <email> admin         # Rolle user|admin
docker compose exec app python -m app.accounts plan <email> plus 2027-03-31   # Tarif free|plus [bis Datum]
docker compose exec app python -m app.accounts reset-token <email>        # Reset-Token, solange kein Mailversand läuft
docker compose exec app python -m app.accounts purge                      # Konten >30 Tage nach Löschung entfernen (macht der Retention-Job täglich)
docker compose exec app python -m app.tester_freischalten --email <email> --tage 14 --ausfuehren   # Probe des Kontos verlängern (TestFlight-Tester, docs/release/TESTFLIGHT-500-2026-11-08.md); ohne --ausfuehren Probelauf
```

Den Reset-Token gibt man dem Nutzer als Link `https://app.example.de/login?reset=<TOKEN>` (gültig wie in
`accounts.RESET_MINUTES`).

## 8. Updates einspielen

```bash
cd /srv/uniflow/app && git pull
cd deploy && docker compose up -d --build     # baut neu, tauscht nur geänderte Container (Caddy bleibt)
docker compose ps && docker compose logs --tail=50 app
docker image prune -f                         # alte Images aufräumen
```

Vor jedem Update ein Backup (Abschnitt 9). Änderungen an `deploy/.env` gelten nach `docker compose up -d`.
Ein laufender Abgleich wird beim Tausch des Containers abgebrochen; beim Start markiert der Dienst verwaiste
Jobs als abgebrochen, der nächste Zeitpunkt (08:00/15:00) holt ihn nach.

## 9. Backups

Was gesichert wird: `accounts.db` (Konten, Sitzungen, Tresor verschlüsselt, Jobs), je Nutzer `lernapp.db`
(Notizen, Kalender, Karteikarten, …), `assets/`, `qis/`-Dokumente, auch `users-deleted/` (30-Tage-Frist). Nicht:
Browser-Profile (Hochschul-Sitzungen), `files/` (im Dienst leer, Dateien werden nur durchgereicht), Protokolle,
`secret.key`. Der Dienst läuft während des Backups weiter (SQLite-Backup-API, keine halben Schreibvorgänge).

```bash
# einmal von Hand
/srv/uniflow/app/deploy/backup.sh
ls -lh /srv/uniflow/backups
# Zeitplan (systemd, täglich 03:30)
cp /srv/uniflow/app/deploy/uniflow-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now uniflow-backup.timer
systemctl list-timers uniflow-backup.timer
journalctl -u uniflow-backup.service -n 20
```

Aufbewahrung 14 Tage (`BACKUP_KEEP_DAYS`). **Ein Server allein ist kein Backup:** in `backup.sh` die Zeile für
`rclone` (Hetzner Storage Box per SFTP) oder `scp` einkommentieren, Ziel in der EU, Archive verschlüsseln, wenn
der Zielspeicher nicht allein vom Inhaber kontrolliert wird. Monatlich eine Wiederherstellung probeweise durchspielen.

### Wiederherstellung

1. Dienst anhalten: `cd /srv/uniflow/app/deploy && docker compose stop app`
2. Archiv auswählen: `ls /srv/uniflow/backups` (Inhalt ansehen: `tar -tzf <Archiv> | head`)
3. Daten-Volume leeren und befüllen (das Archiv enthält den Ordner `uniflow-data/`):
   ```bash
   docker run --rm -v uniflow_uniflow-data:/data -v /srv/uniflow/backups:/backups:ro alpine sh -c \
     'rm -rf /data/* && tar -xzf /backups/<Archiv>.tar.gz -C /data --strip-components=1 && chown -R 1000:1000 /data'
   ```
   (Volume-Name prüfen mit `docker volume ls`; das Compose-Projekt heißt `uniflow`.)
4. `deploy/.env` muss denselben `LERNAPP_SECRET_KEY` enthalten wie zum Zeitpunkt des Backups – sonst sind die
   Tresor-Werte unlesbar (Konten und Notizen bleiben nutzbar, Zugangsdaten müssen neu eingegeben werden).
5. Starten und prüfen: `docker compose start app && docker compose exec app python -m app.accounts list`

Neuer Server: Abschnitte 3–6 wiederholen, danach Wiederherstellung wie oben; Caddy holt ein neues Zertifikat.

## 10. Protokolle lesen

```bash
docker compose logs --tail=200 app          # Anwendung (Jobs: "[jobs] ...", Zugriff: "[access] ...")
docker compose logs --tail=100 caddy        # TLS, Proxy-Fehler
docker compose exec app sh -c 'ls /logs/access && tail -n 20 /logs/access/access-$(date +%F).log'   # Zugriffsprotokoll, 14 Tage
docker compose exec app tail -n 20 /logs/retention.log                                                 # Löschfristen je Lauf
docker compose exec app sh -c 'tail -n 30 /data/users/<id>/logs/sync.log'                              # Abgleich eines Kontos
```

Docker-Protokolle sind auf 3 × 10 MB je Container begrenzt (`docker-compose.yml`). Das Zugriffsprotokoll der
App enthält IP-Adressen und fällt unter die 14-Tage-Frist; Caddy schreibt bewusst keins.

## 11. Löschfristen prüfen

```bash
docker compose exec app python -m app.retention --dry-run    # zeigt, was gelöscht würde, löscht nichts
docker compose exec app python -m app.retention              # sofort ausführen
docker compose exec app tail -n 5 /logs/retention.log        # letzte Läufe (täglich ab LERNAPP_RETENTION_TIME)
```

Fehlt die tägliche Zeile, läuft der Zeitplan nicht: `LERNAPP_JOBS` darf nicht `off` sein, solange kein eigener
Jobs-Container (`python -m app.jobs`) läuft.

## 12. Monitoring (minimal)

- **Healthcheck** im Container: `docker compose ps` zeigt `healthy`; bei `unhealthy` startet Docker den
  Container nicht automatisch neu – `docker compose restart app` und Protokolle lesen.
- **Uptime-Check von außen** (kostenlos: Uptime Kuma selbst gehostet, UptimeRobot, Hetzner-Konsole hat keinen):
  alle 5 Minuten `GET https://app.example.de/login`, Erwartung 200; Benachrichtigung per Mail/Push.
- **Platz und Speicher:** wöchentlich `df -h /` und `docker stats --no-stream`; `docker system df` für alte Images.
  Wird die 2,5-GB-Grenze der App erreicht (Chromium-Abgleiche), `LERNAPP_JOB_WORKERS` senken oder Server vergrößern.
- **Zertifikat:** Caddy erneuert automatisch; Let's Encrypt mailt an `UNIFLOW_ACME_EMAIL`, falls es scheitert.
- **System-Updates:** `unattended-upgrades` ist installiert; Docker-Images über Abschnitt 8 aktualisieren.

## 13. Was der Inhaber zusätzlich tun muss

1. Platzhalter in `docs/release/*.md` ersetzen (Impressum, Datenschutz: Hoster, Standort, Mail-Anbieter) – der
   Dienst liefert diese Dateien unter `/datenschutz`, `/impressum`, `/nutzungsbedingungen`, `/konto-loeschen` aus.
   Entweder im Repository ersetzen und neu bauen, oder einen eigenen Ordner als Volume einhängen und
   `LERNAPP_LEGAL_DIR` darauf zeigen.
2. Mailversand einrichten (Variablen `LERNAPP_MAIL*`, `LERNAPP_SMTP_*`, `LERNAPP_PUBLIC_URL` in `.env.example` sind
   vorgesehen, die Anbindung in `app/mail.py` entsteht parallel); bis dahin Reset-Token per CLI (Abschnitt 7).
3. Vertrag zur Auftragsverarbeitung mit dem Hoster und ggf. dem Mail-Anbieter.
4. Backup-Ziel außer Haus (Abschnitt 9) und einmal die Wiederherstellung üben.
5. Den Abgleich mit einem echten Hochschulkonto auf dem Server beobachten (erster Lauf nach 08:00/15:00 oder per
   „Jetzt abgleichen“ in der App) und `docker stats` dabei ansehen.

## 14. Kapazität und Lastgrenzen (Stand 08.11.2026)

Ziel des Inhabers: „Alle sollen gleichzeitig anmelden, abgleichen, fragen, hochladen können“ – TestFlight mit bis zu
500 Testern, später 5.000 Nutzer, und bis zu **4.000 KI-Fragen gleichzeitig**, ohne dass etwas hängt. Dieser Abschnitt
nennt, was der Dienst auf dem heutigen Server (Hetzner CX23, 2 vCPU, 4 GB) trägt, welche Schalter es gibt und was von
außen begrenzt (OpenAI, Servergröße, Caddy, Dateideskriptoren). Nichts davon wurde gegen den echten Server gemessen;
alle Zahlen stammen aus `tools/lasttest-ki.py` (lokal, 4 Prozesse, Schein-Anbieter mit 10 s Antwortzeit).

### Was geändert wurde (Zweig `server/lastfest`)

| Vorher | Nachher |
| --- | --- |
| KI-Endpunkte waren synchrone Funktionen: jede Frage belegte 5–30 s einen der **40 Threads** je Prozess (anyio-Standard). Ab ~80 gleichzeitigen Fragen warteten **alle** Endpunkte (Anmelden, Abo-Stand, Abgleich). | `/api/ai/tutor`, `/api/ai/flashcards`, `/api/ai/relay`, `/api/ai/document/step` sind `async def` (`app/ai_async.py`). Der Anbieter wird asynchron gefragt (httpx bzw. Async-SDK, Ereignisstrom Zeile für Zeile, nichts gepuffert): eine offene Frage ist **nur eine wartende Verbindung**, kein Thread. Kurze Datenbankschritte laufen in einem eigenen kleinen Begrenzer (8 Threads), nie im allgemeinen Pool. |
| Budgetprüfung summierte je Frage den ganzen Monat unter Schreibsperre (19 ms bei 100k, 62 ms bei 300k Zeilen). | Laufende Monatssummen `ai_usage_month` / `ai_usage_user_month` (Trigger auf `ai_usage_log`, Neuaufbau beim Start). Eine Zeile lesen statt summieren; gleiche Antworten wie vorher (Tests). |
| Während der Anbieter antwortete, hielt jede Frage eine SQLite-Verbindung offen. | Keine Datenbankverbindung während der Antwort (bei 4.000 Fragen wären das 12.000 Dateideskriptoren). |
| Zeitlimit zum Anbieter 120 s, keine Wiederholung; Anbieter-429 als Fehler „antwortete mit Fehler 429“. | 90 s (`LERNAPP_AI_TIMEOUT_S`); Netzfehler/5xx vor der Antwort werden **einmal** sofort wiederholt (nur wenn der Fehler schnell kam, nie nach einem Zeitlimit), dann übernimmt der nächste Anbieter der Mischung. Anbieter-429 → 503 `ai_provider_busy` „Die KI ist gerade ausgelastet, bitte gleich noch einmal.“ mit `Retry-After: 5`. |
| 2 API-Prozesse, 768 MB, 1.024 Dateideskriptoren. | **4 API-Prozesse** (`UVICORN_WORKERS`), `API_MEMORY=1536M`, `jobs` 1536M, `ulimits nofile 65536`, `--backlog 4096`. Healthcheck unverändert. |
| – | Notbremse `LERNAPP_AI_CONCURRENCY` (Standard **5000 je Prozess**): darüber antwortet der Dienst sofort mit 503 `ai_overloaded` + `Retry-After: 3` statt endlos zu warten. |
| accounts.db: WAL, busy_timeout 15 s. | zusätzlich `synchronous=NORMAL` (kein fsync je Commit; im WAL-Modus bleibt die Datei bei Absturz konsistent). |

### Messung (lokal, 4 Prozesse, Schein-Anbieter 10 s)

| Lauf | KI-Fragen gleichzeitig | beantwortet / Fehler | KI-Dauer p50 / p95 | KI-Durchsatz | normale Anfragen **unter Last** p50 / p95 / max | ohne Last p50 / p95 | Speicher je Prozess Ruhe → Spitze |
| --- | --- | --- | --- | --- | --- | --- | --- |
| vorher (develop, 4 Prozesse) | 300 | 300 / 0 | 19,2 s / 38,6 s | 7/s | 6 ms / **17,3 s** / 27,8 s | 51 / 97 ms | 80–162 → 151–182 MB |
| vorher | 2.000 | 2.000 / 0 | 68 s / 157 s | 11/s | 9 ms / **166 s** / 166 s | 49 / 103 ms | 80–166 → 196–283 MB |
| **nachher** (server/lastfest) | 300 | 300 / 0 | 10,0 s / 10,2 s | 25/s | 31 ms / **66 ms** / 85 ms | 57 / 143 ms | 80–217 → 129–232 MB |
| nachher | 2.000 | 2.000 / 0 | 15,7 s / 19,8 s | 94/s | 45 ms / **177 ms** / 781 ms | 51 / 100 ms | 80–150 → 222–258 MB |
| nachher (Anbieter 10–20 s) | 4.000 | 4.000 / 0 | 27,3 s / 32,8 s | 115/s | 29 ms / **832 ms** / 1,8 s | 29 / 154 ms | 80–217 → 278–420 MB |

Speicher je 1.000 gleichzeitig offene KI-Fragen und Prozess: etwa **+200 bis +250 MB** (Lauf mit 4.000 = 1.000 je
Prozess). Die KI-Dauer über der Antwortzeit des Anbieters (nachher 2.000: ~5 s, 4.000: ~7 s) ist die Warteschlange beim
Abschicken (Verbindungsaufbau, Reservierung in accounts.db über 8 Threads je Prozess) – kein Thread-Stau mehr wie vorher.

Lesart: „normale Anfragen“ sind je ein Drittel `POST /api/account/login`, `GET /api/entitlements`, `POST /api/sync/push`,
abgeschickt 3 s nach dem Start der KI-Fragen. Vorher warteten sie hinter den KI-Fragen (p95 17 s bei 300 Fragen);
nachher bleiben sie im Bereich der Messung ohne Last. Der Lasttest läuft auf einem Mac mit `kern.ipc.somaxconn=128`;
Verbindungsspitzen beim Abschicken tausender Fragen in 2–4 s stauen sich dort kurz – auf dem Server steht `--backlog 4096`
und Caddy hält die Verbindungen zu den Clients.

### Was der Dienst jetzt trägt – und was von außen begrenzt

**Der Dienst selbst.** 4.000 gleichzeitig offene KI-Fragen sind 4.000 wartende Verbindungen zum Client und 4.000 zum
Anbieter, verteilt auf 4 Prozesse (je 1.000). Speicher je 1.000 offene Fragen und Prozess: ~200–250 MB (Tabelle, Spitze minus
Ruhewert); 4 Prozesse mit je 1.000 offenen Fragen brauchen damit ~1,2–1,7 GB – `API_MEMORY=1536M` reicht knapp, siehe Servergröße. Die Rechenlast einer Frage ist klein (Prompt bauen, Credits reservieren, Antwort abrechnen: ~5 kurze
Schreibtransaktionen auf accounts.db); 4.000 Fragen in 20 s sind ~200 Fragen/s. Mikro-Messung `tools/lasttest-ki-ledger.py`
(4 Prozesse gleichzeitig, nur der Schreibweg einer Frage: Credits + Budget reservieren, Protokoll + Credits abrechnen):
leere Tabelle **1.293 Fragen/s** (5.172 Transaktionen/s, Reservierung p95 4 ms), 100.000 Zeilen im Monat 968 Fragen/s,
300.000 Zeilen **748 Fragen/s** (p95 1,7 ms; einzelne Ausreißer bis ~1 s = Checkpoint des WAL). Die alte Summe über den
Monat kostete bei 300.000 Zeilen 19 ms je Frage unter Schreibsperre, die laufende Summe 0,03 ms. WAL + kurze
Transaktionen + `synchronous=NORMAL` tragen also das Drei- bis Sechsfache des Ziels; Reservierungen zusammenzufassen
(Batch) ist nicht nötig. Wird es eng, `LERNAPP_AI_DB_THREADS` nicht erhöhen (mehr Threads streiten nur um dieselbe
Datei), sondern mehr Prozesse/Kerne – oder accounts.db auf PostgreSQL (docs/SKALIERUNG-GROSS.md).

**OpenAI (Stufe des Inhaber-Kontos, Stand 08.11.2026, nach 319 EUR Aufladung; nachsehen unter platform.openai.com →
Settings → Limits):** `gpt-6-luna` 10.000.000 Tokens/Minute, 10.000 Anfragen/Minute, 1.000.000.000 Tokens/Tag;
`gpt-6-astra`, `gpt-6.1-sol` u. a. 4.000.000 Tokens/Minute, 10.000 Anfragen/Minute. 4.000 Fragen mit je ~2.500 Tokens
(Eingabe + Ausgabe) sind ~10 Mio. Tokens – das ist **genau die Minutengrenze von gpt-6-luna**; kommen die 4.000 Fragen
innerhalb einer Minute, antwortet OpenAI für einen Teil mit 429 → bei uns „Die KI ist gerade ausgelastet“ (`Retry-After 5`),
die Clients fragen mit derselben `request_id` noch einmal (nie doppelt berechnet). Claude über Bedrock (etwa 25 % der
Mischung) hat eigene Grenzen (AWS-Konsole → Bedrock → Quotas).

**Kostenbremse.** Das Ausgabenlimit der Organisation bei OpenAI (500 USD) ist **nicht erzwungen** (nur Alarm bei
80 %/100 %), und Auto-Reload ist an (bei 5 USD wird auf 100 USD aufgeladen). Die einzige harte Kostenbremse ist darum
**unser** `LERNAPP_AI_BUDGET_EUR` (zahlende Konten je Monat) mit `LERNAPP_AI_TRIAL_BUDGET_EUR` (Probekonten) und
`LERNAPP_AI_LIBRARY_BUDGET_EUR` (Bibliothek). Die Prüfung reserviert **vor** dem Aufruf des Anbieters in einer
`BEGIN IMMEDIATE`-Transaktion (laufende Summe + Reservierung ≤ Budget, sonst 503 `ai_budget_exhausted`); gleichzeitige
Anfragen – auch 4.000 – können das Budget nie gemeinsam überschreiten (Test
`test_reservation_happens_before_the_provider_and_blocks_the_budget_under_concurrency`). Dazu je Konto die Credits
(`app/credits.py`, Obergrenze je Anfrage reserviert) und die Rate-Limits `LERNAPP_AI_RATE_PER_MINUTE` (6) /
`LERNAPP_AI_RATE_PER_HOUR` (60).

**Servergröße.** CX23 (2 vCPU, 4 GB): 4 API-Prozesse à ~150–300 MB plus offene Fragen plus `jobs` (Chromium-Abgleiche)
plus Caddy. Ab etwa 2.000 gleichzeitig offenen KI-Fragen oder dauerhaft >70 % CPU (`docker stats`) auf **CX33 (4 vCPU,
8 GB)** wechseln: `UVICORN_WORKERS=8`, `API_MEMORY=3G`, `jobs` 2560M, `LERNAPP_JOB_WORKERS=3`. Ab ~4.000 offenen Fragen
mit viel gleichzeitigem Abgleich (Chromium) **CX43 (8 vCPU, 16 GB)**: `UVICORN_WORKERS=12`, `API_MEMORY=5G`,
`LERNAPP_JOB_WORKERS=4`. Die Entscheidung hängt am gemessenen Speicher je 1.000 offene Fragen (Tabelle) – vorher
`docker stats --no-stream` im Betrieb ansehen.

**Caddy.** `deploy/Caddyfile` setzt keine Verbindungsgrenze (`max_conns` nicht gesetzt = unbegrenzt) und lange Zeitlimits
(`response_header_timeout 10m`, `read/write 15m`); 4.000 offene Verbindungen sind für Caddy kein Problem, solange die
Dateideskriptoren reichen (Docker-Standard 1.048.576 für den Caddy-Container, nicht ändern).

**Dateideskriptoren.** Jede offene Frage = 1 Verbindung Caddy→App + 1 App→Anbieter (+ kurz SQLite). Der `app`-Container
hat jetzt `ulimits nofile 65536`; prüfen mit `docker compose exec app sh -c 'ulimit -n'`. Der Host (Ubuntu) erlaubt
Standard 1.048.576.

### Schalter in `deploy/.env` (alle optional)

| Schalter | Standard | Bedeutung |
| --- | --- | --- |
| `UVICORN_WORKERS` / `API_MEMORY` | 4 / 1536M | API-Prozesse und ihre Speichergrenze (2 je Kern) |
| `LERNAPP_AI_CONCURRENCY` | 5000 | gleichzeitige KI-Fragen je Prozess; darüber 503 `ai_overloaded` + `Retry-After: 3` (Notbremse) |
| `LERNAPP_AI_TIMEOUT_S` | 90 | Zeitlimit je Verbindung zum Anbieter |
| `LERNAPP_AI_DB_THREADS` | 8 | Threads je Prozess für die Datenbankschritte der KI-Fragen |
| `LERNAPP_AI_BUDGET_EUR` / `LERNAPP_AI_TRIAL_BUDGET_EUR` | 50 / 5 (heute 400 / 100 gesetzt) | harte Kostenbremse je Monat, zahlende Konten / Probekonten |
| `LERNAPP_AI_RATE_PER_MINUTE` / `_PER_HOUR` | 6 / 60 | Fragen je Konto |
| `LERNAPP_LIMIT_API_PER_MIN` | 600 | alle API-Anfragen je Konto und Prozess |
| `LERNAPP_LIMIT_REGISTER_IP` | 30/60 (Vorlage 300/60) | Registrierungen je Adresse (eduroam-NAT!) |

### Was bei Wachstum zu tun ist

1. **500 Tester (TestFlight):** nichts weiter; `LERNAPP_AI_TRIAL_BUDGET_EUR=200` setzen (Probekonten sind in der
   TestFlight-Phase die Regel) und täglich `python -m app.ai_backend`-Monatsbericht bzw. `docker stats` ansehen.
2. **1.000–2.000 Nutzer:** CX33, `UVICORN_WORKERS=8`, `API_MEMORY=3G`; `LERNAPP_AI_BUDGET_EUR` am erwarteten Verbrauch
   ausrichten (100 Credits = 0,90 EUR je Pro-AI-Konto und Monat als Obergrenze).
3. **5.000 Nutzer:** CX43 oder zwei Server (Caddy vor zwei App-Containern geht erst, wenn accounts.db nicht mehr SQLite ist –
   docs/SKALIERUNG-GROSS.md); OpenAI-Stufe prüfen (Tokens/Minute), ggf. zweites Modell in `LERNAPP_AI_ROUTES`.
4. **Immer:** vor Änderungen `tools/lasttest-ki.py` lokal laufen lassen (`--ai 2000 --normal 200`), Tabelle hier
   aktualisieren.

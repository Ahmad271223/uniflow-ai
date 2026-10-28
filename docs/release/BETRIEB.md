# Betrieb des gehosteten Dienstes (Hosting-Paket `deploy/`) – Entwurf, Stand 27.10.2026

Schritt für Schritt vom leeren VPS zum laufenden Studora-Dienst (`LERNAPP_MODE=hosted`): ein Server in der EU,
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
  Datenschutzerklärung (`[[Hosting-Anbieter]]`, `[[Serverstandort]]`), **Vertrag zur Auftragsverarbeitung**
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

# Start-Checkliste: den StudiNow-Dienst in Betrieb nehmen (30.10.2026)

Für den Inhaber. Schritt für Schritt vom leeren Server bis zum laufenden Dienst mit Konten, HTTPS, Mail und Backups
(`docs/PLAN-WEB-ZUERST-2026-10-30.md`, Stufe A). Du brauchst keine Programmierkenntnisse, nur ein Terminal (Windows:
PowerShell oder Windows-Terminal; Mac: Terminal) und etwa zwei Stunden plus Wartezeiten bei den Anbietern.

Die Technik ist fertig und geprüft (Abschnitt 15). Du steckst nur noch fünf Dinge ein: **Server, Domain, Mail-Anbieter,
Stripe-Schlüssel, KI-Schlüssel (Scaleway, AWS Bedrock, OpenAI; Abschnitt 5.4).** Stripe und die KI kannst du auch später nachtragen; der Dienst läuft ohne sie
mit Free-Tarif und 7-Tage-Probe.

Ausführliche Erklärungen zu jedem Befehl stehen in `docs/release/BETRIEB.md`; alle Variablen mit Erklärung in
`deploy/.env.example`. Diese Checkliste ist die kurze Fassung in Reihenfolge.

---

## 0. Vorher entscheiden und bereitlegen

| Was | Entscheidung / Quelle |
|---|---|
| Name und Domain | „StudiNow“ steht in der App; Domain muss dazu passen und frei sein (Plan, Abschnitt 4.4). Prüfen, ob der Name als Marke frei ist. |
| Dienst darf Uni-Passwörter halten? | Entschieden 30.10.: **ja**, mit Zustimmung je Nutzer in der Oberfläche (ist gebaut). Deshalb gehört Chromium ins Image (Abschnitt 14). |
| Bezahlen zum Start? | Entschieden 30.10.: **erst Free** mit 7 Tagen Probe; Stripe ist gebaut und wird eingeschaltet, sobald du die Schlüssel einträgst. |
| KI im Dienst? | Entschieden 30.10.: StudiNow-KI über deine Schlüssel (Pro AI); seit 05.11. als Mischung aus DeepSeek (Scaleway, EU), OpenAI und Claude Sonnet 5.5 (Bedrock, EU), Abschnitt 5.4. Ohne Schlüssel bleiben die KI-Funktionen sauber aus (503). |
| Passwort-Manager | Für Dienst-Geheimnis, Server-Zugang, Stripe- und KI-Schlüssel. Nichts davon in Notizen oder Chats. |

---

## 1. Server bestellen

**Größe für den Start: 2 vCPU, 4 GB RAM, 40 GB SSD** (z. B. Hetzner CX23 in Nürnberg/Falkenstein, IONOS VPS in
Deutschland). Begründung:

- `deploy/docker-compose.yml` startet drei Container: **app** (die API, zwei uvicorn-Prozesse, Grenze 768 MB),
  **jobs** (Hochschul-Abgleich mit Chromium, Wochentests, Löschfristen; ca. 300 MB plus je gleichzeitigem Abgleich ein
  Browser mit 300–500 MB bei `LERNAPP_JOB_WORKERS=2`, Grenze 1,75 GB) und **caddy** (unter 50 MB). Das
  Betriebssystem braucht unter 500 MB. Das passt in 4 GB. Die Trennung stammt aus dem Lasttest
  (`docs/LASTTEST-DIENST-2026-10-30.md`, Abschnitt 7): ein Browser-Abgleich nimmt der API sonst CPU und Speicher weg.
- Die Serverplanung in `docs/LIVE-BLOCKER-TEST-2026-10-25.md` („Hosting nach Nutzerzahl“) rechnet mit diesem Server
  bis etwa 1.000 registrierte Nutzer und 100 gleichzeitig.
- Das Image ist wegen Chromium rund 2 GB groß; mit Docker-Zwischenständen und Backups reichen 40 GB.
- **Lasttest mit 100 Konten und 1.000 Dateien: siehe Lasttest** (`docs/LASTTEST-DIENST-2026-10-30.md`). Ergebnis:
  die API trägt mit zwei Prozessen weit mehr als die erwarteten Anfragen; der Engpass ist der Abgleich durch den Dienst
  (höchstens 240 Starts je Stunde je Hochschule wegen `LERNAPP_UNI_GAP_S=15`, realistisch ~500 Konten mit
  Zugangsdaten je Hochschule). Wächst der Dienst darüber hinaus, ist der nächste Schritt 4 vCPU / 8 GB,
  `LERNAPP_JOB_WORKERS=4` und die Speichergrenze des Containers `jobs` auf 3584M; ein VPS lässt sich beim Hoster ohne
  Neuinstallation vergrößern.

Beim Bestellen:

1. **Standort EU** (Hoster und Standort kommen in die Datenschutzerklärung).
2. Betriebssystem **Debian 12** oder **Ubuntu 24.04 LTS**.
3. **SSH-Schlüssel hinterlegen**, kein Passwort-Login. Schlüssel erzeugen auf deinem Rechner:

```bash
ssh-keygen -t ed25519 -C "studora-server"
cat ~/.ssh/id_ed25519.pub        # diesen Text beim Hoster als SSH-Schlüssel eintragen
```

4. Firewall des Hosters (falls angeboten): nur **22, 80, 443** offen.
5. **Vertrag zur Auftragsverarbeitung** (AVV, Art. 28 DSGVO) in der Hoster-Konsole abschließen (meist ein Klick).

Du bekommst eine **IPv4-Adresse** (und meist eine IPv6-Adresse). Beide notieren.

---

## 2. Domain und DNS

1. Domain registrieren (z. B. `studinow.app`); der Dienst läuft auf einer Unterdomain, z. B. `app.studinow.app`.
2. Beim Domain-Anbieter zwei Einträge anlegen:
   - **A**-Eintrag: `app` → IPv4 des Servers
   - **AAAA**-Eintrag: `app` → IPv6 des Servers (nur, wenn der Server eine hat)
3. Prüfen (dauert nach dem Eintragen 5 Minuten bis einige Stunden):

```bash
dig +short app.studinow.app         # muss die Server-IP liefern
```

**Erst weitermachen, wenn das stimmt.** Caddy holt beim ersten Start ein Zertifikat von Let's Encrypt; zeigt der Name
noch nicht auf den Server, scheitert das, und Let's Encrypt zählt Fehlversuche (nach 5 pro Stunde Sperre).

Für die Mails (Abschnitt 5.4) legt dein Mail-Anbieter später noch SPF/DKIM-Einträge an, ebenfalls im DNS.

---

## 3. Server vorbereiten und Docker installieren

Anmelden und alles als `root` ausführen:

```bash
ssh root@<IPv4-des-Servers>
```

```bash
apt update && apt upgrade -y
apt install -y ca-certificates curl git ufw unattended-upgrades dnsutils
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker --version && docker compose version
```

Firewall und Zeitzone (Zeitpläne 08:00/15:00 und Löschfristen 04:00 gelten in deutscher Ortszeit):

```bash
ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw --force enable
timedatectl set-timezone Europe/Berlin
mkdir -p /srv/uniflow/backups && chmod 700 /srv/uniflow/backups
```

---

## 4. Repository auf den Server holen

Das Repository ist privat. Der Server bekommt einen eigenen Schlüssel, der nur lesen darf („Deploy Key“):

```bash
ssh-keygen -t ed25519 -N "" -C "studora-server" -f /root/.ssh/uniflow_deploy
cat /root/.ssh/uniflow_deploy.pub
```

Den ausgegebenen Text bei GitHub eintragen: Repository → **Settings → Deploy keys → Add deploy key**, nur Lesen
(„Allow write access“ **nicht** anhaken). Dann klonen:

```bash
printf 'Host github.com\n  IdentityFile /root/.ssh/uniflow_deploy\n  IdentitiesOnly yes\n' >> /root/.ssh/config
git clone -b develop git@github.com:<DeinKonto>/<Repository>.git /srv/uniflow/app
cd /srv/uniflow/app && git log --oneline -1
```

---

## 5. `deploy/.env` ausfüllen

```bash
cd /srv/uniflow/app/deploy
cp .env.example .env && chmod 600 .env
openssl rand -base64 32            # Ausgabe = Dienst-Geheimnis, sofort in den Passwort-Manager
nano .env                          # speichern: Strg+O, Enter; beenden: Strg+X
```

Die Datei ist in der Reihenfolge aufgebaut, in der du die Werte brauchst. Alles, was leer bleibt, nimmt den Standard.

### 5.1 Pflicht für den ersten Start

| Variable | Wert | Woher |
|---|---|---|
| `UNIFLOW_DOMAIN` | `app.studinow.app` | deine Unterdomain aus Abschnitt 2 |
| `UNIFLOW_ACME_EMAIL` | deine E-Mail | für Warnungen von Let's Encrypt; ohne Wert startet Caddy nicht |
| `LERNAPP_PUBLIC_URL` | `https://app.studinow.app` | dieselbe Domain mit `https://`, ohne Schrägstrich am Ende (Links in Mails, Rückkehr nach dem Stripe-Checkout) |
| `LERNAPP_ALLOWED_HOSTS` | `app.studinow.app` | dieselbe Domain (docker compose setzt sie ohnehin aus `UNIFLOW_DOMAIN`) |
| `LERNAPP_SECRET_KEY` | Ausgabe von `openssl rand -base64 32` | verschlüsselt die Hochschul-Zugangsdaten aller Konten. **Nie verlieren, nie ändern, nie ins Backup.** |

`LERNAPP_MODE=hosted`, `LERNAPP_FILES=stream`, `LERNAPP_HTTPS=1`, `LERNAPP_DATA_DIR`, `LERNAPP_LOG_DIR` stehen schon
richtig in der Vorlage – nicht ändern.

### 5.2 Mail (für den Start nötig)

Ohne Mail können Nutzer ihre Adresse nicht bestätigen und kein Passwort zurücksetzen. Anbieter mit SMTP, zum Beispiel
**Resend** (bis 3.000 Mails/Monat kostenlos), Brevo, Postmark oder Mailgun:

1. Konto beim Anbieter anlegen, Domain `studinow.app` dort hinzufügen.
2. Der Anbieter zeigt DNS-Einträge (SPF, DKIM, meist 2–3 TXT/CNAME) – beim Domain-Anbieter eintragen, dann beim
   Mail-Anbieter „Verify“ drücken.
3. SMTP-Zugangsdaten erzeugen (bei Resend: API-Schlüssel; Nutzer ist `resend`, Passwort der Schlüssel).
4. In `.env`:

| Variable | Wert |
|---|---|
| `LERNAPP_SMTP_HOST` | vom Anbieter, z. B. `smtp.resend.com` |
| `LERNAPP_SMTP_PORT` | `587` (oder `465`, wenn der Anbieter nur das anbietet) |
| `LERNAPP_SMTP_USER` / `LERNAPP_SMTP_PASSWORD` | vom Anbieter |
| `LERNAPP_MAIL_FROM` | `StudiNow <no-reply@studinow.app>` (Domain muss beim Anbieter verifiziert sein) |
| `LERNAPP_MAIL` | leer lassen (= `smtp`, sobald der Host gesetzt ist) |

Der Mail-Anbieter kommt in die Datenschutzerklärung (Abschnitt 11) und braucht einen AVV (Abschnitt 13).

### 5.3 Stripe (optional, jederzeit nachtragbar)

Im Stripe-Dashboard (stripe.com), zuerst im **Testmodus**:

1. **Produkte**: zwei Produkte mit je einem monatlichen Preis anlegen: StudiNow Plus 1,99 € und StudiNow Pro AI 3,99 €
   (Pro Connect gibt es seit dem 04.11.2026 nicht mehr, `docs/PREISLISTE.md`). Jede Preis-ID beginnt mit `price_`.
2. **Entwickler → API-Schlüssel**: geheimer Schlüssel (`sk_test_…`, später `sk_live_…`).
3. **Entwickler → Webhooks → Endpunkt hinzufügen**: Adresse `https://app.studinow.app/api/billing/stripe/webhook`,
   Ereignisse `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`. Das Signaturgeheimnis beginnt mit `whsec_`.
4. **Einstellungen → Kundenportal** einschalten (Kündigung, Wechsel, Rechnungen).

| Variable | Wert |
|---|---|
| `LERNAPP_STRIPE_SECRET_KEY` | `sk_test_…` / `sk_live_…` |
| `LERNAPP_STRIPE_WEBHOOK_SECRET` | `whsec_…` |
| `LERNAPP_STRIPE_PRICES` | `plus=price_…,pro_ai=price_…` |

Erst mit Test-Schlüsseln und Stripe-Testkarte (4242 4242 4242 4242) einen Abschluss durchspielen, dann Live-Schlüssel
und Live-Preise eintragen und den Webhook im Live-Modus noch einmal anlegen (eigenes `whsec_`).

### 5.4 StudiNow-KI: DeepSeek (EU), OpenAI, Claude Sonnet 5.5 (optional, jederzeit nachtragbar)

Stand 05.11.2026. Die KI mischt drei Anbieter nach Aufgabe (etwa 50 % DeepSeek, 25 % ChatGPT, 25 % Sonnet; schwere
Fälle an Sonnet). Begründung, Preise und Quellen: `docs/KI-MODELLMISCHUNG-2026-11-05.md`. Jeder Anbieter ist einzeln
optional; was fehlt, fällt aus der Mischung, die anderen übernehmen. Mit **einem** Anbieter läuft die KI schon.
Pro AI hat 100 Credits = höchstens 1 € KI-Kosten je Monat. Die Grenze ist hart: Vor jeder Anfrage wird ihre Obergrenze
reserviert.

**Konten, Schlüssel, Verträge:**

1. **Scaleway** (DeepSeek, Paris):
   - console.scaleway.com: Organisation und Projekt (Region fr-par) anlegen, **IAM → API keys → Secret Key**.
   - **Organisation → Verträge**: den AVV herunterladen und ablegen.
   - Ein Budget-Limit setzen.
   - DeepSeek **nie** über api.deepseek.com; der Dienst lehnt solche Adressen ab.
2. **AWS** (Claude Sonnet 5.5 über Bedrock, Frankfurt):
   - Ein Konto anlegen und in **Bedrock → Model access** (Region eu-central-1) den Zugang zu Claude Sonnet 5.5 anfragen.
   - Danach einen **Bedrock-API-Schlüssel** anlegen oder einen IAM-Nutzer nur mit `bedrock:InvokeModel*`.
   - Der DPA gilt über die AWS Service Terms. Einen Budget-Alarm setzen.
   - In der Konsole prüfen, dass das Modell über den **EU-Endpunkt** läuft (nicht „Global“).
3. **OpenAI** (platform.openai.com):
   - Ein Konto mit Zahlungsmittel einrichten: **API keys → Create new secret key** und ein Ausgabenlimit setzen.
   - Den **Data Processing Addendum** annehmen.
   - Empfohlen: beim Vertrieb ein Projekt mit **EU-Datenresidenz** beantragen und den Schlüssel aus diesem Projekt
     nehmen; die Freischaltung braucht ZDR oder eine geänderte Missbrauchsprüfung.

| Variable | Wert |
|---|---|
| `LERNAPP_DEEPSEEK_API_KEY` | Secret Key von Scaleway |
| `LERNAPP_DEEPSEEK_MODEL` | leer = `deepseek-v4.1-flash-1017` (liest Bilder); `deepseek-v4-flash-0731` ist günstiger und liest nur Text |
| `LERNAPP_ANTHROPIC_API_KEY` | Bedrock-API-Schlüssel (oder `AWS_ACCESS_KEY_ID` und `AWS_SECRET_ACCESS_KEY` setzen) |
| `LERNAPP_ANTHROPIC_REGION` / `LERNAPP_ANTHROPIC_MODEL` | leer = `eu-central-1` / `anthropic.claude-sonnet-5-5`; nur `eu-*` erlaubt |
| `LERNAPP_OPENAI_API_KEY` | `sk-…` |
| `LERNAPP_AI_MODEL` | OpenAI-Modell, z. B. `gpt-6-luna` |
| `LERNAPP_OPENAI_BASE_URL` | erst nach der Freischaltung der EU-Residenz: `https://eu.api.openai.com/v1` (die Preise rechnet der Dienst dann mit +10 %) |
| `LERNAPP_AI_DISABLED` | Notschalter, z. B. `deepseek`; danach `docker compose up -d` |
| `LERNAPP_AI_ROUTES` | leer lassen (Standardwege in `app/ai_router.py`); nur zum Feinjustieren |
| Preise | aus der Tabelle `app/ai_prices.py` (Stand `CHECKED`). Vor dem Start mit den Preislisten von OpenAI, Scaleway und AWS vergleichen. `LERNAPP_AI_PRICE_IN_EUR` / `_OUT_EUR` **leer lassen**: sie gälten für alle Modelle gleich. Ohne Preis für ein Modell sperrt der Dienst es (fail closed) |
| `LERNAPP_AI_BUDGET_EUR` / `LERNAPP_AI_USER_BUDGET_EUR` | Monatsgrenze gesamt (Standard 50) und je Konto (Standard 2); erreicht = Sperre bis zum nächsten Monat |
| `LERNAPP_AI_TRIAL_BUDGET_EUR` | Eigenes Monatsbudget für alle Probekonten zusammen (Standard 5), zusätzlich zum Gesamtbudget: die Probe verbraucht nie das Budget zahlender Konten. StudiNow-KI gibt es nur mit bestätigter E-Mail-Adresse (403 `email_unverified`) |
| `LERNAPP_AI_LIBRARY_BUDGET_EUR` / `LERNAPP_AI_LIBRARY_PREP_PER_DAY` | Eigenes Monatsbudget der Bibliothek für die fertigen Wochenfragen (Standard 20 €, zusätzlich zum Gesamtbudget; erreicht = 429 `ai_library_budget_exhausted` für neue Wochen) und neue Wochen je Konto und Tag (Standard 10). Siehe `docs/BIBLIOTHEK-WOCHENFRAGEN.md` |

**Nach dem Start prüfen:**

- Eine Frage im Web stellen.
- Als Inhaber `GET /api/billing/ai-usage` aufrufen. `by_provider` zeigt die Verteilung und die Kosten je Anbieter.
- Auf Scaleway nachsehen, ob die Nutzung im Strom ankommt: In `/api/billing/ai-costs` müssen die Tokens größer als 0
  sein. Fehlt die Nutzung, rechnet der Dienst die Reservierung ab.

### 5.5 Registrierungen je IP (Hochschulnetz)

Der Dienst zählt Registrierungen je Client-IP (`app/accounts.py`, Grenze `register_ip`); im Code stehen 30 je Stunde.
Hinter eduroam, im Hörsaal oder in der Bibliothek teilen sich aber hunderte Geräte wenige Adressen (NAT) – nach dem
ersten Hörsaal, in dem jemand die App vorstellt, bekämen alle weiteren „Zu viele Versuche“ (429). Die Vorlage setzt
deshalb **`LERNAPP_LIMIT_REGISTER_IP=300/60`** (300 je Stunde, Lasttest Empfehlung 3). So lassen; in den ersten Wochen
beobachten, ob in `docker compose logs app` oder im Zugriffsprotokoll 429 bei `/api/account/register` auftauchen – dann
den ersten Wert erhöhen (`600/60`), `docker compose up -d` genügt. Missbrauch bremsen weiterhin die Grenze je
E-Mail-Adresse, die Bestätigungsmail und das Passwort-Hashing. Nur einen zweiten Wert (Minuten) ändern, wenn du weißt,
warum.

### 5.6 Rest

Google-/Apple-Anmeldung, App-Store-Kaufprüfung, Zeitfenster (`LERNAPP_SYNC_TIMES=08:00,15:00`), Arbeiter
(`LERNAPP_JOB_WORKERS=2`), Löschfristen (`14`/`90` Tage): Standardwerte lassen. Die Löschfristen müssen zur
Datenschutzerklärung passen – wer sie ändert, ändert beides. `LERNAPP_JOBS` hat mit Compose keine Wirkung: der
API-Container bekommt in `docker-compose.yml` fest `off`, der Container `jobs` übernimmt Abgleich, Wochentests und
Löschfristen (Abschnitt 1).

---

## 6. Starten

```bash
cd /srv/uniflow/app/deploy
docker compose config -q           # keine Ausgabe = .env und docker-compose.yml stimmig
docker compose up -d --build       # baut das Image (5–10 Minuten, lädt Chromium), startet app, jobs und Caddy
docker compose ps                  # app: "healthy" (nach ca. 30 s), jobs: "healthy" (nach ca. 60 s), caddy: "running"
docker compose logs jobs           # eine Zeile "[jobs] gestartet: 2 Arbeiter, Zeitplan 08:00, 15:00 ..."
docker compose logs -f caddy       # Zertifikat: "certificate obtained successfully"; Strg+C beendet nur die Anzeige
```

Sagt `docker compose config` „UNIFLOW_DOMAIN ist leer“ oder „UNIFLOW_ACME_EMAIL fehlt“: `.env` liegt nicht in
`deploy/` oder die Zeile ist leer.

---

## 7. Erster Test im Browser (eigener Rechner)

| Aufruf | Erwartung |
|---|---|
| `http://app.studinow.app` | leitet auf `https://…/login` um, Schloss-Symbol im Browser |
| `https://app.studinow.app/login` | Anmeldeseite |
| `https://app.studinow.app/datenschutz`, `/impressum`, `/nutzungsbedingungen`, `/konto-loeschen` | die Rechtstexte (noch mit Platzhaltern, Abschnitt 13) |
| `https://app.studinow.app/api/account/info` | eine Zeile JSON mit `"hosted":true` |

Dann **registrieren** mit deiner eigenen E-Mail: Bestätigungsmail kommt an (sonst Abschnitt 12), Link klicken,
anmelden. In den Einstellungen die Hochschule wählen, Zustimmung zum Abgleich geben, Zugangsdaten eintragen, „Jetzt
abgleichen“. Dabei auf dem Server zusehen:

```bash
docker compose logs -f jobs        # Zeilen "[jobs] ..." zeigen den Abgleich (läuft im Container jobs, nicht in app)
docker stats --no-stream           # Speicher des Containers uniflow-jobs während des Abgleichs (Chromium)
```

Außerdem einmal „Passwort vergessen“ auf der Anmeldeseite: Mail mit Link muss kommen.

---

## 8. Dein Admin-Konto

Dein registriertes Konto zum Admin machen (nur über die Kommandozeile, nie über die Oberfläche):

```bash
cd /srv/uniflow/app/deploy
docker compose exec app python -m app.accounts list                       # alle Konten
docker compose exec app python -m app.accounts role <deine-mail> admin    # Rolle setzen
```

Weitere Befehle, die du später brauchst:

```bash
docker compose exec app python -m app.accounts plan <mail> pro_ai 2027-03-31   # Tarif von Hand (z. B. Tester), bis Datum
docker compose exec app python -m app.accounts reset-token <mail>              # Notfall-Reset-Link ohne Mail: https://app.studinow.app/login?reset=<TOKEN>
docker compose exec app python -m app.retention --dry-run                      # zeigt, was die Löschfristen löschen würden
```

`exec app` und `exec jobs` sind gleichwertig: beide Container sehen dieselben Daten (`/data`) und Protokolle (`/logs`).

---

## 9. Backups einschalten und einmal zurückspielen

Das Backup läuft **auf dem Server außerhalb des Containers**, täglich 03:30, 14 Tage Aufbewahrung. Es enthält alle
Datenbanken (konsistent, der Dienst läuft weiter) und Nutzerdateien; **nicht** das Dienst-Geheimnis (das steht in
`.env` und im Passwort-Manager), nicht die Browser-Sitzungen.

```bash
/srv/uniflow/app/deploy/backup.sh                       # einmal von Hand: "Backup geschrieben: ..."
ls -lh /srv/uniflow/backups
cp /srv/uniflow/app/deploy/uniflow-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now uniflow-backup.timer
systemctl list-timers uniflow-backup.timer              # nächster Lauf 03:30
```

**Außer Haus kopieren** – ein Server allein ist kein Backup. Günstig: Hetzner Storage Box (ab ca. 4 €/Monat) per
`rclone` oder `scp`; die passende Zeile steht als Kommentar am Ende von `backup.sh` (einkommentieren, Ziel eintragen).
Der Zielspeicher muss in der EU liegen; die Archive enthalten personenbezogene Daten.

**Wiederherstellung einmal üben** (jetzt, solange nur dein Testkonto da ist; danach monatlich):

```bash
cd /srv/uniflow/app/deploy
docker compose stop app jobs                             # beide Container, die /data benutzen
ls /srv/uniflow/backups                                  # Archiv aussuchen
docker run --rm -v uniflow_uniflow-data:/data -v /srv/uniflow/backups:/backups:ro alpine sh -c \
  'rm -rf /data/* && tar -xzf /backups/<Archiv>.tar.gz -C /data --strip-components=1 && chown -R 1000:1000 /data'
docker compose start app jobs
docker compose exec app python -m app.accounts list      # deine Konten sind wieder da
```

Im Browser anmelden: dein Passwort von vor dem Backup funktioniert. Wichtig: `.env` muss denselben
`LERNAPP_SECRET_KEY` haben wie zur Zeit des Backups, sonst müssen alle Nutzer ihre Hochschul-Zugangsdaten neu eingeben
(Konten und Notizen bleiben trotzdem nutzbar).

---

## 10. Updates einspielen

Vor jedem Update ein Backup (`backup.sh`). Dann:

```bash
cd /srv/uniflow/app && git pull
cd deploy && docker compose up -d --build       # baut neu, tauscht app und jobs; Caddy und Zertifikat bleiben
docker compose ps && docker compose logs --tail=50 app jobs
docker image prune -f                           # alte Images löschen (Platz)
```

Ein laufender Abgleich bekommt beim Tausch noch 25 Sekunden, dann wird er als „Abgebrochen (Dienst gestoppt)“
markiert und beim nächsten Zeitfenster nachgeholt (`docker compose logs jobs` zeigt die betroffenen Job-Nummern).
Änderungen an `.env` gelten nach `docker compose up -d` (ohne `--build`).

Für das Betriebssystem sorgt `unattended-upgrades` (Sicherheitsupdates automatisch); alle paar Monate einmal
`apt update && apt upgrade -y && reboot`.

---

## 11. Logs lesen

```bash
cd /srv/uniflow/app/deploy
docker compose logs --tail=200 app          # API: Anfragen-Fehler mit Traceback, "[mail]" Versandfehler
docker compose logs --tail=200 jobs         # "[jobs]" Abgleiche und Wochentests, "[retention]" Löschfristen, Start/Stopp des Runners
docker compose logs --tail=100 caddy        # Zertifikat, Verbindungsfehler zur App
docker compose exec app sh -c 'tail -n 20 /logs/access/access-$(date +%F).log'    # Zugriffsprotokoll (14 Tage)
docker compose exec app tail -n 20 /logs/retention.log                            # eine Zeile je Löschlauf (täglich 04:00)
docker compose exec app sh -c 'tail -n 30 /data/users/<Konto-ID>/logs/sync.log'  # Abgleich eines Kontos (ID aus accounts list)
docker compose exec app tail -n 20 /logs/mail.log                                 # Mailversand und Fehler (Registrierung, Passwort vergessen, Bestätigung erneut senden) – EIN zentrales Protokoll für alle Konten
docker compose exec jobs cat /logs/jobs.heartbeat                                 # Lebenszeichen des Job-Runners (Zeitstempel, alle 10 s neu)
```

Caddy schreibt bewusst kein Zugriffsprotokoll (Datenschutz, die App führt ihr eigenes mit Frist). Zur Fehlersuche
vorübergehend im `Caddyfile` `output discard` durch `output stderr` ersetzen und `docker compose restart caddy`.

---

## 12. Wenn etwas nicht geht

| Symptom | Ursache und Maßnahme |
|---|---|
| `docker compose config` bricht ab: „UNIFLOW_DOMAIN ist leer“ / „UNIFLOW_ACME_EMAIL fehlt“ | `.env` fehlt in `deploy/` oder Zeile leer. Ausfüllen, erneut. |
| Browser: „Verbindung nicht sicher“, Caddy-Log „obtaining certificate … failed“ | DNS zeigt noch nicht auf den Server (`dig +short app.studinow.app`), oder Port 80/443 zu (`ufw status`, Hoster-Firewall). Beheben, `docker compose restart caddy`. Nach 5 Fehlversuchen wartet Let's Encrypt eine Stunde. |
| `docker compose ps`: app bleibt „unhealthy“ / startet neu | `docker compose logs app`. Häufig: `LERNAPP_SECRET_KEY muss 32 Byte …` (Wert falsch kopiert; neu erzeugen, solange noch keine Zugangsdaten gespeichert sind). |
| `docker compose ps`: jobs „unhealthy“ oder „restarting“ | `docker compose logs jobs`. Der Healthcheck prüft nur das Lebenszeichen `/logs/jobs.heartbeat` (muss jünger als 2 Minuten sein). Steht dort „ein Thread ist beendet“ oder ein Traceback: `docker compose restart jobs`; derselbe Fehler wie bei app, wenn `LERNAPP_SECRET_KEY` falsch ist. Läuft `jobs` nicht, bleiben Abgleiche „wartet (Platz …)“ und die Löschfristen laufen nicht. |
| Registrierung meldet „Zu viele Versuche“ (429), obwohl nur wenige Leute registrieren | Viele Geräte hinter einer Adresse (eduroam, Hörsaal). `LERNAPP_LIMIT_REGISTER_IP` in `.env` erhöhen (Abschnitt 5.5), `docker compose up -d`. Der Zähler läuft nach einer Stunde von selbst ab. |
| Seite lädt, aber „Unbekannter Hostname“ (421) | `LERNAPP_ALLOWED_HOSTS` passt nicht zur Domain, unter der du aufrufst (z. B. `www.`). Namen mit Komma ergänzen, `docker compose up -d`. |
| Keine Bestätigungs-/Reset-Mail | `docker compose exec app tail -n 20 /logs/mail.log`. Steht dort die ganze Mail: `LERNAPP_SMTP_HOST` leer (Modus `log`). Steht dort „authentication failed“: Zugangsdaten. Mail im Spam: SPF/DKIM beim Anbieter noch nicht verifiziert. Notfall: `app.accounts reset-token`. |
| Abgleich schlägt fehl, „browser“/„chromium“ im Log | Speicher: `docker stats` (Container `uniflow-jobs`); `LERNAPP_JOB_WORKERS=1` setzen oder Server vergrößern. Fehlerbilder liegen unter `/data/users/<ID>/logs/`. |
| Abgleich bleibt „wartet (Platz 1)“ | Container `jobs` läuft nicht (`docker compose ps`). Die API legt die Jobs nur an; abgearbeitet werden sie in `jobs`. |
| Stripe: Abschluss klappt, Tarif erscheint nicht | Webhook-Adresse oder `whsec_` falsch (Stripe-Dashboard → Webhooks → Zustellversuche zeigen 400). Testmodus und Livemodus haben getrennte Schlüssel und Webhooks. |
| KI-Funktionen melden „nicht eingerichtet“ (503) | `LERNAPP_OPENAI_API_KEY` oder `LERNAPP_AI_MODEL` leer; nach dem Eintragen `docker compose up -d`. Bei „Token-Preise fehlen“ (503 `ai_not_configured_prices`): `LERNAPP_AI_PRICE_IN_EUR` und `LERNAPP_AI_PRICE_OUT_EUR` eintragen. Bei „Budget erreicht“: `LERNAPP_AI_BUDGET_EUR` erhöhen oder bis Monatsanfang warten. |
| Platte voll | `df -h /`, `docker system df`, `docker image prune -f`; Backups außer Haus und `BACKUP_KEEP_DAYS` prüfen. |
| Löschfristen laufen nicht (keine tägliche Zeile in `retention.log`) | Sie laufen im Container `jobs` (`docker compose ps jobs` muss „healthy“ zeigen). Ohne Compose: `LERNAPP_JOBS` darf im API-Prozess nicht `off` sein, oder `python -m app.jobs` getrennt starten. |
| Server kaputt / gehackt | Neuer Server, Abschnitte 3–6, dann Wiederherstellung (Abschnitt 9) mit demselben `LERNAPP_SECRET_KEY`. Danach alle Zugangsdaten (SSH, Stripe, KI-Anbieter, Mail) erneuern. |

---

## 13. Was du zusätzlich erledigen musst (kein Code)

1. **Rechtstexte**: Platzhalter `[[…]]` in `docs/release/IMPRESSUM.md`, `DATENSCHUTZ.md`, `NUTZUNGSBEDINGUNGEN.md`,
   `KONTO-LOESCHEN.md` ausfüllen (Name, Anschrift, E-Mail, Telefon, Domain, Hoster, Standort, Mail-Anbieter, Datum,
   Aufsichtsbehörde). `tests/test_release_texts.py` listet, was fehlt. Dann **anwaltlich prüfen lassen** – vor dem
   ersten fremden Nutzer. Der Dienst liefert die Dateien unter `/datenschutz` usw. aus; nach dem Ausfüllen
   `git pull` und `docker compose up -d --build` (oder eigenen Ordner als Volume und `LERNAPP_LEGAL_DIR`).
2. **Auftragsverarbeitung (AVV)** mit dem Hoster **und** dem Mail-Anbieter abschließen.
   - Bei Stripe den DPA im Dashboard akzeptieren.
   - Für die StudiNow-KI je einen Vertrag mit den drei KI-Anbietern abschließen (Abschnitt 5.4):
     - Scaleway: AVV unter Organisation → Verträge;
     - AWS: DPA über die Service Terms;
     - OpenAI: Data Processing Addendum.
   - Alle in der Datenschutzerklärung nennen (Abschnitte 8c, 11, 12).
3. **Anfrage an LUH und Hildesheim**: Der Dienst meldet sich mit Nutzer-Zugangsdaten bei Stud.IP/Learnweb an. Die
   Entscheidung vom 30.10. verlangt eine parallele Anfrage an die Hochschulen (`docs/ANFRAGE-STUDIP-ZUGANG.md` als
   Entwurf für die LUH, `elearning@uni-hannover.de`; für Hildesheim das Rechenzentrum). Bis zur Antwort: Abgleich
   vorsichtig lassen (`LERNAPP_UNI_PARALLEL=2`, `LERNAPP_UNI_GAP_S=15` sind die Standardwerte).
4. **Monitoring von außen**: kostenloser Uptime-Check (UptimeRobot o. ä.) auf `https://app.studinow.app/login`,
   alle 5 Minuten, Benachrichtigung per Mail oder Push.
5. **Stripe live schalten** (Abschnitt 5.3) und **Markenprüfung „StudiNow“** vor den Store-Einträgen.
6. **Backup-Ziel außer Haus** einrichten (Abschnitt 9).

---

## 14. Chromium im Image – Abwägung

Der Hochschul-Abgleich im Dienst (`app/studip_sync.py`, `app/hildesheim.py`, `app/qis.py`) steuert mit Playwright
einen echten Chromium-Browser: Anmeldung am WebSSO, Kurslisten, Notenspiegel. Deshalb installiert `deploy/Dockerfile`
Chromium samt Systembibliotheken (`playwright install --with-deps chromium`).

| | mit Chromium (heute) | ohne Chromium |
|---|---|---|
| Image | ca. 2 GB | ca. 0,5 GB |
| RAM | +300–500 MB je gleichzeitigem Abgleich | nur die App (ca. 300 MB) |
| Was geht | Abgleich durch den Dienst (Entscheidung 30.10.: ja), Notenspiegel | nur Upload von Hand; Windows-App und später iPad gleichen selbst ab |
| Server | 2 vCPU / 4 GB mit `LERNAPP_JOB_WORKERS=2` | 1 vCPU / 2 GB würde reichen |

Empfehlung: **so lassen.** Die 1,5 GB Plattenplatz sind beim 40-GB-Server egal, und der Dienst-Abgleich ist die
Grundlage der Web-Version für iPad und Mac. Wer Entscheidung 1 doch zurücknimmt, streicht die Zeile `playwright install`
im Dockerfile und kann auf 2 GB RAM gehen.

---

## 15. Was am 30.10.2026 geprüft wurde (Cloud-Sitzung)

- `docker compose config` mit Test-`.env` stimmig; fehlende `UNIFLOW_DOMAIN`/`UNIFLOW_ACME_EMAIL` bricht mit Hinweis ab.
- `caddy validate` (Image `caddy:2`): „Valid configuration“. HTTP→HTTPS automatisch, HSTS, `nosniff`, keine doppelte
  Content-Security-Policy (die setzt die App), Upload-Grenze 320 MB, Webhook-Pfad ungebremst und ungecacht.
- Container aus dem Dockerfile (ohne die apt- und Chromium-Schicht, die der Sandbox-Proxy sperrte; der Rest identisch):
  Start als Nutzer `uniflow` (UID 1000), nach 7 s `healthy`, `GET /api/account/info` 200 mit `"hosted":true`,
  `GET /` 302 → `/login`, `/login` 200 mit CSP/X-Frame-Options/Referrer-Policy von der App, fremder Host 421,
  `/datenschutz` 200, `/api/account/me` ohne Sitzung 401, Registrierung 201, `app.accounts role … admin`.
- `backup.sh` dreimal gegen den laufenden Container: Archiv mit `accounts.db` und Nutzerdatenbank,
  `PRAGMA integrity_check = ok` für jede Kopie, `secret.key` nicht enthalten, 14-Tage-Aufräumen entfernt ein altes
  Archiv. **Behobener Fehler:** die Prüfung `tar | grep -q` meldete mit `pipefail` ein vollständiges Archiv als
  unvollständig (Exit 1) – jetzt wird die Liste erst ganz gelesen.
- Wiederherstellung: Archiv in einen frischen Datenordner, zweiter Container mit demselben Geheimnis, Konto wieder da,
  Anmeldung mit altem Passwort 200.
- `tests/test_deploy.py` grün (16 Tests; jede `LERNAPP_*`-Variable aus `app/` steht in `.env.example`, keine echten
  Schlüssel in der Vorlage).
- **Nicht hier prüfbar:** Chromium im Container (Download gesperrt; am 27.10. auf Docker Desktop geprüft: 1,99 GB,
  Chromium startet als `uniflow`), echtes Zertifikat, Mailversand, Stripe- und OpenAI-Aufrufe – das sind die Tests in
  Abschnitt 7 auf dem echten Server.

### 15a. Nachtrag 01.11.2026 (Betriebsfunde aus dem Lasttest umgesetzt)

- API mit `uvicorn --workers 2` (Dockerfile) und Jobs als eigener Container `jobs` (`python -m app.jobs`, gleiche
  Volumes und `.env`; API fest `LERNAPP_JOBS=off`). `python -m app.jobs` beendet sich auf `docker stop` geordnet
  (laufende Jobs 25 s abwarten, Rest als abgebrochen markieren) und schreibt alle 10 s das Lebenszeichen
  `/logs/jobs.heartbeat`, das der Healthcheck (`python -m app.jobs --healthcheck`) prüft.
- `LERNAPP_LIMIT_REGISTER_IP=300/60` in der Vorlage (Abschnitt 5.5).
- Zeitplan (`jobs.schedule_due`): ein Tresor-Durchlauf und eine Datenbankverbindung je Zeitfenster statt einer je Konto.
- `mail.log` ist ein zentrales Protokoll (`/logs/mail.log`), auch für Mails aus dem Kontext eines Kontos.
- Geprüft in der Cloud-Sitzung: `docker compose config -q` mit Test-`.env` (drei Dienste, `jobs` mit Healthcheck,
  `LERNAPP_JOBS=off` nur bei app), `tests/test_deploy.py`, `tests/test_hosted_sync.py`, `tests/test_mail.py`.
  **Nicht geprüft:** echter Start mit zwei uvicorn-Prozessen und getrenntem Jobs-Container gegen eine `accounts.db`
  (Prozess-Konkurrenz auf WAL-Dateien) – beim ersten Start auf dem Server `docker compose ps` (alle drei „healthy“/
  „running“) und einen Abgleich nach Abschnitt 7 beobachten.

---

## 16. Kosten je Monat (grob, netto)

| Posten | Betrag | Hinweis |
|---|---|---|
| Server 2 vCPU / 4 GB | 5–6 € | Hetzner CX23 o. ä.; 4 vCPU / 8 GB ca. 12–15 € |
| Domain | 1–2 € | Jahrespreis umgerechnet |
| Backup außer Haus | 3–4 € | Hetzner Storage Box 1 TB |
| Mail | 0 € | Resend bis 3.000 Mails/Monat; danach ca. 20 €/Monat |
| Monitoring | 0 € | UptimeRobot Free |
| Stripe | 0 € fest | je Zahlung ca. 1,5 % + 0,25 € (EU-Karten); bei 1,99 € also ca. 0,28 € je Abo-Monat |
| KI (Pro AI: Scaleway, OpenAI, AWS Bedrock) | 0 € ohne Nutzer | nach Verbrauch, typisch etwa 0,5 Cent je Anfrage in der Mischung (`docs/KI-MODELLMISCHUNG-2026-11-05.md`); je Pro-AI-Konto höchstens 1 € (100 Credits, harte Grenze); `LERNAPP_AI_BUDGET_EUR=50` ist die Obergrenze für alle zusammen |
| Anwalt für Rechtstexte | einmalig | nach Aufwand |
| **Summe ohne KI und Anwalt** | **rund 10–12 €** | |

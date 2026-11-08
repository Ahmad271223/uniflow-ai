# Server-Umzug: app.studinow.app von Helsinki (CX23) nach Nürnberg/Falkenstein (CX43) – 08.11.2026

Für den Inhaber. Schritt für Schritt, ohne Programmierkenntnisse; du brauchst das Terminal auf dem Mac, die
Hetzner-Konsole im Browser und den Zugang zur DNS-Verwaltung der Domain `studinow.app`. Dauer insgesamt etwa
45–60 Minuten, davon **Ausfallzeit nur wenige Minuten** (Abschnitt 6).

Was passiert: Ein neuer, größerer Server wird vorbereitet, der Code und die Konfiguration kommen hinüber, das
Docker-Image wird dort vorab gebaut. Dann wird der alte Dienst kurz angehalten, alle Daten (Konten, Nutzerordner,
Protokolle, Zertifikat) werden 1:1 kopiert und geprüft, der neue Dienst startet, und du stellst den DNS-Eintrag um.
Der alte Server wird **nicht gelöscht**, nur gestoppt – 7 Tage Reserve.

Das Skript `tools/server-umzug.sh` macht alles außer der Hetzner-Konsole und dem DNS-Eintrag. Es läuft auf deinem
Mac und spricht per SSH (Schlüssel `~/.ssh/studinow_server`) mit beiden Servern. Es zeigt nie den Inhalt der `.env`
(Passwörter, Schlüssel) an. Jeder Schritt kann wiederholt werden; bei einem Fehler bricht es ab und sagt, wie es
weitergeht. Nachkontrolle: `tools/server-umzug-pruefen.sh`.

---

## 1. Vorher (5 Minuten)

- Aktuell: `https://app.studinow.app` = Hetzner **CX23 Helsinki**, IPv4 `2.29.122.54` (`docs/UEBERGABE-2026-11-06.md`, Abschnitt 5).
- Ziel: **CX43** (8 vCPU, 16 GB RAM, 160 GB SSD, ca. 16 €/Monat) in **Nürnberg** oder **Falkenstein** – ausgelegt
  auf 4.000 Nutzer gleichzeitig. Kleinere Variante: **CX33** (4 vCPU, 8 GB, ca. 8 €/Monat). Ein späteres Vergrößern
  (Rescale) ist bei Hetzner möglich, ein Standortwechsel nicht – deshalb jetzt der Umzug.
- Zeitpunkt: früher Morgen oder spät abends (wenig Nutzer); nicht während der Wochentest-Zeiten 08:00/15:00.
- **DNS-TTL vorab senken:** Beim Anbieter, bei dem `studinow.app` verwaltet wird (Registrar oder, falls die Domain dort
  eingebunden ist, Netlify-DNS – nachsehen, wo die Einträge `A app` und die STRATO-Mail-Einträge liegen), die TTL des
  Eintrags `A app` auf **60 Sekunden** stellen (oft „1 Minute“ oder „niedrigste“). Am besten **einen Tag vorher**, mindestens
  aber eine Stunde; dann merken Browser und Apps den Wechsel innerhalb einer Minute.
- Auf dem Mac prüfen, dass der Code-Stand stimmt, der auf den neuen Server soll (Standard: der aktuelle HEAD im Ordner
  `uniflow-ai`; der Zweig `server/lastfest` mit 4 API-Prozessen und Speichergrenzen kann per `--ref server/lastfest`
  gewählt werden, sobald er fertig ist):

```bash
cd ~/uniflow-ai && git status --short && git log --oneline -1
```

## 2. Neuen Server in der Hetzner-Konsole anlegen (5 Minuten)

1. https://console.hetzner.cloud → Projekt mit dem bisherigen Server öffnen → **Server hinzufügen**.
2. **Standort:** Nürnberg (nbg1) oder Falkenstein (fsn1) – beides Deutschland.
3. **Image:** Ubuntu **24.04** (nicht 22.04, nicht 26.04).
4. **Typ:** Shared vCPU, **CX43** (8 vCPU / 16 GB) – oder CX33 (4 / 8), wenn es erst einmal reichen soll.
5. **Netzwerk:** IPv4 **und** IPv6 lassen (öffentliche IPv4 wird gebraucht).
6. **SSH-Key:** `studinow_server` auswählen. Fehlt der Schlüssel im Projekt: „SSH-Key hinzufügen“ und den Inhalt
   von `~/.ssh/studinow_server.pub` einfügen (auf dem Mac anzeigen: `cat ~/.ssh/studinow_server.pub`; das ist der
   **öffentliche** Teil, der darf gezeigt werden – nie die Datei ohne `.pub`).
7. Volumes, Firewalls, Backups, Placement Groups, Labels, Cloud config: leer lassen (die Firewall setzt das Skript mit `ufw`;
   Hetzner-Backups kannst du später für ca. 20 % Aufpreis dazuschalten).
8. **Name:** `studinow-nbg` → **Erstellen & kaufen**. Nach ca. 30 Sekunden steht die **IPv4 des neuen Servers** in der
   Übersicht – notieren, das ist `NEU_IP`.

## 3. Trockenlauf (1 Minute)

Zeigt nur, was passieren würde – keine Verbindung, keine Änderung:

```bash
cd ~/uniflow-ai && tools/server-umzug.sh --dry-run 2.29.122.54 NEU_IP
```

## 4. Vorbereitung ohne Ausfall: Schritte 1–3 (15–25 Minuten, Dienst läuft weiter)

```bash
tools/server-umzug.sh --bis-schritt 3 2.29.122.54 NEU_IP
```

Das Skript prüft beide Server, richtet den neuen ein (Pakete, Docker, Firewall 22/80/443, Zeitzone Berlin,
Backup-Ordner, automatische Sicherheitsupdates), kopiert den Code (`git archive`) und von ALT die Konfiguration
(`.env`, `docker-compose.override.yml`, `apple-certs`) und baut das Image. Beim ersten Verbinden fragt SSH einmal nach dem
Fingerabdruck des neuen Servers – das macht das Skript automatisch (`accept-new`).

**Größerer Server, mehr API-Prozesse:** Die `.env` kommt 1:1 vom alten Server und steht dort auf 2 Prozesse. Für den
CX43 laut `deploy/.env.example` (Abschnitt 8b) gleich mitgeben:

```bash
tools/server-umzug.sh --bis-schritt 3 --env-setzen UVICORN_WORKERS=6 --env-setzen API_MEMORY=2G 2.29.122.54 NEU_IP
```

(CX33: `UVICORN_WORKERS=2`, `API_MEMORY=768M` – also ohne `--env-setzen`. Hat der Zweig `server/lastfest` eigene
Standardwerte, gilt dessen Anleitung; mit `--ref server/lastfest` kommt genau dieser Stand auf den Server.)

Dauert das Bauen länger als 10 Minuten oder bricht die Verbindung ab: Befehl einfach noch einmal ausführen.

## 5. Der Wechsel: Schritte 4–6 (Ausfallzeit beginnt)

```bash
tools/server-umzug.sh --ab-schritt 4 2.29.122.54 NEU_IP
```

Ablauf, Schritt 4 (**das ist die Pause**, erfahrungsgemäß 2–5 Minuten bei wenigen GB Daten):

1. Sicherung auf ALT (`backup.sh`, Dienst läuft dabei noch).
2. Rückfrage `Weiter? [ja/N]` – mit `ja` beginnt die Pause. ALT: `docker compose stop app jobs`. Caddy bleibt an,
   Nutzer sehen bis zum Wechsel eine kurze Fehlerseite statt einer Endlos-Wartezeit.
3. Volumes `uniflow-data` (Konten, Nutzerordner), `uniflow-logs` und `caddy-data` (Zertifikat) als tar-Strom
   ALT → NEU; je Volume werden Dateizahl und Bytes verglichen, zusätzlich die Prüfsumme der `accounts.db`.
   Stimmt etwas nicht, bricht das Skript ab, **bevor** NEU startet – ALT ist unverändert (Rückweg Abschnitt 8).
4. NEU: `docker compose up -d`, warten bis `uniflow-app` **healthy**, interne Abfrage von `/api/account/info`,
   Zahl der Konten anzeigen.

Schritt 5 (**DNS – das machst du**): Das Skript zeigt den Hinweis und wartet.

- Beim Domain-Anbieter den Eintrag **`A` · Name `app` · Wert `NEU_IP` · TTL 60** setzen (alten Wert `2.29.122.54`
  **ersetzen**). Gibt es einen `AAAA`-Eintrag (IPv6) für `app`: auf die IPv6 des neuen Servers ändern oder löschen.
- Das Skript fragt alle 30 Sekunden `dig +short app.studinow.app @1.1.1.1` ab (höchstens 60 Minuten; `--dns-wartezeit`),
  bis `NEU_IP` kommt. Danach prüft es `https://app.studinow.app/api/account/info` direkt gegen den neuen Server und meldet
  **ERFOLG**. Weil das Zertifikat mitgezogen wurde, muss Caddy nichts Neues bei Let's Encrypt holen.
- **Ausfallzeit endet hier:** Nutzer, deren Geräte den alten Eintrag noch kennen (bis TTL abgelaufen), landen bis dahin auf
  ALT, wo Caddy läuft, aber die App gestoppt ist (Fehlerseite). Mit TTL 60 ist das nach einer Minute vorbei; mit alter
  TTL (oft 3600) bis zu einer Stunde für einzelne Nutzer. Deshalb die TTL vorher senken (Abschnitt 1).

Schritt 6: ALT `docker compose down` (Daten bleiben), auf NEU den täglichen Backup-Timer (03:30) einrichten, alte
Sicherungen aus `/srv/uniflow/backups` nach NEU kopieren, erstes Backup auf NEU.

## 6. Ausfallzeit – was Nutzer merken

| Phase | Dauer | Nutzer sehen |
|---|---|---|
| Schritte 1–3 | 15–25 min | nichts, Dienst läuft normal |
| Schritt 4 (ALT stoppen → NEU healthy) | ca. 2–5 min (abhängig von der Datenmenge; grob 1 min je GB) | iPad-App: „Server nicht erreichbar“, Web: Fehlerseite von Caddy; nichts geht verloren, die App gleicht später nach |
| Schritt 5 (DNS) | 1 min bei TTL 60, sonst bis zur alten TTL | einzelne Nutzer noch auf ALT (Fehlerseite), die meisten schon auf NEU |
| Schritt 6 | 5 min | nichts |

Datenverlust: keiner. Die App und die Jobs werden auf ALT sauber gestoppt (SQLite schließt, keine halben Schreibvorgänge),
erst danach wird kopiert, und vor dem Start auf NEU werden Dateizahl, Bytes und die Prüfsumme der `accounts.db` verglichen.
Zusätzlich liegt eine frische Sicherung in `/srv/uniflow/backups` auf ALT (und nach Schritt 6 auch auf NEU).

## 7. Nachkontrolle (2 Minuten)

```bash
tools/server-umzug-pruefen.sh NEU_IP 2.29.122.54
```

Zeigt: Container und Health auf NEU, Antwort der API, Zahl der Nutzerordner und Größe der `accounts.db` auf NEU **und**
ALT (muss gleich sein oder auf NEU höher, nie niedriger), DNS und https von außen, Backup-Timer, Platz und Speicher.
Endet mit `ERGEBNIS: keine Probleme gefunden.` – sonst stehen Zeilen mit `PROBLEM:` dabei.

Dann einmal selbst: in der iPad-App anmelden, ein Dokument öffnen, in der Community etwas ansehen; im Browser
`https://app.studinow.app/login`.

## 8. Rückweg, falls etwas schiefgeht

Solange Schritt 6 nicht gelaufen ist, steht ALT komplett bereit:

1. DNS-Eintrag `A app` zurück auf `2.29.122.54` (TTL 60 lassen).
2. ALT wieder starten:
   ```bash
   ssh -i ~/.ssh/studinow_server root@2.29.122.54 'cd /srv/uniflow/app/deploy && docker compose up -d && docker compose ps'
   ```
3. Nach einer Minute `https://app.studinow.app/login` prüfen. Alle Daten sind der Stand vom Anhalten in Schritt 4.

Nach Schritt 6 (ALT per `down` gestoppt): dieselben zwei Befehle – `down` löscht keine Volumes. Hatten Nutzer in der
Zwischenzeit auf NEU gearbeitet, fehlt das auf ALT; dann lieber den Fehler auf NEU beheben (Protokoll:
`ssh … root@NEU_IP 'cd /srv/uniflow/app/deploy && docker compose logs --tail=100 app caddy'`) oder den Umzug mit
`--ab-schritt 4` von NEU zurück nach ALT laufen lassen (Argumente vertauschen: `tools/server-umzug.sh --ab-schritt 4 NEU_IP 2.29.122.54`).

Typische Fehler:

| Meldung | Ursache / Abhilfe |
|---|---|
| `NEU nicht erreichbar` | Server in der Konsole noch nicht fertig, oder SSH-Key nicht gewählt → Server löschen, mit Key neu anlegen |
| `NEU ist nicht Ubuntu 24.04` | falsches Image gewählt; Server löschen und neu anlegen (oder bewusst `--ohne-os-pruefung`) |
| `Volume … stimmt nicht ueberein` | Übertragung abgebrochen (Netz). Erneut `--ab-schritt 4`; ALT ist noch unverändert |
| `uniflow-app auf NEU ist … unhealthy` | `docker compose logs --tail=100 app` auf NEU lesen; meist `.env` unvollständig. Rückweg Punkt 1–2 |
| `DNS zeigt nach 60 Minuten noch auf …` | Eintrag nicht gespeichert oder falscher Anbieter; prüfen, dann `--ab-schritt 5` |
| https antwortet nicht | `docker compose logs --tail=50 caddy` auf NEU; Ports 80/443 (`ufw status`) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Hetzner hat eine IP wiederverwendet, die dein Mac schon kannte: `ssh-keygen -R NEU_IP`, dann erneut |

## 9. Nach dem Umzug (in den nächsten Tagen)

- `docs/UEBERGABE-2026-11-06.md` Abschnitt 5 und `docs/release/BETRIEB.md`: neue IP und Standort eintragen; in der
  Datenschutzerklärung Standort/Hoster prüfen (Hetzner, jetzt Deutschland statt Finnland).
- Uptime-Check (falls eingerichtet) prüft weiter `https://app.studinow.app/login` – keine Änderung nötig.
- **Nach 7 Tagen:** alten Server in der Hetzner-Konsole löschen (vorher bei Bedarf einen Snapshot anlegen, ca. 1 Cent/GB/Monat).
  Bis dahin kostet er weiter ca. 4 €.
- Der alte Hetzner-Firewall-/Backup-Eintrag (falls vorhanden) hängt am alten Server und verschwindet mit ihm.

## 10. Technische Notizen (für die nächste Sitzung)

- Volumes heißen `uniflow_uniflow-data`, `uniflow_uniflow-logs`, `uniflow_caddy-data` (Compose-Projekt `uniflow`).
  Auf NEU werden sie in Schritt 3 mit `docker compose up --no-start` angelegt, damit sie Compose gehören; Schritt 4 leert und
  befüllt sie per `docker run … alpine tar`.
- Gesundheitsprüfung: Es gibt keine `/api/health`; der Container-Healthcheck ruft `/login` (Dockerfile), das Skript fragt
  intern `http://127.0.0.1:8765/api/account/info` (öffentlich, ohne Anmeldung) per Python im Container ab, weil das Image
  kein `curl` hat und https von außen erst nach DNS geht.
- Das Zertifikat wird mitgenommen (`caddy-data`), darum kein Let's-Encrypt-Rate-Limit und sofort https nach dem DNS-Wechsel;
  `--ohne-caddy-daten` lässt Caddy auf NEU ein neues holen.
- Code-Stand: `--ref ZWEIG|COMMIT` (Standard HEAD des Repos, aus dem das Skript läuft); der Stand steht auf dem Server in
  `/srv/uniflow/app/VERSION-COMMIT`.
- Test ohne Server: `tests/test_server_umzug.py` (Trockenlauf gegen 192.0.2.10/20, Reihenfolge der Schritte, keine echten
  ssh/dig/curl-Aufrufe).

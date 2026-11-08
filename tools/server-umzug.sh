#!/usr/bin/env bash
# Umzug des StudiNow-Dienstes (app.studinow.app) auf einen neuen Server – laeuft auf dem Mac des Inhabers.
#
#   tools/server-umzug.sh [Optionen] ALT_IP NEU_IP
#
# Optionen:
#   --dry-run            nur zeigen, was passieren wuerde (kein SSH, kein git archive, keine Wartezeiten)
#   --ref REF            Zweig/Commit des lokalen Repos, der auf den neuen Server kommt (Standard: aktueller HEAD)
#   --ab-schritt N       bei Schritt N (1-6) weitermachen, z. B. nach einem Abbruch
#   --bis-schritt N      nach Schritt N anhalten (z. B. 3: alles vorbereiten, Pause spaeter)
#   --ja                 Rueckfrage vor der Pause (Schritt 4) nicht stellen
#   --ohne-caddy-daten   Zertifikat von Caddy nicht mitnehmen (dann holt Caddy auf NEU ein neues, sobald DNS stimmt)
#   --ohne-os-pruefung   Ubuntu-24.04-Pruefung auf dem neuen Server ueberspringen
#   --env-setzen N=W     Zeile N=W in der .env auf NEU setzen (mehrfach erlaubt), z. B. fuer den groesseren Server
#                        --env-setzen UVICORN_WORKERS=6 --env-setzen API_MEMORY=2G (Werte: deploy/.env.example, 8b)
#   --dns-wartezeit MIN  wie lange auf den DNS-Wechsel gewartet wird (Standard 60 Minuten)
#   --schluessel PFAD    SSH-Schluessel (Standard ~/.ssh/studinow_server)
#   --domain NAME        Hostname des Dienstes (Standard app.studinow.app)
#
# Reihenfolge (jeder Schritt kann wiederholt werden, ohne Schaden anzurichten):
#   1 Vorpruefung und Einrichtung des neuen Servers (Pakete, Docker, Firewall, Zeitzone, Backup-Ordner)
#   2 Code (git archive) und Konfiguration (.env, override, apple-certs) auf den neuen Server
#   3 Image auf dem neuen Server vorab bauen, Volumes anlegen
#   4 PAUSE: ALT anhalten, Daten uebertragen, pruefen, NEU starten, Health abwarten   <- die einzige Ausfallzeit
#   5 DNS auf NEU_IP umstellen (macht der Inhaber), Skript wartet und prueft https
#   6 ALT stoppen (nicht loeschen), Backup-Timer auf NEU, alte Sicherungen kopieren
#
# Anleitung fuer den Inhaber: docs/SERVER-UMZUG-2026-11-08.md. Nachkontrolle: tools/server-umzug-pruefen.sh NEU_IP ALT_IP
# Das Skript zeigt nie Inhalte der .env an (nur, OB die Pflichtzeilen gefuellt sind).
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HIER/.." && pwd)"

# ---------------------------------------------------------------- Einstellungen
SSH_KEY="${HOME}/.ssh/studinow_server"
SSH_USER="root"
DOMAIN="app.studinow.app"
APP_DIR="/srv/uniflow/app"
DEPLOY_DIR="$APP_DIR/deploy"
BACKUP_DIR="/srv/uniflow/backups"
# Compose-Projekt heisst "uniflow" (name: in docker-compose.yml) -> Volumes heissen uniflow_<name>
VOL_DATA="uniflow_uniflow-data"
VOL_LOGS="uniflow_uniflow-logs"
VOL_CADDY="uniflow_caddy-data"
APP_PORT=8765
HEALTH_PFAD="/api/account/info"       # oeffentliche Route ohne Anmeldung (app/account_api.py); eine /api/health gibt es nicht
DNS_RESOLVER="1.1.1.1"

TROCKEN=0
REF=""
AB_SCHRITT=1
BIS_SCHRITT=6
JA=0
MIT_CADDY=1
OS_PRUEFUNG=1
ENV_SETZEN=""          # Zeilen NAME=WERT, durch Zeilenumbruch getrennt (nur nicht geheime Betriebswerte)
DNS_WARTEZEIT_MIN=60

# ---------------------------------------------------------------- Ausgabe
sag()     { printf '%s\n' "$*"; }
hinweis() { printf '   -> %s\n' "$*"; }
schritt() { printf '\n== Schritt %s: %s ==\n' "$1" "$2"; }
fehler()  { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }
warnung() { printf 'WARNUNG: %s\n' "$*" >&2; }

hilfe() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- Argumente
ALT_IP=""; NEU_IP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|--trocken) TROCKEN=1 ;;
    --ref) shift; REF="${1:-}" ;;
    --ab-schritt) shift; AB_SCHRITT="${1:-}" ;;
    --bis-schritt) shift; BIS_SCHRITT="${1:-}" ;;
    --ja) JA=1 ;;
    --ohne-caddy-daten) MIT_CADDY=0 ;;
    --ohne-os-pruefung) OS_PRUEFUNG=0 ;;
    --env-setzen) shift; printf '%s' "${1:-}" | grep -Eq '^[A-Z][A-Z0-9_]*=[^ ]*$' || fehler "--env-setzen erwartet NAME=WERT, bekommen: '${1:-}'"
                  ENV_SETZEN="${ENV_SETZEN}${1}
" ;;
    --dns-wartezeit) shift; DNS_WARTEZEIT_MIN="${1:-}" ;;
    --schluessel) shift; SSH_KEY="${1:-}" ;;
    --domain) shift; DOMAIN="${1:-}" ;;
    -h|--help|--hilfe) hilfe; exit 0 ;;
    -*) fehler "Unbekannte Option: $1 (Hilfe: --help)" ;;
    *) if [ -z "$ALT_IP" ]; then ALT_IP="$1"; elif [ -z "$NEU_IP" ]; then NEU_IP="$1"; else fehler "Zu viele Argumente: $1"; fi ;;
  esac
  shift
done
[ -n "$ALT_IP" ] && [ -n "$NEU_IP" ] || { hilfe; fehler "Bitte ALT_IP und NEU_IP angeben."; }
[ "$ALT_IP" != "$NEU_IP" ] || fehler "ALT_IP und NEU_IP sind gleich."
ip_ok() { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }
ip_ok "$ALT_IP" || fehler "ALT_IP sieht nicht wie eine IPv4-Adresse aus: $ALT_IP"
ip_ok "$NEU_IP" || fehler "NEU_IP sieht nicht wie eine IPv4-Adresse aus: $NEU_IP"
case "$AB_SCHRITT$BIS_SCHRITT" in *[!1-6]*) fehler "--ab-schritt/--bis-schritt brauchen eine Zahl von 1 bis 6" ;; esac
[ "$AB_SCHRITT" -le "$BIS_SCHRITT" ] || fehler "--ab-schritt ($AB_SCHRITT) liegt hinter --bis-schritt ($BIS_SCHRITT)"

# Code-Stand: Standard ist der aktuelle HEAD des Repos, aus dem das Skript laeuft (Zweig/Commit per --ref waehlbar,
# z. B. --ref server/lastfest). Im Trockenlauf ohne Git-Zugriff nur ein Platzhalter.
if [ -z "$REF" ]; then
  if [ "$TROCKEN" = 1 ]; then REF="HEAD"; else REF="$(git -C "$REPO" rev-parse HEAD)"; fi
fi
if [ "$TROCKEN" = 1 ]; then
  COMMIT="$REF"
else
  COMMIT="$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || fehler "Zweig/Commit nicht gefunden: $REF"
fi

# ---------------------------------------------------------------- SSH-Helfer (im Trockenlauf nur Ausgabe)
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"

# ssh_auf IP 'befehl'   – fuehrt einen Befehl auf dem Server aus (stdout bleibt erhalten)
ssh_auf() {
  local ip="$1"; shift
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] ssh %s@%s -- %s\n' "$SSH_USER" "$ip" "$*"; return 0; fi
  # -n: kein stdin, sonst frisst ssh in einer while-read-Schleife (--env-setzen) die restlichen Zeilen (Befund 08.11.2026)
  # shellcheck disable=SC2086
  ssh -n $SSH_OPTS "$SSH_USER@$ip" "$@"
}
ssh_alt() { ssh_auf "$ALT_IP" "$@"; }
ssh_neu() { ssh_auf "$NEU_IP" "$@"; }

# ssh_wert IP 'befehl' PLATZHALTER – liefert die Ausgabe (im Trockenlauf den Platzhalter) und zeigt den Befehl
ssh_wert() {
  local ip="$1" cmd="$2" platzhalter="${3:-}"
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] ssh %s@%s -- %s\n' "$SSH_USER" "$ip" "$cmd" >&2; printf '%s' "$platzhalter"; return 0; fi
  # shellcheck disable=SC2086
  ssh -n $SSH_OPTS "$SSH_USER@$ip" "$cmd"
}

# strom_alt_neu 'befehl auf ALT (schreibt nach stdout)' 'befehl auf NEU (liest stdin)'
strom_alt_neu() {
  if [ "$TROCKEN" = 1 ]; then
    printf '[trocken] ssh %s@%s -- %s | ssh %s@%s -- %s\n' "$SSH_USER" "$ALT_IP" "$1" "$SSH_USER" "$NEU_IP" "$2"; return 0
  fi
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SSH_USER@$ALT_IP" "$1" | ssh $SSH_OPTS "$SSH_USER@$NEU_IP" "$2"
}

# strom_lokal_neu 'lokaler befehl' 'befehl auf NEU (liest stdin)'
strom_lokal_neu() {
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] %s | ssh %s@%s -- %s\n' "$1" "$SSH_USER" "$NEU_IP" "$2"; return 0; fi
  # shellcheck disable=SC2086
  bash -c "$1" | ssh $SSH_OPTS "$SSH_USER@$NEU_IP" "$2"
}

# ssh_skript IP 'mehrzeiliges skript' – fuehrt ein ganzes Skript auf dem Server aus (bash -s); im Trockenlauf wird es gezeigt
ssh_skript() {
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] ssh %s@%s -- bash -s <<EOF\n%s\nEOF\n' "$SSH_USER" "$1" "$2"; return 0; fi
  # shellcheck disable=SC2086
  printf '%s\n' "$2" | ssh $SSH_OPTS "$SSH_USER@$1" "bash -s"
}

lokal() {
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] %s\n' "$*"; return 0; fi
  "$@"
}

# Einrichtung des neuen Servers (wie ~/Studora-Builds/server/einrichten.sh und docs/release/BETRIEB.md Abschnitt 3);
# jeder Befehl kann wiederholt werden.
EINRICHTUNG='set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl ufw unattended-upgrades dnsutils openssl
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
systemctl enable --now unattended-upgrades
ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw --force enable
timedatectl set-timezone Europe/Berlin
# SSH nur mit Schluessel (Hetzner-Image laesst Passwoerter fuer Nicht-root zu); fail2ban gegen Rateversuche (Befund 08.11.: Dutzende je Minute)
printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n" > /etc/ssh/sshd_config.d/90-studinow.conf && sshd -t && systemctl reload ssh
apt-get install -y -qq fail2ban && printf "[sshd]\nenabled = true\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n" > /etc/fail2ban/jail.d/sshd.local && systemctl enable --now fail2ban
mkdir -p /srv/uniflow/backups /srv/uniflow/app/deploy && chmod 700 /srv/uniflow/backups
docker --version && docker compose version
echo "Einrichtung fertig: $(hostname) $(date)"'

frage_ja() {
  [ "$JA" = 1 ] || [ "$TROCKEN" = 1 ] && return 0
  printf '%s [ja/N] ' "$1"
  local antwort; read -r antwort
  [ "$antwort" = "ja" ] || [ "$antwort" = "j" ] || fehler "Abgebrochen durch den Inhaber."
}

warte() { [ "$TROCKEN" = 1 ] || sleep "$1"; }

COMPOSE="cd $DEPLOY_DIR && docker compose"

# Zahl der Dateien und Summe der Dateigroessen (Bytes) in einem Volume – laeuft auch, wenn die Container stehen.
# Dateigroessen statt belegter Bloecke, damit unterschiedliche Dateisysteme auf ALT und NEU das Ergebnis nicht verfaelschen.
volume_kennzahlen() {    # volume_kennzahlen IP VOLUME PLATZHALTER
  ssh_wert "$1" "docker run --rm -v $2:/data:ro alpine sh -c 'cd /data && echo \"\$(find . -type f | wc -l) \$(find . -type f -exec stat -c %s {} + | awk \"{s+=\\\$1} END {print s+0}\")\"'" "$3"
}

# ================================================================ Schritt 1
schritt_1() {
  schritt 1 "Vorpruefung und Einrichtung des neuen Servers"
  [ "$TROCKEN" = 1 ] || [ -r "$SSH_KEY" ] || fehler "SSH-Schluessel fehlt: $SSH_KEY"
  sag "Code-Stand fuer den neuen Server: $REF ($COMMIT)"

  sag "ALT ($ALT_IP) erreichbar?"
  ssh_alt "hostname && test -f $DEPLOY_DIR/.env && ($COMPOSE ps --format '{{.Name}} {{.Status}}')" \
    || fehler "ALT nicht erreichbar oder kein Dienst unter $DEPLOY_DIR (Schluessel $SSH_KEY, root@$ALT_IP)."

  sag "NEU ($NEU_IP) erreichbar?"
  ssh_neu "hostname" || fehler "NEU nicht erreichbar (Hetzner-Konsole: Server fertig? SSH-Key 'studinow_server' beim Anlegen gewaehlt?)."

  if [ "$OS_PRUEFUNG" = 1 ]; then
    local os; os="$(ssh_wert "$NEU_IP" ". /etc/os-release && echo \"\$ID \$VERSION_ID\"" "ubuntu 24.04")"
    [ "$os" = "ubuntu 24.04" ] || fehler "NEU ist nicht Ubuntu 24.04, sondern '$os' (Image in der Hetzner-Konsole pruefen; --ohne-os-pruefung uebergeht das)."
    hinweis "NEU: $os"
  fi
  local alt_dienst; alt_dienst="$(ssh_wert "$NEU_IP" "docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^uniflow-' || true" "0")"
  if [ "${alt_dienst:-0}" != "0" ]; then
    warnung "Auf NEU laufen schon uniflow-Container ($alt_dienst) – der Server ist nicht frisch. Das Skript macht weiter (Wiederholung)."
  fi

  sag "NEU einrichten (Pakete, Docker, Firewall 22/80/443, Zeitzone, Backup-Ordner, automatische Updates) ..."
  ssh_skript "$NEU_IP" "$EINRICHTUNG"
  hinweis "Schritt 1 fertig."
}

# ================================================================ Schritt 2
schritt_2() {
  schritt 2 "Code und Konfiguration auf den neuen Server"
  sag "Code ($REF) per git archive nach $NEU_IP:$APP_DIR ..."
  strom_lokal_neu "git -C '$REPO' archive --format=tar '$COMMIT'" "mkdir -p $APP_DIR && tar -x -C $APP_DIR && echo '$COMMIT' > $APP_DIR/VERSION-COMMIT && echo 'Code entpackt:' \$(cat $APP_DIR/VERSION-COMMIT)"

  sag "Konfiguration von ALT nach NEU (.env, docker-compose.override.yml, apple-certs) ..."
  # Nur, was auf ALT vorhanden ist (das override und apple-certs fehlen in Einzelfaellen); Inhalte werden nie angezeigt.
  strom_alt_neu "cd $DEPLOY_DIR && tar -czf - \$(ls -d .env docker-compose.override.yml apple-certs 2>/dev/null)" \
                "tar -xzf - -C $DEPLOY_DIR && chmod 600 $DEPLOY_DIR/.env && ls -la $DEPLOY_DIR/.env"

  if [ -n "$ENV_SETZEN" ]; then
    sag "Betriebswerte in der .env auf NEU setzen (groesserer Server) ..."
    local zeile name
    printf '%s' "$ENV_SETZEN" | while IFS= read -r zeile; do
      [ -n "$zeile" ] || continue
      name="${zeile%%=*}"
      # vorhandene Zeile ersetzen, sonst anhaengen; der Wert kommt vom Inhaber (kein Geheimnis) und darf angezeigt werden
      ssh_neu "cd $DEPLOY_DIR && if grep -q '^$name=' .env; then sed -i 's|^$name=.*|$zeile|' .env; else printf '\\n%s\\n' '$zeile' >> .env; fi && grep '^$name=' .env"
    done
  fi

  sag "Pflichtzeilen der .env auf NEU gefuellt?"
  local gefuellt
  gefuellt="$(ssh_wert "$NEU_IP" "grep -cE '^(UNIFLOW_DOMAIN|UNIFLOW_ACME_EMAIL|LERNAPP_SECRET_KEY)=.+' $DEPLOY_DIR/.env" "3")"
  [ "$gefuellt" = "3" ] || fehler ".env auf NEU unvollstaendig (gefuellte Pflichtzeilen: $gefuellt von 3) – Kopie von ALT pruefen."
  hinweis "Schritt 2 fertig."
}

# ================================================================ Schritt 3
schritt_3() {
  schritt 3 "Image auf NEU bauen und Volumes anlegen (Dienst startet noch nicht)"
  sag "docker compose build auf NEU (dauert einige Minuten: Python, Playwright/Chromium) ..."
  ssh_neu "$COMPOSE build"
  # up --no-start legt Container, Netz und Volumes mit Compose-Kennzeichnung an, startet aber nichts.
  # So gehoeren die Volumes zu Compose, und das Befuellen in Schritt 4 trifft die richtigen Namen.
  ssh_neu "$COMPOSE up --no-start && docker volume ls --format '{{.Name}}' | grep '^uniflow_'"
  hinweis "Schritt 3 fertig. Ab hier ist der Wechsel kurz."
}

# ================================================================ Schritt 4
schritt_4() {
  schritt 4 "Pause: Daten von ALT nach NEU (einzige Ausfallzeit)"
  sag "Vorher eine Sicherung auf ALT (backup.sh, Dienst laeuft dabei weiter) ..."
  ssh_alt "bash $DEPLOY_DIR/backup.sh"

  frage_ja "Jetzt beginnt die Pause: der Dienst auf ALT wird angehalten, bis NEU laeuft (einige Minuten). Weiter?"
  local start_pause; start_pause="$(date +%s)"
  sag "ALT: app und jobs anhalten (Caddy laeuft weiter, zeigt Nutzern bis zum Wechsel eine Fehlerseite statt Zeitueberschreitung) ..."
  ssh_alt "$COMPOSE stop app jobs"

  local volumes="$VOL_DATA $VOL_LOGS"
  [ "$MIT_CADDY" = 1 ] && volumes="$volumes $VOL_CADDY"
  local vol kenn_alt kenn_neu
  for vol in $volumes; do
    sag "Volume $vol: Kennzahlen auf ALT ..."
    kenn_alt="$(volume_kennzahlen "$ALT_IP" "$vol" "0 0")"
    sag "Volume $vol: uebertragen (tar-Strom ALT -> NEU, Zielvolume wird vorher geleert) ..."
    strom_alt_neu "docker run --rm -v $vol:/data:ro alpine tar -C /data -czf - ." \
                  "docker run --rm -i -v $vol:/data alpine sh -c 'find /data -mindepth 1 -delete && tar -xzf - -C /data'"
    kenn_neu="$(volume_kennzahlen "$NEU_IP" "$vol" "0 0")"
    if [ "$kenn_alt" != "$kenn_neu" ]; then
      if [ "$vol" = "$VOL_CADDY" ]; then
        # Caddy laeuft auf ALT weiter und darf waehrenddessen schreiben (OCSP, Sperrdateien) – kein Grund zum Abbruch
        warnung "Volume $vol weicht ab (ALT: Dateien/Bytes $kenn_alt, NEU: $kenn_neu) – bei Caddy unkritisch, es holt notfalls ein neues Zertifikat."
      else
        fehler "Volume $vol stimmt nicht ueberein (ALT: Dateien/Bytes $kenn_alt, NEU: $kenn_neu). ALT ist unveraendert; Rueckweg: ssh root@$ALT_IP '$COMPOSE up -d'."
      fi
    else
      hinweis "$vol gleich: ${kenn_alt% *} Dateien, ${kenn_alt#* } Bytes"
    fi
  done

  sag "accounts.db: Pruefsumme vergleichen ..."
  local md5_alt md5_neu
  md5_alt="$(ssh_wert "$ALT_IP" "docker run --rm -v $VOL_DATA:/data:ro alpine sh -c 'cd /data && md5sum accounts.db accounts.db-wal 2>/dev/null | md5sum'" "x")"
  md5_neu="$(ssh_wert "$NEU_IP" "docker run --rm -v $VOL_DATA:/data:ro alpine sh -c 'cd /data && md5sum accounts.db accounts.db-wal 2>/dev/null | md5sum'" "x")"
  [ "$md5_alt" = "$md5_neu" ] || fehler "accounts.db unterscheidet sich zwischen ALT und NEU – nicht weitermachen. Rueckweg: ssh root@$ALT_IP '$COMPOSE up -d'."

  sag "NEU: Dienst starten ..."
  ssh_neu "$COMPOSE up -d"
  sag "NEU: warten, bis der Container uniflow-app 'healthy' meldet (bis 3 Minuten) ..."
  local i status="unbekannt"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    status="$(ssh_wert "$NEU_IP" "docker inspect -f '{{.State.Health.Status}}' uniflow-app 2>/dev/null || echo fehlt" "healthy")"
    [ "$status" = "healthy" ] && break
    warte 10
  done
  [ "$status" = "healthy" ] || fehler "uniflow-app auf NEU ist nach 3 Minuten '$status'. Protokoll: ssh root@$NEU_IP '$COMPOSE logs --tail=100 app'. Rueckweg: ssh root@$ALT_IP '$COMPOSE up -d'."

  # Von aussen klappt https erst nach DNS; deshalb intern im Container pruefen (Image hat kein curl, aber Python).
  sag "NEU: interne Antwort von $HEALTH_PFAD ..."
  ssh_neu "$COMPOSE exec -T app python -c \"import urllib.request; r = urllib.request.urlopen('http://127.0.0.1:$APP_PORT$HEALTH_PFAD', timeout=10); print('HTTP', r.status, r.read(80))\""
  sag "NEU: Zahl der Konten ..."
  ssh_neu "$COMPOSE exec -T app python -c \"import sqlite3; print('Konten:', sqlite3.connect('/data/accounts.db').execute('select count(*) from users').fetchone()[0])\""
  ssh_neu "$COMPOSE ps"
  local dauer=$(( $(date +%s) - start_pause ))
  hinweis "Schritt 4 fertig: Daten auf NEU, Dienst laeuft dort. Pause bisher: $((dauer / 60)) min $((dauer % 60)) s (plus DNS-Umstellung)."
}

# ================================================================ Schritt 5
schritt_5() {
  schritt 5 "DNS umstellen (macht der Inhaber) – Skript wartet und prueft"
  if [ "$MIT_CADDY" = 1 ]; then
    sag "Vorab-Test von NEU ueber Caddy mit dem mitgenommenen Zertifikat (noch ohne DNS) ..."
    lokal curl -fsS --max-time 20 --resolve "$DOMAIN:443:$NEU_IP" "https://$DOMAIN$HEALTH_PFAD" \
      || warnung "NEU antwortet noch nicht ueber https (Caddy braucht evtl. noch einen Moment) – weiter mit DNS."
    sag
  fi
  cat <<EOF

   JETZT DNS UMSTELLEN (dort, wo die Domain studinow.app verwaltet wird – Registrar oder Netlify-DNS,
   siehe docs/SERVER-UMZUG-2026-11-08.md Abschnitt 5):
     Eintrag:  A    Name: app    Wert: $NEU_IP    TTL: 60 (so klein wie moeglich)
   Alten Wert $ALT_IP ersetzen, nicht zusaetzlich eintragen. Gibt es einen AAAA-Eintrag (IPv6) fuer app,
   auf die IPv6 des neuen Servers aendern oder loeschen.

EOF
  sag "Warte, bis 'dig +short $DOMAIN @$DNS_RESOLVER' die neue Adresse $NEU_IP liefert (hoechstens $DNS_WARTEZEIT_MIN Minuten) ..."
  local gesehen="" runden=$(( DNS_WARTEZEIT_MIN * 2 )) i=0
  while :; do
    if [ "$TROCKEN" = 1 ]; then printf '[trocken] dig +short %s A @%s\n' "$DOMAIN" "$DNS_RESOLVER"; gesehen="$NEU_IP"; break; fi
    gesehen="$(dig +short "$DOMAIN" A "@$DNS_RESOLVER" 2>/dev/null | tail -n 1 || true)"
    [ "$gesehen" = "$NEU_IP" ] && break
    i=$((i + 1))
    [ "$i" -lt "$runden" ] || fehler "DNS zeigt nach $DNS_WARTEZEIT_MIN Minuten noch auf '${gesehen:-nichts}'. Eintrag pruefen und das Skript mit --ab-schritt 5 erneut starten."
    printf '   %s: noch %s ... (%d/%d)\n' "$(date +%H:%M:%S)" "${gesehen:-keine Antwort}" "$i" "$runden"
    sleep 30
  done
  hinweis "DNS liefert $gesehen."

  sag "Pruefe https://$DOMAIN$HEALTH_PFAD ueber den neuen Server (Caddy holt bei Bedarf das Zertifikat; bis 5 Minuten) ..."
  local ok=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$TROCKEN" = 1 ]; then printf '[trocken] curl -fsS https://%s%s\n' "$DOMAIN" "$HEALTH_PFAD"; ok=1; break; fi
    if curl -fsS --max-time 20 --resolve "$DOMAIN:443:$NEU_IP" "https://$DOMAIN$HEALTH_PFAD" >/dev/null 2>&1; then ok=1; break; fi
    sleep 30
  done
  [ "$ok" = 1 ] || fehler "https://$DOMAIN antwortet auf NEU nicht. Protokoll: ssh root@$NEU_IP '$COMPOSE logs --tail=50 caddy'. Rueckweg: DNS auf $ALT_IP und ssh root@$ALT_IP '$COMPOSE up -d'."
  hinweis "ERFOLG: https://$DOMAIN laeuft auf dem neuen Server $NEU_IP."
}

# ================================================================ Schritt 6
schritt_6() {
  schritt 6 "Aufraeumen: ALT stoppen (nicht loeschen), Backups auf NEU"
  sag "ALT: docker compose down (Daten-Volumes bleiben 7 Tage als Reserve; Server erst danach von Hand loeschen) ..."
  ssh_alt "$COMPOSE down"

  sag "NEU: taeglichen Backup-Timer einrichten (03:30, docs/release/BETRIEB.md Abschnitt 9) ..."
  ssh_neu "cp $DEPLOY_DIR/uniflow-backup.service $DEPLOY_DIR/uniflow-backup.timer /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now uniflow-backup.timer && systemctl list-timers uniflow-backup.timer --no-pager"

  sag "Alte Sicherungen von ALT nach NEU kopieren ($BACKUP_DIR) ..."
  strom_alt_neu "tar -C $BACKUP_DIR -czf - ." "mkdir -p $BACKUP_DIR && tar -xzf - -C $BACKUP_DIR && chmod 700 $BACKUP_DIR && ls -1 $BACKUP_DIR | wc -l"

  sag "NEU: erstes Backup auf dem neuen Server ..."
  ssh_neu "systemctl start uniflow-backup.service && ls -lh $BACKUP_DIR | tail -n 3"
  cat <<EOF

   FERTIG. Der Dienst laeuft auf $NEU_IP. Noch zu tun (von Hand):
   - docs/UEBERGABE-2026-11-06.md und docs/release/BETRIEB.md: neue IP/Standort eintragen; Datenschutz (Standort Deutschland) pruefen.
   - 7 Tage warten, dann alten Server $ALT_IP in der Hetzner-Konsole loeschen (vorher Snapshot, wenn gewuenscht).
   - Nachkontrolle: tools/server-umzug-pruefen.sh $NEU_IP $ALT_IP
EOF
}

# ================================================================ Ablauf
sag "StudiNow-Umzug  ALT=$ALT_IP  ->  NEU=$NEU_IP  Domain=$DOMAIN  Schritte $AB_SCHRITT-$BIS_SCHRITT$([ "$TROCKEN" = 1 ] && printf ' (TROCKENLAUF, nichts wird ausgefuehrt)')"
n=$AB_SCHRITT
while [ "$n" -le "$BIS_SCHRITT" ]; do
  "schritt_$n"
  n=$((n + 1))
done
sag
sag "Ende: Schritte $AB_SCHRITT bis $BIS_SCHRITT durchlaufen."

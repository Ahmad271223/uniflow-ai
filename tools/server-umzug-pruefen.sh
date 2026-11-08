#!/usr/bin/env bash
# Nachkontrolle nach dem Server-Umzug (tools/server-umzug.sh) – laeuft auf dem Mac des Inhabers.
#
#   tools/server-umzug-pruefen.sh [--dry-run] [--schluessel PFAD] [--domain NAME] NEU_IP [ALT_IP]
#
# Zeigt fuer den neuen Server: Container und Health, interne Antwort der API, Zahl der Nutzerordner, Groesse der
# accounts.db, Zahl der Konten, DNS und https von aussen, Backup-Timer. Mit ALT_IP zusaetzlich dieselben Zahlen vom
# alten Server (direkt aus dem Daten-Volume, auch wenn dort die Container gestoppt sind) und den Vergleich.
# Zeigt nie Inhalte der .env. Anleitung: docs/SERVER-UMZUG-2026-11-08.md
set -euo pipefail

SSH_KEY="${HOME}/.ssh/studinow_server"
SSH_USER="root"
DOMAIN="app.studinow.app"
DEPLOY_DIR="/srv/uniflow/app/deploy"
VOL_DATA="uniflow_uniflow-data"
APP_PORT=8765
HEALTH_PFAD="/api/account/info"
TROCKEN=0
NEU_IP=""; ALT_IP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|--trocken) TROCKEN=1 ;;
    --schluessel) shift; SSH_KEY="${1:-}" ;;
    --domain) shift; DOMAIN="${1:-}" ;;
    -h|--help|--hilfe) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'Unbekannte Option: %s\n' "$1" >&2; exit 1 ;;
    *) if [ -z "$NEU_IP" ]; then NEU_IP="$1"; elif [ -z "$ALT_IP" ]; then ALT_IP="$1"; else printf 'Zu viele Argumente: %s\n' "$1" >&2; exit 1; fi ;;
  esac
  shift
done
[ -n "$NEU_IP" ] || { printf 'Bitte NEU_IP angeben (optional ALT_IP).\n' >&2; exit 1; }

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
sag() { printf '%s\n' "$*"; }
titel() { printf '\n-- %s --\n' "$*"; }
FEHLER=0
schlecht() { printf 'PROBLEM: %s\n' "$*"; FEHLER=$((FEHLER + 1)); }

# ssh_wert IP 'befehl' PLATZHALTER – Ausgabe des Befehls (im Trockenlauf der Platzhalter)
ssh_wert() {
  if [ "$TROCKEN" = 1 ]; then printf '[trocken] ssh %s@%s -- %s\n' "$SSH_USER" "$1" "$2" >&2; printf '%s' "${3:-}"; return 0; fi
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SSH_USER@$1" "$2" 2>/dev/null || printf 'FEHLER'
}
ssh_zeige() {    # Befehl ausfuehren und Ausgabe eingerueckt zeigen
  local aus; aus="$(ssh_wert "$1" "$2" "${3:-}")"
  printf '%s\n' "$aus" | sed 's/^/   /'
}

# Zahlen direkt aus dem Daten-Volume (unabhaengig davon, ob die Container laufen): Nutzerordner, DB-Bytes, Konten
volume_zahlen() {    # volume_zahlen IP PLATZHALTER
  ssh_wert "$1" "docker run --rm -v $VOL_DATA:/data:ro alpine sh -c 'echo \"nutzerordner=\$(ls -1d /data/users/*/ 2>/dev/null | wc -l | tr -d \" \") db_bytes=\$(stat -c %s /data/accounts.db 2>/dev/null || echo 0) dateien=\$(find /data -type f | wc -l | tr -d \" \")\"'" "$2"
}

sag "Nachkontrolle StudiNow-Dienst  NEU=$NEU_IP${ALT_IP:+  ALT=$ALT_IP}  Domain=$DOMAIN$([ "$TROCKEN" = 1 ] && printf ' (TROCKENLAUF)')"

titel "NEU: Container"
ssh_zeige "$NEU_IP" "cd $DEPLOY_DIR && docker compose ps --format 'table {{.Name}}\t{{.Status}}'" "uniflow-app Up (healthy)"
status="$(ssh_wert "$NEU_IP" "docker inspect -f '{{.State.Health.Status}}' uniflow-app 2>/dev/null || echo fehlt" "healthy")"
[ "$status" = "healthy" ] && sag "   uniflow-app: healthy" || schlecht "uniflow-app ist '$status' (Protokoll: ssh root@$NEU_IP 'cd $DEPLOY_DIR && docker compose logs --tail=100 app')"
jobs_status="$(ssh_wert "$NEU_IP" "docker inspect -f '{{.State.Health.Status}}' uniflow-jobs 2>/dev/null || echo fehlt" "healthy")"
[ "$jobs_status" = "healthy" ] && sag "   uniflow-jobs: healthy" || schlecht "uniflow-jobs ist '$jobs_status' (in den ersten 2 Minuten nach dem Start normal: 'starting')"

titel "NEU: interne Antwort der API ($HEALTH_PFAD)"
ssh_zeige "$NEU_IP" "cd $DEPLOY_DIR && docker compose exec -T app python -c \"import urllib.request; r = urllib.request.urlopen('http://127.0.0.1:$APP_PORT$HEALTH_PFAD', timeout=10); print('HTTP', r.status, r.read(60))\"" "HTTP 200 b'{\"mode\":\"hosted\"'"
konten_neu="$(ssh_wert "$NEU_IP" "cd $DEPLOY_DIR && docker compose exec -T app python -c \"import sqlite3; print(sqlite3.connect('/data/accounts.db').execute('select count(*) from users').fetchone()[0])\"" "0")"
sag "   Konten in accounts.db: $konten_neu"

titel "NEU: Daten-Volume"
zahlen_neu="$(volume_zahlen "$NEU_IP" "nutzerordner=0 db_bytes=0 dateien=0")"
sag "   $zahlen_neu"
code_neu="$(ssh_wert "$NEU_IP" "cat /srv/uniflow/app/VERSION-COMMIT 2>/dev/null || echo unbekannt" "HEAD")"
sag "   Code-Stand (VERSION-COMMIT): $code_neu"

if [ -n "$ALT_IP" ]; then
  titel "ALT: Daten-Volume zum Vergleich (Container dort duerfen gestoppt sein)"
  zahlen_alt="$(volume_zahlen "$ALT_IP" "nutzerordner=0 db_bytes=0 dateien=0")"
  sag "   $zahlen_alt"
  if [ "$zahlen_alt" = "$zahlen_neu" ]; then
    sag "   gleich: Nutzerordner, accounts.db-Groesse und Dateizahl stimmen ueberein"
  else
    # Nach dem Umzug schreibt NEU weiter (neue Konten, Protokolle): Abweichungen nach oben sind normal, nach unten nicht.
    n_alt="${zahlen_alt#nutzerordner=}"; n_alt="${n_alt%% *}"; n_neu="${zahlen_neu#nutzerordner=}"; n_neu="${n_neu%% *}"
    if [ "${n_neu:-0}" -lt "${n_alt:-0}" ] 2>/dev/null; then
      schlecht "NEU hat weniger Nutzerordner ($n_neu) als ALT ($n_alt) – Daten fehlen?"
    else
      sag "   Abweichung (NEU laeuft seit dem Umzug weiter: $n_alt -> $n_neu Nutzerordner); nicht weniger als auf ALT, in Ordnung"
    fi
  fi
  titel "ALT: Container (sollen nach dem Umzug gestoppt sein)"
  ssh_zeige "$ALT_IP" "docker ps --format '{{.Names}} {{.Status}}' | grep '^uniflow-' || echo 'keine laufenden uniflow-Container'" "keine laufenden uniflow-Container"
fi

titel "DNS und https von aussen"
if [ "$TROCKEN" = 1 ]; then
  printf '[trocken] dig +short %s A @1.1.1.1\n[trocken] curl -fsS https://%s%s\n' "$DOMAIN" "$DOMAIN" "$HEALTH_PFAD"
else
  dns="$(dig +short "$DOMAIN" A @1.1.1.1 2>/dev/null | tail -n 1 || true)"
  [ "$dns" = "$NEU_IP" ] && sag "   DNS: $DOMAIN -> $dns (neuer Server)" || schlecht "DNS liefert '${dns:-nichts}', erwartet $NEU_IP"
  if antwort="$(curl -fsS --max-time 20 "https://$DOMAIN$HEALTH_PFAD" 2>&1)"; then
    sag "   https://$DOMAIN$HEALTH_PFAD: ${antwort:0:80}"
  else
    schlecht "https://$DOMAIN$HEALTH_PFAD antwortet nicht: ${antwort:0:120}"
  fi
fi

titel "NEU: Backup-Timer und Sicherungen"
ssh_zeige "$NEU_IP" "systemctl is-enabled uniflow-backup.timer 2>/dev/null || echo 'nicht eingerichtet'; ls -lh /srv/uniflow/backups 2>/dev/null | tail -n 3" "enabled"

titel "NEU: Platz und Speicher"
ssh_zeige "$NEU_IP" "df -h / | tail -n 1 && free -h | sed -n 2p && docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}'" "/dev/sda1 76G 9G 67G 12% /"

sag
if [ "$FEHLER" = 0 ]; then sag "ERGEBNIS: keine Probleme gefunden."; else sag "ERGEBNIS: $FEHLER Problem(e) – siehe Zeilen mit PROBLEM."; exit 1; fi

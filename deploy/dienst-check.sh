#!/usr/bin/env bash
# Dienstpruefung des StudiNow-Dienstes – laeuft AUF DEM SERVER als root, alle 5 Minuten (deploy/uniflow-dienst-check.timer
# oder Cron: */5 * * * * /srv/uniflow/app/deploy/dienst-check.sh). Entstanden fuer den Launch mit bis zu 4.000 Nutzern
# (docs/release/LAUNCH-4000-2026-11-08.md).
#
#   /srv/uniflow/app/deploy/dienst-check.sh [--dry-run] [--no-mail] [--verbose] [--help]
#
# Prueft (jede Pruefung hat eine Kennung, die in Protokoll und Mail steht):
#   container   uniflow-app, uniflow-jobs, uniflow-caddy laufen und sind "healthy" (docker inspect)
#   platte      Belegung von /srv/uniflow und /var/lib/docker ueber DIENST_CHECK_DISK_PCT (80 %)
#   ram         belegter Arbeitsspeicher (free -m, ohne Cache) ueber DIENST_CHECK_RAM_PCT (90 %)
#   zugriff     Zugriffsprotokoll der App (/logs/access/access-YYYY-MM-DD.log, letzte 5 Minuten): 5xx-Anteil ueber
#               DIENST_CHECK_5XX_PCT (1 %), Anteil 4xx ohne 401/403/404 ueber DIENST_CHECK_ERR_PCT (5 %), p95 der Antwortzeit
#               ueber DIENST_CHECK_P95_MS (2000) – erst ab DIENST_CHECK_MIN_REQ (50) Anfragen im Fenster
#   campus      429 bei /api/account/register oder /api/account/login im Fenster (Campus-NAT: Grenzen je IP zu knapp,
#               LERNAPP_LIMIT_REGISTER_IP / LERNAPP_LOGIN_FAILS_IP erhoehen)
#   zertifikat  TLS-Zertifikat von https://DOMAIN laeuft in weniger als DIENST_CHECK_CERT_DAYS (14) Tagen ab
#   jobs        Lebenszeichen /logs/jobs.heartbeat aelter als DIENST_CHECK_HEARTBEAT_S (180 s)
#   backup      neuestes Archiv in /srv/uniflow/backups aelter als DIENST_CHECK_BACKUP_H (30 h)
#   loeschlauf  letzter erfolgreicher Loeschlauf (/logs/retention.log) aelter als DIENST_CHECK_RETENTION_H (30 h)
#   ausser_haus letzte erfolgreiche Kopie auf die Storage Box (OFFSITE_STATE_DIR/letzte-kopie, deploy/backup-ausser-haus.sh)
#               aelter als DIENST_CHECK_OFFSITE_H (30 h) - nur, wenn OFFSITE_HOST/OFFSITE_USER/OFFSITE_RECIPIENT gesetzt sind
#   http        GET https://DOMAIN/login ueber 127.0.0.1:443 antwortet nicht mit 200 (curl, wenn vorhanden)
#
# Befunde: je eine Zeile "ZEIT PROBLEM kennung Text" in DIENST_CHECK_LOG (/srv/uniflow/dienst-check.log); ist ein Problem
# wieder weg, eine Zeile "ZEIT ERHOLT kennung". Mail: ueber das SMTP-Setup des Dienstes selbst (docker compose exec app
# python -m app.mail send ..., Passwort bleibt in deploy/.env) an DIENST_CHECK_MAIL_TO (support@studinow.app), hoechstens
# eine je Kennung und DIENST_CHECK_MAIL_EVERY_H (6) Stunden (Merkdateien in DIENST_CHECK_STATE). Mit --dry-run wird
# nichts geschrieben und nichts verschickt; alle Zeilen gehen nach stdout ("[trocken] ..." fuer den Mailbefehl).
# Exit: 0 = alles in Ordnung, 1 = mindestens ein Befund, 2 = Aufruffehler. Das Skript zeigt nie Inhalte der .env.
#
# Umgebung (alle optional; Datei /srv/uniflow/dienst-check.env wird vom systemd-Dienst eingelesen):
#   DIENST_CHECK_LOG DIENST_CHECK_STATE DIENST_CHECK_MAIL(1|0) DIENST_CHECK_MAIL_TO DIENST_CHECK_MAIL_EVERY_H DIENST_CHECK_DOMAIN
#   DIENST_CHECK_DISK_PCT DIENST_CHECK_RAM_PCT DIENST_CHECK_5XX_PCT DIENST_CHECK_ERR_PCT DIENST_CHECK_P95_MS DIENST_CHECK_MIN_REQ
#   DIENST_CHECK_CERT_DAYS DIENST_CHECK_HEARTBEAT_S DIENST_CHECK_BACKUP_H DIENST_CHECK_WINDOW_S DIENST_CHECK_DISK_PATHS
#   DIENST_CHECK_BACKUP_DIR DIENST_CHECK_LOGS_VOLUME DIENST_CHECK_OFFSITE_H DIENST_CHECK_RETENTION_H COMPOSE_DIR
#   OFFSITE_HOST OFFSITE_USER OFFSITE_RECIPIENT OFFSITE_STATE_DIR (sonst aus deploy/.env, nur diese Namen)
# Test ohne Server: tests/test_dienst_check.py (bash -n, Trockenlauf mit Attrappen fuer docker/df/free/openssl/curl).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$HERE}"

LOG="${DIENST_CHECK_LOG:-/srv/uniflow/dienst-check.log}"
STATE="${DIENST_CHECK_STATE:-/srv/uniflow/dienst-check.state}"
MAIL="${DIENST_CHECK_MAIL:-1}"
MAIL_TO="${DIENST_CHECK_MAIL_TO:-support@studinow.app}"
MAIL_EVERY_H="${DIENST_CHECK_MAIL_EVERY_H:-6}"
DOMAIN="${DIENST_CHECK_DOMAIN:-}"
DISK_PCT="${DIENST_CHECK_DISK_PCT:-80}"
RAM_PCT="${DIENST_CHECK_RAM_PCT:-90}"
PCT_5XX="${DIENST_CHECK_5XX_PCT:-1}"
PCT_ERR="${DIENST_CHECK_ERR_PCT:-5}"
P95_MS="${DIENST_CHECK_P95_MS:-2000}"
MIN_REQ="${DIENST_CHECK_MIN_REQ:-50}"
CERT_DAYS="${DIENST_CHECK_CERT_DAYS:-14}"
HEARTBEAT_S="${DIENST_CHECK_HEARTBEAT_S:-180}"
BACKUP_H="${DIENST_CHECK_BACKUP_H:-30}"
OFFSITE_H="${DIENST_CHECK_OFFSITE_H:-30}"
RETENTION_H="${DIENST_CHECK_RETENTION_H:-30}"
WINDOW_S="${DIENST_CHECK_WINDOW_S:-300}"
DISK_PATHS="${DIENST_CHECK_DISK_PATHS:-/srv/uniflow /var/lib/docker}"
BACKUP_DIR="${DIENST_CHECK_BACKUP_DIR:-/srv/uniflow/backups}"
LOGS_VOLUME="${DIENST_CHECK_LOGS_VOLUME:-uniflow_uniflow-logs}"
CONTAINERS="uniflow-app uniflow-jobs uniflow-caddy"

TROCKEN=0
VERBOSE=0

hilfe() {
	sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) TROCKEN=1 ;;
		--no-mail) MAIL=0 ;;
		--verbose) VERBOSE=1 ;;
		--help|-h) hilfe; exit 0 ;;
		*) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 2 ;;
	esac
	shift
done

# ---------------------------------------------------------------- Hilfen (GNU/Linux zuerst, BSD/macOS fuer den Trockenlauf am Mac)

now_epoch() { date -u +%s; }
epoch_to_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# "Nov 30 12:00:00 2026 GMT" (openssl notAfter) -> Epoche; leer, wenn nicht lesbar
cert_epoch() {
	date -u -d "$1" +%s 2>/dev/null || date -j -u -f "%b %d %T %Y %Z" "$1" +%s 2>/dev/null || echo ""
}
hat() { command -v "$1" >/dev/null 2>&1; }

NOW="$(now_epoch)"
STAMP="$(epoch_to_iso "$NOW")"
BEFUNDE=()          # "kennung|Text"
KENNUNGEN=()

befund() {          # befund kennung Text
	BEFUNDE+=("$1|$2")
	KENNUNGEN+=("$1")
	zeile "PROBLEM $1 $2"
}
ok() { [ "$VERBOSE" = 1 ] && zeile "OK $1 $2" || true; }
zeile() {
	local text="$STAMP $1"
	if [ "$TROCKEN" = 1 ]; then
		echo "$text"
	else
		mkdir -p "$(dirname "$LOG")"
		echo "$text" >>"$LOG"
		[ "$VERBOSE" = 1 ] && echo "$text" || true
	fi
}

# Domain aus deploy/.env lesen (nur den Namen, nie andere Werte ausgeben)
if [ -z "$DOMAIN" ] && [ -r "$COMPOSE_DIR/.env" ]; then
	DOMAIN="$(grep -E '^UNIFLOW_DOMAIN=' "$COMPOSE_DIR/.env" | head -n1 | cut -d= -f2- | tr -d '"'"'"' \r')"
fi

# ---------------------------------------------------------------- 1. Container

pruefe_container() {
	if ! hat docker; then
		befund container "docker nicht gefunden"
		return
	fi
	local out
	# shellcheck disable=SC2086
	if ! out="$(docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}}' $CONTAINERS 2>&1)"; then
		befund container "docker inspect fehlgeschlagen: $(echo "$out" | head -n1 | cut -c1-160)"
		return
	fi
	local name status health restarts seen=0
	while read -r name status health restarts; do
		[ -n "$name" ] || continue
		seen=$((seen + 1))
		name="${name#/}"
		if [ "$status" != "running" ]; then
			befund container "$name ist $status (Neustarts: ${restarts:-?})"
		elif [ "$health" != "-" ] && [ "$health" != "healthy" ]; then
			befund container "$name ist $health (Neustarts: ${restarts:-?})"
		else
			ok container "$name $status/$health"
		fi
	done <<<"$out"
	[ "$seen" -ge 3 ] || befund container "nur $seen von 3 Containern gefunden"
}

# ---------------------------------------------------------------- 2. Platte

pruefe_platte() {
	local p pct
	for p in $DISK_PATHS; do
		[ -d "$p" ] || continue
		pct="$(df -P "$p" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
		[ -n "$pct" ] || continue
		if [ "$pct" -ge "$DISK_PCT" ]; then
			befund platte "$p zu $pct % belegt (Grenze $DISK_PCT %): docker system prune, alte Backups, LERNAPP_UPLOAD_QUOTA_MB senken"
		else
			ok platte "$p $pct %"
		fi
	done
}

# ---------------------------------------------------------------- 3. Arbeitsspeicher

pruefe_ram() {
	hat free || return 0
	local total avail pct
	read -r total avail < <(free -m | awk '/^Mem:/ {print $2, ($7 != "" ? $7 : $4)}')
	[ -n "${total:-}" ] && [ "$total" -gt 0 ] || return 0
	pct=$(((total - avail) * 100 / total))
	if [ "$pct" -ge "$RAM_PCT" ]; then
		befund ram "$pct % von $total MB belegt (frei $avail MB, Grenze $RAM_PCT %): docker stats ansehen, API_MEMORY/UVICORN_WORKERS pruefen"
	else
		ok ram "$pct % von $total MB"
	fi
}

# ---------------------------------------------------------------- 4. Zugriffsprotokoll (letzte WINDOW_S Sekunden)

LOGS_DIR=""
finde_logs() {
	[ -n "$LOGS_DIR" ] && return 0
	if [ -n "${DIENST_CHECK_LOGS_DIR:-}" ]; then
		LOGS_DIR="$DIENST_CHECK_LOGS_DIR"
	elif hat docker; then
		LOGS_DIR="$(docker volume inspect --format '{{.Mountpoint}}' "$LOGS_VOLUME" 2>/dev/null || true)"
	fi
	[ -n "$LOGS_DIR" ] && [ -d "$LOGS_DIR" ]
}

pruefe_zugriff() {
	finde_logs || { ok zugriff "Protokollordner nicht lesbar (Volume $LOGS_VOLUME)"; return 0; }
	local cutoff heute gestern files=() f
	cutoff="$(epoch_to_iso $((NOW - WINDOW_S)))"
	heute="$(echo "$STAMP" | cut -c1-10)"
	gestern="$(epoch_to_iso $((NOW - 86400)) | cut -c1-10)"
	for f in "$LOGS_DIR/access/access-$gestern.log" "$LOGS_DIR/access/access-$heute.log"; do
		[ -r "$f" ] && files+=("$f")
	done
	[ ${#files[@]} -gt 0 ] || { ok zugriff "kein Zugriffsprotokoll fuer $heute"; return 0; }
	local fenster
	fenster="$(tail -q -n 200000 "${files[@]}" | awk -v cut="$cutoff" '$1 >= cut')"
	local n n5 n4 r429 p95
	read -r n n5 n4 r429 < <(echo "$fenster" | awk '
		NF >= 6 { n++; st = $5
			if (st ~ /^5/) e5++
			if (st ~ /^4/ && st != "401" && st != "403" && st != "404") e4++
			if (st == "429" && ($4 == "/api/account/register" || $4 == "/api/account/login")) r++ }
		END { printf "%d %d %d %d\n", n, e5, e4, r }')
	if [ "$r429" -gt 0 ]; then
		befund campus "$r429 x 429 bei Registrierung/Anmeldung in $((WINDOW_S / 60)) min: Grenzen je IP zu knapp fuer Campus-NAT (LERNAPP_LIMIT_REGISTER_IP, LERNAPP_LOGIN_FAILS_IP erhoehen)"
	else
		ok campus "keine 429 bei Registrierung/Anmeldung"
	fi
	if [ "$n" -lt "$MIN_REQ" ]; then
		ok zugriff "nur $n Anfragen im Fenster (Quoten ab $MIN_REQ)"
		return 0
	fi
	p95="$(echo "$fenster" | awk 'NF >= 6 { ms = $6; sub(/ms$/, "", ms); print ms + 0 }' | sort -n | awk '{ a[NR] = $1 } END { if (NR) { i = int(0.95 * (NR - 1)) + 1; print a[i] } else print 0 }')"
	local a5 a4
	a5=$((n5 * 100 / n)); a4=$((n4 * 100 / n))
	if [ "$a5" -ge "$PCT_5XX" ] && [ "$n5" -gt 0 ]; then
		befund zugriff "5xx-Anteil $a5 % ($n5 von $n Anfragen, Grenze $PCT_5XX %): docker compose logs app --since 10m"
	else
		ok zugriff "5xx $n5 von $n"
	fi
	if [ "$a4" -ge "$PCT_ERR" ] && [ "$n4" -gt 0 ]; then
		befund zugriff "Fehlerquote 4xx (ohne 401/403/404) $a4 % ($n4 von $n): Client-Fehler oder Grenzen (429) pruefen"
	else
		ok zugriff "4xx $n4 von $n"
	fi
	if [ "${p95:-0}" -ge "$P95_MS" ]; then
		befund zugriff "p95 der Antwortzeit $p95 ms bei $n Anfragen (Grenze $P95_MS ms): Last? docker stats, UVICORN_WORKERS"
	else
		ok zugriff "p95 $p95 ms bei $n Anfragen"
	fi
}

# ---------------------------------------------------------------- 5. Zertifikat

pruefe_zertifikat() {
	[ -n "$DOMAIN" ] || { ok zertifikat "keine Domain bekannt (DIENST_CHECK_DOMAIN oder UNIFLOW_DOMAIN in deploy/.env)"; return 0; }
	hat openssl || return 0
	local enddate epoch tage
	enddate="$(echo | openssl s_client -servername "$DOMAIN" -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
	if [ -z "$enddate" ]; then
		befund zertifikat "Zertifikat von $DOMAIN nicht lesbar (Caddy auf 443? docker compose logs caddy)"
		return
	fi
	epoch="$(cert_epoch "$enddate")"
	[ -n "$epoch" ] || { ok zertifikat "Ablaufdatum nicht auswertbar: $enddate"; return 0; }
	tage=$(((epoch - NOW) / 86400))
	if [ "$tage" -lt "$CERT_DAYS" ]; then
		befund zertifikat "Zertifikat von $DOMAIN laeuft in $tage Tagen ab ($enddate): Caddy erneuert nicht - docker compose logs caddy, Port 80/443 offen?"
	else
		ok zertifikat "$DOMAIN noch $tage Tage"
	fi
}

# ---------------------------------------------------------------- 6. Jobs-Lebenszeichen, 7. Backup

pruefe_jobs() {
	finde_logs || return 0
	local f="$LOGS_DIR/jobs.heartbeat" alter
	[ -f "$f" ] || { befund jobs "kein Lebenszeichen $f (python -m app.jobs laeuft nicht?)"; return; }
	alter=$((NOW - $(file_mtime "$f")))
	if [ "$alter" -gt "$HEARTBEAT_S" ]; then
		befund jobs "Lebenszeichen $alter s alt (Grenze $HEARTBEAT_S s): docker compose logs jobs; docker compose restart jobs"
	else
		ok jobs "Lebenszeichen $alter s alt"
	fi
}

# Loeschlauf (app/retention.py, taeglich ab 04:00): Endloeschung nach 30 Tagen und Protokollfristen. Nur ein
# erfolgreicher Lauf schreibt retention.log; scheitert er, wiederholt der Dienst ihn stuendlich (Audit P81-F4/P81-11).
# Fehlt die Datei (neuer Server vor dem ersten Lauf), kein Befund.
pruefe_loeschlauf() {
	finde_logs || return 0
	local f="$LOGS_DIR/retention.log" alter
	[ -f "$f" ] || { ok loeschlauf "noch kein Loeschlauf ($f fehlt)"; return 0; }
	alter=$(((NOW - $(file_mtime "$f")) / 3600))
	if [ "$alter" -ge "$RETENTION_H" ]; then
		befund loeschlauf "letzter Loeschlauf vor $alter h (Grenze $RETENTION_H h): docker compose logs jobs | grep retention; docker compose exec app python -m app.retention"
	else
		ok loeschlauf "letzter Loeschlauf vor $alter h"
	fi
}

pruefe_backup() {
	[ -d "$BACKUP_DIR" ] || { ok backup "kein Backup-Ordner $BACKUP_DIR"; return 0; }
	local neu alter
	neu="$(find "$BACKUP_DIR" -maxdepth 1 -name 'uniflow-*.tar.gz' -type f 2>/dev/null | while read -r f; do echo "$(file_mtime "$f") $f"; done | sort -n | tail -n1)"
	[ -n "$neu" ] || { befund backup "kein Archiv in $BACKUP_DIR (systemctl status uniflow-backup.timer)"; return; }
	alter=$(((NOW - ${neu%% *}) / 3600))
	if [ "$alter" -ge "$BACKUP_H" ]; then
		befund backup "neuestes Archiv ${neu#* } ist $alter h alt (Grenze $BACKUP_H h): journalctl -u uniflow-backup.service"
	else
		ok backup "neuestes Archiv $alter h alt"
	fi
}

# ---------------------------------------------------------------- 7b. Kopie ausser Haus (nur wenn eingerichtet)

# Wert aus der Umgebung, sonst aus deploy/.env - nur der genannte Name, nie andere Werte ausgeben
env_wert() {
	local v="${!1:-}"
	if [ -z "$v" ] && [ -r "$COMPOSE_DIR/.env" ]; then
		v="$(grep -E "^$1=" "$COMPOSE_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '"'"'"' \r' || true)"
	fi
	printf '%s' "$v"
}

pruefe_ausser_haus() {
	local konf merk alter
	konf="$(env_wert OFFSITE_HOST)$(env_wert OFFSITE_USER)$(env_wert OFFSITE_RECIPIENT)"
	[ -n "$konf" ] || { ok ausser_haus "nicht eingerichtet (OFFSITE_* in deploy/.env leer)"; return 0; }
	merk="$(env_wert OFFSITE_STATE_DIR)"
	merk="${merk:-/srv/uniflow/ausser-haus}/letzte-kopie"
	if [ ! -f "$merk" ]; then
		befund ausser_haus "noch keine erfolgreiche Kopie auf die Storage Box ($merk fehlt): journalctl -u uniflow-backup.service, bash deploy/backup-ausser-haus.sh"
		return
	fi
	alter=$(((NOW - $(file_mtime "$merk")) / 3600))
	if [ "$alter" -ge "$OFFSITE_H" ]; then
		befund ausser_haus "letzte erfolgreiche Kopie auf die Storage Box ist $alter h alt (Grenze $OFFSITE_H h): journalctl -u uniflow-backup.service, bash deploy/backup-ausser-haus.sh"
	else
		ok ausser_haus "letzte Kopie $alter h alt"
	fi
}

# ---------------------------------------------------------------- 8. HTTP von aussen (ueber Caddy, ohne DNS)

pruefe_http() {
	[ -n "$DOMAIN" ] && hat curl || return 0
	local code
	code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/login" 2>/dev/null || echo 000)"
	if [ "$code" != "200" ]; then
		befund http "GET https://$DOMAIN/login antwortet $code statt 200 (ueber 127.0.0.1:443)"
	else
		ok http "/login 200"
	fi
}

# ---------------------------------------------------------------- Lauf

pruefe_container
pruefe_platte
pruefe_ram
pruefe_zugriff
pruefe_zertifikat
pruefe_jobs
pruefe_loeschlauf
pruefe_backup
pruefe_ausser_haus
pruefe_http

# Erholung melden: Merkdatei vorhanden, Kennung heute nicht mehr betroffen
if [ -d "$STATE" ]; then
	for merk in "$STATE"/*.problem; do
		[ -e "$merk" ] || continue
		k="$(basename "$merk" .problem)"
		noch=0
		for x in "${KENNUNGEN[@]+"${KENNUNGEN[@]}"}"; do [ "$x" = "$k" ] && noch=1; done
		if [ "$noch" = 0 ]; then
			zeile "ERHOLT $k"
			[ "$TROCKEN" = 1 ] || rm -f "$merk"
		fi
	done
fi

if [ ${#BEFUNDE[@]} -eq 0 ]; then
	ok gesamt "alle Pruefungen bestanden"
	exit 0
fi

# Mail: nur Kennungen, fuer die in den letzten MAIL_EVERY_H Stunden keine Mail ging
neu=()
for b in "${BEFUNDE[@]}"; do
	k="${b%%|*}"
	merk="$STATE/$k.problem"
	if [ -f "$merk" ] && [ $((NOW - $(file_mtime "$merk"))) -lt $((MAIL_EVERY_H * 3600)) ]; then
		continue
	fi
	neu+=("$b")
done

if [ "$MAIL" = 1 ] && [ ${#neu[@]} -gt 0 ]; then
	host="$(hostname 2>/dev/null || echo server)"
	betreff="StudiNow dienst-check: ${#BEFUNDE[@]} Befund(e) auf $host"
	text="Dienstpruefung $STAMP auf $host${DOMAIN:+ ($DOMAIN)}:"$'\n'
	for b in "${BEFUNDE[@]}"; do text+=$'\n'"- ${b%%|*}: ${b#*|}"; done
	text+=$'\n\n'"Protokoll: $LOG"$'\n'"Naechste Mail zu denselben Kennungen fruehestens in $MAIL_EVERY_H h. Anleitung: docs/release/LAUNCH-4000-2026-11-08.md"
	if [ "$TROCKEN" = 1 ]; then
		echo "[trocken] docker compose -f $COMPOSE_DIR/docker-compose.yml exec -T app python -m app.mail send --to $MAIL_TO --subject \"$betreff\""
		echo "[trocken] Mailtext:"; echo "$text" | sed 's/^/[trocken]   /'
	else
		mkdir -p "$STATE"
		if echo "$text" | docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T app python -m app.mail send --to "$MAIL_TO" --subject "$betreff" >/dev/null 2>&1; then
			for b in "${neu[@]}"; do touch "$STATE/${b%%|*}.problem"; done
			zeile "MAIL an $MAIL_TO: ${#neu[@]} neue Kennung(en)"
		else
			zeile "MAIL-FEHLER an $MAIL_TO (python -m app.mail send; LERNAPP_SMTP_* in deploy/.env pruefen)"
		fi
	fi
elif [ "$TROCKEN" = 0 ]; then
	# ohne Mail trotzdem merken, dass das Problem bekannt ist (fuer ERHOLT)
	mkdir -p "$STATE"
	for b in "${BEFUNDE[@]}"; do [ -f "$STATE/${b%%|*}.problem" ] || touch "$STATE/${b%%|*}.problem"; done
fi
exit 1

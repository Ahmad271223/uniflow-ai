#!/usr/bin/env bash
# Lasttest AUF DEM ECHTEN SERVER, ohne den Produktionsdienst anzufassen (09.11.2026, Audit Pakete 62/82/84/87, Gate G5).
#
# Startet aus dem vorhandenen Image uniflow-app:latest (= exakt der Code, der produktiv laeuft) einen EIGENEN
# Wegwerf-Container und laesst darin die Lastwerkzeuge gegen einen eigenen Dienst laufen:
#   ki        tools/lasttest-ki.py        4.000 KI-Fragen gleichzeitig gegen die Attrappe tools/lasttest-ki-anbieter.py
#   anmeldung tools/lasttest-anmeldung.py 1.000 Registrierungen, 4.000 Anmeldungen, 4.000 Syncs, 3.000 gemischt (eine Campus-IP)
#   dauer     tools/lasttest-dauer.py     4.000 Sitzungen, 30 min, 400 Anfragen/s, KI-Anteil, ein API-Prozess per SIGKILL,
#                                         Wiederanlauf-Sturm, Pruefung: jeder bestaetigte Schreibvorgang ist gespeichert
#   restore   tools/restore-probe.py      (nur auf Wunsch) neuestes Archiv aus /srv/uniflow/backups NUR LESEND einbinden,
#                                         in den Wegwerf-Ordner auspacken, integrity_check jeder DB, Dienst auf den Daten
#                                         starten, Stichproben-Konten abfragen; Ausgabe nur Zahlen (Gate G6, P84-03)
# Waehrenddessen schreibt das Skript alle LT_TAKT Sekunden CPU/RAM des Hosts und `docker stats` (eigener Container und
# Produktion, nur lesend) mit; am Ende wird alles weggeraeumt. Ergebnisse: LT_OUT (Standard /root/lasttest/<zeit>/).
#
# Was den Produktionsdienst schuetzt (tests/test_audit_p58_87_golive.py prueft das mit einer docker-Attrappe):
#   - eigener Name uniflow-lasttest-<zeit>; das Skript ruft fuer Produktionscontainer nur `docker inspect`/`docker stats`
#     auf (lesen), nie exec/stop/restart/rm/kill, nie `docker compose`, nie ein Volume der Produktion
#   - einzige Einbindung: ein eigener Arbeitsordner unter /tmp/uniflow-lasttest-<zeit> (Daten, Protokolle, Werkzeuge,
#     Rechte 700); bei `restore` zusaetzlich das neueste Archiv als einzelne Datei NUR LESEND (:ro)
#   - --network none: der Container hat KEIN Netz nach aussen (nur sein eigenes 127.0.0.1) -> kein OpenAI-Aufruf, keine
#     Mail, kein Hochschulserver moeglich; keine .env der Produktion, keine Schluessel; LERNAPP_MAIL=log
#   - Grenzen: --memory LT_MEMORY_MB, --cpus LT_CPUS; vor dem Start genug freier Speicher (MemAvailable >= Grenze +
#     LT_RESERVE_MB) und Produktion "healthy"; Waechter bricht ab, wenn MemAvailable < LT_MIN_FREE_MB faellt oder die
#     Produktion "unhealthy" wird
#   - nur nachts (LT_ERLAUBT_VON..LT_ERLAUBT_BIS Uhr, Standard 0-7), sonst --auch-tagsueber
#
# Aufruf (als root auf dem Server; die Werkzeuge kommen per tar aus dem Repo, die Produktions-Checkout bleibt unberuehrt):
#   git archive HEAD tools/lasttest-server.sh tools/lasttest-ki.py tools/lasttest-ki-anbieter.py tools/lasttest-anmeldung.py \
#       tools/lasttest-dauer.py tools/lasttest_dienst.py | ssh -i ~/.ssh/studinow_server root@46.225.32.3 \
#       'rm -rf /root/studinow-lasttest && mkdir -p /root/studinow-lasttest && tar -x -C /root/studinow-lasttest'
#   ssh -i ~/.ssh/studinow_server root@46.225.32.3 'bash /root/studinow-lasttest/tools/lasttest-server.sh --trocken'
#   ssh -i ~/.ssh/studinow_server root@46.225.32.3 'nohup bash /root/studinow-lasttest/tools/lasttest-server.sh > /root/lasttest.log 2>&1 &'
#
# Optionen: --trocken (nur Vorpruefung und Plan, startet nichts)  --auch-tagsueber  --phasen "restore ki anmeldung dauer"  --help
# Umgebung (alle optional): LT_IMAGE LT_WORKERS LT_MEMORY_MB LT_CPUS LT_RESERVE_MB LT_MIN_FREE_MB LT_TAKT LT_OUT LT_REPO
#   LT_PROD ("uniflow-app uniflow-jobs uniflow-caddy") LT_OHNE_PROD=1 (Server ohne Produktion) LT_ERLAUBT_VON LT_ERLAUBT_BIS
#   KI:        LT_KI_FRAGEN (4000) LT_KI_KONTEN (400) LT_KI_DELAY (10) LT_KI_JITTER (10) LT_KI_NORMAL (300)
#   Anmeldung: LT_REGISTER (1000) LT_LOGINS (4000) LT_SYNCS (4000) LT_MIXED (3000) LT_PARALLEL (64) LT_UPLOADS (0) LT_UPLOAD_MB (5)
#   Dauer:     LT_DAUER_MIN (30) LT_SESSIONS (4000) LT_DAUER_KONTEN (1000) LT_RATE (400) LT_KILL_NACH (600) LT_STURM_S (60)
#              LT_DAUER_AI (1)
#   Restore:   LT_BACKUP_DIR (/srv/uniflow/backups) LT_STICHPROBEN (20)
# Exit: 0 = alle Phasen gelaufen und kein bestaetigter Schreibvorgang verloren, 1 = Phase gescheitert/abgebrochen,
#       2 = Vorpruefung verweigert (nichts gestartet).
set -euo pipefail
export LC_ALL=C           # Zahlen mit Punkt (awk), gleiche Ausgabe auf jedem Server

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

IMAGE="${LT_IMAGE:-uniflow-app:latest}"
NAME="uniflow-lasttest-$STAMP"
TMP_ROOT="${LT_TMP_ROOT:-/tmp}"
WORK="$TMP_ROOT/uniflow-lasttest-$STAMP"
OUT="${LT_OUT:-/root/lasttest/$STAMP}"
REPO="${LT_REPO:-/srv/uniflow/app}"
PROC="${LT_PROC:-/proc}"
PROD="${LT_PROD:-uniflow-app uniflow-jobs uniflow-caddy}"
WORKERS="${LT_WORKERS:-12}"
MEMORY_MB="${LT_MEMORY_MB:-6144}"
CPUS="${LT_CPUS:-6}"
RESERVE_MB="${LT_RESERVE_MB:-2048}"
MIN_FREE_MB="${LT_MIN_FREE_MB:-2048}"
TAKT="${LT_TAKT:-5}"
VON="${LT_ERLAUBT_VON:-0}"
BIS="${LT_ERLAUBT_BIS:-7}"
PHASEN="${LT_PHASEN:-ki anmeldung dauer}"
TROCKEN=0
TAGSUEBER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --trocken) TROCKEN=1 ;;
    --auch-tagsueber) TAGSUEBER=1 ;;
    --phasen) shift; PHASEN="${1:-}" ;;
    --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done

say() { echo "[lasttest $(date +%H:%M:%S)] $*"; }
verweigert() { echo "VERWEIGERT: $*" >&2; exit 2; }

# ---------------------------------------------------------------- Schutz: eigener Name, eigener Ordner

case " $PROD " in *" $NAME "*) verweigert "Name $NAME gehoert der Produktion" ;; esac
case "$NAME" in uniflow-lasttest-*) ;; *) verweigert "Name muss mit uniflow-lasttest- beginnen" ;; esac
case "$WORK" in "$TMP_ROOT"/uniflow-lasttest-*) ;; *) verweigert "Arbeitsordner $WORK liegt nicht unter $TMP_ROOT" ;; esac
for ph in $PHASEN; do
  case "$ph" in ki|anmeldung|dauer|restore) ;; *) verweigert "unbekannte Phase $ph (restore, ki, anmeldung, dauer)" ;; esac
done
TOOLS="lasttest-ki.py lasttest-ki-anbieter.py lasttest-anmeldung.py lasttest-dauer.py lasttest_dienst.py restore-probe.py"
for f in $TOOLS; do
  [ -f "$HERE/$f" ] || verweigert "Werkzeug fehlt: $HERE/$f"
done
ARCHIV=""
case " $PHASEN " in
  *" restore "*)
    BACKUP_DIR="${LT_BACKUP_DIR:-/srv/uniflow/backups}"
    ARCHIV="$(ls -1t "$BACKUP_DIR"/uniflow-*.tar.gz 2>/dev/null | head -n 1 || true)"
    [ -n "$ARCHIV" ] && [ -f "$ARCHIV" ] || verweigert "kein Archiv uniflow-*.tar.gz in $BACKUP_DIR (deploy/backup.sh)"
    ;;
esac

mem_avail_mb() { awk '/^MemAvailable:/ {print int($2 / 1024)}' "$PROC/meminfo"; }
mem_total_mb() { awk '/^MemTotal:/ {print int($2 / 1024)}' "$PROC/meminfo"; }
cpu_snapshot() { awk '/^cpu / {idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle}' "$PROC/stat"; }

# nur lesend: Name, Zustand, Gesundheit, Neustarts eines Produktionscontainers
prod_state() {
  docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}}' "$1" 2>/dev/null \
    || echo "/$1 fehlt - -"
}

# nur lesend, ohne Geheimnisse: Image, Start, Speichergrenze und ausgewaehlte Betriebswerte (nie die ganze Umgebung)
WHITELIST='^(WEB_CONCURRENCY|UVICORN_WORKERS|LERNAPP_MODE|LERNAPP_JOBS|LERNAPP_JOB_WORKERS|LERNAPP_LIMIT_[A-Z_]+|LERNAPP_LOGIN_FAILS_IP|LERNAPP_UPLOAD_QUOTA_MB|LERNAPP_DISK_MIN_FREE_MB|LERNAPP_AI_CONCURRENCY|LERNAPP_AI_TIMEOUT_S|LERNAPP_AI_DB_THREADS|LERNAPP_AI_RATE_PER_MINUTE|LERNAPP_AI_RATE_PER_HOUR|LERNAPP_AI_BUDGET_EUR|LERNAPP_AI_TRIAL_BUDGET_EUR|LERNAPP_FILES)='
prod_fingerprint() {
  echo "zeit=$(date -Is 2>/dev/null || date)"
  echo "repo_commit=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unbekannt)"
  echo "image_lasttest=$(docker image inspect --format '{{.Id}} {{.Created}}' "$IMAGE" 2>/dev/null || echo fehlt)"
  for c in $PROD; do
    echo "container=$(prod_state "$c")"
    echo "  image=$(docker inspect --format '{{.Image}} {{.Created}} mem={{.HostConfig.Memory}}' "$c" 2>/dev/null || echo -)"
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | grep -E "$WHITELIST" | sed 's/^/  env /' || true
  done
  echo "cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo ?) mem_total_mb=$(mem_total_mb) mem_avail_mb=$(mem_avail_mb)"
}

# ---------------------------------------------------------------- Vorpruefung (liest nur)

say "Vorpruefung"
docker image inspect "$IMAGE" >/dev/null 2>&1 || verweigert "Image $IMAGE fehlt (docker images)"
if [ "${LT_OHNE_PROD:-0}" != "1" ]; then
  st="$(prod_state uniflow-app)"
  case "$st" in *" running healthy "*) ;; *) verweigert "Produktion nicht gesund ($st) - erst den Dienst in Ordnung bringen" ;; esac
fi
avail="$(mem_avail_mb)"
[ "$avail" -ge $((MEMORY_MB + RESERVE_MB)) ] || verweigert "zu wenig freier Speicher: ${avail} MB frei, noetig $((MEMORY_MB + RESERVE_MB)) MB (LT_MEMORY_MB + LT_RESERVE_MB)"
stunde="$((10#${LT_STUNDE:-$(date +%H)}))"
if [ "$TAGSUEBER" != "1" ] && { [ "$stunde" -lt "$VON" ] || [ "$stunde" -ge "$BIS" ]; }; then
  verweigert "jetzt ${stunde} Uhr: der Lasttest teilt sich die CPU mit der Produktion - nur ${VON}-${BIS} Uhr, sonst --auch-tagsueber"
fi
free_tmp="$(df -Pm "$TMP_ROOT" | awk 'NR == 2 {print $4}')"
[ "$free_tmp" -ge "${LT_MIN_TMP_MB:-5120}" ] || verweigert "unter $TMP_ROOT nur ${free_tmp} MB frei, noetig ${LT_MIN_TMP_MB:-5120} MB"

say "Plan: Image $IMAGE, Container $NAME (--network none, ${MEMORY_MB} MB, ${CPUS} CPUs, ${WORKERS} API-Prozesse), Ordner $WORK, Phasen: $PHASEN"
[ -n "$ARCHIV" ] && say "Restore-Probe mit $ARCHIV (nur lesend eingebunden)"
if [ "$TROCKEN" = "1" ]; then
  prod_fingerprint
  say "Trockenlauf: nichts gestartet"
  exit 0
fi

# ---------------------------------------------------------------- Aufbau und Aufraeumen

mkdir -p "$OUT"
SAMPLER_PID=""
STARTED=0
cleanup() {
  code=$?
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true
  if [ "$STARTED" = "1" ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  case "$WORK" in "$TMP_ROOT"/uniflow-lasttest-*) rm -rf "$WORK" ;; esac
  say "aufgeraeumt: Container $NAME entfernt, $WORK geloescht; Ergebnisse in $OUT"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$WORK/tools" "$WORK/out" "$WORK/tmp" "$WORK/data" "$WORK/logs"
chmod 700 "$WORK"
for f in $TOOLS; do
  cp "$HERE/$f" "$WORK/tools/$f"
done
ARCHIV_MOUNT=""
# Sicherungen sind 0600 root (Datenschutz); der Container laeuft als uniflow (1000). Darum eine Kopie in den eigenen,
# 0700-geschuetzten Arbeitsordner, die mit ihm geloescht wird (Befund erster Serverlauf 09.11.2026: Permission denied)
if [ -n "$ARCHIV" ]; then
  cp "$ARCHIV" "$WORK/backup.tar.gz" && chmod 600 "$WORK/backup.tar.gz"
fi
[ "$(id -u)" = "0" ] && chown -R 1000:1000 "$WORK"
prod_fingerprint > "$OUT/produktion-vorher.txt"

say "starte Wegwerf-Container $NAME"
# shellcheck disable=SC2086
docker run -d --name "$NAME" --label studinow.lasttest=1 \
  --network none \
  --memory "${MEMORY_MB}m" --memory-swap "${MEMORY_MB}m" --cpus "$CPUS" --pids-limit 8192 \
  --ulimit nofile=65536:65536 --cap-drop ALL --security-opt no-new-privileges \
  -v "$WORK:/lt" -v "$WORK/data:/data" -v "$WORK/logs:/logs" $ARCHIV_MOUNT -w /srv/uniflow \
  -e TMPDIR=/lt/tmp -e LERNAPP_MODE=hosted -e LERNAPP_MAIL=log -e LERNAPP_JOBS=off -e LERNAPP_NO_SCHEDULER=1 \
  -e LERNAPP_DATA_DIR=/data -e LERNAPP_LOG_DIR=/logs -e PYTHONUNBUFFERED=1 \
  --entrypoint sleep "$IMAGE" infinity >/dev/null
STARTED=1

# ---------------------------------------------------------------- Mitschrift und Waechter

sampler() {
  echo "zeit;load1;cpu_belegt_pct;mem_total_mb;mem_avail_mb" > "$OUT/host.csv"
  : > "$OUT/docker-stats.csv"
  prev="$(cpu_snapshot)"
  while sleep "$TAKT"; do
    cur="$(cpu_snapshot)"
    busy="$(echo "$prev $cur" | awk '{dt = $3 - $1; di = $4 - $2; if (dt > 0) printf "%.1f", 100 * (dt - di) / dt; else print 0}')"
    prev="$cur"
    avail="$(mem_avail_mb)"
    echo "$(date +%H:%M:%S);$(cut -d' ' -f1 "$PROC/loadavg");$busy;$(mem_total_mb);$avail" >> "$OUT/host.csv"
    # shellcheck disable=SC2086
    docker stats --no-stream --format "$(date +%H:%M:%S);{{.Name}};{{.CPUPerc}};{{.MemUsage}}" "$NAME" $PROD >> "$OUT/docker-stats.csv" 2>/dev/null || true
    if [ "$avail" -lt "$MIN_FREE_MB" ]; then
      echo "ABBRUCH: nur noch ${avail} MB frei (< ${MIN_FREE_MB})" >> "$OUT/abbruch.txt"
      docker kill "$NAME" >/dev/null 2>&1 || true
      return
    fi
    if [ "${LT_OHNE_PROD:-0}" != "1" ]; then
      case "$(prod_state uniflow-app)" in
        *" unhealthy "*) echo "ABBRUCH: Produktion unhealthy" >> "$OUT/abbruch.txt"; docker kill "$NAME" >/dev/null 2>&1 || true; return ;;
      esac
    fi
  done
}
sampler &
SAMPLER_PID=$!

# ---------------------------------------------------------------- Phasen (alles im eigenen Container)

FEHLER=0
phase() {
  ph="$1"; tool="$2"; shift 2
  say "Phase $ph: $tool $*"
  rc=0
  docker exec "$NAME" python "/lt/tools/$tool" "$@" > "$OUT/$ph.txt" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    say "Phase $ph fertig"
  else
    say "Phase $ph GESCHEITERT (Exit $rc), siehe $OUT/$ph.txt"
    FEHLER=1
  fi
  [ -f "$WORK/out/$ph.json" ] && cp "$WORK/out/$ph.json" "$OUT/$ph.json"
  if [ -f "$OUT/abbruch.txt" ]; then
    say "$(cat "$OUT/abbruch.txt")"
    exit 1
  fi
  return 0
}

for ph in $PHASEN; do
  case "$ph" in
    ki)
      phase ki lasttest-ki.py --repo /srv/uniflow --workers "$WORKERS" --ai "${LT_KI_FRAGEN:-4000}" --normal "${LT_KI_NORMAL:-300}" \
        --accounts "${LT_KI_KONTEN:-400}" --delay "${LT_KI_DELAY:-10}" --jitter "${LT_KI_JITTER:-10}" --ramp 4 --label server \
        --json /lt/out/ki.json ;;
    anmeldung)
      phase anmeldung lasttest-anmeldung.py --repo /srv/uniflow --workers "$WORKERS" --parallel "${LT_PARALLEL:-64}" \
        --register "${LT_REGISTER:-1000}" --logins "${LT_LOGINS:-4000}" --syncs "${LT_SYNCS:-4000}" --mixed "${LT_MIXED:-3000}" \
        --uploads "${LT_UPLOADS:-0}" --upload-mb "${LT_UPLOAD_MB:-5}" \
        --env LERNAPP_LIMIT_REGISTER_IP=2000/60 --env LERNAPP_LIMIT_REGISTER_ALL=3000/60 --env LERNAPP_LOGIN_FAILS_IP=500 \
        --env LERNAPP_LIMIT_API_PER_MIN=300 --env LERNAPP_UPLOAD_QUOTA_MB=512 --label server --json /lt/out/anmeldung.json ;;
    restore)
      phase restore restore-probe.py /lt/backup.tar.gz --ziel /lt/tmp/restore --repo /srv/uniflow \
        --stichproben "${LT_STICHPROBEN:-20}" --json /lt/out/restore.json ;;
    dauer)
      ai_flag=""
      [ "${LT_DAUER_AI:-1}" = "1" ] && ai_flag="--ai"
      # shellcheck disable=SC2086
      phase dauer lasttest-dauer.py --repo /srv/uniflow --workers "$WORKERS" --sessions "${LT_SESSIONS:-4000}" \
        --accounts "${LT_DAUER_KONTEN:-1000}" --minuten "${LT_DAUER_MIN:-30}" --rate "${LT_RATE:-400}" \
        --kill-worker-nach "${LT_KILL_NACH:-600}" --sturm-sekunden "${LT_STURM_S:-60}" $ai_flag --label server \
        --json /lt/out/dauer.json ;;
  esac
done

kill "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""
prod_fingerprint > "$OUT/produktion-nachher.txt"

# Produktion unveraendert? Neustarts und Gesundheit vorher/nachher
grep '^container=' "$OUT/produktion-vorher.txt" > "$OUT/.v" || true
grep '^container=' "$OUT/produktion-nachher.txt" > "$OUT/.n" || true
if cmp -s "$OUT/.v" "$OUT/.n"; then
  say "Produktion unveraendert (Zustand und Neustarts gleich)"
else
  say "ACHTUNG: Produktion vorher/nachher verschieden:"; diff "$OUT/.v" "$OUT/.n" || true
fi
rm -f "$OUT/.v" "$OUT/.n"

{
  echo "# Lasttest auf dem Server $STAMP"
  echo
  echo "Container $NAME aus $IMAGE, --network none, ${MEMORY_MB} MB, ${CPUS} CPUs, ${WORKERS} API-Prozesse. Phasen: $PHASEN"
  echo
  echo '## Produktion vorher'; echo '```'; cat "$OUT/produktion-vorher.txt"; echo '```'
  for ph in $PHASEN; do
    echo; echo "## Phase $ph"; echo '```'; tail -n 40 "$OUT/$ph.txt" 2>/dev/null || echo "(keine Ausgabe)"; echo '```'
  done
  echo; echo '## Host (Spitzen)'
  awk -F';' 'NR > 1 {if ($3 + 0 > c) c = $3 + 0; if (m == "" || $5 + 0 < m) m = $5 + 0; l = ($2 + 0 > l) ? $2 + 0 : l} END {printf "CPU belegt max %.1f %%, MemAvailable min %s MB, load1 max %.2f (%d Proben)\n", c, m, l, NR - 1}' "$OUT/host.csv"
  echo; echo '## Produktion nachher'; echo '```'; cat "$OUT/produktion-nachher.txt"; echo '```'
} > "$OUT/ERGEBNIS.md"

if [ "$FEHLER" != "0" ]; then
  say "mindestens eine Phase gescheitert - $OUT/ERGEBNIS.md"
  exit 1
fi
say "fertig - $OUT/ERGEBNIS.md"
exit 0

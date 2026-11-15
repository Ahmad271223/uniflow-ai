# Gemeinsame Teile von tools/tests-schnell.sh und tools/tests-voll.sh (wird eingelesen, nicht selbst gestartet).
# Erklaerung der Laeufe: docs/TESTLAEUFE.md

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "Repo nicht gefunden"; exit 2; }

# Python: UF_PYTHON, sonst .venv des Repos, sonst .venv des Haupt-Checkouts (Worktrees haben keine eigene), sonst python3
uf_python() {
  if [ -n "${UF_PYTHON:-}" ]; then echo "$UF_PYTHON"; return; fi
  if [ -x "$ROOT/.venv/bin/python" ]; then echo "$ROOT/.venv/bin/python"; return; fi
  local common
  common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ] && [ -x "${common%/.git}/.venv/bin/python" ]; then echo "${common%/.git}/.venv/bin/python"; return; fi
  command -v python3
}
PY="$(uf_python)"

LOGDIR="${UF_TESTLOG_DIR:-${TMPDIR:-/tmp}/studinow-tests}"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y-%m-%d-%H%M%S)"

# Last des Rechners (1-Minuten-Mittel, ganze Zahl)
uf_last() {
  uptime | sed -E 's/.*load averages?: *([0-9]+)[.,].*/\1/'
}

# Dauer seit $1 (Sekunden seit 1970) als m:ss
uf_dauer() {
  local s=$(( $(date +%s) - $1 ))
  printf '%d:%02d min' $(( s / 60 )) $(( s % 60 ))
}

# pytest starten: uf_pytest <Protokolldatei> <Optionen …>; Rueckgabe wie pytest
uf_pytest() {
  local log="$1"; shift
  COLUMNS=400 "$PY" -m pytest -q -p no:cacheprovider "$@" > "$log" 2>&1
}

# letzte Zeile von pytest ("3 failed, 3602 passed, 5 skipped … in 480.03s") in Deutsch: "3602 bestanden, 3 rot, …"
uf_zusammenfassung() {
  local line out="" n pair
  line="$(grep -E '[0-9]+ (passed|failed|errors?|skipped|deselected)[^=]* in [0-9.]+s' "$1" | tail -1)"
  if [ -z "$line" ]; then echo "kein Ergebnis (pytest abgebrochen?)"; return; fi
  for pair in "passed:bestanden" "failed:rot" "errors?:Fehler" "skipped:übersprungen" "xfailed:erwartet rot" "deselected:abgewählt"; do
    n="$(echo "$line" | grep -oE "[0-9]+ ${pair%%:*}" | head -1 | grep -oE '^[0-9]+')"
    [ -n "$n" ] && out="${out}${out:+, }${n} ${pair##*:}"
  done
  echo "$out"
}

# rote Tests (FAILED/ERROR in der Kurzuebersicht), je Zeile eine Kennung wie tests/test_x.py::test_y[param]
uf_rote() {
  grep -E '^(FAILED|ERROR) ' "$1" | sed -E 's/^(FAILED|ERROR) //; s/ - .*$//' | sort -u
}

# Browser-Logik: node --test tests/js/ ; Ausgabe eine Zeile, Rueckgabe 0 = bestanden
uf_node() {
  local log="$1"
  if ! command -v node > /dev/null; then echo "node: rot – node nicht gefunden"; return 1; fi
  if node --test tests/js/ > "$log" 2>&1; then
    echo "node: bestanden ($(sed -nE 's/^.* pass ([0-9]+)$/\1/p' "$log" | tail -1) Tests)"
    return 0
  fi
  echo "node: rot ($(sed -nE 's/^.* fail ([0-9]+)$/\1/p' "$log" | tail -1) von $(sed -nE 's/^.* tests ([0-9]+)$/\1/p' "$log" | tail -1) Tests) – Protokoll: $log"
  return 1
}

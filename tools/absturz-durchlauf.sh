#!/bin/zsh
# Durchlauf der Absturzmeldung vom Geraete-Code bis in die Auswertung (docs/ABSTURZMELDUNG-2026-11-25.md):
#   1. startet den echten Dienst (LERNAPP_MODE=hosted) lokal mit einem Wegwerf-Datenordner,
#   2. laesst den Swift-Kern eine erfundene Absturzmeldung schicken (CrashReportLiveTests: Apples Datenformat ->
#      Warteschlange -> POST /api/diagnose/crashes),
#   3. liest die Auswertung (tools/absturz-auswertung.py) und prueft die Zahlen.
# Nichts geht ins Netz, nichts an den echten Dienst. Aufruf: tools/absturz-durchlauf.sh [Port]
# Rueckgabe 0 = Durchlauf bestanden.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
PORT="${1:-8937}"
if [ -n "${UF_PYTHON:-}" ]; then PY="$UF_PYTHON"
elif [ -x "$ROOT/.venv/bin/python" ]; then PY="$ROOT/.venv/bin/python"
else
  COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$COMMON" ] && [ -x "${COMMON%/.git}/.venv/bin/python" ]; then PY="${COMMON%/.git}/.venv/bin/python"; else PY="$(command -v python3)"; fi
fi
DATA="$(mktemp -d "${TMPDIR:-/tmp}/absturz-durchlauf.XXXXXX")"
export LERNAPP_MODE=hosted LERNAPP_DATA_DIR="$DATA" LERNAPP_LOG_DIR="$DATA" LERNAPP_ENV_FILE="$DATA/leer.env" LERNAPP_NO_SCHEDULER=1 LERNAPP_JOBS=off

"$PY" -c "import sys, uvicorn; from app import server; uvicorn.run(server.app, host='127.0.0.1', port=int(sys.argv[1]), log_level='warning')" "$PORT" > "$DATA/dienst.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$DATA"' EXIT

echo "== 1. Dienst startet (Port $PORT, Daten in einem Wegwerf-Ordner) =="
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$PORT/api/account/info" > /dev/null 2>&1 && break
  kill -0 $PID 2>/dev/null || { echo "Dienst ist nicht gestartet:"; tail -20 "$DATA/dienst.log"; exit 1; }
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$PORT/api/account/info" > /dev/null 2>&1 || { echo "Dienst antwortet nicht."; tail -20 "$DATA/dienst.log"; exit 1; }

echo "== 2. Geraete-Code schickt eine erfundene Absturzmeldung (swift test CrashReportLiveTests) =="
( cd apps/apple/Packages/UniFlowCore && CRASH_TEST_SERVICE="http://127.0.0.1:$PORT" swift test --filter CrashReportLiveTests ) > "$DATA/swift.log" 2>&1
RC=$?
grep -E "Executed [0-9]+ test" "$DATA/swift.log" | tail -1
if [ $RC -ne 0 ] || grep -q "test skipped" "$DATA/swift.log" || ! grep -q "Executed 1 test, with 0 failures" "$DATA/swift.log"; then
  echo "Swift-Test rot oder übersprungen:"; grep -E "error|failed|skipped" "$DATA/swift.log" | tail -10; exit 1
fi

echo "== 3. Auswertung =="
"$PY" tools/absturz-auswertung.py --tage 2 || exit 1
"$PY" tools/absturz-auswertung.py --tage 2 --json > "$DATA/auswertung.json" || exit 1
"$PY" - "$DATA/auswertung.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
rows = {(r["version"], r["device"], r["source"]): (r["crashes"], r["hangs"], r["devices"]) for r in s["rows"]}
exits = {r["reason"]: r["count"] for r in s["exits"]}
want_rows = {("1.0.6 (45)", "ipad", "store"): (1, 1, 1), ("1.0.5 (44)", "ipad", "test"): (1, 0, 1)}
want_exits = {"memory_limit": 2, "bad_access": 1}
ok = (s["crashes"], s["hangs"]) == (2, 1) and rows == want_rows and exits == want_exits
print("ERGEBNIS: bestanden – 2 Abstürze und 1 Hänger sind vom Geräte-Code über den Dienst in der Auswertung angekommen." if ok
      else f"ERGEBNIS: rot – erwartet {want_rows} / {want_exits}, bekommen {rows} / {exits}")
sys.exit(0 if ok else 1)
PYEOF

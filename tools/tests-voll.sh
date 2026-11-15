#!/bin/zsh
# Voller Lauf: ALLE Python-Tests einschliesslich der Lasttests (Marker `last`), danach die Browser-Logik
# (node --test tests/js/). Einmal vor einem Build – und NIE zwei volle Laeufe zugleich: die Lasttests starten viele
# Prozesse, zwei bis drei volle Laeufe nebeneinander treiben die Last des Rechners ueber 300 und lassen Tests kippen.
# Fuer zwischendurch (Agents, Sitzungen): tools/tests-schnell.sh. Welcher Lauf wann: docs/TESTLAEUFE.md
#
# Aufruf:  tools/tests-voll.sh [weitere pytest-Optionen]
# Ablauf:  1. startet nicht, wenn schon ein voller Lauf laeuft (Sperre) oder die Last des Rechners ueber der Grenze liegt
#          2. pytest mit allen Tests
#          3. jeder rote Test, der ein bekannter Wackel-Test ist (tests/wackeltests.txt oder ein Lasttest), laeuft EINMAL
#             einzeln noch einmal; gruen -> "wiederholt", sonst rot. Alle anderen roten Tests bleiben rot.
#          4. node --test tests/js/
# Ausgabe: je Teil eine Zeile (bestanden / rot / wiederholt), am Ende ERGEBNIS.
# Rueckgabe: 0 = bestanden (auch wenn Wackel-Tests erst in der Wiederholung gruen waren), 1 = rot, 2 = nicht gestartet
# Umgebung: UF_PYTHON, UF_TESTLOG_DIR, UF_TESTS_MAX_LAST (Grenze der Rechnerlast, Vorgabe 20; 0 = nicht pruefen),
#           UF_TESTS_LOCK (Sperr-Ordner)

set -u
. "$(dirname "$0")/tests-lib.sh"

MAX="${UF_TESTS_MAX_LAST:-20}"
if [ -d "$HOME/Studora-Builds" ]; then LOCK_DEFAULT="$HOME/Studora-Builds/tests-voll.lock"; else LOCK_DEFAULT="${TMPDIR:-/tmp}/studinow-tests-voll.lock"; fi
LOCK="${UF_TESTS_LOCK:-$LOCK_DEFAULT}"

# 1. Sperre: ein voller Lauf je Rechner (Ordner anlegen ist unteilbar); eine Sperre ohne lebenden Prozess wird ersetzt
if ! mkdir "$LOCK" 2>/dev/null; then
  other="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "NICHT GESTARTET: es läuft schon ein voller Lauf (Prozess $other, seit $(cat "$LOCK/seit" 2>/dev/null), Ordner $(cat "$LOCK/ordner" 2>/dev/null))."
    echo "Volle Läufe nie nebeneinander – warten oder tools/tests-schnell.sh nehmen."
    exit 2
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" || { echo "NICHT GESTARTET: Sperre $LOCK lässt sich nicht anlegen"; exit 2; }
fi
echo $$ > "$LOCK/pid"; date '+%d.%m.%Y %H:%M' > "$LOCK/seit"; echo "$ROOT" > "$LOCK/ordner"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 130' INT TERM

# fremder voller Lauf ohne dieses Skript: ein pytest ohne `not last` und ohne einzelne Testdatei
fremd="$(pgrep -fl '[Pp]ython.* -m pytest' 2>/dev/null | sed -E 's/--(ignore|deselect)=[^ ]*//g' | grep -v 'not last' | grep -vE 'tests/test_[A-Za-z0-9_]+\.py' | grep -v -- '--collect-only')"
if [ -n "$fremd" ]; then
  echo "NICHT GESTARTET: es läuft schon ein voller pytest-Lauf (ohne dieses Skript gestartet):"
  echo "$fremd" | cut -c1-160 | sed 's/^/  /'
  exit 2
fi
last="$(uf_last)"
if [ "$MAX" -gt 0 ] && [ "$last" -ge "$MAX" ]; then
  echo "NICHT GESTARTET: Last des Rechners $last (Grenze $MAX). Warten, bis andere Läufe fertig sind (uptime),"
  echo "oder mit UF_TESTS_MAX_LAST=0 trotzdem starten."
  exit 2
fi

LOG="$LOGDIR/voll-$STAMP.log"
NODELOG="$LOGDIR/voll-$STAMP-node.log"
echo "== Voller Lauf (mit Lasttests) – Last des Rechners: $last =="

# 2. alle Tests
t0=$(date +%s)
uf_pytest "$LOG" --ignore=tests/test_pwa.py "$@"
rc=$?
echo "pytest: $(uf_zusammenfassung "$LOG") ($(uf_dauer $t0))"

# 3. bekannte Wackel-Tests einmal einzeln wiederholen
bekannt() {      # bekannt <tests/datei.py::name[param]>: steht der Test in wackeltests.txt oder lasttests.txt?
  local id="${1#tests/}"
  local file="${id%%::*}" name="${id#*::}"
  name="${name%%\[*}"
  sed -E 's/#.*$//; s/[[:space:]]+$//' "$ROOT/tests/wackeltests.txt" "$ROOT/tests/lasttests.txt" | grep -qxF -e "${file}" -e "${file}::${name}"
}
rot=0; wiederholt=0
if [ $rc -ne 0 ]; then
  rote="$(uf_rote "$LOG")"
  if [ -z "$rote" ]; then
    rot=1
    echo "  rot: pytest endete mit Fehler $rc ohne Liste roter Tests – Protokoll ansehen"
  fi
  i=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if bekannt "$id"; then
      i=$((i+1))
      if uf_pytest "$LOGDIR/voll-$STAMP-wiederholung-$i.log" "$id"; then
        wiederholt=$((wiederholt+1))
        echo "  wiederholt: $id – im vollen Lauf rot, einzeln grün (bekannter Wackel-Test)"
      else
        rot=$((rot+1))
        echo "  rot: $id – auch einzeln rot (Protokoll: $LOGDIR/voll-$STAMP-wiederholung-$i.log)"
      fi
    else
      rot=$((rot+1))
      echo "  rot: $id – kein bekannter Wackel-Test, nicht wiederholt"
    fi
  done <<< "$rote"
fi

# 4. Browser-Logik
uf_node "$NODELOG" || rot=$((rot+1))

if [ $rot -ne 0 ]; then
  echo "ERGEBNIS: rot – Protokoll: $LOG"
  exit 1
fi
if [ $wiederholt -ne 0 ]; then
  echo "ERGEBNIS: bestanden, $wiederholt wiederholt (Wackel-Tests erst einzeln grün) – Protokoll: $LOG"
else
  echo "ERGEBNIS: bestanden"
fi
exit 0

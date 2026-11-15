#!/bin/zsh
# Schneller Lauf: alle Python-Tests OHNE die Lasttests (Marker `last`, tests/lasttests.txt), danach die Browser-Logik
# (node --test tests/js/). Fuer Agents und Sitzungen: darf neben anderen schnellen Laeufen laufen.
# Der volle Lauf (mit Lasttests, einmal vor einem Build, nie zwei zugleich) ist tools/tests-voll.sh.
# Welcher Lauf wann: docs/TESTLAEUFE.md
#
# Aufruf:  tools/tests-schnell.sh [weitere pytest-Optionen oder Testdateien]
#   z. B.  tools/tests-schnell.sh tests/test_accounts.py          nur diese Datei (weiter ohne Lasttests)
# Ausgabe: je Teil eine Zeile (bestanden / rot), am Ende ERGEBNIS. Rueckgabe 0 = bestanden, 1 = rot.
# Umgebung: UF_PYTHON (Python mit pytest), UF_TESTLOG_DIR (Ordner fuer die Protokolle)

set -u
. "$(dirname "$0")/tests-lib.sh"

LOG="$LOGDIR/schnell-$STAMP.log"
NODELOG="$LOGDIR/schnell-$STAMP-node.log"
echo "== Schneller Lauf (ohne Lasttests) – Last des Rechners: $(uf_last) =="

t0=$(date +%s)
uf_pytest "$LOG" --ignore=tests/test_pwa.py -m "not last" "$@"
rc=$?
echo "pytest: $(uf_zusammenfassung "$LOG") ($(uf_dauer $t0))"
rot=0
if [ $rc -ne 0 ]; then
  rot=1
  uf_rote "$LOG" | sed 's/^/  rot: /'
fi

uf_node "$NODELOG" || rot=1

if [ $rot -eq 0 ]; then
  echo "ERGEBNIS: bestanden"
else
  echo "ERGEBNIS: rot – Protokoll: $LOG"
  [ "$(uf_last)" -ge 20 ] && echo "Hinweis: Last des Rechners $(uf_last). Unter Last kippen Browser- und Zeit-Tests; rote Tests einzeln wiederholen."
fi
exit $rot

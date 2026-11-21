#!/bin/bash
# Zaehlt in der laufenden App eines Simulators, wie viele Editoren und Dokumente im Speicher liegen, waehrend
# UniFlowUITests/SpeicherReiterUITests die Reiter wechselt (docs/SPEICHER-STAND.md). Erwartet: immer genau 1.
#
#   tools/speicher-reiter-zaehlen.sh <Simulator-UDID> <xcodebuild-Log> <Ausgabe>   (vor xcodebuild im Hintergrund starten)
#   TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=speicher xcodebuild test ... -only-testing:UniFlowUITests/SpeicherReiterUITests > <Log>
U=$1; LOG=$2; OUT=$3; : > "$OUT"; seen=0
for _ in $(seq 1 1500); do
  n=$(grep -c "^UFSPEICHER halt" "$LOG" 2>/dev/null); n=${n:-0}
  if [ "$n" -gt "$seen" ]; then
    seen=$n; sleep 4
    pid=$(pgrep -f "$U/data/Containers/Bundle/Application/.*/UniFlow.app/UniFlow" | head -1)
    echo "=== $(grep "^UFSPEICHER halt" "$LOG" | tail -1) $(grep "^UFSPEICHER wechsel" "$LOG" | tail -1)" >> "$OUT"
    heap "$pid" 2>/dev/null | awk '$4 ~ /^(UniFlow\.)?(PDFEditorController|DocumentStore|PageInkView|SyncEngine)$/ || $4 ~ /UIKitSplitViewController$/ || $4 == "PDFView" {print "  "$1" x "$4}' >> "$OUT"
    footprint "$pid" 2>/dev/null | grep -m1 "Footprint:" >> "$OUT"
  fi
  grep -q "Executed .* test\|TEST FAILED\|TEST SUCCEEDED" "$LOG" 2>/dev/null && break
  sleep 1
done
echo fertig >> "$OUT"

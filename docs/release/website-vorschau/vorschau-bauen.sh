#!/bin/zsh
# Baut vorschau.jpg (1200 x 630) aus vorschau-quelle.html: doppelt so gross rendern, verkleinern, als JPEG speichern.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1200,630 \
  --screenshot="$PWD/.vorschau.png" "file://$PWD/vorschau-quelle.html" >/dev/null 2>&1
sips -z 630 1200 -s format jpeg -s formatOptions 68 .vorschau.png --out vorschau.jpg >/dev/null
rm -f .vorschau.png
ls -l vorschau.jpg

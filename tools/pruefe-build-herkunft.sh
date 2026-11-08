#!/bin/bash
# Prueft, ob ~/Studora-Builds/export-bNN genau aus <commit> stammt (docs/release/BUILD-HERKUNFT.md, Audit P46-01).
# Aufruf aus dem Repository: tools/pruefe-build-herkunft.sh 25 d08cae54
# Erlaubt sind nur die beim Bauen erzeugten Dateien (Team.xcconfig, UniFlow.xcodeproj, Info.plist, .swiftpm).
set -euo pipefail
NUM="${1:?Build-Nummer fehlt}"
COMMIT="${2:?Commit fehlt}"
BUILDS="${STUDORA_BUILDS:-$HOME/Studora-Builds}"
EXPORT="$BUILDS/export-b$NUM"
ARCHIVE="$BUILDS/StudiNow-$NUM.xcarchive"
cd "$(dirname "$0")/.."
test -d "$EXPORT" || { echo "kein Export-Ordner $EXPORT"; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
git archive "$COMMIT" | tar -x -C "$TMP"
DIFF="$(diff -rq "$TMP" "$EXPORT" 2>&1 \
  | grep -v -e "/apps/apple/Config: Team.xcconfig$" -e "/apps/apple: UniFlow.xcodeproj$" \
            -e "/apps/apple/UniFlow: Info.plist$" -e "/apps/apple/Packages/UniFlowCore: .swiftpm$" || true)"
if [ -n "$DIFF" ]; then
  echo "Build $NUM stammt NICHT aus $COMMIT:"
  echo "$DIFF" | head -20
  exit 1
fi
echo "Export-Ordner export-b$NUM = git archive $COMMIT (bis auf erzeugte Dateien)"
if [ -d "$ARCHIVE" ]; then
  V="$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist")"
  U="$(/usr/libexec/PlistBuddy -c "Print :UFShippedUniversities" "$ARCHIVE/Products/Applications/UniFlow.app/Info.plist" 2>/dev/null || echo "?")"
  echo "Archiv StudiNow-$NUM.xcarchive: CFBundleVersion $V, UFShippedUniversities $U"
  test "$V" = "$NUM" || { echo "Build-Nummer im Archiv weicht ab"; exit 1; }
fi

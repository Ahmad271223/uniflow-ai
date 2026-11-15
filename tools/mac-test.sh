#!/bin/zsh
# Tests am Mac ("Designed for iPad") im eigenen, leeren Datenordner – nie in dem der installierten StudiNow-App.
# Hintergrund: docs/MAC-TESTLAUF-EIGENER-ORDNER-2026-11-14.md
#
# Aufruf (aus dem Repo oder einem Worktree):
#   tools/mac-test.sh -only-testing:UniFlowTests/MacTestIsolationTests [-only-testing:UniFlowTests/…]
#   ohne Angabe: alle Klassen von UniFlowTests (dauert am Mac ueber eine halbe Stunde; besser klassenweise)
#
# Was das Skript tut:
#   1. baut die App fuer den Mac mit der Test-Kennung de.uniflow.ai.mactest (UF_DEBUG_BUNDLE_ID, nur Debug), ohne
#      "Mit Apple anmelden", iCloud und Community-Container (apps/apple/Config/MacTest.entitlements; dafuer braeuchte
#      die Test-Kennung einen eigenen Eintrag im Apple-Entwicklerkonto; so reicht das allgemeine Team-Profil und im
#      Konto aendert sich nichts)
#   2. prueft die Signatur der gebauten App: Kennung und Schluesselbund-Bereich muessen die des Tests sein; sonst Abbruch
#      vor dem ersten Start
#   3. startet die Tests und meldet die App danach beim System wieder ab (Links uniflow:// und *.uniflowsolution
#      sollen bei der installierten App bleiben)
#
# Der Mac muss entsperrt und wach sein; es oeffnen sich StudiNow-Fenster (leere Test-App).
# Umgebung: UF_TEAM (Vorgabe 78MQGF36BD), UF_MACTEST_DD (Bauordner), UF_MACTEST_LOG (Protokolldatei)

set -u
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM="${UF_TEAM:-78MQGF36BD}"
TEST_ID="de.uniflow.ai.mactest"
REAL_ID="de.uniflow.ai"
DD="${UF_MACTEST_DD:-$HOME/Studora-Builds/dd-mactest}"
LOG="${UF_MACTEST_LOG:-$HOME/Studora-Builds/mac-test/$(date +%Y-%m-%d-%H%M%S).log}"
DEST="platform=macOS,arch=arm64,variant=Designed for iPad"
APP="$DD/Build/Products/Debug-iphoneos/UniFlow.app"

cd "$(dirname "$0")/../apps/apple" || { echo "apps/apple nicht gefunden"; exit 2; }
mkdir -p "$(dirname "$LOG")"

locked=$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null)
if [ "$locked" = "true" ]; then
  echo "Der Mac ist gesperrt. Bitte entsperren und noch einmal starten (gesperrt kommt der Testprozess nicht in Gang)."
  exit 2
fi

xcodegen generate -q || { echo "xcodegen ist fehlgeschlagen"; exit 2; }

# fuer alle xcodebuild-Aufrufe gleich; leere Berechtigungen (Config/MacTest.entitlements; ein leerer Wert allein
# genuegt Xcode nicht) = allgemeines Team-Profil, kein neuer Eintrag bei Apple. Bewusst ohne -allowProvisioningUpdates.
settings=(UF_DEBUG_BUNDLE_ID=$TEST_ID DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic
          CODE_SIGN_ENTITLEMENTS=Config/MacTest.entitlements UF_CLOUDKIT_CONTAINER=)

echo "Baue fuer den Mac mit der Test-Kennung $TEST_ID … (Protokoll: $LOG)"
xcodebuild build-for-testing -project UniFlow.xcodeproj -scheme UniFlow -destination "$DEST" -derivedDataPath "$DD" \
  "${settings[@]}" > "$LOG" 2>&1
if [ $? -ne 0 ]; then
  grep -E "error:|\*\* TEST BUILD" "$LOG" | tail -20
  echo "Bau fehlgeschlagen."
  exit 1
fi

# Signatur pruefen, bevor die App das erste Mal startet: eine frische App raeumt beim ersten Start "Reste einer
# frueheren Installation" im Schluesselbund weg – das darf nur den eigenen Bereich des Tests treffen
bundle_id=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist" 2>/dev/null)
ent=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
app_id=$(print -r -- "$ent" | plutil -extract application-identifier raw - 2>/dev/null)
groups=$(print -r -- "$ent" | plutil -extract keychain-access-groups json - 2>/dev/null)
if [ "$bundle_id" != "$TEST_ID" ] || [ "$app_id" != "$TEAM.$TEST_ID" ] || [ "$groups" != "[\"$TEAM.$TEST_ID\"]" ]; then
  echo "Abbruch vor dem Start: Die gebaute App hat nicht die Test-Kennung oder nicht nur den eigenen Schlüsselbund-Bereich."
  echo "  Kennung: $bundle_id   App-ID: $app_id   Schlüsselbund: $groups"
  exit 1
fi
if print -r -- "$ent" | grep -q "$TEAM.$REAL_ID<\|icloud\|applesignin"; then
  echo "Abbruch vor dem Start: Die Signatur nennt Bereiche der echten App (iCloud, Mit Apple anmelden oder deren Kennung)."
  exit 1
fi
echo "Signatur in Ordnung: $app_id, eigener Schlüsselbund-Bereich."

if [ $# -eq 0 ]; then set -- -only-testing:UniFlowTests; fi
xcodebuild test-without-building -project UniFlow.xcodeproj -scheme UniFlow -destination "$DEST" -derivedDataPath "$DD" \
  "${settings[@]}" "$@" >> "$LOG" 2>&1
code=$?

# die Test-App beim System abmelden (sie nennt dieselben Links und Dateitypen wie die installierte App)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1

grep -E "error:|Test Case .* failed|Executed [0-9]+ test|\*\* TEST|Testlauf am Mac abgebrochen" "$LOG" | grep -v "warning\|BUG IN" | tail -40
echo "EXIT $code   Protokoll: $LOG"
exit $code

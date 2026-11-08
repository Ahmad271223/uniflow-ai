#!/usr/bin/env bash
# Laedt den Ordner site/ als neuen Produktions-Deploy zu Netlify hoch (Projekt startling-longma-7d7cdf = studinow.app).
# Voraussetzung: Netlify-Zugangsschluessel in ~/Studora-Builds/private_keys/netlify-token.txt (Netlify: User settings ->
# Applications -> Personal access tokens). Aufruf nach `python tools/gen-site.py`:  tools/site-hochladen.sh
set -euo pipefail
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_ID="${NETLIFY_SITE_ID:-fbcb5657-c8cc-49d0-80ad-fdecd3af1cd9}"
TOKEN_DATEI="${NETLIFY_TOKEN_DATEI:-$HOME/Studora-Builds/private_keys/netlify-token.txt}"
[ -r "$TOKEN_DATEI" ] || { echo "Netlify-Schluessel fehlt: $TOKEN_DATEI" >&2; exit 1; }
[ -f "$HIER/site/index.html" ] || { echo "site/index.html fehlt – erst python tools/gen-site.py" >&2; exit 1; }
ZIP="$(mktemp -t studinow-site).zip"
(cd "$HIER/site" && zip -qr "$ZIP" . -x '.DS_Store')
ANTWORT="$(curl -sS -X POST -H "Authorization: Bearer $(cat "$TOKEN_DATEI")" -H "Content-Type: application/zip" \
  --data-binary @"$ZIP" "https://api.netlify.com/api/v1/sites/$SITE_ID/deploys?title=$(date +%Y-%m-%d_%H%M)")"
rm -f "$ZIP"
ID="$(printf '%s' "$ANTWORT" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id") or ""); import os; os._exit(0 if d.get("id") else 1)')" \
  || { echo "Upload fehlgeschlagen: $ANTWORT" >&2; exit 1; }
for i in $(seq 1 24); do
  STATE="$(curl -sS -H "Authorization: Bearer $(cat "$TOKEN_DATEI")" "https://api.netlify.com/api/v1/deploys/$ID" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state", "unbekannt"))')"
  [ "$STATE" = "ready" ] && break
  [ "$STATE" = "error" ] && { echo "Deploy $ID fehlgeschlagen" >&2; exit 1; }
  sleep 5
done
echo "Deploy $ID: $STATE"
for p in "" datenschutz impressum support konto-loeschen nutzungsbedingungen; do
  printf '  https://studinow.app/%-22s %s\n' "$p" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://studinow.app/$p")"
done

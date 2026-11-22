#!/usr/bin/env bash
# Laedt Formelblaetter (katalog.json + PDFs) auf den Server (app/formelblatt.py). Laeuft auf dem Mac des Inhabers.
# Die PDFs und der Katalog gehoeren NICHT ins oeffentliche Repo; sie liegen in einem eigenen Ordner auf dem Mac.
#
#   tools/formelblatt-hochladen.sh [--dry-run] [--quelle ORDNER] [--schluessel PFAD] SERVER_IP
#
# Uebertragen werden nur katalog.json und *.pdf aus ORDNER (Standard ~/Studora-Builds/formelblaetter).
# Ablauf: rsync in /srv/uniflow/formelblatt-upload, dann Tausch gegen /data/formelblatt im Daten-Volume; der Dienst
# liest den Katalog beim naechsten Zugriff neu (kein Neustart). Danach zeigt eine Pruefung im Container die Eintraege.
set -euo pipefail

QUELLE="${HOME}/Studora-Builds/formelblaetter"
SSH_KEY="${HOME}/.ssh/studinow_server"
SSH_USER="root"
STAGE="/srv/uniflow/formelblatt-upload"
VOL_DATA="uniflow_uniflow-data"
DEPLOY_DIR="/srv/uniflow/app/deploy"
DRY=0
SERVER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quelle) QUELLE="$2"; shift ;;
    --schluessel) SSH_KEY="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    *) SERVER="$1" ;;
  esac
  shift
done

[ -n "$SERVER" ] || { echo "Aufruf: tools/formelblatt-hochladen.sh [--dry-run] SERVER_IP" >&2; exit 2; }
[ -f "$QUELLE/katalog.json" ] || { echo "katalog.json fehlt in $QUELLE" >&2; exit 1; }
python3 -c 'import json,sys,os; k=json.load(open(sys.argv[1])); d=os.path.dirname(sys.argv[1])
for b in k.get("blaetter", []):
    f=os.path.join(d, os.path.basename(b.get("datei","")))
    print(("ok    " if os.path.isfile(f) else "FEHLT ")+b.get("id","?")+"  "+str(b.get("credits"))+" Credits  "+f)' "$QUELLE/katalog.json"

FILTER=(--include='/katalog.json' --include='/*.pdf' --exclude='*')
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SERVER")
if [ "$DRY" = 1 ]; then
  rsync -an --delete --itemize-changes "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/"
  echo "(Probelauf: nichts uebertragen)"
  exit 0
fi

"${SSH[@]}" "mkdir -p '$STAGE' && chmod 700 '$STAGE'"
rsync -a --delete "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/"
"${SSH[@]}" "docker run --rm -v $VOL_DATA:/data -v '$STAGE':/neu:ro alpine sh -c '
  set -e
  rm -rf /data/formelblatt.neu /data/formelblatt.alt
  cp -r /neu /data/formelblatt.neu
  chmod -R a+rX,go-w /data/formelblatt.neu
  if [ -d /data/formelblatt ]; then mv /data/formelblatt /data/formelblatt.alt; fi
  mv /data/formelblatt.neu /data/formelblatt
  rm -rf /data/formelblatt.alt
  echo \"im Volume: \$(ls /data/formelblatt | wc -l) Dateien\"'"
"${SSH[@]}" "cd '$DEPLOY_DIR' && docker compose exec -T app python -c 'from app import formelblatt as f; print([(i[\"id\"], i[\"hochschule\"], i[\"credits\"], i[\"module\"]) for i in f.catalog()])'" || \
  echo "Pruefung im Container nicht moeglich (Dienst aus?)." >&2

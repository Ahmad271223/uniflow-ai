#!/usr/bin/env bash
# Laedt die private Wissensbibliothek als StudiNow-Wissensbank auf den Server (app/wissensbank.py, docs/WISSENSBANK.md).
# Laeuft auf dem Mac des Inhabers. Uebertragen werden NUR katalog.json und die Text-Dateien der Einheiten
# (README.md, 01-*.md, 02-*.md) - keine _pruefung.py, keine Hilfsdateien, keine Original-PDFs.
#
#   tools/wissensbank-hochladen.sh [Optionen] SERVER_IP
#
# Optionen:
#   --dry-run            nur zeigen, was uebertragen wuerde (rsync -n, kein Eingriff auf dem Server)
#   --quelle ORDNER      Klon der Bibliothek (Standard ~/UniFlow/uniflow-wissensbibliothek)
#   --schluessel PFAD    SSH-Schluessel (Standard ~/.ssh/studinow_server)
#
# Ablauf: 1. rsync in einen Zwischenordner auf dem Server (/srv/uniflow/wissensbank-upload),
#         2. Kopie in das Daten-Volume als /data/wissensbank.neu, dann Tausch gegen /data/wissensbank (der Dienst liest
#            den neuen Stand beim naechsten Zugriff; katalog.json ist der Ausloeser),
#         3. Pruefung im Container: python -m app.wissensbank_pruefen --bibliothek.
# Eingeschaltet wird die Wissensbank getrennt davon mit LERNAPP_WISSENSBANK=1 in deploy/.env (Standard aus).
set -euo pipefail

QUELLE="${HOME}/UniFlow/uniflow-wissensbibliothek"
SSH_KEY="${HOME}/.ssh/studinow_server"
SSH_USER="root"
STAGE="/srv/uniflow/wissensbank-upload"
VOL_DATA="uniflow_uniflow-data"
DEPLOY_DIR="/srv/uniflow/app/deploy"
DRY=0
SERVER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quelle) QUELLE="$2"; shift ;;
    --schluessel) SSH_KEY="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    *) SERVER="$1" ;;
  esac
  shift
done

[ -n "$SERVER" ] || { echo "Aufruf: tools/wissensbank-hochladen.sh [--dry-run] SERVER_IP" >&2; exit 2; }
[ -f "$QUELLE/katalog.json" ] || { echo "katalog.json fehlt in $QUELLE" >&2; exit 1; }

STAND="$(python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); print(k.get("stand",""), sum(len(f.get("einheiten",[])) for f in k.get("faecher",[])))' "$QUELLE/katalog.json")"
echo "Bibliothek: $QUELLE (Stand und Einheiten: $STAND)"
if git -C "$QUELLE" rev-parse >/dev/null 2>&1 && [ -n "$(git -C "$QUELLE" status --porcelain)" ]; then
  echo "Hinweis: Der Klon hat nicht festgeschriebene Aenderungen (git status)." >&2
fi

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SERVER")
# nur katalog.json und die .md-Dateien der Einheiten; die README.md im Wurzelordner und alles mit _ am Anfang nicht
FILTER=(--prune-empty-dirs --include='/katalog.json' --exclude='/README.md' --include='*/' --exclude='_*'
        --include='README.md' --include='01-*.md' --include='02-*.md' --exclude='*')

if [ "$DRY" = 1 ]; then
  rsync -an --delete --itemize-changes "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/" | tail -20
  echo "(Probelauf: nichts uebertragen)"
  exit 0
fi

"${SSH[@]}" "mkdir -p '$STAGE' && chmod 700 '$STAGE'"
rsync -a --delete "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/"
"${SSH[@]}" "docker run --rm -v $VOL_DATA:/data -v '$STAGE':/neu:ro alpine sh -c '
  set -e
  rm -rf /data/wissensbank.neu /data/wissensbank.alt
  cp -r /neu /data/wissensbank.neu
  chmod -R a+rX,go-w /data/wissensbank.neu
  if [ -d /data/wissensbank ]; then mv /data/wissensbank /data/wissensbank.alt; fi
  mv /data/wissensbank.neu /data/wissensbank
  rm -rf /data/wissensbank.alt
  echo \"im Volume: \$(find /data/wissensbank -name \"*.md\" | wc -l) Dateien\"'"
"${SSH[@]}" "cd '$DEPLOY_DIR' && docker compose exec -T app python -m app.wissensbank_pruefen --bibliothek" || \
  echo "Pruefung im Container nicht moeglich (Dienst aus?). Daten liegen trotzdem in /data/wissensbank." >&2

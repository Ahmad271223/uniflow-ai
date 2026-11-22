#!/usr/bin/env bash
# Laedt die StudiNow-Erklaerungen (PDF je Kursdatei, app/erklaerung_shop.py) vom Mac des Inhabers in das Daten-Volume.
# Uebertragen werden NUR index.json und pdf/<sha[:2]>/<sha>.pdf aus dem Quellordner (Standard ~/Studora-Builds/erklaerungen-pdf,
# erzeugt mit eingang-arbeit/bibliothek_pdf.py). Kaeufe liegen in accounts.db und bleiben unberuehrt.
#
#   tools/erklaerungen-pdf-hochladen.sh [Optionen] SERVER_IP
#
# Optionen:
#   --dry-run            nur zeigen, was uebertragen wuerde (rsync -n, kein Eingriff auf dem Server)
#   --quelle ORDNER      Ordner mit index.json und pdf/ (Standard ~/Studora-Builds/erklaerungen-pdf)
#   --schluessel PFAD    SSH-Schluessel (Standard ~/.ssh/studinow_server)
#
# Ablauf wie tools/wissensbank-hochladen.sh: rsync in einen Zwischenordner (/srv/uniflow/erklaerungen-upload), dann Kopie
# als /data/erklaerungen-pdf.neu und Tausch gegen /data/erklaerungen-pdf (der Dienst liest index.json beim naechsten Zugriff
# neu). Eingeschaltet wird das Angebot getrennt davon mit LERNAPP_ERKLAERUNGEN=1 in deploy/.env (Standard aus).
set -euo pipefail

QUELLE="${HOME}/Studora-Builds/erklaerungen-pdf"
SSH_KEY="${HOME}/.ssh/studinow_server"
SSH_USER="root"
STAGE="/srv/uniflow/erklaerungen-upload"
VOL_DATA="uniflow_uniflow-data"
DRY=0
SERVER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --quelle) QUELLE="$2"; shift ;;
    --schluessel) SSH_KEY="$2"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    *) SERVER="$1" ;;
  esac
  shift
done

[ -n "$SERVER" ] || { echo "Aufruf: tools/erklaerungen-pdf-hochladen.sh [--dry-run] SERVER_IP" >&2; exit 2; }
[ -f "$QUELLE/index.json" ] || { echo "index.json fehlt in $QUELLE" >&2; exit 1; }
python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("Erklaerungen:", len(i), "PDFs,", sum(int(v.get("pdf_seiten") or 0) for v in i.values()), "Seiten")' "$QUELLE/index.json"

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SERVER")
FILTER=(--prune-empty-dirs --include='/index.json' --include='/pdf/' --include='/pdf/*/' --include='/pdf/*/*.pdf' --exclude='*')

if [ "$DRY" = 1 ]; then
  rsync -an --delete --itemize-changes "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/" | tail -20
  echo "(Probelauf: nichts uebertragen)"
  exit 0
fi

"${SSH[@]}" "mkdir -p '$STAGE' && chmod 700 '$STAGE'"
rsync -a --delete "${FILTER[@]}" -e "ssh -i $SSH_KEY -o BatchMode=yes" "$QUELLE/" "$SSH_USER@$SERVER:$STAGE/"
"${SSH[@]}" "docker run --rm -v $VOL_DATA:/data -v '$STAGE':/neu:ro alpine sh -c '
  set -e
  rm -rf /data/erklaerungen-pdf.neu /data/erklaerungen-pdf.alt
  cp -r /neu /data/erklaerungen-pdf.neu
  chmod -R a+rX,go-w /data/erklaerungen-pdf.neu
  if [ -d /data/erklaerungen-pdf ]; then mv /data/erklaerungen-pdf /data/erklaerungen-pdf.alt; fi
  mv /data/erklaerungen-pdf.neu /data/erklaerungen-pdf
  rm -rf /data/erklaerungen-pdf.alt
  echo \"im Volume: \$(find /data/erklaerungen-pdf -name \"*.pdf\" | wc -l) PDFs\"'"

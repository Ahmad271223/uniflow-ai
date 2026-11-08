#!/usr/bin/env bash
# Taegliches Backup des UniFlow-Dienstes (auf dem Server, ausserhalb des Containers):
#   /srv/uniflow/app/deploy/backup.sh            -> /srv/uniflow/backups/uniflow-YYYY-MM-DD_HHMM.tar.gz
# Zeitplan: deploy/uniflow-backup.timer (systemd) oder Cron:  30 3 * * * /srv/uniflow/app/deploy/backup.sh
# Die Datenbanken werden im Container mit der SQLite-Backup-API kopiert (deploy/backup_snapshot.py), der Dienst
# laeuft dabei weiter. Aufbewahrung: BACKUP_KEEP_DAYS (Standard 14). Wiederherstellung: docs/release/BETRIEB.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/srv/uniflow/backups}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
COMPOSE="${COMPOSE:-docker compose -f "$HERE/docker-compose.yml"}"
STAMP="$(date +%Y-%m-%d_%H%M)"
OUT="$BACKUP_DIR/uniflow-$STAMP.tar.gz"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# -T: kein Terminal, damit stdout das reine tar.gz ist. Das Python-Skript kommt ueber stdin in den Container.
$COMPOSE exec -T app python - < "$HERE/backup_snapshot.py" > "$OUT.part"
mv "$OUT.part" "$OUT"
chmod 600 "$OUT"

# Pruefen, dass das Archiv lesbar ist und die Kontodatenbank enthaelt. Erst die ganze Liste lesen, dann suchen:
# `tar | grep -q` bricht mit pipefail scheinbar zufaellig ab (grep schliesst die Pipe nach dem ersten Treffer, tar
# bekommt SIGPIPE) und meldete ein vollstaendiges Archiv als unvollstaendig.
LIST="$(tar -tzf "$OUT")"
grep -q 'uniflow-data/accounts.db$' <<<"$LIST" || { echo "Backup unvollstaendig: accounts.db fehlt in $OUT" >&2; exit 1; }

# Aufbewahrung: Archive aelter als KEEP_DAYS*24 h loeschen. Minuten statt `-mtime +N`: das zaehlt ganze Tage abgerundet
# und behielt jedes Archiv einen Tag laenger, als die Datenschutzerklaerung sagt (Audit 08.11.2026, P57-06)
find "$BACKUP_DIR" -maxdepth 1 -name 'uniflow-*.tar.gz' -type f -mmin "+$((KEEP_DAYS * 1440 - 30))" -delete

echo "Backup geschrieben: $OUT ($(du -h "$OUT" | cut -f1)); behalten: $(ls -1 "$BACKUP_DIR"/uniflow-*.tar.gz | wc -l) Archive"

# Kopie ausser Haus (ein Server allein ist kein Backup): deploy/backup-ausser-haus.sh verschluesselt die Archive mit age
# und laedt sie auf die Hetzner Storage Box. Es laeuft als ExecStartPost in uniflow-backup.service, also nur nach einem
# gelungenen Lauf dieses Skripts; mit Cron:  backup.sh && backup-ausser-haus.sh. Einrichtung: BETRIEB.md Abschnitt 9.

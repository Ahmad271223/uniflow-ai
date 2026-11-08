#!/usr/bin/env bash
# Sicherung ausser Haus: verschluesselte Kopie der taeglichen Backup-Archive auf einer Hetzner Storage Box (Deutschland).
# Laeuft AUF DEM SERVER als root, direkt nach deploy/backup.sh (uniflow-backup.service, ExecStartPost: nur wenn das
# lokale Backup gelungen ist). Einrichtung vom Mac: tools/sicherung-ausser-haus-einrichten.sh; Doku: docs/release/BETRIEB.md
# Abschnitt 9 "Sicherung ausser Haus".
#
#   /srv/uniflow/app/deploy/backup-ausser-haus.sh [--help]
#
# Ablauf:
#   1. Konfiguration aus der Umgebung oder deploy/.env (nur die OFFSITE_*-Zeilen werden gelesen, nie andere Werte gezeigt).
#      Fehlen OFFSITE_HOST, OFFSITE_USER und OFFSITE_RECIPIENT alle: Meldung "nicht eingerichtet", Exit 0.
#   2. Jedes lokale Archiv BACKUP_DIR/uniflow-*.tar.gz, das auf der Box noch fehlt, wird mit age fuer OFFSITE_RECIPIENT
#      (oeffentlicher Schluessel age1..., der private liegt nur beim Inhaber) verschluesselt. Hochgeladen wird nur der
#      Arbeitsordner mit den .age-Dateien, jede mit gepruefter age-Kopfzeile - nie ein Klartext-Archiv.
#   3. rsync ueber SSH (Port 23, eigener Schluessel OFFSITE_SSH_KEY nur fuer diesen Zweck) nach OFFSITE_DIR/ auf der Box,
#      danach Abgleich der Groessen auf der Box.
#   4. Auf der Box: Kopien, deren Datum im Namen aelter als OFFSITE_KEEP_DAYS (30) Tage ist, loeschen (rsync --delete mit
#      genau diesen Namen; die Box braucht dafuer nur rsync, keine Shell-Befehle).
#   5. Erfolg: OFFSITE_STATE_DIR/letzte-kopie neu schreiben (deploy/dienst-check.sh meldet "ausser_haus", wenn sie
#      aelter als 30 h ist).
#
# Umgebung / deploy/.env:
#   OFFSITE_HOST       PFLICHT  uNNNNNN.your-storagebox.de
#   OFFSITE_USER       PFLICHT  uNNNNNN (oder Unterkonto uNNNNNN-subN)
#   OFFSITE_RECIPIENT  PFLICHT  age1... (oeffentlicher Schluessel; mehrere durch Leerzeichen oder Komma getrennt)
#   OFFSITE_PORT (23) OFFSITE_DIR (studinow) OFFSITE_KEEP_DAYS (30) OFFSITE_SSH_KEY (/root/.ssh/storagebox)
#   OFFSITE_KNOWN_HOSTS (/root/.ssh/storagebox_known_hosts) OFFSITE_STATE_DIR (/srv/uniflow/ausser-haus)
#   BACKUP_DIR (/srv/uniflow/backups) ENV_FILE (deploy/.env)
# Exit: 0 = Kopie aktuell oder nicht eingerichtet, 1 = Fehler beim Verschluesseln/Hochladen/Aufraeumen,
#       2 = Konfiguration unvollstaendig oder falsch. Test ohne Server: tests/test_backup_ausser_haus.py.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
BACKUP_DIR="${BACKUP_DIR:-/srv/uniflow/backups}"
AGE_KOPF="age-encryption.org/v1"
NAME_RE='^uniflow-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.tar\.gz$'

case "${1:-}" in
	--help|-h) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
	"") ;;
	*) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 2 ;;
esac

meldung() { echo "ausser-haus: $*"; }
fehler() { echo "ausser-haus: FEHLER: $*" >&2; exit "${2:-1}"; }

# Wert aus der Umgebung, sonst die letzte Zeile NAME=... aus deploy/.env (ohne Anfuehrungszeichen, CR, Leerzeichen)
wert() {
	local v="${!1:-}"
	if [ -z "$v" ] && [ -r "$ENV_FILE" ]; then
		v="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '"'"'"'\r' || true)"
		v="$(echo "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	fi
	printf '%s' "${v:-${2:-}}"
}

HOST="$(wert OFFSITE_HOST)"
BENUTZER="$(wert OFFSITE_USER)"
EMPFAENGER="$(wert OFFSITE_RECIPIENT)"
PORT="$(wert OFFSITE_PORT 23)"
ZIEL="$(wert OFFSITE_DIR studinow)"
KEEP_DAYS="$(wert OFFSITE_KEEP_DAYS 30)"
SSH_KEY="$(wert OFFSITE_SSH_KEY /root/.ssh/storagebox)"
KNOWN_HOSTS="$(wert OFFSITE_KNOWN_HOSTS /root/.ssh/storagebox_known_hosts)"
STATE_DIR="$(wert OFFSITE_STATE_DIR /srv/uniflow/ausser-haus)"

if [ -z "$HOST$BENUTZER$EMPFAENGER" ]; then
	meldung "nicht eingerichtet (OFFSITE_HOST, OFFSITE_USER, OFFSITE_RECIPIENT in $ENV_FILE leer) - nichts zu tun." \
		"Einrichtung: tools/sicherung-ausser-haus-einrichten.sh, docs/release/BETRIEB.md Abschnitt 9."
	exit 0
fi

# ---------------------------------------------------------------- Konfiguration pruefen (Exit 2)

fehlt=()
[ -n "$HOST" ] || fehlt+=(OFFSITE_HOST)
[ -n "$BENUTZER" ] || fehlt+=(OFFSITE_USER)
[ -n "$EMPFAENGER" ] || fehlt+=(OFFSITE_RECIPIENT)
[ ${#fehlt[@]} -eq 0 ] || fehler "unvollstaendig eingerichtet, es fehlt: ${fehlt[*]} (in $ENV_FILE)" 2

case "$EMPFAENGER" in
	*AGE-SECRET-KEY*) fehler "OFFSITE_RECIPIENT enthaelt einen PRIVATEN age-Schluessel. Der gehoert nicht auf den Server:
  Zeile sofort aus $ENV_FILE entfernen, neues Schluesselpaar auf dem Mac erzeugen (tools/sicherung-ausser-haus-einrichten.sh)
  und nur den oeffentlichen Teil (age1...) eintragen." 2 ;;
esac
EMPF_ARGS=()
for r in ${EMPFAENGER//,/ }; do
	[[ "$r" =~ ^age1[02-9ac-hj-np-z]{20,}$ ]] || fehler "OFFSITE_RECIPIENT ist kein oeffentlicher age-Schluessel (age1...): '${r:0:12}...'" 2
	EMPF_ARGS+=(-r "$r")
done
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fehler "OFFSITE_HOST ungueltig: $HOST (erwartet uNNNNNN.your-storagebox.de)" 2
[[ "$BENUTZER" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fehler "OFFSITE_USER ungueltig: $BENUTZER (erwartet uNNNNNN)" 2
[[ "$PORT" =~ ^[0-9]+$ ]] || fehler "OFFSITE_PORT ungueltig: $PORT" 2
[[ "$ZIEL" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$ZIEL" != "." ] && [ "$ZIEL" != ".." ] || fehler "OFFSITE_DIR ungueltig: $ZIEL (ein Ordnername ohne /)" 2
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] && [ "$KEEP_DAYS" -ge 1 ] || fehler "OFFSITE_KEEP_DAYS ungueltig: $KEEP_DAYS" 2

command -v age >/dev/null 2>&1 || fehler "age fehlt auf dem Server: apt-get install -y age"
command -v rsync >/dev/null 2>&1 || fehler "rsync fehlt auf dem Server: apt-get install -y rsync"
[ -r "$SSH_KEY" ] || fehler "SSH-Schluessel fuer die Storage Box fehlt: $SSH_KEY (ssh-keygen -t ed25519 -N '' -f $SSH_KEY; oeffentlichen Teil in der Box hinterlegen, BETRIEB.md Abschnitt 9)"
[ -d "$BACKUP_DIR" ] || fehler "Backup-Ordner fehlt: $BACKUP_DIR (deploy/backup.sh gelaufen?)"
lokal_anzahl="$(find "$BACKUP_DIR" -maxdepth 1 -name 'uniflow-*.tar.gz' -type f | wc -l | tr -d ' ')"
[ "$lokal_anzahl" -gt 0 ] || fehler "kein lokales Archiv in $BACKUP_DIR (deploy/backup.sh pruefen)"

# ---------------------------------------------------------------- Vorbereitung

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
if command -v flock >/dev/null 2>&1; then
	exec 9>"$STATE_DIR/lauf.lock"
	flock -n 9 || fehler "laeuft bereits (Sperre $STATE_DIR/lauf.lock)"
fi

ARBEIT="$(mktemp -d "$STATE_DIR/arbeit.XXXXXX")"
LEER="$ARBEIT/leer"
RAUS="$ARBEIT/raus"
mkdir -p "$LEER" "$RAUS"
chmod 700 "$ARBEIT"
trap 'rm -rf "$ARBEIT"' EXIT

SSH_CMD="ssh -p $PORT -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30"
SSH_CMD+=" -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=accept-new"
FERN="$BENUTZER@$HOST:$ZIEL/"
RSYNC=(rsync --timeout=600 -e "$SSH_CMD")

# Liste der Dateien auf der Box: "name groesse" je Zeile (aus rsync --list-only; Groesse ohne Tausendertrenner)
fern_liste() {
	local out
	out="$(LC_ALL=C "${RSYNC[@]}" --list-only "$FERN" 2>&1)" || { echo "$out" | tail -n 3 >&2; return 1; }
	echo "$out" | awk '/^-/ { g = $2; gsub(/[,.]/, "", g); print $5, g }'
}

# lokale Zeit "YYYY-MM-DD_HHMM" einer Epoche (GNU date auf dem Server, BSD date fuer Tests am Mac)
stempel() { date -d "@$1" +%Y-%m-%d_%H%M 2>/dev/null || date -r "$1" +%Y-%m-%d_%H%M; }

# ---------------------------------------------------------------- 1. Zielordner anlegen (idempotent) und Bestand lesen

"${RSYNC[@]}" -d "$LEER/" "$FERN" >/dev/null 2>"$ARBEIT/fehler.txt" \
	|| fehler "Storage Box nicht erreichbar ($BENUTZER@$HOST Port $PORT): $(tail -n 2 "$ARBEIT/fehler.txt" | tr '\n' ' ')"
BESTAND="$(fern_liste)" || fehler "Bestand auf der Box nicht lesbar ($FERN)"

# ---------------------------------------------------------------- 2. Fehlende Archive verschluesseln

neu=()
while IFS= read -r archiv; do
	name="$(basename "$archiv")"
	[[ "$name" =~ $NAME_RE ]] || continue
	if grep -qF "$name.age " <<<"$BESTAND"; then continue; fi
	ziel="$RAUS/$name.age"
	age "${EMPF_ARGS[@]}" -o "$ziel.part" "$archiv" || fehler "age konnte $name nicht verschluesseln"
	# Kopfzeile pruefen: hochgeladen wird nur, was nachweislich age-verschluesselt ist
	[ "$(head -c ${#AGE_KOPF} "$ziel.part" 2>/dev/null || true)" = "$AGE_KOPF" ] \
		|| fehler "$name.age hat keine age-Kopfzeile - nichts hochgeladen (Klartext darf die Maschine nicht verlassen)"
	touch -r "$archiv" "$ziel.part"
	chmod 600 "$ziel.part"
	mv "$ziel.part" "$ziel"
	neu+=("$name.age")
done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'uniflow-*.tar.gz' -type f | sort)

# ---------------------------------------------------------------- 3. Hochladen (nur der Ordner mit .age-Dateien) und pruefen

if [ ${#neu[@]} -gt 0 ]; then
	for f in "$RAUS"/*; do
		case "$f" in *.tar.gz.age) ;; *) fehler "unerwartete Datei im Arbeitsordner: $f - abgebrochen" ;; esac
	done
	# -r: Inhalt des Ordners (ohne -r/-d ueberspringt rsync ihn), -p: Rechte 0600 mitnehmen, --ignore-existing: nie ersetzen
	"${RSYNC[@]}" -r -t -p --ignore-existing "$RAUS/" "$FERN" 2>"$ARBEIT/fehler.txt" \
		|| fehler "Hochladen fehlgeschlagen: $(tail -n 2 "$ARBEIT/fehler.txt" | tr '\n' ' ')"
	BESTAND="$(fern_liste)" || fehler "Bestand nach dem Hochladen nicht lesbar"
	for n in "${neu[@]}"; do
		groesse="$(wc -c <"$RAUS/$n" | tr -d ' ')"
		grep -qx "$n $groesse" <<<"$BESTAND" || fehler "$n fehlt nach dem Hochladen auf der Box oder hat eine andere Groesse"
	done
fi
rm -rf "$RAUS"

# ---------------------------------------------------------------- 4. Auf der Box aufraeumen: aelter als KEEP_DAYS

grenze="$(stempel $(($(date +%s) - KEEP_DAYS * 86400)))"
alt=()
while read -r n _; do
	[ -n "$n" ] || continue
	[[ "$n" =~ ^uniflow-([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4})\.tar\.gz\.age$ ]] || continue
	if [[ "${BASH_REMATCH[1]}" < "$grenze" ]]; then alt+=("$n"); fi
done <<<"$BESTAND"

if [ ${#alt[@]} -gt 0 ]; then
	filter=()
	for n in "${alt[@]}"; do filter+=("--include=/$n"); done
	# leerer Quellordner + genau diese Namen + alles andere ausgeschlossen: rsync loescht nur die genannten Dateien
	"${RSYNC[@]}" -r --delete "${filter[@]}" "--exclude=*" "$LEER/" "$FERN" 2>"$ARBEIT/fehler.txt" \
		|| fehler "Aufraeumen auf der Box fehlgeschlagen: $(tail -n 2 "$ARBEIT/fehler.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 5. Erfolg festhalten

auf_box=$(( $(grep -c '\.tar\.gz\.age ' <<<"$BESTAND" || true) - ${#alt[@]} ))
printf 'zeit=%s\nhochgeladen=%s\ngeloescht=%s\nauf_box=%s\nziel=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#neu[@]}" "${#alt[@]}" \
	"$auf_box" "$BENUTZER@$HOST:$ZIEL" >"$STATE_DIR/letzte-kopie.part"
mv "$STATE_DIR/letzte-kopie.part" "$STATE_DIR/letzte-kopie"
meldung "Kopie ausser Haus aktuell: ${#neu[@]} hochgeladen, ${#alt[@]} aelter als $KEEP_DAYS Tage geloescht, $auf_box Archive auf $BENUTZER@$HOST:$ZIEL/"

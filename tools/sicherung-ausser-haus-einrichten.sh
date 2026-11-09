#!/usr/bin/env bash
# Sicherung ausser Haus einrichten – laeuft auf dem Mac des Inhabers, NACHDEM die Storage Box bestellt ist
# (docs/release/BETRIEB.md Abschnitt 9 "Sicherung ausser Haus").
#
#   tools/sicherung-ausser-haus-einrichten.sh [--benutzer uNNNNNN] [--server IP] [--schluessel PFAD]
#                                             [--age-schluessel PFAD] [--nur-anzeigen]
#   tools/sicherung-ausser-haus-einrichten.sh --pruefen DATEI.tar.gz.age [--age-schluessel PFAD]
#
# Einrichten: fragt den Storage-Box-Benutzer ab, erzeugt (einmalig) das age-Schluesselpaar fuer die Verschluesselung
# HIER auf dem Mac (privater Teil: ~/Studora-Builds/private_keys/studinow-sicherung-age.txt, 0600 - zusaetzlich in den
# Passwort-Manager; ohne ihn sind die Kopien unlesbar) und zeigt die sechs Befehle fuer den Server, jeweils als
#   ssh -i ~/.ssh/studinow_server root@46.225.32.3 '...'
# Jeder Schritt laeuft nur nach Rueckfrage (j/N); ohne Terminal oder mit --nur-anzeigen werden sie nur gezeigt.
#   1 Server: age und rsync installieren, SSH-Schluessel /root/.ssh/storagebox nur fuer die Box erzeugen
#   2 oeffentlichen Teil in der Storage Box hinterlegen (install-ssh-key, fragt EINMAL nach dem Storage-Box-Passwort)
#   3 OFFSITE_HOST, OFFSITE_USER, OFFSITE_RECIPIENT (nur der oeffentliche age-Schluessel) in deploy/.env setzen
#   4 uniflow-backup.service mit ExecStartPost einspielen (systemctl daemon-reload)
#   5 Probe-Lauf deploy/backup-ausser-haus.sh und dienst-check (Kennung ausser_haus)
#   6 Probe-Wiederherstellung: neueste Kopie ueber den Server auf den Mac holen (bleibt verschluesselt) und --pruefen
# Pruefen (--pruefen): entschluesselt eine Kopie in einen Ordner, der danach geloescht wird, und prueft das Format von
# deploy/backup_snapshot.py (uniflow-data/BACKUP-INFO.txt, uniflow-data/accounts.db mit PRAGMA integrity_check).
# Der private Schluessel verlaesst den Mac nie; dieses Skript zeigt ihn nie an. Test: tests/test_backup_ausser_haus.py.
set -euo pipefail

SERVER="46.225.32.3"
SSH_KEY="${HOME}/.ssh/studinow_server"
AGE_KEY="${HOME}/Studora-Builds/private_keys/studinow-sicherung-age.txt"
BENUTZER=""
NUR_ANZEIGEN=0
PRUEFEN=""
DEPLOY="/srv/uniflow/app/deploy"
BOX_SSH="ssh -p 23 -i /root/.ssh/storagebox -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/storagebox_known_hosts"

hilfe() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
fehler() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--benutzer) shift; BENUTZER="${1:-}" ;;
		--server) shift; SERVER="${1:-}" ;;
		--schluessel) shift; SSH_KEY="${1:-}" ;;
		--age-schluessel) shift; AGE_KEY="${1:-}" ;;
		--nur-anzeigen) NUR_ANZEIGEN=1 ;;
		--pruefen) shift; PRUEFEN="${1:-}"; [ -n "$PRUEFEN" ] || fehler "--pruefen braucht eine Datei" ;;
		-h|--help|--hilfe) hilfe; exit 0 ;;
		*) fehler "Unbekannte Option: $1 (siehe --help)" ;;
	esac
	shift
done

# ---------------------------------------------------------------- Probe-Wiederherstellung (nur lokal, kein SSH)

pruefe_kopie() {
	local datei="$1" t liste n_db info ok=0 integ konten
	[ -f "$datei" ] || fehler "Datei fehlt: $datei"
	[ -r "$AGE_KEY" ] || fehler "privater age-Schluessel fehlt: $AGE_KEY (aus dem Passwort-Manager zurueckholen)"
	command -v age >/dev/null 2>&1 || fehler "age fehlt: brew install age"
	PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/studinow-probe.XXXXXX")"
	t="$PROBE_TMP"
	chmod 700 "$t"
	# Klartext liegt nur in diesem Ordner und wird in jedem Fall geloescht (globale Variable: die Falle laeuft beim
	# Skriptende, wenn die lokale schon weg ist)
	trap 'rm -rf "${PROBE_TMP:-}"' EXIT
	age -d -i "$AGE_KEY" -o "$t/archiv.tar.gz" "$datei" || fehler "Entschluesseln fehlgeschlagen (falscher Schluessel oder beschaedigte Datei)"
	liste="$(tar -tzf "$t/archiv.tar.gz")" || fehler "kein lesbares tar.gz nach dem Entschluesseln"
	printf 'Entschluesselt: %s (%s Eintraege)\n' "$(basename "$datei")" "$(printf '%s\n' "$liste" | wc -l | tr -d ' ')"
	grep -qx 'uniflow-data/accounts.db' <<<"$liste" || { printf 'PROBLEM: uniflow-data/accounts.db fehlt\n'; ok=1; }
	grep -qx 'uniflow-data/BACKUP-INFO.txt' <<<"$liste" || { printf 'PROBLEM: uniflow-data/BACKUP-INFO.txt fehlt\n'; ok=1; }
	n_db="$(grep -cE '^uniflow-data/users(-deleted)?/[^/]+/lernapp\.db$' <<<"$liste" || true)"
	printf 'Kontodatenbanken (users/*/lernapp.db): %s\n' "$n_db"
	if grep -qE '(^|/)secret\.key$|\.db-(wal|shm)$|/browser-profile' <<<"$liste"; then
		printf 'PROBLEM: Archiv enthaelt secret.key, WAL/SHM oder Browser-Profile (passt nicht zu backup_snapshot.py)\n'; ok=1
	fi
	if [ "$ok" = 0 ]; then
		tar -xzf "$t/archiv.tar.gz" -C "$t" uniflow-data/accounts.db uniflow-data/BACKUP-INFO.txt
		info="$(cat "$t/uniflow-data/BACKUP-INFO.txt")"
		printf 'BACKUP-INFO.txt:\n%s\n' "$(printf '%s\n' "$info" | sed 's/^/   /')"
		grep -q '^created=' <<<"$info" || { printf 'PROBLEM: BACKUP-INFO.txt ohne created=\n'; ok=1; }
		if command -v sqlite3 >/dev/null 2>&1; then
			# Wegwerf-Kopie: normal oeffnen. Mit -readonly scheitert eine Datenbank im WAL-Modus ohne -shm-Datei mit
			# SQLITE_CANTOPEN (14), und set -o pipefail beendete das Skript dann stumm (gefunden 09.11.2026, erster echter Lauf)
			integ="$(sqlite3 "$t/uniflow-data/accounts.db" 'PRAGMA integrity_check;' 2>&1 | head -n1 || true)"
			konten="$(sqlite3 "$t/uniflow-data/accounts.db" 'SELECT count(*) FROM users;' 2>&1 | head -n1 || true)"
			printf 'accounts.db: integrity_check=%s, Konten=%s\n' "$integ" "$konten"
			[ "$integ" = "ok" ] || { printf 'PROBLEM: accounts.db nicht in Ordnung\n'; ok=1; }
		else
			printf 'Hinweis: sqlite3 fehlt, accounts.db nicht geprueft\n'
		fi
	fi
	if [ "$ok" = 0 ]; then
		printf 'ERGEBNIS: Kopie lesbar und vollstaendig. Klartext wieder geloescht.\n'
	else
		printf 'ERGEBNIS: Kopie NICHT in Ordnung (siehe PROBLEM). Klartext wieder geloescht.\n'
	fi
	return "$ok"
}

if [ -n "$PRUEFEN" ]; then
	pruefe_kopie "$PRUEFEN"
	exit $?
fi

# ---------------------------------------------------------------- 0. Werkzeuge, Benutzer, Schluessel

command -v age-keygen >/dev/null 2>&1 || fehler "age fehlt auf dem Mac: brew install age (danach dieses Skript erneut starten)"
[[ "$SERVER" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fehler "--server muss eine IPv4-Adresse sein: $SERVER"

if [ -z "$BENUTZER" ]; then
	[ -t 0 ] || fehler "kein Terminal: --benutzer uNNNNNN angeben"
	printf 'Storage-Box-Benutzer (Hetzner-Konsole -> Storage Box -> Uebersicht, z. B. u123456): '
	read -r BENUTZER
fi
BENUTZER="$(printf '%s' "$BENUTZER" | tr -d ' \t\r')"
[[ "$BENUTZER" =~ ^u[0-9]+(-sub[0-9]+)?$ ]] || fehler "Benutzer muss wie u123456 (oder u123456-sub1) aussehen: '$BENUTZER'"
HOST="${BENUTZER%%-sub*}.your-storagebox.de"

if [ -f "$AGE_KEY" ]; then
	printf 'age-Schluessel vorhanden, wird weiterverwendet: %s\n' "$AGE_KEY"
else
	mkdir -p "$(dirname "$AGE_KEY")"
	chmod 700 "$(dirname "$AGE_KEY")"
	( umask 077; age-keygen -o "$AGE_KEY" 2>/dev/null )
	printf 'age-Schluesselpaar erzeugt: %s\n' "$AGE_KEY"
fi
chmod 600 "$AGE_KEY"
OEFFENTLICH="$(age-keygen -y "$AGE_KEY")"
[[ "$OEFFENTLICH" =~ ^age1[02-9ac-hj-np-z]{20,}$ ]] || fehler "oeffentlicher Schluessel nicht lesbar aus $AGE_KEY"

cat <<EOF

Storage Box:      $BENUTZER@$HOST (Port 23, Ordner studinow/)
Server:           root@$SERVER (Schluessel $SSH_KEY)
Oeffentlicher age-Schluessel (kommt auf den Server): $OEFFENTLICH
Privater age-Schluessel (bleibt auf dem Mac):        $AGE_KEY
  -> JETZT zusaetzlich in den Passwort-Manager legen (Datei-Anhang oder Inhalt). Ohne ihn ist keine Kopie lesbar;
     er darf nie auf den Server, in das Repository oder in eine Mail.
EOF

# ---------------------------------------------------------------- 1.-6. Befehle fuer den Server

SCHRITTE=(
	"Server vorbereiten: age und rsync installieren, SSH-Schluessel nur fuer die Storage Box erzeugen"
	"Oeffentlichen SSH-Schluessel in der Storage Box hinterlegen (fragt EINMAL nach dem Storage-Box-Passwort aus der Hetzner-Konsole)"
	"Werte in deploy/.env setzen (nur Host, Benutzer, oeffentlicher age-Schluessel)"
	"uniflow-backup.service mit dem zweiten Schritt (ExecStartPost) einspielen"
	"Probe-Lauf: Archive verschluesseln und hochladen, danach dienst-check (Kennung ausser_haus)"
	"Probe-Wiederherstellung: neueste Kopie verschluesselt auf den Mac holen und pruefen"
)
BEFEHLE=(
	"set -e; test -f $DEPLOY/backup-ausser-haus.sh || { echo \"$DEPLOY/backup-ausser-haus.sh fehlt: erst den aktuellen Stand einspielen (BETRIEB.md Abschnitt 8)\"; exit 1; }; apt-get install -y -qq age rsync; install -d -m 700 /root/.ssh; test -f /root/.ssh/storagebox || ssh-keygen -q -t ed25519 -N \"\" -C studinow-sicherung -f /root/.ssh/storagebox; cat /root/.ssh/storagebox.pub"
	"cat /root/.ssh/storagebox.pub | ssh -p 23 -o UserKnownHostsFile=/root/.ssh/storagebox_known_hosts -o StrictHostKeyChecking=accept-new $BENUTZER@$HOST install-ssh-key"
	"set -e; cd $DEPLOY; test -f .env; sed -i -E \"/^OFFSITE_(HOST|USER|RECIPIENT)=/d\" .env; printf \"%s\\n\" OFFSITE_HOST=$HOST OFFSITE_USER=$BENUTZER OFFSITE_RECIPIENT=$OEFFENTLICH >> .env; chmod 600 .env; grep -E \"^OFFSITE_(HOST|USER|RECIPIENT)=\" .env"
	"set -e; cp $DEPLOY/uniflow-backup.service /etc/systemd/system/; systemctl daemon-reload; systemctl cat uniflow-backup.service | grep ExecStartPost"
	"set -e; BACKUP_DIR=/srv/uniflow/backups bash $DEPLOY/backup-ausser-haus.sh; cat /srv/uniflow/ausser-haus/letzte-kopie; bash $DEPLOY/dienst-check.sh --dry-run --verbose | grep ausser_haus"
	"set -e; export RSYNC_RSH=\"$BOX_SSH\"; n=\$(rsync --list-only $BENUTZER@$HOST:studinow/ | grep -o \"uniflow-[0-9_-]*[.]tar[.]gz[.]age\" | sort | tail -n1); test -n \"\$n\"; t=\$(mktemp -d); rsync -q $BENUTZER@$HOST:studinow/\$n \$t/; cat \$t/\$n; rm -rf \$t"
)
PROBE="${HOME}/Downloads/studinow-probe-$(date +%Y-%m-%d).tar.gz.age"

for b in "${BEFEHLE[@]}"; do
	case "$b" in *"'"*) fehler "interner Fehler: Befehl enthaelt ein einfaches Anfuehrungszeichen" ;; esac
done

zeige() {   # zeige NR
	local i=$(($1 - 1)) tty=""
	[ "$1" = 2 ] && tty="-t "
	printf '\n== Schritt %s: %s\n' "$1" "${SCHRITTE[$i]}"
	if [ "$1" = 6 ]; then
		printf "ssh -i %s root@%s '%s' > %s\n" "$SSH_KEY" "$SERVER" "${BEFEHLE[$i]}" "$PROBE"
		printf 'bash tools/sicherung-ausser-haus-einrichten.sh --pruefen %s\n' "$PROBE"
	else
		printf "ssh %s-i %s root@%s '%s'\n" "$tty" "$SSH_KEY" "$SERVER" "${BEFEHLE[$i]}"
	fi
}

fuehre_aus() {   # fuehre_aus NR -> Exit des Schritts
	local i=$(($1 - 1))
	case "$1" in
		2) ssh -t -i "$SSH_KEY" "root@$SERVER" "${BEFEHLE[$i]}" ;;
		6) ssh -i "$SSH_KEY" "root@$SERVER" "${BEFEHLE[$i]}" >"$PROBE" && pruefe_kopie "$PROBE" ;;
		*) ssh -i "$SSH_KEY" "root@$SERVER" "${BEFEHLE[$i]}" ;;
	esac
}

interaktiv=0
[ "$NUR_ANZEIGEN" = 0 ] && [ -t 0 ] && interaktiv=1

if [ "$interaktiv" = 0 ]; then
	printf '\nBefehle fuer den Server (nur angezeigt, nichts ausgefuehrt):\n'
	for n in 1 2 3 4 5 6; do zeige "$n"; done
	printf '\nDanach: docs/release/BETRIEB.md Abschnitt 9 (Probe-Wiederherstellung monatlich).\n'
	exit 0
fi

[ -r "$SSH_KEY" ] || fehler "SSH-Schluessel fuer den Server fehlt: $SSH_KEY (--schluessel PFAD)"
printf '\nJeder Schritt wird gezeigt und laeuft nur nach "j". Mit "n" geht es zum naechsten, mit "q" endet das Skript.\n'
for n in 1 2 3 4 5 6; do
	zeige "$n"
	printf 'Schritt %s jetzt ausfuehren? [j/N/q] ' "$n"
	read -r antwort || antwort=q
	case "$antwort" in
		j|J|ja|Ja) fuehre_aus "$n" || fehler "Schritt $n fehlgeschlagen (Ausgabe oben). Nach dem Beheben dieses Skript erneut starten; erledigte Schritte mit n ueberspringen." ;;
		q|Q) printf 'Beendet nach Schritt %s.\n' "$((n - 1))"; exit 0 ;;
		*) printf 'uebersprungen\n' ;;
	esac
done
printf '\nFertig. Ab jetzt laeuft die Kopie taeglich nach dem Backup (03:30); dienst-check meldet "ausser_haus", wenn sie\nlaenger als 30 h ausbleibt. Probe-Wiederherstellung einmal im Monat: Schritt 6 erneut (nur "j" bei 6).\n'

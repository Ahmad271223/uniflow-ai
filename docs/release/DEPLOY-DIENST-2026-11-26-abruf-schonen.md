# Dienst-Update 26.11.2026 – ausgerollt 22:23 (Weck-Signal an ein Gerät je Konto)

Freigabe des Inhabers im Chat: „Ja, deployen“ (Frage: Server-Teil von `app/abruf-schonen` auf app.studinow.app).

## Was

Nur `app/wake_push.py` aus `17c3da61` (Zweig `app/abruf-schonen`): `wake_devices` – der Dienst weckt je Konto nur das
zuletzt benutzte Gerät. Sonst nichts: Vorher geprüft, dass die Datei auf dem Server genau dem Ausgangsstand
`release/1.0.8-alles` @ 52ff61a3 entsprach und Quellordner und laufender Container gleich waren (169 Python-Dateien).
Kein `git archive` des ganzen Zweigs, damit kein anderer, noch nicht freigegebener Stand mitkommt.

## Ablauf

1. Backup: `/srv/uniflow/backups/uniflow-2026-11-26_2222.tar.gz` (451 MB, 46 Datenbanken).
2. Alte Datei gesichert: `/srv/uniflow/backups/wake_push.py.vor-abruf-schonen-2026-11-26`.
3. Neue Datei nach `/srv/uniflow/app/app/wake_push.py`, `docker compose up -d --build`.
4. Geprüft: `uniflow-app` und `uniflow-jobs` healthy, in beiden Containern die neue Datei (sha256 f5cc14da…),
   `wake_devices` vorhanden, `dienst-check.sh --no-mail --verbose`: alle Prüfungen bestanden.

## Wirkung jetzt

Keine sichtbare: Das Weck-Signal ist auf dem Server **ausgeschaltet** (`STUDINOW_WAKE_PUSH` nicht 1, „Gemeldete
Geräte: keine“, „Zuletzt gesendet: noch nie“). Die neue Regel gilt, sobald es eingeschaltet wird.

## Zurück

`cp /srv/uniflow/backups/wake_push.py.vor-abruf-schonen-2026-11-26 /srv/uniflow/app/app/wake_push.py` und
`cd /srv/uniflow/app/deploy && docker compose up -d --build`.

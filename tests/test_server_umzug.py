"""Umzugs-Skripte (tools/server-umzug.sh, tools/server-umzug-pruefen.sh) im Trockenlauf – ohne Server, ohne SSH.

- bash -n (Syntax) und Hilfe
- --dry-run gegen zwei Platzhalter-Adressen (RFC 5737, nicht routbar): Reihenfolge der sechs Schritte und der
  entscheidenden Befehle (stop vor Kopie vor Pruefung vor up -d vor DNS vor down); kein echter ssh/dig/curl-Aufruf
- Fehler bei falschen Argumenten; Volumes mit Compose-Praefix; Health-Route existiert in der App; Einrichtungs-Schritte
- Anleitung docs/SERVER-UMZUG-2026-11-08.md nennt Skript, Hetzner-Angaben, Rueckweg und die 7 Tage fuer den alten Server
"""
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
UMZUG = ROOT / "tools" / "server-umzug.sh"
PRUEFEN = ROOT / "tools" / "server-umzug-pruefen.sh"
DOKU = ROOT / "docs" / "SERVER-UMZUG-2026-11-08.md"
ALT, NEU = "192.0.2.10", "192.0.2.20"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash fehlt")


FALLEN = ("ssh", "scp", "dig", "curl", "git", "docker")
_FALLEN_DIR: Path | None = None


@pytest.fixture(autouse=True, scope="module")
def fallen(tmp_path_factory):
    """Attrappen fuer ssh/dig/curl/git/docker vorn im PATH: ein echter Aufruf im Trockenlauf faellt sofort auf."""
    global _FALLEN_DIR
    d = tmp_path_factory.mktemp("fallen")
    for name in FALLEN:
        f = d / name
        f.write_text(f"#!/usr/bin/env bash\necho 'ECHTER-AUFRUF {name}' \"$@\" >&2\nexit 99\n", encoding="utf-8")
        f.chmod(0o755)
    _FALLEN_DIR = d
    yield d


def lauf(skript: Path, *args: str, erwartet: int = 0) -> str:
    env = {"HOME": os.environ.get("HOME", "/tmp"), "LC_ALL": "C",
           "PATH": f"{_FALLEN_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"}
    # stderr in stdout einreihen, damit die Reihenfolge der Zeilen erhalten bleibt (ssh_wert zeigt im Trockenlauf auf stderr)
    p = subprocess.run(["bash", str(skript), *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                       encoding="utf-8", env=env, cwd=ROOT, timeout=60)
    text = p.stdout
    assert "ECHTER-AUFRUF" not in text, f"Trockenlauf hat ein echtes Werkzeug aufgerufen:\n{text}"
    assert p.returncode == erwartet, f"Exit {p.returncode}, erwartet {erwartet}\n{text}"
    return text


def reihenfolge(text: str, *stuecke: str) -> None:
    pos = -1
    for s in stuecke:
        i = text.find(s, pos + 1)
        assert i >= 0, f"fehlt oder kommt zu frueh: {s!r}"
        pos = i


def test_syntax_und_zeilenenden():
    for skript in (UMZUG, PRUEFEN):
        assert skript.is_file() and os.access(skript, os.X_OK), skript
        raw = skript.read_bytes()
        assert raw.startswith(b"#!/usr/bin/env bash") and b"\r\n" not in raw
        assert b"set -euo pipefail" in raw
        p = subprocess.run(["bash", "-n", str(skript)], capture_output=True, text=True)
        assert p.returncode == 0, p.stderr


def test_hilfe_und_fehlende_argumente():
    hilfe = lauf(UMZUG, "--help")
    assert "ALT_IP NEU_IP" in hilfe and "--dry-run" in hilfe and "--ref" in hilfe
    text = lauf(UMZUG, "--dry-run", ALT, erwartet=1)
    assert "ALT_IP und NEU_IP" in text
    text = lauf(UMZUG, "--dry-run", ALT, ALT, erwartet=1)
    assert "gleich" in text
    text = lauf(UMZUG, "--dry-run", "nicht-ip", NEU, erwartet=1)
    assert "IPv4" in text
    text = lauf(UMZUG, "--dry-run", "--ab-schritt", "9", ALT, NEU, erwartet=1)
    assert "1 bis 6" in text
    text = lauf(UMZUG, "--dry-run", "--env-setzen", "kein gleich", ALT, NEU, erwartet=1)
    assert "NAME=WERT" in text


def test_trockenlauf_reihenfolge_der_schritte():
    text = lauf(UMZUG, "--dry-run", ALT, NEU)
    assert "TROCKENLAUF" in text
    # alle sechs Schritte in Reihenfolge
    reihenfolge(text, "== Schritt 1:", "== Schritt 2:", "== Schritt 3:", "== Schritt 4:", "== Schritt 5:", "== Schritt 6:",
                "Ende: Schritte 1 bis 6")
    # entscheidende Befehle in der richtigen Reihenfolge (idempotent: Volumes vorher per up --no-start angelegt)
    reihenfolge(
        text,
        f"ssh root@{ALT}", "docker compose ps",                                    # 1 ALT erreichbar
        f"ssh root@{NEU} -- hostname", "/etc/os-release",                          # 1 NEU frisch
        "apt-get install", "unattended-upgrades", "get.docker.com", "ufw allow 80/tcp", "ufw allow 443/tcp",
        "ufw --force enable", "timedatectl set-timezone Europe/Berlin", "mkdir -p /srv/uniflow/backups",
        "git -C", "archive --format=tar", f"ssh root@{NEU} -- mkdir -p /srv/uniflow/app && tar -x -C /srv/uniflow/app",
        "VERSION-COMMIT",                                                          # 2 Code
        f"ssh root@{ALT} -- cd /srv/uniflow/app/deploy && tar -czf -", ".env docker-compose.override.yml apple-certs",
        f"| ssh root@{NEU} -- tar -xzf - -C /srv/uniflow/app/deploy", "chmod 600 /srv/uniflow/app/deploy/.env",
        "grep -cE '^(UNIFLOW_DOMAIN|UNIFLOW_ACME_EMAIL|LERNAPP_SECRET_KEY)=.+'",   # 2 Pflichtzeilen, ohne Werte
        f"ssh root@{NEU} -- cd /srv/uniflow/app/deploy && docker compose build",   # 3 Bauen
        "docker compose up --no-start",                                            # 3 Volumes anlegen
        f"ssh root@{ALT} -- /srv/uniflow/app/deploy/backup.sh",                    # 4 Sicherung vor der Pause
        f"ssh root@{ALT} -- cd /srv/uniflow/app/deploy && docker compose stop app jobs",
        f"ssh root@{ALT} -- docker run --rm -v uniflow_uniflow-data:/data:ro alpine tar -C /data -czf - . | "
        f"ssh root@{NEU} -- docker run --rm -i -v uniflow_uniflow-data:/data alpine",
        "tar -xzf - -C /data",
        "uniflow_uniflow-logs:/data:ro alpine tar", "uniflow_caddy-data:/data:ro alpine tar",
        "md5sum accounts.db",                                                      # 4 Pruefsumme
        f"ssh root@{NEU} -- cd /srv/uniflow/app/deploy && docker compose up -d",
        "{{.State.Health.Status}}", "http://127.0.0.1:8765/api/account/info", "select count(*) from users",
        "JETZT DNS UMSTELLEN", f"Wert: {NEU}", "TTL: 60",                            # 5 DNS-Hinweis
        "dig +short app.studinow.app A @1.1.1.1", "curl -fsS https://app.studinow.app/api/account/info", "ERFOLG",
        f"ssh root@{ALT} -- cd /srv/uniflow/app/deploy && docker compose down",     # 6 ALT nur stoppen
        "uniflow-backup.timer", "systemctl enable --now uniflow-backup.timer",
        f"ssh root@{ALT} -- tar -C /srv/uniflow/backups",                           # 6 alte Sicherungen
        "systemctl start uniflow-backup.service", "7 Tage",
    )
    # die Pause (stop) liegt NACH dem Bauen und VOR dem Start auf NEU; down auf ALT erst nach dem DNS-Erfolg
    assert text.index("docker compose build") < text.index("docker compose stop app jobs") < text.index("docker compose up -d")
    assert text.index("ERFOLG") < text.index("docker compose down")
    # nie loeschen: kein down -v, kein volume rm, kein rm -rf auf ALT
    assert "down -v" not in text and "volume rm" not in text and "rm -rf" not in text
    # nie Inhalte der .env zeigen
    assert "cat /srv/uniflow/app/deploy/.env" not in text and "cat .env" not in text
    # Trockenlauf: ausser den [trocken]-Zeilen kein echter Fernaufruf (Attrappen in PATH wuerden sonst anschlagen)
    assert text.count("[trocken] ssh ") >= 25


def test_trockenlauf_optionen():
    text = lauf(UMZUG, "--dry-run", "--ab-schritt", "4", "--bis-schritt", "5", ALT, NEU)
    assert "== Schritt 3:" not in text and "== Schritt 6:" not in text
    assert "== Schritt 4:" in text and "== Schritt 5:" in text and "Schritte 4 bis 5" in text
    text = lauf(UMZUG, "--dry-run", "--ohne-caddy-daten", "--bis-schritt", "4", ALT, NEU)
    assert "uniflow_caddy-data" not in text and "uniflow_uniflow-logs" in text
    text = lauf(UMZUG, "--dry-run", "--ref", "server/lastfest", "--bis-schritt", "2", ALT, NEU)
    assert "archive --format=tar 'server/lastfest'" in text and "Code-Stand fuer den neuen Server: server/lastfest" in text
    text = lauf(UMZUG, "--dry-run", "--env-setzen", "UVICORN_WORKERS=6", "--env-setzen", "API_MEMORY=2G", "--bis-schritt", "2",
                "--ab-schritt", "2", ALT, NEU)
    reihenfolge(text, "s|^UVICORN_WORKERS=.*|UVICORN_WORKERS=6|", "s|^API_MEMORY=.*|API_MEMORY=2G|", "Pflichtzeilen")
    text = lauf(UMZUG, "--dry-run", "--domain", "test.example.org", "--ab-schritt", "5", "--bis-schritt", "5", ALT, NEU)
    assert "dig +short test.example.org" in text


def test_volumes_und_health_passen_zum_hosting_paket():
    compose = (ROOT / "deploy" / "docker-compose.yml").read_text(encoding="utf-8")
    skript = UMZUG.read_text(encoding="utf-8")
    assert re.search(r"^name: uniflow$", compose, re.M)
    for vol in ("uniflow-data", "uniflow-logs", "caddy-data"):
        assert re.search(rf"^  {vol}:$", compose, re.M), vol
        assert f"uniflow_{vol}" in skript, f"Volume {vol} ohne Compose-Praefix im Skript"
    assert 'container_name: uniflow-app' in compose and "uniflow-app" in skript
    # oeffentliche Route ohne Anmeldung, die das Skript intern abfragt (eine /api/health gibt es nicht)
    api = (ROOT / "app" / "account_api.py").read_text(encoding="utf-8")
    assert '@router.get("/info")' in api and "/api/account/info" in skript
    from app import config
    assert f"APP_PORT={config.PORT}" in skript
    # Backup-Einheiten, die Schritt 6 kopiert, liegen im Repo
    assert (ROOT / "deploy" / "uniflow-backup.service").is_file() and (ROOT / "deploy" / "uniflow-backup.timer").is_file()


def test_pruefen_trockenlauf():
    text = lauf(PRUEFEN, "--dry-run", NEU, ALT)
    reihenfolge(text, "NEU: Container", "{{.State.Health.Status}}' uniflow-app", "uniflow-jobs",
                "http://127.0.0.1:8765/api/account/info", "select count(*) from users", "NEU: Daten-Volume",
                f"ssh root@{NEU} -- docker run --rm -v uniflow_uniflow-data:/data:ro alpine", "nutzerordner=",
                "VERSION-COMMIT", "ALT: Daten-Volume", f"ssh root@{ALT} -- docker run --rm -v uniflow_uniflow-data:/data:ro alpine",
                "ALT: Container", "dig +short app.studinow.app", "curl -fsS https://app.studinow.app/api/account/info",
                "uniflow-backup.timer", "ERGEBNIS: keine Probleme")
    nur_neu = lauf(PRUEFEN, "--dry-run", NEU)
    assert "ALT:" not in nur_neu and f"ssh root@{ALT}" not in nur_neu
    lauf(PRUEFEN, "--dry-run", erwartet=1)


def test_anleitung_fuer_den_inhaber():
    text = DOKU.read_text(encoding="utf-8")
    for s in ("tools/server-umzug.sh", "tools/server-umzug-pruefen.sh", "Ubuntu 24.04", "CX43", "CX33", "Nürnberg", "Falkenstein",
              "studinow_server", "studinow-nbg", "Ausfallzeit", "Rückweg", "7 Tage", "TTL", "app.studinow.app", "docker compose up -d",
              "--dry-run", "--ref", "server/lastfest"):
        assert s in text, s
    assert "\r\n" not in text

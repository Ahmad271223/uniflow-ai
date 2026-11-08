"""Dienstpruefung deploy/dienst-check.sh im Trockenlauf – ohne Server, ohne Docker (wie tests/test_server_umzug.py).

- bash -n (Syntax), Hilfe, LF-Zeilenenden, ausfuehrbar
- Attrappen fuer docker/df/free/openssl/curl vorn im PATH liefern ein gesundes und ein krankes Bild; echte Werkzeuge
  (date, stat, awk, sort, tail, find) laufen wie auf dem Server
- gesund: Exit 0, kein Protokoll, keine Mail; krank: alle Kennungen im Protokoll, EINE Mail ueber `python -m app.mail send`
  im App-Container, zweiter Lauf ohne neue Mail (Drossel), gesunder Lauf danach meldet ERHOLT
- --dry-run schreibt nichts und mailt nichts; Mailfehler wird protokolliert
- systemd-Timer alle 5 Minuten, Service mit SuccessExitStatus 0 1; BETRIEB.md und LAUNCH-Doku nennen das Skript
"""
import os
import shutil
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SKRIPT = ROOT / "deploy" / "dienst-check.sh"
pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash fehlt")

ATTRAPPEN = {
    "docker": r'''#!/usr/bin/env bash
case "$1 $2" in
  "inspect --format") cat "$DC_FAKE/inspect.txt" ;;
  "volume inspect") cat "$DC_FAKE/logsdir.txt" ;;
  "compose -f") { echo "ARGS: $*"; cat; echo "---ENDE---"; } >> "$DC_FAKE/mailbox.txt"; exit "${DC_MAIL_EXIT:-0}" ;;
  *) echo "ECHTER-AUFRUF docker $*" >&2; exit 99 ;;
esac
''',
    "df": r'''#!/usr/bin/env bash
pct="$(cat "$DC_FAKE/disk_pct")"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 100000000 ${pct}000000 1000 ${pct}% /"
''',
    "free": r'''#!/usr/bin/env bash
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:          $(cat "$DC_FAKE/ram.txt")"
echo "Swap:             0           0           0"
''',
    "openssl": r'''#!/usr/bin/env bash
case "$1" in
  s_client) cat >/dev/null; echo "-----BEGIN CERTIFICATE-----"; echo "ATTRAPPE"; echo "-----END CERTIFICATE-----" ;;
  x509) cat >/dev/null; echo "notAfter=$(cat "$DC_FAKE/enddate.txt")" ;;
  *) echo "ECHTER-AUFRUF openssl $*" >&2; exit 99 ;;
esac
''',
    "curl": r'''#!/usr/bin/env bash
cat "$DC_FAKE/http.txt"
''',
}


def _enddate(days: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=days)).strftime("%b %d %H:%M:%S %Y GMT")


class Umgebung:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.fake = tmp / "fake"
        self.logs = tmp / "logs"
        self.backups = tmp / "backups"
        self.platte = tmp / "platte"
        self.log = tmp / "dienst-check.log"
        self.state = tmp / "state"
        for d in (self.bin, self.fake, self.logs / "access", self.backups, self.platte):
            d.mkdir(parents=True)
        for name, text in ATTRAPPEN.items():
            f = self.bin / name
            f.write_text(text, encoding="utf-8")
            f.chmod(0o755)
        (self.fake / "logsdir.txt").write_text(str(self.logs) + "\n")

    def gesund(self) -> None:
        (self.fake / "inspect.txt").write_text("/uniflow-app running healthy 0\n/uniflow-jobs running healthy 0\n/uniflow-caddy running - 0\n")
        (self.fake / "disk_pct").write_text("41\n")
        (self.fake / "ram.txt").write_text("16000 6000 4000 10 6000 9500\n")
        (self.fake / "enddate.txt").write_text(_enddate(60) + "\n")
        (self.fake / "http.txt").write_text("200")
        self._zugriff(n=120, fuenfhundert=0, campus429=0, langsam=0)
        hb = self.logs / "jobs.heartbeat"
        hb.write_text("ok")
        os.utime(hb, None)
        b = self.backups / "uniflow-2026-11-08_0330.tar.gz"
        b.write_bytes(b"x")
        os.utime(b, None)

    def krank(self) -> None:
        self.gesund()
        (self.fake / "inspect.txt").write_text("/uniflow-app running healthy 0\n/uniflow-jobs running unhealthy 3\n/uniflow-caddy exited - 1\n")
        (self.fake / "disk_pct").write_text("91\n")
        (self.fake / "ram.txt").write_text("16000 15500 200 10 300 700\n")
        (self.fake / "enddate.txt").write_text(_enddate(5) + "\n")
        (self.fake / "http.txt").write_text("503")
        self._zugriff(n=120, fuenfhundert=12, campus429=3, langsam=10)
        alt = time.time() - 600
        os.utime(self.logs / "jobs.heartbeat", (alt, alt))
        alt = time.time() - 3 * 86400
        os.utime(self.backups / "uniflow-2026-11-08_0330.tar.gz", (alt, alt))

    def _zugriff(self, n: int, fuenfhundert: int, campus429: int, langsam: int) -> None:
        now = datetime.now(timezone.utc)
        ts = (now - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        alt = (now - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        lines = [f'{alt} 10.0.0.1 GET /api/account/me 500 10ms "alt"' for _ in range(50)]     # ausserhalb des Fensters
        for i in range(n):
            st, ms = 200, 20
            if i < fuenfhundert:
                st = 500
            elif i < fuenfhundert + campus429:
                st = 429
            if i >= n - langsam:
                ms = 5000
            path = "/api/account/register" if st == 429 else "/api/entitlements"
            lines.append(f'{ts} 130.75.1.{i % 250} {"POST" if st == 429 else "GET"} {path} {st} {ms}ms "iPad"')
        lines.append(f'{ts} 10.0.0.2 GET /api/x 404 5ms "x"')
        lines.append(f'{ts} 10.0.0.2 PUT /api/files/1/annotations 403 5ms "x"')
        (self.logs / "access" / f"access-{now.strftime('%Y-%m-%d')}.log").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def env(self, **extra) -> dict:
        e = {"HOME": os.environ.get("HOME", "/tmp"), "LC_ALL": "C",
             "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
             "DC_FAKE": str(self.fake), "DIENST_CHECK_LOG": str(self.log), "DIENST_CHECK_STATE": str(self.state),
             "DIENST_CHECK_LOGS_DIR": str(self.logs), "DIENST_CHECK_DOMAIN": "app.example.de",
             "DIENST_CHECK_DISK_PATHS": str(self.platte), "DIENST_CHECK_BACKUP_DIR": str(self.backups),
             "DIENST_CHECK_MIN_REQ": "10", "COMPOSE_DIR": str(self.tmp)}
        e.update(extra)
        return e

    def lauf(self, *args: str, erwartet: int, **extra) -> str:
        p = subprocess.run(["bash", str(SKRIPT), *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           encoding="utf-8", env=self.env(**extra), cwd=ROOT, timeout=60)
        assert "ECHTER-AUFRUF" not in p.stdout, p.stdout
        assert p.returncode == erwartet, f"Exit {p.returncode}, erwartet {erwartet}\n{p.stdout}"
        return p.stdout

    def protokoll(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def mails(self) -> list[str]:
        f = self.fake / "mailbox.txt"
        return [m for m in f.read_text(encoding="utf-8").split("---ENDE---") if m.strip()] if f.exists() else []


@pytest.fixture
def umg(tmp_path):
    return Umgebung(tmp_path)


def test_syntax_hilfe_und_dateiform():
    raw = SKRIPT.read_bytes()
    assert raw.startswith(b"#!/usr/bin/env bash") and b"\r\n" not in raw and b"set -euo pipefail" in raw
    assert os.access(SKRIPT, os.X_OK), "deploy/dienst-check.sh muss ausfuehrbar sein"
    p = subprocess.run(["bash", "-n", str(SKRIPT)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    p = subprocess.run(["bash", str(SKRIPT), "--help"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0 and "--dry-run" in p.stdout and "dienst-check.log" in p.stdout and "support@studinow.app" in p.stdout
    p = subprocess.run(["bash", str(SKRIPT), "--unsinn"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 2 and "Unbekannte Option" in p.stdout + p.stderr


def test_gesund_keine_befunde_keine_mail(umg):
    umg.gesund()
    out = umg.lauf(erwartet=0)
    assert out.strip() == "" and umg.protokoll() == "" and umg.mails() == []
    out = umg.lauf("--verbose", erwartet=0)
    for k in ("OK container uniflow-app", "OK platte", "OK ram", "OK zugriff", "OK campus", "OK zertifikat", "OK jobs", "OK backup", "OK http", "OK gesamt"):
        assert k in out, (k, out)
    assert "PROBLEM" not in out and umg.mails() == []


def test_krank_alle_kennungen_eine_mail_drossel_und_erholung(umg):
    umg.krank()
    out = umg.lauf(erwartet=1)
    log = umg.protokoll()
    for stueck in ("PROBLEM container uniflow-jobs ist unhealthy", "PROBLEM container uniflow-caddy ist exited",
                   "PROBLEM platte", "91 %", "PROBLEM ram 9", "PROBLEM campus 3 x 429", "LERNAPP_LIMIT_REGISTER_IP",
                   "PROBLEM zugriff 5xx-Anteil 9 % (12 von 122 Anfragen", "PROBLEM zugriff p95 der Antwortzeit 5000 ms",
                   "PROBLEM zertifikat Zertifikat von app.example.de laeuft in ", "PROBLEM jobs Lebenszeichen", "PROBLEM backup neuestes Archiv",
                   "PROBLEM http GET https://app.example.de/login antwortet 503", "MAIL an support@studinow.app"):
        assert stueck in log, (stueck, log)
    assert "Fehlerquote 4xx" not in log, "3 x 429 von 122 sind 2 % – unter der 5-%-Grenze; 403/404 zaehlen nicht"
    assert out.strip() == "", "ohne --verbose nichts auf stdout (der Timer soll das Journal nicht fluten)"
    mails = umg.mails()
    assert len(mails) == 1
    m = mails[0]
    assert "exec -T app python -m app.mail send --to support@studinow.app --subject StudiNow dienst-check:" in m
    assert "- platte:" in m and "- zertifikat:" in m and "- campus:" in m and "LAUNCH-4000-2026-11-08.md" in m
    assert sorted(p.name for p in umg.state.glob("*.problem")) == ["backup.problem", "campus.problem", "container.problem", "http.problem",
                                                                     "jobs.problem", "platte.problem", "ram.problem", "zertifikat.problem",
                                                                     "zugriff.problem"]
    # zweiter Lauf: Befunde erneut im Protokoll, aber keine zweite Mail (Drossel 6 h)
    umg.lauf(erwartet=1)
    assert len(umg.mails()) == 1 and umg.protokoll().count("PROBLEM platte") == 2
    # Platte und Zertifikat wieder gut: ERHOLT, Merkdateien weg; der Rest bleibt
    (umg.fake / "disk_pct").write_text("40\n")
    (umg.fake / "enddate.txt").write_text(_enddate(80) + "\n")
    umg.lauf(erwartet=1)
    log = umg.protokoll()
    assert "ERHOLT platte" in log and "ERHOLT zertifikat" in log and "ERHOLT ram" not in log
    assert not (umg.state / "platte.problem").exists() and (umg.state / "ram.problem").exists()
    # alles gesund: ERHOLT fuer den Rest, Exit 0, keine Merkdateien mehr
    umg.gesund()
    umg.lauf(erwartet=0)
    assert "ERHOLT ram" in umg.protokoll() and list(umg.state.glob("*.problem")) == []
    assert len(umg.mails()) == 1


def test_trockenlauf_schreibt_und_mailt_nichts(umg):
    umg.krank()
    out = umg.lauf("--dry-run", erwartet=1)
    assert "PROBLEM platte" in out and "PROBLEM zertifikat" in out
    assert "[trocken] docker compose -f" in out and "python -m app.mail send --to support@studinow.app" in out
    assert "[trocken]   - platte:" in out
    assert not umg.log.exists() and umg.mails() == [] and not umg.state.exists()


def test_no_mail_und_mailfehler(umg):
    umg.krank()
    umg.lauf("--no-mail", erwartet=1)
    assert umg.mails() == [] and "MAIL" not in umg.protokoll()
    assert (umg.state / "platte.problem").exists(), "auch ohne Mail wird das Problem gemerkt (fuer ERHOLT)"
    umg2 = Umgebung(umg.tmp / "zwei")
    umg2.krank()
    umg2.lauf(erwartet=1, DC_MAIL_EXIT="1")
    assert "MAIL-FEHLER an support@studinow.app" in umg2.protokoll() and len(umg2.mails()) == 1
    assert list(umg2.state.glob("*.problem")) == [], "nach einem Mailfehler wird nichts gemerkt: naechster Lauf versucht es wieder"


def test_eigene_grenzen_und_mailadresse(umg):
    umg.gesund()
    (umg.fake / "disk_pct").write_text("75\n")
    umg.lauf(erwartet=0)                                               # 75 % unter 80 %
    umg.lauf(erwartet=1, DIENST_CHECK_DISK_PCT="70", DIENST_CHECK_MAIL_TO="inhaber@example.de")
    assert "PROBLEM platte" in umg.protokoll() and "--to inhaber@example.de" in umg.mails()[0]


def test_zugriff_unter_mindestanzahl_wird_nicht_bewertet(umg):
    umg.gesund()
    umg._zugriff(n=20, fuenfhundert=20, campus429=0, langsam=0)        # 100 % 5xx, aber nur 22 Anfragen (20 + 403 + 404)
    out = umg.lauf("--verbose", erwartet=0, DIENST_CHECK_MIN_REQ="50")
    assert "nur 22 Anfragen im Fenster" in out and "PROBLEM" not in out


def test_timer_service_und_doku():
    timer = (ROOT / "deploy" / "uniflow-dienst-check.timer").read_text(encoding="utf-8")
    service = (ROOT / "deploy" / "uniflow-dienst-check.service").read_text(encoding="utf-8")
    assert "OnUnitActiveSec=5min" in timer and "OnBootSec=" in timer and "WantedBy=timers.target" in timer
    assert "dienst-check.sh" in service and "SuccessExitStatus=0 1" in service and "EnvironmentFile=-/srv/uniflow/dienst-check.env" in service
    assert "Type=oneshot" in service and "After=docker.service" in service
    betrieb = (ROOT / "docs" / "release" / "BETRIEB.md").read_text(encoding="utf-8")
    assert "dienst-check.sh" in betrieb and "uniflow-dienst-check.timer" in betrieb
    launch = (ROOT / "docs" / "release" / "LAUNCH-4000-2026-11-08.md").read_text(encoding="utf-8")
    assert "dienst-check.sh" in launch and "/srv/uniflow/dienst-check.log" in launch

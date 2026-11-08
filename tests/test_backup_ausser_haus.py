"""Sicherung ausser Haus (deploy/backup-ausser-haus.sh, tools/sicherung-ausser-haus-einrichten.sh, dienst-check
"ausser_haus") – ohne Server, ohne Storage Box, ohne age.

Attrappen vorn im PATH (wie tests/test_server_umzug.py): age/age-keygen (Schein-Verschluesselung mit echter
age-Kopfzeile), rsync (spielt die Storage Box in einem lokalen Ordner nach und protokolliert jeden Aufruf), dazu
ssh/scp/sftp/curl als Fallen, die jeden echten Aufruf sofort auffallen lassen.

- bash -n, LF, ausfuehrbar fuer alle beteiligten Skripte
- ohne Konfiguration: Exit 0, Meldung, kein einziger Aufruf von age/rsync
- mit Konfiguration: jedes fehlende Archiv wird verschluesselt, ERST DANN hochgeladen, nie Klartext auf der Box;
  schon vorhandene werden nicht erneut verschluesselt; auf der Box wird geloescht, was aelter als 30 Tage ist
- Fehler (Box nicht erreichbar, Hochladen scheitert, age fehlt oder liefert Klartext, Teil-Konfiguration, privater
  Schluessel in OFFSITE_RECIPIENT, SSH-Schluessel fehlt) -> Exit != 0, Erfolgsmarke bleibt alt
- dienst-check meldet eine veraltete oder fehlende Kopie (nur wenn eingerichtet)
- Einrichtung am Mac: Schluesselpaar lokal, Befehle nur angezeigt, privater Schluessel nie in der Ausgabe;
  --pruefen entschluesselt und prueft das Format von deploy/backup_snapshot.py, Klartext wird geloescht
"""
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SKRIPT = ROOT / "deploy" / "backup-ausser-haus.sh"
EINRICHTEN = ROOT / "tools" / "sicherung-ausser-haus-einrichten.sh"
DIENST_CHECK = ROOT / "deploy" / "dienst-check.sh"
pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash fehlt")

PUB = "age1" + "q" * 58
GEHEIM = "AGE-SECRET-KEY-1ATTRAPPEATTRAPPEATTRAPPEATTRAPPEATTRAPPEATTRAPPEATTRAPPE"
KOPF = b"age-encryption.org/v1\n"

AGE = r'''#!{py}
import base64, json, os, sys
fake = os.environ["AH_FAKE"]
args = sys.argv[1:]
with open(os.path.join(fake, "aufrufe.log"), "a") as log:
    log.write(json.dumps(["age"] + args) + "\n")
if os.environ.get("AGE_FAKE_EXIT"):
    sys.exit(int(os.environ["AGE_FAKE_EXIT"]))
out = args[args.index("-o") + 1]
src = args[-1]
data = open(src, "rb").read()
if "-d" in args:
    key = open(args[args.index("-i") + 1]).read()
    if "AGE-SECRET-KEY-" not in key:
        sys.exit("age: kein privater Schluessel")
    head, rest = data.split(b"\n--- attrappe\n", 1)
    open(out, "wb").write(base64.b64decode(rest))
    sys.exit(0)
assert "-r" in args
if os.environ.get("AGE_FAKE_KLARTEXT"):
    open(out, "wb").write(data)            # kaputtes age: schreibt Klartext
else:
    rec = " ".join(args[i + 1] for i, a in enumerate(args) if a == "-r")
    open(out, "wb").write(b"age-encryption.org/v1\n-> X25519 " + rec.encode() + b"\n--- attrappe\n" + base64.b64encode(data))
'''

AGE_KEYGEN = r'''#!{py}
import os, sys
args = sys.argv[1:]
pub = "{pub}"
if args[:1] == ["-y"]:
    assert "AGE-SECRET-KEY-" in open(args[1]).read()
    print(pub)
    sys.exit(0)
out = args[args.index("-o") + 1]
if os.path.exists(out):
    sys.exit("age-keygen: Datei existiert")
open(out, "w").write("# created: jetzt\n# public key: " + pub + "\n{geheim}\n")
print("Public key: " + pub, file=sys.stderr)
'''

RSYNC = r'''#!{py}
import json, os, shutil, sys
fake = os.environ["AH_FAKE"]
args = sys.argv[1:]
with open(os.path.join(fake, "aufrufe.log"), "a") as log:
    log.write(json.dumps(["rsync"] + args) + "\n")
fern = [a for a in args if "@" in a and ":" in a and not a.startswith("-")]
assert len(fern) == 1, args
fern = fern[0]
remote = os.path.join(fake, "box", fern.split(":", 1)[1].strip("/"))
mode = "liste" if "--list-only" in args else "loeschen" if "--delete" in args else "anlegen" if "-d" in args else "hoch"
if os.environ.get("RSYNC_FAKE_FAIL") == mode:
    sys.stderr.write("rsync: connection unexpectedly closed (Attrappe)\n")
    sys.exit(12)
if mode == "anlegen":
    os.makedirs(remote, exist_ok=True)
elif mode == "liste":
    if not os.path.isdir(remote):
        sys.stderr.write("rsync: change_dir failed: No such file or directory (2)\n")
        sys.exit(23)
    print("drwx------          4,096 2026/11/09 03:31:00 .")
    for n in sorted(os.listdir(remote)):
        print("-rw-------  {{:>13,}} 2026/11/09 03:31:00 {{}}".format(os.path.getsize(os.path.join(remote, n)), n))
elif mode == "loeschen":
    assert "--exclude=*" in args and "-r" in args, args
    src = args[args.index(fern) - 1]
    assert os.listdir(src) == [], "Quelle beim Loeschen muss leer sein"
    for a in args:
        if a.startswith("--include=/"):
            p = os.path.join(remote, a[len("--include=/"):])
            if os.path.isfile(p):
                os.remove(p)
else:
    src = args[args.index(fern) - 1]
    assert src.endswith("/") and "-r" in args, ("ohne -r ueberspringt rsync den Quellordner", args)
    os.makedirs(remote, exist_ok=True)
    with open(os.path.join(fake, "aufrufe.log"), "a") as log:
        for n in sorted(os.listdir(src)):
            data = open(os.path.join(src, n), "rb").read()
            if not data.startswith(b"age-encryption.org/v1\n"):
                log.write(json.dumps(["KLARTEXT", n]) + "\n")
            ziel = os.path.join(remote, n)
            if "--ignore-existing" in args and os.path.exists(ziel):
                continue
            shutil.copyfile(os.path.join(src, n), ziel)
'''

FALLE = "#!/usr/bin/env bash\necho \"ECHTER-AUFRUF $(basename \"$0\") $*\" >&2\nexit 99\n"


def _stempel(tage_zurueck: float) -> str:
    return (datetime.now() - timedelta(days=tage_zurueck)).strftime("%Y-%m-%d_%H%M")


class Box:
    """Server-Ordner (Backups, Status, .env, SSH-Schluessel) und eine nachgespielte Storage Box."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.fake = tmp / "fake"
        self.backups = tmp / "backups"
        self.state = tmp / "ausser-haus"
        self.deploy = tmp / "deploy"
        self.remote = self.fake / "box" / "studinow"
        for d in (self.bin, self.fake, self.backups, self.deploy):
            d.mkdir(parents=True)
        self.key = tmp / "storagebox"
        self.key.write_text("SSH-ATTRAPPE\n")
        py = sys.executable
        for name, text in (("age", AGE), ("age-keygen", AGE_KEYGEN), ("rsync", RSYNC)):
            self._bin(name, text.replace("{py}", py).replace("{pub}", PUB).replace("{geheim}", GEHEIM)
                      .replace("{{", "{").replace("}}", "}"))
        for name in ("ssh", "scp", "sftp", "curl"):
            self._bin(name, FALLE)

    def _bin(self, name: str, text: str) -> None:
        f = self.bin / name
        f.write_text(text, encoding="utf-8")
        f.chmod(0o755)

    def archiv(self, tage_zurueck: float, inhalt: bytes | None = None) -> Path:
        p = self.backups / f"uniflow-{_stempel(tage_zurueck)}.tar.gz"
        p.write_bytes(inhalt if inhalt is not None else b"KLARTEXT-GEHEIM " + p.name.encode() + b" " + os.urandom(64).hex().encode())
        t = time.time() - tage_zurueck * 86400
        os.utime(p, (t, t))
        return p

    def auf_box(self, tage_zurueck: float) -> Path:
        self.remote.mkdir(parents=True, exist_ok=True)
        p = self.remote / f"uniflow-{_stempel(tage_zurueck)}.tar.gz.age"
        p.write_bytes(KOPF + b"-> X25519 alt\n--- attrappe\nQUxU\n")
        return p

    def konfigurieren(self, **werte) -> None:
        zeilen = {"OFFSITE_HOST": "u123456.your-storagebox.de", "OFFSITE_USER": "u123456", "OFFSITE_RECIPIENT": PUB}
        zeilen.update(werte)
        text = "UNIFLOW_DOMAIN=app.example.de\nLERNAPP_SECRET_KEY=NICHT-ZEIGEN\n" + "".join(
            f"{k}={v}\n" for k, v in zeilen.items() if v is not None)
        (self.deploy / ".env").write_text(text, encoding="utf-8")

    def env(self, **extra) -> dict:
        e = {"HOME": str(self.tmp), "LC_ALL": "C", "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
             "AH_FAKE": str(self.fake), "BACKUP_DIR": str(self.backups), "ENV_FILE": str(self.deploy / ".env"),
             "OFFSITE_SSH_KEY": str(self.key), "OFFSITE_STATE_DIR": str(self.state),
             "OFFSITE_KNOWN_HOSTS": str(self.tmp / "known_hosts")}
        e.update(extra)
        return e

    def lauf(self, erwartet: int | None = 0, **extra) -> str:
        p = subprocess.run(["bash", str(SKRIPT)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           encoding="utf-8", env=self.env(**extra), cwd=self.tmp, timeout=60)
        assert "ECHTER-AUFRUF" not in p.stdout, p.stdout
        assert "NICHT-ZEIGEN" not in p.stdout, "Werte aus deploy/.env ausser OFFSITE_* duerfen nie erscheinen"
        if erwartet is None:
            assert p.returncode != 0, f"Fehler erwartet, Exit 0\n{p.stdout}"
        else:
            assert p.returncode == erwartet, f"Exit {p.returncode}, erwartet {erwartet}\n{p.stdout}"
        return p.stdout

    def aufrufe(self) -> list[list[str]]:
        f = self.fake / "aufrufe.log"
        return [json.loads(z) for z in f.read_text().splitlines()] if f.exists() else []


@pytest.fixture
def box(tmp_path):
    return Box(tmp_path)


# ---------------------------------------------------------------- Dateiform

@pytest.mark.parametrize("skript", [SKRIPT, EINRICHTEN, DIENST_CHECK, ROOT / "deploy" / "backup.sh"])
def test_syntax_zeilenenden_ausfuehrbar(skript):
    raw = skript.read_bytes()
    assert raw.startswith(b"#!/usr/bin/env bash") and b"\r\n" not in raw and b"set -euo pipefail" in raw
    if skript.name != "backup.sh":                                 # backup.sh startet systemd ueber bash
        assert os.access(skript, os.X_OK), skript
    p = subprocess.run(["bash", "-n", str(skript)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr


def test_hilfe():
    p = subprocess.run(["bash", str(SKRIPT), "--help"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0 and "OFFSITE_RECIPIENT" in p.stdout and "Port 23" in p.stdout and "set -euo" not in p.stdout
    p = subprocess.run(["bash", str(SKRIPT), "--unsinn"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 2
    p = subprocess.run(["bash", str(EINRICHTEN), "--help"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0 and "--pruefen" in p.stdout and "install-ssh-key" in p.stdout and "set -euo" not in p.stdout


# ---------------------------------------------------------------- ohne Konfiguration

def test_ohne_konfiguration_exit_0_ohne_aufruf(box):
    box.archiv(0.1)
    out = box.lauf(0)
    assert "nicht eingerichtet" in out and box.aufrufe() == [] and not box.remote.exists()
    box.konfigurieren(OFFSITE_HOST="", OFFSITE_USER="", OFFSITE_RECIPIENT="")      # leere Zeilen wie in .env.example
    out = box.lauf(0)
    assert "nicht eingerichtet" in out and box.aufrufe() == [] and not box.state.exists()


# ---------------------------------------------------------------- mit Konfiguration

def test_verschluesselt_erst_dann_hochladen_nie_klartext_und_aufraeumen(box):
    box.konfigurieren()
    lokal = [box.archiv(t) for t in (2.1, 1.1, 0.1)]
    schon_da = box.remote / (lokal[0].name + ".age")
    box.remote.mkdir(parents=True)
    schon_da.write_bytes(KOPF + b"-> X25519 frueher\n--- attrappe\nQUxU\n")
    zu_alt = box.auf_box(40)
    knapp = box.auf_box(29)
    (box.backups / "fremd.txt").write_text("gehoert nicht dazu")
    out = box.lauf(0)
    assert "2 hochgeladen, 1 aelter als 30 Tage geloescht" in out

    # Box: jede lokale Kopie als .age, nichts im Klartext, 40 Tage alt weg, 29 Tage alt noch da
    namen = sorted(p.name for p in box.remote.iterdir())
    assert namen == sorted([knapp.name] + [p.name + ".age" for p in lokal])
    assert not zu_alt.exists() and knapp.exists()
    for p in box.remote.iterdir():
        data = p.read_bytes()
        assert data.startswith(KOPF) and b"KLARTEXT-GEHEIM" not in data, p.name
    assert schon_da.read_bytes().endswith(b"QUxU\n"), "vorhandene Kopie nicht ueberschrieben"

    # Reihenfolge: anlegen, Bestand, age je fehlendem Archiv, ERST DANN hochladen, Bestand, loeschen
    aufrufe = box.aufrufe()
    assert not any(a[0] == "KLARTEXT" for a in aufrufe), aufrufe
    art = []
    for a in aufrufe:
        if a[0] == "age":
            art.append("age")
        elif "--list-only" in a:
            art.append("liste")
        elif "--delete" in a:
            art.append("loeschen")
        elif "-d" in a:
            art.append("anlegen")
        else:
            art.append("hoch")
    assert art == ["anlegen", "liste", "age", "age", "hoch", "liste", "loeschen"], art
    verschluesselt = [a[-1] for a in aufrufe if a[0] == "age"]
    assert verschluesselt == [str(lokal[1]), str(lokal[2])], "nur fehlende, das schon vorhandene nicht erneut"
    for a in aufrufe:
        if a[0] == "age":
            assert a[1:3] == ["-r", PUB] and "-o" in a
    hoch = next(a for a, k in zip(aufrufe, art) if k == "hoch")
    quelle = hoch[-2]
    assert quelle.startswith(str(box.state / "arbeit.")) and "--ignore-existing" in hoch and "-r" in hoch and "-p" in hoch
    ssh = hoch[hoch.index("-e") + 1]
    assert ssh.startswith("ssh -p 23 -i ") and f"-i {box.key}" in ssh and "IdentitiesOnly=yes" in ssh and "BatchMode=yes" in ssh
    assert hoch[-1] == "u123456@u123456.your-storagebox.de:studinow/"
    loeschen = next(a for a, k in zip(aufrufe, art) if k == "loeschen")
    assert [a for a in loeschen if a.startswith("--include=")] == [f"--include=/{zu_alt.name}"]

    # lokal unveraendert, Arbeitsordner weg, Erfolgsmarke fuer dienst-check
    assert all(p.exists() and b"KLARTEXT-GEHEIM" in p.read_bytes() for p in lokal)
    assert list(box.state.glob("arbeit.*")) == []
    marke = (box.state / "letzte-kopie").read_text()
    assert "hochgeladen=2" in marke and "geloescht=1" in marke and "auf_box=4" in marke

    # zweiter Lauf: nichts zu verschluesseln, nichts hochzuladen, nichts zu loeschen
    vorher = len(box.aufrufe())
    out = box.lauf(0)
    neu = box.aufrufe()[vorher:]
    assert "0 hochgeladen, 0 aelter" in out
    assert [a for a in neu if a[0] == "age"] == [] and all("--list-only" in a or "-d" in a for a in neu)


def test_mehrere_empfaenger_und_eigene_frist(box):
    zweiter = "age1" + "p" * 58
    box.konfigurieren(OFFSITE_RECIPIENT=f"{PUB}, {zweiter}", OFFSITE_KEEP_DAYS="10", OFFSITE_DIR="anderer")
    box.archiv(0.1)
    (box.fake / "box" / "anderer").mkdir(parents=True)
    alt = box.fake / "box" / "anderer" / f"uniflow-{_stempel(11)}.tar.gz.age"
    alt.write_bytes(KOPF)
    box.lauf(0)
    age = [a for a in box.aufrufe() if a[0] == "age"]
    assert age[0][1:5] == ["-r", PUB, "-r", zweiter]
    assert not alt.exists()


# ---------------------------------------------------------------- Fehler -> Exit != 0

def _alte_marke(box: Box) -> Path:
    box.state.mkdir(parents=True, exist_ok=True)
    m = box.state / "letzte-kopie"
    m.write_text("alt\n")
    t = time.time() - 3 * 86400
    os.utime(m, (t, t))
    return m


@pytest.mark.parametrize("fall", ["box_nicht_erreichbar", "hochladen", "liste", "aufraeumen"])
def test_rsync_fehler_exit_1_marke_bleibt_alt(box, fall):
    box.konfigurieren()
    box.archiv(0.1)
    box.auf_box(40)
    marke = _alte_marke(box)
    mode = {"box_nicht_erreichbar": "anlegen", "hochladen": "hoch", "liste": "liste", "aufraeumen": "loeschen"}[fall]
    out = box.lauf(1, RSYNC_FAKE_FAIL=mode)
    assert "FEHLER" in out and marke.read_text() == "alt\n"
    assert list(box.state.glob("arbeit.*")) == [], "Arbeitsordner (verschluesselte Dateien) wird auch im Fehlerfall entfernt"


def test_age_fehlt_oder_scheitert_oder_liefert_klartext(box):
    box.konfigurieren()
    box.archiv(0.1)
    marke = _alte_marke(box)
    out = box.lauf(1, AGE_FAKE_EXIT="3")
    assert "nicht verschluesseln" in out and not any("--ignore-existing" in a for a in box.aufrufe())
    out = box.lauf(1, AGE_FAKE_KLARTEXT="1")
    assert "keine age-Kopfzeile" in out
    assert not any("--ignore-existing" in a for a in box.aufrufe()), "Klartext darf nie hochgeladen werden"
    assert not any(p.suffix == ".gz" for p in box.remote.iterdir())
    (box.bin / "age").unlink()
    out = box.lauf(1)
    assert "apt-get install -y age" in out and marke.read_text() == "alt\n"


def test_konfigurationsfehler_exit_2_ohne_aufruf(box):
    box.archiv(0.1)
    box.konfigurieren(OFFSITE_USER=None)
    assert "OFFSITE_USER" in box.lauf(2)
    box.konfigurieren(OFFSITE_RECIPIENT=GEHEIM)
    out = box.lauf(2)
    assert "PRIVATEN age-Schluessel" in out and GEHEIM not in out
    box.konfigurieren(OFFSITE_RECIPIENT="ssh-ed25519 AAAA")
    assert "kein oeffentlicher age-Schluessel" in box.lauf(2)
    box.konfigurieren(OFFSITE_DIR="../weg")
    assert "OFFSITE_DIR ungueltig" in box.lauf(2)
    box.konfigurieren(OFFSITE_HOST="u1.example.de; rm -rf /")
    assert "OFFSITE_HOST ungueltig" in box.lauf(2)
    assert box.aufrufe() == []


def test_ssh_schluessel_oder_archive_fehlen(box):
    box.konfigurieren()
    box.key.unlink()
    assert "ssh-keygen" in box.lauf(1)
    box.key.write_text("x")
    out = box.lauf(1)                                  # Backup-Ordner leer
    assert "kein lokales Archiv" in out and not (box.state / "letzte-kopie").exists()
    assert box.aufrufe() == [], "ohne lokales Archiv wird die Box gar nicht erst angesprochen"


# ---------------------------------------------------------------- dienst-check: Kennung ausser_haus

def test_dienst_check_meldet_veraltete_oder_fehlende_kopie(tmp_path):
    from test_dienst_check import Umgebung
    umg = Umgebung(tmp_path)
    umg.gesund()
    state = tmp_path / "ausser-haus"
    # nicht eingerichtet: kein Befund
    out = umg.lauf("--verbose", erwartet=0, OFFSITE_STATE_DIR=str(state))
    assert "OK ausser_haus nicht eingerichtet" in out
    # eingerichtet (Werte in deploy/.env = COMPOSE_DIR/.env), aber noch nie gelaufen
    (tmp_path / ".env").write_text(f"UNIFLOW_DOMAIN=app.example.de\nOFFSITE_HOST=u1.your-storagebox.de\nOFFSITE_USER=u1\n"
                                   f"OFFSITE_RECIPIENT={PUB}\nOFFSITE_STATE_DIR={state}\n")
    umg.lauf(erwartet=1, DIENST_CHECK_MAIL="0")
    assert "PROBLEM ausser_haus noch keine erfolgreiche Kopie" in umg.protokoll()
    # frisch: kein Befund, ERHOLT
    state.mkdir()
    marke = state / "letzte-kopie"
    marke.write_text("zeit=jetzt\n")
    out = umg.lauf("--verbose", erwartet=0, DIENST_CHECK_MAIL="0")
    assert "OK ausser_haus letzte Kopie 0 h alt" in out and "ERHOLT ausser_haus" in umg.protokoll()
    # 31 h alt: Befund mit Alter und Hinweis
    t = time.time() - 31 * 3600
    os.utime(marke, (t, t))
    umg.lauf(erwartet=1, DIENST_CHECK_MAIL="0")
    log = umg.protokoll()
    assert "PROBLEM ausser_haus letzte erfolgreiche Kopie auf die Storage Box ist 31 h alt (Grenze 30 h)" in log
    assert "backup-ausser-haus.sh" in log
    # eigene Grenze
    umg.lauf("--verbose", erwartet=0, DIENST_CHECK_MAIL="0", DIENST_CHECK_OFFSITE_H="48")


# ---------------------------------------------------------------- Einrichtung am Mac

def _einrichten(box: Box, *args: str, erwartet: int = 0, **extra) -> str:
    env = box.env(TMPDIR=str(box.tmp / "tmp"), **extra)
    (box.tmp / "tmp").mkdir(exist_ok=True)
    p = subprocess.run(["bash", str(EINRICHTEN), *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, encoding="utf-8", env=env, cwd=ROOT, timeout=60)
    assert "ECHTER-AUFRUF" not in p.stdout, f"ssh/scp ohne Rueckfrage:\n{p.stdout}"
    assert GEHEIM not in p.stdout, "privater Schluessel in der Ausgabe"
    assert p.returncode == erwartet, f"Exit {p.returncode}, erwartet {erwartet}\n{p.stdout}"
    return p.stdout


def test_einrichten_erzeugt_schluessel_lokal_und_zeigt_nur_befehle(box):
    out = _einrichten(box, "--benutzer", "u123456")          # ohne Terminal: nur anzeigen, kein ssh
    key = box.tmp / "Studora-Builds" / "private_keys" / "studinow-sicherung-age.txt"
    assert key.is_file() and (key.stat().st_mode & 0o777) == 0o600 and GEHEIM in key.read_text()
    assert ((key.parent.stat().st_mode) & 0o777) == 0o700
    assert "nur angezeigt, nichts ausgefuehrt" in out
    for n in range(1, 7):
        assert f"== Schritt {n}:" in out
    ssh = f"ssh -i {box.tmp}/.ssh/studinow_server root@46.225.32.3 '"
    assert out.count(ssh) == 5 and f"ssh -t -i {box.tmp}/.ssh/studinow_server root@46.225.32.3 '" in out
    assert "apt-get install -y -qq age rsync" in out and "ssh-keygen -q -t ed25519" in out and "-f /root/.ssh/storagebox" in out
    assert "| ssh -p 23" in out and "u123456@u123456.your-storagebox.de install-ssh-key" in out
    assert f"OFFSITE_HOST=u123456.your-storagebox.de OFFSITE_USER=u123456 OFFSITE_RECIPIENT={PUB} >> .env" in out
    assert "chmod 600 .env" in out and "cat .env" not in out
    assert "cp /srv/uniflow/app/deploy/uniflow-backup.service /etc/systemd/system/" in out and "daemon-reload" in out
    assert "bash /srv/uniflow/app/deploy/backup-ausser-haus.sh" in out and "dienst-check.sh --dry-run --verbose" in out
    assert "--pruefen" in out and f"{box.tmp}/Downloads/studinow-probe-" in out
    # zweiter Lauf: derselbe Schluessel bleibt (nie ueberschreiben)
    vorher = key.read_text()
    out = _einrichten(box, "--benutzer", "u123456-sub2", "--nur-anzeigen")
    assert key.read_text() == vorher and "wird weiterverwendet" in out
    assert "OFFSITE_USER=u123456-sub2" in out and "OFFSITE_HOST=u123456.your-storagebox.de" in out


def test_einrichten_fehler(box):
    assert "u123456" in _einrichten(box, "--benutzer", "root", erwartet=1)
    assert "--benutzer" in _einrichten(box, erwartet=1)                      # kein Terminal, kein Benutzer
    assert "IPv4" in _einrichten(box, "--benutzer", "u1", "--server", "x; rm", erwartet=1)
    (box.bin / "age-keygen").unlink()
    assert "brew install age" in _einrichten(box, "--benutzer", "u1", erwartet=1)


def _snapshot_tar(mit_accounts: bool = True) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        def add(name: str, data: bytes) -> None:
            info = tarfile.TarInfo(f"uniflow-data/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        add("BACKUP-INFO.txt", b"created=2026-11-09T02:30:00+00:00\ndata_dir=/data\nsecret_key_included=no\n")
        if mit_accounts:
            con = sqlite3.connect(":memory:")
            con.execute("CREATE TABLE users (id TEXT)")
            con.executemany("INSERT INTO users VALUES (?)", [("a",), ("b",)])
            con.commit()
            add("accounts.db", con.serialize())
            con.close()
        add("users/a/lernapp.db", b"SQLite format 3\x00")
    return buf.getvalue()


def test_pruefen_entschluesselt_prueft_format_und_loescht_klartext(box):
    box.konfigurieren()
    box.archiv(0.1, inhalt=_snapshot_tar())
    box.lauf(0)                                                   # ueber die Box: so liegt die Kopie spaeter vor
    kopie = next(box.remote.iterdir())
    _einrichten(box, "--benutzer", "u123456", "--nur-anzeigen")   # erzeugt den privaten Schluessel
    out = _einrichten(box, "--pruefen", str(kopie))
    assert "Kontodatenbanken (users/*/lernapp.db): 1" in out and "created=2026-11-09" in out
    if shutil.which("sqlite3"):
        assert "integrity_check=ok, Konten=2" in out
    assert "ERGEBNIS: Kopie lesbar und vollstaendig" in out
    assert list((box.tmp / "tmp").iterdir()) == [], "Klartext muss nach der Pruefung geloescht sein"
    # Archiv ohne accounts.db: Exit 1
    box.archiv(0.05, inhalt=_snapshot_tar(mit_accounts=False))
    box.lauf(0)
    neueste = sorted(box.remote.iterdir())[-1]
    out = _einrichten(box, "--pruefen", str(neueste), erwartet=1)
    assert "PROBLEM: uniflow-data/accounts.db fehlt" in out and "NICHT in Ordnung" in out
    assert list((box.tmp / "tmp").iterdir()) == []


# ---------------------------------------------------------------- Einbindung und Doku

def test_einbindung_service_env_und_doku():
    service = (ROOT / "deploy" / "uniflow-backup.service").read_text(encoding="utf-8")
    assert "ExecStart=/usr/bin/env bash /srv/uniflow/app/deploy/backup.sh" in service
    assert "ExecStartPost=/usr/bin/env bash /srv/uniflow/app/deploy/backup-ausser-haus.sh" in service
    assert service.index("ExecStart=") < service.index("ExecStartPost=") and "TimeoutStartSec=" in service
    env = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    for k in ("OFFSITE_HOST=", "OFFSITE_USER=", "OFFSITE_RECIPIENT=", "OFFSITE_KEEP_DAYS="):
        assert f"\n{k}\n" in env, k
    assert "AGE-SECRET-KEY" in env                                   # Warnung: privater Schluessel nie auf den Server
    bet = (ROOT / "docs" / "release" / "BETRIEB.md").read_text(encoding="utf-8")
    for must in ("### Sicherung außer Haus", "BX11", "install-ssh-key", "tools/sicherung-ausser-haus-einrichten.sh",
                 "--pruefen", "age -d", "ExecStartPost", "ausser_haus", "Auftragsverarbeitung", "Port 23"):
        assert must in bet, must
    # Rechtstexte (Storage Box, 30 Tage) gehen erst live, wenn die Kopie wirklich eingerichtet ist: Commit 6ffc94f7 auf
    # Zweig betrieb/sicherung-ausser-haus (Entscheidung 09.11.2026), samt seinen Pruefungen hier.

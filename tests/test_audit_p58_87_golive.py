"""Externer statischer Audit vom 09.11.2026, Pakete 62, 82-85, 87 (Go-live-Gates; Bericht
docs/audit/AUDIT-2026-11-09-PAKET-62-82-87.md, Gates docs/release/GO-LIVE-GATES-2026-11-09.md).

Die Pakete fordern fast nur Nachweise. Hier belegt, was ohne Server geht:
- Werkzeuge fuer den Server-Lasttest laufen auch im Container (python:3.12-slim hat kein `ps`/`pgrep`)
- tools/lasttest-server.sh startet einen EIGENEN Wegwerf-Container und beruehrt den Produktionsdienst nicht
  (Attrappe fuer docker, die jeden Aufruf mitschreibt)
- Restore-Probe (Paket 84): Sicherung -> leerer Ordner -> Dienst auf den Daten, Inhalt gleich (Hashes)
"""
from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"


def _load(name: str):
    path = TOOLS / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").removesuffix(".py"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _fake_proc(root: Path, procs: dict[int, tuple[int, int]]) -> None:
    """Linux-/proc im Kleinen: pid -> (ppid, rss_kb)."""
    for pid, (ppid, rss_kb) in procs.items():
        d = root / str(pid)
        d.mkdir(parents=True)
        (d / "stat").write_text(f"{pid} (python3 -m uvicorn) S {ppid} {pid} {pid} 0 -1 4194560 1 0 0 0\n")
        (d / "status").write_text(f"Name:\tpython3\nPPid:\t{ppid}\nVmRSS:\t  {rss_kb} kB\n")
    (root / "self").mkdir(exist_ok=True)                      # kein Prozess, darf nicht stoeren


def _no_ps(monkeypatch, mod) -> None:
    real = subprocess.run

    def run(cmd, *a, **k):
        if cmd and cmd[0] in ("ps", "pgrep"):
            raise FileNotFoundError(2, "No such file or directory", cmd[0])
        return real(cmd, *a, **k)
    monkeypatch.setattr(mod.subprocess, "run", run)


# ---------------------------------------------------------------- P82: Lastwerkzeuge im Container

@pytest.mark.parametrize("tool", ["lasttest-ki.py", "lasttest-anmeldung.py"])
def test_p82_lasttest_tools_measure_memory_in_a_container_without_ps(tool, tmp_path, monkeypatch):
    """Bestaetigt (Werkzeug): im Image `python:3.12-slim` (deploy/Dockerfile) gibt es weder `ps` noch `pgrep`
    (procps fehlt). tools/lasttest-ki.py brach dort beim ersten Speicher-Abtasten mit FileNotFoundError ab - der
    Lasttest auf dem Server waere nach dem Anlegen der Konten gestorben; lasttest-anmeldung.py lief weiter, schrieb
    aber keinen Speicher mit. Jetzt lesen beide /proc, wenn `ps` fehlt."""
    mod = _load(tool)
    proc = tmp_path / "proc"
    _fake_proc(proc, {100: (1, 51200), 101: (100, 204800), 102: (100, 307200), 103: (100, 20480), 200: (1, 99999)})
    monkeypatch.setattr(mod, "PROC", proc, raising=False)
    _no_ps(monkeypatch, mod)
    assert sorted(mod.children(100)) == [101, 102, 103]
    assert [round(x) for x in mod.rss_mb([101, 102])] == [200, 300]


def _free_port() -> int:
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_p82_ki_lasttest_reaches_the_fake_provider_in_hosted_mode(tmp_path):
    """Bestaetigt (Werkzeug): seit Audit P7-03 (08.11.2026) nimmt der Dienst als LERNAPP_OPENAI_BASE_URL nur noch
    https://api.openai.com an - tools/lasttest-ki.py zeigt aber auf die Attrappe http://127.0.0.1:<port>/v1. Jede
    KI-Frage endete mit 503 ai_not_configured (0 von 10 beantwortet); ein Lauf auf dem Server haette 4.000 Fehler
    "gemessen" und nichts ueber die Kapazitaet gesagt. Jetzt startet das Werkzeug den Dienst ueber
    tools/lasttest_dienst.py, das NUR die Loopback-Attrappe zulaesst (der Dienst selbst bleibt streng)."""
    import json
    import sys
    out = tmp_path / "ki.json"
    r = subprocess.run([sys.executable, str(TOOLS / "lasttest-ki.py"), "--ai", "6", "--normal", "6", "--accounts", "3",
                        "--delay", "0.2", "--workers", "1", "--port", str(_free_port()), "--provider-port", str(_free_port()),
                        "--json", str(out)], cwd=ROOT, capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stderr[-2000:]
    res = json.loads(out.read_text())
    assert res["ai_ok"] == 6, res["ai_errors"]


def test_p82_lasttest_entry_allows_only_the_loopback_fake_provider(monkeypatch):
    """Die Ausnahme gilt nur fuer http://127.0.0.1 / localhost; jede andere fremde Adresse bleibt ai_not_configured,
    und der Dienst selbst (app.ai_backend) ist unveraendert streng."""
    import importlib
    import sys
    from app import ai_backend, config
    monkeypatch.setattr(config, "MODE", "hosted")
    strict = ai_backend.check_openai_base_url
    monkeypatch.syspath_prepend(str(TOOLS))
    sys.modules.pop("lasttest_dienst", None)
    try:
        mod = importlib.import_module("lasttest_dienst")
        assert mod.app is not None
        check = ai_backend.check_openai_base_url
        assert check("http://127.0.0.1:8799/v1") == "http://127.0.0.1:8799/v1"
        assert check("https://api.openai.com/v1") == "https://api.openai.com/v1"
        for bad in ("http://10.0.0.5:8799/v1", "http://evil.example/v1", "https://api.openai.com.evil.example/v1"):
            with pytest.raises(ai_backend.AIUnavailable):
                check(bad)
    finally:
        ai_backend.check_openai_base_url = strict
        sys.modules.pop("lasttest_dienst", None)
    with pytest.raises(ai_backend.AIUnavailable):
        ai_backend.check_openai_base_url("http://127.0.0.1:8799/v1")


def test_p82_soak_tool_keeps_every_acknowledged_write_and_survives_a_killed_worker(tmp_path):
    """tools/lasttest-dauer.py (neu, Gate G5/P84-01 im Kleinen): offener Anfragestrom ueber viele Sitzungen,
    KI-Fragen gegen die Attrappe, ein API-Prozess wird mit SIGKILL beendet, danach ein Wiederanlauf-Sturm. Jeder mit
    200 bestaetigte Push steht danach in der Konto-Datenbank; uvicorn ersetzt den beendeten Prozess."""
    import json
    import sys
    out = tmp_path / "dauer.json"
    r = subprocess.run([sys.executable, str(TOOLS / "lasttest-dauer.py"), "--sessions", "60", "--accounts", "15", "--minuten", "0.2",
                        "--rate", "30", "--workers", "2", "--parallel", "16", "--sturm-sekunden", "2", "--kill-worker-nach", "4",
                        "--ai", "--ai-delay", "0.2", "--ai-jitter", "0.2", "--provider-port", str(_free_port()), "--json", str(out)],
                       cwd=ROOT, capture_output=True, text=True, timeout=240)
    assert r.returncode == 0, (r.stdout[-2000:], r.stderr[-2000:])
    res = json.loads(out.read_text())
    status = {k: v for m in res["minutes"] for k, v in m["status"].items()}
    assert not any("ai_not_configured" in k for k in status), status
    assert res["minutes"][0]["by"].get("ai", {}).get("n", 0) > 0
    assert res["writes"]["acked"] > 0 and res["writes"]["missing"] == 0
    assert res["killed"]["at"] is not None and res["killed"]["back_after_s"] is not None, res["killed"]
    assert res["storm"]["errors"] == 0 and res["storm"]["n"] == 3 * res["sessions"]


# ---------------------------------------------------------------- P82/G5: tools/lasttest-server.sh mit docker-Attrappe

SERVER_SH = TOOLS / "lasttest-server.sh"
PROD = ("uniflow-app", "uniflow-jobs", "uniflow-caddy")

FAKE_DOCKER = r'''#!/usr/bin/env bash
# Attrappe: schreibt jeden Aufruf mit und spielt einen gesunden Server mit Produktion
printf '%s\n' "$*" >> "$LT_FAKE/calls.log"
last=""; for a in "$@"; do last="$a"; done
case "$1" in
  image) [ -f "$LT_FAKE/no_image" ] && exit 1; echo "sha256:lasttest 2026-11-08T20:00:00Z"; exit 0 ;;
  inspect)
    case "$*" in
      *State.Status*) if [ -f "$LT_FAKE/state_$last" ]; then cat "$LT_FAKE/state_$last"; else echo "/$last running healthy 0"; fi ;;
      *Config.Env*) printf 'WEB_CONCURRENCY=12\nLERNAPP_SECRET_KEY=GEHEIM-SCHLUESSEL-123\nLERNAPP_OPENAI_API_KEY=sk-echt-geheim\nLERNAPP_LIMIT_REGISTER_IP=2000/60\nLERNAPP_SMTP_PASSWORD=mail-geheim\n' ;;
      *) echo "sha256:prod 2026-11-08T21:00:00Z mem=8589934592" ;;
    esac ;;
  run)
    prev=""; for a in "$@"; do
      if [ "$prev" = "-v" ]; then case "$a" in *:/lt) echo "${a%:/lt}" > "$LT_FAKE/work" ;; esac; fi; prev="$a"
    done
    echo fakecontainer ;;
  exec)
    work="$(cat "$LT_FAKE/work")"
    [ -d "$work/tools" ] || { echo "Werkzeuge fehlen im Arbeitsordner" >&2; exit 98; }
    tool=""; prev=""; for a in "$@"; do
      case "$a" in /lt/tools/*) tool="${a#/lt/tools/}" ;; esac
      if [ "$prev" = "--json" ]; then j="${a#/lt/}"; echo '{"ok": true}' > "$work/$j"; fi; prev="$a"
    done
    [ -f "$LT_FAKE/low_on_exec" ] && printf 'MemTotal: 16000000 kB\nMemAvailable: 500000 kB\n' > "$LT_FAKE/proc/meminfo"
    sleep "${LT_FAKE_EXEC_S:-0}"
    echo "| Phase | n | ok |"; echo "| $tool | 1 | 1 |"
    [ -f "$LT_FAKE/fail_$tool" ] && exit 1
    exit 0 ;;
  stats) echo "$(date +%H:%M:%S);uniflow-lasttest;12.5%;1GiB / 6GiB" ;;
  rm|kill) exit 0 ;;
  *) echo "UNERWARTET docker $*" >&2; exit 99 ;;
esac
'''


class ServerEnv:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.fake = tmp / "fake"
        self.bin = tmp / "bin"
        self.tmp_root = tmp / "tmproot"
        self.out = tmp / "out"
        for d in (self.fake / "proc", self.bin, self.tmp_root):
            d.mkdir(parents=True)
        (self.bin / "docker").write_text(FAKE_DOCKER)
        (self.bin / "docker").chmod(0o755)
        (self.fake / "proc" / "meminfo").write_text("MemTotal: 16000000 kB\nMemAvailable: 12000000 kB\n")
        (self.fake / "proc" / "stat").write_text("cpu  100 0 100 800 0 0 0 0 0 0\n")
        (self.fake / "proc" / "loadavg").write_text("0.50 0.40 0.30 1/200 12345\n")

    def run(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        import os
        e = {k: v for k, v in os.environ.items() if not k.startswith("LT_")}
        e.update({"PATH": f"{self.bin}:{e.get('PATH', '/usr/bin:/bin')}", "LT_FAKE": str(self.fake), "LT_PROC": str(self.fake / "proc"),
                  "LT_TMP_ROOT": str(self.tmp_root), "LT_OUT": str(self.out), "LT_REPO": str(self.tmp / "kein-repo"),
                  "LT_STUNDE": "03", "LT_TAKT": "1", "LT_MIN_TMP_MB": "1"})
        e.update(env)
        return subprocess.run(["bash", str(SERVER_SH), *args], env=e, capture_output=True, text=True, timeout=120)

    def calls(self) -> list[str]:
        f = self.fake / "calls.log"
        return f.read_text().splitlines() if f.exists() else []


def _assert_production_untouched(calls: list[str]) -> None:
    """Nur lesende Aufrufe fuer die Produktion; alles Schreibende trifft ausschliesslich den eigenen Container."""
    for c in calls:
        words = c.split()
        verb = words[0]
        assert verb in ("image", "inspect", "run", "exec", "stats", "rm", "kill"), c
        assert "compose" not in words and "volume" not in words and "system" not in words, c
        assert "uniflow_uniflow-data" not in c and "uniflow-data:" not in c and "uniflow-logs:" not in c, c
        if verb in ("exec", "rm", "kill"):
            target = [w for w in words[1:] if not w.startswith("-")][0]
            assert target.startswith("uniflow-lasttest-"), c
            assert target not in PROD, c
        if verb == "run":
            assert "--network none" in c and "--name uniflow-lasttest-" in c, c
            assert " -p " not in f" {c} " and "--publish" not in c and "--env-file" not in c, c
            vols = [words[i + 1] for i, w in enumerate(words) if w == "-v"]
            ro = [v for v in vols if v.endswith(":/lt/backup.tar.gz:ro")]      # Restore-Probe: eine Archivdatei, nur lesend
            assert len(ro) <= 1 and all("/uniflow-" in v and v.split(":")[0].endswith(".tar.gz") for v in ro), ro
            assert vols and all("/uniflow-lasttest-" in v.split(":")[0] for v in vols if v not in ro), vols
            assert "--memory" in words and "--cpus" in words and "--cap-drop" in words, c
            assert "OPENAI" not in c and "SMTP" not in c and "LERNAPP_MAIL=log" in c, c


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
def test_g5_server_load_test_runs_in_its_own_container_and_leaves_production_alone(tmp_path):
    """tools/lasttest-server.sh (neu): eigener Container aus uniflow-app:latest, kein Netz, eigener Ordner unter /tmp,
    drei Phasen mit den geforderten Zahlen, Host-Mitschrift, Fingerabdruck der Produktion OHNE Geheimnisse, am Ende
    Container und Ordner weg - und fuer die Produktion nur docker inspect/stats."""
    env = ServerEnv(tmp_path)
    r = env.run(LT_FAKE_EXEC_S="1.5")
    assert r.returncode == 0, (r.stdout, r.stderr)
    calls = env.calls()
    _assert_production_untouched(calls)
    runs = [c for c in calls if c.startswith("run ")]
    assert len(runs) == 1
    name = runs[0].split("--name ")[1].split()[0]
    assert "uniflow-app:latest" in runs[0] and "--entrypoint sleep" in runs[0]
    execs = [c for c in calls if c.startswith("exec ")]
    assert len(execs) == 3
    ki, anm, dauer = execs
    assert "lasttest-ki.py" in ki and "--ai 4000" in ki and "--workers 12" in ki
    assert "lasttest-anmeldung.py" in anm and "--register 1000" in anm and "--logins 4000" in anm and "--syncs 4000" in anm
    assert "lasttest-dauer.py" in dauer and "--sessions 4000" in dauer and "--minuten 30" in dauer and "--ai" in dauer.split()
    assert calls[-1] == f"rm -f {name}" or f"rm -f {name}" in calls
    assert not list(env.tmp_root.iterdir()), "Arbeitsordner nicht weggeraeumt"
    for f in ("ERGEBNIS.md", "host.csv", "produktion-vorher.txt", "produktion-nachher.txt", "ki.json", "anmeldung.json", "dauer.json"):
        assert (env.out / f).exists(), f
    alles = "".join(p.read_text() for p in env.out.iterdir() if p.is_file())
    assert "GEHEIM" not in alles and "sk-echt" not in alles and "mail-geheim" not in alles
    assert "env WEB_CONCURRENCY=12" in (env.out / "produktion-vorher.txt").read_text()
    assert len((env.out / "host.csv").read_text().splitlines()) >= 2
    assert "Produktion unveraendert" in r.stdout


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
@pytest.mark.parametrize("case", ["unhealthy", "speicher", "tagsueber", "image"])
def test_g5_server_load_test_refuses_before_starting_anything(tmp_path, case):
    env = ServerEnv(tmp_path)
    extra = {}
    if case == "unhealthy":
        (env.fake / "state_uniflow-app").write_text("/uniflow-app running unhealthy 3\n")
    elif case == "speicher":
        (env.fake / "proc" / "meminfo").write_text("MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\n")
    elif case == "tagsueber":
        extra["LT_STUNDE"] = "14"
    else:
        (env.fake / "no_image").write_text("")
    r = env.run(**extra)
    assert r.returncode == 2, (r.stdout, r.stderr)
    assert "VERWEIGERT" in r.stderr
    assert not any(c.startswith(("run ", "exec ", "rm ", "kill ")) for c in env.calls())
    if case == "tagsueber":
        assert env.run("--auch-tagsueber", "--phasen", "ki", LT_STUNDE="14").returncode == 0


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
def test_g5_server_load_test_dry_run_starts_nothing(tmp_path):
    env = ServerEnv(tmp_path)
    r = env.run("--trocken")
    assert r.returncode == 0 and "Trockenlauf" in r.stdout
    assert not any(c.startswith(("run ", "exec ", "rm ", "kill ")) for c in env.calls())
    assert "GEHEIM" not in r.stdout and "env LERNAPP_LIMIT_REGISTER_IP=2000/60" in r.stdout


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
def test_g5_server_load_test_cleans_up_when_a_phase_fails(tmp_path):
    env = ServerEnv(tmp_path)
    (env.fake / "fail_lasttest-anmeldung.py").write_text("")
    r = env.run()
    assert r.returncode == 1 and "GESCHEITERT" in r.stdout
    calls = env.calls()
    _assert_production_untouched(calls)
    assert any(c.startswith("rm -f uniflow-lasttest-") for c in calls)
    assert not list(env.tmp_root.iterdir())


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
def test_g5_server_load_test_watchdog_stops_its_own_container_when_memory_runs_low(tmp_path):
    env = ServerEnv(tmp_path)
    (env.fake / "low_on_exec").write_text("")
    r = env.run(LT_FAKE_EXEC_S="3")
    assert r.returncode == 1, (r.stdout, r.stderr)
    assert "ABBRUCH" in (env.out / "abbruch.txt").read_text()
    calls = env.calls()
    _assert_production_untouched(calls)
    assert any(c.startswith("kill uniflow-lasttest-") for c in calls)
    assert len([c for c in calls if c.startswith("exec ")]) == 1, "nach dem Abbruch keine weitere Phase"
    assert any(c.startswith("rm -f uniflow-lasttest-") for c in calls)
    assert not list(env.tmp_root.iterdir())


@pytest.mark.skipif(not __import__("shutil").which("bash"), reason="bash fehlt")
def test_g6_server_restore_probe_mounts_only_the_newest_archive_read_only(tmp_path):
    import os
    env = ServerEnv(tmp_path)
    backups = tmp_path / "backups"
    backups.mkdir()
    old, new = backups / "uniflow-2026-11-08_0330.tar.gz", backups / "uniflow-2026-11-09_0330.tar.gz"
    old.write_bytes(b"alt")
    new.write_bytes(b"neu")
    os.utime(old, (1, 1))
    r = env.run("--phasen", "restore", LT_BACKUP_DIR=str(backups))
    assert r.returncode == 0, (r.stdout, r.stderr)
    calls = env.calls()
    _assert_production_untouched(calls)
    run = next(c for c in calls if c.startswith("run "))
    assert f"-v {new}:/lt/backup.tar.gz:ro" in run and str(old) not in run
    ex = [c for c in calls if c.startswith("exec ")]
    assert len(ex) == 1 and "restore-probe.py /lt/backup.tar.gz --ziel /lt/tmp/restore" in ex[0]
    assert (env.out / "restore.json").exists() and not list(env.tmp_root.iterdir())
    assert new.read_bytes() == b"neu"
    leer = tmp_path / "leer"
    leer.mkdir()
    r = env.run("--phasen", "restore", LT_BACKUP_DIR=str(leer))
    assert r.returncode == 2 and "kein Archiv" in r.stderr


# ---------------------------------------------------------------- P84-03 / P62-12 / G6: Restore-Probe im Kleinen

def test_p84_03_backup_restores_into_an_empty_folder_with_identical_content_and_a_working_service(tmp_path):
    """Echter Weg wie im Ernstfall (BETRIEB.md 9, Wiederherstellung): Dienst mit Konten, Abgleich-Daten und Sitzungen ->
    deploy/backup_snapshot.py -> Archiv in einen LEEREN Ordner (tools/restore-probe.py) -> jede Datenbank
    integrity_check ok, Inhalt Datenbank fuer Datenbank gleich (sha256 ueber iterdump), Dienst startet auf den
    wiederhergestellten Daten und liefert Konto, Abo-Stand und Abgleich fuer jedes Konto. Ausgabe ohne Adressen."""
    import argparse
    import json
    import os
    import shutil
    import sys
    la = _load("lasttest-anmeldung.py")
    probe = _load("restore-probe.py")
    d = la.Dienst(argparse.Namespace(repo=None, workers=1, env=[], port=0, keep=True))
    d.start()
    try:
        for i in range(3):
            st, _, raw = d.call("POST", "/api/account/register", {"email": f"rueck{i}@beispiel.de", "password": la.PASSWORD, "university": "luh"})
            assert st == 201, raw
            tok = json.loads(raw)["token"]
            items = [{"entity": "modules", "local_id": -(k + 1), "op_id": f"rp-{i}-{k}-op", "data": {"name": f"Modul {i}-{k}"}} for k in range(2)]
            st, _, raw = d.call("POST", "/api/sync/push", {"device_id": f"ipad-{i}", "items": items, "deletes": []}, token=tok)
            assert st == 200, raw
    finally:
        d.stop()
    data = d.tmp / "data"
    try:
        archive = tmp_path / "uniflow-2026-11-09_0330.tar.gz"
        with open(archive, "wb") as f:
            r = subprocess.run([sys.executable, str(ROOT / "deploy" / "backup_snapshot.py")], stdout=f, stderr=subprocess.PIPE,
                               env={**os.environ, "LERNAPP_DATA_DIR": str(data)}, timeout=120)
        assert r.returncode == 0, r.stderr
        original = probe.fingerprints(data)
        assert "accounts.db" in original and sum(1 for k in original if k.startswith("users/")) >= 3
        out = tmp_path / "probe.json"
        r = subprocess.run([sys.executable, str(TOOLS / "restore-probe.py"), str(archive), "--ziel", str(tmp_path / "restore"),
                            "--stichproben", "10", "--hashes", "--json", str(out)], cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert r.returncode == 0, (r.stdout[-3000:], r.stderr[-3000:])
        res = json.loads(out.read_text())
        assert res["integrity"]["bad"] == 0 and res["created"]
        assert res["counts"]["users_active"] == 3 and res["counts"]["user_dbs"] == 3
        assert res["fingerprints"] == original, "Inhalt nach der Wiederherstellung anders als vorher"
        assert res["service"]["samples"] == 3 and res["service"]["ok"], res["service"]
        assert "@beispiel.de" not in r.stdout
    finally:
        shutil.rmtree(d.tmp, ignore_errors=True)


def test_p84_03_restore_probe_refuses_an_archive_that_escapes_its_folder(tmp_path):
    import io
    import tarfile
    probe = _load("restore-probe.py")
    archive = tmp_path / "boese.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for name in ("uniflow-data/accounts.db", "uniflow-data/../../etc/cron.d/x"):
            info = tarfile.TarInfo(name)
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
    with pytest.raises(SystemExit, match="unsicher"):
        probe.extract(archive, tmp_path / "ziel")
    assert not (tmp_path / "etc").exists()


# ---------------------------------------------------------------- P62-F7 / P62-04: Pull bei Burst-Updates

def test_p62_07_paged_pull_of_ten_thousand_burst_changes_skips_nothing(tmp_path):
    """Festgenagelt (P62-F7): 10.500 Aenderungen eines Kontos in Bursts zu je 500 Zeilen mit GLEICHEM Zeitstempel,
    dazwischen spaetere Aenderungen; ein Geraet holt mit der echten Seitengrenze (MAX_PULL 2.000) seitenweise ab.
    Jede Zeile kommt an, keine fehlt, der Cursor laeuft nur vorwaerts, danach ist nichts mehr offen."""
    import sqlite3
    import time
    from app import db, sync
    c = sqlite3.connect(tmp_path / "burst.db")
    c.row_factory = sqlite3.Row
    db._init_db(c)
    since = sync.changes(c, None)["cursor"]
    while sync.changes(c, since)["has_more"]:
        since = sync.changes(c, since)["cursor"]
    for b in range(21):
        c.executemany("INSERT INTO modules(name, created_at) VALUES (?, '2026-11-09')", [(f"B{b}-{i}",) for i in range(500)])
        c.execute("UPDATE modules SET sort=? WHERE name LIKE ?", (b, f"B{b}-%"))       # ein Zeitstempel fuer den ganzen Burst
        c.commit()
        time.sleep(0.002)
    seen: list[str] = []
    pages, cursor = 0, since
    while True:
        r = sync.changes(c, cursor)
        pages += 1
        seen += [m["name"] for m in r["changes"].get("modules", [])]
        assert r["cursor"] is None or cursor is None or r["cursor"] >= cursor
        cursor = r["cursor"]
        if not r["has_more"]:
            break
        assert pages < 50
    assert pages >= 5, "Seitengrenze greift"
    assert set(seen) == {f"B{b}-{i}" for b in range(21) for i in range(500)}
    assert sync.changes(c, cursor)["changes"] == {}
    c.close()

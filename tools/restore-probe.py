#!/usr/bin/env python
"""Restore-Probe einer Sicherung (09.11.2026, Audit Paket 84 P84-03, Gate G6): Archiv aus deploy/backup.sh in einen
LEEREN Ordner auspacken, jede Datenbank pruefen, den Dienst auf genau diesen Daten starten und fuer Stichproben-Konten
Konto, Abo-Stand und Abgleich abfragen.

    python tools/restore-probe.py ARCHIV.tar.gz --ziel /tmp/probe [--stichproben 20] [--hashes] [--json ergebnis.json]

Auf dem Server laeuft das im Wegwerf-Container von tools/lasttest-server.sh (`--phasen restore`, kein Netz, Archiv nur
lesend eingebunden, Ordner danach geloescht). Die Ausgabe nennt nur Zahlen - keine Adressen, keine Konto-IDs, keine
Inhalte. Mit `--hashes` zusaetzlich je Datenbank ein Fingerabdruck des Inhalts (sha256 ueber `iterdump`), damit man
Original und Wiederherstellung vergleichen kann (tests/test_audit_p58_87_golive.py).

Pruefungen: Archiv sicher auspackbar (keine absoluten Pfade, kein `..`), BACKUP-INFO.txt mit created=, accounts.db
vorhanden, `PRAGMA integrity_check` = ok fuer JEDE .db, Zaehlung Konten (aktiv/geloescht), Berechtigungen, Konto-
Datenbanken; Dienst startet (uvicorn, 2 Prozesse, nur 127.0.0.1, Mail nur ins Protokoll, keine Jobs) und liefert fuer
jede Stichprobe 200 bei /api/account/me, /api/entitlements und /api/sync/changes. Exit 0 = alles in Ordnung.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PREFIX = "uniflow-data/"


def extract(archive: Path, target: Path) -> int:
    """Nur Eintraege unter uniflow-data/, ohne absolute Pfade und `..`; liefert die Zahl der Dateien."""
    target.mkdir(parents=True, exist_ok=False)
    n = 0
    with tarfile.open(archive, "r:gz") as tar:
        for m in tar:
            name = m.name
            if not name.startswith(PREFIX) or name.startswith("/") or ".." in Path(name).parts:
                raise SystemExit(f"unsicherer Eintrag im Archiv: {name!r}")
            if not (m.isfile() or m.isdir()):
                continue
            rel = name[len(PREFIX):]
            if not rel:
                continue
            dest = target / rel
            if m.isdir():
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            src = tar.extractfile(m)
            with open(dest, "wb") as f:
                while chunk := src.read(1 << 20):
                    f.write(chunk)
            n += 1
    return n


def db_fingerprint(path: Path) -> str:
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        h = hashlib.sha256()
        for line in c.iterdump():
            h.update(line.encode("utf-8", "surrogatepass"))
            h.update(b"\n")
        return h.hexdigest()
    finally:
        c.close()


def fingerprints(data: Path) -> dict[str, str]:
    return {p.relative_to(data).as_posix(): db_fingerprint(p) for p in sorted(data.rglob("*.db"))}


def check_dbs(data: Path) -> dict:
    ok, bad = 0, []
    for p in sorted(data.rglob("*.db")):
        try:
            c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
            r = c.execute("PRAGMA integrity_check").fetchone()[0]
            c.close()
        except sqlite3.Error as e:
            r = str(e)
        if r == "ok":
            ok += 1
        else:
            bad.append(p.relative_to(data).as_posix().split("/")[0])      # nur der oberste Ordner, keine Konto-ID
    return {"ok": ok, "bad": len(bad), "bad_where": sorted(set(bad))}


def counts(data: Path) -> dict:
    c = sqlite3.connect(f"file:{data / 'accounts.db'}?mode=ro", uri=True)
    try:
        out = {"users_active": c.execute("SELECT count(*) FROM users WHERE status='active'").fetchone()[0],
               "users_deleted": c.execute("SELECT count(*) FROM users WHERE status!='active'").fetchone()[0]}
        try:
            out["entitlements"] = c.execute("SELECT count(*) FROM entitlements").fetchone()[0]
        except sqlite3.Error:
            out["entitlements"] = None
    finally:
        c.close()
    out["user_dbs"] = sum(1 for _ in (data / "users").glob("*/lernapp.db")) if (data / "users").is_dir() else 0
    return out


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def service_env(data: Path, logs: Path) -> dict:
    e = {k: v for k, v in os.environ.items() if not k.startswith("LERNAPP_")}
    e.update({"LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": str(data), "LERNAPP_LOG_DIR": str(logs), "LERNAPP_JOBS": "off",
              "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_MAIL": "log", "LERNAPP_OCR": "off", "LERNAPP_ALLOWED_HOSTS": "127.0.0.1",
              "LERNAPP_AI_PROVIDER": "none", "WEB_CONCURRENCY": "2", "PYTHONUNBUFFERED": "1"})
    if os.environ.get("LERNAPP_SECRET_KEY"):
        e["LERNAPP_SECRET_KEY"] = os.environ["LERNAPP_SECRET_KEY"]
    return e


def call(base: str, path: str, token: str | None = None) -> int:
    req = urllib.request.Request(base + path)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            r.read()
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:  # noqa: BLE001
        return 0


def probe_service(data: Path, logs: Path, repo: Path, samples: int) -> dict:
    env = service_env(data, logs)
    # Sitzungen fuer Stichproben-Konten direkt in der WIEDERHERGESTELLTEN accounts.db (nur dieser Ordner, wird geloescht)
    os.environ.update({k: v for k, v in env.items() if k.startswith("LERNAPP_")})
    sys.path.insert(0, str(repo))
    from app import accounts  # noqa: E402
    with accounts.cursor() as conn:
        ids = [r[0] for r in conn.execute("SELECT id FROM users WHERE status='active' ORDER BY random() LIMIT ?", (samples,))]
        tokens = [accounts.create_session(conn, uid, "restore-probe-" + uuid.uuid4().hex[:8], "Restore-Probe") for uid in ids]
    port = free_port()
    log = open(logs / "dienst.log", "wb")
    proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.server:app", "--host", "127.0.0.1", "--port", str(port),
                             "--workers", "2", "--no-access-log", "--log-level", "warning"], cwd=str(repo), env=env, stdout=log, stderr=log)
    base = f"http://127.0.0.1:{port}"
    try:
        t0 = time.monotonic()
        while time.monotonic() - t0 < 90 and call(base, "/login") != 200:
            if proc.poll() is not None:
                break
            time.sleep(0.3)
        start_s = round(time.monotonic() - t0, 1)
        up = call(base, "/login") == 200
        status: dict[str, dict[str, int]] = {}
        for tok in tokens:
            for path in ("/api/account/me", "/api/entitlements", "/api/sync/changes?limit=50"):
                key = path.split("?")[0]
                st = str(call(base, path, tok))
                status.setdefault(key, {})
                status[key][st] = status[key].get(st, 0) + 1
    finally:
        proc.terminate()
        try:
            proc.wait(20)
        except Exception:  # noqa: BLE001
            proc.kill()
    all_ok = up and all(set(v) == {"200"} for v in status.values()) and len(tokens) > 0
    return {"started": up, "start_s": start_s, "samples": len(tokens), "status": status, "ok": all_ok}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("archive")
    ap.add_argument("--ziel", required=True, help="leerer Ordner, in den ausgepackt wird (wird angelegt)")
    ap.add_argument("--repo", default=str(ROOT), help="Code-Stand des Dienstes (Container: /srv/uniflow)")
    ap.add_argument("--stichproben", type=int, default=20)
    ap.add_argument("--hashes", action="store_true")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    target = Path(a.ziel)
    data, logs = target / "data", target / "logs"
    t0 = time.monotonic()
    n_files = extract(Path(a.archive), data)
    logs.mkdir(parents=True, exist_ok=True)
    info = (data / "BACKUP-INFO.txt").read_text(encoding="utf-8") if (data / "BACKUP-INFO.txt").exists() else ""
    created = next((ln.split("=", 1)[1] for ln in info.splitlines() if ln.startswith("created=")), None)
    res = {"archive_bytes": Path(a.archive).stat().st_size, "files": n_files, "created": created,
           "accounts_db": (data / "accounts.db").exists(), "extract_s": round(time.monotonic() - t0, 1)}
    if not res["accounts_db"]:
        print(json.dumps(res, indent=2))
        print("ERGEBNIS: accounts.db fehlt im Archiv")
        return 1
    res["integrity"] = check_dbs(data)
    res["counts"] = counts(data)
    if a.hashes:
        res["fingerprints"] = fingerprints(data)
    res["service"] = probe_service(data, logs, Path(a.repo), a.stichproben)
    res["restore_s"] = round(time.monotonic() - t0, 1)
    ok = res["integrity"]["bad"] == 0 and created is not None and res["service"]["ok"]
    res["ok"] = ok
    text = json.dumps({k: v for k, v in res.items() if k != "fingerprints"}, indent=2, ensure_ascii=False)
    print(text)
    print("ERGEBNIS: " + ("Wiederherstellung vollstaendig, Dienst laeuft auf den Daten" if ok else "FEHLGESCHLAGEN"))
    if a.json:
        Path(a.json).write_text(json.dumps(res, indent=2, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

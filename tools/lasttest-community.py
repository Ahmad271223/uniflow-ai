#!/usr/bin/env python3
"""Lasttest der Community-Abfragen (Ansehen einer Loesung, Liken) ohne Netz, mit mehreren Prozessen.

Misst nur die Arbeit des Dienstes (Datenbank, Datei lesen, Antwort bauen), nicht TLS und Leitung. Legt in einem
Wegwerf-Ordner eine eigene Datenbank mit 5000 Mitgliedern und Paketen verschiedener Groesse an und fasst nichts
Echtes an. Aufruf:  python3 tools/lasttest-community.py [ordner]   (Standard: ein neuer Ordner in /tmp)
Ergebnis 02.11.2026 (4 Kerne, Cloud-Rechner): docs/SKALIERUNG-20000.md, Abschnitt 4.
"""
import base64
import json
import multiprocessing as mp
import os
import random
import shutil
import sys
import tempfile
import time
from pathlib import Path

DATA = Path(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="lasttest-community-"))
os.environ["LERNAPP_DATA_DIR"] = str(DATA)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import community  # noqa: E402

KEY = "k" * 64


def setup(n_sol: int, size_bytes: int, n_members: int) -> list[str]:
    sols = []
    with community.cursor() as c:
        now = community._now()
        for i in range(n_members):
            c.execute("INSERT OR IGNORE INTO community_members VALUES (?,?,?,?,?)", (f"u{i}", KEY, "luh", "course", now))
        community.package_dir().mkdir(parents=True, exist_ok=True)
        for i in range(n_sol):
            pkg = community.sample_package("a" * 64, solution_id=f"00000000-0000-4000-8000-{i:012d}", key_material="community-secret")
            pkg["ciphertext"] = base64.b64encode(os.urandom(size_bytes * 3 // 4)).decode()
            raw = json.dumps(pkg, separators=(",", ":"))
            (community.package_dir() / f"{pkg['header']['solutionId']}.uniflowsolution").write_text(raw)
            c.execute("""INSERT INTO solutions(id,fingerprint,university,author_id,pseudonym,display_name,title,created_at,published_at,
                      page_count,pages,size,status,community_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'active',?)""",
                      (pkg["header"]["solutionId"], "a" * 64, "luh", "author", "Pseudo", "x", "t", now, now, 10, 2, len(raw), KEY))
            sols.append(pkg["header"]["solutionId"])
    return sols


def worker(args):
    sols, n, mode, seed = args
    random.seed(seed)
    community._limit = lambda *a, **k: None          # Tageszaehler (accounts.db) gehoeren nicht zu dieser Messung
    ok = err = 0
    lat = []
    for _ in range(n):
        u = {"id": f"u{random.randrange(5000)}", "email_verified": 1}
        s = random.choice(sols)
        t = time.perf_counter()
        try:
            if mode == "view":
                raw, summ = community.get_package_raw(u, s)
                _ = '{"package":' + raw + ',"solution":' + json.dumps(summ) + "}"        # wie community_api.download
            else:
                community.like(u, s, True)
            ok += 1
        except Exception:
            err += 1
        lat.append(time.perf_counter() - t)
    return ok, err, lat


def run(sols, procs, per, mode):
    t = time.perf_counter()
    with mp.Pool(procs) as p:
        res = p.map(worker, [(sols, per, mode, i) for i in range(procs)])
    dt = time.perf_counter() - t
    ok, err = sum(r[0] for r in res), sum(r[1] for r in res)
    lat = sorted(x for r in res for x in r[2])
    print(f"  {mode:5s} Prozesse={procs} ok={ok} Fehler={err} {ok / dt:7.0f}/s  p50={lat[len(lat) // 2] * 1000:6.1f} ms  "
          f"p99={lat[int(len(lat) * .99)] * 1000:7.1f} ms")


if __name__ == "__main__":
    for label, size, n_sol, per in (("klein 0,3 MB", 300_000, 20, 400), ("mittel 3 MB", 3_000_000, 10, 60), ("gross 20 MB", 20_000_000, 3, 8)):
        shutil.rmtree(DATA, ignore_errors=True)
        DATA.mkdir(parents=True)
        sols = setup(n_sol, size, 5000)
        print(label)
        for procs in (1, 4):
            run(sols, procs, per, "view")
        if size == 300_000:
            for procs in (1, 4):
                run(sols, procs, 1000, "like")
    shutil.rmtree(DATA, ignore_errors=True)

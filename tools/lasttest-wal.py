"""Messung Paket 50-54: WAL-Groesse von accounts.db unter Dauerlast (12 Prozesse) und Backup waehrend der Last.

12 Prozesse gleichzeitig fuer --seconds: jeder liest bei jeder Runde eine Sitzung (accounts.authenticate, wie die
Middleware bei jeder /api-Anfrage) und schreibt in jeder --write-every-ten Runde den Weg einer KI-Frage
(credits.reserve + ai_backend.reserve, danach settle - ~4 Schreibtransaktionen). Parallel: Abtaster der -wal-Datei
alle 100 ms; nach der Haelfte ein Backup von accounts.db per SQLite-Backup-API (deploy/backup_snapshot.snapshot_db).

    .venv/bin/python tools/lasttest-wal.py --procs 12 --seconds 120 --users 4000
Ergebnis 08.11.2026: docs/audit/AUDIT-2026-11-08-PAKET-50-54.md. Laeuft auf einem Temp-Ordner, nie auf echten Daten.
"""
from __future__ import annotations

import argparse
import multiprocessing as mp
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def env(tmp: str) -> None:
    os.environ.update({"LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": f"{tmp}/data", "LERNAPP_LOG_DIR": f"{tmp}/logs",
                       "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_AI_BUDGET_EUR": "100000", "LERNAPP_AI_USER_BUDGET_EUR": "100000",
                       "LERNAPP_AI_RATE_PER_MINUTE": "100000000", "LERNAPP_AI_RATE_PER_HOUR": "100000000",
                       "LERNAPP_CREDITS_FREE": "100000000", "LERNAPP_CREDITS_PRO_AI": "100000000"})
    sys.path.insert(0, str(ROOT))


def seed(tmp: str, users: int) -> list[str]:
    env(tmp)
    import secrets
    from app import accounts, ai_backend
    tokens = []
    now = accounts.iso(accounts.now())
    exp = "2099-01-01T00:00:00+00:00"
    with accounts.cursor() as conn:
        for i in range(users):
            uid = f"{i:032x}"
            conn.execute("INSERT INTO users(id, email, university, created_at) VALUES (?,?,?,?)", (uid, f"u{i}@x.de", "luh", now))
            tok = secrets.token_urlsafe(24)
            conn.execute("INSERT INTO sessions(token_hash, user_id, created_at, last_seen_at, expires_at) VALUES (?,?,?,?,?)",
                         (accounts._token_hash(tok), uid, now, now, exp))
            tokens.append(tok)
    c = ai_backend.connect()
    c.close()
    return tokens


def worker(tmp: str, idx: int, tokens: list[str], seconds: float, write_every: int, q) -> None:
    env(tmp)
    from app import accounts, ai_backend, credits
    from app.ai_backend import Completion
    reads = writes = errors = 0
    lat_r, lat_w = [], []
    end = time.monotonic() + seconds
    i = 0
    while time.monotonic() < end:
        i += 1
        tok = tokens[(idx * 7919 + i) % len(tokens)]
        t0 = time.perf_counter()
        try:
            u = accounts.authenticate(tok)
            reads += 1
        except Exception:
            errors += 1
            continue
        lat_r.append(time.perf_counter() - t0)
        if write_every and i % write_every == 0:
            t0 = time.perf_counter()
            try:
                rid = f"r-{idx}-{i}"
                conn = ai_backend.connect()
                try:
                    credits.reserve(conn, u["id"], rid, "tutor:explain", 3, model="gpt-6-luna")
                    log_id = ai_backend.reserve(conn, u["id"], "tutor:explain")
                    cost = ai_backend.settle(conn, log_id, Completion("x", 1500, 220, "gpt-6-luna"), "openai", "gpt-6-luna")
                    credits.settle(conn, u["id"], rid, cost, model="gpt-6-luna", input_tokens=1500, output_tokens=220)
                finally:
                    conn.close()
                writes += 1
                lat_w.append(time.perf_counter() - t0)
            except Exception as e:  # noqa: BLE001
                errors += 1
                if errors < 3:
                    print("Fehler", idx, e, flush=True)
    accounts.flush_seen()
    q.put((reads, writes, errors, lat_r, lat_w))


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] * 1000 if xs else 0.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, default=12)
    ap.add_argument("--users", type=int, default=4000)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--write-every", type=int, default=10)
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        tokens = seed(tmp, a.users)
        from app import accounts
        wal = Path(str(accounts.db_path()) + "-wal")
        q = mp.Queue()
        ps = [mp.Process(target=worker, args=(tmp, i, tokens, a.seconds, a.write_every, q)) for i in range(a.procs)]
        for p in ps:
            p.start()
        sizes = []
        t_start = time.monotonic()
        backup_s = None
        res = []
        while len(res) < len(ps):
            try:
                res.append(q.get(timeout=0.1))
            except Exception:
                pass
            try:
                sizes.append((time.monotonic() - t_start, wal.stat().st_size))
            except OSError:
                pass
            if backup_s is None and not a.no_backup and time.monotonic() - t_start > a.seconds / 2:
                sys.path.insert(0, str(ROOT / "deploy"))
                import backup_snapshot
                t0 = time.perf_counter()
                snap = backup_snapshot.snapshot_db(accounts.db_path(), Path(tmp), 1)
                backup_s = time.perf_counter() - t0
                import sqlite3
                c = sqlite3.connect(snap)
                ok = c.execute("PRAGMA integrity_check").fetchone()[0]
                n = c.execute("SELECT COUNT(*) FROM ai_usage_log").fetchone()[0]
                c.close()
                print(f"Backup waehrend Last: {backup_s * 1000:.0f} ms, integrity_check={ok}, ai_usage_log={n}", flush=True)
        for p in ps:
            p.join()
        reads = sum(r[0] for r in res)
        writes = sum(r[1] for r in res)
        errors = sum(r[2] for r in res)
        lr = [x for r in res for x in r[3]]
        lw = [x for r in res for x in r[4]]
        db_size = accounts.db_path().stat().st_size
        mx = max((s for _, s in sizes), default=0)
        print(f"{a.procs} Prozesse, {a.seconds:.0f} s: {reads} Lesezugriffe ({reads / a.seconds:.0f}/s), {writes} KI-Schreibwege "
              f"({writes / a.seconds:.0f}/s, je 4 Transaktionen), Fehler {errors}")
        print(f"Lesen p50/p95/max {pct(lr, .5):.2f}/{pct(lr, .95):.2f}/{pct(lr, 1):.1f} ms; Schreibweg p50/p95/max "
              f"{pct(lw, .5):.1f}/{pct(lw, .95):.1f}/{pct(lw, 1):.0f} ms")
        print(f"WAL: max {mx / 1e6:.1f} MB, am Ende {sizes[-1][1] / 1e6 if sizes else 0:.1f} MB; accounts.db {db_size / 1e6:.1f} MB")
        buckets = {}
        for t, s in sizes:
            buckets.setdefault(int(t // 5) * 5, []).append(s)
        print("WAL je 5 s (max MB): " + ", ".join(f"{k}s:{max(v) / 1e6:.1f}" for k, v in sorted(buckets.items())))


if __name__ == "__main__":
    main()

"""Mikro-Messung (08.11.2026): wie viele Reservierungen + Abrechnungen je Sekunde traegt accounts.db (SQLite, WAL,
synchronous=NORMAL, laufende Monatssummen) mit 4 Prozessen gleichzeitig - der Schreibweg einer KI-Frage
(app/ai_backend.reserve + settle, dazu app/credits.reserve + settle) ohne Netz und ohne HTTP.

Aufruf:  .venv/bin/python tools/lasttest-ki-ledger.py --procs 4 --per-proc 1000 [--rows 300000]
         --rows: so viele alte Protokollzeilen vorher einfuegen (Monat voll), um den Unterschied zur Summe ueber den
         Monat zu sehen (die alte Pruefung summierte je Anfrage den ganzen Monat).
Laeuft auf einem Temp-Ordner, nie auf echten Daten.
"""
from __future__ import annotations

import argparse
import multiprocessing as mp
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _setup_env(tmp: str) -> None:
    os.environ["LERNAPP_MODE"] = "hosted"
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    os.environ["LERNAPP_NO_SCHEDULER"] = "1"
    os.environ["LERNAPP_AI_PRICE_IN_EUR"] = "0.1"
    os.environ["LERNAPP_AI_PRICE_OUT_EUR"] = "0.5"
    os.environ["LERNAPP_AI_BUDGET_EUR"] = "100000"
    os.environ["LERNAPP_AI_USER_BUDGET_EUR"] = "100000"
    os.environ["LERNAPP_AI_RATE_PER_MINUTE"] = "100000000"
    os.environ["LERNAPP_AI_RATE_PER_HOUR"] = "100000000"
    os.environ["LERNAPP_CREDITS_PRO_AI"] = "100000000"
    os.environ["LERNAPP_CREDITS_FREE"] = "100000000"          # die Messkonten haben keinen Tarif: Credits wie Free
    sys.path.insert(0, str(ROOT))


def worker(tmp: str, idx: int, n: int, q) -> None:
    _setup_env(tmp)
    from app import ai_backend, credits
    from app.ai_backend import Completion
    lat = []
    uid = f"user-{idx}"
    t_all = time.perf_counter()
    for i in range(n):
        rid = f"r-{idx}-{i}"
        t0 = time.perf_counter()
        conn = ai_backend.connect()
        try:
            credits.reserve(conn, uid, rid, "tutor:explain", 3, model="gpt-6-luna")
            log_id = ai_backend.reserve(conn, uid, "tutor:explain")
        finally:
            conn.close()
        t1 = time.perf_counter()
        conn = ai_backend.connect()
        try:
            c = Completion("Antwort", 1500, 220, "gpt-6-luna")
            cost = ai_backend.settle(conn, log_id, c, "openai", "gpt-6-luna")
            credits.settle(conn, uid, rid, cost, model=c.model, input_tokens=1500, output_tokens=220)
        finally:
            conn.close()
        t2 = time.perf_counter()
        lat.append((t1 - t0, t2 - t1))
    q.put((idx, time.perf_counter() - t_all, lat))


def seed_rows(tmp: str, rows: int) -> None:
    _setup_env(tmp)
    from app import ai_backend
    conn = ai_backend.connect()
    try:
        period = ai_backend._now().strftime("%Y-%m")
        conn.execute("BEGIN")
        conn.executemany("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) VALUES (?,?,?,?,0,0,'done',?)",
                         ((f"alt-{i % 500}", period, "tutor:explain", 900, "2026-11-01T00:00:00") for i in range(rows)))
        conn.execute("COMMIT")
        # wie im Betrieb nach einem ruhigen Moment: das WAL der Einfuegung ist in die Datei uebernommen (sonst misst der
        # erste Lauf den Checkpoint von 300k Zeilen, nicht die Reservierungen)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        t0 = time.perf_counter()
        old = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed' AND trial=0 AND library=0",
                           (period,)).fetchone()[0]
        t_sum = time.perf_counter() - t0
        t0 = time.perf_counter()
        new = ai_backend._pool_total(conn, period, "paid")
        t_tot = time.perf_counter() - t0
        print(f"{rows} Zeilen im Monat: Summe ueber den Monat {t_sum * 1000:.1f} ms, laufende Summe {t_tot * 1000:.3f} ms "
              f"(gleich: {old == new})", flush=True)
    finally:
        conn.close()


def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))] if xs else 0.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, default=4)
    ap.add_argument("--per-proc", type=int, default=1000)
    ap.add_argument("--rows", type=int, default=0)
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lasttest-ledger-")
    try:
        _setup_env(tmp)
        from app import ai_backend
        ai_backend.connect().close()                 # Schema anlegen
        if a.rows:
            seed_rows(tmp, a.rows)
        ctx = mp.get_context("spawn")
        q = ctx.Queue()
        procs = [ctx.Process(target=worker, args=(tmp, i, a.per_proc, q)) for i in range(a.procs)]
        t0 = time.perf_counter()
        for p in procs:
            p.start()
        results = []
        for _ in procs:
            results.append(q.get(timeout=600))
        for p in procs:
            p.join()
        wall = time.perf_counter() - t0
        res = [x for r in results for x in r[2]]
        n = len(res)
        print(f"{a.procs} Prozesse x {a.per_proc} KI-Fragen = {n} Fragen, je 2 Schreibschritte (Reservierung Credits+Budget, "
              f"Abrechnung Credits+Protokoll) = {2 * n} Transaktionsgruppen in {wall:.1f} s")
        print(f"  -> {n / wall:.0f} Fragen/s, {2 * n / wall:.0f} Schreibgruppen/s (je Gruppe 2 Transaktionen = {4 * n / wall:.0f} Transaktionen/s)")
        print(f"  Reservierung p50 {pct([r for r, _ in res], 50) * 1000:.1f} ms, p95 {pct([r for r, _ in res], 95) * 1000:.1f} ms, "
              f"max {max(r for r, _ in res) * 1000:.0f} ms")
        print(f"  Abrechnung   p50 {pct([s for _, s in res], 50) * 1000:.1f} ms, p95 {pct([s for _, s in res], 95) * 1000:.1f} ms, "
              f"max {max(s for _, s in res) * 1000:.0f} ms")
        conn = ai_backend.connect()
        try:
            print(f"  Monatssummen stimmen mit dem Protokoll ueberein: {ai_backend.month_totals_match_log(conn)}")
        finally:
            conn.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

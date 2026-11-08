"""Messung P51-07: ein Zeitfenster (weekly-Job je aktivem Konto) mit echtem jobs.run_job, 4 Arbeiter-Threads wie
LERNAPP_JOB_WORKERS=4, Konten ohne Inhalte (iPad-Konten: Dateien liegen auf dem Geraet). Zweiter Lauf = zweites
Fenster am selben Tag (Konto-DBs existieren schon). Danach retention.run ueber alle Kontoordner.

    .venv/bin/python tools/lasttest-jobs.py 400
Ergebnis 08.11.2026: docs/audit/AUDIT-2026-11-08-PAKET-50-54.md. Laeuft auf einem Temp-Ordner, nie auf echten Daten."""
import os
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

N = int(sys.argv[1]) if len(sys.argv) > 1 else 400
tmp = tempfile.mkdtemp()
os.environ.update({"LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": f"{tmp}/data", "LERNAPP_LOG_DIR": f"{tmp}/logs",
                   "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_JOBS": "off"})
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import accounts, config, jobs  # noqa: E402

config.MODE = "hosted"
now = accounts.iso(accounts.now())
with accounts.cursor() as conn:
    conn.executemany("INSERT INTO users(id, email, university, created_at) VALUES (?,?,?,?)",
                     [(f"{i:032x}", f"j{i}@x.de", "luh", now) for i in range(N)])


def window(hour: int) -> float:
    n = jobs.schedule_due(now=datetime(2026, 11, 9, hour, 1), times=[f"{hour:02d}:00"])
    assert n == N, n
    t0 = time.perf_counter()

    def worker():
        while jobs.work_once():
            pass
    ts = [threading.Thread(target=worker) for _ in range(4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return time.perf_counter() - t0


for label, hour in (("erstes Fenster (Konto-DBs neu)", 8), ("zweites Fenster", 15)):
    dt = window(hour)
    with accounts.cursor() as conn:
        bad = conn.execute("SELECT status, message FROM sync_jobs WHERE status!='done' LIMIT 3").fetchall()
    print(f"{label}: {N} Jobs in {dt:.1f} s = {dt / N * 1000:.0f} ms je Job; nicht 'done': {[tuple(b) for b in bad]}; "
          f"hochgerechnet auf 4.000 Konten {dt / N * 4000 / 60:.1f} min")
from app import retention  # noqa: E402
t0 = time.perf_counter()
res = retention.run()
print(f"retention.run ueber {N} Kontoordner: {time.perf_counter() - t0:.2f} s -> hochgerechnet 4.000: "
      f"{(time.perf_counter() - t0) / N * 4000:.1f} s")

#!/usr/bin/env python
"""Lasttest des gehosteten Dienstes (LERNAPP_MODE=hosted) ohne echten Server: in-process gegen die FastAPI-App.

Misst mit einem eigenen Temp-Datenordner (nie data/):
  1. Konten registrieren (POST /api/account/register), Tarife verteilen (Probe / Plus / Free)
  2. Dateien je Konto in der Konto-Datenbank anlegen
  3. Lese-Anfragen je Konto mit Sitzungstoken (me, entitlements, modules, files, dashboard, billing/plans)
  4. Notizen schreiben (PUT /api/files/{id}/annotations): Plus = 200, Free = 403 plan_required
  5. Jobs: weekly je Konto anlegen und abarbeiten (echtes weekly.tick), danach jobs.schedule_due
  6. Gleichzeitigkeit: N Threads mit Lese-Anfragen fuer verschiedene Konten, "database is locked" zaehlen
  7. Groesse: accounts.db, Summe der Konto-Datenbanken, RSS des Prozesses

Aufruf im Projektordner:  .venv/bin/python tools/lasttest-dienst.py [--accounts 100] [--files 10] [--threads 8]
                           [--reads-per-thread 50] [--budget 540] [--out ergebnis.json] [--keep]
Nur Standardbibliothek + requirements.txt. Laeuft auf dem Mac und in der Cloud. Zeiten mit time.perf_counter.
Ergebnisse: docs/LASTTEST-DIENST-2026-10-30.md
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import resource
import shutil
import statistics
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------- Umgebung (vor dem Import von `app`, wie tests/conftest.py)

TMP = tempfile.mkdtemp(prefix="lernapp-lasttest-")
os.environ["LERNAPP_DATA_DIR"] = str(Path(TMP) / "data")
os.environ["LERNAPP_LOG_DIR"] = str(Path(TMP) / "logs")
os.environ["LERNAPP_ENV_FILE"] = str(Path(TMP) / ".env")        # die .env des Projekts bleibt aussen vor
os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
os.environ["LERNAPP_NO_SCHEDULER"] = "1"
os.environ["LERNAPP_MODE"] = "hosted"
os.environ["LERNAPP_JOBS"] = "off"
os.environ.setdefault("LERNAPP_MAIL", "log")                    # Willkommensmail nur ins Protokoll
sys.path.insert(0, str(ROOT))

PASSWORD = "sehr-geheim-123"
READ_PATHS = ("/api/account/me", "/api/entitlements", "/api/modules", "/api/files", "/api/dashboard", "/api/billing/plans")
NOTE_BODY = json.dumps({"version": 2, "pages": {"1": {"objects": [{"id": "s1", "type": "text", "text": "Notiz aus dem Lasttest"}]}}})


def asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, headers=None, host="test",
              content_type="application/json"):
    """Minimaler ASGI-Aufruf ohne httpx (Kopie von tests/conftest.py); liefert (status, headers, body_bytes)."""
    from urllib.parse import unquote
    p, _, q = path.partition("?")
    hdrs = [(b"host", host.encode()), (b"content-type", content_type.encode())]
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    raw = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else b"")
    hdrs.append((b"content-length", str(len(raw)).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": method,
             "scheme": "http", "path": unquote(p), "raw_path": p.encode(), "query_string": q.encode(), "headers": hdrs,
             "client": client, "server": ("test", 80)}
    out = {"status": None, "headers": [], "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]; out["headers"] = m["headers"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")

    asyncio.run(app(scope, receive, send))
    return out["status"], out["headers"], out["body"]


# ---------------------------------------------------------------- Statistik und Ausgabe

def ms(x: float) -> float:
    return round(x * 1000, 1)


def stats(samples: list[float]) -> dict:
    if not samples:
        return {"n": 0, "median_ms": None, "p95_ms": None, "max_ms": None, "total_s": 0.0}
    s = sorted(samples)
    return {"n": len(s), "median_ms": ms(statistics.median(s)), "p95_ms": ms(s[int(0.95 * (len(s) - 1))]),
            "max_ms": ms(s[-1]), "total_s": round(sum(s), 2)}


def table(headers: list[str], rows: list[list]) -> str:
    cells = [[str(h) for h in headers]] + [["" if c is None else str(c) for c in r] for r in rows]
    w = [max(len(r[i]) for r in cells) for i in range(len(headers))]
    line = lambda r: "| " + " | ".join(c.ljust(w[i]) for i, c in enumerate(r)) + " |"   # noqa: E731
    return "\n".join([line(cells[0]), "|" + "|".join("-" * (x + 2) for x in w) + "|"] + [line(r) for r in cells[1:]])


def say(msg: str) -> None:
    print(msg, flush=True)


def rss_mb() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(r / (1024 * 1024) if sys.platform == "darwin" else r / 1024, 1)   # Mac: Byte, Linux: KB


def file_size(p: Path) -> int:
    total = 0
    for suffix in ("", "-wal", "-shm"):
        q = p.with_name(p.name + suffix)
        if q.exists():
            total += q.stat().st_size
    return total


# ---------------------------------------------------------------- Lauf

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--accounts", type=int, default=100)
    ap.add_argument("--files", type=int, default=10, help="Dateien je Konto")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--reads-per-thread", type=int, default=50)
    ap.add_argument("--budget", type=float, default=540.0, help="Zeitbudget in Sekunden (Standard 9 Minuten)")
    ap.add_argument("--out", help="Ergebnis zusaetzlich als JSON in diese Datei schreiben")
    ap.add_argument("--keep", action="store_true", help="Temp-Datenordner nicht loeschen")
    a = ap.parse_args()
    t_start = time.perf_counter()
    notes: list[str] = []
    res: dict = {"start": datetime.now().isoformat(timespec="seconds"), "python": sys.version.split()[0], "platform": sys.platform,
                 "cpus": os.cpu_count(), "tmp": TMP, "args": vars(a)}

    def remaining() -> float:
        return a.budget - (time.perf_counter() - t_start)

    t0 = time.perf_counter()
    from app import accounts, config, db, jobs                     # noqa: E402
    from app.server import app                                       # noqa: E402
    import sqlite3
    assert config.is_hosted() and str(config.BASE_DATA_DIR).startswith(TMP), "falsche Umgebung"
    res["import_s"] = round(time.perf_counter() - t0, 2)
    res["sqlite"] = sqlite3.sqlite_version
    say(f"Umgebung: {TMP}  (Python {res['python']}, SQLite {res['sqlite']}, {res['cpus']} CPUs, App-Import {res['import_s']} s)")

    # Grundlast des Aufrufwegs: oeffentlicher Pfad ohne Datenbank, zeigt den Anteil von asyncio.run + Middleware
    base = []
    for _ in range(50):
        t = time.perf_counter(); st, _, _ = asgi_call(app, "GET", "/api/account/info"); base.append(time.perf_counter() - t)
        assert st == 200
    res["baseline_info"] = stats(base)

    # ------------------------------------------------------------ 1. Konten
    say(f"\n1. {a.accounts} Konten registrieren ...")
    users: list[dict] = []           # {id, email, token, headers, group, university}
    t_reg, errs_reg = [], 0
    for i in range(a.accounts):
        ip = f"10.{(i // 65536) % 256}.{(i // 256) % 256}.{i % 256 or 1}"        # je Konto eine andere Adresse (Grenze register_ip 30/h)
        uni = "luh" if i % 4 else "hildesheim"
        body = json.dumps({"email": f"last{i:05d}@beispiel.de", "password": PASSWORD, "university": uni})
        t = time.perf_counter()
        st, _, b = asgi_call(app, "POST", "/api/account/register", client=(ip, 5000), body=body)
        t_reg.append(time.perf_counter() - t)
        if st != 201:
            errs_reg += 1
            say(f"   Registrierung {i}: Status {st} {b[:200]!r}")
            continue
        d = json.loads(b)
        users.append({"id": d["user"]["id"], "email": d["user"]["email"], "token": d["token"], "university": uni,
                      "headers": {"Authorization": f"Bearer {d['token']}"}})
    n = len(users)
    n_trial, n_plus = n // 2, int(n * 0.3)
    groups = ["trial"] * n_trial + ["plus"] * n_plus + ["free"] * (n - n_trial - n_plus)
    t = time.perf_counter()
    for u, g in zip(users, groups):
        u["group"] = g
        if g != "trial":
            accounts.end_trial(u["id"])
        if g == "plus":
            accounts.set_plan(u["id"], "plus")
    res["register"] = {**stats(t_reg), "errors": errs_reg, "accounts": n, "groups": {g: groups.count(g) for g in ("trial", "plus", "free")},
                       "plan_setup_s": round(time.perf_counter() - t, 2)}
    say(f"   {n} Konten, Median {res['register']['median_ms']} ms, p95 {res['register']['p95_ms']} ms, gesamt {res['register']['total_s']} s, "
        f"Tarife setzen {res['register']['plan_setup_s']} s")

    # ------------------------------------------------------------ 2. Dateien je Konto
    say(f"\n2. {a.files} Dateien je Konto anlegen ...")
    t_init, t_ins = [], []
    for u in users:
        ctx = config.set_user_context(u["id"], u["university"])
        try:
            t = time.perf_counter(); db.init_db(); t_init.append(time.perf_counter() - t)
            t = time.perf_counter()
            with db.cursor() as conn:
                conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', 1, '2026-10-26')")
                for k in range(a.files):
                    conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, chdate, size) VALUES (?, 'c1', ?, 'pdf', 'neu', ?, ?)",
                                 (f"f{k + 1}", f"Blatt {k + 1}.pdf", 1760000000 + k * 86400, 200_000 + k))
            t_ins.append(time.perf_counter() - t)
        finally:
            config.reset_user_context(ctx)
    res["files"] = {"per_account": a.files, "total": n * a.files, "init_db": stats(t_init), "insert": stats(t_ins),
                    "total_s": round(sum(t_init) + sum(t_ins), 2)}
    say(f"   {n * a.files} Dateien; init_db je Konto Median {res['files']['init_db']['median_ms']} ms, Einfuegen Median "
        f"{res['files']['insert']['median_ms']} ms, gesamt {res['files']['total_s']} s")

    # ------------------------------------------------------------ 3. Lese-Anfragen
    say(f"\n3. Lese-Anfragen: {n} Konten x {len(READ_PATHS)} Pfade ...")
    per_path: dict[str, list[float]] = {p: [] for p in READ_PATHS}
    read_errors: dict[str, int] = {}
    first_me: list[float] = []
    for u in users:
        for p in READ_PATHS:
            t = time.perf_counter()
            st, _, b = asgi_call(app, "GET", p, headers=u["headers"])
            dt = time.perf_counter() - t
            per_path[p].append(dt)
            if p == "/api/account/me":
                first_me.append(dt)
            if st != 200:
                read_errors[f"{p} -> {st}"] = read_errors.get(f"{p} -> {st}", 0) + 1
            elif p == "/api/files" and len(json.loads(b)) != a.files:
                read_errors[f"{p} -> falsche Anzahl"] = read_errors.get(f"{p} -> falsche Anzahl", 0) + 1
    all_reads = [x for v in per_path.values() for x in v]
    res["reads"] = {"all": stats(all_reads), "per_path": {p: stats(v) for p, v in per_path.items()}, "errors": read_errors,
                    "error_rate": round(sum(read_errors.values()) / max(1, len(all_reads)), 4),
                    "note": "/api/account/me ist je Konto die erste Anfrage: enthaelt db.init_db() aus hosted_guard"}
    say(f"   {len(all_reads)} Anfragen, Median {res['reads']['all']['median_ms']} ms, p95 {res['reads']['all']['p95_ms']} ms, "
        f"Fehler {sum(read_errors.values())} ({res['reads']['error_rate'] * 100:.1f} %)")
    for p in READ_PATHS:
        s = res["reads"]["per_path"][p]
        say(f"   {p:<24} Median {s['median_ms']:>7} ms   p95 {s['p95_ms']:>7} ms   max {s['max_ms']:>7} ms")

    # ------------------------------------------------------------ 4. Notizen
    say("\n4. Notizen schreiben (PUT /api/files/{id}/annotations) ...")
    t_notes_plus, t_notes_trial, t_notes_free = [], [], []
    note_status: dict[str, dict[int, int]] = {"plus": {}, "trial": {}, "free": {}}
    free_plan_required = 0
    for u in users:
        g = u["group"]
        for k in range(a.files):
            t = time.perf_counter()
            st, _, b = asgi_call(app, "PUT", f"/api/files/f{k + 1}/annotations", headers=u["headers"], body=NOTE_BODY)
            dt = time.perf_counter() - t
            {"plus": t_notes_plus, "trial": t_notes_trial, "free": t_notes_free}[g].append(dt)
            note_status[g][st] = note_status[g].get(st, 0) + 1
            if g == "free" and st == 403 and json.loads(b).get("code") == "plan_required":
                free_plan_required += 1
    res["notes"] = {"plus": {**stats(t_notes_plus), "status": note_status["plus"]},
                    "trial": {**stats(t_notes_trial), "status": note_status["trial"]},
                    "free": {**stats(t_notes_free), "status": note_status["free"], "plan_required": free_plan_required}}
    say(f"   Plus:  {len(t_notes_plus)} Schreibvorgaenge, Median {res['notes']['plus']['median_ms']} ms, p95 {res['notes']['plus']['p95_ms']} ms, Status {note_status['plus']}")
    say(f"   Probe: {len(t_notes_trial)} Schreibvorgaenge, Median {res['notes']['trial']['median_ms']} ms, p95 {res['notes']['trial']['p95_ms']} ms, Status {note_status['trial']}")
    say(f"   Free:  {len(t_notes_free)} Versuche, davon 403 plan_required: {free_plan_required}, Status {note_status['free']}, Median {res['notes']['free']['median_ms']} ms")

    # ------------------------------------------------------------ 5. Jobs
    say("\n5. Jobs: weekly je Konto anlegen und abarbeiten (echtes weekly.tick) ...")
    t = time.perf_counter()
    for u in users:
        jobs.enqueue(u["id"], "weekly", "scheduled")
    enqueue_s = time.perf_counter() - t
    t_job, done, stopped = [], 0, False
    t = time.perf_counter()
    while True:
        if remaining() < 120:
            stopped = True
            break
        t1 = time.perf_counter()
        if not jobs.work_once():
            break
        t_job.append(time.perf_counter() - t1)
        done += 1
    work_s = time.perf_counter() - t
    if stopped:
        notes.append(f"Punkt 5: Zeitbudget knapp, nach {done} von {n} Jobs abgebrochen.")
    cm, conn = jobs._conn()
    try:
        job_states = {r[0]: r[1] for r in conn.execute("SELECT status, COUNT(*) FROM sync_jobs GROUP BY status")}
        job_fail_msgs = [r[0] for r in conn.execute("SELECT DISTINCT message FROM sync_jobs WHERE status='failed' LIMIT 5")]
    finally:
        cm.__exit__(None, None, None)
    # Zeitfenster: fuer alle Konten (keine Zugangsdaten) einen weekly-Job anlegen
    t = time.perf_counter()
    scheduled = jobs.schedule_due(datetime(2026, 10, 30, 9, 0), times=["08:00"])
    schedule_s = time.perf_counter() - t
    t = time.perf_counter()
    scheduled_again = jobs.schedule_due(datetime(2026, 10, 30, 9, 5), times=["08:00"])      # Fenster schon bearbeitet: 0
    schedule_again_s = time.perf_counter() - t
    res["jobs"] = {"enqueued": n, "enqueue_s": round(enqueue_s, 2), "enqueue_per_job_ms": ms(enqueue_s / max(1, n)),
                   "worked": done, "work_s": round(work_s, 2), "jobs_per_s": round(done / work_s, 1) if work_s else None,
                   "per_job": stats(t_job), "states": job_states, "failed_messages": job_fail_msgs, "stopped_early": stopped,
                   "schedule_due_created": scheduled, "schedule_due_s": round(schedule_s, 2),
                   "schedule_due_per_account_ms": ms(schedule_s / max(1, n)),
                   "schedule_due_repeat_created": scheduled_again, "schedule_due_repeat_s": round(schedule_again_s, 3)}
    say(f"   enqueue {n}: {res['jobs']['enqueue_s']} s ({res['jobs']['enqueue_per_job_ms']} ms je Job); work_once {done} Jobs in {res['jobs']['work_s']} s "
        f"= {res['jobs']['jobs_per_s']} Jobs/s, je Job Median {res['jobs']['per_job']['median_ms']} ms, p95 {res['jobs']['per_job']['p95_ms']} ms")
    say(f"   Stand: {job_states}; schedule_due fuer {n} Konten: {scheduled} Jobs in {res['jobs']['schedule_due_s']} s; "
        f"zweiter Aufruf gleiches Fenster: {scheduled_again} in {res['jobs']['schedule_due_repeat_s']} s")
    if job_fail_msgs:
        say(f"   Fehlgeschlagen: {job_fail_msgs}")

    # ------------------------------------------------------------ 6. Gleichzeitigkeit
    reads_per_thread = a.reads_per_thread
    med_read = (res["reads"]["all"]["median_ms"] or 10) / 1000
    est = a.threads * reads_per_thread * med_read              # GIL: die Threads teilen sich einen Kern
    if est > remaining() * 0.6:
        reads_per_thread = max(5, int(remaining() * 0.6 / (a.threads * med_read)))
        notes.append(f"Punkt 6: Zeitbudget knapp, {reads_per_thread} statt {a.reads_per_thread} Anfragen je Thread.")
    say(f"\n6. Gleichzeitigkeit: {a.threads} Threads x {reads_per_thread} Lese-Anfragen ...")
    lock = threading.Lock()
    conc: dict = {"lat": [], "status": {}, "exceptions": {}, "locked": 0, "per_path": {p: [] for p in READ_PATHS}}

    def worker(tid: int) -> None:
        for k in range(reads_per_thread):
            u = users[(tid * 7919 + k * 13) % n]                  # verschiedene Konten je Thread
            p = READ_PATHS[(tid + k) % len(READ_PATHS)]
            t1 = time.perf_counter()
            try:
                st, _, _ = asgi_call(app, "GET", p, headers=u["headers"])
                err = None
            except Exception as e:  # noqa: BLE001 - ein Fehler im Endpunkt kommt hier als Ausnahme an (500)
                st, err = 500, f"{type(e).__name__}: {e}"[:160]
            dt = time.perf_counter() - t1
            with lock:
                conc["lat"].append(dt); conc["per_path"][p].append(dt)
                conc["status"][st] = conc["status"].get(st, 0) + 1
                if err:
                    conc["exceptions"][err] = conc["exceptions"].get(err, 0) + 1
                    if "locked" in err:
                        conc["locked"] += 1

    ths = [threading.Thread(target=worker, args=(i,), name=f"last-{i}") for i in range(a.threads)]
    t = time.perf_counter()
    [x.start() for x in ths]; [x.join() for x in ths]
    conc_s = time.perf_counter() - t
    total_c = len(conc["lat"])
    errors_c = sum(v for k, v in conc["status"].items() if k != 200)
    res["concurrency"] = {"threads": a.threads, "reads_per_thread": reads_per_thread, "requests": total_c, "wall_s": round(conc_s, 2),
                          "req_per_s": round(total_c / conc_s, 1) if conc_s else None, "lat": stats(conc["lat"]),
                          "per_path": {p: stats(v) for p, v in conc["per_path"].items()},
                          "status": conc["status"], "errors": errors_c, "error_rate": round(errors_c / max(1, total_c), 4),
                          "exceptions": conc["exceptions"], "database_locked": conc["locked"]}
    say(f"   {total_c} Anfragen in {res['concurrency']['wall_s']} s = {res['concurrency']['req_per_s']} Anfragen/s; Median {res['concurrency']['lat']['median_ms']} ms, "
        f"p95 {res['concurrency']['lat']['p95_ms']} ms; Fehler {errors_c} ({res['concurrency']['error_rate'] * 100:.1f} %), "
        f"'database is locked': {conc['locked']}")
    if conc["exceptions"]:
        say(f"   Ausnahmen: {conc['exceptions']}")

    # Protokolle nach "database is locked" durchsuchen (SQLite-Fehler, die ein Endpunkt selbst abgefangen hat)
    locked_in_logs = 0
    for root in (Path(os.environ["LERNAPP_LOG_DIR"]), config.BASE_DATA_DIR):
        for f in root.rglob("*.log"):
            try:
                locked_in_logs += f.read_text(encoding="utf-8", errors="replace").count("database is locked")
            except OSError:
                pass
    res["concurrency"]["database_locked_in_logs"] = locked_in_logs

    # ------------------------------------------------------------ 7. Groesse
    acc = file_size(accounts.db_path())
    user_dbs = [file_size(p) for p in (config.BASE_DATA_DIR / "users").rglob("lernapp.db")]   # luh: users/<id>/, sonst users/<id>/unis/<uni>/
    total_tree = sum(f.stat().st_size for f in config.BASE_DATA_DIR.rglob("*") if f.is_file())
    with accounts.cursor() as conn:
        counts = {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                  for t in ("users", "sessions", "entitlements", "sync_jobs", "rate_limits", "verify_tokens")}
    res["size"] = {"accounts_db_bytes": acc, "accounts_db_kb": round(acc / 1024, 1), "accounts_rows": counts,
                   "user_dbs": len(user_dbs), "user_dbs_total_mb": round(sum(user_dbs) / 1024 / 1024, 2),
                   "user_db_each_kb": round(statistics.median(user_dbs) / 1024, 1) if user_dbs else None,
                   "data_dir_total_mb": round(total_tree / 1024 / 1024, 2), "rss_max_mb": rss_mb()}
    say(f"\n7. Groesse: accounts.db {res['size']['accounts_db_kb']} KB ({counts}); {len(user_dbs)} Konto-Datenbanken "
        f"zusammen {res['size']['user_dbs_total_mb']} MB (je {res['size']['user_db_each_kb']} KB); Datenordner {res['size']['data_dir_total_mb']} MB; "
        f"RSS max {res['size']['rss_max_mb']} MB")

    res["total_s"] = round(time.perf_counter() - t_start, 1)
    res["hinweise"] = notes

    # ------------------------------------------------------------ Tabelle
    say("\n" + "=" * 100)
    say(f"Lasttest Dienst (hosted, in-process) – {n} Konten, {n * a.files} Dateien, Gesamtlaufzeit {res['total_s']} s, RSS {res['size']['rss_max_mb']} MB")
    rows = [
        ["Grundlast GET /api/account/info (ohne DB)", 50, res["baseline_info"]["median_ms"], res["baseline_info"]["p95_ms"], res["baseline_info"]["total_s"], ""],
        ["1 Registrieren (POST register)", n, res["register"]["median_ms"], res["register"]["p95_ms"], res["register"]["total_s"], f"{errs_reg} Fehler; Tarife {res['register']['plan_setup_s']} s"],
        ["2 init_db je Konto", n, res["files"]["init_db"]["median_ms"], res["files"]["init_db"]["p95_ms"], res["files"]["init_db"]["total_s"], ""],
        [f"2 {a.files} Dateien einfuegen je Konto", n, res["files"]["insert"]["median_ms"], res["files"]["insert"]["p95_ms"], res["files"]["insert"]["total_s"], f"{n * a.files} Dateien"],
        ["3 Lesen gesamt", len(all_reads), res["reads"]["all"]["median_ms"], res["reads"]["all"]["p95_ms"], res["reads"]["all"]["total_s"], f"Fehler {sum(read_errors.values())} ({res['reads']['error_rate'] * 100:.1f} %)"],
    ]
    for p in READ_PATHS:
        s = res["reads"]["per_path"][p]
        rows.append([f"3   GET {p}", s["n"], s["median_ms"], s["p95_ms"], s["total_s"], ""])
    rows += [
        ["4 Notizen Plus (PUT annotations)", len(t_notes_plus), res["notes"]["plus"]["median_ms"], res["notes"]["plus"]["p95_ms"], res["notes"]["plus"]["total_s"], f"Status {note_status['plus']}"],
        ["4 Notizen Probe (Zusatz)", len(t_notes_trial), res["notes"]["trial"]["median_ms"], res["notes"]["trial"]["p95_ms"], res["notes"]["trial"]["total_s"], f"Status {note_status['trial']}"],
        ["4 Notizen Free (erwartet 403)", len(t_notes_free), res["notes"]["free"]["median_ms"], res["notes"]["free"]["p95_ms"], res["notes"]["free"]["total_s"], f"403 plan_required: {free_plan_required}"],
        ["5 jobs.enqueue weekly", n, res["jobs"]["enqueue_per_job_ms"], "", res["jobs"]["enqueue_s"], ""],
        ["5 jobs.work_once (weekly.tick echt)", done, res["jobs"]["per_job"]["median_ms"], res["jobs"]["per_job"]["p95_ms"], res["jobs"]["work_s"], f"{res['jobs']['jobs_per_s']} Jobs/s; {job_states}"],
        ["5 jobs.schedule_due (1 Fenster)", scheduled, res["jobs"]["schedule_due_per_account_ms"], "", res["jobs"]["schedule_due_s"], f"zweiter Aufruf: {scheduled_again} in {res['jobs']['schedule_due_repeat_s']} s"],
        [f"6 Gleichzeitig {a.threads} Threads", total_c, res["concurrency"]["lat"]["median_ms"], res["concurrency"]["lat"]["p95_ms"], res["concurrency"]["wall_s"],
         f"{res['concurrency']['req_per_s']} Anfr./s; Fehler {errors_c}; locked {conc['locked']} (+{locked_in_logs} im Log)"],
    ]
    say(table(["Schritt", "Anzahl", "Median ms", "p95 ms", "Gesamt s", "Bemerkung"], rows))
    say("")
    say(table(["Groesse", "Wert"], [
        ["accounts.db (mit WAL)", f"{res['size']['accounts_db_kb']} KB"],
        ["Zeilen accounts.db", json.dumps(counts)],
        ["Konto-Datenbanken", f"{len(user_dbs)} Stueck, zusammen {res['size']['user_dbs_total_mb']} MB, je {res['size']['user_db_each_kb']} KB"],
        ["Datenordner gesamt", f"{res['size']['data_dir_total_mb']} MB"],
        ["RSS (ru_maxrss)", f"{res['size']['rss_max_mb']} MB"],
    ]))
    for x in notes:
        say(f"Hinweis: {x}")

    if a.out:
        Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
        say(f"\nJSON: {a.out}")
    if a.keep:
        say(f"Datenordner bleibt: {TMP}")
    else:
        shutil.rmtree(TMP, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

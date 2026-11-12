#!/usr/bin/env python
"""Lasttest Smart Planner 2.0 (Auftrag des Inhabers vom 12.11.2026, Pflichtpunkt 10): belegen statt behaupten.

Teil A – Rechenkern (app/smart_planner.py, dieselbe Rechnung wie im iPad-Kern): N erfundene Nutzer (Vorgabe 100.000)
mit 2-6 Modulen, Stundenplan, Schlaf/Freizeit, Verpflichtungen und 6-20 Wochen bis zur letzten Klausur; je Nutzer ein
vollstaendiger Plan auf allen Kernen. Gemessen: Zeit je Plan (Median, p95, p99, max), Durchsatz, Fehler (muss 0 sein),
harte Bedingungen an jedem 50. Plan (nie nach der Klausur, nur in freien Fenstern, keine Ueberschneidung, Tagesbudget).

Teil B – Dienst (LERNAPP_MODE=hosted, in-process gegen die FastAPI-App, eigene Datenbank je Konto): K Konten mit je drei
Lernzielen, dann T Threads gleichzeitig mit gemischten Anfragen (Uebersicht mit Neuplanung, Stoppuhr, Zeit eintragen,
Ziel aendern, dieselbe Uebersicht doppelt gleichzeitig). Gemessen: Status, 5xx, "database is locked", Latenz, danach
in jeder Konto-Datenbank keine doppelten Bloecke.

Hochrechnung auf 100.000 gleichzeitige Nutzer: aus der gemessenen CPU-Zeit je Anfrage (Teil B) und je Plan (Teil A) mit
offen genannten Annahmen zur Anfragerate. Das ist eine Rechnung auf Messwerten, kein Lauf mit 100.000 Verbindungen.

Aufruf im Projektordner: .venv/bin/python tools/lasttest-smart-planner.py [--users 100000] [--accounts 200] [--threads 32]
                          [--ops 4000] [--out ergebnis.json]
"""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import random
import resource
import statistics
import sys
import tempfile
import threading
import time
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def pct(xs: list[float], p: float) -> float:
    s = sorted(xs)
    return round(s[min(len(s) - 1, int(p * (len(s) - 1)))] * 1000, 2) if s else 0.0


def summary(xs: list[float]) -> dict:
    if not xs:
        return {"n": 0}
    return {"n": len(xs), "median_ms": round(statistics.median(xs) * 1000, 2), "p95_ms": pct(xs, 0.95), "p99_ms": pct(xs, 0.99),
            "max_ms": round(max(xs) * 1000, 2), "cpu_s": round(sum(xs), 2)}


def rss_mb() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(r / (1024 * 1024) if sys.platform == "darwin" else r / 1024, 1)


# ------------------------------------------------------------------ Teil A

def synth_user(seed: int) -> dict:
    """Ein erfundener Nutzer: Stundenplan, Schlaf, Freizeit, Verpflichtungen, Module mit Zielen und Klausuren"""
    from app import smart_planner as sp
    rnd = random.Random(seed)
    start = date(2026, 11, 16) + timedelta(days=rnd.randint(0, 6))
    weeks = rnd.randint(6, 20)
    n = weeks * 7 + 42
    lectures = [(rnd.randint(0, 4), rnd.choice([480, 600, 720, 840]), rnd.choice([90, 120])) for _ in range(rnd.randint(4, 14))]
    dates = []
    for i in range(n):
        d = start + timedelta(days=i)
        busy = [[a, a + l] for wd, a, l in lectures if wd == d.weekday() and i < weeks * 7]
        dates.append({"date": d.isoformat(), "weekday": d.weekday(), "busy": busy})
    settings = {"sleep_minutes": rnd.choice([480, 540, 600]), "bedtime": rnd.choice([1320, 1380, 1440 - 30]),
                "leisure_minutes": rnd.choice([60, 120, 180]), "learn_days": sorted(rnd.sample(range(7), rnd.randint(5, 7))),
                "commitments": [{"weekday": rnd.randint(0, 6), "start": 960, "end": 1200}] if rnd.random() < 0.4 else []}
    days = sp.build_days(dates, settings)
    mods = []
    for k in range(rnd.randint(2, 6)):
        e = days[rnd.randint(max(7, weeks * 7 - 35), weeks * 7)]["date"]
        mods.append({"id": k + 1, "exam_date": e, "remaining_minutes": rnd.randint(20, 250) * 60, "priority": rnd.randint(1, 3)})
    return {"days": days, "modules": mods, "now_minute": rnd.randint(420, 1300),
            "settings": {"utilization": rnd.choice([40, 50, 60, 70, 80]), "max_block": rnd.choice([90, 120])},
            "accept_partial": rnd.random() < 0.3}


def check_hard(r: dict, inp: dict) -> list[str]:
    from app import smart_planner as sp
    bad = []
    days = {d["date"]: d for d in inp["days"]}
    exams = {m["id"]: m["exam_date"] for m in inp["modules"]}
    caps = dict(zip([d["date"] for d in inp["days"]], r["capacity_minutes"]))
    per: dict[str, list] = {}
    for b in r["blocks"]:
        if exams[b["module_id"]] is not None and b["date"] >= exams[b["module_id"]]:
            bad.append("nach Klausur")
        if not any(a <= b["start"] and b["end"] <= z for a, z in sp.merge(days[b["date"]]["windows"])):
            bad.append("ausserhalb Fenster")
        per.setdefault(b["date"], []).append(b)
    for d, bs in per.items():
        bs.sort(key=lambda x: x["start"])
        if any(x["end"] > y["start"] for x, y in zip(bs, bs[1:])):
            bad.append("Ueberschneidung")
        if sum(x["minutes"] for x in bs) > caps[d]:
            bad.append("Budget")
    return bad


def worker(args: tuple[int, int]) -> dict:
    from app import smart_planner as sp
    lo, hi = args
    times, errors, violations, statuses, blocks = [], 0, 0, {}, 0
    for seed in range(lo, hi):
        inp = synth_user(seed)
        t = time.perf_counter()
        try:
            r = sp.plan(inp)
        except Exception:                      # noqa: BLE001 - jeder Fehler zaehlt
            errors += 1
            continue
        times.append(time.perf_counter() - t)
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
        blocks += len(r["blocks"])
        if seed % 50 == 0 and r["status"] != "unterdeckt" and check_hard(r, inp):
            violations += 1
    return {"times": times, "errors": errors, "violations": violations, "statuses": statuses, "blocks": blocks, "rss_mb": rss_mb()}


def part_a(users: int, procs: int) -> dict:
    print(f"\nA. Rechenkern: {users} Nutzer auf {procs} Prozessen ...", flush=True)
    chunk = max(100, users // (procs * 20))
    jobs = [(i, min(users, i + chunk)) for i in range(0, users, chunk)]
    t0 = time.perf_counter()
    with mp.get_context("spawn").Pool(procs) as pool:
        parts = pool.map(worker, jobs)
    wall = time.perf_counter() - t0
    times = [x for p in parts for x in p["times"]]
    statuses: dict[str, int] = {}
    for p in parts:
        for k, v in p["statuses"].items():
            statuses[k] = statuses.get(k, 0) + v
    res = {"users": users, "processes": procs, "wall_s": round(wall, 1), "plans_per_s": round(len(times) / wall, 1),
           "plan": summary(times), "errors": sum(p["errors"] for p in parts), "hard_violations": sum(p["violations"] for p in parts),
           "checked_every": 50, "statuses": statuses, "blocks_total": sum(p["blocks"] for p in parts),
           "worker_rss_max_mb": max(p["rss_mb"] for p in parts)}
    print(f"   {len(times)} Plaene in {res['wall_s']} s ({res['plans_per_s']}/s), Median {res['plan']['median_ms']} ms, "
          f"p99 {res['plan']['p99_ms']} ms, Fehler {res['errors']}, Verstoesse {res['hard_violations']}", flush=True)
    return res


# ------------------------------------------------------------------ Teil B

def asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, headers=None, host="test"):
    """Minimaler ASGI-Aufruf ohne httpx (wie tests/conftest.py und tools/lasttest-dienst.py)"""
    import asyncio
    from urllib.parse import unquote
    p, _, q = path.partition("?")
    hdrs = [(b"host", host.encode()), (b"content-type", b"application/json")]
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    raw = body.encode() if isinstance(body, str) else (body or b"")
    hdrs.append((b"content-length", str(len(raw)).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": method,
             "scheme": "http", "path": unquote(p), "raw_path": p.encode(), "query_string": q.encode(), "headers": hdrs,
             "client": client, "server": ("test", 80)}
    out = {"status": None, "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")

    asyncio.run(app(scope, receive, send))
    return out["status"], None, out["body"]


def part_b(n_accounts: int, threads: int, ops: int) -> dict:
    tmp = tempfile.mkdtemp(prefix="lernapp-smart-last-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    os.environ["LERNAPP_ENV_FILE"] = str(Path(tmp) / ".env")
    os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
    os.environ["LERNAPP_NO_SCHEDULER"] = "1"
    os.environ["LERNAPP_MODE"] = "hosted"
    os.environ["LERNAPP_JOBS"] = "off"
    os.environ.setdefault("LERNAPP_MAIL", "log")
    from app import accounts, server
    app = server.app
    print(f"\nB. Dienst: {n_accounts} Konten anlegen ...", flush=True)
    users = []
    for i in range(n_accounts):
        ip = f"10.{(i // 65536) % 256}.{(i // 256) % 256}.{i % 256 or 1}"
        st, _, b = asgi_call(app, "POST", "/api/account/register", client=(ip, 5000),
                             body=json.dumps({"email": f"smart{i:05d}@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
        if st != 201:
            print(f"   Registrierung {i}: {st} {b[:120]!r}")
            continue
        d = json.loads(b)
        accounts.set_plan(d["user"]["id"], "plus")
        h = {"Authorization": f"Bearer {d['token']}"}
        mids = []
        for k, (name, hours, exam) in enumerate((("Mathematik", 200, "2027-02-01"), ("Programmieren", 250, "2027-02-15"), ("Elektrotechnik", 220, "2027-03-01"))):
            st, _, b = asgi_call(app, "POST", "/api/modules", body=json.dumps({"name": name}), headers=h)
            mid = json.loads(b)["id"]
            asgi_call(app, "PATCH", f"/api/modules/{mid}", body=json.dumps({"exam_date": exam}), headers=h)
            asgi_call(app, "PUT", f"/api/goals/{mid}", body=json.dumps({"target_hours": hours // 4}), headers=h)
            mids.append(mid)
        # Stundenplan wie im Semester: 8 Veranstaltungen pro Woche
        for k, (wd, st_, en_) in enumerate(((0, "08:15", "09:45"), (0, "10:00", "11:30"), (1, "12:15", "13:45"), (1, "14:00", "15:30"),
                                            (2, "10:00", "11:30"), (3, "08:15", "09:45"), (3, "16:00", "17:30"), (4, "10:00", "11:30"))):
            asgi_call(app, "POST", "/api/timetable/events", headers=h,
                      body=json.dumps({"title": f"Veranstaltung {k}", "kind": "vorlesung", "weekday": wd, "start_time": st_, "end_time": en_,
                                       "module_id": mids[k % 3], "rrule": "weekly"}))
        st, _, b = asgi_call(app, "POST", "/api/goals/plan", body="{}", headers=h)
        users.append({"h": h, "mids": mids})
    print(f"   {len(users)} Konten mit je 3 Lernzielen und Plan", flush=True)

    lat: dict[str, list[float]] = {}
    codes: dict[str, int] = {}
    locked = [0]
    lock = threading.Lock()
    rnd = random.Random(7)
    plan_ops = []
    for i in range(ops):
        u = rnd.randrange(len(users))
        r = rnd.random()
        kind = "overview" if r < 0.55 else "overview_twice" if r < 0.65 else "timer" if r < 0.8 else "entry" if r < 0.9 else "goal"
        plan_ops.append((u, kind, i))
    cursor = [0]

    def call(kind, m, p, h, body=None):
        t = time.perf_counter()
        st, _, b = asgi_call(app, m, p, headers=h, body=body)
        dt = time.perf_counter() - t
        with lock:
            lat.setdefault(kind, []).append(dt)
            codes[str(st)] = codes.get(str(st), 0) + 1
            if b and b"database is locked" in b:
                locked[0] += 1
        return st, b

    def run():
        while True:
            with lock:
                if cursor[0] >= len(plan_ops):
                    return
                u, kind, i = plan_ops[cursor[0]]
                cursor[0] += 1
            us = users[u]
            h = us["h"]
            if kind == "overview":
                call("GET /api/goals", "GET", "/api/goals", h)
            elif kind == "overview_twice":                    # dieselbe Neuplanung doppelt gestartet
                th = threading.Thread(target=call, args=("GET /api/goals (doppelt)", "GET", "/api/goals", h))
                th.start()
                call("GET /api/goals (doppelt)", "GET", "/api/goals", h)
                th.join()
            elif kind == "timer":
                uid = f"last-{u}-{i}"
                call("POST /api/sessions/start", "POST", "/api/sessions/start", h, json.dumps({"uuid": uid, "module_id": us["mids"][i % 3]}))
                call("POST /api/sessions/{}/stop", "POST", f"/api/sessions/{uid}/stop", h)
            elif kind == "entry":
                call("POST /api/sessions", "POST", "/api/sessions", h, json.dumps({"module_id": us["mids"][i % 3], "minutes": 25}))
            else:                                             # Ziel aendern -> naechste Uebersicht plant um
                call("PUT /api/goals/{}", "PUT", f"/api/goals/{us['mids'][i % 3]}", h, json.dumps({"target_hours": 40 + i % 30}))

    print(f"   {ops} Vorgaenge mit {threads} Threads gleichzeitig ...", flush=True)
    t0 = time.perf_counter()
    ts = [threading.Thread(target=run) for _ in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    wall = time.perf_counter() - t0
    # Rechenzeit je Anfrage ohne Gedraenge (ein Thread, CPU-Zeit des Prozesses): Grundlage der Hochrechnung
    cpu: dict[str, list[float]] = {}

    def timed(kind, m, p, h, body=None):
        t = time.process_time()
        asgi_call(app, m, p, headers=h, body=body)
        cpu.setdefault(kind, []).append(time.process_time() - t)
    for k in range(min(len(users), 100)):
        us = users[k]
        timed("GET /api/goals (unveraendert)", "GET", "/api/goals", us["h"])
        timed("GET /api/goals (unveraendert)", "GET", "/api/goals", us["h"])
        timed("PUT /api/goals/{}", "PUT", f"/api/goals/{us['mids'][0]}", us["h"], json.dumps({"target_hours": 33 + k % 5}))
        timed("GET /api/goals (mit Neuplanung)", "GET", "/api/goals", us["h"])
        uid = f"kalib-{k}"
        timed("POST /api/sessions/start", "POST", "/api/sessions/start", us["h"], json.dumps({"uuid": uid, "module_id": us["mids"][1]}))
        timed("POST /api/sessions/{}/stop", "POST", f"/api/sessions/{uid}/stop", us["h"])
    # keine doppelten Bloecke in irgendeiner Konto-Datenbank
    import sqlite3
    dup = 0
    dbs = list((Path(tmp) / "data").rglob("lernapp.db"))
    for p in dbs:
        c = sqlite3.connect(p)
        dup += c.execute("""SELECT COUNT(*) FROM (SELECT 1 FROM study_packages WHERE source='smart' AND status<>'erledigt'
                            GROUP BY module_id, date, start_time HAVING COUNT(*) > 1)""").fetchone()[0]
        c.close()
    res = {"accounts": len(users), "threads": threads, "ops": ops, "wall_s": round(wall, 1),
           "requests": sum(len(v) for v in lat.values()), "requests_per_s": round(sum(len(v) for v in lat.values()) / wall, 1),
           "status": codes, "database_locked": locked[0], "duplicate_blocks": dup, "user_dbs": len(dbs),
           "latency": {k: summary(v) for k, v in sorted(lat.items())},
           "cpu_serial": {k: summary(v) for k, v in sorted(cpu.items())}, "rss_mb": rss_mb()}
    print(f"   {res['requests']} Anfragen in {res['wall_s']} s ({res['requests_per_s']}/s), Status {codes}, "
          f"locked {locked[0]}, doppelte Bloecke {dup}", flush=True)
    return res


def projection(a: dict | None, b: dict) -> dict:
    """100.000 gleichzeitige Nutzer, Annahmen offen: jeder oeffnet alle 5 Minuten Uebersicht/Kalender (mit Pruefung der
    Lernziele, davon jede zehnte mit geaenderten Eingaben und Neuplanung) und schreibt alle 10 Minuten etwas
    (Stoppuhr starten/stoppen, Eintrag, Ziel). CPU-Zeit je Anfrage aus der Messung ohne Gedraenge (Median)."""
    c = b["cpu_serial"]
    def med(k):
        return c.get(k, {}).get("median_ms", 0) / 1000
    get = 0.9 * med("GET /api/goals (unveraendert)") + 0.1 * med("GET /api/goals (mit Neuplanung)")
    write = statistics.mean([med("PUT /api/goals/{}"), med("POST /api/sessions/start"), med("POST /api/sessions/{}/stop")])
    n = 100_000
    get_rate, write_rate = n / 300, n / 600
    cpu = get_rate * get + write_rate * write
    out = {"concurrent_users": n, "assumption": "je Nutzer: Übersicht alle 5 min (jede 10. mit Neuplanung), ein Schreibvorgang alle 10 min",
           "get_per_s": round(get_rate), "write_per_s": round(write_rate), "cpu_ms_get": round(get * 1000, 2), "cpu_ms_write": round(write * 1000, 2),
           "cpu_s_per_s": round(cpu, 1), "cores_needed_at_70_percent": int(cpu / 0.7) + 1}
    if a:
        out["plan_cpu_ms_median"] = a["plan"]["median_ms"]
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", type=int, default=100_000)
    ap.add_argument("--accounts", type=int, default=200)
    ap.add_argument("--threads", type=int, default=32)
    ap.add_argument("--ops", type=int, default=4000)
    ap.add_argument("--procs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--skip-a", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    res = {"date": date.today().isoformat(), "cpu_count": os.cpu_count()}
    res["kern"] = None if a.skip_a else part_a(a.users, a.procs)
    res["dienst"] = part_b(a.accounts, a.threads, a.ops)
    res["hochrechnung"] = projection(res["kern"], res["dienst"])
    print("\nHochrechnung:", json.dumps(res["hochrechnung"], ensure_ascii=False), flush=True)
    if a.out:
        Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    ok = (res["kern"] is None or (res["kern"]["errors"] == 0 and res["kern"]["hard_violations"] == 0)) and \
        res["dienst"]["duplicate_blocks"] == 0 and not any(k.startswith("5") for k in res["dienst"]["status"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python
"""Lasttest Community (Auftrag vom 13.11.2026): 20.000 gleichzeitige Nutzer auf Feed lesen, posten und antworten.

NUR LOKAL: startet einen eigenen Dienst (uvicorn wie im Betrieb, deploy/Dockerfile: WEB_CONCURRENCY=4) auf 127.0.0.1 mit
einem Wegwerf-Datenordner. Es gibt keinen Parameter fuer eine fremde Adresse - gegen den echten Server laeuft das nie.

Aufbau (direkt in die Datenbanken, damit 20.000 Konten Sekunden statt Stunden brauchen): N Konten (Plus, bestaetigt, je
eine Sitzung), K Kurs-Communities mit ungleich grossen Kursen (wenige sehr grosse wie Mathe I, viele kleine), je Konto
M Kurse, je Kurs im Mittel Q Fragen mit Antworten, Likes und hilfreich-Stimmen.

Teil A - Kosten je Anfrage ohne Gedraenge (in-process, ein Thread): CPU-Zeit und Zahl der SQL-Abfragen je Endpunkt.
Teil B - Kapazitaet: uvicorn mit W Prozessen, C Client-Prozesse ohne Pause (geschlossene Schleife) fuer S Sekunden.
Teil C - 20.000 Nutzer gleichzeitig online (offenes Modell): jeder Nutzer handelt im Mittel alle T Sekunden (Feed,
Frage oeffnen, fragen, antworten, liken, Mitteilungen); P Client-Prozesse erzeugen die Anfragen als Poisson-Strom ueber
einen Vorrat an Keep-alive-Verbindungen (wie hinter einem Reverse-Proxy). Gemessen: angebotene und erreichte Rate,
Antwortzeiten, Statuscodes, "database is locked". Danach Pruefung: jede Antwort gespeichert, keine doppelten Stimmen.

Ehrlich: Gemessen wird auf diesem Rechner (Kerne siehe Ausgabe), Client und Dienst teilen sich die Kerne. Was fuer den
gemieteten Server gilt, ist eine Hochrechnung aus der CPU-Zeit je Anfrage (Teil A) - siehe docs/COMMUNITY-LASTTEST-BERICHT.md.

Aufruf im Projektordner:
  .venv/bin/python tools/lasttest-community-feed.py [--users 20000] [--courses 400] [--workers 4] [--seconds 30] [--out x.json]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import multiprocessing as mp
import os
import random
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
NOW = "2026-11-13T08:00:00Z"


def pct(xs, p):
    s = sorted(xs)
    return round(s[min(len(s) - 1, int(p * (len(s) - 1)))] * 1000, 1) if s else 0.0


def summary(xs):
    if not xs:
        return {"n": 0}
    return {"n": len(xs), "median_ms": round(statistics.median(xs) * 1000, 1), "p95_ms": pct(xs, 0.95), "p99_ms": pct(xs, 0.99),
            "max_ms": round(max(xs) * 1000, 1)}


def course_key(i: int) -> str:
    import hashlib
    return hashlib.sha256(f"uniflow.community.course.v1\0luh\0lasttest-kurs-{i}".encode()).hexdigest()


# ------------------------------------------------------------------ Aufbau

def setup_env(tmp: str) -> None:
    os.environ.update(LERNAPP_DATA_DIR=str(Path(tmp) / "data"), LERNAPP_LOG_DIR=str(Path(tmp) / "logs"),
                      LERNAPP_ENV_FILE=str(Path(tmp) / ".env"), LERNAPP_ALLOWED_HOSTS="test,127.0.0.1",
                      LERNAPP_NO_SCHEDULER="1", LERNAPP_MODE="hosted", LERNAPP_JOBS="off", LERNAPP_MAIL="log")


def clone_user_dbs(ids: list[str]) -> float:
    """Bestandsnutzer: jedes Konto hat seine eigene lernapp.db schon (im Betrieb seit dem ersten Abgleich). Eine Vorlage
    mit dem vollen Schema (db.init_db), dann je Konto ein APFS-Klon (clonefile: kein Platz, bis geschrieben wird).
    Ohne das legt der Dienst beim ersten Kontakt jedes Kontos dessen Datenbank an - der Fall "lauter neue Konten"."""
    import ctypes
    import shutil
    from app import config, db
    t0 = time.perf_counter()
    tok = config.set_user_context(ids[0], "luh")
    try:
        db.init_db()
        src = config.db_path()
    finally:
        config.reset_user_context(tok)
    try:
        libc = ctypes.CDLL("libSystem.dylib")
    except OSError:
        libc = None
    for uid in ids[1:]:
        dst = config.user_data_dir(uid, "luh") / "lernapp.db"
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not (libc and libc.clonefile(str(src).encode(), str(dst).encode(), 0) == 0):
            shutil.copyfile(src, dst)
    return round(time.perf_counter() - t0, 1)


def build(n_users: int, n_courses: int, per_user: int, q_per_course: int, seed: int = 1, new_accounts: bool = False) -> dict:
    """Konten, Sitzungen, Mitgliedschaften und Fragen direkt anlegen. Liefert, was die Clients brauchen."""
    from app import accounts, community
    rnd = random.Random(seed)
    t0 = time.perf_counter()
    tmpl = accounts.register("vorlage@beispiel.de", "sehr-geheim-123", "luh")
    with accounts.cursor() as conn:
        row = dict(conn.execute("SELECT * FROM users WHERE id=?", (tmpl["id"],)).fetchone())
        cols = list(row)
        ids, rows = [], []
        for i in range(n_users):
            uid = uuid.uuid4().hex
            r = {**row, "id": uid, "email": f"last{i:05d}@beispiel.de", "email_verified": 1, "plan": "plus", "plan_until": None}
            rows.append(tuple(r[c] for c in cols))
            ids.append(uid)
        conn.executemany(f"INSERT INTO users({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", rows)
        tokens = [accounts.create_session(conn, uid, None, None) for uid in ids]
    user_dbs_s = None if new_accounts else clone_user_dbs(ids)
    # Kursgroessen ungleich (Zipf): Kurs 0 hat viele tausend Mitglieder, die meisten wenige hundert
    weights = [1 / (k + 1) ** 0.8 for k in range(n_courses)]
    keys = [course_key(k) for k in range(n_courses)]
    member_of: list[list[int]] = []
    pseud = {}
    with community.cursor() as conn:
        mem = []
        for i, uid in enumerate(ids):
            mine = set()
            while len(mine) < per_user:
                mine.add(rnd.choices(range(n_courses), weights)[0])
            member_of.append(sorted(mine))
            mem += [(uid, keys[k], "luh", "course", NOW) for k in mine]
        conn.executemany("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)", mem)
        members: dict[int, list[int]] = {}
        for i, ks in enumerate(member_of):
            for k in ks:
                members.setdefault(k, []).append(i)
        questions: dict[int, list[str]] = {}
        qrows, arows, likes, votes = [], [], [], []
        n_q = 0
        for k in range(n_courses):
            ms = members.get(k, [])
            if not ms:
                continue
            nq = max(1, int(q_per_course * len(ms) / (n_users * per_user / n_courses)))     # grosse Kurse mehr Fragen
            for j in range(nq):
                a = rnd.choice(ms)
                qid = uuid.uuid4().hex
                ts = f"2026-{rnd.randint(10, 11):02d}-{rnd.randint(1, 12):02d}T{rnd.randint(0, 23):02d}:{rnd.randint(0, 59):02d}:{rnd.randint(0, 59):02d}Z"
                pseud.setdefault(a, community.pseudonym(ids[a]))
                qrows.append((qid, keys[k], "luh", ids[a], pseud[a], f"Frage {j} in Kurs {k}", "Wie geht Aufgabe 3? " * 8, None, None, ts, ts))
                questions.setdefault(k, []).append(qid)
                for _ in range(rnd.choice((0, 1, 2, 3, 3, 4, 6))):
                    b = rnd.choice(ms)
                    pseud.setdefault(b, community.pseudonym(ids[b]))
                    aid = uuid.uuid4().hex
                    arows.append((aid, qid, ids[b], pseud[b], "Siehe Satz 2.3, dann " * 6, ts))
                    for v in rnd.sample(ms, min(len(ms), rnd.randint(0, 4))):
                        votes.append((aid, ids[v], ts))
                for v in rnd.sample(ms, min(len(ms), rnd.randint(0, 6))):
                    likes.append((qid, ids[v], ts))
                n_q += 1
        conn.executemany("""INSERT INTO questions(id, course_key, university, author_id, pseudonym, title, body, fingerprint, page,
                            created_at, last_activity) VALUES (?,?,?,?,?,?,?,?,?,?,?)""", qrows)
        conn.executemany("INSERT INTO answers(id, question_id, author_id, pseudonym, body, created_at) VALUES (?,?,?,?,?,?)", arows)
        conn.executemany("INSERT OR IGNORE INTO question_likes(question_id, user_id, created_at) VALUES (?,?,?)", likes)
        conn.executemany("INSERT OR IGNORE INTO answer_votes(answer_id, user_id, created_at) VALUES (?,?,?)", votes)
    sizes = sorted((len(v) for v in members.values()), reverse=True)
    info = {"users": n_users, "courses": n_courses, "memberships": n_users * per_user, "questions": n_q, "answers": len(arows),
            "question_likes": len(likes), "answer_votes": len(votes), "largest_course_members": sizes[0],
            "median_course_members": sizes[len(sizes) // 2], "build_s": round(time.perf_counter() - t0, 1),
            "accounts": "neu (Datenbank entsteht beim ersten Kontakt)" if new_accounts else "Bestand (eigene Datenbank vorhanden)",
            "user_dbs_s": user_dbs_s}
    print(f"   Aufbau: {json.dumps(info, ensure_ascii=False)}", flush=True)
    return {"tokens": tokens, "ids": ids, "keys": keys, "member_of": member_of,
            "questions": {k: v for k, v in questions.items()}, "info": info}


# ------------------------------------------------------------------ Vorgaenge (gleich fuer alle Teile)

MIX = (("feed", 0.50), ("detail", 0.25), ("ask", 0.03), ("answer", 0.08), ("like", 0.04), ("vote", 0.04), ("notifications", 0.06))


def pick_op(rnd: random.Random, w: dict, u: int) -> tuple[str, str, str, str | None]:
    """(Art, Methode, Pfad, Body) fuer Nutzer u."""
    r, acc = rnd.random(), 0.0
    kind = MIX[-1][0]
    for k, p in MIX:
        acc += p
        if r < acc:
            kind = k
            break
    k = rnd.choice(w["member_of"][u])
    key, qs = w["keys"][k], w["questions"].get(k) or [None]
    q = rnd.choice(qs)
    if kind == "feed" or q is None:
        # jede fuenfte Feed-Anfrage blaettert eine Seite weiter (Cursor aus der ersten Seite ist hier nicht bekannt:
        # ein fester Zeitpunkt, wie ein Nutzer, der laenger scrollt)
        extra = "&before=2026-11-01T00:00:00Z" if rnd.random() < 0.2 else ""
        return "feed", "GET", f"/api/community/courses/{key}/questions?limit=30{extra}", None
    if kind == "detail":
        return "detail", "GET", f"/api/community/questions/{q}", None
    if kind == "ask":
        return "ask", "POST", f"/api/community/courses/{key}/questions", json.dumps({"title": f"Lastfrage {rnd.random():.6f}", "body": "Text " * 20})
    if kind == "answer":
        return "answer", "POST", f"/api/community/questions/{q}/answers", json.dumps({"body": f"Lastantwort {rnd.random():.6f}"})
    if kind == "like":
        return "like", "POST", f"/api/community/questions/{q}/like", None
    if kind == "vote":
        return "detail", "GET", f"/api/community/questions/{q}", None      # Stimme braucht eine Antwort-ID: erst oeffnen
    return "notifications", "GET", "/api/community/notifications?limit=50", None


# ------------------------------------------------------------------ Teil A

@contextmanager
def count_sql():
    """Zaehlt SQL-Anweisungen aller community.db-Verbindungen (trace callback)."""
    from app import community
    n = [0]
    orig = community.cursor

    @contextmanager
    def traced():
        with orig() as conn:
            conn.set_trace_callback(lambda s: n.__setitem__(0, n[0] + (0 if s.startswith(("BEGIN", "COMMIT", "PRAGMA")) else 1)))
            yield conn
    community.cursor = traced
    try:
        yield n
    finally:
        community.cursor = orig


def part_a(w: dict, rounds: int = 300) -> dict:
    """Arbeit der Community-Funktionen selbst (Datenbank, Antwort bauen), ohne HTTP, Anmeldung und Middleware: CPU-Zeit
    und SQL-Anweisungen je Vorgang. Den Aufwand des ganzen Stapels misst Teil B (CPU-Zeit der Dienst-Prozesse)."""
    from app import accounts, community_qa
    accounts.LIMITS.update(question_user=(10**9, 60), answer_user=(10**9, 60), like_user=(10**9, 60))
    rnd = random.Random(3)
    cpu: dict[str, list[float]] = {}
    sql: dict[str, list[int]] = {}
    big = max(w["questions"], key=lambda k: len(w["questions"][k]))           # groesster Kurs: Feed voll

    def user(u):
        return {"id": w["ids"][u], "email_verified": True, "plan": "plus", "plan_until": None, "role": "user"}
    for i in range(rounds):
        u = rnd.randrange(len(w["ids"]))
        me = user(u)
        k = rnd.choice(w["member_of"][u])
        key, q = w["keys"][k], rnd.choice(w["questions"].get(k) or [None])
        ops = [("feed", community_qa.list_questions, (me, "luh", key, 30)),
               ("feed (Seite 2)", community_qa.list_questions, (me, "luh", key, 30, "2026-11-01T00:00:00Z")),
               ("notifications", community_qa.notifications, (me, False, 50)),
               ("ask", community_qa.ask, (me, "luh", key, f"Frage {i}", "Text " * 20))]
        if q:
            ops += [("detail", community_qa.get_question, (me, q)), ("answer", community_qa.answer, (me, q, f"Antwort {i}")),
                    ("like", community_qa.like_question, (me, q, True))]
        if big in w["member_of"][u]:
            ops.append(("feed (groesster Kurs)", community_qa.list_questions, (me, "luh", w["keys"][big], 30)))
        for kind, fn, args in ops:
            with count_sql() as n:
                t = time.process_time()
                try:
                    fn(*args)
                except Exception as e:                # noqa: BLE001 - eigene Frage liken usw.: zaehlt nicht
                    if getattr(e, "code", "") not in ("own_post",):
                        raise
                cpu.setdefault(kind, []).append(time.process_time() - t)
            sql.setdefault(kind, []).append(n[0])
    out = {k: {**summary(v), "sql_median": int(statistics.median(sql[k])), "sql_max": max(sql[k])} for k, v in sorted(cpu.items())}
    for k, v in out.items():
        print(f"   {k}: CPU Median {v['median_ms']} ms, p95 {v['p95_ms']} ms, SQL je Vorgang {v['sql_median']} (max {v['sql_max']})", flush=True)
    return out


def service_cpu(proc) -> float:
    """CPU-Sekunden aller uvicorn-Prozesse (Hauptprozess und Worker) laut ps."""
    pids = [str(proc.pid)] + subprocess.run(["pgrep", "-P", str(proc.pid)], capture_output=True, text=True).stdout.split()
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(pids)], capture_output=True, text=True).stdout.split()
    total = 0.0
    for t in out:
        parts = [float(x) for x in t.replace("-", ":").split(":")]
        while len(parts) < 3:
            parts.insert(0, 0.0)
        total += parts[-3] * 3600 + parts[-2] * 60 + parts[-1]
    return total


def _asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, headers=None, host="test"):
    import importlib.util
    spec = importlib.util.spec_from_file_location("lt_sp", ROOT / "tools" / "lasttest-smart-planner.py")
    global _SP
    if "_SP" not in globals():
        _SP = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_SP)
    return _SP.asgi_call(app, method, path, client=client, body=body, headers=headers, host=host)


# ------------------------------------------------------------------ HTTP-Client (asyncio, Keep-alive, ohne Fremdpakete)

class Conn:
    def __init__(self, port):
        self.port, self.r, self.w = port, None, None

    async def request(self, method, path, headers, body):
        for attempt in (0, 1):
            if self.w is None:
                self.r, self.w = await asyncio.open_connection("127.0.0.1", self.port)
                reused = False
            else:
                reused = True
            data = body.encode() if body else b""
            head = f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {len(data)}\r\n"
            if data:
                head += "Content-Type: application/json\r\n"
            head += "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n"
            try:
                self.w.write(head.encode() + data)
                await self.w.drain()
                line = await self.r.readline()
                if not line:
                    raise ConnectionResetError("closed")
                status = int(line.split()[1])
                length, close = 0, False
                while True:
                    h = await self.r.readline()
                    if h in (b"\r\n", b"\n", b""):
                        break
                    k, _, v = h.decode("latin-1").partition(":")
                    if k.lower() == "content-length":
                        length = int(v)
                    elif k.lower() == "connection" and "close" in v.lower():
                        close = True
                payload = await self.r.readexactly(length) if length else b""
                if close:
                    self.close()
                return status, payload
            except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
                self.close()
                if reused and attempt == 0:
                    continue                 # Keep-alive vom Dienst geschlossen: einmal neu (wie URLSession)
                raise

    def close(self):
        if self.w is not None:
            self.w.close()
        self.r = self.w = None


def _client_proc(args) -> dict:
    """Ein Client-Prozess. mode 'closed': `conc` Schleifen ohne Pause. mode 'open': Poisson-Strom mit `rate` je Sekunde."""
    port, w, users, mode, seconds, conc, rate, seed = args
    rnd = random.Random(seed)
    lat: dict[str, list[float]] = {}
    codes: dict[str, int] = {}
    locked = [0]
    late = [0]
    answered: list[str] = []

    async def one(c: Conn):
        u = rnd.choice(users)
        h = {"Authorization": f"Bearer {w['tokens'][u]}"}
        kind, m, p, body = pick_op(rnd, w, u)
        t = time.perf_counter()
        try:
            st, b = await c.request(m, p, h, body)
            if kind == "detail" and st == 200 and rnd.random() < 0.16:     # Teil der Oeffnungen: hilfreich-Stimme
                d = json.loads(b)
                others = [a for a in d.get("answer_list", []) if not a["mine"]]
                if others:
                    t2 = time.perf_counter()
                    st2, b2 = await c.request("POST", f"/api/community/answers/{rnd.choice(others)['id']}/vote", h, None)
                    lat.setdefault("vote", []).append(time.perf_counter() - t2)
                    codes[str(st2)] = codes.get(str(st2), 0) + 1
            if kind == "answer" and st == 201:
                answered.append(json.loads(b)["id"])
            key = str(st)
            if b and b"database is locked" in b:
                locked[0] += 1
        except Exception as e:                   # noqa: BLE001 - zaehlt als Fehler
            key = f"exception {type(e).__name__}"
        lat.setdefault(kind, []).append(time.perf_counter() - t)
        codes[key] = codes.get(key, 0) + 1

    async def closed():
        end = time.perf_counter() + seconds

        async def loop():
            c = Conn(port)
            while time.perf_counter() < end:
                await one(c)
            c.close()
        await asyncio.gather(*(loop() for _ in range(conc)))

    async def open_():
        pool = [Conn(port) for _ in range(conc)]
        free = asyncio.Queue()
        for c in pool:
            free.put_nowait(c)
        end = time.perf_counter() + seconds
        tasks = set()
        nxt = time.perf_counter()

        async def run():
            c = await free.get()
            try:
                await one(c)
            finally:
                free.put_nowait(c)
        while nxt < end:
            now = time.perf_counter()
            if nxt > now:
                await asyncio.sleep(nxt - now)
            if free.empty():
                late[0] += 1                      # alle Verbindungen belegt: Anfrage wartet (zaehlt als verspaetet)
            tk = asyncio.ensure_future(run())
            tasks.add(tk)
            tk.add_done_callback(tasks.discard)
            nxt += rnd.expovariate(rate)
        await asyncio.gather(*tasks)
        for c in pool:
            c.close()

    t0 = time.perf_counter()
    asyncio.run(closed() if mode == "closed" else open_())
    return {"lat": lat, "codes": codes, "locked": locked[0], "late": late[0], "wall": time.perf_counter() - t0, "answered": answered}


def start_service(tmp: str, workers: int) -> tuple[subprocess.Popen, int]:
    with socket.socket() as so:
        so.bind(("127.0.0.1", 0))
        port = so.getsockname()[1]
    log = open(Path(tmp) / f"dienst-{workers}.log", "ab")
    proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.server:app", "--host", "127.0.0.1", "--port", str(port),
                             "--workers", str(workers), "--no-access-log", "--backlog", "4096", "--log-level", "warning"],
                            cwd=str(ROOT), env=dict(os.environ, PYTHONUNBUFFERED="1"), stdout=log, stderr=log)
    import http.client
    deadline = time.monotonic() + 90
    while True:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            c.request("GET", "/api/health")
            if c.getresponse().status < 500:
                break
        except Exception:  # noqa: BLE001
            pass
        if proc.poll() is not None or time.monotonic() > deadline:
            raise SystemExit("Dienst startet nicht: " + (Path(tmp) / f"dienst-{workers}.log").read_text(errors="replace")[-2000:])
        time.sleep(0.3)
    return proc, port


def stop_service(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(20)
    except Exception:  # noqa: BLE001
        proc.kill()


def run_clients(port, w, mode, procs, seconds, conc, rate, proc=None) -> dict:
    n = len(w["ids"])
    cpu0 = service_cpu(proc) if proc else None
    # jeder Client-Prozess hat seinen Teil der Nutzer (zusammen alle N)
    chunks = [(port, w, list(range(k, n, procs)), mode, seconds, conc, rate / procs if rate else 0, 100 + k) for k in range(procs)]
    t0 = time.perf_counter()
    with mp.get_context("spawn").Pool(procs) as pool:
        parts = pool.map(_client_proc, chunks)
    wall = time.perf_counter() - t0
    lat: dict[str, list[float]] = {}
    codes: dict[str, int] = {}
    for p in parts:
        for k, v in p["lat"].items():
            lat.setdefault(k, []).extend(v)
        for k, v in p["codes"].items():
            codes[k] = codes.get(k, 0) + v
    total = sum(len(v) for v in lat.values())
    dur = max(p["wall"] for p in parts)
    res = {"mode": mode, "client_procs": procs, "connections": conc * procs, "seconds": seconds, "requests": total,
           "requests_per_s": round(total / dur, 1), "status": codes, "database_locked": sum(p["locked"] for p in parts),
           "late": sum(p["late"] for p in parts), "latency": {k: summary(v) for k, v in sorted(lat.items())},
           "answered_ids": [a for p in parts for a in p["answered"]], "wall_s": round(wall, 1)}
    if rate:
        res["offered_per_s"] = rate
    if proc:
        used = service_cpu(proc) - cpu0
        res["service_cpu_s"] = round(used, 1)
        res["service_cpu_ms_per_request"] = round(used / max(1, total) * 1000, 2)
        res["service_cores_busy"] = round(used / dur, 2)
        print(f"   Dienst-CPU: {res['service_cpu_ms_per_request']} ms je Anfrage, im Mittel {res['service_cores_busy']} Kerne belegt", flush=True)
    print(f"   {total} Anfragen, {res['requests_per_s']}/s, Status {codes}, locked {res['database_locked']}, verspaetet {res['late']}", flush=True)
    for k, v in res["latency"].items():
        print(f"     {k}: n {v['n']}, Median {v['median_ms']} ms, p95 {v['p95_ms']} ms, p99 {v['p99_ms']} ms, max {v['max_ms']} ms", flush=True)
    return res


def check_db(answered: list[str]) -> dict:
    """Nach dem Lauf: jede bestaetigte Antwort liegt in der Datenbank, keine Stimme und kein Like doppelt."""
    from app import community
    with community.cursor() as conn:
        missing = 0
        for i in range(0, len(answered), 500):
            part = answered[i:i + 500]
            found = conn.execute(f"SELECT COUNT(*) FROM answers WHERE id IN ({','.join('?' * len(part))})", part).fetchone()[0]
            missing += len(part) - found
        dup_votes = conn.execute("SELECT COUNT(*) FROM (SELECT 1 FROM answer_votes GROUP BY answer_id, user_id HAVING COUNT(*)>1)").fetchone()[0]
        dup_likes = conn.execute("SELECT COUNT(*) FROM (SELECT 1 FROM question_likes GROUP BY question_id, user_id HAVING COUNT(*)>1)").fetchone()[0]
    return {"answers_confirmed": len(answered), "answers_missing": missing, "duplicate_votes": dup_votes, "duplicate_likes": dup_likes}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", type=int, default=20_000)
    ap.add_argument("--courses", type=int, default=400)
    ap.add_argument("--per-user", type=int, default=6)
    ap.add_argument("--questions", type=int, default=40, help="Fragen je Kurs im Mittel")
    ap.add_argument("--workers", type=int, default=4, help="uvicorn-Prozesse (Betrieb: WEB_CONCURRENCY=4)")
    ap.add_argument("--clients", type=int, default=6, help="Client-Prozesse")
    ap.add_argument("--conc", type=int, default=16, help="Verbindungen je Client-Prozess")
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--think", type=float, default=60.0, help="Teil C: mittlere Zeit zwischen zwei Aktionen eines Nutzers (s)")
    ap.add_argument("--new-accounts", action="store_true", help="lauter neue Konten: Dienst legt jede Konto-Datenbank beim ersten Kontakt an")
    ap.add_argument("--skip-a", action="store_true")
    ap.add_argument("--skip-b", action="store_true")
    ap.add_argument("--skip-c", action="store_true")
    ap.add_argument("--keep", help="Datenordner behalten/wiederverwenden (Pfad)")
    ap.add_argument("--out")
    a = ap.parse_args()
    tmp = a.keep or tempfile.mkdtemp(prefix="lasttest-community-feed-")
    setup_env(tmp)
    res = {"date": date.today().isoformat(), "cpu_count": os.cpu_count(), "workers": a.workers, "data_dir": tmp}
    print(f"Lasttest Community, nur lokal (127.0.0.1), Daten in {tmp}", flush=True)
    print(f"\nAufbau: {a.users} Konten, {a.courses} Kurse ...", flush=True)
    w = build(a.users, a.courses, a.per_user, a.questions, new_accounts=a.new_accounts)
    res["setup"] = w["info"]
    if not a.skip_a:
        print("\nA. Arbeit der Community-Funktionen je Vorgang (ein Thread, ohne HTTP) ...", flush=True)
        res["a"] = part_a(w)
    proc, port = start_service(tmp, a.workers)
    try:
        if not a.skip_b:
            print(f"\nB. Kapazitaet: uvicorn {a.workers} Prozesse, {a.clients}x{a.conc} Verbindungen ohne Pause, {a.seconds} s ...", flush=True)
            res["b"] = run_clients(port, w, "closed", a.clients, a.seconds, a.conc, 0, proc)
        if not a.skip_c:
            rate = a.users / a.think
            print(f"\nC. {a.users} Nutzer online, je Nutzer alle {a.think:g} s eine Aktion = {rate:.0f} Anfragen/s angeboten, {a.seconds} s ...", flush=True)
            res["c"] = run_clients(port, w, "open", a.clients, a.seconds, a.conc * 4, rate, proc)
    finally:
        stop_service(proc)
    answered = (res.get("b") or {}).get("answered_ids", []) + (res.get("c") or {}).get("answered_ids", [])
    res["check"] = check_db(answered)
    print(f"\nPruefung: {json.dumps(res['check'], ensure_ascii=False)}", flush=True)
    for k in ("b", "c"):
        if res.get(k):
            res[k].pop("answered_ids", None)
    if a.out:
        Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    bad = any(str(s).startswith("5") or "exception" in str(s) for k in ("b", "c") for s in (res.get(k) or {}).get("status", {}))
    return 1 if bad or res["check"]["answers_missing"] or res["check"]["duplicate_votes"] else 0


if __name__ == "__main__":
    sys.exit(main())

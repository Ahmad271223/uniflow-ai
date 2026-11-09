#!/usr/bin/env python
"""Dauerlast mit vielen gleichzeitig angemeldeten Sitzungen (09.11.2026, Audit Pakete 62/82/84/87, Gate G5):
nicht nur Spitzen wie tools/lasttest-anmeldung.py, sondern `--sessions` Sitzungen ueber `--minuten` Minuten mit einem
festen Anfragestrom, dazu ein Wiederanlauf-Sturm und optional ein hart beendeter API-Prozess. Am Ende wird geprueft,
dass jeder bestaetigte Schreibvorgang (sync/push, Ergebnis "created") wirklich in der Konto-Datenbank steht.

    .venv/bin/python tools/lasttest-dauer.py --sessions 4000 --accounts 1000 --minuten 30 --rate 400 --workers 12
    .venv/bin/python tools/lasttest-dauer.py --sessions 200 --accounts 50 --minuten 1 --rate 40 --workers 2 --kill-worker-nach 20

Lastmodell (Audit 50-54, Fahrplan): je aktive Sitzung etwa eine Anfrage je 10 s -> 4.000 Sitzungen = 400 Anfragen/s.
Mischung (Gewichte, `--mix`): Abo-Stand 35, Konto 10, Abgleich lesen (GET /api/sync/changes) 25, Abgleich schreiben
(POST /api/sync/push, 1-3 Module mit op_id) 20, Anmelden 5, KI-Frage 5 (nur mit `--ai`, gegen die Attrappe
tools/lasttest-ki-anbieter.py, nie gegen einen echten Anbieter). Der Strom ist "offen": Anfragen werden nach Plan
abgeschickt, egal wie schnell der Dienst antwortet; die Wartezeit zaehlt ab dem geplanten Zeitpunkt (sonst versteckt
ein langsamer Dienst seine eigene Langsamkeit).

Phasen: Dienst starten (wie lasttest-anmeldung.py: uvicorn --workers N, Temp-Datenordner, Mail nur ins Protokoll, alle
Anfragen hinter EINER Campus-Adresse) -> Konten -> Sitzungen (Anmeldungen mit eigener Geraete-ID) -> Dauerlauf mit
Minutenwerten (n, Fehler je Status, p50/p95/p99, RSS je Prozess, WAL von accounts.db) -> Sturm: alle Sitzungen holen
innerhalb `--sturm-sekunden` Abo-Stand, Aenderungen und schicken einen Push (Geraete kommen nach einer Stoerung
gleichzeitig zurueck) -> Pruefung der bestaetigten Schreibvorgaenge -> Tabelle, optional JSON.

Nur Standardbibliothek + requirements.txt. Nie gegen den echten Dienst richten: das Werkzeug startet seinen eigenen.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import random
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _anmeldung():
    spec = importlib.util.spec_from_file_location("lasttest_anmeldung", HERE / "lasttest-anmeldung.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LA = _anmeldung()
PASSWORD = LA.PASSWORD
DEFAULT_MIX = "entitlements=35,me=10,changes=25,push=20,login=5,ai=5"


def pct(values: list[float], p: float) -> int:
    return round(LA.pct(values, p) * 1000)


class Dauer:
    def __init__(self, d, a: argparse.Namespace) -> None:
        self.d, self.a = d, a
        self.users: list[dict] = []            # {id, email}
        self.sessions: list[dict] = []         # {token, user, device}
        self.lock = threading.Lock()
        self.acked: dict[str, set[str]] = {}   # Konto -> bestaetigte Modulnamen
        self.rnd = random.Random(7)
        self.mix = self._mix(a.mix if a.ai else ",".join(x for x in a.mix.split(",") if not x.startswith("ai=")))

    @staticmethod
    def _mix(spec: str) -> list[tuple[str, int]]:
        out = []
        for part in spec.split(","):
            k, _, w = part.partition("=")
            if k.strip() and int(w or 0) > 0:
                out.append((k.strip(), int(w)))
        return out

    # ------------------------------------------------------------ Aufbau

    def setup(self) -> None:
        def reg(i: int):
            email = f"dauer{i:05d}@beispiel.de"
            st, _, raw = self.d.call("POST", "/api/account/register", {"email": email, "password": PASSWORD, "university": "luh"})
            if st == 201:
                return {"id": json.loads(raw)["user"]["id"], "email": email}
            return None
        with ThreadPoolExecutor(max_workers=self.a.parallel) as ex:
            self.users = [u for u in ex.map(reg, range(self.a.accounts)) if u]
        if not self.users:
            raise SystemExit("keine Konten angelegt")
        if self.a.ai:                                           # StudiNow-KI braucht eine bestaetigte Adresse (wie lasttest-ki.py)
            os.environ.update({k: v for k, v in self.d.env().items() if k.startswith("LERNAPP_")})
            sys.path.insert(0, str(self.d.repo))
            from app import accounts  # noqa: E402
            for u in self.users:
                accounts.mark_email_verified(u["id"])

        def sess(i: int):
            u = self.users[i % len(self.users)]
            dev = f"ipad-{i}"
            st, _, raw = self.d.call("POST", "/api/account/login", {"email": u["email"], "password": PASSWORD,
                                                                   "device_id": dev, "device_name": "Lasttest"})
            if st == 200:
                return {"token": json.loads(raw)["token"], "user": u["id"], "device": dev, "since": None}
            return None
        with ThreadPoolExecutor(max_workers=self.a.parallel) as ex:
            self.sessions = [s for s in ex.map(sess, range(self.a.sessions)) if s]
        print(f"{len(self.users)} Konten, {len(self.sessions)} Sitzungen", flush=True)

    # ------------------------------------------------------------ eine Anfrage

    def one(self, kind: str, s: dict) -> int | str:
        tok = s["token"]
        if kind == "entitlements":
            return self.d.call("GET", "/api/entitlements", token=tok)[0]
        if kind == "me":
            return self.d.call("GET", "/api/account/me", token=tok)[0]
        if kind == "changes":
            q = f"?device_id={s['device']}" + (f"&since={s['since']}" if s.get("since") else "")
            st, _, raw = self.d.call("GET", "/api/sync/changes" + q, token=tok)
            if st == 200:
                try:
                    s["since"] = json.loads(raw).get("cursor") or s.get("since")
                except ValueError:
                    pass
            return st
        if kind == "push":
            names = [f"Dauer {uuid.uuid4().hex[:12]}" for _ in range(self.rnd.randint(1, 3))]
            items = [{"entity": "modules", "local_id": -(k + 1), "op_id": "lt-" + uuid.uuid4().hex, "data": {"name": n}}
                     for k, n in enumerate(names)]
            st, _, raw = self.d.call("POST", "/api/sync/push", {"device_id": s["device"], "items": items, "deletes": []}, token=tok)
            if st == 200:
                try:
                    res = json.loads(raw).get("results") or []
                except ValueError:
                    res = []
                ok = [n for n, r in zip(names, res) if r.get("status") in ("created", "resurrected")]
                with self.lock:
                    self.acked.setdefault(s["user"], set()).update(ok)
            return st
        if kind == "login":
            u = next(x for x in self.users if x["id"] == s["user"])
            return self.d.call("POST", "/api/account/login", {"email": u["email"], "password": PASSWORD,
                                                              "device_id": s["device"], "device_name": "Lasttest"})[0]
        if kind == "ai":
            body = {"mode": "explain", "page_text": f"Seite: Eine Matrix ist ein Zahlenschema {uuid.uuid4().hex}.",
                    "question": "Was bedeutet das?", "request_id": "lt-" + uuid.uuid4().hex}
            st, _, raw = self.d.call("POST", "/api/ai/tutor", body, token=tok)
            return st if st == 200 else f"{st} {self._code(raw)}".strip()
        raise ValueError(kind)

    @staticmethod
    def _code(raw: bytes) -> str:
        """Fehlercode des Dienstes ({"detail": {"code": ...}} oder {"code": ...}) fuer die Statusliste."""
        try:
            d = json.loads(raw)
        except ValueError:
            return ""
        inner = d.get("detail") if isinstance(d.get("detail"), dict) else d
        return str(inner.get("code") or "") if isinstance(inner, dict) else ""

    def api_pids(self) -> list[int]:
        """Laufende API-Prozesse: Kinder des uvicorn-Hauptprozesses ab 40 MB (ohne den kleinen Hilfsprozess von
        multiprocessing und ohne einen gerade beendeten, noch nicht abgeholten Prozess)."""
        return [p for p in self.d.worker_pids() if (LA.rss_mb([p]) or [0])[0] >= 40]

    # ------------------------------------------------------------ Dauerlauf

    def soak(self) -> list[dict]:
        a = self.a
        minutes: list[dict] = []
        kinds = [k for k, _ in self.mix]
        weights = [w for _, w in self.mix]
        cur = {"lat": {}, "status": {}, "n": 0}
        cur_lock = threading.Lock()
        fast = ThreadPoolExecutor(max_workers=a.parallel)
        slow = ThreadPoolExecutor(max_workers=max(64, a.parallel * 2))    # KI-Fragen warten 10-20 s auf die Attrappe
        killed = {"at": None, "pid": None, "back_after_s": None}

        def record(kind: str, planned: float, st) -> None:
            dt = time.monotonic() - planned
            with cur_lock:
                cur["n"] += 1
                cur["lat"].setdefault(kind, []).append(dt)
                cur["status"][str(st)] = cur["status"].get(str(st), 0) + 1

        def job(kind: str, s: dict, planned: float) -> None:
            try:
                st = self.one(kind, s)
            except Exception:  # noqa: BLE001
                st = 0
            record(kind, planned, st)

        def close_minute(i: int) -> None:
            with cur_lock:
                lat, status, n = cur["lat"], cur["status"], cur["n"]
                cur.update({"lat": {}, "status": {}, "n": 0})
            allv = [x for v in lat.values() for x in v]
            bad = sum(c for k, c in status.items() if k not in ("200", "201"))
            wal = self.d.tmp / "data" / "accounts.db-wal"
            row = {"minute": i, "n": n, "errors": bad, "status": dict(sorted(status.items())),
                   "p50_ms": pct(allv, 0.5), "p95_ms": pct(allv, 0.95), "p99_ms": pct(allv, 0.99),
                   "by": {k: {"n": len(v), "p95_ms": pct(v, 0.95)} for k, v in sorted(lat.items())},
                   "rss_mb": LA.rss_mb(self.d.worker_pids()), "wal_mb": round(wal.stat().st_size / 2**20, 1) if wal.exists() else 0.0}
            minutes.append(row)
            print(f"  Minute {i:>3}: n={n:<6} Fehler={bad:<5} p50={row['p50_ms']:>5} ms p95={row['p95_ms']:>5} ms "
                  f"p99={row['p99_ms']:>6} ms WAL={row['wal_mb']} MB RSS={row['rss_mb']}", flush=True)

        start = time.monotonic()
        end = start + a.minuten * 60
        interval = 1.0 / a.rate
        nxt, minute_end, i_min = start, start + 60, 1
        n_workers = len(self.api_pids())
        next_check = start
        while nxt < end:
            now = time.monotonic()
            if now < nxt:
                time.sleep(min(nxt - now, 0.05))
                continue
            if now >= minute_end:
                close_minute(i_min)
                i_min += 1
                minute_end += 60
            if a.kill_worker_nach and killed["at"] is None and now - start >= a.kill_worker_nach:
                pids = self.api_pids()
                if pids and pids != [self.d.proc.pid]:
                    killed.update(at=round(now - start, 1), pid=pids[0])
                    os.kill(pids[0], signal.SIGKILL)
                    print(f"  API-Prozess {pids[0]} hart beendet (SIGKILL) nach {killed['at']} s", flush=True)
            if killed["pid"] and killed["back_after_s"] is None and now >= next_check:
                next_check = now + 1.0                          # ps hoechstens einmal je Sekunde
                alive = [p for p in self.api_pids() if p != killed["pid"]]
                if len(alive) >= n_workers:
                    killed["back_after_s"] = round(now - start - killed["at"], 1)
            kind = self.rnd.choices(kinds, weights)[0]
            s = self.sessions[self.rnd.randrange(len(self.sessions))]
            (slow if kind == "ai" else fast).submit(job, kind, s, nxt)
            nxt += interval
        fast.shutdown(wait=True)
        slow.shutdown(wait=True)
        close_minute(i_min)
        self.killed = killed
        return minutes

    def storm(self) -> dict:
        """Alle Sitzungen kommen innerhalb von `--sturm-sekunden` zurueck: Abo-Stand, Aenderungen, Push."""
        a = self.a
        lat: list[float] = []
        status: dict[str, int] = {}
        lock = threading.Lock()

        def back(i: int) -> None:
            s = self.sessions[i]
            time.sleep(self.rnd.random() * a.sturm_sekunden)            # Geraete kommen verteilt, nicht im selben ms
            for kind in ("entitlements", "changes", "push"):
                t0 = time.monotonic()
                try:
                    st = self.one(kind, s)
                except Exception:  # noqa: BLE001
                    st = 0
                with lock:
                    lat.append(time.monotonic() - t0)
                    status[str(st)] = status.get(str(st), 0) + 1
        t0 = time.monotonic()
        with ThreadPoolExecutor(max_workers=max(a.parallel, 256)) as ex:
            list(ex.map(back, range(len(self.sessions))))
        n = sum(status.values())
        return {"n": n, "wall_s": round(time.monotonic() - t0, 1), "errors": sum(c for k, c in status.items() if k not in ("200", "201")),
                "status": dict(sorted(status.items())), "p50_ms": pct(lat, 0.5), "p95_ms": pct(lat, 0.95), "p99_ms": pct(lat, 0.99)}

    def verify(self) -> dict:
        """Jeder bestaetigte Push steht in der Konto-Datenbank (users/<id>/**/lernapp.db, Tabelle modules)."""
        acked = sum(len(v) for v in self.acked.values())
        missing = 0
        for uid, names in self.acked.items():
            found: set[str] = set()
            for dbf in (self.d.tmp / "data" / "users" / uid).rglob("lernapp.db"):
                c = sqlite3.connect(f"file:{dbf}?mode=ro", uri=True, timeout=30)
                try:
                    found |= {r[0] for r in c.execute("SELECT name FROM modules WHERE name LIKE 'Dauer %'")}
                except sqlite3.Error:
                    pass
                finally:
                    c.close()
            missing += len(names - found)
        return {"acked": acked, "missing": missing}

    def run(self) -> dict:
        a = self.a
        print(f"Dienst: {self.d.repo} auf {self.d.base}, {a.workers} Prozesse, Datenordner {self.d.tmp}", flush=True)
        self.setup()
        minutes = self.soak()
        storm = self.storm() if a.sturm_sekunden > 0 else None
        if storm:
            print(f"  Sturm: {storm}", flush=True)
        check = self.verify()
        print(f"  bestaetigte Schreibvorgaenge: {check['acked']}, davon fehlend: {check['missing']}", flush=True)
        total_n = sum(m["n"] for m in minutes)
        total_err = sum(m["errors"] for m in minutes)
        return {"label": a.label, "workers": a.workers, "sessions": len(self.sessions), "accounts": len(self.users),
                "rate": a.rate, "minutes_planned": a.minuten, "mix": self.mix, "minutes": minutes,
                "total": {"n": total_n, "errors": total_err, "error_pct": round(100 * total_err / total_n, 3) if total_n else None},
                "killed": self.killed, "storm": storm, "writes": check, "python": sys.version.split()[0], "cpus": os.cpu_count()}


def table(r: dict) -> str:
    rows = [f"| Minute ({r['label']}) | n | Fehler | p50 ms | p95 ms | p99 ms | WAL MB | RSS je Prozess MB |", "|---|---|---|---|---|---|---|---|"]
    for m in r["minutes"]:
        rows.append(f"| {m['minute']} | {m['n']} | {m['errors']} | {m['p50_ms']} | {m['p95_ms']} | {m['p99_ms']} | {m['wal_mb']} | "
                    f"{', '.join(str(round(x)) for x in m['rss_mb'])} |")
    t = r["total"]
    rows.append(f"\nGesamt {t['n']} Anfragen, {t['errors']} Fehler ({t['error_pct']} %); {r['sessions']} Sitzungen auf {r['accounts']} "
                f"Konten, {r['rate']} Anfragen/s geplant, {r['workers']} Prozesse")
    if r.get("killed", {}).get("at") is not None:
        k = r["killed"]
        rows.append(f"API-Prozess hart beendet nach {k['at']} s, Ersatz nach {k['back_after_s']} s")
    if r.get("storm"):
        s = r["storm"]
        rows.append(f"Sturm: {s['n']} Anfragen in {s['wall_s']} s, {s['errors']} Fehler, p50/p95/p99 {s['p50_ms']}/{s['p95_ms']}/{s['p99_ms']} ms")
    w = r["writes"]
    rows.append(f"Bestaetigte Schreibvorgaenge {w['acked']}, fehlend {w['missing']}")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=None, help="Code-Stand, der laufen soll (Standard: dieses Repo)")
    ap.add_argument("--env", action="append", default=[], help="NAME=WERT fuer den Dienst, mehrfach erlaubt")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--parallel", type=int, default=256, help="gleichzeitige Clients (Threads) fuer schnelle Anfragen")
    ap.add_argument("--accounts", type=int, default=1000)
    ap.add_argument("--sessions", type=int, default=4000)
    ap.add_argument("--minuten", type=float, default=30.0)
    ap.add_argument("--rate", type=float, default=400.0, help="Anfragen je Sekunde im Dauerlauf (je Sitzung ~1 je 10 s)")
    ap.add_argument("--mix", default=DEFAULT_MIX)
    ap.add_argument("--ai", action="store_true", help="KI-Fragen gegen die Attrappe tools/lasttest-ki-anbieter.py")
    ap.add_argument("--ai-delay", type=float, default=10.0)
    ap.add_argument("--ai-jitter", type=float, default=10.0)
    ap.add_argument("--provider-port", type=int, default=8798)
    ap.add_argument("--sturm-sekunden", type=float, default=60.0, help="0 = kein Wiederanlauf-Sturm")
    ap.add_argument("--kill-worker-nach", type=float, default=0.0, help="nach so vielen Sekunden einen API-Prozess hart beenden")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--wrong-pct", type=float, default=0.0)            # von lasttest-anmeldung.Dienst erwartet
    ap.add_argument("--label", default="dauer")
    ap.add_argument("--json", default=None)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    provider = None
    if a.ai:
        a.env = [*a.env, "LERNAPP_AI_PROVIDER=openai", "LERNAPP_OPENAI_API_KEY=sk-lasttest-attrappe",
                 f"LERNAPP_OPENAI_BASE_URL=http://127.0.0.1:{a.provider_port}/v1", "LERNAPP_AI_MODEL=gpt-6-luna",
                 "LERNAPP_AI_BUDGET_EUR=100000", "LERNAPP_AI_TRIAL_BUDGET_EUR=100000", "LERNAPP_AI_USER_BUDGET_EUR=10000",
                 "LERNAPP_AI_RATE_PER_MINUTE=1000000", "LERNAPP_AI_RATE_PER_HOUR=1000000", "LERNAPP_CREDITS_TRIAL=10000000"]
        provider = subprocess.Popen([sys.executable, str(HERE / "lasttest-ki-anbieter.py"), "--port", str(a.provider_port),
                                     "--delay", str(a.ai_delay), "--jitter", str(a.ai_jitter), "--quiet"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Grenzen, die der Lasttest selbst nicht sprengen soll (eine Adresse, viele Anmeldungen) - wie lasttest-anmeldung.py
    a.env = ["LERNAPP_LIMIT_REGISTER_IP=100000/60", "LERNAPP_LIMIT_REGISTER_ALL=100000/60", "LERNAPP_LOGIN_FAILS_IP=100000",
             "LERNAPP_LIMIT_API_PER_MIN=1000000", *a.env]
    d = LA.Dienst(a)
    d.start()
    try:
        r = Dauer(d, a).run()
    finally:
        d.stop()
        if provider is not None:
            provider.terminate()
            try:
                provider.wait(10)
            except Exception:  # noqa: BLE001
                provider.kill()
    print(table(r))
    if a.json:
        Path(a.json).write_text(json.dumps(r, indent=2, ensure_ascii=False))
    return 0 if r["writes"]["missing"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

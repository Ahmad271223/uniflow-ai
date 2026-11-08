"""Lasttest der StudiNow-KI im Dienst, lokal (08.11.2026): viele KI-Fragen GLEICHZEITIG, daneben normale Anfragen
(Anmelden, Abo-Stand, Geraete-Abgleich) - wie lange warten die normalen Anfragen, wie viele KI-Fragen schafft der
Dienst, wie viel Speicher braucht ein Prozess? Nichts geht gegen den echten Server: der Dienst startet hier auf dem
Rechner mit 4 Prozessen (wie auf dem Server) auf einem Temp-Datenordner, der KI-Anbieter ist eine Attrappe
(tools/lasttest-ki-anbieter.py, Antwort nach 10 s).

Aufruf (aus der Repo-Wurzel, venv):
    .venv/bin/python tools/lasttest-ki.py --ai 300 --normal 200 --label nachher
    .venv/bin/python tools/lasttest-ki.py --ai 4000 --normal 200 --accounts 400 --delay 10 --jitter 10 --label nachher
    .venv/bin/python tools/lasttest-ki.py --repo /pfad/zum/alten/stand --ai 300 --label vorher     (Vergleich vorher/nachher)

Ablauf: Dienst und Attrappe starten -> Konten anlegen (bestaetigte E-Mail, Probe = Pro AI mit Credits) -> normale
Anfragen OHNE Last messen (Vergleichswert) -> `--ai` KI-Fragen innerhalb von ~2 s abschicken -> nach 2 s `--normal`
normale Anfragen messen (p50/p95/max) und den Speicher der Prozesse abtasten -> auf alle KI-Antworten warten ->
Tabelle (Markdown) und optional JSON (`--json`). Ergebnisse in docs/release/BETRIEB.md "Kapazitaet und Lastgrenzen".
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

try:
    import httpx2 as httpx
except ImportError:  # pragma: no cover
    import httpx

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PASSWORD = "sehr-geheim-123"


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    xs = sorted(values)
    k = max(0, min(len(xs) - 1, round((p / 100) * (len(xs) - 1))))
    return xs[k]


def ms(v: float) -> str:
    return f"{v * 1000:.0f} ms"


def children(pid: int) -> list[int]:
    try:
        out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        return [int(x) for x in out]
    except Exception:  # noqa: BLE001
        return []


def rss_mb(pids: list[int]) -> list[float]:
    if not pids:
        return []
    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout.split()
    # nur die API-Prozesse (uvicorn startet daneben einen kleinen Hilfsprozess fuer multiprocessing, ~17 MB)
    return [int(x) / 1024 for x in out if x.isdigit() and int(x) / 1024 >= 40]


async def wait_http(client: httpx.AsyncClient, url: str, seconds: float = 60) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            r = await client.get(url)
            if r.status_code == 200:
                return
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(0.3)
    raise SystemExit(f"Dienst antwortet nicht auf {url}")


class Run:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a = a
        self.repo = Path(a.repo).resolve() if a.repo else ROOT
        self.tmp = Path(tempfile.mkdtemp(prefix="lasttest-ki-"))
        self.base = f"http://127.0.0.1:{a.port}"
        self.procs: list[subprocess.Popen] = []
        self.tokens: list[str] = []
        self.emails: list[str] = []
        self.mem_samples: list[list[float]] = []

    def env(self) -> dict:
        e = {k: v for k, v in os.environ.items() if not k.startswith("LERNAPP_")}
        e.update({
            "LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": str(self.tmp / "data"), "LERNAPP_LOG_DIR": str(self.tmp / "logs"),
            "LERNAPP_JOBS": "off", "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_MAIL": "log", "LERNAPP_OCR": "off",
            "LERNAPP_ALLOWED_HOSTS": "127.0.0.1", "LERNAPP_SECRET_KEY": "lasttest-" + uuid.uuid4().hex,
            # Schein-Anbieter statt OpenAI; Preise aus app/ai_prices.py (gpt-6-luna)
            "LERNAPP_AI_PROVIDER": "openai", "LERNAPP_OPENAI_API_KEY": "sk-lasttest-attrappe",
            "LERNAPP_OPENAI_BASE_URL": f"http://127.0.0.1:{self.a.provider_port}/v1", "LERNAPP_AI_MODEL": "gpt-6-luna",
            # Grenzen, die den Lasttest selbst nicht bremsen sollen (im Betrieb viel kleiner!)
            "LERNAPP_AI_BUDGET_EUR": "100000", "LERNAPP_AI_TRIAL_BUDGET_EUR": "100000", "LERNAPP_AI_USER_BUDGET_EUR": "10000",
            "LERNAPP_AI_RATE_PER_MINUTE": "1000000", "LERNAPP_AI_RATE_PER_HOUR": "1000000", "LERNAPP_CREDITS_TRIAL": "10000000",
            "LERNAPP_LIMIT_API_PER_MIN": "1000000", "LERNAPP_LIMIT_REGISTER_IP": "100000/60",
            "WEB_CONCURRENCY": str(self.a.workers), "PYTHONUNBUFFERED": "1",
        })
        if self.a.concurrency:
            e["LERNAPP_AI_CONCURRENCY"] = str(self.a.concurrency)
        return e

    def start(self) -> None:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        want = min(hard if hard != resource.RLIM_INFINITY else 1 << 20, 1 << 20)
        if soft < want:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
        py = sys.executable
        log = open(self.tmp / "dienst.log", "wb")
        self.procs.append(subprocess.Popen([py, str(HERE / "lasttest-ki-anbieter.py"), "--port", str(self.a.provider_port), "--delay", str(self.a.delay),
                                            "--jitter", str(self.a.jitter), "--quiet"], stdout=log, stderr=log))
        self.procs.append(subprocess.Popen([py, "-m", "uvicorn", "app.server:app", "--host", "127.0.0.1", "--port", str(self.a.port),
                                            "--workers", str(self.a.workers), "--no-access-log", "--backlog", "4096", "--log-level", "warning"],
                                           cwd=str(self.repo), env=self.env(), stdout=log, stderr=log))

    def stop(self) -> None:
        for p in self.procs:
            try:
                p.send_signal(signal.SIGTERM)
            except Exception:  # noqa: BLE001
                pass
        for p in self.procs:
            try:
                p.wait(15)
            except Exception:  # noqa: BLE001
                p.kill()
        if not self.a.keep:
            shutil.rmtree(self.tmp, ignore_errors=True)

    def worker_pids(self) -> list[int]:
        master = self.procs[1].pid
        kids = children(master)
        return kids or [master]

    # ------------------------------------------------------------ Konten

    async def accounts(self, client: httpx.AsyncClient) -> None:
        sem = asyncio.Semaphore(8)

        async def one(i: int):
            email = f"lt{i}@beispiel.de"
            async with sem:
                r = await client.post(self.base + "/api/account/register", json={"email": email, "password": PASSWORD, "university": "luh"})
            if r.status_code != 201:
                raise SystemExit(f"Registrierung {i}: {r.status_code} {r.text[:200]}")
            d = r.json()
            self.tokens.append(d["token"])
            self.emails.append(email)
            return d["user"]["id"]
        ids = await asyncio.gather(*(one(i) for i in range(self.a.accounts)))
        # bestaetigte E-Mail (Pflicht fuer die StudiNow-KI): wie accounts.mark_email_verified, direkt in accounts.db
        sys.path.insert(0, str(self.repo))
        os.environ.update({k: v for k, v in self.env().items() if k.startswith("LERNAPP_")})
        from app import accounts  # noqa: E402
        for uid in ids:
            accounts.mark_email_verified(uid)

    # ------------------------------------------------------------ Anfragen

    async def normal_request(self, client: httpx.AsyncClient, i: int) -> tuple[str, float, int]:
        kind = ("entitlements", "login", "sync")[i % 3]
        tok = self.tokens[i % len(self.tokens)]
        h = {"Authorization": f"Bearer {tok}"}
        t0 = time.monotonic()
        try:
            if kind == "entitlements":
                r = await client.get(self.base + "/api/entitlements", headers=h)
            elif kind == "login":
                r = await client.post(self.base + "/api/account/login", json={"email": self.emails[i % len(self.emails)], "password": PASSWORD})
            else:
                r = await client.post(self.base + "/api/sync/push", headers=h,
                                      json={"device_id": f"lt-{i}", "items": [], "deletes": []})
            st = r.status_code
        except Exception:  # noqa: BLE001
            st = 0
        return kind, time.monotonic() - t0, st

    async def normal_batch(self, client: httpx.AsyncClient, n: int, parallel: int) -> dict:
        sem = asyncio.Semaphore(parallel)

        async def one(i):
            async with sem:
                return await self.normal_request(client, i)
        res = await asyncio.gather(*(one(i) for i in range(n)))
        by: dict[str, list[float]] = {}
        bad = 0
        for kind, dt, st in res:
            by.setdefault(kind, []).append(dt)
            if st not in (200, 201):
                bad += 1
        allv = [dt for _, dt, _ in res]
        return {"n": n, "bad": bad, "p50": pct(allv, 50), "p95": pct(allv, 95), "max": max(allv) if allv else 0,
                "by": {k: {"p50": pct(v, 50), "p95": pct(v, 95), "max": max(v)} for k, v in by.items()}}

    async def ai_request(self, client: httpx.AsyncClient, i: int) -> tuple[float, int, str]:
        tok = self.tokens[i % len(self.tokens)]
        body = {"mode": "explain", "page_text": f"Seite {i}: Eine Matrix ist ein rechteckiges Zahlenschema {uuid.uuid4().hex}.",
                "question": "Was bedeutet das?", "request_id": "lt-" + uuid.uuid4().hex}
        t0 = time.monotonic()
        try:
            r = await client.post(self.base + "/api/ai/tutor", headers={"Authorization": f"Bearer {tok}"}, json=body, timeout=600)
            code = ""
            if r.status_code != 200:
                try:
                    code = str(r.json().get("code") or "")
                except Exception:  # noqa: BLE001
                    code = r.text[:60]
            return time.monotonic() - t0, r.status_code, code
        except Exception as e:  # noqa: BLE001
            return time.monotonic() - t0, 0, type(e).__name__

    async def sample_memory(self, stop: asyncio.Event) -> None:
        while not stop.is_set():
            self.mem_samples.append(rss_mb(self.worker_pids()))
            try:
                await asyncio.wait_for(stop.wait(), 1.0)
            except asyncio.TimeoutError:
                pass

    # ------------------------------------------------------------ Ablauf

    async def run(self) -> dict:
        a = self.a
        limits = httpx.Limits(max_connections=None, max_keepalive_connections=256)
        async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=60.0), limits=limits) as client:
            await wait_http(client, self.base + "/login")
            t = time.monotonic()
            await self.accounts(client)
            print(f"{a.accounts} Konten angelegt in {time.monotonic() - t:.1f} s", file=sys.stderr, flush=True)
            idle_mem = rss_mb(self.worker_pids())
            baseline = await self.normal_batch(client, min(a.normal, 100), 10)
            print(f"Vergleich ohne Last: p50 {ms(baseline['p50'])}, p95 {ms(baseline['p95'])}", file=sys.stderr, flush=True)

            stop = asyncio.Event()
            mem_task = asyncio.create_task(self.sample_memory(stop))
            t_start = time.monotonic()

            async def fire(i: int):
                await asyncio.sleep(i * (a.ramp / max(1, a.ai)))      # innerhalb von `ramp` Sekunden abschicken
                return await self.ai_request(client, i)
            ai_tasks = [asyncio.create_task(fire(i)) for i in range(a.ai)]
            await asyncio.sleep(a.ramp + 1.0)
            t_norm = time.monotonic()
            under_load = await self.normal_batch(client, a.normal, 20)
            norm_wall = time.monotonic() - t_norm
            ai_res = await asyncio.gather(*ai_tasks)
            wall = time.monotonic() - t_start
            stop.set()
            await mem_task
        durations = [d for d, st, _ in ai_res]
        ok = sum(1 for _, st, _ in ai_res if st == 200)
        codes: dict[str, int] = {}
        for _, st, code in ai_res:
            if st != 200:
                k = f"{st} {code}".strip()
                codes[k] = codes.get(k, 0) + 1
        peak = [max(col) for col in zip(*[s for s in self.mem_samples if s])] if self.mem_samples else []
        out = {"label": a.label, "repo": str(self.repo), "workers": a.workers, "ai": a.ai, "normal": a.normal, "accounts": a.accounts,
               "delay_s": a.delay, "jitter_s": a.jitter, "ai_ok": ok, "ai_errors": codes, "ai_p50": pct(durations, 50),
               "ai_p95": pct(durations, 95), "ai_max": max(durations) if durations else 0, "wall_s": wall,
               "ai_per_s": (a.ai / wall) if wall else 0, "baseline": baseline, "under_load": under_load, "normal_wall_s": norm_wall,
               "mem_idle_mb": idle_mem, "mem_peak_mb": peak}
        return out


def table(r: dict) -> str:
    peak = ", ".join(f"{m:.0f}" for m in r["mem_peak_mb"]) or "-"
    idle = ", ".join(f"{m:.0f}" for m in r["mem_idle_mb"]) or "-"
    errs = "; ".join(f"{k}: {v}" for k, v in r["ai_errors"].items()) or "keine"
    b, u = r["baseline"], r["under_load"]
    rows = [
        ("Stand", r["label"]), ("Prozesse", str(r["workers"])), ("KI-Fragen gleichzeitig", str(r["ai"])),
        ("Schein-Antwortzeit", f"{r['delay_s']:.0f} s" + (f" + 0..{r['jitter_s']:.0f} s" if r["jitter_s"] else "")),
        ("KI beantwortet", f"{r['ai_ok']} / {r['ai']}"), ("KI-Fehler", errs),
        ("KI-Dauer p50 / p95 / max", f"{r['ai_p50']:.1f} s / {r['ai_p95']:.1f} s / {r['ai_max']:.1f} s"),
        ("KI-Durchsatz", f"{r['ai_per_s']:.0f} Fragen/s (alle {r['ai']} in {r['wall_s']:.1f} s)"),
        ("Normale Anfragen ohne Last p50 / p95", f"{ms(b['p50'])} / {ms(b['p95'])}"),
        ("Normale Anfragen UNTER Last p50 / p95 / max", f"{ms(u['p50'])} / {ms(u['p95'])} / {ms(u['max'])} ({u['n']} Anfragen, {u['bad']} Fehler)"),
    ]
    for k, v in u["by"].items():
        rows.append((f"  davon {k} p50 / p95", f"{ms(v['p50'])} / {ms(v['p95'])}"))
    rows += [("Speicher je Prozess (MB) ohne Last", idle), ("Speicher je Prozess (MB) Spitze", peak)]
    w = max(len(k) for k, _ in rows)
    lines = [f"| {'Messgroesse'.ljust(w)} | Wert |", f"| {'-' * w} | ---- |"]
    lines += [f"| {k.ljust(w)} | {v} |" for k, v in rows]
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=None, help="Code-Stand, der laufen soll (Standard: dieses Repo)")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--ai", type=int, default=300, help="gleichzeitige KI-Fragen")
    ap.add_argument("--normal", type=int, default=200, help="normale Anfragen waehrend der KI-Last")
    ap.add_argument("--accounts", type=int, default=200)
    ap.add_argument("--delay", type=float, default=10.0, help="Antwortzeit der Attrappe in Sekunden")
    ap.add_argument("--jitter", type=float, default=0.0)
    ap.add_argument("--ramp", type=float, default=2.0, help="KI-Fragen innerhalb so vieler Sekunden abschicken")
    ap.add_argument("--concurrency", type=int, default=0, help="LERNAPP_AI_CONCURRENCY fuer den Dienst (0 = Standard)")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--provider-port", type=int, default=8799)
    ap.add_argument("--label", default="nachher")
    ap.add_argument("--json", default=None, help="Ergebnis zusaetzlich als JSON-Datei")
    ap.add_argument("--keep", action="store_true", help="Temp-Ordner (Protokoll des Dienstes) behalten")
    a = ap.parse_args()
    run = Run(a)
    print(f"Code: {run.repo}  Daten: {run.tmp}", file=sys.stderr, flush=True)
    run.start()
    try:
        r = asyncio.run(run.run())
    finally:
        run.stop()
    print(table(r))
    if a.json:
        Path(a.json).write_text(json.dumps(r, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

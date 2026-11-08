#!/usr/bin/env python
"""Lasttest der Nicht-KI-Pfade des Dienstes hinter EINER Campus-Adresse (08.11.2026, Launch mit bis zu 4.000 Nutzern):
Registrieren, Anmelden, Geraete-Abgleich (POST /api/sync/push) gegen einen echten uvicorn mit mehreren Prozessen, lokal.

    .venv/bin/python tools/lasttest-anmeldung.py --label nachher
    .venv/bin/python tools/lasttest-anmeldung.py --repo /pfad/zum/alten/stand --env LERNAPP_LIMIT_REGISTER_IP=300/60 --label vorher
    .venv/bin/python tools/lasttest-anmeldung.py --register 1000 --logins 4000 --syncs 4000 --workers 4 --parallel 64 --json ergebnis.json
    .venv/bin/python tools/lasttest-anmeldung.py --register 500 --logins 0 --syncs 0 --mixed 0 --uploads 2000 --upload-mb 5

Ablauf: Dienst starten (uvicorn --workers N, Temp-Datenordner, Mail nur ins Protokoll) -> `--register` Konten anlegen,
ALLE mit derselben Client-Adresse (X-Forwarded-For; uvicorn laeuft wie im Container mit --proxy-headers) -> `--logins`
Anmeldungen (davon `--wrong-pct` Prozent mit falschem Passwort, wie Tippfehler im Hoersaal) -> `--syncs` Abgleiche mit
Sitzungstoken -> Mischphase (alles gleichzeitig) -> optional `--uploads` PDF-Uploads (POST /api/notebooks, je
`--upload-mb`, Audit Paket 50-54) -> Tabelle mit p50/p95/max, Fehler je Status und Speicher der Prozesse.
Nur Standardbibliothek (urllib, Threads) + requirements.txt des Dienstes. Ergebnisse: docs/release/LAUNCH-4000-2026-11-08.md.
Mit --repo laeuft ein anderer Code-Stand (z. B. `git archive develop | tar -x -C /tmp/vorher`), damit vorher/nachher
mit demselben Werkzeug gemessen werden; --env NAME=WERT setzt Umgebungswerte des Dienstes (mehrfach erlaubt).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import resource
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PASSWORD = "sehr-geheim-123"
CAMPUS_IP = "130.75.1.1"          # eine Adresse fuer alle (NAT der Hochschule)


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(p * (len(s) - 1)))]


def ms(v: float) -> str:
    return f"{v * 1000:.0f}"


def children(pid: int) -> list[int]:
    try:
        out = subprocess.run(["ps", "-ax", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    except Exception:  # noqa: BLE001
        return []
    kids = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == str(pid):
            kids.append(int(parts[0]))
    return kids


def rss_mb(pids: list[int]) -> list[float]:
    out = []
    for pid in pids:
        try:
            kb = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout.strip()
            out.append(round(int(kb) / 1024, 1))
        except Exception:  # noqa: BLE001
            pass
    return out


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Dienst:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a = a
        self.repo = Path(a.repo).resolve() if a.repo else ROOT
        self.tmp = Path(tempfile.mkdtemp(prefix="lasttest-anmeldung-"))
        self.port = a.port or free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.proc: subprocess.Popen | None = None

    def env(self) -> dict:
        e = {k: v for k, v in os.environ.items() if not k.startswith("LERNAPP_")}
        e.update({
            "LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": str(self.tmp / "data"), "LERNAPP_LOG_DIR": str(self.tmp / "logs"),
            "LERNAPP_JOBS": "off", "LERNAPP_NO_SCHEDULER": "1", "LERNAPP_MAIL": "log", "LERNAPP_OCR": "off",
            "LERNAPP_ALLOWED_HOSTS": "127.0.0.1", "LERNAPP_SECRET_KEY": "lasttest-" + uuid.uuid4().hex,
            "LERNAPP_AI_PROVIDER": "none",
            "WEB_CONCURRENCY": str(self.a.workers), "PYTHONUNBUFFERED": "1",
        })
        for kv in self.a.env:
            k, _, v = kv.partition("=")
            e[k.strip()] = v.strip()
        return e

    def start(self) -> None:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        want = min(hard if hard != resource.RLIM_INFINITY else 1 << 16, 1 << 16)
        if soft < want:
            try:
                resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            except (ValueError, OSError):
                pass
        log = open(self.tmp / "dienst.log", "wb")
        self.proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.server:app", "--host", "127.0.0.1", "--port", str(self.port),
                                      "--workers", str(self.a.workers), "--no-access-log", "--backlog", "4096", "--log-level", "warning",
                                      "--proxy-headers", "--forwarded-allow-ips=*"],
                                     cwd=str(self.repo), env=self.env(), stdout=log, stderr=log)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                st, _, _ = self.call("GET", "/api/account/info")
                if st == 200:
                    return
            except Exception:  # noqa: BLE001
                pass
            if self.proc.poll() is not None:
                break
            time.sleep(0.3)
        raise SystemExit(f"Dienst startet nicht: {(self.tmp / 'dienst.log').read_text(errors='replace')[-2000:]}")

    def stop(self) -> None:
        if self.proc is not None:
            try:
                self.proc.send_signal(signal.SIGTERM)
                self.proc.wait(20)
            except Exception:  # noqa: BLE001
                self.proc.kill()
        if not self.a.keep:
            shutil.rmtree(self.tmp, ignore_errors=True)

    def worker_pids(self) -> list[int]:
        assert self.proc is not None
        return children(self.proc.pid) or [self.proc.pid]

    def call(self, method: str, path: str, body: dict | None = None, token: str | None = None, ip: str = CAMPUS_IP,
             raw: bytes | None = None, ctype: str = "application/json") -> tuple[int, float, bytes]:
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", ctype)
        req.add_header("X-Forwarded-For", ip)                   # Campus-NAT: alle hinter einer Adresse
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return r.status, time.monotonic() - t0, raw
        except urllib.error.HTTPError as e:
            return e.code, time.monotonic() - t0, e.read()
        except Exception:  # noqa: BLE001 - Verbindungsabbruch, Zeitlimit
            return 0, time.monotonic() - t0, b""


# ---------------------------------------------------------------- Phasen

class Lauf:
    def __init__(self, d: Dienst, a: argparse.Namespace) -> None:
        self.d, self.a = d, a
        self.tokens: list[str] = []
        self.emails: list[str] = []
        self.rnd = random.Random(42)

    def phase(self, name: str, n: int, fn, parallel: int) -> dict:
        t_wall = time.monotonic()
        with ThreadPoolExecutor(max_workers=parallel) as ex:
            res = list(ex.map(fn, range(n)))
        wall = time.monotonic() - t_wall
        status: dict[str, int] = {}
        lat_ok, lat_all = [], []
        for st, dt, expected in res:
            key = str(st)
            status[key] = status.get(key, 0) + 1
            lat_all.append(dt)
            if st in expected:
                lat_ok.append(dt)
        ok = sum(v for k, v in status.items() if int(k) in fn.expected)
        out = {"name": name, "n": n, "parallel": parallel, "wall_s": round(wall, 2), "per_s": round(n / wall, 1) if wall else None,
               "ok": ok, "errors": n - ok, "status": dict(sorted(status.items())),
               "p50_ms": round(pct(lat_ok, 0.5) * 1000), "p95_ms": round(pct(lat_ok, 0.95) * 1000), "max_ms": round(max(lat_all or [0]) * 1000),
               "rss_mb": rss_mb(self.d.worker_pids())}
        print(f"  {name:<34} n={n:<5} ok={ok:<5} Fehler={n - ok:<5} p50={out['p50_ms']:>5} ms  p95={out['p95_ms']:>5} ms  max={out['max_ms']:>6} ms  "
              f"{out['per_s']}/s  Status {out['status']}", flush=True)
        return out

    # -- Registrieren: alle von derselben Adresse
    def register_one(self, i: int):
        email = f"campus{i:05d}@beispiel.de"
        st, dt, raw = self.d.call("POST", "/api/account/register", {"email": email, "password": PASSWORD, "university": "luh"})
        if st == 201:
            try:
                self.tokens.append(json.loads(raw)["token"])
                self.emails.append(email)
            except (ValueError, KeyError):
                pass
        return st, dt, (201,)
    register_one.expected = (201,)

    # -- Anmelden: ein Teil tippt falsch
    def login_one(self, i: int):
        if not self.emails:
            return 0, 0.0, (200,)
        email = self.emails[i % len(self.emails)]
        wrong = self.rnd.random() * 100 < self.a.wrong_pct
        st, dt, _ = self.d.call("POST", "/api/account/login", {"email": email, "password": "tippfehler-123" if wrong else PASSWORD,
                                                               "device_id": f"d{i}", "device_name": "Lasttest"})
        return st, dt, (401,) if wrong else (200,)
    login_one.expected = (200, 401)

    # -- Abgleich: drei neue Module je Geraet (Vertrag G2: items = [{entity, local_id < 0, data}])
    def sync_one(self, i: int):
        if not self.tokens:
            return 0, 0.0, (200,)
        tok = self.tokens[i % len(self.tokens)]
        items = [{"entity": "modules", "local_id": -(i * 10 + k + 1), "data": {"name": f"Modul {i}-{k}"}} for k in range(3)]
        st, dt, _ = self.d.call("POST", "/api/sync/push", {"device_id": f"d{i % 7}", "items": items, "deletes": []}, token=tok)
        return st, dt, (200,)
    sync_one.expected = (200,)

    def mixed_one(self, i: int):
        k = i % 3
        if k == 0:
            st, dt, exp = self.login_one(i)
            return st, dt, exp
        if k == 1:
            return self.sync_one(i)
        tok = self.tokens[i % len(self.tokens)] if self.tokens else None
        st, dt, _ = self.d.call("GET", "/api/entitlements", token=tok)
        return st, dt, (200,)
    mixed_one.expected = (200, 401)

    # -- Hochladen: eigene PDF als Notizbuch (Platten-Reserve, Kontingent, Nachpruefung alle 8 MB - Audit P28)
    def upload_one(self, i: int):
        if not self.tokens:
            return 0, 0.0, (200,)
        if not hasattr(self, "_pdf"):
            size = max(1, int(self.a.upload_mb * (1 << 20)))
            if self.a.upload_kind == "kaputt":           # beginnt mit %PDF, Rest Datenmuell (abgebrochener Download, Absicht)
                self._pdf = b"%PDF-1.4\n" + os.urandom(size)
            else:                                        # gueltige PDF mit 20 Seiten und einem Anhang dieser Groesse
                import io
                from pypdf import PdfWriter
                w = PdfWriter()
                for _ in range(20):
                    w.add_blank_page(width=595, height=842)
                w.add_attachment("daten.bin", os.urandom(size))
                buf = io.BytesIO()
                w.write(buf)
                self._pdf = buf.getvalue()
        boundary = "----lasttest" + uuid.uuid4().hex
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\npdf\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nSkript {i}\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"s{i}.pdf\"\r\n"
                f"Content-Type: application/pdf\r\n\r\n").encode() + self._pdf + f"\r\n--{boundary}--\r\n".encode()
        st, dt, _ = self.d.call("POST", "/api/notebooks", token=self.tokens[i % len(self.tokens)], raw=body,
                                ctype=f"multipart/form-data; boundary={boundary}")
        return st, dt, (200,)
    upload_one.expected = (200,)

    def run(self) -> dict:
        a = self.a
        print(f"Dienst: {self.d.repo} auf {self.d.base}, {a.workers} Prozesse, Datenordner {self.d.tmp}", flush=True)
        print(f"Umgebung: " + ", ".join(a.env) if a.env else "Umgebung: Standardwerte des Codes", flush=True)
        base_rss = rss_mb(self.d.worker_pids())
        phases = []
        phases.append(self.phase(f"1 Registrieren ({a.register}, eine IP)", a.register, self.register_one, a.parallel))
        phases.append(self.phase(f"2 Anmelden ({a.logins}, {a.wrong_pct:g} % falsch)", a.logins, self.login_one, a.parallel))
        phases.append(self.phase(f"3 Abgleich push ({a.syncs})", a.syncs, self.sync_one, a.parallel))
        phases.append(self.phase(f"4 Gemischt ({a.mixed})", a.mixed, self.mixed_one, a.parallel))
        if a.uploads:
            # waehrenddessen alle 50 ms eine normale Anfrage (Abo-Stand): merkt man die Uploads im Rest des Dienstes?
            import threading
            probe: list[float] = []
            stop = threading.Event()

            def probing():
                tok = self.tokens[0] if self.tokens else None
                while not stop.wait(0.05):
                    st, dt, _ = self.d.call("GET", "/api/entitlements", token=tok)
                    if st == 200:
                        probe.append(dt)
            t = threading.Thread(target=probing, daemon=True)
            t.start()
            phases.append(self.phase(f"5 Hochladen ({a.uploads} x {a.upload_mb:g} MB)", a.uploads, self.upload_one, a.parallel))
            stop.set()
            t.join(70)
            phases[-1]["probe"] = {"n": len(probe), "p50_ms": round(pct(probe, 0.5) * 1000), "p95_ms": round(pct(probe, 0.95) * 1000),
                                   "max_ms": round(max(probe or [0]) * 1000)}
            print(f"  waehrenddessen GET /api/entitlements: {phases[-1]['probe']}", flush=True)
        data_mb = sum(f.stat().st_size for f in (self.d.tmp / "data").rglob("*") if f.is_file()) / 1024 / 1024
        return {"label": a.label, "repo": str(self.d.repo), "workers": a.workers, "parallel": a.parallel, "env": a.env,
                "accounts": len(self.tokens), "phases": phases, "rss_start_mb": base_rss, "data_dir_mb": round(data_mb, 1),
                "python": sys.version.split()[0], "cpus": os.cpu_count()}


def table(r: dict) -> str:
    rows = [f"| Phase ({r['label']}) | n | ok | Fehler | p50 ms | p95 ms | max ms | Anfr./s | Status |", "|---|---|---|---|---|---|---|---|---|"]
    for p in r["phases"]:
        rows.append(f"| {p['name']} | {p['n']} | {p['ok']} | {p['errors']} | {p['p50_ms']} | {p['p95_ms']} | {p['max_ms']} | {p['per_s']} | "
                    f"{', '.join(f'{k}: {v}' for k, v in p['status'].items())} |")
    rss = r["phases"][-1]["rss_mb"] if r["phases"] else []
    rows.append(f"\nKonten: {r['accounts']}; Datenordner {r['data_dir_mb']} MB; RSS je Prozess am Ende: {rss} MB "
                f"(Start {r['rss_start_mb']}); {r['workers']} Prozesse, {r['parallel']} parallele Clients, Python {r['python']}, {r['cpus']} CPUs")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=None, help="Code-Stand, der laufen soll (Standard: dieses Repo)")
    ap.add_argument("--env", action="append", default=[], help="NAME=WERT fuer den Dienst, mehrfach erlaubt")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--parallel", type=int, default=64, help="gleichzeitige Clients")
    ap.add_argument("--register", type=int, default=1000)
    ap.add_argument("--logins", type=int, default=4000)
    ap.add_argument("--wrong-pct", type=float, default=3.0, help="Anteil falscher Passwoerter beim Anmelden")
    ap.add_argument("--syncs", type=int, default=4000)
    ap.add_argument("--mixed", type=int, default=3000)
    ap.add_argument("--uploads", type=int, default=0, help="PDF-Uploads (POST /api/notebooks) nach den anderen Phasen")
    ap.add_argument("--upload-mb", type=float, default=5.0, help="Groesse je Upload in MB")
    ap.add_argument("--upload-kind", choices=("gueltig", "kaputt"), default="gueltig", help="gueltige PDF oder %%PDF + Datenmuell")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--label", default="nachher")
    ap.add_argument("--json", default=None)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    d = Dienst(a)
    d.start()
    try:
        r = Lauf(d, a).run()
    finally:
        d.stop()
    print()
    print(table(r))
    if a.json:
        Path(a.json).write_text(json.dumps(r, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"JSON: {a.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

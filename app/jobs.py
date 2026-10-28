"""Dienst-Jobs im gehosteten Modus: Hochschul-Abgleich und Notenspiegel je Konto.

Warteschlange `sync_jobs` in `accounts.db` (nie in einem Nutzerordner). Arbeiter-Threads holen Jobs atomar ab,
hoechstens ein laufender Job je Konto; jeder Job laeuft im Kontext seines Kontos (Datenordner, Datenbank,
Browser-Profil, Protokolle unter `users/<id>/`, Zugangsdaten aus dem Tresor `app/vault.py`), mit demselben Code wie
im Einzelplatzmodus (`studip_sync.run_sync`, `qis.run`). Zeitplan: `LERNAPP_SYNC_TIMES` (Standard 08:00,15:00,
Ortszeit des Servers) legt fuer jedes Konto mit Zugangsdaten einen Job an; jede Uhrzeit hoechstens einmal am Tag,
auch nach einem Neustart (`schedule_marks`).

Betrieb: im API-Prozess (`LERNAPP_JOBS=inproc`, Standard im gehosteten Modus) oder getrennt mit
`python -m app.jobs` (dann `LERNAPP_JOBS=off` fuer den API-Prozess). `LERNAPP_JOB_WORKERS` (Standard 2) begrenzt die
gleichzeitigen Browser (je etwa 300 MB).
"""
from __future__ import annotations

import os
import threading
import time
from datetime import datetime, timedelta

from . import accounts, config, db, vault

KINDS = {"sync": "Sync", "grades": "Notenspiegel"}
SCHEMA = """
CREATE TABLE IF NOT EXISTS sync_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    kind TEXT NOT NULL,                  -- sync | grades
    trigger TEXT NOT NULL,               -- manual | scheduled
    status TEXT NOT NULL,                -- queued | running | done | failed
    requested_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    message TEXT,
    new_files INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_jobs_user ON sync_jobs(user_id, id);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON sync_jobs(status, id);
CREATE TABLE IF NOT EXISTS schedule_marks (
    slot TEXT PRIMARY KEY,               -- YYYY-MM-DDTHH:MM (Ortszeit)
    created_at TEXT NOT NULL
);
"""


def _now() -> str:
    return accounts.iso(accounts.now())


def _conn():
    cm = accounts.cursor()
    conn = cm.__enter__()
    from . import db
    db.schema_once(conn, "jobs", accounts.db_path(), lambda c: c.executescript(SCHEMA))
    return cm, conn


def _job(r) -> dict | None:
    return dict(r) if r else None


# ---------------------------------------------------------------- Warteschlange

def enqueue(user_id: str, kind: str = "sync", trigger: str = "manual") -> dict:
    """Legt einen Job an; gibt es fuer das Konto schon einen wartenden oder laufenden Job dieser Art, den."""
    if kind not in KINDS:
        raise ValueError("Unbekannte Job-Art")
    cm, conn = _conn()
    try:
        cur = conn.execute("SELECT * FROM sync_jobs WHERE user_id=? AND kind=? AND status IN ('queued','running') ORDER BY id LIMIT 1",
                           (user_id, kind)).fetchone()
        if cur:
            return {**_job(cur), "already": True}
        c = conn.execute("INSERT INTO sync_jobs(user_id, kind, trigger, status, requested_at) VALUES (?,?,?,'queued',?)",
                         (user_id, kind, trigger, _now()))
        return {**_job(conn.execute("SELECT * FROM sync_jobs WHERE id=?", (c.lastrowid,)).fetchone()), "already": False}
    finally:
        cm.__exit__(None, None, None)


def latest(user_id: str, kind: str | None = None) -> dict | None:
    cm, conn = _conn()
    try:
        if kind:
            return _job(conn.execute("SELECT * FROM sync_jobs WHERE user_id=? AND kind=? ORDER BY id DESC LIMIT 1", (user_id, kind)).fetchone())
        return _job(conn.execute("SELECT * FROM sync_jobs WHERE user_id=? ORDER BY id DESC LIMIT 1", (user_id,)).fetchone())
    finally:
        cm.__exit__(None, None, None)


def recent(user_id: str, limit: int = 20) -> list[dict]:
    cm, conn = _conn()
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM sync_jobs WHERE user_id=? ORDER BY id DESC LIMIT ?", (user_id, limit))]
    finally:
        cm.__exit__(None, None, None)


def queue_position(job_id: int) -> int:
    cm, conn = _conn()
    try:
        return conn.execute("SELECT COUNT(*) FROM sync_jobs WHERE status='queued' AND id<?", (job_id,)).fetchone()[0]
    finally:
        cm.__exit__(None, None, None)


def bg_state(user_id: str) -> dict:
    """Gleiche Form wie `_bg_state` im Einzelplatzmodus, dazu der letzte Job."""
    j = latest(user_id)
    if not j:
        return {"running": False, "task": None, "message": "", "job": None}
    running = j["status"] in ("queued", "running")
    msg = j["message"] or ""
    if j["status"] == "queued":
        msg = f"{KINDS[j['kind']]}: wartet (Platz {queue_position(j['id']) + 1})"
    elif j["status"] == "running":
        msg = f"{KINDS[j['kind']]}: laeuft seit {j['started_at']}"
    return {"running": running, "task": KINDS[j["kind"]] if running else None, "message": msg, "job": j}


def claim_next() -> dict | None:
    """Naechsten wartenden Job atomar uebernehmen; Konten mit laufendem Job werden uebersprungen."""
    cm, conn = _conn()
    try:
        conn.execute("BEGIN IMMEDIATE")
        r = conn.execute("""SELECT id FROM sync_jobs WHERE status='queued'
                            AND user_id NOT IN (SELECT user_id FROM sync_jobs WHERE status='running') ORDER BY id LIMIT 1""").fetchone()
        if not r:
            return None
        conn.execute("UPDATE sync_jobs SET status='running', started_at=? WHERE id=? AND status='queued'", (_now(), r["id"]))
        return _job(conn.execute("SELECT * FROM sync_jobs WHERE id=?", (r["id"],)).fetchone())
    finally:
        cm.__exit__(None, None, None)


def _finish(job_id: int, ok: bool, message: str, new_files: int = 0) -> None:
    cm, conn = _conn()
    try:
        conn.execute("UPDATE sync_jobs SET status=?, finished_at=?, message=?, new_files=? WHERE id=?",
                     ("done" if ok else "failed", _now(), message[:2000], new_files, job_id))
    finally:
        cm.__exit__(None, None, None)


def recover_stale(max_hours: float = 6) -> int:
    """Nach einem Neustart: Jobs, die laut Tabelle noch laufen, aber zu alt sind, als fehlgeschlagen abschliessen."""
    cutoff = accounts.iso(accounts.now() - timedelta(hours=max_hours))
    cm, conn = _conn()
    try:
        return conn.execute("UPDATE sync_jobs SET status='failed', finished_at=?, message='Abgebrochen (Dienst neu gestartet)' "
                            "WHERE status='running' AND started_at<=?", (_now(), cutoff)).rowcount
    finally:
        cm.__exit__(None, None, None)


# ---------------------------------------------------------------- Ausfuehrung im Kontext des Kontos

def run_job(job: dict) -> dict:
    """Fuehrt einen uebernommenen Job aus (im aufrufenden Thread) und schliesst ihn ab."""
    user = accounts.get_user(job["user_id"])
    if not user or accounts.get_user(job["user_id"]) is None:
        _finish(job["id"], False, "Konto nicht gefunden")
        return {"ok": False, "message": "Konto nicht gefunden"}
    ok, message, new_files = False, "", 0
    t_user = config.set_user_context(user["id"], user["university"])
    t_env = config.set_env_context(vault.env_for(user["id"]))
    try:
        db.init_db()
        if job["kind"] == "sync":
            from . import studip_sync
            res = studip_sync.run_sync()
            ok, message, new_files = bool(res.get("ok")), res.get("message") or "", len(res.get("new_files") or [])
        else:
            from . import qis
            res = qis.run(show_browser=False)
            ok, message = bool(res.get("ok")), res.get("message") or ""
    except Exception as e:  # noqa: BLE001 - ein Job darf den Arbeiter nie beenden
        ok, message = False, f"FEHLER: {e}"
    finally:
        config.reset_env_context(t_env)
        config.reset_user_context(t_user)
    _finish(job["id"], ok, message, new_files)
    return {"ok": ok, "message": message, "new_files": new_files}


def work_once() -> bool:
    job = claim_next()
    if not job:
        return False
    run_job(job)
    return True


# ---------------------------------------------------------------- Zeitplan

def sync_times() -> list[str]:
    raw = os.environ.get("LERNAPP_SYNC_TIMES", "08:00,15:00")
    out = []
    for t in raw.split(","):
        t = t.strip()
        if len(t) == 5 and t[2] == ":" and t[:2].isdigit() and t[3:].isdigit() and int(t[:2]) < 24 and int(t[3:]) < 60:
            out.append(t)
    return sorted(set(out))


def due_slots(now: datetime, times: list[str] | None = None) -> list[str]:
    """Zeitfenster des heutigen Tages, die schon erreicht sind: 'YYYY-MM-DDTHH:MM'."""
    day = now.strftime("%Y-%m-%d")
    return [f"{day}T{t}" for t in (times if times is not None else sync_times()) if now.strftime("%H:%M") >= t]


def schedule_due(now: datetime | None = None, times: list[str] | None = None) -> int:
    """Fuer jedes erreichte, noch nicht bearbeitete Zeitfenster einen Abgleich je Konto mit Zugangsdaten anlegen."""
    now = now or datetime.now()
    n = 0
    for slot in due_slots(now, times):
        cm, conn = _conn()
        try:
            if conn.execute("SELECT 1 FROM schedule_marks WHERE slot=?", (slot,)).fetchone():
                continue
            conn.execute("INSERT INTO schedule_marks(slot, created_at) VALUES (?,?)", (slot, _now()))
        finally:
            cm.__exit__(None, None, None)
        for uid, _uni in vault.users_with_credentials():
            if not enqueue(uid, "sync", "scheduled")["already"]:
                n += 1
    return n


# ---------------------------------------------------------------- Hintergrundbetrieb

class Runner:
    def __init__(self, workers: int = 2, poll_seconds: float = 5.0):
        self.workers, self.poll = max(1, workers), poll_seconds
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

    def _worker(self) -> None:
        while not self._stop.is_set():
            try:
                if not work_once():
                    self._stop.wait(self.poll)
            except Exception as e:  # noqa: BLE001
                print(f"[jobs] Arbeiter-Fehler: {e}")
                self._stop.wait(self.poll)

    def _scheduler(self) -> None:
        from . import retention
        while not self._stop.is_set():
            try:
                schedule_due()
            except Exception as e:  # noqa: BLE001
                print(f"[jobs] Zeitplan-Fehler: {e}")
            try:
                retention.schedule_due()                   # Loeschfristen einmal taeglich (app/retention.py)
            except Exception as e:  # noqa: BLE001
                print(f"[jobs] Loeschfristen-Fehler: {e}")
            self._stop.wait(30)

    def start(self) -> None:
        recover_stale()
        for i in range(self.workers):
            t = threading.Thread(target=self._worker, name=f"uniflow-job-{i}", daemon=True)
            t.start()
            self._threads.append(t)
        s = threading.Thread(target=self._scheduler, name="uniflow-schedule", daemon=True)
        s.start()
        self._threads.append(s)

    def stop(self) -> None:
        self._stop.set()


_runner: Runner | None = None


def start_background() -> Runner | None:
    """Im API-Prozess, wenn LERNAPP_MODE=hosted und LERNAPP_JOBS nicht 'off' ist."""
    global _runner
    if _runner or not config.is_hosted() or (os.environ.get("LERNAPP_JOBS") or "inproc").lower() == "off":
        return None
    _runner = Runner(workers=int(os.environ.get("LERNAPP_JOB_WORKERS") or 2))
    _runner.start()
    return _runner


def main() -> int:
    """python -m app.jobs: Arbeiter und Zeitplan als eigener Prozess."""
    if not config.is_hosted():
        print("Nur im gehosteten Modus (LERNAPP_MODE=hosted).")
        return 2
    r = Runner(workers=int(os.environ.get("LERNAPP_JOB_WORKERS") or 2))
    r.start()
    print(f"[jobs] {r.workers} Arbeiter, Zeitplan {', '.join(sync_times())} – Strg+C beendet")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        r.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

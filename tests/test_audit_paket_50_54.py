"""Audit-Pakete 50 bis 54 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-50-54.md): Last, KI-Kosten und
Dokumentenindex (P50), Server/SQLite/Jobs (P51), Datenbanklast und Datenintegritaet (P52), Durchsatz und
Ueberlastschutz (P53), 4.000/100.000 Nutzer, Ausfaelle (P54). Ziel: bis 15.11.2026 bis zu 4.000 Nutzer auf EINEM
Server (CPX42, 12 uvicorn-Prozesse, ein Job-Container, eine accounts.db).

Jeder Test traegt die Befundnummer. "Festgenagelt" heisst: Verhalten war schon richtig und bleibt es."""
import asyncio
import hashlib
import importlib.util
import io
import json
import multiprocessing as mp
import os
import sqlite3
import sys
import tarfile
import threading
import time
from pathlib import Path

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_security import _multipart

ROOT = Path(__file__).resolve().parents[1]


def _pdf() -> bytes:
    from pypdf import PdfWriter
    w = PdfWriter()
    w.add_blank_page(width=200, height=200)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def _index_upload(app, headers, pdf):
    body, ctype = _multipart("upload", "a.pdf", pdf, {"file_sha": hashlib.sha256(pdf).hexdigest()})
    st, _, b = asgi_call(app, "POST", "/api/index/file", body=body, content_type=ctype, headers=headers)
    return st, (json.loads(b) if b else None)


@pytest.fixture
def clean_index():
    import shutil
    from app import doc_index
    shutil.rmtree(doc_index.upload_dir(), ignore_errors=True)
    yield doc_index
    shutil.rmtree(doc_index.upload_dir(), ignore_errors=True)


# ================================================================== P50: Dokumentenindex im Dienst

def test_p50_index_upload_keeps_the_disk_reserve(hosted, clean_index, monkeypatch):  # noqa: F811
    """POST /api/index/file legt bis 60 MB je Anfrage fuer 15 Minuten auf die Platte, pruefte aber als einziger
    Upload-Weg die Platten-Reserve nicht (LAUNCH-4000 1.2): ein Konto konnte die Platte fuellen - dann schreibt
    auch accounts.db nicht mehr, fuer alle 4.000 Konten."""
    from app import server
    _, h = _user(hosted, "index-platte@beispiel.de")
    monkeypatch.setattr(server, "disk_free_bytes", lambda p: 50 << 20)              # nur 50 MB frei
    st, d = _index_upload(hosted, h, _pdf())
    assert st == 507 and d["code"] == "storage_full", d
    assert not any(clean_index.upload_dir().glob("*/upload.*")), "nichts auf der Platte gelassen"
    monkeypatch.setattr(server, "disk_free_bytes", lambda p: 500 << 30)
    st, d = _index_upload(hosted, h, _pdf())
    assert st == 202, d


def test_p50_index_upload_open_jobs_per_account_are_capped(hosted, clean_index):  # noqa: F811
    """Kein Client ruft den Endpunkt heute auf (das iPad indexiert auf dem Geraet, analyze_page ist Geruest) - jede
    Datei liegt also volle 15 Minuten. Ohne Grenze je Konto: 300 Anfragen/min je Prozess x 12 Prozesse x 60 MB."""
    _, h = _user(hosted, "index-viel@beispiel.de")
    _, h2 = _user(hosted, "index-anderes@beispiel.de")
    pdf = _pdf()
    for _ in range(clean_index.MAX_OPEN_PER_ACCOUNT):
        st, d = _index_upload(hosted, h, pdf)
        assert st == 202, d
    st, d = _index_upload(hosted, h, pdf)
    assert st == 429 and d["code"] == "index_busy", d
    assert len(list(clean_index.upload_dir().glob("*/upload.*"))) == clean_index.MAX_OPEN_PER_ACCOUNT
    st, d = _index_upload(hosted, h2, pdf)
    assert st == 202, "ein anderes Konto ist nicht betroffen"
    # nach der Loeschfrist (oder Verarbeitung) ist wieder Platz
    clean_index.purge_expired(minutes=0)
    st, d = _index_upload(hosted, h, pdf)
    assert st == 202, d


def test_p50_index_purge_does_not_run_in_the_event_loop(hosted, clean_index, monkeypatch):  # noqa: F811
    """purge_expired liest jeden Auftragsordner (gemessen 0,1 ms je Ordner: 1.000 Ordner 103 ms, 10.000 1,3 s) und
    lief nach jedem Upload in der Ereignisschleife - so lange standen alle Anfragen des Prozesses."""
    _, h = _user(hosted, "index-schleife@beispiel.de")
    seen = []
    real = clean_index.purge_expired

    def spy(*a, **k):
        try:
            asyncio.get_running_loop()
            seen.append("schleife")
        except RuntimeError:
            seen.append("thread")
        return real(*a, **k)
    monkeypatch.setattr(clean_index, "purge_expired", spy)
    st, d = _index_upload(hosted, h, _pdf())
    assert st == 202, d
    assert seen and "schleife" not in seen, seen


# ================================================================== P51/P52: Job-Container nach einem Absturz

def test_p51_08_jobs_process_frees_jobs_left_running_by_a_killed_predecessor(hosted, monkeypatch, tmp_path):  # noqa: F811
    """`python -m app.jobs` wird hart beendet (OOM, SIGKILL, Stromausfall): `Runner.stop` laeuft nicht, der Job bleibt
    'running'. recover_stale gab beim Start nur Jobs frei, die aelter als 6 h sind - bis dahin (und weil es nur beim
    Start laeuft, bis zum naechsten Neustart) bekam das Konto keinen Wochentest-Job mehr: claim_next ueberspringt
    Konten mit laufendem Job, enqueue meldet 'already'. Der Job-Container laeuft genau einmal (docker-compose.yml):
    alles, was bei seinem Start 'running' ist, gehoert einem toten Vorgaenger."""
    from app import accounts, config, jobs, retention
    monkeypatch.setattr(config, "BASE_LOG_DIR", tmp_path / "logs")
    monkeypatch.setenv("LERNAPP_JOB_WORKERS", "1")
    monkeypatch.setenv("LERNAPP_SYNC_TIMES", "")
    monkeypatch.setattr(retention, "schedule_due", lambda *a, **k: None)
    u = accounts.register("absturz@beispiel.de", "sehr-geheim-123", "luh")
    j = jobs.enqueue(u["id"], "weekly", "scheduled")
    assert jobs.claim_next()["id"] == j["id"]                       # der Vorgaenger hat ihn uebernommen ... und stirbt
    assert jobs.enqueue(u["id"], "weekly", "scheduled")["already"]
    stop = threading.Event()
    stop.set()
    assert jobs.main([], stop_event=stop) == 0                      # neuer Job-Container startet
    got = jobs.latest(u["id"])
    assert got["id"] == j["id"] and got["status"] == "failed" and "neu gestartet" in got["message"], got
    again = jobs.enqueue(u["id"], "weekly", "scheduled")
    assert not again["already"], "das Konto bekommt wieder Wochentest-Jobs"


def test_p52_08_four_thousand_queued_jobs_are_each_claimed_exactly_once(hosted):  # noqa: F811
    """Ein Zeitfenster (08:00/15:00) legt je aktivem Konto einen weekly-Job an: 4.000 Jobs. Vier Arbeiter holen sie
    gleichzeitig (BEGIN IMMEDIATE): keiner doppelt, keiner verloren; Zeit je Uebernahme + Abschluss gemessen."""
    from app import accounts, jobs
    n = 4000
    now = accounts.iso(accounts.now())
    with accounts.cursor() as conn:
        conn.executemany("INSERT INTO users(id, email, university, created_at) VALUES (?,?,?,?)",
                         [(f"{i:032x}", f"j{i}@beispiel.de", "luh", now) for i in range(n)])
    t0 = time.perf_counter()
    assert jobs.schedule_due(now=__import__("datetime").datetime(2026, 11, 9, 8, 1), times=["08:00"]) == n
    t_schedule = time.perf_counter() - t0
    claimed: list[int] = []
    lock = threading.Lock()
    errors: list[Exception] = []

    def worker():
        try:
            while True:
                job = jobs.claim_next()
                if not job:
                    return
                with lock:
                    claimed.append(job["id"])
                jobs._finish(job["id"], True, "ok")
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    t0 = time.perf_counter()
    ts = [threading.Thread(target=worker) for _ in range(4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(300)
    dt = time.perf_counter() - t0
    assert not errors, errors[:3]
    assert len(claimed) == n and len(set(claimed)) == n, (len(claimed), len(set(claimed)))
    print(f"\n[P52-08] Fenster anlegen {t_schedule:.2f} s; 4.000 Uebernahmen+Abschluesse mit 4 Arbeitern {dt:.1f} s "
          f"({dt / n * 1000:.2f} ms je Job)")
    assert dt < 120, "Warteschlange selbst ist kein Engpass (gemessen ~10-25 s auf dem Mac)"


# ================================================================== P51-10/P52-10: Backup waehrend der Last

def _backup_module():
    spec = importlib.util.spec_from_file_location("backup_snapshot_p5054", ROOT / "deploy" / "backup_snapshot.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _run_backup(monkeypatch, data: Path) -> tuple[int, list[str]]:
    import runpy
    monkeypatch.setenv("LERNAPP_DATA_DIR", str(data))
    buf = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", type("S", (), {"buffer": buf, "write": lambda s, t: None, "flush": lambda s: None})())
    with pytest.raises(SystemExit) as e:
        runpy.run_path(str(ROOT / "deploy" / "backup_snapshot.py"), run_name="__main__")
    names = tarfile.open(fileobj=io.BytesIO(buf.getvalue()), mode="r:gz").getnames() if buf.getvalue() else []
    return e.value.code, names


def _small_db(p: Path) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(p)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE t(x)")
    c.execute("INSERT INTO t VALUES (1)")
    c.commit()
    c.close()


def test_p51_10_backup_survives_files_that_vanish_while_it_runs(tmp_path, monkeypatch):
    """Das Backup laeuft, waehrend der Dienst arbeitet: zwischen os.walk und dem Kopieren loescht der Dienst Dateien
    (Index-Uploads nach 15 Minuten, ersetzte Assets, ein Konto zieht nach users-deleted/ um). Vorher brach das GANZE
    Backup mit FileNotFoundError bzw. 'unable to open database file' ab - kein Archiv an diesem Tag."""
    data = tmp_path / "data"
    _small_db(data / "accounts.db")
    (data / "users" / "a").mkdir(parents=True)
    (data / "users" / "a" / "notiz.txt").write_text("bleibt")
    real_walk = os.walk

    def walk(top, *a, **k):
        for root, dirs, files in real_walk(top, *a, **k):
            if Path(root) == data / "users" / "a":
                files = list(files) + ["weg.png", "weg.db"]          # beim Auflisten da, beim Kopieren schon geloescht
            yield root, dirs, files
    monkeypatch.setattr(os, "walk", walk)
    code, names = _run_backup(monkeypatch, data)
    assert code == 0
    assert "uniflow-data/accounts.db" in names and "uniflow-data/users/a/notiz.txt" in names
    assert not any("weg." in n for n in names)


def test_p51_10_backup_leaves_out_index_uploads(tmp_path, monkeypatch):
    """Index-Uploads duerfen hoechstens 15 Minuten beim Dienst liegen (app/doc_index.py). Ein Backup um 03:30 nahm
    eine gerade hochgeladene PDF mit in die 14 Tage aufbewahrten Archive."""
    data = tmp_path / "data"
    _small_db(data / "accounts.db")
    job = data / "index-uploads" / ("a" * 32)
    job.mkdir(parents=True)
    (job / "upload.pdf").write_bytes(b"%PDF-1.4 Skript")
    (job / "meta.json").write_text("{}")
    code, names = _run_backup(monkeypatch, data)
    assert code == 0 and "uniflow-data/accounts.db" in names
    assert not any("index-uploads" in n for n in names), names


def test_p52_10_backup_of_accounts_db_under_write_load_is_consistent(tmp_path):
    """Festgenagelt: die SQLite-Backup-API kopiert accounts.db in EINEM Schritt (pages=-1) unter einer Lesesperre -
    WAL-Schreiber laufen weiter, die Kopie startet nicht neu und ist konsistent (integrity_check, alle vorher
    bestaetigten Zeilen enthalten)."""
    mod = _backup_module()
    src = tmp_path / "accounts.db"
    c = sqlite3.connect(src)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE log(id INTEGER PRIMARY KEY, v TEXT)")
    c.executemany("INSERT INTO log(v) VALUES (?)", [("x" * 200,)] * 20000)
    c.commit()
    c.close()
    stop = threading.Event()
    written = [0]

    def writer():
        w = sqlite3.connect(src, timeout=15)
        w.execute("PRAGMA synchronous=NORMAL")
        while not stop.is_set():
            w.execute("INSERT INTO log(v) VALUES ('neu')")
            w.commit()
            written[0] += 1
        w.close()
    t = threading.Thread(target=writer)
    t.start()
    try:
        time.sleep(0.2)
        for n in range(5):
            before = written[0]
            t0 = time.perf_counter()
            snap = mod.snapshot_db(src, tmp_path, n)
            dt = time.perf_counter() - t0
            s = sqlite3.connect(snap)
            assert s.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert s.execute("SELECT COUNT(*) FROM log").fetchone()[0] >= 20000 + before
            s.close()
            snap.unlink()
            assert dt < 10, dt
    finally:
        stop.set()
        t.join(30)
    assert written[0] > 0, "der Schreiber lief waehrend der Kopien weiter"


# ================================================================== P52: Transaktionen, Indizes, KI-Abrechnung

def test_p52_f3_accounts_cursor_rolls_back_on_error(hosted):  # noqa: F811
    """Festgenagelt: accounts.cursor schreibt nur beim normalen Verlassen fest; eine Ausnahme verwirft alles der
    Transaktion (close ohne commit = ROLLBACK). Gewollte Ausnahme: _hit schreibt den Zaehler vorher fest."""
    from app import accounts
    with pytest.raises(RuntimeError):
        with accounts.cursor() as conn:
            conn.execute("INSERT INTO users(id, email, university, created_at) VALUES ('r1','r1@beispiel.de','luh','2026')")
            conn.execute("INSERT INTO users(id, email, university, created_at) VALUES ('r2','r2@beispiel.de','luh','2026')")
            raise RuntimeError("Fehler mitten im Schreibweg")
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users WHERE id IN ('r1','r2')").fetchone()[0] == 0


def test_p52_11_hot_queries_on_accounts_db_use_an_index(hosted):  # noqa: F811
    """Festgenagelt (EXPLAIN QUERY PLAN): die Abfragen, die je Anfrage, je KI-Frage oder je Job laufen, lesen ueber
    einen Index - keine wachsende Tabelle (Sitzungen, KI-Protokoll, Credits, Jobs) wird ganz durchsucht."""
    from app import accounts, ai_backend, billing, credits, jobs
    jobs.latest("x")                                              # Schema der Warteschlange
    conn = ai_backend.connect()
    try:
        credits.ensure_schema(conn)
        billing.ensure_schema(conn)
        hot = {
            "authenticate": ("SELECT s.*, u.status FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?", ("t",)),
            "ki_rate_minute": ("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?", ("u", "2026")),
            "credits_lookup": ("SELECT state, result, charged FROM credit_ledger WHERE user_id=? AND request_id=?", ("u", "r")),
            "credits_stale": ("SELECT period, reserved FROM credit_ledger WHERE user_id=? AND state='reserved' AND created_at<?", ("u", "2026")),
            "job_enqueue": ("SELECT * FROM sync_jobs WHERE user_id=? AND kind=? AND status IN ('queued','running') ORDER BY id LIMIT 1", ("u", "weekly")),
            "job_running": ("SELECT user_id FROM sync_jobs WHERE status='running'", ()),
            "job_queue_position": ("SELECT COUNT(*) FROM sync_jobs WHERE status='queued' AND id<?", (5,)),
            "rate_limits": ("SELECT count, window_start FROM rate_limits WHERE key=?", ("k",)),
        }
        with accounts.cursor() as aconn:
            for name, (sql, args) in hot.items():
                c = aconn if name in ("authenticate", "rate_limits") or name.startswith("job") else conn
                plan = " | ".join(r[3] for r in c.execute("EXPLAIN QUERY PLAN " + sql, args))
                assert "USING" in plan and not any(part.strip().startswith("SCAN ") and "USING" not in part
                                                   for part in plan.split("|")), f"{name}: {plan}"
    finally:
        conn.close()


def test_p52_05_killed_process_after_credit_reservation_neither_loses_nor_double_charges(hosted, monkeypatch):  # noqa: F811
    """Ein API-Prozess stirbt zwischen Reservierung und Ergebnis (OOM, Neustart nach 30 s stop_grace_period): die
    Credits sind reserviert, nie abgebucht. Dieselbe request_id meldet bis zur Frist 409 duplicate_request (kein
    zweiter Anbieteraufruf), danach (credits.STALE_MINUTES) ist die Reservierung frei und derselbe Versuch laeuft
    noch einmal - einmal abgerechnet. Festgenagelt."""
    from datetime import datetime, timedelta, timezone
    from app import ai_backend, credits
    from app import accounts
    u, _ = _user(hosted, "absturz-ki@beispiel.de", plus=False)
    accounts.set_plan(u["id"], "pro_ai")
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "100")
    t0 = datetime(2026, 11, 10, 12, 0, tzinfo=timezone.utc)
    conn = ai_backend.connect()
    try:
        before = credits.balance(conn, u["id"], t0)
        credits.reserve(conn, u["id"], "frage-1", "tutor:explain", 5, t0)          # ... Prozess stirbt hier
        held = credits.balance(conn, u["id"], t0 + timedelta(minutes=1))
        assert held["reserved"] == 5 and held["used"] == before["used"]
        with pytest.raises(credits.CreditsError) as e:
            credits.reserve(conn, u["id"], "frage-1", "tutor:explain", 5, t0 + timedelta(minutes=2))
        assert e.value.status == 409 and e.value.code == "duplicate_request"
        later = t0 + timedelta(minutes=credits.STALE_MINUTES + 1)
        r = credits.reserve(conn, u["id"], "frage-1", "tutor:explain", 5, later)       # Wiederholung nach der Frist
        assert not r.replay and credits.balance(conn, u["id"], later)["reserved"] == 5, "nicht doppelt reserviert"
        credits.settle(conn, u["id"], "frage-1", 20_000, now=later)
        after = credits.balance(conn, u["id"], later)
        assert after["reserved"] == 0 and 0 < after["used"] - before["used"] <= 5, (before, after)
        assert credits.reserve(conn, u["id"], "frage-1", "tutor:explain", 5, later).replay, "fertig: Antwort noch einmal"
    finally:
        conn.close()


# ================================================================== P52-01/P54-09: WAL von accounts.db unter Dauerlast

def _wal_worker(data_dir: str, tokens: list[str], seconds: float, q) -> None:
    os.environ.update({"LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": data_dir, "LERNAPP_NO_SCHEDULER": "1",
                       "LERNAPP_AI_BUDGET_EUR": "100000", "LERNAPP_AI_USER_BUDGET_EUR": "100000",
                       "LERNAPP_AI_RATE_PER_MINUTE": "100000000", "LERNAPP_AI_RATE_PER_HOUR": "100000000"})
    sys.path.insert(0, str(ROOT))
    from app import accounts, ai_backend
    from app.ai_backend import Completion
    n = err = 0
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        n += 1
        try:
            u = accounts.authenticate(tokens[n % len(tokens)])
            if n % 10 == 0:
                conn = ai_backend.connect()
                try:
                    log_id = ai_backend.reserve(conn, u["id"], "tutor:explain")
                    ai_backend.settle(conn, log_id, Completion("x", 1500, 220, "gpt-6-luna"), "openai", "gpt-6-luna")
                finally:
                    conn.close()
        except Exception:  # noqa: BLE001
            err += 1
    accounts.flush_seen()
    q.put((n, err))


def test_p54_09_accounts_db_wal_stays_bounded_under_sustained_multi_process_load(tmp_path):
    """Dauerlast aus mehreren Prozessen (jede Anfrage liest die Sitzung, jede zehnte schreibt den KI-Weg): die
    -wal-Datei waechst nicht unbegrenzt (Auto-Checkpoint bei 1.000 Seiten greift trotz staendiger Leser), keine
    'database is locked'. Volle Messung (12 Prozesse, 120 s) im Bericht; hier 6 Prozesse, 4 s."""
    data = tmp_path / "data"
    env = {"LERNAPP_MODE": "hosted", "LERNAPP_DATA_DIR": str(data)}
    code = ("import os,sys,secrets,json;sys.path.insert(0,%r);from app import accounts,ai_backend;"
            "now=accounts.iso(accounts.now());toks=[]\n"
            "with accounts.cursor() as c:\n"
            "  for i in range(400):\n"
            "    uid='%%032x'%%i;t=secrets.token_urlsafe(16);toks.append(t)\n"
            "    c.execute('INSERT INTO users(id,email,university,created_at) VALUES (?,?,?,?)',(uid,'w%%d@x.de'%%i,'luh',now))\n"
            "    c.execute('INSERT INTO sessions(token_hash,user_id,created_at,last_seen_at,expires_at) VALUES (?,?,?,?,?)',"
            "(accounts._token_hash(t),uid,now,now,'2099-01-01T00:00:00+00:00'))\n"
            "ai_backend.connect().close();print(json.dumps(toks))") % str(ROOT)
    import subprocess
    out = subprocess.run([sys.executable, "-c", code], env={**os.environ, **env}, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    tokens = json.loads(out.stdout.strip().splitlines()[-1])
    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    ps = [ctx.Process(target=_wal_worker, args=(str(data), tokens, 4.0, q)) for _ in range(6)]
    for p in ps:
        p.start()
    wal = data / "accounts.db-wal"
    biggest, res = 0, []
    deadline = time.monotonic() + 120
    while len(res) < len(ps) and time.monotonic() < deadline:
        try:
            res.append(q.get(timeout=0.05))
        except Exception:  # noqa: BLE001 - leer: weiter abtasten
            pass
        try:
            biggest = max(biggest, wal.stat().st_size)
        except OSError:
            pass
    for p in ps:
        p.join(30)
    assert len(res) == len(ps)
    total, errors = sum(r[0] for r in res), sum(r[1] for r in res)
    print(f"\n[P54-09] {total} Anfragen in 4 s aus 6 Prozessen, Fehler {errors}, WAL hoechstens {biggest / 1e6:.1f} MB")
    assert errors == 0
    assert total > 1000
    assert biggest < 64 << 20, f"WAL {biggest / 1e6:.1f} MB"


# ================================================================== P53-07: Ereignisschleife bei Uploads

def test_p53_07_pdf_page_count_of_an_upload_does_not_block_the_event_loop(hosted, monkeypatch):  # noqa: F811
    """POST /api/notebooks ist async; danach zaehlte `len(PdfReader(p).pages)` die Seiten IN der Ereignisschleife.
    Gemessen (pypdf, Mac): 2.000 Seiten 0,3 s, eine kaputte 50-MB-"PDF" (beginnt mit %PDF, Rest Datenmuell) 2,5-9,6 s - so
    lange standen alle Anfragen dieses Prozesses (bei 12 Prozessen ~1/12 aller Nutzer)."""
    import pypdf
    from app import db, server
    monkeypatch.setattr(server, "disk_free_bytes", lambda p: 500 << 30)
    _, h = _user(hosted, "seiten@beispiel.de")
    where = []
    real = pypdf.PdfReader

    class Spy(real):
        def __init__(self, *a, **k):
            try:
                asyncio.get_running_loop()
                where.append("schleife")
            except RuntimeError:
                where.append("thread")
            super().__init__(*a, **k)
    monkeypatch.setattr(pypdf, "PdfReader", Spy)
    body, ctype = _multipart("upload", "s.pdf", _pdf(), {"kind": "pdf", "title": "Skript"})
    st, _, b = asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h, content_type=ctype)
    assert st == 200, b[:300]
    assert where == ["thread"], where
    fid = json.loads(b)["id"]
    from app import config, accounts
    u = accounts.authenticate(h["Authorization"].split()[1])
    tok = config.set_user_context(u["id"], u["university"])
    try:
        with db.cursor() as conn:
            assert conn.execute("SELECT page_count FROM files WHERE id=?", (fid,)).fetchone()[0] == 1
    finally:
        config.reset_user_context(tok)


def test_p53_07_truncated_pdf_is_not_searched_through(tmp_path):
    """Kaputte "PDF" ohne %%EOF (abgebrochener Download): pypdf suchte die Marke rueckwaerts durch die ganze Datei
    (50 MB: 2,5 s CPU unter dem GIL). Jetzt sofort None; gueltige PDFs zaehlen wie bisher."""
    from app import server
    junk = tmp_path / "kaputt.pdf"
    junk.write_bytes(b"%PDF-1.4\n" + os.urandom(20 << 20))
    t0 = time.perf_counter()
    assert server._pdf_page_count(junk) is None
    assert time.perf_counter() - t0 < 0.5
    good = tmp_path / "gut.pdf"
    good.write_bytes(_pdf())
    assert server._pdf_page_count(good) == 1

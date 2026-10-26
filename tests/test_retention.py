"""Loeschfristen (app/retention.py): Zugriffsprotokoll je Tag nur im Dienst (14 Tage), Abgleich-Protokolle und
sync_log je Konto 90 Tage (Logdateien zeilenweise gekuerzt), Jobs/Sitzungen/Token/Zaehler in accounts.db, Konten
30 Tage nach Loeschung, Probelauf ohne Wirkung, einmal taeglich ab 04:00 im Zeitplan, Kommandozeile."""
import json
import os
import sqlite3
import time
from datetime import datetime, timedelta, timezone

import pytest
from conftest import asgi_call


@pytest.fixture
def hosted(app, monkeypatch, tmp_path):
    from app import accounts, config, retention, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    vault.reset_master()
    import shutil
    shutil.rmtree(retention.access_log_dir(), ignore_errors=True)
    (config.BASE_LOG_DIR / "retention.log").unlink(missing_ok=True)
    yield app
    accounts.db_path().unlink(missing_ok=True)
    shutil.rmtree(retention.access_log_dir(), ignore_errors=True)


def _old(path, days):
    t = time.time() - days * 86400
    os.utime(path, (t, t))


# ---------------------------------------------------------------- Zugriffsprotokoll

def test_access_log_written_only_in_hosted_mode_without_query_or_tokens(app, hosted, monkeypatch):
    from app import config, retention
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    f = retention.access_log_dir() / f"access-{today}.log"
    asgi_call(hosted, "GET", "/api/account/info?fingerprint=geheim", headers={"User-Agent": 'Test "Browser"\n', "Authorization": "Bearer abc"})
    asgi_call(hosted, "GET", "/api/settings")                                   # 401 der Sitzungsschicht
    lines = f.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert " GET /api/account/info 200 " in lines[0] and "geheim" not in lines[0] and "abc" not in lines[0]
    assert "Test 'Browser' " in lines[0] and "\n" not in lines[0] and lines[0].startswith(today)
    assert " GET /api/settings 401 " in lines[1]
    monkeypatch.setattr(config, "MODE", "local")
    asgi_call(app, "GET", "/api/settings")
    assert len(f.read_text(encoding="utf-8").splitlines()) == 2, "im Einzelplatzmodus kein Zugriffsprotokoll"


def test_access_logs_older_than_14_days_are_deleted(hosted):
    from app import retention
    d = retention.access_log_dir()
    d.mkdir(parents=True, exist_ok=True)
    now = datetime(2026, 10, 26, 5, 0, tzinfo=timezone.utc)
    for days in (0, 13, 14, 15, 40):
        (d / f"access-{(now - timedelta(days=days)).strftime('%Y-%m-%d')}.log").write_text("x\n")
    (d / "notiz.txt").write_text("bleibt")
    assert retention.purge_access_logs(now.date(), dry_run=True) == 2 and len(list(d.iterdir())) == 6
    assert retention.purge_access_logs(now.date()) == 2
    left = sorted(p.name for p in d.iterdir())
    assert left == ["access-2026-10-12.log", "access-2026-10-13.log", "access-2026-10-26.log", "notiz.txt"]


# ---------------------------------------------------------------- Abgleich-Protokolle und Datenbanken

def test_account_logs_sync_log_and_account_db_follow_the_deadlines(hosted, monkeypatch):
    from app import accounts, config, db, jobs, retention, vault
    u = accounts.register("r@beispiel.de", "sehr-geheim-123", "hildesheim")
    now = datetime.now(timezone.utc)
    t = config.set_user_context(u["id"], "hildesheim")
    try:
        db.init_db()
        logs = config.log_dir()
        with db.cursor() as conn:
            old = (now - timedelta(days=100)).replace(tzinfo=None).isoformat(timespec="seconds")
            new = (now - timedelta(days=5)).replace(tzinfo=None).isoformat(timespec="seconds")
            conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,1,0,'alt')", (old, old))
            conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,1,0,'neu')", (new, new))
    finally:
        config.reset_user_context(t)
    old_day = (now - timedelta(days=95)).strftime("%Y-%m-%d")
    new_day = (now - timedelta(days=2)).strftime("%Y-%m-%d")
    (logs / "sync.log").write_text(f"[{old_day}T08:00:00] alt 1\nFortsetzung alt\n[{new_day}T08:00:00] neu 1\nFortsetzung neu\n", encoding="utf-8")
    (logs / "login-fehler.png").write_bytes(b"png-alt"); _old(logs / "login-fehler.png", 120)
    (logs / "qis-fehler.png").write_bytes(b"png-neu")
    # accounts.db: alter und neuer Job, abgelaufene/beendete Sitzung, verbrauchtes Token, alter Zaehler, altes Merkmal
    vault.set_values(u["id"], {"HILDESHEIM_USER": "x", "HILDESHEIM_PASSWORD": "y"})
    j = jobs.enqueue(u["id"], "sync", "manual"); jobs._finish(j["id"], True, "ok")
    with accounts.cursor() as conn:
        conn.execute("UPDATE sync_jobs SET requested_at=? WHERE id=?", (accounts.iso(now - timedelta(days=91)), j["id"]))
        conn.execute("INSERT INTO sync_jobs(user_id, kind, trigger, status, requested_at) VALUES (?,?,?,?,?)", (u["id"], "sync", "manual", "queued", accounts.iso(now - timedelta(days=200))))
        conn.execute("INSERT INTO schedule_marks(slot, created_at) VALUES ('2026-01-01T08:00', ?)", (accounts.iso(now - timedelta(days=120)),))
        conn.execute("INSERT INTO sessions(token_hash, user_id, created_at, last_seen_at, expires_at) VALUES ('h1', ?, ?, ?, ?)", (u["id"], accounts.iso(now), accounts.iso(now), accounts.iso(now - timedelta(days=1))))
        conn.execute("INSERT INTO sessions(token_hash, user_id, created_at, last_seen_at, expires_at, revoked_at) VALUES ('h2', ?, ?, ?, ?, ?)", (u["id"], accounts.iso(now), accounts.iso(now), accounts.iso(now + timedelta(days=9)), accounts.iso(now)))
        conn.execute("INSERT INTO sessions(token_hash, user_id, created_at, last_seen_at, expires_at) VALUES ('h3', ?, ?, ?, ?)", (u["id"], accounts.iso(now), accounts.iso(now), accounts.iso(now + timedelta(days=9))))
        conn.execute("INSERT INTO reset_tokens(token_hash, user_id, created_at, expires_at, used_at) VALUES ('t1', ?, ?, ?, ?)", (u["id"], accounts.iso(now), accounts.iso(now + timedelta(minutes=5)), accounts.iso(now)))
        conn.execute("INSERT INTO reset_tokens(token_hash, user_id, created_at, expires_at) VALUES ('t2', ?, ?, ?)", (u["id"], accounts.iso(now), accounts.iso(now + timedelta(minutes=5))))
        conn.execute("INSERT INTO login_attempts(key, fails, last_fail_at) VALUES ('email:alt', 3, ?), ('email:neu', 1, ?)", (accounts.iso(now - timedelta(hours=30)), accounts.iso(now)))
    # geloeschtes Konto: eines seit 40 Tagen, eines seit gestern
    for email, days in (("weg@beispiel.de", 40), ("frisch@beispiel.de", 1)):
        d = accounts.register(email, "sehr-geheim-123", "luh")
        accounts.delete_account(d["id"], "sehr-geheim-123")
        with accounts.cursor() as conn:
            conn.execute("UPDATE users SET deleted_at=? WHERE id=?", (accounts.iso(now - timedelta(days=days)), d["id"]))

    probe = retention.run(now, dry_run=True)
    assert probe["dry_run"] and probe["account_logs"] == {"files": 1, "lines": 2, "rows": 1}
    assert (probe["jobs"], probe["marks"], probe["sessions"], probe["reset_tokens"], probe["login_attempts"], probe["accounts_purged"]) == (1, 1, 2, 1, 1, 1)
    assert (logs / "login-fehler.png").exists() and "alt 1" in (logs / "sync.log").read_text(encoding="utf-8"), "Probelauf aendert nichts"

    result = retention.run(now)
    assert {k: result[k] for k in probe if k not in ("dry_run", "at")} == {k: probe[k] for k in probe if k not in ("dry_run", "at")}
    assert not (logs / "login-fehler.png").exists() and (logs / "qis-fehler.png").exists()
    assert (logs / "sync.log").read_text(encoding="utf-8") == f"[{new_day}T08:00:00] neu 1\nFortsetzung neu\n"
    with sqlite3.connect(config.BASE_DATA_DIR / "users" / u["id"] / "unis" / "hildesheim" / "lernapp.db") as c:
        assert [r[0] for r in c.execute("SELECT message FROM sync_log")] == ["neu"]
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM sync_jobs").fetchone()[0] == 1, "wartender Job bleibt, erledigter alter weg"
        assert [r[0] for r in conn.execute("SELECT token_hash FROM sessions ORDER BY token_hash")] == ["h3"]
        assert [r[0] for r in conn.execute("SELECT token_hash FROM reset_tokens")] == ["t2"]
        assert [r[0] for r in conn.execute("SELECT key FROM login_attempts")] == ["email:neu"]
        assert conn.execute("SELECT COUNT(*) FROM users WHERE status='deleted'").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM schedule_marks").fetchone()[0] == 0
    line = (config.BASE_LOG_DIR / "retention.log").read_text(encoding="utf-8").splitlines()[-1]
    assert json.loads(line)["accounts_purged"] == 1
    assert retention.run(now)["account_logs"] == {"files": 0, "lines": 0, "rows": 0}, "zweiter Lauf findet nichts mehr"


def test_trim_dated_log_keeps_undated_continuation_lines(tmp_path):
    from app import retention
    from datetime import date
    p = tmp_path / "x.log"
    p.write_text("ohne Datum am Anfang\n2026-01-01 alt\n  mehr alt\n[2026-10-20T10:00:00] neu\n  mehr neu\n", encoding="utf-8")
    assert retention.trim_dated_log(p, date(2026, 6, 1)) == 2
    assert p.read_text(encoding="utf-8") == "ohne Datum am Anfang\n[2026-10-20T10:00:00] neu\n  mehr neu\n"
    assert retention.trim_dated_log(tmp_path / "fehlt.log", date(2026, 6, 1)) == 0


# ---------------------------------------------------------------- Zeitplan und Kommandozeile

def test_retention_runs_once_per_day_from_four_oclock(hosted, monkeypatch):
    from app import retention
    calls = []
    monkeypatch.setattr(retention, "run", lambda *a, **k: calls.append(1) or {"ok": True})
    assert retention.schedule_due(datetime(2026, 10, 26, 3, 59)) is None and not calls
    assert retention.schedule_due(datetime(2026, 10, 26, 4, 0)) == {"ok": True}
    assert retention.schedule_due(datetime(2026, 10, 26, 23, 0)) is None, "heute schon gelaufen"
    assert retention.schedule_due(datetime(2026, 10, 27, 4, 30)) == {"ok": True} and len(calls) == 2
    monkeypatch.setattr(retention, "RETENTION_TIME", "kaputt")
    assert retention._parse_time("kaputt") == (4, 0) and retention._parse_time("23:59") == (23, 59)


def test_cli_dry_run_prints_counts(hosted, capsys):
    from app import retention
    assert retention.main(["--dry-run"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["dry_run"] is True and "access_files" in out and "accounts_purged" in out


def test_jobs_scheduler_calls_retention(hosted, monkeypatch):
    """Der Zeitplan-Thread der Jobs ruft die Loeschfristen auf, Fehler dort stoppen den Abgleich nicht."""
    from app import jobs, retention
    seen = []
    monkeypatch.setattr(retention, "schedule_due", lambda *a, **k: seen.append("r") or (_ for _ in ()).throw(RuntimeError("boom")))
    monkeypatch.setattr(jobs, "schedule_due", lambda *a, **k: seen.append("s"))
    r = jobs.Runner(workers=1, poll_seconds=0.05)
    r._stop.set()                                   # Schleife laeuft genau einmal durch
    r._stop.clear()
    import threading
    t = threading.Thread(target=r._scheduler, daemon=True); t.start()
    for _ in range(50):
        if "r" in seen:
            break
        time.sleep(0.02)
    r.stop(); t.join(2)
    assert seen[:2] == ["s", "r"]

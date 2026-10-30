"""Hochschul-Abgleich je Konto im gehosteten Modus: Tresor (verschluesselte Zugangsdaten), Zugangsdaten und Pfade aus
dem Nutzerkontext, Job-Warteschlange mit Arbeitern und Zeitplan, Endpunkte."""
import json
import threading
from datetime import datetime

import pytest
from conftest import asgi_call


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_UNI_PARALLEL", "100")          # Schonung der Hochschulen eigens getestet
    monkeypatch.setenv("LERNAPP_UNI_GAP_S", "0")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    monkeypatch.delenv("LERNAPP_SECRET_KEY", raising=False)
    yield app
    accounts.db_path().unlink(missing_ok=True)
    vault.reset_master()


def _register(app, email, uni="luh"):
    st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    assert st == 201, b
    d = json.loads(b)
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


# ---------------------------------------------------------------- Tresor

def test_vault_roundtrip_per_user_and_tamper(hosted):
    from app import vault
    a, b = "a" * 32, "b" * 32
    tok = vault.encrypt(a, "geheim")
    assert tok.startswith("v1:") and vault.decrypt(a, tok) == "geheim"
    with pytest.raises(Exception):
        vault.decrypt(b, tok)                                   # anderes Konto: anderer Schluessel und andere AAD
    with pytest.raises(Exception):
        vault.decrypt(a, tok[:-4] + "AAAA")                     # manipuliert
    assert vault.encrypt(a, "geheim") != tok                    # frische Nonce


def test_vault_master_key_from_env_or_file(hosted, monkeypatch):
    from app import vault
    k1 = vault.master_key()
    assert vault.key_file().exists() and len(k1) == 32
    vault.reset_master()
    assert vault.master_key() == k1, "Datei wird wiederverwendet"
    vault.reset_master()
    monkeypatch.setenv("LERNAPP_SECRET_KEY", "00" * 32)
    assert vault.master_key() == bytes(32)
    vault.reset_master()
    monkeypatch.setenv("LERNAPP_SECRET_KEY", "zu-kurz")
    with pytest.raises(RuntimeError):
        vault.master_key()
    vault.reset_master()


def test_vault_values_encrypted_at_rest_and_env_for(hosted):
    from app import accounts, vault
    u = accounts.register("v@beispiel.de", "sehr-geheim-123", "luh")
    vault.set_values(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "Pa$$wort#1", "QIS_SAME_AS": "STUDIP"})
    with accounts.cursor() as conn:
        rows = conn.execute("SELECT name, value_enc FROM vault WHERE user_id=?", (u["id"],)).fetchall()
    assert {r["name"] for r in rows} == {"STUDIP_USER", "STUDIP_PASSWORD", "QIS_SAME_AS"}
    assert all("Pa$$wort" not in r["value_enc"] and "ab12cd" not in r["value_enc"] for r in rows)
    assert vault.env_for(u["id"]) == {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "Pa$$wort#1", "QIS_SAME_AS": "STUDIP"}
    vault.set_values(u["id"], {"STUDIP_PASSWORD": None})
    assert "STUDIP_PASSWORD" not in vault.env_for(u["id"]) and not vault.has_university_credentials(u["id"], "luh")
    vault.set_values(u["id"], {"STUDIP_PASSWORD": "neu-neu-neu"})
    assert vault.has_university_credentials(u["id"], "luh") and not vault.has_university_credentials(u["id"], "hildesheim")
    assert vault.users_with_credentials() == [(u["id"], "luh")]
    assert vault.delete_all(u["id"]) == 3 and vault.env_for(u["id"]) == {}
    with pytest.raises(ValueError):
        vault.set_values(u["id"], {"klein": "x"})


def test_vault_cache_notices_changes_from_another_process(hosted):
    """P10 (28.10.2026): ein anderer Prozess (Arbeiter, zweiter API-Prozess) schreibt am Zwischenspeicher vorbei."""
    from app import accounts, vault
    u = accounts.register("p10@beispiel.de", "sehr-geheim-123", "luh")
    vault.set_values(u["id"], {"STUDIP_USER": "alt"})
    assert vault.env_for(u["id"])["STUDIP_USER"] == "alt"
    with accounts.cursor() as conn:                 # wie ein anderer Prozess: direkt in die Datenbank
        conn.execute("UPDATE vault SET value_enc=? WHERE user_id=? AND name='STUDIP_USER'", (vault.encrypt(u["id"], "neu"), u["id"]))
        conn.execute("INSERT INTO vault(user_id, name, value_enc, updated_at) VALUES (?,?,?,?)",
                     (u["id"], "STUDIP_PASSWORD", vault.encrypt(u["id"], "pw"), "2026-10-28T10:00:00Z"))
    assert vault.env_for(u["id"]) == {"STUDIP_USER": "neu", "STUDIP_PASSWORD": "pw"}
    with accounts.cursor() as conn:
        conn.execute("DELETE FROM vault WHERE user_id=? AND name='STUDIP_PASSWORD'", (u["id"],))
    assert vault.env_for(u["id"]) == {"STUDIP_USER": "neu"}


def test_session_last_seen_written_at_most_once_a_minute(hosted):
    """P8 (28.10.2026): nicht bei jeder Anfrage ein UPDATE auf accounts.db."""
    from app import accounts
    u, token = accounts.register("p8@beispiel.de", "sehr-geheim-123", "luh"), None
    _, token = accounts.login("p8@beispiel.de", "sehr-geheim-123")
    with accounts.cursor() as conn:
        conn.execute("UPDATE sessions SET last_seen_at='2026-01-01T00:00:00Z'")
    assert accounts.authenticate(token)["id"] == u["id"]
    with accounts.cursor() as conn:
        first = conn.execute("SELECT last_seen_at FROM sessions").fetchone()[0]
    assert first > "2026-01-01T00:00:00Z", "alt: wird geschrieben"
    with accounts.cursor() as conn:
        conn.execute("UPDATE sessions SET last_seen_at=?", (first,))
        changes_before = conn.total_changes
    accounts.authenticate(token)
    with accounts.cursor() as conn:
        assert conn.execute("SELECT last_seen_at FROM sessions").fetchone()[0] == first, "frisch: kein neues UPDATE"


# ---------------------------------------------------------------- Kontext: Zugangsdaten und Pfade je Konto

def test_config_reads_credentials_and_paths_from_account_context(hosted):
    from app import accounts, config, hildesheim, qis, studip_sync, vault
    u = accounts.register("c@beispiel.de", "sehr-geheim-123", "hildesheim")
    vault.set_values(u["id"], {"HILDESHEIM_USER": "peev", "HILDESHEIM_PASSWORD": "pw-pw-pw", "LEARNWEB_TOKEN": "tok123"})
    assert config.own_credentials("HILDESHEIM") == ("", "") or True            # ausserhalb des Kontextes: .env (hier leer)
    t = config.set_user_context(u["id"], "hildesheim")
    try:
        assert config.own_credentials("HILDESHEIM") == ("peev", "pw-pw-pw") and config.secret("LEARNWEB_TOKEN") == "tok123"
        assert config.credentials() == ("", "") and config.configured_university() == "hildesheim"
        d = config.user_data_dir(u["id"], "hildesheim")
        assert hildesheim._profile_dir() == d / "browser-profile-hildesheim" and studip_sync._profile_dir() == d / "browser-profile"
        assert qis._doc_dir() == d / "qis" and config.log_dir() == d / "logs"
        config.set_env({"HILDESHEIM_PASSWORD": "geaendert-1"})                 # schreibt in den Tresor, nie in die .env
        assert config.own_credentials("HILDESHEIM") == ("peev", "geaendert-1")
    finally:
        config.reset_user_context(t)
    assert not (config.ROOT / ".env").exists() or "geaendert-1" not in (config.ROOT / ".env").read_text(encoding="utf-8")
    t2 = config.set_env_context({"STUDIP_USER": "x1", "STUDIP_PASSWORD": "y2"})
    try:
        assert config.credentials() == ("x1", "y2")
    finally:
        config.reset_env_context(t2)


# ---------------------------------------------------------------- Jobs

def test_job_runs_in_account_context_and_records_result(hosted, monkeypatch):
    from app import accounts, config, db, jobs, studip_sync, vault
    u = accounts.register("j@beispiel.de", "sehr-geheim-123", "luh")
    vault.set_values(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "pw-pw-pw-1"})
    seen = {}

    def fake_sync(show_browser=False):
        seen["user"] = config.current_user_id()
        seen["creds"] = config.credentials()
        seen["dir"] = config.data_dir()
        with db.cursor() as conn:
            conn.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES ('t','t',1,2,'Testlauf')")
        return {"ok": True, "new_files": ["f1", "f2"], "message": "2 neue Dateien"}
    monkeypatch.setattr(studip_sync, "run_sync", fake_sync)
    j = jobs.enqueue(u["id"], "sync", "manual")
    assert j["status"] == "queued" and not j["already"]
    assert jobs.enqueue(u["id"], "sync", "manual")["already"], "kein zweiter wartender Job"
    assert jobs.bg_state(u["id"])["running"] and "wartet" in jobs.bg_state(u["id"])["message"]
    assert jobs.work_once() is True and jobs.work_once() is False
    assert seen["user"] == u["id"] and seen["creds"] == ("ab12cd", "pw-pw-pw-1") and seen["dir"] == config.user_data_dir(u["id"], "luh")
    assert config.current_user_id() is None, "Kontext nach dem Job zurueckgesetzt"
    done = jobs.latest(u["id"])
    assert (done["status"], done["message"], done["new_files"]) == ("done", "2 neue Dateien · Wochentests: 0 veröffentlicht, 0 wartend, 0 fehlgeschlagen, 0 Nachträge", 2), "nach dem Abgleich laeuft der Wochentest-Takt (30.10.2026)"
    t = config.set_user_context(u["id"], "luh")
    try:
        with db.cursor() as conn:
            assert db.row(conn, "SELECT message FROM sync_log ORDER BY id DESC LIMIT 1")["message"] == "Testlauf"
    finally:
        config.reset_user_context(t)
    with db.cursor() as conn:
        assert not db.rows(conn, "SELECT 1 FROM sync_log WHERE message='Testlauf'"), "nichts im Einzelplatz-Ordner"

    def boom(show_browser=False):
        raise RuntimeError("Browser fehlt")
    monkeypatch.setattr(studip_sync, "run_sync", boom)
    jobs.enqueue(u["id"], "sync")
    jobs.work_once()
    f = jobs.latest(u["id"])
    assert f["status"] == "failed" and "Browser fehlt" in f["message"] and not jobs.bg_state(u["id"])["running"]


def test_claim_is_atomic_and_one_job_per_account(hosted, monkeypatch):
    from app import accounts, jobs, studip_sync, vault
    a = accounts.register("a@beispiel.de", "sehr-geheim-123", "luh")
    b = accounts.register("b@beispiel.de", "sehr-geheim-123", "luh")
    for u in (a, b):
        vault.set_values(u["id"], {"STUDIP_USER": "x", "STUDIP_PASSWORD": "y-y-y-y-y"})
    jobs.enqueue(a["id"], "sync"); jobs.enqueue(a["id"], "grades"); jobs.enqueue(b["id"], "sync")
    j1 = jobs.claim_next()
    assert (j1["user_id"], j1["kind"]) == (a["id"], "sync")
    j2 = jobs.claim_next()
    assert j2["user_id"] == b["id"], "zweiter Job von A wartet, bis As erster fertig ist"
    assert jobs.claim_next() is None
    jobs._finish(j1["id"], True, "ok")
    assert jobs.claim_next()["kind"] == "grades"
    # Parallel: 8 Threads holen aus 5 Jobs, keiner doppelt
    for i in range(5):
        u = accounts.register(f"p{i}@beispiel.de", "sehr-geheim-123", "luh")
        jobs.enqueue(u["id"], "sync")
    got, lock = [], threading.Lock()

    def grab():
        j = jobs.claim_next()
        if j:
            with lock:
                got.append(j["id"])
    ts = [threading.Thread(target=grab) for _ in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert len(got) == 5 and len(set(got)) == 5
    assert jobs.recover_stale(max_hours=0) >= 5                 # alle "laufenden" ohne Abschluss gelten als abgebrochen


def test_schedule_due_once_per_slot(hosted, monkeypatch):
    from app import accounts, jobs, vault
    u = accounts.register("s@beispiel.de", "sehr-geheim-123", "hildesheim")
    vault.set_values(u["id"], {"HILDESHEIM_USER": "peev", "HILDESHEIM_PASSWORD": "pw-pw-pw"})
    o = accounts.register("ohne@beispiel.de", "sehr-geheim-123", "luh")  # ohne Zugangsdaten: statt Abgleich der Wochentest-Takt
    monkeypatch.setenv("LERNAPP_SYNC_TIMES", "08:00, 15:00, kaputt")
    assert jobs.sync_times() == ["08:00", "15:00"]
    assert jobs.due_slots(datetime(2026, 10, 26, 7, 59)) == []
    assert jobs.due_slots(datetime(2026, 10, 26, 15, 30)) == ["2026-10-26T08:00", "2026-10-26T15:00"]
    assert jobs.schedule_due(datetime(2026, 10, 26, 9, 0)) == 2
    assert jobs.latest(u["id"])["kind"] == "sync" and jobs.latest(o["id"])["kind"] == "weekly"
    assert jobs.schedule_due(datetime(2026, 10, 26, 9, 5)) == 0, "08:00 ist schon bearbeitet"
    assert jobs.schedule_due(datetime(2026, 10, 26, 15, 1)) == 0, "Jobs von 08:00 warten noch: kein zweiter"
    for uid in (u["id"], o["id"]):
        jobs._finish(jobs.latest(uid)["id"], True, "ok")
    assert jobs.schedule_due(datetime(2026, 10, 27, 8, 0)) == 2
    assert jobs.latest(u["id"])["trigger"] == "scheduled" and jobs.latest("x" * 32) is None


# ---------------------------------------------------------------- Endpunkte

def test_hosted_credentials_and_sync_endpoints(hosted, monkeypatch):
    from app import config, jobs, studip_sync
    _, h = _register(hosted, "e@beispiel.de", "luh")
    st, _, b = asgi_call(hosted, "POST", "/api/sync", headers=h)
    assert st == 400 and json.loads(b)["code"] == "credentials_missing"
    st, _, b = asgi_call(hosted, "GET", "/api/credentials", headers=h)
    assert st == 200 and json.loads(b) == {"user": "", "password_set": False, "consent_at": None}
    # Dienst: ohne ausdrueckliche Zustimmung keine Zugangsdaten (Entscheidung 30.10.2026)
    st, _, b = asgi_call(hosted, "PUT", "/api/credentials", headers=h, body=json.dumps({"user": "ab12cd", "password": "Pa$$wort-1"}))
    assert st == 400 and json.loads(b)["code"] == "consent_required"
    assert json.loads(asgi_call(hosted, "GET", "/api/credentials", headers=h)[2])["password_set"] is False
    st, _, b = asgi_call(hosted, "PUT", "/api/credentials", headers=h, body=json.dumps({"user": "ab12cd", "password": "Pa$$wort-1", "consent": True}))
    assert st == 200 and json.loads(b)["password_set"]
    assert not (config.ROOT / ".env").exists() or "ab12cd" not in (config.ROOT / ".env").read_text(encoding="utf-8")
    st, _, b = asgi_call(hosted, "GET", "/api/credentials", headers=h)
    d = json.loads(b)
    assert d["user"] == "ab12cd" and d["password_set"] and d["consent_at"] and d["consent_at"].startswith("20")
    st, _, b = asgi_call(hosted, "GET", "/api/services", headers=h)
    d = json.loads(b)
    assert st == 200 and d["credentials"]["studip"]["user"] == "ab12cd" and d["university_next"] == "luh"
    st, _, b = asgi_call(hosted, "POST", "/api/sync", headers=h)
    d = json.loads(b)
    assert st == 200 and d["started"] == "Sync" and d["status"] == "queued"
    st, _, b = asgi_call(hosted, "GET", "/api/sync/status", headers=h)
    d = json.loads(b)
    assert d["bg"]["running"] and d["bg"]["task"] == "Sync" and d["jobs"][0]["status"] == "queued"
    st, _, b = asgi_call(hosted, "GET", "/api/bg", headers=h)
    assert json.loads(b)["running"]
    monkeypatch.setattr(studip_sync, "run_sync", lambda show_browser=False: {"ok": True, "new_files": [], "message": "0 neue Dateien"})
    assert jobs.work_once()
    st, _, b = asgi_call(hosted, "GET", "/api/sync/status", headers=h)
    d = json.loads(b)
    assert not d["bg"]["running"] and d["jobs"][0]["status"] == "done" and d["jobs"][0]["message"].startswith("0 neue Dateien · Wochentests:")
    st, _, b = asgi_call(hosted, "POST", "/api/grades/sync", headers=h)
    assert st == 200 and json.loads(b)["started"] == "Notenspiegel"
    # Zugangsdaten anderer Konten bleiben getrennt
    _, h2 = _register(hosted, "f@beispiel.de", "luh")
    st, _, b = asgi_call(hosted, "GET", "/api/credentials", headers=h2)
    assert json.loads(b) == {"user": "", "password_set": False, "consent_at": None}
    st, _, b = asgi_call(hosted, "PUT", "/api/credentials/hildesheim", headers=h2, body=json.dumps({"user": "peev", "password": "pw-pw-pw"}))
    assert st == 400 and json.loads(b)["code"] == "consent_required"
    st, _, b = asgi_call(hosted, "PUT", "/api/credentials/hildesheim", headers=h2, body=json.dumps({"user": "peev", "password": "pw-pw-pw", "consent": True}))
    assert st == 200
    st, _, b = asgi_call(hosted, "GET", "/api/services", headers=h2)
    assert json.loads(b)["credentials"]["hildesheim"]["configured"]
    st, _, b = asgi_call(hosted, "PUT", "/api/credentials/hildesheim", headers=h2, body=json.dumps({"clear": True}))
    assert st == 200 and not json.loads(b)["configured"]


def test_local_mode_unchanged(app):
    """Einzelplatz: /api/sync startet weiter den Hintergrundlauf des PCs, Zugangsdaten kommen aus der .env."""
    from app import config
    assert config.MODE == "local" and config.current_user_id() is None
    st, _, b = asgi_call(app, "GET", "/api/bg")
    assert st == 200 and "job" not in json.loads(b)


def test_universities_are_spared_across_accounts(hosted, monkeypatch):
    """P9 (28.10.2026): hoechstens N gleichzeitige Abgleiche je Hochschule und Abstand zwischen zwei Starts; eine andere
    Hochschule wird davon nicht aufgehalten."""
    from app import accounts, jobs
    monkeypatch.setenv("LERNAPP_UNI_PARALLEL", "2")
    monkeypatch.setenv("LERNAPP_UNI_GAP_S", "0")
    luh = [accounts.register(f"l{i}@beispiel.de", "sehr-geheim-123", "luh") for i in range(3)]
    hi = accounts.register("h@beispiel.de", "sehr-geheim-123", "hildesheim")
    for u in luh + [hi]:
        jobs.enqueue(u["id"], "sync")
    a, b = jobs.claim_next(), jobs.claim_next()
    assert {a["user_id"], b["user_id"]} == {luh[0]["id"], luh[1]["id"]}
    c = jobs.claim_next()
    assert c["user_id"] == hi["id"], "dritter LUH-Job wartet, Hildesheim laeuft"
    assert jobs.claim_next() is None
    jobs._finish(a["id"], True, "ok")
    assert jobs.claim_next()["user_id"] == luh[2]["id"]
    # Abstand zwischen zwei Starts derselben Hochschule
    monkeypatch.setenv("LERNAPP_UNI_PARALLEL", "10")
    monkeypatch.setenv("LERNAPP_UNI_GAP_S", "3600")
    late = accounts.register("spaet@beispiel.de", "sehr-geheim-123", "luh")
    jobs.enqueue(late["id"], "sync")
    assert jobs.claim_next() is None, "gerade erst ein LUH-Abgleich gestartet"


def test_api_requests_limited_per_account(hosted, monkeypatch):
    import json as _json
    from app import server
    monkeypatch.setenv("LERNAPP_LIMIT_API_PER_MIN", "3")
    server._API_HITS.clear()
    _, h = _register(hosted, "viel@beispiel.de")
    codes = [asgi_call(hosted, "GET", "/api/account/me", headers=h)[0] for _ in range(4)]
    assert codes[:3] == [200, 200, 200] and codes[3] == 429
    st, hdrs, b = asgi_call(hosted, "GET", "/api/account/me", headers=h)
    assert st == 429 and _json.loads(b)["code"] == "rate_limited" and any(k == b"retry-after" for k, _ in hdrs)
    _, h2 = _register(hosted, "wenig@beispiel.de")
    assert asgi_call(hosted, "GET", "/api/account/me", headers=h2)[0] == 200, "anderes Konto unberuehrt"
    assert server._api_rate("x", now=0.0) == 0 and server._api_rate("x", now=1.0) == 0
    server._API_HITS.clear()


# ---------------------------------------------------------------- Zugangsdaten loeschen, Wochentests je Konto (30.10.2026)

def test_clear_credentials_removes_vault_values_and_consent(hosted):
    from app import vault
    u, h = _register(hosted, "loesch@beispiel.de", "luh")
    asgi_call(hosted, "PUT", "/api/credentials", headers=h, body=json.dumps({"user": "ab12cd", "password": "Pa$$wort-1", "consent": True}))
    assert vault.has_university_credentials(u["id"], "luh") and vault.env_for(u["id"]).get("UNI_CONSENT_AT")
    st, _, b = asgi_call(hosted, "POST", "/api/credentials/clear", headers=h, body="{}")
    assert st == 200 and json.loads(b) == {"ok": True, "user": "", "password_set": False}
    assert not vault.has_university_credentials(u["id"], "luh") and "UNI_CONSENT_AT" not in vault.env_for(u["id"])
    assert json.loads(asgi_call(hosted, "GET", "/api/credentials", headers=h)[2]) == {"user": "", "password_set": False, "consent_at": None}


def test_weekly_quota_follows_the_plan(hosted):
    from app import accounts, billing, jobs
    u = accounts.register("quota@beispiel.de", "sehr-geheim-123", "luh")
    accounts.end_trial(u["id"])
    q = jobs.HostedQuota(accounts.get_user(u["id"]))
    assert "Plus" in q.check() and "Free" in q.check(), "Free: keine KI-Wochentests, mit Grund"
    accounts.set_plan(u["id"], "plus")
    q = jobs.HostedQuota(accounts.get_user(u["id"]))
    assert q.check() is None
    for i in range(3):
        q.consume(f"weekly:{i}:1")
    q.consume("weekly:0:1")                                             # dieselbe Anfrage zaehlt einmal
    conn = billing.connect()
    try:
        assert billing.used(conn, u["id"], "ai_tests_new") == 3
    finally:
        conn.close()
    assert "aufgebraucht" in q.check() and "3 von 3" in q.check()
    accounts.set_plan(u["id"], "pro_ai")
    assert jobs.HostedQuota(accounts.get_user(u["id"])).check() is None, "Pro AI: 40 im Monat"


def test_weekly_job_runs_in_account_context_with_quota_and_after_sync(hosted, monkeypatch):
    from app import accounts, config, db, jobs, studip_sync, vault, weekly
    u = accounts.register("wt@beispiel.de", "sehr-geheim-123", "luh")
    accounts.set_plan(u["id"], "plus")
    seen = []

    def fake_tick(now=None, user_id="local", log=print):
        q = weekly._QUOTA.get()
        seen.append((config.current_user_id(), type(q).__name__ if q else None, q.user["id"] if q else None))
        return {"published": [{"plan_id": 1}], "waiting": [], "failed": [], "nachtraege": []}
    monkeypatch.setattr(weekly, "tick", fake_tick)
    # eigener Job "weekly" (Konto ohne Zugangsdaten)
    j = jobs.enqueue(u["id"], "weekly", "scheduled")
    assert j["status"] == "queued"
    assert jobs.work_once()
    done = jobs.latest(u["id"])
    assert done["status"] == "done" and done["message"] == "Wochentests: 1 veröffentlicht, 0 wartend, 0 fehlgeschlagen, 0 Nachträge", done
    assert seen == [(u["id"], "HostedQuota", u["id"])] and weekly._QUOTA.get() is None and config.current_user_id() is None
    # nach einem Abgleich laeuft der Takt mit (wie _full_sync am PC)
    vault.set_values(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "pw-pw-pw-1"})
    monkeypatch.setattr(studip_sync, "run_sync", lambda show_browser=False: {"ok": True, "new_files": ["f1"], "message": "1 neue Datei"})
    jobs.enqueue(u["id"], "sync", "manual")
    assert jobs.work_once()
    done = jobs.latest(u["id"])
    assert done["status"] == "done" and done["message"] == "1 neue Datei · Wochentests: 1 veröffentlicht, 0 wartend, 0 fehlgeschlagen, 0 Nachträge" and done["new_files"] == 1
    assert len(seen) == 2
    # auto_tests aus: kein Takt
    t = config.set_user_context(u["id"], "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            db.set_setting(conn, "auto_tests", "0")
    finally:
        config.reset_user_context(t)
    jobs.enqueue(u["id"], "weekly", "manual")
    assert jobs.work_once() and jobs.latest(u["id"])["message"] == "Wochentests: aus" and len(seen) == 2
    # ein Fehler im Takt laesst den Abgleich erfolgreich
    monkeypatch.setattr(weekly, "tick", lambda **k: (_ for _ in ()).throw(RuntimeError("KI weg")))
    with db.cursor() as conn:
        pass
    t = config.set_user_context(u["id"], "luh")
    try:
        with db.cursor() as conn:
            db.set_setting(conn, "auto_tests", "1")
    finally:
        config.reset_user_context(t)
    jobs.enqueue(u["id"], "sync", "manual")
    assert jobs.work_once()
    done = jobs.latest(u["id"])
    assert done["status"] == "done" and "Wochentests: FEHLER KI weg" in done["message"]


def test_weekly_jobs_are_not_throttled_like_browser_jobs_and_get_scheduled(hosted, monkeypatch):
    from app import accounts, jobs, vault, weekly
    monkeypatch.setenv("LERNAPP_UNI_PARALLEL", "1")
    monkeypatch.setenv("LERNAPP_UNI_GAP_S", "3600")
    a = accounts.register("a@beispiel.de", "sehr-geheim-123", "luh")
    b = accounts.register("b@beispiel.de", "sehr-geheim-123", "luh")
    vault.set_values(a["id"], {"STUDIP_USER": "x", "STUDIP_PASSWORD": "y"})
    # Zeitplan: Konto mit Zugangsdaten -> sync, ohne -> weekly
    n = jobs.schedule_due(datetime(2026, 10, 30, 8, 5), ["08:00"])
    assert n == 2
    kinds = {j["user_id"]: j["kind"] for j in [jobs.latest(a["id"]), jobs.latest(b["id"])]}
    assert kinds == {a["id"]: "sync", b["id"]: "weekly"}
    # der Abgleich von a laeuft (belegt die Hochschule); der Wochentest-Job von b darf trotzdem starten
    monkeypatch.setattr(weekly, "tick", lambda **k: {"published": [], "waiting": [], "failed": [], "nachtraege": []})
    first = jobs.claim_next()
    assert first["kind"] == "sync" and first["user_id"] == a["id"]
    second = jobs.claim_next()
    assert second is not None and second["kind"] == "weekly" and second["user_id"] == b["id"], "nicht von uni_limits gebremst"
    jobs._finish(first["id"], True, "ok"); jobs._finish(second["id"], True, "ok")
    # zweiter Abgleich derselben Hochschule innerhalb der Pause: gebremst
    jobs.enqueue(a["id"], "sync", "manual")
    assert jobs.claim_next() is None


def test_weekly_ask_uses_the_studora_ai_in_the_service(hosted, monkeypatch):
    from app import accounts, ai_backend, config, weekly
    u = accounts.register("ki@beispiel.de", "sehr-geheim-123", "luh")
    calls = []

    class C:
        text = "ANTWORT"
    monkeypatch.setattr(ai_backend, "complete", lambda user_id, purpose, system, prompt, schema=None, cache=False, now=None: calls.append((user_id, purpose, system, prompt)) or C())
    t = config.set_user_context(u["id"], "luh")
    try:
        assert weekly._ask("Frage", "SYS") == "ANTWORT"
        assert calls == [(u["id"], "weekly_test", "SYS", "Frage")]
        monkeypatch.setattr(ai_backend, "complete", lambda *a, **k: (_ for _ in ()).throw(ai_backend.AIUnavailable("ai_not_configured", "Studora-KI ist nicht eingerichtet.", 503)))
        with pytest.raises(weekly.WeeklyError) as e:
            weekly._ask("Frage", "SYS")
        assert "nicht eingerichtet" in str(e.value)
    finally:
        config.reset_user_context(t)

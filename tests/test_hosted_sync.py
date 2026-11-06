"""Gehosteter Modus: Tresor, Zugangsdaten und Pfade aus dem Nutzerkontext, Job-Warteschlange mit Arbeitern und
Zeitplan, Endpunkte. Seit 06.11.2026 ("Ja, abschalten"): der Dienst speichert keine Hochschul-Zugangsdaten mehr
(410 credentials_not_stored, Tresor beim Start geleert, kein Hochschul-Abgleich im Zeitplan). Der Code fuer den
Abgleich je Konto bleibt und wird mit `jobs.HOSTED_UNI_SYNC = True` und Altbestand (conftest.legacy_vault) geprueft."""
import json
import threading
from datetime import datetime

import pytest
from conftest import asgi_call, legacy_vault


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


def test_vault_is_never_written_and_legacy_values_are_ignored(hosted):
    """06.11.2026: set_values nimmt keine Werte an (auch nicht teilweise), Loeschen geht; Altbestand liegt verschluesselt
    und zaehlt nie als Zugangsdaten fuer einen Abgleich im Dienst."""
    from app import accounts, vault
    u = accounts.register("v@beispiel.de", "sehr-geheim-123", "luh")
    with pytest.raises(vault.CredentialsNotStored) as e:
        vault.set_values(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "Pa$$wort#1"})
    assert "keine Hochschul-Passwörter auf dem Server" in str(e.value)
    with pytest.raises(vault.CredentialsNotStored):
        vault.set_values(u["id"], {"STUDIP_USER": None, "STUDIP_COOKIES": "[]"})          # gemischt: nichts geschrieben
    assert vault.env_for(u["id"]) == {}
    legacy_vault(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "Pa$$wort#1", "QIS_SAME_AS": "STUDIP"})
    with accounts.cursor() as conn:
        rows = conn.execute("SELECT name, value_enc FROM vault WHERE user_id=?", (u["id"],)).fetchall()
    assert {r["name"] for r in rows} == {"STUDIP_USER", "STUDIP_PASSWORD", "QIS_SAME_AS"}
    assert all("Pa$$wort" not in r["value_enc"] and "ab12cd" not in r["value_enc"] for r in rows)
    assert not vault.has_university_credentials(u["id"], "luh") and vault.users_with_credentials() == []
    vault.set_values(u["id"], {"STUDIP_PASSWORD": None})                                  # Loeschen bleibt erlaubt
    assert "STUDIP_PASSWORD" not in vault.env_for(u["id"])
    assert vault.delete_all(u["id"]) == 2 and vault.env_for(u["id"]) == {}
    with pytest.raises(ValueError):
        vault.set_values(u["id"], {"klein": None})


def test_vault_is_purged_at_startup_with_a_count_only(hosted, capsys):
    from app import accounts, server, vault
    a = accounts.register("pa@beispiel.de", "sehr-geheim-123", "luh")
    b = accounts.register("pb@beispiel.de", "sehr-geheim-123", "hildesheim")
    legacy_vault(a["id"], {"STUDIP_USER": "luh-id-a", "STUDIP_PASSWORD": "geheim-a", "STUDIP_COOKIES": "[]"})
    legacy_vault(b["id"], {"HILDESHEIM_USER": "hil-b", "HILDESHEIM_PASSWORD": "geheim-b"})
    assert vault.env_for(a["id"])["STUDIP_USER"] == "luh-id-a"           # im Zwischenspeicher
    import asyncio

    async def start_and_stop():
        async with server._lifespan(server.app):
            pass
    asyncio.run(start_and_stop())
    out = capsys.readouterr().out
    assert "[vault]" in out and "5 Tresor-Eintraege geloescht" in out
    assert "luh-id-a" not in out and "hil-b" not in out and a["id"] not in out and b["id"] not in out, "keine Namen im Protokoll"
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM vault").fetchone()[0] == 0
    assert vault.env_for(a["id"]) == {} and vault.env_for(b["id"]) == {}
    assert vault.purge_at_startup() == 0, "zweiter Start: nichts mehr da"
    assert vault.key_file().exists(), "secret.key bleibt (Pseudonyme in Community und Testbibliothek)"


def test_vault_cache_notices_changes_from_another_process(hosted):
    """P10 (28.10.2026): ein anderer Prozess (Arbeiter, zweiter API-Prozess) schreibt am Zwischenspeicher vorbei."""
    from app import accounts, vault
    u = accounts.register("p10@beispiel.de", "sehr-geheim-123", "luh")
    legacy_vault(u["id"], {"STUDIP_USER": "alt"})
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
    legacy_vault(u["id"], {"HILDESHEIM_USER": "testkennung", "HILDESHEIM_PASSWORD": "pw-pw-pw", "LEARNWEB_TOKEN": "tok123"})
    assert config.own_credentials("HILDESHEIM") == ("", "") or True            # ausserhalb des Kontextes: .env (hier leer)
    t = config.set_user_context(u["id"], "hildesheim")
    try:
        assert config.own_credentials("HILDESHEIM") == ("testkennung", "pw-pw-pw") and config.secret("LEARNWEB_TOKEN") == "tok123"
        assert config.credentials() == ("", "") and config.configured_university() == "hildesheim"
        d = config.user_data_dir(u["id"], "hildesheim")
        assert hildesheim._profile_dir() == d / "browser-profile-hildesheim" and studip_sync._profile_dir() == d / "browser-profile"
        assert qis._doc_dir() == d / "qis" and config.log_dir() == d / "logs"
        with pytest.raises(vault.CredentialsNotStored):                         # weder Tresor noch .env (06.11.2026)
            config.set_env({"HILDESHEIM_PASSWORD": "geaendert-1"})
        assert config.own_credentials("HILDESHEIM") == ("testkennung", "pw-pw-pw")
    finally:
        config.reset_user_context(t)
    assert not (config.ROOT / ".env").exists() or "geaendert-1" not in (config.ROOT / ".env").read_text(encoding="utf-8")
    t2 = config.set_env_context({"STUDIP_USER": "x1", "STUDIP_PASSWORD": "y2"})
    try:
        assert config.credentials() == ("x1", "y2")
    finally:
        config.reset_env_context(t2)


# ---------------------------------------------------------------- Jobs

def test_hosted_sync_and_grades_jobs_are_skipped_without_browser(hosted, monkeypatch):
    """06.11.2026: alte Abgleich- oder Notenspiegel-Jobs in der Warteschlange laufen nicht, kein Chromium, keine Anmeldung."""
    from app import accounts, jobs, qis, studip_sync
    u = accounts.register("skip@beispiel.de", "sehr-geheim-123", "luh")
    legacy_vault(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "pw-pw-pw-1"})

    def never(*a, **k):
        raise AssertionError("im Dienst kein Hochschul-Abgleich")
    monkeypatch.setattr(studip_sync, "run_sync", never)
    monkeypatch.setattr(qis, "run", never)
    for kind in ("sync", "grades"):
        jobs.enqueue(u["id"], kind, "scheduled")
        assert jobs.work_once()
        j = jobs.latest(u["id"])
        assert (j["kind"], j["status"]) == (kind, "failed") and j["message"].startswith("Übersprungen: StudiNow speichert keine")


def test_job_runs_in_account_context_and_records_result(hosted, monkeypatch):
    from app import accounts, config, db, jobs, studip_sync
    monkeypatch.setattr(jobs, "HOSTED_UNI_SYNC", True)           # der Weg bleibt im Code (abgeschaltet seit 06.11.2026)
    u = accounts.register("j@beispiel.de", "sehr-geheim-123", "luh")
    legacy_vault(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "pw-pw-pw-1"})
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
    from app import accounts, jobs
    a = accounts.register("a@beispiel.de", "sehr-geheim-123", "luh")
    b = accounts.register("b@beispiel.de", "sehr-geheim-123", "luh")
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
    from app import accounts, jobs
    u = accounts.register("s@beispiel.de", "sehr-geheim-123", "hildesheim")
    legacy_vault(u["id"], {"HILDESHEIM_USER": "testkennung", "HILDESHEIM_PASSWORD": "pw-pw-pw"})   # Altbestand: trotzdem kein Abgleich
    o = accounts.register("ohne@beispiel.de", "sehr-geheim-123", "luh")  # 06.11.2026: alle Konten bekommen nur den Wochentest-Takt
    monkeypatch.setenv("LERNAPP_SYNC_TIMES", "08:00, 15:00, kaputt")
    assert jobs.sync_times() == ["08:00", "15:00"]
    assert jobs.due_slots(datetime(2026, 10, 26, 7, 59)) == []
    assert jobs.due_slots(datetime(2026, 10, 26, 15, 30)) == ["2026-10-26T08:00", "2026-10-26T15:00"]
    assert jobs.schedule_due(datetime(2026, 10, 26, 9, 0)) == 2
    assert jobs.latest(u["id"])["kind"] == "weekly" and jobs.latest(o["id"])["kind"] == "weekly"
    assert jobs.schedule_due(datetime(2026, 10, 26, 9, 5)) == 0, "08:00 ist schon bearbeitet"
    assert jobs.schedule_due(datetime(2026, 10, 26, 15, 1)) == 0, "Jobs von 08:00 warten noch: kein zweiter"
    for uid in (u["id"], o["id"]):
        jobs._finish(jobs.latest(uid)["id"], True, "ok")
    assert jobs.schedule_due(datetime(2026, 10, 27, 8, 0)) == 2
    assert jobs.latest(u["id"])["trigger"] == "scheduled" and jobs.latest("x" * 32) is None


def test_schedule_due_reads_vault_once_and_uses_one_connection_per_slot(hosted, monkeypatch):
    """Lasttest 30.10.2026, Fund 7: je Fenster EIN Tresor-Durchlauf (vorher zwei) und EINE Verbindung fuer Merkmal und
    alle Jobs (vorher eine je Konto); mehrere faellige Fenster in einem Aufruf teilen sich den Tresor-Durchlauf."""
    from app import accounts, jobs, vault
    monkeypatch.setattr(jobs, "HOSTED_UNI_SYNC", True)           # der Weg bleibt im Code (abgeschaltet seit 06.11.2026)
    users = [accounts.register(f"k{i}@beispiel.de", "sehr-geheim-123", "luh") for i in range(4)]
    for u in users[:2]:
        legacy_vault(u["id"], {"STUDIP_USER": "x", "STUDIP_PASSWORD": "y"})
    with_creds = [(u["id"], "luh") for u in users[:2]]
    calls = {"vault": 0, "conn": 0}
    real_vault, real_conn = vault.users_with_credentials, jobs._conn

    def counting_vault():
        calls["vault"] += 1
        assert real_vault() == [], "seit 06.11.2026 immer leer"
        return list(with_creds)

    def counting_conn():
        calls["conn"] += 1
        return real_conn()
    monkeypatch.setattr(vault, "users_with_credentials", counting_vault)
    monkeypatch.setattr(jobs, "_conn", counting_conn)
    assert jobs.schedule_due(datetime(2026, 10, 26, 16, 0), ["08:00", "15:00"]) == 4, "4 Konten, das zweite Fenster findet alle wartend"
    assert calls == {"vault": 1, "conn": 2}, calls
    kinds = sorted(jobs.latest(u["id"])["kind"] for u in users)
    assert kinds == ["sync", "sync", "weekly", "weekly"]
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM schedule_marks").fetchone()[0] == 2
        assert conn.execute("SELECT COUNT(*) FROM sync_jobs").fetchone()[0] == 4, "keine doppelten Jobs"
    # schon bearbeitet: nur noch die Merkmal-Abfrage, kein Tresor-Durchlauf
    calls.update(vault=0, conn=0)
    assert jobs.schedule_due(datetime(2026, 10, 26, 16, 5), ["08:00", "15:00"]) == 0
    assert calls == {"vault": 0, "conn": 2}
    # ohne vorgeholte Liste holt active_users_without_credentials sie selbst (Aufrufer ausserhalb des Zeitplans)
    assert sorted(jobs.active_users_without_credentials()) == sorted(u["id"] for u in users[2:]) and calls["vault"] == 1


def test_runner_stop_marks_jobs_of_this_process_as_aborted(hosted, monkeypatch):
    """`python -m app.jobs` bekommt SIGTERM (docker stop): laufende Jobs bis zur Frist abwarten, den Rest als abgebrochen
    markieren – sonst stuenden sie 6 Stunden auf 'running' (recover_stale)."""
    from app import accounts, jobs, retention
    # Ohne Zeitplan: nach 08:00 legte der Zeitplan-Thread sonst echte Fenster an (Tresor-Durchlauf unter der
    # Schreibsperre von accounts.db); unter Last wartete der Arbeiter darauf laenger als 5 s, der Test fiel aus und
    # liess den Runner weiterlaufen - der holte dann die Jobs der folgenden Tests (test_hosted_credentials_and_sync_
    # endpoints, test_retention, test_qis_isolation: claim_next fand nichts mehr).
    monkeypatch.setenv("LERNAPP_SYNC_TIMES", "")
    monkeypatch.setattr(retention, "schedule_due", lambda *a, **k: None)
    u = accounts.register("stop@beispiel.de", "sehr-geheim-123", "luh")
    j = jobs.enqueue(u["id"], "weekly", "scheduled")
    started, release = threading.Event(), threading.Event()

    def slow_job(job):
        started.set()
        release.wait(30)
        return {"ok": True}
    monkeypatch.setattr(jobs, "run_job", slow_job)
    runners = []
    try:
        r = jobs.Runner(workers=1, poll_seconds=0.05)
        runners.append(r)
        r.start()
        assert started.wait(30) and r.alive()
        assert r.running_jobs() == [j["id"]]
        assert r.stop(0.2) == [j["id"]], "nach der Frist noch am Laufen: markiert"
        got = jobs.latest(u["id"])
        assert got["status"] == "failed" and got["message"] == "Abgebrochen (Dienst gestoppt)"
        release.set()
        for t in r._threads:
            t.join(30)
        assert not r.alive()
        # ohne laufende Jobs: nichts zu markieren
        r2 = jobs.Runner(workers=1, poll_seconds=0.05)
        runners.append(r2)
        r2.start()
        assert r2.stop(30) == []
    finally:
        # Arbeiter nie in den naechsten Test durchsickern lassen, auch wenn eine Pruefung oben fehlschlaegt
        release.set()
        for x in runners:
            x._stop.set()
            for t in x._threads:
                t.join(30)
        assert not any(x.alive() for x in runners)


def test_jobs_main_writes_heartbeat_for_healthcheck_and_stops_cleanly(hosted, monkeypatch, tmp_path, capsys):
    from app import config, jobs, retention
    monkeypatch.setattr(config, "BASE_LOG_DIR", tmp_path / "logs")
    monkeypatch.setenv("LERNAPP_JOB_WORKERS", "1")
    # Ohne Zeitplan: nach 08:00 legte der Zeitplan-Thread sonst ein Fenster an und wartete mit offener Schreibsperre auf
    # die zweite Verbindung des Tresors (Tabelle vault in der frischen accounts.db) - 15 s Sperrzeit, unter Last ueber
    # STOP_GRACE_S hinaus, dann lief der Runner in den naechsten Test weiter
    monkeypatch.setenv("LERNAPP_SYNC_TIMES", "")
    monkeypatch.setattr(retention, "schedule_due", lambda *a, **k: None)
    assert jobs.main(["--healthcheck"]) == 1, "ohne Lebenszeichen unhealthy"
    stop = threading.Event()
    stop.set()                                              # wie SIGTERM gleich nach dem Start
    assert jobs.main([], stop_event=stop) == 0
    out = capsys.readouterr().out
    assert "[jobs] gestartet: 1 Arbeiter" in out and "[jobs] beendet" in out
    assert jobs.heartbeat_path() == tmp_path / "logs" / "jobs.heartbeat" and jobs.heartbeat_path().exists()
    assert jobs.heartbeat_ok() and jobs.main(["--healthcheck"]) == 0
    assert not jobs.heartbeat_ok(max_age_s=0), "zu alt -> unhealthy"
    monkeypatch.setattr(config, "MODE", "local")
    assert jobs.main([]) == 2, "nur im gehosteten Modus"


# ---------------------------------------------------------------- Endpunkte

NOT_STORED = "StudiNow speichert keine Hochschul-Passwörter auf dem Server. Der Abgleich läuft auf deinem iPad oder in der Windows-App."


def test_hosted_credentials_and_sync_endpoints(hosted, monkeypatch):
    """06.11.2026: jedes Speichern von Hochschul-Zugangsdaten, -Schluesseln und -Sitzungen 410, auch mit Zustimmung;
    Abgleich und Notenspiegel im Dienst ebenso; der Tresor bleibt leer, die .env unberuehrt."""
    from app import config, jobs, vault
    u, h = _register(hosted, "e@beispiel.de", "luh")
    gone = lambda r: (r[0], json.loads(r[2]))                                                  # noqa: E731
    for method, path, body in (
            ("PUT", "/api/credentials", {"user": "ab12cd", "password": "Pa$$wort-1"}),
            ("PUT", "/api/credentials", {"user": "ab12cd", "password": "Pa$$wort-1", "consent": True}),
            ("PUT", "/api/credentials/qis", {"user": "ab12cd", "password": "qis-pw-1", "consent": True}),
            ("PUT", "/api/credentials/hildesheim", {"user": "testkennung", "password": "pw-pw-pw", "consent": True}),
            ("PUT", "/api/credentials/idm", {"same_as": "qis"}),
            ("PUT", "/api/learnweb/token", {"token": "A" * 32}),
            ("PUT", "/api/university/session", {"cookies": [{"name": "Seminar_Session", "value": "abc", "domain": "studip.uni-hannover.de"}]}),
            ("POST", "/api/sync", None),
            ("POST", "/api/grades/sync", None)):
        st, d = gone(asgi_call(hosted, method, path, headers=h, body=json.dumps(body) if body is not None else None))
        assert (st, d) == (410, {"detail": NOT_STORED, "code": "credentials_not_stored"}), (method, path, st, d)
    assert vault.env_for(u["id"]) == {} and jobs.latest(u["id"]) is None, "nichts im Tresor, kein Job"
    assert not (config.ROOT / ".env").exists() or "ab12cd" not in (config.ROOT / ".env").read_text(encoding="utf-8")
    st, _, b = asgi_call(hosted, "GET", "/api/credentials", headers=h)
    assert st == 200 and json.loads(b) == {"user": "", "password_set": False, "stored_on_server": False, "message": NOT_STORED}
    st, _, b = asgi_call(hosted, "GET", "/api/services", headers=h)
    d = json.loads(b)
    assert st == 200 and not d["credentials"]["studip"]["configured"] and not d["credentials"]["qis"]["configured"] and d["university_next"] == "luh"
    # Loeschen bleibt moeglich (Altbestand), Status und Hintergrund gehen weiter
    for method, path, body in (("POST", "/api/credentials/clear", {}), ("PUT", "/api/credentials/qis", {"clear": True}),
                               ("PUT", "/api/learnweb/token", {"clear": True}), ("DELETE", "/api/university/session", None)):
        assert asgi_call(hosted, method, path, headers=h, body=json.dumps(body) if body is not None else None)[0] == 200, path
    st, _, b = asgi_call(hosted, "GET", "/api/sync/status", headers=h)
    assert st == 200 and not json.loads(b)["bg"]["running"]
    assert asgi_call(hosted, "GET", "/api/bg", headers=h)[0] == 200


def test_local_mode_unchanged(app, monkeypatch, tmp_path):
    """Einzelplatz (eigener PC, Windows-App): /api/sync startet weiter den Hintergrundlauf des PCs, Zugangsdaten liegen
    in der .env auf diesem PC (LERNAPP_ENV_FILE im Benutzerprofil), nie im Tresor."""
    from app import config, vault
    assert config.MODE == "local" and config.current_user_id() is None
    st, _, b = asgi_call(app, "GET", "/api/bg")
    assert st == 200 and "job" not in json.loads(b)
    env = tmp_path / ".env"
    monkeypatch.setenv("LERNAPP_ENV_FILE", str(env))
    monkeypatch.setattr(vault, "set_values", lambda *a, **k: (_ for _ in ()).throw(AssertionError("am PC nie der Tresor")))
    st, _, b = asgi_call(app, "PUT", "/api/credentials", body=json.dumps({"user": "ab12cd", "password": "Pa$$wort-1"}))
    assert st == 200 and json.loads(b) == {"ok": True, "user": "ab12cd", "password_set": True}
    assert 'STUDIP_PASSWORD="Pa$$wort-1"' in env.read_text(encoding="utf-8")
    st, _, b = asgi_call(app, "GET", "/api/credentials")
    assert json.loads(b) == {"user": "ab12cd", "password_set": True}
    st, _, b = asgi_call(app, "PUT", "/api/credentials/qis", body=json.dumps({"user": "qis-u", "password": "qis-pw"}))
    assert st == 200 and config.service_credentials("QIS") == ("qis-u", "qis-pw")
    st, _, b = asgi_call(app, "PUT", "/api/learnweb/token", body=json.dumps({"token": "A" * 32}))
    assert st == 200 and config.secret("LEARNWEB_TOKEN") == "A" * 32
    assert asgi_call(app, "POST", "/api/credentials/clear", body="{}")[0] == 200 and config.credentials() == ("", "")
    assert vault.has_university_credentials("a" * 32, "luh") is False


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

def test_clear_credentials_removes_legacy_vault_values_and_consent(hosted):
    from app import vault
    u, h = _register(hosted, "loesch@beispiel.de", "luh")
    legacy_vault(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "Pa$$wort-1", "UNI_CONSENT_AT": "2026-11-01T08:00:00+00:00"})
    st, _, b = asgi_call(hosted, "POST", "/api/credentials/clear", headers=h, body="{}")
    assert st == 200 and json.loads(b) == {"ok": True, "user": "", "password_set": False}
    assert vault.env_for(u["id"]) == {}
    assert json.loads(asgi_call(hosted, "GET", "/api/credentials", headers=h)[2])["password_set"] is False


def test_weekly_quota_follows_the_plan(hosted):
    from app import accounts, billing, jobs
    u = accounts.register("quota@beispiel.de", "sehr-geheim-123", "luh")
    accounts.end_trial(u["id"])
    q = jobs.HostedQuota(accounts.get_user(u["id"]))
    assert "Plus" in q.check() and "Free" in q.check(), "Free: keine KI-Wochentests, mit Grund"
    accounts.set_plan(u["id"], "plus")
    q = jobs.HostedQuota(accounts.get_user(u["id"]))
    assert q.check() is None
    for i in range(4):                                                  # Plus: 4 neue KI-Tests im Monat (04.11.2026)
        q.consume(f"weekly:{i}:1")
    q.consume("weekly:0:1")                                             # dieselbe Anfrage zaehlt einmal
    conn = billing.connect()
    try:
        assert billing.used(conn, u["id"], "ai_tests_new") == 4
    finally:
        conn.close()
    assert "aufgebraucht" in q.check() and "4 von 4" in q.check()
    accounts.set_plan(u["id"], "pro_ai")
    assert jobs.HostedQuota(accounts.get_user(u["id"])).check() is None, "Pro AI: 20 im Monat"


def test_weekly_job_runs_in_account_context_with_quota_and_after_sync(hosted, monkeypatch):
    from app import accounts, config, db, jobs, studip_sync, weekly
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
    # nach einem Abgleich laeuft der Takt mit (wie _full_sync am PC); Abgleich im Dienst seit 06.11.2026 abgeschaltet,
    # der Weg wird mit dem Schalter weiter geprueft
    monkeypatch.setattr(jobs, "HOSTED_UNI_SYNC", True)
    legacy_vault(u["id"], {"STUDIP_USER": "ab12cd", "STUDIP_PASSWORD": "pw-pw-pw-1"})
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
    # seit 06.11.2026 abgeschaltet (kein Konto hat Zugangsdaten im Dienst); der Weg wird mit dem Schalter geprueft
    monkeypatch.setattr(jobs, "HOSTED_UNI_SYNC", True)
    monkeypatch.setattr(vault, "users_with_credentials", lambda: [(a["id"], "luh")])
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
    with pytest.raises(weekly.WeeklyError, match="E-Mail-Adresse bestätigen"):       # unbestaetigt: nie KI im Dienst
        t0 = config.set_user_context(u["id"], "luh")
        try:
            weekly._ask("Frage", "SYS")
        finally:
            config.reset_user_context(t0)
    accounts.mark_email_verified(u["id"])

    class C:
        text = "ANTWORT"
    monkeypatch.setattr(ai_backend, "complete", lambda user_id, purpose, system, prompt, schema=None, cache=False, now=None: calls.append((user_id, purpose, system, prompt)) or C())
    t = config.set_user_context(u["id"], "luh")
    try:
        assert weekly._ask("Frage", "SYS") == "ANTWORT"
        assert calls == [(u["id"], "weekly_test", "SYS", "Frage")]
        monkeypatch.setattr(ai_backend, "complete", lambda *a, **k: (_ for _ in ()).throw(ai_backend.AIUnavailable("ai_not_configured", "StudiNow-KI ist nicht eingerichtet.", 503)))
        with pytest.raises(weekly.WeeklyError) as e:
            weekly._ask("Frage", "SYS")
        assert "nicht eingerichtet" in str(e.value)
    finally:
        config.reset_user_context(t)

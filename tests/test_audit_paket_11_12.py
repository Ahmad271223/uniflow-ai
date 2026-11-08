"""Externer Audit 08.11.2026, Pakete 11 und 12 (docs/audit/AUDIT-2026-11-08-PAKET-11-12.md).

Ein Test je Befund (Name = Nummer des Berichts). Keine echten Hochschul-Logins, keine Netzwerkanfragen: Stud.IP ist
eine Attrappe (FakePage). Datenbanken und .env liegen in tmp_path."""
import json
import logging
import math
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

from app import accounts, ai_prices, config, db, studip_sync, weekly

REPO = Path(__file__).resolve().parents[1]

OLD_SCHEMA = """
CREATE TABLE courses (id TEXT PRIMARY KEY, title TEXT NOT NULL, number TEXT, semester TEXT, subject TEXT, kind TEXT,
                      active INTEGER DEFAULT 1, test_minutes INTEGER DEFAULT 90, created_at TEXT);
CREATE TABLE files (id TEXT PRIMARY KEY, course_id TEXT NOT NULL REFERENCES courses(id), name TEXT NOT NULL, size INTEGER,
                    mime TEXT, author TEXT, chdate INTEGER, download_url TEXT, local_path TEXT, downloaded_at TEXT,
                    first_seen TEXT, status TEXT DEFAULT 'neu', seen_by_user INTEGER DEFAULT 0, text_excerpt TEXT);
CREATE TABLE annotations (file_id TEXT PRIMARY KEY REFERENCES files(id), data TEXT NOT NULL, updated_at TEXT);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
"""


def _cols(path, table):
    c = sqlite3.connect(path)
    try:
        return {r[1] for r in c.execute(f"PRAGMA table_info({table})")}
    finally:
        c.close()


# ---------------------------------------------------------------- Paket 11: app/db.py, app/config.py

def test_p11_01_init_db_rolls_back_completely_on_a_late_failure(tmp_path, monkeypatch):
    """Fehler NACH weekly.ensure_schema (letzter Schritt): vorher hatte dessen executescript die ganze bisherige
    Schemaarbeit schon festgeschrieben (Spalte files.kind blieb). Jetzt eine Transaktion: nichts bleibt halb."""
    path = tmp_path / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript(OLD_SCHEMA)
    monkeypatch.setattr(db, "DB_PATH", path)
    orig = weekly.ensure_schema

    def boom(conn):
        orig(conn)
        raise RuntimeError("Fehler am Ende der Migration")
    monkeypatch.setattr(weekly, "ensure_schema", boom)
    with pytest.raises(RuntimeError):
        db.init_db()
    assert "kind" not in _cols(path, "files"), "Migration halb festgeschrieben"
    assert not _cols(path, "modules"), "neue Tabellen trotz Fehler angelegt"
    assert sqlite3.connect(path).execute("PRAGMA user_version").fetchone()[0] == 0
    monkeypatch.setattr(weekly, "ensure_schema", orig)
    db.init_db()                                                  # naechster Start: vollstaendig
    assert "kind" in _cols(path, "files")
    assert sqlite3.connect(path).execute("PRAGMA user_version").fetchone()[0] == db.schema_fingerprint()


class _StaleTableInfo:
    """Verbindung, deren PRAGMA table_info einen alten Stand liefert: so sieht es aus, wenn ein anderer Prozess die
    Spalte zwischen Pruefen und ALTER angelegt hat."""

    def __init__(self, conn, table, missing):
        self._c, self._t, self._m = conn, table, missing

    def execute(self, sql, *a):
        if sql.strip() == f"PRAGMA table_info({self._t})":
            return [r for r in self._c.execute(sql).fetchall() if r[1] != self._m]
        return self._c.execute(sql, *a)

    def __getattr__(self, n):
        return getattr(self._c, n)


def test_p11_02_add_column_tolerates_a_column_another_process_just_added(tmp_path):
    c = sqlite3.connect(tmp_path / "a.db")
    c.execute("CREATE TABLE identities (id TEXT, email TEXT)")
    accounts._migrate(_StaleTableInfo(c, "identities", "email"))        # vorher: duplicate column name: email
    assert db.add_column(_StaleTableInfo(c, "identities", "email"), "identities", "email", "TEXT") is False
    assert db.add_column(c, "identities", "neu", "TEXT") is True
    with pytest.raises(sqlite3.OperationalError):
        db.add_column(c, "gibtsnicht", "x", "TEXT")                   # andere Fehler bleiben Fehler


_CHILD = r'''
import os, sys, time, traceback
sys.path.insert(0, os.environ["REPO"])
from app import accounts, db
t = float(os.environ["START"])
while time.time() < t:
    pass
err = []
try:
    with accounts.cursor() as c:
        c.execute("SELECT 1")
except Exception as e:
    err.append("accounts.db: %r %s" % (e, traceback.extract_tb(e.__traceback__)[-1].line))
try:
    db.init_db(fast=True)
except Exception as e:
    err.append("lernapp.db: %r %s" % (e, traceback.extract_tb(e.__traceback__)[-1].line))
print("ERR " + " | ".join(err) if err else "OK")
'''


def _processes(tmp, n, old):
    env = dict(os.environ, REPO=str(REPO), LERNAPP_DATA_DIR=str(tmp / "data"), LERNAPP_LOG_DIR=str(tmp / "logs"),
               LERNAPP_ENV_FILE=str(tmp / "keine.env"), LERNAPP_NO_SCHEDULER="1", PYTHONDONTWRITEBYTECODE="1")
    env.pop("LERNAPP_MODE", None)
    if old:                       # Stand vor einem Deploy: Dateien gibt es, ein paar spaetere Spalten fehlen
        subprocess.run([sys.executable, "-c", _CHILD], env=dict(env, START="0"), check=True, capture_output=True)
        a = sqlite3.connect(tmp / "data" / "accounts.db")
        a.execute("ALTER TABLE identities DROP COLUMN email")
        a.commit(); a.close()
        c = sqlite3.connect(tmp / "data" / "lernapp.db")
        for t, col in (("files", "page_count"), ("tests", "duration_sec"), ("page_texts", "search"), ("courses", "miscellaneous")):
            c.execute(f"ALTER TABLE {t} DROP COLUMN {col}")
        c.execute("PRAGMA user_version=0")
        c.commit(); c.close()
    env["START"] = str(time.time() + 2.5)
    ps = [subprocess.Popen([sys.executable, "-c", _CHILD], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True) for _ in range(n)]
    return [(p.communicate(timeout=120)[0].strip().splitlines() or ["(keine Ausgabe)"])[-1] for p in ps]


@pytest.mark.parametrize("old", [False, True], ids=["frische-db", "alte-db"])
def test_p11_02_twelve_processes_start_together(tmp_path, old):
    """Wie der Dienst nach einem Neustart: 12 Prozesse oeffnen gleichzeitig accounts.db und dieselbe Konto-DB.
    Vorher: alte DB -> 'duplicate column name: email' (accounts._migrate), frische DB -> 'database is locked'
    (PRAGMA journal_mode=WAL in mehreren Prozessen zugleich)."""
    for r in range(2):
        out = _processes(tmp_path / f"r{r}", 12, old)
        assert [o for o in out if o != "OK"] == [], out
    assert "email" in _cols(tmp_path / "r0" / "data" / "accounts.db", "identities")


@pytest.mark.parametrize("raw,expect", [("nan", 4.0), ("inf", 4.0), ("-inf", 4.0), ("oops", 4.0), ("-3", 4.0),
                                        ("25", 4.0), ("2.5", 2.5)])
def test_p11_03_invalid_hours_per_day_fall_back_to_default(tmp_path, monkeypatch, caplog, raw, expect):
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "s.db")
    db.init_db()
    with db.cursor() as conn:
        db.set_setting(conn, "hours_per_day", raw)
    with caplog.at_level(logging.WARNING), db.cursor() as conn:
        s = db.get_settings(conn)
    assert s["hours_per_day"] == expect and s["minutes_per_day"] == int(expect * 60)
    assert (expect == 4.0) == ("hours_per_day" in caplog.text)


@pytest.mark.parametrize("raw", ["{", '"x"', "[1, \"a\"]", "{\"a\": 1}", "[9]"])
def test_p11_03_invalid_free_days_fall_back_to_default(tmp_path, monkeypatch, caplog, raw):
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "s.db")
    db.init_db()
    with db.cursor() as conn:
        db.set_setting(conn, "free_days", raw)
        db.set_setting(conn, "test_default_minutes", "neunzig")
    with caplog.at_level(logging.WARNING), db.cursor() as conn:
        s = db.get_settings(conn)
    assert s["free_days"] == [6] and s["learn_days"] == [0, 1, 2, 3, 4, 5]
    assert s["test_default_minutes"] == 90
    assert "free_days" in caplog.text


def test_p11_03_settings_api_survives_a_stored_nan(app):
    from conftest import asgi_call
    st, _, _ = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"hours_per_day": "nan", "free_days": "{"}))
    assert st == 200
    st, _, body = asgi_call(app, "GET", "/api/settings")
    assert st == 200, body                                    # vorher 500 (ValueError) bei jedem Aufruf
    asgi_call(app, "PUT", "/api/settings", body=json.dumps({"hours_per_day": 4, "free_days": [6]}))


def test_p11_04_connect_closes_the_connection_when_setup_fails(monkeypatch, tmp_path):
    made = []
    real = sqlite3.connect

    def spy(*a, **k):
        made.append(real(*a, **k))
        return made[-1]
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "c.db")
    monkeypatch.setattr(db.sqlite3, "connect", spy)
    monkeypatch.setattr(db, "wal_once", lambda conn, p: (_ for _ in ()).throw(sqlite3.OperationalError("disk I/O error")))
    with pytest.raises(sqlite3.OperationalError):
        db.connect()
    with pytest.raises(sqlite3.ProgrammingError):              # geschlossen
        made[0].execute("SELECT 1")


def test_p11_05_schema_fingerprint_covers_every_migration_module(monkeypatch):
    """Jedes Modul, das _init_db importiert, steckt in der Kennzahl (vorher nur db, weekly, sync)."""
    import builtins
    import inspect
    import re
    opened = []
    real_open = builtins.open

    def spy(p, *a, **k):
        opened.append(os.path.basename(str(p)))
        return real_open(p, *a, **k)
    monkeypatch.setattr(db, "_FINGERPRINT", None)
    monkeypatch.setattr(builtins, "open", spy)
    db.schema_fingerprint()
    monkeypatch.setattr(builtins, "open", real_open)
    src = inspect.getsource(db._init_db) + inspect.getsource(db.ensure_term)
    used = {m.strip() + ".py" for grp in re.findall(r"from \. import ([\w, ]+)", src) for m in grp.split(",")}
    used.discard("config.py")                                   # liefert nur die Hochschule, kein Schema
    assert used <= set(opened), used - set(opened)


def test_p11_06_accounts_db_uses_wal_with_synchronous_normal():
    """Designentscheidung (Bewertung im Bericht): festgenagelt, damit eine Aenderung bewusst passiert."""
    with accounts.cursor() as c:
        assert c.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
        assert c.execute("PRAGMA synchronous").fetchone()[0] == 1          # NORMAL


@pytest.mark.parametrize("mode", ["hosted", "local"])
def test_p11_07_invalid_files_mode_is_an_error_not_store(monkeypatch, mode):
    monkeypatch.setattr(config, "MODE", mode)
    monkeypatch.setattr(config, "FILES_MODE", "streem")
    with pytest.raises(ValueError):
        config.files_mode()                                    # vorher: "store" (Dateien auf die Platte)
    monkeypatch.setattr(config, "FILES_MODE", "")
    assert config.files_mode() == ("stream" if mode == "hosted" else "store")


def test_p11_07_invalid_files_mode_stops_the_start(tmp_path):
    env = dict(os.environ, LERNAPP_FILES="streem", LERNAPP_MODE="hosted", LERNAPP_DATA_DIR=str(tmp_path / "d"),
               LERNAPP_LOG_DIR=str(tmp_path / "l"), LERNAPP_ENV_FILE=str(tmp_path / "keine.env"))
    r = subprocess.run([sys.executable, "-c", "import app.config"], cwd=REPO, env=env, capture_output=True, text=True)
    assert r.returncode != 0 and "LERNAPP_FILES" in r.stderr


def test_p11_08_unknown_university_from_user_input_is_rejected(app):
    """Bewertung: still normalisiert wird nur Gespeichertes; Eingaben (Registrierung, Einstellungen) werden abgelehnt."""
    from conftest import asgi_call
    from app import universities
    assert config.normalize_university("tippfehler") == universities.DEFAULT
    st, _, _ = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"university": "tippfehler"}))
    assert st == 400
    with pytest.raises(accounts.AccountError):
        accounts.register("p11-08@example.org", "ein-langes-passwort-123", university="tippfehler")


def test_p11_09_hard_cap_covers_every_image_size_and_model():
    sizes = [(1, 1), (511, 513), (768, 768), (1024, 768), (2048, 2048), (4000, 3000), (12000, 300), (300, 12000)]
    for model in ai_prices.table():
        worst = ai_prices.image_tokens_worst(model)
        for s in sizes:
            for detail in ("high", "low"):
                assert ai_prices.image_tokens(model, s, detail) <= worst, (model, s, detail)
        p = ai_prices.price(model)
        cap = ai_prices.worst_case_microeur(model, "sys", "frage äöü", 500, images=[b"x"])
        used_in = ai_prices.worst_input_tokens("sys", "frage äöü", None, 1, model)
        assert ai_prices.cost_microeur(model, used_in, 500) <= cap, model
        n = ai_prices.max_output_within(model, "sys", "frage", 50_000)
        assert ai_prices.worst_case_microeur(model, "sys", "frage", n) <= 50_000 or n == 0, model
        assert p is not None


# ---------------------------------------------------------------- Paket 12: config.set_env & Co.

@pytest.fixture
def env_file(tmp_path, monkeypatch):
    f = tmp_path / "x.env"
    f.write_text("A=1\n", encoding="utf-8")
    monkeypatch.setenv("LERNAPP_ENV_FILE", str(f))
    monkeypatch.setattr(config, "MODE", "local")
    return f


def test_p12_01_hosted_without_user_context_never_writes_the_env(env_file, monkeypatch):
    monkeypatch.setattr(config, "MODE", "hosted")
    assert config.current_user_id() is None
    with pytest.raises(RuntimeError):
        config.set_env({"STUDIP_PASSWORD": "geheim"})
    assert env_file.read_text(encoding="utf-8") == "A=1\n"


def test_p12_02_parallel_set_env_loses_nothing(env_file):
    errors, start = [], threading.Barrier(8)

    def work(i):
        start.wait()
        try:
            for j in range(25):
                config.set_env({f"K{i}_{j}": str(j)})
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=work, args=(i,)) for i in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    from dotenv import dotenv_values
    v = dotenv_values(env_file)
    assert errors == []
    assert [f"K{i}_{j}" for i in range(8) for j in range(25) if f"K{i}_{j}" not in v] == []
    assert not list(env_file.parent.glob("*.tmp")) and not list(env_file.parent.glob(".env*tmp*"))


@pytest.mark.skipif(os.name != "posix", reason="POSIX-Rechte")
def test_p12_03_env_file_is_private(env_file):
    old = os.umask(0o022)
    try:
        env_file.unlink()
        config.set_env({"STUDIP_PASSWORD": "geheim"})
    finally:
        os.umask(old)
    assert stat.S_IMODE(env_file.stat().st_mode) == 0o600


def test_p12_04_same_as_cycle_ends_like_an_unconfigured_service(env_file):
    env_file.write_text("QIS_SAME_AS=IDM\nIDM_SAME_AS=QIS\nSTUDIP_USER=luh-id\nSTUDIP_PASSWORD=pw\n", encoding="utf-8")
    assert config.service_credentials("QIS") == ("luh-id", "pw")       # = Rueckfall ohne Eintrag (Regel fuer LUH-Dienste)
    env_file.write_text("STUDIP_USER=luh-id\nSTUDIP_PASSWORD=pw\n", encoding="utf-8")
    assert config.service_credentials("QIS") == ("luh-id", "pw")
    env_file.write_text("HILDESHEIM_SAME_AS=IDM\nIDM_SAME_AS=HILDESHEIM\nSTUDIP_USER=luh-id\nSTUDIP_PASSWORD=pw\n", encoding="utf-8")
    assert config.own_credentials("HILDESHEIM") == ("", "")            # fremde Hochschule: nie die LUH-ID


def test_p12_05_retiring_twice_in_one_second_keeps_both(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "BASE_DATA_DIR", tmp_path)
    uid = "a" * 32
    got = []
    for i in range(2):
        (tmp_path / "users" / uid).mkdir(parents=True)
        (tmp_path / "users" / uid / "f.txt").write_text(str(i))
        got.append(config.retire_user_data_dir(uid))                   # vorher: OSError (Ziel existiert) beim zweiten
    assert got[0] != got[1] and all(p.exists() for p in got)
    assert config.retired_user_data_dirs(uid) == sorted(got)


# ---------------------------------------------------------------- Paket 12: studip_sync (Attrappe statt Stud.IP)

class _Resp:
    def __init__(self, status, body):
        self.status, self._b = status, body
        self.ok = 200 <= status < 300

    def json(self):
        return self._b

    def text(self):
        return json.dumps(self._b)


class FakePage:
    """page.request.get(url) -> Antwort aus `routes` (url -> (status, body)); merkt sich jede angefragte Adresse."""

    def __init__(self, routes):
        self.routes, self.calls = routes, []
        self.request = self

    def get(self, url, headers=None):
        self.calls.append(url)
        if len(self.calls) > 500:
            raise AssertionError("Endlosschleife")
        st, body = self.routes.get(url, (404, {}))
        return _Resp(st, body)


B = studip_sync.STUDIP_BASE
ME = f"{B}/jsonapi.php/v1/users/me"
C1 = f"{B}/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester"


def _course(i):
    return {"id": f"c{i}", "type": "courses", "attributes": {"title": f"Kurs {i}"}, "relationships": {}}


@pytest.mark.parametrize("nxt", ["https://evil.example/jsonapi.php/v1/x", "http://" + B.split("://", 1)[1] + "/jsonapi.php/v1/x",
                                 "//evil.example/x"])
def test_p12_06_fetch_courses_never_follows_a_foreign_next_link(nxt, monkeypatch):
    monkeypatch.setattr(studip_sync, "log", lambda m: None)
    page = FakePage({ME: (200, {"data": {"id": "u1"}}), C1: (200, {"data": [_course(1)], "links": {"next": nxt}})})
    with pytest.raises(RuntimeError):
        studip_sync.fetch_courses(page)
    assert all(u.startswith(B + "/") for u in page.calls), page.calls


def test_p12_06_fetch_courses_follows_relative_and_same_host_links():
    p2 = f"{B}/jsonapi.php/v1/users/u1/courses?page[offset]=100"
    page = FakePage({ME: (200, {"data": {"id": "u1"}}),
                     C1: (200, {"data": [_course(1)], "links": {"next": "/jsonapi.php/v1/users/u1/courses?page[offset]=100"}}),
                     p2: (200, {"data": [_course(2)], "links": {}})})
    assert [c["id"] for c in studip_sync.fetch_courses(page)] == ["c1", "c2"]


def test_p12_11_fetch_courses_stops_on_a_self_loop():
    page = FakePage({ME: (200, {"data": {"id": "u1"}}), C1: (200, {"data": [_course(1)], "links": {"next": C1}})})
    with pytest.raises(RuntimeError):
        studip_sync.fetch_courses(page)                          # vorher: Endlosschleife
    assert len(page.calls) <= 3


def test_p12_11_fetch_courses_stops_after_the_page_limit():
    routes = {ME: (200, {"data": {"id": "u1"}})}
    url = C1
    for i in range(studip_sync.MAX_LIST_PAGES + 5):
        nxt = f"{B}/jsonapi.php/v1/users/u1/courses?page[offset]={(i + 1) * 100}"
        routes[url] = (200, {"data": [_course(i)], "links": {"next": nxt}})
        url = nxt
    with pytest.raises(RuntimeError):
        studip_sync.fetch_courses(FakePage(routes))


L1 = f"{B}/jsonapi.php/v1/courses/c1/news?page[limit]=100"


@pytest.mark.parametrize("nxt", ["https://evil.example/n", L1])
def test_p12_07_api_list_foreign_or_looping_next_is_incomplete(nxt):
    page = FakePage({L1: (200, {"data": [{"id": "n1"}], "links": {"next": nxt}})})
    assert studip_sync.api_list(page, L1) is None                # vorher: Teilmenge als Erfolg bzw. fremder Host
    assert "https://evil.example/n" not in page.calls


def test_p12_07_api_list_page_limit_is_incomplete_not_success():
    routes, url = {}, L1
    for i in range(4):
        nxt = f"{B}/jsonapi.php/v1/courses/c1/news?page[offset]={i + 1}"
        routes[url] = (200, {"data": [{"id": f"n{i}"}], "links": {"next": nxt}})
        url = nxt
    assert studip_sync.api_list(FakePage(routes), L1, max_pages=3) is None
    routes[url] = (200, {"data": [], "links": {}})
    assert len(studip_sync.api_list(FakePage(routes), L1, max_pages=5)) == 4


E1 = f"{B}/jsonapi.php/v1/courses/c1/events?page[limit]=200"
E2 = f"{B}/jsonapi.php/v1/courses/c1/events?page[offset]=200"


def _event(i):
    return {"id": f"e{i}", "attributes": {"title": "S", "start": "2026-11-09T10:00:00", "end": "2026-11-09T12:00:00"}}


def test_p12_08_fetch_events_error_on_page_two_is_not_a_complete_list(monkeypatch):
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    page = FakePage({E1: (200, {"data": [_event(1)], "links": {"next": E2}}), E2: (500, {})})
    with pytest.raises(RuntimeError):
        studip_sync.fetch_events(page, "c1")                     # vorher: [e1] als vollstaendige Liste
    page = FakePage({E1: (200, {"data": [_event(1)], "links": {"next": "https://evil.example/e"}})})
    with pytest.raises(RuntimeError):
        studip_sync.fetch_events(page, "c1")
    page = FakePage({E1: (200, {"data": [_event(1)], "links": {"next": E2}}), E2: (200, {"data": [_event(2)]})})
    assert [e["id"] for e in studip_sync.fetch_events(page, "c1")] == ["e1", "e2"]


def test_p12_08_store_events_only_upserts():
    """Bewertung der Folge: auch eine Teilliste haette nichts entfernt (store_events loescht nie)."""
    import inspect
    assert "DELETE" not in inspect.getsource(studip_sync.store_events).upper()
    assert "DELETE" not in inspect.getsource(studip_sync.store_schedule_entries).upper()


def test_p12_09_schedule_error_is_not_an_empty_schedule(monkeypatch):
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    S = f"{B}/jsonapi.php/v1/users/u1/schedule"
    with pytest.raises(RuntimeError):
        studip_sync.fetch_schedule_entries(FakePage({S: (503, {})}), "u1")      # vorher: []
    assert studip_sync.fetch_schedule_entries(FakePage({S: (200, {"data": []})}), "u1") == []


def test_p12_10_login_screenshot_goes_only_to_the_own_log_dir():
    """Bewertung (Designentscheidung): eine Datei, jedes Mal ueberschrieben, im Protokollordner des Kontos bzw. PCs."""
    import inspect
    src = inspect.getsource(studip_sync.login) + inspect.getsource(studip_sync._login)
    assert src.count('config.log_dir() / "login-fehler.png"') + src.count("config.log_dir() / 'login-fehler.png'") >= 2


@pytest.mark.parametrize("n", [0, -1])
def test_p12_12_api_get_rejects_attempts_below_one(n):
    with pytest.raises(ValueError):
        studip_sync.api_get(FakePage({}), f"{B}/x", attempts=n)  # vorher: UnboundLocalError

"""Externer statischer Audit vom 08.11.2026, Pakete 3 und 4 (docs/audit/AUDIT-2026-11-08-PAKET-3-4.md):
app/accounts.py (login_with_identity .. main), app/sync.py, app/retention.py, app/community.py.

Je Befund ein Test: bestaetigte Fehler wurden zuerst hier rot nachgestellt und dann minimal behoben; widerlegte oder
nicht erreichbare Behauptungen nagelt der Test im heutigen Verhalten fest."""
import json
import shutil
import sqlite3
import time
from datetime import date, datetime, timedelta, timezone

import pytest
from conftest import asgi_call

UNKNOWN_ID = "0" * 32
PAST, FUTURE = "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z"
KURS, ANDERER_KURS, GRUPPE = "1" * 64, "2" * 64, "3" * 64
FP = "a" * 64


@pytest.fixture
def hosted(app, monkeypatch):
    """Dienstmodus mit frischer accounts.db und community.db (wie tests/test_community.py und tests/test_retention.py)."""
    from app import accounts, community, config, retention, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for p in (accounts.db_path(), community.db_path()):
        for suffix in ("", "-wal", "-shm"):
            p.with_name(p.name + suffix).unlink(missing_ok=True)
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    shutil.rmtree(retention.access_log_dir(), ignore_errors=True)
    vault.key_file().unlink(missing_ok=True)
    vault.reset_master()
    yield app
    for p in (accounts.db_path(), community.db_path()):
        p.unlink(missing_ok=True)
    shutil.rmtree(community.package_dir(), ignore_errors=True)
    shutil.rmtree(retention.access_log_dir(), ignore_errors=True)
    vault.reset_master()


@pytest.fixture
def conn(tmp_path):
    """Kontodatenbank fuer app/sync.py ohne Dienst (wie tests/test_sync.py)."""
    from app import db
    c = sqlite3.connect(tmp_path / "sync.db", check_same_thread=False)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys=ON")
    db._init_db(c)
    c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Kurs', 'vorlesung', 1, '2026-10-26')")
    c.execute("INSERT INTO files(id, course_id, name, kind, status) VALUES ('f1', 'c1', 'x.pdf', 'pdf', 'neu')")
    c.commit()
    yield c
    c.close()


def _register(app, email, uni="luh", plus=False, verified=True):
    from app import accounts
    st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    assert st == 201, b
    d = json.loads(b)
    accounts.end_trial(d["user"]["id"])
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    return accounts.get_user(d["user"]["id"]), {"Authorization": f"Bearer {d['token']}"}      # Stand nach den Aenderungen


# ================================================================ PAKET 03 - app/accounts.py (61-71)

def test_61_login_with_identity_positive_and_negative(hosted, monkeypatch):
    from app import accounts
    monkeypatch.setitem(accounts.identity_verifiers, "apple",
                        lambda tok, nonce=None: {"subject": "sub-1", "email": "p@beispiel.de", "email_verified": True} if tok == "gut" else None)
    user, token, created = accounts.login_with_identity("apple", "gut", university="luh")
    assert created is True and user["email"] == "p@beispiel.de" and accounts.authenticate(token)["id"] == user["id"]
    _, _, again = accounts.login_with_identity("apple", "gut", university="luh")
    assert again is False, "zweite Anmeldung findet das Konto ueber die Anbieter-Kennung"
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_identity("apple", "schlecht")
    assert (x.value.code, x.value.status) == ("identity_invalid", 401)
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_identity("unbekannt", "gut")
    assert (x.value.code, x.value.status) == ("provider_not_configured", 501)


def test_62_67_68_unknown_user_id_is_404_not_type_error(hosted):
    """Befund 62/67/68 und Korrekturauftrag 5: vorher `_public(None)` -> TypeError. Ueber die API nicht erreichbar
    (die Sitzung gehoert immer zu einem bestehenden Konto), aber fuer CLI, Werkzeuge und Tests sauber als 404."""
    from app import accounts
    for fn, args in ((accounts.set_university, (UNKNOWN_ID, "luh")), (accounts.set_plan, (UNKNOWN_ID, "plus")),
                     (accounts.set_role, (UNKNOWN_ID, "admin"))):
        with pytest.raises(accounts.AccountError) as x:
            fn(*args)
        assert (x.value.code, x.value.status) == ("not_found", 404), fn.__name__
    with pytest.raises(accounts.AccountError) as x:
        accounts.set_university(UNKNOWN_ID, "nirgendwo")
    assert x.value.code == "university_unknown", "Hochschule wird vor dem Konto geprueft"
    u = accounts.register("echt@beispiel.de", "sehr-geheim-123", "luh")
    assert accounts.set_plan(u["id"], "plus")["plan"] == "plus"
    assert accounts.set_role(u["id"], "admin")["role"] == "admin"
    assert accounts.set_university(u["id"], "hildesheim")["university"] == "hildesheim"


def test_62_set_university_over_the_api_only_for_the_own_active_account(hosted):
    u, h = _register(hosted, "wechsel@beispiel.de")
    st, _, b = asgi_call(hosted, "POST", "/api/account/university", headers=h, body=json.dumps({"university": "hildesheim"}))
    assert st == 200 and json.loads(b)["user"]["university"] == "hildesheim"
    st, _, b = asgi_call(hosted, "POST", "/api/account/university", headers=h, body=json.dumps({"university": "nirgendwo"}))
    assert st == 400 and json.loads(b)["code"] == "university_unknown"
    assert asgi_call(hosted, "POST", "/api/account/university", body=json.dumps({"university": "luh"}))[0] == 401


def test_63_delete_account_revokes_sessions_and_withdraws_community(hosted, monkeypatch):
    from app import accounts, community
    u, h = _register(hosted, "weg@beispiel.de")
    _, tok = accounts.login("weg@beispiel.de", "sehr-geheim-123")
    seen = []
    monkeypatch.setattr(community, "withdraw_all", lambda uid, reason: seen.append((uid, reason)) or 0)
    assert accounts.delete_account(u["id"], "sehr-geheim-123")["deleted"] is True
    assert accounts.authenticate(tok) is None and seen == [(u["id"], "account_deleted")]
    with pytest.raises(accounts.AccountError) as x:
        accounts.delete_account(u["id"], "sehr-geheim-123")
    assert x.value.status == 404, "zweites Loeschen: Konto nicht mehr aktiv"


def test_64_65_purge_user_removes_every_table_with_a_user_id(hosted):
    """_has_table mit fehlender Tabelle; _purge_user leert alle Tabellen mit Fremdschluessel auf users."""
    from app import accounts
    u = accounts.register("leer@beispiel.de", "sehr-geheim-123", "luh")
    accounts.login("leer@beispiel.de", "sehr-geheim-123")
    with accounts.cursor() as conn:
        assert accounts._has_table(conn, "users") and not accounts._has_table(conn, "gibt_es_nicht")
        assert accounts._has_table(conn, "sessions'); DROP TABLE users; --") is False, "Name ist Parameter, kein SQL"
        accounts._purge_user(conn, u["id"])
        for t in ("users", "sessions"):
            col = "id" if t == "users" else "user_id"
            assert conn.execute(f"SELECT COUNT(*) FROM {t} WHERE {col}=?", (u["id"],)).fetchone()[0] == 0, t


def test_66_purge_deleted_retries_when_the_data_dir_cannot_be_removed(hosted, monkeypatch):
    """Befund 66 / Korrekturauftrag 1: vorher `shutil.rmtree(..., ignore_errors=True)` NACH dem Loeschen der
    Datenbankzeilen - ein Ordner, der sich nicht loeschen liess, blieb fuer immer liegen (kein Konto mehr, das ihn
    beim naechsten Lauf findet). Jetzt: Ordner zuerst, Fehler -> Konto bleibt fuer den naechsten Lauf."""
    from app import accounts, config
    u = accounts.register("ordner@beispiel.de", "sehr-geheim-123", "luh")
    d = config.user_data_dir(u["id"], "luh")
    d.mkdir(parents=True, exist_ok=True)
    (d / "lernapp.db").write_bytes(b"x")
    accounts.delete_account(u["id"], "sehr-geheim-123")
    assert config.retired_user_data_dirs(u["id"])
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    real_rmtree = shutil.rmtree

    def failing_rmtree(path, *a, **k):
        if "users-deleted" in str(path):
            raise OSError("Platte schreibgeschuetzt")
        return real_rmtree(path, *a, **k)
    monkeypatch.setattr(shutil, "rmtree", failing_rmtree)
    assert accounts.purge_deleted() == 0, "Fehler beim Ordner: Konto bleibt fuer den naechsten Lauf"
    assert accounts.get_user(u["id"]) is not None and config.retired_user_data_dirs(u["id"])
    monkeypatch.setattr(shutil, "rmtree", real_rmtree)
    assert accounts.purge_deleted() == 1
    assert accounts.get_user(u["id"]) is None and not config.retired_user_data_dirs(u["id"])


def test_69_70_user_lookup_includes_deleted_accounts_by_id_but_not_by_email(hosted):
    """Befund 70: get_user filtert `deleted` nicht - die Aufrufer (jobs.run_job, community.reporter_info) brauchen auch
    geloeschte Konten; die API nutzt nur authenticate (nur aktive). Festgenagelt, keine Aenderung."""
    from app import accounts
    u = accounts.register("Such@Beispiel.de", "sehr-geheim-123", "luh")
    assert accounts.user_by_email("  such@beispiel.DE ")["id"] == u["id"] and accounts.user_by_email("x@y.de") is None
    accounts.delete_account(u["id"], "sehr-geheim-123")
    assert accounts.user_by_email("such@beispiel.de") is None, "Adresse ist nach dem Loeschen frei"
    assert accounts.get_user(u["id"])["email"].startswith("deleted-") and accounts.get_user(UNKNOWN_ID) is None


def test_71_admin_cli_plan_and_role(hosted, capsys):
    from app import accounts
    u = accounts.register("cli@beispiel.de", "sehr-geheim-123", "luh")
    assert accounts.main(["plan", "niemand@beispiel.de", "plus"]) == 1
    assert accounts.main(["plan", "cli@beispiel.de", "gold"]) == 1 and "Tarif" in capsys.readouterr().out
    assert accounts.main(["plan", "cli@beispiel.de", "plus", "2027-01-31"]) == 0
    assert json.loads(capsys.readouterr().out.strip().splitlines()[-1]) == {"email": "cli@beispiel.de", "plan": "plus", "plan_until": "2027-01-31", "role": "user"}
    assert accounts.main(["role", "cli@beispiel.de", "admin"]) == 0 and accounts.get_user(u["id"])["role"] == "admin"
    assert accounts.main(["role", "cli@beispiel.de", "gott"]) == 1
    assert accounts.main([]) == 2 and accounts.main(["unsinn"]) == 2


# ================================================================ PAKET 03 - app/sync.py (72-84)

def test_72_73_now_utc_format_and_future_cursor_is_not_awaited():
    from app import sync
    t = sync.now_utc()
    assert sync.TS_RE.match(t) and t.endswith("Z") and len(t) == 24
    t0 = time.monotonic()
    sync._clock_past(FUTURE)
    assert time.monotonic() - t0 < 0.5, "Cursor in der Zukunft: hoechstens CURSOR_WAIT_MAX warten"
    sync._clock_past(PAST)


def test_74_ensure_schema_is_idempotent_and_does_not_bump_versions(conn):
    from app import sync
    conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('M', '#111111', 0, '2026-10-28')")
    before = dict(conn.execute("SELECT sync_version, sync_updated_at FROM modules WHERE name='M'").fetchone())
    sync.ensure_schema(conn)
    sync.ensure_schema(conn)
    assert dict(conn.execute("SELECT sync_version, sync_updated_at FROM modules WHERE name='M'").fetchone()) == before
    assert conn.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%_modules'").fetchone()[0] == 3


def test_76_pull_survives_corrupt_annotation_json(conn):
    """Befund 76: vorher JSONDecodeError -> der ganze Abruf des Kontos antwortete 500, dauerhaft. Jetzt: leere Notizen
    mit der Version des Servers; die naechste Aenderung des Geraets ueberschreibt den kaputten Stand."""
    from app import sync
    conn.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES ('f1', '{kaputt', '2026-01-01', 3)")
    out = sync.changes(conn, None)
    ann = out["changes"]["annotations"]
    assert len(ann) == 1 and ann[0]["data"] == {} and ann[0]["version"] == 3
    # Konflikt auf die kaputte Notiz: Serverstand kommt ebenfalls als leeres Objekt statt 500
    r = sync.push(conn, "ipad", [{"entity": "annotations", "id": "f1", "base_version": 1, "data": {"strokes": []}}])
    assert r["results"][0]["status"] == "conflict" and r["results"][0]["data"] == {} and r["results"][0]["version"] == 3
    r = sync.push(conn, "ipad", [{"entity": "annotations", "id": "f1", "base_version": 3, "data": {"strokes": []}}])
    assert r["results"][0]["status"] == "applied" and r["results"][0]["version"] == 4
    assert sync.changes(conn, None)["changes"]["annotations"][0]["data"] == {"strokes": []}


def test_77_78_tied_timestamps_make_one_page_larger_but_lose_nothing(conn):
    """Befund 77 / Korrekturauftrag 3: 50 Zeilen mit demselben Zeitstempel (eine UPDATE-Anweisung) und limit 3.
    Bestaetigt: die Seite ist groesser als limit (alle Zeilen des letzten Zeitstempels). Widerlegt: kein Datenverlust,
    keine Endlosschleife. Die Seitengroesse ist durch die Zeilen EINER Anweisung begrenzt, nicht unbegrenzt."""
    from app import sync
    for i in range(50):
        conn.execute("INSERT INTO flashcards(question, answer, box) VALUES (?, 'A', 1)", (f"Q{i}",))
    conn.execute("UPDATE flashcards SET box=2")
    since, pages, got, sizes = None, 0, [], []
    while True:
        r = sync.changes(conn, since, 3)
        pages += 1
        got += r["changes"].get("flashcards", [])
        sizes.append(sum(len(v) for v in r["changes"].values()))
        assert r["cursor"] is None or not since or r["cursor"] >= since
        since = r["cursor"]
        if not r["has_more"]:
            break
        assert pages < 50
    assert sorted(c["question"] for c in got) == sorted(f"Q{i}" for i in range(50)), "keine Karte verloren, keine doppelt"
    assert max(sizes) >= 50, "Gleichstand: eine Seite traegt alle 50 Karten (ueber limit 3)"
    assert len(got) == 50
    assert sync.changes(conn, since, 3) == {"cursor": since, "changes": {}, "tombstones": [], "has_more": False}
    # Tombstones mit Gleichstand ebenso vollstaendig
    conn.execute("DELETE FROM flashcards")
    r = sync.changes(conn, since, 3)
    assert len(r["tombstones"]) == 50 or sum(len(sync.changes(conn, c, 3)["tombstones"]) for c in [r["cursor"]]) + len(r["tombstones"]) == 50


def test_79_80_82_push_isolates_bad_ids_and_constraint_errors_per_item(conn):
    """Befunde 79/80/82: vorher ValueError (`int('abc')`), TypeError (Loeschen ohne id), IntegrityError (Fremdschluessel
    auf eine nicht vorhandene positive ID, NOT NULL) -> der ganze Push brach ab (500, alles zurueckgerollt); das Geraet
    haette denselben Push endlos wiederholt. Jetzt: `error` je Eintrag, die uebrigen Eintraege werden uebernommen."""
    from app import sync
    conn.execute("DELETE FROM flashcards")
    items = [
        {"entity": "modules", "id": "abc", "data": {"name": "kaputte ID"}},
        {"entity": "modules", "id": 1, "base_version": "x", "data": {"name": "Basisversion kaputt"}},
        {"entity": "study_packages", "local_id": -1, "data": {"date": "2026-11-02", "module_id": 999999, "subject": "S", "title": "Fremd"}},
        {"entity": "modules", "local_id": -2, "data": {}},
        {"entity": "flashcards", "local_id": -3, "data": {"question": "Gut", "answer": "A", "box": 1}},
    ]
    out = sync.push(conn, "ipad", items, [{"entity": "modules"}, {"entity": "modules", "id": "x"}])
    by = {(r["entity"], r.get("local_id"), r.get("id")): r for r in out["results"]}
    assert by[("modules", None, "abc")]["status"] == "error"
    assert by[("study_packages", -1, None)]["status"] == "error" and "study_packages" in by[("study_packages", -1, None)]["message"]
    assert by[("modules", -2, None)]["status"] == "error"
    good = [r for r in out["results"] if r["entity"] == "flashcards"][0]
    assert good["status"] == "created" and conn.execute("SELECT COUNT(*) FROM flashcards WHERE question='Gut'").fetchone()[0] == 1
    dels = [r for r in out["results"] if r["entity"] == "modules" and r.get("local_id") is None and r.get("id") in (None, "x")]
    assert [r["status"] for r in dels] == ["error", "error"]
    assert conn.execute("SELECT COUNT(*) FROM study_packages WHERE title='Fremd'").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM modules WHERE name='kaputte ID'").fetchone()[0] == 0
    assert all("Traceback" not in json.dumps(r) for r in out["results"])


def test_79_push_endpoint_answers_200_with_error_items_instead_of_500(app):
    body = {"device_id": "ipad-9", "items": [{"entity": "modules", "id": "abc", "data": {"name": "x"}},
                                             {"entity": "modules", "local_id": -1, "data": {"name": "Audit-Push-OK"}}]}
    st, _, b = asgi_call(app, "POST", "/api/sync/push", body=json.dumps(body))
    out = json.loads(b)
    assert st == 200 and [r["status"] for r in out["results"]] == ["error", "created"]
    from app import db
    with db.cursor() as c:
        c.execute("DELETE FROM modules WHERE name='Audit-Push-OK'")


def test_81_merge_fields_trusts_the_client_clock(conn):
    """Befund 81: der spaetere Zeitstempel gewinnt je Feld, auch wenn die Uhr des Geraets vorgeht. Das ist der Vertrag
    (fixtures/merge/cases.json, tests/test_merge_contract.py) - festgenagelt, Aenderung waere eine Produktentscheidung."""
    from app import sync
    server = {"id": 1, "name": "Server", "color": "#000000"}
    out, won = sync._merge_fields(server, {"name": "Client"}, FUTURE, "2026-11-01T00:00:00.000Z", ["id", "name", "color"])
    assert out["name"] == "Client" and won == ["name"]
    out, won = sync._merge_fields(server, {"name": "Client"}, PAST, "2026-11-01T00:00:00.000Z", ["id", "name", "color"])
    assert out["name"] == "Server" and won == []
    out, won = sync._merge_fields(server, {"name": "Client"}, "2026-11-01T00:00:00.000Z", "2026-11-01T00:00:00.000Z", ["id", "name"])
    assert won == ["name"], "Gleichstand: Client gewinnt (>=)"


def test_82_unknown_positive_id_is_created_as_documented(conn):
    from app import sync
    r = sync.push(conn, "ipad", [{"entity": "modules", "id": 4242, "data": {"name": "Fremdes Geraet"}}])
    assert r["results"][0]["status"] == "created" and conn.execute("SELECT name FROM modules WHERE id=4242").fetchone()[0] == "Fremdes Geraet"


def test_83_84_device_file_registration_limits(conn):
    from app import sync
    ok = {"entity": "annotations", "id": "neu-1", "base_version": None, "data": {"strokes": []},
          "file": {"name": "Blatt.pdf", "course_id": "kurs-7", "course_title": "Mathe", "semester": "WiSe 26/27"}}
    assert sync.push(conn, "ipad", [ok])["results"][0]["status"] == "applied"
    f = conn.execute("SELECT course_id, download_url, status FROM files WHERE id='neu-1'").fetchone()
    assert (f["course_id"], f["download_url"], f["status"]) == ("kurs-7", None, "neu"), "ohne Adresse: Dienst laedt nie, Community gilt nicht"
    bad = [dict(ok, id="x" * 201), dict(ok, id="neu-2", file={"name": "B.pdf", "course_id": "__user__"}), dict(ok, id="neu-3", file=None)]
    assert [r["status"] for r in sync.push(conn, "ipad", bad)["results"]] == ["unknown_file"] * 3


# ================================================================ PAKET 03 - app/retention.py (85-90)

def test_85_88_access_log_dir_and_account_dirs_ignore_files(hosted, tmp_path):
    from app import config, retention
    assert retention.access_log_dir() == config.BASE_LOG_DIR / "access"
    base = config.BASE_DATA_DIR / "users"
    shutil.rmtree(base, ignore_errors=True)
    uid = "a" * 32
    (base / uid / "unis" / "hildesheim").mkdir(parents=True)
    (base / uid / "unis" / "notiz.txt").write_text("x")
    (base / "streuner.txt").write_text("x")
    assert retention.account_dirs() == [base / uid, base / uid / "unis" / "hildesheim"]
    shutil.rmtree(base, ignore_errors=True)


def test_86_log_access_strips_line_breaks_from_every_field(hosted):
    """Befund 86 / Korrekturauftrag 4: der Pfad kommt prozent-dekodiert an (%0A -> Zeilenumbruch) und stand roh im
    Protokoll - eine Anfrage konnte eine gefaelschte Zeile anhaengen. Jetzt werden Steuerzeichen in allen Feldern ersetzt."""
    from app import retention
    now = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc)
    f = retention.access_log_dir() / "access-2026-11-08.log"
    retention.log_access("1.2.3.4\r", "GET\n", "/api/x\n2026-11-08T12:00:00Z 9.9.9.9 GET /gefaelscht 200 1ms \"\"?token=geheim", 200, 1.5, "UA\r\nZeile2", now)
    lines = f.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1 and "\r" not in lines[0] and "geheim" not in lines[0]
    assert lines[0].startswith("2026-11-08T12:00:00Z 1.2.3.4") and "/gefaelscht" in lines[0]
    # ueber die API: der ASGI-Pfad ist dekodiert wie bei uvicorn
    asgi_call(hosted, "GET", "/api/account/info%0A2026-11-08T00:00:00Z%209.9.9.9%20GET%20/fake%20200")
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = (retention.access_log_dir() / f"access-{today}.log").read_text(encoding="utf-8").splitlines()
    mine = [l for l in lines if "/fake" in l]
    assert len(mine) == 1 and mine[0].startswith(today) and " GET /api/account/info" in mine[0]
    assert not any(l.startswith("2026-11-08T00:00:00Z 9.9.9.9") for l in lines)


def test_87_purge_access_logs_skips_invalid_date_names(hosted):
    """Befund 87: `access-2026-99-99.log` passt auf den Regex, `date.fromisoformat` warf ValueError und brach den Lauf ab."""
    from app import retention
    d = retention.access_log_dir()
    d.mkdir(parents=True, exist_ok=True)
    for name in ("access-2026-99-99.log", "access-2026-02-30.log", "access-2026-01-01.log", "access-2026-11-08.log"):
        (d / name).write_text("x\n")
    assert retention.purge_access_logs(date(2026, 11, 8)) == 1
    assert sorted(p.name for p in d.iterdir()) == ["access-2026-02-30.log", "access-2026-11-08.log", "access-2026-99-99.log"]


def test_89_trim_dated_log_handles_invalid_dates_and_write_errors(tmp_path, monkeypatch):
    """Befund 89: eine Zeile `2026-13-45 ...` warf ValueError; bei einem Schreibfehler blieb die .tmp-Datei liegen."""
    from pathlib import Path
    from app import retention
    p = tmp_path / "sync.log"
    p.write_text("2020-01-01 alt\n2026-13-45 kaputt, gehoert zum alten Block\n2026-10-20 neu\n2026-99-99 kaputt, gehoert zum neuen\n", encoding="utf-8")
    assert retention.trim_dated_log(p, date(2026, 1, 1)) == 2
    assert p.read_text(encoding="utf-8") == "2026-10-20 neu\n2026-99-99 kaputt, gehoert zum neuen\n"
    p.write_text("2020-01-01 alt\n2026-10-20 neu\n", encoding="utf-8")
    real = Path.write_text

    def failing(self, *a, **k):
        if self.suffix == ".tmp":
            raise OSError("voll")
        return real(self, *a, **k)
    monkeypatch.setattr(Path, "write_text", failing)
    with pytest.raises(OSError):
        retention.trim_dated_log(p, date(2026, 1, 1))
    assert not list(tmp_path.glob("*.tmp")) and p.read_text(encoding="utf-8") == "2020-01-01 alt\n2026-10-20 neu\n", "Original unveraendert"


def test_90_purge_account_logs_continues_after_a_broken_account(hosted, monkeypatch):
    """Befund 90: ein Fehler in einem Konto brach den ganzen Lauf ab; jetzt wird er gezaehlt und protokolliert."""
    from app import config, retention
    base = config.BASE_DATA_DIR / "users"
    shutil.rmtree(base, ignore_errors=True)
    a, b = base / ("a" * 32) / "logs", base / ("b" * 32) / "logs"
    for d in (a, b):
        d.mkdir(parents=True)
        (d / "sync.log").write_text("2020-01-01 alt\n", encoding="utf-8")
    real = retention.trim_dated_log

    def broken(path, *a_, **k):
        if str(path).startswith(str(a)):
            raise OSError("kaputtes Konto")
        return real(path, *a_, **k)
    monkeypatch.setattr(retention, "trim_dated_log", broken)
    out = retention.purge_account_logs(datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc))
    assert out["lines"] == 1 and out["errors"] == 1
    assert (b / "sync.log").read_text(encoding="utf-8") == "" and (a / "sync.log").read_text(encoding="utf-8") == "2020-01-01 alt\n"
    shutil.rmtree(base, ignore_errors=True)


# ================================================================ PAKET 04 - app/retention.py (91-96)

def test_91_p4_05_sync_log_cutoff_is_utc_and_never_deletes_too_early(hosted, tmp_path, monkeypatch):
    """P4-05: der Stichtag kommt aus `run()` immer in UTC (naiv); sync_ops (UTC mit Z) wird exakt verglichen. sync_log
    traegt Ortszeit (db.now_iso): in Deutschland liegt sie 1-2 h VOR UTC im Text, also werden Zeilen hoechstens 2 h
    spaeter geloescht, nie frueher. Kein `Ortszeit als UTC`-Fehler: die Umwandlung geht in die sichere Richtung."""
    from app import retention
    seen = {}
    monkeypatch.setattr(retention, "_purge_sync_log", lambda db_file, cutoff_iso, dry_run: seen.setdefault("cut", cutoff_iso) and 0)
    monkeypatch.setattr(retention, "account_dirs", lambda: [tmp_path])
    (tmp_path / "lernapp.db").write_bytes(b"")
    retention.purge_account_logs(datetime(2026, 11, 8, 1, 30, tzinfo=timezone(timedelta(hours=2))), days=90)
    assert seen["cut"] == "2026-08-09T23:30:00", "Stichtag in UTC, nicht in der Zeitzone des Aufrufers"
    monkeypatch.undo()
    db_file = tmp_path / "lernapp.db"
    c = sqlite3.connect(db_file)
    c.executescript("""CREATE TABLE sync_log (id INTEGER PRIMARY KEY, started_at TEXT, finished_at TEXT);
                       CREATE TABLE sync_ops (op_id TEXT PRIMARY KEY, entity TEXT, result TEXT, device TEXT, created_at TEXT);""")
    c.executemany("INSERT INTO sync_log(started_at) VALUES (?)", [("2026-08-09T23:29:59",), ("2026-08-09T23:30:00",), ("2026-08-10T01:29:59",)])
    c.executemany("INSERT INTO sync_ops VALUES (?,?,?,?,?)", [("a", "x", "{}", None, "2026-08-09T23:29:59Z"), ("b", "x", "{}", None, "2026-08-09T23:30:00Z")])
    c.commit(); c.close()
    assert retention._purge_sync_log(db_file, "2026-08-09T23:30:00", dry_run=True) == 2
    assert retention._purge_sync_log(db_file, "2026-08-09T23:30:00", dry_run=False) == 2
    c = sqlite3.connect(db_file)
    assert [r[0] for r in c.execute("SELECT started_at FROM sync_log ORDER BY started_at")] == ["2026-08-09T23:30:00", "2026-08-10T01:29:59"]
    assert [r[0] for r in c.execute("SELECT op_id FROM sync_ops")] == ["b"]
    c.close()


def test_92_purge_account_db_dry_run_changes_no_rows(hosted):
    from app import accounts, retention
    accounts.register("dry@beispiel.de", "sehr-geheim-123", "luh")
    _, tok = accounts.login("dry@beispiel.de", "sehr-geheim-123")
    accounts.logout(tok)                                    # widerrufene Sitzung: faellig
    with accounts.cursor() as conn:
        before = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    out = retention.purge_account_db(datetime.now(timezone.utc), dry_run=True)
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == before == 1
    assert out["sessions"] == 1 and out["accounts_purged"] == 0
    assert retention.purge_account_db(datetime.now(timezone.utc))["sessions"] == 1
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0


def test_94_parse_time_edge_values():
    from app import retention
    assert retention._parse_time("07:05") == (7, 5) and retention._parse_time("23:59") == (23, 59)
    for bad in ("24:00", "4:60", "4:00:00", "ab:cd", "", "4", " 4: 0x"):
        assert retention._parse_time(bad) == (4, 0), bad


def test_95_p4_01_schedule_due_retries_after_a_failed_run(hosted, monkeypatch):
    """P4-01 (bestaetigt): die Tagesmarke stand VOR `run()` in schedule_marks; warf run() eine Ausnahme, galt der Tag
    als erledigt und die Fristen liefen erst am naechsten Tag. Jetzt: nach einem Fehler faellt die Marke, eine
    Fehlermarke pausiert RETRY_AFTER_MIN Minuten, danach laeuft der Tag erneut; nach Erfolg gilt die Marke."""
    from app import retention
    calls = []

    def run(*a, **k):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("Platte voll")
        return {"ok": True}
    monkeypatch.setattr(retention, "run", run)
    with pytest.raises(RuntimeError):
        retention.schedule_due(datetime(2026, 10, 26, 4, 0))
    assert retention.schedule_due(datetime(2026, 10, 26, 4, 30)) is None, "Pause nach dem Fehler, kein Dauerfeuer alle 30 s"
    assert retention.schedule_due(datetime(2026, 10, 26, 5, 1)) == {"ok": True}, "nach der Pause erneut am selben Tag"
    assert retention.schedule_due(datetime(2026, 10, 26, 23, 0)) is None and len(calls) == 2
    assert retention.schedule_due(datetime(2026, 10, 27, 4, 0)) == {"ok": True} and len(calls) == 3


def test_96_cli_exit_code_and_dry_run(hosted, capsys):
    from app import retention
    assert retention.main(["--dry-run"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["dry_run"] is True and out["account_logs"]["errors"] == 0
    assert retention.main([]) == 0 and json.loads(capsys.readouterr().out)["dry_run"] is False


# ================================================================ PAKET 04 - app/community.py (97-120)

def test_101_cursor_rolls_back_when_the_block_raises(hosted):
    from app import community
    with pytest.raises(RuntimeError):
        with community.cursor() as conn:
            conn.execute("INSERT INTO bans(author_id, created_at, reason) VALUES ('x', 'now', 'test')")
            raise RuntimeError("abbruch")
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM bans WHERE author_id='x'").fetchone()[0] == 0, "close ohne commit = Rollback"


def test_102_114_pseudonym_and_community_key_special_values(hosted):
    from app import community
    a, b = community.pseudonym("a" * 32), community.pseudonym("b" * 32)
    assert a.startswith("Studi-") and len(a) == 14 and a != b and a == community.pseudonym("a" * 32)
    assert community._community_key("A" * 64) == "a" * 64
    for bad in (None, "", "zz" * 32, "a" * 63, "a" * 65, 12345, "a" * 64 + "\n"):
        with pytest.raises(community.CommunityError) as x:
            community._community_key(bad)
        assert x.value.code == "community_invalid"


def test_105_106_115_p4_03_what_the_server_checks_for_course_claims(hosted):
    """P4-03 (Konzept): Kurs-Claims sind Angaben des Geraets. Der Dienst prueft: gueltiger HEX64-Schluessel, Hochschule
    des Kontos, kein Gruppenschluessel, bestaetigte E-Mail, Tagesgrenze fuer neue Schluessel; `owns_file` verlangt eine
    Datei mit Adresse aus dem eigenen Abgleich ODER einen Claim derselben Hochschule. Festgenagelt, kein Umbau
    (Bewertung in docs/audit/AUDIT-2026-11-08-PAKET-3-4.md)."""
    from app import community
    a, _ = _register(hosted, "a@beispiel.de", plus=True)
    b, _ = _register(hosted, "b@beispiel.de", plus=True)
    unbestaetigt, _ = _register(hosted, "c@beispiel.de", plus=True, verified=False)
    out = community.claim_files(a, "luh", [FP, "nicht-hex", FP.upper()], course_keys=[KURS, "kaputt"])
    assert (out["accepted"], out["ignored"], out["total"], out["courses"]) == (1, 2, 1, 1)
    assert community.join(a, "luh", KURS, "course") == {"joined": True, "community_key": KURS}
    for user, uni, key, code in ((b, "luh", KURS, "course_not_owned"), (a, "hildesheim", KURS, "course_not_owned"),
                                 (a, "luh", ANDERER_KURS, "course_not_owned"), (unbestaetigt, "luh", KURS, "email_unverified")):
        with pytest.raises(community.CommunityError) as x:
            community.join(user, uni, key, "course")
        assert (x.value.code, x.value.status) == (code, 403)
    with pytest.raises(community.CommunityError):
        community.join(a, "luh", KURS, "kurs")
    community.create_group(a, "luh", GRUPPE, "Lerngruppe")
    with pytest.raises(community.CommunityError) as x:
        community.join(b, "luh", GRUPPE, "course")
    assert x.value.code == "course_not_owned", "Gruppenschluessel ist nie ein Kurs"
    assert community.claim_files(b, "luh", [], course_keys=[GRUPPE])["courses"] == 0, "Gruppenschluessel als Kurs-Claim verworfen"
    assert community.owns_file(FP, a["id"]) is True, "Claim derselben Hochschule (Kontext ohne Sitzung = Standard luh) genuegt"
    assert community.owns_file(FP, b["id"]) is False and community.owns_file("c" * 64, a["id"]) is False
    community.claim_files(a, "hildesheim", ["c" * 64])
    assert community.owns_file("c" * 64, a["id"]) is False, "Claim einer anderen Hochschule zaehlt im luh-Kontext nicht"
    with pytest.raises(community.CommunityError) as x:
        community.claim_files(a, "luh", ["f" * 64] * (community.MAX_CLAIMS + 1))
    assert x.value.code == "claims_invalid"
    assert community.claim_files(a, "luh", ["b" * 64], replace=True)["total"] == 1, "replace ersetzt die Fingerabdruecke"
    with community.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM community_members WHERE user_id=?", (a["id"],)).fetchone()[0] == 2, "Mitgliedschaft bleibt"


def test_110_p4_02_invalid_base64_is_a_package_error(hosted):
    """P4-02 (widerlegt): `binascii.Error` ist eine Unterklasse von ValueError und wird von `except (ValueError, TypeError)`
    gefangen - jede kaputte Base64 ergibt CommunityError package_invalid, nie einen 500."""
    import binascii
    from app import community
    assert issubclass(binascii.Error, ValueError)
    for bad in ("!!!!", "abc", "YQ==x", "YQ", "QUJD\n", "ÄÖÜ"):
        with pytest.raises(community.CommunityError) as x:
            community._b64len(bad, "salt")
        assert x.value.code == "package_invalid", repr(bad)
    assert community._b64len("", "salt") == 0
    pkg = community.sample_package(FP)
    for field in ("salt", "nonce"):
        p = json.loads(json.dumps(pkg))
        p["header"]["encryption"][field] = "!!!!"
        with pytest.raises(community.CommunityError) as x:
            community.validate_package(p)
        assert x.value.code == "package_invalid"
    p = json.loads(json.dumps(pkg))
    p["ciphertext"] = "%%%%"
    with pytest.raises(community.CommunityError) as x:
        community.validate_package(p)
    assert x.value.code == "package_invalid"


def test_119_120_p4_04_communities_and_solution_lists_under_load(hosted):
    """P4-04 (Messung): 200 gemeldete Kurse mit Mitgliedschaft und 2.000 aktive Loesungen in einer Community mit
    Likes und Kommentaren. Die Zahl steht im Audit-Dokument; die Schranke hier ist bewusst weit (kein Flackern)."""
    from app import community
    me, _ = _register(hosted, "last@beispiel.de", plus=True)
    now = community._now()
    keys = [f"{i:064x}" for i in range(1, 201)]
    with community.cursor() as conn:
        conn.executemany("INSERT INTO course_claims(user_id, course_key, university, claimed_at) VALUES (?,?,?,?)",
                         [(me["id"], k, "luh", now) for k in keys])
        conn.executemany("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                         [(me["id"], k, "luh", "course", now) for k in keys])
        others = [f"{i:032x}" for i in range(1, 51)]
        conn.executemany("INSERT INTO community_members(user_id, community_key, university, kind, joined_at) VALUES (?,?,?,?,?)",
                         [(o, keys[0], "luh", "course", now) for o in others])
        sols = [(f"{i:08x}-0000-4000-8000-000000000000", f"{i:064x}", "luh", others[i % 50], f"Studi-{i % 50:08x}", "Name", f"Blatt {i}",
                 now, f"2026-10-{1 + i % 28:02d}T10:00:00Z", 10, 2, 100, "active", keys[0]) for i in range(2000)]
        conn.executemany("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, title, created_at,
                            published_at, page_count, pages, size, status, community_key) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", sols)
        conn.executemany("INSERT INTO likes(solution_id, user_id, created_at) VALUES (?,?,?)",
                         [(s[0], others[j], now) for s in sols[:1000] for j in range(3)])
        conn.executemany("INSERT INTO comments(id, solution_id, author_id, pseudonym, text, created_at) VALUES (?,?,?,?,?,?)",
                         [(f"c-{s[0]}", s[0], others[0], "Studi-x", "Danke", now) for s in sols[:1000]])
    t0 = time.perf_counter()
    rows = community.communities(me, "luh")
    t_comm = time.perf_counter() - t0
    assert len(rows) == 200 and rows[0]["solutions"] == 2000 and rows[0]["members"] == 51
    t0 = time.perf_counter()
    sols_out = community.community_solutions(me, keys[0])
    t_sol = time.perf_counter() - t0
    assert len(sols_out) == 2000 and sols_out[0]["likes"] == 3
    print(f"\n[P4-04] communities(200): {t_comm * 1000:.0f} ms, community_solutions(2000): {t_sol * 1000:.0f} ms")
    assert t_comm < 2.0 and t_sol < 2.0, (t_comm, t_sol)

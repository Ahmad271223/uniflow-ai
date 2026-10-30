"""Vertrag G2: Geraete-Synchronisierung (app/sync.py) – Trigger, Abruf mit Cursor, Push mit ID-Zuordnung, Konflikte,
Loeschen/Wiederherstellen, Notizen mit base_version, Einstellungen; Endpunkte; je Konto getrennt im Dienst."""
import importlib.util
import json
import sqlite3
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
PAST, FUTURE = "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z"


@pytest.fixture
def conn(tmp_path):
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


def test_triggers_version_timestamp_and_tombstones(conn):
    from app import db, sync
    conn.execute("INSERT INTO modules(name, created_at) VALUES ('M', '2026-10-26')")
    r = db.row(conn, "SELECT * FROM modules")
    assert r["sync_version"] == 1 and sync.TS_RE.match(r["sync_updated_at"])
    conn.execute("UPDATE modules SET name='M2' WHERE id=?", (r["id"],))            # normaler Schreibpfad der App
    r2 = db.row(conn, "SELECT * FROM modules")
    assert r2["sync_version"] == 2 and r2["sync_updated_at"] >= r["sync_updated_at"] and r2["sync_device"] is None
    conn.execute("UPDATE modules SET name='M3', sync_version=7, sync_updated_at='2099-01-01T00:00:00.000Z', sync_device='ipad' WHERE id=?", (r["id"],))
    r3 = db.row(conn, "SELECT * FROM modules")
    assert (r3["sync_version"], r3["sync_device"]) == (7, "ipad"), "explizite Version wird nicht noch einmal erhoeht"
    conn.execute("DELETE FROM modules WHERE id=?", (r["id"],))
    t = db.row(conn, "SELECT * FROM sync_tombstones")
    assert (t["entity"], t["entity_id"]) == ("modules", str(r["id"])) and sync.TS_RE.match(t["deleted_at"])
    # Kaskade: Ausnahme einer geloeschten Serie bekommt ihren eigenen Tombstone
    conn.execute("INSERT INTO course_events(title, weekday, start_time, end_time, created_at) VALUES ('V', 0, '08:00', '10:00', '2026-10-26')")
    eid = db.row(conn, "SELECT id FROM course_events")["id"]
    conn.execute("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?, '2026-11-02', 'skip', '2026-10-26')", (eid,))
    conn.execute("DELETE FROM course_events WHERE id=?", (eid,))
    assert {t["entity"] for t in db.rows(conn, "SELECT entity FROM sync_tombstones")} == {"modules", "course_events", "event_exceptions"}


def test_push_creates_with_mapping_and_pull_with_cursor(conn):
    from app import sync
    out = sync.push(conn, "ipad-1", [
        {"entity": "modules", "local_id": -1, "data": {"name": "Mathe"}},
        {"entity": "study_packages", "local_id": -2, "data": {"date": "2026-11-02", "module_id": -1, "subject": "Mathe", "title": "W3"}},
        {"entity": "study_tasks", "local_id": -3, "data": {"package_id": -2, "type": "uebung", "title": "Blatt"}},
        {"entity": "study_tasks", "local_id": -4, "data": {"package_id": -77, "type": "uebung", "title": "kaputt"}},
        {"entity": "unbekannt", "local_id": -5, "data": {}},
    ])
    st = [r["status"] for r in out["results"]]
    assert st == ["unknown_entity", "created", "created", "created", "error"] or sorted(st) == sorted(["created"] * 3 + ["error", "unknown_entity"])
    m = {(x["entity"], x["local_id"]): x["id"] for x in out["mapping"]}
    assert set(m) == {("modules", -1), ("study_packages", -2), ("study_tasks", -3)}
    pkg = sync.changes(conn, None)["changes"]["study_packages"][0]
    assert pkg["module_id"] == m[("modules", -1)] and pkg["sync_device"] == "ipad-1"
    task = sync.changes(conn, None)["changes"]["study_tasks"][0]
    assert task["package_id"] == m[("study_packages", -2)]
    first = sync.changes(conn, None)
    assert sync.changes(conn, first["cursor"]) == {"cursor": first["cursor"], "changes": {}, "tombstones": [], "has_more": False}
    conn.execute("UPDATE modules SET name='Mathe I'")
    again = sync.changes(conn, first["cursor"])
    assert list(again["changes"]) == ["modules"] and again["changes"]["modules"][0]["sync_version"] == 2


def test_pull_cursor_never_in_current_millisecond(conn):
    """Befund 30.10.2026: eine Aenderung in derselben Millisekunde wie der Cursor bekam denselben Zeitstempel und fiel
    beim naechsten Abruf (`sync_updated_at > cursor`) durch. Der Abruf wartet, bis die Uhr ueber den Cursor hinaus ist.
    Hier liegt die Push-Zeit absichtlich 20 ms in der Zukunft, damit das Fenster sicher getroffen wird."""
    from datetime import datetime, timedelta, timezone
    from app import sync
    t = datetime.now(timezone.utc) + timedelta(milliseconds=20)
    ahead = t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"
    sync.push(conn, "ipad-1", [{"entity": "modules", "local_id": -1, "data": {"name": "Mathe"}}], now=ahead)
    first = sync.changes(conn, None)
    assert first["cursor"] == ahead and sync.now_utc() > first["cursor"], "nach dem Abruf ist die Uhr ueber dem Cursor"
    conn.execute("UPDATE modules SET name='Mathe I'")                                   # Trigger: strftime('now')
    sync.push(conn, "mac-1", [{"entity": "flashcards", "local_id": -2, "data": {"question": "Q", "answer": "A"}}])  # now_utc()
    again = sync.changes(conn, first["cursor"])
    assert sorted(again["changes"]) == ["flashcards", "modules"] and again["changes"]["modules"][0]["sync_version"] == 2
    assert again["cursor"] > first["cursor"]
    far = "2099-01-01T00:00:00.000Z"                                                   # weit voraus: kein Warten
    conn.execute("UPDATE modules SET name='Mathe II', sync_version=9, sync_updated_at=?", (far,))
    import time
    t0 = time.monotonic()
    assert sync.changes(conn, None)["cursor"] == far and time.monotonic() - t0 < 1.0


def test_update_rules_applied_conflict_and_last_writer_per_field(conn):
    from app import db, sync
    sync.push(conn, "ipad-1", [{"entity": "modules", "local_id": -1, "data": {"name": "Physik", "color": "#111111", "priority": 2}}])
    r = sync.push(conn, "mac-1", [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": FUTURE, "data": {"name": "Physik I"}}])
    assert r["results"][0]["status"] == "applied" and r["results"][0]["version"] == 2 and r["conflicts"] == []
    r = sync.push(conn, "ipad-1", [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": FUTURE, "data": {"name": "Physik 1", "priority": 3}}])
    res = r["results"][0]
    assert res["status"] == "conflict" and sorted(res["client_won"]) == ["name", "priority"] and res["version"] == 3
    assert r["conflicts"][0]["server"]["name"] == "Physik I"
    row = db.row(conn, "SELECT name, priority, color, sync_version, sync_device FROM modules WHERE id=1")
    assert (row["name"], row["priority"], row["color"], row["sync_version"], row["sync_device"]) == ("Physik 1", 3, "#111111", 3, "ipad-1")
    r = sync.push(conn, "ipad-1", [{"entity": "modules", "id": 1, "base_version": 1, "updated_at": PAST, "data": {"name": "uralt"}}])
    assert r["results"][0] == {"entity": "modules", "id": 1, "status": "conflict", "version": 3, "client_won": []}
    assert db.row(conn, "SELECT name FROM modules WHERE id=1")["name"] == "Physik 1"


def test_delete_rules_and_resurrect(conn):
    from app import db, sync
    sync.push(conn, "ipad-1", [{"entity": "flashcards", "local_id": -1, "data": {"question": "Q", "answer": "A"}},
                               {"entity": "flashcards", "local_id": -2, "data": {"question": "Q2", "answer": "A2"}}])
    r = sync.push(conn, "mac-1", [], [{"entity": "flashcards", "id": 1, "deleted_at": FUTURE}, {"entity": "flashcards", "id": 2, "deleted_at": PAST}])
    assert [x["status"] for x in r["results"]] == ["deleted", "edit_wins"]
    assert db.row(conn, "SELECT COUNT(*) n FROM flashcards")["n"] == 1
    t = db.row(conn, "SELECT * FROM sync_tombstones WHERE entity='flashcards'")
    assert t["entity_id"] == "1" and t["device"] == "mac-1"
    r = sync.push(conn, "ipad-1", [{"entity": "flashcards", "id": 1, "base_version": 1, "updated_at": PAST, "data": {"box": 2}}])
    assert r["results"][0]["status"] == "deleted"
    r = sync.push(conn, "ipad-1", [{"entity": "flashcards", "id": 1, "base_version": 1, "updated_at": "2099-06-01T00:00:00.000Z",
                                    "data": {"question": "Q", "answer": "A", "box": 2}}])
    assert r["results"][0]["status"] == "resurrected"
    assert db.row(conn, "SELECT box FROM flashcards WHERE id=1")["box"] == 2 and not db.rows(conn, "SELECT 1 FROM sync_tombstones WHERE entity='flashcards'")
    pulled = sync.changes(conn, None)
    assert {c["id"] for c in pulled["changes"]["flashcards"]} == {1, 2}


def test_annotations_follow_base_version_rule(conn):
    from app import sync
    r = sync.push(conn, "ipad-1", [{"entity": "annotations", "id": "f1", "data": {"pages": {"1": {"objects": [{"id": "s1"}]}}}}])
    assert r["results"][0] == {"entity": "annotations", "id": "f1", "status": "applied", "version": 1}
    r = sync.push(conn, "mac-1", [{"entity": "annotations", "id": "f1", "base_version": 1, "data": {"pages": {"1": {"objects": [{"id": "s1"}, {"id": "s2"}]}}}}])
    assert r["results"][0]["version"] == 2
    r = sync.push(conn, "ipad-1", [{"entity": "annotations", "id": "f1", "base_version": 1, "data": {"pages": {}}}])
    res = r["results"][0]
    assert res["status"] == "conflict" and res["version"] == 2 and res["data"]["pages"]["1"]["objects"][1]["id"] == "s2"
    r = sync.push(conn, "ipad-1", [{"entity": "annotations", "id": "nix", "base_version": 0, "data": {}}])
    assert r["results"][0]["status"] == "unknown_file"
    a = sync.changes(conn, None)["changes"]["annotations"][0]
    assert a["version"] == 2 and a["data"]["pages"]["1"]["objects"][1]["id"] == "s2" and a["sync_device"] == "mac-1"


def test_settings_sync_skips_private_keys(conn):
    from app import db, sync
    r = sync.push(conn, "ipad-1", [{"entity": "settings", "local_id": "hours_per_day", "data": {"value": "6"}},
                                   {"entity": "settings", "local_id": "lan_pin", "data": {"value": "123456"}}])
    assert [x["status"] for x in r["results"]] == ["applied", "ignored"]
    assert db.row(conn, "SELECT value FROM settings WHERE key='hours_per_day'")["value"] == "6"
    keys = {s["key"] for s in sync.changes(conn, None)["changes"]["settings"]}
    assert "hours_per_day" in keys and not ({"lan_pin", "university"} & keys)


def _pull_all(conn, since=None, limit=3):
    """Wie ein Client: weiter abrufen, solange has_more; liefert alle Zeilen je Tabelle, Tombstones und Seitenzahl."""
    from app import sync
    seen: dict[str, list] = {}
    tombs, pages = [], 0
    while True:
        r = sync.changes(conn, since, limit)
        pages += 1
        for t, rows in r["changes"].items():
            seen.setdefault(t, []).extend(rows)
        tombs += r["tombstones"]
        assert r["cursor"] is None or not since or r["cursor"] >= since
        since = r["cursor"]
        if not r["has_more"]:
            return seen, tombs, pages, since
        assert pages < 100


def test_paged_pull_never_skips_rows(conn):
    """Vorher (bis 28.10.2026): LIMIT je Tabelle und Cursor = Maximum ueber alle Tabellen. Mehr als LIMIT Aenderungen in
    einer Tabelle plus eine spaetere Aenderung in einer anderen -> der Rest der ersten Tabelle war verloren."""
    from app import sync
    for i in range(7):
        conn.execute("INSERT INTO flashcards(question, answer, box) VALUES (?, 'A', 1)", (f"Q{i}",))
    # viele Zeilen mit GLEICHEM Zeitstempel (eine Anweisung): passen nicht in eine Seite, werden trotzdem vollstaendig geliefert
    conn.execute("UPDATE flashcards SET box=2")
    conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Spaeter', '#111111', 0, '2026-10-28')")
    conn.execute("INSERT INTO flashcards(question, answer, box) VALUES ('weg', 'A', 1)")
    gone = conn.execute("SELECT id FROM flashcards WHERE question='weg'").fetchone()[0]
    conn.execute("DELETE FROM flashcards WHERE id=?", (gone,))
    full = sync.changes(conn, None)
    assert full["has_more"] is False
    rows, tombs, pages, cursor = _pull_all(conn, None, limit=3)
    assert pages >= 1
    want = {t: sorted(r["id"] if "id" in r else r["key"] for r in v) for t, v in full["changes"].items()}
    got = {t: sorted(set(r["id"] if "id" in r else r["key"] for r in v)) for t, v in rows.items()}
    assert got == want, "keine Zeile uebersprungen"
    assert {(t["entity"], t["entity_id"]) for t in tombs} == {(t["entity"], t["entity_id"]) for t in full["tombstones"]}
    assert cursor == full["cursor"]
    assert sync.changes(conn, cursor, 3) == {"cursor": cursor, "changes": {}, "tombstones": [], "has_more": False}


def test_paged_pull_with_more_rows_than_limit_in_one_table(conn):
    from app import sync
    import time
    _, _, _, c0 = _pull_all(conn, None, limit=4)                # Startzustand (Einstellungen usw.) schon abgeholt
    time.sleep(0.003)
    for i in range(9):
        conn.execute("INSERT INTO flashcards(question, answer, box) VALUES (?, 'A', 1)", (f"P{i}",))
        time.sleep(0.003)                                       # verschiedene Zeitstempel
    conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Danach', '#111111', 0, '2026-10-28')")
    first = sync.changes(conn, c0, 4)
    assert first["has_more"] is True and len(first["changes"]["flashcards"]) == 4
    assert "modules" not in first["changes"], "die spaetere Aenderung kommt erst nach den uebrigen Karten"
    rows, _, pages, _ = _pull_all(conn, c0, limit=4)
    assert pages >= 3
    assert {r["question"] for r in rows["flashcards"]} >= {f"P{i}" for i in range(9)}
    assert any(m["name"] == "Danach" for m in rows["modules"])


def test_repeated_push_with_op_id_creates_once(conn):
    """Verlorene Antwort, das Geraet sendet denselben Push noch einmal: mit op_id entsteht nichts doppelt, die
    Zuordnung kommt wieder, auch fuer Kinder im selben Push. Ohne op_id wie bisher (zweite Zeile)."""
    from app import sync
    items = [
        {"entity": "modules", "local_id": -1, "op_id": "op-ipad-0001", "data": {"name": "Wdh-Modul"}},
        {"entity": "study_packages", "local_id": -2, "op_id": "op-ipad-0002", "data": {"date": "2026-11-02", "module_id": -1, "subject": "Wdh", "title": "W1"}},
        {"entity": "flashcards", "local_id": -3, "op_id": "op-ipad-0003", "data": {"question": "Wdh?", "answer": "A", "box": 1}},
    ]
    a = sync.push(conn, "ipad-1", items)
    b = sync.push(conn, "ipad-1", items)
    assert [r["status"] for r in a["results"]] == ["created"] * 3 and not any(r.get("repeated") for r in a["results"])
    assert [r["status"] for r in b["results"]] == ["created"] * 3 and all(r.get("repeated") for r in b["results"])
    assert [r["id"] for r in a["results"]] == [r["id"] for r in b["results"]]
    assert sorted((m["entity"], m["local_id"], m["id"]) for m in a["mapping"]) == sorted((m["entity"], m["local_id"], m["id"]) for m in b["mapping"])
    assert conn.execute("SELECT COUNT(*) FROM modules WHERE name='Wdh-Modul'").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM study_packages WHERE title='W1'").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM flashcards WHERE question='Wdh?'").fetchone()[0] == 1
    # ein neuer Eintrag im Wiederholungs-Push, der auf das wiederholte Modul zeigt, bekommt die richtige ID
    c = sync.push(conn, "ipad-1", [items[0], {"entity": "study_packages", "local_id": -5, "op_id": "op-ipad-0005",
                                              "data": {"date": "2026-11-09", "module_id": -1, "subject": "Wdh", "title": "W2"}}])
    mod = a["results"][0]["id"]
    assert conn.execute("SELECT module_id FROM study_packages WHERE title='W2'").fetchone()[0] == mod and c["results"][1]["status"] == "created"
    # Aenderung mit op_id: Wiederholung meldet dasselbe Ergebnis, kein Konflikt aus der eigenen ersten Fassung
    upd = [{"entity": "modules", "id": mod, "base_version": 1, "op_id": "op-ipad-0006", "data": {"name": "Wdh-Modul 2"}}]
    u1, u2 = sync.push(conn, "ipad-1", upd), sync.push(conn, "ipad-1", upd)
    assert u1["results"][0]["status"] == "applied" and u2["results"][0] == u1["results"][0] | {"repeated": True}
    # Fehler werden nicht gemerkt: ein spaeterer Versuch darf gelingen
    bad = [{"entity": "study_tasks", "local_id": -9, "op_id": "op-ipad-0009", "data": {"package_id": -77, "type": "uebung", "title": "x"}}]
    assert sync.push(conn, "ipad-1", bad)["results"][0]["status"] == "error"
    assert sync.push(conn, "ipad-1", bad)["results"][0].get("repeated") is None
    # ohne op_id wie bisher
    sync.push(conn, "ipad-1", [{"entity": "flashcards", "local_id": -1, "data": {"question": "ohne", "answer": "A", "box": 1}}])
    sync.push(conn, "ipad-1", [{"entity": "flashcards", "local_id": -1, "data": {"question": "ohne", "answer": "A", "box": 1}}])
    assert conn.execute("SELECT COUNT(*) FROM flashcards WHERE question='ohne'").fetchone()[0] == 2


def test_sync_changes_endpoint_takes_a_limit(app):
    from conftest import asgi_call
    import json as _json
    st, _, b = asgi_call(app, "GET", "/api/sync/changes?limit=1")
    assert st == 200 and "has_more" in _json.loads(b)
    assert asgi_call(app, "GET", "/api/sync/changes?limit=0")[0] == 422


def test_sync_endpoints_local_mode(app):
    from app import db
    with db.cursor() as c:
        c.execute("DELETE FROM modules WHERE name='API-Sync'")
    st, _, b = asgi_call(app, "POST", "/api/sync/push", body=json.dumps({"device_id": "ipad-9", "items": [{"entity": "modules", "local_id": -1, "data": {"name": "API-Sync"}}]}))
    out = json.loads(b)
    assert st == 200 and out["results"][0]["status"] == "created" and out["mapping"][0]["local_id"] == -1
    st, _, b = asgi_call(app, "GET", "/api/sync/changes")
    assert st == 200 and any(m["name"] == "API-Sync" for m in json.loads(b)["changes"]["modules"])
    st, _, _ = asgi_call(app, "POST", "/api/sync/push", body=json.dumps({"items": "nein"}))
    assert st == 400
    with db.cursor() as c:
        c.execute("DELETE FROM modules WHERE name='API-Sync'")


def test_sync_is_per_account_in_hosted_mode(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    try:
        toks = []
        for mail in ("s1@beispiel.de", "s2@beispiel.de"):
            st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": mail, "password": "sehr-geheim-123", "university": "luh"}))
            toks.append(json.loads(b)["token"])
        h = lambda t: {"Authorization": f"Bearer {t}"}
        st, _, b = asgi_call(app, "POST", "/api/sync/push", headers=h(toks[0]),
                             body=json.dumps({"device_id": "ipad-a", "items": [{"entity": "modules", "local_id": -1, "data": {"name": "Nur-A"}}]}))
        assert st == 200 and json.loads(b)["results"][0]["status"] == "created"
        st, _, b = asgi_call(app, "GET", "/api/sync/changes", headers=h(toks[1]))
        assert st == 200 and "Nur-A" not in b.decode()
        st, _, b = asgi_call(app, "GET", "/api/sync/changes", headers=h(toks[0]))
        assert "Nur-A" in b.decode()
        assert asgi_call(app, "GET", "/api/sync/changes")[0] == 401
    finally:
        accounts.db_path().unlink(missing_ok=True)


def test_sync_fixture_matches_python():
    spec = importlib.util.spec_from_file_location("gen_sync_fixture", ROOT / "tools" / "gen-sync-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    built = mod.build()
    stored = json.loads((ROOT / "packages" / "shared-contracts" / "fixtures" / "sync" / "cases.json").read_text(encoding="utf-8"))
    assert built["rules"] == stored["rules"]
    assert [c["name"] for c in built["cases"]] == [c["name"] for c in stored["cases"]]
    for b, s in zip(built["cases"], stored["cases"]):
        assert b == s, f"python tools/gen-sync-fixture.py neu ausfuehren ({b['name']})"

"""Geraete-Abgleich der Windows-App mit dem Konto (app/sync_client.py, Vertrag G2, 28.10.2026). Zwei Geraete eines
Kontos: die Windows-App (eigene Datenbank, Einzelplatz) und ein "iPad", das den Dienst direkt per G2 anspricht. Der
Dienst ist dieselbe App im gehosteten Modus, per ASGI aufgerufen."""
import json

import pytest
from conftest import asgi_call

SERVICE = "http://127.0.0.1:9"
FILE = "studip-datei-0001"


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def _hosted(app, method, path, body=None, headers=None):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        return _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers))
    finally:
        config.MODE = old


@pytest.fixture
def two_devices(app, monkeypatch, tmp_path):
    from app import accounts, community, config, db, service_link, sync_client
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)
    service_link.state_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS))
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "windows.db")      # eigene Datenbank der Windows-App
    db.init_db()

    def transport(method, url, headers, body, timeout):
        old = config.MODE
        config.MODE = "hosted"
        try:
            st, h, b = asgi_call(app, method, url[len(SERVICE):], body=body or b"",
                                 headers={k: v for k, v in headers.items() if k == "Authorization"},
                                 content_type=headers.get("Content-Type", "application/json"))
        finally:
            config.MODE = old
        return st, {k.decode(): v.decode() for k, v in h}, b
    monkeypatch.setattr(service_link, "transport", transport)

    st, d = _hosted(app, "POST", "/api/account/register", {"email": "studi@example.org", "password": "sehr-geheim-123", "university": "luh"})
    assert st == 201
    accounts.mark_email_verified(d["user"]["id"])
    accounts.end_trial(d["user"]["id"])             # Tarif-Tests meinen den Stand nach der 7-Tage-Probe
    accounts.set_plan(d["user"]["id"], "plus")
    ipad = {"Authorization": f"Bearer {d['token']}"}
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, semester) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27')")
        conn.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES (?, 'kurs-1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://studip.example/f')", (FILE,))
    st, _ = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "studi@example.org", "password": "sehr-geheim-123"})))
    assert st == 200
    yield app, ipad
    service_link.state_path().unlink(missing_ok=True)
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


def ipad_push(app, ipad, items, deletes=None):
    st, d = _hosted(app, "POST", "/api/sync/push", {"device_id": "ipad-1", "items": items, "deletes": deletes or []}, ipad)
    assert st == 200, d
    return d


def ipad_pull(app, ipad):
    st, d = _hosted(app, "GET", "/api/sync/changes?limit=2000", headers=ipad)
    assert st == 200
    return d["changes"], d["tombstones"]


def page(*ids):
    return {"version": 2, "pages": {"p1": {"objects": [{"id": i, "type": "stroke", "points": [1, 2, 3, 4]} for i in ids]}},
            "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}], "deletedPages": [], "note": "", "bookmarks": [], "outline": []}


def test_first_link_without_duplicates_notes_from_both_devices_stay(two_devices):
    app, ipad = two_devices
    from app import db, sync_client
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, semester) VALUES ('Mathe I', 'WiSe 26/27')").lastrowid
        pid = conn.execute("INSERT INTO study_packages(date, module_id, title, planned_minutes) VALUES ('2026-11-02', ?, 'Blatt 1', 90)", (mid,)).lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title) VALUES (?, 'uebung', 'Aufgabe 1')", (pid,))
        conn.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", (FILE, json.dumps(page("win-a"))))
        db.set_setting(conn, "hours_per_day", "5")
        db.set_setting(conn, "lan_pin", "4711")
    # das iPad war schneller: dieselbe Vorlesung aus Stud.IP, ein eigenes Modul, eigene Striche auf derselben PDF
    r = ipad_push(app, ipad, [
        {"entity": "modules", "local_id": -1, "updated_at": "2026-10-28T08:00:00.000Z", "data": {"name": "Mathe I", "semester": "WiSe 26/27"}},
        {"entity": "modules", "local_id": -2, "updated_at": "2026-10-28T08:00:00.000Z", "data": {"name": "Physik", "semester": "WiSe 26/27"}},
        {"entity": "annotations", "id": FILE, "data": page("ipad-b"),
         "file": {"name": "Blatt1.pdf", "course_id": "kurs-1", "course_title": "Mathematik I"}}])
    assert [x["status"] for x in r["results"]] == ["created", "created", "applied"]

    out = sync_client.run()
    assert out["ok"], out
    with db.cursor() as conn:
        assert sorted(r["name"] for r in db.rows(conn, "SELECT name FROM modules")) == ["Mathe I", "Physik"], "keine Doppelten"
        ids = [o["id"] for o in json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (FILE,))["data"])["pages"]["p1"]["objects"]]
        assert sorted(ids) == ["ipad-b", "win-a"], "Striche beider Geraete bleiben"
    changes, _ = ipad_pull(app, ipad)
    assert sorted(m["name"] for m in changes["modules"]) == ["Mathe I", "Physik"]
    mathe = next(m["id"] for m in changes["modules"] if m["name"] == "Mathe I")
    pkg = changes["study_packages"][0]
    assert (pkg["title"], pkg["module_id"]) == ("Blatt 1", mathe), "Fremdschluessel auf die ID im Dienst umgesetzt"
    assert changes["study_tasks"][0]["package_id"] == pkg["id"]
    note = changes["annotations"][0]
    assert sorted(o["id"] for o in note["data"]["pages"]["p1"]["objects"]) == ["ipad-b", "win-a"]
    keys = {s["key"]: s["value"] for s in changes["settings"]}
    assert keys.get("hours_per_day") == "5" and "lan_pin" not in keys

    again = sync_client.run()
    assert again["ok"] and again["pushed"] == 0 and again["applied"] == 0, again


def test_edits_deletes_and_concurrent_notes(two_devices):
    app, ipad = two_devices
    from app import db, sync_client
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(name, semester) VALUES ('Physik', 'WiSe 26/27')")
        conn.execute("INSERT INTO modules(name, semester) VALUES ('Chemie', 'WiSe 26/27')")
        conn.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", (FILE, json.dumps(page("a"))))
    assert sync_client.run()["ok"]
    changes, _ = ipad_pull(app, ipad)
    physik = next(m for m in changes["modules"] if m["name"] == "Physik")
    note = changes["annotations"][0]
    # iPad: Physik umbenennen, einen Strich ergaenzen; Windows: Chemie loeschen, eigenen Strich ergaenzen
    ipad_push(app, ipad, [{"entity": "modules", "id": physik["id"], "base_version": physik["sync_version"],
                           "updated_at": "2030-01-01T00:00:00.000Z", "data": {"name": "Physik II"}},
                          {"entity": "annotations", "id": FILE, "base_version": note["version"], "data": page("a", "ipad")}])
    with db.cursor() as conn:
        conn.execute("DELETE FROM modules WHERE name='Chemie'")
        d = json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (FILE,))["data"])
        d["pages"]["p1"]["objects"].append({"id": "win", "type": "stroke", "points": [5, 6, 7, 8]})
        conn.execute("UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", (json.dumps(d), FILE))
    out = sync_client.run()
    assert out["ok"], out
    with db.cursor() as conn:
        assert sorted(r["name"] for r in db.rows(conn, "SELECT name FROM modules")) == ["Physik II"]
        ids = [o["id"] for o in json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (FILE,))["data"])["pages"]["p1"]["objects"]]
        assert sorted(ids) == ["a", "ipad", "win"]
    changes, tomb = ipad_pull(app, ipad)
    assert [m["name"] for m in changes["modules"]] == ["Physik II"]
    assert any(t["entity"] == "modules" for t in tomb), "Loeschen kommt beim iPad an"
    assert sorted(o["id"] for o in changes["annotations"][0]["data"]["pages"]["p1"]["objects"]) == ["a", "ipad", "win"]


def test_notes_for_a_file_not_yet_on_this_pc_wait(two_devices):
    app, ipad = two_devices
    from app import db, sync_client
    ipad_push(app, ipad, [{"entity": "annotations", "id": "studip-neu-9", "data": page("x"),
                           "file": {"name": "Neu.pdf", "course_id": "kurs-1", "course_title": "Mathematik I"}}])
    out = sync_client.run()
    assert out["ok"] and out["pending"] == 1, out
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES ('studip-neu-9', 'kurs-1', 'Neu.pdf', 'application/pdf', 'neu', 'https://studip.example/n')")
    out = sync_client.run()
    assert out["ok"] and out["pending"] == 0
    with db.cursor() as conn:
        assert json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id='studip-neu-9'")["data"])["pages"]["p1"]["objects"][0]["id"] == "x"


def test_free_plan_keeps_notes_local_but_syncs_plans(two_devices):
    app, ipad = two_devices
    from app import accounts, db, sync_client
    u = accounts.authenticate(ipad["Authorization"][7:])
    accounts.set_plan(u["id"], "free")
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(name) VALUES ('Nur Plan')")
        conn.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", (FILE, json.dumps(page("lokal"))))
    out = sync_client.run()
    assert out["ok"] and out["plan_required"], out
    changes, _ = ipad_pull(app, ipad)
    assert [m["name"] for m in changes["modules"]] == ["Nur Plan"] and "annotations" not in changes


def test_first_link_keeps_changed_settings_against_fresh_defaults(two_devices):
    """Ein neues Konto im Dienst hat frische Standardwerte; die eigenen Einstellungen des PCs duerfen sie nicht
    ueberschreiben, auch wenn sie aelter sind."""
    app, ipad = two_devices
    from app import db, sync_client
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value='6', sync_updated_at='2020-01-01T00:00:00.000Z' WHERE key='hours_per_day'")
    _hosted(app, "GET", "/api/sync/changes?limit=1", headers=ipad)             # Dienst-Datenbank mit Standardwerten anlegen
    assert sync_client.run()["ok"]
    with db.cursor() as conn:
        assert db.row(conn, "SELECT value FROM settings WHERE key='hours_per_day'")["value"] == "6"
    changes, _ = ipad_pull(app, ipad)
    assert {s["key"]: s["value"] for s in changes["settings"]}["hours_per_day"] == "6"

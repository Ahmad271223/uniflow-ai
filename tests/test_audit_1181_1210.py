"""Audit 1181–1210 (28.10.2026): verteilte Fehler im Geraete-Abgleich, Grenzen, Sicherheitsgrenzen, Migrationen.
Reproduzierbar (feste Saat), nur Temp-Datenordner. Zu jedem Punkt die Nummer im Testnamen."""
import json
import random

import pytest
from conftest import asgi_call

from test_sync_client import SERVICE, FILE, _hosted, _j, ipad_pull, ipad_push, page, two_devices  # noqa: F401


# ---------------------------------------------------------------- 137. verteilte Transaktionen

def test_1181_partially_confirmed_batch_is_resent_exactly(two_devices, monkeypatch):
    """Der Dienst bestaetigt nur einen Teil (Antwort fuer die anderen fehlt): die fehlenden gehen beim naechsten Lauf
    erneut, die bestaetigten nicht doppelt (op_id)."""
    app, ipad = two_devices
    from app import db, service_link, sync_client
    with db.cursor() as conn:
        for n in ("A", "B", "C", "D"):
            conn.execute("INSERT INTO modules(name, semester) VALUES (?, 'WiSe 26/27')", (n,))
    real = service_link.transport

    def drop_half(method, url, headers, body, timeout):
        st, h, b = real(method, url, headers, body, timeout)
        if url.endswith("/api/sync/push"):
            d = json.loads(b)
            d["results"] = d["results"][:2]                    # Antwort nennt nur die ersten zwei
            d["mapping"] = d["mapping"][:2]
            b = json.dumps(d).encode()
        return st, h, b
    monkeypatch.setattr(service_link, "transport", drop_half)
    sync_client.run()
    monkeypatch.setattr(service_link, "transport", real)
    out = sync_client.run()
    assert out["ok"], out
    names = sorted(m["name"] for m in ipad_pull(app, ipad)[0]["modules"])
    assert names == ["A", "B", "C", "D"], "keine Doppelten, nichts verloren"
    assert sync_client.run()["pushed"] == 0


def test_1182_two_devices_same_pdf_different_revisions(two_devices):
    """Beide aendern dieselbe Notiz auf verschiedenen Staenden: kein Ueberschreiben, Striche beider bleiben."""
    app, ipad = two_devices
    from app import db, sync_client
    with db.cursor() as conn:
        conn.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", (FILE, json.dumps(page("basis"))))
    sync_client.run()
    note = ipad_pull(app, ipad)[0]["annotations"][0]
    ipad_push(app, ipad, [{"entity": "annotations", "id": FILE, "base_version": note["version"], "data": page("basis", "ipad")}])
    # das iPad sendet noch einmal mit veraltetem Stand: der Dienst lehnt ab statt zu ueberschreiben
    r = ipad_push(app, ipad, [{"entity": "annotations", "id": FILE, "base_version": note["version"], "data": page("basis", "alt")}])
    assert r["results"][0]["status"] == "conflict"
    with db.cursor() as conn:
        d = json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (FILE,))["data"])
        d["pages"]["p1"]["objects"].append({"id": "win", "type": "stroke", "points": [9, 9, 8, 8]})
        conn.execute("UPDATE annotations SET data=? WHERE file_id=?", (json.dumps(d), FILE))
    assert sync_client.run()["ok"]
    ids = sorted(o["id"] for o in ipad_pull(app, ipad)[0]["annotations"][0]["data"]["pages"]["p1"]["objects"])
    assert ids == ["basis", "ipad", "win"]


def test_1183_delete_arrives_before_create(two_devices):
    """Ein Loeschen fuer eine Zeile, die es (noch) nicht gibt, schadet nicht; danach angelegt bleibt sie."""
    app, ipad = two_devices
    from app import db, sync_client
    r = ipad_push(app, ipad, [], deletes=[{"entity": "modules", "id": 999, "deleted_at": "2026-10-28T10:00:00.000Z"}])
    assert r["results"][0]["status"] == "deleted"
    ipad_push(app, ipad, [{"entity": "modules", "local_id": -1, "data": {"name": "Spaet angelegt"}}])
    assert sync_client.run()["ok"]
    with db.cursor() as conn:
        assert [r["name"] for r in db.rows(conn, "SELECT name FROM modules")] == ["Spaet angelegt"]


def test_1184_crash_between_server_apply_and_local_bookkeeping(two_devices, monkeypatch):
    """Absturz nach dem Senden, bevor der PC die Antwort verbucht: der naechste Lauf legt nichts doppelt an."""
    app, ipad = two_devices
    from app import db, service_link, sync_client
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(name) VALUES ('Einmalig')")
    real = service_link.transport

    def crash_after_push(method, url, headers, body, timeout):
        res = real(method, url, headers, body, timeout)
        if url.endswith("/api/sync/push"):
            raise OSError("Verbindung nach dem Senden abgebrochen")
        return res
    monkeypatch.setattr(service_link, "transport", crash_after_push)
    assert not sync_client.run()["ok"]
    monkeypatch.setattr(service_link, "transport", real)
    assert sync_client.run()["ok"]
    assert [m["name"] for m in ipad_pull(app, ipad)[0]["modules"]] == ["Einmalig"]


def test_1181_1184_random_failures_converge(two_devices, monkeypatch):
    """Feste Saat: Aenderungen auf beiden Geraeten, zufaellige Abbrueche; am Ende sind beide Seiten gleich."""
    app, ipad = two_devices
    from app import db, service_link, sync_client
    rng = random.Random(1181)
    real = service_link.transport

    def flaky(method, url, headers, body, timeout):
        if rng.random() < 0.3:
            raise OSError("Netz weg")
        res = real(method, url, headers, body, timeout)
        if rng.random() < 0.2:
            raise OSError("Antwort verloren")
        return res
    monkeypatch.setattr(service_link, "transport", flaky)
    for step in range(25):
        if rng.random() < 0.5:
            with db.cursor() as conn:
                conn.execute("INSERT INTO flashcards(question, answer) VALUES (?, 'a')", (f"pc-{step}",))
        else:
            ipad_push(app, ipad, [{"entity": "flashcards", "local_id": -1, "op_id": f"ipad-op-{step:04d}", "data": {"question": f"ipad-{step}", "answer": "b"}}])
        sync_client.run()
    monkeypatch.setattr(service_link, "transport", real)
    for _ in range(3):
        sync_client.run()
    with db.cursor() as conn:
        here = sorted(r["question"] for r in db.rows(conn, "SELECT question FROM flashcards"))
    there = sorted(r["question"] for r in ipad_pull(app, ipad)[0].get("flashcards", []))
    assert here == there and len(here) == len(set(here)) == 25


# ---------------------------------------------------------------- 139. Grenzen

def test_1194_too_large_note_document_is_refused(app, monkeypatch):
    from app import db, server
    monkeypatch.setattr(server, "MAX_ANNOTATION_BYTES", 2000)
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('a-kurs', 'K')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES ('a-gross', 'a-kurs', 'x.pdf', 'neu')")
    big = {"version": 2, "pages": {"p1": {"objects": [{"id": str(i), "type": "stroke", "points": list(range(40))} for i in range(40)]}}}
    st, _, b = asgi_call(app, "PUT", "/api/files/a-gross/annotations", body=json.dumps(big))
    assert st == 413 and json.loads(b)["code"] == "annotations_too_large"
    st, _, _ = asgi_call(app, "PUT", "/api/files/a-gross/annotations", body=json.dumps({"version": 2, "pages": {}}))
    assert st == 200


def test_1197_storage_quota_in_the_service(app, monkeypatch, tmp_path):
    from app import config, server
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_STORAGE_QUOTA_MB", "1")
    monkeypatch.setattr(config, "files_dir", lambda: tmp_path / "files")
    monkeypatch.setattr(server, "_assets_dir", lambda: tmp_path / "assets")
    (tmp_path / "files").mkdir()
    (tmp_path / "files" / "alt.pdf").write_bytes(b"0" * (900 << 10))
    server._storage_check(50 << 10, 10 << 20, "Die Datei")               # passt noch
    with pytest.raises(server.HTTPException) as e:
        server._storage_check(200 << 10, 10 << 20, "Die Datei")
    assert e.value.status_code == 413 and e.value.detail["code"] == "storage_quota"
    with pytest.raises(server.HTTPException) as e:
        server._storage_check(20 << 20, 10 << 20, "Die Datei")
    assert e.value.detail["code"] == "upload_too_large"


def test_1196_ai_calls_are_limited(monkeypatch):
    import threading
    import time
    from app import ai
    monkeypatch.setattr(ai, "_AI_SLOTS", threading.BoundedSemaphore(2))
    running, peak, lock = [0], [0], threading.Lock()

    def fake(*a, **k):
        with lock:
            running[0] += 1; peak[0] = max(peak[0], running[0])
        time.sleep(0.05)
        with lock:
            running[0] -= 1
        return "ok"
    monkeypatch.setattr(ai, "_ask", fake)
    ts = [threading.Thread(target=lambda: ai.ask("x", timeout=5)) for _ in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert peak[0] == 2


# ---------------------------------------------------------------- 140. Sicherheitsgrenzen

def test_1201_revoked_session_during_sync_stops_further_requests(two_devices):
    app, ipad = two_devices
    from app import accounts, service_link, sync_client
    token = service_link.load_state()["token"]
    accounts.logout(token)                                             # z. B. "Geraet abmelden" vom iPad aus
    out = sync_client.run()
    assert not out["ok"] and not service_link.linked(), "Token vergessen, nichts mehr gesendet"


def test_1202_client_supplied_account_ids_are_ignored(two_devices):
    """Der Dienst nimmt die Identitaet aus der Sitzung; eine mitgeschickte Konto-ID aendert nichts."""
    app, ipad = two_devices
    from app import accounts
    st, d = _hosted(app, "POST", "/api/account/register", {"email": "fremd@example.org", "password": "sehr-geheim-123", "university": "luh"})
    other_id = d["user"]["id"]
    ipad_push(app, ipad, [{"entity": "modules", "local_id": -1, "user_id": other_id, "data": {"name": "Meins", "user_id": other_id}}])
    fremd = {"Authorization": f"Bearer {d['token']}"}
    assert "modules" not in _hosted(app, "GET", "/api/sync/changes", headers=fremd)[1]["changes"]
    assert accounts.authenticate(ipad["Authorization"][7:])["id"] != other_id


def test_1208_concurrent_migration_is_harmless(tmp_path):
    import sqlite3
    from app import db
    a = sqlite3.connect(tmp_path / "x.db"); a.execute("CREATE TABLE t (id INTEGER)")
    db.add_column(a, "t", "neu", "TEXT")
    db.add_column(a, "t", "neu", "TEXT")                               # zweiter Prozess, gleiche Spalte
    assert [r[1] for r in a.execute("PRAGMA table_info(t)")] == ["id", "neu"]
    with pytest.raises(sqlite3.OperationalError):
        db.add_column(a, "fehlt", "x", "TEXT")

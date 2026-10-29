"""Versionsverlauf der Notizen (Editor-Schritt 4, P0-9): hoechstens eine Version je 5 Minuten; mit snapshot=true
(Schliessen, nach Konflikt) und beim Wiederherstellen dazu der ersetzte und der neue Stand; der Stand selbst wird immer
gespeichert. Gleiche Regel im
lokalen Backend des iPads (UniFlowCore AnnotationEndpoints, AnnotationVersionTests)."""
import json

from conftest import asgi_call


def _add_file(file_id):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?, 'c1', 'n.pdf', 'pdf', 'neu')", (file_id,))


def _doc(n):
    return {"version": 2, "pages": {"p1": {"objects": [{"id": f"s{i}", "type": "stroke"} for i in range(n)]}}}


def _put(app, fid, base, n, extra=""):
    st, _, b = asgi_call(app, "PUT", f"/api/files/{fid}/annotations?base_version={base}{extra}", body=json.dumps(_doc(n)))
    assert st == 200, b
    return json.loads(b)["version"]


def _versions(app, fid):
    st, _, b = asgi_call(app, "GET", f"/api/files/{fid}/annotations/versions")
    assert st == 200
    return [r["version"] for r in json.loads(b)]


def _clock(monkeypatch, times):
    from app import db
    left = list(times)
    monkeypatch.setattr(db, "now_iso", lambda: left.pop(0) if len(left) > 1 else left[0])   # danach bleibt die letzte


def test_versions_at_most_every_five_minutes_and_on_snapshot(app, monkeypatch):
    _add_file("f-v")
    _clock(monkeypatch, ["2026-10-29T10:00:00", "2026-10-29T10:00:02", "2026-10-29T10:04:59",
                         "2026-10-29T10:05:00", "2026-10-29T10:05:01", "2026-10-29T10:05:02"])
    assert _put(app, "f-v", 0, 1) == 1                    # erste Version immer
    assert _put(app, "f-v", 1, 2) == 2                    # 2 s spaeter: Stand ja, Version nein
    assert _put(app, "f-v", 2, 3) == 3                    # 4:59 nach der letzten Version: nein
    assert _put(app, "f-v", 3, 4) == 4                    # genau 5 min: ja
    assert _put(app, "f-v", 4, 5) == 5
    assert _put(app, "f-v", 5, 6, "&snapshot=true") == 6  # Schliessen: immer
    assert _versions(app, "f-v") == [6, 5, 4, 1], "Snapshot: der ersetzte Stand (5) und der neue (6)"
    st, _, b = asgi_call(app, "GET", "/api/files/f-v/annotations")
    assert json.loads(b)["version"] == 6 and len(json.loads(b)["data"]["pages"]["p1"]["objects"]) == 6


def test_clock_set_back_still_records_and_bad_snapshot_is_422(app, monkeypatch):
    _add_file("f-c")
    _clock(monkeypatch, ["2026-10-29T10:00:00", "2026-10-29T09:00:00"])
    _put(app, "f-c", 0, 1)
    _put(app, "f-c", 1, 2)
    assert _versions(app, "f-c") == [2, 1]
    st, _, b = asgi_call(app, "PUT", "/api/files/f-c/annotations?base_version=2&snapshot=vielleicht", body=json.dumps(_doc(1)))
    assert st == 422 and json.loads(b)["detail"][0]["type"] == "bool_parsing"


def test_restore_keeps_the_state_before_and_records_a_version(app, monkeypatch):
    _add_file("f-r")
    _clock(monkeypatch, ["2026-10-29T10:00:00", "2026-10-29T10:00:05", "2026-10-29T10:00:06"])
    _put(app, "f-r", 0, 1)
    _put(app, "f-r", 1, 2)                                # ohne Version
    st, _, b = asgi_call(app, "POST", "/api/files/f-r/annotations/restore/1")
    assert st == 200 and json.loads(b)["version"] == 3
    assert _versions(app, "f-r") == [3, 2, 1], "Stand vor dem Wiederherstellen (2) bleibt im Verlauf"
    st, _, b = asgi_call(app, "POST", "/api/files/f-r/annotations/restore/2")
    assert st == 200
    st, _, b = asgi_call(app, "GET", "/api/files/f-r/annotations")
    assert len(json.loads(b)["data"]["pages"]["p1"]["objects"]) == 2


def test_only_thirty_versions_are_kept(app, monkeypatch):
    _add_file("f-k")
    for i in range(35):
        _put(app, "f-k", i, 1, "&snapshot=1")
    v = _versions(app, "f-k")
    assert len(v) == 30 and v[0] == 35 and v[-1] == 6

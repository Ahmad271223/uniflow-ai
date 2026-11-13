"""Eigene Wochen und Abschnitte je Modul (app/module_layout.py, Auftrag 12.11.2026): gemeinsame Faelle mit dem Kern
(tools/gen-module-layout-fixture.py, ModuleLayoutTests.swift) und die Endpunkte am PC-Dienst."""
import json
import subprocess
import sys
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


def test_fixture_current():
    r = subprocess.run([sys.executable, "tools/gen-module-layout-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_order_and_weeks():
    from app import module_layout as ml
    lay = ml.Layout([{"id": 1, "week": 1, "sort": 0}, {"id": 2, "week": 3, "sort": 1}, {"id": 3, "week": 4, "sort": 2},
                     {"id": 4, "week": 2, "sort": 3}])
    assert ml.order([1, 2, 3, 4, 5, -2], lay) == [1, 3, 4, 5, 2, -2]
    assert ml.order([3, -2, 1, -1, 0, -4, 2], ml.Layout()) == [-4, 0, 1, 2, 3, -1, -2]
    g = ml.Layout([{"id": 2, "week": None, "title": "Graphen", "rank": 30.5}], {"b": "s:2", "d": "w:-4"})
    assert g.planning_week("b", 7) == 3 and g.planning_week("d", 7) == 7
    assert g.display_week("b", 7, False) == ml.custom_week(2) and g.display_week("x", 7, True) == ml.UNASSIGNED


def _call(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, (method, path, st, raw[:300])
    return json.loads(raw) if raw else None


def _blocks(d):
    groups = ("vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges")
    return {w["key"]: sorted(f["id"] for g in groups for f in w[g]) for w in d["weeks"]}


def test_endpoints_keep_user_structure(app):
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Layout-Test', '#175ee8', 99, 't')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('ml-c', 'Layout-Test', 'Layout-Test', 'vorlesung', 1, ?, 't')", (mid,))
        for i, n in enumerate(["Folien Graphen.pdf", "Folien Bäume.pdf", "Zusatz.pdf"]):
            conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)", (f"ml-{i}", "ml-c", n, 1_791_000_000 + i * 604_800))
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["layout_custom"] is False and all("section" in f for f in d["files"])
    key = _call(app, "POST", f"/api/modules/{mid}/sections", {"title": "Kapitel Graphen", "after": "w:1"})["key"]
    assert key.startswith("s:")
    assert _call(app, "POST", f"/api/modules/{mid}/place", {"file_ids": ["ml-0", "fremd"], "to": key})["placed"] == 1
    _call(app, "POST", f"/api/modules/{mid}/sections/rename", {"key": key, "title": "Graphen"})
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert _blocks(d)[key] == ["ml-0"]
    assert next(w for w in d["weeks"] if w["key"] == key)["label"] == "Graphen"
    assert any(t["key"] == key for t in d["targets"]) and d["layout_custom"] is True
    # leere eigene Woche bleibt als Ziel; Woche 9 anlegen
    assert _call(app, "POST", f"/api/modules/{mid}/sections", {"title": "Woche 9"})["key"] == "w:9"
    assert _blocks(_call(app, "GET", f"/api/modules/{mid}"))["w:9"] == []
    # neue Datei beim naechsten Abgleich: automatisch, eigene Ordnung bleibt
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES ('ml-3', 'ml-c', 'Folien Neu.pdf', 1791000000)")
    b = _blocks(_call(app, "GET", f"/api/modules/{mid}"))
    assert b[key] == ["ml-0"] and any("ml-3" in v for k, v in b.items() if k != key)
    _call(app, "POST", f"/api/modules/{mid}/sections/delete", {"key": key})
    assert key not in _blocks(_call(app, "GET", f"/api/modules/{mid}"))
    _call(app, "POST", f"/api/modules/{mid}/sections", {"title": " "}, status=400)
    _call(app, "POST", f"/api/modules/{mid}/sections/delete", {"key": "w:-4"}, status=400)
    _call(app, "POST", f"/api/modules/{mid}/place", {"file_ids": ["ml-1"], "to": "s:99999"}, status=400)
    _call(app, "PUT", f"/api/modules/{mid}/sections/order", {"keys": ["w:1", "w:1"]}, status=400)
    _call(app, "POST", "/api/modules/999999/sections", {"title": "X"}, status=404)
    _call(app, "DELETE", f"/api/modules/{mid}/layout")
    assert _call(app, "GET", f"/api/modules/{mid}")["layout_custom"] is False

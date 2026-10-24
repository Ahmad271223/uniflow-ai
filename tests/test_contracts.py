"""Vertragstests: gemeinsames Notizformat (packages/shared-contracts) ueber den echten Server-Endpunkt."""
import json
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "packages" / "shared-contracts" / "fixtures"


def _add_file(file_id):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?,?,?,?, 'neu')", (file_id, "c1", "x.pdf", "pdf"))


def test_web_editor_document_roundtrip_is_lossless(app):
    doc = json.loads((FIXTURES / "documents" / "web-editor.json").read_text(encoding="utf-8"))
    _add_file("f-contract")
    st, _, b = asgi_call(app, "PUT", "/api/files/f-contract/annotations?base_version=0", body=json.dumps(doc))
    assert st == 200 and json.loads(b)["version"] == 1
    st, _, b = asgi_call(app, "GET", "/api/files/f-contract/annotations")
    got = json.loads(b)
    assert got["version"] == 1
    assert got["data"] == doc, "Server muss das Dokument unveraendert speichern (auch unbekannte Felder und pkdrawing)"


def test_conflict_response_has_newer_document(app):
    doc = json.loads((FIXTURES / "documents" / "web-editor.json").read_text(encoding="utf-8"))
    _add_file("f-contract2")
    asgi_call(app, "PUT", "/api/files/f-contract2/annotations?base_version=0", body=json.dumps(doc))
    stale = dict(doc, note="veraltet")
    st, _, b = asgi_call(app, "PUT", "/api/files/f-contract2/annotations?base_version=0", body=json.dumps(stale))
    assert st == 409
    body = json.loads(b)
    assert body["version"] == 1 and body["data"]["note"] == doc["note"], "409 liefert Version und Daten fuer die Zusammenfuehrung"


def test_fixture_documents_follow_schema_rules():
    """Grundregeln aus annotations.schema.json ohne Zusatzbibliothek pruefen."""
    for path in (FIXTURES / "documents").glob("*.json"):
        doc = json.loads(path.read_text(encoding="utf-8"))
        assert doc["version"] == 2, path.name
        keys = {p["key"] for p in doc["pageOrder"]}
        for p in doc["pageOrder"]:
            assert p["type"] in ("pdf", "blank", "asset"), path.name
            if p["type"] == "pdf":
                assert isinstance(p["index"], int) and p["index"] >= 1, path.name
        for key, page in doc["pages"].items():
            assert key in keys, f"{path.name}: Seite {key} fehlt in pageOrder"
            for o in page.get("objects", []):
                assert o.get("id") and o.get("type") in ("stroke", "text", "shape", "image"), path.name
                if o["type"] == "stroke":
                    assert len(o["points"]) % 2 == 0 and len(o["points"]) >= 4, path.name
                    if "widths" in o:
                        assert len(o["widths"]) * 2 == len(o["points"]), path.name
            if "pkdrawing" in page:
                assert {"data", "objectsSig"} <= set(page["pkdrawing"]), path.name


def test_merge_cases_fixture_is_wellformed():
    cases = json.loads((FIXTURES / "merge" / "cases.json").read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 6
    for c in cases:
        assert {"name", "base", "local", "server", "expectIds", "expectConflicts"} <= set(c)

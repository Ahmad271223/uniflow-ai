"""API-Vertraege (packages/shared-contracts/schemas/api/v1) gegen die echten Endpunkte.

Kleiner Pruefer fuer die genutzte Teilmenge von JSON Schema (type, required, properties, items, const, minimum),
damit keine Zusatzbibliothek noetig ist."""
import json
from pathlib import Path

from conftest import asgi_call

SCHEMAS = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "schemas" / "api" / "v1"
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def check(value, schema, path="$"):
    errors = []
    types = schema.get("type")
    if types:
        allowed = types if isinstance(types, list) else [types]
        def ok(t):
            if t == "integer":
                return isinstance(value, int) and not isinstance(value, bool)
            if t == "number":
                return isinstance(value, (int, float)) and not isinstance(value, bool)
            return isinstance(value, TYPES[t])
        if not any(ok(t) for t in allowed):
            return [f"{path}: Typ {type(value).__name__}, erwartet {allowed}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: {value!r} != {schema['const']!r}")
    if "minimum" in schema and isinstance(value, (int, float)) and value < schema["minimum"]:
        errors.append(f"{path}: {value} < {schema['minimum']}")
    if isinstance(value, dict):
        for k in schema.get("required", []):
            if k not in value:
                errors.append(f"{path}: Feld {k} fehlt")
        for k, sub in schema.get("properties", {}).items():
            if k in value:
                errors += check(value[k], sub, f"{path}.{k}")
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value[:50]):
            errors += check(item, schema["items"], f"{path}[{i}]")
    return errors


def schema(name):
    return json.loads((SCHEMAS / f"{name}.schema.json").read_text(encoding="utf-8"))


def _add_file(file_id):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?,?,?,?, 'neu')", (file_id, "c1", "x.pdf", "pdf"))


def test_annotation_endpoints_match_contract(app):
    _add_file("f-api")
    st, _, b = asgi_call(app, "GET", "/api/files/f-api/annotations")
    assert st == 200 and check(json.loads(b), schema("annotations-get")) == []
    doc = {"version": 2, "pages": {}, "pageOrder": []}
    st, _, b = asgi_call(app, "PUT", "/api/files/f-api/annotations?base_version=0", body=json.dumps(doc))
    assert st == 200 and check(json.loads(b), schema("annotations-put")) == []
    st, _, b = asgi_call(app, "PUT", "/api/files/f-api/annotations?base_version=0", body=json.dumps(doc))
    assert st == 409 and check(json.loads(b), schema("annotations-conflict")) == []


def test_library_matches_contract(app):
    _add_file("f-lib")
    st, _, b = asgi_call(app, "GET", "/api/library")
    assert st == 200
    assert check(json.loads(b), schema("library")) == []


def test_errors_match_contract(app):
    for method, path, kwargs in (("GET", "/api/assets/..%5C/x.txt", {}), ("POST", "/api/sync", {"headers": {"origin": "https://boese.example"}}),
                                 ("GET", "/api/files/gibtsnicht", {})):
        st, _, b = asgi_call(app, method, path, **kwargs)
        assert st >= 400
        assert check(json.loads(b), schema("error")) == [], path


def test_checker_finds_violations():
    assert check({"ok": False, "version": 0}, schema("annotations-put")) != []
    assert check({"files": [{"id": 1, "name": "x"}], "modules": [], "folders": [], "trash": []}, schema("library")) != []

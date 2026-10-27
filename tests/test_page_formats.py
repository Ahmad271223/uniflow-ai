"""Seitenformate: Notizbuch/Whiteboard mit A6 … A2 (hoch/quer) und grossen Whiteboards (app/static/formats.js),
Server prueft dieselben Grenzen; der Editor schaltet beim Tippen im Textfeld nicht mehr das Werkzeug um."""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "app" / "static"


def _post_form(app, fields: dict):
    boundary = "----uniflow"
    body = b""
    for k, v in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += f"--{boundary}--\r\n".encode()
    st, _, raw = asgi_call(app, "POST", "/api/notebooks", body=body, content_type=f"multipart/form-data; boundary={boundary}")
    return st, (json.loads(raw) if raw else None)


def _order(app, fid):
    st, _, raw = asgi_call(app, "GET", f"/api/files/{fid}/annotations")
    assert st == 200
    return json.loads(raw)["data"]["pageOrder"]


def test_notebook_and_whiteboard_take_the_chosen_format(app):
    from app import db
    st, d = _post_form(app, {"kind": "notebook", "title": "A3 quer", "template": "grid", "w": 1191, "h": 842})
    assert st == 200, d
    e = _order(app, d["id"])[0]
    assert (e["type"], e["template"], e["w"], e["h"]) == ("blank", "grid", 1191, 842)
    st, d = _post_form(app, {"kind": "whiteboard", "title": "Riesig", "template": "blank", "w": 3370, "h": 2384})
    assert st == 200
    e = _order(app, d["id"])[0]
    assert (e["w"], e["h"]) == (3370, 2384)
    st, d = _post_form(app, {"kind": "notebook", "title": "Standard", "template": "lined"})
    assert st == 200 and (_order(app, d["id"])[0]["w"], _order(app, d["id"])[0]["h"]) == (595, 842), "ohne Angabe A4 hoch"
    st, d = _post_form(app, {"kind": "whiteboard", "title": "Standard"})
    assert st == 200 and (_order(app, d["id"])[0]["w"], _order(app, d["id"])[0]["h"]) == (842, 595), "ohne Angabe A4 quer"
    with db.cursor() as conn:
        conn.execute("DELETE FROM annotations WHERE file_id IN (SELECT id FROM files WHERE course_id='__user__' AND title IN ('A3 quer','Riesig','Standard'))")
        conn.execute("DELETE FROM files WHERE course_id='__user__' AND title IN ('A3 quer','Riesig','Standard')")


def test_invalid_format_is_rejected_without_creating_a_file(app):
    from app import db
    with db.cursor() as conn:
        before = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    for w, h in ((50, 842), (595, 5000), (0, 842)):
        st, d = _post_form(app, {"kind": "notebook", "title": "kaputt", "w": w, "h": h})
        assert (st, d["code"]) == (400, "format_invalid"), (w, h)
    with db.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM files").fetchone()[0] == before


def test_formats_js_rules():
    node = shutil.which("node")
    if not node:
        pytest.skip("node fehlt")
    script = f"""
import {{ FORMATS, WHITEBOARDS, formatSize, formatOf, validSize, sizeLabel, MAX_SIDE }} from {json.dumps((STATIC / "formats.js").resolve().as_uri())};
const out = {{ a4: formatSize("a4"), a4q: formatSize("a4", "landscape"), a6: formatSize("a6"), a2: formatSize("a2"),
  wb: formatSize("wb_a0"), unknown: formatSize("b5"), of: formatOf(842, 1191), ofq: formatOf(1191, 842), ofWb: formatOf(2384, 1684), ofPdf: formatOf(612, 792),
  valid: [validSize(298, 420), validSize(3370, 2384), validSize(99, 400), validSize(595.5, 842), validSize(3401, 100)],
  label: sizeLabel(612, 792), keys: Object.keys(FORMATS), wbKeys: Object.keys(WHITEBOARDS), maxOk: Object.values(WHITEBOARDS).every(f => f.w <= MAX_SIDE && f.h <= MAX_SIDE && f.w > f.h) }};
process.stdout.write(JSON.stringify(out));
"""
    tmp = ROOT / "tests" / "_formats_runner.mjs"
    tmp.write_text(script, encoding="utf-8")
    try:
        p = subprocess.run([node, str(tmp)], capture_output=True, text=True, encoding="utf-8", timeout=60)
    finally:
        tmp.unlink(missing_ok=True)
    assert p.returncode == 0, p.stderr
    r = json.loads(p.stdout)
    assert r["a4"] == {"w": 595, "h": 842} and r["a4q"] == {"w": 842, "h": 595} and r["a6"] == {"w": 298, "h": 420} and r["a2"] == {"w": 1191, "h": 1684}
    assert r["wb"] == {"w": 3370, "h": 2384} and r["unknown"] is None
    assert (r["of"]["key"], r["of"]["orientation"]) == ("a3", "portrait") and r["ofq"]["name"] == "A3 quer" and r["ofWb"]["key"] == "wb_a1" and r["ofPdf"] is None
    assert r["valid"] == [True, True, False, False, False]
    assert r["label"] == "22 × 28 cm" and r["keys"] == ["a6", "a5", "a4", "a3", "a2"] and r["wbKeys"] == ["wb_a4", "wb_a3", "wb_a1", "wb_a0"] and r["maxOk"]


def test_editor_keeps_keyboard_focus_in_text_fields():
    """Textwerkzeug: pointerdown verhindert den Fokuswechsel, das Textfeld holt den Fokus zurueck, Kurzbefehle greifen
    nie in Eingabefeldern; Formate sind im Editor und in der Bibliothek angebunden."""
    ed = (STATIC / "editor.js").read_text(encoding="utf-8")
    assert 'if (e.target !== st) return; ev.preventDefault(); this.createText(pg, p);' in ed
    assert "setTimeout(focusTa, 0)" in ed and "performance.now() - born < 400" in ed
    assert "contenteditable=\"true\"], .ed-textedit" in ed
    assert "import { FORMATS, WHITEBOARDS, formatSize, formatOf, sizeLabel, validSize } from \"./formats.js" in ed
    assert ed.count('data-m="format"') == 2 and "formatPicker(anchor, i)" in ed and "formatPicker(btn, i)" in ed
    assert re.search(r"setFormat\(i, size\)", ed) and "addBlankPage(where = \"after\", template = \"blank\", size = null)" in ed
    lib = (STATIC / "views-lib.js").read_text(encoding="utf-8")
    assert 'fd.append("w", String(size.w)); fd.append("h", String(size.h));' in lib and "WHITEBOARDS" in lib

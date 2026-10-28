"""Python-Zusammenfuehrung (app/annotation_merge.py) gegen die Referenz app/static/merge.js: jeder gemeinsame Fall
(fixtures/merge/cases.json, Seiten und Dokumente) muss dasselbe ganze Ergebnis liefern, dazu die erwarteten Werte."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "merge" / "cases.json"
MERGE_JS = ROOT / "app" / "static" / "merge.js"

RUNNER = """
import { mergePage, mergeDocument } from %(merge)s;
import { readFileSync } from "node:fs";
const fx = JSON.parse(readFileSync(%(fixture)s, "utf8"));
const out = { cases: fx.cases.map(c => mergePage(c.base, c.local, c.server)),
              documentCases: fx.documentCases.map(c => mergeDocument(c.base, c.local, c.server)) };
process.stdout.write(JSON.stringify(out));
"""


def canon(v):
    from app.annotation_merge import stable_stringify
    return stable_stringify(v)


@pytest.fixture(scope="module")
def js(tmp_path_factory):
    node = shutil.which("node")
    if not node:
        pytest.skip("node fehlt")
    runner = tmp_path_factory.mktemp("merge-py") / "run.mjs"
    runner.write_text(RUNNER % {"merge": json.dumps(MERGE_JS.resolve().as_uri()), "fixture": json.dumps(str(FIXTURE))}, encoding="utf-8")
    p = subprocess.run([node, str(runner)], capture_output=True, text=True, timeout=60, encoding="utf-8")
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def test_page_cases_equal_merge_js(js):
    from app.annotation_merge import merge_page
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for c, r in zip(fx["cases"], js["cases"]):
        page, conflicts = merge_page(c.get("base"), c.get("local"), c.get("server"))
        assert (canon(page), conflicts) == (canon(r["page"]), r["conflicts"]), c["name"]
        ids = None if page is None else [o.get("id") if isinstance(o.get("id"), str) else None for o in page["objects"]]
        assert ids == c["expectIds"] and conflicts == c["expectConflicts"], c["name"]


def test_document_cases_equal_merge_js(js):
    from app.annotation_merge import merge_document
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for c, r in zip(fx["documentCases"], js["documentCases"]):
        doc, conflicts, oc = merge_document(c.get("base"), c.get("local"), c.get("server"))
        assert canon(doc) == canon(r["doc"]), c["name"]
        assert (conflicts, oc) == (r["conflicts"], r["orderConflict"]) == (c["expectConflicts"], c["expectOrderConflict"]), c["name"]

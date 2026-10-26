"""Vertrag Zusammenfuehrung: app/static/merge.js (Referenz) gegen packages/shared-contracts/fixtures/merge/cases.json –
Seitenfaelle (cases) und Dokumentfaelle (documentCases: Seitenreihenfolge, Papierkorb, Wurzelfelder). Laeuft in Node;
ohne Node wird uebersprungen. Kotlin prueft dieselben Faelle (SharedFixtureTest), Swift zieht nach."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "merge" / "cases.json"
MERGE_JS = ROOT / "app" / "static" / "merge.js"

RUNNER = """
import { mergePage, mergeDocument, objectId } from %(merge)s;
import { readFileSync } from "node:fs";
const fx = JSON.parse(readFileSync(%(fixture)s, "utf8"));
const ids = objs => (objs || []).map(o => typeof o.id === "string" ? o.id : null);
const keyOf = e => typeof e === "string" ? e : (e.key ?? e.entry?.key ?? null);
const out = { cases: [], documentCases: [] };
for (const c of fx.cases) {
  const r = mergePage(c.base, c.local, c.server);
  out.cases.push({ ids: r.page ? ids(r.page.objects) : null, conflicts: r.conflicts,
    field: c.expectField && r.page ? r.page.objects[c.expectField.index]?.[c.expectField.key] ?? null : null,
    pageField: c.expectPageField && r.page ? r.page[c.expectPageField.key] ?? null : null });
}
for (const c of fx.documentCases) {
  const r = mergeDocument(c.base, c.local, c.server);
  out.documentCases.push({ order: r.doc.pageOrder.map(keyOf), trash: r.doc.deletedPages.map(keyOf), conflicts: r.conflicts,
    orderConflict: r.orderConflict, pages: Object.fromEntries(Object.entries(r.doc.pages).map(([k, p]) => [k, ids(p.objects)])),
    entries: Object.fromEntries(r.doc.pageOrder.map(e => [keyOf(e), e])), note: r.doc.note ?? null, bookmarks: r.doc.bookmarks ?? null,
    orderPagesExist: r.doc.pageOrder.every(e => keyOf(e) in r.doc.pages) });
}
process.stdout.write(JSON.stringify(out));
"""


@pytest.fixture(scope="module")
def results(tmp_path_factory):
    node = shutil.which("node")
    if not node:
        pytest.skip("node fehlt")
    runner = tmp_path_factory.mktemp("merge") / "run.mjs"
    runner.write_text(RUNNER % {"merge": json.dumps(MERGE_JS.resolve().as_uri()), "fixture": json.dumps(str(FIXTURE))}, encoding="utf-8")
    p = subprocess.run([node, str(runner)], capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def _canon(v):
    return json.dumps(v, sort_keys=True, separators=(",", ":"))


def test_page_cases_match_merge_js(results):
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for c, r in zip(fx["cases"], results["cases"]):
        assert r["ids"] == c["expectIds"], c["name"]
        assert r["conflicts"] == c["expectConflicts"], c["name"]
        if c.get("expectField"):
            assert _canon(r["field"]) == _canon(c["expectField"]["value"]), c["name"]
        if c.get("expectPageField"):
            assert _canon(r["pageField"]) == _canon(c["expectPageField"]["value"]), c["name"]


def test_document_cases_match_merge_js(results):
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert len(fx["documentCases"]) >= 15
    for c, r in zip(fx["documentCases"], results["documentCases"]):
        assert r["order"] == c["expectOrder"], c["name"]
        assert r["trash"] == c["expectTrash"], c["name"]
        assert (r["conflicts"], r["orderConflict"]) == (c["expectConflicts"], c["expectOrderConflict"]), c["name"]
        assert r["orderPagesExist"], c["name"]
        for k, ids in c.get("expectPageIds", {}).items():
            assert r["pages"][k] == ids, c["name"]
        if c.get("expectEntry"):
            e = c["expectEntry"]
            assert _canon(r["entries"][e["key"]].get(e["field"])) == _canon(e["value"]), c["name"]
        if "expectNote" in c:
            assert r["note"] == c["expectNote"], c["name"]
        if "expectBookmarks" in c:
            assert _canon(r["bookmarks"]) == _canon(c["expectBookmarks"]), c["name"]


def test_document_fixture_is_wellformed():
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    names = [c["name"] for c in fx["documentCases"]]
    assert len(names) == len(set(names))
    for c in fx["documentCases"]:
        assert {"name", "base", "local", "server", "expectOrder", "expectTrash", "expectConflicts", "expectOrderConflict"} <= set(c), c["name"]
        for side in ("local", "server"):
            assert isinstance(c[side]["pageOrder"], list) and isinstance(c[side]["pages"], dict), c["name"]
    assert any(c["expectOrderConflict"] for c in fx["documentCases"]), "mindestens ein sichtbarer Reihenfolge-Konflikt"
    assert "documentDescription" in fx

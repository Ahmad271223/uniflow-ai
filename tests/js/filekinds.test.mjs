// Dateiarten (docs/DATEIARTEN.md): dieselben Faelle wie Python (tests/test_office_text.py) und Kern (OfficeTextTests).
// Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { sourceKind, isTextSource, displayType, kindIcon, kindText, pagesHtml } from "../../app/static/filekinds.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const cases = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/office-text/cases.json"), "utf8"));
const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

test("Art aus dem Dateinamen wie Python und Kern", () => {
  for (const c of cases.kinds) {
    assert.equal(sourceKind(c.name), c.kind, c.name);
    assert.equal(isTextSource(c.name), ["pdf", "docx", "pptx"].includes(c.kind), c.name);
  }
  for (const f of cases.files) assert.equal(sourceKind(f.file), f.kind);
});

test("Anzeige-Art, Symbol und Beschriftung in der Bibliothek", () => {
  assert.equal(displayType({ kind: "pdf", doc_type: "uebung", name: "u1.pdf" }), "uebung");
  assert.equal(displayType({ kind: "pdf", name: "x.pdf" }), "sonstiges");
  assert.equal(displayType({ kind: "file", name: "bericht.docx" }), "word");
  assert.equal(displayType({ kind: "file", name: "Folien.PPTX" }), "slides");
  assert.equal(displayType({ kind: "file", name: "vl.m4a" }), "audio");
  assert.equal(displayType({ kind: "file", name: "alt.doc" }), "file");
  assert.equal(displayType({ kind: "notebook", name: "" }), "notebook");
  assert.equal(kindIcon({ kind: "file", name: "a.pptx" }, "file"), "layers");
  assert.equal(kindIcon({ kind: "file", name: "a.doc" }, "file"), "file");
  assert.equal(kindText({ kind: "file", name: "a.mp3" }, ""), "Audio");
});

test("Seiten als Textansicht: Folien nummeriert, Text maskiert, leere Folie gekennzeichnet", () => {
  const folien = cases.files.find(f => f.file === "folien.pptx");
  const html = pagesHtml(folien.pages, "pptx", esc);
  assert.equal((html.match(/<section class="textpage"/g) || []).length, folien.pages.length);
  assert.ok(html.includes("Folie 1</h4>Netzwerkanalyse") && html.includes("Folie 4</h4><span class=\"muted\">(ohne Text)</span>"));
  assert.ok(!html.includes("<a:") && html.includes("Notizen:"));
  assert.ok(pagesHtml(["<b>x</b>"], "docx", esc).includes("Seite 1</h4>&lt;b&gt;x&lt;/b&gt;"));
});

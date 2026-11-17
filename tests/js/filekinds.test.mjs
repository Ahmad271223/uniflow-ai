// Dateiarten (docs/DATEIARTEN.md): dieselben Faelle wie Python (tests/test_office_text.py) und Kern (OfficeTextTests).
// Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { sourceKind, isTextSource, displayType, kindIcon, kindText, pagesHtml, isNewFile } from "../../app/static/filekinds.js";

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

// "Neu" nur 24 Stunden (Auftrag 17.11.2026): der Server rechnet (is_new), die Oberflaeche zeigt und zaehlt nur danach.
// Dieselben Faelle wie UFNewFiles in apps/apple/UniFlowTests/Neu24StundenAppTests.swift.
test("Neu folgt is_new vom Server, aeltere Antworten der alten Regel", () => {
  assert.equal(isNewFile({ is_new: 1, seen_by_user: 0, status: "gelesen" }), true);
  assert.equal(isNewFile({ is_new: 0, seen_by_user: 0, status: "neu" }), false, "aelter als 24 Stunden: nicht mehr neu, auch nie geoeffnet");
  assert.equal(isNewFile({ is_new: true }), true);
  assert.equal(isNewFile({ is_new: false, status: "neu" }), false);
  // aelterer Server ohne is_new
  assert.equal(isNewFile({ seen_by_user: 0, status: "gelesen" }), true);
  assert.equal(isNewFile({ seen_by_user: 1, status: "neu" }), false);
  assert.equal(isNewFile({ is_new: null, seen_by_user: 0 }), true);
  assert.equal(isNewFile({ status: "neu" }), true);
  assert.equal(isNewFile({ status: "gelesen" }), false);
  const files = [{ is_new: 1 }, { is_new: 0, seen_by_user: 0 }, { is_new: 0, status: "neu" }, { is_new: 1 }];
  assert.equal(files.filter(isNewFile).length, 2);
});

test("die Bibliothek benutzt die eine Regel", () => {
  const lib = readFileSync(new URL("../../app/static/views-lib.js", import.meta.url), "utf8");
  assert.match(lib, /import \{[^}]*isNewFile[^}]*\} from "\.\/filekinds\.js\?v=\d+"/);
  assert.ok(!/function isNewFile/.test(lib), "keine zweite Fassung");
  assert.match(lib, /activeFiles\.filter\(isNewFile\)/);
});

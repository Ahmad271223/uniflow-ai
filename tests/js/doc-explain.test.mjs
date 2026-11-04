// KI-Tutor fuer das ganze Dokument (app/static/doc-explain-logic.js, 05.11.2026), ohne Browser.
// Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { SCOPES, CHIPS, scopeBody, docModeFor, pagesLabel, progressText, storedNote, needsConfirm, blockHtml, stepBody }
  from "../../app/static/doc-explain-logic.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const cases = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/doc-explain/cases.json"), "utf8"));
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

test("Umfang und Schnellknoepfe wie auf dem iPad", () => {
  assert.deepEqual(SCOPES.map(s => s[1]), ["Diese Seite", "Ganzes Dokument", "Seiten …"]);
  assert.deepEqual(CHIPS, [["lecture", "Ganze Vorlesung erklären"], ["tasks", "Alle Aufgaben erklären"]]);
  assert.deepEqual(scopeBody("page", 1, 1), { kind: "page" });
  assert.deepEqual(scopeBody("all", 1, 1), { kind: "all" });
  assert.deepEqual(scopeBody("range", "12", "5"), { kind: "range", from: 5, to: 12 }, "vertauschte Grenzen");
  assert.deepEqual(scopeBody("range", "", "x"), { kind: "range", from: 1, to: 1 });
  assert.equal(docModeFor("explain", "page"), null);
  assert.equal(docModeFor("summary", "all"), "lecture");
  assert.equal(docModeFor("steps", "range"), "tasks");
  assert.equal(docModeFor("flashcards", "all"), null);
});

test("Seitenangaben wie app/doc_explain.py", () => {
  for (const l of cases.labels) assert.equal(pagesLabel(l.from, l.to), l.short);
  assert.equal(progressText(1, 4, "Seiten 16–30"), "Teil 2 von 4 · Seiten 16–30");
  assert.equal(storedNote(4, 4), "Schon erklärt · 0 Credits");
  assert.equal(storedNote(1, 4), "1 von 4 Teilen schon erklärt · 0 Credits");
  assert.equal(storedNote(0, 4), null);
});

test("Rueckfrage vor dem Start nur bei mehr als ein paar Credits oder wenn es nicht reicht", () => {
  for (const e of cases.estimates) assert.equal(needsConfirm({ confirm: e.out.confirm, enough: e.out.enough }), e.out.confirm || !e.out.enough);
  const six = cases.estimates.find(e => e.in.way === "credits" && e.in.calls === 6 && e.in.remaining === 74);
  assert.equal(six.out.message, "Kostet etwa 6 Credits, du hast 74.");
  assert.equal(needsConfirm(null), false);
});

test("Bloecke: Seiten als Link, Text escaped, Ueberblick hervorgehoben", () => {
  const blocks = cases.blocks.find(b => b.name === "tasks").out;
  const html = blocks.map(b => blockHtml(b, esc, t => `<p>${esc(t)}</p>`)).join("");
  assert.match(html, /data-page="1">S\. 1<\/a>/);
  assert.match(html, /data-page="1">S\. 1–2<\/a>/);
  assert.equal((html.match(/class="ed-doc-block"/g) || []).length, blocks.length);
  const full = cases.blocks.find(b => b.name === "full").out;
  assert.match(blockHtml(full[0], esc, t => t), /ed-doc-overview/);
  assert.match(blockHtml({ kind: "task", title: "<b>x</b>", from: 2, to: 2, text: "" }, esc, t => t), /&lt;b&gt;x&lt;\/b&gt;/);
  assert.deepEqual(stepBody({ file_id: "f", mode: "tasks" }, { id: "1:tasks:1-2" }, "r1"), { file_id: "f", mode: "tasks", step: "1:tasks:1-2", request_id: "r1" });
  assert.equal(stepBody({}, { id: "x" }, "r", true).force, true);
});

test("Editor bindet Umfang, Schnellknoepfe und den Lauf ein", () => {
  const ed = readFileSync(join(root, "app/static/editor.js"), "utf8");
  assert.match(ed, /from "\.\/doc-explain-logic\.js\?v=\d+"/);
  for (const s of ["ed-ai-scope", "ed-ai-doc", "/api/ai/document/plan", "/api/ai/document/step", "needsConfirm(plan)"]) assert.ok(ed.includes(s), s);
});

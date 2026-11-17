// Block "Klausuren & Altklausuren" geordnet (app/static/exam-groups.js, Wunsch des Inhabers 17.11.2026): dieselbe
// Ansicht wie ModuleExamGroups.swift. Die Ordnung selbst rechnet der Server (tests/test_exam_pairs.py); hier die Daten
// aus packages/shared-contracts/fixtures/local-backend/exam-pairs.json und was die Seite daraus zeichnet.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as EG from "../../app/static/exam-groups.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = f => readFileSync(join(root, f), "utf8");
const fixture = JSON.parse(read("packages/shared-contracts/fixtures/local-backend/exam-pairs.json"));
const groups = fixture.groups.find(c => c.case === "Jahrgaenge wie im echten Kurs").groups;
const row = f => `<a class="doc-row">${f.name}</a>`;

test("nur der Block Klausuren & Altklausuren bekommt die Ordnung nach Jahrgang", () => {
  assert.equal(EG.groupsOf({ week: -2, exam_groups: groups }).length, groups.length);
  assert.deepEqual(EG.groupsOf({ week: 3, exam_groups: groups }), []);
  assert.deepEqual(EG.groupsOf({ week: -2 }), [], "aelterer Server ohne exam_groups: Block bleibt nach Art");
  assert.deepEqual(EG.groupsOf({ week: -2, exam_groups: [{ label: "WS 22/23", files: [] }] }), []);
  assert.deepEqual(EG.COVERED, ["klausuren", "loesungen"]);
});

test("Zahlen hinter dem Jahrgang", () => {
  const f = (...roles) => roles.map(r => ({ exam_role: r }));
  assert.equal(EG.summary(f("klausur")), "1 Klausur");
  assert.equal(EG.summary(f("klausur", "loesung", "klausur")), "2 Klausuren, 1 Lösung");
  assert.equal(EG.summary(f("klausur", "loesung", "weitere_loesung")), "1 Klausur, 2 Lösungen");
  assert.equal(EG.summary(f("weitere_loesung")), "1 Lösung");
  assert.equal(EG.summary([]), "");
});

test("neuester Jahrgang zuerst, jede Klausur mit ihrer Loesung direkt darunter und eingerueckt", () => {
  const html = EG.html(groups, row);
  const order = [...html.matchAll(/<h4[^>]*>([^<]+) <span/g)].map(m => m[1]);
  assert.deepEqual(order.slice(0, 5), ["WS 25/26", "SS 24", "WS 23/24", "WS 22/23", "WS 20/21"]);
  const names = [...html.matchAll(/<a class="doc-row">([^<]+)<\/a>/g)].map(m => m[1]);
  const all = groups.flatMap(g => g.files.map(f => f.name));
  assert.deepEqual(names, all, "jede Datei genau einmal, in der Reihenfolge des Servers");
  assert.ok(html.indexOf("KK1.pdf") < html.indexOf("KK1loes.pdf") && html.indexOf("KK1loes.pdf") < html.indexOf("KK2.pdf"));
  const paired = groups.flatMap(g => g.files).filter(EG.isPaired).length;
  assert.equal((html.match(/class="exam-pair"/g) || []).length, paired);
  assert.ok(html.includes('<div style="flex:1;min-width:0"><a class="doc-row">KK1loes.pdf</a></div>'));
  assert.ok(!html.includes('exam-pair" style="display:flex;align-items:center;gap:.1rem" title="Lösung zur Klausur darüber"><span class="muted" aria-hidden="true" style="flex:0 0 1.4rem;text-align:center">↳</span><div style="flex:1;min-width:0"><a class="doc-row">Lösungen.pdf'),
    "die Sammel-Loesung steht am Ende des Jahrgangs, nicht unter einer Klausur");
});

test("Namen werden als Text gezeichnet", () => {
  const html = EG.html([{ label: "<b>WS</b>", files: [{ name: "x", exam_role: "klausur" }] }], () => "");
  assert.ok(html.includes("&lt;b&gt;WS&lt;/b&gt;") && !html.includes("<b>WS</b>"));
});

test("die Modulseite bindet die Ordnung ein und laesst die anderen Wochen nach Art", () => {
  const misc = read("app/static/views-misc.js");
  assert.ok(misc.includes('import * as EG from "./exam-groups.js?v=1"'));
  assert.ok(misc.includes("EG.html(EG.groupsOf(w), doneRow)"));
  assert.ok(misc.includes("!(EG.groupsOf(w).length && EG.COVERED.includes(k))"));
});

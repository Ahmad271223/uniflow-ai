// Schreibhand und geteilte Ansicht im Web (app/static/doc-nav.js), dieselben Faelle wie SplitSidesAppTests auf dem iPad:
// Skript und Loesung auf der Seite der freien Hand, ein Blatt oder eine Uebung neben der Folie auf der Seite der
// Schreibhand (Befund 09.11.2026: bisher lag jedes zweite Dokument auf der Seite der freien Hand).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isExercise, splitRole, paneBLeft } from "../../app/static/doc-nav.js";

const script = { id: "s", name: "VL03 Graphen.pdf", doc_type: "vorlesung", kind: "pdf" };
const exercise = { id: "u", name: "Uebung 3.pdf", doc_type: "uebung", kind: "pdf" };
const sheet = { id: "n", name: "Notizen", kind: "notebook" };

test("Uebung erkannt wie bisher in views-doc.js", () => {
  assert.equal(isExercise(exercise), true);
  assert.equal(isExercise({ name: "Blatt 2.pdf" }), true);
  assert.equal(isExercise({ name: "x.pdf", studip_folder: "Aufgaben" }), true);
  assert.equal(isExercise(script), false);
});

test("Skript neben der Uebung: Seite der freien Hand", () => {
  assert.equal(splitRole(script, exercise), "reference");
  assert.equal(paneBLeft("right", splitRole(script, exercise)), true, "Rechtshaender: Skript links");
  assert.equal(paneBLeft("left", splitRole(script, exercise)), false, "Linkshaender: Skript rechts");
  assert.equal(paneBLeft(undefined, "reference"), true, "ohne Einstellung wie Rechtshaender");
});

test("Blatt oder Uebung neben dem Skript: Seite der Schreibhand", () => {
  assert.equal(splitRole(sheet, script), "writing");
  assert.equal(splitRole(exercise, script), "writing");
  assert.equal(paneBLeft("right", "writing"), false, "Rechtshaender: Uebung rechts, Skript links");
  assert.equal(paneBLeft("left", "writing"), true, "Linkshaender: Uebung links");
  assert.equal(splitRole(exercise, exercise), "reference", "zwei Uebungen: wie bisher");
  assert.equal(splitRole(script, sheet), "reference");
});

test("views-doc.js legt die geteilte Ansicht danach an", () => {
  const src = readFileSync(new URL("../../app/static/views-doc.js", import.meta.url), "utf8");
  assert.match(src, /paneBLeft\(settings\.hand, splitRole\(f2, f\)\)/);
  assert.match(src, /const right = bLeft,/);
});

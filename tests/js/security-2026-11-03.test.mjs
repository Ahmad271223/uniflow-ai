// Sicherheitspruefung 3.11.2026: Grenzen fuer Strichlisten beim Oeffnen einer Loesung (Fund 9) und Werte aus der
// Adresse bzw. aus Stud.IP nur geprueft in innerHTML (Fund 5 und 8). Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as S from "../../app/static/solutions.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = name => readFileSync(join(root, "app/static", name), "utf8");

test("Strichlisten: Grenze je Liste und insgesamt wie Python und Swift", () => {
  assert.equal(S.LIMITS.maxStrokeValues, 100000);
  assert.equal(S.LIMITS.maxStrokeNumbers, 10000000);
  const page = objects => ({ pages: [{ key: "p1", objects }] });
  S.checkStrokeSizes(page([{ type: "stroke", pointsDelta: new Array(100000).fill(0) }]));
  assert.throws(() => S.checkStrokeSizes(page([{ type: "stroke", pointsDelta: new Array(100001).fill(0) }])), e => e.code === "tooLarge");
  assert.throws(() => S.checkStrokeSizes(page([{ type: "stroke", points: new Array(100001).fill(0) }])), e => e.code === "tooLarge");
  // Formen zaehlen nicht (nur Striche werden dekodiert)
  S.checkStrokeSizes(page([{ type: "shape", points: new Array(200000).fill(0) }]));
  const many = Array.from({ length: 101 }, () => ({ type: "stroke", pointsDelta: new Array(99999).fill(0) }));
  assert.throws(() => S.checkStrokeSizes({ pages: [{ key: "p1", objects: many }] }), e => e.code === "tooLarge");
});

test("Lernkalender: Ansicht, Datum und Modul aus der Adresse nur in fester Form", () => {
  const plan = src("views-plan.js");
  assert.match(plan, /PLAN_VIEWS = \["day", "3days", "week", "month", "list"\]/);
  assert.match(plan, /if \(PLAN_VIEWS\.includes\(params\.view\)\) planState\.view = params\.view;/);
  assert.doesNotMatch(plan, /if \(params\.view\) planState\.view = params\.view/);
});

test("Bibliothek: Pfad, data-open und Ordnerfarben nur geprueft bzw. escaped", () => {
  const lib = src("views-lib.js");
  assert.doesNotMatch(lib, /data-open="path:\$\{it\.path\}"/);
  assert.doesNotMatch(lib, /href="#\/files\?path=\$\{c\.path\}"/);
  assert.doesNotMatch(lib, /--fc:\$\{it\.color \|\|/);
  assert.match(lib, /const path = \/\^\[A-Za-z0-9_\\\/-\]\*\$\/\.test/);
});

test("Wochentest: Raum und Zeiten der Vorlesung escaped", () => {
  assert.match(src("views-weekly.js"), /\$\{esc\(pv\.lecture\.start\)\}–\$\{esc\(pv\.lecture\.end\)\}\$\{pv\.lecture\.room \? ` · \$\{esc\(pv\.lecture\.room\)\}`/);
});

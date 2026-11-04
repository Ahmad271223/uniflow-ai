// Lernstand-Beschriftung (app/static/mastery.js) ohne Browser: dieselben Faelle wie tests/test_mastery.py, MasteryTests
// (Kern) und LernstandAppTests (iPad): das Feld `mastery` der Antwort wird zu "Lernstand 64 %" bzw. "noch kein Lernstand".
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { masteryLabel, masterySub, masteryAria, masteryHtml, HINT } from "../../app/static/mastery.js";

const fx = JSON.parse(readFileSync(new URL("../../packages/shared-contracts/fixtures/mastery/cases.json", import.meta.url), "utf8"));

test("Beschriftung wie im Fixture", () => {
  assert.ok(fx.cases.length >= 12);
  for (const c of fx.cases) {
    assert.equal(masteryLabel(c.expected), c.label, c.name);
    assert.equal(masterySub(c.expected), c.expected ? c.expected.reason : HINT, c.name);
  }
  assert.equal(fx.hint, HINT, "Hinweis ohne Lernstand steht im Fixture");
});

test("ohne Feld (alter Server) wie ohne Lernstand", () => {
  assert.equal(masteryLabel(undefined), "noch kein Lernstand");
  assert.equal(masteryLabel({ score: "x" }), "noch kein Lernstand");
  assert.equal(masteryAria(null), `noch kein Lernstand, ${HINT}`);
  assert.equal(masteryAria({ score: 64, reason: "3 Wochentests" }), "Lernstand 64 Prozent, 3 Wochentests");
});

test("HTML: Ring mit Prozent, Begruendung nur in der mittleren Groesse, Werte escaped", () => {
  const md = masteryHtml({ score: 64, reason: "3 Wochentests <b>" });
  assert.match(md, /class="mastery md"/);
  assert.match(md, /style="--p:64"/);
  assert.match(md, /<b>Lernstand 64 %<\/b><small>3 Wochentests &lt;b&gt;<\/small>/);
  const sm = masteryHtml({ score: 120.4, reason: "r" }, "sm");
  assert.match(sm, /--p:100/, "gedeckelt");
  assert.ok(!sm.includes("<small>"), "klein: nur Ring und Zahl");
  const none = masteryHtml(null, "sm");
  assert.match(none, /class="mastery sm none"/);
  assert.match(none, /--p:0/);
  assert.match(none, new RegExp(`title="${HINT}"`));
});

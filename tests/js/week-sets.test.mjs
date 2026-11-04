// Karte "Fertige Fragen" je Lehrwoche (app/static/week-sets-logic.js), ohne Browser. Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { RIGHT, POLL_MAX, cardMode, statusText, setsLabel, keepPolling } from "../../app/static/week-sets-logic.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

test("Recht wie in app/plans.py", () => {
  const plans = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/plans/plans.json"), "utf8"));
  assert.equal(plans.entitlements[RIGHT].from, "pro_ai");
  assert.equal(plans.entitlements[RIGHT].status, "available");
});

test("ohne Pro AI: Schloss, am eigenen PC nur ein Hinweis in der aktuellen Woche", () => {
  assert.equal(cardMode({ hosted: true, allowed: false, status: "ready", current: true }), "locked");
  assert.equal(cardMode({ hosted: false, allowed: true, status: "ready", current: true }), "service_only");
  assert.equal(cardMode({ hosted: false, allowed: true, status: "ready", current: false }), "hidden");
});

test("Kartenzustaende wie im Vertrag (packages/shared-contracts/fixtures/week-sets)", () => {
  const c = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/week-sets/week-sets.json"), "utf8"));
  assert.ok(c.card_modes.length >= 10);
  for (const x of c.card_modes) assert.equal(cardMode(x), x.mode, JSON.stringify(x));
  assert.equal(c.constants.right, RIGHT);
});

test("Status je Woche", () => {
  const m = (status, current = false) => cardMode({ hosted: true, allowed: true, status, current });
  assert.equal(m("ready"), "show");
  assert.equal(m("preparing"), "poll");
  assert.equal(m("none", true), "auto_prepare", "aktuelle Woche bereitet von selbst vor");
  assert.equal(m("none", false), "offer_prepare", "andere Wochen nur auf Knopfdruck (Kosten)");
  assert.equal(m("failed"), "retry");
  assert.equal(m("missing_content"), "info");
  assert.equal(m("no_material"), "hidden");
});

test("Texte deutsch und einfach, Codes des Dienstes", () => {
  assert.match(statusText("preparing"), /bereitet die Fragen dieser Woche gerade vor/);
  assert.match(statusText("failed", "ai_library_budget_exhausted"), /Budget/);
  assert.match(statusText(null, "library_prep_limit"), /Morgen/);
  assert.match(statusText("missing_content"), /noch nicht geladen/);
  assert.equal(statusText("ready"), null);
});

test("Saetze und Nachfragen", () => {
  assert.equal(setsLabel([{ count: 15 }, { count: 15 }, { count: 15 }]), "3 Sätze · je 15 Fragen");
  assert.equal(setsLabel([{ count: 15 }]), "1 Satz · je 15 Fragen");
  assert.equal(setsLabel([]), "");
  assert.ok(keepPolling("preparing", 0));
  assert.ok(!keepPolling("preparing", POLL_MAX));
  assert.ok(!keepPolling("ready", 0));
});

test("Karte haengt im Modul an jeder Lehrwoche, Logik in neuen Dateien", () => {
  const misc = readFileSync(join(root, "app/static/views-misc.js"), "utf8");
  assert.match(misc, /class="ws-host" data-w="\$\{w\.week\}"/);
  assert.match(misc, /import\("\.\/week-sets\.js\?v=\d+"\)/);
  const ui = readFileSync(join(root, "app/static/week-sets.js"), "utf8");
  assert.match(ui, /href="#\/abo"/, "Weg zur Tarifseite");
  assert.match(ui, /Test starten/);
  assert.match(ui, /#\/exams\/\$\{r\.test_id\}/);
});

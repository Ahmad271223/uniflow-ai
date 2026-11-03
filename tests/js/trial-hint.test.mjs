// Probe des Kontos auf der Uebersicht (app/static/trial-hint.js): "noch N Tage alles frei", danach die Aufforderung zur
// Tarifwahl. Texte wie UFTrialTexts in apps/apple/UniFlow/Views/Settings/TrialBanner.swift (8b715df).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { trialHintHtml, trialTitle, TRIAL_TEXTS } from "../../app/static/trial-hint.js";
import { icon } from "../../app/static/icons.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const running = (days_left, extra = {}) => ({ trial: { granted: true, active: true, days_left, ends_at: "2026-11-10T12:00:00", ...extra }, needs_plan_choice: false });
const over = { trial: { granted: true, active: false, days_left: 0, expired: true }, needs_plan_choice: true };

test("laufende Probe: noch N Tage alles frei", () => {
  assert.equal(trialTitle(1), "Probe: noch 1 Tag alles frei");
  assert.equal(trialTitle(6), "Probe: noch 6 Tage alles frei");
  const html = trialHintHtml(running(6), true, icon, esc);
  assert.match(html, /<b>Probe: noch 6 Tage alles frei<\/b>/);
  assert.match(html, /Bis 10\.11\.2026 hast du alle Funktionen\. Danach wählst du einen Tarif/);
  assert.match(html, /href="#\/abo">Tarife ansehen</);
  assert.ok(!html.includes("trialFree"), "waehrend der Probe kein 'Bei Free bleiben'");
});

test("Probe vorbei: Aufforderung mit Tarife ansehen und Bei Free bleiben", () => {
  const html = trialHintHtml(over, true, icon, esc);
  assert.match(html, /<b>Deine Probe ist vorbei<\/b>/);
  assert.ok(html.includes("Sieben Tage lang war alles frei. Wähle jetzt einen Tarif oder bleib bei Free. Deine Notizen bleiben in jedem Fall erhalten und lesbar."));
  assert.match(html, /href="#\/abo">Tarife ansehen</);
  assert.match(html, /id="trialFree">Bei Free bleiben</);
});

test("nichts zu sagen: leer", () => {
  assert.equal(trialHintHtml(running(6), false, icon, esc), "", "eigener PC: keine Tarife");
  assert.equal(trialHintHtml(null, true, icon, esc), "");
  assert.equal(trialHintHtml({}, true, icon, esc), "");
  assert.equal(trialHintHtml({ trial: { granted: false } }, true, icon, esc), "", "nie eine Probe gehabt");
  assert.equal(trialHintHtml({ trial: { granted: true, active: false }, needs_plan_choice: false }, true, icon, esc), "", "schon gewaehlt");
});

test("die Texte sind dieselben wie auf dem iPad", () => {
  const swift = readFileSync(join(root, "apps/apple/UniFlow/Views/Settings/TrialBanner.swift"), "utf8");
  for (const t of [TRIAL_TEXTS.over, TRIAL_TEXTS.overText, TRIAL_TEXTS.plans, TRIAL_TEXTS.stayFree]) assert.ok(swift.includes(t), t);
  assert.ok(swift.includes('"Probe: noch \\(days) \\(days == 1 ? "Tag" : "Tage") alles frei"'));
});

test("app.js benutzt das Modul und bedient 'Bei Free bleiben'", () => {
  const app = readFileSync(join(root, "app/static/app.js"), "utf8");
  assert.match(app, /trial-hint\.js\?v=\d+/);
  assert.match(app, /return trialHintHtml\(state\.entitlements, state\.hosted, icon, esc\)/);
  assert.match(app, /closest\?\.\("#trialFree"\)/);
  assert.match(app, /\/billing\/plan-choice/);
});

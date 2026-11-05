import { test } from "node:test";
import assert from "node:assert/strict";
import * as O from "../../app/static/onboarding-logic.js";

test("Erststart nur einmal, nicht ohne Abo, nicht in der Demo, nicht für bestehende Nutzer", () => {
  assert.equal(O.shouldShow({ done: false, modules: 0, hash: "" }), true);
  assert.equal(O.shouldShow({ done: false, modules: 0, hash: "#/dashboard" }), true);
  assert.equal(O.shouldShow({ done: true }), false);
  assert.equal(O.shouldShow({ locked: true }), false);
  assert.equal(O.shouldShow({ demo: true }), false);
  assert.equal(O.shouldShow({ modules: 3 }), false);
  assert.equal(O.shouldShow({ session: true }), false);
  assert.equal(O.shouldShow({ hash: "#/doc/x" }), false, "Direktlink geht vor");
  assert.equal(O.isDone({ onboarding_done: "1" }), true);
  assert.equal(O.isDone({}), false);
});

test("Schritte und Beschriftung wie auf dem iPad", () => {
  assert.deepEqual(O.STEPS.map(s => s.id), ["welcome", "university", "login", "plan"]);
  assert.equal(O.stepLabel(1), "Schritt 2 von 4: Hochschule");
});

test("Anmeldung je Hochschule und Ort", () => {
  assert.equal(O.loginStep("luh", false).title, "Bei Stud.IP anmelden");
  assert.equal(O.loginStep("hildesheim", false).title, "Beim Learnweb anmelden");
  assert.equal(O.loginStep("luh", true).title, "Hochschul-Zugang hinterlegen");
  assert.match(O.loginStep("hildesheim", true).intro, /UNI-Account/);
});

test("Hochschule Hannover: Moodle und Campusmanagement, nie Zugangsdaten", () => {
  assert.equal(O.loginStep("hsh", false).title, "Bei Moodle und im Campusmanagement anmelden");
  assert.match(O.loginStep("hsh", false).intro, /SSO-Account/);
  assert.doesNotMatch(O.loginStep("hsh", true).intro, /hinterlegst/);
  assert.match(O.loginStep("hsh", true).intro, /nie dein Passwort/);
});

test("Tarif-Schritt und Hochschulwechsel", () => {
  assert.equal(O.planInfo("trial", { access: { trial_days_left: 6 } }).title, "Probe: noch 6 Tage");
  assert.equal(O.planInfo("trial", { access: { trial_days_left: 1 } }).title, "Probe: noch 1 Tag");
  assert.equal(O.planInfo("active", { plan_name: "StudiNow Plus" }).title, "Dein Tarif: StudiNow Plus");
  assert.equal(O.planInfo("open", null).title, "Alles frei auf diesem PC");
  assert.equal(O.needsRestart("hildesheim", "luh", false), true);
  assert.equal(O.needsRestart("luh", "luh", false), false);
  assert.equal(O.needsRestart("hildesheim", "luh", true), false);
});

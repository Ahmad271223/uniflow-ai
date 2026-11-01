// Hinweis "Studora wurde aktualisiert" (app/static/sw-update.js): nur bei echtem Update, nie beim ersten Aufruf.
// Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { isWorkerUpdate, watchWorkerUpdate } from "../../app/static/sw-update.js";

/// Kleiner EventTarget-Ersatz fuer ServiceWorkerRegistration und ServiceWorker
function target(props = {}) {
  const t = new EventTarget();
  return Object.assign(t, props);
}

/// Spielt einen Worker-Wechsel durch: reg.active/controller vor dem Fund, dann installing -> installed -> activated
function run({ active = null, controller = null }) {
  const calls = [];
  const reg = target({ active, installing: null });
  const container = { controller };
  watchWorkerUpdate(reg, container, () => calls.push("aktualisiert"));
  const w = target({ state: "installing" });
  reg.installing = w;
  reg.dispatchEvent(new Event("updatefound"));
  for (const state of ["installed", "activated"]) {
    w.state = state;
    if (state === "activated") { reg.active = w; container.controller = w; }     // clients.claim() des neuen Workers
    w.dispatchEvent(new Event("statechange"));
  }
  return calls;
}

test("allererster Aufruf: kein aktiver Worker, keine Steuerung -> kein Hinweis", () => {
  assert.deepEqual(run({}), []);
});

test("echtes Update: ein Worker war schon aktiv und steuert die Seite -> genau ein Hinweis", () => {
  const alt = target({ state: "activated" });
  assert.deepEqual(run({ active: alt, controller: alt }), ["aktualisiert"]);
});

test("Update auch dann, wenn die Seite (z. B. nach Umschalt-Neuladen) nicht gesteuert war, aber ein Worker aktiv ist", () => {
  const alt = target({ state: "activated" });
  assert.deepEqual(run({ active: alt, controller: null }), ["aktualisiert"]);
});

test("Wartende Zwischenstaende melden nichts, nur 'activated'", () => {
  const alt = target({ state: "activated" });
  const calls = [];
  const reg = target({ active: alt, installing: null });
  watchWorkerUpdate(reg, { controller: alt }, () => calls.push(1));
  const w = target({ state: "installing" });
  reg.installing = w;
  reg.dispatchEvent(new Event("updatefound"));
  w.state = "installed"; w.dispatchEvent(new Event("statechange"));
  assert.equal(calls.length, 0);
  w.state = "redundant"; w.dispatchEvent(new Event("statechange"));
  assert.equal(calls.length, 0);
});

test("isWorkerUpdate: ohne Registrierung oder Container nie ein Update", () => {
  assert.equal(isWorkerUpdate(null, null), false);
  assert.equal(isWorkerUpdate({ active: null }, { controller: null }), false);
  assert.equal(isWorkerUpdate({ active: {} }, {}), true);
  assert.equal(isWorkerUpdate({}, { controller: {} }), true);
});

test("pwa.js bindet den Hinweis ueber sw-update.js ein, ohne eigene Pruefung auf controller", async () => {
  const { readFileSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
  const src = readFileSync(join(root, "app/static/pwa.js"), "utf8");
  assert.match(src, /from "\.\/sw-update\.js\?v=\d+"/);
  assert.match(src, /watchWorkerUpdate\(reg, navigator\.serviceWorker/);
  assert.doesNotMatch(src, /state === "activated" && navigator\.serviceWorker\.controller/);
});

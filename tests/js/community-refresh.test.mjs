// Community neu laden beim Zurueckkommen ins Fenster (app/static/community-refresh.js, Befund 5.5, 12.11.2026)
import { test } from "node:test";
import assert from "node:assert/strict";
import { REFRESH_MS, isCommunityHash, hasDraft, shouldRefresh, installCommunityRefresh } from "../../app/static/community-refresh.js";

const field = (value, defaultValue = "", type = "text") => ({ value, defaultValue, type });
const root = (...els) => ({ querySelectorAll: () => els });

test("nur Community-Seiten", () => {
  for (const h of ["#/community", "#/community?tab=questions", "#/community?space=abc", "#community"]) assert.ok(isCommunityHash(h), h);
  for (const h of ["", "#/dashboard", "#/doc/12", "#/communityx", "#/cards"]) assert.ok(!isCommunityHash(h), h);
});

test("angefangener Text verhindert das Neuladen", () => {
  assert.equal(hasDraft(root(field(""), field("  "))), false);
  assert.equal(hasDraft(root(field("Meine Antwort"))), true);
  assert.equal(hasDraft(root(field("vorbelegt", "vorbelegt"))), false, "unveraenderter Ausgangswert ist kein Entwurf");
  assert.equal(hasDraft(root(field("on", "", "checkbox"), field("x", "", "hidden"))), false);
  assert.equal(hasDraft(null), false);
});

test("hoechstens einmal je Minute, nie versteckt, nie mit Dialog", () => {
  const base = { hash: "#/community", hidden: false, now: 10 * REFRESH_MS, shownAt: 0, draft: false, modalOpen: false };
  assert.equal(shouldRefresh(base), true);
  assert.equal(shouldRefresh({ ...base, shownAt: base.now - REFRESH_MS + 1 }), false);
  assert.equal(shouldRefresh({ ...base, hidden: true }), false);
  assert.equal(shouldRefresh({ ...base, draft: true }), false);
  assert.equal(shouldRefresh({ ...base, modalOpen: true }), false);
  assert.equal(shouldRefresh({ ...base, hash: "#/files" }), false);
});

test("Einbau: Zurueckkommen zeichnet neu und behaelt die Scroll-Stelle", async () => {
  let t = 0, routed = 0, scrolled = null;
  const handlers = {};
  const on = (name, fn) => { (handlers[name] ||= []).push(fn); };
  const doc = { hidden: false, querySelector: () => null, addEventListener: on };
  const win = { location: { hash: "#/community" }, scrollY: 420, scrollTo: (_, y) => { scrolled = y; }, addEventListener: on };
  let view = root();
  const r = installCommunityRefresh({ route: async () => { routed++; }, view: () => view, doc, win, now: () => t });
  assert.equal(await r.check(), false, "gerade erst gezeigt");
  t = REFRESH_MS;
  assert.equal(await r.check(), true);
  assert.equal(routed, 1); assert.equal(scrolled, 420);
  assert.equal(await r.check(), false, "nicht gleich noch einmal (focus und visibilitychange kommen zusammen)");
  t = 3 * REFRESH_MS; view = root(field("Halbe Frage"));
  assert.equal(await r.check(), false, "Entwurf bleibt stehen");
  view = root(); doc.hidden = true;
  assert.equal(await r.check(), false);
  doc.hidden = false; win.location.hash = "#/files";
  assert.equal(await r.check(), false);
  assert.ok(handlers.visibilitychange?.length && handlers.focus?.length && handlers.hashchange?.length);
});

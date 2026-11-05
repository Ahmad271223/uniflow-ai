import { test } from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/invites-logic.js";

test("ohne Entscheidung des Inhabers keine Belohnungen im Web", () => {
  assert.equal(L.WEB_REWARDS, false);
  assert.match(L.REWARDS_NOTE, /noch nicht entschieden/);
});

test("Zähler und Zeilen je Link", () => {
  assert.equal(L.arrivedLine(0), "Noch niemand ist über deine Links angekommen.");
  assert.equal(L.arrivedLine(1), "1 Person ist über deine Links angekommen.");
  assert.equal(L.arrivedLine(7), "7 Personen sind über deine Links angekommen.");
  assert.equal(L.linkStatus({ expires_at: "2026-12-05T10:00:00", redemptions: 2 }), "gültig bis 05.12.2026 · 2 angekommen");
  assert.equal(L.linkStatus({ expired: true, redemptions: 0 }), "abgelaufen");
});

test("Hinweis zum Anlegen", () => {
  assert.equal(L.createHint({ can_create: true, create_until: "2026-11-12T00:00:00", remaining_links: 18, max_links: 20 }), "Neue Links kannst du bis 12.11.2026 anlegen (noch 18 von 20).");
  assert.equal(L.createHint({ can_create: false, remaining_links: 0, max_links: 20 }), "Du hast alle 20 Einladungslinks angelegt.");
  assert.match(L.createHint({ can_create: false, remaining_links: 5 }), /ersten 7 Tagen/);
});

test("Reihenfolge, Teilen, App-Code, Fehler", () => {
  const s = L.sortedCodes([{ code: "A", created_at: "2026-11-01", expired: true }, { code: "B", created_at: "2026-11-02" }, { code: "C", created_at: "2026-11-03" }]);
  assert.deepEqual(s.map(c => c.code), ["C", "B", "A"]);
  assert.equal(L.appCode("ABCDEFGHJK"), "uniflow://invite/ABCDEFGHJK");
  assert.match(L.shareText("https://studinow.app/i/X"), /https:\/\/studinow\.app\/i\/X$/);
  assert.equal(L.errorState({ code: "not_hosted" }).noAccount, true);
  assert.equal(L.errorState({ code: "not_linked" }).noAccount, true);
  assert.equal(L.errorState({ code: "x", message: "Kaputt" }).text, "Kaputt");
});

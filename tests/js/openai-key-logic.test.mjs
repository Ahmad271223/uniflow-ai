import { test } from "node:test";
import assert from "node:assert/strict";
import * as K from "../../app/static/openai-key-logic.js";

test("Schluessel-Form wie OpenAIKeyRules auf dem iPad", () => {
  assert.equal(K.normalizeKey("  sk-abcdefghijklmnopqrstuvwxyz  "), "sk-abcdefghijklmnopqrstuvwxyz");
  assert.equal(K.normalizeKey("abcdefghijklmnopqrstuvwxyz"), null, "ohne sk-");
  assert.equal(K.normalizeKey("sk-kurz"), null, "zu kurz");
  assert.equal(K.normalizeKey("sk-abc defghijklmnopqrstuvwxyz"), null, "Leerzeichen innen");
  assert.equal(K.normalizeKey("sk-" + "a".repeat(398)), null, "zu lang");
  assert.equal(K.normalizeKey("sk-äbcdefghijklmnopqrstuvwxyz"), null, "kein ASCII");
  assert.equal(K.maskKey("sk-abcdefghijklmnop1234"), "sk-…1234");
  assert.equal(K.maskKey(""), "");
});

test("Badge und Speichern-Regel", () => {
  assert.deepEqual(K.badge(null), { cls: "neutral", text: "nur in der Windows-App" });
  assert.deepEqual(K.badge({ available: true, has_key: false }), { cls: "neutral", text: "kein Schlüssel" });
  assert.deepEqual(K.badge({ available: true, has_key: true, last_error: "401" }), { cls: "warn", text: "Prüfung fehlgeschlagen" });
  assert.deepEqual(K.badge({ available: true, has_key: true, use_for_ai: true, model: "gpt-4o-mini", checked: true }), { cls: "ok", text: "aktiv · geprüft" });
  assert.equal(K.saveProblem("sk-abcdefghijklmnopqrstuvwxyz", true), null);
  assert.match(K.saveProblem("sk-abcdefghijklmnopqrstuvwxyz", false), /stimme zuerst zu/);
  assert.match(K.saveProblem("nix", true), /beginnt mit „sk-“/);
});

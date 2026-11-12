// Zeile "Eigene Dokumente" in der Konto-Karte der Windows-App (app/static/studora-link.js, app/own_docs_sync.py, 12.11.2026)
import { test } from "node:test";
import assert from "node:assert/strict";
import { ownDocsLine } from "../../app/static/studora-link.js";

test("ohne Lauf, mit Fehler oder ohne Recht: keine Zeile", () => {
  for (const l of [null, undefined, { ok: false, error: "x" }, { ok: true }, { ok: true, own_documents: "plan_required" }]) assert.equal(ownDocsLine(l), "", JSON.stringify(l));
});

test("aelterer Dienst: ehrlicher Hinweis statt Erfolg", () => {
  assert.match(ownDocsLine({ ok: true, own_documents: "unavailable" }), /kann das noch nicht/);
});

test("Zahlen, zu grosse Dateien und Fehler stehen da, Namen werden maskiert", () => {
  const html = ownDocsLine({ ok: true, own_documents: "ok", own_up: 2, own_down: 1, own_deleted: 1, assets_up: 1, assets_down: 2,
    own_skipped: ["<b>Riesig</b>"], errors: ["Speicher voll", "noch einer"] });
  assert.match(html, /2 hochgeladen, 1 geholt, 1 gelöscht, 3 Bilder/);
  assert.match(html, /&lt;b&gt;Riesig&lt;\/b&gt;/);
  assert.ok(!html.includes("<b>Riesig"));
  assert.match(html, /Speicher voll \(\+1\)/);
  assert.match(ownDocsLine({ ok: true, own_documents: "ok" }), /alles aktuell/);
});

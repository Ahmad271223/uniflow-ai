// Einwilligung vor der StudiNow-KI in Web und Windows (app/static/ai-consent-logic.js, Server app/ai_consent.py,
// 06.11.2026): 428 ai_consent_required zeigt den Hinweis einmal, Zustimmen speichert und wiederholt die Anfrage,
// Abbrechen schickt nichts und laesst einen verstaendlichen Fehler, gleichzeitige Anfragen teilen sich einen Hinweis.
// Gegenstueck zu AIConsentAppTests.swift auf dem iPad. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../../app/static/ai-consent-logic.js";

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const consentBody = { detail: "Bitte stimme zuerst zu …", code: "ai_consent_required", version: "2026-11-06", consent: { title: "KI-Hilfe: Was wird gesendet?" } };

/** Schein-Server: ohne Einwilligung 428, danach die Antwort */
function server() {
  const s = { granted: false, calls: [] };
  s.fetch = async (url, init) => {
    s.calls.push(String(url));
    if (!s.granted) return json(428, consentBody);
    return json(200, { answer: "Erklärung", url: String(url), body: init?.body ?? null });
  };
  return s;
}

test("needsConsent erkennt den Code oben und in detail, sonst nicht", () => {
  assert.equal(L.needsConsent(428, consentBody), true);
  assert.equal(L.needsConsent(428, { detail: { code: "ai_consent_required" } }), true);
  assert.equal(L.needsConsent(403, consentBody), false);
  assert.equal(L.needsConsent(428, { code: "andere" }), false);
  assert.equal(L.needsConsent(428, null), false);
  assert.deepEqual(L.consentInfo(consentBody), { version: "2026-11-06", text: { title: "KI-Hilfe: Was wird gesendet?" } });
});

test("Zustimmen: Hinweis einmal, speichern mit Stand, Anfrage einmal neu mit demselben Rumpf", async () => {
  const s = server();
  let asked = 0, granted = [];
  const f = L.withConsent(s.fetch, { ask: async info => { asked++; assert.equal(info.text.title, "KI-Hilfe: Was wird gesendet?"); return true; },
                                     grant: async v => { granted.push(v); s.granted = true; } });
  const r = await f("/api/ai/tutor", { method: "POST", body: '{"mode":"explain"}' });
  assert.equal(r.status, 200);
  const d = await r.json();
  assert.equal(d.body, '{"mode":"explain"}');
  assert.equal(asked, 1);
  assert.deepEqual(granted, ["2026-11-06"]);
  assert.deepEqual(s.calls, ["/api/ai/tutor", "/api/ai/tutor"]);
  const again = await f("/api/ai/tutor", { method: "POST", body: "{}" });
  assert.equal(again.status, 200);
  assert.equal(asked, 1, "danach nicht mehr gefragt");
});

test("Abbrechen: nichts gespeichert, kein zweiter Versuch, Fehler mit Text; beim naechsten Mal wieder gefragt", async () => {
  const s = server();
  let asked = 0, granted = 0;
  const f = L.withConsent(s.fetch, { ask: async () => { asked++; return false; }, grant: async () => { granted++; } });
  const r = await f("/api/ai/document/step", { method: "POST", body: "{}" });
  assert.equal(r.status, 428);
  const d = await r.json();
  assert.equal(d.code, "ai_consent_required");
  assert.equal(d.detail, L.DECLINED);
  assert.equal(granted, 0);
  assert.deepEqual(s.calls, ["/api/ai/document/step"], "nicht wiederholt");
  await f("/api/ai/document/step", { method: "POST", body: "{}" });
  assert.equal(asked, 2);
});

test("gleichzeitige Anfragen teilen sich einen Hinweis", async () => {
  const s = server();
  let asked = 0, release;
  const gate = new Promise(r => { release = r; });
  const f = L.withConsent(s.fetch, { ask: async () => { asked++; await gate; return true; }, grant: async () => { s.granted = true; } });
  const a = f("/api/ai/tutor", {}), b = f("/api/flashcards/generate", {});
  await new Promise(r => setTimeout(r, 10));
  release();
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ra.status, 200);
  assert.equal(rb.status, 200);
  assert.equal(asked, 1);
});

test("andere Antworten bleiben unberuehrt (auch 428 ohne den Code, Fehler beim Speichern = Abbrechen)", async () => {
  const other = L.withConsent(async () => json(428, { code: "x" }), { ask: async () => { throw new Error("nie"); }, grant: async () => {} });
  assert.equal((await (await other("/api/x")).json()).code, "x");
  const ok = L.withConsent(async () => json(200, { a: 1 }), { ask: async () => { throw new Error("nie"); }, grant: async () => {} });
  assert.equal((await ok("/api/y")).status, 200);
  const s = server();
  const failing = L.withConsent(s.fetch, { ask: async () => true, grant: async () => { throw new Error("offline"); } });
  const r = await failing("/api/ai/tutor", {});
  assert.equal(r.status, 428);
  assert.equal((await r.json()).detail, L.DECLINED);
});

test("Oberflaeche: Hilfe beim Start installiert, Karte in Einstellungen → Erweitert mit Widerruf", () => {
  const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
  const app = read("app.js"), misc = read("views-misc.js"), ui = read("ai-consent.js");
  assert.match(app, /installConsentFetch\(\);/);
  assert.match(misc, /consentCardHtml\(aiConsent\)/);
  assert.match(misc, /api\("\/ai\/consent", \{ method: "DELETE" \}\)/);
  assert.match(ui, /data-consent="yes"/);
  assert.match(ui, /Zustimmen und fortfahren/);
  assert.match(ui, /\/api\/ai\/consent/);
});

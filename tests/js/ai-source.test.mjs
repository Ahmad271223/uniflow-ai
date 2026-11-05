// KI am PC ueber das StudiNow-Konto (05.11.2026, app/ai_relay.py): Weg der KI und Credits vor der ersten Antwort,
// Tarif-Hinweis bei 402/403/429, eigene Notizen neben der Folie als `own_notes`, Modul als Kontext auf KI-Start.
import test from "node:test";
import assert from "node:assert/strict";
import * as P from "../../app/static/ai-panel.js";
import * as L from "../../app/static/ai-start-logic.js";
import * as SN from "../../app/static/side-notes.js";

const credits = { period: "2026-11", allowance: 100, used: 8, reserved: 0, remaining: 92, resets_at: "2026-12-01T00:00:00+01:00", plan: "pro_ai" };

test("Weg der KI vor der ersten Antwort", () => {
  assert.equal(P.sourceLine(null), "");
  assert.equal(P.sourceLine({ source: "chatgpt" }), "über dein ChatGPT · 0 Credits");
  assert.equal(P.sourceLine({ source: "studinow", credits }), "Credits: 92 von 100 übrig · neu am 1. Dezember");
  assert.equal(P.sourceLine({ source: "studinow", credits: null }), "StudiNow-KI · mit Credits");
  assert.equal(P.sourceLine({ source: "none" }), "Keine KI verbunden");
  assert.equal(P.footerLine(3, null, null, { source: "studinow", credits }), "Seite 3 · Credits: 92 von 100 übrig · neu am 1. Dezember");
  // nach einer Antwort zaehlt deren Stand
  assert.equal(P.footerLine(3, { ...credits, charged: 8, remaining: 84 }, null, { source: "studinow", credits }), "Seite 3 · – 8 Credits (84 übrig)");
  assert.equal(P.footerLine(3, null, { stored: true, source: "cloud" }, { source: "studinow", credits }), "Seite 3 · Schon erklärt · 0 Credits");
  assert.equal(L.statusLine(2, null, null, { source: "chatgpt" }), "2 Anfragen diesen Monat · über dein ChatGPT · 0 Credits");
});

test("Tarif-Hinweis bei Credits, Kontingent, Tarif und Abo", () => {
  for (const c of ["credits_exhausted", "quota_exhausted", "plan_required", "subscription_required", "subscription_unverified"]) assert.ok(P.needsPlan(c), c);
  for (const c of ["email_unverified", "account_required", "service_unreachable", null]) assert.ok(!P.needsPlan(c), c);
});

test("Notizseiten einer Folie gehen als own_notes mit", () => {
  const doc = {
    pageOrder: [{ key: "p1", type: "pdf", index: 1 }, { key: "b1", type: "blank" }, { key: "sn-s1", type: "blank", sideOf: "p1" },
      { key: "p2", type: "pdf", index: 2 }, { key: "p3", type: "pdf", index: 3 }, { key: "b3", type: "blank" }],
    pages: {
      b1: { objects: [{ type: "text", text: "  Merke: λ ist Eigenwert " }, { type: "stroke", points: [] }, { type: "text", text: " " }] },
      "sn-s1": { objects: [{ type: "stroke", points: [], recognizedText: "det(A - λI) = 0" }] },
      b3: { objects: [{ type: "text", text: "x".repeat(5000) }] },
    },
  };
  assert.deepEqual(SN.notePages(doc, "p1"), ["b1", "sn-s1"]);
  assert.deepEqual(SN.notePages(doc, "p2"), []);
  assert.equal(P.notesText(doc, SN.notePages(doc, "p1")), "Merke: λ ist Eigenwert\ndet(A - λI) = 0", "Handschrift nur mit erkanntem Text");
  assert.equal(P.notesText(doc, SN.notePages(doc, "p3")).length, P.OWN_NOTES_CHARS);
  assert.equal(P.OWN_NOTES_CHARS, SN.AI_NOTES_CHARS);
  assert.equal(P.notesText(doc, []), "");
});

test("KI-Start: Modul als Kontext, Dokument geht vor", () => {
  assert.equal(L.requestBody({ question: "Was ist ein Eigenwert?", moduleId: 7 }).module_id, 7);
  const b = L.requestBody({ question: "x", moduleId: 7, fileId: "f1" });
  assert.equal(b.file_id, "f1"); assert.equal(b.module_id, undefined);
});

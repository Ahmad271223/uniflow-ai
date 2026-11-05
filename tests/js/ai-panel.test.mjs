// KI-Hilfe im Editor mit drei farbigen Reitern (app/static/ai-panel.js, 05.11.2026): dieselben Regeln wie TutorPanel.swift
// (Reiter und Modi, Anschlussfragen, "Schon erklaert", Kostenzeile), ohne Browser.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  TABS, MODE_LABELS, tabOf, tabClass, userLabel, followUps, storedLabel, offersRebuild, resetLabel, creditsLine, footerLine, historyFor,
  showsFollowUps, errorText, errorCode, sourceLinks, panelHtml, emptyHtml, HISTORY_TURNS,
} from "../../app/static/ai-panel.js";

const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
const icon = (n, s) => `<svg data-i="${n}" data-s="${s}"></svg>`;
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

test("drei Reiter in der Reihenfolge Erklaeren, Karteikarten, Test; jeder Modus ausser der freien Frage gehoert genau einem", () => {
  assert.deepEqual(TABS.map(t => t.id), ["explain", "cards", "test"]);
  assert.deepEqual(TABS.map(t => t.title), ["Erklären", "Karteikarten", "Test"]);
  const py = read("../ai.py").match(/TUTOR_MODES = \{([\s\S]*?)\n\}/)[1];
  const serverModes = [...py.matchAll(/^\s+"(\w+)":/gm)].map(m => m[1]);
  assert.ok(serverModes.includes("ask") && serverModes.length === 10, `Modi des Dienstes: ${serverModes}`);
  for (const m of serverModes) {
    assert.ok(MODE_LABELS[m], `Name fuer ${m}`);
    const n = TABS.filter(t => t.modes.includes(m)).length;
    assert.equal(n, m === "ask" ? 0 : 1, `${m} liegt in ${n} Reitern`);
  }
  assert.equal(tabOf("flashcards"), "cards"); assert.equal(tabOf("check"), "test"); assert.equal(tabOf("ask"), null);
  assert.equal(tabClass("quiz"), "test"); assert.equal(tabClass("ask"), "explain");
});

test("Beschriftung im Verlauf wie auf dem iPad", () => {
  assert.equal(userLabel("ask", "  Was ist ein Eigenwert? "), "Was ist ein Eigenwert?");
  assert.equal(userLabel("explain"), "Erklären");
  assert.equal(userLabel("explain", "", true), "Erklären (neu)");
  assert.equal(userLabel("steps", "Aufgabe 2"), "Aufgabe lösen: Aufgabe 2");
  assert.equal(userLabel("check", "x = 3"), "Lösung prüfen:\nx = 3");
});

test("Anschlussfragen: nur bekannte Modi, Karteikarten haben keine", () => {
  for (const m of [...Object.keys(MODE_LABELS), "unbekannt"]) {
    for (const [label, mode, question] of followUps(m)) {
      assert.ok(label && MODE_LABELS[mode], `${m}: ${label} -> ${mode}`);
      if (mode === "ask") assert.ok(question, "freie Frage braucht einen Text");
    }
  }
  assert.deepEqual(followUps("flashcards"), []);
  assert.deepEqual(followUps("explain").map(f => f[1]), ["explain_simple", "ask", "terms"]);
  assert.equal(followUps("whatever").length, 3, "Rueckfall wie default");
});

test("Erklaerungsspeicher: ehrliche Beschriftung und 'Neu erklaeren lassen'", () => {
  assert.equal(storedLabel({ stored: true, source: "cloud", variant: 1 }), "Schon erklärt · sofort da · 0 Credits");
  assert.equal(storedLabel({ stored: true, source: "local", variant: 1 }), "Schon erklärt · 0 Credits");
  assert.equal(storedLabel({ stored: false, variant: 2, shared: false }), null);
  assert.equal(storedLabel(null), null);
  assert.equal(offersRebuild({ stored: true, source: "local" }), true);
  assert.equal(offersRebuild({ stored: false }), false); assert.equal(offersRebuild(undefined), false);
});

test("Kostenzeile: gespeichert, Wiederholung, berechnet, Stand; am eigenen PC leer", () => {
  assert.equal(creditsLine(null, { stored: true, source: "local" }), "Schon erklärt · 0 Credits");
  assert.equal(creditsLine({ replay: true, charged: 0 }, null), "Schon berechnet · 0 Credits");
  assert.equal(creditsLine({ charged: 3, remaining: 37 }, null), "– 3 Credits (37 übrig)");
  assert.equal(creditsLine({ charged: 1, remaining: 9 }, null), "– 1 Credit (9 übrig)");
  assert.equal(creditsLine({ charged: 0, remaining: 37, allowance: 100, resets_at: "2026-12-01T00:00:00+01:00" }, null), "Credits: 37 von 100 übrig · neu am 1. Dezember");
  assert.equal(creditsLine({ charged: 0, remaining: 0, allowance: 0 }, null), "Keine Credits in deinem Tarif");
  assert.equal(creditsLine(null, null), "");
  assert.equal(resetLabel("quatsch"), null); assert.equal(resetLabel("2026-13-01"), null);
  assert.equal(footerLine(3, null, null), "Seite 3");
  assert.equal(footerLine(3, { charged: 2, remaining: 8 }, null), "Seite 3 · – 2 Credits (8 übrig)");
  assert.equal(footerLine(4, null, { stored: true, source: "cloud" }), "Seite 4 · Schon erklärt · 0 Credits");
});

test("history: die letzten Beitraege, Karten als Text; Anschlussfragen nur unter der letzten Antwort", () => {
  const ms = Array.from({ length: 10 }, (_, i) => i % 2 === 0 ? { fromUser: true, text: `F${i}` } : { fromUser: false, text: `A${i}` });
  const h = historyFor(ms);
  assert.equal(h.length, HISTORY_TURNS); assert.deepEqual(h[0], { role: "user", text: "F4" }); assert.equal(h.at(-1).role, "assistant");
  assert.deepEqual(historyFor([{ fromUser: false, text: "ignoriert", cards: [{ question: "Q", answer: "A" }] }]), [{ role: "assistant", text: "Q – A" }]);
  assert.equal(showsFollowUps(9, ms), true); assert.equal(showsFollowUps(7, ms), false); assert.equal(showsFollowUps(8, ms), false); assert.equal(showsFollowUps(99, ms), false);
  assert.equal(showsFollowUps(1, [{ fromUser: true }, { fromUser: false }, { fromUser: true }]), true, "die Frage danach nimmt es nicht weg");
});

test("Fehlertexte vom Dienst: Text oder {detail, code}", () => {
  assert.equal(errorText({ detail: "Kaputt" }), "Kaputt");
  assert.equal(errorText({ detail: { detail: "Credits weg", code: "credits_exhausted" } }), "Credits weg");
  assert.equal(errorText({}, "Fallback"), "Fallback");
  assert.equal(errorCode({ code: "credits_exhausted" }), "credits_exhausted"); assert.equal(errorCode({ detail: { code: "x" } }), "x"); assert.equal(errorCode(null), null);
});

test("Quellen: [n] wird zum Link, darunter die genannten", () => {
  const html = sourceLinks("<p>Siehe [1] und [7].</p>", [{ n: 1, cited: true, title: "Folien <b>", page: 4 }, { n: 2, cited: false, current: true, name: "Blatt", page: 2 }], esc);
  assert.match(html, /<a href="#" class="ed-src" data-src="1">\[1\]<\/a>/);
  assert.ok(html.includes("[7]") && !html.includes('data-src="7"'), "unbekannte Marke bleibt Text");
  assert.ok(html.includes("Folien &lt;b&gt;, Seite 4") && html.includes("(diese Seite)"));
  assert.equal(sourceLinks("<p>x</p>", [], esc), "<p>x</p>");
});

test("Leiste: Reiter mit Rollen, Knoepfe aller Modi, KI-Start, Wochentest, Eingabe unten", () => {
  const h = panelHtml(icon, esc);
  assert.equal((h.match(/role="tab"/g) || []).length, 3);
  assert.equal((h.match(/role="tabpanel"/g) || []).length, 3);
  assert.match(h, /class="ed-ai-tab t-explain on"[^>]*aria-selected="true"/);
  assert.match(h, /href="#\/ki"/); assert.match(h, /href="#\/exams"[^>]*>[\s\S]*Wochentest erstellen/);
  for (const m of [...TABS.flatMap(t => t.modes), "quiz"]) assert.match(h, new RegExp(`data-mode="${m}"`), `Knopf fuer ${m}`);
  assert.match(h, /data-doc="lecture"/); assert.match(h, /data-doc="tasks"/); assert.match(h, /class="ed-ai-scope"/);
  assert.match(h, /<form class="ed-ai-form"/); assert.ok(h.indexOf("ed-ai-out") < h.indexOf("ed-ai-form"), "Verlauf oben, Eingabe unten");
  assert.match(h, /aria-label="Frage an die KI"/); assert.match(h, /aria-live="polite"/);
  assert.match(emptyHtml(icon), /Frag etwas zur offenen Seite/);
  assert.ok(!/KI-Tutor/.test(h), "heisst jetzt KI-Hilfe");
});

test("editor.js haengt die Leiste ein: leeres Geruest, createAiPanel, Doku-Lauf als Beitrag im Gespraech, Karteikarte", () => {
  const ed = read("editor.js");
  assert.match(ed, /from "\.\/ai-panel\.js\?v=\d+"/); assert.match(ed, /from "\.\/editor-card\.js\?v=\d+"/);
  assert.match(ed, /<aside class="ed-ai" hidden[^>]*><\/aside>/);
  assert.match(ed, /this\.ai = createAiPanel\(this,/);
  assert.match(ed, /askAI\(mode = "ask", opts = \{\}\) \{ return this\.ai\.ask\(mode, opts\); \}/);
  assert.match(ed, /out = this\.ai\.turn\(/);
  assert.match(ed, /data-mk="card"/); assert.match(ed, /openCardDialog\(/);
  assert.match(ed, /this\.ai\.sendSelection\(text\)/);
  assert.ok(!ed.includes("ed-ai-own"), "kein getrenntes Feld 'Meine Lösung' mehr");
});

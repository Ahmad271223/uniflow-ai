// Abgeben in Moodle (HsH) bzw. im Learnweb (Uni Hildesheim) am PC und Moodle-Nachrichten: reine Regeln und Texte
// (app/static/moodle-submit-logic.js, messages-logic.js, message-reply-logic.js; Server: app/moodle.py, app/moodle_api.py).
import { test } from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/moodle-submit-logic.js";
import * as M from "../../app/static/messages-logic.js";
import * as R from "../../app/static/message-reply-logic.js";

test("Texte je Quelle: Moodle (HsH) und Learnweb (Hildesheim)", () => {
  assert.equal(L.texts("Moodle").title, "In Moodle abgeben");
  assert.equal(L.texts("Learnweb").title, "In Learnweb abgeben");
  assert.match(L.texts("Moodle").notice, /Abgegeben ist sie erst mit „Jetzt abgeben“/);
  assert.match(L.texts("Learnweb").empty, /Keine Learnweb-Aufgabe/);
});

test("Aufgabenliste und Stand", () => {
  const html = L.assignmentOptions([{ cmid: 7001, title: "Übungsblatt 3", course: "Programmieren 1", due_at: "2026-11-12T23:59" }], 7001);
  assert.match(html, /<option value="7001" selected>Übungsblatt 3 · Programmieren 1 · fällig 12\.11\.2026, 23:59<\/option>/);
  assert.equal(L.dueText("2026-11-12"), "12.11.2026");
  const st = L.statusHtml({ state: "Entwurf gespeichert", grading: "Nicht bewertet", attempt: null, has_feedback: true }, L.texts("Moodle"));
  assert.match(st, /Abgabestatus<\/dt><dd>Entwurf gespeichert/);
  assert.ok(!st.includes("Versuch"), "leere Zeilen fehlen");
  assert.match(st, /Feedback vorhanden – in Moodle ansehen\./);
});

test("Entwurf erst mit Aufgabe, Name und PDF; Jetzt abgeben erst nach Bestaetigung und Erklaerung", () => {
  const pdf = { bytes: new Uint8Array(4), pages: 2 };
  const status = { state: "keine Abgabe", can_edit: true };
  assert.equal(L.canDraft({ status, name: "Mueller_Blatt3", pdf }), true);
  assert.equal(L.canDraft({ status: { ...status, can_edit: false }, name: "x", pdf }), false);
  assert.equal(L.canDraft({ status, name: "  ", pdf }), false);
  assert.equal(L.canDraft({ status, name: "x", pdf: null }), false);
  assert.equal(L.canDraft({ status, name: "x", pdf, busy: true }), false);
  const draft = { state: "Entwurf gespeichert", can_submit: true };
  assert.equal(L.canSubmit({ status: draft, confirm: null }), false, "ohne gelesene Bestaetigung nie");
  assert.equal(L.canSubmit({ status: draft, confirm: { statement: "Eigene Leistung" }, accepted: false }), false);
  assert.equal(L.canSubmit({ status: draft, confirm: { statement: "Eigene Leistung" }, accepted: true }), true);
  assert.equal(L.canSubmit({ status: draft, confirm: { statement: null } }), true);
  assert.equal(L.canSubmit({ status: { state: "Abgegeben" }, confirm: { statement: null } }), false, "nicht doppelt");
  assert.equal(L.needsLogin("moodle_login"), true);
});

test("Moodle-Nachrichten der HsH: eigene Texte, Ausweg und Anmeldung", () => {
  const m = { id: "moodle-12-345", source: "moodle" };
  assert.equal(M.isMoodle(m), true);
  assert.equal(M.isLearnweb(m), false);
  assert.equal(M.sourceTexts(m).open, "In Moodle öffnen");
  assert.match(M.sourceTexts(m).privacy, /in Moodle nicht als gelesen/);
  assert.equal(M.sourceName("moodle"), "Moodle");
  assert.equal(M.sourceName("learnweb"), "das Learnweb");
  assert.equal(R.webFallbackLabel("moodle-12-345"), "In Moodle antworten");
  assert.equal(R.replyChannel("moodle-12-345"), "Antworten gehen über Moodle unter deinem Namen.");
  assert.equal(R.needsLogin("moodle_login"), true);
  assert.equal(R.offersWebFallback("moodle_login"), false);
  assert.equal(R.webFallbackLabel("lw-msg-1-2"), "Im Learnweb antworten");
});

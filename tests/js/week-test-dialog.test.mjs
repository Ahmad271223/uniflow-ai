// Dialog "Wochentest erstellen" (app/static/week-test-dialog.js, 05.11.2026) und Testergebnis/Testlauf mit Wahr/Falsch und
// Lueckentext (app/static/test-result.js), ohne Browser: dieselben Faelle wie QuizSettings / WeekTestOptionsTests auf dem iPad.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as W from "../../app/static/week-test-dialog.js";
import * as TR from "../../app/static/test-result.js";

const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Standardeinstellung: 15 Aufgaben, beliebig, alle Arten, kein Thema = gemeinsamer Test moeglich", () => {
  const s = W.defaultSettings();
  assert.deepEqual(s, { count: 15, difficulty: "beliebig", types: ["mc", "tf", "cloze", "short", "calc"], topic: "" });
  assert.equal(W.isStandard(s), true); assert.equal(W.shareBadge(s), "Gemeinsamer Test möglich");
  for (const change of [{ count: 10 }, { difficulty: "schwer" }, { types: ["mc", "tf"] }, { topic: "Kapitel 3" }]) {
    const t = { ...s, ...change };
    assert.equal(W.isStandard(t), false, JSON.stringify(change)); assert.equal(W.shareBadge(t), "Eigener Test, nicht geteilt");
    assert.match(W.shareNote(t), /nur für dich/); assert.match(W.costLine(t), /eigener Test$/);
  }
  assert.equal(W.isStandard({ ...s, topic: "   " }), true, "Leerraum ist kein Thema");
  assert.match(W.shareNote(s), /höchstens 3 Varianten/); assert.match(W.costLine(s), /0 Credits/);
});

test("Verteilung wie im Dienst (ai.week_test_distribution): 5 -> 1/2/2, 10 -> 3/4/3, 15 -> 4/6/5, 20 -> 5/8/7", () => {
  assert.deepEqual(Object.values(W.distribution(5, "beliebig")), [1, 2, 2]);
  assert.deepEqual(Object.values(W.distribution(10, "beliebig")), [3, 4, 3]);
  assert.deepEqual(Object.values(W.distribution(15, "beliebig")), [4, 6, 5]);
  assert.deepEqual(Object.values(W.distribution(20, "beliebig")), [5, 8, 7]);
  assert.deepEqual(W.distribution(10, "schwer"), { leicht: 0, mittel: 0, schwer: 10 });
  assert.equal(W.composition(W.defaultSettings()), "15 Aufgaben · 4 leicht · 6 mittel · 5 schwer");
  assert.equal(W.composition({ ...W.defaultSettings(), count: 10, difficulty: "schwer" }), "10 Aufgaben · alle schwer");
});

test("Aufgabenarten: mindestens eine bleibt an, Reihenfolge wie im Dienst", () => {
  let t = W.ALL_TYPES;
  t = W.toggleType(t, "tf"); assert.deepEqual(t, ["mc", "cloze", "short", "calc"]);
  t = W.toggleType(t, "tf"); assert.deepEqual(t, ["mc", "tf", "cloze", "short", "calc"], "wieder an: an der richtigen Stelle");
  assert.deepEqual(W.toggleType(["calc"], "calc"), ["calc"], "die letzte bleibt");
  assert.deepEqual(W.toggleType(["calc"], "mc"), ["mc", "calc"]);
});

test("Rumpf fuer POST /api/tests/generate: nur gewaehlte Woche, Thema gekuerzt, Arten in Reihenfolge", () => {
  const s = { count: 10, difficulty: "mittel", types: ["cloze", "mc"], topic: "  nur Kapitel 3  " };
  assert.deepEqual(W.body({ moduleId: "4", duration: "45", week: 0, settings: s }),
    { module_id: 4, duration_min: 45, count: 10, difficulty: "mittel", types: ["mc", "cloze"], topic: "nur Kapitel 3" });
  assert.equal(W.body({ moduleId: 4, duration: 30, week: 3, settings: s }).week_no, 3);
  assert.equal(W.body({ moduleId: 4, duration: 30, week: 0, settings: { ...s, topic: "x".repeat(500) } }).topic.length, W.TOPIC_CHARS);
});

test("Lehrwochen mit Unterlagen, neueste zuerst; Unterlagen hoechstens zehn", () => {
  const detail = { weeks: [{ week: 0, vorlesungen: [{ id: 1 }] }, { week: 1, label: "Woche 1", vorlesungen: [{ id: 2 }] }, { week: 2, vorlesungen: [] }, { week: 3, topic: "Reihen", uebungen: [{ id: 3 }], loesungen: [{ id: 4 }] }] };
  assert.deepEqual(W.weeksOf(detail).map(w => w.week), [3, 1]);
  assert.equal(W.weekLabel(W.weeksOf(detail)[0]), "Lehrwoche 3 · Reihen"); assert.equal(W.weekLabel({ week: 1, label: "Woche 1" }), "Woche 1");
  assert.deepEqual(W.materialsOf(W.weeksOf(detail)[0]).map(f => f.id), [3, 4]);
  assert.equal(W.materialsOf({ vorlesungen: Array.from({ length: 12 }, (_, i) => ({ id: i })) }).length, 10);
  assert.deepEqual(W.weeksOf(null), []);
  assert.equal(W.docLabel("loesung"), "Lösung"); assert.equal(W.docLabel("x"), "Unterlage");
});

test("Hash #/exams?neu=<Modul> oeffnet den Dialog", () => {
  assert.deepEqual(W.wantsDialog({ neu: "4" }), { moduleId: 4 }); assert.deepEqual(W.wantsDialog({ neu: "" }), { moduleId: 0 });
  assert.equal(W.wantsDialog({}), null); assert.equal(W.wantsDialog(undefined), null);
});

test("Testlauf: Wahr/Falsch als zwei grosse Flaechen, Luecke als Feld, richtige Antwort ist das Luecken-Wort", () => {
  const tf = { nr: 1, type: "tf", options: ["Wahr", "Falsch"], answer: "Wahr" };
  assert.equal(TR.isChoice(tf), true); assert.equal(TR.isTwoWay(tf), true); assert.deepEqual(TR.choices(tf), ["Wahr", "Falsch"]);
  assert.deepEqual(TR.choices({ type: "tf" }), TR.TF_OPTIONS, "ohne Optionen im Test: immer die zwei festen");
  assert.deepEqual(TR.choices({ type: "tf", options: ["a", "b", "c"] }), TR.TF_OPTIONS);
  const mc = { type: "mc", options: ["A", "B", "C", "D"] };
  assert.equal(TR.isTwoWay(mc), false); assert.deepEqual(TR.choices(mc), ["A", "B", "C", "D"]);
  assert.equal(TR.isTwoWay({ type: "mc", options: ["Ja", "Nein"] }), true, "genau zwei Optionen");
  const cloze = { type: "cloze", question: "Der ___ ist 3.", blank: " Wert ", answer: "Der Wert ist 3." };
  assert.equal(TR.isChoice(cloze), false); assert.equal(TR.correctAnswer(cloze), "Wert"); assert.equal(TR.correctAnswer({ type: "cloze", answer: "A" }), "A");
  assert.equal(TR.correctAnswer({ type: "short", blank: "x", answer: "Antwort" }), "Antwort");
  assert.deepEqual(["mc", "tf", "cloze", "short", "calc", "?"].map(TR.kindLabel), ["Multiple Choice", "Wahr / Falsch", "Lückentext", "Kurzantwort", "Rechnen / Programmieren", "Kurzantwort"]);
  assert.equal(TR.askSub({ ...cloze, nr: 5 }), "Aufgabe 5 · Lückentext");
  assert.equal(TR.explanationOf({ explanation: " Weil B. " }, { feedback: "Falsch." }), "Weil B.");
  assert.equal(TR.explanationOf({ explanation: "Weil B." }, { feedback: "Weil B." }), "", "nicht doppelt");
  assert.equal(TR.explanationOf({}, null), "");
});

test("Testergebnis: Ring, Prozent, richtig/zum Nacharbeiten, Einordnung", () => {
  const t = { questions: [{ nr: 1 }, { nr: 2 }, { nr: 3 }], feedback: { total: 12, max: 20, per_question: [{ nr: 1, points: 10, max: 10 }, { nr: 2, points: 2, max: 5 }, { nr: 3, points: 0, max: 5 }] } };
  const r = TR.resultSummary(t);
  assert.deepEqual([r.pct, r.total, r.max, r.right, r.n, r.redo, r.tone, r.status], [60, 12, 20, 1, 3, 2, "ok", "Gut gemacht"]);
  assert.equal(TR.rightLine(r), "1/3 richtig · 2 zum Nacharbeiten");
  assert.equal(TR.resultSummary({ questions: [], feedback: { total: 3, max: 10, per_question: [] } }).tone, "bad");
  assert.equal(TR.askLabel(4), "Frag die KI zu Aufgabe 4");
  assert.equal(TR.firstQuestion(2, false), "Warum ist meine Antwort zu Aufgabe 2 falsch?"); assert.equal(TR.firstQuestion(2, true), "Erklär mir Aufgabe 2 noch einmal kurz.");
  assert.equal(TR.isRight({ points: 3, max: 5 }), true); assert.equal(TR.isRight({ points: 2.9, max: 5 }), false); assert.equal(TR.isRight(null), false);
  const ctx = TR.tutorContext({ nr: 2, question: "F?", options: ["Wahr", "Falsch"], answer: "Wahr" }, "Falsch", { points: 0, max: 5, feedback: "Nein." });
  assert.match(ctx, /Antwortmöglichkeiten: Wahr \| Falsch/); assert.match(ctx, /Meine Antwort: Falsch/); assert.match(ctx, /Musterlösung: Wahr/);
});

test("views-misc.js: Dialog statt fester Auswahl, Testlauf mit den neuen Arten", () => {
  const m = read("views-misc.js");
  assert.match(m, /from "\.\/week-test-dialog\.js\?v=\d+"/); assert.match(m, /openWeekTestDialog\(\{/);
  assert.ok(!m.includes('id="exSubj"') && !m.includes('id="exDur"'), "Modul und Dauer stehen jetzt im Dialog");
  assert.match(m, /id="exPh"/); assert.match(m, /onStarted: info => \{ window\.pollBg\?\.\(\); placeholder\(info\); \}/);
  assert.match(m, /Fehlende Wochentests/); assert.match(m, /Wochentest erstellen/);
  assert.match(m, /TR\.isChoice\(q\)/); assert.match(m, /q\.type === "cloze"/); assert.match(m, /TR\.correctAnswer\(q\)/); assert.match(m, /TR\.kindLabel\(q\.type\)/);
});

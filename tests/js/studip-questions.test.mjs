// Stundenplan: Rückfragen zum Stud.IP-Kalender und Ausfälle laut Stud.IP im Web (studip-questions.js, 05.11.2026),
// Antworten in der Form von GET /api/timetable/studip-questions bzw. /studip-cancelled (app/timetable_questions.py).
import { test } from "node:test";
import assert from "node:assert/strict";
import * as S from "../../app/static/studip-questions.js";

const QS = {
  hidden: [{ course_id: "k-frei", title: "Testmathe ohne Kalender", times: 2 }],
  busy: [{ course_id: "k-frage", title: "Fragestunden Testmathe", times: [
    { cycle_id: "k-frage|0|14:00|15:30", weekday: 0, start_time: "14:00", end_time: "15:30", room: "Raum F1", attend: true },
    { cycle_id: "k-frage|1|16:00|17:30", weekday: 1, start_time: "16:00", end_time: "17:30", room: "", attend: false },
    { cycle_id: "k-frage|3|16:00|17:30", weekday: 3, start_time: "16:00", end_time: "17:30", room: "Raum F1", attend: true }] }],
};

test("Ausfälle laut Stud.IP: nur genau diese Vorkommen fallen weg, selbst markierte bleiben", () => {
  const keys = S.cancelKeys([{ event_id: 7, date: "2026-12-23" }, { event_id: null, date: "x" }, "kaputt"]);
  assert.deepEqual([...keys], ["7|2026-12-23"]);
  const week = () => ({ days: [{ date: "2026-12-23", events: [
    { event_id: 7, status: "ausfall", exception: "cancelled", title: "VL" },
    { event_id: 8, status: "ausfall", exception: "cancelled", title: "selbst markiert" },
    { event_id: 7, status: "teilnahme", exception: null, title: "anderer Status" }] }, { date: "2026-12-24", events: [] }] });
  const w = week();
  assert.equal(S.hideCancelled(w, keys), 1);
  assert.deepEqual(w.days[0].events.map(e => e.title), ["selbst markiert", "anderer Status"]);
  const shown = week();
  assert.equal(S.hideCancelled(shown, keys, true), 1, "gezählt, aber stehen gelassen");
  assert.equal(shown.days[0].events.length, 3);
  assert.equal(S.hideCancelled({ days: [] }, keys), 0);
  assert.equal(S.hideCancelled(null, keys), 0);
});

test("Hinweiszeile zu den Ausfällen", () => {
  assert.equal(S.cancelNoteHtml(0, false), "");
  assert.match(S.cancelNoteHtml(1, false), /1 Termin fällt diese Woche laut Stud\.IP aus und ist ausgeblendet, wie in Stud\.IP\./);
  assert.match(S.cancelNoteHtml(3, false), /3 Termine fallen .* und sind ausgeblendet/);
  assert.match(S.cancelNoteHtml(3, false), />Anzeigen</);
  assert.match(S.cancelNoteHtml(3, true), /aus\. <button[^>]*>Ausblenden</);
});

test("Fragekarten wie auf dem iPad", () => {
  assert.equal(S.questionsHtml(null), "");
  assert.equal(S.questionsHtml({ hidden: [], busy: [] }), "");
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const html = S.questionsHtml(QS, { esc });
  assert.ok(html.includes(esc(S.hiddenText("Testmathe ohne Kalender"))));
  assert.ok(html.includes("Bis du entscheidest, bleibt er wie in Stud.IP draußen."));
  assert.match(html, /data-sq-inc="0">Übernehmen</);
  assert.match(html, /data-sq-exc="0">Weglassen</);
  assert.ok(html.includes(esc(S.busyText("Fragestunden Testmathe", 3))));
  assert.equal((html.match(/data-sq-t="0"/g) || []).length, 3);
  assert.equal((html.match(/ checked>/g) || []).length, 2, "nicht besuchte Serie ist abgewählt");
  assert.ok(html.includes("Abgewählte Termine werden grau und geben die Zeit für Lernblöcke frei."));
  assert.equal(S.timeLabel(QS.busy[0].times[0]), "Mo 14:00–15:30 · Raum F1");
  assert.equal(S.timeLabel(QS.busy[0].times[1]), "Di 16:00–17:30");
});

test("Rumpf und Rückmeldung", () => {
  assert.deepEqual(S.timesBody(QS.busy[0], new Set(["k-frage|3|16:00|17:30", "k-frage|0|14:00|15:30", "fremd"])),
    { course_id: "k-frage", attend: ["k-frage|0|14:00|15:30", "k-frage|3|16:00|17:30"] });
  assert.equal(S.answerToast("course", { new: 2 }, true), "2 Termine übernommen");
  assert.equal(S.answerToast("course", { new: 1 }, true), "1 Termin übernommen");
  assert.equal(S.answerToast("course", { new: 0 }, true), "Kurs übernommen");
  assert.equal(S.answerToast("course", {}, false), "Kurs weggelassen");
  assert.equal(S.answerToast("times", { skipped: 2 }), "2 Termine als „nicht besucht“ markiert");
  assert.equal(S.answerToast("times", { skipped: 0 }), "Alle Termine bleiben");
});

test("Knöpfe schicken die Antwort und laden neu", async () => {
  const calls = [], toasts = []; let reloaded = 0;
  const btn = data => ({ dataset: data, disabled: false, textContent: "", onclick: null });
  const inc = btn({ sqInc: "0" }), exc = btn({ sqExc: "0" }), save = btn({ sqSave: "0" });
  const boxes = QS.busy[0].times.map((t, i) => ({ value: t.cycle_id, checked: i !== 1 }));
  const root = { querySelectorAll: s => s === "[data-sq-inc]" ? [inc] : s === "[data-sq-exc]" ? [exc] : s === "[data-sq-save]" ? [save] : s === '[data-sq-t="0"]' ? boxes : [] };
  const api = async (path, opts) => { calls.push([path, opts.body]); return path.endsWith("/course") ? { new: 2 } : { skipped: 1 }; };
  S.bindQuestions(root, QS, { api, toast: t => toasts.push(t), done: () => reloaded++ });
  await inc.onclick(); await exc.onclick(); await save.onclick();
  assert.deepEqual(calls, [
    ["/timetable/studip-questions/course", { course_id: "k-frei", include: true }],
    ["/timetable/studip-questions/course", { course_id: "k-frei", include: false }],
    ["/timetable/studip-questions/times", { course_id: "k-frage", attend: ["k-frage|0|14:00|15:30", "k-frage|3|16:00|17:30"] }]]);
  assert.deepEqual(toasts, ["2 Termine übernommen", "Kurs weggelassen", "1 Termin als „nicht besucht“ markiert"]);
  assert.equal(reloaded, 3);
  const failing = { querySelectorAll: s => s === "[data-sq-inc]" ? [inc] : [] };
  S.bindQuestions(failing, QS, { api: async () => { throw new Error("offline"); }, toast: t => toasts.push(t), done: () => reloaded++ });
  await inc.onclick();
  assert.equal(toasts.at(-1), "Antwort nicht gespeichert: offline");
});

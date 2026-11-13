// Lernziele am PC (app/static/goals-logic.js): dieselben Texte und Rechnungen wie GoalsFmt, GoalsInput und
// GoalsOptionRow auf dem iPad (apps/apple/UniFlow/Views/Goals). Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import * as G from "../../app/static/goals-logic.js";

test("Stunden wie im Rechenkern (GoalsFmt.h)", () => {
  assert.equal(G.h(750), "12,5 h");
  assert.equal(G.h(19200), "320 h");
  assert.equal(G.h(0), "0 h");
  assert.equal(G.h(null), "0 h");
  assert.equal(G.h(31), "0,5 h");
  assert.equal(G.h(29), "0,5 h");
  assert.equal(G.h(2), "0 h");
  assert.equal(G.h(-90), "-1,5 h");
  assert.equal(G.h(59.9), "1 h", "Bruchteile von Minuten werden wie Int() in Swift abgeschnitten");
});

test("Tage, Wochentag, Prognose", () => {
  assert.equal(G.days(null), "kein Termin");
  assert.equal(G.days(0), "heute");
  assert.equal(G.days(1), "morgen");
  assert.equal(G.days(12), "in 12 Tagen");
  assert.equal(G.weekday("2026-11-16"), "Mo");
  assert.equal(G.weekday("2026-11-22"), "So");
  assert.equal(G.weekday(""), "");
  assert.deepEqual(G.STATUS.gefaehrdet, ["Gefährdet", "bad"]);
});

test("Zahlenzeile und Balken eines Moduls", () => {
  const st = { target_minutes: 12000, learned_minutes: 600, lecture_minutes: 0, remaining_minutes: 11400, per_week_minutes: 600, forecast_percent: 80 };
  assert.equal(G.numbers(st), "Ziel 200 h · gelernt 10 h · fehlt 190 h · 10 h pro Woche · Prognose 80 %");
  assert.equal(G.numbers({ ...st, lecture_minutes: 90, per_week_minutes: null }),
               "Ziel 200 h · gelernt 10 h · Veranstaltungen 1,5 h · fehlt 190 h · Prognose 80 %");
  assert.equal(G.share(st), 0.05);
  assert.equal(G.share({ target_minutes: 60, learned_minutes: 120 }), 1);
  assert.equal(G.share({ target_minutes: 0 }), 1);
});

test("Stoppuhr: Summe der Abschnitte, offener bis jetzt", () => {
  const s = { segments: [[1000, 1600], [2000, null]] };
  assert.equal(G.elapsed(s, 2065), "0:11:05");
  assert.equal(G.elapsed({ segments: [[0, 3 * 3600 + 61]] }, 0), "3:01:01");
  assert.equal(G.elapsed({}, 0), "0:00:00");
  assert.equal(G.elapsed({ segments: [[5000, null]] }, 4000), "0:00:00", "Uhr des Geraets nachgehend: nie negativ");
});

test("Zahlen mit Komma oder Punkt (GoalsInput)", () => {
  assert.equal(G.parseNum("12,5"), 12.5);
  assert.equal(G.parseNum(" 200 "), 200);
  assert.equal(G.parseNum("12.5"), 12.5);
  assert.equal(G.parseNum(""), null);
  assert.equal(G.parseNum("abc"), null);
  assert.equal(G.parseNum("1e3"), null);
  assert.equal(G.numText(12.5), "12,5");
  assert.equal(G.numText(200), "200");
  assert.equal(G.numText(null), "");
  assert.equal(G.numText(10 / 3), "3,3");
});

test("Ortszeit Berlin -> Unix-Sekunden, Sommer- und Winterzeit", () => {
  assert.equal(G.berlinEpoch("2026-11-13", "14:30"), Date.UTC(2026, 10, 13, 13, 30) / 1000);   // MEZ, UTC+1
  assert.equal(G.berlinEpoch("2026-07-01", "08:00"), Date.UTC(2026, 6, 1, 6, 0) / 1000);      // MESZ, UTC+2
  assert.equal(G.berlinEpoch("2026-03-29", "04:00"), Date.UTC(2026, 2, 29, 2, 0) / 1000);     // Tag der Umstellung
  assert.equal(G.berlinEpoch("2026-13-01", "08:00"), null);
  assert.equal(G.berlinEpoch("2026-11-13", "25:00"), null);
  assert.equal(G.berlinEpoch("x", "08:00"), null);
  assert.equal(G.berlinEpoch("2026-11-13", "8"), null);
});

test("Optionen bei Unterdeckung: was ein Klick aendert (wie GoalsOptionRow.apply)", () => {
  const o = { settings: { leisure_minutes: 120 }, modules: [{ module_id: 3, target_minutes: 12000 }, { module_id: 4, target_minutes: 3000 }] };
  assert.equal(G.actionable({ kind: "nutzungsquote", value: 80 }), true);
  assert.equal(G.actionable({ kind: "nutzungsquote" }), false);
  assert.equal(G.actionable({ kind: "prioritaet" }), false);
  assert.deepEqual(G.optionRequests({ kind: "nutzungsquote", value: 80 }, o),
                   { requests: [{ path: "/goals/settings", method: "PUT", body: { utilization: 80 } }], plan: {} });
  assert.deepEqual(G.optionRequests({ kind: "freizeit", minutes_per_day: 150 }, o).requests[0].body, { leisure_minutes: 0 }, "nie unter 0");
  assert.deepEqual(G.optionRequests({ kind: "freizeit", minutes_per_day: 30 }, o).requests[0].body, { leisure_minutes: 90 });
  assert.deepEqual(G.optionRequests({ kind: "ziele", cuts: [{ module_id: 3, minutes: 1234 }, { module_id: 99, minutes: 60 }] }, o).requests,
                   [{ path: "/goals/3", method: "PUT", body: { target_hours: 179.4 } }], "abgerundet auf Zehntel, unbekannte Module ausgelassen");
  assert.deepEqual(G.optionRequests({ kind: "zweittermin", module_id: 4, date: "2027-03-20" }, o).requests[0],
                   { path: "/goals/4", method: "PUT", body: { exam_attempt: 2, exam_date_2: "2027-03-20" } });
  assert.deepEqual(G.optionRequests({ kind: "teilplan" }, o), { requests: [], plan: { accept_partial: true } });
  assert.equal(G.optionRequests({ kind: "unbekannt" }, o), null);
});

test("Kennzahlen der Kopfzeile", () => {
  const o = { next_exam: { name: "Mathematik", days: 40 }, week: { planned_minutes: 600, learned_minutes: 90 },
              modules: [{ target_minutes: 12000, stats: { remaining_minutes: 11000 } }, { target_minutes: 6000, stats: { remaining_minutes: 6000 } }] };
  assert.deepEqual(G.kpis(o), [["40", "Tage bis Mathematik"], ["10 h", "Diese Woche geplant"], ["1,5 h", "Diese Woche gelernt"], ["283,3 h", "Fehlt noch von 300 h"]]);
  assert.deepEqual(G.kpis({ modules: [] })[0], ["–", "Keine Klausur geplant"]);
});

test("Lernblock im Lernpaket", () => {
  assert.equal(G.blockLabel({ locked: 1 }), "Lernblock aus deinen Lernzielen · gesperrt");
  assert.equal(G.blockLabel({ manual: 1 }), "Lernblock aus deinen Lernzielen · von dir verschoben");
  assert.equal(G.blockLabel({}), "Lernblock aus deinen Lernzielen");
});

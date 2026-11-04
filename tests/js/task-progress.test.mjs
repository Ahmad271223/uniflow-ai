// Eine Zaehlweise "Aufgaben erledigt" (app/static/task-progress.js) ohne Browser. Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { progress, ofDays, ofWeek, weekDays, weekLabel, mondayOf, emptyText } from "../../app/static/task-progress.js";

const task = status => ({ status });
const day = (date, statuses, events = []) => ({ date, packages: statuses.length ? [{ tasks: statuses.map(task) }] : [], events });

test("progress: Zahlen, offene Aufgaben, Anteil, Text; ohne Aufgaben leer statt 0 / 0", () => {
  const p = progress({ done: 1, late: 1, skipped: 1, total: 5 });
  assert.equal(p.open, 2);
  assert.equal(p.empty, false);
  assert.equal(p.fraction, 0.2);
  assert.equal(p.text, "1 / 5");
  const e = progress();
  assert.deepEqual([e.done, e.late, e.skipped, e.total, e.open], [0, 0, 0, 0, 0]);
  assert.equal(e.empty, true);
  assert.equal(e.fraction, 0);
  assert.equal(e.text, null);
  assert.equal(progress({ done: 3, late: 3, total: 4 }).open, 0);                 // nie negativ
  assert.equal(progress({ done: 4, total: 4 }).fraction, 1);
});

test("ofDays: alle Aufgaben aller Lernpakete wie tasks_total, nach Status getrennt", () => {
  const days = [
    { date: "2026-11-02", packages: [{ tasks: [task("erledigt"), task("geplant"), task("in_bearbeitung")] }, { tasks: [task("nachholen")] }] },
    { date: "2026-11-03", packages: [{ tasks: [task("uebersprungen"), task("erledigt")] }] },
    { date: "2026-11-04", packages: [] },
    { date: "2026-11-05" },                                                          // ohne packages
  ];
  const p = ofDays(days);
  assert.deepEqual([p.done, p.late, p.skipped, p.open, p.total], [2, 1, 1, 2, 6]);
  assert.equal(p.text, "2 / 6");
  assert.equal(ofDays([]).empty, true);
  assert.equal(ofDays(undefined).empty, true);
  assert.equal(ofDays([{ date: "2026-11-02", packages: [{ tasks: [] }] }]).text, null);
});

test("ofWeek: Woche der Uebersicht (week.done/total), fehlend leer", () => {
  const p = ofWeek({ done: 2, total: 4, days: [] });
  assert.equal(p.text, "2 / 4");
  assert.equal(p.fraction, 0.5);
  assert.equal(p.open, 2);
  assert.equal(ofWeek({ done: 0, total: 0 }).empty, true);
  assert.equal(ofWeek(null).empty, true);
  assert.equal(ofWeek(undefined).text, null);
});

test("mondayOf: Montag der Woche, Sonntag gehoert zur vorigen Woche, Date oder ISO", () => {
  const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  assert.equal(iso(mondayOf("2026-11-04")), "2026-11-02");                          // Mittwoch
  assert.equal(iso(mondayOf("2026-11-02")), "2026-11-02");                          // Montag selbst
  assert.equal(iso(mondayOf("2026-11-08")), "2026-11-02");                          // Sonntag
  assert.equal(iso(mondayOf(new Date(2027, 0, 1))), "2026-12-28");                  // Jahreswechsel
});

test("weekDays: die sieben Tage Mo–So um das Datum aus mehreren Listen, jeder Tag einmal, sortiert", () => {
  const shown = [day("2026-11-04", ["erledigt"]), day("2026-11-05", ["geplant"]), day("2026-11-06", [])];   // 3 Tage
  const month = [day("2026-10-26", []), day("2026-11-02", ["nachholen"]), day("2026-11-03", []), day("2026-11-04", ["geplant", "geplant"]),
    day("2026-11-05", []), day("2026-11-06", []), day("2026-11-07", []), day("2026-11-08", ["erledigt"]), day("2026-11-09", ["erledigt"])];
  const w = weekDays(new Date(2026, 10, 4), shown, month);
  assert.deepEqual(w.map(x => x.date), ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]);
  assert.equal(w[2], shown[0]);                                                       // die zuerst uebergebene Liste gewinnt
  assert.equal(ofDays(w).text, "2 / 4");                                              // 04: erledigt (shown), 02: nachholen, 05: geplant, 08: erledigt
  assert.equal(weekDays("2026-11-08", shown, month).length, 7);                       // Sonntag: dieselbe Woche
  assert.deepEqual(weekDays("2026-11-04", undefined, [day("2026-11-07", [])]).map(x => x.date), ["2026-11-07"]);   // fehlende Tage fehlen, kein Fehler
  assert.deepEqual(weekDays("2026-11-04").length, 0);
});

test("weekDays: Woche ueber Jahres- und Monatsgrenze", () => {
  const all = Array.from({ length: 14 }, (_, i) => day(`202${i < 7 ? "6-12-" + (25 + i) : "7-01-0" + (i - 6)}`, []));
  assert.deepEqual(weekDays("2026-12-30", all).map(x => x.date), ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"]);
  assert.deepEqual(weekDays("2027-01-03", all).map(x => x.date)[0], "2026-12-28");
});

test("weekLabel: diese Woche, sonst Zeitraum; Monats- und Jahresgrenze", () => {
  const today = new Date(2026, 10, 4);                                                // Mi, 4. Nov. 2026
  assert.equal(weekLabel(new Date(2026, 10, 2), today), "diese Woche");
  assert.equal(weekLabel("2026-11-08", today), "diese Woche");                        // Sonntag derselben Woche
  assert.equal(weekLabel(new Date(2026, 10, 9), today), "Woche 9.–15. Nov.");
  assert.equal(weekLabel("2026-11-11", today), "Woche 9.–15. Nov.");                  // kein Montag: wird auf den Montag gezogen
  assert.equal(weekLabel("2026-10-26", today), "Woche 26. Okt. – 1. Nov.");           // Monatsgrenze
  assert.equal(weekLabel("2026-11-30", today), "Woche 30. Nov. – 6. Dez.");
  assert.equal(weekLabel("2026-12-28", today), "Woche 28. Dez. – 3. Jan.");           // Jahresgrenze
  assert.equal(weekLabel("2026-03-02", today), "Woche 2.–8. März");                   // Monat ohne Punkt
  assert.equal(weekLabel("2026-11-02", new Date(2026, 10, 11)), "Woche 2.–8. Nov.");  // vorige Woche ist nicht "diese Woche"
});

test("emptyText: Satz statt 0 / 0, mit Uni-Terminen", () => {
  assert.equal(emptyText(0), "Keine Lernaufgaben geplant.");
  assert.equal(emptyText(undefined), "Keine Lernaufgaben geplant.");
  assert.equal(emptyText(1), "Keine Lernaufgaben geplant, 1 Uni-Termin.");
  assert.equal(emptyText(3), "Keine Lernaufgaben geplant, 3 Uni-Termine.");
});

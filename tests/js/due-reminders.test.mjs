// Erinnerungen an erkannte Fristen (app/static/due-reminders-logic.js) gegen die gemeinsamen Faelle
// packages/shared-contracts/fixtures/due-detection/cases.json ("reminders", Erwartungen aus DueRemindersTests in Swift).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as R from "../../app/static/due-reminders-logic.js";

const FIX = JSON.parse(readFileSync(new URL("../../packages/shared-contracts/fixtures/due-detection/cases.json", import.meta.url), "utf8")).reminders;
const local = ms => R.berlinLocal(ms);

test("Zeitpunkte mit und ohne Uhrzeit, fruehe Uhrzeiten, vergangene", () => {
  assert.equal(R.PREFIX, FIX.prefix);
  assert.equal(R.LIMIT, FIX.limit);
  for (const c of FIX.plans) {
    const p = R.plan(c.items, c.container, R.parseLocal(c.now));
    assert.deepEqual(p.map(r => `${r.identifier} ${local(r.fireAt)}`), c.expect);
    (c.titles || []).forEach((t, i) => assert.equal(p[i].title, t));
    for (const [i, b] of Object.entries(c.bodies || {})) assert.equal(p[+i].body, b);
    for (const [i, u] of Object.entries(c.utc || {})) assert.equal(new Date(p[+i].fireAt).toISOString().replace(".000", ""), u, "8:00 Berlin im Winter = 7:00 UTC");
  }
  const first = FIX.plans[0];
  assert.equal(R.plan(first.items, first.container, R.parseLocal(first.now))[0].route, "#/doc/f-blatt");
});

test("hoechstens 60, frueheste zuerst", () => {
  const c = FIX.limit_case;
  const items = Array.from({ length: c.count }, (_, i) => {
    const d = new Date(Date.UTC(2026, 10, 1 + i));
    return { id: `i${i}`, title: `Abgabe ${i}`, date: d.toISOString().slice(0, 10), time: c.time };
  });
  const p = R.plan(items, c.container, R.parseLocal(c.now));
  assert.equal(p.length, c.expect_count);
  assert.deepEqual(p.map(r => r.fireAt), [...p.map(r => r.fireAt)].sort((a, b) => a - b));
  assert.equal(local(p[0].fireAt), c.expect_first);
  assert.ok(!p.some(r => r.itemID === c.missing_item));
  assert.equal(R.plan(items, c.container, R.parseLocal(c.now), c.small_limit).length, c.small_limit);
});

test("Termine aus GET /api/due und Abgleich", () => {
  const c = FIX.items_from_response;
  const items = R.itemsFrom(c.response);
  assert.deepEqual(items.map(i => i.id), c.ids, "ausgeblendete fehlen");
  assert.deepEqual(items.map(i => i.route), c.routes);
  assert.deepEqual(items.map(i => i.course), c.courses);
  assert.deepEqual(items.map(i => i.time), c.times);
  const d = R.diff(FIX.diff.pending, FIX.diff.planned.map(identifier => ({ identifier })));
  assert.deepEqual(d.remove, FIX.diff.remove, "anderer Container und ausgeblendete weg, fremde Kennungen bleiben");
});

test("Sommerzeit, Hinweis in der App und Weg der Mitteilung", () => {
  assert.equal(new Date(R.berlinToUtc("2026-07-01", 8 * 60)).toISOString(), "2026-07-01T06:00:00.000Z");
  assert.equal(R.when("2026-11-05", "23:59"), "Do, 05.11. 23:59");
  const now = R.parseLocal("2026-11-05T09:00");
  const s = R.todaySummary([{ id: "a", title: "Abgabe Blatt 3", date: "2026-11-05", time: "12:00", route: "#/doc/f" },
                            { id: "b", title: "Testat", date: "2026-11-06" }, { id: "c", title: "Alt", date: "2026-11-05", time: "08:00" },
                            { id: "d", title: "Später", date: "2026-11-09" }], now);
  assert.deepEqual(s.lines, ["Heute 12:00: Abgabe Blatt 3", "Morgen: Testat"]);
  assert.equal(s.route, "#/doc/f");
  assert.equal(R.todaySummary([], now), null);
  assert.equal(R.dueWithin([{ fireAt: now + 1000 }, { fireAt: now + 10 * 86400000 }], now, 86400000).length, 1);
  assert.equal(R.channel({ __TAURI_INTERNALS__: { invoke() {} } }), "tauri");
  const N = function () {}; N.permission = "default";
  assert.equal(R.channel({ Notification: N }), "browser");
  N.permission = "denied";
  assert.equal(R.channel({ Notification: N }), "inapp");
  assert.equal(R.channel({}), "inapp");
});

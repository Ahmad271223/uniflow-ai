// Karte "Nächste Klausuren" der Übersicht (app/static/exams.js) ohne Browser, mit der Antwort von
// GET /api/exams/upcoming aus dem gemeinsamen Fixture (tools/gen-exams-fixture.py; gleich in ExamsTests und im iPad).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { examsCard, bindExamsCard, moreText, examDate, countdown, placeText, examHref, LIMIT } from "../../app/static/exams.js";

const fx = JSON.parse(readFileSync(new URL("../../packages/shared-contracts/fixtures/exams/exams.json", import.meta.url), "utf8"));
const items = fx.steps[0].response.items;

test("ohne Klausuren keine Karte", () => {
  assert.equal(examsCard([]), "");
  assert.equal(examsCard(null), "");
  assert.equal(examsCard(undefined), "");
  assert.equal(examsCard([{ title: "ohne Tag" }]), "");
});

test("Tag, Countdown, Ort und Quelle", () => {
  assert.equal(examDate("2027-02-12"), "Fr., 12.02.2027");
  assert.equal(countdown({ in_days: "in 100 Tagen" }), "in 100 Tagen");
  assert.equal(countdown({ days_left: 0 }), "heute");
  assert.equal(countdown({ days_left: 1 }), "morgen");
  assert.equal(countdown({ days_left: 12 }), "in 12 Tagen");
  assert.equal(placeText({ time: "09:00", end: "11:00", room: "Hörsaal F 303" }), "09:00–11:00 Uhr · Hörsaal F 303");
  assert.equal(placeText({ time: null, room: null }), "");
  assert.equal(examHref({ module_id: 3, date: "2027-02-05" }), "#/modules/3");
  assert.equal(examHref({ module_id: null, date: "2027-03-01" }), "#/plan?view=day&date=2027-03-01");
});

test("Karte aus der Antwort des Servers: erste vier, Rest gezählt", () => {
  assert.ok(items.length > LIMIT);
  const html = examsCard(items, "<i></i>");
  assert.match(html, /Nächste Klausuren/);
  for (const e of items.slice(0, LIMIT)) {
    assert.ok(html.includes(e.title.replace(/&/g, "&amp;")), e.title);
    assert.ok(html.includes(e.in_days), e.in_days);
  }
  // die ersten vier sofort, die übrigen versteckt hinter dem Knopf "und n weitere" (aufklappbar, 26.11.2026)
  const [head, rest] = html.split('class="list ov-exam-rest"');
  assert.equal(head.split('class="item ov-exam"').length - 1, LIMIT, "zugeklappt höchstens vier Zeilen");
  assert.equal(rest.split('class="item ov-exam"').length - 1, items.length - LIMIT, "alle übrigen stehen im aufklappbaren Teil");
  assert.match(rest, /^ id="ovExamRest" hidden>/);
  assert.match(html, new RegExp(`<button type="button" class="ov-exam-more" aria-expanded="false" aria-controls="ovExamRest" data-count="${items.length}">und ${items.length - LIMIT} weitere</button>`));
  for (const e of items) assert.ok(html.includes(e.title.replace(/&/g, "&amp;")), `aufgeklappt auch: ${e.title}`);
  const ana = items.find(e => e.module_id === 1);
  // Raumfinder (05.11.2026): der Raum steht als Link unter der Zeile (Ort mit Google Maps), die Zeile nennt die Uhrzeit;
  // VoiceOver liest beides in der Beschriftung der Zeile
  assert.ok(html.includes(">09:00–11:00 Uhr<"));
  assert.ok(html.includes('data-room="Hörsaal F 303 · Hörsaal F 102"'));
  assert.match(html, /aria-label="[^"]*09:00–11:00 Uhr · Hörsaal F 303 · Hörsaal F 102/);
  assert.ok(html.includes(ana.source_label));
});

test("fremde Texte werden maskiert", () => {
  const html = examsCard([{ date: "2027-02-12", title: "<img src=x onerror=alert(1)>", room: "\"><script>", source_label: "aus Ankündigung vom 01.11.2026", in_days: "in 100 Tagen" }]);
  assert.ok(!html.includes("<img"));
  assert.ok(!html.includes("<script>"));
  assert.match(html, /&lt;img/);
});

test("und n weitere: bis vier Klausuren kein Knopf, sonst klappt er auf und wieder zu", () => {
  assert.ok(!examsCard(items.slice(0, LIMIT)).includes("ov-exam-more"), "genau vier: kein Knopf");
  assert.equal(moreText(9, false), "und 5 weitere");
  assert.equal(moreText(9, true), "Weniger anzeigen");
  // kleiner Ersatz für das DOM: Knopf und versteckter Teil
  let click;
  const btn = { dataset: { count: "9" }, textContent: "und 5 weitere", attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, addEventListener(_, f) { click = f; } };
  const rest = { hidden: true };
  bindExamsCard({ querySelector: sel => sel === ".ov-exam-more" ? btn : sel === ".ov-exam-rest" ? rest : null });
  click();
  assert.equal(rest.hidden, false, "aufgeklappt: alle sichtbar");
  assert.equal(btn.attrs["aria-expanded"], "true");
  assert.equal(btn.textContent, "Weniger anzeigen");
  click();
  assert.equal(rest.hidden, true);
  assert.equal(btn.attrs["aria-expanded"], "false");
  assert.equal(btn.textContent, "und 5 weitere");
  bindExamsCard(null); bindExamsCard({ querySelector: () => null });   // ohne Karte nichts
});

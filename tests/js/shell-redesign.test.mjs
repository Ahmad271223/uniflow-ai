// Neugestaltung wie iPad (04.11.2026) ohne Browser: Seitenleiste in Gruppen mit Tarifzeile (shell-nav.js), Stapel-Kacheln
// mit Leitner-Faechern (flashcards.js), Lernstand-Kachel (mastery.js) und Testergebnis mit "Frag die KI" (test-result.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { NAV_GROUPS, navItems, navHtml, planLabel, upgradeCta, initials, displayName, accountHtml } from "../../app/static/shell-nav.js";
import { boxCounts, boxLevels, boxAria, practiceLine, practiceMode, stackTotals, weekSegments, weekChip, stackTags, kindOf, cardOf, GENERAL_WEEK } from "../../app/static/flashcards.js";
import { masteryTile, masteryRingText } from "../../app/static/mastery.js";
import { resultSummary, rightLine, askLabel, firstQuestion, tutorContext, askSub, isRight } from "../../app/static/test-result.js";

const icon = n => `<i data-i="${n}"></i>`;

test("Seitenleiste: vier Gruppen, alle bisherigen Ziele plus Karteikarten und Mensa, Pillen nur unter Lernen", () => {
  assert.deepEqual(NAV_GROUPS.map(g => g.title), ["Studium", "Lernen", "Alltag", "Gemeinsam"]);
  assert.deepEqual(navItems().map(x => x[0]), ["dashboard", "plan", "timetable", "modules", "studyplan", "files", "services", "exams", "cards", "mensa", "community"]);
  const html = navHtml(icon);
  assert.match(html, /role="group" aria-labelledby="ng-lernen"><div class="nav-label" id="ng-lernen">Lernen<\/div>/);
  assert.match(html, /data-route="exams" class="nav-pill blue"/);
  assert.match(html, /data-route="cards" class="nav-pill peach"/);
  assert.equal((html.match(/nav-pill/g) || []).length, 2);
  assert.match(html, /data-route="community" title="Community"/, "Community ohne Pille, Abzeichen findet den Link weiter");
});

test("Tarifzeile und Knopf aus /api/entitlements", () => {
  assert.equal(planLabel(null, false), "Eigener PC");
  assert.equal(upgradeCta(null, false), null, "am eigenen PC keine Tarife");
  assert.equal(planLabel({ plan: "free" }, true), "Free");
  assert.equal(planLabel({ plan: "plus" }, true), "Plus");
  assert.equal(planLabel({ plan: "pro_ai" }, true), "Pro AI");
  assert.equal(planLabel({ plan: "pro_connect" }, true), "Pro AI", "Altschluessel heisst wie Pro AI");
  assert.equal(planLabel({ plan: "pro_ai", trial: { active: true, days_left: 5 } }, true), "Probe · noch 5 Tage");
  assert.equal(planLabel({ plan: "pro_ai", trial: { active: true, days_left: 1 } }, true), "Probe · noch 1 Tag");
  assert.equal(planLabel({ plan: "free", trial: { active: false, days_left: 0 } }, true), "Free");
  assert.deepEqual(upgradeCta({ plan: "free" }, true), { label: "Plus holen", href: "#/abo" });
  assert.deepEqual(upgradeCta({ plan: "pro_ai", trial: { active: true } }, true), { label: "Plus holen", href: "#/abo" });
  assert.deepEqual(upgradeCta({ plan: "plus" }, true), { label: "Pro AI holen", href: "#/abo" });
  assert.equal(upgradeCta({ plan: "pro_ai" }, true), null);
});

test("Konto: Initialen, Name, Ersatz ohne Namen, escaped", () => {
  assert.equal(initials("Lea Sommer"), "LS");
  assert.equal(initials("", "lea@uni.de"), "LE");
  assert.equal(initials("", ""), "?");
  assert.equal(displayName(" ", "lea.s@uni.de"), "lea.s");
  assert.equal(displayName("", ""), "Dein Konto");
  const h = accountHtml({ name: "<Lea>", ent: { plan: "free" }, hosted: true, arrow: "→" });
  assert.match(h, /&lt;Lea&gt;/);
  assert.match(h, /<small>Free<\/small>/);
  assert.match(h, /href="#\/abo"[^>]*><span>Plus holen<\/span>→/);
  assert.ok(!accountHtml({ name: "", hosted: false, person: "<svg/>" }).includes("btn primary"), "ohne Tarife kein Knopf");
  assert.match(accountHtml({ name: "", hosted: false, person: "<svg/>" }), /side-acct-av" aria-hidden="true"><svg\/>/);
});

test("Kacheln: Karten je Leitner-Fach, Balkenhoehen, Vorlesetext", () => {
  const cards = [{ box: 1 }, { box: 1 }, { box: 3 }, { box: 5 }, { box: 9 }, { box: null }, { box: "2" }];
  assert.deepEqual(boxCounts(cards), [3, 1, 1, 0, 2]);
  assert.deepEqual(boxCounts([]), [0, 0, 0, 0, 0]);
  assert.deepEqual(boxLevels([4, 2, 0, 0, 1]), [1, 0.5, 0, 0, 0.25]);
  assert.deepEqual(boxLevels([0, 0, 0, 0, 0]), [0, 0, 0, 0, 0]);
  assert.equal(boxAria([1, 0, 0, 0, 2]), "Lernstand: Fach 1: 1 Karte, Fach 2: 0 Karten, Fach 3: 0 Karten, Fach 4: 0 Karten, Fach 5: 2 Karten");
});

test("Kacheln: Üben (faellige zuerst), Summen, Wochenfilter, Etiketten", () => {
  assert.equal(practiceLine(4), "Zuerst die 4 fälligen Karten");
  assert.equal(practiceLine(1), "Zuerst die fällige Karte");
  assert.equal(practiceLine(0), "Frei üben, der Plan bleibt");
  assert.equal(practiceMode({ due: 2 }), "review");
  assert.equal(practiceMode({ due: 0 }), "free");
  assert.deepEqual(stackTotals([{ cards: 4, due: 4 }, { cards: 3, due: 0 }, { cards: 6 }]), { stacks: 3, cards: 13, due: 4 });
  const segs = weekSegments([2, 3], GENERAL_WEEK);
  assert.deepEqual(segs.map(s => s.label), ["Alle", "Allgemein", "W2", "W3"]);
  assert.deepEqual(segs.map(s => s.on), [false, true, false, false]);
  assert.equal(weekSegments([], null)[0].on, true);
  assert.equal(weekChip({ week: 3 }), "Woche 3");
  assert.equal(weekChip({ week: null }), "Allgemein");
  assert.deepEqual(stackTags({ source: "week", shared_id: "x" }), ["gemeinsam", "geteilt"]);
  assert.deepEqual(stackTags({ source: "community" }), ["übernommen"]);
  assert.equal(kindOf({ kind: "uebung" }), "uebung");
  assert.equal(kindOf({ kind: "quatsch" }), "eigene");
  assert.equal(cardOf(0, 7), "Karte 1 von 7");
  assert.equal(cardOf(7, 7), "Karte 7 von 7");
});

test("Lernstand-Kachel: Ring mit Zahl, ohne Lernstand Strich und Hinweis", () => {
  const t = masteryTile({ score: 63.6, reason: "3 Wochentests <x>" });
  assert.match(t, /class="ls-tile md"/);
  assert.match(t, /--p:64/);
  assert.match(t, /<b>Lernstand<\/b><small>3 Wochentests &lt;x&gt;<\/small>/);
  assert.match(t, /aria-label="Lernstand 64 Prozent, 3 Wochentests &lt;x&gt;"/);
  assert.equal(masteryRingText({ score: 64 }), "64 %");
  const none = masteryTile(null, "lg");
  assert.match(none, /class="ls-tile lg none"/);
  assert.match(none, /noch kein Lernstand/);
  assert.equal(masteryRingText(null), "–");
});

test("Testergebnis: Prozent, richtig, Einordnung und Frage an die KI", () => {
  const t = { questions: [{ nr: 1 }, { nr: 2 }, { nr: 3 }], feedback: { total: 20, max: 60, per_question: [{ nr: 1, points: 0, max: 20 }, { nr: 2, points: 12, max: 20 }, { nr: 3, points: 20, max: 20 }] } };
  const r = resultSummary(t);
  assert.deepEqual(r, { pct: 33, total: 20, max: 60, right: 2, n: 3, redo: 1, tone: "bad", status: "Nochmal üben" });
  assert.equal(rightLine(r), "2/3 richtig · 1 zum Nacharbeiten");
  assert.equal(resultSummary({ questions: [], feedback: { total: 9, max: 10, per_question: [] } }).status, "Gut gemacht");
  assert.equal(resultSummary({ feedback: {} }).pct, 0, "ohne Punkte kein Teilen durch null");
  assert.equal(isRight({ points: 12, max: 20 }), true);
  assert.equal(isRight(undefined), false);
  assert.equal(askLabel(2), "Frag die KI zu Aufgabe 2");
  assert.equal(firstQuestion(1, false), "Warum ist meine Antwort zu Aufgabe 1 falsch?");
  assert.match(firstQuestion(1, true), /Erklär mir Aufgabe 1/);
  const ctx = tutorContext({ nr: 1, question: "255 hex?", options: ["F0", "FF"], answer: "FF" }, "F0", { points: 0, max: 20, feedback: "F0 ist 240" });
  assert.match(ctx, /Aufgabe 1: 255 hex\?\nAntwortmöglichkeiten: F0 \| FF\nMeine Antwort: F0\nMusterlösung: FF\nRückmeldung: F0 ist 240\nPunkte: 0 von 20/);
  assert.match(tutorContext({ nr: 2, question: "x", answer: "y" }, "", null), /Meine Antwort: \(keine\)/);
  assert.equal(askSub({ nr: 1, type: "mc" }), "Aufgabe 1 · Multiple Choice");
  assert.equal(askSub({ nr: 2, type: "short" }), "Aufgabe 2 · Kurzantwort");
});

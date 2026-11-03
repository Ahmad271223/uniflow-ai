// Karteikarten-Trainer "Frei üben" (app/static/flashcards.js) ohne Browser: dieselben Faelle wie
// apps/apple/UniFlowTests/FlashcardTrainerTests.swift (Filter, Reihenfolge, zuerst gezeigte Seite) und der Ablauf
// mit PATCH-Attrappe (Zaehler, Vorherige, Verstecken). Nie POST /review: Fach und Termin bleiben unberuehrt.
import { test } from "node:test";
import assert from "node:assert/strict";
import { progressOf, progressCounts, defaultOptions, sameOptions, selectCards, shuffled, createTrainer, PROGRESS } from "../../app/static/flashcards.js";

const card = (id, { bookmarked = false, hidden = false, result = null } = {}) =>
  ({ id, question: `Begriff ${id}`, answer: `Definition ${id}`, box: 1, due: "2026-11-03", bookmarked: bookmarked ? 1 : 0, hidden: hidden ? 1 : 0, last_result: result });
// wie GET /api/flashcards: neueste zuerst
const deck = () => [card(6, { hidden: true, result: "right" }), card(5, { bookmarked: true, hidden: true }), card(4, { bookmarked: true, result: "wrong" }),
  card(3, { result: "right" }), card(2, { bookmarked: true, result: "right" }), card(1)];
const ids = (o, cards = deck(), sh = x => x) => selectCards(o, cards, sh).map(c => c.id);

test("Fortschrittsgruppen: versteckt geht vor dem Urteil", () => {
  assert.deepEqual(deck().map(progressOf), ["hidden", "hidden", "wrong", "right", "right", "unlearned"]);
  assert.equal(progressOf({ id: 9 }), "unlearned", "ohne Spalten (alter Server)");
  assert.equal(progressOf({ id: 9, last_result: "vielleicht" }), "unlearned");
  assert.deepEqual(progressCounts(deck()), { hidden: 2, wrong: 1, right: 2, unlearned: 1 });
});

test("Filter: Lernen und Fortschritt kombiniert", () => {
  const o = defaultOptions();
  assert.deepEqual(ids(o), [1, 2, 3, 4], "Standard: alles ausser versteckt, Original = aelteste zuerst");
  o.scope = "bookmarked"; assert.deepEqual(ids(o), [2, 4], "Lesezeichen ohne versteckte");
  o.progress = ["hidden"]; assert.deepEqual(ids(o), [5], "Lesezeichen und versteckt");
  o.scope = "all"; assert.deepEqual(ids(o), [5, 6], "nur versteckte");
  o.progress = ["right"]; assert.deepEqual(ids(o), [2, 3]);
  o.progress = ["wrong", "unlearned"]; assert.deepEqual(ids(o), [1, 4]);
  o.progress = ["right", "hidden"]; assert.deepEqual(ids(o), [2, 3, 5, 6], "versteckte zaehlen nicht als richtig");
  o.progress = [...PROGRESS]; assert.deepEqual(ids(o), [1, 2, 3, 4, 5, 6]);
  o.progress = []; assert.deepEqual(ids(o), [], "nichts gewaehlt: keine Karte");
  o.scope = "bookmarked"; o.progress = ["unlearned"]; assert.deepEqual(ids(o), [], "keine ungelernte Karte mit Lesezeichen");
});

test("Reihenfolge: Original mischt nie, Zufällig mischt die gefilterte Liste", () => {
  const o = { ...defaultOptions(), progress: [...PROGRESS] };
  assert.deepEqual(selectCards(o, deck()).map(c => c.id), [1, 2, 3, 4, 5, 6]);
  o.order = "random";
  assert.deepEqual(ids(o, deck(), x => [...x].reverse()), [6, 5, 4, 3, 2, 1]);
  assert.deepEqual(selectCards(o, deck()).map(c => c.id).sort(), [1, 2, 3, 4, 5, 6], "dieselben Karten, keine doppelt");
  o.progress = ["right"];
  assert.deepEqual(new Set(selectCards(o, deck()).map(c => c.id)), new Set([2, 3]), "erst filtern, dann mischen");
  let n = 0; const fixed = () => [0.9, 0.1, 0.5, 0.3, 0.7][n++ % 5];
  assert.deepEqual(shuffled([1, 2, 3, 4, 5], fixed).sort(), [1, 2, 3, 4, 5]);
});

test("Optionen vergleichen (Zurücksetzen)", () => {
  assert.ok(sameOptions(defaultOptions(), { ...defaultOptions(), progress: ["unlearned", "right", "wrong"] }), "Reihenfolge der Auswahl egal");
  assert.ok(!sameOptions(defaultOptions(), { ...defaultOptions(), firstSide: "definition" }));
  assert.ok(!sameOptions(defaultOptions(), { ...defaultOptions(), progress: ["right"] }));
});

/** PATCH-Attrappe wie patch_flashcard: aendert nur bookmarked, hidden, last_result */
function fakeServer(cards) {
  const db = new Map(cards.map(c => [c.id, { ...c }])), calls = [];
  const patch = async (id, body) => {
    calls.push({ id, body });
    const row = db.get(id);
    for (const k of ["bookmarked", "hidden"]) if (k in body) row[k] = body[k] ? 1 : 0;
    if ("last_result" in body) row.last_result = body.last_result;
    return { ...row };
  };
  return { db, calls, patch };
}

test("Seite zuerst und Umdrehen", () => {
  const t = createTrainer({ patch: async () => ({}) });
  t.start(deck());
  assert.equal(t.current.id, 1); assert.equal(t.showsDefinition, false);
  t.flip(); assert.equal(t.showsDefinition, true);
  t.flip(); assert.equal(t.showsDefinition, false);
  t.apply({ ...t.options, firstSide: "definition" });
  assert.equal(t.showsDefinition, true); t.flip(); assert.equal(t.showsDefinition, false);
});

test("Antworten zaehlen, Vorherige nimmt zurueck, Plan bleibt", async () => {
  const s = fakeServer(deck()); const t = createTrainer({ patch: s.patch });
  t.start([...s.db.values()]);
  assert.equal(t.progressText, "1/4");
  assert.equal(await t.answer(true), true);                                  // Karte 1: noch nicht gelernt -> right
  // Doppeltipp waehrend des Speicherns zaehlt nicht
  const a = t.answer(false), b = t.answer(false);
  assert.equal(await b, false); assert.equal(await a, true);
  assert.deepEqual([t.known, t.unknown, t.position, t.progressText], [1, 1, 2, "3/4"]);
  assert.equal(s.db.get(1).last_result, "right"); assert.equal(s.db.get(2).last_result, "wrong");
  assert.ok(s.calls.every(c => Object.keys(c.body).every(k => ["bookmarked", "hidden", "last_result"].includes(k))), "nie box/due");
  assert.equal(await t.previous(), true);
  assert.deepEqual([t.known, t.unknown, t.position], [1, 0, 1]);
  assert.equal(s.db.get(2).last_result, "right", "Urteil vor der Antwort wiederhergestellt");
  assert.equal(await t.previous(), true);
  assert.equal(s.db.get(1).last_result, null, "wieder noch nicht gelernt");
  assert.equal(t.canGoBack, false);
  for (let k = 0; k < 4; k++) await t.answer(k % 2 === 0);
  assert.ok(t.finished); assert.equal(t.current, null); assert.equal(t.progressText, "4/4");
  t.practiceUnknown();
  assert.deepEqual(t.cards.map(c => c.id), [2, 4], "nur die nicht gewussten, in ihrer Reihenfolge");
  assert.deepEqual([t.known, t.unknown, t.position], [0, 0, 0]);
});

test("Verstecken nimmt die Karte aus dem Durchgang, Lesezeichen bleibt", async () => {
  const s = fakeServer(deck()); const t = createTrainer({ patch: s.patch });
  t.start([...s.db.values()]);
  await t.toggleBookmark();
  assert.equal(t.current.bookmarked, 1); assert.equal(t.source.find(c => c.id === 1).bookmarked, 1);
  await t.toggleHidden();
  assert.equal(s.db.get(1).hidden, 1);
  assert.deepEqual(t.cards.map(c => c.id), [2, 3, 4], "versteckt passt nicht mehr zum Standardfilter");
  assert.equal(t.current.id, 2);
  // mit "Versteckte Karten" im Filter bleibt sie stehen
  t.apply({ ...defaultOptions(), progress: [...PROGRESS] });
  assert.equal(t.current.id, 1); await t.toggleHidden();
  assert.equal(t.current.id, 1); assert.equal(t.current.hidden, 0);
  t.apply({ ...defaultOptions(), scope: "bookmarked", progress: ["unlearned"] });
  assert.deepEqual(t.cards.map(c => c.id), [1], "Lesezeichen gespeichert und in der Ausgangsliste");
  t.apply({ ...defaultOptions(), progress: [] });
  assert.ok(t.empty, "Filter zu eng");
});

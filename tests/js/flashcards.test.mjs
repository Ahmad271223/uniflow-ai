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

test("Erneut fragen: Karte rueckt drei Plaetze nach hinten, ohne Urteil", () => {
  const t = createTrainer({ patch: async () => ({}) });
  t.start(deck());
  assert.deepEqual(t.cards.map(c => c.id), [1, 2, 3, 4]);
  assert.equal(t.askAgain(), true);
  assert.deepEqual(t.cards.map(c => c.id), [2, 3, 4, 1]);
  assert.deepEqual([t.known, t.unknown, t.position, t.progressText, t.canGoBack], [0, 0, 0, "1/4", false]);
  t.flip(); t.askAgain();
  assert.equal(t.flipped, false); assert.deepEqual(t.cards.map(c => c.id), [3, 4, 1, 2]);
  const one = createTrainer({ patch: async () => ({}) }); one.start(deck().slice(0, 1));
  assert.equal(one.canAskAgain, false); assert.equal(one.askAgain(), false);
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

// --- Geschlossene Stapel und Bearbeiten (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md) ---
import { NEW_STACK, cardsOfStack, stacksOfSubject, defaultStack, stackOptions, suggestedStackName, groupStacks, stackLine, validateCard, editPatch, mergeCard, GENERAL_WEEK, kindLabel, stackBadge, weeksOf, filterStacks } from "../../app/static/flashcards.js";

const stacks = () => [
  { id: 1, name: "LA_Skript.pdf", subject: "Lineare Algebra", file_id: "f-la", cards: 2, due: 1, last_practised: "2026-11-03T10:00:00" },
  { id: 2, name: "Klausur", subject: "Lineare Algebra", file_id: null, cards: 0, due: 0, last_practised: null },
  { id: 3, name: "Ohne Modul", subject: null, file_id: null, cards: 1, due: 1, last_practised: null },
  { id: 4, name: "Allgemein", subject: "Physik", file_id: null, cards: 3, due: 0, last_practised: "2026-11-04T09:00:00" },
];
const modules = [{ id: 7, name: "Lineare Algebra", color: "#4f5bd5" }, { id: 8, name: "Analysis", color: "#1f9d5b" }];

test("Stapel je Modul: Module in ihrer Reihenfolge, Faecher ohne Modul, zuletzt Ohne Modul", () => {
  const g = groupStacks(stacks(), modules);
  assert.deepEqual(g.map(x => x.title), ["Lineare Algebra", "Physik", "Ohne Modul"], "Analysis ohne Stapel fehlt");
  assert.deepEqual(g[0].stacks.map(s => s.id), [1, 2]); assert.equal(g[0].color, "#4f5bd5"); assert.equal(g[2].color, null);
  assert.deepEqual(groupStacks([], modules), []);
});

test("Stapelzeile: Modul, Karten, heute faellig, zuletzt geuebt", () => {
  assert.equal(stackLine(stacks()[0], d => d.split("-").reverse().join(".")), "Lineare Algebra · 2 Karten · Heute fällig (1) · zuletzt geübt am 03.11.2026");
  assert.equal(stackLine(stacks()[2]), "Ohne Modul · 1 Karte · Heute fällig (1) · noch nicht geübt");
  assert.equal(stackLine({ id: 9, name: "x" }), "Ohne Modul · 0 Karten · Heute fällig (0) · noch nicht geübt", "ohne Zaehler (alter Server)");
});

test("Geschlossen: nur Karten des gewaehlten Stapels, Vorgabe zuletzt benutzter Stapel des Fachs", () => {
  const cards = [card(1), { ...card(2), stack_id: 1 }, { ...card(3), stack_id: 2 }, { ...card(4), stack_id: 1 }];
  assert.deepEqual(cardsOfStack(cards, 1).map(c => c.id), [2, 4]);
  assert.deepEqual(cardsOfStack(cards, null).map(c => c.id), [], "ohne Stapel wird nichts abgefragt");
  assert.deepEqual(stacksOfSubject(stacks(), "Lineare Algebra").map(s => s.id), [1, 2], "zuletzt geuebt vor neuestem");
  assert.deepEqual(stacksOfSubject(stacks(), null).map(s => s.id), [3]);
  assert.deepEqual(stacksOfSubject([{ id: 5, name: "a", subject: "X" }, { id: 6, name: "b", subject: "X" }], "X").map(s => s.id), [6, 5], "ohne Uebung: neuester zuerst");
  assert.equal(defaultStack(stacks(), "Lineare Algebra"), 1);
  assert.equal(defaultStack(stacks(), "Analysis"), NEW_STACK);
  assert.deepEqual(stackOptions(stacks(), "Physik"), [{ id: NEW_STACK, name: "Neuer Stapel …" }, { id: 4, name: "Allgemein" }]);
  assert.equal(suggestedStackName({ id: "f", name: "VL01.pdf", title: "Folgen" }, "Analysis"), "Folgen");
  assert.equal(suggestedStackName({ id: "f", name: "VL01.pdf" }, "Analysis"), "VL01.pdf");
  assert.equal(suggestedStackName(null, "Analysis"), "Allgemein");
  assert.equal(suggestedStackName(null, null), "Ohne Modul");
});

test("Bearbeiten: Pruefung, PATCH nur mit Aenderungen, nie Fach oder Termin", () => {
  assert.equal(validateCard({ question: " ", answer: "a", stack: 1 }), "Frage und Antwort sind nötig.");
  assert.equal(validateCard({ question: "q", answer: "a", stack: NEW_STACK, newStackName: " " }), "Der neue Stapel braucht einen Namen.");
  assert.equal(validateCard({ question: "q", answer: "a", stack: NEW_STACK, newStackName: "Kapitel 3" }), null);
  assert.equal(validateCard({ question: "q", answer: "a", stack: "2" }), null);
  const c = { id: 5, question: "Alt", answer: "alt", subject: "Lineare Algebra", stack_id: 1, box: 3, due: "2026-12-01" };
  assert.deepEqual(editPatch(c, { question: " Alt ", answer: "alt", subject: "Lineare Algebra", stack: 1 }), {}, "nichts geaendert");
  assert.deepEqual(editPatch(c, { question: " Neu ", answer: "alt", subject: "Lineare Algebra", stack: "1" }), { question: "Neu" });
  assert.deepEqual(editPatch(c, { question: "Alt", answer: "neu", subject: null, stack: 2 }), { answer: "neu", subject: null, stack_id: 2 });
  assert.deepEqual(editPatch(c, { question: "Alt", answer: "alt", subject: "Lineare Algebra", stack: NEW_STACK }), {}, "Neuer Stapel … wird vorher angelegt");
  for (const d of [{ question: "Neu", answer: "neu", subject: "x", stack: 2 }]) assert.ok(!("box" in editPatch(c, d)) && !("due" in editPatch(c, d)));
  const saved = { ...c, question: "Neu", box: 3 };
  assert.deepEqual(mergeCard([card(1), c, card(9)], saved).map(x => x.question), ["Begriff 1", "Neu", "Begriff 9"], "Stelle bleibt");
});

test("Lehrwoche und Art: Etikett, vorkommende Wochen, Filter Alle/Allgemein/Wn", () => {
  const st = [...stacks(), { id: 5, name: "Blatt 3", subject: "Physik", week: 3, kind: "uebung" }, { id: 6, name: "Folien", subject: "Physik", week: 1, kind: "vorlesung" }];
  assert.equal(stackBadge(st[0]), "Eigene · Allgemein", "ohne Felder (alter Server): Eigene, Allgemein");
  assert.equal(stackBadge(st[4]), "Übung · W3"); assert.equal(stackBadge(st[5]), "Vorlesung · W1");
  assert.equal(kindLabel("unbekannt"), "Eigene");
  assert.deepEqual(weeksOf(st), [1, 3]); assert.deepEqual(weeksOf(stacks()), [], "ohne Wochen keine Filterzeile");
  assert.deepEqual(filterStacks(st, null).map(s => s.id), [1, 2, 3, 4, 5, 6]);
  assert.deepEqual(filterStacks(st, GENERAL_WEEK).map(s => s.id), [1, 2, 3, 4]);
  assert.deepEqual(filterStacks(st, 3).map(s => s.id), [5]); assert.deepEqual(filterStacks(st, 9), []);
});

// --- Geteilte Wochenstapel und Stapel teilen (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md) ---
import { WEEK_KINDS, weekStack, hasCompleteWeek, weekCompleteCards, fetchLabel, stackBadgeFull, canShare, sharedLine, filterShared } from "../../app/static/flashcards.js";

test("Wochenstapel: finden, Woche n komplett = Vorlesung, dann Uebung, Ergebniszeilen", () => {
  const st = [{ id: 10, name: "Übung Woche 5", subject: "Analysis", week: 5, kind: "uebung", source: "week" },
              { id: 11, name: "Vorlesung Woche 5", subject: "Analysis", week: 5, kind: "vorlesung", source: "week" },
              { id: 12, name: "Eigene W5", subject: "Analysis", week: 5, kind: "vorlesung", source: null },
              { id: 13, name: "Vorlesung Woche 6", subject: "Analysis", week: 6, kind: "vorlesung", source: "week" }];
  assert.deepEqual(WEEK_KINDS, ["vorlesung", "uebung"]);
  assert.equal(weekStack(st, "Analysis", 5, "vorlesung").id, 11, "nur gemeinsame Stapel (source = week)");
  assert.equal(weekStack(st, "Physik", 5, "vorlesung"), null);
  assert.ok(hasCompleteWeek(st, "Analysis", 5)); assert.ok(!hasCompleteWeek(st, "Analysis", 6), "Uebung fehlt");
  const cards = [{ id: 3, stack_id: 10 }, { id: 1, stack_id: 11 }, { id: 2, stack_id: 11 }, { id: 4, stack_id: 12 }, { id: 0, stack_id: 10 }];
  assert.deepEqual(weekCompleteCards(cards, st, "Analysis", 5).map(c => c.id), [1, 2, 0, 3], "erst Vorlesung, dann Uebung, kein Mischen");
  assert.equal(fetchLabel("vorlesung", "adopted", 20, 2), "Vorlesung: übernommen · 20 Karten · 0 Credits · Variante 2 von 3");
  assert.equal(fetchLabel("uebung", "generated", 1), "Übung: neu erzeugt und geteilt · 1 Karte");
  assert.equal(fetchLabel("uebung", "no_materials"), "Übung: keine Unterlagen in dieser Woche");
  assert.equal(stackBadgeFull(st[1]), "Vorlesung · W5 · gemeinsam");
});

test("Stapel teilen: nur Stapel eines Moduls mit Karten, Liste anderer nach Woche, Unterzeile", () => {
  assert.ok(canShare({ subject: "Analysis", cards: 3 })); assert.ok(!canShare({ subject: null, cards: 3 }), "ohne Modul nie");
  assert.ok(!canShare({ subject: "Analysis", cards: 0 })); assert.ok(!canShare({ subject: "Analysis", cards: 3 }, false), "ohne Dienst nie");
  assert.equal(stackBadgeFull({ kind: "eigene", week: null, source: "community", shared_id: "x" }), "Eigene · Allgemein · übernommen · geteilt");
  const list = [{ id: "a", week: null, mine: false }, { id: "b", week: 3, mine: false }, { id: "c", week: 3, mine: true }];
  assert.deepEqual(filterShared(list, null).map(s => s.id), ["a", "b"], "eigene geteilte Stapel nicht in der Liste");
  assert.deepEqual(filterShared(list, GENERAL_WEEK).map(s => s.id), ["a"]); assert.deepEqual(filterShared(list, 3).map(s => s.id), ["b"]);
  assert.deepEqual(filterShared(undefined, null), []);
  assert.equal(sharedLine({ pseudonym: "Eule 12", cards: 1, likes: 2, adopted: true }), "von Eule 12 · 1 Karte · 2 Likes · übernommen");
});

// ---------------------------------------------------------------- Tarif: Free liest nur (04.11.2026)
import { readOnly, LOCK_TITLE, LOCK_TEXT } from "../../app/static/flashcards.js";
import { readFileSync } from "node:fs";

test("Sperre: ohne can_use_flashcards im Dienst nur lesen, am eigenen PC nie gesperrt", () => {
  const ent = v => ({ plan: v ? "plus" : "free", entitlements: { can_use_flashcards: v } });
  assert.equal(readOnly(true, ent(false)), true, "Free (auch nach der Probe)");
  assert.equal(readOnly(true, ent(true)), false, "Plus, Pro AI, Probe");
  assert.equal(readOnly(true, null), true, "Rechte noch unbekannt: lieber lesen als 403");
  assert.equal(readOnly(false, ent(false)), false, "Einzelplatz ohne Tarif");
  assert.equal(LOCK_TITLE, "Karteikarten gibt es ab StudiNow Plus.", "wie die 403-Meldung des Dienstes");
  assert.equal(LOCK_TEXT, "Mit Plus übst und bearbeitest du deine Karten wieder.");
});

test("Sperre: die Seite blendet im Lesemodus Anlegen, Bearbeiten, Ueben, Teilen und Uebernehmen aus", () => {
  const src = readFileSync(new URL("../../app/static/views-misc.js", import.meta.url), "utf8");
  const view = src.slice(src.indexOf("export async function viewCards"), src.indexOf("// ================================================================ UNI & NOTEN"));
  assert.match(view, /const ro = FC\.readOnly\(state\.hosted, state\.entitlements\)/);
  for (const marker of ['id="stNew"', 'id="wkFetch"', "data-stedit=", "data-shadopt=", "data-edit="]) {
    const at = view.indexOf(marker);
    assert.ok(at > 0, marker);
    assert.ok(view.slice(Math.max(0, at - 200), at).includes("ro ? \"\" :"), `${marker} haengt an ro`);
  }
  assert.match(view, /weekActions = g => \{ const m = moduleOf\(g\.title\); if \(ro \|\|/, "Karten fuer Woche n holen / komplett ueben");
  assert.match(view, /shareBtn = s => ro \|\|/, "Teilen");
  assert.match(view, /ro \? `\$\{lockHint\(\)\}\$\{list\(\)\}` : `\$\{review\}\$\{practice\(\)\}\$\{list\(\)\}`/, "im Stapel: nur die Liste, kein Wiederholen und Ueben");
  assert.match(view, /href="#\/abo">Tarife ansehen/, "Weg zum Tarif");
});

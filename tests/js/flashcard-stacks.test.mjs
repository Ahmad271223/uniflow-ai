// Karteikarten-Stapel (app/static/flashcard-stacks.js, 04.11.2026) ohne Browser: Anzahl wie der Server
// (flashcard_stacks.stack_count), Lernwoche, Wochenauswahl, Schloss ohne Pro AI bzw. Plus, Anfragen fuer KI-Auftrag,
// Teilen und Uebernehmen, Gruppierung der Community-Stapel nach Woche.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as F from "../../app/static/flashcard-stacks.js";

test("Anzahl und Lernwoche wie der Server", () => {
  assert.deepEqual([null, "abc", "", 1, 5, "30", 50, 51, 999, 7.9].map(F.clampCount), [20, 20, 20, 5, 5, 30, 50, 50, 50, 7]);
  assert.deepEqual([null, "", "module", "5", 7, 0, 31, "x", 2.5].map(F.weekValue), [null, null, null, 5, 7, null, null, null, null]);
  assert.equal(F.weekLabel(null), "Ganzes Modul");
  assert.equal(F.weekLabel(4), "Woche 4");
  assert.equal(F.stackTitle({ module_id: 3, module_name: "Analysis I", lecture_week: 5 }), "Analysis I · Woche 5");
  assert.equal(F.stackTitle({ module_id: null, module_name: "Ohne Modul", lecture_week: null }), "Ohne Modul · Weitere Karten");
});

test("Wochenauswahl: aktuelle Woche vorgewaehlt, sonst die letzte davor, immer auch Ganzes Modul", () => {
  const mod = { weeks: [{ week: 2, label: "Woche 2", topic: "" }, { week: 5, label: "Woche 5", topic: "Reihen" }, { week: 7, label: "Woche 7", topic: "" }] };
  const sel = (m, cur) => F.weekOptions(m, cur).find(o => o.selected).value;
  assert.equal(sel(mod, 5), "5");
  assert.equal(sel(mod, 6), "5", "keine Unterlagen in Woche 6: die letzte davor");
  assert.equal(sel(mod, 1), "7", "vor allen Wochen: die letzte mit Unterlagen");
  assert.equal(sel(mod, null), "7");
  assert.equal(sel({ weeks: [] }, 3), "module");
  const opts = F.weekOptions(mod, 5);
  assert.equal(opts[1].label, "Woche 5 – Reihen");
  assert.deepEqual(opts.at(-1), { value: "module", label: "Ganzes Modul", week: null, selected: false });
});

test("Schloss ohne Pro AI bzw. Plus mit Weg zur Tarifseite", () => {
  const none = () => false, all = () => true;
  assert.deepEqual(F.aiAccess(all), { locked: false });
  assert.equal(F.aiAccess(none).locked, true);
  assert.equal(F.aiAccess(none).href, "#/abo");
  assert.match(F.aiAccess(none).text, /Pro AI/);
  assert.match(F.shareAccess(none).text, /StudiNow Plus/);
  const onlyPlus = n => n === "can_share_flashcards";
  assert.equal(F.aiAccess(onlyPlus).locked, true);
  assert.equal(F.shareAccess(onlyPlus).locked, false);
});

test("Anfrage fuer den KI-Auftrag", () => {
  const b = F.aiRequest({ moduleId: "3", week: "5", count: "80", topic: "  Kriterien " }, () => 0.5);
  assert.deepEqual({ ...b, request_id: undefined }, { module_id: 3, lecture_week: 5, count: 50, topic: "Kriterien", request_id: undefined });
  assert.match(b.request_id, /^fc-[a-z0-9]+-[a-z0-9]+$/);
  const w = F.aiRequest({ moduleId: 3, week: "module", count: 10, again: true });
  assert.equal(w.lecture_week, null);
  assert.equal(w.again, true);
  assert.equal("topic" in w, false);
  assert.notEqual(F.requestId(), F.requestId(() => 0.123), "neue ID je Auftrag");
});

test("Teilen: versteckte und leere Karten bleiben privat, Grenzen werden gemeldet", () => {
  const cards = [{ question: " Q1 ", answer: " A1 " }, { question: "Q2", answer: "A2", hidden: 1 }, { question: "", answer: "x" },
    { question: "Lang", answer: "x".repeat(1001) }];
  const s = F.shareCards(cards);
  assert.deepEqual(s.cards[0], { question: "Q1", answer: "A1" });
  assert.equal(s.cards.length, 2);
  assert.equal(s.tooLong, 1);
  assert.equal(s.cut, 0);
  const many = F.shareCards(Array.from({ length: 503 }, (_, i) => ({ question: `F${i}`, answer: "a" })));
  assert.equal(many.cards.length, 500);
  assert.equal(many.cut, 3);
  const stack = { module_id: 3, module_name: "Analysis I", lecture_week: 5 };
  assert.deepEqual(F.shareBody(stack, s.cards, "  "), { title: "Analysis I · Woche 5", lecture_week: 5, cards: s.cards });
  assert.equal(F.shareBody({ ...stack, lecture_week: null }, [], "t".repeat(200)).title.length, 120);
  const mine = [{ id: "a", community_key: "k", lecture_week: 5, status: "active" }, { id: "b", community_key: "k", lecture_week: null, status: "active" },
    { id: "c", community_key: "x", lecture_week: 5, status: "active" }];
  assert.equal(F.ownDeck(mine, "k", 5).id, "a");
  assert.equal(F.ownDeck(mine, "k", null).id, "b");
  assert.equal(F.ownDeck(mine, "k", 6), null);
  const spaces = [{ kind: "group", moduleId: 3, key: "g" }, { kind: "course", moduleId: 3, key: "k" }];
  assert.equal(F.spaceForModule(spaces, "3").key, "k");
  assert.equal(F.spaceForModule(spaces, 4), null);
});

test("Uebernehmen: Rumpf mit Herkunft, Rueckmeldung, Gruppen nach Woche", () => {
  const a = { deck: { id: "d1", lecture_week: 5 }, cards: [{ question: "q", answer: "a" }], origin: "community:d1" };
  assert.deepEqual(F.adoptBody(a, "7"), { module_id: 7, lecture_week: 5, cards: a.cards, origin: "community:d1" });
  assert.equal(F.adoptBody({ ...a, deck: { lecture_week: null } }, 7).lecture_week, null);
  assert.equal(F.savedText({ added: 12, skipped: 3 }), "12 Karten übernommen, 3 gab es schon");
  assert.equal(F.savedText({ added: 1, skipped: 1 }, "gespeichert"), "1 Karte gespeichert, 1 gab es schon");
  assert.equal(F.savedText({ added: 0 }), "0 Karten übernommen");
  const g = F.groupDecks([{ id: 1, lecture_week: null }, { id: 2, lecture_week: 7 }, { id: 3, lecture_week: 2 }, { id: 4, lecture_week: 7 }]);
  assert.deepEqual(g.map(x => [x.label, x.decks.map(d => d.id)]), [["Woche 2", [3]], ["Woche 7", [2, 4]], ["Ganzes Modul", [1]]]);
  assert.equal(F.deckMeta({ card_count: 1, pseudonym: "Studi-1", uses: 0, mine: false }), "1 Karte · Studi-1");
  assert.equal(F.deckMeta({ card_count: 30, pseudonym: "Studi-1", uses: 4, mine: true }), "30 Karten · Studi-1 · 4× übernommen · von dir");
  assert.match(F.communityHint({ code: "not_linked" }), /StudiNow-Konto/);
  assert.equal(F.communityHint({ message: "x" }), "x");
});

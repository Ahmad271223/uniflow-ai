// KI-Karteikarten auf Auftrag und geteilte Stapel im Community-Kanal (app/static/flashcard-stacks.js, 04.11.2026) ohne
// Browser: Anzahl und Lernwoche wie der Server (flashcard_order), Wochenauswahl, Schloss ohne Pro AI bzw. Plus, Anfrage
// fuer den KI-Auftrag, Ziel-Stapel beim Speichern, Gruppierung der geteilten Stapel nach Woche. Aus der Cloud-Sitzung
// uebernommen und an das Stapel-Modell angepasst.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as F from "../../app/static/flashcard-stacks.js";

test("Anzahl und Lernwoche wie der Server", () => {
  assert.deepEqual([null, "abc", "", 1, 5, "30", 50, 51, 999, 7.9].map(F.clampCount), [20, 20, 20, 5, 5, 30, 50, 50, 50, 7]);
  assert.deepEqual([null, "", "module", "5", 7, 0, 31, "x", 2.5].map(F.weekValue), [null, null, null, 5, 7, null, null, null, null]);
  assert.equal(F.weekLabel(null), "Allgemein");
  assert.equal(F.weekLabel(0), "Allgemein");
  assert.equal(F.weekLabel(4), "Woche 4");
});

test("Wochenauswahl: gewuenschte bzw. aktuelle Woche vorgewaehlt, sonst die letzte davor, immer auch Ganzes Modul", () => {
  const weeks = [{ week: 2, label: "Woche 2", topic: "" }, { week: 5, label: "Woche 5", topic: "Reihen" }, { week: 7, label: "Woche 7", topic: "" }];
  const sel = (cur, preset) => F.weekOptions(weeks, cur, preset).find(o => o.selected).value;
  assert.equal(sel(5), "5");
  assert.equal(sel(6), "5", "keine Unterlagen in Woche 6: die letzte davor");
  assert.equal(sel(1), "7", "vor allen Wochen: die letzte mit Unterlagen");
  assert.equal(sel(null), "7");
  assert.equal(sel(7, 2), "2", "Filter der Seite geht vor");
  assert.equal(F.weekOptions([], 3).find(o => o.selected).value, "module");
  const opts = F.weekOptions(weeks, 5);
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
  const onlyPlus = n => n === "can_use_flashcards";
  assert.equal(F.aiAccess(onlyPlus).locked, true, "KI-Auftrag ist StudiNow-KI (Pro AI)");
  assert.equal(F.shareAccess(onlyPlus).locked, false);
  assert.equal(F.aiAccess(n => n === "can_use_ai_generated_questions").locked, false);
});

test("Anfrage fuer den KI-Auftrag und Speichern in einen Stapel des Moduls", () => {
  const b = F.aiRequest({ moduleId: "3", week: "5", count: "80", topic: "  Kriterien " }, () => 0.5);
  assert.deepEqual({ ...b, request_id: undefined }, { module_id: 3, week: 5, count: 50, topic: "Kriterien", request_id: undefined });
  assert.match(b.request_id, /^fc-[a-z0-9]+-[a-z0-9]+$/);
  const w = F.aiRequest({ moduleId: 3, week: "module", count: 10, again: true });
  assert.equal(w.week, null);
  assert.equal(w.again, true);
  assert.equal("topic" in w, false);
  assert.notEqual(F.requestId(), F.requestId(() => 0.123), "neue ID je Auftrag");
  assert.equal(F.aiStackName(5), "KI · Woche 5");
  assert.equal(F.aiStackName(null), "KI · Ganzes Modul");
  const stacks = [{ id: 1, name: "KI · Woche 5", subject: "Analysis I" }, { id: 2, name: "KI · Woche 5", subject: "Physik" }];
  assert.equal(F.stackFor(stacks, "Physik", " KI · Woche 5 ").id, 2);
  assert.equal(F.stackFor(stacks, "Analysis I", "Andere"), null);
  assert.deepEqual(F.newStackBody(" KI · Woche 5 ", "Analysis I", 5), { name: "KI · Woche 5", subject: "Analysis I", week: 5, kind: "eigene" });
  assert.equal(F.newStackBody("x", "A", undefined).week, null);
  assert.equal(F.savedText(1), "1 Karte gespeichert");
  assert.equal(F.savedText(12, "übernommen"), "12 Karten übernommen");
});

test("Geteilte Stapel: Gruppen nach Woche, Kurzbeschreibung, Hinweise", () => {
  const g = F.groupShared([{ id: "a", week: null }, { id: "b", week: 7 }, { id: "c", week: 2 }, { id: "d", week: 7 }]);
  assert.deepEqual(g.map(x => [x.label, x.stacks.map(s => s.id)]), [["Woche 2", ["c"]], ["Woche 7", ["b", "d"]], ["Allgemein", ["a"]]]);
  assert.equal(F.sharedMeta({ cards: 1, pseudonym: "Studi-1", likes: 0, adopt_count: 0, mine: false }), "1 Karte · Studi-1");
  assert.equal(F.sharedMeta({ cards: 30, pseudonym: "Studi-1", likes: 2, adopt_count: 4, mine: true }), "30 Karten · Studi-1 · 2 ♥ · 4× übernommen · von dir");
  assert.match(F.communityHint({ code: "not_linked" }), /StudiNow-Konto/);
  assert.match(F.communityHint({ code: "module_not_here" }), /eigenes Modul/);
  assert.equal(F.communityHint({ message: "x" }), "x");
});

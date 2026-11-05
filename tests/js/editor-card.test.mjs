// "Als Karteikarte" aus markiertem PDF-Text (app/static/editor-card.js, 05.11.2026), ohne Browser: Vorderseite aus dem
// Text, Pruefung, Rumpf fuer POST /api/flashcards, Stapel-Auswahl.
import test from "node:test";
import assert from "node:assert/strict";
import { frontOf, validate, cardBody, stackOptions, FRONT_MAX } from "../../app/static/editor-card.js";

test("Vorderseite: Zeilenumbrueche und Silbentrennung aus der PDF werden geglaettet", () => {
  assert.equal(frontOf("Ein Eigenwert ist\nein Skalar λ,   der\n\nA v = λ v erfüllt."), "Ein Eigenwert ist ein Skalar λ, der A v = λ v erfüllt.");
  assert.equal(frontOf("Rekur-\nsion ist die Selbst-\nbezüglichkeit"), "Rekursion ist die Selbstbezüglichkeit");
  assert.equal(frontOf("Wert -\n3 bleibt"), "Wert - 3 bleibt", "Minuszeichen vor Ziffern ist keine Silbentrennung");
  assert.equal(frontOf("  "), ""); assert.equal(frontOf(null), "");
  const long = frontOf("Wort ".repeat(400));
  assert.ok(long.length <= FRONT_MAX && long.endsWith("…"));
});

test("Karte braucht Frage und Antwort", () => {
  assert.equal(validate({ question: "Was ist ein Eigenwert?", answer: "" }), "Frage und Antwort sind nötig.");
  assert.equal(validate({ question: "  ", answer: "x" }), "Frage und Antwort sind nötig.");
  assert.equal(validate(null), "Frage und Antwort sind nötig.");
  assert.equal(validate({ question: "F", answer: "A" }), null);
});

test("Rumpf: Dokument, getrimmte Karte, Stapel nur wenn gewaehlt", () => {
  assert.deepEqual(cardBody("f1", { question: " F ", answer: " A ", stack: "" }), { file_id: "f1", cards: [{ question: "F", answer: "A" }] });
  assert.deepEqual(cardBody("f1", { question: "F", answer: "A", stack: "7" }), { file_id: "f1", cards: [{ question: "F", answer: "A" }], stack_id: 7 });
  assert.equal(cardBody(null, { question: "F", answer: "A" }).file_id, null);
  assert.equal("stack_id" in cardBody("f1", { question: "F", answer: "A", stack: "abc" }), false);
});

test("Stapel-Auswahl: automatisch zuerst, dann die vorhandenen mit Modul", () => {
  assert.deepEqual(stackOptions(null).map(o => o.id), [""]);
  const o = stackOptions([{ id: 3, name: "Vorlesung Woche 2", subject: "Analysis" }, { id: 4, name: "Allgemein", subject: null }]);
  assert.deepEqual(o.map(x => [x.id, x.name]), [["", "Stapel dieses Dokuments (automatisch)"], ["3", "Vorlesung Woche 2 · Analysis"], ["4", "Allgemein"]]);
});

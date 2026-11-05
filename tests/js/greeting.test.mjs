import { test } from "node:test";
import assert from "node:assert/strict";
import { salutation, text, displayName, pick, givenName } from "../../app/static/greeting.js";

test("Anrede nach der Stunde wie UFGreeting", () => {
  assert.equal(salutation(0), "Guten Morgen");
  assert.equal(salutation(10), "Guten Morgen");
  assert.equal(salutation(11), "Hallo");
  assert.equal(salutation(17), "Hallo");
  assert.equal(salutation(18), "Guten Abend");
});

test("Satz mit und ohne Namen", () => {
  assert.equal(text("Ahmad", 12), "Hallo Ahmad – lass uns gemeinsam lernen.");
  assert.equal(text("Ahmad", 8), "Guten Morgen, Ahmad – lass uns gemeinsam lernen.");
  assert.equal(text("Lea", 20), "Guten Abend, Lea – lass uns gemeinsam lernen.");
  assert.equal(text("", 12), "Hallo – lass uns gemeinsam lernen.");
  assert.equal(text("  ", 8), "Guten Morgen – lass uns gemeinsam lernen.");
});

test("lange Namen werden auf 23 Zeichen plus … gekürzt", () => {
  assert.equal(displayName("Maximiliane-Alexandra Müller"), "Maximiliane-Alexandra M…");
  assert.equal([...displayName("x".repeat(30))].length, 24);
  assert.equal(displayName("x".repeat(24)), "x".repeat(24));
  assert.equal(displayName(null), null);
});

test("Reihenfolge der Quellen: Rufname, Kontoname, erstes Wort des Anzeigenamens", () => {
  assert.equal(pick({ rufname: "Ahmad", accountName: "A. F.", userName: "Ahmad F." }), "Ahmad");
  assert.equal(pick({ rufname: " ", accountName: "Lea", userName: "Ahmad F." }), "Lea");
  assert.equal(pick({ userName: "Ahmad F." }), "Ahmad");
  assert.equal(pick({}), null);
  assert.equal(givenName("Ahmad Fakih"), "Ahmad");
});

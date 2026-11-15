// KI-Credits mit zwei Toepfen in der Web-Oberflaeche (app/static/credit-packs-logic.js, 15.11.2026) gegen den Vertrag
// packages/shared-contracts/fixtures/credit-packs/contract.json (aus app/credit_texts.py): dieselben Texte wie die
// Apple-App. Im Web und unter Windows wird der Stand gezeigt, gekauft wird in der App.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { balanceLine, keepNote, dormantNote, available, resetDay, showsCredits, webNote, scope, scopeNote, KEEP, WEB_HINT, NO_CREDITS, CHAT_ONLY } from "../../app/static/credit-packs-logic.js";

const contract = JSON.parse(readFileSync(new URL("../../packages/shared-contracts/fixtures/credit-packs/contract.json", import.meta.url), "utf8"));
const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Texte zu beiden Toepfen stimmen in jedem Fall des Vertrags", () => {
  assert.ok(contract.balance_cases.length >= 10);
  for (const c of contract.balance_cases) {
    assert.equal(balanceLine(c.credits), c.expect.line, c.name);
    assert.equal(keepNote(c.credits), c.expect.keep_note, c.name);
    assert.equal(dormantNote(c.credits), c.expect.dormant_note, c.name);
    assert.equal(available(c.credits), c.expect.available, c.name);
    assert.equal(resetDay(c.credits.resets_at), c.expect.reset_day, c.name);
    assert.equal(scope(c.credits), c.expect.scope, c.name);
    assert.equal(scopeNote(c.credits), c.expect.scope_note, c.name);
  }
  assert.equal(CHAT_ONLY, contract.texts.chat_only);
  assert.equal(KEEP, contract.texts.keep);
  assert.equal(WEB_HINT, contract.texts.web_hint);
  assert.equal(NO_CREDITS, contract.texts.no_credits);
  assert.equal(balanceLine(null), null);
});

test("Zusatz zum Monat steht in Klammern, mit Ueberschrift 'Credits' davor", () => {
  const c = { allowance: 100, remaining: 37, purchased: 80, purchased_usable: true };
  assert.equal(balanceLine(c, { monthNote: "neu am 1. Dezember", labelled: true }), "Credits diesen Monat: 37 von 100 (neu am 1. Dezember) · Gekauft: 80");
  assert.equal(balanceLine(c), "Diesen Monat: 37 von 100 · Gekauft: 80");
});

test("Tarifseite: Stand zeigen, kaufen nur in der App", () => {
  const flow = step => contract.flows.find(f => f.step === step).response;
  const abo = read("views-abo.js");
  const pro = flow("Verbrauch: erst die 100 Monats-Credits, dann 30 gekaufte");
  assert.ok(showsCredits(pro.credits));
  assert.equal(balanceLine(pro.credits), "Diesen Monat: 0 von 100 · Gekauft: 270");
  assert.equal(webNote(pro.credits, pro.credit_packs), `${KEEP} ${pro.credit_packs.purchase.web.note}`);
  assert.ok(pro.credit_packs.purchase.web.note.includes("iPhone und iPad") && pro.credit_packs.purchase.web.available === false);
  // ohne Angabe des Dienstes (Windows-App mit aelterem Zwischenstand): der feste Hinweis
  assert.equal(webNote({ allowance: 100, remaining: 5, purchased: 0, resets_at: "2026-12-01T00:00:00+01:00" }, undefined),
    `Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder. ${WEB_HINT}`);
  const resting = flow("Pro AI ist vorbei: die gekauften Credits bleiben beim Konto und ruhen");
  assert.ok(showsCredits(resting.credits) && webNote(resting.credits, resting.credit_packs).startsWith("Du hast noch 191 gekaufte Credits."));
  // Plus (15.11.2026): nur der gekaufte Topf, dazu der Satz, was die Credits dort koennen (nur der KI-Chat)
  const plus = flow("Wechsel zu Plus: die gekauften Credits bleiben, gelten aber nur noch fuer den KI-Chat");
  assert.equal(balanceLine(plus.credits), "Gekauft: 200");
  assert.equal(webNote(plus.credits, plus.credit_packs), `${KEEP} ${CHAT_ONLY} ${plus.credit_packs.purchase.web.note}`);
  assert.ok(showsCredits({ allowance: 0, remaining: 0, purchased: 0, purchased_usable: true, purchased_scope: "chat" }), "Plus sieht die Zeile auch mit 0");
  assert.ok(abo.includes("KI-Chat mit gekauften Credits") && abo.includes("weitere Credits zum Nachkaufen"));
  assert.ok(!showsCredits({ allowance: 0, remaining: 0, purchased: 0 }) && !showsCredits(null));
  // die Seite bindet die Zeile ein und bietet keinen Kauf an (kein Knopf, kein Bezahlweg fuer Credits)
  assert.ok(abo.includes('id="aboCredits"') && abo.includes("webNote(me.credits, me.credit_packs)"));
  assert.ok(!/credits\/apple|data-buy-credits/.test(abo));
});

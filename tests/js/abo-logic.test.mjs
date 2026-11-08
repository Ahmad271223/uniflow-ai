import { test } from "node:test";
import assert from "node:assert/strict";
import * as A from "../../app/static/abo-logic.js";

const plus = { price_cents: 199, price_cents_yearly: 2199 }, free = { price_cents: 0, price_cents_yearly: null };

test("Preiszeile monatlich und jaehrlich wie auf dem iPad", () => {
  assert.deepEqual(A.priceLine(plus, "month"), { main: "1,99 €", unit: " / Monat", other: "oder 21,99 € / Jahr" });
  assert.deepEqual(A.priceLine(plus, "year"), { main: "21,99 €", unit: " / Jahr", other: "entspricht 1,83 € / Monat · oder 1,99 € / Monat" });
  assert.deepEqual(A.priceLine(free, "year"), { main: "0 €", unit: "", other: "" }, "Free hat keinen Jahrespreis");
  assert.equal(A.priceLine({ price_cents: 399, price_cents_yearly: 4199 }, "year").main, "41,99 €");
  assert.equal(A.hasYearly({ plans: { free, plus } }), true);
  assert.equal(A.hasYearly({ plans: { free } }), false);
  assert.equal(A.normalizeInterval("year"), "year");
  assert.equal(A.normalizeInterval("quatsch"), "month");
});

test("Kaufknopf nur, wenn Stripe den Preis des Zeitraums kennt", () => {
  const web = { available: true, plans: ["plus", "pro_ai"], yearly_plans: ["pro_ai"] };
  assert.equal(A.canBuy(web, "plus", "month"), true);
  assert.equal(A.canBuy(web, "plus", "year"), false);
  assert.equal(A.canBuy(web, "pro_ai", "year"), true);
  assert.equal(A.canBuy({ available: false, plans: ["plus"] }, "plus", "month"), false);
  assert.equal(A.buyHint(web, "plus", "year"), "Jährliche Zahlung folgt – monatlich ist möglich.");
  assert.equal(A.buyHint(web, "pro_ai", "year"), "");
  assert.deepEqual(A.checkoutBody("plus", "year"), { plan: "plus", interval: "year" });
  assert.deepEqual(A.checkoutBody("plus", undefined), { plan: "plus", interval: "month" });
});

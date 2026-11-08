// Abo-Seite in Web und Windows (08.11.2026): Umschalter Monatlich/Jaehrlich wie auf dem iPad (app/plans.py kennt
// price_cents_yearly; die Jahrespreise bei Stripe stehen in LERNAPP_STRIPE_PRICES, purchase.web.yearly_plans).
export const INTERVALS = ["month", "year"];
export const INTERVAL_TXT = { month: "Monatlich", year: "Jährlich" };

export const euro = c => c === 0 ? "0 €" : `${(c / 100).toFixed(2).replace(".", ",")} €`;

/** Zeitraum aus dem gemerkten Wert; alles andere wird "month" */
export function normalizeInterval(v) { return INTERVALS.includes(v) ? v : "month"; }

/** Gibt es ueberhaupt einen Tarif mit Jahrespreis? Dann erscheint der Umschalter */
export function hasYearly(contract) {
  return Object.values(contract?.plans || {}).some(p => p && p.price_cents_yearly);
}

/** Preiszeile einer Karte: gewaehlter Zeitraum gross, der andere klein daneben (jaehrlich zusaetzlich "entspricht … / Monat") */
export function priceLine(p, interval) {
  if (!p) return { main: "", unit: "", other: "" };
  if (interval === "year" && p.price_cents_yearly) {
    const perMonth = Math.round(p.price_cents_yearly / 12);
    return { main: euro(p.price_cents_yearly), unit: " / Jahr", other: `entspricht ${euro(perMonth)} / Monat · oder ${euro(p.price_cents)} / Monat` };
  }
  return { main: euro(p.price_cents), unit: p.price_cents ? " / Monat" : "", other: p.price_cents_yearly ? `oder ${euro(p.price_cents_yearly)} / Jahr` : "" };
}

/** Kann dieser Tarif im gewaehlten Zeitraum ueber Stripe abgeschlossen werden? */
export function canBuy(web, key, interval) {
  if (!web || !web.available) return false;
  const list = interval === "year" ? (web.yearly_plans || []) : (web.plans || []);
  return list.includes(key);
}

/** Hinweis, wenn der Zeitraum fuer den Tarif (noch) nicht abschliessbar ist, sonst "" */
export function buyHint(web, key, interval) {
  if (interval === "year" && canBuy(web, key, "month") && !canBuy(web, key, "year")) return "Jährliche Zahlung folgt – monatlich ist möglich.";
  return "";
}

/** Body fuer POST /api/billing/plan-choice bzw. /api/app-account/checkout */
export function checkoutBody(key, interval) { return { plan: key, interval: normalizeInterval(interval) }; }

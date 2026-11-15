// KI-Credits mit zwei Toepfen in der Web-Oberflaeche (Auftrag des Inhabers 15.11.2026, docs/KI-CREDITS-2026-11-15.md):
// Monats-Credits (jeden Monat neu) und gekaufte Credits (verfallen nie). Reine Logik ohne DOM; die Texte entsprechen
// app/credit_texts.py und CreditPacks.swift (tests/js/credit-packs.test.mjs prueft sie gegen
// packages/shared-contracts/fixtures/credit-packs/contract.json). Kaufen kann man im Web und unter Windows noch nicht:
// hier steht der Stand beider Toepfe und der Hinweis auf die App.

const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];
export const KEEP = "Gekaufte Credits verfallen nicht.";
export const WEB_HINT = "Credits kaufst du in der App für iPhone und iPad.";
export const NO_CREDITS = "Keine Credits in deinem Tarif";

const int = v => Math.max(0, Math.trunc(Number(v) || 0));

/** "1. Dezember" aus `resets_at` (ISO, Beginn des naechsten Monats in Berlin); null ohne lesbares Datum */
export function resetDay(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || "")); if (!m) return null;
  const mo = +m[2], d = +m[3]; if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return `${d}. ${MONTHS[mo - 1]}`;
}

/** Stand beider Toepfe: "Diesen Monat: 37 von 100 · Gekauft: 80". `monthNote` steht in Klammern hinter dem Monat
 *  ("neu am 1. Dezember"), `labelled` setzt "Credits" davor. Ohne Monats-Credits nur der gekaufte Topf, ganz ohne
 *  Credits "Keine Credits in deinem Tarif"; null ohne Stand. */
export function balanceLine(c, { monthNote = "", labelled = false } = {}) {
  if (!c || typeof c !== "object") return null;
  const allowance = int(c.allowance), remaining = int(c.remaining), bought = int(c.purchased);
  if (allowance > 0) return `${labelled ? "Credits diesen Monat" : "Diesen Monat"}: ${remaining} von ${allowance}${monthNote ? ` (${monthNote})` : ""} · Gekauft: ${bought}`;
  if (bought > 0) return `${labelled ? "Credits gekauft" : "Gekauft"}: ${bought}${c.purchased_usable ? "" : " · nutzbar mit StudiNow Pro AI"}`;
  return NO_CREDITS;
}

/** "Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder." */
export function keepNote(c) {
  const allowance = int(c?.allowance), day = resetDay(c?.resets_at);
  return allowance > 0 && day ? `${KEEP} Deine ${allowance} Monats-Credits gibt es am ${day} wieder.` : KEEP;
}

/** Hinweis, wenn gekaufte Credits ruhen (Pro AI ist vorbei); null sonst */
export function dormantNote(c) {
  if (!c || typeof c !== "object" || c.purchased_usable || int(c.purchased) === 0) return null;
  return `Du hast noch ${int(c.purchased)} gekaufte Credits. Sie bleiben bei deinem Konto und sind wieder nutzbar, sobald StudiNow Pro AI läuft.`;
}

/** Was jetzt fuer die KI da ist: Rest des Monats plus nutzbare gekaufte Credits */
export function available(c) {
  if (!c || typeof c !== "object") return 0;
  return int(c.remaining) + (c.purchased_usable ? int(c.purchased) : 0);
}

/** Zeigt die Tarifseite die Zeile zu den Credits? Mit Monats-Credits oder gekauften Credits */
export const showsCredits = c => !!c && typeof c === "object" && (int(c.allowance) > 0 || int(c.purchased) > 0);

/** Text unter dem Stand auf der Tarifseite: was mit den Toepfen gilt und wo man kauft (`credit_packs.purchase.web.note`
 *  des Dienstes, sonst der feste Hinweis) */
export function webNote(c, packs) {
  const where = packs?.purchase?.web?.note || WEB_HINT;
  return `${dormantNote(c) || keepNote(c)} ${where}`;
}

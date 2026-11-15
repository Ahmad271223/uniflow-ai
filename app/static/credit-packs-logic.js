// KI-Credits mit zwei Toepfen in der Web-Oberflaeche (Auftrag des Inhabers 15.11.2026, docs/KI-CREDITS-2026-11-15.md):
// Monats-Credits (jeden Monat neu) und gekaufte Credits (verfallen nie). Reine Logik ohne DOM; die Texte entsprechen
// app/credit_texts.py und CreditPacks.swift (tests/js/credit-packs.test.mjs prueft sie gegen
// packages/shared-contracts/fixtures/credit-packs/contract.json). Kaufen kann man im Web und unter Windows noch nicht:
// hier steht der Stand beider Toepfe und der Hinweis auf die App.
// Wofuer gekaufte Credits gelten (`purchased_scope`, Entscheidung des Inhabers 15.11.2026): "all" mit Pro AI und in der
// Probe, "chat" mit Plus (nur Fragen an die KI), "none" mit Free (sie ruhen beim Konto).

const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];
export const KEEP = "Gekaufte Credits verfallen nicht.";
export const WEB_HINT = "Credits kaufst du in der App für iPhone und iPad.";
export const NO_CREDITS = "Keine Credits in deinem Tarif";
export const CHAT_ONLY = "Mit Credits kannst du Fragen an die KI stellen. Erklärungen, Karteikarten und Tests gibt es mit Pro AI.";

/** Wofuer die gekauften Credits gelten: all | chat | none (`purchased_scope`; ohne das Feld aus `purchased_usable`) */
export function scope(c) {
  if (!c || typeof c !== "object") return "none";
  if (["all", "chat", "none"].includes(c.purchased_scope)) return c.purchased_scope;
  return c.purchased_usable ? "all" : "none";
}

/** Satz fuer Plus: was gekaufte Credits dort koennen; null, wenn sie fuer alles gelten */
export const scopeNote = c => scope(c) === "chat" ? CHAT_ONLY : null;

const int = v => Math.max(0, Math.trunc(Number(v) || 0));

/** "1. Dezember" aus `resets_at` (ISO, Beginn des naechsten Monats in Berlin); null ohne lesbares Datum */
export function resetDay(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || "")); if (!m) return null;
  const mo = +m[2], d = +m[3]; if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return `${d}. ${MONTHS[mo - 1]}`;
}

/** Stand beider Toepfe: "Diesen Monat: 37 von 100 · Gekauft: 80". `monthNote` steht in Klammern hinter dem Monat
 *  ("neu am 1. Dezember"), `labelled` setzt "Credits" davor. Ohne Monats-Credits nur der gekaufte Topf (bei Plus auch
 *  mit 0, ruhend mit dem Weg dahin), ganz ohne Credits "Keine Credits in deinem Tarif"; null ohne Stand. */
export function balanceLine(c, { monthNote = "", labelled = false } = {}) {
  if (!c || typeof c !== "object") return null;
  const allowance = int(c.allowance), remaining = int(c.remaining), bought = int(c.purchased);
  if (allowance > 0) return `${labelled ? "Credits diesen Monat" : "Diesen Monat"}: ${remaining} von ${allowance}${monthNote ? ` (${monthNote})` : ""} · Gekauft: ${bought}`;
  const head = `${labelled ? "Credits gekauft" : "Gekauft"}: ${bought}`;
  if (scope(c) !== "none") return head;
  if (bought > 0) return `${head} · nutzbar mit StudiNow Plus oder Pro AI`;
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
  return `Du hast noch ${int(c.purchased)} gekaufte Credits. Sie bleiben bei deinem Konto und sind wieder nutzbar, sobald StudiNow Plus oder Pro AI läuft.`;
}

/** Was jetzt fuer die KI da ist: Rest des Monats plus nutzbare gekaufte Credits */
export function available(c) {
  if (!c || typeof c !== "object") return 0;
  return int(c.remaining) + (c.purchased_usable ? int(c.purchased) : 0);
}

/** Zeigt die Tarifseite die Zeile zu den Credits? Mit Monats-Credits, gekauften Credits oder mit Plus (darf kaufen) */
export const showsCredits = c => !!c && typeof c === "object" && (int(c.allowance) > 0 || int(c.purchased) > 0 || scope(c) === "chat");

/** Text unter dem Stand auf der Tarifseite: was mit den Toepfen gilt und wo man kauft (`credit_packs.purchase.web.note`
 *  des Dienstes, sonst der feste Hinweis) */
export function webNote(c, packs) {
  const where = packs?.purchase?.web?.note || WEB_HINT;
  const what = scopeNote(c);
  return `${dormantNote(c) || keepNote(c)}${what ? ` ${what}` : ""} ${where}`;
}

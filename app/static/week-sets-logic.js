// Fertige Fragen je Vorlesungswoche (Pro AI): reine Regeln ohne Browser, geprueft in tests/js/week-sets.test.mjs.
// Dienst: app/week_library_api.py (GET/POST /api/library/week-sets/...), Ablauf in docs/BIBLIOTHEK-WOCHENFRAGEN.md.

export const RIGHT = "can_use_prepared_week_sets";
export const POLL_MS = 5000;           // so oft fragt die Karte nach, solange die KI vorbereitet
export const POLL_MAX = 60;            // hoechstens 5 Minuten, dann "spaeter noch einmal"

/** Was die Karte einer Woche zeigt: locked | service_only | hidden | show | poll | auto_prepare | offer_prepare | retry | info */
export function cardMode({ hosted, allowed, status, current }) {
  if (!hosted) return current ? "service_only" : "hidden";
  if (!allowed) return "locked";
  switch (status) {
    case "ready": return "show";
    case "preparing": return "poll";
    case "none": return current ? "auto_prepare" : "offer_prepare";
    case "failed": return "retry";
    case "missing_content": return "info";
    default: return "hidden";            // no_material: keine Dateien in der Woche, keine Karte
  }
}

const CODE_TEXT = {
  ai_library_budget_exhausted: "Die Bibliothek hat ihr KI-Budget für diesen Monat aufgebraucht. Neue Wochen kommen im nächsten Monat dazu.",
  library_prep_limit: "Heute hast du schon viele Wochen vorbereiten lassen. Morgen geht es weiter.",
  generation_failed: "Die KI hat nicht genug brauchbare Fragen geliefert. Wir versuchen es später noch einmal.",
  ai_not_configured: "Die StudiNow-KI ist im Dienst noch nicht eingerichtet.",
  ai_not_configured_prices: "Die StudiNow-KI ist im Dienst noch nicht freigeschaltet.",
  ai_provider_error: "Die KI war gerade nicht erreichbar. Wir versuchen es später noch einmal.",
  ai_provider_unreachable: "Die KI war gerade nicht erreichbar. Wir versuchen es später noch einmal.",
  missing_content: "Einige Dateien dieser Woche sind noch nicht geladen. Öffne sie einmal oder warte auf den nächsten Abgleich.",
  no_material: "Für diese Woche gibt es noch keine Folien oder Übungsblätter.",
};

/** Kurzer, einfacher Text zu einem Status oder Fehlercode (null = nichts Besonderes) */
export function statusText(status, code) {
  if (code && CODE_TEXT[code]) return CODE_TEXT[code];
  if (status === "preparing") return "Die StudiNow-KI bereitet die Fragen dieser Woche gerade vor. Das dauert meist ein bis zwei Minuten.";
  if (status === "failed") return CODE_TEXT.generation_failed;
  if (status === "none") return "Für diese Woche sind noch keine fertigen Fragen da.";
  return CODE_TEXT[status] || null;
}

/** "3 Sätze · je 15 Fragen" */
export function setsLabel(sets) {
  const n = (sets || []).length;
  if (!n) return "";
  const size = Math.max(...sets.map(s => s.count || 0));
  return `${n} ${n === 1 ? "Satz" : "Sätze"} · je ${size} Fragen`;
}

/** Weiter nachfragen? Nur solange vorbereitet wird und die Grenze nicht erreicht ist */
export const keepPolling = (status, tries) => status === "preparing" && tries < POLL_MAX;

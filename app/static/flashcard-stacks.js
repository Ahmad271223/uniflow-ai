// Karteikarten-Stapel (04.11.2026), ohne DOM: Beschriftungen, Auswahl von Modul und Lernwoche, Anfragen fuer den
// KI-Auftrag (POST /api/ai/flashcards mit module_id, Pro AI), Teilen in der Community (POST /api/community/communities/
// {key}/decks, Plus) und Uebernehmen (POST /api/community/decks/{id}/adopt, dann POST /api/flashcards/stack mit Herkunft).
// Die Seite zeichnet flashcard-stacks-ui.js; tests/js/flashcard-stacks.test.mjs prueft diese Regeln.

export const COUNT = { min: 5, max: 50, def: 20 };
export const SHARE = { maxCards: 500, maxSide: 1000, maxTitle: 120 };

/** Anzahl fuer den KI-Auftrag: ganze Zahl in COUNT.min..COUNT.max, Unlesbares -> Vorgabe (wie flashcard_stacks.stack_count) */
export function clampCount(n) {
  const v = n === null || n === undefined || typeof n === "boolean" || (typeof n === "string" && n.trim() === "") ? NaN : Math.trunc(Number(n));
  if (!Number.isFinite(v)) return COUNT.def;
  return Math.max(COUNT.min, Math.min(COUNT.max, v));
}

/** Woche aus einem Formularwert: "module" oder leer = ganzes Modul (null), sonst Zahl 1..30 */
export function weekValue(v) {
  if (v === null || v === undefined || v === "" || v === "module") return null;
  const n = Number(v);
  return Number.isInteger(n) && n >= 1 && n <= 30 ? n : null;
}

export const weekLabel = w => (w === null || w === undefined ? "Ganzes Modul" : `Woche ${w}`);

/** Titel eines Stapels: "Analysis I · Woche 5" bzw. "Analysis I · Ganzes Modul" */
export const stackTitle = s => `${s.module_name || "Ohne Modul"} · ${s.module_id == null ? "Weitere Karten" : weekLabel(s.lecture_week)}`;

/** Auswahl der Lernwoche fuer ein Modul: Wochen mit Unterlagen (aus GET /api/flashcards/stacks), die aktuelle Woche
 *  vorgewaehlt, falls vorhanden, sonst die letzte Woche mit Unterlagen; dazu "Ganzes Modul". */
export function weekOptions(module, currentWeek) {
  const weeks = (module?.weeks || []).map(w => ({ value: String(w.week), label: w.topic ? `${w.label} – ${w.topic}` : w.label, week: w.week }));
  const pick = weeks.find(w => w.week === currentWeek) || weeks.filter(w => currentWeek == null || w.week <= currentWeek).pop() || weeks[weeks.length - 1];
  return [...weeks.map(w => ({ ...w, selected: w === pick })), { value: "module", label: "Ganzes Modul", week: null, selected: !pick }];
}

/** Zugang zum KI-Auftrag: ohne Pro AI ein Schloss mit Weg zur Tarifseite */
export function aiAccess(can) {
  return can("can_generate_ai_flashcards") ? { locked: false } :
    { locked: true, text: "KI-Karteikarten gibt es mit StudiNow Pro AI: Fach, Lernwoche und Anzahl wählen, die KI macht den Rest.", href: "#/abo" };
}

export function shareAccess(can) {
  return can("can_share_flashcards") ? { locked: false } :
    { locked: true, text: "Karteikarten teilen und die anderer nutzen gibt es ab StudiNow Plus.", href: "#/abo" };
}

/** Neue Anfrage-ID je Auftrag (Kontingent: eine Wiederholung derselben ID wird nicht doppelt berechnet) */
export const requestId = (rand = Math.random) => `fc-${Date.now().toString(36)}-${Math.floor(rand() * 1e9).toString(36)}`;

/** Rumpf fuer POST /api/ai/flashcards (KI-Auftrag) */
export function aiRequest({ moduleId, week, count, topic, again = false }, rand) {
  const body = { module_id: Number(moduleId), lecture_week: weekValue(week), count: clampCount(count), request_id: requestId(rand) };
  const t = String(topic || "").trim();
  if (t) body.topic = t.slice(0, 300);
  if (again) body.again = true;
  return body;
}

/** Community eines Moduls aus loadSpaces() (community-spaces.js): Kurs-Community mit derselben moduleId */
export const spaceForModule = (spaces, moduleId) => (spaces || []).find(s => s.kind === "course" && moduleId != null && Number(s.moduleId) === Number(moduleId)) || null;

/** Karten zum Teilen: versteckte nicht, leere nicht; zu lange Seiten und zu viele Karten werden gemeldet */
export function shareCards(cards) {
  const usable = (cards || []).filter(c => !(c.hidden && Number(c.hidden) !== 0) && String(c.question || "").trim() && String(c.answer || "").trim())
    .map(c => ({ question: String(c.question).trim(), answer: String(c.answer).trim() }));
  const tooLong = usable.filter(c => c.question.length > SHARE.maxSide || c.answer.length > SHARE.maxSide).length;
  return { cards: usable.slice(0, SHARE.maxCards), tooLong, cut: Math.max(0, usable.length - SHARE.maxCards) };
}

/** Rumpf fuer POST /api/community/communities/{key}/decks */
export function shareBody(stack, cards, title) {
  const t = String(title || "").trim() || stackTitle(stack);
  return { title: t.slice(0, SHARE.maxTitle), lecture_week: stack.lecture_week ?? null, cards };
}

/** Eigener, schon geteilter Stapel derselben Community und Woche (GET /api/community/decks/mine) -> Aktualisieren */
export const ownDeck = (mine, key, week) => (mine || []).find(d => d.community_key === key && (d.lecture_week ?? null) === (week ?? null) && d.status !== "withdrawn") || null;

/** Rumpf fuer POST /api/flashcards/stack nach dem Uebernehmen ({deck, cards, origin} von .../adopt) */
export const adoptBody = (adopted, moduleId) => ({ module_id: Number(moduleId), lecture_week: adopted.deck.lecture_week ?? null, cards: adopted.cards, origin: adopted.origin });

/** Rueckmeldung nach dem Speichern: "12 Karten übernommen, 3 gab es schon" */
export function savedText({ added = 0, skipped = 0 } = {}, verb = "übernommen") {
  const a = added === 1 ? "1 Karte" : `${added} Karten`;
  return skipped ? `${a} ${verb}, ${skipped === 1 ? "1 gab" : `${skipped} gab`} es schon` : `${a} ${verb}`;
}

/** Stapel der Community nach Woche gruppiert: Wochen aufsteigend, "Ganzes Modul" zuletzt */
export function groupDecks(decks) {
  const groups = new Map();
  for (const d of decks || []) {
    const k = d.lecture_week ?? "module";
    if (!groups.has(k)) groups.set(k, { week: d.lecture_week ?? null, label: weekLabel(d.lecture_week ?? null), decks: [] });
    groups.get(k).decks.push(d);
  }
  return [...groups.values()].sort((a, b) => (a.week === null) - (b.week === null) || (a.week ?? 0) - (b.week ?? 0));
}

/** Kurzbeschreibung eines geteilten Stapels */
export const deckMeta = d => [d.card_count === 1 ? "1 Karte" : `${d.card_count} Karten`, d.pseudonym, d.uses ? `${d.uses}× übernommen` : null, d.mine ? "von dir" : null].filter(Boolean).join(" · ");

/** Hinweis zu einem Fehler beim Teilen/Laden aus der Community, der einen Weg zeigt */
export function communityHint(e) {
  if (e?.code === "not_linked") return "Verbinde zuerst dein StudiNow-Konto (Einstellungen → StudiNow-Konto), dann kannst du Karteikarten teilen und übernehmen.";
  if (e?.code === "not_a_member") return "Tritt zuerst der Community dieses Moduls bei.";
  return e?.message || "Das hat nicht geklappt.";
}

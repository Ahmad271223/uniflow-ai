// KI-Karteikarten auf Auftrag und geteilte Stapel im Community-Kanal (04.11.2026), ohne DOM. Aus der Cloud-Sitzung
// uebernommen und an das Stapel-Modell angepasst (docs/KARTEIKARTEN-STAPEL-2026-11-04.md): der KI-Auftrag
// (POST /api/ai/flashcards mit module_id, Pro AI) liefert einen Vorschlag, gespeichert wird in einen Stapel des Moduls
// (POST /api/flashcard-stacks, dann POST /api/flashcards mit stack_id). Geteilte Stapel kommen von
// /api/community/card-stacks (Feld `week`, null = Allgemein). Die Oberflaeche zeichnen flashcard-stacks-ui.js und
// community-decks-ui.js; tests/js/flashcard-stacks.test.mjs prueft diese Regeln.

export const COUNT = { min: 5, max: 50, def: 20 };
export const AI_RIGHT = "can_use_ai_generated_questions";
export const SHARE_RIGHT = "can_use_flashcards";

/** Anzahl fuer den KI-Auftrag: ganze Zahl in COUNT.min..COUNT.max, Unlesbares -> Vorgabe (wie flashcard_order.stack_count) */
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

export const weekLabel = w => (w === null || w === undefined || w === 0 ? "Allgemein" : `Woche ${w}`);

/** Auswahl der Lernwoche (GET /api/ai/flashcards/weeks): Wochen mit Unterlagen, die gewuenschte bzw. aktuelle Woche
 *  vorgewaehlt, sonst die letzte Woche mit Unterlagen; dazu "Ganzes Modul". */
export function weekOptions(weeks, currentWeek, preset) {
  const ws = (weeks || []).map(w => ({ value: String(w.week), label: w.topic ? `${w.label} – ${w.topic}` : w.label, week: w.week }));
  const want = preset ?? currentWeek;
  const pick = ws.find(w => w.week === want) || ws.filter(w => want == null || w.week <= want).pop() || ws[ws.length - 1];
  return [...ws.map(w => ({ ...w, selected: w === pick })), { value: "module", label: "Ganzes Modul", week: null, selected: !pick }];
}

/** Zugang zum KI-Auftrag: ohne Pro AI ein Schloss mit Weg zur Tarifseite */
export function aiAccess(can) {
  return can(AI_RIGHT) ? { locked: false } :
    { locked: true, text: "KI-Karteikarten gibt es mit StudiNow Pro AI: Fach, Lernwoche und Anzahl wählen, die KI macht den Rest.", href: "#/abo" };
}

/** Teilen und Uebernehmen: ab Plus (eigene Karteikarten) */
export function shareAccess(can) {
  return can(SHARE_RIGHT) ? { locked: false } :
    { locked: true, text: "Karteikarten teilen und die anderer übernehmen gibt es ab StudiNow Plus.", href: "#/abo" };
}

/** Neue Anfrage-ID je Auftrag (eine Wiederholung derselben ID wird nicht doppelt berechnet) */
export const requestId = (rand = Math.random) => `fc-${Date.now().toString(36)}-${Math.floor(rand() * 1e9).toString(36)}`;

/** Rumpf fuer POST /api/ai/flashcards (KI-Auftrag) */
export function aiRequest({ moduleId, week, count, topic, again = false }, rand) {
  const body = { module_id: Number(moduleId), week: weekValue(week), count: clampCount(count), request_id: requestId(rand) };
  const t = String(topic || "").trim();
  if (t) body.topic = t.slice(0, 300);
  if (again) body.again = true;
  return body;
}

/** Name des Stapels fuer die Karten des Auftrags: "KI · Woche 5" bzw. "KI · Ganzes Modul" */
export const aiStackName = week => `KI · ${week == null ? "Ganzes Modul" : `Woche ${week}`}`;

/** Ziel beim Speichern: vorhandener Stapel mit diesem Namen im Modul, sonst null (= neu anlegen) */
export const stackFor = (stacks, subject, name) =>
  (stacks || []).find(s => s.subject === subject && String(s.name).trim() === String(name).trim()) || null;

/** Rumpf fuer POST /api/flashcard-stacks, wenn der Stapel neu ist (Art "eigene", Woche des Auftrags) */
export const newStackBody = (name, subject, week) => ({ name: String(name).trim(), subject, week: week ?? null, kind: "eigene" });

/** Rueckmeldung nach dem Speichern: "12 Karten gespeichert" */
export function savedText(n, verb = "gespeichert") {
  return `${n === 1 ? "1 Karte" : `${n} Karten`} ${verb}`;
}

/** Geteilte Stapel nach Woche gruppiert: Wochen aufsteigend, "Allgemein" zuletzt */
export function groupShared(list) {
  const groups = new Map();
  for (const s of list || []) {
    const w = s.week || null;
    const k = w ?? "general";
    if (!groups.has(k)) groups.set(k, { week: w, label: weekLabel(w), stacks: [] });
    groups.get(k).stacks.push(s);
  }
  return [...groups.values()].sort((a, b) => (a.week === null) - (b.week === null) || (a.week ?? 0) - (b.week ?? 0));
}

/** Kurzbeschreibung eines geteilten Stapels */
export const sharedMeta = s => [s.cards === 1 ? "1 Karte" : `${s.cards} Karten`, s.pseudonym, s.likes ? `${s.likes} ♥` : null,
  s.adopt_count ? `${s.adopt_count}× übernommen` : null, s.mine ? "von dir" : null].filter(Boolean).join(" · ");

/** Hinweis zu einem Fehler beim Laden/Uebernehmen aus der Community, der einen Weg zeigt */
export function communityHint(e) {
  if (e?.code === "not_linked") return "Verbinde zuerst dein StudiNow-Konto (Einstellungen → StudiNow-Konto), dann kannst du Karteikarten teilen und übernehmen.";
  if (e?.code === "not_a_member") return "Tritt zuerst der Community dieses Moduls bei.";
  if (e?.code === "module_not_here") return "Dieses Modul gibt es bei dir nicht: übernehmen geht nur in ein eigenes Modul.";
  return e?.message || "Das hat nicht geklappt.";
}

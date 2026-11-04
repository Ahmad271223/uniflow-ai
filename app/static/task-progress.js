// "Aufgaben erledigt" an allen Stellen gleich gezaehlt (wie UFTaskProgress in apps/apple/UniFlow/Views/Plan/PlanView.swift,
// Audit 03.11.2026 Zeile 4): immer eine Woche Montag–Sonntag, auf der Uebersicht die laufende, im Lernkalender die Woche
// des gezeigten Datums (vorher je Ansicht: Liste = Tag, Monat = sechs Wochen). Gezaehlt werden alle Aufgaben der
// Lernpakete dieser Tage wie `tasks_total` des Backends (auch uebersprungene); erledigt = "erledigt". Ohne Aufgaben zeigen
// die Stellen keine Zahl ("0 / 0"), sondern "–" bzw. einen Satz. Ohne DOM (tests/js/task-progress.test.mjs).

const MONTHS_SHORT = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."];
const isoOf = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const parse = s => { const [y, m, d] = String(s).slice(0, 10).split("-").map(Number); return new Date(y, m - 1, d); };
const add = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
/** Montag der Woche eines Datums (Date oder "YYYY-MM-DD") */
export const mondayOf = v => { const d = typeof v === "string" ? parse(v) : new Date(v); return add(d, -((d.getDay() + 6) % 7)); };

/** Zaehlung aus Zahlen; open = geplant oder in Bearbeitung */
export function progress({ done = 0, late = 0, skipped = 0, total = 0 } = {}) {
  return { done, late, skipped, total, open: Math.max(0, total - done - late - skipped), empty: total === 0,
           fraction: total > 0 ? done / total : 0, text: total === 0 ? null : `${done} / ${total}` };
}

/** Aus Kalendertagen (`/api/calendar`): Aufgaben aller Lernpakete */
export function ofDays(days) {
  const p = { done: 0, late: 0, skipped: 0, total: 0 };
  for (const d of days || []) for (const pk of d.packages || []) for (const t of pk.tasks || []) {
    p.total++;
    if (t.status === "erledigt") p.done++; else if (t.status === "nachholen") p.late++; else if (t.status === "uebersprungen") p.skipped++;
  }
  return progress(p);
}

/** Aus der Woche der Uebersicht (`/api/dashboard` → week.done/total, dieselbe Zaehlung im Backend) */
export const ofWeek = w => progress({ done: w?.done || 0, total: w?.total || 0 });

/** Die sieben Tage (Mo–So) um `date` aus mehreren Kalenderantworten, jeder Tag einmal, nach Datum */
export function weekDays(date, ...lists) {
  const mon = mondayOf(date), keys = new Set(Array.from({ length: 7 }, (_, i) => isoOf(add(mon, i))));
  const seen = new Map();
  for (const list of lists) for (const d of list || []) if (keys.has(d.date) && !seen.has(d.date)) seen.set(d.date, d);
  return [...seen.values()].sort((a, b) => a.date.localeCompare(b.date));
}

/** Zeitraum in Worten: "diese Woche", sonst "Woche 9.–15. Nov." bzw. "Woche 28. Dez. – 3. Jan." */
export function weekLabel(monday, today = new Date()) {
  const mon = mondayOf(monday);
  if (isoOf(mon) === isoOf(mondayOf(today))) return "diese Woche";
  const sun = add(mon, 6), f = d => `${d.getDate()}. ${MONTHS_SHORT[d.getMonth()]}`;
  return mon.getMonth() === sun.getMonth() ? `Woche ${mon.getDate()}.–${f(sun)}` : `Woche ${f(mon)} – ${f(sun)}`;
}

/** Satz statt "0 / 0" im Lernkalender: "Keine Lernaufgaben geplant." (mit Uni-Terminen "…, 2 Uni-Termine.") */
export const emptyText = uni => uni > 0 ? `Keine Lernaufgaben geplant, ${uni} Uni-Termin${uni === 1 ? "" : "e"}.` : "Keine Lernaufgaben geplant.";

// Erinnerungen an Abgaben, Tests und Pruefungen (05.11.2026), ohne DOM: wie DueReminders.swift auf dem iPad.
// Je Termin 3 Tage vorher, 1 Tag vorher und am Morgen des Tages jeweils um 8:00 (Berlin), mit Uhrzeit zusaetzlich
// 2 Stunden vorher (nicht vor 6:00; der Morgen nur, wenn "2 Stunden vorher" spaeter kommt). Nur kuenftige Zeitpunkte,
// die fruehesten zuerst, hoechstens 60. Kennungen "de.uniflow.ai.due.<Container>.<Termin>.<d3|d1|d0|h2>".
// Gemeinsame Faelle: packages/shared-contracts/fixtures/due-detection/cases.json ("reminders"), tests/js/due-reminders.test.mjs.
// Die Termine kommen aus GET /api/due (app/due_api.py); geplant und gezeigt wird in due-reminders.js.

export const PREFIX = "de.uniflow.ai.due.";
export const LIMIT = 60;
const MORNING = 8 * 60;
const WEEKDAY_SHORT = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

const pad = n => String(n).padStart(2, "0");
const parts = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || "")); return m ? [+m[1], +m[2], +m[3]] : null; };

// Berliner Ortszeit <-> UTC ohne Bibliothek (Intl kennt die Zeitzone; Sommer-/Winterzeit inklusive)
let fmt;
function berlinFields(ms) {
  fmt ||= new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  const o = {}; for (const p of fmt.formatToParts(new Date(ms))) o[p.type] = p.value;
  return { y: +o.year, mo: +o.month, d: +o.day, h: +o.hour % 24, mi: +o.minute };
}
/** "YYYY-MM-DDTHH:MM" in Berlin fuer einen Zeitpunkt (ms seit 1970) */
export function berlinLocal(ms) { const f = berlinFields(ms); return `${f.y}-${pad(f.mo)}-${pad(f.d)}T${pad(f.h)}:${pad(f.mi)}`; }
/** Zeitpunkt (ms) einer Berliner Ortszeit: Tag "YYYY-MM-DD" und Minuten nach Mitternacht */
export function berlinToUtc(dayISO, minutes) {
  const p = parts(dayISO); if (!p) return NaN;
  const naive = Date.UTC(p[0], p[1] - 1, p[2], Math.floor(minutes / 60), minutes % 60);
  let t = naive;
  for (let i = 0; i < 2; i++) {             // Abstand zur Ortszeit an der Stelle bestimmen (zweimal: Umstellungstage)
    const f = berlinFields(t); const shown = Date.UTC(f.y, f.mo - 1, f.d, f.h, f.mi);
    t = naive - (shown - t);
  }
  return t;
}
/** "2026-10-27T10:00" (Berlin) -> ms */
export const parseLocal = s => { const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/.exec(String(s || "")); return m ? berlinToUtc(m[1], +m[2] * 60 + +m[3]) : NaN; };

const addDays = (iso, n) => { const p = parts(iso); const d = new Date(Date.UTC(p[0], p[1] - 1, p[2] + n)); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; };
function minutes(t) { const m = /^(\d{1,2}):(\d{2})$/.exec(String(t || "")); if (!m) return null; const h = +m[1], mi = +m[2]; return h <= 23 && mi <= 59 ? h * 60 + mi : null; }

/** "Sa, 05.12." bzw. "Sa, 05.12. 23:59" */
export function when(dayISO, time) {
  const p = parts(dayISO); const wd = (new Date(Date.UTC(p[0], p[1] - 1, p[2])).getUTCDay() + 6) % 7;
  return `${WEEKDAY_SHORT[wd]}, ${pad(p[2])}.${pad(p[1])}.` + (time ? ` ${time}` : "");
}

/** Termine aus GET /api/due (ausgeblendete fehlen); Ziel beim Antippen: Dokumentseite, sonst Adresse, sonst Modul */
export function itemsFrom(response) {
  return (response?.items || []).filter(x => x && x.id != null && x.date && x.hidden !== true).map(x => {
    let route = null;
    if (x.file_id) route = `#/doc/${x.file_id}` + ((x.page || 1) > 1 ? `?page=${x.page}` : "");
    else if (x.url) route = x.url;
    else if (x.module_id != null) route = `#/modules/${x.module_id}`;
    return { id: String(x.id), title: x.title || x.kind_label || "Termin", date: x.date, time: x.time || null,
             course: x.course_title || x.module_name || null, origin: x.origin || null, route };
  });
}

/** Erinnerungen fuer alle Termine: kuenftige, frueheste zuerst, hoechstens `limit` */
export function plan(items, container, nowMs, limit = LIMIT) {
  const base = `${PREFIX}${container}.`; const out = [];
  for (const it of items) {
    if (!parts(it.date)) continue;
    const due = minutes(it.time);
    const body = [it.course, when(it.date, it.time), it.origin].filter(Boolean).join(" · ");
    const slots = [["d3", berlinToUtc(addDays(it.date, -3), MORNING), `In 3 Tagen: ${it.title}`],
                   ["d1", berlinToUtc(addDays(it.date, -1), MORNING), `Morgen: ${it.title}`]];
    if (due != null) {
      const before = due - 120;
      if (before > MORNING) slots.push(["d0", berlinToUtc(it.date, MORNING), `Heute: ${it.title}`]);
      if (before >= 6 * 60) slots.push(["h2", berlinToUtc(it.date, before), `In 2 Stunden: ${it.title}`]);
    } else slots.push(["d0", berlinToUtc(it.date, MORNING), `Heute: ${it.title}`]);
    for (const [tag, at, title] of slots) if (at > nowMs) out.push({ identifier: `${base}${it.id}.${tag}`, fireAt: at, title, body, route: it.route, itemID: it.id });
  }
  const seen = new Set();
  return out.filter(r => !seen.has(r.identifier) && seen.add(r.identifier))
    .sort((a, b) => a.fireAt - b.fireAt || (a.identifier < b.identifier ? -1 : a.identifier > b.identifier ? 1 : 0)).slice(0, limit);
}

/** Abgleich: eigene Kennungen (PREFIX, auch anderer Container), die nicht mehr im Plan stehen, zuruecknehmen */
export function diff(pending, planned) {
  const keep = new Set(planned.map(r => r.identifier ?? r));
  return { remove: [...new Set(pending.filter(id => id.startsWith(PREFIX) && !keep.has(id)))].sort(), add: planned };
}

/** Faellig in den naechsten `ms` (fuer die Zeitgeber, solange die App offen ist) */
export const dueWithin = (planned, nowMs, ms) => planned.filter(r => r.fireAt > nowMs && r.fireAt - nowMs <= ms);

/** Kurzer Stand fuer den Hinweis in der App (ohne Mitteilungen): Termine heute und morgen, hoechstens drei */
export function todaySummary(items, nowMs) {
  const today = berlinLocal(nowMs).slice(0, 10), tomorrow = addDays(today, 1);
  const now = berlinLocal(nowMs);
  const soon = items.filter(it => (it.date === today && (!it.time || `${it.date}T${it.time}` >= now)) || it.date === tomorrow)
    .sort((a, b) => (a.date + (a.time || "")).localeCompare(b.date + (b.time || "")));
  if (!soon.length) return null;
  const txt = it => `${it.date === today ? "Heute" : "Morgen"}${it.time ? ` ${it.time}` : ""}: ${it.title}`;
  return { day: today, count: soon.length, lines: soon.slice(0, 3).map(txt), more: Math.max(0, soon.length - 3), route: soon[0].route };
}

/** Welcher Weg fuer Mitteilungen: Windows-App (Tauri-Plugin), Browser (Notification-API) oder nur in der App */
export function channel(win) {
  if (win?.__TAURI__?.notification || win?.__TAURI_INTERNALS__?.invoke) return "tauri";
  if (typeof win?.Notification === "function") return win.Notification.permission === "denied" ? "inapp" : "browser";
  return "inapp";
}

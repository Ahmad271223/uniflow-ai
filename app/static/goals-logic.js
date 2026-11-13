// Lernziele (Smart Planner 2.0) am PC und im Browser: reine Hilfen ohne DOM, Gegenstueck zu GoalsFmt, GoalsInput und
// GoalsOptionRow auf dem iPad (apps/apple/UniFlow/Views/Goals). Getestet in tests/js/goals-logic.test.mjs.

/** Stunden wie im Rechenkern: "12,5 h", "320 h" (Minuten, auf Zehntelstunden gerundet) */
export function h(minutes) {
  const m = Math.trunc(Number(minutes) || 0);
  const tenths = Math.trunc((Math.abs(m) * 10 + 30) / 60);
  const t = tenths % 10 === 0 ? `${Math.trunc(tenths / 10)} h` : `${Math.trunc(tenths / 10)},${tenths % 10} h`;
  return m < 0 ? "-" + t : t;
}

/** Prognose je Modul: Text und Farbton (badge-Klasse) */
export const STATUS = { auf_kurs: ["Auf Kurs", "ok"], knapp: ["Knapp", "warn"], gefaehrdet: ["Gefährdet", "bad"],
                        erreicht: ["Ziel erreicht", "ok"], vorbei: ["Klausur vorbei", "neutral"] };

export function days(n) {
  if (n === null || n === undefined) return "kein Termin";
  if (n === 0) return "heute";
  return n === 1 ? "morgen" : `in ${n} Tagen`;
}

/** Wochentag aus dem ISO-Tag (Mo ... So) */
export function weekday(isoDay) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(isoDay || "");
  if (!m) return "";
  const wd = (new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).getUTCDay() + 6) % 7;
  return ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][wd];
}

/** Zahlenzeile eines Moduls: "Ziel 200 h · gelernt 12 h · fehlt 188 h · 10 h pro Woche · Prognose 80 %" */
export function numbers(st = {}) {
  const parts = [`Ziel ${h(st.target_minutes)}`, `gelernt ${h(st.learned_minutes)}`];
  if ((st.lecture_minutes || 0) > 0) parts.push(`Veranstaltungen ${h(st.lecture_minutes)}`);
  parts.push(`fehlt ${h(st.remaining_minutes)}`);
  if (st.per_week_minutes !== null && st.per_week_minutes !== undefined) parts.push(`${h(st.per_week_minutes)} pro Woche`);
  parts.push(`Prognose ${st.forecast_percent ?? 0} %`);
  return parts.join(" · ");
}

/** Anteil fuer den Balken: gelernt (samt Veranstaltungen) durch Ziel, 0..1 */
export function share(st = {}) {
  const target = st.target_minutes || 0;
  const done = (st.learned_minutes || 0) + (st.lecture_minutes || 0);
  return target > 0 ? Math.max(0, Math.min(1, done / target)) : 1;
}

/** Laufzeit einer Stoppuhr als H:MM:SS: Summe der Abschnitte [start, ende|null] in Unix-Sekunden, offener bis jetzt */
export function elapsed(s, nowSec = Math.floor(Date.now() / 1000)) {
  let sec = 0;
  for (const seg of s?.segments || []) {
    if (!Array.isArray(seg) || seg.length < 2 || typeof seg[0] !== "number") continue;
    sec += Math.max(0, (typeof seg[1] === "number" ? seg[1] : nowSec) - seg[0]);
  }
  const p = n => String(n).padStart(2, "0");
  return `${Math.floor(sec / 3600)}:${p(Math.floor(sec / 60) % 60)}:${p(sec % 60)}`;
}

/** "12,5" / "12.5" -> 12.5; leer oder keine Zahl -> null */
export function parseNum(s) {
  const t = String(s ?? "").trim().replace(",", ".");
  if (!t || !/^-?\d+(\.\d+)?$/.test(t)) return null;
  const d = Number(t);
  return Number.isFinite(d) ? d : null;
}

/** 12.5 -> "12,5", 200 -> "200", null -> "" */
export function numText(d) {
  if (d === null || d === undefined || !Number.isFinite(+d)) return "";
  return +d === Math.round(+d) ? String(Math.round(+d)) : (Math.round(+d * 10) / 10).toFixed(1).replace(".", ",");
}

/** Ortszeit Berlin (Tag "2026-11-13" + "14:30") -> Unix-Sekunden, auch wenn der Rechner anders eingestellt ist */
export function berlinEpoch(day, hmText) {
  const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day || ""), t = /^(\d{1,2}):(\d{2})$/.exec(hmText || "");
  if (!d || !t || +d[2] < 1 || +d[2] > 12 || +d[3] < 1 || +d[3] > 31 || +t[1] > 23 || +t[2] > 59) return null;
  const wall = Date.UTC(+d[1], +d[2] - 1, +d[3], +t[1], +t[2]);
  // Abstand Berlin–UTC zu diesem Zeitpunkt (Sommer-/Winterzeit) aus der Zeitzonen-Datenbank des Browsers
  const offset = at => {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Berlin", hourCycle: "h23", year: "numeric",
      month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(at)).map(p => [p.type, p.value]));
    return Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute) - at;
  };
  let utc = wall - offset(wall);
  utc = wall - offset(utc);                      // zweiter Schritt fuer die Stunden um die Zeitumstellung
  return Math.round(utc / 1000);
}

/** Option bei Unterdeckung: laesst sie sich mit einem Klick uebernehmen? */
export function actionable(opt) {
  switch (opt?.kind) {
    case "nutzungsquote": return Number.isInteger(opt.value);
    case "freizeit": return Number.isInteger(opt.minutes_per_day);
    case "ziele": case "zweittermin": case "teilplan": return true;
    default: return false;
  }
}

/** Anfragen, die eine Option uebernehmen (danach wird neu geplant; "teilplan" plant direkt mit accept_partial).
 *  o = Antwort von GET /api/goals. Liefert [{path, method, body}] und `plan` (Body fuer POST /api/goals/plan). */
export function optionRequests(opt, o) {
  const s = o?.settings || {};
  switch (opt?.kind) {
    case "nutzungsquote":
      return { requests: [{ path: "/goals/settings", method: "PUT", body: { utilization: opt.value ?? 60 } }], plan: {} };
    case "freizeit":
      return { requests: [{ path: "/goals/settings", method: "PUT", body: { leisure_minutes: Math.max(0, (s.leisure_minutes ?? 120) - (opt.minutes_per_day ?? 0)) } }], plan: {} };
    case "ziele": {
      const reqs = [];
      for (const c of opt.cuts || []) {
        const m = (o?.modules || []).find(x => x.module_id === c.module_id);
        if (!m) continue;
        const hours = Math.max(0, ((m.target_minutes || 0) - (c.minutes || 0)) / 60);
        reqs.push({ path: `/goals/${m.module_id}`, method: "PUT", body: { target_hours: Math.floor(hours * 10) / 10 } });
      }
      return { requests: reqs, plan: {} };
    }
    case "zweittermin":
      return { requests: [{ path: `/goals/${opt.module_id}`, method: "PUT", body: { exam_attempt: 2, exam_date_2: opt.date || "" } }], plan: {} };
    case "teilplan":
      return { requests: [], plan: { accept_partial: true } };
    default:
      return null;
  }
}

/** Kennzahlen der Kopfzeile: [Wert, Beschriftung] x 4 */
export function kpis(o) {
  const mods = o?.modules || [];
  const target = mods.reduce((a, m) => a + (m.target_minutes || 0), 0);
  const missing = mods.reduce((a, m) => a + (m.stats?.remaining_minutes || 0), 0);
  const next = o?.next_exam;
  return [[next && next.days !== null && next.days !== undefined ? String(next.days) : "–", next?.name ? `Tage bis ${next.name}` : "Keine Klausur geplant"],
          [h(o?.week?.planned_minutes), "Diese Woche geplant"], [h(o?.week?.learned_minutes), "Diese Woche gelernt"],
          [h(missing), `Fehlt noch von ${h(target)}`]];
}

/** Text des Lernblocks im Lernpaket (wie SmartBlockPanel auf dem iPad) */
export function blockLabel(p) {
  if (+p?.locked === 1) return "Lernblock aus deinen Lernzielen · gesperrt";
  if (+p?.manual === 1) return "Lernblock aus deinen Lernzielen · von dir verschoben";
  return "Lernblock aus deinen Lernzielen";
}

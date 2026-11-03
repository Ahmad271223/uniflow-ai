// Hinweise im Kalenderkopf antippbar (Auftrag des Inhabers 03.11.2026), ohne DOM, wie UFHint in der iPad-App
// (apps/apple/UniFlow/Views/Plan/CalendarHints.swift): Art lesbar, Quelle mit Titel und Datum, Termin dazu.
// Eingabe: ein Eintrag aus marks, deadlines oder notices eines Kalendertags (GET /api/calendar, /api/timetable/week)
// mit _kind "mark" | "deadline" | "notice" und date.

const NOTICE_KINDS = {
  ausfall: ["Ausfall?", "alert", "warn"], verlegt: ["Verlegung?", "move", "warn"], raum: ["Raumänderung", "move", "info"],
  pruefung: ["Klausur / Prüfung", "exam", "bad"], frist: ["Frist", "flag", "bad"], online: ["Online", "users", "info"],
};
const DETECTED_KINDS = { klausur: "Klausur / Prüfung", test: "Test", abgabe: "Abgabe", anmeldung: "Anmeldung" };
const ddmmyyyy = s => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s || "")); return m ? `${m[3]}.${m[2]}.${m[1]}` : ""; };
export const httpUrl = u => /^https?:\/\/[^/\s]/i.test(String(u ?? "")) ? String(u) : "";
const hm = t => { const [h, m] = String(t || "0:0").split(":").map(Number); return h * 60 + (m || 0); };

/** { kindText, icon, tone, title, source, snippet, url, course } fuer das Detail */
export function hintInfo(d) {
  if (d._kind === "mark") {
    const hol = d.kind === "feiertag";
    return { kindText: hol ? "Feiertag" : d.kind === "pause" ? "Vorlesungsfrei (Unterbrechung)" : "Vorlesungsfreie Zeit", icon: hol ? "sun" : "calendar",
             tone: "ok", title: d.label || "", course: "", url: "",
             snippet: hol ? "An diesem Tag finden keine Lehrveranstaltungen statt."
                          : "In dieser Zeit finden in der Regel keine Vorlesungen statt; Prüfungen und Blockveranstaltungen sind möglich.",
             source: hol ? "Gesetzlicher Feiertag" : "Semesterzeiten der Hochschule" };
  }
  if (d._kind === "deadline") {
    if (d.detected) return { kindText: DETECTED_KINDS[d.kind] || "Termin", icon: d.kind === "klausur" || d.kind === "test" ? "exam" : "flag",
                             tone: d.kind === "sonstiges" ? "info" : "bad", title: d.title || "Termin", course: d.course_title || d.module_name || "",
                             snippet: d.snippet || "", url: httpUrl(d.url), source: `${d.origin || "Erkannt"} (automatisch erkannt)` };
    return { kindText: d.kind_label || "Frist", icon: String(d.kind || "").startsWith("test") ? "exam" : "flag", tone: "bad",
             title: d.title || "Frist", course: d.course_title || "", url: httpUrl(d.url),
             snippet: d.full_title && d.full_title !== d.title ? d.full_title : "",
             source: d.source === "studip" ? "Aufgabe aus Stud.IP Courseware" : "Frist aus dem Learnweb-Kalender" };
  }
  const [kindText, icon, tone] = NOTICE_KINDS[d.kind] || ["Termin", "calendar", "info"];
  const src = { studip: "Stud.IP-Ankündigung", learnweb: "Learnweb-Ankündigung" }[d.source] || "Ankündigung";
  const posted = ddmmyyyy(d.posted_at);
  return { kindText, icon, tone, title: d.title || "Hinweis", course: d.course_title || "", snippet: d.snippet || "", url: httpUrl(d.url),
           source: `${src} „${d.title || ""}“${posted ? ` vom ${posted}` : ""}` };
}

/** Termin des Tages zum Hinweis: Ausfall -> Termin mit diesem cancel_hint, sonst gleicher Kurs bzw. Modul (mit Uhrzeit
 *  der, der dann laeuft oder bis 15 Minuten spaeter beginnt). Fristen und Feiertage haben keinen Termin. */
export function relatedEvent(d, events) {
  if (d._kind !== "notice") return null;
  const evs = (events || []).filter(e => e.status !== "verschoben");
  if (d.kind === "ausfall" && d.announcement_id) {
    const e = evs.find(e => e.cancel_hint && e.cancel_hint.announcement_id === d.announcement_id);
    if (e) return e;
  }
  let cand = evs.filter(e => (d.course_id && e.course_id === d.course_id) || (d.module_id != null && e.module_id === d.module_id));
  if (d.time) { const m = hm(d.time); cand = cand.filter(e => { const s = hm(e.start); return s - 15 <= m && m < Math.max(s + 1, hm(e.end)); }); }
  if (d.course_id && cand.some(e => e.course_id === d.course_id)) cand = cand.filter(e => e.course_id === d.course_id);
  return cand[0] || null;
}

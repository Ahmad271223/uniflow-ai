// Stundenplan: Rückfragen zum eigenen Stud.IP-Kalender und Ausfälle laut Stud.IP (05.11.2026, wie
// StudIPCalendarQuestions.swift und StudIPCancellations auf dem iPad). Daten: GET /api/timetable/studip-questions und
// GET /api/timetable/studip-cancelled (app/timetable_questions.py). Ohne Importe, damit node --test es prüfen kann
// (tests/js/studip-questions.test.mjs); Helfer (api, icon, esc, toast) kommen als Argumente.
//
// - Kurs belegt, aber nicht im Kalender: „Übernehmen“ oder „Weglassen“ (bis zur Antwort nicht im Stundenplan).
// - Kurs mit drei oder mehr Terminen je Woche: „Welche Termine besuchst du?“ (alle vorausgewählt, abgewählte werden grau).
// - Ausfälle laut Stud.IP blendet die Woche aus wie Stud.IP (Entscheidung des Inhabers 28.10.2026); eine Zeile nennt
//   ihre Zahl und zeigt sie auf Wunsch mit „fällt aus“. Selbst markierte Ausfälle bleiben immer sichtbar.

const DAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

/** Schlüssel eines Vorkommens: Serie und Tag */
export const cancelKey = (eventId, date) => `${eventId}|${date}`;

/** Schlüssel aus der Antwort von GET /api/timetable/studip-cancelled */
export function cancelKeys(list) {
  return new Set((Array.isArray(list) ? list : []).filter(r => r && r.event_id != null && typeof r.date === "string").map(r => cancelKey(r.event_id, r.date)));
}

/** Ausgefallen laut Stud.IP: Status "ausfall" mit Ausnahme "cancelled" an einem Tag aus `keys` */
export function hides(e, date, keys) {
  return !!e && e.status === "ausfall" && e.exception === "cancelled" && keys.has(cancelKey(e.event_id, e.date || date));
}

/** Woche (days[].events) ohne die Ausfälle laut Stud.IP; `show` lässt sie stehen. Liefert die Zahl der Ausfälle. */
export function hideCancelled(week, keys, show = false) {
  let n = 0;
  for (const d of week?.days || []) {
    const keep = [];
    for (const e of d.events || []) { if (hides(e, d.date, keys)) { n++; if (show) keep.push(e); } else keep.push(e); }
    d.events = keep;
  }
  return n;
}

/** Hinweiszeile über dem Raster, nur wenn es Ausfälle laut Stud.IP gibt */
export function cancelNoteHtml(n, shown, { esc = s => String(s) } = {}) {
  if (!n) return "";
  const t = (n === 1 ? "1 Termin fällt diese Woche laut Stud.IP aus" : `${n} Termine fallen diese Woche laut Stud.IP aus`)
    + (shown ? "." : ` und ${n === 1 ? "ist" : "sind"} ausgeblendet, wie in Stud.IP.`);
  return `<div class="muted small sq-cx" style="margin-bottom:.6rem">${esc(t)} <button class="btn ghost sm" id="sqCx">${shown ? "Ausblenden" : "Anzeigen"}</button></div>`;
}

export const hiddenText = title => `Du bist in „${title}“ eingetragen, aber der Kurs steht nicht in deinem Stud.IP-Kalender.`;
export const busyText = (title, count) => `„${title}“ steht ${count}-mal pro Woche in deinem Kalender. Welche Termine besuchst du?`;
export function timeLabel(t) {
  return `${DAYS[t.weekday] ?? ""} ${t.start_time || ""}–${t.end_time || ""}${t.room ? ` · ${t.room}` : ""}`;
}
/** Rückmeldung nach dem Speichern (wie auf dem iPad) */
export function answerToast(kind, r, include) {
  if (kind === "course") {
    if (!include) return "Kurs weggelassen";
    const n = r?.new || 0;
    return n > 0 ? `${n} ${n === 1 ? "Termin" : "Termine"} übernommen` : "Kurs übernommen";
  }
  const s = r?.skipped || 0;
  return s > 0 ? `${s} ${s === 1 ? "Termin" : "Termine"} als „nicht besucht“ markiert` : "Alle Termine bleiben";
}

/** Rumpf für POST …/times: die angehakten Termine in der Reihenfolge der Frage */
export const timesBody = (q, checked) => ({ course_id: q.course_id, attend: (q.times || []).map(t => t.cycle_id).filter(id => checked.has(id)) });

/** Karten über dem Stundenplan; leer ohne offene Fragen */
export function questionsHtml(qs, { icon = () => "", esc = s => String(s) } = {}) {
  const hidden = qs?.hidden || [], busy = qs?.busy || [];
  if (!hidden.length && !busy.length) return "";
  const card = inner => `<div class="card sq-card" style="margin-bottom:.7rem">${inner}</div>`;
  return `<div class="sq-list" aria-label="Fragen zu deinem Stud.IP-Kalender">${hidden.map((q, i) => card(`<b>${icon("info", 15)} ${esc(hiddenText(q.title))}</b>
      <div class="muted small" style="margin:.25rem 0 .55rem">Bis du entscheidest, bleibt er wie in Stud.IP draußen.</div>
      <div class="row" style="gap:.45rem"><button class="btn primary sm" data-sq-inc="${i}">Übernehmen</button><button class="btn sm" data-sq-exc="${i}">Weglassen</button></div>`)).join("")}${busy.map((q, i) => card(`<b>${icon("clock", 15)} ${esc(busyText(q.title, (q.times || []).length))}</b>
      <div class="stack" style="margin:.45rem 0;gap:.25rem">${(q.times || []).map(t => `<label class="row small" style="gap:.45rem"><input type="checkbox" data-sq-t="${i}" value="${esc(t.cycle_id)}"${t.attend !== false ? " checked" : ""}> ${esc(timeLabel(t))}</label>`).join("")}</div>
      <div class="muted small" style="margin-bottom:.5rem">Abgewählte Termine werden grau und geben die Zeit für Lernblöcke frei.</div>
      <button class="btn primary sm" data-sq-save="${i}">Speichern</button>`)).join("")}</div>`;
}

/** Knöpfe der Karten; `done` lädt den Stundenplan neu */
export function bindQuestions(root, qs, { api, toast, done }) {
  const q$ = s => [...root.querySelectorAll(s)];
  const course = async (q, include, btn) => {
    btn.disabled = true;
    try { toast(answerToast("course", await api("/timetable/studip-questions/course", { method: "POST", body: { course_id: q.course_id, include } }), include)); }
    catch (e) { toast(`Antwort nicht gespeichert: ${e.message}`, 5000); }
    done();
  };
  q$("[data-sq-inc]").forEach(b => b.onclick = () => course(qs.hidden[+b.dataset.sqInc], true, b));
  q$("[data-sq-exc]").forEach(b => b.onclick = () => course(qs.hidden[+b.dataset.sqExc], false, b));
  q$("[data-sq-save]").forEach(b => b.onclick = async () => {
    const i = +b.dataset.sqSave, q = qs.busy[i];
    const checked = new Set(q$(`[data-sq-t="${i}"]`).filter(c => c.checked).map(c => c.value));
    b.disabled = true; b.textContent = "Wird gespeichert …";
    try { toast(answerToast("times", await api("/timetable/studip-questions/times", { method: "POST", body: timesBody(q, checked) }))); }
    catch (e) { toast(`Antwort nicht gespeichert: ${e.message}`, 5000); }
    done();
  });
}

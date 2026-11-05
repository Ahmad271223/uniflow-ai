// Pruefungsanmeldung im Web/Windows (05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): reine Regeln und Texte ohne DOM
// (laeuft unter node, tests/js/exam-registration.test.mjs), nach ExamRegistrationViews.swift der iPad-App. Daten von
// GET /api/exam-registration (app/exam_registration_api.py). StudiNow meldet nie selbst an: "Im QIS anmelden" oeffnet
// nur die QIS-Seite "Mein Studium" im App-Fenster; der Mensch waehlt und bestaetigt selbst. Uni Hildesheim (`system`
// "LSF"): "Im LSF anmelden" oeffnet die Startseite des LSF; das Fenster hat kein Ende (`open_end`: Start der
// POS-Anmeldung, Fristen je Pruefung im LSF), dazu `period_note` statt "nicht sicher".

export const TEXTS = {
  title: "Prüfungsanmeldung",
  openQIS: "Im QIS anmelden",
  fetch: "Angemeldete Prüfungen abrufen",
  suggestions: "Diese Prüfungen solltest du anmelden",
  registered: "angemeldet",
  notRegistered: "nicht angemeldet",
  moduleBlock: "Prüfung anmelden",
  source: "Termine des Prüfungsamts",
  noPeriod: "Den Meldezeitraum für deinen Studiengang kennt StudiNow nicht sicher. Sieh bitte auf der Terminseite nach.",
  noSuggestions: "Für dieses Semester steht laut deinem Plan keine Prüfung an.",
  dismiss: "Ausblenden",
  view: "Ansehen",
};

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export { esc };
const WD = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];
const parts = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || "")); return m ? [+m[1], +m[2], +m[3]] : null; };

/** "So, 22.11." */
export function dayShort(iso) {
  const p = parts(iso);
  if (!p) return "";
  return `${WD[new Date(Date.UTC(p[0], p[1] - 1, p[2])).getUTCDay()]}, ${String(p[2]).padStart(2, "0")}.${String(p[1]).padStart(2, "0")}.`;
}

/** "22.11.2026" */
export function dayFull(iso) {
  const p = parts(iso);
  return p ? `${String(p[2]).padStart(2, "0")}.${String(p[1]).padStart(2, "0")}.${p[0]}` : "";
}

/** "QIS" (LUH) oder "LSF" (Uni Hildesheim) */
export const systemOf = r => (r && r.system) || "QIS";

/** "Im QIS anmelden" / "Im LSF anmelden" */
export const openLabel = r => (r && r.open_label) || `Im ${systemOf(r)} anmelden`;

/** Zeile zur Phase des Meldezeitraums; ohne Ende (Uni Hildesheim) mit dem Pruefungssystem */
export function phaseText(w, system = "QIS") {
  if (!w) return "";
  if (w.open_end) {
    if (w.phase === "open") return `Anmeldung im ${system} seit ${dayShort(w.start)} – Fristen je Prüfung im ${system}`;
    if (w.phase === "soon") {
      const until = w.days_until === 0 ? "heute" : w.days_until === 1 ? "morgen" : `in ${w.days_until} Tagen`;
      return `Anmeldung im ${system} ${w.term} beginnt am ${dayShort(w.start)} (${until}) – Fristen je Prüfung`;
    }
    return `Nächste Anmeldung im ${system}: ab ${dayFull(w.start)} (${w.term})`;
  }
  const vbp = w.kind === "vbp_meldung" ? " (VbP)" : "";
  if (w.phase === "open") {
    const left = w.days_left === 0 ? "endet heute" : w.days_left === 1 ? "endet morgen" : `noch ${w.days_left} Tage`;
    return `Meldezeitraum${vbp} ${w.term} läuft bis ${dayShort(w.end)} – ${left}`;
  }
  if (w.phase === "soon") {
    const until = w.days_until === 0 ? "heute" : w.days_until === 1 ? "morgen" : `in ${w.days_until} Tagen`;
    return `Meldezeitraum${vbp} ${w.term} beginnt am ${dayShort(w.start)} (${until})`;
  }
  return `Nächster Meldezeitraum${vbp}: ${dayShort(w.start)}–${dayShort(w.end)}${parts(w.end) ? parts(w.end)[0] : ""} (${w.term})`;
}

/** Karte nur im Meldezeitraum und in den 7 Tagen davor */
export const showCard = r => !!(r && r.supported && r.show_card);

/** "Klausur am 15.02.2027, 09:00 · HS A · aus Stud.IP-Terminen" */
export function examLine(s) {
  if (!s?.exam_date) return "";
  return [`Prüfung am ${dayFull(s.exam_date)}${s.exam_time ? `, ${s.exam_time}` : ""}`, s.exam_room, s.exam_source].filter(Boolean).join(" · ");
}

/** "Rücktritt bis 08.02.2027" */
export const withdrawLine = s => s?.withdraw_until ? `Rücktritt bis ${dayFull(s.withdraw_until)}` : "";

export function badge(s) {
  return s?.registered
    ? `<span class="badge ok">${esc(TEXTS.registered)}</span>`
    : `<span class="badge warn">${esc(TEXTS.notRegistered)}</span>`;
}

export function rowHtml(s) {
  const sub = [s.reason, s.period === "vbp" ? "VbP-Meldezeitraum" : "", s.last_attempt ? "letzter Versuch" : ""].filter(Boolean).join(" · ");
  const ex = examLine(s), wd = withdrawLine(s);
  return `<div class="xr-row" data-xr="${esc(s.id)}"><div class="main"><div class="title">${esc(s.title || "Prüfung")}</div>`
    + (sub ? `<div class="small muted">${esc(sub)}</div>` : "")
    + (ex ? `<div class="small">${esc(ex)}</div>` : "")
    + (wd ? `<div class="small muted" title="${esc(s.withdraw_rule || "")}">${esc(wd)}</div>` : "")
    + `</div>${badge(s)}</div>`;
}

/** Knoepfe: QIS bzw. LSF im App-Fenster, Abruf der Info-Seite */
export function actionsHtml(r, icon = () => "") {
  return `<div class="xr-actions">${r.qis_url ? `<a class="btn primary sm" href="${esc(r.qis_url)}" target="_blank" rel="noopener">${icon("log-out", 14)} ${esc(openLabel(r))}</a>` : ""}`
    + `<button type="button" class="btn sm" data-xr-fetch>${icon("refresh", 14)} ${esc(TEXTS.fetch)}</button></div>`
    + `<p class="tiny muted">${esc(r.hint || "")}</p>`;
}

/** Stand des letzten Abrufs */
export function runLine(r) {
  if (!r?.registrations_checked_at) return "";
  const d = new Date(r.registrations_checked_at);
  const when = Number.isNaN(d.getTime()) ? "" : ` (${d.toLocaleDateString("de-DE")} ${d.toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" })})`;
  return `${r.registrations_message || ""}${when}`;
}

/** Ganze Karte bzw. Abschnitt; `limit` Vorschlaege (Uebersicht 4, Studienverlauf alle) */
export function cardHtml(r, { icon = () => "", limit = Infinity, section = false } = {}) {
  if (!r?.supported) return "";
  const w = r.window, vw = r.vbp_window;
  const src = r.source?.url ? `<a href="${esc(r.source.url)}" target="_blank" rel="noopener">${esc(TEXTS.source)}</a>${r.source.checked_at ? ` <span class="muted">(Stand ${esc(dayFull(r.source.checked_at))})</span>` : ""}` : "";
  const sys = systemOf(r);
  const note = r.period_note ? `<p class="small muted">${esc(r.period_note)}</p>` : "";
  const phase = (w ? `<p>${esc(phaseText(w, sys))}</p>${vw && vw.phase === "open" ? `<p class="small">${esc(phaseText(vw, sys))}</p>` : ""}`
    : (note ? "" : `<p class="small muted">${esc(TEXTS.noPeriod)}</p>`)) + note;
  const warns = (r.warnings || []).map(x => `<p class="xr-warn" role="alert">${icon("alert", 14)} ${esc(x.text)}</p>`).join("");
  const list = r.suggestions || [];
  const shown = list.slice(0, limit);
  const rows = shown.length ? shown.map(rowHtml).join("") : `<p class="small muted">${esc(r.plan_message || TEXTS.noSuggestions)}</p>`;
  const more = list.length > shown.length ? `<p class="small"><a href="#/studyplan">und ${list.length - shown.length} weitere im Studienverlauf</a></p>` : "";
  const counts = list.length ? `<span class="muted small">${r.open_count} offen · ${r.registered_count} angemeldet</span>` : "";
  return `<section class="card xr-card${section ? " xr-section" : " ov-card"}" aria-label="${esc(TEXTS.title)}"><div class="card-head"><h2>${icon("exam", 18)} ${esc(TEXTS.title)}</h2>${counts}</div>`
    + phase + warns
    + (r.plan_message && list.length ? `<p class="small muted">${esc(r.plan_message)}</p>` : "")
    + `<h3 class="small">${esc(TEXTS.suggestions)}</h3><div class="xr-list">${rows}</div>${more}`
    + actionsHtml(r, icon)
    + `<p class="tiny muted">${esc(runLine(r))}</p>`
    + `<p class="tiny muted">${src}${src ? " · " : ""}${esc(r.disclaimer || "")}</p></section>`;
}

/** Vorschlag zu einem Modul (Katalog-Kennung im Studienverlauf oder Modul der App) */
export function suggestionFor(r, { catalogId, appModuleId } = {}) {
  return (r?.suggestions || []).find(s => (catalogId != null && s.id === catalogId)
    || (appModuleId != null && (s.app_module_ids || []).includes(appModuleId))) || null;
}

/** Block "Prüfung anmelden" am Modul */
export function moduleBlockHtml(r, s, icon = () => "") {
  if (!s) return "";
  const w = s.period === "vbp" ? r.vbp_window : r.window;
  return `<div class="card xr-module" aria-label="${esc(TEXTS.moduleBlock)}"><div class="card-head"><h3>${icon("exam", 16)} ${esc(TEXTS.moduleBlock)}</h3>${badge(s)}</div>`
    + (w ? `<p class="small">${esc(phaseText(w, systemOf(r)))}</p>` : "")
    + rowHtml(s)
    + actionsHtml(r, icon) + `</div>`;
}

/** Hinweis in der App statt einer Systemmitteilung: die juengste faellige Erinnerung (Tag erreicht, Zeitraum laeuft, nicht
    ausgeblendet) oder null */
export function dueReminder(r, today, dismissed = new Set()) {
  const list = (r?.reminders || []).filter(x => x.day <= today && today <= (x.until || x.day) && !dismissed.has(x.id));
  return list.length ? list[list.length - 1] : null;
}

export function bannerHtml(rem, icon = () => "") {
  if (!rem) return "";
  return `<div class="xr-banner" role="status" data-xr-banner="${esc(rem.id)}">${icon("bell", 18)}<div class="main"><b>${esc(rem.title)}</b><div class="small muted">${esc(rem.body)}</div></div>`
    + `<a class="btn sm primary" href="${esc(rem.route || "#/studyplan")}">${esc(TEXTS.view)}</a><button type="button" class="btn sm ghost" data-xr-dismiss>${esc(TEXTS.dismiss)}</button></div>`;
}

/** Abzeichen fuer eine Zeile der Karte "Nächste Klausuren": angemeldet / nicht angemeldet / nichts (unbekannt) */
export function examStatus(r, item) {
  if (!r?.supported || !item) return null;
  const s = (r.suggestions || []).find(x => (Number.isInteger(item.module_id) && (x.app_module_ids || []).includes(item.module_id))
    || (x.exam_date && x.exam_date === item.date && x.title && String(item.title || "").includes(x.title)));
  if (!s) return null;
  return s.registered ? TEXTS.registered : TEXTS.notRegistered;
}

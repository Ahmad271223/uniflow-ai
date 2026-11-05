// Gemeinsame Helfer für alle Ansichten
import { icon } from "./icons.js?v=33";
import { hintInfo, relatedEvent } from "./hints.js?v=3";
import { responseError, resendNote, ACTION_LABEL } from "./service-errors.js?v=1";
export { icon };
export const $ = (s, el = document) => el.querySelector(s);
export const $$ = (s, el = document) => [...el.querySelectorAll(s)];
export const DAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];
export const DAYS_LONG = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"];
export const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];
export const STATUS_TXT = { geplant: "Geplant", in_bearbeitung: "In Bearbeitung", erledigt: "Erledigt", teilweise: "Teilweise erledigt", nachholen: "Nachholen", verschoben: "Verschoben", uebersprungen: "Übersprungen", frei: "Frei", leer: "Nichts geplant" };
export const STATUS_ICON = { geplant: "calendar", in_bearbeitung: "play", erledigt: "check", teilweise: "clock", nachholen: "alert", verschoben: "move", uebersprungen: "x", frei: "sun", leer: "circle" };
export const TYPE_TXT = { vorlesung: "Vorlesung", uebung: "Übung", test: "Wochentest", wiederholung: "Wiederholung", frei: "Lernen", loesung: "Lösung", skript: "Skript", klausur: "Klausur", organisatorisch: "Organisatorisches", sonstiges: "Sonstiges", notebook: "Notizbuch", whiteboard: "Whiteboard", pdf: "PDF", image: "Bild" };
export const TYPE_ICON = { vorlesung: "book", uebung: "pencil", test: "exam", wiederholung: "rotate", frei: "clock", loesung: "check", skript: "file-text", klausur: "flag", organisatorisch: "info", sonstiges: "file", notebook: "note", whiteboard: "square", pdf: "file-text", image: "image" };
export const KIND_TXT = { vorlesung: "Vorlesung", uebung: "Übung", hoersaaluebung: "Hörsaalübung", gruppenuebung: "Gruppenübung", tutorium: "Tutorium", labor: "Labor", seminar: "Seminar", sonstiges: "Sonstiges", persoenlich: "Persönlich" };

export async function api(path, opts = {}) {
  const r = await fetch("/api" + path, { headers: opts.body instanceof FormData ? {} : { "Content-Type": "application/json" }, ...opts, body: opts.body && !(opts.body instanceof FormData) && typeof opts.body !== "string" ? JSON.stringify(opts.body) : opts.body });
  if (r.status === 401 && state.hosted) { location.replace("/login"); }   // Sitzung im Dienst abgelaufen oder abgemeldet
  // Windows-App: Anmeldung abgelaufen oder widerrufen -> neu laden zeigt den Anmeldebildschirm (account-gate.js); auf dem
  // Anmeldebildschirm selbst (signed_in false) laufen Hintergrundabrufe ins Leere, ohne neu zu laden
  if (r.status === 401 && state.appAccount?.signed_in) { location.reload(); }
  if (!r.ok) throw await responseError(r);   // Text zum Fehlercode des Dienstes: service-errors.js (wie ServiceErrorText auf dem iPad)
  return r.json();
}
/** Fehler zeigen. Mit Handlung (e.action aus service-errors.js: Bestaetigungslink erneut senden, Konto oeffnen) als
    kleines Fenster mit dem Knopf, sonst als Hinweis. */
export function showError(e, ms = 5000) {
  if (!e?.action) { toast(e?.message || "Fehler", ms); return; }
  const m = modal(`<h3>${icon("alert", 18)} Das geht noch nicht</h3><p>${esc(e.message)}</p><div class="modal-foot"><button class="btn" data-close>Schließen</button><button class="btn primary" data-act>${esc(ACTION_LABEL[e.action] || "OK")}</button></div>`);
  $("[data-act]", m).onclick = async () => {
    m.remove();
    if (e.action === "accountSettings") { if (state.hosted) $("#avatar")?.click(); else location.hash = "#/settings?tab=account"; return; }
    try { toast(resendNote(await api(state.hosted ? "/account/verify-email/resend" : "/studora/verify-email/resend", { method: "POST" })), 4000); }
    catch (x) { toast(x.message, 5000); }
  };
}
export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Nur http(s)-Links aus Fremddaten (z. B. Learnweb) als href; alles andere wird '#'
export const safeUrl = u => /^https?:\/\//i.test(String(u ?? "")) ? String(u) : "#";
// Feiertage/vorlesungsfreie Zeit (gruen) und Learnweb-Fristen je Kalendertag (Felder marks/deadlines der API)
export const holClass = dd => { const k = (dd.marks || []).map(m => m.kind); return k.includes("feiertag") || k.includes("pause") ? "is-hol" : k.length ? "is-free" : ""; };
export const holChips = (dd, compact) => [...new Map((dd.marks || []).map(m => [m.label, m])).values()].map(m => `<span class="hol-chip ${m.kind}" role="button" tabindex="0" data-chip="${chipRef(m, "mark", dd.date)}" title="${esc(m.label)}">${esc(compact ? ({ "Vorlesungsfreie Zeit": "vorlesungsfrei", "Weihnachtspause": "Pause", "Exkursions- und Projektwoche": "Projektwoche", "Exkursionswoche": "Exkursion" }[m.label] || m.label) : m.label)}</span>`).join("");
// Fristen und Termine aus Ankuendigungen: ein Klick auf den Chip zeigt, was gemeint ist (Titel, Kurs, Zeit, Satz aus
// der Ankuendigung bzw. die ganze Ankuendigung) und bietet den Link zur Quelle an (chipDetail). Die Daten des Chips
// liegen in chipData; der Chip traegt nur eine Kennung (data-chip).
const chipData = new Map();
// events: Termine desselben Tages fuer "Zum Termin" (03.11.2026)
export const chipRef = (x, kind, date, events) => { const k = kind === "deadline" ? `dl-${x.id ?? x.deadline_id}-${date || x.date || ""}` : kind === "mark" ? `hol-${date}-${x.label}` : `an-${x.announcement_id ?? "x"}-${date || x.date || ""}-${x.time || ""}-${x.kind || ""}`; chipData.set(k, { ...x, date: date || x.date, _kind: kind, _events: events || [] }); return k; };
export const dlChips = (dd, compact) => (dd.deadlines || []).map(x => `<a class="dl-chip" href="${esc(safeUrl(x.url))}" data-chip="${chipRef(x, "deadline", dd.date, dd.events)}" style="--dc:${x.color || "var(--bad)"}" title="${esc(x.kind_label)} ${esc(x.time)} · ${esc(x.full_title || x.title)}${x.course_title ? " · " + esc(x.course_title) : ""}"><b>${esc(x.time)}</b> ${esc(compact ? x.kind_label : `${x.kind_label}: ${x.title}`)}</a>`).join("");
// Termine aus Ankuendigungen der Lehrenden (Feld notices): Hinweis mit Art, Satz aus der Ankuendigung als Tooltip
// Ausfall am Termin (Wunsch des Inhabers 02.11.2026): aus einer Ankuendigung erkannt (cancel_hint, app/announcements.py
// mark_cancellations) -> "Ausfall?", eingetragen (Status ausfall) -> "fällt aus"; die vorlesungsfreie Zeit zeigt der Tag gruen
export const cancelLabel = e => e.status === "ausfall" ? (e.exception === "vorlesungsfrei" ? "" : "fällt aus") : (e.cancel_hint ? "Ausfall?" : "");
export const cancelUnsure = e => cancelLabel(e) === "Ausfall?";
// in Stud.IP abgesagter Einzeltermin (cancel_hint mit kind "termin", timetable.studip_cancel_hint, 02.11.2026)
export const cancelSource = e => { const h = e.cancel_hint; return h ? h.kind === "termin" ? "Stud.IP (Termin abgesagt)" : `${{ studip: "Stud.IP-Ankündigung", learnweb: "Learnweb-Ankündigung" }[h.source] || "Ankündigung"} „${h.title}“${h.course_title ? " · " + h.course_title : ""}` : ""; };
// Sitzungsthema aus Stud.IP (session_topic, 02.11.2026): dezent, immer ganz (Inhaber 03.11.2026: Texte aus Stud.IP nie mit "…")
export const topicLine = e => { const t = String(e.session_topic || "").trim(); if (!t) return "";
  return `<div class="small muted tp-line" style="white-space:pre-line">Thema: ${esc(t)}</div>`; };
export const cancelMark = (e, iconOnly) => { const l = cancelLabel(e); if (!l) return ""; const src = cancelSource(e);
  return `<span class="cx-mark" title="${esc(l + (src ? " laut " + src : ""))}" aria-label="${cancelUnsure(e) ? "Möglicher Ausfall" : "Fällt aus"}">${icon("alert", 11)}${iconOnly ? "" : " " + esc(l)}</span>`; };
export const noteChips = (dd, compact) => (dd.notices || []).map(n => `<a class="note-chip k-${esc(n.kind)}" href="${esc(safeUrl(n.url))}" data-chip="${chipRef(n, "notice", dd.date, dd.events)}" title="${esc(n.title)}${n.course_title ? " · " + esc(n.course_title) : ""}: ${esc(n.snippet)}">${icon("info", 11)} ${n.time ? `<b>${esc(n.time)}</b> ` : ""}${esc(compact ? n.kind_label : `${n.kind_label}: ${n.title}`)}</a>`).join("");
// Detail eines Hinweises (03.11.2026, wie UFHintDialog der iPad-App): Art, Titel, Datum und Uhrzeit, Kurs, Termin,
// Satz aus der Quelle, Quelle mit Titel und Datum; "Quelle öffnen" nur fuer http(s), "Zum Termin", bei einem
// unsicheren Ausfall "Fällt aus" / "Findet statt" (vorhandene Ausnahmen wie im Termin-Panel)
export function chipDetail(key) {
  const d = chipData.get(key); if (!d) return;
  const h = hintInfo(d);
  const ev = relatedEvent(d, d._events);
  const when = [d.date ? `${DAYS_LONG[(parseISO(d.date).getDay() + 6) % 7]}, ${fmtDate(d.date, { day: "numeric", month: "long", year: "numeric" })}` : "", d.time ? `${esc(d.time)} Uhr` : ""].filter(Boolean).join(", ");
  const unsure = d._kind === "notice" && d.kind === "ausfall" && ev && cancelUnsure(ev) && ev.event_id;
  const row = (ic, html) => `<div class="hint-row">${icon(ic, 15)}<span>${html}</span></div>`;
  const m = modal(`<h3>${esc(h.title)}</h3>
    <div class="chip-detail hint-detail">
      <span class="badge ${h.tone}">${icon(h.icon, 12)} ${esc(h.kindText)}</span>
      ${row("calendar", when)}${h.course ? row("book", esc(h.course)) : ""}${ev ? row("clock", `${esc(shortName(ev.title))}, ${esc(ev.start)}–${esc(ev.end)}${ev.room ? ", " + esc(ev.room) : ""}`) : ""}
      ${d._kind === "deadline" && d.overdue ? `<div class="small" style="color:var(--bad)">${icon("alert", 13)} Laut Quelle überfällig und noch nicht erledigt.</div>` : ""}
      ${h.snippet ? `<blockquote class="hint-quote">${d._kind === "notice" || d.detected ? `„${esc(h.snippet)}“` : esc(h.snippet)}</blockquote>` : ""}
      <div class="small" style="color:var(--text-2)">Quelle: ${esc(h.source)}</div>
      ${d._kind === "notice" && d.announcement_id ? `<details class="small"><summary class="muted">Ganze Ankündigung</summary><div class="ann-full muted" style="margin-top:.4rem;max-height:40vh;overflow:auto;white-space:pre-wrap">Wird geladen …</div></details>` : ""}
      ${d._kind === "notice" && d.kind === "ausfall" && ev ? `<div class="hint-decide">${ev.status === "ausfall" ? `${cancelMark(ev)}` : `<div class="muted small">Aus dem Text erkannt, nicht sicher. Der Termin bleibt im Plan${unsure ? ", bis du entscheidest" : ""}.</div>${unsure ? `<div class="row" style="gap:.4rem;margin-top:.45rem"><button class="btn primary sm" data-hatt="cancelled">${icon("alert", 14)} Fällt aus</button><button class="btn sm" data-hatt="today_attend">${icon("check", 14)} Findet statt</button></div>` : ""}`}</div>` : ""}
    </div>
    <div class="modal-foot">${ev ? `<button class="btn sm" data-hev>${icon("calendar", 14)} Zum Termin</button>` : ""}${h.url ? `<a class="btn sm" href="${esc(h.url)}" target="_blank" rel="noopener">${icon("arrow-right", 14)} Quelle öffnen</a>` : ""}${d.detected && d.file_id ? `<a class="btn sm" href="#/doc/${encodeURIComponent(d.file_id)}${(d.page || 1) > 1 ? `?page=${+d.page}` : ""}" data-close>${icon("file-text", 14)} Im Dokument</a>` : ""}${d.detected ? `${d.confirmed ? "" : `<button class="btn sm" data-due="confirmed">${icon("check", 14)} Stimmt</button>`}<button class="btn sm" data-due="hidden">${icon("x", 14)} Stimmt nicht</button>` : ""}<button class="btn ghost sm" data-close>Schließen</button></div>`);
  // automatisch erkannte Frist (app/due_store.py): bestaetigen oder ausblenden, gilt auch fuer Erinnerungen (05.11.2026)
  $$("[data-due]", m).forEach(b => b.onclick = async () => {
    try { await api(`/due/${encodeURIComponent(d.id)}`, { method: "PATCH", body: { [b.dataset.due]: true } }); }
    catch (e) { toast(`Nicht gespeichert: ${e.message}`, 4000); return; }
    toast(b.dataset.due === "hidden" ? "Ausgeblendet – erscheint nicht mehr" : "Bestätigt"); m.remove(); state.route();
  });
  const ev$ = $("[data-hev]", m);
  if (ev$) ev$.onclick = () => { m.remove(); import("./views-tt.js?v=47").then(t => ev.event_id ? t.openEvent(ev.event_id, d.date) : (location.hash = `#/plan?view=day&date=${d.date}`)); };
  $$("[data-hatt]", m).forEach(b => b.onclick = async () => {
    try { await api("/timetable/attendance", { method: "POST", body: { event_id: ev.event_id, date: d.date, mode: b.dataset.hatt } }); }
    catch (e) { toast(`Speichern fehlgeschlagen: ${e.message}`, 4000); return; }
    toast(b.dataset.hatt === "cancelled" ? "Als Ausfall eingetragen" : "Termin findet statt"); m.remove(); state.route();
  });
  if (d._kind === "notice" && d.announcement_id) api("/announcements?days=365").then(r => {
    const box = $(".ann-full", m); if (!box) return;
    const a = (r.announcements || []).find(x => x.id === d.announcement_id);
    if (!a) { box.textContent = "Die Ankündigung ist nicht mehr vorhanden."; return; }
    box.classList.remove("muted"); box.textContent = (a.text || "").trim() || "(kein Text)";
  }).catch(e => { const box = $(".ann-full", m); if (box) box.textContent = `Nicht geladen: ${e.message}`; });
  return m;
}
// Normaler Klick oeffnet das Detailfenster; Strg-/Mittelklick behalten den Link im Chip. In der Abfangphase, weil der
// Lernkalender auf den Chips stopPropagation setzt (damit der Klick nicht die Tagesansicht oeffnet)
document.addEventListener("click", e => {
  const a = e.target.closest && e.target.closest("[data-chip]");
  if (!a || e.ctrlKey || e.metaKey || e.shiftKey || e.button) return;
  e.preventDefault(); e.stopPropagation(); chipDetail(a.dataset.chip);
}, true);
// Tastatur: Enter oder Leertaste auf einem Chip (auch Feiertag/vorlesungsfrei, role=button) oeffnet das Detail
document.addEventListener("keydown", e => {
  const a = (e.key === "Enter" || e.key === " ") && e.target.closest && e.target.closest("[data-chip]");
  if (a && chipData.has(a.dataset.chip)) { e.preventDefault(); e.stopPropagation(); chipDetail(a.dataset.chip); }
}, true);
export const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
export const parseISO = s => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
export const todayISO = () => iso(new Date());
export const fmtDate = (v, opts = { day: "2-digit", month: "2-digit", year: "numeric" }) => { if (!v) return ""; const d = typeof v === "number" ? new Date(v * 1000) : (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? parseISO(v) : new Date(v)); return d.toLocaleDateString("de-DE", opts); };
export const fmtShort = v => fmtDate(v, { weekday: "short", day: "2-digit", month: "2-digit" });
export const fmtMin = m => m >= 60 ? `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}` : `${m} min`;
export const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
export const mondayOf = d => addDays(d, -((d.getDay() + 6) % 7));
export const hm = t => { const [h, m] = String(t || "0:0").split(":").map(Number); return h * 60 + (m || 0); };
export const mh = m => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
export function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
let toastT; export function toast(msg, ms = 2600) { let t = $("#toastEl"); if (!t) { t = document.createElement("div"); t.id = "toastEl"; t.className = "toast"; document.body.append(t); } t.textContent = msg; t.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => t.hidden = true, ms); }
export function modal(html, { wide } = {}) { const m = document.createElement("div"); m.className = "modal"; m.setAttribute("role", "dialog"); m.setAttribute("aria-modal", "true"); m.innerHTML = `<div class="modal-box" ${wide ? 'style="width:min(900px,100%)"' : ""}>${html}</div>`; m.addEventListener("click", e => { if (e.target === m) m.remove(); }); $("#overlay").append(m); $$("[data-close]", m).forEach(b => b.onclick = () => m.remove()); return m; }
export function drawer(html) { closeDrawer(); const d = document.createElement("aside"); d.className = "drawer"; d.id = "drawerEl"; d.innerHTML = html; const bd = document.createElement("div"); bd.className = "backdrop"; bd.id = "drawerBd"; bd.onclick = closeDrawer; $("#overlay").append(bd, d); $$("[data-close]", d).forEach(b => b.onclick = closeDrawer); return d; }
export function closeDrawer() { $("#drawerEl")?.remove(); $("#drawerBd")?.remove(); }
export const statusPill = st => `<span class="status-pill st-${st}">${icon(STATUS_ICON[st] || "circle", 12)} ${STATUS_TXT[st] || st}</span>`;
export const diffBadge = d => d ? `<span class="badge ${d <= 2 ? "ok" : d >= 4 ? "bad" : "warn"}">Stufe ${d}</span>` : "";
export const typeBadge = t => t ? `<span class="badge neutral">${esc(TYPE_TXT[t] || t)}</span>` : "";
export const initial = s => (s || "?").replace(/^(Mathematik|Grundlagen|Einführung|Elektrotechnische|Datenstrukturen|Signale|Programmieren)\s*/i, m => m[0]).slice(0, 2).toUpperCase();
// Fachfarben fuer die Farbwahl: erste Stufe von PALETTE in app/colors.py (tests/test_module_colors.py vergleicht)
export const PALETTE = ["#175ee8", "#e95905", "#167535", "#834bbf", "#b9454c", "#1f9682", "#896301", "#de5797", "#0486c2", "#748e03", "#626974", "#a1826c"];
export const shortName = s => (s || "").replace("Mathematik für die Ingenieurwissenschaften", "Mathematik").replace("Elektrotechnische Grundlagen der Informatik", "Elektrotechnik").replace("Datenstrukturen und Algorithmen", "Datenstrukturen & Algorithmen").replace("Grundlagen digitaler Systeme", "Digitale Systeme");
export const state = { route: () => {}, editors: [], hosted: false, gated: false, account: null, appAccount: null, entitlements: null };
// Recht aus dem Abo-Stand (GET /api/entitlements): im Dienst und in der Windows-App mit Konto-Pflicht (state.gated,
// 05.11.2026); ohne Abo ist alles aus (nur lesen). Am eigenen PC ohne Konto-Pflicht ist alles erlaubt. Der Server prueft trotzdem jeden Aufruf.
export const can = name => !(state.hosted || state.gated) || !!state.entitlements?.entitlements?.[name];

// ---------------------------------------------------------------- Barrierefreiheit (28.10.2026)
// Knoepfe nur mit Symbol bekommen ihren Titel als Namen fuer Bildschirmleser; Escape schliesst das oberste Fenster;
// ein neues Fenster bekommt den Fokus auf sein erstes Eingabefeld bzw. seinen ersten Knopf.
function labelIconButtons(root) {
  const nodes = root.querySelectorAll ? root.querySelectorAll("button, a.btn, [role=button]") : [];
  for (const b of [root, ...nodes]) {
    if (!(b instanceof Element) || !b.matches?.("button, a.btn, [role=button]") || b.hasAttribute("aria-label")) continue;
    const text = (b.textContent || "").trim();
    const t = b.getAttribute("title") || b.dataset?.tip;
    if (!text && t) b.setAttribute("aria-label", t);
  }
  for (const svg of root.querySelectorAll ? root.querySelectorAll("svg.ic:not([aria-hidden])") : []) svg.setAttribute("aria-hidden", "true");
}
function focusDialog(m) {
  const f = m.querySelector("input:not([type=hidden]):not([disabled]), textarea, select, button:not([disabled]), a[href]");
  if (f) setTimeout(() => { try { f.focus({ preventScroll: true }); } catch {} }, 30);
}
if (typeof document !== "undefined" && typeof MutationObserver !== "undefined") {
  const mo = new MutationObserver(list => { for (const r of list) for (const n of r.addedNodes) if (n.nodeType === 1) { labelIconButtons(n); if (n.classList?.contains("modal")) focusDialog(n); } });
  const start = () => { labelIconButtons(document.body); mo.observe(document.body, { childList: true, subtree: true }); };
  if (document.body) start(); else document.addEventListener("DOMContentLoaded", start);
  document.addEventListener("keydown", e => {
    if (e.key !== "Escape" || e.defaultPrevented) return;
    const ms = document.querySelectorAll(".modal"); const top = ms[ms.length - 1];
    if (top) { top.remove(); e.preventDefault(); return; }
    const dr = document.getElementById("drawerEl"); if (dr) { closeDrawer(); e.preventDefault(); }
  });
}

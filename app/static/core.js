// Gemeinsame Helfer für alle Ansichten
import { icon } from "./icons.js?v=29";
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
  if (!r.ok) { let m = r.statusText; try { m = (await r.json()).detail || m; } catch {} throw new Error(m); }
  return r.json();
}
export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Nur http(s)-Links aus Fremddaten (z. B. Learnweb) als href; alles andere wird '#'
export const safeUrl = u => /^https?:\/\//i.test(String(u ?? "")) ? String(u) : "#";
// Feiertage/vorlesungsfreie Zeit (gruen) und Learnweb-Fristen je Kalendertag (Felder marks/deadlines der API)
export const holClass = dd => { const k = (dd.marks || []).map(m => m.kind); return k.includes("feiertag") || k.includes("pause") ? "is-hol" : k.length ? "is-free" : ""; };
export const holChips = (dd, compact) => [...new Map((dd.marks || []).map(m => [m.label, m])).values()].map(m => `<span class="hol-chip ${m.kind}" title="${esc(m.label)}">${esc(compact ? ({ "Vorlesungsfreie Zeit": "vorlesungsfrei", "Weihnachtspause": "Pause", "Exkursions- und Projektwoche": "Projektwoche", "Exkursionswoche": "Exkursion" }[m.label] || m.label) : m.label)}</span>`).join("");
// Fristen und Termine aus Ankuendigungen: ein Klick auf den Chip zeigt, was gemeint ist (Titel, Kurs, Zeit, Satz aus
// der Ankuendigung bzw. die ganze Ankuendigung) und bietet den Link zur Quelle an (chipDetail). Die Daten des Chips
// liegen in chipData; der Chip traegt nur eine Kennung (data-chip).
const chipData = new Map();
export const chipRef = (x, kind, date) => { const k = kind === "deadline" ? `dl-${x.id ?? x.deadline_id}-${date || x.date || ""}` : `an-${x.announcement_id ?? "x"}-${date || x.date || ""}-${x.time || ""}-${x.kind || ""}`; chipData.set(k, { ...x, date: date || x.date, _kind: kind }); return k; };
export const dlChips = (dd, compact) => (dd.deadlines || []).map(x => `<a class="dl-chip" href="${esc(safeUrl(x.url))}" data-chip="${chipRef(x, "deadline", dd.date)}" style="--dc:${x.color || "var(--bad)"}" title="${esc(x.kind_label)} ${esc(x.time)} · ${esc(x.full_title || x.title)}${x.course_title ? " · " + esc(x.course_title) : ""}"><b>${esc(x.time)}</b> ${esc(compact ? x.kind_label : `${x.kind_label}: ${x.title}`)}</a>`).join("");
// Termine aus Ankuendigungen der Lehrenden (Feld notices): Hinweis mit Art, Satz aus der Ankuendigung als Tooltip
export const noteChips = (dd, compact) => (dd.notices || []).map(n => `<a class="note-chip k-${esc(n.kind)}" href="${esc(safeUrl(n.url))}" data-chip="${chipRef(n, "notice", dd.date)}" title="${esc(n.title)}${n.course_title ? " · " + esc(n.course_title) : ""}: ${esc(n.snippet)}">${icon("info", 11)} ${n.time ? `<b>${esc(n.time)}</b> ` : ""}${esc(compact ? n.kind_label : `${n.kind_label}: ${n.title}`)}</a>`).join("");
const sourceLabel = url => { let h = ""; try { h = new URL(url).hostname; } catch {} return /studip/i.test(h) ? "Stud.IP" : /learnweb|moodle/i.test(h) ? "Learnweb" : h ? h.replace(/^www\./, "") : ""; };
export function chipDetail(key) {
  const d = chipData.get(key); if (!d) return;
  const isDl = d._kind === "deadline";
  const url = safeUrl(d.url); const src = url !== "#" ? sourceLabel(url) : "";
  const when = [d.date ? `${DAYS_LONG[(parseISO(d.date).getDay() + 6) % 7]}, ${fmtDate(d.date)}` : "", d.time ? `${esc(d.time)} Uhr` : ""].filter(Boolean).join(" · ");
  const m = modal(`<h3>${icon(isDl ? "flag" : "info", 18)} ${esc(d.kind_label || (isDl ? "Frist" : "Termin"))}</h3>
    <div class="chip-detail">
      <div style="font-weight:650;font-size:1.05rem">${esc(isDl ? (d.full_title || d.title) : d.title)}</div>
      <div class="muted small" style="margin:.25rem 0 .7rem">${when}${d.course_title ? ` · ${esc(d.course_title)}` : ""}${src ? ` · ${esc(src)}` : ""}</div>
      ${isDl && d.overdue ? `<div class="small" style="color:var(--bad);margin-bottom:.6rem">${icon("alert", 13)} Laut ${esc(src || "Quelle")} überfällig und noch nicht erledigt.</div>` : ""}
      ${!isDl && d.snippet ? `<blockquote class="small" style="border-left:3px solid var(--line);padding:.3rem .6rem;margin:0 0 .6rem">${esc(d.snippet)}</blockquote>` : ""}
      ${!isDl && d.announcement_id ? `<details class="small" open><summary class="muted">Ganze Ankündigung</summary><div class="ann-full muted" style="margin-top:.4rem;max-height:40vh;overflow:auto;white-space:pre-wrap">Wird geladen …</div></details>` : ""}
      ${isDl ? `<div class="muted small">Die Frist stammt aus ${esc(src || "der Hochschule")}. Was genau abzugeben ist, steht dort${d.course_title ? ` im Kurs „${esc(d.course_title)}“` : ""}.</div>` : ""}
    </div>
    <div class="modal-foot">${url !== "#" ? `<a class="btn primary sm" href="${esc(url)}" target="_blank" rel="noopener">${icon("arrow-right", 14)} ${src ? `In ${esc(src)} öffnen` : "Link öffnen"}</a>` : ""}<button class="btn sm" data-close>Schließen</button></div>`);
  if (!isDl && d.announcement_id) api("/announcements?days=365").then(r => {
    const box = $(".ann-full", m); if (!box) return;
    const a = (r.announcements || []).find(x => x.id === d.announcement_id);
    if (!a) { box.textContent = "Die Ankündigung ist nicht mehr vorhanden."; return; }
    box.classList.remove("muted"); box.textContent = (a.text || "").trim() || "(kein Text)";
    if (a.author || a.posted_at) box.insertAdjacentHTML("afterend", `<div class="muted small" style="margin-top:.3rem">${esc(a.author || "")}${a.author && a.posted_at ? " · " : ""}${a.posted_at ? fmtShort(a.posted_at.slice(0, 10)) : ""}</div>`);
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
export function modal(html, { wide } = {}) { const m = document.createElement("div"); m.className = "modal"; m.innerHTML = `<div class="modal-box" ${wide ? 'style="width:min(900px,100%)"' : ""}>${html}</div>`; m.addEventListener("click", e => { if (e.target === m) m.remove(); }); $("#overlay").append(m); $$("[data-close]", m).forEach(b => b.onclick = () => m.remove()); return m; }
export function drawer(html) { closeDrawer(); const d = document.createElement("aside"); d.className = "drawer"; d.id = "drawerEl"; d.innerHTML = html; const bd = document.createElement("div"); bd.className = "backdrop"; bd.id = "drawerBd"; bd.onclick = closeDrawer; $("#overlay").append(bd, d); $$("[data-close]", d).forEach(b => b.onclick = closeDrawer); return d; }
export function closeDrawer() { $("#drawerEl")?.remove(); $("#drawerBd")?.remove(); }
export const statusPill = st => `<span class="status-pill st-${st}">${icon(STATUS_ICON[st] || "circle", 12)} ${STATUS_TXT[st] || st}</span>`;
export const diffBadge = d => d ? `<span class="badge ${d <= 2 ? "ok" : d >= 4 ? "bad" : "warn"}">Stufe ${d}</span>` : "";
export const typeBadge = t => t ? `<span class="badge neutral">${esc(TYPE_TXT[t] || t)}</span>` : "";
export const initial = s => (s || "?").replace(/^(Mathematik|Grundlagen|Einführung|Elektrotechnische|Datenstrukturen|Signale|Programmieren)\s*/i, m => m[0]).slice(0, 2).toUpperCase();
// Fachfarben fuer die Farbwahl: erste Stufe von PALETTE in app/colors.py (tests/test_module_colors.py vergleicht)
export const PALETTE = ["#175ee8", "#e95905", "#167535", "#834bbf", "#b9454c", "#1f9682", "#896301", "#de5797", "#0486c2", "#748e03", "#626974", "#a1826c"];
export const shortName = s => (s || "").replace("Mathematik für die Ingenieurwissenschaften", "Mathematik").replace("Elektrotechnische Grundlagen der Informatik", "Elektrotechnik").replace("Datenstrukturen und Algorithmen", "Datenstrukturen & Algorithmen").replace("Grundlagen digitaler Systeme", "Digitale Systeme");
export const state = { route: () => {}, editors: [], hosted: false, account: null };

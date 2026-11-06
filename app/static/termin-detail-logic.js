// Termin-Detail in Web und Windows (06.11.2026, Auftrag des Inhabers), wie TerminDetail.swift (UniFlowCore) und
// TerminDetailViews.swift auf dem iPad: im Termin-Panel des Stundenplans und Lernkalenders der Raum (Klick startet die
// Route zu Fuss in Google Maps) und alle Lehrenden des Kurses (Klick auf die E-Mail: neue Uni-Mail). Regeln und HTML ohne
// DOM, unter node geprueft (tests/js/termin-detail.test.mjs mit packages/shared-contracts/fixtures/termin-detail/cases.json).
// Lehrende nur an der LUH (Stud.IP), Route nur an der LUH (Standortfinder); HsH und Hildesheim: Raum als Text mit
// "In Karten suchen". An Google geht nichts von selbst: erst beim Klick.
import { segments, mayLink } from "./rooms-logic.js?v=1";
import { rowHtml } from "./lecturers-logic.js?v=1";

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const TEXTS = {
  room: "Raum",
  rooms: "Räume",
  routeSub: "Route zu Fuß in Google Maps",
  showInFinder: "Im Raumfinder anzeigen",
  searchMaps: "In Karten suchen",
  lecturers: "Lehrende",
  writeAll: "Allen Lehrenden schreiben",
  toModule: "Zum Modul",
  loading: "Lehrende werden geladen …",
  connectTitle: "Uni-Mail ist nicht verbunden",
  connectMessage: "Mit Uni-Mail schreibst du direkt aus StudiNow von deinem Uni-Postfach aus. Gesendet wird erst mit „Senden“.",
  connect: "Uni-Mail verbinden",
  mailApp: "Mit der Mail-App schreiben",
};

export const routeLabel = t => `Raum ${t}, Route zu Fuß starten`;
export const finderLabel = t => `Raum ${t} im Raumfinder anzeigen`;
export const mapsLabel = t => `Raum ${t} in Karten suchen`;
export const tutorsTitle = n => `Tutor/innen (${n})`;

/** Raeume eines Termins ("1101 - F102 · Online" -> zwei), wie TerminDetail.rooms */
export const rooms = text => segments(text).map(t => ({ text: t, link: mayLink(t) }));

/** Nach GET /api/rooms/resolve (ein Teil): {kind: "route", url} | {kind: "search", query} | {kind: "none"} */
export function route(part, app = false) {
  const status = part?.status || "";
  if (status === "online") return { kind: "none" };
  const text = part?.text || "";
  if (status === "found" || status === "building") {
    const m = part.maps || {};
    const url = app ? (m.google_app_route ?? m.google_route) : m.google_route;
    if (typeof url === "string" && (url.startsWith("https://") || url.startsWith("comgooglemaps://"))) return { kind: "route", url };
  }
  return { kind: "search", query: text };
}

const isLecturer = p => (p?.roles || []).includes("dozent");

/** Dozent/innen (auch mit Tutor-Rolle) und reine Tutor/innen */
export const groups = people => ({ lecturers: (people || []).filter(isLecturer), tutors: (people || []).filter(p => !isLecturer(p)) });

/** "Allen Lehrenden schreiben": Adressen der Dozent/innen, ohne leere und doppelte */
export function recipients(people) {
  const out = [];
  for (const p of groups(people).lecturers) {
    const e = String(p.email || "").trim();
    if (e && !out.some(x => x.toLowerCase() === e.toLowerCase())) out.push(e);
  }
  return out;
}

export function subject(title) {
  const t = String(title ?? "").trim();
  return t ? `Frage zu ${t}` : "";
}

/** wie urllib.parse.quote(s, safe="") */
export const quote = s => encodeURIComponent(String(s)).replace(/[!'()*]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());

/** mailto: mit allen Empfaengern und Betreff; null ohne Adresse */
export function mailto(to, subj) {
  const list = (to || []).map(x => String(x).trim()).filter(Boolean);
  if (!list.length) return null;
  const s = String(subj || "").trim();
  return "mailto:" + list.join(",") + (s ? "?subject=" + quote(s) : "");
}

/** compose (Uni-Mail verbunden) | connect (zuerst verbinden) | mailto | studip (keine Adresse) */
export function mailChoice(to, uniMail) {
  if (!(to || []).some(x => String(x).trim())) return "studip";
  return { connected: "compose", disconnected: "connect" }[uniMail] || "mailto";
}

/** Stand von Uni-Mail aus GET /api/sogo/status */
export const uniMailState = st => (!st || !st.available ? "none" : st.connected ? "connected" : "disconnected");

/** Abfrage fuer GET /api/lecturers: Stud.IP-Kurs, sonst Modul */
export function lecturersQuery(e) {
  const c = e?.course_id;
  if (typeof c === "string" && c.trim()) return `course_id=${quote(c)}`;
  if (Number.isInteger(e?.module_id)) return `module_id=${e.module_id}`;
  return null;
}

export const showsLecturers = u => u === "luh";

/** Bereich "Raum": an der LUH (finder) je Raum ein Knopf "Route" und "Im Raumfinder anzeigen" (.room-link, app.js) */
export function roomSectionHtml(text, finder, icon = () => "") {
  const rs = rooms(text);
  if (!rs.length) return "";
  const row = r => {
    if (r.link && finder) {
      return `<div class="td-room"><button type="button" class="td-route" data-route="${esc(r.text)}" aria-label="${esc(routeLabel(r.text))}">${icon("map-pin", 18)}<span><b>${esc(r.text)}</b><small>${esc(TEXTS.routeSub)}</small></span>${icon("arrow-right", 16)}</button>
        <button type="button" class="btn ghost sm room-link" data-room="${esc(r.text)}" aria-haspopup="dialog" aria-label="${esc(finderLabel(r.text))}">${esc(TEXTS.showInFinder)}</button></div>`;
    }
    return `<div class="td-room td-room-text"><span>${icon(r.link ? "map-pin" : "info", 14)} ${esc(r.text)}</span>${r.link ? `<button type="button" class="btn sm" data-maps="${esc(r.text)}" aria-label="${esc(mapsLabel(r.text))}">${icon("search", 14)} ${esc(TEXTS.searchMaps)}</button>` : ""}</div>`;
  };
  return `<section class="td-sec" aria-label="${esc(rs.length > 1 ? TEXTS.rooms : TEXTS.room)}"><h3>${icon("map-pin", 16)} ${esc(rs.length > 1 ? TEXTS.rooms : TEXTS.room)}</h3>${rs.map(row).join("")}</section>`;
}

/** Bereich "Lehrende" aus GET /api/lecturers; leer ausser an der LUH; Tutor/innen zugeklappt */
export function lecturersSectionHtml(d, icon = () => "", loading = false) {
  if (!d || !d.available) return "";
  const people = d.people || [];
  if (!people.length && !loading && !d.hint) return "";
  const g = groups(people), all = recipients(people);
  const body = !people.length
    ? `<div class="small muted">${esc(loading ? TEXTS.loading : d.hint)}</div>`
    : g.lecturers.map(p => rowHtml(p)).join("")
      + (g.tutors.length ? `<details class="td-tutors"><summary>${esc(tutorsTitle(g.tutors.length))}</summary>${g.tutors.map(p => rowHtml(p)).join("")}</details>` : "");
  return `<section class="td-sec td-lecturers" aria-label="${esc(TEXTS.lecturers)}"><div class="row between wrap"><h3>${icon("users", 16)} ${esc(TEXTS.lecturers)}</h3>${all.length > 1 ? `<button type="button" class="btn sm" data-mail-all aria-label="${esc(TEXTS.writeAll)}">${icon("mail", 14)} ${esc(TEXTS.writeAll)}</button>` : ""}</div>${body}</section>`;
}

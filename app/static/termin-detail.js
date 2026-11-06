// Termin-Detail im Termin-Panel (Stundenplan, Lernkalender) in Web und Windows (06.11.2026), wie TerminDetailViews.swift:
// Raum (Klick: aufloesen und sofort Route zu Fuss in Google Maps; nicht eindeutig: Raumfinder mit vorbelegter Suche;
// HsH/Hildesheim: "In Karten suchen") und alle Lehrenden des Kurses (nur LUH). Klick auf eine E-Mail: neue Uni-Mail mit
// Empfaenger und Betreff "Frage zu <Kurs>" (gesendet erst mit "Senden"); Uni-Mail nicht verbunden: zuerst verbinden oder
// Mail-Programm; ohne Adresse "Nachricht in Stud.IP". Regeln in termin-detail-logic.js.
import { $, $$, api, icon, modal, toast } from "./core.js?v=46";
import * as T from "./termin-detail-logic.js?v=1";

const { esc } = T;

function ensureCss() {
  if (document.getElementById("tdCss")) return;
  const s = document.createElement("style");
  s.id = "tdCss";
  s.textContent = `.td-sec{margin:0 0 .9rem}.td-sec h3{font-size:.95rem;margin:0 0 .4rem;display:flex;gap:.4rem;align-items:center}
.td-room{display:flex;flex-direction:column;align-items:flex-start;gap:.25rem;margin-bottom:.5rem}
.td-route{display:flex;align-items:center;gap:.6rem;width:100%;min-height:52px;padding:.55rem .75rem;border:1px solid var(--line);border-radius:var(--r,12px);background:var(--surface);color:var(--text);text-align:left;cursor:pointer;font:inherit}
.td-route:hover,.td-route:focus-visible{border-color:var(--accent)}.td-route>span{flex:1;display:flex;flex-direction:column;min-width:0;overflow-wrap:anywhere}
.td-route small{color:var(--muted)}.td-route svg{color:var(--accent-text,var(--accent));flex:none}
.td-room-text{flex-direction:row;flex-wrap:wrap;align-items:center;gap:.5rem}.td-room-text>span{overflow-wrap:anywhere}
.td-lecturers .lec-row{padding:.6rem 0;border-bottom:1px solid var(--line)}.td-lecturers .lec-row:last-child{border-bottom:0}
.td-lecturers .lec-mail,.td-lecturers .btn,.td-tutors summary{min-height:44px}.td-lecturers .lec-mail{overflow-wrap:anywhere;text-align:left}
.td-tutors summary{display:flex;align-items:center;cursor:pointer;font-weight:650;color:var(--text-2,var(--text))}`;
  document.head.append(s);
}

async function resolvePart(text) {
  try { return (await api(`/rooms/resolve?text=${encodeURIComponent(text)}`)).parts?.[0] || null; } catch { return null; }
}

/** Klick auf den Raum: Route zu Fuss sofort, sonst Raumfinder mit der Suche */
async function startRoute(text) {
  const r = T.route((await resolvePart(text)) || { text, status: "none" }, false);
  if (r.kind === "route") window.open(r.url, "_blank", "noopener");
  else if (r.kind === "search") location.hash = `#/raumfinder?q=${encodeURIComponent(r.query || text)}`;
}

async function searchMaps(text) {
  const p = await resolvePart(text);
  const u = p?.maps?.google;
  if (typeof u === "string" && u.startsWith("https://")) window.open(u, "_blank", "noopener");
  else toast("Der Ort ließ sich nicht suchen.");
}

async function uniMailStatus() {
  try { return await api("/sogo/status"); } catch { return null; }
}

/** E-Mail an `to` (eine oder alle Lehrenden) */
async function write(to, title, person) {
  const subj = T.subject(title);
  const choice = T.mailChoice(to, T.uniMailState(await uniMailStatus()));
  if (choice === "compose") return (await import("./uni-mail.js?v=2")).composeTo(to.join(", "), subj);
  if (choice === "mailto") { const u = T.mailto(to, subj); if (u) location.href = u; return; }
  if (choice === "studip") { if (person) (await import("./lecturers.js?v=3")).studipMessage(person, title); return; }
  const m = modal(`<h3>${icon("mail", 18)} ${esc(T.TEXTS.connectTitle)}</h3><p class="muted">${esc(T.TEXTS.connectMessage)}</p>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn" data-mailapp>${esc(T.TEXTS.mailApp)}</button>
    <a class="btn primary" href="#/unimail" data-connect>${esc(T.TEXTS.connect)}</a></div>`);
  $("[data-mailapp]", m).onclick = () => { m.remove(); const u = T.mailto(to, subj); if (u) location.href = u; };
  $("[data-connect]", m).onclick = () => m.remove();
}

/** Raum und Lehrende in `host` (Termin-Panel); `e`: room, course_id, module_id; `title`: Kurs */
export async function mountTerminDetail(host, e, title) {
  if (!host) return;
  ensureCss();
  let finder = false;
  try { finder = !!(await api("/rooms/campuses")).finder; } catch { finder = false; }
  host.innerHTML = `${T.roomSectionHtml(e.room, finder, icon)}<div data-td-lect></div>`;
  $$("[data-route]", host).forEach(b => b.onclick = async () => { b.disabled = true; try { await startRoute(b.dataset.route); } finally { b.disabled = false; } });
  $$("[data-maps]", host).forEach(b => b.onclick = () => searchMaps(b.dataset.maps));
  const q = T.lecturersQuery(e);
  if (!q) return;
  let d;
  try { d = await api(`/lecturers?${q}`); } catch { return; }
  const box = $("[data-td-lect]", host);
  if (!box) return;
  box.innerHTML = T.lecturersSectionHtml(d, icon);
  const people = d.people || [];
  const by = Object.fromEntries(people.map(p => [p.id, p]));
  $$("[data-mail]", box).forEach(b => b.onclick = () => write([b.dataset.mail], title, by[b.closest(".lec-row")?.dataset.id]));
  $$("[data-msg]", box).forEach(b => b.onclick = () => by[b.dataset.msg] && write([], title, by[b.dataset.msg]));
  $("[data-mail-all]", box)?.addEventListener("click", () => write(T.recipients(people), title, null));
}

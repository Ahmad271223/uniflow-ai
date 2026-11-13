// Lehrende und Kontakte (LUH, Stud.IP) in Web und Windows (06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md), wie
// LecturersViews.swift: Bereich "Lehrende" in der Moduluebersicht (`mountModuleLecturers`, nur mit Eintraegen, an HsH und
// Hildesheim unsichtbar) und Seite #/lehrende mit Suche nach Name oder Modul (erreichbar von Uni-Mail und der Modulseite).
// Klick auf die E-Mail: neue E-Mail in Uni-Mail mit dem Empfaenger (am PC mit verbundener Uni-Mail), sonst mailto:.
// "Nachricht in Stud.IP": Fenster, das ueber POST /api/lecturers/{id}/message sendet (nur Lehrende der eigenen Kurse,
// genau ein Versuch); Ausweg "In Stud.IP schreiben". Raeume fuehren zum Raumfinder (.room-link, app.js).
import { $, $$, api, icon, modal, toast } from "./core.js?v=47";
import * as L from "./lecturers-logic.js?v=1";

const { esc } = L;

async function uniMailConnected() {
  try { const s = await api("/sogo/status"); return !!(s.available && s.connected); } catch { return false; }
}

async function mail(email, person, module) {
  const a = L.mailAction(email, await uniMailConnected());
  if (!a) return;
  if (a.kind === "mailto") { location.href = a.url; return; }
  const m = await import("./uni-mail.js?v=3");
  m.composeTo(a.to, L.subject(person, module));
}

export function studipMessage(p, module) {
  const md = modal(`<h3>${icon("mail", 18)} Nachricht an ${esc(p.name)}</h3>
    <label class="field">Betreff<input class="input" data-f="subject" value="${esc(L.subject(p, module))}"></label>
    <label class="field">Nachricht<textarea class="input" data-f="text" rows="8" style="width:100%"></textarea></label>
    <p class="small muted">${esc(L.TEXTS.notice)}</p><div class="small" data-msg style="color:var(--bad)"></div>
    <div class="modal-foot"><a class="btn" href="${esc(p.message_url)}" target="_blank" rel="noopener">${esc(L.TEXTS.fallback)}</a>
      <button class="btn" data-close>Abbrechen</button><button class="btn primary" data-send>Senden</button></div>`);
  const f = k => $(`[data-f="${k}"]`, md);
  $("[data-send]", md).onclick = async e => {
    const b = e.currentTarget;
    if (!f("text").value.trim() || !f("subject").value.trim()) { $("[data-msg]", md).textContent = "Bitte Betreff und Text schreiben."; return; }
    b.disabled = true;
    try {
      await api(`/lecturers/${encodeURIComponent(p.id)}/message`, { method: "POST", body: { subject: f("subject").value, text: f("text").value } });
      md.remove(); toast(`Gesendet an ${p.name}.`);
    } catch (x) { $("[data-msg]", md).textContent = x.message; b.disabled = false; }   // nie still wiederholen
  };
}

function wire(box, people, module) {
  const by = Object.fromEntries(people.map(p => [p.id, p]));
  $$("[data-mail]", box).forEach(b => b.onclick = () => mail(b.dataset.mail, by[b.closest(".lec-row").dataset.id] || {}, module));
  $$("[data-msg]", box).forEach(b => b.onclick = () => by[b.dataset.msg] && studipMessage(by[b.dataset.msg], module));
}

/** Bereich "Lehrende" in der Moduluebersicht; ohne Eintraege bleibt `host` leer */
export async function mountModuleLecturers(host, moduleId, moduleName) {
  let d;
  try { d = await api(`/lecturers?module_id=${encodeURIComponent(moduleId)}`); } catch { return; }
  if (!L.shows(d)) return;
  const box = document.createElement("div");
  box.className = "card lec-card";
  box.innerHTML = `<div class="row between"><h3>${icon("users", 18)} ${esc(L.TEXTS.title)}</h3><a class="btn sm" href="#/lehrende">${esc(L.TEXTS.all)}</a></div>
    ${L.listHtml(d.people)}<p class="small muted">${esc(L.TEXTS.privacy)}</p>`;
  host.append(box);
  wire(box, d.people, moduleName);
}

/** Seite #/lehrende */
export async function viewLecturers(_, params, view) {
  view.innerHTML = `<div class="content"><div class="page-head"><div><h1>${esc(L.TEXTS.title)}</h1><div class="sub">${esc(L.TEXTS.sub)}</div></div></div>
    <div id="lecBody"><div class="muted small">Wird geladen …</div></div></div>`;
  const root = $("#lecBody", view);
  let q = "", timer = null;
  async function load() {
    let d;
    try { d = await api(`/lecturers${q ? `?q=${encodeURIComponent(q)}` : ""}`); } catch (e) { root.innerHTML = `<div class="card empty">${esc(e.message)}</div>`; return; }
    if (!d.available) { root.innerHTML = `<div class="card empty">${icon("users", 32)}<div>${esc(L.TEXTS.notAvailable)}</div></div>`; return; }
    if (!$("#lecQ", root)) {
      root.innerHTML = `<input class="input" id="lecQ" placeholder="${esc(L.TEXTS.search)}" aria-label="${esc(L.TEXTS.search)}" style="max-width:420px;margin-bottom:.8rem">
        <div class="card" id="lecList"></div><p class="small muted">${esc(L.TEXTS.privacy)}</p>`;
      $("#lecQ", root).oninput = e => { clearTimeout(timer); timer = setTimeout(() => { q = e.target.value.trim(); load(); }, 250); };
    }
    const list = $("#lecList", root);
    list.innerHTML = d.people.length ? `<div class="small muted">${esc(L.countLine(d))}</div>${L.listHtml(d.people, true)}`
      : `<div class="empty small">${esc(d.hint || "")}</div>`;
    wire(list, d.people);
  }
  await load();
}

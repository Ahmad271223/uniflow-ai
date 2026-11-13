// Seite "Uni-Mail" (#/unimail) in Web/Windows-App am PC (docs/UNI-MAIL-2026-11-05.md), nach UniMailViews.swift: Anmelden
// im Anmeldefenster (POST /api/sogo/login), Ordner, Liste mit Seiten, Suche, Lesen (HTML im abgeschotteten Rahmen ohne
// Skripte und ohne Netz), Anhänge, Antworten/Allen antworten/Weiterleiten/Neue E-Mail, Entwurf speichern, Senden nur mit
// Bestätigung ("confirm": true), Markieren, Papierkorb mit "Rückgängig" (Anfrage erst nach 5 s), Uni-Kalender übernehmen.
// Menüpunkt nur am PC an der LUH und der Uni Hildesheim (GET /api/sogo/status, Hochschule in "university"); im Dienst
// und an der HsH gibt es Uni-Mail nicht. Raum-Links (Raumfinder) und „Lehrende“ nur an der LUH.
import { $, $$, api, icon, toast, modal } from "./core.js?v=47";
import * as L from "./uni-mail-logic.js?v=2";

const { esc } = L;

export async function refreshNav() {
  let st;
  try { st = await api("/sogo/status"); } catch { return; }
  const nav = $("#nav");
  if (!nav) return;
  let a = $('a[data-route="unimail"]', nav);
  if (!L.showsNavItem(st)) { a?.remove(); return; }
  if (!a) {
    a = document.createElement("a");
    a.href = "#/unimail"; a.dataset.route = "unimail"; a.title = L.TEXTS.title;
    a.innerHTML = `${icon("mail", 18)}<span>${esc(L.TEXTS.title)}</span>`;
    const after = $('a[data-route="messages"]', nav) || $('a[data-route="dashboard"]', nav);
    if (after) after.after(a); else nav.prepend(a);
  }
  a.classList.toggle("active", /^#\/unimail/.test(location.hash));
  let b = $(".msg-count", a);
  const t = st.connected ? L.badgeText(st.unseen || 0) : "";
  if (!t) { b?.remove(); return; }
  if (!b) { b = document.createElement("span"); b.className = "msg-count"; a.append(b); }
  b.textContent = t;
  a.setAttribute("aria-label", `${L.TEXTS.title}, ${L.badgeLabel(st.unseen)}`);
}

// Neue E-Mail mit Empfaenger von aussen (Lehrende, lecturers.js, 06.11.2026): oeffnet Uni-Mail und das Schreibfenster
let pendingCompose = null, openCompose = null;
export function composeTo(to, subject = "") {
  const preset = { to, subject };
  if (openCompose && /^#\/unimail/.test(location.hash)) return openCompose(preset);
  pendingCompose = preset;
  location.hash = "#/unimail";
}

let started = false;
export function startNavItem() {
  if (started) return; started = true;
  refreshNav();
  window.addEventListener("hashchange", () => setTimeout(refreshNav, 400));
  setInterval(() => { if (!document.hidden) refreshNav(); }, 300000);
}

export async function viewUniMail(_, __, view) {
  let st;
  try { st = await api("/sogo/status"); } catch (e) { view.innerHTML = `<div class="content"><div class="card empty">${icon("alert", 32)}<div>${esc(e.message)}</div></div></div>`; return; }
  const T = L.texts(st);
  view.innerHTML = `<div class="content um-page">
    <div class="page-head"><div><h1>${esc(T.name)}</h1><div class="sub">${esc(T.sub)}</div></div>
      ${L.showsLecturers(st) ? `<div class="actions"><a class="btn sm" id="umLecturers" href="#/lehrende" title="Lehrende deiner Kurse mit E-Mail-Adresse und Sprechstunde">${icon("users", 14)} Lehrende</a></div>` : ""}</div>
    <div id="umBody"></div></div>`;
  const root = $("#umBody", view);
  if (!L.site(st)) { root.innerHTML = `<div class="card empty">${icon("mail", 32)}<div>${esc(T.unavailable)}</div></div>`; return; }
  if (!st.connected) {
    root.innerHTML = `<div class="card"><h3>${icon("mail", 18)} Uni-Mail verbinden</h3><p class="small muted">${esc(T.hint)}</p>
      <button class="btn primary" id="umLogin">Bei Uni-Mail anmelden</button></div>`;
    $("#umLogin", root).onclick = async () => {
      try { await api("/sogo/login", { method: "POST" }); toast("Anmeldefenster ist offen – bitte dort anmelden."); } catch (e) { toast(e.message, 5000); }
      const t = setInterval(async () => { try { const s = await api("/sogo/status"); if (s.connected) { clearInterval(t); viewUniMail(_, __, view); refreshNav(); } } catch {} }, 3000);
    };
    return;
  }
  let folder = "INBOX", query = "", listing = null, messages = [], page = 0, boxes = [];
  root.innerHTML = `<div class="row" style="gap:.5rem;flex-wrap:wrap;margin-bottom:.8rem">
      <select class="input" id="umFolder" style="max-width:220px" aria-label="Ordner"></select>
      <input class="input" id="umQ" placeholder="Suchen (Betreff, Absender)" style="max-width:280px">
      <button class="btn sm" id="umRefresh">${icon("refresh", 14)} Aktualisieren</button>
      <button class="btn primary sm" id="umNew">${icon("pen", 14)} Neue E-Mail</button></div>
    <div id="umErr"></div>
    <div class="grid" style="grid-template-columns:minmax(260px,380px) 1fr;gap:1rem;align-items:start">
      <div class="card" id="umList"></div><div id="umRead" class="card"><div class="muted small">Wähle links eine E-Mail aus.</div></div></div>
    <div class="card" id="umCal" style="margin-top:1rem"></div>`;
  const err = m => { $("#umErr", root).innerHTML = m ? `<div class="card flat" style="color:var(--bad);margin-bottom:.6rem">${esc(m)}</div>` : ""; };
  const fail = e => { err(e.message || String(e)); };

  async function loadBoxes() {
    try { boxes = (await api("/sogo/mailboxes")).mailboxes || []; } catch (e) { fail(e); }
    $("#umFolder", root).innerHTML = boxes.map(b => `<option value="${esc(b.path)}">${"  ".repeat(b.level || 0)}${esc(b.name)}</option>`).join("");
  }
  async function load() {
    try {
      listing = await api(`/sogo/messages?folder=${encodeURIComponent(folder)}&q=${encodeURIComponent(query)}`);
      messages = listing.messages || []; page = 0; err(""); renderList();
    } catch (e) { fail(e); }
  }
  async function more() {
    try {
      const r = await api(`/sogo/messages?folder=${encodeURIComponent(folder)}&page=${page + 1}&uids=${(listing.uids || []).join(",")}`);
      messages = messages.concat(r.messages || []); page += 1; renderList();
    } catch (e) { fail(e); }
  }
  function renderList() {
    const total = listing?.total || 0;
    $("#umList", root).innerHTML = `<div class="small muted">${total ? `${total} ${total === 1 ? "E-Mail" : "E-Mails"}` : "Keine E-Mails."}${listing?.stale ? " · ohne Netz" : ""}</div>`
      + messages.map(m => `<button class="um-row" data-uid="${m.uid}" style="display:block;width:100%;text-align:left;padding:.5rem;border:0;background:none;border-bottom:1px solid var(--line)">
        <b style="${m.read ? "font-weight:500" : ""}">${m.read ? "" : "● "}${esc(m.sender || "(ohne Absender)")}</b> <span class="small muted" style="float:right">${esc(m.date)}</span>
        <div class="small">${esc(m.subject || "(ohne Betreff)")}${m.attachment ? " " + icon("file", 12) : ""}${m.flagged ? " " + icon("flag", 12) : ""}</div></button>`).join("")
      + (messages.length < total && !listing?.stale ? `<button class="btn sm" id="umMore" style="margin-top:.6rem">Weitere laden</button>` : "");
    $$(".um-row", root).forEach(b => b.onclick = () => openMessage(+b.dataset.uid));
    const mb = $("#umMore", root); if (mb) mb.onclick = more;
  }
  async function openMessage(uid) {
    const box = $("#umRead", root);
    box.innerHTML = `<div class="muted small">Wird geladen …</div>`;
    let m;
    try { m = await api(`/sogo/message?folder=${encodeURIComponent(folder)}&uid=${uid}`); } catch (e) { box.innerHTML = `<div style="color:var(--bad)">${esc(e.message)}</div>`; return; }
    const row = messages.find(x => x.uid === uid); if (row && !row.read) { row.read = true; renderList(); refreshNav(); }
    const inTrash = (boxes.find(b => b.type === "trash") || {}).path === folder;
    box.innerHTML = `<h3>${esc(m.subject || "(ohne Betreff)")}</h3>
      <div class="small">Von: ${esc((m.from || []).map(L.addressText).join(", "))}<br>An: ${esc((m.to || []).map(L.addressText).join(", "))}${(m.cc || []).length ? `<br>Cc: ${esc(m.cc.map(L.addressText).join(", "))}` : ""}<br><span class="muted">${esc(m.date)}</span></div>
      <div class="row" style="gap:.4rem;flex-wrap:wrap;margin:.6rem 0">
        <button class="btn primary sm" data-a="reply">Antworten</button><button class="btn sm" data-a="replyall">Allen antworten</button>
        <button class="btn sm" data-a="forward">Weiterleiten</button><button class="btn sm" data-a="unread">Als ungelesen</button>
        <button class="btn sm" data-a="flag">Markieren</button>${inTrash ? `<button class="btn sm" data-a="restore">Wiederherstellen</button>` : `<button class="btn danger sm" data-a="trash">In den Papierkorb</button>`}</div>
      ${(m.attachments || []).map(a => `<a class="btn ghost sm" href="/api/sogo/attachment?path=${encodeURIComponent(a.path)}" download>${icon("file", 14)} ${esc(a.name)} ${esc(a.size)}</a>`).join(" ")}
      ${m.remote_blocked ? `<div class="small muted">Bilder aus dem Internet werden nicht geladen.</div>` : ""}
      ${m.html ? `<iframe sandbox="" title="Inhalt der E-Mail" style="width:100%;min-height:360px;border:0;background:#fff"></iframe>` : `<pre style="white-space:pre-wrap">${esc(m.text)}</pre>`}`;
    const f = $("iframe", box); if (f) f.srcdoc = L.frameDoc(m.html);
    $$("[data-a]", box).forEach(b => b.onclick = async () => {
      const a = b.dataset.a;
      try {
        if (a === "reply" || a === "replyall" || a === "forward") return compose(a, uid);
        if (a === "unread") { await api("/sogo/flags", { method: "POST", body: { folder, uids: [uid], read: false } }); if (row) row.read = false; renderList(); refreshNav(); }
        if (a === "flag") { await api("/sogo/flags", { method: "POST", body: { folder, uids: [uid], flagged: true } }); if (row) row.flagged = true; renderList(); }
        if (a === "restore") { await api("/sogo/restore", { method: "POST", body: { uids: [uid] } }); toast("In den Posteingang verschoben."); messages = messages.filter(x => x.uid !== uid); renderList(); }
        if (a === "trash") trash(uid);
      } catch (e) { fail(e); }
    });
  }
  function trash(uid) {
    const hidden = messages.filter(x => x.uid !== uid), keep = messages;
    messages = hidden; renderList(); $("#umRead", root).innerHTML = "";
    const bar = document.createElement("div"); bar.className = "card flat";
    bar.innerHTML = `In den Papierkorb verschoben. <button class="btn sm">Rückgängig</button>`;
    $("#umErr", root).append(bar);
    const t = setTimeout(async () => { bar.remove(); try { await api("/sogo/trash", { method: "POST", body: { folder, uids: [uid] } }); refreshNav(); } catch (e) { messages = keep; renderList(); fail(e); } }, 5000);
    $("button", bar).onclick = () => { clearTimeout(t); bar.remove(); messages = keep; renderList(); };
  }
  async function compose(action, uid, preset) {
    let draft;
    try { draft = await api("/sogo/draft", { method: "POST", body: { action, folder, uid } }); } catch (e) { return fail(e); }
    const md = modal(`<h3>${esc(L.composeTitle(action))}</h3><div class="small muted">Von: ${esc(draft.from)}</div>
      ${["to:An", "cc:Cc", "bcc:Bcc", "subject:Betreff"].map(x => { const [k, l] = x.split(":"); return `<label class="small">${l}<input class="input" data-f="${k}"></label>`; }).join("")}
      <textarea class="input" data-f="text" rows="12" style="width:100%"></textarea>
      <div class="small">${(draft.attachments || []).map(a => esc(a.name)).join(", ")}</div>
      <label class="small">Datei anhängen <input type="file" data-file></label>
      <p class="small muted">${esc(L.TEXTS.sendNote)}</p><div class="small" data-msg style="color:var(--bad)"></div>
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn" data-save>Als Entwurf speichern</button><button class="btn primary" data-send>Senden</button></div>`, { wide: true });
    const fv = k => $(`[data-f="${k}"]`, md);
    fv("to").value = (draft.to || []).join(", "); fv("cc").value = (draft.cc || []).join(", "); fv("bcc").value = (draft.bcc || []).join(", ");
    fv("subject").value = draft.subject || ""; fv("text").value = draft.text || "";
    if (preset?.to && !fv("to").value) fv("to").value = preset.to;
    if (preset?.subject && !fv("subject").value) fv("subject").value = preset.subject;
    const fields = () => ({ to: fv("to").value, cc: fv("cc").value, bcc: fv("bcc").value, subject: fv("subject").value, text: fv("text").value });
    const msg = t => { $("[data-msg]", md).textContent = t || ""; };
    $("[data-file]", md).onchange = async e => {
      const file = e.target.files[0]; if (!file) return;
      const fd = new FormData(); fd.append("draft", JSON.stringify(draft)); fd.append("file", file);
      try { const a = await api("/sogo/draft/attach", { method: "POST", body: fd }); toast(`Angehängt: ${a.name}`); } catch (x) { msg(x.message); }
    };
    $("[data-save]", md).onclick = async () => { try { await api("/sogo/draft/save", { method: "POST", body: L.body(draft, fields()) }); toast("Als Entwurf gespeichert."); } catch (x) { msg(x.message); } };
    $("[data-send]", md).onclick = async () => {
      const f = fields();
      if (!window.confirm(L.sendQuestion(f.to, f.cc, f.bcc))) return;
      try { await api("/sogo/draft/send", { method: "POST", body: L.body(draft, f, true) }); md.remove(); toast("Gesendet."); } catch (x) { msg(x.message); }
    };
  }
  async function calendar() {
    const box = $("#umCal", root);
    let ev = [];
    try { ev = (await api("/sogo/calendar/events?days=30")).events || []; } catch {}
    box.innerHTML = `<h3>${icon("calendar", 18)} Uni-Kalender</h3><p class="small muted">${esc(L.TEXTS.calendar)}</p>
      <button class="btn sm" data-d="7">Nächste 7 Tage übernehmen</button> <button class="btn sm" data-d="30">Nächste 30 Tage übernehmen</button>
      ${ev.slice(0, 30).map(e => `<div style="margin-top:.5rem"><div class="small muted">${esc(L.when(e))}</div><b>${esc(e.title)}</b>${e.location ? `<div class="small">${L.roomLinks(st) ? `<button class="room-link" data-room="${esc(e.location)}">${icon("map-pin", 12)} ${esc(e.location)}</button>` : esc(e.location)}</div>` : ""}</div>`).join("")}`;
    $$("[data-d]", box).forEach(b => b.onclick = async () => {
      try { const r = await api("/sogo/calendar/import", { method: "POST", body: { days: +b.dataset.d } }); toast(`${r.events} Termine übernommen.`); calendar(); } catch (e) { fail(e); }
    });
  }
  $("#umFolder", root).onchange = e => { folder = e.target.value; load(); };
  $("#umQ", root).onkeydown = e => { if (e.key === "Enter") { query = e.target.value; load(); } };
  $("#umRefresh", root).onclick = load;
  $("#umNew", root).onclick = () => compose("compose");
  openCompose = preset => compose("compose", undefined, preset);
  await loadBoxes();
  await load();
  if (pendingCompose) { const p = pendingCompose; pendingCompose = null; compose("compose", undefined, p); }
  calendar();
}

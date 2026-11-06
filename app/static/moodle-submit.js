// Blatt "In Moodle abgeben" (HsH) bzw. "In Learnweb abgeben" (Uni Hildesheim) im Web-Editor (Windows/Einzelplatz,
// 05.11.2026), nach MoodleSubmitSheet der iPad-App (apps/apple/UniFlow/Views/MoodleViews.swift, docs/HSH-2026-11-05.md).
// Aufgabe aus den Moodle-Fristen, Stand live, PDF aus derselben Funktion wie "Exportieren" (studip-submit.js buildPdf),
// "Als Entwurf hochladen" (noch keine Abgabe), danach "Jetzt abgeben" mit der verlangten Erklaerung. Jeder Schritt genau
// einmal und nur auf Knopfdruck (app/moodle_api.py).
import { $, api, icon, modal, toast } from "./core.js?v=46";
import * as L from "./moodle-submit-logic.js?v=1";
import { buildPdf } from "./studip-submit.js?v=3";

const { esc } = L;

async function call(path, opts) {
  const r = await fetch("/api/moodle/assign" + path, opts);
  let d = {};
  try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d.detail || `Fehler ${r.status}`); Object.assign(e, { code: d.code, webUrl: d.web_url, status: r.status }); throw e; }
  return d;
}

export async function openMoodleSubmit(editor) {
  const box = modal(`<h3>${icon("upload", 18)} <span id="msTitle">Abgeben</span></h3><div id="msBody" aria-live="polite"><p class="muted"><span class="uf-shimmer">Aufgaben werden geladen …</span></p></div>`, { wide: true });
  box.classList.add("sub-modal");
  const body = $("#msBody", box);
  const wireClose = () => box.querySelectorAll("[data-close]").forEach(b => b.onclick = () => box.remove());
  let info;
  try { info = await call(""); }
  catch (e) {
    body.innerHTML = `<p>${esc(e.status === 404 ? L.texts().notAvailable : e.message)}</p><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`;
    wireClose(); return;
  }
  const T = L.texts(info.source);
  $("#msTitle", box).textContent = T.title;
  const only = info.assignments.length === 1 ? info.assignments[0].cmid : "";
  const st = { cmid: only, status: null, confirm: null, accepted: false, name: L.finalFileName(editor.name || "Abgabe"), withNotes: true, pdf: null, busy: false };

  body.innerHTML = `<p class="sub-warn small">${icon("info", 14)} ${esc(T.notice)}</p><p class="tiny muted">${esc(T.notTested)}</p>
    ${info.connected ? "" : `<p class="small">${esc(T.notConnected)} <button class="btn sm" data-login>${esc(T.login)}</button></p>`}
    ${info.assignments.length ? `<label class="field"><span>${esc(T.assignment)}</span><select class="input" id="msAssign">${L.assignmentOptions(info.assignments, st.cmid)}</select></label>`
      : `<p class="muted small">${esc(T.empty)}</p>`}
    <div id="msStatus" class="small"></div>
    <label class="field"><span>${esc(T.fileName)}</span><input class="input" id="msName" maxlength="124" autocomplete="off"></label>
    <label class="row small" style="gap:.4rem"><input type="checkbox" id="msNotes" checked> ${esc(T.withNotes)}</label>
    <p class="small" id="msPreview"></p>
    <div id="msConfirm"></div>
    <div id="msErr"></div>
    ${info.history?.length ? `<details class="sub-hist"><summary>${esc(T.history)} (${info.history.length})</summary><ul>${info.history.map(h => `<li class="small">${esc(h.line)}</li>`).join("")}</ul></details>` : ""}
    <div class="modal-foot"><button class="btn" data-close>Schließen</button><a class="btn" id="msOpen" target="_blank" rel="noopener" hidden>${esc(T.open)}</a><button class="btn" id="msDraft" disabled>${icon("upload", 15)} ${esc(T.draft)}</button></div>`;
  wireClose();
  const nameIn = $("#msName", box), draftBtn = $("#msDraft", box), openLink = $("#msOpen", box);
  nameIn.value = st.name;
  const login = async () => { try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden", 4000); } catch (x) { toast(x.message, 4000); } };
  box.querySelectorAll("[data-login]").forEach(b => b.onclick = login);

  function showError(e) {
    const host = $("#msErr", box);
    host.innerHTML = `<div class="sub-err" role="alert">${icon("alert", 14)} ${esc(e.message)}${L.needsLogin(e.code) ? ` <button class="btn sm primary" data-login>${esc(T.login)}</button>` : ""}${e.webUrl ? ` <a class="btn sm" href="${esc(e.webUrl)}" target="_blank" rel="noopener">${esc(T.open)}</a>` : ""}</div>`;
    host.querySelectorAll("[data-login]").forEach(b => b.onclick = login);
  }
  function paint() {
    draftBtn.disabled = !L.canDraft(st);
    const go = $("#msGo", box);
    if (go) go.disabled = !L.canSubmit(st);
    const a = info.assignments.find(x => String(x.cmid) === String(st.cmid));
    openLink.hidden = !a; if (a) openLink.href = a.url;
  }
  function drawConfirm() {
    const host = $("#msConfirm", box);
    if (!st.confirm || st.status?.state === "Abgegeben") { host.innerHTML = ""; paint(); return; }
    host.innerHTML = `<div class="card flat">${st.confirm.statement != null ? `<label class="row small" style="gap:.4rem;align-items:flex-start"><input type="checkbox" id="msStatement"> ${esc(st.confirm.statement)}</label>` : ""}
      <button class="btn danger" id="msGo" disabled>${icon("check", 15)} ${esc(T.submit)}</button></div>`;
    $("#msStatement", host)?.addEventListener("change", e => { st.accepted = e.target.checked; paint(); });
    $("#msGo", host).onclick = submitNow;
    paint();
  }
  async function loadConfirm() {
    st.confirm = null; st.accepted = false;
    if (st.status?.state === "Entwurf gespeichert" && st.status.can_submit) {
      try { st.confirm = await call(`/${st.cmid}/confirm`); } catch (e) { showError(e); }
    }
    drawConfirm();
  }
  async function loadStatus() {
    st.status = null; st.confirm = null; $("#msErr", box).innerHTML = ""; drawConfirm();
    const host = $("#msStatus", box);
    if (!st.cmid) { host.innerHTML = ""; paint(); return; }
    host.innerHTML = `<span class="uf-shimmer">${esc(T.loading)}</span>`;
    try { st.status = await call(`/${st.cmid}`); host.innerHTML = `<b>${esc(T.state)}</b>${L.statusHtml(st.status, T)}`; }
    catch (e) { host.innerHTML = ""; showError(e); }
    await loadConfirm();
  }
  async function build() {
    st.pdf = null; paint();
    const pv = $("#msPreview", box);
    pv.innerHTML = `<span class="uf-shimmer">${esc(T.building)}</span>`;
    try { st.pdf = await buildPdf(editor, st.withNotes); pv.textContent = `${st.pdf.pages === 1 ? "1 Seite" : `${st.pdf.pages} Seiten`} bereit`; }
    catch (e) { pv.textContent = `PDF nicht erstellt: ${e.message}`; }
    paint();
  }
  async function uploadDraft() {
    if (draftBtn.disabled) return;
    st.busy = true; paint(); $("#msErr", box).innerHTML = "";
    const fd = new FormData();
    fd.append("file", new Blob([st.pdf.bytes], { type: "application/pdf" }), L.finalFileName(st.name));
    fd.append("file_name", L.finalFileName(st.name));
    try {
      const r = await call(`/${st.cmid}/draft`, { method: "POST", body: fd });
      st.status = r.status;
      $("#msStatus", box).innerHTML = `<b>${esc(T.state)}</b>${L.statusHtml(st.status, T)}<p class="small"><span class="badge ok">${icon("check", 12)} Entwurf gespeichert</span> Datei: ${esc(r.saved_name)}</p>`;
      await loadConfirm();
    } catch (e) { showError(e); }
    st.busy = false; paint();
  }
  async function submitNow() {
    if (!L.canSubmit(st)) return;
    st.busy = true; paint(); $("#msErr", box).innerHTML = "";
    try {
      const r = await call(`/${st.cmid}/submit`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ statement_accepted: !!st.accepted }) });
      st.status = r.status; st.confirm = null;
      $("#msStatus", box).innerHTML = `<b>${esc(T.state)}</b>${L.statusHtml(st.status, T)}<p class="small"><span class="badge ok">${icon("check", 12)} ${esc(r.record?.line || "Abgegeben")}</span></p>`;
      drawConfirm();
    } catch (e) { showError(e); }
    st.busy = false; paint();
  }

  $("#msAssign", box)?.addEventListener("change", e => { st.cmid = e.target.value; loadStatus(); });
  nameIn.oninput = e => { st.name = e.target.value; paint(); };
  $("#msNotes", box).onchange = e => { st.withNotes = e.target.checked; build(); };
  draftBtn.onclick = uploadDraft;
  if (st.cmid) loadStatus();
  build();
}

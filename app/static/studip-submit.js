// Blatt "In Stud.IP abgeben" im Web-Editor (Windows/Einzelplatz, 05.11.2026), nach StudIPSubmitSheet.swift der iPad-App
// (docs/ABGEBEN-STUDIP-2026-11-05.md). Die PDF kommt aus derselben Funktion wie "Exportieren" (Editor.exportPdf mit
// { bytes: true }); "Notizen und Blätter mitschicken" flicht Seitennotizen und Blaetter daneben hinter ihre Folie
// (side-notes.js, wie NotesExport auf dem iPad). Kurs, Ordner (Hausaufgabenordner zuerst), Dateiname "Nachname_Blatt3.pdf",
// Vorschau, "Jetzt abgeben" (genau ein Hochladen, app/studip_submit.py), danach "In Stud.IP öffnen" im App-Fenster.
import { $, api, icon, modal, toast } from "./core.js?v=44";
import * as L from "./studip-submit-logic.js?v=1";

const { esc } = L;

function ensureCss() {
  if (document.getElementById("studip-tools-css")) return;
  const l = document.createElement("link"); l.id = "studip-tools-css"; l.rel = "stylesheet"; l.href = "studip-tools.css?v=1"; document.head.append(l);
}

/** Fertige PDF fuer die Abgabe: {bytes, pages, notes}. Dieselbe Funktion wie "Exportieren" (editor.js, side-notes.js):
    deine Notizen auf den Folien gehen immer mit, leere Seitennotizen nie; der Schalter steuert Seitennotizen und Blaetter. */
export async function buildPdf(editor, withNotes) {
  const before = editor._expNotes;
  editor._expNotes = withNotes;
  try { return await editor.exportPdf(null, false, false, { bytes: true }); }
  finally { editor._expNotes = before; }
}

async function call(path, opts) {
  const r = await fetch("/api" + path, opts);
  let d = {};
  try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d.detail || `Fehler ${r.status}`); Object.assign(e, { code: d.code, webUrl: d.web_url, status: r.status }); throw e; }
  return d;
}

export async function openSubmit(editor) {
  ensureCss();
  const box = modal(`<h3>${icon("upload", 18)} ${esc(L.TEXTS.title)}</h3><div id="subBody" aria-live="polite"><p class="muted"><span class="uf-shimmer">Kurse werden geladen …</span></p></div>`, { wide: true });
  box.classList.add("sub-modal");
  const body = $("#subBody", box);
  const close = `<div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`;
  const wireClose = () => box.querySelectorAll("[data-close]").forEach(b => b.onclick = () => box.remove());
  let info;
  try { info = await call(`/studip/submit?file_id=${encodeURIComponent(editor.fileId)}`); }
  catch (e) { body.innerHTML = `<p>${esc(e.status === 404 ? L.TEXTS.notAvailable : e.message)}</p>${close}`; wireClose(); return; }

  const st = { course: info.suggested_course || "", folders: null, folder: null, name: "", nameEdited: false, withNotes: true, pdf: null, busy: false };
  body.innerHTML = `<p class="sub-warn small">${icon("info", 14)} ${esc(info.warning)}</p>
    ${info.connected ? "" : `<p class="small">${esc(L.TEXTS.notConnected)} <button class="btn sm" data-login>${esc(L.TEXTS.login)}</button></p>`}
    ${info.courses.length ? "" : `<p class="muted small">${esc(L.TEXTS.noCourses)}</p>`}
    <label class="field"><span>${esc(L.TEXTS.course)}</span><select class="input" id="subCourse">${L.courseOptions(info.courses, st.course)}</select></label>
    <div class="field"><span>${esc(L.TEXTS.folder)}</span><div id="subFolders" class="small muted">Wähle einen Kurs.</div></div>
    <label class="field"><span>${esc(L.TEXTS.fileName)}</span><input class="input" id="subName" maxlength="124" autocomplete="off"></label>
    <label class="row small" style="gap:.4rem"><input type="checkbox" id="subNotes" checked> ${esc(L.TEXTS.withNotes)}</label>
    <p class="tiny muted">${esc(L.TEXTS.withNotesHint)}</p>
    <p class="small" id="subPreview"></p>
    <div id="subErr"></div>
    ${info.history?.length ? `<details class="sub-hist"><summary>${esc(L.TEXTS.history)} (${info.history.length})</summary><ul>${info.history.map(h => `<li class="small">${esc(h.line)} · ${esc(h.file_name)}${h.url ? ` · <a href="${esc(h.url)}" target="_blank" rel="noopener">${esc(L.TEXTS.open)}</a>` : ""}</li>`).join("")}</ul></details>` : ""}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="subGo" disabled>${icon("upload", 15)} ${esc(L.TEXTS.confirm)}</button></div>`;
  wireClose();
  const go = $("#subGo", box), nameIn = $("#subName", box);
  const paint = () => { go.disabled = st.busy || !L.canSubmit({ folder: st.folder, name: st.name, pdf: st.pdf }); };
  box.querySelectorAll("[data-login]").forEach(b => b.onclick = async () => {
    try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden", 4000); } catch (x) { toast(x.message, 4000); }
  });

  async function loadFolders() {
    const host = $("#subFolders", box);
    st.folders = null; st.folder = null; paint();
    if (!st.course) { host.textContent = "Wähle einen Kurs."; return; }
    host.innerHTML = `<span class="uf-shimmer">${esc(L.TEXTS.loadingFolders)}</span>`;
    try {
      const f = await call(`/studip/submit/folders?course_id=${encodeURIComponent(st.course)}&title=${encodeURIComponent(info.title || editor.name || "")}`);
      st.folders = f; st.folder = f.suggested;
      host.innerHTML = L.foldersHtml(f, st.folder); host.classList.remove("muted");
      host.querySelectorAll('input[name="subFolder"]').forEach(r => r.onchange = () => { st.folder = r.value; paint(); });
      if (!st.nameEdited) { st.name = f.file_name; nameIn.value = f.file_name; }
    } catch (e) { host.innerHTML = errHtml(e); wireErr(host); }
    paint();
  }
  async function build() {
    st.pdf = null; paint();
    const pv = $("#subPreview", box);
    pv.innerHTML = `<span class="uf-shimmer">${esc(L.TEXTS.building)}</span>`;
    try {
      const r = await buildPdf(editor, st.withNotes);
      st.pdf = r;
      const n = L.sizeNotice(r.bytes.length);
      pv.innerHTML = `${icon("file-text", 14)} ${esc(L.preview(r.pages, r.bytes.length))}${n ? `<br><span class="muted">${esc(n)}</span>` : ""}`;
    } catch (e) { pv.textContent = `PDF nicht erstellt: ${e.message}`; }
    paint();
  }
  function errHtml(e) {
    const link = e.webUrl && L.offersFolderLink(e.code) ? ` <a class="btn sm" href="${esc(e.webUrl)}" target="_blank" rel="noopener">${esc(L.TEXTS.openFolder)}</a>` : "";
    const login = L.needsLogin(e.code) ? ` <button class="btn sm primary" data-login>${esc(L.TEXTS.login)}</button>` : "";
    return `<div class="sub-err" role="alert">${icon("alert", 14)} ${esc(e.message)}${login}${link}</div>`;
  }
  function wireErr(el) {
    el.querySelectorAll("[data-login]").forEach(b => b.onclick = async () => {
      try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden", 4000); } catch (x) { toast(x.message, 4000); }
    });
  }

  $("#subCourse", box).onchange = e => { st.course = e.target.value; loadFolders(); };
  nameIn.oninput = e => { st.name = e.target.value; st.nameEdited = true; paint(); };
  $("#subNotes", box).onchange = e => { st.withNotes = e.target.checked; build(); };
  go.onclick = async () => {
    if (go.disabled) return;
    st.busy = true; paint(); go.innerHTML = `<span class="uf-shimmer">Wird hochgeladen …</span>`; $("#subErr", box).innerHTML = "";
    const fd = new FormData();
    fd.append("file", new Blob([st.pdf.bytes], { type: "application/pdf" }), L.finalFileName(st.name));
    fd.append("course_id", st.course); fd.append("folder_id", st.folder); fd.append("file_name", L.finalFileName(st.name));
    fd.append("document_id", editor.fileId); fd.append("with_notes", st.withNotes ? "1" : "0"); fd.append("pages", String(st.pdf.pages));
    try {
      const r = await call("/studip/submit", { method: "POST", body: fd });
      const course = info.courses.find(c => c.id === st.course)?.title || "Stud.IP";
      const folder = st.folders?.writable.find(x => x.id === st.folder)?.label || "";
      body.innerHTML = `<p><span class="badge ok">${icon("check", 13)} ${esc(L.doneText(course, folder))}</span></p><p class="small muted">${esc(r.record?.line || "")} · ${esc(r.record?.file_name || "")}</p>
        <div class="modal-foot"><a class="btn" href="${esc(r.url)}" target="_blank" rel="noopener">${esc(L.TEXTS.open)} ${icon("arrow-right", 14)}</a><button class="btn primary" data-close>Fertig</button></div>`;
      wireClose();
    } catch (e) {
      $("#subErr", box).innerHTML = errHtml(e); wireErr($("#subErr", box));
      st.busy = false; go.innerHTML = `${icon("upload", 15)} ${esc(L.TEXTS.confirm)}`; paint();
    }
  };
  if (st.course) loadFolders();
  build();
}

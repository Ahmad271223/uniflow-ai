// KI-Start (#/ki) wie auf dem iPad: ruhiger Start ("Was möchtest du heute lernen?", fünf farbige Aktionen, ein großes
// Frage-Feld mit Modul und Dokument), nach der ersten Frage ein Gespräch mit Antworten als Markdown und der Eingabe
// unten. Regeln in ai-start-logic.js (tests/js/ai-start.test.mjs); Fragen gehen an POST /api/ai/tutor wie die KI-Hilfe
// im Editor. Erreichbar über das Raster-Symbol in der KI-Hilfe und den Knopf "KI-Start" bei Tests & Wiederholung.
import { $, $$, api, esc, icon, toast, state } from "./core.js?v=46";
import * as L from "./ai-start-logic.js?v=2";
import { followUps, MODE_LABELS, needsPlan } from "./ai-panel.js?v=2";

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* nur Komfort */ } },
};
const RECENTS_KEY = "uf.ai.recents", COUNT_KEY = () => `uf.ai.count.${L.monthKey()}`;

export async function viewAiStart(_, params, view) {
  const [mods, lib, { md }] = await Promise.all([api("/modules").catch(() => []), api("/library").catch(() => ({ files: [] })), import("./editor.js?v=71")]);
  // in der Seitenleiste leuchtet "Tests & Wiederholung" (wie auf dem iPad)
  $$("[data-route]").forEach(a => a.classList.toggle("active", a.dataset.route === "exams"));
  const st = { module: 0, fileId: "", question: "", turns: [], pending: null, busy: false, error: null, exhausted: false, help: false, credits: null, explain: null, loaded: false, source: null };
  const docs = () => L.documents(lib.files, st.module);
  const attach = () => L.attachment(st.fileId, docs());
  if (!st.fileId) st.fileId = docs()[0]?.id || "";
  const pills = L.ACTIONS.map(a => `<button type="button" class="ai-pill tone-${a.tone}" data-act="${a.id}" aria-label="${esc(a.title)}: ${esc(a.sub)}"><span class="ai-pill-ic" aria-hidden="true">${icon(a.icon, 18)}</span><span class="ai-pill-t"><b>${esc(a.title)}</b><small>${esc(a.sub)}</small></span></button>`).join("");
  view.innerHTML = `<div class="content ai-start" id="aiRoot" data-layout="start">
    <div class="ai-top"><a class="btn ghost sm" href="#/exams">${icon("arrow-left", 14)} Tests</a><span class="spacer"></span><button type="button" class="btn sm" id="aiNew" hidden>${icon("plus", 14)} Neues Gespräch</button></div>
    <div class="ai-main">
      <div class="ai-head" id="aiHead"><span class="ai-logo" aria-hidden="true">${icon("sparkles", 28)}</span><h1>${esc(L.START_QUESTION)}</h1></div>
      <div class="ai-thread" id="aiThread" aria-live="polite"></div>
      <div class="ai-help" id="aiHelp" hidden></div>
      <div class="ai-bottom">
        <div class="ai-actions" id="aiActions" role="group" aria-label="Aktionen">${pills}</div>
        <form class="ai-composer" id="aiForm" autocomplete="off">
          <textarea id="aiQ" rows="2" placeholder="${esc(L.PLACEHOLDER)}" aria-label="Frage an die KI"></textarea>
          <div class="ai-composer-row"><label class="ai-chip" title="Modul als Kontext">${icon("layers", 14)}<select id="aiMod" aria-label="Modul"><option value="0">Alle Module</option>${mods.map(m => `<option value="${m.id}">${esc(m.name)}</option>`).join("")}</select></label>
            <span id="aiAttach"></span><span class="spacer"></span>
            <button type="submit" class="btn primary icon" id="aiSend" aria-label="Frage senden" title="Frage senden (Enter)">${icon("arrow-right", 18)}</button></div>
        </form>
        <div class="ai-status small muted" id="aiStatus"></div>
        <div class="ai-err small" id="aiErr" role="alert" hidden></div>
      </div>
      <section class="ai-recent" id="aiRecent" hidden></section>
    </div></div>`;
  const root = $("#aiRoot", view), q = $("#aiQ", view);

  const recents = () => store.get(RECENTS_KEY, []);
  const count = () => store.get(COUNT_KEY(), 0);
  const lay = () => L.layout(st.turns.length, !!st.pending);

  function drawAttach() {
    const a = attach();
    $("#aiAttach", view).innerHTML = a
      ? `<span class="ai-chip on"><button type="button" class="ai-chip-b" id="aiPick" aria-label="Angehängt: ${esc(a.label)}. Anderes Dokument wählen">${icon("file-text", 14)} <span class="ai-chip-t">${esc(a.label)}</span></button><button type="button" class="ai-chip-x" id="aiDrop" aria-label="Dokument entfernen">${icon("x", 13)}</button></span>`
      : `<button type="button" class="ai-chip" id="aiPick" aria-label="Dokument anhängen">${icon("file-text", 14)} <span class="ai-chip-t">Dokument anhängen</span></button>`;
    $("#aiPick", view).onclick = pickDoc;
    $("#aiDrop", view)?.addEventListener("click", () => { st.fileId = ""; drawAttach(); });
  }
  function pickDoc() {
    const list = docs().slice(0, 40);
    const body = list.length ? list.map(f => `<button type="button" class="ai-doc${f.id === st.fileId ? " on" : ""}" data-doc="${esc(f.id)}"><span>${icon("file-text", 15)}</span><span class="ai-doc-t"><b>${esc(L.docTitle(f))}</b><small>${[f.page_count ? `${f.page_count} ${f.page_count === 1 ? "Seite" : "Seiten"}` : "", f.last_opened ? "zuletzt geöffnet" : ""].filter(Boolean).join(" · ")}</small></span>${f.id === st.fileId ? icon("check", 15) : ""}</button>`).join("")
      : `<div class="empty small">Kein geladenes PDF in diesem Modul. Nach dem Abgleich mit der Hochschule stehen die Kursdateien hier.</div>`;
    const m = document.createElement("div"); m.className = "modal"; m.setAttribute("role", "dialog"); m.setAttribute("aria-modal", "true"); m.setAttribute("aria-label", "Dokument anhängen");
    m.innerHTML = `<div class="modal-box"><h3>${icon("file-text", 18)} Dokument anhängen</h3><p class="muted small">Die KI liest die erste Seite des Dokuments als Kontext deiner Frage.</p><div class="ai-doclist">${body}</div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div></div>`;
    m.addEventListener("click", e => { if (e.target === m) m.remove(); });
    $("#overlay").append(m); $("[data-close]", m).onclick = () => m.remove();
    $$("[data-doc]", m).forEach(b => b.onclick = () => { st.fileId = b.dataset.doc; m.remove(); drawAttach(); });
  }

  function drawHelp() {
    const box = $("#aiHelp", view); box.hidden = !st.help; if (!st.help) { box.innerHTML = ""; return; }
    const sec = s => `<div class="ai-help-s"><h3>${icon(s.icon, 14)} ${esc(s.title)}</h3><ul>${s.items.map(i => `<li>${esc(i)}</li>`).join("")}</ul></div>`;
    box.innerHTML = `<div class="card"><div class="row between"><h2>${icon("life-buoy", 18)} ${esc(L.HELP.title)}</h2><span class="row" style="gap:.4rem"><span class="badge neutral">${esc(L.HELP.costLine)}</span><button type="button" class="btn ghost icon sm" id="aiHelpX" aria-label="Hilfe schließen">${icon("x", 15)}</button></span></div>
      ${sec(L.HELP.can)}${sec(L.HELP.start)}<div class="ai-chips">${L.HELP.examples.map((t, i) => `<button type="button" class="chip" data-ex="${i}">${icon("sparkles", 13)} ${esc(t)}</button>`).join("")}</div>
      ${sec(L.HELP.without)}<a class="btn sm" href="#/settings">${icon("settings", 14)} Einstellungen öffnen</a></div>`;
    $("#aiHelpX", box).onclick = () => { st.help = false; drawHelp(); };
    $$("[data-ex]", box).forEach(b => b.onclick = () => { q.value = L.HELP.examples[+b.dataset.ex]; q.focus(); });
  }

  function drawThread() {
    const t = $("#aiThread", view);
    t.innerHTML = st.turns.map((x, i) => {
      const last = i === st.turns.length - 1 && !st.pending;
      const fu = last ? followUps(x.mode).filter(f => f[1] !== "flashcards") : [];
      return `<div class="ai-turn"><div class="ai-me">${esc(x.question).replace(/\n/g, "<br>")}</div>
        <div class="ai-bot"><div class="ai-bot-h">${icon("sparkles", 14)} ${esc(x.fileName ? `KI-Antwort · ${x.fileName}` : "KI-Antwort")}</div><div class="ai-md">${md(x.text)}</div>
          ${last && (fu.length || x.fileId) ? `<div class="ai-chips">${fu.map((f, k) => `<button type="button" class="chip" data-fu="${i}:${k}">${icon("sparkles", 13)} ${esc(f[0])}</button>`).join("")}${x.fileId ? `<a class="chip" href="#/doc/${encodeURIComponent(x.fileId)}">${icon("book", 13)} Im Dokument mit KI-Hilfe öffnen</a>` : ""}</div>` : ""}</div></div>`;
    }).join("") + (st.pending ? `<div class="ai-turn"><div class="ai-me">${esc(st.pending.label).replace(/\n/g, "<br>")}</div><div class="ai-bot muted"><span class="uf-shimmer">${esc(st.pending.busy || "Die KI denkt nach …")}</span></div></div>` : "");
    $$("[data-fu]", t).forEach(b => b.onclick = () => { const [i, k] = b.dataset.fu.split(":").map(Number); const x = st.turns[i]; const [label, mode, question] = followUps(x.mode).filter(f => f[1] !== "flashcards")[k]; if (x.fileId && x.fileId !== st.fileId) { st.fileId = x.fileId; drawAttach(); } send({ mode, question, label: question || label, busy: "Die KI antwortet …" }); });
  }

  function drawRecent() {
    const box = $("#aiRecent", view), list = recents();
    box.hidden = !(L.showsRecents(lay()) && list.length);
    if (box.hidden) { box.innerHTML = ""; return; }
    box.innerHTML = `<div class="row between"><h2>Zuletzt</h2><button type="button" class="btn ghost sm" id="aiRecentClear">Leeren</button></div><div class="ai-recent-g">${list.map((e, i) => `<button type="button" class="ai-rc" data-rc="${i}" aria-label="Zuletzt: ${esc(e.question)}"><b>${esc(e.question)}</b><span>${esc(L.plain(e.answer))}</span>${e.fileName ? `<small>${esc(e.fileName)}</small>` : ""}</button>`).join("")}</div>`;
    $("#aiRecentClear", box).onclick = () => { store.set(RECENTS_KEY, []); drawRecent(); };
    $$("[data-rc]", box).forEach(b => b.onclick = () => { const e = list[+b.dataset.rc]; st.help = false; st.turns = [{ question: e.question, text: e.answer, mode: "ask", fileId: e.fileId || "", fileName: e.fileName || "" }]; draw(); });
  }

  function draw() {
    root.dataset.layout = lay();
    $("#aiHead", view).hidden = lay() === "chat"; $("#aiNew", view).hidden = lay() !== "chat";
    $("#aiStatus", view).textContent = L.statusLine(count(), st.credits, st.explain, st.source);
    const err = $("#aiErr", view); err.hidden = !st.error;
    err.innerHTML = st.error ? `${esc(st.error)}${st.exhausted ? ` <a class="btn sm" href="#/abo">${icon("star", 13)} Tarif ansehen</a>` : ""}` : "";
    $("#aiSend", view).disabled = st.busy; $$(".ai-pill", view).forEach(b => b.disabled = st.busy && b.dataset.act !== "help");
    drawThread(); drawHelp(); drawRecent();
    if (lay() === "chat") { const th = $("#aiThread", view); th.lastElementChild?.scrollIntoView?.({ block: "start", behavior: "smooth" }); }
  }

  async function send({ mode = "ask", question = "", label, busy }) {
    if (st.busy) return;
    const f = st.fileId ? docs().find(d => d.id === st.fileId) : null;
    const body = L.requestBody({ mode, question, fileId: f?.id || "", moduleId: st.module, turns: st.turns });
    st.busy = true; st.error = null; st.exhausted = false; st.help = false; st.pending = { label: label || question || MODE_LABELS[mode] || mode, busy };
    if (mode === "ask") q.value = "";
    draw();
    try {
      const r = await api("/ai/tutor", { method: "POST", body });
      const text = L.answerText(r, mode);
      st.credits = r.credits || null; st.explain = r.explain || null;
      const a = { question: st.pending.label, text, mode, fileId: f?.id || "", fileName: f ? L.docTitle(f) : "" };
      st.turns.push(a); st.pending = null;
      store.set(COUNT_KEY(), count() + 1); store.set(RECENTS_KEY, L.addRecent(recents(), { question: a.question, answer: text, fileId: a.fileId, fileName: a.fileName }));
    } catch (e) {
      st.pending = null; if (mode === "ask" && !q.value) q.value = question;      // Frage zurueck ins Feld
      st.error = e.message || "Die KI ist gerade nicht erreichbar."; st.exhausted = needsPlan(e.code);
    }
    st.busy = false; draw();
  }

  // ---- Ereignisse
  $("#aiMod", view).onchange = e => {
    st.module = +e.target.value;
    if (!docs().some(d => d.id === st.fileId)) st.fileId = docs()[0]?.id || "";     // das Dokument des anderen Moduls passt nicht mehr
    drawAttach();
  };
  $("#aiForm", view).onsubmit = e => { e.preventDefault(); const v = q.value.trim(); if (v) send({ mode: "ask", question: v, label: v, busy: "Die KI liest deine Unterlagen …" }); };
  q.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); $("#aiForm", view).requestSubmit(); } });
  $("#aiNew", view).onclick = () => { if (st.busy) return; st.turns = []; st.help = false; st.error = null; st.exhausted = false; st.credits = null; st.explain = null; draw(); q.focus(); };
  $$(".ai-pill", view).forEach(b => b.onclick = () => {
    const id = b.dataset.act;
    if (id === "ask") { st.help = false; drawHelp(); q.focus(); }
    else if (id === "cards") location.hash = "#/cards?ki=1";                       // KI-Auftrag auf der Karteikarten-Seite
    else if (id === "explain") {
      const f = st.fileId ? docs().find(d => d.id === st.fileId) : docs()[0];
      if (!f) { toast("Wähle zuerst ein Dokument."); return pickDoc(); }
      st.fileId = f.id; drawAttach(); send({ mode: "summary", label: `Zusammenfassung: ${L.docTitle(f)}`, busy: `Die KI liest ${L.docTitle(f)} …` });
    }
    else if (id === "quiz") location.hash = `#/exams?neu=${st.module || ""}`;       // Dialog "Wochentest erstellen"
    else { st.help = !st.help; drawHelp(); if (st.help) $("#aiHelp", view).scrollIntoView?.({ block: "start", behavior: "smooth" }); }
  });
  drawAttach(); draw();
  // Weg der KI und Credits-Stand (am PC ueber das StudiNow-Konto) fuer die Statuszeile
  api("/ai/source").then(s => { st.source = s; if (!st.busy) $("#aiStatus", view).textContent = L.statusLine(count(), st.credits, st.explain, st.source); }).catch(() => {});
  if (params?.q) { q.value = params.q; }
  q.focus();
}

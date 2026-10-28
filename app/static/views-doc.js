// Dokument-Ansicht mit Tabs, Notizfläche, geteilter Ansicht und Zeitmesser
import { $, $$, api, can, esc, icon, toast, modal, debounce, typeBadge, diffBadge, TYPE_ICON, TYPE_TXT, state } from "./core.js?v=32";
import { PdfEditor } from "./editor.js?v=41";

const TABS_KEY = "uniflow-doc-tabs";
export const docTabs = { list: [], state: {} };
try { docTabs.list = JSON.parse(localStorage.getItem(TABS_KEY) || "[]"); } catch {}
function saveTabs() { try { localStorage.setItem(TABS_KEY, JSON.stringify(docTabs.list.slice(-12))); } catch {} }
export function rememberTab(id, title) { if (!docTabs.list.some(t => t.id === id)) { docTabs.list.push({ id, title }); saveTabs(); } }
export function closeTab(id) { docTabs.list = docTabs.list.filter(t => t.id !== id); delete docTabs.state[id]; saveTabs(); }

export async function viewDoc(parts, params, view) {
  const id = parts[0]; let f;
  try { f = await api(`/files/${id}`); } catch { closeTab(id); view.innerHTML = `<div class="content"><div class="card empty">Dokument nicht gefunden.</div></div>`; return; }
  const title = f.title || f.ai_title || f.name;
  rememberTab(id, title);
  api(`/files/${id}/opened`, { method: "POST", body: {} }).catch(() => {});
  if (f.status === "neu") api(`/files/${id}`, { method: "PATCH", body: { status: "gelesen" } }).catch(() => {});
  const settings = await api("/settings").catch(() => ({}));
  view.className = "doc-view"; document.body.classList.add("doc-open"); let notesOpen = false, split = false;
  const hand = settings.hand === "left" ? "hand-left" : "hand-right";
  view.innerHTML = `<div class="doc-top" id="docTop"><button class="btn ghost icon sm doc-menu" id="docMenu" title="Menü">${icon("menu", 18)}</button><button class="btn ghost sm" id="docBack" title="Zurück">${icon("chevron-left", 18)}<span class="hide-s">Dokumente</span></button><div class="doc-tabs" id="docTabs"></div>
      ${params.task ? `<button class="btn ok sm" id="docDone" title="Aufgabe erledigt">${icon("check", 14)}<span class="hide-s"> Erledigt</span></button>` : ""}
      <select class="input doc-state" id="docState" title="Status des Dokuments"><option value="neu" ${f.status === "neu" ? "selected" : ""}>neu</option><option value="gelesen" ${f.status === "gelesen" || f.status === "neu" ? "selected" : ""}>gelesen</option><option value="erledigt" ${f.status === "erledigt" ? "selected" : ""}>erledigt</option></select>
      <button class="btn ghost icon sm" id="docFav" title="Favorit" style="color:${f.favorite ? "var(--warn)" : "var(--muted)"}">${icon("star", 16)}</button>
      <button class="btn ghost sm" id="docNotes" title="Notizfläche">${icon("note", 16)}<span class="hide-s"> Notizen</span></button><button class="btn ghost sm" id="docSplit" title="Zweites Dokument daneben öffnen">${icon("columns", 16)}<span class="hide-s"> Geteilt</span></button><button class="btn ghost icon sm" id="docFull" title="Vollbild">${icon("maximize", 16)}</button></div>
    <button class="fs-exit" id="fsExit" title="Vollbild verlassen">${icon("x", 15)} Vollbild beenden</button>
    <div class="doc-panes ${hand}" id="docPanes"><div class="doc-pane" id="paneA"></div><div class="split-handle" id="splitHandle" hidden title="Breite ziehen"><i></i></div><div class="doc-pane" id="paneB" hidden></div><div class="notes-pane" id="paneN" hidden><div class="nh">${icon("note", 16)} Eigene Notizen<span class="spacer"></span><span class="muted tiny" id="noteSaved"></span></div><textarea id="noteArea" placeholder="Hier frei schreiben und rechnen. Wird automatisch gespeichert.&#10;Für Handschrift: im Editor eine leere Notizseite einfügen (Seite +)."></textarea></div></div>`;
  renderTabs(id);
  $("#docBack").onclick = () => { if (history.length > 1) history.back(); else location.hash = f.module_id ? `#/modules/${f.module_id}` : "#/files"; };
  $("#docState").onchange = async () => { await api(`/files/${id}`, { method: "PATCH", body: { status: $("#docState").value } }); toast("Status gespeichert"); };
  $("#docFav").onclick = async () => { f.favorite = f.favorite ? 0 : 1; await api(`/files/${id}/favorite`, { method: "POST", body: { favorite: !!f.favorite } }); $("#docFav").style.color = f.favorite ? "var(--warn)" : "var(--muted)"; };
  $("#docFull").onclick = () => document.body.classList.toggle("fullscreen-doc");
  $("#fsExit").onclick = () => document.body.classList.remove("fullscreen-doc");
  $("#docMenu").onclick = () => { $("#sidebar").classList.toggle("open"); };
  $("#docDone")?.addEventListener("click", async () => { await api(`/tasks/${params.task}/status`, { method: "POST", body: { status: "erledigt" } }); toast("Aufgabe erledigt ✓"); location.hash = "#/plan"; });
  const edA = await mountDoc($("#paneA"), f, { page: +params.page || f.last_page || 1, penInput: settings.pen_input, onPage: debounce(p => api(`/files/${id}/opened`, { method: "POST", body: { last_page: p } }).catch(() => {}), 800), restore: docTabs.state[id] });
  let lastEd = edA;
  if (edA) { edA.tabId = id; edA.onActive = () => { lastEd = edA; }; edA.delegate = () => lastEd; $("#noteArea").value = edA.model.note || ""; $("#noteArea").oninput = debounce(() => { edA.model.note = $("#noteArea").value; edA.markDirty(); $("#noteSaved").textContent = "gespeichert"; }, 600); }
  $("#docNotes").onclick = () => { notesOpen = !notesOpen; $("#paneN").hidden = !notesOpen; $("#docPanes").classList.toggle("notes", notesOpen); layoutSplit(); };
  // geteilte Ansicht: Skript auf der Seite der freien Hand, Breite ziehbar und gemerkt
  const splitPct = () => { try { return Math.max(20, Math.min(65, +localStorage.getItem("doc-split") || 35)); } catch { return 35; } };
  const layoutSplit = () => {
    const P = $("#docPanes"), H = $("#splitHandle"); if (!P) return;
    if (!split) { P.style.gridTemplateColumns = ""; H.hidden = true; ["#paneA", "#paneB", "#paneN"].forEach(s => { $(s).style.order = ""; }); return; }
    const right = hand === "hand-right", pct = splitPct(), notes = notesOpen ? " 300px" : "";
    P.style.gridTemplateColumns = right ? `${pct}% 10px minmax(0, 1fr)${notes}` : `minmax(0, 1fr) 10px ${pct}%${notes}`;
    $("#paneB").style.order = right ? 1 : 3; H.style.order = 2; $("#paneA").style.order = right ? 3 : 1; $("#paneN").style.order = 4; H.hidden = false;
  };
  $("#splitHandle").onpointerdown = e => {
    e.preventDefault(); const H = e.currentTarget; try { H.setPointerCapture(e.pointerId); } catch {}
    const box = $("#docPanes").getBoundingClientRect();
    H.onpointermove = ev => { let pct = hand === "hand-right" ? (ev.clientX - box.left) / box.width * 100 : (box.right - ev.clientX) / box.width * 100; pct = Math.max(20, Math.min(65, pct)); try { localStorage.setItem("doc-split", pct.toFixed(1)); } catch {} layoutSplit(); };
    H.onpointerup = H.onpointercancel = () => { H.onpointermove = null; };
  };
  // Schliessen wirkt sofort; das Speichern des zweiten Dokuments laeuft im Hintergrund weiter (Entwurf liegt lokal)
  let splitGen = 0;
  const closeSplit = () => {
    split = false; splitGen++;
    if (edA) { edA.onToolState = null; lastEd = edA; }
    const P = $("#paneB"); P.hidden = true; $("#docPanes").classList.remove("split"); layoutSplit();
    const ed = state.editors.find(e => e.pane === "B");
    if (ed) { state.editors = state.editors.filter(e => e !== ed); ed.destroy().catch(e => console.error(e)); }
    P.innerHTML = "";
  };
  const openSplit = async (pick, page) => {
    if (split) closeSplit();
    const gen = ++splitGen; split = true;
    const P = $("#paneB");
    P.innerHTML = `<div class="pane-bar"><span class="t">${icon("book", 14)}<b>Lädt…</b></span><button class="btn ghost sm" data-close-split title="Zweites Dokument schließen">${icon("x", 14)} Schließen</button></div><div class="pane-body"></div>`;
    P.querySelector("[data-close-split]").onclick = () => { if (gen === splitGen) closeSplit(); };
    P.hidden = false; $("#docPanes").classList.add("split"); layoutSplit();
    let f2; try { f2 = await api(`/files/${pick}`); } catch { if (gen === splitGen) { toast("Dokument nicht gefunden"); closeSplit(); } return; }
    if (gen !== splitGen) return;
    $(".pane-bar b", P).textContent = f2.title || f2.ai_title || f2.name;
    const ed = await mountDoc($(".pane-body", P), f2, { page: page || f2.last_page || 1, penInput: settings.pen_input, pane: "B" });
    if (!ed || gen !== splitGen) return;
    ed.onActive = () => { lastEd = ed; }; if (edA) { ed.applyToolState(edA.toolState()); edA.onToolState = st => ed.applyToolState(st); }
  };
  $("#docSplit").onclick = async () => { if (split) return closeSplit(); const pick = await pickDocument(f.module_id); if (pick) openSplit(pick); };
  const isExercise = ["uebung", "loesung", "klausur"].includes(f.doc_type) || /übung|uebung|blatt|ueb\d|aufgabe/i.test(`${f.name} ${f.studip_folder || ""}`);
  if (edA && isExercise) setupScriptHint(edA, f, openSplit);   // Modul ermittelt der Server aus der Datei
}
// ---------------------------------------------------------------- Skriptsuche: unaufdringlicher Hinweis zur aktuellen Aufgabe
function setupScriptHint(ed, f, openSplit) {
  const box = document.createElement("div"); box.className = "script-hint"; box.hidden = true; $("#docPanes").append(box);
  const cache = new Map(), dismissed = new Set(); let timer = null, lastKey = null;
  const run = async () => {
    if (ed.destroyed || document.documentElement.classList.contains("ed-inking")) return;
    const ctx = await ed.taskContext().catch(() => null);
    if (!ctx || ctx.text.length < 40 || dismissed.has(ctx.key)) { box.hidden = true; return; }
    if (ctx.key === lastKey && !box.hidden) return; lastKey = ctx.key;
    let r = cache.get(ctx.key);
    if (!r) { try { r = await api("/related", { method: "POST", body: { file_id: f.id, text: ctx.text } }); cache.set(ctx.key, r); } catch { return; } }
    const hit = r.results && r.results[0]; if (!hit || ed.destroyed) { box.hidden = true; return; }
    box.innerHTML = `${icon("book", 16)}<div class="m"><b>Passende Skriptstelle${ctx.label.startsWith("Seite") ? "" : ` zu ${esc(ctx.label)}`}</b><span>${esc(hit.title)} · Seite ${hit.page}</span></div><button class="btn sm primary" data-open>${icon("columns", 14)} Öffnen</button><button class="btn ghost icon sm" data-x title="Für diese Aufgabe ausblenden">${icon("x", 14)}</button>`;
    box.title = `${hit.snippet}\n\nGemeinsame Begriffe: ${hit.terms.join(", ")}`; box.hidden = false;
    box.querySelector("[data-open]").onclick = () => { box.hidden = true; openSplit(hit.file_id, hit.page); };
    box.querySelector("[data-x]").onclick = () => { dismissed.add(ctx.key); box.hidden = true; };
  };
  const schedule = () => { clearTimeout(timer); timer = setTimeout(run, 2500); };
  ed.onInk = schedule; const prevOnPage = ed.onPage; ed.onPage = p => { prevOnPage?.(p); schedule(); };
  ed.scroll.addEventListener("scroll", schedule, { passive: true }); schedule();
}
function renderTabs(activeId) {
  const el = $("#docTabs"); if (!el) return;
  el.innerHTML = docTabs.list.map(t => `<div class="doc-tab ${t.id === activeId ? "active" : ""}" data-tab="${t.id}" title="${esc(t.title)}">${icon("file-text", 14)}<span>${esc(t.title)}</span><i class="x" data-x="${t.id}">${icon("x", 12)}</i></div>`).join("");
  const act = el.querySelector(".doc-tab.active"); if (act) el.scrollLeft = Math.max(0, act.offsetLeft - 60);
  $$("[data-tab]", el).forEach(d => d.onclick = e => { if (e.target.closest("[data-x]")) return; location.hash = `#/doc/${d.dataset.tab}`; });
  $$("[data-x]", el).forEach(x => x.onclick = e => { e.stopPropagation(); const id = x.dataset.x; closeTab(id); if (id === activeId) { const next = docTabs.list[docTabs.list.length - 1]; location.hash = next ? `#/doc/${next.id}` : "#/files"; } else renderTabs(activeId); });
}
function docFallback(host, f, msg, keep = false) {
  const box = document.createElement("div"); box.className = "card flat"; box.style.cssText = "margin:.4rem;background:var(--warn-soft);border-color:transparent";
  box.innerHTML = `<b>${icon("alert", 15)} Dokument wird nicht angezeigt</b><div class="small" style="margin:.3rem 0">${esc(msg)}</div><div class="row wrap"><button class="btn sm primary" id="fbViewer">${icon("file-text", 14)} Im Browser-Viewer anzeigen</button><a class="btn sm" href="/api/files/${f.id}/content" target="_blank">${icon("download", 14)} In neuem Tab öffnen</a><button class="btn sm ghost" id="fbRetry">${icon("refresh", 14)} Neu laden</button><a class="btn sm ghost" href="#/settings?tab=diag">Diagnose</a></div>`;
  if (!keep) host.innerHTML = ""; host.prepend(box);
  box.querySelector("#fbViewer").onclick = () => { host.innerHTML = `<iframe src="/api/files/${f.id}/content#toolbar=1" style="flex:1;border:1px solid var(--line);border-radius:var(--r);min-height:70vh;background:#fff"></iframe>`; };
  box.querySelector("#fbRetry").onclick = () => location.reload();
}
export async function mountDoc(host, f, { page = 1, onPage, penInput, restore, pane } = {}) {
  host.innerHTML = "";
  const isPdf = !!f.exists && (/\.pdf$/i.test(f.local_path || "") || /\.pdf$/i.test(f.name || "") || /pdf/i.test(f.mime || ""));
  const notebook = f.kind === "notebook" || f.kind === "whiteboard" || (!f.local_path && f.course_id === "__user__");
  if (!f.exists && !notebook) { host.innerHTML = `<div class="pane-empty">${icon("alert", 28)}Datei ist lokal nicht vorhanden. Bitte Sync ausführen.</div>`; return null; }
  if (isPdf || notebook) {
    const div = document.createElement("div"); div.className = "ed-host"; host.append(div);
    const readOnly = !can("can_annotate_pdf");      // Studora Free im Dienst: lesen ja, schreiben ab Plus (Server prueft ebenso)
    if (readOnly) { const n = document.createElement("div"); n.className = "ed-readonly-note"; n.innerHTML = `${icon("info", 14)} Nur lesen – Notizen, Textmarker und Apple Pencil gibt es ab <a href="#/abo">Studora Plus</a>.`; host.insertBefore(n, div); }
    const ed = new PdfEditor(div, { fileId: f.id, name: f.title || f.name, url: notebook && !f.local_path ? null : `/api/files/${f.id}/content`, penInput, onPage, readOnly,
      onStatus: s => { const el = $(".ed-status", div); if (el) { el.textContent = s; el.title = s; } if (host.id === "paneA") { const d = $("#docStatus"); if (d) d.textContent = s; } },
      onAccessory: k => { if (k === "timer") toggleTimer(true); } });
    ed.pane = pane; state.editors.push(ed);           // vor dem Laden markieren: Schliessen waehrend des Ladens findet den Editor
    try { await ed.load(); if (ed.destroyed) return null; if (restore) ed.restoreState(restore); else if (page > 1) (ed._initialGoto = setTimeout(() => ed.goToPage(page - 1), 300)); } catch (e) { if (ed.destroyed) return null; console.error(e); state.errors?.push({ t: new Date().toISOString(), msg: e.message, src: "editor" }); docFallback(host, f, e.message); return null; }
    // Sicherheitsnetz: wenn nach dem Laden keine Seite sichtbar ist, Hinweis + Browser-Viewer anbieten
    setTimeout(() => { if (ed.destroyed) return; const sc = div.querySelector(".ed-scroll"); const visible = sc && sc.clientHeight > 40 && div.querySelectorAll(".ed-page").length > 0 && [...div.querySelectorAll("canvas.ed-pdf")].some(c => c.width > 0); if (!visible) docFallback(host, f, `Die Seiten wurden nicht dargestellt (Seiten: ${ed.pages?.length ?? 0}, Ansichtshöhe: ${sc ? sc.clientHeight : 0}px, Browser: ${navigator.userAgent.split(") ").pop()}).`, true); }, 2500);
    return ed;
  }
  if (/\.(py|txt|md|c|h|java|pf|csv|tex)$/i.test(f.name)) { const pre = document.createElement("div"); pre.className = "nonpdf"; pre.textContent = await (await fetch(`/api/files/${f.id}/content`)).text(); host.append(pre); return null; }
  if (/\.docx$/i.test(f.name)) {
    // Word nur ansehen (Entscheidung 28.10.2026); HTML kommt geprueft vom Backend (app/docx_view.py)
    host.innerHTML = `<div class="pane-empty">Word-Dokument wird geladen …</div>`;
    try {
      const r = await fetch(`/api/files/${f.id}/docx`); const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.detail || `Fehler ${r.status}`);
      host.innerHTML = `<div class="docx-wrap"><div class="docx-bar"><span class="badge neutral">${icon("file-text", 12)} Word – nur ansehen</span><span class="spacer"></span><a class="btn sm" href="/api/files/${f.id}/content" download>${icon("download", 14)} Herunterladen</a></div><article class="docx-view">${d.html}</article></div>`;
    } catch (e) {
      host.innerHTML = `<div class="pane-empty">${icon("alert", 24)} ${e.message}<a class="btn sm" href="/api/files/${f.id}/content" download>${icon("download", 14)} Herunterladen</a></div>`;
    }
    return null;
  }
  if (/\.(png|jpe?g|gif|webp)$/i.test(f.name)) { host.innerHTML = `<div class="nonpdf" style="text-align:center"><img src="/api/files/${f.id}/content" style="max-width:100%"></div>`; return null; }
  host.innerHTML = `<div class="pane-empty">Keine Vorschau für diesen Dateityp.<a class="btn sm" href="/api/files/${f.id}/content" target="_blank">${icon("download", 14)} Öffnen / Herunterladen</a></div>`; return null;
}
export function pickDocument(moduleId) {
  return new Promise(async resolve => {
    const files = (await api("/files")).filter(x => /\.pdf$/i.test(x.name)); let q = "";
    const m = modal(`<h3>Zweites Dokument öffnen</h3><input class="input" id="pdQ" placeholder="Suchen… (z. B. Übungsblatt)"><div class="list" id="pdList" style="max-height:50vh;overflow:auto;margin-top:.5rem"></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`);
    const render = () => { const fs = files.filter(x => (!q || (x.name + " " + (x.ai_title || "") + " " + (x.subject || "")).toLowerCase().includes(q))).sort((a, b) => (b.module_id === moduleId) - (a.module_id === moduleId) || b.chdate - a.chdate).slice(0, 60); $("#pdList", m).innerHTML = fs.map(x => `<div class="item" data-id="${x.id}">${icon(TYPE_ICON[x.doc_type] || "file", 16)}<div class="main"><div class="title">${esc(x.ai_title || x.name)}</div><div class="sub">${esc(x.subject || "")} · ${esc(TYPE_TXT[x.doc_type] || "")}</div></div></div>`).join(""); $$("[data-id]", m).forEach(el => el.onclick = () => { m.remove(); resolve(el.dataset.id); }); };
    $("#pdQ", m).oninput = e => { q = e.target.value.toLowerCase(); render(); }; render(); m.addEventListener("click", e => { if (e.target === m) resolve(null); }); $("[data-close]", m).addEventListener("click", () => resolve(null));
  });
}

// ---------------------------------------------------------------- Zeitmesser (global, läuft über Ansichten hinweg)
const timer = { mode: "stopwatch", running: false, elapsed: 0, target: 25 * 60, startAt: 0, pomo: { work: 25, pause: 5, phase: "work", round: 1 }, open: false, int: null };
export function toggleTimer(open) {
  timer.open = open ?? !timer.open; renderTimer();
}
function fmt(s) { s = Math.max(0, Math.round(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }
function tick() { if (!timer.running) return; const now = Date.now(); timer.elapsed = timer.base + (now - timer.startAt) / 1000; if (timer.mode !== "stopwatch" && timer.elapsed >= timer.target) { timer.running = false; timer.elapsed = timer.target; try { new AudioContext().resume(); } catch {} toast(timer.mode === "pomodoro" ? (timer.pomo.phase === "work" ? "Pomodoro vorbei – Pause!" : "Pause vorbei – weiter geht's") : "Zeit abgelaufen"); if (timer.mode === "pomodoro") { timer.pomo.phase = timer.pomo.phase === "work" ? "pause" : "work"; if (timer.pomo.phase === "work") timer.pomo.round++; timer.target = (timer.pomo.phase === "work" ? timer.pomo.work : timer.pomo.pause) * 60; timer.elapsed = 0; timer.base = 0; } } renderTimer(); }
function renderTimer() {
  $("#timerWidget")?.remove(); $("#timerPill")?.remove();
  if (!timer.open) { if (timer.running || timer.elapsed > 0) { const p = document.createElement("div"); p.id = "timerPill"; p.className = "timer-pill"; p.textContent = (timer.mode === "stopwatch" ? fmt(timer.elapsed) : fmt(timer.target - timer.elapsed)); p.onclick = () => toggleTimer(true); document.body.append(p); } return; }
  const w = document.createElement("div"); w.id = "timerWidget"; w.className = "timer-widget";
  const left = timer.mode === "stopwatch" ? timer.elapsed : timer.target - timer.elapsed;
  w.innerHTML = `<div class="row between"><div class="seg">${[["stopwatch", "Stoppuhr"], ["countdown", "Countdown"], ["pomodoro", "Pomodoro"]].map(([k, l]) => `<button class="${timer.mode === k ? "active" : ""}" data-mode="${k}">${l}</button>`).join("")}</div><button class="btn ghost icon sm" data-t="close">${icon("x", 14)}</button></div>
    <div class="big ${timer.mode !== "stopwatch" && left <= 0 ? "done" : ""}">${fmt(left)}</div>
    ${timer.mode === "countdown" ? `<div class="row" style="justify-content:center;gap:.3rem">${[5, 15, 25, 45, 60].map(n => `<button class="chip" data-min="${n}">${n} min</button>`).join("")}</div>` : timer.mode === "pomodoro" ? `<div class="muted small" style="text-align:center">${timer.pomo.phase === "work" ? "Arbeiten" : "Pause"} · Runde ${timer.pomo.round} · ${timer.pomo.work}/${timer.pomo.pause} min</div>` : ""}
    <div class="row" style="justify-content:center;margin-top:.5rem"><button class="btn primary sm" data-t="toggle">${timer.running ? "Pause" : "Start"}</button><button class="btn sm" data-t="reset">Zurücksetzen</button></div>`;
  document.body.append(w);
  $$("[data-mode]", w).forEach(b => b.onclick = () => { timer.mode = b.dataset.mode; timer.running = false; timer.elapsed = 0; timer.base = 0; if (timer.mode === "pomodoro") { timer.pomo = { work: 25, pause: 5, phase: "work", round: 1 }; timer.target = 25 * 60; } if (timer.mode === "countdown") timer.target = 25 * 60; renderTimer(); });
  $$("[data-min]", w).forEach(b => b.onclick = () => { timer.target = +b.dataset.min * 60; timer.elapsed = 0; timer.base = 0; renderTimer(); });
  $("[data-t=close]", w).onclick = () => toggleTimer(false);
  $("[data-t=reset]", w).onclick = () => { timer.running = false; timer.elapsed = 0; timer.base = 0; renderTimer(); };
  $("[data-t=toggle]", w).onclick = () => { if (timer.running) { timer.running = false; timer.base = timer.elapsed; } else { timer.running = true; timer.base = timer.elapsed; timer.startAt = Date.now(); if (!timer.int) timer.int = setInterval(tick, 500); } renderTimer(); };
}

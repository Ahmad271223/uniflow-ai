// Karte "Fertige Fragen" je Lehrwoche im Modul (Pro AI): Saetze als Test starten, Themen, Hinweise und Loesungen mit
// Erklaerung aufklappbar. Regeln in week-sets-logic.js, Dienst app/week_library_api.py. Eingebunden von views-misc.js.
import { $, $$, api, esc, icon, toast, showError, can, state } from "./core.js?v=43";
import { RIGHT, POLL_MS, cardMode, statusText, setsLabel, keepPolling } from "./week-sets-logic.js?v=3";

const LOCK = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`;
const CSS = `.ws-card{border:1px solid var(--line);border-radius:12px;padding:.65rem .8rem;margin:.2rem 0 .7rem;background:var(--surface-2)}
.ws-head{display:flex;align-items:center;gap:.45rem;flex-wrap:wrap}.ws-head b{font-size:.95rem}.ws-head .spacer{flex:1}
.ws-card.locked{color:var(--muted)}.ws-sets{display:flex;flex-direction:column;gap:.35rem;margin:.55rem 0}
.ws-set{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}.ws-set span{flex:1;min-width:10rem}
.ws-card details{margin-top:.35rem}.ws-card summary{cursor:pointer;font-weight:600}.ws-card ul,.ws-card ol{margin:.3rem 0 .3rem 1.1rem;padding:0}
.ws-sol{margin:.3rem 0 .3rem .4rem}.ws-sol summary{font-weight:500}.ws-sol p{margin:.25rem 0}`;

function ensureCss() {
  if (document.getElementById("ws-css")) return;
  const s = document.createElement("style"); s.id = "ws-css"; s.textContent = CSS; document.head.append(s);
}

const head = (extra = "") => `<div class="ws-head">${icon("sparkles", 16)}<b>Fertige Fragen</b>${extra}</div>`;

function lockedHtml() {
  return `<div class="ws-card locked">${head(`<span class="badge neutral">${LOCK} Pro AI</span>`)}
    <p class="small" style="margin:.35rem 0">Mit StudiNow Pro AI bekommst du zu jeder Vorlesungswoche 2–3 fertige Sätze mit je 15 Fragen, dazu Themen, Hinweise und Lösungen mit Erklärung.</p>
    <a class="btn sm" href="#/abo">${LOCK} Tarife ansehen</a></div>`;
}

function readyHtml(d) {
  const sets = d.sets.map(s => `<div class="ws-set"><span><b>${esc(s.title)}</b>${s.focus ? ` <span class="muted small">· ${esc(s.focus)}</span>` : ""}</span><button class="btn sm primary" data-start="${s.nr}">${icon("play", 13)} Test starten</button></div>`).join("");
  const topics = d.topics.length ? `<details><summary>Themen der Woche (${d.topics.length})</summary><ul>${d.topics.map(t => `<li><b>${esc(t.title)}</b>${t.summary ? ` – ${esc(t.summary)}` : ""}</li>`).join("")}</ul></details>` : "";
  const hints = d.hints.length ? `<details><summary>Hinweise (${d.hints.length})</summary><ul>${d.hints.map(h => `<li>${esc(h)}</li>`).join("")}</ul></details>` : "";
  const sols = d.solutions.length ? `<details><summary>Lösungen zu den Übungsaufgaben (${d.solutions.length})</summary>${d.solutions.map(s => `<details class="ws-sol"><summary>${esc(s.label)}${s.official ? ` <span class="badge ok">mit Musterlösung</span>` : ""}</summary>
      <p><b>Ergebnis:</b> ${esc(s.answer)}</p>${s.steps?.length ? `<ol>${s.steps.map(x => `<li>${esc(x)}</li>`).join("")}</ol>` : ""}${s.explanation ? `<p class="muted small"><b>Warum:</b> ${esc(s.explanation)}</p>` : ""}</details>`).join("")}</details>` : "";
  return `<div class="ws-card">${head(`<span class="badge ok">${esc(setsLabel(d.sets))}</span>`)}
    <p class="muted small" style="margin:.3rem 0 0">Von der StudiNow-KI vorbereitet und automatisch geprüft. Zählt nicht auf deine neuen KI-Tests.</p>
    <div class="ws-sets">${sets}</div>${topics}${hints}${sols}</div>`;
}

const noteHtml = (text, button = "") => `<div class="ws-card">${head()}<p class="small" style="margin:.35rem 0">${esc(text)}</p>${button}</div>`;
const loadingHtml = text => `<div class="ws-card">${head()}<p class="small muted" style="margin:.35rem 0"><span class="uf-shimmer">${esc(text)}</span></p></div>`;

/** Eine Woche: Karte nach Status zeichnen; `current` = aktuelle Lehrwoche (bereitet von selbst vor). */
async function mountWeek(host, moduleId, week, status, current) {
  const base = `/library/week-sets/${moduleId}/${week}`;
  let tries = 0;
  const draw = async d => {
    if (!host.isConnected) return;
    const mode = cardMode({ hosted: true, allowed: true, status: d.status, current });
    if (mode === "hidden") { host.innerHTML = ""; return; }
    if (mode === "show") {
      host.innerHTML = readyHtml(d);
      $$("[data-start]", host).forEach(b => b.onclick = async () => {
        b.disabled = true;
        try { const r = await api(`${base}/sets/${b.dataset.start}/start`, { method: "POST", body: { request_id: crypto.randomUUID?.() } }); location.hash = `#/exams/${r.test_id}`; }
        catch (e) { b.disabled = false; e.code === "plan_required" ? (host.innerHTML = lockedHtml()) : showError(e); }
      });
      return;
    }
    if (mode === "poll") {
      host.innerHTML = loadingHtml(statusText("preparing"));
      if (keepPolling(d.status, tries++)) setTimeout(() => host.isConnected && api(base).then(draw).catch(fail), POLL_MS);
      else host.innerHTML = noteHtml("Das dauert länger als gedacht. Schau später noch einmal vorbei.");
      return;
    }
    if (mode === "auto_prepare") return prepare(true);
    const btn = mode === "offer_prepare" ? `<button class="btn sm" data-prep>${icon("sparkles", 13)} Fragen vorbereiten lassen</button>`
      : mode === "retry" ? `<button class="btn sm" data-prep>${icon("refresh", 13)} Erneut versuchen</button>` : "";
    host.innerHTML = noteHtml(statusText(d.status, d.error_code) || "", btn);
    $("[data-prep]", host)?.addEventListener("click", () => prepare(false));
  };
  // quiet: von selbst angestossen (aktuelle Woche) -> kein Fenster, nur der Hinweis in der Karte
  const fail = (e, quiet = false) => {
    if (!host.isConnected) return;
    if (e.code === "plan_required") { host.innerHTML = lockedHtml(); return; }
    if (e.action && !quiet) showError(e);
    host.innerHTML = noteHtml(statusText(null, e.code) || e.message, `<button class="btn sm" data-prep>${icon("refresh", 13)} Erneut versuchen</button>`);
    $("[data-prep]", host)?.addEventListener("click", () => prepare(false));
  };
  async function prepare(quiet) {
    host.innerHTML = loadingHtml(statusText("preparing"));
    try { await draw(await api(`${base}/prepare`, { method: "POST", body: {} })); } catch (e) { fail(e, quiet); }
  }
  if (status === "ready" || status === "preparing" || current) {
    host.innerHTML = loadingHtml("Lade fertige Fragen…");
    try { await draw(await api(base)); } catch (e) { fail(e); }
  } else {
    await draw({ status });
  }
}

/** Alle Wochen eines Moduls: `hosts` = Elemente mit data-w (Lehrwoche), `currentWeek` = aktuelle Lehrwoche */
export async function mountWeekSets(hosts, moduleId, currentWeek) {
  if (!hosts.length) return;
  ensureCss();
  if (!state.hosted) {
    // Einzelplatz: die Bibliothek gibt es nur im Dienst; ein Hinweis in der aktuellen Woche genuegt
    hosts.forEach(h => { if (cardMode({ hosted: false, current: +h.dataset.w === currentWeek }) === "service_only") h.innerHTML = noteHtml("Fertige Fragen je Vorlesungswoche gibt es im StudiNow-Dienst mit Pro AI. Am eigenen PC erstellt deine KI die Wochentests."); });
    return;
  }
  if (!can(RIGHT)) { hosts.forEach(h => h.innerHTML = lockedHtml()); return; }
  let ov;
  try { ov = await api(`/library/week-sets/${moduleId}`); }
  catch (e) { if (e.code === "plan_required") hosts.forEach(h => h.innerHTML = lockedHtml()); else toast(e.message, 4000); return; }
  const byWeek = new Map(ov.weeks.map(w => [w.week, w]));
  hosts.forEach(h => { const w = byWeek.get(+h.dataset.w); if (w) mountWeek(h, moduleId, w.week, w.status, w.week === currentWeek); });
}

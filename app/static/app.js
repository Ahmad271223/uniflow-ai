// UniFlow AI – Shell, Router, Dashboard
import { $, $$, api, esc, safeUrl, noteChips, chipRef, icon, toast, modal, debounce, fmtDate, fmtShort, fmtMin, parseISO, todayISO, statusPill, shortName, DAYS, TYPE_ICON, TYPE_TXT, state } from "./core.js?v=43";
import { viewDashboard as viewHome } from "./views-home.js?v=19";
import { viewDoc, toggleTimer, docTabs } from "./views-doc.js?v=63";
import { viewFiles } from "./views-lib.js?v=62";
import { viewPlan, openPackage, suggestFlow, generatePlan, bindCalendar, taskRow, bindTaskRows, dayTimeline, bindDayExtras, tasksListHtml } from "./views-plan.js?v=48";
import { viewTimetable, openEvent } from "./views-tt.js?v=46";
import { viewModules, viewExams, viewCards, viewCommunity, viewSettings, viewServices } from "./views-misc.js?v=81";
import { viewAbo, planChoicePrompt } from "./views-abo.js?v=46";
import { resendNote } from "./service-errors.js?v=1";
import { askOlderSemesters } from "./older-semesters-ui.js?v=4";
import { chipState } from "./sync-chip.js?v=1";
import { trialHintHtml } from "./trial-hint.js?v=1";
import { initPWA, keepCacheForAccount, clearWorkerCache } from "./pwa.js?v=15";
import { navHtml, accountHtml } from "./shell-nav.js?v=1";

// ---------------------------------------------------------------- Shell
// Seitenleiste in Gruppen wie auf dem iPad (shell-nav.js): STUDIUM / LERNEN / GEMEINSAM, unten Konto mit Tarif
function buildShell() {
  $("#brandLogo").innerHTML = icon("graduation", 18);
  $("#nav").innerHTML = navHtml(icon);
  $("#navSettings").innerHTML = `${icon("settings", 18)}<span>Einstellungen</span>`; $("#navSettings").dataset.route = "settings"; $("#navSettings").className = "";
  $("#collapseBtn").innerHTML = `${icon("panel-left", 18)}<span> Einklappen</span>`;
  $("#menuBtn").innerHTML = icon("menu", 20); $("#themeBtn").innerHTML = icon("sun", 18); $("#profileBtn").innerHTML = icon("clock", 18); $("#profileBtn").title = "Zeitmesser";
  $("#syncBtn").innerHTML = `${icon("sync", 15)} Sync`;
  $("#mobileNav").innerHTML = [["dashboard", "Start", "home"], ["plan", "Kalender", "calendar"], ["modules", "Module", "book"], ["files", "Dokumente", "folder"], ["settings", "Mehr", "settings"]].map(([r, t, i]) => `<a href="#/${r}" data-route="${r}">${icon(i, 20)}${t}</a>`).join("");
  $("#collapseBtn").onclick = () => { $("#shell").classList.toggle("collapsed"); try { localStorage.setItem("sidebar", $("#shell").classList.contains("collapsed") ? "min" : "full"); } catch {} };
  try { if (localStorage.getItem("sidebar") === "min") $("#shell").classList.add("collapsed"); } catch {}
  $("#menuBtn").onclick = () => { $("#sidebar").classList.toggle("open"); toggleBackdrop($("#sidebar").classList.contains("open")); };
  $("#themeBtn").onclick = () => { const cur = document.documentElement.dataset.theme || "auto"; const next = cur === "dark" ? "light" : cur === "light" ? "auto" : "dark"; setTheme(next); toast(`Design: ${{ dark: "Dunkel", light: "Hell", auto: "Automatisch" }[next]}`); };
  $("#profileBtn").onclick = () => toggleTimer();
  $("#syncBtn").onclick = async () => { try { await api("/sync", { method: "POST" }); toast("Synchronisierung gestartet"); pollBg(); } catch (e) { toast(e.message); } };
  $("#searchInput").oninput = debounce(globalSearch, 220);
  $("#searchInput").onkeydown = e => { if (e.key === "Escape") $("#searchPop").hidden = true; };
  document.addEventListener("click", e => { if (!e.target.closest("#globalSearch")) $("#searchPop").hidden = true; });
  document.addEventListener("keydown", e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") { e.preventDefault(); $("#searchInput").focus(); } });
}
function toggleBackdrop(on) { let b = $("#sideBd"); if (on && !b) { b = document.createElement("div"); b.className = "backdrop"; b.id = "sideBd"; b.onclick = () => { $("#sidebar").classList.remove("open"); b.remove(); }; document.body.append(b); } else if (!on) b?.remove(); }
function setTheme(t) { if (t === "auto") delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = t; try { localStorage.setItem("theme", t); } catch {} $("#themeBtn").innerHTML = icon(t === "dark" ? "moon" : "sun", 18); }
window.setTheme = setTheme;
async function globalSearch() {
  const q = $("#searchInput").value.trim(); const pop = $("#searchPop");
  if (q.length < 2) { pop.hidden = true; return; }
  const r = await api(`/search?q=${encodeURIComponent(q)}`);
  pop.innerHTML = (r.modules.map(m => `<a href="#/modules/${m.id}"><span class="dot" style="background:${m.color}"></span><b>${esc(m.name)}</b><span class="muted small">Modul</span></a>`).join("") +
    r.files.map(f => `<a href="#/doc/${f.id}">${icon(TYPE_ICON[f.doc_type] || "file", 16)}<span class="main"><span style="display:block">${esc(f.ai_title || f.name)}</span><span class="muted small">${esc(f.subject || "")} · ${esc(TYPE_TXT[f.doc_type] || f.name)}</span></span></a>`).join("") +
    (r.tasks || []).map(t => `<a href="#/plan?view=day&date=${t.date}">${icon(TYPE_ICON[t.type] || "check", 16)}<span class="main"><span style="display:block">${esc(t.title)}</span><span class="muted small">${esc(t.subject || "")} · Aufgabe · ${fmtShort(t.date)}</span></span></a>`).join("") +
    (r.pages || []).map(p => `<a href="#/doc/${p.file_id}?page=${p.page}">${icon("file-text", 16)}<span class="main"><span style="display:block">${esc(p.ai_title || p.name)} · Seite ${p.page}</span><span class="muted small">${esc(p.snippet)}</span></span></a>`).join("")) || `<div class="muted small" style="padding:.6rem">Keine Treffer</div>`;
  pop.hidden = false; $$("a", pop).forEach(a => a.onclick = () => { pop.hidden = true; $("#searchInput").value = ""; });
}
let bgTimer; async function pollBg() {
  try {
    const bg = await api("/bg"); const chip = $("#syncChip");
    if (bg.running) { chip.innerHTML = `${icon("refresh", 14)} ${esc(bg.message || `${bg.task} läuft…`)}`; $("#syncBtn").disabled = true; clearTimeout(bgTimer); bgTimer = setTimeout(pollBg, 3000); pollBg._was = true; }
    else { $("#syncBtn").disabled = false; if (pollBg._was) { pollBg._was = false; toast(bg.message || "Fertig"); route(); askOlderSemesters(); } updateSyncChip(); }
  } catch {}
}
window.pollBg = pollBg;
// Anzeige oben nur bei Neuem, Fehlern oder laufendem Abgleich (sync-chip.js); sonst bleibt der Knopf "Sync" allein
async function updateSyncChip() { try { const s = await api("/sync/status"); const l = s.log[0]; const c = chipState(l, l ? new Date(l.finished_at).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" }) : ""); $("#syncChip").innerHTML = c ? `${icon(c.icon, 14, c.tone)} ${esc(c.text)}` : ""; $("#syncChip").title = c ? c.title : ""; } catch {} }
// Fehler sichtbar machen (Diagnose unter Einstellungen → Diagnose)
state.errors = [];
function noteError(msg, src) { const m = String(msg || "Unbekannter Fehler"); if (/ResizeObserver loop/i.test(m)) return; /* harmlose Browsermeldung */ state.errors.push({ t: new Date().toISOString(), msg: m, src: src || "" }); if (state.errors.length > 30) state.errors.shift(); if (!noteError._shown) { noteError._shown = true; toast("Fehler: " + m.slice(0, 120), 5000); setTimeout(() => noteError._shown = false, 8000); } }
window.addEventListener("error", e => noteError(e.message, e.filename ? `${e.filename.split("/").pop()}:${e.lineno}` : ""));
window.addEventListener("unhandledrejection", e => noteError(e.reason?.message || e.reason, "promise"));
const UNI_NAMES = { luh: "Leibniz Universität Hannover", hildesheim: "Universität Hildesheim" };
// Glocke: ungelesene Mitteilungen der Community (Dienst oder Windows-App mit StudiNow-Konto), alle 2 Minuten
window.updateBell = n => { const b = $("#notifBtn"); if (!b) return; if (n == null) { b.hidden = true; return; }
  b.hidden = false; b.innerHTML = icon("bell", 18) + (n ? `<span class="notif-badge">${n > 99 ? "99+" : n}</span>` : ""); b.setAttribute("aria-label", n ? `${n} ungelesene Mitteilungen` : "Mitteilungen"); };
async function pollBell() { try { const { unreadCount } = await import("./views-qa.js?v=8"); window.updateBell(await unreadCount()); } catch {} }
setTimeout(askOlderSemesters, 6000);   // einmalige Frage "Auch frühere Semester laden?" (older-semesters-ui.js)
setTimeout(pollBell, 4000); setInterval(() => { if (!document.hidden) pollBell(); }, 120000);
document.addEventListener("click", e => { if (e.target.closest?.("#notifBtn")) location.hash = "#/community?tab=notify"; });
// Abzeichen mit der Zahl offener Korrekturhinweise am Menuepunkt "Community" (03.11.2026, wie auf dem iPad), sparsam geholt
import("./community-corrections-ui.js?v=5").then(m => m.startBadgePolling()).catch(() => {});

function accountMenu() {
  const a = state.account;
  const m = modal(`<div class="card-head"><h2>${icon("user", 18)} StudiNow-Konto</h2><button class="btn ghost icon" data-close>${icon("x", 16)}</button></div>
    <p style="margin:.2rem 0"><b>${esc(a.email)}</b></p><p class="muted small" style="margin:0 0 .9rem">${esc(UNI_NAMES[a.university] || a.university)} · Tarif ${esc(state.entitlements?.plan_name || "StudiNow Free")}${a.role === "admin" ? " · Moderation" : ""}</p>
    ${a.email_verified ? "" : `<div class="card flat" style="background:var(--warn-soft);border-color:transparent;margin:0 0 .8rem"><b class="small">E-Mail-Adresse noch nicht bestätigt</b><div class="small muted" style="margin:.2rem 0 .5rem">Bitte den Link in der Willkommensmail öffnen. Ohne Bestätigung gehen StudiNow-KI und Schreiben in der Community nicht.</div><button class="btn sm" id="accVerify">Bestätigungslink erneut senden</button></div>`}
    <div class="row wrap"><button class="btn primary" id="accLogout">${icon("log-out", 15)} Abmelden</button><button class="btn" id="accLogoutAll" title="Alle anderen Geräte abmelden, dieses bleibt angemeldet">Andere Geräte abmelden</button><a class="btn" href="#/settings?tab=account" data-close>Hochschul-Zugang</a><a class="btn" href="/api/account/export" download title="Alle Daten dieses Kontos als ZIP (Auskunft nach DSGVO)">${icon("download", 15)} Meine Daten exportieren</a></div>
    <details class="small" style="margin-top:.8rem" id="accDevs"><summary><b>Angemeldete Geräte</b></summary><div class="sl-devlist muted">Lade …</div></details>
    <p class="muted tiny" style="margin:.9rem 0 0"><a href="/datenschutz" target="_blank" rel="noopener">Datenschutz</a> · <a href="/nutzungsbedingungen" target="_blank" rel="noopener">Nutzungsbedingungen</a> · <a href="/impressum" target="_blank" rel="noopener">Impressum</a> · <a href="/konto-loeschen" target="_blank" rel="noopener">Konto löschen</a></p>`);
  const devs = $("#accDevs", m);
  devs.ontoggle = async () => { if (!devs.open) return; const { deviceList } = await import("./studora-link.js?v=7");
    try { const d = await api("/account/me"); deviceList($(".sl-devlist", devs), d.sessions || [], async (id, cur) => { await api(`/account/sessions/${id}`, { method: "DELETE" }); if (cur) location.replace("/login"); else devs.ontoggle(); }); }
    catch (e) { $(".sl-devlist", devs).textContent = e.message; } };
  $("#accLogout", m).onclick = async () => { try { await api("/account/logout", { method: "POST" }); } catch {} clearWorkerCache(); location.replace("/login"); };
  $("#accVerify", m)?.addEventListener("click", async e => { e.target.disabled = true; try { const r = await api("/account/verify-email/resend", { method: "POST" }); toast(resendNote(r), 4000); } catch (x) { toast(x.message, 5000); e.target.disabled = false; } });
  $("#accLogoutAll", m).onclick = async () => { try { const r = await api("/account/logout-all", { method: "POST" }); toast(r.revoked ? `${r.revoked} andere Sitzung(en) beendet` : "Keine anderen Geräte angemeldet"); } catch (e) { toast(e.message); } };
}

// Kontoblock unten in der Seitenleiste: Initialen, Name, Tarif (Probe mit Resttagen) und "Plus holen →" zur Tarifseite.
// Klick auf den Namen: im Dienst das Kontomenue, am eigenen PC die Einstellungen
function renderAccount() {
  const box = $("#sideAcct"); if (!box) return;
  box.innerHTML = accountHtml({ name: state.userName, email: state.account?.email, ent: state.entitlements, hosted: state.hosted, arrow: icon("arrow-right", 15), person: icon("user", 16) });
  $("#sideAcctBtn", box).onclick = () => { if (state.hosted && state.account) accountMenu(); else location.hash = "#/settings"; };
}
window.renderAccount = renderAccount;

// ---------------------------------------------------------------- Router
const routes = { dashboard: viewDashboard, plan: viewPlan, timetable: viewTimetable, modules: viewModules, files: viewFiles, exams: viewExams, cards: viewCards, community: viewCommunity, settings: viewSettings, abo: viewAbo, doc: viewDoc, services: viewServices, tasks: (p, q, v) => viewPlan(p, { ...q, view: "list" }, v) };
async function route() {
  const hash = location.hash.replace(/^#\/?/, "") || "dashboard";
  const [path, qs] = hash.split("?"); const parts = path.split("/"); const name = parts[0]; const params = Object.fromEntries(new URLSearchParams(qs || ""));
  $$("[data-route]").forEach(a => a.classList.toggle("active", a.dataset.route === name || (name === "doc" && a.dataset.route === "files")));
  $("#sidebar").classList.remove("open"); toggleBackdrop(false); $("#drawerEl")?.remove(); $("#drawerBd")?.remove(); $$("#overlay .modal").forEach(m => m.remove());
  document.body.classList.remove("exam-focus", "fullscreen-doc", "doc-open");
  for (const ed of state.editors) { try { if (ed.tabId) docTabs.state[ed.tabId] = ed.getState(); await ed.destroy(); } catch {} } state.editors = [];
  const view = $("#view"); view.className = ""; view.innerHTML = `<div class="content"><div class="skeleton" style="height:28px;width:40%;margin-bottom:1rem"></div><div class="grid cols-3"><div class="skeleton" style="height:120px"></div><div class="skeleton" style="height:120px"></div><div class="skeleton" style="height:120px"></div></div></div>`;
  try { await (routes[name] || viewDashboard)(parts.slice(1), params, view); } catch (e) {
    console.error(e); const offline = /Failed to fetch|NetworkError|Load failed|fetch/i.test(e.message || "");
    if (offline && !navigator.onLine) { view.innerHTML = `<div class="content"><div class="card" style="max-width:600px"><h2>${icon("alert", 18)} Offline</h2><p class="muted">Diese Seite wurde auf diesem Gerät noch nicht geladen. Zuletzt geöffnete Unterlagen und Listen sind ohne Netz da; alles andere, sobald wieder Netz ist.</p><div class="row"><a class="btn" href="#/dashboard">${icon("home", 15)} Zur Übersicht</a><button class="btn primary" onclick="location.reload()">${icon("refresh", 15)} Neu laden</button></div></div></div>`; return; }
    view.innerHTML = offline ? `<div class="content"><div class="card" style="max-width:600px"><h2>${icon("alert", 18)} Server nicht erreichbar</h2><p class="muted">Die App läuft auf deinem PC (serve.py). Der Server startet gerade neu oder wurde beendet. Es wird automatisch weiter versucht…</p><div class="row"><button class="btn primary" onclick="location.reload()">${icon("refresh", 15)} Jetzt neu laden</button><a class="btn" href="#/settings?tab=diag">Diagnose</a></div></div></div>`
      : `<div class="content"><div class="card"><h2>Fehler</h2><p class="muted">${esc(e.message)}</p></div></div>`;
    if (offline) setTimeout(() => api("/bg").then(() => route()).catch(() => {}), 3000);
  }
  if (name !== "doc") window.scrollTo(0, 0);
}
state.route = route; window.addEventListener("hashchange", route);

// Probe auf der Uebersicht (Dienst): "noch N Tage alles frei", danach einmal die Aufforderung (planChoicePrompt)
function trialHint() { return trialHintHtml(state.entitlements, state.hosted, icon, esc); }
// "Bei Free bleiben" auf der Hinweiskarte (trial-hint.js); die Uebersicht zeichnet danach neu
document.addEventListener("click", async e => {
  if (!e.target.closest?.("#trialFree")) return;
  try { await api("/billing/plan-choice", { method: "POST", body: { plan: "free" } }); toast("Du bleibst bei Free – deine Notizen bleiben"); if (state.entitlements) state.entitlements.needs_plan_choice = false; route(); }
  catch (x) { toast(x.message, 5000); }
});

// Übersicht (Startseite): views-home.js; die Hinweiskarte der Probe (Dienst) kommt von hier
async function viewDashboard(p, q, v) {
  await viewHome(p, q, v, trialHint);
  // Korrekturhinweise zu eigenen geteilten Loesungen (Oeffnen / Ignorieren) oben auf der Uebersicht, nur wenn welche offen sind
  try {
    const U = await import("./community-corrections-ui.js?v=5"); const n = await U.inboxCount(); if (!n || !v.isConnected) return;
    (await import("./community-logic.js?v=2")).ensureCss();
    const box = document.createElement("div"); box.className = "card"; v.querySelector(".content")?.prepend(box);
    await U.renderInbox(box, { toast, onChange: () => route() });
    if (!box.innerHTML) box.remove();
  } catch { /* Community nicht verfuegbar */ }
}

// ---------------------------------------------------------------- Start
async function start() {
  // Gehosteter Dienst: ohne gueltige Sitzung zur Anmeldeseite, sonst Konto hinter dem Avatar (Abmelden)
  try { state.hosted = !!(await fetch("/api/account/info").then(r => r.json())).hosted; } catch {}
  if (state.hosted) {
    const r = await fetch("/api/account/me");
    if (r.status === 401) { location.replace("/login"); return; }
    try { state.entitlements = await fetch("/api/entitlements").then(x => x.ok ? x.json() : null); } catch {}
    if (r.ok) { state.account = (await r.json()).user; const av = $("#avatar"); av.textContent = state.account.email.slice(0, 2).toUpperCase(); av.title = `${state.account.email} – Konto und Abmelden`; av.style.cursor = "pointer"; av.onclick = accountMenu; }
  }
  keepCacheForAccount(state.hosted ? state.account?.id ?? state.account?.email : "local");
  buildShell(); setTheme((() => { try { return localStorage.getItem("theme") || "light"; } catch { return "light"; } })());
  initPWA();
  window.__app = { route, api, state };
  renderAccount();
  api("/settings").then(s => { const n = (s.user_name || "").trim(); if (n) $("#avatar").textContent = n.split(/\s+/).map(x => x[0]).join("").slice(0, 2).toUpperCase(); state.userName = n; renderAccount(); }).catch(() => {});
  route(); pollBg(); updateSyncChip();
  if (state.hosted && state.entitlements?.needs_plan_choice && !location.hash.startsWith("#/abo")) planChoicePrompt(state.entitlements);
  // Windows-App: das Fenster blockiert Links in ein neues Fenster (target="_blank", window.open) still. Dort oeffnet sie
  // der lokale Dienst im Standardbrowser (/api/desktop/open, nur http/https)
  api("/desktop").then(d => {
    if (!d.desktop) return;
    state.desktop = true;
    const openExternal = url => api("/desktop/open", { method: "POST", body: { url } }).then(() => toast("Im Browser geöffnet")).catch(e => toast(`Link nicht geöffnet: ${e.message}`));
    document.addEventListener("click", e => {
      const a = e.target.closest && e.target.closest('a[target="_blank"]');
      if (!a || (a.getAttribute("href") || "#").startsWith("#") || !/^https?:/i.test(a.href)) return;
      e.preventDefault(); openExternal(a.href);
    }, true);
    window.open = url => { const abs = url ? new URL(url, location.href).href : ""; if (/^https?:/i.test(abs)) openExternal(abs); return null; };
  }).catch(() => {});
}
start();

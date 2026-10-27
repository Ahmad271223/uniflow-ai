// UniFlow AI – Shell, Router, Dashboard
import { $, $$, api, esc, safeUrl, noteChips, chipRef, icon, toast, modal, debounce, fmtDate, fmtShort, fmtMin, parseISO, todayISO, statusPill, shortName, DAYS, TYPE_ICON, TYPE_TXT, state } from "./core.js?v=30";
import { viewDoc, toggleTimer, docTabs } from "./views-doc.js?v=30";
import { viewFiles } from "./views-lib.js?v=30";
import { viewPlan, openPackage, suggestFlow, generatePlan, bindCalendar, taskRow, bindTaskRows, dayTimeline, bindDayExtras, tasksListHtml } from "./views-plan.js?v=31";
import { viewTimetable, openEvent } from "./views-tt.js?v=30";
import { viewModules, viewExams, viewCards, viewCommunity, viewSettings, viewServices } from "./views-misc.js?v=32";
import { viewAbo } from "./views-abo.js?v=31";

// ---------------------------------------------------------------- Shell
const NAV = [["dashboard", "Übersicht", "home"], ["plan", "Lernkalender", "calendar"], ["timetable", "Stundenplan", "clock"], ["modules", "Meine Module", "book"], ["files", "Dokumente & Notizen", "folder"], ["exams", "Tests & Wiederholung", "exam"], ["services", "Uni & Noten", "graduation"], ["community", "Community", "users"]];
function buildShell() {
  $("#brandLogo").innerHTML = icon("graduation", 18);
  $("#nav").innerHTML = NAV.map(([r, t, i]) => `<a href="#/${r}" data-route="${r}">${icon(i, 18)}<span>${t}</span></a>`).join("");
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
    else { $("#syncBtn").disabled = false; if (pollBg._was) { pollBg._was = false; toast(bg.message || "Fertig"); route(); } updateSyncChip(); }
  } catch {}
}
window.pollBg = pollBg;
async function updateSyncChip() { try { const s = await api("/sync/status"); const l = s.log[0]; $("#syncChip").innerHTML = l ? `${icon(l.ok ? "check" : "alert", 14, l.ok ? "ok" : "")} Zuletzt synchronisiert: ${new Date(l.finished_at).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" })}` : `${icon("info", 14)} Noch kein Sync`; $("#syncChip").title = l ? l.message : ""; } catch {} }
// Fehler sichtbar machen (Diagnose unter Einstellungen → Diagnose)
state.errors = [];
function noteError(msg, src) { const m = String(msg || "Unbekannter Fehler"); if (/ResizeObserver loop/i.test(m)) return; /* harmlose Browsermeldung */ state.errors.push({ t: new Date().toISOString(), msg: m, src: src || "" }); if (state.errors.length > 30) state.errors.shift(); if (!noteError._shown) { noteError._shown = true; toast("Fehler: " + m.slice(0, 120), 5000); setTimeout(() => noteError._shown = false, 8000); } }
window.addEventListener("error", e => noteError(e.message, e.filename ? `${e.filename.split("/").pop()}:${e.lineno}` : ""));
window.addEventListener("unhandledrejection", e => noteError(e.reason?.message || e.reason, "promise"));
const UNI_NAMES = { luh: "Leibniz Universität Hannover", hildesheim: "Universität Hildesheim" };
function accountMenu() {
  const a = state.account;
  const m = modal(`<div class="card-head"><h2>${icon("user", 18)} UniFlow-Konto</h2><button class="btn ghost icon" data-close>${icon("x", 16)}</button></div>
    <p style="margin:.2rem 0"><b>${esc(a.email)}</b></p><p class="muted small" style="margin:0 0 .9rem">${esc(UNI_NAMES[a.university] || a.university)} · Tarif ${esc(state.entitlements?.plan_name || "Studora Free")}${a.role === "admin" ? " · Moderation" : ""}</p>
    <div class="row wrap"><button class="btn primary" id="accLogout">${icon("log-out", 15)} Abmelden</button><button class="btn" id="accLogoutAll" title="Alle anderen Geräte abmelden, dieses bleibt angemeldet">Andere Geräte abmelden</button><a class="btn" href="#/settings?tab=account" data-close>Hochschul-Zugang</a></div>
    <p class="muted tiny" style="margin:.9rem 0 0"><a href="/datenschutz" target="_blank" rel="noopener">Datenschutz</a> · <a href="/nutzungsbedingungen" target="_blank" rel="noopener">Nutzungsbedingungen</a> · <a href="/impressum" target="_blank" rel="noopener">Impressum</a> · <a href="/konto-loeschen" target="_blank" rel="noopener">Konto löschen</a></p>`);
  $("#accLogout", m).onclick = async () => { try { await api("/account/logout", { method: "POST" }); } catch {} location.replace("/login"); };
  $("#accLogoutAll", m).onclick = async () => { try { const r = await api("/account/logout-all", { method: "POST" }); toast(r.revoked ? `${r.revoked} andere Sitzung(en) beendet` : "Keine anderen Geräte angemeldet"); } catch (e) { toast(e.message); } };
}

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
    view.innerHTML = offline ? `<div class="content"><div class="card" style="max-width:600px"><h2>${icon("alert", 18)} Server nicht erreichbar</h2><p class="muted">Die App läuft auf deinem PC (serve.py). Der Server startet gerade neu oder wurde beendet. Es wird automatisch weiter versucht…</p><div class="row"><button class="btn primary" onclick="location.reload()">${icon("refresh", 15)} Jetzt neu laden</button><a class="btn" href="#/settings?tab=diag">Diagnose</a></div></div></div>`
      : `<div class="content"><div class="card"><h2>Fehler</h2><p class="muted">${esc(e.message)}</p></div></div>`;
    if (offline) setTimeout(() => api("/bg").then(() => route()).catch(() => {}), 3000);
  }
  if (name !== "doc") window.scrollTo(0, 0);
}
state.route = route; window.addEventListener("hashchange", route);

// ================================================================ ÜBERSICHT (Dashboard)
async function viewDashboard(_, __, view) {
  const d = await api("/dashboard");
  const h = new Date().getHours(); const greet = h < 11 ? "Guten Morgen" : h < 18 ? "Guten Tag" : "Guten Abend";
  const today = d.today; const pk = today.packages; const evs = (today.events || []).filter(e => e.status !== "verschoben");
  const openToday = pk.reduce((n, p) => n + p.tasks.filter(t => !["erledigt", "uebersprungen"].includes(t.status)).length, 0);
  const doneToday = pk.reduce((n, p) => n + p.tasks.filter(t => t.status === "erledigt").length, 0); const totalToday = pk.reduce((n, p) => n + p.tasks.length, 0);
  const newByMod = {}; d.new_files.forEach(f => (newByMod[f.subject || "Sonstiges"] ||= []).push(f));
  const nextOpen = pk.flatMap(p => p.tasks.filter(t => !["erledigt", "uebersprungen"].includes(t.status)).map(t => ({ ...t, p })))[0];
  view.innerHTML = `<div class="content" style="max-width:1120px">
    <div class="page-head greet"><div><h1>${greet}!</h1><div class="date">${new Date().toLocaleDateString("de-DE", { weekday: "long", day: "numeric", month: "long" })} · ${pk.length ? `heute ${pk.length} Lernpaket${pk.length > 1 ? "e" : ""}` : "heute ist nichts geplant"}${evs.length ? ` · ${evs.filter(e => e.status === "teilnahme").length} Uni-Termine` : ""}</div></div>
      <div class="actions"><a class="btn" href="#/plan?view=day&date=${today.date}">${icon("calendar", 16)} Tagesansicht</a>${nextOpen ? `<a class="btn primary" href="${nextOpen.file_id ? `#/doc/${nextOpen.file_id}?task=${nextOpen.id}` : `#/plan?view=day&date=${today.date}`}">${icon("play", 16)} Weiterlernen</a>` : ""}</div></div>
    <div class="grid cols-3" style="margin-bottom:1.2rem"><div class="card kpi"><b>${fmtMin(today.minutes || 0)}</b><span>heute geplant${today.free?.length ? ` · ${fmtMin(today.free.reduce((a, w) => a + w.minutes, 0))} frei` : ""}</span></div><div class="card kpi"><b>${doneToday} / ${totalToday}</b><span>Aufgaben erledigt</span><div class="progress ok" style="margin-top:.4rem"><i style="width:${totalToday ? Math.round(100 * doneToday / totalToday) : 0}%"></i></div></div><div class="card kpi" style="${d.backlog ? "border-color:var(--bad)" : ""}"><b style="${d.backlog ? "color:var(--bad)" : ""}">${d.backlog}</b><span>nachzuholen${d.backlog ? ` · <a href="#" id="rescueBtn">neu planen</a>` : ""}</span></div></div>
    <div class="grid cols-3">
      <div class="span-2 stack">
        <div class="card"><div class="card-head"><h2>${icon("play", 18)} Heute für dich geplant</h2></div>
          ${pk.length ? pk.map(p => { const done = p.tasks.filter(t => t.status === "erledigt").length; return `<div class="pkg-card" style="--pc:${p.color || "var(--accent)"}"><div class="row between wrap"><div><div class="row"><span class="dot" style="background:${p.color || "var(--accent)"}"></span><b>${esc(shortName(p.subject))}</b><span class="muted small">${p.start_time ? `${p.start_time}–${p.end_time} · ` : ""}${fmtMin(p.planned_minutes || 0)}</span></div><div class="small" style="margin:.2rem 0 0 1.1rem">${esc(p.title)}</div></div>${statusPill(p.status)}</div>
            <div class="stack" style="margin:.5rem 0 .4rem 1.1rem;gap:.25rem">${p.tasks.map(t => `<div class="row small ${t.status === "erledigt" ? "muted" : ""}" style="gap:.4rem">${icon(t.status === "erledigt" ? "check" : TYPE_ICON[t.type], 14)}<span style="${t.status === "erledigt" ? "text-decoration:line-through" : ""}">${esc(t.title)}</span><span class="muted">${t.est_minutes} min</span>${t.file_id && t.status !== "erledigt" ? `<a class="small" href="#/doc/${t.file_id}?task=${t.id}">öffnen</a>` : ""}</div>`).join("")}</div>
            <div class="row" style="margin-left:1.1rem"><div class="progress ok" style="flex:1"><i style="width:${p.tasks.length ? Math.round(100 * done / p.tasks.length) : 0}%"></i></div><button class="btn sm" data-pkg="${p.id}">Lernpaket öffnen</button></div></div>`; }).join("")
            : `<div class="empty">${icon("calendar", 36)}<div>Für heute ist nichts geplant.</div><button class="btn sm primary" id="genTodayBtn" style="margin-top:.6rem">${icon("sparkles", 14)} Lernplan erstellen</button></div>`}</div>
        ${evs.length ? `<div class="card"><div class="card-head"><h2>${icon("clock", 18)} Heute an der Uni</h2><a class="small" href="#/timetable">Stundenplan</a></div>${evs.map(e => `<div class="row small" style="padding:.3rem 0;border-bottom:1px solid var(--line);cursor:pointer" data-ev="${e.event_id}"><span class="dot" style="background:${e.color}"></span><b style="min-width:92px;flex-shrink:0">${e.start}–${e.end}</b><span style="flex:1;min-width:0;${e.status !== "teilnahme" ? "text-decoration:line-through;color:var(--muted)" : ""}">${esc(e.title)}</span><span class="muted" style="max-width:35%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(e.room || "")}">${e.room ? esc(e.room) : ""}</span></div>`).join("")}</div>` : ""}
      </div>
      <div class="stack">
        <div class="card"><div class="card-head"><h2>${icon("flag", 18)} Nächste Termine</h2></div>${d.upcoming.length ? `<div class="list">${d.upcoming.slice(0, 6).map(u => u.deadline_id
          ? `<a class="item" href="${esc(safeUrl(u.url))}" data-chip="${chipRef({ ...u, id: u.deadline_id, kind_label: u.kind_label || "Frist" }, "deadline", u.date)}" title="${esc(u.full_title || u.title)}"><span class="dot" style="background:${u.color || "var(--accent)"}"></span><div class="main"><div class="title">${esc(shortName(u.title))}</div><div class="sub"${u.overdue ? ' style="color:var(--bad)"' : ""}>${fmtShort(u.date)}${u.time ? ` ${esc(u.time)}` : ""} · ${esc(u.kind_label || "Frist")}${u.course_title ? ` · ${esc(shortName(u.course_title))}` : ""}</div></div></a>`
          : `<a class="item" href="${u.package_id ? `#/plan?view=day&date=${u.date}` : u.module_id ? `#/modules/${u.module_id}` : "#/plan"}"><span class="dot" style="background:${u.color || "var(--accent)"}"></span><div class="main"><div class="title">${esc(shortName(u.title))}</div><div class="sub">${fmtShort(u.date)} · ${u.kind === "klausur" ? "Klausur" : u.kind === "test" ? "Wochentest" : "Lernpaket"}</div></div></a>`).join("")}</div>` : `<div class="empty small">Keine Termine.</div>`}</div>
        ${d.announcements?.length ? `<div class="card"><div class="card-head"><h2>${icon("info", 18)} Ankündigungen</h2><span class="muted small">${d.announcements.length}</span></div>${d.announcements.slice(0, 5).map(a => `<details class="ann-item"><summary><div class="t" title="${esc(a.title)}">${esc(a.title)}</div><div class="s">${fmtShort(a.posted_at.slice(0, 10))}${a.course_title ? ` · ${esc(shortName(a.course_title))}` : ""} · ${a.source === "studip" ? "Stud.IP" : a.source === "demo" ? "Demo" : "Learnweb"}</div>${a.upcoming?.length ? `<div class="ann-dates">${noteChips({ notices: a.upcoming.slice(0, 3).map(x => ({ ...x, kind_label: `${fmtShort(x.date)} ${{ ausfall: "Ausfall?", verlegt: "Verlegung?", raum: "Raum", pruefung: "Prüfung", frist: "Frist", online: "Online" }[x.kind] || "Termin"}`, title: a.title, url: a.url, course_title: a.course_title })) }, true)}</div>` : ""}</summary><div class="body">${esc(a.text)}</div>${a.url ? `<a class="small" href="${esc(safeUrl(a.url))}" target="_blank" rel="noopener">Im ${a.source === "studip" ? "Stud.IP" : a.source === "demo" ? "Demo" : "Learnweb"} öffnen</a>` : ""}</details>`).join("")}</div>` : ""}
        <div class="card"><div class="card-head"><h2>${icon("clock", 18)} Diese Woche</h2><span class="muted small">${d.week.done}/${d.week.total}</span></div><div class="progress ok" style="margin-bottom:.7rem"><i style="width:${d.week.total ? Math.round(100 * d.week.done / d.week.total) : 0}%"></i></div><div class="week-strip">${d.week.days.map(w => `<a class="d ${w.date === today.date ? "today" : ""}" href="#/plan?view=day&date=${w.date}"><b>${DAYS[(parseISO(w.date).getDay() + 6) % 7]}</b><span class="sd ${w.status}" style="margin:0 auto"></span><span class="m">${w.minutes ? fmtMin(w.minutes) : "–"}</span></a>`).join("")}</div></div>
        <div class="card"><div class="card-head"><h2>${icon("sparkles", 18)} Neu aus ${esc(d.settings?.files_source || "Stud.IP")}</h2><span class="muted small">${d.new_total}</span></div>${d.new_total ? Object.entries(newByMod).slice(0, 4).map(([s, fs]) => `<a class="item" href="#/files?section=new"><div class="main"><div class="title">${esc(shortName(s))}</div><div class="sub">${fs.length} neue ${fs.length === 1 ? "Datei" : "Dateien"} · ${esc(fs[0].ai_title || fs[0].name)}${fs.length > 1 ? " …" : ""}</div></div><span class="badge">${fs.length}</span></a>`).join("") + `<div class="row between" style="margin-top:.4rem"><a class="small" href="#/files?section=new">Alle anzeigen</a><button class="btn ghost sm" id="markSeenBtn">Gesehen</button></div>` : `<div class="empty small">Nichts Neues.</div>`}</div>
      </div></div></div>`;
  $$("[data-pkg]", view).forEach(el => el.onclick = () => openPackage(+el.dataset.pkg));
  $$("[data-ev]", view).forEach(el => el.onclick = () => openEvent(+el.dataset.ev, today.date));
  $("#rescueBtn")?.addEventListener("click", e => { e.preventDefault(); suggestFlow({ rescue: true }); });
  $("#genTodayBtn")?.addEventListener("click", () => generatePlan(todayISO()));
  $("#markSeenBtn")?.addEventListener("click", async () => { await api("/files/mark-seen", { method: "POST" }); route(); });
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
  buildShell(); setTheme((() => { try { return localStorage.getItem("theme") || "light"; } catch { return "light"; } })());
  window.__app = { route, api, state };
  api("/settings").then(s => { const n = (s.user_name || "").trim(); if (n) $("#avatar").textContent = n.split(/\s+/).map(x => x[0]).join("").slice(0, 2).toUpperCase(); }).catch(() => {});
  route(); pollBg(); updateSyncChip();
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

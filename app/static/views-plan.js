// Lernkalender: Woche (Zeitraster), Tag (Zeitleiste), Monat, Aufgabenliste; Lernpakete, Nachholen, Neuplanung, Lernkombination
import { holClass, holChips, dlChips, noteChips, $, $$, api, esc, icon, toast, modal, drawer, iso, parseISO, todayISO, fmtDate, fmtShort, fmtMin, addDays, mondayOf, hm, mh, statusPill, DAYS, DAYS_LONG, MONTHS, STATUS_TXT, TYPE_TXT, TYPE_ICON, shortName, state } from "./core.js?v=30";
import { tinyNames } from "./plan-names.js?v=30";

export const planState = { view: "week", date: todayISO(), module: "" };
const KIND_ICON = { vorlesung: "book", uebung: "pencil", gruppenuebung: "users", hoersaaluebung: "pencil", tutorium: "users", persoenlich: "user", sonstiges: "calendar" };
const KIND_LABEL = { vorlesung: "Vorlesung", uebung: "Übung", gruppenuebung: "Übung", hoersaaluebung: "Übung", tutorium: "Tutorium", persoenlich: "Persönlich", sonstiges: "Termin" };

export async function viewPlan(_, params, view) {
  if (params.view) planState.view = params.view; if (params.date) planState.date = params.date; if (params.module !== undefined) planState.module = params.module;
  const d = parseISO(planState.date); const t = todayISO();
  let start, end;
  if (planState.view === "week") { start = mondayOf(d); end = addDays(start, 6); }
  else if (planState.view === "3days") { start = d; end = addDays(d, 2); }
  else if (planState.view === "month") { const f = new Date(d.getFullYear(), d.getMonth(), 1); start = mondayOf(f); end = addDays(mondayOf(new Date(d.getFullYear(), d.getMonth() + 1, 0)), 6); }
  else { start = d; end = d; }
  const mStart = mondayOf(new Date(d.getFullYear(), d.getMonth(), 1)), mEnd = addDays(mondayOf(new Date(d.getFullYear(), d.getMonth() + 1, 0)), 6);
  const [cal, open, mods, month] = await Promise.all([api(`/calendar?start=${iso(start)}&end=${iso(end)}`), api("/tasks/open"), api("/modules"), planState.view === "month" ? null : api(`/calendar?start=${iso(mStart)}&end=${iso(mEnd)}`)]);
  const backlog = open.filter(x => x.status === "nachholen");
  const label = (planState.view === "week" || planState.view === "3days") ? `${fmtDate(start, { day: "numeric", month: "long" })} – ${fmtDate(end, { day: "numeric", month: "long", year: "numeric" })}` : planState.view === "month" ? `${MONTHS[d.getMonth()]} ${d.getFullYear()}` : d.toLocaleDateString("de-DE", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const modFilter = planState.module ? +planState.module : null;
  const filt = dd => ({ ...dd, events: (dd.events || []).filter(e => !modFilter || e.module_id === modFilter), packages: dd.packages.filter(p => !modFilter || p.module_id === modFilter) });
  const days = cal.days.map(filt);
  view.innerHTML = `<div class="content wide" style="max-width:1600px;padding:1.3rem 1.5rem 3rem">
    <div class="page-head"><div><h1>Lernkalender</h1><div class="sub">Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt.</div></div>
      <div class="actions"><button class="btn" id="addPkgBtn">${icon("plus", 15)} Lernpaket</button><button class="btn" id="cfgBtn">${icon("settings", 15)} Lernkombination</button><button class="btn" id="rescueBtn" ${backlog.length ? "" : "disabled"} title="${backlog.length ? "" : "Nichts nachzuholen"}">${icon("life-buoy", 15)} Woche retten</button><button class="btn primary" id="genBtn">${icon("sparkles", 15)} Plan erstellen</button></div></div>
    ${backlog.length ? `<div class="card" style="border-color:transparent;background:var(--bad-soft);margin-bottom:1rem"><div class="row wrap"><b style="color:var(--bad)">${icon("alert", 16)} ${backlog.length} Aufgabe${backlog.length > 1 ? "n müssen" : " muss"} nachgeholt werden</b><span class="spacer"></span><button class="btn sm" id="catchNow">Jetzt nachholen</button><button class="btn sm primary" id="catchPlan">Neu einplanen</button><button class="btn sm ghost" id="catchSkip">Bewusst überspringen</button></div></div>` : ""}
    <div class="cal2 ${["week", "3days"].includes(planState.view) ? "wk" : ""} ${sideOff() ? "side-off" : ""}" id="cal2"><div class="cal2-main">
      <div class="cal2-bar"><div class="seg pill">${[["day", "Tag"], ["3days", "3 Tage"], ["week", "Woche"], ["month", "Monat"], ["list", "Liste"]].map(([k, l]) => `<button class="${planState.view === k ? "active" : ""}" data-view="${k}">${k === "list" ? icon("list", 14) + " " : ""}${l}</button>`).join("")}</div>
        <span class="spacer" style="max-width:1.5rem"></span><button class="btn icon" id="prevBtn">${icon("chevron-left", 18)}</button><div class="cal2-title">${icon("calendar", 17)} <span>${label}</span></div><button class="btn icon" id="nextBtn">${icon("chevron-right", 18)}</button>
        <span class="spacer"></span><button class="btn" id="todayBtn">Heute</button><select class="input" id="modSel" style="width:auto"><option value="">Alle Module</option>${mods.map(m => `<option value="${m.id}" ${modFilter === m.id ? "selected" : ""}>${esc(shortName(m.name))}</option>`).join("")}</select><button class="btn icon" id="cfgBtn2" title="Lernkombination">${icon("settings", 17)}</button>${["week", "3days"].includes(planState.view) ? `<button class="btn icon" id="sideBtn" title="Seitenspalte ein-/ausblenden">${icon("panel-right", 17)}</button>` : ""}</div>
      <div id="calBody"></div></div>
      <aside class="cal2-side" id="calSide"></aside></div></div>`;
  const body = $("#calBody");
  if (planState.view === "week" || planState.view === "3days") body.innerHTML = weekGrid(days, await freeMap(start, end));
  else if (planState.view === "month") body.innerHTML = `<div class="cal-month">${DAYS.map(x => `<div class="mh">${x}</div>`).join("")}${days.map(dd => { const dt = parseISO(dd.date); return `<div class="md ${dt.getMonth() !== d.getMonth() ? "other" : ""} ${dd.date === t ? "today" : ""} ${holClass(dd)}" data-date="${dd.date}"><div class="n"><span class="sd ${dd.status}"></span>${dt.getDate()}</div>${holChips(dd, true)}${dlChips(dd, true)}${noteChips(dd, true)}<div class="mp">${dd.packages.map(p => `<span style="--pc:${p.color || "var(--accent)"}" title="${esc(p.subject)}"></span>`).join("")}</div>${dd.minutes ? `<span class="muted tiny">${fmtMin(dd.minutes)}</span>` : ""}</div>`; }).join("")}</div>`;
  else if (planState.view === "day") { const ex = holChips(days[0]) + dlChips(days[0]) + noteChips(days[0]); body.innerHTML = (ex ? `<div class="cal-day-extras">${ex}</div>` : "") + await dayTimeline(iso(d), days[0]); bindDayExtras(body, iso(d)); }
  else { body.innerHTML = await tasksListHtml(open); bindTaskRows(body, state.route); }
  $("#calSide").innerHTML = planState.view === "day" ? await daySide(iso(d), days[0], month || cal) : weekSide(days, backlog, month || cal, d);
  bindSide(view, iso(d), days);
  const go = (v, date) => { location.hash = `#/plan?view=${v}&date=${date}${planState.module ? `&module=${planState.module}` : ""}`; };
  $$("[data-view]", view).forEach(b => b.onclick = () => go(b.dataset.view, planState.date));
  const step = planState.view === "month" ? n => iso(new Date(d.getFullYear(), d.getMonth() + n, 1)) : n => iso(addDays(d, n * (planState.view === "week" ? 7 : planState.view === "3days" ? 3 : 1)));
  $("#prevBtn").onclick = () => go(planState.view, step(-1)); $("#nextBtn").onclick = () => go(planState.view, step(1)); $("#todayBtn").onclick = () => go(planState.view, t);
  $("#sideBtn")?.addEventListener("click", () => { const off = !$("#cal2").classList.contains("side-off"); $("#cal2").classList.toggle("side-off", off); try { localStorage.setItem("cal-side", off ? "off" : "on"); } catch {} });
  $("#modSel").onchange = e => { planState.module = e.target.value; go(planState.view, planState.date); };
  $("#genBtn").onclick = () => generatePlan(iso(planState.view === "week" ? start : d));
  $("#cfgBtn").onclick = $("#cfgBtn2").onclick = () => configDialog(); $("#addPkgBtn").onclick = () => addPackageDialog(iso(planState.view === "day" ? d : start));
  $("#rescueBtn").onclick = () => suggestFlow({ rescue: true });
  $("#catchPlan")?.addEventListener("click", () => suggestFlow({})); $("#catchNow")?.addEventListener("click", () => go("list", planState.date));
  $("#catchSkip")?.addEventListener("click", async () => { if (confirm(`${backlog.length} offene Aufgaben als bewusst übersprungen markieren?`)) { await api("/tasks/skip", { method: "POST", body: { task_ids: backlog.map(b => b.id) } }); toast("Übersprungen"); state.route(); } });
  bindCalendar(body);
}

// ---------------------------------------------------------------- Wochenraster
const H = 60;
function range(days) { const ev = days.flatMap(dd => [...(dd.events || []), ...dd.packages.filter(p => p.start_time).map(p => ({ start: p.start_time, end: p.end_time }))]); const lo = Math.min(8 * 60, ...ev.map(e => hm(e.start))); const hi = Math.max(19 * 60, ...ev.map(e => hm(e.end))); return { lo: Math.floor(lo / 60) * 60, hi: Math.ceil(hi / 60) * 60 }; }
export function ring(p, color) { return `<span class="ring" style="--p:${Math.max(0, Math.min(100, p || 0))};--rc:${color || "var(--ok)"}"></span>`; }
// Kurznamen enger Bloecke (app/static/plan-names.js): eindeutig je Fach ueber alle Tage der Ansicht
function planTinyNames(days) {
  return tinyNames(days.flatMap(dd => [...(dd.events || []).map(e => ({ title: e.title, module_id: e.module_id })), ...dd.packages.map(p => ({ title: p.subject, module_id: p.module_id }))]));
}
function sideOff() { try { const v = localStorage.getItem("cal-side"); return v ? v === "off" : window.innerWidth < 1400; } catch { return window.innerWidth < 1400; } }
async function freeMap(start, end) { const out = {}; for (const w of new Set([iso(mondayOf(start)), iso(mondayOf(end))])) { try { const tw = await api(`/timetable/week?start=${w}`); tw.days.forEach(x => { out[x.date] = x.free || []; }); } catch {} } return out; }
// Gleichzeitige Termine nebeneinander (Spuren) statt uebereinander
function lanes(items) {
  const sorted = items.map((it, i) => ({ ...it, i })).sort((a, b) => a.s - b.s || b.e - a.e); const res = []; let cluster = [], clusterEnd = -1, laneEnds = [];
  const flush = () => { const n = laneEnds.length || 1; cluster.forEach(c => { res[c.i].n = n; }); cluster = []; laneEnds = []; };
  for (const it of sorted) { if (cluster.length && it.s >= clusterEnd) flush(); let lane = laneEnds.findIndex(e => e <= it.s); if (lane < 0) { lane = laneEnds.length; laneEnds.push(it.e); } else laneEnds[lane] = it.e; res[it.i] = { lane, n: 1 }; cluster.push(it); clusterEnd = Math.max(clusterEnd, it.e); }
  flush(); return res;
}
function posStyle(px, s, e, L, minH = 30) { const top = px(s), h = Math.max(minH, px(e) - top - 3); const n = L?.n || 1, k = L?.lane || 0; return { h, css: `top:${top}px;height:${h}px;left:calc(${k} * (100% - 6px) / ${n} + 3px);width:calc((100% - 6px) / ${n} - ${n > 1 ? 2 : 0}px);right:auto` }; }
function dayHead(dd, compact) {
  const dt = parseISO(dd.date); const p = dd.tasks_total ? Math.round(100 * dd.tasks_done / dd.tasks_total) : 0;
  const col = dd.status === "nachholen" ? "var(--bad)" : dd.status === "erledigt" ? "var(--ok)" : dd.status === "teilweise" ? "var(--warn)" : "var(--accent)";
  const txt = dd.status === "frei" ? "Frei" : dd.minutes ? fmtMin(dd.minutes) : (compact ? "–" : "Nichts geplant");
  return `<div class="cal2-dh ${dd.date === todayISO() ? "today" : ""} ${holClass(dd)}" data-date="${dd.date}"><div class="wd">${DAYS[dd.weekday]}</div><div class="dn">${dt.getDate()}.${dt.getMonth() + 1}.</div><div class="pm">${dd.tasks_total ? ring(p, col) : ""}<span>${txt}</span></div>${holChips(dd, compact)}${dlChips(dd, compact)}${noteChips(dd, true)}</div>`;
}
function evBlock(e, px, dateStr, L, compact, tn) {
  const off = e.status !== "teilnahme"; const P = posStyle(px, hm(e.start), hm(e.end), L); const name = compact || (L?.n || 1) > 1 ? tn.get(e.title || "") : shortName(e.title);
  return `<div class="cal2-ev ${off ? "off" : ""} ${(L?.n || 1) >= 3 || (compact && (L?.n || 1) >= 2) ? "narrow" : ""}" style="--ec:${e.color || "var(--accent)"};${P.css}" data-ev="${e.event_id}" data-date="${dateStr}" title="${esc(e.title)} ${e.start}–${e.end}${e.room ? " · " + esc(e.room) : ""}${e.note ? " · " + esc(e.note) : ""}"><div class="t">${e.start}${compact ? "" : ` – ${e.end}`}</div><b>${esc(name)}</b>${P.h > 54 ? `<div class="r">${esc((e.room || KIND_LABEL[e.kind] || "").split(":")[0])}</div>` : ""}</div>`;
}
function pkgBlock(p, px, L, compact, tn) {
  const P = posStyle(px, hm(p.start_time), hm(p.end_time), L); const done = p.tasks.filter(t => t.status === "erledigt").length; const name = compact || (L?.n || 1) > 1 ? tn.get(p.subject || "") : shortName(p.subject);
  return `<div class="cal2-ev study ${p.status} ${(L?.n || 1) >= 3 || (compact && (L?.n || 1) >= 2) ? "narrow" : ""}" style="--ec:${p.color || "var(--info)"};${P.css}" data-pkg="${p.id}" title="Lernblock · ${esc(p.subject)}: ${esc(p.title)}"><div class="t">${icon("book", 11)} ${p.start_time}${compact ? "" : ` – ${p.end_time}`}</div><b>${esc(name)}</b>${P.h > 54 ? `<div class="r">${esc(p.title)}</div>` : ""}${P.h > 88 && !compact ? `<div class="foot">${statusPill(p.status)}<span class="chk ${p.status === "erledigt" ? "on" : ""}" data-pkgdone="${p.id}" title="${done}/${p.tasks.length} erledigt">${p.status === "erledigt" ? icon("check", 11) : ""}</span></div>` : ""}</div>`;
}
function weekGrid(days, free = {}) {
  const { lo, hi } = range(days); const px = m => (m - lo) / 60 * H; const t = todayISO(); const now = new Date(); const nowM = now.getHours() * 60 + now.getMinutes();
  const compact = days.length >= 7 && window.innerWidth < 1500; const tn = planTinyNames(days);
  const unslotted = days.flatMap(dd => dd.packages.filter(p => !p.start_time && p.tasks.length).map(p => ({ ...p, _d: dd.date }))); // leere Pakete brauchen keine Uhrzeit
  const col = dd => {
    const evs = (dd.events || []).filter(e => e.status !== "verschoben"); const pks = dd.packages.filter(p => p.start_time);
    const L = lanes([...evs.map(e => ({ s: hm(e.start), e: hm(e.end) })), ...pks.map(p => ({ s: hm(p.start_time), e: hm(p.end_time) }))]);
    const fr = (free[dd.date] || []).filter(w => w.end > lo && w.start < hi).map(w => `<div class="cal2-free" style="top:${px(Math.max(lo, w.start))}px;height:${px(Math.min(hi, w.end)) - px(Math.max(lo, w.start))}px" title="Frei ${w.start_hm}–${w.end_hm}"></div>`).join("");
    return `<div class="cal2-col ${dd.date === t ? "today" : ""} ${holClass(dd)}" style="height:${px(hi)}px;--hour:${H}px" data-date="${dd.date}">${fr}${evs.map((e, i) => evBlock(e, px, dd.date, L[i], compact, tn)).join("")}${pks.map((p, i) => pkgBlock(p, px, L[evs.length + i], compact, tn)).join("")}${dd.date === t && nowM >= lo && nowM <= hi ? `<div class="cal2-now" style="top:${px(nowM)}px"></div>` : ""}${dd.date === t ? `<button class="cal2-add" data-add="${dd.date}" title="Lernpaket hinzufügen">${icon("plus", 16)}</button>` : ""}</div>`;
  };
  return `<div class="cal2-grid" style="grid-template-columns:44px repeat(${days.length}, minmax(${days.length > 3 ? 78 : 0}px, 1fr))"><div></div>${days.map(dd => dayHead(dd, compact)).join("")}
    <div class="cal2-axis" style="height:${px(hi)}px">${Array.from({ length: (hi - lo) / 60 + 1 }, (_, i) => `<span style="top:${px(lo + i * 60)}px">${mh(lo + i * 60)}</span>`).join("")}</div>
    ${days.map(col).join("")}</div>
    <div class="cal2-legend"><span><i class="lg-uni"></i> Uni-Termin</span><span><i class="lg-study"></i> Lernblock</span><span><i class="lg-free"></i> Freie Zeit</span><span><i class="lg-off"></i> nicht besucht</span><span><i class="lg-hol"></i> Feiertag / vorlesungsfrei</span><span><i class="lg-dl"></i> Frist (Learnweb)</span><span><i class="lg-note"></i> Hinweis aus Ankündigung</span></div>
    ${unslotted.length ? `<div class="card flat" style="margin-top:.9rem;background:var(--surface-2);border-color:transparent"><div class="row between"><b class="small">${unslotted.length} Lernpaket${unslotted.length > 1 ? "e" : ""} ohne Uhrzeit</b><button class="btn sm" id="reslotWeek" data-dates="${[...new Set(unslotted.map(p => p._d))].sort().join(",")}">Uhrzeiten vergeben</button></div><div class="row wrap" style="margin-top:.5rem">${unslotted.map(p => `<div class="pkg ${p.status}" style="--pc:${p.color || "var(--accent)"};min-width:200px;flex:1" data-pkg="${p.id}"><div class="pt">${esc(shortName(p.subject))}</div><div class="ps">${fmtShort(p._d)} · ${esc(p.title)} · ${fmtMin(p.planned_minutes || 0)}</div></div>`).join("")}</div></div>` : ""}`;
}
export function bindCalendar(body) {
  $$(".dl-chip, .note-chip", body).forEach(a => a.addEventListener("click", e => e.stopPropagation()));    // Link ins Learnweb statt Tagesansicht
  $$(".pkg[data-pkg], .tt-ev[data-pkg], .cal2-ev[data-pkg], .day2-ev[data-pkg]", body).forEach(el => { el.onclick = e => { if (e.target.closest("[data-pkgdone]")) return; openPackage(+el.dataset.pkg); }; el.draggable = true; el.ondragstart = e => { e.dataTransfer.setData("text/plain", el.dataset.pkg); el.classList.add("dragging"); }; el.ondragend = () => el.classList.remove("dragging"); });
  $$("[data-pkgdone]", body).forEach(c => c.onclick = async e => { e.stopPropagation(); const p = await api(`/packages/${c.dataset.pkgdone}`); const done = p.status === "erledigt"; for (const t of p.tasks) if ((t.status === "erledigt") === done) await api(`/tasks/${t.id}/status`, { method: "POST", body: { status: done ? "geplant" : "erledigt" } }); toast(done ? "Wieder offen" : "Lernpaket erledigt ✓"); state.route(); });
  $$(".cal-day, .cal2-col", body).forEach(col => { col.ondragover = e => { e.preventDefault(); col.classList.add("drop"); }; col.ondragleave = () => col.classList.remove("drop"); col.ondrop = async e => { e.preventDefault(); col.classList.remove("drop"); const id = e.dataTransfer.getData("text/plain"); if (!id) return; try { await api(`/packages/${id}`, { method: "PATCH", body: { date: col.dataset.date } }); toast("Verschoben"); state.route(); } catch (err) { toast(err.message); } }; const h = $(".dh", col); if (h) h.onclick = () => { location.hash = `#/plan?view=day&date=${col.dataset.date}`; }; });
  $$(".cal2-dh[data-date], .md[data-date]", body).forEach(el => el.onclick = () => { location.hash = `#/plan?view=day&date=${el.dataset.date}`; });
  $$("[data-add]", body).forEach(b => b.onclick = e => { e.stopPropagation(); addPackageDialog(b.dataset.add); });
  // "Uhrzeiten vergeben": die Tage der Pakete ohne Uhrzeit, von Hand gesetzte Uhrzeiten bleiben (only_unset)
  $("#reslotWeek", body)?.addEventListener("click", async e => { await api("/timetable/reslot", { method: "POST", body: { dates: e.currentTarget.dataset.dates.split(","), only_unset: true } }); toast("Uhrzeiten vergeben"); state.route(); });
  $$(".tt-ev[data-ev], .cal2-ev[data-ev], .day2-ev[data-ev]", body).forEach(el => el.onclick = () => import("./views-tt.js?v=30").then(m => m.openEvent(+el.dataset.ev, el.dataset.date)));
}
export function pkgBox(p) { return `<div class="pkg ${p.status}" style="--pc:${p.color || "var(--accent)"}" data-pkg="${p.id}"><div class="pt">${esc(shortName(p.subject || p.title))}</div><div class="ps">${esc(p.title && p.title !== p.subject ? p.title : "")}</div><div class="ps">${p.start_time ? `${p.start_time}–${p.end_time} · ` : ""}${fmtMin(p.planned_minutes || 0)} ${statusPill(p.status)}</div><div class="tl">${p.tasks.map(t => `<i class="${t.status === "erledigt" ? "done" : t.status === "nachholen" ? "late" : ""}" title="${esc(t.title)}">${{ vorlesung: "V", uebung: "Ü", test: "T", wiederholung: "W", frei: "L" }[t.type] || "•"}</i>`).join("")}</div></div>`; }

// ---------------------------------------------------------------- Seitenleiste (Woche)
export function donut(segs, centerBig, centerSmall) {
  const total = segs.reduce((a, s) => a + s.n, 0) || 1; let acc = 0;
  const grad = segs.map(s => { const a = acc / total * 360; acc += s.n; return `${s.color} ${a}deg ${acc / total * 360}deg`; }).join(", ") || "var(--line) 0deg 360deg";
  return `<div class="donut-wrap"><div class="donut" style="--seg:${segs.length && total ? grad : "var(--line) 0deg 360deg"}"><i><b>${centerBig}</b>${centerSmall}</i></div><div class="legend2">${segs.map(s => `<div><span class="dot" style="background:${s.color}"></span>${s.label}<b>${s.n}</b></div>`).join("")}</div></div>`;
}
export function miniCal(d, monthCal, selected) {
  const first = new Date(d.getFullYear(), d.getMonth(), 1); const start = mondayOf(first); const byDate = Object.fromEntries((monthCal?.days || []).map(x => [x.date, x])); const t = todayISO();
  const cells = Array.from({ length: 42 }, (_, i) => { const dt = addDays(start, i); const k = iso(dt); const dd = byDate[k]; const colors = [...new Set((dd?.packages || []).map(p => p.color || "var(--accent)"))].slice(0, 3); if (dd?.deadlines?.length) colors.push("var(--bad)"); if (dd?.notices?.length) colors.push("var(--info)"); const hc = dd ? holClass(dd) : ""; const tip = [...(dd?.marks || []).map(m => m.label), ...(dd?.deadlines || []).map(x => `${x.kind_label} ${x.time}: ${x.title}`), ...(dd?.notices || []).map(n => `${n.kind_label}: ${n.title}`)].join(" · "); return `<a href="#/plan?view=day&date=${k}" class="${dt.getMonth() !== d.getMonth() ? "other" : ""} ${k === t ? "today" : k === selected ? "sel" : ""} ${hc === "is-hol" ? "hol" : hc === "is-free" ? "vfrei" : ""}"${tip ? ` title="${esc(tip)}"` : ""}>${dt.getDate()}<span class="dots">${colors.map(c => `<i style="--dc:${c}"></i>`).join("")}</span></a>`; });
  const pm = iso(new Date(d.getFullYear(), d.getMonth() - 1, 1)), nm = iso(new Date(d.getFullYear(), d.getMonth() + 1, 1));
  return `<div class="side-card mini-cal"><h2>${MONTHS[d.getMonth()]} ${d.getFullYear()}<span class="row" style="gap:.2rem"><a class="btn ghost icon sm" href="#/plan?view=${planState.view}&date=${pm}">${icon("chevron-left", 15)}</a><a class="btn ghost icon sm" href="#/plan?view=${planState.view}&date=${nm}">${icon("chevron-right", 15)}</a></span></h2><div class="mh">${DAYS.map(x => `<span>${x}</span>`).join("")}</div><div class="md">${cells.slice(0, (byDate && cells.length) ? 42 : 42).join("")}</div></div>`;
}
function weekSide(days, backlog, monthCal, d) {
  const done = days.reduce((a, x) => a + x.tasks_done, 0), total = days.reduce((a, x) => a + x.tasks_total, 0);
  const late = days.flatMap(x => x.packages.flatMap(p => p.tasks.filter(t => t.status === "nachholen"))).length;
  const planned = Math.max(0, total - done - late); const uni = days.reduce((a, x) => a + (x.events || []).filter(e => e.status === "teilnahme").length, 0);
  const todo = backlog.slice(0, 4);
  return `<div class="side-card"><h2>Mein Fortschritt</h2>${donut([{ label: "Erledigt", n: done, color: "var(--ok)" }, { label: "Geplant", n: planned, color: "var(--info)" }, { label: "Nachholen", n: late, color: "var(--bad)" }, { label: "Uni-Termine", n: uni, color: "var(--line-strong)" }].filter((s, i) => i < 3 || s.n), `${done} / ${total}`, "Aufgaben")}</div>
    <div class="side-card"><h2>Nicht erledigt<span class="badge ${backlog.length ? "bad" : "neutral"}">${backlog.length}</span></h2>${todo.length ? todo.map(x => `<div class="todo-item" data-pkg="${x.package_id}"><span class="ic-c" style="background:var(--bad-soft);color:var(--bad)">${icon("alert", 13)}</span><div class="m"><b>${esc(shortName(x.subject || ""))}</b><span>${esc(x.title)}</span></div>${icon("chevron-right", 16)}</div>`).join("") : `<div class="muted small">Alles erledigt – nichts nachzuholen.</div>`}</div>
    <div class="side-card"><h2>Schnell hinzufügen</h2><div class="quick-grid"><button class="btn" data-q="pkg">${icon("book", 15)} Lernpaket</button><button class="btn" data-q="free">${icon("calendar", 15)} Freie Zeit</button><button class="btn" data-q="test">${icon("exam", 15)} Testtermin</button><button class="btn" data-q="personal">${icon("user", 15)} Persönlich</button></div></div>
    ${miniCal(d, monthCal, planState.date)}`;
}
function bindSide(view, dateStr, days) {
  $$("#calSide [data-pkg]", view).forEach(el => el.onclick = () => openPackage(+el.dataset.pkg));
  $$("#calSide [data-q]", view).forEach(b => b.onclick = async () => { const q = b.dataset.q; if (q === "pkg") addPackageDialog(dateStr); else if (q === "free") (await import("./views-tt.js?v=30")).availabilityDialog(); else if (q === "personal") (await import("./views-tt.js?v=30")).eventDialog(null, { date_from: dateStr, kind: "persoenlich" }); else location.hash = "#/exams"; });
  $$("#calSide [data-taskdone]", view).forEach(c => c.onclick = async () => { const done = c.classList.contains("on"); await api(`/tasks/${c.dataset.taskdone}/status`, { method: "POST", body: { status: done ? "geplant" : "erledigt" } }); toast(done ? "Wieder offen" : "Erledigt ✓"); state.route(); });
  $("#calSide #addTaskBtn", view)?.addEventListener("click", () => addPackageDialog(dateStr));
  $$("#calSide [data-use]", view).forEach(b => b.onclick = () => useFreeWindow(dateStr, b.dataset.use));
}

// ---------------------------------------------------------------- Tagesansicht als Zeitleiste
export async function dayTimeline(dateStr, dd) {
  const dt = await api(`/timetable/day?date=${dateStr}`); if (!dd) dd = (await api(`/calendar?start=${dateStr}&end=${dateStr}`)).days[0];
  const evs = dt.events.filter(e => e.status !== "verschoben" && (!planState.module || e.module_id === +planState.module));
  const lo = Math.max(0, Math.min(7 * 60, ...evs.map(e => hm(e.start)), ...dd.packages.filter(p => p.start_time).map(p => hm(p.start_time)))); const hi = Math.min(24 * 60, Math.max(20 * 60, ...evs.map(e => hm(e.end)), ...dd.packages.filter(p => p.end_time).map(p => hm(p.end_time)))); const HH = 72; const px = m => (m - lo) / 60 * HH;
  const blocks = [...dt.free.map(w => `<div class="day2-free" style="top:${px(w.start)}px;height:${px(w.end) - px(w.start)}px" title="Frei: ${w.start_hm}–${w.end_hm}"></div>`),
    ...evs.map(e => { const top = px(hm(e.start)), h = Math.max(58, px(hm(e.end)) - top - 6); const off = e.status !== "teilnahme"; return `<div class="day2-ev ${off ? "off" : ""}" style="--ec:${e.color || "var(--accent)"};top:${top}px;height:${h}px" data-ev="${e.event_id}" data-date="${dateStr}"><div class="ib">${icon(KIND_ICON[e.kind] || "calendar", 18)}</div><div class="m"><b>${esc(shortName(e.title))}</b><span>${e.start} – ${e.end}${e.room ? ` · ${esc(e.room)}` : ""}${off ? ` · ${{ nicht_teilnahme: "nicht besucht", ausfall: "fällt aus" }[e.status] || ""}` : ""}</span></div><div class="bd"><span class="badge kind">${KIND_LABEL[e.kind] || e.kind}</span>${e.module_name ? `<span class="badge neutral">${esc(shortName(e.module_name))}</span>` : ""}</div></div>`; }),
    ...dd.packages.filter(p => p.start_time).map(p => { const top = px(hm(p.start_time)), h = Math.max(58, px(hm(p.end_time)) - top - 6); const done = p.tasks.filter(t => t.status === "erledigt").length; return `<div class="day2-ev study ${p.status}" style="--ec:${p.color || "var(--info)"};top:${top}px;height:${h}px" data-pkg="${p.id}"><div class="ib">${icon("book", 18)}</div><div class="m"><b>${esc(shortName(p.subject))} – ${esc(p.title)}</b><span>${p.start_time} – ${p.end_time} · ${fmtMin(p.planned_minutes || 0)} · ${done}/${p.tasks.length} erledigt</span></div><div class="bd"><span class="badge info">Lernpaket</span>${statusPill(p.status)}</div></div>`; }),
    ...dt.blocked.map(b => `<div class="tt-blocked" style="left:60px;top:${px(hm(b.start))}px;height:${px(hm(b.end)) - px(hm(b.start))}px">${esc(b.title || "Sperrzeit")}</div>`)];
  const unslotted = dd.packages.filter(p => !p.start_time && p.tasks.length);
  return `<div class="day2" style="height:${px(hi) + 20}px"><div class="cal2-axis" style="position:absolute;left:0;top:0;width:52px;height:${px(hi)}px">${Array.from({ length: (hi - lo) / 60 + 1 }, (_, i) => `<span style="top:${px(lo + i * 60)}px">${mh(lo + i * 60)}</span>`).join("")}</div><div class="day2-lines" style="position:absolute;left:60px;right:8px;top:0;height:${px(hi)}px;background-image:linear-gradient(var(--line) 1px,transparent 1px);background-size:100% ${HH}px"></div>${blocks.join("")}${dateStr === todayISO() ? `<div class="cal2-now" style="left:60px;top:${px(new Date().getHours() * 60 + new Date().getMinutes())}px"></div>` : ""}</div>
    ${unslotted.length ? `<div class="card flat" style="margin-top:.6rem;background:var(--surface-2);border-color:transparent"><div class="row between"><b class="small">${unslotted.length} Lernpaket${unslotted.length > 1 ? "e" : ""} ohne Uhrzeit</b><a href="#" id="reslotBtn" class="btn sm">Uhrzeiten vergeben</a></div><div class="row wrap" style="margin-top:.5rem">${unslotted.map(pkgBox).join("")}</div></div>` : ""}`;
}
async function daySide(dateStr, dd, monthCal) {
  const dt = await api(`/timetable/day?date=${dateStr}`); const evs = dt.events.filter(e => e.status === "teilnahme");
  const lect = evs.filter(e => e.kind === "vorlesung").length, ex = evs.filter(e => e.kind !== "vorlesung" && e.kind !== "persoenlich").length;
  const tasks = dd.packages.flatMap(p => p.tasks.map(t => ({ ...t, p }))); const tests = tasks.filter(t => t.type === "test").length;
  const done = tasks.filter(t => t.status === "erledigt").length; const d = parseISO(dateStr);
  return `${miniCal(d, monthCal, dateStr)}
    <div class="side-card"><h2>Tagesübersicht</h2>${donut([{ label: "Vorlesungen", n: lect, color: "var(--accent)" }, { label: "Übungen", n: ex, color: "var(--ok)" }, { label: "Tests", n: tests, color: "var(--bad)" }, { label: "Freie Zeit", n: dt.free.length, color: "var(--line-strong)" }], `${done} / ${tasks.length}`, "Aufgaben")}</div>
    <div class="side-card"><h2>Heutige Aufgaben<button class="btn ghost sm" id="addTaskBtn" style="color:var(--accent-text)">${icon("plus", 14)} Hinzufügen</button></h2>${tasks.length ? tasks.map(t => `<div class="task2 ${t.status}"><span class="chk ${t.status === "erledigt" ? "on" : ""}" data-taskdone="${t.id}">${t.status === "erledigt" ? icon("check", 13) : ""}</span><div class="m"><b>${esc(shortName(t.p.subject))} – ${esc(t.title)}</b><span>${t.start_time ? `${t.start_time} – ${t.end_time} · ` : ""}${TYPE_TXT[t.type] || t.type} · ${t.est_minutes} min</span></div>${t.file_id ? `<a class="btn ghost icon sm" href="#/doc/${t.file_id}?task=${t.id}" title="Öffnen">${icon("book", 15)}</a>` : ""}</div>`).join("") : `<div class="muted small">Für diesen Tag ist nichts geplant.</div>`}</div>
    <div class="side-card"><h2>${icon("clock", 16)} Freie Zeit</h2>${dt.free.length ? dt.free.map(w => `<div class="row between" style="padding:.35rem 0;border-bottom:1px solid var(--line)"><span class="small"><b>${w.start_hm} – ${w.end_hm}</b> &nbsp; ${fmtMin(w.minutes)}${w.campus ? " · Campus" : ""}</span><button class="btn sm" data-use="${w.start}:${w.end}" style="color:var(--accent-text)">${icon("plus", 13)} Lernzeit planen</button></div>`).join("") : `<div class="muted small">Keine freien Fenster (Lernzeit ${dt.learn_start}–${dt.learn_end}).</div>`}</div>`;
}
export function bindDayExtras(body, dateStr) {
  $("#reslotBtn", body)?.addEventListener("click", async e => { e.preventDefault(); await api("/timetable/reslot", { method: "POST", body: { dates: [dateStr], only_unset: true } }); state.route(); });
  $$("[data-use]", body).forEach(b => b.onclick = () => useFreeWindow(dateStr, b.dataset.use));
}
export async function useFreeWindow(dateStr, range, extra = {}) {
  const [a, b] = range.split(":").map(Number); const mins = b - a;
  const m = modal(`<h3>${icon("sun", 18)} ${fmtMin(mins)} frei (${mh(a)}–${mh(b)})</h3><p class="muted">Wie möchtest du die Zeit nutzen?</p><div class="stack">
    ${extra.materials?.length ? `<button class="btn" data-u="exercise">${icon("pencil", 16)} Passende Übung bearbeiten</button><button class="btn" data-u="lecture">${icon("book", 16)} Vorlesung selbstständig nacharbeiten</button>` : ""}
    <button class="btn" data-u="ai">${icon("sparkles", 16)} Lerneinheit automatisch einplanen</button><button class="btn" data-u="catch">${icon("alert", 16)} Offene Aufgaben nachholen</button><button class="btn" data-u="manual">${icon("plus", 16)} Eigenen Lernblock anlegen</button><button class="btn ghost" data-close>Frei lassen</button></div>`);
  $$("[data-u]", m).forEach(btn => btn.onclick = async () => {
    const u = btn.dataset.u; m.remove();
    const mats = extra.materials || [];
    if (u === "exercise" || u === "lecture") { const lec = mats.filter(x => x.doc_type === "vorlesung"), ex = mats.filter(x => x.doc_type === "uebung"); const tasks = []; if (u === "lecture" && lec[0]) tasks.push({ type: "vorlesung", file_id: lec[0].id, title: lec[0].ai_title || lec[0].name, est_minutes: Math.min(mins, lec[0].est_minutes || 60) }); if (ex[0]) tasks.push({ type: "uebung", file_id: ex[0].id, title: ex[0].ai_title || ex[0].name, est_minutes: Math.min(mins - (tasks[0]?.est_minutes || 0), ex[0].est_minutes || 45) }); if (u === "lecture") tasks.push({ type: "test", title: "Gemeinsamer Wochentest", est_minutes: 15 }); const p = await api("/packages", { method: "POST", body: { date: dateStr, module_id: extra.module_id, title: u === "lecture" ? "Vorlesung nacharbeiten" : "Übung bearbeiten", tasks: tasks.filter(t => t.est_minutes > 0) } }); await api(`/packages/${p.id}`, { method: "PATCH", body: { start_time: mh(a) } }); toast("Lernblock angelegt"); state.route(); } // Beginn des Fensters statt den Tag neu zu legen
    if (u === "ai") { const r = await api("/calendar/generate", { method: "POST", body: { start: dateStr, window_start: mh(a), window_end: mh(b) } }); toast(r.message); state.route(); } // genau in dieses Fenster
    if (u === "catch") suggestFlow({ horizon: 1 });
    if (u === "manual") addPackageDialog(dateStr, mins);
  });
}

// ---------------------------------------------------------------- Lernpaket-Panel
export async function openPackage(id) {
  let p; try { p = await api(`/packages/${id}`); } catch { return toast("Paket nicht gefunden"); }
  const html = `<div class="drawer-head"><span class="dot" style="background:${p.color || "var(--accent)"}"></span><div style="flex:1"><b>${esc(p.subject)}</b><div class="muted small">${esc(p.title)} · ${fmtShort(p.date)}${p.start_time ? ` · ${p.start_time}–${p.end_time}` : ""} · ${fmtMin(p.planned_minutes || 0)}</div></div>${statusPill(p.status)}<button class="btn ghost icon" data-close>${icon("x", 18)}</button></div>
    <div class="drawer-body"><div class="stack" id="taskList">${p.tasks.map(t => taskRow(t)).join("")}</div>
      ${p.status === "nachholen" || p.status === "teilweise" ? `<div class="card flat" style="margin-top:1rem;background:var(--bad-soft);border-color:transparent"><b>${p.tasks.filter(t => t.status === "nachholen").length} Aufgaben müssen nachgeholt werden.</b><div class="row wrap" style="margin-top:.5rem"><button class="btn sm primary" id="pkSuggest">Neu einplanen</button><button class="btn sm" id="pkSkip">Bewusst überspringen</button></div></div>` : ""}</div>
    <div class="drawer-foot"><button class="btn sm" id="pkMove">${icon("move", 14)} Verschieben</button><button class="btn sm" id="pkTime">${icon("clock", 14)} Uhrzeit</button><button class="btn sm" id="pkAddTask">${icon("plus", 14)} Aufgabe</button><span class="spacer"></span><button class="btn sm danger" id="pkDel">${icon("trash", 14)}</button></div>`;
  const host = drawer(html);
  bindTaskRows(host, () => openPackage(id));
  $("#pkSuggest", host)?.addEventListener("click", () => suggestFlow({ package_id: id }));
  $("#pkSkip", host)?.addEventListener("click", async () => { await api("/tasks/skip", { method: "POST", body: { task_ids: p.tasks.filter(t => t.status === "nachholen").map(t => t.id) } }); toast("Übersprungen"); state.route(); });
  $("#pkMove", host).onclick = () => moveDialog(`Lernpaket „${p.subject}“ verschieben`, async date => { await api(`/packages/${id}`, { method: "PATCH", body: { date } }); toast("Verschoben"); state.route(); }, p.date);
  $("#pkTime", host).onclick = () => { const m = modal(`<h3>Uhrzeit</h3><div class="row"><label class="field" style="flex:1">Beginn<input class="input" type="time" id="ptS" value="${p.start_time || "09:00"}"></label><label class="field" style="flex:1">Dauer<input class="input" type="number" id="ptD" value="${p.start_time && p.end_time && hm(p.end_time) > hm(p.start_time) ? hm(p.end_time) - hm(p.start_time) : p.planned_minutes || 60}" step="15"></label></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="ptOk">Speichern</button></div>`); $("#ptOk", m).onclick = async () => { await api(`/packages/${id}`, { method: "PATCH", body: { start_time: $("#ptS", m).value, end_time: mh(hm($("#ptS", m).value) + (+$("#ptD", m).value)) } }); m.remove(); state.route(); }; };
  $("#pkDel", host).onclick = async () => { if (confirm("Lernpaket mit allen Aufgaben löschen?")) { await api(`/packages/${id}`, { method: "DELETE" }); state.route(); } };
  $("#pkAddTask", host).onclick = () => addTaskDialog(p, () => openPackage(id));
}
export function taskRow(t) {
  const done = t.status === "erledigt";
  return `<div class="task-row ${t.status}" data-task="${t.id}"><div class="chk ${done ? "on" : ""}" data-done="${t.id}" title="${done ? "Als offen markieren" : "Als erledigt markieren"}">${done ? icon("check", 14) : ""}</div>
    <div class="tt"><b>${icon(TYPE_ICON[t.type] || "file", 14)} ${esc(t.title)}</b><span>${TYPE_TXT[t.type] || t.type} · ${t.est_minutes} min${t.start_time ? ` · ${t.start_time}–${t.end_time}` : ""} · ${STATUS_TXT[t.status]}${t.moved_from ? ` · verschoben von ${fmtShort(t.moved_from)}` : ""}${t.test_submitted ? ` · ${Math.round(t.test_score)}/${Math.round(t.test_max)} P.` : ""}</span></div>
    ${t.file_id ? `<a class="btn sm" href="#/doc/${t.file_id}?task=${t.id}${t.last_page > 1 ? `&page=${t.last_page}` : ""}" title="Dokument öffnen">${icon("book", 14)} Öffnen</a>` : t.type === "test" ? `<button class="btn sm ${t.test_submitted ? "" : "primary"}" data-starttest="${t.id}">${icon("play", 14)} ${t.test_id ? (t.test_submitted ? "Ergebnis" : "Fortsetzen") : "Test starten"}</button>` : ""}
    <button class="btn ghost icon sm" data-taskmenu="${t.id}" title="Mehr">${icon("more", 16)}</button></div>`;
}
export function bindTaskRows(host, refresh) {
  $$("[data-done]", host).forEach(c => c.onclick = async () => { const done = c.classList.contains("on"); await api(`/tasks/${c.dataset.done}/status`, { method: "POST", body: { status: done ? "geplant" : "erledigt" } }); toast(done ? "Wieder offen" : "Erledigt ✓"); refresh(); });
  $$("[data-starttest]", host).forEach(b => b.onclick = async () => { b.disabled = true; b.textContent = "Test wird erstellt…"; try { const r = await api(`/tasks/${b.dataset.starttest}/start-test`, { method: "POST" }); location.hash = `#/exams/${r.test_id}?task=${b.dataset.starttest}`; } catch (e) { toast(e.message, 5000); b.disabled = false; } });
  $$("[data-taskmenu]", host).forEach(b => b.onclick = () => {
    const id = +b.dataset.taskmenu;
    const m = modal(`<h3>Aufgabe</h3><div class="stack"><button class="btn" data-a="in_bearbeitung">${icon("play", 14)} In Bearbeitung</button><button class="btn" data-a="move">${icon("move", 14)} Auf anderen Tag verschieben</button><button class="btn" data-a="uebersprungen">${icon("x", 14)} Bewusst überspringen</button><button class="btn" data-a="edit">${icon("pencil", 14)} Titel / Dauer ändern</button><button class="btn danger" data-a="delete">${icon("trash", 14)} Löschen</button></div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`);
    $$("[data-a]", m).forEach(x => x.onclick = async () => {
      const a = x.dataset.a; m.remove();
      if (a === "move") return moveDialog("Aufgabe verschieben", async date => { await api("/calendar/apply", { method: "POST", body: { moves: [{ task_id: id, to: date }] } }); toast("Verschoben"); refresh(); state.route(); });
      if (a === "delete") { if (confirm("Aufgabe löschen?")) { await api(`/tasks/${id}`, { method: "DELETE" }); refresh(); } return; }
      if (a === "edit") { const row = $(`[data-task="${id}"] .tt b`, host); const e = modal(`<h3>Aufgabe bearbeiten</h3><label class="field">Titel<input class="input" id="etT" value="${esc(row?.textContent.trim() || "")}"></label><label class="field">Dauer (Minuten)<input class="input" type="number" id="etM" value="45" min="5" step="5"></label><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="etOk">Speichern</button></div>`); $("#etOk", e).onclick = async () => { await api(`/tasks/${id}`, { method: "PATCH", body: { title: $("#etT", e).value, est_minutes: +$("#etM", e).value } }); e.remove(); refresh(); }; return; }
      await api(`/tasks/${id}/status`, { method: "POST", body: { status: a } }); refresh();
    });
  });
}
export function moveDialog(title, onPick, current) {
  const m = modal(`<h3>${esc(title)}</h3><label class="field">Neuer Tag<input class="input" type="date" id="mvDate" value="${current || todayISO()}"></label><div class="row wrap" style="margin:.3rem 0">${[1, 2, 3, 7].map(n => `<button class="chip" data-n="${n}">+${n} Tag${n > 1 ? "e" : ""}</button>`).join("")}</div><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="mvOk">Verschieben</button></div>`);
  $$("[data-n]", m).forEach(c => c.onclick = () => { $("#mvDate", m).value = iso(addDays(new Date(), +c.dataset.n)); });
  $("#mvOk", m).onclick = async () => { const v = $("#mvDate", m).value; if (!v) return; m.remove(); await onPick(v); };
}
async function addTaskDialog(p, refresh) {
  const d = p.module_id ? await api(`/modules/${p.module_id}`) : { files: [] };
  const m = modal(`<h3>Aufgabe hinzufügen</h3><label class="field">Art<select class="input" id="atType"><option value="vorlesung">Vorlesung</option><option value="uebung">Übung</option><option value="test">Wochentest</option><option value="wiederholung">Wiederholung</option><option value="frei">Freies Lernen</option></select></label>
    <label class="field">Dokument (optional)<select class="input" id="atFile"><option value="">– keins –</option>${d.files.map(f => `<option value="${f.id}">${esc(f.ai_title || f.name)}</option>`).join("")}</select></label>
    <label class="field">Titel<input class="input" id="atTitle" placeholder="z. B. Kapitel 3 wiederholen"></label><label class="field">Dauer (Minuten)<input class="input" type="number" id="atMin" value="45" min="5" step="5"></label>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="atOk">Hinzufügen</button></div>`);
  $("#atFile", m).onchange = () => { const f = d.files.find(x => x.id === $("#atFile", m).value); if (f && !$("#atTitle", m).value) $("#atTitle", m).value = f.ai_title || f.name; };
  $("#atOk", m).onclick = async () => { await api(`/packages/${p.id}/tasks`, { method: "POST", body: { type: $("#atType", m).value, file_id: $("#atFile", m).value || null, title: $("#atTitle", m).value || TYPE_TXT[$("#atType", m).value], est_minutes: +$("#atMin", m).value } }); m.remove(); toast("Aufgabe hinzugefügt"); refresh(); };
}
export async function addPackageDialog(date, minutes = 60) {
  const mods = await api("/modules");
  const m = modal(`<h3>Neues Lernpaket</h3><div class="row"><label class="field" style="flex:1">Tag<input class="input" type="date" id="npDate" value="${date}"></label><label class="field" style="flex:1">Modul<select class="input" id="npMod">${mods.map(x => `<option value="${x.id}">${esc(x.name)}</option>`).join("")}</select></label></div>
    <label class="field">Titel<input class="input" id="npTitle" placeholder="z. B. Kapitel 2 lernen"></label><div class="row"><label class="field" style="flex:1">Beginn (optional)<input class="input" type="time" id="npStart"></label><label class="field" style="flex:1">Dauer (Minuten)<input class="input" type="number" id="npMin" value="${minutes}" min="5" step="5"></label></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="npOk">Anlegen</button></div>`);
  $("#npOk", m).onclick = async () => { const r = await api("/packages", { method: "POST", body: { date: $("#npDate", m).value, module_id: +$("#npMod", m).value, title: $("#npTitle", m).value || "Lernen", minutes: +$("#npMin", m).value } }); if ($("#npStart", m).value) await api(`/packages/${r.id}`, { method: "PATCH", body: { start_time: $("#npStart", m).value, end_time: mh(hm($("#npStart", m).value) + (+$("#npMin", m).value)) } }); m.remove(); toast("Lernpaket angelegt"); state.route(); };
}
export async function generatePlan(startDate) {
  const feas = await api("/calendar/feasibility");
  const m = modal(`<h3>${icon("sparkles", 18)} Lernplan erstellen</h3><p class="muted small">Erstellt Lernpakete pro Modul und Lehrwoche (Vorlesung → Übungen → gemeinsamer Wochentest) für freie Tage ab dem gewählten Datum und legt sie in freie Zeitfenster deines Stundenplans. Bestehende Pakete bleiben erhalten.</p>
    ${feas.hint ? `<div class="card flat" style="background:var(--warn-soft);border-color:transparent;margin:.5rem 0"><b>${icon("alert", 14)} Hinweis:</b> ${esc(feas.hint)}</div>` : `<div class="small muted">Offen: ca. ${fmtMin(feas.open_minutes)} · verfügbar in 4 Wochen: ${fmtMin(feas.available_minutes_4w)}</div>`}
    <div class="row"><label class="field" style="flex:1">Ab<input class="input" type="date" id="gpStart" value="${startDate}"></label><label class="field" style="flex:1">Tage<select class="input" id="gpDays"><option value="7">7 Tage</option><option value="14">14 Tage</option><option value="28">4 Wochen</option></select></label></div>
    <label class="field"><input type="checkbox" id="gpReplace"> Automatisch erstellte, noch nicht begonnene Pakete in diesem Zeitraum ersetzen</label>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn" id="gpCfg">Lernkombination ändern</button><button class="btn primary" id="gpOk">Erstellen</button></div>`);
  $("#gpCfg", m).onclick = () => { m.remove(); configDialog(() => generatePlan(startDate)); };
  $("#gpOk", m).onclick = async () => { $("#gpOk", m).disabled = true; const st = $("#gpStart", m).value; try { const r = await api("/calendar/generate", { method: "POST", body: { start: st, days: +$("#gpDays", m).value, replace: $("#gpReplace", m).checked } }); m.remove(); toast(r.message); location.hash = `#/plan?view=week&date=${st}`; state.route(); } catch (e) { toast(e.message); $("#gpOk", m).disabled = false; } };
}
const PRESETS = { A: { n: "Intensiv", d: "1 Fach pro Tag · Vorlesung + Übungen + Wochentest", v: { subjects_per_day: 1, parts_lecture: 1, parts_exercise: 1, tests_per_subject: 1 } }, B: { n: "Intensiv mit Wiederholung", d: "1 Fach pro Tag · zusätzlich Wiederholung (Karteikarten)", v: { subjects_per_day: 1, parts_lecture: 1, parts_exercise: 1, tests_per_subject: 2 } }, C: { n: "Abwechslungsreich", d: "2 Fächer pro Tag · je Vorlesung + Übungen + Wochentest", v: { subjects_per_day: 2, parts_lecture: 1, parts_exercise: 1, tests_per_subject: 1 } }, D: { n: "Zwei Fächer mit Wiederholung", d: "2 Fächer pro Tag · zusätzlich Wiederholung", v: { subjects_per_day: 2, parts_lecture: 1, parts_exercise: 1, tests_per_subject: 2 } }, E: { n: "Benutzerdefiniert", d: "Alles selbst kombinieren", v: null } };
export async function configDialog(after) {
  const s = await api("/settings");
  const m = modal(`<h3>Meinen Lernplan konfigurieren</h3>
    <div class="stack" id="presets">${Object.entries(PRESETS).map(([k, p]) => `<label class="chip" style="justify-content:flex-start;padding:.5rem .8rem;border-radius:10px"><input type="radio" name="preset" value="${k}" style="margin-right:.4rem"><b>${k} – ${p.n}</b>&nbsp;<span class="muted">${p.d}</span></label>`).join("")}</div>
    <div class="grid cols-2" style="margin-top:.8rem">
      <label class="field">Fächer pro Tag<select class="input" id="cSub">${[1, 2, 3].map(n => `<option value="${n}" ${s.subjects_per_day == n ? "selected" : ""}>${n} Fach${n > 1 ? "er" : ""}</option>`).join("")}</select></label>
      <label class="field">Lernzeit pro Tag (Minuten)<input class="input" type="number" id="cMin" value="${s.minutes_per_day}" min="30" step="15"></label>
      <label class="field">Vorlesungen der Woche<select class="input" id="cLec"><option value="0" ${s.parts_lecture == 0 ? "selected" : ""}>nicht einplanen</option><option value="1" ${s.parts_lecture >= 1 ? "selected" : ""}>alle der Lehrwoche</option></select></label>
      <label class="field">Übungen der Woche<select class="input" id="cEx"><option value="0" ${s.parts_exercise == 0 ? "selected" : ""}>nicht einplanen</option><option value="1" ${s.parts_exercise >= 1 ? "selected" : ""}>alle (Hörsaal-, Gruppenübung …)</option></select></label>
      <label class="field">Wochentest pro Modul<select class="input" id="cTests"><option value="0" ${s.tests_per_subject == 0 ? "selected" : ""}>kein Test</option><option value="1" ${s.tests_per_subject == 1 ? "selected" : ""}>1 gemeinsamer Test</option><option value="2" ${s.tests_per_subject == 2 ? "selected" : ""}>1 Test + Wiederholung</option></select></label>
      <label class="field">Dauer Wochentest<select class="input" id="cTmin">${[15, 30, 45, 60, 90].map(n => `<option value="${n}" ${s.test_minutes == n ? "selected" : ""}>${n} min</option>`).join("")}</select></label></div>
    <label class="field">Lerntage<div class="row wrap" id="cDays">${DAYS.map((d, i) => `<button type="button" class="chip ${s.free_days.includes(i) ? "" : "on"}" data-d="${i}">${d}</button>`).join("")}</div></label>
    <label class="field"><input type="checkbox" id="cExam" ${s.exam_priority ? "checked" : ""}> Klausurtermine stärker priorisieren</label>
    <div id="cFeas" class="small muted" style="margin:.4rem 0"></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="cOk">Speichern</button></div>`);
  const upd = () => { const sub = +$("#cSub", m).value, lec = +$("#cLec", m).value, ex = +$("#cEx", m).value, te = +$("#cTests", m).value, tm = +$("#cTmin", m).value, mn = +$("#cMin", m).value; const need = sub * (lec * 45 + ex * 60 + (te ? tm : 0) + (te > 1 ? 15 : 0)); $("#cFeas", m).innerHTML = `Deine Kombination: <b>${sub} Fächer täglich · ${lec ? "Vorlesung" : "ohne Vorlesung"} · ${ex ? "Übungen" : "ohne Übung"} · ${te ? "1 Wochentest" : "kein Test"}${te > 1 ? " + Wiederholung" : ""}</b> → etwa ${fmtMin(need)} pro Tag. ${need > mn ? `<span style="color:var(--bad)">Das passt nicht in ${fmtMin(mn)}. Vorschlag: ${sub > 1 ? "weniger Fächer pro Tag" : "kürzerer Test oder mehr Lernzeit"}.</span>` : `<span style="color:var(--ok)">Passt in ${fmtMin(mn)}.</span>`}`; };
  $$("select, input", m).forEach(el => el.addEventListener("input", upd)); upd();
  $$("input[name=preset]", m).forEach(r => r.onchange = () => { const p = PRESETS[r.value]; if (p.v) { $("#cSub", m).value = p.v.subjects_per_day; $("#cLec", m).value = p.v.parts_lecture; $("#cEx", m).value = p.v.parts_exercise; $("#cTests", m).value = p.v.tests_per_subject; } upd(); });
  $$("#cDays .chip", m).forEach(c => c.onclick = () => c.classList.toggle("on"));
  $("#cOk", m).onclick = async () => { const free = $$("#cDays .chip", m).filter(c => !c.classList.contains("on")).map(c => +c.dataset.d); await api("/settings", { method: "PUT", body: { subjects_per_day: $("#cSub", m).value, parts_lecture: $("#cLec", m).value, parts_exercise: $("#cEx", m).value, tests_per_subject: $("#cTests", m).value, test_minutes: $("#cTmin", m).value, hours_per_day: (+$("#cMin", m).value / 60).toFixed(2), free_days: free, exam_priority: $("#cExam", m).checked } }); m.remove(); toast("Lernkombination gespeichert"); if (after) after(); else state.route(); };
}
export async function suggestFlow(body) {
  const r = await api("/calendar/suggest", { method: "POST", body });
  if (!r.moves.length) return toast(r.message);
  const m = modal(`<h3>${body.rescue ? icon("life-buoy", 18) + " Meine Woche retten" : icon("move", 18) + " Neu einplanen"}</h3><p>${esc(r.message)}</p>
    <ul class="sugg" style="list-style:none;padding:0;margin:.5rem 0">${r.moves.map((mv, i) => `<li><span>${icon(TYPE_ICON[mv.type] || "file", 14)} ${esc(shortName(mv.subject || ""))}: ${esc(mv.title)}</span><span class="muted small">${mv.est_minutes} min</span><span class="muted small">${fmtShort(mv.from)} →</span><input class="input" type="date" value="${mv.to || ""}" data-i="${i}" style="width:150px"></li>`).join("")}</ul>
    <p class="muted small">${body.rescue ? "Verteilt auf die nächsten 7 Tage, höchstens 60 % deiner Tageszeit, damit nichts gestapelt wird." : "Verteilt nach freier Lernzeit. Erledigte Aufgaben bleiben erledigt."} Du kannst jeden Tag noch ändern.</p>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="sgOk">Vorschlag übernehmen</button></div>`);
  $("#sgOk", m).onclick = async () => { $$("input[data-i]", m).forEach(inp => r.moves[+inp.dataset.i].to = inp.value); const a = await api("/calendar/apply", { method: "POST", body: { moves: r.moves } }); m.remove(); toast(`${a.moved} Aufgaben neu eingeplant`); state.route(); };
}
export async function tasksListHtml(ts) {
  ts = ts || await api("/tasks/open"); const t = todayISO();
  const groups = [["Nachholen", ts.filter(x => x.status === "nachholen"), "bad"], ["Heute", ts.filter(x => x.date === t && x.status !== "nachholen"), "info"], ["Demnächst", ts.filter(x => x.date > t), "neutral"]];
  return `<div class="stack">${groups.map(([n, list, cls]) => list.length ? `<div class="card"><div class="card-head"><h2><span class="badge ${cls}">${list.length}</span> ${n}</h2></div>${list.map(x => `<div class="row small muted" style="margin:.4rem 0 -.2rem"><span class="dot" style="background:${x.color || "var(--accent)"}"></span>${esc(shortName(x.subject || ""))} · ${fmtShort(x.date)}</div>${taskRow(x)}`).join("")}</div>` : "").join("") || `<div class="card empty">${icon("check", 36)}<div>Keine offenen Aufgaben.</div></div>`}</div>`;
}

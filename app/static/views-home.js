// StudiNow – Übersicht (Startseite): beantwortet "Was mache ich heute?" (Design 2, style.css Abschnitt "Übersicht (Design 2)").
// Oben links der größte Block mit der wichtigsten Information und dem Hauptknopf, daneben "Heute für dich geplant";
// darunter eine schlichte Zahlenzeile ohne Rahmen und Karten nur, wenn sie etwas zeigen. Alle Daten kommen aus
// GET /api/dashboard (study.dashboard); keine eigene Datenquelle.
import { $, $$, api, esc, safeUrl, noteChips, cancelMark, chipRef, icon, fmtShort, fmtMin, iso, parseISO, todayISO, shortName, DAYS, TYPE_ICON, state } from "./core.js?v=40";
import { openPackage, suggestFlow, generatePlan } from "./views-plan.js?v=45";
import { openEvent } from "./views-tt.js?v=43";
import { installBanner, bindInstallBanner } from "./pwa.js?v=12";
import { staggerOnce, countUp } from "./motion.js?v=2";
import { newsCard, bindNews } from "./news.js?v=3";

const OPEN = t => !["erledigt", "uebersprungen"].includes(t.status);
const hhmm = (d = new Date()) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
const dot = c => `<span class="dot" style="background:${esc(c || "var(--accent)")}" aria-hidden="true"></span>`;

/// "heute" / "morgen" / "Mo., 02.11." für ein ISO-Datum
function dayLabel(date, today) {
  if (date === today) return "heute";
  const t = parseISO(today); t.setDate(t.getDate() + 1);
  return date === iso(t) ? "morgen" : fmtShort(date);
}

/// Nächster Uni-Termin (Vorlesung bevorzugt) der Module in den nächsten 14 Tagen (modules[].next_event)
function nextLecture(modules) {
  const evs = modules.map(m => m.next_event && { ...m.next_event, module_name: m.next_event.module_name || m.name, color: m.next_event.color || m.color }).filter(Boolean);
  const sort = a => a.sort((x, y) => (x.date + x.start).localeCompare(y.date + y.start));
  const lectures = sort(evs.filter(e => e.kind === "vorlesung"));
  return lectures[0] || sort(evs)[0] || null;
}

/// Was zählt heute? Reihenfolge: nachzuholen, offene Aufgaben, alles erledigt, nächster Termin heute, nächster Termin
function pickFocus(d, ctx) {
  if (d.backlog) return { kind: "backlog" };
  if (ctx.nextOpen) return { kind: "tasks" };
  if (ctx.totalToday > 0) return { kind: "done" };
  if (ctx.nextEventToday) return { kind: "event", ev: ctx.nextEventToday };
  if (d.upcoming?.[0]) return { kind: "upcoming", u: d.upcoming[0] };
  return { kind: "none" };
}

function upcomingHref(u) {
  if (u.deadline_id) return safeUrl(u.url);
  return u.package_id ? `#/plan?view=day&date=${u.date}` : u.module_id ? `#/modules/${u.module_id}` : "#/plan";
}

function focusBlock(d, ctx, focus, lecture, aside = "") {
  const today = d.today.date;
  const linkLearn = ctx.nextOpen ? (ctx.nextOpen.file_id ? `#/doc/${ctx.nextOpen.file_id}?task=${ctx.nextOpen.id}` : `#/plan?view=day&date=${today}`) : "";
  let body = "", actions = "";
  if (focus.kind === "backlog") {
    body = `<div class="ov-big"><b>${d.backlog}</b><span>nachzuholen</span></div>
      <p class="ov-lead">Offene Aufgaben aus früheren Lernpaketen. StudiNow schlägt dir freie Zeiten dafür vor.</p>`;
    actions = `<button class="btn primary" id="rescueBtn">${icon("rotate", 16)} Jetzt nachholen</button>${ctx.nextOpen ? `<a class="btn" href="${linkLearn}">${icon("play", 16)} Heute weiterlernen</a>` : ""}`;
  } else if (focus.kind === "tasks") {
    const n = ctx.openToday, rest = ctx.openMinutes;
    body = `<div class="ov-big"><b>${n}</b><span>${n === 1 ? "Aufgabe" : "Aufgaben"} für heute</span></div>
      <p class="ov-lead">${fmtMin(rest)} geplant. Als Nächstes: <span class="ov-nowrap">${dot(ctx.nextOpen.p.color)} ${esc(ctx.nextOpen.title)}</span></p>`;
    actions = `<a class="btn primary" href="${linkLearn}">${icon("play", 16)} Weiterlernen</a>`;
  } else if (focus.kind === "done") {
    body = `<div class="ov-head">Heute ist alles erledigt.</div><p class="ov-lead">${ctx.doneToday} von ${ctx.totalToday} Aufgaben abgehakt.</p>`;
    actions = `<a class="btn" href="#/plan?view=day&date=${today}">${icon("calendar", 16)} Tagesansicht</a>`;
  } else if (focus.kind === "event") {
    const e = focus.ev;
    body = `<div class="ov-head">${dot(e.color)} ${esc(e.title)}</div><p class="ov-lead">Heute ${esc(e.start)}–${esc(e.end)}${e.room ? ` · ${esc(e.room)}` : ""}</p>`;
    actions = `<button class="btn primary" data-ev="${e.event_id}">${icon("clock", 16)} Termin öffnen</button>`;
  } else if (focus.kind === "upcoming") {
    const u = focus.u;
    body = `<div class="ov-head">${dot(u.color)} ${esc(shortName(u.title))}</div><p class="ov-lead">${esc(dayLabel(u.date, today))}${u.time ? ` ${esc(u.time)}` : ""} · ${esc(u.deadline_id ? (u.kind_label || "Frist") : u.kind === "klausur" ? "Klausur" : u.kind === "test" ? "Wochentest" : "Lernpaket")}</p>`;
    actions = `<a class="btn primary" href="${upcomingHref(u)}"${u.deadline_id ? ` target="_blank" rel="noopener"` : ""}>${icon("flag", 16)} Ansehen</a>`;
  } else {
    body = `<div class="ov-head">Heute ist nichts geplant.</div><p class="ov-lead">Lege dir einen Lernplan an oder genieße den freien Tag.</p>`;
    actions = `<button class="btn primary" id="genTodayBtn">${icon("sparkles", 16)} Lernplan erstellen</button>`;
  }
  const lectureLine = lecture && !(focus.kind === "event" && focus.ev.event_id === lecture.event_id && focus.ev.date === lecture.date)
    ? `<div class="ov-next"><span class="ov-kicker">${lecture.kind === "vorlesung" ? "Nächste Vorlesung" : "Nächster Termin an der Uni"}</span>
        <button class="ov-link" data-ev="${lecture.event_id}" data-evdate="${esc(lecture.date)}">${dot(lecture.color)} <b>${esc(shortName(lecture.module_name || lecture.title))}</b> · ${esc(dayLabel(lecture.date, today))} ${esc(lecture.start)}${lecture.room ? ` · ${esc(lecture.room)}` : ""}</button></div>` : "";
  return `<section class="ov-focus" aria-label="Was heute wichtig ist"><div class="ov-main"><div class="ov-kicker">Was mache ich heute?</div>${body}<div class="ov-actions">${actions}</div>${lectureLine}</div>${aside}</section>`;
}

function planCard(d, ctx) {
  const pk = d.today.packages, evs = ctx.evs;
  const pkgs = pk.map(p => {
    const done = p.tasks.filter(t => t.status === "erledigt").length; const color = p.color || "var(--accent)";
    return `<div class="pkg-card ov-pkg" style="--pc:${esc(color)}">
      <div class="row between wrap"><div class="ov-pkg-t"><div class="row">${dot(color)}<b>${esc(shortName(p.subject))}</b><span class="ov-t2 small">${p.start_time ? `${esc(p.start_time)}–${esc(p.end_time)} · ` : ""}${fmtMin(p.planned_minutes || 0)}</span></div>
        <div class="small ov-pkg-sub">${esc(p.title)}</div></div><button class="btn sm" data-pkg="${p.id}">Lernpaket öffnen</button></div>
      <div class="ov-tasks">${p.tasks.map(t => `<div class="row small ${t.status === "erledigt" ? "ov-done" : ""}">${icon(t.status === "erledigt" ? "check" : TYPE_ICON[t.type], 14)}<span class="ov-task-t">${esc(t.title)}</span><span class="ov-t2">${t.est_minutes} min</span>${t.file_id && t.status !== "erledigt" ? `<a class="small" href="#/doc/${t.file_id}?task=${t.id}">öffnen</a>` : ""}</div>`).join("")}</div>
      <div class="progress ok" role="progressbar" aria-valuenow="${done}" aria-valuemin="0" aria-valuemax="${p.tasks.length}" aria-label="${done} von ${p.tasks.length} Aufgaben erledigt"><i style="width:${p.tasks.length ? Math.round(100 * done / p.tasks.length) : 0}%"></i></div></div>`;
  }).join("");
  const events = evs.length ? `<div class="ov-sec"><h3>${icon("clock", 16)} An der Uni</h3><a class="small" href="#/timetable">Stundenplan</a></div>
    ${evs.map(e => `<div class="ov-ev ${e.status !== "teilnahme" ? "ov-off" : ""}" data-ev="${e.event_id}" role="button" tabindex="0">${dot(e.color)}<b>${esc(e.start)}–${esc(e.end)}</b><span class="ov-ev-t">${esc(e.title)}</span>${cancelMark(e)}${e.room ? `<span class="ov-t2 ov-ev-r" title="${esc(e.room)}">${esc(e.room)}</span>` : ""}</div>`).join("")}` : "";
  const nothing = !pk.length ? `<div class="ov-none"><p>Kein Lernpaket für heute.</p><button class="btn sm" id="genTodayBtn2">${icon("sparkles", 14)} Lernplan erstellen</button></div>` : "";
  return `<section class="ov-plan card"><div class="card-head"><h2>${icon("play", 18)} Heute für dich geplant</h2><a class="small" href="#/plan?view=day&date=${d.today.date}">Tagesansicht</a></div>${pkgs}${nothing}${events}</section>`;
}

/// Ist für heute weder Lernpaket noch Termin da, steht das kurz neben dem Fokus statt in einer leeren Karte
function emptyAside() {
  return `<div class="ov-aside"><h2>${icon("play", 18)} Heute für dich geplant</h2><p>Für heute ist nichts geplant.</p><button class="btn" id="genTodayBtn2">${icon("sparkles", 14)} Lernplan erstellen</button></div>`;
}

/// Die frühere Kästchenreihe als schlichte Zeile. "nachzuholen" steht schon groß im Fokus-Block und entfällt hier.
function statLine(d, ctx) {
  const t = d.today; const free = t.free?.length ? t.free.reduce((a, w) => a + w.minutes, 0) : 0;
  const items = [];
  if (t.minutes) items.push(`<span><b>${fmtMin(t.minutes)}</b> heute geplant${free ? `, ${fmtMin(free)} frei` : ""}</span>`);
  if (ctx.totalToday) items.push(`<span><b>${ctx.doneToday} / ${ctx.totalToday}</b> Aufgaben erledigt</span>`);
  return items.length ? `<p class="ov-stats" aria-label="Kennzahlen von heute">${items.join("")}</p>` : "";   // nichts zu zählen: keine leere Zeile
}

function termineCard(d) {
  if (!d.upcoming?.length) return "";
  return `<section class="card ov-card"><div class="card-head"><h2>${icon("flag", 18)} Nächste Termine</h2></div><div class="list">${d.upcoming.slice(0, 6).map(u => u.deadline_id
    ? `<a class="item" href="${esc(safeUrl(u.url))}" data-chip="${chipRef({ ...u, id: u.deadline_id, kind_label: u.kind_label || "Frist" }, "deadline", u.date)}" title="${esc(u.full_title || u.title)}">${dot(u.color)}<div class="main"><div class="title">${esc(shortName(u.title))}</div><div class="sub"${u.overdue ? ' style="color:var(--bad)"' : ""}>${fmtShort(u.date)}${u.time ? ` ${esc(u.time)}` : ""} · ${esc(u.kind_label || "Frist")}${u.course_title ? ` · ${esc(shortName(u.course_title))}` : ""}</div></div></a>`
    : `<a class="item" href="${upcomingHref(u)}">${dot(u.color)}<div class="main"><div class="title">${esc(shortName(u.title))}</div><div class="sub">${fmtShort(u.date)} · ${u.kind === "klausur" ? "Klausur" : u.kind === "test" ? "Wochentest" : "Lernpaket"}</div></div></a>`).join("")}</div></section>`;
}

function modulesCard(d) {
  const mods = (d.modules || []).filter(m => m.active !== 0).slice(0, 5);
  if (!mods.length) return "";
  return `<section class="card ov-card"><div class="card-head"><h2>${icon("book", 18)} Deine Module</h2><a class="small" href="#/modules">Alle</a></div><div class="list">${mods.map(m => `<a class="item ov-mod" href="#/modules/${m.id}" style="--mc:${esc(m.color || "var(--accent)")}">${dot(m.color)}<div class="main"><div class="title">${esc(shortName(m.name))}</div><div class="sub">${m.open_tasks ? `${m.open_tasks} offen` : "nichts offen"}${m.exam_date ? ` · Klausur ${fmtShort(m.exam_date)}` : m.next_event ? ` · ${esc(m.next_event.kind === "vorlesung" ? "Vorlesung" : "Termin")} ${esc(dayLabel(m.next_event.date, d.today.date))} ${esc(m.next_event.start)}` : ""}</div><div class="progress ov-mod-bar" role="progressbar" aria-valuenow="${m.progress || 0}" aria-valuemin="0" aria-valuemax="100" aria-label="Lernfortschritt ${m.progress || 0} Prozent"><i style="width:${m.progress || 0}%"></i></div></div></a>`).join("")}</div></section>`;
}

function weekCard(d) {
  if (!d.week?.total) return "";
  return `<section class="card ov-card"><div class="card-head"><h2>${icon("clock", 18)} Diese Woche</h2><span class="ov-t2 small">${d.week.done}/${d.week.total} erledigt</span></div><div class="progress ok" style="margin-bottom:.7rem"><i style="width:${Math.round(100 * d.week.done / d.week.total)}%"></i></div><div class="week-strip">${d.week.days.map(w => `<a class="d ${w.date === d.today.date ? "today" : ""}" href="#/plan?view=day&date=${w.date}"><b>${DAYS[(parseISO(w.date).getDay() + 6) % 7]}</b><span class="sd ${w.status}" style="margin:0 auto"></span><span class="m"${w.minutes ? ` title="${fmtMin(w.minutes)}"` : ""}>${w.minutes ? `${Math.floor(w.minutes / 60)}:${String(w.minutes % 60).padStart(2, "0")}` : "–"}</span></a>`).join("")}</div></section>`;
}

function newFilesCard(d) {
  if (!d.new_total) return "";
  const src = d.settings?.files_source || "Stud.IP"; const newByMod = {};
  d.new_files.forEach(f => (newByMod[f.subject || "Sonstiges"] ||= []).push(f));
  const ls = d.last_sync; const sync = ls?.finished_at ? `Letzter Abgleich ${new Date(ls.finished_at).toLocaleString("de-DE", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })}` : "";
  return `<section class="card ov-card"><div class="card-head"><h2>${icon("sparkles", 18)} Neu aus ${esc(src)}</h2><span class="ov-t2 small">${d.new_total}</span></div>${Object.entries(newByMod).slice(0, 4).map(([s, fs]) => `<a class="item" href="#/files?section=new"><div class="main"><div class="title">${esc(shortName(s))}</div><div class="sub">${fs.length} neue ${fs.length === 1 ? "Datei" : "Dateien"} · ${esc(fs[0].ai_title || fs[0].name)}${fs.length > 1 ? " …" : ""}</div></div><span class="badge">${fs.length}</span></a>`).join("")}
    <div class="row between ov-foot"><a class="small" href="#/files?section=new">Alle anzeigen</a><button class="btn ghost sm" id="markSeenBtn">Gesehen</button></div>${sync ? `<div class="ov-t2 tiny">${esc(sync)}</div>` : ""}</section>`;
}

function announcementsCard(d) {
  if (!d.announcements?.length) return "";
  const srcName = a => a.source === "studip" ? "Stud.IP" : a.source === "demo" ? "Demo" : "Learnweb";
  return `<section class="card ov-card"><div class="card-head"><h2>${icon("info", 18)} Ankündigungen</h2><span class="ov-t2 small">${d.announcements.length}</span></div>${d.announcements.slice(0, 5).map(a => `<details class="ann-item"><summary><div class="t" title="${esc(a.title)}">${esc(a.title)}</div><div class="s">${fmtShort(a.posted_at.slice(0, 10))}${a.course_title ? ` · ${esc(shortName(a.course_title))}` : ""} · ${srcName(a)}</div>${a.upcoming?.length ? `<div class="ann-dates">${noteChips({ notices: a.upcoming.slice(0, 3).map(x => ({ ...x, kind_label: `${fmtShort(x.date)} ${{ ausfall: "Ausfall?", verlegt: "Verlegung?", raum: "Raum", pruefung: "Prüfung", frist: "Frist", online: "Online" }[x.kind] || "Termin"}`, title: a.title, url: a.url, course_title: a.course_title })) }, true)}</div>` : ""}</summary><div class="body">${esc(a.text)}</div>${a.url ? `<a class="small" href="${esc(safeUrl(a.url))}" target="_blank" rel="noopener">Im ${srcName(a)} öffnen</a>` : ""}</details>`).join("")}</section>`;
}

/// `hints()` liefert die Hinweiskarten des Dienstes (Probe, siehe app.js trialHint); sie stehen unter dem Tagesplan.
export async function viewDashboard(_, __, view, hints = () => "") {
  // Neuigkeiten (Ankuendigungen, Nachrichten, Aenderungen) und neue Anzeigen im Schwarzen Brett sind Ergaenzungen: ein Fehler haelt die Uebersicht nicht an
  const [d, news, bulletin] = await Promise.all([api("/dashboard"), api("/news").catch(() => null), api("/studip/bulletin").catch(() => null)]);
  const h = new Date().getHours(); const greet = h < 11 ? "Guten Morgen" : h < 18 ? "Guten Tag" : "Guten Abend";
  const today = d.today, pk = today.packages;
  const evs = (today.events || []).filter(e => e.status !== "verschoben");
  const openTasks = pk.flatMap(p => p.tasks.filter(OPEN).map(t => ({ ...t, p })));
  const now = hhmm();
  const ctx = {
    evs, nextOpen: openTasks[0], openToday: openTasks.length, openMinutes: openTasks.reduce((a, t) => a + (t.est_minutes || 0), 0),
    doneToday: pk.reduce((n, p) => n + p.tasks.filter(t => t.status === "erledigt").length, 0), totalToday: pk.reduce((n, p) => n + p.tasks.length, 0),
    nextEventToday: evs.filter(e => e.status === "teilnahme" && e.end >= now).sort((a, b) => a.start.localeCompare(b.start))[0],
  };
  const focus = pickFocus(d, ctx), lecture = nextLecture(d.modules || []);
  const planEmpty = !pk.length && !evs.length;
  const soloFocus = planEmpty && focus.kind === "none";                     // nichts da: ein Block statt zwei
  // "Neuigkeiten" ersetzt die Karte "Ankuendigungen" (wie auf dem iPad); nur wenn /api/news nicht antwortet, bleibt die alte
  const newsHtml = news ? newsCard(news.items, d.today.date, bulletin?.new_count || 0) : announcementsCard(d);
  const rest = [termineCard(d), newsHtml, modulesCard(d), weekCard(d), newFilesCard(d)].filter(Boolean);
  const nEv = evs.filter(e => e.status === "teilnahme").length;
  view.innerHTML = `<div class="content ov" style="max-width:1120px">
    <div class="page-head greet"><div><h1>${greet}!</h1><div class="date">${new Date().toLocaleDateString("de-DE", { weekday: "long", day: "numeric", month: "long" })} · ${pk.length ? `heute ${pk.length} Lernpaket${pk.length > 1 ? "e" : ""}` : "heute kein Lernpaket"}${nEv ? ` · ${nEv} Uni-Termin${nEv > 1 ? "e" : ""}` : ""}</div></div>
      <div class="actions"><a class="btn" href="#/plan?view=day&date=${today.date}">${icon("calendar", 16)} Tagesansicht</a></div></div>
    ${statLine(d, ctx)}
    <div class="ov-top${planEmpty ? " solo" : ""}">${focusBlock(d, ctx, focus, lecture, planEmpty && !soloFocus ? emptyAside() : "")}${planEmpty ? "" : planCard(d, ctx)}</div>
    ${installBanner()}${hints()}
    ${rest.length ? `<div class="ov-rest">${rest.join("")}</div>` : ""}</div>`;
  bindInstallBanner(view);
  if (news) bindNews(view, news.items, d.today.date);
  // Abschnitte erscheinen beim ersten Oeffnen leicht gestaffelt, Kennzahlen rollen zur neuen Zahl (motion.js)
  staggerOnce($(".content.ov", view), "dashboard");
  $$(".ov-stats b", view).forEach((b, i) => countUp(b, `dashboard-stat-${i}`));
  $$("[data-pkg]", view).forEach(el => el.onclick = () => openPackage(+el.dataset.pkg));
  $$("[data-ev]", view).forEach(el => { const go = () => openEvent(+el.dataset.ev, el.dataset.evdate || today.date); el.onclick = go; el.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); } }; });
  $("#rescueBtn", view)?.addEventListener("click", e => { e.preventDefault(); suggestFlow({ rescue: true }); });
  $$("#genTodayBtn, #genTodayBtn2", view).forEach(b => b.addEventListener("click", () => generatePlan(todayISO())));
  $("#markSeenBtn", view)?.addEventListener("click", async () => { await api("/files/mark-seen", { method: "POST" }); state.route?.(); });
}

// Lernziele (Smart Planner 2.0) im Lernkalender am PC und im Browser (#/plan?view=ziele), wie GoalsPage.swift auf dem
// iPad: Ziele in Stunden je Modul, Kennzahlen, Machbarkeit mit Optionen bei Unterdeckung, Woche geplant/gelernt,
// Konflikte, Stoppuhr, Lernzeit eintragen, Zeitrahmen. Daten: GET /api/goals (app/smart_goals.py, ohne KI; plant nur
// bei geaenderten Eingaben um). Nichts wird ohne Klick geaendert.
import { $, $$, api, esc, icon, toast, modal, fmtShort, todayISO, mh, DAYS, state } from "./core.js?v=47";
import * as G from "./goals-logic.js?v=1";

const VIEWS = [["ziele", "Lernziele", "flag"], ["day", "Tag"], ["3days", "3 Tage"], ["week", "Woche"], ["month", "Monat"], ["list", "Liste", "list"]];
let ticker = null;

/** Ansichten des Lernkalenders als Leiste (geteilt mit views-plan.js) */
export const viewPills = current => `<div class="seg pill">${VIEWS.map(([k, l, ic]) => `<button class="${current === k ? "active" : ""}" data-view="${k}">${ic ? icon(ic, 14) + " " : ""}${l}</button>`).join("")}</div>`;

/** Aufruf mit Fehlerhinweis; danach Ansicht neu laden */
async function send(path, method, body, done) {
  try {
    const r = await api(path, { method, body });
    if (done) toast(done);
    state.route();
    return r ?? {};
  } catch (e) { toast(e.message || "Fehler", 5000); return null; }
}

async function plan(body = {}) {
  try {
    const r = await api("/goals/plan", { method: "POST", body });
    if (r.applied) toast(`Lernplan steht: ${r.change?.added ?? 0} neue, ${r.change?.removed ?? 0} entfernte Lernblöcke`, 4000);
    else toast(r.result?.message || "Zu wenig Zeit – wähle unten eine Option.", 5000);
  } catch (e) { toast(e.message || "Fehler", 5000); }
  state.route();
}

export async function viewGoals(view, planState) {
  const go = v => { location.hash = `#/plan?view=${v}&date=${planState.date}${planState.module ? `&module=${planState.module}` : ""}`; };
  view.innerHTML = `<div class="content wide goals" style="max-width:1400px;padding:1.3rem 1.5rem 3rem">${head(null)}<div class="card"><span class="muted">Lade Lernziele …</span></div></div>`;
  let o;
  try { o = await api("/goals"); } catch (e) {
    view.innerHTML = `<div class="content wide goals" style="max-width:1400px;padding:1.3rem 1.5rem 3rem">${head(null)}<div class="card">${icon("alert", 16)} ${esc(e.message || "Lernziele nicht erreichbar.")}</div></div>`;
    bindHead(view, null, go);
    return;
  }
  view.innerHTML = `<div class="content wide goals" style="max-width:1400px;padding:1.3rem 1.5rem 3rem">${head(o)}${bodyHtml(o)}</div>`;
  bindHead(view, o, go);
  bindBody(view, o);
}

function head(o) {
  const mods = o?.modules || [];
  return `<div class="page-head"><div><h1>Lernziele</h1><div class="sub">Wie viele Stunden du bis zur Klausur lernen willst – StudiNow verteilt sie auf deine freie Zeit.</div></div>
    <div class="actions"><button class="btn" id="glFrame">${icon("clock", 15)} Zeitrahmen</button><button class="btn" id="glEntry" ${mods.length ? "" : "disabled"}>${icon("plus", 15)} Zeit eintragen</button>
    <button class="btn primary" id="glPlan" ${mods.length ? "" : "disabled"}>${icon("sparkles", 15)} ${o?.planned ? "Neu verteilen" : "Plan erstellen"}</button></div></div>
    <div class="cal2-bar" style="margin-bottom:1rem">${viewPills("ziele")}</div>`;
}

function bindHead(view, o, go) {
  $$("[data-view]", view).forEach(b => b.onclick = () => go(b.dataset.view));
  $("#glFrame", view).onclick = () => settingsDialog();
  $("#glEntry", view).onclick = () => entryDialog(o?.modules || []);
  $("#glPlan", view).onclick = e => { e.currentTarget.disabled = true; plan(); };
}

// ---------------------------------------------------------------- Inhalt

function bodyHtml(o) {
  const mods = o.modules || [];
  let out = "";
  if (o.busy) out += `<div class="card flat" style="background:var(--info-soft);border-color:transparent;margin-bottom:1rem">${icon("clock", 15)} Der Plan wird gerade auf einem anderen Gerät neu berechnet – gleich noch einmal laden.</div>`;
  if (o.proposal) out += proposalHtml(o.proposal);
  if ((o.running || []).length) out += timerHtml(o.running, mods);
  if (!mods.length) return out + startHtml(o.modules_without_goal || []);
  out += `<div class="card goals-kpis">${G.kpis(o).map(([v, l]) => `<div class="kpi"><b>${esc(v)}</b><span>${esc(l)}</span></div>`).join("")}</div>`;
  if (o.plan && o.plan.status !== "ok") out += feasibilityHtml(o.plan, o);
  out += `<div class="goals-cols"><div class="card goals-mods"><div class="card-head"><h2>${icon("book", 17)} Module</h2></div>${mods.map(moduleHtml).join("")}</div>
    <div class="stack">${weekHtml(o.week || {})}${conflictsHtml(o.conflicts || [])}</div></div>`;
  if ((o.modules_without_goal || []).length) out += `<div class="card" style="margin-top:1rem"><div class="card-head"><h2>${icon("book", 17)} Module ohne Lernziel</h2></div><div class="row wrap">${o.modules_without_goal.map(m => `<button class="btn sm" data-newgoal="${m.module_id}">${icon("plus", 13)} ${esc(m.name)}</button>`).join("")}</div></div>`;
  return out;
}

const startHtml = others => `<div class="card"><div class="card-head"><h2>${icon("flag", 17)} Lernziele festlegen</h2></div>
  <p class="muted">Trage je Modul ein, wie viele Stunden du bis zur Klausur selbst lernen willst (zum Beispiel Mathematik 200 h). StudiNow plant daraus Lernblöcke in deine freie Zeit – nie über Vorlesungen, nie nach der Klausur.</p>
  ${others.length ? `<div class="row wrap">${others.map(m => `<button class="btn sm" data-newgoal="${m.module_id}">${icon("plus", 13)} ${esc(m.name)}</button>`).join("")}</div>` : `<p class="small muted">Noch keine Module. Verbinde Stud.IP oder lege Module an.</p>`}</div>`;

function proposalHtml(p) {
  const short = p.kind === "unterdeckt";
  return `<div class="card goals-proposal ${short ? "bad" : "warn"}"><div class="row wrap"><b>${icon("alert", 16)} ${esc(short ? `Die Zeit reicht nicht mehr: ${p.message || ""}` : (p.message || "Dein Plan sollte neu verteilt werden."))}</b><span class="spacer"></span>
    ${short ? "" : `<button class="btn sm primary" id="glReplan">Neu verteilen</button>`}<button class="btn sm" id="glKeep">Alten Plan behalten</button></div></div>`;
}

function timerHtml(running, mods) {
  return running.map(s => {
    const name = mods.find(m => m.module_id === s.module_id)?.name || "Lernzeit";
    const paused = s.state === "pause";
    return `<div class="card goals-timer" data-timer="${esc(s.uuid)}"><div class="row wrap">${icon("clock", 18)}<b><span>${esc(name)}</span>: <span class="goals-elapsed" data-elapsed="${esc(s.uuid)}">${G.elapsed(s)}</span>${paused ? " (Pause)" : ""}</b><span class="spacer"></span>
      <button class="btn sm" data-tpause="${esc(s.uuid)}" data-paused="${paused ? 1 : 0}">${icon(paused ? "play" : "clock", 14)} ${paused ? "Weiter" : "Pause"}</button><button class="btn sm primary" data-tstop="${esc(s.uuid)}">${icon("check", 14)} Beenden</button></div></div>`;
  }).join("");
}

function feasibilityHtml(p, o) {
  const names = ids => (ids || []).map(id => o.modules.find(m => m.module_id === id)?.name).filter(Boolean).join(", ");
  return `<div class="card goals-feas"><div class="card-head"><h2>${icon("alert", 17)} ${p.status === "teilplan" ? "Teilplan: nicht alle Stunden passen" : "Zu wenig Zeit bis zu den Klausuren"}</h2></div>
    ${p.message ? `<p class="goals-feas-msg">${esc(p.message)}</p>` : ""}
    ${(p.deadlines || []).map(d => `<div class="goals-deadline"><b>bis ${esc(fmtShort(d.date))}</b><span>${G.h(d.need_minutes)} nötig, ${G.h(d.available_minutes)} verfügbar</span>${(d.missing_minutes || 0) > 0 ? `<span class="badge bad">fehlen ${G.h(d.missing_minutes)}</span>` : ""}<span class="muted small">${esc(names(d.modules))}</span></div>`).join("")}
    <p class="small muted">Was möchtest du tun? StudiNow ändert nichts, bevor du eine Option wählst.</p>
    <div class="stack">${(p.options || []).map((opt, i) => `<div class="goals-option"><span>${esc(opt.text || "")}</span>${G.actionable(opt) ? `<button class="btn sm" data-opt="${i}">Übernehmen</button>` : ""}</div>`).join("")}</div></div>`;
}

function moduleHtml(m) {
  const st = m.stats || {};
  const [label, tone] = G.STATUS[st.status] || ["", "neutral"];
  let exam;
  if (m.writing === false) exam = `<span class="badge neutral">schreibe ich nicht</span>`;
  else if (m.exam_date) exam = `<span class="small">Klausur ${esc(fmtShort(m.exam_date))} · ${G.days(st.days_left)}</span>${m.exam_source === "zweittermin" ? `<span class="badge info">Zweittermin</span>` : ""}${m.exam_confirmed === false ? `<span class="badge warn">unbestätigt</span><button class="btn sm" data-confirm="${m.module_id}">Bestätigen</button>` : ""}`;
  else exam = `<span class="badge warn">Klausurtermin fehlt</span>`;
  const color = /^#[0-9a-fA-F]{3,8}$/.test(m.color || "") ? m.color : "var(--accent)";
  return `<div class="goals-mod" data-mod="${m.module_id}" style="--mc:${color}"><div class="goals-mod-title"><b>${esc(m.name)}</b>${exam}<span class="spacer"></span>${label ? `<span class="badge ${tone}">${label}</span>` : ""}</div>
    <div class="progress"><i style="width:${Math.round(G.share(st) * 100)}%;background:var(--mc)"></i></div>
    <div class="small muted goals-numbers">${esc(G.numbers(st))}</div>
    <div class="row wrap"><button class="btn sm" data-goal="${m.module_id}">${icon("pencil", 13)} Ziel</button><button class="btn sm" data-start="${m.module_id}">${icon("play", 13)} Starten</button><button class="btn sm" data-entry="${m.module_id}">${icon("plus", 13)} Zeit eintragen</button></div></div>`;
}

function weekHtml(week) {
  const ds = week.days || [];
  const top = Math.max(60, ...ds.map(d => Math.max(d.planned_minutes || 0, d.learned_minutes || 0)));
  return `<div class="card"><div class="card-head"><h2>${icon("calendar", 17)} Diese Woche</h2></div>
    ${ds.map(d => `<div class="goals-day"><b>${G.weekday(d.date)}</b><div class="goals-bar"><i class="pl" style="width:${Math.round((d.planned_minutes || 0) / top * 100)}%"></i><i class="le" style="width:${Math.round(Math.min(1, (d.learned_minutes || 0) / top) * 100)}%"></i></div><span class="small">${G.h(d.learned_minutes)} / ${G.h(d.planned_minutes)}</span></div>`).join("")}
    <div class="row small muted" style="margin-top:.5rem"><span class="goals-key pl"></span> geplant <span class="goals-key le"></span> gelernt</div></div>`;
}

function conflictsHtml(cs) {
  return `<div class="card"><div class="card-head"><h2>${icon("alert", 17)} Konflikte</h2></div>
    ${cs.length ? cs.slice(0, 12).map(c => `<div class="goals-conflict ${c.kind === "unbestaetigt" ? "warn" : "bad"}" ${c.package_id ? `role="button" tabindex="0" data-pkg="${+c.package_id}"` : ""}>${icon(c.kind === "material" ? "file-text" : "alert", 14)} <span>${esc(c.text || "")}</span></div>`).join("") : `<span class="small muted">Keine Konflikte.</span>`}
    ${cs.length > 12 ? `<div class="small muted">und ${cs.length - 12} weitere</div>` : ""}</div>`;
}

function bindBody(view, o) {
  const mods = o.modules || [];
  const byId = id => mods.find(m => m.module_id === +id) || (o.modules_without_goal || []).find(m => m.module_id === +id);
  $("#glReplan", view)?.addEventListener("click", () => plan());
  $("#glKeep", view)?.addEventListener("click", () => send("/goals/plan/keep", "POST", undefined, "Plan bleibt wie er ist"));
  $$("[data-newgoal], [data-goal]", view).forEach(b => b.onclick = () => goalDialog(byId(b.dataset.newgoal || b.dataset.goal)));
  $$("[data-start]", view).forEach(b => b.onclick = () => send("/sessions/start", "POST", { module_id: +b.dataset.start }, "Stoppuhr läuft"));
  $$("[data-entry]", view).forEach(b => b.onclick = () => entryDialog(mods, +b.dataset.entry));
  $$("[data-confirm]", view).forEach(b => b.onclick = () => send(`/goals/${+b.dataset.confirm}`, "PUT", { confirm_exam: true }, "Klausurtermin bestätigt"));
  $$("[data-tpause]", view).forEach(b => b.onclick = () => send(`/sessions/${encodeURIComponent(b.dataset.tpause)}/${b.dataset.paused === "1" ? "resume" : "pause"}`, "POST"));
  $$("[data-tstop]", view).forEach(b => b.onclick = async () => {
    const r = await send(`/sessions/${encodeURIComponent(b.dataset.tstop)}/stop`, "POST");
    if (r) toast(`${G.h(r.credited_minutes)} gelernt – gespeichert`);
  });
  $$("[data-pkg]", view).forEach(c => c.onclick = async () => (await import("./views-plan.js?v=51")).openPackage(+c.dataset.pkg));
  $$("[data-opt]", view).forEach(b => b.onclick = async () => {
    const opt = o.plan.options[+b.dataset.opt];
    if (!confirm(`${opt.text || "Option"} – übernehmen und neu planen?`)) return;
    const q = G.optionRequests(opt, o);
    if (!q) return;
    for (const r of q.requests) {
      try { await api(r.path, { method: r.method, body: r.body }); } catch (e) { toast(e.message || "Fehler", 5000); state.route(); return; }
    }
    plan(q.plan);
  });
  // Stoppuhr laeuft sichtbar mit (nur solange diese Ansicht steht)
  clearInterval(ticker);
  if ((o.running || []).length) {
    ticker = setInterval(() => {
      const els = $$("[data-elapsed]", view);
      if (!els.length || !els[0].isConnected) { clearInterval(ticker); return; }
      for (const el of els) { const s = o.running.find(x => x.uuid === el.dataset.elapsed); if (s) el.textContent = G.elapsed(s); }
    }, 1000);
  }
}

// ---------------------------------------------------------------- Dialoge

const field = (label, inner) => `<label class="field">${label}${inner}</label>`;

/** Lernziel eines Moduls: Stunden, schon gelernt, Klausurtermin (+ gefundene Termine), Zweittermin, Prioritaet */
export async function goalDialog(m) {
  if (!m) return;
  const mid = m.module_id, hasGoal = m.target_minutes !== undefined;
  const exam = m.module_exam_date || m.exam_date || "";
  const md = modal(`<h3>${icon("flag", 18)} Lernziel: ${esc(m.name)}</h3>
    <p class="muted small">Wie viele Stunden willst du bis zur Klausur selbst lernen? Pflichtveranstaltungen zählen nur mit, wenn du es unten einschaltest.</p>
    <div class="grid cols-2">${field("Ziel in Stunden (z. B. 200)", `<input class="input" id="gdT" inputmode="decimal" value="${G.numText(m.target_minutes != null ? m.target_minutes / 60 : null)}" placeholder="200">`)}
      ${field("Schon gelernt (Stunden)", `<input class="input" id="gdB" inputmode="decimal" value="${G.numText(m.learned_before_minutes != null ? m.learned_before_minutes / 60 : null)}" placeholder="0">`)}
      ${field("Klausurtermin", `<input class="input" type="date" id="gdE" value="${esc(exam)}">`)}
      ${field("Zweittermin (falls bekannt)", `<input class="input" type="date" id="gdE2" value="${esc(m.exam_date_2 || "")}">`)}
      ${field("Ich schreibe", `<select class="input" id="gdA"><option value="1" ${(m.exam_attempt || 1) === 1 ? "selected" : ""}>Ersttermin</option><option value="2" ${m.exam_attempt === 2 ? "selected" : ""}>Zweittermin</option></select>`)}
      ${field("Priorität", `<select class="input" id="gdP">${[[1, "niedrig"], [2, "normal"], [3, "hoch"]].map(([v, l]) => `<option value="${v}" ${(m.priority || 2) === v ? "selected" : ""}>${l}</option>`).join("")}</select>`)}</div>
    <div id="gdCand"></div>
    <label class="field row"><input type="checkbox" id="gdL" ${m.include_lectures ? "checked" : ""}> Pflichtveranstaltungen (Vorlesungen, Übungen laut Stundenplan) zählen zum Ziel</label>
    <label class="field row"><input type="checkbox" id="gdW" ${m.writing === false ? "" : "checked"}> Ich schreibe diese Klausur in diesem Semester</label>
    ${m.exam_source === "automatisch" ? `<p class="small" style="color:var(--warn-text)">Der Klausurtermin wurde automatisch erkannt. Prüfe ihn und klicke in der Übersicht auf „Bestätigen“.</p>` : ""}
    <div class="modal-foot">${hasGoal ? `<button class="btn danger" id="gdDel" title="Lernziel entfernen">${icon("trash", 15)}</button>` : ""}<span class="spacer"></span><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="gdOk">Speichern</button></div>`, { wide: true });
  // gefundene Termine (Stud.IP, QIS-Anmeldung, Kalender, Dokumente) zum Uebernehmen
  api(`/exams/upcoming?module_id=${mid}`).then(r => {
    const items = (r.items || []).filter(x => x.module_id === mid).slice(0, 6);
    if (!items.length || !md.isConnected) return;
    $("#gdCand", md).innerHTML = field("Gefundene Termine (anklicken zum Übernehmen)", `<div class="row wrap">${items.map(c => `<button type="button" class="chip" data-cand="${esc(c.date)}">${esc(fmtShort(c.date))} · ${esc(c.source_label || "erkannt")}</button>`).join("")}</div>`);
    $$("[data-cand]", md).forEach(c => c.onclick = () => { $("#gdE", md).value = c.dataset.cand; $$("[data-cand]", md).forEach(x => x.classList.toggle("on", x === c)); });
  }).catch(() => {});
  $("#gdDel", md)?.addEventListener("click", async () => {
    if (!confirm(`Lernziel für „${m.name}“ entfernen? Künftige automatische Lernblöcke fallen weg.`)) return;
    if (await send(`/goals/${mid}`, "DELETE", undefined, "Lernziel entfernt")) md.remove();
  });
  $("#gdOk", md).onclick = async () => {
    const hours = G.parseNum($("#gdT", md).value);
    if (hours === null || hours < 0) return toast("Ziel bitte als Zahl in Stunden eintragen.");
    const second = $("#gdE2", md).value;
    const body = { target_hours: hours, include_lectures: $("#gdL", md).checked, writing: $("#gdW", md).checked, priority: +$("#gdP", md).value,
                   exam_date_2: second || null, exam_attempt: +$("#gdA", md).value };
    const before = G.parseNum($("#gdB", md).value);
    if (before !== null) body.learned_before_hours = before;
    const newExam = $("#gdE", md).value;
    $("#gdOk", md).disabled = true;
    try {
      if (newExam !== exam) await api(`/modules/${mid}`, { method: "PATCH", body: { exam_date: newExam } });
      await api(`/goals/${mid}`, { method: "PUT", body });
      md.remove(); toast("Lernziel gespeichert"); state.route();
    } catch (e) { toast(e.message || "Fehler", 5000); $("#gdOk", md).disabled = false; }
  };
}

/** Zeitrahmen: Schlaf, Freizeit, Nutzungsquote, Blocklaengen, Wochengrenze, Arbeit und feste Verpflichtungen */
export async function settingsDialog() {
  let s;
  try { s = await api("/goals/settings"); } catch (e) { return toast(e.message || "Fehler", 5000); }
  let items = (s.commitments || []).map(c => ({ weekday: c.weekday ?? 0, start: mh(c.start ?? 960), end: mh(c.end ?? 1200), kind: c.kind || "verpflichtung", title: c.title || "" }));
  const num = (id, label, v) => field(label, `<input class="input" type="number" id="${id}" value="${esc(v ?? "")}" min="0">`);
  const md = modal(`<h3>${icon("clock", 18)} Zeitrahmen fürs Lernen</h3>
    <p class="muted small">Geplant wird nur in echter freier Zeit: ohne Schlaf, Freizeit, Vorlesungen samt Fahrtzeit, Sperrzeiten, Arbeit und Verpflichtungen. Von der freien Zeit nutzt StudiNow höchstens die Nutzungsquote.</p>
    <div class="grid cols-2">${field("Schlaf pro Nacht (Stunden)", `<input class="input" id="gsSleep" inputmode="decimal" value="${G.numText(s.sleep_hours)}">`)}
      ${field("Schlafenszeit", `<input class="input" type="time" id="gsBed" value="${esc(s.bedtime_hm || "23:00")}">`)}
      ${num("gsLeisure", "Freizeit pro Tag (Minuten, abends)", s.leisure_minutes)}${num("gsQuota", "Nutzungsquote der freien Zeit (%)", s.utilization)}
      ${num("gsMin", "Kürzester Lernblock (Minuten)", s.min_block)}${num("gsMax", "Längster Lernblock (Minuten)", s.max_block)}
      ${num("gsBreak", "Pause zwischen Blöcken (Minuten)", s.break)}
      ${field("Höchstens pro Woche (Stunden, leer = ohne)", `<input class="input" id="gsWeek" inputmode="decimal" value="${(s.max_week_minutes || 0) > 0 ? G.numText(s.max_week_minutes / 60) : ""}">`)}</div>
    ${field("Arbeit und feste Verpflichtungen", `<div id="gsItems" class="stack"></div><button type="button" class="btn sm" id="gsAdd">${icon("plus", 14)} Eintrag</button>`)}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="gsOk">Speichern</button></div>`, { wide: true });
  const render = () => {
    $("#gsItems", md).innerHTML = items.map((c, i) => `<div class="row wrap"><select class="input" data-ck="weekday" data-i="${i}" style="width:auto">${DAYS.map((d, k) => `<option value="${k}" ${c.weekday === k ? "selected" : ""}>${d}</option>`).join("")}</select>
      <input class="input" type="time" data-ck="start" data-i="${i}" value="${c.start}" style="width:auto"><input class="input" type="time" data-ck="end" data-i="${i}" value="${c.end}" style="width:auto">
      <select class="input" data-ck="kind" data-i="${i}" style="width:auto"><option value="arbeit" ${c.kind === "arbeit" ? "selected" : ""}>Arbeit</option><option value="verpflichtung" ${c.kind !== "arbeit" ? "selected" : ""}>Verpflichtung</option></select>
      <input class="input" data-ck="title" data-i="${i}" value="${esc(c.title)}" placeholder="Bezeichnung" style="flex:1;min-width:8rem"><button type="button" class="btn ghost icon sm" data-cdel="${i}" aria-label="Entfernen">${icon("x", 14)}</button></div>`).join("") || `<span class="small muted">Keine.</span>`;
    $$("[data-ck]", md).forEach(el => el.onchange = () => { items[+el.dataset.i][el.dataset.ck] = el.dataset.ck === "weekday" ? +el.value : el.value; });
    $$("[data-cdel]", md).forEach(b => b.onclick = () => { items.splice(+b.dataset.cdel, 1); render(); });
  };
  render();
  $("#gsAdd", md).onclick = () => { items.push({ weekday: 0, start: "16:00", end: "20:00", kind: "arbeit", title: "" }); render(); };
  $("#gsOk", md).onclick = async () => {
    const sleep = G.parseNum($("#gsSleep", md).value);
    if (sleep === null) return toast("Schlaf bitte als Zahl in Stunden.");
    const body = { sleep_hours: sleep, bedtime: $("#gsBed", md).value, leisure_minutes: +$("#gsLeisure", md).value, utilization: +$("#gsQuota", md).value,
                   min_block: +$("#gsMin", md).value, max_block: +$("#gsMax", md).value, break: +$("#gsBreak", md).value,
                   max_week_minutes: Math.round((G.parseNum($("#gsWeek", md).value) || 0) * 60), commitments: items };
    if (await send("/goals/settings", "PUT", body, "Zeitrahmen gespeichert")) md.remove();
  };
}

/** Lernzeit nachtragen: Dauer an einem Tag oder von–bis (Ueberschneidung mit der Stoppuhr zaehlt nur einmal) */
export function entryDialog(mods, moduleId) {
  if (!mods.length) return;
  const md = modal(`<h3>${icon("clock", 18)} Lernzeit eintragen</h3><p class="muted small">Mit Uhrzeit zählt eine Überschneidung mit der Stoppuhr nur einmal.</p>
    <div class="grid cols-2">${field("Modul", `<select class="input" id="seMod">${mods.map(m => `<option value="${m.module_id}" ${m.module_id === moduleId ? "selected" : ""}>${esc(m.name)}</option>`).join("")}</select>`)}
      ${field("Tag", `<input class="input" type="date" id="seDay" value="${todayISO()}">`)}
      <div id="seDur">${field("Dauer (Minuten)", `<input class="input" type="number" id="seMin" value="60" min="1">`)}</div>
      <div id="seTimes" class="row" hidden>${field("Von", `<input class="input" type="time" id="seFrom" value="14:00">`)}${field("Bis", `<input class="input" type="time" id="seTo" value="15:30">`)}</div></div>
    <label class="field row"><input type="checkbox" id="seWith"> Mit Uhrzeit eintragen</label>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="seOk">Speichern</button></div>`);
  $("#seWith", md).onchange = e => { $("#seDur", md).hidden = e.target.checked; $("#seTimes", md).hidden = !e.target.checked; };
  $("#seOk", md).onclick = async () => {
    const body = { module_id: +$("#seMod", md).value, uuid: crypto.randomUUID() };
    const day = $("#seDay", md).value;
    if ($("#seWith", md).checked) {
      const a = G.berlinEpoch(day, $("#seFrom", md).value), b = G.berlinEpoch(day, $("#seTo", md).value);
      if (a === null || b === null) return toast("Uhrzeit prüfen.");
      Object.assign(body, { start: a, end: b });
    } else Object.assign(body, { minutes: +$("#seMin", md).value, day });
    if (await send("/sessions", "POST", body, "Lernzeit gespeichert")) md.remove();
  };
}

/** Ein abgehakter Lernblock zaehlt nur mit der wirklich gelernten Zeit */
export function blockDoneDialog(p, after) {
  const planned = p.start_time && p.end_time ? Math.max(0, toMin(p.end_time) - toMin(p.start_time)) : 0;
  const md = modal(`<h3>${icon("check", 18)} Wie lange hast du gelernt?</h3>
    <p><b>${esc(p.subject || "Lernblock")} · ${esc(fmtShort(p.date))} · ${esc(p.start_time || "")}–${esc(p.end_time || "")}</b></p>
    <p class="muted small">Nur die Zeit, die du wirklich gelernt hast, zählt für dein Ziel.</p>
    ${field("Gelernt (Minuten)", `<input class="input" type="number" id="bdMin" min="0" value="${planned || p.planned_minutes || 60}">`)}
    <div class="modal-foot"><button class="btn" id="bdNone">Nicht gelernt</button><span class="spacer"></span><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="bdOk">Speichern</button></div>`);
  const save = async minutes => {
    if (await send(`/goals/blocks/${p.id}/done`, "POST", { minutes }, minutes > 0 ? `${G.h(minutes)} gelernt ✓` : "Als nicht gelernt vermerkt")) { md.remove(); after?.(); }
  };
  $("#bdNone", md).onclick = () => save(0);
  $("#bdOk", md).onclick = () => save(Math.max(0, +$("#bdMin", md).value || 0));
}
const toMin = t => { const [a, b] = String(t).split(":").map(Number); return a * 60 + (b || 0); };

/** Teil im Lernpaket-Fenster fuer Bloecke des Stundenplaners (source='smart'): abhaken mit Zeit, Stoppuhr, sperren */
export function smartBlockHtml(p) {
  const done = p.status === "erledigt", locked = +p.locked === 1;
  return `<div class="card flat goals-block"><div class="small"><b>${icon("flag", 14)} ${esc(G.blockLabel(p))}</b></div>
    <div class="small muted">Gesperrte und von dir verschobene Blöcke verschiebt StudiNow nie von selbst.</div>
    <div class="row wrap" style="margin-top:.4rem">${done ? `<button class="btn sm" id="sbUndone">Wieder offen</button>` : (p.date || "") <= todayISO() ? `<button class="btn sm primary" id="sbDone">${icon("check", 13)} Abhaken mit Zeit</button>` : ""}
      <button class="btn sm" id="sbTimer">${icon("play", 13)} Stoppuhr</button><button class="btn sm" id="sbLock">${icon("flag", 13)} ${locked ? "Entsperren" : "Sperren"}</button></div></div>`;
}

export function bindSmartBlock(host, p, refresh) {
  $("#sbDone", host)?.addEventListener("click", () => blockDoneDialog(p, refresh));
  $("#sbUndone", host)?.addEventListener("click", async () => { if (await send(`/goals/blocks/${p.id}/undone`, "POST", undefined, "Wieder offen")) refresh?.(); });
  $("#sbTimer", host)?.addEventListener("click", () => send("/sessions/start", "POST", { module_id: p.module_id, package_id: p.id }, "Stoppuhr läuft"));
  $("#sbLock", host)?.addEventListener("click", async () => {
    const locked = +p.locked === 1;
    if (await send(`/goals/blocks/${p.id}`, "PATCH", { locked: !locked }, locked ? "Entsperrt" : "Gesperrt: bleibt, wo er ist")) refresh?.();
  });
}

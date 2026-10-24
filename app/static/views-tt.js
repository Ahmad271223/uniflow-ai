// Stundenplan: Wochenraster, Termin-Panel mit Teilnahme, Import-Vorschau, Verfügbarkeit
import { $, $$, api, esc, icon, toast, modal, drawer, iso, parseISO, todayISO, fmtDate, fmtShort, fmtMin, addDays, mondayOf, hm, mh, DAYS, DAYS_LONG, KIND_TXT, shortName, state } from "./core.js?v=25";
import { useFreeWindow, openPackage } from "./views-plan.js?v=25";

let ttDate = todayISO();
export async function viewTimetable(_, params, view) {
  if (params.date) ttDate = params.date;
  const start = mondayOf(parseISO(ttDate)); const w = await api(`/timetable/week?start=${iso(start)}`); const conflicts = await api("/timetable/conflicts").catch(() => []);
  const allEv = w.days.flatMap(d => d.events); const lo = Math.min(hm(w.learn_start), 8 * 60, ...allEv.map(e => hm(e.start))) - 60, hi = Math.max(hm(w.learn_end), 18 * 60, ...allEv.map(e => hm(e.end))) + 60; const H = 56; const px = m => (m - lo) / 60 * H;
  const hasEvents = allEv.length > 0;
  view.innerHTML = `<div class="content wide" style="max-width:1600px;margin:0 auto;padding:1.2rem 1.4rem">
    <div class="page-head"><div><h1>Stundenplan</h1><div class="sub">${esc(w.term.name)} · ${fmtDate(w.term.start)} – ${fmtDate(w.term.end)} · Lernzeit ${w.learn_start}–${w.learn_end}</div></div>
      <div class="actions"><button class="btn sm" id="ttAvail">${icon("clock", 14)} Verfügbarkeit</button><button class="btn sm" id="ttAdd">${icon("plus", 14)} Termin</button><button class="btn primary sm" id="ttImport">${icon("download", 14)} Stundenplan importieren</button></div></div>
    ${conflicts.length ? `<div class="card" style="border-color:var(--warn);background:var(--warn-soft);margin-bottom:.8rem"><div class="row wrap"><b>${icon("alert", 16)} ${conflicts.length} Lernslot${conflicts.length > 1 ? "s überschneiden" : " überschneidet"} sich mit Hochschulterminen</b><span class="spacer"></span><button class="btn sm primary" id="ttReslot">Lernslots neu legen</button></div><div class="small muted" style="margin-top:.3rem">${conflicts.slice(0, 4).map(c => `${fmtShort(c.date)}: ${esc(shortName(c.subject))} ${c.slot} ↔ ${esc(c.event)} ${c.event_time}`).join(" · ")}</div></div>` : ""}
    <div class="row wrap" style="margin-bottom:.7rem"><button class="btn icon sm" id="ttPrev">${icon("chevron-left", 16)}</button><b style="min-width:220px;text-align:center">${fmtDate(start, { day: "numeric", month: "long" })} – ${fmtDate(addDays(start, 6), { day: "numeric", month: "long", year: "numeric" })}</b><button class="btn icon sm" id="ttNext">${icon("chevron-right", 16)}</button><button class="btn sm ghost" id="ttToday">Heute</button><span class="spacer"></span>
      <div class="tt-legend"><span><i style="background:var(--accent)"></i> Vorlesung/Übung</span><span><i style="background:var(--surface);border:1px solid var(--accent)"></i> Lernslot</span><span><i style="background:repeating-linear-gradient(135deg,transparent 0 3px,var(--ok) 3px 4px)"></i> Frei</span><span><i style="background:repeating-linear-gradient(45deg,transparent 0 3px,#999 3px 4px)"></i> Sperrzeit</span></div></div>
    ${hasEvents ? "" : `<div class="card" style="margin-bottom:.8rem"><b>Noch kein Stundenplan.</b> <span class="muted">Deine Stud.IP-Kurse haben bereits Termine. Mit „Stundenplan importieren → aus Stud.IP“ übernimmst du sie in einer Vorschau, wählst deine Übungsgruppen und bestätigst.</span></div>`}
    <div class="tt-wrap"><div class="tt-grid"><div class="tt-head"></div>${w.days.map(d => `<div class="tt-head ${d.date === todayISO() ? "today" : ""}">${DAYS_LONG[d.weekday]}<span class="d">${fmtDate(d.date, { day: "2-digit", month: "2-digit" })}</span></div>`).join("")}
      <div class="tt-axis" style="height:${px(hi)}px">${Array.from({ length: Math.floor((hi - lo) / 60) + 1 }, (_, i) => `<span style="top:${px(lo + i * 60)}px">${mh(lo + i * 60)}</span>`).join("")}</div>
      ${w.days.map(d => `<div class="tt-col ${d.date === todayISO() ? "today" : ""}" style="height:${px(hi)}px;--hour:${H}px" data-date="${d.date}">
        ${d.free.map(f => `<div class="tt-free" style="top:${px(f.start)}px;height:${px(f.end) - px(f.start)}px" title="Frei ${f.start_hm}–${f.end_hm} (${fmtMin(f.minutes)})"></div>`).join("")}
        ${d.blocked.map(b => `<div class="tt-blocked" style="top:${px(hm(b.start))}px;height:${px(hm(b.end)) - px(hm(b.start))}px">${esc(b.title || "Sperrzeit")}</div>`).join("")}
        ${d.events.map(e => `<div class="tt-ev ${e.status}" style="--ec:${e.color};top:${px(hm(e.start))}px;height:${Math.max(24, px(hm(e.end)) - px(hm(e.start)) - 2)}px" data-ev="${e.event_id}" data-date="${d.date}" title="${esc(e.title)}"><b>${esc(shortName(e.title))}</b><small>${e.start}–${e.end}${e.room ? " · " + esc(e.room.slice(0, 18)) : ""}</small></div>`).join("")}
        ${d.packages.filter(p => p.start_time).map(p => `<div class="tt-ev study ${p.status}" style="--pc:${p.color || "var(--accent)"};top:${px(hm(p.start_time))}px;height:${Math.max(24, px(hm(p.end_time)) - px(hm(p.start_time)) - 2)}px" data-pkg="${p.id}" title="${esc(p.subject)}: ${esc(p.title)}"><b>${esc(shortName(p.subject))}</b><small>${p.start_time}–${p.end_time} · ${esc(p.title)}</small></div>`).join("")}
      </div>`).join("")}</div></div>
    <p class="muted small" style="margin-top:.6rem">Klick auf einen Termin: Teilnahme ändern, bearbeiten, Unterlagen öffnen. Nicht besuchte Veranstaltungen geben Zeit frei, die du für Lernblöcke nutzen kannst.</p></div>`;
  $("#ttPrev").onclick = () => { location.hash = `#/timetable?date=${iso(addDays(start, -7))}`; }; $("#ttNext").onclick = () => { location.hash = `#/timetable?date=${iso(addDays(start, 7))}`; }; $("#ttToday").onclick = () => { location.hash = `#/timetable?date=${todayISO()}`; };
  $("#ttImport").onclick = () => importDialog(); $("#ttAdd").onclick = () => eventDialog(null); $("#ttAvail").onclick = () => availabilityDialog();
  $("#ttReslot")?.addEventListener("click", async () => { const r = await api("/timetable/reslot", { method: "POST", body: {} }); toast(`${r.reslotted.length} Tage neu gelegt`); state.route(); });
  $$("[data-ev]", view).forEach(el => el.onclick = () => openEvent(+el.dataset.ev, el.dataset.date));
  $$("[data-pkg]", view).forEach(el => el.onclick = () => openPackage(+el.dataset.pkg));
  $$(".tt-col", view).forEach(col => col.ondblclick = e => { const rect = col.getBoundingClientRect(); const m = Math.round((lo + (e.clientY - rect.top) / H * 60) / 15) * 15; eventDialog(null, { weekday: parseISO(col.dataset.date).getDay() === 0 ? 6 : parseISO(col.dataset.date).getDay() - 1, start_time: mh(m), end_time: mh(m + 90), date_from: col.dataset.date }); });
}

export async function openEvent(eventId, dateStr) {
  const events = await api("/timetable/events"); const e = events.find(x => x.id === eventId); if (!e) return toast("Termin nicht gefunden");
  const occ = (await api(`/timetable/day?date=${dateStr}`)).events.find(o => o.event_id === eventId) || { status: e.attend ? "teilnahme" : "nicht_teilnahme", start: e.start_time, end: e.end_time };
  const mats = await api(`/timetable/event-materials/${eventId}?date=${dateStr}`).catch(() => []);
  const st = occ.status;
  const d = drawer(`<div class="drawer-head"><span class="dot" style="background:${occ.color || "var(--accent)"}"></span><div style="flex:1"><b>${esc(e.title)}</b><div class="muted small">${KIND_TXT[e.kind] || e.kind} · ${fmtShort(dateStr)} · ${occ.start}–${occ.end}${e.room ? " · " + esc(e.room) : ""}${e.lecturer ? " · " + esc(e.lecturer) : ""}</div></div><button class="btn ghost icon" data-close>${icon("x", 18)}</button></div>
    <div class="drawer-body"><div class="card flat" style="background:var(--surface-2);border-color:transparent"><b>Teilnahme: ${{ teilnahme: "Ich nehme teil", nicht_teilnahme: e.attend ? "Heute nicht" : "Dauerhaft nicht", ausfall: "Fällt aus", verschoben: "Verschoben" }[st] || st}</b>${e.rrule !== "once" ? `<div class="muted tiny">${e.rrule === "biweekly" ? "Alle zwei Wochen" : "Wöchentlich"} · ${e.source === "studip" ? "aus Stud.IP" : e.source}</div>` : ""}
      <div class="stack" style="margin-top:.6rem">${[["today_attend", "check", "Ich nehme teil", st === "teilnahme"], ["today_skip", "x", "Ich nehme heute nicht teil", st === "nicht_teilnahme" && e.attend], ["permanent_skip", "log-out", "Ich besuche diese Veranstaltung dauerhaft nicht", !e.attend], ["cancelled", "alert", "Veranstaltung fällt aus", st === "ausfall"]].map(([k, i, l, on]) => `<button class="btn ${on ? "primary" : ""}" data-att="${k}">${icon(i, 15)} ${l}</button>`).join("")}${!e.attend ? `<button class="btn" data-att="permanent_attend">${icon("rotate", 15)} Wieder dauerhaft besuchen</button>` : ""}${occ.exception ? `<button class="btn ghost sm" data-att="reset">Ausnahme für diesen Tag zurücksetzen</button>` : ""}</div></div>
      <h3 style="margin:1rem 0 .4rem">${icon("book", 16)} Passende Unterlagen</h3>${mats.length ? mats.map(f => `<a class="doc-row ${f.status}" href="#/doc/${f.id}">${icon(f.doc_type === "uebung" ? "pencil" : "book", 16)}<span><span class="t">${esc(f.ai_title || f.name)}</span><span class="s">${esc(f.doc_type || "")}${f.est_minutes ? ` · ca. ${f.est_minutes} min` : ""}</span></span></a>`).join("") : `<div class="muted small">Keine passenden Unterlagen gefunden.</div>`}
      ${e.module_id ? `<a class="btn sm" style="margin-top:.5rem" href="#/modules/${e.module_id}">${icon("book", 14)} Modul öffnen</a>` : ""}</div>
    <div class="drawer-foot"><button class="btn sm" id="evEdit">${icon("pencil", 14)} Bearbeiten</button><button class="btn sm" id="evBlock">${icon("plus", 14)} Lernblock danach</button><span class="spacer"></span><button class="btn sm danger" id="evDel">${icon("trash", 14)}</button></div>`);
  $$("[data-att]", d).forEach(b => b.onclick = async () => {
    const mode = b.dataset.att; const r = await api("/timetable/attendance", { method: "POST", body: { event_id: eventId, date: dateStr, mode } });
    if ((mode === "today_skip" || mode === "permanent_skip" || mode === "cancelled") && r.freed_minutes >= 30) {
      const w = r.windows[0]; const m = modal(`<h3>${icon("sun", 18)} Du hast jetzt ${fmtMin(r.freed_minutes)} frei</h3><p class="muted">${mode === "permanent_skip" ? "Die Vorlesung gilt nicht als gelernt. " : ""}Möchtest du die Zeit nutzen, z. B. die Vorlesung selbstständig mit den Folien bearbeiten?</p><div class="modal-foot"><button class="btn" data-close>Frei lassen</button><button class="btn primary" id="useIt">Zeit nutzen</button></div>`);
      $("#useIt", m).onclick = () => { m.remove(); useFreeWindow(dateStr, w ? `${w.start}:${w.end}` : `${hm(occ.start)}:${hm(occ.end)}`, { materials: r.materials, module_id: e.module_id }); };
    } else toast("Teilnahme gespeichert");
    state.route(); openEvent(eventId, dateStr);
  });
  $("#evEdit", d).onclick = () => eventDialog(e, { date: dateStr });
  $("#evDel", d).onclick = async () => { if (confirm("Ganze Veranstaltungsreihe aus dem Stundenplan entfernen?")) { await api(`/timetable/events/${eventId}`, { method: "DELETE" }); state.route(); } };
  $("#evBlock", d).onclick = () => useFreeWindow(dateStr, `${hm(occ.end)}:${Math.min(hm(occ.end) + 90, 22 * 60)}`, { materials: mats, module_id: e.module_id });
}

export async function eventDialog(e, preset = {}) {
  const mods = await api("/modules");
  const v = { ...{ title: "", kind: "vorlesung", weekday: 0, start_time: "08:00", end_time: "09:30", room: "", lecturer: "", rrule: "weekly", module_id: "", date_from: "", date_to: "" }, ...(e || {}), ...preset };
  const m = modal(`<h3>${e ? "Termin bearbeiten" : "Neuer Termin"}</h3>
    <label class="field">Titel<input class="input" id="evT" value="${esc(v.title)}" placeholder="z. B. Mathematik I – Vorlesung"></label>
    <div class="row"><label class="field" style="flex:1">Art<select class="input" id="evK">${Object.entries(KIND_TXT).map(([k, l]) => `<option value="${k}" ${v.kind === k ? "selected" : ""}>${l}</option>`).join("")}</select></label><label class="field" style="flex:1">Modul<select class="input" id="evM"><option value="">– keins –</option>${mods.map(x => `<option value="${x.id}" ${v.module_id == x.id ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label></div>
    <div class="row"><label class="field" style="flex:1">Wochentag<select class="input" id="evW">${DAYS_LONG.map((d, i) => `<option value="${i}" ${v.weekday == i ? "selected" : ""}>${d}</option>`).join("")}</select></label><label class="field" style="flex:1">Beginn<input class="input" type="time" id="evS" value="${v.start_time}"></label><label class="field" style="flex:1">Ende<input class="input" type="time" id="evE" value="${v.end_time}"></label></div>
    <div class="row"><label class="field" style="flex:1">Raum<input class="input" id="evR" value="${esc(v.room || "")}"></label><label class="field" style="flex:1">Dozent/in<input class="input" id="evL" value="${esc(v.lecturer || "")}"></label></div>
    <div class="row"><label class="field" style="flex:1">Rhythmus<select class="input" id="evRR"><option value="weekly" ${v.rrule === "weekly" ? "selected" : ""}>Wöchentlich</option><option value="biweekly" ${v.rrule === "biweekly" ? "selected" : ""}>Alle zwei Wochen</option><option value="once" ${v.rrule === "once" ? "selected" : ""}>Einzeltermin</option></select></label><label class="field" style="flex:1">Von<input class="input" type="date" id="evF" value="${v.date_from || ""}"></label><label class="field" style="flex:1">Bis<input class="input" type="date" id="evTo" value="${v.date_to || ""}"></label></div>
    ${e && e.rrule !== "once" ? `<label class="field">Änderung gilt für<select class="input" id="evScope"><option value="single">Nur diesen Termin (${fmtShort(preset.date || todayISO())})</option><option value="future">Diesen und alle zukünftigen Termine</option><option value="series" selected>Die gesamte Veranstaltungsreihe</option></select></label>` : ""}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="evOk">Speichern</button></div>`);
  $("#evOk", m).onclick = async () => {
    const body = { title: $("#evT", m).value, kind: $("#evK", m).value, module_id: $("#evM", m).value ? +$("#evM", m).value : null, weekday: +$("#evW", m).value, start_time: $("#evS", m).value, end_time: $("#evE", m).value, room: $("#evR", m).value, lecturer: $("#evL", m).value, rrule: $("#evRR", m).value, date_from: $("#evF", m).value || null, date_to: $("#evTo", m).value || null };
    if (e) { const scope = $("#evScope", m)?.value || "series"; await api(`/timetable/events/${e.id}`, { method: "PATCH", body: { ...body, scope, date: preset.date || todayISO() } }); } else await api("/timetable/events", { method: "POST", body });
    m.remove(); toast("Gespeichert"); state.route();
  };
}

export async function availabilityDialog() {
  const s = await api("/settings");
  const m = modal(`<h3>${icon("clock", 18)} Persönliche Verfügbarkeit</h3><p class="muted small">Freie Kalenderzeit ist nicht automatisch Lernzeit: Fahrtzeiten, Sperrzeiten und Mindestlänge werden abgezogen.</p>
    <div class="grid cols-2"><label class="field">Früheste Lernzeit<input class="input" type="time" id="avS" value="${s.learn_start}"></label><label class="field">Späteste Lernzeit<input class="input" type="time" id="avE" value="${s.learn_end}"></label>
    <label class="field">Fahrtzeit Zuhause ↔ Uni (Minuten)<input class="input" type="number" id="avT" value="${s.travel_minutes}" step="5"></label><label class="field">Mindestdauer eines Lernslots (Minuten)<input class="input" type="number" id="avM" value="${s.min_slot_minutes}" step="5"></label>
    <label class="field">Pause zwischen Aufgaben (Minuten)<input class="input" type="number" id="avB" value="${s.break_minutes}" step="5"></label><label class="field">Maximale Lernzeit pro Tag (Minuten)<input class="input" type="number" id="avD" value="${s.minutes_per_day}" step="15"></label></div>
    <label class="field">Lernfreie Wochentage<div class="row wrap" id="avDays">${DAYS.map((d, i) => `<button type="button" class="chip ${s.free_days.includes(i) ? "on" : ""}" data-d="${i}">${d}</button>`).join("")}</div></label>
    <label class="field">Sperrzeiten (z. B. Job, Sport, Mittag)<div id="avBlocked" class="stack"></div><button class="btn sm" id="avAddB">${icon("plus", 14)} Sperrzeit</button></label>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="avOk">Speichern</button></div>`);
  let blocked = [...(s.blocked_times || [])];
  const renderB = () => { $("#avBlocked", m).innerHTML = blocked.map((b, i) => `<div class="row"><select class="input" data-bk="weekday" data-i="${i}" style="width:auto">${DAYS.map((d, k) => `<option value="${k}" ${b.weekday == k ? "selected" : ""}>${d}</option>`).join("")}</select><input class="input" type="time" data-bk="start" data-i="${i}" value="${b.start}" style="width:auto"><input class="input" type="time" data-bk="end" data-i="${i}" value="${b.end}" style="width:auto"><input class="input" data-bk="title" data-i="${i}" value="${esc(b.title || "")}" placeholder="Bezeichnung"><button class="btn ghost icon sm" data-bdel="${i}">${icon("x", 14)}</button></div>`).join("") || `<span class="muted small">Keine Sperrzeiten.</span>`; $$("[data-bk]", m).forEach(el => el.onchange = () => { blocked[+el.dataset.i][el.dataset.bk] = el.dataset.bk === "weekday" ? +el.value : el.value; }); $$("[data-bdel]", m).forEach(b => b.onclick = () => { blocked.splice(+b.dataset.bdel, 1); renderB(); }); };
  renderB(); $("#avAddB", m).onclick = () => { blocked.push({ weekday: 0, start: "12:00", end: "13:00", title: "" }); renderB(); };
  $$("#avDays .chip", m).forEach(c => c.onclick = () => c.classList.toggle("on"));
  $("#avOk", m).onclick = async () => { await api("/settings", { method: "PUT", body: { learn_start: $("#avS", m).value, learn_end: $("#avE", m).value, travel_minutes: $("#avT", m).value, min_slot_minutes: $("#avM", m).value, break_minutes: $("#avB", m).value, hours_per_day: (+$("#avD", m).value / 60).toFixed(2), free_days: $$("#avDays .chip.on", m).map(c => +c.dataset.d), blocked_times: blocked } }); m.remove(); toast("Verfügbarkeit gespeichert"); state.route(); };
}

export async function importDialog() {
  const m = modal(`<h3>${icon("download", 18)} Stundenplan importieren</h3><p class="muted small">Du siehst zuerst eine bearbeitbare Vorschau. Erst nach Bestätigung werden die Termine übernommen.</p>
    <div class="stack"><button class="btn primary" data-src="studip">${icon("sync", 16)} Aus Stud.IP übernehmen (Termine deiner Kurse)</button><button class="btn" data-src="ics">${icon("calendar", 16)} Kalenderdatei (ICS)</button><button class="btn" data-src="pdf">${icon("file-text", 16)} PDF-Stundenplan (Texterkennung + KI)</button><button class="btn" data-src="image">${icon("image", 16)} Screenshot / Foto (KI-Bildanalyse)</button><button class="btn" data-src="text">${icon("type", 16)} Text einfügen (KI)</button><button class="btn" data-src="manual">${icon("plus", 16)} Manuell eingeben</button></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button></div>`);
  $$("[data-src]", m).forEach(b => b.onclick = async () => {
    const src = b.dataset.src; m.remove();
    if (src === "manual") return eventDialog(null);
    const fd = new FormData(); fd.append("source", src);
    if (src === "text") { const t = modal(`<h3>Stundenplan als Text</h3><textarea class="input" id="impT" rows="10" placeholder="Montag 08:00-09:30 Mathematik I Vorlesung Hörsaal A&#10;Dienstag 10:00-11:30 Programmieren I ..."></textarea><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="impOk">Analysieren</button></div>`); $("#impOk", t).onclick = () => { fd.append("text", $("#impT", t).value); t.remove(); runImport(fd, src); }; return; }
    if (src === "studip") return runImport(fd, src);
    const inp = document.createElement("input"); inp.type = "file"; inp.accept = src === "ics" ? ".ics,text/calendar" : src === "pdf" ? "application/pdf" : "image/*"; inp.onchange = () => { fd.append("upload", inp.files[0]); runImport(fd, src); }; inp.click();
  });
}
async function runImport(fd, src) {
  const wait = modal(`<h3>Import läuft…</h3><p class="muted">${src === "studip" ? "Termine werden zusammengefasst." : "Die KI liest den Stundenplan. Das dauert etwa eine halbe Minute."}</p>`);
  let r; try { r = await api("/timetable/import/preview", { method: "POST", body: fd }); } catch (e) { wait.remove(); return toast("Import fehlgeschlagen: " + e.message, 6000); }
  wait.remove(); previewDialog(r, src);
}
function previewDialog(r, src) {
  const entries = r.entries.map((e, i) => ({ ...e, _i: i, selected: e.selected !== false })); const mods = r.modules; const removed = r.diff.removed || [];
  const m = modal(`<h3>Importvorschau · ${entries.length} Veranstaltungen</h3><p class="muted small">${r.diff.new.length} neu · ${r.diff.changed.length} geändert · ${r.diff.same.length} unverändert${removed.length ? ` · ${removed.length} nicht mehr enthalten` : ""}. ${entries.some(e => e.uncertain) ? "Orange markierte Zeilen sind unsicher (z. B. mehrere parallele Übungsgruppen): bitte prüfen und nur deine Gruppe auswählen." : ""}</p>
    <div style="max-height:55vh;overflow:auto"><table class="imp-table"><tr><th></th><th>Veranstaltung</th><th>Art</th><th>Tag</th><th>Von</th><th>Bis</th><th>Raum</th><th>Modul</th></tr>${entries.map(e => `<tr class="${e.uncertain ? "unc" : ""} ${e.selected ? "" : "off"}" data-i="${e._i}"><td><input type="checkbox" data-f="selected" ${e.selected ? "checked" : ""}></td><td><input data-f="title" value="${esc(e.title)}" style="width:190px">${e.hint ? `<div class="muted tiny">${esc(e.hint)}</div>` : ""}${e.existing_id ? `<div class="muted tiny">vorhanden${e.old_start ? ` (bisher ${e.old_start}–${e.old_end})` : ""}</div>` : ""}</td><td><select data-f="kind">${Object.entries(KIND_TXT).map(([k, l]) => `<option value="${k}" ${e.kind === k ? "selected" : ""}>${l}</option>`).join("")}</select></td><td><select data-f="weekday">${DAYS.map((d, k) => `<option value="${k}" ${e.weekday == k ? "selected" : ""}>${d}</option>`).join("")}</select></td><td><input type="time" data-f="start_time" value="${e.start_time}"></td><td><input type="time" data-f="end_time" value="${e.end_time}"></td><td><input data-f="room" value="${esc(e.room || "")}" style="width:90px"></td><td><select data-f="module_id"><option value="">–</option>${mods.map(x => `<option value="${x.id}" ${e.module_id == x.id ? "selected" : ""}>${esc(shortName(x.name))}</option>`).join("")}</select></td></tr>`).join("")}</table></div>
    ${removed.length ? `<div class="card flat" style="margin-top:.6rem"><b>Nicht mehr im neuen Plan:</b> ${removed.map(x => `<label class="chip"><input type="checkbox" data-rm="${x.id}"> ${esc(x.title)} (${DAYS[x.weekday]} ${x.start_time})</label>`).join(" ")}<div class="muted tiny">Angehakte werden entfernt.</div></div>` : ""}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="impConfirm">Übernehmen</button></div>`, { wide: true });
  $$("tr[data-i] [data-f]", m).forEach(el => el.onchange = () => { const e = entries[+el.closest("tr").dataset.i]; const f = el.dataset.f; e[f] = el.type === "checkbox" ? el.checked : (f === "weekday" ? +el.value : f === "module_id" ? (el.value ? +el.value : null) : el.value); el.closest("tr").classList.toggle("off", !e.selected); });
  $("#impConfirm", m).onclick = async () => {
    const chosen = entries.filter(e => e.selected); if (!chosen.length) return toast("Nichts ausgewählt");
    const diff = r.diff; const withIds = chosen.map(e => { const ch = diff.changed.find(c => c._i === undefined && c.title === e.title && c.weekday === e.weekday) || diff.same.find(c => c.title === e.title && c.weekday === e.weekday); return { ...e, existing_id: ch?.existing_id }; });
    const res = await api("/timetable/import/confirm", { method: "POST", body: { entries: withIds, source: src, import_id: r.import_id, remove_ids: $$("[data-rm]:checked", m).map(c => +c.dataset.rm) } });
    m.remove(); toast(`${res.new} neu, ${res.updated} aktualisiert${res.removed ? `, ${res.removed} entfernt` : ""}`);
    if (res.conflicts?.length) { const c = modal(`<h3>${icon("alert", 18)} ${res.conflicts.length} Lernslots kollidieren jetzt mit Terminen</h3><ul class="small">${res.conflicts.slice(0, 8).map(x => `<li>${fmtShort(x.date)}: ${esc(shortName(x.subject))} ${x.slot} ↔ ${esc(x.event)} ${x.event_time}</li>`).join("")}</ul><div class="modal-foot"><button class="btn" data-close>Später</button><button class="btn primary" id="cfOk">Lernslots neu legen</button></div>`); $("#cfOk", c).onclick = async () => { await api("/timetable/reslot", { method: "POST", body: {} }); c.remove(); state.route(); }; }
    state.route();
  };
}

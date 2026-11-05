// Module (Vorlage), Tests & Wiederholung, Einstellungen (Module & Wochentests), Uni & Noten, Community
import { renderWeeklyBox } from "./views-weekly.js?v=14";
import { installCard, bindInstallBanner } from "./pwa.js?v=15";
import { staggerOnce, countUp, reveal } from "./motion.js?v=2";
import { $, $$, api, can, esc, icon, toast, modal, drawer, showError, fmtDate, fmtShort, fmtMin, diffBadge, typeBadge, initial, shortName, TYPE_TXT, TYPE_ICON, KIND_TXT, DAYS, PALETTE, state } from "./core.js?v=43";
import * as FC from "./flashcards.js?v=7";
// KI-Karteikarten auf Auftrag (Pro AI, 04.11.2026): Dialog in flashcard-stacks-ui.js
import { openAiDialog, lockIcon } from "./flashcard-stacks-ui.js?v=3";
import { mountBulletin } from "./bulletin.js?v=5";
import { mountStudipTexts } from "./studip-texts.js?v=5";
import { settingHtml } from "./older-semesters.js?v=2";
import { bindSetting as bindOlderSetting } from "./older-semesters-ui.js?v=4";
// Lernstand je Modul (docs/LERNSTAND-2026-11-04.md): Ring, Zahl und Begruendung aus dem Feld `mastery`
import { masteryHtml, masteryTile } from "./mastery.js?v=2";
// Testergebnis wie auf dem iPad: Ring, Einordnung und "Frag die KI zu Aufgabe n" (test-result.js)
import * as TR from "./test-result.js?v=1";

// ================================================================ MODULE
const DECO = [[/mathe/i, "grid"], [/elektro/i, "sparkles"], [/signal/i, "rotate"], [/programm/i, "type"], [/datenstruktur|algorithm/i, "layers"], [/einf/i, "columns"], [/digital/i, "cards"]];
const deco = name => (DECO.find(([re]) => re.test(name)) || [null, "book"])[1];
let modMode = "cards"; try { modMode = localStorage.getItem("mod-mode") || "cards"; } catch {}
export function modCard(m) {
  const nx = m.next_event; const desc = (m.topics || []).length ? m.topics.join(", ") : `Vorlesung, Übungen und Material – ${m.courses} Veranstaltung${m.courses === 1 ? "" : "en"} aus Stud.IP.`;
  const nxt = nx ? `<div class="next">${icon("calendar", 20)}<div class="m"><small>Nächster Termin</small><b>${esc(shortName(nx.title))}</b><span>${fmtShort(nx.date)} · ${nx.start} – ${nx.end}${nx.room ? ` · ${esc(nx.room.split(":")[0])}` : ""}</span></div>${icon("chevron-right", 16)}</div>`
    : m.next_package ? `<div class="next">${icon("book", 20)}<div class="m"><small>Nächster Lernblock</small><b>${esc(m.next_package.title)}</b><span>${fmtShort(m.next_package.date)}</span></div>${icon("chevron-right", 16)}</div>` : `<div class="next">${icon("calendar", 20)}<div class="m"><small>Nächster Termin</small><b class="muted">Kein Termin in den nächsten 14 Tagen</b></div></div>`;
  return `<a class="mod2" style="--mc:${m.color}" href="#/modules/${m.id}"><span class="deco">${icon(deco(m.name), 44)}</span>
    <div class="hd"><div class="ini">${initial(m.name)}</div><div class="nm">${esc(m.name)}</div></div>
    <div class="desc">${esc(desc)}</div>
    <div class="pr"><span><strong>${m.progress}%</strong> bearbeitet</span>${m.new_count ? `<b>${m.new_count} neue Inhalte</b>` : `<span class="muted">${m.exam_date ? "Klausur " + fmtDate(m.exam_date) : "aktuell"}</span>`}</div><div class="progress"><i style="width:${m.progress}%"></i></div>
    <div class="mod2-mastery">${masteryTile(m.mastery)}</div>
    ${nxt}
    <div class="stats"><div>${icon("file-text", 18)}<span><b>${m.file_count}</b>Dateien</span></div><div>${icon("tasks", 18)}<span><b>${m.task_count ?? m.open_tasks}</b>Aufgaben</span></div><div>${icon("exam", 18)}<span><b>${m.test_count ?? 0}</b>Wochentest${m.test_count === 1 ? "" : "s"}</span></div></div></a>`;
}
export async function viewModules(parts, _, view) {
  if (parts[0]) return viewModule(+parts[0], view);
  const mods = await api("/modules");
  view.innerHTML = `<div class="content" style="max-width:1480px"><div class="page-head"><div><h1>Meine Module</h1><div class="sub">Alle Module deines Studiums – Vorlesungen, Übungen, Materialien und Tests an einem Ort.</div></div>
      <div class="actions"><div class="seg pill"><button class="${modMode === "cards" ? "active" : ""}" data-mm="cards">Karten</button><button class="${modMode === "list" ? "active" : ""}" data-mm="list">Liste</button></div><a class="btn" href="#/settings?tab=modules">${icon("settings", 15)} Module & Wochentests</a></div></div>
    ${mods.length ? (modMode === "cards" ? `<div class="mod2-grid">${mods.map(modCard).join("")}</div>` : `<div class="card pad-0 lib-list mod2-list">${mods.map(m => `<a class="lib-row" href="#/modules/${m.id}" style="color:inherit"><div class="mini folder" style="--fc:${m.color}">${initial(m.name)}</div><div><b>${esc(m.name)}</b><div class="muted tiny">${esc((m.topics || []).join(", ")) || `${m.courses} Veranstaltungen`}</div></div><span class="small">${m.progress}% bearbeitet<br>${masteryHtml(m.mastery, "sm")}</span><span class="small muted">${m.file_count} Dateien · ${m.new_count} neu</span><span class="small muted">${m.next_event ? `${fmtShort(m.next_event.date)} ${m.next_event.start}` : "–"}</span><span>${icon("chevron-right", 16)}</span></a>`).join("")}</div>`) : `<div class="card empty">Noch keine Module. Erst synchronisieren.</div>`}</div>`;
  $$("[data-mm]", view).forEach(b => b.onclick = () => { modMode = b.dataset.mm; try { localStorage.setItem("mod-mode", modMode); } catch {} state.route(); });
  staggerOnce($(".mod2-grid", view), "modules");                          // Kacheln beim ersten Oeffnen leicht gestaffelt
}
async function viewModule(id, view) {
  const d = await api(`/modules/${id}`); const m = d.module; let tab = "overview", mode = "list";
  const curWeek = d.weeks.filter(w => w.week >= 1).slice(-1)[0];
  // `switched`: nur der Reiter wechselt – die Seite blendet nicht neu ein, nur der Reiterinhalt (transition-panel)
  const render = (switched = false) => {
    const byType = k => d.files.filter(f => (f.doc_type || "sonstiges") === k).sort((a, b) => b.chdate - a.chdate);
    const docList = fs => fs.length ? (mode === "list" ? fs.map(docRow).join("") : `<div class="doc-grid">${fs.map(docCard).join("")}</div>`) : `<div class="empty small">Nichts vorhanden.</div>`;
    const body = tab === "overview" ? `<div class="card wt-box" id="wtBox"><div class="muted small"><span class="uf-shimmer">Lade Wochentests…</span></div></div><div id="stHost"></div>` + d.weeks.map(w => `<div class="card week-block" data-w="${w.week}"><div class="wh">${icon("chevron-down", 16)}<h3>${esc(w.label)}${w.topic ? ` – ${esc(w.topic)}` : ""}</h3><span class="muted">${w.count} Dokumente</span>${w.vorlesungen.length ? `<button class="btn ghost sm ai-week" data-w="${w.week}">${icon("sparkles", 14)} Zusammenfassen</button>` : ""}</div>
        <div class="wb">${w.week >= 1 ? `<div class="ws-host" data-w="${w.week}"></div>` : ""}${["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"].filter(k => w[k].length).map(k => { const groups = {}; w[k].forEach(f => (groups[f.sub_label || { vorlesungen: "Vorlesung", uebungen: "Übung", loesungen: "Lösung", skripte: "Skript", klausuren: "Klausur", sonstiges: "Sonstiges" }[k]] ||= []).push(f)); return Object.entries(groups).map(([lab, fs]) => `<h4 style="margin:.5rem 0 .2rem">${esc(lab)}${fs.length > 1 ? ` <span class="muted" style="font-weight:400">· ${fs.length}</span>` : ""}</h4>${fs.map(docRow).join("")}`).join(""); }).join("")}</div></div>`).join("") || `<div class="card empty">Keine Dokumente.</div>`
      : tab === "notes" ? `<div class="card">${docList(d.notes)}</div>`
      : `<div class="card">${docList(byType({ lectures: "vorlesung", exercises: "uebung", solutions: "loesung", scripts: "skript", exams: "klausur" }[tab]))}</div>`;
    view.innerHTML = `<div class="content${switched ? " no-enter" : ""}">
      <div class="page-head"><div class="mod-head"><div class="color" style="background:${m.color}">${initial(m.name)}</div><div><h1>${esc(m.name)}</h1><div class="sub">${d.courses.length} Veranstaltungen: ${d.courses.map(c => KIND_TXT[c.kind] || c.kind).join(", ")}${m.exam_date ? ` · Klausur ${fmtDate(m.exam_date)}` : ""}</div></div></div>
        <div class="actions"><button class="btn sm" id="modEdit">${icon("settings", 14)} Modul</button><div class="seg"><button class="${mode === "list" ? "active" : ""}" data-mode="list">${icon("list", 15)}</button><button class="${mode === "cards" ? "active" : ""}" data-mode="cards">${icon("grid", 15)}</button></div></div></div>
      <div class="mod-ls" style="--mc:${m.color || "var(--accent)"}">${masteryTile(d.mastery, "lg")}</div>
      <div class="grid cols-3" style="margin-bottom:1rem"><div class="card kpi"><b>${d.progress}%</b><span>Lernfortschritt</span><div class="progress" style="margin-top:.4rem"><i style="width:${d.progress}%"></i></div></div><div class="card kpi"><b>${curWeek ? curWeek.label.split("·")[0].trim() : "–"}</b><span>Aktuelle Lehrwoche${curWeek?.topic ? ` · ${esc(curWeek.topic)}` : ""}</span></div><div class="card kpi"><b>${d.next_package ? fmtShort(d.next_package.date) : "–"}</b><span>${d.next_package ? esc(d.next_package.title) : "Kein Lernblock geplant"}${d.next_package ? ` · <a href="#/plan?view=day&date=${d.next_package.date}">öffnen</a>` : ""}</span></div></div>
      <div class="tabs">${[["overview", "Übersicht"], ["lectures", "Vorlesungen"], ["exercises", "Übungen"], ["solutions", "Lösungen"], ["scripts", "Skripte"], ["exams", "Klausuren"], ["notes", "Notizen"]].map(([k, t]) => `<button class="${tab === k ? "active" : ""}" data-tab="${k}">${t}</button>`).join("")}</div>
      <div class="tab-panel${switched ? " uf-panel-in" : ""}">${body}</div></div>`;
    $$("[data-tab]", view).forEach(b => b.onclick = () => { if (tab === b.dataset.tab) return; tab = b.dataset.tab; render(true); });
    countUp($(".kpi b", view), `module-${id}-progress`);                  // Lernfortschritt rollt zur neuen Zahl
    bindInstallBanner(view);
    $$("[data-mode]", view).forEach(b => b.onclick = () => { mode = b.dataset.mode; render(true); });
    // Auf- und Zuklappen wie disclosure (Hoehe und Deckkraft), der Pfeil dreht mit
    $$(".week-block .wh", view).forEach(h => h.onclick = e => { if (e.target.closest(".ai-week")) return; const wb = $(".wb", h.parentElement); const open = wb.hidden; h.parentElement.classList.toggle("closed", !open); reveal(wb, open); });
    $$(".ai-week", view).forEach(b => b.onclick = () => summarizeWeek(d.weeks.find(w => w.week === +b.dataset.w), m));
    $("#modEdit").onclick = () => editModule(m, () => viewModule(id, view));
    if ($("#wtBox", view)) renderWeeklyBox($("#wtBox", view), m);
    if ($("#stHost", view)) mountStudipTexts($("#stHost", view), id, api);   // Courseware, Wiki, Forum (Blubber) aus Stud.IP
    // Fertige Fragen je Lehrwoche (Pro AI, Bibliothek des Dienstes): week-sets.js
    if ($(".ws-host", view)) import("./week-sets.js?v=3").then(M => M.mountWeekSets($$(".ws-host", view), id, curWeek?.week)).catch(e => console.warn("Fertige Fragen", e));
  };
  render();
}
export function docRow(f) { return `<a class="doc-row ${f.status}" href="#/doc/${f.id}" title="${esc(f.name)}">${icon(TYPE_ICON[f.doc_type] || "file", 17)}<span><span class="t">${esc(f.ai_title || f.name)}</span><span class="s">${esc(f.sub_label || TYPE_TXT[f.doc_type] || "Dokument")}${f.studip_folder ? ` · ${esc(f.studip_folder.split("/").slice(-1)[0])}` : ""} · ${fmtDate(f.chdate)}${f.est_minutes ? ` · ca. ${f.est_minutes} min` : ""}${f.has_notes ? " · mit Notizen" : ""}</span></span><span class="row" style="gap:.3rem">${f.favorite ? icon("star", 14) : ""}${diffBadge(f.difficulty)}</span></a>`; }
export function docCard(f) { return `<a class="doc-card" href="#/doc/${f.id}"><div class="row between"><span class="badge neutral">${esc(TYPE_TXT[f.doc_type] || "Dokument")}</span>${diffBadge(f.difficulty)}</div><div class="t">${esc(f.ai_title || f.name)}</div><div class="muted small">${fmtDate(f.chdate)}${f.est_minutes ? ` · ${f.est_minutes} min` : ""}</div>${f.summary ? `<div class="small muted" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">${esc(f.summary)}</div>` : ""}</a>`; }
export function editModule(m, done) {
  const box = modal(`<h3>Modul bearbeiten</h3><label class="field">Name<input class="input" id="emName" value="${esc(m.name)}"></label>
    <div class="field">Farbe<div class="mod-colors" id="emColors">${PALETTE.map(c => `<button type="button" class="mod-sw" data-c="${c}" style="--sw:${c}" title="Farbe ${c}" aria-label="Farbe ${c}"></button>`).join("")}<label class="mod-sw own" title="Eigene Farbe"><input type="color" id="emColor" value="${esc(m.color || "#4f5bd5")}" aria-label="Eigene Farbe"></label></div></div>
    <div class="row"><label class="field" style="flex:1">Priorität<select class="input" id="emPrio"><option value="1" ${m.priority == 1 ? "selected" : ""}>Niedrig</option><option value="2" ${m.priority == 2 ? "selected" : ""}>Normal</option><option value="3" ${m.priority == 3 ? "selected" : ""}>Hoch</option></select></label><label class="field" style="flex:1">Klausurtermin<input class="input" type="date" id="emExam" value="${m.exam_date || ""}"></label></div>
    <div class="row"><label class="field" style="flex:1"><input type="checkbox" id="emActive" ${m.active !== 0 ? "checked" : ""}> Modul aktiv (wird eingeplant)</label><label class="field" style="flex:1"><input type="checkbox" id="emTest" ${m.weekly_test !== 0 ? "checked" : ""}> Gemeinsamer Wochentest</label><label class="field" style="flex:1">Abweichende Testdauer<select class="input" id="emTmin"><option value="">Standard</option>${[15, 30, 45, 60, 90].map(n => `<option value="${n}" ${m.test_minutes == n ? "selected" : ""}>${n} min</option>`).join("")}</select></label></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="emOk">Speichern</button></div>`);
  // Farbwahl: Palette (app/colors.py) oder eigene Farbe; gesendet wird die Farbe nur, wenn sie sich aendert (Merker color_custom)
  const was = (m.color || "").toLowerCase(); let color = was;
  const mark = () => { $$(".mod-sw[data-c]", box).forEach(b => b.classList.toggle("on", b.dataset.c === color)); const own = $(".mod-sw.own", box); own.classList.toggle("on", !!color && !PALETTE.includes(color)); own.style.setProperty("--sw", color && !PALETTE.includes(color) ? color : ""); };
  $$(".mod-sw[data-c]", box).forEach(b => b.onclick = () => { color = b.dataset.c; $("#emColor", box).value = color; mark(); });
  $("#emColor", box).oninput = e => { color = e.target.value.toLowerCase(); mark(); };
  mark();
  // Farben anderer Module blass mit Hinweis (waehlbar bleiben sie)
  api("/modules").then(list => { const used = new Map(list.filter(x => x.id !== m.id && x.color).map(x => [x.color.toLowerCase(), x.name])); $$(".mod-sw[data-c]", box).forEach(b => { const n = used.get(b.dataset.c); b.classList.toggle("used", !!n); b.title = n ? `Farbe ${b.dataset.c} – schon vergeben: ${n}` : `Farbe ${b.dataset.c}`; }); }).catch(() => {});
  $("#emOk", box).onclick = async () => { await api(`/modules/${m.id}`, { method: "PATCH", body: { name: $("#emName", box).value, ...(color && color !== was ? { color } : {}), priority: +$("#emPrio", box).value, exam_date: $("#emExam", box).value || null, active: $("#emActive", box).checked ? 1 : 0, weekly_test: $("#emTest", box).checked ? 1 : 0, test_minutes: $("#emTmin", box).value ? +$("#emTmin", box).value : null } }); box.remove(); toast("Gespeichert"); done(); };
}
async function summarizeWeek(w, m) {
  const box = modal(`<h3>${icon("sparkles", 18)} Zusammenfassung: ${esc(w.label)}</h3><div id="sumOut" class="muted"><span class="uf-shimmer">Die KI liest die Vorlesungsfolien dieser Woche…</span></div><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`);
  try { let text = ""; for (const f of w.vorlesungen.slice(0, 3)) for (let p = 1; p <= 4; p++) { const r = await api(`/files/${f.id}/pagetext?page=${p}`); if (!r.text) break; text += `\n--- ${f.name} S.${p} ---\n${r.text}`; if (text.length > 9000) break; }
    const r = await api("/ai/tutor", { method: "POST", body: { file_id: w.vorlesungen[0].id, page: 1, mode: "summary", page_text: text.slice(0, 9000), question: `Fasse die Vorlesungen der ${w.label} im Modul ${m.name} zusammen.` } });
    const { md } = await import("./editor.js?v=66"); $("#sumOut", box).innerHTML = md(r.answer); $("#sumOut", box).classList.remove("muted"); } catch (e) { $("#sumOut", box).textContent = "Fehler: " + e.message; }
}

// ================================================================ TESTS & WIEDERHOLUNG
export async function viewExams(parts, params, view) {
  if (parts[0]) return runTest(+parts[0], params, view);
  const [tests, mods, cards] = await Promise.all([api("/tests"), api("/modules"), api("/flashcards?due=true")]);
  const modByName = Object.fromEntries(mods.map(m => [m.name, m]));
  const groups = {}; tests.forEach(t => { const k = (t.module_id || t.subject) + ":" + (t.week_no ?? t.week_start); (groups[k] ||= []).push(t); });
  const cardsHtml = tests.length ? Object.values(groups).sort((a, b) => (b[0].week_start || "").localeCompare(a[0].week_start || "")).map(g => g.map(t => { const m = modByName[t.subject]; const pct = t.submitted_at ? Math.round(100 * t.score / t.max_score) : null; return `<div class="card test-card" style="--mc:${m?.color || "var(--accent)"}"><div class="row between"><div class="row"><span class="dot" style="background:${m?.color || "var(--accent)"}"></span><b>${esc(shortName(t.subject))}</b></div><div class="row test-head-r">${t.def_id ? `<span class="badge ok" title="Gemeinsamer Wochentest, Stoff bis zum Seitenmarker">${t.week_no ? "Wochentest" : "Probeklausur"}</span>` : t.auto ? `<span class="badge neutral">Wochentest</span>` : `<span class="badge info">manuell</span>`}${t.def_id && t.submitted_at ? "" : `<button class="btn ghost icon test-del" data-del="${t.id}" title="Test löschen" aria-label="Test löschen">${icon("trash", 16)}</button>`}</div></div>
      <div class="small muted" style="margin:.3rem 0">${t.week_no ? `Lehrwoche ${t.week_no}` : t.week_start ? `Woche ${fmtDate(t.week_start)}` : ""} · ${t.duration_min} min · ${t.question_count || "?"} Aufgaben</div>
      <div class="small" style="min-height:2.6em">${esc((t.title || "").replace(/^Wochentest\s+[^–-]+[–-]\s*/, "").replace(/\(.*?Minuten.*?\)/, "").trim())}</div>
      ${pct !== null ? `<div class="progress ${pct >= 60 ? "ok" : ""}" style="margin:.5rem 0 .3rem"><i style="width:${pct}%;${pct < 60 ? "background:var(--bad)" : ""}"></i></div><div class="row between small"><span>${Math.round(t.score)}/${Math.round(t.max_score)} Punkte (${pct} %)</span><a class="btn test-go" href="#/exams/${t.id}">Ansehen</a></div>` : `<div class="row between small" style="margin-top:.5rem"><span class="muted">${t.started_at ? "begonnen" : "noch nicht gestartet"}</span><a class="btn primary test-go" href="#/exams/${t.id}">${icon("play", 15)} ${t.started_at ? "Fortsetzen" : "Starten"}</a></div>`}
</div>`; }).join("")).join("") : `<div class="card empty">${icon("exam", 36)}<div>Noch keine Wochentests. Sie entstehen automatisch pro Modul und Lehrwoche, sobald neue Inhalte da sind, oder manuell unten.</div></div>`;
  view.innerHTML = `<div class="content"><div class="page-head"><div><h1>Tests & Wiederholung</h1><div class="sub">Ein gemeinsamer Wochentest pro Modul und Lehrwoche, dazu Karteikarten zum Wiederholen.</div></div>
      <div class="actions"><select class="input" id="exSubj" style="width:auto">${mods.map(s => `<option value="${s.id}">${esc(shortName(s.name))}</option>`).join("")}</select><select class="input" id="exDur" style="width:auto">${[15, 30, 45, 60, 90].map(n => `<option value="${n}" ${n === 30 ? "selected" : ""}>${n} min</option>`).join("")}</select><button class="btn sm" id="exGen">${icon("plus", 14)} Zusatztest</button><button class="btn primary sm" id="exWeek">${icon("sparkles", 14)} Wochentests erstellen</button></div></div>
    <div class="statbar"><span><b>${tests.filter(t => !t.submitted_at).length}</b> offene Tests</span><span><b>${tests.filter(t => t.submitted_at).length}</b> abgeschlossen${tests.some(t => t.submitted_at) ? ` · Ø ${Math.round(tests.filter(t => t.submitted_at).reduce((a, t) => a + 100 * t.score / t.max_score, 0) / tests.filter(t => t.submitted_at).length)} %` : ""}</span><a href="#/cards"><b>${cards.length}</b> Karteikarten fällig →</a></div>
    <div class="test-grid">${cardsHtml}</div></div>`;
  $("#exGen").onclick = async () => { try { await api("/tests/generate", { method: "POST", body: { module_id: +$("#exSubj").value, duration_min: +$("#exDur").value } }); toast("Zusatztest wird erstellt (ca. 1 Minute)…"); window.pollBg?.(); } catch (e) { toast(e.message); } };
  $("#exWeek").onclick = async () => { try { await api("/tests/generate-week", { method: "POST" }); toast("Fehlende Wochentests werden erstellt…"); window.pollBg?.(); } catch (e) { toast(e.message); } };
  // eigene Rueckfrage statt confirm(): gross genug fuer den Finger, auch in der iPad-App zuverlaessig
  $$("[data-del]", view).forEach(b => b.onclick = () => {
    const t = tests.find(x => x.id === +b.dataset.del); if (!t) return;
    const m = modal(`<h3>Test löschen?</h3><p><b>${esc(shortName(t.subject))}</b> · ${esc((t.title || "").replace(/^Wochentest\s+[^–-]+[–-]\s*/, "").trim())}</p>${t.auto ? `<p class="muted small">Dieser Wochentest wird danach nicht automatisch neu erstellt. Einen neuen Test legst du jederzeit mit „Zusatztest“ an.</p>` : ""}${t.submitted_at ? `<p class="muted small">Ergebnis und Antworten werden mit gelöscht.</p>` : ""}<div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn danger" data-yes>${icon("trash", 14)} Löschen</button></div>`);
    $("[data-yes]", m).onclick = async () => { m.remove(); try { await api(`/tests/${t.id}`, { method: "DELETE" }); toast("Test gelöscht"); state.route(); } catch (e) { toast("Löschen fehlgeschlagen: " + e.message); } };
  });
}
let timerInt = null;
async function runTest(id, params, view) {
  const t = await api(`/tests/${id}`); let cur = 0; const answers = { ...(t.answers || {}) }; const fb = t.feedback?.per_question ? Object.fromEntries(t.feedback.per_question.map(q => [String(q.nr), q])) : {};
  document.body.classList.toggle("exam-focus", !t.submitted_at);
  const render = () => {
    const q = t.questions[cur]; const f = fb[String(q.nr)]; const ans = answers[String(q.nr)] || "";
    view.innerHTML = `<div class="content" style="max-width:900px"><div class="row wrap" style="margin-bottom:1rem"><a class="btn sm" href="${params.task ? "#/plan" : "#/exams"}" id="exBack">${icon("arrow-left", 14)} ${t.submitted_at ? "Zurück" : "Abbrechen"}</a><div><b>${esc(t.title)}</b><div class="muted small">${esc(t.subject)} · ${t.duration_min} min · ${t.questions.length} Aufgaben · KI-generiert${t.week_no ? ` · Lehrwoche ${t.week_no}` : ""}</div></div><span class="spacer"></span><span class="timer" id="timer"></span></div>
      ${t.submitted_at ? (() => { const r = TR.resultSummary(t); return `<section class="card tr-head ${r.tone}" aria-label="Ergebnis"><div class="tr-top"><span class="tr-ring" style="--p:${r.pct}" role="img" aria-label="${r.pct} Prozent">${icon(r.tone === "ok" ? "check" : "refresh", 26)}</span>
        <div class="tr-num"><div><b class="tr-pct">${r.pct} %</b> <span class="muted">${r.total} / ${r.max} Punkte</span></div><div><b>${r.right}/${r.n} richtig</b>${r.redo ? `<span class="muted"> · ${r.redo} zum Nacharbeiten</span>` : ""}</div><span class="tr-status">${icon(r.tone === "ok" ? "check" : "alert", 14)} ${esc(r.status)}</span></div></div>
        ${t.feedback.summary ? `<p class="tr-sum">${esc(t.feedback.summary)}</p>` : ""}${t.feedback.weak_topics?.length ? `<div class="tr-weak"><b class="small">Nochmal anschauen:</b>${t.feedback.weak_topics.map(w => `<span class="tr-topic">${esc(w)}</span>`).join("")}</div>` : ""}</section>`; })() : ""}
      <div class="row wrap" style="gap:.3rem;margin-bottom:.8rem">${t.questions.map((qq, i) => `<button class="chip ${i === cur ? "on" : ""}" data-q="${i}" style="${fb[String(qq.nr)] ? `border-color:${fb[String(qq.nr)].points >= fb[String(qq.nr)].max * .6 ? "var(--ok)" : "var(--bad)"}` : answers[String(qq.nr)] ? "border-color:var(--accent)" : ""}">${qq.nr}</button>`).join("")}</div>
      <div class="q ${f ? (f.points >= f.max * .6 ? "good" : "bad") : ""}"><div class="qh"><span>Aufgabe ${q.nr} von ${t.questions.length} · ${q.type === "mc" ? "Multiple Choice" : q.type === "calc" ? "Rechnen / Programmieren" : "Kurzantwort"}</span><span>${q.points} P.${f ? ` → ${f.points}` : ""}</span></div>
        <div style="font-size:1.02rem;margin-bottom:.7rem">${esc(q.question).replace(/\n/g, "<br>")}</div>
        ${q.type === "mc" ? (q.options || []).map(o => `<label class="opt"><input type="radio" name="q" value="${esc(o)}" ${ans === o ? "checked" : ""} ${t.submitted_at ? "disabled" : ""}> ${esc(o)}</label>`).join("") : `<textarea class="input" id="qa" ${t.submitted_at ? "disabled" : ""} placeholder="Deine Antwort / Rechenweg">${esc(ans)}</textarea>`}
        ${f ? `<div class="fb"><b>Feedback:</b> ${esc(f.feedback)}<br><b>Musterlösung:</b> ${esc(q.answer)}</div><button class="btn primary tr-ask" id="qAsk">${icon("sparkles", 16)} ${esc(TR.askLabel(q.nr))}</button>` : ""}</div>
      <div class="row between"><button class="btn" id="qPrev" ${cur === 0 ? "disabled" : ""}>${icon("chevron-left", 14)} Zurück</button>${cur < t.questions.length - 1 ? `<button class="btn primary" id="qNext">Weiter ${icon("chevron-right", 14)}</button>` : (t.submitted_at ? "" : `<button class="btn ok" id="qSubmit">${icon("check", 14)} Abgeben & bewerten</button>`)}</div></div>`;
    const save = () => { const q = t.questions[cur]; const el = q.type === "mc" ? $("input[name=q]:checked", view) : $("#qa", view); answers[String(q.nr)] = el ? el.value : ""; };
    $$("[data-q]", view).forEach(b => b.onclick = () => { save(); cur = +b.dataset.q; render(); });
    $("#qPrev").onclick = () => { save(); cur--; render(); }; $("#qNext")?.addEventListener("click", () => { save(); cur++; render(); });
    $("#qSubmit")?.addEventListener("click", async () => { save(); const open = t.questions.filter(q => !answers[String(q.nr)]).length; if (!confirm(`Test abgeben?${open ? ` ${open} Aufgaben sind unbeantwortet.` : ""} Die KI bewertet deine Antworten.`)) return; $("#qSubmit").disabled = true; $("#qSubmit").textContent = "Wird bewertet…"; clearInterval(timerInt); try { await api(`/tests/${id}/submit`, { method: "POST", body: { answers } }); if (params.task) await api(`/tasks/${params.task}/status`, { method: "POST", body: { status: "erledigt" } }); runTest(id, params, view); } catch (e) { toast("Bewertung fehlgeschlagen: " + e.message, 5000); $("#qSubmit").disabled = false; } });
    $("#exBack").onclick = () => { document.body.classList.remove("exam-focus"); clearInterval(timerInt); };
    $("#qAsk", view)?.addEventListener("click", () => askAi(q, ans, f));
  };
  // KI-Hilfe zu einer Aufgabe (Seitenleiste): Aufgabe mit eigener und richtiger Antwort, Gespraech, Vorschlaege, Eingabe unten
  const askAi = (q, ans, f) => {
    const right = TR.isRight(f), history = [];
    const d = drawer(`<div class="tr-ai" role="dialog" aria-modal="true" aria-labelledby="trAiT"><div class="tr-ai-hd"><span class="tr-ai-ic" aria-hidden="true">${icon("sparkles", 20)}</span><div><h2 id="trAiT">KI-Hilfe</h2><div class="muted small">${esc(TR.askSub(q))}</div></div><span class="spacer"></span><button class="btn ghost icon" data-close aria-label="KI-Hilfe schließen">${icon("x", 18)}</button></div>
      <div class="tr-ai-body" id="trAiLog" aria-live="polite"><div class="tr-ai-ctx"><div>${esc(q.question).replace(/\n/g, "<br>")}</div><div class="tr-ai-mine ${right ? "ok" : "bad"}">${icon(right ? "check" : "x", 15)} <span><b>Deine Antwort:</b> ${esc(ans || "(keine)")}</span></div><div class="tr-ai-mine ok">${icon("check", 15)} <span><b>Richtige Antwort:</b> ${esc(q.answer ?? "")}</span></div></div></div>
      <div class="tr-ai-sugg">${TR.SUGGESTIONS.map(x => `<button type="button" class="chip" data-sugg="${esc(x)}">${icon("sparkles", 13)} ${esc(x)}</button>`).join("")}</div>
      <form class="tr-ai-in" id="trAiForm"><input class="input" id="trAiQ" placeholder="Frag weiter zu dieser Aufgabe …" aria-label="Frage an die KI" autocomplete="off"><button class="btn primary icon" type="submit" aria-label="Senden">${icon("arrow-right", 18)}</button></form></div>`);
    d.classList.add("tr-drawer");
    const log = $("#trAiLog", d), form = $("#trAiForm", d), inp = $("#trAiQ", d);
    let busy = false;
    const ask = async question => { question = String(question || "").trim(); if (!question || busy) return; busy = true; form.querySelector("button").disabled = true;
      log.insertAdjacentHTML("beforeend", `<div class="tr-ai-me">${esc(question)}</div>`);
      const wait = document.createElement("div"); wait.className = "tr-ai-bot muted"; wait.innerHTML = `<span class="uf-shimmer">Die KI denkt nach …</span>`; log.append(wait); log.scrollTop = log.scrollHeight;
      try { const r = await api("/ai/tutor", { method: "POST", body: { mode: "explain", page_text: TR.tutorContext(q, ans, f), question, history: history.slice() } });
        const { md } = await import("./editor.js?v=66"); wait.classList.remove("muted"); wait.innerHTML = md(r.answer || "");
        history.push({ role: "user", text: question }, { role: "assistant", text: r.answer || "" }); }
      catch (e) { wait.classList.remove("muted"); wait.textContent = `Die KI-Hilfe ist gerade nicht erreichbar: ${e.message}`; }
      busy = false; form.querySelector("button").disabled = false; log.scrollTop = log.scrollHeight; };
    form.onsubmit = e => { e.preventDefault(); const v = inp.value; inp.value = ""; ask(v); };
    $$("[data-sugg]", d).forEach(b => b.onclick = () => ask(b.dataset.sugg));
    inp.focus(); ask(TR.firstQuestion(q.nr, right));
  };
  render();
  if (!t.submitted_at) { const end = new Date(t.started_at).getTime() + t.duration_min * 60000; clearInterval(timerInt); const tick = () => { const left = Math.max(0, end - Date.now()); const el = $("#timer"); if (!el) { clearInterval(timerInt); return; } el.textContent = `⏱ ${Math.floor(left / 60000)}:${String(Math.floor(left % 60000 / 1000)).padStart(2, "0")}`; el.classList.toggle("low", left < 5 * 60000); if (left <= 0) { clearInterval(timerInt); toast("Zeit abgelaufen – bitte abgeben."); } }; tick(); timerInt = setInterval(tick, 1000); }
}
// Karteikarten: Stapel je Modul (04.11.2026, geschlossen: geuebt wird nur im gewaehlten Stapel), darin "Heute fällig"
// (Leitner, POST /review), "Frei üben" (Trainer wie FlashcardTrainer.swift, flashcards.js) und die Karten mit Bearbeiten
// in der Zeile (PATCH question/answer/subject/stack_id, Lernstand bleibt). Der Trainer speichert nur last_result,
// Lesezeichen und "versteckt" per PATCH, nie Fach oder Termin. Stapel: anlegen, umbenennen/verschieben, loeschen (Karten
// mit oder Umzug) ueber /api/flashcard-stacks.
let cardKeys = null;
const SWIPE = 110;                                                            // ab dieser Strecke zaehlt Wischen als Antwort
let cardsStack = null;                                                        // gewaehlter Stapel (bleibt beim Neuladen der Seite)
let cardsWeek = null;                                                         // Wochenfilter der Stapelliste (null = alle)
// Tarif (04.11.2026): ohne `can_use_flashcards` (Free im Dienst, z. B. nach der Probe) nur lesen – Stapel und Karten
// bleiben sichtbar, statt der Knoepfe zum Anlegen, Bearbeiten, Ueben, Teilen und Uebernehmen steht der Hinweis auf Plus.
export async function viewCards(_, __, view) {
  let [dueAll, all, stacks, modules] = await Promise.all([api("/flashcards?due=true"), api("/flashcards"), api("/flashcard-stacks"), api("/modules")]);
  let i = 0, shown = false, editing = null;
  const ro = FC.readOnly(state.hosted, state.entitlements);
  const lockHint = () => ro ? `<div class="card fc-lock" role="note" style="margin-bottom:1rem"><div class="row wrap" style="gap:.6rem;align-items:center">${icon("star", 18)}<div style="flex:1;min-width:12rem"><b>${esc(FC.LOCK_TITLE)}</b><div class="small muted">${esc(FC.LOCK_TEXT)} Deine Stapel und Karten bleiben erhalten.</div></div><a class="btn primary sm" href="#/abo">Tarife ansehen</a></div></div>` : "";
  // Geteilte Stapel je Modul (Modul-Community, nur im gehosteten Dienst: am Einzelplatz leitet /api/community/... an
  // den Dienst weiter, wo die lokale module_id nichts bedeutet -> Teilen bleibt dort ausgeblendet) und der Titel des
  // Trainers, wenn er ohne gewaehlten Stapel laeuft ("Woche n komplett": Vorlesung, dann Uebung)
  let shared = {}, shareAvail = false, trainerTitle = null;
  if (cardsStack != null && !stacks.some(s => s.id === cardsStack)) cardsStack = null;
  const loadShared = async () => {
    const out = {}; let ok = !!state.hosted;
    for (const m of ok ? modules : []) {
      try { out[m.id] = (await api(`/community/card-stacks?module_id=${m.id}`)).stacks || []; }
      catch (e) { if ([401, 403, 409, 501].includes(e.status) && e.code !== "not_a_member" || e.code === "not_hosted") { ok = false; break; } out[m.id] = []; }
    }
    shared = ok ? out : {}; shareAvail = ok && modules.length > 0;
  };
  const trainer = FC.createTrainer({ patch: (id, body) => api(`/flashcards/${id}`, { method: "PATCH", body }) });
  const reload = async () => { [dueAll, all, stacks, modules] = await Promise.all([api("/flashcards?due=true"), api("/flashcards"), api("/flashcard-stacks"), api("/modules")]); if (cardsStack != null && !stacks.some(s => s.id === cardsStack)) cardsStack = null; i = 0; shown = false; render(); loadShared().then(() => { if (view.isConnected && !trainer.active) render(); }).catch(() => {}); };
  const attempt = async (what, fn) => { try { await fn(); } catch (e) { toast(`${what}: ${e.message}`, 4000); } render(); };
  const stack = () => stacks.find(s => s.id === cardsStack) || null;
  const cards = () => FC.cardsOfStack(all, cardsStack);
  const due = () => FC.cardsOfStack(dueAll, cardsStack);
  const moduleOf = subject => modules.find(m => m.name === subject) || null;
  const moduleSelect = (id, value) => `<select id="${id}"><option value="">– keins –</option>${modules.map(m => `<option value="${m.id}" ${String(m.id) === String(value) ? "selected" : ""}>${esc(m.name)}</option>`).join("")}</select>`;
  const stackSelect = (id, subject, value) => `<select id="${id}">${FC.stackOptions(stacks, subject).map(o => `<option value="${o.id}" ${o.id === value ? "selected" : ""}>${esc(o.name)}</option>`).join("")}</select>`;
  const sub = c => [esc(c.answer), `Fach ${c.box}`, ...(FC.isHidden(c) ? [] : [`fällig ${fmtDate(c.due)}`]), ...(FC.isBookmarked(c) ? ["Lesezeichen"] : []), ...(FC.isHidden(c) ? ["versteckt, nicht in „Heute fällig“"] : [])].join(" · ");
  // Stapelliste je Modul
  const sharedAll = () => Object.values(shared).flat();
  const weeksAll = () => [...new Set([...FC.weeksOf(stacks), ...FC.weeksOf(sharedAll())])].sort((a, b) => a - b);
  // je Modul bei gewaehlter Lehrwoche: "Woche n komplett" (beide gemeinsamen Stapel da) bzw. "Karten fuer Woche n holen"
  const weekActions = g => { const m = moduleOf(g.title); if (ro || !m || !(cardsWeek > 0)) return "";
    return FC.hasCompleteWeek(stacks, m.name, cardsWeek) ? `<button class="btn sm" data-weekplay="${m.id}" aria-label="Woche ${cardsWeek} komplett üben: ${esc(m.name)}">${icon("play", 13)} Woche ${cardsWeek} komplett</button>`
      : `<button class="btn sm" data-weekfetch="${m.id}" aria-label="Karten für Woche ${cardsWeek} holen: ${esc(m.name)}">${icon("download", 13)} Karten für Woche ${cardsWeek} holen</button>`; };
  // geteilte Stapel anderer je Modul (Wochenfilter wie die eigene Liste): Uebernehmen, Like, Melden
  const sharedList = () => { if (!shareAvail) return "";
    const groups = modules.map(m => ({ m, list: FC.filterShared(shared[m.id], cardsWeek) })).filter(x => x.list.length);
    return `<div class="card" style="margin-top:1rem"><div class="card-head"><h2>${icon("users", 18)} Geteilt in deinen Modulen</h2></div>
      <p class="muted small" style="margin:0 0 .4rem">Stapel anderer aus der Community deiner Module. „Übernehmen“ legt eine eigene Kopie an – dein Lernstand bleibt privat, 0 Credits.</p>
      ${groups.length ? groups.map(({ m, list }) => `<div class="fc-group"><span class="dot" style="background:${m.color || "var(--line-strong)"}"></span><b>${esc(m.name)}</b><span class="muted small">${list.length}</span></div><div class="list">${list.map(x => `<div class="item"><div class="main"><div class="title">${esc(x.name)} <span class="chip fc-badge-kind">${esc(FC.stackBadge(x))}</span></div><div class="sub">${esc(FC.sharedLine(x))}</div></div>
        <button class="btn ghost icon sm${x.liked_by_me ? " fc-on" : ""}" data-shlike="${esc(x.id)}" aria-pressed="${!!x.liked_by_me}" title="${x.liked_by_me ? "Like entfernen" : "Liken"}" aria-label="${x.liked_by_me ? "Like entfernen" : "Liken"}: ${esc(x.name)}">${icon("heart", 14)}</button>
        <button class="btn ghost icon sm" data-shreport="${esc(x.id)}" ${x.reported_by_me ? "disabled" : ""} title="${x.reported_by_me ? "Schon gemeldet" : "Melden"}" aria-label="Melden: ${esc(x.name)}">${icon("flag", 14)}</button>
        ${ro ? "" : `<button class="btn sm${x.adopted ? "" : " primary"}" data-shadopt="${esc(x.id)}" ${x.adopted ? "disabled" : ""} aria-label="${x.adopted ? "Schon übernommen" : "Übernehmen"}: ${esc(x.name)}">${icon("download", 13)} ${x.adopted ? "Übernommen" : "Übernehmen"}</button>`}</div>`).join("")}</div>`).join("")
        : `<div class="empty small">${cardsWeek == null ? "In deinen Modulen hat noch niemand einen Stapel geteilt." : "Kein geteilter Stapel in dieser Woche."}</div>`}</div>`; };
  // Stapel als Kacheln wie auf dem iPad (CardsPage.swift, 04.11.2026): Kante in der Farbe der Art, Name, Modul, Woche,
  // grosse Zahl "heute fällig", Lernstand je Leitner-Fach 1-5, grosser Knopf "Üben" (faellige zuerst, sonst frei)
  // und "…" mit Bearbeiten, Teilen und Löschen. Free (nur lesen): "Ansehen" statt "Üben", kein Menue.
  const MORE = `<svg class="ic" width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>`;
  const shareBtn = s => ro || !shareAvail || !(s.shared_id || FC.canShare(s)) ? "" : s.shared_id
    ? `<button type="button" role="menuitem" data-reshare="${s.id}">${icon("refresh", 15)} Geteilte Kopie aktualisieren</button><button type="button" role="menuitem" data-unshare="${s.id}">${icon("users", 15)} Teilen zurückziehen</button>`
    : `<button type="button" role="menuitem" data-share="${s.id}">${icon("users", 15)} Stapel teilen</button>`;
  const menuItems = s => ro ? "" : `<button type="button" role="menuitem" data-stedit="${s.id}">${icon("pen", 15)} Bearbeiten</button>${shareBtn(s)}<button type="button" role="menuitem" class="danger" data-stdel="${s.id}">${icon("trash", 15)} Löschen</button>`;
  const stackMenu = s => ro ? "" : `<div class="fc-menu"><button type="button" class="btn fc-more" data-menu="${s.id}" aria-haspopup="menu" aria-expanded="false" aria-controls="fcm${s.id}" title="Weitere Aktionen" aria-label="Weitere Aktionen: ${esc(s.name)}">${MORE}</button>
    <div class="fc-menu-pop" role="menu" id="fcm${s.id}" aria-label="Stapel ${esc(s.name)}" hidden>${menuItems(s)}</div></div>`;
  const stackTile = s => { const kind = FC.kindOf(s), counts = FC.boxCounts(FC.cardsOfStack(all, s.id)), lv = FC.boxLevels(counts), due = Number(s.due) || 0, n = Number(s.cards) || 0;
    return `<article class="fc-tile k-${kind}" aria-labelledby="fcs${s.id}">
      <div class="fc-tile-hd"><span class="fc-tile-ic" aria-hidden="true">${icon(FC.KIND_ICON[kind], 22)}</span><div class="fc-tile-t"><a href="#" class="fc-tile-name" id="fcs${s.id}" data-open="${s.id}" aria-label="Stapel öffnen: ${esc(s.name)}">${esc(s.name)}</a><div class="muted small">${esc(s.subject || "Ohne Modul")}</div></div></div>
      <div class="fc-tile-tags"><span class="fc-tag kind">${esc(FC.kindLabel(kind))}</span><span class="fc-tag">${esc(FC.weekChip(s))}</span>${FC.stackTags(s).map(t => `<span class="fc-tag soft">${esc(t)}</span>`).join("")}</div>
      <div class="fc-tile-due${due ? "" : " zero"}"><b>${due}</b><span>heute fällig</span><span class="spacer"></span><span class="muted">${n} ${n === 1 ? "Karte" : "Karten"}</span></div>
      <div class="fc-boxes" role="img" aria-label="${esc(FC.boxAria(counts))}"><div class="fc-boxes-hd" aria-hidden="true"><b>Lernstand</b><span>Fach 1 → 5</span></div>
        <div class="fc-boxes-bars" aria-hidden="true">${lv.map((h, k) => `<span class="fc-box"><i style="height:${counts[k] ? Math.max(14, Math.round(h * 100)) : 0}%;opacity:${(.45 + .55 * k / 4).toFixed(2)}"></i></span>`).join("")}</div>
        <div class="fc-boxes-n" aria-hidden="true">${counts.map(c => `<span>${c}</span>`).join("")}</div></div>
      <div class="fc-tile-go">${ro ? `<a href="#" class="btn fc-go" data-open="${s.id}" aria-label="Ansehen: ${esc(s.name)}">${icon("eye", 18)} Ansehen</a>` : `<button type="button" class="btn primary fc-go" data-play="${s.id}" ${n ? "" : "disabled"} aria-label="Üben: ${esc(s.name)}, ${esc(FC.practiceLine(due))}">${icon("play", 18)} Üben</button>`}${stackMenu(s)}</div>
      <div class="muted small fc-tile-foot">${ro ? esc(FC.stackLine(s, fmtDate).split(" · ").slice(-1)[0]) : esc(n ? FC.practiceLine(due) : "Noch keine Karte im Stapel")}</div></article>`; };
  const stackList = () => { const tot = FC.stackTotals(stacks), segs = FC.weekSegments(weeksAll(), cardsWeek);
    return `${lockHint()}<div class="card fc-sum"><div class="fc-sum-due"><b>${dueAll.length}</b><span>heute fällig</span></div><span class="fc-sum-sep" aria-hidden="true"></span><span class="muted">${tot.stacks} ${tot.stacks === 1 ? "Stapel" : "Stapel"} · ${tot.cards} ${tot.cards === 1 ? "Karte" : "Karten"}</span><span class="spacer"></span>${ro ? "" : modules.length ? `<button class="btn" id="aiOrder">${can("can_use_ai_generated_questions") ? icon("sparkles", 15) : lockIcon(15)} KI-Karteikarten</button><button class="btn" id="wkFetch">${icon("download", 15)} Karten für eine Woche holen …</button>` : ""}</div>
    ${weeksAll().length ? `<div class="seg fc-weekseg" role="radiogroup" aria-label="Lehrwoche">${segs.map(x => `<button type="button" class="${x.on ? "active" : ""}" role="radio" aria-checked="${x.on}" data-week="${x.value === null ? "" : x.value}">${x.label}</button>`).join("")}</div>` : ""}
    ${stacks.length ? (FC.groupStacks(FC.filterStacks(stacks, cardsWeek), modules).map(g => `<section class="fc-sec" aria-label="${esc(g.title)}"><div class="fc-group"><span class="dot" style="background:${g.color || "var(--line-strong)"}"></span><h2>${esc(g.title)}</h2><span class="fc-count-b">${g.stacks.length}</span><span class="spacer"></span>${weekActions(g)}</div><div class="fc-tiles">${g.stacks.map(stackTile).join("")}</div></section>`).join("") || `<div class="card empty small">Kein Stapel in dieser Woche.</div>`)
      : `<div class="card empty">${icon("cards", 32)}<div>${ro ? "Noch keine Karten." : "Noch keine Karten. Erstelle welche im Editor über die KI-Seitenleiste, hole die gemeinsamen Karten einer Woche oder lege einen Stapel an."}</div></div>`}${sharedList()}`; };
  // "Karten fuer Woche n holen": Vorlesung und Uebung nacheinander (POST /flashcard-stacks/week/{modul}/{woche}/{art});
  // vorhandener oder gemeinsamer Stapel = 0 Credits, sonst erzeugt die KI ihn einmal fuer alle
  const fetchWeek = async (moduleId, week) => {
    const lines = [];
    for (const kind of FC.WEEK_KINDS) {
      try { const r = await api(`/flashcard-stacks/week/${moduleId}/${week}/${kind}`, { method: "POST", body: {} }); lines.push(FC.fetchLabel(kind, r.status, r.stack?.cards ?? 0, r.variant)); }
      catch (e) { if (e.code === "no_materials") lines.push(FC.fetchLabel(kind, "no_materials")); else throw e; }
    }
    return lines;
  };
  const weekFetchDialog = (moduleId, week) => {
    const wk = week || Math.max(1, weeksAll().slice(-1)[0] || 1), weeks = [...new Set([...Array.from({ length: 16 }, (_, k) => k + 1), ...weeksAll(), wk])].sort((a, b) => a - b);
    const m = modal(`<h3>${icon("download", 18)} Karten für eine Woche holen</h3><form id="wkForm"><div class="row wrap"><label class="field"><span>Modul</span><select id="wkMod">${modules.map(x => `<option value="${x.id}" ${x.id === moduleId ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label>
      <label class="field"><span>Lehrwoche</span><select id="wkWeek">${weeks.map(w => `<option value="${w}" ${w === wk ? "selected" : ""}>Woche ${w}</option>`).join("")}</select></label></div>
      <p class="muted small">Je Woche gibt es zwei gemeinsame Stapel: „Vorlesung Woche n“ aus den Vorlesungsunterlagen und „Übung Woche n“ aus den Übungsblättern. Sie werden einmal erzeugt und von allen übernommen, die dieselben Unterlagen haben – übernehmen kostet 0 Credits. Nur wenn noch niemand sie hat, erzeugt deine KI den Stapel (eine Anfrage je Stapel, bis zu 20 Karten). Geübt wird danach privat.</p>
      <div id="wkOut" class="small" aria-live="polite"></div><div class="modal-foot"><button class="btn" type="button" data-close>Schließen</button><button class="btn primary" type="submit" id="wkGo">${icon("download", 14)} Karten holen</button></div></form>`);
    $("#wkForm", m).onsubmit = async e => { e.preventDefault(); const go = $("#wkGo", m), mid = Number($("#wkMod", m).value), w = Number($("#wkWeek", m).value);
      go.disabled = true; go.textContent = "Wird geholt …";
      try { const lines = await fetchWeek(mid, w); $("#wkOut", m).innerHTML = lines.map(l => `<div>${esc(l)}</div>`).join(""); cardsWeek = w; await reload(); }
      catch (x) { showError(x); }
      go.disabled = false; go.innerHTML = `${icon("download", 14)} Karten holen`; };
  };
  // "Stapel teilen" (freiwillig, je Stapel, nie einzelne Karten): Kopie in die Community des Moduls unter dem Pseudonym
  const shareDialog = s => {
    const m = modal(`<h3>${icon("users", 18)} Stapel teilen?</h3><p><b>${esc(s.name)}</b> · ${s.cards} ${s.cards === 1 ? "Karte" : "Karten"}</p>
      <p class="small">Eine Kopie der Karten (Frage und Antwort) erscheint in der Community von <b>${esc(s.subject)}</b> unter ${s.week ? `<b>Woche ${s.week}</b>` : "<b>Allgemein</b>"} – mit deinem Pseudonym, nie mit deinem Namen. Dein Lernstand bleibt privat. Andere können den Stapel übernehmen, liken oder melden; du kannst das Teilen jederzeit zurückziehen.</p>
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="shGo">${icon("users", 14)} Teilen</button></div>`);
    $("#shGo", m).onclick = () => attempt("Stapel teilen", async () => { await api(`/flashcard-stacks/${s.id}/share`, { method: "POST", body: {} }); m.remove(); toast("Stapel geteilt"); await reload(); });
  };
  const reportDialog = x => {
    const reasons = [["foreignMaterial", "Fremdes Material (Urheberrecht)"], ["gradedSubmission", "Bewertete Abgabe"], ["offensive", "Beleidigend"], ["spam", "Spam"], ["other", "Etwas anderes"]];
    const m = modal(`<h3>${icon("flag", 18)} Stapel melden</h3><p><b>${esc(x.name)}</b> · ${esc(x.pseudonym || "")}</p><form id="rpForm"><label class="field"><span>Grund</span><select name="reason">${reasons.map(([k, t]) => `<option value="${k}">${t}</option>`).join("")}</select></label><label class="field"><span>Hinweis (optional)</span><textarea name="note" rows="2" maxlength="500"></textarea></label>
      <div class="modal-foot"><button class="btn" type="button" data-close>Abbrechen</button><button class="btn primary" type="submit">${icon("flag", 14)} Melden</button></div></form>`);
    $("#rpForm", m).onsubmit = e => { e.preventDefault(); attempt("Melden", async () => { await api(`/community/card-stacks/${x.id}/report`, { method: "POST", body: { reason: e.target.reason.value, note: e.target.note.value } }); m.remove(); toast("Danke, der Stapel ist gemeldet."); await reload(); }); };
  };
  // Karten des Stapels mit Bearbeiten in der Zeile
  const editRow = c => { const subject = c.subject || null, mod = moduleOf(subject);
    return `<div class="item fc-edit" data-editrow="${c.id}"><form class="main" data-editform="${c.id}"><label class="field"><span>Frage</span><textarea name="question" rows="2">${esc(c.question)}</textarea></label><label class="field"><span>Antwort</span><textarea name="answer" rows="2">${esc(c.answer)}</textarea></label>
      <div class="row wrap"><label class="field"><span>Modul</span>${moduleSelect(`edMod${c.id}`, mod?.id ?? "")}</label><label class="field"><span>Stapel</span>${stackSelect(`edStack${c.id}`, subject, c.stack_id)}</label><label class="field fc-newname" ${c.stack_id ? "hidden" : ""}><span>Name des neuen Stapels</span><input name="newStackName" value=""></label></div>
      <p class="muted small" style="margin:.2rem 0 0">Fach ${c.box} und Termin der Wiederholung bleiben beim Bearbeiten erhalten.</p>
      <div class="row" style="margin-top:.5rem"><button class="btn primary sm" type="submit">${icon("check", 14)} Speichern</button><button class="btn sm" type="button" data-editcancel>Abbrechen</button></div></form></div>`; };
  const list = () => { const cs = cards(); return `<div class="card" style="margin-top:1rem"><div class="card-head"><h2>Karten im Stapel</h2><span class="muted small">${cs.length}</span></div><div class="list">${cs.map(c => editing === c.id ? editRow(c) : `<div class="item${FC.isHidden(c) ? " fc-hidden" : ""}"><div class="main"><div class="title">${esc(c.question)}</div><div class="sub">${sub(c)}</div></div>
    ${ro ? "" : `<button class="btn ghost icon sm" data-edit="${c.id}" title="Bearbeiten" aria-label="Karte bearbeiten: ${esc(c.question)}">${icon("pen", 14)}</button>
    <button class="btn ghost icon sm${FC.isBookmarked(c) ? " fc-on" : ""}" data-mark="${c.id}" aria-pressed="${FC.isBookmarked(c)}" title="${FC.isBookmarked(c) ? "Lesezeichen entfernen" : "Lesezeichen setzen"}" aria-label="${FC.isBookmarked(c) ? "Lesezeichen entfernen" : "Lesezeichen setzen"}: ${esc(c.question)}">${icon("bookmark", 14)}</button>
    <button class="btn ghost icon sm" data-hide="${c.id}" title="${FC.isHidden(c) ? "Wieder zeigen" : "Verstecken"}" aria-label="${FC.isHidden(c) ? "Karte wieder zeigen" : "Karte verstecken"}: ${esc(c.question)}">${icon(FC.isHidden(c) ? "eye" : "eye-off", 14)}</button>
    <button class="btn ghost icon sm" data-delcard="${c.id}" title="Karte löschen" aria-label="Karte löschen: ${esc(c.question)}">${icon("trash", 14)}</button>`}</div>`).join("") || `<div class="empty small">Noch keine Karte in diesem Stapel.</div>`}</div></div>`; };
  const practice = () => { const cs = cards(), n = FC.progressCounts(cs), marks = cs.filter(FC.isBookmarked).length;
    return `<div class="card" style="margin-top:1rem"><div class="card-head"><h2>${icon("layers", 18)} Frei üben</h2></div><p class="small" style="margin:0">Die Karten dieses Stapels im eigenen Tempo: umdrehen, nach rechts wischen (→) für gewusst, nach links (←) für nicht gewusst. Ändert den Wiederholungsplan nicht.</p>
      <p class="muted small" style="margin:.3rem 0 0">${n.right} richtig · ${n.wrong} falsch · ${n.unlearned} noch nicht gelernt${marks ? ` · ${marks} mit Lesezeichen` : ""}${n.hidden ? ` · ${n.hidden} versteckt` : ""}</p>
      <div class="row wrap" style="margin-top:.8rem"><button class="btn primary sm" id="fcPlay" ${cs.length ? "" : "disabled"}>${icon("play", 14)} Üben</button><button class="btn ghost sm" id="fcOpts" ${cs.length ? "" : "disabled"}>${icon("filter", 14)} Optionen</button></div></div>`; };
  const counters = () => `<div class="fc-count"><b class="fc-pos">${FC.cardOf(trainer.position, trainer.cards.length)}</b><span class="spacer"></span><span class="fc-pill bad">Nicht gewusst <b>${trainer.unknown}</b></span><span class="fc-pill ok">Gewusst <b>${trainer.known}</b></span></div>
    <div class="progress fc-prog" role="progressbar" aria-label="Fortschritt" aria-valuemin="0" aria-valuemax="${trainer.cards.length}" aria-valuenow="${Math.min(trainer.position, trainer.cards.length)}"><i style="width:${trainer.cards.length ? Math.round(100 * Math.min(trainer.position, trainer.cards.length) / trainer.cards.length) : 0}%"></i></div>`;
  const trainerHtml = () => {
    const c = trainer.current, head = `<div class="row" style="gap:.4rem"><button class="btn ghost icon" id="trEnd" title="Üben beenden" aria-label="Üben beenden">${icon("arrow-left", 18)}</button><b style="font-size:.95rem">Frei üben · ${esc(trainerTitle || stack()?.name || "")}</b><span class="spacer"></span><button class="btn ghost icon" id="trRestart" title="Neu starten" aria-label="Neu starten" ${trainer.busy || !trainer.source.length ? "disabled" : ""}>${icon("refresh", 18)}</button><button class="btn ghost icon" id="trOpts" title="Optionen" aria-label="Optionen">${icon("filter", 18)}</button></div>`;
    if (trainer.empty) return `<div class="card" id="fcTr">${head}<div class="empty">${icon("filter", 32)}<div>${trainer.options.scope === "bookmarked" ? "Keine Karte mit Lesezeichen passt zu diesen Optionen." : "Keine Karte passt zu diesen Optionen."}</div><button class="btn sm" id="trOpts2">${icon("filter", 14)} Optionen</button></div></div>`;
    if (trainer.finished) { const n = trainer.known + trainer.unknown;
      return `<div class="card" id="fcTr">${head}${counters()}<h3 style="margin:.6rem 0 .2rem">Durchgang geschafft</h3><p class="small" style="margin:0">${n} ${n === 1 ? "Karte" : "Karten"} geübt: ${trainer.known} gewusst, ${trainer.unknown} nicht gewusst.</p><p class="muted small" style="margin:.2rem 0 0">Der Wiederholungsplan („Heute fällig“) bleibt davon unverändert.</p>
        <div class="row wrap" style="margin-top:.9rem">${trainer.unknown ? `<button class="btn primary sm" id="trUnknown">${icon("play", 14)} Nicht gewusste üben (${trainer.unknown})</button>` : ""}<button class="btn sm" id="trRestart2">${icon("refresh", 14)} Neu starten</button><button class="btn sm" id="trPrev" ${trainer.canGoBack ? "" : "disabled"}>${icon("undo", 14)} Vorherige</button><button class="btn sm" id="trDone">${icon("check", 14)} Fertig</button></div></div>`; }
    const def = trainer.showsDefinition, text = def ? c.answer : c.question, marked = FC.isBookmarked(c), hid = FC.isHidden(c);
    return `<div class="card" id="fcTr">${head}${counters()}
      <div class="fc-stage"><div class="fc-big${def ? " def" : ""}" id="trCard" role="button" tabindex="0" aria-label="${def ? "Definition" : "Begriff"}: ${esc(text)}. Leertaste dreht die Karte."><span class="fc-side">${def ? "Definition" : "Begriff"}</span><span class="fc-badge" aria-hidden="true"></span>
        <div class="fc-tools"><button class="btn ghost icon sm" id="trEdit" title="Bearbeiten" aria-label="Bearbeiten" ${trainer.busy ? "disabled" : ""}>${icon("pen", 16)}</button><button class="btn ghost icon sm${marked ? " fc-on" : ""}" id="trMark" aria-pressed="${marked}" title="${marked ? "Lesezeichen entfernen" : "Lesezeichen setzen"}" aria-label="${marked ? "Lesezeichen entfernen" : "Lesezeichen setzen"}" ${trainer.busy ? "disabled" : ""}>${icon("bookmark", 16)}</button><button class="btn ghost sm" id="trHide" ${trainer.busy ? "disabled" : ""}>${hid ? "Wieder zeigen" : "Verstecken"}</button></div>
        <div class="fc-text">${esc(text).replace(/\n/g, "<br>")}</div></div></div>
      <p class="muted small" style="text-align:center;margin:.6rem 0 0" aria-hidden="true">Klicken oder Leertaste zum Umdrehen · → bzw. nach rechts wischen: gewusst · ← bzw. nach links: nicht gewusst</p>
      <div class="fc-judge"><button class="btn fc-no" id="trNo" ${trainer.busy ? "disabled" : ""}>${icon("x", 18)} Nicht gewusst</button><button class="btn fc-yes" id="trYes" ${trainer.busy ? "disabled" : ""}>${icon("check", 18)} Gewusst</button></div>
      <div class="row fc-bar"><button class="btn" id="trPrev" ${trainer.canGoBack ? "" : "disabled"}>${icon("undo", 15)} Vorherige</button><button class="btn" id="trAgain" ${trainer.canAskAgain ? "" : "disabled"} title="Kommt ein paar Karten später noch einmal">${icon("refresh", 15)} Erneut fragen</button></div></div>`;
  };
  const answer = known => { if (trainer.busy || !trainer.current) return; const p = trainer.answer(known); render(); attempt("Antwort speichern", () => p); };
  const previous = () => { if (!trainer.canGoBack) return; const p = trainer.previous(); render(); attempt("Zurücknehmen", () => p); };
  const askAgain = () => { if (!trainer.askAgain()) return; render(); toast(`Kommt in ${FC.ASK_AGAIN_GAP} Karten wieder`, 1500); };
  const flip = () => { if (!trainer.current) return; trainer.flip(); render(); $("#trCard", view)?.focus(); };
  const close = () => { trainer.end(); trainerTitle = null; reload().catch(e => toast(e.message, 4000)); };
  // Karte bearbeiten im Dialog (Trainer, Wiederholung): Frage, Antwort, Modul, Stapel; der Lernstand bleibt
  const editDialog = (c, after) => {
    const subject = c.subject || null, mod = moduleOf(subject);
    const m = modal(`<h3>${icon("pen", 18)} Karte bearbeiten</h3><form id="fcEditForm"><label class="field"><span>Frage</span><textarea name="question" rows="3">${esc(c.question)}</textarea></label><label class="field"><span>Antwort</span><textarea name="answer" rows="3">${esc(c.answer)}</textarea></label>
      <div class="row wrap"><label class="field"><span>Modul</span>${moduleSelect("fcEdMod", mod?.id ?? "")}</label><label class="field"><span>Stapel</span>${stackSelect("fcEdStack", subject, c.stack_id)}</label><label class="field fc-newname" hidden><span>Name des neuen Stapels</span><input name="newStackName"></label></div>
      <p class="muted small">Fach ${c.box} und Termin der Wiederholung bleiben erhalten.</p><div class="modal-foot"><button class="btn" type="button" data-close>Abbrechen</button><button class="btn primary" type="submit">${icon("check", 14)} Speichern</button></div></form>`);
    bindEditForm($("#fcEditForm", m), c, async saved => { m.remove(); after?.(saved); });
  };
  // Formular (Zeile oder Dialog): Modulwechsel setzt die Stapelauswahl neu, "Neuer Stapel …" blendet den Namen ein
  const bindEditForm = (form, c, done) => {
    const mod = $("select[id^=edMod], select#fcEdMod", form), st = $("select[id^=edStack], select#fcEdStack", form), nameField = $(".fc-newname", form);
    const syncName = () => { nameField.hidden = Number(st.value) !== FC.NEW_STACK; if (!nameField.hidden && !$("input", nameField).value) $("input", nameField).value = FC.suggestedStackName(null, modules.find(x => String(x.id) === mod.value)?.name || null); };
    mod.onchange = () => { const subject = modules.find(x => String(x.id) === mod.value)?.name || null; const keep = FC.stacksOfSubject(stacks, subject).some(s => s.id === Number(st.value));
      st.innerHTML = FC.stackOptions(stacks, subject).map(o => `<option value="${o.id}">${esc(o.name)}</option>`).join(""); st.value = String(keep ? Number(st.value) : FC.defaultStack(stacks, subject)); syncName(); };
    st.onchange = syncName; syncName();
    form.onsubmit = e => { e.preventDefault();
      const subject = modules.find(x => String(x.id) === mod.value)?.name || null;
      const d = { question: form.question.value, answer: form.answer.value, subject, stack: Number(st.value), newStackName: form.newStackName?.value || "" };
      const err = FC.validateCard(d); if (err) { toast(err, 3000); return; }
      attempt("Karte speichern", async () => {
        if (d.stack === FC.NEW_STACK) { const s = await api("/flashcard-stacks", { method: "POST", body: { name: d.newStackName.trim(), subject, file_id: c.file_id || null } }); stacks = [s, ...stacks]; d.stack = s.id; }
        const body = FC.editPatch(c, d);
        const saved = Object.keys(body).length ? await api(`/flashcards/${c.id}`, { method: "PATCH", body }) : c;
        all = FC.mergeCard(all, saved); dueAll = FC.mergeCard(dueAll, saved); editing = null;
        toast("Karte gespeichert"); await done(saved);
      }); };
  };
  // Stapel anlegen bzw. umbenennen und verschieben
  const stackDialog = s => {
    const mod = moduleOf(s?.subject || null);
    const weeks = [...new Set([...Array.from({ length: 16 }, (_, i) => i + 1), ...FC.weeksOf(stacks), ...(s?.week ? [s.week] : [])])].sort((a, b) => a - b);
    const m = modal(`<h3>${icon("layers", 18)} ${s ? "Stapel bearbeiten" : "Neuer Stapel"}</h3><form id="stForm"><label class="field"><span>Name</span><input name="name" value="${esc(s?.name || "")}" placeholder="z. B. Klausur, Kapitel 3" required></label><label class="field"><span>Modul</span>${moduleSelect("stMod", mod?.id ?? "")}</label>
      <div class="row wrap"><label class="field"><span>Lehrwoche</span><select id="stWeek"><option value="">Allgemein</option>${weeks.map(w => `<option value="${w}" ${s?.week === w ? "selected" : ""}>W${w}</option>`).join("")}</select></label><label class="field"><span>Art</span><select id="stKind">${Object.entries(FC.KINDS).map(([k, t]) => `<option value="${k}" ${(s?.kind || "eigene") === k ? "selected" : ""}>${t}</option>`).join("")}</select></label></div>
      ${s?.cards ? `<p class="muted small">Die ${s.cards} ${s.cards === 1 ? "Karte" : "Karten"} des Stapels wechseln das Modul mit.</p>` : ""}<div class="modal-foot"><button class="btn" type="button" data-close>Abbrechen</button><button class="btn primary" type="submit">${icon("check", 14)} ${s ? "Speichern" : "Anlegen"}</button></div></form>`);
    $("#stForm", m).onsubmit = e => { e.preventDefault(); const name = e.target.name.value.trim(); if (!name) { toast("Der Stapel braucht einen Namen.", 3000); return; }
      const subject = modules.find(x => String(x.id) === $("#stMod", m).value)?.name || null;
      const week = $("#stWeek", m).value ? Number($("#stWeek", m).value) : null, kind = $("#stKind", m).value;
      attempt(s ? "Stapel speichern" : "Stapel anlegen", async () => { await api(s ? `/flashcard-stacks/${s.id}` : "/flashcard-stacks", { method: s ? "PATCH" : "POST", body: { name, subject, week, kind } }); m.remove(); toast(s ? "Stapel gespeichert" : "Stapel angelegt"); await reload(); }); };
  };
  // Stapel loeschen: Karten mit loeschen oder in einen anderen Stapel verschieben (Lernstand bleibt)
  const stackDeleteDialog = s => {
    const others = stacks.filter(x => x.id !== s.id);
    const m = modal(`<h3>${icon("trash", 18)} Stapel löschen?</h3><p><b>${esc(s.name)}</b></p>${s.cards ? `<p class="small">Was soll mit ${s.cards === 1 ? "der Karte" : `den ${s.cards} Karten`} geschehen?</p><label class="field"><span>Karten</span><select id="stMove"><option value="0">Mit dem Stapel löschen</option>${others.map(o => `<option value="${o.id}">Verschieben in: ${esc(o.name)}${o.subject ? ` (${esc(o.subject)})` : ""}</option>`).join("")}</select></label><p class="muted small" id="stMoveHint">Die Karten und ihr Lernstand werden gelöscht. Das lässt sich nicht rückgängig machen.</p>` : `<p class="small">Der Stapel ist leer und wird gelöscht.</p>`}
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary danger" id="stDelGo">${icon("trash", 14)} Löschen</button></div>`);
    $("#stMove", m)?.addEventListener("change", e => { $("#stMoveHint", m).textContent = e.target.value === "0" ? "Die Karten und ihr Lernstand werden gelöscht. Das lässt sich nicht rückgängig machen." : "Die Karten behalten ihren Lernstand und bekommen das Modul des Zielstapels."; $("#stDelGo", m).innerHTML = `${icon("trash", 14)} ${e.target.value === "0" ? "Löschen" : "Verschieben und löschen"}`; });
    $("#stDelGo", m).onclick = () => { const to = Number($("#stMove", m)?.value || 0); attempt("Stapel löschen", async () => { await api(`/flashcard-stacks/${s.id}${to ? `?move_to=${to}` : ""}`, { method: "DELETE" }); m.remove(); if (cardsStack === s.id) cardsStack = to || null; toast(to ? "Karten verschoben, Stapel gelöscht" : "Stapel gelöscht"); await reload(); }); };
  };
  const options = () => {
    let draft = { ...trainer.options, progress: [...trainer.options.progress] };
    const n = FC.progressCounts(trainer.source), marks = trainer.source.filter(FC.isBookmarked).length;
    const seg = (key, opts) => `<div class="seg pill fc-seg" role="radiogroup">${opts.map(([v, t]) => `<button type="button" role="radio" aria-checked="${draft[key] === v}" class="${draft[key] === v ? "active" : ""}" data-k="${key}" data-v="${v}">${t}</button>`).join("")}</div>`;
    const html = () => `<h3>${icon("filter", 18)} Optionen</h3>
      <div class="fc-opt"><small>Lernen</small>${seg("scope", [["all", "Alle"], ["bookmarked", `Lesezeichen (${marks})`]])}</div>
      <div class="fc-opt"><small>Nach Fortschritt filtern</small><div class="row wrap" style="gap:.4rem">${FC.PROGRESS.map(p => `<button type="button" class="chip${draft.progress.includes(p) ? " on" : ""}" aria-pressed="${draft.progress.includes(p)}" data-p="${p}">${draft.progress.includes(p) ? icon("check", 13) : ""} ${FC.PROGRESS_TXT[p]} (${n[p]})</button>`).join("")}</div></div>
      <div class="fc-opt"><small>Reihenfolge</small>${seg("order", [["original", "Original"], ["random", "Zufällig"]])}</div>
      <div class="fc-opt"><small>Zuerst zeigen</small>${seg("firstSide", [["term", "Begriff"], ["definition", "Definition"]])}</div>
      ${(() => { const k = FC.selectCards(draft, trainer.source, x => x).length; return `<p class="small ${k ? "muted" : ""}" style="margin:.8rem 0 0;${k ? "" : "color:var(--bad-text)"}">${k === 1 ? "1 Karte passt." : `${k} Karten passen.`}</p>`; })()}
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn" data-reset ${FC.sameOptions(draft, FC.defaultOptions()) ? "disabled" : ""}>Zurücksetzen</button><button class="btn primary" data-apply>${icon("check", 14)} Filter anwenden</button></div>`;
    const m = modal(html()), box = $(".modal-box", m);
    const bind = () => {
      $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
      $$("[data-k]", box).forEach(b => b.onclick = () => { draft[b.dataset.k] = b.dataset.v; redraw(); });
      $$("[data-p]", box).forEach(b => b.onclick = () => { const p = b.dataset.p; draft.progress = draft.progress.includes(p) ? draft.progress.filter(x => x !== p) : [...draft.progress, p]; redraw(); });
      $("[data-reset]", box).onclick = () => { draft = FC.defaultOptions(); redraw(); };
      $("[data-apply]", box).onclick = () => { trainer.apply(draft); m.remove(); render(); };
    };
    const redraw = () => { box.innerHTML = html(); bind(); };
    bind();
  };
  const bindSwipe = card => {
    let x0 = null, y0 = 0, dx = 0, id = null;
    const set = d => { card.style.transform = d ? `translateX(${d}px) rotate(${matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : d / 30}deg)` : ""; const lean = d / SWIPE; card.classList.toggle("lean-ok", lean > .25); card.classList.toggle("lean-bad", lean < -.25); $(".fc-badge", card).textContent = lean > .25 ? "Gewusst" : lean < -.25 ? "Nicht gewusst" : ""; };
    card.addEventListener("pointerdown", e => { if (e.button || e.target.closest(".fc-tools")) return; x0 = e.clientX; y0 = e.clientY; dx = 0; id = e.pointerId; });
    card.addEventListener("pointermove", e => { if (x0 === null || e.pointerId !== id) return; const w = e.clientX - x0, h = e.clientY - y0; if (Math.abs(w) < 18 || Math.abs(w) <= Math.abs(h) || trainer.busy) return; if (!card.hasPointerCapture(id)) card.setPointerCapture(id); dx = w; card.classList.add("dragging"); set(dx); });
    const up = e => { if (x0 === null || e.pointerId !== id) return; x0 = null; card.classList.remove("dragging"); const d = dx; dx = 0;
      if (Math.abs(d) >= SWIPE && !trainer.busy) { answer(d > 0); return; } set(0); if (Math.abs(d) < 8 && e.type === "pointerup") flip(); };
    card.addEventListener("pointerup", up); card.addEventListener("pointercancel", up);
  };
  // Wiederholung: jede Antwort zaehlt einmal (waehrend des Speicherns keine zweite)
  let reviewing = false;
  const judge = async (c, correct) => { if (reviewing || !c || !shown) return; reviewing = true;
    try { await api(`/flashcards/${c.id}/review`, { method: "POST", body: { correct } }); i++; shown = false; } catch (e) { toast(`Antwort speichern: ${e.message}`, 4000); }
    finally { reviewing = false; } render(); $("#fc", view)?.focus(); };
  // "…"-Menue der Kacheln: oeffnet unter dem Knopf, Escape oder Klick daneben schliesst, Pfeiltasten wandern
  const closeMenus = (except = null) => $$(".fc-menu-pop", view).forEach(m => { if (m === except) return; m.hidden = true; $(`[aria-controls="${m.id}"]`, view)?.setAttribute("aria-expanded", "false"); });
  const bindMenus = () => $$("[data-menu]", view).forEach(b => { const pop = $(`#${b.getAttribute("aria-controls")}`, view);
    b.onclick = e => { e.stopPropagation(); const open = pop.hidden; closeMenus(pop); pop.hidden = !open; b.setAttribute("aria-expanded", String(open)); if (open) $("[role=menuitem]", pop)?.focus(); };
    pop.onkeydown = e => { const items = $$("[role=menuitem]", pop), k = items.indexOf(document.activeElement);
      if (e.key === "Escape") { e.preventDefault(); closeMenus(); b.focus(); }
      else if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); items[(k + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus(); } };
    $$("[role=menuitem]", pop).forEach(it => it.addEventListener("click", () => closeMenus())); });
  if (!view._fcMenuClose) { view._fcMenuClose = true; document.addEventListener("click", e => { if (view.isConnected && !e.target.closest?.(".fc-menu")) closeMenus(); }); }
  const render = () => {
    const s = stack(), d = due(), c = d[i];
    const review = s ? (c ? `<section class="card fc-rev" id="fcRev" aria-label="Wiederholung: heute fällig">
      <div class="fc-rev-head"><div><h2>Heute fällig (${d.length})</h2><div class="muted small">${esc(s.name)}</div></div><button class="btn sm" id="fcEdit">${icon("pen", 14)} Bearbeiten</button></div>
      <div class="fc-rev-pos"><b>${FC.cardOf(i, d.length)}</b><span class="muted small">Fach ${c.box} · Nur dieser Stapel wird abgefragt</span></div>
      <div class="progress fc-prog" role="progressbar" aria-label="Fortschritt" aria-valuemin="0" aria-valuemax="${d.length}" aria-valuenow="${i}"><i style="width:${Math.round(100 * i / d.length)}%"></i></div>
      <div class="fc-card fc-big2${shown ? " shown" : ""}" id="fc" role="button" tabindex="0" aria-label="${shown ? `Frage: ${esc(c.question)}. Antwort: ${esc(c.answer)}` : `Frage: ${esc(c.question)}. Leertaste deckt die Antwort auf.`}">
        <span class="fc-lab"><i aria-hidden="true"></i>Frage</span><div class="fc-q">${esc(c.question).replace(/\n/g, "<br>")}</div>
        ${shown ? `<span class="fc-lab ans"><i aria-hidden="true"></i>Antwort</span><div class="fc-a">${esc(c.answer).replace(/\n/g, "<br>")}</div>` : ""}</div>
      ${shown ? `<p class="muted small fc-hint" aria-hidden="true">← nicht gewusst · → gewusst</p><div class="fc-judge"><button class="btn fc-no" id="fcW">${icon("x", 18)} Nicht gewusst</button><button class="btn fc-yes" id="fcR">${icon("check", 18)} Gewusst</button></div>`
        : `<p class="muted small fc-hint" aria-hidden="true">Klicken oder Leertaste deckt die Antwort auf</p><button class="btn primary fc-show" id="fcShow">${icon("rotate", 18)} Antwort zeigen</button>`}</section>`
      : `<div class="card empty">${icon("check", 36)}<div>In diesem Stapel ist heute nichts fällig.</div></div>`) : "";
    const head = s ? `<a class="btn" href="#" id="fcBack">${icon("layers", 15)} Alle Stapel</a>` : (ro ? "" : `<button class="btn" id="stNew">${icon("layers", 15)} Neuer Stapel</button>`);
    view.innerHTML = `<div class="content fc-page${s || trainer.active ? " fc-narrow" : ""}"><div class="page-head"><div><h1>Karteikarten${s ? ` · ${esc(s.name)}` : ""}</h1><div class="sub">${s ? `${esc(FC.stackLine(s, fmtDate))}` : "Deine Stapel je Modul · Leitner-System: richtig = seltener, falsch = morgen wieder."}</div></div><div class="actions">${head}</div></div>
      ${trainer.active && !ro ? trainerHtml() : s ? (ro ? `${lockHint()}${list()}` : `${review}${practice()}${list()}`) : stackList()}</div>`;
    $("#fcBack", view)?.addEventListener("click", e => { e.preventDefault(); cardsStack = null; i = 0; shown = false; editing = null; render(); });
    if (trainer.active) {
      $("#trEnd", view).onclick = close; $("#trDone", view)?.addEventListener("click", close);
      $("#trRestart", view).onclick = () => { trainer.restart(); render(); }; $("#trRestart2", view)?.addEventListener("click", () => { trainer.restart(); render(); });
      $("#trOpts", view).onclick = options; $("#trOpts2", view)?.addEventListener("click", options);
      $("#trUnknown", view)?.addEventListener("click", () => { trainer.practiceUnknown(); render(); });
      $("#trPrev", view)?.addEventListener("click", previous);
      $("#trAgain", view)?.addEventListener("click", askAgain);
      $("#trNo", view)?.addEventListener("click", () => answer(false)); $("#trYes", view)?.addEventListener("click", () => answer(true));
      $("#trMark", view)?.addEventListener("click", () => { const p = trainer.toggleBookmark(); render(); attempt("Lesezeichen", () => p); });
      $("#trHide", view)?.addEventListener("click", () => { const hiding = !FC.isHidden(trainer.current); const p = trainer.toggleHidden(); render(); attempt(hiding ? "Verstecken" : "Wieder zeigen", async () => { await p; toast(hiding ? "Karte versteckt" : "Karte wird wieder gezeigt"); }); });
      $("#trEdit", view)?.addEventListener("click", () => { if (trainer.current) editDialog(trainer.current, saved => { trainer.cards = FC.mergeCard(trainer.cards, saved); trainer.source = FC.mergeCard(trainer.source, saved); render(); }); });
      const card = $("#trCard", view); if (card) { bindSwipe(card); card.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); flip(); } }); }
      return;
    }
    if (!s) {
      $("#stNew", view)?.addEventListener("click", () => stackDialog(null));
      $$("[data-week]", view).forEach(b => b.onclick = () => { cardsWeek = b.dataset.week === "" ? null : Number(b.dataset.week); render(); });
      $$("[data-open]", view).forEach(a => a.onclick = e => { e.preventDefault(); cardsStack = +a.dataset.open; i = 0; shown = false; editing = null; render(); });
      // "Üben": heute faellige Karten (Leitner) zuerst, sonst frei im Trainer (Plan bleibt)
      $$("[data-play]", view).forEach(b => b.onclick = () => { const st = stacks.find(x => x.id === +b.dataset.play); if (!st) return;
        cardsStack = st.id; i = 0; shown = false; editing = null;
        if (FC.practiceMode(st) === "free") { trainerTitle = null; trainer.start(cards()); }
        render(); ($("#fc", view) || $("#trCard", view))?.focus(); });
      bindMenus();
      $$("[data-stedit]", view).forEach(b => b.onclick = () => stackDialog(stacks.find(x => x.id === +b.dataset.stedit)));
      $$("[data-stdel]", view).forEach(b => b.onclick = () => stackDeleteDialog(stacks.find(x => x.id === +b.dataset.stdel)));
      $("#wkFetch", view)?.addEventListener("click", () => weekFetchDialog(modules[0]?.id, cardsWeek > 0 ? cardsWeek : null));
      $("#aiOrder", view)?.addEventListener("click", () => openAiDialog({ modules, stacks, preset: { week: cardsWeek > 0 ? cardsWeek : undefined } }, () => reload().catch(e => toast(e.message, 4000))));
      $$("[data-reshare]", view).forEach(b => b.onclick = () => { const s = stacks.find(x => x.id === +b.dataset.reshare); if (s) attempt("Geteilte Kopie aktualisieren", async () => { const r = await api(`/flashcard-stacks/${s.id}/share`, { method: "PUT" }); toast(`Geteilte Kopie aktualisiert: ${r.cards} ${r.cards === 1 ? "Karte" : "Karten"}`); await reload(); }); });
      $$("[data-weekfetch]", view).forEach(b => b.onclick = () => weekFetchDialog(+b.dataset.weekfetch, cardsWeek));
      $$("[data-weekplay]", view).forEach(b => b.onclick = () => { const m = modules.find(x => x.id === +b.dataset.weekplay); if (!m) return;
        trainerTitle = `${m.name} · Woche ${cardsWeek} komplett`; trainer.start(FC.weekCompleteCards(all, stacks, m.name, cardsWeek)); render(); });
      $$("[data-share]", view).forEach(b => b.onclick = () => shareDialog(stacks.find(x => x.id === +b.dataset.share)));
      $$("[data-unshare]", view).forEach(b => b.onclick = () => { const s = stacks.find(x => x.id === +b.dataset.unshare); if (s && confirm(`Teilen von „${s.name}“ zurückziehen? Wer ihn schon übernommen hat, behält seine Kopie.`)) attempt("Teilen zurückziehen", async () => { await api(`/flashcard-stacks/${s.id}/share`, { method: "DELETE" }); toast("Teilen zurückgezogen"); await reload(); }); });
      const sharedById = id => sharedAll().find(x => x.id === id);
      $$("[data-shadopt]", view).forEach(b => b.onclick = () => attempt("Übernehmen", async () => { const r = await api(`/community/card-stacks/${b.dataset.shadopt}/adopt`, { method: "POST", body: {} }); toast(r.already ? "Schon übernommen" : `Übernommen: ${r.count} ${r.count === 1 ? "Karte" : "Karten"} – 0 Credits`); await reload(); }));
      $$("[data-shlike]", view).forEach(b => b.onclick = () => { const x = sharedById(b.dataset.shlike); if (x) attempt("Like", async () => { const r = await api(`/community/card-stacks/${x.id}/like`, { method: x.liked_by_me ? "DELETE" : "POST" }); Object.assign(x, { liked_by_me: r.liked, likes: r.likes }); }); });
      $$("[data-shreport]", view).forEach(b => b.onclick = () => { const x = sharedById(b.dataset.shreport); if (x) reportDialog(x); });
      return;
    }
    const reveal = () => { if (shown) return; shown = true; render(); $("#fc", view)?.focus(); };
    $("#fc")?.addEventListener("click", reveal); $("#fcShow", view)?.addEventListener("click", reveal);
    $("#fc")?.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); reveal(); } });
    $("#fcEdit", view)?.addEventListener("click", () => editDialog(c, () => render()));
    $("#fcW")?.addEventListener("click", () => judge(c, false));
    $("#fcR")?.addEventListener("click", () => judge(c, true));
    $("#fcPlay", view)?.addEventListener("click", () => { trainerTitle = null; trainer.start(cards()); render(); });
    $("#fcOpts", view)?.addEventListener("click", () => { trainer.start(cards()); render(); options(); });
    const flag = (cid, key) => { const card = all.find(x => x.id === +cid); if (!card) return; attempt(key === "hidden" ? "Verstecken" : "Lesezeichen", async () => { const saved = await api(`/flashcards/${cid}`, { method: "PATCH", body: { [key]: key === "hidden" ? !FC.isHidden(card) : !FC.isBookmarked(card) } }); Object.assign(card, { bookmarked: saved.bookmarked, hidden: saved.hidden }); if (key === "hidden") { dueAll = await api("/flashcards?due=true"); i = 0; shown = false; } }); };
    $$("[data-mark]", view).forEach(b => b.onclick = () => flag(b.dataset.mark, "bookmarked"));
    $$("[data-hide]", view).forEach(b => b.onclick = () => flag(b.dataset.hide, "hidden"));
    $$("[data-edit]", view).forEach(b => b.onclick = () => { editing = +b.dataset.edit; render(); $("[data-editform] textarea", view)?.focus(); });
    $$("[data-editcancel]", view).forEach(b => b.onclick = () => { editing = null; render(); });
    $$("[data-editform]", view).forEach(f => { const card = all.find(x => x.id === +f.dataset.editform); if (card) bindEditForm(f, card, async () => { await reload(); }); });
    $$("[data-delcard]", view).forEach(b => b.onclick = async () => { await api(`/flashcards/${b.dataset.delcard}`, { method: "DELETE" }); state.route(); });
  };
  // Tastatur im Trainer: ← nicht gewusst, → gewusst, Leertaste dreht, Strg/Cmd+Z = Vorherige (nicht in Eingabefeldern, nicht bei offenem Dialog)
  if (cardKeys) document.removeEventListener("keydown", cardKeys);
  cardKeys = e => {
    if (!view.isConnected) return;
    if (e.target.closest?.("input, textarea, select, [contenteditable]") || document.querySelector("#overlay .modal")) return;
    // Wiederholung (heute faellig): Leertaste deckt auf, danach → gewusst, ← nicht gewusst
    if ($("#fcRev", view) && !$("#fcTr", view)) {
      const plain = !e.metaKey && !e.ctrlKey && !e.altKey;
      if (e.key === " " && plain && !e.target.closest?.("button:not(#fc)")) { e.preventDefault(); if (!shown) { $("#fcShow", view)?.click(); } }
      else if (shown && plain && (e.key === "ArrowRight" || e.key === "ArrowLeft")) { e.preventDefault(); $(e.key === "ArrowRight" ? "#fcR" : "#fcW", view)?.click(); }
      return;
    }
    if (!$("#fcTr", view)) return;
    if (e.key === "ArrowRight" && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); answer(true); }
    else if (e.key === "ArrowLeft" && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); answer(false); }
    else if (e.key === " " && !e.target.closest?.("button")) { e.preventDefault(); flip(); }
    else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); previous(); }
    else if (e.key.toLowerCase() === "r" && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); askAgain(); }
  };
  document.addEventListener("keydown", cardKeys);
  render();
  loadShared().then(() => { if (view.isConnected && !trainer.active && shareAvail) render(); }).catch(() => {});
}

// ================================================================ UNI & NOTEN (Dienste, QIS-Notenspiegel, Zugänge)
const CRED_LIST = [["studip", "Stud.IP / WebSSO"], ["qis", "QIS (Prüfungsverwaltung)"], ["idm", "IDM Account-Manager"], ["ilias", "ILIAS"], ["mail", "E-Mail (LUIS)"], ["matrix", "Matrix-Chat"], ["luhki", "LUHKI"], ["gitlab", "GitLab"], ["hildesheim", "UNI-Account Hildesheim (CAS)"]];
const credListFor = uni => CRED_LIST.filter(([k]) => uni === "hildesheim" ? k === "hildesheim" : k !== "hildesheim");
const CRED_NAME = Object.fromEntries(CRED_LIST);
function credDialog(key, cur) {
  const mode = cur.own ? "own" : cur.same_as ? "same" : "none";
  const m = modal(`<h3>Zugang: ${CRED_NAME[key]}</h3><p class="muted small">Wird nur lokal in der .env gespeichert. ${key === "qis" ? "QIS braucht meist ein eigenes Passwort (nicht das WebSSO-Passwort)." : key === "idm" ? "Der Account-Manager nutzt in der Regel dasselbe Passwort wie QIS." : "Wenn der Dienst über WebSSO läuft, reicht „wie Stud.IP“."}</p>
    <div class="stack"><label class="chip" style="justify-content:flex-start;padding:.5rem .8rem;border-radius:10px"><input type="radio" name="cm" value="own" ${mode === "own" ? "checked" : ""} style="margin-right:.4rem"> Eigene Zugangsdaten</label>
      <div id="cmOwn" class="stack" style="padding-left:1.4rem"><label class="field" style="margin:.2rem 0">Benutzername<input class="input" id="cU" value="${esc(cur.user || "")}" autocomplete="username"></label><label class="field" style="margin:.2rem 0">Passwort<input class="input" type="password" id="cP" placeholder="${cur.own ? "•••••••• (leer lassen = behalten)" : ""}" autocomplete="current-password"></label></div>
      <label class="chip" style="justify-content:flex-start;padding:.5rem .8rem;border-radius:10px"><input type="radio" name="cm" value="same" ${mode === "same" ? "checked" : ""} style="margin-right:.4rem"> Gleiches Passwort wie <select class="input" id="cSame" style="width:auto;margin-left:.4rem">${CRED_LIST.filter(([k]) => k !== key).map(([k, n]) => `<option value="${k}" ${cur.same_as === k ? "selected" : ""}>${n}</option>`).join("")}</select></label>
      <label class="chip" style="justify-content:flex-start;padding:.5rem .8rem;border-radius:10px"><input type="radio" name="cm" value="none" ${mode === "none" ? "checked" : ""} style="margin-right:.4rem"> Nicht speichern</label></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="cOk">Speichern</button></div>`);
  $("#cOk", m).onclick = async () => {
    const sel = $("input[name=cm]:checked", m).value;
    try {
      if (sel === "none") await api(`/credentials/${key}`, { method: "PUT", body: { clear: true } });
      else if (sel === "same") await api(`/credentials/${key}`, { method: "PUT", body: { same_as: $("#cSame", m).value } });
      else { const u = $("#cU", m).value.trim(), p = $("#cP", m).value; if (!p && cur.own && u === cur.user) { m.remove(); return; } await api(`/credentials/${key}`, { method: "PUT", body: { user: u, password: p } }); }
      m.remove(); toast("Zugang gespeichert"); state.route();
    } catch (e) { toast(e.message, 4000); }
  };
}
export async function viewServices(parts, params, view) {
  const [svc, grades, tt] = await Promise.all([api("/services"), api("/grades"), api("/timetable/auto-status").catch(() => null)]);
  const q = svc.qis; const g = grades;
  view.innerHTML = `<div class="content" style="max-width:1120px"><div class="page-head"><div><h1>Uni & Noten</h1><div class="sub">Alle Dienste der ${esc(svc.university?.name || "Leibniz Universität Hannover")} an einem Ort, Notenspiegel direkt in der App.</div></div></div>
    <div class="grid cols-3" style="margin-bottom:1.2rem">
      <div class="card kpi" title="Bestandene, benotete ${g.basis === "module" ? "Module" : "Leistungen"}, nach Leistungspunkten gewichtet; wie in Prüfungsordnungen üblich nach der ersten Nachkommastelle abgeschnitten"><b>${g.average != null ? String(g.average.toFixed(1)).replace(".", ",") : "–"}</b><span>Aktueller Schnitt${g.average_exact != null ? ` · genau ${String(g.average_exact.toFixed(2)).replace(".", ",")} · ${g.graded_count} ${g.basis === "module" ? "benotete Module" : "Noten"}, ${String(g.graded_credits).replace(".", ",")} LP` : ""}</span></div>
      <div class="card kpi"><b>${String(g.credits || 0).replace(".", ",")} LP</b><span>aus ${g.passed} bestandenen ${g.basis === "module" ? "Modulen" : "Leistungen"}${g.failed_attempts ? ` · ${g.failed_attempts} nicht bestandene Versuche` : ""}</span></div>
      <div class="card kpi"><b>${g.last_run ? new Date(g.last_run.finished_at).toLocaleDateString("de-DE") : "–"}</b><span>${g.last_run ? (g.last_run.ok ? "zuletzt abgerufen" : "letzter Abruf fehlgeschlagen") : "noch nicht abgerufen"}</span></div></div>
    <div class="grid cols-3">
      <div class="card span-2"><div class="card-head"><h2>${icon("exam", 18)} Notenspiegel (${esc(svc.university?.grades_source || "QIS")})</h2><div class="actions"><button class="btn sm" id="qisCred">${icon("log-out", 14)} Zugang</button><button class="btn primary sm" id="qisSync">${icon("sync", 14)} ${svc.university?.key === "hildesheim" ? "Noten abrufen" : "Noten & Bescheinigungen abrufen"}</button></div></div>
        ${svc.university?.key === "hildesheim" ? (svc.qis.configured ? "" : `<div class="card flat" style="background:var(--accent-soft);border-color:transparent;margin-bottom:.8rem"><b>${icon("log-out", 14)} UNI-Account hinterlegen</b><div class="small muted" style="margin:.2rem 0 .5rem">Die Noten kommen aus dem LSF. Trage dafür einmal deinen UNI-Account unter Einstellungen → Zugang ein.</div><a class="btn sm primary" href="#/settings?tab=account">Zum Zugang</a></div>`) : !(svc.credentials?.qis?.own) ? `<div class="card flat" style="background:var(--accent-soft);border-color:transparent;margin-bottom:.8rem"><b>${icon("log-out", 14)} QIS-Zugang hinterlegen</b><div class="small muted" style="margin:.2rem 0 .5rem">QIS hat meist ein eigenes Passwort (nicht das WebSSO-Passwort). Einmal eintragen, danach holt die App Noten und Bescheinigungen selbst – ohne dass du dich einloggen musst.${svc.credentials?.qis?.same_as ? ` Aktuell: wie ${esc(svc.credentials.qis.same_as)}.` : ""}</div><div class="row wrap"><input class="input" id="qInlineU" placeholder="Benutzername (z. B. LUH-ID)" autocomplete="username" style="max-width:220px"><input class="input" type="password" id="qInlineP" placeholder="QIS-Passwort" autocomplete="current-password" style="max-width:220px"><button class="btn primary sm" id="qInlineOk">${icon("check", 14)} Speichern & abrufen</button></div></div>` : `<div class="small muted" style="margin-bottom:.6rem">Zugang gespeichert (${esc(svc.credentials.qis.user || "")}). Die App meldet sich selbst an und holt Notenspiegel, Bescheinigungen und Transcript of Records.</div>`}
        ${g.last_run && !g.last_run.ok ? `<div class="card flat" style="background:var(--bad-soft);border-color:transparent;margin-bottom:.6rem"><b>${icon("alert", 14)} ${esc(g.last_run.message)}</b><div class="muted small">Ein Screenshot der Seite liegt unter logs/qis-fehler.png. Mit „Noten abrufen (sichtbar)“ kannst du den Ablauf im Browserfenster verfolgen.</div><button class="btn sm" id="qisShow" style="margin-top:.4rem">Noten abrufen (sichtbar)</button></div>` : ""}
        ${g.bereiche?.length ? `<div class="row wrap" style="gap:.4rem;margin-bottom:.6rem">${g.bereiche.map(b => `<span class="chip" title="Bereich laut Notenspiegel">${esc(b.text)}${b.note ? ` · <b>${esc(b.note)}</b>` : ""}${b.credits ? ` · ${esc(b.credits)} LP` : ""}</span>`).join("")}</div>` : ""}
        ${g.grades.some(r => r.level === "pruefung") && g.grades.some(r => r.level === "modul") ? `<div class="seg" style="margin-bottom:.6rem"><button class="${state.gradesAll ? "" : "active"}" data-gview="mod">Module</button><button class="${state.gradesAll ? "active" : ""}" data-gview="all">Alle Prüfungen und Versuche</button></div>` : ""}
        ${g.grades.length ? `<table class="tbl"><tr><th>${state.gradesAll ? "Prüfung" : "Modul"}</th><th>Semester</th><th>Note</th><th>LP</th><th>Status</th><th>Versuch</th></tr>${g.grades.filter(r => r.level !== "bereich" && (state.gradesAll || r.level === "modul" || !g.grades.some(x => x.level === "modul"))).map(r => `<tr class="${r.level === "pruefung" ? "muted" : ""}"><td><b>${esc(r.text)}</b>${r.pruefungsnr || r.art ? `<div class="muted tiny">${esc([r.pruefungsnr, r.art].filter(Boolean).join(" · "))}</div>` : ""}</td><td class="small">${esc(r.semester_norm || r.semester || "")}</td><td><b>${esc(r.note || "–")}</b></td><td class="small">${esc(r.credits || "")}</td><td><span class="badge ${(r.status || "").toLowerCase().startsWith("be") ? "ok" : (r.status || "").toLowerCase().startsWith("ni") ? "bad" : "neutral"}">${esc(r.status || "–")}</span></td><td class="small">${esc(r.versuch || "")}</td></tr>`).join("")}</table>` : `<div class="empty small">${icon("exam", 30)}<div>Noch keine Noten geladen. Nach dem ersten Abruf erscheinen hier alle Prüfungsleistungen aus dem ${esc(svc.university?.grades_source || "QIS")}-Notenspiegel.</div></div>`}
        ${g.documents?.length ? `<h3 style="margin-top:1rem">Bescheinigungen & Transcript of Records</h3><div class="list">${g.documents.map(d => `<a class="item" href="/api/qis/documents/${d.id}" target="_blank">${icon("file-text", 16)}<div class="main"><div class="title">${esc(d.title)}</div><div class="sub">${fmtDate(d.fetched_at)}</div></div></a>`).join("")}</div>` : ""}
        <p class="muted tiny" style="margin-top:.8rem">${svc.university?.key === "hildesheim" ? "Die Noten werden mit deinem UNI-Account direkt aus dem LSF gelesen (Meine Funktionen → Notenspiegel)" : "Die Noten werden mit deinen Zugangsdaten direkt aus dem QIS-Portal gelesen (Prüfungsverwaltung → Notenspiegel)"} und nur lokal gespeichert. Prüfungsanmeldungen bleiben im Portal selbst.</p></div>
      <div class="stack">
        <div class="card"><div class="card-head"><h2>${icon("clock", 18)} Stundenplan</h2></div><p class="small">${tt ? `Vorlesungen und eindeutige Termine werden bei jedem Sync automatisch übernommen${tt.personal?.length ? `, dazu ${tt.personal.length} persönliche Einträge aus deinem Stud.IP-Stundenplan` : ""}.` : ""}</p>${tt?.pending_groups ? `<div class="card flat" style="background:var(--warn-soft);border-color:transparent"><b>${tt.courses.length} ${tt.courses.length === 1 ? "Fach" : "Fächer"} mit parallelen Übungsgruppen</b><div class="small muted">${tt.courses.map(esc).join(", ")}</div><div class="small" style="margin-top:.3rem">Trage deine Gruppe im Stud.IP-Stundenplan ein oder wähle sie hier unter Stundenplan → Importieren.</div></div>` : `<div class="small muted">Keine offenen Gruppenentscheidungen.</div>`}<a class="btn sm" style="margin-top:.5rem" href="#/timetable">${icon("calendar", 14)} Stundenplan öffnen</a></div>
        <div class="card"><div class="card-head"><h2>${icon("log-out", 18)} Zugänge</h2></div><div class="small">${credListFor(svc.university?.key).map(([k, n]) => { const c = svc.credentials?.[k] || {}; const st = k === "studip" || k === "hildesheim" ? (c.configured ? ["ok", k === "hildesheim" ? `gespeichert${c.user ? " · " + esc(c.user) : ""}` : "LUH-ID gespeichert"] : ["warn", "fehlt"]) : c.own ? ["ok", `eigener Zugang${c.user ? " · " + esc(c.user) : ""}`] : c.same_as ? ["info", `wie ${CRED_NAME[c.same_as] || c.same_as}`] : ["neutral", "nicht gesetzt"]; return `<div class="row between" style="padding:.35rem 0;border-bottom:1px solid var(--line)"><span>${n}</span><span class="row" style="gap:.35rem"><span class="badge ${st[0]}">${st[1]}</span>${k === "studip" || k === "hildesheim" ? `<a class="btn ghost icon sm" href="#/settings?tab=account" title="Bearbeiten">${icon("pencil", 13)}</a>` : `<button class="btn ghost icon sm" data-cred="${k}" title="Bearbeiten">${icon("pencil", 13)}</button>`}</span></div>`; }).join("")}</div><p class="muted tiny" style="margin-top:.6rem">${svc.university?.key === "hildesheim" ? "" : "Jeder Dienst kann ein eigenes Passwort haben oder auf einen anderen verweisen (z. B. IDM „wie QIS“). "}Alles liegt nur in der lokalen .env auf deinem PC. ${svc.university?.key === "hildesheim" ? "Genutzt werden Learnweb (Dateien) und LSF (Stundenplan, Noten), beide über den UNI-Account." : "Genutzt werden Stud.IP (Sync) und QIS (Noten); die übrigen merkst du dir hier als Übersicht."}</p></div>
      </div></div>
    <div id="bulletinHost"></div>
    <div class="card-head" style="margin-top:1.4rem"><h2>${icon("layers", 18)} Uni-Dienste</h2></div>
    <div class="grid auto">${svc.services.map(s => `<a class="card mod-card" style="--mc:var(--accent)" href="${s.url}" target="_blank" rel="noopener"><div class="row"><div class="color" style="width:34px;height:34px;border-radius:9px;background:var(--accent-soft);color:var(--accent-text);display:grid;place-items:center">${icon(s.icon || "file", 18)}</div><div class="name">${esc(s.name)}</div></div><div class="small muted">${esc(s.desc)}</div><div class="row between small"><span class="badge neutral">${esc(s.login)}</span>${s.connected ? `<span class="badge ok">synchronisiert</span>` : s.connector ? `<span class="badge info">Noten-Abruf</span>` : `<span class="muted">öffnen ↗</span>`}</div></a>`).join("")}</div></div>`;
  $$("[data-gview]", view).forEach(b => b.onclick = () => { state.gradesAll = b.dataset.gview === "all"; state.route(); });
  mountBulletin($("#bulletinHost", view), api);                      // Schwarzes Brett (nur lokal, nur mit Brett und Anzeigen)
  const sync = async show => { try { await api(`/grades/sync${show ? "?show=true" : ""}`, { method: "POST" }); toast("Notenspiegel wird abgerufen…"); window.pollBg?.(); } catch (e) { toast(e.message, 4000); } };
  $("#qisSync").onclick = () => sync(false);
  $("#qInlineOk")?.addEventListener("click", async () => { const u = $("#qInlineU").value.trim(), p = $("#qInlineP").value; if (!u || !p) return toast("Benutzername und Passwort eingeben"); try { await api("/credentials/qis", { method: "PUT", body: { user: u, password: p } }); toast("QIS-Zugang gespeichert"); await sync(false); state.route(); } catch (e) { toast(e.message, 4000); } }); $("#qisShow")?.addEventListener("click", () => sync(true));
  $$("[data-cred]", view).forEach(b => b.onclick = () => credDialog(b.dataset.cred, svc.credentials?.[b.dataset.cred] || {}));
  $("#qisCred").onclick = () => svc.university?.key === "hildesheim" ? (location.hash = "#/settings?tab=account") : credDialog("qis", svc.credentials?.qis || {});
}

// ================================================================ COMMUNITY
const SOL_STATUS = { active: ["ok", "veröffentlicht"], withdrawn: ["neutral", "zurückgezogen"], hidden: ["warn", "verborgen (Meldungen)"], removed: ["bad", "entfernt"] };
const REPORT_TXT = { foreignMaterial: "Fremdmaterial", gradedSubmission: "benotete Abgabe", offensive: "anstößig", spam: "Spam", other: "Sonstiges" };
const solRow = (s, actions) => `<tr><td><b>${esc(s.title || s.display_name || "Lösung")}</b>${s.title && s.display_name ? `<div class="tiny muted">${esc(s.display_name)}</div>` : ""}</td><td class="small">${s.pages} von ${s.page_count} Seiten</td><td class="small">${fmtDate(s.published_at)}</td><td class="small">${s.downloads}×</td><td><span class="badge ${SOL_STATUS[s.status]?.[0] || "neutral"}">${SOL_STATUS[s.status]?.[1] || esc(s.status)}</span></td><td class="row" style="gap:.3rem;justify-content:flex-end">${actions}</td></tr>`;
export async function viewCommunity(_, params, view) {
  const r = await fetch("/api/community/info");
  const head = `<div class="page-head"><div><h1>Community</h1><div class="sub">Lösungen zu deinen Übungsblättern – gleiches Konto auf Windows und iPad.</div></div></div>`;
  if (r.status === 501 || r.status === 409 || r.status === 502) {
    // Windows-App: Community ueber das StudiNow-Konto (app/service_link.py); 409 = nicht verbunden/andere Hochschule
    const d = await r.json().catch(() => ({}));
    view.innerHTML = `<div class="content" style="max-width:860px">${head}
      <div class="card"><div class="card-head"><h2>${icon("user", 18)} StudiNow-Konto</h2></div><div id="slCard"></div>${d.code && d.code !== "not_linked" ? `<p class="small" style="margin-top:.6rem">${icon("alert", 13)} ${esc(d.detail || "")}</p>` : ""}</div>
      <div class="card"><div class="card-head"><h2>${icon("info", 18)} Was du damit kannst</h2></div><ul class="small muted" style="margin:0"><li>Im PDF-Editor (Knopf ${icon("users", 13)}) die Lösungen anderer zu derselben PDF sehen und als eigene Ebene über deine Seite legen</li><li>Liken und an einer Stelle der Seite kommentieren, mit Antworten</li><li>Eigene Notizen als Lösung teilen – verschlüsselt, nur lesbar mit derselben Original-PDF</li><li>Gilt mit demselben Konto auf dem iPad; nur innerhalb deiner Hochschule</li></ul></div></div>`;
    const { renderLinkCard } = await import("./studora-link.js?v=7");
    renderLinkCard($("#slCard", view), { onChange: () => state.route() });
    return;
  }
  if (!r.ok) { view.innerHTML = `<div class="content"><div class="card"><span class="badge bad">Community nicht erreichbar (${r.status})</span></div></div>`; return; }
  const info = await r.json();
  // Seite einer Community (03.11.2026): Kanal nach Lehrwoche, Diskussion, Dokumente (app/static/community-channel.js)
  if (params?.space) return (await import("./community-channel.js?v=10")).renderSpacePage(view, params, info);
  // Reiter (28.10.2026): Uebersicht, Fragen je Kurs, Gemerkt, Mitteilungen (app/static/views-qa.js)
  const tab = params?.tab || "overview";
  const tabs = `<div class="seg qa-tabs" role="tablist">${[["overview", "Übersicht"], ["questions", "Fragen"], ["bookmarks", "Gemerkt"], ["notify", "Mitteilungen"]].map(([k, l]) => `<button role="tab" aria-selected="${tab === k}" class="${tab === k ? "active" : ""}" data-ctab="${k}">${l}</button>`).join("")}</div>`;
  const bindTabs = () => $$("[data-ctab]", view).forEach(b => b.onclick = () => { location.hash = b.dataset.ctab === "overview" ? "#/community" : `#/community?tab=${b.dataset.ctab}`; });
  if (tab !== "overview") {
    view.innerHTML = `<div class="content" style="max-width:960px">${head}${tabs}<div class="card" id="qaPanel"></div></div>`;
    bindTabs();
    const q = await import("./views-qa.js?v=8"); const el = $("#qaPanel", view);
    if (tab === "questions") q.renderQuestions(el); else if (tab === "bookmarks") q.renderBookmarks(el); else q.renderNotifications(el, n => window.updateBell?.(n));
    return;
  }
  const [mine, blocks, mod] = await Promise.all([api("/community/mine"), api("/community/blocks"), info.admin ? api("/community/moderation") : Promise.resolve(null)]);
  const run = async (fn, msg) => { try { await fn(); if (msg) toast(msg); state.route(); } catch (e) { toast(e.message, 4000); } };
  view.innerHTML = `<div class="content" style="max-width:960px"><div class="page-head"><div><h1>Community</h1><div class="sub">Lösungen zu deinen Übungsblättern – geteilt auf Windows und dem iPad.</div></div><div class="row"><span class="badge neutral" title="Dein Name in der Community">${icon("user", 12)} ${esc(info.pseudonym)}</span>${info.plan_ok ? `<span class="badge ok">StudiNow Plus</span>` : `<span class="badge warn">StudiNow Plus nötig</span>`}</div></div>
    ${tabs}
    <div id="ccInboxAll"></div>
    <div class="card"><div class="card-head"><h2>${icon("info", 18)} So funktioniert es</h2></div><ul class="small muted" style="margin:0">
      <li>Jeder Kurs ist eine Community. Tritt bei und öffne sie: Dort findest du die Notizen nach Lehrwoche und die Diskussion.</li>
      <li>Fehlt dir etwas in einer fremden Lösung? Mit „Korrektur vorschlagen“ markierst du es in deiner PDF; der Ersteller bekommt einen Hinweis.</li>
      <li>Hast du dieselbe PDF, liegt eine Lösung über deiner PDF. Sonst liest du sie auf leeren Seiten.</li>
      <li>Du erscheinst nur als <b>${esc(info.pseudonym)}</b>. Ab ${info.reports_to_hide} Meldungen ist eine Lösung verborgen, bis die Moderation entscheidet.</li>
      <li>Veröffentlichen, projizieren, liken und kommentieren passiert im PDF-Editor: in der Windows-App über den Knopf ${icon("users", 13)}, auf dem iPad über „Lösung teilen“ / „Lösungen vergleichen“.</li></ul></div>
    <div class="card"><div class="card-head"><h2>${icon("users", 18)} Deine Communities</h2></div><div id="spacesCard"></div></div>
    ${state.hosted ? "" : `<div class="card"><div class="card-head"><h2>${icon("user", 18)} StudiNow-Konto auf diesem PC</h2></div><div id="slCard"></div></div>`}
    <div class="card"><div class="card-head"><h2>${icon("layers", 18)} Meine Veröffentlichungen</h2><span class="badge neutral">${mine.solutions.length}</span></div>
      ${mine.solutions.length ? `<table class="tbl"><tr><th>Lösung</th><th>Umfang</th><th>Veröffentlicht</th><th>Geladen</th><th>Status</th><th></th></tr>${mine.solutions.map(s => solRow(s, s.status === "active" || s.status === "hidden" ? `<button class="btn sm" data-withdraw="${s.solution_id}">${icon("x", 13)} Zurückziehen</button>` : "")).join("")}</table>` : `<p class="muted small" style="margin:0">Noch nichts veröffentlicht. Öffne ein Übungsblatt aus deinem Abgleich im Editor und wähle Community → Teilen (iPad: „Lösung teilen“).</p>`}</div>
    <div class="card"><div class="card-head"><h2>${icon("x", 18)} Gesperrte Autoren</h2><span class="badge neutral">${blocks.blocked.length}</span></div>
      ${blocks.blocked.length ? `<div class="row wrap">${blocks.blocked.map(p => `<span class="chip">${esc(p)} <button class="btn ghost icon sm" data-unblock="${esc(p)}" title="Sperre aufheben">${icon("x", 12)}</button></span>`).join("")}</div>` : `<p class="muted small" style="margin:0">Niemand gesperrt. Lösungen eines gesperrten Autors siehst du nicht mehr – sperren geht in der Community-Leiste des Editors.</p>`}</div>
    ${mod ? `<div class="card"><div class="card-head"><h2>${icon("settings", 18)} Moderation</h2><span class="badge ${mod.solutions.some(s => s.status === "hidden") ? "warn" : "neutral"}">${mod.solutions.length} gemeldet oder gesperrt</span></div>
      ${mod.solutions.length ? `<table class="tbl"><tr><th>Lösung</th><th>Umfang</th><th>Veröffentlicht</th><th>Geladen</th><th>Status</th><th></th></tr>${mod.solutions.map(s => solRow(s, `<span class="tiny muted" style="flex:1">${esc(s.pseudonym)}${s.author_banned ? " · Autor gesperrt" : ""}<br>${s.reports.map(x => esc(REPORT_TXT[x.reason] || x.reason) + (x.note ? `: ${esc(x.note)}` : "")).join(" · ")}</span>${s.status === "active" ? `<button class="btn sm" data-mod="hide" data-id="${s.solution_id}">Verbergen</button>` : ""}${s.status === "hidden" || s.status === "removed" ? `<button class="btn sm" data-mod="restore" data-id="${s.solution_id}">Wiederherstellen</button>` : ""}${s.status !== "removed" ? `<button class="btn sm" data-mod="remove" data-id="${s.solution_id}">Entfernen</button>` : ""}${s.author_banned ? `<button class="btn sm" data-mod="unban_author" data-id="${s.solution_id}">Autor freigeben</button>` : `<button class="btn sm danger" data-mod="ban_author" data-id="${s.solution_id}">Autor sperren</button>`}`)).join("")}</table>` : `<p class="muted small" style="margin:0">Keine Meldungen offen.</p>`}</div>` : ""}</div>`;
  bindTabs();
  import("./community-spaces.js?v=19").then(m => m.renderSpaces($("#spacesCard", view)));
  Promise.all([import("./community-logic.js?v=2"), import("./community-corrections-ui.js?v=5")]).then(([L, U]) => { L.ensureCss(); U.renderInbox($("#ccInboxAll", view), { toast, onChange: () => state.route() }); });
  if (!state.hosted && $("#slCard", view)) import("./studora-link.js?v=7").then(m => m.renderLinkCard($("#slCard", view), { onChange: () => state.route() }));
  $$("[data-withdraw]", view).forEach(b => b.onclick = () => { if (confirm("Lösung zurückziehen? Andere können sie dann nicht mehr laden.")) run(() => api(`/community/solutions/${b.dataset.withdraw}`, { method: "DELETE" }), "Lösung zurückgezogen"); });
  $$("[data-unblock]", view).forEach(b => b.onclick = () => run(() => api(`/community/blocks/${encodeURIComponent(b.dataset.unblock)}`, { method: "DELETE" }), "Sperre aufgehoben"));
  $$("[data-mod]", view).forEach(b => b.onclick = () => { const a = b.dataset.mod; if ((a === "remove" || a === "ban_author") && !confirm(a === "remove" ? "Lösung endgültig entfernen?" : "Autor sperren? Alle seine Lösungen werden entfernt.")) return; run(() => api(`/community/solutions/${b.dataset.id}/moderate`, { method: "POST", body: { action: a } }), "Moderation gespeichert"); });
}

// ================================================================ EINSTELLUNGEN
function diagTab() {
  const errs = state.errors || []; const info = [`Browser: ${navigator.userAgent}`, `Fenster: ${innerWidth}×${innerHeight}, Pixelverhältnis ${devicePixelRatio}`, `Design: ${document.documentElement.dataset.theme || "auto"}`, `Adresse: ${location.origin}`, `Module-Version: v=29`, `Fehler in dieser Sitzung: ${errs.length}`];
  return `<div class="card"><div class="card-head"><h2>${icon("info", 18)} Diagnose</h2><button class="btn sm" id="diagCopy">${icon("copy", 14)} Kopieren</button></div><pre id="diagText" class="small" style="white-space:pre-wrap;background:var(--surface-2);padding:.7rem;border-radius:var(--r-sm)">${esc(info.join("\n"))}${errs.length ? "\n\n" + esc(errs.map(e => `${e.t.slice(11, 19)} ${e.src ? "[" + e.src + "] " : ""}${e.msg}`).join("\n")) : ""}</pre>
    <div class="card-head" style="margin-top:1rem"><h2>${icon("book", 18)} Demo-Inhalte</h2><button class="btn sm" id="demoToggle">…</button></div><p class="muted small" id="demoText">Ein Demo-Modul mit drei PDFs, Stundenplan, Lernkalender, einer Frist und einer Ankündigung – zum Ausprobieren ohne Hochschulkonto und für die App-Prüfung. Lässt sich jederzeit wieder entfernen.</p>
    <div class="card-head" style="margin-top:1rem"><h2>${icon("file-text", 18)} PDF-Anzeige testen</h2><button class="btn sm primary" id="diagTest">Test starten</button></div><p class="muted small">Lädt eine PDF aus deiner Bibliothek, liest sie mit pdf.js und zeichnet Seite 1 – genau wie der Editor. Wenn hier ein Bild erscheint, funktioniert die Anzeige in diesem Browser.</p><div id="diagOut" class="small"></div></div>`;
}

// ChatGPT verbinden (eigener PC): Sign in with ChatGPT, Token nur auf diesem Rechner (app/chatgpt_login.py). Im Dienst
// zeigt die Karte den ehrlichen Stand "noch nicht freigegeben".
function chatgptCard(gpt, models) {
  if (!gpt) return "";
  const head = `<div class="card-head"><h2>${icon("sparkles", 18)} KI über mein ChatGPT</h2><span class="badge ${gpt.connected ? (gpt.needs_reauth ? "warn" : gpt.sharing ? "ok" : "warn") : "neutral"}">${gpt.connected ? (gpt.needs_reauth ? "neu anmelden" : gpt.sharing ? "verbunden" : "ohne Abo-Nutzung") : gpt.available ? "nicht verbunden" : "noch nicht verfügbar"}</span></div>`;
  if (!gpt.available) return `<div class="card">${head}<p class="small muted">Die offizielle ChatGPT-Verbindung ist für den Dienst noch nicht von OpenAI freigegeben. Auf dem eigenen PC kannst du dein ChatGPT-Konto schon verbinden.</p></div>`;
  const pending = gpt.pending ? `<p class="small" style="color:var(--accent)">${icon("clock", 13)} Anmeldung läuft im Browser … (Port ${gpt.pending.port})</p>` : "";
  const err = gpt.last_error ? `<p class="small" style="color:var(--bad)">${esc(gpt.last_error)}</p>` : "";
  if (!gpt.connected) return `<div class="card">${head}
      <p class="small muted">Verbinde dein eigenes ChatGPT-Konto (Plus, Pro oder Go): Erklärungen im Editor, Analyse der Unterlagen und Lernpläne laufen dann über dein Abo statt über Claude. StudiNow bekommt nur Name und E-Mail und ein Zugriffstoken, nie dein Passwort und nie deine Chats. Das Token bleibt auf diesem Rechner.</p>
      ${pending}${err}<div class="row wrap"><button class="btn primary sm" id="gptConnect" ${gpt.pending ? "disabled" : ""}>${icon("log-out", 14)} ChatGPT verbinden</button>${gpt.pending ? `<button class="btn sm" id="gptOpen">Anmeldeseite erneut öffnen</button>` : ""}</div></div>`;
  const who = gpt.email || gpt.name || "ChatGPT-Konto";
  const options = (models && models.length ? models : [gpt.model].filter(Boolean)).map(m => `<option value="${esc(m)}" ${m === gpt.model ? "selected" : ""}>${esc(m)}</option>`).join("");
  return `<div class="card">${head}
      <p class="small">Verbunden als <b>${esc(who)}</b>${gpt.sharing ? "" : ` – <span style="color:var(--warn-text)">die Nutzung deines Abos in Apps ist nicht freigegeben</span>`}.</p>
      ${gpt.sharing ? "" : `<p class="small muted">Ohne Freigabe laufen keine KI-Anfragen über dein Abo. „Freigabe nachholen“ öffnet die Zustimmungsseite von OpenAI noch einmal.</p>`}
      ${gpt.needs_reauth ? `<p class="small" style="color:var(--warn)">Die Anmeldung ist abgelaufen – bitte neu verbinden.</p>` : ""}${err}
      <div class="row wrap" style="align-items:center;gap:.6rem">
        <label class="field" style="margin:0;flex:1">Modell<select class="input" id="gptModel">${options || `<option value="">(Modelle laden …)</option>`}</select></label>
        <label class="small"><input type="checkbox" id="gptUse" ${gpt.use_for_ai ? "checked" : ""}> KI-Anfragen über mein ChatGPT</label></div>
      ${!gpt.model ? `<p class="small muted">Bitte ein Modell wählen, sonst bleibt Claude aktiv.</p>` : ""}
      <p class="small muted">Verbrauch zählt gegen dein ChatGPT-Kontingent; das Wochenlimit für StudiNow setzt du in ChatGPT unter Einstellungen → Nutzung (<a href="${esc(gpt.usage_help_url || "https://chatgpt.com/settings/usage")}" target="_blank" rel="noopener">Nutzung verwalten</a>).</p>
      <div class="row wrap"><button class="btn sm" id="gptReconnect">${icon("refresh", 14)} Neu verbinden</button>${gpt.sharing ? "" : `<button class="btn primary sm" id="gptReconsent">Freigabe nachholen</button>`}<button class="btn ghost sm" id="gptOther">Anderes Konto verbinden</button><button class="btn ghost sm" id="gptDisconnect">Trennen</button></div></div>`;
}

export async function viewSettings(_, params, view) {
  const gpt = await api("/integrations/chatgpt").catch(() => null);
  const gptModels = gpt?.connected && !gpt.needs_reauth ? await api("/integrations/chatgpt/models").then(r => r.models).catch(() => null) : null;
  const [s, courses, mods, log, cred, term, svc, sess, older] = await Promise.all([api("/settings"), api("/courses"), api("/modules"), api("/sync/status"), api("/credentials"), api("/terms"), api("/services"), state.hosted ? null : api("/university/session").catch(() => null), api("/older-semesters").catch(() => null)]);
  const uniKey = svc.university?.key || "luh";
  let tab = params.tab === "diag" ? "advanced" : (params.tab || "modules"); let openMod = null;
  const render = () => {
    if (tab === "abo") { location.hash = "#/abo"; return; }   // Abo & Tarife hat eine eigene Seite
    const activeMods = mods.filter(m => m.active !== 0);
    const modulesCard = `<div class="card set-mods"><div class="card-head"><h2>${icon("book", 18)} Module & Wochentests</h2><span class="badge ok">${activeMods.length} aktiv</span></div>
      <div class="row wrap" style="margin:.6rem 0"><label class="field" style="margin:0"><input type="checkbox" id="sAutoTests" ${s.auto_tests ? "checked" : ""}> Gemeinsamen Wochentest pro Modul automatisch erstellen</label><span class="spacer"></span><label class="field" style="margin:0;display:flex;align-items:center;gap:.5rem">Standard-Testdauer <div class="seg">${[15, 30, 60].map(n => `<button class="${s.test_minutes == n ? "active" : ""}" data-tmin="${n}">${n} Min.</button>`).join("")}<button class="${![15, 30, 60].includes(+s.test_minutes) ? "active" : ""}" data-tmin="custom">Eigene</button></div></label></div>
      ${settingHtml(older)}
      <div class="stack">${mods.map(m => { const cs = courses.filter(c => c.module_id === m.id); const open = openMod === m.id; return `<div class="card flat ${m.active === 0 ? "muted" : ""}" style="padding:.7rem .9rem"><div class="row wrap" data-open="${m.id}" style="cursor:pointer"><span class="dot" style="background:${m.color};width:12px;height:12px"></span><b style="flex:1">${esc(m.name)}</b><span class="muted small">${cs.length} Kurse</span><span class="badge ${m.weekly_test === 0 ? "neutral" : "ok"}">${m.weekly_test === 0 ? "kein Wochentest" : `1 gemeinsamer Test pro Woche${m.test_minutes ? ` · ${m.test_minutes} min` : ""}`}</span><label class="small" style="margin:0" title="Modul einplanen"><input type="checkbox" data-active="${m.id}" ${m.active !== 0 ? "checked" : ""}> aktiv</label><button class="btn ghost icon sm" data-edit="${m.id}" title="Bearbeiten" aria-label="Bearbeiten">${icon("settings", 14)}</button>${icon(open ? "chevron-down" : "chevron-right", 16)}</div>
        ${open ? `<div style="margin-top:.6rem;border-top:1px solid var(--line);padding-top:.5rem"><table class="tbl"><tr><th>Stud.IP-Kurs</th><th>Semester</th><th>Art</th><th>Modul</th></tr>${cs.map(c => `<tr class="${c.active === 0 ? "muted" : ""}"><td><label class="small" style="margin:0;display:flex;gap:.4rem;align-items:center" title="${c.active === 0 ? "Früheres Semester – nicht eingeplant. Einschalten, wenn du den Kurs doch brauchst." : "Eingeplant"}"><input type="checkbox" data-cactive="${c.id}" ${c.active !== 0 ? "checked" : ""}> ${esc(c.title)}</label></td><td class="small muted">${esc(c.semester || "")}</td><td><select class="input" data-kind="${c.id}" style="width:auto">${Object.entries(KIND_TXT).filter(([k]) => ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar", "sonstiges"].includes(k)).map(([k, l]) => `<option value="${k}" ${c.kind === k ? "selected" : ""}>${l}</option>`).join("")}</select></td><td><select class="input" data-mod="${c.id}" aria-label="Modul zuordnen" style="width:auto">${mods.map(x => `<option value="${x.id}" ${c.module_id === x.id ? "selected" : ""}>${esc(shortName(x.name))}</option>`).join("")}<option value="">– kein Modul –</option></select></td></tr>`).join("") || `<tr><td colspan="4" class="muted">Keine Kurse zugeordnet.</td></tr>`}</table></div>` : ""}</div>`; }).join("")}
      ${courses.filter(c => !c.module_id && c.id !== "__user__").length ? `<div class="card flat" style="padding:.7rem .9rem"><b class="muted">Ohne Modul (nicht eingeplant)</b>${courses.filter(c => !c.module_id && c.id !== "__user__").map(c => `<div class="row small" style="margin-top:.4rem"><span style="flex:1">${esc(c.title)}</span><select class="input" data-mod="${c.id}" aria-label="Modul zuordnen" style="width:auto"><option value="">– kein Modul –</option>${mods.map(x => `<option value="${x.id}">${esc(shortName(x.name))}</option>`).join("")}</select></div>`).join("")}</div>` : ""}</div>
      <div class="row wrap" style="margin-top:.8rem"><button class="chip" id="newModBtn">${icon("plus", 13)} Modul anlegen</button><button class="chip" id="autoAssign">${icon("sparkles", 13)} Zuordnung automatisch prüfen</button></div>
      <p class="muted small" style="margin-top:.8rem">Ein Modul fasst mehrere Stud.IP-Kurse zusammen (Vorlesung, Hörsaalübung, Gruppenübung …). Kurse aus früheren Semestern erkennt die App am Semester in Stud.IP und plant sie nicht ein; ihre Unterlagen bleiben in der Bibliothek. Pro Modul und Lehrwoche entsteht höchstens <b>ein gemeinsamer Wochentest</b>, und nur wenn in der Woche neue Inhalte vorliegen.</p>
      <p class="muted small" style="margin-top:.8rem"><b>Deine Einstellungen:</b> ${activeMods.filter(m => m.weekly_test !== 0).length} Wochentests in einer Woche mit neuen Inhalten in allen aktiven Modulen, jeweils ${s.test_minutes} Minuten. Vorlesungen und sämtliche zugehörigen Übungen werden gemeinsam berücksichtigt.</p></div>`;
    // Erster Bildschirm: Semester, Lernzeiten und Modulliste nebeneinander (Design 3)
    const semesterCard = `<div class="card set-card"><div class="card-head"><h2>${icon("calendar", 18)} Semester</h2></div>
        <div class="set-term"><label class="field set-term-name">Name<input class="input" id="tName" value="${esc(term.name)}"></label><label class="field">Beginn<input class="input" type="date" id="tStart" value="${term.start}"></label><label class="field">Ende<input class="input" type="date" id="tEnd" value="${term.end}"></label></div>
        <button class="btn sm primary" id="tSave">Speichern</button></div>`;
    const freeDays = (s.free_days || []).map(d => DAYS[d]).join(", ") || "keine";
    const lernCard = long => `<div class="card set-card"><div class="card-head"><h2>${icon("clock", 18)} Lernzeiten</h2></div>
        ${long ? `<p class="muted small">Lernkombination (Fächer pro Tag, Vorlesung/Übungen/Wochentest) und persönliche Verfügbarkeit (Lernzeiten, Fahrtzeit, Sperrzeiten).</p>` : ""}
        <dl class="set-facts"><dt>Lernfenster</dt><dd>${s.learn_start}–${s.learn_end}</dd><dt>Pro Tag</dt><dd>${fmtMin(s.minutes_per_day)}, ${s.subjects_per_day} ${+s.subjects_per_day === 1 ? "Fach" : "Fächer"}</dd><dt>Freie Tage</dt><dd>${freeDays}</dd><dt>Fahrtzeit</dt><dd>${s.travel_minutes} min</dd></dl>
        <div class="set-actions"><button class="btn sm" id="openCfg">${icon("settings", 14)} Lernkombination</button><button class="btn sm" id="openAvail">${icon("clock", 14)} Verfügbarkeit & Sperrzeiten</button></div></div>`;
    const modulesTab = `<div class="set2"><div class="set2-main">${modulesCard}</div><div class="set2-side">${semesterCard}${lernCard(false)}</div></div>`;
    const planTab = `<div class="set2 set2-single">${lernCard(true)}</div>`;
    const loginCard = state.hosted ? "" : `<div class="card"><div class="card-head"><h2>${icon("log-out", 18)} ${uniKey === "hildesheim" ? "Learnweb-Anmeldung" : "Stud.IP-Anmeldung"}</h2>${sess?.session ? `<span class="badge ok">Sitzung gemerkt</span>` : `<span class="badge warn">nicht angemeldet</span>`}</div>
        <p class="muted small">Du meldest dich im Browserfenster selbst an${uniKey === "hildesheim" ? " (UNI-Account über das CAS)" : " (LUH-ID über das WebSSO)"}. Das Passwort merkt sich der Browser, wenn du das dort erlaubst – die App speichert nur die Sitzung und holt damit Dateien und Termine, bis die Hochschule sie beendet. Dann einfach erneut anmelden.${sess?.saved_at ? ` Zuletzt angemeldet: ${new Date(sess.saved_at).toLocaleString("de-DE", { dateStyle: "short", timeStyle: "short" })}.` : ""}</p>
        <div class="row"><button class="btn primary sm" id="uniLogin">${icon("log-out", 14)} Im Browser anmelden</button>${sess?.session ? `<button class="btn ghost sm" id="uniForget">Sitzung vergessen</button>` : ""}<button class="btn sm" id="testSync2">Dateien jetzt holen (ohne KI)</button><span class="spacer"></span><button class="btn ghost sm danger" id="uniReset" title="Alles von diesem Account auf diesem PC löschen, damit sich ein anderer Account anmelden kann">${icon("trash-2", 14)} Konto entfernen</button></div></div>`;
    const credText = state.hosted
      ? `Mit deinen Zugangsdaten meldet sich <b>der StudiNow-Dienst</b> um 8 und 15 Uhr bei deiner Hochschule an und lädt neue Unterlagen in dein Konto – auch wenn du nicht angemeldet bist. Die Zugangsdaten liegen verschlüsselt in deinem Konto, nie in der App; du kannst sie jederzeit löschen. Ohne Zugangsdaten lädst du deine Unterlagen selbst hoch.${cred.consent_at ? ` Zugestimmt am ${new Date(cred.consent_at).toLocaleDateString("de-DE")}.` : ""}`
      : "Nur nötig, wenn der Abgleich um 8 und 15 Uhr auch nach Ablauf der Sitzung ohne Nachfrage laufen soll. Liegt nur in der lokalen .env – lass es leer, wenn die App dein Passwort nicht kennen soll.";
    const credCard = `<div class="card"><div class="card-head"><h2>${icon("log-out", 18)} Zugangsdaten (optional)</h2>${cred.user && cred.password_set ? `<span class="badge ok">gespeichert</span>` : `<span class="badge neutral">leer</span>`}</div><p class="muted small">${credText}</p>
        <label class="field">LUH-ID<input class="input" id="credUser" value="${esc(cred.user || "")}" autocomplete="username"></label><label class="field">WebSSO-Passwort<input class="input" id="credPass" type="password" placeholder="${cred.password_set ? "•••••••• (leer lassen = behalten)" : "noch nicht gesetzt"}" autocomplete="current-password"></label>
        ${state.hosted ? `<label class="small" style="display:flex;gap:.5rem;align-items:flex-start;margin:.4rem 0"><input type="checkbox" id="credConsent" ${cred.consent_at ? "checked" : ""}> <span>Ich stimme zu, dass sich der StudiNow-Dienst mit diesen Zugangsdaten bei meiner Hochschule anmeldet und meine Unterlagen in mein Konto lädt. Ich kann die Zugangsdaten jederzeit löschen (<a href="/datenschutz" target="_blank" rel="noopener">Datenschutz</a>).</span></label>` : ""}
        <div class="row wrap"><button class="btn primary sm" id="saveCred">Zugang speichern</button><button class="btn sm" id="testSync">Dateien jetzt holen (ohne KI)</button>${state.hosted && cred.password_set ? `<button class="btn ghost sm danger" id="clearCred">Zugangsdaten löschen</button>` : ""}</div></div>`;
    const looksCard = `<div class="card"><div class="card-head"><h2>${icon("user", 18)} Anzeigename</h2></div><div class="row"><input class="input" id="sName" value="${esc(s.user_name || "")}" placeholder="z. B. Ahmad H." style="max-width:260px"><button class="btn sm" id="sNameOk">Speichern</button></div>
        <div class="card-head" style="margin-top:1rem"><h2>${icon("sun", 18)} Darstellung</h2></div><div class="seg">${[["auto", "Automatisch"], ["light", "Hell"], ["dark", "Dunkel"]].map(([k, l]) => `<button class="${(document.documentElement.dataset.theme || "auto") === k ? "active" : ""}" data-theme="${k}">${l}</button>`).join("")}</div>
        <div class="card-head" style="margin-top:1rem"><h2>${icon("pen", 18)} Stift & Touch</h2></div><select class="input" id="sPen" style="width:auto"><option value="all" ${s.pen_input === "all" ? "selected" : ""}>Finger darf schreiben (Handballen wird bei Stift ignoriert)</option><option value="pen_only" ${s.pen_input === "pen_only" ? "selected" : ""}>Nur Stift schreibt, Finger navigiert</option></select>
        <div class="card-head" style="margin-top:1rem"><h2>${icon("hand", 18)} Schreibhand</h2></div><div class="seg">${[["right", "Rechtshänder"], ["left", "Linkshänder"]].map(([k, l]) => `<button class="${(s.hand || "right") === k ? "active" : ""}" data-hand="${k}">${l}</button>`).join("")}</div><p class="muted tiny" style="margin-top:.4rem">Geteilte Ansicht: Das Skript öffnet auf der Seite der freien Hand (35 %), das Übungsblatt daneben.</p></div>`;
    const ipadCard = `<div class="card span-2" id="ipadCard"><div class="card-head"><h2>${icon("columns", 18)} Auf dem iPad benutzen</h2><span class="badge neutral" id="lanBadge">…</span></div><div id="ipadBody" class="small muted">Netzwerk wird geprüft…</div></div>`;
    const logCard = `<div class="card span-2"><div class="card-head"><h2>${icon("sync", 18)} Sync-Protokoll</h2><label class="small"><input type="checkbox" id="sAutoPlan" ${s.auto_plan ? "checked" : ""}> Lernkalender nach dem Sync automatisch auffüllen</label></div><div class="small" style="max-height:200px;overflow:auto">${log.log.map(l => `<div><span style="color:var(--${l.ok ? "ok" : "bad"}-text)">${icon(l.ok ? "check" : "x", 14)}</span> ${new Date(l.started_at).toLocaleString("de-DE")} – ${esc((l.message || "").slice(0, 90))}</div>`).join("") || `<span class="muted">Noch kein Sync.</span>`}</div></div>`;
    const hi = svc.credentials?.hildesheim || {};
    const uniCard = `<div class="card span-2"><div class="card-head"><h2>${icon("book", 18)} Hochschule</h2><span class="badge neutral">${esc(svc.university?.files_source || "")} + ${esc(svc.university?.grades_source || "")}</span></div>
        <div class="row wrap"><select class="input" id="uniSel" style="width:auto">${(svc.universities || []).map(u => `<option value="${u.key}" ${u.key === (svc.university_next || uniKey) ? "selected" : ""}>${esc(u.name)}</option>`).join("")}</select>
        <span class="muted small" style="flex:1">${uniKey === "hildesheim" ? "Dateien aus dem Learnweb, Stundenplan und Noten aus dem LSF, Anmeldung über den UNI-Account (CAS)." : "Dateien und Termine aus Stud.IP, Noten aus dem QIS, Anmeldung über das WebSSO."}</span></div>
        ${svc.university_next && svc.university_next !== uniKey ? `<div class="card flat" style="background:var(--warn-soft, var(--accent-soft));border-color:transparent;margin-top:.6rem"><b>${icon("info", 14)} Neustart nötig</b><div class="small">Vorgemerkt: ${esc((svc.universities || []).find(u => u.key === svc.university_next)?.name || svc.university_next)}. Nach einem Neustart der App sind deren Daten aktiv.</div></div>` : ""}
        <p class="muted tiny" style="margin-top:.5rem">Jede Hochschule hat einen eigenen Datenordner: Kurse, Dateien, Noten und Anmeldungen werden nie gemischt.</p></div>`;
    const hiCard = `<div class="card"><div class="card-head"><h2>${icon("log-out", 18)} UNI-Account (optional)</h2>${hi.configured ? `<span class="badge ok">gespeichert</span>` : `<span class="badge neutral">leer</span>`}</div><p class="muted small">Nur nötig, wenn der Abgleich um 8 und 15 Uhr auch nach Ablauf der Sitzung ohne Nachfrage laufen soll (Learnweb und LSF über das CAS). Liegt nur in der lokalen .env – lass es leer, wenn die App dein Passwort nicht kennen soll.</p>
        <label class="field">Zugangskennung<input class="input" id="hiUser" value="${esc(hi.user || "")}" autocomplete="username"></label><label class="field">Passwort<input class="input" id="hiPass" type="password" placeholder="${hi.configured ? "•••••••• (leer lassen = behalten)" : "noch nicht gesetzt"}" autocomplete="current-password"></label>
        <div class="row"><button class="btn primary sm" id="hiSave">Zugang speichern</button><button class="btn sm" id="testSync">Dateien jetzt holen (ohne KI)</button></div>
        <div class="card-head" style="margin-top:1rem"><h2>${icon("settings", 18)} Learnweb-Schlüssel</h2>${svc.learnweb?.token_set ? `<span class="badge ok">gesetzt</span>` : `<span class="badge neutral">optional</span>`}</div>
        <p class="muted small">Mit Schlüssel holt die App die Dateien direkt über die Moodle-Schnittstelle, ohne Browser-Anmeldung, und Moodle markiert nichts als angesehen. Erzeugen: im Learnweb Profil → Einstellungen → Sicherheitsschlüssel → „Moodle mobile web service“.</p>
        <div class="row"><input class="input" id="lwToken" type="password" placeholder="${svc.learnweb?.token_set ? "•••••••• (neu eingeben zum Ersetzen)" : "Schlüssel einfügen"}" autocomplete="off" style="flex:1"><button class="btn sm" id="lwSave">Speichern</button>${svc.learnweb?.token_set ? `<button class="btn ghost sm" id="lwClear">Entfernen</button>` : ""}</div></div>`;
    const accountTab = `<div class="grid cols-2">${uniCard}${loginCard}${uniKey === "hildesheim" ? hiCard : credCard}${looksCard}${ipadCard}${installCard()}</div>`; const advancedTab = `<div class="stack">${chatgptCard(gpt, gptModels)}${logCard}${diagTab()}</div>`;
    view.innerHTML = `<div class="content set-page" style="max-width:1180px"><div class="page-head"><div><h1>Einstellungen</h1></div></div>
      <div class="set-layout"><nav class="set-nav">${[["modules", "Module & Wochentests", "book"], ["plan", "Lernzeit & Verfügbarkeit", "clock"], ["account", "Zugang & Darstellung", "user"], ["abo", "Abo & Tarife", "star"], ["advanced", "Erweitert", "settings"]].map(([k, l, i]) => `<button class="${tab === k ? "active" : ""}" data-tab="${k}">${icon(i, 16)}<span>${l}</span></button>`).join("")}</nav><div class="set-body">
      ${tab === "modules" ? modulesTab : tab === "account" ? accountTab : tab === "advanced" ? advancedTab : planTab}</div></div></div>`;
    $$("[data-tab]", view).forEach(b => b.onclick = () => { tab = b.dataset.tab; render(); });
    // ChatGPT verbinden: Browser oeffnet sich, danach den Stand abfragen, bis die Anmeldung durch ist
    const gptWait = () => { let n = 0; const t = setInterval(async () => { const g = await api("/integrations/chatgpt").catch(() => null); if (!g || ++n > 300 || (!g.pending && (g.connected || g.last_error))) { clearInterval(t); if (g?.connected) toast("ChatGPT verbunden"); else if (g?.last_error) toast(g.last_error, 5000); state.route(); } }, 2000); };
    $("#gptConnect")?.addEventListener("click", async () => { try { await api("/integrations/chatgpt/connect", { method: "POST", body: {} }); toast("Anmeldeseite öffnet sich im Browser", 4000); state.route(); gptWait(); } catch (e) { toast(e.message, 5000); } });
    $("#gptReconnect")?.addEventListener("click", async () => { try { await api("/integrations/chatgpt/connect", { method: "POST", body: {} }); toast("Anmeldeseite öffnet sich im Browser", 4000); gptWait(); } catch (e) { toast(e.message, 5000); } });
    $("#gptReconsent")?.addEventListener("click", async () => { try { await api("/integrations/chatgpt/connect", { method: "POST", body: { reconsent: true } }); toast("Zustimmungsseite öffnet sich im Browser", 4000); gptWait(); } catch (e) { toast(e.message, 5000); } });
    $("#gptOther")?.addEventListener("click", async () => { if (!confirm("Anderes ChatGPT-Konto verbinden? Die bisherige Verbindung wird gelöscht und StudiNow registriert sich bei OpenAI neu.")) return; try { await api("/integrations/chatgpt/connect", { method: "POST", body: { new_account: true } }); toast("Anmeldeseite öffnet sich im Browser", 4000); state.route(); gptWait(); } catch (e) { toast(e.message, 5000); } });
    $("#gptOpen")?.addEventListener("click", async () => { try { const r = await api("/integrations/chatgpt/connect", { method: "POST", body: {} }); toast("Anmeldeseite geöffnet"); if (!r.auth_url) return; } catch (e) { toast(e.message, 5000); } });
    $("#gptDisconnect")?.addEventListener("click", async () => { if (!confirm("ChatGPT trennen? Das Zugriffstoken wird gelöscht; KI-Anfragen laufen wieder über Claude.")) return; await api("/integrations/chatgpt/disconnect", { method: "POST", body: {} }); toast("Getrennt"); state.route(); });
    $("#gptModel")?.addEventListener("change", async e => { try { await api("/integrations/chatgpt/settings", { method: "PUT", body: { model: e.target.value } }); toast("Modell gespeichert"); } catch (x) { toast(x.message, 4000); } });
    $("#gptUse")?.addEventListener("change", async e => { await api("/integrations/chatgpt/settings", { method: "PUT", body: { use_for_ai: e.target.checked } }); toast(e.target.checked ? "KI läuft über dein ChatGPT" : "KI läuft über Claude"); });
    $$("[data-open]", view).forEach(el => el.onclick = e => { if (e.target.closest("input, button, select, label")) return; openMod = openMod === +el.dataset.open ? null : +el.dataset.open; render(); });
    $$("[data-edit]", view).forEach(b => b.onclick = () => editModule(mods.find(m => m.id === +b.dataset.edit), () => state.route()));
    $$("[data-active]", view).forEach(c => c.onchange = async () => { await api(`/modules/${c.dataset.active}`, { method: "PATCH", body: { active: c.checked ? 1 : 0 } }); toast("Gespeichert"); state.route(); });
    $$("[data-tmin]", view).forEach(b => b.onclick = async () => { let v = b.dataset.tmin; if (v === "custom") { v = prompt("Testdauer in Minuten:", s.test_minutes); if (!v) return; } await api("/settings", { method: "PUT", body: { test_minutes: +v } }); toast("Testdauer gespeichert"); state.route(); });
    bindOlderSetting(view);
    $("#sAutoTests")?.addEventListener("change", async e => { await api("/settings", { method: "PUT", body: { auto_tests: e.target.checked } }); toast("Gespeichert"); });
    $("#sAutoPlan")?.addEventListener("change", async e => { await api("/settings", { method: "PUT", body: { auto_plan: e.target.checked } }); toast("Gespeichert"); });
    $$("[data-mod]", view).forEach(el => el.onchange = async () => { await api(`/courses/${el.dataset.mod}/module`, { method: "POST", body: { module_id: el.value ? +el.value : null } }); toast("Zuordnung gespeichert"); state.route(); });
    $$("[data-cactive]", view).forEach(el => el.onchange = async () => { await api(`/courses/${el.dataset.cactive}`, { method: "PATCH", body: { active: el.checked ? 1 : 0 } }); toast(el.checked ? "Kurs eingeplant" : "Kurs nicht mehr eingeplant"); state.route(); });
    $$("[data-kind]", view).forEach(el => el.onchange = async () => { await api(`/courses/${el.dataset.kind}`, { method: "PATCH", body: { kind: el.value } }); toast("Gespeichert"); });
    $("#newModBtn")?.addEventListener("click", () => { const m = modal(`<h3>Neues Modul</h3><label class="field">Name<input class="input" id="nmName"></label><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="nmOk">Anlegen</button></div>`); $("#nmOk", m).onclick = async () => { await api("/modules", { method: "POST", body: { name: $("#nmName", m).value } }); m.remove(); state.route(); }; });
    $("#autoAssign")?.addEventListener("click", async () => { const r = await api("/modules/auto-assign", { method: "POST" }); toast(`${r.assigned} Kurse zugeordnet${r.uncertain.length ? `, ${r.uncertain.length} unsicher` : ""}`); if (r.uncertain.length) modal(`<h3>Unsichere Zuordnungen</h3><p class="muted small">Bitte unter dem jeweiligen Modul prüfen.</p><ul class="small">${r.uncertain.map(u => `<li>${esc(u.title)} → ${esc(u.suggestion || "kein Vorschlag")}</li>`).join("")}</ul><div class="modal-foot"><button class="btn primary" data-close>OK</button></div>`); state.route(); });
    $("#uniLogin")?.addEventListener("click", async () => { try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden", 4000); window.pollBg?.(); const t = setInterval(async () => { const r = await api("/university/session").catch(() => null); if (!r || r.window?.state !== "open") { clearInterval(t); if (r?.window?.state === "ok") toast("Angemeldet, Sitzung gemerkt"); state.route(); } }, 2000); } catch (e) { toast(e.message, 4000); } });
    $("#uniReset")?.addEventListener("click", () => {
      const m = modal(`<h3>Hochschul-Konto entfernen</h3><p class="small">Löscht auf diesem PC endgültig: die Anmeldung und gemerkte Sitzung, gespeicherte Zugangsdaten, alle Kurse, Dateien, Notizen, Karteikarten, Tests, Lernpläne, Stundenplan, Noten, die ChatGPT-Verbindung und die Sicherungen. Danach ist die App leer und ein anderer Account kann sich anmelden.</p><p class="small"><b>Das lässt sich nicht rückgängig machen.</b></p><label class="field" style="flex-direction:row;align-items:center;gap:.5rem"><input type="checkbox" id="rsOk"> Ja, alles von diesem PC löschen</label><div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary danger" id="rsGo" disabled>Konto entfernen</button></div>`);
      $("#rsOk", m).onchange = e => { $("#rsGo", m).disabled = !e.target.checked; };
      $("#rsGo", m).onclick = async () => { $("#rsGo", m).disabled = true; $("#rsGo", m).textContent = "Wird gelöscht…"; try { await api("/university/reset", { method: "POST" }); try { localStorage.clear(); sessionStorage.clear(); } catch { /* egal */ } toast("Konto entfernt, alle Daten gelöscht. Die App startet leer.", 5000); setTimeout(() => { location.hash = "#/"; location.reload(); }, 900); } catch (e) { toast(e.message, 6000); $("#rsGo", m).disabled = false; $("#rsGo", m).textContent = "Konto entfernen"; } };
    });
    $("#uniForget")?.addEventListener("click", async () => { try { await api("/university/session", { method: "DELETE" }); toast("Sitzung vergessen"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#testSync2")?.addEventListener("click", async () => { try { await api("/sync?ai=false", { method: "POST" }); toast("Dateien werden geholt…"); window.pollBg?.(); } catch (e) { toast(e.message); } });
    $("#saveCred")?.addEventListener("click", async () => { if (state.hosted && !$("#credConsent")?.checked) { toast("Bitte zuerst der Anmeldung durch den Dienst zustimmen", 5000); return; } try { await api("/credentials", { method: "PUT", body: { user: $("#credUser").value, password: $("#credPass").value, consent: state.hosted ? !!$("#credConsent")?.checked : undefined } }); toast("Zugang gespeichert"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#clearCred")?.addEventListener("click", async () => { if (!confirm("Zugangsdaten löschen? Der Dienst gleicht dann nicht mehr automatisch ab; deine Unterlagen bleiben.")) return; try { await api("/credentials/clear", { method: "POST", body: {} }); toast("Zugangsdaten gelöscht"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#uniSel")?.addEventListener("change", async e => { const v = e.target.value; const cur = svc.university_next || uniKey; if (v === cur) return; if (!confirm("Hochschule wechseln? Jede Uni hat ihre eigenen Daten. Nach einem Neustart der App öffnest du die Daten der gewählten Uni. Die bisherigen Daten bleiben getrennt erhalten.")) { e.target.value = cur; return; } try { await api("/settings", { method: "PUT", body: { university: v } }); toast("Gespeichert. Bitte die App neu starten.", 6000); state.route(); } catch (err) { toast(err.message, 4000); e.target.value = cur; } });
    $("#hiSave")?.addEventListener("click", async () => { const u = $("#hiUser").value.trim(), p = $("#hiPass").value; if (!u) return toast("Zugangskennung eingeben"); if (!p) return toast(hi.configured && hi.user === u ? "Unverändert" : "Passwort eingeben"); try { await api("/credentials/hildesheim", { method: "PUT", body: { user: u, password: p } }); toast("UNI-Account gespeichert"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#lwSave")?.addEventListener("click", async () => { const t = $("#lwToken").value.trim(); if (!t) return toast("Schlüssel einfügen"); try { await api("/learnweb/token", { method: "PUT", body: { token: t } }); toast("Learnweb-Schlüssel gespeichert"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#lwClear")?.addEventListener("click", async () => { try { await api("/learnweb/token", { method: "PUT", body: { clear: true } }); toast("Schlüssel entfernt"); state.route(); } catch (e) { toast(e.message, 4000); } });
    $("#testSync")?.addEventListener("click", async () => { try { await api("/sync?ai=false", { method: "POST" }); toast("Dateien werden geholt…"); window.pollBg?.(); } catch (e) { toast(e.message); } });
    $("#tSave")?.addEventListener("click", async () => { await api("/terms", { method: "PUT", body: { name: $("#tName").value, start: $("#tStart").value, end: $("#tEnd").value } }); toast("Semester gespeichert"); });
    $$("[data-theme]", view).forEach(b => b.onclick = () => { window.setTheme?.(b.dataset.theme); render(); });
    $("#sPen")?.addEventListener("change", async e => { await api("/settings", { method: "PUT", body: { pen_input: e.target.value } }); toast("Gespeichert"); });
    if ($("#ipadCard")) api("/network").then(net => {
      // Antwort kann nach einem Neuaufbau der Ansicht (z. B. nach "Speichern") ankommen: dann gibt es die Elemente nicht mehr
      if (!$("#lanBadge") || !$("#ipadBody")) return;
      $("#lanBadge").className = `badge ${net.lan ? "ok" : "warn"}`; $("#lanBadge").textContent = net.lan ? "WLAN-Zugriff aktiv" : "nur auf diesem PC";
      $("#ipadBody").className = "small"; $("#ipadBody").innerHTML = `
        <ol style="padding-left:1.2rem;margin:.2rem 0 .6rem;display:grid;gap:.45rem">
          <li><b>Einmalig Firewall freigeben</b> (PowerShell als Administrator):<pre style="margin:.3rem 0;background:var(--surface-2);padding:.5rem .7rem;border-radius:8px;white-space:pre-wrap">netsh advfirewall firewall add rule name="StudIP-LernApp" dir=in action=allow protocol=TCP localport=${net.port}</pre></li>
          <li><b>Server im WLAN-Modus starten</b> (im Projektordner):<pre style="margin:.3rem 0;background:var(--surface-2);padding:.5rem .7rem;border-radius:8px;white-space:pre-wrap">.venv\\Scripts\\python.exe serve.py --lan</pre>${net.lan ? `<span style="color:var(--ok-text)">${icon("check", 13)} läuft gerade im WLAN-Modus</span>` : `<span class="muted">Aktuell ist der Server nur auf diesem PC erreichbar.</span>`}</li>
          <li><b>iPad im selben WLAN</b> in Safari öffnen: ${net.urls.length ? net.urls.map(u => `<a href="${u}" target="_blank" style="font-weight:600">${u}</a>`).join(" &nbsp;oder&nbsp; ") : "<i>keine WLAN-Adresse gefunden</i>"}</li>
          <li><b>PIN eingeben:</b> <span style="font-size:1.3rem;font-weight:700;letter-spacing:.2em;color:var(--accent-text)">${net.pin}</span> <span class="muted">(gilt nur für andere Geräte, wird gespeichert)</span></li>
          <li>Safari → Teilen-Symbol → <b>„Zum Home-Bildschirm“</b>: Die App startet dann im Vollbild wie eine echte iPad-App. Apple Pencil schreibt direkt im Editor (Einstellung „Nur Stift schreibt“ unter Stift & Touch).</li>
        </ol>
        <div class="card flat" style="background:var(--warn-soft);border-color:transparent"><b>${icon("alert", 14)} Im Uni-WLAN (eduroam)</b> sehen sich Geräte meist nicht. Dann am PC den <b>Mobilen Hotspot</b> einschalten (Windows-Einstellungen → Netzwerk → Mobiler Hotspot) und das iPad damit verbinden. Die Adresse ist dann in der Regel <b>http://192.168.137.1:${net.port}</b>.</div>`;
    }).catch(() => { const b = $("#ipadBody"); if (b) b.textContent = "Netzwerkinfo nicht verfügbar."; });
    $$("[data-hand]", view).forEach(b => b.onclick = async () => { await api("/settings", { method: "PUT", body: { hand: b.dataset.hand } }); s.hand = b.dataset.hand; toast("Schreibhand gespeichert"); render(); });
    $("#sNameOk")?.addEventListener("click", async () => { await api("/settings", { method: "PUT", body: { user_name: $("#sName").value } }); toast("Gespeichert"); location.reload(); });
    $("#diagCopy")?.addEventListener("click", () => { navigator.clipboard?.writeText($("#diagText").textContent).then(() => toast("Diagnose kopiert")); });
    const demoBtn = $("#demoToggle");
    if (demoBtn) {
      const showDemo = d => { demoBtn.textContent = d.enabled ? "Demo-Inhalte entfernen" : "Demo-Inhalte anlegen"; demoBtn.dataset.on = d.enabled ? "1" : "0"; };
      api("/demo").then(showDemo).catch(() => { demoBtn.disabled = true; });
      demoBtn.onclick = async () => { demoBtn.disabled = true; try { const d = await api("/demo", { method: "POST", body: { enabled: demoBtn.dataset.on !== "1" } }); showDemo(d); toast(d.enabled ? `Demo angelegt: ${d.files} PDFs, ${d.events} Termine, ${d.packages} Lernpakete` : "Demo-Inhalte entfernt"); } catch (e) { toast(e.message, 4000); } demoBtn.disabled = false; };
    }
    $("#diagTest")?.addEventListener("click", async () => { const out = $("#diagOut"); out.textContent = "Prüfe…"; const lines = []; try { const f = (await api("/library")).files.find(x => x.kind === "pdf" && x.downloaded_at); if (!f) { out.textContent = "Keine PDF vorhanden."; return; } const r = await fetch(`/api/files/${f.id}/content`); lines.push(`PDF-Abruf: HTTP ${r.status}, Typ ${r.headers.get("content-type")}`); const pdfjs = await import("./vendor/pdf.min.mjs?v=3"); pdfjs.GlobalWorkerOptions.workerSrc = "./vendor/pdf.worker.min.mjs?v=3"; const doc = await pdfjs.getDocument({ data: await r.arrayBuffer() }).promise; lines.push(`pdf.js: ${doc.numPages} Seiten gelesen`); const page = await doc.getPage(1); const vp = page.getViewport({ scale: 1 }); const cv = document.createElement("canvas"); cv.width = vp.width; cv.height = vp.height; await page.render({ canvasContext: cv.getContext("2d"), viewport: vp }).promise; lines.push(`Canvas: Seite 1 gerendert (${Math.round(vp.width)}×${Math.round(vp.height)})`); lines.push(`Konva: ${typeof window.Konva !== "undefined" ? "geladen" : "nicht geladen (wird erst im Editor geladen)"}`); out.innerHTML = `<div style="color:var(--ok-text)">${icon("check", 15)} ${lines.join("<br>")}</div><img src="${cv.toDataURL()}" style="max-width:220px;border:1px solid var(--line);margin-top:.5rem">`; } catch (e) { lines.push(`Fehler: ${e.message}`); out.innerHTML = `<div style="color:var(--bad)">${lines.join("<br>")}</div>`; } });
    $("#openCfg")?.addEventListener("click", async () => (await import("./views-plan.js?v=48")).configDialog(() => state.route()));
    $("#openAvail")?.addEventListener("click", async () => (await import("./views-plan.js?v=48")).availabilityDialog());
  };
  render();
}

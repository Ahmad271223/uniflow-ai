// Dialog "Wochentest erstellen" wie auf dem iPad (QuizComposer.swift, 03./04.11.2026): Modul, Lehrwoche (oder die neuesten
// Unterlagen), Dauer, Zahl der Aufgaben (5/10/15/20), Schwierigkeit, Aufgabenarten (Multiple Choice, Wahr/Falsch,
// Lueckentext, Kurzantwort, Rechnen/Programmieren), Thema oder Hinweis, die Unterlagen, die einfliessen, und ehrlich,
// ob ein gemeinsamer Test moeglich ist. Gesendet wird POST /api/tests/generate (app/server.py, ai.week_test_options).
// Nur die Standardeinstellung (15 Aufgaben, beliebig, alle Arten, kein Thema) kann ein gemeinsamer Test sein; jede
// Abweichung ist ein eigener Test mit der KI des Nutzers und wird so beschriftet. Regeln ohne DOM:
// tests/js/week-test-dialog.test.mjs.

export const COUNTS = [5, 10, 15, 20];
export const DURATIONS = [15, 30, 45, 60, 90];
export const LEVELS = [["beliebig", "Beliebig"], ["leicht", "Leicht"], ["mittel", "Mittel"], ["schwer", "Schwer"]];
export const TYPE_LABELS = [["mc", "Multiple Choice"], ["tf", "Wahr / Falsch"], ["cloze", "Lückentext"], ["short", "Kurzantwort"], ["calc", "Rechnen / Programmieren"]];
export const ALL_TYPES = TYPE_LABELS.map(t => t[0]);
export const TOPIC_CHARS = 300;
const DIFFICULTY = { leicht: 4, mittel: 6, schwer: 5 };       // wie ai.WEEK_TEST_DIFFICULTY (4/6/5 = 15)

export const defaultSettings = () => ({ count: 15, difficulty: "beliebig", types: [...ALL_TYPES], topic: "" });

/** Art an- oder abwaehlen; die letzte bleibt an, die Reihenfolge ist die des Dienstes */
export function toggleType(types, type) {
  if (types.includes(type)) return types.length > 1 ? types.filter(t => t !== type) : types;
  return ALL_TYPES.filter(t => t === type || types.includes(t));
}

/** Nur die Standardeinstellung kann ein gemeinsamer Test sein (ai.week_test_is_standard) */
export const isStandard = s => s.count === 15 && s.difficulty === "beliebig" && s.types.length === ALL_TYPES.length && !String(s.topic || "").trim();

/** Schwierigkeiten je Zahl der Aufgaben (ai.week_test_distribution): eine feste Stufe bekommt alle, "beliebig" verteilt 4/6/5
 *  nach Hare-Niemeyer (groesster Rest, bei Gleichstand leicht, mittel, schwer) */
export function distribution(count, difficulty) {
  const keys = Object.keys(DIFFICULTY), total = 15;
  if (difficulty !== "beliebig") return Object.fromEntries(keys.map(k => [k, k === difficulty ? count : 0]));
  const base = Object.fromEntries(keys.map(k => [k, Math.floor(count * DIFFICULTY[k] / total)]));
  const order = [...keys].sort((a, b) => (count * DIFFICULTY[b] % total) - (count * DIFFICULTY[a] % total) || keys.indexOf(a) - keys.indexOf(b));
  let rest = count - Object.values(base).reduce((a, b) => a + b, 0);
  for (const k of order) { if (rest-- <= 0) break; base[k]++; }
  return base;
}

/** "15 Aufgaben · 4 leicht · 6 mittel · 5 schwer" bzw. "10 Aufgaben · alle schwer" */
export function composition(s) {
  if (s.difficulty === "beliebig") { const d = distribution(s.count, "beliebig"); return `${s.count} Aufgaben · ${Object.keys(d).map(k => `${d[k]} ${k}`).join(" · ")}`; }
  return `${s.count} Aufgaben · alle ${s.difficulty}`;
}
export const shareBadge = s => (isStandard(s) ? "Gemeinsamer Test möglich" : "Eigener Test, nicht geteilt");
export const shareNote = s => (isStandard(s)
  ? "Standardeinstellung: Gibt es für dieses Modul schon einen gemeinsamen Test (höchstens 3 Varianten je Lehrwoche), bekommst du eine Variante ohne neue KI-Anfrage."
  : "Eigener Test, nicht geteilt: Mit eigenen Einstellungen erstellt deine KI den Test nur für dich; gemeinsame Varianten gibt es nur in der Standardeinstellung.");
export const costLine = s => `1 Anfrage an die KI${isStandard(s) ? " · bei gemeinsamem Test 0 Credits" : " · eigener Test"}`;

/** Rumpf fuer POST /api/tests/generate: Modul, Dauer, Lehrwoche (nur wenn gewaehlt) und die Parameter des Dienstes */
export function body({ moduleId, duration, week, settings }) {
  const b = { module_id: Number(moduleId), duration_min: Number(duration) };
  if (Number(week) > 0) b.week_no = Number(week);
  return { ...b, count: settings.count, difficulty: settings.difficulty, types: ALL_TYPES.filter(t => settings.types.includes(t)), topic: String(settings.topic || "").trim().slice(0, TOPIC_CHARS) };
}

/** Lehrwochen mit Unterlagen (Vorlesung, Skript, Uebung, Loesung), neueste zuerst */
export const weeksOf = detail => (detail?.weeks || []).filter(w => w.week >= 1 && materialsOf(w).length).sort((a, b) => b.week - a.week);
/** Unterlagen einer Woche in der Reihenfolge des Dienstes, hoechstens 10 */
export const materialsOf = w => [...(w?.vorlesungen || []), ...(w?.skripte || []), ...(w?.uebungen || []), ...(w?.loesungen || [])].slice(0, 10);
export const DOC_LABEL = { vorlesung: "Vorlesung", uebung: "Übung", loesung: "Lösung", skript: "Skript", klausur: "Klausur" };
export const docLabel = t => DOC_LABEL[t] || "Unterlage";
export const weekLabel = w => `${w.label || `Lehrwoche ${w.week}`}${w.topic ? ` · ${w.topic}` : ""}`;

/** Auswahl "Modul/Woche" aus dem Hash der Tests-Seite: #/exams?neu=<Modul> */
export const wantsDialog = params => (params && params.neu !== undefined ? { moduleId: Number(params.neu) || 0 } : null);

// ---------------------------------------------------------------- Dialog
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Dialog oeffnen. deps: { api, modal, icon, toast, modules, moduleId, onStarted } (aus views-misc.js) */
export function openWeekTestDialog({ api, modal, icon, toast, modules, moduleId = 0, onStarted = () => {} }) {
  const st = { module: moduleId || (modules.length === 1 ? modules[0].id : 0), week: 0, duration: 30, s: defaultSettings(), detail: null, busy: false };
  const m = modal(`<h3>${icon("exam", 18)} Wochentest erstellen</h3><form id="wtForm" class="wt-form" autocomplete="off">
    <label class="field"><span>Modul</span><select id="wtMod" class="input" aria-label="Modul">${st.module ? "" : `<option value="0">– Modul wählen –</option>`}${modules.map(x => `<option value="${x.id}"${x.id === st.module ? " selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label>
    <label class="field"><span>Lehrwoche</span><select id="wtWeek" class="input" aria-label="Lehrwoche"><option value="0">Neueste Unterlagen des Moduls</option></select></label>
    <div class="field"><span>Dauer</span><div class="wt-chips" id="wtDur" role="radiogroup" aria-label="Dauer"></div></div>
    <div class="field"><span>Aufgaben</span><div class="wt-chips" id="wtCount" role="radiogroup" aria-label="Zahl der Aufgaben"></div></div>
    <div class="field"><span>Schwierigkeit</span><div class="wt-chips" id="wtLevel" role="radiogroup" aria-label="Schwierigkeit"></div></div>
    <div class="field"><span>Aufgabenarten (mindestens eine)</span><div class="wt-chips" id="wtTypes" role="group" aria-label="Aufgabenarten"></div></div>
    <label class="field"><span>Thema oder Hinweise (optional)</span><input id="wtTopic" class="input" maxlength="${TOPIC_CHARS}" placeholder="z. B. nur Kapitel 3, mehr Beweise, ohne Programmieren"></label>
    <div class="field"><span>Aufbau</span><div class="wt-chips"><span class="badge info" id="wtComp"></span><span class="badge" id="wtShare"></span></div></div>
    <div class="field"><span>Unterlagen, die einfließen</span><div id="wtMat" class="small muted"></div></div>
    <p class="small muted" style="margin:.4rem 0 0">${icon("sparkles", 13)} <span id="wtCost"></span></p><p class="small muted" id="wtNote" style="margin:.2rem 0 0"></p>
    <div class="ed-err small" id="wtErr" role="alert" hidden></div>
    <div class="modal-foot"><button class="btn" type="button" data-close>Abbrechen</button><button class="btn primary" type="submit" id="wtGo">${icon("sparkles", 14)} Test erstellen</button></div></form>`);
  const $ = s => m.querySelector(s);
  const chips = (host, list, isOn, onPick, role) => {
    host.innerHTML = list.map(([v, label]) => `<button type="button" class="chip${isOn(v) ? " on" : ""}" role="${role}" aria-checked="${isOn(v)}" data-v="${esc(v)}">${isOn(v) && role === "checkbox" ? icon("check", 12) + " " : ""}${esc(label)}</button>`).join("");
    host.querySelectorAll("[data-v]").forEach(b => b.onclick = () => onPick(b.dataset.v));
  };
  function draw() {
    chips($("#wtDur"), DURATIONS.map(d => [d, `${d} min`]), v => +v === st.duration, v => { st.duration = +v; draw(); }, "radio");
    chips($("#wtCount"), COUNTS.map(n => [n, String(n)]), v => +v === st.s.count, v => { st.s.count = +v; draw(); }, "radio");
    chips($("#wtLevel"), LEVELS, v => v === st.s.difficulty, v => { st.s.difficulty = v; draw(); }, "radio");
    chips($("#wtTypes"), TYPE_LABELS, v => st.s.types.includes(v), v => { st.s.types = toggleType(st.s.types, v); draw(); }, "checkbox");
    $("#wtComp").textContent = composition(st.s);
    const sh = $("#wtShare"); sh.textContent = shareBadge(st.s); sh.className = `badge ${isStandard(st.s) ? "info" : "neutral"}`;
    $("#wtCost").textContent = costLine(st.s); $("#wtNote").textContent = shareNote(st.s);
    const weeks = weeksOf(st.detail), sel = $("#wtWeek");
    sel.innerHTML = `<option value="0">Neueste Unterlagen des Moduls</option>` + weeks.map(w => `<option value="${w.week}"${w.week === st.week ? " selected" : ""}>${esc(weekLabel(w))}</option>`).join("");
    const w = weeks.find(x => x.week === st.week);
    $("#wtMat").innerHTML = !st.module ? "Wähle ein Modul." : w ? `<ul class="wt-mat">${materialsOf(w).map(f => `<li>${icon("check", 13)} ${esc(f.ai_title || f.title || f.name || "")} <span class="badge neutral">${esc(docLabel(f.doc_type))}</span></li>`).join("")}</ul>`
      : st.detail ? "Die 8 neuesten Unterlagen des Moduls (ohne Organisatorisches)." : "Unterlagen werden geladen …";
    $("#wtGo").disabled = st.busy || !st.module;
  }
  async function loadDetail() {
    st.detail = null; draw();
    if (!st.module) return;
    try { st.detail = await api(`/modules/${st.module}`); } catch { st.detail = { weeks: [] }; }
    const weeks = weeksOf(st.detail);
    if (!weeks.some(w => w.week === st.week)) st.week = weeks[0]?.week || 0;       // wie auf dem iPad: die neueste Woche vorwaehlen
    draw();
  }
  $("#wtMod").onchange = e => { st.module = +e.target.value; st.week = 0; loadDetail(); };
  $("#wtWeek").onchange = e => { st.week = +e.target.value; draw(); };
  $("#wtTopic").oninput = e => { st.s.topic = e.target.value; draw(); };
  $("#wtForm").onsubmit = async e => {
    e.preventDefault(); if (st.busy || !st.module) return;
    st.busy = true; draw(); $("#wtErr").hidden = true;
    try {
      await api("/tests/generate", { method: "POST", body: body({ moduleId: st.module, duration: st.duration, week: st.week, settings: st.s }) });
      m.remove(); toast(isStandard(st.s) ? "Gemeinsamer Test wird gesucht, sonst erstellt – ca. 1 Minute …" : "Eigener Test wird erstellt – ca. 1 Minute …"); onStarted({ shared: isStandard(st.s), count: st.s.count });
    } catch (x) { $("#wtErr").textContent = x.message || "Der Test konnte nicht gestartet werden."; $("#wtErr").hidden = false; st.busy = false; draw(); }
  };
  draw(); loadDetail();
  return m;
}

// Gemeinsamer Wochentest der Kursgruppe (app/weekly_tests.py im Dienst, 28.10.2026). Alle Studierenden desselben
// Kurses bekommen in derselben Kalenderwoche denselben Test; jeder hat seinen eigenen Versuch, Punkte rechnet der
// Dienst, Loesungen kommen erst nach der Abgabe, die Rangliste ist freiwillig und nach der Frist ganz sichtbar.
// Windows: ueber das Studora-Konto (Weiterleitung /api/community/...), das Material der Woche stellt das eigene
// Backend zusammen (/api/weekly/materials, nur Texte).
import { $, $$, esc, icon, toast, modal } from "./core.js?v=32";

const when = iso => { try { return new Date(iso).toLocaleString("de-DE", { weekday: "short", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch { return ""; } };
const LEVEL = { short: "kurz", medium: "mittel", hard: "schwer" };
const KIND = { vorlesung: "Vorlesung", uebung: "Übung", gruppenuebung: "Gruppenübung", hoersaaluebung: "Hörsaalübung", tutorium: "Tutorium", loesung: "Lösung", skript: "Skript", altklausur: "Altklausur" };

// eigener Abruf statt core.api: die Oberflaeche braucht den Fehlercode des Dienstes (Vertrag G1)
async function j(path, opts = {}) {
  const r = await fetch(path, { method: opts.method || "GET", headers: opts.body !== undefined ? { "Content-Type": "application/json" } : {}, body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d?.detail || `Fehler ${r.status}`); e.code = d?.code; e.status = r.status; throw e; }
  return d;
}
const fmt = n => String(Math.round((n ?? 0) * 10) / 10).replace(".", ",");
const dez = n => String(n).replace(".", ",");
const people = n => n === 1 ? "1 gewertete Abgabe" : `${n} gewertete Abgaben`;
// Quellen einer Aufgabe (Q-Nummern des Materials); mit Fingerabdruck als Link, der die eigene Datei an der Seite oeffnet
const srcHtml = (t, q, links) => (q.sources || []).map(s => {
  const m = (t.materials || []).find(x => x.q === s.q); if (!m) return "";
  const txt = `${KIND[m.kind] || m.kind}: ${esc(m.title)}${s.page ? `, S. ${s.page}` : ""}`;
  return links && m.sha256 ? `<a href="#" data-fp="${esc(m.sha256)}" data-page="${+s.page || 1}">${txt}</a>` : txt;
}).filter(Boolean).join(" · ");
function wireSources(view) {
  $$("[data-fp]", view).forEach(a => a.onclick = async e => {
    e.preventDefault();
    try { const f = await j(`/api/files/by-fingerprint/${a.dataset.fp}`); location.hash = `#/doc/${f.file_id}?page=${a.dataset.page}`; }
    catch (x) { toast(x.message); }
  });
}

// ---------------------------------------------------------------- Uebersicht: diese Woche je Modul
export async function renderWeeklyOverview(el, modules) {
  const mods = modules.filter(m => m.active !== 0);
  if (!mods.length) { el.innerHTML = ""; return; }
  el.innerHTML = `<div class="card wk-card"><div class="card-head"><h2>${icon("users", 18)} Gemeinsamer Wochentest deiner Kursgruppe</h2><span class="tiny muted">für alle in deinem Kurs gleich · Rangliste freiwillig</span></div>
    <div class="wk-list">${mods.map(m => `<div class="wk-row" data-mod="${m.id}"><span class="dot" style="background:${esc(m.color || "var(--accent)")}"></span><b>${esc(m.name)}</b><span class="wk-state small muted">…</span></div>`).join("")}</div>
    <p class="tiny muted" style="margin:.5rem 0 0">15 Aufgaben aus Vorlesung, Übungen und passenden Skript- und Altklausur-Stellen dieser Woche, einmal von der Studora-KI erstellt und geprüft. Punkte rechnet der Dienst; Lösungen siehst du nach der Abgabe.</p></div>`;
  for (const m of mods) drawRow($(`[data-mod="${m.id}"]`, el), m);
}

async function drawRow(row, m) {
  const st = $(".wk-state", row);
  let g;
  try { g = await j(`/api/weekly/group?module_id=${m.id}`); } catch (e) { st.textContent = e.code === "no_course" ? "kein Hochschulkurs zugeordnet" : e.message; return; }
  const show = async () => {
    if (!row.isConnected) return;                          // Seite verlassen: nicht weiter nachfragen
    let t = null;
    try { t = await j(`/api/community/weekly/${g.course_key}/${g.week}?term=${encodeURIComponent(g.term)}`); }
    catch (e) {
      if (e.code === "not_generated") { st.innerHTML = `<span>${g.week.replace("-W", " · KW ")}: noch kein Test</span> <button class="btn sm" data-gen>${icon("sparkles", 13)} Erstellen lassen</button>`; $("[data-gen]", st).onclick = gen; return; }
      st.innerHTML = e.code === "not_linked" ? `<a href="#/community">Mit dem Studora-Konto verbinden</a>` : esc(e.message); return;
    }
    if (t.status === "generating") { st.innerHTML = `<span class="spin-dot"></span> wird erstellt …`; setTimeout(show, 5000); return; }
    if (t.status === "failed") { st.innerHTML = `<span class="wk-bad">${esc(t.error || "Erstellen fehlgeschlagen")}</span> <button class="btn sm ghost" data-gen>Erneut versuchen</button>`; $("[data-gen]", st).onclick = gen; return; }
    const a = t.attempt;
    const label = !a ? "Starten" : a.submitted_at ? "Ergebnis" : "Weiter";
    st.innerHTML = `<span>${esc(t.title || "Wochentest")} · ${t.questions.length} Aufgaben${a?.submitted_at && a.score != null ? ` · <b>${fmt(a.score)}/${fmt(a.max_score)}</b>` : ""}</span> <a class="btn sm ${a?.submitted_at ? "" : "primary"}" href="#/exams/w/${t.id}">${label}</a>`;
  };
  const gen = async () => {
    st.innerHTML = `<span class="spin-dot"></span> Material der Woche wird zusammengestellt …`;
    try { await j("/api/weekly/request", { method: "POST", body: { module_id: m.id } }); } catch (e) { st.innerHTML = `<span class="wk-bad">${esc(e.message)}</span>`; return; }
    show();
  };
  show();
}

// ---------------------------------------------------------------- Bearbeiten
export async function runWeekly(testId, view, practice = false) {
  view.innerHTML = `<div class="content"><div class="card">Lade Wochentest …</div></div>`;
  let t;
  try { t = await j(`/api/community/weekly/tests/${testId}/attempt`, { method: "POST", body: { practice } }); }
  catch (e) { view.innerHTML = `<div class="content"><div class="card">${icon("alert", 16)} ${esc(e.message)} <a href="#/exams">Zurück</a></div></div>`; return; }
  if (t.attempt?.submitted_at) return showResult(t, view);
  const a = t.attempt; const key = `wk-draft:${a.id}`;
  let answers = Object.assign({}, a.answers || {}); try { Object.assign(answers, JSON.parse(localStorage.getItem(key) || "{}")); } catch {}
  const input = q => {
    const v = answers[q.id] ?? "";
    if (q.type === "mc") return (q.options || []).map((o, i) => { const L = String.fromCharCode(65 + i); return `<label class="wk-opt"><input type="radio" name="${q.id}" value="${L}" ${v === L ? "checked" : ""}> <b>${L}</b> ${esc(o)}</label>`; }).join("");
    if (q.type === "multi") { const set = new Set(String(v).split(",").filter(Boolean)); return (q.options || []).map((o, i) => { const L = String.fromCharCode(65 + i); return `<label class="wk-opt"><input type="checkbox" name="${q.id}" value="${L}" ${set.has(L) ? "checked" : ""}> <b>${L}</b> ${esc(o)}</label>`; }).join(""); }
    if (q.type === "number") return `<input class="input wk-num" name="${q.id}" inputmode="decimal" placeholder="Zahl, z. B. 2,5" value="${esc(v)}" aria-label="Antwort Aufgabe ${q.nr}">`;
    return `<textarea class="input" name="${q.id}" rows="${q.type === "short" ? 2 : 5}" placeholder="${q.type === "calc" ? "Rechenweg und Ergebnis" : "Deine Antwort"}" aria-label="Antwort Aufgabe ${q.nr}">${esc(v)}</textarea>`;
  };
  view.innerHTML = `<div class="content wk"><div class="page-head"><div><h1>${esc(t.title || "Wochentest")}</h1><div class="sub">${esc(t.week.replace("-W", " · KW "))} · ${t.questions.length} Aufgaben (${t.levels.short} kurz, ${t.levels.medium} mittel, ${t.levels.hard} schwer) · ${fmt(t.max_points)} Punkte${(t.topics || []).length ? ` · ${esc(t.topics.join(", "))}` : ""}</div></div>
      <div class="actions"><span class="small muted wk-saved" aria-live="polite"></span><a class="btn sm ghost" href="#/exams">Später weiter</a><button class="btn primary sm" id="wkSubmit">Abgeben</button></div></div>
    <nav class="wk-nav" aria-label="Aufgaben">${t.questions.map(q => `<a href="#wkq-${q.id}" class="wk-chip lvl-${q.level}" data-chip="${q.id}" title="Aufgabe ${q.nr} (${LEVEL[q.level]})">${q.nr}</a>`).join("")}</nav>
    ${t.questions.map(q => `<section class="card wk-q" id="wkq-${q.id}"><div class="row between"><b>Aufgabe ${q.nr}</b><span class="tiny muted"><span class="badge lvl-${q.level}">${LEVEL[q.level]}</span> ${fmt(q.points)} P.${q.minutes ? ` · ca. ${q.minutes} min` : ""}${q.past_exam ? ` · <span class="badge warn">Altklausur</span>` : q.past_exam_like ? ` · <span class="badge neutral">nach Altklausur</span>` : ""}</span></div>
      <div class="wk-text">${esc(q.question).replace(/\n/g, "<br>")}</div><div class="wk-answer">${input(q)}</div>${srcHtml(t, q, false) ? `<div class="tiny muted">Quelle: ${srcHtml(t, q, false)}</div>` : ""}</section>`).join("")}
    <div class="row" style="justify-content:flex-end;margin:1rem 0"><button class="btn primary" id="wkSubmit2">Abgeben</button></div></div>`;
  const mark = () => t.questions.forEach(q => $(`[data-chip="${q.id}"]`, view)?.classList.toggle("done", !!String(answers[q.id] ?? "").trim()));
  let timer = null;
  const read = el => { const name = el.name; if (el.type === "checkbox") return $$(`input[name="${name}"]:checked`, view).map(x => x.value).join(","); if (el.type === "radio") return $(`input[name="${name}"]:checked`, view)?.value || ""; return el.value; };
  const saveSoon = () => { try { localStorage.setItem(key, JSON.stringify(answers)); } catch {} clearTimeout(timer); timer = setTimeout(async () => { try { await j(`/api/community/weekly/attempts/${a.id}`, { method: "PUT", body: { answers } }); $(".wk-saved", view).textContent = "Gespeichert"; } catch { $(".wk-saved", view).textContent = "Offline gespeichert"; } }, 1200); };
  $$(".wk-answer input, .wk-answer textarea", view).forEach(el => el.addEventListener("input", () => { answers[el.name] = read(el); mark(); saveSoon(); }));
  $$(".wk-answer input[type=radio], .wk-answer input[type=checkbox]", view).forEach(el => el.addEventListener("change", () => { answers[el.name] = read(el); mark(); saveSoon(); }));
  mark();
  const submit = () => {
    const open = t.questions.filter(q => !String(answers[q.id] ?? "").trim()).length;
    const back = modal(`<h3>Abgeben?</h3>${open ? `<p class="small">${open} Aufgabe(n) sind noch leer.</p>` : ""}<p class="small muted">${a.official ? "Nur dieser erste Versuch zählt. Danach siehst du Lösungen und Erklärungen." : "Übungsversuch: zählt nicht für die Rangliste."}</p>
      ${a.official ? `<label class="row small" style="gap:.4rem;align-items:center"><input type="checkbox" id="wkLb"> In der Rangliste der Kursgruppe zeigen</label>
      <label class="small">Name in der Rangliste <input class="input" id="wkName" maxlength="24" placeholder="leer = dein Pseudonym"></label>` : ""}
      <div class="modal-foot"><button class="btn" data-close>Zurück</button><button class="btn primary" data-go>Abgeben</button></div>`);
    $("[data-go]", back).onclick = async e => { e.target.disabled = true; e.target.textContent = "Wird bewertet …";
      try { const r = await j(`/api/community/weekly/attempts/${a.id}/submit`, { method: "POST", body: { answers, leaderboard: !!$("#wkLb", back)?.checked, display_name: $("#wkName", back)?.value.trim() || null } });
        try { localStorage.removeItem(key); } catch {} back.remove(); showResult(r, view); }
      catch (x) { e.target.disabled = false; e.target.textContent = "Abgeben"; toast(x.message, 5000); } };
  };
  $("#wkSubmit", view).onclick = submit; $("#wkSubmit2", view).onclick = submit;
}

// ---------------------------------------------------------------- Ergebnis und Rangliste
async function showResult(t, view) {
  const a = t.attempt; const res = a.result || {}; const sol = t.solutions || {};
  const pct = a.max_score ? Math.round(100 * a.score / a.max_score) : 0;
  view.innerHTML = `<div class="content wk"><div class="page-head"><div><h1>${esc(t.title || "Wochentest")}</h1><div class="sub">${esc(t.week.replace("-W", " · KW "))} · abgegeben ${when(a.submitted_at)}</div></div><div class="actions"><a class="btn sm ghost" href="#/exams">Zurück</a><button class="btn sm" id="wkPractice">Noch einmal üben</button></div></div>
    <div class="card wk-score"><div class="wk-big">${fmt(a.score)} / ${fmt(a.max_score)}</div><div class="progress ${pct >= 60 ? "ok" : ""}"><i style="width:${pct}%"></i></div>
      <div class="small muted">${pct} %${a.status === "grading_pending" ? " · offene Antworten werden noch bewertet" : a.needs_review ? " · eine Bewertung ist unsicher und wird geprüft, bis dahin nicht in der Rangliste" : ""}${a.official ? "" : " · Übungsversuch, zählt nicht für die Rangliste"}</div></div>
    <div class="card" id="wkLbBox"><div class="card-head"><h2>${icon("star", 18)} Rangliste der Kursgruppe</h2></div><div class="small muted">Lade …</div></div>
    ${t.questions.map(q => { const r = res[q.id] || {}; const s = sol[q.id] || {}; const full = (r.points ?? 0) >= q.points - 1e-6;
      return `<section class="card wk-q ${full ? "wk-ok" : (r.points ?? 0) > 0 ? "wk-part" : "wk-no"}"><div class="row between"><b>Aufgabe ${q.nr}</b><span class="small"><b>${fmt(r.points)}</b> / ${fmt(q.points)} P.</span></div>
        <div class="wk-text">${esc(q.question).replace(/\n/g, "<br>")}</div>
        ${(q.options || []).length ? `<div class="small muted">${q.options.map((o, i) => `<b>${String.fromCharCode(65 + i)}</b> ${esc(o)}`).join(" · ")}</div>` : ""}
        <div class="small"><b>Deine Antwort:</b> ${esc(a.answers?.[q.id] || "–")}</div>
        <div class="small"><b>Lösung:</b> ${esc(q.type === "number" && s.value != null ? `${dez(s.value)}${s.tolerance ? ` (± ${dez(s.tolerance)})` : ""}` : s.answer ?? "–")}</div>
        ${s.explanation ? `<div class="small muted">${esc(s.explanation)}</div>` : ""}${r.feedback ? `<div class="small">${esc(r.feedback)}</div>` : ""}
        ${(s.typical_errors || []).length ? `<div class="tiny muted">Typische Fehler: ${esc(s.typical_errors.join("; "))}</div>` : ""}
        ${srcHtml(t, q, true) ? `<div class="tiny muted">Quelle: ${srcHtml(t, q, true)}</div>` : ""}</section>`; }).join("")}</div>`;
  wireSources(view);
  $("#wkPractice", view).onclick = () => runWeekly(t.id, view, true);
  const box = $("#wkLbBox", view);
  try {
    const lb = await j(`/api/community/weekly/tests/${t.id}/leaderboard`);
    const opt = a.official ? `<label class="row small" style="gap:.4rem;align-items:center;margin-top:.5rem"><input type="checkbox" id="wkLbOn" ${a.leaderboard ? "checked" : ""}> Mich in der Rangliste zeigen${a.display_name ? ` als <b>${esc(a.display_name)}</b>` : ""}</label>` : "";
    $(".small.muted", box).outerHTML = lb.visible
      ? `<table class="tbl"><tr><th>Platz</th><th>Name</th><th>Punkte</th><th>%</th><th>Zeit</th></tr>${(lb.entries || []).map(e => `<tr class="${e.me ? "wk-me" : ""}"><td>${e.rank}</td><td>${esc(e.name)}${e.me ? " (du)" : ""}</td><td>${fmt(e.score)}/${fmt(e.max)}</td><td>${e.percent} %</td><td class="muted">${e.minutes} min</td></tr>`).join("") || `<tr><td colspan="5" class="muted">Niemand hat die Rangliste freigegeben.</td></tr>`}</table><div class="tiny muted">${people(lb.participants)}${lb.my_rank ? ` · dein Platz: ${lb.my_rank}` : ""}</div>${opt}`
      : `<div class="small">Die Rangliste ist ab <b>${when(lb.closes_at)}</b> sichtbar, damit frühe Ergebnisse niemanden beeinflussen. Bisher ${people(lb.participants)}.</div>${opt}`;
    $("#wkLbOn", box)?.addEventListener("change", async e => { try { await j(`/api/community/weekly/attempts/${a.id}/leaderboard`, { method: "POST", body: { on: e.target.checked } }); } catch (x) { toast(x.message); e.target.checked = !e.target.checked; } });
  } catch (e) { $(".small.muted", box).textContent = e.message; }
}

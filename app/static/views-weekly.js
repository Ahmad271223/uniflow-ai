// Vorlesungs-Seitenmarker ("Vorlesung bis hier"), Lernfortschritt & Wochentests, Testdetails, Probeklausur
import { $, $$, api, esc, icon, toast, modal, fmtDate } from "./core.js?v=24";

const SRC = { hoersaaluebung: "Hörsaalübung", gruppenuebung: "Gruppenübung", uebungsblatt: "Übungsblatt", zusatz: "Zusatzübung", tutorium: "Tutorium", altklausur: "Altklausur", loesung: "Musterlösung" };
const when = s => s ? new Date(s).toLocaleString("de-DE", { weekday: "short", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "–";
const pct = t => t && t.submitted_at && t.max_score ? Math.round(100 * t.score / t.max_score) : null;

// ================================================================ PDF-Editor: Button "Vorlesung bis hier"
export async function setupLectureMarker(ed, f, btn) {
  const refresh = async () => {
    try { ed.lectureMarks = await api(`/markers?file_id=${encodeURIComponent(f.id)}`); } catch { ed.lectureMarks = []; }
    const review = ed.lectureMarks.some(m => m.needs_review);
    btn.classList.toggle("warn", review);
    btn.title = review ? "Ein Marker muss nach einer Dokumentänderung geprüft werden" : "Vorlesung bis hier: letzte behandelte Seite markieren";
    ed.renderSide?.();
  };
  await refresh();
  btn.onclick = async () => {
    const p = ed.pages[ed.currentPage];
    if (!p || p.type !== "pdf") return toast("Bitte eine Seite des Vorlesungsskripts wählen (keine eingefügte Notizseite).");
    let pv;
    try { pv = await api(`/markers/preview?file_id=${encodeURIComponent(f.id)}&page=${p.index}`); } catch (e) { return toast(e.message, 5000); }
    const own = ed.lectureMarks.filter(m => m.scope === "personal");
    const box = modal(`<h3>${icon("bookmark", 18)} Vorlesung bis hier</h3>
      <p style="margin:.2rem 0 .8rem"><b>${pv.existing ? `Seite ${pv.page} ist bereits als Vorlesungsende markiert.` : `Bis Seite ${pv.page} als behandelt markieren?`}</b> <span class="muted small">Folie ${pv.page} von ${pv.page_count}</span></p>
      <div class="wt-facts">
        <span>Vorlesungstermin</span><div><input class="input" type="date" id="lmDate" value="${pv.lecture_date}" max="${new Date().toISOString().slice(0, 10)}" style="width:auto"> <span class="muted small" id="lmLec">${lecText(pv)}</span></div>
        <span>Erfasster Seitenbereich</span><div><b>Seite ${pv.range[0]}–${pv.range[1]}</b> <span class="muted small">neu seit dem letzten Marker</span></div>
        <span>Thema</span><div><input class="input" id="lmTopic" value="${esc(pv.topic)}" placeholder="z. B. Variablen und Datentypen"></div>
        <span>Wochentest</span><div id="lmPub">${pubText(pv)}</div>
      </div>
      <p class="muted small" style="margin:.7rem 0 0">${icon("info", 13)} Der Marker begrenzt den Lernstoff: Seiten danach kommen in keinem Wochentest vor. Er ist keine Textmarkierung und gilt zunächst nur für dich.</p>
      ${own.length ? `<h4 style="margin:1rem 0 .3rem">Marker in diesem Dokument</h4><div class="wt-marks">${own.map(m => `<div class="wt-mark ${m.needs_review ? "review" : ""}"><span>${icon(m.needs_review ? "alert" : "flag", 14)} <b>S. ${m.page_range[0]}–${m.page}</b> · ${fmtDate(m.lecture_date)}${m.topic ? ` · ${esc(m.topic)}` : ""}${m.needs_review ? `<br><span class="small">${esc(m.review_note || "")}</span>` : ""}</span>
          <span class="row" style="gap:.25rem"><button class="btn ghost sm" data-go="${m.page}" title="Zur Seite">${icon("arrow-left", 13)}</button>${m.page !== pv.page ? `<button class="btn ghost sm" data-move="${m.id}" title="Auf aktuelle Seite ${pv.page} verschieben">→ S. ${pv.page}</button>` : ""}<button class="btn ghost sm" data-rel="${m.id}" title="Für den Kurs freigeben">${icon("users", 13)}</button><button class="btn ghost sm" data-del="${m.id}" title="Marker löschen">${icon("trash", 13)}</button></span></div>`).join("")}</div>` : ""}
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="lmOk">${icon("bookmark", 14)} ${pv.existing ? "Änderungen speichern" : `Bis Seite ${pv.page} markieren`}</button></div>`);
    $("#lmDate", box).onchange = async () => { try { const q = await api(`/markers/preview?file_id=${encodeURIComponent(f.id)}&page=${p.index}&lecture_date=${$("#lmDate", box).value}`); pv = q; $("#lmLec", box).textContent = lecText(q); $("#lmPub", box).innerHTML = pubText(q); } catch (e) { toast(e.message); } };
    $("#lmOk", box).onclick = async () => {
      try { if (pv.existing) await api(`/markers/${pv.existing.id}`, { method: "PATCH", body: { lecture_date: $("#lmDate", box).value, topic: $("#lmTopic", box).value } });
        else await api("/markers", { method: "POST", body: { file_id: f.id, page: p.index, page_key: p.key, lecture_date: $("#lmDate", box).value, topic: $("#lmTopic", box).value } });
        box.remove(); toast(`Seite ${pv.range[0]}–${pv.page} als behandelt markiert. Wochentest ab ${when(pv.publish_at)}.`, 4000); refresh(); }
      catch (e) { toast(e.message, 6000); }
    };
    $$("[data-go]", box).forEach(b => b.onclick = () => { const i = ed.pages.findIndex(x => x.type === "pdf" && x.index === +b.dataset.go); if (i >= 0) ed.goToPage(i); box.remove(); });
    $$("[data-move]", box).forEach(b => b.onclick = async () => { try { await api(`/markers/${b.dataset.move}`, { method: "PATCH", body: { page: p.index, page_key: p.key } }); box.remove(); toast("Marker verschoben"); refresh(); } catch (e) { toast(e.message, 6000); } });
    $$("[data-del]", box).forEach(b => b.onclick = async () => { if (!confirm("Marker löschen? Bereits veröffentlichte Wochentests bleiben unverändert.")) return; await api(`/markers/${b.dataset.del}`, { method: "DELETE" }); box.remove(); toast("Marker gelöscht"); refresh(); });
    $$("[data-rel]", box).forEach(b => b.onclick = async () => {
      if (!confirm("Diesen Marker als gemeinsamen Kursstand freigeben?\n\nDann richtet sich der gemeinsame Wochentest aller Teilnehmer nach diesem Stoffumfang. Nur freigeben, wenn der Stand für den ganzen Kurs stimmt.")) return;
      try { await api(`/markers/${b.dataset.rel}/release`, { method: "POST", body: { confirm: true } }); box.remove(); toast("Als Kursmarker freigegeben"); refresh(); } catch (e) { toast(e.message, 6000); }
    });
  };
}
function lecText(pv) { return pv.lecture ? `${pv.lecture.start}–${pv.lecture.end}${pv.lecture.room ? ` · ${pv.lecture.room}` : ""} (Stundenplan)` : "kein Termin im Stundenplan – Ende wird geschätzt"; }
function pubText(pv) { return `voraussichtlich <b>${when(pv.publish_at)}</b> <span class="muted small">(${pv.publish_hours} h nach Vorlesungsende, Lehrwoche ${pv.week_no})</span>`; }

// ================================================================ Modulübersicht: Lernfortschritt & Wochentests
export async function renderWeeklyBox(host, module, onChange) {
  let d;
  try { d = await api(`/weekly/module/${module.id}`); } catch (e) { host.innerHTML = `<div class="muted small">Wochentests nicht geladen: ${esc(e.message)}</div>`; return; }
  const row = w => {
    const plans = w.plans.length ? w.plans : [null];
    return plans.map(p => {
      const t = p?.test; const pc = pct(t);
      const right = !p ? (w.markers.length ? `<span class="muted small">Marker gesetzt</span>` : `<span class="muted small">${icon("bookmark", 13)} im Skript „Vorlesung bis hier“ setzen</span>`)
        : p.status === "veroeffentlicht" ? `${pc !== null ? `<span class="badge ${pc >= 60 ? "ok" : "bad"}">${pc} %</span>` : ""}<a class="btn ${t?.submitted_at ? "" : "primary"} sm" href="#/exams/${t?.id}">${t?.submitted_at ? "Ergebnis" : `${icon("play", 13)} Starten`}</a><button class="btn ghost sm" data-def="${p.def_id}">Details</button>`
        : p.status === "wartet" ? `<span class="small muted">wartet auf ${p.missing.map(x => SRC[x] || x).join(", ")} · spätestens ${when(p.deadline_at)}</span>`
        : p.status === "fehlgeschlagen" ? `<span class="small" style="color:var(--bad)" title="${esc(p.error || "")}">${icon("alert", 13)} nicht freigegeben</span><button class="btn ghost sm" data-retry>Erneut versuchen</button>`
        : `<span class="small muted">${icon("clock", 13)} erscheint ${when(p.publish_at)}</span>`;
      const st = !p ? w.status : p.status_text;
      const pages = p ? p.pages.map(s => `S. ${s.from}–${s.to}`).join(", ") : "";
      return `<div class="wt-row wt-st-${p ? p.status : "leer"}"><div class="wt-w">Woche ${w.week}${p && p.part > 1 ? ` · Teil ${p.part}` : ""}</div>
        <div class="wt-t"><b>${esc(w.topic || (p ? p.topic : "") || "–")}</b><span class="muted small">${esc(st)}${pages ? ` · ${pages}` : ""}${p?.question_count ? ` · ${p.question_count} Aufgaben` : ""}</span>
        ${p?.nachtraege?.length ? p.nachtraege.map(n => `<span class="small">${icon("plus", 12)} Nachtrag: <a href="#/exams/${n.test?.id}">${esc(n.title || "ergänzende Aufgaben")}</a>${pct(n.test) !== null ? ` · ${pct(n.test)} %` : ""}</span>`).join("") : ""}</div>
        <div class="wt-a">${right}</div></div>`;
    }).join("");
  };
  host.innerHTML = `<div class="card-head"><h2>${icon("exam", 18)} Lernfortschritt & Wochentests</h2><span class="row" style="gap:.3rem"><button class="btn sm" id="wtMock">${icon("sparkles", 14)} Probeklausur</button><button class="btn ghost icon sm" id="wtSet" title="Einstellungen für Wochentests">${icon("settings", 15)}</button></span></div>
    ${d.needs_review.length ? `<div class="wt-warn">${icon("alert", 14)} ${d.needs_review.length} Marker nach Dokumentänderung prüfen – der betroffene Stoff zählt bis dahin nicht.</div>` : ""}
    <div class="wt-list">${d.weeks.map(row).join("")}</div>
    ${d.mock_exams.length ? `<div class="small" style="margin-top:.6rem"><b>Probeklausuren:</b> ${d.mock_exams.map(m => `<a href="#/exams/${m.test?.id}">${esc(m.title || "Probeklausur")}</a>${pct(m.test) !== null ? ` (${pct(m.test)} %)` : ""}`).join(" · ")}</div>` : ""}
    <p class="muted tiny" style="margin:.6rem 0 0">Ein gemeinsamer Test pro Lehrwoche, ${d.settings.publish_hours} h nach Vorlesungsende, nur aus Stoff bis zum Marker. Spätere Uploads kommen als Nachtrag dazu, der Test selbst bleibt unverändert.</p>`;
  $$("[data-def]", host).forEach(b => b.onclick = () => defDetails(+b.dataset.def));
  $$("[data-retry]", host).forEach(b => b.onclick = async () => { try { await api("/weekly/tick", { method: "POST" }); toast("Wird erneut versucht…"); window.pollBg?.(); } catch (e) { toast(e.message); } });
  $("#wtSet", host).onclick = () => weeklySettings(module, d.settings, () => { renderWeeklyBox(host, module, onChange); onChange?.(); });
  $("#wtMock", host).onclick = () => mockDialog(module);
}

export async function defDetails(id) {
  const box = modal(`<h3>${icon("exam", 18)} Testdetails</h3><div id="ddBody" class="muted">Lade…</div><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`, { wide: true });
  try {
    const d = await api(`/weekly/defs/${id}`);
    const pages = arr => arr.length ? arr.map(p => `${esc(p.name || "Skript")}: S. ${p.from}–${p.to}`).join("<br>") : "–";
    const st = d.test ? (d.test.submitted_at ? `abgegeben · ${Math.round(d.test.score)}/${Math.round(d.test.max_score)} Punkte` : d.test.started_at ? "begonnen" : "noch nicht gestartet") : "–";
    $("#ddBody", box).classList.remove("muted");
    $("#ddBody", box).innerHTML = `<div class="wt-facts">
      <span>Thema</span><div><b>${esc(d.topic || d.title || "–")}</b> <span class="muted small">${d.kind === "probeklausur" ? "Probeklausur" : d.kind === "nachtrag" ? "Nachtrag" : `Lehrwoche ${d.week_no}`} · Version ${d.version}</span></div>
      <span>Vorlesungsseiten</span><div>${pages(d.pages)}${d.prior_pages.length ? `<div class="muted small" style="margin-top:.2rem">Vorwissen: ${d.prior_pages.map(p => `S. ${p.from}–${p.to}`).join(", ")}</div>` : ""}</div>
      <span>Verwendete Übungen</span><div>${d.used_materials.length ? d.used_materials.map(m => `<div class="small">${esc(m.label)}</div>`).join("") : `<span class="muted">nur Vorlesungsinhalte</span>`}</div>
      <span>Altklausuraufgaben</span><div>${d.exam_questions} im Test · ${d.exam_candidates} passende gefunden</div>
      <span>Testaufgaben</span><div>${d.question_count}${d.levels ? ` <span class="muted small">(${Object.entries(d.levels).map(([k, v]) => `${v} ${k}`).join(", ")})</span>` : ""} · ${d.duration_min} min</div>
      <span>Veröffentlicht</span><div>${when(d.published_at)}</div>
      <span>Bearbeitung</span><div>${st}${d.test ? ` <a class="btn sm" href="#/exams/${d.test.id}" data-close-link>${d.test.submitted_at ? "Ansehen" : "Starten"}</a>` : ""}</div>
      ${d.missing.length ? `<span>Fehlende Quellen</span><div style="color:var(--warn)">${d.missing.map(x => SRC[x] || x).join(", ")} waren bis zur Veröffentlichung nicht hochgeladen</div>` : ""}
      ${d.excluded_count ? `<span>Ausgeschlossen</span><div class="muted small">${d.excluded_count} Aufgaben aus Übungen/Altklausuren betreffen noch nicht behandelten Stoff</div>` : ""}
      ${d.nachtraege.length ? `<span>Nachträge</span><div>${d.nachtraege.map(n => `${esc(n.title || "Nachtrag")} · ${when(n.published_at)}`).join("<br>")}</div>` : ""}
    </div>
    ${d.ranking.length ? `<h4 style="margin:1rem 0 .3rem">${icon("users", 15)} Rangliste dieser Testversion</h4><table class="tbl"><tr><th>#</th><th>Teilnehmer</th><th>Punkte</th><th>Dauer</th></tr>${d.ranking.map(r => `<tr><td>${r.rank}</td><td>${r.user_id === "local" ? "Du" : esc(r.user_id)}</td><td>${Math.round(r.score)}/${Math.round(r.max_score)} (${r.percent} %)</td><td>${r.duration_sec ? `${Math.round(r.duration_sec / 60)} min` : "–"}</td></tr>`).join("")}</table><p class="muted tiny">Alle Teilnehmer dieser Version haben dieselben Aufgaben und Bewertungskriterien. Nachträge zählen nicht.</p>` : ""}`;
    $$("[data-close-link]", box).forEach(a => a.onclick = () => box.remove());
  } catch (e) { $("#ddBody", box).textContent = "Fehler: " + e.message; }
}

function weeklySettings(module, s, done) {
  const exp = new Set(s.expected_materials || []);
  const box = modal(`<h3>${icon("settings", 18)} Wochentests · ${esc(module.name)}</h3>
    <label class="field">Veröffentlichung nach Vorlesungsende<select class="input" id="wsHours" style="width:auto">${[5, 24, 48].map(h => `<option value="${h}" ${+s.publish_hours === h ? "selected" : ""}>${h} Stunden</option>`).join("")}</select><span class="muted tiny">gilt für alle Module</span></label>
    <div class="field">Diese Übungen kommen jede Woche sicher – der Test wartet darauf (höchstens ${s.max_delay_hours} h länger):
      <div class="row wrap" style="margin-top:.3rem">${["hoersaaluebung", "gruppenuebung", "uebungsblatt", "zusatz", "tutorium"].map(k => `<label class="chip"><input type="checkbox" data-exp="${k}" ${exp.has(k) ? "checked" : ""}> ${SRC[k]}</label>`).join("")}</div>
      <span class="muted tiny">Nichts ankreuzen, wenn unklar. Ohne Angabe wird nicht gewartet, später hochgeladene Aufgaben kommen als Nachtrag.</span></div>
    <div class="field">Altklausuren<div class="row wrap" style="margin-top:.3rem"><label class="chip"><input type="radio" name="wsReuse" value="paraphrase" ${s.exam_reuse !== "original" ? "checked" : ""}> nur angelehnte neue Aufgaben</label><label class="chip"><input type="radio" name="wsReuse" value="original" ${s.exam_reuse === "original" ? "checked" : ""}> Originalaufgaben erlaubt</label></div>
      <span class="muted tiny">Originale nur, wenn die Nutzungsrechte das erlauben.</span></div>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="wsOk">Speichern</button></div>`);
  $("#wsOk", box).onclick = async () => {
    await api("/settings", { method: "PUT", body: { weekly_publish_hours: $("#wsHours", box).value } });
    await api(`/modules/${module.id}`, { method: "PATCH", body: { expected_materials: $$("[data-exp]", box).filter(c => c.checked).map(c => c.dataset.exp), exam_reuse: $("input[name=wsReuse]:checked", box).value } });
    box.remove(); toast("Gespeichert"); done();
  };
}

function mockDialog(module) {
  const box = modal(`<h3>${icon("sparkles", 18)} Probeklausur · ${esc(module.name)}</h3>
    <p class="small">Die Probeklausur orientiert sich an Aufbau, Aufgabentypen und Punkteverteilung der echten Altklausuren. Sie wird nur auf Anfrage erstellt.</p>
    <div class="stack"><button class="btn" id="pkNow">${icon("bookmark", 14)} Lernstandsklausur – nur bis zum letzten Marker</button><button class="btn" id="pkFull">${icon("flag", 14)} Abschlussprobeklausur – gesamter Stoff</button></div>
    <p class="muted tiny">Die Abschlussprobeklausur ist erst möglich, wenn alle Vorlesungsskripte bis zur letzten Seite markiert sind.</p>
    <div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`);
  const go = async full => { try { await api("/weekly/mock-exam", { method: "POST", body: { module_id: module.id, full } }); box.remove(); toast("Probeklausur wird erstellt und geprüft (einige Minuten)…", 4000); window.pollBg?.(); } catch (e) { toast(e.message, 6000); } };
  $("#pkNow", box).onclick = () => go(false); $("#pkFull", box).onclick = () => go(true);
}

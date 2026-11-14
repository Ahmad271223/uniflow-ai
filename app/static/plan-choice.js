// Lernplaner am PC und im Browser (Auftrag des Inhabers 14.11.2026, Teil 1; wie PlanChoiceViews.swift auf dem iPad):
// Faecher in der Lernkombination, Wochenwunsch "Diese Woche", "Thema schon gemacht", "Hier ein anderes Fach gemacht".
// Endpunkte: /api/calendar/modules, /api/calendar/week-wish, /api/calendar/topic-done (app/study_choice.py).
import { $, $$, api, esc, icon, toast, modal, todayISO, fmtShort, state, closeDrawer } from "./core.js?v=47";

const KEPT = n => `${n === 1 ? "1 selbst angelegtes oder geändertes Lernpaket gehört" : `${n} selbst angelegte oder geänderte Lernpakete gehören`} zu nicht gewählten Fächern. Auch entfernen? Erledigtes und erfasste Lernzeit bleiben.`;

// ---------------------------------------------------------------- Faecher in der Lernkombination

/** Abschnitt "Faecher" fuer configDialog: HTML (leer ohne Module) */
export function subjectsHtml(o) {
  if (!o?.modules?.length) return "";
  return `<label class="field">Fächer<span class="muted small">Diese Fächer plant der Lernkalender. Abgewählte Fächer bekommen nie Lernpakete.</span>
    <div class="row wrap" id="cSubj">${o.modules.map(chip).join("")}</div>
    <div class="row" style="margin-top:.4rem"><input class="input" id="cSubjNew" placeholder="Eigenes Fach, z. B. Englisch" style="flex:1"><button type="button" class="btn sm" id="cSubjAdd">${icon("plus", 14)} Hinzufügen</button></div></label>`;
}
const chip = x => `<button type="button" class="chip ${x.planned ? "on" : ""}" data-subj="${esc(x.name)}">${x.planned ? icon("check", 12) + " " : ""}${esc(x.name)}</button>`;

/** Haken umschalten, eigenes Fach hinzufuegen (sofort angelegt, noch nicht gespeicherte Haken bleiben) */
export function bindSubjects(m) {
  const box = $("#cSubj", m); if (!box) return;
  const bindChips = () => $$("[data-subj]", box).forEach(c => c.onclick = () => { const on = !c.classList.contains("on"); c.classList.toggle("on", on); c.innerHTML = (on ? icon("check", 12) + " " : "") + esc(c.dataset.subj); });
  bindChips();
  $("#cSubjAdd", m).onclick = async () => {
    const name = $("#cSubjNew", m).value.trim(); if (!name) return;
    const chosen = Object.fromEntries($$("[data-subj]", box).map(c => [c.dataset.subj, c.classList.contains("on")]));
    try {
      const o = await api("/calendar/modules", { method: "POST", body: { add: name } });
      box.innerHTML = o.modules.map(x => chip({ ...x, planned: x.name in chosen ? chosen[x.name] : x.planned })).join("");
      $("#cSubjNew", m).value = ""; bindChips();
    } catch (e) { toast(e.message); }
  };
}

/** Beim Speichern der Lernkombination: Wahl speichern, bei uebrigen eigenen Paketen nachfragen */
export async function saveSubjects(m) {
  const chips = $$("[data-subj]", m); if (!chips.length) return;
  const saved = await api("/calendar/modules", { method: "POST", body: { modules: chips.map(c => ({ name: c.dataset.subj, planned: c.classList.contains("on") })) } });
  if (saved.kept > 0 && confirm(KEPT(saved.kept))) await api("/calendar/modules", { method: "POST", body: { remove_own: true } });
}

// ---------------------------------------------------------------- Wochenwunsch

export async function weekWishDialog() {
  const o = await api("/calendar/week-wish");
  const wished = [...o.modules];
  const m = modal(`<h3>${icon("star", 18)} Was willst du diese Woche machen?</h3>
    <p class="muted">Wähle die Fächer, auf die du diese Woche Lust hast. Der Plan für den Rest der Woche richtet sich danach. Fächer mit einer Klausur in den nächsten 14 Tagen bleiben trotzdem dabei.</p>
    ${o.choices.length ? `<div class="row wrap" id="wwList">${o.choices.map(c => `<button type="button" class="chip ${c.wished ? "on" : ""}" data-ww="${esc(c.name)}">${esc(c.name)}</button>`).join("")}</div>` : `<p class="muted">Keine Fächer im Lernkalender.</p>`}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="wwOk">Speichern</button></div>`);
  $$("[data-ww]", m).forEach(c => c.onclick = () => {
    const n = c.dataset.ww, i = wished.indexOf(n);
    if (i >= 0) wished.splice(i, 1); else wished.push(n);
    c.classList.toggle("on", i < 0);
  });
  $("#wwOk", m).onclick = async () => {
    try {
      const r = await api("/calendar/week-wish", { method: "PUT", body: { modules: wished } });
      m.remove(); toast(r.plan?.message || "Wochenwunsch gespeichert"); state.route();
    } catch (e) { toast(e.message); }
  };
}

// ---------------------------------------------------------------- Thema gemacht

export async function topicDone(ids, inPackage) {
  const body = { task_ids: ids }; if (inPackage) body.in_package = inPackage;
  const r = await api("/calendar/topic-done", { method: "POST", body });
  toast(r.message); state.route();
  return r;
}

/** Offene, geplante Themen anderer Faecher ab heute (hoechstens 30) */
export function candidates(open, p, today) {
  return open.filter(t => t.status === "geplant" && t.module_id !== p.module_id && (t.date || "") >= today && t.package_id !== p.id).slice(0, 30);
}

export async function otherTopicDialog(p) {
  const list = candidates(await api("/tasks/open"), p, todayISO());
  const m = modal(`<h3>${icon("move", 18)} Was hast du stattdessen gemacht?</h3>
    <p class="muted">Wähle das Thema, das du in dieser Zeit gelernt hast. Es zählt als erledigt, sein späterer Termin wird frei, und dieses Lernpaket rückt dorthin.</p>
    ${list.length ? `<div class="stack" id="otList">${list.map(t => `<label class="row" style="gap:.6rem;align-items:center"><input type="checkbox" data-ot="${t.id}"><span class="dot" style="background:${t.color || "var(--accent)"}"></span><span><b>${esc(t.title)}</b><br><span class="muted small">${esc(t.subject || "")} · ${fmtShort(t.date)}</span></span></label>`).join("")}</div>` : `<p class="muted">Keine geplanten Themen anderer Fächer.</p>`}
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="otOk" disabled>Erledigt – Termine tauschen</button></div>`);
  const ok = $("#otOk", m);
  $$("[data-ot]", m).forEach(c => c.onchange = () => { ok.disabled = !$$("[data-ot]:checked", m).length; });
  ok.onclick = async () => {
    const ids = $$("[data-ot]:checked", m).map(c => +c.dataset.ot);
    try { await topicDone(ids, p.id); m.remove(); closeDrawer(); } catch (e) { toast(e.message); }
  };
}

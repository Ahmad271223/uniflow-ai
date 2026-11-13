// KI-Karteikarten auf Auftrag (Pro AI) und Ansicht eines geteilten Stapels (04.11.2026). Aus der Cloud-Sitzung
// uebernommen und an das Stapel-Modell angepasst: Fach, Lernwoche oder ganzes Modul, Anzahl 5-50, Schwerpunkt,
// Vorschau mit Haken, "Andere Karten", dann Speichern in einen Stapel des Moduls ("KI · Woche n", Art "eigene").
// Regeln ohne DOM in flashcard-stacks.js. Eingebunden von viewCards (views-misc.js) und community-decks-ui.js.
import { $, $$, api, esc, icon, toast, showError, modal, can } from "./core.js?v=47";
import * as F from "./flashcard-stacks.js?v=3";

/** Schloss (icons.js hat keins): gleiche Strichart wie die anderen Symbole */
export const lockIcon = (size = 16) => `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`;
export const lockHtml = a => `<div class="small" style="display:flex;gap:.5rem;align-items:flex-start;padding:.6rem .7rem;border:1px dashed var(--line-strong);border-radius:10px">${lockIcon(16)}<span>${esc(a.text)} <a href="${a.href}" data-close>Tarife ansehen</a></span></div>`;

/** Dialog "KI-Karteikarten". opts: { modules: [{id, name}], stacks (eigene Stapel, fuer den Namen), preset: {moduleId,
 *  week} }; done() nach dem Speichern. */
export function openAiDialog({ modules = [], stacks = [], preset = {} } = {}, done) {
  const access = F.aiAccess(can);
  if (access.locked) { modal(`<h3>${lockIcon(18)} KI-Karteikarten</h3>${lockHtml(access)}<div class="modal-foot"><button class="btn" data-close>Schließen</button><a class="btn primary" href="#/abo" data-close>Zu den Tarifen</a></div>`); return; }
  if (!modules.length) { toast("Noch keine Module. Gleiche zuerst deine Hochschule ab.", 4000); return; }
  const m = modal(`<h3>${icon("sparkles", 18)} KI-Karteikarten</h3><div id="aiBody"></div>`, { wide: true });
  const box = $("#aiBody", m);
  const st = { cards: null, keep: new Set(), req: null, busy: false, info: null, moduleId: preset.moduleId ?? modules[0].id };
  const loadWeeks = async () => {
    const sel = $("#aiWeek", box);
    sel.innerHTML = `<option value="module">Wird geladen …</option>`;
    let w = { weeks: [], current_week: null };
    try { w = await api(`/ai/flashcards/weeks?module_id=${st.moduleId}`); } catch { /* ohne Wochen: nur "Ganzes Modul" */ }
    if (!sel.isConnected) return;
    sel.innerHTML = F.weekOptions(w.weeks, w.current_week, preset.week).map(o => `<option value="${o.value}" ${o.selected ? "selected" : ""}>${esc(o.label)}</option>`).join("");
  };
  const form = () => {
    box.innerHTML = `<p class="small muted" style="margin-top:0">Die StudiNow-KI nimmt das Material genau dieser Woche (markierte Vorlesungsseiten, Folien, Skript, Übungen) und macht so viele Karten, wie du willst. Karten, die du in diesem Modul schon hast, kommen nicht doppelt.</p>
      <label class="field">Fach<select class="input" id="aiMod">${modules.map(x => `<option value="${x.id}" ${x.id === st.moduleId ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label>
      <label class="field">Lernwoche<select class="input" id="aiWeek"></select></label>
      <label class="field">Anzahl <b id="aiN">${F.COUNT.def}</b><input type="range" id="aiCount" min="${F.COUNT.min}" max="${F.COUNT.max}" step="1" value="${F.COUNT.def}"></label>
      <label class="field">Schwerpunkt (optional)<input class="input" id="aiTopic" maxlength="300" placeholder="z. B. Konvergenzkriterien"></label>
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="aiGo">${icon("sparkles", 14)} Karten erstellen</button></div>`;
    $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
    $("#aiMod", box).onchange = e => { st.moduleId = +e.target.value; loadWeeks(); };
    $("#aiCount", box).oninput = e => { $("#aiN", box).textContent = e.target.value; };
    $("#aiGo", box).onclick = () => run(false);
    loadWeeks();
  };
  const run = async again => {
    if (st.busy) return;
    if (!again) st.req = { moduleId: st.moduleId, week: F.weekValue($("#aiWeek", box).value), count: $("#aiCount", box).value, topic: $("#aiTopic", box).value };
    st.busy = true;
    box.innerHTML = `<p class="small">${icon("sparkles", 14)} Die KI erstellt ${F.clampCount(st.req.count)} Karten … das dauert etwa eine halbe Minute.</p>`;
    try {
      const r = await api("/ai/flashcards", { method: "POST", body: F.aiRequest({ ...st.req, again }) });
      st.cards = r.cards; st.keep = new Set(r.cards.map((_, i) => i)); st.info = r;
      st.busy = false; preview();
    } catch (e) { st.busy = false; form(); showError(e, 6000); }
  };
  const preview = () => {
    const r = st.info;
    box.innerHTML = `<p class="small" style="margin-top:0"><b>${esc(r.module_name)} · ${esc(r.week == null ? "Ganzes Modul" : F.weekLabel(r.week))}</b> – ${st.cards.length} Vorschläge${r.duplicates_removed ? `, ${r.duplicates_removed} doppelte weggelassen` : ""}.
        <span class="muted">Quellen: ${esc(r.sources.map(s => s.name).join(", ") || "–")}</span></p>
      <div class="list" style="max-height:50vh;overflow:auto">${st.cards.map((c, i) => `<label class="item" style="align-items:flex-start;cursor:pointer"><input type="checkbox" data-keep="${i}" ${st.keep.has(i) ? "checked" : ""} style="margin:.25rem .6rem 0 0"><div class="main"><div class="title">${esc(c.question)}</div><div class="sub">${esc(c.answer)}</div></div></label>`).join("")}</div>
      <label class="field">Stapel<input class="input" id="aiStack" maxlength="120" value="${esc(F.aiStackName(r.week))}"></label>
      <div class="modal-foot"><button class="btn" data-close>Verwerfen</button><button class="btn" id="aiAgain">${icon("refresh", 14)} Andere Karten</button><button class="btn primary" id="aiSave">${icon("check", 14)} Speichern (<span id="aiK">${st.keep.size}</span>)</button></div>`;
    $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
    $$("[data-keep]", box).forEach(c => c.onchange = () => { c.checked ? st.keep.add(+c.dataset.keep) : st.keep.delete(+c.dataset.keep); $("#aiK", box).textContent = st.keep.size; });
    $("#aiAgain", box).onclick = () => run(true);
    $("#aiSave", box).onclick = async () => {
      const cards = st.cards.filter((_, i) => st.keep.has(i));
      const name = $("#aiStack", box).value.trim() || F.aiStackName(r.week);
      if (!cards.length) { toast("Keine Karte ausgewählt."); return; }
      try {
        const target = F.stackFor(stacks, r.module_name, name) || await api("/flashcard-stacks", { method: "POST", body: F.newStackBody(name, r.module_name, r.week) });
        await api("/flashcards", { method: "POST", body: { stack_id: target.id, cards } });
        m.remove(); toast(`${F.savedText(cards.length)} – Stapel „${name}“`, 3500); done?.();
      } catch (e) { showError(e, 5000); }
    };
  };
  form();
}

/** Geteilten Stapel ansehen (GET /api/community/card-stacks/{id}); mit onAdopt ein Knopf "Übernehmen" */
export async function showShared(id, { onAdopt } = {}) {
  let d;
  try { d = await api(`/community/card-stacks/${encodeURIComponent(id)}`); } catch (e) { showError(e, 5000); return; }
  const m = modal(`<h3>${icon("cards", 18)} ${esc(d.name)}</h3><p class="small muted" style="margin-top:0">${esc(F.weekLabel(d.week))} · ${esc(F.sharedMeta(d))}</p>
    <div class="list" style="max-height:55vh;overflow:auto">${(d.cards_list || []).map(c => `<div class="item"><div class="main"><div class="title">${esc(c.question)}</div><div class="sub">${esc(c.answer)}</div></div></div>`).join("")}</div>
    <div class="modal-foot"><button class="btn" data-close>Schließen</button>${onAdopt && !d.mine ? `<button class="btn primary" data-adopt>${icon("download", 14)} Übernehmen</button>` : ""}</div>`, { wide: true });
  $("[data-adopt]", m)?.addEventListener("click", async () => { if (await onAdopt(d)) m.remove(); });
}

/** Als eigenen Stapel uebernehmen (POST /api/community/card-stacks/{id}/adopt, 0 Credits); true bei Erfolg */
export async function adoptShared(s) {
  const access = F.shareAccess(can);
  if (access.locked) { toast(access.text, 5000); return false; }
  try {
    const r = await api(`/community/card-stacks/${encodeURIComponent(s.id)}/adopt`, { method: "POST", body: {} });
    toast(r.already ? "Schon übernommen" : `Übernommen: ${F.savedText(r.count, "")}`.trim() + " – 0 Credits", 3500);
    return true;
  } catch (e) { toast(F.communityHint(e), 5000); return false; }
}

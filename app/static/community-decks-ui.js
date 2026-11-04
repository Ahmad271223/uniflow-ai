// Reiter "Karteikarten" im Community-Kanal (community-channel.js, 04.11.2026): geteilte Stapel der Community nach
// Lehrwoche ("Woche 5", "Ganzes Modul"), ansehen, uebernehmen (in das eigene Modul der Community bzw. bei Lerngruppen in
// ein gewaehltes Modul), melden. Teilen geht von der Seite "Karteikarten" aus (Stapel -> Teilen).
import { $, $$, api, esc, icon, can } from "./core.js?v=41";
import { capi } from "./views-qa.js?v=5";
import * as F from "./flashcard-stacks.js?v=1";
import { showDeck, adoptDeck } from "./flashcard-stacks-ui.js?v=1";

/** Panel fuellen. space: {key, kind, moduleId, name}; weeks: Lehrwochen des Moduls ({week, label, topic}) fuer die Beschriftung */
export async function renderDecksPanel(panel, { space, weeks = [] } = {}) {
  panel.innerHTML = `<p class="small muted">Karteikarten werden geladen …</p>`;
  let data, modules = [];
  try {
    [data, modules] = await Promise.all([capi(`/communities/${space.key}/decks`),
      space.moduleId ? Promise.resolve([]) : api("/flashcards/stacks").then(o => o.modules || [], () => [])]);
  } catch (e) { panel.innerHTML = `<div class="cc-note bad">${esc(F.communityHint(e))}</div>`; return; }
  if (!panel.isConnected) return;
  const topic = w => weeks.find(x => x.week === w)?.topic;
  const groups = F.groupDecks(data.decks);
  const locked = F.shareAccess(can);
  const deckHtml = d => `<div class="item"><div class="main"><div class="title">${icon("cards", 14)} ${esc(d.title)}</div>
      <div class="sub">${esc(F.deckMeta(d))}${d.preview?.length ? ` · ${esc(d.preview.join(" · "))}` : ""}</div></div>
      <button class="btn sm ghost" data-view="${esc(d.id)}">${icon("eye", 13)} Ansehen</button>
      ${d.mine ? "" : `<button class="btn sm${d.used_by_me ? "" : " primary"}" data-adopt="${esc(d.id)}" ${locked.locked ? "disabled" : ""}>${icon("download", 13)} ${d.used_by_me ? "Erneut übernehmen" : "Übernehmen"}</button>`}</div>`;
  panel.innerHTML = `${locked.locked ? `<div class="cc-note">${icon("lock", 13)} ${esc(locked.text)} <a href="${locked.href}">Tarife ansehen</a></div>` : ""}
    ${space.moduleId ? "" : `<label class="field" style="max-width:340px">Übernehmen in<select class="input" id="cdMod">${modules.map(m => `<option value="${m.id}">${esc(m.name)}</option>`).join("")}</select></label>`}
    ${groups.map(g => `<div class="card" style="margin-top:.7rem"><div class="card-head"><h3 style="margin:0">${esc(g.label)}${g.week != null && topic(g.week) ? ` <span class="small muted">· ${esc(topic(g.week))}</span>` : ""}</h3><span class="muted small">${g.decks.length} ${g.decks.length === 1 ? "Stapel" : "Stapel"}</span></div>
      <div class="list">${g.decks.map(deckHtml).join("")}</div></div>`).join("")
      || `<div class="card"><div class="cc-empty"><span class="cc-badge-ic">${icon("cards", 26)}</span><div>Noch niemand hat hier Karteikarten geteilt.</div></div></div>`}
    <p class="small muted" style="margin-top:.8rem">${icon("share", 13)} Eigene Karten teilst du unter <a href="#/cards">Karteikarten</a> → Stapel → Teilen.</p>`;
  const byId = new Map(data.decks.map(d => [d.id, d]));
  const target = () => space.moduleId ?? (Number($("#cdMod", panel)?.value) || null);
  const adopt = async d => { const ok = await adoptDeck(d, target()); if (ok) renderDecksPanel(panel, { space, weeks }); return ok; };
  $$("[data-view]", panel).forEach(b => b.onclick = () => { const d = byId.get(b.dataset.view); showDeck(d.id, d.mine || locked.locked ? {} : { onAdopt: adopt }); });
  $$("[data-adopt]", panel).forEach(b => b.onclick = () => adopt(byId.get(b.dataset.adopt)));
}

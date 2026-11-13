// Reiter "Karteikarten" im Community-Kanal (community-channel.js, 04.11.2026): geteilte Stapel der Modul-Community nach
// Lehrwoche ("Woche 5", "Allgemein"), ansehen und als eigenen Stapel uebernehmen (in das eigene Modul der Community,
// 0 Credits, ab Plus). Daten: GET /api/community/card-stacks?module=<Schluessel> (app/community_cards_api.py). Teilen geht
// von der Seite "Karteikarten" aus (Stapel -> ... -> Stapel teilen). Lerngruppen haben keine geteilten Stapel.
import { $$, api, esc, icon, can } from "./core.js?v=47";
import * as F from "./flashcard-stacks.js?v=3";
import { showShared, adoptShared, lockIcon } from "./flashcard-stacks-ui.js?v=6";

/** Panel fuellen. space: {key, kind, name}; weeks: Lehrwochen des Moduls ({week, label, topic}) fuer die Beschriftung */
export async function renderDecksPanel(panel, { space, weeks = [] } = {}) {
  if (space.kind === "group") { panel.innerHTML = `<div class="card"><p class="small muted" style="margin:0">Karteikarten-Stapel teilt man in der Community eines Moduls, nicht in Lerngruppen.</p></div>`; return; }
  panel.innerHTML = `<p class="small muted">Karteikarten werden geladen …</p>`;
  let data;
  try { data = await api(`/community/card-stacks?module=${encodeURIComponent(space.key)}`); } catch (e) { panel.innerHTML = `<div class="cc-note bad">${esc(F.communityHint(e))}</div>`; return; }
  if (!panel.isConnected) return;
  const topic = w => weeks.find(x => x.week === w)?.topic;
  const groups = F.groupShared(data.stacks);
  const locked = F.shareAccess(can);
  const row = s => `<div class="item"><div class="main"><div class="title">${icon("cards", 14)} ${esc(s.name)}</div>
      <div class="sub">${esc(F.sharedMeta(s))}</div></div>
      <button class="btn sm ghost" data-view="${esc(s.id)}">${icon("eye", 13)} Ansehen</button>
      ${s.mine ? "" : `<button class="btn sm${s.adopted ? "" : " primary"}" data-adopt="${esc(s.id)}" ${locked.locked || s.adopted ? "disabled" : ""}>${icon("download", 13)} ${s.adopted ? "Übernommen" : "Übernehmen"}</button>`}</div>`;
  panel.innerHTML = `${locked.locked ? `<div class="cc-note">${lockIcon(13)} ${esc(locked.text)} <a href="${locked.href}">Tarife ansehen</a></div>` : ""}
    ${groups.map(g => `<div class="card" style="margin-top:.7rem"><div class="card-head"><h3 style="margin:0">${esc(g.label)}${g.week != null && topic(g.week) ? ` <span class="small muted">· ${esc(topic(g.week))}</span>` : ""}</h3><span class="muted small">${g.stacks.length} Stapel</span></div>
      <div class="list">${g.stacks.map(row).join("")}</div></div>`).join("")
      || `<div class="card"><div class="cc-empty"><span class="cc-badge-ic">${icon("cards", 26)}</span><div>Noch niemand hat hier Karteikarten geteilt.</div></div></div>`}
    <p class="small muted" style="margin-top:.8rem">${icon("share", 13)} Eigene Karten teilst du unter <a href="#/cards">Karteikarten</a> → Stapel → Stapel teilen.</p>`;
  const byId = new Map(data.stacks.map(s => [s.id, s]));
  const adopt = async s => { const ok = await adoptShared(s); if (ok) renderDecksPanel(panel, { space, weeks }); return ok; };
  $$("[data-view]", panel).forEach(b => b.onclick = () => { const s = byId.get(b.dataset.view); showShared(s.id, s.mine || locked.locked || s.adopted ? {} : { onAdopt: adopt }); });
  $$("[data-adopt]", panel).forEach(b => b.onclick = () => adopt(byId.get(b.dataset.adopt)));
}

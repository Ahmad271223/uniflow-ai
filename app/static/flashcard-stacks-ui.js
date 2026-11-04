// Karteikarten-Stapel auf der Seite "Karteikarten" (04.11.2026): Stapel je Modul und Lernwoche, "KI-Karteikarten"
// (Pro AI: Modul, Lernwoche oder ganzes Modul, Anzahl, Vorschau, uebernehmen), "Teilen" je Stapel und "Aus der Community"
// (Plus). Regeln ohne DOM in flashcard-stacks.js. Community-Aufrufe gehen ueber /api/community/... (am PC an den Dienst
// weitergeleitet). Wird von viewCards (views-misc.js) eingehaengt; community-decks-ui.js nutzt showDeck/adoptDeck.
import { $, $$, api, esc, icon, toast, showError, modal, can } from "./core.js?v=41";
import { capi } from "./views-qa.js?v=5";
import * as F from "./flashcard-stacks.js?v=1";

/** Schloss (icons.js hat keins): gleiche Strichart wie die anderen Symbole */
export const lockIcon = (size = 16) => `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`;
const lockHtml = a => `<div class="small" style="display:flex;gap:.5rem;align-items:flex-start;padding:.6rem .7rem;border:1px dashed var(--line-strong);border-radius:10px">${lockIcon(16)}<span>${esc(a.text)} <a href="${a.href}" data-close>Tarife ansehen</a></span></div>`;
const swatch = c => (c && /^#[0-9a-f]{6}$/i.test(c) ? `<span aria-hidden="true" style="display:inline-block;width:.7rem;height:.7rem;border-radius:3px;background:${c};margin-right:.35rem"></span>` : "");

let spacesCache = null;
async function spaces() {
  if (!spacesCache) spacesCache = import("./community-spaces.js?v=17").then(m => m.loadSpaces()).catch(e => { spacesCache = null; throw e; });
  return spacesCache;
}

/** Karte "Stapel" auf der Karteikarten-Seite. opts: { all (alle Karten), onLearn(cards), reload(), ov (schon geladen),
 *  onLoaded(ov) } */
export async function mountStacks(el, { all = [], onLearn, reload, ov = null, onLoaded } = {}) {
  if (!ov) {
    try { ov = await api("/flashcards/stacks"); } catch (e) { el.innerHTML = `<div class="card small">${esc(e.message)}</div>`; return; }
    onLoaded?.(ov);
  }
  if (!el.isConnected) return;
  const byId = new Map(all.map(c => [c.id, c]));
  const ai = F.aiAccess(can);
  const row = (s, i) => `<div class="item" data-stack="${i}"><div class="main"><div class="title">${swatch(s.color)}${esc(s.module_name)} <span class="muted">· ${esc(s.module_id == null ? s.label : F.weekLabel(s.lecture_week))}</span></div>
      <div class="sub">${s.count} ${s.count === 1 ? "Karte" : "Karten"} · ${s.due} fällig${s.origins.ai ? ` · ${s.origins.ai} von der KI` : ""}${s.origins.community ? ` · ${s.origins.community} aus der Community` : ""}</div></div>
      <button class="btn sm" data-learn="${i}" ${s.count ? "" : "disabled"}>${icon("play", 13)} Lernen</button>
      ${s.module_id == null ? "" : `<button class="btn sm ghost" data-share="${i}" title="Stapel in der Community teilen">${icon("share", 13)} Teilen</button><button class="btn sm ghost" data-comm="${i}" title="Stapel anderer zu dieser Woche">${icon("users", 13)} Community</button>`}</div>`;
  el.innerHTML = `<div class="card" style="margin-top:1rem" id="fcStacks"><div class="card-head"><h2>${icon("layers", 18)} Stapel</h2><span class="spacer"></span>
      <button class="btn sm${ai.locked ? "" : " primary"}" id="stAi">${(ai.locked ? lockIcon(14) : icon("sparkles", 14))} KI-Karteikarten</button>
      <button class="btn sm" id="stComm">${icon("users", 14)} Aus der Community</button></div>
    <p class="small muted" style="margin:0 0 .4rem">Karten gehören zu einem Modul und einer Lernwoche – oder zum ganzen Modul.</p>
    <div class="list">${ov.stacks.map(row).join("") || `<div class="empty small">Noch keine Stapel. Lass dir Karten von der KI machen oder übernimm welche aus der Community.</div>`}</div></div>`;
  const done = () => (reload ? reload() : null);
  $("#stAi", el).onclick = () => openAiDialog(ov, {}, done);
  $("#stComm", el).onclick = () => openCommunityDialog(ov, {}, done);
  $$("[data-learn]", el).forEach(b => b.onclick = () => onLearn?.(ov.stacks[+b.dataset.learn].card_ids.map(id => byId.get(id)).filter(Boolean)));
  $$("[data-share]", el).forEach(b => b.onclick = () => { const s = ov.stacks[+b.dataset.share]; openShareDialog(s, s.card_ids.map(id => byId.get(id)).filter(Boolean)); });
  $$("[data-comm]", el).forEach(b => b.onclick = () => { const s = ov.stacks[+b.dataset.comm]; openCommunityDialog(ov, { moduleId: s.module_id, week: s.lecture_week }, done); });
}

/** Modul- und Wochenauswahl (gemeinsam fuer KI-Auftrag und Community) */
function pickerHtml(ov, preset) {
  const mods = ov.modules || [];
  const mid = preset.moduleId ?? mods[0]?.id;
  const mod = mods.find(m => m.id === mid) || mods[0];
  const opts = F.weekOptions(mod, ov.current_week);
  const sel = preset.week !== undefined ? String(preset.week ?? "module") : null;
  return `<label class="field">Fach<select class="input" id="pkMod">${mods.map(m => `<option value="${m.id}" ${m === mod ? "selected" : ""}>${esc(m.name)}</option>`).join("")}</select></label>
    <label class="field">Lernwoche<select class="input" id="pkWeek">${opts.map(o => `<option value="${o.value}" ${(sel !== null ? o.value === sel : o.selected) ? "selected" : ""}>${esc(o.label)}</option>`).join("")}${sel && sel !== "module" && !opts.some(o => o.value === sel) ? `<option value="${esc(sel)}" selected>Woche ${esc(sel)}</option>` : ""}</select></label>`;
}
function bindPicker(box, ov, onChange) {
  $("#pkMod", box).onchange = () => { const mod = ov.modules.find(m => m.id === +$("#pkMod", box).value); $("#pkWeek", box).innerHTML = F.weekOptions(mod, ov.current_week).map(o => `<option value="${o.value}" ${o.selected ? "selected" : ""}>${esc(o.label)}</option>`).join(""); onChange?.(); };
  $("#pkWeek", box).onchange = () => onChange?.();
}
const picked = box => ({ moduleId: +$("#pkMod", box).value, week: F.weekValue($("#pkWeek", box).value) });

// ---------------------------------------------------------------- KI-Karteikarten (Pro AI)

export function openAiDialog(ov, preset = {}, done) {
  const access = F.aiAccess(can);
  if (access.locked) { modal(`<h3>${lockIcon(18)} KI-Karteikarten</h3>${lockHtml(access)}<div class="modal-foot"><button class="btn" data-close>Schließen</button><a class="btn primary" href="#/abo" data-close>Zu den Tarifen</a></div>`); return; }
  if (!ov.modules?.length) { toast("Noch keine Module. Gleiche zuerst deine Hochschule ab.", 4000); return; }
  const m = modal(`<h3>${icon("sparkles", 18)} KI-Karteikarten</h3><div id="aiBody"></div>`, { wide: true });
  const box = $("#aiBody", m);
  const st = { cards: null, keep: new Set(), req: null, busy: false, info: null };
  const form = () => {
    box.innerHTML = `<p class="small muted" style="margin-top:0">Die StudiNow-KI nimmt das Material genau dieser Woche (markierte Vorlesungsseiten, Folien, Skript, Übungen) und macht so viele Karten, wie du willst. Karten, die du schon hast, kommen nicht doppelt.</p>
      ${pickerHtml(ov, preset)}
      <label class="field">Anzahl <b id="aiN">${F.COUNT.def}</b><input type="range" id="aiCount" min="${F.COUNT.min}" max="${F.COUNT.max}" step="1" value="${F.COUNT.def}"></label>
      <label class="field">Schwerpunkt (optional)<input class="input" id="aiTopic" maxlength="300" placeholder="z. B. Konvergenzkriterien"></label>
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="aiGo">${icon("sparkles", 14)} Karten erstellen</button></div>`;
    bindPicker(box, ov);
    $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
    $("#aiCount", box).oninput = e => { $("#aiN", box).textContent = e.target.value; };
    $("#aiGo", box).onclick = () => run(false);
  };
  const run = async again => {
    if (st.busy) return;
    if (!again) st.req = { ...picked(box), count: $("#aiCount", box).value, topic: $("#aiTopic", box).value };
    st.busy = true;
    box.innerHTML = `<p class="small">${icon("sparkles", 14)} Die KI erstellt ${F.clampCount(st.req.count)} Karten … das dauert etwa eine halbe Minute.</p>`;
    try {
      const r = await api("/ai/flashcards", { method: "POST", body: F.aiRequest({ ...st.req, again }) });
      st.cards = r.cards; st.keep = new Set(r.cards.map((_, i) => i)); st.info = r;
      preview();
    } catch (e) { st.busy = false; form(); showError(e, 6000); return; }
    st.busy = false;
  };
  const preview = () => {
    const r = st.info;
    box.innerHTML = `<p class="small" style="margin-top:0"><b>${esc(r.module_name)} · ${esc(F.weekLabel(r.lecture_week))}</b> – ${st.cards.length} Vorschläge${r.duplicates_removed ? `, ${r.duplicates_removed} doppelte weggelassen` : ""}.
        <span class="muted">Quellen: ${esc(r.sources.map(s => s.name).join(", ") || "–")}</span></p>
      <div class="list" style="max-height:50vh;overflow:auto">${st.cards.map((c, i) => `<label class="item" style="align-items:flex-start;cursor:pointer"><input type="checkbox" data-keep="${i}" ${st.keep.has(i) ? "checked" : ""} style="margin:.25rem .6rem 0 0"><div class="main"><div class="title">${esc(c.question)}</div><div class="sub">${esc(c.answer)}</div></div></label>`).join("")}</div>
      <div class="modal-foot"><button class="btn" data-close>Verwerfen</button><button class="btn" id="aiAgain">${icon("refresh", 14)} Andere Karten</button><button class="btn primary" id="aiSave">${icon("check", 14)} Übernehmen (<span id="aiK">${st.keep.size}</span>)</button></div>`;
    $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
    $$("[data-keep]", box).forEach(c => c.onchange = () => { c.checked ? st.keep.add(+c.dataset.keep) : st.keep.delete(+c.dataset.keep); $("#aiK", box).textContent = st.keep.size; });
    $("#aiAgain", box).onclick = () => run(true);
    $("#aiSave", box).onclick = async () => {
      const cards = st.cards.filter((_, i) => st.keep.has(i));
      if (!cards.length) { toast("Keine Karte ausgewählt."); return; }
      try {
        const r2 = await api("/flashcards/stack", { method: "POST", body: { module_id: r.module_id, lecture_week: r.lecture_week, cards, origin: "ai" } });
        m.remove(); toast(F.savedText(r2, "gespeichert"), 3500); done?.();
      } catch (e) { showError(e, 5000); }
    };
  };
  form();
}

// ---------------------------------------------------------------- Teilen (Plus)

export async function openShareDialog(stack, cards) {
  const access = F.shareAccess(can);
  if (access.locked) { modal(`<h3>${lockIcon(18)} Stapel teilen</h3>${lockHtml(access)}<div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`); return; }
  const m = modal(`<h3>${icon("share", 18)} Stapel teilen</h3><div id="shBody"><p class="small muted">Community wird geladen …</p></div>`);
  const box = $("#shBody", m);
  const { cards: usable, tooLong, cut } = F.shareCards(cards);
  let space, mine;
  try { space = F.spaceForModule((await spaces()).spaces, stack.module_id); mine = space ? (await capi("/decks/mine")).decks : []; }
  catch (e) { box.innerHTML = `<p class="small">${esc(F.communityHint(e))}</p><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`; $$("[data-close]", box).forEach(b => b.onclick = () => m.remove()); return; }
  if (!space) { box.innerHTML = `<p class="small">Für dieses Modul gibt es keine Kurs-Community (kein Kurs aus deinem Hochschul-Abgleich).</p><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`; $$("[data-close]", box).forEach(b => b.onclick = () => m.remove()); return; }
  const own = F.ownDeck(mine, space.key, stack.lecture_week);
  const draw = () => {
    box.innerHTML = `<p class="small" style="margin-top:0">Für alle in der Community <b>${esc(space.name)}</b> (${esc(F.weekLabel(stack.lecture_week))}), unter deinem Pseudonym. ${usable.length} ${usable.length === 1 ? "Karte" : "Karten"}${cut ? ` (die ersten ${F.SHARE.maxCards})` : ""}; versteckte Karten bleiben privat.</p>
      ${tooLong ? `<p class="small" style="color:var(--bad-text)">${tooLong} ${tooLong === 1 ? "Karte hat" : "Karten haben"} mehr als ${F.SHARE.maxSide} Zeichen je Seite. Kürze sie zuerst.</p>` : ""}
      ${own ? `<p class="small">${icon("info", 13)} Du hast hier schon einen Stapel geteilt („${esc(own.title)}“). Teilen ersetzt seine Karten.</p>` : ""}
      ${space.joined ? "" : `<p class="small">${icon("info", 13)} Du bist noch nicht Mitglied dieser Community.</p>`}
      <label class="field">Titel<input class="input" id="shTitle" maxlength="${F.SHARE.maxTitle}" value="${esc(own?.title || F.stackTitle(stack))}"></label>
      <p class="tiny muted">Bitte keine persönlichen Daten und keine bewerteten Abgaben teilen.</p>
      <div class="modal-foot"><button class="btn" data-close>Abbrechen</button>${space.joined ? "" : `<button class="btn" id="shJoin">${icon("plus", 14)} Beitreten</button>`}<button class="btn primary" id="shGo" ${!space.joined || tooLong || !usable.length ? "disabled" : ""}>${icon("share", 14)} ${own ? "Aktualisieren" : "Teilen"}</button></div>`;
    $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
    $("#shJoin", box)?.addEventListener("click", async () => { try { await capi(`/communities/${space.key}/join`, { method: "POST", body: { kind: "course" } }); space.joined = true; spacesCache = null; draw(); } catch (e) { showError(e, 5000); } });
    $("#shGo", box).onclick = async () => {
      const body = F.shareBody(stack, usable, $("#shTitle", box).value);
      try {
        if (own) await capi(`/decks/${own.id}`, { method: "PUT", body: { title: body.title, cards: body.cards } });
        else await capi(`/communities/${space.key}/decks`, { method: "POST", body });
        m.remove(); toast(own ? "Geteilter Stapel aktualisiert" : "Stapel geteilt", 3000);
      } catch (e) { showError(e, 6000); }
    };
  };
  draw();
}

// ---------------------------------------------------------------- Aus der Community (Plus)

/** Stapel ansehen; mit onAdopt einen Knopf "Übernehmen" */
export async function showDeck(deckId, { onAdopt } = {}) {
  let d;
  try { d = await capi(`/decks/${deckId}`); } catch (e) { showError(e, 5000); return; }
  const m = modal(`<h3>${icon("cards", 18)} ${esc(d.title)}</h3><p class="small muted" style="margin-top:0">${esc(F.weekLabel(d.lecture_week))} · ${esc(F.deckMeta(d))}</p>
    <div class="list" style="max-height:55vh;overflow:auto">${d.cards.map(c => `<div class="item"><div class="main"><div class="title">${esc(c.question)}</div><div class="sub">${esc(c.answer)}</div></div></div>`).join("")}</div>
    <div class="modal-foot">${d.mine ? "" : `<button class="btn ghost" data-report>${icon("flag", 14)} Melden</button>`}<button class="btn" data-close>Schließen</button>${onAdopt ? `<button class="btn primary" data-adopt>${icon("download", 14)} Übernehmen</button>` : ""}</div>`, { wide: true });
  $("[data-adopt]", m)?.addEventListener("click", async () => { if (await onAdopt(d)) m.remove(); });
  $("[data-report]", m)?.addEventListener("click", async () => {
    if (!confirm("Diesen Stapel melden (z. B. Spam, beleidigend, fremdes Material)?")) return;
    try { await capi(`/decks/${d.id}/report`, { method: "POST", body: { reason: "other" } }); toast("Danke, der Stapel wurde gemeldet."); m.remove(); } catch (e) { showError(e, 5000); }
  });
}

/** In die eigenen Karten uebernehmen (Kopie mit Herkunft); true bei Erfolg */
export async function adoptDeck(deck, moduleId) {
  const access = F.shareAccess(can);
  if (access.locked) { toast(access.text, 5000); return false; }
  if (moduleId == null) { toast("Wähle zuerst ein Modul für die Karten.", 4000); return false; }
  try {
    const a = await capi(`/decks/${deck.id}/adopt`, { method: "POST" });
    const r = await api("/flashcards/stack", { method: "POST", body: F.adoptBody(a, moduleId) });
    toast(F.savedText(r), 3500);
    return true;
  } catch (e) { showError(e, 6000); return false; }
}

export async function openCommunityDialog(ov, preset = {}, done) {
  if (!ov.modules?.length) { toast("Noch keine Module. Gleiche zuerst deine Hochschule ab.", 4000); return; }
  const m = modal(`<h3>${icon("users", 18)} Karteikarten aus der Community</h3>${F.shareAccess(can).locked ? lockHtml(F.shareAccess(can)) : ""}<div id="cdPick" class="row wrap" style="gap:.6rem"></div><div id="cdList" style="margin-top:.6rem"></div><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`, { wide: true });
  const pick = $("#cdPick", m), list = $("#cdList", m);
  pick.innerHTML = pickerHtml(ov, preset);
  const load = async () => {
    const { moduleId, week } = picked(pick);
    list.innerHTML = `<p class="small muted">Wird geladen …</p>`;
    let space;
    try { space = F.spaceForModule((await spaces()).spaces, moduleId); } catch (e) { list.innerHTML = `<p class="small">${esc(F.communityHint(e))}</p>`; return; }
    if (!space) { list.innerHTML = `<p class="small">Für dieses Modul gibt es keine Kurs-Community.</p>`; return; }
    if (!space.joined) {
      list.innerHTML = `<p class="small">Tritt der Community <b>${esc(space.name)}</b> bei, um ihre Karteikarten zu sehen.</p><button class="btn sm primary" id="cdJoin">${icon("plus", 14)} Beitreten</button>`;
      $("#cdJoin", list).onclick = async () => { try { await capi(`/communities/${space.key}/join`, { method: "POST", body: { kind: "course" } }); space.joined = true; spacesCache = null; load(); } catch (e) { showError(e, 5000); } };
      return;
    }
    let decks;
    try { decks = (await capi(`/communities/${space.key}/decks?week=${week ?? "module"}`)).decks; } catch (e) { list.innerHTML = `<p class="small">${esc(F.communityHint(e))}</p>`; return; }
    list.innerHTML = decks.length ? `<div class="list">${decks.map((d, i) => `<div class="item"><div class="main"><div class="title">${esc(d.title)}</div><div class="sub">${esc(F.deckMeta(d))}${d.preview?.length ? ` · ${esc(d.preview.join(" · "))}` : ""}</div></div>
        <button class="btn sm ghost" data-view="${i}">${icon("eye", 13)} Ansehen</button>${d.mine ? "" : `<button class="btn sm${d.used_by_me ? "" : " primary"}" data-adopt="${i}">${icon("download", 13)} ${d.used_by_me ? "Erneut übernehmen" : "Übernehmen"}</button>`}</div>`).join("")}</div>`
      : `<p class="small muted">Für ${esc(F.weekLabel(week))} hat hier noch niemand Karteikarten geteilt.</p>`;
    $$("[data-view]", list).forEach(b => b.onclick = () => showDeck(decks[+b.dataset.view].id, decks[+b.dataset.view].mine ? {} : { onAdopt: async d => { const ok = await adoptDeck(d, moduleId); if (ok) done?.(); return ok; } }));
    $$("[data-adopt]", list).forEach(b => b.onclick = async () => { if (await adoptDeck(decks[+b.dataset.adopt], moduleId)) { done?.(); load(); } });
  };
  bindPicker(pick, ov, load);
  load();
}

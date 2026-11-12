// Korrekturvorschlaege in der Oberflaeche (Windows-App und Web): Posteingang des Erstellers (Oeffnen, Ignorieren, Gesehen),
// Korrekturen unter der Diskussion einer Loesung, Abzeichen am Menuepunkt "Community". Gegenstueck zu
// CorrectionCommunityViews.swift und CommunityBadge.swift auf dem iPad. Chiffrat und Texte: community-corrections.js.
import { icon } from "./icons.js?v=33";
import * as C from "./community-corrections.js?v=2";
import * as L from "./community-logic.js?v=3";
import { capi } from "./views-qa.js?v=9";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const REASONS = { offensive: "anstößig", spam: "Spam", foreignMaterial: "Fremdmaterial", gradedSubmission: "benotete Abgabe", other: "Sonstiges" };
export const changed = () => { try { window.dispatchEvent(new Event("cc:changed")); } catch {} };

// ---------------------------------------------------------------- Abzeichen am Menuepunkt

/** Gibt es hier Korrekturen? Im Dienst immer, am PC nur mit verbundenem StudiNow-Konto (ohne Konto antwortet die
 *  Weiterleitung 409 - der Zaehler wuerde sonst alle 2 Minuten einen Fehler erzeugen). Ohne Rueckfrage beim Dienst. */
let availableCache = null;
export async function available() {
  if (availableCache) return availableCache;
  availableCache = fetch("/api/studora/status?refresh=false").then(r => r.ok ? r.json() : {}).then(s => !!(s.hosted || s.linked)).catch(() => false);
  const v = await availableCache;
  setTimeout(() => { availableCache = null; }, 60000);           // An-/Abmelden wirkt spaetestens nach einer Minute
  return v;
}

/** Zahl offener Korrekturhinweise (nicht geoeffnet, nicht ignoriert); null = Community hier nicht verfuegbar. */
export async function inboxCount() {
  if (!(await available())) return null;
  try { return (await capi("/corrections/inbox?count_only=true")).open; } catch { return null; }
}
/** Zahl am Menuepunkt "Community" (Seitenleiste); 0 oder null entfernt sie. */
export function setBadge(n) {
  const text = C.badgeText(n || 0), label = `${n} offene${n === 1 ? "r" : ""} Korrekturhinweis${n === 1 ? "" : "e"}`;
  if (text) L.ensureCss();                                      // die Zahl braucht ihre Gestaltung schon vor der Community-Seite
  // Seitenleiste (Menuepunkt "Community") und Menue-Knopf der schmalen Ansicht
  for (const [el, cls] of [[$('#nav a[data-route="community"]'), "cc-count"], [$("#menuBtn"), "cc-count cc-menu"]]) {
    if (!el) continue;
    let b = $(".cc-count", el);
    if (!text) { b?.remove(); if (el.id !== "menuBtn") el.removeAttribute("title"); continue; }
    if (!b) { b = document.createElement("span"); b.className = cls; el.append(b); }
    b.textContent = text; b.setAttribute("aria-label", label);
    if (el.id !== "menuBtn") el.title = C.editorHint(n);
  }
}
let polling = false;
/** Zaehler sparsam holen: einmal nach dem Start, danach alle 2 Minuten bei sichtbarem Fenster und nach jeder Aenderung. */
export function startBadgePolling() {
  if (polling) return; polling = true;
  const poll = async () => { if (!document.hidden) setBadge(await inboxCount()); };
  setTimeout(poll, 5000); setInterval(poll, 120000);
  window.addEventListener("cc:changed", poll);
}

// ---------------------------------------------------------------- Eigene Datei zu einer Loesung

/** Eigene Datei zu einem Fingerabdruck; null = keine auf diesem Geraet. */
export async function localFile(fingerprint) {
  if (!fingerprint) return null;
  try { const r = await fetch(`/api/files/by-fingerprint/${fingerprint}`); return r.ok ? await r.json() : null; } catch { return null; }
}
/** Im Dokument oeffnen und dort etwas tun: `cmd` = {correct: solutionId} (Korrektur schreiben) oder {view: correctionId} (ansehen). */
export function openInEditor(file, cmd) {
  try { sessionStorage.setItem("cc-cmd", JSON.stringify(cmd)); sessionStorage.setItem("open-community", "1"); } catch {}
  location.hash = `#/doc/${encodeURIComponent(file.file_id)}`;
}
export function takeCommand() {
  try { const v = sessionStorage.getItem("cc-cmd"); sessionStorage.removeItem("cc-cmd"); return v ? JSON.parse(v) : null; } catch { return null; }
}

// ---------------------------------------------------------------- Korrekturen einer Loesung (unter der Diskussion)

/** Korrekturen zu einer Loesung mit dem Geheimnis der Community lesen; unlesbare (anderer Schluessel, beschaedigt) fallen weg. */
export async function loadCorrections(solutionId, secret) {
  const rows = (await capi(`/solutions/${solutionId}/corrections`)).corrections || [];
  const out = [];
  for (const r of rows) {
    try { out.push({ ...r, content: await C.open(r.payload, r.id, solutionId, secret) }); } catch { /* nicht lesbar: nicht zeigen */ }
  }
  return out;
}
export async function reasonPick() {
  const p = prompt(`Grund der Meldung (${Object.values(REASONS).join(", ")}):`, "Spam"); if (!p) return null;
  return Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.trim().toLowerCase().slice(0, 4))) || "other";
}

/** Eine Korrektur als Karte: Name, Zeit, Zusammenfassung, Begleittext, Knoepfe Ansehen / Zuruecknehmen / Melden. */
export function correctionCard(c) {
  const n = C.displayName(c.content || c);
  return `<div class="cc-corr" data-corr="${esc(c.id)}">
    <div class="row" style="gap:.5rem;align-items:center"><span class="cc-av t${L.tint(n)}">${esc(L.initial(n))}</span><b>${esc(C.entryTitle(c.content || c))}</b><span class="tiny muted">${esc(L.relative(c.created_at))}</span>${c.mine ? `<span class="badge neutral">deine</span>` : ""}</div>
    <div class="small muted">${esc(C.summary(c.content))}</div>
    ${c.content.note ? `<div class="small" style="white-space:pre-wrap;overflow-wrap:anywhere">${esc(c.content.note)}</div>` : ""}
    <div class="cc-act"><button class="btn sm" data-cview="${esc(c.id)}">${icon("eye", 13)} Ansehen</button>
      ${c.mine ? `<button class="btn sm ghost" data-cdelete="${esc(c.id)}">${icon("trash", 13)} Zurücknehmen</button>` : `<button class="btn sm ghost" data-creport="${esc(c.id)}">Melden</button>`}</div></div>`;
}
/** Knoepfe der Karten verbinden. `ctx`: {solution, onChange(), toast(msg)}. */
export function bindCorrections(el, list, ctx) {
  $$("[data-cview]", el).forEach(b => b.onclick = async () => {
    const f = await localFile(ctx.solution.fingerprint);
    if (!f) { ctx.toast(C.TEXTS.needsPDFToView); return; }
    openInEditor(f, { view: b.dataset.cview });
  });
  $$("[data-cdelete]", el).forEach(b => b.onclick = async () => {
    if (!confirm("Deine Korrektur zurücknehmen?")) return;
    try { await capi(`/corrections/${b.dataset.cdelete}`, { method: "DELETE" }); ctx.toast(C.TEXTS.deleted); ctx.onChange(); } catch (e) { ctx.toast(e.message); }
  });
  $$("[data-creport]", el).forEach(b => b.onclick = async () => {
    const reason = await reasonPick(); if (!reason) return;
    try { await capi(`/corrections/${b.dataset.creport}/report`, { method: "POST", body: { reason } }); ctx.toast(C.TEXTS.reported); ctx.onChange(); } catch (e) { ctx.toast(e.message); }
  });
}

// ---------------------------------------------------------------- Posteingang des Erstellers

async function setStatus(id, status) { await capi(`/corrections/${id}/status`, { method: "POST", body: { status } }); changed(); }

/**
 * Hinweise "Deine Lösung hat einen Korrekturhinweis von <Name> bekommen" mit Öffnen / Ignorieren; schon geöffnete in
 * der Gruppe "Gesehen (N)". `communityKey`: nur die Lösungen dieser Community (Seite einer Community), sonst alle.
 */
export async function renderInbox(el, { communityKey = null, onChange = () => {}, toast = alert, emptyText = null } = {}) {
  let box;
  if (!(await available())) { el.innerHTML = ""; return 0; }
  try { box = await capi("/corrections/inbox"); } catch (e) { el.innerHTML = `<p class="small muted">${esc(e.message)}</p>`; return 0; }
  const items = (box.items || []).filter(c => !communityKey || c.community_key === communityKey);
  const { open, seen } = C.groupInbox(items);
  if (!items.length) { el.innerHTML = emptyText ? `<p class="small muted">${esc(emptyText)}</p>` : ""; return 0; }
  const row = c => `<div class="cc-corr${c.status === "seen" ? " seen" : ""}" data-iid="${esc(c.id)}">
      <div>${esc(C.inboxMessage({ pseudonym: c.pseudonym }, c.title))}</div>
      <div class="tiny muted">${esc(L.relative(c.created_at))}${c.status === "seen" ? ` · ${C.TEXTS.seen}` : ""}</div>
      <div class="cc-act"><button class="btn sm primary" data-iopen="${esc(c.id)}">Öffnen</button><button class="btn sm ghost" data-iignore="${esc(c.id)}">Ignorieren</button></div></div>`;
  el.innerHTML = `<section class="cc-inbox" aria-label="Korrekturhinweise">
    <div class="cc-inbox-head">${icon("bell", 16)} Korrekturhinweise${open.length ? ` <span class="cc-count">${open.length}</span>` : ""}</div>
    ${open.map(row).join("")}
    ${seen.length ? `<details class="cc-seen"><summary class="small muted" style="cursor:pointer;min-height:36px">${esc(C.seenGroup(seen.length))}</summary><div class="cc-inbox">${seen.map(row).join("")}</div></details>` : ""}</section>`;
  const byId = id => items.find(c => c.id === id);
  $$("[data-iopen]", el).forEach(b => b.onclick = async () => {
    const c = byId(b.dataset.iopen);
    const f = await localFile(c.fingerprint);
    if (!f) { toast(C.TEXTS.needsPDFToView); return; }
    try { if (c.status !== "seen") await setStatus(c.id, "seen"); } catch {}        // Oeffnen = gesehen
    openInEditor(f, { view: c.id });
  });
  $$("[data-iignore]", el).forEach(b => b.onclick = async () => {
    try { await setStatus(b.dataset.iignore, "ignored"); } catch (e) { toast(e.message); return; }
    onChange();
  });
  return open.length;
}

// Schwarzes Brett aus Stud.IP unter "Uni & Noten" (Auftrag des Inhabers 03.11.2026: "mit einbinden, wenn eine Uni das
// hat"), 1:1 nach apps/apple/UniFlow/Views/Services/BulletinCard.swift. Eine ruhige Karte, nur wenn die Hochschule das
// Brett hat und Anzeigen gespeichert sind: Themen-Chips mit Anzahl, Liste der Anzeigen (ganzer Titel, Thema, Tag, ganzer
// Text; nie "…"), Antippen oeffnet einen einfachen Leser mit "In Stud.IP öffnen". Daten: GET /api/studip/bulletin und
// /api/studip/bulletin/{id} (app/studip_bulletin.py, nur lokal, keine Autoren). Im gehosteten Dienst und bei Hochschulen
// ohne Brett meldet der Server available=false; dann bleibt die Karte weg.
import { $, $$, esc, icon, safeUrl, fmtShort, fmtDate, modal } from "./core.js?v=46";

export const BULLETIN = { title: "Schwarzes Brett", readerOpen: "In Stud.IP öffnen", all: "Alle", icon: "note", shown: 8,
  note: "Kleinanzeigen aus dem Schwarzen Brett in Stud.IP, nur auf diesem Gerät gespeichert; Namen der Anbietenden holt StudiNow nicht.",
  readerNote: "Antworten und Kontakt über die Anzeige in Stud.IP." };

/// "Schwarzes Brett: 5 neue Anzeigen" fuer die Karte "Neuigkeiten"
export const newLine = n => `${BULLETIN.title}: ${n} neue ${n === 1 ? "Anzeige" : "Anzeigen"}`;

/// "Anzeige: Fahrrad zu verkaufen · Biete · Mo., 02.11."
export const accessibility = e => ["Anzeige: " + (e.title || ""), e.topic || "", e.posted_at ? fmtShort(e.posted_at.slice(0, 10)) : ""].filter(Boolean).join(" · ");

export const filterEntries = (entries, topic) => topic ? (entries || []).filter(e => e.topic === topic) : (entries || []);

/// Link nur mit http(s); sonst keiner
const link = (url, label, cls = "btn sm") => { const u = safeUrl(url); return u === "#" ? "" : `<a class="${cls}" href="${esc(u)}" target="_blank" rel="noopener">${esc(label)} ${icon("arrow-right", 14)}</a>`; };

/// Eine Zeile: ganzer Titel, Tag, Thema, ganzer Text (Absaetze bleiben), nie gekuerzt
export function entryRow(e) {
  return `<div class="bb-entry" role="button" tabindex="0" data-bid="${esc(e.id)}" aria-label="${esc(accessibility(e))}">
    <div class="bb-head"><b class="bb-title">${esc(e.title)}</b><span class="bb-date">${e.posted_at ? esc(fmtShort(e.posted_at.slice(0, 10))) : ""}</span></div>
    <span class="badge neutral">${esc(e.topic)}</span>
    ${e.text ? `<div class="bb-text">${esc(e.text)}</div>` : ""}</div>`;
}

/// Karte; ui = { topic, expanded }. Leer, wenn die Hochschule kein Brett hat oder nichts gespeichert ist.
export function cardHtml(data, ui = { topic: "", expanded: false }) {
  const entries = data?.entries || [];
  if (!data?.available || !entries.length) return "";
  const shown = filterEntries(entries, ui.topic);
  const rows = ui.expanded ? shown : shown.slice(0, BULLETIN.shown);
  const chips = [`<button class="chip ${ui.topic ? "" : "on"}" data-btopic="">${BULLETIN.all} ${entries.length}</button>`,
    ...(data.topics || []).map(t => `<button class="chip ${ui.topic === t.title ? "on" : ""}" data-btopic="${esc(t.title)}">${esc(t.title)} ${t.count}</button>`)].join("");
  return `<section class="card bb-card" aria-label="${BULLETIN.title}"><div class="card-head"><h2>${icon(BULLETIN.icon, 18)} ${BULLETIN.title}</h2>${link(data.url, BULLETIN.readerOpen)}</div>
    <div class="row wrap bb-topics" role="group" aria-label="Themen" style="gap:.4rem;margin-bottom:.4rem">${chips}</div>
    <div class="bb-list">${rows.map(entryRow).join("")}</div>
    ${shown.length > BULLETIN.shown ? `<button class="btn ghost sm" id="bbMore">${ui.expanded ? "Weniger anzeigen" : `Alle ${shown.length} anzeigen`}</button>` : ""}
    <p class="muted tiny" style="margin-top:.6rem">${BULLETIN.note}</p></section>`;
}

/// Leser: Titel, Thema und Tag, ganzer Text, Hinweis, "In Stud.IP öffnen"
export function readerHtml(d) {
  return `<h3>${icon(BULLETIN.icon, 18)} ${esc(d.title)}</h3>
    <div class="muted small" style="margin-bottom:.6rem">${[d.topic, d.posted_at ? fmtDate(d.posted_at.slice(0, 10)) : ""].filter(Boolean).map(esc).join(" · ")}</div>
    <div class="bb-reader">${esc(d.text)}</div>
    <p class="muted tiny" style="margin-top:.6rem">${BULLETIN.readerNote}</p>
    <div class="modal-foot">${link(d.url, BULLETIN.readerOpen)}<button class="btn primary" data-close>Schließen</button></div>`;
}

export async function openReader(id, api) {
  const m = modal(`<h3>${icon(BULLETIN.icon, 18)} ${BULLETIN.title}</h3><div class="muted"><span class="uf-shimmer">Lade Anzeige …</span></div>`);
  try { $(".modal-box", m).innerHTML = readerHtml(await api(`/studip/bulletin/${encodeURIComponent(id)}`)); $$("[data-close]", m).forEach(b => b.onclick = () => m.remove()); }
  catch (e) { $(".modal-box", m).innerHTML = `<h3>${BULLETIN.title}</h3><p class="small">${icon("alert", 14)} ${esc(e.message)}</p><div class="modal-foot"><button class="btn primary" data-close>Schließen</button></div>`; $$("[data-close]", m).forEach(b => b.onclick = () => m.remove()); }
}

/// Zeichnet die Karte in `host` (ein leeres Element) und bindet Chips, "Alle anzeigen" und Zeilen
export function renderCard(host, data, api, ui = { topic: "", expanded: false }) {
  host.innerHTML = cardHtml(data, ui);
  const again = () => renderCard(host, data, api, ui);
  $$("[data-btopic]", host).forEach(b => b.onclick = () => { ui.topic = b.dataset.btopic; ui.expanded = false; again(); });
  $("#bbMore", host)?.addEventListener("click", () => { ui.expanded = !ui.expanded; again(); });
  $$("[data-bid]", host).forEach(el => { const go = () => openReader(el.dataset.bid, api); el.onclick = go; el.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); } }; });
}

/// Laedt GET /api/studip/bulletin und zeichnet die Karte; ohne Brett oder bei Fehler bleibt `host` leer
export async function mountBulletin(host, api) {
  let data = null;
  try { data = await api("/studip/bulletin"); } catch { return; }
  if (host.isConnected !== false) renderCard(host, data, api);
}

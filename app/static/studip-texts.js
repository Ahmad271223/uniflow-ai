// "Aus Stud.IP" in der Modulansicht (Uebersicht), 1:1 nach apps/apple/UniFlow/Views/Modules/StudIPTextsCard.swift: ein
// einziger, standardmaessig zugeklappter Bereich mit einer kurzen Zeile je Quelle (Courseware · Wiki · Forum, Anzahl,
// zuletzt geaendert). Antippen einer Zeile zeigt die Eintraege, ein Eintrag oeffnet einen einfachen Leser (ganzer Text,
// Herkunft, "In Stud.IP öffnen"). Daten: GET /api/modules/{id}/studip und /api/studip-texts/{id} (app/studip_texts.py).
// Ohne Eintraege erscheint der Bereich nicht. Die Fristen der Courseware-Aufgaben stehen nicht hier, sondern wo Fristen
// schon stehen ("Abgaben & Prüfungen", Planer). Dazu "Blubber" (Kurs-Chats, GET /api/studip/blubber?module=): der Abgleich
// ist vorerst ausgeschaltet (app/studip_blubber.py SYNC_ENABLED), die Gruppe erscheint nur, wenn Beitraege gespeichert sind.
import { $, $$, esc, icon, safeUrl, fmtShort, modal } from "./core.js?v=42";

export const TEXTS = { title: "Aus Stud.IP", readerOpen: "In Stud.IP öffnen", icons: { courseware: "book", wiki: "file-text", forum: "users", blubber: "note" }, blubberLabel: "Blubber" };

/// Bereich "Blubber" wie die Gruppen von /api/modules/{id}/studip; null ohne Threads
export function blubberGroup(v) {
  const threads = v?.threads || [];
  if (!threads.length) return null;
  const changed = threads.map(t => t.changed).filter(Boolean).sort().pop() || null;
  return { kind: "blubber", label: TEXTS.blubberLabel, count: threads.length, changed, items: threads };
}

/// Zweite Zeile eines Threads: "Analysis I · 3 neu · Mo., 02.11."
export const threadDetail = t => [t.course_title || "", t.new_count > 0 ? `${t.new_count} neu` : "", t.changed ? fmtShort(t.changed.slice(0, 10)) : ""].filter(Boolean).join(" · ");

/// "Courseware · 3 · geändert Fr., 31.10."
export const groupLine = g => `${g.label} · ${g.count}${g.changed ? ` · geändert ${fmtShort(g.changed)}` : ""}`;

/// Kopfzeile zugeklappt: "Courseware 3 · Wiki 2 · Forum 1"
export const summary = groups => groups.map(g => `${g.label} ${g.count}`).join(" · ");

const link = (url, cls = "btn sm") => { const u = safeUrl(url); return u === "#" ? "" : `<a class="${cls}" href="${esc(u)}" target="_blank" rel="noopener">${TEXTS.readerOpen} ${icon("arrow-right", 14)}</a>`; };

/// Zeile eines Eintrags: ganzer Titel (umbrechend), darunter Kurs und Tag
function itemRow(x) {
  return `<button class="st-item" data-stid="${esc(x.id)}"><b>${esc(x.title)}</b><span class="muted tiny">${esc([x.course_title, x.changed ? fmtShort(x.changed) : ""].filter(Boolean).join(" · "))}</span></button>`;
}
/// Zeile eines Blubber-Threads: neuester Beitrag (Rolle: Text) ganz, darunter Kurs, Zahl neuer Beitraege, Tag
function threadRow(t) {
  return `<button class="st-item" data-btid="${esc(t.id)}" aria-label="${esc(`Blubber: ${t.preview} · ${threadDetail(t)}`)}"><b>${esc(t.preview)}</b><span class="muted tiny">${esc(threadDetail(t))}</span></button>`;
}

/// Karte; ui = { expanded, open (Art der aufgeklappten Gruppe) }. Leer ohne Gruppen.
export function cardHtml(groups, ui = { expanded: false, open: null }) {
  if (!groups.length) return "";
  const rows = ui.expanded ? groups.map(g => {
    const open = ui.open === g.kind;
    return `<div class="st-group"><button class="st-line" data-stkind="${esc(g.kind)}" aria-expanded="${open}">${icon(TEXTS.icons[g.kind] || "file", 15)}<span>${esc(groupLine(g))}</span>${icon("chevron-right", 13)}</button>
      ${open ? `<div class="st-items">${g.items.map(g.kind === "blubber" ? threadRow : itemRow).join("")}</div>` : ""}</div>`;
  }).join("") : "";
  return `<section class="card st-card" aria-label="${TEXTS.title}"><button class="st-head" id="stToggle" aria-expanded="${!!ui.expanded}" title="Courseware, Wiki, Forum und Blubber aus Stud.IP zeigen">${icon("chevron-right", 16)}<b>${TEXTS.title}</b>${ui.expanded ? "" : `<span class="muted small">${esc(summary(groups))}</span>`}</button>${rows}</section>`;
}

/// Leser fuer einen Stud.IP-Text: Art, Kurs, Aenderung, ganzer Text, "In Stud.IP öffnen"
export function readerHtml(d) {
  const meta = [d.kind_label, d.course_title, d.changed ? "geändert " + fmtShort(d.changed) : ""].filter(Boolean).map(esc).join(" · ");
  return `<h3>${icon(TEXTS.icons[d.kind] || "file-text", 18)} ${esc(d.title)}</h3><div class="muted small" style="margin-bottom:.6rem">${meta}</div>
    <div class="bb-reader">${esc(d.text)}</div><div class="modal-foot">${link(d.url)}<button class="btn primary" data-close>Schließen</button></div>`;
}

/// "Lehrende · Mo., 02.11. 09:30"
export const commentHead = c => (c.role || "") + (c.posted_at && c.posted_at.length >= 16 ? ` · ${fmtShort(c.posted_at.slice(0, 10))} ${c.posted_at.slice(11, 16)}` : "");

/// Leser fuer einen Blubber-Thread: Beitraege der Reihe nach mit Rolle statt Name
export function blubberReaderHtml(d) {
  return `<h3>${icon(TEXTS.icons.blubber, 18)} Blubber · ${esc(d.course_title || "")}</h3>
    ${(d.comments || []).map(c => `<div class="st-comment"><div class="small" style="font-weight:600">${esc(commentHead(c))}</div><div class="bb-reader">${esc(c.text)}</div></div>`).join("")}
    <p class="muted tiny">Nur die neuesten Beiträge, ohne Namen; StudiNow markiert in Stud.IP nichts als gelesen.</p>
    <div class="modal-foot">${link(d.url)}<button class="btn primary" data-close>Schließen</button></div>`;
}

async function openReader(path, html, api) {
  const m = modal(`<h3>${TEXTS.title}</h3><div class="muted"><span class="uf-shimmer">Lade …</span></div>`, { wide: true });
  const box = $(".modal-box", m);
  try { box.innerHTML = html(await api(path)); } catch (e) { box.innerHTML = `<h3>${TEXTS.title}</h3><p class="small">${icon("alert", 14)} ${esc(e.message)}</p><div class="modal-foot"><button class="btn primary" data-close>Schließen</button></div>`; }
  $$("[data-close]", m).forEach(b => b.onclick = () => m.remove());
}

export function renderCard(host, groups, api, ui = { expanded: false, open: null }) {
  host.innerHTML = cardHtml(groups, ui);
  const again = () => renderCard(host, groups, api, ui);
  $("#stToggle", host)?.addEventListener("click", () => { ui.expanded = !ui.expanded; again(); });
  $$("[data-stkind]", host).forEach(b => b.onclick = () => { ui.open = ui.open === b.dataset.stkind ? null : b.dataset.stkind; again(); });
  $$("[data-stid]", host).forEach(b => b.onclick = () => openReader(`/studip-texts/${encodeURIComponent(b.dataset.stid)}`, readerHtml, api));
  $$("[data-btid]", host).forEach(b => b.onclick = () => openReader(`/studip/blubber/${encodeURIComponent(b.dataset.btid)}`, blubberReaderHtml, api));
}

/// Laedt die Gruppen des Moduls und zeichnet den Bereich in `host`; ohne Eintraege oder bei Fehler bleibt `host` leer
export async function mountStudipTexts(host, moduleId, api) {
  const [texts, blubber] = await Promise.all([api(`/modules/${moduleId}/studip`).catch(() => null), api(`/studip/blubber?module=${moduleId}`).catch(() => null)]);
  const groups = [...(texts?.groups || []), blubberGroup(blubber)].filter(Boolean);
  if (host.isConnected !== false) renderCard(host, groups, api);
}

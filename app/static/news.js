// Karte "Neuigkeiten" auf der Uebersicht (Auftrag des Inhabers 02.11.2026: "alles schlau einbauen, nicht ueberladen"),
// 1:1 nach apps/apple/UniFlow/Views/NewsCard.swift. Eine Karte statt vieler: Ankuendigungen (Kurs und Stud.IP-weit, auch
// Learnweb), Nachrichten (nur lokal), Aenderungen in Kursen und - falls je eingeschaltet - Blubber, die neuesten fuenf.
// Je Zeile ein Symbol nach Art, Kurs bzw. Absender, ganzer Betreff, Zeit und erkannte Hinweise als Chips ("Frist 12.11.",
// "Ausfall? 12.11."). Aufklappen zeigt den ganzen Text (nie "…") mit Link nach Stud.IP bzw. Learnweb (nur http/https).
// "Alle anzeigen" oeffnet eine Liste mit Filter-Chips. Darunter eine Zeile "Schwarzes Brett: N neue Anzeigen", wenn es
// welche gibt. Daten: GET /api/news (app/studip_extras.py feed_for). Nachrichten werden in Stud.IP nie als gelesen
// markiert und gehen von hier nie an die KI oder einen Dienst.
import { $, $$, esc, icon, safeUrl, fmtShort, shortName, modal } from "./core.js?v=42";
import { newLine } from "./bulletin.js?v=4";

/// Art -> [Symbol, Ton, Bezeichnung]
export const KIND_STYLE = { nachricht: ["note", "info", "Nachricht"], aenderung: ["refresh", "ok", "Änderung"], blubber: ["users", "warn", "Blubber"] };
export const newsStyle = kind => KIND_STYLE[kind] || ["bell", "accent", "Ankündigung"];

/// Chip-Ton: Ausfall rot, Frist und Verlegung gelb, Pruefung Akzent
export const chipTone = kind => kind === "ausfall" ? "bad" : kind === "frist" || kind === "verlegt" ? "warn" : "";

/// Tage zwischen zwei "YYYY-MM-DD" ohne Kalender und Zeitzone
const dayNumber = s => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || ""); return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) / 86400000 : NaN; };

/// "09:15" heute, "gestern", sonst "Sa., 31.10."
export function newsTime(at, today) {
  if (!at || at.length < 10) return "";
  const day = at.slice(0, 10);
  if (day === today) return at.length >= 16 ? at.slice(11, 16) : "heute";
  if (dayNumber(today) - dayNumber(day) === 1) return "gestern";
  return fmtShort(day);
}

/// Text fuer Bedienungshilfen: "Nachricht: Tutorium entfällt · Lehrende · 08:15 · Ausfall? 12.11."
export const newsLabel = (item, today) => [`${newsStyle(item.kind)[2]}: ${item.title || ""}`, item.who || "", newsTime(item.at, today), ...(item.chips || []).map(c => c.label)].filter(Boolean).join(" · ");

export const FILTERS = [["", "Alle"], ["ankuendigung", "Ankündigungen"], ["nachricht", "Nachrichten"], ["aenderung", "Änderungen"], ["blubber", "Blubber"]];
export const filterNews = (items, key) => key ? (items || []).filter(i => i.kind === key) : (items || []);

/// Eine Zeile (aufklappbar): ganzer Betreff in der Zeile, ganzer Text und Link im aufgeklappten Teil
export function newsRow(item, today) {
  const [ic, tone] = newsStyle(item.kind);
  const chips = (item.chips || []).map(c => `<span class="badge ${chipTone(c.kind)}">${esc(c.label)}</span>`).join("");
  const url = safeUrl(item.url);
  return `<details class="ann-item news-item"><summary><span class="news-ic tone-${tone}" aria-hidden="true">${icon(ic, 14)}</span>
      <span class="news-main"><span class="news-top"><b class="news-who">${esc(shortName(item.who))}</b><span class="news-time">${esc(newsTime(item.at, today))}</span>${icon("chevron-down", 12)}</span>
      <span class="t news-title">${esc(item.title)}</span>${chips ? `<span class="news-chips">${chips}</span>` : ""}</span></summary>
    <div class="news-more">${item.text ? `<div class="body">${esc(item.text)}</div>` : ""}${url !== "#" ? `<a class="small" href="${esc(url)}" target="_blank" rel="noopener">${item.source === "learnweb" ? "Im Learnweb öffnen" : "In Stud.IP öffnen"}</a>` : ""}</div></details>`;
}

/// Karte fuer die Uebersicht; leer ohne Eintraege. `bulletinNew`: neue Anzeigen im Schwarzen Brett (0 = keine Zeile)
export function newsCard(items, today, bulletinNew = 0) {
  if (!items?.length) return "";
  const line = bulletinNew > 0 ? `<a class="news-bulletin" href="#/services" aria-label="${esc(newLine(bulletinNew))}" title="Schwarzes Brett unter Uni &amp; Noten öffnen">${icon("note", 14)}<span>${esc(newLine(bulletinNew))}</span>${icon("chevron-right", 12)}</a>` : "";
  return `<section class="card ov-card news-card"><div class="card-head"><h2>${icon("bell", 18)} Neuigkeiten</h2><button class="btn ghost sm" id="newsAll">Alle anzeigen</button></div>${items.slice(0, 5).map(i => newsRow(i, today)).join("")}${line}</section>`;
}

/// Inhalt der Liste "Alle Neuigkeiten" fuer einen Filter
export function listHtml(items, today, key) {
  const shown = filterNews(items, key);
  const chips = FILTERS.filter(([k]) => k !== "blubber" || items.some(i => i.kind === "blubber"))
    .map(([k, label]) => `<button class="chip ${key === k ? "on" : ""}" data-nf="${k}">${label}${k ? " " + filterNews(items, k).length : ""}</button>`).join("");
  return `<div class="row wrap" style="gap:.4rem;margin-bottom:.6rem">${chips}</div>
    ${shown.length ? shown.map(i => newsRow(i, today)).join("") : `<p class="muted small" style="text-align:center;padding:1.5rem 0">Nichts Neues.</p>`}
    ${(!key || key === "nachricht") && items.some(i => i.kind === "nachricht") ? `<p class="muted tiny" style="margin-top:.6rem">Nachrichten bleiben nur auf diesem Gerät; StudiNow markiert sie in Stud.IP nicht als gelesen.</p>` : ""}`;
}

/// "Alle anzeigen": Liste mit Filter-Chips in einem Fenster
export function openAll(items, today) {
  let key = "";
  const m = modal(`<h3>${icon("bell", 18)} Neuigkeiten</h3><div id="newsList"></div><div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`, { wide: true });
  const draw = () => { const box = $("#newsList", m); box.innerHTML = listHtml(items, today, key); $$("[data-nf]", box).forEach(b => b.onclick = () => { key = b.dataset.nf; draw(); }); };
  draw();
}

/// Bindet "Alle anzeigen" der Karte in `view`
export function bindNews(view, items, today) {
  $("#newsAll", view)?.addEventListener("click", () => openAll(items, today));
}

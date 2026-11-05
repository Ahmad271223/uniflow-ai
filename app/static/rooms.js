// Raumfinder in Web und Windows (05.11.2026, docs/RAUMFINDER-2026-11-05.md), wie RoomFinderViews.swift: Seite #/raumfinder
// mit Suche im Standortfinder der LUH (Raum, Gebaeude, Einrichtung), Treffern und Detail mit Raumplan, Barrierefreiheit
// und automatisch Links zu Google Maps ("In Google Maps öffnen", "Route" zu Fuss) und Apple Karten; Standorte von HsH und
// Uni Hildesheim mit Adresse ("Ort laut Hochschule; genaue Lage ohne Gewähr"). `openRoom(text)` loest eine Raumangabe aus
// Stundenplan, Lernkalender oder Klausuren auf (Klick auf .room-link, app.js). Frei in jedem Tarif.
// Daten: GET /api/rooms/search, /api/rooms/resolve, /api/rooms/campuses (app/rooms_api.py); Regeln: rooms-logic.js.
// An Google geht nichts von selbst: erst der Klick auf einen Karten-Link oeffnet Google Maps.
import { $, $$, api, esc, icon, modal } from "./core.js?v=46";
import * as L from "./rooms-logic.js?v=1";

function ensureCss() {
  if (document.getElementById("rooms-css")) return;
  const l = document.createElement("link"); l.id = "rooms-css"; l.rel = "stylesheet"; l.href = "rooms.css?v=1"; document.head.append(l);
}

const ext = (url, label, cls = "btn sm", ico = "") => url
  ? `<a class="${cls}" href="${esc(url)}" target="_blank" rel="noopener noreferrer nofollow">${ico ? icon(ico, 14) + " " : ""}${esc(label)}</a>` : "";

/** Karten-Links (nur Links: geoeffnet wird erst beim Klick) */
export const mapsButtons = maps => maps ? `<div class="rm-maps">
  ${ext(L.mapsUrl(maps, "google"), "In Google Maps öffnen", "btn primary sm", "map-pin")}
  ${ext(L.mapsUrl(maps, "route"), "Route", "btn sm", "arrow-right").replace("<a ", `<a aria-label="Route zu Fuß in Google Maps" `)}
  ${ext(L.mapsUrl(maps, "apple"), "In Apple Karten")}</div>` : "";

function placeHtml(p, attribution) {
  const rows = L.placeRows(p), bf = L.accessibilityRows(p), links = L.infoLinks(p);
  return `<div class="rm-place">
    <h3 class="rm-title">${icon(p.type === "room" ? "map-pin" : p.type === "facility" ? "book" : p.type === "campus" ? "graduation" : "home", 18)} ${esc(p.title)}</h3>
    ${p.subtitle ? `<p class="small muted">${esc(p.subtitle)}</p>` : ""}
    ${p.note ? `<div class="card flat rm-note" role="note">${icon("info", 15)} ${esc(p.note)}</div>` : ""}
    ${mapsButtons(p.maps)}
    ${rows.length ? `<dl class="rm-rows">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>` : ""}
    ${p.description ? `<p class="small">${esc(p.description)}</p>` : ""}
    ${links.length ? `<div class="rm-links">${links.map(l => ext(l.url, l.label, "btn ghost sm", l.label.startsWith("Raumplan") ? "layers" : "file-text")).join("")}</div>` : ""}
    ${p.source === "standortfinder" ? `<section class="rm-sec"><h4>Barrierefreiheit</h4>${bf.length ? bf.map(r => `<p><b>${esc(r.title)}</b>${r.text ? `<br><span class="muted">${esc(r.text)}</span>` : ""}</p>`).join("")
      : `<p class="muted small">Keine Angaben zur Barrierefreiheit im Standortfinder.</p>`}</section>` : ""}
    ${attribution ? `<p class="small muted">${esc(attribution)}. Angaben ohne Gewähr.</p>` : ""}
  </div>`;
}

function showPlace(p, attribution) {
  ensureCss();
  const md = modal(`<div class="card-head"><h3 id="rmH">Ort</h3><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>
    ${placeHtml(p, attribution)}<div class="modal-foot"><button class="btn primary" data-close>Fertig</button></div>`);
  md.setAttribute("aria-labelledby", "rmH");
  md.addEventListener("keydown", e => { if (e.key === "Escape") md.remove(); });
  $("[data-close]", md)?.focus();
}

/** Raumangabe aufloesen und zeigen (Stundenplan, Lernkalender, Klausuren) */
export async function openRoom(text) {
  ensureCss();
  const md = modal(`<div class="card-head"><h3 id="rmH">Raum</h3><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>
    <p class="small muted">Ort für „${esc(text)}“</p><div id="rmBody"><div class="skeleton" style="height:90px"></div></div>
    <div class="modal-foot"><button class="btn primary" data-close>Fertig</button></div>`);
  md.setAttribute("aria-labelledby", "rmH");
  md.addEventListener("keydown", e => { if (e.key === "Escape") md.remove(); });
  const body = $("#rmBody", md);
  let r;
  try { r = await api(L.resolvePath(text)); } catch (e) { body.innerHTML = `<p>${icon("alert", 15)} Der Ort konnte nicht geladen werden.</p>`; return; }
  const parts = r.parts || [];
  body.innerHTML = `${r.message ? `<div class="card flat rm-note" role="status">${icon("alert", 15)} ${esc(r.message)}</div>` : ""}
    ${parts.map((p, i) => `<div class="rm-part" data-part="${i}">${parts.length > 1 ? `<h4>${esc(p.text)}</h4>` : ""}
      ${p.place ? `${p.status !== "found" && L.statusText(p) ? `<p class="small">${esc(L.statusText(p))}</p>` : ""}${placeHtml(p.place)}`
        : `${L.statusText(p) ? `<p class="small">${esc(L.statusText(p))}</p>` : ""}
           ${(p.candidates || []).map((c, j) => `<button type="button" class="rm-result" data-cand="${j}">${icon("map-pin", 15)}<span><b>${esc(c.title)}</b><small>${esc(c.subtitle)}</small></span></button>`).join("")}
           ${p.status !== "online" ? `${(p.candidates || []).length ? `<p class="small muted">Oder nach dem Text suchen:</p>` : ""}${mapsButtons(p.maps)}` : ""}`}</div>`).join("")}
    ${r.source?.attribution ? `<p class="small muted">${esc(r.source.attribution)}. Angaben ohne Gewähr.</p>` : ""}`;
  $$("[data-part]", body).forEach(el => {
    const p = parts[+el.dataset.part];
    $$("[data-cand]", el).forEach(b => b.onclick = () => { el.innerHTML = placeHtml(p.candidates[+b.dataset.cand]); });
  });
}

export async function viewRooms(_, q, view) {
  ensureCss();
  let campuses = null;
  try { campuses = await api("/rooms/campuses"); } catch { campuses = null; }
  view.innerHTML = `<div class="content rm" style="max-width:1000px">
    <div class="page-head"><div><h1>Raumfinder</h1><div class="sub">Räume, Gebäude und Einrichtungen finden – mit Link zu Google Maps</div></div></div>
    <form class="rm-search" id="rmForm" role="search"><input class="input" id="rmQ" type="search" autocomplete="off" aria-label="Raum, Gebäude oder Einrichtung"
      placeholder="Raum, Gebäude oder Einrichtung (z. B. F102, 1101, Bibliothek)" value="${esc(q?.q || "")}">
      <button class="btn primary" type="submit">${icon("search", 15)} Suchen</button></form>
    <div class="rm-examples" id="rmEx">${["F102", "1101", "Hauptgebäude", "Bibliothek", "Audimax"].map(e => `<button type="button" class="chip" data-ex="${esc(e)}">${esc(e)}</button>`).join("")}</div>
    <div id="rmRes" aria-live="polite"></div>
    ${campuses ? `<section class="card rm-campuses"><div class="card-head"><h2>${icon("graduation", 18)} ${campuses.finder ? "Standorte der Leibniz Universität Hannover" : `Standorte: ${esc(campuses.name)}`}</h2></div>
      ${campuses.note ? `<p class="small">${esc(campuses.name)} hat keinen öffentlichen Raumfinder. ${esc(campuses.note)}.</p>` : ""}
      ${campuses.campuses.map(c => `<div class="rm-campus"><b>${esc(c.title)}</b><span class="small muted">${esc(c.address?.line || "")}</span>${mapsButtons(c.maps)}</div>`).join("")}</section>` : ""}
    <p class="small muted">Suche: Standortfinder der Leibniz Universität Hannover. Die Karten-Links öffnen Google Maps oder Apple Karten erst, wenn du sie anklickst.</p>
  </div>`;
  let result = null;
  const search = async (page = 0) => {
    const term = $("#rmQ", view).value.trim();
    if (!term) return;
    const box = $("#rmRes", view);
    if (!page) box.innerHTML = `<div class="skeleton" style="height:90px"></div>`;
    let r;
    try { r = await api(L.searchPath(term, page)); } catch { box.innerHTML = `<div class="card">${icon("alert", 15)} Die Suche ist gerade nicht möglich. Versuche es später erneut.</div>`; return; }
    result = page && result ? { ...r, items: [...result.items, ...r.items] } : r;
    $("#rmEx", view).hidden = true;
    box.innerHTML = `${result.message ? `<div class="card flat rm-note" role="status">${icon("alert", 15)} ${esc(result.message)}</div>` : ""}
      <p class="rm-count"><b>${esc(L.countText(result))}</b></p>
      ${result.items.map((p, i) => `<button type="button" class="rm-result" data-i="${i}">${icon(p.type === "room" ? "map-pin" : p.type === "facility" ? "book" : "home", 16)}<span><b>${esc(p.title)}</b><small>${esc(p.subtitle)}</small></span>${icon("chevron-right", 14)}</button>`).join("")}
      ${result.pages > result.page + 1 ? `<button class="btn" id="rmMore">${icon("chevron-down", 14)} Weitere Treffer laden</button>` : ""}`;
    $$("[data-i]", box).forEach(b => b.onclick = () => showPlace(result.items[+b.dataset.i], result.source?.attribution));
    $("#rmMore", box)?.addEventListener("click", () => search(result.page + 1));
  };
  $("#rmForm", view).onsubmit = e => { e.preventDefault(); search(); };
  $$("[data-ex]", view).forEach(b => b.onclick = () => { $("#rmQ", view).value = b.dataset.ex; search(); });
  if (q?.q) search();
}

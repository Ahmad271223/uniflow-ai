// Mensa in Web und Windows (05.11.2026, docs/MENSA-2026-11-05.md), wie MensaPage.swift: Seite #/mensa mit Mensa-Auswahl
// (Standard der Hochschule, gemerkt, Favoriten), Heute/Morgen/Woche, Gerichte als Karten mit dem Preis der eigenen Gruppe,
// Filter (vegan, vegetarisch, ohne Schwein, Allergene meiden), Oeffnungszeiten und Quelle; Karte "Heute in der Mensa" auf
// der Uebersicht (drei Hauptgerichte, am Wochenende und an geschlossenen Tagen ausgeblendet). Frei in jedem Tarif.
// Daten: GET /api/mensa/canteens, GET /api/mensa/menu (app/mensa_api.py); Regeln: mensa-logic.js.
import { $, $$, api, esc, icon, modal, todayISO } from "./core.js?v=45";
import * as L from "./mensa-logic.js?v=2";

let listCache = null;

function ensureCss() {
  if (document.getElementById("mensa-css")) return;
  const l = document.createElement("link"); l.id = "mensa-css"; l.rel = "stylesheet"; l.href = "mensa.css?v=2"; document.head.append(l);
}

async function canteens() {
  if (!listCache) listCache = await api("/mensa/canteens");
  return listCache;
}

const prefs = () => L.readPrefs(globalThis.localStorage);
const save = p => L.writePrefs(globalThis.localStorage, p);

function labelBadges(m) {
  const show = (m.labels || []).filter(k => k !== "fleisch" || !(m.labels || []).some(x => ["gefluegel", "schwein", "rind"].includes(x)))
    .filter(k => k !== "vegetarisch" || !(m.labels || []).includes("vegan"));
  return show.map(k => `<span class="mn-tag mn-${k}">${esc(L.LABEL_NAMES[k] || k)}</span>`).join("");
}

// Karte je Gericht: immer sichtbar, was es gibt; Antippen/Enter oeffnet alle Angaben (Preise, Bestandteile, Naehrwerte,
// Kennzeichnungen, Allergene, Zusatzstoffe), wie die Seite der Mensa sie zeigt
function mealCard(m, role) {
  const price = L.formatPrice(L.priceFor(m, role));
  const short = L.nutritionShort(m);
  return `<button type="button" class="mn-meal${m.main ? "" : " side"}" data-meal="${esc(m.id)}" aria-haspopup="dialog" aria-label="${esc(`${m.name}, ${price}${short ? `, ${short}` : ""}. Alle Angaben zeigen`)}">
    <span class="mn-meal-top"><span class="mn-cat">${esc(m.category || "")}${m.time === "abend" ? " · abends" : m.time === "frueh" ? " · Frühstück" : ""}</span><span class="mn-price">${esc(price)}</span></span>
    <span class="mn-name">${esc(m.name)}</span>
    ${(m.labels || []).length ? `<span class="mn-tags">${labelBadges(m)}</span>` : ""}
    ${short ? `<span class="mn-nutri">${esc(short)}</span>` : ""}
    <span class="mn-open">Alle Angaben ${icon("chevron-right", 13)}</span>
  </button>`;
}

const section = (title, body) => `<section class="mn-sec"><h3>${esc(title)}</h3>${body}</section>`;

function mealDetail(m, menu) {
  const roles = Object.entries(L.ROLE_NAMES).map(([k, t]) => `<div class="mn-row"><span>${t}</span><b>${esc(L.formatPrice(L.priceFor(m, k)))}</b></div>`).join("");
  const rows = L.nutritionRows(m);
  const nutri = rows.length ? `<p class="small muted">${esc(L.basisLabel(m.nutrition))} (Angabe des Studentenwerks)</p>${rows.map(r => `<div class="mn-row${r.sub ? " sub" : ""}"><span>${esc(r.label)}</span><b>${esc(r.value)}</b></div>`).join("")}`
    : `<p class="muted">${esc(L.NO_NUTRITION)}</p>`;
  const labels = (m.labels || []).filter(k => k !== "vegetarisch" || !(m.labels || []).includes("vegan")).map(k => L.LABEL_NAMES[k] || k);
  const marks = [...labels, ...L.climateRows(m), ...(m.notes || [])];
  const list = xs => `<ul class="mn-list">${xs.map(x => `<li>${esc(x)}</li>`).join("")}</ul>`;
  const md = modal(`<div class="card-head"><h3 id="mnDetailH">${esc(m.name)}</h3><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>
    <p class="small muted" style="margin:-.4rem 0 .6rem">${esc([m.category, m.time === "abend" ? "abends" : "", menu?.canteen?.name].filter(Boolean).join(" · "))}</p>
    <div class="mn-detail">
      ${section("Preise", roles)}
      ${(m.components || []).length ? section("Bestandteile und Beilagen", list(m.components)) : ""}
      ${section("Nährwerte", nutri)}
      ${section("Kennzeichnungen", marks.length ? list(marks) : `<p class="muted">Keine Kennzeichnungen angegeben.</p>`)}
      ${section("Allergene", (m.allergens || []).length ? list(m.allergens.map(a => a.name)) : `<p class="muted">Keine Allergene angegeben.</p>`)}
      ${section("Zusatzstoffe", (m.additives || []).length ? list(m.additives.map(a => a.name)) : `<p class="muted">Keine Zusatzstoffe angegeben.</p>`)}
    </div>
    <p class="small muted">${esc(menu?.source?.attribution || "")}. Angaben ohne Gewähr; verbindlich ist der Aushang vor Ort.</p>
    <div class="modal-foot"><button class="btn primary" data-close>Fertig</button></div>`);
  md.setAttribute("aria-labelledby", "mnDetailH");
  $("[data-close]", md)?.focus();
  md.addEventListener("keydown", e => { if (e.key === "Escape") md.remove(); });
}

function dayBlock(day, p, today, heading) {
  if (day.status !== "open") return `${heading ? `<h2 class="mn-day">${esc(heading)}</h2>` : ""}<div class="card flat mn-empty">${icon("clock", 16)} ${esc(L.STATUS_TEXT[day.status] || L.STATUS_TEXT.none)}</div>`;
  const shown = L.sortMeals(L.filterMeals(day.meals, p.filter), p.sort, p.role);
  const hidden = day.meals.length - shown.length;
  const main = shown.filter(m => m.main), side = shown.filter(m => !m.main);
  return `${heading ? `<h2 class="mn-day">${esc(heading)}</h2>` : ""}
    ${shown.length ? `<div class="mn-grid">${main.map(m => mealCard(m, p.role)).join("")}</div>
      ${side.length ? `<h3 class="mn-sub">Beilagen, Salate und Desserts</h3><div class="mn-grid compact">${side.map(m => mealCard(m, p.role)).join("")}</div>` : ""}`
      : `<div class="card flat mn-empty">${icon("filter", 16)} Kein Gericht passt zum Filter.</div>`}
    ${hidden > 0 && shown.length ? `<p class="small muted">${hidden === 1 ? "1 Gericht" : `${hidden} Gerichte`} durch den Filter ausgeblendet.</p>` : ""}`;
}

function controls(list, p, cid, mode, sorts) {
  const groups = L.canteenGroups(list, p.favorites);
  const fav = p.favorites.includes(cid);
  const names = Object.fromEntries((list.allergens || []).map(a => [a.key, a.name]));
  return `<div class="mn-controls">
    <label class="mn-field"><span>Mensa</span><select id="mnCanteen">${groups.map(g => `<optgroup label="${esc(g.title)}">${g.items.map(c => `<option value="${esc(c.id)}"${c.id === cid ? " selected" : ""}>${esc(c.name)}</option>`).join("")}</optgroup>`).join("")}</select></label>
    <button class="btn ghost icon mn-fav${fav ? " on" : ""}" id="mnFav" aria-pressed="${fav}" aria-label="${fav ? "Aus den Favoriten entfernen" : "Zu den Favoriten"}" title="${fav ? "Favorit" : "Als Favorit merken"}">${icon("star", 18)}</button>
    <div class="seg" role="group" aria-label="Zeitraum">${[["today", "Heute"], ["tomorrow", "Morgen"], ["week", "Woche"]].map(([k, t]) => `<button data-mode="${k}" class="${mode === k ? "active" : ""}" aria-pressed="${mode === k}">${t}</button>`).join("")}</div>
    <label class="mn-field"><span>Preis für</span><select id="mnRole">${Object.entries(L.ROLE_NAMES).map(([k, t]) => `<option value="${k}"${p.role === k ? " selected" : ""}>${t}</option>`).join("")}</select></label>
    <label class="mn-field"><span>Sortieren nach</span><select id="mnSort">${sorts.map(([k, t]) => `<option value="${k}"${p.sort === k ? " selected" : ""}>${t}${k === "price" ? " (günstig zuerst)" : k === "kcal" ? " (wenig zuerst)" : k === "protein" ? " (viel zuerst)" : ""}</option>`).join("")}</select></label>
  </div>
  <div class="mn-filters" role="group" aria-label="Filter">
    ${[["vegan", "vegan"], ["vegetarisch", "vegetarisch"], ["ohne_schwein", "ohne Schwein"]].map(([k, t]) => `<button class="chip${p.filter[k] ? " on" : ""}" data-f="${k}" aria-pressed="${!!p.filter[k]}">${t}</button>`).join("")}
    <details class="mn-allergens"><summary class="chip${p.filter.allergens.length ? " on" : ""}">Allergene meiden${p.filter.allergens.length ? ` (${p.filter.allergens.length})` : ""}</summary>
      <div class="mn-allergen-list">${(list.allergens || []).map(a => `<label><input type="checkbox" data-a="${esc(a.key)}"${p.filter.allergens.includes(a.key) ? " checked" : ""}> ${esc(a.name)}</label>`).join("")}</div></details>
    ${L.isFilterEmpty(p.filter) ? "" : `<span class="small muted" aria-live="polite">Filter: ${esc(L.filterSummary(p.filter, names))}</span>`}
  </div>`;
}

function infoCard(menu) {
  const c = menu.canteen || {};
  const at = menu.fetched_at ? String(menu.fetched_at).slice(11, 16) : "";
  return `<aside class="card mn-info"><h2>${icon("clock", 16)} Öffnungszeiten</h2>
    ${(c.hours || []).map(h => `<div class="mn-hours"><div class="small muted">${esc(h.label)}</div>${h.lines.map(l => `<div>${esc(l)}</div>`).join("")}</div>`).join("")}
    <p class="small muted">${esc(c.address || "")}</p>
    <p class="small muted">${esc(menu.source?.attribution || "")}${at ? ` · Stand ${esc(at)} Uhr` : ""}. Angaben ohne Gewähr; verbindlich ist der Aushang vor Ort.</p>
    <a class="small" href="${esc(c.url || menu.source?.url || "#")}" target="_blank" rel="noopener">Seite der Mensa öffnen</a></aside>`;
}

export async function viewMensa(_, q, view) {
  ensureCss();
  const list = await canteens();
  let p = prefs();
  const today = todayISO();
  let mode = ["today", "tomorrow", "week"].includes(q?.tag) ? q.tag : "today";
  const render = async () => {
    const cid = q?.canteen && list.canteens.some(c => c.id === q.canteen) ? q.canteen : L.chosenCanteen(p, list);
    const start = mode === "tomorrow" ? L.addDays(today, 1) : today;
    const days = mode === "week" ? 7 : 1;
    let menu = null, err = null;
    try { menu = await api(`/mensa/menu?canteen=${encodeURIComponent(cid)}&date=${start}&days=${days}`); } catch (e) { err = e.message; }
    const name = list.canteens.find(c => c.id === cid)?.name || "Mensa";
    view.innerHTML = `<div class="content mn" style="max-width:1120px">
      <div class="page-head"><div><h1>Mensa</h1><div class="sub">${esc(name)}${mode === "week" ? " · diese Woche" : ` · ${esc(L.dayLong(start))}`}</div></div></div>
      ${controls(list, p, cid, mode, L.availableSorts((menu?.days || []).flatMap(d => d.meals || [])))}
      ${menu?.message ? `<div class="card flat mn-note" role="status">${icon("alert", 16)} ${esc(menu.message)}</div>` : ""}
      <div class="mn-layout"><div class="mn-main">
        ${err ? `<div class="card">${icon("alert", 16)} ${esc(err)} <button class="btn sm" id="mnRetry">${icon("refresh", 14)} Erneut versuchen</button></div>`
          : mode === "week" ? menu.days.map(d => dayBlock(d, p, today, `${L.dayLabel(d.date, today)} · ${L.dayLong(d.date)}`)).join("")
          : dayBlock(menu.days[0], p, today, "")}
      </div>${menu ? infoCard(menu) : ""}</div></div>`;
    $("#mnRetry", view)?.addEventListener("click", render);
    $("#mnCanteen", view).onchange = e => { p = { ...p, canteen: e.target.value }; save(p); if (q) delete q.canteen; render(); };
    $("#mnFav", view).onclick = () => { p = L.toggleFavorite(p, cid); save(p); render(); };
    $("#mnRole", view).onchange = e => { p = { ...p, role: e.target.value }; save(p); render(); };
    $("#mnSort", view).onchange = e => { p = { ...p, sort: e.target.value }; save(p); render(); };
    const byId = new Map((menu?.days || []).flatMap(d => d.meals || []).map(m => [m.id, m]));
    $$("[data-meal]", view).forEach(b => b.onclick = () => { const m = byId.get(b.dataset.meal); if (m) mealDetail(m, menu); });
    $$("[data-mode]", view).forEach(b => b.onclick = () => { mode = b.dataset.mode; render(); });
    $$("[data-f]", view).forEach(b => b.onclick = () => {
      const k = b.dataset.f, f = { ...p.filter, [k]: !p.filter[k] };
      if (k === "vegan" && f.vegan) f.vegetarisch = false;
      if (k === "vegetarisch" && f.vegetarisch) f.vegan = false;
      p = { ...p, filter: f }; save(p); render();
    });
    const det = $(".mn-allergens", view);
    det?.addEventListener("keydown", e => { if (e.key === "Escape" && det.open) { det.open = false; $("summary", det).focus(); } });
    $$("[data-a]", view).forEach(cb => cb.onchange = () => {
      const s = new Set(p.filter.allergens); cb.checked ? s.add(cb.dataset.a) : s.delete(cb.dataset.a);
      const key = cb.dataset.a;
      p = { ...p, filter: { ...p.filter, allergens: [...s] } }; save(p);
      // Liste bleibt offen, Fokus bleibt auf dem Kaestchen (Tastatur, VoiceOver)
      render().then(() => { const d = $(".mn-allergens", view); if (d) { d.open = true; $$("[data-a]", d).find(x => x.dataset.a === key)?.focus(); } });
    });
  };
  // Klick ausserhalb schliesst die Allergenliste
  view.addEventListener("click", e => { const d = $(".mn-allergens[open]", view); if (d && !d.contains(e.target)) d.open = false; });
  await render();
}

/** Karte "Heute in der Mensa" auf der Uebersicht; leer, wenn heute nichts (Wochenende, geschlossen, kein Plan, kein Netz ohne Stand) */
export async function renderDashboard(host) {
  if (!host) return;
  ensureCss();
  const today = todayISO();
  if (L.isWeekend(today)) { host.innerHTML = ""; return; }
  const list = await canteens();
  const p = prefs();
  const cid = L.chosenCanteen(p, list);
  const menu = await api(`/mensa/menu?canteen=${encodeURIComponent(cid)}&date=${today}&days=1`);
  const card = L.dashboardCard(menu, today, p.filter, p.role);
  if (!card) { host.innerHTML = ""; return; }
  host.innerHTML = `<section class="card ov-card mn-dash" aria-labelledby="mnDashH"><div class="card-head"><h2 id="mnDashH">${icon("utensils", 18)} Heute in der Mensa</h2><a class="small" href="#/mensa">Alle Gerichte</a></div>
    <div class="small muted" style="margin-bottom:.4rem">${esc(card.canteen)}${card.stale ? " · letzter Stand" : ""}</div>
    <ul class="mn-dash-list">${card.meals.map(m => `<li><span class="mn-dash-name">${esc(m.name)}</span><span class="mn-dash-meta">${m.labels.includes("vegan") ? `<span class="mn-tag mn-vegan">vegan</span>` : m.labels.includes("vegetarisch") ? `<span class="mn-tag mn-vegetarisch">vegetarisch</span>` : ""}<b>${esc(m.price)}</b></span></li>`).join("")}</ul></section>`;
}

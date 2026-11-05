// Karte "Zuletzt benutzt" auf der Uebersicht und "Weitermachen wie zuvor" beim Start (Web und Windows, 05.11.2026).
// Regeln: recent-logic.js. Der Stand fuer Weitermachen liegt je Konto im Speicher dieses Browsers bzw. des
// Windows-Fensters (wie auf dem iPad je Geraet); die Liste kommt vom Server (GET /api/recent, app/recent.py).
import { DASHBOARD_LIMIT, KIND_ICON, itemHref, subtitle, resumeEntry, resumeTarget, resumeKey } from "./recent-logic.js?v=1";

/** Karte fuer die Uebersicht; ohne Eintraege nichts */
export function recentCard(items, { icon, esc }) {
  const list = (items || []).slice(0, DASHBOARD_LIMIT);
  if (!list.length) return "";
  return `<section class="card ov-card" aria-label="Zuletzt benutzt"><div class="card-head"><h2>${icon("clock", 18)} Zuletzt benutzt</h2></div><div class="list">${list.map(it =>
    `<a class="item" href="${esc(itemHref(it))}">${icon(KIND_ICON[it.kind] || "file", 16)}<div class="main"><div class="title">${esc(it.title || "Ohne Titel")}</div><div class="sub">${esc(subtitle(it))}</div></div></a>`).join("")}</div></section>`;
}

const store = {
  get(k) { try { return JSON.parse(localStorage.getItem(k) || "null"); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

/** aktueller Stand im Dokument: Seite aus der Seitenzahl des Editors, KI-Hilfe offen oder nicht */
function docState() {
  const pane = document.getElementById("paneA");
  const page = Number(pane?.querySelector(".ed-pageno")?.value) || undefined;
  const ai = pane?.querySelector(".ed-ai") ? !pane.querySelector(".ed-ai").hidden : undefined;
  return { page, ai };
}

/** Mitschreiben und beim Start wiederherstellen. `api` aus core.js; `account` trennt die Staende je Konto. */
export function startResume({ api, account, skip = false }) {
  const key = resumeKey(account);
  const saved = store.get(key);
  const record = () => {
    const e = resumeEntry(location.hash, location.hash.startsWith("#/doc/") ? docState() : {});
    store.set(key, { ...e, at: new Date().toISOString() });
  };
  // zuerst entscheiden, dann mitschreiben (sonst ueberschreibt die Uebersicht den alten Stand)
  const startHash = location.hash;
  const target = skip ? null : resumeTarget(saved, startHash);
  if (target) {
    api(`/files/${encodeURIComponent(saved.file)}`).then(() => {
      if (location.hash === startHash || (!location.hash && !startHash)) location.hash = target;   // in der Zwischenzeit nichts anderes geoeffnet
    }).catch(() => store.set(key, { route: "dashboard" }));
  } else record();
  window.addEventListener("hashchange", record);
  document.addEventListener("visibilitychange", () => { if (document.hidden) record(); });
  window.addEventListener("pagehide", record);
  document.addEventListener("click", () => { if (location.hash.startsWith("#/doc/")) setTimeout(record, 0); }, true);
  setInterval(() => { if (!document.hidden && location.hash.startsWith("#/doc/")) record(); }, 15000);
}

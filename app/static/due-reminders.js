// Erinnerungen an erkannte Fristen in Web und Windows-App (05.11.2026; iPad: DueReminderScheduler.swift).
// Holt beim Start und danach alle 30 Minuten GET /api/due, plant die Erinnerungen (due-reminders-logic.js) und zeigt
// die faelligen, solange StudiNow offen ist:
//  - Windows-App: als Windows-Mitteilung ueber das Tauri-Plugin "notification" (apps/windows/src-tauri,
//    capabilities/notifications.json; nur fuer die Seite des lokalen Backends),
//  - Browser: mit der Notification-API; die Erlaubnis wird erst beim Einschalten erfragt (Klick),
//  - sonst (blockiert, nicht unterstuetzt): als Hinweis in der App.
// Eingeschaltet wird mit dem Knopf "Erinnerungen an Fristen" in der Karte "Nächste Termine" der Übersicht (Stand je
// Browser in localStorage). Einmal am Tag zeigt die App ausserdem kurz, was heute und morgen faellig ist.
import * as L from "./due-reminders-logic.js?v=1";

const KEY = "due-reminders";            // "on" | "off"
const FIRED = "due-reminders-fired";    // schon gezeigte Kennungen (je Browser), damit ein Neuladen nichts doppelt zeigt
const SUMMARY = "due-reminders-summary"; // Tag des letzten Hinweises "heute und morgen"
const HORIZON = 26 * 3600 * 1000;       // Zeitgeber nur fuer die naechsten 26 Stunden; danach plant der naechste Abruf
let ctx = null, timers = [], items = [], refreshT = 0;

const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
const enabled = () => store.get(KEY) === "on";
function fired() { try { return new Set(JSON.parse(store.get(FIRED) || "[]")); } catch { return new Set(); } }
function markFired(id) { const s = [...fired(), id].slice(-300); store.set(FIRED, JSON.stringify(s)); }
const container = () => String(ctx?.state?.account?.id ?? ctx?.state?.appAccount?.user?.id ?? "local");

// ---------------------------------------------------------------- Wege der Mitteilung
async function tauriInvoke(cmd, args) { return window.__TAURI_INTERNALS__.invoke(`plugin:notification|${cmd}`, args); }
async function tauriPermission(ask) {
  const n = window.__TAURI__?.notification;
  try {
    if (n?.isPermissionGranted) { if (await n.isPermissionGranted()) return true; return ask ? (await n.requestPermission()) === "granted" : false; }
    if (await tauriInvoke("is_permission_granted")) return true;
    return ask ? (await tauriInvoke("request_permission")) === "granted" : false;
  } catch { return false; }
}
async function permission(ask) {
  const ch = L.channel(window);
  if (ch === "tauri") return tauriPermission(ask);
  if (ch === "browser") {
    if (Notification.permission === "granted") return true;
    if (!ask) return false;
    try { return (await Notification.requestPermission()) === "granted"; } catch { return false; }
  }
  return false;
}
function open(route) {
  if (!route) return;
  if (/^https?:/i.test(route)) window.open(route, "_blank", "noopener"); else location.hash = route;
}
async function show(r) {
  const ch = L.channel(window);
  try {
    if (ch === "tauri" && await tauriPermission(false)) {
      const n = window.__TAURI__?.notification;
      if (n?.sendNotification) n.sendNotification({ title: r.title, body: r.body });
      else await tauriInvoke("notify", { options: { title: r.title, body: r.body } });
      return;
    }
    if (ch === "browser" && Notification.permission === "granted") {
      const n = new Notification(r.title, { body: r.body, tag: r.identifier });
      n.onclick = () => { window.focus(); open(r.route); n.close(); };
      return;
    }
  } catch { /* faellt auf den Hinweis in der App zurueck */ }
  banner(r.title, r.body, r.route);
}

// ---------------------------------------------------------------- Hinweis in der App
function banner(title, body, route) {
  const { esc, icon } = ctx;
  document.getElementById("dueBanner")?.remove();
  const b = document.createElement("div");
  b.id = "dueBanner"; b.className = "due-banner"; b.setAttribute("role", "status");
  b.innerHTML = `${icon("bell", 18)}<div class="due-banner-t"><b>${esc(title)}</b>${body ? `<span>${esc(body)}</span>` : ""}</div>
    ${route ? `<button class="btn sm" data-due-open>Öffnen</button>` : ""}<button class="btn ghost icon sm" data-due-close title="Schließen">${icon("x", 14)}</button>`;
  b.querySelector("[data-due-open]")?.addEventListener("click", () => { b.remove(); open(route); });
  b.querySelector("[data-due-close]").onclick = () => b.remove();
  document.body.append(b);
}
function ensureCss() {
  if (document.getElementById("dueCss")) return;
  const s = document.createElement("style"); s.id = "dueCss";
  s.textContent = `.due-banner{position:fixed;right:16px;bottom:16px;z-index:60;display:flex;gap:.6rem;align-items:center;max-width:min(440px,calc(100vw - 32px));
    background:var(--surface,#fff);color:var(--text,#171a26);border:1px solid var(--border,#e5e8f0);border-radius:14px;padding:.7rem .8rem;box-shadow:0 8px 28px rgba(20,24,40,.16)}
    .due-banner-t{display:flex;flex-direction:column;gap:.1rem;min-width:0;flex:1}.due-banner-t span{font-size:.85rem;color:var(--text-2,#4a5068)}
    @media (max-width:600px){.due-banner{left:16px;right:16px;bottom:76px}}`;
  document.head.append(s);
}

// ---------------------------------------------------------------- Planen
function schedule() {
  timers.forEach(clearTimeout); timers = [];
  if (!enabled()) return;
  const now = Date.now(), done = fired();
  for (const r of L.dueWithin(L.plan(items, container(), now), now, HORIZON)) {
    if (done.has(r.identifier)) continue;
    timers.push(setTimeout(() => { if (!fired().has(r.identifier)) { markFired(r.identifier); show(r); } }, r.fireAt - now));
  }
}
function daySummary() {
  const s = L.todaySummary(items, Date.now());
  if (!s || store.get(SUMMARY) === s.day) return;
  store.set(SUMMARY, s.day);
  banner(s.count === 1 ? "Bald fällig" : `${s.count} Termine bald fällig`, s.lines.join(" · ") + (s.more ? ` · und ${s.more} weitere` : ""), s.route);
}
async function refresh() {
  if (document.hidden && items.length) return;
  try { items = L.itemsFrom(await ctx.api("/due")); } catch { return; }
  schedule();
  if (enabled()) daySummary();
}

// ---------------------------------------------------------------- Knopf in "Nächste Termine"
function toggleHtml() {
  const { icon } = ctx; const on = enabled();
  return `<button class="btn ghost sm due-toggle" data-due-toggle aria-pressed="${on}" aria-label="Erinnerungen an Fristen ${on ? "an" : "aus"}" title="${on ? "Erinnerungen an Abgaben, Tests und Prüfungen ausschalten" : "3 Tage, 1 Tag und am Morgen vor erkannten Fristen erinnern"}">${icon("bell", 14)} ${on ? "Erinnert" : "Erinnern"}</button>`;
}
async function toggle(btn) {
  if (enabled()) { store.set(KEY, "off"); schedule(); ctx.toast("Erinnerungen an Fristen sind aus"); }
  else {
    store.set(KEY, "on");
    const ok = await permission(true);
    ctx.toast(ok ? "Erinnerungen an Fristen sind an" : "Mitteilungen sind nicht erlaubt – StudiNow erinnert dich hier in der App, solange sie offen ist.", 5000);
    await refresh();
  }
  btn.outerHTML = toggleHtml();
}
function mountToggle(root) {
  const card = [...root.querySelectorAll(".card-head h2")].find(h => /Nächste Termine/.test(h.textContent))?.closest(".card-head");
  if (!card || card.querySelector("[data-due-toggle]")) return;
  card.insertAdjacentHTML("beforeend", toggleHtml());
}

/** Einmal beim Start (app.js): ctx = { api, toast, icon, esc, state } */
export function init(c) {
  if (ctx) return; ctx = c; ensureCss();
  document.addEventListener("click", e => { const b = e.target.closest?.("[data-due-toggle]"); if (b) { e.preventDefault(); toggle(b); } });
  const view = document.getElementById("view");
  if (view) { mountToggle(view); new MutationObserver(() => mountToggle(view)).observe(view, { childList: true, subtree: true }); }
  setTimeout(refresh, 5000);
  refreshT = setInterval(refresh, 30 * 60 * 1000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
}
export const _internals = { toggleHtml, schedule, get items() { return items; } };

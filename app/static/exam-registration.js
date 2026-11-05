// Pruefungsanmeldung im Web/Windows (05.11.2026, docs/PRUEFUNGSANMELDUNG-2026-11-05.md), nach ExamRegistrationViews.swift:
// Karte auf der Uebersicht (im Meldezeitraum und 7 Tage davor), Abschnitt im Studienverlauf, Block "Prüfung anmelden" am
// Modul (Studienverlauf und Modulseite), Abzeichen angemeldet/nicht angemeldet in "Nächste Klausuren". Erinnerungen an
// denselben Tagen wie auf dem iPad (erster Tag, 7 und 2 Tage vor dem Ende): als Hinweis in der App und, wenn in der
// Windows-App die Erinnerungen eingeschaltet und erlaubt sind (due-reminders.js), einmal als Windows-Mitteilung. StudiNow meldet nie selbst an; "Im QIS anmelden" oeffnet nur QIS.
// Regeln und Texte: exam-registration-logic.js; Daten: GET /api/exam-registration (app/exam_registration_api.py).
import { $, $$, api, icon, toast, todayISO } from "./core.js?v=44";
import * as L from "./exam-registration-logic.js?v=1";

const DISMISS_KEY = "xr-dismissed";
let cache = null;

function ensureCss() {
  if (document.getElementById("studip-tools-css")) return;
  const l = document.createElement("link"); l.id = "studip-tools-css"; l.rel = "stylesheet"; l.href = "studip-tools.css?v=1"; document.head.append(l);
}

/** Antwort (kurz zwischengespeichert, damit Uebersicht und Karte nicht doppelt rechnen) */
export async function load(force = false) {
  if (!force && cache && Date.now() - cache.at < 30000) return cache.data;
  const data = await api("/exam-registration");
  cache = { at: Date.now(), data };
  return data;
}

function dismissed() {
  try { return new Set(JSON.parse(localStorage.getItem(DISMISS_KEY) || "[]")); } catch { return new Set(); }
}
function dismiss(id) {
  try { const s = [...dismissed(), id].slice(-40); localStorage.setItem(DISMISS_KEY, JSON.stringify(s)); } catch {}
}

/** "Angemeldete Prüfungen abrufen": der normale QIS-Abruf liest die Info-Seite mit (nur lesend) */
async function fetchRegistrations(btn, rerender) {
  const before = cache?.data?.registrations_checked_at || null;
  btn.disabled = true;
  try { await api("/grades/sync", { method: "POST" }); toast("QIS-Abruf gestartet – Noten und angemeldete Prüfungen", 4000); window.pollBg?.(); }
  catch (e) { toast(e.message, 5000); btn.disabled = false; return; }
  for (let i = 0; i < 40; i++) {
    await new Promise(r => setTimeout(r, 5000));
    const d = await load(true).catch(() => null);
    if (d && d.registrations_checked_at !== before) { toast(d.registrations_message || "Abgerufen", 4000); rerender(d); return; }
  }
  btn.disabled = false;
}

function bind(host, rerender) {
  $$("[data-xr-fetch]", host).forEach(b => b.onclick = () => fetchRegistrations(b, rerender));
  $$("[data-xr-dismiss]", host).forEach(b => b.onclick = () => { const el = b.closest("[data-xr-banner]"); dismiss(el.dataset.xrBanner); el.remove(); });
}

/** Windows-Mitteilung (Tauri-Plugin "notification", wie due-reminders.js), nur wenn dort "Erinnerungen" eingeschaltet
    und erlaubt sind; je Erinnerung einmal. Sonst bleibt es beim Hinweis in der App. */
async function notifyOnce(rem) {
  const inv = window.__TAURI_INTERNALS__?.invoke;
  if (!rem || !inv) return;
  let done = [];
  try { if (localStorage.getItem("due-reminders") !== "on") return; done = JSON.parse(localStorage.getItem("xr-notified") || "[]"); } catch { return; }
  if (done.includes(rem.id)) return;
  try {
    if (!(await inv("plugin:notification|is_permission_granted"))) return;
    await inv("plugin:notification|notify", { options: { title: rem.title, body: rem.body } });
    localStorage.setItem("xr-notified", JSON.stringify([...done, rem.id].slice(-40)));
  } catch { /* Hinweis in der App genuegt */ }
}

function bannerFor(r) {
  const rem = L.dueReminder(r, todayISO(), dismissed());
  notifyOnce(rem);
  return L.bannerHtml(rem, icon);
}

/** Uebersicht: Hinweis (Erinnerung), Karte und Abzeichen in "Nächste Klausuren" */
export async function renderDashboard(host, examsCard) {
  if (!host) return;
  let r;
  try { r = await load(); } catch { return; }
  if (!r?.supported) return;
  ensureCss();
  const draw = d => {
    host.innerHTML = bannerFor(d) + (L.showCard(d) ? L.cardHtml(d, { icon, limit: 4 }) : "");
    bind(host, draw);
  };
  draw(r);
  // Abzeichen an den Klausuren
  $$(".ov-exam", examsCard || document.createElement("div")).forEach(a => {
    const href = a.getAttribute("href") || "", mid = /#\/modules\/(\d+)/.exec(href);
    const title = $(".title", a)?.textContent || "";
    const st = L.examStatus(r, { module_id: mid ? +mid[1] : null, title });
    if (!st || $(".xr-exam-badge", a)) return;
    const b = document.createElement("span");
    b.className = `badge xr-exam-badge ${st === L.TEXTS.registered ? "ok" : "warn"}`; b.textContent = st;
    $(".main", a)?.append(b);
  });
}

/** Studienverlauf: Abschnitt (immer, wenn die Hochschule unterstuetzt ist) mit Hinweis */
export async function renderSection(host) {
  if (!host) return;
  let r;
  try { r = await load(); } catch { return; }
  if (!r?.supported) return;
  ensureCss();
  const draw = d => { host.innerHTML = bannerFor(d) + L.cardHtml(d, { icon, section: true }); bind(host, draw); };
  draw(r);
}

/** Block "Prüfung anmelden" am Modul: in `box` angehaengt (Moduldetail) bzw. vor `before` eingefuegt (Modulseite) */
export async function renderModuleBlock(box, { catalogId, appModuleId, before = false } = {}) {
  if (!box) return;
  let r;
  try { r = await load(); } catch { return; }
  const s = L.suggestionFor(r, { catalogId, appModuleId });
  if (!s) return;
  ensureCss();
  const el = document.createElement("div");
  el.innerHTML = L.moduleBlockHtml(r, s, icon);
  if (before) box.before(el); else box.append(el);
  bind(el, () => {});
}

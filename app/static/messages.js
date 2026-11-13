// Seite "Nachrichten" in der Seitenleiste (Windows/Einzelplatz, 05.11.2026), nach MessagesPage.swift der iPad-App (Commit 1f99d9b):
// der Stud.IP-Posteingang, wie ihn der Abgleich lokal speichert. Liste (Absender als Rolle, Betreff ganz, Zeit, Punkt "neu seit
// dem letzten Besuch"), Suchfeld, Lesebereich mit dem ganzen Text, erkannten Tagen als Chips und "In Stud.IP öffnen". Breit stehen
// Liste und Lesebereich nebeneinander, schmal schiebt der Lesebereich die Liste weg ("Zurück"). Den Menüpunkt gibt es nur, wenn
// Stud.IP verbunden ist oder schon Nachrichten gespeichert sind (GET /api/studip/messages/status); die Zahl daran zählt die
// neuen. Regeln und Texte: messages-logic.js; Daten: app/studip_messages.py (nur Liste, nie die Einzelansicht, nichts wird in
// Stud.IP als gelesen markiert, nie im gehosteten Dienst, nie im Offline-Speicher, nie an die KI).
import { $, $$, api, icon, toast, todayISO, debounce } from "./core.js?v=47";
import * as L from "./messages-logic.js?v=4";

const { esc } = L;

function ensureCss() {
  if (document.getElementById("msg-css")) return;
  const l = document.createElement("link"); l.id = "msg-css"; l.rel = "stylesheet"; l.href = "messages.css?v=2"; document.head.append(l);
}

// ---------------------------------------------------------------- Menüpunkt und Zahl

/** Zahl der neuen Nachrichten am Menüpunkt (0 entfernt sie) */
export function setBadge(link, n) {
  if (!link) return;
  let b = $(".msg-count", link);
  const text = L.badgeText(n);
  if (!text) { b?.remove(); link.removeAttribute("aria-label"); return; }
  if (!b) { b = document.createElement("span"); b.className = "msg-count"; link.append(b); }
  b.textContent = text;
  link.setAttribute("aria-label", `${L.TEXTS.title}, ${L.badgeLabel(n)}`);
}

/** Menüpunkt "Nachrichten" direkt nach "Übersicht" anlegen bzw. entfernen; Zahl nachziehen */
export async function refreshNav() {
  let st;
  try { st = await api("/studip/messages/status"); } catch { return; }
  const nav = $("#nav");
  if (!nav) return;
  let a = $('a[data-route="messages"]', nav);
  if (!st.available) { a?.remove(); return; }
  if (!a) {
    ensureCss();
    a = document.createElement("a");
    a.href = "#/messages"; a.dataset.route = "messages"; a.title = L.TEXTS.title;
    a.innerHTML = `${icon("mail", 18)}<span>${esc(L.TEXTS.title)}</span>`;
    const dash = $('a[data-route="dashboard"]', nav);
    if (dash) dash.after(a); else nav.prepend(a);
  }
  a.classList.toggle("active", /^#\/messages/.test(location.hash));
  setBadge(a, location.hash.startsWith("#/messages") ? 0 : st.new_count);
}

let started = false;
/** Einmal nach dem Start; danach bei Seitenwechseln und alle 2 Minuten bei sichtbarem Fenster */
export function startNavItem() {
  if (started) return; started = true;
  refreshNav();
  window.addEventListener("hashchange", () => { setTimeout(refreshNav, 400); });
  setInterval(() => { if (!document.hidden) refreshNav(); }, 120000);
}

// ---------------------------------------------------------------- Seite

export async function viewMessages(_, __, view) {
  ensureCss();
  const today = todayISO();
  let data = null, selected = null, previousMark, markTaken = false, query = "";

  view.innerHTML = `<div class="content msg-page">
    <div class="page-head"><div><h1>${esc(L.TEXTS.title)}</h1><div class="sub" id="msgSub"></div></div><div class="row"><button class="btn sm" id="msgSync">${icon("sync", 14)} ${esc(L.TEXTS.sync)}</button></div></div>
    <div id="msgBody"></div></div>`;
  const body = $("#msgBody", view), sub = $("#msgSub", view);
  $("#msgSync", view).onclick = async () => {
    try { await api("/sync", { method: "POST" }); toast("Synchronisierung gestartet"); window.pollBg?.(); } catch (e) { toast(e.message, 4000); }
  };

  async function load(first) {
    try {
      data = await api("/studip/messages" + (query ? `?q=${encodeURIComponent(query)}` : ""));
    } catch (e) { data = null; body.innerHTML = `<div class="card empty" id="msgEmpty">${icon("alert", 32)}<div>Nachrichten nicht lesbar: ${esc(e.message)}</div></div>`; sub.textContent = ""; return; }
    if (!markTaken) { previousMark = data.seen_up_to; markTaken = true; }
    if (first) draw(); else drawResults();
    // Die Seite ist offen: alles Gespeicherte gilt als gesehen; die Punkte bleiben für diesen Besuch
    if (data.new_count > 0) {
      api("/studip/messages/seen", { method: "POST" }).then(() => setBadge($('#nav a[data-route="messages"]'), 0)).catch(() => {});
    }
  }

  const wide = () => window.matchMedia("(min-width: 901px)").matches;

  function draw() {
    sub.textContent = data.total ? `${L.countText(data.total)} · ${L.syncLine(data.fetched_at)}` : L.syncLine(data.fetched_at);
    if (!data.total) {
      const why = data.available ? "" : `<p class="muted small">Nachrichten gibt es in der Windows-App, sobald ${L.sourceName(data.source)} verbunden ist.</p>`;
      body.innerHTML = `<div class="card empty" id="msgEmpty">${icon("mail", 36)}<div>${esc(L.TEXTS.empty)}</div><p class="muted small">${esc(L.syncLine(data.fetched_at))}</p>${why}</div>`;
      return;
    }
    body.innerHTML = `<div class="msg-search">${icon("search", 16)}<input class="input" id="msgQ" type="search" autocomplete="off" placeholder="${esc(L.TEXTS.searchPrompt)}" aria-label="${esc(L.TEXTS.searchPrompt)}" value="${esc(query)}"></div>
      <div class="card pad-0 msg-pane" id="msgPane"><div class="msg-list" id="msgList" role="group" aria-label="${esc(L.TEXTS.title)}"></div><div class="msg-reader" id="msgReader" aria-live="polite"></div></div>`;
    $("#msgQ", body).oninput = debounce(e => { query = e.target.value.trim(); load(false); }, 220);
    drawResults();
  }

  function drawResults() {
    const msgs = data.messages;
    if (selected && !msgs.some(m => m.id === selected)) selected = null;
    if (!selected && wide() && msgs.length) selected = msgs[0].id;
    $("#msgList", body).innerHTML = msgs.length ? L.listHtml(msgs, { selected, mark: previousMark, today }) : `<div class="msg-none muted small">${esc(L.noHits(query))}</div>`;
    $$(".msg-row", body).forEach(b => b.onclick = () => select(b.dataset.id));
    drawReader(false);
  }

  function drawReader(focus) {
    const pane = $("#msgPane", body), box = $("#msgReader", body);
    const m = data.messages.find(x => x.id === selected);
    pane.classList.toggle("has-sel", !!m);
    if (!m) { box.innerHTML = `<div class="msg-pick muted">${icon("mail", 30)}<div>${esc(data.messages.length ? L.TEXTS.pick : L.noHits(query))}</div></div>`; return; }
    box.innerHTML = L.readerHtml(m, { today, back: true, icon });
    // Antworten / Allen antworten (05.11.2026, message-reply.js): Knoepfe, "Beantwortet am …", eigene Antwort
    import("./message-reply.js?v=6").then(R => { if (selected === m.id) R.decorateReader(box, m, { onSent: () => load(false) }); }).catch(() => {});
    box.scrollTop = 0;
    $(".msg-back", box).onclick = () => { selected = null; drawResults(); $(".msg-row", body)?.focus(); };
    $$(".msg-row", body).forEach(b => { const on = b.dataset.id === selected; b.classList.toggle("on", on); if (on) b.setAttribute("aria-current", "true"); else b.removeAttribute("aria-current"); });
    if (focus) $(".msg-title", box)?.focus();
  }

  function select(id) { selected = id; drawReader(true); window.scrollTo(0, 0); }

  await load(true);
}

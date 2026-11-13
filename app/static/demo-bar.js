// Demo nur für die Store-Prüfung: schmale Leiste "Demo-Inhalte – erfunden, ohne Hochschule" mit "Beenden" über jeder Seite
// und der kleine Link "Ohne Hochschulkonto ansehen (Demo)" auf der ersten Seite ohne Hochschulverbindung. Regeln, Texte und
// Entscheidung: demo-logic.js; Inhalt der Demo und rückstandsloses Entfernen: app/demo.py (GET/POST /api/demo).
// Nur im Einzelplatz (Windows-App/PC), nie im gehosteten Dienst.
import { $, api, icon, toast, modal, state } from "./core.js?v=47";
import * as D from "./demo-logic.js?v=1";

let active = false;

function ensureCss() {
  if (document.getElementById("demo-css")) return;
  const l = document.createElement("link"); l.id = "demo-css"; l.rel = "stylesheet"; l.href = "demo-bar.css?v=1"; document.head.append(l);
}

function setBar(on) {
  active = on;
  document.body.classList.toggle("demo-on", on);
  let bar = $("#demoBar");
  if (!on) { bar?.remove(); return; }
  ensureCss();
  if (!bar) {
    bar = document.createElement("div"); bar.id = "demoBar"; bar.className = "demo-bar"; bar.setAttribute("role", "region"); bar.setAttribute("aria-label", "Demo-Hinweis");
    $("#view").before(bar);
  }
  bar.innerHTML = D.barHtml(icon);
  $("#demoEnd", bar).onclick = endDemo;
}

/** Zurück zur Übersicht (dort steht ohne Verbindung wieder die erste Seite mit dem Link) */
function toStart() {
  if ((location.hash || "#/dashboard") === "#/dashboard") state.route?.(); else location.hash = "#/dashboard";
}

export async function startDemo(btn) {
  if (btn) { btn.disabled = true; btn.textContent = D.TEXTS.running; }
  try {
    const d = await api("/demo", { method: "POST", body: { enabled: true } });
    setBar(true);
    toast(D.installedText(d), 3500);
    toStart();
  } catch (e) {
    toast(e.message, 4000);
    if (btn) { btn.disabled = false; btn.textContent = D.TEXTS.link; }
  }
}

export function endDemo() {
  const m = modal(`<h3>${icon("log-out", 18)} ${D.TEXTS.end}?</h3><p>${D.TEXTS.confirmEnd}</p>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="demoEndYes">${D.TEXTS.end}</button></div>`);
  $("#demoEndYes", m).onclick = async e => {
    e.target.disabled = true;
    try {
      await api("/demo", { method: "POST", body: { enabled: false, thorough: true } });
      m.remove(); setBar(false); toast(D.TEXTS.ended, 3000); toStart();
    } catch (x) { toast(x.message, 4000); e.target.disabled = false; }
  };
}

/** Einmal nach dem Start: Leiste zeigen, wenn die Demo läuft; Abgleich mit der Hochschule bleibt in der Demo aus */
export async function init() {
  if (state.hosted) return;
  document.addEventListener("click", e => {
    if (!active || !e.target.closest?.("#syncBtn")) return;
    e.stopImmediatePropagation(); e.preventDefault(); toast(D.TEXTS.syncBlocked, 4000);
  }, true);
  try { setBar(!!(await api("/demo")).enabled); } catch { /* ohne Demo-Angabe keine Leiste */ }
}

/** Erste Seite ohne Hochschulverbindung: Karte ganz unten auf der Übersicht mit dem Demo-Link (nur wenn nichts verbunden ist) */
export async function firstStart(view) {
  if (state.hosted) return;
  const get = (p, pick) => api(p).then(pick).catch(() => null);
  const [demo, session, cred, mods] = await Promise.all([
    get("/demo", d => !!d.enabled), get("/university/session", s => !!s.session),
    get("/credentials", c => !!(c.user && c.password_set)), get("/modules", m => Array.isArray(m) ? m.length : null)]);
  if (!view.isConnected || !D.firstStartVisible({ hosted: false, demo, session, credentials: cred, modules: mods })) return;
  ensureCss();
  const box = document.createElement("div"); box.innerHTML = D.firstStartHtml();
  view.querySelector(".content")?.append(box.firstElementChild);        // ganz unten, wie auf der Anmeldeseite des iPad
  $("#demoStart", view).onclick = e => startDemo(e.target);
}

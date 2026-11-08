// Erststart in Web und Windows (05.11.2026, wie OnboardingFlow/FirstLoginFlow auf dem iPad): nach der Anmeldung mit dem
// StudiNow-Konto einmal je Hochschule Willkommen (Rufname), Hochschule waehlen, an der Hochschule anmelden, Tarif.
// Regeln und Texte: onboarding-logic.js. Gespeichert wird nur in den Einstellungen (rufname, onboarding_done).
import * as O from "./onboarding-logic.js?v=2";
import { gateState } from "./account-gate.js?v=1";

const PENDING = "uniflow.rufname.pending";      // Rufname ueber einen Neustart (Hochschulwechsel am PC) hinweg

function ensureCss() {
  if (document.getElementById("ob-css")) return;
  const l = document.createElement("link"); l.id = "ob-css"; l.rel = "stylesheet"; l.href = "onboarding.css?v=1"; document.head.append(l);
}

/** Pruefen und bei Bedarf zeigen. deps: { api, icon, esc, toast, state } aus app.js; liefert true, wenn gezeigt */
export async function maybeStart({ api, icon, esc, toast, state }) {
  if (!state.gated) return false;                                  // nur mit Konto-Pflicht (Dienst, Windows-App)
  const get = (p, pick) => api(p).then(pick).catch(() => null);
  const [settings, mods, demo, session] = await Promise.all([api("/settings").catch(() => null), get("/modules", m => (Array.isArray(m) ? m.length : 0)),
    state.hosted ? false : get("/demo", d => !!d.enabled), state.hosted ? false : get("/university/session", s => !!s.session)]);
  if (!settings) return false;
  const locked = gateState(state.entitlements, state.appAccount) === "locked";
  if (!O.shouldShow({ done: O.isDone(settings), locked, demo, modules: mods, session, hash: location.hash })) return false;
  show({ api, icon, esc, toast, state, settings });
  return true;
}

function show({ api, icon, esc, toast, state, settings }) {
  ensureCss();
  let pending = ""; try { pending = localStorage.getItem(PENDING) || ""; } catch {}
  const st = { i: 0, rufname: settings.rufname || pending || "", uni: settings.university, running: settings.university, unis: [], loggedIn: false, polling: null };
  const box = document.createElement("div"); box.className = "ob-overlay"; box.setAttribute("role", "dialog"); box.setAttribute("aria-modal", "true"); box.setAttribute("aria-label", "Erster Start");
  document.body.append(box);
  api("/services").then(s => { st.unis = s.universities || []; st.unisNote = s.universities_note || ""; if (O.STEPS[st.i].id === "university") draw(); }).catch(() => {});
  const close = () => { clearInterval(st.polling); box.remove(); };
  const finish = async (hash = "#/dashboard") => {
    try { await api("/settings", { method: "PUT", body: { onboarding_done: "1", rufname: st.rufname.trim() } }); } catch {}
    try { localStorage.removeItem(PENDING); } catch {}
    close(); if (location.hash !== hash) location.hash = hash; else state.route();
  };
  const dots = () => `<div class="ob-dots" aria-hidden="true">${O.STEPS.map((_, k) => `<i class="${k <= st.i ? "on" : ""}"></i>`).join("")}</div><p class="ob-step">${esc(O.stepLabel(st.i))}</p>`;
  const page = inner => { box.innerHTML = `<div class="ob-page">${inner}</div>`; box.querySelector("input, button.primary, a.primary")?.focus({ preventScroll: true }); };
  const next = () => { st.i++; draw(); };

  function draw() {
    const step = O.STEPS[st.i].id;
    if (step === "welcome") {
      page(`<div class="ob-logo">${icon("graduation", 38)}</div><h1>Willkommen bei StudiNow</h1>
        <p class="ob-lead">Stud.IP-Dateien, Lernplan und Notizen – dein Studium an einem Ort.</p>
        <label class="field"><b>Wie sollen wir dich nennen?</b><input class="input" id="obName" maxlength="40" autocomplete="given-name" placeholder="z. B. Ahmad" value="${esc(st.rufname)}"></label>
        <p class="muted small" style="margin:.3rem 0 1.2rem">Für „Hallo … – lass uns gemeinsam lernen.“ auf der Übersicht. Du kannst es leer lassen.</p>
        <div class="ob-foot"><button class="btn primary" id="obNext">Weiter ${icon("arrow-right", 15)}</button></div>`);
      const go = () => { st.rufname = box.querySelector("#obName").value.trim(); api("/settings", { method: "PUT", body: { rufname: st.rufname } }).catch(() => {}); next(); };
      box.querySelector("#obNext").onclick = go;
      box.querySelector("#obName").onkeydown = e => { if (e.key === "Enter") go(); };
    } else if (step === "university") {
      const list = st.unis.length ? st.unis : [{ key: st.running, name: st.running }];
      page(`${dots()}<h1>Hochschule wählen</h1><p class="ob-lead">An welcher Hochschule studierst du? StudiNow richtet danach die passenden Zugänge ein.</p>
        <div class="ob-choices" role="radiogroup" aria-label="Hochschule">${list.map(u => `<label class="ob-choice"><input type="radio" name="obUni" value="${esc(u.key)}"${u.key === st.uni ? " checked" : ""}${state.hosted && u.key !== st.running ? " disabled" : ""}> <span>${esc(u.name)}</span></label>`).join("")}</div>
        ${state.hosted ? `<p class="muted small" style="margin:-.6rem 0 1.2rem">Die Hochschule gehört zu deinem StudiNow-Konto.</p>` : ""}
        ${st.unisNote ? `<p class="muted small" style="margin:-.6rem 0 1.2rem">${esc(st.unisNote)}</p>` : ""}
        <div class="ob-foot"><button class="btn" id="obBack">Zurück</button><span class="spacer"></span><button class="btn primary" id="obNext">Weiter ${icon("arrow-right", 15)}</button></div>`);
      box.querySelector("#obBack").onclick = () => { st.i--; draw(); };
      box.querySelector("#obNext").onclick = async () => {
        st.uni = box.querySelector("input[name=obUni]:checked")?.value || st.running;
        if (!O.needsRestart(st.uni, st.running, state.hosted)) { next(); return; }
        try { await api("/settings", { method: "PUT", body: { university: st.uni } }); } catch (e) { toast(e.message, 5000); return; }
        try { localStorage.setItem(PENDING, st.rufname); } catch {}
        page(`<h1>Bitte StudiNow neu starten</h1><p class="ob-lead">Jede Hochschule hat einen eigenen Datenordner. Nach dem Neustart öffnet StudiNow die Daten der gewählten Hochschule und es geht hier mit der Anmeldung weiter.</p>
          <div class="ob-foot"><button class="btn primary" id="obOk">Verstanden</button></div>`);
        box.querySelector("#obOk").onclick = close;
      };
    } else if (step === "login") {
      const L = O.loginStep(st.uni, state.hosted);
      page(`${dots()}<h1>${esc(L.title)}</h1><p class="ob-lead">${esc(L.intro)}</p>
        <div id="obLoginState">${st.loggedIn ? `<p class="ob-note ob-ok">${icon("check", 16)} Angemeldet – der erste Abgleich läuft. Du kannst schon loslegen; die Übersicht zeigt seinen Stand.</p>` : ""}</div>
        <div class="ob-foot">${st.loggedIn ? `<button class="btn primary" id="obNext">Weiter ${icon("arrow-right", 15)}</button>` : `<button class="btn primary" id="obLogin">${esc(L.action)}</button><span class="spacer"></span><button class="ob-later" id="obLater">Später anmelden</button>`}</div>`);
      box.querySelector("#obNext")?.addEventListener("click", next);
      box.querySelector("#obLater")?.addEventListener("click", next);
      box.querySelector("#obLogin")?.addEventListener("click", async e => {
        if (state.hosted) { next(); return; }       // Dienst: kein Hochschul-Zugang im Web (06.11.2026)
        e.target.disabled = true;
        try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden", 4000); }
        catch (x) { toast(x.message, 5000); e.target.disabled = false; return; }
        clearInterval(st.polling);
        st.polling = setInterval(async () => {
          const r = await api("/university/session").catch(() => null);
          if (r?.session) { clearInterval(st.polling); st.loggedIn = true; api("/sync", { method: "POST" }).then(() => window.pollBg?.()).catch(() => {}); draw(); }
          else if (r && r.window && r.window.state !== "open") { clearInterval(st.polling); e.target.disabled = false; }
        }, 2000);
      });
    } else {
      const P = O.planInfo(gateState(state.entitlements, state.appAccount), state.entitlements);
      page(`${dots()}<h1>${esc(P.title)}</h1><p class="ob-lead">${esc(P.text)}</p>
        <div class="ob-foot"><button class="btn primary" id="obDone">Los geht’s ${icon("arrow-right", 15)}</button><a class="btn" href="#/abo" id="obAbo">Tarife ansehen</a></div>`);
      box.querySelector("#obDone").onclick = () => finish();
      box.querySelector("#obAbo").onclick = e => { e.preventDefault(); finish("#/abo"); };
    }
  }
  draw();
}

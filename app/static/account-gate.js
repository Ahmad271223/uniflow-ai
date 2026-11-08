// Konto- und Abo-Pflicht in Web und Windows (Entscheidung des Inhabers vom 05.11.2026; Server: app/access.py,
// app/account_mode.py). Ohne Anmeldung nur der Anmeldebildschirm (Windows; im Web die Seite /login), waehrend der Probe
// alles wie Pro AI mit einer Leiste "noch N Tage", ohne Abo nur die Abo-Seite und die eigenen Daten zum Ansehen und
// Exportieren (nur lesen; der Server lehnt Schreiben mit 402 subscription_required ab). Die iPad-App betrifft das nicht.
// Reines Modul (kein Import aus core.js, kein DOM beim Laden): tests/js/account-gate.test.mjs prueft die Texte und Zustaende;
// app.js ruft mountLogin und gateBarHtml.

const escHtml = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const GATE_TEXTS = {
  lockedTitle: "Kein aktives Abo",
  lockedText: "Ohne aktives Abo kannst du deine Daten nur ansehen und exportieren. Wähle StudiNow Plus oder Pro AI, um weiterzumachen – deine Daten bleiben in jedem Fall erhalten.",
  unverifiedTitle: "Abo konnte nicht geprüft werden",
  choose: "Abo wählen",
  viewData: "Meine Daten ansehen",
  exportData: "Meine Daten exportieren",
  recheck: "Erneut prüfen",
  readOnly: "Nur lesen",
  apple: "Du hast schon ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones.",
  loginTitle: "Bei StudiNow anmelden",
  loginText: "StudiNow für Windows braucht dein StudiNow-Konto – dasselbe wie auf dem iPad und im Web. Neue Konten haben 7 Tage Probe mit allem wie StudiNow Pro AI, ohne Zahlungsdaten.",
  browserWait: "Im Browser geöffnet. Melde dich dort an; StudiNow wechselt danach von selbst weiter.",
  checkoutOpened: "Die Bezahlseite ist in deinem Browser geöffnet. Nach dem Bezahlen erscheint dein Abo hier von selbst.",
};

/** "Probe: noch N Tage alles wie StudiNow Pro AI" */
export const trialBarTitle = days => { const n = Math.max(1, Number(days) || 1); return `Probe: noch ${n} ${n === 1 ? "Tag" : "Tage"} alles wie StudiNow Pro AI`; };

/**
 * Zustand der Oberflaeche: "open" (keine Pflicht: eigener PC ohne Konto-Pflicht, Entwicklung), "login" (Windows ohne
 * Anmeldung), "locked" (ohne Abo oder Abo nicht pruefbar: nur lesen), "trial" (Probe laeuft), "active" (Plus/Pro AI).
 * ent = GET /api/entitlements (Feld access), account = GET /api/app-account/status (nur Windows).
 */
export function gateState(ent, account) {
  if (account && account.required && account.state === "signed_out") return "login";
  const a = ent && ent.access;
  if (!a || !a.account_required) return "open";
  if (a.locked) return "locked";
  if (a.state === "trial") return "trial";
  return "active";
}

/** Export der eigenen Daten: Windows die Daten dieses PCs, im Web das ganze Konto (DSGVO-Export) */
export const exportHref = ent => (ent && ent.mode === "account" ? "/api/app-account/export" : "/api/account/export");

/** Leiste ueber dem Inhalt: ohne Abo mit "Abo wählen" und "Meine Daten exportieren", in der Probe mit den Resttagen. */
export function gateBarHtml(ent, account, { icon = () => "", esc = escHtml } = {}) {
  const st = gateState(ent, account);
  const box = (tone, inner) => `<div class="gate-bar" role="status" style="display:flex;flex-wrap:wrap;align-items:center;gap:.5rem .8rem;padding:.55rem 1rem;margin:0;border-bottom:1px solid var(--line, #e5e8f0);background:var(--${tone}-soft, #fff6e5)">${inner}</div>`;
  if (st === "locked") {
    const unverified = ent.access.state === "unverified";
    return box("warn", `${icon("alert", 16)}<span style="flex:1;min-width:14rem"><b>${esc(unverified ? GATE_TEXTS.unverifiedTitle : GATE_TEXTS.lockedTitle)} · ${esc(GATE_TEXTS.readOnly)}</b> <span class="small muted">${esc(ent.access.message || GATE_TEXTS.lockedText)}</span></span>`
      + (unverified ? `<button type="button" class="btn sm" id="gateRecheck">${esc(GATE_TEXTS.recheck)}</button>` : `<a class="btn sm primary" href="#/abo">${esc(GATE_TEXTS.choose)}</a>`)
      + `<a class="btn sm" href="${exportHref(ent)}" download>${icon("download", 14)} ${esc(GATE_TEXTS.exportData)}</a>`);
  }
  if (st === "trial") {
    return box("info", `${icon("sparkles", 16)}<span style="flex:1;min-width:14rem"><b>${esc(trialBarTitle(ent.access.trial_days_left))}</b> <span class="small muted">Danach brauchst du ein Abo; deine Daten bleiben in jedem Fall erhalten.</span></span><a class="btn sm" href="#/abo">${esc(GATE_TEXTS.choose)}</a>`);
  }
  return "";
}

/** Anmeldebildschirm der Windows-App (ohne Seitenleiste). info = GET /api/app-account/status */
export function loginScreenHtml(info, { icon = () => "", esc = escHtml } = {}) {
  const host = (() => { try { return new URL(info.service_url).host; } catch { return "app.studinow.app"; } })();
  return `<div class="gate-login" style="min-height:100vh;display:grid;place-items:center;padding:1.2rem;box-sizing:border-box;background:var(--bg)">
  <div style="width:min(420px,100%)">
    <div class="brand" style="justify-content:center;padding-bottom:1rem;font-size:1.2rem"><div class="logo">${icon("graduation", 18)}</div><span>StudiNow</span></div>
    <div class="card">
      <h1 style="font-size:1.25rem;margin:0 0 .3rem">${esc(GATE_TEXTS.loginTitle)}</h1>
      <p class="small muted" style="margin:0 0 .8rem">${esc(GATE_TEXTS.loginText)}</p>
      <form id="gateLogin" autocomplete="on">
        <label class="field">E-Mail<input class="input" name="email" type="email" required autocomplete="username" value="${esc(info.last_email || "")}"></label>
        <label class="field">Passwort<input class="input" name="password" type="password" required autocomplete="current-password"></label>
        <div class="small" id="gateMsg" role="alert" style="min-height:1.2em;margin:.4rem 0;color:var(--bad-text)">${esc(info.last_error || "")}</div>
        <button class="btn primary" type="submit" style="width:100%;justify-content:center">Anmelden</button>
      </form>
      <div style="display:grid;gap:.5rem;margin-top:.9rem">
        <button type="button" class="btn" data-browser="login" data-provider="apple" style="justify-content:center">Mit Apple anmelden</button>
        <button type="button" class="btn" data-browser="login" data-provider="google" style="justify-content:center">Mit Google anmelden</button>
      </div>
      <div class="row wrap small" style="justify-content:space-between;gap:.6rem;margin-top:.9rem">
        <a href="#" data-browser="register">Neu hier? Konto anlegen</a><a href="#" data-browser="forgot">Passwort vergessen?</a>
      </div>
      <p class="tiny muted" style="margin:.9rem 0 0">Apple, Google, „Konto anlegen“ und „Passwort vergessen“ öffnen ${esc(host)} in deinem Browser. Gespeichert wird nur die Anmeldung dieses PCs (in der Windows-Anmeldeinformationsverwaltung), nie dein Passwort. Deine Daten auf diesem PC bleiben erhalten: <a href="/api/app-account/export" download>${esc(GATE_TEXTS.exportData)}</a>.</p>
    </div>
  </div></div>`;
}

/** Anmeldebildschirm einhaengen und bedienen; nach erfolgreicher Anmeldung laedt die Seite neu. */
export function mountLogin(root, info, { icon, esc } = {}) {
  const shell = root.querySelector("#shell"); if (shell) shell.hidden = true;
  const mob = root.querySelector("#mobileNav"); if (mob) mob.hidden = true;
  const wrap = document.createElement("div"); wrap.id = "gateLoginRoot"; wrap.innerHTML = loginScreenHtml(info, { icon, esc });
  root.prepend(wrap);
  const msg = wrap.querySelector("#gateMsg");
  const say = (t, ok) => { msg.textContent = t || ""; msg.style.color = ok ? "var(--ok-text)" : "var(--bad-text)"; };
  const post = async (path, body) => {
    const r = await fetch("/api/app-account" + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
    let d = null; try { d = await r.json(); } catch {}
    if (!r.ok) throw new Error((d && (typeof d.detail === "string" ? d.detail : d.detail?.detail)) || `Fehler ${r.status}`);
    return d;
  };
  let poll = null;
  const waitForLogin = () => {
    clearInterval(poll); const until = Date.now() + 10 * 60 * 1000;
    poll = setInterval(async () => {
      if (Date.now() > until) { clearInterval(poll); return; }
      try { const s = await fetch("/api/app-account/status").then(r => r.json()); if (s.signed_in) { clearInterval(poll); location.reload(); } } catch {}
    }, 2000);
  };
  wrap.querySelector("#gateLogin").onsubmit = async e => {
    e.preventDefault(); const f = e.target; const b = f.querySelector("button"); b.disabled = true; say("Melde an …", true);
    try { await post("/login", { email: f.email.value.trim(), password: f.password.value }); location.reload(); }
    catch (x) { say(x.message); b.disabled = false; }
  };
  wrap.querySelectorAll("[data-browser]").forEach(el => el.addEventListener("click", async e => {
    e.preventDefault();
    try { const r = await post("/browser-login", { mode: el.dataset.browser, provider: el.dataset.provider || undefined }); say(r && r.opened === false ? `Der Browser ließ sich nicht öffnen. Bitte diese Adresse im Browser aufrufen: ${r.url}` : GATE_TEXTS.browserWait, true); waitForLogin(); }
    catch (x) { say(x.message); }
  }));
  return wrap;
}

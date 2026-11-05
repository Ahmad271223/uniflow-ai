// Anmeldeseite des gehosteten Dienstes: Anmelden, Konto anlegen, Passwort vergessen, neues Passwort (/login?reset=TOKEN),
// „Mit Google/Apple anmelden“ (nur wenn /api/account/providers den Anbieter meldet; die SDKs kommen von
// accounts.google.com bzw. appleid.cdn-apple.com, erlaubt durch die CSP der Anmeldeseite in app/server.py).
// Ruft nur die oeffentlichen Kontopfade (Vertrag G1); die Sitzung kommt als HttpOnly-Cookie vom Server. Kein Inline-Skript (CSP).
// Anmeldung fuer StudiNow fuer Windows (05.11.2026, app/app_login_api.py): /login?app=windows&redirect_uri=http://127.0.0.1:
// <port>/konto/rueckkehr&state=..&code_challenge=.. – nach der Anmeldung holt die Seite mit der Browser-Sitzung einen
// Einmal-Code und leitet auf den eigenen PC zurueck; ist schon jemand angemeldet, fragt sie vorher nach.
import { serviceError } from "./service-errors.js?v=1";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const UNI = { luh: "Leibniz Universität Hannover", hildesheim: "Universität Hildesheim", hsh: "Hochschule Hannover" };
const post = async (path, body) => {
  const r = await fetch("/api/account" + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) throw serviceError(r.status, d, { retryAfter: parseInt(r.headers.get("Retry-After") ?? "", 10) });   // Texte der Fehlercodes: service-errors.js
  return d;
};
const say = (id, text, ok) => { const m = $("#" + id); m.textContent = text; m.className = "msg " + (ok ? "ok" : "bad"); };
const busy = (form, on) => $$("button, input, select", form).forEach(x => x.disabled = on);
const device = () => ("Browser " + (navigator.userAgentData?.platform || navigator.platform || "")).trim();
const loadScript = src => new Promise((ok, bad) => { const s = document.createElement("script"); s.src = src; s.async = true; s.onload = ok; s.onerror = bad; document.head.appendChild(s); });
// Windows-App wartet auf die Anmeldung (nur Rueckleitungen auf diesen PC, sonst gilt die normale Seite)
const appFlow = (() => {
  const q = new URLSearchParams(location.search);
  const r = q.get("redirect_uri") || "";
  if (q.get("app") !== "windows" || !/^http:\/\/(127\.0\.0\.1|localhost|\[::1\]):\d{1,5}\/konto\/rueckkehr$/.test(r)) return null;
  return { redirect_uri: r, state: q.get("state") || "", code_challenge: q.get("code_challenge") || "", tab: q.get("tab") || "login", provider: q.get("provider") || "" };
})();
async function handBack() {
  const r = await fetch("/api/app-login/code", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ redirect_uri: appFlow.redirect_uri, state: appFlow.state, code_challenge: appFlow.code_challenge }) });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) throw serviceError(r.status, d);
  location.replace(d.redirect);
}
/** nach erfolgreicher Anmeldung: in die Web-App oder zurueck in die Windows-App */
const done = async () => { if (appFlow) await handBack(); else location.replace("/"); };
function show(tab) {
  $$("form").forEach(f => f.classList.toggle("active", f.id === tab));
  $$("#tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  $("#tabs").style.display = tab === "login" || tab === "register" ? "flex" : "none";
  $("#social").style.display = tab === "login" || tab === "register" ? "" : "none";
  $("#" + tab + " input")?.focus();
}
$$("[data-tab]").forEach(el => el.addEventListener("click", e => { e.preventDefault(); show(el.dataset.tab); }));

const info = await fetch("/api/account/info").then(r => r.json()).catch(() => null);
if (!info || !info.hosted) {
  location.replace("/");                                   // am PC gibt es keine Anmeldung
} else {
  $("#uniSelect").innerHTML = info.universities.map(k => `<option value="${k}">${UNI[k] || k}</option>`).join("");
  $$("#pwHint, #pwHint2").forEach(h => h.textContent = `(mindestens ${info.password_min} Zeichen)`);
  $$('input[name="password"]').forEach(i => i.minLength = info.password_min);
  const token = new URLSearchParams(location.search).get("reset");
  const verify = new URLSearchParams(location.search).get("verify");
  show(token ? "reset" : appFlow && ["register", "forgot"].includes(appFlow.tab) ? appFlow.tab : "login");
  if (appFlow) {
    // Hinweis oben: fuer welche App angemeldet wird; mit bestehender Browser-Sitzung erst nachfragen (kein stilles Weiterreichen)
    const note = document.createElement("div"); note.className = "msg ok"; note.style.display = "block"; note.style.margin = "0 0 .8rem";
    note.textContent = appFlow.provider === "apple" ? "Anmeldung für StudiNow für Windows – wähle unten „Mit Apple anmelden“."
      : appFlow.provider === "google" ? "Anmeldung für StudiNow für Windows – wähle unten „Mit Google anmelden“."
      : "Anmeldung für StudiNow für Windows. Danach geht es in der App weiter.";
    $(".card").prepend(note);
    const me = await fetch("/api/account/me").then(r => r.ok ? r.json() : null).catch(() => null);
    if (me && me.user) {
      const box = document.createElement("div"); box.className = "card flat"; box.style.margin = "0 0 .8rem";
      box.innerHTML = `<p class="small" style="margin:0 0 .5rem">Du bist im Browser als <b></b> angemeldet. Mit diesem Konto bei StudiNow für Windows anmelden?</p><div class="row wrap" style="gap:.5rem"><button type="button" class="btn primary sm" id="appGo">Weiter</button><button type="button" class="btn sm" id="appOther">Anderes Konto</button></div><div class="msg" id="appMsg"></div>`;
      box.querySelector("b").textContent = me.user.email;
      note.after(box);
      box.querySelector("#appGo").onclick = async e => { e.target.disabled = true; try { await handBack(); } catch (x) { say("appMsg", x.message); e.target.disabled = false; } };
      box.querySelector("#appOther").onclick = async () => { await fetch("/api/account/logout", { method: "POST" }).catch(() => {}); box.remove(); };
    }
  }
  if (verify) {                                              // Link aus der Willkommensmail: Adresse bestaetigen
    history.replaceState(null, "", "/login");
    post("/verify-email", { token: verify })
      .then(() => say("loginMsg", "E-Mail-Adresse bestätigt. Du kannst dich jetzt anmelden.", true))
      .catch(x => say("loginMsg", x.message));
  }
  $("#login").onsubmit = async e => {
    e.preventDefault(); const f = e.target; busy(f, true);
    try { await post("/login", { email: f.email.value.trim(), password: f.password.value, device_name: device() }); await done(); }
    catch (x) { say("loginMsg", x.message); busy(f, false); }
  };
  $("#register").onsubmit = async e => {
    e.preventDefault(); const f = e.target;
    if (f.password.value !== f.password2.value) return say("registerMsg", "Die Passwörter stimmen nicht überein.");
    busy(f, true);
    try { await post("/register", { email: f.email.value.trim(), password: f.password.value, university: f.university.value, device_name: device() }); await done(); }
    catch (x) { say("registerMsg", x.message); busy(f, false); }
  };
  $("#forgot").onsubmit = async e => {
    e.preventDefault(); const f = e.target; busy(f, true);
    try { const d = await post("/password/reset-request", { email: f.email.value.trim() }); say("forgotMsg", d.message || "Wenn es ein Konto gibt, wurde ein Link verschickt.", true); }
    catch (x) { say("forgotMsg", x.message); }
    busy(f, false);
  };
  $("#reset").onsubmit = async e => {
    e.preventDefault(); const f = e.target;
    if (f.password.value !== f.password2.value) return say("resetMsg", "Die Passwörter stimmen nicht überein.");
    busy(f, true);
    try { await post("/password/reset", { token, new_password: f.password.value }); history.replaceState(null, "", "/login"); show("login"); say("loginMsg", "Passwort gesetzt – jetzt anmelden.", true); }
    catch (x) { say("resetMsg", x.message); }
    busy(f, false);
  };

  // Mit Google / Apple anmelden: ein neues Konto nimmt die Hochschule aus der Auswahl im Reiter „Konto anlegen“.
  const prov = await fetch("/api/account/providers").then(r => r.json()).catch(() => null);
  const social = $("#social");
  const uni = () => $("#uniSelect").value;
  if (prov && prov.google && prov.google_web_client_id) {
    try {
      await loadScript("https://accounts.google.com/gsi/client");
      window.google.accounts.id.initialize({ client_id: prov.google_web_client_id, callback: async r => {
        try { await post("/login/google", { id_token: r.credential, university: uni(), device_name: device() }); await done(); }
        catch (x) { say("socialMsg", x.message); }
      } });
      window.google.accounts.id.renderButton($("#googleBtn"), { type: "standard", size: "large", text: "signin_with", locale: "de", width: 320 });
      social.hidden = false;
    } catch { /* SDK nicht erreichbar: Anmeldung per Passwort bleibt */ }
  }
  if (prov && prov.apple && prov.apple_web_client_id) {
    try {
      await loadScript("https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/de_DE/appleid.auth.js");
      const nonce = crypto.randomUUID().replace(/-/g, "");
      window.AppleID.auth.init({ clientId: prov.apple_web_client_id, scope: "email", redirectURI: location.origin + "/login", usePopup: true, nonce });
      const btn = $("#appleBtn");
      btn.hidden = false;
      btn.onclick = async () => {
        btn.disabled = true;
        try {
          const r = await window.AppleID.auth.signIn();
          await post("/login/apple", { id_token: r.authorization.id_token, nonce, university: uni(), device_name: device() });
          await done();
        } catch (x) { if (!x || x.error !== "popup_closed_by_user") say("socialMsg", x?.message || "Anmeldung bei Apple abgebrochen."); }
        btn.disabled = false;
      };
      social.hidden = false;
    } catch { /* SDK nicht erreichbar: Anmeldung per Passwort bleibt */ }
  }
}

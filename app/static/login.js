// Anmeldeseite des gehosteten Dienstes: Anmelden, Konto anlegen, Passwort vergessen, neues Passwort (/login?reset=TOKEN).
// Ruft nur die oeffentlichen Kontopfade (Vertrag G1); die Sitzung kommt als HttpOnly-Cookie vom Server. Kein Inline-Skript (CSP).
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const UNI = { luh: "Leibniz Universität Hannover", hildesheim: "Universität Hildesheim" };
const post = async (path, body) => {
  const r = await fetch("/api/account" + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) throw new Error((d && d.detail) || `Fehler ${r.status}`);
  return d;
};
const say = (id, text, ok) => { const m = $("#" + id); m.textContent = text; m.className = "msg " + (ok ? "ok" : "bad"); };
const busy = (form, on) => $$("button, input, select", form).forEach(x => x.disabled = on);
const device = () => ("Browser " + (navigator.userAgentData?.platform || navigator.platform || "")).trim();
function show(tab) {
  $$("form").forEach(f => f.classList.toggle("active", f.id === tab));
  $$("#tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  $("#tabs").style.display = tab === "login" || tab === "register" ? "flex" : "none";
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
  show(token ? "reset" : "login");
  $("#login").onsubmit = async e => {
    e.preventDefault(); const f = e.target; busy(f, true);
    try { await post("/login", { email: f.email.value.trim(), password: f.password.value, device_name: device() }); location.replace("/"); }
    catch (x) { say("loginMsg", x.message); busy(f, false); }
  };
  $("#register").onsubmit = async e => {
    e.preventDefault(); const f = e.target;
    if (f.password.value !== f.password2.value) return say("registerMsg", "Die Passwörter stimmen nicht überein.");
    busy(f, true);
    try { await post("/register", { email: f.email.value.trim(), password: f.password.value, university: f.university.value, device_name: device() }); location.replace("/"); }
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
}

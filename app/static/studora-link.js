// Studora-Konto in der Windows-App verbinden (app/service_link.py): Anmelden am Dienst, Status, Abmelden, PDFs melden.
// Wird in der Community-Seite und in der Community-Leiste des Editors gezeigt. Das Passwort geht nur einmal ueber das
// lokale Backend an den Dienst; gespeichert wird allein das Sitzungs-Token auf diesem PC.
import { icon } from "./icons.js?v=31";

const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const PLAN = { free: "Studora Free", plus: "Studora Plus", pro_connect: "Studora Pro Connect", pro_ai: "Studora Pro AI" };

async function call(path, body) {
  const r = await fetch("/api/studora" + path, body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d?.detail || `Fehler ${r.status}`); e.code = d?.code; throw e; }
  return d;
}
export const linkStatus = (refresh = true) => call(`/status?refresh=${refresh}`);

/** Karte mit Anmeldeformular bzw. verbundenem Konto. `onChange(status)` nach Anmelden/Abmelden. */
export async function renderLinkCard(el, { onChange, compact = false } = {}) {
  let st;
  try { st = await linkStatus(); } catch (e) { el.innerHTML = `<div class="small muted">${esc(e.message)}</div>`; return null; }
  if (st.hosted) { el.innerHTML = ""; return st; }
  if (st.linked) {
    const u = st.user || {};
    const claims = st.claims ? `${st.claims.sent} PDFs gemeldet, ${new Date(st.claims.at * 1000).toLocaleString("de-DE", { dateStyle: "short", timeStyle: "short" })}` : "noch keine PDFs gemeldet";
    el.innerHTML = `<div class="sl-card">
      <div class="row" style="gap:.5rem;align-items:center"><span class="badge ok">${icon("check", 12)} Verbunden</span><b class="sl-mail">${esc(u.email || "")}</b></div>
      <div class="small muted" style="margin:.35rem 0">${esc(PLAN[u.plan] || u.plan || "")}${u.university ? ` · ${esc(u.university === "luh" ? "Leibniz Universität Hannover" : u.university === "hildesheim" ? "Universität Hildesheim" : u.university)}` : ""}${st.offline ? " · Dienst gerade nicht erreichbar" : ""}</div>
      ${u.email_verified === false ? `<div class="sl-warn small">${icon("alert", 13)} E-Mail noch nicht bestätigt: Teilen, Liken und Kommentieren gehen erst danach. <button class="btn ghost sm" data-sl="resend">Mail erneut senden</button></div>` : ""}
      ${st.university_mismatch ? `<div class="sl-warn small">${icon("alert", 13)} ${esc(st.university_mismatch)}</div>` : ""}
      <div class="small muted">${esc(claims)}</div>
      <div class="row wrap" style="gap:.4rem;margin-top:.5rem"><button class="btn sm" data-sl="claims">${icon("sync", 13)} PDFs jetzt melden</button><button class="btn sm ghost" data-sl="logout">${icon("x", 13)} Abmelden</button></div>
      <div class="sl-msg small"></div></div>`;
    const msg = $(".sl-msg", el);
    $('[data-sl="claims"]', el).onclick = async e => { e.target.disabled = true; try { const c = await call("/claims", {}); msg.textContent = `${c.sent} PDFs gemeldet.`; } catch (x) { msg.textContent = x.message; } e.target.disabled = false; };
    $('[data-sl="logout"]', el).onclick = async () => { if (!confirm("Vom Studora-Konto abmelden? Deine Notizen auf diesem PC bleiben erhalten.")) return; const s = await call("/logout", {}); onChange?.(s); renderLinkCard(el, { onChange, compact }); };
    const rs = $('[data-sl="resend"]', el); if (rs) rs.onclick = async () => { try { await call("/verify-email/resend", {}); msg.textContent = "Bestätigungsmail gesendet."; } catch (x) { msg.textContent = x.message; } };
    return st;
  }
  el.innerHTML = `<form class="sl-card sl-form" autocomplete="on">
    <div><b>${icon("user", 14)} Mit deinem Studora-Konto anmelden</b></div>
    <p class="small muted" style="margin:.3rem 0 .5rem">Dasselbe Konto wie auf dem iPad. ${compact ? "" : "Damit siehst, likest und kommentierst du Lösungen anderer zu deinen PDFs und teilst eigene. "}Dein Hochschul-Passwort bleibt auf diesem PC; das Studora-Passwort wird nicht gespeichert.${st.expired ? " <b>Die letzte Anmeldung ist abgelaufen.</b>" : ""}</p>
    ${st.env_url ? "" : `<label class="small">Adresse des Dienstes<input class="input" name="url" type="url" placeholder="https://…" value="${esc(st.url || "")}" required></label>`}
    <label class="small">E-Mail<input class="input" name="email" type="email" autocomplete="username" value="${esc(st.last_email || "")}" required></label>
    <label class="small">Passwort<input class="input" name="password" type="password" autocomplete="current-password" required></label>
    <div class="row" style="gap:.5rem;margin-top:.4rem"><button class="btn primary sm" type="submit">Anmelden</button><span class="sl-msg small"></span></div></form>`;
  const form = $("form", el), msg = $(".sl-msg", el);
  form.onsubmit = async ev => {
    ev.preventDefault(); const fd = new FormData(form); const b = form.querySelector("button"); b.disabled = true; msg.textContent = "Melde an …";
    try {
      const s = await call("/login", { url: fd.get("url") || undefined, email: fd.get("email"), password: fd.get("password") });
      form.reset(); onChange?.(s); await renderLinkCard(el, { onChange, compact });
      if (s.claims_error) $(".sl-msg", el).textContent = s.claims_error.detail;
    } catch (x) { msg.textContent = x.message; b.disabled = false; }
  };
  return st;
}

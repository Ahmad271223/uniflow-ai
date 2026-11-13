// Hinweis "KI-Hilfe: Was wird gesendet?" in Web und Windows (06.11.2026, wie auf dem iPad; Server app/ai_consent.py,
// Regeln ohne DOM in ai-consent-logic.js). `installConsentFetch()` haengt die Hilfe einmal beim Start um window.fetch:
// jede KI-Anfrage, die der Server mit 428 `ai_consent_required` ablehnt, zeigt den Hinweis und laeuft nach
// "Okay, los" einmal neu. Seit 13.11.2026 kurz: zuerst nur `short`, der Rest hinter "Genauer ansehen" (<details>). Texte kommen vom Server (gleich AIConsentText auf dem iPad).
import { esc, icon, modal } from "./core.js?v=47";
import { withConsent } from "./ai-consent-logic.js?v=1";

let installed = false;

/** Hinweis als Fenster; Promise<boolean> (true = zugestimmt). Schliessen ohne Knopf zaehlt als Abbrechen. */
export function askConsent(info) {
  const t = info?.text || {};
  const li = xs => (xs || []).map(x => `<li>${esc(x)}</li>`).join("");
  return new Promise(resolve => {
    const m = modal(`<h3>${icon("sparkles", 18)} ${esc(t.title || "KI-Hilfe: Was wird gesendet?")}</h3>
      <div class="ai-consent" style="max-height:min(60vh,520px);overflow:auto">
        <p>${esc(t.short || t.intro || "")}</p>
        <details class="ai-consent-more"><summary class="small">${esc(t.details || "Genauer ansehen")}</summary>
        <h4 style="margin:.8rem 0 .3rem">${icon("file-text", 15)} ${esc(t.what_heading || "Was gesendet wird")}</h4><ul class="small">${li(t.what)}</ul>
        <p class="small muted">${esc(t.never || "")}</p>
        <h4 style="margin:.8rem 0 .3rem">${icon("share", 15)} ${esc(t.where_heading || "Wohin es geht")}</h4><p class="small">${esc(t.service || "")}</p><ul class="small">${li(t.recipients)}</ul>
        <p class="small muted">${esc(t.processors || "")}</p>
        <p class="small muted">${esc(t.revoke || "")}</p>
        </details>
        <p class="small"><a href="${esc(t.privacy_url || "https://studinow.app/datenschutz")}" target="_blank" rel="noopener">${esc(t.privacy_link || "Datenschutzerklärung")}</a></p>
      </div>
      <div class="modal-foot"><button class="btn" data-consent="no">${esc(t.cancel || "Abbrechen")}</button><button class="btn primary" data-consent="yes">${icon("check", 14)} ${esc(t.accept || "Okay, los")}</button></div>`);
    m.setAttribute("aria-label", t.title || "KI-Hilfe: Was wird gesendet?");
    let done = false;
    const finish = ok => { if (done) return; done = true; obs.disconnect(); m.remove(); resolve(ok); };
    m.querySelector('[data-consent="yes"]').onclick = () => finish(true);
    m.querySelector('[data-consent="no"]').onclick = () => finish(false);
    // Klick daneben oder Escape entfernt das Fenster: gilt als Abbrechen
    const obs = new MutationObserver(() => { if (!m.isConnected) finish(false); });
    obs.observe(m.parentNode || document.body, { childList: true });
  });
}

/** Einmal beim Start (app.js): window.fetch mit Einwilligung */
export function installConsentFetch(win = window) {
  if (installed) return;
  installed = true;
  const raw = win.fetch.bind(win);
  win.fetch = withConsent(raw, {
    ask: askConsent,
    grant: async version => {
      const r = await raw("/api/ai/consent", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ version }) });
      if (!r.ok) throw new Error("Einwilligung nicht gespeichert");
    },
  });
}

/** Karte in Einstellungen → Erweitert: Stand und "KI-Einwilligung widerrufen" */
export function consentCardHtml(c) {
  if (!c) return "";
  const when = c.granted_at ? new Date(c.granted_at).toLocaleDateString("de-DE", { day: "numeric", month: "long", year: "numeric" }) : "";
  const text = c.granted
    ? `Erteilt am ${esc(when)}: Seitentext, Bereich und Frage gehen über den StudiNow-Dienst an OpenAI bzw. Claude (Amazon Bedrock, Frankfurt).`
    : "Noch nicht erteilt. Vor der ersten Anfrage an die StudiNow-KI fragt StudiNow, ob Seitentext und Frage an den KI-Anbieter gehen dürfen.";
  return `<div class="card" id="aiConsentCard"><div class="card-head"><h2>${icon("sparkles", 18)} KI-Einwilligung</h2><span class="badge ${c.granted ? "ok" : "neutral"}">${c.granted ? "erteilt" : "nicht erteilt"}</span></div>
    <p class="small muted">${text} <a href="${esc(c.text?.privacy_url || "https://studinow.app/datenschutz")}" target="_blank" rel="noopener">Datenschutzerklärung</a></p>
    ${c.granted ? `<div class="row wrap"><button class="btn sm" id="aiConsentRevoke">${icon("x", 14)} ${esc(c.text?.revoke_button || "KI-Einwilligung widerrufen")}</button></div>` : ""}</div>`;
}

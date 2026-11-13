// Einwilligung vor der StudiNow-KI (06.11.2026, App Store 5.1.2(i) wie auf dem iPad; Server: app/ai_consent.py).
// Der Server schickt ohne Einwilligung nichts an einen KI-Anbieter und antwortet 428 `ai_consent_required` mit den
// Texten des Hinweises. Diese Hilfe um `fetch` faengt das an EINER Stelle fuer alle KI-Stellen ab (KI-Hilfe, ganzes
// Dokument, Karteikarten, Wochentests …): Hinweis zeigen (`ask`), bei "Okay, los" speichern (`grant`,
// POST /api/ai/consent) und die Anfrage einmal wiederholen; bei "Abbrechen" bleibt eine 428-Antwort mit DECLINED.
// Gleichzeitige Anfragen teilen sich einen Hinweis. Ohne DOM, damit node --test es pruefen kann (tests/js/ai-consent.test.mjs).

export const CONSENT_CODE = "ai_consent_required";
export const DECLINED = "Ohne deine Zustimmung sendet StudiNow nichts an die KI. Beim nächsten Versuch fragen wir dich erneut.";

/** Ist das die Antwort "Einwilligung fehlt"? (Status und gelesener Rumpf; FastAPI legt den Code oben oder in `detail` ab) */
export function needsConsent(status, body) {
  if (status !== 428 || !body || typeof body !== "object") return false;
  return body.code === CONSENT_CODE || body.detail?.code === CONSENT_CODE;
}

/** Felder des Hinweises aus der 428-Antwort: {version, text} */
export function consentInfo(body) {
  const d = body?.detail && typeof body.detail === "object" ? { ...body.detail, ...body } : body || {};
  return { version: d.version ?? null, text: d.consent ?? null };
}

/** Antwort nach "Abbrechen": 428 mit verstaendlichem Text, damit die KI-Stelle ihn wie jeden Fehler zeigt */
export function declinedResponse() {
  return new Response(JSON.stringify({ detail: DECLINED, code: CONSENT_CODE }), { status: 428, headers: { "Content-Type": "application/json" } });
}

/**
 * fetch mit Einwilligung. `ask(info)` -> Promise<boolean> (Hinweis zeigen), `grant(version)` -> Promise (speichern).
 * Wiederholt die urspruengliche Anfrage hoechstens einmal.
 */
export function withConsent(fetchFn, { ask, grant }) {
  let pending = null;
  return async function consentFetch(input, init) {
    const r = await fetchFn(input, init);
    if (r.status !== 428) return r;
    let body = null;
    try { body = await r.clone().json(); } catch { return r; }
    if (!needsConsent(r.status, body)) return r;
    const info = consentInfo(body);
    if (!pending) {
      pending = (async () => {
        try {
          if (!(await ask(info))) return false;
          await grant(info.version);
          return true;
        } catch { return false; }
      })();
      pending.finally(() => { pending = null; });
    }
    const ok = await pending;
    return ok ? fetchFn(input, init) : declinedResponse();
  };
}

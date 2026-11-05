// Fehlercodes des StudiNow-Dienstes -> verstaendlicher deutscher Text (EINE Stelle, 03.11.2026).
// Dieselben Texte wie ServiceErrorText.swift auf dem iPad (apps/apple/Packages/UniFlowCore/.../ServiceErrorText.swift,
// geprueft in tests/js/service-errors.test.mjs gegen die Erwartungen aus ServiceErrorTextTests.swift). Unbekannte Codes
// behalten die Meldung des Dienstes ({detail, code}, Vertrag G1/G4).
// Reines Modul ohne Browserzugriff: core.js (api), views-qa.js und editor-community.js (capi) bauen ihre Fehler damit.

/** Meldungen je Konto und Tag (rules.limits.report_user im Kontovertrag, packages/shared-contracts/fixtures/account) */
export const REPORTS_PER_DAY = 10;

const KNOWN = {
  email_unverified: "Bestätige zuerst deine E-Mail-Adresse. Den Link findest du in der Willkommensmail; unter Einstellungen → StudiNow-Konto kannst du ihn erneut anfordern.",
  duplicate_request: "Diese Anfrage wurde schon verarbeitet und nicht noch einmal berechnet. Starte sie bei Bedarf neu.",
  ai_trial_budget_exhausted: "Das Kontingent der StudiNow-KI für Probekonten ist in diesem Monat aufgebraucht. Ab dem nächsten Monat geht es weiter.",
  ai_not_configured_prices: "Die StudiNow-KI ist im Dienst noch nicht freigeschaltet. Bitte versuche es später erneut.",
  email_taken: "Für diese E-Mail-Adresse gibt es schon ein StudiNow-Konto. Melde dich dort mit E-Mail und Passwort an und bestätige die Adresse; danach lässt sich die Anmeldung verknüpfen.",
  last_login_method: "Das ist der einzige Anmeldeweg deines Kontos. Lege zuerst ein Passwort fest oder verknüpfe einen anderen Weg, dann kannst du diesen entfernen.",
  subscription_owned_by_other_account: "Dieses App-Store-Abo ist schon mit einem anderen StudiNow-Konto verbunden. Melde dich mit jenem Konto an, dann gilt es auch für die StudiNow-KI.",
  apple_not_configured: "Der StudiNow-Dienst kann App-Store-Käufe gerade noch nicht prüfen. Dein Abo gilt auf dem iPad trotzdem; bitte versuche es später erneut.",
  provider_not_configured: "„Mit Apple anmelden“ ist beim StudiNow-Dienst noch nicht eingerichtet. Melde dich vorerst mit E-Mail und Passwort an.",
  cross_site: "Die Anfrage wurde aus Sicherheitsgründen abgelehnt, weil sie nicht direkt aus StudiNow kam. Starte sie bitte in der App oder auf der StudiNow-Webseite selbst.",
};

/** Eigener Text fuer einen bekannten Code; null = Meldung des Dienstes zeigen */
export const known = code => (Object.prototype.hasOwnProperty.call(KNOWN, code) ? KNOWN[code] : null);

/** Handlung zur Meldung: "verifyEmail" (Bestaetigungslink erneut senden), "accountSettings" (Konto oeffnen) oder null */
export function action(code) {
  if (code === "email_unverified") return "verifyEmail";
  if (code === "last_login_method" || code === "email_taken") return "accountSettings";
  return null;
}

/** Beschriftung des Knopfs zur Handlung */
export const ACTION_LABEL = { verifyEmail: "Bestätigungslink erneut senden", accountSettings: "Konto öffnen" };

/** Zusatz "in N min erneut versuchen" aus Retry-After (Sekunden); ab 2 Stunden in Stunden (Tagesgrenzen) */
export function retryHint(retryAfter) {
  const s = Number(retryAfter);
  if (!Number.isFinite(s) || s <= 0) return null;
  const minutes = Math.max(1, Math.floor(s / 60));
  if (minutes >= 120) return `in etwa ${Math.floor((minutes + 30) / 60)} Std. erneut versuchen`;
  return `in ${minutes} min erneut versuchen`;
}

const withHint = (base, retryAfter) => { const h = retryHint(retryAfter); return h ? `${base} (${h})` : base; };

/** Text fuer die Oberflaeche: eigener Text fuer bekannte Codes, sonst die Meldung des Dienstes; mit Retry-After
    der Hinweis, wann es wieder geht */
export const text = (code, serverMessage, retryAfter) => withHint(known(code) || serverMessage, retryAfter);

/** Grenze report_user erreicht (Dienst: 429 rate_limited beim Melden) */
export const reportLimit = retryAfter => withHint(`Du hast heute schon ${REPORTS_PER_DAY} Meldungen abgegeben, mehr sind pro Tag nicht möglich.`, retryAfter);

/** Rueckmeldung nach "Bestaetigungslink erneut senden" (POST .../verify-email/resend) */
export const resendNote = r => (r && r.already ? "Deine E-Mail-Adresse ist schon bestätigt." : (r && r.message) || "Wir haben dir einen neuen Bestätigungslink geschickt.");

/**
 * Fehler aus der Antwort des Dienstes (oder des lokalen Servers, der sie durchreicht).
 * data = JSON der Antwort ({detail, code}; detail darf auch ein Objekt mit eigenem code sein), retryAfter = Kopfzeile
 * Retry-After in Sekunden, report = die Anfrage war eine Meldung (dann ist 429 rate_limited die Tagesgrenze).
 * Der Error traegt message (Text fuer die Oberflaeche), code, status, retryAfter, action und serviceMessage.
 */
export function serviceError(status, data, { retryAfter, report = false, fallback } = {}) {
  const d = data && typeof data === "object" ? data : {};
  const inner = d.detail && typeof d.detail === "object" ? d.detail : null;
  const code = String(d.code || inner?.code || "");
  const raw = inner ? inner.detail || inner.message : d.detail;
  const message = typeof raw === "string" && raw ? raw : (fallback || `Fehler ${status}`);
  const retry = Number.isFinite(Number(retryAfter)) && Number(retryAfter) > 0 ? Number(retryAfter) : null;
  const shown = report && code === "rate_limited" ? reportLimit(retry) : text(code, message, retry);
  const e = new Error(shown);
  Object.assign(e, { code: code || undefined, status, retryAfter: retry, action: action(code), serviceMessage: message });
  return e;
}

/** Fehler aus einer fetch-Antwort (r.ok ist false); liest den Koerper und Retry-After selbst */
export async function responseError(r, opts = {}) {
  let data = null;
  try { data = await r.json(); } catch {}
  const retryAfter = parseInt(r.headers?.get?.("Retry-After") ?? "", 10);
  return serviceError(r.status, data, { ...opts, retryAfter, fallback: opts.fallback || r.statusText || undefined });
}

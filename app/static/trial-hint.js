// Probe des StudiNow-Kontos auf der Uebersicht (Dienst): "noch N Tage alles frei", danach die Aufforderung zur Tarifwahl
// mit "Tarife ansehen" und "Bei Free bleiben" (wie TrialBanner.swift auf dem iPad, 8b715df; die Texte stammen von hier,
// views-abo.js). Reines Modul fuer tests/js/trial-hint.test.mjs; app.js reicht das Ergebnis an die Uebersicht weiter und
// bedient "Bei Free bleiben" (Klick auf #trialFree).

export const TRIAL_TEXTS = {
  over: "Deine Probe ist vorbei",
  overText: "Sieben Tage lang war alles frei. Wähle jetzt einen Tarif oder bleib bei Free. Deine Notizen bleiben in jedem Fall erhalten und lesbar.",
  plans: "Tarife ansehen",
  stayFree: "Bei Free bleiben",
};

/** "Probe: noch N Tage alles frei" */
export const trialTitle = days => `Probe: noch ${days} ${days === 1 ? "Tag" : "Tage"} alles frei`;

/**
 * HTML der Hinweiskarte. ent = Antwort von GET /api/entitlements ({trial: {granted, active, days_left, ends_at},
 * needs_plan_choice}); hosted = Dienst (auf dem eigenen PC gibt es keine Tarife, alles ist frei). Leer, wenn es nichts
 * zu sagen gibt.
 */
export function trialHintHtml(ent, hosted, icon, esc) {
  const tr = ent?.trial;
  if (!hosted || !tr?.granted) return "";
  if (tr.active) {
    const ends = tr.ends_at ? new Date(tr.ends_at).toLocaleDateString("de-DE") : "";
    return `<div class="card pwa-hint"><div class="row wrap" style="align-items:center;gap:.6rem">${icon("sparkles", 18)}<div style="flex:1"><b>${esc(trialTitle(tr.days_left))}</b>`
      + `<div class="small muted">${ends ? `Bis ${esc(ends)} hast du alle Funktionen. ` : ""}Danach wählst du einen Tarif; ohne Wahl geht es mit Free weiter, deine Notizen bleiben.</div></div>`
      + `<a class="btn sm" href="#/abo">${esc(TRIAL_TEXTS.plans)}</a></div></div>`;
  }
  if (ent?.needs_plan_choice) {
    return `<div class="card pwa-hint" style="border-color:var(--warn)"><div class="row wrap" style="align-items:center;gap:.6rem">${icon("alert", 18)}<div style="flex:1"><b>${esc(TRIAL_TEXTS.over)}</b>`
      + `<div class="small muted">${esc(TRIAL_TEXTS.overText)}</div></div>`
      + `<a class="btn primary sm" href="#/abo">${esc(TRIAL_TEXTS.plans)}</a><button type="button" class="btn sm" id="trialFree">${esc(TRIAL_TEXTS.stayFree)}</button></div></div>`;
  }
  return "";
}

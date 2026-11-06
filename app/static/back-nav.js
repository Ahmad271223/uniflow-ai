// Zurueck-Pfeil oben links auf jeder Seite ausser der Startseite (Wunsch des Inhabers 06.11.2026, wie auf dem iPad).
// Ohne Browser testbar (tests/js/back-nav.test.mjs): die App merkt sich die in dieser Sitzung besuchten Seiten. Gibt es
// eine vorige Seite in der App, geht der Pfeil mit history.back() dorthin (wie der Zurueck-Knopf des Browsers), sonst
// zur Startseite (#/) bzw. zum mitgegebenen Ziel (Dokument: Modul oder Dokumente). Ein Zurueck innerhalb einer Seite
// (setLocal) kommt zuerst.

/** Startseite: leerer Hash, "#/", "#/dashboard" (auch mit Parametern) */
export function isHome(hash) {
  const name = String(hash || "").replace(/^#\/?/, "").split(/[?/]/)[0];
  return name === "" || name === "dashboard";
}

/** Normalform fuer den Vergleich: "#/plan?x=1" und "#plan?x=1" gleich, Start immer "#/dashboard" */
export function norm(hash) {
  const h = String(hash || "").replace(/^#\/?/, "");
  return isHome("#/" + h) && !h.includes("?") ? "#/dashboard" : "#/" + h;
}

/**
 * Verlauf der App. `visit(hash)` bei jedem Seitenwechsel (hashchange): war es die vorige Seite, ging der Nutzer
 * zurueck (Browser-Pfeil oder unser Pfeil), sonst ist es eine neue Seite. `back(fallback)` liefert, was zu tun ist:
 * { local } (Zurueck der Seite), { history: true } (history.back()) oder { hash } (Startseite oder Ziel).
 */
export function createBackNav() {
  let stack = [];
  let local = null;
  return {
    visit(hash) {
      const h = norm(hash);
      local = null;
      if (stack.length && stack[stack.length - 1] === h) return;
      if (stack.length > 1 && stack[stack.length - 2] === h) { stack.pop(); return; }
      stack.push(h);
      if (stack.length > 50) stack = stack.slice(-50);
    },
    get depth() { return stack.length; },
    canGoBack() { return stack.length > 1; },
    setLocal(fn) { local = typeof fn === "function" ? fn : null; },
    back(fallback = "#/") {
      if (local) { const fn = local; local = null; return { local: fn }; }
      if (stack.length > 1) return { history: true };
      return { hash: fallback };
    },
  };
}

/** Knopf in der Kopfzeile: Chevron und "Zurück" (schmal nur der Chevron, per CSS), VoiceOver/Screenreader "Zurück" */
export function backButtonHtml(icon) {
  return `${icon("chevron-left", 18)}<span class="back-label">Zurück</span>`;
}

/** Pfeil sichtbar? Nur ausserhalb der Startseite */
export function showsBack(hash) { return !isHome(hash); }

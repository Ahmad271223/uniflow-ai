// Lernstand je Modul (docs/LERNSTAND-2026-11-04.md): Beschriftung des Felds `mastery` aus GET /api/modules und
// /api/modules/{id} ({score, reason, tests, cards, tasks_done, tasks_total} oder null). Gerechnet wird nur im Backend
// (app/mastery.py, gleiche Zahl wie auf dem iPad); hier nur Text und ein kleiner Ring in der bestehenden Optik.
// Dieselben Texte wie LernstandText in der iPad-App (packages/shared-contracts/fixtures/mastery/cases.json).
// kein Import aus core.js (braucht das DOM): so laeuft die Datei auch unter node (tests/js/mastery.test.mjs)
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const HINT = "Steigt mit Wochentests, bewerteten Karteikarten und erledigten Aufgaben.";

/// "Lernstand 64 %" (geschuetztes Leerzeichen vor dem Prozent) oder "noch kein Lernstand"
export function masteryLabel(m) {
  return m && Number.isFinite(m.score) ? `Lernstand ${Math.round(m.score)} %` : "noch kein Lernstand";
}

/// Unterzeile: die Begruendung ("3 Wochentests, 42 Karten, 12 von 20 Aufgaben"), ohne Lernstand der Hinweis, was ihn hebt
export function masterySub(m) {
  return m && Number.isFinite(m.score) ? (m.reason || "") : HINT;
}

/// Ein Satz fuer Vorlesehilfen: "Lernstand 64 Prozent, 3 Wochentests, …" bzw. "noch kein Lernstand, steigt mit …"
export function masteryAria(m) {
  const sub = masterySub(m);
  return (m && Number.isFinite(m.score) ? `Lernstand ${Math.round(m.score)} Prozent` : "noch kein Lernstand") + (sub ? `, ${sub}` : "");
}

/// Ring mit Zahl und Text: <span class="mastery [none]"><i class="ring" style="--p:64"></i><b>Lernstand 64 %</b><small>…</small></span>
/// `size`: "sm" (Uebersicht, Modulliste: nur Ring und Zahl, die Begruendung als title) oder "md" (Modulkarte, Modulseite)
export function masteryHtml(m, size = "md") {
  const has = !!(m && Number.isFinite(m.score)), p = has ? Math.max(0, Math.min(100, Math.round(m.score))) : 0;
  const label = masteryLabel(m), sub = masterySub(m);
  return `<span class="mastery ${size}${has ? "" : " none"}" role="img" aria-label="${esc(masteryAria(m))}" title="${esc(sub)}"><i class="ring" style="--p:${p}"></i><span class="t"><b>${esc(label)}</b>${size === "md" ? `<small>${esc(sub)}</small>` : ""}</span></span>`;
}

const STAR = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m12 2 3.1 6.3 6.9 1-5 4.9 1.2 6.8L12 17.8 5.8 21l1.2-6.8-5-4.9 6.9-1z"/></svg>`;

/// Zahl im Ring der Kachel: "64 %" bzw. "–" ohne Lernstand
export function masteryRingText(m) {
  return m && Number.isFinite(m.score) ? `${Math.max(0, Math.min(100, Math.round(m.score)))} %` : "–";
}

/// Lernstand-Kachel wie auf dem iPad (UFComponents LernstandTile, 04.11.2026): Stern in Modulfarbe, "Lernstand" bzw.
/// "noch kein Lernstand", darunter die Begruendung, rechts der Ring mit der Zahl. Farbe ueber --mc des Elternelements.
/// `size`: "md" (Modulkarte, Uebersicht) oder "lg" (Modulseite)
export function masteryTile(m, size = "md") {
  const has = !!(m && Number.isFinite(m.score)), p = has ? Math.max(0, Math.min(100, Math.round(m.score))) : 0;
  return `<div class="ls-tile ${size}${has ? "" : " none"}" role="img" aria-label="${esc(masteryAria(m))}">`
    + `<span class="ls-star" aria-hidden="true">${STAR}</span>`
    + `<span class="ls-t" aria-hidden="true"><b>${has ? "Lernstand" : "noch kein Lernstand"}</b><small>${esc(masterySub(m))}</small></span>`
    + `<span class="ls-ring" style="--p:${p}" aria-hidden="true"><i></i><b>${esc(masteryRingText(m))}</b></span></div>`;
}

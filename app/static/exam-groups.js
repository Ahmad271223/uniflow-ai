// Block "Klausuren & Altklausuren" geordnet (Wunsch des Inhabers 17.11.2026: zu jeder Klausur genau ihre Loesung, wie
// ModuleExamGroups.swift auf dem iPad): nach Jahrgang, neuester zuerst; jede Klausur mit ihrer Loesung direkt darunter
// (eingerueckt), Sammel-Loesungen und Loesungen ohne erkannte Klausur am Ende des Jahrgangs. Die Ordnung kommt fertig
// vom Server (`exam_groups` im Moduldetail, app/exam_pairs.py); hier wird nur gezeichnet. Reine Texte und HTML-Teile
// ohne Browserzugriff (tests/js/exam-groups.test.mjs); angeschlossen in views-misc.js (viewModule).

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Gruppen nach Art, die diese Ansicht im Block ersetzt */
export const COVERED = ["klausuren", "loesungen"];

/** Gruppen nach Jahrgang eines Wochenblocks; leer bei allen anderen Wochen und ohne die Ordnung vom Server */
export const groupsOf = w => (w && w.week === -2 ? (w.exam_groups || []).filter(g => (g.files || []).length) : []);

/** Steht die Datei als Loesung direkt unter ihrer Klausur? */
export const isPaired = f => f?.exam_role === "loesung";

/** "2 Klausuren, 1 Lösung" hinter dem Jahrgang */
export function summary(files) {
  const exams = (files || []).filter(f => f.exam_role === "klausur").length, sols = (files || []).length - exams;
  return [exams ? (exams === 1 ? "1 Klausur" : `${exams} Klausuren`) : "", sols ? (sols === 1 ? "1 Lösung" : `${sols} Lösungen`) : ""].filter(Boolean).join(", ");
}

/** HTML der Gruppen; `row(f)` zeichnet eine Dateizeile (in views-misc.js mit dem Haken "erledigt") */
export function html(groups, row) {
  return (groups || []).map(g => `<h4 style="margin:.5rem 0 .2rem">${esc(g.label)} <span class="muted" style="font-weight:400">· ${esc(summary(g.files))}</span></h4>`
    + g.files.map(f => isPaired(f)
      ? `<div class="exam-pair" style="display:flex;align-items:center;gap:.1rem" title="Lösung zur Klausur darüber"><span class="muted" aria-hidden="true" style="flex:0 0 1.4rem;text-align:center">↳</span><div style="flex:1;min-width:0">${row(f)}</div></div>`
      : row(f)).join("")).join("");
}

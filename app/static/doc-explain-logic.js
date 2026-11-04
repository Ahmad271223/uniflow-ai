// KI-Tutor fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md): Umfang, Schnellknoepfe, Lauf
// Teil fuer Teil und die Bloecke mit Seiten als Link. Regeln ohne Browser (tests/js/doc-explain.test.mjs); der Dienst
// (app/doc_explain_api.py) plant, erkennt die Absicht in der Frage und rechnet die Kosten. Eingebunden von editor.js.

export const SCOPES = [["page", "Diese Seite"], ["all", "Ganzes Dokument"], ["range", "Seiten …"]];
export const CHIPS = [["lecture", "Ganze Vorlesung erklären"], ["tasks", "Alle Aufgaben erklären"]];
// Modi des Tutors, die bei Umfang "Ganzes Dokument"/"Seiten" einen Lauf starten (wie TutorDocRun.docMode auf dem iPad)
const LECTURE_MODES = new Set(["explain", "explain_simple", "summary", "terms"]);
const TASK_MODES = new Set(["steps", "hints"]);

/** `scope` fuer den Dienst aus der Auswahl (Seiten in beliebiger Reihenfolge) */
export function scopeBody(kind, from, to) {
  if (kind === "all") return { kind: "all" };
  if (kind === "range") {
    const a = Math.max(1, parseInt(from, 10) || 1), b = Math.max(1, parseInt(to, 10) || a);
    return { kind: "range", from: Math.min(a, b), to: Math.max(a, b) };
  }
  return { kind: "page" };
}

/** Lauf fuer einen Modus des Tutors bei diesem Umfang: "lecture" | "tasks" | null (wie bisher fuer die Seite) */
export function docModeFor(mode, scopeKind) {
  if (scopeKind === "page") return null;
  if (LECTURE_MODES.has(mode)) return "lecture";
  if (TASK_MODES.has(mode)) return "tasks";
  return null;
}

/** "S. 5" bzw. "S. 5–7" (wie doc_explain.pages_label) */
export const pagesLabel = (a, b) => (a === b ? `S. ${a}` : `S. ${a}–${b}`);

/** "Teil 2 von 4 · Seiten 16–30" */
export const progressText = (done, total, title) => `Teil ${Math.min(done + 1, total)} von ${total} · ${title || ""}`;

/** Herkunft unter dem Ergebnis; null ohne schon Erklaertes */
export function storedNote(cached, total) {
  if (!total || !cached) return null;
  return cached === total ? "Schon erklärt · 0 Credits" : `${cached} von ${total} Teilen schon erklärt · 0 Credits`;
}

/** Vorher fragen? Der Dienst sagt es (`confirm`, mehr als 3 Credits) oder es reicht nicht (`enough: false`) */
export const needsConfirm = plan => !!plan && (plan.confirm === true || plan.enough === false);

/** Ein Block als HTML: Titel, Seiten als Link (data-page = erste Seite), Text ueber `md` */
export function blockHtml(b, esc, md) {
  const cls = b.kind === "overview" ? "ed-doc-block ed-doc-overview" : "ed-doc-block";
  return `<section class="${cls}"><div class="ed-doc-head"><b>${esc(b.title)}</b> <a href="#" class="ed-doc-page" data-page="${Number(b.from) || 1}">${esc(pagesLabel(b.from, b.to))}</a></div>${md(b.text || "")}</section>`;
}

/** Body eines Schritts: Anfrage des Plans + Schritt + eigene request_id */
export function stepBody(base, step, requestId, force = false) {
  const b = { ...base, step: step.id, request_id: requestId };
  if (force) b.force = true;
  return b;
}

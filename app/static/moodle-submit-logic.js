// "In Moodle abgeben" bzw. "In Learnweb abgeben" aus dem Web-Editor (Windows/Einzelplatz, HsH und Uni Hildesheim,
// 05.11.2026): reine Regeln und Texte ohne DOM (laeuft unter node, tests/js/moodle-submit.test.mjs). Gleiche Texte wie
// MoodleSubmitSheet in apps/apple/UniFlow/Views/MoodleViews.swift; Abruf, Entwurf und Abgabe macht app/moodle_api.py.
// Abgegeben ist erst mit "Jetzt abgeben"; "Als Entwurf hochladen" legt die PDF nur in den Entwurf.
import { esc, finalFileName } from "./studip-submit-logic.js?v=1";

export { esc, finalFileName };

export const texts = (source = "Moodle") => ({
  title: `In ${source} abgeben`,
  notice: `Erst „Als Entwurf hochladen“ legt die PDF in deiner Abgabe ab. Abgegeben ist sie erst mit „Jetzt abgeben“ – das lässt sich in ${source} oft nicht zurücknehmen.`,
  notTested: `Mit einem echten ${source}-Konto noch nicht geprüft. Kontrolliere die Abgabe danach in ${source}.`,
  empty: `Keine ${source}-Aufgabe mit Abgabe gefunden. Aufgaben kommen mit den Fristen beim Abgleich.`,
  notAvailable: `Abgeben in ${source} gibt es nur in der Windows-App. Exportiere die PDF und lade sie im Browser hoch.`,
  notConnected: `${source} ist nicht verbunden.`,
  login: "Bei der Hochschule anmelden",
  assignment: "Aufgabe",
  state: `Stand in ${source}`,
  fileName: "Dateiname",
  withNotes: "Notizen und Blätter mitschicken",
  draft: "Als Entwurf hochladen",
  submit: "Jetzt abgeben",
  open: `In ${source} öffnen`,
  feedback: `Feedback vorhanden – in ${source} ansehen.`,
  history: "Bisher",
  building: "PDF wird erstellt …",
  loading: `Stand wird aus ${source} gelesen …`,
});

/** Faelligkeit "2026-11-12T23:59" -> "12.11.2026, 23:59" */
export function dueText(v) {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(String(v || ""));
  return m ? `${m[3]}.${m[2]}.${m[1]}${m[4] ? `, ${m[4]}:${m[5]}` : ""}` : String(v || "");
}

/** Auswahl der Aufgaben: "Übungsblatt 3 · Programmieren 1 · fällig 12.11.2026, 23:59" */
export function assignmentOptions(list, selected) {
  return `<option value="">Aufgabe wählen …</option>` + (list || []).map(a =>
    `<option value="${esc(a.cmid)}"${String(a.cmid) === String(selected ?? "") ? " selected" : ""}>${esc([a.title, a.course, a.due_at ? `fällig ${dueText(a.due_at)}` : ""].filter(Boolean).join(" · "))}</option>`).join("");
}

/** Stand als Zeilen (Abgabestatus, Bewertungsstatus, Versuch) */
export function statusHtml(s, t = texts()) {
  if (!s) return "";
  const rows = [["Abgabestatus", s.state], ["Bewertungsstatus", s.grading], ["Versuch", s.attempt]].filter(r => r[1]);
  return `<dl class="sub-status">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>`
    + (s.has_feedback ? `<p class="small">${esc(t.feedback)}</p>` : "");
}

/** "Als Entwurf hochladen": nur mit Aufgabe, die sich bearbeiten laesst, Name und fertiger PDF */
export const canDraft = ({ status, name, pdf, busy }) => !busy && !!status?.can_edit && !!finalFileName(name) && !!pdf;

/** "Jetzt abgeben": erst nach dem Lesen der Bestaetigung; eine verlangte Erklaerung muss angehakt sein */
export const canSubmit = ({ confirm, accepted, busy, status }) =>
  !busy && !!confirm && status?.state !== "Abgegeben" && (confirm.statement == null || !!accepted);

/** Fehler mit Anmeldung als Ausweg */
export const needsLogin = code => code === "moodle_login";

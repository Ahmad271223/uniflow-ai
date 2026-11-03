// Fruehere Semester in der Bibliothek (03.11.2026, wie OlderSemestersViews.swift auf dem iPad): Der Abgleich laedt nur die
// Dateien des aktuellen Semesters. Nach dem ersten Abgleich, der Kurse frueherer Semester findet, fragt die App einmal
// "Auch frühere Semester laden?"; in der Bibliothek stehen die frueheren Semester als eigene, zugeklappte Ordner mit
// "Dateien laden" je Kurs und je Semester; unter Einstellungen → Module laesst sich die Wahl aendern.
// Daten: GET /api/older-semesters (app/older_semesters.py). Reine Texte und HTML-Teile ohne Browserzugriff
// (tests/js/older-semesters.test.mjs); Anbindung an Seite, Dialog und Abgleich: older-semesters-ui.js.
import { icon } from "./icons.js?v=31";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export const NOTE_QUEUED = "Vorgemerkt: Die Dateien kommen mit dem nächsten Abgleich.";
/** Hinweis unter "Dateien früherer Semester mitladen" (Einstellungen → Module) */
export const OLDER_FILES_HINT = "Aus: StudiNow lädt nur Dateien des aktuellen Semesters. Frühere Semester lädst du jederzeit in der Bibliothek, je Semester oder je Kurs.";

/** Frage zeigen? Nur ohne gespeicherte Wahl und mit mindestens einem Kurs eines frueheren Semesters */
export const shouldAsk = overview => !!overview && (overview.choice == null) && (overview.semesters || []).length > 0;

/** Anzahl der Kurse frueherer Semester */
export const courseCount = overview => (overview?.semesters || []).reduce((n, s) => n + (s.courses || []).length, 0);

/** Text der Frage "Auch frühere Semester laden?" */
export function questionText(current, courses) {
  return `StudiNow hat die Dateien deines aktuellen Semesters${current ? ` (${current})` : ""} geladen. `
    + `Dazu gibt es ${plural(courses, "Kurs", "Kurse")} aus früheren Semestern. `
    + "Du kannst ihre Dateien jederzeit später in der Bibliothek laden, je Semester oder je Kurs.";
}

/** Text zum Stand eines Kurses */
export function courseStatus(c) {
  const files = c.files || 0, done = c.downloaded || 0;
  if (c.requested) return "Vorgemerkt, kommt mit dem nächsten Abgleich";
  if (files === 0) return c.loaded ? "Keine Dateien" : "Dateien noch nicht geladen";
  if (done >= files) return `${plural(files, "Datei", "Dateien")} geladen`;
  if (done === 0) return `${plural(files, "Datei", "Dateien")} bekannt, nicht geladen`;
  return `${done} von ${files} Dateien geladen`;
}

/** Ist bei diesem Kurs noch etwas zu laden? (nie geladen oder nicht alle Dateien da) */
export const needsLoad = c => !c.loaded || (c.downloaded || 0) < (c.files || 0);

/** Pfad des Kursordners in der Bibliothek (#/files?path=c<Kurs-ID>) */
export const coursePath = id => "c" + id;
/** Kurs-ID aus einem Bibliothekspfad "c<Kurs-ID>"; null, wenn es keiner ist */
export const courseIdOf = seg => (/^c[A-Za-z0-9_-]+$/.test(seg || "") ? seg.slice(1) : null);
/** Gehoert der Kurs zu einem frueheren Semester? */
export const findCourse = (overview, id) => { for (const s of overview?.semesters || []) for (const c of s.courses || []) if (c.id === id) return c; return null; };

/** Ueberschrift des aktuellen Semesters ueber den Ordnern (nur wenn es fruehere gibt) */
export const currentHeading = overview => (overview && (overview.semesters || []).length ? "Aktuelles Semester" + (overview.current ? ` · ${overview.current}` : "") : "");

/**
 * Bereich "Frühere Semester" unter den Ordnern: je Semester ein zugeklappter Ordner mit seinen Kursen, "Alle laden" fuer
 * das ganze Semester, "Dateien laden" je Kurs. open = Menge aufgeklappter Semester, busy = Menge ladender Schluessel
 * (Semester-Name oder Kurs-ID).
 */
export function semestersHtml(overview, open = new Set(), busy = new Set()) {
  const semesters = overview?.semesters || [];
  if (!semesters.length) return "";
  const lead = overview.choice === "all"
    ? "StudiNow lädt die Dateien früherer Semester mit. Einzelne Kurse kannst du hier erneut laden."
    : "StudiNow lädt nur Dateien des aktuellen Semesters. Frühere Semester kannst du hier je Semester oder je Kurs laden.";
  const anyBusy = busy.size > 0;
  return `<section class="older-sem" aria-label="Frühere Semester"><h2>Frühere Semester</h2><p class="muted small">${esc(lead)}</p>${semesters.map((s, i) => {
    const courses = s.courses || [], isOpen = open.has(s.label);
    const files = courses.reduce((n, c) => n + (c.files || 0), 0), done = courses.reduce((n, c) => n + (c.downloaded || 0), 0);
    const todo = courses.filter(needsLoad).map(c => c.id);
    return `<div class="older-card"><div class="older-head">
        <button type="button" class="older-toggle" data-older-toggle="${i}" aria-expanded="${isOpen}" aria-label="${esc(s.label)}, ${isOpen ? "aufgeklappt" : "zugeklappt"}">
          ${icon(isOpen ? "chevron-down" : "chevron-right", 16)}<span class="older-ic">${icon("folder", 18)}</span>
          <span class="older-t"><b>${esc(s.label)}</b><span class="muted small">${plural(courses.length, "Kurs", "Kurse")}${files > 0 ? ` · ${done} von ${files} Dateien geladen` : ""}</span></span></button>
        ${todo.length ? `<button type="button" class="btn sm" data-older-all="${i}" ${anyBusy ? "disabled" : ""} aria-label="Dateien aller Kurse aus ${esc(s.label)} laden">${icon("download", 14)} ${busy.has(s.label) ? "Lädt …" : "Alle laden"}</button>` : ""}</div>
      ${isOpen ? `<div class="older-courses">${courses.map(c => courseRowHtml(c, busy, anyBusy)).join("")}</div>` : ""}</div>`;
  }).join("")}</section>`;
}

function courseRowHtml(c, busy, anyBusy) {
  const hasFiles = (c.files || 0) > 0;
  return `<div class="older-course"><${hasFiles ? `a href="#/files?path=${esc(coursePath(c.id))}"` : "div"} class="older-ct"><b>${esc(c.title)}</b><span class="muted small">${esc(courseStatus(c))}</span></${hasFiles ? "a" : "div"}>
    ${needsLoad(c) ? `<button type="button" class="btn sm" data-older-course="${esc(c.id)}" ${anyBusy ? "disabled" : ""} aria-label="Dateien von ${esc(c.title)} laden">${icon("download", 14)} ${busy.has(c.id) ? "Lädt …" : "Dateien laden"}</button>` : ""}</div>`;
}

/**
 * Kopf eines Kursordners aus einem frueheren Semester: Stand der Dateien, "Dateien laden" und die bekannten, noch nicht
 * geladenen Dateien (die geladenen stehen darunter wie in jedem Kursordner). files = Dateien des Kurses
 * (GET /api/older-semesters/courses/{id}/files).
 */
export function courseHeaderHtml(files, { loading = false, showAll = false } = {}) {
  const missing = files.filter(f => f.downloaded !== 1);
  const state = !files.length ? "Die Dateiliste ist noch nicht geladen."
    : missing.length === 0 ? `Alle ${files.length} Dateien sind geladen.`
    : `${files.length - missing.length} von ${files.length} Dateien geladen.`;
  const shown = showAll ? missing : missing.slice(0, 8);
  return `<div class="card older-head-card"><div class="row between wrap"><div><b>Kurs aus einem früheren Semester</b><div class="muted small">${esc(state)}</div></div>
    ${!files.length || missing.length ? `<button type="button" class="btn primary" data-older-load ${loading ? "disabled" : ""}>${icon("download", 15)} ${loading ? "Lädt …" : "Dateien laden"}</button>` : ""}</div>
    ${missing.length ? `<div class="older-missing">${shown.map(f => `<div class="older-file">${icon("file", 14)}<span>${esc(f.name || "")}</span></div>`).join("")}
      ${missing.length > 8 ? `<button type="button" class="btn ghost sm" data-older-more>${showAll ? "Weniger anzeigen" : `Alle ${missing.length} anzeigen`}</button>` : ""}</div>` : ""}</div>`;
}

/** Kontrollkaestchen "Dateien früherer Semester mitladen" (Einstellungen → Module); leer, wenn es nichts zu waehlen gibt */
export function settingHtml(overview) {
  if (!overview || (overview.choice == null && !(overview.semesters || []).length)) return "";
  return `<div style="margin:.4rem 0 .8rem"><label class="field" style="margin:0"><input type="checkbox" id="sOlderAll" ${overview.choice === "all" ? "checked" : ""}> Dateien früherer Semester mitladen</label>
    <div class="muted small" style="margin-top:.2rem">${esc(OLDER_FILES_HINT)}</div></div>`;
}

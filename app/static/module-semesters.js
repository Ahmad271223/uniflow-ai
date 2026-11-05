// Module je Semester (Wunsch des Inhabers 05.11.2026, wie ModulesPage.swift auf dem iPad): auf der Seite "Meine Module"
// steht das aktuelle Semester zuerst (aufgeklappt, die gewohnten Karten), dann das naechste, dann "Frühere Semester"
// je Semester zugeklappt mit Zahl der Module und Dateien – fuer alle Portale (Stud.IP, Moodle/Learnweb, HISinOne/LSF).
// Dazu der Hinweis aus dem Abgleich: "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)".
// Daten: GET /api/module-semesters und /api/sync-order (app/sync_order.py). Reine Texte und HTML-Teile ohne
// Browserzugriff (tests/js/module-semesters.test.mjs); angeschlossen in views-misc.js (viewModules).
import { icon } from "./icons.js?v=33";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

/** Hinweis zum Stand der Stufen (leer, wenn es nichts zu sagen gibt) */
export const hintText = status => (status && status.hint) || "";

/** Laeuft noch etwas, das die Seite neu zeichnen soll (aktuelles Semester oder fruehere im Hintergrund)? */
export const stillLoading = status => !!status && (!status.current?.ready || !!status.older?.running);

/** Hinweisleiste ueber den Modulen */
export function hintHtml(status) {
  const t = hintText(status);
  if (!t) return "";
  const busy = stillLoading(status);
  return `<div class="sem-hint" role="status" aria-live="polite">${icon(busy ? "refresh" : "clock", 15)}<span>${esc(t)}</span></div>`;
}

/** Zahlen eines Semesters: "3 Module · 12 Dateien" (geladen von bekannt, wenn noch nicht alles da ist) */
export function countLabel(g) {
  const n = g?.count ?? (g?.items || []).length, files = g?.files || 0, done = g?.downloaded || 0;
  let t = plural(n, "Modul", "Module");
  if (files > 0) t += done >= files ? ` · ${plural(files, "Datei", "Dateien")}` : ` · ${done} von ${files} Dateien geladen`;
  else if (!g?.loaded) t += " · Dateien noch nicht geladen";
  return t;
}

/**
 * Module auf die Abschnitte verteilen. mods = GET /api/modules, sem = GET /api/module-semesters (darf fehlen: dann
 * alles wie bisher im aktuellen Semester). Module, die keinem Semester zugeordnet sind (selbst angelegt), gehoeren
 * zum aktuellen.
 */
export function splitModules(mods, sem) {
  const list = Array.isArray(mods) ? mods : [];
  if (!sem) return { current: list, upcoming: [], older: [], label: "" };
  const byId = new Map(list.map(m => [m.id, m]));
  const elsewhere = new Set();
  const upcoming = (sem.upcoming || []).map(g => {
    (g.module_ids || []).forEach(id => elsewhere.add(id));
    return { ...g, mods: (g.module_ids || []).map(id => byId.get(id)).filter(Boolean) };
  });
  (sem.older || []).forEach(g => (g.items || []).forEach(it => { if (it.module_id != null) elsewhere.add(it.module_id); }));
  return { current: list.filter(m => !elsewhere.has(m.id)), upcoming, older: sem.older || [], label: sem.current?.label || "" };
}

/** Kopf des aktuellen Semesters (nur, wenn es andere Semester gibt) */
export function currentHeadHtml(split) {
  if (!split.label || (!split.upcoming.length && !split.older.length)) return "";
  return `<h2 class="sem-head">${esc("Aktuelles Semester · " + split.label)} <span class="muted small">${esc(plural(split.current.length, "Modul", "Module"))}</span></h2>`;
}

/** Ziel eines Eintrags: das Modul, sonst der Kursordner in der Bibliothek */
export const itemHref = it => (it.module_id != null ? `#/modules/${it.module_id}` : `#/files?path=c${encodeURIComponent((it.course_ids || [])[0] || "")}`);

function itemStatus(it) {
  const files = it.files || 0, done = it.downloaded || 0;
  const parts = [plural(it.courses || 0, "Veranstaltung", "Veranstaltungen")];
  if (files === 0) parts.push(it.loaded ? "keine Dateien" : "Dateien noch nicht geladen");
  else parts.push(done >= files ? plural(files, "Datei", "Dateien") : `${done} von ${files} Dateien geladen`);
  return parts.join(" · ");
}

/**
 * "Frühere Semester": je Semester ein zugeklappter Abschnitt mit Zahl der Module und Dateien; aufgeklappt die Module
 * (echte Module und erkannte Faecher aus Kursen ohne Modul). open = Menge aufgeklappter Semester (Beschriftung).
 */
export function olderHtml(older, open = new Set()) {
  if (!older || !older.length) return "";
  return `<section class="older-sem mod-older" aria-label="Frühere Semester"><h2>Frühere Semester</h2>${older.map((g, i) => {
    const isOpen = open.has(g.label);
    return `<div class="older-card"><div class="older-head">
        <button type="button" class="older-toggle" data-sem-toggle="${i}" aria-expanded="${isOpen}" aria-label="${esc(g.label)}, ${esc(countLabel(g))}, ${isOpen ? "aufgeklappt" : "zugeklappt"}">
          ${icon(isOpen ? "chevron-down" : "chevron-right", 16)}<span class="older-ic">${icon("book", 18)}</span>
          <span class="older-t"><b>${esc(g.label)}</b><span class="muted small">${esc(countLabel(g))}</span></span></button></div>
      ${isOpen ? `<div class="older-courses">${(g.items || []).map(it => `<div class="older-course"><a class="older-ct" href="${esc(itemHref(it))}"><b>${it.color ? `<span class="dot" style="background:${esc(it.color)}"></span> ` : ""}${esc(it.name)}</b><span class="muted small">${esc(itemStatus(it))}</span></a></div>`).join("")}</div>` : ""}</div>`;
  }).join("")}</section>`;
}

/** Abschnitt "Nächstes Semester" (Karten wie das aktuelle, cardFn = modCard) */
export function upcomingHtml(upcoming, cardFn) {
  return (upcoming || []).filter(g => (g.mods || []).length).map(g => `<h2 class="sem-head">${esc("Nächstes Semester · " + g.label)} <span class="muted small">${esc(plural(g.mods.length, "Modul", "Module"))}</span></h2><div class="mod2-grid">${g.mods.map(cardFn).join("")}</div>`).join("");
}

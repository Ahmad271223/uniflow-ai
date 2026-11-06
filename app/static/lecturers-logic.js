// Lehrende und Kontakte (LUH, Stud.IP) in Web und Windows (06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md): Regeln und
// HTML ohne DOM, unter node geprueft (tests/js/lecturers.test.mjs mit
// packages/shared-contracts/fixtures/studip-lecturers/lecturers.json). Daten liefert GET /api/lecturers (app/studip_lecturers.py);
// gleiche Texte wie LecturersViews.swift. Nur an der LUH; HsH und Hildesheim: Bereich unsichtbar (`shows`).

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const TEXTS = {
  title: "Lehrende",
  sub: "Lehrende und Tutor/innen deiner Kurse aus Stud.IP – mit E-Mail und Sprechstunde",
  search: "Suchen (Name oder Modul)",
  all: "Alle Lehrenden",
  studipMessage: "Nachricht in Stud.IP",
  office: "Sprechstunde",
  privacy: "Aus Stud.IP, so wie du es dort siehst. Die Angaben bleiben auf diesem PC.",
  notAvailable: "Lehrende mit E-Mail und Sprechstunde gibt es vorerst für die Leibniz Universität Hannover (Stud.IP).",
  noEmail: "Nachricht über Stud.IP",
  notice: "Wird über Stud.IP unter deinem Namen gesendet. Die Empfänger sehen deinen Namen.",
  fallback: "In Stud.IP schreiben",
};

/** Bereich zeigen? Nur verfuegbar (LUH, nicht im Dienst) und mit Eintraegen */
export const shows = d => !!(d && d.available && (d.people || []).length);

/** "Dozent/in · Funktion · Modul A, Modul B" (Module nur in der Gesamtliste) */
export function detail(p, showCourses = false) {
  const parts = [p.role_label || ""];
  if (p.label) parts.push(p.label);
  if (showCourses) {
    const names = [...new Set((p.courses || []).map(c => c.module_name || c.title).filter(Boolean))];
    if (names.length) parts.push(names.join(", "));
  }
  return parts.filter(Boolean).join(" · ");
}

export const officeLines = s => String(s || "").split("\n").map(x => x.trim()).filter(Boolean);

/** Betreff einer neuen Nachricht: "Frage zu Analysis I" */
export function subject(p, module) {
  if (module) return `Frage zu ${module}`;
  const c = (p.courses || [])[0];
  const n = c ? (c.module_name || c.title || "") : "";
  return n ? `Frage zu ${n}` : "";
}

/** E-Mail angeklickt: Uni-Mail (verbunden) oder mailto: */
export function mailAction(email, uniMailConnected) {
  const e = String(email || "").trim();
  if (!e) return null;
  return uniMailConnected ? { kind: "unimail", to: e } : { kind: "mailto", url: `mailto:${encodeURI(e)}` };
}

/** "3 Personen" bzw. "1 von 3 Personen" */
export function countLine(d) {
  const n = d.count || 0, total = d.total ?? n;
  return n === total ? `${n} ${n === 1 ? "Person" : "Personen"}` : `${n} von ${total} Personen`;
}

/** Bedienungshilfe der Zeile wie LecturersText.accessibility */
export function ariaLabel(p) {
  const parts = [p.name || "", p.role_label || "", p.email ? `E-Mail ${p.email}` : TEXTS.noEmail];
  const office = officeLines(p.office_hours).join(", ");
  if (office) parts.push(`${TEXTS.office} ${office}`);
  if (p.location) parts.push(/^raum\b/i.test(p.location) ? p.location : `Raum ${p.location}`);
  return parts.filter(Boolean).join(", ");
}

/** Nennt eine Zeile der Sprechstunde einen Raum ("F 303", "1101 - F102", "Gebäude 3403")? Zeiten bleiben Text */
export const namesRoom = t => /(?<![\p{L}\p{N}_.])[A-Z]{1,2}\s?\d{3}[A-Z]?(?![\p{L}\p{N}_.])|Geb(?:äude|\.)\s*\d{4}|(?<!\d)\d{4}\s*[-/]\s*[A-Z]/u.test(String(t || ""));

const roomButton = t => `<button type="button" class="room-link" data-room="${esc(t)}" aria-haspopup="dialog" aria-label="${esc(`Raum ${t}: Ort und Link zu Google Maps zeigen`)}">📍 <span>${esc(t)}</span></button>`;
const officeLine = t => namesRoom(t) ? roomButton(t) : `<span>${esc(t)}</span>`;

/** Eine Zeile; Raumangaben als .room-link (Raumfinder, app.js) */
export function rowHtml(p, showCourses = false) {
  const office = officeLines(p.office_hours);
  return `<div class="lec-row" data-id="${esc(p.id)}" role="group" aria-label="${esc(ariaLabel(p))}">
    <div class="lec-name"><b>${esc(p.name)}</b></div>
    ${detail(p, showCourses) ? `<div class="small muted">${esc(detail(p, showCourses))}</div>` : ""}
    ${p.email ? `<button class="lec-mail link" data-mail="${esc(p.email)}" aria-label="E-Mail an ${esc(p.email)}">✉ ${esc(p.email)}</button>`
              : `<div class="small muted lec-nomail">${esc(TEXTS.noEmail)}</div>`}
    ${office.length ? `<div class="small lec-office"><b>${esc(TEXTS.office)}</b><br>${office.map(officeLine).join("<br>")}</div>` : ""}
    ${p.location ? `<div class="small">${roomButton(p.location)}</div>` : ""}
    ${p.institute ? `<div class="small muted">${esc(p.institute)}</div>` : ""}
    <button class="btn sm lec-msg" data-msg="${esc(p.id)}">${esc(TEXTS.studipMessage)}</button>
  </div>`;
}

export const listHtml = (people, showCourses = false) => (people || []).map(p => rowHtml(p, showCourses)).join("");

// Kommende Klausuren (Auftrag des Inhabers 04.11.2026: Klausurtermine immer sichtbar): Karte "Nächste Klausuren" der
// Übersicht aus GET /api/exams/upcoming (app/exams.py; gleiche Liste wie auf dem iPad, Kern: Exams.swift). Je Klausur
// Tag, Countdown ("in 12 Tagen"), Modul, Uhrzeit und Raum, wenn bekannt, und die Quelle ("aus Stud.IP-Terminen",
// "aus Ankündigung vom …", "selbst eingetragen"). Ohne Klausuren keine Karte.
// kein Import aus core.js (braucht das DOM): so laeuft die Datei auch unter node (tests/js/exams.test.mjs)
import { roomLink, mayLink } from "./rooms-logic.js?v=1";   // Raumfinder (05.11.2026): Raum als Link zum Ort
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const WD = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];

export const LIMIT = 4;

/// "Fr., 12.02.2027"
export function examDate(isoDay) {
  const [y, m, d] = String(isoDay || "").split("-").map(Number);
  if (!y || !m || !d) return String(isoDay || "");
  const wd = WD[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  return `${wd}., ${String(d).padStart(2, "0")}.${String(m).padStart(2, "0")}.${y}`;
}

/// "heute", "morgen", "in 12 Tagen" (aus der Antwort, sonst aus days_left)
export function countdown(e) {
  if (e?.in_days) return e.in_days;
  const n = Number(e?.days_left) || 0;
  return n === 0 ? "heute" : n === 1 ? "morgen" : n > 1 ? `in ${n} Tagen` : `vor ${-n} Tagen`;
}

/// "09:00–11:00 Uhr · Hörsaal F 303" (nur was bekannt ist), sonst ""; `room: false` ohne Raum (steht dann als Link darunter)
export function placeText(e, room = true) {
  const parts = [];
  if (e?.time) parts.push(e.end ? `${e.time}–${e.end} Uhr` : `${e.time} Uhr`);
  if (room && e?.room) parts.push(e.room);
  return parts.join(" · ");
}

/// Link einer Zeile: Modul, sonst der Tag im Lernplan
export function examHref(e) {
  return Number.isInteger(e?.module_id) ? `#/modules/${e.module_id}` : `#/plan?view=day&date=${encodeURIComponent(e?.date || "")}`;
}

/// Karte "Nächste Klausuren" (HTML) oder "" ohne Klausuren; `iconHtml`: Symbol im Kopf (core.js icon())
export function examsCard(items, iconHtml = "", iconFn = () => "") {
  const list = Array.isArray(items) ? items.filter(e => e && e.date) : [];
  if (!list.length) return "";
  const rows = list.slice(0, LIMIT).map(e => {
    const link = !!e.room && mayLink(e.room);
    const place = placeText(e), shown = placeText(e, !link);
    const day = examDate(e.date);
    return `<a class="item ov-exam" href="${esc(examHref(e))}" aria-label="${esc([e.title, day, countdown(e), place, e.source_label].filter(Boolean).join(", "))}">`
      + `<span class="ov-exam-day" aria-hidden="true"><span>${esc(day.slice(0, 3))}</span><b>${esc(day.slice(5, 11))}</b></span>`
      + `<div class="main"><div class="title">${esc(e.title || "Klausur")}</div>`
      + (shown ? `<div class="sub">${esc(shown)}</div>` : "")
      + (e.source_label ? `<div class="sub ov-exam-src">${esc(e.source_label)}</div>` : "")
      + `</div><span class="badge ov-exam-in">${esc(countdown(e))}</span></a>`
      + (link ? `<div class="ov-exam-room">${roomLink(e.room, iconFn)}</div>` : "");
  }).join("");
  const more = list.length > LIMIT ? `<div class="ov-t2 small">und ${list.length - LIMIT} weitere</div>` : "";
  return `<section class="card ov-card ov-exams" aria-label="Nächste Klausuren"><div class="card-head"><h2>${iconHtml} Nächste Klausuren</h2></div>`
    + `<div class="list">${rows}</div>${more}</section>`;
}

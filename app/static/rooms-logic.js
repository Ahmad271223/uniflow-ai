// Raumfinder in Web und Windows (05.11.2026, docs/RAUMFINDER-2026-11-05.md): Regeln ohne DOM, unter node geprueft
// (tests/js/rooms.test.mjs mit packages/shared-contracts/fixtures/rooms/cases.json). Zerlegen und Aufloesen macht der
// Server (app/rooms.py, GET /api/rooms/resolve); hier nur: lohnt ein Link, welcher Kartenlink, Texte der Anzeige.
// An Google geht nichts von selbst: Links oeffnen sich erst beim Anklicken.

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** wie rooms.json "online_words" */
export const ONLINE_WORDS = ["online", "digital", "virtuell", "zoom", "webex", "bigbluebutton", "bbb", "meetings", "livestream", "stream", "teams"];
const WORD = "[\\p{L}\\p{N}_äöüß]";
const ROOM_CODE = /(?<![\p{L}\p{N}_.])[A-Z]{1,2}\s?\d{3}[A-Z]?(?![\p{L}\p{N}_.])/u;

/** Teile einer Raumangabe ("A · B", "A; B", "A | B", Zeilen), hoechstens vier (wie rooms.segments) */
export function segments(text) {
  return String(text ?? "").replace(/\r/g, "\n").split(/\s+·\s+|;|\s\|\s|\n/u)
    .map(s => s.split(/\s+/u).filter(Boolean).join(" ")).filter(Boolean).slice(0, 4);
}

/** nur "online", "Zoom" & Co. (ohne Raumnummer) */
export function isOnline(seg) {
  const low = String(seg ?? "").toLowerCase();
  return ONLINE_WORDS.some(w => new RegExp(`(?<!${WORD})${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?!${WORD})`, "u").test(low));
}

/** Link lohnt (nicht leer, nicht nur online); gleich in Rooms.mayLink (Swift) */
export const mayLink = text => segments(text).some(s => !isOnline(s) || ROOM_CODE.test(s));

export const resolvePath = text => `/rooms/resolve?text=${encodeURIComponent(String(text ?? ""))}`;
export const searchPath = (q, page = 0) => `/rooms/search?q=${encodeURIComponent(String(q ?? "").trim())}&page=${page}`;

/** Google Maps im Browser (am PC keine App), Route zu Fuss; Apple Karten daneben */
export function mapsUrl(maps, kind = "google") {
  const key = { google: "google", route: "google_route", apple: "apple" }[kind] || "google";
  const u = maps?.[key];
  return typeof u === "string" && u.startsWith("https://") ? u : null;
}

/** Raumangabe als Link (Klick oeffnet den Ort, rooms.js); sonst nur Text */
export function roomLink(text, icon = () => "") {
  const t = String(text ?? "").trim();
  if (!t) return "";
  if (!mayLink(t)) return `<span class="room-text">${esc(t)}</span>`;
  return `<button type="button" class="room-link" data-room="${esc(t)}" aria-haspopup="dialog" aria-label="${esc(`Raum ${t}: Ort und Link zu Google Maps zeigen`)}">${icon("map-pin", 13)}<span>${esc(t)}</span></button>`;
}

/** Zeilen "Angaben" eines Orts: [Bezeichnung, Wert] */
export function placeRows(p) {
  const rows = [];
  if (p?.building) rows.push(["Gebäude", p.building + (p.building_name ? ` (${p.building_name})` : "")]);
  if (p?.floor_label) rows.push(["Etage", p.floor_label + (p.floor ? ` (Etage ${p.floor})` : "")]);
  if (p?.room) rows.push(["Raum", p.room + (p.room_name ? ` – ${p.room_name}` : "")]);
  if (p?.address?.line) rows.push(["Adresse", p.address.line]);
  return rows;
}

/** Hinweis je aufgeloester Angabe */
export function statusText(part) {
  if (part?.status === "online") return "Online-Termin – kein Ort.";
  return ["offline", "not_found", "unknown", "ambiguous", "building", "campus", "search"].includes(part?.status) ? part.note || "" : "";
}

/** Barrierefreiheit als Zeilen "Titel (Status)" mit Text */
export function accessibilityRows(p) {
  const a = p?.accessibility || {};
  return [...(a.building || []), ...(a.room || [])].map(r => ({ title: r.status ? `${r.title} (${r.status})` : r.title, text: r.text || "" }));
}

/** Links zur Gebaeudeinfo der LUH (nur https) */
export function infoLinks(p) {
  return [["Raumplan ansehen", "floorplan_url"], ["Raum im Gebäudeinfo der LUH", "room_url"], ["Gebäudeinfo der LUH", "building_url"],
    ["Website", "website"], ["Öffnungszeiten", "opening_hours_url"]]
    .filter(([, k]) => typeof p?.[k] === "string" && p[k].startsWith("https://")).map(([label, k]) => ({ label, url: p[k] }));
}

export const countText = r => !r?.count ? `Keine Treffer für „${r?.query || ""}“.` : r.count === 1 ? "1 Treffer" : `${r.count} Treffer`;

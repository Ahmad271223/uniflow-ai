// Notizen und Blaetter mitschicken (wie SideNotes.swift auf dem iPad, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md), ohne DOM:
// - Seitennotiz: Leerseite im eigenen Dokument direkt hinter einer Folie ("Leere Seite danach").
// - Blatt daneben: eigenes Notizbuch, auf dem iPad in der geteilten Ansicht beschrieben. Das Hauptdokument merkt sich
//   im Wurzelfeld `sideSheets`, neben welcher eigenen Seite eine Blattseite beschrieben wurde (erste Seite gilt):
//   [{ file: "<Notizbuch>", pages: { "<Blattseite>": "<Seite im Dokument>" } }]. Der Browser schreibt das Feld nicht
//   (es gibt dort kein Blatt daneben), behaelt es aber (editor.js migrate) und schickt die Blaetter mit.
// Eingebunden von editor.js (PDF exportieren, exportPlan), editor-community.js (Loesung teilen), studip-submit.js
// ("In Stud.IP abgeben") und ai-panel.js (own_notes: loadSheets, interleaved, notePages); tests/js/side-notes.test.mjs.

export const FIELD = "sideSheets";
export const KEY_PREFIX = "sn";
export const SIDE_OF = "sideOf";
export const SIDE_FILE = "sideFile";
/** Hoechstlaenge der Notizen fuer die KI (Feld own_notes von POST /api/ai/tutor) */
export const AI_NOTES_CHARS = 4000;

const typeOf = e => e?.type || "pdf";
const objectsOf = (doc, key) => doc?.pages?.[key]?.objects || [];
const hasContent = (doc, key) => objectsOf(doc, key).length > 0;

/** Verknuepfungen: Blatt -> { Blattseite -> Seite im Dokument }. Unbrauchbare Eintraege werden uebergangen, die erste gilt. */
export function links(doc) {
  const out = {};
  for (const e of Array.isArray(doc?.[FIELD]) ? doc[FIELD] : []) {
    const file = typeof e?.file === "string" ? e.file : ""; const pages = e?.pages;
    if (!file || !pages || typeof pages !== "object" || Array.isArray(pages)) continue;
    for (const [sheetKey, main] of Object.entries(pages)) {
      if (typeof main !== "string" || !main) continue;
      out[file] ||= {}; if (!(sheetKey in out[file])) out[file][sheetKey] = main;
    }
  }
  return out;
}

/** Blaetter mit mindestens einem Eintrag, in der gespeicherten Reihenfolge */
export function sheetFileIDs(doc) {
  const seen = new Set(), out = [];
  for (const e of Array.isArray(doc?.[FIELD]) ? doc[FIELD] : []) { const f = e?.file; if (typeof f === "string" && f && !seen.has(f)) { seen.add(f); out.push(f); } }
  return out;
}

/** Eingeflochtene Blattseite ("sn-…", "sn2-…") */
export const isSheetKey = key => /^sn\d*-/.test(String(key || ""));

/**
 * Dokument in der Reihenfolge der Seitenleiste mit den Blattseiten direkt hinter ihrer Folie: Folie, ihre Seitennotizen
 * (Leerseiten dahinter bis zur naechsten PDF-Seite), dann die neben ihr beschriebenen Blattseiten. Unverknuepfte
 * Blattseiten (oder deren Seite es nicht mehr gibt) kommen ans Ende. `sheets`: [{ fileId, doc }] (auch { fileID, document }).
 * Nur Leerseiten eines Blatts werden uebernommen (Schluessel `sn-<Blattseite>`, Felder `sideOf`, `sideFile`, ohne
 * pkdrawing). skipEmptySheetPages: Blattseiten ohne Notizen weglassen; skipEmptyNotePages: leere Seitennotizen hinter einer
 * PDF-Seite weglassen (ihre Blattseiten bleiben). Das Original bleibt unveraendert.
 */
export function interleaved(main, sheets = [], { skipEmptySheetPages = true, skipEmptyNotePages = false } = {}) {
  const lk = links(main);
  const pages = { ...(main?.pages || {}) };
  const order0 = Array.isArray(main?.pageOrder) ? main.pageOrder : [];
  const mainKeys = new Set(order0.map(e => e?.key).filter(Boolean));
  const used = new Set([...mainKeys, ...Object.keys(pages)]);
  const byAnchor = new Map(); const loose = [];
  for (const sheet of sheets || []) {
    const fileId = sheet?.fileId ?? sheet?.fileID, sd = sheet?.doc ?? sheet?.document; if (!sd) continue; const seen = new Set();
    for (const entry of Array.isArray(sd.pageOrder) ? sd.pageOrder : []) {
      if (typeOf(entry) !== "blank") continue;
      const key = entry.key; if (typeof key !== "string" || !key || seen.has(key)) continue; seen.add(key);
      if (skipEmptySheetPages && !hasContent(sd, key)) continue;
      let nk = `${KEY_PREFIX}-${key}`; let n = 2; while (used.has(nk)) { nk = `${KEY_PREFIX}${n}-${key}`; n++; }
      used.add(nk);
      const e = { ...entry, key: nk, [SIDE_FILE]: fileId };
      const a = lk[fileId]?.[key]; const anchor = a && mainKeys.has(a) ? a : null;
      if (anchor) e[SIDE_OF] = anchor; else delete e[SIDE_OF];
      const page = { ...(sd.pages?.[key] || { objects: [] }) }; delete page.pkdrawing;
      pages[nk] = page;
      if (anchor) { if (!byAnchor.has(anchor)) byAnchor.set(anchor, []); byAnchor.get(anchor).push(e); } else loose.push(e);
    }
  }
  const take = k => { const v = byAnchor.get(k) || []; byAnchor.delete(k); return v; };
  const order = []; let pending = []; let sawPDF = false;
  for (const entry of order0) {
    const type = typeOf(entry);
    if (type === "pdf") { order.push(...pending); pending = []; sawPDF = true; }
    if (skipEmptyNotePages && sawPDF && type === "blank" && entry?.key && !hasContent(main, entry.key)) { pending.push(...take(entry.key)); continue; }
    order.push(entry);
    if (entry?.key) pending.push(...take(entry.key));
  }
  order.push(...pending, ...loose);
  return { ...main, pageOrder: order, pages };
}

/** Notizseiten einer Seite im eingeflochtenen Dokument: Seitennotizen direkt dahinter bis zur naechsten PDF-Seite und
 *  die neben ihr beschriebenen Blattseiten. Fuer eine Leerseite nur die Blattseiten, die neben ihr beschrieben wurden. */
export function notePages(doc, key) {
  const order = doc?.pageOrder || []; const i = order.findIndex(e => e?.key === key); if (i < 0) return [];
  const isPDF = typeOf(order[i]) === "pdf"; const out = [];
  for (let j = i + 1; j < order.length; j++) {
    const e = order[j]; const type = typeOf(e); if (type === "pdf") break;
    const k = e?.key; if (!k) continue;
    if (isSheetKey(k)) { const side = e[SIDE_OF]; if (side && (isPDF || side === key)) out.push(k); }
    else if (isPDF && type === "blank") out.push(k);
  }
  return out;
}

/** Schluessel der Notizseiten (Leerseiten hinter einer PDF-Seite und Blattseiten; keine eingefuegten Bild-/PDF-Seiten),
 *  Reihenfolge des Dokuments */
export function notePageKeys(doc) {
  let sawPDF = false; const out = [];
  for (const e of doc?.pageOrder || []) { const type = typeOf(e); if (type === "pdf") { sawPDF = true; continue; } if (e?.key && (isSheetKey(e.key) || (sawPDF && type === "blank"))) out.push(e.key); }
  return out;
}

/** Seitennotizen und Blattseiten im eingeflochtenen Dokument */
export const notePageCount = doc => notePageKeys(doc).length;

/** Folie (letzte PDF-Seite davor) einer Seite, oder null; unverknuepfte Blattseiten gehoeren keiner Folie */
export function slideOf(doc, key) {
  let last = null;
  for (const e of doc?.pageOrder || []) { if (typeOf(e) === "pdf") last = e.key; if (e?.key === key) return typeOf(e) === "pdf" ? e.key : (isSheetKey(key) && !e[SIDE_OF] ? null : last); }
  return null;
}

/** Gewaehlte Seiten mit der Folie jeder gewaehlten Notizseite (sonst stuende die Notiz beim Empfaenger als "Eigene Seite"
 *  ganz vorn). `allowed(slideKey)`: Folien, die sich teilen lassen. Wie SolutionBuilder.withSlides. */
export function withSlides(doc, keys, allowed = () => true) {
  const out = [...keys]; const have = new Set(keys); let lastPDF = null;
  for (const e of doc?.pageOrder || []) {
    const k = e?.key; if (!k) continue;
    if (typeOf(e) === "pdf") { lastPDF = k; continue; }
    if (isSheetKey(k) && !e[SIDE_OF]) continue;
    if (have.has(k) && lastPDF && !have.has(lastPDF) && allowed(lastPDF)) { out.push(lastPDF); have.add(lastPDF); }
  }
  return out;
}

/** Seiten fuer den PDF-Export (Indizes in `doc.pageOrder` des eingeflochtenen Dokuments). `mainKeys`: gewaehlte Seiten des
 *  Dokuments (null = alle); `withNotes`: ihre Notizseiten gleich dahinter (bei "alle" stehen sie ohnehin dort). */
export function exportIndices(doc, mainKeys = null, withNotes = true) {
  const order = doc?.pageOrder || [];
  if (!mainKeys) return order.map((_, i) => i);
  const want = []; const seen = new Set();
  for (const k of mainKeys) { if (seen.has(k)) continue; seen.add(k); want.push(k); if (withNotes) for (const n of notePages(doc, k)) if (!seen.has(n)) { seen.add(n); want.push(n); } }
  return want.map(k => order.findIndex(e => e?.key === k)).filter(i => i >= 0);
}

/** Bezeichnung einer Seite im eingeflochtenen Dokument fuer Listen: "PDF-Seite 4", "Notiz zu Folie 4",
 *  "Blatt zu Folie 4", "Blatt", "Eigene Seite", "Eingefuegte Seite" */
export function noteLabel(doc, i) {
  const order = doc?.pageOrder || []; const e = order[i]; if (!e) return "";
  const type = typeOf(e);
  if (type === "pdf") return `PDF-Seite ${e.index}`;
  let slide = null;
  for (let j = i - 1; j >= 0; j--) if (typeOf(order[j]) === "pdf") { slide = order[j].index; break; }
  if (isSheetKey(e.key)) return e[SIDE_OF] && slide ? `Blatt zu Folie ${slide}` : "Blatt";
  if (type === "blank") return slide ? `Notiz zu Folie ${slide}` : "Eigene Seite";
  return "Eingefügte Seite";
}

/** Getippter Text der Notizseiten (Textfelder, Haftnotizen) fuer die KI-Hilfe, ohne Handschrift (wie SideNotes.typedText) */
export function typedText(doc, keys) {
  return (keys || []).flatMap(k => objectsOf(doc, k).filter(o => o?.type === "text" && typeof o.text === "string").map(o => o.text.trim()).filter(Boolean))
    .join("\n").slice(0, AI_NOTES_CHARS);
}

// ---------------------------------------------------------------- Loesung teilen (Auswahl wie SolutionShareSheet)
const shareableType = e => typeOf(e) === "pdf" || typeOf(e) === "blank";

/** Vorauswahl: alle teilbaren Seiten mit Notizen (nie eingefuegte Bild-/PDF-Seiten); mit `includeNotes` (Standard) die
 *  Notizseiten mit ihrer Folie, sonst keine Notizseite */
export function initialShareSelection(doc, includeNotes = true) {
  const notes = new Set(notePageKeys(doc));
  const keys = (doc?.pageOrder || []).filter(e => e?.key && shareableType(e) && hasContent(doc, e.key) && (includeNotes || !notes.has(e.key))).map(e => e.key);
  return new Set(withSlides(doc, keys));
}

/** Haken an einer Seite: eine Notizseite bringt ihre Folie mit, eine abgewaehlte Folie nimmt ihre Notizseiten heraus */
export function toggleShare(doc, sel, key, on) {
  const out = new Set(sel || []);
  if (on) { out.add(key); const s = slideOf(doc, key); if (s && s !== key) out.add(s); }
  else { out.delete(key); const e = (doc?.pageOrder || []).find(x => x?.key === key); if (e && typeOf(e) === "pdf") for (const n of notePages(doc, key)) out.delete(n); }
  return out;
}

/** Schalter "Notizen und Blaetter mitschicken": an = alle Notizseiten mit Notizen (und ihre Folien), aus = keine */
export function setShareNotes(doc, sel, on) {
  const out = new Set(sel || []); const notes = notePageKeys(doc);
  if (!on) { notes.forEach(k => out.delete(k)); return out; }
  notes.filter(k => hasContent(doc, k)).forEach(k => out.add(k));
  return new Set(withSlides(doc, [...out]));
}

/** Was der PDF-Export ausgibt (wie NotesExport.exportDocument): `pageIdx` = gewaehlte Seiten des Dokuments (Indizes der
 *  Seitenleiste) oder null fuer alle; `includeSideNotes` = "Notizen und Blaetter mitschicken" (Blaetter laden, bei
 *  gewaehlten Seiten ihre Notizseiten dazu). Das ganze Dokument laesst leere Seitennotizen hinter Folien weg.
 *  Ergebnis { doc, idxs, notes } mit `notes` = Anzahl ausgegebener Notizseiten. Fehlt ein Blatt, geht es ohne weiter. */
export async function exportPlan(model, { pageIdx = null, includeSideNotes = true, fetchJson = null } = {}) {
  const sheets = includeSideNotes && fetchJson ? await loadSheets(model, fetchJson) : [];
  const whole = !pageIdx;
  const doc = interleaved(model, sheets, { skipEmptyNotePages: whole });
  const idxs = whole ? doc.pageOrder.map((_, i) => i)
    : exportIndices(doc, pageIdx.map(i => model?.pageOrder?.[i]?.key).filter(Boolean), includeSideNotes);
  const noteKeys = new Set(notePageKeys(doc));
  return { doc, idxs, notes: idxs.filter(i => noteKeys.has(doc.pageOrder[i]?.key)).length };
}

/** Blaetter laden: `fetchJson(url)` liefert die Antwort von GET /api/files/{id}/annotations ({ data }) oder wirft.
 *  Fehlende oder nicht lesbare Blaetter werden uebergangen. Ergebnis [{ fileId, doc }]. */
export async function loadSheets(main, fetchJson) {
  const out = [];
  for (const id of sheetFileIDs(main)) {
    try { const r = await fetchJson(`/api/files/${encodeURIComponent(id)}/annotations`); const d = r?.data; if (d && Array.isArray(d.pageOrder)) out.push({ fileId: id, doc: d }); } catch { /* Blatt fehlt */ }
  }
  return out;
}

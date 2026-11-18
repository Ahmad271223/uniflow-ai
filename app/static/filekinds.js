// Dateiarten jenseits der PDF (docs/DATEIARTEN.md, 04.11.2026): Word, PowerPoint, Audio, Video erkennen und beschriften.
// `files.kind` aus dem Backend bleibt "pdf | image | file | notebook | whiteboard"; die Art einer "file" kommt aus dem
// Namen, gleich wie `OfficeText.kind` im Kern (pdf | docx | pptx | audio) und `LibraryStyle.sourceKind` in der App.
// Geprueft von tests/js/filekinds.test.mjs mit packages/shared-contracts/fixtures/office-text/cases.json.
const EXT = { pdf: "pdf", docx: "docx", pptx: "pptx", mp3: "audio", m4a: "audio" };

/** pdf | docx | pptx | audio zu einem Dateinamen, sonst null (wie extract.text_kind in Python) */
export function sourceKind(name) {
  const last = String(name || "").split("/").pop();
  const dot = last.lastIndexOf(".");
  if (dot <= 0 || dot === last.length - 1) return null;
  return EXT[last.slice(dot + 1).toLowerCase()] || null;
}

/** Liefert die Datei Seitentexte (Suche, Skriptsuche, KI-Hilfe, Wochentests)? */
export const isTextSource = name => ["pdf", "docx", "pptx"].includes(sourceKind(name));

/** Anzeige-Art einer Bibliotheksdatei: pdf nach Dokumenttyp, "file" nach der Endung (word | slides | audio), sonst die Art */
export function displayType(f) {
  if (f.kind === "pdf") return f.doc_type || "sonstiges";
  if (f.kind === "file" || !f.kind) {
    const k = sourceKind(f.name);
    return k === "docx" ? "word" : k === "pptx" ? "slides" : k === "audio" ? "audio" : "file";
  }
  return f.kind;
}

export const KIND_ICON = { word: "file-text", slides: "layers", audio: "play", video: "play" };
export const KIND_TXT = { word: "Word", slides: "PowerPoint", audio: "Audio", video: "Video" };

/** Symbol zu einer Datei in Bibliothek und Schnellzugriff (nur fuer Arten, die core.js nicht kennt) */
export const kindIcon = (f, fallback) => KIND_ICON[displayType(f)] || fallback;
export const kindText = (f, fallback) => KIND_TXT[displayType(f)] || fallback;

/** Seiten einer PowerPoint- oder Word-Datei als Textansicht: "Folie n" bzw. "Seite n" je Seite, Text sicher maskiert */
export function pagesHtml(pages, kind, esc) {
  const label = kind === "pptx" ? "Folie" : "Seite";
  return pages.map((t, i) => `<section class="textpage" data-page="${i + 1}"><h4 class="muted small">${label} ${i + 1}</h4>${t ? esc(t) : `<span class="muted">(ohne Text)</span>`}</section>`).join("");
}

/** "Neu" wie auf der Uebersicht, den Modulkarten und in der iPad-App (study.new_file_sql, UFNewFiles): noch nicht
 * angesehen UND vor hoechstens 24 Stunden eingetragen (Auftrag des Inhabers 17.11.2026). Das rechnet der Server aus
 * (`is_new` 1/0 je Datei), hier wird nicht mit Zeiten gerechnet. Aeltere Antworten ohne `is_new`: nicht angesehen
 * (`seen_by_user` 0), noch aeltere ohne beides: Lernstand "neu". */
export function isNewFile(f) {
  if (f.is_new != null) return f.is_new === true || Number(f.is_new) === 1;
  return f.seen_by_user != null ? Number(f.seen_by_user) === 0 : f.status === "neu";
}

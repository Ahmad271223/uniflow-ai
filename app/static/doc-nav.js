// Dokument-Tabs: wohin nach dem Schliessen, und die leere Seite "Dokument wählen" (03.11.2026, wie Views.swift auf dem
// iPad: letzter Tab zu -> zurueck in die Bibliothek statt auf eine leere Seite ohne Zurueck). Reines Modul fuer
// tests/js/doc-nav.test.mjs; views-doc.js zeichnet und navigiert damit.

/** Ziel der Bibliothek */
export const LIBRARY_HASH = "#/files";

/** Text der leeren Seite, wenn kein Dokument offen ist (oder das gemerkte nicht mehr da ist) */
export const EMPTY_DOC = {
  title: "Dokument wählen",
  text: "In der Bibliothek ein Modul und ein Dokument auswählen.",
  missing: "Dieses Dokument gibt es nicht mehr.",
  action: "Zur Bibliothek",
};

/**
 * Adresse nach dem Schliessen eines Tabs. list = die Tabs NACH dem Entfernen, activeId = der offene Tab,
 * closedId = der geschlossene. Wurde der offene Tab geschlossen: der zuletzt geoeffnete uebrige, sonst die Bibliothek.
 * Wurde ein anderer geschlossen: null (bleibt auf der Seite).
 */
export function afterCloseTab(list, activeId, closedId) {
  if (closedId !== activeId) return null;
  const next = list[list.length - 1];
  return next ? `#/doc/${encodeURIComponent(next.id)}` : LIBRARY_HASH;
}

/** HTML der leeren Seite; missing = ein gemerktes Dokument ist nicht mehr da. icon = Symbolfunktion der Oberflaeche. */
export function emptyDocHtml(icon, esc, missing = false) {
  return `<div class="content"><div class="card empty">${icon("file-text", 36)}<div><b>${esc(EMPTY_DOC.title)}</b></div>`
    + `<div class="muted small">${esc(missing ? EMPTY_DOC.missing : EMPTY_DOC.text)}</div>`
    + `<div class="row" style="justify-content:center;margin-top:.8rem"><a class="btn primary" href="${LIBRARY_HASH}">${icon("folder", 15)} ${esc(EMPTY_DOC.action)}</a></div></div></div>`;
}

// ---- Schreibhand und geteilte Ansicht (09.11.2026, wie SplitSides.swift auf dem iPad; tests/js/split-sides.test.mjs)

/** Uebungsblatt, Loesung oder Klausur (Name, Stud.IP-Ordner oder Art) */
export function isExercise(f) {
  return ["uebung", "loesung", "klausur"].includes(f?.doc_type) || /übung|uebung|blatt|ueb\d|aufgabe/i.test(`${f?.name || ""} ${f?.studip_folder || ""}`);
}

/**
 * Rolle des zweiten Dokuments: "writing" (Blatt oder Uebung neben einem Skript: Seite der Schreibhand), sonst
 * "reference" (Skript und alles zum Lesen: Seite der freien Hand). Bisher lag jedes zweite Dokument auf der freien Seite.
 */
export function splitRole(side, primary) {
  const writes = f => f?.kind === "notebook" || f?.kind === "whiteboard" || isExercise(f);
  return writes(side) && !writes(primary) ? "writing" : "reference";
}

/** Zweites Dokument links? hand = Einstellung "right" | "left" (fehlt = Rechtshaender, freie Hand links) */
export function paneBLeft(hand, role) {
  const freeLeft = hand !== "left";
  return role === "writing" ? !freeLeft : freeLeft;
}

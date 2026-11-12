// Community neu laden, wenn man ins Fenster zurueckkommt (Befund 5.5 in docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md,
// 12.11.2026): Keine Ansicht aktualisierte sich von selbst; neue Fragen, Antworten, Lösungen und Mitteilungen anderer
// Geraete sah man erst nach einem Seitenwechsel. Jetzt beim Zurueckkommen (Fenster wieder sichtbar oder im Vordergrund)
// hoechstens einmal je Minute neu zeichnen, an derselben Scroll-Stelle. Nie, solange angefangener Text in einem Feld
// steht (Antwort, Frage, Kommentar) oder ein Dialog offen ist: der ginge beim Neuzeichnen verloren.
export const REFRESH_MS = 60 * 1000;

export function isCommunityHash(hash) {
  const h = String(hash || "").replace(/^#\/?/, "");
  return h === "community" || h.startsWith("community?") || h.startsWith("community/");
}

// Angefangener Text: ein sichtbares Eingabefeld, dessen Inhalt vom Ausgangswert abweicht
export function hasDraft(root) {
  if (!root?.querySelectorAll) return false;
  for (const el of root.querySelectorAll("textarea, input")) {
    const type = (el.type || "text").toLowerCase();
    if (["hidden", "checkbox", "radio", "button", "submit", "file", "range", "color"].includes(type)) continue;
    if (String(el.value || "").trim() && el.value !== el.defaultValue) return true;
  }
  return false;
}

export function shouldRefresh({ hash, hidden, now, shownAt, draft, modalOpen }) {
  if (hidden || draft || modalOpen || !isCommunityHash(hash)) return false;
  return now - (shownAt || 0) >= REFRESH_MS;
}

// Einbau in app.js: `route` zeichnet die Seite, `view` ist #view, `doc` das Dokument (fuer Tests austauschbar)
export function installCommunityRefresh({ route, view, doc = document, win = window, now = () => Date.now() }) {
  let shownAt = 0, busy = false;
  const mark = () => { if (isCommunityHash(win.location.hash)) shownAt = now(); };
  const check = async () => {
    const modalOpen = !!doc.querySelector("#overlay .modal, dialog[open]");
    if (busy || !shouldRefresh({ hash: win.location.hash, hidden: doc.hidden, now: now(), shownAt, draft: hasDraft(view()), modalOpen })) return false;
    busy = true; shownAt = now();
    const y = win.scrollY || 0;
    try { await route(); win.scrollTo(0, y); } finally { busy = false; }
    return true;
  };
  win.addEventListener("hashchange", mark);
  doc.addEventListener("visibilitychange", check);
  win.addEventListener("focus", check);
  mark();
  return { check, mark };
}

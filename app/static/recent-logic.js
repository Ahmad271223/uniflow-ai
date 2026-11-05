// "Zuletzt benutzt" und "Weitermachen wie zuvor" fuer Web und Windows (docs/WEITERMACHEN-2026-11-04.md, wie
// RecentItems.swift und ResumeState.swift auf dem iPad). Reine Funktionen ohne DOM (tests/js/recent.test.mjs).
//
// Liste: GET /api/recent (app/recent.py) liefert Dokumente (Seite), KI-Gespraeche und Wochentests nach Zeit.
// Weitermachen: wer das Fenster schliesst, waehrend ein Dokument offen ist, kommt beim naechsten Start auf dessen
// Seite zurueck, mit offener KI-Hilfe, wenn sie offen war (das Gespraech laedt die KI-Hilfe selbst, ai-panel.js).
// Wer das Dokument in der App verlaesst (Uebersicht, andere Seite), schliesst es ausdruecklich: dann startet die App dort.

export const DASHBOARD_LIMIT = 10;
export const KIND_LABEL = { document: "Dokument", conversation: "KI-Gespräch", test: "Wochentest" };
export const KIND_ICON = { document: "file", conversation: "sparkles", test: "exam" };

/** Ziel beim Antippen: Dokument auf seiner Seite, Gespraech im Dokument mit offener KI-Hilfe, Wochentest */
export function itemHref(it) {
  const id = encodeURIComponent(String(it?.id ?? ""));
  if (it?.kind === "test") return `#/exams/${id}`;
  if (it?.kind === "conversation") return it.test_id ? `#/exams/${encodeURIComponent(it.test_id)}` : `#/doc/${id}?ki=1`;
  const page = Number(it?.page) || 1;
  return `#/doc/${id}${page > 1 ? `?page=${page}` : ""}`;
}

const shortDate = at => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(at || ""));
  if (!m) return "";
  const d = new Date(+m[1], +m[2] - 1, +m[3]);
  return `${["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][d.getDay()]}., ${m[3]}.${m[2]}.`;
};

/** "Dokument · Analysis · Seite 4 · Mo., 03.11." – nur, was es gibt */
export function subtitle(it) {
  const parts = [KIND_LABEL[it?.kind] || "Dokument"];
  if (it?.sub) parts.push(String(it.sub));
  if (it?.kind === "document" && Number(it.page) > 1) parts.push(`Seite ${it.page}`);
  if (it?.kind === "test" && it.done && Number(it.max_score) > 0) parts.push(`${Math.round(100 * Number(it.score || 0) / Number(it.max_score))} %`);
  else if (it?.kind === "test" && !it.done) parts.push("begonnen");
  const d = shortDate(it?.at); if (d) parts.push(d);
  return parts.join(" · ");
}

// ---------------------------------------------------------------- Weitermachen

/** Stand fuer eine Route: im Dokument Datei, Seite und ob die KI-Hilfe offen ist; sonst nur der Name der Seite */
export function resumeEntry(hash, { page, ai } = {}) {
  const h = String(hash || "").replace(/^#\/?/, "");
  const [path, qs] = h.split("?"); const parts = path.split("/");
  if (parts[0] !== "doc" || !parts[1]) return { route: parts[0] || "dashboard" };
  const q = new URLSearchParams(qs || "");
  let file; try { file = decodeURIComponent(parts[1]); } catch { file = parts[1]; }
  return { route: "doc", file, page: Math.max(1, Math.floor(Number(page) || Number(q.get("page")) || 1)), ai: !!(ai ?? q.get("ki") === "1") };
}

/** Wohin beim Start? Nur wenn zuletzt ein Dokument offen war und die App auf der Uebersicht startet (keine andere
 *  Adresse, kein Erststart); sonst null */
export function resumeTarget(saved, currentHash) {
  if (!saved || saved.route !== "doc" || !saved.file) return null;
  const h = String(currentHash || "").replace(/^#\/?/, "");
  if (h && h !== "dashboard") return null;
  return `#/doc/${encodeURIComponent(saved.file)}?page=${Math.max(1, Number(saved.page) || 1)}${saved.ai ? "&ki=1" : ""}`;
}

export const resumeKey = account => `uniflow.resume.${account || "local"}`;

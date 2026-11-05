// KI-Start (Route #/ki) wie auf dem iPad (AIStartView.swift, Neugestaltung 04.11.2026), Regeln ohne DOM
// (tests/js/ai-start.test.mjs): ruhiger Start mit einer Frage und fuenf farbigen Aktionen, danach ein Gespraech mit
// Eingabe unten. Kontext ist das gewaehlte Modul und ein angehaengtes Dokument (dessen erste Seite); Fragen gehen an
// POST /api/ai/tutor wie die KI-Hilfe im Editor. "Hilfe" fragt keine KI (0 Credits). Gezeichnet wird in views-ai.js.
import { creditsLine, sourceLine } from "./ai-panel.js?v=2";

/** Aktionen in der Reihenfolge der Pillen; `tone` ist die Farbe (CSS-Klasse tone-<tone>) */
export const ACTIONS = [
  { id: "ask", title: "Fragen", sub: "Zur Seite, zur Aufgabe, zum Begriff", icon: "sparkles", tone: "teal" },
  { id: "cards", title: "Karteikarten", sub: "Aus einem Dokument, zum Durchsehen vor dem Speichern", icon: "cards", tone: "peach" },
  { id: "explain", title: "Erklären / PDF analysieren", sub: "Zusammenfassung des Dokuments, dann weiter im Editor", icon: "book", tone: "mint" },
  { id: "quiz", title: "Wochentest", sub: "15 Aufgaben zu einer Lehrwoche, gemeinsam je Modul", icon: "exam", tone: "sky" },
  { id: "help", title: "Hilfe", sub: "Was die KI-Hilfe kann und wie du anfängst, ohne KI", icon: "life-buoy", tone: "lavender" },
];

export const START_QUESTION = "Was möchtest du heute lernen?";
export const PLACEHOLDER = "Frag etwas … z. B. Erkläre mir den Satz von Bolzano";

/** Hilfe ohne KI (0 Credits): nennt nur, was die App heute kann */
export const HELP = {
  title: "So hilft dir die KI-Hilfe",
  costLine: "ohne KI · 0 Credits",
  can: { title: "Was die KI-Hilfe kann", icon: "sparkles", items: [
    "Eine Seite oder eine Markierung erklären – auf Wunsch so einfach wie möglich",
    "Eine Aufgabe Schritt für Schritt lösen – oder nur Hinweise geben, ohne die Lösung zu verraten",
    "Deine eigene Lösung prüfen: was stimmt, wo der Fehler liegt",
    "Fachbegriffe der Seite kurz definieren",
    "Eine Seite zusammenfassen und sagen, was du danach können musst",
    "Das ganze Dokument erklären: die ganze Vorlesung oder alle Aufgaben",
    "Karteikarten aus Seiten vorschlagen – du siehst jede Karte, bevor sie gespeichert wird",
    "Einen Wochentest mit Aufgabenzahl, Schwierigkeit und Aufgabenarten erstellen",
  ] },
  examples: [
    "Erkläre mir diese Seite so einfach wie möglich.",
    "Was muss ich nach dieser Vorlesung können? Nenne 3 Punkte.",
    "Löse Aufgabe 1 Schritt für Schritt.",
    "Gib mir nur Hinweise zu Aufgabe 2, keine fertige Lösung.",
    "Welche Fachbegriffe kommen hier vor? Definiere sie kurz.",
  ],
  start: { title: "So fängst du an", icon: "pen", items: [
    "Wähle oben ein Modul und hänge ein Dokument an – die KI liest dann dessen erste Seite.",
    "Im Editor liest die KI-Hilfe die offene Seite oder deinen markierten Text.",
    "Antworten bleiben unter „Zuletzt“ in diesem Browser.",
  ] },
  without: { title: "Ohne Unterlagen", icon: "sync", items: [
    "Noch keine Dokumente? Verbinde in den Einstellungen Stud.IP (an der Uni Hildesheim: Learnweb).",
    "Der Abgleich holt die Kursdateien in deine Bibliothek; danach wählst du hier eines als Kontext.",
    "Eigene PDFs kommen über „Dokumente & Notizen“ dazu.",
  ] },
};
export const helpSections = () => [HELP.can, HELP.start, HELP.without];
/** alle sichtbaren Hilfetexte (Ehrlichkeits-Test: keine Versprechen ohne Funktion) */
export const helpText = () => [HELP.title, HELP.costLine, ...helpSections().flatMap(s => [s.title, ...s.items]), ...HELP.examples].join("\n");

/** Titel eines Dokuments wie in der Bibliothek */
export const docTitle = f => f?.ai_title || f?.title || f?.name || "";

/** Lesbare Dokumente des gewaehlten Moduls (geladen, PDF), zuletzt geoeffnete zuerst, dann neueste */
export function documents(files, moduleId = 0) {
  return (Array.isArray(files) ? files : [])
    .filter(f => (!moduleId || f.module_id === moduleId) && !!f.downloaded_at && (f.kind || "pdf") === "pdf")
    .sort((a, b) => {
      const la = a.last_opened || "", lb = b.last_opened || "";
      if (la !== lb) return la < lb ? 1 : -1;
      return (b.chdate || 0) - (a.chdate || 0);
    });
}

/** Das angehaengte Dokument: Titel und Grund, wenn es die Vorgabe ist; null ohne Wahl */
export function attachment(fileId, docs) {
  if (!fileId) return null;
  const f = docs.find(d => d.id === fileId); if (!f) return null;
  const isDefault = docs[0]?.id === f.id;
  const hint = isDefault ? (f.last_opened ? "zuletzt geöffnet" : "neuestes Dokument") : null;
  return { id: f.id, title: docTitle(f), hint, label: hint ? `${docTitle(f)} · ${hint}` : docTitle(f) };
}

/** Zustand der Seite: Gespraech, sobald es einen Beitrag gibt oder die erste Frage unterwegs ist */
export const layout = (turns, pending) => (turns > 0 || pending ? "chat" : "start");
export const showsRecents = lay => lay === "start";

/** `history` fuer den Dienst (letzte 6 Beitraege) */
export function historyOf(turns, max = 6) {
  return turns.flatMap(t => [{ role: "user", text: t.question }, { role: "assistant", text: t.text }]).slice(-max);
}

/** Rumpf fuer POST /api/ai/tutor: Frage, optional Dokument (Seite 1) oder Modul als Kontext, bisheriges Gespraech */
export function requestBody({ mode = "ask", question = "", fileId = "", moduleId = 0, turns = [] }) {
  const body = { mode, page: 1, history: historyOf(turns) };
  if (fileId) body.file_id = fileId;
  else if (moduleId) body.module_id = moduleId;
  if (question) body.question = question;
  return body;
}

/** Antworttext einer Anfrage: bei Karteikarten die Karten als Liste */
export function answerText(r, mode) {
  let text = r?.answer || "";
  if (mode === "flashcards" && Array.isArray(r?.cards) && r.cards.length) text = r.cards.map(c => `- **${c.question || ""}** – ${c.answer || ""}`).join("\n");
  return text;
}

// ---------------------------------------------------------------- Zuletzt (im Browser)
export const RECENTS_MAX = 6;
/** neuen Eintrag nach vorn, gleiche Frage zum selben Dokument ersetzt, hoechstens RECENTS_MAX */
export function addRecent(list, entry, max = RECENTS_MAX) {
  const rest = (Array.isArray(list) ? list : []).filter(e => !(e.question === entry.question && (e.fileId || "") === (entry.fileId || "")));
  return [entry, ...rest].slice(0, max);
}
/** Vorschau einer Antwort ohne Markdown-Zeichen fuer die Karten unter "Zuletzt" */
export function plain(markdown) {
  return String(markdown || "").replace(/```[\s\S]*?```/g, " ").replace(/^#{1,6}\s*/gm, "").replace(/^\s*(?:[-*•]|\d+[.)])\s+/gm, "").replace(/\*\*|__|`/g, "")
    .replace(/\s*\n\s*/g, " · ").replace(/\s{2,}/g, " ").trim();
}

// ---------------------------------------------------------------- Kostenzeile
export const monthKey = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
export const countLine = n => (n === 1 ? "1 Anfrage diesen Monat" : `${n} Anfragen diesen Monat`);
/** "3 Anfragen diesen Monat · Credits: 37 von 100 übrig" (Credits im Dienst und am PC mit StudiNow-Konto); vor der
 *  ersten Antwort der Weg der KI aus GET /api/ai/source ("über dein ChatGPT · 0 Credits") */
export function statusLine(count, credits, explain, source = null) {
  const c = creditsLine(credits, explain) || sourceLine(source);
  return c ? `${countLine(count)} · ${c}` : countLine(count);
}

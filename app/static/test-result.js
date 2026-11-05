// Ergebnis eines Wochentests wie auf dem iPad (Neugestaltung 04.11.2026, TestResultView): Ring mit Prozent, Punkte,
// "n/m richtig · k zum Nacharbeiten", Einordnung ("Gut gemacht" / "Nochmal üben") und je Aufgabe "Frag die KI zu
// Aufgabe n" mit der KI-Hilfe in einer Seitenleiste (POST /api/ai/tutor, mode "explain", Aufgabe, eigene Antwort und
// Musterloesung als Kontext). Ohne DOM: tests/js/test-result.test.mjs.

/** eine Aufgabe zaehlt als richtig ab 60 % ihrer Punkte (wie die Faerbung der Aufgabenknoepfe) */
export const isRight = f => !!f && Number(f.points) >= Number(f.max) * 0.6;

/** Kopf des Ergebnisses aus test.feedback und den Aufgaben */
export function resultSummary(test) {
  const fb = test?.feedback || {}, per = Array.isArray(fb.per_question) ? fb.per_question : [];
  const total = Math.round(Number(fb.total) || 0), max = Math.round(Number(fb.max) || 0);
  const pct = max ? Math.max(0, Math.min(100, Math.round(100 * (Number(fb.total) || 0) / Number(fb.max)))) : 0;
  const n = (test?.questions || []).length || per.length, right = per.filter(isRight).length;
  const good = pct >= 60;
  return { pct, total, max, right, n, redo: Math.max(0, n - right), tone: good ? "ok" : "bad", status: good ? "Gut gemacht" : "Nochmal üben" };
}

/** "1/3 richtig · 2 zum Nacharbeiten" */
export const rightLine = r => `${r.right}/${r.n} richtig${r.redo ? ` · ${r.redo} zum Nacharbeiten` : ""}`;

export const askLabel = nr => `Frag die KI zu Aufgabe ${nr}`;

/** erste Frage an die KI: bei falscher Antwort "Warum …", sonst eine Erklaerung */
export const firstQuestion = (nr, right) => right ? `Erklär mir Aufgabe ${nr} noch einmal kurz.` : `Warum ist meine Antwort zu Aufgabe ${nr} falsch?`;

export const SUGGESTIONS = ["Erklär es mir einfacher", "Gib mir eine ähnliche Übungsaufgabe", "Welcher Denkfehler steckt dahinter?"];

/** Kontext fuer die KI (page_text): Aufgabe, eigene Antwort, Musterloesung, Rueckmeldung */
export function tutorContext(q, answer, f) {
  return [`Aufgabe ${q.nr}: ${q.question}`, q.options?.length ? `Antwortmöglichkeiten: ${q.options.join(" | ")}` : "",
    `Meine Antwort: ${answer || "(keine)"}`, `Musterlösung: ${q.answer ?? ""}`, f?.feedback ? `Rückmeldung: ${f.feedback}` : "",
    f ? `Punkte: ${f.points} von ${f.max}` : ""].filter(Boolean).join("\n");
}

/** Unterzeile der KI-Hilfe: "Aufgabe 1 · Multiple Choice" */
export const QTYPE = { mc: "Multiple Choice", calc: "Rechnen / Programmieren", tf: "Wahr / Falsch", cloze: "Lückentext", short: "Kurzantwort" };
export const askSub = q => `Aufgabe ${q.nr} · ${QTYPE[q.type] || "Kurzantwort"}`;

// Aufgabenarten seit 04.11.2026 (wie ExamQuestionCard in ExamsPage.swift): Wahr/Falsch und Lueckentext neben Multiple Choice,
// Kurzantwort und Rechnen. Auswahl-Aufgaben haben Antwortmoeglichkeiten (Wahr/Falsch immer die zwei festen), der
// Lueckentext ein einzeiliges Feld; die richtige Antwort ist beim Lueckentext das Wort fuer die Luecke (`blank`).
export const TF_OPTIONS = ["Wahr", "Falsch"];
export const kindLabel = type => QTYPE[type] || "Kurzantwort";
export const isChoice = q => q?.type === "mc" || q?.type === "tf";
/** Antwortmoeglichkeiten: bei Wahr/Falsch immer die beiden festen, auch wenn der Test keine mitbringt */
export function choices(q) {
  const o = Array.isArray(q?.options) ? q.options.map(String) : [];
  return q?.type === "tf" && o.length !== 2 ? TF_OPTIONS : o;
}
/** Zwei Optionen (Wahr/Falsch, Ja/Nein): zwei grosse Flaechen nebeneinander */
export const isTwoWay = q => isChoice(q) && choices(q).length === 2;
/** Richtige Antwort zum Anzeigen: beim Lueckentext das Wort fuer die Luecke, sonst die Musterloesung */
export function correctAnswer(q) {
  const blank = String(q?.blank ?? "").trim();
  return q?.type === "cloze" && blank ? blank : String(q?.answer ?? "");
}

/** Erklaerung zur Aufgabe: die der KI aus dem Test (`explanation`, 1-3 Saetze), nur wenn die Rueckmeldung der Bewertung nicht dasselbe sagt */
export function explanationOf(q, f) {
  const e = String(q?.explanation ?? "").trim();
  return e && e !== String(f?.feedback ?? "").trim() ? e : "";
}

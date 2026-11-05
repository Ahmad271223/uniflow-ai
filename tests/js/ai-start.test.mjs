// KI-Start (#/ki, app/static/ai-start-logic.js + views-ai.js, 05.11.2026), ohne Browser: Aktionen, Hilfe ohne KI,
// Dokumente als Kontext, Gespraech statt Start, Zuletzt, Kostenzeile.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../../app/static/ai-start-logic.js";
import { MODE_LABELS } from "../../app/static/ai-panel.js";

const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("fuenf Aktionen in der Reihenfolge und Farbe des iPads", () => {
  assert.deepEqual(L.ACTIONS.map(a => a.id), ["ask", "cards", "explain", "quiz", "help"]);
  assert.deepEqual(L.ACTIONS.map(a => a.tone), ["teal", "peach", "mint", "sky", "lavender"]);
  assert.deepEqual(L.ACTIONS.map(a => a.title), ["Fragen", "Karteikarten", "Erklären / PDF analysieren", "Wochentest", "Hilfe"]);
  assert.equal(L.START_QUESTION, "Was möchtest du heute lernen?");
  for (const a of L.ACTIONS) assert.ok(a.sub && a.icon, a.id);
});

test("Hilfe ohne KI: nennt nur, was es gibt, und kostet nichts", () => {
  assert.equal(L.HELP.costLine, "ohne KI · 0 Credits");
  assert.equal(L.helpSections().length, 3);
  assert.equal(L.HELP.examples.length, 5);
  const t = L.helpText();
  for (const falsch of [/Vorlesung aufnehmen/i, /Aufnahme/i, /Webseiten?-?Import/i, /Handschrift/i, /Apple|iPad|Schlüsselbund|ChatGPT/i]) assert.ok(!falsch.test(t), `Versprechen ohne Funktion: ${falsch}`);
  assert.match(t, /Karteikarten/); assert.match(t, /Wochentest/); assert.match(t, /ganze Vorlesung/);
});

test("Dokumente als Kontext: geladene PDFs des Moduls, zuletzt geoeffnete zuerst", () => {
  const files = [
    { id: "a", module_id: 1, downloaded_at: "x", kind: "pdf", chdate: 10, title: "A" },
    { id: "b", module_id: 1, downloaded_at: "x", kind: "pdf", chdate: 20, title: "B", last_opened: "2026-11-04T10:00" },
    { id: "c", module_id: 2, downloaded_at: "x", kind: "pdf", chdate: 30, title: "C" },
    { id: "d", module_id: 1, downloaded_at: null, kind: "pdf", chdate: 40, title: "D" },
    { id: "e", module_id: 1, downloaded_at: "x", kind: "docx", chdate: 50, title: "E" },
    { id: "f", module_id: 1, downloaded_at: "x", chdate: 5, name: "F.pdf", ai_title: "Folien F" },
  ];
  assert.deepEqual(L.documents(files, 1).map(f => f.id), ["b", "a", "f"]);
  assert.deepEqual(L.documents(files, 0).map(f => f.id), ["b", "c", "a", "f"], "alle Module");
  assert.deepEqual(L.documents(null, 0), []);
  const docs = L.documents(files, 1);
  assert.deepEqual(L.attachment("b", docs), { id: "b", title: "B", hint: "zuletzt geöffnet", label: "B · zuletzt geöffnet" });
  assert.equal(L.attachment("a", docs).hint, null, "vom Nutzer gewaehlt: kein Grund");
  assert.equal(L.attachment("f", docs).title, "Folien F");
  assert.equal(L.attachment("", docs), null); assert.equal(L.attachment("zzz", docs), null);
  assert.equal(L.attachment("a", [{ id: "a", title: "A", chdate: 1 }]).hint, "neuestes Dokument");
});

test("Start oder Gespraech; Zuletzt nur im Start", () => {
  assert.equal(L.layout(0, false), "start"); assert.equal(L.layout(1, false), "chat"); assert.equal(L.layout(0, true), "chat");
  assert.equal(L.showsRecents("start"), true); assert.equal(L.showsRecents("chat"), false);
});

test("Anfrage an den Tutor: Seite 1 des Dokuments, Verlauf der letzten sechs Beitraege", () => {
  const turns = Array.from({ length: 5 }, (_, i) => ({ question: `F${i}`, text: `A${i}` }));
  const b = L.requestBody({ mode: "ask", question: "Neu?", fileId: "f1", turns });
  assert.equal(b.mode, "ask"); assert.equal(b.page, 1); assert.equal(b.file_id, "f1"); assert.equal(b.question, "Neu?");
  assert.equal(b.history.length, 6); assert.deepEqual(b.history[0], { role: "user", text: "F2" }); assert.deepEqual(b.history.at(-1), { role: "assistant", text: "A4" });
  const bare = L.requestBody({ mode: "summary" });
  assert.ok(!("file_id" in bare) && !("question" in bare) && bare.history.length === 0);
  assert.equal(L.answerText({ answer: "Text" }, "ask"), "Text");
  assert.equal(L.answerText({ answer: "x", cards: [{ question: "Q", answer: "A" }] }, "flashcards"), "- **Q** – A");
  assert.equal(L.answerText(null, "ask"), "");
});

test("Zuletzt: neu nach vorn, gleiche Frage ersetzt, hoechstens sechs; Vorschau ohne Markdown", () => {
  let list = [];
  for (let i = 0; i < 8; i++) list = L.addRecent(list, { question: `F${i}`, answer: "a", fileId: "" });
  assert.equal(list.length, L.RECENTS_MAX); assert.equal(list[0].question, "F7");
  list = L.addRecent(list, { question: "F5", answer: "neu", fileId: "" });
  assert.equal(list.length, 6); assert.deepEqual(list.slice(0, 2).map(e => e.question), ["F5", "F7"]); assert.equal(list[0].answer, "neu");
  const other = L.addRecent(list, { question: "F5", answer: "x", fileId: "f9" });
  assert.deepEqual(other.slice(0, 2).map(e => [e.question, e.fileId]), [["F5", "f9"], ["F5", ""]], "anderes Dokument = andere Frage, beide bleiben");
  assert.equal(L.plain("## Titel\n\n- **Fett** und `code`\n- zwei\n\n1. eins"), "Titel · Fett und code · zwei · eins");
  assert.equal(L.plain(null), "");
});

test("Kostenzeile: Anfragen diesen Monat, mit Credits im Dienst", () => {
  assert.equal(L.countLine(1), "1 Anfrage diesen Monat"); assert.equal(L.countLine(0), "0 Anfragen diesen Monat"); assert.equal(L.countLine(5), "5 Anfragen diesen Monat");
  assert.equal(L.statusLine(3, null, null), "3 Anfragen diesen Monat");
  assert.equal(L.statusLine(3, { charged: 2, remaining: 8 }, null), "3 Anfragen diesen Monat · – 2 Credits (8 übrig)");
  assert.equal(L.monthKey(new Date(2026, 10, 5)), "2026-11");
});

test("views-ai.js und app.js: Route #/ki, Verlauf an den Tutor, Hilfe ohne Anfrage, Einstiege", () => {
  const v = read("views-ai.js"), app = read("app.js"), misc = read("views-misc.js"), ap = read("ai-panel.js");
  assert.match(app, /import \{ viewAiStart \} from "\.\/views-ai\.js\?v=\d+"/); assert.match(app, /routes\.ki = viewAiStart/);
  assert.match(v, /api\("\/ai\/tutor"/); assert.match(v, /L\.requestBody\(/);
  assert.match(v, /id === "cards"[\s\S]{0,80}#\/cards\?ki=1/); assert.match(v, /#\/exams\?neu=/);
  assert.match(misc, /params\?\.ki\) \$\("#aiOrder"/, "Karteikarten-Seite oeffnet den KI-Auftrag");
  assert.match(misc, /href="#\/ki"/, "Knopf KI-Start bei Tests & Wiederholung"); assert.match(ap, /href="#\/ki"/, "Raster-Symbol in der KI-Hilfe");
  const help = v.slice(v.indexOf("function drawHelp"), v.indexOf("function drawThread"));
  assert.ok(!/api\(/.test(help), "Hilfe fragt keine KI");
  assert.ok(MODE_LABELS.summary, "Erklaeren/PDF analysieren nutzt den Modus Zusammenfassen");
});

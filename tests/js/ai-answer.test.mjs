// Antworten der KI als HTML im Web (app/static/ai-answer.js, 18.11.2026, Antwortstil wie ChatGPT): dieselbe Gliederung
// wie AIMarkdownText auf dem iPad, Formeln als MathML (vom Browser gesetzt), ohne Browser geprueft.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { answerHtml, blocks, texToMathML, mathHtml, inlineHtml, cells, withoutMarks, sourceLabel } from "../../app/static/ai-answer.js";

const fixture = f => readFileSync(new URL(`../../packages/shared-contracts/fixtures/ai-tutor/${f}`, import.meta.url), "utf8");
const ANSWER = fixture("erklaeren-gu05-5-1.md");

test("Formeln: Bruch, Hochzahl, Kasten, Vorzeichen, Wurzel, Klammern in Formelhoehe", () => {
  assert.equal(texToMathML("\\frac{3+4i}{1-2i}"),
    "<mfrac><mrow><mn>3</mn><mo>+</mo><mn>4</mn><mi>i</mi></mrow><mrow><mn>1</mn><mo>−</mo><mn>2</mn><mi>i</mi></mrow></mfrac>");
  assert.equal(texToMathML("8i^2"), "<mrow><mn>8</mn><msup><mi>i</mi><mn>2</mn></msup></mrow>");
  assert.equal(texToMathML("\\boxed{-1 + 2i}"),
    '<mrow class="ai-boxed"><mrow><mo form="prefix">−</mo><mn>1</mn><mo>+</mo><mn>2</mn><mi>i</mi></mrow></mrow>');
  assert.equal(texToMathML("8 \\cdot (-1)"),
    '<mrow><mn>8</mn><mo>·</mo><mo stretchy="false">(</mo><mo form="prefix">−</mo><mn>1</mn><mo stretchy="false">)</mo></mrow>');
  assert.equal(texToMathML("x_1^2"), "<msubsup><mi>x</mi><mn>1</mn><mn>2</mn></msubsup>");
  assert.equal(texToMathML("\\sqrt{2}"), "<msqrt><mn>2</mn></msqrt>");
  assert.match(texToMathML("\\left(\\frac{a}{b}\\right)^2"), /^<msup><mrow><mo fence="true" stretchy="true">\(<\/mo><mfrac>/);
  assert.equal(texToMathML("\\alpha \\le \\pi"), "<mrow><mi>α</mi><mo>≤</mo><mi>π</mi></mrow>");
  assert.equal(texToMathML("\\text{Realteil}"), "<mtext>Realteil</mtext>");
  assert.equal(texToMathML("<script>"), "<mrow><mo>&lt;</mo><mi>s</mi><mi>c</mi><mi>r</mi><mi>i</mi><mi>p</mi><mi>t</mi><mo>&gt;</mo></mrow>", "nichts kommt roh ins HTML");
  assert.match(texToMathML("a \\\\ b"), /^<mtable><mtr><mtd><mi>a<\/mi><\/mtd><\/mtr><mtr><mtd><mi>b<\/mi><\/mtd><\/mtr><\/mtable>$/);
  assert.equal(mathHtml("x", true), '<math display="block"><mi>x</mi></math>');
  // kaputtes LaTeX bricht nichts
  for (const bad of ["\\frac{1}{2", "a } b \\right) c", "\\", "^", "\\left(", "\\unbekannt{x}"]) assert.equal(typeof texToMathML(bad), "string");
});

test("Bloecke der ChatGPT-aehnlichen Antwort zu Aufgabe 5.1", () => {
  const b = blocks(ANSWER);
  const count = t => b.filter(x => x.type === t).length;
  assert.equal(b[0].type, "paragraph");
  assert.equal(count("rule"), 5);
  assert.deepEqual(b.filter(x => x.type === "heading" && x.level === 2).map(x => x.text),
    ["1. Was ist überhaupt eine komplexe Zahl?", "2. Aufgabe (a)", "3. Aufgabe (b)", "4. Aufgabe (c)", "5. Die wichtigste Regel für deine Klausur"]);
  assert.equal(b.filter(x => x.type === "heading" && x.level === 3).length, 12);
  assert.ok(count("math") >= 25);
  const quote = b.find(x => x.type === "quote");
  assert.equal(quote.blocks[0].text, "**Merke: Komplexe Brüche lösen – immer gleich!**");
  assert.equal(quote.blocks[1].type, "numbered"); assert.equal(quote.blocks[1].items.length, 5);
  const table = b.find(x => x.type === "table");
  assert.deepEqual(table.header, ["Aufgabe", "Normaldarstellung"]);
  assert.deepEqual(table.rows.map(r => r[0]), ["(a)", "(b)", "(c)"]);
  assert.equal(b[b.length - 1].type, "paragraph"); assert.ok(b[b.length - 1].text.endsWith("wird?"));
});

test("HTML: keine rohen $ oder \\-Befehle, Kasten, Merke, Tabelle; mehrzeilige Formel und Formel allein im Absatz", () => {
  const h = answerHtml(ANSWER);
  assert.ok(!h.includes("$") && !/\\(frac|boxed|cdot)/.test(h), "alle Formeln gesetzt");
  assert.ok(h.includes('<div class="ai-math"><math display="block"'));
  assert.ok((h.match(/class="ai-boxed"/g) || []).length >= 10);
  assert.ok(h.includes('<div class="ai-merke"><p><b>Merke: Komplexe Brüche lösen – immer gleich!</b></p><ol>'));
  assert.ok(h.includes('<div class="ai-table"><table><thead><tr><th>Aufgabe</th><th>Normaldarstellung</th></tr></thead>'));
  assert.ok(h.includes("<hr>") && h.includes("<h3>2. Aufgabe (a)</h3>") && h.includes("<h4>Schritt 1: Mit dem konjugierten Nenner erweitern</h4>"));
  assert.equal(answerHtml("$$\n\\frac{a}{b}\n= c\n$$"), '<div class="ai-math"><math display="block"><mrow><mfrac><mi>a</mi><mi>b</mi></mfrac><mo>=</mo><mi>c</mi></mrow></math></div>');
  assert.equal(answerHtml("$x+yi$"), '<div class="ai-math"><math display="block"><mrow><mi>x</mi><mo>+</mo><mi>y</mi><mi>i</mi></mrow></math></div>');
  assert.equal(inlineHtml("Preis 5 $ und **fett** <b>"), "Preis 5 $ und <b>fett</b> &lt;b&gt;");
  assert.deepEqual(cells("| $|z|$ | b |"), ["$|z|$", "b"], "Betrag in der Formel trennt keine Zelle");
  // die alte flache Antwort bleibt ein Absatz (mit gesetzten Formeln statt Rohtext)
  const old = answerHtml(fixture("erklaeren-gu05-5-1-alt.md"));
  assert.ok(old.startsWith("<p>") && old.includes("<mfrac>") && !old.includes("$"));
});

test("Quellen: Marke aus dem Text, Zeile darunter mit Seite", () => {
  const src = [{ n: 1, page: 1, file_id: "f1", title: "GU05", cited: true }, { n: 2, page: 4, file_id: "f2", title: "Skript" }];
  assert.equal(withoutMarks("… und $i^2=-1$. [1] Siehe [2] und [7].", src), "… und $i^2=-1$. Siehe und [7].");
  assert.equal(withoutMarks("x [1]", []), "x [1]");
  assert.equal(sourceLabel(src[0], "f1"), "Seite 1");
  assert.equal(sourceLabel(src[1], "f1"), "Skript, Seite 4");
  assert.equal(sourceLabel({ n: 3, studip_id: "w1", title: "Wiki" }, "f1"), "Wiki (Stud.IP)");
});

test("editor.js nutzt die neue Darstellung, die KI-Leiste die Quellenzeile", () => {
  const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
  assert.match(read("editor.js"), /import \{ answerHtml \} from "\.\/ai-answer\.js\?v=\d+"/);
  assert.match(read("editor.js"), /export function md\(s\) \{\s*return answerHtml\(s\);/);
  assert.match(read("editor.css"), /\.ai-boxed/);
  assert.match(read("editor.css"), /\.ai-merke/);
});

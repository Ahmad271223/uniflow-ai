// Antworten der KI als HTML (18.11.2026, Antwortstil wie ChatGPT; wie AIMarkdownText und MathFormulaView auf dem iPad):
// Ueberschriften, Listen, Trennlinien, Merke-Kasten (Zitat "> "), Tabellen und Formeln. Formeln werden zu MathML, das
// alle aktuellen Browser selbst setzen (Brueche uebereinander, Hochzahlen, Wurzeln, Kasten fuer \boxed) - ohne
// Bibliothek, ohne Skript aus dem Netz. Reine Logik ohne DOM (tests/js/ai-answer.test.mjs).

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ESC[c]);

// ---------------------------------------------------------------- Formeln (LaTeX -> MathML)

const SYMBOLS = {
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ε", zeta: "ζ", eta: "η", theta: "θ", vartheta: "ϑ",
  iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", pi: "π", rho: "ρ", sigma: "σ", tau: "τ", upsilon: "υ", phi: "φ",
  varphi: "φ", chi: "χ", psi: "ψ", omega: "ω", Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π", Sigma: "Σ",
  Phi: "Φ", Psi: "Ψ", Omega: "Ω", infty: "∞", partial: "∂", nabla: "∇", int: "∫", oint: "∮", sum: "∑", prod: "∏",
  cdot: "·", cdots: "⋯", ldots: "…", dots: "…", times: "×", div: "÷", pm: "±", mp: "∓", circ: "∘", le: "≤", leq: "≤",
  ge: "≥", geq: "≥", ne: "≠", neq: "≠", approx: "≈", equiv: "≡", sim: "∼", propto: "∝", to: "→", rightarrow: "→",
  leftarrow: "←", Rightarrow: "⇒", implies: "⇒", Leftarrow: "⇐", Leftrightarrow: "⇔", iff: "⇔", mapsto: "↦", in: "∈",
  notin: "∉", subset: "⊂", subseteq: "⊆", cup: "∪", cap: "∩", setminus: "∖", emptyset: "∅", forall: "∀", exists: "∃",
  neg: "¬", land: "∧", wedge: "∧", lor: "∨", vee: "∨", oplus: "⊕", otimes: "⊗", langle: "⟨", rangle: "⟩", hbar: "ℏ",
  ell: "ℓ", degree: "°", prime: "′", mid: "|", vert: "|", Vert: "‖", lfloor: "⌊", rfloor: "⌋", lceil: "⌈", rceil: "⌉",
};
const FUNCTIONS = new Set(["sin", "cos", "tan", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "exp", "log", "ln", "lg",
  "lim", "max", "min", "sup", "inf", "det", "dim", "ker", "deg", "gcd", "arg", "sgn", "Re", "Im", "mod"]);
const OPERATORS = new Set(["+", "−", "=", "<", ">", "·", "×", "÷", "±", "∓", "≤", "≥", "≠", "≈", "≡", "∼", "∝", "→", "←", "⇒", "⇐",
  "⇔", "↦", "∈", "∉", "⊂", "⊆", "∪", "∩", "∖", "∧", "∨", "⊕", "⊗", "∘", ":"]);
const SPACES = { quad: 1, qquad: 2, enspace: .5 };
const IGNORED = new Set(["displaystyle", "textstyle", "limits", "nolimits", "nonumber", "notag", "big", "Big", "bigg", "Bigg",
  "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "middle", "label", "tag"]);
const BLACKBOARD = { R: "ℝ", N: "ℕ", Z: "ℤ", Q: "ℚ", C: "ℂ", P: "ℙ" };
const ACCENTS = { hat: "^", bar: "¯", overline: "¯", tilde: "~", dot: "˙", ddot: "¨", vec: "→" };

/** LaTeX einer Formel -> MathML (ohne <math>): eigener kleiner Parser wie MathLayout.swift */
export function texToMathML(tex) {
  const s = String(tex ?? "");
  let i = 0;
  const peek = (k = 0) => s[i + k];
  const isLetter = c => c != null && /\p{L}/u.test(c);
  const isDigit = c => c != null && /[0-9]/.test(c);
  const node = (tag, inner, attrs = "") => `<${tag}${attrs}>${inner}</${tag}>`;
  const lineBreaks = [];

  function skipSpaces() { while (peek() === " " || peek() === "\n" || peek() === "\t") i++; }
  function lookingAt(name) { return s.startsWith("\\" + name, i) && !isLetter(s[i + 1 + name.length]); }

  function row(top = false, untilBracket = false) {
    const out = [];
    while (i < s.length) {
      const c = peek();
      if (c === "}") return out;
      if (untilBracket && c === "]") return out;
      if (c === "\\" && peek(1) === "\\") { i += 2; if (top) { lineBreaks.push(out.length); out.push("<mspace linebreak=\"newline\"></mspace>"); } else out.push(node("mspace", "", ' width="1em"')); continue; }
      if (c === "\\" && lookingAt("right")) return out;
      if (c === "^" || c === "_") { i++; attach(out, argument(), c === "^"); continue; }
      const a = atom(out);
      if (a != null) out.push(a);
    }
    return out;
  }
  function wrapRow(items) { return items.length === 1 ? items[0] : node("mrow", items.join("")); }
  function attach(out, arg, sup) {
    const base = out.pop() ?? "<mrow></mrow>";
    const m = /^<msub>([\s\S]*)<\/msub>$/.exec(base);
    if (sup && m) {                                       // x_1^2 -> msubsup
      const parts = splitTwo(m[1]);
      if (parts) { out.push(node("msubsup", parts[0] + parts[1] + arg)); return; }
    }
    out.push(node(sup ? "msup" : "msub", base + arg));
  }
  /** zwei Kinder eines Elements trennen (oberste Ebene) */
  function splitTwo(inner) {
    let depth = 0;
    for (let k = 0; k < inner.length; k++) {
      if (inner.startsWith("</", k)) { depth--; k = inner.indexOf(">", k); if (depth === 0) return [inner.slice(0, k + 1), inner.slice(k + 1)]; continue; }
      if (inner[k] === "<") { const e = inner.indexOf(">", k); if (inner[e - 1] !== "/") depth++; k = e; }
    }
    return null;
  }
  function argument() {
    skipSpaces();
    const c = peek();
    if (c == null) return "<mrow></mrow>";
    if (c === "{") { i++; const r = row(); if (peek() === "}") i++; return wrapRow(r.length ? r : ["<mrow></mrow>"]); }
    if (c === "\\") return atom([]) ?? "<mrow></mrow>";
    i++;
    return classify(c, []);
  }
  function rawGroup() {
    skipSpaces();
    if (peek() !== "{") { const c = peek(); if (c != null) i++; return c ?? ""; }
    i++;
    let depth = 1, out = "";
    while (i < s.length) { const c = s[i++]; if (c === "{") depth++; else if (c === "}" && --depth === 0) break; out += c; }
    return out;
  }
  function unaryAllowed(prev) {
    const last = prev[prev.length - 1];
    return last == null || /^<mo( [^>]*)?>[^<]*<\/mo>$/.test(last) && !/>[)\]}|]<\/mo>$/.test(last);
  }
  function classify(c, prev) {
    if (c === "-" || c === "−") return unaryAllowed(prev) ? node("mo", "−", ' form="prefix"') : node("mo", "−");
    if (c === "+" && unaryAllowed(prev)) return node("mo", "+", ' form="prefix"');
    if (c === "*") return node("mo", "·");
    if (c === "'") return node("mo", "′");
    if (isLetter(c)) return node("mi", esc(c));
    if (isDigit(c)) return node("mn", c);
    if ("()[]|".includes(c)) return node("mo", esc(c), ' stretchy="false"');
    return node("mo", esc(c));
  }
  function atom(prev) {
    const c = peek();
    if (c === " " || c === "\n" || c === "\t" || c === "&") { i++; return null; }
    if (c === "~") { i++; return node("mspace", "", ' width="0.33em"'); }
    if (c === "{") { i++; const r = row(); if (peek() === "}") i++; return wrapRow(r.length ? r : ["<mrow></mrow>"]); }
    if (c === "\\") return command(prev);
    if (isDigit(c)) {
      let num = "";
      while (isDigit(peek()) || ((peek() === "." || peek() === ",") && isDigit(peek(1)) && num)) num += s[i++];
      return node("mn", num);
    }
    i++;
    return classify(c, prev);
  }
  function delimiter() {
    skipSpaces();
    const c = peek();
    if (c == null) return "";
    if (c === "\\") {
      i++;
      if (!isLetter(peek())) { const n = s[i++]; return n === "|" ? "‖" : n; }
      let name = ""; while (isLetter(peek())) name += s[i++];
      return SYMBOLS[name] ?? "";
    }
    i++;
    return c === "." ? "" : c;
  }
  function command(prev) {
    i++;
    const n = peek();
    if (n == null) return node("mo", "\\");
    if (!isLetter(n)) {
      i++;
      if (n === ",") return node("mspace", "", ' width="0.17em"');
      if (n === ":" || n === ">") return node("mspace", "", ' width="0.22em"');
      if (n === ";") return node("mspace", "", ' width="0.28em"');
      if (n === " ") return node("mspace", "", ' width="0.25em"');
      if (n === "!") return null;
      if (n === "|") return node("mo", "‖");
      return node("mo", esc(n));
    }
    let name = ""; while (isLetter(peek())) name += s[i++];
    switch (name) {
      case "frac": case "dfrac": case "tfrac": case "cfrac": { const a = argument(), b = argument(); return node("mfrac", a + b); }
      case "binom": { const a = argument(), b = argument(); return node("mrow", node("mo", "(") + node("mfrac", a + b, ' linethickness="0"') + node("mo", ")")); }
      case "sqrt": {
        skipSpaces();
        if (peek() === "[") { i++; const idx = row(false, true); if (peek() === "]") i++; const body = argument(); return node("mroot", body + wrapRow(idx.length ? idx : ["<mrow></mrow>"])); }
        return node("msqrt", argument());
      }
      case "boxed": case "fbox": case "framebox": return node("mrow", argument(), ' class="ai-boxed"');
      case "text": case "textrm": case "textnormal": case "mbox": case "textup": case "textit": case "textbf": case "emph":
        return node("mtext", esc(rawGroup()));
      case "operatorname": case "mathrm": { const t = rawGroup(); return node("mi", esc(t), t.length === 1 ? ' mathvariant="normal"' : ""); }
      case "mathbf": case "mathit": case "boldsymbol": case "bm": case "mathcal": case "mathsf": case "mathtt": case "underline": return argument();
      case "mathbb": { const t = rawGroup(); return node("mi", esc(BLACKBOARD[t] ?? t), ' mathvariant="normal"'); }
      case "left": {
        const open = delimiter(); const body = row(); let close = "";
        if (lookingAt("right")) { i += 6; close = delimiter(); }
        return node("mrow", (open ? node("mo", esc(open), ' fence="true" stretchy="true"') : "") + body.join("") + (close ? node("mo", esc(close), ' fence="true" stretchy="true"') : ""));
      }
      case "right": delimiter(); return null;
      case "begin": case "end": {
        const env = rawGroup();
        if (name === "begin" && /^(array|tabular)/.test(env)) { skipSpaces(); if (peek() === "{") rawGroup(); }
        if (env === "cases" && name === "begin") return node("mo", "{");
        return null;
      }
      case "color": rawGroup(); return null;
      case "textcolor": rawGroup(); return argument();
      default: {
        if (IGNORED.has(name)) return null;
        if (SPACES[name]) return node("mspace", "", ` width="${SPACES[name]}em"`);
        if (ACCENTS[name]) return node("mover", argument() + node("mo", ACCENTS[name]), ' accent="true"');
        if (FUNCTIONS.has(name)) return node("mi", name === "gcd" ? "ggT" : name);
        const sym = SYMBOLS[name];
        if (sym == null) return node("mtext", esc(name));
        if (OPERATORS.has(sym)) return node("mo", sym);
        if (/\p{Ll}/u.test(sym)) return node("mi", sym);
        return node("mo", sym);
      }
    }
  }

  const out = [];
  while (i < s.length) {
    out.push(...row(true));
    if (peek() === "}") i++;                                 // ueberzaehlige } ueberspringen
    else if (lookingAt("right")) { i += 6; delimiter(); }
  }
  // Zeilen (\\) als Tabelle untereinander, sonst eine Zeile
  if (lineBreaks.length) {
    const lines = []; let cur = [];
    for (const x of out) { if (x === "<mspace linebreak=\"newline\"></mspace>") { lines.push(cur); cur = []; } else cur.push(x); }
    lines.push(cur);
    return node("mtable", lines.filter(l => l.length).map(l => node("mtr", node("mtd", wrapRow(l)))).join(""));
  }
  return wrapRow(out.length ? out : ["<mrow></mrow>"]);
}

/** <math> fuer eine Formel; `display` = Block-Formel (zentriert). Screenreader lesen MathML selbst vor. */
export function mathHtml(tex, display = false) {
  return `<math${display ? ' display="block"' : ""}>${texToMathML(tex)}</math>`;
}

// ---------------------------------------------------------------- Markdown -> HTML

/** Text einer Zeile: Formeln $…$ als MathML, sonst escapt mit **fett**, *kursiv*, `code` */
export function inlineHtml(s) {
  const t = String(s ?? "");
  const parts = [];
  const re = /\$(?!\$)(?=[^\s$])([^$\n]{1,400}?)(?<=[^\s$\\])\$(?!\d)/g;
  let last = 0, m;
  while ((m = re.exec(t))) {
    parts.push(styled(t.slice(last, m.index)));
    parts.push(mathHtml(m[1]));
    last = m.index + m[0].length;
  }
  parts.push(styled(t.slice(last)));
  return parts.join("");
}
function styled(s) {
  let h = esc(s);
  h = h.replace(/`([^`]+)`/g, "<code>$1</code>");
  h = h.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/(^|\s)\*(?!\s)(.+?)\*(?=\s|$|[.,;:])/g, "$1<i>$2</i>");
  return h;
}

const isRule = t => /^([-*_])(\s*\1){2,}$/.test(t);
const isTableSep = t => /^\|?[\s:|-]*-[\s:|-]*$/.test(t) && t.includes("-");
export function cells(line) {
  let t = line.trim();
  if (t.startsWith("|")) t = t.slice(1);
  if (t.endsWith("|")) t = t.slice(0, -1);
  const out = []; let cur = "", math = false;
  for (const c of t) { if (c === "$") math = !math; if (c === "|" && !math) { out.push(cur.trim()); cur = ""; } else cur += c; }
  out.push(cur.trim());
  return out;
}
const solo = p => { const t = p.trim(); return /^\$[^$]+\$$/.test(t) ? t.slice(1, -1).trim() : null; };

/** Bloecke wie AIMarkdown.blocks (Swift): heading, paragraph, bullets, numbered, code, math, rule, quote, table */
export function blocks(text) {
  const lines = String(text ?? "").replace(/\r\n/g, "\n").split("\n");
  const out = []; let para = [], bullets = [], numbered = [], code = null;
  const flush = () => {
    if (para.length) { const p = para.join(" "); const tex = solo(p); out.push(tex != null ? { type: "math", tex } : { type: "paragraph", text: p }); para = []; }
    if (bullets.length) { out.push({ type: "bullets", items: bullets }); bullets = []; }
    if (numbered.length) { out.push({ type: "numbered", items: numbered }); numbered = []; }
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], t = line.trim();
    if (code) { if (t.startsWith("```")) { out.push({ type: "code", text: code.join("\n") }); code = null; } else code.push(line); continue; }
    if (t.startsWith("```")) { flush(); code = []; continue; }
    if (!t) { flush(); continue; }
    if (t.startsWith("$$") || t.startsWith("\\[")) {
      flush();
      const close = t.startsWith("$$") ? "$$" : "\\]", rest = t.slice(2);
      const end = rest.indexOf(close);
      if (end >= 0) { const tex = rest.slice(0, end).trim(); if (tex) out.push({ type: "math", tex }); continue; }
      const body = rest ? [rest] : [];
      while (++i < lines.length) { const k = lines[i].indexOf(close); if (k >= 0) { if (lines[i].slice(0, k).trim()) body.push(lines[i].slice(0, k)); break; } body.push(lines[i]); }
      const tex = body.join("\n").trim(); if (tex) out.push({ type: "math", tex });
      continue;
    }
    if (t.startsWith(">")) {
      flush();
      const inner = [];
      while (i < lines.length && lines[i].trim().startsWith(">")) { inner.push(lines[i].trim().slice(1).replace(/^ /, "")); i++; }
      i--;
      const b = blocks(inner.join("\n")); if (b.length) out.push({ type: "quote", blocks: b });
      continue;
    }
    if (isRule(t)) { flush(); out.push({ type: "rule" }); continue; }
    if (t.startsWith("|") && i + 1 < lines.length && isTableSep(lines[i + 1].trim())) {
      flush();
      const header = cells(t), rows = [];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith("|")) rows.push(cells(lines[i++]));
      i--;
      out.push({ type: "table", header, rows });
      continue;
    }
    const h = /^(#{1,6})\s+(.+?)\s*#*$/.exec(t);
    if (h) { flush(); out.push({ type: "heading", level: h[1].length, text: h[2] }); continue; }
    const b = /^[-*•]\s+(.+)$/.exec(t);
    if (b) { if (para.length || numbered.length) flush(); bullets.push(b[1]); continue; }
    const n = /^\d{1,3}[.)]\s+(.+)$/.exec(t);
    if (n) { if (para.length || bullets.length) flush(); numbered.push(n[1]); continue; }
    if (line.startsWith("  ") && bullets.length) { bullets[bullets.length - 1] += " " + t; continue; }
    if (line.startsWith("  ") && numbered.length) { numbered[numbered.length - 1] += " " + t; continue; }
    if (bullets.length || numbered.length) flush();
    para.push(t);
  }
  if (code) out.push({ type: "code", text: code.join("\n") });
  flush();
  return out;
}

function blockHtml(b) {
  switch (b.type) {
    case "heading": return b.level <= 2 ? `<h3>${inlineHtml(b.text)}</h3>` : `<h4>${inlineHtml(b.text)}</h4>`;
    case "paragraph": return `<p>${inlineHtml(b.text)}</p>`;
    case "bullets": return `<ul>${b.items.map(x => `<li>${inlineHtml(x)}</li>`).join("")}</ul>`;
    case "numbered": return `<ol>${b.items.map(x => `<li>${inlineHtml(x)}</li>`).join("")}</ol>`;
    case "code": return `<pre>${esc(b.text)}</pre>`;
    case "math": return `<div class="ai-math">${mathHtml(b.tex, true)}</div>`;
    case "rule": return "<hr>";
    case "quote": return `<div class="ai-merke">${b.blocks.map(blockHtml).join("")}</div>`;
    case "table": {
      const cols = Math.max(b.header.length, ...b.rows.map(r => r.length));
      const cell = (tag, x) => { const tex = solo(x || ""); return `<${tag}>${tex != null ? mathHtml(tex) : inlineHtml(x || "")}</${tag}>`; };
      const head = `<tr>${Array.from({ length: cols }, (_, k) => cell("th", b.header[k])).join("")}</tr>`;
      const body = b.rows.map(r => `<tr>${Array.from({ length: cols }, (_, k) => cell("td", r[k])).join("")}</tr>`).join("");
      return `<div class="ai-table"><table><thead>${head}</thead><tbody>${body}</tbody></table></div>`;
    }
    default: return "";
  }
}

/** Markdown einer KI-Antwort -> HTML (Ersatz fuer das fruehere md() in editor.js) */
export function answerHtml(text) { return blocks(text).map(blockHtml).join(""); }

// ---------------------------------------------------------------- Quellen

/** Quellenmarken [n] der bekannten Quellen aus dem Text (die Quelle steht klein unter der Antwort) */
export function withoutMarks(text, sources) {
  const known = new Set((Array.isArray(sources) ? sources : []).map(x => String(x.n)));
  if (!known.size) return String(text ?? "");
  return String(text ?? "").replace(/[ \t]?\[(\d{1,2})\]/g, (m, n) => known.has(n) ? "" : m);
}

/** "Seite 1" (diese Datei), "Skript, Seite 4", "Wiki (Stud.IP)" */
export function sourceLabel(x, fileId) {
  if (x.studip_id) return `${x.title || x.name || "Stud.IP"} (Stud.IP)`;
  if (!x.file_id || x.file_id === fileId || x.current) return `Seite ${x.page}`;
  return `${x.title || x.name || "Dokument"}, Seite ${x.page}`;
}

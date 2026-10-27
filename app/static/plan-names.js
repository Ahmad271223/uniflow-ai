// Kurznamen fuer enge Bloecke im Lernkalender (Woche, 3 Tage). Eine Fassung fuer Web und iPad: PlanNames in
// apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Study/PlanNames.swift arbeitet Schritt fuer Schritt
// gleich; die gemeinsamen Faelle stehen in packages/shared-contracts/fixtures/plan-names/cases.json.
//
// 1. Titel bereinigen: Kursnummer am Anfang ("11051 ...", "7002 - ..."), Uebungs-/Tutoriumswort vorn oder hinten
//    (wird zum Praefix "Ue "), Vorlesungswort vorn, eingeklammerte Zusaetze ("(fuer Elektrotechnik)") und ", Tranche ..."
//    zaehlen nicht.
// 2. Feste Eintraege nur am Anfang des bereinigten Titels (ganze Woerter), sonst allgemein: ein Wort bis 8 Buchstaben
//    bleibt, laengere werden an einer Silbengrenze gekuerzt ("Psych."); zwei Woerter je drei Buchstaben ("SigSys"); ab
//    drei Woertern die Anfangsbuchstaben ("EGI"). Fuellwoerter fallen weg, roemische Zahlen und Nummern bleiben.
// 3. Haben verschiedene Faecher (Modul, bereinigter Titel, fester Eintrag) denselben Kurznamen, wird er verlaengert, bis er
//    eindeutig ist: feste Eintraege werden allgemein, sonst bekommt das erste Wort, in dem sich die Faecher
//    unterscheiden, einen Buchstaben mehr (ein Wort: naechste Silbengrenze), zuletzt der ganze Titel.
// Nur Zeichen-fuer-Zeichen-Schritte (keine regulaeren Ausdruecke), damit Swift genau dasselbe tut.

const SPACES = new Set([9, 10, 11, 12, 13, 32, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff]);
const isSpace = cp => SPACES.has(cp) || (cp >= 0x2000 && cp <= 0x200a);
const SEPARATORS = new Set([..."-–—/,;:+&.|·()[]\"'„“”"].map(c => c.codePointAt(0)));
const VOWELS = new Set([..."aeiouyäöüàáâéèêëíìîïóòôúùû"]);
const STOP = new Set(["der", "die", "das", "des", "dem", "den", "und", "oder", "für", "fuer", "in", "im", "ins", "zu", "zum", "zur",
  "von", "vom", "mit", "an", "am", "auf", "aus", "bei", "über", "ueber", "unter", "nach", "vor", "ohne", "sowie", "bzw", "als",
  "ein", "eine", "einer", "eines", "einem", "einen", "the", "of", "and", "or", "for", "to", "a", "on", "with", "at", "by", "from", "into"]);
const EXERCISE = new Set(["übung", "uebung", "übungen", "gruppenübung", "gruppenuebung", "hörsaalübung", "hoersaaluebung",
  "zentralübung", "tutorium", "tutorien", "fragestunde", "fragestunden"]);
const LECTURE = new Set(["vorlesung", "vl"]);
const LINKERS = new Set(["zu", "zur", "zum"]);
// Feste Kurznamen: ganze Woerter am Anfang (klein geschrieben, " & " gilt als "und"); Nummern danach werden angehaengt
const FIXED = [
  [["mathematik", "für", "die", "ingenieurwissenschaften", "iii"], "Numerik"], [["numerik"], "Numerik"],
  [["mathematik", "für", "die", "ingenieurwissenschaften", "ii"], "Mathe II"], [["mathematik", "ii"], "Mathe II"],
  [["mathematik", "für", "die", "ingenieurwissenschaften", "i"], "Mathe I"], [["mathematik", "i"], "Mathe I"],
  [["signale", "und", "systeme"], "SigSys"], [["datenstrukturen", "und", "algorithmen"], "DSA"],
  [["programmieren", "ii"], "Prog II"], [["programmieren", "i"], "Prog I"], [["einführung", "in", "die", "informatik"], "Info"],
  [["grundlagen", "digitaler", "systeme"], "DigiSys"], [["digitale", "systeme"], "DigiSys"],
];

const cps = s => [...s];
const lower = s => s.toLowerCase();
function collapse(s) {
  let out = "", gap = false;
  for (const ch of s) { if (isSpace(ch.codePointAt(0))) gap = out.length > 0; else { if (gap) out += " "; out += ch; gap = false; } }
  return out;
}
function trimChars(s, chars) {
  const a = cps(s); let i = 0, j = a.length;
  while (i < j && chars.includes(a[i])) i++;
  while (j > i && chars.includes(a[j - 1])) j--;
  return a.slice(i, j).join("");
}
const isDigit = c => c >= "0" && c <= "9";
const isNumberToken = w => { const a = cps(w.endsWith(":") ? w.slice(0, -1) : w); return a.length > 0 && isDigit(a[0]) && a.every(c => isDigit(c) || c === "." || c === "/"); };
const isDash = w => w === "-" || w === "–" || w === "—" || w === ":";
function dropNumber(words) {
  if (words.length > 1 && isNumberToken(words[0])) { words = words.slice(1); if (words.length > 1 && isDash(words[0])) words = words.slice(1); }
  return words;
}
// Eingeklammerte Zusaetze entfernen (auch "[...]"); true, wenn einer davon nur "Uebung", "Tutorium" ... ist
function dropBrackets(s) {
  const a = cps(s); let out = [], exercise = false;
  for (let i = 0; i < a.length; i++) {
    const close = a[i] === "(" ? ")" : a[i] === "[" ? "]" : null;
    const j = close ? a.indexOf(close, i + 1) : -1;
    if (j < 0) { out.push(a[i]); continue; }
    if (EXERCISE.has(lower(collapse(a.slice(i + 1, j).join(""))))) exercise = true;
    while (out.length && isSpace(out[out.length - 1].codePointAt(0))) out.pop();
    out.push(" "); i = j;
  }
  return { text: out.join(""), exercise };
}

// Titel -> { pre: Praefix fuer Uebungen oder "", base: bereinigter Titel }
export function parseTitle(title) {
  let words = collapse((title || "").normalize("NFC")).split(" ").filter(Boolean), pre = "";
  words = dropNumber(words);
  if (words.length > 1) {
    const first = lower(words[0]), colon = first.endsWith(":"), w0 = colon ? first.slice(0, -1) : first;
    if (EXERCISE.has(w0) || LECTURE.has(w0)) {
      let rest = words.slice(1);
      if (!colon && rest.length > 1 && (LINKERS.has(lower(rest[0])) || rest[0] === ":")) rest = rest.slice(1);
      if (EXERCISE.has(w0)) pre = "Ü ";
      words = dropNumber(rest);
    }
  }
  const br = dropBrackets(words.join(" "));
  if (br.exercise) pre = "Ü ";
  words = collapse(br.text).split(" ").filter(Boolean);
  // "... - Fragestunden", "... - Tutorium", "... Uebung" am Ende
  for (let i = words.length - 1; i > 0; i--) {
    if (isDash(words[i]) && i + 1 < words.length && EXERCISE.has(lower(words[i + 1]))) { words = words.slice(0, i); pre = "Ü "; break; }
  }
  if (words.length > 1 && EXERCISE.has(lower(words[words.length - 1]))) { words = words.slice(0, -1); pre = "Ü "; }
  const tr = words.findIndex((w, i) => i > 0 && lower(trimChars(w, ",")) === "tranche");
  if (tr > 0) words = words.slice(0, tr);
  let base = trimChars(words.join(" "), [..." -–—:,("]);
  if (!base) base = collapse((title || "").normalize("NFC"));
  return { pre, base };
}

function tokens(base) {
  const out = []; let cur = "";
  for (const ch of base.split(" & ").join(" und ")) {
    const cp = ch.codePointAt(0);
    if (isSpace(cp) || SEPARATORS.has(cp)) { if (cur) out.push(cur); cur = ""; } else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}
function isDesignator(w) {
  const a = cps(w);
  if (a.length >= 1 && a.length <= 4 && a.every(c => c === "I" || c === "V" || c === "X")) return true;
  if (a.length === 1 && a[0] >= "A" && a[0] <= "Z") return true;
  let k = 0; while (k < a.length && isDigit(a[k])) k++;
  return k > 0 && (k === a.length || (k === a.length - 1 && a[k] >= "a" && a[k] <= "z"));
}
const cap = s => { const a = cps(s); return a.length ? a[0].toUpperCase() + a.slice(1).join("") : ""; };
const isVowel = c => VOWELS.has(lower(c));
// Kuerzungen eines langen Worts an Silbengrenzen ("Psychologie" -> "Psych.", "Psychol.", ...), zuletzt das ganze Wort
function cuts(w) {
  const a = cps(w);
  if (a.length <= 8) return [w];
  const out = [];
  for (let p = 3; p < a.length; p++) if (isVowel(a[p]) && !isVowel(a[p - 1])) out.push(a.slice(0, p).join("") + ".");
  if (!out.length) out.push(a.slice(0, 6).join("") + ".");
  out.push(w);
  return out;
}

// Zerlegung eines bereinigten Titels: fester Eintrag, wichtige Woerter, Nummern
function analyse(base) {
  const toks = tokens(base), low = toks.map(lower);
  let fixed = null, rest = 0;
  for (const [seq, name] of FIXED) {
    if (seq.length <= low.length && seq.every((w, i) => low[i] === w)) { fixed = name; rest = seq.length; break; }
  }
  const sig = [], des = [];
  toks.forEach((w, i) => { if (i > 0 && isDesignator(w)) des.push(w); else if (!STOP.has(low[i])) sig.push(w); });
  const fixedDes = toks.filter((w, i) => i >= rest && i > 0 && isDesignator(w));
  return { base, fixed: fixed && (fixedDes.length ? `${fixed} ${fixedDes.join(" ")}` : fixed), sig, des, words: sig.slice(0, 6) };
}
function startState(a) {
  return { mode: a.fixed ? "fixed" : "gen", cut: 0, lens: a.words.map(() => (a.words.length === 2 ? 3 : 1)) };
}
function candidate(a, st) {
  if (st.mode === "fixed") return a.fixed;
  if (st.mode === "full" || !a.sig.length) return a.base;
  let core;
  if (a.sig.length === 1) { const c = cuts(a.sig[0]); core = c[Math.min(st.cut, c.length - 1)]; }
  else core = a.words.map((w, i) => cap(cps(w).slice(0, st.lens[i]).join(""))).join("");
  return a.des.length ? `${core} ${a.des.join(" ")}` : core;
}

// Kurzname ohne Blick auf andere Faecher
export function tinyName(title) {
  const { pre, base } = parseTitle(title); const a = analyse(base);
  return pre + candidate(a, startState(a));
}

// Kurznamen fuer alle Titel eines Plans: items = [{ title, module_id }] -> Map Titel -> Kurzname. Verschiedene Faecher
// bekommen verschiedene Kurznamen (ein Fach: gleiches Modul, gleicher bereinigter Titel oder gleicher fester Eintrag).
export function tinyNames(items) {
  const titles = [], modsOf = new Map();
  for (const it of items || []) {
    const t = it?.title || ""; if (!modsOf.has(t)) { modsOf.set(t, new Set()); titles.push(t); }
    if (it?.module_id != null && it.module_id !== "") modsOf.get(t).add(String(it.module_id));
  }
  // Faecher: Titel mit gleichem Modul oder gleichem bereinigtem Titel gehoeren zusammen (Union-Find)
  const parent = new Map(); const find = k => { while (parent.get(k) !== k) k = parent.get(k); return k; };
  const add = k => { if (!parent.has(k)) parent.set(k, k); };
  const union = (x, y) => { add(x); add(y); const a = find(x), b = find(y); if (a !== b) parent.set(a < b ? b : a, a < b ? a : b); };
  const info = titles.map(t => { const p = parseTitle(t); const a = analyse(p.base); return { t, pre: p.pre, a, st: startState(a) }; });
  info.forEach(x => {
    union("t:" + x.t, "n:" + lower(x.a.base));
    if (x.a.fixed) union("t:" + x.t, "f:" + x.a.fixed);       // fester Eintrag: "Mathematik I" = "Mathematik fuer die ... I"
    for (const m of modsOf.get(x.t)) union("t:" + x.t, "m:" + m);
  });
  info.forEach(x => { x.fach = find("t:" + x.t); });
  for (let round = 0; round < 200; round++) {
    const groups = new Map();
    for (const x of info) { const c = candidate(x.a, x.st); if (!groups.has(c)) groups.set(c, []); groups.get(c).push(x); }
    let changed = false;
    for (const g of groups.values()) {
      if (new Set(g.map(x => x.fach)).size < 2) continue;
      const fixedOnes = g.filter(x => x.st.mode === "fixed");
      if (fixedOnes.length) { fixedOnes.forEach(x => { x.st = { ...startState(x.a), mode: "gen" }; }); changed = true; continue; }
      const gens = g.filter(x => x.st.mode === "gen" && x.a.sig.length);
      if (!gens.length) continue;
      const m = gens[0].a.words.length;
      if (m >= 2 && gens.every(x => x.a.words.length === m)) {
        let j = -1;
        for (let k = 0; k < m && j < 0; k++) {
          const differ = new Set(gens.map(x => lower(x.a.words[k]))).size > 1;
          if (differ && gens.some(x => x.st.lens[k] < cps(x.a.words[k]).length)) j = k;
        }
        if (j >= 0) gens.forEach(x => { if (x.st.lens[j] < cps(x.a.words[j]).length) { x.st = { ...x.st, lens: x.st.lens.map((v, i) => (i === j ? v + 1 : v)) }; } });
        else gens.forEach(x => { x.st = { ...x.st, mode: "full" }; });
      } else if (gens.every(x => x.a.sig.length === 1)) {
        gens.forEach(x => { x.st = x.st.cut < cuts(x.a.sig[0]).length - 1 ? { ...x.st, cut: x.st.cut + 1 } : { ...x.st, mode: "full" }; });
      } else gens.forEach(x => { x.st = { ...x.st, mode: "full" }; });
      changed = true;
    }
    if (!changed) break;
  }
  return new Map(info.map(x => [x.t, x.pre + candidate(x.a, x.st)]));
}

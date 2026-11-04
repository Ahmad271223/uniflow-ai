// Karteikarten-Trainer "Frei üben" (wie FlashcardTrainer.swift auf dem iPad), ohne DOM: Optionen, Filter, Reihenfolge
// und der Ablauf eines Durchgangs. Die Seite (viewCards in views-misc.js) zeichnet nur; tests/js/flashcards.test.mjs
// prueft dieselben Faelle wie FlashcardTrainerTests.swift.
//
// Der Trainer aendert den Wiederholungsplan NICHT: Fach und Termin (Leitner, POST /review) bleiben Sache von
// "Heute fällig". Gespeichert wird nur das letzte eigene Urteil (last_result), Lesezeichen und "versteckt" ueber
// PATCH /api/flashcards/{id}.

export const PROGRESS = ["right", "wrong", "unlearned", "hidden"];
export const PROGRESS_TXT = { right: "Richtig", wrong: "Falsch", unlearned: "Noch nicht gelernt", hidden: "Versteckte Karten" };

/** Gruppe einer Karte: jede Karte steht in genau einer (versteckt geht vor dem Urteil) */
export function progressOf(card) {
  if (card.hidden && Number(card.hidden) !== 0) return "hidden";
  return card.last_result === "right" ? "right" : card.last_result === "wrong" ? "wrong" : "unlearned";
}

/** Standard: alle Karten ausser versteckten, Reihenfolge des Anlegens, zuerst der Begriff */
export const defaultOptions = () => ({ scope: "all", progress: ["right", "wrong", "unlearned"], order: "original", firstSide: "term" });
export const sameOptions = (a, b) => a.scope === b.scope && a.order === b.order && a.firstSide === b.firstSide
  && a.progress.length === b.progress.length && a.progress.every(p => b.progress.includes(p));

export const isBookmarked = c => !!c.bookmarked && Number(c.bookmarked) !== 0;
export const isHidden = c => !!c.hidden && Number(c.hidden) !== 0;

export function matches(options, card) {
  return (options.scope === "all" || isBookmarked(card)) && options.progress.includes(progressOf(card));
}

/** Fisher-Yates mit Zufallsquelle (Tests setzen eine feste) */
export function shuffled(list, random = Math.random) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

/** Karten fuer einen Durchgang: gefiltert, "Original" = aelteste zuerst (id aufsteigend), "Zufällig" mit `shuffle` */
export function selectCards(options, cards, shuffle = shuffled) {
  const picked = cards.filter(c => matches(options, c)).sort((a, b) => (a.id ?? 0) - (b.id ?? 0));
  return options.order === "random" ? shuffle(picked) : picked;
}

/** Zahl der Karten je Gruppe */
export function progressCounts(cards) {
  const out = { right: 0, wrong: 0, unlearned: 0, hidden: 0 };
  for (const c of cards) out[progressOf(c)]++;
  return out;
}

/** Ablauf eines Durchgangs. `patch(id, body)` speichert (PATCH /api/flashcards/{id}) und liefert die gespeicherte Karte.
 *  Jede Antwort zaehlt einmal: waehrend des Speicherns (`busy`) werden weitere Eingaben ignoriert. */
/** "Erneut fragen": so viele Karten spaeter kommt dieselbe Karte wieder (wie FlashcardTrainer.askAgainGap) */
export const ASK_AGAIN_GAP = 3;

export function createTrainer({ patch, shuffle = shuffled } = {}) {
  const t = {
    options: defaultOptions(), active: false, cards: [], source: [], position: 0, flipped: false,
    known: 0, unknown: 0, answers: [], busy: false,
    get current() { return t.active && t.position < t.cards.length ? t.cards[t.position] : null; },
    get finished() { return t.active && t.cards.length > 0 && t.position >= t.cards.length; },
    get empty() { return t.active && t.cards.length === 0; },
    get canGoBack() { return t.active && t.answers.length > 0 && !t.busy; },
    /** zeigt gerade die Definition */
    get showsDefinition() { return (t.options.firstSide === "definition") !== t.flipped; },
    get progressText() { return `${Math.min(t.position + 1, t.cards.length)}/${t.cards.length}`; },
    start(all) { t.source = all; begin(selectCards(t.options, all, shuffle)); },
    restart() { begin(selectCards(t.options, t.source, shuffle)); },
    apply(options) { t.options = { ...options, progress: [...options.progress] }; t.restart(); },
    /** nur die in diesem Durchgang nicht gewussten Karten, in ihrer Reihenfolge */
    practiceUnknown() { const ids = new Set(t.answers.filter(a => !a.known).map(a => a.id)); begin(t.cards.filter(c => ids.has(c.id))); },
    end() { t.active = false; t.cards = []; t.position = 0; t.flipped = false; t.known = 0; t.unknown = 0; t.answers = []; t.busy = false; },
    flip() { if (t.current) t.flipped = !t.flipped; },
    /** "Erneut fragen" moeglich: Karte vorn und danach noch mindestens eine andere */
    get canAskAgain() { return !!t.current && !t.busy && t.position + 1 < t.cards.length; },
    /** Karte ohne Urteil nach hinten: kommt ASK_AGAIN_GAP Karten spaeter wieder (am Ende, wenn weniger folgen) */
    askAgain() {
      if (!t.canAskAgain) return false;
      const [card] = t.cards.splice(t.position, 1);
      t.cards.splice(Math.min(t.position + ASK_AGAIN_GAP, t.cards.length), 0, card);
      t.flipped = false;
      return true;
    },
    /** Antwort auf die aktuelle Karte; false, wenn nichts zu bewerten war */
    async answer(known) {
      const card = t.current; if (!card || t.busy) return false;
      const index = t.position, before = card.last_result ?? null; t.busy = true;    // Urteil vor dem Speichern merken
      try {
        const saved = await patch(card.id, { last_result: known ? "right" : "wrong" });
        if (!t.active || t.position !== index) return false;
        t.answers.push({ index, id: card.id, known, before });
        merge(saved);
        if (known) t.known++; else t.unknown++;
        t.position++; t.flipped = false;
        return true;
      } finally { t.busy = false; }
    },
    /** "Vorherige": letzte Antwort zuruecknehmen (Zaehler und gespeichertes Urteil), Karte wieder vorn */
    async previous() {
      const last = t.answers[t.answers.length - 1]; if (!last || t.busy) return false;
      t.busy = true;
      try {
        const saved = await patch(last.id, { last_result: last.before });
        if (t.answers[t.answers.length - 1] !== last) return false;
        t.answers.pop(); merge(saved);
        if (last.known) t.known--; else t.unknown--;
        t.position = last.index; t.flipped = false;
        return true;
      } finally { t.busy = false; }
    },
    async toggleBookmark() {
      const card = t.current; if (!card || t.busy) return;
      t.busy = true;
      try { merge(await patch(card.id, { bookmarked: !isBookmarked(card) })); } finally { t.busy = false; }
    },
    /** verstecken bzw. wieder zeigen; passt die Karte danach nicht mehr zum Filter, verlaesst sie den Durchgang */
    async toggleHidden() {
      const card = t.current; if (!card || t.busy) return;
      t.busy = true;
      try {
        merge(await patch(card.id, { hidden: !isHidden(card) }));
        const now = t.current;
        if (now && now.id === card.id && !matches(t.options, now)) { t.cards.splice(t.position, 1); t.flipped = false; }
      } finally { t.busy = false; }
    },
  };
  function begin(list) { t.cards = list; t.position = 0; t.flipped = false; t.known = 0; t.unknown = 0; t.answers = []; t.active = true; }
  function merge(saved) {
    if (!saved || saved.id == null) return;
    const up = c => c.id === saved.id ? { ...c, bookmarked: saved.bookmarked ?? 0, hidden: saved.hidden ?? 0, last_result: saved.last_result ?? null } : c;
    t.cards = t.cards.map(up); t.source = t.source.map(up);
  }
  return t;
}

// ---------------------------------------------------------------------------------------------------------------
// Geschlossene Stapel und Bearbeiten (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md), ohne DOM: dieselben Regeln
// wie FlashcardDeck in CardsPage.swift. Jede Karte gehoert zu genau einem Stapel; geuebt wird nur im gewaehlten
// Stapel; eine Karte laesst sich nachtraeglich aendern (Frage, Antwort, Modul, Stapel), der Lernstand bleibt.

/** Kennung fuer "Neuer Stapel …" in Auswahlfeldern */
export const NEW_STACK = -1;

/** Karten eines Stapels (neueste zuerst wie die Antwort) */
export const cardsOfStack = (cards, stackId) => cards.filter(c => c.stack_id === stackId);

/** Stapel eines Fachs (null = ohne Modul): zuletzt geuebte zuerst, dann die neuesten */
export function stacksOfSubject(stacks, subject) {
  return stacks.filter(s => (s.subject || "") === (subject || ""))
    .sort((a, b) => ((b.last_practised || "") + "\u0000" + String(b.id).padStart(12, "0")).localeCompare((a.last_practised || "") + "\u0000" + String(a.id).padStart(12, "0")));
}

/** Vorgabe beim Anlegen oder Verschieben: der zuletzt benutzte Stapel des Fachs, sonst "Neuer Stapel …" */
export const defaultStack = (stacks, subject) => stacksOfSubject(stacks, subject)[0]?.id ?? NEW_STACK;

/** Auswahl fuer ein Stapel-Feld: "Neuer Stapel …" plus die Stapel des Fachs */
export const stackOptions = (stacks, subject) => [{ id: NEW_STACK, name: "Neuer Stapel …" }, ...stacksOfSubject(stacks, subject).map(s => ({ id: s.id, name: s.name }))];

/** Name fuer "Neuer Stapel …": Titel des Dokuments, sonst "Allgemein" im Modul, sonst "Ohne Modul" (wie der Server) */
export const suggestedStackName = (file, subject) => (file && (file.title || file.name)) || (subject ? "Allgemein" : "Ohne Modul");

/** Stapelliste je Modul: Module in ihrer Reihenfolge (Fach = Modulname), dann Faecher ohne Modul, zuletzt "Ohne Modul" */
export function groupStacks(stacks, modules) {
  const buckets = new Map();
  for (const s of stacks) { const k = s.subject || ""; if (!buckets.has(k)) buckets.set(k, []); buckets.get(k).push(s); }
  const out = [];
  for (const m of modules) { if (buckets.has(m.name)) { out.push({ id: `m${m.id}`, title: m.name, color: m.color || null, stacks: buckets.get(m.name) }); buckets.delete(m.name); } }
  for (const k of [...buckets.keys()].filter(k => k).sort()) out.push({ id: `s${k}`, title: k, color: null, stacks: buckets.get(k) });
  if (buckets.has("")) out.push({ id: "none", title: "Ohne Modul", color: null, stacks: buckets.get("") });
  return out;
}

/** Unterzeile eines Stapels: Modul, Karten, heute faellig, zuletzt geuebt (`fmt` formatiert ein ISO-Datum) */
export function stackLine(s, fmt = d => d) {
  const n = s.cards ?? 0;
  const parts = [s.subject || "Ohne Modul", `${n} ${n === 1 ? "Karte" : "Karten"}`, `Heute fällig (${s.due ?? 0})`];
  parts.push(s.last_practised ? `zuletzt geübt am ${fmt(String(s.last_practised).slice(0, 10))}` : "noch nicht geübt");
  return parts.join(" · ");
}

/** Pruefung eines Entwurfs (Anlegen oder Bearbeiten): Meldung oder null */
export function validateCard(d) {
  if (!String(d.question ?? "").trim() || !String(d.answer ?? "").trim()) return "Frage und Antwort sind nötig.";
  if (Number(d.stack) === NEW_STACK && !String(d.newStackName ?? "").trim()) return "Der neue Stapel braucht einen Namen.";
  return null;
}

/** PATCH-Rumpf fuers Bearbeiten: nur geaenderte Felder (Frage, Antwort ohne Leerraum aussen, Fach, Stapel); leer = nichts zu speichern */
export function editPatch(card, d) {
  const body = {};
  const q = String(d.question ?? "").trim(), a = String(d.answer ?? "").trim();
  if (q !== card.question) body.question = q;
  if (a !== card.answer) body.answer = a;
  const subject = d.subject || null;
  if (subject !== (card.subject || null)) body.subject = subject;
  if (d.stack != null && Number(d.stack) !== NEW_STACK && Number(d.stack) !== card.stack_id) body.stack_id = Number(d.stack);
  return body;
}

/** Gespeicherte Karte (Antwort von PATCH) in eine Liste uebernehmen, Stelle bleibt */
export const mergeCard = (cards, saved) => cards.map(c => c.id === saved.id ? { ...c, ...saved } : c);

// Lehrwoche und Art je Stapel (Ergaenzung 04.11.2026): week 1..n (null = "Allgemein"), kind vorlesung | uebung | eigene
export const KINDS = { eigene: "Eigene", vorlesung: "Vorlesung", uebung: "Übung" };
export const GENERAL_WEEK = 0;
export const kindLabel = kind => KINDS[kind] || "Eigene";
/** Etikett eines Stapels: "Übung · W3", "Eigene · Allgemein" */
export const stackBadge = s => `${kindLabel(s.kind)} · ${s.week ? `W${s.week}` : "Allgemein"}`;
/** Lehrwochen, die in Stapeln vorkommen (Filter "Alle · Allgemein · W1 … Wn"), aufsteigend */
export const weeksOf = stacks => [...new Set(stacks.map(s => s.week).filter(w => w))].sort((a, b) => a - b);
/** Stapel nach Woche: null = alle, GENERAL_WEEK = ohne Lehrwoche, sonst die Woche */
export const filterStacks = (stacks, week) => week == null ? stacks : stacks.filter(s => week === GENERAL_WEEK ? !s.week : s.week === week);

// ---------------------------------------------------------------------------------------------------------------
// Geteilte Wochenstapel und "Stapel teilen" (Entscheidung des Inhabers vom 04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md),
// ohne DOM, dieselben Regeln wie FlashcardDeck in CardsPage.swift: je Modul und Lehrwoche die gemeinsamen Stapel
// "Vorlesung Woche n" und "Übung Woche n" (POST /api/flashcard-stacks/week/{modul}/{woche}/{art}: uebernehmen = 0 Credits),
// "Woche n komplett" = Vorlesung, dann Uebung (bewusste Wahl, kein Mischen); eigene Stapel je Stapel in die
// Modul-Community (POST /api/flashcard-stacks/{id}/share), geteilte Stapel anderer (/api/community/card-stacks) uebernehmen.

/** Arten der Wochenstapel in der Reihenfolge von "Woche n komplett" */
export const WEEK_KINDS = ["vorlesung", "uebung"];

/** uebernommener Wochenstapel eines Fachs (source = week) fuer Woche und Art, sonst null */
export const weekStack = (stacks, subject, week, kind) =>
  stacks.find(s => s.source === "week" && (s.subject || "") === (subject || "") && s.week === week && s.kind === kind) || null;

/** beide Wochenstapel da: "Woche n komplett" laesst sich ueben */
export const hasCompleteWeek = (stacks, subject, week) => WEEK_KINDS.every(k => weekStack(stacks, subject, week, k));

/** Karten fuer "Woche n komplett": erst der Vorlesungsstapel, dann der Uebungsstapel, je in der Reihenfolge des Anlegens */
export function weekCompleteCards(cards, stacks, subject, week) {
  return WEEK_KINDS.flatMap(k => { const s = weekStack(stacks, subject, week, k); return s ? cards.filter(c => c.stack_id === s.id).sort((a, b) => a.id - b.id) : []; });
}

/** Ergebniszeile beim Holen ("Vorlesung: übernommen · 20 Karten · 0 Credits · Variante 2 von 3") */
export function fetchLabel(kind, status, cards = 0, variant = null) {
  const name = kind === "vorlesung" ? "Vorlesung" : "Übung", n = `${cards} ${cards === 1 ? "Karte" : "Karten"}`;
  switch (status) {
    case "exists": return `${name}: Stapel ist schon da`;
    case "adopted": return `${name}: übernommen · ${n} · 0 Credits${variant ? ` · Variante ${variant} von 3` : ""}`;
    case "generated": return `${name}: neu erzeugt und geteilt · ${n}`;
    case "unshared": return `${name}: eigener Stapel · ${n}`;
    case "no_materials": return `${name}: keine Unterlagen in dieser Woche`;
    default: return `${name}: ${status}`;
  }
}

/** Etikett mit Herkunft: "Vorlesung · W5 · gemeinsam", "… · übernommen", "… · geteilt" */
export function stackBadgeFull(s) {
  let out = stackBadge(s);
  if (s.source === "week") out += " · gemeinsam"; else if (s.source === "community") out += " · übernommen";
  if (s.shared_id) out += " · geteilt";
  return out;
}

/** "Stapel teilen" gibt es nur fuer Stapel eines Moduls mit Karten, solange der Dienst da ist */
export const canShare = (s, available = true) => available && !!s.subject && (s.cards ?? 0) > 0;

/** Unterzeile eines geteilten Stapels: Pseudonym, Karten, Likes, eigener/uebernommen */
export function sharedLine(s) {
  const n = s.cards ?? 0, likes = s.likes ?? 0;
  const parts = [`von ${s.pseudonym || "Anonym"}`, `${n} ${n === 1 ? "Karte" : "Karten"}`, `${likes} ${likes === 1 ? "Like" : "Likes"}`];
  if (s.mine) parts.push("dein Stapel");
  if (s.adopted) parts.push("übernommen");
  return parts.join(" · ");
}

/** geteilte Stapel anderer nach Woche (null = alle, GENERAL_WEEK = Allgemein), eigene nicht */
export const filterShared = (list, week) => filterStacks((list || []).filter(s => !s.mine), week);

// ---------------------------------------------------------------- Tarif (Entscheidung 04.11.2026)
// Eigene Karteikarten (anlegen, bearbeiten, ueben, Stapel, teilen, uebernehmen, Wochenstapel holen) gibt es ab Plus
// (Recht `can_use_flashcards`, der Dienst antwortet sonst 403). Free sieht seine Karten und Stapel weiter, nur lesend.
// Am eigenen PC (nicht gehostet) gibt es keine Tarife.
export const LOCK_TITLE = "Karteikarten gibt es ab StudiNow Plus.";
export const LOCK_TEXT = "Mit Plus übst und bearbeitest du deine Karten wieder.";
export const readOnly = (hosted, entitlements) => !!hosted && !entitlements?.entitlements?.can_use_flashcards;

// ---------------------------------------------------------------- Stapel-Kacheln (Neugestaltung 04.11.2026)
// Wie die Kacheln in CardsPage.swift: farbige Kante je Art, Name, Modul, Woche, grosse Zahl "heute fällig", Lernstand als
// Balken je Leitner-Fach 1 bis 5, grosser Knopf "Üben" und darunter, was "Üben" tut.

/** Symbol je Art (core.js icon) */
export const KIND_ICON = { eigene: "cards", uebung: "pen", vorlesung: "book" };
export const kindOf = s => (s && KINDS[s.kind] ? s.kind : "eigene");

/** Wochen-Etikett einer Kachel: "Woche 3" bzw. "Allgemein" */
export const weekChip = s => (s && s.week ? `Woche ${s.week}` : "Allgemein");

/** Herkunft als kurze Etiketten: gemeinsam, übernommen, geteilt */
export function stackTags(s) {
  const out = [];
  if (s?.source === "week") out.push("gemeinsam"); else if (s?.source === "community") out.push("übernommen");
  if (s?.shared_id) out.push("geteilt");
  return out;
}

/** Karten je Leitner-Fach 1..5 (fehlendes oder unbrauchbares Fach zaehlt als 1, mehr als 5 als 5) */
export function boxCounts(cards) {
  const out = [0, 0, 0, 0, 0];
  for (const c of cards || []) { const b = Math.min(5, Math.max(1, Math.round(Number(c.box) || 1))); out[b - 1]++; }
  return out;
}

/** Balkenhoehe je Fach als Anteil am groessten Fach (0..1); ohne Karten alles 0 */
export function boxLevels(counts) {
  const max = Math.max(0, ...counts);
  return counts.map(n => (max ? n / max : 0));
}

/** Vorlesetext der Balken: "Lernstand: Fach 1: 4 Karten, Fach 2: 0 Karten, …" */
export const boxAria = counts => `Lernstand: ${counts.map((n, k) => `Fach ${k + 1}: ${n} ${n === 1 ? "Karte" : "Karten"}`).join(", ")}`;

/** Zeile unter "Üben": faellige Karten zuerst, sonst freies Ueben ohne Planaenderung */
export function practiceLine(due) {
  const n = Number(due) || 0;
  return n === 1 ? "Zuerst die fällige Karte" : n > 1 ? `Zuerst die ${n} fälligen Karten` : "Frei üben, der Plan bleibt";
}

/** Was "Üben" auf einer Kachel startet: "review" (heute faellige Karten, Leitner) oder "free" (Trainer, Plan bleibt) */
export const practiceMode = s => ((Number(s?.due) || 0) > 0 ? "review" : "free");

/** Summen fuer die Kopfzeile: Stapel, Karten, heute faellig */
export function stackTotals(stacks) {
  return (stacks || []).reduce((t, s) => ({ stacks: t.stacks + 1, cards: t.cards + (Number(s.cards) || 0), due: t.due + (Number(s.due) || 0) }), { stacks: 0, cards: 0, due: 0 });
}

/** Segmente des Wochenfilters: Alle, Allgemein, W1 … Wn; `current` null = Alle */
export const weekSegments = (weeks, current) => [[null, "Alle"], [GENERAL_WEEK, "Allgemein"], ...weeks.map(w => [w, `W${w}`])]
  .map(([value, label]) => ({ value, label, on: current === value }));

/** "Karte 2 von 7" (Position 0-basiert, am Ende die letzte) */
export const cardOf = (position, total) => `Karte ${Math.min(position + 1, total)} von ${total}`;

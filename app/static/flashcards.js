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

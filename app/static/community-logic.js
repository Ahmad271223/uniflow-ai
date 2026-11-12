// Community-Seite (Kanal nach Lehrwoche, Diskussion, Dokumente) ohne DOM: Einordnung der Blaetter, Wochen und Karten,
// Listen, Filter und Texte. Gegenstueck zu CommunityChannelView.swift / CommunitySpacePage.swift auf dem iPad; laeuft
// auch unter Node (tests/js/community-logic.test.mjs).

// ---------------------------------------------------------------- Art eines Blatts

/** Reihenfolge = Reihenfolge der Karten in einer Woche (CommunityChannelKind). */
export const KINDS = {
  vorlesung: { order: 0, title: "Vorlesung", icon: "book", tone: "blue" },
  hoersaaluebung: { order: 1, title: "Hörsaalübung", icon: "columns", tone: "violet" },
  uebung: { order: 2, title: "Übung", icon: "pencil", tone: "green" },
  gruppenuebung: { order: 3, title: "Gruppenübung", icon: "users", tone: "teal" },
  tutorium: { order: 4, title: "Tutorium", icon: "graduation", tone: "orange" },
  klausur: { order: 5, title: "Klausur", icon: "exam", tone: "red" },
  notizen: { order: 6, title: "Eigene Notizen", icon: "note", tone: "butter" },
};

/** Bezeichnung wie "Gruppenübung", "Altklausur", "Lösung" (auch Freitext) -> Art; null = nichts erkannt. */
export function kindFromLabel(raw) {
  const l = String(raw ?? "").toLowerCase();
  if (!l) return null;
  const has = (...w) => w.some(x => l.includes(x));
  if (has("klausur", "kurztest", "probeklausur")) return "klausur";
  if (has("gruppenübung", "gruppenuebung")) return "gruppenuebung";
  if (has("hörsaal", "hoersaal", "zentralübung", "zentraluebung")) return "hoersaaluebung";
  if (has("tutorium", "tutorien")) return "tutorium";
  if (has("übung", "uebung", "lösung", "loesung", "übungsblatt", "aufgabenblatt")) return "uebung";
  if (has("vorlesung", "folien", "skript", "mitschrift")) return "vorlesung";
  return null;
}
export function kindFromType(type) {
  return ({ vorlesung: "vorlesung", skript: "vorlesung", uebung: "uebung", loesung: "uebung", klausur: "klausur" })[type] || null;
}
/** Einordnung: zuerst die eigene Datei (sub_label, sonst doc_type), sonst der Titel; sagt die Datei nur "Übung", der Titel aber
 *  Gruppen-, Hörsaalübung oder Tutorium, gilt das genauere; nichts erkannt = eigene Notizen. */
export function classify({ subLabel, docType, title }) {
  const fromFile = kindFromLabel(subLabel) || kindFromType(docType);
  const fromTitle = kindFromLabel(title);
  if (fromFile === "uebung" && ["hoersaaluebung", "gruppenuebung", "tutorium"].includes(fromTitle)) return fromTitle;
  return fromFile || fromTitle || "notizen";
}

// ---------------------------------------------------------------- Kanal: Blaetter, Wochen

/** Titel zum Vergleichen (wie die Dateien des Moduls: ohne Endung, kleingeschrieben, Leerraum zusammengefasst). */
export const titleKey = t => String(t ?? "").replace(/\.pdf$/i, "").replace(/\s+/g, " ").trim().toLowerCase();
export const personName = s => String(s?.display_name || s?.pseudonym || "").trim() || "Anonym";

/** Datei aus dem Moduldetail (`/api/modules/{id}`, Feld files bzw. Wochengruppen) fuer den Kanal. */
export function channelFile(f) {
  if (!f || f.id == null) return null;
  const name = String(f.name ?? "");
  return { id: f.id, title: f.ai_title || f.title || name, subLabel: f.sub_label || null, docType: f.doc_type || null, fingerprint: f.content_sha256 || "",
           version: String(f.edited_at || f.chdate || ""), isPDF: !name || /\.pdf$/i.test(name) };
}

/** Blaetter je Lehrwoche aus den Wochen des Moduls (Vorlesungen, Übungen, Skripte, Klausuren; ohne fertige Lösungen und
 *  Sonstiges). Negative Wochen (vor/nach dem Semester) gelten als "ohne Lehrwoche". */
export function skeleton(weeks) {
  const out = [];
  for (const w of weeks || []) for (const g of ["vorlesungen", "uebungen", "skripte", "klausuren"]) for (const f of w[g] || []) {
    const file = channelFile(f); if (file) out.push({ file, week: Math.max(0, w.week | 0) });
  }
  return out;
}

/** Eigene Dateien des Moduls nach Fingerabdruck und Titel (alle Gruppen, mit Lehrwoche) und die Blätter je Woche für
 *  `buildChannel`. Eine geteilte Lösung findet ihr Blatt über den Fingerabdruck der PDF, sonst über den Titel. */
export function fileIndex(weeks) {
  const byFp = new Map(), byTitle = new Map();
  for (const w of weeks || []) for (const g of ["vorlesungen", "uebungen", "skripte", "klausuren", "loesungen", "sonstiges"]) for (const f of w[g] || []) {
    const file = channelFile(f); if (!file) continue;
    file.week = Math.max(0, w.week | 0);
    if (file.fingerprint && !byFp.has(file.fingerprint)) byFp.set(file.fingerprint, file);
    const t = titleKey(file.title); if (t && !byTitle.has(t)) byTitle.set(t, file);
  }
  const skeletonItems = skeleton(weeks).map(({ file, week }) => ({ file: { ...file, week }, week }));
  return { skeletonItems, fileFor: s => (s.fingerprint && byFp.get(s.fingerprint)) || byTitle.get(titleKey(s.title)) || null };
}

/** Beschriftung einer Woche aus den Wochen des Moduls ("Woche 3 · 28.10.–01.11."), sonst "Woche 3". */
export function weekLabel(week, weeks = []) {
  if (!week) return "Ohne Lehrwoche";
  return (weeks.find(w => w.week === week)?.label) || `Woche ${week}`;
}

/** Lösungen zu Blättern bündeln (gleicher Fingerabdruck oder gleicher Titel = dasselbe Blatt), nach Lehrwoche ordnen (ohne
 *  Woche zuletzt), in der Woche nach Art und Titel. `fileFor(solution)` liefert die eigene Datei {id, title, subLabel, docType,
 *  week?}; Blätter des Moduls ohne geteilte Notizen stehen trotzdem in ihrer Woche (`skeletonItems`). */
export function buildChannel(list, { fileFor = () => null, skeletonItems = [] } = {}) {
  const groups = [], byPrint = new Map(), byTitle = new Map();
  for (const s of list || []) {
    const t = titleKey(s.title);
    const hit = (s.fingerprint ? byPrint.get(s.fingerprint) : undefined) ?? (t ? byTitle.get(t) : undefined);
    const i = hit ?? groups.length;
    if (hit === undefined) groups.push([]);
    groups[i].push(s);
    if (s.fingerprint && !byPrint.has(s.fingerprint)) byPrint.set(s.fingerprint, i);
    if (t && !byTitle.has(t)) byTitle.set(t, i);
  }
  const items = groups.map(people => {
    const own = people.map(fileFor).find(Boolean) || null;
    const title = people.find(p => p.title)?.title || own?.title || "Ohne Titel";
    const weeks = people.map(p => p.week | 0).filter(w => w > 0);
    const sorted = [...people].sort((a, b) => (a.mine === b.mine ? 0 : a.mine ? -1 : 1) || (b.likes | 0) - (a.likes | 0) || String(b.published_at ?? b.created_at).localeCompare(String(a.published_at ?? a.created_at)));
    const first = people[0];
    return { id: first.fingerprint ? `f:${first.fingerprint}` : `t:${titleKey(title)}`, kind: classify({ subLabel: own?.subLabel, docType: own?.docType, title }),
             title, week: weeks.length ? Math.min(...weeks) : (own?.week | 0), people: sorted, file: own };
  });
  const all = [...items], covered = new Set(items.map(i => titleKey(i.title)));
  for (const i of items) if (i.file) covered.add(`id:${i.file.id}`);
  for (const { file, week } of skeletonItems) {
    const t = titleKey(file.title);
    if (!t || covered.has(t) || covered.has(`id:${file.id}`)) continue;
    covered.add(t);
    all.push({ id: `m:${file.id}`, kind: classify({ subLabel: file.subLabel, docType: file.docType, title: file.title }), title: file.title, week, people: [], file });
  }
  const byWeek = new Map();
  for (const it of all) byWeek.set(it.week, [...(byWeek.get(it.week) || []), it]);
  return [...byWeek].map(([week, its]) => ({ week, items: its.sort((a, b) => KINDS[a.kind].order - KINDS[b.kind].order || a.title.localeCompare(b.title, "de", { numeric: true })) }))
    .sort((a, b) => (a.week === 0) - (b.week === 0) || a.week - b.week);
}

export const itemLikes = it => it.people.reduce((n, p) => n + (p.likes | 0), 0);
export const itemComments = it => it.people.reduce((n, p) => n + (p.comments | 0), 0);
/** Jüngste Veröffentlichung zu diesem Blatt. */
export const itemLatest = it => it.people.map(p => String(p.published_at ?? p.created_at ?? "")).reduce((a, b) => (a > b ? a : b), "");
export const itemByline = it => (it.people.length === 1 ? `von ${personName(it.people[0])}` : `${it.people.length} Personen`);

/** Blätter mit geteilten Notizen als Liste: Relevanz (Likes + Kommentare, dann neueste) oder neueste zuerst. */
export function rows(weeks, sort = "relevance") {
  return weeks.flatMap(w => w.items).filter(i => i.people.length).sort((a, b) => {
    if (sort === "relevance" && itemLikes(a) + itemComments(a) !== itemLikes(b) + itemComments(b)) return itemLikes(b) + itemComments(b) - itemLikes(a) - itemComments(a);
    if (itemLatest(a) !== itemLatest(b)) return itemLatest(a) > itemLatest(b) ? -1 : 1;
    return a.title.localeCompare(b.title, "de", { numeric: true });
  });
}
/** Die neuesten geteilten Blätter als eine Reihe (Reiter "Diskussion"). */
export const LATEST_LIMIT = 8;
export const latest = weeks => rows(weeks, "newest").slice(0, LATEST_LIMIT);

/** Von einer Person zur nächsten oder vorherigen (Pfeile, Wischen); an den Enden bleibt es stehen. */
export const step = (i, n, dir) => Math.max(0, Math.min(n - 1, i + dir));

// ---------------------------------------------------------------- Diskussion: Fragen, Filter

/** "newest" = neueste zuerst, "unanswered" = nur Fragen ohne Antwort (CommunityPostFilter). */
export function filterPosts(questions, filter = "newest") {
  const newest = [...(questions || [])].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)) || String(b.id).localeCompare(String(a.id)));
  return filter === "unanswered" ? newest.filter(q => !isAnswered(q)) : newest;
}
export const isAnswered = q => (q.answers | 0) > 0;
export const FILTERS = { newest: "Neueste", unanswered: "Unbeantwortet" };

// ---------------------------------------------------------------- Texte

export const plural = (n, one, many) => (n === 1 ? `1 ${one}` : `${n} ${many}`);
export const likesText = n => plural(n, "Like", "Likes");
export const commentsText = n => plural(n, "Kommentar", "Kommentare");
export const repliesText = n => (n === 1 ? "1 Antwort" : `${n} Antworten`);
export const documentsLabel = n => `Dokumente (${n})`;
export const weekDetail = (sheets, shared) => { const s = sheets === 1 ? "1 Blatt" : `${sheets} Blätter`; return shared === 0 || shared === sheets ? s : `${s} · ${shared} mit Notizen`; };
export const itemDetail = (it, discussion = false) => {
  if (!it.people.length) return "Noch niemand geteilt";
  const parts = [plural(it.people.length, "Person", "Personen")];
  if (discussion) parts.push(commentsText(itemComments(it)));
  return parts.join(" · ");
};
export const personDetail = (s, dateText, discussion = true) => {
  const parts = [dateText, plural(s.pages | 0, "Seite", "Seiten")];
  if (discussion) parts.push(likesText(s.likes | 0), commentsText(s.comments | 0));
  return parts.join(" · ");
};
export const TEXTS = {
  joinHint: "Tritt der Community bei, um die geteilten Notizen und die Diskussion zu sehen.",
  discussionNotice: "Alle Mitglieder sehen deine Fragen und Antworten unter deinem Pseudonym.",
  noneShared: "Noch keine geteilten Notizen in dieser Community. Teile deine über „Teilen“ → Community in einer PDF.",
  firstPerson: "Sei die erste Person",
  firstPersonText: "Noch niemand hat Notizen zu diesem Blatt geteilt. Öffne die PDF und teile deine über „Teilen“ → Community.",
  missing: "Diese Community gibt es in deinem Hochschul-Abgleich nicht.",
};

/** "Leibniz Universität Hannover · 24 Mitglieder" (Mitglieder nur, wenn bekannt). */
export function subtitle(space, university) {
  const parts = [];
  if (space.kind === "group") parts.push("Lerngruppe"); else if (university) parts.push(university);
  if (space.current === false && space.kind === "course") parts.push("früheres Semester");
  if (space.members != null) parts.push(space.members === 1 ? "1 Mitglied" : `${space.members} Mitglieder`);
  return parts.join(" · ");
}

/** "gerade eben", "vor 3 Stunden"; älter als eine Woche: das Datum. */
export function relative(iso, now = new Date()) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const sec = (now.getTime() - d.getTime()) / 1000;
  if (sec < 60) return "gerade eben";
  if (sec > 7 * 86400) return d.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", year: "numeric" });
  const rtf = new Intl.RelativeTimeFormat("de", { numeric: "always" });
  return sec < 3600 ? rtf.format(-Math.floor(sec / 60), "minute") : sec < 86400 ? rtf.format(-Math.floor(sec / 3600), "hour") : rtf.format(-Math.floor(sec / 86400), "day");
}
export const initial = name => ([...String(name ?? "").trim()][0] || "?").toUpperCase();
/** Stabile Farbnummer 0..5 zu einem Namen (Avatare). */
export function tint(name) { let h = 0; for (const ch of String(name ?? "")) h = (h * 31 + ch.codePointAt(0)) >>> 0; return h % 6; }

/** Sichtbare Communities in der Liste: Lerngruppen und Module des aktuellen Semesters, mit `showOlder` auch frühere (wie
 *  CommunitySpacesCard auf dem iPad). `older` = Module nur früherer Semester (Zahl am Knopf "Frühere Kurse (N)"). */
export function visibleSpaces(spaces, showOlder) {
  const older = spaces.filter(s => s.kind === "course" && s.current === false);
  return { older, shown: showOlder ? spaces : spaces.filter(s => s.kind === "group" || s.current !== false) };
}

/** Gestaltung der Community-Seite nachladen (community-channel.css); einmal je Seite, ohne DOM ein Nichts. */
export function ensureCss() {
  if (typeof document === "undefined" || document.getElementById("cc-css")) return;
  const l = document.createElement("link"); l.id = "cc-css"; l.rel = "stylesheet"; l.href = "community-channel.css?v=2"; document.head.append(l);
}

// ---------------------------------------------------------------- Lerngruppen ohne Code auf diesem Geraet
/** Lerngruppen, denen das Konto beigetreten ist, deren Beitrittscode dieses Geraet aber nicht kennt (Befund 5.4,
 *  12.11.2026). `rows`: Liste des Dienstes (`/community/communities`), `knownKeys`: Schluessel, die hier schon offen sind.
 *  Der Code liegt nie beim Dienst; die Gruppe erscheint mit "Code hier einmal eingeben". */
export function pendingGroups(rows, knownKeys) {
  const known = new Set(knownKeys || []);
  return [...(rows || [])].filter(r => r && r.kind === "group" && r.joined && !known.has(r.community_key))
    .map(r => ({ key: r.community_key, name: r.name || "Lerngruppe", joined: true, members: r.members ?? 0, solutions: r.solutions ?? 0 }));
}

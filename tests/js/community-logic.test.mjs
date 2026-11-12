// Community-Seite im Browser (app/static/community-logic.js): Einordnung der Blaetter, Kanal nach Lehrwoche, Liste, Filter.
// Gegenstueck zu CommunityChannelAppTests.swift auf dem iPad. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/community-logic.js";

const sol = (id, o = {}) => ({ solution_id: id, fingerprint: o.fp ?? "", title: o.title ?? "", display_name: o.name ?? "", pseudonym: `Studi-${id}`,
                               published_at: o.at ?? "2026-11-01T10:00:00Z", pages: 2, likes: o.likes ?? 0, comments: o.comments ?? 0, mine: !!o.mine, week: o.week ?? 0 });

test("Art eines Blatts: Datei vor Titel, das genauere gewinnt, sonst eigene Notizen", () => {
  assert.equal(L.classify({ subLabel: "Gruppenübung", title: "x" }), "gruppenuebung");
  assert.equal(L.classify({ docType: "klausur", title: "x" }), "klausur");
  assert.equal(L.classify({ docType: "uebung", title: "Hörsaalübung 4" }), "hoersaaluebung");
  assert.equal(L.classify({ docType: "uebung", title: "Tutorium 2" }), "tutorium");
  assert.equal(L.classify({ docType: "skript", title: "x" }), "vorlesung");
  assert.equal(L.classify({ docType: "loesung", title: "x" }), "uebung");
  assert.equal(L.classify({ title: "Altklausur 2019" }), "klausur");
  assert.equal(L.classify({ title: "Meine Mitschrift" }), "vorlesung");
  assert.equal(L.classify({ title: "Irgendwas" }), "notizen");
  assert.equal(L.classify({}), "notizen");
});

const moduleWeeks = [
  { week: 1, label: "Woche 1 · 21.10.–25.10.", vorlesungen: [{ id: "v1", name: "Folien 1.pdf", content_sha256: "a1", sub_label: "Vorlesung", doc_type: "vorlesung" }],
    uebungen: [{ id: "u1", name: "Blatt 1.pdf", content_sha256: "b1", sub_label: "Übung", doc_type: "uebung" }], loesungen: [{ id: "l1", name: "Lösung 1.pdf", content_sha256: "c1", doc_type: "loesung" }], skripte: [], klausuren: [], sonstiges: [] },
  { week: 2, label: "Woche 2 · 28.10.–01.11.", vorlesungen: [{ id: "v2", name: "Folien 2.pdf", doc_type: "vorlesung" }], uebungen: [{ id: "u2", name: "Blatt 2.pdf", content_sha256: "b2", sub_label: "Gruppenübung", doc_type: "uebung" }], skripte: [], klausuren: [], loesungen: [], sonstiges: [] },
  { week: -1, label: "Vor dem Semester", vorlesungen: [], uebungen: [], skripte: [], klausuren: [{ id: "k1", name: "Altklausur.pdf", doc_type: "klausur" }], loesungen: [], sonstiges: [] },
];

test("Kanal zeigt die Lehrwochen des Moduls auch ohne Geteiltes, mit Vorlesung/Übung je Woche", () => {
  const { skeletonItems, fileFor } = L.fileIndex(moduleWeeks);
  const weeks = L.buildChannel([], { fileFor, skeletonItems });
  assert.deepEqual(weeks.map(w => w.week), [1, 2, 0], "Wochen aufsteigend, ohne Woche zuletzt (negative Wochen zaehlen als ohne)");
  assert.deepEqual(weeks[0].items.map(i => [i.kind, i.title]), [["vorlesung", "Folien 1.pdf"], ["uebung", "Blatt 1.pdf"]], "Loesungen sind keine Karten");
  assert.ok(weeks.every(w => w.items.every(i => i.people.length === 0)));
  assert.equal(weeks[1].items[1].kind, "gruppenuebung");
  assert.equal(weeks[2].items[0].kind, "klausur");
  assert.equal(L.weekLabel(2, moduleWeeks), "Woche 2 · 28.10.–01.11.");
  assert.equal(L.weekLabel(7, moduleWeeks), "Woche 7");
  assert.equal(L.weekLabel(0, moduleWeeks), "Ohne Lehrwoche");
  assert.equal(L.weekDetail(3, 2), "3 Blätter · 2 mit Notizen");
  assert.equal(L.weekDetail(1, 1), "1 Blatt");
  assert.equal(L.weekDetail(2, 0), "2 Blätter");
});

test("geteilte Notizen landen ueber den Fingerabdruck in der Woche ihres Blatts und buendeln Personen", () => {
  const { skeletonItems, fileFor } = L.fileIndex(moduleWeeks);
  const list = [sol("a", { fp: "b1", title: "Blatt 1", name: "Lea", likes: 1, at: "2026-11-01T10:00:00Z" }),
                sol("b", { fp: "b1", title: "Übungsblatt 1", name: "Ben", likes: 4, at: "2026-11-02T10:00:00Z" }),
                sol("c", { fp: "b1", title: "Blatt 1", mine: true, at: "2026-10-30T10:00:00Z" }),
                sol("d", { fp: "zz", title: "Eigene Zusammenfassung", name: "Kai" })];
  const weeks = L.buildChannel(list, { fileFor, skeletonItems });
  const w1 = weeks.find(w => w.week === 1);
  const blatt1 = w1.items.find(i => i.file?.id === "u1");
  assert.deepEqual(blatt1.people.map(p => p.solution_id), ["c", "b", "a"], "eigene zuerst, dann meistgelikt");
  assert.equal(blatt1.kind, "uebung");
  assert.equal(w1.items.filter(i => i.file?.id === "u1").length, 1, "das Blatt steht nur einmal da (Fingerabdruck oder Titel)");
  assert.equal(L.itemDetail(blatt1), "3 Personen");
  assert.equal(L.itemDetail(blatt1, true), "3 Personen · 0 Kommentare");
  assert.equal(L.itemDetail({ people: [] }), "Noch niemand geteilt");
  assert.equal(L.itemByline(blatt1), "3 Personen");
  const sonst = weeks.find(w => w.week === 0);
  assert.equal(sonst.items.find(i => i.title === "Eigene Zusammenfassung").kind, "notizen", "ohne Datei und ohne Hinweis im Titel: eigene Notizen, ohne Woche");
  assert.equal(weeks.at(-1).week, 0);
});

test("Liste: Relevanz (Likes + Kommentare) oder neueste zuerst, nur Blaetter mit Notizen; neueste Reihe hoechstens 8", () => {
  const list = [sol("a", { fp: "f1", title: "A", likes: 1, at: "2026-11-03T10:00:00Z" }), sol("b", { fp: "f2", title: "B", likes: 5, at: "2026-11-01T10:00:00Z" }),
                sol("c", { fp: "f3", title: "C", comments: 3, likes: 0, at: "2026-11-02T10:00:00Z" })];
  const weeks = L.buildChannel(list);
  assert.deepEqual(L.rows(weeks, "relevance").map(i => i.title), ["B", "C", "A"]);
  assert.deepEqual(L.rows(weeks, "newest").map(i => i.title), ["A", "C", "B"]);
  assert.equal(L.rows(L.buildChannel([], { skeletonItems: L.fileIndex(moduleWeeks).skeletonItems }), "newest").length, 0, "leere Blaetter stehen nicht in der Liste");
  const many = Array.from({ length: 12 }, (_, i) => sol(`s${i}`, { fp: `f${i}`, title: `T${i}`, at: `2026-11-01T10:${String(i).padStart(2, "0")}:00Z` }));
  assert.equal(L.latest(L.buildChannel(many)).length, L.LATEST_LIMIT);
});

test("Liste der Communities: nur das aktuelle Semester, 'Fruehere Kurse (N)' dahinter, Lerngruppen immer", () => {
  const spaces = [{ key: "a", kind: "course", current: true }, { key: "b", kind: "course", current: false }, { key: "c", kind: "course" }, { key: "g", kind: "group", current: false }, { key: "d", kind: "course", current: false }];
  const hidden = L.visibleSpaces(spaces, false);
  assert.deepEqual(hidden.shown.map(s => s.key), ["a", "c", "g"], "unbekannt gilt als aktuell, frueher ist weg");
  assert.deepEqual(hidden.older.map(s => s.key), ["b", "d"], "die Zahl am Knopf");
  const all = L.visibleSpaces(spaces, true);
  assert.equal(all.shown.length, 5); assert.equal(all.older.length, 2);
  assert.deepEqual(L.visibleSpaces([{ key: "g", kind: "group", current: false }], false).older, [], "Lerngruppen sind nie fruehere Kurse");
});

test("Pfeile: zur naechsten und vorherigen Person, an den Enden Stopp", () => {
  assert.equal(L.step(0, 3, 1), 1); assert.equal(L.step(2, 3, 1), 2); assert.equal(L.step(0, 3, -1), 0); assert.equal(L.step(1, 3, -1), 0);
});

test("Diskussion: Filter Neueste und Unbeantwortet", () => {
  const qs = [{ id: "1", created_at: "2026-11-01T10:00:00Z", answers: 0 }, { id: "2", created_at: "2026-11-03T10:00:00Z", answers: 2 }, { id: "3", created_at: "2026-11-02T10:00:00Z", answers: 0 }];
  assert.deepEqual(L.filterPosts(qs, "newest").map(q => q.id), ["2", "3", "1"]);
  assert.deepEqual(L.filterPosts(qs, "unanswered").map(q => q.id), ["3", "1"]);
  assert.equal(L.repliesText(1), "1 Antwort"); assert.equal(L.repliesText(3), "3 Antworten");
  assert.equal(L.likesText(1), "1 Like"); assert.equal(L.commentsText(0), "0 Kommentare");
});

test("Kopfzeile, Namen, Zeit", () => {
  assert.equal(L.subtitle({ kind: "course", members: 24, current: true }, "Leibniz Universität Hannover"), "Leibniz Universität Hannover · 24 Mitglieder");
  assert.equal(L.subtitle({ kind: "course", members: 1, current: false }, "Uni"), "Uni · früheres Semester · 1 Mitglied");
  assert.equal(L.subtitle({ kind: "group", members: null }, "Uni"), "Lerngruppe");
  assert.equal(L.personName({ display_name: "Lea", pseudonym: "Studi-1" }), "Lea");
  assert.equal(L.personName({ display_name: "", pseudonym: "Studi-1" }), "Studi-1");
  assert.equal(L.personName({}), "Anonym");
  const now = new Date("2026-11-03T12:00:00Z");
  assert.equal(L.relative("2026-11-03T11:59:30Z", now), "gerade eben");
  assert.equal(L.relative("2026-11-03T09:00:00Z", now), "vor 3 Stunden");
  assert.equal(L.relative("2026-11-01T12:00:00Z", now), "vor 2 Tagen");
  assert.match(L.relative("2026-10-01T12:00:00Z", now), /^01\.10\.2026$/);
  assert.equal(L.initial("lea"), "L"); assert.equal(L.initial(""), "?");
  assert.equal(L.tint("Lea"), L.tint("Lea"));
});

test("Lerngruppen eines anderen Geraets: erscheinen ohne Code, nur beigetretene Gruppen (Befund 5.4, 12.11.2026)", () => {
  const rows = [
    { community_key: "k-kurs", kind: "course", name: null, joined: true, members: 9, solutions: 3 },
    { community_key: "k-hier", kind: "group", name: "Mathe-Runde", joined: true, members: 4, solutions: 1 },
    { community_key: "k-dort", kind: "group", name: "Physik-Gruppe", joined: true, members: 2 },
    { community_key: "k-raus", kind: "group", name: "Verlassen", joined: false, members: 5 },
    { community_key: "k-ohne", kind: "group", name: null, joined: true },
  ];
  const out = L.pendingGroups(rows, ["k-kurs", "k-hier"]);
  assert.deepEqual(out.map(g => g.key), ["k-dort", "k-ohne"]);
  assert.deepEqual(out[0], { key: "k-dort", name: "Physik-Gruppe", joined: true, members: 2, solutions: 0 });
  assert.equal(out[1].name, "Lerngruppe");
  assert.deepEqual(L.pendingGroups(new Map(rows.map(r => [r.community_key, r])).values(), []).length, 3, "auch aus einer Map");
  assert.deepEqual(L.pendingGroups(null, null), []);
});

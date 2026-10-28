// Notizen und neue PDF-Fassung (app/static/pdf-version.js, Pruefpunkte 1187–1191).
import { test } from "node:test";
import assert from "node:assert/strict";
import { pageSig, remapToVersion, describe } from "../../app/static/pdf-version.js";

const texts = ["Kapitel 1 Einleitung in die Analysis", "Kapitel 2 Folgen und Grenzwerte", "Kapitel 3 Reihen und Konvergenz", "Kapitel 4 Stetigkeit von Funktionen"];
const sigs = arr => arr.map(pageSig);
const doc = (n = 4) => ({
  version: 2, pageOrder: Array.from({ length: n }, (_, i) => ({ key: "p" + (i + 1), type: "pdf", index: i + 1 })),
  pages: Object.fromEntries(Array.from({ length: n }, (_, i) => ["p" + (i + 1), { objects: [{ id: "n" + (i + 1), type: "stroke", points: [1, 2, 3, 4] }] }])),
});
const info = (t, sha = "neu") => ({ sha256: sha, pageCount: t.length, sigs: sigs(t), sizes: t.map(() => [595, 842]) });
const notesAt = d => d.pageOrder.map(e => [e.type === "pdf" ? e.index : "eigen", (d.pages[e.key].objects[0] || {}).id || "-"]);

test("Signatur: Gross/Klein, Leerzeichen und Satzzeichen egal, kurze Seiten ohne Signatur", () => {
  assert.equal(pageSig("Kapitel 1: Einleitung!"), pageSig("kapitel1einleitung"));
  assert.equal(pageSig("   "), ""); assert.equal(pageSig("Seite 3"), "");
});

test("neu komprimiert, gleicher Text: nichts verschiebt sich (1191)", () => {
  const { doc: d, report } = remapToVersion(doc(), info(texts, "alt"), info(texts));
  assert.deepEqual(notesAt(d), [[1, "n1"], [2, "n2"], [3, "n3"], [4, "n4"]]);
  assert.equal(report.moved.length + report.added.length + report.orphaned.length, 0);
  assert.equal(d.pdf.sha256, "neu");
});

test("Seite vorne eingefuegt: Notizen bleiben bei ihrer logischen Seite (1188)", () => {
  const { doc: d, report } = remapToVersion(doc(), info(texts, "alt"), info(["Deckblatt Wintersemester 2026 Analysis", ...texts]));
  assert.deepEqual(notesAt(d), [[1, "-"], [2, "n1"], [3, "n2"], [4, "n3"], [5, "n4"]]);
  assert.deepEqual(report.added, [1]); assert.equal(report.moved.length, 4);
});

test("Seite entfernt: Notizen werden nicht vernichtet (1189)", () => {
  const { doc: d, report } = remapToVersion(doc(), info(texts, "alt"), info([texts[0], texts[1], texts[3]]));
  assert.deepEqual(notesAt(d), [[1, "n1"], [2, "n2"], ["eigen", "n3"], [3, "n4"]]);
  assert.deepEqual(report.orphaned, [3]);
  const orphan = d.pageOrder[2]; assert.equal(orphan.type, "blank"); assert.deepEqual(orphan.orphanOf, { index: 3, sha256: "alt" });
  assert.match(describe(report), /gibt es nicht mehr/);
});

test("gleiche Seitenzahl, anderer Inhalt auf einer Seite: keine stille Zuordnung (1190)", () => {
  const { doc: d } = remapToVersion(doc(), info(texts, "alt"), info([texts[0], "Kapitel 2 voellig neu geschrieben Beispiele", texts[2], texts[3]]));
  assert.deepEqual(notesAt(d), [[1, "n1"], [2, "-"], ["eigen", "n2"], [3, "n3"], [4, "n4"]], "neue Seite 2 an ihrer Stelle, alte Notizen dahinter auf eigener Seite");
});

test("Scans ohne Text: gleicher Index als unsicher, nie verschwunden", () => {
  const scans = ["", "", ""];
  const { doc: d, report } = remapToVersion(doc(3), info(scans, "alt"), info(["", "", "", ""]));
  assert.deepEqual(notesAt(d), [[1, "n1"], [2, "n2"], [3, "n3"], [4, "-"]]);
  assert.deepEqual(report.uncertain, [1, 2, 3]); assert.deepEqual(report.added, [4]);
});

test("Eigene Seiten und das Original bleiben unberuehrt", () => {
  const d0 = doc(2); d0.pageOrder.splice(1, 0, { key: "b1", type: "blank", template: "grid", w: 595, h: 842 }); d0.pages.b1 = { objects: [{ id: "eigen" }] };
  const before = JSON.stringify(d0);
  const { doc: d } = remapToVersion(d0, info(texts.slice(0, 2), "alt"), info(texts.slice(0, 2)));
  assert.equal(JSON.stringify(d0), before, "Original unveraendert");
  assert.deepEqual(d.pageOrder.map(e => e.key), ["p1", "b1", "p2"]);
});

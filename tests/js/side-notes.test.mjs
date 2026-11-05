// Notizen und Blätter mitschicken (app/static/side-notes.js, 05.11.2026), ohne Browser: dieselben Fälle wie
// SideNotesTests auf dem iPad (Einflechten hinter Folie und Seitennotizen, leere Blattseiten, unverknüpfte ans Ende,
// Schlüsselkollision, Folie zu Notizseiten) und die Auswahl im PDF-Export und im Dialog "Lösung teilen".
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as SN from "../../app/static/side-notes.js";

const stroke = id => ({ id, type: "stroke", tool: "pen", color: "#000", width: 2, points: [0, 0, 10, 10] });
// Dokument: Folien p1..p4, Seitennotiz b1 hinter p2 (beschrieben), leere b2 hinter p3; Blatt nb1 mit drei Seiten
function fixture() {
  const main = {
    version: 2,
    pageOrder: [{ key: "p1", type: "pdf", index: 1 }, { key: "p2", type: "pdf", index: 2 }, { key: "b1", type: "blank", template: "lined", w: 595, h: 842 },
      { key: "p3", type: "pdf", index: 3 }, { key: "b2", type: "blank", template: "blank" }, { key: "p4", type: "pdf", index: 4 }],
    pages: { p1: { objects: [] }, p2: { objects: [stroke("a")] }, b1: { objects: [stroke("b")] }, p3: { objects: [] }, b2: { objects: [] }, p4: { objects: [] } },
    sideSheets: [{ file: "nb1", pages: { s1: "p4", s2: "b2", s9: "gone" } }, { file: "nb1", pages: { s1: "p1" } }, { file: "", pages: {} }, { nope: 1 }],
  };
  const sheet = {
    version: 2,
    pageOrder: [{ key: "s1", type: "blank", template: "grid", w: 500, h: 700 }, { key: "s2", type: "blank" }, { key: "s3", type: "blank" }, { key: "s9", type: "blank" }, { key: "s4", type: "blank" }],
    pages: { s1: { objects: [stroke("c")], pkdrawing: "AAA" }, s2: { objects: [stroke("d")] }, s3: { objects: [] }, s9: { objects: [stroke("e")] }, s4: { objects: [stroke("f")] } },
  };
  return { main, sheets: [{ fileId: "nb1", doc: sheet }] };
}
const keys = d => d.pageOrder.map(e => e.key);

test("Verknüpfungen: erste gilt, unbrauchbare übergangen, Blätter in Reihenfolge", () => {
  const { main } = fixture();
  assert.deepEqual(SN.links(main), { nb1: { s1: "p4", s2: "b2", s9: "gone" } });
  assert.deepEqual(SN.sheetFileIDs(main), ["nb1"]);
  assert.deepEqual(SN.links({}), {}); assert.deepEqual(SN.sheetFileIDs({ sideSheets: "x" }), []);
  assert.equal(SN.isSheetKey("sn-s1"), true); assert.equal(SN.isSheetKey("sn12-s1"), true);
  assert.equal(SN.isSheetKey("snack"), false); assert.equal(SN.isSheetKey("nb-s1"), false);
});

test("Einflechten: Blattseite hinter Folie und ihren Seitennotizen, leere weg, unverknüpfte ans Ende", () => {
  const { main, sheets } = fixture();
  const d = SN.interleaved(main, sheets);
  assert.deepEqual(keys(d), ["p1", "p2", "b1", "p3", "b2", "sn-s2", "p4", "sn-s1", "sn-s9", "sn-s4"]);
  const s1 = d.pageOrder.find(e => e.key === "sn-s1");
  assert.equal(s1.sideOf, "p4"); assert.equal(s1.sideFile, "nb1"); assert.equal(s1.template, "grid"); assert.equal(s1.w, 500);
  assert.equal("sideOf" in d.pageOrder.find(e => e.key === "sn-s9"), false, "Seite gibt es nicht mehr");
  assert.equal(d.pages["sn-s1"].pkdrawing, undefined); assert.equal(d.pages["sn-s1"].objects.length, 1);
  assert.equal(main.pageOrder.length, 6, "Original unverändert"); assert.equal(main.pages["sn-s1"], undefined);
  const all = SN.interleaved(main, sheets, { skipEmptySheetPages: false });
  assert.ok(keys(all).includes("sn-s3"));
});

test("Leere Seitennotizen weglassen, ihre Blattseiten bleiben bei der Folie", () => {
  const { main, sheets } = fixture();
  const d = SN.interleaved(main, sheets, { skipEmptyNotePages: true });
  assert.deepEqual(keys(d), ["p1", "p2", "b1", "p3", "sn-s2", "p4", "sn-s1", "sn-s9", "sn-s4"]);
  // reines Notizbuch (keine PDF-Seite): leere Seiten bleiben
  const nb = { pageOrder: [{ key: "b1", type: "blank" }, { key: "b2", type: "blank" }], pages: { b1: { objects: [] }, b2: { objects: [] } } };
  assert.deepEqual(keys(SN.interleaved(nb, [], { skipEmptyNotePages: true })), ["b1", "b2"]);
});

test("Schlüsselkollision: sn2-…", () => {
  const { main, sheets } = fixture();
  main.pageOrder.push({ key: "sn-s1", type: "blank" }); main.pages["sn-s1"] = { objects: [] };
  const d = SN.interleaved(main, sheets);
  assert.ok(keys(d).includes("sn2-s1")); assert.equal(d.pages["sn-s1"].objects.length, 0, "eigene Seite bleibt");
});

test("Notizseiten einer Seite, Anzahl, Folie und Bezeichnungen", () => {
  const { main, sheets } = fixture(); const d = SN.interleaved(main, sheets);
  assert.deepEqual(SN.notePages(d, "p2"), ["b1"]);
  assert.deepEqual(SN.notePages(d, "p3"), ["b2", "sn-s2"]);
  assert.deepEqual(SN.notePages(d, "b2"), ["sn-s2"], "Leerseite: nur ihre Blattseiten");
  assert.deepEqual(SN.notePages(d, "p4"), ["sn-s1"], "unverknüpfte gehören keiner Folie");
  assert.deepEqual(SN.notePages(d, "x"), []);
  assert.equal(SN.notePageCount(d), 6);
  assert.deepEqual(SN.notePageKeys(d), ["b1", "b2", "sn-s2", "sn-s1", "sn-s9", "sn-s4"]);
  assert.equal(SN.slideOf(d, "sn-s2"), "p3"); assert.equal(SN.slideOf(d, "p2"), "p2"); assert.equal(SN.slideOf(d, "sn-s9"), null);
  const lab = k => SN.noteLabel(d, keys(d).indexOf(k));
  assert.equal(lab("p2"), "PDF-Seite 2"); assert.equal(lab("b1"), "Notiz zu Folie 2"); assert.equal(lab("sn-s2"), "Blatt zu Folie 3"); assert.equal(lab("sn-s9"), "Blatt");
  assert.equal(SN.noteLabel({ pageOrder: [{ key: "b0", type: "blank" }] }, 0), "Eigene Seite");
});

test("Notizseite bringt ihre Folie mit (withSlides), unverknüpfte nicht, nur erlaubte Folien", () => {
  const { main, sheets } = fixture(); const d = SN.interleaved(main, sheets);
  assert.deepEqual(SN.withSlides(d, ["b1", "sn-s2", "sn-s9"]), ["b1", "sn-s2", "sn-s9", "p2", "p3"]);
  assert.deepEqual(SN.withSlides(d, ["sn-s1"], k => k !== "p4"), ["sn-s1"]);
  assert.deepEqual(SN.withSlides(d, ["p2", "b1"]), ["p2", "b1"]);
});

test("PDF-Export: ganzes Dokument ohne leere Seitennotizen, diese Seite mit ihren Notizseiten, aus = ohne Blätter", async () => {
  const { main, sheets } = fixture(); const calls = [];
  const fetchJson = async u => { calls.push(u); if (u.includes("nb1")) return { data: sheets[0].doc, version: 3 }; throw new Error("404"); };
  const all = await SN.exportPlan(main, { pageIdx: null, includeSideNotes: true, fetchJson });
  assert.deepEqual(all.idxs.map(i => all.doc.pageOrder[i].key), ["p1", "p2", "b1", "p3", "sn-s2", "p4", "sn-s1", "sn-s9", "sn-s4"]);
  assert.equal(all.notes, 5); assert.deepEqual(calls, ["/api/files/nb1/annotations"]);
  const page = await SN.exportPlan(main, { pageIdx: [3], includeSideNotes: true, fetchJson });   // Seite 4 der Seitenleiste = p3
  assert.deepEqual(page.idxs.map(i => page.doc.pageOrder[i].key), ["p3", "b2", "sn-s2"]);
  const plain = await SN.exportPlan(main, { pageIdx: [3], includeSideNotes: false, fetchJson });
  assert.deepEqual(plain.idxs.map(i => plain.doc.pageOrder[i].key), ["p3"]);
  const noSheets = await SN.exportPlan(main, { pageIdx: null, includeSideNotes: false, fetchJson });
  assert.deepEqual(noSheets.idxs.map(i => noSheets.doc.pageOrder[i].key), ["p1", "p2", "b1", "p3", "p4"]);
  const broken = await SN.exportPlan(main, { includeSideNotes: true, fetchJson: async () => { throw new Error("offline"); } });
  assert.equal(broken.doc.pageOrder.length, 5, "Blatt fehlt: Export geht trotzdem");
  const range = await SN.exportPlan(main, { pageIdx: [1, 2], includeSideNotes: true, fetchJson });
  assert.deepEqual(range.idxs.map(i => range.doc.pageOrder[i].key), ["p2", "b1"], "b1 ist gewählt und Notizseite von p2: nur einmal");
});

test("Lösung teilen: Vorauswahl, Schalter Notizen und Blätter, Haken an Folie und Notizseite", () => {
  const { main, sheets } = fixture(); const d = SN.interleaved(main, sheets);
  const on = SN.initialShareSelection(d, true);
  assert.deepEqual([...on].sort(), ["b1", "p2", "p3", "p4", "sn-s1", "sn-s2", "sn-s4", "sn-s9"].sort(), "Notizseiten mit ihrer Folie, leere b2 nicht");
  const off = SN.initialShareSelection(d, false);
  assert.deepEqual([...off], ["p2"]);
  assert.deepEqual([...SN.setShareNotes(d, on, false)].sort(), ["p2", "p3", "p4"]);
  assert.deepEqual([...SN.setShareNotes(d, off, true)].sort(), [...on].sort());
  let s = SN.toggleShare(d, new Set(), "sn-s2", true); assert.deepEqual([...s].sort(), ["p3", "sn-s2"]);
  s = SN.toggleShare(d, s, "p3", false); assert.deepEqual([...s], [], "Folie abwählen nimmt ihre Notizseiten heraus");
  s = SN.toggleShare(d, new Set(["p2", "b1"]), "b1", false); assert.deepEqual([...s], ["p2"]);
});

test("Getippter Notiztext für die KI-Hilfe (own_notes), höchstens 4000 Zeichen", () => {
  const doc = { pages: { b1: { objects: [{ type: "text", text: "  Merke: λ ist Eigenwert " }, stroke("x"), { type: "text", text: " " }] }, sn: { objects: [{ type: "text", text: "Blatt" }] } } };
  assert.equal(SN.typedText(doc, ["b1", "sn", "nix"]), "Merke: λ ist Eigenwert\nBlatt");
  assert.equal(SN.typedText({ pages: { a: { objects: [{ type: "text", text: "x".repeat(5000) }] } } }, ["a"]).length, SN.AI_NOTES_CHARS);
});

test("Eingefügte Bild-/PDF-Seiten sind keine Notizseiten und werden nie vorgewählt", () => {
  const d = { pageOrder: [{ key: "p1", type: "pdf", index: 1 }, { key: "a1", type: "asset", index: 1, assetUrl: "/x.pdf" }, { key: "b1", type: "blank" }],
    pages: { p1: { objects: [] }, a1: { objects: [stroke("q")] }, b1: { objects: [stroke("r")] } } };
  assert.deepEqual(SN.notePageKeys(d), ["b1"]); assert.equal(SN.notePageCount(d), 1);
  assert.deepEqual(SN.notePages(d, "p1"), ["b1"]);
  assert.equal(SN.noteLabel(d, 1), "Eingefügte Seite");
  assert.deepEqual([...SN.initialShareSelection(d, true)].sort(), ["b1", "p1"]);
  assert.deepEqual([...SN.initialShareSelection(d, false)], []);
  assert.deepEqual(SN.interleaved(d, [{ fileID: "x", document: { pageOrder: [{ key: "s", type: "blank" }], pages: { s: { objects: [stroke("z")] } } } }]).pageOrder.map(e => e.key),
    ["p1", "a1", "b1", "sn-s"], "Blatt auch als {fileID, document}");
});

test("Editor und Community binden das Mitschicken ein", () => {
  const ed = readFileSync(new URL("../../app/static/editor.js", import.meta.url), "utf8");
  assert.match(ed, /import\("\.\/side-notes\.js\?v=\d+"\)/); assert.match(ed, /Notizen und Blätter mitschicken/);
  const com = readFileSync(new URL("../../app/static/editor-community.js", import.meta.url), "utf8");
  assert.match(com, /from "\.\/side-notes\.js\?v=\d+"/); assert.match(com, /data-f="notes"/); assert.match(com, /SN\.withSlides\(doc/);
});

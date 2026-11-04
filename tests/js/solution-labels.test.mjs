// Seitentitel geteilter Loesungen beim Empfaenger (05.11.2026): Notizseiten heissen nach ihrer Folie, wie in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pageTitle } from "../../app/static/solution-labels.js";

test("Folie, Seitennotiz und Blattseite dahinter, Seite vor der ersten Folie", () => {
  const pages = [{ key: "b0" }, { key: "p2", pdfIndex: 2 }, { key: "bx" }, { key: "p4", pdfIndex: 4 }, { key: "sn-b1" }, { key: "sn2-b1" }];
  assert.deepEqual(pages.map((_, i) => pageTitle(pages, i)),
    ["Eigene Seite", "PDF-Seite 2", "Notiz zu Folie 2", "PDF-Seite 4", "Notiz zu Folie 4", "Notiz zu Folie 4"]);
  assert.equal(pageTitle(pages, 99), "Eigene Seite");
  assert.equal(pageTitle(null, 0), "Eigene Seite");
});

test("Community-Kanal und Loesung daneben benutzen die Titel", () => {
  for (const f of ["community-channel.js", "community-editor-tools.js"]) {
    const src = readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
    assert.match(src, /from "\.\/solution-labels\.js\?v=\d+"/, f);
    assert.doesNotMatch(src, /"Eigene Seite der Lösung"/, f);
  }
});

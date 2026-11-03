// Dokument-Tabs und Abgleich-Anzeige (03.11.2026, wie Views.swift 1a82c70 und HildesheimStatusLine 6954835 auf dem iPad):
// letzter Tab zu fuehrt in die Bibliothek, leere Seite "Dokument wählen"; die Anzeige oben nur bei Neuem oder Fehlern.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { afterCloseTab, emptyDocHtml, EMPTY_DOC } from "../../app/static/doc-nav.js";
import { chipState, hasNews, hasProblem } from "../../app/static/sync-chip.js";
import { icon } from "../../app/static/icons.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = f => readFileSync(join(root, f), "utf8");
const esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");

test("letzter Tab zu: zurueck in die Bibliothek", () => {
  assert.equal(afterCloseTab([], "a", "a"), "#/files", "kein Tab mehr");
  assert.equal(afterCloseTab([{ id: "b" }, { id: "c" }], "c", "c"), "#/doc/c", "der zuletzt geoeffnete uebrige");
  assert.equal(afterCloseTab([{ id: "b" }], "a", "a"), "#/doc/b");
  assert.equal(afterCloseTab([{ id: "b" }], "b", "a"), null, "ein anderer Tab: auf der Seite bleiben");
  assert.equal(afterCloseTab([], "b", "a"), null, "ein anderer Tab, auch wenn keiner uebrig ist, ist nicht der offene");
  assert.equal(afterCloseTab([{ id: "x y" }], "a", "a"), "#/doc/x%20y");
});

test("leere Seite: Titel, Hinweis und Weg zur Bibliothek wie auf dem iPad", () => {
  const swift = read("apps/apple/UniFlow/Views/Views.swift");
  assert.ok(swift.includes(`Label("${EMPTY_DOC.title}"`), "Titel wie in Views.swift");
  assert.ok(swift.includes(`Button("${EMPTY_DOC.action}")`), "Knopf wie in Views.swift");
  const html = emptyDocHtml(icon, esc);
  assert.match(html, /<b>Dokument wählen<\/b>/);
  assert.match(html, /href="#\/files"[^>]*>[\s\S]*Zur Bibliothek/);
  assert.match(html, new RegExp(EMPTY_DOC.text));
  assert.match(emptyDocHtml(icon, esc, true), /Dieses Dokument gibt es nicht mehr\./);
  assert.ok(!emptyDocHtml(icon, esc, true).includes(EMPTY_DOC.text));
});

test("views-doc.js nutzt beides", () => {
  const src = read("app/static/views-doc.js");
  assert.match(src, /afterCloseTab\(docTabs\.list, activeId, id\)/);
  assert.match(src, /if \(!id\) \{ view\.innerHTML = emptyDocHtml\(icon, esc\)/);
  assert.match(src, /catch \{ closeTab\(id\); view\.innerHTML = emptyDocHtml\(icon, esc, true\)/);
});

const log = (o = {}) => ({ ok: 1, new_files: 0, message: "0 neue/geaenderte Dateien", finished_at: "2026-11-03T14:05:00", ...o });

test("Abgleich-Anzeige: ruhig, wenn nichts zu sagen ist", () => {
  assert.equal(chipState(undefined, "14:05"), null, "noch kein Abgleich");
  assert.equal(chipState(log(), "14:05"), null);
  // Meldungen der Hochschulen ohne Neues (HildesheimSync.quiet auf dem iPad, hier die Python-Fassung)
  const quiet = "0 neue/geaenderte Dateien aus 6 Learnweb-Kursen, Fristen: 4 (0 neu, 0 entfernt), Ankuendigungen: 0 neu (0 mit Termin), 0 entfernt, Stundenplan: 0 neu, 12 unveraendert, 0 entfernt";
  assert.equal(chipState(log({ message: quiet }), "14:05"), null);
  assert.equal(hasNews(log({ message: quiet })), false);
  assert.equal(hasProblem(log({ message: quiet })), false);
  assert.equal(chipState(log({ message: "0 neue/geaenderte Dateien, 0 Stundenplan-Termine" }), "14:05"), null);
});

test("Abgleich-Anzeige: Neues", () => {
  assert.deepEqual(chipState(log({ new_files: 3, message: "3 neue/geaenderte Dateien" }), "14:05"),
    { tone: "ok", icon: "check", text: "Zuletzt synchronisiert: 14:05 · 3 neue Dateien", title: "3 neue/geaenderte Dateien" });
  assert.match(chipState(log({ new_files: 1 }), "14:05").text, /· 1 neue Datei$/);
  assert.match(chipState(log({ message: "0 neue/geaenderte Dateien, 2 Stundenplan-Termine" }), "08:00").text, /· Neues$/);
  assert.match(chipState(log({ message: "0 neue/geaenderte Dateien, 1 Serien entfernt (nicht in deinem Stud.IP-Kalender)" }), "08:00").text, /· Neues$/);
  assert.match(chipState(log({ message: "Fristen: 4 (1 neu, 0 entfernt)" }), "08:00").text, /· Neues$/);
  assert.match(chipState(log({ message: "Ankuendigungen: 0 neu (0 mit Termin), 2 entfernt" }), "08:00").text, /· Neues$/);
});

test("Abgleich-Anzeige: Fehler", () => {
  const failed = chipState(log({ ok: 0, message: "FEHLER: Anmeldung bei Stud.IP noetig" }), "14:05");
  assert.equal(failed.tone, "bad");
  assert.equal(failed.icon, "alert");
  assert.equal(failed.text, "Letzter Abgleich mit Problem (14:05)");
  assert.equal(failed.title, "FEHLER: Anmeldung bei Stud.IP noetig");
  assert.equal(chipState(log({ message: "3 neue/geaenderte Dateien, Learnweb-Fristen: FEHLER Kalender gesperrt", new_files: 3 }), "14:05").tone, "bad", "Teilfehler geht vor Neuem");
});

test("app.js zeichnet die Anzeige nur mit chipState", () => {
  const src = read("app/static/app.js");
  assert.match(src, /sync-chip\.js\?v=\d+/);
  assert.match(src, /chipState\(l, /);
  assert.doesNotMatch(src, /Noch kein Sync/);
});

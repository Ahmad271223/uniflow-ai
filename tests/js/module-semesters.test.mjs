// Module je Semester und Hinweis zum Abgleich (app/static/module-semesters.js, Wunsch des Inhabers 05.11.2026): dieselben
// Faelle wie apps/apple/UniFlowTests/SyncOrderAppTests.swift (Gruppen, Zahlen, Hinweis "(3 von 6)").
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as MS from "../../app/static/module-semesters.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = f => readFileSync(join(root, f), "utf8");

const mods = [{ id: 1, name: "Datenstrukturen" }, { id: 2, name: "Bachelorarbeit" }, { id: 3, name: "Regelungstechnik" }, { id: 4, name: "Eigenes Modul" }];
const item = (name, o = {}) => ({ name, module_id: null, color: null, course_ids: ["c-" + name], courses: 1, files: 0, downloaded: 0, loaded: false, ...o });
const sem = {
  current: { key: [2026, 2], label: "WiSe 2026/27", module_ids: [1, 4], count: 2 },
  upcoming: [{ key: [2027, 1], label: "SoSe 2027", module_ids: [2], items: [item("Bachelorarbeit", { module_id: 2 })], count: 1 }],
  older: [
    { key: [2026, 1], label: "SoSe 2026", count: 1, files: 3, downloaded: 3, loaded: true, items: [item("Regelungstechnik", { module_id: 3, files: 3, downloaded: 3, loaded: true })] },
    { key: [2025, 2], label: "WiSe 2025/26", count: 2, files: 0, downloaded: 0, loaded: false, items: [item("Signale und Systeme"), item("Mathe <III>")] },
  ],
  status: { current: { ready: true }, older: { running: true, total: 6, done: 3 }, hint: "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)" },
};

test("Module werden auf aktuelles, naechstes und fruehere Semester verteilt", () => {
  const s = MS.splitModules(mods, sem);
  assert.deepEqual(s.current.map(m => m.id), [1, 4], "eigene Module ohne Semester bleiben im aktuellen");
  assert.deepEqual(s.upcoming.map(g => [g.label, g.mods.map(m => m.id)]), [["SoSe 2027", [2]]]);
  assert.deepEqual(s.older.map(g => g.label), ["SoSe 2026", "WiSe 2025/26"], "neuestes zuerst wie geliefert");
  assert.equal(s.label, "WiSe 2026/27");
  const plain = MS.splitModules(mods, null);
  assert.equal(plain.current.length, 4, "ohne Semesterdaten alles wie bisher");
  assert.equal(MS.currentHeadHtml(plain), "", "ohne andere Semester keine Ueberschrift");
  assert.match(MS.currentHeadHtml(s), /Aktuelles Semester · WiSe 2026\/27 <span class="muted small">2 Module<\/span>/);
});

test("Fruehere Semester sind zugeklappt, mit Zahlen, und klappen auf", () => {
  const closed = MS.olderHtml(sem.older);
  assert.match(closed, /<h2>Frühere Semester<\/h2>/);
  assert.match(closed, /<b>SoSe 2026<\/b><span class="muted small">1 Modul · 3 Dateien<\/span>/);
  assert.match(closed, /<b>WiSe 2025\/26<\/b><span class="muted small">2 Module · Dateien noch nicht geladen<\/span>/);
  assert.equal((closed.match(/aria-expanded="false"/g) || []).length, 2);
  assert.ok(!closed.includes("older-courses"), "zugeklappt: keine Module sichtbar");
  const open = MS.olderHtml(sem.older, new Set(["WiSe 2025/26"]));
  assert.match(open, /href="#\/files\?path=cc-Signale%20und%20Systeme"/, "ohne Modul: Kursordner in der Bibliothek");
  assert.match(open, /Mathe &lt;III&gt;/);
  assert.match(MS.olderHtml(sem.older, new Set(["SoSe 2026"])), /href="#\/modules\/3"/, "echtes Modul oeffnet das Modul");
  assert.equal(MS.olderHtml([]), "");
  assert.equal(MS.countLabel({ count: 2, files: 10, downloaded: 4 }), "2 Module · 4 von 10 Dateien geladen");
});

test("Hinweis zum Abgleich", () => {
  assert.match(MS.hintHtml(sem.status), /role="status"[^>]*>.*Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen \(3 von 6\)/s);
  assert.equal(MS.stillLoading(sem.status), true);
  assert.equal(MS.stillLoading({ current: { ready: true }, older: { running: false } }), false);
  assert.equal(MS.stillLoading({ current: { ready: false }, older: {} }), true, "erster Abgleich laeuft");
  assert.equal(MS.hintHtml({ current: { ready: true }, older: {}, hint: null }), "");
  assert.equal(MS.hintHtml(null), "");
});

test("die Seite ist angeschlossen und die Texte gleichen dem iPad", () => {
  const misc = read("app/static/views-misc.js");
  assert.match(misc, /module-semesters\.js\?v=\d+/);
  assert.match(misc, /api\("\/module-semesters"\)/);
  assert.match(misc, /MS\.olderHtml\(split\.older, open\)/);
  const swift = read("apps/apple/UniFlow/Views/Modules/ModulesPage.swift");
  for (const t of ["Frühere Semester", "Aktuelles Semester · ", "Nächstes Semester · ", "Dateien noch nicht geladen"]) assert.ok(swift.includes(t), `Swift: ${t}`);
  const core = read("apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Sync/SyncOrder.swift");
  for (const t of ["Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (", "Aktuelles Semester wird geladen …"]) assert.ok(core.includes(t), `Kern: ${t}`);
});

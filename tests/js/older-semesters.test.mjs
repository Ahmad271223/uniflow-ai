// Fruehere Semester (app/static/older-semesters.js): Texte und HTML-Teile ohne Browser. Dieselben Faelle wie
// apps/apple/UniFlowTests/LocalDocumentsAppTests.swift (Frage, Stand je Kurs, "Dateien laden"); zusaetzlich liest der Test
// die deutschen Texte aus OlderSemestersViews.swift/SettingsPage.swift und vergleicht sie mit denen der Web-Oberflaeche.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as O from "../../app/static/older-semesters.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = f => readFileSync(join(root, f), "utf8");

const course = (id, o = {}) => ({ id, title: `Kurs ${id}`, files: 0, downloaded: 0, requested: false, loaded: false, ...o });
const overview = (o = {}) => ({ choice: null, current: "WiSe 2026/27", semesters: [
  { label: "SoSe 2026", courses: [course("a", { files: 4, downloaded: 1 }), course("b", { files: 2, downloaded: 2, loaded: true })] },
  { label: "WiSe 2024/25", courses: [course("c")] }], ...o });

test("die Frage kommt nur ohne Wahl und mit Kursen frueherer Semester", () => {
  assert.equal(O.shouldAsk(overview()), true);
  assert.equal(O.shouldAsk(overview({ choice: "current" })), false);
  assert.equal(O.shouldAsk(overview({ choice: "all" })), false);
  assert.equal(O.shouldAsk(overview({ semesters: [] })), false, "ohne fruehere Kurse nichts zu fragen");
  assert.equal(O.shouldAsk(null), false);
  assert.equal(O.courseCount(overview()), 3);
});

test("Text der Frage", () => {
  assert.equal(O.questionText("WiSe 2026/27", 1), "StudiNow hat die Dateien deines aktuellen Semesters (WiSe 2026/27) geladen. Dazu gibt es 1 Kurs aus früheren Semestern. StudiNow lädt sie im Hintergrund nach, neuestes Semester zuerst und nur im WLAN. Du kannst ihre Dateien jederzeit später in der Bibliothek laden, je Semester oder je Kurs.");
  assert.match(O.questionText("", 3), /^StudiNow hat die Dateien deines aktuellen Semesters geladen\. Dazu gibt es 3 Kurse aus/);
});

test("Stand je Kurs", () => {
  assert.equal(O.courseStatus(course("x", { requested: true })), "Vorgemerkt, kommt mit dem nächsten Abgleich");
  assert.equal(O.courseStatus(course("x")), "Dateien noch nicht geladen");
  assert.equal(O.courseStatus(course("x", { loaded: true })), "Keine Dateien");
  assert.equal(O.courseStatus(course("x", { files: 1, downloaded: 1 })), "1 Datei geladen");
  assert.equal(O.courseStatus(course("x", { files: 3, downloaded: 3 })), "3 Dateien geladen");
  assert.equal(O.courseStatus(course("x", { files: 1, downloaded: 0 })), "1 Datei bekannt, nicht geladen");
  assert.equal(O.courseStatus(course("x", { files: 5, downloaded: 2 })), "2 von 5 Dateien geladen");
});

test("noch etwas zu laden?", () => {
  assert.equal(O.needsLoad(course("x")), true, "nie geladen");
  assert.equal(O.needsLoad(course("x", { loaded: true, files: 2, downloaded: 2 })), false);
  assert.equal(O.needsLoad(course("x", { loaded: true, files: 2, downloaded: 1 })), true, "Datei fehlt");
});

test("Kursordner in der Bibliothek", () => {
  assert.equal(O.coursePath("abc-1"), "cabc-1");
  assert.equal(O.courseIdOf("cabc-1"), "abc-1");
  assert.equal(O.courseIdOf("m5"), null, "Modulordner ist kein Kursordner nach c<ID>");
  assert.equal(O.courseIdOf("c"), null);
  assert.equal(O.courseIdOf(undefined), null);
  assert.equal(O.courseIdOf("c<script>"), null);
  assert.equal(O.findCourse(overview(), "c").title, "Kurs c");
  assert.equal(O.findCourse(overview(), "zz"), null);
  assert.equal(O.findCourse(null, "a"), null);
});

test("Bereich Fruehere Semester: zugeklappt, aufgeklappt, beschaeftigt", () => {
  const closed = O.semestersHtml(overview({ choice: "current" }));
  assert.match(O.semestersHtml(overview()), /StudiNow lädt die Dateien früherer Semester mit\./, "nie gefragt: Vorgabe Nur WLAN laedt mit");
  assert.match(closed, /Frühere Semester<\/h2>/);
  assert.match(closed, /StudiNow lädt nur Dateien des aktuellen Semesters\. Frühere Semester kannst du hier je Semester oder je Kurs laden\./);
  assert.match(closed, /SoSe 2026<\/b><span class="muted small">2 Kurse · 3 von 6 Dateien geladen/);
  assert.match(closed, /WiSe 2024\/25<\/b><span class="muted small">1 Kurs<\/span>/, "ohne Dateien keine Zaehlung");
  assert.ok(!closed.includes("older-course"), "Kurse erst nach dem Aufklappen");
  assert.match(closed, /data-older-all="0"/);
  assert.match(closed, /aria-label="SoSe 2026, zugeklappt"/);
  const open = O.semestersHtml(overview(), new Set(["SoSe 2026"]));
  assert.match(open, /aria-label="SoSe 2026, aufgeklappt"/);
  assert.match(open, /href="#\/files\?path=ca"/, "Kurs mit Dateien oeffnet den Kursordner");
  assert.match(open, /data-older-course="a"/);
  assert.ok(!open.includes('data-older-course="b"'), "geladener Kurs braucht kein Laden");
  assert.ok(!O.semestersHtml(overview(), new Set(["WiSe 2024/25"])).includes('href="#/files?path=cc"'), "ohne Dateien kein Link");
  const busy = O.semestersHtml(overview(), new Set(["SoSe 2026"]), new Set(["a"]));
  assert.match(busy, /Lädt …/);
  assert.ok((busy.match(/ disabled/g) || []).length >= 3, "waehrend des Ladens sind alle Knoepfe aus");
  assert.match(O.semestersHtml(overview({ choice: "all" })), /StudiNow lädt die Dateien früherer Semester mit\. Einzelne Kurse kannst du hier erneut laden\./);
  assert.equal(O.semestersHtml(overview({ semesters: [] })), "");
  assert.equal(O.semestersHtml(null), "");
});

test("Titel aus Stud.IP werden maskiert", () => {
  const o = overview({ semesters: [{ label: "SoSe <b>1</b>", courses: [course("x", { title: '<img src=x onerror="a">', files: 1 })] }] });
  const html = O.semestersHtml(o, new Set(["SoSe <b>1</b>"]));
  assert.ok(!html.includes("<img") && !html.includes("<b>1</b>"), html);
  assert.match(html, /&lt;img src=x onerror=&quot;a&quot;&gt;/);
});

test("Ueberschrift des aktuellen Semesters nur mit fruehereren Semestern", () => {
  assert.equal(O.currentHeading(overview()), "Aktuelles Semester · WiSe 2026/27");
  assert.equal(O.currentHeading(overview({ semesters: [] })), "");
  assert.equal(O.currentHeading(null), "");
});

test("Kopf im Kursordner", () => {
  const f = (name, d) => ({ name, downloaded: d });
  assert.match(O.courseHeaderHtml([]), /Die Dateiliste ist noch nicht geladen\./);
  assert.match(O.courseHeaderHtml([]), /data-older-load/);
  const all = O.courseHeaderHtml([f("a.pdf", 1), f("b.pdf", 1)]);
  assert.match(all, /Alle 2 Dateien sind geladen\./);
  assert.ok(!all.includes("data-older-load"), "alles da: kein Laden");
  const part = O.courseHeaderHtml([f("a.pdf", 1), f("b.pdf", 0)]);
  assert.match(part, /1 von 2 Dateien geladen\./);
  assert.match(part, /<span>b\.pdf<\/span>/);
  assert.ok(!part.includes("<span>a.pdf</span>"), "nur die fehlenden stehen im Kopf");
  const many = Array.from({ length: 11 }, (_, i) => f(`d${i}.pdf`, 0));
  assert.equal((O.courseHeaderHtml(many).match(/older-file/g) || []).length, 8);
  assert.match(O.courseHeaderHtml(many), />Alle 11 anzeigen</);
  assert.equal((O.courseHeaderHtml(many, { showAll: true }).match(/older-file/g) || []).length, 11);
  assert.match(O.courseHeaderHtml(many, { showAll: true }), />Weniger anzeigen</);
  assert.match(O.courseHeaderHtml(many, { loading: true }), /disabled>[\s\S]*Lädt …/);
  assert.match(O.courseHeaderHtml([f("<x>.pdf", 0)]), /&lt;x&gt;\.pdf/);
});

test("Einstellung \"Ältere Semester laden\": nur wenn es etwas zu waehlen gibt", () => {
  assert.equal(O.settingHtml(null), "");
  assert.equal(O.settingHtml(overview({ semesters: [] })), "", "nichts gewaehlt und nichts da");
  assert.ok(O.settingHtml(overview({ semesters: [], choice: "current" })).includes('id="sOlderMode"'), "schon gewaehlt: Auswahl bleibt");
  const sel = h => (h.match(/<option value="(\w+)" selected>/) || [])[1];
  assert.equal(sel(O.settingHtml(overview())), "wifi", "nie gefragt: Vorgabe Nur WLAN (05.11.2026)");
  assert.equal(sel(O.settingHtml(overview({ choice: "current" }))), "off", "fruehere Wahl 'nur aktuelles Semester' = Aus");
  assert.equal(sel(O.settingHtml(overview({ choice: "all" }))), "auto", "fruehere Wahl 'alle' = Automatisch");
  assert.equal(sel(O.settingHtml(overview({ choice: "all", mode: "wifi" }))), "wifi", "die neue Wahl gilt vor der alten");
  assert.match(O.settingHtml(overview()), /Ältere Semester laden <select[^>]*>.*>Automatisch<.*>Nur WLAN<.*>Aus</s);
  assert.match(O.settingHtml(overview()), /Aus: StudiNow lädt nur Dateien des aktuellen Semesters\. Frühere Semester lädst du jederzeit in der Bibliothek, je Semester oder je Kurs\./);
  assert.match(O.settingHtml(overview()), /zuerst das aktuelle Semester samt Stundenplan/);
});

test("die Texte sind dieselben wie auf dem iPad", () => {
  const views = read("apps/apple/UniFlow/Views/Library/OlderSemestersViews.swift");
  const settings = read("apps/apple/UniFlow/Views/Settings/SettingsPage.swift");
  for (const t of ["Auch frühere Semester laden?", "Nur aktuelles Semester", "Frühere Semester auch laden", "Frühere Semester", "Alle laden", "Dateien laden",
    "Kurs aus einem früheren Semester", "Die Dateiliste ist noch nicht geladen.", "Vorgemerkt, kommt mit dem nächsten Abgleich", "Dateien noch nicht geladen",
    "StudiNow lädt die Dateien früherer Semester mit. Einzelne Kurse kannst du hier erneut laden.",
    "StudiNow lädt nur Dateien des aktuellen Semesters. Frühere Semester kannst du hier je Semester oder je Kurs laden.",
    "Du kannst ihre Dateien jederzeit später in der Bibliothek laden, je Semester oder je Kurs."]) assert.ok(views.includes(t), `Swift: ${t}`);
  assert.ok(settings.includes("Ältere Semester laden"), "Swift: Ältere Semester laden");
  const core = read("apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Study/OlderSemesters.swift");
  for (const [, t] of O.OLDER_MODES) assert.ok(core.includes(`"${t}"`), `Swift: ${t}`);
  assert.ok(read("apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Sync/SyncOrder.swift").includes(O.OLDER_FILES_HINT), "Hinweis gleich auf dem iPad");
  assert.ok(views.includes("StudiNow lädt sie im Hintergrund nach, neuestes Semester zuerst und nur im WLAN. "), "Frage gleich auf dem iPad");
  assert.ok(O.OLDER_FILES_HINT.endsWith("lädt nur Dateien des aktuellen Semesters. Frühere Semester lädst du jederzeit in der Bibliothek, je Semester oder je Kurs."));
  assert.ok(read("apps/apple/UniFlow/Services/StudIPSync.swift").includes(O.NOTE_QUEUED));
});

test("die Seiten sind angeschlossen", () => {
  const lib = read("app/static/views-lib.js"), misc = read("app/static/views-misc.js"), app = read("app/static/app.js");
  assert.match(lib, /older-semesters-ui\.js\?v=\d+/);
  assert.match(lib, /api\("\/older-semesters"\)/);
  assert.match(lib, /bindSemesters\(\$\("#olderSem", view\), older/);
  assert.match(lib, /bindCourseHeader\(/);
  assert.match(misc, /bindOlderSetting\(view\)/);
  assert.match(misc, /settingHtml\(older\)/);
  assert.match(app, /askOlderSemesters\)?\(?/);
  assert.match(app, /older-semesters-ui\.js\?v=\d+/);
});

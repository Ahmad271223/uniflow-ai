// Hinweise im Kalenderkopf antippbar (Auftrag des Inhabers 03.11.2026): Detail je Art wie UFHint der iPad-App
// (CalendarHintAppTests). Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { hintInfo, relatedEvent, httpUrl } from "../../app/static/hints.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = name => readFileSync(join(root, "app/static", name), "utf8");

const events = [
  { event_id: 1, course_id: "k-vl", module_id: 3, title: "Testmathematik", start: "10:15", end: "11:45", status: "teilnahme",
    cancel_hint: { announcement_id: "sp-news-1", label: "Ausfall?" } },
  { event_id: 2, course_id: "k-ue", module_id: 3, title: "Übung Testmathematik", start: "14:15", end: "15:45", status: "teilnahme" },
];

test("Ausfall aus einer Stud.IP-Ankuendigung: Art, Quelle mit Titel und Datum, Termin mit dem Hinweis", () => {
  const n = { _kind: "notice", announcement_id: "sp-news-1", kind: "ausfall", title: "Hinweis zur Vorlesung", source: "studip",
              snippet: "Die Vorlesung am 12.11. fällt aus.", url: "https://studip.example/news/1", course_title: "Testmathematik",
              course_id: "k-vl", module_id: 3, posted_at: "2026-11-02T09:00:00+01:00", date: "2026-11-12" };
  const h = hintInfo(n);
  assert.equal(h.kindText, "Ausfall?");
  assert.equal(h.tone, "warn");
  assert.equal(h.source, "Stud.IP-Ankündigung „Hinweis zur Vorlesung“ vom 02.11.2026");
  assert.equal(h.snippet, "Die Vorlesung am 12.11. fällt aus.");
  assert.equal(h.url, "https://studip.example/news/1");
  assert.equal(relatedEvent(n, events).event_id, 1);
});

test("Raum mit Uhrzeit: Termin desselben Kurses zur Zeit, fremde Adressen nie", () => {
  const n = { _kind: "notice", kind: "raum", title: "Raum", source: "learnweb", time: "14:15", course_id: "k-ue", module_id: 3,
              url: "javascript:alert(1)", date: "2026-11-12" };
  assert.equal(hintInfo(n).kindText, "Raumänderung");
  assert.equal(hintInfo(n).url, "");
  assert.equal(hintInfo(n).source, "Learnweb-Ankündigung „Raum“");
  assert.equal(relatedEvent(n, events).event_id, 2);
  assert.equal(relatedEvent({ ...n, time: "18:00" }, events), null);
  assert.equal(hintInfo({ ...n, kind: "pruefung" }).kindText, "Klausur / Prüfung");
});

test("Fristen und Feiertage: Quelle je Herkunft, kein Termin", () => {
  const cw = { _kind: "deadline", id: "sp-cw-1", source: "studip", title: "Aufgabe 2", full_title: "Aufgabe 2", kind: "abgabe",
               kind_label: "Abgabe", time: "12:00", url: "https://studip.example/cw/2" };
  assert.equal(hintInfo(cw).source, "Aufgabe aus Stud.IP Courseware");
  assert.equal(hintInfo(cw).snippet, "");
  assert.equal(hintInfo({ ...cw, source: "learnweb", full_title: "Aufgabe 2 ist fällig" }).source, "Frist aus dem Learnweb-Kalender");
  assert.equal(relatedEvent(cw, events), null);
  const det = { _kind: "deadline", detected: true, kind: "klausur", title: "Klausur", origin: "erkannt in Blatt3.pdf, S. 2", snippet: "Klausur am 6.11." };
  assert.equal(hintInfo(det).kindText, "Klausur / Prüfung");
  assert.equal(hintInfo(det).source, "erkannt in Blatt3.pdf, S. 2 (automatisch erkannt)");
  const hol = hintInfo({ _kind: "mark", kind: "feiertag", label: "Reformationstag" });
  assert.deepEqual([hol.kindText, hol.source, hol.tone], ["Feiertag", "Gesetzlicher Feiertag", "ok"]);
  assert.equal(hintInfo({ _kind: "mark", kind: "vorlesungsfrei", label: "Vorlesungsfreie Zeit" }).kindText, "Vorlesungsfreie Zeit");
  assert.equal(httpUrl("ftp://x"), "");
  assert.equal(httpUrl("https://learnweb.example/a"), "https://learnweb.example/a");
});

test("Chips im Kalender tragen das Detail: Feiertage antippbar, Termine des Tages fuer \"Zum Termin\"", () => {
  const core = src("core.js");
  assert.match(core, /class="hol-chip \$\{m\.kind\}" role="button" tabindex="0" data-chip="\$\{chipRef\(m, "mark", dd\.date\)\}"/);
  assert.match(core, /chipRef\(n, "notice", dd\.date, dd\.events\)/);
  assert.match(core, /data-hev>.*Zum Termin/);
  assert.match(core, /Quelle öffnen/);
  assert.match(core, /\/timetable\/attendance/);
});

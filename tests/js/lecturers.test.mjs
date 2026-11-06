// Lehrende und Kontakte (LUH, Stud.IP; docs/LEHRENDE-KONTAKTE-2026-11-06.md): Regeln und HTML in lecturers-logic.js mit
// den Antworten der gemeinsamen Fixture (packages/shared-contracts/fixtures/studip-lecturers/lecturers.json, erfundene
// Namen, example.org): Bereich nur an der LUH mit Eintraegen, E-Mail ueber Uni-Mail oder mailto:, "Nachricht über Stud.IP"
// ohne Adresse, Sprechstunde mit Raum-Link, Einbindung in Modulseite, Uni-Mail und Router.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as L from "../../app/static/lecturers-logic.js";

const fx = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/studip-lecturers/lecturers.json", import.meta.url), "utf8"));
const read = f => fs.readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
const by = Object.fromEntries(fx.overview.map(o => [JSON.stringify(Object.fromEntries(Object.entries(o.query).sort())), o.result]));

test("Bereich nur an der LUH und nur mit Eintraegen", () => {
  assert.equal(L.shows(by['{"module_id":1,"university":"luh"}']), true);
  assert.equal(L.shows(by['{"university":"hsh"}']), false);
  assert.equal(L.shows(by['{"course_id":"k-ana","university":"hildesheim"}']), false);
  assert.equal(L.shows(by['{"allowed":false,"university":"luh"}']), false, "im Dienst nie");
  assert.equal(L.shows(by['{"course_id":"k-zu","university":"luh"}']), false, "leer: kein Platzhalter");
  assert.equal(L.shows(null), false);
});

test("Zeilen: E-Mail, ohne Adresse Stud.IP, Sprechstunde mit Raum", () => {
  const course = by['{"course_id":"k-ana","university":"luh"}'];
  const [prof, doz2] = course.people;
  const html = L.rowHtml(prof);
  assert.match(html, /data-mail="erika\.beispiel@example\.org"/);
  assert.match(html, /aria-label="E-Mail an erika\.beispiel@example\.org"/);
  assert.match(html, /<span>Di 10–11 Uhr<\/span>/, "Zeiten bleiben Text");
  assert.match(html, /class="room-link" data-room="Raum F 303 \(1101\)"/, "Raum fuehrt zum Raumfinder");
  assert.match(html, /Institut für Testmathematik/);
  assert.match(html, /Nachricht in Stud\.IP/);
  const none = L.rowHtml(doz2);
  assert.doesNotMatch(none, /data-mail=/);
  assert.match(none, /Nachricht über Stud\.IP/);
  assert.equal(L.ariaLabel(prof), "Prof. Dr. Erika Beispiel, Dozent/in, E-Mail erika.beispiel@example.org, Sprechstunde Di 10–11 Uhr, und nach Vereinbarung, Raum F 303 (1101)");
  assert.equal(L.detail(prof), "Dozent/in · Modulverantwortliche");
  const all = by['{"university":"luh"}'];
  assert.ok(all.people.every(p => !p.email || p.email.endsWith("example.org")), "nur erfundene Adressen");
  const tut = all.people.find(p => p.id === "u-tut1");
  assert.equal(L.detail(tut, true), "Tutor/in · Analysis I");
  assert.equal(L.subject(tut), "Frage zu Analysis I");
  assert.equal(L.subject(tut, "Programmieren"), "Frage zu Programmieren");
  assert.equal(L.countLine(all), "5 Personen");
  assert.equal(L.countLine(by['{"q":"übung","university":"luh"}']), "3 von 5 Personen");
  assert.ok(L.rowHtml({ id: "x", name: "<b>", email: "" }).includes("&lt;b&gt;"), "escaped");
});

test("E-Mail: Uni-Mail wenn verbunden, sonst mailto", () => {
  assert.deepEqual(L.mailAction("a@example.org", true), { kind: "unimail", to: "a@example.org" });
  assert.deepEqual(L.mailAction("a@example.org", false), { kind: "mailto", url: "mailto:a@example.org" });
  assert.equal(L.mailAction(" ", true), null);
  assert.equal(L.namesRoom("Raum F 303 (1101)"), true);
  assert.equal(L.namesRoom("1101 - F102"), true);
  assert.equal(L.namesRoom("Gebäude 3403, Raum A003"), true);
  assert.equal(L.namesRoom("Di 10–11 Uhr"), false);
  assert.equal(L.namesRoom("nach Vereinbarung"), false);
  assert.deepEqual(L.officeLines("a\n\n b \n"), ["a", "b"]);
});

test("Einbindung: Modulseite, Seite #/lehrende, Uni-Mail mit Empfaenger", () => {
  const misc = read("views-misc.js"), app = read("app.js"), um = read("uni-mail.js"), lec = read("lecturers.js");
  assert.match(misc, /<div id="lecHost"><\/div>/);
  assert.match(misc, /mountModuleLecturers\(\$\("#lecHost", view\), id, m\.name\)/);
  assert.match(app, /routes\.lehrende = routes\.lecturers =/);
  assert.match(um, /export function composeTo\(to, subject = ""\)/);
  assert.match(um, /href="#\/lehrende"/, "Uni-Mail fuehrt zu den Lehrenden");
  assert.match(lec, /\/lecturers\/\$\{encodeURIComponent\(p\.id\)\}\/message/);
  assert.match(lec, /m\.composeTo\(a\.to/);
  const v = app.match(/uni-mail\.js\?v=(\d+)/)[1];
  assert.ok(lec.includes(`uni-mail.js?v=${v}`), "gleiche Fassung von uni-mail.js");
});

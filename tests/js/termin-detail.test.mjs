// Termin-Detail (06.11.2026): Regeln und HTML in termin-detail-logic.js mit den gemeinsamen Faellen
// (packages/shared-contracts/fixtures/termin-detail/cases.json, gleich in UniFlowCore/TerminDetailTests.swift): Raeume,
// Route zu Fuss oder Raumfinder-Suche, Lehrende und Tutor/innen, "Allen Lehrenden schreiben", Betreff, mailto:, Wahl
// zwischen Uni-Mail, "Uni-Mail verbinden", Mail-Programm und Stud.IP; Einbindung ins Termin-Panel.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as T from "../../app/static/termin-detail-logic.js";

const fx = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/termin-detail/cases.json", import.meta.url), "utf8"));
const read = f => fs.readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Raeume eines Termins", () => {
  for (const c of fx.rooms) assert.deepEqual(T.rooms(c.text), c.want, JSON.stringify(c));
});

test("Route zu Fuss oder Raumfinder-Suche", () => {
  for (const c of fx.route) {
    const got = T.route(c.part, c.app);
    const want = c.want.kind === "route" ? { kind: "route", url: c.want.url } : c.want.kind === "search" ? { kind: "search", query: c.want.query } : { kind: "none" };
    assert.deepEqual(got, want, JSON.stringify(c));
  }
});

test("Lehrende, Tutor/innen, alle Adressen", () => {
  const g = T.groups(fx.people);
  assert.deepEqual(g.lecturers.map(p => p.id), fx.groups.lecturers);
  assert.deepEqual(g.tutors.map(p => p.id), fx.groups.tutors);
  assert.deepEqual(T.recipients(fx.people), fx.recipients);
});

test("Betreff, mailto:, Wahl des Wegs", () => {
  for (const c of fx.subject) assert.equal(T.subject(c.title), c.want);
  for (const c of fx.mailto) assert.equal(T.mailto(c.to, c.subject), c.want, JSON.stringify(c));
  for (const c of fx.mail_choice) assert.equal(T.mailChoice(c.to, c.unimail), c.want, JSON.stringify(c));
  assert.equal(T.uniMailState({ available: true, connected: true }), "connected");
  assert.equal(T.uniMailState({ available: true, connected: false }), "disconnected");
  assert.equal(T.uniMailState({ available: false }), "none");
  assert.equal(T.uniMailState(null), "none");
});

test("Abfrage der Lehrenden und Hochschule", () => {
  for (const c of fx.lecturers_query) assert.equal(T.lecturersQuery(c.event), c.want, JSON.stringify(c));
  for (const c of fx.shows_lecturers) assert.equal(T.showsLecturers(c.university), c.want);
});

test("HTML: Raum mit Route an der LUH, sonst Text mit Kartensuche", () => {
  const luh = T.roomSectionHtml("1101 - F102 · Online", true);
  assert.match(luh, /<h3> Räume<\/h3>/);
  assert.match(luh, /class="td-route" data-route="1101 - F102" aria-label="Raum 1101 - F102, Route zu Fuß starten"/);
  assert.match(luh, /class="btn ghost sm room-link" data-room="1101 - F102"[^>]*aria-label="Raum 1101 - F102 im Raumfinder anzeigen"/);
  assert.ok(!/data-route="Online"/.test(luh) && /> Online<\/span>/.test(luh), "Online bleibt Text");
  const hsh = T.roomSectionHtml("1H.1.01", false);
  assert.ok(!hsh.includes("data-route"));
  assert.match(hsh, /data-maps="1H\.1\.01" aria-label="Raum 1H\.1\.01 in Karten suchen"/);
  assert.equal(T.roomSectionHtml("", true), "");
  assert.match(T.roomSectionHtml('<img src=x onerror="1">', true), /&lt;img/);
});

test("HTML: Lehrende mit E-Mail, Tutor/innen zugeklappt, Allen schreiben nur ab zwei Adressen", () => {
  const d = { available: true, people: fx.people.slice(0, 3), hint: null };
  const html = T.lecturersSectionHtml(d);
  assert.match(html, /data-mail="erika\.beispiel@example\.org"/);
  assert.match(html, /data-mail="max\.muster@example\.org"/);
  assert.match(html, /<details class="td-tutors"><summary>Tutor\/innen \(1\)<\/summary>/);
  assert.ok(html.indexOf("Erfundener Tutor") > html.indexOf("<details"), "Tutor im zugeklappten Teil");
  assert.match(html, /data-mail-all aria-label="Allen Lehrenden schreiben"/);
  const one = T.lecturersSectionHtml({ available: true, people: [fx.people[0]] });
  assert.ok(!one.includes("data-mail-all"));
  assert.equal(T.lecturersSectionHtml({ available: false, people: fx.people }), "", "HsH/Hildesheim: unsichtbar");
  assert.equal(T.lecturersSectionHtml({ available: true, people: [], hint: null }), "");
  assert.match(T.lecturersSectionHtml({ available: true, people: [], hint: "Die Lehrenden kommen mit dem nächsten Stud.IP-Abgleich." }), /nächsten Stud\.IP-Abgleich/);
});

test("Einbindung: Termin-Panel, Route, Uni-Mail, Raumfinder mit Suche", () => {
  const tt = read("views-tt.js"), td = read("termin-detail.js");
  assert.match(tt, /import\("\.\/termin-detail\.js\?v=1"\)\.then\(m => m\.mountTerminDetail/);
  assert.match(tt, /Zum Modul/);
  assert.ok(!tt.includes("Modul öffnen"));
  assert.match(td, /window\.open\(r\.url, "_blank", "noopener"\)/);
  assert.match(td, /#\/raumfinder\?q=\$\{encodeURIComponent/);
  assert.match(td, /composeTo\(to\.join\(", "\), subj\)/);
  assert.match(td, /href="#\/unimail" data-connect/);
  assert.match(read("lecturers.js"), /export function studipMessage/);
  assert.match(read("rooms.js"), /if \(q\?\.q\) search\(\)/, "Raumfinder sucht mit ?q= sofort");
});

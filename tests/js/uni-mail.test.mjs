// Uni-Mail (SOGo der LUH, docs/UNI-MAIL-2026-11-05.md) in Web/Windows: Regeln in uni-mail-logic.js, Route und Menüpunkt,
// Senden nur mit Bestätigung ("confirm": true nur aus der Rückfrage), Mail-HTML im abgeschotteten Rahmen.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as L from "../../app/static/uni-mail-logic.js";

const read = f => fs.readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Zahl, Texte, Termine", () => {
  assert.equal(L.badgeText(0), "");
  assert.equal(L.badgeText(7), "7");
  assert.equal(L.badgeText(120), "99+");
  assert.equal(L.badgeLabel(1), "1 ungelesene E-Mail");
  assert.equal(L.addressText({ name: "Max", email: "m@x.de" }), "Max <m@x.de>");
  assert.equal(L.addressText({ name: "", email: "m@x.de" }), "m@x.de");
  assert.equal(L.composeTitle("replyall"), "Allen antworten");
  assert.equal(L.composeTitle("compose"), "Neue E-Mail");
  assert.equal(L.sendQuestion("a@b.de, c@d.de", "", "x@y.de"), "E-Mail an 3 Empfänger senden?");
  assert.equal(L.when({ start: "2026-11-09T10:15", end: "2026-11-09T11:45", all_day: false }), "09.11., 10:15–11:45");
  assert.equal(L.when({ start: "2026-11-11T00:00", end: "2026-11-12T23:59", all_day: true }), "11.11. – 12.11., ganztägig");
  assert.ok(!L.showsNavItem({ available: false }) && L.showsNavItem({ available: true }));
});

test("Senden nur mit Bestätigung", () => {
  assert.equal(L.body({ draft_id: "d" }, { to: "a@b.de" }).confirm, undefined);
  assert.equal(L.body({ draft_id: "d" }, { to: "a@b.de" }, true).confirm, true);
  const src = read("uni-mail.js");
  const sends = src.match(/\/sogo\/draft\/send/g) || [];
  assert.equal(sends.length, 1, "genau eine Stelle sendet");
  assert.match(src, /window\.confirm\(L\.sendQuestion[\s\S]{0,200}\/sogo\/draft\/send", \{ method: "POST", body: L\.body\(draft, f, true\)/);
});

test("Mail-HTML ohne Skripte und ohne Netz", () => {
  const d = L.frameDoc("<p>x</p>");
  assert.match(d, /default-src 'none'/);
  assert.match(read("uni-mail.js"), /<iframe sandbox=""/);
});

test("Route und Menüpunkt am PC", () => {
  const app = read("app.js");
  assert.match(app, /routes\.unimail = .*uni-mail\.js\?v=\d+/);
  assert.match(app, /if \(!state\.hosted\) \{[^\n]*uni-mail\.js\?v=\d+"\)\.then\(m => m\.startNavItem\(\)\)/);
});

test("Uni Hildesheim: eigener Name, keine Raum-Links, kein „Lehrende“; HsH ohne Uni-Mail", () => {
  const cases = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/sogo/cases.json", import.meta.url), "utf8")).sites;
  for (const s of cases.list) {                     // gleiche Rechner und Namen wie sogo.SITES / SOGoSite
    assert.equal(L.SITES[s.key].host, s.host);
    assert.equal(L.SITES[s.key].name, s.name);
    assert.equal(L.SITES[s.key].roomLinks, s.room_links);
  }
  const hi = { available: true, university: "hildesheim", connected: true };
  const luh = { available: true, university: "luh" };
  assert.equal(L.texts(hi).name, "Uni-Mail (Uni Hildesheim)");
  assert.equal(L.texts(hi).sub, "E-Mails und Kalender der Universität Hildesheim (SOGo)");
  assert.match(L.texts(hi).hint, /SOGo-Seite der Uni Hildesheim/);
  assert.equal(L.texts(luh).name, "Uni-Mail (LUH)");
  assert.ok(L.roomLinks(luh) && !L.roomLinks(hi));
  assert.ok(L.showsLecturers(luh) && !L.showsLecturers(hi));
  const hsh = { available: false, university: null };
  assert.ok(!L.showsNavItem(hsh) && L.site(hsh) === null && !L.roomLinks(hsh));
  assert.equal(L.site({ available: true, university: "__proto__" }), null, "nur bekannte Hochschulen");
  const src = read("uni-mail.js");
  assert.match(src, /L\.roomLinks\(st\) \? `<button class="room-link"/, "Raum-Link nur mit roomLinks");
  assert.match(src, /L\.showsLecturers\(st\) \?/);
});

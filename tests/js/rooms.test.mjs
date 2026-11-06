// Raumfinder (docs/RAUMFINDER-2026-11-05.md): Regeln in rooms-logic.js mit denselben Faellen wie app/rooms.py und
// Rooms.swift (packages/shared-contracts/fixtures/rooms/cases.json): Teile einer Raumangabe, "online", Raum-Link,
// Kartenlinks, Angaben eines Orts; Menuepunkt unter Alltag, Route und Raum-Links in Stundenplan und Klausuren.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as L from "../../app/static/rooms-logic.js";
import { NAV_GROUPS } from "../../app/static/shell-nav.js";
import { examsCard } from "../../app/static/exams.js";

const cases = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/rooms/cases.json", import.meta.url), "utf8"));
const data = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/rooms.json", import.meta.url), "utf8"));
const read = f => fs.readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Teile und online wie in Python", () => {
  assert.deepEqual(L.ONLINE_WORDS, data.online_words, "gleiche Woerter wie rooms.json");
  for (const [t, parts] of Object.entries(cases.segments)) assert.deepEqual(L.segments(t), parts, t);
  for (const c of cases.parse) {
    assert.deepEqual(L.segments(c.text), c.result.parts.map(p => p.text), c.text);
    for (const p of c.result.parts) {
      if (p.online) assert.ok(L.isOnline(p.text) && !L.mayLink(p.text), p.text);
      if (p.linkable) assert.ok(L.mayLink(p.text), p.text);
    }
  }
  assert.ok(L.mayLink("Online / Raum F102"), "Raum zaehlt");
  assert.ok(L.mayLink("Seminarraum"), "der Server sagt, ob er etwas findet");
  assert.ok(!L.mayLink("") && !L.mayLink("Zoom"));
});

test("Raum-Link und Kartenlinks", () => {
  const html = L.roomLink("1101 - F102", n => `<i data-i="${n}"></i>`);
  assert.match(html, /class="room-link" data-room="1101 - F102"/);
  assert.match(html, /aria-label="Raum 1101 - F102: Ort und Link zu Google Maps zeigen"/);
  assert.match(html, /data-i="map-pin"/);
  assert.equal(L.roomLink("Online"), '<span class="room-text">Online</span>');
  assert.ok(!L.roomLink('"><script>').includes("<script>"));
  const f102 = cases.places["search-f102.json"][0];
  assert.equal(L.mapsUrl(f102.maps), "https://www.google.com/maps/search/?api=1&query=52.38255%2C9.71785");
  assert.equal(L.mapsUrl(f102.maps, "route"), "https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking");
  assert.equal(L.mapsUrl(f102.maps, "apple"), "https://maps.apple.com/?q=Raum%20F102&ll=52.38255%2C9.71785");
  assert.equal(L.mapsUrl({ google: "comgooglemaps://?q=1" }), null, "am PC nur https");
  assert.equal(L.resolvePath("1101 - F102"), "/rooms/resolve?text=1101%20-%20F102");
  assert.equal(L.searchPath(" Hauptgebäude "), "/rooms/search?q=Hauptgeb%C3%A4ude&page=0");
});

test("Angaben, Barrierefreiheit, Hinweise", () => {
  const f102 = cases.places["search-f102.json"][0];
  assert.deepEqual(L.placeRows(f102), [["Gebäude", "1101 (Hauptgebäude)"], ["Etage", "1. Obergeschoss (Etage 001)"], ["Raum", "F102"],
    ["Adresse", "Welfengarten 1, 30167 Hannover"]]);
  assert.deepEqual(L.infoLinks(f102).map(l => l.label), ["Raumplan ansehen", "Raum im Gebäudeinfo der LUH", "Gebäudeinfo der LUH"]);
  const t = cases.crafted[0].place;
  assert.deepEqual(L.accessibilityRows(t)[0], { title: "PKW-Stellplätze für Menschen mit Behinderungen (vorhanden)", text: "Zwei Plätze am Eingang" });
  const st = Object.fromEntries(cases.resolve.map(c => [c.text, c.result.parts[0]]));
  assert.equal(L.statusText(st["1H.1.01"]), "Ort laut Hochschule; genaue Lage ohne Gewähr");
  assert.equal(L.statusText(st["Online"]), "Online-Termin – kein Ort.");
  assert.equal(L.statusText(st["1101 - F102"]), "");
  assert.equal(L.countText({ count: 0, query: "x" }), "Keine Treffer für „x“.");
  assert.equal(L.countText({ count: 16 }), "16 Treffer");
});

test("Seitenleiste, Route, Raum-Links in Stundenplan und Klausuren", () => {
  assert.deepEqual(NAV_GROUPS.find(g => g.id === "alltag").items, [["mensa", "Mensa", "utensils"], ["raumfinder", "Raumfinder", "map-pin"]]);
  assert.match(read("app.js"), /routes\.raumfinder = routes\.rooms = /);
  assert.match(read("app.js"), /\.room-link\[data-room\]/);
  assert.match(read("views-tt.js"), /roomLink\(e\.room, icon\)/);
  const html = examsCard([{ date: "2027-02-12", title: "Analysis", time: "09:00", end: "11:00", room: "Hörsaal F 303", in_days: "in 99 Tagen" }]);
  assert.match(html, /class="ov-exam-room"><button type="button" class="room-link" data-room="Hörsaal F 303"/);
  assert.match(html, /aria-label="Analysis, [^"]*09:00–11:00 Uhr · Hörsaal F 303/);
  const online = examsCard([{ date: "2027-02-12", title: "Analysis", room: "Online" }]);
  assert.ok(!online.includes("room-link") && online.includes(">Online<"));
});

// Mensa (docs/MENSA-2026-11-05.md): Regeln in mensa-logic.js mit denselben Faellen wie app/mensa.py und Mensa.swift
// (packages/shared-contracts/fixtures/mensa/cases.json), Karte "Heute in der Mensa", Einstellungen im Browser, Auswahlliste.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as L from "../../app/static/mensa-logic.js";
import { NAV_GROUPS } from "../../app/static/shell-nav.js";

const cases = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/mensa/cases.json", import.meta.url), "utf8"));
const parsed = n => cases.parse[n].result;
const sample = [...parsed("studifutter-garbsen.json").days["2026-11-05"], ...parsed("stwon-hi-uni.json").days["2026-11-05"]];

test("Filter und Auswahl wie in Python", () => {
  for (const c of cases.filters) {
    assert.deepEqual(L.filterMeals(sample, c.filter).map(m => m.id), c.ids, JSON.stringify(c.filter));
    assert.deepEqual(L.topMeals(sample, 3, c.filter).map(m => m.id), c.top, JSON.stringify(c.filter));
  }
  assert.deepEqual(L.topMeals(parsed("stwon-hi-uni.json").days["2026-11-05"]).map(m => m.id), cases.top_stwon);
  for (const c of cases.prices) assert.equal(L.priceFor(sample.find(m => m.id === c.id), c.role), c.price);
});

test("Preis, Tage, Filtertext", () => {
  assert.equal(L.formatPrice(2.5), "2,50 €");
  assert.equal(L.formatPrice(null), "–");
  assert.equal(L.dayLabel("2026-11-05", "2026-11-05"), "Heute");
  assert.equal(L.dayLabel("2026-11-06", "2026-11-05"), "Morgen");
  assert.equal(L.dayLabel("2026-11-09", "2026-11-05"), "Mo 9.11.");
  assert.equal(L.addDays("2026-10-31", 1), "2026-11-01");
  assert.ok(L.isWeekend("2026-11-07") && !L.isWeekend("2026-11-06"));
  assert.equal(L.filterSummary({ vegan: true, ohne_schwein: true, allergens: ["gluten"] }, { gluten: "Gluten" }), "vegan · ohne Schwein · ohne Gluten");
  assert.ok(L.isFilterEmpty({ allergens: [] }) && !L.isFilterEmpty({ vegetarisch: true }));
});

test("Karte Heute in der Mensa: drei Hauptgerichte, nie am Wochenende oder an geschlossenen Tagen", () => {
  const meals = parsed("studifutter-garbsen.json").days["2026-11-05"];
  const menu = { canteen: { name: "Mensa Garbsen" }, days: [{ date: "2026-11-05", status: "open", meals }], stale: false };
  const card = L.dashboardCard(menu, "2026-11-05", {}, "guest");
  assert.equal(card.canteen, "Mensa Garbsen");
  assert.equal(card.meals.length, 3);
  assert.deepEqual(card.meals.map(m => m.id), L.topMeals(meals).map(m => m.id));
  assert.match(card.meals[0].price, /€$/);
  assert.equal(L.dashboardCard({ ...menu, days: [{ date: "2026-11-05", status: "closed", meals: [] }] }, "2026-11-05"), null);
  assert.equal(L.dashboardCard({ ...menu, days: [{ date: "2026-11-07", status: "open", meals }] }, "2026-11-07"), null, "Samstag");
  assert.ok(L.dashboardCard(menu, "2026-11-05", { vegan: true }).meals.every(m => m.labels.includes("vegan")), "Filter gilt auch fuer die Karte");
  assert.equal(L.dashboardCard({ ...menu, days: [{ date: "2026-11-05", status: "open", meals: meals.filter(m => !m.main) }] }, "2026-11-05"), null, "nur Beilagen");
});

test("Einstellungen: Mensa, Favoriten, Gruppe, Filter; kaputte Werte werden ersetzt", () => {
  const store = new Map();
  const st = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  let p = L.readPrefs(st);
  assert.deepEqual(p, { canteen: null, favorites: [], role: "student", sort: "line", filter: { vegan: false, vegetarisch: false, ohne_schwein: false, allergens: [] } });
  p = L.toggleFavorite({ ...p, role: "guest" }, "contine");
  L.writePrefs(st, p);
  assert.deepEqual(L.readPrefs(st).favorites, ["contine"]);
  assert.equal(L.readPrefs(st).role, "guest");
  store.set(L.PREF_KEY, "{kaputt");
  assert.equal(L.readPrefs(st).role, "student");
  const list = { default: "hi-uni", region: "hildesheim", canteens: [
    { id: "hi-uni", own: true, region: "hildesheim" }, { id: "hi-hohnsen", own: false, region: "hildesheim" }, { id: "contine", own: false, region: "hannover" }] };
  assert.equal(L.chosenCanteen({ favorites: [] }, list), "hi-uni", "Standard der Hochschule");
  assert.equal(L.chosenCanteen({ favorites: ["contine"] }, list), "contine", "erster Favorit");
  assert.equal(L.chosenCanteen({ canteen: "hi-hohnsen", favorites: ["contine"] }, list), "hi-hohnsen", "gemerkt");
  assert.equal(L.chosenCanteen({ canteen: "gibtsnicht" }, list), "hi-uni");
  assert.deepEqual(L.canteenGroups(list, ["contine"]).map(g => [g.title, g.items.map(c => c.id)]),
    [["Favoriten", ["contine"]], ["Deine Hochschule", ["hi-uni"]], ["Weitere in der Nähe", ["hi-hohnsen"]]]);
});

test("Mensa steht in der Seitenleiste unter Alltag", () => {
  assert.deepEqual(NAV_GROUPS.find(g => g.id === "alltag").items.map(x => x[0]), ["mensa"]);
  const app = fs.readFileSync(new URL("../../app/static/app.js", import.meta.url), "utf8");
  assert.match(app, /routes\.mensa = /);
  const home = fs.readFileSync(new URL("../../app/static/views-home.js", import.meta.url), "utf8");
  assert.match(home, /id="mensaHost"/);
});

test("Sortierung wie in Python, Naehrwerte, Klima", () => {
  for (const c of cases.sorts) {
    const meals = parsed(c.fixture).days["2026-11-05"];
    assert.deepEqual(L.sortMeals(meals, c.by, c.role).map(m => m.id), c.ids, `${c.fixture} ${c.by} ${c.role}`);
  }
  const garbsen = parsed("studifutter-garbsen.json").days["2026-11-05"];
  const chili = garbsen.find(m => m.name.startsWith("Chili con Carne"));
  assert.deepEqual(L.nutritionRows(chili).map(r => `${r.label}: ${r.value}`), ["Brennwert: 811 kcal", "Fett: 35,2 g",
    "davon gesättigte Fettsäuren: 15,9 g", "Kohlenhydrate: 62,2 g", "davon Zucker: 12,5 g", "Eiweiß: 53,6 g", "Salz: 5,3 g"]);
  assert.equal(L.basisLabel(chili.nutrition), "pro Portion");
  assert.equal(L.nutritionShort(chili), "811 kcal · 53,6 g Eiweiß");
  assert.deepEqual(L.climateRows(chili), ["CO₂e 2.174 g pro Portion"]);
  const risotto = parsed("stwon-hi-uni.json").days["2026-11-05"][0];
  assert.equal(L.nutritionRows(risotto)[0].value, "388 kJ / 93 kcal");
  assert.equal(L.basisLabel(risotto.nutrition), "pro 100 g");
  assert.equal(L.nutritionShort(risotto), "93 kcal/100 g · 3,3 g Eiweiß/100 g");
  const om = parsed("openmensa-hauptmensa.json").days["2026-11-05"];
  assert.deepEqual(L.nutritionRows(om[0]), []);
  assert.deepEqual(L.availableSorts(om).map(x => x[0]), ["line", "price"], "ohne Naehrwerte nur Menuelinie und Preis");
  assert.deepEqual(L.availableSorts(garbsen).map(x => x[0]), ["line", "price", "kcal", "protein"]);
});

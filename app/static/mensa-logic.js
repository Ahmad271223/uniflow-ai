// Mensa-Regeln ohne DOM (05.11.2026, docs/MENSA-2026-11-05.md), gleich wie app/mensa.py und Mensa.swift: Filter
// (vegan, vegetarisch, ohne Schwein, Allergene meiden), Auswahl fuer die Karte "Heute in der Mensa", Preis je Gruppe,
// Tagesumschalter (Heute/Morgen/Woche), Einstellungen im Browser. Tests: tests/js/mensa.test.mjs mit
// packages/shared-contracts/fixtures/mensa/cases.json.

export const ROLE_NAMES = { student: "Studierende", employee: "Bedienstete", guest: "Gäste" };
export const LABEL_NAMES = { vegan: "vegan", vegetarisch: "vegetarisch", fisch: "Fisch", fleisch: "Fleisch", gefluegel: "Geflügel", schwein: "Schwein", rind: "Rind", alkohol: "Alkohol" };
export const STATUS_TEXT = {
  closed: "Geschlossen – an diesem Tag gibt es kein Essen.",
  none: "Für diesen Tag gibt es noch keinen Speiseplan.",
};
const WD = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];
const WD_LONG = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"];

/** {vegan, vegetarisch, ohne_schwein, allergens: [...]} wie in Python */
export function matches(meal, f = {}) {
  const labels = new Set(meal.labels || []);
  if (f.vegan && !labels.has("vegan")) return false;
  if (f.vegetarisch && !labels.has("vegetarisch")) return false;
  if (f.ohne_schwein && labels.has("schwein")) return false;
  const avoid = new Set(f.allergens || []);
  return !(avoid.size && (meal.allergens || []).some(a => avoid.has(a.key)));
}

export const filterMeals = (meals, f) => (meals || []).filter(m => matches(m, f));

/** Hauptgerichte passend zum Filter, mittags vor abends (stabil) */
export function topMeals(meals, n = 3, f = {}) {
  const rank = { frueh: 1, mittag: 0, abend: 2 };
  return filterMeals(meals, f).filter(m => m.main).map((m, i) => [rank[m.time] ?? 0, i, m])
    .sort((a, b) => a[0] - b[0] || a[1] - b[1]).slice(0, n).map(x => x[2]);
}

export function priceFor(meal, role) {
  const r = ["student", "employee", "guest"].includes(role) ? role : "student";
  const v = meal?.prices?.[r];
  return typeof v === "number" ? v : null;
}

/** "2,50 €"; ohne Preis "–" */
export const formatPrice = v => typeof v === "number" ? `${v.toFixed(2).replace(".", ",")} €` : "–";

export const isFilterEmpty = f => !f?.vegan && !f?.vegetarisch && !f?.ohne_schwein && !(f?.allergens || []).length;

/** Kurzbeschreibung des Filters fuer VoiceOver und die Leerzeile */
export function filterSummary(f, allergenNames = {}) {
  const parts = [];
  if (f?.vegan) parts.push("vegan"); else if (f?.vegetarisch) parts.push("vegetarisch");
  if (f?.ohne_schwein) parts.push("ohne Schwein");
  const a = (f?.allergens || []).map(k => allergenNames[k] || k);
  if (a.length) parts.push(`ohne ${a.join(", ")}`);
  return parts.join(" · ");
}

const pad = n => String(n).padStart(2, "0");
export const isoOf = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const dateOf = iso => { const [y, m, d] = iso.split("-").map(Number); return new Date(y, m - 1, d); };
export const addDays = (iso, n) => { const d = dateOf(iso); d.setDate(d.getDate() + n); return isoOf(d); };

/** "Heute", "Morgen", sonst "Mo 9.11." */
export function dayLabel(iso, today) {
  if (iso === today) return "Heute";
  if (iso === addDays(today, 1)) return "Morgen";
  const d = dateOf(iso);
  return `${WD[d.getDay()]} ${d.getDate()}.${d.getMonth() + 1}.`;
}

/** "Donnerstag, 5. November" */
export function dayLong(iso) {
  const d = dateOf(iso);
  return `${WD_LONG[d.getDay()]}, ${d.getDate()}. ${d.toLocaleDateString("de-DE", { month: "long" })}`;
}

export const isWeekend = iso => [0, 6].includes(dateOf(iso).getDay());

/** Karte "Heute in der Mensa": nur an offenen Tagen mit Hauptgerichten; am Wochenende und an geschlossenen Tagen nie */
export function dashboardCard(menu, today, f = {}, role = "student") {
  const day = (menu?.days || []).find(d => d.date === today);
  if (!day || day.status !== "open" || isWeekend(today)) return null;
  const top = topMeals(day.meals, 3, f);
  if (!top.length) return null;
  return { canteen: menu.canteen?.name || "Mensa", meals: top.map(m => ({ id: m.id, name: m.name, category: m.category, labels: m.labels || [], price: formatPrice(priceFor(m, role)) })), stale: !!menu.stale };
}

/** Einstellungen (Browser): Mensa, Favoriten, Preisgruppe, Filter */
export const PREF_KEY = "mensa-prefs";
export function readPrefs(storage) {
  try {
    const p = JSON.parse(storage?.getItem(PREF_KEY) || "{}");
    return { canteen: typeof p.canteen === "string" ? p.canteen : null, favorites: Array.isArray(p.favorites) ? p.favorites.filter(x => typeof x === "string") : [],
      role: ["student", "employee", "guest"].includes(p.role) ? p.role : "student", sort: ["line", "price", "kcal", "protein"].includes(p.sort) ? p.sort : "line", filter: { vegan: !!p.filter?.vegan, vegetarisch: !!p.filter?.vegetarisch,
        ohne_schwein: !!p.filter?.ohne_schwein, allergens: Array.isArray(p.filter?.allergens) ? p.filter.allergens.filter(x => typeof x === "string") : [] } };
  } catch { return { canteen: null, favorites: [], role: "student", sort: "line", filter: { vegan: false, vegetarisch: false, ohne_schwein: false, allergens: [] } }; }
}
export function writePrefs(storage, prefs) { try { storage?.setItem(PREF_KEY, JSON.stringify(prefs)); } catch {} }

/** gewaehlte Mensa: gemerkt (wenn es sie gibt), sonst erster Favorit, sonst Standard der Hochschule */
export function chosenCanteen(prefs, list) {
  const ids = new Set((list?.canteens || []).map(c => c.id));
  if (prefs?.canteen && ids.has(prefs.canteen)) return prefs.canteen;
  const fav = (prefs?.favorites || []).find(id => ids.has(id));
  return fav || list?.default || "hauptmensa";
}

export function toggleFavorite(prefs, id) {
  const s = new Set(prefs.favorites || []);
  s.has(id) ? s.delete(id) : s.add(id);
  return { ...prefs, favorites: [...s] };
}

/** Auswahlliste: Favoriten, deine Hochschule, weitere in der Region, andere Orte */
export function canteenGroups(list, favorites = []) {
  const all = list?.canteens || [];
  const fav = new Set(favorites);
  const groups = [
    ["Favoriten", all.filter(c => fav.has(c.id))],
    ["Deine Hochschule", all.filter(c => !fav.has(c.id) && c.own)],
    ["Weitere in der Nähe", all.filter(c => !fav.has(c.id) && !c.own && c.region === list?.region)],
    ["Andere Orte", all.filter(c => !fav.has(c.id) && !c.own && c.region !== list?.region)],
  ];
  return groups.filter(g => g[1].length).map(([title, items]) => ({ title, items }));
}

// ---- Naehrwerte, Bestandteile, Sortierung (Wunsch des Inhabers 05.11.2026) ----

export const NO_NUTRITION = "Keine Nährwertangaben vom Studentenwerk";
export const SORTS = [["line", "Menülinie"], ["price", "Preis"], ["kcal", "Kalorien"], ["protein", "Eiweiß"]];
export const NUTRIENTS = [["fat", "Fett"], ["saturated_fat", "davon gesättigte Fettsäuren"], ["carbohydrates", "Kohlenhydrate"],
  ["sugar", "davon Zucker"], ["fiber", "Ballaststoffe"], ["protein", "Eiweiß"], ["salt", "Salz"]];

/** wie sort_meals in Python: Preis/Kalorien aufsteigend, Eiweiss absteigend, ohne Angabe ans Ende, sonst stabil */
export function sortMeals(meals, by = "line", role = "student") {
  const val = m => {
    const n = m.nutrition || {};
    if (by === "price") return priceFor(m, role);
    if (by === "kcal") return typeof n.energy_kcal === "number" ? n.energy_kcal : null;
    if (by === "protein") return typeof n.protein === "number" ? -n.protein : null;
    return 0;
  };
  return (meals || []).map((m, i) => [val(m), i, m])
    .sort((a, b) => (a[0] === null) - (b[0] === null) || (a[0] ?? 0) - (b[0] ?? 0) || a[1] - b[1]).map(x => x[2]);
}

/** Sortierungen, fuer die es Daten gibt (Kalorien/Eiweiss nur mit Naehrwerten) */
export function availableSorts(meals) {
  const has = k => (meals || []).some(m => typeof m.nutrition?.[k] === "number");
  return SORTS.filter(([k]) => k === "line" || k === "price" || (k === "kcal" && has("energy_kcal")) || (k === "protein" && has("protein")));
}

const num = (v, d = 1) => Number(v).toLocaleString("de-DE", { maximumFractionDigits: d, minimumFractionDigits: 0 });

/** "pro Portion" / "pro 100 g" */
export const basisLabel = n => n?.basis === "100g" ? "pro 100 g" : "pro Portion";

/** Zeilen der Naehrwerte: Brennwert "615 kJ / 147 kcal" (oder nur kcal), dann Gramm; leer ohne Angaben */
export function nutritionRows(meal) {
  const n = meal?.nutrition;
  if (!n) return [];
  const rows = [];
  const kj = typeof n.energy_kj === "number", kcal = typeof n.energy_kcal === "number";
  if (kj || kcal) rows.push({ key: "energy", label: "Brennwert", value: [kj ? `${num(n.energy_kj, 0)} kJ` : "", kcal ? `${num(n.energy_kcal, 0)} kcal` : ""].filter(Boolean).join(" / ") });
  for (const [k, label] of NUTRIENTS) if (typeof n[k] === "number") rows.push({ key: k, label, value: `${num(n[k])} g`, sub: label.startsWith("davon") });
  return rows;
}

/** kurze Zeile auf der Karte: "811 kcal · 53,6 g Eiweiß" (pro Portion) bzw. "93 kcal/100 g" */
export function nutritionShort(meal) {
  const n = meal?.nutrition;
  if (!n || typeof n.energy_kcal !== "number") return "";
  const per = n.basis === "100g" ? "/100 g" : "";
  return `${num(n.energy_kcal, 0)} kcal${per}${typeof n.protein === "number" ? ` · ${num(n.protein)} g Eiweiß${per}` : ""}`;
}

/** Klima: "KlimaTeller", "CO₂e 360 g pro Portion", "CO₂-Bewertung B" */
export function climateRows(meal) {
  const c = meal?.climate;
  if (!c) return [];
  const out = [];
  if (c.klimateller) out.push("KlimaTeller");
  if (typeof c.co2_g === "number") out.push(`CO₂e ${num(c.co2_g, 0)} g pro Portion`);
  if (c.rating) out.push(`CO₂-Bewertung ${c.rating}`);
  return out;
}

// Seitenleiste wie auf dem iPad (Neugestaltung 04.11.2026, AppShell.swift): Gruppen STUDIUM / LERNEN / ALLTAG / GEMEINSAM mit
// kleinen Ueberschriften, "Tests & Wiederholung" und "Karteikarten" als farbige Pillen (blau bzw. pfirsich), unten das
// Konto mit Initialen, Name, Tarif ("Free", "Plus", "Pro AI", "Probe · noch 5 Tage") und "Plus holen →" bzw.
// "Pro AI holen →" zur Tarifseite (#/abo). Tarif und Probe kommen aus GET /api/entitlements (state.entitlements); am
// eigenen PC (nicht gehostet) gibt es keine Tarife.
// kein Import aus core.js (braucht das DOM): so laeuft die Datei auch unter node (tests/js/shell-nav.test.mjs)
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Gruppen der Seitenleiste: [Route, Titel, Symbol, Pille] */
export const NAV_GROUPS = [
  { id: "studium", title: "Studium", items: [["dashboard", "Übersicht", "home"], ["plan", "Lernkalender", "calendar"], ["timetable", "Stundenplan", "clock"],
    ["modules", "Meine Module", "book"], ["studyplan", "Studienverlauf", "columns"], ["files", "Dokumente & Notizen", "folder"], ["services", "Uni & Noten", "graduation"]] },
  { id: "lernen", title: "Lernen", items: [["exams", "Tests & Wiederholung", "exam", "blue"], ["cards", "Karteikarten", "cards", "peach"]] },
  // Mensa (05.11.2026, mensa.js): Speiseplaene der Studentenwerke; Raumfinder (05.11.2026, rooms.js): Standortfinder der
  // LUH mit Link zu Google Maps; beide frei in jedem Tarif
  { id: "alltag", title: "Alltag", items: [["mensa", "Mensa", "utensils"], ["raumfinder", "Raumfinder", "map-pin"]] },
  { id: "gemeinsam", title: "Gemeinsam", items: [["community", "Community", "users"]] },
];

/** alle Eintraege flach (Route, Titel, Symbol) in der Reihenfolge der Seitenleiste */
export const navItems = (groups = NAV_GROUPS) => groups.flatMap(g => g.items);

/** HTML der Navigation; `icon(name, size)` aus core.js */
export function navHtml(icon, groups = NAV_GROUPS) {
  return groups.map(g => `<div class="nav-group" role="group" aria-labelledby="ng-${g.id}"><div class="nav-label" id="ng-${g.id}">${esc(g.title)}</div>`
    + g.items.map(([r, t, i, pill]) => `<a href="#/${r}" data-route="${r}"${pill ? ` class="nav-pill ${pill}"` : ""} title="${esc(t)}">${icon(i, 18)}<span>${esc(t)}</span></a>`).join("")
    + `</div>`).join("");
}

/** Kurzname des Tarifs wie auf dem iPad */
const SHORT = { free: "Free", plus: "Plus", pro_ai: "Pro AI", pro_connect: "Pro AI" };

/** Tarifzeile unter dem Namen: "Probe · noch 5 Tage", "Free", "Plus", "Pro AI"; am eigenen PC "Eigener PC";
    mit Abo-Pflicht (Web, Windows, 05.11.2026) ohne Abo "Kein Abo · nur lesen" */
export function planLabel(ent, hosted) {
  if (!hosted) return "Eigener PC";
  if (ent?.access?.locked) return "Kein Abo · nur lesen";
  const tr = ent?.trial;
  if (tr?.active) { const n = Math.max(1, Number(tr.days_left) || 1); return `Probe · noch ${n} ${n === 1 ? "Tag" : "Tage"}`; }
  return SHORT[ent?.plan] || "Free";
}

/** Knopf zur Tarifseite: Free und Probe "Plus holen", Plus "Pro AI holen", Pro AI keiner; am eigenen PC keiner */
export function upgradeCta(ent, hosted) {
  if (!hosted) return null;
  if (ent?.access?.locked) return { label: "Abo wählen", href: "#/abo" };
  const plan = ent?.plan || "free";
  if (ent?.trial?.active || plan === "free") return { label: "Plus holen", href: "#/abo" };
  if (plan === "plus") return { label: "Pro AI holen", href: "#/abo" };
  return null;
}

/** Initialen aus dem Namen ("Lea Sommer" -> "LS"), sonst aus der E-Mail ("lea@…" -> "LE"), sonst "?" */
export function initials(name, email) {
  const n = String(name || "").trim();
  if (n) return n.split(/\s+/).map(x => x[0]).join("").slice(0, 2).toUpperCase();
  const e = String(email || "").trim();
  return e ? e.slice(0, 2).toUpperCase() : "?";
}

/** angezeigter Name: Name aus den Einstellungen, sonst der Teil der E-Mail vor dem @, sonst "Dein Konto" */
export function displayName(name, email) {
  const n = String(name || "").trim();
  if (n) return n;
  const e = String(email || "").trim();
  return e ? e.split("@")[0] : "Dein Konto";
}

/** Kontoblock unten in der Seitenleiste; `arrow` = Symbol-HTML fuer den Pfeil, `person` = Symbol ohne Namen und E-Mail */
export function accountHtml({ name, email, ent, hosted, arrow = "→", person = "" }) {
  const shown = displayName(name, email), plan = planLabel(ent, hosted), cta = upgradeCta(ent, hosted), ini = initials(name, email);
  return `<button type="button" class="side-acct-who" id="sideAcctBtn" aria-label="${esc(`${shown}, Tarif ${plan}. ${hosted ? "Konto öffnen" : "Einstellungen öffnen"}`)}">`
    + `<span class="side-acct-av" aria-hidden="true">${ini === "?" && person ? person : esc(ini)}</span>`
    + `<span class="side-acct-t"><b>${esc(shown)}</b><small>${esc(plan)}</small></span></button>`
    + (cta ? `<a class="btn primary side-acct-cta" href="${cta.href}" aria-label="${esc(cta.label)}: Tarife ansehen"><span>${esc(cta.label)}</span>${arrow}</a>` : "");
}

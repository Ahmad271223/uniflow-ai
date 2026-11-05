// Studienverlauf selbst gestalten im Web (study-plan-logic.js, 05.11.2026): Semesterlage, Rumpfe fuer POST
// /api/study-plan/settings (verschieben, waehlen, tauschen, nicht belegen, zurueck, Schwerpunkt, eigene Eintraege, zuruecksetzen),
// LP-Summen und Rueckmeldung, Auswahl eines Platzes, Bereiche, Menue, Nur-lesen und die Masse der Gesamtansicht.
// Der Plan unten ist erfunden und hat die Form von GET /api/study-plan (docs/STUDIENVERLAUF-2026-11-04.md "Für Web und iPhone").
import { test } from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/study-plan-logic.js";

const icon = n => `<i data-i="${n}"></i>`;
const mod = (id, title, o = {}) => ({ id, title, kind: "pflicht", lp: 5, turnus: "WS", status: "geplant", hints: [], ...o });

const PLAN = {
  available: true, current_term: "WiSe 26/27", lp_done: 15, lp_total: 180,
  semesters: [
    { term: "WiSe 25/26", fachsemester: 1, lp: 15, modules: [mod("prog1", "Programmieren I", { status: "bestanden", grade: "1,7", semester: 1 }), mod("mathe1", "Mathematik I: Lineare Algebra", { lp: 10, status: "bestanden", semester: 1 })], slots: [] },
    { term: "SoSe 26", fachsemester: 2, lp: 0, modules: [], slots: [] },
    { term: "WiSe 26/27", fachsemester: 3, current: true, lp: 30, lp_slots: 5,
      modules: [mod("dsa", "Datenstrukturen und Algorithmen", { status: "nicht_bestanden", attempt: 1, semester: 3 }), mod("rn", "Rechnernetze", { turnus: "SS", semester: 4, placed: true, hints: ["Laut Katalog nur im Sommersemester angeboten"] }),
        mod("ki", "Künstliche Intelligenz", { kind: "wahlpflicht", lp: 5, area: "vert", semester: null }), mod("eigen-1", "Japanisch I", { kind: "wahl", lp: 4, area: "sg", custom: true, status: "offen" }),
        mod("sem", "Proseminar Netze", { kind: "wahlpflicht", status: "angemeldet", area: "sem", lp: 11 })],
      slots: [{ id: "platz-1", kind: "slot", title: "Seminare", area: "sem", areas: ["sem"], type: "seminar", area_kind: "wahlpflicht", lp: 5, fachsemester: 3 }] },
    { term: "SoSe 27", fachsemester: 4, lp: 40, lp_slots: 15,
      modules: [mod("db", "Grundlagen der Datenbanksysteme", { turnus: "SS", semester: 4 }), mod("ba", "Bachelorarbeit", { kind: "abschluss", lp: 35, turnus: "WS+SS", semester: 6 })],
      slots: [{ id: "platz-2", kind: "track", title: "Schwerpunkt wählen", group: "schwerpunkt", areas: ["sp-a", "sp-b"], type: "schwerpunkt", area_kind: "wahlpflicht", lp: 15 }] },
  ],
  areas: [
    { id: "pflicht", name: "Pflicht", type: "pflicht", kind: "pflicht", active: true, choice: false, target: 100, lp_done: 15, lp_planned: 40 },
    { id: "sem", name: "Seminare", type: "seminar", kind: "wahlpflicht", active: true, choice: true, target: 5, lp_required: 5, modules_required: 1, count: 0, lp_done: 0, lp_planned: 0, lp_open: 5, options: 3, rule: "Ein Seminar aus der Liste." },
    { id: "vert", name: "Vertiefung", type: "vertiefung", kind: "wahlpflicht", active: true, choice: true, target: 15, lp_done: 0, lp_planned: 5, lp_open: 10, options: 12 },
    { id: "sg", name: "Studium generale", type: "studium_generale", kind: "wahl", active: true, choice: true, target: null, lp_done: 0, lp_planned: 0, options: 0 },
    { id: "abschluss", name: "Abschluss", type: "abschluss", kind: "abschluss", active: true, target: 35, lp_done: 0, lp_planned: 35 },
    { id: "sp-a", name: "Schwerpunkt A", type: "schwerpunkt", kind: "wahlpflicht", group: "schwerpunkt", active: false, options: 6, lp_max: 25 },
    { id: "sp-b", name: "Schwerpunkt B", type: "schwerpunkt", kind: "wahlpflicht", group: "schwerpunkt", active: false, options: 4, lp_required: 20 },
  ],
  groups: [{ id: "schwerpunkt", label: "Schwerpunkt", options: ["sp-a", "sp-b"], chosen: null, auto: false }],
  electives: [
    { id: "ki", title: "Künstliche Intelligenz", kind: "wahlpflicht", area: "vert", areas: ["vert"], lp: 5, semester: null, turnus: "WS", chosen: true, included: true },
    { id: "sem-a", title: "Seminar Sicherheit", kind: "wahlpflicht", area: "sem", areas: ["sem"], lp: 5, semester: 5, turnus: "SS", chosen: false, included: false },
    { id: "sem-b", title: "Seminar Algorithmen", kind: "wahlpflicht", area: "sem", areas: ["sem"], lp: 5, semester: 3, turnus: "WS", chosen: false, included: false },
    { id: "ml", title: "Maschinelles Lernen", kind: "wahlpflicht", area: "vert", areas: ["vert", "sem"], lp: 5, semester: null, turnus: "WS+SS", chosen: false, included: false },
    { id: "sem", title: "Proseminar Netze", kind: "wahlpflicht", area: "sem", areas: ["sem"], lp: 11, chosen: true, included: true },
  ],
  excluded: [{ id: "mci", title: "Mensch-Computer-Interaktion", kind: "pflicht", lp: 5, semester: 3 }],
  placements: { rn: "WiSe 26/27" },
};

test("Semesternamen wie im Kern: parse_term / term_name", () => {
  assert.equal(L.parseTerm("WiSe 25/26"), 2025 * 2 + 1);
  assert.equal(L.parseTerm("SoSe 26"), 2026 * 2);
  assert.equal(L.parseTerm("WS 2025/26"), 2025 * 2 + 1);
  assert.equal(L.parseTerm("Sommersemester 2027"), 2027 * 2);
  assert.equal(L.parseTerm("Herbst 26"), null);
  assert.equal(L.termName(2026 * 2 + 1), "WiSe 26/27");
  assert.equal(L.termName(2027 * 2), "SoSe 27");
  assert.equal(L.termName(2099 * 2 + 1), "WiSe 99/00");
});

test("Verschieben nach …: ab dem aktuellen Semester bis vier nach dem letzten, Fachsemester auch danach", () => {
  assert.deepEqual(L.moveTerms(PLAN), ["WiSe 26/27", "SoSe 27", "WiSe 27/28", "SoSe 28", "WiSe 28/29", "SoSe 29"]);
  assert.equal(L.fachsemesterOf(PLAN, "SoSe 27"), 4);
  assert.equal(L.fachsemesterOf(PLAN, "SoSe 29"), 8);
  assert.equal(L.fachsemesterOf(PLAN, "quatsch"), null);
  assert.deepEqual(L.moveTerms({ semesters: [{ term: "SoSe 26" }] }), ["SoSe 26", "WiSe 26/27", "SoSe 27", "WiSe 27/28", "SoSe 28"], "ohne aktuelles Semester ab dem ersten");
});

test("LP je Zeile: danach-Summe, Warnung ueber 36 LP, Turnus-Warnung, jetzige Lage", () => {
  const rows = L.moveRows(PLAN, PLAN.semesters[2].modules[1]);            // Rechnernetze (SS) liegt im WiSe 26/27
  const here = rows.find(r => r.current);
  assert.equal(here.term, "WiSe 26/27");
  assert.equal(here.lp, 30, "die jetzige Lage zaehlt das Modul nicht doppelt");
  const so27 = rows.find(r => r.term === "SoSe 27");
  assert.deepEqual([so27.lp, so27.over, so27.warn], [45, true, null]);
  const wi27 = rows.find(r => r.term === "WiSe 27/28");
  assert.deepEqual([wi27.lp, wi27.over, wi27.warn, wi27.fach], [5, false, "Laut Katalog nur im Sommersemester angeboten", 5]);
  const html = L.moveHtml(PLAN, PLAN.semesters[2].modules[1], icon);
  assert.match(html, /aria-current="true"[^>]*aria-label="WiSe 26\/27, 3\. Fachsemester, aktuelle Lage"/);
  assert.match(html, /danach 45 LP in diesem Semester/);
  assert.match(html, /data-reset-one="rn"[\s\S]*Ins empfohlene Semester/, "selbst gelegt: zurueck ins empfohlene Semester");
  assert.equal(L.turnusWarning("WS", "SoSe 27"), "Laut Katalog nur im Wintersemester angeboten");
  assert.equal(L.turnusWarning("WS+SS", "SoSe 27"), null);
  assert.equal(L.lpFree({ lp: 18 }), 12);
  assert.equal(L.lpFree({ lp: 40 }), 0);
  assert.equal(L.overloaded({ lp: 36 }), false);
  assert.equal(L.overloaded({ lp: 37 }), true);
});

test("Spaltenkopf: LP-Summe, Warnung ueber 36 LP, + n LP offen, Ablageziel nur beim Bearbeiten", () => {
  const sem = PLAN.semesters[3];
  const edit = L.semesterHtml(sem, icon, { edit: true, plan: PLAN });
  assert.match(edit, /class="sp-sem over" data-term="SoSe 27" data-drop="SoSe 27"/);
  assert.match(edit, /badge warn"><i data-i="alert"><\/i>40 LP/);
  assert.match(edit, /\+ 15 LP offen/);
  assert.match(edit, /aria-label="SoSe 27, 4\. Fachsemester, 40 Leistungspunkte, mehr als der Richtwert, dazu 15 Leistungspunkte offene Wahl"/);
  const ro = L.semesterHtml(sem, icon, { edit: false, plan: PLAN });
  assert.ok(!ro.includes("data-drop"), "nur lesen: kein Ablegen");
  assert.ok(!ro.includes("draggable"), "nur lesen: nichts zum Ziehen");
  assert.match(ro, /<div class="sp-slot track"[^>]*role="group"/, "Platz nur als Anzeige");
  assert.ok(!L.semesterHtml(sem, icon).includes("sp-slot"), "ohne Optionen wie bisher (ohne Plaetze)");
});

test("Karten: bestanden gesperrt, Ziehen und Menue nur fuer verschiebbare, Etiketten und Hinweise", () => {
  const passed = L.moduleCardHtml(PLAN.semesters[0].modules[0], icon, { edit: true, plan: PLAN });
  assert.ok(!passed.includes("draggable"), "Bestandenes bleibt im Semester aus QIS");
  assert.match(passed, /sp-card locked/);
  assert.ok(!passed.includes("data-menu"), "Bestanden: nur Details, kein Menue");
  const rn = L.moduleCardHtml(PLAN.semesters[2].modules[1], icon, { edit: true, plan: PLAN });
  assert.match(rn, /draggable="true" data-drag="rn"/);
  assert.match(rn, /data-menu="rn" aria-haspopup="menu" aria-expanded="false" aria-label="Aktionen für Rechnernetze"/);
  assert.match(rn, /Selbst eingeplant/);
  assert.match(rn, /sp-hint"><i data-i="alert"><\/i><span>Laut Katalog nur im Sommersemester angeboten/);
  assert.match(rn, /aria-label="Rechnernetze, 5 Leistungspunkte, Pflicht, Sommersemester, Geplant, selbst eingeplant, Laut Katalog nur im Sommersemester angeboten"/);
  const custom = L.moduleCardHtml(PLAN.semesters[2].modules[3], icon, { edit: true, plan: PLAN });
  assert.match(custom, /Eigener Eintrag/);
  assert.ok(!custom.includes("draggable"), "eigener Eintrag liegt im eigenen Fachsemester");
  const evil = L.moduleCardHtml(mod("x\"><b>", "<img src=x onerror=1>"), icon, { edit: true, plan: PLAN });
  assert.ok(!evil.includes("<img") && !evil.includes('x"><b>'), "Titel und id escaped");
});

test("Menue Aktionen: Verschieben, ins empfohlene Semester, Tauschen nur fuer gewaehlte Wahlmodule, Nicht belegen", () => {
  const acts = m => L.menuItems(m, PLAN).map(x => x[0]);
  const s3 = PLAN.semesters[2].modules;
  assert.deepEqual(acts(PLAN.semesters[0].modules[0]), ["detail"]);
  assert.deepEqual(acts(s3[0]), ["detail", "move", "drop"], "nicht bestanden: kein Tauschen");
  assert.deepEqual(acts(s3[1]), ["detail", "move", "reset", "drop"]);
  assert.deepEqual(acts(s3[2]), ["detail", "move", "replace", "drop"]);
  assert.deepEqual(acts(s3[3]), ["detail", "remove"]);
  assert.deepEqual(acts(s3[4]), ["detail", "move", "drop"], "angemeldet: nicht tauschen");
  const html = L.menuHtml(s3[2], PLAN, icon);
  assert.match(html, /role="menu" aria-label="Aktionen für Künstliche Intelligenz"/);
  assert.equal((html.match(/role="menuitem"/g) || []).length, 4);
  assert.match(html, /class="danger" data-act="drop"/);
});

test("Rumpfe: verschieben und zurueck ins empfohlene Semester behalten die uebrige eigene Lage", () => {
  assert.deepEqual(L.editMove(PLAN, "db", "WiSe 27/28"), { placements: { rn: "WiSe 26/27", db: "WiSe 27/28" } });
  assert.deepEqual(L.editResetPlacement(PLAN, "rn"), { placements: {} });
  assert.deepEqual(PLAN.placements, { rn: "WiSe 26/27" }, "Plan bleibt unveraendert");
  assert.deepEqual(L.EDIT_RESET, { placements: null, excluded: null });
});

test("Rumpfe: waehlen in einen Platz, zurueck in den Plan, tauschen, nicht belegen", () => {
  const semA = PLAN.electives[1];
  assert.deepEqual(L.editChoose(PLAN, semA, "WiSe 26/27"), { electives: ["ki", "sem", "sem-a"], placements: { rn: "WiSe 26/27", "sem-a": "WiSe 26/27" } });
  assert.deepEqual(L.editChoose(PLAN, { ...PLAN.excluded[0], excluded: true }, null), { excluded: [] }, "Pflichtmodul zurueckholen");
  assert.deepEqual(L.editReplace(PLAN, "ki", PLAN.electives[3], "WiSe 26/27"), { electives: ["sem", "ml"], placements: { rn: "WiSe 26/27", ml: "WiSe 26/27" } });
  const s3 = PLAN.semesters[2].modules;
  assert.deepEqual(L.editDrop(PLAN, s3[2]), { electives: ["sem"] }, "gewaehltes Wahlmodul abwaehlen");
  assert.deepEqual(L.editDrop(PLAN, s3[1]), { excluded: ["mci", "rn"], placements: {} }, "Pflichtmodul ausschliessen, Lage weg");
});

test("Rumpfe: Schwerpunkt und eigene Eintraege", () => {
  assert.deepEqual(L.editTrack(PLAN, "schwerpunkt", "sp-b"), { tracks: { schwerpunkt: "sp-b" } });
  const auto = { ...PLAN, groups: [{ id: "nebenfach", chosen: "nf-m", auto: true }, { id: "schwerpunkt", chosen: "sp-a", auto: false }] };
  assert.deepEqual(L.editTrack(auto, "schwerpunkt", null), { tracks: {} }, "aus QIS geschlossene Gruppe bleibt automatisch");
  assert.deepEqual(L.editAddCustom(PLAN, "  Spanisch A1 ", 3, "sg", 3), { custom: [
    { id: "eigen-1", title: "Japanisch I", lp: 4, area: "sg", semester: 3 }, { title: "Spanisch A1", lp: 3, area: "sg", semester: 3 }] });
  assert.deepEqual(L.editRemoveCustom(PLAN, "eigen-1"), { custom: [] });
  assert.equal(L.parseLp("2,5"), 2.5);
  assert.equal(L.parseLp("999"), 60);
  assert.equal(L.parseLp("x"), 0);
});

test("Rueckmeldung: verschoben, vorgezogen, mehrere vorgezogen, freie LP im Ausgangssemester", () => {
  const from = { term: "SoSe 27", fachsemester: 4, lp: 40 };
  const after = { semesters: [{ term: "WiSe 26/27", fachsemester: 3, lp: 35, modules: [mod("db", "Grundlagen der Datenbanksysteme", { placed: true, semester: 4 })] }, { term: "SoSe 27", fachsemester: 4, lp: 18, modules: [] }] };
  assert.equal(L.moveMessage("Grundlagen der Datenbanksysteme", from, "WiSe 26/27", after), "Grundlagen der Datenbanksysteme vorgezogen nach WiSe 26/27 – im 4. Semester sind jetzt 12 LP frei");
  after.semesters[0].modules.push(mod("a", "A", { placed: true, semester: 4 }), mod("b", "B", { placed: true, semester: 5 }));
  assert.equal(L.moveMessage("A", from, "WiSe 26/27", after), "3 Module vorgezogen – im 4. Semester sind jetzt 12 LP frei");
  assert.equal(L.moveMessage("Rechnernetze", { term: "WiSe 26/27", fachsemester: 3 }, "WiSe 27/28", after), "Rechnernetze verschoben nach WiSe 27/28 – im 3. Semester sind jetzt 0 LP frei");
});

test("Platz: Titel mit LP, Zeile je Bereich, Vorlesetext, Richtung", () => {
  const [sl] = PLAN.semesters[2].slots, tr = PLAN.semesters[3].slots[0];
  assert.equal(L.slotTitle(sl), "Seminare (5 LP)");
  assert.equal(L.slotLine(sl, PLAN), "0 von 1 Modulen gewählt");
  assert.equal(L.slotLine({ area: "vert" }, PLAN), "noch 10 von 15 LP offen");
  assert.equal(L.slotLine({ area: "sg" }, PLAN), "0 Module zur Wahl");
  assert.equal(L.slotLine(tr, PLAN), "Eine von 2 Richtungen wählen");
  assert.equal(L.slotLabel(sl, PLAN), "Offener Platz, Seminare (5 Leistungspunkte), Wahlpflicht, 0 von 1 Modulen gewählt");
  const html = L.slotCardHtml(sl, PLAN, icon, true, "WiSe 26/27");
  assert.match(html, /<button type="button" class="sp-slot" data-slot="platz-1" data-term="WiSe 26\/27"/);
  assert.match(html, /sp-tag line">Seminar</);
  assert.match(L.slotCardHtml(tr, PLAN, icon, true, "SoSe 27"), /sp-slot track[\s\S]*data-i="layers"/);
  assert.equal(L.findSlot(PLAN, "platz-2").term, "SoSe 27");
  const t = L.tracksHtml(PLAN, tr, icon);
  assert.match(t, /data-pick-track="sp-a" aria-pressed="false"[\s\S]*6 Module · bis 25 LP/);
  assert.match(t, /Schwerpunkt B[\s\S]*bis 20 LP/);
});

test("Auswahl: nur erlaubte Bereiche, nicht schon im Plan, nicht belegte dazu, Suche, Sortierung", () => {
  const [sl] = PLAN.semesters[2].slots;
  assert.deepEqual(L.choices(PLAN, sl).map(o => o.id), ["sem-b", "sem-a", "ml"], "Semester zuerst, ohne Semester zuletzt; ml gehoert auch zu sem");
  assert.deepEqual(L.choices(PLAN, sl, "sicher").map(o => o.id), ["sem-a"]);
  assert.deepEqual(L.choices(PLAN, null).map(o => o.id), ["mci", "sem-b", "sem-a", "ml"], "Modul hinzufuegen: alles, auch nicht belegte");
  assert.deepEqual(L.choices(PLAN, { areas: [] }).map(o => o.id).sort(), ["mci", "ml", "sem-a", "sem-b"], "leere Bereichsliste = alle");
  const list = L.chooserListHtml(PLAN, sl, "", { expanded: "sem-a", details: { "sem-a": { exam: "Referat", texts: { content: "Aktuelle Arbeiten zur Sicherheit." } } }, target: "WiSe 26/27" }, icon);
  assert.match(list, /data-opt="sem-a" aria-expanded="true"/);
  assert.match(list, /Prüfung: Referat[\s\S]*Aktuelle Arbeiten zur Sicherheit\.[\s\S]*Laut Katalog nur im Sommersemester angeboten[\s\S]*data-choose="sem-a"[^>]*>.*In WiSe 26\/27 wählen/);
  assert.match(L.chooserListHtml(PLAN, sl, "zzz", { target: "" }, icon), /Für diesen Platz gibt es im Katalog keine weiteren Module/);
  assert.match(L.chooserListHtml({ ...PLAN, electives: [], excluded: [] }, null, "", {}, icon), /Alle Module des Katalogs sind schon im Plan/);
  assert.match(L.chooserHeadHtml(PLAN, null, "SoSe 27"), /<option value="SoSe 27" selected>SoSe 27 · 4\. Fachsemester/);
  assert.match(L.chooserHeadHtml(PLAN, sl), /Seminare \(5 LP\)<\/b> · 0 von 1 Modulen gewählt[\s\S]*Ein Seminar aus der Liste\./);
  const rs = L.replaceSlot(PLAN, PLAN.semesters[2].modules[2]);
  assert.deepEqual([rs.title, rs.areas, rs.term], ["Statt Künstliche Intelligenz", ["vert"], "WiSe 26/27"]);
  assert.match(L.customBlockHtml(icon), /id="spCustAdd" disabled/);
});

test("Bereiche und Wahl: Gruppe offen, Fortschritt, Abschluss weg, Nicht belegt mit Zurück in den Plan", () => {
  assert.deepEqual(L.shownAreas(PLAN).map(a => a.id), ["sem", "vert", "pflicht"], "Wahl zuerst, Abschluss und leere ohne Ziel weg");
  assert.equal(L.areaLine(PLAN.areas[0]), "55 von 100 LP · 15 bestanden");
  assert.equal(L.areaLine(PLAN.areas[1]), "0 von 5 LP · 0 von 1 Modulen");
  const html = L.areasHtml(PLAN, icon, true);
  assert.match(html, /Schwerpunkt: noch nicht gewählt<\/b><button type="button" class="btn sm" data-track="schwerpunkt" aria-label="Schwerpunkt wählen">Wählen/);
  assert.match(html, /<i style="width:55%">/);
  assert.match(html, /data-restore="mci" aria-label="Mensch-Computer-Interaktion zurück in den Plan"/);
  const ro = L.areasHtml(PLAN, icon, false);
  assert.ok(!ro.includes("data-restore") && !ro.includes("data-track"), "nur lesen: keine Knoepfe");
  assert.equal(L.areasHtml({ ...PLAN, groups: [], excluded: [], areas: [PLAN.areas[0]] }, icon, true), "", "ohne Wahl kein Kasten");
  const chosen = L.areasHtml({ ...PLAN, groups: [{ id: "nf", label: "Nebenfach", chosen: "vert", auto: true }] }, icon, true);
  assert.match(chosen, /Nebenfach: Vertiefung \(aus QIS\)[\s\S]*>Ändern</);
});

test("Nur lesen: Hinweis mit Abo-Link; Board ohne Ziehen, Menue und Plaetze zum Waehlen", () => {
  assert.match(L.readOnlyHtml(icon), /Nur lesen\.[\s\S]*href="#\/abo"/);
  const board = L.boardHtml(PLAN, "all", icon, { edit: false });
  assert.ok(!/draggable|data-menu|data-drop|<button type="button" class="sp-slot/.test(board));
  const edit = L.boardHtml(PLAN, "all", icon, { edit: true });
  assert.equal((edit.match(/data-drop=/g) || []).length, 4);
  assert.ok(!L.boardHtml(PLAN, "passed", icon, { edit: true }).includes("sp-slot"), "Filter Bestanden: keine Plaetze");
});

test("Gesamtansicht breit: eine Reihe quer, zwei hochkant, Chip-Hoehe 14–30 px nach freiem Platz", () => {
  const sems = n => Array.from({ length: n }, (_, i) => ({ titles: Array.from({ length: i === 2 ? 12 : 4 }, (_, j) => `Modul ${j}`) }));
  const wide = L.overviewLayout({ width: 1100, height: 680, semesters: sems(7) });
  assert.deepEqual([wide.mode, wide.rows, wide.perRow], ["cols", 1, 7]);
  assert.equal(wide.colWidth, Math.floor((1100 - 36) / 7));
  assert.equal(wide.chip, 30, "viel Hoehe: 30 px");
  assert.equal(L.overviewLayout({ width: 1100, height: 400, semesters: sems(7) }).chip, Math.floor((400 - 34 - 36) / 12), "sonst Hoehe durch die meisten Chips");
  assert.equal(wide.fits, true);
  const tall = L.overviewLayout({ width: 760, height: 1000, semesters: sems(8) });
  assert.deepEqual([tall.rows, tall.perRow], [2, 4], "hochkant ab fuenf Semestern zwei Reihen");
  const cramped = L.overviewLayout({ width: 700, height: 320, semesters: sems(7) });
  assert.equal(cramped.rows, 2, "zu schmale Spalten: zwei Reihen");
  assert.equal(cramped.chip, 14, "nie kleiner als 14 px");
  assert.equal(cramped.fits, false);
  const roomy = L.overviewLayout({ width: 1400, height: 900, semesters: [{ titles: ["A"] }, { titles: [] }] });
  assert.deepEqual([roomy.chip, roomy.font], [30, 12.5], "hoechstens 30 px, Schrift 12,5");
});

test("Gesamtansicht schmal (Telefon 390 px): Semester untereinander, groesste Schrift, die in die Hoehe passt", () => {
  const plan = { semesters: Array.from({ length: 7 }, (_, i) => ({ titles: Array.from({ length: [3, 3, 2, 0, 13, 8, 3][i] }, (_, j) => `Grundlagen der Informatik ${j}`) })) };
  const lay = L.overviewLayout({ width: 358, height: 700, semesters: plan.semesters });
  assert.equal(lay.mode, "stack");
  assert.ok(lay.fits && lay.total <= 700);
  assert.equal(lay.font, 11.5, "12,5 und 12 passen nicht mehr, 11,5 schon");
    assert.equal(lay.chipMax, Math.floor((358 - 14 - 4) / 2), "hoechstens zwei Chips nebeneinander bei langen Titeln");
  const bigger = L.overviewLayout({ width: 358, height: 2000, semesters: plan.semesters });
  assert.equal(bigger.font, 12.5, "viel Platz: groesste Schrift");
    const tiny = L.overviewLayout({ width: 358, height: 200, semesters: plan.semesters });
  assert.deepEqual([tiny.font, tiny.fits], [9.5, false], "passt es nie, bleibt die Schrift lesbar und die Seite rollt");
});

test("Gesamtansicht HTML: Chips mit Kurzname, LP, Statusfarbe, Warnzeichen; Plaetze gestrichelt; Ziehen nur beim Bearbeiten", () => {
  const lay = L.overviewLayout({ width: 1100, height: 680, semesters: L.overviewInput(PLAN) });
  const html = L.overviewHtml(PLAN, lay, icon, true);
  assert.match(html, /class="sp-ov cols" id="spOverview" style="--cols:4;/);
  assert.match(html, /class="sp-chip t-ok passed" data-module="prog1"/);
  assert.match(html, /class="sp-chip t-bad" data-module="dsa" draggable="true" data-drag="dsa" data-ctx="dsa" aria-haspopup="menu"/);
  assert.match(html, /data-module="rn"[\s\S]*?<span class="w">/, "Hinweis: Warnzeichen");
  assert.match(html, /class="sp-chip slot" data-slot="platz-1" data-term="WiSe 26\/27"/);
  assert.match(html, /sp-ov-col current" data-term="WiSe 26\/27" data-drop="WiSe 26\/27"/);
  assert.match(html, /sp-ov-lp over" aria-hidden="true">40<small>\+15<\/small>/);
  const ro = L.overviewHtml(PLAN, lay, icon, false);
  assert.ok(!/draggable|data-drop|data-ctx|<button type="button" class="sp-chip slot/.test(ro));
  const stack = L.overviewHtml(PLAN, L.overviewLayout({ width: 358, height: 600, semesters: L.overviewInput(PLAN) }), icon, true);
  assert.match(stack, /class="sp-ov stack" id="spOverview" style="--chip:\d+px;--cf:[\d.]+px;--cmax:\d+px"/);
  assert.equal(L.chipTone({ status: "angemeldet" }), "info");
  assert.equal(L.chipTone({ status: "geplant", moved_from: "SoSe 26" }), "warn");
  assert.equal(L.chipTone({ status: "offen" }), "neutral");
});

test("Kurznamen wie am iPad: passt, Fuellwoerter weg, Woerter kuerzen, Anfangsbuchstaben", () => {
  assert.equal(L.abbreviation("Rechnernetze", 200, 12), "Rechnernetze");
  assert.equal(L.abbreviation("Grundlagen der Rechnernetze", 150, 12), "Grundla. Rechner.");
  assert.equal(L.abbreviation("Grundlagen der Rechnernetze", 100, 12), "Grund. Rechn.");
  assert.equal(L.abbreviation("Grundlagen der Rechnernetze und Betriebssysteme", 40, 12), "GRB");
  assert.equal(L.abbreviation("Mathematik II", 40, 12), "M II");
});

test("Einstellungen: Schwerpunkt und eigene Eintraege nur, wenn geaendert", () => {
  const ui = { tracks: L.tracksBefore(PLAN), removed: new Set() };
  assert.deepEqual(L.settingsExtraBody(PLAN, ui), {});
  ui.tracks.schwerpunkt = "sp-a";
  ui.removed.add("eigen-1");
  assert.deepEqual(L.settingsExtraBody(PLAN, ui), { tracks: { schwerpunkt: "sp-a" }, custom: [] });
  const html = L.settingsExtraHtml(PLAN, { tracks: { schwerpunkt: "sp-a" }, removed: new Set() }, icon);
  assert.match(html, /data-set-track="schwerpunkt"[\s\S]*<option value="sp-a" selected>Schwerpunkt A/);
  assert.match(html, /data-rm-custom="eigen-1" aria-label="Japanisch I entfernen"/);
  assert.equal(L.settingsExtraHtml({ available: false }, ui, icon), "");
  assert.match(L.settingsHtml({ po_options: [], term_options: [], elective_options: [] }, { po: "", start: "", chosen: new Set() }, icon, "<p>EXTRA</p>"), /<p>EXTRA<\/p><div class="sp-err small" id="spSetErr" hidden><\/div><\/div>$/);
});

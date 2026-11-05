// Studienverlauf im Web (study-plan-logic.js): Beschriftungen, Filter, "Nachholen im naechsten passenden Semester", Zustaende ohne
// Plan, Katalogsuche, Moduldetail, Einstellungen, Studiengang-Auswahl. Die Antworten sind die des Backends aus dem gemeinsamen
// Fixture (packages/shared-contracts/fixtures/study-plan-engine/endpoints.json, erfunden), damit Web und iPad dasselbe lesen.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../../app/static/study-plan-logic.js";

const fx = JSON.parse(readFileSync(new URL("../../packages/shared-contracts/fixtures/study-plan-engine/endpoints.json", import.meta.url), "utf8"));
const step = (i) => fx.steps[i].response;
const PLAN = step(4);                    // Technische Informatik PO 2022, Programmieren II nicht bestanden
const NONE = step(0);                    // ohne Katalog
const icon = n => `<i data-i="${n}"></i>`;

test("Zahlen, LP und Fortschritt deutsch", () => {
  assert.equal(L.number(5), "5");
  assert.equal(L.number(2.5), "2,5");
  assert.equal(L.lpText(7.5), "7,5 LP");
  assert.equal(L.progressText(84, 180), "84 von 180 LP");
  assert.equal(L.percent(90, 180), 50);
  assert.equal(L.percent(5, 0), 0);
  assert.equal(L.fach(3), "3. Fachsemester");
  assert.equal(L.fach(null), null);
});

test("Status wie auf dem iPad: bestanden, angemeldet, nicht bestanden, verschoben, geplant, offen", () => {
  assert.equal(L.statusKey("bestanden"), "passed");
  assert.equal(L.statusKey("angemeldet"), "registered");
  assert.equal(L.statusKey("nicht_bestanden"), "failed");
  assert.equal(L.statusKey("Nicht bestanden"), "failed");
  assert.equal(L.statusKey("geplant", "SoSe 26"), "moved", "verschoben, wenn moved_from gesetzt ist");
  assert.equal(L.statusKey("geplant"), "planned");
  assert.equal(L.statusKey("offen"), "open");
  assert.equal(L.statusText({ status: "bestanden", grade: "1,7" }), "Bestanden · 1,7");
  assert.equal(L.statusText({ status: "bestanden", grade: 2 }), "Bestanden · 2,0");
  assert.equal(L.statusText({ status: "nicht_bestanden", attempt: 2 }), "Nicht bestanden · Versuch 2");
  assert.equal(L.statusText({ status: "geplant", moved_from: "SoSe 26" }), "Verschoben · aus SoSe 26");
  assert.equal(L.statusText({ status: "offen" }), "Offen");
  assert.equal(L.isOpen({ status: "bestanden" }), false);
  assert.equal(L.isOpen({ status: "geplant" }), true);
});

test("Art, Turnus und Vorlesetext", () => {
  assert.equal(L.kindText("wahlpflicht"), "Wahlpflicht");
  assert.equal(L.kindText("abschluss"), "Abschluss");
  assert.equal(L.kindClass("wahl"), "teal");
  assert.equal(L.turnusShort("WS"), "WiSe");
  assert.equal(L.turnusShort("SS"), "SoSe");
  assert.equal(L.turnusShort("WS+SS"), "jedes Semester");
  assert.equal(L.turnusShort("unbekannt"), null);
  assert.equal(L.turnusLong("SS"), "Sommersemester");
  const m = { title: "Programmieren I", lp: 5, kind: "pflicht", turnus: "WS", status: "bestanden", grade: "1,7" };
  assert.equal(L.moduleLabel(m), "Programmieren I, 5 Leistungspunkte, Pflicht, Wintersemester, Bestanden, 1,7");
});

test("Plan aus dem Fixture: Zahlen, Filter und Semester", () => {
  assert.equal(PLAN.available, true);
  const c = L.counts(PLAN);
  assert.equal(c.all, L.allModules(PLAN).length);
  assert.equal(c.passed, 6);
  assert.equal(c.open, c.all - c.passed);
  assert.equal(L.visibleSemesters(PLAN, "all").length, 7);
  const open = L.visibleSemesters(PLAN, "open");
  assert.ok(open.every(s => s.modules.length && s.modules.every(L.isOpen)), "Filter Offen behaelt nur offene Module");
  assert.ok(open.length < 7, "Semester ohne offene Module fallen weg");
  assert.equal(open.find(s => s.term === "SoSe 27").lp, 32, "die LP-Summe bleibt die des ganzen Semesters");
  const passed = L.visibleSemesters(PLAN, "passed");
  assert.deepEqual(passed.map(s => s.term), ["WiSe 25/26", "SoSe 26"]);
});

test("Nachholen im naechsten passenden Semester: nicht Bestandenes und Liegengebliebenes, nicht jede Verschiebung", () => {
  const b = L.backlog(PLAN);
  assert.deepEqual(b.map(x => x.id), ["programmieren-2", "rechnerstrukturen", "et-2", "datenstrukturen"]);
  assert.deepEqual(b[0], { id: "programmieren-2", title: "Programmieren II", lp: 5, to: "SoSe 27", from: "SoSe 26", attempt: 1,
    reason: "Nicht bestanden – nächster Versuch", current: false, last: false, status: "failed" });
  assert.ok(!b.some(x => x.id === "betriebssysteme"), "Verschiebung wegen Voraussetzung ist kein Nachholen");
  const html = L.backlogHtml(PLAN, icon);
  assert.match(html, /Nachholen im nächsten passenden Semester/);
  assert.match(html, /aus SoSe 26 → <b>SoSe 27<\/b>/);
  assert.match(html, /Versuch 1/);
  assert.equal(L.backlogHtml({ semesters: [{ term: "WiSe 26/27", modules: [{ id: "a", status: "bestanden" }] }] }), "", "ohne Eintraege keine Karte");
});

test("Modulkarte: Streifen je Bereich, Art, Turnus, Status, Grund und letzter Versuch", () => {
  const sem = PLAN.semesters.find(s => s.term === "SoSe 27");
  const m = sem.modules.find(x => x.id === "programmieren-2");
  const html = L.moduleCardHtml({ ...m, last_attempt: true }, icon);
  assert.match(html, /data-module="programmieren-2"/);
  assert.match(html, /class="sp-mod failed"/);
  assert.match(html, /Nicht bestanden · Versuch 1/);
  assert.match(html, /aus SoSe 26 · Nicht bestanden – nächster Versuch/);
  assert.match(html, /Letzter Versuch/);
  assert.match(html, /aria-label="Programmieren II, 5 Leistungspunkte, Pflicht,/);
  assert.equal(L.areaColor("informatik"), L.areaColor("informatik"), "gleiche Farbe fuer denselben Bereich");
  assert.equal(L.areaColor(null), "");
});

test("Semesterspalte: Aktuell-Marke, Fachsemester, Warnung ab mehr als 36 LP, HTML wird maskiert", () => {
  const cur = L.semesterHtml(PLAN.semesters.find(s => s.current), icon);
  assert.match(cur, /sp-sem current/);
  assert.match(cur, /Aktuell/);
  assert.match(cur, /3\. Fachsemester/);
  const over = L.semesterHtml({ term: "SoSe 28", fachsemester: 6, lp: 40, current: false, modules: [{ id: "x", title: "<img onerror=x>", lp: 40, kind: "pflicht", turnus: "SS", status: "geplant" }] }, icon);
  assert.match(over, /mehr als der Richtwert/);
  assert.match(over, /badge warn/);
  assert.ok(!over.includes("<img onerror"), "Titel maskiert");
  assert.match(L.semesterHtml({ term: "T", lp: 0, modules: [] }), /Keine Module geplant/);
});

test("Kopfkarte: Ring, Studiengang, PO, Hinweise und der Satz zur Pruefungsordnung", () => {
  const h = L.headerHtml(PLAN, icon);
  assert.match(h, /Technische Informatik B\.Sc\./);
  assert.match(h, /PO 2022 · Katalog WS 2025\/26/);
  assert.match(h, /<b>37<\/b><small>von 59 LP<\/small>|von \d+ LP/);
  assert.match(h, /Du liegst 22 LP hinter dem Studienverlaufsplan/);
  assert.match(h, /Verbindlich ist die Prüfungsordnung deiner Hochschule\./);
  assert.match(h, /--p:\d+\.\d/);
});

test("Pruefungsordnung bestaetigen nur solange sie vorgeschlagen ist", () => {
  assert.equal(L.poCardHtml({ suggested_po: "2022", po_confirmed: true }), "");
  assert.equal(L.poCardHtml({ po_confirmed: false }), "");
  const html = L.poCardHtml({ suggested_po: "2025", po_confirmed: false, qis_program: "Technische Informatik (PO-Version 2017)" }, icon);
  assert.match(html, /PO 2025\?/);
  assert.match(html, /QIS nennt „Technische Informatik \(PO-Version 2017\)“/);
  assert.match(html, /id="spPoYes"/);
});

test("Zustaende ohne Plan: QIS verbinden, Katalog laedt, kein Katalog, Studiengang waehlen", () => {
  assert.equal(L.gapKind(PLAN, null), null);
  // ohne QIS-Studiengang und ohne gewaehlte Ordnung: QIS verbinden (wie auf dem iPad)
  assert.equal(L.gapKind({ ...NONE, qis_program: null, program: null, po_confirmed: false }, null), "noqis");
  // QIS bekannt, Suche laeuft: laedt; fertig ohne Fund: kein Katalog; Fehler: Ladekarte mit Erneut-Knopf
  const known = { ...NONE, qis_program: "Musterfach", po_confirmed: false };
  assert.equal(L.gapKind(known, { state: "searching" }), "loading");
  assert.equal(L.gapKind(known, { state: "downloading" }), "loading");
  assert.equal(L.gapKind(known, { state: "not_found" }), "nocatalog");
  assert.equal(L.gapKind(known, { state: "error" }), "loading");
  // Ordnung gewaehlt (auch ohne QIS): nie "QIS verbinden"
  assert.equal(L.gapKind({ ...NONE, po_confirmed: true }, { state: "not_found" }), "nocatalog");
  assert.equal(L.gapKind({ available: false, reason: "no_catalog_po", po_confirmed: true }, { state: "idle" }), "nocatalog");
  assert.equal(L.gapKind({ available: false, reason: "irgendwas" }, null), "other");

  assert.match(L.noQisHtml(icon), /Verbinde QIS, damit StudiNow deinen Studiengang kennt[\s\S]*href="#\/services"[\s\S]*id="spPick"/);
  const nc = L.noCatalogHtml({ qis_program: "Musterfach", po: "2017", message: "Für die Prüfungsordnung 2017 gibt es noch keinen Katalog." }, icon);
  assert.match(nc, /Noch kein Katalog für deinen Studiengang/);
  assert.match(nc, /Musterfach · PO 2017/);
  assert.match(nc, /Für die Prüfungsordnung 2017 gibt es noch keinen Katalog\./);
  assert.match(nc, /id="spLink"[\s\S]*Link speichern/);
  assert.ok(!L.noCatalogHtml({ message: "Für deinen Studiengang gibt es noch keinen Katalog." }).includes("sp-warn"), "Standardsatz nicht doppelt");
});

test("Katalogsuche: Zustaende, Text und Fortschritt", () => {
  for (const s of ["searching", "downloading", "parsing"]) assert.equal(L.catalogBusy({ state: s }), true, s);
  for (const s of ["ready", "seed", "library"]) assert.equal(L.catalogReady({ state: s }), true, s);
  assert.equal(L.catalogFailed({ state: "error" }), true);
  assert.equal(L.catalogNotFound({ state: "not_found" }), true);
  assert.equal(L.catalogBusy({ state: "idle" }), false);
  assert.equal(L.catalogText({ state: "seed" }), "Aus dem StudiNow-Grundstock");
  assert.equal(L.catalogText({ state: "downloading" }), "Modulkatalog wird geladen …");
  assert.equal(L.catalogText({ state: "error", message: "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut." }),
    "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut.");
  const busy = L.loadingHtml({ program: "Technische Informatik", degree: "B.Sc.", po: "2022" }, { state: "searching", progress: 0.4 }, icon);
  assert.match(busy, /Modulkatalog wird vorbereitet/);
  assert.match(busy, /Technische Informatik B\.Sc\. · PO 2022/);
  assert.match(busy, /aria-valuenow="40"/);
  assert.match(busy, /ohne deine Noten oder deinen Namen/);
  const failed = L.loadingHtml({}, { state: "error" }, icon);
  assert.match(failed, /Modulkatalog nicht geladen/);
  assert.match(failed, /id="spRetry"/);
  assert.ok(!failed.includes("sp-spin"), "bei einem Fehler dreht nichts");
});

test("Link zum Modulhandbuch: nur https mit Rechnernamen, keine Leerzeichen", () => {
  assert.equal(L.catalogUrl("https://modkat.example.invalid/modulhandbuch.pdf"), "https://modkat.example.invalid/modulhandbuch.pdf");
  assert.equal(L.catalogUrl("  https://example.org/a.pdf "), "https://example.org/a.pdf");
  assert.equal(L.catalogUrl("http://example.org/a.pdf"), null, "das Backend nimmt nur https");
  assert.equal(L.catalogUrl("https://example.org/a b.pdf"), null);
  assert.equal(L.catalogUrl("https://localhost/a.pdf"), null);
  assert.equal(L.catalogUrl("javascript:alert(1)"), null);
  assert.equal(L.catalogUrl(""), null);
  assert.equal(L.catalogUrl("https://example.org/" + "a".repeat(500)), null);
});

test("Modul finden und Semester des Moduls (Sprung von der Modulseite)", () => {
  assert.equal(L.findModule(PLAN, "mathematik-3").id, "mathematik-3");
  assert.equal(L.findModule(PLAN, "Programmieren II").id, "programmieren-2", "nach Titel, ohne Gross-/Kleinschreibung");
  assert.equal(L.findModule(PLAN, "programmieren ii").id, "programmieren-2");
  assert.equal(L.findModule(PLAN, "Gibt es nicht"), null);
  assert.equal(L.findModule(PLAN, ""), null);
  assert.equal(L.semesterOf(PLAN, "programmieren-2").term, "SoSe 27");
});

test("Moduldetail aus dem Fixture: Stand mit Versuchen, Fakten, Voraussetzungen, Unterlagen, Quelle", () => {
  const d = step(6);
  assert.equal(d.id, "programmieren-2");
  const html = L.detailHtml(d, icon);
  assert.match(html, /<h2>Programmieren II<\/h2>/);
  assert.match(html, /Dein Stand/);
  assert.match(html, /Nicht bestanden · Versuch 1/);
  assert.match(html, /Versuch 1[\s\S]*SoSe 26[\s\S]*5,0/);
  assert.match(html, /Leistungspunkte<\/dt><dd>5 LP/);
  assert.match(html, /Klausur 90 min/);
  assert.match(html, /data-open="programmieren-1"[^>]*>[^<]*<i data-i="arrow-right"><\/i> Programmieren I/);
  assert.match(html, /href="#\/modules\/1"/);
  assert.match(html, /href="#\/doc\/f1"/);
  assert.match(html, /target="_blank" rel="noopener noreferrer"/);
  assert.match(html, /\(S\. 22\)/);
  assert.match(html, /Verbindlich ist die Prüfungsordnung/);
  // ohne Katalogtexte kein Textabschnitt; ladend: Hinweis
  assert.ok(!L.detailHtml({ ...d, texts: null }, icon).includes("Aus dem Modulkatalog"));
  assert.match(L.detailHtml({ ...d, texts: null, texts_loading: true }, icon), /Inhalte und Lernziele werden geladen/);
  const withText = L.detailHtml({ ...d, texts: { content: "Zeile eins\nZeile <b>zwei</b>", goals: "", literature: "Buch" } }, icon);
  assert.match(withText, /<summary>Inhalte<\/summary>/);
  assert.match(withText, /<summary>Literatur<\/summary>/);
  assert.ok(!withText.includes("<summary>Lernziele"), "leere Abschnitte fehlen");
  assert.match(withText, /&lt;b&gt;zwei&lt;\/b&gt;/);
  assert.match(withText, /Modultexte liegen nur auf diesem Gerät\./);
});

test("Datum im Versuch deutsch", () => {
  assert.equal(L.day("2026-02-10"), "10.02.2026");
  assert.equal(L.day("10.02.2026"), "10.02.2026");
  assert.equal(L.day(""), "");
  assert.match(L.ownHtml({ own: { status: "nicht_bestanden", attempts: [{ attempt: 1, semester: "WiSe 25/26", date: "2026-02-10", grade: "5,0", status: "nicht bestanden" }] } }, icon), /WiSe 25\/26 · 10\.02\.2026/);
});

test("Letzter Versuch warnt im Detail; ohne Katalogzuordnung steht Nicht gewaehlt", () => {
  const d = { ...step(6), own: { status: "nicht_bestanden", attempts: [{ attempt: 1, status: "nicht bestanden" }, { attempt: 2, status: "nicht bestanden" }, { attempt: 3, status: "nicht bestanden" }], last_attempt: true } };
  assert.match(L.ownHtml(d, icon), /Letzter Versuch – sprich mit der Studienberatung\./);
  assert.match(L.ownHtml({ own: { status: "nicht_gewaehlt", attempts: [] } }, icon), /Nicht gewählt/);
  assert.match(L.ownHtml({ own: { status: "bestanden", attempts: [{ attempt: 1, status: "bestanden", grade: "1,3" }] } }, icon), /Bestanden · 1,3/);
});

test("Lange Katalogtexte werden gekuerzt (Pruefungs- und Studienleistung)", () => {
  const long = "Portfolio, das folgende Leistungen umfasst: " + "Vorbereitung jeder Sitzung anhand von Exzerpten ".repeat(12);
  const s = L.shorten(long);
  assert.ok(s.length <= 182 && s.endsWith(" …"), s);
  assert.equal(L.shorten("Klausur 90 min"), "Klausur 90 min");
  assert.equal(L.shorten(null), "");
  const d = { ...step(6), exam: long, coursework: long };
  const html = L.factsHtml(d, icon);
  assert.ok(html.length < long.length * 2 && !html.includes(long), "im Detail nur der Anfang");
});

test("Einstellungen aus dem Fixture: PO, Studienbeginn, Wahlpflicht mit LP-Zaehler", () => {
  const s = step(5);
  const st = { po: s.po || "", start: s.start_term || "", chosen: new Set(s.electives) };
  const html = L.settingsHtml(s, st, icon);
  assert.match(html, /Prüfungsordnung/);
  assert.match(html, /<option value="2022"/);
  assert.match(html, /Studienbeginn/);
  assert.match(html, /Wahlpflicht/);
  const opts = s.elective_options;
  assert.ok(opts.length >= 2);
  assert.equal(L.chosenLp(s, new Set()), 0);
  assert.equal(L.chosenLp(s, new Set(opts.map(o => o.id))), opts.reduce((a, o) => a + o.lp, 0));
  assert.match(L.counterText(10, 15), /10 von 15 LP gewählt/);
  assert.match(L.counterText(10, 0), /^10 LP gewählt$/);
  for (const o of opts) assert.match(html, new RegExp(`data-el="${o.id}"`));
  // Rumpf: Wahlmodule in Reihenfolge der Liste, unbekannte hinten, leere Felder als null
  const body = L.settingsBody(s, { po: "", start: "", chosen: new Set([opts[1].id, opts[0].id, "zzz"]) });
  assert.deepEqual(body, { po: null, start_term: null, electives: [opts[0].id, opts[1].id, "zzz"] });
  // PO nur als Kuerzel gewaehlt (Register): erscheint als Option
  assert.match(L.settingsHtml({ ...s, po: "TIBSc25", po_options: ["2022"] }, { po: "TIBSc25", start: "", chosen: new Set() }, icon), /<option value="TIBSc25" selected>PO TIBSc25</);
  assert.match(L.settingsHtml({ ...s, po: "TIBSc25", po_options: ["2022"], catalogs: [{ po: "2025", code: "TIBSc25" }] }, { po: "TIBSc25", start: "", chosen: new Set() }, icon), /<option value="TIBSc25" selected>PO 2025</);
  assert.equal(L.poLabel({ catalogs: [{ po: "2022", code: "TIBSc22" }] }, "2022"), "2022");
});

test("Studiengang waehlen: Register mit Suche, PO-Knoepfe, ohne Katalog ausgegraut", () => {
  const list = [
    { program: "Technische Informatik", degree: "B.Sc.", faculty: "Fakultät für Elektrotechnik und Informatik", pos: [{ po: "2025", code: "TIBSc25", catalog_terms: ["WS 2026/27"] }, { po: "2022", code: "TIBSc22", catalog_terms: ["WS 2025/26"] }] },
    { program: "Geschichte", degree: "M.A.", faculty: "Philosophische Fakultät", pos: [] },
    { program: "Maschinenbau", degree: "B.Sc.", pos: [{ po: "2026", code: "mb|b.sc.|2026", catalog_terms: [] }] },
  ];
  assert.equal(L.filterPrograms(list, "informatik").length, 1);
  assert.equal(L.filterPrograms(list, "MASCHINENBAU").length, 1);
  assert.equal(L.filterPrograms(list, "").length, 3);
  assert.equal(L.filterPrograms(list, "philosophische").length, 1, "auch nach Fakultaet");
  const html = L.programsHtml(list, "", "TIBSc22");
  assert.match(html, /data-pick="TIBSc25"[^>]*>PO 2025/);
  assert.match(html, /data-pick="TIBSc22"/);
  assert.match(html, /class="chip on" data-pick="TIBSc22"/, "die gewaehlte Ordnung ist markiert");
  assert.match(html, /<li class="off">[\s\S]*Geschichte[\s\S]*Katalog noch nicht bekannt/);
  assert.match(L.programsHtml(list, "xyz", ""), /Kein Studiengang gefunden/);
  assert.match(L.programsHtml(Array.from({ length: 70 }, (_, i) => ({ program: `Fach ${i}`, pos: [] })), "", "", 60), /10 weitere/);
  assert.ok(!L.programsHtml([{ program: "<script>", pos: [] }], "", "").includes("<script>"), "maskiert");
});

test("Filterleiste zeigt die Zahlen und markiert die Auswahl", () => {
  const html = L.filterHtml(PLAN, "open");
  assert.match(html, /data-filter="all">Alle \(\d+\)/);
  assert.match(html, /aria-checked="true" class="active" data-filter="open"/);
  assert.match(L.boardHtml(PLAN, "passed", icon), /id="spBoard"/);
  assert.match(L.boardHtml({ semesters: [{ term: "A", modules: [{ id: "x", status: "offen" }] }] }, "passed", icon), /Noch kein Modul bestanden\./);
  assert.match(L.boardHtml({ semesters: [{ term: "A", modules: [{ id: "x", status: "bestanden" }] }] }, "open", icon), /Alles bestanden – nichts mehr offen\./);
});

test("Quelle mit Seitenzahl springt in der PDF auf die Seite", () => {
  assert.equal(L.sourceUrl("https://modkat.example.invalid/a.pdf", 12), "https://modkat.example.invalid/a.pdf#page=12");
  assert.equal(L.sourceUrl("https://modkat.example.invalid/a.pdf#x", 12), "https://modkat.example.invalid/a.pdf#x");
  assert.equal(L.sourceUrl("javascript:alert(1)", 1), null);
  assert.equal(L.sourceUrl("kein link", 1), null);
  assert.equal(L.sourceLabel(22), "Im Modulkatalog ansehen (S. 22)");
  assert.equal(L.sourceLabel(null), "Im Modulkatalog ansehen");
});

test("Quelle des Notenspiegels je Hochschule: QIS (LUH), LSF (Hildesheim), Campusmanagement (HsH)", () => {
  const po = { suggested_po: "2025", po_confirmed: false, qis_program: "Musterfach" };
  try {
    L.setUniversity("hildesheim");
    assert.match(L.poCardHtml(po, icon), /LSF nennt „Musterfach“/);
    assert.match(L.noQisHtml(icon), /Verbinde das LSF, damit StudiNow deinen Studiengang kennt/);
    assert.match(L.customHint(), /Heißt er wie im LSF,/);
    L.setUniversity("hsh");
    assert.match(L.poCardHtml(po, icon), /Campusmanagement nennt „Musterfach“/);
    assert.match(L.noQisHtml(icon), /Melde dich im Campusmanagement an, damit StudiNow/);
    assert.equal(L.source().aus, "aus dem Campusmanagement");
    for (const html of [L.poCardHtml(po, icon), L.noQisHtml(icon), L.customHint()]) assert.ok(!html.includes("QIS"), html);
    L.setUniversity("unbekannt");                     // unbekannt: LUH
    assert.match(L.noQisHtml(icon), /Verbinde QIS, damit/);
    assert.equal(L.customHint(), L.CUSTOM_HINT);
  } finally { L.setUniversity("luh"); }
});

// Bescheinigungen (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md): Regeln und HTML in certificates-logic.js mit den
// Antworten der gemeinsamen Fixture (packages/shared-contracts/fixtures/certificates/cases.json, nachgebaute Seiten):
// Gruppen nach Art, Stand mit Datum, ehrliche Leertexte, Semesterwahl, nicht angebotene Arten, Einbindung in Router
// und Uni & Noten.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import * as L from "../../app/static/certificates-logic.js";

const fx = JSON.parse(fs.readFileSync(new URL("../../packages/shared-contracts/fixtures/certificates/cases.json", import.meta.url), "utf8"));
const read = f => fs.readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");
const summary = uni => fx.summary.find(s => s.university === uni).summary;

test("Gruppen nach Art in der Reihenfolge der Liste", () => {
  const g = L.groups(summary("luh").offers);
  assert.deepEqual(g.map(x => x.kind), ["immatrikulation", "notenspiegel"]);
  assert.equal(g[0].label, "Immatrikulations- / Studienbescheinigung");
  const plus = L.groups(summary("hildesheim").offers).map(x => x.kind);
  assert.deepEqual(plus, ["immatrikulation", "bafoeg", "bescheid", "sonstige"]);
});

test("Stand, Unterzeile und Dateiname", () => {
  assert.equal(L.stand("2026-11-06T14:03:00"), "06.11.2026, 14:03");
  assert.equal(L.stand("2026-11-06"), "06.11.2026");
  const o = { semester: "WiSe 2026/27", confirmed: true, file: { fetched_at: "2026-11-06T14:03:00", semester: "WiSe 2026/27" } };
  assert.equal(L.subline(o), "WiSe 2026/27 · Stand: 06.11.2026, 14:03");
  assert.equal(L.subline({ confirmed: false, file: null }), "noch nicht geladen · Aufbau noch nicht mit echtem Konto geprüft");
  assert.equal(L.fileName("Studienzeit- / Immatrikulationsbescheinigung", "2026-11-06T14:03:00"),
    "Studienzeit- - Immatrikulationsbescheinigung (Stand 06.11.2026).pdf");
});

test("Leertexte und nicht angebotene Arten", () => {
  assert.match(L.emptyText("never", "PLuS"), /Liste aktualisieren/);
  assert.match(L.emptyText("login", "QIS"), /^Melde dich bei QIS an/);
  assert.match(L.emptyText("ok", "LSF"), /gerade keine Bescheinigungen/);
  assert.deepEqual(L.missing(summary("luh")).map(k => k.key), ["datenkontrollblatt", "rueckmeldung"]);
});

test("Seite: Knoepfe, Semesterwahl, Anmeldung, Hinweis", () => {
  const html = L.pageHtml(summary("hsh"), () => "");
  assert.match(html, /<h1>Bescheinigungen<\/h1>/);
  assert.match(html, /id="certRefresh"/);
  assert.equal((html.match(/data-dl="/g) || []).length, summary("hsh").offers.length, "jedes Dokument einzeln laden");
  assert.doesNotMatch(html, /Anmeldung nötig/);
  const withFile = { ...summary("luh"), status: "login" };
  withFile.offers = withFile.offers.map((o, i) => i ? o : { ...o, file: { fetched_at: "2026-11-06T10:00:00", url: `/api/certificates/${o.id}/file`, size: 3 } });
  const h2 = L.pageHtml(withFile, () => "");
  assert.match(h2, /Anmeldung nötig/);
  assert.match(h2, new RegExp(`href="/api/certificates/${withFile.offers[0].id}/file"`));
  assert.match(h2, /Neu laden/);
  const sel = L.rowHtml({ id: "x", title: "Immatrikulationsbescheinigung", semesters: [{ value: "2026_2", label: "WiSe 2026/27" }], file: null });
  assert.match(sel, /<select class="input sm" data-sem="x"/);
  assert.match(L.rowHtml({ id: "y", title: "<b>", file: null }), /&lt;b&gt;/, "Titel maskiert");
  assert.match(html, /Campusmanagement/);
});

test("Router und Uni & Noten", () => {
  assert.match(read("app.js"), /routes\.bescheinigungen = routes\.certificates = .*certificates\.js/);
  assert.match(read("views-misc.js"), /href="#\/bescheinigungen"/);
  assert.match(read("certificates.js"), /\/certificates\/refresh/);
});

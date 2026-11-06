// Zurueck-Pfeil der Web-/Windows-Oberflaeche (app/static/back-nav.js, 06.11.2026) ohne Browser: Startseite ohne Pfeil,
// Verlauf A -> B -> Zurueck = A per history.back(), ohne Verlauf zur Startseite bzw. zum Ziel des Dokuments, Zurueck
// innerhalb einer Seite zuerst; Einbau in index.html, app.js und views-doc.js.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isHome, norm, createBackNav, backButtonHtml, showsBack } from "../../app/static/back-nav.js";

const read = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Startseite ohne Pfeil, alle anderen Routen mit", () => {
  for (const h of ["", "#", "#/", "#/dashboard", "#dashboard", "#/dashboard?x=1"]) assert.equal(showsBack(h), false, h);
  for (const h of ["#/plan", "#/modules/3", "#/doc/abc?page=2", "#/settings?tab=account", "#/mensa", "#/unimail", "#/ki", "#/abo"]) {
    assert.equal(showsBack(h), true, h);
  }
  assert.equal(isHome("#/dashboards"), false);
  assert.equal(norm(""), "#/dashboard");
  assert.equal(norm("#plan?view=day"), "#/plan?view=day");
});

test("Verlauf: A -> B -> Zurück = A (history.back), dann ohne Verlauf zur Startseite", () => {
  const n = createBackNav();
  n.visit("#/modules");                       // A (erste Seite der Sitzung)
  assert.equal(n.canGoBack(), false);
  assert.deepEqual(n.back(), { hash: "#/" }, "ohne Verlauf zur Startseite");
  n.visit("#/mensa");                         // B
  assert.equal(n.canGoBack(), true);
  assert.deepEqual(n.back(), { history: true }, "vorige Seite der App");
  n.visit("#/modules");                       // history.back() fuehrt zu A
  assert.equal(n.depth, 1);
  assert.deepEqual(n.back(), { hash: "#/" });
});

test("gleiche Seite neu gezeichnet zaehlt nicht doppelt; Browser-Zurueck wird erkannt", () => {
  const n = createBackNav();
  n.visit("#/");
  n.visit("#/plan");
  n.visit("#/plan");                          // route() nach Sync: dieselbe Seite
  assert.equal(n.depth, 2);
  n.visit("#/doc/1");
  n.visit("#/plan");                          // Browser-Pfeil
  assert.equal(n.depth, 2);
  assert.deepEqual(n.back(), { history: true });
});

test("Dokument ohne Verlauf: zum Modul bzw. zu den Dokumenten", () => {
  const n = createBackNav();
  n.visit("#/doc/abc");
  assert.deepEqual(n.back("#/modules/4"), { hash: "#/modules/4" });
});

test("Zurück innerhalb einer Seite zuerst, Seitenwechsel löscht es", () => {
  const n = createBackNav();
  n.visit("#/");
  n.visit("#/messages");
  let closed = 0;
  n.setLocal(() => closed++);
  const r = n.back();
  assert.equal(typeof r.local, "function");
  r.local();
  assert.equal(closed, 1);
  assert.deepEqual(n.back(), { history: true }, "danach die vorige Seite");
  n.setLocal(() => closed++);
  n.visit("#/plan");
  assert.equal(n.back().local, undefined, "Seitenwechsel loescht das Zurueck der Seite");
});

test("Knopf: Chevron und Text, Einbau in Kopfzeile, Router und Dokument", () => {
  const html = backButtonHtml(n => `<i data-i="${n}"></i>`);
  assert.match(html, /data-i="chevron-left"/);
  assert.match(html, /<span class="back-label">Zurück<\/span>/);
  const index = read("index.html"), app = read("app.js"), doc = read("views-doc.js"), css = read("style.css");
  assert.match(index, /<header class="header">\s*<button class="btn ghost back-btn" id="backBtn" title="Zurück" aria-label="Zurück" hidden><\/button>/,
    "Pfeil oben links vor dem Menue");
  assert.match(app, /import \{ createBackNav, backButtonHtml, showsBack \} from "\.\/back-nav\.js\?v=\d+"/);
  assert.match(app, /backNav\.visit\(location\.hash\); const bb = \$\("#backBtn"\); if \(bb\) bb\.hidden = !showsBack\(location\.hash\)/);
  assert.match(app, /if \(r\.local\) r\.local\(\); else if \(r\.history\) history\.back\(\); else location\.hash = r\.hash;/);
  assert.match(doc, /id="docBack" title="Zurück" aria-label="Zurück">\$\{icon\("chevron-left", 18\)\}<span class="hide-s">Zurück<\/span>/);
  assert.match(doc, /window\.goBack\(to\)/, "Dokument nutzt denselben Pfeil");
  assert.match(css, /\.back-btn \{[^}]*min-width: 44px; min-height: 44px;/, "44 px Trefferflaeche");
  assert.match(css, /\.back-btn\[hidden\] \{ display: none; \}/);
});

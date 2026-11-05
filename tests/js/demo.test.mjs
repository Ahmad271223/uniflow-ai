// Demo nur für die Store-Prüfung (Windows, 05.11.2026) ohne Browser: wann die erste Seite den Link zeigt, die Leiste, die Texte.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as D from "../../app/static/demo-logic.js";

const icon = n => `<i data-i="${n}"></i>`;
const FRESH = { hosted: false, demo: false, session: false, credentials: false, modules: 0 };

test("Link nur auf der ersten Seite ohne Hochschulverbindung, nur im Einzelplatz", () => {
  assert.equal(D.firstStartVisible(FRESH), true);
  assert.equal(D.firstStartVisible({ ...FRESH, hosted: true }), false, "nie im gehosteten Dienst");
  assert.equal(D.firstStartVisible({ ...FRESH, demo: true }), false, "läuft die Demo schon, steht dort die Leiste");
  assert.equal(D.firstStartVisible({ ...FRESH, session: true }), false, "Hochschule verbunden");
  assert.equal(D.firstStartVisible({ ...FRESH, credentials: true }), false, "Zugangsdaten hinterlegt");
  assert.equal(D.firstStartVisible({ ...FRESH, modules: 3 }), false, "es gibt schon Module");
  for (const k of ["demo", "session", "credentials", "modules"]) {
    assert.equal(D.firstStartVisible({ ...FRESH, [k]: null }), false, `${k} unbekannt: lieber kein Link`);
  }
  assert.equal(D.firstStartVisible(null), false);
});

test("Link: kleiner Textlink mit dem Wortlaut der Pruefhinweise, kein Knopf; daneben 'Hochschule verbinden'", () => {
  const html = D.firstStartHtml();
  assert.equal(D.TEXTS.link, "Ohne Hochschulkonto ansehen (Demo)");
  assert.match(html, /<button type="button" class="fs-demo-link" id="demoStart">Ohne Hochschulkonto ansehen \(Demo\)<\/button>/);
  assert.doesNotMatch(html, /class="btn[^"]*"[^>]*id="demoStart"/, "kein Knopf");
  assert.match(html, /href="#\/settings\?tab=account">Hochschule verbinden</);
  assert.ok(html.indexOf("fs-demo") > html.indexOf("Hochschule verbinden"), "Link ganz unten");
  assert.match(D.TEXTS.welcomeText, /Passwort/);
  assert.doesNotMatch(D.TEXTS.welcomeText, /speichert dein Passwort\b(?! nur)/, "kein Versprechen, das die .env-Alternative bricht");
});

test("Leiste: 'Demo-Inhalte – erfunden, ohne Hochschule' mit 'Beenden'", () => {
  const html = D.barHtml(icon);
  assert.match(html, /Demo-Inhalte – erfunden, ohne Hochschule/);
  assert.match(html, /id="demoEnd"[^>]*>.*Beenden/s);
  assert.match(D.TEXTS.confirmEnd, /^Demo beenden\?/);
  assert.equal(D.TEXTS.ended, "Demo beendet");
  assert.match(D.TEXTS.syncBlocked, /Beenden/);
});

test("Meldung nach dem Anlegen wie im Web und auf dem iPad", () => {
  assert.equal(D.installedText({ files: 3, events: 3, packages: 3 }), "Demo angelegt: 3 PDFs, 3 Termine, 3 Lernpakete");
  assert.equal(D.installedText({ files: 1, events: 1, packages: 1 }), "Demo angelegt: 1 PDF, 1 Termin, 1 Lernpaket");
});

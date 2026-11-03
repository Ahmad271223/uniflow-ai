// Fehlercodes des StudiNow-Dienstes -> deutscher Text (app/static/service-errors.js). Dieselben Faelle wie
// apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/ServiceErrorTextTests.swift; zusaetzlich liest der Test die Texte
// aus ServiceErrorText.swift und vergleicht sie Zeichen fuer Zeichen (die EINE Stelle soll auf Web und iPad gleich sein).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as E from "../../app/static/service-errors.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const swift = readFileSync(join(root, "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Account/ServiceErrorText.swift"), "utf8");
const err = (status, code, message = "Meldung des Dienstes", retry) => E.serviceError(status, { detail: message, code }, { retryAfter: retry });

test("jeder neue Code hat seinen eigenen deutschen Text", () => {
  const expected = [[403, "email_unverified", "Bestätige zuerst deine E-Mail-Adresse"], [409, "duplicate_request", "schon verarbeitet"],
    [429, "ai_trial_budget_exhausted", "Probekonten"], [503, "ai_not_configured_prices", "noch nicht freigeschaltet"],
    [409, "email_taken", "gibt es schon ein StudiNow-Konto"], [409, "last_login_method", "einzige Anmeldeweg"], [403, "cross_site", "Sicherheitsgründen"]];
  for (const [status, code, part] of expected) {
    const e = err(status, code);
    assert.ok(e.message.includes(part), `${code}: ${e.message}`);
    assert.ok(!e.message.includes("Meldung des Dienstes"), `${code}: eigener Text statt Dienst-Text`);
    assert.equal(E.known(code), e.message, code);
    assert.equal(e.code, code);
    assert.equal(e.status, status);
  }
});

test("die Texte sind dieselben wie in ServiceErrorText.swift", () => {
  const pairs = [...swift.matchAll(/case "(\w+)":\s*\n\s*return "((?:[^"\\]|\\.)*)"/g)];
  assert.equal(pairs.length, 7, "sieben bekannte Codes in Swift");
  for (const [, code, txt] of pairs) assert.equal(E.known(code), txt.replace(/\\"/g, '"'), code);
  const limit = swift.match(/let base = "Du hast heute schon \\\(reportsPerDay\) Meldungen abgegeben, mehr sind pro Tag nicht möglich\."/);
  assert.ok(limit, "Text der Meldegrenze in Swift gefunden");
  assert.equal(E.reportLimit(null), "Du hast heute schon 10 Meldungen abgegeben, mehr sind pro Tag nicht möglich.");
  assert.match(swift, /static let reportsPerDay = 10/);
});

test("unbekannter Code behaelt die Meldung des Dienstes", () => {
  assert.equal(E.known("voellig_neu"), null);
  assert.equal(E.known("constructor"), null, "keine Eigenschaften von Object");
  assert.equal(err(400, "voellig_neu", "Text vom Dienst").message, "Text vom Dienst");
  assert.equal(err(400, "voellig_neu").action, null);
});

test("Retry-After wird angehaengt", () => {
  assert.equal(err(429, "rate_limited", "Zu viele Versuche.", 600).message, "Zu viele Versuche. (in 10 min erneut versuchen)");
  assert.equal(err(429, "rate_limited", "Zu viele Versuche.", 20).message, "Zu viele Versuche. (in 1 min erneut versuchen)");
  assert.equal(err(429, "rate_limited", "x", 86400).message, "x (in etwa 24 Std. erneut versuchen)");
  assert.ok(err(429, "ai_trial_budget_exhausted", undefined, 60).message.endsWith("(in 1 min erneut versuchen)"));
  assert.equal(err(429, "rate_limited", "x", 0).message, "x");
  assert.equal(err(429, "rate_limited", "x", NaN).message, "x");
});

test("Handlungen", () => {
  assert.equal(err(403, "email_unverified").action, "verifyEmail");
  assert.equal(err(409, "last_login_method").action, "accountSettings");
  assert.equal(err(409, "email_taken").action, "accountSettings");
  for (const c of ["duplicate_request", "ai_trial_budget_exhausted", "ai_not_configured_prices", "cross_site", "rate_limited"]) assert.equal(err(400, c).action, null, c);
  assert.equal(E.ACTION_LABEL.verifyEmail, "Bestätigungslink erneut senden");
});

test("Melden: 429 rate_limited ist die Tagesgrenze, andere Grenzen behalten den Dienst-Text", () => {
  const rep = E.serviceError(429, { detail: "Zu viele Versuche.", code: "rate_limited" }, { retryAfter: 3600, report: true });
  assert.equal(rep.message, "Du hast heute schon 10 Meldungen abgegeben, mehr sind pro Tag nicht möglich. (in 60 min erneut versuchen)");
  const other = E.serviceError(429, { detail: "Zu viele Versuche.", code: "rate_limited" }, { retryAfter: 120 });
  assert.equal(other.message, "Zu viele Versuche. (in 2 min erneut versuchen)");
  assert.equal(E.serviceError(409, { detail: "x", code: "duplicate_request" }, { report: true }).message, E.known("duplicate_request"));
});

test("Antwortformen: detail als Objekt, ohne Koerper, kaputte Werte", () => {
  assert.equal(E.serviceError(403, { detail: { detail: "Text", code: "cross_site" } }).message, E.known("cross_site"));
  assert.equal(E.serviceError(500, null, { fallback: "Server Error" }).message, "Server Error");
  assert.equal(E.serviceError(502, undefined).message, "Fehler 502");
  assert.equal(E.serviceError(422, { detail: [{ msg: "x" }] }, { fallback: "Unprocessable" }).message, "Unprocessable", "FastAPI-Pruefliste ist kein Text");
  assert.equal(E.serviceError(400, { detail: "Nur Text" }).code, undefined);
});

test("Bestaetigungslink erneut senden: Rueckmeldung", () => {
  assert.equal(E.resendNote({ ok: true, already: false, message: "Wir haben dir einen neuen Bestätigungslink geschickt." }), "Wir haben dir einen neuen Bestätigungslink geschickt.");
  assert.equal(E.resendNote({ ok: true, already: true }), "Deine E-Mail-Adresse ist schon bestätigt.");
  assert.equal(E.resendNote({ ok: true }), "Wir haben dir einen neuen Bestätigungslink geschickt.");
  assert.equal(E.resendNote(null), "Wir haben dir einen neuen Bestätigungslink geschickt.");
});

test("responseError liest Koerper und Retry-After aus einer fetch-Antwort", async () => {
  const r = { status: 429, statusText: "Too Many Requests", headers: { get: k => (k === "Retry-After" ? "1800" : null) }, json: async () => ({ detail: "Zu viele Versuche.", code: "rate_limited" }) };
  const e = await E.responseError(r);
  assert.equal(e.message, "Zu viele Versuche. (in 30 min erneut versuchen)");
  assert.equal(e.status, 429);
  const broken = { status: 500, statusText: "Internal Server Error", headers: { get: () => null }, json: async () => { throw new Error("kein JSON"); } };
  assert.equal((await E.responseError(broken)).message, "Internal Server Error");
});

test("alle Stellen mit eigenem fetch benutzen die eine Stelle", () => {
  const src = f => readFileSync(join(root, "app/static", f), "utf8");
  for (const f of ["core.js", "views-qa.js", "editor-community.js", "studora-link.js", "login.js"]) assert.match(src(f), /service-errors\.js\?v=\d+/, f);
  assert.match(src("core.js"), /if \(!r\.ok\) throw await responseError\(r\);/, "api() baut den Fehler mit der einen Stelle");
  assert.doesNotMatch(src("core.js"), /\(await r\.json\(\)\)\.detail/, "api() baut den Text nicht mehr selbst");
  assert.match(src("views-qa.js"), /throw await responseError\(r, \{ report: /);
  assert.match(src("editor-community.js"), /await responseError\(r, \{ report: /);
});

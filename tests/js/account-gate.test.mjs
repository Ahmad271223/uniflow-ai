// Konto- und Abo-Pflicht in Web und Windows (app/static/account-gate.js, Entscheidung des Inhabers 05.11.2026):
// Zustaende der Oberflaeche, Leiste ueber dem Inhalt, Anmeldebildschirm der Windows-App, Tarifzeile der Seitenleiste.
import { test } from "node:test";
import assert from "node:assert/strict";
import { gateState, gateBarHtml, loginScreenHtml, exportHref, trialBarTitle, socialState, GATE_TEXTS } from "../../app/static/account-gate.js";
import { planLabel, upgradeCta } from "../../app/static/shell-nav.js";
import { trialHintHtml } from "../../app/static/trial-hint.js";

const acc = (state, extra = {}) => ({ access: { client: "web", account_required: true, state, locked: state === "subscription_required" || state === "unverified", trial_days_left: state === "trial" ? 3 : null, message: null, ...extra } });
const icon = name => `[${name}]`;

test("Zustaende: open, login, locked, trial, active", () => {
  assert.equal(gateState(null, null), "open", "eigener PC ohne Konto-Pflicht");
  assert.equal(gateState({ access: { client: "app", account_required: false, state: "free", locked: false } }), "open", "iPad-Client: keine Pflicht");
  assert.equal(gateState(null, { required: true, state: "signed_out" }), "login");
  assert.equal(gateState(acc("subscription_required")), "locked");
  assert.equal(gateState(acc("unverified")), "locked");
  assert.equal(gateState(acc("trial")), "trial");
  assert.equal(gateState(acc("active")), "active");
});

test("Leiste: ohne Abo nur lesen mit Abo waehlen und Export, Probe mit Resttagen, sonst nichts", () => {
  const locked = gateBarHtml(acc("subscription_required"), null, { icon });
  assert.match(locked, /Kein aktives Abo · Nur lesen/);
  assert.match(locked, /href="#\/abo">Abo wählen</);
  assert.match(locked, /href="\/api\/account\/export" download/, "Web: DSGVO-Export des Kontos");
  const win = gateBarHtml({ mode: "account", ...acc("unverified", { message: "Dein Abo konnte seit mehr als 7 Tagen nicht geprüft werden." }) }, null, { icon });
  assert.match(win, /Abo konnte nicht geprüft werden/);
  assert.match(win, /id="gateRecheck">Erneut prüfen</);
  assert.match(win, /href="\/api\/app-account\/export"/, "Windows: Daten dieses PCs");
  assert.match(gateBarHtml(acc("trial"), null, { icon }), /Probe: noch 3 Tage alles wie StudiNow Pro AI/);
  assert.equal(gateBarHtml(acc("active"), null, { icon }), "");
  assert.equal(gateBarHtml(null, null, { icon }), "");
  assert.equal(trialBarTitle(1), "Probe: noch 1 Tag alles wie StudiNow Pro AI");
  assert.equal(exportHref({ mode: "hosted" }), "/api/account/export");
});

test("Anmeldebildschirm der Windows-App: Passwort, Apple, Google, Konto anlegen, nie das Passwort speichern", () => {
  const html = loginScreenHtml({ service_url: "https://app.studinow.app", last_email: "lea@example.org", last_error: "" }, { icon });
  assert.match(html, /<h1[^>]*>Bei StudiNow anmelden<\/h1>/);
  assert.match(html, /value="lea@example\.org"/);
  assert.match(html, /data-provider="apple"[^>]*>Mit Apple anmelden</);
  assert.match(html, /data-provider="google"[^>]*>Mit Google anmelden</);
  assert.match(html, /data-browser="register">Neu hier\? Konto anlegen</);
  assert.match(html, /app\.studinow\.app in deinem Browser/);
  assert.match(html, /nie dein Passwort/);
  assert.ok(!loginScreenHtml({ service_url: "x", last_email: "<b>" }).includes("<b>"), "Werte werden maskiert");
});

test("Texte: Apple-Abo, ohne Abo nur ansehen und exportieren, Daten bleiben", () => {
  assert.equal(GATE_TEXTS.apple, "Du hast schon ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones.");
  assert.match(GATE_TEXTS.lockedText, /nur ansehen und exportieren/);
  assert.match(GATE_TEXTS.lockedText, /Daten bleiben/);
});

test("Seitenleiste und Probe-Karte mit Abo-Pflicht: kein 'Bei Free bleiben'", () => {
  assert.equal(planLabel(acc("subscription_required"), true), "Kein Abo · nur lesen");
  assert.deepEqual(upgradeCta(acc("subscription_required"), true), { label: "Abo wählen", href: "#/abo" });
  assert.equal(planLabel({ plan: "free" }, true), "Free", "iPad-Stand ohne Pflicht wie bisher");
  const over = { trial: { granted: true, active: false, expired: true }, needs_plan_choice: true };
  assert.match(trialHintHtml(over, true, icon, s => s), /trialFree/, "ohne Pflicht wie bisher");
  assert.equal(trialHintHtml({ ...over, ...acc("subscription_required") }, true, icon, s => s), "", "mit Pflicht zeigt die Leiste den Stand");
});

test("Apple und Google im Browser nur mit Web-Kennung des Dienstes; sonst Hinweis fuer Konten vom iPad (12.11.2026)", () => {
  const p = (extra = {}) => ({ reachable: true, apple: true, google: false, apple_browser: false, google_browser: false, ...extra });
  assert.deepEqual(socialState(null), { apple: true, google: true, hint: false }, "ohne Antwort: wie bisher, kein Raten");
  assert.deepEqual(socialState({ reachable: false }), { apple: true, google: true, hint: false }, "Dienst nicht erreichbar");
  // Stand des Dienstes am 12.11.2026: Bundle-ID ja, Services-ID nein
  assert.deepEqual(socialState(p()), { apple: false, google: false, hint: true });
  assert.deepEqual(socialState(p({ apple_browser: true })), { apple: true, google: false, hint: false });
  assert.deepEqual(socialState(p({ apple_browser: true, google_browser: true })), { apple: true, google: true, hint: false });
  assert.deepEqual(socialState(p({ google_browser: true })), { apple: false, google: true, hint: true });
  const html = loginScreenHtml({ service_url: "https://app.studinow.app", last_email: "", last_error: "" }, { icon });
  assert.match(html, /id="gateAppleHint"[^>]*display:none/, "Hinweis erst sichtbar, wenn der Dienst Apple im Browser nicht kann");
  assert.match(html, /Konto mit Apple auf dem iPad angelegt\?/);
  assert.match(html, /data-browser="forgot">Passwort festlegen</, "Knopf oeffnet den Reiter Passwort vergessen im Browser");
  assert.match(GATE_TEXTS.appleHint, /iPad wird dabei einmal abgemeldet/);
});

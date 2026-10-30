// Regeln des Service Workers (app/static/sw-policy.js) ohne Browser. Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const ctx = { self: {}, URL };
vm.runInNewContext(readFileSync(join(root, "app/static/sw-policy.js"), "utf8"), ctx);
const P = ctx.self.StudoraSW;
const ORIGIN = "https://studora.example";
const c = (method, path) => P.classify(method, ORIGIN + path, ORIGIN);

test("Oberflaeche und Dateien kommen in die Ablage, Aenderungen nie", () => {
  assert.equal(c("GET", "/").kind, "shell");
  assert.equal(c("GET", "/app.js?v=55").kind, "shell");
  assert.equal(c("GET", "/vendor/pdf.min.mjs?v=3").kind, "shell");
  assert.equal(c("GET", "/fonts/inter.css?v=30").kind, "shell");
  assert.equal(c("GET", "/manifest.webmanifest").kind, "shell");
  assert.equal(c("GET", "/api/files/abc/content").kind, "files");
  assert.equal(c("GET", "/api/files/abc/content?download=1").kind, "files");
  assert.equal(c("GET", "/api/files/abc/docx").kind, "files");
  assert.equal(c("GET", "/api/files/abc").kind, "api");
  assert.equal(c("GET", "/api/files/abc/annotations").kind, "api");
  assert.equal(c("GET", "/api/dashboard").kind, "api");
  assert.equal(c("GET", "/api/modules").kind, "api");
  assert.equal(c("GET", "/api/calendar/week?date=2026-10-30").kind, "api");
  for (const m of ["POST", "PUT", "PATCH", "DELETE"]) assert.equal(c(m, "/api/files/abc/annotations").kind, "write", m);
});

test("Konto, Auftraege, Abgleich, Suche, Anmeldung und fremde Hosts bleiben am Worker vorbei", () => {
  for (const p of ["/api/account/me", "/api/account", "/api/bg", "/api/sync/status", "/api/network", "/api/integrations/chatgpt",
    "/api/billing/plans", "/api/entitlements", "/api/credentials", "/api/university/session", "/api/qis/runs", "/api/search?q=x",
    "/api/related?file_id=1", "/api/desktop", "/api/services", "/api/files/abc/recordings", "/api/recordings/1/audio",
    "/api/community/notifications", "/login", "/sw.js", "/auth/callback?code=1"]) {
    assert.equal(c("GET", p).kind, "bypass", p);
  }
  assert.equal(P.classify("GET", "https://auth.openai.com/x", ORIGIN).kind, "bypass");
  assert.equal(P.classify("GET", "nicht:eine//adresse", ORIGIN).kind, "bypass");
  // "accounts" ist kein Konto-Pfad, "backgrounds" kein bg
  assert.equal(c("GET", "/api/accounts-stats").kind, "api");
  assert.equal(c("GET", "/api/bgx").kind, "api");
});

test("Schluessel: Dateien ohne Abfrage, Listen mit Abfrage", () => {
  assert.equal(P.cacheKey("files", ORIGIN + "/api/files/abc/content?download=1", ORIGIN), ORIGIN + "/api/files/abc/content");
  assert.equal(P.cacheKey("api", ORIGIN + "/api/calendar/week?date=2026-10-30", ORIGIN), ORIGIN + "/api/calendar/week?date=2026-10-30");
  assert.equal(P.cacheKey("shell", "/app.js?v=55", ORIGIN), ORIGIN + "/app.js?v=55");
});

test("nur vollstaendige 200er vom eigenen Server werden abgelegt", () => {
  assert.equal(P.storable(200, "basic"), true);
  assert.equal(P.storable(200, "default"), true);
  assert.equal(P.storable(206, "basic"), false);
  assert.equal(P.storable(302, "basic"), false);
  assert.equal(P.storable(401, "basic"), false);
  assert.equal(P.storable(200, "opaque"), false);
  assert.equal(P.storable(200, "opaqueredirect"), false);
});

test("Verdraengung: die aeltesten zuerst, Grenzen und Namen stehen fest", () => {
  const keys = Array.from({ length: 43 }, (_, i) => `k${i}`);
  assert.deepEqual(P.evict(keys, 40), ["k0", "k1", "k2"]);
  assert.equal(P.evict(keys.slice(0, 40), 40).length, 0);
  // Werte aus dem vm-Kontext haben fremde Prototypen: ueber JSON vergleichen
  assert.deepEqual(JSON.parse(JSON.stringify(P.LIMITS)), { shell: 400, files: 40, api: 300 });
  assert.deepEqual(Object.keys(P.CACHES), ["shell", "files", "api"]);
  assert.ok(Object.values(P.CACHES).every(n => /^studora-(shell|files|api)-v\d+$/.test(n)));
});

test("Aenderung ohne Netz: 503 mit Code offline, wie ein Serverfehler aufgebaut", () => {
  const r = P.offlineWrite();
  assert.equal(r.status, 503);
  assert.equal(r.body.code, "offline");
  assert.match(r.body.detail, /Offline/);
});

test("sw.js bindet die Regeln mit Version ein und die Datei gibt es", () => {
  const sw = readFileSync(join(root, "app/static/sw.js"), "utf8");
  const m = sw.match(/importScripts\("sw-policy\.js\?v=(\d+)"\)/);
  assert.ok(m, "importScripts mit Version");
  assert.ok(/skipWaiting|clients\.claim/.test(sw));
  const appjs = readFileSync(join(root, "app/static/pwa.js"), "utf8");
  assert.match(appjs, /serviceWorker\.register\("\/sw\.js"\)/, "Anmeldung ohne ?v=, damit der Browser Updates am Inhalt erkennt");
});

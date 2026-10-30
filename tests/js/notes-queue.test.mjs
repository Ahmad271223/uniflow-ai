// Notiz-Warteschlange (app/static/notes-queue.js) ohne Browser: Speicher = Map-Attrappe, fetch = Attrappe.
// Ausfuehren: node --test tests/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createQueue, memoryStorage, webStorage, isOfflineResponse, baseOf } from "../../app/static/notes-queue.js";

const json = (status, body, headers = {}) => ({
  status, ok: status >= 200 && status < 300, headers: { get: k => headers[k] ?? null },
  json: async () => body, clone() { return this; },
});
const page = (...ids) => ({ objects: ids.map(id => ({ id, type: "stroke", points: [1, 2] })) });
const doc = (pages, extra = {}) => ({ version: 2, pages, pageOrder: Object.keys(pages).map(key => ({ key, type: "blank", w: 595, h: 842 })), deletedPages: [], ...extra });

/// fetch-Attrappe: Liste von Antworten je Aufruf (Funktion oder Antwort); merkt sich die Aufrufe
function fakeFetch(plan) {
  const calls = [];
  const fn = async (url, opts) => {
    const body = JSON.parse(opts.body); calls.push({ url, body, base: Number(new URL("http://x" + url).searchParams.get("base_version")) });
    const next = plan.shift();
    if (typeof next === "function") return next(url, body, calls.length);
    if (next instanceof Error) throw next;
    return next ?? json(200, { ok: true, version: 99 });
  };
  fn.calls = calls; return fn;
}

const entry = (fileId, data, version = 1, more = {}) => ({ fileId, data, version, dirtyKeys: Object.keys(data.pages), ...more });

test("nur der neueste Stand je Datei, aelteste Datei zuerst", async () => {
  let t = 1000; const q = createQueue({ storage: memoryStorage(), fetch: fakeFetch([]), now: () => t++ });
  q.setAccount("k1");
  await q.remember(entry("b", doc({ p1: page("x") })));
  await q.remember(entry("a", doc({ p1: page("a1") })));
  await q.remember(entry("b", doc({ p1: page("x", "y") }), 3));
  const p = await q.pending();
  assert.deepEqual(p.map(e => e.fileId), ["a", "b"], "b wurde zuletzt geschrieben und steht hinten");
  assert.equal(p[1].version, 3);
  assert.deepEqual(p[1].data.pages.p1.objects.map(o => o.id), ["x", "y"]);
  assert.equal(p[1].account, "k1"); assert.equal(p[1].dirty, true); assert.ok(p[1].savedAt >= 1000);
  assert.equal(await q.count(), 2);
});

test("Erfolg entfernt den Eintrag aus der Warteschlange und merkt die neue Version", async () => {
  const f = fakeFetch([json(200, { ok: true, version: 7 })]);
  const q = createQueue({ storage: memoryStorage(), fetch: f }); const sent = [];
  q.hooks.sent = (n, ids) => sent.push([n, ids]);
  await q.remember(entry("f1", doc({ p1: page("a") }), 6));
  const r = await q.flush();
  assert.deepEqual(r, { sent: ["f1"], kept: [], offline: false });
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].base, 6); assert.match(f.calls[0].url, /^\/api\/files\/f1\/annotations\?base_version=6$/);
  assert.equal(await q.count(), 0, "nichts mehr offen");
  const kept = await q.get("f1"); assert.equal(kept.dirty, false); assert.equal(kept.version, 7, "Entwurf bleibt als bestaetigter Stand liegen");
  assert.deepEqual(sent, [[1, ["f1"]]]);
});

test("ohne Netz (fetch-Fehler, 503 offline, X-Studora-Offline) bleibt alles liegen und der Lauf endet", async () => {
  for (const fail of [new TypeError("Failed to fetch"), json(503, { detail: "Offline", code: "offline" }, { "X-Studora-Offline": "1" }), json(200, { ok: true, version: 2 }, { "X-Studora-Offline": "1" })]) {
    const f = fakeFetch([fail]); const q = createQueue({ storage: memoryStorage(), fetch: f }); let offline = 0; q.hooks.offline = () => offline++;
    await q.remember(entry("f1", doc({ p1: page("a") })));
    await q.remember(entry("f2", doc({ p1: page("b") })));
    const r = await q.flush();
    assert.equal(r.offline, true); assert.deepEqual(r.sent, []); assert.deepEqual(r.kept, ["f1"]);
    assert.equal(f.calls.length, 1, "nach dem ersten Netzfehler nicht weiter probieren");
    assert.equal(await q.count(), 2); assert.equal(offline, 1);
  }
  // navigator.onLine === false: gar nicht erst senden
  const f = fakeFetch([]); const q = createQueue({ storage: memoryStorage(), fetch: f, online: () => false });
  await q.remember(entry("f1", doc({ p1: page("a") })));
  assert.equal((await q.flush()).offline, true); assert.equal(f.calls.length, 0);
});

test("409: mit merge.js zusammenfuehren (Basis = bestaetigter Stand) und mit der Serverversion erneut senden", async () => {
  const base = doc({ p1: page("alt") });
  const local = doc({ p1: page("alt", "lokal") });
  const server = doc({ p1: page("alt", "fremd") });
  const f = fakeFetch([json(409, { detail: "Konflikt", version: 5, data: server }), json(200, { ok: true, version: 6 })]);
  const q = createQueue({ storage: memoryStorage(), fetch: f }); const merged = [];
  q.hooks.merged = (id, c) => merged.push([id, c]);
  await q.remember(entry("f1", local, 2, { basePages: { p1: JSON.stringify(base.pages.p1) } }));
  const r = await q.flush();
  assert.deepEqual(r.sent, ["f1"]);
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].base, 5, "zweiter Versuch mit der Version aus der 409-Antwort");
  assert.match(f.calls[1].url, /snapshot=true/, "nach Konflikt: ersetzter Stand in den Verlauf");
  assert.deepEqual(f.calls[1].body.pages.p1.objects.map(o => o.id).sort(), ["alt", "fremd", "lokal"], "Striche beider Geraete bleiben");
  assert.deepEqual(merged, [["f1", 0]]);
  assert.equal((await q.get("f1")).version, 6);
});

test("409 ohne Ende: nach vier Versuchen aufgeben, Eintrag behalten, einmal melden", async () => {
  const srv = doc({ p1: page("s") });
  const conflict = () => json(409, { detail: "Konflikt", version: 9, data: srv });
  const f = fakeFetch([conflict, conflict, conflict, conflict, conflict]);
  const q = createQueue({ storage: memoryStorage(), fetch: f }); const errors = []; q.hooks.error = (id, m) => errors.push([id, m]);
  await q.remember(entry("f1", doc({ p1: page("l") })));
  const r = await q.flush();
  assert.deepEqual(r.kept, ["f1"]); assert.equal(f.calls.length, 4); assert.equal(await q.count(), 1);
  assert.deepEqual(errors, [["f1", "Konflikt nicht auflösbar"]]);
});

test("anderer Fehler (403, 500): Eintrag behalten, nur einmal melden, naechste Datei trotzdem senden", async () => {
  const f = fakeFetch([json(403, { detail: "Ab Studora Plus" }), json(200, { ok: true, version: 2 }), json(403, { detail: "Ab Studora Plus" })]);
  const q = createQueue({ storage: memoryStorage(), fetch: f }); const errors = []; q.hooks.error = (id, m) => errors.push([id, m]);
  await q.remember(entry("f1", doc({ p1: page("a") })));
  await q.remember(entry("f2", doc({ p1: page("b") })));
  let r = await q.flush();
  assert.deepEqual(r, { sent: ["f2"], kept: ["f1"], offline: false });
  r = await q.flush();
  assert.deepEqual(r.kept, ["f1"]); assert.equal(f.calls.length, 3);
  assert.deepEqual(errors, [["f1", "Ab Studora Plus (403)"]], "gleicher Fehler nur einmal gemeldet");
});

test("gehaltene Datei (Editor offen) und `except` werden ausgelassen; flush laeuft nie doppelt", async () => {
  let release; const f = fakeFetch([() => new Promise(res => { release = () => res(json(200, { ok: true, version: 2 })); })]);
  const q = createQueue({ storage: memoryStorage(), fetch: f });
  await q.remember(entry("offen", doc({ p1: page("a") })));
  await q.remember(entry("zu", doc({ p1: page("b") })));
  await q.remember(entry("x", doc({ p1: page("c") })));
  q.hold("offen");
  const p1 = q.flush({ except: "x" }); const p2 = q.flush();
  assert.equal(p1, p2, "zweiter Aufruf bekommt denselben Lauf");
  while (!release) await new Promise(r => setTimeout(r, 1));
  release();
  const r = await p1;
  assert.deepEqual(r.sent, ["zu"]); assert.equal(f.calls.length, 1);
  q.release("offen"); assert.equal(q.isHeld("offen"), false);
  assert.deepEqual((await q.flush()).sent.sort(), ["offen", "x"]);
});

test("Kontowechsel: Eintraege des alten Kontos werden nicht unter dem neuen gesendet, alte ohne Vermerk bekommen das alte Konto", async () => {
  const f = fakeFetch([]); const q = createQueue({ storage: memoryStorage(), fetch: f });
  await q.remember(entry("alt-ohne", doc({ p1: page("a") })));          // vor dem Kontovermerk geschrieben (kein account)
  q.setAccount("anna");
  await q.remember(entry("anna1", doc({ p1: page("b") })));
  // Wechsel zu bert (pwa.js keepCacheForAccount): alte ohne Vermerk gehoeren anna
  assert.equal(await q.claimUntagged("anna"), 1);
  assert.equal(await q.count("anna"), 2);
  q.setAccount("bert");
  await q.remember(entry("bert1", doc({ p1: page("c") })));
  const r = await q.flush();
  assert.deepEqual(r.sent, ["bert1"]); assert.equal(f.calls.length, 1);
  assert.equal(await q.count("anna"), 2, "annas Notizen bleiben liegen");
  // anna wieder da: ihre Notizen gehen raus
  q.setAccount("anna");
  assert.deepEqual((await q.flush()).sent.sort(), ["alt-ohne", "anna1"]);
  assert.equal(await q.count("anna"), 0);
});

test("remember/settled: Entwurf als erledigt markieren; Speicherfehler liefert false", async () => {
  const q = createQueue({ storage: memoryStorage(), fetch: fakeFetch([]) });
  await q.remember(entry("f1", doc({ p1: page("a") })));
  await q.settled("f1", { data: doc({ p1: page("a") }), version: 4 });
  assert.equal(await q.count(), 0); assert.equal((await q.get("f1")).version, 4);
  const broken = { async all() { throw new Error("kaputt"); }, async get() { throw new Error("kaputt"); }, async put() { throw new Error("voll"); }, async del() {} };
  const q2 = createQueue({ storage: broken, fetch: fakeFetch([]) });
  assert.equal(await q2.remember(entry("f1", doc({}))), false);
  assert.deepEqual(await q2.pending(), []); assert.equal(await q2.get("f1"), null);
});

test("webStorage (localStorage-Rueckfall) haelt einen Schluessel je Datei", async () => {
  const m = new Map();
  const ls = { get length() { return m.size; }, key: i => [...m.keys()][i] ?? null, getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) };
  ls.setItem("anderes", "x");
  const st = webStorage(ls);
  await st.put({ fileId: "f1", dirty: true, data: { a: 1 } }); await st.put({ fileId: "f1", dirty: true, data: { a: 2 } }); await st.put({ fileId: "f2", dirty: false });
  assert.equal(m.size, 3); assert.deepEqual((await st.get("f1")).data, { a: 2 });
  assert.deepEqual((await st.all()).map(e => e.fileId).sort(), ["f1", "f2"]);
  await st.del("f1"); assert.equal(await st.get("f1"), null);
});

test("isOfflineResponse und baseOf", async () => {
  assert.equal(await isOfflineResponse(json(503, { code: "offline" })), true);
  assert.equal(await isOfflineResponse(json(503, { code: "busy" })), false);
  assert.equal(await isOfflineResponse(json(200, {}, { "X-Studora-Offline": "1" })), true);
  assert.equal(await isOfflineResponse(json(500, {})), false);
  assert.equal(baseOf({}), null);
  assert.deepEqual(baseOf({ basePages: { p1: JSON.stringify({ objects: [] }), p2: null } }), { version: 2, pages: { p1: { objects: [] } }, pageOrder: [], deletedPages: [] });
});

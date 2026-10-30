// Service Worker der Web-Oberflaeche: Studora als App auf iPad, Mac und Windows (Safari "Zum Home-Bildschirm" bzw.
// "Zum Dock hinzufuegen", Edge/Chrome "Installieren") mit Offline-Rueckfall. Die Regeln stehen in sw-policy.js und
// sind ohne Browser geprueft (tests/js/sw.test.mjs); hier nur das Verdrahten mit Cache und fetch.
//
// Registriert von app.js. Diese Datei bleibt immer unter derselben Adresse (/sw.js, ohne ?v=): der Browser erkennt ein
// Update am Inhalt. Aendert sich sw-policy.js, hier die Version in importScripts hochzaehlen.
/* global StudoraSW */
importScripts("sw-policy.js?v=1");

const P = StudoraSW;

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keep = new Set(Object.values(P.CACHES));
    for (const name of await caches.keys()) if (!keep.has(name)) await caches.delete(name);
    await self.clients.claim();
  })());
});

// Die Seite meldet "clear" beim Abmelden oder Kontowechsel: Dateien und Listen des alten Kontos verschwinden
self.addEventListener("message", event => {
  const type = event.data && event.data.type;
  if (type === "clear") event.waitUntil(Promise.all([caches.delete(P.CACHES.files), caches.delete(P.CACHES.api)]));
});

async function put(kind, key, response) {
  const cache = await caches.open(P.CACHES[kind]);
  await cache.put(key, response);
  const keys = await cache.keys();
  for (const old of P.evict(keys, P.LIMITS[kind])) await cache.delete(old);
}

async function networkFirst(kind, request) {
  const key = P.cacheKey(kind, request.url, self.location.origin);
  try {
    const response = await fetch(request);
    if (P.storable(response.status, response.type)) put(kind, key, response.clone()).catch(() => {});
    return response;
  } catch (error) {
    const cached = await (await caches.open(P.CACHES[kind])).match(key);
    if (cached) {
      const headers = new Headers(cached.headers);
      headers.set("X-Studora-Offline", "1");
      return new Response(cached.body, { status: cached.status, statusText: cached.statusText, headers });
    }
    throw error;
  }
}

self.addEventListener("fetch", event => {
  const d = P.classify(event.request.method, event.request.url, self.location.origin);
  if (d.kind === "bypass") return;
  if (d.kind === "write") {
    event.respondWith(fetch(event.request).catch(() => {
      const r = P.offlineWrite();
      return new Response(JSON.stringify(r.body), { status: r.status, headers: { "Content-Type": "application/json", "X-Studora-Offline": "1" } });
    }));
    return;
  }
  event.respondWith(networkFirst(d.kind, event.request));
});

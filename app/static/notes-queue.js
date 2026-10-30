// Warteschlange fuer Notizen ohne Netz (docs/PLAN-WEB-ZUERST-2026-10-30.md Stufe B.2): der zuletzt gewollte Stand je
// Datei liegt im Browser (IndexedDB "lernapp-editor", Ablage "drafts"; Rueckfall localStorage, zuletzt Speicher) und
// wird gesendet, sobald Netz da ist: beim `online`-Ereignis, beim Start (pwa.js initPWA) und wenn ein Editor oeffnet.
// Der Editor (editor.js) schreibt denselben Eintrag als Entwurf (dirty = noch nicht beim Server) und haelt seine Datei
// (hold), solange er offen ist: dann sendet er selbst. Ohne Editor sendet flush() hier; bei 409 wird mit merge.js
// zusammengefuehrt (Basis = letzter bestaetigter Stand der geaenderten Seiten) und erneut gesendet.
// Die Logik haengt nur an einem kleinen Speicher-Interface { all, get, put, del } und laeuft ohne Browser
// (tests/js/notes-queue.test.mjs mit memoryStorage).
import { mergeDocument } from "./merge.js?v=30";

export const DB_NAME = "lernapp-editor", DB_VERSION = 2, STORE = "drafts";

// ---------------------------------------------------------------- IndexedDB (Entwuerfe, Vorschaubilder); frueher in editor.js
export const IDB = {
  db: null,
  open() {
    if (this.db) return Promise.resolve(this.db);
    return new Promise((res, rej) => {
      const r = indexedDB.open(DB_NAME, DB_VERSION);
      r.onupgradeneeded = () => { const d = r.result; if (!d.objectStoreNames.contains("drafts")) d.createObjectStore("drafts", { keyPath: "fileId" }); if (!d.objectStoreNames.contains("thumbs")) d.createObjectStore("thumbs", { keyPath: "key" }); };
      r.onsuccess = () => { this.db = r.result; this.db.onversionchange = () => { this.db.close(); this.db = null; }; res(this.db); };
      r.onerror = () => rej(r.error); r.onblocked = () => rej(new Error("IndexedDB blockiert"));
    });
  },
  async tx(store, mode, fn) { const d = await this.open(); return new Promise((res, rej) => { const t = d.transaction(store, mode); const q = fn(t.objectStore(store)); q.onsuccess = () => res(q.result); q.onerror = () => rej(q.error); t.onabort = () => rej(t.error || new Error("IndexedDB abgebrochen")); }); },
  get(store, key) { return this.tx(store, "readonly", s => s.get(key)); },
  put(store, val) { return this.tx(store, "readwrite", s => s.put(val)); },
  del(store, key) { return this.tx(store, "readwrite", s => s.delete(key)); },
  all(store) { return this.tx(store, "readonly", s => s.getAll()); },
};

// ---------------------------------------------------------------- Speicher-Interface { all(), get(fileId), put(entry), del(fileId) }
export function memoryStorage(map = new Map()) {
  return { kind: "memory", map,
    async all() { return [...map.values()]; }, async get(id) { return map.has(id) ? map.get(id) : null; },
    async put(e) { map.set(e.fileId, e); }, async del(id) { map.delete(id); } };
}

export function idbStorage(idb = IDB) {
  return { kind: "idb",
    async all() { return (await idb.all(STORE)) || []; }, async get(id) { return (await idb.get(STORE, id)) ?? null; },
    async put(e) { await idb.put(STORE, e); }, async del(id) { await idb.del(STORE, id); } };
}

/// localStorage (oder etwas mit getItem/setItem/removeItem/key/length): ein Schluessel je Datei
export function webStorage(ls, prefix = "notes-queue:") {
  const keys = () => { const out = []; for (let i = 0; i < ls.length; i++) { const k = ls.key(i); if (k && k.startsWith(prefix)) out.push(k); } return out; };
  const read = k => { try { return JSON.parse(ls.getItem(k)); } catch { return null; } };
  return { kind: "web",
    async all() { return keys().map(read).filter(Boolean); }, async get(id) { return read(prefix + id); },
    async put(e) { ls.setItem(prefix + e.fileId, JSON.stringify(e)); }, async del(id) { ls.removeItem(prefix + id); } };
}

/// Im Browser: IndexedDB; wenn die nicht geht (Safari privat, gesperrt), localStorage; sonst nur im Speicher
export function defaultStorage() {
  let impl = null;
  const fallback = () => { try { if (typeof localStorage !== "undefined" && localStorage) return webStorage(localStorage); } catch {} return memoryStorage(); };
  const pick = () => impl || (impl = (typeof indexedDB !== "undefined" && indexedDB) ? idbStorage() : fallback());
  const wrap = m => async (...a) => {
    try { return await pick()[m](...a); }
    catch (e) { if (impl && impl.kind === "idb") { console.warn("Notiz-Warteschlange: IndexedDB nicht nutzbar, Rueckfall", e?.message || e); impl = fallback(); return impl[m](...a); } throw e; }
  };
  return { get kind() { return pick().kind; }, all: wrap("all"), get: wrap("get"), put: wrap("put"), del: wrap("del") };
}

// ---------------------------------------------------------------- Netz oder nicht?
/// Antwort des Service Workers ohne Netz (sw.js): Kopf X-Studora-Offline oder 503 mit Code "offline"
export async function isOfflineResponse(r) {
  if (!r) return false;
  try { if (r.headers && r.headers.get("X-Studora-Offline") === "1") return true; } catch {}
  if (r.status !== 503) return false;
  try { const j = await r.clone().json(); return j && j.code === "offline"; } catch { return false; }
}

/// Basis fuer die Zusammenfuehrung aus dem Entwurf: die Seiten, wie sie vor den eigenen Aenderungen bestaetigt waren
/// (editor.js snap: JSON je Seite); ohne Basis gelten beide Seiten als neu
export function baseOf(entry) {
  if (!entry || !entry.basePages) return null;
  const pages = {};
  for (const [k, v] of Object.entries(entry.basePages)) { if (v == null) continue; try { pages[k] = typeof v === "string" ? JSON.parse(v) : v; } catch {} }
  return { version: 2, pages, pageOrder: [], deletedPages: [] };
}

const PUT_URL = (fileId, version, snapshot) => `/api/files/${encodeURIComponent(fileId)}/annotations?base_version=${version || 0}${snapshot ? "&snapshot=true" : ""}`;

// ---------------------------------------------------------------- Warteschlange
/// storage: Speicher-Interface; fetch: fetch-Funktion; merge: (base, local, server) -> { doc, conflicts }; now: Uhr
export function createQueue({ storage = memoryStorage(), fetch: fetchFn = (typeof fetch === "function" ? fetch.bind(globalThis) : null), merge = mergeDocument, now = Date.now, online = () => (typeof navigator === "undefined" || navigator.onLine !== false) } = {}) {
  const held = new Set(); const reported = new Set(); let account = null; let flushing = null;
  const hooks = { sent() {}, error() {}, merged() {}, offline() {} };
  const mine = e => e && e.dirty && (!e.account || account == null || e.account === account);
  const q = {
    hooks, storage,
    get account() { return account; },
    /// Konto merken: Eintraege tragen es, damit nach einem Kontowechsel nichts unter dem falschen Konto gesendet wird
    setAccount(id) { account = id == null ? null : String(id); },
    hold(fileId) { held.add(fileId); }, release(fileId) { held.delete(fileId); }, isHeld(fileId) { return held.has(fileId); },

    /// Zuletzt gewollter Stand einer Datei (ersetzt den vorigen): { fileId, data, version (= base_version), dirtyKeys,
    /// basePages, struct, meta }. Liefert false, wenn der Speicher nicht schreiben konnte.
    async remember(entry) {
      if (!entry || !entry.fileId) return false;
      const e = { ...entry, dirty: true, savedAt: now(), account: entry.account || account || undefined };
      if (e.account === undefined) delete e.account;
      try { await storage.put(e); return true; } catch (err) { console.warn("Notiz-Warteschlange: nicht gespeichert", err?.message || err); return false; }
    },
    /// Stand ist beim Server: Eintrag bleibt als Entwurf (dirty = false), damit der Editor ihn nicht erneut sendet
    async settled(fileId, { data, version } = {}) {
      try { await storage.put({ fileId, data, version, dirty: false, savedAt: now(), account: account || undefined }); } catch {}
    },
    async get(fileId) { try { return await storage.get(fileId); } catch { return null; } },
    async forget(fileId) { try { await storage.del(fileId); } catch {} },
    /// Unerledigte Eintraege dieses Kontos, aelteste zuerst
    async pending(acc = account) {
      let all = []; try { all = await storage.all(); } catch { return []; }
      return all.filter(e => e && e.dirty && (acc == null || !e.account || e.account === acc)).sort((a, b) => (a.savedAt || 0) - (b.savedAt || 0));
    },
    async count(acc = account) { return (await q.pending(acc)).length; },
    /// Eintraege ohne Konto dem Konto `acc` zuschreiben (alte Entwuerfe vor dem Kontowechsel)
    async claimUntagged(acc) {
      if (acc == null) return 0; let n = 0;
      for (const e of await q.pending(null)) if (!e.account) { try { await storage.put({ ...e, account: String(acc) }); n++; } catch {} }
      return n;
    },

    /// Alles Unerledigte senden (hoechstens ein Lauf gleichzeitig). Ergebnis { sent: [fileId], kept: [fileId], offline }.
    /// Netzfehler: Eintraege bleiben, Lauf endet. 409: zusammenfuehren und erneut senden (bis 3-mal). Anderer Fehler:
    /// Eintrag bleibt, einmal gemeldet (hooks.error).
    flush({ except = null } = {}) {
      if (flushing) return flushing;
      flushing = (async () => {
        const out = { sent: [], kept: [], offline: false };
        if (!fetchFn) return out;
        if (!online()) { out.offline = true; hooks.offline(); return out; }
        for (const entry of await q.pending()) {
          if (!mine(entry) || held.has(entry.fileId) || entry.fileId === except) continue;
          const r = await sendOne(entry);
          if (r.offline) { out.offline = true; out.kept.push(entry.fileId); hooks.offline(); break; }
          if (r.ok) out.sent.push(entry.fileId); else out.kept.push(entry.fileId);
        }
        if (out.sent.length) hooks.sent(out.sent.length, out.sent);
        return out;
      })().finally(() => { flushing = null; });
      return flushing;
    },
  };

  async function sendOne(entry) {
    let body = entry.data, version = entry.version || 0, snapshot = false, merged = 0;
    for (let attempt = 0; attempt < 4; attempt++) {
      let r;
      try { r = await fetchFn(PUT_URL(entry.fileId, version, snapshot), { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }); }
      catch { return { offline: true }; }                                   // fetch selbst gescheitert: kein Netz
      if (await isOfflineResponse(r)) return { offline: true };
      if (r.status === 409) {
        if (attempt === 3) return fail(entry, "Konflikt nicht auflösbar");
        let srv; try { srv = await r.json(); } catch { return fail(entry, "Konflikt ohne Serverstand"); }
        const m = merge(baseOf(entry), body, srv.data || { version: 2, pages: {} });
        body = m.doc; version = srv.version || 0; snapshot = true; merged += (m.conflicts || 0);
        hooks.merged(entry.fileId, m.conflicts || 0);
        continue;
      }
      if (!r.ok) {
        let detail = ""; try { detail = (await r.json()).detail || ""; } catch {}
        return fail(entry, detail ? `${detail} (${r.status})` : `HTTP ${r.status}`);
      }
      let j = {}; try { j = await r.json(); } catch {}
      try { await storage.put({ ...entry, data: body, version: j.version ?? version + 1, dirty: false, savedAt: now() }); } catch {}
      return { ok: true, merged };
    }
    return fail(entry, "Konflikt nicht auflösbar");
  }
  function fail(entry, msg) {
    const key = entry.fileId + ":" + msg;
    if (!reported.has(key)) { reported.add(key); hooks.error(entry.fileId, msg); }
    return { ok: false };
  }
  return q;
}

/// Die eine Warteschlange der Oberflaeche (pwa.js und editor.js teilen sie sich; gleiche Modul-Adresse = gleiche Instanz)
export const notesQueue = createQueue({ storage: defaultStorage() });

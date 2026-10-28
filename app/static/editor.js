// UniFlow Editor 2.0 – PDF- und Notizeditor (pdf.js + Konva + pdf-lib)
// Koordinaten: alle Objekte in Seiteneinheiten (PDF-Punkte bei Zoom 1); Stage wird mit dem Zoom skaliert.
import { icon } from "./icons.js?v=31";
import { mergeDocument } from "./merge.js?v=30";
import { FORMATS, WHITEBOARDS, formatSize, formatOf, sizeLabel, validSize } from "./formats.js?v=30";
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let pdfjsLib = null;
async function getPdfjs() { if (pdfjsLib) return pdfjsLib; pdfjsLib = await import("./vendor/pdf.min.mjs?v=3"); pdfjsLib.GlobalWorkerOptions.workerSrc = "./vendor/pdf.worker.min.mjs?v=3"; return pdfjsLib; }
function loadScript(src) { return new Promise((res, rej) => { if ($(`script[src="${src}"]`)) return res(); const s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = rej; document.head.append(s); }); }

// ---------------------------------------------------------------- IndexedDB (lokale Entwürfe, Vorschaubilder)
export const IDB = {
  db: null,
  open() { if (this.db) return Promise.resolve(this.db); return new Promise((res, rej) => { const r = indexedDB.open("lernapp-editor", 2); r.onupgradeneeded = () => { const d = r.result; if (!d.objectStoreNames.contains("drafts")) d.createObjectStore("drafts", { keyPath: "fileId" }); if (!d.objectStoreNames.contains("thumbs")) d.createObjectStore("thumbs", { keyPath: "key" }); }; r.onsuccess = () => { this.db = r.result; res(this.db); }; r.onerror = () => rej(r.error); }); },
  async get(store, key) { try { const db = await this.open(); return new Promise(res => { const q = db.transaction(store).objectStore(store).get(key); q.onsuccess = () => res(q.result || null); q.onerror = () => res(null); }); } catch { return null; } },
  async put(store, rec) { try { const db = await this.open(); db.transaction(store, "readwrite").objectStore(store).put(rec); } catch {} },
  async del(store, key) { try { const db = await this.open(); db.transaction(store, "readwrite").objectStore(store).delete(key); } catch {} },
};

export const FONTS = ["Arial", "Helvetica", "Segoe UI", "Verdana", "Georgia", "Times New Roman", "Courier New", "Comic Sans MS", "Cambria Math"];
export const TEMPLATES = { blank: "Leer", lined: "Liniert", grid: "Kariert", dotted: "Gepunktet", mm: "Millimeter", cornell: "Cornell" };
const IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const DPR = () => Math.min(window.devicePixelRatio || 1, 2);   // volle Schaerfe; Speicher begrenzt pageDpr() ueber MAX_PX
// iOS Safari hat ein festes Gesamtlimit fuer Canvas-Speicher -> pro Seiten-Canvas hoechstens ~4,5 MPixel
const MAX_PX = IS_IOS ? 4.5e6 : 12e6;
const pageDpr = (pg, zoom) => Math.max(0.6, Math.min(DPR(), Math.sqrt(MAX_PX / Math.max(1, pg.w * zoom * pg.h * zoom))));
try { if (window.Konva) Konva.pixelRatio = DPR(); } catch {}
const PEN_DEFAULTS = { pen: { width: 2.2, opacity: 1 }, fountain: { width: 2.6, opacity: 1 }, pencil: { width: 1.8, opacity: 0.75 }, marker: { width: 16, opacity: 0.35 } };
const WIDTHS = [1.2, 2.5, 5];
const SWATCHES = ["#1d2130", "#5b6170", "#9aa0ae", "#e5322d", "#22a55b", "#9a2a2a", "#2b5df0", "#f5b400"];
// Konva legt je Stage zwei Puffer in voller Seitengroesse an. Gebraucht werden sie nur fuer halbtransparente Formen
// mit Rand und Fuellung (oder Schatten); bei vielen Seiten belegen sie auf dem iPad den knappen Canvas-Speicher.
// Daher 1x1, bis eine Form sie wirklich anfordert (vendorte Konva 9.3.16, _resizeDOM entspricht dem Original).
function patchKonva() {
  const K = window.Konva; if (!K || K._uniBuf) return; K._uniBuf = true;
  const fit = st => { const w = st._needBuf ? st.width() : 1, h = st._needBuf ? st.height() : 1; st.bufferCanvas.setSize(w, h); st.bufferHitCanvas.setSize(w, h); };
  const need = st => { if (st && !st._needBuf) { st._needBuf = true; fit(st); } };
  K.Stage.prototype._resizeDOM = function () { const w = this.width(), h = this.height(); if (this.content) { this.content.style.width = w + "px"; this.content.style.height = h + "px"; } fit(this); this.children.forEach(l => { l.setSize({ width: w, height: h }); l.draw(); }); };
  const ub = K.Shape.prototype._useBufferCanvas; K.Shape.prototype._useBufferCanvas = function (f) { const r = ub.call(this, f); if (r) need(this.getStage()); return r; };
  const is = K.Shape.prototype.intersects; K.Shape.prototype.intersects = function (p) { need(this.getStage()); return is.call(this, p); };
}
// Seiten der Reihe nach rendern: pdf.js rechnet je Seite in 15-ms-Happen pro Bild. Mehrere Seiten gleichzeitig
// (schnelles Scrollen, geteilte Ansicht) lassen dem Scrollen keine Zeit. Immer nur eine, die zur Bildmitte naechste zuerst.
const renderQ = { cur: null, wait: new Set() };
function pumpRender() {
  if (renderQ.cur) return;
  let best = null, bd = Infinity;
  for (const it of renderQ.wait) { if (it.ed.destroyed || !it.pg.mounted || it.pg._rq !== it) { renderQ.wait.delete(it); continue; } const d = it.ed.pageDistance(it.pg); if (d < bd) { bd = d; best = it; } }
  if (!best) return;
  renderQ.wait.delete(best); best.pg._rq = null; renderQ.cur = best;
  const done = () => { if (renderQ.cur !== best) return; renderQ.cur = null; pumpRender(); };
  best.ed.renderPdfNow(best.pg).catch(() => {}).finally(done); setTimeout(done, 8000);   // haengt eine Seite (Netz), nicht alle blockieren
}
const DEFAULT_TEXT = { fontFamily: "Arial", fontSize: 14, fill: "#1d2130", bold: false, italic: false, underline: false, align: "left", bg: "", opacity: 1, width: 220, lineHeight: 1.25 };

// ================================================================= Editor
export class PdfEditor {
  constructor(container, opts) {
    this.c = container; this.fileId = opts.fileId; this.name = opts.name || "Dokument"; this.url = opts.url || null;
    this.onStatus = opts.onStatus || (() => {}); this.onPage = opts.onPage || (() => {}); this.onAccessory = opts.onAccessory || (() => {});
    this.tool = "pen"; this.penType = "pen"; this.color = "#1d2130"; this.width = 2.2; this.opacity = 1; this.eraserSize = 10; this.eraserMode = "partial"; try { const ep = JSON.parse(localStorage.getItem("ed-eraser") || "{}"); if (ep.size) this.eraserSize = ep.size; if (ep.mode) this.eraserMode = ep.mode; } catch {}
    this.shapeKind = "rect"; this.shapeFill = ""; this.textStyle = { ...DEFAULT_TEXT };
    this.zoom = 1.2; this.model = null; this.version = 0; this.dirty = false;
    this.pages = []; this.history = []; this.future = []; this.selection = []; this.clipboard = null;
    this.penSeenAt = 0; this.pointers = new Map(); this.currentPage = 0; this.textCache = new Map(); this.assetDocs = new Map();
    this.destroyed = false; this.penInput = opts.penInput || "all"; this.readOnly = !!opts.readOnly;
    this.ruler = null; this.zoomWin = null; this.recorder = null; this._prev = new Map();
    this.prefs = Object.assign({ scroll: "vertical", single: false, sidebar: "left", hidden: [] }, (() => { try { return JSON.parse(localStorage.getItem("ed-prefs") || "{}"); } catch { return {}; } })());
  }

  // ---------------------------------------------------------------- Laden
  async load() {
    await Promise.all([getPdfjs(), loadScript("./vendor/konva.min.js")]); patchKonva();
    if (this.destroyed) return;                       // waehrend des Ladens geschlossen
    this.buildUI();
    this.onStatus("Lade Dokument…");
    this.pdf = null; this.pageSizes = [];
    if (this.url) {
      const r = await fetch(this.url); const ct = r.headers.get("content-type") || "";
      this.loadInfo = { status: r.status, type: ct, pages: 0 };
      if (!r.ok) throw new Error(`Die Datei konnte nicht geladen werden (HTTP ${r.status}).`);
      if (!ct.includes("pdf")) throw new Error(`Unerwarteter Dateityp „${ct || "unbekannt"}“ – keine PDF.`);
      const buf = await r.arrayBuffer(); if (this.destroyed) return; this.pdfBytes = buf.slice(0);
      try { this.pdf = await pdfjsLib.getDocument({ data: buf }).promise; } catch (e) { throw new Error(`PDF konnte nicht gelesen werden: ${e.message}`); }
      if (this.destroyed) { this.pdf.destroy(); this.pdf = null; return; }
      // Seitengroessen parallel abfragen (nacheinander dauert das bei 100+ Folien auf dem iPad mehrere Sekunden)
      const ps = await Promise.all(Array.from({ length: this.pdf.numPages }, (_, i) => this.pdf.getPage(i + 1)));
      for (const p of ps) { const vp = p.getViewport({ scale: 1 }); this.pageSizes.push({ w: vp.width, h: vp.height }); }
      this.loadInfo.pages = this.pdf.numPages;
    }
    await this.loadModel();
    if (this.destroyed) { this.pdf?.destroy?.(); this.pdf = null; return; }
    this.zoom = this.model.zoom || 1.2;
    this.buildPages(); this.renderSide(); this.updateZoomLabel(); this.setTool(this.tool); this.applyPrefs(); this.updatePenInputBtn();
    if (this.pdf) import("./editor-community.js?v=3").then(m => { if (!this.destroyed) { this.community = m.attach(this); this.pages.forEach(pg => this.community.mountPage(pg)); } }).catch(e => console.warn("Community", e));
    this.onStatus(this._mergedOnLoad ? "Offline-Notizen mit neuerem Stand zusammengeführt" : "Gespeichert");
    this._online = () => this.flush(); window.addEventListener("online", this._online);
  }
  async loadModel() {
    let server = null;
    try { const r = await fetch(`/api/files/${this.fileId}/annotations`); if (r.ok) server = await r.json(); else this.offline = true; } catch { this.offline = true; }
    const draft = await IDB.get("drafts", this.fileId);
    const serverModel = server ? this.migrate(server.data || { version: 2 }) : null;
    this.version = server ? (server.version || 0) : (draft?.version || 0);
    if (draft && draft.dirty && (!server || (draft.version || 0) >= (server.version || 0))) {
      // ungesendeter Entwurf auf dem neuesten Stand
      this.model = this.migrate(draft.data); this.dirty = true;
      this.base = this.snap(serverModel || this.migrate({ version: 2 }));
    } else if (draft && draft.dirty && serverModel) {
      // Entwurf ist aelter als der Server (anderes Geraet hat inzwischen gespeichert): zusammenfuehren statt verwerfen
      const local = this.migrate(draft.data);
      const keys = draft.dirtyKeys || Object.keys(local.pages).filter(k => JSON.stringify(local.pages[k]) !== JSON.stringify(serverModel.pages[k]));
      this.model = this.mergeInto(serverModel, local, { keys, struct: !!draft.struct, meta: !!draft.meta }, draft.basePages ? { pages: draft.basePages } : null);
      this.base = this.snap(serverModel); this.dirty = true;
      this._mergedOnLoad = keys.length;
    } else {
      this.model = serverModel || this.migrate({ version: 2 });
      this.base = this.snap(this.model);
    }
    if (this.dirty) this.scheduleSave();
  }
  // Vergleichsstand: pro Seite das JSON, dazu Seitenreihenfolge und Dokument-Notizen
  snap(m) { return { pages: Object.fromEntries(Object.entries(m.pages || {}).map(([k, v]) => [k, JSON.stringify(v)])), order: JSON.stringify([m.pageOrder || [], m.deletedPages || []]), meta: JSON.stringify([m.note || "", m.bookmarks || [], m.outline || []]) }; }
  diffFromBase(m = this.model) { const b = this.base || { pages: {}, order: "", meta: "" }; const keys = Object.keys(m.pages || {}).filter(k => b.pages[k] !== JSON.stringify(m.pages[k])); const cur = this.snap(m); return { keys, struct: cur.order !== b.order, meta: cur.meta !== b.meta }; }
  // Drei-Wege-Zusammenfuehrung des ganzen Dokuments (merge.js mergeDocument: Seiten, Reihenfolge, Papierkorb, Notizen).
  // base = letzter bestaetigter Stand als snap (oder nur { pages }) oder null; d bleibt fuer die Rueckgabe von applyServerMerge
  mergeInto(server, local, d, base = null) {
    const r = mergeDocument(base ? this.unsnap(base) : null, local, server);
    this._mergeConflicts = r.conflicts; this._orderConflict = r.orderConflict;
    return this.migrate(r.doc);
  }
  // snap() zurueck in ein Dokument (fehlende Teile = unbekannt, dann gelten beide Seiten als neu)
  unsnap(s) {
    const [pageOrder, deletedPages] = s.order ? JSON.parse(s.order) : [[], []]; const [note, bookmarks, outline] = s.meta ? JSON.parse(s.meta) : ["", [], []];
    return { version: 2, pages: Object.fromEntries(Object.entries(s.pages || {}).map(([k, v]) => [k, typeof v === "string" ? JSON.parse(v) : v])), pageOrder, deletedPages, note, bookmarks, outline };
  }
  // Serverstand eines anderen Geraets uebernehmen, eigene geaenderte Seiten behalten, Anzeige nur dort erneuern, wo noetig
  applyServerMerge(serverData, version) {
    const server = this.migrate(serverData || { version: 2 });
    const d = this.diffFromBase(this.model);
    const merged = this.mergeInto(server, this.model, d, this.base || null);
    const old = this.model; const orderChanged = JSON.stringify(merged.pageOrder) !== JSON.stringify(old.pageOrder);
    this.model = merged; this.version = version; this.base = this.snap(server);
    this.history = []; this.future = [];          // Undo-Schritte bezogen sich auf den alten Stand
    if (this.destroyed) { /* geschlossen: nur noch speichern */ }
    else if (orderChanged) this.buildPages();
    else for (const pg of this.pages) { if (pg.mounted && JSON.stringify(old.pages[pg.key]?.objects) !== JSON.stringify(merged.pages[pg.key]?.objects)) this.reloadPage(pg); }
    this.onStatus(this._orderConflict ? "Seitenreihenfolge auf beiden Geräten geändert – die Reihenfolge dieses Geräts gilt"
      : this._mergeConflicts ? `Mit anderem Gerät zusammengeführt – ${this._mergeConflicts} Konflikt${this._mergeConflicts > 1 ? "e" : ""}, dieses Gerät gilt` : "Mit anderem Gerät zusammengeführt");
    return d.keys.length + (d.struct || d.meta ? 1 : 0);
  }
  // Aufgabe auf der aktuellen Seite: Block ab der Ueberschrift "Aufgabe 2.3" ueber dem letzten Strich (sonst Bildmitte)
  async taskContext() {
    const pg = this.pages[this.currentPage]; if (!pg || pg.type !== "pdf" || !this.pdf) return null;
    const page = await this.pdf.getPage(pg.index); const tc = await page.getTextContent(); const vp = page.getViewport({ scale: 1, rotation: ((page.rotate || 0) + (pg.rotation || 0)) % 360 });
    const lines = [];
    for (const it of tc.items) { if (!it.str || !it.str.trim()) continue; const [, y] = vp.convertToViewportPoint(it.transform[4], it.transform[5]); let L = lines.find(l => Math.abs(l.y - y) < 4); if (!L) { L = { y, s: "" }; lines.push(L); } L.s += (L.s ? " " : "") + it.str; }
    lines.sort((a, b) => a.y - b.y);
    let ty = null;
    if (this._lastInkPage === pg.key && Date.now() - (this._lastInkAt || 0) < 120000) { const last = [...(this.model.pages[pg.key]?.objects || [])].reverse().find(o => o.type === "stroke" && o.points?.length); if (last) ty = last.points[1] + (last.y || 0); }
    if (ty == null) { const r = pg.el.getBoundingClientRect(), sr = this.scroll.getBoundingClientRect(); ty = ((sr.top + sr.height / 2) - r.top) / this.zoom; }
    const heads = lines.map((l, i) => ({ i, m: l.s.match(/^\s*(Aufgabe|Übung|Uebung|Exercise|Problem)\s*(\d+(?:[.,]\d+)?)/i) })).filter(h => h.m);
    let from = 0, to = lines.length, label = `Seite ${this.currentPage + 1}`;
    if (heads.length) { const cur = heads.filter(h => lines[h.i].y <= ty + 12).pop() || heads[0]; const nxt = heads.find(h => h.i > cur.i); from = cur.i; to = nxt ? nxt.i : lines.length; label = `${cur.m[1]} ${cur.m[2]}`; }
    return { page: this.currentPage + 1, label, text: lines.slice(from, to).map(l => l.s).join("\n"), key: `${pg.key}:${from}` };
  }
  reloadPage(pg) { this.clearSelection(); pg.layer.find(".obj").forEach(n => n.destroy()); (this.model.pages[pg.key]?.objects || []).forEach(o => this.addNode(pg, o)); pg.layer.batchDraw(); }
  migrate(m) {
    const n = this.pdf ? this.pdf.numPages : 0;
    const out = { ...(m.version === 2 ? m : {}), version: 2, zoom: m.zoom || 1.2, pages: {}, pageOrder: [], bookmarks: m.bookmarks || [], outline: m.outline || [], note: m.note || "", deletedPages: m.deletedPages || [] };
    if (m.version === 2 && m.pageOrder) { out.pages = m.pages || {}; out.pageOrder = m.pageOrder; }
    else {
      for (let i = 1; i <= n; i++) {
        const old = (m.pages || {})[i]; const { w, h } = this.pageSizes[i - 1]; const objs = [];
        if (old) {
          (old.strokes || []).forEach(s => objs.push({ id: uid(), type: "stroke", tool: s.tool === "marker" ? "marker" : "pen", color: s.color || "#e5322d", width: s.tool === "marker" ? 14 : 2.2, opacity: s.tool === "marker" ? 0.35 : 1, points: s.pts.flatMap(([x, y]) => [x * w, y * h]), x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1 }));
          (old.notes || []).forEach(nt => objs.push({ id: uid(), type: "text", x: nt.x * w, y: nt.y * h, width: 160, text: nt.text || "", ...DEFAULT_TEXT, bg: "#fff7a8", rotation: 0, scaleX: 1, scaleY: 1 }));
        }
        out.pages["p" + i] = { objects: objs };
      }
    }
    if (!out.pageOrder.length) { for (let i = 1; i <= n; i++) out.pageOrder.push({ key: "p" + i, type: "pdf", index: i }); if (!n) { out.pageOrder.push({ key: "b1", type: "blank", template: "blank", w: 595, h: 842 }); } }
    out.pageOrder.forEach(p => { out.pages[p.key] ||= { objects: [] }; });
    return out;
  }

  // ---------------------------------------------------------------- UI
  buildUI() {
    this.c.classList.add("ed"); this.c.classList.toggle("ed-readonly", this.readOnly); this.c.innerHTML = `
      <div class="ed-bar ed-main">
        <div class="ed-group ed-left">
          <button data-act="side" title="Seitenleiste">${icon("panel-left")}</button>
          <button data-act="search" title="Im Dokument suchen">${icon("search")}</button>
          <button data-act="ai" title="KI-Assistent">${icon("sparkles")}</button>
          <button data-act="community" class="ed-combtn" title="Community: Lösungen anderer, Kommentare, eigene Lösung teilen">${icon("users")}</button>
        </div>
        <div class="ed-group ed-tools">
          <button data-tool="lasso" title="Lasso (L)">${icon("lasso")}</button>
          <button data-tool="pen" title="Stift (P)">${icon("pen")}</button>
          <button data-tool="marker" title="Textmarker">${icon("highlighter")}</button>
          <button data-tool="eraser" title="Radierer (E)">${icon("eraser")}</button>
          <button data-tool="text" title="Text (T)">${icon("type")}</button>
          <button data-tool="shape" title="Formen (S)">${icon("square")}</button>
          <button data-tool="image" title="Bild einfügen">${icon("image")}</button>
          <button data-tool="sticky" title="Haftnotiz">${icon("note")}</button>
          <button data-tool="textselect" title="PDF-Text markieren (für KI)">${icon("text-select")}</button>
          <button data-tool="hand" title="Verschieben (Leertaste)">${icon("hand")}</button>
          <span class="ed-sep"></span>
          <button data-act="accessories" title="Zubehör">${icon("more")} ${icon("chevron-down", 12)}</button>
        </div>
        <div class="ed-group ed-right">
          <span class="ed-status"></span>
          <button data-act="peninput" class="ed-peninput" title="Eingabe: Nur Stift / Finger & Stift">${icon("pen")}</button>
          <button data-act="addpage" title="Seite hinzufügen">${icon("page-plus")}</button>
          <button data-act="export" title="Teilen und Exportieren">${icon("download")}</button>
          <button data-act="more" title="Mehr">${icon("more")}</button>
        </div>
      </div>
      <div class="ed-bar ed-ctx"><div class="ed-group"><button data-act="undo" title="Rückgängig (Strg+Z)">${icon("undo")}</button><button data-act="redo" title="Wiederholen (Strg+Y)">${icon("redo")}</button></div><div class="ed-ctx-body"></div></div>
      <div class="ed-body">
        <aside class="ed-side"><div class="ed-side-head"><div class="seg"><button data-side="pages" class="active" title="Seiten">${icon("file")}</button><button data-side="outline" title="Gliederung">${icon("list")}</button><button data-side="rec" title="Aufnahmen">${icon("sync")}</button></div><button class="ed-side-close" title="Schließen">${icon("x", 16)}</button></div><div class="ed-side-body"></div></aside>
        <div class="ed-scroll" tabindex="0"><div class="ed-pages"></div></div>
        <aside class="ed-ai" hidden>
          <div class="ed-ai-head"><strong>${icon("sparkles", 16)} KI-Tutor</strong><span class="ed-ai-page"></span><button class="ed-ai-close">${icon("x", 16)}</button></div>
          <label>Modus<select class="ed-ai-mode"><option value="explain">Markiertes erklären</option><option value="explain_simple">Einfach erklären</option><option value="summary">Seite zusammenfassen</option><option value="terms">Fachbegriffe definieren</option><option value="steps">Aufgabe schrittweise lösen</option><option value="hints">Nur Hinweise geben</option><option value="check">Meine Lösung prüfen</option><option value="similar">Ähnliche Aufgabe erstellen</option><option value="flashcards">Karteikarten erstellen</option><option value="quiz">Quizfragen erstellen</option></select></label>
          <label>Markierter Text <small>(Werkzeug ¶ oder einfügen)</small><textarea class="ed-ai-sel" rows="3"></textarea></label>
          <label class="ed-ai-own-wrap" hidden>Meine Lösung<textarea class="ed-ai-own" rows="4"></textarea></label>
          <label>Frage (optional)<input class="ed-ai-q"></label>
          <label class="small"><input type="checkbox" class="ed-ai-ctx" checked> Aktuelle Seite als Kontext mitgeben</label>
          <button class="btn primary ed-ai-go">Fragen</button><div class="ed-ai-out"></div>
        </aside>
        <aside class="ed-com" hidden></aside>
      </div>
      <div class="ed-zoomwin" hidden><div class="ed-zw-head"><b>Zoom-Ansicht</b><span class="muted small">Schreibe hier, der Text erscheint an der markierten Stelle der Seite.</span><span class="spacer"></span><button data-zw="left" title="Nach links">${icon("chevron-left", 14)}</button><button data-zw="right" title="Nach rechts">${icon("chevron-right", 14)}</button><button data-zw="down" title="Nächste Zeile">${icon("chevron-down", 14)}</button><button data-zw="close">${icon("x", 14)}</button></div><div class="ed-zw-body"><canvas class="ed-zw-canvas"></canvas></div></div>
      <div class="ed-pageinfo"><button data-act="prev">${icon("chevron-left", 14)}</button> Seite <input class="ed-pageno" type="number" min="1" value="1"> / <span class="ed-pagecount">?</span> <button data-act="next">${icon("chevron-right", 14)}</button><span class="ed-sep"></span><button data-act="zoomout" title="Kleiner">${icon("zoom-out", 14)}</button><span class="ed-zoom">120%</span><button data-act="zoomin" title="Größer">${icon("zoom-in", 14)}</button><button data-act="fit" title="Seitenbreite">${icon("fit", 14)}</button><button data-act="fullscreen" title="Vollbild">${icon("maximize", 14)}</button></div>
      <div class="ed-pop" hidden></div>`;
    this.scroll = $(".ed-scroll", this.c); this.pagesEl = $(".ed-pages", this.c); this.ctx = $(".ed-ctx-body", this.c); this.pop = $(".ed-pop", this.c);
    $$("[data-tool]", this.c).forEach(b => b.onclick = () => this.setTool(b.dataset.tool, true));
    $$("[data-act]", this.c).forEach(b => b.onclick = e => this.action(b.dataset.act, b));
    $$("[data-side]", this.c).forEach(b => b.onclick = () => { this.sideTab = b.dataset.side; $$("[data-side]", this.c).forEach(x => x.classList.toggle("active", x === b)); this.renderSide(); });
    $(".ed-side-close", this.c).onclick = () => this.toggleSide(false);
    $(".ed-pageno", this.c).onchange = e => this.goToPage(+e.target.value - 1);
    $(".ed-ai-close", this.c).onclick = () => $(".ed-ai", this.c).hidden = true;
    $(".ed-ai-go", this.c).onclick = () => this.askAI();
    $(".ed-ai-mode", this.c).onchange = e => { $(".ed-ai-own-wrap", this.c).hidden = e.target.value !== "check"; };
    $$("[data-zw]", this.c).forEach(b => b.onclick = () => this.zoomWinAction(b.dataset.zw));
    this.scroll.addEventListener("scroll", () => {
      if (this.destroyed) return;                    // Browser liefert ein vorgemerktes Scroll-Ereignis evtl. erst nach dem Schliessen
      this._scrollEpoch = (this._scrollEpoch || 0) + 1;
      { const now = performance.now(), st = this.scroll.scrollTop + this.scroll.scrollLeft, L = this._lastSc; if (L && now - L.t < 100 && Math.abs(st - L.st) / Math.max(1, now - L.t) > 1.2) this._scrollFastAt = now; this._lastSc = { t: now, st }; }
      this.onScroll(); clearTimeout(this._sct); this._sct = setTimeout(() => { if (!this.pan && !this.pinch && !this.penDown && !this._activeLive && !this._clampAnim && !this._fling) this.clampView(true); }, 220); });
    this._ro = new ResizeObserver(() => { this.setPad(); this.clampView(); }); this._ro.observe(this.scroll);
    this.scroll.addEventListener("wheel", e => { if (e.ctrlKey || e.metaKey) { e.preventDefault(); this.zoomAt(this.zoom * (e.deltaY < 0 ? 1.1 : 0.9), e.clientX, e.clientY); } }, { passive: false });
    this.scroll.addEventListener("keydown", e => this.onKey(e));
    this.c.addEventListener("paste", e => this.onPaste(e));
    // ---- Eingabe: Stift zeichnet, Finger scrollt/zoomt, Handballen wird ignoriert, nichts rutscht nach
    this.penDown = false; this.penLiftAt = 0; this.pan = null; this.touches = new Map();
    const PALM_AFTER_PEN = 500, PAN_SLOP = 8;
    const stopScrollMotion = () => { this._fling = null; this._clampAnim = null; this.pan = null; if (this.pinch) this.pinchEnd(); this.pointers.clear(); clearTimeout(this._initialGoto); const t = this.scroll.scrollTop, l = this.scroll.scrollLeft; this.scroll.scrollTop = t; this.scroll.scrollLeft = l; };
    this.scroll.addEventListener("pointerdown", e => {
      this._fling = null; clearTimeout(this._initialGoto); if (this._pendMount?.size) this.flushMounts(true);
      const palmLike = e.pointerType === "touch" && (this.penDown || Date.now() - this.penLiftAt < PALM_AFTER_PEN || (e.width > 90 && e.height > 90));
      if (e.pointerType !== "pen" && !palmLike && this.ruler?.group && (this.rulerG || this.rulerHit(e.clientX, e.clientY, e.pointerType === "mouse"))) { this.rulerDown(e); e.stopPropagation(); e.preventDefault(); return; }
      if (e.pointerType === "pen" || e.pointerType === "mouse") {
        if (e.pointerType === "pen") {
          this.penDown = true; this.penSeenAt = Date.now(); this.rulerG = null;
          this.touches.forEach(t => { t.palm = true; });          // was schon aufliegt, ist Handballen
          stopScrollMotion(); this.cancelLiveStroke("touch");
          try { window.getSelection()?.removeAllRanges(); } catch {}
          if (this.penInput !== "pen_only" && !this._penManual) { this.penInput = "pen_only"; this.updatePenInputBtn(); this.onStatus("Apple Pencil erkannt – Finger scrollt und zoomt"); fetch("/api/settings", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ pen_input: "pen_only" }) }).catch(() => {}); }
        }
        if (this.tool === "hand" || this.spaceHand) { this.pan = { id: e.pointerId, x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, moved: true, noFling: true, t: performance.now() }; e.preventDefault(); e.stopPropagation(); }
        return;
      }
      if (e.pointerType !== "touch") return;
      const palm = this.penDown || Date.now() - this.penLiftAt < PALM_AFTER_PEN || (e.width > 90 && e.height > 90);
      this.touches.set(e.pointerId, { sx: e.clientX, sy: e.clientY, palm, ev: e });
      if (palm) { e.stopPropagation(); e.preventDefault(); return; }
      const fingers = [...this.touches.entries()].filter(([, t]) => !t.palm);
      const panMode = this.penInput === "pen_only" || this.tool === "hand" || this.spaceHand;
      if (fingers.length === 2) {
        this.cancelLiveStroke("touch");                          // Finger-Strich der ersten Beruehrung verwerfen
        this.pointers.clear(); fingers.forEach(([id, t]) => this.pointers.set(id, t.ev)); this.pan = null; this.pinchStart();
        e.stopPropagation(); e.preventDefault();
      } else if (fingers.length === 1 && panMode) {
        this.pan = { id: e.pointerId, x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, moved: false, t: performance.now(), vx: 0, vy: 0 };
        e.stopPropagation(); e.preventDefault();
      } else if (fingers.length > 2) { e.stopPropagation(); e.preventDefault(); }
    }, true);
    this.scroll.addEventListener("pointermove", e => {
      if (this.rulerG?.ptrs.has(e.pointerId)) { this.rulerMove(e); e.stopPropagation(); e.preventDefault(); return; }
      const t = this.touches.get(e.pointerId);
      if (t) { t.ev = e; if (t.palm) { e.stopPropagation(); e.preventDefault(); return; } }
      if (this.pinch && this.pointers.has(e.pointerId)) { this.pointers.set(e.pointerId, e); if (!this.penDown) this.pinchMove(); e.stopPropagation(); e.preventDefault(); return; }
      const p = this.pan; if (!p || p.id !== e.pointerId) return;
      e.stopPropagation(); e.preventDefault();
      if (e.pointerType === "touch" && (this.penDown || Date.now() - this.penLiftAt < PALM_AFTER_PEN)) { p.x = e.clientX; p.y = e.clientY; p.noFling = true; return; }
      if (!p.moved) { if (Math.hypot(e.clientX - p.sx, e.clientY - p.sy) < PAN_SLOP) return; p.moved = true; p.x = e.clientX; p.y = e.clientY; p.t = performance.now(); return; }
      const now = performance.now(); const dx = e.clientX - p.x, dy = e.clientY - p.y; this.scroll.scrollLeft -= dx; this.scroll.scrollTop -= dy; this.clampView();
      const dt = Math.max(1, now - p.t); p.vx = 0.7 * (p.vx || 0) + 0.3 * (dx / dt); p.vy = 0.7 * (p.vy || 0) + 0.3 * (dy / dt); p.t = now; p.x = e.clientX; p.y = e.clientY;
    }, true);
    const up = e => {
      if (this.rulerG?.ptrs.has(e.pointerId)) { this.rulerG.ptrs.delete(e.pointerId); if (!this.rulerG.ptrs.size) this.rulerG = null; else this.rulerReset(); e.stopPropagation(); return; }
      if (e.pointerType === "pen") { this.penDown = false; this.penLiftAt = Date.now(); this.penSeenAt = Date.now(); }
      const t = this.touches.get(e.pointerId); this.touches.delete(e.pointerId);
      if (this.pointers.has(e.pointerId)) { this.pointers.clear(); this.pinchEnd(); }
      const p = this.pan;
      if (p && p.id === e.pointerId) {
        this.pan = null;
        const travel = Math.hypot(e.clientX - p.sx, e.clientY - p.sy);
        if (e.type === "pointerup" && p.moved && !p.noFling && !(t && t.palm) && travel > 30 && performance.now() - (p.t || 0) < 60 && Date.now() - this.penLiftAt > PALM_AFTER_PEN) this.fling(p.vx || 0, p.vy || 0);
      }
    };
    // Safari: Markieren, Lupe, Kontextmenue und Seiten-Zoom auf der Schreibflaeche unterdruecken
    const blockNative = e => {
      if (e.target.closest?.("textarea, input, select, .ed-textedit")) return;
      if (["text", "sticky", "image"].includes(this.tool)) return;
      if (e.cancelable) e.preventDefault();
    };
    this.scroll.addEventListener("touchstart", blockNative, { passive: false, capture: true });
    this.scroll.addEventListener("touchmove", blockNative, { passive: false, capture: true });
    this.scroll.addEventListener("contextmenu", e => e.preventDefault());
    document.addEventListener("gesturestart", this._gest = e => { if (this.c.contains(e.target)) e.preventDefault(); }, { passive: false });
    document.addEventListener("gesturechange", this._gest, { passive: false });
    document.addEventListener("selectstart", this._selStart = e => { if (this.penDown || this._activeLive) e.preventDefault(); });
    // Sicherheitsnetz: Abheben, das nicht ueber die Seite kommt, beendet den Strich trotzdem
    this._winUp = e => { if (e.pointerType === "pen") { this.penDown = false; this.penLiftAt = Date.now(); } this.touches?.delete(e.pointerId); const a = this._activeLive; if (a && a.id === e.pointerId) a.finish(); };
    window.addEventListener("pointerup", this._winUp); window.addEventListener("pointercancel", this._winUp);
    this._resetInput = () => { this.penDown = false; this.pan = null; if (this.pinch) this.pinchEnd(); this.pointers.clear(); this.touches?.clear(); this.rulerG = null; this._activeLive?.finish(); if (this.dirty && !this.destroyed) { this._writeDraft(true); if (document.visibilityState === "hidden") this.flush(); } };
    document.addEventListener("visibilitychange", this._resetInput); window.addEventListener("blur", this._resetInput); window.addEventListener("pagehide", this._resetInput);
    // Stift-Cursor beim Schweben (fixiert, veraendert die Scrollflaeche nicht)
    this.cursorEl = document.createElement("div"); this.cursorEl.className = "ed-cursor"; this.cursorEl.hidden = true; this.c.append(this.cursorEl);
    this.scroll.addEventListener("pointermove", e => { if ((this.tool !== "pen" && this.tool !== "eraser") || e.pointerType === "touch" || e.buttons || this.penDown) { this.cursorEl.hidden = true; return; } const sz = this.tool === "eraser" ? this.eraserSize : Math.max(2, this.width * this.zoom); this.cursorEl.style.cssText = `width:${sz}px;height:${sz}px;left:${e.clientX}px;top:${e.clientY}px;border-color:${this.tool === "eraser" ? "#888" : this.color}`; this.cursorEl.hidden = false; });
    this.scroll.addEventListener("pointerleave", () => { this.cursorEl.hidden = true; });
    this.scroll.addEventListener("pointerup", up, true); this.scroll.addEventListener("pointercancel", up, true);
    this.scroll.style.touchAction = "none";
    document.addEventListener("keydown", this._space = e => { if (e.code === "Space" && !this.editingText && this.c.contains(document.activeElement)) { this.spaceHand = true; this.scroll.classList.add("hand"); } });
    document.addEventListener("keyup", this._spaceUp = e => { if (e.code === "Space") { this.spaceHand = false; this.scroll.classList.remove("hand"); } });
    document.addEventListener("pointerdown", this._popClose = e => { if (!this.pop.hidden && !this.pop.contains(e.target) && !e.target.closest("[data-act]")) this.pop.hidden = true; });
    this.sideTab = "pages";
  }
  applyPrefs() { this.scroll.classList.toggle("horizontal", this.prefs.scroll === "horizontal"); this.c.classList.toggle("side-right", this.prefs.sidebar === "right"); this.c.classList.toggle("single", !!this.prefs.single); $$("[data-tool]", this.c).forEach(b => b.hidden = this.prefs.hidden.includes(b.dataset.tool)); if (this.prefs.single) this.showSingle(); }
  savePrefs() { try { localStorage.setItem("ed-prefs", JSON.stringify(this.prefs)); } catch {} this.applyPrefs(); }
  toggleSide(on) { const s = $(".ed-side", this.c); const show = on ?? !s.classList.contains("open"); s.classList.toggle("open", show); if (show) this.renderSide(); }

  // ---------------------------------------------------------------- Kontextleiste
  renderCtx() {
    const t = this.tool; let html = "";
    const sw = (cur, attr) => `<span class="ed-swatches">${SWATCHES.map(c => `<button class="ed-sw ${cur === c ? "on" : ""}" data-${attr}="${c}" style="background:${c}" title="${c}"></button>`).join("")}<label class="ed-sw custom" title="Eigene Farbe"><input type="color" data-${attr}-custom value="${cur}"></label></span>`;
    if (t === "pen") html = `<span class="ed-group">${[["pen", "pen", "Kugelschreiber"], ["fountain", "fountain", "Füller"], ["pencil", "pencil", "Bleistift"], ["marker", "highlighter", "Textmarker"]].map(([k, i, n]) => `<button class="${this.penType === k ? "active" : ""}" data-pen="${k}" title="${n}">${icon(i)}</button>`).join("")}</span><span class="ed-group ed-widths">${WIDTHS.map(w => `<button class="ed-w ${Math.abs(this.width - w) < 0.01 ? "on" : ""}" data-w="${w}" title="${w} px"><i style="height:${Math.min(12, 2 + w * 1.6)}px"></i></button>`).join("")}<label title="Strichstärke"><input type="range" class="ed-width" min="0.5" max="40" step="0.5" value="${this.width}"></label>${this.penType === "marker" ? `<label title="Deckkraft">${icon("circle", 12)}<input type="range" class="ed-opacity" min="0.1" max="1" step="0.05" value="${this.opacity}"></label>` : ""}</span>${sw(this.color, "color")}`;
    else if (t === "eraser") html = `<span class="ed-group">${[[10, "Klein"], [18, "Mittel"], [34, "Groß"]].map(([s, n]) => `<button class="${this.eraserSize === s ? "active" : ""}" data-esize="${s}" title="${n}"><i class="ed-edot" style="width:${s / 2 + 6}px;height:${s / 2 + 6}px"></i></button>`).join("")}</span><span class="ed-group"><div class="seg"><button class="${this.eraserMode === "partial" ? "active" : ""}" data-emode="partial">Teilweise</button><button class="${this.eraserMode === "whole" ? "active" : ""}" data-emode="whole">Ganzer Strich</button><button class="${this.eraserMode === "object" ? "active" : ""}" data-emode="object">Objekte</button></div></span><span class="muted small">Radiert nur deine Notizen, nie das Original-PDF.</span>`;
    else if (t === "text" || (this.selection.length && this.selection.some(s => s.node.getAttr("obj").type === "text"))) {
      const st = this.selText() || this.textStyle;
      html = `<span class="ed-group"><select class="ed-font" title="Schriftart">${FONTS.map(f => `<option style="font-family:'${f}'" ${st.fontFamily === f ? "selected" : ""}>${f}</option>`).join("")}</select><input type="number" class="ed-size" min="6" max="120" value="${st.fontSize}" title="Schriftgröße"><input type="color" class="ed-tcolor" value="${st.fill}" title="Textfarbe"></span><span class="ed-group"><button data-fmt="bold" class="${st.bold ? "active" : ""}" title="Fett">${icon("bold")}</button><button data-fmt="italic" class="${st.italic ? "active" : ""}" title="Kursiv">${icon("italic")}</button><button data-fmt="underline" class="${st.underline ? "active" : ""}" title="Unterstrichen">${icon("underline")}</button></span><span class="ed-group"><button data-align="left" class="${st.align === "left" ? "active" : ""}">${icon("align-left")}</button><button data-align="center" class="${st.align === "center" ? "active" : ""}">${icon("align-center")}</button><button data-align="right" class="${st.align === "right" ? "active" : ""}">${icon("align-right")}</button></span><span class="ed-group"><label title="Zeilenabstand">↕<select class="ed-lh">${[1, 1.25, 1.5, 2].map(v => `<option value="${v}" ${(st.lineHeight || 1.25) == v ? "selected" : ""}>${v}</option>`).join("")}</select></label><label title="Hintergrund"><input type="color" class="ed-bg" value="${st.bg || "#ffffff"}"><button data-act="nobg" title="Kein Hintergrund">${icon("x", 12)}</button></label><label title="Transparenz">${icon("circle", 12)}<input type="range" class="ed-topacity" min="0.1" max="1" step="0.05" value="${st.opacity ?? 1}"></label></span>`;
    } else if (t === "shape") html = `<span class="ed-group">${[["line", "line", "Linie"], ["arrow", "arrow", "Pfeil"], ["rect", "square", "Rechteck"], ["ellipse", "circle", "Kreis/Ellipse"], ["triangle", "triangle", "Dreieck"], ["polygon", "layers", "Polygon (Klicks, Doppelklick beendet)"]].map(([k, i, n]) => `<button class="${this.shapeKind === k ? "active" : ""}" data-shape="${k}" title="${n}">${icon(i)}</button>`).join("")}</span><span class="ed-group"><label title="Strichstärke">${icon("pen", 12)}<input type="range" class="ed-width" min="0.5" max="20" step="0.5" value="${this.width}"></label><label title="Transparenz">${icon("circle", 12)}<input type="range" class="ed-opacity" min="0.1" max="1" step="0.05" value="${this.opacity}"></label></span>${sw(this.color, "color")}<span class="ed-group"><label title="Füllung">Füllung <input type="color" class="ed-fill" value="${this.shapeFill || "#ffffff"}"><button data-act="nofill" title="Keine Füllung">${icon("x", 12)}</button></label></span>`;
    else if (t === "lasso") { const s = this.selection[0]?.node.getAttr("obj"); html = this.selection.length ? `<span class="ed-group"><span class="small muted">${this.selection.length} ausgewählt</span><button data-act="duplicate" title="Duplizieren">${icon("copy")}</button><button data-act="copy" title="Kopieren">${icon("copy")}</button><button data-act="cut" title="Ausschneiden">${icon("eraser")}</button><button data-act="delete" title="Löschen">${icon("trash")}</button></span>${s && (s.type === "stroke" || s.type === "shape") ? `<span class="ed-group"><label>${icon("pen", 12)}<input type="range" class="ed-width" min="0.5" max="40" step="0.5" value="${s.width || s.strokeWidth || 2}"></label><label>${icon("circle", 12)}<input type="range" class="ed-opacity" min="0.1" max="1" step="0.05" value="${s.opacity ?? 1}"></label></span>${sw(s.color || s.stroke, "color")}` : ""}` : `<span class="muted small">Umkreise Notizen mit dem Lasso oder ziehe ein Rechteck. Dann verschieben, skalieren, drehen, kopieren.</span>`; }
    else if (t === "image") html = `<span class="muted small">Klicke auf die Seite, um ein Bild einzufügen, oder füge einen Screenshot mit Strg+V ein.</span><button data-act="image">${icon("image")} Bild wählen</button>`;
    else if (t === "sticky") html = `<span class="muted small">Klicke auf die Seite, um eine Haftnotiz zu platzieren.</span>${sw(this.stickyColor || "#fff7a8", "sticky")}`;
    else if (t === "textselect") html = `<span class="muted small">Ziehe ein Rechteck über PDF-Text, der Text landet in der KI-Seitenleiste.</span>`;
    else if (t === "hand") html = `<span class="muted small">Ziehen zum Verschieben, Strg+Mausrad oder zwei Finger zum Zoomen.</span>`;
    this.ctx.innerHTML = html;
    $$("[data-pen]", this.ctx).forEach(b => b.onclick = () => { this.penType = b.dataset.pen; const d = PEN_DEFAULTS[this.penType]; this.width = d.width; this.opacity = d.opacity; this.renderCtx(); });
    $$("[data-w]", this.ctx).forEach(b => b.onclick = () => { this.width = +b.dataset.w; this.applyToSelection({ width: this.width, strokeWidth: this.width }); this.renderCtx(); });
    $$("[data-color]", this.ctx).forEach(b => b.onclick = () => { this.color = b.dataset.color; this.applyToSelection({ color: this.color, stroke: this.color }); this.renderCtx(); });
    $("[data-color-custom]", this.ctx)?.addEventListener("input", e => { this.color = e.target.value; this.applyToSelection({ color: this.color, stroke: this.color }); });
    $$("[data-sticky]", this.ctx).forEach(b => b.onclick = () => { this.stickyColor = b.dataset.sticky; this.renderCtx(); });
    $(".ed-width", this.ctx)?.addEventListener("input", e => { this.width = +e.target.value; this.applyToSelection({ width: this.width, strokeWidth: this.width }); });
    $(".ed-opacity", this.ctx)?.addEventListener("input", e => { this.opacity = +e.target.value; this.applyToSelection({ opacity: this.opacity }); });
    $$("[data-esize]", this.ctx).forEach(b => b.onclick = () => { this.eraserSize = +b.dataset.esize; this.saveEraser(); this.renderCtx(); });
    $$("[data-emode]", this.ctx).forEach(b => b.onclick = () => { this.eraserMode = b.dataset.emode; this.saveEraser(); this.renderCtx(); });
    $$("[data-shape]", this.ctx).forEach(b => b.onclick = () => { this.shapeKind = b.dataset.shape; this.renderCtx(); });
    $(".ed-fill", this.ctx)?.addEventListener("input", e => { this.shapeFill = e.target.value; this.applyToSelection({ fill: this.shapeFill }); });
    $(".ed-font", this.ctx)?.addEventListener("change", e => this.setTextStyle({ fontFamily: e.target.value }));
    $(".ed-size", this.ctx)?.addEventListener("change", e => this.setTextStyle({ fontSize: clamp(+e.target.value, 6, 120) }));
    $(".ed-tcolor", this.ctx)?.addEventListener("input", e => this.setTextStyle({ fill: e.target.value }));
    $(".ed-lh", this.ctx)?.addEventListener("change", e => this.setTextStyle({ lineHeight: +e.target.value }));
    $(".ed-bg", this.ctx)?.addEventListener("input", e => this.setTextStyle({ bg: e.target.value }));
    $(".ed-topacity", this.ctx)?.addEventListener("input", e => this.setTextStyle({ opacity: +e.target.value }));
    $$("[data-fmt]", this.ctx).forEach(b => b.onclick = () => this.toggleFmt(b.dataset.fmt));
    $$("[data-align]", this.ctx).forEach(b => b.onclick = () => this.setTextStyle({ align: b.dataset.align }));
    $$("[data-act]", this.ctx).forEach(b => b.onclick = () => this.action(b.dataset.act, b));
    this.updateToolButtons(); this.onToolState?.(this.toolState());
  }
  selText() { const s = this.selection.find(x => x.node.getAttr("obj").type === "text"); return s ? s.node.getAttr("obj") : null; }

  // ---------------------------------------------------------------- Seiten aufbauen
  buildPages() {
    this.pagesEl.innerHTML = ""; this.pages = [];
    this.model.pageOrder.forEach((p, i) => {
      const size = p.type === "pdf" ? this.pageSizes[p.index - 1] : { w: p.w || 595, h: p.h || 842 };
      const rot = p.rotation || 0; const sw = rot % 180 ? size.h : size.w, sh = rot % 180 ? size.w : size.h;
      const el = document.createElement("div"); el.className = "ed-page" + (p.type === "blank" ? " blank" : ""); el.dataset.i = i;
      el.innerHTML = `<canvas class="ed-pdf"></canvas><div class="ed-stage"></div><canvas class="ed-live"></canvas><canvas class="ed-predict"></canvas><div class="ed-pagelabel">${i + 1}</div>`;
      const pv = this._prev.get(this.prevKey(p)); if (pv) this.setPreview(el, pv);
      this.pagesEl.append(el);
      this.pages.push({ ...p, w: sw, h: sh, baseW: size.w, baseH: size.h, el, mounted: false, stage: null, layer: null, renderTask: null });
    });
    this.applyZoomSizes(); this.setPad();
    $(".ed-pagecount", this.c).textContent = this.pages.length;
    this.io?.disconnect(); this.ioFar?.disconnect();
    // aufbauen kurz vor dem Sichtbereich, abbauen erst weit davon entfernt (kein Neuaufbau beim Hin- und Herscrollen)
    this.io = new IntersectionObserver(entries => entries.forEach(en => { const pg = this.pages[+en.target.dataset.i]; if (!pg) return; pg.near = en.isIntersecting; if (en.isIntersecting) this.mountSoon(pg); }), { root: this.scroll, rootMargin: "300px 300px" });
    this.ioFar = new IntersectionObserver(entries => entries.forEach(en => { const pg = this.pages[+en.target.dataset.i]; if (pg && !en.isIntersecting) this.unmount(pg); }), { root: this.scroll, rootMargin: "100% 100%" });
    this.pages.forEach(p => { this.io.observe(p.el); this.ioFar.observe(p.el); });
    this.pages.slice(0, 2).forEach(p => this.mount(p));
    requestAnimationFrame(() => this.clampView());
    if (this.prefs.single) this.showSingle();
  }
  applyZoomSizes(now = false) { this.pages.forEach(p => { p.el.style.width = p.w * this.zoom + "px"; p.el.style.height = p.h * this.zoom + "px"; if (p.stage && p.stageZoom) { p.stage.content.style.transformOrigin = "0 0"; p.stage.content.style.transform = `scale(${this.zoom / p.stageZoom})`; } }); this._zoomPending = true; clearTimeout(this._zc); if (now) this.flushZoom(); else this._zc = setTimeout(() => this.flushZoom(), 220); }
  flushZoom() { clearTimeout(this._zc); if (!this._zoomPending) return; this._zoomPending = false; if (this._livePg) this.releaseLiveCanvases(this._livePg); this.pages.forEach(p => { if (!p.stage) return; if (p.stageZoom !== this.zoom) { this.sizeStage(p); p.stage.batchDraw(); } if (p.mounted && p.renderedZoom !== this.zoom) this.renderPdf(p); }); }
  sizeStage(p) { if (!p.stage) return; const r = pageDpr(p, this.zoom), lr = p.inked ? r : Math.min(r, 0.2); p.stage.content.style.transform = ""; if (p.layerPR !== lr) { p.layer.getCanvas().setPixelRatio(lr); p.tmp.getCanvas().setPixelRatio(Math.min(1, r)); p.layerPR = lr; } if (!p.hitPR) { try { p.layer.hitCanvas.setPixelRatio(0.75); p.tmp.hitCanvas.setPixelRatio(0.5); } catch {} p.hitPR = 1; } p.stage.size({ width: p.w * this.zoom, height: p.h * this.zoom }); p.stage.scale({ x: this.zoom, y: this.zoom }); p.stageZoom = this.zoom; }
  releaseLiveCanvases(pg) { $$(".ed-live, .ed-predict", pg.el).forEach(c => { c.width = 0; c.height = 0; }); if (this._livePg === pg) this._livePg = null; }
  cancelLiveStroke(type) { const a = this._activeLive; if (!a || (type && a.type !== type)) return; a.cancel(); }
  setPad() { const W = this.scroll.clientWidth, H = this.scroll.clientHeight; if (!W || !H) return; const px = Math.round(W * 0.6), py = Math.round(H * 0.6); const dx = px - (this._padX || 0), dy = py - (this._padY || 0); if (!dx && !dy) return; this.pagesEl.style.padding = `${py}px ${px}px`; this._padX = px; this._padY = py; this.scroll.scrollLeft += dx; this.scroll.scrollTop += dy; }
  viewBounds() { const W = this.scroll.clientWidth, H = this.scroll.clientHeight; let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const pg of this.pages) { const e = pg.el; if (!e.offsetParent) continue; x0 = Math.min(x0, e.offsetLeft); y0 = Math.min(y0, e.offsetTop); x1 = Math.max(x1, e.offsetLeft + e.offsetWidth); y1 = Math.max(y1, e.offsetTop + e.offsetHeight); } if (x0 === Infinity) return null; const ax = (lo, hi, V, m) => hi - lo + 2 * m <= V ? [(lo + hi) / 2 - V / 2, (lo + hi) / 2 - V / 2] : [lo - m, hi - V + m]; const [l0, l1] = ax(x0, x1, W, 12); const [t0, t1] = ax(y0, y1, H, 10); return { l0, l1, t0, t1 }; }
  clampView(smooth = false) { const b = this.viewBounds(); if (!b) return; const sl = clamp(this.scroll.scrollLeft, b.l0, b.l1), st = clamp(this.scroll.scrollTop, b.t0, b.t1); if (Math.abs(sl - this.scroll.scrollLeft) < 0.5 && Math.abs(st - this.scroll.scrollTop) < 0.5) return; if (!smooth) { this.scroll.scrollLeft = sl; this.scroll.scrollTop = st; return; } const fl = this.scroll.scrollLeft, ft = this.scroll.scrollTop, t0 = performance.now(), anim = {}; this._clampAnim = anim; const step = () => { if (this._clampAnim !== anim) return; const k = Math.min(1, (performance.now() - t0) / 200), e = 1 - Math.pow(1 - k, 3); this.scroll.scrollLeft = fl + (sl - fl) * e; this.scroll.scrollTop = ft + (st - ft) * e; if (k < 1) requestAnimationFrame(step); else this._clampAnim = null; }; requestAnimationFrame(step); }
  showSingle() { this.pages.forEach((p, i) => p.el.style.display = (!this.prefs.single || i === this.currentPage) ? "" : "none"); if (this.prefs.single) this.mount(this.pages[this.currentPage]); }
  // waehrend schnellem Wischen keine Seiten aufbauen (Konva und Canvas kosten auf dem iPad Millisekunden je Seite)
  mountSoon(pg) {
    if (!this.renderShouldWait(true)) { this.mount(pg); return; }
    (this._pendMount ||= new Set()).add(pg); clearTimeout(this._pendT); this._pendT = setTimeout(() => this.flushMounts(), 120);
  }
  flushMounts(force = false) {
    clearTimeout(this._pendT); const set = this._pendMount; if (!set?.size || this.destroyed) return;
    if (!force && this.renderShouldWait(true)) { this._pendT = setTimeout(() => this.flushMounts(), 120); return; }
    this._pendMount = null; set.forEach(pg => { if (pg.near && this.pages[+pg.el.dataset.i] === pg) this.mount(pg); });
  }
  async mount(pg) {
    if (pg.mounted || this.destroyed) return; pg.mounted = true; pg.inked = (this.model.pages[pg.key]?.objects?.length || 0) > 0;
    this.renderPdf(pg);
    const stage = new Konva.Stage({ container: $(".ed-stage", pg.el), width: 1, height: 1 });   // Groesse setzt sizeStage
    stage.scale({ x: this.zoom, y: this.zoom });
    const layer = new Konva.Layer(); const tmp = new Konva.Layer({ listening: false }); stage.add(layer, tmp);
    pg.stage = stage; pg.layer = layer; pg.tmp = tmp; layer.listening(this.tool === "lasso"); this.sizeStage(pg);
    pg.tr = new Konva.Transformer({ rotateEnabled: true, keepRatio: false, padding: 4, anchorSize: 9, borderStroke: "#4f5bd5", anchorStroke: "#4f5bd5", enabledAnchors: ["top-left", "top-right", "bottom-left", "bottom-right", "middle-left", "middle-right", "top-center", "bottom-center"] });
    layer.add(pg.tr);
    // Ebene fuer projizierte Loesungen anderer: ueber der PDF, unter den eigenen Notizen, ohne Eingabe
    pg.foreign = new Konva.Layer({ listening: false }); stage.add(pg.foreign); pg.foreign.moveToBottom();
    this.model.pages[pg.key].objects.forEach(o => this.addNode(pg, o));
    layer.batchDraw(); this.bindStage(pg);
    this.community?.mountPage(pg);
    if (this.ruler && this.pages[this.currentPage] === pg) this.showRuler(pg);
  }
  updateToolButtons() { const act = this.tool === "pen" && this.penType === "marker" ? "marker" : this.tool; $$("[data-tool]", this.c).forEach(b => b.classList.toggle("active", b.dataset.tool === act)); }
  toolState() { return { tool: this.tool, penType: this.penType, color: this.color, width: this.width, opacity: this.opacity, eraserMode: this.eraserMode, eraserSize: this.eraserSize, shapeKind: this.shapeKind }; }
  applyToolState(st) { if (!st) return; Object.assign(this, { penType: st.penType, color: st.color, width: st.width, opacity: st.opacity, eraserMode: st.eraserMode, eraserSize: st.eraserSize, shapeKind: st.shapeKind }); this._penCustom = true; if (this.tool !== st.tool) this.setTool(st.tool); else this.renderCtx(); }
  saveEraser() { try { localStorage.setItem("ed-eraser", JSON.stringify({ size: this.eraserSize, mode: this.eraserMode })); } catch {} }
  updatePenInputBtn() { const b = $(".ed-peninput", this.c); if (!b) return; const po = this.penInput === "pen_only"; b.innerHTML = po ? `${icon("pen", 16)}<span class="ed-pi">Stift</span>` : `${icon("hand", 16)}<span class="ed-pi">Finger</span>`; b.classList.toggle("active", po); b.title = po ? "Nur der Stift schreibt, Finger scrollt und zoomt (tippen zum Umschalten)" : "Finger und Stift schreiben (tippen für „Nur Stift“)"; }
  unmount(pg) { this._pendMount?.delete(pg); if (!pg.mounted) return; pg.mounted = false; if (pg._rq) { renderQ.wait.delete(pg._rq); pg._rq = null; } pg.layerPR = pg.hitPR = pg.stageZoom = undefined; if (this._livePg === pg) this._livePg = null; const lv = $(".ed-live", pg.el); if (lv) { lv.width = 0; lv.height = 0; } const pv = $(".ed-predict", pg.el); if (pv) { pv.width = 0; pv.height = 0; } pg.renderTask?.cancel?.(); pg.renderTask = null; if (pg.stage) { pg.stage.destroy(); pg.stage = null; pg.layer = null; pg.foreign = null; } const cv = $(".ed-pdf", pg.el); cv.width = cv.height = 0; this.selection = this.selection.filter(s => s.pg !== pg); }
  // Vorlagenseiten sofort, PDF-Seiten ueber die gemeinsame Warteschlange
  renderPdf(pg) {
    if (pg.type !== "pdf" && pg.type !== "asset") { this.renderTemplate($(".ed-pdf", pg.el), pg, pageDpr(pg, this.zoom)); return; }
    if (pg._rq) return; pg._rq = { ed: this, pg }; renderQ.wait.add(pg._rq); pumpRender();
  }
  async renderPdfNow(pg) {
    let doc = this.pdf;
    if (pg.type === "asset") doc = await this.assetDoc(pg.assetUrl);
    if (!doc || !pg.mounted || this.destroyed) return;
    const page = await doc.getPage(pg.index);
    if (!pg.mounted || this.destroyed) return;
    pg.renderTask?.cancel?.();
    const zoom = this.zoom, vp = page.getViewport({ scale: zoom * pageDpr(pg, zoom), rotation: ((page.rotate || 0) + (pg.rotation || 0)) % 360 });
    // in eine neue Canvas rendern und fertig einsetzen: bis dahin bleibt die alte Darstellung bzw. die Vorschau stehen
    const off = document.createElement("canvas"); off.className = "ed-pdf"; off.width = vp.width; off.height = vp.height; off.style.width = "100%"; off.style.height = "100%";
    const task = page.render({ canvasContext: off.getContext("2d"), viewport: vp }); pg.renderTask = task;
    task.onContinue = next => this.paceRender(next);
    try { await task.promise; } catch { off.width = off.height = 0; return; }
    if (!pg.mounted || pg.renderTask !== task) { off.width = off.height = 0; return; }
    pg.renderTask = null;
    const cv = $(".ed-pdf", pg.el); if (cv) { cv.replaceWith(off); cv.width = cv.height = 0; } else pg.el.prepend(off);
    pg.renderedZoom = zoom; this.savePreview(pg, off);
    if (zoom !== this.zoom) this.renderPdf(pg);          // waehrenddessen gezoomt
  }
  // pdf.js meldet sich nach jedem Happen: waehrend Wischen, Zoomen und Schreiben kurz warten (je Happen hoechstens 1,5 s)
  paceRender(next, since = performance.now()) { if (!this.destroyed && this.renderShouldWait() && performance.now() - since < 1500) { setTimeout(() => this.paceRender(next, since), 50); return; } next(); }
  renderShouldWait(scrollOnly = false) { const moving = !!this._fling || performance.now() - (this._scrollFastAt || 0) < 120; return scrollOnly ? moving : moving || !!this.pinch || document.documentElement.classList.contains("ed-inking"); }
  pageDistance(pg) { const s = this.scroll, e = pg.el, hz = this.prefs.scroll === "horizontal"; const V = Math.max(1, hz ? s.clientWidth : s.clientHeight), c = (hz ? s.scrollLeft : s.scrollTop) + V / 2, a = hz ? e.offsetLeft : e.offsetTop, b = a + (hz ? e.offsetWidth : e.offsetHeight); return (c < a ? a - c : c > b ? c - b : 0) / V; }
  // kleine JPEG-Vorschau je Seite: beim Zurueckscrollen sofort sichtbar, bis die scharfe Darstellung fertig ist
  prevKey(p) { return `${p.key}:${p.rotation || 0}`; }
  setPreview(el, url) { el.style.background = `#fff url("${url}") 0 0 / 100% 100% no-repeat`; }
  savePreview(pg, src) {
    const k = this.prevKey(pg); if (this._prev.has(k) || !src.width) return; this._prev.set(k, "");
    const c = document.createElement("canvas"), s = Math.min(1, 360 / src.width); c.width = Math.max(1, Math.round(src.width * s)); c.height = Math.max(1, Math.round(src.height * s));
    c.getContext("2d").drawImage(src, 0, 0, c.width, c.height);
    c.toBlob(b => { c.width = c.height = 0; if (!b || this.destroyed) { this._prev.delete(k); return; } const u = URL.createObjectURL(b); this._prev.set(k, u); const p = this.pages.find(x => this.prevKey(x) === k); if (p) this.setPreview(p.el, u); }, "image/jpeg", 0.7);
  }
  renderTemplate(cv, pg, dpr) {
    const W = Math.round(pg.w * this.zoom * dpr), H = Math.round(pg.h * this.zoom * dpr); cv.width = W; cv.height = H; cv.style.width = "100%"; cv.style.height = "100%";
    const ctx = cv.getContext("2d"); const s = this.zoom * dpr; ctx.fillStyle = pg.template === "cornell" ? "#fffdf7" : "#ffffff"; ctx.fillRect(0, 0, W, H);
    const t = pg.template || "blank"; ctx.strokeStyle = "#d9dde8"; ctx.lineWidth = Math.max(1, s * 0.6);
    const step = (t === "mm" ? 2.835 : t === "grid" || t === "dotted" ? 14.17 : 24) * s;
    if (t === "lined" || t === "cornell") { for (let y = 60 * s; y < H; y += step) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke(); } }
    if (t === "grid" || t === "mm") { for (let x = 0; x < W; x += step) { ctx.lineWidth = t === "mm" && Math.round(x / step) % 10 === 0 ? s * 1.2 : s * 0.5; ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke(); } for (let y = 0; y < H; y += step) { ctx.lineWidth = t === "mm" && Math.round(y / step) % 10 === 0 ? s * 1.2 : s * 0.5; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke(); } }
    if (t === "dotted") { ctx.fillStyle = "#c9ced9"; for (let x = step; x < W; x += step) for (let y = step; y < H; y += step) { ctx.beginPath(); ctx.arc(x, y, s * 0.9, 0, Math.PI * 2); ctx.fill(); } }
    if (t === "cornell") { ctx.strokeStyle = "#b9c2d6"; ctx.lineWidth = s * 1.4; ctx.beginPath(); ctx.moveTo(150 * s, 0); ctx.lineTo(150 * s, H - 150 * s); ctx.stroke(); ctx.beginPath(); ctx.moveTo(0, H - 150 * s); ctx.lineTo(W, H - 150 * s); ctx.stroke(); ctx.fillStyle = "#9aa0ae"; ctx.font = `${11 * s}px sans-serif`; ctx.fillText("Stichworte", 12 * s, 22 * s); ctx.fillText("Notizen", 162 * s, 22 * s); ctx.fillText("Zusammenfassung", 12 * s, H - 128 * s); }
    pg.renderedZoom = this.zoom;
  }
  async assetDoc(url) { if (this.assetDocs.has(url)) return this.assetDocs.get(url); const buf = await (await fetch(url)).arrayBuffer(); const doc = await pdfjsLib.getDocument({ data: buf }).promise; this.assetDocs.set(url, doc); return doc; }

  // ---------------------------------------------------------------- Objekte -> Konva
  addNode(pg, o) {
    const node = this.makeNode(pg, o);
    if (!node) return null;
    node.setAttr("obj", o);
    if (!pg.inked) { pg.inked = true; if (pg.stage && pg.layerPR !== undefined) { const r = pageDpr(pg, this.zoom); pg.layer.getCanvas().setPixelRatio(r); pg.layerPR = r; } }
    pg.layer.add(node); pg.tr.moveToTop();
    node.on("dragend transformend", () => this.syncNode(pg, node));
    return node;
  }
  // foreign: {image(src) -> URL oder null} fuer fremde Loesungen und Vorschauen (nicht bearbeitbar)
  makeNode(pg, o, foreign = null) {
    let node;
    const common = { id: o.id, name: "obj", x: o.x || 0, y: o.y || 0, rotation: o.rotation || 0, scaleX: o.scaleX || 1, scaleY: o.scaleY || 1, opacity: o.opacity ?? 1, draggable: false };
    if (o.type === "stroke" && o.tool !== "marker" && o.points && o.points.length >= 4) {
      node = this.makeInkShape(common, o);
    } else if (o.type === "stroke") {
      node = new Konva.Line({ ...common, points: o.points, stroke: o.color, strokeWidth: o.width, lineCap: "round", lineJoin: "round", tension: o.tool === "marker" || o.points.length >= 24 ? 0 : 0.25, hitStrokeWidth: Math.max(12, o.width), globalCompositeOperation: o.tool === "marker" ? "multiply" : "source-over", shadowForStrokeEnabled: false, perfectDrawEnabled: false });
      if (o.tool === "pencil") node.dash([1.5, 1.2]);
    } else if (o.type === "text") {
      node = new Konva.Group({ ...common });
      const txt = new Konva.Text({ name: "txt", text: o.text || "", width: o.width || 200, fontFamily: o.fontFamily, fontSize: o.fontSize, fill: o.fill, fontStyle: `${o.bold ? "bold" : ""} ${o.italic ? "italic" : ""}`.trim() || "normal", textDecoration: o.underline ? "underline" : "", align: o.align || "left", padding: 4, lineHeight: o.lineHeight || 1.25, wrap: "word" });
      const bg = new Konva.Rect({ name: "bg", width: txt.width(), height: txt.height(), fill: o.bg || undefined, cornerRadius: 3 });
      node.add(bg, txt); if (!foreign) node.on("dblclick dbltap", () => this.editText(pg, node));
    } else if (o.type === "shape") {
      const s = { ...common, stroke: o.stroke, strokeWidth: o.strokeWidth, fill: o.fill || undefined, hitStrokeWidth: 12 };
      if (o.shape === "rect") node = new Konva.Rect({ ...s, width: o.width, height: o.height });
      else if (o.shape === "ellipse") node = new Konva.Ellipse({ ...s, radiusX: o.width / 2, radiusY: o.height / 2, offsetX: -o.width / 2, offsetY: -o.height / 2 });
      else if (o.shape === "triangle") node = new Konva.Line({ ...s, points: [o.width / 2, 0, o.width, o.height, 0, o.height], closed: true });
      else if (o.shape === "polygon") node = new Konva.Line({ ...s, points: o.points, closed: true });
      else if (o.shape === "arrow") node = new Konva.Arrow({ ...s, points: o.points, pointerLength: Math.max(8, o.strokeWidth * 3), pointerWidth: Math.max(8, o.strokeWidth * 3), fill: o.stroke });
      else node = new Konva.Line({ ...s, points: o.points });
    } else if (o.type === "image") {
      node = new Konva.Image({ ...common, width: o.width, height: o.height });
      const src = foreign ? foreign.image(o.src) : o.src; if (!src) return null;
      const img = new Image(); img.onload = () => { if (o.crop) node.crop(o.crop); node.image(img); (node.getLayer() || pg.layer)?.batchDraw(); }; img.src = src;
    }
    if (node && foreign) { node.listening(false); node.name("foreign-obj"); }
    return node || null;
  }
  syncNode(pg, node) {
    const o = node.getAttr("obj"); const before = this.snapshot(pg);
    o.x = node.x(); o.y = node.y(); o.rotation = node.rotation(); o.scaleX = node.scaleX(); o.scaleY = node.scaleY();
    if (o.type === "text") { const txt = node.findOne(".txt"); const bg = node.findOne(".bg"); if (Math.abs(node.scaleX() - 1) > 0.001) { o.width = Math.max(40, txt.width() * node.scaleX()); txt.width(o.width); node.scaleX(1); o.scaleX = 1; } if (Math.abs(node.scaleY() - 1) > 0.001) { o.fontSize = clamp(Math.round(txt.fontSize() * node.scaleY() * 10) / 10, 6, 200); txt.fontSize(o.fontSize); node.scaleY(1); o.scaleY = 1; } bg.size({ width: txt.width(), height: txt.height() }); }
    this.commit(pg, before);
  }
  makeInkShape(common, o) {
    const pts = o.points; const ws = o.widths && o.widths.length * 2 === pts.length ? o.widths : null; const W = o.width || 2;
    const maxW = ws ? Math.max(...ws, 0.5) : W; const avgW = ws ? ws.reduce((x, y) => x + y, 0) / ws.length : W;
    const single = !ws || (o.opacity ?? 1) < 1;   // halbtransparent: ein Pfad, sonst ueberlagern sich Segmente zu Punkten
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity; for (let i = 0; i < pts.length; i += 2) { if (pts[i] < minX) minX = pts[i]; if (pts[i] > maxX) maxX = pts[i]; if (pts[i + 1] < minY) minY = pts[i + 1]; if (pts[i + 1] > maxY) maxY = pts[i + 1]; }
    const node = new Konva.Shape({ ...common, stroke: o.color, strokeWidth: maxW, hitStrokeWidth: Math.max(12, maxW), perfectDrawEnabled: false, shadowForStrokeEnabled: false,
      sceneFunc: (ctx) => { const c = ctx._context; c.save(); c.strokeStyle = o.color; c.lineCap = "round"; c.lineJoin = "round"; if (o.tool === "pencil") c.setLineDash([1.5, 1.2]); const n = pts.length / 2;
        if (n === 1) { c.beginPath(); c.arc(pts[0], pts[1], (ws ? ws[0] : W) / 2, 0, Math.PI * 2); c.fillStyle = o.color; c.fill(); c.restore(); return; }
        if (single) { c.lineWidth = Math.max(0.3, avgW); c.beginPath(); c.moveTo(pts[0], pts[1]); for (let i = 1; i < n - 1; i++) c.quadraticCurveTo(pts[2 * i], pts[2 * i + 1], (pts[2 * i] + pts[2 * i + 2]) / 2, (pts[2 * i + 1] + pts[2 * i + 3]) / 2); c.lineTo(pts[2 * n - 2], pts[2 * n - 1]); c.stroke(); c.restore(); return; }
        for (let i = 1; i < n; i++) { const x0 = pts[2 * i - 2], y0 = pts[2 * i - 1], x1 = pts[2 * i], y1 = pts[2 * i + 1]; c.lineWidth = Math.max(0.3, (ws[i - 1] + ws[i]) / 2); c.beginPath();
          if (i === 1) c.moveTo(x0, y0); else c.moveTo((x0 + pts[2 * i - 4]) / 2, (y0 + pts[2 * i - 3]) / 2);
          if (i === n - 1) c.lineTo(x1, y1); else c.quadraticCurveTo(x0, y0, (x0 + x1) / 2, (y0 + y1) / 2);
          c.stroke(); }
        c.restore(); },
      hitFunc: (ctx, shape) => { ctx.beginPath(); ctx.moveTo(pts[0], pts[1]); for (let i = 2; i < pts.length; i += 2) ctx.lineTo(pts[i], pts[i + 1]); ctx.strokeShape(shape); } });
    node.points = () => pts;
    node.getSelfRect = () => ({ x: minX - maxW / 2, y: minY - maxW / 2, width: maxX - minX + maxW, height: maxY - minY + maxW });
    return node;
  }
  refreshNode(pg, node) { const o = node.getAttr("obj"); node.destroy(); const n = this.addNode(pg, o); pg.layer.batchDraw(); return n; }

  // ---------------------------------------------------------------- Historie & Speichern
  snapshot(pg) { return JSON.stringify(this.model.pages[pg.key].objects); }
  commit(pg, before) { const after = this.snapshot(pg); if (before === after) return; this.history.push({ key: pg.key, before, after }); if (this.history.length > 150) this.history.shift(); this.future = []; this.markDirty(); }
  commitPages(before) { const after = JSON.stringify({ o: this.model.pageOrder, p: Object.keys(this.model.pages), d: this.model.deletedPages }); this.history.push({ pages: true, before, after, snapPages: JSON.parse(JSON.stringify(this.model.pages)) }); this.future = []; this.markDirty(); }
  pagesSnap() { return JSON.stringify({ o: this.model.pageOrder, p: Object.keys(this.model.pages), d: this.model.deletedPages }); }
  undo() { const h = this.history.pop(); if (!h) return; this.future.push(h); if (h.addJson) return this.unAdd(h); h.pages ? this.restorePages(h, "before") : this.restore(h.key, h.before); }
  redo() { const h = this.future.pop(); if (!h) return; this.history.push(h); if (h.addJson) return this.reAdd(h); h.pages ? this.restorePages(h, "after") : this.restore(h.key, h.after); }
  unAdd(h) { const objs = this.model.pages[h.key]?.objects; if (!objs) return; const i = objs.findIndex(x => x.id === h.id); if (i >= 0) objs.splice(i, 1); const pg = this.pages.find(x => x.key === h.key); if (pg?.mounted) { this.clearSelection(); pg.layer.find(".obj").filter(n => n.getAttr("obj")?.id === h.id).forEach(n => n.destroy()); pg.layer.batchDraw(); } this.markDirty(); }
  reAdd(h) { const objs = this.model.pages[h.key]?.objects; if (!objs) return; const o = JSON.parse(h.addJson); objs.push(o); const pg = this.pages.find(x => x.key === h.key); if (pg?.mounted) { this.addNode(pg, o); pg.layer.batchDraw(); } this.markDirty(); }
  restore(key, json) { this.model.pages[key].objects = JSON.parse(json); const pg = this.pages.find(p => p.key === key); if (pg?.mounted) { this.clearSelection(); pg.layer.find(".obj").forEach(n => n.destroy()); this.model.pages[key].objects.forEach(o => this.addNode(pg, o)); pg.layer.batchDraw(); } this.markDirty(); }
  restorePages(h, which) { const snap = JSON.parse(h[which]); const cur = this.model.pageOrder.map(p => p.key); this.model.pageOrder = snap.o; this.model.deletedPages = snap.d || []; snap.o.forEach(p => { if (!this.model.pages[p.key]) this.model.pages[p.key] = (h.snapPages && h.snapPages[p.key]) || { objects: [] }; }); this.rebuildPages(); this.markDirty(); }
  markDirty() { this.dirty = true; this.setSaveState("saving"); this.scheduleSave(); this._draftSoon(); }
  // Lokaler Entwurf unabhaengig vom Hochladen: spaetestens 1,5 s nach einer Aenderung (zwischen zwei Strichen),
  // damit ein Safari-Absturz beim Dauerschreiben nichts verliert
  _draftSoon() { if (!this._draftT) this._draftT = setTimeout(() => this._writeDraft(), 1500); }
  _writeDraft(force = false) { if (!force && (this.penDown || this._activeLive) && !this.destroyed) { this._draftT = setTimeout(() => this._writeDraft(), 300); return; } clearTimeout(this._draftT); this._draftT = 0; if (!this.dirty || !this.model) return; try { const dd = this.diffFromBase(); IDB.put("drafts", { fileId: this.fileId, data: this.model, version: this.version, dirty: true, savedAt: Date.now(), dirtyKeys: dd.keys, struct: dd.struct, meta: dd.meta, basePages: Object.fromEntries(dd.keys.map(k => [k, this.base?.pages?.[k] ?? null])) }); } catch {} }
  setSaveState(st) { const el = $(".ed-status", this.c); if (el) el.dataset.state = st; this.onStatus(st === "saving" ? "Speichert…" : st === "offline" ? "Offline – wird nachgeholt" : "Gespeichert"); }
  scheduleSave() { clearTimeout(this._t); if (!this._dirtySince) this._dirtySince = Date.now(); this._t = setTimeout(() => this._saveTick(), 1200); }
  _saveTick() { const busy = (this.penDown && Date.now() - (this.penSeenAt || 0) < 15000) || (this._activeLive && Date.now() - (this._liveAt || 0) < 15000); const waited = Date.now() - (this._dirtySince || Date.now()); if (busy || (Date.now() - (this.penLiftAt || 0) < 900 && waited < 20000)) { this._t = setTimeout(() => this._saveTick(), 400); return; } this._dirtySince = 0; const dd = this.diffFromBase(); IDB.put("drafts", { fileId: this.fileId, data: this.model, version: this.version, dirty: true, savedAt: Date.now(), dirtyKeys: dd.keys, struct: dd.struct, meta: dd.meta, basePages: Object.fromEntries(dd.keys.map(k => [k, this.base?.pages?.[k] ?? null])) }); this.flush(); }
  async flush() {
    if (this.readOnly || !this.dirty || this.saving) return; this.saving = true;
    let retryConflict = false;
    try {
      const sentJson = JSON.stringify(this.model);
      const r = await fetch(`/api/files/${this.fileId}/annotations?base_version=${this.version}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: sentJson });
      if (r.status === 409) {
        const srv = await r.json();
        this._conflicts = (this._conflicts || 0) + 1;
        if (this._conflicts > 3) throw new Error("Konflikt nicht auflösbar");
        this.applyServerMerge(srv.data, srv.version); retryConflict = true; return;
      }
      if (!r.ok) throw new Error(r.statusText);
      const j = await r.json(); this.version = j.version; this._conflicts = 0;
      this.base = this.snap(JSON.parse(sentJson));
      const changedMeanwhile = JSON.stringify(this.model) !== sentJson;   // waehrend des Sendens weitergeschrieben?
      this.dirty = changedMeanwhile;
      if (changedMeanwhile) { this.scheduleSave(); this.setSaveState("saving"); }
      else { IDB.put("drafts", { fileId: this.fileId, data: this.model, version: this.version, dirty: false, savedAt: Date.now() }); this.setSaveState("saved"); }
      IDB.del("thumbs", this.fileId + ":" + (this.pages[0]?.key || ""));
      this.offline = false;
    } catch (e) { this.offline = true; this.setSaveState("offline"); setTimeout(() => this.flush(), 15000); }
    finally { this.saving = false; if (retryConflict) this.flush(); }
  }

  // ---------------------------------------------------------------- Werkzeuge
  setTool(t, fromBar = false) {
    if (t === "shape:") t = "shape";
    if (t === "marker") { if (this.penType !== "marker") { this._lastPen = this.penType; this._penCustom = false; } this.penType = "marker"; t = "pen"; }
    else if (t === "pen" && fromBar && this.penType === "marker") { this.penType = this._lastPen || "pen"; this._penCustom = false; }
    this.tool = t; this.clearSelection();
    this.updateToolButtons();
    if (t === "pen") { const d = PEN_DEFAULTS[this.penType]; if (!this._penCustom) { this.width = d.width; this.opacity = d.opacity ?? 1; } }
    if (t === "shape") { this.opacity = 1; }
    this.scroll.dataset.tool = t; this.renderCtx();
    this.pages.forEach(pg => { if (pg.layer) { const on = t === "lasso"; if (pg.layer.listening() !== on) { pg.layer.listening(on); if (on) pg.layer.batchDraw(); } pg.layer.find(".obj").forEach(n => n.draggable(on)); } });
    this.polyPts = null;
  }
  setTextStyle(patch) { Object.assign(this.textStyle, patch); const sel = this.selection.filter(s => s.node.getAttr("obj").type === "text"); if (sel.length) { const pg = sel[0].pg; const before = this.snapshot(pg); sel.forEach(s => { Object.assign(s.node.getAttr("obj"), patch); const n = this.refreshNode(pg, s.node); s.node = n; n.draggable(true); }); pg.tr.nodes(sel.map(s => s.node)); this.commit(pg, before); } this.renderCtx(); }
  toggleFmt(k) { const st = this.selText() || this.textStyle; this.setTextStyle({ [k]: !st[k] }); }
  applyToSelection(patch) { if (!this.selection.length) return; const pg = this.selection[0].pg; const before = this.snapshot(pg); this.selection.forEach(s => { const o = s.node.getAttr("obj"); if (o.type === "stroke") { if (patch.color) o.color = patch.color; if (patch.width) { if (o.widths && o.width) o.widths = o.widths.map(w => Math.round(w * patch.width / o.width * 100) / 100); o.width = patch.width; } if (patch.opacity != null) o.opacity = patch.opacity; } else if (o.type === "shape") { if (patch.stroke) o.stroke = patch.stroke; if (patch.strokeWidth) o.strokeWidth = patch.strokeWidth; if (patch.opacity != null) o.opacity = patch.opacity; if ("fill" in patch) o.fill = patch.fill; } else if (patch.opacity != null) o.opacity = patch.opacity; s.node = this.refreshNode(pg, s.node); s.node.draggable(true); }); pg.tr.nodes(this.selection.map(s => s.node)); this.commit(pg, before); }
  allowPointer(ev) { if (this.readOnly) return false; if (ev.pointerType === "touch") { if (this.penInput === "pen_only" || this.penDown) return false; if (Date.now() - this.penSeenAt < 1200 || this.pointers.size > 1) return false; } if (ev.button !== 0 && ev.pointerType === "mouse") return false; return true; }

  // Gemeinsame Strich-API (Stage + Zoom-Fenster)
  liveCtx(pg, cls = ".ed-live") { const cv = $(cls, pg.el); const dpr = pageDpr(pg, this.zoom); const W = Math.round(pg.w * this.zoom * dpr), H = Math.round(pg.h * this.zoom * dpr); if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; } const ctx = cv.getContext("2d"); ctx.setTransform(this.zoom * dpr, 0, 0, this.zoom * dpr, 0, 0); return { cv, ctx, dpr }; }
  clearLive(d) { try { this.liveClear(d); if (d.pctx && d.pcv) { d.pctx.save(); d.pctx.setTransform(1, 0, 0, 1, 0, 0); d.pctx.clearRect(0, 0, d.pcv.width, d.pcv.height); d.pctx.restore(); } d.pred = null; } catch {} }
  strokeAbort(d) { this.clearLive(d); }
  penWidth(d, pr, speed, ev) { const base = this.width, t = d.tool; if (t === "marker") return base; const sp = Math.min(1, (speed || 0) / 2.2); let w; if (t === "fountain") w = base * (0.45 + 1.1 * pr) * (1.15 - 0.5 * sp); else if (t === "pencil") { const tilt = ev ? Math.min(1, Math.hypot(ev.tiltX || 0, ev.tiltY || 0) / 60) : 0; w = base * (0.8 + 0.3 * pr + 0.9 * tilt); } else w = base * (0.9 + 0.2 * pr) * (1.03 - 0.1 * sp); /* Kugelschreiber: fast gleichmaessig */ const prev = d.widths[d.widths.length - 1]; return prev ? prev * 0.65 + w * 0.35 : w; }
  liveClear(d) { const { cv, ctx } = d; ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height); ctx.restore(); }
  widthAt(d, pr) { return d.widths?.length ? d.widths[d.widths.length - 1] : (d.tool === "fountain" ? this.width * (0.5 + pr) : this.width); }
  strokeBegin(pg, p, pressure = 0.5) { if (this.ruler && this.ruler.pg === pg) { const pr = this.rulerProject(p); if (pr) { p = pr; this._rulerStroke = true; } else this._rulerStroke = false; } const t = this.penType; if (this._livePg && this._livePg !== pg) this.releaseLiveCanvases(this._livePg); this._livePg = pg; const { cv, ctx, dpr } = this.liveCtx(pg); const d = { dpr, tool: t, pts: [p.x, p.y], pressures: [pressure], widths: [], cv, ctx, pg, t0: performance.now(), tl: performance.now(), pred: null }; d.widths.push(this.penWidth(d, pressure, 0, null)); this.liveClear(d); const pc = this.liveCtx(pg, ".ed-predict"); d.pcv = pc.cv; d.pctx = pc.ctx; pc.ctx.save(); pc.ctx.setTransform(1, 0, 0, 1, 0, 0); pc.ctx.clearRect(0, 0, pc.cv.width, pc.cv.height); pc.ctx.restore(); ctx.strokeStyle = this.color; ctx.fillStyle = this.color; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.globalAlpha = this.opacity; ctx.globalCompositeOperation = t === "marker" ? "multiply" : "source-over"; ctx.setLineDash(t === "pencil" ? [1.5, 1.2] : []); ctx.beginPath(); ctx.arc(p.x, p.y, this.widthAt(d, pressure) / 2, 0, Math.PI * 2); ctx.fill(); return d; }
  strokeMove(pg, d, p, pressure = 0.5, ev = null) { if (this._rulerStroke) { const pr = this.rulerProject(p, true); if (pr) p = pr; } const pts = d.pts; const lx = pts[pts.length - 2], ly = pts[pts.length - 1]; d.raw = p; if (!this._rulerStroke && d.tool !== "marker") p = { x: lx + (p.x - lx) * 0.6, y: ly + (p.y - ly) * 0.6 };   // Zittern glaetten
    const dist = Math.hypot(p.x - lx, p.y - ly); if (dist < 0.35 / this.zoom) return; const now = ev?.timeStamp || performance.now(); const dt = Math.max(1, now - d.tl); d.tl = now; const w = this.penWidth(d, pressure, dist / dt, ev); pts.push(p.x, p.y); d.pressures.push(pressure); d.widths.push(w); const ctx = d.ctx; const n = pts.length; if (this.opacity < 1) { this.liveClear(d); ctx.lineWidth = Math.max(0.3, d.widths.reduce((a, b) => a + b, 0) / d.widths.length); ctx.beginPath(); ctx.moveTo(pts[0], pts[1]); for (let i = 2; i < n - 2; i += 2) ctx.quadraticCurveTo(pts[i], pts[i + 1], (pts[i] + pts[i + 2]) / 2, (pts[i + 1] + pts[i + 3]) / 2); ctx.lineTo(pts[n - 2], pts[n - 1]); ctx.stroke(); return; } ctx.lineWidth = Math.max(0.3, (d.widths[d.widths.length - 2] + w) / 2); ctx.beginPath(); if (n >= 6) { const [x0, y0, x1, y1, x2, y2] = pts.slice(-6); ctx.moveTo((x0 + x1) / 2, (y0 + y1) / 2); ctx.quadraticCurveTo(x1, y1, (x1 + x2) / 2, (y1 + y2) / 2); } else { ctx.moveTo(pts[0], pts[1]); ctx.lineTo((pts[0] + pts[2]) / 2, (pts[1] + pts[3]) / 2); } ctx.stroke(); }
  strokePredict(d, preds) { const c = d.pctx; if (!c) return; const k = this.zoom * (d.dpr || DPR()); if (d.pred) { c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.clearRect(d.pred.x * k - 8, d.pred.y * k - 8, d.pred.w * k + 16, d.pred.h * k + 16); c.restore(); d.pred = null; } const pts = d.pts, n = pts.length; if (n < 4 || this.opacity < 1) return; const lx = pts[n - 2], ly = pts[n - 1]; const mx = (pts[n - 4] + lx) / 2, my = (pts[n - 3] + ly) / 2; let minX = Math.min(mx, lx), minY = Math.min(my, ly), maxX = Math.max(mx, lx), maxY = Math.max(my, ly); c.strokeStyle = this.color; c.globalAlpha = this.opacity; c.lineCap = "round"; c.lineJoin = "round"; c.setLineDash([]); c.lineWidth = Math.max(0.3, d.widths[d.widths.length - 1] || this.width); c.beginPath(); c.moveTo(mx, my); c.lineTo(lx, ly); for (const q of preds) { c.lineTo(q.x, q.y); minX = Math.min(minX, q.x); minY = Math.min(minY, q.y); maxX = Math.max(maxX, q.x); maxY = Math.max(maxY, q.y); } c.stroke(); const pad = c.lineWidth; d.pred = { x: minX - pad, y: minY - pad, w: maxX - minX + 2 * pad, h: maxY - minY + 2 * pad }; }
  strokeEnd(pg, d) { if (d.raw && d.pts.length >= 2 && d.tool !== "marker" && !this._rulerStroke) { const n = d.pts.length; if (Math.hypot(d.raw.x - d.pts[n - 2], d.raw.y - d.pts[n - 1]) > 0.3 / this.zoom) { d.pts.push(d.raw.x, d.raw.y); d.widths.push(d.widths[d.widths.length - 1]); d.pressures.push(d.pressures[d.pressures.length - 1]); } } let pts = d.pts; let widths = d.widths.slice(); if (pts.length < 2) { this.clearLive(d); return; } if (pts.length === 2) { pts = [pts[0], pts[1], pts[0] + 0.05, pts[1] + 0.05]; widths = [widths[0], widths[0]]; } const avg = d.pressures.reduce((a, b) => a + b, 0) / d.pressures.length; const w = widths.length ? widths.reduce((a, b) => a + b, 0) / widths.length : (d.tool === "fountain" ? this.width * (0.5 + avg) : this.width); const o = { id: uid(), type: "stroke", tool: d.tool, color: this.color, width: Math.round(w * 100) / 100, opacity: this.opacity, points: pts.map(v => Math.round(v * 100) / 100), x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1 }; if (d.tool !== "marker" && widths.length * 2 === pts.length && Math.max(...widths) - Math.min(...widths) > 0.05) o.widths = widths.map(v => Math.round(v * 100) / 100); this.model.pages[pg.key].objects.push(o); const node = this.addNode(pg, o); try { node.draw(); } catch { pg.layer.batchDraw(); } this.clearLive(d); this.history.push({ key: pg.key, id: o.id, addJson: JSON.stringify(o) }); if (this.history.length > 150) this.history.shift(); this.future = []; this.markDirty(); this._lastInkAt = Date.now(); this._lastInkPage = pg.key; this.onInk?.(); this.zoomWinRefresh(); }

  bindStage(pg) {
    const st = pg.stage; let drawing = null, lasso = null, shape = null, marquee = null, tsel = null;
    // --- Stift & Radierer: direkt ueber Pointer-Events (alle Zwischenpunkte, kein Hit-Test, Capture bis zum Loslassen)
    // native Stift-Listener nur EINMAL pro Seitenelement (die Seite wird beim Scrollen mehrfach ein-/ausgeblendet)
    if (!pg._nativeInk) { pg._nativeInk = true;
      const el = pg.el; let live = null; let rect = null, rectEpoch = -1;
      const getRect = () => { if (!rect || rectEpoch !== this._scrollEpoch) { rect = el.getBoundingClientRect(); rectEpoch = this._scrollEpoch; } return rect; };
      const lpR = (ev, r) => ({ x: (ev.clientX - r.left) / this.zoom, y: (ev.clientY - r.top) / this.zoom });
      const press = ev => ev.pointerType === "pen" && ev.pressure ? ev.pressure : 0.5;
      const endLive = (keep = true) => {
        const cur = live; live = null; rect = null;
        if (this._activeLive?.pg === pg) this._activeLive = null;
        document.documentElement.classList.remove("ed-inking");
        if (!cur) return;
        try { el.releasePointerCapture(cur.id); } catch {}
        if (cur.d) { if (keep) this.strokeEnd(pg, cur.d); else this.strokeAbort(cur.d); }
        else if (cur.changed) this.commit(pg, cur.before);
      };
      el.addEventListener("pointerdown", ev => {
        if (this.tool !== "pen" && this.tool !== "eraser") return;
        if (this.spaceHand || ev.button === 1 || !this.allowPointer(ev)) return;
        if (live) endLive(!(live.type === "touch" && ev.pointerType === "pen"));   // neues Aufsetzen beendet immer den alten Strich (iPad: gleiche pointerId)
        ev.preventDefault(); ev.stopPropagation(); try { el.setPointerCapture(ev.pointerId); } catch {}
        this.flushZoom();                                   // ausstehende Zoom-Anpassung vor dem Strich abschliessen
        this.setCurrent(pg); this.onActive?.(this); rect = null; const p = lpR(ev, getRect());
        document.documentElement.classList.add("ed-inking");
        if (this.tool === "pen") live = { id: ev.pointerId, type: ev.pointerType, d: this.strokeBegin(pg, p, press(ev)) };
        else { live = { id: ev.pointerId, type: ev.pointerType, tool: "eraser", before: this.snapshot(pg), changed: false }; this.eraseAt(pg, p, live); }
        this._activeLive = { pg, type: ev.pointerType, id: ev.pointerId, cancel: () => endLive(false), finish: () => endLive(true) }; this._liveAt = Date.now();
      }, true);
      el.addEventListener("pointermove", ev => {
        if (!live || ev.pointerId !== live.id) return;
        ev.preventDefault(); ev.stopPropagation();
        const r = getRect();
        const evs = ev.getCoalescedEvents ? ev.getCoalescedEvents() : []; if (!evs.length) evs.push(ev);
        for (const e2 of evs) { const p = lpR(e2, r); if (live.d) this.strokeMove(pg, live.d, p, press(e2), e2); else this.eraseAt(pg, p, live); }
        if (live.d) this.strokePredict(live.d, ev.getPredictedEvents ? ev.getPredictedEvents().slice(0, 3).map(e2 => lpR(e2, r)) : []);
      }, true);
      const liveEnd = ev => {
        if (!live || ev.pointerId !== live.id) return;
        ev.stopPropagation();
        if (ev.type === "pointerup" && live.d) this.strokeMove(pg, live.d, lpR(ev, getRect()), press(ev), ev);
        endLive(true);
      };
      el.addEventListener("pointerup", liveEnd, true); el.addEventListener("pointercancel", liveEnd, true); el.addEventListener("lostpointercapture", liveEnd, true);
    }
    const pos = () => { const p = st.getPointerPosition(); return { x: p.x / this.zoom, y: p.y / this.zoom }; };
    st.on("pointerdown", e => {
      const ev = e.evt; this.setCurrent(pg);
      if (this.spaceHand || this.tool === "hand" || ev.button === 1) return;
      if (!this.allowPointer(ev)) return;
      if (this.tool === "pen" || this.tool === "eraser") return;   // laeuft ueber die nativen Pointer-Events oben
      if (e.target.getParent()?.className === "Transformer" || (e.target.hasName && e.target.hasName("rulerui"))) return;
      const p = pos(); const t = this.tool;
      const pr = ev.pressure && ev.pointerType === "pen" ? ev.pressure : 0.5;
      if (t === "pen") { drawing = this.strokeBegin(pg, p, pr); ev.preventDefault(); }
      else if (t === "eraser") { drawing = { tool: "eraser", before: this.snapshot(pg), changed: false }; this.eraseAt(pg, p, drawing); }
      else if (t === "lasso") { if (e.target !== st && e.target.hasName?.("obj")) return; if (e.target.getParent()?.className === "Transformer") return; if (ev.shiftKey) { marquee = { x0: p.x, y0: p.y, rect: new Konva.Rect({ x: p.x, y: p.y, stroke: "#4f5bd5", strokeWidth: 1 / this.zoom, dash: [4 / this.zoom, 3 / this.zoom], fill: "rgba(79,91,213,.06)" }) }; pg.tmp.add(marquee.rect); } else { lasso = new Konva.Line({ points: [p.x, p.y], stroke: "#4f5bd5", strokeWidth: 1 / this.zoom, dash: [6 / this.zoom, 4 / this.zoom], closed: true, fill: "rgba(79,91,213,.08)", listening: false }); pg.tmp.add(lasso); } this.clearSelection(); }
      // preventDefault: sonst holt sich die Seite nach dem pointerdown den Fokus zurueck, das Textfeld verliert ihn und
      // die naechste Taste schaltete das Werkzeug um (p = Stift)
      else if (t === "text") { if (e.target !== st) return; ev.preventDefault(); this.createText(pg, p); }
      else if (t === "sticky") { if (e.target !== st) return; ev.preventDefault(); this.createSticky(pg, p); }
      else if (t === "image") { if (e.target !== st) return; this._imgPos = p; this.action("image"); }
      else if (t === "shape") { if (this.shapeKind === "polygon") { this.polyClick(pg, p, e); return; } shape = { kind: this.shapeKind, x0: p.x, y0: p.y, node: null }; }
      else if (t === "textselect") { tsel = { x0: p.x, y0: p.y, rect: new Konva.Rect({ x: p.x, y: p.y, fill: "rgba(255,200,0,.25)", stroke: "#d98a00", strokeWidth: 1 / this.zoom, listening: false }) }; pg.tmp.add(tsel.rect); }
      pg.tmp.batchDraw();
    });
    st.on("pointermove", e => {
      const ev = e.evt; if (!drawing && !lasso && !shape && !marquee && !tsel) { if (this.polyPts && this.polyPts.pg === pg) this.polyPreview(pg, pos()); st.container().style.cursor = (this.tool === "lasso" && e.target.hasName?.("obj")) ? "move" : ""; return; }
      const p = pos();
      if (drawing?.line) this.strokeMove(pg, drawing, p, ev.pressure && ev.pointerType === "pen" ? ev.pressure : 0.5);
      else if (drawing?.tool === "eraser") this.eraseAt(pg, p, drawing);
      else if (lasso) { lasso.points([...lasso.points(), p.x, p.y]); pg.tmp.batchDraw(); }
      else if (marquee) { marquee.rect.size({ width: p.x - marquee.x0, height: p.y - marquee.y0 }); pg.tmp.batchDraw(); }
      else if (tsel) { tsel.rect.size({ width: p.x - tsel.x0, height: p.y - tsel.y0 }); pg.tmp.batchDraw(); }
      else if (shape) { if (!shape.node) { shape.node = this.makeShapeNode(shape.kind, shape.x0, shape.y0, p.x, p.y); pg.tmp.add(shape.node); } else this.updateShapeNode(shape.node, shape.kind, shape.x0, shape.y0, p.x, p.y); pg.tmp.batchDraw(); }
    });
    const finish = () => {
      if (drawing?.line) this.strokeEnd(pg, drawing);
      else if (drawing?.tool === "eraser") { if (drawing.changed) this.commit(pg, drawing.before); }
      else if (lasso) { const poly = lasso.points(); lasso.destroy(); pg.tmp.batchDraw(); if (poly.length >= 6) this.selectByPolygon(pg, poly); }
      else if (marquee) { const r = marquee.rect; const box = { x: Math.min(marquee.x0, marquee.x0 + r.width()), y: Math.min(marquee.y0, marquee.y0 + r.height()), w: Math.abs(r.width()), h: Math.abs(r.height()) }; r.destroy(); pg.tmp.batchDraw(); if (box.w > 3 && box.h > 3) this.selectByRect(pg, box); }
      else if (tsel) { const r = tsel.rect; const box = { x: Math.min(tsel.x0, tsel.x0 + r.width()), y: Math.min(tsel.y0, tsel.y0 + r.height()), w: Math.abs(r.width()), h: Math.abs(r.height()) }; r.destroy(); pg.tmp.batchDraw(); this.extractText(pg, box); }
      else if (shape?.node) { const o = shape.node.getAttr("obj"); shape.node.destroy(); pg.tmp.batchDraw(); if (o && (Math.abs(o.width || 0) > 2 || (o.points && o.points.length))) { const before = this.snapshot(pg); o.id = uid(); this.model.pages[pg.key].objects.push(o); this.addNode(pg, o); pg.layer.batchDraw(); this.commit(pg, before); } }
      drawing = lasso = shape = marquee = tsel = null;
    };
    st.on("pointerup pointercancel", finish); st.on("mouseleave", () => { if (drawing || lasso || shape || marquee || tsel) finish(); });
    st.on("click tap", e => { if (this.tool !== "lasso") return; if (e.target === st) return; let node = e.target; while (node && !(node.hasName && node.hasName("obj"))) node = node.getParent(); if (!node) return; if (e.evt.shiftKey) this.toggleSelect(pg, node); else if (!this.selection.some(s => s.node === node)) this.select(pg, [node]); });
    st.on("dblclick dbltap", () => { if (this.polyPts && this.polyPts.pg === pg) this.polyFinish(pg); });
  }
  polyClick(pg, p) { if (!this.polyPts || this.polyPts.pg !== pg) { this.polyPts = { pg, pts: [p.x, p.y], line: new Konva.Line({ points: [p.x, p.y], stroke: this.color, strokeWidth: this.width, opacity: this.opacity, closed: false, fill: this.shapeFill || undefined, listening: false }) }; pg.tmp.add(this.polyPts.line); } else { this.polyPts.pts.push(p.x, p.y); this.polyPts.line.points(this.polyPts.pts); } pg.tmp.batchDraw(); }
  polyPreview(pg, p) { this.polyPts.line.points([...this.polyPts.pts, p.x, p.y]); pg.tmp.batchDraw(); }
  polyFinish(pg) { const pp = this.polyPts; this.polyPts = null; pp.line.destroy(); pg.tmp.batchDraw(); if (pp.pts.length < 6) return; const before = this.snapshot(pg); const o = { id: uid(), type: "shape", shape: "polygon", x: 0, y: 0, points: pp.pts.map(v => Math.round(v * 100) / 100), stroke: this.color, strokeWidth: this.width, fill: this.shapeFill || "", opacity: this.opacity, rotation: 0, scaleX: 1, scaleY: 1, width: 1, height: 1 }; this.model.pages[pg.key].objects.push(o); this.addNode(pg, o); pg.layer.batchDraw(); this.commit(pg, before); }
  makeShapeNode(kind, x0, y0, x1, y1) { const o = this.shapeObj(kind, x0, y0, x1, y1); const n = this.buildShape(o); n.setAttr("obj", o); return n; }
  updateShapeNode(node, kind, x0, y0, x1, y1) { const o = this.shapeObj(kind, x0, y0, x1, y1); node.setAttr("obj", o); if (kind === "line" || kind === "arrow") node.points(o.points); else if (kind === "triangle") { node.position({ x: o.x, y: o.y }); node.points([o.width / 2, 0, o.width, o.height, 0, o.height]); } else if (kind === "ellipse") { node.position({ x: o.x, y: o.y }); node.radius({ x: o.width / 2, y: o.height / 2 }); node.offset({ x: -o.width / 2, y: -o.height / 2 }); } else { node.position({ x: o.x, y: o.y }); node.size({ width: o.width, height: o.height }); } }
  shapeObj(kind, x0, y0, x1, y1) { const base = { type: "shape", shape: kind, stroke: this.color, strokeWidth: this.width, fill: this.shapeFill || "", opacity: this.opacity, rotation: 0, scaleX: 1, scaleY: 1 }; if (kind === "line" || kind === "arrow") return { ...base, x: 0, y: 0, points: [x0, y0, x1, y1], width: Math.abs(x1 - x0) + Math.abs(y1 - y0) }; return { ...base, x: Math.min(x0, x1), y: Math.min(y0, y1), width: Math.abs(x1 - x0), height: Math.abs(y1 - y0) }; }
  buildShape(o) { const s = { stroke: o.stroke, strokeWidth: o.strokeWidth, opacity: o.opacity, fill: o.fill || undefined }; if (o.shape === "rect") return new Konva.Rect({ ...s, x: o.x, y: o.y, width: o.width, height: o.height }); if (o.shape === "ellipse") return new Konva.Ellipse({ ...s, x: o.x, y: o.y, radiusX: o.width / 2, radiusY: o.height / 2, offsetX: -o.width / 2, offsetY: -o.height / 2 }); if (o.shape === "triangle") return new Konva.Line({ ...s, x: o.x, y: o.y, points: [o.width / 2, 0, o.width, o.height, 0, o.height], closed: true }); if (o.shape === "arrow") return new Konva.Arrow({ ...s, points: o.points, fill: o.stroke, pointerLength: Math.max(8, o.strokeWidth * 3), pointerWidth: Math.max(8, o.strokeWidth * 3) }); return new Konva.Line({ ...s, points: o.points }); }

  eraseAt(pg, p, drawing) {
    const r = this.eraserSize / 2 / this.zoom + 1; const objs = this.model.pages[pg.key].objects; let hit = false; const mode = this.eraserMode;
    for (const n of pg.layer.find(".obj")) {
      const o = n.getAttr("obj");
      if (mode === "object") { if (o.type === "stroke") continue; const rect = n.getClientRect(); const x = rect.x / this.zoom, y = rect.y / this.zoom, w = rect.width / this.zoom, h = rect.height / this.zoom; if (p.x >= x - r && p.x <= x + w + r && p.y >= y - r && p.y <= y + h + r) { objs.splice(objs.indexOf(o), 1); n.destroy(); hit = true; } continue; }
      if (o.type !== "stroke" && o.type !== "shape") continue;
      const inv = n.getAbsoluteTransform().copy().invert(); const lp = inv.point({ x: p.x * this.zoom, y: p.y * this.zoom });
      const pts = n.points ? n.points() : null; if (!pts || pts.length < 2) continue;
      if (o.type === "stroke" && mode === "partial") {
        const keep = []; let changed = false; for (let i = 0; i < pts.length; i += 2) { if (Math.hypot(lp.x - pts[i], lp.y - pts[i + 1]) < r + (o.width || 2) / 2) { changed = true; keep.push(null); } else keep.push([pts[i], pts[i + 1], i / 2]); }
        if (!changed) continue;
        const segs = []; let cur = []; keep.forEach(k => { if (k) cur.push(k); else { if (cur.length >= 2) segs.push(cur); cur = []; } }); if (cur.length >= 2) segs.push(cur);
        objs.splice(objs.indexOf(o), 1); n.destroy(); segs.forEach(sg => { const no = { ...o, id: uid(), points: sg.flatMap(k => [k[0], k[1]]) }; if (o.widths) no.widths = sg.map(k => o.widths[k[2]] ?? o.width); objs.push(no); this.addNode(pg, no); }); hit = true; continue;
      }
      let near = false; for (let i = 0; i < pts.length - 2; i += 2) if (distSeg(lp.x, lp.y, pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) < r + (o.width || o.strokeWidth || 2) / 2) { near = true; break; }
      if (near) { objs.splice(objs.indexOf(o), 1); n.destroy(); hit = true; }
    }
    if (hit) { drawing.changed = true; pg.layer.batchDraw(); }
  }

  // ---------------------------------------------------------------- Auswahl
  select(pg, nodes) { this.clearSelection(); this.selection = nodes.map(n => ({ pg, node: n })); nodes.forEach(n => n.draggable(true)); pg.tr.nodes(nodes); pg.tr.moveToTop(); pg.layer.batchDraw(); this.renderCtx(); }
  toggleSelect(pg, node) { const i = this.selection.findIndex(s => s.node === node); if (i >= 0) this.selection.splice(i, 1); else if (!this.selection.length || this.selection[0].pg === pg) this.selection.push({ pg, node }); pg.tr.nodes(this.selection.map(s => s.node)); pg.layer.batchDraw(); this.renderCtx(); }
  clearSelection() { if (!this.selection.length) return; const pg = this.selection[0].pg; this.selection = []; if (pg.tr) { pg.tr.nodes([]); pg.layer.batchDraw(); } if (this.tool === "lasso") this.renderCtx(); }
  selectByPolygon(pg, poly) { const nodes = pg.layer.find(".obj").filter(n => { const r = n.getClientRect(); const cx = (r.x + r.width / 2) / this.zoom, cy = (r.y + r.height / 2) / this.zoom; return pointInPoly(cx, cy, poly); }); if (nodes.length) this.select(pg, nodes); }
  selectByRect(pg, box) { const nodes = pg.layer.find(".obj").filter(n => { const r = n.getClientRect(); const x = r.x / this.zoom, y = r.y / this.zoom, w = r.width / this.zoom, h = r.height / this.zoom; return x >= box.x && y >= box.y && x + w <= box.x + box.w && y + h <= box.y + box.h; }); if (nodes.length) this.select(pg, nodes); }
  deleteSelection() { if (!this.selection.length) return; const pg = this.selection[0].pg; const before = this.snapshot(pg); const objs = this.model.pages[pg.key].objects; this.selection.forEach(s => { const i = objs.indexOf(s.node.getAttr("obj")); if (i >= 0) objs.splice(i, 1); s.node.destroy(); }); this.selection = []; pg.tr.nodes([]); pg.layer.batchDraw(); this.commit(pg, before); this.renderCtx(); }
  copySelection() { if (!this.selection.length) return; this.clipboard = this.selection.map(s => JSON.parse(JSON.stringify(s.node.getAttr("obj")))); }
  paste(offset = 20) { if (!this.clipboard?.length) return; const pg = this.pages[this.currentPage]; if (!pg?.mounted) return; const before = this.snapshot(pg); const nodes = this.clipboard.map(o => { const c = { ...JSON.parse(JSON.stringify(o)), id: uid() }; c.x = (c.x || 0) + offset; c.y = (c.y || 0) + offset; this.model.pages[pg.key].objects.push(c); return this.addNode(pg, c); }); pg.layer.batchDraw(); this.commit(pg, before); this.setTool("lasso"); this.select(pg, nodes); }
  duplicateSelection() { this.copySelection(); this.paste(18); }

  // ---------------------------------------------------------------- Text / Haftnotiz
  createText(pg, p, style) { const before = this.snapshot(pg); const o = { id: uid(), type: "text", x: p.x, y: p.y, text: "", ...this.textStyle, ...(style || {}), rotation: 0, scaleX: 1, scaleY: 1 }; this.model.pages[pg.key].objects.push(o); const node = this.addNode(pg, o); pg.layer.batchDraw(); this.commit(pg, before); this.editText(pg, node, true); }
  createSticky(pg, p) { this.createText(pg, { x: p.x - 10, y: p.y - 10 }, { bg: this.stickyColor || "#fff7a8", width: 170, fontSize: 13 }); }
  editText(pg, node, isNew = false) {
    const o = node.getAttr("obj"); const txt = node.findOne(".txt"); const before = this.snapshot(pg);
    this.clearSelection(); txt.hide(); pg.layer.batchDraw(); this.editingText = true;
    const ta = document.createElement("textarea"); ta.className = "ed-textedit"; pg.el.append(ta);
    const abs = node.getAbsolutePosition(); Object.assign(ta.style, { left: abs.x + "px", top: abs.y + "px", width: (o.width * this.zoom) + "px", minHeight: (txt.height() * this.zoom) + "px", fontSize: o.fontSize * this.zoom + "px", fontFamily: o.fontFamily, color: o.fill, fontWeight: o.bold ? "bold" : "normal", fontStyle: o.italic ? "italic" : "normal", textDecoration: o.underline ? "underline" : "none", textAlign: o.align, background: o.bg || "rgba(255,255,255,.9)", transform: `rotate(${o.rotation || 0}deg)`, lineHeight: String(o.lineHeight || 1.25), padding: 4 * this.zoom + "px" });
    ta.value = o.text; const born = performance.now();
    const focusTa = () => { if (!ta.isConnected) return; ta.focus({ preventScroll: true }); if (!isNew) ta.select(); };
    focusTa(); setTimeout(focusTa, 0);                // Fokus auch nach der Standardaktion des Zeigerereignisses sichern
    const autosize = () => { ta.style.height = "auto"; ta.style.height = ta.scrollHeight + "px"; }; autosize(); ta.oninput = autosize;
    const done = cancel => { if (!ta.isConnected) return; ta.remove(); this.editingText = false; txt.show(); if (!cancel) o.text = ta.value; if (!o.text.trim()) { const objs = this.model.pages[pg.key].objects; const i = objs.indexOf(o); if (i >= 0) objs.splice(i, 1); node.destroy(); } else { const n = this.refreshNode(pg, node); if (!isNew) { this.setTool("lasso"); this.select(pg, [n]); } } pg.layer.batchDraw(); this.commit(pg, before); };
    // kurz nach dem Anlegen holt der Browser den Fokus manchmal auf die Seite zurueck: dann zurueckholen statt beenden
    ta.onblur = () => { if (performance.now() - born < 400 && ta.isConnected) { setTimeout(() => { if (ta.isConnected && document.activeElement !== ta) ta.focus({ preventScroll: true }); }, 0); return; } done(false); };
    ta.onkeydown = e => { if (e.key === "Escape") done(true); if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) done(false); e.stopPropagation(); };
  }

  // ---------------------------------------------------------------- Bilder
  async insertImageFile(file, at) {
    const pg = this.pages[this.currentPage]; if (!pg?.mounted || !file) return;
    const fd = new FormData(); fd.append("upload", file, file.name || "bild.png");
    const r = await fetch(`/api/files/${this.fileId}/assets`, { method: "POST", body: fd }); if (!r.ok) { alert("Bild-Upload fehlgeschlagen"); return; }
    const { url } = await r.json();
    const img = new Image(); img.onload = () => { const maxW = pg.w * 0.5; const sc = Math.min(1, maxW / img.width); const before = this.snapshot(pg); const p = at || this._imgPos || { x: pg.w * 0.25, y: 60 }; const o = { id: uid(), type: "image", src: url, x: p.x, y: p.y, width: img.width * sc, height: img.height * sc, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1 }; this._imgPos = null; this.model.pages[pg.key].objects.push(o); const n = this.addNode(pg, o); pg.layer.batchDraw(); this.commit(pg, before); this.setTool("lasso"); setTimeout(() => this.select(pg, [n]), 50); }; img.src = url;
  }
  onPaste(e) { const items = [...(e.clipboardData?.items || [])]; const img = items.find(i => i.type.startsWith("image/")); if (img) { e.preventDefault(); this.insertImageFile(img.getAsFile()); return; } if (this.clipboard && !this.editingText && !["TEXTAREA", "INPUT"].includes(document.activeElement?.tagName)) { e.preventDefault(); this.paste(); } }

  // ---------------------------------------------------------------- Seitenverwaltung
  rebuildPages() { this.pages.forEach(p => this.unmount(p)); this.buildPages(); this.renderSide(); }
  insertPage(where, entry) { const before = this.pagesSnap(); const i = this.currentPage; const pos = where === "before" ? i : where === "end" ? this.pages.length : i + 1; this.model.pageOrder.splice(pos, 0, entry); this.model.pages[entry.key] ||= { objects: [] }; this.rebuildPages(); this.commitPages(before); setTimeout(() => this.goToPage(pos), 60); }
  addBlankPage(where = "after", template = "blank", size = null) { const cur = this.pages[this.currentPage]; const s = size && validSize(size.w, size.h) ? size : { w: cur?.baseW || 595, h: cur?.baseH || 842 }; this.insertPage(where, { key: "b" + uid(), type: "blank", template, w: s.w, h: s.h }); }
  // Seitenformat einer Notizseite aendern (A6 … A2 hoch/quer, Whiteboards): Objekte behalten ihre Lage in Punkten
  setFormat(i, size) { if (!size || !validSize(size.w, size.h)) return; const before = this.pagesSnap(); const p = this.model.pageOrder[i]; if (p.type !== "blank") return; p.w = size.w; p.h = size.h; this.rebuildPages(); this.commitPages(before); }
  formatPicker(anchor, i) {
    const p = this.model.pageOrder[i]; if (p.type !== "blank") { alert("Nur Notizseiten lassen sich im Format ändern; PDF-Seiten behalten ihr Maß."); return; }
    const w = p.w || 595, h = p.h || 842; let orient = formatOf(w, h)?.orientation || (w > h ? "landscape" : "portrait");
    this.showPop(anchor, `<div class="ed-menu"><div class="ed-menu-head">Seitenformat (${sizeLabel(w, h)})</div>
      <div class="seg ed-orient"><button data-orient="portrait" class="${orient === "portrait" ? "active" : ""}">Hoch</button><button data-orient="landscape" class="${orient === "landscape" ? "active" : ""}">Quer</button></div>
      <div class="ed-menu-list">${Object.entries(FORMATS).map(([k, f]) => `<button data-fmt="${k}">${f.name} <span class="muted tiny">${Math.round(f.w / 72 * 2.54)} × ${Math.round(f.h / 72 * 2.54)} cm</span></button>`).join("")}</div>
      <div class="ed-menu-sub">Whiteboard (immer quer)</div><div class="ed-menu-list">${Object.entries(WHITEBOARDS).map(([k, f]) => `<button data-fmt="${k}" title="${f.hint || ""}">${f.name}</button>`).join("")}</div></div>`);
    $$("[data-orient]", this.pop).forEach(b => b.onclick = () => { orient = b.dataset.orient; $$("[data-orient]", this.pop).forEach(x => x.classList.toggle("active", x === b)); });
    $$("[data-fmt]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; this.setFormat(i, formatSize(b.dataset.fmt, orient)); });
  }
  duplicatePage(i = this.currentPage) { const src = this.model.pageOrder[i]; const key = (src.type === "pdf" ? "p" + src.index + "c" : "b") + uid(); const before = this.pagesSnap(); this.model.pageOrder.splice(i + 1, 0, { ...src, key }); this.model.pages[key] = JSON.parse(JSON.stringify(this.model.pages[src.key])); this.model.pages[key].objects.forEach(o => o.id = uid()); this.rebuildPages(); this.commitPages(before); }
  rotatePage(i = this.currentPage, deg = 90) { const before = this.pagesSnap(); const p = this.model.pageOrder[i]; p.rotation = ((p.rotation || 0) + deg) % 360; this.rebuildPages(); this.commitPages(before); }
  deletePage(i = this.currentPage) { if (this.pages.length <= 1) return; const before = this.pagesSnap(); const [p] = this.model.pageOrder.splice(i, 1); this.model.deletedPages.push({ entry: p, objects: this.model.pages[p.key]?.objects || [], at: Date.now(), pos: i }); this.rebuildPages(); this.commitPages(before); this.onStatus("Seite in den Papierkorb gelegt (Mehr → Papierkorb)"); }
  restorePage(idx) { const before = this.pagesSnap(); const d = this.model.deletedPages.splice(idx, 1)[0]; this.model.pageOrder.splice(Math.min(d.pos, this.model.pageOrder.length), 0, d.entry); this.model.pages[d.entry.key] = { objects: d.objects }; this.rebuildPages(); this.commitPages(before); }
  clearPage(i = this.currentPage) { const pg = this.pages[i]; const before = this.snapshot(pg); this.model.pages[pg.key].objects = []; if (pg.mounted) { pg.layer.find(".obj").forEach(n => n.destroy()); pg.layer.batchDraw(); } this.commit(pg, before); }
  movePage(from, to) { if (from === to || to < 0 || to >= this.pages.length) return; const before = this.pagesSnap(); const po = this.model.pageOrder; const [p] = po.splice(from, 1); po.splice(to, 0, p); this.rebuildPages(); this.commitPages(before); }
  setTemplate(i, template) { const before = this.pagesSnap(); const p = this.model.pageOrder[i]; if (p.type !== "blank") { p.type = "blank"; delete p.index; p.w = p.w || this.pages[i].baseW; p.h = p.h || this.pages[i].baseH; } p.template = template; this.rebuildPages(); this.commitPages(before); }
  toggleBookmark(i = this.currentPage, title) { const key = this.pages[i].key; const bm = this.model.bookmarks; const idx = bm.findIndex(b => b.key === key); if (idx >= 0) bm.splice(idx, 1); else bm.push({ key, title: title || `Seite ${i + 1}` }); this.markDirty(); this.renderSide(); }
  addOutline(i = this.currentPage, title) { title = title || (safePrompt("Titel des Gliederungspunkts:", `Abschnitt ${this.model.outline.length + 1}`) ?? ""); if (!title) return; this.model.outline.push({ key: this.pages[i].key, title }); this.markDirty(); this.sideTab = "outline"; this.toggleSide(true); }
  async importPdfPages(file, where = "after") { const fd = new FormData(); fd.append("upload", file, file.name || "import.pdf"); const r = await fetch(`/api/files/${this.fileId}/assets?kind=pdf`, { method: "POST", body: fd }); if (!r.ok) { alert("PDF-Upload fehlgeschlagen"); return; } const { url } = await r.json(); const doc = await this.assetDoc(url); const before = this.pagesSnap(); let pos = where === "before" ? this.currentPage : where === "end" ? this.pages.length : this.currentPage + 1; for (let i = 1; i <= doc.numPages; i++) { const p = await doc.getPage(i); const vp = p.getViewport({ scale: 1 }); const entry = { key: "a" + uid(), type: "asset", assetUrl: url, index: i, w: vp.width, h: vp.height }; this.model.pageOrder.splice(pos++, 0, entry); this.model.pages[entry.key] = { objects: [] }; } this.rebuildPages(); this.commitPages(before); }
  async imageAsPage(file, where = "after") { const pg = this.pages[this.currentPage]; const fd = new FormData(); fd.append("upload", file, file.name || "bild.png"); const r = await fetch(`/api/files/${this.fileId}/assets`, { method: "POST", body: fd }); if (!r.ok) return; const { url } = await r.json(); const img = new Image(); img.onload = () => { const w = pg?.baseW || 595, h = pg?.baseH || 842; const sc = Math.min((w - 40) / img.width, (h - 40) / img.height, 1); const entry = { key: "b" + uid(), type: "blank", template: "blank", w, h }; this.insertPage(where, entry); this.model.pages[entry.key].objects.push({ id: uid(), type: "image", src: url, x: 20, y: 20, width: img.width * sc, height: img.height * sc, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1 }); this.rebuildPages(); this.markDirty(); }; img.src = url; }

  // ---------------------------------------------------------------- Seitenleiste
  renderSide() {
    const body = $(".ed-side-body", this.c); if (!body) return;
    if (this.sideTab === "pages") {
      body.innerHTML = `<div class="ed-thumbs">${this.pages.map((p, i) => `<div class="ed-thumb ${i === this.currentPage ? "active" : ""}" data-i="${i}" draggable="true"><div class="ed-thumb-img"><canvas width="${Math.round(110 * p.w / p.h) || 80}" height="110"></canvas>${this.model.bookmarks.some(b => b.key === p.key) ? `<span class="ed-thumb-bm">${icon("bookmark", 12)}</span>` : ""}</div><div class="ed-thumb-foot"><span>${i + 1}${p.type === "blank" ? ` · ${TEMPLATES[p.template] || "Notiz"}` : ""}</span><button class="ed-thumb-menu" data-pm="${i}" title="Seitenmenü">${icon("chevron-down", 14)}</button></div></div>`).join("")}</div>`;
      $$(".ed-thumb", body).forEach(d => { d.onclick = e => { if (e.target.closest(".ed-thumb-menu")) return; this.goToPage(+d.dataset.i); }; d.ondragstart = e => e.dataTransfer.setData("text/plain", d.dataset.i); d.ondragover = e => { e.preventDefault(); d.classList.add("over"); }; d.ondragleave = () => d.classList.remove("over"); d.ondrop = e => { e.preventDefault(); d.classList.remove("over"); const from = +e.dataTransfer.getData("text/plain"); this.movePage(from, +d.dataset.i); }; });
      $$(".ed-thumb-menu", body).forEach(b => b.onclick = e => { e.stopPropagation(); this.pageMenu(+b.dataset.pm, b); });
      this.thumbIO?.disconnect(); this.thumbIO = new IntersectionObserver(ens => ens.forEach(en => { if (!en.isIntersecting) return; this.thumbIO.unobserve(en.target); this.renderThumb(this.pages[+en.target.dataset.i], $("canvas", en.target)); }), { root: body, rootMargin: "300px" });
      $$(".ed-thumb", body).forEach(d => this.thumbIO.observe(d));
    } else if (this.sideTab === "outline") {
      const items = [...this.model.outline.map((o, i) => ({ ...o, kind: "outline", i })), ...this.model.bookmarks.map((b, i) => ({ ...b, kind: "bm", i }))];
      body.innerHTML = `<div class="ed-outline"><div class="row between small"><b>Gliederung & Lesezeichen</b><button class="ed-mini" data-act="addoutline">${icon("plus", 14)}</button></div>${items.map(it => { const pi = this.pages.findIndex(p => p.key === it.key); return pi < 0 ? "" : `<div class="ed-ol" data-i="${pi}">${icon(it.kind === "bm" ? "bookmark" : "list", 14)}<span class="ed-ol-t" contenteditable="true" data-kind="${it.kind}" data-idx="${it.i}">${esc(it.title)}</span><span class="muted tiny">S. ${pi + 1}</span><button class="ed-mini" data-del="${it.kind}:${it.i}" title="Entfernen">${icon("x", 12)}</button></div>`; }).join("") || `<p class="muted small">Noch keine Einträge. Über das Seitenmenü „Zur Gliederung hinzufügen“ oder Lesezeichen setzen.</p>`}${this.pdfOutline ? `<div class="small muted" style="margin-top:.6rem"><b>PDF-Gliederung</b>${this.pdfOutline.map(o => `<div class="ed-ol" data-i="${o.page}">${icon("file-text", 14)}<span>${esc(o.title)}</span><span class="muted tiny">S. ${o.page + 1}</span></div>`).join("")}</div>` : ""}</div>`;
      $$(".ed-ol", body).forEach(el => el.onclick = e => { if (e.target.closest("[contenteditable], button")) return; this.goToPage(+el.dataset.i); });
      $$(".ed-ol-t", body).forEach(el => el.onblur = () => { const list = el.dataset.kind === "bm" ? this.model.bookmarks : this.model.outline; list[+el.dataset.idx].title = el.textContent.trim() || "Abschnitt"; this.markDirty(); });
      $$("[data-del]", body).forEach(b => b.onclick = () => { const [k, i] = b.dataset.del.split(":"); (k === "bm" ? this.model.bookmarks : this.model.outline).splice(+i, 1); this.markDirty(); this.renderSide(); });
      $("[data-act=addoutline]", body).onclick = () => this.addOutline();
      if (this.pdf && !this.pdfOutline) this.loadPdfOutline();
    } else {
      body.innerHTML = `<div class="ed-rec"><div class="row between small"><b>Aufnahmen</b><button class="ed-mini ${this.recorder ? "rec-on" : ""}" data-act="record">${icon("circle", 14)} ${this.recorder ? "Stopp" : "Aufnehmen"}</button></div><p class="muted tiny">Audio nur nach Freigabe des Mikrofons. Bitte Aufnahmen von Lehrveranstaltungen nur mit Erlaubnis. Transkription ist in dieser lokalen Version nicht verfügbar.</p><div class="ed-rec-list muted small">Lade…</div></div>`;
      $("[data-act=record]", body).onclick = () => this.toggleRecording();
      fetch(`/api/files/${this.fileId}/recordings`).then(r => r.json()).then(list => { const el = $(".ed-rec-list", body); if (!el) return; el.innerHTML = list.map(r => `<div class="ed-rec-item"><div class="row between"><b class="small">${esc(r.title)}</b><button class="ed-mini" data-delrec="${r.id}">${icon("trash", 12)}</button></div><audio controls src="${r.url}" style="width:100%"></audio><span class="muted tiny">${r.page ? `Seite ${r.page} · ` : ""}${new Date(r.created_at).toLocaleString("de-DE")}</span></div>`).join("") || "<span class='muted'>Keine Aufnahmen.</span>"; $$("[data-delrec]", el).forEach(b => b.onclick = async () => { await fetch(`/api/recordings/${b.dataset.delrec}`, { method: "DELETE" }); this.renderSide(); }); });
    }
  }
  async renderThumb(p, cv) { if (!cv || !p) return; if (p.type === "blank") { this.renderTemplateThumb(cv, p); return; } const doc = p.type === "asset" ? await this.assetDoc(p.assetUrl) : this.pdf; if (!doc) return; const page = await doc.getPage(p.index); const vp = page.getViewport({ scale: cv.height / (p.rotation % 180 ? p.baseW : p.baseH), rotation: ((page.rotate || 0) + (p.rotation || 0)) % 360 }); cv.width = vp.width; try { await page.render({ canvasContext: cv.getContext("2d"), viewport: vp }).promise; } catch {} }
  renderTemplateThumb(cv, p) { const ctx = cv.getContext("2d"); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height); ctx.strokeStyle = "#d9dde8"; const t = p.template; if (t === "lined" || t === "cornell") for (let y = 12; y < cv.height; y += 8) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(cv.width, y); ctx.stroke(); } if (t === "grid" || t === "mm") { for (let x = 0; x < cv.width; x += 7) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, cv.height); ctx.stroke(); } for (let y = 0; y < cv.height; y += 7) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(cv.width, y); ctx.stroke(); } } if (t === "dotted") { ctx.fillStyle = "#c9ced9"; for (let x = 6; x < cv.width; x += 7) for (let y = 6; y < cv.height; y += 7) ctx.fillRect(x, y, 1.2, 1.2); } }
  async loadPdfOutline() { try { const ol = await this.pdf.getOutline(); if (!ol) { this.pdfOutline = []; return; } const out = []; for (const it of ol.slice(0, 60)) { try { const dest = typeof it.dest === "string" ? await this.pdf.getDestination(it.dest) : it.dest; const idx = dest ? await this.pdf.getPageIndex(dest[0]) : 0; const pi = this.pages.findIndex(p => p.type === "pdf" && p.index === idx + 1); if (pi >= 0) out.push({ title: it.title, page: pi }); } catch {} } this.pdfOutline = out; if (out.length) this.renderSide(); } catch { this.pdfOutline = []; } }
  pageMenu(i, anchor) {
    const p = this.model.pageOrder[i]; const isBm = this.model.bookmarks.some(b => b.key === p.key);
    this.showPop(anchor, `<div class="ed-menu"><div class="ed-menu-head">Seite „${i + 1}“</div>
      <button data-m="bm">${icon("bookmark", 16)} ${isBm ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen"}</button>
      <button data-m="copy">${icon("copy", 16)} Seite kopieren (duplizieren)</button>
      <button data-m="rotate">${icon("rotate", 16)} Seite drehen</button>
      <button data-m="outline">${icon("list", 16)} Seite zur Gliederung hinzufügen</button>
      <button data-m="template">${icon("grid", 16)} Vorlage wechseln</button><button data-m="format">${icon("columns", 16)} Seitenformat ändern</button>
      <button data-m="goto">${icon("arrow-right", 16)} Gehe zu Seite <span class="muted small">(1 – ${this.pages.length})</span></button>
      <button data-m="clear" class="danger">${icon("eraser", 16)} Seite leeren</button>
      <button data-m="delete" class="danger">${icon("trash", 16)} Seite in den Papierkorb legen</button></div>`);
    $$("[data-m]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; const m = b.dataset.m; if (m === "bm") this.toggleBookmark(i); if (m === "copy") this.duplicatePage(i); if (m === "rotate") this.rotatePage(i); if (m === "outline") this.addOutline(i); if (m === "template") this.templatePicker(anchor, t => this.setTemplate(i, t)); if (m === "format") this.formatPicker(anchor, i); if (m === "goto") { const n = +(safePrompt("Seite:", String(i + 1)) || 0); if (n) this.goToPage(n - 1); } if (m === "clear") { if (confirm("Alle Notizen auf dieser Seite löschen? (Rückgängig möglich)")) this.clearPage(i); } if (m === "delete") this.deletePage(i); });
  }
  templatePicker(anchor, cb) { this.showPop(anchor, `<div class="ed-menu"><div class="ed-menu-head">Vorlage wechseln</div><div class="ed-tpl-grid">${Object.entries(TEMPLATES).map(([k, n]) => `<button data-tpl="${k}"><i class="ed-tpl ${k}"></i><span>${n}</span></button>`).join("")}</div></div>`); $$("[data-tpl]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; cb(b.dataset.tpl); }); }
  showPop(anchor, html) { const pop = this.pop; pop.innerHTML = html; pop.hidden = false; const r = anchor.getBoundingClientRect(); const c = this.c.getBoundingClientRect(); pop.style.top = (r.bottom - c.top + 6) + "px"; const left = Math.min(r.left - c.left, c.width - pop.offsetWidth - 10); pop.style.left = Math.max(6, left) + "px"; }

  // ---------------------------------------------------------------- Menüs der Hauptleiste
  action(a, btn) {
    const map = {
      peninput: () => { this._penManual = true; this.penInput = this.penInput === "pen_only" ? "all" : "pen_only"; this.updatePenInputBtn(); this.onStatus(this.penInput === "pen_only" ? "Nur Stift schreibt – Finger scrollt und zoomt" : "Finger darf schreiben"); fetch("/api/settings", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ pen_input: this.penInput }) }).catch(() => {}); },
      side: () => this.toggleSide(), undo: () => (this.delegate?.() || this).undo(), redo: () => (this.delegate?.() || this).redo(), delete: () => this.deleteSelection(), duplicate: () => this.duplicateSelection(), copy: () => { this.copySelection(); this.onStatus("Kopiert"); }, cut: () => { this.copySelection(); this.deleteSelection(); },
      zoomin: () => this.zoomTo(this.zoom * 1.2), zoomout: () => this.zoomTo(this.zoom / 1.2), fit: () => this.fitWidth(), fullscreen: () => this.toggleFullscreen(), prev: () => this.goToPage(this.currentPage - 1), next: () => this.goToPage(this.currentPage + 1),
      ai: () => { const p = $(".ed-ai", this.c); p.hidden = !p.hidden; if (!p.hidden) this.community?.toggle(false); },
      community: () => { if (this.community) this.community.toggle(); else this.onStatus("Community lädt …"); }, nobg: () => this.setTextStyle({ bg: "" }), nofill: () => { this.shapeFill = ""; this.applyToSelection({ fill: "" }); this.renderCtx(); },
      image: () => { const inp = document.createElement("input"); inp.type = "file"; inp.accept = "image/*"; inp.onchange = () => this.insertImageFile(inp.files[0]); inp.click(); },
      search: () => this.searchPop(btn), addpage: () => this.addPagePop(btn), export: () => this.exportPop(btn), more: () => this.morePop(btn), accessories: () => this.accessoriesPop(btn),
    };
    map[a]?.();
  }
  searchPop(btn) { this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Im Dokument suchen</div><input class="ed-search input" placeholder="Suchbegriff… (Enter)"><div class="ed-search-res"></div></div>`); const inp = $(".ed-search", this.pop); inp.focus(); inp.onkeydown = e => { if (e.key === "Enter") this.search(inp.value); e.stopPropagation(); }; }
  addPagePop(btn) {
    let where = "after", fmt = "current", orient = "portrait"; const cur = this.model.pageOrder[this.currentPage];
    this.showPop(btn, `<div class="ed-menu ed-addpage"><div class="ed-menu-head">Seite hinzufügen</div><div class="seg ed-where"><button data-where="before">Vor dieser</button><button data-where="after" class="active">Nach dieser</button><button data-where="end">Letzte Seite</button></div>
      <div class="ed-menu-sub">Format</div><div class="seg ed-format"><button data-fmt="current" class="active">Wie aktuelle</button>${Object.entries(FORMATS).map(([k, f]) => `<button data-fmt="${k}">${f.name}</button>`).join("")}</div>
      <div class="seg ed-orient" style="margin-top:.3rem"><button data-orient="portrait" class="active">Hoch</button><button data-orient="landscape">Quer</button>${Object.entries(WHITEBOARDS).map(([k, f]) => `<button data-fmt="${k}" title="${f.hint || ""}">${f.name.replace(/ \(.*\)/, "")}-Whiteboard</button>`).join("")}</div>
      <div class="ed-menu-sub">Neue Vorlagen</div><p class="muted tiny">Vorlagen übernehmen die gewählte Größe, sonst die der aktuellen Seite.</p>
      <div class="ed-tpl-grid"><button data-tpl="current"><i class="ed-tpl current"></i><span>Aktuelle Vorlage</span></button>${Object.entries(TEMPLATES).map(([k, n]) => `<button data-tpl="${k}"><i class="ed-tpl ${k}"></i><span>${n}</span></button>`).join("")}</div>
      <div class="ed-menu-list"><button data-add="image">${icon("image", 16)} Bild</button><button data-add="pdf">${icon("file-text", 16)} PDF-Seiten importieren</button><button data-add="dup">${icon("copy", 16)} Aktuelle Seite duplizieren</button></div></div>`);
    $$("[data-where]", this.pop).forEach(b => b.onclick = () => { where = b.dataset.where; $$("[data-where]", this.pop).forEach(x => x.classList.toggle("active", x === b)); });
    $$("[data-fmt]", this.pop).forEach(b => b.onclick = () => { fmt = b.dataset.fmt; $$("[data-fmt]", this.pop).forEach(x => x.classList.toggle("active", x === b)); });
    $$("[data-orient]", this.pop).forEach(b => b.onclick = () => { orient = b.dataset.orient; $$("[data-orient]", this.pop).forEach(x => x.classList.toggle("active", x === b)); });
    const chosen = () => fmt === "current" ? null : formatSize(fmt, orient);
    $$("[data-tpl]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; const t = b.dataset.tpl; if (t === "current") { if (cur.type === "blank") this.addBlankPage(where, cur.template, chosen()); else if (chosen()) this.addBlankPage(where, "blank", chosen()); else this.duplicatePage(); } else this.addBlankPage(where, t, chosen()); });
    $$("[data-add]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; const k = b.dataset.add; if (k === "dup") return this.duplicatePage(); const inp = document.createElement("input"); inp.type = "file"; inp.accept = k === "pdf" ? "application/pdf" : "image/*"; inp.onchange = () => k === "pdf" ? this.importPdfPages(inp.files[0], where) : this.imageAsPage(inp.files[0], where); inp.click(); });
  }
  exportPop(btn) {
    this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Teilen und Exportieren</div><div class="ed-menu-sub">Zusammenarbeit</div><button disabled title="Noch nicht verbunden">${icon("users", 16)} Teilen… <span class="muted tiny">vorbereitet</span></button>
      <div class="ed-menu-sub">Exportieren</div><label class="small" style="display:flex;gap:.4rem;align-items:center;padding:.2rem .6rem"><input type="checkbox" class="ed-exp-noann"> Ohne Notizen exportieren</label>
      <button data-exp="page">${icon("file", 16)} Diese Seite exportieren</button><button data-exp="range">${icon("list", 16)} Ausgewählte Seiten… </button><button data-exp="all">${icon("download", 16)} Alle exportieren</button><button data-exp="print">${icon("file-text", 16)} Drucken</button></div>`);
    $$("[data-exp]", this.pop).forEach(b => b.onclick = () => { const noann = $(".ed-exp-noann", this.pop).checked; this.pop.hidden = true; const k = b.dataset.exp; if (k === "page") this.exportPdf([this.currentPage], noann); else if (k === "range") { const r = safePrompt("Seiten (z. B. 1-3,5):", `${this.currentPage + 1}`); if (r) this.exportPdf(parseRange(r, this.pages.length), noann); } else if (k === "print") this.exportPdf(null, noann, true); else this.exportPdf(null, noann); });
  }
  morePop(btn) {
    const i = this.currentPage; const p = this.model.pageOrder[i]; const isBm = this.model.bookmarks.some(b => b.key === p.key);
    this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Mehr</div><div class="ed-menu-sub">Seite „${i + 1}“</div>
      <button data-m="bm">${icon("bookmark", 16)} ${isBm ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen"}</button><button data-m="copy">${icon("copy", 16)} Seite kopieren</button><button data-m="rotate">${icon("rotate", 16)} Seite drehen</button><button data-m="outline">${icon("list", 16)} Seite zur Gliederung hinzufügen</button><button data-m="template">${icon("grid", 16)} Vorlage wechseln</button><button data-m="format">${icon("columns", 16)} Seitenformat ändern</button><button data-m="goto">${icon("arrow-right", 16)} Gehe zu Seite <span class="muted tiny">(1 – ${this.pages.length})</span></button><button data-m="clear" class="danger">${icon("eraser", 16)} Seite leeren</button><button data-m="delete" class="danger">${icon("trash", 16)} Seite in den Papierkorb legen</button>
      ${this.model.deletedPages.length ? `<button data-m="trash">${icon("rotate", 16)} Papierkorb (${this.model.deletedPages.length}) – wiederherstellen</button>` : ""}
      <div class="ed-menu-sub">Einstellungen</div>
      <div class="ed-menu-row">${icon("move", 16)} Scrollrichtung <select data-pref="scroll"><option value="vertical" ${this.prefs.scroll === "vertical" ? "selected" : ""}>Vertikal</option><option value="horizontal" ${this.prefs.scroll === "horizontal" ? "selected" : ""}>Horizontal</option></select></div>
      <div class="ed-menu-row">${icon("panel-left", 16)} Seitenleiste <select data-pref="sidebar"><option value="left" ${this.prefs.sidebar === "left" ? "selected" : ""}>Links</option><option value="right" ${this.prefs.sidebar === "right" ? "selected" : ""}>Rechts</option></select></div>
      <div class="ed-menu-row">${icon("pen", 16)} Stylus- & Handballenerkennung <select data-pref="pen"><option value="all" ${this.penInput === "all" ? "selected" : ""}>Finger darf schreiben</option><option value="pen_only" ${this.penInput === "pen_only" ? "selected" : ""}>Nur Stift schreibt, Finger navigiert</option></select></div>
      <div class="ed-menu-row">${icon("file", 16)} Dokumentbearbeitung <select data-pref="single"><option value="0" ${!this.prefs.single ? "selected" : ""}>Fortlaufend</option><option value="1" ${this.prefs.single ? "selected" : ""}>Einzelne Seite</option></select></div>
      <button data-m="toolbar">${icon("settings", 16)} Werkzeugleiste anpassen</button></div>`);
    $$("[data-m]", this.pop).forEach(b => b.onclick = () => { const m = b.dataset.m; if (m !== "template" && m !== "toolbar" && m !== "trash" && m !== "format") this.pop.hidden = true; if (m === "bm") this.toggleBookmark(i); if (m === "copy") this.duplicatePage(i); if (m === "rotate") this.rotatePage(i); if (m === "outline") this.addOutline(i); if (m === "template") this.templatePicker(btn, t => this.setTemplate(i, t)); if (m === "format") this.formatPicker(btn, i); if (m === "goto") { const n = +(safePrompt("Seite:", String(i + 1)) || 0); if (n) this.goToPage(n - 1); } if (m === "clear") { if (confirm("Alle Notizen auf dieser Seite löschen? (Rückgängig möglich)")) this.clearPage(i); } if (m === "delete") this.deletePage(i); if (m === "trash") this.trashPop(btn); if (m === "toolbar") this.toolbarPop(btn); });
    $$("[data-pref]", this.pop).forEach(s => s.onchange = () => { const k = s.dataset.pref; if (k === "pen") { this._penManual = true; this.penInput = s.value; this.updatePenInputBtn(); fetch("/api/settings", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ pen_input: s.value }) }).catch(() => {}); } else if (k === "single") { this.prefs.single = s.value === "1"; this.savePrefs(); this.showSingle(); } else { this.prefs[k] = s.value; this.savePrefs(); } });
  }
  trashPop(btn) { this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Papierkorb</div>${this.model.deletedPages.map((d, i) => `<button data-rs="${i}">${icon("rotate", 16)} ${d.entry.type === "blank" ? "Notizseite" : "PDF-Seite " + (d.entry.index || "")} wiederherstellen <span class="muted tiny">${new Date(d.at).toLocaleTimeString("de-DE")}</span></button>`).join("")}<button data-rs="clear" class="danger">${icon("trash", 16)} Papierkorb leeren</button></div>`); $$("[data-rs]", this.pop).forEach(b => b.onclick = () => { this.pop.hidden = true; if (b.dataset.rs === "clear") { this.model.deletedPages = []; this.markDirty(); } else this.restorePage(+b.dataset.rs); }); }
  toolbarPop(btn) { const tools = [["lasso", "Lasso"], ["pen", "Stift"], ["eraser", "Radierer"], ["text", "Text"], ["shape", "Formen"], ["image", "Bild"], ["sticky", "Haftnotiz"], ["textselect", "PDF-Text markieren"], ["hand", "Hand"]]; this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Werkzeugleiste anpassen</div>${tools.map(([k, n]) => `<label class="ed-menu-row"><input type="checkbox" data-tb="${k}" ${this.prefs.hidden.includes(k) ? "" : "checked"}> ${n}</label>`).join("")}<p class="muted tiny" style="padding:.2rem .6rem">Stiftfarben und -stärken merkt sich die Kontextleiste automatisch.</p></div>`); $$("[data-tb]", this.pop).forEach(c => c.onchange = () => { const k = c.dataset.tb; this.prefs.hidden = this.prefs.hidden.filter(x => x !== k); if (!c.checked) this.prefs.hidden.push(k); this.savePrefs(); }); }
  accessoriesPop(btn) { this.showPop(btn, `<div class="ed-menu"><div class="ed-menu-head">Zubehör</div><button data-ac="record">${icon("circle", 16)} ${this.recorder ? "Aufnahme stoppen" : "Aufnehmen"}</button><button data-ac="recs">${icon("sync", 16)} Aufnahmen anzeigen</button><button data-ac="zoomwin">${icon("zoom-in", 16)} Zoom-Ansicht ${this.zoomWin ? "(aus)" : ""}</button><button data-ac="ruler">${icon("line", 16)} Lineal ${this.ruler ? "(aus)" : ""}</button><button data-ac="timer">${icon("clock", 16)} Zeitmesser</button><div class="ed-menu-sub"></div><button data-ac="toolbar">${icon("settings", 16)} Werkzeugleiste anpassen</button></div>`); $$("[data-ac]", this.pop).forEach(b => b.onclick = () => { const k = b.dataset.ac; if (k !== "toolbar") this.pop.hidden = true; if (k === "record") this.toggleRecording(); if (k === "recs") { this.sideTab = "rec"; $$("[data-side]", this.c).forEach(x => x.classList.toggle("active", x.dataset.side === "rec")); this.toggleSide(true); } if (k === "zoomwin") this.toggleZoomWin(); if (k === "ruler") this.toggleRuler(); if (k === "timer") this.onAccessory("timer"); if (k === "toolbar") this.toolbarPop(btn); }); }

  // ---------------------------------------------------------------- Navigation, Zoom, Vollbild
  setCurrent(pg) { if (this.destroyed) return; const i = this.pages.indexOf(pg); if (i >= 0 && i !== this.currentPage) { this.currentPage = i; $(".ed-pageno", this.c).value = i + 1; $$(".ed-thumb", this.c).forEach(t => t.classList.toggle("active", +t.dataset.i === i)); $(".ed-ai-page", this.c).textContent = `Seite ${i + 1}`; this.onPage(i + 1); if (this.ruler) this.showRuler(pg); if (this.zoomWin) this.zoomWinSetPage(pg); } }
  onScroll() { if (this.prefs.single) return; const horiz = this.prefs.scroll === "horizontal"; const mid = horiz ? this.scroll.scrollLeft + this.scroll.clientWidth / 2 : this.scroll.scrollTop + this.scroll.clientHeight / 3; let best = 0; for (let i = 0; i < this.pages.length; i++) { const el = this.pages[i].el; if ((horiz ? el.offsetLeft : el.offsetTop) <= mid) best = i; else break; } this.setCurrent(this.pages[best]); }
  goToPage(i) { if (this.destroyed || !this.pages.length) return; i = clamp(i, 0, this.pages.length - 1); if (this.prefs.single) { this.currentPage = i; this.showSingle(); this.setCurrent(this.pages[i]); $(".ed-pageno", this.c).value = i + 1; return; } const el = this.pages[i].el; this.prefs.scroll === "horizontal" ? this.scroll.scrollTo({ left: el.offsetLeft - 12, behavior: "smooth" }) : this.scroll.scrollTo({ top: el.offsetTop - 8, behavior: "smooth" }); this.setCurrent(this.pages[i]); }
  zoomTo(z, anchor) { z = clamp(z, 0.3, 6); const old = this.zoom; if (Math.abs(z - old) < 0.001) return; const sr = this.scroll.getBoundingClientRect(); const a = anchor || { x: this.scroll.clientWidth / 2, y: this.scroll.clientHeight / 2 }; const ax = sr.left + a.x, ay = sr.top + a.y; let ref = null; for (const pg of this.pages) { const r = pg.el.getBoundingClientRect(); if (r.width && ay >= r.top - 30 && ay <= r.bottom + 30) { ref = { pg, px: (ax - r.left) / old, py: (ay - r.top) / old }; break; } } if (!ref) { const pg = this.pages[this.currentPage] || this.pages[0]; const r = pg.el.getBoundingClientRect(); ref = { pg, px: (ax - r.left) / old, py: (ay - r.top) / old }; } this.zoom = z; this.model.zoom = z; this.applyZoomSizes(); this.updateZoomLabel(); const r2 = ref.pg.el.getBoundingClientRect(); this.scroll.scrollLeft += (r2.left + ref.px * z) - ax; this.scroll.scrollTop += (r2.top + ref.py * z) - ay; this.dirty = true; clearTimeout(this._zs); this._zs = setTimeout(() => this.flush(), 2500); if (this.ruler) this.showRuler(this.pages[this.currentPage]); if (!this.pinch && !this._pinchCommit) this.clampView(); }
  zoomAt(z, clientX, clientY) { const r = this.scroll.getBoundingClientRect(); this.zoomTo(z, { x: clientX - r.left, y: clientY - r.top }); }
  fitWidth() { const pg = this.pages[this.currentPage] || this.pages[0]; this.zoomTo((this.scroll.clientWidth - 40) / pg.w); }
  fitPage() { const pg = this.pages[this.currentPage] || this.pages[0]; this.zoomTo(Math.min((this.scroll.clientWidth - 40) / pg.w, (this.scroll.clientHeight - 30) / pg.h)); }
  updateZoomLabel() { $(".ed-zoom", this.c).textContent = Math.round(this.zoom * 100) + "%"; }
  fling(vx, vy) { if (Math.hypot(vx, vy) < 0.05) return; const f = { vx, vy, t: performance.now() }; this._fling = f; const step = () => { if (this._fling !== f) return; const now = performance.now(); const dt = Math.min(40, now - f.t); f.t = now; this.scroll.scrollLeft -= f.vx * dt; this.scroll.scrollTop -= f.vy * dt; { const sl = this.scroll.scrollLeft, st = this.scroll.scrollTop; this.clampView(); if (this.scroll.scrollLeft !== sl) f.vx = 0; if (this.scroll.scrollTop !== st) f.vy = 0; } f.vx *= Math.pow(0.94, dt / 16); f.vy *= Math.pow(0.94, dt / 16); if (Math.hypot(f.vx, f.vy) > 0.02) requestAnimationFrame(step); else this._fling = null; }; requestAnimationFrame(step); }
  pinchStart() { const [a, b] = [...this.pointers.values()]; if (!a || !b) return; const mx = (a.clientX + b.clientX) / 2, my = (a.clientY + b.clientY) / 2; const pr = this.pagesEl.getBoundingClientRect(); this.pinch = { d0: Math.max(1, Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY)), z0: this.zoom, m0x: mx, m0y: my, k: 1, tx: 0, ty: 0 }; const pe = this.pagesEl.style; pe.transformOrigin = `${mx - pr.left}px ${my - pr.top}px`; pe.willChange = "transform"; }
  pinchMove() { if (!this.pinch || this._pinchRaf) return; this._pinchRaf = requestAnimationFrame(() => { this._pinchRaf = 0; const P = this.pinch; if (!P) return; const [a, b] = [...this.pointers.values()]; if (!a || !b) return; const z = clamp(P.z0 * Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY) / P.d0, 0.3, 6); P.k = z / P.z0; P.tx = (a.clientX + b.clientX) / 2 - P.m0x; P.ty = (a.clientY + b.clientY) / 2 - P.m0y; this.pagesEl.style.transform = `translate(${P.tx}px, ${P.ty}px) scale(${P.k})`; const zl = $(".ed-zoom", this.c); if (zl) zl.textContent = Math.round(z * 100) + "%"; }); }
  pinchEnd() { const P = this.pinch; this.pinch = null; if (this._pinchRaf) { cancelAnimationFrame(this._pinchRaf); this._pinchRaf = 0; } if (!P) return; const pe = this.pagesEl.style; pe.transform = ""; pe.transformOrigin = ""; pe.willChange = ""; this._pinchCommit = true; try { if (Math.abs(P.k - 1) > 0.003) this.zoomAt(P.z0 * P.k, P.m0x, P.m0y); this.scroll.scrollLeft -= P.tx; this.scroll.scrollTop -= P.ty; } finally { this._pinchCommit = false; } this.updateZoomLabel(); this.clampView(true); }
  toggleFullscreen() { document.body.classList.toggle("fullscreen-doc"); }
  getState() { return { page: this.currentPage, zoom: this.zoom, tool: this.tool, penType: this.penType, color: this.color, width: this.width, scrollTop: this.scroll.scrollTop, scrollLeft: this.scroll.scrollLeft }; }
  restoreState(s) { if (!s) return; this.penType = s.penType || this.penType; this.color = s.color || this.color; this.width = s.width || this.width; if (s.zoom && Math.abs(s.zoom - this.zoom) > 0.01) this.zoomTo(s.zoom); this.setTool(s.tool || "pen"); if (s.page) this._initialGoto = setTimeout(() => this.goToPage(s.page), 200); }

  async search(q) { const out = $(".ed-search-res", this.pop); if (!out) return; q = (q || "").trim().toLowerCase(); if (!q) { out.innerHTML = ""; return; } out.innerHTML = "Suche…"; const hits = []; for (const p of this.pages) { if (p.type !== "pdf") continue; const t = await this.pageText(p.index); const i = t.toLowerCase().indexOf(q); if (i >= 0) hits.push({ i: this.pages.indexOf(p), ctx: t.slice(Math.max(0, i - 30), i + 40).replace(/\s+/g, " ") }); } out.innerHTML = hits.length ? hits.map(h => `<a href="#" data-i="${h.i}"><b>S. ${h.i + 1}</b> …${esc(h.ctx)}…</a>`).join("") : "<span class='muted small'>Nichts gefunden</span>"; $$("a", out).forEach(a => a.onclick = e => { e.preventDefault(); this.pop.hidden = true; this.goToPage(+a.dataset.i); }); }
  async pageText(index) { if (!this.pdf) return ""; if (this.textCache.has(index)) return this.textCache.get(index); const page = await this.pdf.getPage(index); const tc = await page.getTextContent(); const t = tc.items.map(i => i.str).join(" "); this.textCache.set(index, t); return t; }
  async extractText(pg, box) { if (pg.type !== "pdf") return; const page = await this.pdf.getPage(pg.index); const tc = await page.getTextContent(); const vp = page.getViewport({ scale: 1 }); const parts = []; tc.items.forEach(it => { if (!it.str) return; const [x, y] = vp.convertToViewportPoint(it.transform[4], it.transform[5]); const h = Math.hypot(it.transform[2], it.transform[3]) || 10; const w = it.width || 0; const ix = x, iy = y - h; if (ix + w >= box.x && ix <= box.x + box.w && iy + h >= box.y && iy <= box.y + box.h) parts.push({ y: Math.round(iy / 4), x: ix, s: it.str }); }); parts.sort((a, b) => a.y - b.y || a.x - b.x); let text = "", lastY = null; parts.forEach(p => { if (lastY !== null && p.y !== lastY) text += "\n"; else if (text && !text.endsWith(" ")) text += " "; text += p.s; lastY = p.y; }); $(".ed-ai", this.c).hidden = false; $(".ed-ai-sel", this.c).value = text.trim(); this.onStatus(text.trim() ? "Text übernommen – Modus wählen und Fragen" : "Kein Text im markierten Bereich"); }

  // ---------------------------------------------------------------- Zubehör: Lineal
  toggleRuler() { if (this.ruler) { this.ruler.pg?.tmp?.listening(false); this.ruler.group?.destroy(); this.ruler.pg?.tmp?.batchDraw(); this.ruler = null; return; } const rpg = this.pages[this.currentPage]; let rx = 80, ry = 200; if (rpg?.el) { const sr = this.scroll.getBoundingClientRect(); const c = this.toPage(rpg, sr.left + sr.width / 2, sr.top + sr.height / 2); rx = Math.max(0, c.x - 200); ry = Math.max(0, c.y - 17); } this.ruler = { pg: null, x: rx, y: ry, angle: 0, len: 400 }; this.showRuler(this.pages[this.currentPage]); }
  showRuler(pg) { if (!this.ruler || !pg?.mounted) return; this.ruler.group?.destroy(); const r = this.ruler; r.pg = pg; const g = new Konva.Group({ x: r.x, y: r.y, rotation: r.angle, name: "rulerui", listening: false }); g.add(new Konva.Rect({ width: r.len, height: 34, fill: "rgba(79,91,213,.14)", stroke: "#4f5bd5", strokeWidth: 1 / this.zoom, cornerRadius: 5 })); for (let x = 0; x <= r.len; x += 10) g.add(new Konva.Line({ points: [x, 0, x, x % 50 === 0 ? 12 : 6], stroke: "#4f5bd5", strokeWidth: 1 / this.zoom })); for (let x = 0; x <= r.len; x += 10) g.add(new Konva.Line({ points: [x, 34, x, x % 50 === 0 ? 22 : 28], stroke: "#4f5bd5", strokeWidth: 1 / this.zoom })); const lbl = new Konva.Text({ x: r.len / 2 - 14, y: 12, text: `${Math.round(r.angle)}°`, fontSize: 11, fill: "#4f5bd5", fontStyle: "bold" }); g.add(lbl); g.add(new Konva.Circle({ x: r.len, y: 17, radius: 11, fill: "#4f5bd5", opacity: .9 })); pg.tmp.add(g); pg.tmp.batchDraw(); r.group = g; r.label = lbl; }
  toPage(pg, cx, cy) { const r = pg.el.getBoundingClientRect(); return { x: (cx - r.left) / this.zoom, y: (cy - r.top) / this.zoom }; }
  rulerHit(cx, cy, mouse = false) { const R = this.ruler, g = R?.group, pg = R?.pg; if (!g || !pg?.mounted) return null; const q = this.toPage(pg, cx, cy); const a = -R.angle * Math.PI / 180; const dx = q.x - g.x(), dy = q.y - g.y(); const lx = dx * Math.cos(a) - dy * Math.sin(a), ly = dx * Math.sin(a) + dy * Math.cos(a); const pad = mouse ? 0 : 12 / this.zoom;   /* Maus: Kante bleibt zum Zeichnen frei */ if (Math.hypot(lx - R.len, ly - 17) < 22 / this.zoom) return "knob"; return lx >= -pad && lx <= R.len + pad && ly >= -pad && ly <= 34 + pad ? "body" : null; }
  rulerDown(e) { const hit = this.rulerG ? "body" : this.rulerHit(e.clientX, e.clientY); if (!this.rulerG) this.rulerG = { ptrs: new Map(), knob: hit === "knob" }; this.rulerG.ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY }); this.rulerReset(); }
  rulerReset() { const G = this.rulerG, R = this.ruler; if (!G || !R?.group) return; G.s = { x: R.group.x(), y: R.group.y(), a: R.angle, ptrs: [...G.ptrs.values()].map(q => ({ ...q })) }; if (G.ptrs.size > 1) G.knob = false; }
  rulerMove(e) {
    const G = this.rulerG, R = this.ruler, pg = R?.pg; if (!G?.s || !R?.group || !pg?.mounted) return; G.ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const now = [...G.ptrs.values()], s = G.s; let x = s.x, y = s.y, ang = s.a;
    if (now.length >= 2 && s.ptrs.length >= 2) { const d = Math.atan2(now[1].y - now[0].y, now[1].x - now[0].x) - Math.atan2(s.ptrs[1].y - s.ptrs[0].y, s.ptrs[1].x - s.ptrs[0].x); const m0 = this.toPage(pg, (s.ptrs[0].x + s.ptrs[1].x) / 2, (s.ptrs[0].y + s.ptrs[1].y) / 2), m1 = this.toPage(pg, (now[0].x + now[1].x) / 2, (now[0].y + now[1].y) / 2); const ox = s.x - m0.x, oy = s.y - m0.y; x = m1.x + ox * Math.cos(d) - oy * Math.sin(d); y = m1.y + ox * Math.sin(d) + oy * Math.cos(d); ang = s.a + d * 180 / Math.PI; }
    else if (G.knob) { const q = this.toPage(pg, now[0].x, now[0].y); ang = (Math.atan2(q.y - s.y, q.x - s.x) - Math.atan2(17, R.len)) * 180 / Math.PI; }
    else { const p0 = this.toPage(pg, s.ptrs[0].x, s.ptrs[0].y), p1 = this.toPage(pg, now[0].x, now[0].y); x = s.x + p1.x - p0.x; y = s.y + p1.y - p0.y; }
    ang = ((ang % 360) + 360) % 360; for (const sn of [0, 45, 90, 135, 180, 225, 270, 315, 360]) if (Math.abs(ang - sn) < 2) ang = sn % 360;
    R.angle = ang; R.x = x; R.y = y; R.group.position({ x, y }); R.group.rotation(ang); R.label?.text(`${Math.round(ang)}°`); pg.tmp.batchDraw();
  }
  rulerProject(p, force = false) { const r = this.ruler; if (!r?.group) return null; const a = r.angle * Math.PI / 180; const dir = { x: Math.cos(a), y: Math.sin(a) }; const base = { x: r.group.x(), y: r.group.y() }; const rel = { x: p.x - base.x, y: p.y - base.y }; const along = rel.x * dir.x + rel.y * dir.y; const off = -rel.x * dir.y + rel.y * dir.x; let o; if (force) o = this._rulerEdge ?? -3; else { if (along < -10 || along > r.len + 10) return null; if (off >= -16 && off <= 6) o = -3; else if (off >= 28 && off <= 50) o = 37; else return null; this._rulerEdge = o; } return { x: base.x + dir.x * along - dir.y * o, y: base.y + dir.y * along + dir.x * o }; }

  // ---------------------------------------------------------------- Zubehör: Zoom-Ansicht
  toggleZoomWin() { const w = $(".ed-zoomwin", this.c); if (this.zoomWin) { this.zoomWin.rect?.destroy(); this.zoomWin.pg?.tmp?.batchDraw(); this.zoomWin = null; w.hidden = true; return; } w.hidden = false; this.zoomWin = { pg: null, x: 40, y: 60, w: 260, h: 70, scale: 3 }; this.zoomWinSetPage(this.pages[this.currentPage]); this.bindZoomCanvas(); }
  zoomWinSetPage(pg) { const z = this.zoomWin; if (!z || !pg?.mounted) return; z.rect?.destroy(); z.pg = pg; const cv = $(".ed-zw-canvas", this.c); const body = $(".ed-zw-body", this.c); z.w = Math.min(pg.w - 20, (body.clientWidth - 8) / z.scale); z.h = (body.clientHeight - 8) / z.scale; cv.width = Math.round(z.w * z.scale * (window.devicePixelRatio || 1)); cv.height = Math.round(z.h * z.scale * (window.devicePixelRatio || 1)); cv.style.width = z.w * z.scale + "px"; cv.style.height = z.h * z.scale + "px"; const rect = new Konva.Rect({ x: z.x, y: z.y, width: z.w, height: z.h, stroke: "#4f5bd5", strokeWidth: 1.5 / this.zoom, dash: [6 / this.zoom, 3 / this.zoom], fill: "rgba(79,91,213,.05)", draggable: true, name: "rulerui" }); rect.on("dragmove dragend", () => { z.x = rect.x(); z.y = rect.y(); this.zoomWinRefresh(); }); pg.tmp.add(rect); pg.tmp.batchDraw(); z.rect = rect; this.zoomWinRefresh(); }
  zoomWinRefresh() { const z = this.zoomWin; if (!z?.pg?.mounted) return; const pg = z.pg; const cv = $(".ed-zw-canvas", this.c); const ctx = cv.getContext("2d"); const dpr = window.devicePixelRatio || 1; const S = z.scale * dpr; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height); const pdfc = $(".ed-pdf", pg.el); if (pdfc.width) { const k = pdfc.width / pg.w; ctx.drawImage(pdfc, z.x * k, z.y * k, z.w * k, z.h * k, 0, 0, z.w * S, z.h * S); } try { const lc = pg.layer.toCanvas({ x: z.x * this.zoom, y: z.y * this.zoom, width: z.w * this.zoom, height: z.h * this.zoom, pixelRatio: S / this.zoom }); ctx.drawImage(lc, 0, 0, z.w * S, z.h * S); } catch {} }
  bindZoomCanvas() { const cv = $(".ed-zw-canvas", this.c); let d = null; const pos = e => { const r = cv.getBoundingClientRect(); const z = this.zoomWin; return { x: z.x + (e.clientX - r.left) / z.scale, y: z.y + (e.clientY - r.top) / z.scale }; }; cv.onpointerdown = e => { if (!this.zoomWin?.pg?.mounted || !this.allowPointer(e)) return; cv.setPointerCapture(e.pointerId); const p = pos(e); const pg = this.zoomWin.pg; if (this.tool === "eraser") { d = { tool: "eraser", before: this.snapshot(pg), changed: false }; this.eraseAt(pg, p, d); } else { this.setTool(this.tool === "pen" ? "pen" : "pen"); d = this.strokeBegin(pg, p, e.pressure || 0.5); } }; cv.onpointermove = e => { if (!d) return; const p = pos(e); const pg = this.zoomWin.pg; if (d.tool === "eraser") this.eraseAt(pg, p, d); else { this.strokeMove(pg, d, p, e.pressure || 0.5); const r = cv.getBoundingClientRect(); const ctx = cv.getContext("2d"); const S = this.zoomWin.scale * (window.devicePixelRatio || 1); ctx.strokeStyle = this.color; ctx.lineWidth = this.width * S; ctx.lineCap = "round"; const pts = d.pts; if (pts.length >= 4) { ctx.beginPath(); ctx.moveTo((pts[pts.length - 4] - this.zoomWin.x) * S, (pts[pts.length - 3] - this.zoomWin.y) * S); ctx.lineTo((pts[pts.length - 2] - this.zoomWin.x) * S, (pts[pts.length - 1] - this.zoomWin.y) * S); ctx.stroke(); } if (p.x > this.zoomWin.x + this.zoomWin.w - 12) this._zwAdvance = true; } }; const end = e => { if (!d) return; const pg = this.zoomWin.pg; if (d.tool === "eraser") { if (d.changed) this.commit(pg, d.before); } else this.strokeEnd(pg, d); d = null; if (this._zwAdvance) { this._zwAdvance = false; this.zoomWinAction("right"); } }; cv.onpointerup = end; cv.onpointercancel = end; }
  zoomWinAction(k) { const z = this.zoomWin; if (k === "close") return this.toggleZoomWin(); if (!z?.pg) return; if (k === "right") z.x = Math.min(z.pg.w - z.w, z.x + z.w * 0.45); if (k === "left") z.x = Math.max(0, z.x - z.w * 0.45); if (k === "down") { z.y = Math.min(z.pg.h - z.h, z.y + z.h * 0.8); z.x = 40; } z.rect.position({ x: z.x, y: z.y }); z.pg.tmp.batchDraw(); this.zoomWinRefresh(); }

  // ---------------------------------------------------------------- Zubehör: Aufnahme
  async toggleRecording() {
    if (this.recorder) { this.recorder.stop(); return; }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true }); const rec = new MediaRecorder(stream); const chunks = []; const t0 = Date.now();
      rec.ondataavailable = e => chunks.push(e.data);
      rec.onstop = async () => { stream.getTracks().forEach(t => t.stop()); this.recorder = null; this.onStatus("Aufnahme wird gespeichert…"); const blob = new Blob(chunks, { type: rec.mimeType || "audio/webm" }); const fd = new FormData(); fd.append("upload", blob, "aufnahme.webm"); fd.append("page", String(this.currentPage + 1)); fd.append("duration", String((Date.now() - t0) / 1000)); await fetch(`/api/files/${this.fileId}/recordings`, { method: "POST", body: fd }); this.onStatus("Aufnahme gespeichert"); this.sideTab = "rec"; this.toggleSide(true); this.renderSide(); };
      rec.start(); this.recorder = rec; this.onStatus("● Aufnahme läuft…"); this.renderSide();
    } catch (e) { alert("Mikrofon nicht verfügbar oder Zugriff abgelehnt: " + e.message); }
  }

  // ---------------------------------------------------------------- KI
  async askAI() {
    const out = $(".ed-ai-out", this.c); const mode = $(".ed-ai-mode", this.c).value; const pg = this.pages[this.currentPage];
    const body = { file_id: this.fileId, page: pg?.type === "pdf" ? pg.index : null, mode: mode === "quiz" ? "similar" : mode, selection: $(".ed-ai-sel", this.c).value, question: ($(".ed-ai-q", this.c).value || "") + (mode === "quiz" ? " Erstelle 5 Quizfragen mit Lösungen zur Seite." : ""), own_solution: $(".ed-ai-own", this.c).value, page_text: "" };
    if ($(".ed-ai-ctx", this.c).checked && pg?.type === "pdf") body.page_text = await this.pageText(pg.index);
    if (pg?.type === "blank" && $(".ed-ai-ctx", this.c).checked) body.page_text = (this.model.pages[pg.key].objects.filter(o => o.type === "text").map(o => o.text).join("\n")) + "\n[Handschrift auf Notizseiten kann nicht gelesen werden]";
    out.innerHTML = "<div class='muted'>⏳ Die KI denkt nach…</div>"; $(".ed-ai-go", this.c).disabled = true;
    try {
      const r = await fetch("/api/ai/tutor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!r.ok) throw new Error((await r.json()).detail || r.statusText);
      const j = await r.json();
      if (mode === "flashcards" && Array.isArray(j.cards)) { out.innerHTML = `<div class="ed-cards">${j.cards.map(c => `<div class="ed-card"><b>${esc(c.question)}</b><div>${esc(c.answer)}</div></div>`).join("")}</div><button class="btn primary ed-cards-save">Karteikarten speichern (${j.cards.length})</button>`; $(".ed-cards-save", out).onclick = async () => { await fetch("/api/flashcards", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ file_id: this.fileId, cards: j.cards }) }); $(".ed-cards-save", out).textContent = "Gespeichert ✓"; $(".ed-cards-save", out).disabled = true; }; }
      else out.innerHTML = md(j.answer) + `<div class="ed-ai-actions"><button class="btn sm ed-ai-insert">Als Textfeld einfügen</button></div>`;
      $(".ed-ai-insert", out)?.addEventListener("click", () => { if (!pg?.mounted) return; const before = this.snapshot(pg); const o = { id: uid(), type: "text", x: 20, y: 20, text: j.answer.replace(/[*#`]/g, ""), ...this.textStyle, bg: "#e8eeff", width: Math.min(320, pg.w - 40), fontSize: 11, rotation: 0, scaleX: 1, scaleY: 1 }; this.model.pages[pg.key].objects.push(o); this.addNode(pg, o); pg.layer.batchDraw(); this.commit(pg, before); });
    } catch (e) { out.innerHTML = `<div class="ed-err">Fehler: ${esc(e.message)}</div>`; }
    finally { $(".ed-ai-go", this.c).disabled = false; }
  }

  // ---------------------------------------------------------------- Export
  async exportPdf(pageIdx = null, withoutAnnotations = false, print = false) {
    this.onStatus("Exportiere PDF…"); await loadScript("./vendor/pdf-lib.min.js");
    const { PDFDocument, rgb } = window.PDFLib;
    const src = this.pdfBytes ? await PDFDocument.load(this.pdfBytes) : null; const out = await PDFDocument.create(); const assetDocs = new Map();
    const hidden = document.createElement("div"); hidden.style.cssText = "position:fixed;left:-99999px;top:0"; document.body.append(hidden);
    const idxs = pageIdx || this.model.pageOrder.map((_, i) => i);
    for (const i of idxs) {
      const p = this.model.pageOrder[i]; if (!p) continue;
      const size = p.type === "pdf" ? this.pageSizes[p.index - 1] : { w: p.w || 595, h: p.h || 842 };
      let page;
      if (p.type === "pdf" && src) { const [cp] = await out.copyPages(src, [p.index - 1]); page = out.addPage(cp); }
      else if (p.type === "asset") { if (!assetDocs.has(p.assetUrl)) assetDocs.set(p.assetUrl, await PDFDocument.load(await (await fetch(p.assetUrl)).arrayBuffer())); const [cp] = await out.copyPages(assetDocs.get(p.assetUrl), [p.index - 1]); page = out.addPage(cp); }
      else { page = out.addPage([size.w, size.h]); this.drawTemplatePdf(page, p, rgb); }
      if (p.rotation) page.setRotation(window.PDFLib.degrees(((page.getRotation().angle || 0) + p.rotation) % 360));
      const objs = this.model.pages[p.key]?.objects || []; if (!objs.length || withoutAnnotations) continue;
      const scale = 2; const stW = p.rotation % 180 ? size.h : size.w, stH = p.rotation % 180 ? size.w : size.h; const st = new Konva.Stage({ container: hidden, width: stW * scale, height: stH * scale }); st.scale({ x: scale, y: scale });
      const fake = { key: p.key, layer: new Konva.Layer(), tr: new Konva.Transformer(), w: stW, h: stH }; st.add(fake.layer); fake.layer.add(fake.tr);
      const imgs = []; objs.forEach(o => { const n = this.addNode(fake, o); if (o.type === "image") imgs.push(new Promise(res => { const im = new Image(); im.crossOrigin = "anonymous"; im.onload = () => { n.image(im); res(); }; im.onerror = res; im.src = o.src; })); });
      await Promise.all(imgs); fake.tr.destroy(); fake.layer.draw();
      const png = await out.embedPng(st.toDataURL({ pixelRatio: 1 })); st.destroy();
      const { width, height } = page.getSize(); const rot = page.getRotation().angle || 0;
      if (rot === 0) page.drawImage(png, { x: 0, y: 0, width, height }); else page.drawImage(png, { x: 0, y: 0, width, height, rotate: window.PDFLib.degrees(0) });
    }
    hidden.remove();
    const bytes = await out.save(); const blob = new Blob([bytes], { type: "application/pdf" }); const url = URL.createObjectURL(blob);
    if (print) { const w = window.open(url, "_blank"); if (w) w.addEventListener("load", () => { try { w.print(); } catch {} }); }
    else { const a = document.createElement("a"); a.href = url; a.download = this.name.replace(/\.pdf$/i, "") + (pageIdx ? ` (Seite ${pageIdx.map(i => i + 1).join(",")})` : " (annotiert)") + ".pdf"; a.click(); }
    setTimeout(() => URL.revokeObjectURL(url), 20000); this.onStatus("PDF exportiert");
  }
  drawTemplatePdf(page, p, rgb) { const { width: W, height: H } = page.getSize(); const t = p.template || "blank"; const col = rgb(0.85, 0.87, 0.91); const step = t === "mm" ? 2.835 : (t === "grid" || t === "dotted") ? 14.17 : 24; if (t === "lined" || t === "cornell") for (let y = H - 60; y > 0; y -= step) page.drawLine({ start: { x: 0, y }, end: { x: W, y }, thickness: 0.5, color: col }); if (t === "grid" || t === "mm") { for (let x = 0; x < W; x += step) page.drawLine({ start: { x, y: 0 }, end: { x, y: H }, thickness: 0.4, color: col }); for (let y = 0; y < H; y += step) page.drawLine({ start: { x: 0, y }, end: { x: W, y }, thickness: 0.4, color: col }); } if (t === "dotted") for (let x = step; x < W; x += step) for (let y = step; y < H; y += step) page.drawCircle({ x, y, size: 0.8, color: col }); if (t === "cornell") { page.drawLine({ start: { x: 150, y: 150 }, end: { x: 150, y: H }, thickness: 1, color: col }); page.drawLine({ start: { x: 0, y: 150 }, end: { x: W, y: 150 }, thickness: 1, color: col }); } }

  // ---------------------------------------------------------------- Tastatur
  onKey(e) {
    const tgt = e.target;
    if (this.editingText || ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName)
        || (tgt && tgt.closest && tgt.closest('input, textarea, select, [contenteditable="true"], .ed-textedit'))) return;
    const k = e.key.toLowerCase(); const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && k === "z") { e.preventDefault(); e.shiftKey ? this.redo() : this.undo(); } else if (ctrl && k === "y") { e.preventDefault(); this.redo(); }
    else if (ctrl && k === "c") this.copySelection(); else if (ctrl && k === "x") { this.copySelection(); this.deleteSelection(); } else if (ctrl && k === "d") { e.preventDefault(); this.duplicateSelection(); }
    else if (ctrl && (k === "+" || k === "=")) { e.preventDefault(); this.zoomTo(this.zoom * 1.2); } else if (ctrl && k === "-") { e.preventDefault(); this.zoomTo(this.zoom / 1.2); } else if (ctrl && k === "0") { e.preventDefault(); this.fitWidth(); }
    else if (ctrl && k === "b") { e.preventDefault(); this.toggleFmt("bold"); } else if (ctrl && k === "i") { e.preventDefault(); this.toggleFmt("italic"); } else if (ctrl && k === "u") { e.preventDefault(); this.toggleFmt("underline"); }
    else if (k === "delete" || k === "backspace") { if (this.selection.length) { e.preventDefault(); this.deleteSelection(); } }
    else if (k === "escape") { this.clearSelection(); this.pop.hidden = true; if (this.polyPts) this.polyFinish(this.polyPts.pg); }
    else if (!ctrl && { v: "lasso", l: "lasso", p: "pen", h: "pen", e: "eraser", t: "text", s: "shape" }[k]) { const tool = { v: "lasso", l: "lasso", p: "pen", h: "pen", e: "eraser", t: "text", s: "shape" }[k]; if (k === "h") { this.penType = "marker"; this._penCustom = false; } if (k === "p") { this.penType = "pen"; this._penCustom = false; } this.setTool(tool); }
    else if (k === "pagedown" || k === "arrowright" && this.prefs.single) { e.preventDefault(); this.goToPage(this.currentPage + 1); } else if (k === "pageup" || k === "arrowleft" && this.prefs.single) { e.preventDefault(); this.goToPage(this.currentPage - 1); }
    else if (k === "f11") { e.preventDefault(); this.toggleFullscreen(); }
  }
  async destroy() {
    if (this.destroyed) return; this.destroyed = true; clearTimeout(this._t); clearTimeout(this._pendT); clearTimeout(this._initialGoto); if (this.recorder) this.recorder.stop();
    const unsaved = this.dirty; if (unsaved) this._writeDraft(true); clearTimeout(this._draftT);
    this.io?.disconnect(); this.ioFar?.disconnect(); this.thumbIO?.disconnect(); this._ro?.disconnect(); this.pages.forEach(p => this.unmount(p));
    document.removeEventListener("keydown", this._space); document.removeEventListener("keyup", this._spaceUp); document.removeEventListener("pointerdown", this._popClose); document.removeEventListener("gesturestart", this._gest); document.removeEventListener("gesturechange", this._gest); document.removeEventListener("selectstart", this._selStart); window.removeEventListener("pointerup", this._winUp); window.removeEventListener("pointercancel", this._winUp); document.removeEventListener("visibilitychange", this._resetInput); window.removeEventListener("blur", this._resetInput); window.removeEventListener("pagehide", this._resetInput); document.documentElement.classList.remove("ed-inking"); window.removeEventListener("online", this._online);
    this.pdf?.destroy?.(); this.assetDocs.forEach(d => d.destroy?.()); this.c.innerHTML = ""; this.c.classList.remove("ed");
    this._prev.forEach(u => u && URL.revokeObjectURL(u)); this._prev.clear();
    // der Entwurf liegt schon in IndexedDB; das Senden laeuft weiter, Schliessen und Seitenwechsel warten hoechstens 1,5 s
    if (unsaved) await Promise.race([this.flush(), new Promise(r => setTimeout(r, 1500))]);
  }
}

// ---------------------------------------------------------------- Vorschaubild (für die Bibliothek)
export async function renderThumbnail(fileId, url, chdate, width = 180) {
  const key = `${fileId}:${chdate}:${width}`;
  const cached = await IDB.get("thumbs", key); if (cached) return cached.data;
  try {
    await getPdfjs(); const buf = await (await fetch(url)).arrayBuffer(); const doc = await pdfjsLib.getDocument({ data: buf }).promise; const page = await doc.getPage(1);
    const vp0 = page.getViewport({ scale: 1 }); const vp = page.getViewport({ scale: width / vp0.width }); const cv = document.createElement("canvas"); cv.width = vp.width; cv.height = vp.height;
    await page.render({ canvasContext: cv.getContext("2d"), viewport: vp }).promise; const data = cv.toDataURL("image/jpeg", 0.75); doc.destroy(); IDB.put("thumbs", { key, data, at: Date.now() }); return data;
  } catch { return null; }
}

// ---------------------------------------------------------------- Hilfsfunktionen
function distSeg(px, py, x1, y1, x2, y2) { const dx = x2 - x1, dy = y2 - y1; const l2 = dx * dx + dy * dy; let t = l2 ? ((px - x1) * dx + (py - y1) * dy) / l2 : 0; t = clamp(t, 0, 1); return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy)); }
function pointInPoly(x, y, poly) { let inside = false; for (let i = 0, j = poly.length - 2; i < poly.length; j = i, i += 2) { const xi = poly[i], yi = poly[i + 1], xj = poly[j], yj = poly[j + 1]; if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside; } return inside; }
function safePrompt(msg, def) { try { return window.prompt(msg, def); } catch { return def; } }
function parseRange(s, n) { const out = new Set(); s.split(",").forEach(part => { const m = part.trim().match(/^(\d+)(?:-(\d+))?$/); if (!m) return; const a = +m[1], b = m[2] ? +m[2] : a; for (let i = Math.min(a, b); i <= Math.max(a, b); i++) if (i >= 1 && i <= n) out.add(i - 1); }); return [...out].sort((a, b) => a - b); }
export function md(s) {
  let h = esc(s || "");
  h = h.replace(/```([\s\S]*?)```/g, (_, c) => `<pre>${c}</pre>`).replace(/`([^`]+)`/g, "<code>$1</code>");
  h = h.replace(/^### (.*)$/gm, "<h4>$1</h4>").replace(/^## (.*)$/gm, "<h3>$1</h3>").replace(/^# (.*)$/gm, "<h3>$1</h3>");
  h = h.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/(^|\s)\*(?!\s)(.+?)\*(?=\s|$|[.,;:])/g, "$1<i>$2</i>");
  h = h.replace(/^(?:\s*[-*•] .*(?:\n|$))+/gm, b => `<ul>${b.trim().split(/\n/).map(l => `<li>${l.replace(/^\s*[-*•] /, "")}</li>`).join("")}</ul>`);
  h = h.replace(/^(?:\s*\d+[.)] .*(?:\n|$))+/gm, b => `<ol>${b.trim().split(/\n/).map(l => `<li>${l.replace(/^\s*\d+[.)] /, "")}</li>`).join("")}</ol>`);
  return h.split(/\n{2,}/).map(p => /^<(h\d|ul|ol|pre)/.test(p.trim()) ? p : `<p>${p.replace(/\n/g, "<br>")}</p>`).join("");
}

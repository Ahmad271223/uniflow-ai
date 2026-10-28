// Community im PDF-Editor (Windows-App und Web, 28.10.2026): Loesungen anderer zur offenen PDF, als eigene,
// schreibgeschuetzte Ebene projizieren, liken, Kommentare an einer Stelle der Seite (wie in Word, mit Antworten) und
// eigene Notizen als Loesung teilen (mit Vorschau). Pakete entstehen und oeffnen sich hier im Browser mit WebCrypto
// (app/static/solutions.js), byte-gleich mit dem iPad. Der Dienst sieht nie den Inhalt einer Loesung.
//
// Kommentar-Stelle (Vertrag G4, auch fuer das iPad): `page_key` = Schluessel der Seite IM PAKET (content.pages[].key),
// `anchor` = {x, y} in 0..1 von links oben in der Anzeige des Absenders (dieselben Koordinaten wie die Objekte,
// geteilt durch die angezeigte Seitengroesse). Empfaenger mit anderer Drehung bilden die Stelle wie die Objekte ab.
import { icon } from "./icons.js?v=31";
import * as S from "./solutions.js?v=1";
import { renderLinkCard } from "./studora-link.js?v=4";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const when = iso => { try { return new Date(iso).toLocaleString("de-DE", { day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch { return ""; } };
const REASONS = { offensive: "anstößig", spam: "Spam", foreignMaterial: "Fremdmaterial", gradedSubmission: "benotete Abgabe", other: "Sonstiges" };

async function capi(path, { method = "GET", body } = {}) {
  const r = await fetch("/api/community" + path, { method, headers: body !== undefined ? { "Content-Type": "application/json" } : {}, body: body !== undefined ? JSON.stringify(body) : undefined });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d?.detail || `Community-Fehler ${r.status}`); e.code = d?.code || (r.status === 501 ? "not_hosted" : "http_" + r.status); e.status = r.status; throw e; }
  return d;
}

// Zahlen fremder Objekte endlich und begrenzt lesen (wie ObjectGeometry.number auf dem iPad)
function safeObj(o) {
  const c = JSON.parse(JSON.stringify(o));
  const n = (v, lim, d = 0) => (typeof v === "number" && Number.isFinite(v) ? Math.max(-lim, Math.min(lim, v)) : d);
  for (const k of ["x", "y", "width", "height", "strokeWidth", "fontSize", "lineHeight"]) if (k in c) c[k] = n(c[k], 100000, k === "lineHeight" ? 1.25 : 0);
  for (const k of ["scaleX", "scaleY"]) if (k in c) c[k] = n(c[k], 100, 1);
  if ("rotation" in c) c.rotation = n(c.rotation, 1e6) % 360;
  if ("opacity" in c) c.opacity = Math.max(0, Math.min(1, n(c.opacity, 1, 1)));
  if (Array.isArray(c.points)) c.points = c.points.map(v => n(v, 100000));
  if (Array.isArray(c.widths)) c.widths = c.widths.map(v => n(v, 1000, 1));
  if (Array.isArray(c.crop) || (c.crop && typeof c.crop !== "object")) delete c.crop;
  if (typeof c.text === "string" && c.text.length > 20000) c.text = c.text.slice(0, 20000);
  for (const k of ["color", "fill", "stroke", "bg", "fontFamily"]) if (k in c && typeof c[k] !== "string") delete c[k];
  return c;
}
const dataUrl = img => img ? `data:${img.mime};base64,${img.data}` : null;

async function imageBytes(src) {
  try {
    if (src.startsWith("data:")) { const m = /^data:image\/(?:png|jpeg);base64,(.*)$/.exec(src); const d = m && S.b64decode(m[1]); const mime = d && S.sniffImage(d); return mime ? { mime, data: d } : null; }
    const r = await fetch(src); if (!r.ok) return null;
    const d = new Uint8Array(await r.arrayBuffer()); const mime = S.sniffImage(d); return mime ? { mime, data: d } : null;
  } catch { return null; }
}

export function attach(ed) { return new Community(ed); }

class Community {
  constructor(ed) {
    this.ed = ed; this.el = $(".ed-com", ed.c); this.btn = $('[data-act="community"]', ed.c);
    this.opened = new Map();        // Loesungs-ID -> {summary, content, visible, error, images, local}
    this.comments = new Map();      // Loesungs-ID -> Kommentare
    this.list = null; this.info = null; this.err = null; this.tab = "list"; this.active = null; this.pending = null; this.placing = false;
    this.crypto = !!globalThis.crypto?.subtle;
    this.ready = this.prepare();
    // aus "Gemerkt" oder den Mitteilungen geoeffnet: Leiste gleich zeigen
    try { if (sessionStorage.getItem("open-community")) { sessionStorage.removeItem("open-community"); setTimeout(() => this.toggle(true), 600); } } catch {}
  }
  get available() { return !!(this.ed.pdf && this.ed.pdfBytes); }
  pdfBytes() { return new Uint8Array(this.ed.pdfBytes); }
  visKey() { return `com-vis:${this.fp}`; }
  saveVisible() { try { localStorage.setItem(this.visKey(), JSON.stringify([...this.opened].filter(([, o]) => o.visible && !o.local).map(([id]) => id))); } catch {} }

  async prepare() {
    if (!this.available || !this.crypto) return;
    this.fp = await S.sha256Hex(this.pdfBytes());
    const n = this.ed.pdf.numPages;
    const ps = await Promise.all(Array.from({ length: n }, (_, i) => this.ed.pdf.getPage(i + 1)));
    const info = ps.map(p => ({ width: p.view[2] - p.view[0], height: p.view[3] - p.view[1], rotation: p.rotate || 0 }));
    this.pdfInfo = { pageCount: n, page: i => info[i - 1] || null };
    await this.load(true);
    // zuletzt projizierte Loesungen wieder einblenden
    let vis = []; try { vis = JSON.parse(localStorage.getItem(this.visKey()) || "[]"); } catch {}
    for (const id of vis) if (this.list?.some(s => s.solution_id === id)) await this.project(id, true, true);
  }
  async load(quiet = false) {
    if (!this.fp) return;
    try {
      this.info ||= await capi("/info");
      this.list = (await capi(`/solutions?fingerprint=${this.fp}`)).solutions;
      this.err = null;
    } catch (e) { this.err = e; this.list = this.list || null; }
    this.badge();
    if (!quiet) this.render();
  }
  badge() {
    if (!this.btn) return; let b = $(".ed-badge", this.btn);
    const n = (this.list || []).filter(s => !s.mine).length;
    if (!n) { b?.remove(); return; }
    if (!b) { b = document.createElement("span"); b.className = "ed-badge"; this.btn.append(b); }
    b.textContent = n; this.btn.title = `Community: ${n} Lösung${n === 1 ? "" : "en"} anderer zu dieser PDF`;
  }
  toggle(show) {
    const on = show ?? this.el.hidden; this.el.hidden = !on;
    if (on) { $(".ed-ai", this.ed.c)?.setAttribute("hidden", ""); this.render(); if (!this.list && !this.err) this.ready.then(() => this.render()); }
    else this.stopPlace();
  }

  // ---------------------------------------------------------------- Projizieren
  async openSolution(id) {
    let o = this.opened.get(id);
    if (o?.content) return o;
    const summary = this.list?.find(s => s.solution_id === id) || o?.summary;
    o = { summary, content: null, visible: false, error: null, images: {} };
    this.opened.set(id, o);
    try {
      const { package: pkg } = await capi(`/solutions/${id}`);
      const content = await S.openPackage(pkg, this.pdfBytes(), this.fp);
      const bad = S.mismatch(content, this.pdfInfo);
      if (bad) throw Object.assign(new Error(bad), { code: "mismatch" });
      o.content = content; o.images = content.images;
    } catch (e) { o.error = e.message; }
    return o;
  }
  async project(id, on = true, quiet = false) {
    const o = await this.openSolution(id);
    if (o.error) { if (!quiet) this.render(); return; }
    o.visible = on; this.saveVisible();
    if (on && !this.comments.has(id)) await this.loadComments(id, true);
    this.refreshAll(); if (!quiet) this.render();
  }
  mountPage(pg) {
    if (!pg.foreign) { this.drawMarkers(pg); return; }
    pg.foreign.destroyChildren();
    for (const o of this.opened.values()) if (o.visible && o.content) this.drawOn(pg, o);
    pg.foreign.batchDraw(); this.drawMarkers(pg);
  }
  refreshAll() { this.ed.pages.forEach(pg => this.mountPage(pg)); }
  localRot(pg) { const info = this.pdfInfo?.page(pg.index); return S.normRot((info?.rotation || 0) + (pg.rotation || 0)); }
  solPage(content, pg) { return pg.type === "pdf" ? content.pages.find(p => p.kind === "pdf" && p.pdfIndex === pg.index) : null; }
  drawOn(pg, o) {
    const sp = this.solPage(o.content, pg); if (!sp || !sp.objects.length) return;
    const [a, b, , , tx, ty] = S.transform(sp.width, sp.height, sp.rotation, this.localRot(pg));
    const g = new Konva.Group({ x: tx, y: ty, rotation: Math.round(Math.atan2(b, a) * 180 / Math.PI), listening: false, name: "foreign" });
    for (const raw of sp.objects) {
      if (raw.type === "image" && !o.images[raw.src]) continue;          // fehlendes Bild des Absenders
      try { const n = this.ed.makeNode(pg, safeObj(raw), { image: src => dataUrl(o.images[src]) }); if (n) g.add(n); } catch {}
    }
    pg.foreign.add(g);
  }

  // ---------------------------------------------------------------- Kommentar-Marker auf den Seiten
  markerSolutions() { return [...this.opened].filter(([id, o]) => o.content && (o.visible || id === this.active) && this.comments.has(id)); }
  toLocal(sp, pg, anchor) {
    const [dw, dh] = S.displaySize(sp);
    const [lx, ly] = S.applyT(S.transform(sp.width, sp.height, sp.rotation, this.localRot(pg)), anchor.x * dw, anchor.y * dh);
    return [lx / pg.w, ly / pg.h];
  }
  toSender(sp, pg, fx, fy) {
    const [sx, sy] = S.applyT(S.transform(sp.width, sp.height, this.localRot(pg), sp.rotation), fx * pg.w, fy * pg.h);
    const [dw, dh] = S.displaySize(sp);
    return { x: Math.round(Math.max(0, Math.min(1, sx / dw)) * 10000) / 10000, y: Math.round(Math.max(0, Math.min(1, sy / dh)) * 10000) / 10000 };
  }
  numbered(id) { let n = 0; const out = new Map(); for (const c of this.comments.get(id) || []) if (!c.parent_id && c.anchor) out.set(c.id, ++n); return out; }
  drawMarkers(pg) {
    $$(".ed-cmark", pg.el).forEach(m => m.remove());
    if (pg.type !== "pdf") return;
    for (const [id, o] of this.markerSolutions()) {
      const nums = this.numbered(id);
      for (const c of this.comments.get(id)) {
        if (c.parent_id || !c.anchor || c.deleted && !nums.has(c.id)) continue;
        const sp = o.content.pages.find(p => p.key === c.page_key); if (!sp || sp.kind !== "pdf" || sp.pdfIndex !== pg.index) continue;
        const [fx, fy] = this.toLocal(sp, pg, c.anchor);
        const m = document.createElement("button"); m.className = "ed-cmark" + (id === this.active ? " active" : "") + (this.focus === c.id ? " focus" : "");
        m.style.left = `${fx * 100}%`; m.style.top = `${fy * 100}%`; m.textContent = nums.get(c.id) || "•";
        m.title = `${c.pseudonym}: ${c.text}`.slice(0, 200);
        m.onclick = e => { e.stopPropagation(); this.showComments(id, c.id); };
        pg.el.append(m);
      }
    }
    if (this.pending && this.pending.pg === pg) { const m = document.createElement("span"); m.className = "ed-cmark pending"; m.style.left = `${this.pending.fx * 100}%`; m.style.top = `${this.pending.fy * 100}%`; m.textContent = "+"; pg.el.append(m); }
  }
  startPlace() {
    const o = this.opened.get(this.active); if (!o?.content) return;
    this.placing = true; this.ed.c.classList.add("ed-placing");
    for (const pg of this.ed.pages) {
      const sp = this.solPage(o.content, pg); const d = document.createElement("div");
      d.className = "ed-cplace" + (sp ? "" : " off"); d.title = sp ? "Hier klicken: Kommentar an diese Stelle" : "Diese Seite gehört nicht zur Lösung";
      pg.el.append(d);
    }
    // vor allen Werkzeugen abfangen (der Editor hoert in der Capture-Phase auf dem Scrollbereich): Klick setzt die Stelle
    const stop = e => { if (!e.target.closest?.(".ed-page")) return; e.preventDefault(); e.stopPropagation(); };
    this._placeH = e => {
      const el = e.target.closest?.(".ed-page"); if (!el) return;
      e.preventDefault(); e.stopPropagation();
      const pg = this.ed.pages[+el.dataset.i]; const sp = pg && this.solPage(o.content, pg); if (!sp) return;
      const r = el.getBoundingClientRect(); const fx = (e.clientX - r.left) / r.width, fy = (e.clientY - r.top) / r.height;
      this.pending = { pg, fx, fy, page_key: sp.key, anchor: this.toSender(sp, pg, fx, fy), label: `Seite ${this.ed.pages.indexOf(pg) + 1}` };
      this.stopPlace(); this.drawMarkers(pg); this.render(); setTimeout(() => $(".com-new textarea", this.el)?.focus(), 30);
    };
    this._placeStop = stop;
    this.ed.c.addEventListener("pointerdown", this._placeH, true);
    for (const t of ["mousedown", "touchstart", "pointerup", "click"]) this.ed.c.addEventListener(t, stop, true);
    this.render();
  }
  stopPlace() {
    this.placing = false; this.ed.c.classList.remove("ed-placing"); $$(".ed-cplace", this.ed.c).forEach(d => d.remove());
    if (this._placeH) { this.ed.c.removeEventListener("pointerdown", this._placeH, true); this._placeH = null; }
    if (this._placeStop) { const s = this._placeStop; this._placeStop = null; setTimeout(() => { for (const t of ["mousedown", "touchstart", "pointerup", "click"]) this.ed.c.removeEventListener(t, s, true); }, 400); }
  }

  // ---------------------------------------------------------------- Kommentare
  async loadComments(id, quiet = false) {
    try { this.comments.set(id, (await capi(`/solutions/${id}/comments`)).comments); } catch (e) { if (!quiet) this.toast(e.message); }
  }
  async showComments(id, focus = null) {
    this.active = id; this.tab = "comments"; this.focus = focus; this.toggle(true);
    this.render();
    await this.openSolution(id); await this.loadComments(id, true);
    this.refreshAll(); this.render();
    if (focus) { $(`[data-cid="${focus}"]`, this.el)?.scrollIntoView({ block: "nearest" }); const c = this.comments.get(id)?.find(x => x.id === focus); this.goToComment(id, c); }
  }
  goToComment(id, c) {
    const o = this.opened.get(id); if (!c?.anchor || !o?.content) return;
    const sp = o.content.pages.find(p => p.key === c.page_key); if (!sp) return;
    const i = this.ed.pages.findIndex(pg => pg.type === "pdf" && pg.index === sp.pdfIndex); if (i >= 0 && i !== this.ed.currentPage) this.ed.goToPage(i);
    this.focus = c.id; this.refreshAll();
  }
  pageLabel(id, c) {
    if (!c.page_key) return "";
    const sp = this.opened.get(id)?.content?.pages.find(p => p.key === c.page_key); if (!sp) return "";
    const i = this.ed.pages.findIndex(pg => pg.type === "pdf" && pg.index === sp.pdfIndex);
    return i >= 0 ? `Seite ${i + 1}` : sp.kind === "blank" ? "eigene Seite" : "";
  }
  async send(id, body) {
    try { await capi(`/solutions/${id}/comments`, { method: "POST", body }); this.pending = null; await this.loadComments(id); this.bumpCount(id); this.refreshAll(); this.render(); }
    catch (e) { this.toast(e.message); }
  }
  bumpCount(id) { const s = this.list?.find(x => x.solution_id === id); if (s) s.comments = (this.comments.get(id) || []).filter(c => !c.deleted).length; }

  // ---------------------------------------------------------------- Oberflaeche
  toast(msg) { const t = $(".com-toast", this.el); if (!t) return; t.textContent = msg; t.hidden = false; clearTimeout(this._tt); this._tt = setTimeout(() => t.hidden = true, 6000); }
  async render() {
    if (this.el.hidden) return;
    const head = `<div class="com-head"><strong>${icon("users", 16)} Community</strong><span class="spacer"></span><button class="btn ghost icon sm" data-c="reload" title="Neu laden">${icon("refresh", 15)}</button><button class="btn ghost icon sm" data-c="close" title="Schließen">${icon("x", 16)}</button></div>`;
    const tabs = `<div class="seg com-tabs"><button class="${this.tab === "list" ? "active" : ""}" data-tab="list">Lösungen${this.list ? ` (${this.list.length})` : ""}</button>${this.active ? `<button class="${this.tab === "comments" ? "active" : ""}" data-tab="comments">Kommentare</button>` : ""}<button class="${this.tab === "questions" ? "active" : ""}" data-tab="questions">Fragen</button><button class="${this.tab === "share" ? "active" : ""}" data-tab="share">${icon("share", 13)} Teilen</button></div>`;
    let body;
    if (!this.available) body = `<p class="small muted">Die Community gibt es für PDF-Dateien aus deinem Hochschul-Abgleich. Dieses Dokument ist keine PDF.</p>`;
    else if (!this.crypto) body = `<p class="small muted">Lösungen werden verschlüsselt geöffnet. Das geht in der Windows-App und im Browser über https, nicht über eine einfache WLAN-Adresse.</p>`;
    else if (!this.list && !this.err) body = `<p class="small muted">Lade Lösungen …</p>`;
    else if (this.err && !this.list) body = this.errorBody();
    else body = tabs + (this.tab === "share" ? this.shareBody() : this.tab === "questions" ? `<div class="com-qa small muted">Lade Fragen …</div>` : this.tab === "comments" && this.active ? this.commentsBody() : this.listBody());
    this.el.innerHTML = head + `<div class="com-body">${body}</div><div class="com-toast small" hidden></div>`;
    this.bind();
    const lc = $(".com-link", this.el); if (lc) renderLinkCard(lc, { compact: true, onChange: () => { this.info = null; this.err = null; this.list = null; this.load(); } });
    if (this.tab === "share" && this.list) this.renderPreviews();
    if (this.tab === "questions") this.renderQA();
  }
  errorBody() {
    const e = this.err;
    if (e.code === "not_linked") return `<div class="com-link"></div>`;
    if (e.code === "file_not_owned") return `<p class="small">${icon("info", 14)} Diese PDF stammt nicht aus deinem Hochschul-Abgleich. Lösungen gibt es nur für Dateien aus Stud.IP oder Learnweb, damit nur Kursteilnehmer sie sehen.</p><button class="btn sm" data-c="claims">${icon("sync", 13)} Meine PDFs jetzt melden</button><div class="com-link" style="margin-top:.8rem"></div>`;
    if (e.code === "university_mismatch" || e.code === "service_unreachable") return `<p class="small">${icon("alert", 14)} ${esc(e.message)}</p><button class="btn sm" data-c="reload">Erneut versuchen</button><div class="com-link" style="margin-top:.8rem"></div>`;
    if (e.code === "not_hosted") return `<p class="small muted">Die Community läuft über den Studora-Dienst.</p>`;
    return `<p class="small">${icon("alert", 14)} ${esc(e.message)}</p><button class="btn sm" data-c="reload">Erneut versuchen</button>`;
  }
  listBody() {
    const own = [...this.opened].filter(([, o]) => o.local);
    const items = (this.list || []).map(s => {
      const o = this.opened.get(s.solution_id); const vis = !!o?.visible;
      return `<div class="com-sol${vis ? " on" : ""}">
        <div class="com-sol-title"><b>${esc(s.title || (s.display_name ? `Lösung von ${s.display_name}` : "Lösung"))}</b>${s.mine ? ` <span class="badge neutral">deine</span>` : ""}</div>
        <div class="tiny muted">${esc(s.display_name || s.pseudonym)}${s.display_name ? ` · ${esc(s.pseudonym)}` : ""} · ${when(s.published_at)} · ${s.pages} Seite${s.pages === 1 ? "" : "n"}</div>
        <div class="com-sol-act">
          <button class="btn sm ${vis ? "primary" : ""}" data-proj="${s.solution_id}" title="Als eigene Ebene über deine PDF legen (deine Notizen bleiben unverändert)">${icon(vis ? "eye-off" : "eye", 14)} ${vis ? "Ausblenden" : "Projizieren"}</button>
          <button class="btn sm ghost com-like${s.liked_by_me ? " liked" : ""}" data-like="${s.solution_id}" ${s.mine ? 'disabled title="Die eigene Lösung lässt sich nicht liken"' : `title="${s.liked_by_me ? "Gefällt mir nicht mehr" : "Gefällt mir"}"`}>${icon("heart", 14)} ${s.likes ?? 0}</button>
          <button class="btn sm ghost" data-com="${s.solution_id}" title="Kommentare">${icon("message", 14)} ${s.comments ?? 0}</button>
          <button class="btn sm ghost icon" data-bm="${s.solution_id}" title="Merken (Community → Gemerkt)" aria-label="Merken">${icon("bookmark", 14)}</button>
          ${s.mine ? "" : `<button class="btn sm ghost icon" data-more="${s.solution_id}" title="Melden oder Autor sperren" aria-label="Melden oder Autor sperren">${icon("more", 14)}</button>`}
        </div>${o?.error ? `<div class="com-err small">${icon("alert", 13)} ${esc(o.error)}</div>` : ""}</div>`;
    }).join("");
    const local = own.map(([id, o]) => `<div class="com-sol${o.visible ? " on" : ""}"><div class="com-sol-title"><b>${esc(o.content.title || "Lösung aus Datei")}</b> <span class="badge neutral">Datei</span></div><div class="tiny muted">${esc(o.content.displayName || "anonym")} · ${when(o.content.createdAt)}</div><div class="com-sol-act"><button class="btn sm ${o.visible ? "primary" : ""}" data-lproj="${id}">${icon(o.visible ? "eye-off" : "eye", 14)} ${o.visible ? "Ausblenden" : "Projizieren"}</button><button class="btn sm ghost" data-ldel="${id}">${icon("x", 14)} Entfernen</button></div></div>`).join("");
    return `${this.err ? `<div class="com-err small">${esc(this.err.message)}</div>` : ""}
      ${items || `<p class="small muted">Zu dieser PDF hat noch niemand eine Lösung geteilt. Teile deine eigene im Reiter „Teilen“.</p>`}${local}
      <label class="btn sm ghost com-file">${icon("upload", 13)} Lösung aus Datei öffnen<input type="file" accept=".uniflowsolution,application/json" hidden></label>
      <p class="tiny muted">Meistgelikte zuerst. Öffnen kann eine Lösung nur, wer dieselbe Original-PDF hat; sie wird hier im Arbeitsspeicher entschlüsselt.</p>`;
  }
  commentsBody() {
    const id = this.active; const s = this.list?.find(x => x.solution_id === id); const o = this.opened.get(id);
    const list = this.comments.get(id); const nums = this.numbered(id); const canC = !!this.info?.can_comment;
    const card = (c, reply) => `<div class="com-c${reply ? " reply" : ""}${this.focus === c.id ? " focus" : ""}" data-cid="${c.id}" ${c.anchor ? `data-goto="${c.id}"` : ""}>
      <div class="com-c-head">${!reply && nums.has(c.id) ? `<span class="com-num">${nums.get(c.id)}</span>` : ""}<b>${esc(c.pseudonym)}</b>${c.by_author ? ` <span class="badge neutral">Autor</span>` : ""}<span class="tiny muted">${when(c.created_at)}${c.edited_at ? " · bearbeitet" : ""}${this.pageLabel(id, c) ? ` · ${this.pageLabel(id, c)}` : ""}</span></div>
      <div class="com-c-text">${c.deleted ? `<i class="muted">Kommentar gelöscht</i>` : esc(c.text).replace(/\n/g, "<br>")}</div>
      ${c.deleted ? "" : `<div class="com-c-act">${!reply && canC ? `<button class="btn ghost sm" data-reply="${c.id}">${icon("reply", 12)} Antworten</button>` : ""}${c.mine ? `<button class="btn ghost sm" data-edit="${c.id}">Bearbeiten</button>` : ""}${c.mine || s?.mine ? `<button class="btn ghost sm" data-cdel="${c.id}">Löschen</button>` : ""}${c.mine ? "" : `<button class="btn ghost sm" data-crep="${c.id}">Melden</button>`}</div>`}
      ${this.replyTo === c.id ? `<div class="com-new"><textarea rows="2" maxlength="${this.info?.max_comment || 2000}" placeholder="Antwort …"></textarea><div class="row"><button class="btn sm primary" data-send="reply">Antworten</button><button class="btn sm ghost" data-cancel>Abbrechen</button></div></div>` : ""}</div>`;
    const threads = (list || []).filter(c => !c.parent_id).map(t => card(t, false) + list.filter(r => r.parent_id === t.id).map(r => card(r, true)).join("")).join("");
    return `<div class="com-sol-title" style="margin:.2rem 0 .4rem"><button class="btn ghost sm" data-tab="list">${icon("chevron-left", 13)}</button><b>${esc(s?.title || s?.display_name || "Lösung")}</b></div>
      ${o?.error ? `<div class="com-err small">${esc(o.error)}</div>` : ""}
      ${canC ? (this.pending ? `<div class="com-new"><div class="tiny muted">${icon("map-pin", 12)} Kommentar an markierter Stelle (${esc(this.pending.label)})</div><textarea rows="3" maxlength="${this.info?.max_comment || 2000}" placeholder="Was ist dir an dieser Stelle aufgefallen?"></textarea><div class="row"><button class="btn sm primary" data-send="anchor">Kommentieren</button><button class="btn sm ghost" data-cancel>Abbrechen</button></div></div>`
        : `<div class="row wrap" style="gap:.4rem"><button class="btn sm${this.placing ? " primary" : ""}" data-c="place" ${o?.content ? "" : "disabled"}>${icon("map-pin", 13)} ${this.placing ? "Klicke auf die Stelle …" : "An Stelle kommentieren"}</button><button class="btn sm ghost" data-c="general">${icon("message", 13)} Allgemein</button></div>
          ${this.general ? `<div class="com-new"><textarea rows="3" maxlength="${this.info?.max_comment || 2000}" placeholder="Kommentar zur ganzen Lösung"></textarea><div class="row"><button class="btn sm primary" data-send="general">Kommentieren</button><button class="btn sm ghost" data-cancel>Abbrechen</button></div></div>` : ""}`)
        : `<p class="tiny muted">${icon("info", 12)} Lesen kann jeder; kommentieren geht ab Studora Plus mit bestätigter E-Mail.</p>`}
      <div class="com-threads">${list ? threads || `<p class="small muted">Noch keine Kommentare.${canC ? " Setze den ersten an eine Stelle der Seite." : ""}</p>` : `<p class="small muted">Lade Kommentare …</p>`}</div>`;
  }
  shareRows() {
    return this.ed.model.pageOrder.map((p, i) => {
      const n = this.ed.model.pages[p.key]?.objects?.length || 0; const ok = S.shareable(p);
      return { key: p.key, i, n, ok, label: (p.type || "pdf") === "pdf" ? `Seite ${i + 1}` : p.type === "blank" ? `Seite ${i + 1} (eigene Seite)` : `Seite ${i + 1} (eingefügt)` };
    });
  }
  shareBody() {
    const rows = this.shareRows(); this.shareSel ||= new Set(rows.filter(r => r.ok && r.n).map(r => r.key));
    const sel = rows.filter(r => this.shareSel.has(r.key) && r.ok); const objs = sel.reduce((a, r) => a + r.n, 0);
    const canShare = this.info?.can_share;
    return `<p class="small muted" style="margin-top:.2rem">Geteilt werden nur deine eigenen Notizen der gewählten Seiten, nie die PDF. Andere sehen sie nur, wenn sie dieselbe Original-PDF haben.</p>
      <label class="small">Titel<input class="input" data-f="title" maxlength="200" value="${esc(this.shareTitle ?? this.ed.name.replace(/\.pdf$/i, ""))}"></label>
      <label class="small">Anzeigename <span class="muted">(leer = nur dein Pseudonym${this.info?.pseudonym ? ` ${esc(this.info.pseudonym)}` : ""})</span><input class="input" data-f="name" maxlength="60" value="${esc(this.shareName || "")}"></label>
      <div class="com-pages">${rows.map(r => `<label class="small ${r.ok ? "" : "muted"}" title="${r.ok ? "" : "Eingefügte Bild- oder PDF-Seiten werden nie geteilt"}"><input type="checkbox" data-pg="${esc(r.key)}" ${r.ok ? "" : "disabled"} ${r.ok && this.shareSel.has(r.key) ? "checked" : ""}> ${esc(r.label)} <span class="muted">· ${r.n} Objekt${r.n === 1 ? "" : "e"}</span></label>`).join("")}</div>
      <div class="small"><b>Vorschau</b> <span class="muted">(so sehen andere deine Notizen, ohne Original)</span> · ${sel.length} Seite${sel.length === 1 ? "" : "n"}, ${objs} Objekte</div>
      <div class="com-prev"></div>
      <div class="row wrap" style="gap:.4rem;margin-top:.5rem"><button class="btn sm primary" data-c="publish" ${sel.length && objs && canShare ? "" : "disabled"}>${icon("share", 13)} Veröffentlichen</button><button class="btn sm" data-c="savefile" ${sel.length && objs ? "" : "disabled"}>${icon("download", 13)} Als Datei</button></div>
      ${canShare ? "" : `<p class="tiny muted">Veröffentlichen gibt es ab Studora Plus mit bestätigter E-Mail. Als Datei geht es immer (z. B. per Mail an Kommilitonen).</p>`}
      <div class="com-share-msg small"></div>`;
  }
  async renderQA() {
    // Fragen im Kurs dieser PDF (Kurs-Schluessel wie auf dem iPad), mit "nur zu dieser PDF" und Frage zur aktuellen Seite
    const box = $(".com-qa", this.el); if (!box) return;
    try {
      const f = await (await fetch(`/api/files/${encodeURIComponent(this.ed.fileId)}`)).json();
      const q = await import("./views-qa.js?v=2");
      const courses = await q.courseKeys(); const c = courses.find(x => x.course_id === f.course_id);
      if (!c) { box.textContent = "Diese Datei gehört zu keinem deiner Kurse; Fragen gibt es je Kurs."; return; }
      const pg = this.ed.pages[this.ed.currentPage];
      q.renderQuestions(box, { courseKey: c.key, fingerprint: this.fp, page: pg?.type === "pdf" ? pg.index : undefined });
    } catch (e) { box.textContent = e.message; }
  }
  async renderPreviews() {
    const box = $(".com-prev", this.el); if (!box || !window.Konva) return;
    const token = (this._prevTok = (this._prevTok || 0) + 1);
    const rows = this.shareRows().filter(r => r.ok && this.shareSel.has(r.key)).slice(0, 8);
    box.innerHTML = rows.map(r => `<figure data-pv="${esc(r.key)}"><div class="com-pv-img"></div><figcaption class="tiny muted">${esc(r.label)}</figcaption></figure>`).join("") + (this.shareSel.size > 8 ? `<span class="tiny muted">… und ${this.shareSel.size - 8} weitere</span>` : "");
    for (const r of rows) {
      const entry = this.ed.model.pageOrder[r.i]; const pg = this.ed.pages[r.i]; if (!pg) continue;
      const W = pg.w, H = pg.h, sc = 132 / Math.max(W, H);
      const holder = document.createElement("div"); const stage = new Konva.Stage({ container: holder, width: Math.round(W * sc), height: Math.round(H * sc) });
      stage.scale({ x: sc, y: sc }); const layer = new Konva.Layer(); stage.add(layer);
      layer.add(new Konva.Rect({ x: 0, y: 0, width: W, height: H, fill: "#fff" }));
      for (const o of this.ed.model.pages[entry.key]?.objects || []) { try { const n = this.ed.makeNode(pg, safeObj(o), { image: src => src }); if (n) layer.add(n); } catch {} }
      await new Promise(res => setTimeout(res, 250)); if (token !== this._prevTok) { stage.destroy(); return; }
      layer.draw(); const url = stage.toDataURL({ pixelRatio: 1.5 }); stage.destroy();
      const f = $(`[data-pv="${CSS.escape(r.key)}"] .com-pv-img`, box); if (f) f.innerHTML = `<img alt="" src="${url}">`;
    }
  }
  async buildPackage() {
    const keys = this.ed.model.pageOrder.map(p => p.key).filter(k => this.shareSel.has(k));
    const srcs = S.imageSources(this.ed.model, keys); const images = {};
    for (const src of srcs) { const b = await imageBytes(src); if (b) images[src] = b; }
    const content = S.buildContent({ model: this.ed.model, selectedKeys: keys, pdfPageCount: this.pdfInfo.pageCount, pdfPage: i => this.pdfInfo.page(i),
                                     images, fingerprint: this.fp, title: this.shareTitle ?? this.ed.name.replace(/\.pdf$/i, ""), displayName: this.shareName || "" });
    return { content, pkg: await S.seal(content, this.pdfBytes()) };
  }

  bind() {
    const el = this.el; const msg = t => { const m = $(".com-share-msg", el); if (m) m.textContent = t; };
    $$("[data-c]", el).forEach(b => b.onclick = async () => {
      const c = b.dataset.c;
      if (c === "close") return this.toggle(false);
      if (c === "reload") { this.err = null; this.info = null; this.list = null; this.render(); return this.load(); }
      if (c === "claims") { b.disabled = true; try { await fetch("/api/studora/claims", { method: "POST" }); } catch {} this.err = null; return this.load(); }
      if (c === "place") { if (this.placing) { this.stopPlace(); this.render(); } else this.startPlace(); return; }
      if (c === "general") { this.general = !this.general; this.render(); return; }
      if (c === "publish" || c === "savefile") {
        b.disabled = true; msg(c === "publish" ? "Verschlüssele und veröffentliche …" : "Verschlüssele …");
        try {
          const { content, pkg } = await this.buildPackage();
          if (c === "savefile") {
            const url = URL.createObjectURL(new Blob([S.encodePackage(pkg)], { type: "application/json" }));
            const a = document.createElement("a"); a.href = url; a.download = `${(content.title || "Lösung").replace(/[\\/:*?"<>|]+/g, "_")}.uniflowsolution`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 20000);
            msg(`Datei erstellt: ${content.pages.length} Seiten${content.missingImages.length ? `, ${content.missingImages.length} Bild(er) nicht verfügbar` : ""}.`);
          } else {
            await capi("/solutions", { method: "POST", body: { package: pkg, title: content.title || null } });
            msg("Veröffentlicht. Andere mit derselben PDF sehen deine Lösung jetzt."); this.tab = "list"; await this.load();
          }
        } catch (e) { msg(e.message); }
        b.disabled = false;
      }
    });
    $$("[data-tab]", el).forEach(b => b.onclick = () => { this.tab = b.dataset.tab; if (this.tab !== "comments") this.stopPlace(); this.render(); });
    $$("[data-proj]", el).forEach(b => b.onclick = async () => { b.disabled = true; const id = b.dataset.proj; await this.project(id, !this.opened.get(id)?.visible); });
    $$("[data-like]", el).forEach(b => b.onclick = async () => {
      const s = this.list.find(x => x.solution_id === b.dataset.like); b.disabled = true;
      try { const r = await capi(`/solutions/${s.solution_id}/like`, { method: s.liked_by_me ? "DELETE" : "POST" }); s.liked_by_me = !s.liked_by_me; s.likes = r?.likes ?? s.likes; } catch (e) { this.toast(e.message); }
      this.render();
    });
    $$("[data-com]", el).forEach(b => b.onclick = () => this.showComments(b.dataset.com));
    $$("[data-bm]", el).forEach(b => b.onclick = async () => { try { await capi(`/bookmarks/solution/${b.dataset.bm}`, { method: "POST" }); this.toast("Gemerkt – zu finden unter Community → Gemerkt."); } catch (e) { this.toast(e.message); } });
    $$("[data-more]", el).forEach(b => b.onclick = async () => {
      const id = b.dataset.more; const pick = prompt(`Melden (Grund eingeben: ${Object.values(REASONS).join(", ")}) oder „sperren“, um Lösungen dieses Autors nicht mehr zu sehen:`);
      if (!pick) return; const p = pick.trim().toLowerCase();
      try {
        if (p.startsWith("sperr")) { await capi(`/solutions/${id}/block`, { method: "POST" }); this.opened.delete(id); this.refreshAll(); this.toast("Autor gesperrt."); }
        else { const reason = Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.slice(0, 4))) || "other"; await capi(`/solutions/${id}/report`, { method: "POST", body: { reason, note: reason === "other" ? pick.slice(0, 300) : null } }); this.toast("Gemeldet. Danke!"); }
        await this.load();
      } catch (e) { this.toast(e.message); }
    });
    const file = $(".com-file input", el);
    if (file) file.onchange = async () => {
      const f = file.files[0]; if (!f) return;
      try {
        const content = await S.openPackage(await f.text(), this.pdfBytes(), this.fp);
        const bad = S.mismatch(content, this.pdfInfo); if (bad) throw new Error(bad);
        this.opened.set(content.solutionId, { content, visible: true, images: content.images, local: true }); this.refreshAll(); this.render();
      } catch (e) { this.toast(e.message); }
    };
    $$("[data-lproj]", el).forEach(b => b.onclick = () => { const o = this.opened.get(b.dataset.lproj); o.visible = !o.visible; this.refreshAll(); this.render(); });
    $$("[data-ldel]", el).forEach(b => b.onclick = () => { this.opened.delete(b.dataset.ldel); this.refreshAll(); this.render(); });
    // Kommentare
    $$("[data-goto]", el).forEach(d => d.onclick = e => { if (e.target.closest("button, textarea")) return; const c = this.comments.get(this.active)?.find(x => x.id === d.dataset.goto); this.goToComment(this.active, c); this.render(); });
    $$("[data-reply]", el).forEach(b => b.onclick = () => { this.replyTo = b.dataset.reply; this.render(); setTimeout(() => $(`[data-cid="${this.replyTo}"] textarea`, el)?.focus(), 20); });
    $$("[data-cancel]", el).forEach(b => b.onclick = () => { const pg = this.pending?.pg; this.pending = null; this.replyTo = null; this.general = false; if (pg) this.drawMarkers(pg); this.render(); });
    $$("[data-send]", el).forEach(b => b.onclick = async () => {
      const text = b.closest(".com-new").querySelector("textarea").value.trim(); if (!text) return; b.disabled = true;
      const k = b.dataset.send; const id = this.active;
      const body = k === "anchor" ? { text, page_key: this.pending.page_key, anchor: this.pending.anchor } : k === "reply" ? { text, parent_id: this.replyTo } : { text };
      if (k === "reply") this.replyTo = null; if (k === "general") this.general = false;
      await this.send(id, body);
    });
    $$("[data-edit]", el).forEach(b => b.onclick = async () => {
      const c = this.comments.get(this.active).find(x => x.id === b.dataset.edit); const t = prompt("Kommentar bearbeiten:", c.text); if (t === null || !t.trim()) return;
      try { await capi(`/comments/${c.id}`, { method: "PATCH", body: { text: t.trim() } }); await this.loadComments(this.active); this.refreshAll(); this.render(); } catch (e) { this.toast(e.message); }
    });
    $$("[data-cdel]", el).forEach(b => b.onclick = async () => {
      if (!confirm("Kommentar löschen?")) return;
      try { await capi(`/comments/${b.dataset.cdel}`, { method: "DELETE" }); await this.loadComments(this.active); this.bumpCount(this.active); this.refreshAll(); this.render(); } catch (e) { this.toast(e.message); }
    });
    $$("[data-crep]", el).forEach(b => b.onclick = async () => {
      const p = prompt(`Kommentar melden – Grund (${Object.values(REASONS).join(", ")}):`, "anstößig"); if (!p) return;
      const reason = Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.trim().toLowerCase().slice(0, 4))) || "other";
      try { await capi(`/comments/${b.dataset.crep}/report`, { method: "POST", body: { reason } }); this.toast("Gemeldet. Danke!"); } catch (e) { this.toast(e.message); }
    });
    // Teilen
    $$("[data-pg]", el).forEach(c => c.onchange = () => { c.checked ? this.shareSel.add(c.dataset.pg) : this.shareSel.delete(c.dataset.pg); this.render(); });
    const t = $('[data-f="title"]', el); if (t) t.oninput = () => this.shareTitle = t.value;
    const n = $('[data-f="name"]', el); if (n) n.oninput = () => this.shareName = n.value;
  }
}

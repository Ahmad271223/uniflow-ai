// Werkzeuge der Community im PDF-Editor (editor-community.js): "Korrektur vorschlagen" (eigene Ebene mit Strichen und
// Randnotizen ueber der projizierten Loesung, Entwurf, Schicken) und "Daneben ansehen" (fremde Loesung neben dem Dokument,
// nur ansehen, die eigene PDF darunter). Gegenstueck zu CorrectionMode.swift und SolutionSidePane auf dem iPad.
import { icon } from "./icons.js?v=31";
import * as S from "./solutions.js?v=6";
import * as C from "./community-corrections.js?v=1";
import * as U from "./community-corrections-ui.js?v=1";
import { loadSpaces } from "./community-spaces.js?v=14";
import { capi } from "./views-qa.js?v=4";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const COLORS = ["#e5322d", "#1f6fe0", "#1f9d5b"];
const uid = () => (globalThis.crypto?.randomUUID?.() || S.uuid()).slice(0, 12);

/** Passt eine Korrektur zur eigenen PDF (Seitengroesse < 0,5 pt)? Meldung oder null. */
export function fits(content, pdfInfo) {
  for (const p of content.pages) {
    const i = pdfInfo.page(p.pdfIndex);
    if (!i || Math.abs(i.width - p.width) >= 0.5 || Math.abs(i.height - p.height) >= 0.5) return "Die Korrektur passt nicht zu deiner PDF (andere Fassung der Datei).";
  }
  return null;
}

// ================================================================ Korrektur schreiben
export class CorrectionMode {
  /** `summary`: Eintrag der Loesung aus /solutions (title, pseudonym, community_key). */
  constructor(com, summary) {
    this.com = com; this.ed = com.ed; this.sum = summary; this.sid = summary.solution_id;
    this.tool = "pen"; this.color = COLORS[0]; this.finger = false; this.pages = new Map(); this.note = ""; this.history = []; this.live = null; this.busy = false; this.msg = "";
    this.key = `cc-draft:${this.sid}`;
    try { const d = JSON.parse(localStorage.getItem(this.key) || "null"); if (d) { this.note = d.note || ""; (d.pages || []).forEach(p => this.pages.set(p.pdfIndex, p)); } } catch { /* ohne Entwurf */ }
    this.onDown = e => this.down(e); this.onStop = e => { if (e.target.closest?.(".ed-corr")) { e.stopPropagation(); } };
    this.ed.c.addEventListener("pointerdown", this.onDown, true);
    for (const t of ["mousedown", "touchstart", "pointerup", "click"]) this.ed.c.addEventListener(t, this.onStop, true);
    this.ed.c.classList.add("ed-correcting");
    this.ed.pages.forEach(pg => this.mount(pg));
  }
  stop() {
    this.ed.c.removeEventListener("pointerdown", this.onDown, true);
    for (const t of ["mousedown", "touchstart", "pointerup", "click"]) this.ed.c.removeEventListener(t, this.onStop, true);
    this.ed.c.classList.remove("ed-correcting");
    $$(".ed-corr, .ed-cmark.corr.mine", this.ed.c).forEach(n => n.remove());
  }
  data(pg) {
    const info = this.com.pdfInfo.page(pg.index);
    let d = this.pages.get(pg.index);
    if (!d) { d = { pdfIndex: pg.index, width: info.width, height: info.height, rotation: this.com.localRot(pg), strokes: [], notes: [] }; this.pages.set(pg.index, d); }
    return d;
  }
  get strokeTotal() { return [...this.pages.values()].reduce((n, p) => n + p.strokes.length, 0); }
  get noteTotal() { return [...this.pages.values()].reduce((n, p) => n + p.notes.length, 0); }
  save() {
    try {
      const pages = [...this.pages.values()].filter(p => p.strokes.length || p.notes.length);
      if (!pages.length && !this.note.trim()) localStorage.removeItem(this.key); else localStorage.setItem(this.key, JSON.stringify({ note: this.note, pages }));
    } catch { /* ohne Speicher */ }
  }
  discard() { try { localStorage.removeItem(this.key); } catch { /* egal */ } this.pages.clear(); this.history = []; this.note = ""; }

  // ---- Ebene auf den Seiten
  mount(pg) {
    if (pg.type !== "pdf" || !this.com.pdfInfo?.page(pg.index)) return;
    let cv = $(".ed-corr", pg.el);
    if (!cv) { cv = document.createElement("canvas"); cv.className = "ed-corr"; pg.el.append(cv); }
    cv.classList.toggle("note", this.tool === "note");
    const r = pg.el.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
    cv.width = Math.max(1, Math.round(r.width * dpr)); cv.height = Math.max(1, Math.round(r.height * dpr));
    cv.style.touchAction = this.finger ? "none" : "pan-x pan-y pinch-zoom";
    this.paint(pg, cv);
    $$(".ed-cmark.corr.mine", pg.el).forEach(n => n.remove());
    (this.pages.get(pg.index)?.notes || []).forEach((n, i) => {
      const m = document.createElement("button"); m.className = "ed-cmark corr mine"; m.style.left = `${n.x * 100}%`; m.style.top = `${n.y * 100}%`; m.textContent = i + 1; m.title = n.text;
      m.onclick = ev => { ev.stopPropagation(); this.editNote(pg, n); }; pg.el.append(m);
    });
  }
  paint(pg, cv = $(".ed-corr", pg.el)) {
    if (!cv) return;
    const ctx = cv.getContext("2d"); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height);
    ctx.scale(cv.width / pg.w, cv.height / pg.h);
    const objects = [...(this.pages.get(pg.index)?.strokes || []), ...(this.live && this.live.pg === pg ? [this.live.obj] : [])];
    S.drawObjects(ctx, { objects }, {});
  }
  point(e, pg) {
    const r = pg.el.getBoundingClientRect();
    return [Math.round((e.clientX - r.left) / r.width * pg.w * 100) / 100, Math.round((e.clientY - r.top) / r.height * pg.h * 100) / 100];
  }
  down(e) {
    const cv = e.target.closest?.(".ed-corr"); if (!cv) return;
    const pg = this.ed.pages.find(p => p.el === cv.parentElement); if (!pg) return;
    if (e.pointerType === "touch" && !this.finger) { e.stopPropagation(); return; }     // Finger blaettert, ausser "Mit dem Finger zeichnen" ist an
    e.preventDefault(); e.stopPropagation();
    if (this.tool === "note") { this.addNote(pg, ...this.fraction(e, pg)); return; }
    const marker = this.tool === "marker";
    const obj = { id: uid(), type: "stroke", tool: this.tool, color: marker ? "#ffd60a" : this.color, width: marker ? 14 : 2.4, opacity: marker ? 0.35 : 1, points: [...this.point(e, pg)], x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1 };
    this.live = { pg, obj };
    const move = ev => { if (ev.pointerId !== e.pointerId) return; const [x, y] = this.point(ev, pg), n = obj.points.length; if (Math.hypot(x - obj.points[n - 2], y - obj.points[n - 1]) >= 0.4) { obj.points.push(x, y); this.paint(pg); } };
    const up = ev => {
      if (ev.pointerId !== e.pointerId) return;
      window.removeEventListener("pointermove", move, true); window.removeEventListener("pointerup", up, true); window.removeEventListener("pointercancel", up, true);
      if (obj.points.length === 2) obj.points.push(obj.points[0] + 0.05, obj.points[1] + 0.05);
      this.live = null; this.data(pg).strokes.push(obj); this.history.push({ pdfIndex: pg.index, id: obj.id, kind: "stroke" }); this.paint(pg); this.changed();
    };
    window.addEventListener("pointermove", move, true); window.addEventListener("pointerup", up, true); window.addEventListener("pointercancel", up, true);
  }
  fraction(e, pg) { const r = pg.el.getBoundingClientRect(); return [Math.round((e.clientX - r.left) / r.width * 10000) / 10000, Math.round((e.clientY - r.top) / r.height * 10000) / 10000]; }
  addNote(pg, x, y) {
    const t = (prompt(`Randnotiz (höchstens ${C.MAX_TEXT} Zeichen):`) || "").trim(); if (!t) return;
    const n = { id: uid(), x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)), text: t.slice(0, C.MAX_TEXT) };
    this.data(pg).notes.push(n); this.history.push({ pdfIndex: pg.index, id: n.id, kind: "note" }); this.mount(pg); this.changed();
  }
  editNote(pg, n) {
    const t = prompt("Randnotiz bearbeiten (leer = löschen):", n.text); if (t === null) return;
    const d = this.data(pg);
    if (!t.trim()) { d.notes = d.notes.filter(x => x !== n); this.history = this.history.filter(h => h.id !== n.id); } else n.text = t.trim().slice(0, C.MAX_TEXT);
    this.mount(pg); this.changed();
  }
  undo() {
    const h = this.history.pop(); if (!h) return;
    const d = this.pages.get(h.pdfIndex); if (!d) return;
    if (h.kind === "stroke") d.strokes = d.strokes.filter(s => s.id !== h.id); else d.notes = d.notes.filter(n => n.id !== h.id);
    const pg = this.ed.pages.find(p => p.type === "pdf" && p.index === h.pdfIndex); if (pg) this.mount(pg);
    this.changed();
  }
  changed() { this.save(); const s = $(".cc-sum", this.com.el); if (s) s.textContent = this.summary(); const b = $("[data-corr='send']", this.com.el); if (b) b.disabled = this.empty || this.busy; }
  get empty() { return !this.strokeTotal && !this.noteTotal && !this.note.trim(); }
  summary() { return `${C.strokes(this.strokeTotal)} · ${C.notes(this.noteTotal)}`; }

  // ---- Leiste
  body() {
    const t = this.tool;
    return `<div class="com-sol-title" style="margin:.2rem 0"><b>${icon("pencil", 14)} ${C.TEXTS.action}</b></div>
      <p class="small muted" style="margin:0">Zu „${esc(this.sum.title || this.sum.display_name || "Lösung")}“ von ${esc(this.sum.display_name || this.sum.pseudonym)}. Du markierst in deiner PDF über der Lösung; die Lösung selbst bleibt unverändert.</p>
      <div class="cc-tools" role="toolbar" aria-label="Korrektur-Werkzeuge">
        <button class="btn sm${t === "pen" ? " active" : ""}" data-corr="pen" aria-pressed="${t === "pen"}">${icon("pen", 13)} Stift</button>
        <button class="btn sm${t === "marker" ? " active" : ""}" data-corr="marker" aria-pressed="${t === "marker"}">${icon("highlighter", 13)} Marker</button>
        <button class="btn sm${t === "note" ? " active" : ""}" data-corr="note" aria-pressed="${t === "note"}">${icon("message", 13)} Randnotiz</button>
        <button class="btn sm ghost" data-corr="undo" title="Letzte Markierung zurücknehmen">${icon("undo", 13)} Zurück</button>
        ${COLORS.map(c => `<button class="cc-col btn${this.color === c && t === "pen" ? " active" : ""}" data-corr-color="${c}" style="background:${c}" aria-label="Farbe ${c}"></button>`).join("")}</div>
      <label class="small row" style="gap:.35rem;align-items:center"><input type="checkbox" data-corr="finger" ${this.finger ? "checked" : ""}> Mit dem Finger zeichnen</label>
      <div class="small cc-sum" aria-live="polite">${esc(this.summary())}</div>
      <label class="small">Begleittext an den Ersteller <span class="muted">(optional)</span><textarea class="input" data-corr="note" rows="3" maxlength="${C.MAX_TEXT}" placeholder="Steht über deiner Korrektur. Höchstens ${C.MAX_TEXT} Zeichen.">${esc(this.note)}</textarea></label>
      <div class="row wrap" style="gap:.4rem"><button class="btn sm primary" data-corr="send" ${this.empty || this.busy ? "disabled" : ""}>${icon("share", 13)} Schicken</button><button class="btn sm ghost" data-corr="discard">Verwerfen</button></div>
      <div class="small cc-corr-msg" role="status">${esc(this.msg)}</div>`;
  }
  bind(el) {
    $$("[data-corr]", el).forEach(b => {
      const k = b.dataset.corr;
      if (k === "note" && b.tagName === "TEXTAREA") { b.oninput = () => { this.note = b.value; this.changed(); }; return; }
      if (k === "finger") { b.onchange = () => { this.finger = b.checked; this.ed.pages.forEach(pg => this.mount(pg)); }; return; }
      b.onclick = () => this.act(k);
    });
    $$("[data-corr-color]", el).forEach(b => b.onclick = () => { this.color = b.dataset.corrColor; this.tool = "pen"; this.com.render(); this.ed.pages.forEach(pg => this.mount(pg)); });
  }
  act(k) {
    if (k === "pen" || k === "marker" || k === "note") { this.tool = k; this.com.render(); this.ed.pages.forEach(pg => this.mount(pg)); }
    else if (k === "undo") this.undo();
    else if (k === "discard") { if (this.empty || confirm("Deine Korrektur verwerfen?")) { this.discard(); this.com.endCorrection(); } }
    else if (k === "send") this.send();
  }
  async send() {
    this.busy = true; this.msg = "Verschlüssele und schicke …"; this.com.render();
    try {
      const spaces = (await loadSpaces()).spaces; const space = spaces.find(s => s.key === this.sum.community_key);
      if (!space) throw new Error("Diese Community gibt es in deinem Hochschul-Abgleich nicht.");
      const pages = [...this.pages.values()].filter(p => p.strokes.length || p.notes.length);
      const corr = { id: S.uuid(), solution_id: this.sid, pseudonym: this.com.info?.pseudonym || "", created_at: S.timestamp(), note: this.note, pages };
      const payload = await C.seal(corr, space.secret);
      await capi(`/solutions/${this.sid}/corrections`, { method: "POST", body: { id: corr.id, payload } });
      this.discard(); this.com.endCorrection(); this.com.toast(C.TEXTS.sent); U.changed(); this.com.reloadCorrections?.();
    } catch (e) { this.busy = false; this.msg = e.code === "plan_required" ? "Korrekturen vorschlagen gibt es ab StudiNow Plus." : e.message; this.com.render(); }
  }
}

// ================================================================ Loesung daneben ansehen
export class SolutionSide {
  constructor(com) {
    this.com = com; this.el = document.createElement("aside"); this.el.className = "ed-solside"; this.el.hidden = true; com.el.before(this.el); this.token = 0;
  }
  close() { this.el.hidden = true; this.el.innerHTML = ""; this.token++; }
  get isOpen() { return !this.el.hidden; }
  async show(id) {
    const tok = ++this.token, summary = this.com.list?.find(s => s.solution_id === id);
    this.el.hidden = false;
    this.el.innerHTML = `<div class="ss-head">${icon("users", 15)}<b>${esc(summary?.title || summary?.display_name || "Lösung")} · ${esc(summary?.display_name || summary?.pseudonym || "")}</b><span class="badge neutral">nur ansehen</span><button class="btn ghost icon sm" data-ss="x" aria-label="Schließen">${icon("x", 15)}</button></div><div class="ss-body small muted">Wird geladen …</div>`;
    $("[data-ss='x']", this.el).onclick = () => this.close();
    const body = $(".ss-body", this.el);
    const o = await this.com.openSolution(id);
    if (tok !== this.token) return;
    if (o.error) { body.innerHTML = `<div class="com-err small">${icon("alert", 13)} ${esc(o.error)}</div>`; return; }
    body.className = "ss-body"; body.innerHTML = "";
    const width = Math.max(240, body.clientWidth - 24 || 360);
    for (const page of o.content.pages) {
      const fig = document.createElement("figure"), cv = document.createElement("canvas"), cap = document.createElement("figcaption");
      cap.className = "tiny muted"; cap.textContent = page.pdfIndex ? `PDF-Seite ${page.pdfIndex}` : "Eigene Seite der Lösung";
      fig.append(cv, cap); body.append(fig);
      await this.draw(cv, page, o, width, tok);
      if (tok !== this.token) return;
    }
  }
  /** Eine Seite in der Breite der Spalte, scharf (Bildschirmpixel): eigene PDF-Seite darunter, Notizen der Loesung darueber. */
  async draw(cv, page, o, cssWidth, tok) {
    const [dw, dh] = S.displaySize(page), dpr = Math.min(2, devicePixelRatio || 1), k = cssWidth * dpr / dw;
    cv.width = Math.round(dw * k); cv.height = Math.round(dh * k); cv.style.aspectRatio = `${dw} / ${dh}`;
    const ctx = cv.getContext("2d"); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height);
    if (page.kind === "pdf" && this.com.ed.pdf) {
      try {
        const pp = await this.com.ed.pdf.getPage(page.pdfIndex);
        const base = pp.getViewport({ scale: 1, rotation: page.rotation }), vp = pp.getViewport({ scale: cv.width / base.width, rotation: page.rotation });
        await pp.render({ canvasContext: ctx, viewport: vp }).promise;
      } catch { /* ohne PDF-Seite: weisser Grund */ }
    }
    if (tok !== this.token) return;
    ctx.setTransform(k, 0, 0, k, 0, 0); S.drawObjects(ctx, page, o.images);
  }
}

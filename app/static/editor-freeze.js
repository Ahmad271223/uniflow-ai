// Bildschirm fixieren im Editor (wie EditorFreeze.swift und FreezeViews.swift auf dem iPad, Wunsch des Inhabers
// 05.11.2026, docs/FIXIEREN-ABPAUSEN-2026-11-05.md). Zwei Stufen:
// - "Ansicht fixieren" (view): Zoom, Scrollen, Mausrad, Pinch, Fingerwischen und Seitenwechsel gesperrt, Stift und
//   Werkzeuge schreiben weiter. Abzeichen "Ansicht fixiert" mit "Loesen", Strg+L (Mac Cmd+L).
// - "Zum Abpausen einfrieren" (trace): Seite im aktuellen Zoom auf dem ganzen Bildschirm (Fullscreen API, sonst fest
//   ueber die Oberflaeche gelegt), alle Leisten weg, keine Eingabe (auch nicht der Stift), Bildschirm bleibt an (Screen
//   Wake Lock, wo vorhanden). Entsperren: Schloss etwa 2 s halten (Fortschrittsring), Esc, oder das Schloss per Tastatur
//   bzw. Screenreader ausloesen (Klick ohne Zeiger). Danach die Stufe davor.
// Der obere Teil (createFreeze, pointerPolicy, keyAction) ist reine Logik ohne DOM (tests/js/editor-freeze.test.mjs);
// attachFreeze(ed) bindet ihn an den PdfEditor (editor.js ruft es nach buildUI auf). Dafuer ersetzt attachFreeze einige
// Methoden der Editor-Instanz (goToPage, zoomTo, fling, pinchStart, clampView, buildPages, rebuildPages, destroy) durch
// Huellen, die bei fixierter Ansicht nichts tun bzw. die Stelle halten. Nichts davon wird gespeichert.

export const UNLOCK_HOLD_MS = 2000;
export const INTRO_SEEN_KEY = "uniflow.freeze.introSeen";
export const CONTRAST_KEY = "uniflow.freeze.contrast";

export const TEXTS = {
  section: "Bildschirm fixieren",
  fixView: "Ansicht fixieren",
  releaseView: "Ansicht lösen",
  trace: "Zum Abpausen einfrieren",
  badge: "Ansicht fixiert",
  release: "Lösen",
  contrast: "Kontrast für Abpausen",
  contrastHint: "Weißer Hintergrund ohne Seitenschatten.",
  unlock: "Entsperren",
  introTitle: "Bildschirm fixieren",
  viewExplain: "Zoom, Scrollen und Seitenwechsel sind gesperrt, der Stift schreibt weiter. Gut für genaue technische Zeichnungen. Lösen über das Abzeichen oben oder Strg+L.",
  traceExplain: "Die Seite füllt den Bildschirm im aktuellen Zoom, alle Leisten verschwinden und keine Berührung wirkt mehr – auch nicht der Stift oder Papier, das darauf liegt. Der Bildschirm bleibt an. Entsperren: das Schloss in der Ecke etwa zwei Sekunden halten oder Esc drücken.",
  lockLabel: "Abpausen-Sperre",
  lockHint: "Zum Entsperren etwa zwei Sekunden gedrückt halten.",
  blocked: "Ansicht ist fixiert – zum Blättern oder Zoomen erst „Lösen“ (Strg+L)",
  fixed: "Ansicht fixiert – der Stift schreibt weiter",
  released: "Ansicht gelöst",
  traced: "Zum Abpausen eingefroren – Schloss 2 Sekunden halten oder Esc",
  unlocked: "Entsperrt",
};

// ---------------------------------------------------------------- Zustand (wie EditorFreeze.swift)
/** Stufen und Halten des Schlosses. `screen`: { idleTimerDisabled (lesen/setzen), supportsBrightness, brightness };
 *  im Browser haelt `idleTimerDisabled = true` den Bildschirm ueber die Wake-Lock-API an, Helligkeit gibt es nicht. */
export function createFreeze(screen = { idleTimerDisabled: false, supportsBrightness: false, brightness: 1 }) {
  let mode = "off", options = { maxBrightness: false, highContrast: false }, before = "off";
  let savedIdle = null, savedBrightness = null, suspended = false, holdStart = null;
  const f = {
    onChange: null,
    get mode() { return mode; },
    get options() { return options; },
    get locksView() { return mode !== "off"; },
    get acceptsInput() { return mode !== "trace"; },
    get showsChrome() { return mode !== "trace"; },
    get isSuspended() { return suspended; },
    get isHolding() { return holdStart != null; },
    fixView() { if (mode !== "off") return false; set("view"); return true; },
    /** Strg+L und Menue: fixieren bzw. loesen; beim Abpausen ohne Wirkung */
    toggleView() { if (mode === "off") return f.fixView(); if (mode === "view") { set("off"); return true; } return false; },
    startTracing(opts = {}) {
      if (mode === "trace") return false;
      options = { maxBrightness: !!opts.maxBrightness, highContrast: !!opts.highContrast };
      before = mode; savedIdle = screen.idleTimerDisabled; screen.idleTimerDisabled = true; savedBrightness = null;
      if (options.maxBrightness && screen.supportsBrightness) { savedBrightness = screen.brightness; if (!suspended) screen.brightness = 1; }
      holdStart = null; set("trace"); return true;
    },
    /** vom Abpausen zurueck zur Stufe davor, von "fixiert" ganz aus */
    unlock() {
      if (mode === "off") return;
      if (mode === "view") { set("off"); return; }
      restore(); holdStart = null; set(before === "view" ? "view" : "off");
    },
    /** Dokument geschlossen: alles aus, Bildschirm wie vorher */
    end() { if (mode === "trace") restore(); holdStart = null; suspended = false; set("off"); },
    suspend() { if (suspended) return; suspended = true; holdStart = null; if (mode === "trace" && savedBrightness != null) screen.brightness = savedBrightness; },
    resume() {
      if (!suspended) return; suspended = false;
      if (mode === "trace" && savedBrightness != null && screen.supportsBrightness) screen.brightness = 1;
      if (mode === "trace") screen.idleTimerDisabled = true;        // Wake Lock faellt im Hintergrund weg: neu anfordern
    },
    holdBegan(now) { if (mode === "trace") holdStart = now; },
    holdProgress(now) { if (mode !== "trace" || holdStart == null) return 0; return Math.min(1, Math.max(0, (now - holdStart) / UNLOCK_HOLD_MS)); },
    holdCheck(now) { if (mode !== "trace" || holdStart == null || f.holdProgress(now) < 1) return false; f.unlock(); return true; },
    holdEnded(now) { const r = f.holdCheck(now); holdStart = null; return r; },
    holdCancelled() { holdStart = null; },
  };
  function restore() {
    if (savedIdle != null) screen.idleTimerDisabled = savedIdle;
    if (savedBrightness != null && screen.supportsBrightness) screen.brightness = savedBrightness;
    savedIdle = null; savedBrightness = null;
  }
  function set(m) { if (m === mode) return; mode = m; f.onChange?.(m); }
  return f;
}

// ---------------------------------------------------------------- Eingaben (rein)
/** Darf ein pointerdown auf der Seite durch? "allow" | "block".
 *  s = { mode, pointerType, button, tool, penInput, spaceHand, fingersDown (andere Finger, die schon aufliegen) } */
export function pointerPolicy(s) {
  if (s.mode === "trace") return "block";
  if (s.mode !== "view") return "allow";
  const panTool = s.tool === "hand" || !!s.spaceHand;
  if (s.pointerType === "pen") return panTool ? "block" : "allow";
  if (s.pointerType === "mouse") return panTool || s.button === 1 ? "block" : "allow";   // mittlere Taste: Bildlauf
  // Finger: scrollt bei "Nur Stift" oder Hand, zwei Finger zoomen
  if (panTool || s.penInput === "pen_only" || (s.fingersDown || 0) > 0) return "block";
  return "allow";
}

/** Tastendruck bei Stufe `mode`: "toggle" (Strg/Cmd+L), "unlock" (Esc beim Abpausen), "block" oder null (durchlassen).
 *  k = { key, ctrlKey, metaKey, altKey, shiftKey, inField (Fokus in einem Eingabefeld), onLock (Fokus auf dem Schloss) } */
export function keyAction(mode, k) {
  const key = String(k.key || "").toLowerCase(); const ctrl = !!(k.ctrlKey || k.metaKey);
  const isL = ctrl && !k.altKey && !k.shiftKey && key === "l";
  if (mode === "trace") {
    if (key === "escape") return "unlock";
    if (key === "tab") return null;                                  // zum Schloss (Tastatur)
    if (k.onLock && (key === "enter" || key === " " || key === "spacebar")) return null;
    return "block";
  }
  if (isL) return k.inField ? null : "toggle";
  if (mode !== "view" || k.inField) return null;
  if (ctrl && ["+", "=", "-", "0"].includes(key)) return "block";   // Zoom
  if (["pageup", "pagedown", "home", "end", "arrowup", "arrowdown", "arrowleft", "arrowright"].includes(key)) return "block";
  return null;
}

// ---------------------------------------------------------------- Bildschirm (Wake Lock)
export function browserScreen(nav = globalThis.navigator) {
  let sentinel = null, want = false;
  const request = () => { if (!want || sentinel || !nav?.wakeLock?.request) return; nav.wakeLock.request("screen").then(s => { if (!want) { s.release().catch(() => {}); return; } sentinel = s; s.addEventListener?.("release", () => { if (sentinel === s) sentinel = null; }); }).catch(() => {}); };
  return {
    get idleTimerDisabled() { return want; },
    set idleTimerDisabled(v) { want = !!v; if (want) request(); else if (sentinel) { const s = sentinel; sentinel = null; s.release().catch(() => {}); } },
    get supported() { return !!nav?.wakeLock?.request; },
    get held() { return !!sentinel; },
    supportsBrightness: false, brightness: 1,
  };
}

// ---------------------------------------------------------------- Einbinden in den Editor
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const LOCK_SVG = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
let cssLoaded = false;
function loadCss() {
  if (cssLoaded || typeof document === "undefined") return; cssLoaded = true;
  if (document.querySelector('link[href^="editor-freeze.css"]')) return;
  const l = document.createElement("link"); l.rel = "stylesheet"; l.href = "editor-freeze.css?v=1"; document.head.append(l);
}

/** Bindet die Sperren an einen PdfEditor (nach buildUI). Gibt { freeze, menuHtml, bindMenu, toggleView, startTracing } zurueck. */
export function attachFreeze(ed) {
  loadCss();
  const screen = browserScreen();
  const fz = createFreeze(screen);
  const orig = {};
  for (const k of ["goToPage", "zoomTo", "fling", "pinchStart", "clampView", "buildPages", "rebuildPages", "destroy"]) if (typeof ed[k] === "function") orig[k] = ed[k].bind(ed);
  let anchor = null, restoring = false, lastMsg = 0, blockedIds = new Set(), enteredFs = false, raf = 0, holdRaf = 0;
  const say = m => ed.onStatus?.(m);
  const blockedMsg = () => { const now = Date.now(); if (now - lastMsg > 1500) { lastMsg = now; say(TEXTS.blocked); } };

  // ---- Stelle merken und halten (Seitenschluessel, Punkt der Seite an der linken oberen Ecke, Zoom)
  const capture = () => {
    const pg = ed.pages?.[ed.currentPage] || ed.pages?.[0]; if (!pg || !ed.scroll) return null;
    const sr = ed.scroll.getBoundingClientRect(), r = pg.el.getBoundingClientRect(); const z = ed.zoom || 1;
    return { key: pg.key, dx: (sr.left - r.left) / z, dy: (sr.top - r.top) / z, zoom: ed.zoom };
  };
  const restore = () => {
    if (!anchor || restoring || ed.destroyed || !ed.scroll) return;
    restoring = true;
    try {
      if (Math.abs((ed.zoom || 1) - anchor.zoom) > 0.001 && orig.zoomTo) orig.zoomTo(anchor.zoom);   // durchgerutschter Zoom zurueck
      const pg = ed.pages.find(p => p.key === anchor.key) || ed.pages[ed.currentPage]; if (!pg) return;
      const sr = ed.scroll.getBoundingClientRect(), r = pg.el.getBoundingClientRect(); const z = ed.zoom || 1;
      const dl = (r.left + anchor.dx * z) - sr.left, dt = (r.top + anchor.dy * z) - sr.top;
      if (Math.abs(dl) >= 0.5) ed.scroll.scrollLeft += dl; if (Math.abs(dt) >= 0.5) ed.scroll.scrollTop += dt;
    } finally { restoring = false; }
  };
  const restoreSoon = () => { if (!anchor) return; cancelAnimationFrame(raf); raf = requestAnimationFrame(() => restore()); };

  // ---- Methoden der Instanz umhuellen
  ed.goToPage = (...a) => { if (fz.locksView) { blockedMsg(); return; } return orig.goToPage(...a); };
  ed.zoomTo = (...a) => { if (fz.locksView) { blockedMsg(); return; } return orig.zoomTo(...a); };
  if (orig.fling) ed.fling = (...a) => fz.locksView ? undefined : orig.fling(...a);
  if (orig.pinchStart) ed.pinchStart = (...a) => fz.locksView ? undefined : orig.pinchStart(...a);
  if (orig.clampView) ed.clampView = (...a) => fz.locksView ? undefined : orig.clampView(...a);
  if (orig.buildPages) ed.buildPages = (...a) => { const r = orig.buildPages(...a); restoreSoon(); return r; };
  if (orig.rebuildPages) ed.rebuildPages = (...a) => { const r = orig.rebuildPages(...a); restoreSoon(); return r; };

  // ---- Eingaben abfangen (Erfassungsphase am Container: vor den Handlern von editor.js auf .ed-scroll)
  const onLockEl = t => !!t?.closest?.(".ed-freeze-lock");
  const inScroll = t => !!(ed.scroll && t && ed.scroll.contains(t));
  const pdown = e => {
    if (fz.mode === "off") return;
    if (fz.mode === "trace") { if (onLockEl(e.target)) return; blockedIds.add(e.pointerId); e.preventDefault(); e.stopPropagation(); return; }
    if (!inScroll(e.target)) return;
    const fingersDown = [...(ed.touches?.values?.() || [])].filter(t => !t.palm).length;
    if (pointerPolicy({ mode: fz.mode, pointerType: e.pointerType, button: e.button, tool: ed.tool, penInput: ed.penInput, spaceHand: ed.spaceHand, fingersDown }) === "block") {
      blockedIds.add(e.pointerId); e.preventDefault(); e.stopPropagation();
      if (e.pointerType === "touch" && fingersDown) ed.cancelLiveStroke?.("touch");                 // zweiter Finger: kein Pinch, Strich verwerfen
    }
  };
  const pmove = e => { if (blockedIds.has(e.pointerId) || (fz.mode === "trace" && !onLockEl(e.target))) { e.preventDefault(); e.stopPropagation(); } };
  const pup = e => { if (blockedIds.delete(e.pointerId) || (fz.mode === "trace" && !onLockEl(e.target))) { e.stopPropagation(); } };
  const wheel = e => { if (fz.mode === "trace" || (fz.mode === "view" && inScroll(e.target))) { e.preventDefault(); e.stopPropagation(); if (fz.mode === "view") blockedMsg(); } };
  const swallow = e => { if (fz.mode === "trace" && !onLockEl(e.target)) { if (e.cancelable) e.preventDefault(); e.stopPropagation(); } };
  const C = ed.c;
  C.addEventListener("pointerdown", pdown, true); C.addEventListener("pointermove", pmove, true);
  C.addEventListener("pointerup", pup, true); C.addEventListener("pointercancel", pup, true);
  C.addEventListener("wheel", wheel, { capture: true, passive: false });
  for (const t of ["touchstart", "touchmove", "contextmenu", "dblclick", "click", "mousedown"]) C.addEventListener(t, swallow, { capture: true, passive: false });
  const onScroll = () => { if (fz.locksView && !restoring) restoreSoon(); };
  ed.scroll?.addEventListener("scroll", onScroll);
  const ro = typeof ResizeObserver === "function" ? new ResizeObserver(() => { if (fz.locksView) restoreSoon(); }) : null; if (ro && ed.scroll) ro.observe(ed.scroll);

  const inField = t => !!t?.closest?.('input, textarea, select, [contenteditable="true"], .ed-textedit');
  const mine = () => C.isConnected && !ed.destroyed && (C.contains(document.activeElement) || document.activeElement === document.body || document.activeElement == null || document.fullscreenElement === C);
  const key = e => {
    if (!mine()) return;
    if (fz.mode === "off" && !(e.ctrlKey || e.metaKey)) return;
    const a = keyAction(fz.mode, { key: e.key, ctrlKey: e.ctrlKey, metaKey: e.metaKey, altKey: e.altKey, shiftKey: e.shiftKey, inField: inField(e.target), onLock: onLockEl(e.target) });
    if (!a) return;
    e.preventDefault(); e.stopPropagation();
    if (a === "toggle") toggleView();
    else if (a === "unlock") unlock();
    else if (a === "block" && fz.mode === "view") blockedMsg();
  };
  document.addEventListener("keydown", key, true);
  const vis = () => { if (document.visibilityState === "hidden") { fz.suspend(); stopHold(); } else fz.resume(); };
  document.addEventListener("visibilitychange", vis);
  const fsChange = () => { if (fz.mode === "trace" && enteredFs && document.fullscreenElement !== C) { enteredFs = false; unlock(); } };
  document.addEventListener("fullscreenchange", fsChange);

  // ---- Oberflaeche: Abzeichen (fixiert) und Sperre mit Schloss (Abpausen)
  const body = C.querySelector(".ed-body") || C;
  const badge = document.createElement("div"); badge.className = "ed-freeze-badge"; badge.hidden = true; badge.setAttribute("role", "status");
  badge.innerHTML = `${LOCK_SVG}<span>${esc(TEXTS.badge)}</span><button type="button" class="ed-freeze-release">${esc(TEXTS.release)}</button>`;
  badge.querySelector("button").onclick = () => { fz.unlock(); };
  body.append(badge);
  const shield = document.createElement("div"); shield.className = "ed-freeze-shield"; shield.hidden = true; shield.setAttribute("aria-hidden", "true");
  const lock = document.createElement("button"); lock.type = "button"; lock.className = "ed-freeze-lock"; lock.hidden = true;
  lock.setAttribute("aria-label", `${TEXTS.lockLabel}. ${TEXTS.lockHint} Oder Esc.`); lock.title = TEXTS.lockHint;
  lock.innerHTML = `<svg class="ed-freeze-ring" viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="21" pathLength="100"/></svg>${LOCK_SVG}`;
  C.append(shield, lock);
  const ring = lock.querySelector("circle");
  const setRing = p => { ring.style.strokeDasharray = `${(p * 100).toFixed(1)} 100`; lock.classList.toggle("holding", p > 0); };
  const stopHold = () => { cancelAnimationFrame(holdRaf); holdRaf = 0; fz.holdCancelled(); setRing(0); };
  lock.addEventListener("pointerdown", e => {
    if (fz.mode !== "trace") return; e.preventDefault(); e.stopPropagation();
    try { lock.setPointerCapture(e.pointerId); } catch {}
    fz.holdBegan(performance.now());
    const tick = () => { if (!fz.isHolding) return; setRing(fz.holdProgress(performance.now())); if (fz.holdCheck(performance.now())) { setRing(0); return; } holdRaf = requestAnimationFrame(tick); };
    holdRaf = requestAnimationFrame(tick);
  });
  const lockUp = e => { if (fz.mode !== "trace") return; e.stopPropagation(); cancelAnimationFrame(holdRaf); holdRaf = 0; fz.holdEnded(performance.now()); setRing(0); };
  lock.addEventListener("pointerup", lockUp); lock.addEventListener("pointercancel", lockUp); lock.addEventListener("lostpointercapture", lockUp);
  // Tastatur oder Screenreader (Klick ohne Zeiger, detail 0): sofort entsperren wie die VoiceOver-Aktion
  lock.addEventListener("click", e => { e.stopPropagation(); if (fz.mode === "trace" && e.detail === 0) unlock(); });
  lock.addEventListener("contextmenu", e => e.preventDefault());

  // ---- Stufen anwenden
  let shown = "off";
  fz.onChange = mode => {
    const was = shown; shown = mode;
    if (was === "trace" && mode !== "trace") {                    // Abpausen vorbei (Schloss, Esc, Schliessen): Vollbild aus
      if (enteredFs && document.fullscreenElement === C) document.exitFullscreen?.().catch(() => {});
      enteredFs = false; if (!ed.destroyed) say(TEXTS.unlocked);
    }
    C.classList.toggle("ed-fixed", mode !== "off");
    C.classList.toggle("ed-tracing", mode === "trace");
    C.classList.toggle("ed-trace-contrast", mode === "trace" && fz.options.highContrast);
    document.body.classList.toggle("ed-tracing-doc", mode === "trace");
    badge.hidden = mode !== "view"; shield.hidden = lock.hidden = mode !== "trace";
    const pn = C.querySelector(".ed-pageno"); if (pn) pn.disabled = mode !== "off";
    if (mode === "trace") { ed.pop && (ed.pop.hidden = true); ed.clearSelection?.(); try { document.activeElement?.blur?.(); } catch {} }
    if (mode === "off") { anchor = null; blockedIds.clear(); } else { anchor ||= capture(); restoreSoon(); }
    if (mode !== "trace") stopHold();
  };

  function toggleView() {
    if (fz.mode === "trace") return false;
    const was = fz.mode; const r = fz.toggleView();
    if (r) say(was === "off" ? TEXTS.fixed : TEXTS.released);
    return r;
  }
  function startTracing(opts = {}) {
    const highContrast = opts.highContrast ?? store.get(CONTRAST_KEY) === "1";
    if (fz.mode === "off") anchor = capture();
    if (!fz.startTracing({ highContrast })) return false;
    if (C.requestFullscreen && !document.fullscreenElement) {
      try { const p = C.requestFullscreen({ navigationUI: "hide" }); enteredFs = true; p?.catch?.(() => { enteredFs = false; }); } catch { enteredFs = false; }
    }
    say(TEXTS.traced);
    setTimeout(() => { try { lock.focus({ preventScroll: true }); } catch {} }, 50);
    return true;
  }
  function unlock() {
    if (fz.mode === "off") return;
    const wasTrace = fz.mode === "trace";
    fz.unlock();                                                   // Vollbild und Meldung beim Abpausen: onChange
    if (!wasTrace) say(TEXTS.released);
  }

  // ---- Erklaerung beim ersten Mal (beide Stufen, Schalter "Kontrast fuer Abpausen")
  function intro(pick) {
    const host = document.getElementById("overlay") || document.body;
    const m = document.createElement("div"); m.className = "modal"; m.setAttribute("role", "dialog"); m.setAttribute("aria-modal", "true"); m.setAttribute("aria-labelledby", "edFzT");
    m.innerHTML = `<div class="modal-box ed-freeze-intro"><h3 id="edFzT">${esc(TEXTS.introTitle)}</h3>
      <div class="ed-fz-step"><b>${esc(TEXTS.fixView)}</b><p class="small muted">${esc(TEXTS.viewExplain)}</p></div>
      <div class="ed-fz-step"><b>${esc(TEXTS.trace)}</b><p class="small muted">${esc(TEXTS.traceExplain)}</p></div>
      <label class="small ed-fz-opt"><input type="checkbox" data-fz-contrast ${store.get(CONTRAST_KEY) === "1" ? "checked" : ""}> ${esc(TEXTS.contrast)} <span class="muted">– ${esc(TEXTS.contrastHint)}</span></label>
      <div class="modal-foot"><button class="btn" type="button" data-fz-go="cancel">Abbrechen</button><button class="btn" type="button" data-fz-go="view">${esc(TEXTS.fixView)}</button><button class="btn primary" type="button" data-fz-go="trace">${esc(TEXTS.trace)}</button></div></div>`;
    host.append(m);
    const close = () => { m.remove(); document.removeEventListener("keydown", escClose, true); };
    const escClose = e => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
    document.addEventListener("keydown", escClose, true);
    m.addEventListener("click", e => { if (e.target === m) close(); });
    m.querySelectorAll("[data-fz-go]").forEach(b => b.onclick = () => {
      const go = b.dataset.fzGo; const hc = m.querySelector("[data-fz-contrast]").checked; store.set(CONTRAST_KEY, hc ? "1" : "0");
      close(); if (go === "cancel") return; store.set(INTRO_SEEN_KEY, "1");
      if (go === "view") { if (fz.mode === "off") toggleView(); } else startTracing({ highContrast: hc });
    });
    m.querySelector(`[data-fz-go="${pick === "trace" ? "trace" : "view"}"]`)?.focus();
  }

  // ---- Menue "Mehr"
  const menuHtml = () => {
    const hc = store.get(CONTRAST_KEY) === "1";
    return `<div class="ed-menu-sub">${esc(TEXTS.section)}</div>
      <button data-fz="view">${LOCK_SVG} ${esc(fz.mode === "view" ? TEXTS.releaseView : TEXTS.fixView)} <span class="muted tiny">(Strg+L)</span></button>
      <button data-fz="trace">${LOCK_SVG} ${esc(TEXTS.trace)}</button>
      <label class="small ed-fz-opt" style="display:flex;gap:.4rem;align-items:center;padding:.2rem .6rem"><input type="checkbox" data-fz-contrast ${hc ? "checked" : ""}> ${esc(TEXTS.contrast)}</label>`;
  };
  const bindMenu = pop => {
    pop.querySelectorAll("[data-fz]").forEach(b => b.onclick = () => {
      pop.hidden = true; const k = b.dataset.fz;
      if (k === "view" && fz.mode === "view") { toggleView(); return; }
      if (store.get(INTRO_SEEN_KEY) !== "1") { intro(k); return; }
      if (k === "view") toggleView(); else startTracing();
    });
    pop.querySelectorAll("[data-fz-contrast]").forEach(c => c.onchange = () => store.set(CONTRAST_KEY, c.checked ? "1" : "0"));
  };

  // ---- Schliessen: alles loesen, Bildschirm wie vorher
  ed.destroy = (...a) => {
    if (fz.mode === "trace" && enteredFs && document.fullscreenElement === C) document.exitFullscreen?.().catch(() => {});
    fz.end(); document.body.classList.remove("ed-tracing-doc");
    document.removeEventListener("keydown", key, true); document.removeEventListener("visibilitychange", vis); document.removeEventListener("fullscreenchange", fsChange);
    ro?.disconnect(); cancelAnimationFrame(raf); stopHold();
    return orig.destroy?.(...a);
  };

  return { freeze: fz, screen, menuHtml, bindMenu, toggleView, startTracing, unlock, intro, get mode() { return fz.mode; }, _restore: restore, _anchor: () => anchor };
}

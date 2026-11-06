// Seite "Studienverlauf" (Web/Windows, 05.11.2026; Vorlage: StudyPlanPage.swift und StudyPlanEditing.swift auf dem iPad,
// docs/STUDIENVERLAUF-2026-11-04.md "Für Web und iPhone"): Kopf mit Studiengang, Pruefungsordnung, Ring "84 von 180 LP" und
// Hinweisen, Kasten "Bereiche und Wahl", darunter ein Board mit einer Spalte je Semester (schmal: Abschnitte untereinander),
// Karte je Modul mit LP, Art, Turnus und Status, offene Plaetze ("Seminare (5 LP)", "Nebenfach wählen") mit Auswahl, Tauschen,
// "Nicht belegen", eigene Eintraege, Verschieben per Ziehen (Maus: HTML5, Finger/Stift: langes Druecken) und ueber das Menue
// "Verschieben nach …" (Tastatur), "Plan zurücksetzen", Gesamtansicht aller Semester ohne Rollen (Umschalter gemerkt).
// Der Plan kommt fertig vom Backend (GET /api/study-plan); Aenderungen gehen als Teil-Einstellung an POST
// /api/study-plan/settings. Ohne aktives Abo (Web/Windows, account-gate.js) nur lesen. Noten aus QIS bleiben auf diesem Geraet.
// Regeln und HTML stehen in study-plan-logic.js (laeuft auch unter node: tests/js/study-plan*.test.mjs).
import { $, $$, api, icon, modal, toast, showError, state as app } from "./core.js?v=46";
import { gateState } from "./account-gate.js?v=1";
import * as L from "./study-plan-logic.js?v=3";

const POLL_MS = 2000;
const OV_KEY = "studyplan.overview";
const LONG_PRESS_MS = 350;

const readOverview = () => { try { return localStorage.getItem(OV_KEY) === "1"; } catch { return false; } };
const writeOverview = on => { try { localStorage.setItem(OV_KEY, on ? "1" : "0"); } catch { /* privates Fenster */ } };

const subText = () => `Was wann dran ist, was bestanden ist und was du nachholen musst – aus dem Modulkatalog deiner Hochschule und deinen Noten ${L.source().aus}.`;

export async function viewStudyPlan(parts, params, view) {
  const st = { plan: null, catalog: null, filter: "all", focus: params?.module || null, focusDone: false, timer: null, failed: null,
    overview: readOverview(), editError: null, refocus: null };
  /** Bearbeiten erlaubt: am eigenen PC ohne Pflicht, in der Probe und mit Abo; gesperrt (ohne Abo) nur lesen */
  const editable = () => gateState(app.entitlements, app.appAccount) !== "locked";
  view.innerHTML = `<div class="content sp-page" id="spRoot" style="max-width:1480px"><div class="page-head"><div><h1>${L.T.title}</h1>`
    + `<div class="sub" id="spSub">${subText()}</div></div><div class="actions" id="spActions"></div></div>`
    + `<div id="xrSection"></div><div id="spBody"><div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>${L.T.loading}</span></div></div>`
    + `<div class="sr-only" id="spLive" role="status" aria-live="polite"></div></div>`;
  const root = $("#spRoot", view), body = $("#spBody", root);
  // Hochschule fuer die Quellen-Texte (QIS, LSF, Campusmanagement); scheitert das Lesen, bleibt LUH
  const uniReady = api("/settings").then(s => { L.setUniversity(s?.university); const sub = $("#spSub", root); if (sub) sub.textContent = subText(); }).catch(() => {});
  import("./exam-registration.js?v=3").then(X => X.renderSection($("#xrSection", root))).catch(() => {});   // Pruefungsanmeldung
  const alive = () => root.isConnected && /^#\/(studyplan|studienverlauf)/.test(location.hash);

  async function load() {
    try {
      st.plan = await api("/study-plan");
      st.failed = null;
      if (!st.plan.available) st.catalog = await api("/study-catalog/status").catch(() => st.catalog);
    } catch (e) {
      if (st.plan) return;                                   // letzter Stand bleibt
      st.failed = e.message || "Unbekannter Fehler";
    }
    await uniReady;
    render();
    schedulePoll();
  }

  function schedulePoll() {
    clearTimeout(st.timer);
    if (!st.plan || st.plan.available || L.gapKind(st.plan, st.catalog) !== "loading" || !L.catalogBusy(st.catalog)) return;
    st.timer = setTimeout(async () => {
      if (!alive()) return;
      try {
        st.catalog = await api("/study-catalog/status");
        if (L.catalogReady(st.catalog)) return load();         // fertig: Plan neu lesen
      } catch { /* naechster Versuch */ }
      render();
      schedulePoll();
    }, POLL_MS);
  }

  function actions() {
    const a = $("#spActions", root), p = st.plan, edit = editable();
    const show = p && L.gapKind(p, st.catalog) !== "noqis" && edit;
    const resettable = p?.available && (Object.keys(p.placements || {}).length || (p.excluded || []).length);
    a.innerHTML = !show ? "" : (p.available ? `<button type="button" class="btn" id="spAdd" title="Modul hinzufügen">${icon("plus", 15)} <span class="lbl">Modul hinzufügen</span></button>` : "")
      + (resettable ? `<button type="button" class="btn" id="spReset" title="Plan zurücksetzen">${icon("undo", 15)} <span class="lbl">Plan zurücksetzen</span></button>` : "")
      + `<button type="button" class="btn" id="spSettings" title="Einstellungen">${icon("settings", 15)} <span class="lbl">Einstellungen</span></button>`;
    $("#spSettings", a)?.addEventListener("click", openSettings);
    $("#spAdd", a)?.addEventListener("click", () => openChooser(null));
    $("#spReset", a)?.addEventListener("click", confirmReset);
  }

  const toggleHtml = () => `<div class="seg pill sp-view" role="radiogroup" aria-label="Ansicht">`
    + [[false, "Semester"], [true, "Gesamtansicht"]].map(([v, t]) => `<button type="button" role="radio" aria-checked="${st.overview === v}" class="${st.overview === v ? "active" : ""}" data-view="${v ? "overview" : "board"}">${t}</button>`).join("") + `</div>`;
  const errHtml = () => st.editError ? `<div class="sp-err small" role="alert" id="spEditErr">${L.esc(st.editError)}</div>` : "";

  function render() {
    actions();
    root.classList.toggle("sp-ov-on", !!(st.plan?.available && st.overview));
    const p = st.plan, edit = editable();
    if (st.failed && !p) {
      body.innerHTML = `<div class="card sp-notice bad"><div class="sp-notice-ic">${icon("alert", 20)}</div><div class="sp-notice-t"><h3>Studienverlauf nicht lesbar</h3><p class="muted">${L.esc(st.failed)}</p><div class="row wrap"><button type="button" class="btn" id="spReload">${icon("refresh", 15)} Erneut laden</button></div></div></div>`;
      $("#spReload", body).onclick = load;
      return;
    }
    if (p.available && st.overview) {
      body.innerHTML = (edit ? "" : L.readOnlyHtml(icon)) + `<div class="sp-ov-bar">${toggleHtml()}<span class="sp-ov-done">${L.esc(L.progressText(Number(p.lp_done) || 0, Number(p.lp_total) || 0))}</span>`
        + `<span class="muted small sp-ov-tip">${edit ? "Tippen: Details · Ziehen: verschieben · Rechtsklick: mehr" : ""}</span></div>${errHtml()}<div id="spOvHost" class="sp-ov-host"></div>`;
      bindPlan();
      layoutOverview();
      restoreFocus();
      return;
    }
    if (p.available) {
      body.innerHTML = `<div class="sp-stack">${edit ? "" : L.readOnlyHtml(icon)}${L.poCardHtml(p, icon)}${L.headerHtml(p, icon)}${errHtml()}${L.areasHtml(p, icon, edit)}${L.backlogHtml(p, icon)}`
        + `<div class="sp-tools">${L.filterHtml(p, st.filter)}${toggleHtml()}</div>${L.boardHtml(p, st.filter, icon, { edit })}</div>`;
      bindPlan();
      if (!st.focusDone && st.focus) {
        st.focusDone = true;
        const m = L.findModule(p, st.focus);
        if (m) { scrollToSemester(L.semesterOf(p, m.id)?.term); openModule(m.id); }
      } else if (!restoreFocus()) leadBoard();
      return;
    }
    const gap = L.gapKind(p, st.catalog);
    body.innerHTML = (edit ? "" : L.readOnlyHtml(icon)) + (gap === "noqis" ? L.noQisHtml(icon) : gap === "loading" ? L.loadingHtml(p, st.catalog, icon) : gap === "nocatalog" ? L.noCatalogHtml(p, icon) : L.otherGapHtml(p, icon));
    if (!edit) $$("#spPick, #spLinkSave, #spLink", body).forEach(b => { b.disabled = true; });
    bindGap();
  }

  /** nach dem Neuzeichnen den Fokus zurueck auf dieselbe Karte bzw. denselben Knopf (Tastatur, Bildschirmleser) */
  function restoreFocus() {
    const sel = st.refocus;
    st.refocus = null;
    const el = sel && $(sel, body);
    if (!el) return false;
    el.focus({ preventScroll: false });
    return true;
  }

  /** Board quer: liegt das aktuelle Semester hinter der dritten Spalte, beginnt die Ansicht beim Semester davor */
  function leadBoard() {
    const board = $("#spBoard", body);
    if (!board || board.scrollWidth <= board.clientWidth) return;
    const cols = $$(".sp-sem", board), i = cols.findIndex(c => c.classList.contains("current"));
    if (i >= 3) board.scrollLeft = cols[i - 1].offsetLeft - board.offsetLeft;
  }
  function scrollToSemester(term) {
    const el = term && $$(".sp-sem", body).find(c => c.dataset.term === term);
    if (!el) return;
    const board = $("#spBoard", body);
    if (board && board.scrollWidth > board.clientWidth) board.scrollLeft = el.offsetLeft - board.offsetLeft;
    else el.scrollIntoView?.({ block: "start" });
  }

  // ---------------------------------------------------------------- Gesamtansicht: Groesse aus dem freien Platz
  function layoutOverview() {
    const host = $("#spOvHost", body);
    if (!host || !st.plan?.available) return;
    const top = host.getBoundingClientRect().top + window.scrollY;
    const width = host.clientWidth;
    // feste Leiste unten (Telefon: .mobile-nav) abziehen
    const nav = $(".mobile-nav"), navH = nav && getComputedStyle(nav).position === "fixed" && getComputedStyle(nav).display !== "none" ? nav.getBoundingClientRect().height : 0;
    const height = Math.max(260, window.innerHeight - top - navH - 14);
    const lay = L.overviewLayout({ width, height, semesters: L.overviewInput(st.plan) });
    host.innerHTML = L.overviewHtml(st.plan, lay, icon, editable());
    host.dataset.fits = lay.fits ? "1" : "0";
  }
  let resizeT;
  const onResize = () => {
    if (!alive()) { window.removeEventListener("resize", onResize); return; }
    clearTimeout(resizeT);
    resizeT = setTimeout(() => { if (st.overview && st.plan?.available) layoutOverview(); }, 120);
  };
  window.addEventListener("resize", onResize);

  // ---------------------------------------------------------------- Ereignisse auf dem Plan (einmal, delegiert)
  let suppressClick = false;
  function bindPlan() {
    $$("[data-filter]", body).forEach(b => b.onclick = () => { st.filter = b.dataset.filter; st.refocus = `[data-filter="${b.dataset.filter}"]`; render(); });
    $$("[data-view]", body).forEach(b => b.onclick = () => {
      st.overview = b.dataset.view === "overview";
      writeOverview(st.overview);
      st.refocus = `[data-view="${b.dataset.view}"]`;
      if (st.overview) window.scrollTo(0, 0);
      render();
    });
    $("#spPoYes", body)?.addEventListener("click", async e => {
      e.currentTarget.disabled = true;
      try { await saveSettings({ po: st.plan.suggested_po }); await load(); }
      catch (x) { const el = $("#spPoErr", body); if (el) { el.hidden = false; el.textContent = `Speichern fehlgeschlagen: ${x.message}`; } e.currentTarget.disabled = false; }
    });
    $("#spPoChange", body)?.addEventListener("click", openSettings);
    if (!editable()) $$("#spPoYes, #spPoChange", body).forEach(b => { b.disabled = true; });
  }

  body.addEventListener("click", e => {
    if (suppressClick) { suppressClick = false; e.preventDefault(); e.stopPropagation(); return; }
    const t = e.target.closest("button, a");
    if (!t || !body.contains(t) || !st.plan?.available) return;
    if (t.dataset.menu) { openMenu(t.dataset.menu, t); return; }
    if (t.dataset.module) { openModule(t.dataset.module); return; }
    if (t.dataset.slot && editable()) { const sl = L.findSlot(st.plan, t.dataset.slot); if (sl) openChooser(sl); return; }
    if (t.dataset.track && editable()) { openChooser(trackSlot(t.dataset.track)); return; }
    if (t.dataset.restore && editable()) {
      const o = (st.plan.excluded || []).find(x => x.id === t.dataset.restore);
      if (o) apply(L.editChoose(st.plan, { ...o, excluded: true }, null), () => `${o.title} ist wieder im Plan.`, `[data-module="${CSS.escape(o.id)}"]`);
    }
  });
  // Rechtsklick bzw. Kontextmenue-Taste / Umschalt+F10 auf einer Karte oder einem Chip: Menue "Aktionen"
  body.addEventListener("contextmenu", e => {
    const c = e.target.closest("[data-ctx], [data-card]");
    if (!c || !editable() || !st.plan?.available) return;
    const id = c.dataset.ctx || c.dataset.card, m = L.allModules(st.plan).find(x => x.id === id);
    if (!m || L.menuItems(m, st.plan).length < 2) return;
    e.preventDefault();
    openMenu(id, c.querySelector?.("[data-menu]") || c, { x: e.clientX, y: e.clientY });
  });
  body.addEventListener("keydown", e => {
    if (!(e.key === "ContextMenu" || (e.shiftKey && e.key === "F10"))) return;
    const c = e.target.closest?.("[data-ctx], [data-card] [data-module]");
    if (!c || !editable()) return;
    const id = c.dataset.ctx || c.dataset.module;
    e.preventDefault();
    openMenu(id, c);
  });

  // ---------------------------------------------------------------- Ziehen und Ablegen (Maus: HTML5; Finger/Stift: langes Druecken)
  let drag = null;   // { id, el, ghost?, over?, touch }
  const dropCols = () => $$("[data-drop]", body);
  const markDrop = col => { dropCols().forEach(c => c.classList.toggle("drop-on", c === col)); };
  function endDrag() {
    if (!drag) return;
    drag.el?.classList.remove("dragging");
    drag.ghost?.remove();
    body.classList.remove("sp-dragging");
    dropCols().forEach(c => c.classList.remove("drop-on", "drop-ready"));
    drag = null;
  }
  body.addEventListener("dragstart", e => {
    const el = e.target.closest?.("[data-drag]");
    if (!el || !editable()) return;
    if (drag?.touch) { e.preventDefault(); return; }       // eigenes Ziehen per Finger laeuft schon
    drag = { id: el.dataset.drag, el, touch: false };
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", drag.id);
    el.classList.add("dragging");
    body.classList.add("sp-dragging");
    dropCols().forEach(c => c.classList.add("drop-ready"));
  });
  body.addEventListener("dragover", e => {
    const col = e.target.closest?.("[data-drop]");
    if (!col || !drag) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    markDrop(col);
  });
  body.addEventListener("dragleave", e => { const col = e.target.closest?.("[data-drop]"); if (col && !col.contains(e.relatedTarget)) col.classList.remove("drop-on"); });
  body.addEventListener("drop", e => {
    const col = e.target.closest?.("[data-drop]");
    if (!col || !drag) return;
    e.preventDefault();
    const id = e.dataTransfer.getData("text/plain") || drag.id, term = col.dataset.drop;
    endDrag();
    move(id, term);
  });
  body.addEventListener("dragend", endDrag);

  // Finger und Stift: langes Druecken hebt die Karte an, Ziehen auf eine Spalte legt sie dort ab
  let press = null;
  body.addEventListener("pointerdown", e => {
    if (e.pointerType === "mouse" || !editable()) return;
    const el = e.target.closest?.("[data-drag]");
    if (!el) return;
    press = { id: el.dataset.drag, el, x: e.clientX, y: e.clientY, pid: e.pointerId,
      timer: setTimeout(() => startTouchDrag(e.clientX, e.clientY), LONG_PRESS_MS) };
  });
  function startTouchDrag(x, y) {
    if (!press) return;
    const { el, id } = press;
    const r = el.getBoundingClientRect();
    const ghost = el.cloneNode(true);
    ghost.removeAttribute("id");
    ghost.className += " sp-ghost";
    ghost.style.width = `${Math.min(r.width, 280)}px`;
    ghost.setAttribute("aria-hidden", "true");
    document.body.append(ghost);
    drag = { id, el, ghost, touch: true, dx: x - r.left, dy: y - r.top };
    moveGhost(x, y);
    el.classList.add("dragging");
    body.classList.add("sp-dragging");
    dropCols().forEach(c => c.classList.add("drop-ready"));
    try { navigator.vibrate?.(15); } catch { /* ohne Vibration */ }
  }
  function moveGhost(x, y) {
    if (!drag?.ghost) return;
    drag.ghost.style.transform = `translate(${x - Math.min(drag.dx, 140)}px, ${y - drag.dy}px)`;
    const under = document.elementFromPoint(x, y)?.closest?.("[data-drop]");
    drag.over = under && body.contains(under) ? under : null;
    markDrop(drag.over);
  }
  document.addEventListener("pointermove", e => {
    if (press && !drag && e.pointerId === press.pid && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 10) { clearTimeout(press.timer); press = null; return; }
    if (drag?.touch) moveGhost(e.clientX, e.clientY);
  });
  const touchMoveBlock = e => { if (drag?.touch && e.cancelable) e.preventDefault(); };
  document.addEventListener("touchmove", touchMoveBlock, { passive: false });
  const finishPointer = (e, cancel) => {
    if (press) { clearTimeout(press.timer); press = null; }
    if (!drag?.touch) return;
    const target = cancel ? null : drag.over, id = drag.id;
    suppressClick = true;
    setTimeout(() => { suppressClick = false; }, 400);
    endDrag();
    if (target) move(id, target.dataset.drop);
  };
  document.addEventListener("pointerup", e => finishPointer(e, false));
  document.addEventListener("pointercancel", e => finishPointer(e, true));
  // Seite verlassen: Zuhoerer am Dokument abbauen
  const cleanup = () => {
    if (alive()) return;
    document.removeEventListener("touchmove", touchMoveBlock);
    window.removeEventListener("hashchange", cleanup);
    window.removeEventListener("resize", onResize);
    closeMenu();
    endDrag();
  };
  window.addEventListener("hashchange", cleanup);

  // ---------------------------------------------------------------- Menue "Aktionen"
  let menu = null;
  function closeMenu(refocus) {
    if (!menu) return;
    const { el, opener } = menu;
    menu = null;
    el.remove();
    opener?.setAttribute?.("aria-expanded", "false");
    if (refocus && opener?.isConnected) opener.focus();
    document.removeEventListener("pointerdown", outside, true);
  }
  const outside = e => { if (menu && !menu.el.contains(e.target) && e.target !== menu.opener) closeMenu(false); };
  function openMenu(id, opener, at) {
    const p = st.plan, m = L.allModules(p).find(x => x.id === id);
    if (!m) return;
    closeMenu(false);
    const wrap = document.createElement("div");
    wrap.className = "sp-menu-pop";
    wrap.innerHTML = L.menuHtml(m, p, icon);
    document.body.append(wrap);
    const r = opener.getBoundingClientRect(), w = wrap.offsetWidth, h = wrap.offsetHeight;
    const x = at ? at.x : r.right - w, y = at ? at.y : r.bottom + 4;
    wrap.style.left = `${Math.max(8, Math.min(window.innerWidth - w - 8, x))}px`;
    wrap.style.top = `${Math.max(8, y + h > window.innerHeight - 8 ? (at ? at.y - h : r.top - h - 4) : y)}px`;
    opener.setAttribute?.("aria-expanded", "true");
    menu = { el: wrap, opener };
    const items = $$("[role=menuitem]", wrap);
    items[0]?.focus();
    wrap.addEventListener("keydown", e => {
      const i = items.indexOf(document.activeElement);
      if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
      else if (e.key === "Home") { e.preventDefault(); items[0].focus(); }
      else if (e.key === "End") { e.preventDefault(); items[items.length - 1].focus(); }
      else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeMenu(true); }
      else if (e.key === "Tab") closeMenu(false);
    });
    wrap.addEventListener("click", e => {
      const b = e.target.closest("[data-act]");
      if (!b) return;
      closeMenu(false);
      act(id, b.dataset.act, opener);
    });
    setTimeout(() => document.addEventListener("pointerdown", outside, true), 0);
  }

  /** Aktion an einem Modul (Menue, Moduldetail) */
  function act(id, action, opener) {
    const p = st.plan, m = L.allModules(p).find(x => x.id === id);
    if (!m) return;
    const back = `[data-module="${CSS.escape(id)}"]`;
    if (action === "detail") openModule(id);
    else if (action === "move") openMove(id, opener);
    else if (action === "reset") apply(L.editResetPlacement(p, id), () => `${m.title} liegt wieder im empfohlenen Semester.`, back);
    else if (action === "replace") openChooser(L.replaceSlot(p, m), { replace: m });
    else if (action === "drop") apply(L.editDrop(p, m), () => `${m.title} wird nicht belegt – „Zurück in den Plan“ holt es wieder.`, "#spAreasH");
    else if (action === "remove") apply(L.editRemoveCustom(p, id), () => `„${m.title}“ entfernt.`, null);
  }

  // ---------------------------------------------------------------- Aendern: senden, neu lesen, Rueckmeldung
  async function saveSettings(change) { return api("/study-plan/settings", { method: "POST", body: change }); }

  async function apply(change, message, refocus) {
    try {
      await saveSettings(change);
      st.editError = null;
    } catch (e) {
      st.editError = `Ändern fehlgeschlagen: ${e.message}`;
      render();
      return false;
    }
    st.refocus = refocus || null;
    await load();
    const text = message?.(st.plan);
    if (text) say(text);
    return true;
  }
  function say(text) {
    toast(text, 6000);
    const live = $("#spLive", root);
    if (live) { live.textContent = ""; setTimeout(() => { live.textContent = text; }, 50); }
  }

  async function move(id, term) {
    const p = st.plan, m = L.allModules(p).find(x => x.id === id);
    if (!m || !L.movable(m) || !term) return;
    const from = L.semesterOf(p, id);
    if (from?.term === term) return;
    await apply(L.editMove(p, id, term), after => L.moveMessage(m.title, from, term, after), `[data-module="${CSS.escape(id)}"]`);
  }

  function confirmReset() {
    const m = modal(`<div class="card-head"><h2>Plan zurücksetzen?</h2></div><p>Eigene Verschiebungen und „Nicht belegen“ werden entfernt. Gewählte Module, Schwerpunkt und eigene Einträge bleiben.</p>`
      + `<div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn danger" id="spResetYes">${icon("undo", 15)} Zurücksetzen</button></div>`);
    $("#spResetYes", m).onclick = async () => { m.remove(); await apply(L.EDIT_RESET, () => "Plan zurückgesetzt – alle Module liegen wieder im empfohlenen Semester.", null); };
  }

  // ---------------------------------------------------------------- Verschieben nach …
  function openMove(id, opener) {
    const p = st.plan, mod = L.allModules(p).find(x => x.id === id);
    if (!mod) return;
    const m = modal(`<div class="card-head"><h2>${icon("move", 18)} Verschieben nach …</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div><div class="sp-mv">${L.moveHtml(p, mod, icon)}</div>`);
    m.classList.add("sp-modal");
    m.addEventListener("click", e => {
      const b = e.target.closest("[data-to], [data-reset-one]");
      if (!b) return;
      m.remove();
      if (b.dataset.resetOne) act(id, "reset", opener);
      else if (!b.hasAttribute("aria-current")) move(id, b.dataset.to);
      else opener?.focus?.();
    });
    // erster Fokus auf die jetzige Lage (Pfeiltasten wandern durch die Semester)
    setTimeout(() => $(".sp-move.here", m)?.focus(), 40);
    m.addEventListener("keydown", e => {
      if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
      const list = $$(".sp-move", m), i = list.indexOf(document.activeElement);
      if (i < 0) return;
      e.preventDefault();
      list[Math.max(0, Math.min(list.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))].focus();
    });
  }

  // ---------------------------------------------------------------- Auswahl: Platz, Modul hinzufuegen, Tauschen, Richtung
  const trackSlot = groupId => {
    const g = (st.plan.groups || []).find(x => x.id === groupId);
    return { id: `gruppe-${groupId}`, kind: "track", title: `${g?.label || "Schwerpunkt"} wählen`, group: groupId, areas: g?.options || [], term: "" };
  };

  function openChooser(slot, { replace } = {}) {
    const p = st.plan;
    if (!p?.available || !editable()) return;
    const title = slot ? (L.isTrack(slot) ? slot.title : replace ? "Anderes Modul wählen" : "Modul wählen") : "Modul hinzufügen";
    const m = modal(`<div class="card-head"><h2>${icon(slot && L.isTrack(slot) ? "layers" : "plus", 18)} ${L.esc(title)}</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div><div class="sp-ch" id="spCh"></div>`, { wide: true });
    m.classList.add("sp-modal");
    const box = $("#spCh", m);
    if (slot && L.isTrack(slot)) {
      box.innerHTML = L.tracksHtml(p, slot, icon);
      box.addEventListener("click", e => {
        const b = e.target.closest("[data-pick-track]");
        if (!b) return;
        m.remove();
        const id = b.dataset.pickTrack;
        apply(L.editTrack(p, slot.group, id), after => `${L.area(after, id)?.name || id} gewählt.`, "#spAreasH");
      });
      return;
    }
    const ui = { query: "", expanded: null, details: {}, target: slot?.term || L.currentTerm(p) || p.semesters?.[0]?.term || "" };
    box.innerHTML = `<div class="sp-ch-head" id="spChHead">${L.chooserHeadHtml(p, slot, ui.target)}</div>`
      + `<input class="input" id="spChQ" type="search" placeholder="Modul suchen" aria-label="Modul suchen" autocomplete="off">`
      + `<div id="spChList" class="sp-ch-list"></div>${L.customBlockHtml(icon)}`;
    const list = $("#spChList", box);
    const draw = keep => {
      list.innerHTML = L.chooserListHtml(p, slot, ui.query, ui, icon);
      if (keep) $(`[data-opt="${CSS.escape(keep)}"]`, list)?.focus();
    };
    draw();
    $("#spChQ", box).oninput = e => { ui.query = e.target.value; ui.expanded = null; draw(); };
    $("#spChTerm", box)?.addEventListener("change", e => { ui.target = e.target.value; draw(); });
    list.addEventListener("click", async e => {
      const ch = e.target.closest("[data-choose]");
      if (ch) {
        const o = L.allOptions(p).find(x => x.id === ch.dataset.choose);
        if (!o) return;
        m.remove();
        const term = ui.target || null, back = `[data-module="${CSS.escape(o.id)}"]`;
        if (replace) apply(L.editReplace(p, replace.id, o, slot.term || null), () => `${o.title} statt ${replace.title} gewählt.`, back);
        else apply(L.editChoose(p, o, term), () => `${o.title} eingeplant${term ? ` in ${term}` : ""}.`, back);
        return;
      }
      const b = e.target.closest("[data-opt]");
      if (!b) return;
      const id = b.dataset.opt;
      ui.expanded = ui.expanded === id ? null : id;
      draw(id);
      if (ui.expanded && !ui.details[id]) {
        try { ui.details[id] = await api(`/study-plan/module/${encodeURIComponent(id)}`); }
        catch { ui.details[id] = {}; }
        if (m.isConnected && ui.expanded === id) draw(id);
      }
    });
    const t = $("#spCustTitle", box), lp = $("#spCustLp", box), add = $("#spCustAdd", box);
    t.oninput = () => { add.disabled = !t.value.trim(); };
    const doAdd = () => {
      const title = t.value.trim();
      if (!title) return;
      m.remove();
      apply(L.editAddCustom(p, title, L.parseLp(lp.value), slot?.area ?? null, L.fachsemesterOf(p, slot?.term || ui.target)), () => `„${title}“ eingetragen.`, null);
    };
    add.onclick = doAdd;
    t.onkeydown = e => { if (e.key === "Enter") doAdd(); };
  }

  function bindGap() {
    $("#spRetry", body)?.addEventListener("click", async () => {
      try { st.catalog = await api("/study-catalog/sync", { method: "POST", body: { force: true } }); } catch (e) { toast(e.message); }
      await load();
    });
    $("#spPick", body)?.addEventListener("click", openPrograms);
    const save = $("#spLinkSave", body), field = $("#spLink", body), msg = $("#spLinkMsg", body);
    const sayLink = (text, ok) => { msg.className = `small ${ok ? "sp-ok" : "sp-bad"}`; msg.textContent = text; };
    const doSave = async () => {
      const url = L.catalogUrl(field.value);
      if (!url) return sayLink(L.T.linkInvalid, false);
      save.disabled = true;
      try { await saveSettings({ catalog_url: url }); sayLink(L.T.linkSaved, true); st.catalog = await api("/study-catalog/status").catch(() => st.catalog); await load(); }
      catch (e) { sayLink(`Speichern fehlgeschlagen: ${e.message}`, false); }
      save.disabled = false;
    };
    if (save) { save.onclick = doSave; field.onkeydown = e => { if (e.key === "Enter") doSave(); }; }
  }

  // ---------------------------------------------------------------- Moduldetail
  async function openModule(id) {
    const stack = [id], cache = {};
    const m = modal(`<div class="card-head"><h2>${icon("columns", 18)} Moduldetails</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div><div class="sp-modal-body" id="spDetail"></div><div id="spDetAct"></div>`, { wide: true });
    m.classList.add("sp-modal");
    const box = $("#spDetail", m), foot = $("#spDetAct", m);
    const head = $(".card-head h2", m);
    let tries = 0;
    // Aendern direkt aus dem Detail (wie "manage" am iPad): Verschieben, ins empfohlene Semester, tauschen, nicht belegen
    const actionsFor = cur => {
      const pm = L.allModules(st.plan).find(x => x.id === cur);
      const items = pm && editable() ? L.menuItems(pm, st.plan).filter(([a]) => a !== "detail") : [];
      foot.innerHTML = items.length ? `<div class="modal-foot sp-det-act">${items.map(([a, t, i]) => `<button type="button" class="btn${a === "drop" || a === "remove" ? " danger-text" : ""}" data-det-act="${a}">${icon(i, 14)} ${L.esc(t)}</button>`).join("")}</div>` : "";
      $$("[data-det-act]", foot).forEach(b => b.onclick = () => { m.remove(); act(cur, b.dataset.detAct, $(`[data-module="${CSS.escape(cur)}"]`, body)); });
    };
    const bindDetail = () => {
      $$("[data-open]", box).forEach(b => b.onclick = () => { stack.push(b.dataset.open); tries = 0; show(); });
      $$("a[data-away]", box).forEach(a => a.addEventListener("click", () => m.remove()));
    };
    async function show(force) {
      const cur = stack[stack.length - 1];
      head.innerHTML = `${stack.length > 1 ? `<button type="button" class="btn ghost sm" id="spBack">${icon("chevron-left", 14)} Zurück</button> ` : ""}${icon("columns", 18)} Moduldetails`;
      $("#spBack", head)?.addEventListener("click", () => { stack.pop(); tries = 0; show(); });
      actionsFor(cur);
      if (force || !cache[cur]) {
        box.innerHTML = `<div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Lädt …</span></div>`;
        try { cache[cur] = await api(`/study-plan/module/${encodeURIComponent(cur)}`); }
        catch (e) {
          const pm = L.allModules(st.plan).find(x => x.id === cur);
          // eigener Eintrag: kein Katalogmodul, das Detail zeigt den eigenen Stand aus dem Plan
          if (pm?.custom) { cache[cur] = { title: pm.title, kind: pm.kind, lp: pm.lp, turnus: pm.turnus, own: { status: pm.status, attempts: [] }, custom: true }; }
          else {
            box.innerHTML = `<div class="card sp-notice bad"><div class="sp-notice-t"><h3>Modul nicht lesbar</h3><p class="muted">${L.esc(e.message)}</p><button type="button" class="btn" id="spDetRetry">${icon("refresh", 15)} Erneut laden</button></div></div>`;
            $("#spDetRetry", box).onclick = () => show(true);
            return;
          }
        }
      }
      if (cur !== stack[stack.length - 1]) return;
      box.innerHTML = L.detailHtml(cache[cur], icon);
      bindDetail();
      import("./exam-registration.js?v=3").then(X => X.renderModuleBlock(box, { catalogId: cur })).catch(() => {});   // "Prüfung anmelden"
      // Modultexte werden im Hintergrund geladen: einige Male nachfragen, solange das Fenster dieses Modul zeigt
      if (cache[cur].texts_loading && !cache[cur].texts && tries < 8) {
        tries++;
        setTimeout(async () => {
          if (!m.isConnected || cur !== stack[stack.length - 1]) return;
          try { cache[cur] = await api(`/study-plan/module/${encodeURIComponent(cur)}`); box.innerHTML = L.detailHtml(cache[cur], icon); bindDetail(); } catch { /* spaeter */ }
          if (cache[cur]?.texts_loading && !cache[cur]?.texts && tries < 8) show();
        }, 2500);
      }
    }
    await show();
  }

  // ---------------------------------------------------------------- Einstellungen
  async function openSettings() {
    const m = modal(`<div class="card-head"><h2>${icon("settings", 18)} Studienverlauf einstellen</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div><div id="spSetBox"><div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Lädt …</span></div></div>`, { wide: true });
    const box = $("#spSetBox", m);
    let s;
    try { s = await api("/study-plan/settings"); }
    catch (e) { box.innerHTML = `<p class="muted">Einstellungen nicht lesbar: ${L.esc(e.message)}</p>`; return; }
    const plan = st.plan?.available ? st.plan : null;
    const ui = { po: s.po || "", start: s.start_term || "", chosen: new Set(s.electives || []), tracks: L.tracksBefore(plan), removed: new Set() };
    const draw = () => {
      box.innerHTML = L.settingsHtml(s, ui, icon, L.settingsExtraHtml(plan, ui, icon))
        + `<div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="spSave">${icon("check", 15)} Speichern</button></div>`;
      $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
      $("#spSetPo", box)?.addEventListener("change", e => { ui.po = e.target.value; });
      $("#spSetStart", box)?.addEventListener("change", e => { ui.start = e.target.value; });
      $$("[data-set-track]", box).forEach(sel => sel.onchange = () => { ui.tracks[sel.dataset.setTrack] = sel.value; draw(); $(`[data-set-track="${CSS.escape(sel.dataset.setTrack)}"]`, box)?.focus(); });
      $$("[data-rm-custom]", box).forEach(b => b.onclick = () => { ui.removed.add(b.dataset.rmCustom); draw(); });
      $$("[data-el]", box).forEach(c => c.onchange = () => {
        if (c.checked) ui.chosen.add(c.dataset.el); else ui.chosen.delete(c.dataset.el);
        const lp = L.chosenLp(s, ui.chosen), req = Number(s.elective_lp_required) || 0;
        $("#spCount", box).textContent = L.counterText(lp, req);
        $("#spCount", box).className = req && lp >= req ? "ok" : "";
        const bar = $("#spCountBar", box); if (bar) bar.style.width = `${Math.min(100, req ? (lp / req) * 100 : 0)}%`;
      });
      $("#spSetPick", box)?.addEventListener("click", () => { m.remove(); openPrograms(); });
      $("#spSave", box).onclick = async e => {
        e.currentTarget.disabled = true;
        try { await saveSettings({ ...L.settingsBody(s, ui), ...L.settingsExtraBody(plan, ui) }); m.remove(); toast("Studienverlauf gespeichert"); await load(); }
        catch (x) { const el = $("#spSetErr", box); el.hidden = false; el.textContent = `Speichern fehlgeschlagen: ${x.message}`; e.currentTarget.disabled = false; }
      };
    };
    draw();
  }

  // ---------------------------------------------------------------- Studiengang aus dem Register waehlen
  async function openPrograms() {
    const m = modal(`<div class="card-head"><h2>${icon("list", 18)} Studiengang wählen</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>`
      + `<p class="muted small">Alle Studiengänge der Leibniz Universität Hannover, für die StudiNow Modulkataloge kennt. Wähle deine Prüfungsordnung (PO). Verbindlich ist die Ordnung, nach der du eingeschrieben bist.</p>`
      + `<input class="input" id="spProgQ" type="search" placeholder="Studiengang suchen, z. B. Informatik" aria-label="Studiengang suchen" autocomplete="off"><div id="spProgList" class="sp-proglist"><div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Lädt …</span></div></div>`, { wide: true });
    const list = $("#spProgList", m);
    let all;
    try { all = (await api("/study-catalog/programs")).programs; }
    catch (e) { list.innerHTML = `<p class="muted">Liste nicht lesbar: ${L.esc(e.message)}</p>`; return; }
    const current = (await api("/study-plan/settings").catch(() => ({}))).po || "";
    const draw = () => {
      list.innerHTML = L.programsHtml(all, $("#spProgQ", m).value, current);
      $$("[data-pick]", list).forEach(b => b.onclick = async () => {
        b.disabled = true;
        try {
          await saveSettings({ po: b.dataset.pick });
          st.catalog = await api("/study-catalog/status").catch(() => st.catalog);      // stoesst die Suche an
          m.remove(); toast("Studiengang gewählt – StudiNow sucht den Katalog"); st.plan = null; await load();
        } catch (x) { showError(x); b.disabled = false; }
      });
    };
    $("#spProgQ", m).oninput = draw;
    draw();
    $("#spProgQ", m).focus();
  }

  await load();
}

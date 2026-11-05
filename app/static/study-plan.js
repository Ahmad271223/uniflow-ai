// Seite "Studienverlauf" (Web/Windows, 05.11.2026; Vorlage: StudyPlanPage.swift auf dem iPad, docs/STUDIENVERLAUF-2026-11-04.md):
// Kopf mit Studiengang, Pruefungsordnung, Ring "84 von 180 LP" und Hinweisen, darunter ein Board mit einer Spalte je Semester
// (schmal: Abschnitte untereinander), Karte je Modul mit LP, Art, Turnus und Status, Filter Alle / Offen / Bestanden, die Karte
// "Nachholen im naechsten passenden Semester", Moduldetail und Einstellungen als Fenster. Der Plan kommt fertig vom Backend
// (GET /api/study-plan); Noten aus QIS bleiben auf diesem Geraet. Ohne Plan: QIS verbinden, Studiengang aus dem Register
// waehlen, Katalogsuche mit Fortschritt (GET /api/study-catalog/status, fragt alle 2 s nach) oder Link zum Modulhandbuch.
// Die Regeln und das HTML stehen in study-plan-logic.js (laeuft auch unter node: tests/js/study-plan.test.mjs).
import { $, $$, api, icon, modal, toast, showError } from "./core.js?v=43";
import * as L from "./study-plan-logic.js?v=1";

const POLL_MS = 2000;

export async function viewStudyPlan(parts, params, view) {
  const st = { plan: null, catalog: null, filter: "all", focus: params?.module || null, focusDone: false, timer: null, failed: null };
  view.innerHTML = `<div class="content sp-page" id="spRoot" style="max-width:1480px"><div class="page-head"><div><h1>${L.T.title}</h1>`
    + `<div class="sub">Was wann dran ist, was bestanden ist und was du nachholen musst – aus dem Modulkatalog deiner Hochschule und deinen Noten aus QIS.</div></div><div class="actions" id="spActions"></div></div>`
    + `<div id="spBody"><div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>${L.T.loading}</span></div></div></div>`;
  const root = $("#spRoot", view), body = $("#spBody", root);
  const alive = () => root.isConnected && /^#\/studyplan/.test(location.hash);

  async function load() {
    try {
      st.plan = await api("/study-plan");
      st.failed = null;
      if (!st.plan.available) st.catalog = await api("/study-catalog/status").catch(() => st.catalog);
    } catch (e) {
      if (st.plan) return;                                   // letzter Stand bleibt
      st.failed = e.message || "Unbekannter Fehler";
    }
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
    const a = $("#spActions", root);
    const show = st.plan && L.gapKind(st.plan, st.catalog) !== "noqis";
    a.innerHTML = show ? `<button type="button" class="btn" id="spSettings">${icon("settings", 15)} Einstellungen</button>` : "";
    $("#spSettings", a)?.addEventListener("click", openSettings);
  }

  function render() {
    actions();
    const p = st.plan;
    if (st.failed && !p) {
      body.innerHTML = `<div class="card sp-notice bad"><div class="sp-notice-ic">${icon("alert", 20)}</div><div class="sp-notice-t"><h3>Studienverlauf nicht lesbar</h3><p class="muted">${L.esc(st.failed)}</p><div class="row wrap"><button type="button" class="btn" id="spReload">${icon("refresh", 15)} Erneut laden</button></div></div></div>`;
      $("#spReload", body).onclick = load;
      return;
    }
    if (p.available) {
      body.innerHTML = `<div class="sp-stack">${L.poCardHtml(p, icon)}${L.headerHtml(p, icon)}${L.backlogHtml(p, icon)}${L.filterHtml(p, st.filter)}${L.boardHtml(p, st.filter, icon)}</div>`;
      bindPlan();
      if (!st.focusDone && st.focus) {
        st.focusDone = true;
        const m = L.findModule(p, st.focus);
        if (m) { scrollToSemester(L.semesterOf(p, m.id)?.term); openModule(m.id); }
      } else leadBoard();
      return;
    }
    const gap = L.gapKind(p, st.catalog);
    body.innerHTML = gap === "noqis" ? L.noQisHtml(icon) : gap === "loading" ? L.loadingHtml(p, st.catalog, icon) : gap === "nocatalog" ? L.noCatalogHtml(p, icon) : L.otherGapHtml(p, icon);
    bindGap();
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

  function bindPlan() {
    $$("[data-filter]", body).forEach(b => b.onclick = () => { st.filter = b.dataset.filter; render(); });
    $$("[data-module]", body).forEach(b => b.onclick = () => openModule(b.dataset.module));
    $("#spPoYes", body)?.addEventListener("click", async e => {
      e.currentTarget.disabled = true;
      try { await saveSettings({ po: st.plan.suggested_po }); await load(); }
      catch (x) { const el = $("#spPoErr", body); if (el) { el.hidden = false; el.textContent = `Speichern fehlgeschlagen: ${x.message}`; } e.currentTarget.disabled = false; }
    });
    $("#spPoChange", body)?.addEventListener("click", openSettings);
  }

  function bindGap() {
    $("#spRetry", body)?.addEventListener("click", async () => {
      try { st.catalog = await api("/study-catalog/sync", { method: "POST", body: { force: true } }); } catch (e) { toast(e.message); }
      await load();
    });
    $("#spPick", body)?.addEventListener("click", openPrograms);
    const save = $("#spLinkSave", body), field = $("#spLink", body), msg = $("#spLinkMsg", body);
    const say = (text, ok) => { msg.className = `small ${ok ? "sp-ok" : "sp-bad"}`; msg.textContent = text; };
    const doSave = async () => {
      const url = L.catalogUrl(field.value);
      if (!url) return say(L.T.linkInvalid, false);
      save.disabled = true;
      try { await saveSettings({ catalog_url: url }); say(L.T.linkSaved, true); st.catalog = await api("/study-catalog/status").catch(() => st.catalog); await load(); }
      catch (e) { say(`Speichern fehlgeschlagen: ${e.message}`, false); }
      save.disabled = false;
    };
    if (save) { save.onclick = doSave; field.onkeydown = e => { if (e.key === "Enter") doSave(); }; }
  }

  /** Einstellungen lesen und mit einer Aenderung zuruecksenden (nur die genannten Felder aendern sich) */
  async function saveSettings(change) { return api("/study-plan/settings", { method: "POST", body: change }); }

  // ---------------------------------------------------------------- Moduldetail
  async function openModule(id) {
    const stack = [id], cache = {};
    const m = modal(`<div class="card-head"><h2>${icon("columns", 18)} Moduldetails</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div><div class="sp-modal-body" id="spDetail"></div>`, { wide: true });
    m.classList.add("sp-modal");
    const box = $("#spDetail", m);
    const head = $(".card-head h2", m);
    let tries = 0;
    async function show(force) {
      const cur = stack[stack.length - 1];
      head.innerHTML = `${stack.length > 1 ? `<button type="button" class="btn ghost sm" id="spBack">${icon("chevron-left", 14)} Zurück</button> ` : ""}${icon("columns", 18)} Moduldetails`;
      $("#spBack", head)?.addEventListener("click", () => { stack.pop(); tries = 0; show(); });
      if (force || !cache[cur]) {
        box.innerHTML = `<div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Lädt …</span></div>`;
        try { cache[cur] = await api(`/study-plan/module/${encodeURIComponent(cur)}`); }
        catch (e) { box.innerHTML = `<div class="card sp-notice bad"><div class="sp-notice-t"><h3>Modul nicht lesbar</h3><p class="muted">${L.esc(e.message)}</p><button type="button" class="btn" id="spDetRetry">${icon("refresh", 15)} Erneut laden</button></div></div>`;
          $("#spDetRetry", box).onclick = () => show(true); return; }
      }
      if (cur !== stack[stack.length - 1]) return;
      box.innerHTML = L.detailHtml(cache[cur], icon);
      $$("[data-open]", box).forEach(b => b.onclick = () => { stack.push(b.dataset.open); tries = 0; show(); });
      $$("a[data-away]", box).forEach(a => a.addEventListener("click", () => m.remove()));
      // Modultexte werden im Hintergrund geladen: einige Male nachfragen, solange das Fenster dieses Modul zeigt
      if (cache[cur].texts_loading && !cache[cur].texts && tries < 8) {
        tries++;
        setTimeout(async () => {
          if (!m.isConnected || cur !== stack[stack.length - 1]) return;
          try { cache[cur] = await api(`/study-plan/module/${encodeURIComponent(cur)}`); box.innerHTML = L.detailHtml(cache[cur], icon); $$("[data-open]", box).forEach(b => b.onclick = () => { stack.push(b.dataset.open); tries = 0; show(); }); } catch { /* spaeter */ }
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
    const ui = { po: s.po || "", start: s.start_term || "", chosen: new Set(s.electives || []) };
    const draw = () => {
      box.innerHTML = L.settingsHtml(s, ui, icon) + `<div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="spSave">${icon("check", 15)} Speichern</button></div>`;
      $$("[data-close]", box).forEach(b => b.onclick = () => m.remove());
      $("#spSetPo", box)?.addEventListener("change", e => { ui.po = e.target.value; });
      $("#spSetStart", box)?.addEventListener("change", e => { ui.start = e.target.value; });
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
        try { await saveSettings(L.settingsBody(s, ui)); m.remove(); toast("Studienverlauf gespeichert"); await load(); }
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

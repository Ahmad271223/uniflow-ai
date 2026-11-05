// Community als eigene Seite (Windows-App und Web, wie CommunitySpacePage.swift / CommunityChannelView.swift auf dem iPad):
// Kopf mit Modulname und Hochschule, Reiter "Diskussion" (Fragen und Antworten, darueber die neuesten geteilten Notizen) und
// "Dokumente (N)" (Kanal nach Lehrwoche als Karten je Vorlesung, Uebung, ... oder als Liste). Tippen auf eine Karte zeigt, wer
// dazu Notizen geteilt hat; Tippen auf eine Person zeigt ihre Notizen, mit Pfeilen geht es zur naechsten bzw. vorherigen.
// Dort "Korrektur vorschlagen", Likes und Kommentare. Reiter "Karteikarten": geteilte Stapel je Lehrwoche (community-decks-ui.js).
// Aufruf: #/community?space=<schluessel>&tab=discussion|docs|cards&layout=weeks|list
import { icon } from "./icons.js?v=32";
import { $, $$, api, toast, modal } from "./core.js?v=43";
import * as S from "./solutions.js?v=6";
import { pageTitle } from "./solution-labels.js?v=1";
import * as L from "./community-logic.js?v=2";
import * as C from "./community-corrections.js?v=2";
import * as U from "./community-corrections-ui.js?v=5";
import { loadSpaces, openWithSpaces, decodeImages } from "./community-spaces.js?v=19";
import { capi, openQuestion } from "./views-qa.js?v=7";
import { renderDecksPanel } from "./community-decks-ui.js?v=3";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const UNI = { luh: "Leibniz Universität Hannover", hildesheim: "Universität Hildesheim" };
const REASONS = { offensive: "anstößig", spam: "Spam", foreignMaterial: "Fremdmaterial", gradedSubmission: "benotete Abgabe", other: "Sonstiges" };
const when = iso => { try { return new Date(iso).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", year: "numeric" }); } catch { return ""; } };
const nl = t => esc(t).replace(/\n/g, "<br>");
const avatar = (name, cls = "") => `<span class="cc-av t${L.tint(name)} ${cls}" aria-hidden="true">${esc(L.initial(name))}</span>`;
const tagHtml = (kind, inline = false) => `<span class="cc-tag${inline ? " inline" : ""}">${icon(L.KINDS[kind].icon, 12)} ${esc(L.KINDS[kind].title)}</span>`;
const empty = (ic, text, extra = "") => `<div class="cc-empty"><span class="cc-badge-ic">${icon(ic, 26)}</span><div>${text}</div>${extra}</div>`;
const pickReason = () => { const p = prompt(`Grund der Meldung (${Object.values(REASONS).join(", ")}):`, "Spam"); if (!p) return null; return Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.trim().toLowerCase().slice(0, 4))) || "other"; };

/** Seite einer Community. `info`: Antwort von /api/community/info (Tarif, Pseudonym). */
export async function renderSpacePage(view, params, info) {
  L.ensureCss();
  view.innerHTML = `<div class="content cc"><p class="small muted">Community wird geladen …</p></div>`;
  const root = $(".cc", view);
  let data;
  try { data = await loadSpaces(); } catch (e) { root.innerHTML = `<div class="cc-note bad">${esc(e.message)}</div>`; return; }
  const space = data.spaces.find(s => s.key === params.space);
  const back = `<button class="cc-back" data-go="overview">${icon("chevron-left", 16)} Community</button>`;
  if (!space) { root.innerHTML = `${back}<div class="card">${empty("users", esc(L.TEXTS.missing))}</div>`; $("[data-go]", root).onclick = () => (location.hash = "#/community"); return; }

  const st = { space, spaces: [space, ...data.spaces.filter(s => s !== space)], university: UNI[data.university] || data.university, info,
               tab: ["docs", "cards"].includes(params.tab) ? params.tab : "discussion", layout: params.layout === "list" ? "list" : "weeks", sort: params.sort === "newest" ? "newest" : "relevance",
               items: null, module: null, notice: null, error: null, joining: false, filter: "newest", reading: false };
  const sync = () => { try { history.replaceState(null, "", `#/community?space=${space.key}&tab=${st.tab}&layout=${st.layout}&sort=${st.sort}`); } catch {} };
  let observer = null;

  async function load() {
    st.error = null;
    if (!st.space.joined) { st.items = []; return; }
    const [sols, mod] = await Promise.all([
      capi(`/communities/${space.key}/solutions`).then(r => r.solutions, e => { st.error = e.message; return []; }),
      space.moduleId ? api(`/modules/${space.moduleId}`).catch(() => null) : Promise.resolve(null)]);
    st.items = sols; st.module = mod;
  }
  const weeks = () => st.module?.weeks || [];
  const channel = () => { const { skeletonItems, fileFor } = L.fileIndex(weeks()); return L.buildChannel(st.items || [], { fileFor, skeletonItems: st.layout === "weeks" && st.tab === "docs" ? skeletonItems : [] }); };
  const tone = () => (st.module?.module?.color && /^#[0-9a-f]{6}$/i.test(st.module.module.color) ? `style="--tc:${st.module.module.color}"` : "");

  // ---------------------------------------------------------------- Seite
  function draw() {
    st.reading = false; observer?.disconnect();
    const sub = L.subtitle(st.space, st.university);
    const tabs = [["discussion", "Diskussion"], ["docs", L.documentsLabel(st.items?.length ?? 0)], ["cards", "Karteikarten"]];
    root.innerHTML = `<div class="cc-top">${back}</div>
      <header class="cc-head" ${tone()}><span class="cc-tile" aria-hidden="true">${st.space.kind === "group" ? icon("users", 26) : esc(L.initial(st.space.name))}</span>
        <div><h1>${esc(st.space.name)}</h1>${sub ? `<div class="small muted">${esc(sub)}</div>` : ""}</div><span class="cc-deco">${icon(st.space.kind === "group" ? "users" : "graduation", 64)}</span></header>
      <div id="ccInbox"></div>
      <div class="cc-tabs" role="tablist">${tabs.map(([k, l]) => `<button class="cc-tab" role="tab" aria-selected="${st.tab === k}" data-tab="${k}">${esc(l)}</button>`).join("")}</div>
      ${st.notice ? `<div class="cc-note ok" role="status">${esc(st.notice)}</div>` : ""}${st.error ? `<div class="cc-note bad">${esc(st.error)}</div>` : ""}
      <div id="ccPanel" ${tone()}></div>
      ${st.space.joined ? "" : `<div class="cc-joinbar"><button class="btn primary" id="ccJoin" ${st.joining ? "disabled" : ""}>${icon("plus", 16)} ${st.joining ? "Wird beigetreten …" : "Beitreten"}</button></div>`}`;
    $("[data-go]", root).onclick = () => (location.hash = "#/community");
    $$("[data-tab]", root).forEach(b => b.onclick = () => { st.tab = b.dataset.tab; st.notice = null; sync(); draw(); });
    $("#ccJoin", root)?.addEventListener("click", join);
    const panel = $("#ccPanel", root);
    if (!st.space.joined) { panel.innerHTML = `<div class="card">${empty(st.space.kind === "group" ? "users" : "book", esc(L.TEXTS.joinHint))}</div>`; return; }
    U.renderInbox($("#ccInbox", root), { communityKey: st.space.key, toast, onChange: draw });
    if (st.items === null) { panel.innerHTML = `<p class="small muted">Lösungen werden geladen …</p>`; return; }
    if (st.tab === "cards") renderDecksPanel(panel, { space: st.space, weeks: weeks() });     // Karteikarten der Wochen (community-decks-ui.js)
    else if (st.tab === "discussion") discussion(panel); else documents(panel);
  }
  async function join() {
    st.joining = true; draw();
    try { await capi(`/communities/${space.key}/join`, { method: "POST", body: { kind: space.kind } }); st.space.joined = true; st.items = null; draw(); await load(); }
    catch (e) { st.error = e.message; }
    st.joining = false; draw();
  }

  // ---------------------------------------------------------------- Dokumente: Wochen, Karten, Liste
  function thumb(item, withTag = false) {
    const k = L.KINDS[item.kind];
    return `<div class="cc-thumb" ${item.file?.isPDF ? `data-fid="${esc(item.file.id)}" data-ver="${esc(item.file.version)}"` : ""}>
      <span class="cc-sheet" aria-hidden="true"><i style="width:90%"></i><i style="width:70%"></i><i style="width:82%"></i><i style="width:50%"></i></span>
      <span class="cc-kind-ic">${icon(k.icon, 20)}</span>${withTag ? tagHtml(item.kind) : ""}</div>`;
  }
  function cardHtml(item) {
    const none = !item.people.length;
    const names = item.people.map(L.personName), cm = L.itemComments(item);
    return `<button class="cc-card cc-t-${L.KINDS[item.kind].tone}${none ? " empty" : ""}" data-item="${esc(item.id)}" aria-label="${esc(`${L.KINDS[item.kind].title}: ${item.title}, ${L.itemDetail(item, true)}`)}">
      ${thumb(item, true)}
      <div class="cc-body"><div class="cc-title">${esc(item.title)}</div>
        <div class="cc-meta">${none ? `<span class="cc-av" style="background:transparent;border:1.5px dashed var(--line-strong);color:var(--muted)">${icon("plus", 12)}</span>` : `<span class="cc-avs">${names.slice(0, 2).map(n => avatar(n)).join("")}</span>`}
          <span>${esc(L.itemDetail(item))}</span><span class="cc-spacer"></span>${cm ? `<span title="Kommentare">${icon("message", 12)} ${cm}</span>` : ""}</div></div></button>`;
  }
  function rowHtml(item) {
    const lat = L.itemLatest(item);
    return `<button class="cc-li cc-t-${L.KINDS[item.kind].tone}" data-item="${esc(item.id)}" aria-label="${esc(`${L.KINDS[item.kind].title}: ${item.title}, ${L.itemByline(item)}`)}">
      ${thumb(item)}<span class="cc-info"><span class="cc-title">${esc(item.title)}</span>
      <span class="small muted" style="display:flex;gap:.4rem;align-items:center">${item.people.slice(0, 3).map(p => avatar(L.personName(p))).join("")}${esc(L.itemByline(item))} · ${esc(when(lat))}</span>
      <span class="cc-stats">${tagHtml(item.kind, true)}<span>${icon("star", 12)} ${L.itemLikes(item)}</span><span>${icon("note", 12)} ${L.itemComments(item)}</span></span></span>${icon("chevron-right", 16)}</button>`;
  }
  function lazyThumbs(box) {
    observer?.disconnect();
    observer = new IntersectionObserver(async ens => {
      for (const en of ens) {
        if (!en.isIntersecting) continue; observer.unobserve(en.target);
        const id = en.target.dataset.fid; if (!id || en.target.querySelector("img")) continue;
        try {
          const ed = await import("./editor.js?v=66");
          const data = await ed.renderThumbnail(id, `/api/files/${id}/content`, en.target.dataset.ver, 220);
          if (data) { const img = new Image(); img.alt = ""; img.src = data; en.target.prepend(img); $(".cc-sheet", en.target)?.remove(); }
        } catch { /* Platzhalter bleibt */ }
      }
    }, { rootMargin: "300px" });
    $$("[data-fid]", box).forEach(el => observer.observe(el));
  }
  function bindItems(box, all) {
    $$("[data-item]", box).forEach(b => b.onclick = () => whoShared(all.find(i => i.id === b.dataset.item)));
  }
  function cardRow(items) { return `<div class="cc-row">${items.map(cardHtml).join("")}</div>`; }

  function documents(panel) {
    const ch = channel();
    const chips = `<div class="cc-chips"><button class="cc-chip" aria-pressed="${st.layout === "weeks"}" data-layout="weeks">${icon("calendar", 13)} Wochen</button>
      <button class="cc-chip" aria-pressed="${st.layout === "list"}" data-layout="list">${icon("list", 13)} Liste</button>
      ${st.layout === "list" ? `<span class="small muted" style="margin-left:.6rem">Sortieren:</span>${[["relevance", "Relevanz"], ["newest", "Neueste"]].map(([k, l]) => `<button class="cc-chip" aria-pressed="${st.sort === k}" data-sort="${k}">${l}</button>`).join("")}` : ""}</div>`;
    const skeleton = L.fileIndex(weeks()).skeletonItems;
    let body;
    if (!st.items.length && (st.layout === "list" || !skeleton.length)) body = `<div class="card">${empty("file-text", esc(L.TEXTS.noneShared))}</div>`;
    else if (st.layout === "list") body = `<div class="cc-list">${L.rows(ch, st.sort).map(rowHtml).join("")}</div>`;
    else body = ch.map(w => {
      const shared = w.items.filter(i => i.people.length).length;
      return `<section class="cc-week" aria-label="${esc(L.weekLabel(w.week, weeks()))}"><div class="cc-week-head"><span class="cc-week-mark cc-wash cc-ink">${w.week ? w.week : icon("layers", 18)}</span>
        <div><h2>${esc(L.weekLabel(w.week, weeks()))}</h2><div class="small muted">${esc(L.weekDetail(w.items.length, shared))}</div></div></div>${cardRow(w.items)}</section>`;
    }).join("");
    panel.innerHTML = chips + body;
    $$("[data-layout]", panel).forEach(b => b.onclick = () => { st.layout = b.dataset.layout; sync(); draw(); });
    $$("[data-sort]", panel).forEach(b => b.onclick = () => { st.sort = b.dataset.sort; sync(); draw(); });
    bindItems(panel, ch.flatMap(w => w.items)); lazyThumbs(panel);
  }

  // ---------------------------------------------------------------- Diskussion: Fragen und Antworten
  function discussion(panel) {
    const ch = channel(), latest = L.latest(ch);
    panel.innerHTML = `${latest.length ? `<section class="cc-week"><div class="cc-week-head"><span class="cc-week-mark cc-wash cc-ink">${icon("sparkles", 20)}</span><h2>Neueste geteilte Notizen</h2></div>${cardRow(latest)}</section>` : ""}
      <section><div class="cc-week-head"><span class="cc-week-mark cc-wash cc-ink">${icon("message", 20)}</span><h2>Fragen und Antworten</h2></div><div id="ccQa"></div></section>`;
    bindItems(panel, ch.flatMap(w => w.items)); lazyThumbs(panel);
    questions($("#ccQa", panel));
  }
  function questions(box) {
    const q = { list: [], next: null, loading: false };
    const post = p => {
      const n = p.pseudonym;
      return `<article class="cc-post" tabindex="0" role="button" data-q="${esc(p.id)}" aria-label="${esc(`Frage von ${n}: ${p.title}. ${L.repliesText(p.answers)}, ${L.likesText(p.likes)}`)}">
        ${avatar(n, "big")}<div class="cc-info"><span class="cc-title">${esc(p.title)}</span>${p.body ? `<span class="cc-snip">${esc(p.body)}</span>` : ""}
          <span class="cc-foot"><span>${esc(n)}${p.mine ? " (du)" : ""} · ${esc(L.relative(p.created_at))}</span><span>${esc(L.repliesText(p.answers))}</span>
            ${L.isAnswered(p) ? `<span class="badge ok">${icon("check", 11)} Beantwortet</span>` : ""}${p.accepted_answer ? `<span class="badge ok">gelöst</span>` : ""}</span></span>
        </div><button class="cc-likebtn${p.liked_by_me ? " liked" : ""}" data-like="${esc(p.id)}" ${p.mine ? 'disabled title="Die eigene Frage lässt sich nicht liken"' : `title="${p.liked_by_me ? "Gefällt mir nicht mehr" : "Gefällt mir"}"`} aria-pressed="${!!p.liked_by_me}" aria-label="${esc(L.likesText(p.likes))}">${icon("heart", 14)} <span>${p.likes}</span></button></article>`;
    };
    const paint = () => {
      const shown = L.filterPosts(q.list, st.filter);
      box.innerHTML = `<p class="tiny muted" style="margin-top:0">${esc(L.TEXTS.discussionNotice)}</p>
        <details class="cc-ask"><summary class="btn sm primary" style="display:inline-flex">${icon("plus", 13)} Frage stellen</summary>
          <input class="input" id="ccQt" maxlength="160" placeholder="Worum geht es? (z. B. Aufgabe 2b: Konvergenz zeigen)"><textarea class="input" id="ccQb" rows="3" maxlength="4000" placeholder="Was hast du schon versucht? Wo hängst du?"></textarea>
          <div class="row" style="gap:.4rem;align-items:center"><button class="btn sm primary" id="ccQs">Fragen</button><span class="small" id="ccQm"></span></div></details>
        <div class="cc-chips">${Object.entries(L.FILTERS).map(([k, l]) => `<button class="cc-chip" aria-pressed="${st.filter === k}" data-filter="${k}">${l}</button>`).join("")}</div>
        <div class="cc-posts">${shown.map(post).join("") || (q.loading ? `<p class="small muted">Lade Fragen …</p>` : `<div class="card">${empty("message", st.filter === "unanswered" ? "Alle Fragen sind beantwortet." : "Noch keine Fragen in dieser Community. Stell die erste – Mitglieder sehen sie sofort.")}</div>`)}</div>
        ${q.next ? `<button class="btn sm ghost" id="ccQmore" style="margin-top:.6rem">Mehr laden</button>` : ""}`;
      $$("[data-filter]", box).forEach(b => b.onclick = () => { st.filter = b.dataset.filter; fetchQ(true); });
      $("#ccQmore", box)?.addEventListener("click", () => fetchQ(false));
      $$("[data-q]", box).forEach(el => { const open = () => openQuestion(el.dataset.q, () => fetchQ(true)); el.onclick = e => { if (!e.target.closest("[data-like]")) open(); }; el.onkeydown = e => { if (e.key === "Enter" && e.target === el) open(); }; });
      $$("[data-like]", box).forEach(b => b.onclick = async e => {
        e.stopPropagation(); const p = q.list.find(x => x.id === b.dataset.like); b.disabled = true;
        try { const r = await capi(`/questions/${p.id}/like`, { method: p.liked_by_me ? "DELETE" : "POST" }); p.liked_by_me = r.liked; p.likes = r.likes; paint(); $(`[data-like="${p.id}"]`, box)?.classList.add("cc-pop"); }
        catch (x) { toast(x.message, 4000); b.disabled = false; }
      });
      $("#ccQs", box)?.addEventListener("click", async e => {
        const t = $("#ccQt", box).value.trim(); if (!t) return; e.target.disabled = true;
        try { await capi(`/courses/${space.key}/questions`, { method: "POST", body: { title: t, body: $("#ccQb", box).value } }); fetchQ(true); }
        catch (x) { $("#ccQm", box).textContent = x.message; e.target.disabled = false; }
      });
    };
    async function fetchQ(reset) {
      if (reset) { q.list = []; q.next = null; }
      q.loading = true; paint();
      const qs = new URLSearchParams({ limit: "30" }); if (!reset && q.next) qs.set("before", q.next); if (st.filter === "unanswered") qs.set("unanswered", "true");
      try { const d = await capi(`/courses/${space.key}/questions?${qs}`); q.list = reset ? d.questions : q.list.concat(d.questions); q.next = d.next; }
      catch (e) { box.innerHTML = `<div class="cc-note bad">${esc(e.message)}</div>`; return; }
      q.loading = false; paint();
    }
    fetchQ(true);
  }

  // ---------------------------------------------------------------- Blatt: wer hat etwas geteilt
  function whoShared(item) {
    const cls = `cc-t-${L.KINDS[item.kind].tone}`;
    const m = modal(`<div class="card-head"><h2>${esc(item.title)}</h2><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>
      <div class="${cls} cc" style="max-width:none"><div class="row wrap" style="gap:.5rem;align-items:center;margin-bottom:.6rem">${tagHtml(item.kind, true)}<span class="small muted">${esc(L.weekLabel(item.week, weeks()))}</span>
        ${item.file ? `<button class="btn sm" data-local>${icon("file-text", 13)} In meiner PDF öffnen</button>` : ""}</div>
      ${item.people.length ? `<p class="small" style="font-weight:620;margin:.2rem 0">${esc(item.people.length === 1 ? "1 Person hat Notizen geteilt" : `${item.people.length} Personen haben Notizen geteilt`)}</p>
        <div class="cc-people">${item.people.map((s, i) => { const n = L.personName(s); return `<button class="cc-person" data-person="${i}" aria-label="${esc(`Notizen von ${n}${s.mine ? " (du)" : ""}, ${L.personDetail(s, when(s.published_at))}`)}">${avatar(n, "big")}<span class="cc-info"><b>${esc(n)}</b>${s.mine ? ` <span class="badge">Du</span>` : ""}<div class="small muted">${esc(L.personDetail(s, when(s.published_at)))}</div></span>${icon("chevron-right", 16)}</button>`; }).join("")}</div>`
        : empty(L.KINDS[item.kind].icon, `<b>${esc(L.TEXTS.firstPerson)}</b><br>${esc(L.TEXTS.firstPersonText)}`)}</div>`);
    $("[data-local]", m)?.addEventListener("click", () => { m.remove(); location.hash = `#/doc/${encodeURIComponent(item.file.id)}`; });
    $$("[data-person]", m).forEach(b => b.onclick = () => { m.remove(); reader(item, +b.dataset.person); });
  }

  // ---------------------------------------------------------------- Leser: Notizen einer Person, weiter zur naechsten
  function reader(item, start) {
    st.reading = true; observer?.disconnect();
    let i = start, tab = "notes"; const people = item.people; const opened = new Map();
    const canShare = !!st.info?.can_share;
    const keyHandler = e => { if (!st.reading || e.target.closest?.("input, textarea")) return; if (e.key === "ArrowRight") go(1); else if (e.key === "ArrowLeft") go(-1); };
    document.addEventListener("keydown", keyHandler);
    const stop = () => { document.removeEventListener("keydown", keyHandler); window.removeEventListener("hashchange", stop); };
    window.addEventListener("hashchange", stop);
    const leave = () => { stop(); draw(); };

    async function content(s) {
      if (opened.has(s.solution_id)) return opened.get(s.solution_id);
      const { package: pkg } = await capi(`/solutions/${s.solution_id}`);
      const c = await openWithSpaces(pkg, st.spaces); const o = { content: c, images: await decodeImages(c) }; opened.set(s.solution_id, o); return o;
    }
    function go(d) { const n = L.step(i, people.length, d); if (n !== i) { i = n; tab = "notes"; show(); } }
    async function show() {
      const s = people[i], name = L.personName(s);
      root.innerHTML = `<div class="cc-reader ${"cc-t-" + L.KINDS[item.kind].tone}" ${tone()}>
        <div class="cc-rbar"><button class="btn ghost" data-leave>${icon("chevron-left", 15)} Zurück</button>
          <button class="btn ghost icon" data-prev aria-label="Vorherige Person" ${i === 0 ? "disabled" : ""}>${icon("chevron-left", 18)}</button>
          <div class="cc-rtitle">${esc(item.title)}<div class="tiny muted" style="font-weight:400">${avatar(name)} ${esc(name)}${s.mine ? " (du)" : ""} · ${i + 1} von ${people.length}</div></div>
          <button class="btn ghost icon" data-next aria-label="Nächste Person" ${i === people.length - 1 ? "disabled" : ""}>${icon("chevron-right", 18)}</button></div>
        <div class="cc-tabs" role="tablist"><button class="cc-tab" role="tab" aria-selected="${tab === "notes"}" data-rtab="notes">Dokument</button><button class="cc-tab" role="tab" aria-selected="${tab === "talk"}" data-rtab="talk" id="ccTalkTab">Diskussion (${s.comments | 0})</button></div>
        <div id="ccRPane"><p class="small muted">Wird geladen …</p></div><div class="cc-actions" id="ccActs"></div></div>`;
      $("[data-leave]", root).onclick = leave; $("[data-prev]", root).onclick = () => go(-1); $("[data-next]", root).onclick = () => go(1);
      $$("[data-rtab]", root).forEach(b => b.onclick = () => { tab = b.dataset.rtab; show(); });
      actions(s);
      const pane = $("#ccRPane", root);
      if (tab === "notes") await notesPane(pane, s); else await talkPane(pane, s);
    }
    async function notesPane(pane, s) {
      try {
        const o = await content(s); if (people[i] !== s) return;
        const local = await U.localFile(s.fingerprint);
        pane.innerHTML = `<p class="small ${local ? "" : "muted"}">${local ? `Du hast dieselbe PDF. <a href="#/doc/${esc(local.file_id)}">Im Dokument ansehen</a> – dort liegt die Lösung über deiner PDF.` : "Du hast diese PDF nicht, darum stehen die Notizen auf leeren Seiten."}</p><div class="cc-pages"></div>`;
        const box = $(".cc-pages", pane);
        for (const [pi, page] of o.content.pages.entries()) {
          const fig = document.createElement("figure"), cv = document.createElement("canvas"), sc = 2; cv.width = page.width * sc; cv.height = page.height * sc;
          const ctx = cv.getContext("2d"); ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height); ctx.scale(sc, sc); S.drawObjects(ctx, page, o.images);
          const cap = document.createElement("figcaption"); cap.className = "tiny muted"; cap.textContent = pageTitle(o.content.pages, pi);
          fig.append(cv, cap); box.append(fig);
        }
      } catch (e) { pane.innerHTML = `<div class="cc-note bad">${esc(e.message)}</div>`; }
    }
    async function talkPane(pane, s) {
      let comments = [], corrs = [], err = null;
      try { comments = (await capi(`/solutions/${s.solution_id}/comments`)).comments; } catch (e) { err = e.message; }
      try { corrs = await U.loadCorrections(s.solution_id, st.space.secret); } catch { /* ohne Korrekturen */ }
      if (people[i] !== s || tab !== "talk") return;
      const canC = !!st.info?.can_comment; let replyTo = null;
      const card = (c, reply) => `<div class="com-c${reply ? " reply" : ""}" data-cid="${esc(c.id)}"><div class="com-c-head"><b>${esc(c.pseudonym)}</b>${c.by_author ? ` <span class="badge neutral">Autor</span>` : ""}<span class="tiny muted">${esc(L.relative(c.created_at))}${c.edited_at ? " · bearbeitet" : ""}</span></div>
        <div class="com-c-text">${c.deleted ? `<i class="muted">Kommentar gelöscht</i>` : nl(c.text)}</div>
        ${c.deleted ? "" : `<div class="com-c-act">${!reply && canC ? `<button class="btn ghost sm" data-reply="${esc(c.id)}">${icon("reply", 12)} Antworten</button>` : ""}${c.mine || s.mine ? `<button class="btn ghost sm" data-cdel="${esc(c.id)}">Löschen</button>` : ""}${c.mine ? "" : `<button class="btn ghost sm" data-crep="${esc(c.id)}">Melden</button>`}</div>`}
        ${replyTo === c.id ? `<div class="com-new"><textarea rows="2" maxlength="${st.info?.max_comment || 2000}" placeholder="Antwort …"></textarea><div class="row"><button class="btn sm primary" data-send-reply>Antworten</button><button class="btn sm ghost" data-cancel>Abbrechen</button></div></div>` : ""}</div>`;
      const paint = () => {
        const threads = comments.filter(c => !c.parent_id).map(t => card(t, false) + comments.filter(r => r.parent_id === t.id).map(r => card(r, true)).join("")).join("");
        pane.innerHTML = `${err ? `<div class="cc-note bad">${esc(err)}</div>` : ""}
          ${corrs.length ? `<section style="margin-bottom:1rem"><h3 style="margin:.2rem 0">${esc(C.TEXTS.sectionTitle)} (${corrs.length})</h3><p class="tiny muted">${esc(C.TEXTS.sectionNotice)}</p><div class="cc-inbox" id="ccCorrs">${corrs.map(U.correctionCard).join("")}</div></section>` : ""}
          ${canC ? `<div class="com-new" style="margin-bottom:.8rem"><textarea id="ccCt" rows="3" maxlength="${st.info?.max_comment || 2000}" placeholder="Kommentar zur ganzen Lösung"></textarea><div class="row"><button class="btn sm primary" id="ccCs">Kommentieren</button></div></div>`
            : `<p class="tiny muted">${icon("info", 12)} Lesen kann jeder; kommentieren geht ab StudiNow Plus mit bestätigter E-Mail.</p>`}
          <div class="com-threads">${threads || `<p class="small muted">Noch keine Kommentare.</p>`}</div>`;
        U.bindCorrections(pane, corrs, { solution: s, toast, onChange: () => { U.changed(); show(); } });
        const reload = async () => { comments = (await capi(`/solutions/${s.solution_id}/comments`)).comments; s.comments = comments.filter(c => !c.deleted).length; const t = $("#ccTalkTab", root); if (t) t.textContent = `Diskussion (${s.comments})`; paint(); };
        const run = async fn => { try { await fn(); } catch (e) { toast(e.message, 4000); } };
        $("#ccCs", pane)?.addEventListener("click", () => { const t = $("#ccCt", pane).value.trim(); if (t) run(async () => { await capi(`/solutions/${s.solution_id}/comments`, { method: "POST", body: { text: t } }); await reload(); }); });
        $$("[data-reply]", pane).forEach(b => b.onclick = () => { replyTo = b.dataset.reply; paint(); });
        $$("[data-cancel]", pane).forEach(b => b.onclick = () => { replyTo = null; paint(); });
        $$("[data-send-reply]", pane).forEach(b => b.onclick = () => { const t = b.closest(".com-new").querySelector("textarea").value.trim(); if (t) run(async () => { await capi(`/solutions/${s.solution_id}/comments`, { method: "POST", body: { text: t, parent_id: replyTo } }); replyTo = null; await reload(); }); });
        $$("[data-cdel]", pane).forEach(b => b.onclick = () => { if (confirm("Kommentar löschen?")) run(async () => { await capi(`/comments/${b.dataset.cdel}`, { method: "DELETE" }); await reload(); }); });
        $$("[data-crep]", pane).forEach(b => b.onclick = () => { const r = pickReason(); if (r) run(async () => { await capi(`/comments/${b.dataset.crep}/report`, { method: "POST", body: { reason: r } }); toast("Gemeldet. Danke!"); }); });
      };
      paint();
    }
    async function actions(s) {
      const box = $("#ccActs", root); if (!box) return;
      const paint = (lf) => {
        const offer = C.offer({ own: s.mine, supported: true, canShare, localFile: lf });
        box.innerHTML = `<button class="btn sm ghost${s.liked_by_me ? " liked" : ""}" data-a="like" ${s.mine ? 'disabled title="Die eigene Lösung lässt sich nicht liken"' : ""}>${icon("heart", 14)} ${s.likes | 0}</button>
          <button class="btn sm ghost" data-a="bookmark">${icon("bookmark", 14)} Merken</button>
          ${offer === "hidden" ? "" : `<button class="btn sm" data-a="correct" ${offer === "checking" ? "disabled" : ""}>${icon("pencil", 14)} ${C.TEXTS.action}</button>`}
          ${lf ? `<button class="btn sm ghost" data-a="local">${icon("file-text", 14)} In meiner PDF öffnen</button>` : ""}
          ${s.mine ? "" : `<button class="btn sm ghost" data-a="more" aria-label="Melden oder Autor sperren">${icon("more", 14)}</button>`}`;
        $$("[data-a]", box).forEach(b => b.onclick = async () => {
          const a = b.dataset.a;
          try {
            if (a === "like") { const r = await capi(`/solutions/${s.solution_id}/like`, { method: s.liked_by_me ? "DELETE" : "POST" }); s.liked_by_me = !s.liked_by_me; s.likes = r.likes; paint(lf); $('[data-a="like"]', box).classList.add("cc-pop"); }
            else if (a === "bookmark") { await capi(`/bookmarks/solution/${s.solution_id}`, { method: "POST" }); toast("Gemerkt – zu finden unter Community → Gemerkt."); }
            else if (a === "local") location.hash = `#/doc/${encodeURIComponent(lf.file_id)}`;
            else if (a === "correct") {
              if (offer === "locked") toast("Korrekturen vorschlagen gibt es ab StudiNow Plus.", 4000);
              else if (offer === "needsPDF") toast(C.TEXTS.needsPDF, 4000);
              else U.openInEditor(lf, { correct: s.solution_id });
            } else if (a === "more") {
              const pick = prompt(`Melden (Grund eingeben: ${Object.values(REASONS).join(", ")}) oder „sperren“, um Lösungen dieses Autors nicht mehr zu sehen:`); if (!pick) return;
              const p = pick.trim().toLowerCase();
              if (p.startsWith("sperr")) { await capi(`/solutions/${s.solution_id}/block`, { method: "POST" }); st.items = st.items.filter(x => x.pseudonym !== s.pseudonym); leave(); toast("Autor gesperrt."); }
              else { const reason = Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.slice(0, 4))) || "other"; await capi(`/solutions/${s.solution_id}/report`, { method: "POST", body: { reason, note: reason === "other" ? pick.slice(0, 300) : null } }); toast("Gemeldet. Danke!"); }
            }
          } catch (e) { toast(e.message, 4000); }
        });
      };
      if (s.mine) { paint(null); return; }
      paint(undefined); const lf = await U.localFile(s.fingerprint); if (people[i] === s && $("#ccActs", root)) paint(lf);
    }
    show();
  }

  draw();
  await load();
  if (!st.reading) draw();
}

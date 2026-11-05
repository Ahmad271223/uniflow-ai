// KI-Hilfe im Editor als Gespraech mit drei farbigen Reitern (wie TutorPanel.swift auf dem iPad, Neugestaltung 04.11.2026):
// oben "Erklaeren" (gruen), "Karteikarten" (orange), "Test" (blau), darunter die Aktionen des Reiters; Antworten als
// Markdown, Fragen als Blasen rechts, Anschlussfragen unter der letzten Antwort, "Schon erklaert - sofort da - 0 Credits"
// mit "Neu erklaeren lassen" (Erklaerungsspeicher, app/explain_local.py), Eingabe unten fest, Kostenzeile klein darunter.
// Der Teil bis `createAiPanel` ist reine Logik ohne DOM (tests/js/ai-panel.test.mjs); `createAiPanel` zeichnet und
// spricht mit POST /api/ai/tutor. Das ganze Dokument (Umfang, Schnellknoepfe) bleibt in doc-explain-logic.js / editor.js.
import { SCOPES, CHIPS, docModeFor } from "./doc-explain-logic.js?v=1";

/** Reiter: Kennung, Titel, Symbol, Modi in der Reihenfolge der Knoepfe (jeder Modus ausser "ask" gehoert genau einem Reiter) */
export const TABS = [
  { id: "explain", title: "Erklären", icon: "book", modes: ["explain", "explain_simple", "summary", "terms", "steps", "hints"] },
  { id: "cards", title: "Karteikarten", icon: "cards", modes: ["flashcards"] },
  { id: "test", title: "Test", icon: "exam", modes: ["similar", "check"] },
];
export const MODE_LABELS = {
  ask: "Frage", explain: "Erklären", explain_simple: "Einfach erklären", summary: "Zusammenfassen", steps: "Aufgabe lösen",
  hints: "Nur Hinweise", check: "Lösung prüfen", similar: "Ähnliche Aufgabe", terms: "Fachbegriffe", flashcards: "Karteikarten",
  quiz: "Quizfragen",
};
export const HISTORY_TURNS = 6;                      // wie ai.TUTOR_HISTORY_TURNS

/** Reiter eines Modus (Anschlussfrage, "Text markieren"); null fuer die freie Frage */
export const tabOf = mode => TABS.find(t => t.modes.includes(mode))?.id || null;

/** Text im Verlauf fuer eine Anfrage: freie Frage = der Text, Pruefen mit der Loesung, sonst Name des Modus (mit Frage) */
export function userLabel(mode, typed = "", force = false) {
  const name = MODE_LABELS[mode] || mode, t = String(typed || "").trim();
  if (mode === "ask") return t;
  if (mode === "check") return `Lösung prüfen:\n${t}`;
  return t ? `${name}: ${t}` : (force ? `${name} (neu)` : name);
}

/** Anschlussfragen je Modus (wie AIFollowUps.suggest): [Beschriftung, Modus, Frage] */
export function followUps(mode) {
  const ex = ["Ein Beispiel dazu", "ask", "Gib mir ein konkretes Beispiel dazu."];
  switch (mode) {
    case "explain": return [["Einfacher erklären", "explain_simple", ""], ex, ["Fachbegriffe", "terms", ""]];
    case "explain_simple": return [["Etwas genauer", "explain", ""], ex];
    case "summary": return [["Was muss ich können?", "ask", "Was muss ich nach dieser Seite können? Nenne 3 Punkte."], ["Karteikarten daraus", "flashcards", ""], ["Ähnliche Aufgabe", "similar", ""]];
    case "steps": return [["Warum dieser Schritt?", "ask", "Warum ist der erste Schritt so und nicht anders?"], ["Ähnliche Aufgabe", "similar", ""], ["Nur Hinweise", "hints", ""]];
    case "hints": return [["Nächster Hinweis", "ask", "Gib mir einen weiteren, konkreteren Hinweis."], ["Ganz lösen", "steps", ""]];
    case "check": return [["Wie behebe ich den Fehler?", "ask", "Wie behebe ich den Fehler Schritt für Schritt?"], ["Musterlösung", "steps", ""]];
    case "similar": return [["Noch eine", "similar", ""], ["Lösung erklären", "ask", "Erkläre die Lösung der Übungsaufgabe Schritt für Schritt."]];
    case "terms": return [["Karteikarten daraus", "flashcards", ""], ["Zusammenhang", "ask", "Wie hängen diese Begriffe zusammen?"]];
    case "flashcards": return [];
    default: return [["Einfacher erklären", "explain_simple", ""], ex, ["Zusammenfassen", "summary", ""]];
  }
}

/** Herkunft unter einer gespeicherten Antwort (Erklaerungsspeicher); null bei einer Live-Antwort */
export function storedLabel(explain) {
  if (!explain || explain.stored !== true) return null;
  return explain.source === "cloud" ? "Schon erklärt · sofort da · 0 Credits" : "Schon erklärt · 0 Credits";
}
/** "Neu erklaeren lassen" nur unter einer gespeicherten Antwort */
export const offersRebuild = explain => storedLabel(explain) !== null;

const MONTHS = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"];
/** "neu am 1. Dezember" aus `resets_at` (ISO); null ohne brauchbares Datum */
export function resetLabel(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || "")); if (!m) return null;
  const mo = +m[2]; if (mo < 1 || mo > 12) return null;
  return `neu am ${+m[3]}. ${MONTHS[mo - 1]}`;
}

/** Kostenzeile aus der Antwort des Dienstes (`credits`, `explain`): gespeichert "Schon erklärt · 0 Credits", Wiederholung
 *  "Schon berechnet · 0 Credits", berechnet "– 3 Credits (37 übrig)", sonst der Stand; am eigenen PC (ohne Credits) leer */
export function creditsLine(credits, explain) {
  if (storedLabel(explain)) return "Schon erklärt · 0 Credits";
  if (!credits) return "";
  if (credits.replay) return "Schon berechnet · 0 Credits";
  const n = Number(credits.charged) || 0;
  if (n > 0) return `– ${n === 1 ? "1 Credit" : `${n} Credits`}${Number.isFinite(credits.remaining) ? ` (${credits.remaining} übrig)` : ""}`;
  if (!(credits.allowance > 0)) return "Keine Credits in deinem Tarif";
  const reset = resetLabel(credits.resets_at);
  return `Credits: ${credits.remaining} von ${credits.allowance} übrig${reset ? ` · ${reset}` : ""}`;
}

/** Weg der KI vor der ersten Antwort (GET /api/ai/source, 05.11.2026): am PC mit Konto der Credits-Stand, sonst der Weg */
export function sourceLine(source) {
  if (!source) return "";
  if (source.source === "chatgpt") return "über dein ChatGPT · 0 Credits";
  if (source.source === "studinow") return source.credits ? creditsLine(source.credits, null) : "StudiNow-KI · mit Credits";
  if (source.source === "cli") return "Claude-Kommandozeile (Entwickler)";
  if (source.source === "none") return "Keine KI verbunden";
  return "";
}

/** Fusszeile des Eingabefelds: "Seite 3 · Schon erklärt · 0 Credits"; ohne Antwort der Weg der KI (`source`) */
export function footerLine(page, credits, explain, source = null) {
  const line = creditsLine(credits, explain) || sourceLine(source);
  return `Seite ${page}${line ? ` · ${line}` : ""}`;
}

/** Fehler, unter denen der Weg zum Tarif steht (Credits, Kontingent, Tarif, Abo) */
export const PLAN_CODES = ["credits_exhausted", "quota_exhausted", "plan_required", "subscription_required", "subscription_unverified"];
export const needsPlan = code => PLAN_CODES.includes(code);

/** `history` fuer den Dienst: die letzten Beitraege, Karten als Text */
export function historyFor(messages) {
  return messages.slice(-HISTORY_TURNS).map(m => ({
    role: m.fromUser ? "user" : "assistant",
    text: m.cards?.length ? m.cards.map(c => `${c.question} – ${c.answer}`).join("\n") : m.text,
  }));
}

/** Anschlussfragen nur unter der letzten Antwort des Gespraechs */
export function showsFollowUps(index, messages) {
  const m = messages[index]; if (!m || m.fromUser) return false;
  for (let i = messages.length - 1; i >= 0; i--) if (!messages[i].fromUser) return i === index;
  return false;
}

/** Fehlertext: `detail` als Text oder {detail, code} (der Dienst) */
export function errorText(j, fallback = "") {
  const d = j?.detail;
  if (typeof d === "string") return d;
  if (d && typeof d.detail === "string") return d.detail;
  return fallback;
}
export const errorCode = j => j?.code || j?.detail?.code || null;

/** Quellen mit Seite aus der Antwort: [n] im Text wird zum Link, darunter die Liste der genannten (oder aktuellen) */
export function sourceLinks(html, sources, esc) {
  const src = Array.isArray(sources) ? sources : [], known = new Set(src.map(x => String(x.n)));
  const body = html.replace(/\[(\d{1,2})\]/g, (m, n) => known.has(n) ? `<a href="#" class="ed-src" data-src="${n}">[${n}]</a>` : m);
  const list = src.filter(x => x.cited || x.current).map(x => `<li><a href="#" class="ed-src" data-src="${x.n}">[${x.n}] ${esc(x.title || x.name || "Datei")}${x.studip_id ? " (Stud.IP)" : `, Seite ${x.page}`}</a>${x.current ? ` <span class="muted">(diese Seite)</span>` : ""}</li>`).join("");
  return body + (list ? `<div class="ed-ai-src"><b>Quellen</b><ul>${list}</ul></div>` : "");
}

/** Farbe eines Modus-Knopfes: der Reiter, zu dem er gehoert (Quizfragen liegen im Reiter Test) */
export const tabClass = mode => tabOf(mode) || (mode === "quiz" ? "test" : "explain");

// ---------------------------------------------------------------- eigene Notizen mitschicken (wie AttachedNotes auf dem iPad)
export const OWN_NOTES_CHARS = 4000;                 // wie ai.OWN_NOTES_CHARS
/** Text der Notizseiten (side-notes.js notePages) fuer `own_notes`: Textfelder und Haftnotizen wie SN.typedText, dazu
 *  Handschrift nur mit erkanntem Text (vom iPad), in Reihenfolge, hoechstens OWN_NOTES_CHARS */
export function notesText(doc, keys) {
  const parts = [];
  for (const k of keys || []) for (const o of doc?.pages?.[k]?.objects || []) {
    const t = o?.type === "text" ? o.text : (o?.type === "stroke" ? (o.recognizedText || o.recognized_text) : null);
    if (typeof t === "string" && t.trim()) parts.push(t.trim());
  }
  return parts.join("\n").slice(0, OWN_NOTES_CHARS);
}

/** Leerzustand als Einladung */
export const emptyHtml = icon => `<div class="ed-ai-empty"><b>${icon("sparkles", 15)} Frag etwas zur offenen Seite</b><p class="muted small">Oder wähle oben Erklären, Karteikarten oder Test. Markierter Text wird mitgeschickt.</p></div>`;

/** HTML der Leiste (Reiter, Aktionen, Gespraech, Eingabe); `icon(name, size)` aus icons.js */
export function panelHtml(icon, esc = s => s) {
  const tabs = TABS.map((t, i) => `<button type="button" role="tab" class="ed-ai-tab t-${t.id}${i === 0 ? " on" : ""}" id="edAiTab-${t.id}" data-tab="${t.id}" aria-selected="${i === 0}" aria-controls="edAiPane-${t.id}">${icon(t.icon, 15)}<span>${esc(t.title)}</span></button>`).join("");
  const chip = (mode, ic, label = MODE_LABELS[mode], extra = "") => `<button type="button" class="ed-ai-chip t-${tabClass(mode)}" data-mode="${mode}"${extra}>${icon(ic, 13)} ${esc(label)}</button>`;
  return `
    <div class="ed-ai-head"><strong>${icon("sparkles", 16)} KI-Hilfe</strong><span class="ed-ai-page"></span>
      <a class="btn ghost icon sm ed-ai-start" href="#/ki" title="KI-Start öffnen" aria-label="KI-Start öffnen">${icon("grid", 16)}</a>
      <button type="button" class="btn ghost sm ed-ai-new" hidden>Neu</button>
      <button type="button" class="ed-ai-close" aria-label="KI-Hilfe schließen">${icon("x", 16)}</button></div>
    <div class="ed-ai-tabs" role="tablist" aria-label="Bereiche der KI-Hilfe">${tabs}</div>
    <div class="ed-ai-acts">
      <div class="ed-ai-pane" role="tabpanel" id="edAiPane-explain" aria-labelledby="edAiTab-explain" data-pane="explain">
        <div class="ed-ai-scoperow"><label class="small">Umfang <select class="ed-ai-scope">${SCOPES.map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join("")}</select></label>
          <span class="ed-ai-range small" hidden>Seiten <input class="ed-ai-from" type="number" min="1" value="1"> bis <input class="ed-ai-to" type="number" min="1" value="1"></span></div>
        <div class="ed-ai-chips">${CHIPS.map(([m, t]) => `<button type="button" class="ed-ai-chip t-explain ed-ai-doc" data-doc="${m}">${icon("sparkles", 13)} ${esc(t)}</button>`).join("")}</div>
        <div class="ed-ai-chips">${TABS[0].modes.map(m => chip(m, m === "explain" ? "sparkles" : "file-text")).join("")}</div>
      </div>
      <div class="ed-ai-pane" role="tabpanel" id="edAiPane-cards" aria-labelledby="edAiTab-cards" data-pane="cards" hidden>
        <p class="muted small">Karten aus der offenen Seite – du siehst jede Karte, bevor sie gespeichert wird.</p>
        <div class="ed-ai-chips">${chip("flashcards", "cards", "Karteikarten zur Seite erstellen")}</div>
      </div>
      <div class="ed-ai-pane" role="tabpanel" id="edAiPane-test" aria-labelledby="edAiTab-test" data-pane="test" hidden>
        <div class="ed-ai-chips">${chip("similar", "refresh")}${chip("check", "check", "Lösung prüfen", ' aria-pressed="false"')}${chip("quiz", "exam", "5 Quizfragen")}
          <a class="ed-ai-chip t-test" href="#/exams" title="Wochentest mit Aufgabenzahl, Schwierigkeit und Aufgabenarten">${icon("exam", 13)} Wochentest erstellen</a></div>
      </div>
    </div>
    <div class="ed-ai-out" aria-live="polite">${emptyHtml(icon)}</div>
    <div class="ed-ai-status muted small" hidden></div>
    <form class="ed-ai-form" autocomplete="off">
      <details class="ed-ai-seldet"><summary>Markierter Text</summary><textarea class="ed-ai-sel" rows="3" placeholder="Mit dem Werkzeug „Text markieren“ (¶) oder hier einfügen"></textarea></details>
      <label class="small ed-ai-ctxl"><input type="checkbox" class="ed-ai-ctx" checked> Aktuelle Seite als Kontext mitgeben</label>
      <div class="ed-ai-composer"><span class="ed-ai-checkpill" hidden>${icon("check", 12)} Lösung prüfen <button type="button" class="ed-ai-checkoff" aria-label="Lösung prüfen beenden">${icon("x", 12)}</button></span>
        <textarea class="ed-ai-q" rows="2" placeholder="Frag etwas zur Seite …" aria-label="Frage an die KI"></textarea>
        <button type="submit" class="btn primary icon ed-ai-go" aria-label="Senden" title="Senden (Enter)">${icon("arrow-right", 16)}</button></div>
      <div class="ed-ai-foot muted tiny" aria-live="polite"></div>
    </form>`;
}

/** Gespraech der KI-Hilfe je Dokument laden und speichern (GET/PUT/DELETE /api/tutor-conversations/<Datei>, app/recent.py).
 *  `onLoad(messages)` bekommt das gespeicherte Gespraech; Fehler bleiben still (ohne Abo nur lesen, offline). */
export function conversationStore(fileId, nameOf, onLoad, fetchFn = (...a) => fetch(...a)) {
  const url = fileId ? `/api/tutor-conversations/${encodeURIComponent(fileId)}` : null;
  let timer = null;
  const put = msgs => fetchFn(url, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ file_name: nameOf() || "", messages: msgs }) }).catch(() => {});
  const ready = url ? fetchFn(url).then(r => (r.ok ? r.json() : null)).then(c => { if (Array.isArray(c?.messages)) onLoad(c.messages); }).catch(() => {}) : Promise.resolve();
  return {
    ready,
    save(msgs) { if (!url) return; clearTimeout(timer); const copy = msgs.slice(); timer = setTimeout(() => put(copy), 300); },
    clear() { if (!url) return; clearTimeout(timer); fetchFn(url, { method: "DELETE" }).catch(() => {}); },
  };
}

/** Leiste in den Editor haengen. `ed` = Editor (pages, currentPage, fileId, model, c, pageText, docRun, goToPage, ...);
 *  `deps` = { $, $$, icon, esc, md, uid } aus editor.js. */
export function createAiPanel(ed, deps) {
  const { $, $$, icon, esc, md, uid } = deps;
  const root = $(".ed-ai", ed.c);
  const st = { tab: "explain", messages: [], busy: false, checking: false, credits: null, explain: null, source: null };
  // Weitermachen (04.11.2026 wie TutorConversations.swift): Gespraech je Dokument im eigenen Datenbestand (app/recent.py)
  const conv = conversationStore(ed.fileId, () => ed.name, msgs => { if (!st.messages.length && msgs.length) { st.messages = msgs; renderAll(); } });
  root.innerHTML = panelHtml(icon, esc);
  const q = sel => $(sel, root);
  const out = () => q(".ed-ai-out");

  const page = () => { const pg = ed.pages[ed.currentPage]; return pg ? ed.pages.indexOf(pg) + 1 : 1; };
  function updateFooter() { q(".ed-ai-foot").textContent = footerLine(page(), st.credits, st.explain, st.source); q(".ed-ai-page").textContent = `Seite ${page()}`; }
  // Weg der KI und Credits-Stand (am PC ueber das StudiNow-Konto), bevor die erste Antwort da ist
  fetch("/api/ai/source").then(r => r.ok ? r.json() : null).then(s => { st.source = s; updateFooter(); }).catch(() => {});
  function setTab(id) {
    st.tab = id;
    $$(".ed-ai-tab", root).forEach(b => { const on = b.dataset.tab === id; b.classList.toggle("on", on); b.setAttribute("aria-selected", String(on)); });
    $$(".ed-ai-pane", root).forEach(p => { p.hidden = p.dataset.pane !== id; });
  }
  function setChecking(on) {
    st.checking = !!on;
    q(".ed-ai-checkpill").hidden = !on;
    const chip = q('[data-mode="check"]'); chip.classList.toggle("on", !!on); chip.setAttribute("aria-pressed", String(!!on));
    q(".ed-ai-q").placeholder = on ? "Deine Lösung oder deinen Rechenweg eintragen" : "Frag etwas zur Seite …";
    q(".ed-ai-go").title = on ? "Lösung prüfen" : "Senden (Enter)";
    if (on) q(".ed-ai-q").focus();
  }
  function setBusy(on, label = "") {
    st.busy = on;
    const s = q(".ed-ai-status"); s.hidden = !on; s.innerHTML = on ? `<span class="uf-shimmer">${esc(label || "Die KI denkt nach …")}</span>` : "";
    q(".ed-ai-go").disabled = on;
    $$(".ed-ai-chip, .ed-ai-doc", root).forEach(b => { if (b.tagName === "BUTTON") b.disabled = on; });
  }
  function scroll() { const o = out(); o.scrollTop = o.scrollHeight; root.scrollTop = root.scrollHeight; }
  function clearEmpty() { q(".ed-ai-empty")?.remove(); q(".ed-ai-new").hidden = false; }

  const bubble = (text, quote) => `<div class="ed-ai-me">${esc(text).replace(/\n/g, "<br>")}${quote ? `<div class="ed-ai-quote">„${esc(quote.slice(0, 160))}${quote.length > 160 ? " …" : ""}“</div>` : ""}</div>`;
  /** neuer Beitrag fuer das ganze Dokument (editor.js docRun): Frage als Blase, Antwortbereich darunter */
  function turn(label) {
    clearEmpty();
    const o = out(); o.insertAdjacentHTML("beforeend", bubble(label));
    const a = document.createElement("div"); a.className = "ed-ai-bot ed-turn-a"; o.append(a); scroll(); return a;
  }

  function renderAnswer(m, index) {
    const wrap = document.createElement("div"); wrap.className = "ed-ai-bot";
    if (m.cards?.length) {
      wrap.innerHTML = `<div class="ed-cards">${m.cards.map(c => `<div class="ed-card"><b>${esc(c.question)}</b><div>${esc(c.answer)}</div></div>`).join("")}</div>
        <button type="button" class="btn sm ed-cards-save"${m.saved ? " disabled" : ""}>${icon("cards", 14)} ${m.saved ? "In Karteikarten gespeichert ✓" : `Als Karteikarten speichern (${m.cards.length})`}</button>`;
      $(".ed-cards-save", wrap).onclick = async e => {
        const b = e.currentTarget; b.disabled = true;
        try {
          const r = await fetch("/api/flashcards", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ file_id: ed.fileId, cards: m.cards }) });
          if (!r.ok) throw new Error(errorText(await r.json().catch(() => ({})), r.statusText));
          m.saved = true; b.innerHTML = `${icon("cards", 14)} In Karteikarten gespeichert ✓`; conv.save(st.messages);
        } catch (err) { b.disabled = false; ed.onStatus(`Karten nicht gespeichert: ${err.message}`); }
      };
    } else {
      const stored = storedLabel(m.explain);
      wrap.innerHTML = sourceLinks(md(m.text), m.sources, esc)
        + `<div class="ed-ai-actions"><button type="button" class="btn sm ed-ai-insert">Als Textfeld einfügen</button></div>`
        + (stored ? `<div class="ed-ai-stored"><span class="ed-ai-storedl">${icon("check", 13)} ${esc(stored)}</span> <button type="button" class="btn ghost sm ed-ai-rebuild">${icon("refresh", 13)} Neu erklären lassen</button></div>` : "");
      $$(".ed-src", wrap).forEach(a => a.onclick = e => {
        e.preventDefault(); const x = (m.sources || []).find(s => String(s.n) === a.dataset.src); if (!x) return;
        if (x.studip_id) { if (/^https?:\/\//.test(x.url || "")) window.open(x.url, "_blank", "noopener"); return; }
        if (x.file_id === ed.fileId) { const i = ed.pages.findIndex(p => p.type === "pdf" && p.index === +x.page); if (i >= 0) ed.goToPage(i); }
        else location.hash = `#/doc/${encodeURIComponent(x.file_id)}?page=${x.page}`;
      });
      $(".ed-ai-insert", wrap).onclick = () => insertText(m.text);
      $(".ed-ai-rebuild", wrap)?.addEventListener("click", () => ask(m.mode, { force: true }));
    }
    if (showsFollowUps(index, st.messages)) {
      const fu = followUps(m.mode);
      if (fu.length) {
        const row = document.createElement("div"); row.className = "ed-ai-chips ed-ai-fu";
        row.innerHTML = fu.map(([label, mode, question], i) => `<button type="button" class="ed-ai-chip t-${tabClass(mode)}" data-fu="${i}">${icon("sparkles", 13)} ${esc(label)}</button>`).join("");
        $$("[data-fu]", row).forEach(b => b.onclick = () => { const [, mode, question] = fu[+b.dataset.fu]; q(".ed-ai-q").value = question; ask(mode); });
        wrap.append(row);
      }
    }
    return wrap;
  }
  function renderAll() {
    const o = out(); o.innerHTML = "";
    if (!st.messages.length) { o.innerHTML = emptyHtml(icon); q(".ed-ai-new").hidden = true; return; }
    q(".ed-ai-new").hidden = false;
    st.messages.forEach((m, i) => { if (m.fromUser) o.insertAdjacentHTML("beforeend", bubble(m.text, m.quote)); else o.append(renderAnswer(m, i)); });
    scroll();
  }
  function insertText(text) {
    const pg = ed.pages[ed.currentPage]; if (!pg?.mounted) return;
    const before = ed.snapshot(pg);
    const o = { id: uid(), type: "text", x: 20, y: 20, text: String(text).replace(/[*#`]/g, ""), ...ed.textStyle, bg: "#e8eeff", width: Math.min(320, pg.w - 40), fontSize: 11, rotation: 0, scaleX: 1, scaleY: 1 };
    ed.model.pages[pg.key].objects.push(o); ed.addNode(pg, o); pg.layer.batchDraw(); ed.commit(pg, before);
  }

  /** Notiztext einer Folie mit ihren Seitennotizen und den Blaettern daneben (side-notes.js); leer ohne Notizen */
  async function ownNotesFor(pageKey) {
    try {
      const SN = await import("./side-notes.js?v=1");
      const sheets = await SN.loadSheets(ed.model, async u => { const r = await fetch(u); if (!r.ok) throw new Error(String(r.status)); return r.json(); });
      const doc = sheets.length ? SN.interleaved(ed.model, sheets) : ed.model;
      return notesText(doc, SN.notePages(doc, pageKey));
    } catch { return ""; }
  }

  /** Eine Frage an die KI. mode: ask | explain | … | quiz; opts.force = "Neu erklaeren lassen" */
  async function ask(mode = "ask", opts = {}) {
    if (st.busy) return;
    const input = q(".ed-ai-q"), typed = input.value.trim();
    if (mode === "ask" && st.checking) mode = "check";
    // Umfang "Ganzes Dokument"/"Seiten": Erklaeren, Zusammenfassen, Fachbegriffe -> Vorlesung; Aufgabe/Hinweise -> alle Aufgaben
    const dm = opts.force ? null : docModeFor(mode, q(".ed-ai-scope").value);
    if (dm) { await ed.docRun(dm); return; }
    const selection = (opts.selection ?? q(".ed-ai-sel").value).trim();
    // Wunsch fuers ganze Dokument in der Frage ("Erkläre die ganze Vorlesung", "Löse alle Aufgaben", "Seiten 5 bis 12")
    if (mode === "ask" && typed && !selection && opts.docIntent !== false && await ed.docRun(null, typed)) { input.value = ""; return; }
    if (mode === "check" && !typed) { ed.onStatus("Trag zuerst deine Lösung ein."); input.focus(); return; }
    const pg = ed.pages[ed.currentPage];
    const body = { file_id: ed.fileId, page: pg?.type === "pdf" ? pg.index : null, mode: mode === "quiz" ? "similar" : mode, selection,
      question: mode === "check" ? "" : typed + (mode === "quiz" ? (typed ? " " : "") + "Erstelle 5 Quizfragen mit Lösungen zur Seite." : ""),
      own_solution: mode === "check" ? typed : "", page_text: "", history: historyFor(st.messages) };
    if (opts.force) body.force = true;
    if (q(".ed-ai-ctx").checked && pg?.type === "pdf") body.page_text = await ed.pageText(pg.index);
    // Seitennotizen und Blaetter neben der Folie gehen mit (docs/NOTIZEN-MITSCHICKEN-2026-11-05.md 4.3); dann nutzt der
    // Server nie den geteilten Erklaerungsspeicher (persoenlicher Inhalt)
    if (pg?.type === "pdf") { const notes = await ownNotesFor(pg.key); if (notes) body.own_notes = notes; }
    if (pg?.type === "blank" && q(".ed-ai-ctx").checked) body.page_text = (ed.model.pages[pg.key].objects.filter(o => o.type === "text").map(o => o.text).join("\n")) + "\n[Handschrift auf Notizseiten kann nicht gelesen werden]";
    const tab = tabOf(mode); if (tab && tab !== st.tab && mode !== "check") setTab(tab);
    const mine = { fromUser: true, text: userLabel(mode, typed, !!opts.force), quote: selection };
    st.messages.push(mine); input.value = ""; q(".ed-ai-sel").value = "";
    if (mode === "check") setChecking(false);
    clearEmpty(); out().insertAdjacentHTML("beforeend", bubble(mine.text, mine.quote)); scroll();
    setBusy(true, "Die KI liest die Seite …");
    try {
      const r = await fetch("/api/ai/tutor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { const e = new Error(errorText(j, r.statusText)); e.code = errorCode(j); throw e; }
      const a = { fromUser: false, text: j.answer || "", cards: mode === "flashcards" && Array.isArray(j.cards) ? j.cards : [], sources: j.sources || [], mode: mode === "quiz" ? "similar" : mode, explain: j.explain || null };
      st.messages.push(a); st.credits = j.credits || null; st.explain = a.explain; conv.save(st.messages);
      renderAll(); updateFooter();
    } catch (e) {
      // Frage ohne Antwort nicht im Verlauf lassen, Eingabe zurueck ins Feld
      st.messages.pop(); input.value = typed; q(".ed-ai-sel").value = selection; renderAll();
      out().insertAdjacentHTML("beforeend", `<div class="ed-err" role="alert">Fehler: ${esc(e.message)}${needsPlan(e.code) ? ` <a href="#/abo">Tarif ansehen</a>` : ""}</div>`); scroll();
    } finally { setBusy(false); }
  }

  // ---- Ereignisse
  $$(".ed-ai-tab", root).forEach(b => b.onclick = () => setTab(b.dataset.tab));
  $$(".ed-ai-chip[data-mode]", root).forEach(b => b.onclick = () => { const m = b.dataset.mode; if (m === "check") setChecking(!st.checking); else ask(m); });
  $$(".ed-ai-doc", root).forEach(b => b.onclick = () => ed.docRun(b.dataset.doc));
  q(".ed-ai-scope").onchange = e => { q(".ed-ai-range").hidden = e.target.value !== "range"; };
  q(".ed-ai-close").onclick = () => { root.hidden = true; };
  q(".ed-ai-new").onclick = () => { if (st.busy) return; st.messages = []; st.credits = null; st.explain = null; renderAll(); updateFooter(); conv.clear(); };
  q(".ed-ai-checkoff").onclick = () => setChecking(false);
  q(".ed-ai-form").onsubmit = e => { e.preventDefault(); ask(st.checking ? "check" : "ask"); };
  q(".ed-ai-q").addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); q(".ed-ai-form").requestSubmit(); } });

  updateFooter();
  return {
    ask, turn, setTab, setBusy, updateFooter, get busy() { return st.busy; }, get messages() { return st.messages; },
    /** Seite hat gewechselt: Kopfzeile und Fusszeile nachziehen */
    pageChanged: updateFooter,
    /** Fehler im Antwortbereich (ohne Beitrag) */
    error(msg) { clearEmpty(); out().insertAdjacentHTML("beforeend", `<div class="ed-err" role="alert">Fehler: ${esc(msg)}</div>`); scroll(); },
    /** "An den KI-Tutor" aus dem markierten PDF-Text: Panel auf, Text uebernehmen, Erklaerung dazu (wie auf dem iPad) */
    sendSelection(text, mode = "explain") { root.hidden = false; q(".ed-ai-sel").value = text; setTab("explain"); return ask(mode, { selection: text }); },
    open() { root.hidden = false; updateFooter(); },
  };
}

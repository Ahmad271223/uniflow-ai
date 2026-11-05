// Fenster "Antworten" / "Allen antworten" zur Seite "Nachrichten" (Windows/Einzelplatz, 05.11.2026), nach
// MessageReplySheet.swift der iPad-App (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md). An (Absender, bei "Alle" die weiteren
// Empfaenger, Umschalter), Betreff "RE: …", Text, "Original zitieren" (aus, Zitat grau darunter), Hinweis, Senden.
// Entwurf bei jeder Aenderung (PUT …/draft, nur dieser PC), beim naechsten Oeffnen "Entwurf vom … wiederhergestellt".
// Fehler mit Ausweg "In Stud.IP antworten" (Schreibfenster mit answer_to im App-Fenster) bzw. Anmeldung bei der
// Hochschule. Gesendet wird nur auf "Senden" (POST …/reply), nie still wiederholt. Regeln: message-reply-logic.js.
import { $, api, icon, modal, toast, debounce } from "./core.js?v=45";
import * as R from "./message-reply-logic.js?v=3";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const path = id => `/studip/messages/${encodeURIComponent(id)}`;

/** Leser ergaenzen: Knoepfe und eigene Antwort vor dem Datenschutz-Hinweis */
export function decorateReader(box, m, { onSent } = {}) {
  const html = R.readerReplyHtml(m, { icon });
  const note = box.querySelector("p.muted.tiny:last-of-type");
  if (note) {
    if (R.isReplyable(m)) note.textContent = `${note.textContent} ${R.replyChannel(m.id)}`;
    if (html) note.insertAdjacentHTML("beforebegin", html);
  }
  box.querySelectorAll("[data-reply]").forEach(b => b.onclick = () => openReply(m, b.dataset.reply, { onSent }));
}

function errorHtml(e, m) {
  const web = e.webUrl || m.reply_url;
  return `<div class="msg-reply-err" role="alert"><p>${icon("alert", 15)} ${esc(e.message)}</p><div class="row wrap">`
    + (R.needsLogin(e.code) ? `<button type="button" class="btn sm primary" data-login>${icon("log-out", 14)} ${esc(R.TEXTS.login)}</button>` : "")
    + (R.offersWebFallback(e.code) && web ? `<a class="btn sm" href="${esc(web)}" target="_blank" rel="noopener">${esc(R.webFallbackLabel(m?.id))} ${icon("arrow-right", 14)}</a>` : "")
    + `</div></div>`;
}

async function failure(r) {
  // api() kennt web_url nicht: Koerper hier selbst lesen
  let d = {};
  try { d = await r.json(); } catch {}
  const e = new Error(d.detail || `Fehler ${r.status}`);
  Object.assign(e, { code: d.code, webUrl: d.web_url, status: r.status });
  return e;
}

async function call(p, opts = {}) {
  const r = await fetch("/api" + p, { headers: { "Content-Type": "application/json" }, ...opts, body: opts.body ? JSON.stringify(opts.body) : undefined });
  if (!r.ok) throw await failure(r);
  return r.json();
}

/** Antwortfenster; mode "sender" oder "all" */
export async function openReply(m, mode = "sender", { onSent } = {}) {
  const box = modal(`<h3>${icon("reply", 18)} ${esc(mode === "all" ? R.TEXTS.replyAll : R.TEXTS.reply)}</h3><div id="rpBody" aria-live="polite"><p class="muted"><span class="uf-shimmer">${esc(R.TEXTS.loading)}</span></p></div>`);
  const body = $("#rpBody", box);
  let ctx;
  try { ctx = await call(`${path(m.id)}/reply?all=${mode === "all" ? 1 : 0}`); }
  catch (e) { body.innerHTML = errorHtml(e, m) + `<div class="modal-foot"><button class="btn" data-close>Schließen</button></div>`; wire(); return; }

  const d = ctx.draft;
  const cur = { mode: mode === "all" && ctx.allows_reply_all ? "all" : "sender",
    subject: d?.subject || ctx.reply_subject, text: d?.text || "", quote: !!d?.quote };
  const others = ctx.others || [];
  const toggle = ctx.allows_reply_all && others.length
    ? `<div class="seg" role="group" aria-label="Empfänger"><button type="button" data-mode="sender">${esc(R.TEXTS.onlySender)}</button><button type="button" data-mode="all">${esc(R.allLabel(others.length + 1))}</button></div>` : "";
  body.innerHTML = `${d ? `<p class="small muted">${esc(R.draftRestored(d.saved_at))}</p>` : ""}
    <div class="field"><span>An</span><div class="row wrap" style="gap:.5rem"><b id="rpTo"></b>${toggle}</div>${ctx.is_circular ? `<p class="small muted">${esc(R.circularNote(ctx.other_count + 1))}</p>` : ""}</div>
    ${ctx.no_subject ? "" : `<label class="field"><span>Betreff</span><input class="input" id="rpSubject" maxlength="250" value="${esc(cur.subject)}"></label>`}
    <label class="field"><span>Text</span><textarea class="input" id="rpText" rows="7" maxlength="20000" aria-required="true">${esc(cur.text)}</textarea></label>
    <label class="row small" style="gap:.4rem"><input type="checkbox" id="rpQuote" ${cur.quote ? "checked" : ""}> ${esc(R.TEXTS.quote)}</label>
    <pre class="msg-quote muted small" id="rpQuoteText" ${cur.quote ? "" : "hidden"}>${esc(ctx.quote)}</pre>
    <p class="small muted">${icon("info", 13)} ${esc(ctx.notice || R.TEXTS.notice)}</p>
    <div id="rpErr"></div>
    <div class="modal-foot">${d ? `<button class="btn ghost" id="rpDiscard">${esc(R.TEXTS.discard)}</button>` : ""}<span class="spacer"></span><button class="btn" data-close>Abbrechen</button><button class="btn primary" id="rpSend" disabled>${icon("reply", 15)} ${esc(R.TEXTS.send)}</button></div>`;

  const send = $("#rpSend", box), text = $("#rpText", box);
  const paint = () => {
    $("#rpTo", box).textContent = R.toLine(ctx, cur.mode);
    box.querySelectorAll("[data-mode]").forEach(b => { b.classList.toggle("active", b.dataset.mode === cur.mode); b.setAttribute("aria-pressed", String(b.dataset.mode === cur.mode)); });
    send.disabled = !R.canSend(cur.text);
  };
  const save = debounce(() => {
    api(`${path(m.id)}/draft`, { method: "PUT", body: cur }).catch(() => {});
  }, 500);
  box.querySelectorAll("[data-mode]").forEach(b => b.onclick = () => { cur.mode = b.dataset.mode; paint(); save(); });
  const subj = $("#rpSubject", box);          // Learnweb (Uni Hildesheim): Unterhaltungen ohne Betreff
  if (subj) subj.oninput = e => { cur.subject = e.target.value; save(); };
  text.oninput = e => { cur.text = e.target.value; paint(); save(); };
  $("#rpQuote", box).onchange = e => { cur.quote = e.target.checked; $("#rpQuoteText", box).hidden = !cur.quote; save(); };
  const disc = $("#rpDiscard", box);
  if (disc) disc.onclick = async () => { await api(`${path(m.id)}/draft`, { method: "DELETE" }).catch(() => {}); cur.text = ""; text.value = ""; cur.quote = false; $("#rpQuote", box).checked = false; $("#rpQuoteText", box).hidden = true; disc.remove(); paint(); };
  send.onclick = async () => {
    if (!R.canSend(cur.text)) return;
    send.disabled = true; send.innerHTML = `<span class="uf-shimmer">Wird gesendet …</span>`;
    try {
      const r = await call(`${path(m.id)}/reply`, { method: "POST", body: cur });
      const names = [ctx.sender?.name || "Absender", ...(cur.mode === "all" ? others.map(o => o.name) : [])];
      body.innerHTML = `<div class="msg-sent"><p><span class="badge ok">${icon("check", 13)} ${esc(R.TEXTS.sent)}</span></p><p>${esc(R.sentLine(names))}</p><p class="small muted">${esc(r.record?.line || "")}</p>
        ${r.outbox_url ? `<p><a href="${esc(r.outbox_url)}" target="_blank" rel="noopener">${ctx.source === "learnweb" ? "Unterhaltung im Learnweb ansehen" : ctx.source === "moodle" ? "Unterhaltung in Moodle ansehen" : "In Stud.IP unter „Gesendet“ ansehen"}</a></p>` : ""}</div>
        <div class="modal-foot"><button class="btn primary" data-close>${esc(R.TEXTS.done)}</button></div>`;
      wire();
      onSent?.(r.record);
    } catch (e) {
      $("#rpErr", box).innerHTML = errorHtml(e, m); wireErr();
      send.innerHTML = `${icon("reply", 15)} ${esc(R.TEXTS.send)}`; send.disabled = !R.canSend(cur.text);
    }
  };
  paint(); text.focus();

  function wireErr() {
    box.querySelectorAll("[data-login]").forEach(b => b.onclick = async () => {
      try { await api("/university/login", { method: "POST" }); toast("Anmeldefenster öffnet sich – dort anmelden; dein Entwurf bleibt erhalten", 5000); }
      catch (x) { toast(x.message, 4000); }
    });
  }
  function wire() { box.querySelectorAll("[data-close]").forEach(b => b.onclick = () => box.remove()); wireErr(); }
}

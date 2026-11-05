// Antworten auf Stud.IP-Nachrichten (Windows/Einzelplatz, 05.11.2026): reine Regeln und Texte ohne DOM (laeuft unter node,
// tests/js/message-reply.test.mjs). Gleiche Regeln und Texte wie MessageReplySheet.swift / StudIPMessageReply.swift der
// iPad-App (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md). Das Fenster steht in message-reply.js, die Daten kommen von
// GET/POST /api/studip/messages/{id}/reply (app/studip_reply.py). Gesendet wird nur auf "Senden", nie still wiederholt.

export const MAX_REPLY_ALL = 20;

export const TEXTS = {
  reply: "Antworten",
  replyAll: "Allen antworten",
  openStudIP: "In Stud.IP antworten",
  notice: "Wird über Stud.IP unter deinem Namen gesendet. Die Empfänger sehen deinen Namen.",
  quote: "Original zitieren",
  send: "Senden",
  sent: "Gesendet",
  done: "Fertig",
  discard: "Entwurf verwerfen",
  ownReply: "Deine Antwort",
  privacyExtra: "Antworten gehen über Stud.IP unter deinem Namen.",
  onlySender: "Nur Absender",
  loading: "Empfänger werden aus Stud.IP gelesen …",
  login: "Bei der Hochschule anmelden",
};

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Systemnachricht (Absender "Stud.IP" oder leer): kein Antworten */
export const isReplyable = m => !!m && (m.replyable ?? (String(m.sender || "").trim() !== "" && String(m.sender).trim() !== "Stud.IP"));

/** "Allen antworten" im Leser: Zahl der Empfaenger (mit einem selbst) 2 bis 21 */
export const offersReplyAll = n => Number.isInteger(n) && n >= 2 && n - 1 <= MAX_REPLY_ALL;

/** "RE: " davor wie Stud.IP im Browser, nicht doppelt */
export function replySubject(subject) {
  const s = String(subject || "").trim();
  if (!s || s === "(ohne Betreff)") return "RE: ";
  return /^(re:|aw:|re :|antw:)/i.test(s) ? s : "RE: " + s;
}

/** Umschalter "Nur Absender / Alle (n)" */
export const allLabel = n => `Alle (${n})`;

/** Kopf "An": Namen, bei Rundnachricht der Hinweis */
export function toLine(ctx, mode) {
  if (!ctx) return "";
  const names = [ctx.sender?.name || "Absender"];
  if (mode === "all") names.push(...(ctx.others || []).map(o => o.name));
  return names.join(", ");
}

export const circularNote = n => `Rundnachricht an ${n} Personen – die Antwort geht nur an den Absender`;

/** Senden erst mit Text */
export const canSend = text => String(text || "").trim().length > 0;

/** "Entwurf vom 05.11., 14:30 wiederhergestellt" (Ortszeit) */
export function draftRestored(savedAt) {
  const d = new Date(savedAt);
  if (Number.isNaN(d.getTime())) return "Entwurf wiederhergestellt";
  const p = n => String(n).padStart(2, "0");
  return `Entwurf vom ${p(d.getDate())}.${p(d.getMonth() + 1)}., ${p(d.getHours())}:${p(d.getMinutes())} wiederhergestellt`;
}

/** "Gesendet an Prof. Test, Bob" */
export const sentLine = names => `${TEXTS.sent} an ${names.join(", ")}`;

/** Fehler mit Ausweg "In Stud.IP antworten" (alles ausser Netz, Anmeldung und nicht verbunden) */
export const offersWebFallback = code => !!code && !["reply_offline", "studip_login", "studip_not_connected", "reply_empty"].includes(code);

/** Anmeldung noetig */
export const needsLogin = code => code === "studip_login" || code === "studip_not_connected";

/** Leser: Knoepfe, "Beantwortet am …" und die eigene Antwort (aufklappbar) */
export function readerReplyHtml(m, { icon = () => "" } = {}) {
  if (!m) return "";
  const replies = Array.isArray(m.replies) ? m.replies : [];
  const badge = replies.length ? `<div class="msg-replied-line"><span class="badge ok">${icon("check", 12)} ${esc(replies[0].line || "Beantwortet")}</span></div>
    <details class="msg-own"><summary>${esc(TEXTS.ownReply)}</summary><div class="msg-text">${esc(replies[0].text || "")}</div></details>` : "";
  if (!isReplyable(m)) return badge;
  const all = offersReplyAll(m.recipients) ? `<button type="button" class="btn" data-reply="all">${icon("users", 15)} ${esc(TEXTS.replyAll)}</button>` : "";
  return `${badge}<div class="row wrap msg-reply-btns"><button type="button" class="btn primary" data-reply="sender">${icon("reply", 15)} ${esc(TEXTS.reply)}</button>${all}</div>`;
}

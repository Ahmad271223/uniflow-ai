// Seite "Nachrichten" (Windows/Einzelplatz, 05.11.2026): reine Regeln und Texte, ohne DOM (laeuft auch unter node,
// tests/js/messages.test.mjs). Gleiche Regeln und Texte wie MessagesPage.swift / MessagesInbox.swift der iPad-App
// (Commit 1f99d9b); die Seite selbst steht in messages.js, die Daten kommen von GET /api/studip/messages
// (app/studip_messages.py). Datenschutz: nur die Liste des Posteingangs, nie die Einzelansicht, nichts wird in Stud.IP
// als gelesen markiert, nichts geht an die KI oder einen Dienst; die Antworten bleiben aus dem Offline-Speicher (sw-policy.js).

export const TEXTS = {
  title: "Nachrichten",
  open: "In Stud.IP öffnen",
  empty: "Keine Nachrichten",
  searchPrompt: "Nachrichten durchsuchen",
  back: "Nachrichten",
  pick: "Wähle links eine Nachricht aus.",
  noText: "Diese Nachricht hat keinen Text.",
  noSubject: "(ohne Betreff)",
  privacy: "Nachrichten bleiben nur auf diesem Gerät; StudiNow markiert sie in Stud.IP nicht als gelesen.",
  sync: "Mit Stud.IP abgleichen",
};

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export { esc };

/** "Keine Treffer für „xyz“" */
export const noHits = q => `Keine Treffer für „${q}“`;

/** "3 Nachrichten", "1 Nachricht" */
export const countText = n => n === 1 ? "1 Nachricht" : `${n} Nachrichten`;

/** Nur http(s)-Adressen werden zu Links (sonst ""). */
export const httpUrl = u => /^https?:\/\/[^/\s]/i.test(String(u ?? "")) ? String(u) : "";

/** Zeitpunkt einer Stud.IP-Zeitangabe mit Zeitzone ("2026-11-02T08:15:00+01:00"); null, wenn unlesbar oder ohne Zeitzone */
export function instant(s) {
  if (typeof s !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$/.test(s)) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

/** Neuer als die Marke? Ohne Marke ja; verglichen wird der Zeitpunkt, ohne lesbaren Zeitpunkt der Text. */
export function isNew(sentAt, mark) {
  if (!mark) return true;
  if (!sentAt) return false;
  const a = instant(sentAt), b = instant(mark);
  if (a !== null && b !== null) return a > b;
  return sentAt > mark;
}

export const newCount = (messages, mark) => (messages || []).filter(m => isNew(m.sent_at, mark)).length;

/** Zahl am Menuepunkt: leer bei 0, "99+" ab 100 */
export const badgeText = n => !n || n < 1 ? "" : n > 99 ? "99+" : String(n);

/** Beschriftung der Zahl fuer Bedienungshilfen: "3 neue Nachrichten" */
export const badgeLabel = n => n === 1 ? "1 neue Nachricht" : `${n} neue Nachrichten`;

const WD = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."];
const dayNumber = s => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || ""); return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) / 86400000 : NaN; };
const weekday = day => { const n = dayNumber(day); return Number.isNaN(n) ? "" : WD[new Date(n * 86400000).getUTCDay()]; };
const ddmm = day => `${day.slice(8, 10)}.${day.slice(5, 7)}.`;

/** Zeit in der Liste: "09:15" heute, "gestern", sonst "Sa., 31.10." (Ortszeit wie von Stud.IP genannt) */
export function listTime(sentAt, today) {
  if (!sentAt || sentAt.length < 10) return "";
  const day = sentAt.slice(0, 10);
  if (day === today) return sentAt.length >= 16 ? sentAt.slice(11, 16) : "heute";
  if (dayNumber(today) - dayNumber(day) === 1) return "gestern";
  return `${weekday(day)} ${ddmm(day)}`.trim().replace(" ", ", ");
}

/** "Mo., 02.11.2026, 08:15 Uhr" aus `sent_at` */
export function fullDate(sentAt) {
  if (!sentAt || sentAt.length < 10) return "";
  const day = sentAt.slice(0, 10);
  const wd = weekday(day);
  const date = `${wd ? wd + ", " : ""}${day.slice(8, 10)}.${day.slice(5, 7)}.${day.slice(0, 4)}`;
  return sentAt.length >= 16 ? `${date}, ${sentAt.slice(11, 16)} Uhr` : date;
}

/** "Zuletzt abgeglichen: 04.11.2026, 09:30 Uhr" bzw. "Noch nicht mit Stud.IP abgeglichen" (aus dem Abrufzeitpunkt der Nachrichten) */
export function syncLine(fetchedAt) {
  if (!fetchedAt || fetchedAt.length < 16) return "Noch nicht mit Stud.IP abgeglichen";
  return `Zuletzt abgeglichen: ${fetchedAt.slice(8, 10)}.${fetchedAt.slice(5, 7)}.${fetchedAt.slice(0, 4)}, ${fetchedAt.slice(11, 16)} Uhr`;
}

const KIND_TEXT = { frist: ["Frist", "warn"], pruefung: ["Prüfung", "bad"], ausfall: ["Ausfall?", "warn"], verlegt: ["Verlegung?", "warn"],
  raum: ["Raumänderung", "info"], online: ["Online", "info"] };

/** Chip eines erkannten Tags: "Frist 19.11., 12:00"; vergangene Tage gedaempft (neutral); null ohne Tag */
export function chip(d, today) {
  const day = d && d.date;
  if (typeof day !== "string" || day.length < 10) return null;
  const [text, tone] = KIND_TEXT[d.kind] || ["Termin", "info"];
  return { label: `${text} ${ddmm(day)}${d.time ? `, ${d.time}` : ""}`, tone: day < today ? "neutral" : tone, past: day < today };
}

/** Erkannte Tage einer Nachricht ohne Doppelte (gleiche Beschriftung) */
export function chips(m, today) {
  const seen = new Set();
  return (m.dates || []).map(d => chip(d, today)).filter(c => c && !seen.has(c.label) && seen.add(c.label));
}

/** Text fuer Bedienungshilfen je Zeile: "Neu, Tutorium entfällt, von Lehrende, 08:15" */
export function rowLabel(m, fresh, today) {
  const parts = [m.subject || TEXTS.noSubject];
  if (m.sender) parts.push(`von ${m.sender}`);
  const t = listTime(m.sent_at, today);
  if (t) parts.push(t);
  if (m.replies?.length) parts.push("Beantwortet");
  return (fresh ? ["Neu", ...parts] : parts).join(", ");
}

/** Liste links: eine Zeile je Nachricht. `mark` = Marke VOR diesem Besuch (Punkt "neu seit dem letzten Besuch"). */
export function listHtml(messages, { selected, mark, today }) {
  return messages.map(m => {
    const fresh = isNew(m.sent_at, mark), on = m.id === selected;
    const first = chips(m, today)[0];
    return `<button type="button" class="msg-row${on ? " on" : ""}${fresh ? " fresh" : ""}" data-id="${esc(m.id)}" aria-label="${esc(rowLabel(m, fresh, today))}"${on ? ` aria-current="true"` : ""}>
      <span class="msg-dot" aria-hidden="true"></span>
      <span class="msg-main"><span class="msg-top"><b class="msg-who">${esc(m.sender || "Stud.IP")}</b><span class="msg-time">${m.replies?.length ? `<span class="msg-replied" aria-hidden="true">✓</span> ` : ""}${esc(listTime(m.sent_at, today))}</span></span>
      <span class="msg-subj">${esc(m.subject || TEXTS.noSubject)}</span>${first ? `<span class="msg-chip-line">${esc(first.label)}</span>` : ""}</span></button>`;
  }).join("");
}

/** Lesebereich: Betreff, Absender (Rolle), Datum, erkannte Tage, ganzer Text, "In Stud.IP öffnen" (nur http/https) */
export function readerHtml(m, { today, back = false, icon = () => "" }) {
  const cs = chips(m, today), url = httpUrl(m.url);
  return `${back ? `<button type="button" class="btn ghost sm msg-back" aria-label="Zurück zu den Nachrichten">${icon("chevron-left", 16)} ${esc(TEXTS.back)}</button>` : ""}
    <h2 class="msg-title" tabindex="-1">${esc(m.subject || TEXTS.noSubject)}</h2>
    <div class="msg-meta"><span class="badge info">${esc(m.sender || "Stud.IP")}</span><span class="muted small">${esc(fullDate(m.sent_at))}</span></div>
    ${cs.length ? `<div class="msg-chips" aria-label="Erkannte Termine: ${esc(cs.map(c => c.label).join(", "))}">${cs.map(c => `<span class="badge ${c.tone}">${esc(c.label)}</span>`).join("")}</div>` : ""}
    <hr class="msg-rule">
    ${m.text ? `<div class="msg-text">${esc(m.text)}</div>` : `<p class="muted">${esc(TEXTS.noText)}</p>`}
    ${url ? `<p><a class="btn" href="${esc(url)}" target="_blank" rel="noopener" aria-label="${esc(TEXTS.open)}: öffnet den Posteingang in Stud.IP">${esc(TEXTS.open)} ${icon("arrow-right", 15)}</a></p>` : ""}
    <p class="muted tiny">${esc(TEXTS.privacy)}</p>`;
}

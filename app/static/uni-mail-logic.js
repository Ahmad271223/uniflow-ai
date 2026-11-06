// Uni-Mail und Uni-Kalender (SOGo der LUH bzw. der Uni Hildesheim, seit 06.11.2026) in Web und Windows-App
// (docs/UNI-MAIL-2026-11-05.md): Regeln und Texte ohne DOM (node: tests/js/uni-mail.test.mjs), wie UniMailViews.swift
// auf dem iPad. Daten: /api/sogo/... (app/sogo_api.py).

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const TEXTS = {
  title: "Uni-Mail",
  sub: "E-Mails und Kalender der Leibniz Universität Hannover (SOGo)",
  hint: "Melde dich auf der echten SOGo-Seite der LUH an. StudiNow merkt sich nur die Sitzung, nie dein Passwort. E-Mails bleiben auf diesem PC und in deinem Uni-Postfach, nichts geht an StudiNow-Server.",
  sendNote: "Gesendet wird erst mit „Senden“ und deiner Bestätigung. Die E-Mail geht direkt von deinem Uni-Postfach aus.",
  expired: "Die Anmeldung bei Uni-Mail ist abgelaufen. Bitte neu anmelden.",
  calendar: "Termine aus deinem Uni-Kalender erscheinen im Lernkalender und Stundenplan als „Uni-Kalender“ – nur lesend. Ganztägige Termine stehen nur hier.",
};

/** Zahl am Menüpunkt: ungelesene ("99+" ab 100); 0 = keine */
export const badgeText = n => (n > 99 ? "99+" : n > 0 ? String(n) : "");
export const badgeLabel = n => (n === 1 ? "1 ungelesene E-Mail" : `${n} ungelesene E-Mails`);

/** Menüpunkt nur am PC an einer Hochschule mit SOGo: LUH, Uni Hildesheim (HsH: nicht; Dienst: 404 der Route) */
export const showsNavItem = st => !!(st && st.available);

/** SOGo je Hochschule (wie sogo.SITES und SOGoSite): Anzeigename, Hochschule, Raumfinder-Links (nur LUH) */
export const SITES = {
  luh: { name: "Uni-Mail (LUH)", university: "Leibniz Universität Hannover", short: "LUH", host: "kalender.uni-hannover.de", roomLinks: true },
  hildesheim: { name: "Uni-Mail (Uni Hildesheim)", university: "Universität Hildesheim", short: "Uni Hildesheim", host: "webmail.uni-hildesheim.de", roomLinks: false },
};

/** Hochschule aus /api/sogo/status; nur bekannte Schlüssel, sonst null (dann keine Uni-Mail) */
export const site = st => (st && st.available && Object.hasOwn(SITES, st.university) ? SITES[st.university] : null);

/** Texte der Seite für die Hochschule aus dem Status */
export function texts(st) {
  const s = site(st);
  if (!s) return { ...TEXTS, name: TEXTS.title, sub: "E-Mails und Kalender deiner Hochschule (SOGo)", unavailable: "Uni-Mail gibt es für Studierende der Leibniz Universität Hannover und der Universität Hildesheim." };
  return {
    ...TEXTS, name: s.name, sub: `E-Mails und Kalender der ${s.university} (SOGo)`,
    hint: `Melde dich auf der echten SOGo-Seite der ${s.short} an. StudiNow merkt sich nur die Sitzung, nie dein Passwort. E-Mails bleiben auf diesem PC und in deinem Uni-Postfach, nichts geht an StudiNow-Server.`,
  };
}

/** Ort eines Termins als Link zum Raumfinder? Nur an der LUH (Standortfinder der LUH) */
export const roomLinks = st => !!site(st)?.roomLinks;

/** Knopf „Lehrende“ (Stud.IP, nur LUH) auf der Seite Uni-Mail */
export const showsLecturers = st => site(st) === SITES.luh;

/** Adresse anzeigen: "Name <a@b>" bzw. nur die Adresse */
export const addressText = a => (a?.name ? (a.email && a.email !== a.name ? `${a.name} <${a.email}>` : a.name) : a?.email || "");

/** Titel des Schreibfensters */
export const composeTitle = action => ({ reply: "Antworten", replyall: "Allen antworten", forward: "Weiterleiten" }[action] || "Neue E-Mail");

/** Rückfrage vor dem Senden */
export function sendQuestion(to, cc, bcc) {
  const n = [to, cc, bcc].map(s => String(s || "").split(/[,;\n]/).map(x => x.trim()).filter(Boolean).length).reduce((a, b) => a + b, 0);
  return n === 1 ? "E-Mail an 1 Empfänger senden?" : `E-Mail an ${n} Empfänger senden?`;
}

/** Körper für /api/sogo/draft/save bzw. /send; "confirm" nur aus der Rückfrage */
export function body(draft, f, confirm = false) {
  const b = { draft, to: f.to || "", cc: f.cc || "", bcc: f.bcc || "", subject: f.subject || "", text: f.text || "" };
  if (confirm) b.confirm = true;
  return b;
}

/** "Mo, 09.11., 10:15–11:45" bzw. ganztägig */
export function when(e) {
  const st = e.start || "", en = e.end || "";
  const d = s => `${s.slice(8, 10)}.${s.slice(5, 7)}.`;
  if (e.all_day) return st.slice(0, 10) === en.slice(0, 10) ? `${d(st)}, ganztägig` : `${d(st)} – ${d(en)}, ganztägig`;
  return `${d(st)}, ${st.slice(11, 16)}–${en.slice(11, 16)}`;
}

/** HTML der Mail im abgeschotteten Rahmen (sandbox ohne Skripte, CSP ohne Netz) */
export const frameDoc = html => `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><style>body{font:15px system-ui,sans-serif;margin:0;word-wrap:break-word}img{max-width:100%}blockquote{border-left:3px solid #9aa3c7;margin:0 0 0 4px;padding-left:10px}</style></head><body>${html || ""}</body></html>`;

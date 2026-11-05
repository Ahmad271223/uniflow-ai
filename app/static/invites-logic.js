// Seite "Freunde einladen" fuer Web und Windows (docs/EINLADUNGEN.md, wie InviteView.swift auf dem iPad, 05.11.2026).
// Reine Funktionen ohne DOM (tests/js/invites.test.mjs). Daten: GET /api/invites (im Dienst direkt, in der Windows-App
// ueber das StudiNow-Konto weitergereicht, app/invites_api.py `_forward`).
//
// Belohnungen: Auf dem iPad sind es Apple-Angebotscodes, die nur im App Store einloesbar sind. Fuer Web und Windows
// (Stripe-Gutscheine) hat der Inhaber noch nicht entschieden (docs/EINLADUNGEN.md Abschnitt 9). Solange
// `WEB_REWARDS` false ist, zeigt die Seite Links, Teilen, QR-Code und den Zaehler, aber keine Belohnungen und nichts
// zum Einloesen.

export const WEB_REWARDS = false;
export const APP_SCHEME = "uniflow://invite/";
export const REWARDS_NOTE = "Belohnungen für Einladungen gibt es bisher nur als App-Store-Code in der iPad-App. Ob es sie auch im Browser und unter Windows gibt, ist noch nicht entschieden – hier wird darum nichts versprochen.";

const two = n => String(n).padStart(2, "0");
/** "05.12.2026" aus ISO */
export function day(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
  return m ? `${m[3]}.${m[2]}.${m[1]}` : "";
}

/** "1 Person ist angekommen" / "3 Personen sind angekommen" / "Noch niemand ist angekommen" */
export function arrivedLine(n) {
  const k = Math.max(0, Number(n) || 0);
  return k === 0 ? "Noch niemand ist über deine Links angekommen." : `${k} ${k === 1 ? "Person ist" : "Personen sind"} über deine Links angekommen.`;
}

/** Zeile je Link: "gültig bis 05.12.2026 · 2 angekommen" bzw. "abgelaufen" */
export function linkStatus(c) {
  const parts = [c?.expired ? "abgelaufen" : `gültig bis ${day(c?.expires_at)}`];
  const r = Number(c?.redemptions) || 0;
  if (r) parts.push(`${r} angekommen`);
  return parts.join(" · ");
}

/** Hinweis zum Anlegen neuer Links (Fenster in der Probewoche, hoechstens 20) */
export function createHint(ov) {
  if (!ov) return "";
  const left = Number(ov.remaining_links) || 0;
  if (ov.can_create) return `Neue Links kannst du bis ${day(ov.create_until)} anlegen (noch ${left} von ${ov.max_links ?? 20}).`;
  if (!left) return `Du hast alle ${ov.max_links ?? 20} Einladungslinks angelegt.`;
  return "Neue Einladungslinks gibt es nur in den ersten 7 Tagen deines Kontos bzw. während der Probe. Deine Links bleiben 30 Tage gültig.";
}

/** gueltige Links zuerst, darin der neueste zuerst */
export function sortedCodes(codes) {
  return [...(codes || [])].sort((a, b) => (a.expired === b.expired ? String(b.created_at).localeCompare(String(a.created_at)) : a.expired ? 1 : -1));
}

export const shareText = url => `Ich lerne mit StudiNow – Stud.IP-Dateien, Lernplan und Notizen an einem Ort. Probier es aus: ${url}`;
export const appCode = code => APP_SCHEME + String(code || "");

/** Fehler der Endpunkte in einen Satz fuer die Seite; `noAccount` = ohne StudiNow-Konto (PC ohne Anmeldung) */
export function errorState(e) {
  const code = e?.code || "";
  if (code === "not_hosted" || code === "not_linked" || code === "unauthenticated" || code === "account_required")
    return { noAccount: true, text: "Einladungen brauchen dein StudiNow-Konto. Melde dich mit deinem Konto an, dann erscheinen hier deine Links." };
  if (code === "service_unreachable") return { noAccount: false, text: "Der StudiNow-Dienst ist gerade nicht erreichbar. Bitte später erneut versuchen." };
  return { noAccount: false, text: e?.message || "Die Einladungen konnten nicht geladen werden." };
}

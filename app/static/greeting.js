// Begruessung mit Namen auf der Uebersicht wie auf dem iPad (UFGreeting.swift, Wunsch des Inhabers 04.11.2026):
// "Hallo Ahmad – lass uns gemeinsam lernen.", vor 11 Uhr "Guten Morgen, Ahmad – …", ab 18 Uhr "Guten Abend, Ahmad – …";
// ohne Namen "Hallo – lass uns gemeinsam lernen.". Reine Funktionen (tests/js/greeting.test.mjs).
// Namensquellen im Web/unter Windows in dieser Reihenfolge (`pick`): der selbst gewaehlte Rufname (Einstellung `rufname`,
// Erststart "Wie sollen wir dich nennen?" oder Einstellungen), der Anzeigename des StudiNow-Kontos (falls es einen hat),
// das erste Wort des Anzeigenamens fuer die Community (`user_name`), sonst ohne Namen.

export const MAX_NAME = 24;
export const TAIL = "lass uns gemeinsam lernen.";

/** vor 11 Uhr "Guten Morgen", ab 18 Uhr "Guten Abend", dazwischen "Hallo" */
export const salutation = hour => (hour < 11 ? "Guten Morgen" : hour < 18 ? "Hallo" : "Guten Abend");

/** ohne Rand-Leerzeichen, leer = null, laenger als 24 Zeichen auf 23 plus "…" gekuerzt */
export function displayName(raw) {
  const t = String(raw ?? "").trim();
  if (!t) return null;
  const chars = [...t];
  return chars.length > MAX_NAME ? chars.slice(0, MAX_NAME - 1).join("").trimEnd() + "…" : t;
}

/** "Ahmad Fakih" -> "Ahmad" */
export const givenName = full => displayName(String(full ?? "").trim().split(/[\s ]+/)[0]);

export function text(name, hour) {
  const s = salutation(hour), n = displayName(name);
  if (!n) return `${s} – ${TAIL}`;
  return s === "Hallo" ? `Hallo ${n} – ${TAIL}` : `${s}, ${n} – ${TAIL}`;
}

/** Reihenfolge der Quellen; jede gilt nur, wenn sie nicht leer ist */
export const pick = ({ rufname, accountName, userName } = {}) => displayName(rufname) ?? displayName(accountName) ?? givenName(userName);

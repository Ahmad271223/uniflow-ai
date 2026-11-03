// Abgleich-Anzeige oben (03.11.2026, wie HildesheimStatusLine.shows auf dem iPad): sichtbar nur, wenn es etwas zu sagen
// gibt: ein Abgleich laeuft (zeigt app.js pollBg), der letzte Abgleich scheiterte oder brachte Neues. Sonst bleibt der
// Knopf "Sync" allein ("warum steht da oben immer abgehakt"). Reines Modul fuer tests/js/sync-chip.test.mjs.
// Eingabe ist eine Zeile aus sync_log ({ok, new_files, message, finished_at}), wie GET /api/sync/status sie liefert.

const FAIL = /FEHLER/;

/** Zahl hinter einem Muster wie "3 neu", "2 entfernt", "4 Stundenplan-Termine" in der Meldung (alle Treffer addiert) */
function counted(message, word) {
  let n = 0;
  for (const m of String(message || "").matchAll(new RegExp(`(\\d+)\\s+${word}`, "g"))) n += +m[1];
  return n;
}

/** Hat der Abgleich Neues oder Geaendertes gebracht? (neue Dateien, neue oder entfernte Fristen, Ankuendigungen, Termine) */
export function hasNews(entry) {
  if (!entry) return false;
  if ((+entry.new_files || 0) > 0) return true;
  const msg = entry.message || "";
  return counted(msg, "neu") + counted(msg, "entfernt") + counted(msg, "Stundenplan-Termine") + counted(msg, "Serien entfernt") > 0;
}

/** Ist der Abgleich gescheitert oder war ein Teil davon fehlerhaft? */
export const hasProblem = entry => !!entry && (!entry.ok || FAIL.test(entry.message || ""));

/**
 * Was die Anzeige zeigt: null = nichts (ruhig), sonst {tone: "bad" | "ok", icon, text, title}.
 * time = Uhrzeit des Abgleichs als Text ("14:05").
 */
export function chipState(entry, time) {
  if (!entry) return null;
  const at = time ? ` (${time})` : "";
  if (hasProblem(entry)) return { tone: "bad", icon: "alert", text: `Letzter Abgleich mit Problem${at}`, title: entry.message || "" };
  if (hasNews(entry)) {
    const n = +entry.new_files || 0;
    return { tone: "ok", icon: "check", text: `Zuletzt synchronisiert: ${time || "?"} · ${n > 0 ? `${n} ${n === 1 ? "neue Datei" : "neue Dateien"}` : "Neues"}`, title: entry.message || "" };
  }
  return null;
}

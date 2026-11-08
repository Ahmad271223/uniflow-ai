// Eigenes ChatGPT per OpenAI-API-Schluessel (Windows-App, 08.11.2026; app/openai_key.py, iPad OpenAIKeyRules). Reine
// Regeln fuer die Karte in Einstellungen -> Erweitert; der Server prueft dieselben Regeln noch einmal.
export const KEYS_URL = "https://platform.openai.com/api-keys";

/** Schluessel in gueltiger Form (aussen ohne Leerraum, "sk-", 20-400 sichtbare ASCII-Zeichen), sonst null */
export function normalizeKey(raw) {
  const k = String(raw || "").trim();
  if (!k.startsWith("sk-") || k.length < 20 || k.length > 400) return null;
  for (const ch of k) { const c = ch.charCodeAt(0); if (c <= 32 || c >= 127) return null; }
  return k;
}

/** Anzeige eines Schluessels: nur die letzten vier Zeichen */
export function maskKey(key) {
  if (!key) return "";
  return key.length >= 8 ? "sk-…" + key.slice(-4) : "sk-…";
}

/** Stand der Karte als kurze Zeile (Badge) */
export function badge(st) {
  if (!st || !st.available) return { cls: "neutral", text: "nur in der Windows-App" };
  if (!st.has_key) return { cls: "neutral", text: "kein Schlüssel" };
  if (st.last_error) return { cls: "warn", text: "Prüfung fehlgeschlagen" };
  if (!st.use_for_ai) return { cls: "neutral", text: "aus" };
  if (!st.model) return { cls: "warn", text: "Modell wählen" };
  return { cls: "ok", text: st.checked ? "aktiv · geprüft" : "aktiv" };
}

/** Speichern nur mit Einwilligung und gueltigem Schluessel; liefert den Fehlertext oder null */
export function saveProblem(raw, consent) {
  if (!normalizeKey(raw)) return "Der Schlüssel beginnt mit „sk-“ und hat 20 bis 400 Zeichen ohne Leerzeichen.";
  if (!consent) return "Bitte stimme zuerst zu, dass StudiNow deine Anfragen mit deinem Schlüssel direkt an OpenAI senden darf.";
  return null;
}

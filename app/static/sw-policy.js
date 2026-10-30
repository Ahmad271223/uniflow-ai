// Regeln des Service Workers (app/static/sw.js), ohne Browser pruefbar (tests/js/sw.test.mjs): welche Anfrage wie
// behandelt wird und wie gross die Ablagen sind. Ein gewoehnliches Skript (importScripts), kein Modul.
//
// Grundsatz: Netz zuerst, Ablage nur als Rueckfall. Die Oberflaeche traegt Versionen in der Adresse (?v=N), darum darf
// sie nach einem Update nicht aus der Ablage haengen bleiben: jede erfolgreiche Antwort ersetzt die alte. Offline gibt
// es den zuletzt gesehenen Stand: Oberflaeche, zuletzt geoeffnete PDFs und die zuletzt gelesenen Listen. Aenderungen
// (POST/PUT/DELETE) gehen nie in die Ablage; ohne Netz scheitern sie mit einer klaren Meldung (Code "offline").
(function (root) {
  "use strict";
  const CACHES = { shell: "studora-shell-v1", files: "studora-files-v1", api: "studora-api-v1" };
  const LIMITS = { shell: 400, files: 40, api: 300 };
  // Antworten, die nie aus der Ablage kommen duerfen: Konto und Sitzung, laufende Auftraege, Abgleich, Bezahlung,
  // Zugangsdaten, Suche (Eingabe), Diagnose; Aufzeichnungen (gross) kommen auch nicht hinein
  const API_NEVER = [/^\/api\/account(\/|$)/, /^\/api\/bg(\/|$)/, /^\/api\/sync(\/|$)/, /^\/api\/network(\/|$)/,
    /^\/api\/integrations(\/|$)/, /^\/api\/billing(\/|$)/, /^\/api\/entitlements(\/|$)/, /^\/api\/credentials(\/|$)/,
    /^\/api\/university\/session(\/|$)/, /^\/api\/qis(\/|$)/, /^\/api\/search(\/|$)/, /^\/api\/related(\/|$)/,
    /^\/api\/desktop(\/|$)/, /^\/api\/services(\/|$)/, /^\/api\/diag(\/|$)/, /^\/api\/files\/[^/]+\/recordings(\/|$)/,
    /^\/api\/recordings(\/|$)/, /^\/api\/community\/notifications(\/|$)/];
  const FILE_CONTENT = /^\/api\/files\/[^/]+\/(content|docx)$/;

  /// Entscheidung fuer eine Anfrage: {kind: "bypass"|"shell"|"files"|"api"|"write", reason}
  function classify(method, url, origin) {
    let u;
    try { u = new URL(url, origin); } catch (e) { return { kind: "bypass", reason: "adresse" }; }
    if (u.origin !== origin) return { kind: "bypass", reason: "fremd" };
    if (method !== "GET") return { kind: "write", reason: method };
    const p = u.pathname;
    if (p === "/login" || p === "/sw.js" || p.startsWith("/auth/")) return { kind: "bypass", reason: "anmeldung" };
    if (!p.startsWith("/api/")) return { kind: "shell", reason: "oberflaeche" };
    if (FILE_CONTENT.test(p)) return { kind: "files", reason: "datei" };
    if (API_NEVER.some(function (re) { return re.test(p); })) return { kind: "bypass", reason: "nie" };
    return { kind: "api", reason: "liste" };
  }

  /// Schluessel in der Ablage: fuer Dateien ohne Abfrage (Download-Varianten teilen den Inhalt), sonst die ganze Adresse
  function cacheKey(kind, url, origin) {
    const u = new URL(url, origin);
    if (kind === "files") return u.origin + u.pathname;
    return u.origin + u.pathname + u.search;
  }

  /// Darf eine Antwort in die Ablage? Nur vollstaendige 200er vom eigenen Server (keine Weiterleitungen, kein 206)
  function storable(status, type) {
    return status === 200 && (type === "basic" || type === "default" || type === "");
  }

  /// Antwort fuer eine gescheiterte Aenderung ohne Netz (Form wie die Fehler des Servers)
  function offlineWrite() {
    return { status: 503, body: { detail: "Offline – die Änderung wurde nicht gespeichert. Bitte mit Netz erneut versuchen.", code: "offline" } };
  }

  /// Welche Schluessel bei zu voller Ablage verschwinden: die aeltesten zuerst (Einfuegereihenfolge), bis `limit` bleibt
  function evict(keys, limit) {
    return keys.length > limit ? keys.slice(0, keys.length - limit) : [];
  }

  root.StudoraSW = { CACHES, LIMITS, classify, cacheKey, storable, offlineWrite, evict };
})(typeof self !== "undefined" ? self : globalThis);

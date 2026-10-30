// Studora als App im Browser (Web zuerst, docs/PLAN-WEB-ZUERST-2026-10-30.md Stufe B): Service Worker anmelden,
// Online/Offline anzeigen, Hinweis "Zum Home-Bildschirm" (iPad) bzw. "Zum Dock hinzufuegen" (Mac) bzw. "Installieren"
// (Edge, Chrome), Ablage beim Abmelden oder Kontowechsel leeren. Die Regeln des Workers stehen in sw-policy.js.
import { $, icon, toast, state } from "./core.js?v=32";

const HINT_KEY = "pwa-hint-dismissed";
let installPrompt = null;             // beforeinstallprompt (Edge, Chrome); Safari kennt das nicht

/// Laeuft die Oberflaeche schon als installierte App?
export function standalone() {
  try { return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true; } catch { return false; }
}

/// Welche Anleitung passt zum Geraet: ipad | mac | chrome | null (nichts anbieten)
export function installKind(ua = navigator.userAgent, platform = navigator.platform, touch = navigator.maxTouchPoints || 0) {
  const safari = /Safari/.test(ua) && !/Chrome|Chromium|CriOS|Edg|FxiOS/.test(ua);
  if (/iPad/.test(ua) || (platform === "MacIntel" && touch > 1)) return safari ? "ipad" : null;
  if (/Macintosh/.test(ua)) return safari ? "mac" : (installPrompt ? "chrome" : null);
  return installPrompt ? "chrome" : null;
}

export const INSTALL_TEXT = {
  ipad: "Teilen-Symbol antippen, dann „Zum Home-Bildschirm“. Studora bekommt ein Symbol, läuft im Vollbild und offline mit den zuletzt geladenen Unterlagen.",
  mac: "In Safari: Ablage → „Zum Dock hinzufügen“ (ab macOS 14). Studora läuft dann in einem eigenen Fenster wie eine App.",
  chrome: "Mit „Installieren“ bekommt Studora ein eigenes Fenster und ein Symbol im Startmenü.",
};

/// Service Worker anmelden; ein neuer Stand wird beim naechsten Laden aktiv (skipWaiting + clients.claim im Worker)
export async function registerWorker() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    const reg = await navigator.serviceWorker.register("/sw.js");
    reg.addEventListener("updatefound", () => {
      const w = reg.installing;
      w?.addEventListener("statechange", () => { if (w.state === "activated" && navigator.serviceWorker.controller) toast("Studora wurde aktualisiert"); });
    });
    return reg;
  } catch (e) { console.warn("Service Worker nicht angemeldet:", e.message); return null; }
}

/// Ablage des Workers leeren (Abmelden, anderes Konto): Dateien und Listen des alten Kontos verschwinden
export function clearWorkerCache() {
  try { navigator.serviceWorker?.controller?.postMessage({ type: "clear" }); } catch {}
}

/// Gehoert die Ablage noch zum angemeldeten Konto? Sonst leeren und das Konto merken
export function keepCacheForAccount(accountId) {
  const key = "pwa-account"; let last = null;
  try { last = localStorage.getItem(key); } catch {}
  const id = accountId == null ? "" : String(accountId);
  if (last !== null && last !== id) clearWorkerCache();
  try { localStorage.setItem(key, id); } catch {}
}

/// Online/Offline im Kopf anzeigen
export function watchConnection() {
  const render = () => {
    const chip = $("#syncChip"); if (!chip) return;
    if (navigator.onLine) { chip.classList.remove("offline"); if (chip.dataset.offline) { delete chip.dataset.offline; toast("Wieder online"); state.route?.(); } return; }
    chip.classList.add("offline"); chip.dataset.offline = "1";
    chip.innerHTML = `${icon("alert", 14)} Offline – zuletzt geladene Inhalte`;
  };
  window.addEventListener("online", render); window.addEventListener("offline", render); render();
}

/// Hinweis oben auf der Startseite, bis er einmal geschlossen wurde; nicht in der installierten App
export function installBanner() {
  if (standalone()) return "";
  try { if (localStorage.getItem(HINT_KEY)) return ""; } catch {}
  const kind = installKind(); if (!kind) return "";
  return `<div class="card pwa-hint" id="pwaHint"><div class="row wrap" style="align-items:center;gap:.6rem">${icon("columns", 18)}<div style="flex:1"><b>Studora als App</b><div class="small muted">${INSTALL_TEXT[kind]}</div></div>${kind === "chrome" ? `<button class="btn primary sm" id="pwaInstall">Installieren</button>` : ""}<button class="btn ghost icon sm" id="pwaHintClose" title="Hinweis schließen" aria-label="Hinweis schließen">${icon("x", 14)}</button></div></div>`;
}

export function bindInstallBanner(view) {
  $("#pwaHintClose", view)?.addEventListener("click", () => { try { localStorage.setItem(HINT_KEY, "1"); } catch {} $("#pwaHint", view)?.remove(); });
  $("#pwaInstall", view)?.addEventListener("click", async () => { if (!installPrompt) return; installPrompt.prompt(); const r = await installPrompt.userChoice.catch(() => null); if (r?.outcome === "accepted") { toast("Studora installiert"); $("#pwaHint", view)?.remove(); } });
}

/// Karte in den Einstellungen (Zugang & Darstellung): immer sichtbar, auch nach dem Schliessen des Hinweises
export function installCard() {
  const kind = installKind(); const on = standalone();
  const text = on ? "Studora läuft als installierte App. Zuletzt geladene Unterlagen und Listen sind auch ohne Netz da; Änderungen brauchen Netz."
    : kind ? INSTALL_TEXT[kind] : "In Safari auf dem iPad oder Mac lässt sich Studora als App installieren (Teilen → „Zum Home-Bildschirm“ bzw. Ablage → „Zum Dock hinzufügen“).";
  return `<div class="card" id="pwaCard"><div class="card-head"><h2>${icon("columns", 18)} Als App nutzen</h2>${on ? `<span class="badge ok">installiert</span>` : `<span class="badge neutral">im Browser</span>`}</div><p class="muted small">${text}</p>${!on && kind === "chrome" ? `<div class="row"><button class="btn primary sm" id="pwaInstall">Installieren</button></div>` : ""}</div>`;
}

export function initPWA() {
  window.addEventListener("beforeinstallprompt", e => { e.preventDefault(); installPrompt = e; });
  registerWorker(); watchConnection();
}

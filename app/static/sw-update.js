// Hinweis "Studora wurde aktualisiert" nur bei einem echten Update: Ein Service Worker, der schon aktiv war (oder die
// Seite schon steuert), wird durch einen neuen ersetzt. Beim allerersten Aufruf gibt es noch keinen Vorgaenger - dann
// wird der Worker zwar auch installiert und aktiviert (clients.claim), aber nichts "aktualisiert". Ohne Browser-Importe,
// damit tests/js/sw-update.test.mjs es mit Attrappen pruefen kann.

/// Gab es vor dem neuen Worker schon einen aktiven (reg.active) oder steuert einer die Seite (container.controller)?
export function isWorkerUpdate(reg, container) {
  return !!(reg && reg.active) || !!(container && container.controller);
}

/// Meldet `onUpdate`, sobald ein neuer Worker einen schon vorhandenen abloest. Der erste Worker einer Seite meldet nichts.
export function watchWorkerUpdate(reg, container, onUpdate) {
  reg.addEventListener("updatefound", () => {
    const w = reg.installing;
    if (!w || !isWorkerUpdate(reg, container)) return;          // Stand beim Fund, vor clients.claim() des neuen Workers
    w.addEventListener("statechange", () => { if (w.state === "activated") onUpdate(); });
  });
}

// Bewegung der Oberflaeche (Auftrag des Inhabers 03.11.2026), schlank und ohne Bibliothek. Vorbild sind die Muster
// aus motion-primitives (animated-group/in-view, animated-number, transition-panel, disclosure, text-shimmer), hier
// eigenstaendig als CSS (style.css, "Bewegung") und wenige Zeilen JS umgesetzt: kurze Dauern (0.18-0.35 s), keine
// Federn mit Ueberschwingen, nichts wartet auf eine Animation. Bei prefers-reduced-motion keine Lage- oder
// Groessenaenderung, hoechstens eine Ueberblendung; Zahlen stehen sofort da.

const seen = new Set();          // Gruppen, die in dieser Sitzung schon gestaffelt erschienen sind
const lastNumbers = new Map();   // zuletzt gezeigte Zahlen je Schluessel (Zahlen rollen von dort zur neuen)

export const reducedMotion = () => {
  try { return !!globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches; } catch { return false; }
};

/// Kinder von `root` erscheinen leicht gestaffelt (Deckkraft und 8 px von unten), nur beim ersten Erscheinen der
/// Gruppe `key` – nicht bei jedem Neuladen. Ab dem achten Kind kein weiterer Versatz.
export function staggerOnce(root, key) {
  if (!root || seen.has(key)) return false;
  seen.add(key);
  [...root.children].forEach((el, i) => el.style.setProperty("--i", String(Math.min(i, 8))));
  root.classList.add("uf-stagger");
  // Klasse nach dem Erscheinen wieder weg: spaetere Umbauten der Seite blenden nicht noch einmal ein
  setTimeout(() => root.classList.remove("uf-stagger"), 700);
  return true;
}

/// Ganze Zahlen in einem Text ("2 / 5", "1 h 30 min", "60%")
export function numbersIn(text) { return (String(text).match(/\d+/g) || []).map(Number); }

/// Text mit den Zahlen auf halbem Weg (t 0..1) zwischen `from` und den Zahlen des Textes; Rest bleibt unveraendert
export function textAt(text, from, t) {
  let i = 0;
  return String(text).replace(/\d+/g, n => {
    const to = Number(n), a = from[i++] ?? to;
    return String(Math.round(a + (to - a) * t));
  });
}

/// Zahlen in `el` rollen weich zur neuen Zahl (animated-number). Beim ersten Erscheinen von 0 aus, danach vom
/// zuletzt gezeigten Stand; gleich geblieben oder reduzierte Bewegung: sofort der Endwert.
export function countUp(el, key, duration = 320) {
  if (!el) return;
  const text = el.textContent, target = numbersIn(text);
  const from = lastNumbers.get(key) ?? target.map(() => 0);
  lastNumbers.set(key, target);
  if (reducedMotion() || !target.length || from.join() === target.join() || !globalThis.requestAnimationFrame) return;
  const start = performance.now();
  const ease = t => 1 - Math.pow(1 - t, 3);                                   // ease-out, ohne Ueberschwingen
  const step = now => {
    const t = Math.min(1, (now - start) / duration);
    el.textContent = textAt(text, from, ease(t));
    if (t < 1 && el.isConnected) requestAnimationFrame(step); else el.textContent = text;
  };
  el.textContent = textAt(text, from, 0);
  requestAnimationFrame(step);
}

/// Auf- und Zuklappen wie disclosure: Hoehe und Deckkraft. Reduziert nur Ueberblendung beim Aufklappen.
export function reveal(el, open) {
  if (!el) return;
  const animate = typeof el.animate === "function";
  el._ufAnim?.cancel();                                                     // schnelles Hin und Her: letzte Bewegung abbrechen
  if (open) {
    el.hidden = false;
    if (!animate) return;
    if (reducedMotion()) { el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: "ease-out" }); return; }
    const h = el.scrollHeight;
    el._ufAnim = el.animate([{ height: "0px", opacity: 0, overflow: "hidden" }, { height: h + "px", opacity: 1, overflow: "hidden" }],
      { duration: 260, easing: "cubic-bezier(.2, 0, 0, 1)" });
  } else {
    if (!animate || reducedMotion()) { el.hidden = true; return; }
    const h = el.scrollHeight;
    const a = el._ufAnim = el.animate([{ height: h + "px", opacity: 1, overflow: "hidden" }, { height: "0px", opacity: 0, overflow: "hidden" }],
      { duration: 200, easing: "cubic-bezier(.4, 0, 1, 1)" });
    a.onfinish = () => { el.hidden = true; };
  }
}

/// nur fuer Tests
export function _resetMotion() { seen.clear(); lastNumbers.clear(); }

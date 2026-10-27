// Seitenformate in PDF-Punkten (1 pt = 1/72 Zoll), ISO 216 gerundet: A6 … A2, dazu Whiteboards (quer, groesser).
// Gemeinsam fuer Editor (Seite hinzufuegen, Format aendern) und Bibliothek (neues Notizbuch/Whiteboard); der Server
// prueft dieselben Grenzen (validSize). Objekte speichern ihre Lage in Punkten, ein Formatwechsel verschiebt nichts.
export const FORMATS = {
  a6: { name: "A6", w: 298, h: 420 },
  a5: { name: "A5", w: 420, h: 595 },
  a4: { name: "A4", w: 595, h: 842 },
  a3: { name: "A3", w: 842, h: 1191 },
  a2: { name: "A2", w: 1191, h: 1684 },
};
export const WHITEBOARDS = {
  wb_a4: { name: "Klein (A4 quer)", w: 842, h: 595 },
  wb_a3: { name: "Mittel (A3 quer)", w: 1191, h: 842 },
  wb_a1: { name: "Groß (A1 quer)", w: 2384, h: 1684 },
  wb_a0: { name: "Riesig (A0 quer)", w: 3370, h: 2384, hint: "braucht viel Arbeitsspeicher, auf Tablets lieber „Groß“" },
};
export const MIN_SIDE = 100, MAX_SIDE = 3400;

export function validSize(w, h) {
  return Number.isInteger(w) && Number.isInteger(h) && w >= MIN_SIDE && h >= MIN_SIDE && w <= MAX_SIDE && h <= MAX_SIDE;
}

/** Breite/Hoehe eines Formats; orientation "portrait" (hoch) oder "landscape" (quer). Whiteboards sind immer quer. */
export function formatSize(key, orientation = "portrait") {
  const f = FORMATS[key];
  if (f) return orientation === "landscape" ? { w: f.h, h: f.w } : { w: f.w, h: f.h };
  const wb = WHITEBOARDS[key];
  return wb ? { w: wb.w, h: wb.h } : null;
}

/** Format und Ausrichtung zu einer Seitengroesse (± 2 pt), sonst null (z. B. PDF-Seite, eigenes Mass). */
export function formatOf(w, h) {
  const near = (a, b) => Math.abs(a - b) <= 2;
  for (const [key, f] of Object.entries(FORMATS)) {
    if (near(w, f.w) && near(h, f.h)) return { key, orientation: "portrait", name: f.name };
    if (near(w, f.h) && near(h, f.w)) return { key, orientation: "landscape", name: f.name + " quer" };
  }
  for (const [key, f] of Object.entries(WHITEBOARDS)) if (near(w, f.w) && near(h, f.h)) return { key, orientation: "landscape", name: f.name };
  return null;
}

export function sizeLabel(w, h) {
  const f = formatOf(w, h);
  return f ? f.name : `${Math.round(w / 72 * 2.54)} × ${Math.round(h / 72 * 2.54)} cm`;
}

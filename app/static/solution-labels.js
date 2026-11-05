// Titel der Seiten einer geteilten Loesung beim Empfaenger (05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md), wie
// SolutionBuilder.pageTitle in Swift: PDF-Seite -> "PDF-Seite 4", Leerseite hinter einer PDF-Seite (Seitennotiz oder
// Blatt daneben, das der Absender neben dieser Folie beschrieben hat) -> "Notiz zu Folie 4", davor -> "Eigene Seite".

/** Titel der Seite `i` in `pages` (Seiten eines geoeffneten Loesungsinhalts, Reihenfolge des Absenders). */
export function pageTitle(pages, i) {
  const p = pages?.[i];
  if (!p) return "Eigene Seite";
  if (Number.isInteger(p.pdfIndex)) return `PDF-Seite ${p.pdfIndex}`;
  for (let j = i - 1; j >= 0; j--) if (Number.isInteger(pages[j]?.pdfIndex)) return `Notiz zu Folie ${pages[j].pdfIndex}`;
  return "Eigene Seite";
}

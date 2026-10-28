// Notizen und PDF-Fassung (Pruefpunkte 1187–1191, 28.10.2026).
//
// Notizen haengen an der Datei-ID und je Seite am PDF-Seitenindex. Ersetzt die Hochschule die PDF (gleicher Name,
// neue Fassung), stimmen die Indizes nicht mehr, sobald Seiten eingefuegt oder entfernt wurden. Deshalb merkt sich
// das Notizdokument die Fassung, zu der es gehoert:
//   doc.pdf = { sha256, pageCount, sigs: [Textsignatur je Seite], sizes: [[w, h] je Seite] }
// Textsignatur = FNV-1a (32 Bit, hex) ueber den normalisierten Seitentext (klein, nur Buchstaben und Ziffern);
// leere Seiten (Scans ohne Text) haben "".
//
// Beim Oeffnen mit anderem sha256 werden PDF-Seiten der Seitenreihenfolge ueber gleiche Signaturen der neuen Fassung
// zugeordnet (eindeutige Treffer). Ohne Treffer bleibt der Index, solange es die Seite noch gibt und die Signatur
// unbekannt ist; eine Seite, die es nicht mehr gibt, wird zur eigenen Seite mit ihren Notizen (nie geloescht, nie
// still auf eine fremde Seite gelegt). Neue Seiten der Fassung kommen an ihrer Stelle dazu. Nur neu komprimiert
// (gleicher Text): alle Signaturen gleich, nichts verschiebt sich. Gilt fuer Web, Windows und iPad gleich.

export function fnv1a(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(16).padStart(8, "0");
}
export function normText(t) { return String(t || "").toLowerCase().normalize("NFKD").replace(/[^\p{L}\p{N}]+/gu, ""); }
export function pageSig(text) { const n = normText(text); return n.length < 12 ? "" : fnv1a(n); }

/**
 * Seitenreihenfolge an eine neue Fassung anpassen. `oldPdf`/`newPdf`: {sha256, pageCount, sigs, sizes}.
 * Liefert {doc, report: {moved, kept, orphaned, added, uncertain}}; `doc` ist eine Kopie, das Original bleibt.
 */
export function remapToVersion(doc, oldPdf, newPdf) {
  const out = JSON.parse(JSON.stringify(doc));
  const report = { moved: [], kept: [], orphaned: [], added: [], uncertain: [] };
  const newBySig = new Map();
  (newPdf.sigs || []).forEach((s, i) => { if (!s) return; newBySig.set(s, newBySig.has(s) ? -1 : i + 1); });   // -1 = mehrdeutig
  const used = new Set();
  const plan = out.pageOrder.map(e => {
    if ((e.type || "pdf") !== "pdf") return null;
    const sig = (oldPdf.sigs || [])[e.index - 1] || "";
    const hit = sig ? newBySig.get(sig) : undefined;
    return { e, sig, hit };
  });
  // 1. eindeutige Treffer ueber die Signatur
  for (const p of plan) if (p && p.hit > 0 && !used.has(p.hit)) { used.add(p.hit); p.to = p.hit; }
  // 2. ohne Signatur (oder ohne Treffer, aber unbekannt): gleicher Index, wenn frei und vorhanden
  for (const p of plan) {
    if (!p || p.to) continue;
    const same = p.e.index;
    const newSigThere = (newPdf.sigs || [])[same - 1] || "";
    if (same <= newPdf.pageCount && !used.has(same) && (!p.sig || !newSigThere)) { used.add(same); p.to = same; p.uncertain = true; }
  }
  for (const p of plan) {
    if (!p) continue;
    if (p.to) {
      if (p.to !== p.e.index) report.moved.push([p.e.index, p.to]); else if (p.uncertain) report.uncertain.push(p.e.index); else report.kept.push(p.e.index);
      p.e.index = p.to;
    } else {
      // Seite gibt es in der neuen Fassung nicht (mehr): eigene Seite mit den Notizen, Masse der alten Fassung
      const [w, h] = (oldPdf.sizes || [])[p.e.index - 1] || [595, 842];
      report.orphaned.push(p.e.index);
      p.e.orphanOf = { index: p.e.index, sha256: oldPdf.sha256 };
      p.e.type = "blank"; p.e.template = "blank"; p.e.w = w; p.e.h = h; delete p.e.index;
    }
  }
  // 3. neue Seiten der Fassung an ihrer Stelle einfuegen (hinter der PDF-Seite mit dem naechstkleineren Index)
  const keys = new Set(out.pageOrder.map(e => e.key));
  for (let j = 1; j <= newPdf.pageCount; j++) {
    if (used.has(j)) continue;
    let key = "p" + j; while (keys.has(key)) key = "p" + j + "n" + Math.random().toString(36).slice(2, 6);
    keys.add(key);
    let at = 0;
    out.pageOrder.forEach((e, i) => { if ((e.type || "pdf") === "pdf" && e.index < j) at = i + 1; });
    out.pageOrder.splice(at, 0, { key, type: "pdf", index: j });
    out.pages[key] = out.pages[key] || { objects: [] };
    used.add(j); report.added.push(j);
  }
  out.pdf = { sha256: newPdf.sha256, pageCount: newPdf.pageCount, sigs: newPdf.sigs, sizes: newPdf.sizes };
  return { doc: out, report };
}

export function describe(report) {
  const parts = [];
  if (report.moved.length) parts.push(`${report.moved.length} Seite(n) an ihre neue Stelle verschoben`);
  if (report.added.length) parts.push(`${report.added.length} neue Seite(n)`);
  if (report.orphaned.length) parts.push(`${report.orphaned.length} Seite(n) gibt es nicht mehr – ihre Notizen stehen jetzt auf eigenen Seiten`);
  if (report.uncertain.length) parts.push(`${report.uncertain.length} Seite(n) ohne lesbaren Text, Zuordnung bitte prüfen`);
  return parts.length ? `Neue Fassung der PDF: ${parts.join(", ")}.` : "Neue Fassung der PDF, Seiten unverändert.";
}

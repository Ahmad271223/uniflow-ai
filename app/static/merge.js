// Drei-Wege-Zusammenfuehrung von Notizseiten (Basis = letzter bestaetigter Serverstand, lokal, Server).
// Gleiche Regeln wie UniFlowCore/AnnotationMerge.swift; gemeinsame Testfaelle: packages/shared-contracts/fixtures/merge.
// - nur auf einer Seite geaendert -> diese Aenderung gilt
// - neu auf einer Seite -> wird uebernommen (Striche beider Geraete bleiben)
// - auf einer Seite geloescht, auf der anderen unveraendert -> geloescht
// - auf einer Seite geloescht, auf der anderen geaendert -> bleibt (Konflikt)
// - auf beiden Seiten verschieden geaendert -> lokaler Stand (Konflikt)

/** JSON mit sortierten Schluesseln: Gleichheit unabhaengig von der Reihenfolge der Felder. */
export function stableStringify(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v === undefined ? null : v);
  if (Array.isArray(v)) return "[" + v.map(stableStringify).join(",") + "]";
  return "{" + Object.keys(v).sort().filter(k => v[k] !== undefined).map(k => JSON.stringify(k) + ":" + stableStringify(v[k])).join(",") + "}";
}

const same = (a, b) => (a == null && b == null) || (a != null && b != null && stableStringify(a) === stableStringify(b));

export function objectId(o) { return o && typeof o.id === "string" && o.id ? o.id : "~" + stableStringify(o); }

export function mergeObjects(base, local, server) {
  const index = list => { const m = new Map(); for (const o of list || []) m.set(objectId(o), o); return m; };
  const b = index(base), l = index(local);
  const out = [], emitted = new Set(); let conflicts = 0;
  for (const o of server || []) {
    const id = objectId(o); if (emitted.has(id)) continue; emitted.add(id);
    const bo = b.get(id), lo = l.get(id);
    if (lo !== undefined) {
      if (same(lo, bo) || same(lo, o)) out.push(o);
      else if (same(o, bo)) out.push(lo);
      else { out.push(lo); conflicts++; }
    } else if (bo === undefined) out.push(o);                 // neu auf dem anderen Geraet
    else if (!same(o, bo)) { out.push(o); conflicts++; }      // hier geloescht, dort geaendert -> behalten
  }
  for (const o of local || []) {
    const id = objectId(o); if (emitted.has(id)) continue; emitted.add(id);
    const bo = b.get(id);
    if (bo === undefined) out.push(o);                        // neu auf diesem Geraet
    else if (!same(o, bo)) { out.push(o); conflicts++; }      // dort geloescht, hier geaendert -> behalten
  }
  return { objects: out, conflicts };
}

/** Eine Seite zusammenfuehren; null = Seite existiert (dort) nicht. Ergebnis: { page, conflicts }. */
export function mergePage(base, local, server) {
  if (same(local, base)) return { page: server ?? null, conflicts: 0 };
  if (same(server, base) || same(server, local)) return { page: local ?? null, conflicts: 0 };
  if (local == null) return { page: server, conflicts: 1 };
  if (server == null) return { page: local, conflicts: 1 };
  const result = {}; let conflicts = 0;
  const keys = new Set([...Object.keys(local), ...Object.keys(server), ...Object.keys(base || {})]);
  for (const k of keys) {
    if (k === "objects" || k === "pkdrawing") continue;
    const bv = base ? base[k] : undefined, lv = local[k], sv = server[k];
    let v;
    if (same(lv, bv)) v = sv; else if (same(sv, bv) || same(sv, lv)) v = lv; else { v = lv; conflicts++; }
    if (v !== undefined) result[k] = v;
  }
  const m = mergeObjects(base?.objects || [], local.objects || [], server.objects || []);
  result.objects = m.objects; conflicts += m.conflicts;
  // native iPad-Zeichnung nur behalten, wenn sie noch genau zu den Objekten passt
  if (local.pkdrawing && same(m.objects, local.objects || [])) result.pkdrawing = local.pkdrawing;
  else if (server.pkdrawing && same(m.objects, server.objects || [])) result.pkdrawing = server.pkdrawing;
  return { page: result, conflicts };
}

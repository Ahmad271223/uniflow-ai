// Drei-Wege-Zusammenfuehrung von Notizseiten und ganzen Dokumenten (Basis = letzter bestaetigter Serverstand, lokal, Server).
// Referenz fuer UniFlowCore/AnnotationMerge.swift und apps/android/core (AnnotationMerge.kt, AnnotationDocument.kt);
// gemeinsame Testfaelle: packages/shared-contracts/fixtures/merge/cases.json (cases = Seite, documentCases = Dokument).
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
  // native iPad-Zeichnung: v1 nur, wenn sie noch genau zu den Objekten passt. v2 prueft das iPad je Strich selbst
  // (strokeSigs) und bleibt deshalb auch bei abweichenden Objekten erhalten (wie AnnotationMerge.mergedDrawing)
  const perStroke = pk => !!pk && pk.format === "pkdrawing-v2" && Array.isArray(pk.strokeSigs);
  if (local.pkdrawing && same(m.objects, local.objects || [])) result.pkdrawing = local.pkdrawing;
  else if (server.pkdrawing && same(m.objects, server.objects || [])) result.pkdrawing = server.pkdrawing;
  else if (perStroke(local.pkdrawing)) result.pkdrawing = local.pkdrawing;
  else if (perStroke(server.pkdrawing)) result.pkdrawing = server.pkdrawing;
  return { page: result, conflicts };
}

// ---------------------------------------------------------------- Dokument: Seitenreihenfolge, Papierkorb, Wurzelfelder
// Gemeinsame Faelle: documentCases in packages/shared-contracts/fixtures/merge/cases.json (Web, Kotlin, Swift).
// Reihenfolge (nur Schluessel, Loeschen gegen Aenderung wie mergePage):
// - nur auf einer Seite umsortiert/eingefuegt -> diese Reihenfolge gilt
// - beide geaendert, auf den gemeinsamen Seiten aber gleich -> vertraeglich: eingefuegte Seiten jeder Seite hinter
//   ihrem Vorgaenger (Serverseiten zuerst, dann die lokalen), kein Konflikt
// - beide verschieden umsortiert -> dieses Geraet, orderConflict = true und ein Konflikt (sichtbar machen!)
// Papierkorb: Eintraege beider Seiten je Schluessel vereinigt (hier zuerst), ohne Seiten, die wieder in der Reihenfolge stehen.
// Eintraege (Drehung, Vorlage, ...) und Wurzelfelder (note, bookmarks, outline, ...) nach der Feldregel aus mergePage.

const keyOf = e => (e && typeof e === "object") ? (typeof e.key === "string" ? e.key : (e.entry && typeof e.entry.key === "string" ? e.entry.key : null)) : (typeof e === "string" ? e : null);
const orderKeys = doc => ((doc && doc.pageOrder) || []).map(keyOf).filter(k => k != null);
const pageOf = (doc, k) => (doc && doc.pages && doc.pages[k] != null) ? doc.pages[k] : null;
const entryOf = (doc, k) => ((doc && doc.pageOrder) || []).find(e => keyOf(e) === k) ?? null;

/** Feldregel wie in mergePage: nur hier geaendert -> hier, nur dort -> dort, beide verschieden -> hier + Konflikt. */
export function mergeField(bv, lv, sv) {
  if (same(lv, bv)) return { value: sv, conflicts: 0 };
  if (same(sv, bv) || same(sv, lv)) return { value: lv, conflicts: 0 };
  return { value: lv, conflicts: 1 };
}

/** Welche Seiten bleiben und in welcher Folge; Ergebnis { keys, conflict }. */
export function mergePageOrder(base, local, server) {
  const B = orderKeys(base), L = orderKeys(local), S = orderKeys(server);
  const bSet = new Set(B), lSet = new Set(L), sSet = new Set(S);
  const dropped = k => {
    if (lSet.has(k) && sSet.has(k)) return false;
    if (!bSet.has(k)) return false;                                    // neu auf einer Seite: bleibt
    if (!lSet.has(k)) return same(pageOf(server, k), pageOf(base, k)); // hier geloescht: weg, wenn dort unveraendert
    return same(pageOf(local, k), pageOf(base, k));                    // dort geloescht: weg, wenn hier unveraendert
  };
  const Lk = L.filter(k => !dropped(k)), Sk = S.filter(k => !dropped(k)), Bk = B.filter(k => !dropped(k));
  const common = new Set(Lk.filter(k => Sk.includes(k)));
  const restrict = list => list.filter(k => common.has(k));
  const eq = (a, b) => a.length === b.length && a.every((k, i) => k === b[i]);
  const oL = restrict(Lk), oS = restrict(Sk), oB = restrict(Bk);
  let primary, secondary, conflict = false;
  if (eq(oL, oS) || eq(oS, oB)) { primary = Lk; secondary = Sk; }      // vertraeglich oder nur hier umsortiert
  else if (eq(oL, oB)) { primary = Sk; secondary = Lk; }               // nur dort umsortiert
  else { primary = Lk; secondary = Sk; conflict = true; }              // beide verschieden: dieses Geraet, Konflikt
  const out = [...primary];
  for (let i = 0; i < secondary.length; i++) {
    const k = secondary[i]; if (out.includes(k)) continue;
    let at = 0;                                                        // hinter dem naechsten Vorgaenger, der schon drin ist
    for (let j = i - 1; j >= 0; j--) { const p = out.indexOf(secondary[j]); if (p >= 0) { at = p + 1; break; } }
    out.splice(at, 0, k);
  }
  return { keys: out, conflict };
}

/** Papierkorb beider Seiten: je Schluessel einmal (hier zuerst), ohne Seiten, die in der Reihenfolge stehen. */
export function mergeTrash(local, server, keys) {
  const inOrder = new Set(keys), seen = new Set(), out = [];
  for (const e of [...((local && local.deletedPages) || []), ...((server && server.deletedPages) || [])]) {
    const k = keyOf(e); if (k == null || seen.has(k) || inOrder.has(k)) continue;
    seen.add(k); out.push(e);
  }
  return out;
}

/** Ganzes Dokument zusammenfuehren; Ergebnis { doc, conflicts, orderConflict }. */
export function mergeDocument(base, local, server) {
  let conflicts = 0;
  const pages = {};
  const keys = new Set([...Object.keys((server && server.pages) || {}), ...Object.keys((local && local.pages) || {}), ...Object.keys((base && base.pages) || {})]);
  for (const k of keys) {
    const r = mergePage(pageOf(base, k), pageOf(local, k), pageOf(server, k));
    if (r.page != null) pages[k] = r.page;
    conflicts += r.conflicts;
  }
  const order = mergePageOrder(base, local, server);
  if (order.conflict) conflicts++;
  const pageOrder = order.keys.map(k => {
    const lE = entryOf(local, k), sE = entryOf(server, k);
    if (lE && sE) { const f = mergeField(entryOf(base, k), lE, sE); conflicts += f.conflicts; return f.value; }
    return lE ?? sE;
  });
  for (const k of order.keys) if (!pages[k]) pages[k] = pageOf(local, k) ?? pageOf(server, k) ?? { objects: [] };
  const out = {};
  const rootKeys = new Set([...Object.keys(server || {}), ...Object.keys(local || {}), ...Object.keys(base || {})]);
  for (const k of rootKeys) {
    if (k === "pages" || k === "pageOrder" || k === "deletedPages") continue;
    const f = mergeField(base ? base[k] : undefined, local ? local[k] : undefined, server ? server[k] : undefined);
    conflicts += f.conflicts;
    if (f.value !== undefined) out[k] = f.value;
  }
  out.pages = pages; out.pageOrder = pageOrder; out.deletedPages = mergeTrash(local, server, order.keys);
  return { doc: out, conflicts, orderConflict: order.conflict };
}

import Foundation

/// Drei-Wege-Zusammenfuehrung (Basis = letzter bestaetigter Serverstand, lokal, Server) wie app/static/merge.js,
/// die Referenz des Vertrags; gemeinsame Faelle: packages/shared-contracts/fixtures/merge/cases.json (`cases` =
/// Seite, `documentCases` = Dokument).
///
/// Regeln je Objekt (Identitaet = `id`, ohne `id` der Inhalt):
/// - nur auf einer Seite geaendert -> diese Aenderung gilt
/// - neu auf einer Seite -> wird uebernommen (Striche beider Geraete bleiben erhalten)
/// - auf einer Seite geloescht und auf der anderen unveraendert -> geloescht
/// - auf einer Seite geloescht, auf der anderen geaendert -> bleibt erhalten (Konflikt wird gezaehlt)
/// - auf beiden Seiten verschieden geaendert -> Stand dieses Geraets (Konflikt wird gezaehlt)
///
/// Dokument (`mergeDocument`: Seitenreihenfolge, Papierkorb, Wurzelfelder; Regel vom 26.10.2026):
/// - Welche Seiten bleiben: wie `mergePage` (auf einer Seite geloescht, auf der anderen unveraendert -> weg; gegen
///   geaendert -> bleibt an ihrem Platz, Konflikt).
/// - Reihenfolge: nur eine Seite umsortiert/eingefuegt -> diese gilt. Beide geaendert, auf den gemeinsamen Seiten
///   aber gleich -> vertraeglich: eingefuegte Seiten jeder Seite hinter ihrem Vorgaenger (Serverseiten zuerst, dann
///   lokale), kein Konflikt. Beide verschieden umsortiert -> dieses Geraet, `orderConflict` und ein Konflikt (die
///   Oberflaeche zeigt es: `SyncIssue.seitenreihenfolge`).
/// - Papierkorb: Eintraege beider Seiten je Schluessel vereinigt (hier zuerst), ohne Seiten, die wieder in der
///   Reihenfolge stehen. Eintraege (Drehung, Vorlage) und Wurzelfelder (note, bookmarks, outline) nach der Feldregel.
public enum AnnotationMerge {

    public struct Result: Equatable, Sendable {
        public var page: JSONValue?
        public var conflicts: Int
    }

    /// Ergebnis von `mergeDocument` (`{ doc, conflicts, orderConflict }` in merge.js)
    public struct DocumentResult: Equatable, Sendable {
        public var doc: JSONValue
        public var conflicts: Int
        /// beide Geraete haben die Seiten verschieden umsortiert: die Reihenfolge dieses Geraets gilt
        public var orderConflict: Bool
    }

    /// `same(a, b)` in merge.js: fehlend und null sind gleich, sonst gleicher Inhalt
    static func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        let an = a == nil || a == .null, bn = b == nil || b == .null
        if an || bn { return an && bn }
        return a == b
    }

    public static func objectID(_ o: JSONValue) -> String {
        if let id = o["id"]?.string, !id.isEmpty { return id }
        return "~" + o.jsonString(sortedKeys: true)
    }

    /// Eine Seite zusammenfuehren. `nil` bedeutet: Seite existiert (dort) nicht.
    public static func mergePage(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> Result {
        if same(local, base) { return Result(page: server, conflicts: 0) }
        if same(server, base) || same(server, local) { return Result(page: local, conflicts: 0) }
        guard let l = local else { return Result(page: server, conflicts: 1) }   // lokal geloescht, Server geaendert
        guard let s = server else { return Result(page: l, conflicts: 1) }       // auf Server geloescht, lokal geaendert
        let lo = l.object ?? [:], so = s.object ?? [:], bo = base?.object ?? [:]
        var result: [String: JSONValue] = [:]
        var conflicts = 0
        for key in Set(lo.keys).union(so.keys).union(bo.keys) where key != "objects" && key != "pkdrawing" {
            let (value, c) = mergeField(base: bo[key], local: lo[key], server: so[key])
            if let value { result[key] = value }
            conflicts += c
        }
        let localObjects = l["objects"]?.array ?? []
        let serverObjects = s["objects"]?.array ?? []
        let (objects, c) = mergeObjects(base: base?["objects"]?.array ?? [], local: localObjects, server: serverObjects)
        result["objects"] = .array(objects)
        conflicts += c
        if let pk = mergedDrawing(local: lo["pkdrawing"], server: so["pkdrawing"],
                                  objectsMatchLocal: objects == localObjects, objectsMatchServer: objects == serverObjects) {
            result["pkdrawing"] = pk
        }
        return Result(page: .object(result), conflicts: conflicts)
    }

    /// Native Zeichnung des Ergebnisses. v1 nur, wenn sie noch genau zu den Objekten passt. v2 prueft jeden Strich
    /// beim Laden selbst (Signatur je Strich) und bleibt deshalb auch bei abweichenden Objekten erhalten: geloeschte
    /// oder im Browser geaenderte Striche werden dann aus den Objekten aufgebaut, alle anderen behalten ihr natives
    /// Aussehen. Vorrang hat die Zeichnung dieses Geraets (neuester nativer Stand).
    static func mergedDrawing(local: JSONValue?, server: JSONValue?, objectsMatchLocal: Bool, objectsMatchServer: Bool) -> JSONValue? {
        if let local, objectsMatchLocal { return local }
        if let server, objectsMatchServer { return server }
        if StoredDrawing.isPerStroke(local) { return local }
        if StoredDrawing.isPerStroke(server) { return server }
        return nil
    }

    /// Feldregel wie `mergeField` in merge.js: nur hier geaendert -> hier, nur dort -> dort, beide verschieden ->
    /// hier + Konflikt
    public static func mergeField(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> (JSONValue?, Int) {
        if same(local, base) { return (server, 0) }
        if same(server, base) || same(server, local) { return (local, 0) }
        return (local, 1)
    }

    public static func mergeObjects(base: [JSONValue], local: [JSONValue], server: [JSONValue]) -> ([JSONValue], Int) {
        func index(_ list: [JSONValue]) -> [String: JSONValue] {
            var d: [String: JSONValue] = [:]
            d.reserveCapacity(list.count)
            for o in list { d[objectID(o)] = o }
            return d
        }
        let b = index(base), l = index(local)
        var out: [JSONValue] = []
        out.reserveCapacity(max(local.count, server.count))
        var conflicts = 0
        var emitted = Set<String>()
        emitted.reserveCapacity(local.count + server.count)
        for o in server {
            let id = objectID(o)
            guard emitted.insert(id).inserted else { continue }
            let bo = b[id]
            if let lo = l[id] {
                if lo == bo || lo == o { out.append(o) }
                else if o == bo { out.append(lo) }
                else { out.append(lo); conflicts += 1 }
            } else if bo == nil {
                out.append(o)                                   // neu auf dem anderen Geraet
            } else if o != bo {
                out.append(o); conflicts += 1                   // hier geloescht, dort geaendert -> behalten
            }                                                   // hier geloescht, dort unveraendert -> weg
        }
        for o in local {
            let id = objectID(o)
            guard emitted.insert(id).inserted else { continue }
            let bo = b[id]
            if bo == nil { out.append(o) }                      // neu auf diesem Geraet
            else if o != bo { out.append(o); conflicts += 1 }   // dort geloescht, hier geaendert -> behalten
        }
        return (out, conflicts)
    }

    // MARK: Dokument: Seitenreihenfolge, Papierkorb, Wurzelfelder

    /// Schluessel eines Eintrags in `pageOrder` oder `deletedPages` (`keyOf`): `key`, `entry.key` oder ein Text
    static func keyOf(_ e: JSONValue) -> String? {
        if let k = e["key"]?.string { return k }
        if let k = e["entry"]?["key"]?.string { return k }
        return e.string
    }

    static func orderKeys(_ doc: JSONValue?) -> [String] { (doc?["pageOrder"]?.array ?? []).compactMap(keyOf) }

    static func pageOf(_ doc: JSONValue?, _ k: String) -> JSONValue? {
        guard let p = doc?["pages"]?[k], p != .null else { return nil }
        return p
    }

    static func entryOf(_ doc: JSONValue?, _ k: String) -> JSONValue? {
        (doc?["pageOrder"]?.array ?? []).first { keyOf($0) == k }
    }

    /// `mergePageOrder(base, local, server)`: welche Seiten bleiben und in welcher Folge (Dokumente mit `pageOrder`
    /// und `pages`); `conflict`: beide Geraete haben die gemeinsamen Seiten verschieden umsortiert
    public static func mergePageOrder(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> (keys: [String], conflict: Bool) {
        let B = orderKeys(base), L = orderKeys(local), S = orderKeys(server)
        let bSet = Set(B), lSet = Set(L), sSet = Set(S)
        func dropped(_ k: String) -> Bool {
            if lSet.contains(k), sSet.contains(k) { return false }
            if !bSet.contains(k) { return false }                                    // neu auf einer Seite: bleibt
            if !lSet.contains(k) { return same(pageOf(server, k), pageOf(base, k)) }  // hier geloescht: weg, wenn dort unveraendert
            return same(pageOf(local, k), pageOf(base, k))                           // dort geloescht: weg, wenn hier unveraendert
        }
        let Lk = L.filter { !dropped($0) }, Sk = S.filter { !dropped($0) }, Bk = B.filter { !dropped($0) }
        let common = Set(Lk).intersection(Sk)
        let oL = Lk.filter(common.contains), oS = Sk.filter(common.contains), oB = Bk.filter(common.contains)
        var primary: [String], secondary: [String], conflict = false
        if oL == oS || oS == oB { primary = Lk; secondary = Sk }              // vertraeglich oder nur hier umsortiert
        else if oL == oB { primary = Sk; secondary = Lk }                     // nur dort umsortiert
        else { primary = Lk; secondary = Sk; conflict = true }                // beide verschieden: dieses Geraet, Konflikt
        var out = primary
        for (i, k) in secondary.enumerated() where !out.contains(k) {
            var at = 0                                                        // hinter dem naechsten Vorgaenger, der schon drin ist
            var j = i - 1
            while j >= 0 {
                if let p = out.firstIndex(of: secondary[j]) { at = p + 1; break }
                j -= 1
            }
            out.insert(k, at: at)
        }
        return (out, conflict)
    }

    /// `mergeTrash(local, server, keys)`: Papierkorb beider Seiten: je Schluessel einmal (hier zuerst), ohne Seiten,
    /// die in der Reihenfolge stehen
    public static func mergeTrash(local: JSONValue?, server: JSONValue?, keys: [String]) -> [JSONValue] {
        let inOrder = Set(keys)
        var seen = Set<String>(), out: [JSONValue] = []
        for e in (local?["deletedPages"]?.array ?? []) + (server?["deletedPages"]?.array ?? []) {
            guard let k = keyOf(e), !inOrder.contains(k), seen.insert(k).inserted else { continue }
            out.append(e)
        }
        return out
    }

    /// Reihenfolge, Papierkorb und Wurzelfelder eines Dokuments (ohne die Seiten selbst): der Teil von
    /// `mergeDocument`, den `SyncEngine` nach seinem eigenen Seitenabgleich braucht. Die Dokumente tragen `pages`
    /// nur fuer die Regel, welche Seiten bleiben; das Ergebnis hat kein `pages`.
    static func mergeRootMeta(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> (meta: JSONValue, conflicts: Int, orderConflict: Bool) {
        var conflicts = 0
        let order = mergePageOrder(base: base, local: local, server: server)
        if order.conflict { conflicts += 1 }
        var pageOrder: [JSONValue] = []
        for k in order.keys {
            let lE = entryOf(local, k), sE = entryOf(server, k)
            if let lE, let sE {
                let (v, c) = mergeField(base: entryOf(base, k), local: lE, server: sE)
                conflicts += c
                if let v { pageOrder.append(v) }
            } else if let e = lE ?? sE {
                pageOrder.append(e)
            }
        }
        var out: [String: JSONValue] = [:]
        let rootKeys = Set((server?.object ?? [:]).keys).union((local?.object ?? [:]).keys).union((base?.object ?? [:]).keys)
        for k in rootKeys where k != "pages" && k != "pageOrder" && k != "deletedPages" {
            let (v, c) = mergeField(base: base?[k], local: local?[k], server: server?[k])
            conflicts += c
            if let v { out[k] = v }
        }
        out["pageOrder"] = .array(pageOrder)
        // merge.js setzt deletedPages immer; hier nur, wenn eine Seite es kannte oder etwas darin steht, damit ein
        // Stand ohne Papierkorb gleich dem Serverstand bleibt (nichts erneut hochladen)
        let trash = mergeTrash(local: local, server: server, keys: order.keys)
        if !trash.isEmpty || local?["deletedPages"] != nil || server?["deletedPages"] != nil || base?["deletedPages"] != nil {
            out["deletedPages"] = .array(trash)
        }
        return (.object(out), conflicts, order.conflict)
    }

    /// `mergeDocument(base, local, server)`: ganzes Dokument zusammenfuehren (Seiten mit `mergePage`, Reihenfolge,
    /// Papierkorb, Wurzelfelder). Fehlende Dokumente (`nil` oder null) gelten als leer.
    public static func mergeDocument(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> DocumentResult {
        let base = base == .null ? nil : base, local = local == .null ? nil : local, server = server == .null ? nil : server
        var conflicts = 0
        var pages: [String: JSONValue] = [:]
        let keys = Set((server?["pages"]?.object ?? [:]).keys).union((local?["pages"]?.object ?? [:]).keys).union((base?["pages"]?.object ?? [:]).keys)
        for k in keys {
            let r = mergePage(base: pageOf(base, k), local: pageOf(local, k), server: pageOf(server, k))
            if let p = r.page, p != .null { pages[k] = p }
            conflicts += r.conflicts
        }
        let (meta, c, orderConflict) = mergeRootMeta(base: base, local: local, server: server)
        conflicts += c
        for k in orderKeys(meta) where pages[k] == nil {
            pages[k] = pageOf(local, k) ?? pageOf(server, k) ?? ["objects": []]
        }
        var doc = meta.object ?? [:]
        doc["pages"] = .object(pages)
        return DocumentResult(doc: .object(doc), conflicts: conflicts, orderConflict: orderConflict)
    }
}

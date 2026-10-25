import Foundation

/// Drei-Wege-Zusammenfuehrung (Basis = letzter bestaetigter Serverstand, lokal, Server).
///
/// Regeln je Objekt (Identitaet = `id`, ohne `id` der Inhalt):
/// - nur auf einer Seite geaendert -> diese Aenderung gilt
/// - neu auf einer Seite -> wird uebernommen (Striche beider Geraete bleiben erhalten)
/// - auf einer Seite geloescht und auf der anderen unveraendert -> geloescht
/// - auf einer Seite geloescht, auf der anderen geaendert -> bleibt erhalten (Konflikt wird gezaehlt)
/// - auf beiden Seiten verschieden geaendert -> Stand dieses Geraets (Konflikt wird gezaehlt)
public enum AnnotationMerge {

    public struct Result: Equatable, Sendable {
        public var page: JSONValue?
        public var conflicts: Int
    }

    public static func objectID(_ o: JSONValue) -> String {
        if let id = o["id"]?.string, !id.isEmpty { return id }
        return "~" + o.jsonString(sortedKeys: true)
    }

    /// Eine Seite zusammenfuehren. `nil` bedeutet: Seite existiert (dort) nicht.
    public static func mergePage(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> Result {
        if local == base { return Result(page: server, conflicts: 0) }
        if server == base || server == local { return Result(page: local, conflicts: 0) }
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

    static func mergeField(base: JSONValue?, local: JSONValue?, server: JSONValue?) -> (JSONValue?, Int) {
        if local == base { return (server, 0) }
        if server == base || server == local { return (local, 0) }
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

    /// Wurzelfelder ohne `pages`. `pageOrder`: Reihenfolge des Servers, hier hinzugefuegte Seiten werden angehaengt.
    public static func mergeRootMeta(base: JSONValue, local: JSONValue, server: JSONValue) -> (JSONValue, Int) {
        if local == base { return (server, 0) }
        if server == base || server == local { return (local, 0) }
        let lo = local.object ?? [:], so = server.object ?? [:], bo = base.object ?? [:]
        var result: [String: JSONValue] = [:]
        var conflicts = 0
        for key in Set(lo.keys).union(so.keys).union(bo.keys) where key != "pages" {
            if key == "pageOrder" {
                result[key] = mergePageOrder(base: bo[key]?.array ?? [], local: lo[key]?.array ?? [], server: so[key]?.array ?? [])
                continue
            }
            let (value, c) = mergeField(base: bo[key], local: lo[key], server: so[key])
            if let value { result[key] = value }
            conflicts += c
        }
        return (.object(result), conflicts)
    }

    static func mergePageOrder(base: [JSONValue], local: [JSONValue], server: [JSONValue]) -> JSONValue {
        if local == base { return .array(server) }
        if server == base { return .array(local) }
        var out = server
        let known = Set(server.compactMap { $0["key"]?.string })
        let baseKeys = Set(base.compactMap { $0["key"]?.string })
        for p in local {
            guard let k = p["key"]?.string, !known.contains(k), !baseKeys.contains(k) else { continue }
            out.append(p)                                       // nur hier neu hinzugefuegt
        }
        return .array(out)
    }
}

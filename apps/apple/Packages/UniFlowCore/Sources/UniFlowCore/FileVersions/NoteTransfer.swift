import Foundation

/// Notizen einer Datei auf ihre neue Original-Fassung umhaengen (S7). Reine Funktionen auf `AnnotationDocument`; die
/// Seiten behalten ihre Schluessel und ihren Inhalt, nur `index` der PDF-Seiten in `pageOrder` (und im Papierkorb)
/// zeigt danach auf die neue Fassung (`PageMatch`).
///
/// - PDF-Seite mit Gegenstueck: neuer `index`; eingefuegte Seiten (Leerseite, Bild, PDF) dahinter gehen mit.
/// - entfernte Seite: verschwindet samt ihrem Inhalt aus dem Dokument; ihre Notizen bleiben auf der alten Fassung
///   (Abzug in `file_versions`), eingefuegte Seiten dahinter haengen an der vorigen Seite.
/// - neue Seite: eigener Eintrag (Schluessel `p<n>`, sonst `p<n>-v<Fassung>`).
/// - Reihenfolge: Hatte der Nutzer die PDF-Seiten nicht umgestellt, gilt die Reihenfolge der neuen Fassung (eine in der
///   Vorlage verschobene Folie steht dann an ihrem neuen Platz); sonst bleibt seine Reihenfolge, und neue Seiten kommen
///   hinter die Seite mit der naechstkleineren Seitenzahl.
/// - Lesezeichen und Gliederung bleiben (ein Eintrag zu einer entfernten Seite wird wie im Web nicht angezeigt).
/// - `origin`: Herkunftsstempel (Inhalts-Hash, Seitenzahl und Nummer der Fassung), an dem der Editor erkennt, zu
///   welcher Original-PDF die Notizen gehoeren.
public enum NoteTransfer {

    /// Seitenliste, wie Editor und Web sie ohne Notizen anlegen (`ensurePDFPages`, `migrate()`)?
    static func isAutomaticPageList(_ order: [JSONValue]) -> Bool {
        for (i, e) in order.enumerated() {
            guard let o = e.object, o["type"]?.string == "pdf", o["index"]?.int == i + 1, o["key"]?.string == "p\(i + 1)",
                  Set(o.keys).isSubset(of: ["key", "type", "index"]) else { return false }
        }
        return true
    }

    /// Hat das Dokument Notizen (mehr als die automatische Seitenliste)? Objekte auf einer Seite, eingefuegte,
    /// gedrehte, umgestellte oder geloeschte Seiten, Lesezeichen, Gliederung oder eine Notiz zum Dokument.
    public static func hasNotes(_ doc: AnnotationDocument) -> Bool {
        if doc.pages.values.contains(where: { !($0["objects"]?.array ?? []).isEmpty }) { return true }
        if !isAutomaticPageList(doc.pageOrder) { return true }
        for k in ["bookmarks", "outline", "deletedPages"] where !(doc.root[k]?.array ?? []).isEmpty { return true }
        if let note = doc.root["note"]?.string, !note.isEmpty { return true }
        return false
    }

    /// PDF-Seiten (1-basiert), auf denen Notizen liegen (auch auf einer verdoppelten Seite)
    public static func pagesWithNotes(_ doc: AnnotationDocument) -> Set<Int> {
        var out = Set<Int>()
        for e in doc.pageOrder where (e["type"]?.string ?? "pdf") == "pdf" {
            guard let key = e["key"]?.string, let i = e["index"]?.int, !doc.objects(page: key).isEmpty else { continue }
            out.insert(i)
        }
        return out
    }

    /// Hoechste PDF-Seite, auf die das Dokument verweist (Seitenzahl der alten Fassung, wenn sie fehlt)
    static func highestPDFIndex(_ doc: AnnotationDocument) -> Int {
        let trash = (doc.root["deletedPages"]?.array ?? []).compactMap { $0["entry"] }
        return (doc.pageOrder + trash).filter { ($0["type"]?.string ?? "pdf") == "pdf" }.compactMap { $0["index"]?.int }.max() ?? 0
    }

    public struct Result: Equatable, Sendable {
        public var document: AnnotationDocument
        /// Seiten, die mit ihrer alten Seite entfallen (nur auf der alten Fassung)
        public var removedKeys: [String]
        /// Seiten der neuen Fassung ohne Gegenstueck
        public var addedKeys: [String]
    }

    private struct Group {
        var entry: JSONValue
        var index: Int?
        var trailing: [JSONValue] = []
    }

    /// Notizen auf die neue Fassung umhaengen. `version`: Nummer der neuen Fassung (fuer Schluessel neuer Seiten und
    /// den Herkunftsstempel), `sha256`: Inhalts-Hash der neuen Fassung.
    public static func transfer(_ document: AnnotationDocument, match: PageMatch.Result, version: Int, sha256: String?) -> Result {
        var doc = document
        doc.ensurePDFPages(count: match.oldCount)
        var head: [JSONValue] = []
        var groups: [Group] = []
        for e in doc.pageOrder {
            if (e["type"]?.string ?? "pdf") == "pdf" { groups.append(Group(entry: e, index: e["index"]?.int)) }
            else if groups.isEmpty { head.append(e) }
            else { groups[groups.count - 1].trailing.append(e) }
        }
        let oldIndices = groups.compactMap(\.index)
        let userOrder = zip(oldIndices, oldIndices.dropFirst()).contains { $0 > $1 }

        // zuordnen; eingefuegte Seiten einer entfernten Seite haengen an der vorigen
        var kept: [Group] = []
        var removedKeys: [String] = []
        for var g in groups {
            if let i = g.index, let n = match.newIndex(old: i) {
                g.entry["index"] = .number(Double(n))
                g.index = n
                kept.append(g)
            } else {
                if let key = g.entry["key"]?.string { removedKeys.append(key) }
                if kept.isEmpty { head += g.trailing } else { kept[kept.count - 1].trailing += g.trailing }
            }
        }

        // neue Seiten
        var used = Set(doc.pageOrder.compactMap { $0["key"]?.string }).union(doc.pages.keys)
        for d in doc.root["deletedPages"]?.array ?? [] { if let k = d["entry"]?["key"]?.string { used.insert(k) } }
        var addedKeys: [String] = []
        var added: [Group] = []
        for n in match.added {
            var key = "p\(n)"
            if used.contains(key) { key = "p\(n)-v\(version)" }
            var k = 2
            while used.contains(key) { key = "p\(n)-v\(version)-\(k)"; k += 1 }
            used.insert(key)
            addedKeys.append(key)
            added.append(Group(entry: .object(["key": .string(key), "type": "pdf", "index": .number(Double(n))]), index: n))
        }
        var ordered: [Group]
        if userOrder {
            ordered = kept
            for g in added {
                let n = g.index ?? 0
                let at = ordered.lastIndex { ($0.index ?? 0) < n }.map { $0 + 1 } ?? 0
                ordered.insert(g, at: at)
            }
        } else {
            ordered = (kept + added).enumerated().sorted { a, b in
                let x = a.element.index ?? 0, y = b.element.index ?? 0
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        doc.root["pageOrder"] = .array(head + ordered.flatMap { [$0.entry] + $0.trailing })

        var pages = doc.pages
        for k in removedKeys where !ordered.contains(where: { $0.entry["key"]?.string == k }) { pages.removeValue(forKey: k) }
        for k in addedKeys { pages[k] = .object(["objects": .array([])]) }
        doc.pages = pages

        // Papierkorb: Seiten der alten Fassung zeigen auf ihre neue Seite, entfernte bleiben nur auf der alten
        if let trash = doc.root["deletedPages"]?.array {
            doc.root["deletedPages"] = .array(trash.compactMap { d in
                guard let entry = d["entry"], (entry["type"]?.string ?? "pdf") == "pdf" else { return d }
                guard let i = entry["index"]?.int, let n = match.newIndex(old: i) else { return nil }
                var out = d
                out["entry"]?["index"] = .number(Double(n))
                return out
            })
        }
        doc.root["origin"] = .object(["sha256": sha256.map(JSONValue.string) ?? .null, "pages": .number(Double(match.newCount)),
                                      "version": .number(Double(version))])
        return Result(document: doc, removedKeys: removedKeys, addedKeys: addedKeys)
    }
}

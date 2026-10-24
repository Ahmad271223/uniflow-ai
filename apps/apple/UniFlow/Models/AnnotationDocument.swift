import Foundation

/// Notizmodell einer Datei im gemeinsamen Format "uniflow-annotations" Version 2
/// (siehe packages/shared-contracts/annotations.schema.json).
///
/// - `pageOrder`: Reihenfolge der Seiten; `type: "pdf"` mit `index` (1-basiert) verweist auf eine PDF-Seite,
///   andere Typen (blank, asset) sind im Web-Editor eingefuegte Seiten.
/// - `pages[key].objects`: Objekte der Seite in Seitenpunkten (Ursprung oben links, Seite ohne Zoom).
/// - `pages[key].pkdrawing`: zusaetzlich die native PencilKit-Zeichnung (`data` Base64) samt Signatur der
///   Objekte, aus denen sie stammt. Stimmt die Signatur nicht mehr (Seite im Browser bearbeitet), wird die
///   Zeichnung aus den Objekten neu aufgebaut.
struct AnnotationDocument {
    var root: JSONValue
    var version: Int

    static func empty() -> AnnotationDocument {
        AnnotationDocument(root: .object(["version": .number(2), "zoom": .number(1.2), "pages": .object([:]), "pageOrder": .array([])]), version: 0)
    }

    var pageOrder: [JSONValue] { root["pageOrder"]?.array ?? [] }

    /// Legt p1…pN an, wenn noch keine Seitenliste existiert (wie migrate() im Web-Editor).
    mutating func ensurePDFPages(count: Int) {
        if root["pages"]?.object == nil { root["pages"] = .object([:]) }
        if root["version"] == nil { root["version"] = .number(2) }
        guard pageOrder.isEmpty, count > 0 else { return }
        var order: [JSONValue] = []
        var pages = root["pages"]?.object ?? [:]
        for i in 1...count {
            order.append(.object(["key": .string("p\(i)"), "type": .string("pdf"), "index": .number(Double(i))]))
            if pages["p\(i)"] == nil { pages["p\(i)"] = .object(["objects": .array([])]) }
        }
        root["pageOrder"] = .array(order)
        root["pages"] = .object(pages)
    }

    /// Seitenschluessel zur PDF-Seite (1-basiert).
    func pageKey(forPDFIndex index: Int) -> String? {
        for p in pageOrder where p["type"]?.string == "pdf" && p["index"]?.int == index {
            if let key = p["key"]?.string { return key }
        }
        return nil
    }

    /// Anzahl der Seiten, die nur im Web-Editor existieren (in dieser App noch nicht angezeigt).
    var insertedPageCount: Int { pageOrder.filter { $0["type"]?.string != "pdf" }.count }

    func page(_ key: String) -> JSONValue? { root["pages"]?[key] }

    func objects(page key: String) -> [JSONValue] { page(key)?["objects"]?.array ?? [] }

    func pkDrawing(page key: String) -> (data: String, signature: String)? {
        guard let pk = page(key)?["pkdrawing"], let d = pk["data"]?.string, let s = pk["objectsSig"]?.string else { return nil }
        return (d, s)
    }

    mutating func setPage(_ key: String, objects: [JSONValue], pkData: String, signature: String) {
        var pages = root["pages"]?.object ?? [:]
        var p = pages[key] ?? .object([:])
        p["objects"] = .array(objects)
        p["pkdrawing"] = .object(["data": .string(pkData), "objectsSig": .string(signature), "format": .string("pkdrawing-v1")])
        pages[key] = p
        root["pages"] = .object(pages)
    }

    /// Uebernimmt eine Seite unveraendert (fuer die Konfliktaufloesung).
    mutating func setPageRaw(_ key: String, _ value: JSONValue) {
        var pages = root["pages"]?.object ?? [:]
        pages[key] = value
        root["pages"] = .object(pages)
    }
}

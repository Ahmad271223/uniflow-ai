import Foundation

/// Notizmodell einer Datei im gemeinsamen Format "uniflow-annotations" Version 2
/// (siehe packages/shared-contracts/annotations.schema.json).
///
/// - `pageOrder`: Reihenfolge der Seiten; `type: "pdf"` mit `index` (1-basiert) verweist auf eine PDF-Seite,
///   andere Typen (blank, asset) sind im Web-Editor eingefuegte Seiten.
/// - `pages[key].objects`: Objekte der Seite in Seitenpunkten (Ursprung oben links, Seite ohne Zoom).
/// - `pages[key].pkdrawing`: zusaetzlich die native PencilKit-Zeichnung (`data` Base64) samt Signatur der
///   Objekte, aus denen sie stammt, und den Objekt-IDs je PencilKit-Strich (`strokeIds`). Ab `pkdrawing-v2`
///   zusaetzlich eine Signatur je Strich (`strokeSigs`), damit eine Browser-Aenderung nur die betroffenen
///   Striche neu aufbauen laesst.
public struct AnnotationDocument: Equatable, Sendable {
    public var root: JSONValue

    public static let emptyRoot: JSONValue = .object([
        "version": .number(2), "zoom": .number(1.2), "pages": .object([:]), "pageOrder": .array([]),
    ])

    public init(root: JSONValue) {
        if case .object = root { self.root = root } else { self.root = AnnotationDocument.emptyRoot }
        if self.root["pages"]?.object == nil { self.root["pages"] = .object([:]) }
    }

    /// Dokument aus Wurzelfeldern (ohne `pages`) und Seiten.
    public init(rootMeta: JSONValue, pages: [String: JSONValue]) {
        var r = rootMeta.object ?? AnnotationDocument.emptyRoot.object!
        r["pages"] = .object(pages)
        self.init(root: .object(r))
    }

    public static func empty() -> AnnotationDocument { AnnotationDocument(root: emptyRoot) }

    public var pageOrder: [JSONValue] { root["pageOrder"]?.array ?? [] }

    public var pages: [String: JSONValue] {
        get { root["pages"]?.object ?? [:] }
        set { root["pages"] = .object(newValue) }
    }

    /// Wurzel ohne die Seiten (Reihenfolge, Lesezeichen, Gliederung, Notiz ...).
    public var rootMeta: JSONValue {
        var r = root.object ?? [:]
        r.removeValue(forKey: "pages")
        return .object(r)
    }

    /// Legt p1…pN an, wenn noch keine Seitenliste existiert (wie migrate() im Web-Editor).
    /// - Returns: `true`, wenn die Seitenliste neu angelegt wurde.
    @discardableResult
    public mutating func ensurePDFPages(count: Int) -> Bool {
        if root["version"] == nil { root["version"] = .number(2) }
        guard pageOrder.isEmpty, count > 0 else { return false }
        var order: [JSONValue] = []
        order.reserveCapacity(count)
        for i in 1...count {
            order.append(.object(["key": .string("p\(i)"), "type": .string("pdf"), "index": .number(Double(i))]))
        }
        root["pageOrder"] = .array(order)
        return true
    }

    /// Seitenschluessel zur PDF-Seite (1-basiert). `nil`, wenn die Seite im Browser entfernt wurde.
    public func pageKey(forPDFIndex index: Int) -> String? {
        for p in pageOrder where p["type"]?.string == "pdf" && p["index"]?.int == index {
            if let key = p["key"]?.string { return key }
        }
        return nil
    }

    /// PDF-Seite (1-basiert) zu einem Seitenschluessel, `nil` fuer eingefuegte Seiten.
    public func pdfIndex(forPageKey key: String) -> Int? {
        for p in pageOrder where p["key"]?.string == key && p["type"]?.string == "pdf" { return p["index"]?.int }
        return nil
    }

    /// Anzahl der Seiten, die nur im Web-Editor existieren (eingefuegte Leer-, Bild- oder PDF-Seiten).
    public var insertedPageCount: Int { pageOrder.filter { $0["type"]?.string != "pdf" }.count }

    /// PDF-Seiten (1-basiert), die im Browser aus der Seitenliste entfernt wurden.
    public func removedPDFIndices(pdfPageCount: Int) -> [Int] {
        guard !pageOrder.isEmpty, pdfPageCount > 0 else { return [] }
        let present = Set(pageOrder.compactMap { $0["type"]?.string == "pdf" ? $0["index"]?.int : nil })
        return (1...pdfPageCount).filter { !present.contains($0) }
    }

    public func page(_ key: String) -> JSONValue? { root["pages"]?[key] }

    public func objects(page key: String) -> [JSONValue] { page(key)?["objects"]?.array ?? [] }
}

/// Native Zeichnung einer Seite, wie sie im Feld `pkdrawing` steht.
///
/// - `pkdrawing-v1`: gueltig nur, solange `objectsSig` zu allen Objekten der Seite passt.
/// - `pkdrawing-v2`: zusaetzlich `strokeSigs[i]` = Signatur der Objekte von `strokeIds[i]`. Jeder native Strich
///   ist fuer sich gueltig, solange seine Objekte unveraendert sind. `objectsSig` wird weiter geschrieben, damit
///   aeltere App-Versionen (nur v1) die Zeichnung als Ganzes verwenden oder verwerfen koennen.
public struct StoredDrawing: Equatable, Sendable {
    public static let formatV1 = "pkdrawing-v1"
    public static let formatV2 = "pkdrawing-v2"

    public var data: String
    public var signature: String
    /// Objekt-IDs je PencilKit-Strich (gleiche Reihenfolge wie die Striche der Zeichnung).
    public var strokeIDs: [[String]]
    /// Signatur je Strich (nur v2, gleiche Reihenfolge wie `strokeIDs`); `nil` = v1.
    public var strokeSignatures: [String]?

    public init(data: String, signature: String, strokeIDs: [[String]], strokeSignatures: [String]? = nil) {
        self.data = data
        self.signature = signature
        self.strokeIDs = strokeIDs
        self.strokeSignatures = strokeSignatures
    }

    public init?(page: JSONValue?) {
        guard let pk = page?["pkdrawing"] else { return nil }
        self.init(json: pk)
    }

    public init?(json pk: JSONValue) {
        guard let d = pk["data"]?.string, let s = pk["objectsSig"]?.string else { return nil }
        data = d
        signature = s
        strokeIDs = (pk["strokeIds"]?.array ?? []).map { ($0.array ?? []).compactMap { $0.string } }
        if pk["format"]?.string == StoredDrawing.formatV2, let sigs = pk["strokeSigs"]?.array {
            strokeSignatures = sigs.map { $0.string ?? "" }
        } else {
            strokeSignatures = nil
        }
    }

    /// v2: jeder Strich traegt seine eigene Signatur.
    public var isPerStroke: Bool { strokeSignatures != nil }

    /// `true`, wenn das Feld `pkdrawing` eine v2-Zeichnung ist (prueft ihre Gueltigkeit je Strich selbst).
    public static func isPerStroke(_ pk: JSONValue?) -> Bool {
        guard let pk else { return false }
        return pk["format"]?.string == formatV2 && pk["strokeSigs"]?.array != nil
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "data": .string(data), "objectsSig": .string(signature),
            "format": .string(strokeSignatures == nil ? StoredDrawing.formatV1 : StoredDrawing.formatV2),
            "strokeIds": .array(strokeIDs.map { .array($0.map { .string($0) }) }),
        ]
        if let strokeSignatures { o["strokeSigs"] = .array(strokeSignatures.map { .string($0) }) }
        return .object(o)
    }
}

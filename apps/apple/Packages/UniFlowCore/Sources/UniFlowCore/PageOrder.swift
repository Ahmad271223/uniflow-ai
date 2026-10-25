import Foundation

/// Seitenoperationen im gemeinsamen Notizmodell, gleiches Ergebnis wie im Web-Editor (app/static/editor.js:
/// `addBlankPage`, `deletePage`, `restorePage`).
///
/// - `pageOrder`: Reihenfolge; eingefuegte Leerseiten haben `type: "blank"`, Vorlage, Breite und Hoehe.
/// - `deletedPages`: Papierkorb, je Eintrag `{entry, objects, at, pos}` (Eintrag aus `pageOrder`, Objekte der Seite,
///   Zeitpunkt in Millisekunden, frueherer Platz). `pages[key]` bleibt beim Loeschen erhalten (wie im Web).
///
/// Reine Funktionen auf `AnnotationDocument`; Speichern und Hochladen uebernimmt der Aufrufer anhand von `Change`.
public enum PageOrder {

    /// Vorlagen fuer Leerseiten (gleiche Schluessel wie TEMPLATES im Web-Editor).
    public static let templates = ["blank", "lined", "grid", "dotted", "mm", "cornell"]

    /// Ergebnis einer Seitenoperation.
    public struct Change: Equatable, Sendable {
        /// Seite, die danach angezeigt werden soll (neue, wiederhergestellte oder Nachbarseite).
        public var focusKey: String?
        /// Seiten, deren Inhalt in `pages` geaendert wurde (die Wurzelfelder aendern sich immer).
        public var changedPageKeys: [String]

        public init(focusKey: String?, changedPageKeys: [String]) {
            self.focusKey = focusKey
            self.changedPageKeys = changedPageKeys
        }
    }

    /// Eintrag im Papierkorb (fuer Listen in der Oberflaeche).
    public struct TrashedPage: Equatable, Sendable {
        /// Position in `deletedPages`.
        public var trashIndex: Int
        public var key: String
        /// pdf | blank | asset
        public var type: String
        /// 1-basierte PDF-Seite, nur bei `type == "pdf"`.
        public var pdfIndex: Int?
        public var template: String?
        /// Frueherer Platz in `pageOrder` (0-basiert).
        public var position: Int
        public var deletedAt: Date?
        public var objectCount: Int
    }

    // MARK: Schluessel

    /// Neuer Schluessel fuer eine Leerseite wie `"b" + uid()` im Web-Editor (8 Zufallszeichen + 4 Zeitzeichen, Basis 36).
    public static func newBlankKey(now: Date = Date()) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var rng = SystemRandomNumberGenerator()
        let random = String((0..<8).map { _ in alphabet[Int(rng.next() % 36)] })
        let time = String(Int(now.timeIntervalSince1970 * 1000), radix: 36)
        return "b" + random + String(time.suffix(4))
    }

    static func keys(_ doc: AnnotationDocument) -> [String] { doc.pageOrder.compactMap { $0["key"]?.string } }

    static func index(of key: String, in order: [JSONValue]) -> Int? { order.firstIndex { $0["key"]?.string == key } }

    // MARK: Einfuegen

    /// Leerseite nach `afterKey` einfuegen (ohne oder mit unbekanntem Schluessel: am Ende).
    /// Unbekannte Vorlagen werden zu `blank`. `pages[key]` wird angelegt, falls noch nicht vorhanden.
    @discardableResult
    public static func insertBlank(_ doc: inout AnnotationDocument, after afterKey: String?, template: String,
                                   width: Double = 595, height: Double = 842, key: String? = nil) -> Change? {
        var order = doc.pageOrder
        var newKey = key ?? newBlankKey()
        if key == nil {
            while doc.page(newKey) != nil || index(of: newKey, in: order) != nil { newKey = newBlankKey() }
        } else if index(of: newKey, in: order) != nil {
            return nil                                          // Schluessel schon vergeben
        }
        let t = templates.contains(template) ? template : "blank"
        let entry: JSONValue = .object([
            "key": .string(newKey), "type": "blank", "template": .string(t),
            "w": .number(width > 0 ? width : 595), "h": .number(height > 0 ? height : 842),
        ])
        let pos = afterKey.flatMap { index(of: $0, in: order) }.map { $0 + 1 } ?? order.count
        order.insert(entry, at: pos)
        doc.root["pageOrder"] = .array(order)
        var changed: [String] = []
        if doc.page(newKey) == nil {
            doc.pages[newKey] = .object(["objects": .array([])])
            changed.append(newKey)
        }
        return Change(focusKey: newKey, changedPageKeys: changed)
    }

    // MARK: Papierkorb

    /// Seite in den Papierkorb legen. Die letzte verbliebene Seite bleibt (wie im Web-Editor).
    /// `focusKey` ist die Seite, die danach an ihrer Stelle steht (sonst die vorherige).
    @discardableResult
    public static func trash(_ doc: inout AnnotationDocument, key: String, now: Date = Date()) -> Change? {
        var order = doc.pageOrder
        guard order.count > 1, let i = index(of: key, in: order) else { return nil }
        let entry = order.remove(at: i)
        var deleted = doc.root["deletedPages"]?.array ?? []
        deleted.append(.object([
            "entry": entry,
            "objects": .array(doc.objects(page: key)),
            "at": .number((now.timeIntervalSince1970 * 1000).rounded()),
            "pos": .number(Double(i)),
        ]))
        doc.root["pageOrder"] = .array(order)
        doc.root["deletedPages"] = .array(deleted)
        let neighbor = order[min(i, order.count - 1)]["key"]?.string
        return Change(focusKey: neighbor, changedPageKeys: [])
    }

    /// Papierkorb-Eintraege in der gespeicherten Reihenfolge (aelteste zuerst).
    public static func trashedPages(_ doc: AnnotationDocument) -> [TrashedPage] {
        (doc.root["deletedPages"]?.array ?? []).enumerated().compactMap { i, d in
            guard let entry = d["entry"], let key = entry["key"]?.string else { return nil }
            let type = entry["type"]?.string ?? "pdf"
            return TrashedPage(
                trashIndex: i, key: key, type: type,
                pdfIndex: type == "pdf" ? entry["index"]?.int : nil,
                template: entry["template"]?.string,
                position: max(0, d["pos"]?.int ?? 0),
                deletedAt: d["at"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) },
                objectCount: d["objects"]?.array?.count ?? 0)
        }
    }

    /// Juengsten Papierkorb-Eintrag dieser Seite wiederherstellen.
    @discardableResult
    public static func restore(_ doc: inout AnnotationDocument, key: String) -> Change? {
        guard let i = trashedPages(doc).last(where: { $0.key == key })?.trashIndex else { return nil }
        return restore(&doc, trashIndex: i)
    }

    /// Papierkorb-Eintrag wiederherstellen: zurueck an den frueheren Platz (hoechstens ans Ende), Objekte zurueck in
    /// `pages[key]`. Andere Felder der Seite (z. B. `pkdrawing`) bleiben; passt deren Signatur nicht mehr zu den
    /// Objekten, wird die Zeichnung wie gewohnt aus den Objekten neu aufgebaut.
    /// Steht die Seite schon in `pageOrder` (z. B. nach einer Zusammenfuehrung), wird nur der Eintrag entfernt.
    @discardableResult
    public static func restore(_ doc: inout AnnotationDocument, trashIndex: Int) -> Change? {
        var deleted = doc.root["deletedPages"]?.array ?? []
        guard deleted.indices.contains(trashIndex) else { return nil }
        let d = deleted[trashIndex]
        guard let entry = d["entry"], let key = entry["key"]?.string else { return nil }
        deleted.remove(at: trashIndex)
        var order = doc.pageOrder
        if index(of: key, in: order) == nil {
            order.insert(entry, at: min(max(0, d["pos"]?.int ?? order.count), order.count))
        }
        doc.root["pageOrder"] = .array(order)
        doc.root["deletedPages"] = .array(deleted)
        let before = doc.page(key)
        var page = before ?? .object([:])
        if case .object = page {} else { page = .object([:]) }
        if let objects = d["objects"], case .array = objects { page["objects"] = objects }
        else if page["objects"] == nil { page["objects"] = .array([]) }
        var changed: [String] = []
        if page != before {
            doc.pages[key] = page
            changed.append(key)
        }
        return Change(focusKey: key, changedPageKeys: changed)
    }
}

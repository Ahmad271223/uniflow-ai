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

    // MARK: Groesse

    /// Seitengroesse ohne die zusaetzliche Drehung aus `pageOrder` (wie `baseW`/`baseH` im Web-Editor): bei 90 und
    /// 270 Grad sind Breite und Hoehe der angezeigten Seite vertauscht. Groesse neuer Leerseiten nach dieser Seite.
    /// Ungewoehnliche Werte zaehlen wie in der Anzeige (`SolutionGeometry.normalized`: abgerundet auf Vielfache von 90,
    /// auch negativ oder ueber 360), z. B. 45 wie 0 und -90 wie 270.
    public static func baseSize(shownWidth: Double, shownHeight: Double, extraRotation: Int) -> (width: Double, height: Double) {
        SolutionGeometry.normalized(extraRotation) % 180 == 0 ? (shownWidth, shownHeight) : (shownHeight, shownWidth)
    }

    /// Groesste Seitenkante (200 Zoll wie `SolutionLimits.maxPageSide`, groesste Seite nach PDF-Spezifikation)
    public static let maxSide = SolutionLimits.maxPageSide

    /// Groesse einer eingefuegten Leerseite aus ihrem Eintrag in `pageOrder` (`w`, `h`), eine Regel fuer Anzeige,
    /// Loesungspaket und Einfuegen: fehlende, nicht endliche oder nicht positive Werte werden zu A4 (595 x 842),
    /// groessere als `maxSide` werden begrenzt. Notizen stehen in Seitenpunkten; mit derselben Groesse ueberall liegen
    /// sie im Editor und beim Empfaenger an derselben Stelle.
    public static func blankSize(width w: Double?, height h: Double?) -> (width: Double, height: Double) {
        func side(_ v: Double?, _ fallback: Double) -> Double {
            guard let v, v.isFinite, v > 0 else { return fallback }
            return min(v, maxSide)
        }
        return (side(w, 595), side(h, 842))
    }

    public static func blankSize(_ entry: JSONValue) -> (width: Double, height: Double) {
        blankSize(width: entry["w"]?.double, height: entry["h"]?.double)
    }

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
        let size = blankSize(width: width, height: height)
        let entry: JSONValue = .object([
            "key": .string(newKey), "type": "blank", "template": .string(t),
            "w": .number(size.width), "h": .number(size.height),
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

    // MARK: Drehen

    /// Seite um `degrees` (Vielfaches von 90) im Uhrzeigersinn drehen, wie `rotatePage` im Web-Editor: `rotation` im
    /// Eintrag von `pageOrder`, die Objekte der Seite drehen mit (P0-7, `PageRotation`), damit sie auf demselben Inhalt
    /// bleiben. `shownWidth` x `shownHeight` = angezeigte Seite vor dem Drehen. Andere Felder der Seite bleiben; die
    /// native Zeichnung (`pkdrawing`) rechnet das iPad selbst um (sonst wird sie wie gewohnt aus den Objekten gebaut).
    @discardableResult
    public static func rotate(_ doc: inout AnnotationDocument, key: String, shownWidth: Double, shownHeight: Double,
                              degrees: Int = 90) -> Change? {
        var order = doc.pageOrder
        guard let i = index(of: key, in: order) else { return nil }
        order[i]["rotation"] = .number(Double(SolutionGeometry.normalized((order[i]["rotation"]?.int ?? 0) + degrees)))
        doc.root["pageOrder"] = .array(order)
        let objects = doc.objects(page: key)
        guard !objects.isEmpty, var page = doc.page(key) else { return Change(focusKey: key, changedPageKeys: []) }
        page["objects"] = .array(PageRotation.rotate(objects, width: shownWidth, height: shownHeight, degrees: degrees))
        doc.pages[key] = page
        return Change(focusKey: key, changedPageKeys: [key])
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
    /// Steht die Seite schon in `pageOrder` (z. B. nach einer Zusammenfuehrung), wird nur der Eintrag entfernt;
    /// `pages[key]` bleibt dann unberuehrt, damit seitdem entstandene Objekte nicht verloren gehen.
    /// Hat sich `pages[key]` seit dem Loeschen geaendert (beide Geraete haben die Seite geloescht, das andere vorher
    /// darauf geschrieben: `mergeTrash` behaelt den Papierkorb-Eintrag dieses Geraets, `pages[key]` hat den neueren
    /// Stand), gehen diese Objekte nicht verloren: Objekte des Papierkorbs in ihrer Reihenfolge, dabei je Kennung der
    /// Stand aus `pages[key]`, dahinter die Objekte, die nur dort stehen (`AnnotationMerge.objectID`). Ohne Aenderung
    /// seit dem Loeschen (der Normalfall) ist das genau der Papierkorb-Eintrag wie im Web.
    @discardableResult
    public static func restore(_ doc: inout AnnotationDocument, trashIndex: Int) -> Change? {
        var deleted = doc.root["deletedPages"]?.array ?? []
        guard deleted.indices.contains(trashIndex) else { return nil }
        let d = deleted[trashIndex]
        guard let entry = d["entry"], let key = entry["key"]?.string else { return nil }
        deleted.remove(at: trashIndex)
        doc.root["deletedPages"] = .array(deleted)
        var order = doc.pageOrder
        if index(of: key, in: order) != nil {
            return Change(focusKey: key, changedPageKeys: [])   // Seite ist schon da: alter Stand waere veraltet
        }
        order.insert(entry, at: min(max(0, d["pos"]?.int ?? order.count), order.count))
        doc.root["pageOrder"] = .array(order)
        let before = doc.page(key)
        var page = before ?? .object([:])
        if case .object = page {} else { page = .object([:]) }
        if let objects = d["objects"]?.array {
            page["objects"] = .array(restoredObjects(trashed: objects, current: page["objects"]?.array ?? []))
        } else if page["objects"] == nil { page["objects"] = .array([]) }
        var changed: [String] = []
        if page != before {
            doc.pages[key] = page
            changed.append(key)
        }
        return Change(focusKey: key, changedPageKeys: changed)
    }

    /// Objekte einer wiederhergestellten Seite: Papierkorb-Objekte (Reihenfolge), je Kennung der Stand aus der Seite,
    /// dahinter, was nur in der Seite steht. Nichts aus beiden Listen geht verloren.
    static func restoredObjects(trashed: [JSONValue], current: [JSONValue]) -> [JSONValue] {
        guard trashed != current else { return trashed }
        var byID: [String: JSONValue] = [:]
        for o in current where byID[AnnotationMerge.objectID(o)] == nil { byID[AnnotationMerge.objectID(o)] = o }
        var out: [JSONValue] = []
        var placed = Set<String>()
        for o in trashed {
            let id = AnnotationMerge.objectID(o)
            guard placed.insert(id).inserted else { continue }
            out.append(byID[id] ?? o)
        }
        for o in current where placed.insert(AnnotationMerge.objectID(o)).inserted { out.append(o) }
        return out
    }
}

/// Geometrie der Bildschirmvorlagen wie `renderTemplate` in app/static/editor.js, in Seitenpunkten (Ursprung oben
/// links). Die App zeichnet daraus Ebenen (`PaperTemplate`); Farben und Strichstaerken stehen ebenfalls hier, damit
/// sie zusammen mit den Abstaenden gegen das Web geprueft werden koennen.
public struct TemplateGeometry: Equatable, Sendable {
    /// Waagrechte Linien ueber die ganze Breite (liniert und Cornell ab 60 pt, Raster ab 0), y-Werte.
    public var horizontal: [Double] = []
    /// Senkrechte Linien ueber die ganze Hoehe (Raster, Millimeter), x-Werte.
    public var vertical: [Double] = []
    /// Millimeterpapier: jede zehnte Linie (1 cm, Index 0, 10, 20 ...) kraeftiger; sonst nil.
    public var boldEvery: Int?
    /// Punktraster: Spalten (x) und Zeilen (y), Punkte an allen Kreuzungen.
    public var dotColumns: [Double] = []
    public var dotRows: [Double] = []
    /// Cornell: senkrechte Trennlinie bei x = 150 bis `cornellFooterY`, waagrechte bei `cornellFooterY`.
    public var cornellFooterY: Double?

    // Werte wie im Web (Farben als #rrggbb)
    public static let lineColor = "#d9dde8"
    public static let dotColor = "#c9ced9"
    public static let cornellRuleColor = "#b9c2d6"
    public static let cornellLabelColor = "#9aa0ae"
    public static let cornellPaper = "#fffdf7"
    public static let lineWidth = 0.6           // liniert, Cornell
    public static let gridWidth = 0.5           // Raster, Millimeter (duenn)
    public static let gridBoldWidth = 1.2       // Millimeter, jede zehnte
    public static let cornellRuleWidth = 1.4
    public static let dotRadius = 0.9
    public static let cornellDividerX = 150.0
    public static let cornellFooterHeight = 150.0
    /// Beschriftungen (Text, Grundlinie links); `fromBottom`: y vom unteren Rand gemessen.
    public static let cornellLabels: [(text: String, x: Double, y: Double, fromBottom: Bool)] = [
        ("Stichworte", 12, 22, false), ("Notizen", 162, 22, false), ("Zusammenfassung", 12, 128, true),
    ]

    public init() {}

    /// Abstand der Linien: 24 pt liniert/Cornell, 5 mm Raster und Punkte, 1 mm Millimeterpapier.
    public static func step(_ template: String) -> Double {
        template == "mm" ? 2.835 : (template == "grid" || template == "dotted") ? 14.17 : 24
    }

    /// Geometrie fuer eine Seite; leer bei `blank`, `nil`, unbekannten Vorlagen und leerer oder nicht endlicher
    /// Groesse. Linien gibt es hoechstens bis `PageOrder.maxSide` (sonst liefe die Schleife bei einer beschaedigten
    /// Seitengroesse wie 1e999 = unendlich nie zu Ende): Millimeterpapier auf der groessten Seite sind rund 5100 Linien
    /// je Richtung.
    public static func make(_ template: String?, width rawW: Double, height rawH: Double) -> TemplateGeometry {
        var g = TemplateGeometry()
        guard let t = template, t != "blank", PageOrder.templates.contains(t), rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0 else { return g }
        let W = min(rawW, PageOrder.maxSide), H = min(rawH, PageOrder.maxSide)
        let step = step(t)
        // Positionen als Vielfache des Abstands (nicht aufsummiert), sonst wandern sie auf langen Seiten
        func run(from start: Double, below limit: Double) -> [Double] {
            var out: [Double] = []
            var i = 0
            while start + Double(i) * step < limit { out.append(start + Double(i) * step); i += 1 }
            return out
        }
        switch t {
        case "lined":
            g.horizontal = run(from: 60, below: H)
        case "cornell":
            g.horizontal = run(from: 60, below: H)
            g.cornellFooterY = H - cornellFooterHeight
        case "grid", "mm":
            g.vertical = run(from: 0, below: W)
            g.horizontal = run(from: 0, below: H)
            g.boldEvery = t == "mm" ? 10 : nil
        case "dotted":
            g.dotColumns = run(from: step, below: W)
            g.dotRows = run(from: step, below: H)
        default:
            break
        }
        return g
    }

    public var isEmpty: Bool {
        horizontal.isEmpty && vertical.isEmpty && dotColumns.isEmpty && cornellFooterY == nil
    }

    /// Linie mit Index `i` ist kraeftig (nur Millimeterpapier).
    public func isBold(_ i: Int) -> Bool { boldEvery.map { i % $0 == 0 } ?? false }
}

import Foundation

/// Notizen neben der Folie mitschicken (Wunsch des Inhabers 05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md).
///
/// - **Seitennotiz**: Leerseite im eigenen Dokument direkt hinter einer Folie ("Leere Seite danach").
/// - **Blatt daneben**: eigenes Notizbuch in der geteilten Ansicht. Das Hauptdokument merkt sich im Wurzelfeld
///   `sideSheets`, neben welcher eigenen Seite eine Blattseite beschrieben wurde (erste Seite gilt):
///   `[{"file": "<Notizbuch>", "pages": {"<Blattseite>": "<Seite im Dokument>"}}]`.
///
/// Reine Funktionen auf `AnnotationDocument`; Laden der Blaetter, Speichern und Rendern uebernimmt die App.
public enum SideNotes {

    /// Wurzelfeld im Hauptdokument
    public static let field = "sideSheets"
    /// Praefix der eingeflochtenen Blattseiten. Bewusst kein Notizblatt-Schluessel (`SolutionBuilder.isNotebookKey`):
    /// beim Zusammenfuehren einer Loesung bleiben sie wie Leerseiten hinter ihrer PDF-Seite.
    public static let keyPrefix = "sn"
    /// Felder im eingeflochtenen `pageOrder`-Eintrag: Seite im Dokument, neben der geschrieben wurde, und das Blatt
    public static let sideOfField = "sideOf"
    public static let sideFileField = "sideFile"

    /// Ein Blatt daneben mit seinem Notizmodell.
    public struct Sheet: Sendable, Equatable {
        public var fileID: String
        public var document: AnnotationDocument

        public init(fileID: String, document: AnnotationDocument) {
            self.fileID = fileID
            self.document = document
        }
    }

    // MARK: Verknuepfen

    /// Verknuepfungen: Blatt -> (Blattseite -> Seite im Dokument). Unbrauchbare Eintraege werden uebergangen.
    public static func links(_ doc: AnnotationDocument) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for e in doc.root[field]?.array ?? [] {
            guard let file = e["file"]?.string, !file.isEmpty, let pages = e["pages"]?.object else { continue }
            for (sheetKey, v) in pages {
                guard let main = v.string, !main.isEmpty else { continue }
                if out[file]?[sheetKey] == nil { out[file, default: [:]][sheetKey] = main }
            }
        }
        return out
    }

    /// Blaetter mit mindestens einer Verknuepfung, in der gespeicherten Reihenfolge.
    public static func sheetFileIDs(_ doc: AnnotationDocument) -> [String] {
        var seen = Set<String>()
        return (doc.root[field]?.array ?? []).compactMap { e in
            guard let f = e["file"]?.string, !f.isEmpty, seen.insert(f).inserted else { return nil }
            return f
        }
    }

    /// Blattseite `sheetPage` des Blatts `sheetFile` mit der Seite `mainKey` des Dokuments verknuepfen. Die erste
    /// Verknuepfung gilt ("wo es angefangen hat"); eine schon verknuepfte Blattseite bleibt unveraendert.
    /// - Returns: `true`, wenn sich das Dokument geaendert hat.
    @discardableResult
    public static func link(_ doc: inout AnnotationDocument, sheetFile: String, sheetPage: String, to mainKey: String) -> Bool {
        guard !sheetFile.isEmpty, !sheetPage.isEmpty, !mainKey.isEmpty,
              links(doc)[sheetFile]?[sheetPage] == nil else { return false }
        var list = doc.root[field]?.array ?? []
        if let i = list.firstIndex(where: { $0["file"]?.string == sheetFile && $0["pages"]?.object != nil }) {
            var pages = list[i]["pages"]?.object ?? [:]
            pages[sheetPage] = .string(mainKey)
            list[i]["pages"] = .object(pages)
        } else {
            list.append(.object(["file": .string(sheetFile), "pages": .object([sheetPage: .string(mainKey)])]))
        }
        doc.root[field] = .array(list)
        return true
    }

    /// Wird `link` etwas aendern? (spart einen Schreibvorgang je Strich)
    public static func needsLink(_ doc: AnnotationDocument, sheetFile: String, sheetPage: String) -> Bool {
        !sheetFile.isEmpty && !sheetPage.isEmpty && links(doc)[sheetFile]?[sheetPage] == nil
    }

    // MARK: Einflechten

    /// Seite eines Blatts, die eingeflochten wurde ("sn-…", "sn2-…").
    public static func isSheetKey(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix) else { return false }
        let rest = key.dropFirst(keyPrefix.count).drop(while: \.isNumber)
        return rest.hasPrefix("-")
    }

    /// Seite hat eigene Notizobjekte
    static func hasContent(_ doc: AnnotationDocument, _ key: String) -> Bool { !doc.objects(page: key).isEmpty }

    /// Dokument in der Reihenfolge der Seitenleiste mit den Blattseiten direkt hinter ihrer Folie:
    /// Folie, ihre Seitennotizen (Leerseiten dahinter bis zur naechsten PDF-Seite), dann die neben ihr beschriebenen
    /// Blattseiten (Reihenfolge des Blatts, Blaetter in der Reihenfolge von `sheets`). Unverknuepfte Blattseiten oder
    /// solche, deren Seite es nicht mehr gibt, kommen ans Ende.
    ///
    /// - Nur Leerseiten eines Blatts (`type: "blank"`) werden uebernommen, mit Vorlage, Groesse und Drehung; neue
    ///   Schluessel `sn-<Blattseite>` und im Eintrag `sideOf` (Seite im Dokument, fehlt bei unverknuepften) und
    ///   `sideFile`. `pkdrawing` bleibt weg (die Striche stehen vollstaendig in `objects`).
    /// - `skipEmptySheetPages`: Blattseiten ohne Notizobjekte weglassen.
    /// - `skipEmptyNotePages`: zusaetzlich leere Seitennotizen des Dokuments weglassen (nur Leerseiten hinter einer
    ///   PDF-Seite; Seiten eines reinen Notizbuchs bleiben).
    public static func interleaved(main: AnnotationDocument, sheets: [Sheet], skipEmptySheetPages: Bool = true,
                                   skipEmptyNotePages: Bool = false) -> AnnotationDocument {
        let links = links(main)
        var out = main
        var pages = main.pages
        var usedKeys = Set(main.pageOrder.compactMap { $0["key"]?.string }).union(pages.keys)
        // Blattseiten je Seite im Dokument (Reihenfolge) und unverknuepfte
        var byAnchor: [String: [JSONValue]] = [:]
        var loose: [JSONValue] = []
        let mainKeys = Set(main.pageOrder.compactMap { $0["key"]?.string })
        for sheet in sheets {
            var seenInSheet = Set<String>()
            for entry in sheet.document.pageOrder where (entry["type"]?.string ?? "pdf") == "blank" {
                guard let key = entry["key"]?.string, seenInSheet.insert(key).inserted else { continue }
                if skipEmptySheetPages, !hasContent(sheet.document, key) { continue }
                var newKey = "\(keyPrefix)-" + key
                var n = 2
                while usedKeys.contains(newKey) { newKey = "\(keyPrefix)\(n)-" + key; n += 1 }
                usedKeys.insert(newKey)
                var e = entry.object ?? [:]
                e["key"] = .string(newKey)
                e[sideFileField] = .string(sheet.fileID)
                let anchor = links[sheet.fileID]?[key].flatMap { mainKeys.contains($0) ? $0 : nil }
                if let anchor { e[sideOfField] = .string(anchor) } else { e.removeValue(forKey: sideOfField) }
                var page = sheet.document.page(key)?.object ?? ["objects": .array([])]
                page.removeValue(forKey: "pkdrawing")
                pages[newKey] = .object(page)
                if let anchor { byAnchor[anchor, default: []].append(.object(e)) } else { loose.append(.object(e)) }
            }
        }
        // Reihenfolge: Blattseiten einer Seite hinter ihr und ihren Seitennotizen (vor der naechsten PDF-Seite)
        var order: [JSONValue] = []
        var pendingSheets: [JSONValue] = []
        var sawPDF = false
        for entry in main.pageOrder {
            let type = entry["type"]?.string ?? "pdf"
            if type == "pdf" {
                order += pendingSheets
                pendingSheets = []
                sawPDF = true
            }
            if skipEmptyNotePages, sawPDF, type == "blank", let k = entry["key"]?.string, !hasContent(main, k) {
                pendingSheets += byAnchor.removeValue(forKey: k) ?? []      // ihre Blattseiten bleiben
                continue
            }
            order.append(entry)
            if let k = entry["key"]?.string { pendingSheets += byAnchor.removeValue(forKey: k) ?? [] }
        }
        order += pendingSheets
        order += loose
        out.root["pageOrder"] = .array(order)
        out.pages = pages
        return out
    }

    /// Notizseiten einer Seite im eingeflochtenen Dokument: ihre Seitennotizen (Leerseiten direkt dahinter bis zur
    /// naechsten PDF-Seite) und die neben ihr beschriebenen Blattseiten, in Anzeigereihenfolge. Nur fuer PDF-Seiten;
    /// fuer eine Leerseite die Blattseiten, die neben ihr beschrieben wurden.
    public static func notePages(_ doc: AnnotationDocument, of key: String) -> [String] {
        let order = doc.pageOrder
        guard let i = order.firstIndex(where: { $0["key"]?.string == key }) else { return [] }
        let isPDF = (order[i]["type"]?.string ?? "pdf") == "pdf"
        var out: [String] = []
        var j = i + 1
        while j < order.count {
            let e = order[j]
            let type = e["type"]?.string ?? "pdf"
            if type == "pdf" { break }
            if let k = e["key"]?.string {
                if isSheetKey(k) {
                    // verknuepfte Blattseiten stehen nach `interleaved` in der Gruppe ihrer Folie (auch die einer
                    // ausgelassenen leeren Seitennotiz); unverknuepfte (ohne `sideOf`) gehoeren keiner Folie
                    if let side = e[sideOfField]?.string, isPDF || side == key { out.append(k) }
                } else if isPDF, type == "blank" {
                    out.append(k)
                }
            }
            j += 1
        }
        return out
    }

    /// Anzahl Seitennotizen und Blattseiten im eingeflochtenen Dokument (Leerseiten hinter einer PDF-Seite und alle
    /// Blattseiten)
    public static func notePageCount(_ doc: AnnotationDocument) -> Int {
        var sawPDF = false
        var n = 0
        for e in doc.pageOrder {
            let type = e["type"]?.string ?? "pdf"
            if type == "pdf" { sawPDF = true; continue }
            if let k = e["key"]?.string, isSheetKey(k) || (sawPDF && type == "blank") { n += 1 }
        }
        return n
    }

    /// Text der Notizen fuer die KI (ohne Handschrift): Texte aus Textfeldern und Haftnotizen der Seiten.
    public static func typedText(_ doc: AnnotationDocument, keys: [String]) -> String {
        keys.flatMap { k in
            doc.objects(page: k).compactMap { o -> String? in
                guard o["type"]?.string == "text", let t = o["text"]?.string else { return nil }
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
        }.joined(separator: "\n")
    }

    /// Hoechstlaenge der Notizen fuer die KI (wie MARKIERTER TEXT / MEINE LOESUNG im Prompt)
    public static let aiNotesChars = 4000
}

extension SolutionBuilder {
    /// Titel einer Seite einer Loesung beim Empfaenger: PDF-Seite -> "PDF-Seite 4", Leerseite hinter einer PDF-Seite
    /// -> "Notiz zu Folie 4", Leerseite vor der ersten PDF-Seite -> "Eigene Seite" (Browser: `pageTitle` in
    /// app/static/solutions.js).
    public static func pageTitle(_ pages: [SolutionPage], at index: Int) -> String {
        guard pages.indices.contains(index) else { return "Eigene Seite" }
        if let i = pages[index].pdfIndex { return "PDF-Seite \(i)" }
        for p in pages[..<index].reversed() {
            if let i = p.pdfIndex { return "Notiz zu Folie \(i)" }
        }
        return "Eigene Seite"
    }

    /// Folie einer Seite in der Reihenfolge `pages`: sie selbst (PDF-Seite) oder die letzte PDF-Seite davor
    public static func slideKey(of key: String, in pages: [SolutionPage]) -> String? {
        guard let i = pages.firstIndex(where: { $0.key == key }) else { return nil }
        return pages[...i].last(where: { $0.pdfIndex != nil })?.key
    }

    /// Gewaehlte Seiten mit der Folie jeder gewaehlten Notizseite: ohne ihre Folie stuende eine Notiz beim Empfaenger
    /// als "Eigene Seite" ganz vorn (und beim Zusammenfuehren vor allen PDF-Seiten). `allowed`: Folien, die sich
    /// teilen lassen (der Aufrufer prueft sie); andere werden nicht ergaenzt.
    public static func withSlides(_ doc: AnnotationDocument, keys: [String], allowed: (String) -> Bool = { _ in true }) -> [String] {
        var out = keys
        var have = Set(keys)
        var lastPDF: String?
        for e in doc.pageOrder {
            guard let k = e["key"]?.string else { continue }
            if (e["type"]?.string ?? "pdf") == "pdf" { lastPDF = k; continue }
            // unverknuepfte Blattseiten (am Ende) gehoeren keiner Folie
            if SideNotes.isSheetKey(k), e[SideNotes.sideOfField] == nil { continue }
            if have.contains(k), let slide = lastPDF, !have.contains(slide), allowed(slide) {
                out.append(slide)
                have.insert(slide)
            }
        }
        return out
    }

    /// Seitennotizen und Blattseiten mit Notizen ("Notizen und Blätter mitschicken"): Leerseiten hinter einer
    /// PDF-Seite und eingeflochtene Blattseiten (`SideNotes.isSheetKey`)
    public static func notePageKeys(_ pages: [SolutionPage]) -> [String] {
        var sawPDF = false
        return pages.compactMap { p in
            if p.pdfIndex != nil { sawPDF = true; return nil }
            guard SideNotes.isSheetKey(p.key) || sawPDF else { return nil }
            return p.key
        }
    }
}

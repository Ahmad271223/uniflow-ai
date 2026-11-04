import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Seitentexte aus Word (.docx) und PowerPoint (.pptx) wie app/extract.py (docs/DATEIARTEN.md, 04.11.2026): ZIP und
/// XML ohne Fremdbibliothek, auf denselben Dateien dieselben Seiten wie Python
/// (packages/shared-contracts/fixtures/office-text). Dazu die Seiten eines Transkripts (Audio auf dem iPad: Text
/// neben der Datei) und die Art (`kind`) fuer Antworten.
///
/// - docx: Absaetze in Dokumentreihenfolge (auch Tabellenzellen), Tabulator und Zeilenumbruch im Absatz; Seiten
///   entstehen an Ueberschriften ab `softPageChars` Zeichen, spaetestens nach `hardPageChars` Zeichen und an echten
///   Seitenumbruechen.
/// - pptx: jede Folie eine Seite in der Reihenfolge der Praesentation, Platzhalter fuer Foliennummer, Datum, Kopf-
///   und Fusszeile ausgelassen, die Notizen der Folie als Anhang ("Notizen:").
public enum OfficeText {
    /// `SOFT_PAGE_CHARS`: neue Seite an einer Ueberschrift ab so vielen Zeichen (Codepunkte wie Pythons len) ...
    public static let softPageChars = 3000
    /// `HARD_PAGE_CHARS`: ... und spaetestens vor dem Absatz, mit dem diese Zahl erreicht ist
    public static let hardPageChars = 6000
    /// Eintraege im Paket hoechstens so gross (`MAX_ZIP_ENTRY`)
    static let maxEntry = 40 << 20
    /// `KINDS`: Art zu einer Endung; Audio nur auf dem iPad (Transkript neben der Datei)
    static let kinds: [String: String] = ["pdf": "pdf", "docx": "docx", "pptx": "pptx", "mp3": "audio", "m4a": "audio"]
    /// Transkript einer Audiodatei: Textdatei neben ihr (Zeilen = Absaetze), nur auf dem Geraet
    public static let transcriptSuffix = ".transkript.txt"

    static let wordNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let drawingNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let presentationNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let compatNS = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let headingPrefixes = ["heading", "berschrift", "überschrift", "title", "titel"]
    static let skipPlaceholders: Set<String> = ["sldNum", "dt", "ftr", "hdr"]

    // MARK: Art

    /// `text_kind(name)`: pdf | docx | pptx | audio, sonst nil (Endung ohne Rueksicht auf Gross-/Kleinschreibung)
    public static func kind(_ name: String?) -> String? {
        guard let ext = LocalFileResponse.suffix(name ?? "")?.dropFirst().lowercased() else { return nil }
        return kinds[String(ext)]
    }

    /// `is_text_source(name)`: liefert die Datei Seitentexte fuer Suche, Skriptsuche, KI-Hilfe und Wochentests?
    public static func isTextSource(_ name: String?) -> Bool { ["pdf", "docx", "pptx"].contains(kind(name) ?? "") }

    public static func isOffice(_ name: String?) -> Bool { ["docx", "pptx"].contains(kind(name) ?? "") }

    public static func isAudio(_ name: String?) -> Bool { kind(name) == "audio" }

    /// Pfad des Transkripts zu einer Audiodatei (wie `local_path` relativ zum Container)
    public static func transcriptPath(for path: String) -> String { path + transcriptSuffix }

    // MARK: Seiten aus Absaetzen

    /// `pages_from_paragraphs`: Seiten aus Absaetzen; `headings` Indizes der Ueberschriften, `breaks` die der Absaetze,
    /// vor denen ein echter Seitenumbruch steht. Leere Absaetze fallen weg; neue Seite vor einer Ueberschrift ab
    /// `softPageChars`, vor jedem Absatz ab `hardPageChars`, vor einem Umbruch immer (wenn die Seite nicht leer ist).
    public static func pages(paragraphs: [String], headings: Set<Int> = [], breaks: Set<Int> = []) -> [String] {
        var pages: [String] = []
        var cur: [String] = []
        var size = 0
        for (i, raw) in paragraphs.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if !cur.isEmpty, breaks.contains(i) || size >= hardPageChars || (headings.contains(i) && size >= softPageChars) {
                pages.append(cur.joined(separator: "\n"))
                cur = []
                size = 0
            }
            cur.append(t)
            size += t.unicodeScalars.count + 1
        }
        if !cur.isEmpty { pages.append(cur.joined(separator: "\n")) }
        return pages
    }

    /// Seiten eines Transkripts (eine Zeile je Absatz); nil, wenn die Datei fehlt oder kein UTF-8 ist
    public static func transcriptPages(url: URL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pages(paragraphs: text.components(separatedBy: "\n"))
    }

    // MARK: Word und PowerPoint

    enum Failure: Error { case unreadable(String) }

    /// Seitentexte einer Word- oder PowerPoint-Datei auf der Platte; nil fuer andere Dateien oder wenn sie sich nicht
    /// lesen laesst (wie `page_texts` bei einer kaputten PDF: keine Seiten)
    public static func pages(url: URL, name: String) -> [String]? {
        guard let k = kind(name), k == "docx" || k == "pptx", let data = try? Data(contentsOf: url) else { return nil }
        return try? pages(data: data, kind: k)
    }

    /// `office_pages_bytes(data, suffix)`; wirft bei kaputter Datei
    public static func pages(data: Data, kind: String) throws -> [String] {
        kind == "docx" ? try docxPages(data) : try pptxPages(data)
    }

    /// `docx_pages`: [] ohne Text
    public static func docxPages(_ data: Data) throws -> [String] {
        let zip: ZipReader
        do { zip = try ZipReader(data: data) } catch { throw Failure.unreadable("Word-Datei nicht lesbar") }
        guard let doc = try? zip.read("word/document.xml", limit: maxEntry) else { throw Failure.unreadable("word/document.xml fehlt") }
        let ps = try Paragraphs(data: doc, paragraph: (wordNS, "p"), text: (wordNS, "t"), tab: (wordNS, "tab"),
                                lineBreak: (wordNS, "br"), style: (wordNS, "pStyle"))
        return pages(paragraphs: ps.paragraphs, headings: ps.headings, breaks: ps.breaks)
    }

    /// `pptx_pages`: je Folie eine Seite, eine Folie ohne Text bleibt eine leere Seite
    public static func pptxPages(_ data: Data) throws -> [String] {
        let zip: ZipReader
        do { zip = try ZipReader(data: data) } catch { throw Failure.unreadable("PowerPoint-Datei nicht lesbar") }
        guard let pres = try? zip.read("ppt/presentation.xml", limit: maxEntry) else { throw Failure.unreadable("ppt/presentation.xml fehlt") }
        let rels = try relationships(zip, "ppt/_rels/presentation.xml.rels")
        var slides: [String] = []
        for rid in try SlideList(data: pres).ids {
            if let r = rels[rid], r.type.hasSuffix("/slide") { slides.append(resolve(base: "ppt", target: r.target)) }
        }
        if slides.isEmpty {
            // ohne Liste: slide1.xml, slide2.xml ... in Nummernreihenfolge
            let numbered: [(Int, String)] = zip.names.compactMap { n in
                guard n.hasPrefix("ppt/slides/slide"), n.hasSuffix(".xml") else { return nil }
                let digits = n.dropFirst("ppt/slides/slide".count).dropLast(4)
                guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let k = Int(digits) else { return nil }
                return (k, n)
            }
            slides = numbered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var out: [String] = []
        for slide in slides {
            let body = try slideText(zip, slide)
            let dir = slide.contains("/") ? String(slide[..<slide.lastIndex(of: "/")!]) : ""
            let file = slide.split(separator: "/").last.map(String.init) ?? slide
            let srels = try relationships(zip, dir + "/_rels/" + file + ".rels")
            var notes = ""
            for (_, r) in srels.sorted(by: { $0.key < $1.key }) where r.type.hasSuffix("/notesSlide") {
                notes = try slideText(zip, resolve(base: dir, target: r.target))
                break
            }
            if body.isEmpty && notes.isEmpty { out.append("") } else { out.append(body + (notes.isEmpty ? "" : "\n\nNotizen:\n" + notes)) }
        }
        return out
    }

    private static func slideText(_ zip: ZipReader, _ name: String) throws -> String {
        guard let data = try? zip.read(name, limit: maxEntry) else { return "" }
        let ps = try Paragraphs(data: data, paragraph: (drawingNS, "p"), text: (drawingNS, "t"), tab: nil,
                                lineBreak: (drawingNS, "br"), style: nil)
        return ps.paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `_rels`: Id -> (Type, Target) einer Teil-Datei; leer ohne Datei
    static func relationships(_ zip: ZipReader, _ name: String) throws -> [String: (type: String, target: String)] {
        guard let data = try? zip.read(name, limit: maxEntry) else { return [:] }
        return try Relationships(data: data).items
    }

    /// `_resolve`: Ziel einer Beziehung relativ zur Teil-Datei
    static func resolve(base: String, target: String) -> String {
        if target.hasPrefix("/") { return String(target.drop(while: { $0 == "/" })) }
        var parts = base.split(separator: "/").map(String.init)
        for seg in target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } } else if !seg.isEmpty && seg != "." { parts.append(seg) }
        }
        return parts.joined(separator: "/")
    }

    /// Attributwert nach lokalem Namen ("type", "w:type", "r:id")
    static func attribute(_ dict: [String: String], _ local: String) -> String? {
        if let v = dict[local] { return v }
        for (k, v) in dict where k.hasSuffix(":" + local) { return v }
        return nil
    }

    // MARK: XML (ereignisgesteuert wie `_Paragraphs` in Python)

    /// Absaetze aus einem OOXML-Teil: Text gehoert zum innersten offenen Absatz, Tabulator und Zeilenumbruch werden
    /// Zeichen, `mc:Fallback` (zweite Fassung desselben Inhalts) und ausgelassene Platzhalter zaehlen nicht.
    final class Paragraphs: NSObject, XMLParserDelegate {
        typealias Tag = (ns: String, name: String)
        private(set) var paragraphs: [String] = []
        private(set) var headings = Set<Int>()
        private(set) var breaks = Set<Int>()

        private let pTag: Tag, tTag: Tag, tabTag: Tag?, brTag: Tag, styleTag: Tag?
        private var stack: [[String]] = []
        private var heading: [Bool] = []
        private var fallback = 0
        private var skipShape = 0
        private var depth = 0
        private var shapeDepth: [Int] = []
        private var pendingBreak = false
        private var textDepth: Int?
        private var buffer = ""
        private var error: Error?

        init(data: Data, paragraph: Tag, text: Tag, tab: Tag?, lineBreak: Tag, style: Tag?) throws {
            pTag = paragraph; tTag = text; tabTag = tab; brTag = lineBreak; styleTag = style
            super.init()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = self
            guard parser.parse(), error == nil else { throw Failure.unreadable("XML nicht lesbar") }
        }

        private func matches(_ tag: Tag?, _ ns: String?, _ name: String) -> Bool {
            guard let tag else { return false }
            return tag.name == name && tag.ns == (ns ?? "")
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if matches((compatNS, "Fallback"), ns, name) {
                fallback += 1
            } else if matches((presentationNS, "sp"), ns, name) {
                shapeDepth.append(depth)
            } else if matches((presentationNS, "ph"), ns, name), let last = shapeDepth.last, skipShape == 0,
                      skipPlaceholders.contains(attribute(attributes, "type") ?? "") {
                skipShape = last
            } else if matches(pTag, ns, name) {
                stack.append([])
                heading.append(false)
            } else if matches(tTag, ns, name) {
                textDepth = depth
                buffer = ""
            } else if matches(brTag, ns, name), attribute(attributes, "type") == "page" {
                pageBreakAttr = true
            } else if let s = styleTag, matches(s, ns, name) {
                styleIsHeading = headingPrefixes.contains { (attribute(attributes, "val") ?? "").lowercased().hasPrefix($0) }
            }
        }

        private var pageBreakAttr = false
        private var styleIsHeading = false

        func parser(_ parser: XMLParser, foundCharacters string: String) { if textDepth == depth { buffer += string } }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { if textDepth == depth { buffer += whitespaceString } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if textDepth == depth { buffer += String(decoding: CDATABlock, as: UTF8.self) } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI ns: String?, qualifiedName: String?) {
            if fallback == 0 && skipShape == 0 {
                if matches(tTag, ns, name), !stack.isEmpty {
                    stack[stack.count - 1].append(buffer)
                } else if matches(tabTag, ns, name), !stack.isEmpty {
                    stack[stack.count - 1].append("\t")
                } else if matches(brTag, ns, name), !stack.isEmpty {
                    if pageBreakAttr { pendingBreak = true } else { stack[stack.count - 1].append("\n") }
                } else if matches(styleTag, ns, name), !stack.isEmpty, styleIsHeading {
                    heading[heading.count - 1] = true
                } else if matches((wordNS, "outlineLvl"), ns, name), !stack.isEmpty {
                    heading[heading.count - 1] = true
                } else if matches(pTag, ns, name), !stack.isEmpty {
                    let text = stack.removeLast().joined()
                    let h = heading.removeLast()
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let i = paragraphs.count
                        if pendingBreak { breaks.insert(i); pendingBreak = false }
                        if h { headings.insert(i) }
                        paragraphs.append(text)
                    }
                }
            } else if matches(pTag, ns, name), !stack.isEmpty {
                stack.removeLast()
                heading.removeLast()
            }
            if matches(tTag, ns, name) { textDepth = nil; buffer = "" }
            if matches(brTag, ns, name) { pageBreakAttr = false }
            if matches(styleTag, ns, name) { styleIsHeading = false }
            if matches((compatNS, "Fallback"), ns, name) {
                fallback -= 1
            } else if matches((presentationNS, "sp"), ns, name) {
                if let last = shapeDepth.last, last == skipShape { skipShape = 0 }
                if !shapeDepth.isEmpty { shapeDepth.removeLast() }
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    /// `p:sldIdLst/p:sldId r:id` in Reihenfolge
    private final class SlideList: NSObject, XMLParserDelegate {
        private(set) var ids: [String] = []
        private var error: Error?
        init(data: Data) throws {
            super.init()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = self
            guard parser.parse(), error == nil else { throw Failure.unreadable("presentation.xml nicht lesbar") }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?, qualifiedName: String?, attributes: [String: String]) {
            // `r:id` (Beziehung), nicht das eigene `id` der Folie (Python: `el.get(R + "id")`)
            if name == "sldId", ns == presentationNS, let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value { ids.append(id) }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    /// `Relationship Id/Type/Target`
    private final class Relationships: NSObject, XMLParserDelegate {
        private(set) var items: [String: (type: String, target: String)] = [:]
        private var error: Error?
        init(data: Data) throws {
            super.init()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = self
            guard parser.parse(), error == nil else { throw Failure.unreadable("Beziehungen nicht lesbar") }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "Relationship", ns == packageRelNS {
                items[attributes["Id"] ?? ""] = (attributes["Type"] ?? "", attributes["Target"] ?? "")
            }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }
}

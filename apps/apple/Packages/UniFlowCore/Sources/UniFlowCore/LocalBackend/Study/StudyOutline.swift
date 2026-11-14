import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Echte Lernaufgaben statt Dateinamen, mit Lernschritten (Auftrag des Inhabers 14.11.2026, Teil 2; Beispiele: Skript
/// und Arbeitsblaetter "Signale und Systeme"). Spiegel von app/outline.py, ganzzahlig gerechnet wie dort.
///
/// - Gliederung einer PDF aus ihren Lesezeichen (PDFKit): Abschnitte mit Nummer, Titel, Kapitel und Seiten, gespeichert
///   je Datei in `file_outline` (mit chdate; neue Fassung = neu lesen; nicht abgeglichen).
/// - `parts`: eine Unterlage in Aufgaben, die in die Lernzeit passen, an Abschnitts- und Kapitelgrenzen; ohne
///   Gliederung nach Seiten. Dauer nach Seiten (`minPerPage`).
/// - `steps`: feste Lernschritte je Aufgabenart zum Abhaken (ohne KI, Entscheidung des Inhabers).
enum StudyOutline {
    static let minPerPage = 4
    static let skip: Set<String> = ["title", "titel", "titelseite", "inhaltsverzeichnis", "inhalt", "contents", "table of contents",
                                    "vorwort", "literatur", "literaturverzeichnis", "index", "stichwortverzeichnis",
                                    "abbildungsverzeichnis"]
    static let longTitle = 60

    struct Section: Equatable {
        var number: String
        var title: String
        var chapter: String
        var from: Int
        var to: Int

        var json: JSONValue {
            ["number": .string(number), "title": .string(title), "chapter": .string(chapter), "from": .number(Double(from)), "to": .number(Double(to))]
        }

        init(number: String, title: String, chapter: String, from: Int, to: Int) {
            self.number = number; self.title = title; self.chapter = chapter; self.from = from; self.to = to
        }

        init?(_ v: JSONValue) {
            guard let f = v["from"]?.int, let t = v["to"]?.int else { return nil }
            self.init(number: v["number"]?.string ?? "", title: v["title"]?.string ?? "", chapter: v["chapter"]?.string ?? "", from: f, to: t)
        }
    }

    struct Part: Equatable {
        let title: String
        let est: Int
        let from: Int
        let to: Int
    }

    // MARK: Gliederung

    /// `NUM_RE`: "2.3 Faltung", "A.1 Fourier", "3. Laplace" -> (Nummer, Titel)
    static func split(_ title: String) -> (String, String)? {
        guard let m = title.range(of: #"^((?:[A-Z]|[0-9]+)(?:\.[0-9]+)*)\.?\s+(.+)$"#, options: .regularExpression) else { return nil }
        let s = String(title[m])
        guard let sp = s.range(of: #"\.?\s+"#, options: .regularExpression) else { return nil }
        let number = String(s[s.startIndex..<sp.lowerBound])
        let name = PyText.strip(String(s[sp.upperBound...]))
        return name.isEmpty ? nil : (number, name)
    }

    /// `sections_from_entries`: Lesezeichen (Ebene, Titel, Seite 1-basiert) -> Abschnitte
    static func sections(entries: [(level: Int, title: String, page: Int)], pageCount: Int) -> [Section] {
        var es = entries.map { (level: $0.level, title: PyText.strip($0.title), page: $0.page) }
            .filter { 1 <= $0.page && $0.page <= max(1, pageCount) && !$0.title.isEmpty }
        guard var top = es.map(\.level).min() else { return [] }
        if es.filter({ $0.level == top }).count == 1 && es.contains(where: { $0.level > top }) {
            top += 1
            es = es.filter { $0.level >= top }
        }
        var used: [(title: String, page: Int, chapter: String)] = []
        var chapter = ""
        for (i, e) in es.enumerated() {
            if e.level == top {
                chapter = e.title
                let hasChild = i + 1 < es.count && es[i + 1].level == top + 1
                if !hasChild { used.append((e.title, e.page, e.title)) }
            } else if e.level == top + 1 {
                used.append((e.title, e.page, chapter))
            }
        }
        var out: [Section] = []
        for u in used {
            let key = u.title.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            if skip.contains(key) { continue }
            let (number, name) = split(u.title) ?? ("", u.title)
            out.append(Section(number: number, title: name, chapter: u.chapter, from: u.page, to: 0))
        }
        out = out.enumerated().sorted { $0.element.from != $1.element.from ? $0.element.from < $1.element.from : $0.offset < $1.offset }.map(\.element)
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].from : pageCount + 1
            out[i].to = max(out[i].from, next - 1)
        }
        return out
    }

    /// Lesezeichen und Seitenzahl einer PDF; nil, wenn sie nicht lesbar ist
    static func readPDF(_ url: URL) -> (entries: [(level: Int, title: String, page: Int)], pages: Int)? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else { return nil }
        var entries: [(level: Int, title: String, page: Int)] = []
        func walk(_ node: PDFOutline, _ level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page {
                    entries.append((level, child.label ?? "", doc.index(for: page) + 1))
                }
                walk(child, level + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, 0) }
        return (entries, doc.pageCount)
        #else
        return nil
        #endif
    }

    static func store(_ c: SQLiteConnection, fileID: String, chdate: SQLiteValue, pageCount: Int, sections: [Section], source: String) throws {
        try c.execute("""
            INSERT INTO file_outline(file_id, chdate, page_count, sections, source) VALUES (?,?,?,?,?)
            ON CONFLICT(file_id) DO UPDATE SET chdate=excluded.chdate, page_count=excluded.page_count,
            sections=excluded.sections, source=excluded.source
            """, [.text(fileID), chdate, .integer(Int64(pageCount)), .text(JSONValue.array(sections.map(\.json)).jsonString()), .text(source)])
    }

    /// `refresh`: Gliederung lokaler PDFs lesen, die noch keine haben oder seitdem geaendert wurden
    @discardableResult
    static func refresh(database: SQLiteDatabase, files: LocalFiles?) async throws -> Int {
        guard let files else { return 0 }
        let rows = try await database.withConnection { c in
            try c.query("""
                SELECT f.id, f.local_path, f.chdate FROM files f LEFT JOIN file_outline o ON o.file_id=f.id
                WHERE f.local_path IS NOT NULL AND f.deleted_at IS NULL AND lower(f.local_path) LIKE '%.pdf'
                AND (o.file_id IS NULL OR COALESCE(o.chdate,0) <> COALESCE(f.chdate,0))
                """)
        }
        var n = 0
        for r in rows {
            guard let id = r["id"]?.string, let path = r["local_path"]?.string, files.exists(stored: path), let url = files.url(stored: path),
                  let got = readPDF(url) else { continue }
            let secs = sections(entries: got.entries, pageCount: got.pages)
            try await database.transaction { c in
                try store(c, fileID: id, chdate: r["chdate"] ?? .null, pageCount: got.pages, sections: secs, source: secs.isEmpty ? "none" : "outline")
            }
            n += 1
        }
        return n
    }

    /// `load`: Seitenzahl und Abschnitte aus `file_outline`
    static func load(_ c: SQLiteConnection, fileID: SQLiteValue) throws -> (pageCount: Int, sections: [Section])? {
        guard let r = try c.queryOne("SELECT page_count, sections FROM file_outline WHERE file_id=?", [fileID]) else { return nil }
        let list = (try? PyJSON.parse(r["sections"]?.string ?? "[]"))?.json.array ?? []
        return (Int(r["page_count"]?.int64 ?? 0), list.compactMap(Section.init))
    }

    // MARK: Aufgaben

    /// "S. 25–29", eine Seite: "S. 17"
    static func pages(_ a: Int, _ b: Int) -> String { a == b ? "S. \(a)" : "S. \(a)–\(b)" }

    static func label(_ s: Section) -> String { s.number.isEmpty ? s.title : PyText.strip("\(s.number) \(s.title)") }

    static func count(_ s: String) -> Int { s.unicodeScalars.count }

    static func title(_ secs: [Section], _ a: Int, _ b: Int, piece: String = "") -> String {
        let t: String
        if secs.count == 1 {
            t = label(secs[0]) + piece
        } else if secs.count == 2 && count(label(secs[0])) + count(label(secs[1])) <= longTitle {
            t = "\(label(secs[0])), \(label(secs[1]))"
        } else {
            let last = secs[secs.count - 1]
            t = "\(label(secs[0])) bis \(last.number.isEmpty ? last.title : last.number)"
        }
        return "\(t) · \(pages(a, b))"
    }

    /// `est_total`: Dauer der ganzen Unterlage (Skript/Vorlesung mindestens `minPerPage` je Seite)
    static func estTotal(_ est: Int, pageCount: Int, kind: String) -> Int {
        (kind == "vorlesung" || kind == "skript") && pageCount > 0 ? max(est, pageCount * minPerPage) : est
    }

    /// `parts`: Seiten first...last in Aufgaben bis `budget` Minuten (ganze Abschnitte, nie ueber eine Kapitelgrenze;
    /// ein zu langer Abschnitt nach Seiten; ohne Abschnitte nach Seiten)
    static func parts(_ sections: [Section], pageCount: Int, total: Int, budget: Int, first: Int = 1, last: Int? = nil, name: String = "") -> [Part] {
        let last = min(last ?? pageCount, pageCount)
        guard pageCount > 0, first <= last else { return [] }
        func mins(_ a: Int, _ b: Int) -> Int { max(5, -BerlinClock.floorDiv(-(total * (b - a + 1)), pageCount)) }
        let span = total > 0 ? max(1, BerlinClock.floorDiv(budget * pageCount, total)) : last - first + 1
        var out: [Part] = []
        let secs = sections.filter { $0.to >= first && $0.from <= last }.map { s -> Section in
            var x = s
            x.from = max(s.from, first)
            x.to = min(s.to, last)
            return x
        }
        if secs.isEmpty {
            let n = -BerlinClock.floorDiv(-(last - first + 1), span)
            for k in 0..<n {
                let a = first + k * span, b = min(last, a + span - 1)
                out.append(Part(title: PyText.strip("\(name) · \(pages(a, b))", chars: " ·"), est: mins(a, b), from: a, to: b))
            }
            return out
        }
        var perChapter: [String: Int] = [:]
        for x in sections { perChapter[x.chapter, default: 0] += 1 }
        func close(_ cur: [Section]) {
            let ch = cur[0].chapter
            let whole = cur.count > 1 && !ch.isEmpty && cur.count == perChapter[ch, default: 0]
            let t = whole ? "\(ch) · \(pages(cur[0].from, cur[cur.count - 1].to))" : title(cur, cur[0].from, cur[cur.count - 1].to)
            out.append(Part(title: t, est: mins(cur[0].from, cur[cur.count - 1].to), from: cur[0].from, to: cur[cur.count - 1].to))
        }
        var cur: [Section] = []
        for s in secs {
            if !cur.isEmpty && (mins(cur[0].from, s.to) > budget || s.chapter != cur[0].chapter) {
                close(cur)
                cur = []
            }
            if mins(s.from, s.to) > budget {
                let n = -BerlinClock.floorDiv(-(s.to - s.from + 1), span)
                for k in 0..<n {
                    let a = s.from + k * span, b = min(s.to, a + span - 1)
                    out.append(Part(title: title([s], a, b, piece: n > 1 ? ", Teil \(k + 1)/\(n)" : ""), est: mins(a, b), from: a, to: b))
                }
                continue
            }
            cur.append(s)
        }
        if !cur.isEmpty { close(cur) }
        return out
    }

    // MARK: Lernschritte

    static func steps(_ kind: String, _ a: Int? = nil, _ b: Int? = nil) -> [String] {
        let whereText = a != nil && b != nil && a! != 0 && b! != 0 ? " auf \(pages(a!, b!))" : ""
        switch kind {
        case "vorlesung", "skript":
            return ["Überfliegen: Überschriften, Formeln und Bilder\(whereText) ansehen",
                    "Lesen und die wichtigsten Definitionen und Formeln herausschreiben",
                    "Ein Beispiel aus dem Abschnitt selbst nachrechnen",
                    "In zwei Sätzen erklären, worum es geht"]
        case "uebung":
            return ["Aufgabe lesen: Was ist gegeben, was ist gesucht?",
                    "Passende Formel oder den passenden Abschnitt im Skript suchen",
                    "Lösungsweg aufschreiben und rechnen",
                    "Ergebnis prüfen: Einheit, Vorzeichen, Größenordnung"]
        case "loesung":
            return ["Erst ohne Lösung versuchen",
                    "Mit der Lösung vergleichen und Fehler markieren",
                    "Die schwierigste Stelle noch einmal ohne Lösung rechnen"]
        default:
            return []
        }
    }

    /// `steps_json`: JSON wie Pythons json.dumps(..., ensure_ascii=False, separators=(",", ":")), sonst NULL
    static func stepsJSON(_ kind: String, _ a: Int? = nil, _ b: Int? = nil) -> SQLiteValue {
        let s = steps(kind, a, b)
        return s.isEmpty ? .null : .text(JSONValue.array(s.map(JSONValue.string)).jsonString())
    }
}

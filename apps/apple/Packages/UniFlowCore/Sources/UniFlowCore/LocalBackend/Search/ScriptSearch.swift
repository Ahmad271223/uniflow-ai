import Foundation

/// Skriptsuche und Seitentexte wie app/scriptsearch.py: zur Aufgabe auf einem Uebungsblatt die passende Stelle im
/// Vorlesungsskript finden, ohne KI. Die Seitentexte der PDFs stehen in `page_texts` (je Datei und Seite, mit der
/// Aenderungszeit der Datei); am PC liest sie pypdf, auf dem Geraet PDFKit (`LocalDocumentTools.pdfPageTexts`). Die
/// Suche ist BM25 ueber Woerter mit einfacher deutscher Wortstamm-Kuerzung, Ergebnisse unter einer Mindestguete
/// werden nicht gezeigt. Dazu die Seitentreffer der globalen Suche (`find_pages`).
///
/// Kein `await` in einer Transaktion: erst lesen, dann die PDF ausserhalb lesen, dann kurz schreiben.
/// Abweichung: Der Zwischenspeicher des Index (`_CACHE`) gilt hier auch fuer den Ablageort der Dateien; am PC fehlte
/// eine erst spaeter geladene Datei bis zum Neustart im Index.
public enum ScriptSearch {

    /// `STOP` (gleiche Woerter wie in app/scriptsearch.py)
    static let stop: Set<String> = Set("""
        aber alle allem allen aller alles also als am an andere anderen auch auf aus bei beide beiden beim bereits bestimmen
        bestimmt berechnen berechne bis bitte da dabei damit dann das dass dem den denen der deren des dessen die dies diese
        diesem diesen dieser dieses doch dort du durch ein eine einem einen einer eines einige er es etwa euch falls fuer für
        gegeben gegebene gegebenen gilt gibt habe haben hat hier ihr ihre im in ins ist ja je jede jedem jeden jeder jedes
        kann koennen können man mit muss nach neben nicht noch nun nur ob oder ohne sei seien sein seine sich sie sind so
        sodass soll sollen sowie ueber über um und uns unter vom von vor wann war was weil welche welchem welchen welcher
        wenn wer werden wie wieder wir wird wo zeigen zeige zu zum zur zwei drei vier fünf funf aufgabe aufgaben teilaufgabe
        blatt übung uebung übungsblatt hinweis lösung loesung punkte punkt folgende folgenden folgendes beweisen begründen
        geben gib skizzieren betrachten betrachte seite folie vorlesung kapitel definition satz beispiel bemerkung lemma relevant relevanter klausur klausurrelevant stoff tranche
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Endungen fuer den Wortstamm, in der Reihenfolge von Python (die erste passende gilt)
    static let suffixes = ["ungen", "ung", "en", "er", "es", "em", "e", "n", "s"]
    static let umlauts: [(base: Unicode.Scalar, umlaut: String)] = [("a", "ä"), ("o", "ö"), ("u", "ü"), ("A", "Ä"), ("O", "Ö"), ("U", "Ü")]
    private static let spacedDiaeresis: [PyRegex] = umlauts.map { PyRegex("\u{A8}\\s*" + String($0.base)) }
    private static let word = PyRegex("[a-zäöüß]{3,}")
    private static let spaces = PyRegex(#"\s+"#)
    private static let nonWord = PyRegex("[^\\p{L}\\p{N}_]+")         // \W+ wie Python (Gegenstueck zu PyRegex.word)

    // MARK: Text

    /// `normalize(text)`: pypdf liefert Umlaute oft zerlegt ("Unabh¨ angigkeit", "a" + U+0308)
    public static func normalize(_ text: String) -> String {
        var t = text
        for (i, u) in umlauts.enumerated() {
            t = spacedDiaeresis[i].sub(t, u.umlaut)
            t = replacing(t, [u.base, "\u{308}"], with: u.umlaut)
        }
        return t
    }

    /// `str.replace` nach Codepunkten (Swift vergleicht kanonisch aequivalent: "a" + U+0308 waere schon "ä")
    static func replacing(_ s: String, _ needle: [Unicode.Scalar], with replacement: String) -> String {
        let u = Array(s.unicodeScalars)
        guard u.count >= needle.count, !needle.isEmpty else { return s }
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            if i + needle.count <= u.count, Array(u[i..<(i + needle.count)]) == needle {
                out.append(contentsOf: replacement.unicodeScalars)
                i += needle.count
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(out)
    }

    /// `tokens(text)`: Woerter ab drei Buchstaben ohne Stoppwoerter, lange Woerter ohne Endung
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        for found in word.findAll(PyText.lower(normalize(text))) {
            if stop.contains(found) { continue }
            var w = Array(found.unicodeScalars)
            for suf in suffixes {
                let s = Array(suf.unicodeScalars)
                if w.count > 5, w.count >= s.count, Array(w.suffix(s.count)) == s {
                    w.removeLast(s.count)
                    break
                }
            }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: w)
            let stem = String(v)
            if w.count >= 3, !stop.contains(stem) { out.append(stem) }
        }
        return out
    }

    /// Erste `n` Codepunkte (`s[:n]`)
    static func prefix(_ s: String, _ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.prefix(max(0, n)))
        return String(v)
    }

    /// `_snippet(text, terms, width)`: Ausschnitt um den ersten Treffer; die Stelle wird im klein geschriebenen Text
    /// gesucht und im Original ausgeschnitten (wie Python, auch wenn die Kleinschreibung die Laenge aendert)
    static func snippet(_ text: String, terms: [String], width: Int = 170) -> String {
        let flat = Array(PyText.strip(spaces.sub(text, " ")).unicodeScalars)
        let low = Array(PyText.lower(String(String.UnicodeScalarView(flat))).unicodeScalars)
        var pos: Int?
        for t in terms {
            if let p = find(low, Array(t.unicodeScalars)) { pos = min(pos ?? p, p) }
        }
        let start = max(0, (pos ?? 0) - 50)
        let lo = min(start, flat.count), hi = min(start + width, flat.count)
        var v = String.UnicodeScalarView()
        v.append(contentsOf: flat[lo..<hi])
        return (start > 0 ? "…" : "") + String(v) + (start + width < flat.count ? "…" : "")
    }

    /// `hay.find(needle)` nach Codepunkten
    static func find(_ hay: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Int? {
        if needle.isEmpty { return 0 }
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }

    static func hasPDFSuffix(_ s: String) -> Bool {
        Array(PyText.lower(s).unicodeScalars.suffix(4)) == Array(".pdf".unicodeScalars)
    }

    // MARK: Seitentexte (page_texts)

    /// Was `page_texts(conn, file_id)` vorfindet
    enum StoredPages: Sendable {
        /// keine lokale PDF: keine Seitentexte
        case unavailable
        /// gespeichert und so alt wie die Datei
        case fresh([String])
        /// neu lesen (noch nicht gelesen oder die Datei hat eine neuere Aenderungszeit)
        case read(URL, chdate: SQLiteValue)
    }

    /// Erster Teil von `page_texts`: Datei mit lokaler PDF? Gespeicherte Texte noch gueltig?
    static func storedPages(_ c: SQLiteConnection, fileID: String, files: LocalFiles?) throws -> StoredPages {
        guard let f = try c.queryOne("SELECT local_path, chdate FROM files WHERE id=?", [.text(fileID)]),
              let path = f["local_path"]?.string, !path.isEmpty, let files, files.exists(stored: path), hasPDFSuffix(path),
              let url = files.url(stored: path) else { return .unavailable }
        let chdate = f["chdate"] ?? .null
        let rows = try c.query("SELECT page, text, chdate FROM page_texts WHERE file_id=? ORDER BY page", [.text(fileID)])
        if !rows.isEmpty, rows.allSatisfy({ ($0["chdate"]?.double ?? 0) == (chdate.double ?? 0) }) {
            return .fresh(rows.map { $0["text"]?.string ?? "" })
        }
        return .read(url, chdate: chdate)
    }

    /// Zweiter Teil von `page_texts`: neu gelesene Texte speichern (`chdate or 0`), nur wenn die Datei noch dieselbe
    /// Aenderungszeit hat (sonst kam inzwischen eine neue Fassung, deren Texte gehoeren nicht zu dieser)
    static func storePages(_ c: SQLiteConnection, fileID: String, pages: [String], chdate: SQLiteValue) throws {
        guard let now = try c.queryOne("SELECT chdate FROM files WHERE id=?", [.text(fileID)]),
              (now["chdate"]?.double ?? 0) == (chdate.double ?? 0) else { return }
        try c.execute("DELETE FROM page_texts WHERE file_id=?", [.text(fileID)])
        let stamp: SQLiteValue = LocalModules.truthy(chdate) ? chdate : .integer(0)
        for (i, t) in pages.enumerated() {
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)",
                          [.text(fileID), .integer(Int64(i + 1)), .text(t), stamp])
        }
    }

    /// `page_texts(conn, file_id)`: alle Seitentexte einer Datei, aus dem Zwischenspeicher oder neu gelesen (PDFKit in
    /// der App) und gespeichert. Leer ohne lokale PDF oder wenn sie sich nicht lesen laesst.
    public static func pageTexts(fileID: String, database: SQLiteDatabase, files: LocalFiles?) async throws -> [String] {
        let state = try await database.withConnection { try storedPages($0, fileID: fileID, files: files) }
        switch state {
        case .unavailable: return []
        case .fresh(let pages): return pages
        case .read(let url, let chdate):
            guard let pages = files?.tools.pdfPageTexts(url) else { return [] }
            try await database.transaction { try storePages($0, fileID: fileID, pages: pages, chdate: chdate) }
            return pages
        }
    }

    // MARK: Index je Modul (BM25)

    struct Doc: Sendable {
        let file: [String: JSONValue]
        let page: Int
        let tf: [String: Int]
        let length: Int
        let text: String
    }

    struct Index: Sendable {
        let docs: [Doc]
        let df: [String: Int]
        let avg: Double
        var n: Int { docs.count }
    }

    /// `_CACHE`: Index je Modul und Stand der Quellen (hoechstens etwa 20 Eintraege), je Datenbank (`LocalContext`)
    final class IndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Index] = [:]

        func get(_ key: String) -> Index? { lock.withLock { entries[key] } }

        func set(_ key: String, _ index: Index) {
            lock.withLock {
                if entries.count > 20 { entries.removeAll() }
                entries[key] = index
            }
        }
    }

    /// `_sources(conn, module_id, None)`: PDFs der Vorlesungen und Skripte eines Moduls (aktive Kurse, aelteste zuerst)
    static func sources(_ c: SQLiteConnection, moduleID: SQLiteValue) throws -> [[String: JSONValue]] {
        try LocalModules.fileRows(c, moduleID: moduleID).map(\.json).filter { f in
            hasPDFSuffix(f["name"]?.string ?? "") && ["vorlesung", "skript"].contains(f["doc_type"]?.string ?? "")
        }
    }

    /// `_index(conn, module_id)`: Seiten mit mindestens fuenf Woertern, Dokumenthaeufigkeit, mittlere Laenge
    static func index(moduleID: SQLiteValue, database: SQLiteDatabase, files: LocalFiles?, cache: IndexCache) async throws -> Index {
        let (srcs, stamps) = try await database.withConnection { c -> ([[String: JSONValue]], [String]) in
            let s = try sources(c, moduleID: moduleID)
            var stamps: [String] = []
            for f in s {
                let id = f["id"]?.string ?? ""
                let path = try c.scalar("SELECT local_path FROM files WHERE id=?", [.text(id)])?.string ?? ""
                stamps.append([id, f["chdate"]?.jsonString() ?? "0", path].joined(separator: "\u{1F}"))
            }
            return (s, stamps)
        }
        let key = (moduleID.json?.jsonString() ?? "null") + "\u{1E}" + stamps.sorted().joined(separator: "\u{1E}")
        if let hit = cache.get(key) { return hit }
        var docs: [Doc] = []
        for f in srcs {
            let pages = try await pageTexts(fileID: f["id"]?.string ?? "", database: database, files: files)
            for (i, text) in pages.enumerated() {
                let toks = tokens(text)
                if toks.count < 5 { continue }
                var tf: [String: Int] = [:]
                for t in toks { tf[t, default: 0] += 1 }
                docs.append(Doc(file: f, page: i + 1, tf: tf, length: toks.count, text: text))
            }
        }
        var df: [String: Int] = [:]
        for d in docs { for t in d.tf.keys { df[t, default: 0] += 1 } }
        let avg = Double(docs.reduce(0) { $0 + $1.length }) / Double(max(1, docs.count))
        let idx = Index(docs: docs, df: df, avg: avg)
        cache.set(key, idx)
        return idx
    }

    /// `search(conn, module_id, query, exclude, limit)`
    static func search(moduleID: SQLiteValue, query: String, exclude: String?, limit: Int = 3,
                       database: SQLiteDatabase, files: LocalFiles?, cache: IndexCache) async throws -> JSONValue {
        let q = tokens(query)
        if q.isEmpty { return ["terms": [], "results": []] }
        let idx = try await index(moduleID: moduleID, database: database, files: files, cache: cache)
        if idx.n == 0 { return ["terms": [], "results": [], "note": "keine Vorlesungs- oder Skriptseiten im Modul"] }
        // Counter(q): Haeufigkeit je Wort in der Reihenfolge des ersten Auftretens
        var order: [String] = []
        var qtf: [String: Int] = [:]
        for t in q {
            if qtf[t] == nil { order.append(t) }
            qtf[t, default: 0] += 1
        }
        let k1 = 1.4, b = 0.75
        var scored: [(score: Double, hit: [String], doc: Doc)] = []
        for d in idx.docs {
            if let exclude, d.file["id"]?.string == exclude { continue }
            var s = 0.0
            var hit: [String] = []
            for t in order {
                guard let tf = d.tf[t] else { continue }
                let qn = qtf[t] ?? 0
                let df = Double(idx.df[t] ?? 0)
                let idf = log(1 + (Double(idx.n) - df + 0.5) / (df + 0.5))
                s += idf * Double(tf) * (k1 + 1) / (Double(tf) + k1 * (1 - b + b * Double(d.length) / idx.avg)) * Double(min(qn, 2))
                hit.append(t)
            }
            if hit.count >= 2 { scored.append((s, hit, d)) }
        }
        // sort(key=-score) ist stabil: bei Gleichstand bleibt die Reihenfolge der Seiten
        let ranked = scored.enumerated().sorted { x, y in
            x.element.score != y.element.score ? x.element.score > y.element.score : x.offset < y.offset
        }.map(\.element)
        // Mindestguete: absolute Punktzahl und deutlicher Abstand zum Durchschnitt
        let mean = scored.isEmpty ? 0 : scored.reduce(0.0) { $0 + $1.score } / Double(scored.count)
        var results: [JSONValue] = []
        var seen = Set<String>()
        for (s, hit, d) in ranked {
            if s < 6 || (mean != 0 && s < mean * 1.6) { break }
            let key = prefix(nonWord.sub(normalize(d.text), ""), 120)    // Druckfassung derselben Folie nicht doppelt
            if !seen.insert(key).inserted { continue }
            let f = d.file
            let title = LocalModules.truthy(f["ai_title"]) ? f["ai_title"] : f["name"]
            // nach Haeufigkeit, bei Gleichstand in der Reihenfolge der Anfrage (stabil wie sorted in Python)
            let terms = hit.enumerated().sorted { x, y in
                let a = idx.df[x.element] ?? 0, c = idx.df[y.element] ?? 0
                return a != c ? a > c : x.offset < y.offset
            }.prefix(6).map { JSONValue.string($0.element) }
            results.append(.object([
                "file_id": f["id"] ?? .null, "title": title ?? .null, "name": f["name"] ?? .null, "label": f["sub_label"] ?? .null,
                "page": .number(Double(d.page)), "score": .number(QISParser.round2(s)), "terms": .array(Array(terms)),
                "snippet": .string(snippet(normalize(d.text), terms: hit)),
            ]))
            if results.count >= limit { break }
        }
        let terms = Set(q).sorted(by: PyText.less).prefix(20).map { JSONValue.string($0) }
        return ["terms": .array(Array(terms)), "results": .array(results)]
    }

    // MARK: Globale Suche

    /// `find_pages(conn, q, limit)`: Seiten, deren gespeicherter Text den (klein geschriebenen) Suchtext enthaelt;
    /// nur Texte der aktuellen Fassung, gelesen wird nichts neu
    static func findPages(_ c: SQLiteConnection, _ q: String, limit: Int = 10) throws -> [JSONValue] {
        let rows = try c.query("""
            SELECT p.file_id, p.page, p.text, f.name, a.title AS ai_title, c.subject, c.module_id
            FROM page_texts p JOIN files f ON f.id=p.file_id JOIN courses c ON c.id=f.course_id
            LEFT JOIN analysis a ON a.file_id=f.id
            WHERE COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0) AND lower(COALESCE(p.text, '')) LIKE ?
            ORDER BY f.chdate DESC, p.file_id, p.page LIMIT ?
            """, [.text("%" + q + "%"), .integer(Int64(limit))])
        return rows.map { r in
            var o: [String: JSONValue] = [:]
            for k in ["file_id", "page", "name", "ai_title", "subject", "module_id"] { o[k] = r[k]?.json ?? .null }
            o["snippet"] = .string(snippet(normalize(r["text"]?.string ?? ""), terms: [q]))
            return .object(o)
        }
    }
}

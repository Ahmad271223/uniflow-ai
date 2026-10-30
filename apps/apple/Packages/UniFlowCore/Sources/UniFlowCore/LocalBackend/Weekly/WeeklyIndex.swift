import Foundation

// Aufgabenindex wie app/weekly.py (`split_tasks`, `index_module`, `_bm25_refs`, `_link_solutions`, `task_scope`,
// `candidates`): Uebungen, Musterloesungen und Altklausuren auf Aufgabenebene, je Dateiversion zwischengespeichert,
// per Inhaltsabgleich (BM25) den Vorlesungsseiten zugeordnet.
extension Weekly {
    static let taskHead = try! NSRegularExpression(
        pattern: (#"(?im)^[ \t]*(?:\d{1,2}\.\s*)?(Aufgabe|Aufg\.|Exercise|Problem|Task)\s*(\d{1,2}(?:[.,]\d{1,2})?[a-z]?)\b[ \t]*[:.)\-–]?"#)
            .replacingOccurrences(of: #"\b"#, with: PyRegex.boundary).replacingOccurrences(of: #"\s"#, with: PyRegex.space),
        options: [.useUnixLineSeparators])
    static let points = PyRegex(#"\(?\s*(\d{1,2}(?:[.,]5)?)\s*(?:Punkte|Pkt\.?|P\.)\s*\)?"#, ignoreCase: true)
    static let term = PyRegex(#"(WiSe|WS|SoSe|SS|Winter|Sommer)\s*(?:semester)?\s*['_ ]?(\d{2,4})(?:\s*[/_-]\s*(\d{2,4}))?"#, ignoreCase: true)

    /// `round(x, 2)` wie Python (korrekt gerundete Dezimaldarstellung)
    static func round2(_ x: Double) -> Double { Double(String(format: "%.2f", x)) ?? x }

    /// `task_source(f)`
    static func taskSource(_ f: [String: JSONValue]) -> String {
        let lab = PyText.lower(f["sub_label"]?.string ?? "")
        let fl = PyText.lower("\(f["studip_folder"]?.string ?? "") \(f["name"]?.string ?? "")")
        if f["doc_type"]?.string == "loesung" || lab.contains("lösung") { return "loesung" }
        if f["doc_type"]?.string == "klausur" { return "altklausur" }
        if fl.contains("zusatz") || fl.contains("eigenarbeit") { return "zusatz" }
        if lab.contains("hörsaal") || lab.contains("hoersaal") { return "hoersaaluebung" }
        if lab.contains("gruppen") { return "gruppenuebung" }
        if lab.contains("tutorium") { return "tutorium" }
        return "uebungsblatt"
    }

    struct Task { var nr: String, pageFrom: Int, pageTo: Int, text: String }

    /// `split_tasks(pages)`: Aufgaben nach Ueberschriften "Aufgabe N", ohne solche je Seite
    static func splitTasks(_ pages: [String]) -> [Task] {
        let norm = pages.map { ScriptSearch.normalize($0) }
        var flat = "", starts: [Int] = []                    // Positionen in UTF-16 (nur Vergleiche, wie Python)
        for t in norm {
            starts.append(flat.utf16.count)
            flat += t + "\n"
        }
        func pageAt(_ pos: Int) -> Int {
            var p = 1
            for (i, s) in starts.enumerated() where s <= pos { p = i + 1 }
            return p
        }
        let ns = flat as NSString
        let found: [(Int, String)] = taskHead.matches(in: flat, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: 2)
            guard r.location != NSNotFound else { return nil }
            return (m.range.location, ns.substring(with: r).replacingOccurrences(of: ",", with: "."))
        }
        var tasks: [Task] = []
        if !found.isEmpty {
            for (k, (pos, nr)) in found.enumerated() {
                let end = k + 1 < found.count ? found[k + 1].0 : ns.length
                let text = PyText.strip(ns.substring(with: NSRange(location: pos, length: end - pos)))
                if len(text) < 25 { continue }
                tasks.append(Task(nr: nr, pageFrom: pageAt(pos), pageTo: pageAt(max(pos, end - 1)), text: text))
            }
            // gleiche Nummer mehrfach (z. B. Inhaltsverzeichnis): laengste Fundstelle behalten
            var order: [String] = [], seen: [String: Task] = [:]
            for t in tasks {
                if let s = seen[t.nr] {
                    if len(t.text) > len(s.text) { seen[t.nr] = t }
                } else {
                    order.append(t.nr); seen[t.nr] = t
                }
            }
            tasks = order.map { seen[$0]! }.enumerated().sorted { a, b in
                if a.element.pageFrom != b.element.pageFrom { return a.element.pageFrom < b.element.pageFrom }
                let x = nrKey(a.element.nr), y = nrKey(b.element.nr)
                if x != y { return x < y }
                return a.offset < b.offset
            }.map(\.element)
        }
        if tasks.isEmpty {
            for (i, t) in pages.enumerated() {
                let s = PyText.strip(ScriptSearch.normalize(t))
                if len(s) >= 40 { tasks.append(Task(nr: "S\(i + 1)", pageFrom: i + 1, pageTo: i + 1, text: s)) }
            }
        }
        return tasks
    }

    struct NrKey: Comparable {
        let a: Int, b: Int, c: String
        static func < (l: NrKey, r: NrKey) -> Bool {
            (l.a, l.b) != (r.a, r.b) ? (l.a, l.b) < (r.a, r.b) : l.c.unicodeScalars.lexicographicallyPrecedes(r.c.unicodeScalars)
        }
    }
    static let nrPattern = PyRegex(#"(\d+)(?:\.(\d+))?([a-z]?)"#)

    /// `_nr_key(nr)`
    static func nrKey(_ nr: String) -> NrKey {
        guard let m = nrPattern.match(nr), let a = m.group(1).flatMap({ Int($0) }) else { return NrKey(a: 999, b: 0, c: nr) }
        return NrKey(a: a, b: m.group(2).flatMap { Int($0) } ?? 0, c: m.group(3) ?? "")
    }

    static let solExt = PyRegex(#"\.[a-z0-9]+$"#)
    static let solWords = PyRegex(#"musterl(ö|oe)sung(en)?|l(ö|oe)sung(en)?|l(ö|oe)s\b|lsg|solutions?|mit|und|_|-|\s|\(|\)"#)

    /// `_solution_key(name)`
    static func solutionKey(_ name: String) -> String { solWords.sub(solExt.sub(PyText.lower(name))) }

    /// `_difficulty(text, points, source)`
    static func difficulty(_ text: String, _ points: Double?, _ source: String) -> Int {
        let n = len(text)
        let d = 2 + (n > 700 ? 1 : 0) + (n > 1600 ? 1 : 0) + (source == "altklausur" ? 1 : 0) + ((points ?? 0) >= 10 ? 1 : 0)
        return max(1, min(5, d))
    }

    static func isPDF(_ f: [String: JSONValue]) -> Bool { PyText.lower(f["name"]?.string ?? "").hasSuffix(".pdf") }

    /// `_lecture_hash(conn, module_id)`
    static func lectureHash(_ c: SQLiteConnection, _ moduleID: Int) throws -> String {
        let files = try LocalModules.fileRows(c, moduleID: .integer(Int64(moduleID))).map(\.json)
            .filter { lectureTypes.contains($0["doc_type"]?.string ?? "") && isPDF($0) }
        let pairs = files.map { f -> (String, PyJSON) in
            let ch = f["chdate"].flatMap { LocalModules.truthy(v($0)) ? PyJSON($0) : nil } ?? .int("0")
            return (f["id"]?.string ?? "", ch)
        }.sorted { $0.0 != $1.0 ? $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) : $0.1.dumps < $1.1.dumps }
        return String(h(.array(pairs.map { .array([.string($0.0), $0.1]) })).prefix(8))
    }

    struct Ref { var fileID: String, page: Int, score: Double, viaTwin = false
        var py: PyJSON { .object([.init("file_id", .string(fileID)), .init("page", Weekly.i(page)), .init("score", .float(score))]) }
    }

    /// `_bm25_refs(conn, module_id, text)`: alle stark passenden Vorlesungsseiten, dazu bis zu `limit` schwache
    static func bm25Refs(_ index: ScriptSearch.Index, _ text: String, limit: Int = 8) -> [Ref] {
        let q = ScriptSearch.tokens(text)
        guard !q.isEmpty, index.n > 0 else { return [] }
        var qtf: [String: Int] = [:], order: [String] = []
        for t in q {
            if qtf[t] == nil { order.append(t) }
            qtf[t, default: 0] += 1
        }
        let k1 = 1.4, b = 0.75
        var scored: [(Double, String, Int)] = []
        for d in index.docs {
            var s = 0.0, hits = 0
            for t in order {
                guard let tf = d.tf[t], tf > 0, let df = index.df[t] else { continue }
                let idf = log(1 + (Double(index.n) - Double(df) + 0.5) / (Double(df) + 0.5))
                let tfd = Double(tf)
                s += idf * tfd * (k1 + 1) / (tfd + k1 * (1 - b + b * Double(d.length) / index.avg)) * Double(min(qtf[t]!, 2))
                hits += 1
            }
            if hits >= 2 { scored.append((s, d.file["id"]?.string ?? "", d.page)) }
        }
        scored = scored.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }.map(\.element)
        guard let best = scored.first?.0, best >= minRefScore else { return [] }
        let strongRefs = scored.filter { $0.0 >= strong * best }
        let weak = scored.filter { $0.0 < strong * best }.prefix(limit)
        return (strongRefs + weak).map { Ref(fileID: $0.1, page: $0.2, score: round2($0.0)) }
    }

    /// `index_module(conn, module_id, now)`: nur Dateien, deren Version (oder der Vorlesungsstand) sich geaendert hat
    @discardableResult
    static func indexModule(_ c: SQLiteConnection, _ moduleID: Int, index: ScriptSearch.Index, now: Int) throws -> (indexed: Int, unchanged: Int) {
        let lec = try lectureHash(c, moduleID)
        let files = try LocalModules.fileRows(c, moduleID: .integer(Int64(moduleID))).map(\.json)
            .filter { taskTypes.contains($0["doc_type"]?.string ?? "") && isPDF($0) }
        var done = 0, skipped = 0
        for f in files {
            let fid = f["id"]?.string ?? ""
            let ver = "\(try docVersion(c, fid)):\(lec)"
            if try c.scalar("SELECT version FROM doc_index WHERE file_id=?", [.text(fid)])?.string == ver { skipped += 1; continue }
            let pages = try pageTexts(c, fid)
            let src = taskSource(f)
            let tm = term.search("\(f["studip_folder"]?.string ?? "") \(f["name"]?.string ?? "")")
            var old: [String: [String: JSONValue]] = [:]
            for r in try c.rows("SELECT nr, content_hash, indexed_at FROM task_index WHERE file_id=?", [.text(fid)]) { old[r["nr"]?.string ?? ""] = r }
            try c.execute("DELETE FROM task_index WHERE file_id=?", [.text(fid)])
            let tasks = splitTasks(pages)
            let title = f["ai_title"].flatMap { LocalModules.truthy(v($0)) ? $0.string : nil } ?? f["name"]?.string ?? ""
            for t in tasks {
                let head = String(t.text.unicodeScalars.prefix(300))
                let pts = points.search(head).flatMap { $0.group(1) }.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
                let ch = h(.string(norm(t.text)))
                let prev = old[t.nr]
                let first = prev?["content_hash"]?.string == ch ? prev?["indexed_at"]?.string : nil
                let label = "\(sourceText[src] ?? src) · \(title) · " + (t.nr.hasPrefix("S") ? "Seite \(t.nr.dropFirst())" : "Aufgabe \(t.nr)")
                try c.execute("""
                    INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, points, difficulty,
                    exam_term, lecture_refs, content_hash, indexed_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(fid), .text(ver), .integer(Int64(moduleID)), .text(src), .text(t.nr), .text(label),
                          .integer(Int64(t.pageFrom)), .integer(Int64(t.pageTo)), .text(String(t.text.unicodeScalars.prefix(6000))),
                          pts.map { .real($0) } ?? .null, .integer(Int64(difficulty(t.text, pts, src))),
                          tm.flatMap { $0.group(0) }.map { .text($0) } ?? .null,
                          .text(PyJSON.array(bm25Refs(index, t.text).map(\.py)).dumps), .text(ch), .text(first ?? iso(now))])
            }
            try c.execute("INSERT OR REPLACE INTO doc_index(file_id, version, module_id, role, tasks, indexed_at) VALUES (?,?,?,?,?,?)",
                          [.text(fid), .text(ver), .integer(Int64(moduleID)), .text(src), .integer(Int64(tasks.count)), .text(iso(now))])
            done += 1
        }
        try linkSolutions(c, moduleID)
        return (done, skipped)
    }

    /// `_link_solutions(conn, module_id)`: Musterloesung je Aufgabe ueber den Dateinamen und die Nummer
    static func linkSolutions(_ c: SQLiteConnection, _ moduleID: Int) throws {
        let mid = SQLiteValue.integer(Int64(moduleID))
        let sols = try c.rows("""
            SELECT t.file_id, t.nr, t.text, f.name FROM task_index t JOIN files f ON f.id=t.file_id
            WHERE t.module_id=? AND t.source='loesung'
            """, [mid])
        if sols.isEmpty { return }
        var keys: [String] = [], byKey: [String: [String: [String: JSONValue]]] = [:]
        for s in sols {
            let k = solutionKey(s["name"]?.string ?? "")
            if byKey[k] == nil { keys.append(k) }
            byKey[k, default: [:]][s["nr"]?.string ?? ""] = s
        }
        for t in try c.rows("""
            SELECT t.id, t.nr, f.name FROM task_index t JOIN files f ON f.id=t.file_id
            WHERE t.module_id=? AND t.source!='loesung'
            """, [mid]) {
            let k = solutionKey(t["name"]?.string ?? "")
            var cand = byKey[k]
            if cand == nil || cand!.isEmpty {
                cand = keys.first { kk in !kk.isEmpty && !k.isEmpty && (k.contains(kk) || kk.contains(k)) && min(len(kk), len(k)) >= 4 }.flatMap { byKey[$0] }
            }
            let s = cand?[t["nr"]?.string ?? ""]
            try c.execute("UPDATE task_index SET solution_file_id=?, solution_text=? WHERE id=?",
                          [s.map { v($0["file_id"]) } ?? .null, s.map { .text(String(($0["text"]?.string ?? "").unicodeScalars.prefix(5000))) } ?? .null,
                           v(t["id"])])
        }
    }

    struct Scope { var ok: Bool, reason: String, new: Bool, refs: [Ref] }

    static func refs(of task: [String: JSONValue]) -> [Ref] {
        let raw: JSONValue? = task["lecture_refs"]?.string.flatMap { try? JSONValue.parse($0) } ?? task["lecture_refs"]
        return (raw?.array ?? []).map { Ref(fileID: $0["file_id"]?.string ?? "", page: $0["page"]?.int ?? 0, score: $0["score"]?.double ?? 0) }
    }

    /// `task_scope(task, cov_pages, new_pages, twin)`: loesbar, wenn alle stark passenden Vorlesungsseiten behandelt sind
    static func taskScope(_ task: [String: JSONValue], covered: Set<PageKey>, newPages: Set<PageKey>, twin: ((PageKey) -> PageKey?)?) -> Scope {
        let rs = refs(of: task)
        guard let best = rs.first?.score else { return Scope(ok: false, reason: "kein sicherer Bezug zu Vorlesungsseiten", new: false, refs: []) }
        var strongRefs: [Ref] = [], outside: [Ref] = []
        for r in rs {
            if r.score < strong * best { continue }
            let key = PageKey(file: r.fileID, page: r.page)
            if !covered.contains(key) {
                guard let tw = twin?(key) else { outside.append(r); continue }
                strongRefs.append(Ref(fileID: tw.file, page: tw.page, score: r.score, viaTwin: true))
                continue
            }
            strongRefs.append(r)
        }
        if !outside.isEmpty {
            return Scope(ok: false, reason: "braucht noch nicht behandelte Seite(n) \(outside.prefix(4).map { String($0.page) }.joined(separator: ", "))",
                         new: false, refs: [])
        }
        return Scope(ok: true, reason: "", new: strongRefs.contains { newPages.contains(PageKey(file: $0.fileID, page: $0.page)) }, refs: strongRefs)
    }

    /// `_twin_finder`: nahezu identische Seiten (Token-Jaccard >= 0,8), z. B. Folien aus einem anderen Semester
    static func twinFinder(_ index: ScriptSearch.Index, covered: Set<PageKey>) -> (PageKey) -> PageKey? {
        var keys: [PageKey] = [], byKey: [PageKey: Set<String>] = [:]
        for d in index.docs {
            let k = PageKey(file: d.file["id"]?.string ?? "", page: d.page)
            if byKey[k] == nil { keys.append(k) }
            byKey[k] = Set(d.tf.keys)
        }
        let cov = keys.filter { covered.contains($0) && byKey[$0]!.count >= 8 }.map { ($0, byKey[$0]!) }
        var memo: [PageKey: PageKey?] = [:]
        return { k in
            if let m = memo[k] { return m }
            var hit: PageKey?
            if let toks = byKey[k], toks.count >= 8 {
                hit = cov.first { $0.0.file != k.file && Double(toks.intersection($0.1).count) / Double(toks.union($0.1).count) >= 0.8 }?.0
            }
            memo[k] = hit
            return hit
        }
    }

    struct Candidate { var row: [String: JSONValue], isNewWeek: Bool, refs: [Ref]
        var id: Int { row["id"]?.int ?? 0 }
        var source: String { row["source"]?.string ?? "" }
    }

    /// `candidates(conn, module_id, cov, new_pages)`
    static func candidates(_ c: SQLiteConnection, _ moduleID: Int, index: ScriptSearch.Index, covered: Set<PageKey>,
                           newPages: Set<PageKey>) throws -> (ok: [Candidate], excluded: [PyJSON]) {
        let rows = try c.rows("SELECT * FROM task_index WHERE module_id=? AND source!='loesung' ORDER BY source, file_id, page_from",
                              [.integer(Int64(moduleID))])
        let twin = twinFinder(index, covered: covered)
        var ok: [Candidate] = [], excluded: [PyJSON] = []
        for t in rows {
            let s = taskScope(t, covered: covered, newPages: newPages, twin: twin)
            if s.ok {
                ok.append(Candidate(row: t, isNewWeek: s.new, refs: s.refs))
            } else {
                excluded.append(.object([.init("id", PyJSON(t["id"] ?? .null)), .init("label", PyJSON(t["label"] ?? .null)),
                                         .init("reason", .string(s.reason))]))
            }
        }
        return (ok, excluded)
    }
}

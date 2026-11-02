import Foundation

// Lernstoff aus Stud.IP auf dem Geraet (2.11.2026), dieselben Schritte wie app/studip_texts.py: Courseware-Aufgaben
// mit Abgabefrist (in `deadlines`, source 'studip', module 'courseware'), Courseware-Seiten, Wiki-Seiten und
// Forum-Themen als Text in EINER Tabelle `studip_texts` (Art courseware | wiki | forum). Nur lesend: ausschliesslich
// GET ueber den `StudIPClient` (dieselben Pausen), nichts wird markiert oder abonniert. Forenbeitraege ohne
// Autorennamen: Beziehungen zu Personen werden nie gelesen, Zitate und @Erwaehnungen fallen weg.
//
// Last: hoechstens `maxRequests` Anfragen je Abgleich fuer diese Quellen, je Kurs ein gerechter Anteil; nur die
// aktuellen Kurse (der Aufrufer gibt sie). Aenderungserkennung ueber chdate (spaetestens nach `recheckDays` doch neu).
// Funktion nicht vorhanden (HTTP 400/403/404/405): je Kurs gemerkt, ohne jeden Erfolg aber mindestens zweimal an der
// Hochschule; erst nach `recheckDays` wieder gefragt (`studip_text_state`).
//
// ANNAHMEN zu Pfaden und Feldern (an der LUH erst mit echtem Konto pruefbar) stehen in app/studip_texts.py; der
// Vertrag packages/shared-contracts/fixtures/studip-texts/texte.json (tools/gen-studip-texts-fixture.py) prueft, dass
// beide gleich fragen, lesen und speichern.

public enum StudIPTexts {
    public static let kinds = ["courseware", "wiki", "forum"]
    public static let kindLabels = ["courseware": "Courseware", "wiki": "Wiki", "forum": "Forum"]
    static let features = ["tasks", "courseware", "wiki", "forum"]
    public static let maxRequests = 200
    static let minCourseRequests = 12
    static let maxPages = 40
    static let maxDepth = 4
    static let maxWiki = 30
    static let maxForum = 20
    static let maxText = 8000
    static let recheckDays = 14
    static let absentStatus: Set<Int> = [400, 403, 404, 405]
    static let api = "jsonapi.php/v1/"

    static let tablesSQL = """
        CREATE TABLE IF NOT EXISTS studip_texts (
            id TEXT PRIMARY KEY,
            course_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            url TEXT,
            changed TEXT,
            fetched_at TEXT
        );
        CREATE INDEX IF NOT EXISTS ix_studip_texts_course ON studip_texts(course_id, kind);
        CREATE TABLE IF NOT EXISTS studip_text_state (key TEXT PRIMARY KEY, value TEXT);
        """

    static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tablesSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_texts'") != nil
    }

    // MARK: - Ergebnis eines Abrufs

    public struct TextRow: Sendable, Equatable {
        public var id, kind, title, text, url, changed: String
    }

    public struct Deadline: Sendable, Equatable {
        public var id, courseID, title, fullTitle, dueAt, url: String
    }

    public struct CourseResult: Sendable {
        public var courseID: String
        public var rows: [TextRow] = []
        /// je Art: in Stud.IP gesehene Eintraege (auch unveraenderte); was fehlt, faellt bei vollstaendigem Lesen weg
        public var seen: [String: [String]] = ["courseware": [], "wiki": [], "forum": []]
        public var complete: [String: Bool] = ["courseware": false, "wiki": false, "forum": false]
        /// nil = Aufgaben nicht gelesen (Bestand bleibt)
        public var deadlines: [Deadline]?
        public var deadlinesComplete = false

        mutating func unsee(_ kind: String, _ id: String) {
            if let i = seen[kind]?.firstIndex(of: id) { seen[kind]?.remove(at: i) }
        }
    }

    public struct Download: Sendable {
        public var courses: [CourseResult] = []
        public var stateSet: [String: String] = [:]
        public var stateDel: [String] = []
        /// Anfragen aufgebraucht oder Netz weg: Rest nicht gefragt
        public var stopped = false
        public var requests = 0
    }

    public struct StoreResult: Sendable, Equatable {
        public var texts = 0
        public var deadlines = 0

        public init(texts: Int = 0, deadlines: Int = 0) {
            self.texts = texts
            self.deadlines = deadlines
        }

        /// Teile fuer die Zusammenfassung des Abgleichs (`summary` in Python)
        public var summary: [String] {
            var parts: [String] = []
            if texts > 0 { parts.append("\(texts) Lerntexte aus Stud.IP") }
            if deadlines > 0 { parts.append("\(deadlines) Courseware-\(deadlines == 1 ? "Frist" : "Fristen")") }
            return parts
        }
    }

    // MARK: - Lesen der Antworten

    static func attrs(_ x: JSONValue?) -> [String: JSONValue] { x?["attributes"]?.object ?? [:] }

    static func relID(_ x: JSONValue?, _ name: String) -> String? { x?["relationships"]?[name]?["data"]?["id"]?.string }

    static func text(_ v: JSONValue?) -> String { v?.string ?? "" }

    static func first(_ a: [String: JSONValue], _ keys: String...) -> String {
        for k in keys { if let s = a[k]?.string, !PyText.strip(s).isEmpty { return s } }
        return ""
    }

    static func changed(_ a: [String: JSONValue]) -> String {
        for k in ["chdate", "mkdate"] {
            switch a[k] {
            case .string(let s)? where !s.isEmpty: return s
            case .number(let d)? where d.isFinite: return String(Int(d.rounded(.towardZero)))
            default: continue
            }
        }
        return ""
    }

    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(true)?: return true
        case .number(let d)?: return d == 1
        case .string(let s)?: return ["1", "true", "yes"].contains(PyText.lower(s))
        default: return false
        }
    }

    private static let spacesTabs = PyRegex(#"[ \t]+"#)
    private static let newlines = PyRegex(#"\s*\n\s*"#)
    private static let anySpace = PyRegex(#"\s+"#)
    private static let linkWithText = PyRegex(#"\[\[[^\]|]*\|([^\]]*)\]\]"#)
    private static let link = PyRegex(#"\[\[([^\]]*)\]\]"#)
    private static let headingMark = PyRegex(#"(?m)^!{1,4}\s*"#)
    private static let htmlTag = PyRegex(#"<[a-zA-Z/][^>]*>"#)
    private static let quoteBlock = PyRegex(#"(?is)\[quote[^\]]*\].*?\[/quote\]"#)
    private static let blockquote = PyRegex(#"(?is)<blockquote\b.*?</blockquote>"#)
    private static let mention = PyRegex(#"(?<![\w@])@[\w.\-]+"#)
    private static let isoPrefix = PyRegex(#"^\d{4}-\d{2}-\d{2}"#)
    private static let unixDigits = PyRegex(#"^\d{9,11}$"#)

    /// Leerraum wie html_to_text
    static func squash(_ t: String) -> String {
        let s = spacesTabs.sub(t.replacingOccurrences(of: "\u{A0}", with: " "), " ")
        return PyText.strip(newlines.sub(s, "\n"))
    }

    /// `markup_to_text`: Stud.IP-Formatierung grob als Text
    static func markupToText(_ t: String) -> String {
        var s = linkWithText.subGroup(t, 1)
        s = link.subGroup(s, 1)
        s = headingMark.sub(s, "")
        for mark in ["**", "%%", "__", "{{", "}}"] { s = s.replacingOccurrences(of: mark, with: "") }
        return squash(s)
    }

    static func richToText(_ t: String) -> String {
        htmlTag.found(in: t) ? Announcements.htmlToText(t) : markupToText(t)
    }

    /// `anonymize`: Zitate (mit Namen) und @Erwaehnungen fallen weg
    static func anonymize(_ t: String) -> String {
        mention.sub(blockquote.sub(quoteBlock.sub(t, " "), " "), "@…")
    }

    /// `cut(t, n)`: nach `n` Zeichen am Wort kuerzen
    static func cut(_ t: String, _ n: Int = maxText) -> String {
        let s = PyText.strip(t)
        let u = Array(s.unicodeScalars)
        if u.count <= n { return s }
        let head = Array(u[0..<n])
        let i = head.lastIndex(of: " ") ?? 0
        return String(String.UnicodeScalarView(i > 0 ? Array(head[0..<i]) : head)) + " …"
    }

    static func payload(_ a: [String: JSONValue]) -> [String: JSONValue] {
        if let s = a["payload"]?.string {
            return (try? JSONValue.parse(Data(s.utf8)))?.object ?? [:]
        }
        return a["payload"]?.object ?? [:]
    }

    /// `block_text`: Text-, Ueberschrift-, Code- und Formelbloecke; Dateibloecke nur als Verweis; sonst nichts
    static func blockText(_ block: JSONValue) -> String {
        let a = attrs(block)
        let kind = PyText.lower(text(a["block-type"]))
        let p = payload(a)
        switch kind {
        case "text", "key-point", "typewriter":
            return Announcements.htmlToText(text(p["text"]))
        case "headline":
            return squash([text(p["title"]), text(p["subtitle"])].filter { !PyText.strip($0).isEmpty }.joined(separator: "\n"))
        case "code":
            return PyText.strip(text(p["content"]))
        case "katex", "math", "formula":
            return PyText.strip(first(p, "formula", "content", "text"))
        case "document", "download", "folder":
            let name = squash(first(p, "title", "name", "file_name", "filename"))
            return "[\(kind == "folder" ? "Ordner" : "Datei"): \(name.isEmpty ? "ohne Titel" : name)]"
        default:
            return ""
        }
    }

    /// `berlin_local`: ISO-Zeitpunkt -> Ortszeit Berlin "YYYY-MM-DDTHH:MM"; reines Datum -> 23:59; sonst nil
    static func berlinLocal(_ v: JSONValue?) -> String? {
        guard let raw = v?.string else { return nil }
        let s = PyText.strip(raw)
        guard isoPrefix.found(in: s) else { return nil }
        if s.unicodeScalars.count == 10 { return BerlinClock.parseISODate(s) != nil ? s + "T23:59" : nil }
        guard let t = StudIPTimestamp.parse(s), let seconds = t.seconds else { return nil }
        if t.offset == nil {
            return BerlinClock.isoDate(t.day) + "T" + BerlinClock.pad(seconds / 3600, 2) + ":" + BerlinClock.pad(seconds / 60 % 60, 2)
        }
        return PyText.slice(BerlinClock.localISO(utc: t.utcSeconds), 0, 16)
    }

    static func base(_ b: String) -> String {
        var s = b
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func tasksURL(_ b: String, _ cid: String) -> String { "\(base(b))/dispatch.php/course/courseware/tasks?cid=\(cid)" }
    static func coursewareURL(_ b: String, _ cid: String, _ eid: String) -> String {
        "\(base(b))/dispatch.php/course/courseware/?cid=\(cid)#/structural_element/\(eid)"
    }
    static func wikiURL(_ b: String, _ cid: String, _ pid: String) -> String { "\(base(b))/dispatch.php/course/wiki/page/\(pid)?cid=\(cid)" }
    static func forumURL(_ b: String, _ cid: String, _ eid: String) -> String {
        "\(base(b))/plugins.php/coreforum/index/index/\(eid)?cid=\(cid)#\(eid)"
    }

    /// `task_deadline`: Frist einer eigenen Courseware-Aufgabe; abgegebene fallen weg
    static func taskDeadline(_ task: JSONValue, included: [String: JSONValue], courseID: String, base b: String) -> Deadline? {
        let a = attrs(task)
        guard let tid = task["id"]?.string, !truthy(a["submitted"]) else { return nil }
        let group = relID(task, "task-group").flatMap { included["courseware-task-groups|" + $0] }
        let element = relID(task, "structural-element").flatMap { included["courseware-structural-elements|" + $0] }
        let granted = PyText.lower(text(a["renewal"])) == "granted" || PyText.lower(text(a["renewal-state"])) == "granted"
        guard let due = (granted ? berlinLocal(a["renewal-date"]) : nil) ?? berlinLocal(a["submission-date"]) ?? berlinLocal(attrs(group)["end-date"])
        else { return nil }
        var title = squash(first(attrs(group), "title"))
        if title.isEmpty { title = squash(first(attrs(element), "title")) }
        if title.isEmpty { title = "Courseware-Aufgabe" }
        return Deadline(id: "sp-cw-\(tid)", courseID: courseID, title: title, fullTitle: "\(title) · Stud.IP Courseware", dueAt: due,
                        url: tasksURL(b, courseID))
    }

    /// `group_deadline`: Ersatzweg ueber die Aufgabengruppen des Kurses
    static func groupDeadline(_ group: JSONValue, courseID: String, base b: String) -> Deadline? {
        let a = attrs(group)
        guard let gid = group["id"]?.string, let due = berlinLocal(a["end-date"]) ?? berlinLocal(a["submission-date"]) else { return nil }
        let t = squash(first(a, "title"))
        let title = t.isEmpty ? "Courseware-Aufgabe" : t
        return Deadline(id: "sp-cwg-\(gid)", courseID: courseID, title: title, fullTitle: "\(title) · Stud.IP Courseware", dueAt: due,
                        url: tasksURL(b, courseID))
    }

    // MARK: - Abruf

    /// Bekannter Stand: Text-ID -> (changed, fetched_at)
    public typealias Known = [String: (changed: String, fetchedAt: String)]

    /// `load`: Stand vor dem Abruf (bekannte Texte, Merker)
    public static func load(_ c: SQLiteConnection) throws -> (known: Known, state: [String: String]) {
        guard try hasTables(c) else { return ([:], [:]) }
        var known: Known = [:]
        for r in try c.query("SELECT id, changed, fetched_at FROM studip_texts") {
            if let id = r["id"]?.string { known[id] = (r["changed"]?.string ?? "", r["fetched_at"]?.string ?? "") }
        }
        var state: [String: String] = [:]
        for r in try c.query("SELECT key, value FROM studip_text_state") {
            if let k = r["key"]?.string { state[k] = r["value"]?.string ?? "" }
        }
        return (known, state)
    }

    enum Failure: Error { case absent, failed, stop, stopAll }

    static func day(_ s: String) -> Int? { BerlinClock.parseISODate(PyText.slice(s, 0, 10)) }

    /// Abruf aller Kurse wie `fetch` in Python. Wirft nur bei abgelaufener Sitzung und Abbruch; alles andere steht im
    /// Ergebnis. `today`: "YYYY-MM-DD".
    public static func fetch(client: StudIPClient, courses: [StudIPCourse], known: Known, state: [String: String], today: String,
                             base: String, budget: Int = maxRequests) async throws -> Download {
        let f = Fetcher(client: client, known: known, state: state, today: BerlinClock.parseISODate(today) ?? 0, base: base, budget: budget)
        f.start = await client.requestCount
        return try await f.run(courses)
    }

    /// Ein Abruf (nur innerhalb von `fetch`, nacheinander)
    final class Fetcher {
        let client: StudIPClient
        let known: Known
        var state: [String: String]
        let today: Int
        let base: String
        let budget: Int
        var start = 0
        var limit: Int
        var out = Download()
        var res = CourseResult(courseID: "")

        init(client: StudIPClient, known: Known, state: [String: String], today: Int, base: String, budget: Int) {
            self.client = client
            self.known = known
            self.state = state
            self.today = today
            self.base = base
            self.budget = budget
            self.limit = budget
        }

        func used() async -> Int { await client.requestCount - start }

        private func fetchJSON(_ path: String) async throws -> JSONValue {
            do {
                return try await client.json(path)
            } catch let e as StudIPError {
                switch e {
                case .sessionExpired: throw e
                case .requestLimit: throw Failure.stopAll
                case .http(let status, _) where absentStatus.contains(status): throw Failure.absent
                default: throw Failure.failed
                }
            } catch let e as URLError {
                throw StudIPScheduleStore.stopsFetch(e) ? Failure.stopAll : Failure.failed
            }
        }

        /// `Api.list`: alle Seiten; die Grenze gilt vor jeder Liste; "nicht vorhanden" nur auf der ersten Seite
        func list(_ path: String) async throws -> (data: [JSONValue], included: [JSONValue]) {
            if await used() >= limit { throw Failure.stop }
            var data: [JSONValue] = [], included: [JSONValue] = []
            var next: String? = path
            var seen = Set<String>()
            while let n = next, !seen.contains(n) {
                seen.insert(n)
                let body: JSONValue
                do {
                    body = try await fetchJSON(n)
                } catch Failure.absent where n != path {
                    throw Failure.failed
                }
                guard let page = body["data"]?.array else { throw Failure.failed }
                data += page
                included += body["included"]?.array ?? []
                next = body["links"]?["next"]?.string
            }
            return (data, included)
        }

        func one(_ path: String) async throws -> JSONValue {
            if await used() >= limit { throw Failure.stop }
            guard let d = try await fetchJSON(path)["data"], d.object != nil else { throw Failure.failed }
            return d
        }

        func fresh(_ id: String, _ changed: String) -> Bool {
            guard let k = known[id], !changed.isEmpty, k.changed == changed, let d = day(k.fetchedAt) else { return false }
            return today - d < recheckDays
        }

        func absent(_ key: String) -> Bool {
            guard let v = state[key], let d = day(v) else { return false }
            return today < d
        }

        func run(_ courses: [StudIPCourse]) async throws -> Download {
            let until = BerlinClock.isoDate(today + recheckDays)
            var ok: [String: Int] = [:], missing: [String: Int] = [:]
            courseLoop: for (i, c) in courses.enumerated() {
                let left = budget - (await used())
                if left <= 0 { out.stopped = true; break }
                limit = await used() + min(left, max(minCourseRequests, left / (courses.count - i)))
                res = CourseResult(courseID: c.id)
                for feature in features {
                    if absent("absent|\(feature)") || absent("absent|\(feature)|\(c.id)") { continue }
                    do {
                        try Task.checkCancellation()
                        switch feature {
                        case "tasks": try await tasks(c.id)
                        case "courseware": try await courseware(c.id)
                        case "wiki": try await wiki(c.id)
                        default: try await forum(c.id)
                        }
                        ok[feature, default: 0] += 1
                        if state["absent|\(feature)|\(c.id)"] != nil { out.stateDel.append("absent|\(feature)|\(c.id)") }
                    } catch Failure.absent {
                        missing[feature, default: 0] += 1
                        out.stateSet["absent|\(feature)|\(c.id)"] = until
                        state["absent|\(feature)|\(c.id)"] = until
                    } catch Failure.failed, Failure.stop {
                        continue
                    } catch Failure.stopAll {
                        // kein Netz oder Anfragegrenze des Clients: der Rest wird nicht gefragt, Gelesenes bleibt
                        out.stopped = true
                        out.courses.append(res)
                        break courseLoop
                    }
                }
                out.courses.append(res)
            }
            for f in features where ok[f, default: 0] == 0 && missing[f, default: 0] >= 2 { out.stateSet["absent|\(f)"] = until }
            out.requests = await used()
            return out
        }

        func tasks(_ cid: String) async throws {
            let path = state["tasks_path"]
            let order = path == "1" || path == "2" ? [path!] : ["1", "2"]
            for (n, p) in order.enumerated() {
                var items: [Deadline]
                do {
                    if p == "1" {
                        let (data, inc) = try await list("\(api)courseware-tasks?filter[cid]=\(cid)&include=task-group,structural-element&page[limit]=100")
                        var included: [String: JSONValue] = [:]
                        for x in inc { if let t = x["type"]?.string, let id = x["id"]?.string { included[t + "|" + id] = x } }
                        items = data.filter { $0.object != nil }.compactMap { taskDeadline($0, included: included, courseID: cid, base: base) }
                    } else {
                        let (data, _) = try await list("\(api)courses/\(cid)/courseware-task-groups?page[limit]=100")
                        items = data.filter { $0.object != nil }.compactMap { groupDeadline($0, courseID: cid, base: base) }
                    }
                } catch Failure.absent where n + 1 < order.count {
                    continue
                }
                if path != p {
                    out.stateSet["tasks_path"] = p
                    state["tasks_path"] = p
                }
                res.deadlines = items
                res.deadlinesComplete = true
                return
            }
        }

        func elementText(_ eid: String) async throws -> String {
            let (containers, inc) = try await list("\(api)courseware-structural-elements/\(eid)/containers?include=blocks&page[limit]=100")
            let blocks = inc.filter { $0.object != nil && $0["type"]?.string == "courseware-blocks" }
            var parts: [String] = []
            if !blocks.isEmpty {
                var keys: [String] = [], byContainer: [String: [JSONValue]] = [:], loose: [JSONValue] = []
                for b in blocks {
                    if let k = relID(b, "container") {
                        if byContainer[k] == nil { keys.append(k) }
                        byContainer[k, default: []].append(b)
                    } else {
                        loose.append(b)
                    }
                }
                var ordered: [JSONValue] = []
                for ct in containers where ct.object != nil {
                    if let id = ct["id"]?.string, let list = byContainer.removeValue(forKey: id) { ordered += list }
                }
                for k in keys { ordered += byContainer[k] ?? [] }
                ordered += loose
                parts = ordered.map(blockText)
            } else {
                for ct in containers {
                    guard ct.object != nil, let id = ct["id"]?.string else { continue }
                    let (data, _) = try await list("\(api)courseware-containers/\(id)/blocks?page[limit]=100")
                    parts += data.filter { $0.object != nil }.map(blockText)
                }
            }
            return parts.filter { !PyText.strip($0).isEmpty }.joined(separator: "\n\n")
        }

        func courseware(_ cid: String) async throws {
            let (units, inc) = try await list("\(api)courses/\(cid)/courseware-units?include=structural-element&page[limit]=50")
            var elements: [String: JSONValue] = [:]
            for x in inc where x.object != nil && x["type"]?.string == "courseware-structural-elements" {
                if let id = x["id"]?.string { elements[id] = x }
            }
            var count = 0
            var complete = true

            func visit(_ eid: String, _ a: [String: JSONValue], _ depth: Int) async throws {
                if count >= maxPages { return }
                count += 1
                let rid = "cw-\(eid)"
                let ch = changed(a)
                let t = squash(first(a, "title"))
                res.seen["courseware", default: []].append(rid)
                if !fresh(rid, ch) {
                    var body: String?
                    do {
                        body = try await elementText(eid)
                    } catch Failure.absent {
                        body = ""
                    } catch Failure.failed {
                        complete = false
                        body = nil
                    }
                    if let body, !body.isEmpty {
                        res.rows.append(TextRow(id: rid, kind: "courseware", title: t.isEmpty ? "Courseware" : t, text: cut(body),
                                                url: coursewareURL(base, cid, eid), changed: ch))
                    } else if body != nil {
                        res.unsee("courseware", rid)              // ohne Text: kein Eintrag (ein alter faellt weg)
                    }
                }
                if depth >= maxDepth { return }
                let children: [JSONValue]
                do {
                    children = try await list("\(api)courseware-structural-elements/\(eid)/children?page[limit]=100").data
                } catch Failure.absent {
                    return
                } catch Failure.failed {
                    complete = false
                    return
                }
                for child in children {
                    if child.object != nil, let id = child["id"]?.string { try await visit(id, attrs(child), depth + 1) }
                }
            }

            do {
                for u in units {
                    if let root = relID(u, "structural-element") { try await visit(root, attrs(elements[root]), 0) }
                }
            } catch Failure.stop {
                complete = false
            }
            res.complete["courseware"] = complete
        }

        func wiki(_ cid: String) async throws {
            let (pages, _) = try await list("\(api)courses/\(cid)/wiki-pages?page[limit]=100")
            var complete = true
            for p in pages.filter({ $0.object != nil && $0["id"]?.string != nil }).prefix(maxWiki) {
                let pid = p["id"]!.string!
                let a = attrs(p)
                let rid = "wiki-\(pid)"
                let ch = changed(a)
                res.seen["wiki", default: []].append(rid)
                if !ch.isEmpty, (known[rid]?.changed ?? "") == ch { continue }
                var content = a["content-html"]?.string ?? a["content"]?.string
                if content == nil {
                    do {
                        content = first(attrs(try await one("\(api)wiki-pages/\(pid)")), "content-html", "content")
                    } catch Failure.failed, Failure.absent, Failure.stop {
                        complete = false
                        continue
                    }
                }
                let body = richToText(content ?? "")
                let t = squash(first(a, "keyword", "name", "title"))
                if !body.isEmpty {
                    res.rows.append(TextRow(id: rid, kind: "wiki", title: t.isEmpty ? "Wiki" : t, text: cut(body), url: wikiURL(base, cid, pid), changed: ch))
                } else {
                    res.unsee("wiki", rid)
                }
            }
            res.complete["wiki"] = complete
        }

        static func posting(_ a: [String: JSONValue]) -> String {
            richToText(anonymize(a["content-html"]?.string ?? text(a["content"])))
        }

        func forum(_ cid: String) async throws {
            let (cats, _) = try await list("\(api)courses/\(cid)/forum-categories?page[limit]=50")
            var complete = true
            var count = 0
            do {
                categories: for cat in cats {
                    if count >= maxForum { break }
                    guard cat.object != nil, let catID = cat["id"]?.string else { continue }
                    let entries: [JSONValue]
                    do {
                        entries = try await list("\(api)forum-categories/\(catID)/entries?page[limit]=50").data
                    } catch Failure.absent, Failure.failed {
                        complete = false
                        continue
                    }
                    for e in entries {
                        if count >= maxForum { continue categories }
                        guard e.object != nil, let eid = e["id"]?.string else { continue }
                        count += 1
                        let a = attrs(e)
                        let rid = "forum-\(eid)"
                        let ch = changed(a)
                        res.seen["forum", default: []].append(rid)
                        if fresh(rid, ch) { continue }
                        var posts: [JSONValue]
                        do {
                            posts = try await list("\(api)forum-entries/\(eid)/entries?page[limit]=100").data
                        } catch Failure.absent {
                            posts = []
                        } catch Failure.failed {
                            complete = false
                            continue
                        }
                        var parts = [Self.posting(a)]
                        for x in posts where x.object != nil {
                            let pa = attrs(x)
                            parts.append([squash(first(pa, "title")), Self.posting(pa)].filter { !$0.isEmpty }.joined(separator: "\n"))
                        }
                        let body = parts.filter { !$0.isEmpty }.joined(separator: "\n---\n")
                        let t = squash(first(a, "title", "name"))
                        if !body.isEmpty {
                            res.rows.append(TextRow(id: rid, kind: "forum", title: t.isEmpty ? "Forum" : t, text: cut(body), url: forumURL(base, cid, eid),
                                                    changed: ch))
                        } else {
                            res.unsee("forum", rid)
                        }
                    }
                }
            } catch Failure.stop {
                complete = false
            }
            res.complete["forum"] = complete
        }
    }

    // MARK: - Speichern

    /// `store`: in einer Transaktion aufrufen
    @discardableResult
    public static func store(_ c: SQLiteConnection, _ d: Download, now: String) throws -> StoreResult {
        try ensureTables(c)
        var out = StoreResult()
        for res in d.courses {
            let cid = res.courseID
            for r in res.rows {
                try c.execute("""
                    INSERT INTO studip_texts(id, course_id, kind, title, text, url, changed, fetched_at) VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, kind=excluded.kind, title=excluded.title,
                    text=excluded.text, url=excluded.url, changed=excluded.changed, fetched_at=excluded.fetched_at
                    """, [.text(r.id), .text(cid), .text(r.kind), .text(r.title), .text(r.text), .text(r.url), .text(r.changed), .text(now)])
                out.texts += 1
            }
            for kind in kinds where res.complete[kind] == true {
                let keep = Set(res.seen[kind] ?? []).union(res.rows.filter { $0.kind == kind }.map(\.id))
                for r in try c.query("SELECT id FROM studip_texts WHERE course_id=? AND kind=? ORDER BY id", [.text(cid), .text(kind)]) {
                    guard let id = r["id"]?.string, !keep.contains(id) else { continue }
                    try c.execute("DELETE FROM studip_texts WHERE id=?", [.text(id)])
                }
            }
            if let list = res.deadlines {
                for x in list {
                    try c.execute("""
                        INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                        VALUES (?, 'studip', ?, ?, ?, 'abgabe', 'courseware', ?, ?, 0, ?)
                        ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title, full_title=excluded.full_title,
                        kind=excluded.kind, module=excluded.module, due_at=excluded.due_at, url=excluded.url, fetched_at=excluded.fetched_at
                        """, [.text(x.id), .text(cid), .text(x.title), .text(x.fullTitle), .text(x.dueAt), .text(x.url), .text(now)])
                    out.deadlines += 1
                }
                if res.deadlinesComplete {
                    let ids = list.map(\.id)
                    let marks = ids.isEmpty ? "''" : Array(repeating: "?", count: ids.count).joined(separator: ",")
                    try c.execute("DELETE FROM deadlines WHERE source='studip' AND module='courseware' AND course_id=? AND id NOT IN (\(marks))",
                                  [.text(cid)] + ids.map(SQLiteValue.text))
                }
            }
        }
        for (k, v) in d.stateSet.sorted(by: { PyText.less($0.key, $1.key) }) {
            try c.execute("INSERT OR REPLACE INTO studip_text_state(key, value) VALUES (?,?)", [.text(k), .text(v)])
        }
        for k in d.stateDel where d.stateSet[k] == nil {
            try c.execute("DELETE FROM studip_text_state WHERE key=?", [.text(k)])
        }
        return out
    }

    // MARK: - Lesen: Modulansicht, Suche, KI

    struct Stored {
        let id, kind, title, text, url, changed, courseTitle: String
    }

    static func rows(_ c: SQLiteConnection, moduleID: SQLiteValue, kinds: [String] = kinds) throws -> [Stored] {
        guard try hasTables(c) else { return [] }
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        return try c.query("""
            SELECT t.id, t.kind, t.title, t.text, t.url, t.changed, c.title AS course_title
            FROM studip_texts t JOIN courses c ON c.id=t.course_id
            WHERE c.module_id=? AND c.active=1 AND t.kind IN (\(marks)) ORDER BY t.id
            """, [moduleID] + kinds.map(SQLiteValue.text)).map { r in
            Stored(id: r["id"]?.string ?? "", kind: r["kind"]?.string ?? "", title: r["title"]?.string ?? "", text: r["text"]?.string ?? "",
                   url: r["url"]?.string ?? "", changed: r["changed"]?.string ?? "", courseTitle: r["course_title"]?.string ?? "")
        }
    }

    /// `_day_text`: Tag der Aenderung "YYYY-MM-DD" oder ""
    static func dayText(_ changed: String) -> String {
        if isoPrefix.found(in: changed) { return PyText.slice(changed, 0, 10) }
        if unixDigits.found(in: changed), let n = Int(changed) { return BerlinClock.isoDate(BerlinClock.local(utc: n).day) }
        return ""
    }

    static func optional(_ s: String) -> JSONValue { s.isEmpty ? .null : .string(s) }

    /// `overview`: Bereich "Aus Stud.IP" der Modulansicht
    public static func overview(_ c: SQLiteConnection, moduleID: SQLiteValue) throws -> JSONValue {
        let all = try rows(c, moduleID: moduleID)
        var groups: [JSONValue] = []
        var total = 0
        for kind in kinds {
            let items = all.filter { $0.kind == kind }.map { ($0, dayText($0.changed)) }.sorted { a, b in
                a.1 != b.1 ? PyText.less(b.1, a.1) : PyText.less(b.0.id, a.0.id)
            }
            guard let top = items.first else { continue }
            total += items.count
            groups.append(["kind": .string(kind), "label": .string(kindLabels[kind] ?? kind), "count": .number(Double(items.count)),
                           "changed": optional(top.1),
                           "items": .array(items.prefix(30).map { r, d in
                               ["id": .string(r.id), "title": .string(r.title), "course_title": .string(r.courseTitle), "changed": optional(d),
                                "url": .string(r.url)]
                           })])
        }
        return ["groups": .array(groups), "total": .number(Double(total))]
    }

    /// `item`: ein Text zum Lesen; nil = unbekannt
    public static func item(_ c: SQLiteConnection, id: String) throws -> JSONValue? {
        guard try hasTables(c), let r = try c.queryOne("""
            SELECT t.id, t.kind, t.title, t.text, t.url, t.changed, c.title AS course_title FROM studip_texts t
            LEFT JOIN courses c ON c.id=t.course_id WHERE t.id=?
            """, [.text(id)]) else { return nil }
        let kind = r["kind"]?.string ?? ""
        return ["id": .string(r["id"]?.string ?? id), "kind": .string(kind), "kind_label": .string(kindLabels[kind] ?? kind),
                "title": .string(r["title"]?.string ?? ""), "text": .string(r["text"]?.string ?? ""), "url": r["url"]?.string.map(JSONValue.string) ?? .null,
                "changed": optional(dayText(r["changed"]?.string ?? "")), "course_title": r["course_title"]?.string.map(JSONValue.string) ?? .null]
    }

    /// `search`: passende Texte des Moduls; Punkte = getroffene Woerter * 1000 + Haeufigkeit (hoechstens 999)
    public static func search(_ c: SQLiteConnection, moduleID: SQLiteValue, query: String, kinds: [String] = kinds, limit: Int = 3) throws -> [JSONValue] {
        var q: [String] = []
        for t in ScriptSearch.tokens(query) where !q.contains(t) { q.append(t) }
        guard !q.isEmpty, moduleID != .null else { return [] }
        let need = q.count >= 2 ? 2 : 1
        var scored: [(Int, Stored, [String])] = []
        for r in try rows(c, moduleID: moduleID, kinds: kinds) {
            var tf: [String: Int] = [:]
            for t in ScriptSearch.tokens(r.title + "\n" + r.text) { tf[t, default: 0] += 1 }
            let hit = q.filter { tf[$0, default: 0] > 0 }
            guard hit.count >= need else { continue }
            scored.append((hit.count * 1000 + min(999, hit.reduce(0) { $0 + tf[$1, default: 0] }), r, hit))
        }
        scored.sort { a, b in a.0 != b.0 ? a.0 > b.0 : PyText.less(a.1.id, b.1.id) }
        return scored.prefix(limit).map { s, r, hit in
            ["id": .string(r.id), "kind": .string(r.kind), "kind_label": .string(kindLabels[r.kind] ?? r.kind), "title": .string(r.title),
             "course_title": .string(r.courseTitle), "url": .string(r.url), "score": .number(Double(s)),
             "snippet": .string(ScriptSearch.snippet(ScriptSearch.normalize(r.text), terms: hit))]
        }
    }

    /// `tutor_sources`: weitere Quellen fuer die KI-Hilfe, nummeriert ab `start`
    public static func tutorSources(_ c: SQLiteConnection, moduleID: SQLiteValue, query: String, start: Int, limit: Int = 2) throws -> [JSONValue] {
        try search(c, moduleID: moduleID, query: query, limit: limit).enumerated().map { i, h in
            ["n": .number(Double(start + i)), "studip_id": h["id"] ?? .null, "kind": h["kind"] ?? .null,
             "title": .string("\(h["kind_label"]?.string ?? ""): \(h["title"]?.string ?? "")"), "name": h["title"] ?? .null,
             "page": .null, "snippet": h["snippet"] ?? .null, "url": h["url"] ?? .null, "current": false]
        }
    }

    /// `weekly_lines`: Ergaenzung fuer den Wochentest (Courseware und Wiki, gekuerzt, mit Herkunft)
    public static func weeklyLines(_ c: SQLiteConnection, moduleID: SQLiteValue, query: String, limit: Int = 2, chars: Int = 600) throws -> [String] {
        try search(c, moduleID: moduleID, query: query, kinds: ["courseware", "wiki"], limit: limit).map { h in
            let t = try item(c, id: h["id"]?.string ?? "")?["text"]?.string ?? ""
            let flat = PyText.strip(anySpace.sub(t, " "))
            return "\(h["kind_label"]?.string ?? "") „\(h["title"]?.string ?? "")“: \(cut(flat, chars))"
        }
    }
}

extension PyRegex {
    /// `re.sub(p, r"\N", s)`: jeder Treffer wird durch Gruppe `group` ersetzt
    func subGroup(_ s: String, _ group: Int) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s), withTemplate: "$\(group)")
    }
}

import Foundation

/// Erkannte Abgaben, Tests und Pruefungstermine in der Datenbank des Containers (je Nutzer und Hochschule), nur auf
/// dem Geraet. Quellen: Seitentexte der PDFs (`page_texts`), Dateinamen, Ankuendigungen (`announcements`); die
/// Erkennung selbst ist `DueDetection`. Die Learnweb-Fristen (`deadlines`) bleiben, wie sie sind; ein erkannter Termin,
/// den es dort schon gibt (gleiches Modul bzw. gleicher Kurs, gleicher Tag, gleiche Art), wird nicht doppelt gezeigt,
/// ebenso einer am Klausurtermin des Moduls.
///
/// Tabellen, erst bei Bedarf angelegt (wie `file_versions`; am PC gibt es sie nicht, das Schema der Python-Referenz
/// bleibt unveraendert):
/// - `due_hits`: jede Fundstelle (Datei und Seite, Dateiname oder Ankuendigung). Wird nach jedem Abgleich ganz neu
///   berechnet (`refreshAll`, ohne geaenderte Eingaben uebersprungen) und fuer eine Datei, wenn ihre Seitentexte neu
///   gelesen sind (`refreshFile`; PDFs ganz ohne Seitentexte liest POST /api/due/backfill nach).
/// - `due_choices`: Entscheidungen des Nutzers je Kurs, Tag und Art ("stimmt nicht", bestaetigt, eigene Uhrzeit). Sie
///   bleiben beim Neuberechnen stehen und gelten wieder, sobald derselbe Termin erneut erkannt wird.
/// - `due_meta`: Stand der Erkennung (Version, Tag des letzten Laufs).
/// Angezeigt wird je Modul (sonst Kurs), Tag und Art ein Termin mit allen Fundstellen.
public enum DueStore {
    /// Stand der Erkennung; aendert sich die Erkennung, rechnet `ensureFresh` alles neu
    static let detectorVersion = "1"

    static let tablesSQL = """
        CREATE TABLE IF NOT EXISTS due_hits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,              -- dokument | dateiname | ankuendigung
            file_id TEXT,
            page INTEGER,
            announcement_id TEXT,
            course_id TEXT,
            date TEXT NOT NULL,                -- YYYY-MM-DD
            time TEXT,                         -- HH:MM
            kind TEXT NOT NULL,                -- abgabe | test | klausur | anmeldung | sonstiges
            label TEXT NOT NULL,
            snippet TEXT,
            name TEXT,                         -- Dateiname bzw. Titel der Ankuendigung
            url TEXT,
            detected_at TEXT
        );
        CREATE INDEX IF NOT EXISTS ix_due_hits_date ON due_hits(date);
        CREATE INDEX IF NOT EXISTS ix_due_hits_file ON due_hits(file_id);
        CREATE TABLE IF NOT EXISTS due_choices (
            key TEXT PRIMARY KEY,              -- Kurs|Tag|Art
            hidden INTEGER NOT NULL DEFAULT 0, -- "stimmt nicht"
            confirmed INTEGER NOT NULL DEFAULT 0,
            time TEXT,                         -- eigene Uhrzeit des Nutzers
            updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS due_meta (key TEXT PRIMARY KEY, value TEXT);
        """

    static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tablesSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='due_hits'") != nil
    }

    // MARK: - Rahmen

    /// Laufende Semester dieser Datenbank: Hochschule aus `settings`, aktives Semester aus `terms`
    static func window(_ c: SQLiteConnection, clock: UniFlowClock) throws -> DueDetection.Window? {
        let university = try Holidays.university(c)
        let row = try c.queryOne("SELECT name, start, end FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")
        var term: (name: String, start: String, end: String)?
        if let r = row, let s = r["start"]?.string, let e = r["end"]?.string { term = (r["name"]?.string ?? "", s, e) }
        return DueDetection.Window.current(university: university, today: LocalTimetable.today(clock), term: term)
    }

    // MARK: - Erkennen und speichern

    struct Row {
        var source: String
        var fileID: String?
        var page: Int?
        var announcementID: String?
        var courseID: String?
        var hit: DueDetection.Hit
        var name: String?
        var url: String?
    }

    public struct RefreshResult: Sendable, Equatable {
        public var hits = 0
        public var changed = false
    }

    /// Loesungen und Altklausuren: dort stehen Termine frueherer Durchgaenge
    private static let oldExamNameRE = HText.regex(#"l(?:ö|oe)sung|musterl|solution|altklausur|alte[ _-]?klausur"#, [.caseInsensitive])

    /// Vorauswahl der Seiten in SQL: nur Seiten mit einem Schluesselwort (Suchform `page_texts.search`, klein)
    private static var likeClause: String {
        "(p.search IS NULL OR " + DueDetection.likeTerms.map { _ in "p.search LIKE ?" }.joined(separator: " OR ") + ")"
    }

    private static var likeParams: [SQLiteValue] { DueDetection.likeTerms.map { .text("%" + $0 + "%") } }

    /// Tagesnummer einer Unix-Zeit (Aenderung der Datei) in Berlin; nil ohne Zeit
    static func day(unix v: JSONValue?) -> Int? {
        guard let s = v?.double, s > 0 else { return nil }
        return BerlinClock.local(utc: Int(s)).day
    }

    /// Fundstellen einer Datei: Seiten (`pages`) und Dateiname. Nennt der Kopf ein anderes Semester, keine.
    static func scanFile(id: String, name: String, chdate: JSONValue?, courseID: String?, pages: [(Int, String)], firstPage: String?,
                         window: DueDetection.Window) -> [Row] {
        if let s = DueDetection.headSemester(firstPage: firstPage, name: name), !window.semesters.isEmpty, !window.semesters.contains(s) {
            return []
        }
        let old = DueDetection.has(oldExamNameRE, name)
        let ctx = DueDetection.Context(window: window, reference: day(unix: chdate), name: name, head: DueDetection.headLines(firstPage),
                                       allowYearless: !old, allowExams: !old)
        var out: [Row] = []
        for (page, text) in pages {
            for h in DueDetection.detect(text, context: ctx) {
                out.append(Row(source: "dokument", fileID: id, page: page, courseID: courseID, hit: h, name: name))
            }
        }
        let lower = ScriptSearch.searchForm(name)
        if DueDetection.likeTerms.contains(where: { lower.contains($0) }) {
            for h in DueDetection.detect(DueDetection.nameText(name), context: ctx) {
                out.append(Row(source: "dateiname", fileID: id, page: nil, courseID: courseID, hit: h, name: name))
            }
        }
        return out
    }

    private static let fileFilter = "f.deleted_at IS NULL AND c.active=1 AND f.course_id <> '__user__'"

    /// Fundstellen aller Dateien (nur aktuelle Fassung der Seitentexte, nicht im Papierkorb, gewaehlte Kurse)
    static func scanFiles(_ c: SQLiteConnection, window: DueDetection.Window, only fileID: String? = nil) throws -> [Row] {
        let one = fileID.map { _ in " AND f.id=?" } ?? ""
        let oneParam: [SQLiteValue] = fileID.map { [.text($0)] } ?? []
        var pagesByFile: [String: [(Int, String)]] = [:]
        for r in try c.query("""
            SELECT p.file_id, p.page, p.text, p.search FROM page_texts p JOIN files f ON f.id=p.file_id JOIN courses c ON c.id=f.course_id
            WHERE COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0) AND \(fileFilter)\(one) AND \(likeClause)
            ORDER BY p.file_id, p.page
            """, oneParam + likeParams) {
            guard let id = r["file_id"]?.string, let page = r["page"]?.int else { continue }
            let text = r["text"]?.string ?? ""
            // Suchform fehlt (aeltere Zeilen): hier bilden und pruefen
            if r["search"]?.string == nil {
                let form = ScriptSearch.searchForm(text)
                guard DueDetection.likeTerms.contains(where: { form.contains($0) }) else { continue }
            }
            pagesByFile[id, default: []].append((page, text))
        }
        var out: [Row] = []
        for f in try c.rows("""
            SELECT f.id, f.name, f.chdate, f.course_id FROM files f JOIN courses c ON c.id=f.course_id
            WHERE \(fileFilter)\(one) ORDER BY f.id
            """, oneParam) {
            guard let id = f["id"]?.string else { continue }
            let name = f["name"]?.string ?? ""
            let pages = pagesByFile[id] ?? []
            guard !pages.isEmpty || DueDetection.likeTerms.contains(where: { ScriptSearch.searchForm(name).contains($0) }) else { continue }
            var first = pages.first(where: { $0.0 == 1 })?.1
            if first == nil {
                first = try c.scalar("""
                    SELECT p.text FROM page_texts p JOIN files f ON f.id=p.file_id
                    WHERE p.file_id=? AND p.page=1 AND COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0)
                    """, [.text(id)])?.string
            }
            out += scanFile(id: id, name: name, chdate: f["chdate"], courseID: f["course_id"]?.string, pages: pages, firstPage: first, window: window)
        }
        return out
    }

    /// Fundstellen der Ankuendigungen (Stud.IP-News, Learnweb-Foren); Bezugstag ist der Tag der Ankuendigung
    static func scanAnnouncements(_ c: SQLiteConnection, window: DueDetection.Window) throws -> [Row] {
        var out: [Row] = []
        for a in try c.rows("""
            SELECT a.id, a.course_id, a.title, a.text, a.posted_at, a.url FROM announcements a LEFT JOIN courses c ON c.id=a.course_id
            WHERE COALESCE(c.active, 1)=1 ORDER BY a.posted_at, a.id
            """) {
            guard let id = a["id"]?.string else { continue }
            let title = a["title"]?.string ?? ""
            let ref = Announcements.postedDay(a["posted_at"]?.string ?? "", today: window.today)
            let ctx = DueDetection.Context(window: window, reference: ref)
            for h in DueDetection.detect(title + "\n" + (a["text"]?.string ?? ""), context: ctx) {
                out.append(Row(source: "ankuendigung", fileID: nil, page: nil, announcementID: id, courseID: a["course_id"]?.string,
                               hit: h, name: title, url: a["url"]?.string))
            }
        }
        return out
    }

    static func insert(_ c: SQLiteConnection, _ rows: [Row], now: String) throws {
        for r in rows {
            try c.execute("""
                INSERT INTO due_hits(source, file_id, page, announcement_id, course_id, date, time, kind, label, snippet, name, url, detected_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(r.source), SQLiteValue(r.fileID), r.page.map { .integer(Int64($0)) } ?? .null, SQLiteValue(r.announcementID),
                      SQLiteValue(r.courseID), .text(r.hit.date), SQLiteValue(r.hit.time), .text(r.hit.kind.rawValue), .text(r.hit.label),
                      .text(r.hit.snippet), SQLiteValue(r.name), SQLiteValue(r.url), .text(now)])
        }
    }

    /// Fundstellen ohne Zeitstempel und Reihenfolge (erkennt, ob sich etwas geaendert hat)
    private static func signature(_ c: SQLiteConnection) throws -> [String] {
        try c.query("""
            SELECT source, COALESCE(file_id,''), COALESCE(page,0), COALESCE(announcement_id,''), COALESCE(course_id,''), date, COALESCE(time,''),
                   kind, label FROM due_hits
            """).map { r in (0..<9).map { r[$0].string ?? String(r[$0].int64 ?? 0) }.joined(separator: "|") }.sorted()
    }

    private static func setMeta(_ c: SQLiteConnection, _ key: String, _ value: String) throws {
        try c.execute("INSERT INTO due_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    /// Stand der Eingaben (Seitentexte, Dateien, Kurse, Ankuendigungen, Semester, Tag, Erkennung): gleich -> nichts zu
    /// tun. Ein Abgleich ohne neue Dateien kostet so kaum etwas.
    static func inputStamp(_ c: SQLiteConnection, clock: UniFlowClock) throws -> String {
        var parts = [detectorVersion, clock.today, try Holidays.university(c)]
        for sql in [
            "SELECT COUNT(*), TOTAL(chdate), TOTAL(length(text)) FROM page_texts",
            "SELECT COUNT(*), TOTAL(chdate), TOTAL(length(name)), TOTAL(length(course_id)), TOTAL(deleted_at IS NOT NULL) FROM files",
            "SELECT group_concat(x, ',') FROM (SELECT id || ':' || COALESCE(active, 1) AS x FROM courses ORDER BY id)",
            "SELECT COUNT(*), TOTAL(length(text)), TOTAL(length(title)), MAX(posted_at), TOTAL(length(course_id)) FROM announcements",
            "SELECT group_concat(x, ',') FROM (SELECT name || '|' || start || '|' || end || '|' || active AS x FROM terms ORDER BY id)",
        ] {
            if let r = try c.queryOne(sql) { parts.append((0..<r.values.count).map { i in r[i].string ?? r[i].double.map { String($0) } ?? "-" }.joined(separator: ";")) }
        }
        return parts.joined(separator: "/")
    }

    /// Alles neu berechnen (nach jedem Abgleich; in einer Transaktion aufrufen). Entscheidungen des Nutzers bleiben.
    /// Ohne geaenderte Eingaben (`inputStamp`) bleibt alles, wie es ist; `force` rechnet trotzdem.
    @discardableResult
    public static func refreshAll(_ c: SQLiteConnection, clock: UniFlowClock, force: Bool = false) throws -> RefreshResult {
        try ensureTables(c)
        let stamp = try inputStamp(c, clock: clock)
        if !force, try c.scalar("SELECT value FROM due_meta WHERE key='input'")?.string == stamp {
            try setMeta(c, "refreshed_day", clock.today)
            return RefreshResult(hits: try c.scalar("SELECT COUNT(*) FROM due_hits")?.int ?? 0, changed: false)
        }
        let before = try signature(c)
        try c.execute("DELETE FROM due_hits")
        var rows: [Row] = []
        if let w = try window(c, clock: clock) {
            rows = try scanFiles(c, window: w) + scanAnnouncements(c, window: w)
            try insert(c, rows, now: clock.nowISO)
        }
        try setMeta(c, "version", detectorVersion)
        try setMeta(c, "refreshed_day", clock.today)
        try setMeta(c, "refreshed_at", clock.nowISO)
        try setMeta(c, "input", stamp)
        return RefreshResult(hits: rows.count, changed: try signature(c) != before)
    }

    /// Neu gelesene Seitentexte einer Datei (Oeffnen, Skriptsuche): nur ihre Fundstellen neu. Ohne Tabellen (noch nie
    /// gerechnet) nichts; das erledigt dann `ensureFresh` beim naechsten Lesen.
    static func refreshFile(_ c: SQLiteConnection, fileID: String, clock: UniFlowClock) throws {
        guard try hasTables(c) else { return }
        try c.execute("DELETE FROM due_hits WHERE file_id=?", [.text(fileID)])
        try c.execute("DELETE FROM due_meta WHERE key='input'")
        guard let w = try window(c, clock: clock) else { return }
        try insert(c, try scanFiles(c, window: w, only: fileID), now: clock.nowISO)
    }

    // MARK: - Fehlende Seitentexte

    /// PDFs ohne Seitentexte der aktuellen Fassung (vor S7 geladen, nie geoeffnet), neueste zuerst; nicht lesbare
    /// (`markUnreadable`, gleiche Aenderungszeit) fehlen
    static func backfillCandidates(_ c: SQLiteConnection, limit: Int) throws -> [String] {
        try c.query("""
            SELECT f.id FROM files f JOIN courses c ON c.id=f.course_id
            WHERE \(fileFilter) AND COALESCE(f.local_path, '') <> '' AND lower(f.local_path) LIKE '%.pdf'
              AND NOT EXISTS (SELECT 1 FROM page_texts p WHERE p.file_id=f.id AND COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0))
              AND NOT EXISTS (SELECT 1 FROM due_meta m WHERE m.key='unreadable:' || f.id AND m.value=CAST(COALESCE(f.chdate, 0) AS TEXT))
            ORDER BY f.chdate DESC, f.id LIMIT ?
            """, [.integer(Int64(limit))]).compactMap { $0["id"]?.string }
    }

    /// PDF ohne lesbaren Text (oder nicht auf dem Geraet): nicht bei jedem Lauf erneut versuchen, bis eine neue Fassung kommt
    static func markUnreadable(_ c: SQLiteConnection, fileID: String) throws {
        let chdate = try c.scalar("SELECT COALESCE(chdate, 0) FROM files WHERE id=?", [.text(fileID)])?.int64 ?? 0
        try setMeta(c, "unreadable:" + fileID, String(chdate))
    }

    /// Vor dem Lesen der Liste: noch nie gerechnet, andere Erkennung oder neuer Tag (anderes Semester moeglich) ->
    /// neu rechnen. In einer Transaktion aufrufen. true, wenn sich dabei etwas geaendert hat.
    @discardableResult
    static func ensureFresh(_ c: SQLiteConnection, clock: UniFlowClock) throws -> Bool {
        if try hasTables(c),
           try c.scalar("SELECT value FROM due_meta WHERE key='version'")?.string == detectorVersion,
           try c.scalar("SELECT value FROM due_meta WHERE key='refreshed_day'")?.string == clock.today { return false }
        return try refreshAll(c, clock: clock).changed
    }

    // MARK: - Lesen

    /// Ein angezeigter Termin: alle Fundstellen mit gleichem Modul (sonst Kurs), Tag und Art
    struct Group {
        var id: String
        var date: String
        var kind: String
        var hits: [[String: JSONValue]]
        var keys: [String]
        var hidden = false
        var confirmed = false
        var userTime: String?
        /// steht schon als Learnweb-Frist oder Klausurtermin des Moduls da
        var covered = false
    }

    /// Schluessel einer Entscheidung: Kurs, Tag, Art
    static func choiceKey(course: String?, date: String, kind: String) -> String { "\(course ?? "-")|\(date)|\(kind)" }

    static func groupID(_ scope: String, _ date: String, _ kind: String) -> String {
        "due-" + String(SolutionSHA256.hexString(SolutionSHA256.hash(Data("\(scope)|\(date)|\(kind)".utf8))).prefix(16))
    }

    /// Art einer Learnweb-Frist als Art der Erkennung (fuer "schon vorhanden")
    static func learnwebKind(_ k: String?) -> String? {
        switch k {
        case "abgabe", "frist": return "abgabe"
        case "test_ende", "test_beginn": return "test"
        default: return nil
        }
    }

    static func scope(module: JSONValue?, course: String?) -> String {
        if let m = module?.int { return "m\(m)" }
        return "c\(course ?? "-")"
    }

    /// Termine im Zeitraum (Tage "YYYY-MM-DD", beide eingeschlossen), nach Tag; Fundstellen geloeschter Dateien fehlen
    static func groups(_ c: SQLiteConnection, from: String, to: String) throws -> [Group] {
        guard try hasTables(c) else { return [] }
        let rows = try c.rows("""
            SELECT h.*, c.module_id, c.title AS course_title, m.color, m.name AS module_name, f.id AS known_file, f.deleted_at AS file_deleted
            FROM due_hits h LEFT JOIN courses c ON c.id=h.course_id LEFT JOIN modules m ON m.id=c.module_id LEFT JOIN files f ON f.id=h.file_id
            WHERE h.date >= ? AND h.date <= ? ORDER BY h.date, h.id
            """, [.text(from), .text(to)])
        guard !rows.isEmpty else { return [] }
        var choices: [String: [String: JSONValue]] = [:]
        for r in try c.rows("SELECT * FROM due_choices") { if let k = r["key"]?.string { choices[k] = r } }
        // schon vorhanden: Learnweb-Fristen und Klausurtermine der Module
        var existing = Set<String>()
        for r in try c.rows("""
            SELECT d.course_id, substr(d.due_at, 1, 10) AS day, d.kind, c.module_id FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id
            WHERE d.due_at >= ? AND d.due_at < ?
            """, [.text(from), .text(to + "T99")]) {
            guard let kind = learnwebKind(r["kind"]?.string), let day = r["day"]?.string else { continue }
            existing.insert("\(scope(module: r["module_id"], course: r["course_id"]?.string))|\(day)|\(kind)")
        }
        for r in try c.rows("SELECT id, exam_date FROM modules WHERE exam_date >= ? AND exam_date <= ?", [.text(from), .text(to)]) {
            if let id = r["id"]?.int, let day = r["exam_date"]?.string { existing.insert("m\(id)|\(PyText.slice(day, 0, 10))|klausur") }
        }
        var order: [String] = []
        var byKey: [String: Group] = [:]
        for r in rows {
            if let f = r["file_id"]?.string, !f.isEmpty, (r["known_file"]?.isNull ?? true) || !(r["file_deleted"]?.isNull ?? true) { continue }
            guard let date = r["date"]?.string, let kind = r["kind"]?.string else { continue }
            let s = scope(module: r["module_id"], course: r["course_id"]?.string)
            let gk = "\(s)|\(date)|\(kind)"
            if byKey[gk] == nil {
                order.append(gk)
                byKey[gk] = Group(id: groupID(s, date, kind), date: date, kind: kind, hits: [], keys: [], covered: existing.contains(gk))
            }
            byKey[gk]!.hits.append(r)
            let ck = choiceKey(course: r["course_id"]?.string, date: date, kind: kind)
            if !byKey[gk]!.keys.contains(ck) { byKey[gk]!.keys.append(ck) }
        }
        return order.compactMap { k in
            guard var g = byKey[k] else { return nil }
            for key in g.keys {
                guard let ch = choices[key] else { continue }
                if LocalModules.truthy(ch["hidden"]) { g.hidden = true }
                if LocalModules.truthy(ch["confirmed"]) { g.confirmed = true }
                if g.userTime == nil, let t = ch["time"]?.string, !t.isEmpty { g.userTime = t }
            }
            return g
        }
    }

    private static let sourceRank = ["dokument": 0, "dateiname": 1, "ankuendigung": 2]

    /// Fundstellen sortiert: Dokumente (nach Name, Seite), Dateinamen, Ankuendigungen
    static func sortedHits(_ g: Group) -> [[String: JSONValue]] {
        g.hits.enumerated().sorted { a, b in
            let ra = sourceRank[a.element["source"]?.string ?? ""] ?? 9, rb = sourceRank[b.element["source"]?.string ?? ""] ?? 9
            if ra != rb { return ra < rb }
            let na = a.element["name"]?.string ?? "", nb = b.element["name"]?.string ?? ""
            if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
            let pa = a.element["page"]?.int ?? 0, pb = b.element["page"]?.int ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    /// Bezeichnung: mit Nummer vor ohne, sonst die haeufigste
    static func title(_ hits: [[String: JSONValue]]) -> String {
        let labels = hits.compactMap { $0["label"]?.string }
        if let numbered = labels.first(where: { $0.contains(where: \.isNumber) }) { return numbered }
        var count: [String: Int] = [:]
        for l in labels { count[l, default: 0] += 1 }
        return labels.max { (count[$0] ?? 0) < (count[$1] ?? 0) } ?? "Termin"
    }

    /// Uhrzeit: die eigene des Nutzers, sonst die haeufigste genannte (bei Gleichstand die der ersten Fundstelle)
    static func time(_ g: Group, _ hits: [[String: JSONValue]]) -> String? {
        if let t = g.userTime { return t }
        let times = hits.compactMap { $0["time"]?.string }
        var count: [String: Int] = [:]
        for t in times { count[t, default: 0] += 1 }
        let best = count.values.max() ?? 0
        return times.first { count[$0] == best }
    }

    /// Ehrlicher Text zur Herkunft: "erkannt in Blatt3.pdf, S. 2"
    static func origin(_ h: [String: JSONValue]) -> String {
        let name = h["name"]?.string ?? ""
        switch h["source"]?.string {
        case "dokument": return "erkannt in \(name), S. \(h["page"]?.int ?? 1)"
        case "dateiname": return "erkannt im Dateinamen „\(name)“"
        default: return "erkannt in der Ankündigung „\(name)“"
        }
    }

    static func originText(_ hits: [[String: JSONValue]]) -> String {
        guard let first = hits.first else { return "" }
        let more = hits.count - 1
        return origin(first) + (more == 0 ? "" : more == 1 ? " und an 1 weiteren Stelle" : " und an \(more) weiteren Stellen")
    }

    /// Art fuer die Anzeige ("Kurztestat 2" -> "Kurztestat", "Abgabe Blatt 3" -> "Abgabe")
    static func kindLabel(_ title: String) -> String {
        String(title.split(separator: " ").first ?? Substring(title))
    }

    /// Gemeinsame Felder eines erkannten Termins in allen Antworten
    static func json(_ g: Group) -> [String: JSONValue] {
        let hits = sortedHits(g)
        let first = hits.first ?? [:]
        let t = title(hits)
        let sources: [JSONValue] = hits.prefix(8).map { h in
            ["source": h["source"] ?? .null, "file_id": h["file_id"] ?? .null, "page": h["page"] ?? .null, "name": h["name"] ?? .null,
             "announcement_id": h["announcement_id"] ?? .null, "url": h["url"] ?? .null, "snippet": h["snippet"] ?? .null,
             "origin": .string(origin(h))]
        }
        let opener = hits.first { $0["file_id"]?.string != nil } ?? first
        let announcements = Array(Set(hits.compactMap { $0["announcement_id"]?.string })).sorted().map(JSONValue.string)
        return [
            "id": .string(g.id), "source": "dokument", "detected": true, "date": .string(g.date), "time": time(g, hits).map(JSONValue.string) ?? .null,
            "kind": .string(g.kind), "kind_label": .string(kindLabel(t)), "title": .string(t), "origin": .string(originText(hits)),
            "full_title": .string("\(t) · \(originText(hits))"), "snippet": first["snippet"] ?? .null,
            "course_id": first["course_id"] ?? .null, "course_title": first["course_title"] ?? .null, "module_id": first["module_id"] ?? .null,
            "module_name": first["module_name"] ?? .null, "color": first["color"] ?? .null,
            "file_id": opener["file_id"] ?? .null, "page": opener["file_id"]?.string != nil ? (opener["page"].flatMap { $0.isNull ? nil : $0 } ?? .number(1)) : .null,
            "url": opener["file_id"]?.string == nil ? (opener["url"] ?? .null) : .null,
            "announcement_ids": .array(announcements), "sources": .array(sources),
            "confirmed": .bool(g.confirmed), "hidden": .bool(g.hidden), "user_time": .bool(g.userTime != nil), "overdue": false,
        ]
    }

    /// Erkannte Termine je Kalendertag fuer Lernkalender und Stundenplan (Feld `deadlines`, wie die Learnweb-Fristen);
    /// ausgeblendete und schon vorhandene fehlen
    static func calendarDays(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [String: [JSONValue]] {
        var out: [String: [JSONValue]] = [:]
        for g in try groups(c, from: BerlinClock.isoDate(start), to: BerlinClock.isoDate(end)) where !g.hidden && !g.covered {
            out[g.date, default: []].append(.object(json(g)))
        }
        return out
    }

    /// Hinweise aus Ankuendigungen, die schon als erkannter Termin am selben Tag dastehen, nicht doppelt zeigen
    static func withoutDuplicateNotices(_ notes: [String: [JSONValue]], deadlines: [String: [JSONValue]]) -> [String: [JSONValue]] {
        var out = notes
        for (day, list) in notes {
            let covered = Set((deadlines[day] ?? []).flatMap { $0["announcement_ids"]?.array?.compactMap(\.string) ?? [] })
            guard !covered.isEmpty else { continue }
            out[day] = list.filter { !covered.contains($0["announcement_id"]?.string ?? "") }
        }
        return out
    }

    /// Kommende erkannte Termine fuer "Nächste Termine" und GET /api/deadlines (Form wie `upcoming_deadlines`)
    static func upcoming(_ c: SQLiteConnection, today t: Int, now: String, limit: Int) throws -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        for g in try groups(c, from: BerlinClock.isoDate(t), to: BerlinClock.isoDate(t + 400)) where !g.hidden && !g.covered {
            var x = json(g)
            if let time = x["time"]?.string, PyText.less(g.date + "T" + time, now) { continue }
            x["deadline_id"] = .string(g.id)
            out.append(x)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Liste "Abgaben & Prüfungen"

    /// "heute", "morgen", "in 3 Tagen", "vor 2 Tagen"
    public static func inDays(_ n: Int) -> String {
        switch n {
        case 0: return "heute"
        case 1: return "morgen"
        case -1: return "gestern"
        case let k where k > 1: return "in \(k) Tagen"
        default: return "vor \(-n) Tagen"
        }
    }

    static func withDays(_ x: inout [String: JSONValue], today: Int) {
        let n = (x["date"]?.string).flatMap(BerlinClock.parseISODate).map { $0 - today } ?? 0
        x["days_left"] = .number(Double(n))
        x["in_days"] = .string(inDays(n))
        x["due_at"] = .string((x["date"]?.string ?? "") + ((x["time"]?.string).map { "T" + $0 } ?? ""))
    }

    /// Kommende Abgaben, Tests und Pruefungen: erkannte Termine, Learnweb-Fristen, Klausurtermine der Module; nach Tag und
    /// Uhrzeit. `moduleID`: nur dieses Modul. `includeHidden`: auch ausgeblendete (zum Wiederherstellen). Rechnet vorher
    /// neu, wenn noetig (`ensureFresh`; `refreshed`: dabei hat sich etwas geaendert): in einer Transaktion aufrufen.
    static func list(_ c: SQLiteConnection, clock: UniFlowClock, moduleID: Int? = nil, includeHidden: Bool = false,
                     days: Int = 200) throws -> [String: JSONValue] {
        let refreshed = try ensureFresh(c, clock: clock)
        let t = LocalTimetable.today(clock), now = PyText.slice(clock.nowISO, 0, 16)
        let from = BerlinClock.isoDate(t), to = BerlinClock.isoDate(t + days)
        var items: [[String: JSONValue]] = []
        var hiddenCount = 0
        for g in try groups(c, from: from, to: to) where !g.covered {
            let x = json(g)
            if let time = x["time"]?.string, PyText.less(g.date + "T" + time, now) { continue }
            if let m = moduleID, x["module_id"]?.int != m { continue }
            if g.hidden {
                hiddenCount += 1
                if !includeHidden { continue }
            }
            items.append(x)
        }
        for r in try c.rows("""
            SELECT d.*, c.title AS course_title, c.module_id, m.color, m.name AS module_name
            FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id LEFT JOIN modules m ON m.id=c.module_id
            WHERE d.due_at >= ? AND d.due_at <= ? ORDER BY d.due_at
            """, [.text(now), .text(to + "T99")]) {
            if let m = moduleID, r["module_id"]?.int != m { continue }
            guard let due = r["due_at"]?.string else { continue }
            let kind = r["kind"]?.string ?? ""
            items.append([
                "id": r["id"] ?? .null, "deadline_id": r["id"] ?? .null, "source": "learnweb", "detected": false,
                "date": .string(PyText.slice(due, 0, 10)), "time": .string(PyText.slice(due, 11, 16)),
                "kind": .string(learnwebKind(kind) ?? "sonstiges"), "kind_label": .string(Holidays.deadlineLabels[kind] ?? "Frist"),
                "title": r["title"] ?? .null, "full_title": LocalTimetable.or(r["full_title"], r["title"] ?? .null),
                "origin": "aus dem Learnweb-Kalender", "course_id": r["course_id"] ?? .null, "course_title": r["course_title"] ?? .null,
                "module_id": r["module_id"] ?? .null, "module_name": r["module_name"] ?? .null, "color": r["color"] ?? .null,
                "url": r["url"] ?? .null, "file_id": .null, "page": .null, "confirmed": true, "hidden": false, "user_time": false,
                "overdue": .bool(LocalModules.truthy(r["overdue"])),
            ])
        }
        for m in try c.rows("""
            SELECT id, name, color, exam_date FROM modules WHERE exam_date >= ? AND exam_date <= ? AND COALESCE(active, 1)=1 ORDER BY exam_date
            """, [.text(from), .text(to)]) {
            if let mid = moduleID, m["id"]?.int != mid { continue }
            guard let day = m["exam_date"]?.string else { continue }
            items.append([
                "id": .string("exam-\(m["id"]?.int ?? 0)"), "source": "modul", "detected": false, "date": .string(PyText.slice(day, 0, 10)),
                "time": .null, "kind": "klausur", "kind_label": "Klausur", "title": .string("Klausur \(LocalTimetable.text(m["name"]))"),
                "full_title": .string("Klausur \(LocalTimetable.text(m["name"]))"), "origin": "Klausurtermin im Modul",
                "course_id": .null, "course_title": .null, "module_id": m["id"] ?? .null, "module_name": m["name"] ?? .null,
                "color": m["color"] ?? .null, "url": .null, "file_id": .null, "page": .null, "confirmed": true, "hidden": false,
                "user_time": false, "overdue": false,
            ])
        }
        for i in items.indices { withDays(&items[i], today: t) }
        items = items.enumerated().sorted { a, b in
            let da = a.element["due_at"]?.string ?? "", db = b.element["due_at"]?.string ?? ""
            let xa = PyText.slice(da, 0, 10), xb = PyText.slice(db, 0, 10)
            if xa != xb { return xa < xb }
            if da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element)
        return ["items": .array(items.map(JSONValue.object)), "hidden": .number(Double(hiddenCount)), "today": .string(from),
                "refreshed": .bool(refreshed)]
    }

    // MARK: - Entscheidungen

    /// Termin ausblenden ("stimmt nicht"), wieder zeigen, bestaetigen oder Uhrzeit setzen (`time`: .some(nil) loescht
    /// die eigene). Gilt fuer alle Kurse des angezeigten Termins und bleibt beim Neuberechnen. nil: Termin unbekannt.
    static func update(_ c: SQLiteConnection, id: String, hidden: Bool?, confirmed: Bool?, time: String??, clock: UniFlowClock) throws -> [String: JSONValue]? {
        try ensureTables(c)
        guard let g = try groups(c, from: "0000-00-00", to: "9999-99-99").first(where: { $0.id == id }) else { return nil }
        for key in g.keys {
            try c.execute("INSERT OR IGNORE INTO due_choices(key, hidden, confirmed, time, updated_at) VALUES (?, 0, 0, NULL, ?)",
                          [.text(key), .text(clock.nowISO)])
            if let hidden { try c.execute("UPDATE due_choices SET hidden=?, updated_at=? WHERE key=?", [.integer(hidden ? 1 : 0), .text(clock.nowISO), .text(key)]) }
            if let confirmed {
                try c.execute("UPDATE due_choices SET confirmed=?, updated_at=? WHERE key=?", [.integer(confirmed ? 1 : 0), .text(clock.nowISO), .text(key)])
            }
            if let time { try c.execute("UPDATE due_choices SET time=?, updated_at=? WHERE key=?", [SQLiteValue(time), .text(clock.nowISO), .text(key)]) }
        }
        guard let fresh = try groups(c, from: g.date, to: g.date).first(where: { $0.id == id }) else { return nil }
        var x = json(fresh)
        withDays(&x, today: LocalTimetable.today(clock))
        return x
    }
}

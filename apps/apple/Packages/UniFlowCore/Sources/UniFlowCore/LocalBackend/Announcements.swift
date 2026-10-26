import Foundation

/// Ankuendigungen der Lehrenden (Learnweb-Ankuendigungsforen, Stud.IP-Ankuendigungen) mit erkannten Terminen wie
/// app/announcements.py. Lehrende schreiben Ausfaelle, Raumwechsel, Online-Termine oder Abgaben oft nur als Text in
/// eine Ankuendigung. Die Texte werden gespeichert und die darin genannten Tage erkannt (`extractDates`); die App
/// zeigt sie als Hinweis an den Kalendertagen und auf der Startseite und aendert nie selbst Termine (ein Text ist
/// keine verlaessliche Absage). Tabelle `announcements` (Schema wie am PC), `dates` als JSON-Liste.
///
/// Quellen, alle nur lesend: Learnweb mit Schluessel (REST mod_forum_get_forums_by_courses ->
/// mod_forum_get_forum_discussions, Typ "news"), Learnweb ohne Schluessel (die Forumsseiten), Stud.IP
/// (JSON-API /courses/{id}/news). Abruf: `LearnwebAPI.announcements`, `StudIPClient.courseNews`.
/// Erwartungswerte: packages/shared-contracts/fixtures/hildesheim/expected.json (announcement-dates, forum-*).
public enum Announcements {

    /// Eine Ankuendigung in der Form von `make` (Zeile der Tabelle `announcements`)
    public struct Item: Sendable, Equatable {
        public let id: String
        public let source: String
        public let courseID: String?
        public let title: String
        public let text: String
        public let author: String
        public let postedAt: String
        public let url: String?
        public let discussion: String?
        /// [{date, time, kind, snippet}]
        public let dates: [JSONValue]
    }

    /// `KIND_LABELS`
    public static let kindLabels: [String: String] = ["ausfall": "Ausfall?", "verlegt": "Verlegung?", "raum": "Raum", "pruefung": "Prüfung",
                                                      "frist": "Frist", "online": "Online", "termin": "Termin"]

    /// `MONTHS` in der Reihenfolge von app/announcements.py (sie bestimmt die Alternative im Muster)
    static let months: [(String, Int)] = [
        ("januar", 1), ("jan", 1), ("februar", 2), ("feb", 2), ("märz", 3), ("maerz", 3), ("mär", 3), ("april", 4), ("apr", 4), ("mai", 5),
        ("juni", 6), ("jun", 6), ("juli", 7), ("jul", 7), ("august", 8), ("aug", 8), ("september", 9), ("sep", 9), ("sept", 9),
        ("oktober", 10), ("okt", 10), ("november", 11), ("nov", 11), ("dezember", 12), ("dez", 12),
    ]
    static let monthByName: [String: Int] = Dictionary(months, uniquingKeysWith: { a, _ in a })

    // Jahr: vierstellig (auch mit Leerzeichen) oder zweistellig direkt angehaengt ("12.11.26"); "28.10. 10-12 Uhr" ist kein Jahr
    private static let numDateRE = HText.regex(#"(?<![\d.])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(20\d{2})(?!\d)|(\d{2})(?!\d))?(?![\d])"#)
    private static let nameDateRE: NSRegularExpression = {
        // "|".join(sorted(MONTHS, key=len, reverse=True)): laengste zuerst, bei gleicher Laenge die Reihenfolge der Tabelle
        let names = months.map(\.0).enumerated().sorted { a, b in
            a.element.unicodeScalars.count != b.element.unicodeScalars.count ? a.element.unicodeScalars.count > b.element.unicodeScalars.count : a.offset < b.offset
        }.map(\.element)
        return HText.regex(#"(?<![\d.])(\d{1,2})\.\s?("# + names.joined(separator: "|") + #")\.?(?:\s+((?:20)\d{2}))?(?![a-zäöü])"#, [.caseInsensitive])
    }()
    private static let timeRE = HText.regex(#"^[^.!?\n]{0,25}?\b(?:um|ab|von)?\s*(\d{1,2})(?:[:.](\d{2}))?\s*(?:Uhr|h\b|-|–|bis)"#, [.caseInsensitive])
    /// `KINDS`: Reihenfolge = Vorrang
    private static let kinds: [(String, NSRegularExpression)] = [
        ("ausfall", HText.regex(#"f(?:ä|ae)llt\s+(?:\w+\s+){0,4}aus\b|entf(?:ä|ae)llt|ausfall|abgesagt|findet\s+(?:\w+\s+)?nicht\s+statt|keine\s+(?:vorlesung|sitzung|veranstaltung|übung|uebung|seminar)"#, [.caseInsensitive])),
        ("verlegt", HText.regex(#"verlegt|verschoben|stattdessen|ersatztermin|nachgeholt|nachholtermin"#, [.caseInsensitive])),
        ("raum", HText.regex(#"\braum\b|raumwechsel|raumänderung|h(?:ö|oe)rsaal|seminarraum|\bin\s+(?:raum|geb(?:ä|ae)ude)"#, [.caseInsensitive])),
        ("frist", HText.regex(#"abgabe|frist|deadline|einreichen|hochladen|bis\s+(?:zum|spätestens|spaetestens)"#, [.caseInsensitive])),
        ("pruefung", HText.regex(#"klausur|pr(?:ü|ue)fung|hausarbeit|portfolio|referat"#, [.caseInsensitive])),
        ("online", HText.regex(#"online|zoom|bigbluebutton|\bbbb\b|webex|digital|videokonferenz"#, [.caseInsensitive])),
    ]
    private static let sentenceEndRE = HText.regex(#"\.(?:\s|$)(?![\d])"#)
    private static let clauseEndRE = HText.regex(#"[,;]"#)
    private static let spacesRE = PyRegex(#"[ \t]+"#)
    private static let newlineRE = PyRegex(#"\s*\n\s*"#)
    private static let whitespaceRE = PyRegex(#"\s+"#)
    private static let discussionRE = HText.regex(#"data-discussionid="(\d+)"|/mod/forum/discuss\.php\?d=(\d+)"#)

    // MARK: Text aus HTML

    /// Elemente, vor denen `_Text` einen Zeilenumbruch setzt
    private static let blockTags: Set<String> = ["br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"]

    /// `html_to_text(s)`: Text einer HTML-Ankuendigung; Zeilenumbrueche vor Bloecken, Entities aufgeloest,
    /// Leerraum zusammengezogen
    public static func htmlToText(_ s: String?) -> String {
        var parts: [String] = []
        for t in HTMLTokenizer.tokens(s ?? "") {
            switch t {
            case .start(let name, _): if blockTags.contains(name) { parts.append("\n") }
            case .text(let data): parts.append(data)
            case .raw(_, let data): parts.append(data)
            case .end: break
            }
        }
        // html.unescape noch einmal auf dem Ganzen (wie in Python: die Parserdaten sind schon aufgeloest)
        var text = QISParser.decodeEntities(parts.joined()).replacingOccurrences(of: "\u{A0}", with: " ")
        text = spacesRE.sub(text, " ")
        return PyText.strip(newlineRE.sub(text, "\n"))
    }

    // MARK: Termine im Text

    private struct Scalars {
        let text: String
        let u: [Unicode.Scalar]
        /// UTF-16-Position -> Index in `u`
        let utf16ToIndex: [Int]

        init(_ text: String) {
            self.text = text
            u = Array(text.unicodeScalars)
            var map: [Int] = []
            map.reserveCapacity(text.utf16.count + 1)
            for (i, s) in u.enumerated() { for _ in 0..<s.utf16.count { map.append(i) } }
            map.append(u.count)
            utf16ToIndex = map
        }

        func range(_ r: NSRange) -> (Int, Int) { (utf16ToIndex[r.location], utf16ToIndex[r.location + r.length]) }
        func slice(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(u[max(0, min(a, u.count))..<max(0, min(max(a, b), u.count))])) }
        func isDigit(_ i: Int) -> Bool {
            let t = u[i].properties.numericType
            return t == .decimal || t == .digit
        }
        /// `text.rfind(c, 0, end)`: -1 ohne Treffer
        func rfind(_ c: Unicode.Scalar, from: Int = 0, before end: Int) -> Int {
            var i = min(end, u.count) - 1
            while i >= max(from, 0) { if u[i] == c { return i }; i -= 1 }
            return -1
        }
        /// `text.find(c, start)`: -1 ohne Treffer
        func find(_ c: Unicode.Scalar, from start: Int) -> Int {
            var i = max(start, 0)
            while i < u.count { if u[i] == c { return i }; i += 1 }
            return -1
        }
    }

    /// `_sent_bounds`: Satzgrenzen um [start, end): Index vor dem Satzanfang, Index des Satzendes (Punkte in
    /// Datumsangaben zaehlen nicht)
    private static func sentenceBounds(_ s: Scalars, _ start: Int, _ end: Int) -> (Int, Int) {
        var a = ".!?\n".unicodeScalars.map { s.rfind($0, before: start) }.max() ?? -1
        while a > 0, s.u[a] == ".", s.isDigit(a - 1) {      // "12.11." ist kein Satzende
            a = ".!?\n".unicodeScalars.map { s.rfind($0, before: a) }.max() ?? -1
        }
        var candidates = "!?\n".unicodeScalars.map { s.find($0, from: end) }.filter { $0 != -1 }
        let tail = s.slice(end, s.u.count)
        if let m = sentenceEndRE.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) {
            candidates.append(end + Scalars(tail).range(m.range).0)
        }
        return (a, candidates.min() ?? s.u.count)
    }

    /// `_sentence`: Satz um das Datum, hoechstens 180 Zeichen
    private static func sentence(_ s: Scalars, _ start: Int, _ end: Int) -> String {
        let (a, b) = sentenceBounds(s, start, end)
        let text = PyText.strip(s.slice(a + 1, b + 1))
        guard PyText.length(text) > 180 else { return text }
        return PyText.strip(PyText.slice(text, 0, 177)) + "…"      // rstrip: Pythons rstrip; strip ist hier gleich (Anfang schon ohne Leerraum)
    }

    /// `_clause`: Satzteil um ein Datum: innerhalb des Satzes vom letzten Komma/Semikolon/Doppelpunkt davor bis zum
    /// naechsten danach
    private static func clause(_ s: Scalars, _ start: Int, _ end: Int) -> String {
        let (sa, sb) = sentenceBounds(s, start, end)
        let a = ([sa] + ",;:".unicodeScalars.map { s.rfind($0, from: sa + 1, before: start) }).max() ?? sa
        let between = s.slice(end, sb)
        var stop = sb
        if let m = clauseEndRE.firstMatch(in: between, range: NSRange(location: 0, length: (between as NSString).length)) {
            stop = end + Scalars(between).range(m.range).0
        }
        return s.slice(a + 1, stop)
    }

    /// `_kind(sentence)`: Art aus dem Satz, sonst "termin"
    private static func kind(of sentence: String) -> String {
        let range = NSRange(location: 0, length: (sentence as NSString).length)
        for (k, re) in kinds where re.firstMatch(in: sentence, range: range) != nil { return k }
        return "termin"
    }

    /// `_year(day, month, posted)`: Jahr ohne Angabe: das Jahr, in dem der Tag zwischen 30 Tagen vor und 300 Tagen
    /// nach der Ankuendigung liegt (sonst keins)
    private static func year(day: Int, month: Int, posted: Int) -> Int? {
        let py = BerlinClock.civil(posted).year
        for y in [py - 1, py, py + 1] {
            guard (1...12).contains(month), day >= 1, day <= BerlinClock.daysInMonth(year: y, month: month) else { continue }
            let d = BerlinClock.dayNumber(year: y, month: month, day: day)
            if posted - 30 <= d, d <= posted + 300 { return y }
        }
        return nil
    }

    /// `extract_dates(text, posted)`: Tage, die in einer Ankuendigung genannt werden: [{date, time, kind, snippet}],
    /// nach Datum sortiert, ohne Doppelte. Erkannt: 12.11., 12.11.26, 12.11.2026, 12. November (2026). Uhrzeit
    /// direkt danach (14 Uhr, 14:15, 14.15 Uhr). Art aus dem Satz (Ausfall, Verlegung, Raum, Pruefung, Frist,
    /// Online, sonst Termin). Tage mehr als 30 Tage vor der Ankuendigung werden ignoriert. `posted`: Tagesnummer.
    public static func extractDates(_ text: String, posted: Int) -> [JSONValue] {
        let s = Scalars(text)
        var order: [(String, String?)] = []
        var found: [String: [String: JSONValue]] = [:]
        func key(_ d: String, _ t: String?) -> String { d + "|" + (t ?? "-") }
        let full = NSRange(location: 0, length: (text as NSString).length)
        for (re, named) in [(numDateRE, false), (nameDateRE, true)] {
            for m in re.matches(in: text, range: full) {
                func group(_ i: Int) -> String? {
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : (text as NSString).substring(with: r)
                }
                guard let g1 = group(1), let day = Int(g1), let g2 = group(2) else { continue }
                let month: Int
                if named {
                    guard let mo = monthByName[PyText.lower(g2)] else { continue }
                    month = mo
                } else {
                    guard let mo = Int(g2) else { continue }
                    month = mo
                }
                let y = group(3) ?? (named ? nil : group(4))
                let (mStart, mEnd) = s.range(m.range)
                let yearValue: Int?
                if let y {
                    guard let n = Int(y) else { continue }
                    yearValue = y.unicodeScalars.count == 2 ? 2000 + n : n
                } else {
                    yearValue = year(day: day, month: month, posted: posted)
                }
                guard let yr = yearValue, yr != 0, (1...12).contains(month), day >= 1,
                      day <= BerlinClock.daysInMonth(year: yr, month: month) else { continue }
                let d = BerlinClock.dayNumber(year: yr, month: month, day: day)
                if d < posted - 30 || d > posted + 400 { continue }
                let tail = s.slice(mEnd, mEnd + 40)
                var t: String?
                if let tm = timeRE.firstMatch(in: tail, options: [.anchored], range: NSRange(location: 0, length: (tail as NSString).length)) {
                    let ns = tail as NSString
                    let h = Int(ns.substring(with: tm.range(at: 1))) ?? -1
                    let mi = tm.range(at: 2).location == NSNotFound ? nil : ns.substring(with: tm.range(at: 2))
                    if (6...23).contains(h), (Int(mi ?? "0") ?? 60) < 60 { t = String(format: "%02d:", h) + (mi ?? "00") }
                }
                let sent = sentence(s, mStart, mEnd)
                // Art zuerst aus dem Satzteil um das Datum ("Keine Vorlesung am 24.12., stattdessen am 7.1." -> Ausfall, Verlegung)
                var k = kind(of: clause(s, mStart, mEnd))
                if k == "termin" { k = kind(of: sent) }
                let iso = BerlinClock.isoDate(d)
                if found[key(iso, t)] == nil {
                    order.append((iso, t))
                    found[key(iso, t)] = ["date": .string(iso), "time": t.map(JSONValue.string) ?? .null, "kind": .string(k), "snippet": .string(sent)]
                }
            }
        }
        // gleicher Tag mit und ohne Uhrzeit: nur der Eintrag mit Uhrzeit
        let withTime = Set(order.filter { $0.1 != nil }.map(\.0))
        let out = order.filter { $0.1 != nil || !withTime.contains($0.0) }.compactMap { found[key($0.0, $0.1)] }
        return (try? LocalTimetable.stableSorted(out) { a, b in
            let da = a["date"]?.string ?? "", db = b["date"]?.string ?? ""
            if da != db { return PyText.less(da, db) }
            return PyText.less(a["time"]?.string ?? "", b["time"]?.string ?? "")
        })?.map(JSONValue.object) ?? out.map(JSONValue.object)
    }

    // MARK: Learnweb-Forumsseiten (Weg ohne Schluessel)

    /// Beitrag einer Diskussionsseite (discuss.php) wie `_ForumPosts`
    public struct ForumPost: Sendable, Equatable {
        public var id: Int
        public var subject = ""
        public var author = ""
        public var postedAt = ""
        public var html = ""
    }

    /// `parse_discussion_html(page_html)`: Beitraege einer Diskussionsseite: id, Betreff, Autor, Zeit, Text (HTML).
    /// Tiefe wie Pythons HTMLParser: ein Start-Tag ohne Schraegstrich zaehlt hoch, `<br/>` wieder herunter.
    public static func parseDiscussionHTML(_ pageHTML: String) -> [ForumPost] {
        var posts: [ForumPost] = []
        var cur: Int?                               // Index in posts
        var capture: String?
        var depth = 0
        var buf: [String] = []
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;")
        }
        func start(_ tag: String, _ a: [String: String]) {
            if tag == "article", let pid = a["data-post-id"], !pid.isEmpty {
                posts.append(ForumPost(id: Int(pid.trimmingCharacters(in: .whitespaces)) ?? 0))
                cur = posts.count - 1
                return
            }
            guard let i = cur else { return }
            if capture != nil {
                depth += 1
                if capture == "content" { buf.append("<\(tag)>") }
                return
            }
            if a["data-region-content"] == "forum-post-core-subject" {
                capture = "subject"; depth = 1; buf = []
            } else if tag == "div", (a["id"] ?? "").hasPrefix("post-content-") {
                capture = "content"; depth = 1; buf = []
            } else if tag == "time", let dt = a["datetime"], !dt.isEmpty, posts[i].postedAt.isEmpty {
                posts[i].postedAt = dt
            } else if tag == "a", (a["href"] ?? "").contains("/user/view.php"), posts[i].author.isEmpty {
                capture = "author"; depth = 1; buf = []
            }
        }
        func end(_ tag: String) {
            guard capture != nil, let i = cur else { return }
            depth -= 1
            if depth > 0 {
                if capture == "content" { buf.append("</\(tag)>") }
                return
            }
            let val = buf.joined()
            switch capture {
            case "content": posts[i].html = val
            case "subject": posts[i].subject = PyText.strip(whitespaceRE.sub(val, " "))
            default: posts[i].author = PyText.strip(whitespaceRE.sub(val, " "))
            }
            capture = nil
        }
        func data(_ text: String) {
            guard capture != nil else { return }
            buf.append(capture == "content" ? escape(text) : text)
        }
        for t in HTMLTokenizer.tokens(pageHTML, selfClosingEnds: true) {
            switch t {
            case .start(let name, let a): start(name, a)
            case .end(let name): end(name)
            case .text(let s): data(s)
            case .raw(let name, let s): start(name, [:]); data(s); end(name)
            }
        }
        return posts.filter { $0.id != 0 }
    }

    /// `discussion_links(view_html)`: Diskussions-IDs der Forumsuebersicht (view.php), in Reihenfolge der Seite
    public static func discussionLinks(_ viewHTML: String) -> [Int] {
        var seen: [Int] = []
        let ns = viewHTML as NSString
        for m in discussionRE.matches(in: viewHTML, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard r.location != NSNotFound, let d = Int(ns.substring(with: r)) else { continue }
            if !seen.contains(d) { seen.append(d) }
        }
        return seen
    }

    /// `is_news_forum(body_class)`
    public static func isNewsForum(bodyClass: String?) -> Bool {
        (bodyClass ?? "").split(whereSeparator: { $0.isWhitespace }).contains("forumtype-news")
    }

    // MARK: Einheitliche Form

    /// `_posted_date(posted_at)`: Tag der Ankuendigung aus dem ISO-Zeitpunkt, sonst heute
    static func postedDay(_ postedAt: String, today: Int) -> Int {
        let u = Array(postedAt.unicodeScalars)
        guard u.count >= 10, u.count == 10 || u[10] == "T" || u[10] == " ",
              let d = BerlinClock.parseISODate(String(String.UnicodeScalarView(u[0..<10]))) else { return today }
        return d
    }

    /// `make(aid, source, course_id, title, body_html, author, posted_at, url, discussion)`
    public static func make(id: String, source: String, courseID: String?, title: String, bodyHTML: String, author: String,
                            postedAt: String, url: String?, discussion: String? = nil, today: Int) -> Item {
        let text = htmlToText(bodyHTML)
        let cleanTitle = htmlToText(title)
        let shortTitle = PyText.slice(cleanTitle, 0, 200)
        return Item(id: id, source: source, courseID: courseID, title: shortTitle.isEmpty ? "Ankündigung" : shortTitle,
                    text: PyText.slice(text, 0, 6000), author: PyText.slice(author, 0, 120), postedAt: postedAt, url: url,
                    discussion: discussion, dates: extractDates("\(cleanTitle)\n\(text)", posted: postedDay(postedAt, today: today)))
    }

    /// `from_moodle_discussion(d, course_id, base)`: REST mod_forum_get_forum_discussions -> Ankuendigung (erster
    /// Beitrag der Diskussion); nil, wenn die Kennungen fehlen (Python: KeyError)
    public static func fromMoodleDiscussion(_ d: JSONValue, courseID: String, base: String, today: Int) -> Item? {
        guard let id = d["id"]?.int, let discussion = d["discussion"]?.int else { return nil }
        let ts = (d["created"]?.int).flatMap { $0 != 0 ? $0 : nil } ?? d["timemodified"]?.int ?? 0
        let posted = Learnweb.localISO(ts) + ":00"
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        let subject = [d["subject"]?.string, d["name"]?.string].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return make(id: "lw-post-\(id)", source: "learnweb", courseID: courseID, title: subject, bodyHTML: d["message"]?.string ?? "",
                    author: d["userfullname"]?.string ?? "", postedAt: posted, url: "\(b)/mod/forum/discuss.php?d=\(discussion)",
                    discussion: "lw-d-\(discussion)", today: today)
    }

    /// `from_forum_post(p, course_id, base, discussion_id)`
    public static func fromForumPost(_ p: ForumPost, courseID: String, base: String, discussionID: Int, today: Int) -> Item {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return make(id: "lw-post-\(p.id)", source: "learnweb", courseID: courseID, title: p.subject, bodyHTML: p.html, author: p.author,
                    postedAt: p.postedAt, url: "\(b)/mod/forum/discuss.php?d=\(discussionID)#p\(p.id)", discussion: "lw-d-\(discussionID)",
                    today: today)
    }

    /// `from_studip_news(n, course_id, studip_base)`: nil ohne Kennung (Python: KeyError)
    public static func fromStudIPNews(_ n: JSONValue, courseID: String, studipBase: String, today: Int) -> Item? {
        guard let id = n["id"]?.string ?? n["id"]?.int.map(String.init) else { return nil }
        let a = n["attributes"] ?? .null
        let posted = [a["publication-start"]?.string, a["mkdate"]?.string].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return make(id: "sp-news-\(id)", source: "studip", courseID: courseID, title: a["title"]?.string ?? "",
                    bodyHTML: a["content"]?.string ?? "", author: "", postedAt: posted,
                    url: "\(studipBase)/dispatch.php/course/overview?cid=\(courseID)", today: today)
    }

    // MARK: Speicher

    public struct StoreResult: Sendable, Equatable {
        public var new = 0, total = 0, removed = 0
    }

    /// `store(conn, items, source, fetched_at, course_ids)`: Ankuendigungen speichern (Upsert). Nur fuer vollstaendig
    /// gelesene Kurse (`courseIDs`) werden geloeschte entfernt; Learnweb-Beitraege bekannter Diskussionen (nicht
    /// erneut gelesen) bleiben stehen.
    public static func store(_ c: SQLiteConnection, _ items: [Item], source: String, fetchedAt: String, courseIDs: [String]? = nil) throws -> StoreResult {
        var known = Set<String>()
        for r in try c.rows("SELECT id FROM announcements WHERE source=?", [.text(source)]) { if let id = r["id"]?.string { known.insert(id) } }
        for a in items {
            try c.execute("""
                INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, discussion, dates, fetched_at)
                                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                                        ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title, text=excluded.text,
                                          author=excluded.author, posted_at=excluded.posted_at, url=excluded.url, discussion=excluded.discussion,
                                          dates=excluded.dates, fetched_at=excluded.fetched_at
                """, [.text(a.id), .text(source), SQLiteValue(a.courseID), .text(a.title), .text(a.text), .text(a.author), .text(a.postedAt),
                      SQLiteValue(a.url), SQLiteValue(a.discussion), .text(JSONValue.array(a.dates).jsonString()), .text(fetchedAt)])
        }
        var removed = 0
        if let courseIDs {
            let ids = items.map(\.id)
            let marks = ids.isEmpty ? "''" : Array(repeating: "?", count: ids.count).joined(separator: ",")
            for cid in courseIDs {
                removed += try c.execute("DELETE FROM announcements WHERE source=? AND course_id=? AND id NOT IN (\(marks))",
                                         [.text(source), .text(cid)] + ids.map(SQLiteValue.text))
            }
        }
        return StoreResult(new: Set(ids(items)).subtracting(known).count, total: items.count, removed: removed)
    }

    private static func ids(_ items: [Item]) -> [String] { items.map(\.id) }

    /// `known_discussions(conn)`
    public static func knownDiscussions(_ c: SQLiteConnection) throws -> Set<String> {
        Set(try c.rows("SELECT DISTINCT discussion FROM announcements WHERE discussion IS NOT NULL").compactMap { $0["discussion"]?.string })
    }

    // MARK: Lesen

    /// `_row(r)`: Zeile mit Kurs und Farbe als Antwortobjekt, `dates` aus dem JSON-Text
    static func row(_ r: [String: JSONValue]) throws -> [String: JSONValue] {
        let text = LocalTimetable.or(r["dates"], "[]")
        guard let s = text.string, let dates = try? JSONValue.parse(Data(s.utf8)) else {
            throw LocalHTTPError(status: 500, message: "dates ist kein JSON")
        }
        return ["id": r["id"] ?? .null, "source": r["source"] ?? .null, "course_id": r["course_id"] ?? .null,
                "course_title": r["course_title"] ?? .null, "color": r["color"] ?? .null, "title": r["title"] ?? .null,
                "text": r["text"] ?? .null, "author": r["author"] ?? .null, "posted_at": r["posted_at"] ?? .null,
                "url": r["url"] ?? .null, "dates": dates]
    }

    private static let selectRows = """
        SELECT a.*, c.title AS course_title, m.color FROM announcements a LEFT JOIN courses c ON c.id=a.course_id
                                    LEFT JOIN modules m ON m.id=c.module_id
        """

    /// `recent(conn, days, limit, today)`: Ankuendigungen der letzten Tage und solche mit kommenden Terminen,
    /// neueste zuerst
    static func recent(_ c: SQLiteConnection, days: Int = 30, limit: Int = 20, today: Int) throws -> [JSONValue] {
        let t = BerlinClock.isoDate(today)
        let since = BerlinClock.isoDate(today - days)
        var out: [JSONValue] = []
        for r in try c.rows(selectRows + " ORDER BY a.posted_at DESC") {
            var x = try row(r)
            let upcoming = (x["dates"]?.array ?? []).filter { d in
                guard let day = d["date"]?.string else { return false }
                return !PyText.less(day, t)
            }
            guard let posted = x["posted_at"]?.string else { throw LocalHTTPError(status: 500, message: "posted_at ist kein Text") }
            if !PyText.less(PyText.slice(posted, 0, 10), since) || !upcoming.isEmpty {
                x["upcoming"] = .array(upcoming)
                out.append(.object(x))
            }
        }
        return Array(out.prefix(limit))
    }

    /// `by_day(conn, start, end)`: erkannte Termine aus Ankuendigungen je Kalendertag (Lernkalender, Stundenplan)
    static func byDay(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [String: [JSONValue]] {
        let lo = BerlinClock.isoDate(start), hi = BerlinClock.isoDate(end)
        var out: [String: [JSONValue]] = [:]
        for r in try c.rows(selectRows + " WHERE a.dates <> '[]'") {
            let x = try row(r)
            for d in x["dates"]?.array ?? [] {
                guard let day = d["date"]?.string, !PyText.less(day, lo), !PyText.less(hi, day) else { continue }
                let kind = d["kind"]?.string ?? ""
                out[day, default: []].append([
                    "announcement_id": x["id"] ?? .null, "title": x["title"] ?? .null, "kind": d["kind"] ?? .null,
                    "kind_label": .string(kindLabels[kind] ?? "Termin"), "time": d["time"] ?? .null, "snippet": d["snippet"] ?? .null,
                    "url": x["url"] ?? .null, "course_title": x["course_title"] ?? .null, "color": x["color"] ?? .null,
                    "source": x["source"] ?? .null,
                ])
            }
        }
        // v.sort(key=lambda n: (n["time"] or "", n["title"])), stabil
        for (day, list) in out {
            out[day] = try LocalTimetable.stableSorted(list) { a, b in
                let ta = LocalTimetable.or(a["time"], "").string ?? "", tb = LocalTimetable.or(b["time"], "").string ?? ""
                if ta != tb { return PyText.less(ta, tb) }
                guard let x = a["title"]?.string, let y = b["title"]?.string else { throw LocalHTTPError(status: 500, message: "Titel ist kein Text") }
                return PyText.less(x, y)
            }
        }
        return out
    }
}

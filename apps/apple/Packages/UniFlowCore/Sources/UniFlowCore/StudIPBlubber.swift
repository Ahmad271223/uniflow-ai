import Foundation

// Blubber aus Stud.IP (Kurs-Chats, 03.11.2026; die Geraete-Probe fand die Routen an der LUH). Nur lesend, nur auf diesem
// Geraet (Tabelle studip_blubber, nicht im Geraete-Abgleich, nicht in der Community, keine Quelle der KI).
//
// Gespeichert wird je Beitrag: Kurs, Thread, Rolle der Verfasserin (Lehrende, Tutor/in, Studierende, du; nie ein Name),
// Text (hoechstens `maxText` Zeichen, Erwaehnungen und Zitate entfernt), Zeitpunkt und der Link in Stud.IP.
//
// Welche Route? Geprueft am Stud.IP-Quelltext (gitlab.studip.de/studip/studip, main, Stand 03.11.2026):
//  - `courses/{id}/blubber-threads` ruft `BlubberThread::findBySeminar` -> `findByContext`, und das LEGT den
//    Standard-Thread des Kurses AN, wenn es ihn noch nicht gibt (lib/models/BlubberThread.php, findByContext:
//    `$coursethread->store()`, Verfasser ist der anfragende Nutzer). Das waere ein Schreibzugriff in Stud.IP; die App
//    nutzt die Route darum nicht.
//  - `blubber-threads` (alle eigenen: Kurse, Einrichtungen, der Stud.IP-weite Thread, Erwaehnungen) ruft
//    `findMyGlobalThreads`: eine Abfrage, nach letzter Aktivitaet sortiert, mit `latest-activity` je Thread. Stud.IP
//    raeumt dort vorab leere, ueber eine Stunde alte Threads ohne Beitrag auf (dieselbe Aufraeumarbeit wie beim Oeffnen
//    von Blubber im Browser); Inhalte oder Gesehen-Marken des Nutzers aendert das nicht.
//  - `blubber-threads/{id}/comments` (CommentsByThreadIndex): reine Abfrage (findBySQL).
//  - Gesehen-Marken: das Schema liest `getLastVisit`/`countUnseenComments` nur (object_get_visit, SELECT). Gesetzt
//    werden sie allein von `markAsRead` (Browser: blubber/index, course/messenger/course) und von PATCH
//    `blubber-threads/{id}` mit `visited-at` (ThreadsUpdate). Beides ruft die App nie auf.
//
// Anfragen: eine Liste, dann hoechstens `maxThreads` Kommentar-Listen, nur fuer Threads, deren `latest-activity` sich
// seit dem letzten Lesen geaendert hat. Genommen werden Threads der gewaehlten Kurse und der Stud.IP-weite Thread
// ("global", ohne Kurs); private Gespraeche und Einrichtungen nie. Antwortet die Liste mit 404/403, merkt sich die App
// das unter `studip_missing_endpoints` ("blubber") und fragt erst nach 30 Tagen wieder.
//
// Keine Python-Entsprechung: der PC-Server liest Blubber nicht (docs/IPAD-STUDIP-SYNC.md, Abschnitt 12).

public enum StudIPBlubber {
    /// Abgleich ein? Entscheidung des Inhabers 03.11.2026: vorerst aus. `GET blubber-threads` raeumt in Stud.IP leere
    /// Threads auf (loescht sie, wie das Oeffnen von Blubber im Browser); das ist kein reines Lesen. Code bleibt fuer spaeter.
    public static var syncEnabled = false
    /// neueste Beitraege je Thread
    public static let perThread = 20
    /// nur Notbremse: Beitraege bleiben ganz (Inhaber 03.11.2026: nie "…")
    public static let maxText = 50000
    /// Kommentar-Listen je Abgleich
    public static let maxThreads = 12
    /// Threads in der Liste (Stud.IP sortiert nach letzter Aktivitaet)
    static let listLimit = 40
    public static let missingName = "blubber"
    /// "neu" fuer die Uebersicht: so viele Tage zurueck
    public static let newDays = 7
    /// Kennung des Stud.IP-weiten Threads
    static let globalID = "global"
    static let activityKey = "studip_blubber_activity"
    static let fetchedKey = "studip_blubber_fetched_at"
    static let api = "jsonapi.php/v1/"
    /// ohne erkennbare Rolle (externer Kontakt, Nutzer nicht mitgeliefert)
    static let unknownRole = "Teilnehmende"
    static let ownRole = "du"

    static let table = """
        CREATE TABLE IF NOT EXISTS studip_blubber (
            id TEXT PRIMARY KEY,
            course_id TEXT,                    -- NULL = Stud.IP-weiter Thread
            thread_id TEXT NOT NULL,
            author_role TEXT NOT NULL,         -- Lehrende, Tutor/in, Studierende, du ... nie ein Name
            text TEXT NOT NULL,                -- ganzer Text ohne Formatierung und Erwaehnungen
            posted_at TEXT,                    -- YYYY-MM-DDTHH:MM:SS, Ortszeit
            url TEXT,                          -- Thread in Stud.IP
            fetched_at TEXT
        )
        """

    /// Ein Thread aus der Liste
    public struct Thread: Sendable, Equatable {
        public let id: String
        /// nil = Stud.IP-weit
        public let courseID: String?
        public let latestActivity: String
        public let url: String
        /// Eroeffnungsbeitrag (Threads mit eigenem Text); der Standard-Thread eines Kurses hat keinen
        public let opening: Post?
    }

    /// Ein Beitrag
    public struct Post: Sendable, Equatable {
        public let id: String
        public let courseID: String?
        public let threadID: String
        public let authorRole: String
        public let text: String
        public let postedAt: String
        public let url: String

        public init(id: String, courseID: String?, threadID: String, authorRole: String, text: String, postedAt: String, url: String) {
            self.id = id
            self.courseID = courseID
            self.threadID = threadID
            self.authorRole = authorRole
            self.text = text
            self.postedAt = postedAt
            self.url = url
        }
    }

    // MARK: Lesen

    static func str(_ v: JSONValue?) -> String { v?.string ?? "" }

    /// Link in Stud.IP wie `BlubberThread::getURL`
    static func threadURL(base: String, threadID: String, courseID: String?) -> String {
        let b = StudIPTexts.base(base)
        if let cid = courseID { return "\(b)/dispatch.php/course/messenger/course/\(threadID)?cid=\(cid)" }
        return "\(b)/dispatch.php/blubber/index/\(threadID)"
    }

    /// Nutzer aus `included` (nur die Rolle wird gelesen)
    static func users(_ included: JSONValue?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for u in included?.array ?? [] where u.object != nil && u["type"]?.string == "users" {
            if let id = StudIPTerms.id(u) { out[id] = StudIPTerms.attrs(u) }
        }
        return out
    }

    /// Rolle statt Name: "du" fuer eigene Beitraege, sonst die globale Rolle (`permission`) wie bei den Nachrichten
    static func role(_ x: JSONValue, users: [String: JSONValue], userID: String) -> String {
        guard let r = StudIPExtras.rel(x, "author"), let ref = r, let id = StudIPTerms.id(ref) else { return unknownRole }
        if !userID.isEmpty, id == userID { return ownRole }
        return StudIPExtras.roleLabels[PyText.lower(str(users[id]?["permission"]))] ?? unknownRole
    }

    /// Erwaehnung, wie Stud.IP sie speichert: `[Vorname Nachname]https://…/dispatch.php/profile?username=x`
    private static let mentionLink = PyRegex(#"\[[^\]\n]*\]\s*\S*dispatch\.php/profile\S*"#)
    private static let profileURL = PyRegex(#"\S*dispatch\.php/profile\?\S*"#)
    private static let quotedMention = PyRegex(#"(?<![\w@])@"[^"\n]*""#)
    private static let profileAnchor = PyRegex(#"(?is)<a\b[^>]*dispatch\.php/profile[^>]*>.*?</a>"#)
    private static let linkMarkup = PyRegex(#"\[([^\]\n]+)\](https?://\S+)"#)
    private static let anySpace = PyRegex(#"\s+"#)

    /// Text eines Beitrags ohne Namen: Erwaehnungen, Profil-Links und Zitate fallen weg, Formatierung wird Text,
    /// hoechstens `maxText` Zeichen
    static func clean(content: String, html: String) -> String {
        var t: String
        if !PyText.strip(content).isEmpty {
            t = mentionLink.sub(content, "@Person")
            t = profileURL.sub(t, "")
            t = quotedMention.sub(t, "@Person")
            t = linkMarkup.subGroup(t, 1)
            t = StudIPTexts.richToText(StudIPTexts.anonymize(t))
        } else {
            t = Announcements.htmlToText(StudIPTexts.anonymize(profileAnchor.sub(html, "@Person")))
            t = quotedMention.sub(profileURL.sub(t, ""), "@Person")
        }
        return StudIPTexts.full(anySpace.sub(t, " "), maxText)
    }

    /// Zeitpunkt (ISO mit Zone) -> "YYYY-MM-DDTHH:MM:SS" Ortszeit Berlin; "" ohne lesbare Zeit
    static func local(_ v: JSONValue?) -> String {
        StudIPTexts.berlinLocal(v).map { $0 + ":00" } ?? ""
    }

    /// Threads aus `blubber-threads`: nur Kurse aus `courseIDs` und der Stud.IP-weite Thread; private Gespraeche,
    /// Einrichtungen und andere oeffentliche Threads nie. Der Name des Threads (bei oeffentlichen und privaten der
    /// Name einer Person) wird nicht gelesen.
    public static func parseThreads(_ j: JSONValue?, courseIDs: Set<String>, userID: String, base: String) -> [Thread] {
        let users = users(j?["included"])
        var out: [Thread] = []
        var seen = Set<String>()
        for x in j?["data"]?.array ?? [] {
            guard x.object != nil, let id = StudIPTerms.id(x), !seen.contains(id) else { continue }
            let a = StudIPTerms.attrs(x)
            let type = PyText.lower(str(a["context-type"]))
            var courseID: String?
            if type == "course" {
                guard let r = StudIPExtras.rel(x, "context"), let ctx = r, let cid = StudIPTerms.id(ctx), courseIDs.contains(cid) else { continue }
                courseID = cid
            } else if !(type == "public" && id == globalID) {
                continue
            }
            seen.insert(id)
            let url = threadURL(base: base, threadID: id, courseID: courseID)
            var opening: Post?
            let text = clean(content: str(a["content"]), html: str(a["content-html"]))
            if !text.isEmpty, id != globalID {
                opening = Post(id: "bt-\(id)", courseID: courseID, threadID: id, authorRole: role(x, users: users, userID: userID),
                               text: text, postedAt: local(a["mkdate"]), url: url)
            }
            out.append(Thread(id: id, courseID: courseID, latestActivity: str(a["latest-activity"]), url: url, opening: opening))
        }
        return out
    }

    /// Beitraege aus `blubber-threads/{id}/comments` (neueste zuerst angefragt), hoechstens `perThread`, ohne leere
    public static func parseComments(_ j: JSONValue?, thread: Thread, userID: String) -> [Post] {
        let users = users(j?["included"])
        var out: [Post] = []
        var seen = Set<String>()
        for x in j?["data"]?.array ?? [] {
            guard x.object != nil, let id = StudIPTerms.id(x), !seen.contains(id) else { continue }
            seen.insert(id)
            let a = StudIPTerms.attrs(x)
            let text = clean(content: str(a["content"]), html: str(a["content-html"]))
            guard !text.isEmpty else { continue }
            out.append(Post(id: "bc-\(id)", courseID: thread.courseID, threadID: thread.id, authorRole: role(x, users: users, userID: userID),
                            text: text, postedAt: local(a["mkdate"]), url: thread.url))
            if out.count >= perThread { break }
        }
        return out
    }

    // MARK: Abruf (Geraet)

    public struct Download: Sendable {
        /// nil = Liste nicht gelesen (fehlt, Fehler, Sitzung); der Bestand bleibt
        public var threads: [Thread]?
        /// neu gelesene Threads -> Beitraege (Eroeffnung und Kommentare); nicht genannte Threads bleiben wie gespeichert
        public var posts: [String: [Post]] = [:]
        /// Thread -> `latest-activity` der gelesenen Threads
        public var activity: [String: String] = [:]
        public var missing: [String: JSONValue] = [:]
        public var sessionExpired = false
        /// Anfragen an Stud.IP in diesem Abruf
        public var requests = 0
        public init() {}
    }

    /// Liste und die geaenderten Threads. Wirft nie. `known`: Thread -> zuletzt gelesene `latest-activity`
    /// (`known(_:)`); `courseIDs`: die gewaehlten aktuellen Kurse.
    public static func fetch(client: StudIPClient, userID: String, courseIDs: [String], missing: [String: JSONValue],
                             known: [String: String], today: String) async -> Download {
        var d = Download()
        d.missing = missing
        guard StudIPExtras.shouldAsk(missing, missingName, today: today) else { return d }
        let base = client.baseString
        let list: JSONValue
        do {
            d.requests += 1
            list = try await client.json("\(api)blubber-threads?page[limit]=\(listLimit)&include=author")
        } catch StudIPError.http(let status, _) {
            d.missing = StudIPExtras.remember(missing, missingName, status: status, today: today)
            return d
        } catch StudIPError.sessionExpired {
            d.sessionExpired = true
            return d
        } catch {
            return d
        }
        guard list["data"]?.array != nil else { return d }
        d.missing = StudIPExtras.remember(missing, missingName, status: 200, today: today)
        let threads = parseThreads(list, courseIDs: Set(courseIDs), userID: userID, base: base)
        d.threads = threads
        var asked = 0
        for t in threads {
            if !t.latestActivity.isEmpty, known[t.id] == t.latestActivity { continue }      // unveraendert
            guard asked < maxThreads else { break }
            asked += 1
            do {
                d.requests += 1
                let j = try await client.json("\(api)blubber-threads/\(t.id)/comments?sort=-mkdate&page[limit]=\(perThread)&include=author")
                guard j["data"]?.array != nil else { continue }
                var posts = parseComments(j, thread: t, userID: userID)
                if let o = t.opening { posts.append(o) }
                d.posts[t.id] = posts
                d.activity[t.id] = t.latestActivity
            } catch StudIPError.sessionExpired {
                d.sessionExpired = true
                return d
            } catch {
                if StudIPScheduleStore.stopsFetch(error) { return d }
                continue                                                // dieser Thread bleibt wie gespeichert
            }
        }
        return d
    }

    // MARK: Speicher

    static func has(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_blubber'") != nil
    }

    static func setting(_ c: SQLiteConnection, _ key: String) throws -> String? {
        try c.scalar("SELECT value FROM settings WHERE key=?", [.text(key)])?.string
    }

    /// Zuletzt gelesene `latest-activity` je Thread (fuer `fetch`)
    public static func known(_ c: SQLiteConnection) throws -> [String: String] {
        guard let raw = try setting(c, activityKey), let v = try? JSONValue.parse(Data(raw.utf8)) else { return [:] }
        return (v.object ?? [:]).compactMapValues(\.string)
    }

    /// Schreibt den Abruf (in einer Transaktion aufrufen): Threads, die nicht mehr in der Liste stehen (Kurs abgewaehlt,
    /// in Stud.IP geloescht), fallen weg; neu gelesene Threads werden ersetzt, die anderen bleiben.
    public static func store(_ d: Download, in c: SQLiteConnection, clock: UniFlowClock) throws {
        try StudIPExtras.saveMissing(c, d.missing)
        guard let threads = d.threads else { return }
        let now = clock.nowISO
        try c.executeScript(table)
        let ids = threads.map(\.id)
        try c.execute("DELETE FROM studip_blubber WHERE thread_id NOT IN (\(StudIPExtras.marks(ids.count)))", ids.map { .text($0) })
        for (tid, posts) in d.posts {
            try c.execute("DELETE FROM studip_blubber WHERE thread_id=?", [.text(tid)])
            for p in posts {
                try c.execute("""
                    INSERT OR REPLACE INTO studip_blubber(id, course_id, thread_id, author_role, text, posted_at, url, fetched_at)
                    VALUES (?,?,?,?,?,?,?,?)
                    """, [.text(p.id), p.courseID.map { .text($0) } ?? .null, .text(p.threadID), .text(p.authorRole), .text(p.text),
                          .text(p.postedAt), .text(p.url), .text(now)])
            }
        }
        var activity = try known(c).filter { ids.contains($0.key) }
        for (k, v) in d.activity { activity[k] = v }
        let json = JSONValue.object(activity.mapValues { .string($0) }).jsonString(sortedKeys: true)
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(activityKey), .text(json)])
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(fetchedKey), .text(now)])
    }

    // MARK: Lesen: Karte, Leser, Neuigkeiten

    static func optional(_ s: String?) -> JSONValue { (s ?? "").isEmpty ? .null : .string(s!) }

    /// Threads mit Zahlen. Filter: Kurs (`course`) oder Modul (`module`), sonst alle (auch der Stud.IP-weite)
    static func threadRows(_ c: SQLiteConnection, courseID: String?, moduleID: Int?, today: Int) throws -> [JSONValue] {
        guard try has(c) else { return [] }
        var sql = """
            SELECT b.thread_id, b.course_id, b.author_role, b.text, b.posted_at, b.url, c.title AS course_title, m.color
            FROM studip_blubber b LEFT JOIN courses c ON c.id=b.course_id LEFT JOIN modules m ON m.id=c.module_id
            """
        var args: [SQLiteValue] = []
        if let courseID, !courseID.isEmpty {
            sql += " WHERE b.course_id=?"
            args.append(.text(courseID))
        } else if let moduleID {
            sql += " WHERE c.module_id=?"
            args.append(.integer(Int64(moduleID)))
        }
        sql += " ORDER BY b.posted_at DESC, b.id"
        let since = BerlinClock.isoDate(today - newDays)
        var order: [String] = []
        var groups: [String: [[String: JSONValue]]] = [:]
        for r in try c.rows(sql, args) {
            let tid = str(r["thread_id"])
            if groups[tid] == nil { order.append(tid) }
            groups[tid, default: []].append(r)
        }
        return order.map { tid in
            let rs = groups[tid] ?? []
            let first = rs[0]                                       // neuester Beitrag
            let fresh = rs.filter { r in
                let p = str(r["posted_at"])
                return !p.isEmpty && !PyText.less(PyText.slice(p, 0, 10), since) && str(r["author_role"]) != ownRole
            }
            let course = str(first["course_title"])
            let where_ = (first["course_id"] ?? .null).isNull ? "Stud.IP-weit" : (course.isEmpty ? "Kurs" : course)
            return ["id": .string(tid), "course_id": first["course_id"] ?? .null, "course_title": .string(where_),
                    "count": .number(Double(rs.count)), "new_count": .number(Double(fresh.count)),
                    "changed": optional(str(first["posted_at"])), "new_at": optional(fresh.first.map { str($0["posted_at"]) }),
                    "preview": .string("\(str(first["author_role"])): \(str(first["text"]))"),
                    "url": optional(str(first["url"])), "color": first["color"] ?? .null]
        }
    }

    /// `GET /api/studip/blubber?course=&module=`: {threads: [{id, course_id, course_title, count, new_count, changed,
    /// preview, url}], count, fetched_at}; Threads mit dem neuesten Beitrag zuerst
    public static func overview(_ c: SQLiteConnection, courseID: String?, moduleID: Int?, today: Int) throws -> JSONValue {
        let threads = try threadRows(c, courseID: courseID, moduleID: moduleID, today: today)
        let total = threads.reduce(0) { $0 + ($1["count"]?.int ?? 0) }
        return ["threads": .array(threads), "count": .number(Double(total)),
                "fetched_at": (try setting(c, fetchedKey)).map(JSONValue.string) ?? .null]
    }

    /// `GET /api/studip/blubber/{thread_id}`: Beitraege zum Lesen, aelteste zuerst; nil = unbekannt
    public static func thread(_ c: SQLiteConnection, id: String) throws -> JSONValue? {
        guard try has(c) else { return nil }
        let rows = try c.rows("""
            SELECT b.id, b.course_id, b.author_role, b.text, b.posted_at, b.url, c.title AS course_title
            FROM studip_blubber b LEFT JOIN courses c ON c.id=b.course_id WHERE b.thread_id=? ORDER BY b.posted_at, b.id
            """, [.text(id)])
        guard let first = rows.first else { return nil }
        let course = str(first["course_title"])
        return ["id": .string(id), "course_id": first["course_id"] ?? .null,
                "course_title": .string((first["course_id"] ?? .null).isNull ? "Stud.IP-weit" : (course.isEmpty ? "Kurs" : course)),
                "url": optional(str(first["url"])),
                "comments": .array(rows.map { r in
                    ["id": r["id"] ?? .null, "role": r["author_role"] ?? .null, "text": r["text"] ?? .null, "posted_at": optional(str(r["posted_at"]))]
                })]
    }

    /// "Blubber in Analysis I: 3 neue Beiträge"
    public static func feedTitle(course: String, global: Bool, count: Int) -> String {
        let n = count == 1 ? "1 neuer Beitrag" : "\(count) neue Beiträge"
        return global ? "Blubber Stud.IP-weit: \(n)" : "Blubber in \(course): \(n)"
    }

    /// Zeilen fuer die Karte "Neuigkeiten": je Thread mit neuen Beitraegen anderer (letzte `newDays` Tage) eine Zeile,
    /// nur aktive Kurse und der Stud.IP-weite Thread
    public static func feedLines(_ c: SQLiteConnection, today: Int) throws -> [JSONValue] {
        guard try has(c) else { return [] }
        let active = Set(try c.rows("SELECT id FROM courses WHERE active=1").compactMap { $0["id"]?.string })
        return try threadRows(c, courseID: nil, moduleID: nil, today: today).compactMap { t in
            let n = t["new_count"]?.int ?? 0
            let global = (t["course_id"] ?? .null).isNull
            guard n > 0, global || active.contains(str(t["course_id"])) else { return nil }
            let course = str(t["course_title"])
            return ["id": .string("blubber-\(str(t["id"]))"), "kind": "blubber", "who": .string(global ? "Stud.IP-weit" : course),
                    "title": .string(feedTitle(course: course, global: global, count: n)), "at": t["new_at"] ?? .string(""),
                    "url": t["url"] ?? .null, "text": t["preview"] ?? .string(""), "chips": .array([]), "source": "studip",
                    "color": t["color"] ?? .null, "thread_id": t["id"] ?? .null]
        }
    }
}

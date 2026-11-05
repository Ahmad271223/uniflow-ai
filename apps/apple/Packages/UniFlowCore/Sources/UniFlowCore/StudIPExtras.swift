import Foundation

// Neuigkeiten aus Stud.IP ueber die Kurse hinaus wie app/studip_extras.py (02.11.2026). Alles nur lesend.
//  - Stud.IP-weite Ankuendigungen (studip/news): in `announcements` ohne Kurs, Fristen und Termine wie Kurs-Ankuendigungen.
//  - Nachrichten (users/{id}/inbox): nur die Liste, nie die Einzelansicht (die koennte als gelesen markieren). Gespeichert
//    werden Absender (Rolle statt Name, wenn Stud.IP sie nennt), Betreff, Datum, ganzer Text (die Liste liefert
//    `message` ganz und markiert nichts; Spalte `preview`), Link auf den
//    Posteingang und die erkannten Tage ohne Satz. Nur auf diesem Geraet (Tabelle studip_messages, nicht im
//    Geraete-Abgleich, nicht in der Community, keine automatische Quelle der KI).
//  - Activity-Stream (users/{id}/activitystream): nur Hinweisquelle "Neu in Kurs X". Kurse damit beim Abgleich zu
//    ueberspringen ist nicht sicher (der Stream nennt nicht jede Aenderung, ist gekuerzt und je Hochschule anders
//    eingestellt); der Abgleich liest weiter jeden Kurs. Teilnehmende, Nachrichten und Personennamen bleiben aussen vor.
//  - Sprechstunden (users/{id}/consultation-bookings): eigene Buchungen als Termine im Planer.
// Endpunkte mit 404/403 merkt sich die App (settings.studip_missing_endpoints) und fragt erst nach `retryDays` wieder.
// Feldnamen ohne Beleg an der LUH werden defensiv gelesen (Annahmen am Feld). Fixture tools/gen-studip-extras-fixture.py.

public enum StudIPExtras {

    static let retryDays = 30
    static let missingKey = "studip_missing_endpoints"
    static let systemSender = "____%system%____"
    /// globale Rolle (Annahme: Attribut `permission` des Nutzers) -> Anzeige statt des Namens
    static let roleLabels: [String: String] = ["dozent": "Lehrende", "tutor": "Tutor/in", "autor": "Studierende", "user": "Studierende",
                                               "admin": "Verwaltung", "root": "Stud.IP-Team"]
    /// Arten im Activity-Stream (Annahme: Attribut `activity-type`), in dieser Reihenfolge; Einzahl, Mehrzahl
    static let activityLabels: [(type: String, one: String, many: String)] = [
        ("documents", "Datei", "Dateien"), ("forum", "Forumsbeitrag", "Forumsbeiträge"), ("wiki", "Wiki-Änderung", "Wiki-Änderungen"),
        ("schedule", "Terminänderung", "Terminänderungen"), ("courseware", "Courseware-Änderung", "Courseware-Änderungen"),
    ]
    static let activityDays = 14
    static let chipKinds: [String: String] = ["frist": "Frist", "pruefung": "Prüfung", "ausfall": "Ausfall?", "verlegt": "Verlegung?"]
    static let consultColor = "#0e9f9a"
    private static let dateTimeRE = PyRegex(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#)

    static let messagesTable = """
        CREATE TABLE IF NOT EXISTS studip_messages (
            id TEXT PRIMARY KEY,
            sender TEXT,                       -- Rolle (Lehrende, Verwaltung ...) oder hoechstens der Name
            subject TEXT,
            preview TEXT,                      -- ganzer Text der Nachricht (Name der Spalte von frueher)
            sent_at TEXT,
            url TEXT,                          -- Posteingang (nicht die Einzelansicht)
            dates TEXT,                        -- erkannte Tage [{date, time, kind}]
            fetched_at TEXT
        )
        """
    static let activityTable = """
        CREATE TABLE IF NOT EXISTS studip_activity (
            id TEXT PRIMARY KEY,
            course_id TEXT NOT NULL,
            type TEXT NOT NULL,
            at TEXT NOT NULL,
            url TEXT,
            fetched_at TEXT
        )
        """
    static let consultTable = """
        CREATE TABLE IF NOT EXISTS studip_consultations (
            id TEXT PRIMARY KEY,
            start TEXT NOT NULL,               -- YYYY-MM-DDTHH:MM:SS, Ortszeit
            end TEXT NOT NULL,
            room TEXT,
            fetched_at TEXT
        )
        """

    // MARK: Hilfen

    static func str(_ v: JSONValue?) -> String { v?.string ?? "" }

    /// `_rel(x, name)`: Ziel einer Beziehung; `.some(nil)` bei `data: null`, nil ohne Beziehung
    static func rel(_ x: JSONValue?, _ name: String) -> JSONValue?? {
        guard let r = x?["relationships"]?[name], r.object != nil, let data = r["data"] else { return nil }
        return .some(data.object != nil ? data : nil)
    }

    // MARK: Fehlende Endpunkte

    /// `should_ask(missing, name, today)`
    public static func shouldAsk(_ missing: [String: JSONValue], _ name: String, today: String) -> Bool {
        guard let seen = missing[name]?.string else { return true }
        guard let t = BerlinClock.parseISODate(today), let s = BerlinClock.parseISODate(PyText.slice(seen, 0, 10)) else { return true }
        return t - s >= retryDays
    }

    /// `remember(missing, name, status, today)`
    public static func remember(_ missing: [String: JSONValue], _ name: String, status: Int, today: String) -> [String: JSONValue] {
        var out = missing
        if status == 403 || status == 404 { out[name] = .string(today) } else if (200..<300).contains(status) { out[name] = nil }
        return out
    }

    public static func loadMissing(_ c: SQLiteConnection) throws -> [String: JSONValue] {
        guard let raw = try c.scalar("SELECT value FROM settings WHERE key=?", [.text(missingKey)])?.string,
              let v = try? JSONValue.parse(Data(raw.utf8)) else { return [:] }
        return v.object ?? [:]
    }

    static func saveMissing(_ c: SQLiteConnection, _ missing: [String: JSONValue]) throws {
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(missingKey), .text(JSONValue.object(missing).jsonString(sortedKeys: true))])
    }

    // MARK: Lesen

    /// `global_news(data, base)`: Ankuendigungen ohne Kurs, Link auf die Startseite
    public static func globalNews(_ data: JSONValue?, base: String, today: Int) -> [Announcements.Item] {
        (data?.array ?? []).compactMap { n in
            guard n.object != nil, let id = StudIPTerms.id(n) else { return nil }
            let a = StudIPTerms.attrs(n)
            let posted = [str(a["publication-start"]), str(a["mkdate"])].first { !$0.isEmpty } ?? ""
            return Announcements.make(id: "sp-news-\(id)", source: "studip", courseID: nil, title: str(a["title"]), bodyHTML: str(a["content"]),
                                      author: "", postedAt: posted, url: "\(base)/dispatch.php/start", today: today)
        }
    }

    /// Gelesene Nachricht (nur Listenfelder)
    public struct Message: Sendable, Equatable {
        public let id, sender, subject, preview, sentAt, url: String
        /// [{date, time, kind}]
        public let dates: [JSONValue]

        public var json: JSONValue {
            ["id": .string(id), "sender": .string(sender), "subject": .string(subject), "preview": .string(preview),
             "sent_at": .string(sentAt), "url": .string(url), "dates": .array(dates)]
        }
    }

    /// `sender_label(m, users)`: Systemnachricht "Stud.IP", sonst die Rolle, sonst "Absender" (nie der Name)
    static func senderLabel(_ m: JSONValue, users: [String: JSONValue]) -> String {
        guard let s = rel(m, "sender") else { return "" }
        guard let ref = s else { return "Stud.IP" }
        if ref["id"]?.string == systemSender { return "Stud.IP" }
        let a = users[StudIPTerms.id(ref) ?? ""] ?? .object([:])
        if let role = roleLabels[PyText.lower(str(a["permission"]))] { return role }
        return "Absender"                                     // ohne Rolle nie der Name (2.11.2026: keine Personennamen speichern)
    }

    /// `parse_messages(data, included, base, today)`. Annahme (Stud.IP 5, MessageSchema): subject, message (HTML),
    /// mkdate, Beziehung sender. Tage aus Betreff und ganzem Text, gespeichert nur Tag, Uhrzeit und Art.
    public static func parseMessages(_ data: JSONValue?, included: JSONValue?, base: String, today: Int) -> [Message] {
        var users: [String: JSONValue] = [:]
        for u in included?.array ?? [] where u.object != nil && u["type"]?.string == "users" {
            if let id = StudIPTerms.id(u) { users[id] = StudIPTerms.attrs(u) }
        }
        var out: [Message] = []
        for m in data?.array ?? [] {
            guard m.object != nil, let id = StudIPTerms.id(m) else { continue }
            let a = StudIPTerms.attrs(m)
            var subject = PyText.slice(Announcements.htmlToText(str(a["subject"])), 0, Announcements.maxTitle)
            if subject.isEmpty { subject = "(ohne Betreff)" }
            let text = Announcements.htmlToText(str(a["message"]))
            let sent = str(a["mkdate"])
            let posted = Announcements.postedDayOrNil(sent) ?? today
            let dates: [JSONValue] = Announcements.datesFor(title: subject, text: text, posted: posted).map { d in
                ["date": d["date"] ?? .null, "time": d["time"] ?? .null, "kind": d["kind"] ?? .null]
            }
            let preview = PyText.slice(text, 0, Announcements.maxText)      // ganzer Text (Inhaber 03.11.2026: nie "…")
            out.append(Message(id: "sp-msg-\(id)", sender: senderLabel(m, users: users), subject: subject, preview: preview, sentAt: sent,
                               url: "\(base)/dispatch.php/messages/overview", dates: dates))
        }
        return out
    }

    /// Aenderung in einem Kurs aus dem Activity-Stream
    public struct Activity: Sendable, Equatable {
        public let id, courseID, type, at, url: String

        public var json: JSONValue { ["id": .string(id), "course_id": .string(courseID), "type": .string(type), "at": .string(at), "url": .string(url)] }
    }

    /// `parse_activity(data, base)`. Annahme: activity-type, mkdate (ISO), Beziehung context (courses); Titel und
    /// Inhalt (nennen Personen) werden nicht gelesen
    public static func parseActivity(_ data: JSONValue?, base: String) -> [Activity] {
        let known = Set(activityLabels.map(\.type))
        var out: [Activity] = []
        for x in data?.array ?? [] {
            guard x.object != nil, let id = StudIPTerms.id(x) else { continue }
            let a = StudIPTerms.attrs(x)
            let type = PyText.lower(str(a["activity-type"]))
            let at = str(a["mkdate"])
            guard known.contains(type), let ctxRef = rel(x, "context"), let ctx = ctxRef, ctx["type"]?.string == "courses",
                  let cid = StudIPTerms.id(ctx), PyText.length(at) >= 10 else { continue }
            out.append(Activity(id: id, courseID: cid, type: type, at: at, url: "\(base)/dispatch.php/course/overview?cid=\(cid)"))
        }
        return out
    }

    /// Eigene Sprechstunden-Buchung
    public struct Booking: Sendable, Equatable {
        public let id, start, end, room: String

        public var json: JSONValue { ["id": .string(id), "start": .string(start), "end": .string(end), "room": .string(room)] }
    }

    /// `_local_dt(v)`: "YYYY-MM-DDTHH:MM:SS" Ortszeit aus ISO-Text (erste 19 Zeichen) oder Unix-Zeit (Berlin)
    static func localDateTime(_ v: JSONValue?) -> String? {
        if let s = v?.string, dateTimeRE.regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            let head = PyText.slice(s, 0, 19)
            return PyText.length(head) == 19 ? head : PyText.slice(head, 0, 16) + ":00"
        }
        if case .number(let n)? = v, n == n.rounded(), n > 0, n < 1e12 { return Learnweb.localISO(Int(n)) + ":00" }
        return nil
    }

    /// `parse_bookings(data, included)`. Annahme (nicht an der LUH belegt): Buchung -> slot (consultation-slots,
    /// start-time/end-time, sonst start/end) -> block (consultation-blocks, room). Ohne lesbare Zeit fehlt die Buchung.
    public static func parseBookings(_ data: JSONValue?, included: JSONValue?) -> [Booking] {
        var inc: [String: JSONValue] = [:]
        for i in included?.array ?? [] where i.object != nil {
            inc["\(i["type"]?.string ?? "")|\(StudIPTerms.id(i) ?? "")"] = i
        }
        var out: [Booking] = []
        for b in data?.array ?? [] {
            guard b.object != nil, let id = StudIPTerms.id(b), let slotRef = rel(b, "slot"), let sref = slotRef else { continue }
            let slot = inc["consultation-slots|\(StudIPTerms.id(sref) ?? "")"]
            let sa = StudIPTerms.attrs(slot)
            let start = localDateTime(sa.object?["start-time"] != nil ? sa["start-time"] : sa["start"])
            let end = localDateTime(sa.object?["end-time"] != nil ? sa["end-time"] : sa["end"])
            guard let start, let end, PyText.less(start, end) else { continue }
            var room = ""
            if let slot, let blockRef = rel(slot, "block"), let bref = blockRef,
               let block = inc["consultation-blocks|\(StudIPTerms.id(bref) ?? "")"] {
                room = PyText.slice(PyText.strip(str(StudIPTerms.attrs(block)["room"])), 0, 120)
            }
            out.append(Booking(id: id, start: start, end: end, room: room))
        }
        return LocalTimetable.stableSorted(out) { x, y in x.start != y.start ? PyText.less(x.start, y.start) : PyText.less(x.id, y.id) }
    }

    /// `chips(dates, today)`: alle kommenden Pruefungen, danach hoechstens zwei Fristen, Ausfaelle oder Verlegungen
    static func chips(_ dates: JSONValue?, today: String) -> [JSONValue] {
        // zuerst alle kommenden Pruefungen (Klausurtermine fallen nie weg, 04.11.2026), danach hoechstens zwei der
        // uebrigen Arten (Fristen, Ausfaelle, Verlegungen)
        var exams: [JSONValue] = [], other: [JSONValue] = []
        for d in dates?.array ?? [] {
            guard let day = d["date"]?.string, !PyText.less(day, today), let kind = d["kind"]?.string, let label = chipKinds[kind] else { continue }
            let text = "\(label) \(PyText.slice(day, 8, 10)).\(PyText.slice(day, 5, 7))."
            if (exams + other).contains(where: { $0["label"]?.string == text }) { continue }
            let chip: JSONValue = ["label": .string(text), "kind": .string(kind), "date": .string(day)]
            if kind == "pruefung" { exams.append(chip) } else if other.count < 2 { other.append(chip) }
        }
        return exams + other
    }

    /// `activity_title(types)`: "Neu: 2 Dateien, 1 Forumsbeitrag"
    static func activityTitle(_ types: [String]) -> String {
        var parts: [String] = []
        for l in activityLabels {
            let n = types.filter { $0 == l.type }.count
            if n > 0 { parts.append("\(n) \(n == 1 ? l.one : l.many)") }
        }
        return "Neu: " + parts.joined(separator: ", ")
    }

    /// `feed(news, messages, activity, today, limit)`: Karte "Neuigkeiten", neueste zuerst. Zeile:
    /// {id, kind (ankuendigung | nachricht | aenderung | blubber), who, title, at, url, text, chips, source, color}.
    /// `extra`: fertige Zeilen ohne Python-Entsprechung (Blubber, nur Geraet, `StudIPBlubber.feedLines`), werden mitsortiert.
    public static func feed(news: [JSONValue], messages: [JSONValue], activity: [JSONValue], today: String, limit: Int = 50,
                            extra: [JSONValue] = []) -> [JSONValue] {
        var out: [JSONValue] = []
        for a in news {
            var who = a["course_title"]?.string ?? ""
            if who.isEmpty {
                let global = (a["course_id"] ?? .null).isNull && a["source"]?.string == "studip"
                who = global ? "Stud.IP-weit" : a["source"]?.string == "learnweb" ? "Learnweb" : "Stud.IP"
            }
            out.append(["id": a["id"] ?? .null, "kind": "ankuendigung", "who": .string(who),
                        "title": LocalTimetable.or(a["title"], "Ankündigung"), "at": LocalTimetable.or(a["posted_at"], ""),
                        "url": a["url"] ?? .null, "text": LocalTimetable.or(a["text"], ""), "chips": .array(chips(a["dates"], today: today)),
                        "source": a["source"] ?? .null, "color": a["color"] ?? .null])
        }
        for m in messages {
            out.append(["id": m["id"] ?? .null, "kind": "nachricht", "who": LocalTimetable.or(m["sender"], "Nachricht"),
                        "title": LocalTimetable.or(m["subject"], "(ohne Betreff)"), "at": LocalTimetable.or(m["sent_at"], ""),
                        "url": m["url"] ?? .null, "text": LocalTimetable.or(m["preview"], ""), "chips": .array(chips(m["dates"], today: today)),
                        "source": "studip", "color": .null])
        }
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for x in activity {
            let key = "\(str(x["course_id"]))|\(PyText.slice(str(x["at"]), 0, 10))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(x)
        }
        for key in order {
            let xs = groups[key] ?? []
            let latest = xs.map { str($0["at"]) }.reduce("") { PyText.less($0, $1) ? $1 : $0 }
            let first = xs[0]
            out.append(["id": .string("act-\(str(first["course_id"]))-\(PyText.slice(str(first["at"]), 0, 10))"), "kind": "aenderung",
                        "who": LocalTimetable.or(first["course_title"], "Kurs"), "title": .string(activityTitle(xs.map { str($0["type"]) })),
                        "at": .string(latest), "url": first["url"] ?? .null, "text": "", "chips": .array([]), "source": "studip",
                        "color": first["color"] ?? .null])
        }
        out += extra
        let sorted = LocalTimetable.stableSorted(out) { a, b in PyText.less(str(b["at"]), str(a["at"])) }
        return Array(sorted.prefix(limit))
    }

    // MARK: Speicher

    static func has(_ c: SQLiteConnection, _ table: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) != nil
    }

    static func marks(_ n: Int) -> String { n == 0 ? "''" : Array(repeating: "?", count: n).joined(separator: ",") }

    /// `store_global_news`: Stud.IP-weite Ankuendigungen; steht eine auch in einem Kurs, bleibt sie dort
    @discardableResult
    static func storeGlobalNews(_ c: SQLiteConnection, _ items: [Announcements.Item], fetchedAt: String) throws -> Announcements.StoreResult {
        let inCourse = Set(try c.rows("SELECT id FROM announcements WHERE source='studip' AND course_id IS NOT NULL").compactMap { $0["id"]?.string })
        let keep = items.filter { !inCourse.contains($0.id) }
        var res = try Announcements.store(c, keep, source: "studip", fetchedAt: fetchedAt)
        res.removed = try c.execute("DELETE FROM announcements WHERE source='studip' AND course_id IS NULL AND id NOT IN (\(marks(keep.count)))",
                                    keep.map { .text($0.id) })
        return res
    }

    /// `store_messages`: Nachrichten ersetzen (in Stud.IP Geloeschtes verschwindet)
    static func storeMessages(_ c: SQLiteConnection, _ items: [Message], fetchedAt: String) throws {
        try c.executeScript(messagesTable)
        try c.execute("DELETE FROM studip_messages WHERE id NOT IN (\(marks(items.count)))", items.map { .text($0.id) })
        for m in items {
            try c.execute("""
                INSERT OR REPLACE INTO studip_messages(id, sender, subject, preview, sent_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?)
                """, [.text(m.id), .text(m.sender), .text(m.subject), .text(m.preview), .text(m.sentAt), .text(m.url),
                      .text(JSONValue.array(m.dates).jsonString()), .text(fetchedAt)])
        }
    }

    /// `store_activity`: dazuschreiben, aeltere als `activityDays` entfernen
    static func storeActivity(_ c: SQLiteConnection, _ items: [Activity], fetchedAt: String, today: Int) throws {
        try c.executeScript(activityTable)
        for x in items {
            try c.execute("INSERT OR REPLACE INTO studip_activity(id, course_id, type, at, url, fetched_at) VALUES (?,?,?,?,?,?)",
                          [.text(x.id), .text(x.courseID), .text(x.type), .text(x.at), .text(x.url), .text(fetchedAt)])
        }
        try c.execute("DELETE FROM studip_activity WHERE substr(at, 1, 10) < ?", [.text(BerlinClock.isoDate(today - activityDays))])
    }

    /// `store_consultations`: eigene Buchungen ersetzen
    static func storeConsultations(_ c: SQLiteConnection, _ items: [Booking], fetchedAt: String) throws {
        try c.executeScript(consultTable)
        try c.execute("DELETE FROM studip_consultations")
        for x in items {
            try c.execute("INSERT OR REPLACE INTO studip_consultations(id, start, end, room, fetched_at) VALUES (?,?,?,?,?)",
                          [.text(x.id), .text(x.start), .text(x.end), .text(x.room), .text(fetchedAt)])
        }
    }

    /// `consultation_occurrences(conn, start, end)`: Sprechstunden als Vorkommen ohne Serie (nur lesend)
    static func consultationOccurrences(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [JSONValue] {
        guard try has(c, "studip_consultations") else { return [] }
        return try c.rows("SELECT id, start, end, room FROM studip_consultations WHERE start >= ? AND start < ? ORDER BY start, id",
                          [.text(BerlinClock.isoDate(start)), .text(BerlinClock.isoDate(end + 1))]).map { r in
            let st = str(r["start"]), en = str(r["end"])
            let sameDay = PyText.slice(en, 0, 10) == PyText.slice(st, 0, 10)
            return ["event_id": .null, "studip_id": .string("consult-\(str(r["id"]))"), "date": .string(PyText.slice(st, 0, 10)),
                    "start": .string(PyText.slice(st, 11, 16)), "end": .string(sameDay ? PyText.slice(en, 11, 16) : "23:59"),
                    "title": "Sprechstunde", "kind": "sprechstunde", "module_id": .null, "module_name": .null, "color": .string(consultColor),
                    "room": .string(str(r["room"])), "lecturer": .null, "course_id": .null, "status": "teilnahme", "permanent_skip": false,
                    "exception": .null, "source": "studip-sprechstunde"]
        }
    }

    /// `with_consultations`: Vorkommen mit den Sprechstunden, nach Tag und Beginn (ohne Sprechstunden unveraendert)
    static func withConsultations(_ c: SQLiteConnection, _ occ: [JSONValue], from start: Int, to end: Int) throws -> [JSONValue] {
        let extra = try consultationOccurrences(c, from: start, to: end)
        guard !extra.isEmpty else { return occ }
        return LocalTimetable.stableSorted(occ + extra) { a, b in
            let (da, db) = (str(a["date"]), str(b["date"]))
            if da != db { return PyText.less(da, db) }
            return PyText.less(LocalTimetable.or(a["start"], "").string ?? "", LocalTimetable.or(b["start"], "").string ?? "")
        }
    }

    /// `feed_for(conn, today)`: Neuigkeiten aus der Datenbank (Endpunkt /api/news)
    public static func feedFor(_ c: SQLiteConnection, today: Int, limit: Int = 50) throws -> [JSONValue] {
        let news = try Announcements.recent(c, days: 30, limit: limit, today: today)
        var messages: [JSONValue] = []
        if try has(c, "studip_messages") {
            for r in try c.rows("SELECT id, sender, subject, preview, sent_at, url, dates FROM studip_messages ORDER BY sent_at DESC, id") {
                let dates = (r["dates"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .array([])
                messages.append(["id": r["id"] ?? .null, "sender": r["sender"] ?? .null, "subject": r["subject"] ?? .null,
                                 "preview": r["preview"] ?? .null, "sent_at": r["sent_at"] ?? .null, "url": r["url"] ?? .null, "dates": dates])
            }
        }
        var activity: [JSONValue] = []
        if try has(c, "studip_activity") {
            for r in try c.rows("""
                SELECT x.id, x.course_id, x.type, x.at, x.url, c.title, m.color FROM studip_activity x
                JOIN courses c ON c.id=x.course_id LEFT JOIN modules m ON m.id=c.module_id
                WHERE c.active=1 AND substr(x.at, 1, 10) >= ? ORDER BY x.at, x.id
                """, [.text(BerlinClock.isoDate(today - activityDays))]) {
                activity.append(["id": r["id"] ?? .null, "course_id": r["course_id"] ?? .null, "type": r["type"] ?? .null, "at": r["at"] ?? .null,
                                 "url": r["url"] ?? .null, "course_title": r["title"] ?? .null, "color": r["color"] ?? .null])
            }
        }
        // Blubber (nur Geraet, keine Python-Entsprechung): eine Zeile je Thread mit neuen Beitraegen
        let blubber = try StudIPBlubber.feedLines(c, today: today)
        return feed(news: news, messages: messages, activity: activity, today: BerlinClock.isoDate(today), limit: limit, extra: blubber)
    }

    // MARK: Abruf und Speichern (Geraet)

    /// Was der Abruf geladen hat; nil = nicht gelesen (fehlt, Fehler), der Bestand bleibt
    public struct Download: Sendable {
        public var semesters: [StudIPTerms.Period]?
        public var holidays: [StudIPTerms.Holiday]?
        public var globalNews: [Announcements.Item]?
        public var messages: [Message]?
        /// Zahl der Empfaenger je Nachricht (Antworten, StudIPMessageReply.swift); nur gesetzt, wenn die Liste sie nennt
        public var messageMeta: [String: Int]?
        public var activity: [Activity]?
        public var bookings: [Booking]?
        /// fehlende Endpunkte nach diesem Abruf
        public var missing: [String: JSONValue] = [:]
        public var sessionExpired = false
        public init() {}
    }

    /// Liest alle Ergaenzungen nacheinander. Wirft nie: abgelaufene Sitzung steht im Ergebnis, Netzfehler beenden den
    /// Abruf (`StudIPScheduleStore.stopsFetch`), sonst bleibt ein Fehler bei seinem Teil. `missing`: gespeicherte Liste.
    public static func fetch(client: StudIPClient, userID: String, missing: [String: JSONValue], today: Int) async -> Download {
        var d = Download()
        d.missing = missing
        let t = BerlinClock.isoDate(today)
        let base = client.baseString
        var stop = false

        func ask(_ name: String, _ paths: [String]) async -> JSONValue? {
            guard !stop, shouldAsk(d.missing, name, today: t) else { return nil }
            for p in paths {
                do {
                    let j = try await client.json("jsonapi.php/v1/" + p)
                    d.missing = remember(d.missing, name, status: 200, today: t)
                    return j["data"]?.array != nil ? j : nil
                } catch StudIPError.http(let status, _) {
                    d.missing = remember(d.missing, name, status: status, today: t)
                    if status == 400 { continue }      // z. B. include unbekannt: naechster Pfad
                    return nil
                } catch StudIPError.sessionExpired {
                    d.sessionExpired = true
                    stop = true
                    return nil
                } catch {
                    if StudIPScheduleStore.stopsFetch(error) { stop = true }
                    return nil
                }
            }
            return nil
        }

        if let j = await ask("semesters", ["semesters?page[limit]=100"]) { d.semesters = StudIPTerms.parseSemesters(j["data"]) }
        if let j = await ask("holidays", ["holidays?page[limit]=100"]) { d.holidays = StudIPTerms.parseHolidays(j["data"]) }
        if let j = await ask("studip-news", ["studip/news?page[limit]=50"]) { d.globalNews = globalNews(j["data"], base: base, today: today) }
        if let j = await ask("inbox", ["users/\(userID)/inbox?page[limit]=30&include=sender", "users/\(userID)/inbox?page[limit]=30"]) {
            d.messages = parseMessages(j["data"], included: j["included"], base: base, today: today)
            d.messageMeta = parseMessageMeta(j["data"])
        }
        if let j = await ask("activitystream", ["users/\(userID)/activitystream"]) { d.activity = parseActivity(j["data"], base: base) }
        if let j = await ask("consultations", ["users/\(userID)/consultation-bookings?include=slot,slot.block", "users/\(userID)/consultation-bookings"]) {
            d.bookings = parseBookings(j["data"], included: j["included"])
        }
        return d
    }

    /// `fetch` mit dem heutigen Tag der Uhr des Backends
    public static func fetch(client: StudIPClient, userID: String, missing: [String: JSONValue], clock: UniFlowClock) async -> Download {
        await fetch(client: client, userID: userID, missing: missing, today: BerlinClock.parseISODate(clock.today) ?? 0)
    }

    /// Schreibt den Abruf in die Datenbank (in einer Transaktion aufrufen)
    public static func store(_ d: Download, in c: SQLiteConnection, clock: UniFlowClock) throws {
        let now = clock.nowISO
        let today = BerlinClock.parseISODate(clock.today) ?? 0
        try StudIPTerms.store(c, semesters: d.semesters, holidays: d.holidays, fetchedAt: now)
        if let g = d.globalNews { try storeGlobalNews(c, g, fetchedAt: now) }
        if let m = d.messages {
            try storeMessages(c, m, fetchedAt: now)
            try storeMessageMeta(c, d.messageMeta ?? [:])
        }
        if let a = d.activity { try storeActivity(c, a, fetchedAt: now, today: today) }
        if let b = d.bookings { try storeConsultations(c, b, fetchedAt: now) }
        try saveMissing(c, d.missing)
    }
}

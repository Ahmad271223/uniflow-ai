import Foundation

/// Learnweb-Fristen (Abgaben, Tests) aus dem Moodle-Kalender wie `deadline_kind`, `local_iso`,
/// `short_deadline_title`, `deadlines_from_events` in app/learnweb.py. Abruf: `LearnwebAPI.deadlines`,
/// Ablage: `UniStore.storeDeadlines` (Tabelle `deadlines`). Erwartungswerte: fixtures/hildesheim/expected.json
/// (learnweb-deadlines, deadline-kinds, deadline-titles, local-iso).
extension Learnweb {

    /// Eine Frist in der Form von `deadlines_from_events` (Zeile der Tabelle `deadlines`)
    public struct Deadline: Sendable, Equatable {
        /// "lw-ev-<Moodle-Ereignis-id>"
        public let id: String
        /// "lw-<Kurs-id>", nil bei Terminen ohne Kurs
        public let courseID: String?
        /// ohne angehaengte Zeitangabe in Klammern
        public let title: String
        /// Name wie im Learnweb
        public let fullTitle: String
        /// abgabe | test_ende | test_beginn | frist | termin
        public let kind: String
        /// assign | quiz | ...
        public let module: String?
        /// lokale Zeit "YYYY-MM-DDTHH:MM"
        public let dueAt: String
        public let url: String?
        /// laut Learnweb ueberfaellig und noch nicht erledigt
        public let overdue: Bool

        public var json: JSONValue {
            ["id": .string(id), "course_id": courseID.map(JSONValue.string) ?? .null, "title": .string(title), "full_title": .string(fullTitle),
             "kind": .string(kind), "module": module.map(JSONValue.string) ?? .null, "due_at": .string(dueAt),
             "url": url.map(JSONValue.string) ?? .null, "overdue": .bool(overdue)]
        }
    }

    /// `DEADLINE_KINDS`
    static let deadlineKinds: [String: String] = ["assign|due": "abgabe", "quiz|close": "test_ende", "quiz|open": "test_beginn"]
    /// `DEADLINE_DAYS_BACK`: ueberfaellige, nicht erledigte Fristen des Semesters (Moodle liefert erledigte nicht mehr)
    public static let deadlineDaysBack = 120
    /// `DEADLINE_DAYS_AHEAD`
    public static let deadlineDaysAhead = 200
    /// `DEADLINE_PAGES`
    static let deadlinePages = 10

    // Angehaengte Zeitangabe im Aktivitaetsnamen, z. B. "Bonustest (verfügbar vom 30.10. (15:00 Uhr) bis 02.11. (23:59 Uhr))"
    // oder "Abgabe ... (schließt am 04.11. um 23:59 Uhr)": steht schon als Datum/Uhrzeit in der Frist
    private static let trailingDateRE = PyRegex(#"\s*\((?:[^()]|\([^()]*\))*?\b\d{1,2}\.\d{1,2}\.(?:[^()]|\([^()]*\))*\)\s*$"#)

    /// `short_deadline_title(title)`: Titel ohne angehaengte Zeitangabe in Klammern; bleibt nichts uebrig, der volle Titel
    public static func shortDeadlineTitle(_ title: String) -> String {
        let t = PyText.strip(trailingDateRE.sub(title, ""))
        return t.isEmpty ? PyText.strip(title) : t
    }

    /// `deadline_kind(modulename, eventtype)`: abgabe | test_ende | test_beginn | frist (andere Aktivitaet:
    /// faellig/schliesst) | termin (alles andere)
    public static func deadlineKind(module: String?, eventtype: String?) -> String {
        let m = PyText.lower(module ?? ""), e = PyText.lower(eventtype ?? "")
        if let k = deadlineKinds[m + "|" + e] { return k }
        if !m.isEmpty, ["due", "close", "expectcompletionon", "gradingdue"].contains(e) { return "frist" }
        return "termin"
    }

    /// `local_iso(ts)`: Unix-Zeit als lokale Uhrzeit 'YYYY-MM-DDTHH:MM' (Europe/Berlin, wie die Stundenplan-Zeiten)
    public static func localISO(_ ts: Int) -> String { PyText.slice(BerlinClock.localISO(utc: ts), 0, 16) }

    /// `deadlines_from_events(events)`: Moodle-Kalenderereignisse -> Fristen der App, nach Zeit sortiert, ohne
    /// doppelte Ereignisse (gleiche Kennung: die letzte gilt)
    public static func deadlinesFromEvents(_ events: [JSONValue]) -> [Deadline] {
        var out: [String: Deadline] = [:]
        for e in events {
            guard let id = e["id"]?.int, let ts = e["timestart"]?.int, ts != 0 else { continue }
            let course = e["course"] ?? .null
            let cid = (course["id"]?.int).flatMap { $0 != 0 ? $0 : nil } ?? e["courseid"]?.int      // course.get("id") or courseid
            let title = PyText.strip(HText.nfc([e["activityname"]?.string, e["name"]?.string].compactMap { $0 }.first { !$0.isEmpty } ?? ""))
            let did = "lw-ev-\(id)"
            let short = shortDeadlineTitle(title)
            let url = e["url"]?.string
            out[did] = Deadline(id: did, courseID: cid.flatMap { $0 > 1 ? "lw-\($0)" : nil },
                                title: short.isEmpty ? "Termin" : short, fullTitle: title.isEmpty ? "Termin" : title,
                                kind: deadlineKind(module: e["modulename"]?.string, eventtype: e["eventtype"]?.string),
                                module: (e["modulename"]?.string).flatMap { $0.isEmpty ? nil : $0 }, dueAt: localISO(ts),
                                url: url.flatMap { $0.isEmpty ? nil : $0 }, overdue: LocalModules.truthy(e["overdue"]))
        }
        return out.values.sorted { a, b in
            if a.dueAt != b.dueAt { return PyText.less(a.dueAt, b.dueAt) }
            if a.title != b.title { return PyText.less(a.title, b.title) }
            return PyText.less(a.id, b.id)
        }
    }

    /// `fetch_deadline_events(call, now)`: Ereignisse aus beiden Kalender-Quellen; `call(fn, args)` ist REST
    /// (Schluessel) oder AJAX (Sitzung). Die Vorschau ist nur Ergaenzung ("Test beginnt"): eine Fehlermeldung von
    /// Moodle dort wird uebergangen, die Fristen selbst kommen aus der ersten Quelle.
    static func fetchDeadlineEvents(now: Int, call: (String, [(String, JSONValue)]) async throws -> JSONValue) async throws -> [JSONValue] {
        var events: [JSONValue] = []
        var args: [(String, JSONValue)] = [("timesortfrom", .number(Double(now - deadlineDaysBack * 86400))),
                                           ("timesortto", .number(Double(now + deadlineDaysAhead * 86400))), ("limitnum", .number(50))]
        for _ in 0..<deadlinePages {
            let d = try await call("core_calendar_get_action_events_by_timesort", args)
            let page = d["events"]?.array ?? []
            events += page
            guard page.count >= 50, let last = d["lastid"], LocalModules.truthy(last) else { break }
            args = args.filter { $0.0 != "aftereventid" } + [("aftereventid", last)]
        }
        do {
            events += try await call("core_calendar_get_calendar_upcoming_view", [("courseid", .number(1)), ("categoryid", .number(0))])["events"]?.array ?? []
        } catch let e as HildesheimError {
            // wie `except LearnwebError`: eine Fehlermeldung von Moodle zur Vorschau uebergehen; Netz- und HTTP-Fehler
            // (wie am PC) und Abbruch gehen weiter
            switch e {
            case .badResponse, .invalidToken, .sessionExpired: break
            default: throw e
            }
        }
        return events
    }
}

extension UniStore {
    /// `store_deadlines(conn, items, fetched_at, window_from)`: Learnweb-Fristen speichern. Was im abgefragten
    /// Zeitfenster (ab `windowFrom`, 120 Tage zurueck) nicht mehr kommt, ist im Learnweb geloescht oder erledigt und
    /// wird entfernt; aeltere Fristen bleiben als Verlauf stehen.
    public static func storeDeadlines(_ c: SQLiteConnection, _ items: [Learnweb.Deadline], fetchedAt: String,
                                      windowFrom: String) throws -> Announcements.StoreResult {
        var known = Set<String>()
        for r in try c.rows("SELECT id FROM deadlines WHERE source='learnweb'") { if let id = r["id"]?.string { known.insert(id) } }
        for d in items {
            try c.execute("""
                INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                                        VALUES (?, 'learnweb', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                        ON CONFLICT(id) DO UPDATE SET course_id=excluded.course_id, title=excluded.title,
                                          full_title=excluded.full_title, kind=excluded.kind,
                                          module=excluded.module, due_at=excluded.due_at, url=excluded.url, overdue=excluded.overdue, fetched_at=excluded.fetched_at
                """, [.text(d.id), SQLiteValue(d.courseID), .text(d.title), .text(d.fullTitle.isEmpty ? d.title : d.fullTitle), .text(d.kind),
                      SQLiteValue(d.module), .text(d.dueAt), SQLiteValue(d.url), .integer(d.overdue ? 1 : 0), .text(fetchedAt)])
        }
        let ids = items.map(\.id)
        let marks = ids.isEmpty ? "''" : Array(repeating: "?", count: ids.count).joined(separator: ",")
        let gone = try c.execute("DELETE FROM deadlines WHERE source='learnweb' AND due_at >= ? AND id NOT IN (\(marks))",
                                 [.text(windowFrom)] + ids.map(SQLiteValue.text))
        return Announcements.StoreResult(new: Set(ids).subtracting(known).count, total: ids.count, removed: gone)
    }
}

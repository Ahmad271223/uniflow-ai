import Foundation

// Stundenplan aus Stud.IP in die lokale Datenbank, wie auf dem PC in app/studip_sync.py (fetch_events/store_events,
// fetch_schedule_entries/store_schedule_entries, danach timetable.auto_import). Auf dem Geraet kommen die
// Kurszeiten dazu (seminar-cycle-dates aus users/{id}/schedule, gelesen von StudIPSchedule): Tabelle
// studip_cycle_dates, die es nur auf dem Geraet gibt und die wie page_texts in app/scriptsearch.py erst bei Bedarf
// angelegt wird. LocalTimetableImport.studipEntries nutzt sie anstelle der aus Einzelterminen abgeleiteten Serien.
//
// Abruf und Speichern sind getrennt: erst alles laden (Netzwerk), dann in einer Transaktion schreiben (kein await
// in der Transaktion, siehe SQLiteDatabase). Was nicht geladen werden konnte, bleibt wie zuletzt gespeichert.

/// Einzeltermin eines Kurses (course-events) wie fetch_events in app/studip_sync.py.
public struct StudIPCourseEvent: Sendable, Equatable {
    public let id: String
    public let courseID: String
    public let title: String
    /// Beginn und Ende wie geliefert, die ersten 19 Zeichen ("2026-10-26T09:00:00", Ortszeit der Hochschule)
    public let start: String
    public let end: String
    /// erster Ort bis zum ersten Komma
    public let room: String

    public init(id: String, courseID: String, title: String, start: String, end: String, room: String) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.start = start
        self.end = end
        self.room = room
    }

    /// `data` von courses/{id}/events; abgesagte Termine (`is-cancelled`) fehlen wie auf dem PC
    public static func parse(_ data: [JSONValue], courseID: String) -> [StudIPCourseEvent] {
        data.compactMap { e in
            guard let id = e["id"]?.string else { return nil }
            let a = e["attributes"]
            if LocalModules.truthy(a?["is-cancelled"]) { return nil }
            func text(_ k: String) -> String { a?[k]?.string ?? "" }
            let room = text("location").split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return StudIPCourseEvent(id: id, courseID: courseID, title: text("title"), start: PyText.slice(text("start"), 0, 19),
                                     end: PyText.slice(text("end"), 0, 19), room: PyText.strip(room))
        }
    }
}

extension StudIPClient {
    /// Einzeltermine eines Kurses (courses/{id}/events, alle Seiten). Nur lesend.
    public func courseEvents(courseID: String) async throws -> [StudIPCourseEvent] {
        let (data, _) = try await list("jsonapi.php/v1/courses/\(courseID)/events?page[limit]=200")
        return StudIPCourseEvent.parse(data, courseID: courseID)
    }

    /// Ankuendigungen (News) eines Kurses wie `fetch_news` (courses/{id}/news, eine Seite mit 100). Nur lesend.
    public func courseNews(courseID: String) async throws -> [JSONValue] {
        try await json("jsonapi.php/v1/courses/\(courseID)/news?page[limit]=100")["data"]?.array ?? []
    }

    /// Basis fuer Links in Ankuendigungen (STUDIP_BASE am PC, ohne "/" am Ende)
    nonisolated var baseString: String {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
}

/// Was der Stundenplan-Abruf geladen hat. nil bzw. fehlende Kurse: nicht geladen, das Gespeicherte bleibt.
public struct StudIPScheduleDownload: Sendable {
    /// Kurse, die abgeglichen werden (wie die Kursliste in run_sync)
    public var courses: [StudIPCourse]
    /// `course-type` je Kurs aus users/{id}/courses
    public var courseTypes: [String: Int] = [:]
    /// seminar-cycle-dates aus users/{id}/schedule (Rohdaten der JSON:API)
    public var cycles: [JSONValue]?
    /// schedule-entries (eigene Eintraege) aus users/{id}/schedule
    public var personal: [JSONValue]?
    /// Einzeltermine je Kurs, nur vollstaendig geladene Kurse
    public var events: [String: [StudIPCourseEvent]] = [:]
    /// Ankuendigungen (News) je Kurs, Rohdaten der JSON:API; fehlt ein Kurs, bleibt sein Bestand (wie `fetch_news` None)
    public var news: [String: [JSONValue]] = [:]
    /// Basis fuer Links in Ankuendigungen (STUDIP_BASE)
    public var studipBase = ""
    /// Kurse, deren Termine nicht geladen werden konnten
    public var failedCourses: [String] = []
    /// Anmeldung abgelaufen (der Rest wurde nicht mehr abgefragt)
    public var sessionExpired = false
    /// Netz- oder Zeitlimitfehler: der Rest wurde nicht mehr abgefragt (steht in `failedCourses`)
    public var unreachable = false
    /// users/{id}/schedule liess sich nicht laden (Meldung ohne Kennungen)
    public var scheduleError: String?

    public init(courses: [StudIPCourse]) {
        self.courses = courses
    }
}

/// Ergebnis des Speicherns (fuer die Zusammenfassung des Abgleichs).
public struct StudIPScheduleResult: Sendable, Equatable {
    /// neu in den Stundenplan uebernommene Serien (auto_import)
    public let newEvents: Int
    /// Eintraege offener Gruppen, die auf die Auswahl warten (StudIPScheduleImport.openGroups)
    public let pendingGroups: Int
    public let cycles: Int
    public let events: Int

    public init(newEvents: Int, pendingGroups: Int, cycles: Int, events: Int) {
        self.newEvents = newEvents
        self.pendingGroups = pendingGroups
        self.cycles = cycles
        self.events = events
    }
}

public enum StudIPScheduleStore {

    /// Kurszeiten nur auf dem Geraet (Rohdaten, damit StudIPSchedule sie bei jeder Abfrage gleich liest)
    static let cycleTable = """
        CREATE TABLE IF NOT EXISTS studip_cycle_dates (
            id TEXT PRIMARY KEY,               -- Stud.IP-ID der Kurszeit
            course_id TEXT NOT NULL,
            course_type INTEGER,               -- course-type des Kurses (Art, wenn Titel und Beschreibung keine nennen)
            data TEXT NOT NULL,                -- Eintrag aus users/{id}/schedule (seminar-cycle-dates, JSON)
            fetched_at TEXT
        )
        """

    // MARK: Abruf

    /// Laedt Kurszeiten, eigene Eintraege und die Einzeltermine der Kurse. Wirft nie: Fehler je Teil stehen im
    /// Ergebnis, damit der Datei-Abgleich davon unberuehrt bleibt. Nach einem Netz- oder Zeitlimitfehler
    /// (`stopsFetch`) fragt der Abruf nichts mehr ab: jede weitere Anfrage wuerde nur bis zum Zeitlimit warten
    /// (30 s je Kurs), waehrend der Datei-Abgleich noch nicht fertig gemeldet ist.
    public static func fetch(client: StudIPClient, userID: String, courses: [StudIPCourse]) async -> StudIPScheduleDownload {
        var d = StudIPScheduleDownload(courses: courses)
        d.studipBase = client.baseString
        do {
            let r = try await client.scheduleResources(userID: userID)
            d.cycles = r.schedule.filter { $0["type"]?.string == "seminar-cycle-dates" }
            d.personal = r.schedule.filter { $0["type"]?.string == "schedule-entries" }
            for c in r.courses {
                if let id = c["id"]?.string, let t = StudIPSchedule.integer(c["attributes"]?["course-type"]) { d.courseTypes[id] = t }
            }
        } catch StudIPError.sessionExpired {
            d.sessionExpired = true
            return d
        } catch {
            d.scheduleError = (error as? StudIPError)?.description ?? "Stundenplan nicht lesbar"
            if stopsFetch(error) {
                d.unreachable = true
                d.failedCourses = courses.map(\.id)
                return d
            }
        }
        for (i, c) in courses.enumerated() {
            do {
                d.events[c.id] = try await client.courseEvents(courseID: c.id)
            } catch StudIPError.sessionExpired {
                d.sessionExpired = true
                break
            } catch {
                d.failedCourses.append(c.id)
                if stopsFetch(error) {
                    d.unreachable = true
                    d.failedCourses += courses[(i + 1)...].map(\.id)
                    break
                }
            }
            // Ankuendigungen je Kurs wie in run_sync, unabhaengig von den Terminen: eine Ergaenzung ("Ankuendigungen
            // nicht gelesen"), ein Fehler laesst den Bestand des Kurses stehen; Abbruch und abgelaufene Sitzung
            // bemerkt der naechste Kurs
            if let news = try? await client.courseNews(courseID: c.id) { d.news[c.id] = news }
        }
        return d
    }

    /// Fehler, nach denen weitere Anfragen sinnlos sind: kein Netz, Server nicht erreichbar oder haengt (Zeitlimit),
    /// Abbruch der Aufgabe, Anfragegrenze des Durchgangs erreicht
    static func stopsFetch(_ error: Error) -> Bool {
        if error is CancellationError || (error as? StudIPError) == StudIPError.requestLimit { return true }
        guard let u = error as? URLError else { return false }
        let codes: Set<URLError.Code> = [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                         .dnsLookupFailed, .cancelled, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed]
        return codes.contains(u.code)
    }

    // MARK: Speichern

    /// Schreibt den Abruf in die Datenbank (in einer Transaktion aufrufen) und uebernimmt danach wie auf dem PC alle
    /// eindeutigen Termine in den Stundenplan (`auto_import`, auf dem Geraet mit Verknuepfung: StudIPScheduleImport).
    /// Parallele Gruppen bleiben zur Auswahl.
    public static func store(_ d: StudIPScheduleDownload, in c: SQLiteConnection, clock: UniFlowClock) throws -> StudIPScheduleResult {
        let now: SQLiteValue = .text(clock.nowISO)
        // Kurse wie upsert_course in run_sync, derselbe Weg wie der Datei-Abgleich (`StudIPLibrary.storeCourses`):
        // anlegen bzw. Titel, Nummer, Semester aktualisieren; Fach und Art aus `UniRules.classify` nur, solange
        // sie fehlen (der Nutzer darf sie aendern). Ohne Art fiele ein Kurs aus studip_entries (kind != 'sonstiges').
        try StudIPLibrary.storeCourses(c, d.courses, startedAt: clock.nowISO)
        // Einzeltermine je vollstaendig geladenem Kurs ersetzen (store_events; dort bleiben Veraltete stehen)
        var events = 0
        for (courseID, list) in d.events.sorted(by: { $0.key < $1.key }) {
            try c.execute("DELETE FROM studip_events WHERE course_id=?", [.text(courseID)])
            for e in list {
                try c.execute("""
                    INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, start=excluded.start, end=excluded.end, room=excluded.room, fetched_at=excluded.fetched_at
                    """, [.text(e.id), .text(e.courseID), .text(e.title), .text(e.start), .text(e.end), .text(e.room), now])
                events += 1
            }
        }
        // eigene Eintraege (store_schedule_entries): Wochentag 0 = Montag, Uhrzeiten als "HH:MM"
        if let personal = d.personal {
            try c.execute("DELETE FROM studip_schedule_entries")
            for r in personal {
                guard let id = r["id"]?.string, let a = r["attributes"], let wd = StudIPSchedule.studipWeekday(a["weekday"] ?? 1),
                      let s = StudIPSchedule.minutes(a["start"]?.string), let e = StudIPSchedule.minutes(a["end"]?.string) else { continue }
                try c.execute("""
                    INSERT INTO studip_schedule_entries(id, title, weekday, start, end, description, fetched_at) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, weekday=excluded.weekday, start=excluded.start, end=excluded.end, description=excluded.description, fetched_at=excluded.fetched_at
                    """, [.text(id), .text(LocalTimetable.or(a["title"], "Termin").string ?? "Termin"), .integer(Int64(wd)),
                          .text(LocalFreeWindows.mh(s)), .text(LocalFreeWindows.mh(e)), .text(a["description"]?.string ?? ""), now])
            }
        }
        // Ankuendigungen je gelesenem Kurs (announcements.store mit course_ids=[c["id"]]: Geloeschtes verschwindet)
        let today = BerlinClock.parseISODate(clock.today) ?? 0
        for (courseID, list) in d.news.sorted(by: { $0.key < $1.key }) {
            let items = list.compactMap { Announcements.fromStudIPNews($0, courseID: courseID, studipBase: d.studipBase, today: today) }
            _ = try Announcements.store(c, items, source: "studip", fetchedAt: clock.nowISO, courseIDs: [courseID])
        }
        var cycles = 0
        if let list = d.cycles {
            try c.executeScript(cycleTable)
            try c.execute("DELETE FROM studip_cycle_dates")
            for r in list {
                let owner = r["relationships"]?["owner"]?["data"]
                guard let id = r["id"]?.string, owner?["type"]?.string == "courses", let course = owner?["id"]?.string else { continue }
                try c.execute("INSERT OR REPLACE INTO studip_cycle_dates(id, course_id, course_type, data, fetched_at) VALUES (?,?,?,?,?)",
                              [.text(id), .text(course), SQLiteValue(d.courseTypes[course]), .text(r.jsonString(sortedKeys: true)), now])
                cycles += 1
            }
        }
        let r = try StudIPScheduleImport.autoImport(c, clock: clock)
        return StudIPScheduleResult(newEvents: r.new, pendingGroups: r.pendingGroups, cycles: cycles, events: events)
    }

    // MARK: Lesen

    /// Kurszeit mit Semester (fuer Termine ohne eigenen Zeitraum) und Eintrag in der Form von studip_entries.
    struct StoredCycle {
        let entry: StudIPScheduleEntry
        let term: StudIPTerm
        let json: [String: JSONValue]
    }

    /// Gespeicherte Kurszeiten der aktiven Kurse (ohne "sonstiges"), gelesen von StudIPSchedule mit Titel und Nummer
    /// aus der Tabelle courses. Modul aus dem Kurs; ist der Kurs als Uebung eingeordnet, ist es auch die Art (wie
    /// studip_entries). Leer, solange es die Tabelle noch nicht gibt.
    static func cycleEntries(_ c: SQLiteConnection) throws -> [StoredCycle] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_dates'") != nil else { return [] }
        let rows = try c.rows("""
            SELECT y.data, y.course_type, c.id AS course_id, c.title, c.number, c.module_id, c.kind
            FROM studip_cycle_dates y JOIN courses c ON c.id=y.course_id WHERE c.active=1 AND c.kind != 'sonstiges' ORDER BY y.id
            """)
        guard !rows.isEmpty else { return [] }
        var schedule: [JSONValue] = []
        var courses: [String: JSONValue] = [:]
        var info: [String: (module: JSONValue, kind: JSONValue)] = [:]
        for r in rows {
            guard let course = r["course_id"]?.string, let text = r["data"]?.string, let data = try? JSONValue.parse(text) else { continue }
            schedule.append(data)
            courses[course] = ["id": .string(course), "type": "courses",
                               "attributes": ["title": r["title"] ?? .null, "course-number": r["number"] ?? .null, "course-type": r["course_type"] ?? .null]]
            info[course] = (r["module_id"] ?? .null, r["kind"] ?? .null)
        }
        let tt = StudIPSchedule.timetable(schedule: schedule, courses: courses.keys.sorted().compactMap { courses[$0] })
        let t = try LocalTimetable.term(c)
        let term = StudIPTerm(start: t["start"]?.string ?? "", end: t["end"]?.string ?? "")
        return tt.entries.map { e in
            var o = e.json.object ?? [:]
            if let course = e.courseID, let i = info[course] {
                o["module_id"] = i.module
                if i.kind == "uebung" { o["kind"] = "uebung" }
            }
            return StoredCycle(entry: e, term: term, json: o)
        }
    }
}

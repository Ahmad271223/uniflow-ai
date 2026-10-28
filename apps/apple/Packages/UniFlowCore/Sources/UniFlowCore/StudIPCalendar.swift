import Foundation

// Eigener Stud.IP-Kalender (users/{id}/events.ics) als Auswahl fuer den Stundenplan, nur auf dem Geraet.
//
// users/{id}/schedule liefert alle Kurszeiten aller belegten Kurse: auch fremde Uebungsgruppen und Kurse, die der
// Nutzer in Stud.IP nicht im Kalender haben will. Stud.IP selbst zeigt im Kalender nur Termine von Kursen mit
// Kalenderbindung (seminar_user.bind_calendar), ohne im Stundenplan ausgeblendete Kurszeiten und Termine mit
// Statusgruppen nur fuer deren Mitglieder (CalendarCourseDate::getEvents). Genau diese Termine stehen im
// iCalendar-Export, ab dem Zeitpunkt der Abfrage. Ihre UID ist "Stud.IP-SEM-<Termin-ID>@<Host>", dieselbe ID wie in
// courses/{id}/events (studip_events.id). Damit entscheidet der Abgleich je Kurszeit:
// - relevant: mindestens ein kuenftiger Termin der Kurszeit steht im Kalender (Kurs, Tag, Beginn; bei gleichen
//   Zeiten in mehreren Raeumen zaehlt der Raum),
// - nicht relevant: kuenftige Termine, aber keiner im Kalender (z. B. Kurs ohne Kalenderbindung, fremde Gruppe).
// Kurszeiten ganz in der Vergangenheit und Kurse ohne geladene Einzeltermine bleiben unentschieden (bisherige Regel:
// parallele Gruppen zur Auswahl). Entscheidungen bleiben gespeichert, damit sich am Semesterende oder bei einem
// gescheiterten Abruf nichts zurueckdreht. Ein Kalender ganz ohne Veranstaltungstermine entscheidet nichts.
// Einzeltermine, die zu keiner Kurszeit gehoeren (Blocktermine, Klausuren, Kurse ohne Kurszeiten), entscheidet
// `LocalTimetableImport.applyCalendar` je Serie wie Python (`_apply_calendar`, Tabelle studip_series_relevance).
//
// Zwei Fragen an den Nutzer (Antworten je Kurs in studip_course_choices, also je Datenbank = je Nutzer und
// Hochschule, gelten fuer jeden weiteren Abgleich):
// - Kurs belegt, aber ganz ohne Termine im Kalender (z. B. selbst aus dem Kalender genommen): bis zur Antwort nicht
//   uebernommen wie in Stud.IP; "Uebernehmen" nimmt ihn mit der bisherigen Regel (parallele Gruppen zur Auswahl),
//   "Weglassen" laesst ihn weg.
// - Kurs mit drei oder mehr Serien je Woche im Kalender: welche besucht der Nutzer? Alle sind wie in Stud.IP
//   uebernommen; abgewaehlte bekommen attend=0 (grau, Zeit frei).
// Tabellen wie studip_cycle_dates erst bei Bedarf angelegt.

enum StudIPCalendar {

    static let tables = """
        CREATE TABLE IF NOT EXISTS studip_calendar_dates (
            id TEXT PRIMARY KEY,               -- Stud.IP-ID eines Termins im eigenen Kalender
            fetched_at TEXT
        );
        CREATE TABLE IF NOT EXISTS studip_cycle_relevance (
            cycle_id TEXT PRIMARY KEY,         -- Kurszeit (studip_cycle_dates.id)
            course_id TEXT NOT NULL,
            relevant INTEGER NOT NULL,         -- 0 = nicht im Kalender, 1 = Kurs, Tag und Beginn, 2 = dazu der Raum
            decided_at TEXT
        );
        """

    static let choicesTable = """
        CREATE TABLE IF NOT EXISTS studip_course_choices (
            course_id TEXT PRIMARY KEY,
            include INTEGER,                   -- Kurs ohne Kalendertermine: 1 = uebernehmen, 0 = weglassen, NULL = offen
            times_known TEXT,                  -- Kurszeiten, zu denen der Nutzer geantwortet hat (JSON-Liste)
            times_skipped TEXT,                -- davon nicht besucht (JSON-Liste)
            updated_at TEXT
        )
        """

    /// Ab so vielen Serien je Woche fragt der Abgleich, welche der Nutzer besucht
    static let busyTimes = 3

    /// Antwort des Nutzers zu einem Kurs
    struct Choice: Equatable {
        var include: Bool?
        var known: Set<String> = []
        var skipped: Set<String> = []
    }

    // MARK: Lesen der Antwort

    private static let folded = HText.regex("\\r?\\n[ \\t]")
    private static let uidLine = HText.regex("^UID:Stud\\.IP-SEM-([^@\\s]+)@", [.anchorsMatchLines])

    /// `calendar_date_ids(ics)` wie app/timetable.py: Termin-IDs der Veranstaltungstermine im Kalender (Zeilen
    /// "UID:Stud.IP-SEM-<id>@..." nach dem Entfalten nach RFC 5545); eigene Kalendertermine und Eintraege ohne solche
    /// UID fehlen. Ohne Doppelte, nach Codepunkten sortiert. Vorher las das Geraet die UID ueber `parseICS`: ein
    /// Termin ohne lesbares DTSTART fiel dann mit seiner ID weg.
    static func dateIDs(ics: String) -> [String] {
        let text = folded.stringByReplacingMatches(in: ics, range: NSRange(location: 0, length: (ics as NSString).length), withTemplate: "")
        let ns = text as NSString
        var out = Set<String>()
        for m in uidLine.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return out.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    // MARK: Entscheiden

    /// Speichert den Kalender und entscheidet die Kurszeiten neu (in der Transaktion des Abgleichs, nach Kurszeiten und
    /// Einzelterminen). Liefert false, wenn nichts entschieden wurde (Kalender ohne Veranstaltungstermine).
    ///
    /// IDs frueherer Abrufe bleiben (Befund mit echten Daten, 28.10.2026): der Export beginnt mit dem Abruf, ein Ersetzen
    /// vergass also alles davor, und vergangene Tage zeigten wieder alle parallelen Gruppen. Entfernt werden nur IDs, die
    /// nicht mehr im Kalender stehen und deren Termin ab dem Abrufzeitpunkt beginnt (Datum aus `studip_events`); was
    /// davor lag, bleibt auf dem zuletzt gesehenen Stand, ebenso IDs ohne bekannten Termin. Die neuen IDs bekommen den
    /// Zeitpunkt dieses Abrufs, `max(fetched_at)` ist damit immer der letzte Abruf.
    @discardableResult
    static func store(ids: [String], in c: SQLiteConnection, clock: UniFlowClock) throws -> Bool {
        guard !ids.isEmpty else { return false }
        try c.executeScript(tables)
        let fresh = Set(ids)
        let now = LocalTimetableImport.isoDateTime(.string(clock.nowISO))
        for r in try c.rows("SELECT d.id, s.start FROM studip_calendar_dates d LEFT JOIN studip_events s ON s.id=d.id") {
            guard let id = r["id"]?.string, !fresh.contains(id) else { continue }
            guard let now, let st = LocalTimetableImport.isoDateTime(r["start"]) else { continue }      // Termin unbekannt: bleibt
            if !Coverage.before(st, now) { try c.execute("DELETE FROM studip_calendar_dates WHERE id=?", [.text(id)]) }
        }
        for id in ids {
            try c.execute("INSERT OR REPLACE INTO studip_calendar_dates(id, fetched_at) VALUES (?,?)", [.text(id), .text(clock.nowISO)])
        }
        let inCalendar = Set(ids)
        // Einzeltermine der Kurse: welche Kurse geladen sind, welche Tage und Beginnzeiten im Kalender stehen
        var loaded = Set<String>(), byTime = Set<String>(), byRoom = Set<String>()
        for r in try c.rows("SELECT id, course_id, start, room FROM studip_events") {
            guard let course = r["course_id"]?.string, let st = LocalTimetableImport.isoDateTime(r["start"]) else { continue }
            loaded.insert(course)
            guard let id = r["id"]?.string, inCalendar.contains(id) else { continue }
            let k = "\(course)|\(BerlinClock.isoDate(st.day))|\(LocalFreeWindows.mh(st.minutes))"
            byTime.insert(k)
            byRoom.insert(k + "|" + (r["room"]?.string ?? ""))
        }
        // ab morgen: der Kalender beginnt mit dem Zeitpunkt der Abfrage, heute frueher liegende Termine fehlen dort
        let from = BerlinClock.isoDate(LocalTimetable.today(clock) + 1)
        var decided: [(cycle: StudIPScheduleEntry, time: Bool, room: Bool)] = []
        for cy in try StudIPScheduleStore.cycleEntries(c, relevance: false) {
            let e = cy.entry
            guard let course = e.courseID, loaded.contains(course) else { continue }
            let to = e.dateTo ?? (cy.term.end.isEmpty ? "2037-12-31" : cy.term.end)
            let future = e.occurrences(from: from, to: to, term: cy.term)
            guard !future.isEmpty else { continue }
            let keys = future.map { "\(course)|\($0.date)|\($0.startTime)" }
            decided.append((e, keys.contains { byTime.contains($0) }, keys.contains { byRoom.contains($0 + "|" + e.room) }))
        }
        // Gleiche Zeiten eines Kurses in mehreren Raeumen: passt bei einer der Raum, gilt nur sie
        var roomMatched = Set<String>()
        for d in decided where d.room { roomMatched.insert(sameTime(d.cycle)) }
        for d in decided {
            let relevant = roomMatched.contains(sameTime(d.cycle)) ? (d.room ? 2 : 0) : (d.time ? 1 : 0)
            try c.execute("""
                INSERT INTO studip_cycle_relevance(cycle_id, course_id, relevant, decided_at) VALUES (?,?,?,?)
                ON CONFLICT(cycle_id) DO UPDATE SET course_id=excluded.course_id, relevant=excluded.relevant, decided_at=excluded.decided_at
                """, [.text(d.cycle.id), .text(d.cycle.courseID ?? ""), .integer(Int64(relevant)), .text(clock.nowISO)])
        }
        return true
    }

    /// Kurs, Wochentag, Beginn und Ende einer Kurszeit
    static func sameTime(_ e: StudIPScheduleEntry) -> String { "\(e.courseID ?? "")|\(e.weekday)|\(e.startTime)|\(e.endTime)" }

    // MARK: Abfragen

    /// Gespeicherte Entscheidungen je Kurszeit (0, 1, 2); leer, solange es keinen Kalender gab
    static func decisions(_ c: SQLiteConnection) throws -> [String: Int] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_relevance'") != nil else { return [:] }
        var out: [String: Int] = [:]
        for r in try c.rows("SELECT cycle_id, relevant FROM studip_cycle_relevance") {
            if let id = r["cycle_id"]?.string, let v = r["relevant"]?.int { out[id] = v }
        }
        return out
    }

    /// Termine im Kalender und der Tag der Abfrage; nil, solange es keinen Kalender gab
    static func calendar(_ c: SQLiteConnection) throws -> (ids: Set<String>, day: Int)? {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_calendar_dates'") != nil else { return nil }
        let rows = try c.rows("SELECT id, fetched_at FROM studip_calendar_dates")
        guard let at = rows.compactMap({ $0["fetched_at"]?.string }).max(),
              let day = BerlinClock.parseISODate(PyText.slice(at, 0, 10)) else { return nil }
        return (Set(rows.compactMap { $0["id"]?.string }), day)
    }

    /// Was der eigene Kalender fuer die Woche abdeckt (`LocalTimetable.studipDated`, `mergeDated`). Nur auf dem Geraet,
    /// Python entscheidet erst ab dem Tag nach dem Abruf und vergisst bei jedem Abruf die Tage davor (Bitte an die
    /// PC-Sitzung in docs/STAND-MAC-SITZUNG.md). Regel, Begruendung: docs/IPAD-STUDIP-SYNC.md §10.
    struct Coverage {
        typealias Time = LocalTimetableImport.LocalTime
        /// Termin-IDs aller Abrufe, die noch gelten
        let ids: Set<String>
        /// letzter Abruf (Ortszeit) und sein Tag
        let fetched: Time
        /// Beginn des fruehesten Kalendertermins, den es als Einzeltermin gibt; davor weiss der Kalender nichts
        let first: Time?
        /// Zeitschlitze der Kalendertermine: Kurs, Wochentag, Beginn, Ende
        let slots: Set<String>
        /// Kurse mit mindestens einem Kalendertermin
        let courses: Set<String>

        static func before(_ a: Time, _ b: Time) -> Bool { (a.day, a.minutes) < (b.day, b.minutes) }

        static func slot(course: String, start: Time, end: Time) -> String {
            "\(course)|\(BerlinClock.weekday(start.day))|\(LocalFreeWindows.mh(start.minutes))|\(LocalFreeWindows.mh(end.minutes))"
        }

        /// Zeigt die Woche diesen Stud.IP-Einzeltermin? Im Kalender: ja. Sonst nein, wenn der Kalender den Zeitpunkt
        /// abdeckt (ab dem fruehesten Kalendertermin), ausser der Termin begann am Abruftag vor dem Abruf (ob der
        /// Export begonnene Termine enthaelt, ist nicht sicher). Davor gilt der Zeitschlitz: derselbe Kurs, Wochentag,
        /// Beginn und Ende wie ein Kalendertermin heisst eigener Termin; ein Kurs ganz ohne Kalendertermin faellt weg.
        func shows(id: String?, course: String?, start: Time, end: Time) -> Bool {
            if let id, ids.contains(id) { return true }
            let beganBeforeFetch = start.day == fetched.day && Self.before(start, fetched)
            if let first, !Self.before(start, first), !beganBeforeFetch { return false }
            guard let course, courses.contains(course) else { return false }
            return slots.contains(Self.slot(course: course, start: start, end: end))
        }
    }

    /// Abdeckung des eigenen Kalenders; nil, solange es keinen Kalender gab
    static func coverage(_ c: SQLiteConnection) throws -> Coverage? {
        guard let cal = try calendar(c) else { return nil }
        let at = try c.queryOne("SELECT MAX(fetched_at) FROM studip_calendar_dates")?[0].string
        let fetched = LocalTimetableImport.isoDateTime(at.map(JSONValue.string)) ?? Coverage.Time(day: cal.day, minutes: 0)
        var first: Coverage.Time?
        var slots = Set<String>(), courses = Set<String>()
        for r in try c.rows("SELECT s.course_id, s.start, s.end FROM studip_events s JOIN studip_calendar_dates d ON d.id=s.id") {
            guard let course = r["course_id"]?.string, let st = LocalTimetableImport.isoDateTime(r["start"]),
                  let en = LocalTimetableImport.isoDateTime(r["end"]) else { continue }
            courses.insert(course)
            slots.insert(Coverage.slot(course: course, start: st, end: en))
            if first.map({ Coverage.before(st, $0) }) ?? true { first = st }
        }
        return Coverage(ids: cal.ids, fetched: fetched, first: first, slots: slots, courses: courses)
    }

    /// Kurse, die laut Kalender ganz fehlen: entschieden, aber keine Kurszeit relevant (z. B. ohne Kalenderbindung)
    static func hiddenCourses(_ c: SQLiteConnection) throws -> Set<String> {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_relevance'") != nil else { return [] }
        let rows = try c.rows("SELECT course_id FROM studip_cycle_relevance GROUP BY course_id HAVING MAX(relevant) = 0")
        return Set(rows.compactMap { $0["course_id"]?.string })
    }

    /// Gespeicherte Antworten je Kurs; leer, solange es keine gab
    static func choices(_ c: SQLiteConnection) throws -> [String: Choice] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_course_choices'") != nil else { return [:] }
        var out: [String: Choice] = [:]
        for r in try c.rows("SELECT course_id, include, times_known, times_skipped FROM studip_course_choices") {
            guard let id = r["course_id"]?.string else { continue }
            func list(_ k: String) -> Set<String> {
                Set((r[k]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) }?.array?.compactMap(\.string) ?? [])
            }
            out[id] = Choice(include: r["include"]?.int.map { $0 != 0 }, known: list("times_known"), skipped: list("times_skipped"))
        }
        return out
    }

    /// Kurs ohne Kalendertermine uebernehmen oder weglassen
    static func setInclude(_ c: SQLiteConnection, course: String, include: Bool, clock: UniFlowClock) throws {
        try c.executeScript(choicesTable)
        try c.execute("""
            INSERT INTO studip_course_choices(course_id, include, updated_at) VALUES (?,?,?)
            ON CONFLICT(course_id) DO UPDATE SET include=excluded.include, updated_at=excluded.updated_at
            """, [.text(course), .integer(include ? 1 : 0), .text(clock.nowISO)])
    }

    /// Besuchte Termine eines Kurses mit vielen Serien: die gefragten Kurszeiten (`known`) merken, nicht besuchte
    /// (`known` ohne `attend`) bekommen attend=0, besuchte attend=1, soweit sie schon im Stundenplan stehen.
    static func setTimes(_ c: SQLiteConnection, course: String, known: [String], attend: Set<String>, clock: UniFlowClock) throws {
        try c.executeScript(choicesTable)
        let skipped = known.filter { !attend.contains($0) }
        func json(_ l: [String]) -> SQLiteValue { .text(JSONValue.array(Set(l).sorted().map(JSONValue.string)).jsonString(sortedKeys: true)) }
        try c.execute("""
            INSERT INTO studip_course_choices(course_id, times_known, times_skipped, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(course_id) DO UPDATE SET times_known=excluded.times_known, times_skipped=excluded.times_skipped, updated_at=excluded.updated_at
            """, [.text(course), json(known), json(skipped), .text(clock.nowISO)])
        let links = try StudIPScheduleImport.readLinks(c)
        for id in known {
            guard let l = links["cycle:" + id] else { continue }
            try c.execute("UPDATE course_events SET attend=? WHERE id=?", [.integer(attend.contains(id) ? 1 : 0), .integer(l.eventID)])
        }
    }

    /// Kurszeiten, die der Nutzer abgewaehlt hat (alle Kurse)
    static func skippedTimes(_ c: SQLiteConnection) throws -> Set<String> {
        try choices(c).values.reduce(into: Set<String>()) { $0.formUnion($1.skipped) }
    }

    /// Offene Fragen: Kurse ohne Kalendertermine ohne Antwort ("hidden") und Kurse mit `busyTimes` oder mehr Serien
    /// je Woche im Kalender, zu deren Kurszeiten noch keine Antwort vorliegt ("busy", mit Stand der Teilnahme).
    static func questions(_ c: SQLiteConnection) throws -> JSONValue {
        let decisions = try decisions(c)
        guard !decisions.isEmpty else { return ["hidden": [], "busy": []] }
        let choices = try choices(c)
        let all = try StudIPScheduleStore.cycleEntries(c, relevance: false)
        var titles: [String: String] = [:], counts: [String: Int] = [:]
        for cy in all {
            guard let course = cy.entry.courseID else { continue }
            titles[course] = cy.entry.title
            counts[course, default: 0] += 1
        }
        let hidden = try hiddenCourses(c).filter { choices[$0]?.include == nil && titles[$0] != nil }
            .sorted { (titles[$0] ?? "", $0) < (titles[$1] ?? "", $1) }
        let links = try StudIPScheduleImport.readLinks(c)
        var times: [String: [StudIPScheduleEntry]] = [:]
        for cy in try StudIPScheduleStore.relevant(c, all) where (decisions[cy.entry.id] ?? 0) > 0 && cy.entry.rrule != "once" {
            if let course = cy.entry.courseID { times[course, default: []].append(cy.entry) }
        }
        var busy: [JSONValue] = []
        for (course, list) in times.sorted(by: { (titles[$0.key] ?? "", $0.key) < (titles[$1.key] ?? "", $1.key) }) where list.count >= busyTimes {
            let known = choices[course]?.known ?? []
            guard !list.allSatisfy({ known.contains($0.id) }) else { continue }
            let skipped = choices[course]?.skipped ?? []
            var rows: [JSONValue] = []
            for e in list {
                var attend = !skipped.contains(e.id)
                if let l = links["cycle:" + e.id], let r = try c.queryOne("SELECT attend FROM course_events WHERE id=?", [.integer(l.eventID)]) {
                    attend = (r["attend"]?.int ?? 1) != 0
                }
                rows.append(["cycle_id": .string(e.id), "weekday": .number(Double(e.weekday)), "start_time": .string(e.startTime),
                             "end_time": .string(e.endTime), "room": .string(e.room), "attend": .bool(attend)])
            }
            busy.append(["course_id": .string(course), "title": .string(titles[course] ?? ""), "times": .array(rows)])
        }
        return ["hidden": .array(hidden.map { ["course_id": .string($0), "title": .string(titles[$0] ?? ""),
                                               "times": .number(Double(counts[$0] ?? 0))] }),
                "busy": .array(busy)]
    }

    /// Kurse mit mindestens einer entschiedenen Kurszeit
    static func decidedCourses(_ c: SQLiteConnection) throws -> Set<String> {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_relevance'") != nil else { return [] }
        return Set(try c.rows("SELECT DISTINCT course_id FROM studip_cycle_relevance").compactMap { $0["course_id"]?.string })
    }
}

import Foundation

/// Stundenplan-Import wie app/timetable.py: Art und Modul raten (`guess_kind` = `UniRules.eventKind`, `guess_module`),
/// Kalenderdateien (`parse_ics`, `_ics_dt` mit UTC/TZID und EXDATE, Korrektur vom 25.10.2026 zuerst in Python; BYDAY wie
/// der LSF-Export der Uni Hildesheim, den `LSFCalendar` hierueber liest), Einzeltermine zu Serien (`merge_weekly`),
/// Stud.IP-Termine (`studip_entries`, `auto_import`), Vorschau (`enrich`, `diff_against_existing`) und Uebernahme
/// (`apply_import`, auch fuer `lsf.import_plan` in `UniStore.importPlan`). Eintraege sind JSON-Objekte in der Form
/// von Python.
///
/// Erweiterung auf dem Geraet: Kurszeiten aus Stud.IP (seminar-cycle-dates, `StudIPScheduleStore`) ersetzen fuer
/// ihren Kurs die aus Einzelterminen abgeleiteten Serien; Einzeltermine, die zu keiner Kurszeit passen (z. B.
/// Blocktermine), bleiben wie in Python. Ohne gespeicherte Kurszeiten ist `studipEntries` gleich `studip_entries`.
enum LocalTimetableImport {
    typealias Entry = [String: JSONValue]

    // MARK: Text wie Python (`needle in hay` und `str.strip()` aus PyText)

    /// Wortzeichen wie `\w` in Pythons `re` (Buchstaben, Zahlzeichen, Unterstrich)
    static func isWordChar(_ u: Unicode.Scalar) -> Bool {
        if u == "_" || u.properties.numericType != nil { return true }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    // MARK: Art und Modul

    /// `guess_module(conn, title)`: Modul, dessen Name (oder Kurstitel) am besten zum Titel passt, ab 0,55. Eine
    /// Fassung fuer Stundenplan und Module (`ModuleGuess`, S4), hier als JSON-Wert fuer die Eintraege.
    static func guessModule(_ c: SQLiteConnection, title: String) throws -> JSONValue {
        try ModuleGuess.guessModule(c, title: title)?.json ?? .null
    }

    // MARK: Kalenderdatei (ICS)

    /// Ortszeit Berlin: Tag (Tage seit 1970) und Minuten seit Mitternacht
    struct LocalTime: Equatable {
        var day: Int
        var minutes: Int

        func adding(minutes m: Int) -> LocalTime {
            let total = minutes + m
            return LocalTime(day: day + BerlinClock.floorDiv(total, 1440), minutes: total - BerlinClock.floorDiv(total, 1440) * 1440)
        }
    }

    /// TZID-Werte, die UTC bedeuten (`UTC_TZIDS` in app/timetable.py)
    static let utcTZIDs: Set<String> = ["UTC", "ETC/UTC", "GMT", "ETC/GMT", "Z", "UNIVERSAL", "ETC/UNIVERSAL", "ZULU", "ETC/ZULU", "UCT", "ETC/UCT"]

    // strptime("%Y%m%dT%H%M%S") bzw. ("%Y%m%d") mit den Mustern aus Pythons _strptime: erster Treffer ab dem Anfang
    // (ohne Suche nach einem laengeren), danach muss der Text zu Ende sein ("20261021T0815" ergibt 08:01:05)
    private static let strptimeDateTime = HText.regex("([0-9]{4})(1[0-2]|0[1-9]|[1-9])(3[01]|[12][0-9]|0[1-9]|[1-9]| [1-9])T(2[0-3]|[0-1][0-9]|[0-9])([0-5][0-9]|[0-9])(6[0-1]|[0-5][0-9]|[0-9])", [.caseInsensitive])
    private static let strptimeDate = HText.regex("([0-9]{4})(1[0-2]|0[1-9]|[1-9])(3[01]|[12][0-9]|0[1-9]|[1-9]| [1-9])")

    /// Gruppen eines Treffers ab dem Anfang, der den ganzen Text abdeckt, als Zahlen
    private static func strptime(_ re: NSRegularExpression, _ s: String) -> [Int]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length == ns.length else { return nil }
        return (1..<m.numberOfRanges).compactMap { Int(ns.substring(with: m.range(at: $0)).trimmingCharacters(in: .whitespaces)) }
    }

    /// `_ics_dt(v, params)`: Zeitpunkt als Ortszeit Berlin. "...Z" ist UTC, TZID=... eine Zeitzone (UTC-Namen und
    /// Europe/Berlin ohne Datenbank, andere aus den bekannten Zonen des Systems); unbekannte und Zeiten ohne Angabe
    /// gelten als Berliner Zeit. Reine Daten beginnen um 00:00. nil, wo Python mit ValueError scheitert.
    static func icsDate(_ raw: String, params: String = "") -> LocalTime? {
        let v = PyText.strip(raw)
        if v.unicodeScalars.contains("T") {
            guard let p = strptime(strptimeDateTime, PyText.slice(v, 0, 15)), p.count == 6, p[0] >= 1,
                  (1...BerlinClock.daysInMonth(year: p[0], month: p[1])).contains(p[2]), p[5] < 60 else { return nil }
            let day = BerlinClock.dayNumber(year: p[0], month: p[1], day: p[2])
            let wall = LocalTime(day: day, minutes: p[3] * 60 + p[4])
            let utcFlag = PyText.slice(v, 15, 16).uppercased() == "Z"
            let tz = tzid(params)
            if utcFlag || tz.map({ utcTZIDs.contains($0.uppercased()) }) == true {
                return berlin(utc: day * 86400 + p[3] * 3600 + p[4] * 60 + p[5])
            }
            // nur echte Zonennamen wie bei zoneinfo ("GMT+1" deutet Foundation als Versatz, Python kennt es nicht)
            if let tz, tz != "Europe/Berlin", let zone = TimeZone(identifier: tz), zone.identifier == tz {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                if let date = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4], second: p[5])) {
                    return berlin(utc: Int(date.timeIntervalSince1970.rounded(.down)))
                }
            }
            return wall
        }
        guard let p = strptime(strptimeDate, PyText.slice(v, 0, 8)), p.count == 3, p[0] >= 1,
              (1...BerlinClock.daysInMonth(year: p[0], month: p[1])).contains(p[2]) else { return nil }
        return LocalTime(day: BerlinClock.dayNumber(year: p[0], month: p[1], day: p[2]), minutes: 0)
    }

    /// `_berlin_from_utc`
    static func berlin(utc seconds: Int) -> LocalTime {
        let l = BerlinClock.local(utc: seconds)
        return LocalTime(day: l.day, minutes: l.minutes)
    }

    /// `_tzid(params)`: TZID aus "DTSTART;TZID=Europe/Berlin", ohne Anfuehrungszeichen
    static func tzid(_ params: String) -> String? {
        for p in params.split(separator: ";", omittingEmptySubsequences: false).dropFirst() where p.uppercased().hasPrefix("TZID=") {
            let v = PyText.strip(String(p.dropFirst(5))).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return v.isEmpty ? nil : v
        }
        return nil
    }

    private static let untilRule = HText.regex("UNTIL=([0-9]{8})(T[0-9]{6}Z?)?")
    private static let intervalRule = HText.regex("INTERVAL=([0-9]+)")

    /// `_ics_until(rrule, start)`: letzter Tag; UNTIL mit Uhrzeit vor dem Beginn des Termins zaehlt den Vortag
    static func icsUntil(_ rrule: String, start: LocalTime) -> String? {
        guard let g = HText.match(untilRule, rrule)?.groups, let d = g[1] else { return nil }
        let day = PyText.slice(d, 0, 4) + "-" + PyText.slice(d, 4, 6) + "-" + PyText.slice(d, 6, 8)
        guard let t = g[2] else { return day }
        guard let u = icsDate(d + t) else { return day }
        var last = u.day
        if u.minutes != 0 && u.minutes < start.minutes { last -= 1 }
        return BerlinClock.isoDate(last)
    }

    /// `_ics_exdates(items)`: Ausfaelle als ISO-Daten (Ortszeit Berlin), sortiert und ohne Doppelte
    static func icsExdates(_ items: [(value: String, params: String)]) -> [String] {
        var out = Set<String>()
        for (value, params) in items {
            for part in value.split(separator: ",", omittingEmptySubsequences: false) where !PyText.strip(String(part)).isEmpty {
                if let t = icsDate(String(part), params: params) { out.insert(BerlinClock.isoDate(t.day)) }
            }
        }
        return out.sorted()
    }

    /// `parse_ics(text)`: VEVENT mit DTSTART/DTEND/SUMMARY/LOCATION/RRULE (auch BYDAY)/EXDATE/UID/DESCRIPTION
    static func parseICS(_ text: String) -> [Entry] {
        // Zeilen entfalten: "\r\n" -> "\n", Folgezeilen mit Leerzeichen/Tab an die vorige haengen
        var scalars: [Unicode.Scalar] = []
        let src = Array(text.unicodeScalars)
        var i = 0
        while i < src.count {
            if src[i] == "\r", i + 1 < src.count, src[i + 1] == "\n" { scalars.append("\n"); i += 2 } else { scalars.append(src[i]); i += 1 }
        }
        var lines: [[Unicode.Scalar]] = []
        for ln in scalars.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = ln.first, f == " " || f == "\t", !lines.isEmpty {
                lines[lines.count - 1] += ln.dropFirst()
            } else {
                lines.append(Array(ln))
            }
        }
        struct Event {
            var props: [String: String] = [:]
            var exdates: [(value: String, params: String)] = []
        }
        func string(_ u: ArraySlice<Unicode.Scalar>) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: u)
            return String(v)
        }
        let begin = Array("BEGIN:VEVENT".unicodeScalars), endTag = Array("END:VEVENT".unicodeScalars)
        var events: [Event] = []
        var cur: Event?
        for ln in lines {
            if ln.starts(with: begin) {
                cur = Event()
            } else if ln.starts(with: endTag), let c = cur {
                events.append(c)
                cur = nil
            } else if cur != nil, let colon = ln.firstIndex(of: ":") {
                let k = string(ln[..<colon]), v = string(ln[(colon + 1)...])
                let key = (k.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "").uppercased()
                cur?.props[key] = PyText.strip(v)
                if key == "DTSTART" || key == "DTEND" {
                    cur?.props[key + "_PARAMS"] = k
                } else if key == "EXDATE" {
                    cur?.exdates.append((PyText.strip(v), k))      // mehrere EXDATE-Zeilen moeglich, jede mit eigener TZID
                }
            }
        }
        var out: [Entry] = []
        for ev in events {
            guard let st = icsDate(ev.props["DTSTART"] ?? "", params: ev.props["DTSTART_PARAMS"] ?? "") else { continue }
            let en: LocalTime
            if let dtend = ev.props["DTEND"], !dtend.isEmpty {
                guard let e = icsDate(dtend, params: ev.props["DTEND_PARAMS"] ?? "") else { continue }
                en = e
            } else {
                en = st.adding(minutes: 90)
            }
            let rr = ev.props["RRULE"] ?? ""
            let weekly = PyText.contains(rr, "FREQ=WEEKLY")
            let interval = HText.match(intervalRule, rr)?.groups[1]
            let title = (ev.props["SUMMARY"] ?? "Veranstaltung").replacingOccurrences(of: "\\,", with: ",")
            let room = (ev.props["LOCATION"] ?? "").replacingOccurrences(of: "\\,", with: ",")
            // BYDAY bestimmt den Wochentag (im LSF ist DTSTART der Semesterbeginn, auch fuer Donnerstags-Kurse); bei
            // mehreren Tagen je Tag eine Serie mit den Ausfaellen an diesem Wochentag
            let days = weekly ? byDays(rr) : []
            let exdates = icsExdates(ev.exdates)
            let until = icsUntil(rr, start: st).map(JSONValue.string) ?? .null
            let description = (ev.props["DESCRIPTION"] ?? "").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",")
            let startWeekday = BerlinClock.weekday(st.day)
            for wd in days.isEmpty ? [startWeekday] : days {
                let first = st.day + ((wd - startWeekday) % 7 + 7) % 7
                let own = exdates.filter { d in days.isEmpty || BerlinClock.parseISODate(d).map(BerlinClock.weekday) == wd }
                out.append([
                    "title": .string(title), "kind": .string(UniRules.eventKind(title)), "weekday": .number(Double(wd)),
                    "start_time": .string(LocalFreeWindows.mh(st.minutes)), "end_time": .string(LocalFreeWindows.mh(en.minutes)),
                    "room": .string(room), "rrule": .string(weekly ? (interval == "2" ? "biweekly" : "weekly") : "once"),
                    "date_from": .string(BerlinClock.isoDate(first)), "date_to": until,
                    "uncertain": false, "exdates": .array(own.map(JSONValue.string)),
                    "uid": ev.props["UID"].map(JSONValue.string) ?? .null, "description": .string(description),
                ])
            }
        }
        return out
    }

    /// Wochentage wie `ICS_DAYS`
    static let icsDays: [String: Int] = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]
    private static let byDayRule = HText.regex("BYDAY=([A-Z,0-9+-]+)")

    /// Wochentage aus BYDAY (`[ICS_DAYS[d[-2:]] for d in ... if d[-2:] in ICS_DAYS]`, z. B. "-1SU" -> 6); doppelte
    /// bleiben doppelt wie in Python
    static func byDays(_ rrule: String) -> [Int] {
        guard let g = HText.match(byDayRule, rrule)?.groups, let list = g[1] else { return [] }
        return list.split(separator: ",", omittingEmptySubsequences: false).compactMap { d in icsDays[String(d.suffix(2))] }
    }

    // MARK: Serien aus Einzelterminen

    /// `merge_weekly(entries)`: ab drei gleichen Terminen (Titel, Wochentag, Beginn, Ende) eine Serie, alle zwei
    /// Wochen, wenn alle Abstaende 14 Tage sind
    static func mergeWeekly(_ entries: [Entry]) throws -> [Entry] {
        var order: [JSONValue] = []
        var groups: [JSONValue: [Entry]] = [:]
        for e in entries {
            let k: JSONValue = [e["title"] ?? .null, e["weekday"] ?? .null, e["start_time"] ?? .null, e["end_time"] ?? .null]
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(e)
        }
        var out: [Entry] = []
        for k in order {
            let list = groups[k] ?? []
            // Wochen ohne Termin innerhalb der Serie (Weihnachtspause, Feiertage, einzelne Ausfaelle) kommen als
            // `exdates` mit (wie merge_weekly am PC seit 26.10.2026): Stud.IP legt an vorlesungsfreien Tagen keine
            // Termine an, die Serie wuerde die Luecke sonst wieder mit Vorlesungen fuellen. Alle 14 Tage: alle
            // Abstaende sind Vielfache von 14 (auch mit einer Luecke von 28 Tagen ueber Weihnachten).
            let dates = Array(Set(list.compactMap { LocalModules.truthy($0["date_from"]) ? $0["date_from"]?.string : nil }))
                .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            guard list.count >= 3, dates.count >= 2, let firstDate = dates.first, let lastDate = dates.last else { out += list; continue }
            let days = try dates.map { try LocalTimetable.day(.string($0), "date_from") }
            let gaps = zip(days, days.dropFirst()).map { $1 - $0 }
            let step = gaps.allSatisfy { $0 % 14 == 0 } ? 14 : 7
            let known = Set(dates)
            var missing: [String] = []
            var d = days[0]
            while d <= days[days.count - 1] {
                let iso = BerlinClock.isoDate(d)
                if !known.contains(iso) { missing.append(iso) }
                d += step
            }
            var e = list[0]
            e["rrule"] = step == 14 ? "biweekly" : "weekly"
            e["date_from"] = .string(firstDate)
            e["date_to"] = .string(lastDate)
            e["count"] = .number(Double(list.count))
            if !missing.isEmpty { e["exdates"] = .array(missing.map(JSONValue.string)) }       // Feld nur bei Luecken
            out.append(e)
        }
        return out
    }

    // MARK: Stud.IP

    private static let biweeklyWords = HText.regex("alle 2 Wochen|zweiw[öo]chentlich|14-?t[äa]g", [.caseInsensitive])

    /// `datetime.fromisoformat(v)` fuer gespeicherte Stud.IP-Termine: Tag und Uhrzeit, wie sie im Text stehen
    /// (eine Zeitzone am Ende aendert sie nicht). nil, wo Python mit ValueError/TypeError scheitert.
    static func isoDateTime(_ v: JSONValue?) -> LocalTime? {
        guard let s = v?.string else { return nil }
        let u = Array(s.unicodeScalars)
        func digits(_ from: Int, _ n: Int) -> Int? {
            guard from + n <= u.count else { return nil }
            var r = 0
            for k in from..<(from + n) {
                guard (0x30...0x39).contains(u[k].value) else { return nil }
                r = r * 10 + Int(u[k].value - 0x30)
            }
            return r
        }
        func date() -> (y: Int, mo: Int, d: Int, end: Int)? {
            if u.count >= 10, u[4] == "-", u[7] == "-", let a = digits(0, 4), let b = digits(5, 2), let c = digits(8, 2) { return (a, b, c, 10) }
            if let a = digits(0, 4), let b = digits(4, 2), let c = digits(6, 2) { return (a, b, c, 8) }
            return nil
        }
        guard let (y, mo, d, dateEnd) = date(), y >= 1, (1...12).contains(mo),
              (1...BerlinClock.daysInMonth(year: y, month: mo)).contains(d) else { return nil }
        var i = dateEnd
        let day = BerlinClock.dayNumber(year: y, month: mo, day: d)
        if i == u.count { return LocalTime(day: day, minutes: 0) }
        guard u[i] == "T" || u[i] == " ", let h = digits(i + 1, 2), h < 24 else { return nil }
        i += 3
        var mi = 0
        if i < u.count, u[i] == ":" {
            guard let m = digits(i + 1, 2), m < 60 else { return nil }
            mi = m
            i += 3
            if i < u.count, u[i] == ":" {
                guard let sec = digits(i + 1, 2), sec < 60 else { return nil }
                i += 3
                if i < u.count, u[i] == "." || u[i] == "," {
                    i += 1
                    let f = i
                    while i < u.count, (0x30...0x39).contains(u[i].value) { i += 1 }
                    guard i > f else { return nil }
                }
            }
        }
        if i < u.count {
            // Zone: Z oder +HH[:MM]
            if u[i] == "Z" || u[i] == "z" {
                i += 1
            } else if u[i] == "+" || u[i] == "-" {
                guard digits(i + 1, 2) != nil else { return nil }
                i += 3
                if i < u.count, u[i] == ":" { i += 1 }
                if i < u.count { guard digits(i, 2) != nil else { return nil }; i += 2 }
            }
            guard i == u.count else { return nil }
        }
        return LocalTime(day: day, minutes: h * 60 + mi)
    }

    /// `studip_entries(conn)`: Einzeltermine der aktiven Kurse zu Serien zusammengefasst, parallele Gruppen (mehr
    /// als zwei Serien je Kurs) zur Auswahl, dazu die persoenlichen Eintraege aus dem Stud.IP-Stundenplan. Auf dem
    /// Geraet zusaetzlich die Kurszeiten (seminar-cycle-dates) aus `StudIPScheduleStore`.
    static func studipEntries(_ c: SQLiteConnection) throws -> [Entry] {
        let rows = try c.rows("""
            SELECT s.*, c.title AS course_title, c.module_id, c.kind AS course_kind FROM studip_events s JOIN courses c ON c.id=s.course_id
                                        WHERE c.active=1 AND c.kind != 'sonstiges' ORDER BY s.start
            """)
        let cycles = try StudIPScheduleStore.cycleEntries(c)
        // Einzeltermine, die eine Kurszeit schon abdeckt (gleicher Tag und Beginn, auch ausgefallene)
        var covered: [String: Set<String>] = [:]
        if !cycles.isEmpty {
            var span: [String: (lo: String, hi: String)] = [:]
            for r in rows {
                guard let course = r["course_id"]?.string, let st = isoDateTime(r["start"]) else { continue }
                let d = BerlinClock.isoDate(st.day)
                let s = span[course]
                span[course] = (min(s?.lo ?? d, d), max(s?.hi ?? d, d))
            }
            for cy in cycles {
                guard let course = cy.entry.courseID, let s = span[course] else { continue }
                for o in cy.entry.occurrences(from: s.lo, to: s.hi, term: cy.term, includeCancelled: true) {
                    covered[course, default: []].insert(o.date + "|" + o.startTime)
                }
            }
        }
        var entries: [Entry] = []
        for r in rows {
            guard let st = isoDateTime(r["start"]), let en = isoDateTime(r["end"]) else { continue }
            if let course = r["course_id"]?.string,
               covered[course]?.contains(BerlinClock.isoDate(st.day) + "|" + LocalFreeWindows.mh(st.minutes)) == true { continue }
            let title = r["course_title"] ?? .null
            let date: JSONValue = .string(BerlinClock.isoDate(st.day))
            entries.append([
                "title": title, "kind": .string(r["course_kind"] == "uebung" ? "uebung" : UniRules.eventKind(title.string ?? "")),
                "weekday": .number(Double(BerlinClock.weekday(st.day))), "start_time": .string(LocalFreeWindows.mh(st.minutes)),
                "end_time": .string(LocalFreeWindows.mh(en.minutes)), "room": LocalTimetable.or(r["room"], ""), "rrule": "once",
                "date_from": date, "date_to": date, "module_id": r["module_id"] ?? .null, "course_id": r["course_id"] ?? .null,
                "uncertain": false,
            ])
        }
        var merged = try mergeWeekly(entries)
        // Uebungen mit vielen parallelen Gruppenterminen: nur eine Gruppe wird besucht -> Auswahl noetig
        var perCourse: [JSONValue: Int] = [:]
        for e in merged { perCourse[e["course_id"] ?? .null, default: 0] += 1 }
        for i in merged.indices {
            let n = perCourse[merged[i]["course_id"] ?? .null] ?? 0
            merged[i]["group_slots"] = .number(Double(n))
            merged[i]["selected"] = .bool(n <= 2)
            merged[i]["uncertain"] = .bool(n > 2)
            if n > 2 { merged[i]["hint"] = .string("\(n) parallele Gruppen – nur deine Gruppe auswählen") }
        }
        // Kurszeiten aus Stud.IP (Geraet): Gruppen je Kurs und Art bestimmt StudIPSchedule
        merged += cycles.map(\.json)
        // Persoenliche Eintraege aus dem Stud.IP-Stundenplan (z. B. die gewaehlte Uebungsgruppe)
        for r in try c.rows("SELECT * FROM studip_schedule_entries") {
            let titleValue = LocalTimetable.or(r["title"], "Termin")
            guard let title = titleValue.string else { throw LocalHTTPError(status: 500, message: "Titel eines Stundenplan-Eintrags ist kein Text") }
            let desc = LocalTimetable.or(r["description"], "")
            guard let descText = desc.string else { throw LocalHTTPError(status: 500, message: "Beschreibung ist kein Text") }
            let biweekly = HText.match(biweeklyWords, title + " " + descText) != nil
            merged.append([
                "title": .string(title), "kind": .string(UniRules.eventKind(title)), "weekday": .number(Double(try LocalTimetable.int(r["weekday"], "weekday"))),
                "start_time": r["start"] ?? .null, "end_time": r["end"] ?? .null, "room": "", "rrule": biweekly ? "biweekly" : "weekly",
                "date_from": .null, "date_to": .null, "module_id": try guessModule(c, title: title), "course_id": .null,
                "uncertain": false, "selected": true, "group_slots": 1, "personal": true,
                "hint": "persönlicher Eintrag aus deinem Stud.IP-Stundenplan",
            ])
        }
        // merged.sort(key=lambda e: (e["weekday"], e["start_time"])), stabil
        return try LocalTimetable.stableSorted(merged) { a, b in
            let wa = a["weekday"]?.double ?? 0, wb = b["weekday"]?.double ?? 0
            if wa != wb { return wa < wb }
            guard let sa = a["start_time"]?.string, let sb = b["start_time"]?.string else {
                if a["start_time"] == b["start_time"] { return false }
                throw LocalHTTPError(status: 500, message: "Termin ohne Beginn")
            }
            return sa.unicodeScalars.lexicographicallyPrecedes(sb.unicodeScalars)
        }
    }

    // MARK: Vorschau und Uebernahme

    /// `enrich(conn, entries)`: Modul raten, wo keines gesetzt ist
    static func enrich(_ c: SQLiteConnection, _ entries: [Entry]) throws -> [Entry] {
        try entries.map { e in
            var e = e
            if !LocalModules.truthy(e["module_id"]) {
                guard let title = e["title"] else { throw LocalHTTPError(status: 500, message: "Eintrag ohne Titel") }
                e["module_id"] = try guessModule(c, title: LocalModules.truthy(title) ? (title.string ?? LocalTimetable.text(title)) : "")
            }
            e["module_guess_uncertain"] = .bool(e["module_id"] == nil || e["module_id"] == .null)
            return e
        }
    }

    /// Schluessel einer Serie: Titel ohne Nicht-Wortzeichen, klein, hoechstens 30 Zeichen, und Wochentag
    static func seriesKey(_ e: [String: JSONValue]) throws -> JSONValue {
        let raw = LocalTimetable.or(e["title"], "")
        guard let title = raw.string else { throw LocalHTTPError(status: 500, message: "Titel ist kein Text") }
        var short = String.UnicodeScalarView()
        short.append(contentsOf: title.lowercased().unicodeScalars.filter(isWordChar).prefix(30))
        return [.string(String(short)), .number(Double(try LocalTimetable.int(e["weekday"], "weekday")))]
    }

    /// `diff_against_existing(conn, entries)`: neu / geaendert / unveraendert / entfernt gegen vorhandene Serien
    static func diffAgainstExisting(_ c: SQLiteConnection, _ entries: [Entry]) throws -> JSONValue {
        var order: [JSONValue] = []
        var exMap: [JSONValue: [String: JSONValue]] = [:]
        for x in try c.rows("SELECT * FROM course_events WHERE source != 'personal'") {
            let k = try seriesKey(x)
            if exMap[k] == nil { order.append(k) }
            exMap[k] = x                                       // wie im dict: letzte Zeile, erste Stelle
        }
        var new: [JSONValue] = [], changed: [JSONValue] = [], same: [JSONValue] = []
        var seen = Set<JSONValue>()
        for e in entries {
            let k = try seriesKey(e)
            seen.insert(k)
            if let x = exMap[k] {
                var o = e
                if x["start_time"] != e["start_time"] || x["end_time"] != e["end_time"] {
                    o["old_start"] = x["start_time"] ?? .null
                    o["old_end"] = x["end_time"] ?? .null
                    o["existing_id"] = x["id"] ?? .null
                    changed.append(.object(o))
                } else {
                    o["existing_id"] = x["id"] ?? .null
                    same.append(.object(o))
                }
            } else {
                new.append(.object(e))
            }
        }
        let removed = order.filter { !seen.contains($0) }.compactMap { exMap[$0].map(JSONValue.object) }
        return ["new": .array(new), "changed": .array(changed), "same": .array(same), "removed": .array(removed)]
    }

    /// `apply_import(conn, entries, source, remove_ids)` mit den IDs der neuen Serien (`ids`, fuer den LSF-Import am
    /// PC); Ausfaelle (`exdates`) werden zu Ausnahmen "cancelled",
    /// bei einer vorhandenen Serie entfallen nicht mehr gemeldete Ausfaelle derselben Quelle. `imported` (nur auf dem
    /// Geraet, StudIPScheduleImport) bekommt jeden Eintrag mit der ID seiner Serie.
    static func applyImport(_ c: SQLiteConnection, _ entries: [JSONValue], source: String, removeIDs: [JSONValue] = [],
                            clock: UniFlowClock, imported: ((Entry, SQLiteValue) throws -> Void)? = nil) throws -> JSONValue {
        var nNew = 0, nUpd = 0
        var newIDs: [JSONValue] = []
        let note = source.hasPrefix("studip") ? "Ausfall laut Stud.IP" : "Ausfall laut Kalender"
        func required(_ e: [String: JSONValue], _ k: String) throws -> JSONValue {
            guard let v = e[k] else { throw LocalHTTPError(status: 500, message: "Eintrag ohne \(k)") }
            return v
        }
        for item in entries {
            guard let e = item.object else { throw LocalHTTPError(status: 500, message: "Eintrag ist kein Objekt") }
            let eventID: SQLiteValue
            if LocalModules.truthy(e["existing_id"]) {
                eventID = try LocalTimetable.bind(e["existing_id"], "existing_id")
                try c.execute("UPDATE course_events SET start_time=?, end_time=?, room=COALESCE(NULLIF(?,''), room), kind=?, module_id=COALESCE(?, module_id) WHERE id=?",
                              [try LocalTimetable.bind(try required(e, "start_time"), "start_time"), try LocalTimetable.bind(try required(e, "end_time"), "end_time"),
                               try LocalTimetable.bind(LocalTimetable.or(e["room"], ""), "room"), try LocalTimetable.bind(LocalTimetable.or(e["kind"], "vorlesung"), "kind"),
                               try LocalTimetable.bind(e["module_id"], "module_id"), eventID])
                try dropStaleCancellations(c, eventID: eventID, dates: e["exdates"], note: note)
                nUpd += 1
            } else {
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, created_at)
                                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)
                    """, [try LocalTimetable.bind(e["module_id"], "module_id"), try LocalTimetable.bind(e["course_id"], "course_id"),
                          try LocalTimetable.bind(try required(e, "title"), "title"), try LocalTimetable.bind(LocalTimetable.or(e["kind"], "vorlesung"), "kind"),
                          .integer(Int64(try LocalTimetable.int(try required(e, "weekday"), "weekday"))),
                          try LocalTimetable.bind(try required(e, "start_time"), "start_time"), try LocalTimetable.bind(try required(e, "end_time"), "end_time"),
                          try LocalTimetable.bind(LocalTimetable.or(e["room"], ""), "room"), try LocalTimetable.bind(LocalTimetable.or(e["lecturer"], ""), "lecturer"),
                          try LocalTimetable.bind(LocalTimetable.or(e["rrule"], "weekly"), "rrule"), try LocalTimetable.bind(e["date_from"], "date_from"),
                          try LocalTimetable.bind(e["date_to"], "date_to"), .text(source), .text(clock.nowISO)])
                eventID = .integer(c.lastInsertRowID)
                newIDs.append(.number(Double(c.lastInsertRowID)))
                nNew += 1
            }
            try addCancellations(c, eventID: eventID, dates: e["exdates"], note: note, clock: clock)
            try imported?(e, eventID)
        }
        for rid in removeIDs {
            let id = try LocalTimetable.bind(rid, "remove_ids")
            try c.execute("DELETE FROM event_notes WHERE event_id=?", [id])
            try c.execute("DELETE FROM course_events WHERE id=?", [id])
        }
        return ["new": .number(Double(nNew)), "updated": .number(Double(nUpd)), "removed": .number(Double(removeIDs.count)), "ids": .array(newIDs)]
    }

    /// `_add_cancellations`: Ausfaelle einer Serie als Ausnahme "cancelled"; Tage mit vorhandener Ausnahme bleiben
    static func addCancellations(_ c: SQLiteConnection, eventID: SQLiteValue, dates: JSONValue?, note: String, clock: UniFlowClock) throws {
        guard let list = dates?.array, try c.queryOne("SELECT 1 FROM course_events WHERE id=?", [eventID]) != nil else { return }
        for d in list {
            guard let s = d.string, s.utf8.count == 10, s.utf8.enumerated().allSatisfy({ i, b in
                (i == 4 || i == 7) ? b == 0x2D : (0x30...0x39).contains(b)
            }) else { continue }
            if try c.queryOne("SELECT 1 FROM event_exceptions WHERE event_id=? AND date=?", [eventID, .text(s)]) != nil { continue }
            try c.execute("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,'cancelled',NULL,NULL,NULL,?,?)",
                          [eventID, .text(s), .text(note), .text(clock.nowISO)])
        }
    }

    /// `_drop_stale_cancellations`: erneuter Import einer vorhandenen Serie; Ausfaelle derselben Quelle (gleiche
    /// Notiz), die die neue Fassung nicht mehr meldet, entfallen. Ohne Liste (`exdates` fehlt) aendert sich nichts.
    static func dropStaleCancellations(_ c: SQLiteConnection, eventID: SQLiteValue, dates: JSONValue?, note: String) throws {
        guard let list = dates?.array else { return }
        // `d in keep` nach Codepunkten wie Python
        let keep = Set(list.compactMap { $0.string.map { $0.unicodeScalars.map(\.value) } })
        for r in try c.rows("SELECT id, date FROM event_exceptions WHERE event_id=? AND type='cancelled' AND note=? ORDER BY id", [eventID, .text(note)]) {
            if let d = r["date"]?.string, keep.contains(d.unicodeScalars.map(\.value)) { continue }
            try c.execute("DELETE FROM event_exceptions WHERE id=?", [try LocalTimetable.bind(r["id"], "id")])
        }
    }
}

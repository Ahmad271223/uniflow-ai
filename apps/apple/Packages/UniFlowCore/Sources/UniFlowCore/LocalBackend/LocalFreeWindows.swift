import Foundation

/// Freie Zeitfenster wie `timetable.free_windows` in app/timetable.py: Lernbeginn bis Lernende abzueglich der
/// belegten Bloecke (`busy_blocks`: besuchte Hochschultermine, Sperrzeiten des Wochentags, schon geplante
/// Lernslots) und der Fahrtzeit vor dem ersten und nach dem letzten Campus-Termin. `campus` ist wahr, wenn das
/// Fenster zwischen zwei Campus-Terminen liegt. Ergebnisgleichheit mit Python: `LocalFreeWindowsTests`
/// (timetable-free.json, nur Sperrzeiten) und `LocalTimetableTests` (timetable-logic.json, mit Terminen und Paketen).
enum LocalFreeWindows {
    /// Belegter Block eines Tages (`busy_blocks`)
    struct Block {
        let start: Int
        let end: Int
        /// event | blocked | study | travel
        let kind: String
        let campus: Bool
    }

    /// `free_windows(conn, d, s, include_packages)`
    static func compute(_ c: SQLiteConnection, day: Int, settings s: [String: JSONValue], includePackages: Bool = true) throws -> [JSONValue] {
        let (lo, hi) = (try hm(s["learn_start"], key: "learn_start"), try hm(s["learn_end"], key: "learn_end"))
        return try windows(lo: lo, hi: hi, blocks: try busyBlocks(c, day: day, settings: s, includePackages: includePackages), settings: s)
    }

    /// `busy_blocks(conn, d, settings, include_packages)`, nach Beginn sortiert (stabil wie `sorted` in Python)
    static func busyBlocks(_ c: SQLiteConnection, day: Int, settings s: [String: JSONValue], includePackages: Bool = true) throws -> [Block] {
        var blocks: [Block] = []
        for o in try LocalTimetable.occurrences(c, from: day, to: day) where o["status"] == "teilnahme" {
            blocks.append(Block(start: try hm(o["start"], key: "start"), end: try hm(o["end"], key: "end"), kind: "event", campus: true))
        }
        blocks += try blockedBlocks(day, settings: s)
        if includePackages {
            for p in try c.rows("SELECT start_time, end_time, subject FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status NOT IN ('verschoben','uebersprungen')",
                                [.text(LocalTimetable.iso(day))]) {
                blocks.append(Block(start: try hm(p["start_time"], key: "start_time"), end: try hm(p["end_time"], key: "end_time"),
                                    kind: "study", campus: false))
            }
        }
        return LocalTimetable.stableSorted(blocks) { $0.start < $1.start }
    }

    /// Sperrzeiten des Wochentags als Bloecke
    static func blockedBlocks(_ day: Int, settings s: [String: JSONValue]) throws -> [Block] {
        try LocalTimetable.blocked(day, settings: s).map { b in
            // b["start"] fehlt -> KeyError in Python (500); null zaehlt wie "00:00"
            guard let start = b["start"], let end = b["end"] else {
                throw LocalHTTPError(status: 500, message: "Sperrzeit ohne Beginn oder Ende")
            }
            return Block(start: try hm(start, key: "blocked_times"), end: try hm(end, key: "blocked_times"), kind: "blocked", campus: false)
        }
    }

    /// Rest von `free_windows`: Fahrtzeiten, Luecken zwischen den Bloecken, Mindestlaenge, Campus-Merkmal
    static func windows(lo: Int, hi: Int, blocks busy: [Block], settings s: [String: JSONValue]) throws -> [JSONValue] {
        var blocks = busy
        let travel = s["travel_minutes"]?.int ?? 30
        let campus = blocks.filter { $0.kind == "event" }
        // Fahrtzeit: vor dem ersten und nach dem letzten Campus-Termin (erster und letzter nach Beginn)
        if let first = campus.first, let last = campus.last {
            blocks.append(Block(start: first.start - travel, end: first.start, kind: "travel", campus: false))
            blocks.append(Block(start: last.end, end: last.end + travel, kind: "travel", campus: false))
        }
        blocks = LocalTimetable.stableSorted(blocks) { $0.start < $1.start }

        var windows: [(start: Int, end: Int)] = []
        var cur = lo
        for b in blocks {
            if b.end <= cur { continue }
            if b.start > cur { windows.append((cur, min(b.start, hi))) }
            cur = max(cur, b.end)
            if cur >= hi { break }
        }
        if cur < hi { windows.append((cur, hi)) }

        let minSlot = s["min_slot_minutes"]?.int ?? 30
        return windows.filter { $0.end - $0.start >= minSlot }.map { w in
            let onCampus = campus.contains { $0.end <= w.start } && campus.contains { $0.start >= w.end }
            return ["start": .number(Double(w.start)), "end": .number(Double(w.end)), "minutes": .number(Double(w.end - w.start)),
                    "start_hm": .string(mh(w.start)), "end_hm": .string(mh(w.end)), "campus": .bool(onCampus)]
        }
    }

    /// `hm(t)`: "HH:MM" in Minuten; `str(t or "00:00")`, danach `int` der ersten beiden Teile. Was Python daran
    /// scheitern laesst (z. B. "8" oder eine Zahl), wird zu 500 mit Meldung.
    static func hm(_ value: JSONValue?, key: String) throws -> Int {
        let v = value ?? .null
        let text: String
        if !LocalModules.truthy(v) {
            text = "00:00"
        } else if let s = v.string {
            text = s
        } else {
            throw LocalHTTPError(status: 500, message: "Uhrzeit in \(key) ist kein Text")
        }
        guard let (h, m) = hourMinute(text) else {
            throw LocalHTTPError(status: 500, message: "Ungültige Uhrzeit in \(key): \(text)")
        }
        return h * 60 + m
    }

    /// Stunde und Minute wie `int()` der ersten beiden Teile von `t.split(":")` in hm(); nil, wo Python scheitert.
    /// Ohne Grenzen (25:70 gibt es hier); die Stud.IP-Zeiten pruefen sie selbst (`StudIPSchedule.minutes`).
    static func hourMinute(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).prefix(2).map(String.init)
        guard parts.count == 2, let h = PyConvert.int(parts[0]), let m = PyConvert.int(parts[1]) else { return nil }
        return (h, m)
    }

    /// `mh(m)`: Minuten als "HH:MM", negative Werte als 00:00 (die eine Formatierung, auch fuer Stud.IP-Zeiten)
    static func mh(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return BerlinClock.pad(m / 60, 2) + ":" + BerlinClock.pad(m % 60, 2)
    }
}

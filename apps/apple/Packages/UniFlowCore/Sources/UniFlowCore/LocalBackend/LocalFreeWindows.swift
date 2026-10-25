import Foundation

/// Freie Zeitfenster wie `timetable.free_windows` in app/timetable.py, solange es lokal noch keine Termine und
/// Lernpakete gibt (Termine mit S5, Lernpakete mit S6): Lernbeginn bis Lernende abzueglich der Sperrzeiten des
/// Wochentags. Ohne Campus-Termine entfallen die Fahrtzeiten, `campus` ist immer false. Ergebnisgleichheit mit
/// Python prueft `LocalFreeWindowsTests` (Fixture timetable-free.json).
enum LocalFreeWindows {
    /// `free_windows(conn, d, s)` ohne Termine und Lernpakete
    static func compute(day: Int, settings s: [String: JSONValue]) throws -> [JSONValue] {
        let lo = try hm(s["learn_start"], key: "learn_start")
        let hi = try hm(s["learn_end"], key: "learn_end")
        // busy_blocks: nur die Sperrzeiten des Wochentags, nach Beginn sortiert (stabil wie sorted in Python)
        var blocks: [(start: Int, end: Int)] = []
        for b in LocalPending.blocked(day, settings: s).array ?? [] {
            // b["start"] fehlt -> KeyError in Python (500); null zaehlt wie "00:00"
            guard let start = b["start"], let end = b["end"] else {
                throw LocalHTTPError(status: 500, message: "Sperrzeit ohne Beginn oder Ende")
            }
            blocks.append((try hm(start, key: "blocked_times"), try hm(end, key: "blocked_times")))
        }
        blocks = blocks.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)

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
            ["start": .number(Double(w.start)), "end": .number(Double(w.end)), "minutes": .number(Double(w.end - w.start)),
             "start_hm": .string(mh(w.start)), "end_hm": .string(mh(w.end)), "campus": false]
        }
    }

    /// `hm(t)`: "HH:MM" in Minuten; `str(t or "00:00")`, danach `int` der ersten beiden Teile. Was Python daran
    /// scheitern laesst (z. B. "8" oder eine Zahl), wird zu 500 mit Meldung.
    static func hm(_ value: JSONValue?, key: String) throws -> Int {
        let v = value ?? .null
        let text: String
        if !LocalPending.truthy(v) {
            text = "00:00"
        } else if let s = v.string {
            text = s
        } else {
            throw LocalHTTPError(status: 500, message: "Uhrzeit in \(key) ist kein Text")
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).prefix(2).map(String.init)
        guard parts.count == 2, let h = PyConvert.int(parts[0]), let m = PyConvert.int(parts[1]) else {
            throw LocalHTTPError(status: 500, message: "Ungültige Uhrzeit in \(key): \(text)")
        }
        return h * 60 + m
    }

    /// `mh(m)`: Minuten als "HH:MM", negative Werte als 00:00
    static func mh(_ minutes: Int) -> String {
        let m = max(0, minutes)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return two(m / 60) + ":" + two(m % 60)
    }
}

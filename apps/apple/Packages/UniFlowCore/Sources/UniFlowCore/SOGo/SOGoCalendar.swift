import Foundation

/// Termine des Uni-Kalenders (SOGo) in der Datenbank des Containers und im Stundenplan/Lernkalender, wie
/// `store_events`, `calendar_occurrences` und `with_calendar` in app/sogo.py. Nur lesend: Termine aendert man im
/// Uni-Kalender selbst. Ganztaegige stehen nur auf der Seite Uni-Mail (sie wuerden sonst den ganzen Tag als belegt
/// zaehlen). Tabellen erst bei Bedarf angelegt (kein Schema-Wechsel).
public enum SOGoCalendar {
    static let table = """
        CREATE TABLE IF NOT EXISTS sogo_events (
            uid TEXT PRIMARY KEY, id TEXT NOT NULL, calendar TEXT, title TEXT, location TEXT,
            start TEXT NOT NULL, end TEXT NOT NULL, all_day INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, fetched_at TEXT)
        """

    static func has(_ c: SQLiteConnection) throws -> Bool { try StudIPExtras.has(c, "sogo_events") }

    /// Termine des Zeitraums [first, last] ersetzen (frueher gelesene ausserhalb bleiben). Rueckgabe: Zahl gespeicherter.
    @discardableResult
    public static func store(_ c: SQLiteConnection, _ events: [JSONValue], first: Int, last: Int, fetchedAt: String) throws -> Int {
        try c.executeScript(table)
        _ = try c.execute("DELETE FROM sogo_events WHERE start >= ? AND start < ?", [.text(BerlinClock.isoDate(first)), .text(BerlinClock.isoDate(last + 1))])
        var n = 0
        for e in events {
            _ = try c.execute("""
                INSERT OR REPLACE INTO sogo_events(uid, id, calendar, title, location, start, end, all_day, cancelled, fetched_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(e["uid"]?.string ?? ""), .text(e["id"]?.string ?? ""), .text(e["calendar"]?.string ?? ""), .text(e["title"]?.string ?? ""),
                      .text(e["location"]?.string ?? ""), .text(e["start"]?.string ?? ""), .text(e["end"]?.string ?? ""),
                      .integer(e["all_day"]?.bool == true ? 1 : 0), .integer(e["cancelled"]?.bool == true ? 1 : 0), .text(fetchedAt)])
            n += 1
        }
        return n
    }

    /// Gespeicherte Termine, die den Zeitraum beruehren
    public static func stored(_ c: SQLiteConnection, first: Int, last: Int) throws -> [JSONValue] {
        guard try has(c) else { return [] }
        return try c.rows("""
            SELECT uid, id, calendar, title, location, start, end, all_day, cancelled FROM sogo_events
            WHERE start < ? AND end >= ? ORDER BY start, title, uid
            """, [.text(BerlinClock.isoDate(last + 1)), .text(BerlinClock.isoDate(first))]).map { r in
            let title = r["title"]?.string ?? ""
            return ["uid": r["uid"] ?? .null, "id": r["id"] ?? .null, "calendar": .string(r["calendar"]?.string ?? ""),
                    "title": .string(title.isEmpty ? "Termin" : title), "location": .string(r["location"]?.string ?? ""),
                    "start": r["start"] ?? .null, "end": r["end"] ?? .null, "all_day": .bool((r["all_day"]?.int ?? 0) != 0),
                    "cancelled": .bool((r["cancelled"]?.int ?? 0) != 0)]
        }
    }

    @discardableResult
    public static func forget(_ c: SQLiteConnection) throws -> Int {
        guard try has(c) else { return 0 }
        return try c.execute("DELETE FROM sogo_events")
    }

    /// Termine mit Uhrzeit als Vorkommen ohne Serie (Quelle "uni-kalender", Art "sonstiges", nur lesend)
    public static func occurrences(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [JSONValue] {
        guard try has(c) else { return [] }
        return try c.rows("""
            SELECT id, calendar, title, location, start, end, cancelled FROM sogo_events
            WHERE all_day=0 AND start >= ? AND start < ? ORDER BY start, title, uid
            """, [.text(BerlinClock.isoDate(start)), .text(BerlinClock.isoDate(end + 1))]).map { r in
            let st = r["start"]?.string ?? "", en = r["end"]?.string ?? ""
            let cancelled = (r["cancelled"]?.int ?? 0) != 0
            let title = r["title"]?.string ?? ""
            return ["event_id": .null, "studip_id": r["id"] ?? .null, "date": .string(PyText.slice(st, 0, 10)),
                    "start": .string(PyText.slice(st, 11, 16)),
                    "end": .string(PyText.slice(en, 0, 10) == PyText.slice(st, 0, 10) ? PyText.slice(en, 11, 16) : "23:59"),
                    "title": .string(title.isEmpty ? "Termin" : title), "kind": "sonstiges", "module_id": .null, "module_name": .null,
                    "color": .string(SOGo.color), "room": .string(r["location"]?.string ?? ""), "lecturer": .null, "course_id": .null,
                    "status": .string(cancelled ? "ausfall" : "teilnahme"), "permanent_skip": false,
                    "exception": cancelled ? "cancelled" : .null, "source": .string(SOGo.source), "calendar": .string(r["calendar"]?.string ?? "")]
        }
    }

    static func sameKey(_ o: JSONValue) -> String {
        let title = o["title"]?.string ?? ""
        return "\(o["date"]?.string ?? "")|\(o["start"]?.string ?? "")|\(PyText.lower(SOGo.squash(title)))"
    }

    /// Vorkommen des Planers mit den Terminen des Uni-Kalenders, nach Tag und Beginn; gleicher Tag, Beginn und Titel
    /// wie ein vorhandener kommt nicht doppelt. Ohne Termine unveraendert.
    public static func withCalendar(_ c: SQLiteConnection, _ occ: [JSONValue], from start: Int, to end: Int) throws -> [JSONValue] {
        var extra = try occurrences(c, from: start, to: end)
        guard !extra.isEmpty else { return occ }
        let have = Set(occ.map(sameKey))
        extra = extra.filter { !have.contains(sameKey($0)) }
        guard !extra.isEmpty else { return occ }
        return LocalTimetable.stableSorted(occ + extra) { a, b in
            let (da, db) = (a["date"]?.string ?? "", b["date"]?.string ?? "")
            if da != db { return PyText.less(da, db) }
            return PyText.less(LocalTimetable.or(a["start"], "").string ?? "", LocalTimetable.or(b["start"], "").string ?? "")
        }
    }
}

/// Erste Seite eines Ordners (nur Kopfzeilen) fuer die Anzeige ohne Netz, wie `store_cache`/`cached` in app/sogo.py
public enum SOGoMailCache {
    static let table = "CREATE TABLE IF NOT EXISTS sogo_mail_cache (folder TEXT PRIMARY KEY, data TEXT NOT NULL, fetched_at TEXT)"

    public static func store(_ c: SQLiteConnection, _ listing: JSONValue, fetchedAt: String) throws {
        try c.executeScript(table)
        var keep: [String: JSONValue] = [:]
        for k in ["folder", "total", "pages", "messages", "unseen"] { keep[k] = listing[k] ?? .null }
        _ = try c.execute("INSERT OR REPLACE INTO sogo_mail_cache(folder, data, fetched_at) VALUES (?,?,?)",
                          [.text(listing["folder"]?.string ?? "INBOX"), .text(JSONValue.object(keep).jsonString(sortedKeys: true)), .text(fetchedAt)])
    }

    public static func cached(_ c: SQLiteConnection, folder: String) throws -> JSONValue? {
        guard try StudIPExtras.has(c, "sogo_mail_cache"),
              let r = try c.rows("SELECT data, fetched_at FROM sogo_mail_cache WHERE folder=?", [.text(folder)]).first,
              let d = (r["data"]?.string).flatMap({ try? JSONValue.parse($0) }), var o = d.object else { return nil }
        o["fetched_at"] = r["fetched_at"] ?? .null
        o["stale"] = true
        return .object(o)
    }

    public static func forget(_ c: SQLiteConnection) throws {
        if try StudIPExtras.has(c, "sogo_mail_cache") { _ = try c.execute("DELETE FROM sogo_mail_cache") }
    }
}

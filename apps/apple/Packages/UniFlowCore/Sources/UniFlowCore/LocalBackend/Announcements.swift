import Foundation

/// Ankuendigungen der Lehrenden (Learnweb-Ankuendigungsforen, Stud.IP-Ankuendigungen) mit erkannten Terminen wie
/// app/announcements.py. Die Texte werden gespeichert und die darin genannten Tage erkannt (`extractDates`); die App
/// zeigt sie als Hinweis an den Kalendertagen und auf der Startseite und aendert nie selbst Termine (ein Text ist
/// keine verlaessliche Absage). Tabelle `announcements` (Schema wie am PC), `dates` als JSON-Liste.
public enum Announcements {

    /// `KIND_LABELS`
    public static let kindLabels: [String: String] = ["ausfall": "Ausfall?", "verlegt": "Verlegung?", "raum": "Raum", "pruefung": "Prüfung",
                                                      "frist": "Frist", "online": "Online", "termin": "Termin"]

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

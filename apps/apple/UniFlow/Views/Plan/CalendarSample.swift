import Foundation
import UniFlowCore

/// Nur Debug (-UFCalendarSample YES): Demo-Inhalte und dazu erfundene Kalenderdaten der laufenden Woche fuer
/// Bildvergleiche des Kalenders (03.11.2026): drei gleichzeitige Termine mit langen Namen am Mittwoch, zwei am
/// Donnerstag, Ankuendigungen mit Ausfall, Klausur und Raumwechsel, eine Learnweb-Frist. Alles erfunden, nur im
/// lokalen Backend des Simulators; ein zweiter Start ersetzt die Beispieldaten statt sie zu verdoppeln.
enum CalendarSample {
    @MainActor
    static func seed(_ api: APIClient?) async {
        #if DEBUG
        guard let api, api.isLocal, let host = (api.transport as? LocalTransport)?.host else { return }
        _ = try? await api.value("/api/demo", method: "POST", body: ["enabled": .bool(true)])
        let monday = PlanData.monday(Date())
        func day(_ n: Int) -> String { Fmt.isoDay(PlanData.add(monday, n)) }
        func dm(_ n: Int) -> String {
            let c = PlanData.cal.dateComponents([.day, .month], from: PlanData.add(monday, n))
            return String(format: "%02d.%02d.", c.day ?? 0, c.month ?? 0)
        }
        let now = "\(day(0))T08:00:00", due = "\(day(4))T23:59"
        let modules: [(name: String, color: String, course: String, title: String, kind: String, weekday: Int, start: String, end: String)] = [
            ("Biologie für das Lehramt", "#1f9d5b", "sample-bio", "Biologie für das Lehramt – Vorlesung", "vorlesung", 2, "10:15", "11:45"),
            ("Einführung in die Erziehungswissenschaft", "#d9851e", "sample-ew", "Einführung in die Erziehungswissenschaft", "vorlesung", 2, "10:15", "11:45"),
            ("Englische Sprachwissenschaft", "#2f7fd1", "sample-en", "Englische Sprachwissenschaft – Seminar", "seminar", 2, "10:00", "12:00"),
            ("Bildungsforschung", "#d64545", "sample-bf", "Bildungsforschung – Übung", "uebung", 3, "14:15", "15:45"),
        ]
        let items: [Announcements.Item] = [
            Announcements.make(id: "sample-news-1", source: "studip", courseID: "sample-bio", title: "Vorlesung am Donnerstag",
                               bodyHTML: "<p>Die Vorlesung am \(dm(3)) fällt aus. Die Übung findet wie gewohnt statt.</p>", author: "",
                               postedAt: "\(day(0))T09:00:00+01:00", url: "https://studip.example/news/sample-1", today: 0),
            Announcements.make(id: "sample-news-2", source: "learnweb", courseID: "sample-ew", title: "Klausurtermin",
                               bodyHTML: "<p>Die Klausur findet am \(dm(4)) um 10:00 Uhr im Audimax statt.</p>", author: "",
                               postedAt: "\(day(0))T10:00:00+01:00", url: "https://learnweb.example/mod/forum/discuss.php?d=1", today: 0),
            Announcements.make(id: "sample-news-3", source: "studip", courseID: "sample-en", title: "Raumwechsel",
                               bodyHTML: "<p>Das Seminar am \(dm(2)) findet in Raum C 112 statt.</p>", author: "",
                               postedAt: "\(day(0))T11:00:00+01:00", url: "https://studip.example/news/sample-3", today: 0),
        ]
        do {
            try await host.backend().context.database.transaction { c in
                try c.execute("DELETE FROM course_events WHERE source='sample'")
                try c.execute("DELETE FROM deadlines WHERE id LIKE 'sample-%'")
                for m in modules {
                    if try c.rows("SELECT id FROM modules WHERE name=?", [.text(m.name)]).isEmpty {
                        try c.execute("INSERT INTO modules(name, color, sort, created_at) VALUES (?,?,9,?)", [.text(m.name), .text(m.color), .text(now)])
                    }
                    let mid = try c.rows("SELECT id FROM modules WHERE name=?", [.text(m.name)]).first?["id"]?.int ?? 0
                    try c.execute("INSERT OR REPLACE INTO courses(id, title, semester, kind, active, module_id, created_at) VALUES (?,?,?,?,1,?,?)",
                                  [.text(m.course), .text(m.name), .text("WiSe 2026/27"), .text(m.kind), .integer(Int64(mid)), .text(now)])
                    try c.execute("""
                        INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                        VALUES (?,?,?,?,?,?,?,'weekly',1,'sample',?)
                        """, [.integer(Int64(mid)), .text(m.course), .text(m.title), .text(m.kind), .integer(Int64(m.weekday)),
                              .text(m.start), .text(m.end), .text(now)])
                }
                // Biologie auch donnerstags (die abgesagte Vorlesung) und Erziehungswissenschaft gleichzeitig
                let bio = try c.rows("SELECT id FROM modules WHERE name='Biologie für das Lehramt'").first?["id"]?.int ?? 0
                let ew = try c.rows("SELECT id FROM modules WHERE name='Einführung in die Erziehungswissenschaft'").first?["id"]?.int ?? 0
                for (mid, course, title) in [(bio, "sample-bio", "Biologie für das Lehramt – Vorlesung"), (ew, "sample-ew", "Einführung in die Erziehungswissenschaft – Tutorium")] {
                    try c.execute("""
                        INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                        VALUES (?,?,?,?,3,'10:15','11:45','weekly',1,'sample',?)
                        """, [.integer(Int64(mid)), .text(course), .text(title), .text(title.hasSuffix("Tutorium") ? "tutorium" : "vorlesung"), .text(now)])
                }
                try c.execute("""
                    INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                    VALUES ('sample-dl-1','learnweb','sample-ew','Hausaufgabe 3','Hausaufgabe 3 ist fällig','abgabe','assign',?,?,0,?)
                    """, [.text(due), .text("https://learnweb.example/mod/assign/view.php?id=3"), .text(now)])
                _ = try Announcements.store(c, items.filter { $0.source == "studip" }, source: "studip", fetchedAt: now)
                _ = try Announcements.store(c, items.filter { $0.source == "learnweb" }, source: "learnweb", fetchedAt: now)
            }
        } catch {
            print("CalendarSample: \(error)")
        }
        #endif
    }
}

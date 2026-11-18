import XCTest
@testable import UniFlowCore

/// Mitteilung "Ausfall, Raumänderung oder Verlegung heute oder morgen" (Auftrag des Inhabers 17.11.2026): Rechnung im
/// Kern, mit derselben Stundenplan-Rechnung wie Woche und Stundenplan. Erfundene Termine.
final class ScheduleChangesTests: XCTestCase {
    /// Mittwoch, 11.11.2026, 10:00 Berlin (Mittwoch = Wochentag 2, Donnerstag = 3)
    private let clock = UniFlowClock.fixed(berlin: "2026-11-11T10:00:00")!

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
    }

    private func snapshot(_ b: LocalBackend) async throws -> ScheduleSnapshot? {
        let clock = self.clock
        return try await b.context.database.withConnection { ScheduleSnapshot.read($0, clock: clock) }
    }

    private func event(_ b: LocalBackend, _ title: String, weekday: Int, start: String, room: String, attend: Int = 1) async throws {
        try await b.context.database.execute("""
            INSERT INTO course_events(title, kind, weekday, start_time, end_time, room, rrule, date_from, date_to, attend, source, created_at)
            VALUES (?, 'vorlesung', ?, ?, '11:30', ?, 'weekly', '2026-10-12', '2027-02-05', ?, 'lsf', 'x')
            """, [.text(title), .integer(Int64(weekday)), .text(start), .text(room), .integer(Int64(attend))])
    }

    func testReadsTodayAndTomorrowOnlyAttendedEvents() async throws {
        let b = try await backend()
        try await event(b, "Analysis A (erfunden)", weekday: 2, start: "10:00", room: "A 101")
        try await event(b, "Numerik B (erfunden)", weekday: 3, start: "08:15", room: "B 202")
        try await event(b, "Freitagstermin", weekday: 4, start: "08:15", room: "C 303")
        try await event(b, "Nicht besucht", weekday: 2, start: "12:00", room: "D 404", attend: 0)
        let read = try await snapshot(b)
        let s = try XCTUnwrap(read)
        XCTAssertEqual(s.today, "2026-11-11")
        XCTAssertEqual(Set(s.entries.values.map(\.title)), ["Analysis A (erfunden)", "Numerik B (erfunden)"])
        XCTAssertEqual(Set(s.entries.values.map(\.date)), ["2026-11-11", "2026-11-12"])
    }

    func testCancelledRoomAndMovedAreChangesOnlyForKnownEvents() async throws {
        let b = try await backend()
        try await event(b, "Analysis A (erfunden)", weekday: 2, start: "10:00", room: "A 101")
        try await event(b, "Numerik B (erfunden)", weekday: 3, start: "08:15", room: "B 202")
        let before = try await snapshot(b)
        // erster Stand ohne Termine: keine Neuigkeit
        XCTAssertEqual(ScheduleSnapshot.changes(before: ScheduleSnapshot(today: "2026-11-11", entries: [:]), after: before), [])
        XCTAssertEqual(ScheduleSnapshot.changes(before: nil, after: before), [])
        XCTAssertEqual(ScheduleSnapshot.changes(before: before, after: before), [], "nichts geaendert")

        // heute faellt Analysis aus, morgen ist Numerik in einem anderen Raum, dazu ein neuer Termin (keine Neuigkeit)
        try await b.context.database.execute("INSERT INTO event_exceptions(event_id, date, type) VALUES (1, '2026-11-11', 'cancelled')")
        try await b.context.database.execute("UPDATE course_events SET room='B 302' WHERE id=2")
        try await event(b, "Neuer Kurs", weekday: 2, start: "14:00", room: "E 1")
        let after = try await snapshot(b)
        let c = ScheduleSnapshot.changes(before: before, after: after)
        XCTAssertEqual(c.map(\.kind), [.cancelled, .room])
        XCTAssertEqual(c.map(\.today), [true, false])
        XCTAssertEqual(c[1].oldRoom, "B 202")
        XCTAssertEqual(c[1].entry.room, "B 302")
        XCTAssertNotEqual(c[0].id, c[1].id)

        // verlegt: andere Zeit
        try await b.context.database.execute("INSERT INTO event_exceptions(event_id, date, type, new_start, new_end) VALUES (2, '2026-11-12', 'moved', '12:00', '13:30')")
        let later = try await snapshot(b)
        let moved = ScheduleSnapshot.changes(before: after, after: later)
        XCTAssertEqual(moved.map(\.kind), [.moved])
        XCTAssertEqual(moved.first?.entry.start, "12:00")
    }

    func testHolidayIsNoNews() {
        let today = "2026-12-24"
        let a = ScheduleEntry(key: "1|2026-12-24", title: "X", date: today, start: "10:00", room: "A", status: "teilnahme")
        let b = ScheduleEntry(key: "1|2026-12-24", title: "X", date: today, start: "10:00", room: "A", status: "ausfall", exception: "vorlesungsfrei")
        XCTAssertEqual(ScheduleSnapshot.changes(before: ScheduleSnapshot(today: today, entries: [a.key: a]),
                                                after: ScheduleSnapshot(today: today, entries: [b.key: b])), [])
    }
}

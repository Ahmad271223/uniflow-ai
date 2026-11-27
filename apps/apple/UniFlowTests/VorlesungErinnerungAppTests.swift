import XCTest
import UniFlowCore
@testable import UniFlow

/// Erinnerung vor der Vorlesung (Entscheidung des Inhabers 27.11.2026: Schalter, Vorgabe aus): Planung aus dem
/// Stundenplan der echten lokalen Datenbank, Ausfall/Verlegung/Bearbeitung, Zeit vorher, Grenze, Platz fuer Abgaben,
/// Erlaubnis erst beim Einschalten, Ausschalten nimmt alles zurueck, fremde Mitteilungen bleiben.
@MainActor
final class VorlesungErinnerungAppTests: XCTestCase {
    final class Fake: DueNotifying {
        var state: DueNotificationStatus = .notDetermined
        var grant = true
        var requests = 0
        var pending: [String: DueReminders.Reminder] = [:]
        var foreign: Set<String> = ["de.uniflow.ai.due.x.1.d3", "de.uniflow.ai.sync.files"]
        func status() async -> DueNotificationStatus { state }
        func requestPermission() async -> Bool { requests += 1; state = grant ? .allowed : .denied; return grant }
        func pendingIdentifiers() async -> [String] { Array(pending.keys) + Array(foreign) }
        func schedule(_ r: DueReminders.Reminder) async { pending[r.identifier] = r }
        func remove(_ identifiers: [String]) { for i in identifiers { pending[i] = nil; foreign.remove(i) } }
    }

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "vorlesung-erinnerung-\(UUID().uuidString)")
    }

    private func backend() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vorlesung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-26T09:00:00")!)
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func at(_ day: String, _ time: String) throws -> Date { try XCTUnwrap(HomeWidgetClock.date(day: day, time: time)) }

    /// Do. 10:15 Analysis (F 102), Fr. 08:15 Programmieren (Audimax); 3.12. Ausfall, 27.11. auf Sa. 10:00 verlegt
    private func timetable(_ api: APIClient) async throws -> (a: Int, p: Int) {
        let analysis = try await api.value("/api/timetable/events", method: "POST", body: [
            "title": "Analysis I", "kind": "vorlesung", "weekday": 3, "start_time": "10:15", "end_time": "11:45",
            "room": "F 102", "date_from": "2026-11-01", "date_to": "2027-01-30"])
        let prog = try await api.value("/api/timetable/events", method: "POST", body: [
            "title": "Programmieren", "kind": "uebung", "weekday": 4, "start_time": "08:15", "end_time": "09:45",
            "room": "Audimax", "date_from": "2026-11-01", "date_to": "2027-01-30"])
        let a = try XCTUnwrap(analysis.i("id")), p = try XCTUnwrap(prog.i("id"))
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(a)), "date": "2026-12-03", "type": "cancelled"])
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(p)), "date": "2026-11-27", "type": "moved", "new_date": "2026-11-28", "new_start": "10:00", "new_end": "11:30"])
        return (a, p)
    }

    private func scheduler(_ f: Fake, now: Date) -> LectureReminderScheduler {
        let s = LectureReminderScheduler(notifier: f, defaults: defaults)
        s.now = { now }
        return s
    }

    func testOffByDefaultAndAsksOnlyWhenSwitchedOn() async throws {
        let api = try backend()
        _ = try await timetable(api)
        let f = Fake()
        let s = scheduler(f, now: try at("2026-11-26", "09:00"))
        XCTAssertFalse(s.enabled, "Vorgabe aus")
        await s.refresh(api: api, container: "c1", demo: false)
        XCTAssertEqual(f.requests, 0, "ohne Schalter fragt niemand iOS")
        XCTAssertTrue(f.pending.isEmpty)
        XCTAssertEqual(LectureReminderScheduler.reserved(defaults), 0)

        f.grant = false
        let refused = await s.setEnabled(true, api: api, container: "c1", demo: false)
        XCTAssertFalse(refused)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(defaults.bool(forKey: LectureReminderScheduler.enabledKey))
        XCTAssertTrue(f.pending.isEmpty)
    }

    func testPlansFromTheRealTimetable() async throws {
        let api = try backend()
        _ = try await timetable(api)
        let f = Fake()
        let s = scheduler(f, now: try at("2026-11-26", "09:00"))
        let ok = await s.setEnabled(true, api: api, container: "c1", demo: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(LectureReminderScheduler.reserved(defaults), LectureReminders.budget, "Abgaben ruecken zusammen")
        let mine = f.pending.values.sorted { $0.fireAt < $1.fireAt }
        XCTAssertEqual(mine.first?.fireAt, try at("2026-11-26", "10:05"), "10 Minuten vor 10:15")
        XCTAssertEqual(mine.first?.title, "In 10 Min: Analysis I")
        XCTAssertEqual(mine.first?.body, "10:15–11:45 · F 102")
        XCTAssertEqual(mine.first?.route, "#/timetable?date=2026-11-26")
        XCTAssertTrue(mine.allSatisfy { $0.identifier.hasPrefix("de.uniflow.ai.lecture.c1.") && !$0.identifier.contains(" ") })
        // verlegt: Fr. 27.11. 8:15 meldet sich nicht, dafuer Sa. 28.11. 10:00; Ausfall 3.12. meldet sich nicht
        let fires = Set(mine.map(\.fireAt))
        XCTAssertFalse(fires.contains(try at("2026-11-27", "08:05")))
        XCTAssertTrue(fires.contains(try at("2026-11-28", "09:50")))
        XCTAssertFalse(fires.contains(try at("2026-12-03", "10:05")), "Ausfall")
        XCTAssertTrue(fires.contains(try at("2026-12-04", "08:05")))
        XCTAssertEqual(mine.count, 3, "zwei Wochen ab heute: 26.11., 28.11., 4.12. (ohne 3.12.)")
        XCTAssertEqual(Set(mine.map(\.fireAt)).count, mine.count)
        XCTAssertEqual(f.foreign.count, 2, "fremde Mitteilungen bleiben")
    }

    func testChangesInTheAppReplanAndNothingDoubles() async throws {
        let api = try backend()
        let (a, p) = try await timetable(api)
        let f = Fake()
        let s = scheduler(f, now: try at("2026-11-26", "09:00"))
        await s.setEnabled(true, api: api, container: "c1", demo: false)
        let before = Set(f.pending.keys)
        await s.refresh(api: api, container: "c1", demo: false)
        XCTAssertEqual(Set(f.pending.keys), before, "zweiter Lauf ohne Aenderung")

        // heute spaeter, Programmieren geloescht
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(a)), "date": "2026-11-26", "type": "edit", "new_start": "10:30", "new_end": "12:00"])
        _ = try await api.value("/api/timetable/events/\(p)", method: "DELETE")
        await s.refresh(api: api, container: "c1", demo: false)
        let fires = f.pending.values.map(\.fireAt).sorted()
        XCTAssertEqual(fires, [try at("2026-11-26", "10:20")], "nur noch Analysis heute, jetzt um 10:30 (3.12. faellt aus)")
        XCTAssertEqual(f.pending.values.first?.body, "10:30–12:00 · F 102")
        // als ausgefallen markiert: keine Erinnerung mehr
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(a)), "date": "2026-11-26", "type": "cancelled"])
        await s.refresh(api: api, container: "c1", demo: false)
        XCTAssertTrue(f.pending.isEmpty)
    }

    func testLeadTimeLimitDemoAndOff() async throws {
        let api = try backend()
        _ = try await timetable(api)
        let f = Fake()
        let s = scheduler(f, now: try at("2026-11-26", "10:10"))
        await s.setEnabled(true, api: api, container: "c1", demo: false)
        XCTAssertFalse(f.pending.values.contains { $0.fireAt <= (try! at("2026-11-26", "10:10")) }, "nichts in der Vergangenheit")
        await s.setLead(30, api: api, container: "c1", demo: false)
        XCTAssertEqual(s.lead, 30)
        XCTAssertTrue(f.pending.values.allSatisfy { $0.title.hasPrefix("In 30 Min: ") })
        XCTAssertEqual(f.pending.values.map(\.fireAt).min(), try at("2026-11-28", "09:30"), "heute 9:45 ist schon vorbei")
        await s.setLead(7, api: api, container: "c1", demo: false)
        XCTAssertEqual(s.lead, 30, "nur 5, 10, 15, 30")
        XCTAssertEqual(LectureReminderScheduler(notifier: f, defaults: defaults).lead, 30, "gemerkt")

        await s.refresh(api: api, container: "c1", demo: true)
        XCTAssertTrue(f.pending.isEmpty, "Demo plant nichts")
        await s.refresh(api: api, container: "c1", demo: false)
        XCTAssertFalse(f.pending.isEmpty)
        f.state = .denied
        await s.refresh(api: api, container: "c1", demo: false)
        XCTAssertTrue(f.pending.isEmpty, "ohne Erlaubnis von iOS zurueckgenommen")
        f.state = .allowed
        await s.refresh(api: api, container: "c1", demo: false)
        await s.setEnabled(false, api: api, container: "c1", demo: false)
        XCTAssertTrue(f.pending.isEmpty)
        XCTAssertEqual(f.foreign.count, 2, "Abgaben und Abgleich bleiben")
        XCTAssertEqual(LectureReminderScheduler.reserved(defaults), 0)
    }

    func testPlanRulesWithoutDatabase() throws {
        func ev(_ title: String, _ start: String, _ end: String, status: String = "teilnahme", id: Int) -> JSONValue {
            ["event_id": .number(Double(id)), "title": .string(title), "start": .string(start), "end": .string(end),
             "status": .string(status), "room": "R 1"]
        }
        var events: [JSONValue] = []
        for h in 8..<20 { events.append(ev("Kurs \(h)", String(format: "%02d:00", h), String(format: "%02d:45", h), id: h)) }
        events.append(ev("Nicht besucht", "07:00", "07:30", status: "nicht_teilnahme", id: 99))
        let week: JSONValue = ["days": [["date": "2026-11-30", "events": .array(events)]]]
        let now = try at("2026-11-30", "06:00")
        let plan = LectureReminders.plan(weeks: [week], cancelled: [], container: "c", lead: 15, now: now)
        XCTAssertEqual(plan.count, LectureReminders.budget, "hoechstens \(LectureReminders.budget)")
        XCTAssertEqual(plan.first?.fireAt, try at("2026-11-30", "07:45"), "die fruehesten zuerst, ohne den nicht besuchten")
        XCTAssertEqual(plan.first?.title, "In 15 Min: Kurs 8")
        XCTAssertEqual(LectureReminders.plan(weeks: [week], cancelled: [], container: "c", lead: 15, now: now, limit: 3).count, 3)
        XCTAssertEqual(LectureReminders.safe("t|2026-11-30|08:00|Lineare Algebra. I"), "t|2026-11-30|08_00|Lineare_Algebra__I")
        let d = LectureReminders.diff(pending: ["de.uniflow.ai.lecture.c.alt", "de.uniflow.ai.due.c.x", plan[0].identifier], planned: plan)
        XCTAssertEqual(d.remove, ["de.uniflow.ai.lecture.c.alt"])
        XCTAssertEqual(d.add.count, plan.count - 1)
        XCTAssertTrue(DueNotificationDelegate.isOwn(plan[0].identifier), "Banner im Vordergrund und Antippen oeffnet den Tag")
        XCTAssertEqual(DueNotificationDelegate.route(identifier: plan[0].identifier, userInfo: ["route": "#/timetable?date=2026-11-30"]),
                       "#/timetable?date=2026-11-30")
    }
}

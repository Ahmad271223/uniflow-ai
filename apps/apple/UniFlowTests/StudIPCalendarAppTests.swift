import XCTest
import UniFlowCore
@testable import UniFlow

/// Eigener Stud.IP-Kalender im lokalen Modus: der Abgleich uebernimmt nur die Termine, die Stud.IP dem Nutzer selbst
/// zeigt, und stellt zwei Fragen (Kurs ohne Kalendertermine, Kurs mit vielen Serien je Woche). Erfundene Antworten aus
/// packages/shared-contracts/fixtures/studip-schedule/kalender. Uhr: 25.10.2026, 14:30.
@MainActor
final class StudIPCalendarAppTests: XCTestCase {

    private static let courses = [
        StudIPCourse(id: "k-vl", title: "Testvorlesung Kalender", number: "8001", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "k-ue", title: "Übung Testvorlesung Kalender", number: "8002", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "k-prog", title: "Übung Testprogrammierung Kalender", number: "8003", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "k-frei", title: "Testmathe ohne Kalender", number: "8004", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "k-frage", title: "Fragestunden Testmathe", number: "8005", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "k-tut", title: "Tutorium Testphysik", number: "8006", semesterTitle: "WiSe 2026/27"),
    ]
    private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-kalender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func fixture(_ name: String, type: String = "application/vnd.api+json") throws -> HTTPReply {
        // .../apps/apple/UniFlowTests/StudIPCalendarAppTests.swift -> Repository-Wurzel
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/kalender/\(name)"))
        return HTTPReply(status: 200, contentType: type, body: data)
    }

    private func studIP(calendar: Bool = true) throws -> StudIPClient {
        var routes: [String: HTTPReply] = [
            "/jsonapi.php/v1/users/u-test/schedule": try fixture("users-schedule.json"),
            "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester,end-semester": try fixture("users-courses.json"),
        ]
        for c in Self.courses { routes["/jsonapi.php/v1/courses/\(c.id)/events?page[limit]=200"] = try fixture("course-events-\(c.id).json") }
        if calendar { routes["/jsonapi.php/v1/users/u-test/events.ics"] = try fixture("users-events.ics", type: "text/calendar; charset=utf-8") }
        return StudIPClient(base: URL(string: "https://studip.test")!, transport: TimetableLocalAppTests.FixtureTransport(routes), pauseMillis: 0)
    }

    private func api(_ h: LocalBackendHost) -> APIClient { APIClient(base: APIClient.localBase, transport: LocalTransport(host: h)) }

    /// Abgleich mit Kalender: Zusammenfassung nennt die Fragen, keine Gruppenwahl offen; die Antworten wirken sofort
    /// und gelten beim naechsten Abgleich weiter
    func testCalendarSyncAsksAndRemembersAnswers() async throws {
        let h = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock)
        let out = await StudIPScheduleSync(host: h).run(client: try studIP(), userID: "u-test", courses: Self.courses)
        XCTAssertEqual(out.summary, ["11 Stundenplan-Termine", "2 Fragen zu deinen Kursen im Stundenplan"])
        XCTAssertFalse(out.calendarFailed)

        let a = api(h)
        let q = try await a.value("/api/timetable/studip-questions")
        XCTAssertEqual(q.list("hidden").map { $0.s("title") ?? "" }, ["Testmathe ohne Kalender"])
        XCTAssertEqual(StudIPCalendarQuestions.hiddenText("Testmathe ohne Kalender"),
                       "Du bist in „Testmathe ohne Kalender“ eingetragen, aber der Kurs steht nicht in deinem Stud.IP-Kalender.")
        let busy = try XCTUnwrap(q.list("busy").first)
        XCTAssertEqual(busy.s("title"), "Fragestunden Testmathe")
        XCTAssertEqual(busy.list("times").count, 4)
        let status = try await a.value("/api/timetable/auto-status")
        XCTAssertEqual(status.i("pending_groups"), 0)

        // Woche wie TimetableView: kein Termin des Kurses ohne Kalender, eine Tutoriumsserie trotz zwei Raeumen
        let week = try await a.value("/api/timetable/week?start=2026-10-26")
        let titles = week.list("days").flatMap { $0.list("events") }.compactMap { $0.s("title") }
        XCTAssertFalse(titles.contains("Testmathe ohne Kalender"))
        XCTAssertEqual(titles.filter { $0 == "Tutorium Testphysik" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Fragestunden Testmathe" }.count, 4)

        // Antworten: Kurs uebernehmen, zwei Fragestunden abwaehlen
        let take = try await a.value("/api/timetable/studip-questions/course", method: "POST", body: ["course_id": "k-frei", "include": true])
        XCTAssertEqual(take.i("new"), 2)
        let ids = busy.list("times").compactMap { $0.s("cycle_id") }
        _ = try await a.value("/api/timetable/studip-questions/times", method: "POST", body: ["course_id": "k-frage", "attend": .array(ids.prefix(2).map(JSONValue.string))])
        let after = try await a.value("/api/timetable/studip-questions")
        XCTAssertTrue(after.list("hidden").isEmpty && after.list("busy").isEmpty)
        let events = try await a.value("/api/timetable/events").items.filter { $0.s("title") == "Fragestunden Testmathe" }
        XCTAssertEqual(events.filter { $0.i("attend") == 0 }.count, 2, "abgewählt: grau, Zeit frei")

        let again = await StudIPScheduleSync(host: h).run(client: try studIP(), userID: "u-test", courses: Self.courses)
        XCTAssertEqual(again.summary, [], "nichts neu, nichts entfernt, keine Frage mehr")
    }

    /// Ohne Kalender (alte Stud.IP-Fassung): bisherige Regel und ein ehrlicher Hinweis
    func testWithoutCalendarSummaryIsHonest() async throws {
        let h = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock)
        let out = await StudIPScheduleSync(host: h).run(client: try studIP(calendar: false), userID: "u-test", courses: Self.courses)
        XCTAssertTrue(out.calendarFailed)
        XCTAssertTrue(out.summary.contains("Übungsgruppen zur Auswahl im Stundenplan"))
        XCTAssertEqual(out.summary.last, "Stud.IP-Kalender nicht gelesen: eigene Übungsgruppen nicht sicher bekannt")
        let q = try await api(h).value("/api/timetable/studip-questions")
        XCTAssertTrue(q.list("hidden").isEmpty && q.list("busy").isEmpty)
    }

    /// Antworten liegen in der Datenbank des Containers: je Nutzer und Hochschule getrennt (Uni-Wechsel, anderes Konto)
    func testAnswersStayInTheirContainer() async throws {
        let base = try tempDir()
        func host(_ user: String, _ uni: UniversityKey) -> LocalBackendHost {
            let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: uni))
            return LocalBackendHost(directory: layout.databaseDirectory, clock: clock, university: uni)
        }
        let luh = host("001234.erfunden-ada", .luh)
        _ = await StudIPScheduleSync(host: luh).run(client: try studIP(), userID: "u-test", courses: Self.courses)
        _ = try await api(luh).value("/api/timetable/studip-questions/course", method: "POST", body: ["course_id": "k-frei", "include": false])

        // Wechsel zur Universitaet Hildesheim: eigener Container, keine Antworten, keine Fragen aus Stud.IP
        let hi = host("001234.erfunden-ada", .hildesheim)
        let hq = try await api(hi).value("/api/timetable/studip-questions")
        XCTAssertTrue(hq.list("hidden").isEmpty && hq.list("busy").isEmpty)

        // anderes Konto an der LUH: fragt selbst
        let bob = host("009876.erfunden-bob", .luh)
        _ = await StudIPScheduleSync(host: bob).run(client: try studIP(), userID: "u-test", courses: Self.courses)
        let bq = try await api(bob).value("/api/timetable/studip-questions")
        XCTAssertEqual(bq.list("hidden").map { $0.s("course_id") ?? "" }, ["k-frei"])

        // zurueck: die Antwort der LUH gilt weiter
        let lq = try await api(luh).value("/api/timetable/studip-questions")
        XCTAssertTrue(lq.list("hidden").isEmpty)
        let again = await StudIPScheduleSync(host: luh).run(client: try studIP(), userID: "u-test", courses: Self.courses)
        XCTAssertEqual(again.result?.openQuestions, 1, "nur die Fragestunden, der weggelassene Kurs fragt nicht erneut")
    }
}

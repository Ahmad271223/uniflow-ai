import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Reihenfolge des Abgleichs auf dem iPad (Wunsch des Inhabers 05.11.2026, `SyncOrder`, docs/SYNC-REIHENFOLGE-2026-11-05.md):
/// ein Studierender im 7. Semester sieht sein Semester und den Stundenplan nach Stufe (a), ohne dass ein frueheres
/// Semester abgefragt wurde; Stufe (d) laedt danach neuestes Semester zuerst, pausiert und macht weiter. Dazu die
/// Seite Module je Semester und der Hinweis "(3 von 6)". Stud.IP antwortet mit erfundenen Daten, nie ein echter Abruf.
@MainActor
final class SyncOrderAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!

    /// Semester je Kurs: c1 (1. Semester) bis c7 (aktuell), c8 das naechste
    private static let terms: [(id: Int, title: String, start: String, end: String, course: String)] = [
        (1, "WiSe 2023/24", "2023-10-01", "2024-03-31", "Vorlesung Mathematik I"),
        (2, "SoSe 2024", "2024-04-01", "2024-09-30", "Vorlesung Mathematik II"),
        (3, "WiSe 2024/25", "2024-10-01", "2025-03-31", "Vorlesung Elektrotechnik I"),
        (4, "SoSe 2025", "2025-04-01", "2025-09-30", "Vorlesung Elektrotechnik II"),
        (5, "WiSe 2025/26", "2025-10-01", "2026-03-31", "Vorlesung Signale und Systeme"),
        (6, "SoSe 2026", "2026-04-01", "2026-09-30", "Vorlesung Regelungstechnik"),
        (7, "WiSe 2026/27", "2026-10-01", "2027-03-31", "Vorlesung Datenstrukturen"),
        (8, "SoSe 2027", "2027-04-01", "2027-09-30", "Vorlesung Bachelorseminar"),
    ]

    private struct Device {
        let host: LocalBackendHost
        let api: APIClient
        let studipRoot: URL
    }

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(host: host, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)),
                      studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-order-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Stud.IP mit festen Antworten; merkt sich die Abrufe in Reihenfolge
    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [String] = []
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }
        func clear() { lock.lock(); log.removeAll(); lock.unlock() }
        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; lock.unlock() }
        func json(_ path: String, _ text: String) { set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))) }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: StudIPSync.base.absoluteString, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock()
            log.append(key)
            let r = routes[key]
            lock.unlock()
            return r ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }

        func index(_ pred: (String) -> Bool) -> Int? { requested.firstIndex(where: pred) }
        func folders(of course: Int) -> Bool { requested.contains("/jsonapi.php/v1/courses/c\(course)/folders?page[limit]=200") }
    }

    private static func pdf(_ marker: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { ctx in
            ctx.beginPage()
            (marker as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }

    private func portal() -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        let courses = Self.terms.map { s in
            #"{"id":"c\#(s.id)","type":"courses","attributes":{"title":"\#(s.course)"},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s\#(s.id)"}},"end-semester":{"data":{"type":"semesters","id":"s\#(s.id)"}}}}"#
        }.joined(separator: ",")
        let sems = Self.terms.map { s in
            #"{"id":"s\#(s.id)","type":"semesters","attributes":{"title":"\#(s.title)","start":"\#(s.start)T00:00:00+02:00","end":"\#(s.end)T23:59:59+02:00"}}"#
        }.joined(separator: ",")
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"{"data":[\#(courses)],"included":[\#(sems)]}"#)
        t.json("/jsonapi.php/v1/users/u1/schedule", #"{"data":[],"links":{}}"#)
        for s in Self.terms {
            let file = Self.pdf("Blatt \(s.id)")
            t.json("/jsonapi.php/v1/courses/c\(s.id)/folders?page[limit]=200", #"{"data":[{"id":"r\#(s.id)","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            t.json("/jsonapi.php/v1/folders/r\(s.id)/file-refs?page[limit]=500", #"""
                {"data":[{"id":"d\#(s.id)","attributes":{"name":"Blatt \#(s.id).pdf","filesize":\#(file.count),"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}]}
                """#)
            t.json("/jsonapi.php/v1/folders/r\(s.id)/folders?page[limit]=200", #"{"data":[]}"#)
            t.set("/jsonapi.php/v1/file-refs/d\(s.id)/content", HTTPReply(status: 200, contentType: "application/pdf", body: file))
        }
        return t
    }

    private func client(_ t: FakeStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 2, delayNanos: { _ in 0 }))
    }

    // MARK: Stufe (a) vor allem anderen

    func testSeventhSemesterSeesCurrentModulesAndTimetableBeforeAnyOlderRequest() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        for old in 1...6 { XCTAssertFalse(stud.folders(of: old), "c\(old): frueheres Semester im vollen Lauf nicht abgefragt") }
        let lists7 = try XCTUnwrap(stud.index { $0.contains("/courses/c7/folders") })
        let schedule = try XCTUnwrap(stud.index { $0.hasPrefix("/jsonapi.php/v1/users/u1/schedule") })
        let download7 = try XCTUnwrap(stud.index { $0 == "/jsonapi.php/v1/file-refs/d7/content" })
        let download8 = try XCTUnwrap(stud.index { $0 == "/jsonapi.php/v1/file-refs/d8/content" })
        // erstes Einrichten (07.11.2026): Kurse und Stundenplan zuerst, dann Dateilisten und Downloads
        XCTAssertLessThan(schedule, lists7, "erster Lauf: Stundenplan vor den Dateilisten")
        XCTAssertLessThan(schedule, download7, "Stundenplan vor den Downloads")
        XCTAssertLessThan(download7, download8, "aktuelles vor naechstem Semester")

        let status = try await dev.api.value("/api/sync-order")
        XCTAssertEqual(status["current"]?["label"]?.string, "WiSe 2026/27")
        XCTAssertEqual(status["current"]?["ready"]?.bool, true)
        // vor der Antwort auf "Auch frühere Semester laden?" (07.11.2026): nichts Altes steht an, kein Lade-Hinweis
        XCTAssertTrue(status["hint"]?.isNull ?? false, "\(status["hint"] ?? .null)")
        XCTAssertEqual(status["older"]?["pending"]?.int, 0)

        // Module je Semester: aktuelles zuerst, naechstes, dann sechs fruehere, neuestes zuerst, noch ohne Dateien
        let mods = try await dev.api.value("/api/modules").items
        let sem = try await dev.api.value("/api/module-semesters")
        let split = ModuleSemesters.split(mods, sem)
        XCTAssertEqual(split.current.compactMap { $0.s("name") }, ["Datenstrukturen"])
        XCTAssertEqual(split.upcoming.map(\.label), ["SoSe 2027"])
        XCTAssertEqual(split.older.compactMap { $0.s("label") }, ["SoSe 2026", "WiSe 2025/26", "SoSe 2025", "WiSe 2024/25", "SoSe 2024", "WiSe 2023/24"])
        XCTAssertEqual(ModuleSemesters.currentHead(split), "Aktuelles Semester · WiSe 2026/27")
        XCTAssertEqual(ModuleSemesters.countLabel(split.older[0]), "1 Modul · Dateien noch nicht geladen")
        XCTAssertEqual(split.older[0]["items"]?.array?.first?.s("name"), "Regelungstechnik")
        XCTAssertNil(ModuleSemesters.hint(sem), "vor der Antwort kein Hinweis „werden geladen“")
        XCTAssertFalse(ModuleSemesters.stillLoading(sem))
    }

    // MARK: Frage vor Stufe (d) (Wunsch des Inhabers 07.11.2026)

    /// Stufe (d) vor der Antwort (auch im WLAN, `pause` erlaubt alles): kein Abruf eines frueheren Semesters; die Frage
    /// steht an. Ja (`OlderSemestersQuestionHost.answer`) = Nur WLAN, dann neuestes zuerst; die Frage kommt nicht wieder.
    func testNothingOlderBeforeTheAnswerThenYesLoadsNewestFirst() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let db = try await dev.host.backend().context.database
        let today = Self.clock.today
        let load: (Set<String>) async -> Void = { ids in _ = await sync.run(client: self.client(stud), olderOnly: true, olderCourses: ids) }
        stud.clear()
        let none = await OlderSemesterLoader.runStage(db: db, today: today, perTerm: true, pause: { _ in nil }, load: load, wait: {})
        XCTAssertEqual(none, 0, "vor der Antwort kein Lauf")
        for old in 1...6 { XCTAssertFalse(stud.folders(of: old), "c\(old) vor der Antwort nicht abgefragt") }
        let overview = try await dev.api.value("/api/older-semesters")
        XCTAssertTrue(OlderSemestersQuestionHost.shouldAsk(overview), "Frage steht an")
        XCTAssertEqual(overview["semesters"]?.array?.count, 6)
        XCTAssertEqual(overview.s("mode"), "off", "Einstellungen zeigen vor der Antwort Aus")

        let mode = try await OlderSemestersQuestionHost.answer(yes: true, api: dev.api)
        XCTAssertEqual(mode, .wifi)
        let after = try await dev.api.value("/api/older-semesters")
        XCTAssertFalse(OlderSemestersQuestionHost.shouldAsk(after), "beantwortet: keine Frage mehr")
        XCTAssertEqual(after.s("mode"), "wifi")
        let sem = try await dev.api.value("/api/module-semesters")
        XCTAssertEqual(ModuleSemesters.hint(sem), "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (0 von 6)")
        stud.clear()
        let runs = await OlderSemesterLoader.runStage(db: db, today: today, perTerm: true, pause: { _ in nil }, load: load, wait: {})
        XCTAssertEqual(runs, 6)
        XCTAssertEqual(stud.requested.filter { $0.hasSuffix("/folders?page[limit]=200") && $0.contains("/courses/") },
                       [6, 5, 4, 3, 2, 1].map { "/jsonapi.php/v1/courses/c\($0)/folders?page[limit]=200" }, "neuestes Semester zuerst")
        // alte Kurse bleiben aus (nicht im Lernplan/Stundenplan), ihre Dateien liegen in der Bibliothek
        let courses = try await dev.api.value("/api/courses").items
        XCTAssertEqual(Set(courses.filter { $0.i("active") == 1 }.compactMap { $0.s("id") }).subtracting(["__user__"]), ["c7", "c8"])
        // Bibliothek, Ordner "Frühere Semester": Kurs des 1. Semesters mit geladener Datei
        let old = try await dev.api.value("/api/older-semesters/courses/c1/files").items
        XCTAssertEqual(old.map { $0.s("name") }, ["Blatt 1.pdf"])
        XCTAssertEqual(old.first?.i("downloaded"), 1, "Unterlagen des 1. Semesters geladen")
    }

    /// Nein ("Nur aktuelles Semester" = Aus): nichts Altes, auch nach weiteren Abgleichen, keine erneute Frage
    func testAnswerNoLoadsNothingAndAsksNoMore() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let mode = try await OlderSemestersQuestionHost.answer(yes: false, api: dev.api)
        XCTAssertEqual(mode, .off)
        let db = try await dev.host.backend().context.database
        stud.clear()
        await sync.run(client: client(stud))
        let runs = await OlderSemesterLoader.runStage(db: db, today: Self.clock.today, perTerm: true, pause: { _ in nil }, load: { ids in
            _ = await sync.run(client: self.client(stud), olderOnly: true, olderCourses: ids)
        }, wait: {})
        XCTAssertEqual(runs, 0)
        for old in 1...6 { XCTAssertFalse(stud.folders(of: old), "c\(old): Nein heisst nichts Altes") }
        let overview = try await dev.api.value("/api/older-semesters")
        XCTAssertFalse(OlderSemestersQuestionHost.shouldAsk(overview), "keine erneute Frage")
        XCTAssertEqual(overview.s("mode"), "off")
    }

    // MARK: Stufe (d): neuestes zuerst, Pause, fortsetzbar

    func testOlderSemestersLoadNewestFirstPauseAndResume() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let db = try await dev.host.backend().context.database
        let today = Self.clock.today
        // Antwort "Frühere Semester auch laden" (vor der Antwort laedt Stufe d nichts, 07.11.2026)
        _ = try await OlderSemestersQuestionHost.answer(yes: true, api: dev.api)
        stud.clear()
        var asked = 0
        let runs = await OlderSemesterLoader.runStage(db: db, today: today, perTerm: true, pause: { _ in
            asked += 1
            return asked > 3 ? .lowPower : nil                     // nach drei Semestern Stromsparmodus
        }, load: { ids in
            _ = await sync.run(client: self.client(stud), olderOnly: true, olderCourses: ids)
        }, wait: {})
        XCTAssertEqual(runs, 3)
        let order = stud.requested.filter { $0.hasSuffix("/folders?page[limit]=200") && $0.contains("/courses/") }
        XCTAssertEqual(order, [6, 5, 4].map { "/jsonapi.php/v1/courses/c\($0)/folders?page[limit]=200" }, "neuestes Semester zuerst")
        XCTAssertFalse(stud.requested.contains { $0.contains("/schedule") }, "Stufe (d): kein Stundenplan")
        var sem = try await dev.api.value("/api/module-semesters")
        XCTAssertEqual(ModuleSemesters.hint(sem), "Aktuelles Semester ist da · ältere Semester pausiert (Stromsparmodus) (3 von 6)")
        XCTAssertEqual(ModuleSemesters.countLabel(ModuleSemesters.split([], sem).older[0]), "1 Modul · 1 Datei")

        // Stromsparmodus aus: weiter beim naechsten Semester, Geladenes nicht erneut
        stud.clear()
        let more = await OlderSemesterLoader.runStage(db: db, today: today, perTerm: true, pause: { _ in nil }, load: { ids in
            _ = await sync.run(client: self.client(stud), olderOnly: true, olderCourses: ids)
        }, wait: {})
        XCTAssertEqual(more, 3)
        XCTAssertEqual(stud.requested.filter { $0.hasSuffix("/folders?page[limit]=200") && $0.contains("/courses/") },
                       [3, 2, 1].map { "/jsonapi.php/v1/courses/c\($0)/folders?page[limit]=200" })
        sem = try await dev.api.value("/api/module-semesters")
        XCTAssertNil(ModuleSemesters.hint(sem), "alles geladen: kein Hinweis")
        XCTAssertTrue(ModuleSemesters.split([], sem).older.allSatisfy { $0["loaded"]?.bool == true })

        // "Aus": Stufe (d) holt nichts mehr von selbst
        _ = try await dev.api.value("/api/older-semesters/mode", method: "POST", body: ["mode": "off"])
        let none = await OlderSemesterLoader.runStage(db: db, today: today, perTerm: true, pause: { _ in nil }, load: { _ in XCTFail("nichts zu laden") }, wait: {})
        XCTAssertEqual(none, 0)
    }

    // MARK: Seite Module

    func testOlderTermsRenderCollapsedAndOpen() throws {
        let older: [JSONValue] = [
            ["label": "SoSe 2026", "count": 2, "files": 10, "downloaded": 4, "loaded": false,
             "items": [["name": "Regelungstechnik", "module_id": 3, "color": "#4f5bd5", "course_ids": ["c6"], "courses": 1, "files": 6, "downloaded": 4, "loaded": false],
                       ["name": "Werkstoffe", "module_id": .null, "color": .null, "course_ids": ["c9"], "courses": 1, "files": 4, "downloaded": 0, "loaded": false]]],
        ]
        XCTAssertEqual(ModuleSemesters.countLabel(older[0]), "2 Module · 4 von 10 Dateien geladen")
        XCTAssertEqual(ModuleSemesters.itemStatus(older[0]["items"]!.array![0]), "1 Veranstaltung · 4 von 6 Dateien geladen")
        var chosen: [JSONValue] = []
        for open in [Set<String>(), ["SoSe 2026"]] {
            let view = OlderModuleSemesters(older: older, open: .constant(open)) { chosen.append($0) }
            let host = UIHostingController(rootView: view.frame(width: 700))
            host.view.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 700, height: 2000)).height, 40)
        }
        XCTAssertTrue(chosen.isEmpty)
        XCTAssertEqual(ModuleSemesterHint(text: "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)").text,
                       "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)")
    }
}

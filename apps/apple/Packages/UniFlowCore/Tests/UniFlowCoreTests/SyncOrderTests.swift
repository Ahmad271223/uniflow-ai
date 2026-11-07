import Foundation
import XCTest
@testable import UniFlowCore

/// Reihenfolge des Abgleichs (Wunsch des Inhabers 05.11.2026, `SyncOrder`, wie tests/test_sync_order.py): zuerst das
/// aktuelle Semester samt Stundenplan, dann Noten und naechstes Semester, fruehere Semester zuletzt (Stufe d),
/// neuestes zuerst und fortsetzbar. Portal als Stub mit 7 Semestern (Learnweb/Moodle und LSF), nie ein echter Abruf.
final class SyncOrderTests: XCTestCase {
    let base = "https://www.uni-hildesheim.de/learnweb2026"
    let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })
    /// 5.11.2026: WiSe 2026/27 ist das 7. Semester
    let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!

    /// Kurse je Semester: Moodle-ID -> Titel mit Semester wie im Learnweb
    let terms: [(Int, String)] = [(1, "WiSe 2023/24"), (2, "SoSe 2024"), (3, "WiSe 2024/25"), (4, "SoSe 2025"), (5, "WiSe 2025/26"),
                                  (6, "SoSe 2026"), (7, "WiSe 2026/27"), (8, "SoSe 2027")]

    /// Alle Abrufe in Reihenfolge (Learnweb ueber das Netz, LSF ueber den Campus-Stub)
    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func clear() { lock.lock(); items.removeAll(); lock.unlock() }
    }

    actor FakeCampus: UniCampusClient {
        let log: CallLog
        init(_ log: CallLog) { self.log = log }
        func planEntries() async throws -> [LSFCalendar.Entry]? { log.add("plan"); return nil }
        func grades() async throws -> [QISGrade] { log.add("grades"); return [] }
    }

    private func container() async throws -> (SQLiteDatabase, DataContainerLayout) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("so-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.erfunden.0007", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        return (db, layout)
    }

    /// Learnweb mit 8 Kursen (7 Semester und das naechste); je Kurs eine Datei
    private func learnweb(_ log: CallLog) -> FakeUniTransport {
        FakeUniTransport { req in
            let body = String(decoding: req.body ?? Data(), as: UTF8.self)
            if body.contains("wsfunction=core_webservice_get_site_info") { return okJSON(.object(["userid": .number(42)])) }
            if body.contains("wsfunction=core_enrol_get_users_courses") {
                return okJSON(.array(self.terms.map { id, term in
                    .object(["id": .number(Double(id)), "fullname": .string("\(term): 04\(id) Kurs \(id)"), "hidden": .number(0)])
                }))
            }
            if body.contains("wsfunction=core_course_get_contents"), let id = body.split(separator: "&").first?.split(separator: "=").last {
                log.add("files-\(id)")
                return okJSON(.array([.object(["id": .number(1), "name": .string("Woche 1"), "modules": .array([.object([
                    "id": .number(Double(id)! * 10), "modname": .string("resource"), "name": .string("Folien"),
                    "contents": .array([.object(["type": .string("file"), "filename": .string("folien\(id).pdf"), "filepath": .string("/"),
                                                 "filesize": .number(4), "mimetype": .string("application/pdf"), "timemodified": .number(1_790_000_000),
                                                 "fileurl": .string("\(self.base)/webservice/pluginfile.php/\(id)/mod_resource/content/1/folien\(id).pdf")])]),
                ])])])]))
            }
            if req.url.absoluteString.contains("pluginfile.php") {
                log.add("download-\(req.url.absoluteString.split(separator: "/")[5])")
                return UniResponse(status: 200, headers: ["Content-Type": "application/pdf"], body: Data("%PDF-1.4 x".utf8))
            }
            return okJSON(.array([]))
        }
    }

    private func sync(_ db: SQLiteDatabase, _ layout: DataContainerLayout, _ t: FakeUniTransport, _ log: CallLog) -> HildesheimSync {
        HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(LearnwebToken("TOK")!), transport: t, retry: noWait),
                       lsf: FakeCampus(log), transport: t, clock: clock, retry: noWait)
    }

    func testCurrentSemesterAndTimetableComeBeforeAnyOlderSemester() async throws {
        let (db, layout) = try await container()
        let log = CallLog()
        let t = learnweb(log)
        let r = await sync(db, layout, t, log).run()
        XCTAssertFalse(r.cancelled)
        let calls = log.all
        XCTAssertEqual(calls.first, "plan", "Stundenplan vor allen Dateien: \(calls)")
        let older = (1...6).map { "files-\($0)" }
        XCTAssertTrue(Set(calls).isDisjoint(with: older), "der volle Lauf fragt kein frueheres Semester ab: \(calls)")
        let cur = try XCTUnwrap(calls.firstIndex(of: "files-7")), next = try XCTUnwrap(calls.firstIndex(of: "files-8"))
        let grades = try XCTUnwrap(calls.firstIndex(of: "grades"))
        XCTAssertLessThan(cur, next, "aktuelles vor naechstem Semester")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "download-7")), next)
        XCTAssertLessThan(next, grades, "Noten nach den Kursen")
        XCTAssertEqual(r.completed.first, HildesheimSync.Report.Part.learnweb, "Stand je Teil in fester Reihenfolge")

        let status = try await db.withConnection { try SyncOrder.status($0, today: self.clock.today) }
        XCTAssertEqual(status["current"]?["label"]?.string, "WiSe 2026/27")
        XCTAssertEqual(status["current"]?["ready"]?.bool, true)
        XCTAssertEqual(status["older"]?["total"]?.int, 6)
        // vor der Antwort auf "Auch frühere Semester laden?" (07.11.2026): nichts steht an, auch nicht im WLAN
        XCTAssertEqual(status["older"]?["pending"]?.int, 0, "nie gefragt: kein frueheres Semester steht an")
        XCTAssertEqual(status["older"]?["mode"]?.string, "off")
        XCTAssertTrue(status["hint"]?.isNull ?? false, "vor der Antwort kein Hinweis auf Laden: \(status["hint"] ?? .null)")
        let ask = try await db.withConnection { try OlderSemesters.needsQuestion($0, today: self.clock.today) }
        XCTAssertTrue(ask, "Frage steht an")
        log.clear()
        let before = await sync(db, layout, t, log).run(olderOnly: true)
        XCTAssertTrue(log.all.filter { $0.hasPrefix("files-") || $0.hasPrefix("download-") }.isEmpty, "vor der Antwort nichts Altes: \(log.all)")
        XCTAssertEqual(before.olderLoaded.count, 0)

        // Antwort "Frühere Semester auch laden" (Nur WLAN): alle sechs stehen an
        try await db.transaction { try OlderSemesters.setMode($0, OlderSemesters.yesMode, now: "2026-11-05T10:05:00") }
        let asked = try await db.withConnection { try SyncOrder.status($0, today: self.clock.today) }
        XCTAssertEqual(asked["older"]?["pending"]?.int, 6, "nach Ja: alle frueheren Semester stehen an")
        XCTAssertEqual(asked["hint"]?.string, "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (0 von 6)")

        // Stufe (d): nur fruehere Semester, neuestes zuerst, ohne Stundenplan und Noten
        log.clear()
        let o = await sync(db, layout, t, log).run(olderOnly: true)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("files-") }, ["files-6", "files-5", "files-4", "files-3", "files-2", "files-1"])
        XCTAssertFalse(log.all.contains("plan") || log.all.contains("grades"), "\(log.all)")
        XCTAssertEqual(o.olderLoaded.count, 6)
        let after = try await db.withConnection { try SyncOrder.status($0, today: self.clock.today) }
        XCTAssertEqual(after["older"]?["done"]?.int, 6)
        XCTAssertTrue(after["hint"]?.isNull ?? false, "alles geladen: kein Hinweis")
        log.clear()
        _ = await sync(db, layout, t, log).run(olderOnly: true)
        XCTAssertTrue(log.all.filter { $0.hasPrefix("files-") }.isEmpty, "fortsetzbar: Geladenes nicht erneut")
    }

    /// Antwort "Nur aktuelles Semester" (Aus): Stufe (d) laedt nichts, auch nach weiteren vollen Abgleichen; die Frage
    /// kommt nicht wieder; "Dateien laden" fuer ein Semester in der Bibliothek geht weiter
    func testAnswerNoLoadsNothingAndDoesNotAskAgain() async throws {
        let (db, layout) = try await container()
        let log = CallLog()
        let t = learnweb(log)
        _ = await sync(db, layout, t, log).run()
        try await db.transaction { try OlderSemesters.setMode($0, .off, now: "2026-11-05T10:05:00") }
        log.clear()
        _ = await sync(db, layout, t, log).run()
        _ = await sync(db, layout, t, log).run(olderOnly: true)
        XCTAssertTrue(Set(log.all).isDisjoint(with: (1...6).flatMap { ["files-\($0)", "download-\($0)"] }), "Nein: nichts Altes: \(log.all)")
        let (ask, mode) = try await db.withConnection { (try OlderSemesters.needsQuestion($0, today: self.clock.today), try OlderSemesters.mode($0)) }
        XCTAssertFalse(ask, "keine erneute Frage")
        XCTAssertEqual(mode, .off)
        let status = try await db.withConnection { try SyncOrder.status($0, today: self.clock.today) }
        XCTAssertTrue(status["hint"]?.isNull ?? false)
        // ein Semester von Hand nachladen (Bibliothek): nur dieser Kurs
        try await db.transaction { _ = try OlderSemesters.request($0, courseIDs: ["lw-5"], today: self.clock.today, now: "2026-11-05T10:06:00") }
        log.clear()
        _ = await sync(db, layout, t, log).run(olderOnly: true)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("files-") }, ["files-5"])
    }

    func testModulesAreGroupedPerSemester() async throws {
        let (db, layout) = try await container()
        let log = CallLog()
        _ = await sync(db, layout, learnweb(log), log).run()
        let d = try await db.transaction { try SyncOrder.modulesBySemester($0, clock: self.clock) }
        XCTAssertEqual(d["current"]?["label"]?.string, "WiSe 2026/27")
        XCTAssertEqual(d["current"]?["count"]?.int, 1)
        XCTAssertEqual(d["upcoming"]?.array?.map { $0["label"]?.string }, ["SoSe 2027"])
        XCTAssertEqual(d["older"]?.array?.compactMap { $0["label"]?.string },
                       ["SoSe 2026", "WiSe 2025/26", "SoSe 2025", "WiSe 2024/25", "SoSe 2024", "WiSe 2023/24"], "neuestes zuerst")
        let s6 = try XCTUnwrap(d["older"]?.array?.first)
        XCTAssertEqual(s6["count"]?.int, 1)
        XCTAssertEqual(s6["items"]?.array?.first?["name"]?.string, "Kurs 6")
        XCTAssertEqual(s6["items"]?.array?.first?["course_ids"]?.array?.compactMap(\.string), ["lw-6"])
        XCTAssertEqual(s6["loaded"]?.bool, false, "Dateien kommen erst in Stufe (d)")
        // ueber den lokalen Router wie in der App
        let backend = try LocalBackend(database: db, clock: clock)
        for path in ["/api/module-semesters", "/api/sync-order", "/api/older-semesters"] {
            let r = await backend.handle(LocalRequest(method: "GET", path: path, headers: [:], body: Data()))
            XCTAssertEqual(r.status, 200, path)
        }
        let mode = await backend.handle(LocalRequest(method: "POST", path: "/api/older-semesters/mode", headers: ["Content-Type": "application/json"],
                                                     body: Data(#"{"mode":"off"}"#.utf8)))
        XCTAssertEqual(mode.json?["mode"]?.string, "off")
        let older = await backend.handle(LocalRequest(method: "GET", path: "/api/older-semesters", headers: [:], body: Data()))
        XCTAssertEqual(older.json?["mode"]?.string, "off")
        XCTAssertEqual(older.json?["choice"]?.string, "current")
    }

    func testModeAndPolicy() async throws {
        let (db, _) = try await container()
        try await db.transaction { c in
            XCTAssertEqual(try OlderSemesters.mode(c), .off, "Vorgabe solange nie gefragt: Aus (07.11.2026, vorher Nur WLAN)")
            XCTAssertEqual(OlderSemesters.yesMode, .wifi, "Ja auf die Frage: Nur WLAN")
            XCTAssertNil(try OlderSemesters.choice(c), "nie gefragt")
            try OlderSemesters.setChoice(c, .all, now: "2026-11-05T10:00:00")
            XCTAssertEqual(try OlderSemesters.mode(c), .auto, "fruehere Wahl 'alle' = Automatisch")
            try OlderSemesters.setMode(c, .off, now: "2026-11-05T10:01:00")
            XCTAssertEqual(try OlderSemesters.choice(c), .current, "Aus = fruehere Wahl 'nur aktuelles Semester'")
        }
        XCTAssertNil(OlderLoadPolicy.decide(mode: .wifi, lowPower: false, onWiFi: true))
        XCTAssertEqual(OlderLoadPolicy.decide(mode: .wifi, lowPower: false, onWiFi: false), .wifi)
        XCTAssertNil(OlderLoadPolicy.decide(mode: .auto, lowPower: false, onWiFi: false))
        XCTAssertEqual(OlderLoadPolicy.decide(mode: .auto, lowPower: true, onWiFi: true), .lowPower)
        XCTAssertEqual(OlderLoadPolicy.decide(mode: .auto, lowPower: false, onWiFi: true, appOpen: false), .closed)
        XCTAssertEqual(SyncOrder.hintText(currentReady: true, progress: .init(total: 6, done: 3, pending: 3)),
                       "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)")
        XCTAssertEqual(SyncOrder.hintText(currentReady: true, progress: .init(total: 6, done: 2, pending: 4), paused: .lowPower),
                       "Aktuelles Semester ist da · ältere Semester pausiert (Stromsparmodus) (2 von 6)")
        XCTAssertEqual(SyncOrder.hintText(currentReady: false, progress: .init(total: 6, done: 0, pending: 6)), "Aktuelles Semester wird geladen …")
        XCTAssertNil(SyncOrder.hintText(currentReady: true, progress: .init(total: 6, done: 6, pending: 0)))
    }

    func testCurrentTermFromPortalThenDate() {
        let terms = [SyncOrder.PortalTerm(title: "WiSe 2026/27", start: "2026-09-01", end: "2027-02-28"),
                     SyncOrder.PortalTerm(title: "SoSe 2026", start: "2026-03-01", end: "2026-08-31")]
        XCTAssertEqual(SyncOrder.currentTerm(today: "2026-09-15", terms: terms, university: .luh), Semesters.Key(year: 2026, half: 2))
        XCTAssertEqual(SyncOrder.currentTerm(today: "2026-09-15", university: .luh), Semesters.Key(year: 2026, half: 1), "LUH: WiSe ab Oktober")
        XCTAssertEqual(SyncOrder.currentTerm(today: "2026-09-15", university: .hsh), Semesters.Key(year: 2026, half: 2), "HsH: WiSe ab September")
        XCTAssertEqual(SyncOrder.currentTerm(today: "2027-02-10", university: .hsh), Semesters.Key(year: 2026, half: 2))
        XCTAssertEqual(SyncOrder.termKey("20262"), Semesters.Key(year: 2026, half: 2), "LSF-Semesterkennung")
        XCTAssertEqual(SyncOrder.termKey("SoSe 2026"), Semesters.Key(year: 2026, half: 1))
        let cur = Semesters.Key(year: 2026, half: 2)
        XCTAssertEqual(SyncOrder.stage(active: false, semester: "WiSe 2026/27", current: cur), .older)
        XCTAssertEqual(SyncOrder.stage(active: true, semester: "SoSe 2027", current: cur), .upcoming)
        XCTAssertEqual(SyncOrder.stage(active: true, semester: "SoSe 2026", current: cur), .current, "noch laufend (Pruefungszeit)")
        XCTAssertEqual(SyncOrder.stage(active: true, semester: nil, current: cur), .current)
        XCTAssertEqual(SyncOrder.newestFirst(["SoSe 2024", "", "WiSe 2025/26", "SoSe 2025"], semester: { $0 }), ["WiSe 2025/26", "SoSe 2025", "SoSe 2024", ""])
    }

    func testStagesRunInPriorityOrder() async {
        let log = CallLog(), ready = CallLog()
        struct Boom: Error {}
        let out = await SyncOrder.run([
            .init(.older, "alt") { log.add("older") },
            .init(.grades, "noten") { log.add("grades") },
            .init(.current, "plan") { log.add("plan") },
            .init(.upcoming, "next") { log.add("upcoming") },
            .init(.current, "dateien") { throw Boom() },
        ], onStage: { ready.add($0.rawValue) })
        XCTAssertEqual(log.all, ["plan", "grades", "upcoming", "older"])
        XCTAssertEqual(out.map(\.stage), [.current, .current, .grades, .upcoming, .older])
        XCTAssertEqual(out[1], SyncOrder.StepResult(stage: .current, name: "dateien", ok: false), "ein Fehler haelt die uebrigen nicht an")
        XCTAssertEqual(ready.all, ["current", "grades", "upcoming", "older"])
    }
}

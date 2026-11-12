import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Studiengruppen und Faecher im Lernkalender (Auftrag des Inhabers 12.11.2026) im echten Abgleich der App, mit
/// erfundenen Stud.IP-Antworten (example.org, keine Anfrage an eine Hochschule): eine Vorlesung (Art 1) und eine
/// Studiengruppe (Art 99, ohne Nummer, unbegrenzt) mit je zwei Dateien und je einer Kurszeit.
///
/// Bis 12.11.2026 lud der Abgleich eine Studiengruppe wie jeden Kurs (Befund iPad 07.11.2026). Jetzt: Vorgabe alles aus,
/// einmal fragen, je Schalter Dateien, Modul, Termine.
@MainActor
final class StudyGroupsAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-12T10:00:00")!

    private struct Device {
        let host: LocalBackendHost
        let studipRoot: URL
    }

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(host: host, studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-groups-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Stud.IP mit festen Antworten (Pfad -> Antwort), merkt die Abrufe
    final class Portal: StudIPTransport, @unchecked Sendable {
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

        func asked(course: String) -> Bool { requested.contains { $0.contains("/courses/\(course)/") } }
    }

    static func pdf(_ marker: String) -> Data { Data("%PDF-1.4\n% \(marker)\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8) }

    static let files: [String: [(id: String, name: String)]] = [
        "v1": [("v1a", "Analysis_Kap_1.pdf"), ("v1b", "Analysis_Kap_2.pdf")],
        "sg": [("sg1", "Lerngruppe Notizen 1.pdf"), ("sg2", "Lerngruppe Notizen 2.pdf")],
    ]

    func portal() -> Portal {
        let t = Portal()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        let sem = #"{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00","end":"2027-03-31T23:59:59+02:00"}}"#
        let lecture = #"{"id":"v1","type":"courses","attributes":{"title":"Testanalysis I","course-number":"10001","course-type":1},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}},"end-semester":{"data":{"type":"semesters","id":"s1"}}}}"#
        let group = #"{"id":"sg","type":"courses","attributes":{"title":"Lerngruppe Beispiel","course-type":99},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}},"end-semester":{"data":null}}}"#
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"{"data":[\#(lecture),\#(group)],"included":[\#(sem)]}"#)
        let cycle = { (id: String, course: String, weekday: Int, start: String, end: String) in
            #"{"id":"\#(id)","type":"seminar-cycle-dates","attributes":{"title":"Kurszeit","description":"","start":"\#(start)","end":"\#(end)","weekday":\#(weekday),"recurrence":{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12","UNTIL":"2027-01-29"},"locations":["Raum Test"]},"relationships":{"owner":{"data":{"type":"courses","id":"\#(course)"}}}}"#
        }
        t.json("/jsonapi.php/v1/users/u1/schedule",
               #"{"data":[\#(cycle("cy-v1", "v1", 1, "10:00", "11:30")),\#(cycle("cy-sg", "sg", 3, "18:00", "19:30"))],"links":{}}"#)
        for (course, list) in Self.files {
            t.json("/jsonapi.php/v1/courses/\(course)/folders?page[limit]=200",
                   #"{"data":[{"id":"r\#(course)","type":"folders","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            t.json("/jsonapi.php/v1/folders/r\(course)/folders?page[limit]=200", #"{"data":[]}"#)
            let refs = list.map { f in
                #"{"id":"\#(f.id)","type":"file-refs","attributes":{"name":"\#(f.name)","filesize":\#(Self.pdf(f.id).count),"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}"#
            }.joined(separator: ",")
            t.json("/jsonapi.php/v1/folders/r\(course)/file-refs?page[limit]=500", #"{"data":[\#(refs)]}"#)
            for f in list { t.set("/jsonapi.php/v1/file-refs/\(f.id)/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf(f.id))) }
        }
        return t
    }

    func client(_ t: Portal) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    private func rows(_ dev: Device, _ sql: String) async throws -> [[String: JSONValue]] {
        try await dev.host.backend().context.database.rows(sql)
    }

    private func loadedFiles(_ dev: Device) async throws -> Set<String> {
        Set(try await rows(dev, "SELECT id FROM files WHERE COALESCE(local_path,'') <> ''").compactMap { $0["id"]?.string })
    }

    private func groupModule(_ dev: Device) async throws -> String? {
        try await rows(dev, "SELECT m.name FROM courses c JOIN modules m ON m.id=c.module_id WHERE c.id='sg'").first?["name"]?.string
    }

    private func groupEvents(_ dev: Device) async throws -> Int {
        try await rows(dev, "SELECT id FROM course_events WHERE course_id='sg'").count
    }

    // MARK: Erster Abgleich: Gruppe bleibt aus, Frage faellig

    func testFirstSyncLeavesStudyGroupOutAndAsksOnce() async throws {
        let dev = try device()
        let stud = portal()
        let d = try defaults()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: d)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(sync.studyGroups.map(\.id), ["sg"])
        XCTAssertEqual(sync.regularCourses.map(\.id), ["v1"])
        // Vorlesung wie bisher; die Gruppe kostet keinen Abruf ausser der Kursliste und landet nirgends
        let loaded = try await loadedFiles(dev)
        XCTAssertEqual(loaded, ["v1a", "v1b"])
        XCTAssertFalse(stud.asked(course: "sg"), "\(stud.requested)")
        let groupRows = try await rows(dev, "SELECT id FROM courses WHERE id='sg'")
        XCTAssertTrue(groupRows.isEmpty)
        let events = try await groupEvents(dev)
        XCTAssertEqual(events, 0)
        let lectureEvents = try await rows(dev, "SELECT id FROM course_events WHERE course_id='v1'")
        XCTAssertEqual(lectureEvents.count, 1)
        // einmal fragen: faellig, nach dem Zeigen nicht mehr (auch nach einem Neustart)
        XCTAssertTrue(sync.groupsQuestionDue)
        sync.groupSettings.asked = true
        XCTAssertFalse(sync.groupsQuestionDue)
        let again = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: d)
        XCTAssertFalse(again.groupsQuestionDue)
        XCTAssertEqual(again.groupSettings, StudIPStudyGroups.Settings(asked: true))
    }

    // MARK: Schalter wirken

    func testSwitchesLoadFilesModuleAndTimetableAndOffCleansUp() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))

        // nur Dateien: geladen, aber kein Modul und keine Termine
        sync.groupSettings = .init(asked: true, choices: ["sg": .init(files: true)])
        await sync.run(client: client(stud))
        var loaded = try await loadedFiles(dev)
        XCTAssertTrue(loaded.isSuperset(of: ["sg1", "sg2"]), "\(loaded)")
        var module = try await groupModule(dev)
        XCTAssertNil(module)
        var events = try await groupEvents(dev)
        XCTAssertEqual(events, 0)

        // Modul (eigenes) und Termine dazu; das neue Modul plant der Lernkalender nicht von selbst
        sync.groupSettings = .init(asked: true, choices: ["sg": .init(files: true, module: true, timetable: true)])
        await sync.run(client: client(stud))
        module = try await groupModule(dev)
        XCTAssertEqual(module, "Lerngruppe Beispiel")
        events = try await groupEvents(dev)
        XCTAssertEqual(events, 1)
        let off = try await dev.host.backend().context.database.withConnection { try StudyPlanModules.off($0) }
        XCTAssertEqual(off, ["Lerngruppe Beispiel"])
        let names = await sync.moduleNames()
        XCTAssertTrue(names.contains("Testanalysis I") && names.contains("Lerngruppe Beispiel"), "\(names)")

        // anderes Modul gewaehlt
        sync.groupSettings = .init(asked: true, choices: ["sg": .init(files: true, module: true, moduleName: "Testanalysis I", timetable: true)])
        await sync.run(client: client(stud))
        module = try await groupModule(dev)
        XCTAssertEqual(module, "Testanalysis I")

        // alles aus: kein Abruf der Gruppe mehr, Termine und Modul weg; Geladenes bleibt auf dem Geraet
        sync.groupSettings = .init(asked: true, choices: [:])
        stud.clear()
        await sync.run(client: client(stud))
        XCTAssertFalse(stud.asked(course: "sg"), "\(stud.requested)")
        events = try await groupEvents(dev)
        XCTAssertEqual(events, 0)
        module = try await groupModule(dev)
        XCTAssertNil(module)
        loaded = try await loadedFiles(dev)
        XCTAssertTrue(loaded.isSuperset(of: ["v1a", "v1b"]))
    }

    // MARK: Fragen

    func testQuestionRulesAndSaveBody() {
        XCTAssertTrue(StudIPQuestionsHost.shouldAskPlan(["asked": false, "modules": [["name": "A"]]]))
        XCTAssertFalse(StudIPQuestionsHost.shouldAskPlan(["asked": true, "modules": [["name": "A"]]]))
        XCTAssertFalse(StudIPQuestionsHost.shouldAskPlan(["asked": false, "modules": []]), "ohne Module nichts zu fragen")
        // nie waehrend eines anderen Dialogs (und nie beim Schreiben, `OpenDocuments.writing`)
        let overlay = UFOverlay(), sync = StudIPSync()
        XCTAssertFalse(OpenDocuments.shared.writing)
        XCTAssertFalse(StudIPQuestionsHost.busy(overlay: overlay, studip: sync))
        let id = overlay.modal { Text("anderer Dialog") }
        XCTAssertTrue(StudIPQuestionsHost.busy(overlay: overlay, studip: sync))
        overlay.close(id)
        let items = PlanModuleItem.list(["modules": [["name": "Mathe", "color": "#112233", "planned": true], ["name": "Lerngruppe", "planned": false]]])
        XCTAssertEqual(items.map(\.planned), [true, false])
        XCTAssertEqual(PlanModulesSheet.body(items), ["modules": [["name": "Mathe", "planned": true], ["name": "Lerngruppe", "planned": false]]])
        XCTAssertEqual(StudyGroupsText.summary(.init()), "aus")
        XCTAssertEqual(StudyGroupsText.summary(.init(files: true, module: true, timetable: true)), "Dateien · eigenes Modul · Termine")
    }

    // MARK: Bilder

    /// Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR): beide Fragen, hell und dunkel
    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let groups = [StudIPCourse(id: "sg1", title: "Lerngruppe Analysis I", courseType: 99),
                      StudIPCourse(id: "sg2", title: "Fachschaft Maschinenbau", courseType: 99)]
        let modules = ["Analysis I", "Technische Mechanik", "Programmieren"]
        let groupsSheet = StudyGroupsSheet(groups: groups, modules: modules,
                                           choices: ["sg1": .init(files: true, module: true, moduleName: "Analysis I", timetable: true)], asQuestion: true)
        let plan = PlanModulesSheet(items: [PlanModuleItem(name: "Analysis I", color: "#4f46e5", planned: true),
                                            PlanModuleItem(name: "Technische Mechanik", color: "#0ea5e9", planned: true),
                                            PlanModuleItem(name: "Programmieren", color: "#16a34a", planned: true),
                                            PlanModuleItem(name: "Lerngruppe Analysis I", color: "#f59e0b", planned: false)], asQuestion: true)
        try shoot(groupsSheet, name: "studiengruppen", dir: dir)
        try shoot(plan, name: "lernkalender-faecher", dir: dir)
    }

    private func shoot<V: View>(_ view: V, name: String, dir: URL) throws {
        let suite = "uniflow-groups-shot-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = ZStack {
            UF.bg.ignoresSafeArea()
            Color(red: 10 / 255, green: 12 / 255, blue: 24 / 255).opacity(0.45).ignoresSafeArea()
            ScrollView { view.frame(maxWidth: 620).padding(16).frame(maxWidth: .infinity) }
        }
        .environmentObject(StudIPSync(defaults: d))
        .environmentObject(Session(local: .local(), defaults: d))
        .environmentObject(UFToastCenter())
        .environmentObject(UFRouter())
        .environmentObject(UFOverlay())
        let frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            window.overrideUserInterfaceStyle = style
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format).pngData { _ in
                _ = hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            try png.write(to: dir.appendingPathComponent("\(name)-\(tone).png"))
        }
    }
}

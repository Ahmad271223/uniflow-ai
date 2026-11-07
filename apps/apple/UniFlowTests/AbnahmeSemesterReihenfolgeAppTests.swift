import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Abnahme "7 Semester: zuerst das Neueste, dann fragen" im **Release-Stand** (nur LUH, `UFReleaseUniversities.storeDefault`),
/// Wunsch des Inhabers 07.11.2026: Wer im 7. Semester ist, bekommt beim ersten Abgleich nur das aktuelle Semester
/// (Kurse, Stundenplan, Dateien) mit Fortschritt; Uebersicht und Stundenplan sind da, bevor irgendetwas Altes geladen
/// wird. Danach die Frage "Auch frühere Semester laden?": Ja laedt die sechs frueheren Semester neuestes zuerst im
/// Hintergrund mit Stand "(n von 6)", Nein laedt nichts und fragt nicht erneut; die Einstellungen zeigen die Wahl.
/// Echte Wurzel der App (`RootView`) mit der Stud.IP-Anmeldeseite aus `DebugStub/erststart`; den Abgleich beantwortet
/// ein Stud.IP-Nachbau mit erfundenen Kursen (sieben Semester und das naechste), nie ein echter Abruf.
/// Mit UF_ABNAHME_DIR (xcodebuild: TEST_RUNNER_UF_ABNAHME_DIR) schreibt der Test Bilder `<nn>-<station>.png`.
@MainActor
final class AbnahmeSemesterReihenfolgeAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!
    private static let size = CGSize(width: 1024, height: 768)

    /// c1 (1. Semester) bis c7 (aktuell), c8 das naechste
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

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer?
    private var background: BackgroundSyncController!
    private var outDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        UFReleaseUniversities.shipped = UFReleaseUniversities.storeDefault              // Store-Build: nur die LUH
        bed = try ContainerTestBed(name: "abnahme-semester", clock: Self.clock)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(),
                               observeRevocation: false)
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        UFFmt.todayOverride = Self.clock.today
        UFGreeting.hourOverride = 12
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_ABNAHME_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.removeObject(forKey: "UFLoginStub")
        UFFmt.todayOverride = nil
        UFGreeting.hourOverride = nil
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager.onChange = nil
        manager.deactivate()
        await bed.tearDown()
        UFReleaseUniversities.reset()
        try await super.tearDown()
    }

    // MARK: - Stud.IP-Nachbau mit sieben Semestern

    /// Stud.IP mit festen Antworten (example-Daten, erfunden); merkt sich die Abrufe in Reihenfolge
    private final class SevenTermStudIP: StudIPTransport, @unchecked Sendable {
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

        func folders(of course: Int) -> Bool { requested.contains("/jsonapi.php/v1/courses/c\(course)/folders?page[limit]=200") }
        /// Kurse, deren Ordner abgefragt wurden, in Reihenfolge
        var folderOrder: [Int] {
            requested.compactMap { p -> Int? in
                guard p.hasPrefix("/jsonapi.php/v1/courses/c"), p.hasSuffix("/folders?page[limit]=200") else { return nil }
                return Int(p.dropFirst("/jsonapi.php/v1/courses/c".count).prefix { $0.isNumber })
            }
        }
    }

    private static func pdf(_ marker: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { ctx in
            ctx.beginPage()
            (marker as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }

    private func portal() -> SevenTermStudIP {
        let t = SevenTermStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        let courses = Self.terms.map { s in
            #"{"id":"c\#(s.id)","type":"courses","attributes":{"title":"\#(s.course)"},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s\#(s.id)"}},"end-semester":{"data":{"type":"semesters","id":"s\#(s.id)"}}}}"#
        }.joined(separator: ",")
        let sems = Self.terms.map { s in
            #"{"id":"s\#(s.id)","type":"semesters","attributes":{"title":"\#(s.title)","start":"\#(s.start)T00:00:00+02:00","end":"\#(s.end)T23:59:59+02:00"}}"#
        }.joined(separator: ",")
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"{"data":[\#(courses)],"included":[\#(sems)]}"#)
        // Stundenplan des aktuellen Semesters: Datenstrukturen montags 10:00, dienstags 14:00 (erfundene Raeume)
        t.json("/jsonapi.php/v1/users/u1/schedule", #"""
            {"data":[
             {"id":"cy-c7a","type":"seminar-cycle-dates","attributes":{"title":"Kurszeit","description":"","start":"10:00","end":"11:30","weekday":1,"color":null,
               "recurrence":{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12T10:00:00+02:00","UNTIL":"2027-01-25T11:30:00+01:00"},"locations":["Hörsaal A 101"]},
              "relationships":{"owner":{"data":{"type":"courses","id":"c7"}}}},
             {"id":"cy-c7b","type":"seminar-cycle-dates","attributes":{"title":"Kurszeit","description":"","start":"14:00","end":"15:30","weekday":2,"color":null,
               "recurrence":{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-13T14:00:00+02:00","UNTIL":"2027-01-26T15:30:00+01:00"},"locations":["Raum B 202"]},
              "relationships":{"owner":{"data":{"type":"courses","id":"c7"}}}}],"links":{}}
            """#)
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

    private func client(_ t: SevenTermStudIP, pause: UInt64 = 0) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: pause, retry: UniRetry(attempts: 2, delayNanos: { _ in 0 }))
    }

    // MARK: - Aufbau (wie AbnahmeV1LUHReleaseAppTests)

    private struct Root: View {
        @ObservedObject var manager: ContainerManager
        @ObservedObject var account: AccountStore
        let background: BackgroundSyncController

        var body: some View {
            RootView()
                .environment(\.qis, manager.qis)
                .environment(\.uniMail, manager.uniMail)
                .environment(\.ufChatGPTLink, manager.chatgpt)
                .environment(\.ufStudoraAccount, manager.account)
                .modifier(UFAIAccessProvider(chatgpt: manager.chatgpt, account: manager.account))
                .environment(\.backgroundSync, background)
                .environment(\.ufDemoActive, manager.demoActive)
                .environmentObject(manager.studip)
                .environmentObject(manager)
                .environmentObject(account)
        }
    }

    private func host() throws -> HostedEnvironment {
        let env = try hostWithEnvironment(Root(manager: manager, account: account, background: background),
                                          api: container?.api ?? .local(.unavailable), size: Self.size, studip: manager.studip)
        manager.onChange = { [weak session = env.session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        env.pump(0.5)
        return env
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        var all = LayoutWidthAuditTests.elements(in: env.window)
        if let v = env.hosting.presentedViewController?.view, v.window == nil { all += LayoutWidthAuditTests.elements(in: v) }
        return all.flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        if !ok { XCTFail("„\(text)“ fehlt:\n" + texts(env).joined(separator: "\n"), file: file, line: line) }
        return ok
    }

    @discardableResult
    private func tap(_ label: String, in env: HostedEnvironment) -> Bool {
        for e in LayoutWidthAuditTests.elements(in: env.window) where e.accessibilityTraits.contains(.button) && e.accessibilityLabel == label {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func pumping<T>(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw XCTSkip("Zeitueberschreitung") }
        return try result.get()
    }

    private func webView(_ env: HostedEnvironment) -> WKWebView? {
        func find(_ v: UIView) -> WKWebView? {
            if let w = v as? WKWebView { return w }
            for s in v.subviews { if let w = find(s) { return w } }
            return nil
        }
        return find(env.window)
    }

    /// Bild des Fensters (mit Dialogen), Massstab 2
    private func shoot(_ env: HostedEnvironment, _ name: String) {
        guard let outDir else { return }
        env.pump(0.4)
        let window = env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let file = outDir.appendingPathComponent(name + ".png")
        do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
    }

    /// Stud.IP angemeldet (Nachbildung der Anmeldeseite), dann der erste Abgleich mit dem Nachbau; QIS "Später anmelden"
    private func firstSync(_ env: HostedEnvironment, _ stud: SevenTermStudIP, photos: Bool) throws {
        expect(env, "Schritt 1 von 2: " + FirstLoginStep.studip.title)
        let stub = ContainerTestBed.stubDirectory
        let web = try XCTUnwrap(env.wait(timeout: 20) { self.webView(env)?.url?.lastPathComponent == "studip.html" } ? webView(env) : nil)
        web.loadFileURL(stub.appendingPathComponent("studip-angemeldet.html"), allowingReadAccessTo: stub)
        XCTAssertTrue(env.wait(timeout: 20) { self.manager.studip.hasStoredSession }, "Stud.IP-Sitzung gespeichert")
        // wie `StudIPSync.signedIn` (unter XCTest laeuft der Abgleich nicht von selbst), langsam genug fuer den Fortschritt
        var finished = false
        let c = client(stud, pause: photos ? 250 : 0)
        Task { @MainActor in _ = await self.manager.studip.run(client: c); finished = true }
        expect(env, "Schritt 2 von 2: " + FirstLoginStep.qis.title)
        XCTAssertTrue(tap("Später anmelden", in: env), "Später anmelden")
        expect(env, "Kurse und Dateien aus Stud.IP")
        if photos && !finished { shoot(env, "01-erstabgleich-fortschritt") }
        XCTAssertTrue(env.wait(timeout: 60) { finished }, "Abgleich fertig")
        XCTAssertEqual(manager.studip.phase, .idle, manager.studip.lastSummary ?? "")
        expect(env, FirstSyncProgress.title(finished: true, anyLoaded: true))
        if photos { shoot(env, "02-erstabgleich-fertig") }
        // nur das aktuelle (und naechste) Semester: kein frueheres abgefragt, Stundenplan vor den Dateilisten
        XCTAssertEqual(Set(stud.folderOrder), [7, 8], "erster Abgleich: nur aktuelles und naechstes Semester: \(stud.folderOrder)")
        let schedule = try XCTUnwrap(stud.requested.firstIndex { $0.hasPrefix("/jsonapi.php/v1/users/u1/schedule") })
        let lists7 = try XCTUnwrap(stud.requested.firstIndex { $0.contains("/courses/c7/folders") })
        XCTAssertLessThan(schedule, lists7, "Stundenplan vor den Dateien")
        XCTAssertTrue(tap("Zur Übersicht", in: env), "Zur Übersicht")
        XCTAssertTrue(env.wait { self.account.stage == .ready }, "Oberflaeche")
    }

    private func open() throws {
        UserDefaults.standard.set(ContainerTestBed.stubDirectory.path, forKey: "UFLoginStub")
        XCTAssertTrue(DebugUniStub.isActive)
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        account.markPlanShown()
        account.chooseUniversity(.luh)
        container = try bed.open(manager, account)
        let qis = try XCTUnwrap(manager.qis)
        qis.syncsAfterSignIn = false
    }

    /// Frage wie `OlderSemestersQuestionHost` (der unter XCTest nicht von selbst fragt): nur, solange nie beantwortet
    private func presentQuestion(_ env: HostedEnvironment, api: APIClient) throws {
        let overview = try pumping { try await api.value("/api/older-semesters") }
        XCTAssertTrue(OlderSemestersQuestionHost.shouldAsk(overview), "Frage steht an")
        let courses = (overview["semesters"]?.array ?? []).reduce(0) { $0 + ($1["courses"]?.array?.count ?? 0) }
        XCTAssertEqual(courses, 6)
        env.overlay.modal { OlderSemestersQuestion(current: overview.s("current") ?? "", courses: courses) }
        expect(env, "Auch frühere Semester laden?")
    }

    private func olderRuns(_ api: APIClient) throws -> JSONValue { try pumping { try await api.value("/api/older-semesters") } }

    // MARK: - Ja

    func test01ErstAktuellesSemesterDannFrageJaLaedtNeuestesZuerst() throws {
        try open()
        let env = try host()
        let stud = portal()
        try firstSync(env, stud, photos: true)
        let api = container!.api
        let db = try pumping { try await self.container!.host.backend().context.database }

        // Uebersicht und Stundenplan stehen, nichts Altes geladen
        expect(env, "Hallo Ada")
        shoot(env, "03-uebersicht")
        env.router.go(.timetable())
        expect(env, "Datenstrukturen")
        shoot(env, "04-stundenplan")
        let status = try pumping { try await api.value("/api/sync-order") }
        XCTAssertEqual(status["current"]?["label"]?.string, "WiSe 2026/27")
        XCTAssertEqual(status["older"]?["pending"]?.int, 0, "vor der Antwort steht nichts Altes an")

        // Stufe (d) vor der Antwort (WLAN, kein Stromsparmodus): laedt nichts
        stud.clear()
        let load: (Set<String>) async -> Void = { ids in _ = await self.manager.studip.run(client: self.client(stud), olderOnly: true, olderCourses: ids) }
        let before = try pumping { await OlderSemesterLoader.runStage(db: db, today: Self.clock.today, perTerm: true, pause: { _ in nil }, load: load, wait: {}) }
        XCTAssertEqual(before, 0)
        XCTAssertTrue(stud.folderOrder.isEmpty, "vor der Antwort kein frueheres Semester: \(stud.requested)")

        // Frage, "Frühere Semester auch laden"
        env.router.go(.dashboard)
        try presentQuestion(env, api: api)
        shoot(env, "05-frage-fruehere-semester")
        XCTAssertTrue(tap(OlderSemestersQuestion.yes, in: env), "Ja")
        XCTAssertTrue(env.wait { (try? self.olderRuns(api))?.s("mode") == "wifi" }, "Antwort gespeichert: Nur WLAN")
        XCTAssertFalse(OlderSemestersQuestionHost.shouldAsk(try olderRuns(api)), "keine erneute Frage")

        // drei Semester, neuestes zuerst: Stand "(3 von 6)" auf der Seite Module
        stud.clear()
        var n = 0
        _ = try pumping {
            await OlderSemesterLoader.runStage(db: db, today: Self.clock.today, perTerm: true, pause: { _ in
                n += 1
                return n > 3 ? .closed : nil
            }, load: load, wait: {})
        }
        XCTAssertEqual(stud.folderOrder, [6, 5, 4], "neuestes Semester zuerst")
        XCTAssertFalse(stud.requested.contains { $0.contains("/schedule") }, "Stufe (d): kein Stundenplan")
        _ = try pumping { try await db.transaction { try SyncOrder.setOlder($0, running: true) } }   // laeuft weiter
        env.router.go(.modules)
        expect(env, "(3 von 6)")
        shoot(env, "06-module-stand-3-von-6")

        // der Rest, fortgesetzt
        stud.clear()
        let more = try pumping { await OlderSemesterLoader.runStage(db: db, today: Self.clock.today, perTerm: true, pause: { _ in nil }, load: load, wait: {}) }
        XCTAssertEqual(more, 3)
        XCTAssertEqual(stud.folderOrder, [3, 2, 1])
        let sem = try pumping { try await api.value("/api/module-semesters") }
        XCTAssertNil(ModuleSemesters.hint(sem), "alles geladen")
        // alte Kurse nicht eingeplant (aus), ihre Unterlagen in der Bibliothek
        let active = try pumping { try await api.value("/api/courses").items.filter { $0.i("active") == 1 }.compactMap { $0.s("id") } }
        XCTAssertEqual(Set(active).subtracting(["__user__"]), ["c7", "c8"])
        let old = try pumping { try await api.value("/api/older-semesters/courses/c1/files").items }
        XCTAssertEqual(old.first?.i("downloaded"), 1, "Blatt des 1. Semesters geladen")
        env.router.go(.files())
        expect(env, "Frühere Semester")
        shoot(env, "07-bibliothek-fruehere-semester")

        env.router.go(.settings(tab: "modules"))
        expect(env, "Ältere Semester laden")
        expect(env, "Nur WLAN")
        shoot(env, "08-einstellungen-nur-wlan")
    }

    // MARK: - Nein

    func test02FrageNeinLaedtNichtsUndFragtNichtErneut() throws {
        try open()
        let env = try host()
        let stud = portal()
        try firstSync(env, stud, photos: false)
        let api = container!.api
        let db = try pumping { try await self.container!.host.backend().context.database }
        try presentQuestion(env, api: api)
        XCTAssertTrue(tap(OlderSemestersQuestion.no, in: env), "Nein")
        XCTAssertTrue(env.wait { (try? self.olderRuns(api))?.s("mode") == "off" }, "Antwort gespeichert: Aus")

        // weiterer voller Abgleich und Stufe (d): nichts Altes, keine Frage
        stud.clear()
        _ = try pumping { await self.manager.studip.run(client: self.client(stud)) }
        let runs = try pumping {
            await OlderSemesterLoader.runStage(db: db, today: Self.clock.today, perTerm: true, pause: { _ in nil }, load: { ids in
                _ = await self.manager.studip.run(client: self.client(stud), olderOnly: true, olderCourses: ids)
            }, wait: {})
        }
        XCTAssertEqual(runs, 0)
        for old in 1...6 { XCTAssertFalse(stud.folders(of: old), "c\(old): Nein heisst nichts Altes") }
        XCTAssertFalse(OlderSemestersQuestionHost.shouldAsk(try olderRuns(api)), "keine erneute Frage")

        env.router.go(.settings(tab: "modules"))
        expect(env, "Ältere Semester laden")
        shoot(env, "09-einstellungen-aus")
    }
}

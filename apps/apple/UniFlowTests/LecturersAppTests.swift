import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Lehrende und Kontakte auf dem iPad (LUH, Stud.IP, 06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md): Abruf gegen die
/// Debug-Nachbildung (apps/apple/DebugStub/erststart, erfundene Personen, example.org), Bereich "Lehrende" auf der
/// Modulseite, Seite "Lehrende" mit Suche, E-Mail ueber Uni-Mail bzw. mailto:, "Nachricht in Stud.IP" mit festem
/// Empfaenger, HsH ohne Bereich. Nie Netz.
@MainActor
final class LecturersAppTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct AuthorizedChecker: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-06T10:00:00")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-lehrende-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private static let courses = [StudIPCourse(id: "c-ma", title: "Mathematik für Ingenieure I"),
                                  StudIPCourse(id: "c-ma-ue", title: "Übung zu Mathematik für Ingenieure I"),
                                  StudIPCourse(id: "c-prog", title: "Programmieren I")]

    /// Geraet mit zwei Modulen und den Kursen der Nachbildung; `sync`: Lehrende aus der Nachbildung laden
    private func device(university: UniversityKey = .luh, sync: Bool = true) throws -> (LocalBackendHost, APIClient) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock, university: university)
        try awaiting {
            let b = try await host.backend()
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Mathematik für Ingenieure I', '#4f5bd5'), (2, 'Programmieren I', '#0e9f9a')")
                for (id, title, module) in [("c-ma", "Mathematik für Ingenieure I", 1), ("c-ma-ue", "Übung zu Mathematik für Ingenieure I", 1),
                                            ("c-prog", "Programmieren I", 2)] {
                    try c.execute("INSERT INTO courses(id, title, kind, active, module_id, created_at) VALUES (?, ?, 'vorlesung', 1, ?, 't')",
                                  [.text(id), .text(title), .integer(Int64(module))])
                }
            }
            if sync {
                let client = StudIPClient(base: StudIPSync.base, transport: DebugStubTransport(directory: ContainerTestBed.stubDirectory), pauseMillis: 0)
                let expired = await StudIPExtrasSync(host: host).lecturers(client: client, courses: Self.courses)
                XCTAssertFalse(expired)
            }
        }
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    // MARK: Bedienungshilfen

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-lehrende-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(UFToastCenter())
            .environmentObject(StudIPSync())
            .environmentObject(AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: AuthorizedChecker(), observeRevocation: false))
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        return window
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func elements(in window: UIWindow) -> [NSObject] {
        var roots: [UIView] = [window]
        var vc = window.rootViewController?.presentedViewController
        while let v = vc { if let view = v.view { roots.append(view) }; vc = v.presentedViewController }
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 45 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        for r in roots { r.layoutIfNeeded(); visit(r, depth: 0) }
        return out
    }

    private func texts(_ w: UIWindow) -> [String] {
        elements(in: w).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ w: UIWindow, _ text: String) -> Bool { texts(w).contains { $0.contains(text) } }

    private func tap(_ label: String, in w: UIWindow, exact: Bool = true) -> Bool {
        for e in elements(in: w) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: Tests

    /// Abruf gegen die Nachbildung: Lehrende je Modul mit E-Mail, Tutor ohne Adresse, Sprechstunde mit Raum
    func testDebugStubLoadsLecturersPerModule() throws {
        let (_, api) = try device()
        let m1 = try awaiting { try await api.value("/api/lecturers?module_id=1") }
        XCTAssertEqual(m1["available"]?.bool, true)
        let people = m1.list("people")
        XCTAssertEqual(people.map { $0.s("name") ?? "" }, ["Dr. Beispiel Dozentin", "Erfundener Tutor"], "Dozent/innen vor Tutor/innen")
        XCTAssertEqual(people.first?.s("email"), "beispiel.dozentin@example.org")
        XCTAssertEqual(people.first?.s("office_hours"), "Mi 14–15 Uhr")
        XCTAssertEqual(people.first?.s("location"), "1101 - F102")
        XCTAssertEqual(people.first?.s("institute"), "Institut für Beispielmathematik")
        XCTAssertEqual(people.first?.list("courses").count, 2, "eine Person, zwei Kurse des Moduls")
        XCTAssertEqual(people.last?.s("no_email"), "Nachricht über Stud.IP")
        XCTAssertEqual(people.last?.s("role_label"), "Tutor/in")
        let all = try awaiting { try await api.value("/api/lecturers?q=programm") }
        XCTAssertEqual(all.list("people").map { $0.s("email") ?? "" }, ["programmieren@example.org"], "Suche nach dem Modul")
        for p in try awaiting({ try await api.value("/api/lecturers") }).list("people") {
            let e = p.s("email") ?? ""
            XCTAssertTrue(e.isEmpty || e.hasSuffix("@example.org"), "nur erfundene Adressen: \(e)")
        }
    }

    func testRouteAndRules() throws {
        XCTAssertEqual(UFRoute.lecturers.hash, "#/lehrende")
        XCTAssertEqual(UFRoute(hash: "#/lehrende"), .lecturers)
        XCTAssertEqual(UFRoute(hash: "#/lecturers"), .lecturers)
        XCTAssertTrue(UFRouter.showsBackArrow(on: .lecturers))
        XCTAssertFalse(UFNavItem.visible(local: true, gradesOnDevice: true, community: true).contains { $0.route == .lecturers },
                       "kein eigener Menuepunkt")
        XCTAssertEqual(LecturerMailAction.choose(email: "a@example.org", uniMailConnected: true), .uniMail("a@example.org"))
        XCTAssertEqual(LecturerMailAction.choose(email: "a@example.org", uniMailConnected: false), .mailto(URL(string: "mailto:a@example.org")!))
        XCTAssertNil(LecturerMailAction.choose(email: " ", uniMailConnected: true))
        let p: JSONValue = ["id": "u1", "name": "Dr. Test", "username": "dtest", "role_label": "Dozent/in", "label": "Modulverantwortliche",
                            "email": "", "office_hours": "Di 10–11 Uhr\nund nach Vereinbarung", "location": "F102",
                            "courses": [["title": "Analysis I – Vorlesung", "module_name": "Analysis I"], ["title": "Extra", "module_name": .null]]]
        XCTAssertEqual(LecturersText.detail(p, showCourses: true), "Dozent/in · Modulverantwortliche · Analysis I, Extra")
        XCTAssertEqual(LecturersText.detail(p, showCourses: false), "Dozent/in · Modulverantwortliche")
        XCTAssertEqual(LecturersText.officeLines(p.s("office_hours")), ["Di 10–11 Uhr", "und nach Vereinbarung"])
        XCTAssertEqual(LecturersText.accessibility(p),
                       "Dr. Test, Dozent/in, Nachricht über Stud.IP, Sprechstunde Di 10–11 Uhr, und nach Vereinbarung, Raum F102")
        XCTAssertEqual(LecturersText.subject(p), "Frage zu Analysis I")
        let req = LecturerMessageRequest(person: p)
        XCTAssertEqual(req.original.localID, "lect-u1")
        XCTAssertEqual(req.original.directTo, StudIPPerson(id: "u1", name: "Dr. Test"))
        XCTAssertEqual(MessageReplySheet.title(direct: req.original.directTo, all: false), "Nachricht an Dr. Test")
        XCTAssertEqual(LecturersPage.countLine(["count": 3, "total": 3]), "3 Personen")
        XCTAssertEqual(LecturersPage.countLine(["count": 1, "total": 3]), "1 von 3 Personen")
    }

    /// "Nachricht in Stud.IP": fester Empfaenger, Betreff Pflicht, genau ein POST an die Nachbildung, Ausweg mit rec_uname
    func testDirectMessageSendsToTheLecturerOnly() throws {
        let suite = "uniflow-lehrende-msg-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let stub = DebugStubTransport(directory: ContainerTestBed.stubDirectory)
        let deps = MessageReplyModel.Dependencies(connected: { true }, ensureSession: { _ in .ready },
                                                  client: { StudIPClient(base: StudIPSync.base, transport: stub, pauseMillis: 0) },
                                                  defaults: defaults)
        let original = MessageReplyOriginal.direct(to: StudIPPerson(id: "u-stub-doz", name: "Dr. Beispiel Dozentin"), username: "bdozentin",
                                                   subject: "")
        let model = MessageReplyModel(original: original, mode: .sender, dependencies: deps)
        try awaiting { await model.start() }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.recipients.map(\.id), ["u-stub-doz"])
        XCTAssertNil(model.quoteText, "kein Zitat bei einer neuen Nachricht")
        model.text = "Guten Tag, ich habe eine Frage zu Blatt 3."
        XCTAssertFalse(model.canSend, "ohne Betreff nicht senden")
        model.subject = "Frage zu Mathematik für Ingenieure I"
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.replyWebURL.absoluteString, "https://studip.uni-hannover.de/dispatch.php/messages/write?rec_uname=bdozentin")
        try awaiting { await model.send() }
        guard case .sent(let record) = model.phase else { return XCTFail("nicht gesendet: \(model.phase)") }
        XCTAssertEqual(record.sentID, "stub-gesendet")
        XCTAssertEqual(record.recipients, 1)
        XCTAssertNil(StudIPReplyDrafts.load(defaults).draft(for: "lect-u-stub-doz"), "Entwurf nach dem Senden weg")
    }

    /// Modulseite: Bereich "Lehrende" mit E-Mail, Sprechstunde als Raum-Link, "Nachricht in Stud.IP" oeffnet das Fenster
    func testModuleCardShowsContactsAndOpensStudIPMessage() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (_, api) = try device()
        let w = try show(ScrollView { ModuleLecturersCard(moduleID: 1, moduleName: "Mathematik für Ingenieure I").padding(20) }, api: api)
        XCTAssertTrue(pump { self.shows(w, "E-Mail an beispiel.dozentin@example.org") }, texts(w).joined(separator: "\n"))
        for t in ["Lehrende", "Alle Lehrenden", "Dr. Beispiel Dozentin", "Erfundener Tutor", "Nachricht über Stud.IP",
                  "Raum 1101 - F102", "Institut für Beispielmathematik", "Die Angaben bleiben auf diesem iPad."] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(texts(w).joined(separator: "\n"))")
        }
        XCTAssertTrue(tap("Nachricht in Stud.IP", in: w))
        // ohne gespeicherte Stud.IP-Sitzung: das Fenster sagt es (der Empfaenger stuende fest)
        XCTAssertTrue(pump { self.shows(w, "Stud.IP ist nicht verbunden") }, texts(w).joined(separator: "\n"))
    }

    /// Seite "Lehrende": alle Lehrenden der aktiven Kurse mit Modul, Zahl, Suche ueber den Kern
    func testPageListsAllLecturers() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (_, api) = try device()
        let w = try show(LecturersPage(), api: api)
        XCTAssertTrue(pump { self.shows(w, "3 Personen") }, texts(w).joined(separator: "\n"))
        for t in ["Prof. Erfunden Programmierer", "programmieren@example.org", "Mathematik für Ingenieure I", "Programmieren I"] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(texts(w).joined(separator: "\n"))")
        }
    }

    /// Hochschule Hannover: kein Bereich auf der Modulseite (kein Platzhalter), die Seite sagt es ruhig; keine Anfrage
    func testHsHHidesTheSection() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (host, api) = try device(university: .hsh, sync: false)
        let t = DebugStubTransport(directory: ContainerTestBed.stubDirectory)
        let expired = try awaiting {
            await StudIPExtrasSync(host: host).lecturers(client: StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0), courses: Self.courses)
        }
        XCTAssertFalse(expired)
        let v = try awaiting { try await api.value("/api/lecturers?module_id=1") }
        XCTAssertEqual(v["available"]?.bool, false)
        let w = try show(ScrollView { VStack { Text("Modul"); ModuleLecturersCard(moduleID: 1) }.padding(20) }, api: api)
        pump(timeout: 1.5)
        XCTAssertTrue(shows(w, "Modul"))
        XCTAssertFalse(shows(w, "Alle Lehrenden"), texts(w).joined(separator: "\n"))
        w.isHidden = true
        let p = try show(LecturersPage(), api: api)
        XCTAssertTrue(pump { self.shows(p, "vorerst für die Leibniz Universität Hannover") }, texts(p).joined(separator: "\n"))
    }
}

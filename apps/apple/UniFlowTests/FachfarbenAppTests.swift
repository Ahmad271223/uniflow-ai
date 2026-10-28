import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Fachfarben und Kurznamen im lokalen Modus ohne PC: Jedes Fach hat eine eigene Farbe aus der Palette, Vorlesung und
/// Uebung eines Fachs dieselbe; enge Bloecke im Lernkalender bekommen eindeutige Kurznamen ("SigSys", "Ü SigSys",
/// "EGI" statt zweimal "ET"); die Farbwahl im Modul-Dialog schickt die Farbe nur bei einer Aenderung. Erfundene
/// Kurse und Termine (allgemeine Fachtitel), Uhr eingefroren auf Montag, 26.10.2026, 07:30 Europe/Berlin.
/// Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) legt der Test Bildschirmfotos dort ab.
@MainActor
final class FachfarbenAppTests: XCTestCase {

    final class RecordingTransport: APITransport, @unchecked Sendable {
        let inner: LocalTransport
        private let lock = NSLock()
        private var log: [(method: String, path: String, status: Int, body: JSONValue?)] = []

        init(_ inner: LocalTransport) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let r = try await inner.send(request)
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            lock.withLock { log.append((request.httpMethod ?? "GET", request.url?.path ?? "", r.1.statusCode, body)) }
            return r
        }

        var calls: [(method: String, path: String, status: Int, body: JSONValue?)] { lock.withLock { log } }
    }

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct AuthorizedChecker: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-farben-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Kurse wie aus Stud.IP (Vorlesung und Uebung je Fach), Module ueber GET /api/modules, Termine am Montag
    /// 26.10. teils gleichzeitig (enge Bloecke nebeneinander)
    private func seededAPI() async throws -> (APIClient, RecordingTransport) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-26T07:30:00")!)
        let backend = try await host.backend()
        let courses: [(String, String)] = [
            ("k-sig", "Signale und Systeme (für Elektrotechnik)"), ("k-sig-ue", "Übung: Signale und Systeme (für Elektrotechnik)"),
            ("k-egi", "Elektrotechnische Grundlagen der Informatik"), ("k-sp", "Einführung in die Sozialpädagogik"),
            ("k-so", "Einführung in die Soziologie"), ("k-ma", "Testmathematik I"), ("k-ma-ue", "Übung zu Testmathematik I"),
        ]
        try await backend.context.database.transaction { c in
            for (id, title) in courses {
                let (subject, kind) = UniRules.classify(title)
                try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(subject), .text(kind), .text("2026-10-01T08:00:00")])
            }
        }
        let recorder = RecordingTransport(LocalTransport(host: host))
        let api = APIClient(base: APIClient.localBase, transport: recorder)
        _ = try await api.value("/api/modules")                                  // ensure_modules: je Fach ein Modul
        let events: [(String, String, String, String, String)] = [
            ("k-sig", "Signale und Systeme (für Elektrotechnik)", "vorlesung", "10:00", "11:30"),
            ("k-sig-ue", "Übung: Signale und Systeme (für Elektrotechnik)", "uebung", "10:00", "11:30"),
            ("k-egi", "Elektrotechnische Grundlagen der Informatik", "vorlesung", "10:30", "12:00"),
            ("k-sp", "Einführung in die Sozialpädagogik", "vorlesung", "14:00", "15:30"),
            ("k-so", "Einführung in die Soziologie", "vorlesung", "14:00", "15:30"),
            ("k-ma", "Testmathematik I", "vorlesung", "08:15", "09:45"),
            ("k-ma-ue", "Übung zu Testmathematik I", "uebung", "16:00", "17:30"),
        ]
        try await backend.context.database.transaction { c in
            for e in events {
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                    VALUES ((SELECT module_id FROM courses WHERE id=?), ?, ?, ?, 0, ?, ?, 'weekly', 1, 'studip', '2026-10-01T08:00:00')
                    """, [.text(e.0), .text(e.0), .text(e.1), .text(e.2), .text(e.3), .text(e.4)])
            }
        }
        return (api, recorder)
    }

    // MARK: Fenster, Bedienungshilfen (wie StudyPlanLocalAppTests)

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

    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient, style: UIUserInterfaceStyle = .light, overlay given: UFOverlay? = nil) throws -> UIView {
        let overlay = given ?? UFOverlay()
        let suite = "uniflow-farben-\(UUID().uuidString)"
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
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1300)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.overrideUserInterfaceStyle = style
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
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
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityLabel == label && e.accessibilityTraits.contains(.button) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Bildschirmfoto nach UF_SCREENSHOT_DIR (wenn gesetzt); scheitert nie
    private func screenshot(_ view: UIView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    // MARK: Tests

    /// Jedes Fach eine eigene Farbe der Reihe nach aus der Palette; Vorlesung und Uebung eines Fachs, der Termin im
    /// Lernkalender und das Modul zeigen dieselbe Farbe
    func testEverySubjectHasItsOwnColorEverywhere() throws {
        let (api, _) = try awaiting { try await self.seededAPI() }
        let mods = try awaiting { try await api.value("/api/modules") }.items
        XCTAssertEqual(mods.map { $0.s("name") ?? "" }, ["Signale und Systeme", "Elektrotechnische Grundlagen der Informatik",
                                                         "Einführung in die Sozialpädagogik", "Einführung in die Soziologie", "Testmathematik I"])
        XCTAssertEqual(mods.compactMap { $0.s("color") }, Array(ModuleColors.palette.prefix(5)), "der Reihe nach, keine doppelt")
        let colorOf = Dictionary(uniqueKeysWithValues: mods.map { ($0.i("id") ?? 0, $0.s("color") ?? "") })
        let cal = try awaiting { try await api.value("/api/calendar?start=2026-10-26&end=2026-10-26") }
        let events = cal.list("days").first?.list("events") ?? []
        XCTAssertEqual(events.count, 7)
        for e in events { XCTAssertEqual(e.s("color"), colorOf[e.i("module_id") ?? -1], e.s("title") ?? "") }
        let sig = events.filter { ($0.s("title") ?? "").contains("Signale") }.compactMap { $0.s("color") }
        XCTAssertEqual(Set(sig).count, 1, "Vorlesung und Übung eines Fachs in einer Farbe")
        let tt = try awaiting { try await api.value("/api/timetable/week?start=2026-10-26") }
        let ttColors = Set((tt.list("days").first?.list("events") ?? []).compactMap { $0.s("color") })
        XCTAssertEqual(ttColors, Set(mods.compactMap { $0.s("color") }), "Stundenplan zeigt dieselben Fachfarben")
    }

    /// Enge Bloecke im Lernkalender (Woche, iPad-Breite): eindeutige Kurznamen je Fach, kein doppeltes "ET". Seit e9a40d1
    /// wie die Web-App: Initialen erst ab drei Bloecken nebeneinander (SigSys, Ü SigSys, EGI um 10 Uhr), sonst der
    /// lesbare Kurzname (die beiden Einfuehrungen um 14 Uhr, die Uebung allein)
    func testNarrowBlocksShowUniqueShortNames() throws {
        let (api, recorder) = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let plan = try show(PlanView(params: (view: "week", date: "2026-10-26", module: nil)), api: api, style: style)
            XCTAssertTrue(pump { recorder.calls.contains { $0.path == "/api/calendar" } && self.shows(plan, "EGI") }, texts(plan).joined(separator: "\n"))
            let all = texts(plan)
            for name in ["SigSys", "Ü SigSys", "EGI", "Einführung in die Sozialpädagogik", "Einführung in die Soziologie", "Übung zu Testmathematik I"] {
                XCTAssertTrue(all.contains { $0.contains(name) }, "\(name) fehlt: \(all)")
            }
            XCTAssertFalse(all.contains { $0.range(of: #"(^|[^A-Za-z])ET([^A-Za-z]|$)"#, options: .regularExpression) != nil }, "kein ET: \(all)")
            screenshot(plan, style == .dark ? "lernkalender-woche-dunkel" : "lernkalender-woche-hell")
        }
    }

    /// Farbwahl im Modul-Dialog: Palette, die gewaehlte Farbe wird gespeichert und als eigene markiert; Speichern
    /// ohne Farbwechsel schickt keine Farbe (der Merker bleibt verlaesslich)
    func testColorChoiceInModuleDialog() throws {
        let (api, recorder) = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let module = try XCTUnwrap(try awaiting { try await api.value("/api/modules") }.items.first)
        let id = try XCTUnwrap(module.i("id"))

        let unchanged = try show(ModuleEditDialog(m: module), api: api)
        XCTAssertTrue(pump { self.shows(unchanged, "Modul bearbeiten") && self.shows(unchanged, "Farbe \(ModuleColors.palette[3])") },
                      texts(unchanged).joined(separator: "\n"))
        screenshot(unchanged, "modul-farbwahl")
        XCTAssertTrue(tap("Speichern", in: unchanged), texts(unchanged).joined(separator: "\n"))
        XCTAssertTrue(pump { recorder.calls.contains { $0.method == "PATCH" && $0.path == "/api/modules/\(id)" } })
        let first = try XCTUnwrap(recorder.calls.last { $0.method == "PATCH" })
        XCTAssertNil(first.body?["color"], "ohne Farbwechsel keine Farbe: \(String(describing: first.body))")
        XCTAssertEqual(try awaiting { try await api.value("/api/modules/\(id)") }["module"]?.i("color_custom"), 0)

        let dialog = try show(ModuleEditDialog(m: module), api: api)
        XCTAssertTrue(pump { self.shows(dialog, "Farbe \(ModuleColors.palette[3])") })
        XCTAssertTrue(tap("Farbe \(ModuleColors.palette[3])", in: dialog), texts(dialog).joined(separator: "\n"))
        pump(timeout: 0.3)
        let before = recorder.calls.count
        XCTAssertTrue(tap("Speichern", in: dialog))
        XCTAssertTrue(pump { recorder.calls.dropFirst(before).contains { $0.method == "PATCH" && $0.path == "/api/modules/\(id)" } })
        let second = try XCTUnwrap(recorder.calls.last { $0.method == "PATCH" })
        XCTAssertEqual(second.body?["color"], .string(ModuleColors.palette[3]))
        XCTAssertEqual(second.status, 200)
        let saved = try awaiting { try await api.value("/api/modules/\(id)") }["module"]
        XCTAssertEqual(saved?.s("color"), ModuleColors.palette[3])
        XCTAssertEqual(saved?.i("color_custom"), 1)
    }
}

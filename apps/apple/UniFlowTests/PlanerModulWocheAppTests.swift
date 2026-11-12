import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Auftrag 12.11.2026: "Zeig bitte immer die richtigen Module an, wenn man auf ein Fach klickt im Planer; es sollen
/// nicht alle VL-Wochen rein angezeigt werden."
///
/// Testdaten (erfunden): Mathematik I und Mathematik II mit je Vorlesung und Uebung, je Lehrwoche 1–5 eine Datei der
/// Vorlesung ("M1 …", "M2 …"). Die Uebung zu Mathematik II lag zuerst (falsch geraten) unter Mathematik I, ihr Termin
/// (Do 12:00) wurde so uebernommen; danach hat der Nutzer den Kurs Mathematik II zugeordnet.
///
/// Vorher (fce67e0c): Termin im Lernkalender antippen -> "Zum Modul" oeffnete Mathematik I (Modul der Serie statt des
/// Kurses) mit allen fuenf Wochen aufgeklappt; das Lernpaket hatte gar keinen Weg ins Modul. Jetzt: Mathematik II, nur
/// die Woche des Termins (bzw. der Unterlagen des Pakets) offen, die anderen zugeklappt und mit einem Tippen auf.
/// Bewusst nur mit Typen, die es vorher schon gab (EventDrawer, PackageDrawer, ModulePage, UFRouter): derselbe Test
/// laeuft am alten Stand und ist dort rot.
@MainActor
final class PlanerModulWocheAppTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-12T10:00:00")!
    private let names = ["Einführung", "Folgen", "Reihen", "Stetigkeit", "Ableitung"]

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(Self.accessibilityAutomation(true))
    }

    override func tearDown() async throws {
        Self.accessibilityAutomation(false)
        try await super.tearDown()
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

    /// Geraet mit beiden Modulen, Dateien, dem Termin der Uebung (Serie mit altem Modul 1, Kurs danach Modul 2) und einem
    /// Lernpaket von Mathematik II am 12.11. mit einer Aufgabe zur Datei aus Woche 2
    private func device() throws -> (api: APIClient, event: Int, package: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-planer-modul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock, university: .luh)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let names = names
        return try awaiting { () async throws -> (APIClient, Int, Int) in
            let b = try await host.backend()
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Mathematik I', '#175ee8', 0), (2, 'Mathematik II', '#16a34a', 1)")
                for (id, title, kind, module) in [("m1-vl", "Mathematik I", "vorlesung", 1), ("m1-ue", "Übung zu Mathematik I", "uebung", 1),
                                                  ("m2-vl", "Mathematik II", "vorlesung", 2), ("m2-ue", "Übung zu Mathematik II", "uebung", 1)] {
                    try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,1,?,'t')",
                                  [.text(id), .text(title), .text(module == 1 ? "Mathematik I" : "Mathematik II"), .text(kind), .integer(Int64(module))])
                }
                // Lehrwoche 1 ab Montag 12.10.: je Woche eine Datei je Vorlesung, Dienstag 10:00
                let first = try XCTUnwrap(Fmt.date("2026-10-13")).addingTimeInterval(10 * 3600)
                for (i, n) in names.enumerated() {
                    for (course, prefix) in [("m1-vl", "M1"), ("m2-vl", "M2")] {
                        try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)",
                                      [.text("\(prefix)-\(i + 1)"), .text(course), .text("\(prefix) \(n).pdf"),
                                       .integer(Int64(first.addingTimeInterval(Double(i) * 7 * 86400).timeIntervalSince1970))])
                    }
                }
            }
            let ev = try await api.value("/api/timetable/events", method: "POST",
                                         body: ["title": "Übung zu Mathematik II", "kind": "uebung", "weekday": 3, "start_time": "12:00",
                                                "end_time": "13:30", "rrule": "weekly", "module_id": 1, "course_id": "m2-ue"])
            _ = try await api.value("/api/courses/m2-ue/module", method: "POST", body: ["module_id": 2])
            let pkg = try await api.value("/api/packages", method: "POST",
                                          body: ["date": "2026-11-12", "module_id": 2, "title": "Folgen wiederholen",
                                                 "tasks": [["type": "vorlesung", "file_id": "M2-2", "title": "M2 Folgen", "est_minutes": 30]]])
            return (api, try XCTUnwrap(ev.i("id")), try XCTUnwrap(pkg.i("id")))
        }
    }

    // MARK: Fenster und Bedienungshilfen (wie TerminDetailAppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient, router: UFRouter, size: CGSize = CGSize(width: 1180, height: 2400)) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-planer-modul-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(router)
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(UFToastCenter())
            .environmentObject(StudIPSync())
        let frame = CGRect(origin: .zero, size: size)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func elements(in window: UIWindow) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()                   // ein Element ist ueber mehrere Wege erreichbar
        func visit(_ element: Any, depth: Int) {
            guard depth < 45 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        window.layoutIfNeeded()
        visit(window, depth: 0)
        return out
    }

    private func texts(_ w: UIWindow) -> [String] { elements(in: w).compactMap(\.accessibilityLabel) }
    private func shows(_ w: UIWindow, _ text: String) -> Bool { texts(w).contains { $0.contains(text) } }
    private func dump(_ w: UIWindow) -> String { texts(w).joined(separator: "\n") }
    /// Wochenkoepfe ("Woche 3 · 26.10. – 01.11."; Nummern je nach Semesterkalender der Hochschule)
    private func weekHeads(_ w: UIWindow) -> Int { Set(texts(w).filter { $0.hasPrefix("Woche ") && $0.contains(" · ") }).count }

    private func tap(_ label: String, in w: UIWindow) -> Bool {
        for e in elements(in: w) where e.accessibilityTraits.contains(.button) && e.accessibilityLabel == label {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Moduldetail zur Route des Routers; wartet auf die Wochenkoepfe
    private func modulePage(after router: UFRouter, api: APIClient) throws -> UIWindow {
        guard case .module(let id) = router.route else {
            XCTFail("keine Modul-Route: \(router.route)")
            return try show(EmptyView(), api: api, router: router)
        }
        let w = try show(ModulePage(id: id), api: api, router: router)
        XCTAssertTrue(pump { self.weekHeads(w) >= 5 }, dump(w))
        pump(timeout: 0.5)
        return w
    }

    // MARK: Tests

    /// Termin im Lernkalender antippen -> "Zum Modul": Mathematik II, nur Woche 4 (Do 05.11.) aufgeklappt
    func testEventOpensRightModuleWithOnlyItsWeek() throws {
        let (api, event, _) = try device()
        let router = UFRouter(start: .plan(view: "week", date: "2026-11-05"))
        let drawer = try show(EventDrawer(eventID: event, date: "2026-11-05"), api: api, router: router, size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(pump { self.shows(drawer, "Zum Modul") }, dump(drawer))
        XCTAssertTrue(tap("Zum Modul", in: drawer), dump(drawer))
        XCTAssertTrue(pump { router.route != .plan(view: "week", date: "2026-11-05") })
        drawer.isHidden = true
        XCTAssertEqual(router.route, .module(2), "Modul des Kurses (Mathematik II), nicht das beim Import geratene (Mathematik I)")

        let w = try modulePage(after: router, api: api)
        XCTAssertTrue(shows(w, "Mathematik II"), dump(w))
        XCTAssertEqual(weekHeads(w), 5, "alle fuenf Wochenkoepfe bleiben sichtbar: \(dump(w))")
        XCTAssertTrue(shows(w, "M2 Stetigkeit"), "Woche des Termins aufgeklappt: \(dump(w))")
        for (i, n) in names.enumerated() where i != 3 {
            XCTAssertFalse(shows(w, "M2 \(n)"), "Woche \(i + 1) zugeklappt: \(dump(w))")
        }
        XCTAssertFalse(shows(w, "M1 "), "nichts aus Mathematik I")
        // andere Wochen mit einem Tippen
        XCTAssertTrue(tap("Alle Wochen aufklappen", in: w), dump(w))
        XCTAssertTrue(pump { self.names.allSatisfy { self.shows(w, "M2 \($0)") } }, dump(w))
    }

    /// Lernpaket antippen -> "Zum Modul": Mathematik II, aufgeklappt die Woche der Unterlage der Aufgabe (Woche 2)
    func testPackageOpensModuleWithWeekOfItsMaterial() throws {
        let (api, _, package) = try device()
        let router = UFRouter(start: .plan(view: "week", date: "2026-11-12"))
        let drawer = try show(PackageDrawer(id: package), api: api, router: router, size: CGSize(width: 1180, height: 1400))
        XCTAssertTrue(pump { self.shows(drawer, "Folgen wiederholen") }, dump(drawer))
        XCTAssertTrue(pump(timeout: 2) { self.shows(drawer, "Zum Modul") }, "Lernpaket ohne Weg ins Modul: \(dump(drawer))")
        XCTAssertTrue(tap("Zum Modul", in: drawer), dump(drawer))
        XCTAssertTrue(pump(timeout: 2) { router.route == .module(2) }, "\(router.route)")
        drawer.isHidden = true
        guard router.route == .module(2) else { return }

        let w = try modulePage(after: router, api: api)
        XCTAssertTrue(shows(w, "M2 Folgen"), "Woche der Unterlage aufgeklappt: \(dump(w))")
        for (i, n) in names.enumerated() where i != 1 {
            XCTAssertFalse(shows(w, "M2 \(n)"), "Woche \(i + 1) zugeklappt: \(dump(w))")
        }
    }

    /// Moduldetail ohne Sprung (Meine Module, Seitenleiste): wie bisher alle Wochen offen, kein Hinweis
    func testModuleListStillShowsAllWeeks() throws {
        let (api, _, _) = try device()
        let router = UFRouter(start: .module(2))
        let w = try modulePage(after: router, api: api)
        for n in names { XCTAssertTrue(shows(w, "M2 \(n)"), "\(n): \(dump(w))") }
        XCTAssertFalse(shows(w, "Alle Wochen aufklappen"))
    }
}

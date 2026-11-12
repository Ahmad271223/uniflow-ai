import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Auftrag 12.11.2026: "Beim Stundenplan bitte auch einen Strich einfügen mit aktueller Uhrzeit wie beim Lernkalender."
/// Ein Baustein (`UFNowLine`) fuer Stundenplan und Lernkalender: nur in der Spalte von heute, nur im sichtbaren
/// Zeitbereich, VoiceOver "Jetzt, hh:mm". Uhrzeit fest ueber `UFNowLine.nowOverride` (Do 12.11.2026 10:30 Berlin).
@MainActor
final class StundenplanJetztLinieAppTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-12T10:30:00")!

    private static func at(_ day: String, _ hour: Int, _ minute: Int) -> Date {
        Fmt.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Fmt.date(day)!)!
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(Self.accessibilityAutomation(true))
        UFNowLine.nowOverride = Self.at("2026-11-12", 10, 30)
    }

    override func tearDown() async throws {
        UFNowLine.nowOverride = nil
        Self.accessibilityAutomation(false)
        try await super.tearDown()
    }

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func api() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-jetzt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock, university: .luh)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let done = expectation(description: "Termin")
        Task { @MainActor in
            _ = try? await api.value("/api/timetable/events", method: "POST",
                                     body: ["title": "Mathematik I", "kind": "vorlesung", "weekday": 3, "start_time": "10:00",
                                            "end_time": "11:30", "rrule": "weekly"])
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return api
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-jetzt-\(UUID().uuidString)"
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
        let frame = CGRect(x: 0, y: 0, width: 1366, height: 1400)
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

    private func labels(_ w: UIWindow) -> [String] { elements(in: w).compactMap(\.accessibilityLabel) }
    private func nowLines(_ w: UIWindow) -> [NSObject] { elements(in: w).filter { $0.accessibilityLabel?.hasPrefix("Jetzt, ") == true } }

    // MARK: Regeln

    /// Nur heute, nur im sichtbaren Bereich; Beschriftung "Jetzt, 10:30"
    func testRules() {
        let now = Self.at("2026-11-12", 10, 30)
        XCTAssertEqual(UFNowLine.label(now), "Jetzt, 10:30")
        XCTAssertEqual(UFNowLine.minutes(now), 630)
        XCTAssertTrue(UFNowLine.visible(date: "2026-11-12", now: now, lo: 420, hi: 1140))
        XCTAssertFalse(UFNowLine.visible(date: "2026-11-11", now: now, lo: 420, hi: 1140), "nur am heutigen Tag")
        XCTAssertFalse(UFNowLine.visible(date: "2026-11-12", now: Self.at("2026-11-12", 6, 59), lo: 420, hi: 1140), "vor dem Raster")
        XCTAssertFalse(UFNowLine.visible(date: "2026-11-12", now: Self.at("2026-11-12", 19, 1), lo: 420, hi: 1140), "nach dem Raster")
        XCTAssertTrue(UFNowLine.visible(date: "2026-11-12", now: Self.at("2026-11-12", 19, 0), lo: 420, hi: 1140), "Rand zaehlt")
        XCTAssertEqual(UFNowLine.now(), now, "feste Uhrzeit im Test")
    }

    // MARK: Stundenplan

    /// Woche mit heute: genau eine Linie "Jetzt, 10:30" in der Donnerstagsspalte, auf Hoehe 10:30 (zwischen den
    /// Stundenmarken 10:00 und 11:00 der Zeitachse)
    func testTimetableShowsNowLineOnToday() throws {
        let w = try show(TimetableView(date: "2026-11-12"), api: try api())
        XCTAssertTrue(pump { self.labels(w).contains { $0.hasPrefix("Mathematik I") } }, labels(w).joined(separator: "\n"))
        XCTAssertTrue(pump(timeout: 3) { self.nowLines(w).count == 1 }, labels(w).joined(separator: "\n"))
        let line = try XCTUnwrap(nowLines(w).first)
        XCTAssertEqual(line.accessibilityLabel, "Jetzt, 10:30")
        // senkrecht: in der Mitte zwischen 10:00 und 11:00 der Zeitachse
        let axis = elements(in: w).filter { ["10:00", "11:00"].contains($0.accessibilityLabel ?? "") }.map(\.accessibilityFrame.midY).sorted()
        if axis.count == 2 {
            XCTAssertEqual(line.accessibilityFrame.midY, (axis[0] + axis[1]) / 2, accuracy: 3, "Hoehe 10:30")
        }
        // waagrecht: in der Spalte des Donnerstags (Kopf "Donnerstag")
        if let thu = elements(in: w).first(where: { $0.accessibilityLabel == "Donnerstag" }) {
            XCTAssertTrue(line.accessibilityFrame.minX <= thu.accessibilityFrame.midX && thu.accessibilityFrame.midX <= line.accessibilityFrame.maxX,
                          "Linie \(line.accessibilityFrame) unter dem Kopf \(thu.accessibilityFrame)")
        }
    }

    /// Spaeter am Abend ausserhalb des Rasters (bis 19:00) und in einer anderen Woche: keine Linie
    func testTimetableHidesNowLineOutsideRangeAndOtherWeeks() throws {
        let api = try api()
        UFNowLine.nowOverride = Self.at("2026-11-12", 22, 15)
        let late = try show(TimetableView(date: "2026-11-12"), api: api)
        XCTAssertTrue(pump { self.labels(late).contains { $0.hasPrefix("Mathematik I") } })
        pump(timeout: 0.5)
        XCTAssertTrue(nowLines(late).isEmpty, "22:15 liegt nach dem Raster")
        late.isHidden = true
        UFNowLine.nowOverride = Self.at("2026-11-12", 10, 30)
        let next = try show(TimetableView(date: "2026-11-19"), api: api)
        XCTAssertTrue(pump { self.labels(next).contains { $0.hasPrefix("Mathematik I") } })
        pump(timeout: 0.5)
        XCTAssertTrue(nowLines(next).isEmpty, "naechste Woche: heute nicht im Raster")
    }

    /// Lernkalender (Woche) zeigt dieselbe Linie aus demselben Baustein
    func testPlanWeekUsesSameNowLine() throws {
        let w = try show(PlanView(params: (view: "week", date: "2026-11-12", module: "")), api: try api())
        XCTAssertTrue(pump(timeout: 15) { self.nowLines(w).count == 1 }, labels(w).joined(separator: "\n"))
        XCTAssertEqual(nowLines(w).first?.accessibilityLabel, "Jetzt, 10:30")
    }
}

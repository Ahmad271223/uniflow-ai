import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Raumfinder der Uni Hildesheim auf dem iPad (07.11.2026, docs/RAUMFINDER-HILDESHEIM-2026-11-07.md): Seite mit Suche im
/// Raumplan des LSF, Gebaeudeliste, Detail mit Adresse, Kartenlinks und Belegung; Termin im Stundenplan mit Raumcode
/// -> Route zu Fuss ohne Anfrage. Daten: lokales Backend der Hochschule "hildesheim" mit nachgebauten LSF-Seiten
/// (`HildesheimRoomsDemoHTTP`, erfundene Raeume), nie Netz. Mit UF_SCREENSHOT_DIR schreibt der Test Bildschirmfotos.
@MainActor
final class HildesheimRoomFinderAppTests: XCTestCase {

    final class Recorder: APITransport, @unchecked Sendable {
        let inner: APITransport
        private let lock = NSLock()
        private var paths: [String] = []
        init(_ inner: APITransport) { self.inner = inner }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { paths.append(request.url?.path ?? "") }
            return try await inner.send(request)
        }
        func count(_ path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-hi-rooms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Lokales Backend der Uni Hildesheim (Einstellungen `university = hildesheim`)
    private func device() throws -> (APIClient, Recorder) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-07T10:00:00")!, university: .hildesheim)
        let rec = Recorder(LocalTransport(host: host))
        return (APIClient(base: APIClient.localBase, transport: rec), rec)
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

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-hi-rooms-\(UUID().uuidString)"
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

    /// Bildschirmfoto des Fensters (mit praesentiertem Blatt) als PNG nach UF_SCREENSHOT_DIR, sonst nichts
    private func screenshot(_ w: UIWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        pump(timeout: 0.6)
        let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: url.appendingPathComponent("\(name).png"))
    }

    // MARK: Tests

    /// Seite: Suche im LSF (vorbelegt "Test"), Standorte und Gebaeudeliste, Detail mit Adresse, Karten und Belegung
    func testPageSearchDetailAndPlan() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (api, rec) = try device()
        let w = try show(RoomFinderPage(initialQuery: "Test"), api: api)
        XCTAssertTrue(pump { self.shows(w, "2 Treffer") }, texts(w).joined(separator: "\n"))
        XCTAssertTrue(pump { self.shows(w, "Standorte der Universität Hildesheim") }, texts(w).joined(separator: "\n"))
        for t in ["Gebäude im LSF (44)", "Raum TC.T.1.01 – Kleiner Testraum", "Gebäude T (Testcampus) · 1. Obergeschoss · Teststraße 1, 31141 Hildesheim",
                  "Gebäude I (Hauptcampus)", "Suche: Raumplan im LSF der Universität Hildesheim"] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(texts(w).joined(separator: "\n"))")
        }
        XCTAssertFalse(shows(w, "hat noch keinen Raumfinder"))
        XCTAssertEqual(rec.count("/api/rooms/search"), 1)
        screenshot(w, "raumfinder-hildesheim-seite")
        XCTAssertTrue(tap("Raum TC.T.1.01", in: w, exact: false))
        XCTAssertTrue(pump { self.shows(w, "In Google Maps öffnen") }, texts(w).joined(separator: "\n"))
        for t in ["Route zu Fuß in Google Maps", "In Apple Karten", "Gebäude T (Testcampus)"] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(texts(w).joined(separator: "\n"))")
        }
        XCTAssertEqual(rec.count("/api/rooms/plan"), 0, "Belegung erst auf Antippen")
        screenshot(w, "raumfinder-hildesheim-detail")
        // ganzer Ort ohne Blatt (im Blatt liegt der untere Teil ausserhalb des sichtbaren Bereichs): Verweise, Belegung
        w.isHidden = true
        let place = try awaiting { try await api.value("/api/rooms/place?rgid=9002") }["place"] ?? .null
        let d = try show(ScrollView { RoomPlaceView(place: place, attribution: "Lage: LSF").padding(20) }, api: api)
        XCTAssertTrue(pump { self.shows(d, "Raum TC.T.0.02 – Großer Testsaal") }, texts(d).joined(separator: "\n"))
        for t in ["Teststraße 1, 31141 Hildesheim", "Erdgeschoss", "Hörsaal", "Raum im LSF", "Gebäude im LSF",
                  "Belegung dieser Woche laden", "Lage: LSF. Angaben ohne Gewähr."] {
            XCTAssertTrue(shows(d, t), "\(t) fehlt: \(texts(d).joined(separator: "\n"))")
        }
        XCTAssertFalse(shows(d, "Barrierefreiheit"), "nur beim Standortfinder")
        XCTAssertTrue(tap("Belegung dieser Woche laden", in: d))
        XCTAssertTrue(pump { self.shows(d, "1234 Testvorlesung Algorithmen") }, texts(d).joined(separator: "\n"))
        XCTAssertTrue(shows(d, "KW 45 · 2026"))
        XCTAssertTrue(shows(d, "Klausur Testmodul & Übung"))
        XCTAssertFalse(shows(d, "Muster"), "keine Lehrpersonen")
        XCTAssertEqual(rec.count("/api/rooms/plan"), 1)
        XCTAssertTrue(tap("Nächste Woche", in: d))
        XCTAssertTrue(pump { self.shows(d, "KW 46 · 2026") }, texts(d).joined(separator: "\n"))
        XCTAssertEqual(rec.count("/api/rooms/plan"), 2)
        screenshot(d, "raumfinder-hildesheim-belegung")
    }

    /// Termin im Stundenplan mit LSF-Raumcode: Antippen startet die Route zu Fuss (ohne Anfrage ans LSF), daneben
    /// "Im Raumfinder anzeigen" mit Adresse
    func testTimetableRoomRoute() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (api, rec) = try device()
        let created = try awaiting {
            try await api.value("/api/timetable/events", method: "POST",
                                body: ["title": "Einführung in die Informatik", "kind": "vorlesung", "weekday": 3, "start_time": "10:00",
                                       "end_time": "12:00", "rrule": "weekly", "room": "Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1"])
        }
        let id = try XCTUnwrap(created.i("id"))
        var opened: [URL] = []
        TerminOpen.handler = { opened.append($0) }
        defer { TerminOpen.handler = nil }
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        let label = TerminDetailText.routeLabel("Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1")
        XCTAssertTrue(pump { self.shows(w, label) }, texts(w).joined(separator: "\n"))
        XCTAssertEqual(rec.count("/api/rooms/resolve"), 0, "nichts wird vor dem Antippen aufgeloest")
        XCTAssertTrue(tap(label, in: w))
        XCTAssertTrue(pump { !opened.isEmpty })
        XCTAssertEqual(opened.first?.absoluteString, "https://www.google.com/maps/dir/?api=1&destination=52.13452%2C9.97618&travelmode=walking")
        XCTAssertEqual(rec.count("/api/rooms/resolve"), 1)
        screenshot(w, "raumfinder-hildesheim-termin")
        XCTAssertTrue(tap(TerminDetailText.finderLabel("Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1"), in: w))
        XCTAssertTrue(pump { self.shows(w, "Universitätsplatz 1, 31141 Hildesheim") }, texts(w).joined(separator: "\n"))
        XCTAssertTrue(shows(w, "Raum HC.I.1.Hörsaal 1"))
    }

    /// Regeln ohne Oberflaeche: Gebaeudename -> Route zum Gebaeude, unbekannter Text -> Raumfinder mit Suche, Online bleibt Text
    func testResolveRules() throws {
        let (api, _) = try device()
        let forum = try awaiting { try await api.value("/api/rooms/resolve?text=Forum") }
        let fp = try XCTUnwrap(forum.list("parts").first)
        XCTAssertEqual(fp.s("status"), "building")
        XCTAssertEqual(TerminDetail.route(fp, appInstalled: false),
                       .route("https://www.google.com/maps/dir/?api=1&destination=52.1333%2C9.9757&travelmode=walking"))
        let none = try awaiting { try await api.value("/api/rooms/resolve?text=Raum%204711") }
        let np = try XCTUnwrap(none.list("parts").first)
        XCTAssertEqual(np.s("status"), "not_found")
        XCTAssertEqual(TerminDetail.route(np, appInstalled: false), .search("Raum 4711"))
        XCTAssertEqual(RoomUI.statusText(np), HildesheimRooms.notFound)
        let online = try awaiting { try await api.value("/api/rooms/resolve?text=Online") }
        XCTAssertEqual(TerminDetail.route(try XCTUnwrap(online.list("parts").first), appInstalled: false), .none)
        let campuses = try awaiting { try await api.value("/api/rooms/campuses") }
        XCTAssertEqual(campuses["finder"]?.bool, true)
        XCTAssertEqual(campuses.list("buildings").count, 44)
        XCTAssertEqual(campuses.list("buildings").first?.s("campus"), "Hauptcampus", "Hauptcampus zuerst")
        XCTAssertEqual(campuses["source"]?.s("key"), "lsf")
    }
}

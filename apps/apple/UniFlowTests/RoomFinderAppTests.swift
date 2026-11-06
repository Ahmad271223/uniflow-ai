import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Raumfinder auf dem iPad (05.11.2026, docs/RAUMFINDER-2026-11-05.md): Kartenlinks (Google-Maps-App oder Web, Route zu
/// Fuss, Apple Karten), Route und Menuepunkt unter "Alltag", Seite mit Suche und Detail, Termin im Stundenplan mit
/// antippbarem Raum. Daten: lokales Backend mit `RoomFinderDemoHTTP` (gespeicherte Treffer des Standortfinders), nie Netz.
@MainActor
final class RoomFinderAppTests: XCTestCase {

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-rooms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func device() throws -> (APIClient, Recorder) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-05T10:00:00")!)
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

    // MARK: Bedienungshilfen lesen und ausloesen

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-rooms-\(UUID().uuidString)"
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

    /// Google Maps: App, wenn installiert (`comgooglemaps://`), sonst Web; Route zu Fuss; Apple Karten daneben
    func testMapsLinksForAPlace() async throws {
        let f102 = try await RoomFinderDemoHTTP().search("F102", page: 0)
        let place = Rooms.place(try XCTUnwrap(f102["data"]?.array?.first))
        XCTAssertEqual(place.s("title"), "Raum F102")
        let maps = place["maps"]
        XCTAssertEqual(RoomUI.googleURL(maps, route: false, appInstalled: false)?.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=52.38255%2C9.71785")
        XCTAssertEqual(RoomUI.googleURL(maps, route: true, appInstalled: false)?.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking")
        XCTAssertEqual(RoomUI.googleURL(maps, route: false, appInstalled: true)?.absoluteString, "comgooglemaps://?q=52.38255%2C9.71785")
        XCTAssertEqual(RoomUI.googleURL(maps, route: true, appInstalled: true)?.absoluteString,
                       "comgooglemaps://?daddr=52.38255%2C9.71785&directionsmode=walking")
        XCTAssertEqual(RoomUI.appleURL(maps)?.absoluteString, "https://maps.apple.com/?q=Raum%20F102&ll=52.38255%2C9.71785")
        XCTAssertEqual(RoomUI.path(text: "1101 - F102"), "/api/rooms/resolve?text=1101%20-%20F102")
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String]
        XCTAssertEqual(schemes, ["comgooglemaps"], "canOpenURL fuer die Google-Maps-App")
        // Detail baut sich auf
        let host = UIHostingController(rootView: RoomDetailSheet(place: place, attribution: "Lage: Test"))
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }

    func testRouteAndMenuEntry() {
        XCTAssertEqual(UFRoute.rooms.hash, "#/raumfinder")
        XCTAssertEqual(UFRoute(hash: "#/raumfinder"), .rooms)
        XCTAssertEqual(UFRoute(hash: "#/rooms"), .rooms)
        XCTAssertEqual(UFRoute.rooms.navKey, "rooms")
        let local = UFNavItem.visible(local: true, gradesOnDevice: false, community: false, flashcards: false)
        let item = try? XCTUnwrap(local.first { $0.id == "rooms" })
        XCTAssertEqual(item?.title, "Raumfinder")
        XCTAssertTrue(UFIconNames.all.contains("map-pin"))
        XCTAssertTrue(UFNavItem.active(item!, in: local, route: .rooms))
        XCTAssertEqual(UFNavGroup.groups(local).first { $0.id == "everyday" }?.items.map(\.id), ["mensa", "rooms"])
        XCTAssertTrue(UFNavItem.more(visible: local).contains { $0.id == "rooms" }, "in der unteren Leiste unter Mehr")
    }

    /// Seite: Beispiel "F102" antippen -> Treffer -> Detail mit Google Maps, Route, Apple Karten und Raumplan
    func testPageSearchAndDetail() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (api, rec) = try device()
        let w = try show(RoomFinderPage(), api: api)
        XCTAssertTrue(pump { self.shows(w, "Hauptgebäude (Welfengarten)") }, texts(w).joined(separator: "\n"))
        XCTAssertTrue(shows(w, "Raumfinder"))
        XCTAssertTrue(tap("F102", in: w))
        XCTAssertTrue(pump { self.shows(w, "1 Treffer") }, texts(w).joined(separator: "\n"))
        XCTAssertEqual(rec.count("/api/rooms/search"), 1)
        XCTAssertTrue(tap("Raum F102", in: w, exact: false))
        XCTAssertTrue(pump { self.shows(w, "In Google Maps öffnen") }, texts(w).joined(separator: "\n"))
        for t in ["Route zu Fuß in Google Maps", "In Apple Karten", "1. Obergeschoss"] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(texts(w).joined(separator: "\n"))")
        }
        // ganzer Ort ohne Blatt (im Blatt liegt der untere Teil ausserhalb des sichtbaren Bereichs)
        w.isHidden = true
        let f102 = try awaiting { try await RoomFinderDemoHTTP().search("F102", page: 0) }
        let place = Rooms.place(try XCTUnwrap(f102["data"]?.array?.first))
        let d = try show(ScrollView { RoomPlaceView(place: place, attribution: "Lage: Standortfinder").padding(20) }, api: api)
        XCTAssertTrue(pump { self.shows(d, "Raumplan ansehen") }, texts(d).joined(separator: "\n"))
        for t in ["In Google Maps öffnen", "Welfengarten 1, 30167 Hannover", "Raum im Gebäudeinfo der LUH",
                  "Keine Angaben zur Barrierefreiheit im Standortfinder.", "Lage: Standortfinder. Angaben ohne Gewähr."] {
            XCTAssertTrue(shows(d, t), "\(t) fehlt: \(texts(d).joined(separator: "\n"))")
        }
    }

    /// Termin im Stundenplan: Raum "1101 - F102" ist ein Link; Antippen loest ihn auf und zeigt den Google-Maps-Link
    func testTimetableEntryWithTappableRoom() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let (api, rec) = try device()
        let created = try awaiting {
            try await api.value("/api/timetable/events", method: "POST",
                                body: ["title": "Testphysik", "kind": "vorlesung", "weekday": 3, "start_time": "10:00", "end_time": "11:30",
                                       "rrule": "weekly", "room": "1101 - F102"])
        }
        let id = try XCTUnwrap(created.i("id"))
        let resolved = try awaiting { try await api.value(RoomUI.path(text: "1101 - F102")) }
        XCTAssertEqual(resolved.list("parts").first?.s("status"), "found")
        XCTAssertEqual(resolved.list("parts").first?["maps"]?.s("google_route"),
                       "https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking")
        let before = rec.count("/api/rooms/resolve")

        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "Raum 1101 - F102") }, texts(w).joined(separator: "\n"))
        XCTAssertEqual(rec.count("/api/rooms/resolve"), before, "nichts wird vor dem Antippen aufgeloest")
        XCTAssertTrue(tap("Raum 1101 - F102", in: w))
        XCTAssertTrue(pump { self.shows(w, "In Google Maps öffnen") }, texts(w).joined(separator: "\n"))
        XCTAssertTrue(shows(w, "Raum F102"))
        XCTAssertEqual(rec.count("/api/rooms/resolve"), before + 1)
    }

    /// Online-Termine bleiben Text; HsH-Angaben werden zum Standort der Hochschule
    func testLinkRulesAndOtherUniversities() throws {
        XCTAssertFalse(Rooms.mayLink("Online"))
        XCTAssertTrue(Rooms.mayLink("Hörsaal F 303"))
        let (api, _) = try device()
        let r = try awaiting { try await api.value("/api/rooms/resolve?text=1H.1.01&university=hsh") }
        let part = try XCTUnwrap(r.list("parts").first)
        XCTAssertEqual(part.s("status"), "campus")
        XCTAssertEqual(part["place"]?.s("title"), "Campus Linden")
        XCTAssertEqual(RoomUI.statusText(part), "Ort laut Hochschule; genaue Lage ohne Gewähr")
        XCTAssertEqual(RoomUI.googleURL(part["maps"], route: false, appInstalled: false)?.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=Hochschule%20Hannover%2C%20Ricklinger%20Stadtweg%20120%2C%2030459%20Hannover")
    }
}

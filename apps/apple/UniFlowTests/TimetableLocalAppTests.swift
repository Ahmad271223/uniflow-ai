import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// S5 im lokalen Modus ohne PC: Stundenplan aus Stud.IP (erfundene JSON:API-Antworten aus
/// packages/shared-contracts/fixtures/studip-schedule) in die Datenbank des Geraets, Stundenplan-Woche und
/// Gruppenauswahl der Importvorschau aus dem lokalen Backend. Uhr eingefroren: 25.10.2026 (Zeitumstellung).
@MainActor
final class TimetableLocalAppTests: XCTestCase {

    /// Feste Stud.IP-Antworten je Pfad (ohne Host, Klammern unkodiert); andere Pfade 404
    final class FixtureTransport: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let routes: [String: HTTPReply]
        private var log: [String] = []

        init(_ routes: [String: HTTPReply]) { self.routes = routes }

        var requested: [String] { lock.withLock { log } }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: "https://studip.test", with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.withLock { log.append(key) }
            return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }
    }

    /// Merkt sich Pfad und Status jeder Anfrage an das lokale Backend
    final class RecordingTransport: APITransport, @unchecked Sendable {
        let inner: LocalTransport
        private let lock = NSLock()
        private var log: [(path: String, status: Int)] = []

        init(_ inner: LocalTransport) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let r = try await inner.send(request)
            lock.withLock { log.append((request.url?.path ?? "", r.1.statusCode)) }
            return r
        }

        var calls: [(path: String, status: Int)] { lock.withLock { log } }
    }

    private static let courses = [
        StudIPCourse(id: "c-ana", title: "Testanalysis I", number: "9001", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "c-ana-ue", title: "Übung Testanalysis I", number: "9002", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "c-prog", title: "Testprogrammierung", number: "9003", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "c-sem", title: "Testseminar Beispiel", semesterTitle: "WiSe 2026/27"),
        StudIPCourse(id: "c-erst", title: "Begrüßung der Erstsemester", semesterTitle: "WiSe 2026/27"),
    ]

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-s5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func host() throws -> LocalBackendHost {
        LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-25T14:30:05")!)
    }

    private func fixture(_ name: String) throws -> HTTPReply {
        // .../apps/apple/UniFlowTests/TimetableLocalAppTests.swift -> Repository-Wurzel
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/\(name)"))
        return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: data)
    }

    /// Stud.IP mit den erfundenen Antworten; `replace` ueberschreibt einzelne Pfade (Fehlerfaelle)
    private func studIP(_ replace: [String: HTTPReply] = [:]) throws -> (StudIPClient, FixtureTransport) {
        let empty = HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(#"{"data": [], "links": {}}"#.utf8))
        var routes: [String: HTTPReply] = [
            "/jsonapi.php/v1/users/u-test/schedule": try fixture("users-schedule.json"),
            "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester": try fixture("users-courses.json"),
            "/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": try fixture("course-events-c-ana-1.json"),
            "/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200": try fixture("course-events-c-ana-2.json"),
            "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": try fixture("course-events-c-sem.json"),
            "/jsonapi.php/v1/courses/c-ana-ue/events?page[limit]=200": empty,
            "/jsonapi.php/v1/courses/c-prog/events?page[limit]=200": empty,
            "/jsonapi.php/v1/courses/c-erst/events?page[limit]=200": empty,
        ]
        for (k, v) in replace { routes[k] = v }
        let t = FixtureTransport(routes)
        return (StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0), t)
    }

    /// Lokales Backend mit dem Stundenplan aus Stud.IP (wie nach einem Abgleich)
    private func syncedAPI() async throws -> (APIClient, RecordingTransport, LocalBackendHost) {
        let h = try host()
        let (client, _) = try studIP()
        let out = await StudIPScheduleSync(host: h).run(client: client, userID: "u-test", courses: Self.courses)
        XCTAssertNotNil(out.result)
        let recorder = RecordingTransport(LocalTransport(host: h))
        return (APIClient(base: APIClient.localBase, transport: recorder), recorder, h)
    }

    // MARK: Abruf und Ablage

    func testScheduleSyncFillsLocalTimetable() async throws {
        let h = try host()
        let (client, transport) = try studIP()
        var progress: [String] = []
        let out = await StudIPScheduleSync(host: h).run(client: client, userID: "u-test", courses: Self.courses) { progress.append($0) }
        XCTAssertEqual(progress, ["Stundenplan wird geladen …"])
        XCTAssertEqual(out.result, StudIPScheduleResult(newEvents: 8, pendingGroups: 3, cycles: 8, events: 7))
        XCTAssertEqual(out.summary, ["8 Stundenplan-Termine", "Übungsgruppen zur Auswahl im Stundenplan"])
        XCTAssertTrue(transport.requested.allSatisfy { !$0.contains("/files") && !$0.contains("/folders") }, "nur Stundenplan-Abfragen")

        // Woche nach der Zeitumstellung aus dem lokalen Backend, wie TimetableView.load()
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: h))
        let week = try await api.value("/api/timetable/week?start=2026-10-26")
        let days = week.list("days")
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[0].list("events").map { "\($0.s("title") ?? "") \($0.s("start") ?? "")" }, ["Testanalysis I 10:00"])
        XCTAssertEqual(days[1].list("events").map { $0.s("title") ?? "" }, ["Testprogrammierung", "Testseminar Beispiel"])
        XCTAssertEqual(days[4].list("events").count, 0, "Übungsgruppen warten auf die Auswahl")
        XCTAssertEqual(days[6].list("events").map { $0.s("title") ?? "" }, ["Chorprobe"])
        let next = try await api.value("/api/timetable/week?start=2026-11-02")
        XCTAssertEqual(next.list("days").first?.list("events").first?.s("status"), "ausfall", "Ausfall laut Stud.IP")
        let status = try await api.value("/api/timetable/auto-status")
        XCTAssertEqual(status.i("pending_groups"), 3)

        // zweiter Abgleich: nichts doppelt
        let again = await StudIPScheduleSync(host: h).run(client: try studIP().0, userID: "u-test", courses: Self.courses)
        XCTAssertEqual(again.result?.newEvents, 0)
        XCTAssertEqual(again.summary, ["Übungsgruppen zur Auswahl im Stundenplan"])
        let events = try await api.value("/api/timetable/events").items
        XCTAssertEqual(events.count, 8)
    }

    /// Fehler beim Termin-Abruf werfen nicht (der Datei-Abgleich laeuft weiter) und stehen in der Zusammenfassung
    func testScheduleErrorsNeverThrow() async throws {
        let failing = HTTPReply(status: 500, contentType: "text/plain")
        var replace: [String: HTTPReply] = ["/jsonapi.php/v1/users/u-test/schedule": failing]
        for c in Self.courses { replace["/jsonapi.php/v1/courses/\(c.id)/events?page[limit]=200"] = failing }
        let out = await StudIPScheduleSync(host: try host()).run(client: try studIP(replace).0, userID: "u-test", courses: Self.courses)
        XCTAssertEqual(out.result, StudIPScheduleResult(newEvents: 0, pendingGroups: 0, cycles: 0, events: 0))
        XCTAssertEqual(out.summary, ["Kurszeiten nicht geladen", "Termine von 5 Kursen nicht geladen"])

        let expired = await StudIPScheduleSync(host: try host())
            .run(client: try studIP(["/jsonapi.php/v1/users/u-test/schedule": HTTPReply(status: 401)]).0, userID: "u-test", courses: Self.courses)
        XCTAssertTrue(expired.sessionExpired)
        XCTAssertEqual(expired.summary, ["Stundenplan: Stud.IP-Anmeldung abgelaufen"])

        // Datenbank nicht verfuegbar (Ordner ist eine Datei): nichts gespeichert, kein Absturz
        let blocked = try tempDir().appendingPathComponent("db")
        try Data("x".utf8).write(to: blocked)
        let noDB = await StudIPScheduleSync(host: LocalBackendHost(directory: blocked))
            .run(client: try studIP().0, userID: "u-test", courses: Self.courses)
        XCTAssertNil(noDB.result)
        XCTAssertEqual(noDB.summary, ["Stundenplan nicht gespeichert"])
    }

    // MARK: Seiten im Fenster

    // Die Seiten-Tests laufen synchron: nur dann arbeitet die Hauptschleife (RunLoop.main) die Aufgaben der Ansicht
    // (.task, Antworten des Backends) ab, waehrend der Test wartet.

    /// Asynchrone Vorbereitung aus einem synchronen Test (wartet mit laufender Hauptschleife)
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

    /// SwiftUI baut den Bedienungshilfen-Baum nur, wenn ein Hilfsmittel aktiv ist: Automation ein- und wieder
    /// ausschalten wie bei UI-Tests (nur im Test, libAccessibility des Simulators). false, wenn es das nicht gibt.
    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    /// Hostet eine Ansicht mit den Umgebungsobjekten der App, wartet auf die Anfragen und liefert die sichtbaren Texte
    /// `expected`: Texte, auf die hoechstens bis zum Ende der Wartezeit gewartet wird (der Test prueft sie danach)
    private func render<V: View>(_ view: V, api: APIClient, recorder: RecordingTransport, expected: [String] = [],
                                 until done: ([(path: String, status: Int)]) -> Bool) throws -> [String] {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let suite = "uniflow-s5-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(UFOverlay())
            .environmentObject(UFToastCenter())
            .environmentObject(StudIPSync())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let end = Date().addingTimeInterval(10)
        while !done(recorder.calls) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))                   // Antwort in die Ansicht uebernehmen
        hosting.view.layoutIfNeeded()
        // erwartete Texte koennen spaeter erscheinen (Zustand aus .onAppear, Bedienungshilfen-Baum wird nachgezogen)
        var shown = texts(in: hosting.view)
        while !expected.allSatisfy({ e in shown.contains { $0.contains(e) } }) && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosting.view.layoutIfNeeded()
            shown = texts(in: hosting.view)
        }
        return shown
    }

    /// Texte aus dem Bedienungshilfen-Baum der SwiftUI-Ansicht
    private func texts(in view: UIView) -> [String] {
        var out: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if let l = o.accessibilityLabel, !l.isEmpty { out.append(l) }
                if let v = o.accessibilityValue, !v.isEmpty { out.append(v) }
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

    /// Abnahme S5: Stundenplan-Woche aus Stud.IP im lokalen Modus
    func testTimetablePageShowsStudIPWeekLocally() throws {
        let (api, recorder, _) = try awaiting { try await self.syncedAPI() }
        let titles = ["Testanalysis I", "Testprogrammierung", "Testseminar Beispiel", "Übung Testanalysis I", "Chorprobe"]
        let shown = try render(TimetableView(date: "2026-10-26"), api: api, recorder: recorder, expected: titles) { calls in
            calls.contains { $0.path == "/api/timetable/week" } && calls.contains { $0.path == "/api/timetable/conflicts" }
        }
        let calls = recorder.calls
        XCTAssertTrue(calls.contains { $0.path == "/api/timetable/week" && $0.status == 200 }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(calls)")
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(all.contains("Stundenplan"), all)
        XCTAssertTrue(all.contains("WiSe 2026/27"), all)
        XCTAssertTrue(all.contains("26. Oktober – 1. November 2026"), all)
        for title in titles {
            XCTAssertTrue(all.contains(title), "\(title) fehlt: \(all)")
        }
        XCTAssertFalse(all.contains("Noch kein Stundenplan"), all)
    }

    /// Gruppenauswahl wie in der Web-App: die Vorschau "aus Stud.IP" zeigt die parallelen Gruppen mit Hinweis
    func testImportPreviewOffersGroupChoice() throws {
        let (api, recorder, _) = try awaiting { try await self.syncedAPI() }
        let preview = try awaiting { try await api.form("/api/timetable/import/preview", fields: ["source": "studip"]) }
        let entries = preview.list("entries")
        XCTAssertEqual(entries.filter { $0["selected"]?.bool == false }.count, 3)
        let hint = "3 parallele Gruppen – nur deine Gruppe auswählen"
        let shown = try render(TimetablePreviewDialog(r: preview, source: "studip"), api: api, recorder: recorder, expected: [hint]) { _ in true }
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(all.contains("Importvorschau · \(entries.count) Veranstaltungen"), all)
        XCTAssertTrue(all.contains(hint), all)
        XCTAssertTrue(all.contains("3 neu · 0 geändert · 8 unverändert"), all)
    }
}

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

    /// Stud.IP haengt (Zeitlimit) oder kein Netz: nach der ersten gescheiterten Anfrage fragt der Stundenplan nichts
    /// mehr ab, statt jeden Kurs bis zum Zeitlimit zu versuchen
    func testUnreachableStudIPStopsAfterFirstRequest() async throws {
        final class TimeoutTransport: StudIPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            var count: Int { lock.withLock { n } }
            func get(_ url: URL, accept: String?) async throws -> HTTPReply {
                lock.withLock { n += 1 }
                throw URLError(.timedOut)
            }
        }
        let many = (1...12).map { StudIPCourse(id: "c-\($0)", title: "Testkurs \($0)") }
        let t = TimeoutTransport()
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let out = await StudIPScheduleSync(host: try host()).run(client: client, userID: "u-test", courses: many)
        XCTAssertEqual(t.count, 1)
        XCTAssertTrue(out.unreachable)
        XCTAssertEqual(out.failedCourses, 12)
        XCTAssertEqual(out.summary, ["Stundenplan: Stud.IP nicht erreichbar"])
    }

    /// Gruppenwahl ueber die Importvorschau wie TimetablePreviewDialog: schon uebernommene Termine sind nicht
    /// vorausgewaehlt, Aenderungen des Nutzers bleiben; danach meldet der Abgleich keine offenen Gruppen mehr
    func testGroupChoiceKeepsUserChangesAndClearsHint() async throws {
        let (api, _, h) = try await syncedAPI()
        let events = try await api.value("/api/timetable/events").items
        let ana = try XCTUnwrap(events.first { $0.s("title") == "Testanalysis I" && $0.i("weekday") == 0 }?.i("id"))
        _ = try await api.value("/api/timetable/events/\(ana)", method: "PATCH",
                                body: ["start_time": "10:15", "end_time": "11:45", "room": "Eigener Raum", "kind": "seminar"])

        let preview = try await api.form("/api/timetable/import/preview", fields: ["source": "studip"])
        let diff = preview["diff"] ?? .null
        let rows = preview.list("entries")
        XCTAssertEqual(rows.filter { TimetablePreviewDialog.preselected($0, diff: diff, source: "studip") }.count, 0,
                       "alles schon uebernommen, offene Gruppen nicht angehakt")
        XCTAssertEqual(rows.filter { TimetablePreviewDialog.preselected($0, diff: diff, source: "ics") }.count, rows.count - 3,
                       "andere Quellen wie in der Web-App")
        // wie confirm: angehakte Zeilen (hier nur die gewaehlte Gruppe) mit existing_id
        var group = try XCTUnwrap(rows.first { $0.s("room") == "Pool Test B" }?.object)
        group["selected"] = true
        group["existing_id"] = TimetablePreviewDialog.existing(diff, .object(group))?["existing_id"] ?? .null
        let res = try await api.value("/api/timetable/import/confirm", method: "POST",
                                      body: ["entries": [.object(group)], "source": "studip", "import_id": preview["import_id"] ?? .null, "remove_ids": []])
        XCTAssertEqual(res.i("new"), 1)
        XCTAssertEqual(res.i("updated"), 0)
        let after = try await api.value("/api/timetable/events").items.first { $0.i("id") == ana }
        XCTAssertEqual(after?.s("start_time"), "10:15")
        XCTAssertEqual(after?.s("room"), "Eigener Raum")
        XCTAssertEqual(after?.s("kind"), "seminar")

        let again = await StudIPScheduleSync(host: h).run(client: try studIP().0, userID: "u-test", courses: Self.courses)
        XCTAssertEqual(again.result?.newEvents, 0)
        XCTAssertEqual(again.summary, [], "Gruppe gewählt: kein Hinweis mehr")
        let status = try await api.value("/api/timetable/auto-status")
        XCTAssertEqual(status.i("pending_groups"), 0)
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

    /// Hostet eine Ansicht mit den Umgebungsobjekten der App (`studip`: Abgleich der Ansicht, sonst ein neuer) und gibt
    /// `body` die Funktion `look`: wartet hoechstens `timeout` Sekunden, bis `done` gilt und die Texte `expected`
    /// erscheinen (der Test prueft sie danach), und liefert die sichtbaren Texte. Das Fenster bleibt fuer `body` offen.
    private func hosted<V: View>(_ view: V, api: APIClient, studip: StudIPSync? = nil,
                                 _ body: (_ look: (_ expected: [String], _ timeout: Double, _ done: () -> Bool) -> [String]) throws -> Void) throws {
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
            .environmentObject(studip ?? StudIPSync())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try body { expected, timeout, done in
            let end = Date().addingTimeInterval(timeout)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))               // Antwort in die Ansicht uebernehmen
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
    }

    /// Hostet eine Ansicht, wartet auf die Anfragen und liefert die sichtbaren Texte
    /// `expected`: Texte, auf die hoechstens bis zum Ende der Wartezeit gewartet wird (der Test prueft sie danach)
    private func render<V: View>(_ view: V, api: APIClient, recorder: RecordingTransport, expected: [String] = [],
                                 until done: @escaping ([(path: String, status: Int)]) -> Bool) throws -> [String] {
        var shown: [String] = []
        try hosted(view, api: api) { look in shown = look(expected, 10) { done(recorder.calls) } }
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
        let kept = "Schon übernommene Termine sind nicht angehakt"
        let shown = try render(TimetablePreviewDialog(r: preview, source: "studip"), api: api, recorder: recorder, expected: [hint, kept]) { _ in true }
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(all.contains("Importvorschau · \(entries.count) Veranstaltungen"), all)
        XCTAssertTrue(all.contains(hint), all)
        XCTAssertTrue(all.contains("3 neu · 0 geändert · 8 unverändert"), all)
        XCTAssertTrue(all.contains(kept), all)
    }

    // MARK: Gesamtablauf S3 + S4 + S5

    /// Zweiseitige Test-PDF
    private func pdf(_ marker: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...2 {
                ctx.beginPage()
                ("\(marker) Seite \(i)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    /// Ein ganzes Stud.IP mit erfundenen Antworten: ein Fach in Vorlesung und Uebung (mit Kurszeiten, einem Ausfall und
    /// einer Klausur als Einzeltermin), ein Seminar nur mit Einzelterminen, eine Begruessung; Dateien in Stud.IP-Ordnern
    /// ueber zwei Lehrwochen (die Vorlesungszeit beginnt am 12.10., drei Kurse laden dort hoch), ein eigener Eintrag
    private func fullStudIP() -> FixtureTransport {
        let body = pdf("Testunterlage")
        func ok(_ text: String) -> HTTPReply { HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8)) }
        let semester = #""relationships":{"start-semester":{"data":{"type":"semesters","id":"s-test"}}}"#
        var routes: [String: HTTPReply] = [
            "/jsonapi.php/v1/users/me": ok(#"{"data":{"id":"u-flow","type":"users"}}"#),
            "/jsonapi.php/v1/users/u-flow/courses?page[limit]=100&include=start-semester": ok(#"""
                {"data":[
                  {"id":"c-ma","type":"courses","attributes":{"title":"Testmathematik I","course-number":"T-MA1","course-type":1},\#(semester)},
                  {"id":"c-ma-ue","type":"courses","attributes":{"title":"Übung zu Testmathematik I","course-number":"T-MA2","course-type":3},\#(semester)},
                  {"id":"c-sem","type":"courses","attributes":{"title":"Testseminar Beispiel","course-type":2},\#(semester)},
                  {"id":"c-erst","type":"courses","attributes":{"title":"Begrüßung der Testsemester","course-type":7},\#(semester)}],
                 "included":[{"id":"s-test","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}],
                 "links":{}}
                """#),
            "/jsonapi.php/v1/users/u-flow/schedule": ok(#"""
                {"data":[
                  {"id":"cy-flow-ma","type":"seminar-cycle-dates",
                   "attributes":{"title":"Kurszeit","description":"","start":"10:00","end":"11:30","weekday":1,"color":null,
                                 "recurrence":{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12T10:00:00+02:00","UNTIL":"2027-01-25T11:30:00+01:00",
                                               "EXDATES":["2026-11-02T10:00:00+01:00"]},
                                 "locations":["Hörsaal Test 1"]},
                   "relationships":{"owner":{"data":{"type":"courses","id":"c-ma"}}}},
                  {"id":"cy-flow-ue","type":"seminar-cycle-dates",
                   "attributes":{"title":"Kurszeit","description":"","start":"14:00","end":"15:30","weekday":3,"color":null,
                                 "recurrence":{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-14","UNTIL":"2027-01-27"},"locations":["Raum Test 2"]},
                   "relationships":{"owner":{"data":{"type":"courses","id":"c-ma-ue"}}}},
                  {"id":"pe-flow-1","type":"schedule-entries",
                   "attributes":{"title":"Chorprobe","description":"","start":"17:00","end":"19:00","weekday":7,"color":null},
                   "relationships":{"owner":{"data":{"type":"users","id":"u-flow"}}}}],
                 "links":{}}
                """#),
            // Einzeltermine: die Kurszeit der Vorlesung deckt die Montage ab, die Klausur liegt ausserhalb; das Seminar hat
            // keine Kurszeit (drei Dienstage werden wie am PC eine Serie); die Begruessung ("sonstiges") faellt heraus
            "/jsonapi.php/v1/courses/c-ma/events?page[limit]=200": ok(#"""
                {"data":[
                  {"id":"ev-ma-1","type":"course-events","attributes":{"title":"Sitzung","start":"2026-10-12T10:00:00+02:00","end":"2026-10-12T11:30:00+02:00","location":"Hörsaal Test 1","is-cancelled":false}},
                  {"id":"ev-ma-2","type":"course-events","attributes":{"title":"Sitzung","start":"2026-10-19T10:00:00+02:00","end":"2026-10-19T11:30:00+02:00","location":"Hörsaal Test 1","is-cancelled":false}},
                  {"id":"ev-ma-k","type":"course-events","attributes":{"title":"Klausur","start":"2027-02-08T09:00:00+01:00","end":"2027-02-08T11:00:00+01:00","location":"Audimax Test","is-cancelled":false}}],
                 "links":{}}
                """#),
            "/jsonapi.php/v1/courses/c-ma-ue/events?page[limit]=200": ok(#"{"data":[],"links":{}}"#),
            "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": ok(#"""
                {"data":[
                  {"id":"ev-sem-a","type":"course-events","attributes":{"title":"Termin","start":"2026-10-13T16:00:00+02:00","end":"2026-10-13T17:30:00+02:00","location":"Seminarraum Test","is-cancelled":false}},
                  {"id":"ev-sem-b","type":"course-events","attributes":{"title":"Termin","start":"2026-10-20T16:00:00+02:00","end":"2026-10-20T17:30:00+02:00","location":"Seminarraum Test","is-cancelled":false}},
                  {"id":"ev-sem-c","type":"course-events","attributes":{"title":"Termin","start":"2026-10-27T16:00:00+01:00","end":"2026-10-27T17:30:00+01:00","location":"Seminarraum Test","is-cancelled":false}}],
                 "links":{}}
                """#),
            "/jsonapi.php/v1/courses/c-erst/events?page[limit]=200": ok(#"""
                {"data":[{"id":"ev-erst","type":"course-events","attributes":{"title":"Begrüßung","start":"2026-10-12T09:00:00+02:00","end":"2026-10-12T12:00:00+02:00","location":"Audimax Test","is-cancelled":false}}],
                 "links":{}}
                """#),
        ]
        func ref(_ id: String, _ name: String, _ changed: String) -> String {
            #"{"id":"\#(id)","attributes":{"name":"\#(name)","filesize":\#(body.count),"mime-type":"application/pdf","chdate":"\#(changed)","is-downloadable":true}}"#
        }
        // Ordnerbaum: Kurs -> Wurzelordner -> Unterordner mit Dateien
        let tree: [(course: String, root: String, rootFiles: [String], subs: [(id: String, name: String, files: [String])])] = [
            ("c-ma", "fr-ma", [ref("fk1", "Altklausur WS 2025.pdf", "2026-10-16T08:00:00+02:00")],
             [("fr-ma-v", "Vorlesung", [ref("fv1", "VL01 Einführung.pdf", "2026-10-13T10:00:00+02:00"), ref("fv2", "VL02.pdf", "2026-10-20T10:00:00+02:00")])]),
            ("c-ma-ue", "fr-ue", [],
             [("fr-ue-b", "Übungsblätter", [ref("fu1", "Blatt 1.pdf", "2026-10-14T12:00:00+02:00"), ref("fu2", "Blatt 2.pdf", "2026-10-21T12:00:00+02:00")]),
              ("fr-ue-l", "Lösungen", [ref("fl1", "Lösung Blatt 1.pdf", "2026-10-21T13:00:00+02:00")])]),
            ("c-sem", "fr-sem", [], []),
            ("c-erst", "fr-erst", [ref("fw1", "Willkommen.pdf", "2026-10-12T08:00:00+02:00")], []),
        ]
        for c in tree {
            routes["/jsonapi.php/v1/courses/\(c.course)/folders?page[limit]=200"] = ok(#"{"data":[{"id":"\#(c.root)","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            routes["/jsonapi.php/v1/folders/\(c.root)/file-refs?page[limit]=500"] = ok(#"{"data":[\#(c.rootFiles.joined(separator: ","))]}"#)
            let subs = c.subs.map { #"{"id":"\#($0.id)","attributes":{"name":"\#($0.name)"}}"# }.joined(separator: ",")
            routes["/jsonapi.php/v1/folders/\(c.root)/folders?page[limit]=200"] = ok(#"{"data":[\#(subs)]}"#)
            for s in c.subs {
                routes["/jsonapi.php/v1/folders/\(s.id)/file-refs?page[limit]=500"] = ok(#"{"data":[\#(s.files.joined(separator: ","))]}"#)
                routes["/jsonapi.php/v1/folders/\(s.id)/folders?page[limit]=200"] = ok(#"{"data":[]}"#)
            }
        }
        for id in ["fk1", "fv1", "fv2", "fu1", "fu2", "fl1", "fw1"] {
            routes["/jsonapi.php/v1/file-refs/\(id)/content"] = HTTPReply(status: 200, contentType: "application/pdf", body: body)
        }
        return FixtureTransport(routes)
    }

    /// Geraet mit lokalem Backend und Dateiablage im Temp-Ordner, Abgleich ueber `StudIPSync` wie in der App
    private func syncedDevice() async throws -> (api: APIClient, recorder: RecordingTransport, sync: StudIPSync, stud: FixtureTransport,
                                                 client: StudIPClient) {
        let d = try freshDevice()
        await d.sync.run(client: d.client)
        return d
    }

    /// Dasselbe Geraet vor dem ersten Abgleich (frisch installiert, Datenbank leer)
    private func freshDevice() throws -> (api: APIClient, recorder: RecordingTransport, sync: StudIPSync, stud: FixtureTransport,
                                          client: StudIPClient) {
        let c = try tempDir()
        let h = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                 clock: .fixed(berlin: "2026-10-25T14:30:05")!,
                                 files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let suite = "uniflow-s5-flow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let sync = StudIPSync(root: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true), host: h,
                              clock: .fixed(berlin: "2026-10-25T14:30:05")!, defaults: defaults,
                              support: c.appendingPathComponent("Library/Application Support/UniFlow", isDirectory: true))
        let stud = fullStudIP()
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: stud, pauseMillis: 0)
        let recorder = RecordingTransport(LocalTransport(host: h))
        return (APIClient(base: APIClient.localBase, transport: recorder), recorder, sync, stud, client)
    }

    /// Abnahme S3 + S4 + S5 in einem Ablauf ohne PC: Stud.IP-Abgleich (`StudIPSync.run`, feste erfundene Antworten)
    /// -> Dateien in Dokumente nach Fach und Lehrwoche -> Stundenplan mit Kurszeiten, Ausfall, Einzelterminen und
    /// eigenem Eintrag -> Unterlagen zum Termin (Endpunkte und Termin-Panel im Fenster) und naechster Termin im Modul.
    /// Ein zweiter Abgleich laedt und uebernimmt nichts doppelt.
    func testStudIPSyncFillsDocumentsTimetableAndEventMaterials() throws {
        let (api, recorder, sync, stud, client) = try awaiting { try await self.syncedDevice() }
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(stud.requested.filter { $0.hasSuffix("/content") }.count, 7)
        XCTAssertTrue(stud.requested.contains("/jsonapi.php/v1/users/u-flow/schedule"), "Stundenplan nach dem Datei-Abgleich")
        let summary = try XCTUnwrap(sync.lastSummary)
        XCTAssertTrue(summary.hasPrefix("7 neu/geändert"), summary)
        XCTAssertTrue(summary.contains("5 Stundenplan-Termine"), summary)
        XCTAssertFalse(summary.contains("nicht geladen"), summary)

        let series = try awaiting { () async throws -> Int in
            // 1. Dokumente & Notizen: ein Modul je Fach (Vorlesung und Uebung zusammen), Art und Lehrwoche je Datei
            let lib = try await api.value("/api/library")
            let mods = lib.list("modules")
            XCTAssertEqual(mods.compactMap { $0.s("name") }, ["Testmathematik I", "Testseminar Beispiel"])
            let ma = try XCTUnwrap(mods.first?.i("id"))
            let files = Dictionary(uniqueKeysWithValues: lib.list("files").compactMap { f in f.s("id").map { ($0, f) } })
            for id in ["fk1", "fv1", "fv2", "fu1", "fu2", "fl1"] { XCTAssertEqual(files[id]?.i("module_id"), ma, id) }
            XCTAssertEqual(files["fw1"]?["module_id"], .null, "Begrüßung ohne Modul")
            XCTAssertEqual(files["fv2"]?.s("doc_type"), "vorlesung")
            XCTAssertEqual(files["fu2"]?.s("doc_type"), "uebung")
            XCTAssertEqual(files["fl1"]?.s("doc_type"), "loesung")
            XCTAssertEqual(files["fk1"]?.s("sub_label"), "Altklausur")
            let detail = try await api.value("/api/modules/\(ma)")
            let weeks = detail.list("weeks")
            XCTAssertEqual(weeks.map { $0.s("label") ?? "" }, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
            XCTAssertEqual(weeks.first?.list("vorlesungen").compactMap { $0.s("id") }, ["fv1"])
            XCTAssertEqual(weeks.dropFirst().first?.list("uebungen").compactMap { $0.s("id") }, ["fu2"])

            // 2. Stundenplan aus Kurszeiten, Einzelterminen und eigenem Eintrag; die Termine gehoeren zum Modul ihres Fachs
            let events = try await api.value("/api/timetable/events").items
            XCTAssertEqual(events.count, 5, "\(events.map { $0.s("title") ?? "" })")
            XCTAssertTrue(events.allSatisfy { $0.s("source") == "studip" })
            let lecture = try XCTUnwrap(events.first { $0.s("course_id") == "c-ma" && $0.s("rrule") == "weekly" })
            XCTAssertEqual(lecture.i("module_id"), ma, "Modul schon beim ersten Abgleich")
            XCTAssertEqual(lecture.s("room"), "Hörsaal Test 1")
            XCTAssertEqual(events.first { $0.s("course_id") == "c-ma-ue" }?.i("module_id"), ma)
            XCTAssertEqual(events.first { $0.s("course_id") == "c-sem" }?.s("rrule"), "weekly", "drei Einzeltermine werden eine Serie")
            XCTAssertNotNil(events.first { $0.s("course_id") == "c-ma" && $0.s("rrule") == "once" && $0.s("date_from") == "2027-02-08" },
                            "Klausur außerhalb der Kurszeit")
            XCTAssertNil(events.first { $0.s("course_id") == "c-erst" }, "Begrüßung nicht im Stundenplan")
            let week = try await api.value("/api/timetable/week?start=2026-10-26")
            let days = week.list("days")
            func titles(_ d: Int) -> [String] { days[d].list("events").map { "\($0.s("title") ?? "") \($0.s("start") ?? "")" } }
            XCTAssertEqual(titles(0), ["Testmathematik I 10:00"])
            XCTAssertEqual(titles(1), ["Testseminar Beispiel 16:00"])
            XCTAssertEqual(titles(2), ["Übung zu Testmathematik I 14:00"])
            XCTAssertEqual(titles(6), ["Chorprobe 17:00"])
            XCTAssertEqual(days[0].list("events").first?.s("module_name"), "Testmathematik I")
            let next = try await api.value("/api/timetable/week?start=2026-11-02")
            XCTAssertEqual(next.list("days").first?.list("events").first?.s("status"), "ausfall", "Ausfall laut Stud.IP")

            // 3. Unterlagen zum Termin: die Lehrwoche der Dateien wie im Moduldetail (study.file_week: "Lösung Blatt 1",
            // in Woche 2 hochgeladen, gehoert zu Woche 1), sonst die neuesten des Moduls
            let id = try XCTUnwrap(lecture.i("id"))
            func materials(_ event: Int, _ date: String) async throws -> [String] {
                try await api.value("/api/timetable/event-materials/\(event)?date=\(date)").items.compactMap { $0.s("id") }
            }
            let mats1 = try await materials(id, "2026-10-12")
            XCTAssertEqual(mats1, ["fv1", "fu1", "fl1"], "Woche 1")
            let mats2 = try await materials(id, "2026-10-19")
            XCTAssertEqual(mats2, ["fv2", "fu2"], "Woche 2")
            let mats3 = try await materials(id, "2026-10-26")
            XCTAssertEqual(mats3, ["fv1", "fu1", "fv2", "fu2"], "Woche 3 ohne Dateien: die neuesten")
            let exercise = try XCTUnwrap(events.first { $0.s("course_id") == "c-ma-ue" }?.i("id"))
            let matsUe = try await materials(exercise, "2026-10-21")
            XCTAssertEqual(matsUe, ["fv2", "fu2"])
            let seminar = try XCTUnwrap(events.first { $0.s("course_id") == "c-sem" }?.i("id"))
            let matsSem = try await materials(seminar, "2026-10-20")
            XCTAssertEqual(matsSem, [], "Modul ohne Dateien")
            // Nicht-Teilnahme liefert dieselben Unterlagen fuer die freie Zeit
            let skip = try await api.value("/api/timetable/attendance", method: "POST",
                                           body: ["event_id": .number(Double(id)), "date": "2026-10-19", "mode": "today_skip"])
            XCTAssertEqual(skip.list("materials").compactMap { $0.s("id") }, ["fv2", "fu2"])
            _ = try await api.value("/api/timetable/attendance", method: "POST",
                                    body: ["event_id": .number(Double(id)), "date": "2026-10-19", "mode": "reset"])

            // 4. Meine Module: naechster Termin je Modul aus dem Stundenplan
            let list = try await api.value("/api/modules").items
            let card = try XCTUnwrap(list.first { $0.i("id") == ma })
            XCTAssertEqual(card["next_event"]?.s("date"), "2026-10-26")
            XCTAssertEqual(card["next_event"]?.s("title"), "Testmathematik I")
            XCTAssertEqual(list.first { $0.s("name") == "Testseminar Beispiel" }?["next_event"]?.s("date"), "2026-10-27")
            let log = try await api.value("/api/sync/status")["log"]?.array ?? []
            XCTAssertEqual(log.first?["message"], "7 neue/geaenderte Dateien, 5 Stundenplan-Termine")
            return id
        }

        // 5. Termin-Panel im Fenster (wie ein Tipp auf den Termin im Stundenplan): passende Unterlagen der Woche
        let names = ["VL02.pdf", "Blatt 2.pdf"]
        let shown = try render(EventDrawer(eventID: series, date: "2026-10-19"), api: api, recorder: recorder,
                               expected: ["Passende Unterlagen"] + names) { calls in
            calls.contains { $0.path.hasPrefix("/api/timetable/event-materials/") }
        }
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(all.contains("Passende Unterlagen"), all)
        for n in names { XCTAssertTrue(all.contains(n), "\(n) fehlt: \(all)") }
        XCTAssertFalse(all.contains("Keine passenden Unterlagen"), all)
        XCTAssertFalse(all.contains("VL01 Einführung.pdf"), "Woche 1 gehört nicht dazu: \(all)")
        XCTAssertFalse(all.contains("Lösung Blatt 1.pdf"), "Lehrwoche 1: \(all)")
        XCTAssertTrue(all.contains("Modul öffnen"), all)
        XCTAssertFalse(recorder.calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(recorder.calls)")

        // 6. Zweiter Abgleich: nichts doppelt geladen oder uebernommen, Zuordnung bleibt
        try awaiting { () async throws -> Void in
            let before = stud.requested.filter { $0.hasSuffix("/content") }.count
            await sync.run(client: client)
            XCTAssertEqual(sync.phase, .idle)
            XCTAssertEqual(stud.requested.filter { $0.hasSuffix("/content") }.count, before, "unverändert in Stud.IP: kein Download")
            let events = try await api.value("/api/timetable/events").items
            XCTAssertEqual(events.count, 5)
            let summary = try XCTUnwrap(sync.lastSummary)
            XCTAssertFalse(summary.contains("Stundenplan-Termine"), summary)
            let mats = try await api.value("/api/timetable/event-materials/\(series)?date=2026-10-19").items.compactMap { $0.s("id") }
            XCTAssertEqual(mats, ["fv2", "fu2"])
        }
    }

    /// Erste Verbindung bei offener Seite: Dokumente & Notizen und Stundenplan sind leer, der Abgleich fuellt die
    /// Datenbank, und die offene Seite laedt danach von selbst neu (ohne Seitenwechsel), wie nach einem Sync des PCs.
    /// Vorher blieb die Seite leer, bis man sie verliess und wieder oeffnete.
    func testOpenPageReloadsWhenStudIPSyncEnds() throws {
        let pages: [(name: String, view: AnyView, path: String, expected: [String])] = [
            ("Dokumente & Notizen", AnyView(LibraryPage(section: nil, path: nil, q: nil)), "/api/library",
             ["Testmathematik I", "Begrüßung der Testsemester"]),
            ("Stundenplan", AnyView(TimetableView(date: "2026-10-26")), "/api/timetable/week", ["Übung zu Testmathematik I", "Chorprobe"]),
        ]
        for page in pages {
            let (api, recorder, sync, _, client) = try freshDevice()
            func loads() -> Int { recorder.calls.filter { $0.path == page.path }.count }
            try hosted(page.view, api: api, studip: sync) { look in
                let before = look([], 10) { loads() >= 1 }.joined(separator: "\n")
                let initial = loads()
                XCTAssertGreaterThanOrEqual(initial, 1, page.name)
                for e in page.expected { XCTAssertFalse(before.contains(e), "\(page.name) vor dem Abgleich: \(before)") }

                Task { @MainActor in await sync.run(client: client) }
                let after = look(page.expected, 60) { sync.finishedRuns == 1 && loads() > initial }.joined(separator: "\n")
                XCTAssertEqual(sync.phase, .idle, "\(page.name): \(sync.phase)")
                XCTAssertEqual(sync.finishedRuns, 1)
                XCTAssertGreaterThan(loads(), initial, "\(page.name) lädt nach dem Abgleich neu")
                for e in page.expected { XCTAssertTrue(after.contains(e), "\(page.name): \(e) fehlt: \(after)") }
                XCTAssertFalse(recorder.calls.contains { $0.status >= 400 }, "keine Fehlerantwort: \(recorder.calls)")
            }
        }
    }
}

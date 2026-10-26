import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Externe Pruefpunkte 251–330 (docs/audit/RUNDE-09-10-251-330.md): veraltete Antworten, erhaltener Stand nach
/// einem gescheiterten Neuladen, Tageswechsel, sichtbare Fehler statt `try?`, Kopfzeile nach Konto- oder
/// Serverwechsel, Pruefungsentwuerfe je Container. Nur erfundene Daten, Temp-Ordner, kein Netz.
@MainActor
final class AuditRunde0910AppTests: XCTestCase {

    /// Weiche vor einem Transport: zaehlt Anfragen je Pfad, antwortet fest (`canned`, nacheinander mit `sequence`),
    /// laesst Pfade scheitern (`fail`, `failAll`) oder verzoegert die erste Anfrage eines Pfads (`delayFirst`)
    final class FakeTransport: APITransport, @unchecked Sendable {
        private let inner: APITransport?
        private let lock = NSLock()
        private var paths: [String] = []
        private var canned: [String: JSONValue] = [:]
        private var sequence: [String: [JSONValue]] = [:]
        private var fail: [String: Int] = [:]
        private var failAll: Int?
        private var delayFirst: [String: UInt64] = [:]

        init(_ inner: APITransport? = nil) { self.inner = inner }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let (delay, status, body): (UInt64?, Int?, JSONValue?) = lock.withLock {
                paths.append(path)
                let d = delayFirst.removeValue(forKey: path)
                var b = canned[path]
                if var seq = sequence[path], !seq.isEmpty { b = seq.removeFirst(); sequence[path] = seq }
                return (d, fail[path] ?? failAll, b)
            }
            if let delay { try await Task.sleep(nanoseconds: delay) }
            if let status {
                let data = Data("{\"detail\":\"Testfehler \(status)\"}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if let body {
                return (body.serialized(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            guard let inner else { throw URLError(.cannotConnectToHost) }
            return try await inner.send(request)
        }

        func count(_ path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func answers(_ path: String, _ v: [JSONValue]) { lock.withLock { sequence[path] = v } }
        func fail(_ path: String, _ status: Int?) { lock.withLock { fail[path] = status } }
        func failEverything(_ status: Int?) { lock.withLock { failAll = status } }
        func delayFirst(_ path: String, ms: UInt64) { lock.withLock { delayFirst[path] = ms * 1_000_000 } }
    }

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct MemoryUniversitySecrets: UniversitySecretStoring {
        final class Box: @unchecked Sendable { var values: [String: String] = [:] }
        let box = Box()
        func read(_ account: String) -> String? { box.values[account] }
        func write(_ value: String, account: String) -> Bool { box.values[account] = value; return true }
        func remove(_ account: String) { box.values[account] = nil }
        func accounts() -> [String] { Array(box.values.keys) }
        func removeAll() -> Bool { box.values = [:]; return true }
    }

    private struct AuthorizedChecker: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Lokales Backend mit einem Kurs und einer neuen Datei (fuer "Neu aus Stud.IP" mit Knopf "Gesehen")
    private func seededHost(now: String = "2026-10-26T07:30:00") async throws -> LocalBackendHost {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: now)!)
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-ma"), .text("Testmathematik I"), .text("WiSe 2026/27"), .text("Testmathematik I"), .text("vorlesung"), .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES (?,?,?,?,?, 'neu', 'pdf')",
                          [.text("f-v1"), .text("k-ma"), .text("VL01.pdf"), .text("Vorlesung"),
                           .integer(Int64(UniFlowClock.fixed(berlin: "2026-10-12T10:00:00")!.now.timeIntervalSince1970))])
        }
        return host
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

    // MARK: Bedienungshilfen (wie StudyPlanLocalAppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private struct Hosted {
        let view: UIView
        let toast: UFToastCenter
        let router: UFRouter
        let overlay: UFOverlay
    }

    private func show<V: View>(_ view: V, api: APIClient) throws -> Hosted {
        let overlay = UFOverlay(), router = UFRouter(), toast = UFToastCenter()
        let suite = "uniflow-audit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay))
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(router)
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(toast)
            .environmentObject(StudIPSync())
            .environmentObject(AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: AuthorizedChecker(), observeRevocation: false))
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return Hosted(view: hosting.view, toast: toast, router: router, overlay: overlay)
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

    /// Knopf mit dieser Beschriftung ausloesen; `exact: false` reicht, wenn ein Symbol davor steht (Auswahlpunkt)
    private func tap(_ label: String, in view: UIView, exact: Bool = true) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: 253, 254 – RemoteData

    /// 253: zwei Ladevorgaenge zugleich – die aeltere Antwort (hier die erste, verzoegerte) ueberschreibt nie die
    /// neuere; ebenso nach einem Pfadwechsel waehrend des Ladens
    func testStaleResponseNeverOverwritesNewerOne() async throws {
        let t = FakeTransport()
        t.answers("/api/dashboard", [["stand": "alt"], ["stand": "neu"]])
        t.delayFirst("/api/dashboard", ms: 300)
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let data = RemoteData(path: "/api/dashboard", api: api, cache: ResponseCache(root: try tempDir()))
        let slow = Task { await data.load() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await data.load()
        XCTAssertEqual(data.value?["stand"], "neu")
        await slow.value
        XCTAssertEqual(data.value?["stand"], "neu", "die verzoegerte erste Antwort darf die zweite nicht ersetzen")
        XCTAssertEqual(t.count("/api/dashboard"), 2)

        // Pfadwechsel waehrend des Ladens: die Antwort des alten Pfads landet nicht unter dem neuen
        t.answer("/api/calendar", ["woche": "A"])
        t.delayFirst("/api/calendar", ms: 300)
        t.answer("/api/calendar2", ["woche": "B"])
        let old = Task { await data.reload(path: "/api/calendar") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await data.reload(path: "/api/calendar2")
        await old.value
        XCTAssertEqual(data.value?["woche"], "B")
        XCTAssertEqual(data.path, "/api/calendar2")
    }

    /// 254: Neu laden scheitert, waehrend ein Stand da ist – er bleibt, dazu die Meldung; gelingt es wieder,
    /// verschwindet sie. Ohne Stand bleibt die Fehlerkarte.
    func testFailedReloadKeepsLastStateAndShowsReason() async throws {
        let t = FakeTransport()
        t.answer("/api/dashboard", ["stand": "eins"])
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let data = RemoteData(path: "/api/dashboard", api: api, cache: ResponseCache(root: try tempDir()))
        await data.load()
        XCTAssertEqual(data.value?["stand"], "eins")
        t.failEverything(500)
        await data.load()
        XCTAssertEqual(data.value?["stand"], "eins", "letzter Stand bleibt")
        XCTAssertEqual(data.reloadError, "Testfehler 500")
        t.failEverything(nil)
        await data.load()
        XCTAssertNil(data.reloadError)

        let fresh = RemoteData(path: "/api/dashboard", api: api, cache: ResponseCache(root: try tempDir()))
        t.failEverything(503)
        await fresh.load()
        if case .failed(let m) = fresh.state { XCTAssertEqual(m, "Testfehler 503") } else { XCTFail("ohne Stand: Fehlerkarte, \(fresh.state)") }
        XCTAssertNil(fresh.reloadError)
    }

    // MARK: 251, 254, 256 – Uebersicht

    /// 251: "Gesehen" scheitert -> Meldung mit Grund (vorher try?, nichts sichtbar). 256: Tageswechsel laedt die
    /// Uebersicht neu. 254: scheitert dieses Neuladen, bleibt der Inhalt stehen, darueber die Meldung.
    func testDashboardShowsMarkSeenFailureAndReloadsOnDayChange() throws {
        let host = try awaiting { try await self.seededHost() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let t = FakeTransport(LocalTransport(host: host))
        let api = APIClient(base: APIClient.localBase, transport: t)
        let page = try show(DashboardView(api: api), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Gesehen") }, texts(page.view).joined(separator: "\n"))

        t.fail("/api/files/mark-seen", 500)
        XCTAssertTrue(tap("Gesehen", in: page.view))
        XCTAssertTrue(pump { page.toast.message?.hasPrefix("Als gesehen markieren fehlgeschlagen") == true }, page.toast.message ?? "keine Meldung")
        XCTAssertTrue(page.toast.message?.contains("Testfehler 500") == true, page.toast.message ?? "")
        XCTAssertTrue(shows(page.view, "Gesehen"), "die Datei bleibt neu")

        // Mitternacht: neu laden ohne Neustart
        let before = t.count("/api/dashboard")
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertTrue(pump { t.count("/api/dashboard") > before }, "Tageswechsel laedt neu")

        // Neu laden scheitert: Inhalt bleibt, Meldung darueber
        t.fail("/api/dashboard", 500)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertTrue(pump { self.shows(page.view, "Neu laden fehlgeschlagen") }, texts(page.view).joined(separator: "\n"))
        XCTAssertTrue(shows(page.view, "Heute für dich geplant"), "letzter Stand bleibt sichtbar")
        XCTAssertFalse(shows(page.view, "Jetzt neu laden"), "keine Fehlerkarte anstelle des Inhalts")
    }

    // MARK: 279, 311, 312 – Stundenplan und Termin

    /// 279: scheitert der Konfliktabruf, steht das auf der Seite (vorher stille leere Liste = "keine Konflikte")
    func testTimetableSaysWhenConflictCheckFails() throws {
        let host = try awaiting { try await self.seededHost() }
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let t = FakeTransport(LocalTransport(host: host))
        t.fail("/api/timetable/conflicts", 500)
        let api = APIClient(base: APIClient.localBase, transport: t)
        let page = try show(TimetableView(date: "2026-10-26"), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Konfliktprüfung nicht möglich: Testfehler 500") }, texts(page.view).joined(separator: "\n"))
        XCTAssertTrue(shows(page.view, "Stundenplan"), "die Seite selbst ist da")
    }

    /// 311/312: "Termin nicht gefunden" (geloescht) und "Termin laden fehlgeschlagen" (Fehlerantwort) sind zwei
    /// Meldungen; Unterlagen, die sich nicht laden lassen, stehen als Meldung statt als "Keine passenden Unterlagen"
    func testEventDrawerDistinguishesMissingFromFailedAndShowsMaterialErrors() throws {
        let host = try awaiting { try await self.seededHost() }
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let t = FakeTransport(LocalTransport(host: host))
        let api = APIClient(base: APIClient.localBase, transport: t)
        let gone = try show(EventDrawer(eventID: 4711, date: "2026-10-26"), api: api)
        XCTAssertTrue(pump { gone.toast.message == "Termin nicht gefunden" }, gone.toast.message ?? "keine Meldung")

        t.fail("/api/timetable/events", 500)
        let failed = try show(EventDrawer(eventID: 4711, date: "2026-10-26"), api: api)
        XCTAssertTrue(pump { failed.toast.message?.hasPrefix("Termin laden fehlgeschlagen") == true }, failed.toast.message ?? "keine Meldung")
        t.fail("/api/timetable/events", nil)

        let created = try awaiting {
            try await api.value("/api/timetable/events", method: "POST",
                                body: ["title": "Testphysik", "kind": "vorlesung", "weekday": 0, "start_time": "10:00", "end_time": "11:30", "rrule": "weekly"])
        }
        let id = try XCTUnwrap(created.i("id"))
        t.fail("/api/timetable/event-materials/\(id)", 500)
        let drawer = try show(EventDrawer(eventID: id, date: "2026-10-26"), api: api)
        XCTAssertTrue(pump { self.shows(drawer.view, "Unterlagen ließen sich nicht laden: Testfehler 500") }, texts(drawer.view).joined(separator: "\n"))
        XCTAssertFalse(shows(drawer.view, "Keine passenden Unterlagen gefunden."))
    }

    // MARK: 306 – Lernpaket abschliessen

    /// 306: scheitert eine Aufgabe, bricht das Abschliessen dort ab und die Meldung nennt den Teilstand (vorher
    /// "Lernpaket erledigt" trotz halb geaendertem Paket)
    func testPackageToggleStopsAtFirstFailureAndSaysSo() async throws {
        let host = try await seededHost()
        let t = FakeTransport(LocalTransport(host: host))
        let api = APIClient(base: APIClient.localBase, transport: t)
        let p = try await api.value("/api/packages", method: "POST", body: ["date": "2026-10-26", "title": "Lernen", "tasks": [
            ["type": "frei", "title": "Eins", "est_minutes": 30], ["type": "frei", "title": "Zwei", "est_minutes": 30],
        ]])
        let pid = try XCTUnwrap(p.i("id"))
        let tasks = try await api.value("/api/packages/\(pid)").list("tasks").compactMap { $0.i("id") }
        XCTAssertEqual(tasks.count, 2)
        t.fail("/api/tasks/\(tasks[1])/status", 500)
        let toast = UFToastCenter(), router = UFRouter()
        await PlanActions(api: api, overlay: UFOverlay(), toast: toast, router: router).togglePackageDone(pid)
        XCTAssertEqual(toast.message, "1 von 2 Aufgaben geändert, dann fehlgeschlagen: Testfehler 500")
        let after = try await api.value("/api/packages/\(pid)").list("tasks").map { $0.s("status") ?? "" }
        XCTAssertEqual(after, ["erledigt", "geplant"], "der Teilstand ist genau der gemeldete")
        XCTAssertEqual(router.reloadToken, 1, "die Seite zeigt den echten Stand")

        t.fail("/api/tasks/\(tasks[1])/status", nil)
        await PlanActions(api: api, overlay: UFOverlay(), toast: toast, router: router).togglePackageDone(pid)
        XCTAssertEqual(toast.message, "Lernpaket erledigt ✓")
        let done = try await api.value("/api/packages/\(pid)").list("tasks").map { $0.s("status") ?? "" }
        XCTAssertEqual(done, ["erledigt", "erledigt"])
    }

    // MARK: 291–297 – Kopfzeile

    private func serverAPI(_ t: FakeTransport, host: String) -> APIClient {
        t.answer("/api/sync/status", ["log": []])
        t.answer("/api/bg", ["running": false, "task": .null, "message": ""])
        return APIClient(base: URL(string: "http://\(host).test/")!, transport: t)
    }

    private func waitUntil(_ cond: @escaping @MainActor () -> Bool, seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }

    /// 291/292/297: nach `attach` einer anderen Datenquelle sind Treffer und Initialen sofort weg, und die spaete
    /// Antwort der alten Quelle setzt weder Initialen noch Treffer
    func testHeaderDropsOldSourceOnAttach() async throws {
        let a = FakeTransport(), b = FakeTransport()
        a.answer("/api/settings", ["user_name": "Alt Anna"])
        a.delayFirst("/api/settings", ms: 400)
        a.answer("/api/search", ["modules": [["id": 1, "name": "Altmodul"]]])
        a.delayFirst("/api/search", ms: 400)
        b.answer("/api/settings", ["user_name": "Neu Nils"])
        b.answer("/api/search", ["modules": [["id": 2, "name": "Neumodul"]]])
        let shell = ShellState()
        shell.attach(serverAPI(a, host: "alt"))
        shell.search("modul")
        try await Task.sleep(nanoseconds: 300_000_000)                      // Entprellung vorbei, Antwort von A unterwegs
        XCTAssertEqual(shell.initials, "", "A hat noch nicht geantwortet")
        shell.attach(serverAPI(b, host: "neu"))
        XCTAssertEqual(shell.searchHits.map(\.title), [])
        XCTAssertEqual(shell.initials, "")
        let w1 = await waitUntil { shell.initials == "NN" }
        XCTAssertTrue(w1, shell.initials)
        try await Task.sleep(nanoseconds: 500_000_000)                      // A antwortet inzwischen
        XCTAssertEqual(shell.initials, "NN", "die spaete Antwort von A setzt keine Initialen")
        XCTAssertEqual(shell.searchHits.map(\.title), [], "die spaete Suche von A zeigt keine Treffer")
        shell.search("modul")
        let w2 = await waitUntil { shell.searchHits.map(\.title) == ["Neumodul"] }
        XCTAssertTrue(w2, "\(shell.searchHits.map(\.title))")
    }

    /// 296: scheitert die Suche, verschwinden die alten Treffer und die Meldung steht (vorher blieben sie stehen)
    func testSearchErrorClearsHitsAndIsVisible() async throws {
        let t = FakeTransport()
        t.answer("/api/settings", ["user_name": ""])
        t.answer("/api/search", ["modules": [["id": 1, "name": "Treffermodul"]]])
        let shell = ShellState()
        shell.attach(serverAPI(t, host: "suche"))
        shell.search("treffer")
        let w3 = await waitUntil { shell.searchHits.count == 1 }
        XCTAssertTrue(w3)
        t.fail("/api/search", 503)
        shell.search("treffer2")
        let w4 = await waitUntil { shell.searchError != nil }
        XCTAssertTrue(w4, "Meldung")
        XCTAssertEqual(shell.searchError, "Suche nicht möglich: Testfehler 503")
        XCTAssertEqual(shell.searchHits.count, 0)
        t.fail("/api/search", nil)
        shell.search("treffer3")
        let w5 = await waitUntil { shell.searchHits.count == 1 && shell.searchError == nil }
        XCTAssertTrue(w5)
    }

    /// 293/295: hoechstens eine Beobachtung je Aufgabe; scheitert /api/bg, endet sie mit sichtbarer Meldung
    func testBackgroundPollingIsSingleAndStopsVisibly() async throws {
        let t = FakeTransport()
        t.answer("/api/settings", ["user_name": ""])
        let api = serverAPI(t, host: "bg")
        let shell = ShellState()
        shell.api = api
        let toast = UFToastCenter()
        async let one: Void = shell.pollBackground(toast: toast)
        async let two: Void = shell.pollBackground(toast: toast)
        _ = await (one, two)
        XCTAssertEqual(t.count("/api/bg"), 1, "zwei Aufrufe, eine Schleife")

        t.fail("/api/bg", 500)
        await shell.pollBackground(toast: toast)
        XCTAssertEqual(shell.syncChip, "Status der Aufgabe nicht abrufbar")
        XCTAssertEqual(toast.message, "Status der Hintergrundaufgabe nicht abrufbar: Testfehler 500")
        XCTAssertFalse(shell.syncRunning)
    }

    // MARK: 261/263/270 – Pruefungsentwurf je Container

    /// Der Entwurf einer Pruefung liegt in den Einstellungen des aktiven Containers (Apple-Nutzer, Hochschule), nicht in
    /// UserDefaults.standard: ein anderes Konto auf demselben iPad sieht ihn nicht
    func testExamDraftLivesInContainerDefaults() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let base = try tempDir()
        let key = DataContainerKey(userID: "001234.erfunden-ada.\(UUID().uuidString.prefix(8))", university: .luh)
        let appSuite = "uniflow-audit-app-\(UUID().uuidString)"
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: appSuite) }
        let container = ActiveContainer(key: key, base: base, keychain: MemoryUniversitySecrets(), cookieService: "de.uniflow.ai.test.\(UUID().uuidString)",
                                        appDefaults: appDefaults, clock: .fixed(berlin: "2026-10-26T10:00:00")!, cloud: nil)
        let suite = container.defaultsSuite
        ActiveContainer.current = container
        addTeardownBlock { @MainActor in
            ActiveContainer.current = nil
            UserDefaults().removePersistentDomain(forName: suite)
        }

        let t = FakeTransport()
        t.answer("/api/tests/7", ["id": 7, "title": "Wochentest Testmathematik I – Lehrwoche 2", "subject": "Testmathematik I", "duration_min": 30,
                                  "started_at": "2026-10-26T10:00:00", "submitted_at": .null, "answers": [:], "feedback": .null,
                                  "questions": [["nr": 1, "type": "mc", "question": "Was ist 2 + 2?", "options": ["Vier", "Fünf"], "points": 1]]])
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let page = try show(ExamRunPage(id: 7, task: nil), api: api)
        XCTAssertTrue(pump { self.shows(page.view, "Was ist 2 + 2?") }, texts(page.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Vier", in: page.view, exact: false), texts(page.view).joined(separator: "\n"))
        let draftKey = "exam-draft:http://erfunden.test/:7"
        XCTAssertTrue(pump { container.defaults.dictionary(forKey: draftKey) as? [String: String] == ["1": "Vier"] })
        XCTAssertNil(UserDefaults.standard.object(forKey: draftKey), "nichts in den gemeinsamen UserDefaults")
        XCTAssertNil(appDefaults.object(forKey: draftKey))
    }

    /// 326: ein beschaedigter Zwischenspeicher gilt nicht als Stand – ohne Antwort bleibt die Fehlerkarte
    func testCorruptedCacheIsNotShownAsData() async throws {
        let root = try tempDir()
        let cache = ResponseCache(root: root)
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: FakeTransport())
        let key = api.base.absoluteString + "/api/dashboard"
        cache.store(["stand": "gut"], for: key)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("{\"stand\": kaputt".utf8).write(to: file)
        XCTAssertNil(cache.load(key))
        let data = RemoteData(path: "/api/dashboard", api: api, cache: cache)
        await data.load()                                                    // Transport ohne Antwort: Netzfehler
        if case .failed = data.state {} else { XCTFail("kein Stand aus dem beschaedigten Zwischenspeicher: \(data.state)") }
        XCTAssertTrue(data.failedOffline)
    }

    // MARK: Kleine Bausteine

    /// `attempt`: Fehler mit Grund sichtbar, Erfolg still
    func testAttemptShowsReasonAndReportsFailure() async {
        let toast = UFToastCenter()
        let ok = await toast.attempt("Ordner anlegen") {}
        XCTAssertTrue(ok)
        XCTAssertNil(toast.message)
        let failed = await toast.attempt("Ordner anlegen") { throw APIError(status: 500, message: "{\"detail\":\"Datenbank gesperrt\"}") }
        XCTAssertFalse(failed)
        XCTAssertEqual(toast.message, "Ordner anlegen fehlgeschlagen: Datenbank gesperrt")
    }

    /// 274: sitzungsweite Anzeigezustaende beginnen nach dem Wechsel der Datenquelle von vorn
    func testSessionStateResetsOnDataSourceSwitch() {
        PlanView.state = (view: "day", date: "2026-01-05", module: "7")
        TimetableView.ttDate = "2026-01-05"
        LibraryPage.sort = "name"
        LibraryPage.filter = "uebung"
        UFSessionState.reset()
        XCTAssertEqual(PlanView.state.view, "week")
        XCTAssertEqual(PlanView.state.module, "")
        XCTAssertEqual(PlanView.state.date, UFFmt.todayISO())
        XCTAssertEqual(TimetableView.ttDate, UFFmt.todayISO())
        XCTAssertEqual(LibraryPage.sort, "date")
        XCTAssertEqual(LibraryPage.filter, "all")
    }

    /// 288/285: die Bilanz nach dem Import nennt importierte, gescheiterte und nicht lesbare Dateien genau
    func testImportSummaryCountsSuccessAndFailure() {
        XCTAssertEqual(LibraryNewDialog.importSummary(ok: 3, failed: []), "3 Dateien importiert")
        XCTAssertEqual(LibraryNewDialog.importSummary(ok: 1, failed: []), "1 Datei importiert")
        XCTAssertEqual(LibraryNewDialog.importSummary(ok: 2, failed: ["b.pdf (Not Found)"]), "2 Dateien importiert · 1 fehlgeschlagen: b.pdf (Not Found)")
        XCTAssertEqual(LibraryNewDialog.importSummary(ok: 0, failed: ["a.pdf (x)"], unreadable: 2), "1 fehlgeschlagen: a.pdf (x) · 2 Fotos nicht lesbar")
        XCTAssertEqual(LibraryNewDialog.importSummary(ok: 0, failed: []), "Nichts importiert")
    }

    /// 286: das Bildformat kommt aus den Daten, nicht pauschal "JPEG"
    func testImageTypeComesFromData() {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        XCTAssertEqual(LibraryNewDialog.imageType(png)?.preferredMIMEType, "image/png")
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.8) { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        XCTAssertEqual(LibraryNewDialog.imageType(jpeg)?.preferredMIMEType, "image/jpeg")
        XCTAssertNil(LibraryNewDialog.imageType(Data("kein Bild".utf8)))
    }
}

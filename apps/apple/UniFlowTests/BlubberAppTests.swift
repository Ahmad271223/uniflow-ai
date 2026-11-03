import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Blubber aus Stud.IP (03.11.2026, `StudIPBlubber`): Zeile "Blubber" im Bereich "Aus Stud.IP" der Modulansicht, Leser
/// mit Rolle statt Name und "In Stud.IP öffnen", Zeile "Blubber in <Kurs>: N neue Beiträge" in den Neuigkeiten, Abgleich
/// mit festen erfundenen Antworten (nur GET, nie die Kurs-Route). Lokales Backend mit eingefrorener Uhr, kein Netz.
@MainActor
final class BlubberAppTests: XCTestCase {

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-02T10:30:00")!

    // Blubber ist im Betrieb aus (Entscheidung 03.11.2026); diese Tests pruefen den Code fuer spaeter
    override func setUp() { super.setUp(); StudIPBlubber.syncEnabled = true }
    override func tearDown() { StudIPBlubber.syncEnabled = false; super.tearDown() }

    /// Ausgeschaltet fragt der Abgleich Blubber gar nicht an (auch nicht die aufraeumende Liste)
    func testSwitchedOffNeverAsksForBlubber() throws {
        StudIPBlubber.syncEnabled = false
        let (_, _, _, fake) = try awaiting { try await self.synced() }
        XCTAssertFalse(fake.log.contains { $0.contains("blubber") }, "\(fake.log)")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-blubber-\(UUID().uuidString)", isDirectory: true)
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

    private final class Fake: StudIPTransport, @unchecked Sendable {
        let lock = NSLock()
        var log: [String] = []
        let routes: [String: HTTPReply]
        init(_ routes: [String: HTTPReply]) { self.routes = routes }
        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: "https://studip.uni-hannover.de", with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock(); log.append(key); lock.unlock()
            return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }
    }

    private static func api(_ s: String) -> HTTPReply { HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(s.utf8)) }

    private static let users = #"""
        {"type": "users", "id": "doz", "attributes": {"formatted-name": "Prof. Erika Mustermann", "permission": "dozent"}},
        {"type": "users", "id": "stu", "attributes": {"formatted-name": "Lena Beispiel", "permission": "autor"}}
        """#

    /// Liste und Kommentare wie Stud.IP sie liefert (erfunden): ein Thread im Kurs c-ana mit drei Beitraegen
    private static let routes: [String: HTTPReply] = [
        "/jsonapi.php/v1/blubber-threads?page[limit]=40&include=author": api(#"""
            {"data": [{"type": "blubber-threads", "id": "t-ana", "attributes": {"name": "Testanalysis I", "context-type": "course", "content": null,
               "latest-activity": "2026-11-02T09:30:00+01:00", "mkdate": "2026-10-12T08:00:00+02:00"},
              "relationships": {"context": {"data": {"type": "courses", "id": "c-ana"}}}},
              {"type": "blubber-threads", "id": "t-priv", "attributes": {"name": "Lena Beispiel", "context-type": "private", "content": "privat",
               "latest-activity": "2026-11-02T09:00:00+01:00"}, "relationships": {"context": {"data": null}}}],
             "included": [\#(users)]}
            """#),
        "/jsonapi.php/v1/blubber-threads/t-ana/comments?sort=-mkdate&page[limit]=20&include=author": api(#"""
            {"data": [
              {"type": "blubber-comments", "id": "k1", "attributes": {"content": "Die Übung am Mittwoch fällt aus, [Lena Beispiel]https://studip.uni-hannover.de/dispatch.php/profile?username=lbeispiel bitte weitersagen.", "mkdate": "2026-11-02T09:30:00+01:00"},
               "relationships": {"author": {"data": {"type": "users", "id": "doz"}}}},
              {"type": "blubber-comments", "id": "k2", "attributes": {"content": "Gibt es einen Ersatztermin?", "mkdate": "2026-11-01T20:15:00+01:00"},
               "relationships": {"author": {"data": {"type": "users", "id": "stu"}}}},
              {"type": "blubber-comments", "id": "k3", "attributes": {"content": "Ich frage nach.", "mkdate": "2026-11-01T19:00:00+01:00"},
               "relationships": {"author": {"data": {"type": "users", "id": "u1"}}}}],
             "included": [\#(users)]}
            """#),
    ]

    /// Container mit Modul und Kurs, danach der Abgleich der Ergaenzungen mit den festen Antworten
    private func synced() async throws -> (LocalBackendHost, APIClient, Int, Fake) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: Self.clock, university: .luh)
        let backend = try await host.backend()
        let mid = try await backend.context.database.transaction { c -> Int in
            try c.execute("INSERT INTO modules(name) VALUES ('Testanalysis')")
            let id = try c.scalar("SELECT last_insert_rowid()")?.int ?? 0
            try c.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-ana', 'Testanalysis I', ?, 1)", [.integer(Int64(id))])
            return id
        }
        let fake = Fake(Self.routes)
        let client = StudIPClient(base: StudIPSync.base, transport: fake, pauseMillis: 0)
        let expired = await StudIPExtrasSync(host: host).run(client: client, userID: "u1", courses: [StudIPCourse(id: "c-ana", title: "Testanalysis I")])
        XCTAssertFalse(expired)
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)), mid, fake)
    }

    // MARK: Bedienungshilfen (wie NewsCardAppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 700, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func pump(_ seconds: Double = 0.8) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
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

    private func labels(_ view: UIView) -> [String] {
        var seen = Set<String>()
        return elements(in: view).compactMap(\.accessibilityLabel).filter { seen.insert($0).inserted }
    }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) && (e.accessibilityLabel ?? "").hasPrefix(label) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func session(_ api: APIClient) throws -> Session {
        let suite = "uniflow-blubber-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Session(local: api, defaults: defaults)
    }

    // MARK: Tests

    /// Abgleich: nur GET auf die Liste und die Kommentare, nie die Kurs-Route (die in Stud.IP einen Thread anlegen kann),
    /// nie PATCH/visited-at; private Threads nicht gelesen; keine Namen in der Datenbank
    func testSyncReadsOnlyListAndCommentsWithoutNames() throws {
        let (host, api, mid, fake) = try awaiting { try await self.synced() }
        XCTAssertTrue(fake.log.contains("/jsonapi.php/v1/blubber-threads?page[limit]=40&include=author"), "\(fake.log)")
        XCTAssertTrue(fake.log.contains("/jsonapi.php/v1/blubber-threads/t-ana/comments?sort=-mkdate&page[limit]=20&include=author"), "\(fake.log)")
        XCTAssertFalse(fake.log.contains { $0.contains("courses/c-ana/blubber") || $0.contains("t-priv") }, "\(fake.log)")
        let dump = try awaiting {
            try await host.backend().context.database.withConnection { c in try c.rows("SELECT * FROM studip_blubber").map { "\($0)" }.joined() }
        }
        for name in ["Mustermann", "Beispiel", "Lena", "Erika", "lbeispiel"] { XCTAssertFalse(dump.contains(name), name) }
        let o = try awaiting { try await api.value("/api/studip/blubber?module=\(mid)") }
        XCTAssertEqual(o.list("threads").count, 1)
        XCTAssertEqual(o.list("threads").first?.i("new_count"), 2, "eigener Beitrag zaehlt nicht als neu")
        let t = try awaiting { try await api.value("/api/studip/blubber/t-ana") }
        XCTAssertEqual(t.list("comments").compactMap { $0.s("role") }, ["du", "Studierende", "Lehrende"], "aelteste zuerst")
        XCTAssertEqual(t.list("comments").last?.s("text"), "Die Übung am Mittwoch fällt aus, @… bitte weitersagen.")
    }

    /// Bereich "Aus Stud.IP": Zeile "Blubber · 1", aufgeklappt der Thread mit dem neuesten Beitrag und Rolle
    func testModuleCardShowsBlubberLine() throws {
        let (_, api, mid, _) = try awaiting { try await self.synced() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let view = host(StudIPTextsCard(moduleID: mid).environmentObject(try session(api)).environmentObject(UFOverlay()).environmentObject(UFRouter()).environmentObject(ShellState()).environmentObject(StudIPSync()).frame(width: 640).padding(20))
        pump()
        XCTAssertTrue(tap("Aus Stud.IP", in: view), "\(labels(view))")
        pump(0.5)
        var all = labels(view)
        XCTAssertTrue(all.contains { $0.hasPrefix("Blubber · 1 · geändert") }, "\(all)")
        XCTAssertTrue(tap("Blubber · 1", in: view), "\(all)")
        pump(0.5)
        all = labels(view)
        XCTAssertTrue(all.contains { $0.hasPrefix("Blubber: Lehrende: Die Übung am Mittwoch fällt aus") && $0.contains("Testanalysis I · 2 neu") }, "\(all)")
        XCTAssertFalse(all.contains { $0.contains("Mustermann") || $0.contains("Lena") }, "kein Personenname")
    }

    /// Leser: Beitraege der Reihe nach mit Rolle, Hinweis, "In Stud.IP öffnen"
    func testReaderShowsRolesAndOpenLink() throws {
        let (_, api, _, _) = try awaiting { try await self.synced() }
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let view = host(StudIPBlubberReader(id: "t-ana").environmentObject(try session(api)).frame(width: 640, height: 800))
        pump(1.0)
        let all = labels(view)
        XCTAssertTrue(all.contains { $0.hasPrefix("du · ") && $0.contains("Ich frage nach.") }, "\(all)")
        XCTAssertTrue(all.contains { $0.hasPrefix("Lehrende · ") && $0.contains("09:30") }, "\(all)")
        XCTAssertTrue(all.contains("In Stud.IP öffnen"), "\(all)")
        XCTAssertFalse(all.contains { $0.contains("Mustermann") || $0.contains("Lena") })
        XCTAssertEqual(StudIPBlubberReader.head(["role": "Tutor/in", "posted_at": "2026-11-02T09:30:00"]), "Tutor/in · Mo. 02.11. 09:30")
    }

    /// Neuigkeiten: /api/news hat die Zeile, die Karte zeigt sie mit eigener Art
    func testNewsFeedHasOneLinePerThread() throws {
        let (_, api, _, _) = try awaiting { try await self.synced() }
        let news = try awaiting { try await api.value("/api/news") }
        let lines = news.list("items").filter { $0.s("kind") == "blubber" }
        XCTAssertEqual(lines.compactMap { $0.s("title") }, ["Blubber in Testanalysis I: 2 neue Beiträge"])
        XCTAssertEqual(NewsRow.style("blubber").label, "Blubber")
        XCTAssertEqual(NewsAllList.filtered(news.list("items"), "blubber").count, 1)
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let view = host(NewsCard(items: lines, today: "2026-11-02") {}.frame(width: 420).padding(20))
        pump(0.5)
        XCTAssertTrue(labels(view).contains("Blubber: Blubber in Testanalysis I: 2 neue Beiträge · Testanalysis I · 09:30"), "\(labels(view))")
    }
}

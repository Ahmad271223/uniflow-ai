import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Schwarzes Brett aus Stud.IP (Auftrag des Inhabers 03.11.2026): Karte unter "Uni & Noten" nur mit Plugin und
/// Anzeigen, Themen-Chips mit Anzahl, Zeilen mit Titel, Thema, Tag und Vorschau, Zeile in der Karte "Neuigkeiten";
/// an der Uni Hildesheim nichts. Lokales Backend mit eingefrorener Uhr, nur erfundene Daten, kein Netz.
@MainActor
final class BulletinAppTests: XCTestCase {

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-02T10:30:00")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-bulletin-\(UUID().uuidString)", isDirectory: true)
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

    /// Drei Themen, zwoelf Anzeigen (Biete 5, Jobs an der Uni 3, Wohnliches 4), zwei davon aelter als sieben Tage
    private func seeded(_ uni: UniversityKey = .luh) async throws -> (LocalBackendHost, APIClient) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: Self.clock, university: uni)
        let backend = try await host.backend()
        var d = StudIPBulletin.Download()
        d.topics = [.init(id: "a", title: "Biete", count: 120), .init(id: "b", title: "Jobs an der Uni", count: 9), .init(id: "c", title: "Wohnliches", count: 40)]
        var entries: [StudIPBulletin.Entry] = []
        let plan: [(String, Int)] = [("Biete", 5), ("Jobs an der Uni", 3), ("Wohnliches", 4)]
        var n = 0
        for (topic, count) in plan {
            for i in 1...count {
                n += 1
                let day = n <= 10 ? "2026-11-0\(max(1, 3 - min(i, 2)))" : "2026-10-20"
                entries.append(.init(id: "sb-\(n)", topic: topic, title: n == 1 ? "Fahrrad zu verkaufen" : "\(topic) Anzeige \(i)",
                                     text: "Gut erhaltenes Rad, 28 Zoll. Nur Abholung in Hannover. Preis Verhandlungssache.",
                                     url: "https://studip.uni-hannover.de/plugins.php/schwarzesbrettplugin/article/view/\(n)",
                                     postedAt: "\(day)T09:\(String(format: "%02d", n)):00"))
            }
        }
        d.entries = entries
        try await backend.context.database.transaction { try StudIPBulletin.store(d, in: $0, clock: Self.clock) }
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
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
        let suite = "uniflow-bulletin-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Session(local: api, defaults: defaults)
    }

    // MARK: Tests

    /// Endpunkt: Themen in Stud.IP-Reihenfolge mit gespeicherter Anzahl, Anzeigen neueste zuerst, Filter, "neu"
    func testEndpointListsTopicsAndEntries() throws {
        let (_, api) = try awaiting { try await self.seeded() }
        let o = try awaiting { try await api.value("/api/studip/bulletin") }
        XCTAssertEqual(o["available"]?.bool, true)
        XCTAssertEqual(o.list("topics").map { $0.s("title") }, ["Biete", "Jobs an der Uni", "Wohnliches"])
        XCTAssertEqual(o.list("topics").map { $0.i("count") }, [5, 3, 4])
        XCTAssertEqual(o.list("topics").first?.i("total"), 120)
        XCTAssertEqual(o.list("entries").count, 12)
        XCTAssertEqual(o.i("new_count"), 10, "zwei Anzeigen sind aelter als sieben Tage")
        XCTAssertEqual(o.s("url"), "https://studip.uni-hannover.de/plugins.php/schwarzesbrettplugin/category/list")
        let jobs = try awaiting { try await api.value("/api/studip/bulletin?topic=Jobs%20an%20der%20Uni") }
        XCTAssertEqual(jobs.list("entries").count, 3)
        let one = try awaiting { try await api.value("/api/studip/bulletin/sb-1") }
        XCTAssertEqual(one.s("title"), "Fahrrad zu verkaufen")
        XCTAssertEqual(one.s("topic"), "Biete")
        XCTAssertNotNil(one.s("url").flatMap(UFDayExtras.safeURL))
    }

    /// Karte: Themen-Chips mit Anzahl, acht Zeilen, "Alle 12 anzeigen"; ein Chip filtert
    func testCardShowsChipsAndRowsAndFilters() throws {
        let (_, api) = try awaiting { try await self.seeded() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let view = host(BulletinCard().environmentObject(try session(api)).environmentObject(UFOverlay()).environmentObject(UFRouter()).environmentObject(ShellState()).environmentObject(StudIPSync()).frame(width: 640).padding(20))
        pump()
        var all = labels(view)
        XCTAssertTrue(all.contains("Alle 12"), "\(all)")
        XCTAssertTrue(all.contains("Biete 5"), "\(all)")
        XCTAssertTrue(all.contains("Jobs an der Uni 3"), "\(all)")
        XCTAssertTrue(all.contains("Wohnliches 4"), "\(all)")
        XCTAssertTrue(all.contains("Anzeige: Fahrrad zu verkaufen · Biete · Mo. 02.11."), "\(all)")
        XCTAssertEqual(all.filter { $0.hasPrefix("Anzeige:") }.count, BulletinText.shown, "zuerst nur acht Zeilen")
        XCTAssertTrue(all.contains("Alle 12 anzeigen"), "\(all)")
        XCTAssertFalse(all.contains { $0.contains("Mustermann") }, "kein Personenname")
        XCTAssertTrue(tap("Jobs an der Uni", in: view))
        pump(0.5)
        all = labels(view)
        XCTAssertEqual(all.filter { $0.hasPrefix("Anzeige:") }.count, 3, "\(all)")
        XCTAssertTrue(all.allSatisfy { !$0.hasPrefix("Anzeige:") || $0.contains("· Jobs an der Uni ·") }, "\(all)")
        XCTAssertFalse(all.contains("Alle 12 anzeigen"))
    }

    /// Karte "Neuigkeiten": eine Zeile "Schwarzes Brett: 10 neue Anzeigen", Antippen fuehrt zu Uni & Noten
    func testNewsCardShowsOneLineForNewAds() throws {
        XCTAssertEqual(BulletinText.newLine(1), "Schwarzes Brett: 1 neue Anzeige")
        XCTAssertEqual(BulletinText.newLine(10), "Schwarzes Brett: 10 neue Anzeigen")
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let item: JSONValue = ["id": "n1", "kind": "ankuendigung", "who": "Testmathematik", "title": "Vorlesung entfällt",
                               "at": "2026-11-02T09:00:00", "text": "", "chips": .array([]), "source": "studip"]
        var opened = 0
        let view = host(NewsCard(items: [item], today: "2026-11-02", bulletinNew: 10, openBulletin: { opened += 1 }) {}.frame(width: 420).padding(20))
        pump(0.5)
        let all = labels(view)
        XCTAssertTrue(all.contains("Schwarzes Brett: 10 neue Anzeigen"), "\(all)")
        XCTAssertTrue(tap("Schwarzes Brett:", in: view))
        XCTAssertEqual(opened, 1)
        // ohne neue Anzeigen keine Zeile
        let plain = host(NewsCard(items: [item], today: "2026-11-02") {}.frame(width: 420).padding(20))
        pump(0.3)
        XCTAssertFalse(labels(plain).contains { $0.hasPrefix("Schwarzes Brett") })
    }

    /// Inhaber 03.11.2026: "die ganze Nachricht aus Stud.IP im Schwarzen Brett, ohne '…'": der RSS-Text wird ganz
    /// gespeichert (ueber 1000 Zeichen, Absaetze bleiben), die Zeile zeigt ihn ganz (auch fuer VoiceOver), der Leser auch
    func testLongAdIsStoredAndShownCompletely() throws {
        let words = (1...200).map { "Wort\($0)" }.joined(separator: " ")
        let title = "WG-Zimmer in der Nordstadt ab Dezember, 18 m², möbliert, mit Balkon und Blick auf den Welfengarten"
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
        <item><title>\(title)</title><link>https://studip.uni-hannover.de/plugins.php/schwarzesbrettplugin/article/view/lang</link>
        <description><![CDATA[<p>Hallo zusammen,</p><p>\(words)</p><p>Meldet euch gern!</p>]]></description><pubDate>Mon, 02 Nov 2026 09:00:00 +0100</pubDate><guid isPermaLink="false">lang</guid></item>
        </channel></rss>
        """
        let full = "Hallo zusammen,\n\(words)\nMeldet euch gern!"
        let parsed = StudIPBulletin.parseFeed(xml: rss, topic: "Wohnliches")
        XCTAssertEqual(parsed.first?.text, full)
        XCTAssertGreaterThan(full.count, 1000)
        let (_, api): (LocalBackendHost, APIClient) = try awaiting {
            let host = LocalBackendHost(directory: try self.tempDir().appendingPathComponent("db", isDirectory: true), clock: Self.clock, university: .luh)
            let backend = try await host.backend()
            var d = StudIPBulletin.Download()
            d.topics = [.init(id: "c", title: "Wohnliches", count: 1)]
            d.entries = parsed
            try await backend.context.database.transaction { try StudIPBulletin.store(d, in: $0, clock: Self.clock) }
            return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
        }
        let one = try awaiting { try await api.value("/api/studip/bulletin/sb-lang") }
        XCTAssertEqual(one.s("text"), full, "ganz gespeichert")
        XCTAssertEqual(one.s("title"), title)
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let s = try session(api)
        let card = host(BulletinCard().environmentObject(s).environmentObject(UFOverlay()).environmentObject(UFRouter()).environmentObject(ShellState()).environmentObject(StudIPSync()).frame(width: 640).padding(20))
        pump()
        let row = try XCTUnwrap(elements(in: card).first { ($0.accessibilityLabel ?? "").hasPrefix("Anzeige: \(title) · ") }, "ganzer Titel")
        XCTAssertEqual(row.accessibilityValue, full, "ganzer Text in der Zeile")
        XCTAssertFalse(labels(card).contains { $0.contains("…") }, "\(labels(card))")
        let reader = host(BulletinReader(id: "sb-lang").environmentObject(s).environmentObject(UFOverlay()).environmentObject(UFRouter()).environmentObject(ShellState()).frame(width: 640))
        pump()
        let all = labels(reader)
        XCTAssertTrue(all.contains(full), "ganzer Text im Leser: \(all)")
        XCTAssertFalse(all.contains { $0.contains("…") || $0.contains("Gekürzt") }, "\(all)")
    }

    /// Uni Hildesheim: kein Brett, Endpunkt sagt es, die Karte bleibt weg
    func testHildesheimHasNoCard() throws {
        let (_, api) = try awaiting { try await self.seeded(.hildesheim) }
        let o = try awaiting { try await api.value("/api/studip/bulletin") }
        XCTAssertEqual(o["available"]?.bool, false)
        XCTAssertEqual(o.list("entries").count, 0)
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let view = host(BulletinCard().environmentObject(try session(api)).environmentObject(UFOverlay()).environmentObject(UFRouter()).environmentObject(ShellState()).environmentObject(StudIPSync()).frame(width: 640).padding(20))
        pump(0.5)
        XCTAssertFalse(labels(view).contains { $0.contains("Schwarzes Brett") || $0.hasPrefix("Anzeige:") })
    }

    /// Abgleich: an der LUH wird das Brett nach den Ergaenzungen gelesen (Themenliste und ein Feed je Thema, nur GET),
    /// in Hildesheim nie
    func testExtrasSyncReadsTheBoardOnlyWithPlugin() throws {
        let list = """
        <html><body><ul class="sb-categories"><li><a href="/plugins.php/schwarzesbrettplugin/category/view/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" class="category">Biete (2)</a></li></ul></body></html>
        """
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
        <item><title>Tisch</title><link>https://studip.uni-hannover.de/plugins.php/schwarzesbrettplugin/article/view/t1</link>
        <description><![CDATA[<p>Holz</p>]]></description><pubDate>Mon, 02 Nov 2026 09:00:00 +0100</pubDate><guid isPermaLink="false">t1</guid></item>
        </channel></rss>
        """
        final class Fake: StudIPTransport, @unchecked Sendable {
            let lock = NSLock()
            var log: [String] = []
            let routes: [String: HTTPReply]
            init(_ routes: [String: HTTPReply]) { self.routes = routes }
            func get(_ url: URL, accept: String?) async throws -> HTTPReply {
                let key = url.path
                lock.lock(); log.append(key); lock.unlock()
                return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data("{}".utf8))
            }
        }
        let fake = Fake(["/plugins.php/schwarzesbrettplugin/category/list": HTTPReply(status: 200, contentType: "text/html", body: Data(list.utf8)),
                         "/plugins.php/schwarzesbrettplugin/rss/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/20": HTTPReply(status: 200, contentType: "application/rss+xml", body: Data(rss.utf8))])
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: Self.clock, university: .luh)
        let client = StudIPClient(base: StudIPSync.base, transport: fake, pauseMillis: 0)
        let expired = try awaiting { await StudIPExtrasSync(host: host).run(client: client, userID: "u1") }
        XCTAssertFalse(expired)
        XCTAssertTrue(fake.log.contains("/plugins.php/schwarzesbrettplugin/category/list"), "\(fake.log)")
        XCTAssertTrue(fake.log.contains("/plugins.php/schwarzesbrettplugin/rss/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/20"), "\(fake.log)")
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let o = try awaiting { try await api.value("/api/studip/bulletin") }
        XCTAssertEqual(o.list("entries").map { $0.s("title") }, ["Tisch"])
        // gleich noch einmal: innerhalb von sechs Stunden keine Anfrage ans Brett
        let before = fake.log.count
        _ = try awaiting { await StudIPExtrasSync(host: host).run(client: client, userID: "u1") }
        XCTAssertFalse(fake.log.dropFirst(before).contains { $0.contains("schwarzesbrett") })

        let hild = LocalBackendHost(directory: try tempDir().appendingPathComponent("db2", isDirectory: true), clock: Self.clock, university: .hildesheim)
        let fake2 = Fake([:])
        _ = try awaiting { await StudIPExtrasSync(host: hild).run(client: StudIPClient(base: StudIPSync.base, transport: fake2, pauseMillis: 0), userID: "u1") }
        XCTAssertFalse(fake2.log.contains { $0.contains("schwarzesbrett") }, "\(fake2.log)")
    }
}

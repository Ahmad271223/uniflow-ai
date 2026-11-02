import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Karte "Neuigkeiten" auf der Uebersicht (Auftrag des Inhabers 02.11.2026): Ankuendigungen (Kurs und Stud.IP-weit),
/// Nachrichten und Aenderungen gebuendelt, die neuesten fuenf mit Symbol nach Art, Kurs/Absender, Betreff, Zeit und
/// Hinweis-Chips; "Alle anzeigen" mit Filter-Chips. Lokales Backend mit eingefrorener Uhr, nur erfundene Daten.
@MainActor
final class NewsCardAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-news-\(UUID().uuidString)", isDirectory: true)
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

    /// Kurs mit Ankuendigung, Stud.IP-weite Ankuendigung, zwei Nachrichten, Aenderungen an zwei Tagen: acht Zeilen
    private func seededAPI() async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-02T10:30:00")!)
        let backend = try await host.backend()
        let today = 20759                                             // 02.11.2026 als Tagesnummer (Fallback)
        let base = "https://studip.example"
        let inbox: JSONValue = ["data": [
            ["id": "m1", "type": "messages", "attributes": ["subject": "Tutorium entfällt",
                                                             "message": "<p>Das Tutorium am 12.11. fällt aus. Abgabe bis 19.11. um 12 Uhr.</p>",
                                                             "mkdate": "2026-11-02T08:15:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "u-doz"]]]],
            ["id": "m2", "type": "messages", "attributes": ["subject": "Ihre Bescheinigung", "message": "Text", "mkdate": "2026-10-30T12:00:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "____%system%____"]]]],
        ], "included": [["id": "u-doz", "type": "users", "attributes": ["formatted-name": "Prof. Erika Test", "permission": "dozent"]]]]
        let activity: JSONValue = ["data": [
            ["id": "a1", "type": "activities", "attributes": ["activity-type": "documents", "mkdate": "2026-11-02T07:00:00+01:00"],
             "relationships": ["context": ["data": ["type": "courses", "id": "k-vl"]]]],
            ["id": "a2", "type": "activities", "attributes": ["activity-type": "forum", "mkdate": "2026-10-31T07:00:00+01:00"],
             "relationships": ["context": ["data": ["type": "courses", "id": "k-vl"]]]],
        ]]
        var d = StudIPExtras.Download()
        d.globalNews = StudIPExtras.globalNews(.array([["id": "g1", "type": "news", "attributes": [
            "title": "Rückmeldung zum SoSe 2027", "content": "<p>Bitte bis zum 15.01.2027 zurückmelden (Frist).</p>",
            "publication-start": "2026-11-01T10:00:00+01:00"]]]), base: base, today: today)
        d.messages = StudIPExtras.parseMessages(inbox["data"], included: inbox["included"], base: base, today: today)
        d.activity = StudIPExtras.parseActivity(activity["data"], base: base)
        let course = Announcements.make(id: "sp-news-n1", source: "studip", courseID: "k-vl", title: "Vorlesung entfällt",
                                        bodyHTML: "<p>Die Vorlesung am 12.11. fällt aus.</p>", author: "",
                                        postedAt: "2026-11-02T09:00:00+01:00", url: "\(base)/course", today: today)
        let older = (1...2).map { i in
            Announcements.make(id: "sp-news-o\(i)", source: "studip", courseID: "k-vl", title: "Ältere Ankündigung \(i)", bodyHTML: "x",
                               author: "", postedAt: "2026-10-2\(i)T09:00:00+02:00", url: nil, today: today)
        }
        let clock = backend.context.clock
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('k-vl', 'Testmathematik', 'vorlesung', 1, 't')")
            _ = try Announcements.store(c, [course] + older, source: "studip", fetchedAt: "t", courseIDs: ["k-vl"])
            try StudIPExtras.store(d, in: c, clock: clock)
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    // MARK: Bedienungshilfen (wie AusfallMarkAppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 700, height: 1200)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func pump(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

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

    /// Beschriftungen ohne Doppelte (ein Element erscheint ueber Unteransicht und Bedienungshilfen-Baum zweimal)
    private func labels(_ view: UIView) -> [String] {
        var seen = Set<String>()
        return elements(in: view).compactMap(\.accessibilityLabel).filter { seen.insert($0).inserted }
    }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) && (e.accessibilityLabel ?? "").contains(label) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: Tests

    /// /api/news liefert alle drei Arten gebuendelt, neueste zuerst, mit Chips; Nachrichten mit Rolle statt Name
    func testNewsEndpointBundlesAllKinds() throws {
        let api = try awaiting { try await self.seededAPI() }
        let items = try awaiting { try await api.value("/api/news") }.list("items")
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items.prefix(3).map { $0.s("kind") }, ["ankuendigung", "nachricht", "aenderung"])
        XCTAssertEqual(items[1].s("who"), "Lehrende", "Rolle statt Name")
        XCTAssertEqual(items[1].list("chips").compactMap { $0.s("label") }, ["Ausfall? 12.11.", "Frist 19.11."])
        XCTAssertEqual(items[2].s("title"), "Neu: 1 Datei")
        XCTAssertTrue(items.contains { $0.s("who") == "Stud.IP-weit" && $0.list("chips").first?.s("label") == "Frist 15.01." })
        XCTAssertFalse(items.contains { ($0.s("who") ?? "").contains("Erika") }, "kein Personenname")
    }

    /// Karte: fuenf Zeilen mit Art, Betreff, Kurs/Absender, Zeit und Chips; "Alle anzeigen" oeffnet die Liste
    func testCardShowsFiveRowsWithKindsAndChips() throws {
        let api = try awaiting { try await self.seededAPI() }
        let items = try awaiting { try await api.value("/api/news") }.list("items")
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        var opened = 0
        let view = host(NewsCard(items: items, today: "2026-11-02") { opened += 1 }.frame(width: 420).padding(20))
        pump()
        let all = labels(view)
        let rows = all.filter { $0.hasPrefix("Ankündigung:") || $0.hasPrefix("Nachricht:") || $0.hasPrefix("Änderung:") }
        XCTAssertEqual(rows.count, 5, "neueste fünf: \(all)")
        XCTAssertTrue(all.contains("Ankündigung: Vorlesung entfällt · Testmathematik · 09:00 · Ausfall? 12.11."), "\(all)")
        XCTAssertTrue(all.contains("Nachricht: Tutorium entfällt · Lehrende · 08:15 · Ausfall? 12.11. · Frist 19.11."), "\(all)")
        XCTAssertTrue(all.contains("Änderung: Neu: 1 Datei · Testmathematik · 07:00"), "\(all)")
        XCTAssertTrue(all.contains { $0.hasPrefix("Ankündigung: Rückmeldung zum SoSe 2027 · Stud.IP-weit · gestern") }, "\(all)")
        XCTAssertTrue(tap("Alle anzeigen", in: view))
        XCTAssertEqual(opened, 1)
    }

    /// Liste "Alle anzeigen": Filter-Chips mit Anzahl, Filter nach Art, Hinweis zum Datenschutz der Nachrichten
    func testAllListFilters() throws {
        let api = try awaiting { try await self.seededAPI() }
        let items = try awaiting { try await api.value("/api/news") }.list("items")
        XCTAssertEqual(NewsAllList.filtered(items, "").count, 8)
        XCTAssertEqual(NewsAllList.filtered(items, "ankuendigung").count, 4)
        XCTAssertEqual(NewsAllList.filtered(items, "nachricht").count, 2)
        XCTAssertEqual(NewsAllList.filtered(items, "aenderung").count, 2)
        XCTAssertTrue(Self.accessibilityAutomation(true))
        defer { Self.accessibilityAutomation(false) }
        let view = host(NewsAllList(items: items, today: "2026-11-02") {}.frame(width: 600))
        pump()
        var all = labels(view)
        for chip in ["Alle", "Ankündigungen 4", "Nachrichten 2", "Änderungen 2"] { XCTAssertTrue(all.contains(chip), "\(chip) fehlt: \(all)") }
        XCTAssertTrue(all.contains { $0.contains("nur auf diesem Gerät") })
        XCTAssertTrue(tap("Nachrichten 2", in: view))
        pump()
        all = labels(view)
        let rows = all.filter { $0.hasPrefix("Ankündigung:") || $0.hasPrefix("Nachricht:") || $0.hasPrefix("Änderung:") }
        XCTAssertEqual(rows.count, 2, "\(all)")
        XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("Nachricht:") })
    }

    func testTimeLabels() {
        XCTAssertEqual(NewsRow.time("2026-11-02T08:15:00+01:00", today: "2026-11-02"), "08:15")
        XCTAssertEqual(NewsRow.time("2026-11-01T10:00:00+01:00", today: "2026-11-02"), "gestern")
        XCTAssertEqual(NewsRow.time("2026-10-31T10:00:00+01:00", today: "2026-11-01"), "gestern", "ueber den Monatswechsel")
        XCTAssertEqual(NewsRow.time("", today: "2026-11-02"), "")
    }
}

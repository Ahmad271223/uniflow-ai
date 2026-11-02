import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Ausfall am Termin im Planer (Wunsch des Inhabers 02.11.2026): eine Stud.IP-Ankuendigung "Die Vorlesung am 12.11.
/// faellt aus" markiert die Vorlesung des Moduls am 12.11. mit Warnzeichen und "Ausfall?" samt Quelle; die Uebung
/// desselben Tages bleibt unmarkiert. Bestaetigen ueber die vorhandene Ausnahme (cancelled) macht daraus "fällt aus",
/// verwerfen (today_attend) nimmt die Markierung weg. Lokales Backend mit eingefrorener Uhr, nur erfundene Daten.
@MainActor
final class AusfallMarkAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ausfall-\(UUID().uuidString)", isDirectory: true)
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

    /// Modul mit Vorlesung (Do 10:15) und Uebung (Do 14:15), Ankuendigung im Vorlesungskurs
    private func seededAPI() async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-02T09:30:00")!)
        let backend = try await host.backend()
        let news = Announcements.make(id: "sp-news-ax1", source: "studip", courseID: "k-vl", title: "Hinweis zur Vorlesung",
                                      bodyHTML: "<p>Die Vorlesung am 12.11. fällt aus, die Übung findet statt.</p>", author: "",
                                      postedAt: "2026-11-02T09:00:00+01:00", url: "https://studip.example/news/1", today: 0)
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testmathematik', '#4f5bd5', 0, '2026-10-01T08:00:00')")
            let mid = try XCTUnwrap(c.rows("SELECT id FROM modules WHERE name='Testmathematik'").first?["id"]?.int)
            for (id, title, kind) in [("k-vl", "Testmathematik", "vorlesung"), ("k-ue", "Übung Testmathematik", "uebung")] {
                try c.execute("INSERT INTO courses(id, title, semester, kind, active, module_id, created_at) VALUES (?,?,?,?,1,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(kind), .integer(Int64(mid)), .text("2026-10-01T08:00:00")])
            }
            for (course, title, kind, start, end) in [("k-vl", "Testmathematik", "vorlesung", "10:15", "11:45"),
                                                      ("k-ue", "Übung Testmathematik", "uebung", "14:15", "15:45")] {
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                    VALUES (?,?,?,?,3,?,?,'weekly',1,'manual','2026-10-01T08:00:00')
                    """, [.integer(Int64(mid)), .text(course), .text(title), .text(kind), .text(start), .text(end)])
            }
            _ = try Announcements.store(c, [news], source: "studip", fetchedAt: "2026-11-02T09:00:00")
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func events(_ api: APIClient, _ day: String = "2026-11-12") async throws -> [String: JSONValue] {
        let d = try await api.value("/api/timetable/day?date=\(day)")
        return Dictionary(d.list("events").map { ($0.s("kind") ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Bedienungshilfen (wie AuditRunde0910AppTests)

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 900, height: 900)
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

    private func labels(_ view: UIView) -> [String] { elements(in: view).compactMap(\.accessibilityLabel) }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) && (e.accessibilityLabel ?? "").contains(label) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: Tests

    /// Die Antwort des Kerns traegt den Hinweis nur an der Vorlesung; die Anzeige-Regeln lesen ihn als "Ausfall?" mit Quelle
    func testAnnouncementMarksOnlyTheLectureAsUnsure() throws {
        let api = try awaiting { try await self.seededAPI() }
        let ev = try awaiting { try await self.events(api) }
        let vl = try XCTUnwrap(ev["vorlesung"]), ue = try XCTUnwrap(ev["uebung"])
        XCTAssertEqual(vl.s("status"), "teilnahme", "ein Text ist keine verlaessliche Absage: der Termin bleibt")
        XCTAssertEqual(UFCancel.label(vl), "Ausfall?")
        XCTAssertTrue(UFCancel.unsure(vl))
        XCTAssertEqual(UFCancel.source(vl), "Stud.IP-Ankündigung „Hinweis zur Vorlesung“ · Testmathematik")
        XCTAssertNil(UFCancel.label(ue), "die Uebung findet laut Nachricht statt")
        // andere Woche: kein Hinweis
        let next = try awaiting { try await self.events(api, "2026-11-19") }
        XCTAssertNil(UFCancel.label(try XCTUnwrap(next["vorlesung"])))
    }

    /// Stundenplan-Kasten, Lernkalender-Kasten und Hinweiskasten zeigen das Warnzeichen mit Text; "Fällt aus" im
    /// Kasten bestaetigt ueber /api/timetable/attendance (cancelled), danach "fällt aus"; "Findet statt" nimmt es weg
    func testBlocksShowWarningAndUserDecides() throws {
        let api = try awaiting { try await self.seededAPI() }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let vl = try XCTUnwrap(try awaiting { try await self.events(api) }["vorlesung"])
        let eventID = try XCTUnwrap(vl.i("event_id"))
        var decided: [String] = []
        let view = host(VStack(alignment: .leading, spacing: 20) {
            ZStack(alignment: .topLeading) { TimetableEventBlock(e: vl, width: 160, px: { CGFloat($0 - 600) }) {} }.frame(width: 160, height: 160)
            ZStack(alignment: .topLeading) {
                PlanEventBlock(e: vl, lane: PlanLane(), W: 200, px: { CGFloat($0 - 600) }, compact: false) {}
            }.frame(width: 200, height: 160)
            UFCancelHintBox(e: vl) { decided.append($0) }.frame(width: 420)
        }.padding(20))
        pump()
        let all = labels(view)
        XCTAssertGreaterThanOrEqual(all.filter { $0.contains("Möglicher Ausfall") }.count, 3, "Warnzeichen fehlt: \(all)")
        XCTAssertTrue(all.contains { $0.contains("laut Stud.IP-Ankündigung „Hinweis zur Vorlesung“") }, "Quelle fehlt: \(all)")
        XCTAssertTrue(all.contains { $0.contains("Die Vorlesung am 12.11. fällt aus") }, "Satz der Ankündigung fehlt: \(all)")
        XCTAssertTrue(tap("Fällt aus", in: view), "Knopf \"Fällt aus\" fehlt: \(all)")
        XCTAssertTrue(tap("Findet statt", in: view))
        XCTAssertEqual(decided, ["cancelled", "today_attend"])

        // Entscheidung ueber die vorhandene Mechanik (event_exceptions)
        _ = try awaiting { try await api.value("/api/timetable/attendance", method: "POST",
                                                body: ["event_id": .number(Double(eventID)), "date": "2026-11-12", "mode": "cancelled"]) }
        let confirmed = try XCTUnwrap(try awaiting { try await self.events(api) }["vorlesung"])
        XCTAssertEqual(confirmed.s("status"), "ausfall")
        XCTAssertEqual(UFCancel.label(confirmed), "fällt aus")
        XCTAssertFalse(UFCancel.unsure(confirmed))
        XCTAssertEqual(UFCancel.source(confirmed), UFCancel.source(vl), "Quelle bleibt sichtbar")
        let sure = host(ZStack(alignment: .topLeading) { TimetableEventBlock(e: confirmed, width: 160, px: { CGFloat($0 - 600) }) {} }
                        .frame(width: 160, height: 160))
        pump()
        XCTAssertTrue(labels(sure).contains { $0.contains("Fällt aus") }, "\(labels(sure))")

        _ = try awaiting { try await api.value("/api/timetable/attendance", method: "POST",
                                                body: ["event_id": .number(Double(eventID)), "date": "2026-11-12", "mode": "today_attend"]) }
        let dismissed = try XCTUnwrap(try awaiting { try await self.events(api) }["vorlesung"])
        XCTAssertEqual(dismissed.s("status"), "teilnahme")
        XCTAssertNil(UFCancel.label(dismissed), "verworfen: keine Markierung mehr")
    }

    /// Vorlesungsfreie Zeit zeigt der Tag gruen, kein Warnzeichen am Termin; eingetragene Ausfaelle ohne Ankuendigung
    /// tragen "fällt aus"
    func testLabelRules() {
        XCTAssertNil(UFCancel.label(["status": "ausfall", "exception": "vorlesungsfrei"]))
        XCTAssertEqual(UFCancel.label(["status": "ausfall", "exception": "cancelled"]), "fällt aus")
        XCTAssertNil(UFCancel.label(["status": "teilnahme", "exception": .null]))
        XCTAssertNil(UFCancel.label(["status": "teilnahme", "cancel_hint": .null]))
        XCTAssertEqual(UFCancel.helpText(["status": "teilnahme", "cancel_hint": ["title": "Ausfall", "source": "learnweb"]]),
                       "Ausfall? laut Learnweb-Ankündigung „Ausfall“")
    }
}

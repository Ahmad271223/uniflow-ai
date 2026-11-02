import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Stud.IP im Planer (Entscheidung des Inhabers 02.11.2026): ein in Stud.IP abgesagter Einzeltermin bleibt als
/// bestaetigter Ausfall ("fällt aus", Quelle Stud.IP) sichtbar, das Sitzungsthema steht dezent am Termin (eine Zeile,
/// aufklappbar), Dateien "Link/Webadresse" oeffnen nur http(s). Lokales Backend mit eingefrorener Uhr, erfundene Daten.
@MainActor
final class StudIPSessionAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-session-\(UUID().uuidString)", isDirectory: true)
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

    /// Kurs mit Einzelterminen am 10.11. (Thema) und 17.11. (in Stud.IP abgesagt), ohne Serie
    private func seededAPI() async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-02T09:30:00")!)
        let backend = try await host.backend()
        let long = "Kapitel 3: Grenzwerte von Folgen und Reihen, Konvergenzkriterien, Beispiele aus der Elektrotechnik\nmit Übungsteil"
        try await backend.context.database.transaction { c in
            try c.execute("""
                INSERT INTO courses(id, title, semester, kind, active, created_at) VALUES ('k-ana', 'Testanalysis', 'WiSe 2026/27', 'vorlesung', 1, '2026-10-01T08:00:00')
                """)
            for (id, day, topic, cancelled) in [("e-1", "2026-11-10", long, 0), ("e-2", "2026-11-17", "Exkursion", 1)] {
                try c.execute("""
                    INSERT INTO studip_events(id, course_id, title, start, end, room, description, cancelled, fetched_at) VALUES (?,?,?,?,?,?,?,?,?)
                    """, [.text(id), "k-ana", "Sitzung", .text("\(day)T10:00:00"), .text("\(day)T11:30:00"), "Hörsaal Test", .text(topic),
                          .integer(Int64(cancelled)), "2026-11-02T09:00:00"])
            }
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func event(_ api: APIClient, _ day: String) async throws -> JSONValue {
        let d = try await api.value("/api/timetable/day?date=\(day)")
        return try XCTUnwrap(d.list("events").first { $0.s("course_id") == "k-ana" })
    }

    func testCancelledDateIsConfirmedAndFree() throws {
        let api = try awaiting { try await self.seededAPI() }
        let e = try awaiting { try await self.event(api, "2026-11-17") }
        XCTAssertEqual(e.s("status"), "ausfall")
        XCTAssertEqual(UFCancel.label(e), "fällt aus")
        XCTAssertFalse(UFCancel.unsure(e), "bestaetigt: keine Entscheidung noetig")
        XCTAssertEqual(UFCancel.source(e), "Stud.IP (Termin abgesagt)")
        XCTAssertEqual(UFCancel.helpText(e), "fällt aus laut Stud.IP (Termin abgesagt)")
        XCTAssertTrue(DatedEventDialog.text("2026-11-17", cancelled: true).contains("die Zeit ist frei"))
        // die Zeit ist frei: der Tag hat keinen belegten Block fuer den Termin
        let day = try awaiting { try await api.value("/api/timetable/day?date=2026-11-17") }
        XCTAssertTrue(day.list("free").contains { ($0.i("start") ?? 9999) <= 600 && ($0.i("end") ?? 0) >= 690 }, "\(day.list("free"))")
        // Ankuendigungs-Hinweise bleiben wie bisher ("Ausfall?" mit Quelle der Ankuendigung)
        let news: JSONValue = ["status": "teilnahme", "cancel_hint": ["source": "studip", "title": "Hinweis", "course_title": "Testanalysis"]]
        XCTAssertEqual(UFCancel.source(news), "Stud.IP-Ankündigung „Hinweis“ · Testanalysis")
    }

    func testSessionTopicShowsOneLineAndExpands() throws {
        let api = try awaiting { try await self.seededAPI() }
        let e = try awaiting { try await self.event(api, "2026-11-10") }
        let topic = try XCTUnwrap(UFSessionTopic.text(e))
        XCTAssertTrue(topic.hasPrefix("Kapitel 3: Grenzwerte"))
        XCTAssertTrue(UFSessionTopic.isLong(topic))
        XCTAssertFalse(UFSessionTopic.isLong("Sensoren"))
        XCTAssertNil(UFSessionTopic.text(["session_topic": "  "]))
        XCTAssertNil(UFSessionTopic.text(["title": "ohne Thema"]))
        // gerendert: ein Eintrag mit dem Thema als Bedienungshilfe
        let hosting = UIHostingController(rootView: UFSessionTopic(e: e).frame(width: 400))
        hosting.view.frame = CGRect(x: 0, y: 0, width: 400, height: 80)
        hosting.view.layoutIfNeeded()
        XCTAssertGreaterThan(hosting.sizeThatFits(in: CGSize(width: 400, height: 400)).height, 0)
    }

    func testLinkTargetsOnlyWeb() {
        func link(_ url: String) -> StudIPLibrary.FileLink {
            StudIPLibrary.FileLink(id: "l", courseID: "c", courseTitle: "K", folder: "", name: "Link", url: url)
        }
        XCTAssertEqual(StudIPView.linkTarget(link("https://video.uni-hannover.de/v/1"))?.host, "video.uni-hannover.de")
        XCTAssertNotNil(StudIPView.linkTarget(link("http://example.org")))
        XCTAssertNil(StudIPView.linkTarget(link("javascript:alert(1)")))
        XCTAssertNil(StudIPView.linkTarget(link("file:///etc/hosts")))
    }
}

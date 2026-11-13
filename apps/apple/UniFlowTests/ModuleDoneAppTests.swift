import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Moduldetail (Auftrag des Inhabers 13.11.2026): Wochen starten zugeklappt, Haken je Datei ganz rechts, "Woche
/// erledigt" im Wochenkopf mit Fortschritt "n/m erledigt", zweiter Tipp nimmt alle Haken weg. Gleicher Stand wie die
/// Lernpakete. Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder
/// hell/dunkel. Nur erfundene Daten.
@MainActor
final class ModuleDoneAppTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-done-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func pumping<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(30)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    /// Ein Modul mit drei Lehrwochen (Learnweb-Abschnitte): Woche 1 mit zwei, Woche 2 mit drei, Woche 3 mit einer Datei;
    /// heutiges Lernpaket mit einer Aufgabe zur ersten Datei aus Woche 2
    private func api() throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-13T10:00:00")!)
        try pumping {
            let backend = try await host.backend()
            try await backend.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Einführung in die Informatik', '#175ee8', 0)")
                try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-101', 'Einführung in die Informatik', 'Einführung in die Informatik', 'vorlesung', 'WiSe 2026/27', 1, 1, 't')")
                let lw: [(String, String, String)] = [
                    ("f1", "Folien Einführung.pdf", "Woche 1"), ("f2", "Übungsblatt 1.pdf", "Woche 1"),
                    ("f3", "Folien Zahlensysteme.pdf", "Woche 2"), ("f4", "Übungsblatt 2.pdf", "Woche 2"), ("f5", "Lösung Blatt 1.pdf", "Woche 2"),
                    ("f6", "Folien Rekursion.pdf", "Woche 3")]
                for (id, name, _) in lw {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status) VALUES (?,?,?,?,?, 'gelesen')",
                                  [.text(id), .text("lw-101"), .text(name), .integer(1_760_000_000), .text("2026-10-12T09:00:00")])
                }
                try LectureWeeks.assignCourse(c, courseID: "lw-101", semester: "WiSe 2026/27", university: "hildesheim",
                                              files: lw.map { LectureWeeks.Input(id: $0.0, name: $0.1, section: $0.2) }, now: "2026-10-12T09:00:00")
                try c.execute("INSERT INTO study_packages(id, date, module_id, title, status, created_at) VALUES (1, '2026-11-13', 1, 'Informatik', 'geplant', 't')")
                try c.execute("INSERT INTO study_tasks(id, package_id, type, file_id, title, status) VALUES (1, 1, 'vorlesung', 'f3', 'Folien Zahlensysteme', 'geplant')")
            }
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func module(_ api: APIClient, size: CGSize = CGSize(width: 1180, height: 1100)) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(ModulePage(id: 1), api: api, size: size)
        env.router.go(.module(1))
        return env
    }

    private func status(_ api: APIClient) throws -> [String: String] {
        let d = try pumping { try await api.value("/api/modules/1") }
        return Dictionary(uniqueKeysWithValues: d.list("files").compactMap { f in f.s("id").map { ($0, f.s("status") ?? "") } })
    }

    private func taskStatus(_ api: APIClient) throws -> String? {
        let d = try pumping { try await api.value("/api/packages/1") }
        return d.list("tasks").first?.s("status")
    }

    func testWeeksStartCollapsedAndOpenOnTap() throws {
        let api = try api()
        let env = try module(api)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Woche 1") } }, env.labels().joined(separator: "\n"))
        XCTAssertFalse(env.labels().contains { $0.hasPrefix("Erledigt: ") }, "keine Datei sichtbar, alle Wochen zu")
        XCTAssertTrue(env.labels().contains("Woche erledigt"), "Knopf im Wochenkopf auch zugeklappt")
        XCTAssertEqual(env.openWeeks(), 3)
        XCTAssertTrue(env.labels().contains("Erledigt: Folien Einführung.pdf"), env.labels().joined(separator: "\n"))
        // beim Neuladen bleiben die Wochen offen
        env.router.reload()
        env.pump(1)
        XCTAssertTrue(env.labels().contains("Erledigt: Folien Rekursion.pdf"))
    }

    func testTickFileAndWholeWeek() throws {
        let api = try api()
        let env = try module(api)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Woche 2") } })
        env.openWeeks()
        // Haken an einer Datei: gleicher Stand wie das Lernpaket (Aufgabe erledigt)
        XCTAssertTrue(env.activate("Erledigt: Folien Zahlensysteme.pdf"))
        XCTAssertTrue(env.wait { (try? self.status(api)["f3"]) == "erledigt" })
        XCTAssertTrue(env.wait { env.labels().contains("1/3 erledigt") }, env.labels().joined(separator: "\n"))
        XCTAssertEqual(try taskStatus(api), "erledigt")
        // Haken wieder weg
        XCTAssertTrue(env.activate("Erledigt: Folien Zahlensysteme.pdf"))
        XCTAssertTrue(env.wait { (try? self.status(api)["f3"]) == "gelesen" })
        XCTAssertEqual(try taskStatus(api), "geplant")
        // "Woche erledigt" (erste Woche): beide Dateien abgehakt, zweiter Tipp nimmt alle Haken weg
        XCTAssertTrue(env.wait { !env.labels().contains("1/3 erledigt") })
        XCTAssertTrue(env.activate("Woche erledigt"))
        XCTAssertTrue(env.wait { (try? self.status(api)).map { $0["f1"] == "erledigt" && $0["f2"] == "erledigt" } == true })
        XCTAssertEqual(try status(api)["f3"], "gelesen", "andere Wochen bleiben")
        XCTAssertTrue(env.wait { env.labels().contains("2/2 erledigt") }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.activate("Woche erledigt"))
        XCTAssertTrue(env.wait { (try? self.status(api)).map { $0["f1"] == "gelesen" && $0["f2"] == "gelesen" } == true })
    }

    // MARK: Bilder

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let api = try api()
        _ = try pumping { try await api.value("/api/modules/1/done", method: "POST", body: ["file_ids": ["f1", "f2"], "done": true]) }
        _ = try pumping { try await api.value("/api/modules/1/done", method: "POST", body: ["file_ids": ["f3"], "done": true]) }
        let env = try module(api, size: CGSize(width: 1180, height: 900))
        _ = env.wait { env.labels().contains { $0.hasPrefix("Woche 3") } }
        shoot(env, "erledigt-01-wochen-zugeklappt", to: dir)
        _ = env.activate(env.labels().first { $0.hasPrefix("Woche 2") } ?? "")
        env.pump(0.6)
        shoot(env, "erledigt-02-woche-offen-mit-haken", to: dir)
    }

    private func png(_ view: UIView) -> Data {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, to dir: URL) {
        env.pump(1.0)
        for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.8)
            let file = dir.appendingPathComponent("\(name)-\(tone).png")
            do { try png(env.view).write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
        }
        env.window.overrideUserInterfaceStyle = .unspecified
    }
}

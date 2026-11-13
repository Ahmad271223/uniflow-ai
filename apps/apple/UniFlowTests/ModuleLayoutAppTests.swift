import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Eigene Wochen im Moduldetail (Auftrag 12.11.2026): "Nicht zugeordnet" mit Vorschlaegen, Vorschlaege uebernehmen,
/// eigener Abschnitt mit Menue, Ablage per Ziehen (Ziel), LUH-Sammelupload. Mit UF_SCREENSHOT_DIR (xcodebuild:
/// TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder hell/dunkel. Nur erfundene Daten.
@MainActor
final class ModuleLayoutAppTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-layout-\(UUID().uuidString)", isDirectory: true)
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

    /// Learnweb-Kurs (Hildesheim, Modul 1): drei Dateien mit Wochen-Abschnitt, zwei ohne Hinweis; LUH-Kurs (Modul 2) mit
    /// Sammelupload am 13.10.
    private func api() throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-12T10:00:00")!)
        try pumping {
            let backend = try await host.backend()
            try await backend.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Einführung in die Informatik', '#175ee8', 0), (2, 'Lineare Algebra', '#16a34a', 1)")
                try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-101', 'Einführung in die Informatik', 'Einführung in die Informatik', 'vorlesung', 'WiSe 2026/27', 1, 1, 't')")
                try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('sp-1', 'Lineare Algebra', 'Lineare Algebra', 'vorlesung', 'WiSe 2026/27', 1, 2, 't')")
                let lw: [(String, String, String)] = [("lw-f1", "Folien Einführung.pdf", "Woche 1"), ("lw-f2", "Folien Zahlensysteme.pdf", "Woche 2"),
                                                      ("lw-f3", "Übungsblatt Rekursion.pdf", "Woche 3"), ("lw-f4", "03 Rekursion.pdf", "Material"),
                                                      ("lw-f5", "Zusatzmaterial.pdf", "Material")]
                for (id, name, _) in lw {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate, first_seen) VALUES (?,?,?,?,?)",
                                  [.text(id), .text("lw-101"), .text(name), .integer(1_760_000_000), .text("2026-10-12T09:00:00")])
                }
                try LectureWeeks.assignCourse(c, courseID: "lw-101", semester: "WiSe 2026/27", university: "hildesheim",
                                              files: lw.map { LectureWeeks.Input(id: $0.0, name: $0.1, section: $0.2) }, now: "2026-10-12T09:00:00")
                try c.executeScript("CREATE TABLE IF NOT EXISTS page_texts (file_id TEXT, page INTEGER, text TEXT, chdate REAL)")
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('lw-f5', 1, 'Informatik I – Vorlesung 2: Zahlensysteme', 1760000000)")
                for (i, n) in ["Einführung", "Vektorräume", "Basis", "Lineare Abbildungen", "Matrizen", "Determinanten"].enumerated() {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)",
                                  [.text("la-\(i + 1)"), .text("sp-1"), .text("LA \(n).pdf"), .integer(Int64(1_791_878_400 + 60 * i))])
                }
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('la-3', 1, 'Lineare Algebra I\nVorlesung 3 – Basis und Dimension', 0)")
            }
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func module(_ api: APIClient, _ id: Int, size: CGSize = CGSize(width: 1180, height: 1400)) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(ModulePage(id: id), api: api, size: size)
        env.router.go(.module(id))
        return env
    }

    func testUnassignedWithSuggestionsAndAccept() throws {
        let api = try api()
        let env = try module(api, 1)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Nicht zugeordnet") } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Vorschläge übernehmen (2)"), env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Vorschlag: Woche 3 · 02.11. – 08.11.") || env.labels().contains { $0.hasPrefix("Vorschlag: Woche 3") },
                      env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Abschnitt hinzufügen"))
        XCTAssertTrue(env.labels().contains { $0.hasPrefix("Abschnitt Woche 1") && $0.hasSuffix("bearbeiten") }, env.labels().joined(separator: "\n"))
        // uebernehmen ueber die Schnittstelle der Seite, danach ist "Nicht zugeordnet" leer und verschwindet
        _ = try pumping { try await api.value("/api/modules/1/suggestions/accept", method: "POST", body: [:]) }
        env.router.reload()
        XCTAssertTrue(env.wait { !env.labels().contains { $0.hasPrefix("Nicht zugeordnet") } }, env.labels().joined(separator: "\n"))
    }

    func testOwnSectionShowsWithMenuAndEmptyHint() throws {
        let api = try api()
        let r = try pumping { try await api.value("/api/modules/1/sections", method: "POST", body: ["title": "Kapitel Graphen", "after": "w:2"]) }
        XCTAssertEqual(r.s("key")?.hasPrefix("s:"), true)
        let env = try module(api, 1)
        XCTAssertTrue(env.wait { env.labels().contains("Abschnitt Kapitel Graphen bearbeiten") }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains { $0.hasPrefix("Noch leer") }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains { $0.contains("Mehr zur Ordnung") }, "Zuruecksetzen erst mit eigener Ordnung")
    }

    func testStudIPBulkUploadUnassigned() throws {
        let api = try api()
        let env = try module(api, 2)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Nicht zugeordnet") } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Vorschläge übernehmen (1)"), env.labels().joined(separator: "\n"))
    }

    // MARK: Bilder

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let api = try api()
        let env = try module(api, 1, size: CGSize(width: 1180, height: 1500))
        _ = env.wait { env.labels().contains { $0.hasPrefix("Nicht zugeordnet") } }
        shoot(env, "wochen-01-hildesheim-nicht-zugeordnet", to: dir)
        _ = try pumping { try await api.value("/api/modules/1/suggestions/accept", method: "POST", body: [:]) }
        _ = try pumping { try await api.value("/api/modules/1/sections", method: "POST", body: ["title": "Kapitel Rekursion", "after": "w:3"]) }
        _ = try pumping { try await api.value("/api/modules/1/sections/rename", method: "POST", body: ["key": "w:1", "title": "Woche 1 – Einstieg"]) }
        env.router.reload()
        _ = env.wait { env.labels().contains("Abschnitt Kapitel Rekursion bearbeiten") }
        shoot(env, "wochen-02-hildesheim-eigene-ordnung", to: dir)
        let la = try module(api, 2, size: CGSize(width: 1180, height: 1300))
        _ = la.wait { la.labels().contains { $0.hasPrefix("Nicht zugeordnet") } }
        shoot(la, "wochen-03-luh-sammelupload", to: dir)
        let dialog = try hostWithEnvironment(ModuleSectionNameDialog(moduleID: 1, mode: .create(after: "w:3")), api: api,
                                             size: CGSize(width: 700, height: 420))
        dialog.pump(1.0)
        shoot(dialog, "wochen-04-abschnitt-anlegen", to: dir)
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

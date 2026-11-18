import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Block "Klausuren & Altklausuren" im Moduldetail (Wunsch des Inhabers 17.11.2026): nach Jahrgang, neuester zuerst,
/// jede Klausur mit ihrer Loesung direkt darunter, Sammel-Loesung am Ende des Jahrgangs. Ausgedachte Dateien nach dem
/// Muster des echten Kurses (Kursart Uebung, Ordner je Jahrgang). Mit UF_SCREENSHOT_DIR (xcodebuild:
/// TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder hell/dunkel, iPad und iPhone-Breite.
@MainActor
final class ModuleExamGroupsAppTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-exams-\(UUID().uuidString)", isDirectory: true)
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

    /// (ID, Name, Ordner)
    private let files: [(String, String, String)] = [
        ("a1", "KK1.pdf", "Alte Klausuren/WS 22/23"), ("a1s", "KK1loes.pdf", "Alte Klausuren/WS 22/23"),
        ("a2", "KK2.pdf", "Alte Klausuren/WS 22/23"), ("a2s", "KK2loes.pdf", "Alte Klausuren/WS 22/23"),
        ("a10", "KK10.pdf", "Alte Klausuren/WS 22/23"),
        ("b0", "kk0b.pdf", "Alte Klausuren/WS 23/24"), ("b0s", "sol0b.pdf", "Alte Klausuren/WS 23/24"),
        ("b1", "kk1b.pdf", "Alte Klausuren/WS 23/24"), ("b1s", "sol1b.pdf", "Alte Klausuren/WS 23/24"),
        // andere Namen als in WS 22/23: `labels()` nennt jede Beschriftung nur einmal
        ("c1", "KK3.pdf", "Alte Klausuren/WS 20/21"), ("c2", "KK4.pdf", "Alte Klausuren/WS 20/21"),
        ("cs", "Lösungen.pdf", "Alte Klausuren/WS 20/21"),
        ("u1", "Blatt 3.pdf", "Übungen"), ("u1s", "Lösung Blatt 3.pdf", "Übungen"),
    ]

    private func api() throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-17T10:00:00")!)
        let files = files
        try pumping {
            let backend = try await host.backend()
            try await backend.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Testmathematik I', '#175ee8', 0)")
                try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('k2', 'Übung zu Testmathematik I', 'Testmathematik I', 'uebung', 'WiSe 2026/27', 1, 1, 't')")
                for (id, name, folder) in files {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status, studip_folder) VALUES (?, 'k2', ?, ?, ?, 'gelesen', ?)",
                                  [.text(id), .text(name), .integer(folder == "Übungen" ? 1_793_000_000 : 1_676_000_000),
                                   .text("2026-10-12T09:00:00"), .text(folder)])
                }
            }
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func module(_ api: APIClient, size: CGSize = CGSize(width: 1180, height: 1400)) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(ModulePage(id: 1), api: api, size: size)
        env.router.go(.module(1))
        return env
    }

    func testExamBlockShowsEachExamWithItsSolutionByTerm() throws {
        let env = try module(try api())
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Klausuren & Altklausuren") } }, env.labels().joined(separator: "\n"))
        env.openWeeks()
        let labels = env.labels()
        func at(_ prefix: String) -> Int { labels.firstIndex { $0.hasPrefix(prefix) } ?? -1 }
        // Jahrgaenge: neuester zuerst, mit Zahlen
        let terms = ["WS 23/24 · 2 Klausuren, 2 Lösungen", "WS 22/23 · 3 Klausuren, 2 Lösungen", "WS 20/21 · 2 Klausuren, 1 Lösung"]
        for t in terms { XCTAssertGreaterThanOrEqual(at(t), 0, "\(t) fehlt\n" + labels.joined(separator: "\n")) }
        XCTAssertEqual(terms.map(at), terms.map(at).sorted())
        // jede Klausur, direkt danach ihre Loesung (Zeilen des Blocks in der Reihenfolge der Seite)
        let rows = labels.filter { $0.hasPrefix("Erledigt: ") }.map { String($0.dropFirst("Erledigt: ".count)) }
        // die laufende Woche steht oben, der Block "Klausuren & Altklausuren" ganz unten
        let other = Array(rows.prefix(2)), block = Array(rows.dropFirst(2))
        XCTAssertEqual(other, ["Blatt 3.pdf", "Lösung Blatt 3.pdf"], "die anderen Wochen bleiben nach Art")
        XCTAssertEqual(block, ["kk0b.pdf", "sol0b.pdf", "kk1b.pdf", "sol1b.pdf",
                               "KK1.pdf", "KK1loes.pdf", "KK2.pdf", "KK2loes.pdf", "KK10.pdf",
                               "KK3.pdf", "KK4.pdf", "Lösungen.pdf"], labels.joined(separator: "\n"))
        XCTAssertTrue(labels.contains("Übung") && labels.contains("Lösung"), "Gruppen nach Art in der normalen Woche")
        XCTAssertFalse(labels.contains { $0.hasPrefix("Klausur-Lösung") || $0.hasPrefix("Altklausur") },
                       "im Block keine Gruppen nach Art mehr")
    }

    // MARK: Bilder

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, size) in [("ipad", CGSize(width: 1180, height: 1700)), ("schmal", CGSize(width: 402, height: 2300))] {
            let env = try module(try api(), size: size)
            _ = env.wait { env.labels().contains { $0.hasPrefix("Klausuren & Altklausuren") } }
            env.openWeeks()
            shoot(env, "klausuren-nach-jahrgang-\(name)", to: dir)
        }
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

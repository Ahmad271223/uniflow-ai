import SwiftUI
import UIKit
import XCTest
@testable import UniFlow
@testable import UniFlowCore

/// "Neu" nur 24 Stunden (Auftrag des Inhabers 17.11.2026: "wenn etwas laenger als 24 Std in der App ist, automatisch
/// nicht mehr neu"). Der Kern rechnet (`LocalLibrary.newFileSQL`, Feld `is_new` je Datei), die App zeigt und zaehlt
/// nur danach: `UFNewFiles`, die Marke "Neu" in den Dateizeilen des Moduls und am Termin, Bereich und Zaehler der
/// Bibliothek. Der Lernstand ("neu" | "gelesen" | "erledigt") entscheidet darueber nicht mehr.
@MainActor
final class Neu24StundenAppTests: XCTestCase {
    private let now = "2026-11-17T13:20:05"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neu24-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Lokales Backend, Uhr 17.11.2026 13:20:05: ein Kurs mit vier nie als gelesen markierten Dateien - 23 Stunden alt,
    /// 25 Stunden alt, 23 Stunden alt aber geoeffnet, ohne Eintragezeit. Die Dateiliste des Kurses wurde am 1.10. zum
    /// ersten Mal eingelesen (`first_listed_at`): alles hier kam danach dazu.
    private func seededHost() async throws -> LocalBackendHost {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: now)!)
        let backend = try await host.backend()
        let chdate = Int64(UniFlowClock.fixed(berlin: "2026-11-10T10:00:00")!.now.timeIntervalSince1970)
        try await backend.context.database.transaction { c in
            try c.execute("""
                INSERT INTO courses(id, title, semester, subject, kind, created_at, first_listed_at)
                VALUES ('k-ma','Testmathematik I','WiSe 2026/27','Testmathematik I','vorlesung','2026-10-01T08:00:00','2026-10-01T08:00:00')
                """)
            let files: [(String, String, String?, Int)] = [
                ("f-jung", "Frischblatt.pdf", "2026-11-16T14:20:05", 0), ("f-alt", "Altblatt.pdf", "2026-11-16T12:20:05", 0),
                ("f-offen", "Offenblatt.pdf", "2026-11-16T14:20:05", 1), ("f-ohne", "Ohnezeitblatt.pdf", nil, 0),
            ]
            for (id, name, seen, opened) in files {
                try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, first_seen, status, seen_by_user, kind) VALUES (?,?,?,?,?,?, 'neu', ?, 'pdf')",
                              [.text(id), .text("k-ma"), .text(name), .text("Vorlesung"), .integer(chdate), seen.map(SQLiteValue.text) ?? .null, .integer(Int64(opened))])
            }
        }
        return host
    }

    /// Asynchrones von einem synchronen Test aus (gehostete Ansichten brauchen die laufende Hauptschleife)
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

    private func api(_ host: LocalBackendHost) -> APIClient { APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)) }

    // MARK: UFNewFiles

    func testIsNewFolgtDemFeldDesKerns() {
        // `is_new` entscheidet, egal was Lernstand und "gesehen" sagen
        XCTAssertTrue(UFNewFiles.isNew(["is_new": 1, "seen_by_user": 0, "status": "gelesen"]))
        XCTAssertFalse(UFNewFiles.isNew(["is_new": 0, "seen_by_user": 0, "status": "neu"]), "aelter als 24 Stunden: nicht mehr neu, auch nie geoeffnet")
        XCTAssertTrue(UFNewFiles.isNew(["is_new": true]))
        XCTAssertFalse(UFNewFiles.isNew(["is_new": false, "status": "neu"]))
        // aelterer eigener PC-Server ohne `is_new`: die alte Regel
        XCTAssertTrue(UFNewFiles.isNew(["seen_by_user": 0, "status": "gelesen"]))
        XCTAssertFalse(UFNewFiles.isNew(["seen_by_user": 1, "status": "neu"]))
        XCTAssertTrue(UFNewFiles.isNew(["is_new": .null, "seen_by_user": 0]))
        XCTAssertTrue(UFNewFiles.isNew(["status": "neu"]))
        XCTAssertFalse(UFNewFiles.isNew(["status": "gelesen"]))
        XCTAssertEqual(UFNewFiles.count([["is_new": 1], ["is_new": 0, "seen_by_user": 0], ["is_new": 0, "status": "neu"], ["is_new": 1]]), 2)
    }

    // MARK: Dateizeilen

    private func rowLabels<V: View>(_ row: V) throws -> [String] {
        let env = try hostWithEnvironment(row.frame(width: 700), size: CGSize(width: 800, height: 300))
        env.pump(0.4)
        let labels = env.labels()
        env.window.isHidden = true
        return labels
    }

    func testModulzeileZeigtNeuNurMitIsNew() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { _ = HostedEnvironment.accessibilityAutomation(false) }
        func file(_ status: String, _ new: JSONValue?) -> JSONValue {
            var f: [String: JSONValue] = ["id": "f1", "name": "Blatt Sieben.pdf", "status": .string(status), "doc_type": "uebung", "sub_label": "Übung",
                                          "chdate": 1_794_000_000]
            if let new { f["is_new"] = new }
            return .object(f)
        }
        let fresh = try rowLabels(UFDocRow(f: file("gelesen", 1)) {})
        XCTAssertTrue(fresh.contains { $0.contains("Blatt Sieben.pdf") && $0.contains("Neu") }, fresh.joined(separator: " | "))
        let old = try rowLabels(UFDocRow(f: file("neu", 0)) {})
        XCTAssertTrue(old.contains { $0.contains("Blatt Sieben.pdf") }, old.joined(separator: " | "))
        XCTAssertFalse(old.contains { $0.contains("Neu") }, "Lernstand \"neu\", aber aelter als 24 Stunden: " + old.joined(separator: " | "))
        let done = try rowLabels(UFDocRow(f: file("erledigt", 0)) {})
        XCTAssertFalse(done.contains { $0.contains("Neu") }, done.joined(separator: " | "))
        // aelterer PC-Server ohne is_new: wie bisher der Lernstand
        let legacy = try rowLabels(UFDocRow(f: file("neu", nil)) {})
        XCTAssertTrue(legacy.contains { $0.contains("Neu") }, legacy.joined(separator: " | "))
    }

    func testTerminzeileZeigtNeuNurMitIsNew() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { _ = HostedEnvironment.accessibilityAutomation(false) }
        func file(_ status: String, _ new: JSONValue?) -> JSONValue {
            var f: [String: JSONValue] = ["id": "f1", "name": "Folien Acht.pdf", "status": .string(status), "doc_type": "vorlesung"]
            if let new { f["is_new"] = new }
            return .object(f)
        }
        let fresh = try rowLabels(UFEventDocRow(f: file("gelesen", 1)) {})
        XCTAssertTrue(fresh.contains { $0.contains("Folien Acht.pdf") && $0.contains("Neu") }, fresh.joined(separator: " | "))
        let old = try rowLabels(UFEventDocRow(f: file("neu", 0)) {})
        XCTAssertTrue(old.contains { $0.contains("Folien Acht.pdf") }, old.joined(separator: " | "))
        XCTAssertFalse(old.contains { $0.contains("Neu") }, "Lernstand \"neu\", aber aelter als 24 Stunden: " + old.joined(separator: " | "))
        let legacy = try rowLabels(UFEventDocRow(f: file("neu", nil)) {})
        XCTAssertTrue(legacy.contains { $0.contains("Neu") }, legacy.joined(separator: " | "))
    }

    // MARK: ueber das lokale Backend: alle Stellen gleich

    func testAlleStellenZaehlenDasselbe() async throws {
        let api = api(try await seededHost())
        let dash = try await api.value("/api/dashboard")
        XCTAssertEqual(dash.i("new_total"), 1)
        XCTAssertEqual(dash.list("new_files").compactMap { $0.s("id") }, ["f-jung"])
        let card = try XCTUnwrap(dash.list("modules").first)
        XCTAssertEqual(card.i("new_count"), 1, "Modulkarte: \"1 neue Inhalte\"")
        // Bibliothek: Zaehler und Bereich "Neu"
        let lib = try await api.value("/api/library")
        XCTAssertEqual(lib.list("files").count, 4)
        XCTAssertEqual(UFNewFiles.count(lib.list("files")), 1)
        XCTAssertEqual(lib.list("files").filter(UFNewFiles.isNew).compactMap { $0.s("id") }, ["f-jung"])
        // Moduldetail: Dateizeilen
        let detail = try await api.value("/api/modules/\(try XCTUnwrap(card.i("id")))")
        XCTAssertEqual(detail.i("new_count"), 1)
        XCTAssertEqual(detail.list("files").count, 4)
        XCTAssertEqual(detail.list("files").filter(UFNewFiles.isNew).compactMap { $0.s("id") }, ["f-jung"])
        XCTAssertTrue(detail.list("files").allSatisfy { $0.s("status") == "neu" }, "der Lernstand bleibt, wie er ist")
        // Kurse
        let courses = try await api.value("/api/courses")
        XCTAssertEqual(courses.items.first { $0.s("id") == "k-ma" }?.i("new_count"), 1)
    }

    func testBibliothekBereichNeuZeigtNurDieFrischeDatei() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { _ = HostedEnvironment.accessibilityAutomation(false) }
        let saved = UserDefaults.standard.string(forKey: "lib-mode")
        defer { UserDefaults.standard.set(saved, forKey: "lib-mode") }
        UserDefaults.standard.set("list", forKey: "lib-mode")
        let api = api(try awaiting { try await self.seededHost() })
        let env = try hostWithEnvironment(LibraryPage(section: "new", path: nil, q: nil), api: api)
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("Frischblatt") } }, env.labels().joined(separator: " | "))
        let labels = env.labels()
        for old in ["Altblatt", "Offenblatt", "Ohnezeitblatt"] {
            XCTAssertFalse(labels.contains { $0.contains(old) }, "\(old) ist nicht mehr neu: " + labels.joined(separator: " | "))
        }
        env.window.isHidden = true
    }
}

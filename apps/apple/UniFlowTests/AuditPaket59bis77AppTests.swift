import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Audit 09.11.2026, Pakete 59, 60, 61, 70, 71, 76, 77 (Speichern, Offline, Wiederherstellung), Bericht
/// docs/audit/AUDIT-2026-11-09-PAKET-59-61-70-71-76-77.md. Kern: P60-F1/P61-F1/P70-F4/P71-F1/P77-F1 "ein Strich liegt
/// nach dem Absetzen zuerst nur im Speicher". Ein harter Abbruch des Prozesses (iOS beendet die App, Absturz) wird so
/// nachgestellt: der Ordner des Containers wird zu einem Zeitpunkt kopiert (das ist alles, was ein beendeter Prozess
/// hinterlaesst), und ein neuer Store oeffnet die Kopie. Echter Weg wie in `AuditPaket41AppTests`: lokales Backend
/// (SQLite) im Temp-Ordner. Alle Daten sind erfunden.
@MainActor
final class AuditPaket59bis77AppTests: XCTestCase {

    // MARK: Aufbau

    struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let file: LibFile
    }

    private func makeFixture(pages: Int = 3) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-p59-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-09T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "p59-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-09T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: pages, .schlicht).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)"))
            .write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-09T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, host: host, api: api, file: file)
    }

    private func openStore(_ fx: Fixture, timing: SaveTiming = .standard) async -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        store.saveTiming = timing
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private func strokes(_ doc: AnnotationDocument?, _ key: String) -> Int {
        (doc?.objects(page: key) ?? []).filter { $0["type"]?.string == "stroke" }.count
    }

    private func stroke(_ n: Int) -> PKStroke {
        let x = 40 + CGFloat(n % 20) * 25, y = 100 + CGFloat(n / 20) * 30
        return Handschrift.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x + 18, y: y + 4),
                                created: Date(timeIntervalSinceReferenceDate: 797_000_000 + Double(n)))
    }

    private func drawing(_ range: Range<Int>) -> PKDrawing {
        var d = PKDrawing()
        for n in range { d.strokes.append(stroke(n)) }
        return d
    }

    /// Was ein in diesem Moment hart beendeter Prozess hinterlaesst: Kopie des ganzen Ordners (Journal, PDF,
    /// Datenbank). Synchron auf dem Hauptthread, also ohne dass der laufende Store dazwischen weiterarbeitet.
    private func diskAtThisMoment(_ fx: Fixture) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-p59kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fx.root, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy
    }

    /// Neuer Prozess auf der Kopie: oeffnet das Dokument wie nach dem Neustart, liest den Stand, schliesst es.
    private func restart(_ fx: Fixture, from copy: URL) async -> AnnotationDocument {
        let host = LocalBackendHost(directory: copy.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-09T09:05:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let store = DocumentStore(file: fx.file, api: api, root: copy)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let doc = await store.pageStructureDocument()
        await store.close()
        return doc
    }

    // MARK: P60-F1 / P61-F1 / P71-F1 / P77-F1: harter Abbruch direkt nach dem Absetzen

    /// Der Prozess endet, bevor die Schreibpause abgelaufen ist (hier: Pause 30 s, keine Obergrenze, damit nichts
    /// vorher umgerechnet wird). Kein Hintergrund, kein Schliessen, keine Uebergabe: drei fertige Striche muessen
    /// nach dem Neustart da sein.
    func testP60_F1_HardKillBeforeThePauseKeepsEveryLiftedStroke() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: nil))
        for n in 1...3 { store.canvasChanged(pageKey: "p1", drawing: drawing(0..<n)) }
        store.canvasChanged(pageKey: "p2", drawing: drawing(40..<41))
        let disk = try diskAtThisMoment(fx)
        let doc = await restart(fx, from: disk)
        XCTAssertEqual(strokes(doc, "p1"), 3, "fertige Striche nach hartem Abbruch verloren (Seite 1)")
        XCTAssertEqual(strokes(doc, "p2"), 1, "fertiger Strich nach hartem Abbruch verloren (Seite 2)")
        withExtendedLifetime(store) {}
    }

    /// P61-01 / P77-01: Strich absetzen, Prozess nach 0, 50, 100, 200, 300, 500 und 1000 ms beenden (Standard 0,25 s /
    /// 2 s). Gemessen wird, ab wann der Strich einen Abbruch uebersteht: einmal auf einer leeren Seite, einmal auf einer
    /// dichten (300 Striche; dort kommt die Umrechnung der ganzen Seite dazu).
    func testP61_01_StrokeSurvivesAKillAtEveryMomentAfterTheLift() async throws {
        for existing in [0, 300] {
            let fx = try await makeFixture()
            let store = await openStore(fx)
            if existing > 0 {
                store.canvasChanged(pageKey: "p1", drawing: drawing(0..<existing))
                await store.flush()
            }
            let lifted = drawing(0..<(existing + 1))
            let t0 = DispatchTime.now().uptimeNanoseconds
            store.canvasChanged(pageKey: "p1", drawing: lifted)
            var copies: [(ms: Double, url: URL)] = []
            for offset in [0.0, 50, 100, 200, 300, 500, 1000] {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                if offset > elapsed { try await Task.sleep(nanoseconds: UInt64((offset - elapsed) * 1e6)) }
                let at = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                copies.append((at, try diskAtThisMoment(fx)))
            }
            await store.close()
            var report: [String] = []
            for c in copies {
                let n = strokes(await restart(fx, from: c.url), "p1")
                report.append(String(format: "%.0f ms: %d", c.ms, n))
                XCTAssertEqual(n, existing + 1, String(format: "Abbruch %.0f ms nach dem Absetzen (Seite mit %d Strichen): Strich fehlt", c.ms, existing))
            }
            print("P61-01 Seite mit \(existing) Strichen, Striche nach Abbruch: " + report.joined(separator: ", "))
        }
    }

    /// Was die Canvas beim Abbruch zeigte, ist nach dem Neustart unbekannt (Striche, die erst waehrend der Pause von
    /// einem anderen Geraet kamen, fehlen ihr). Die Wiederherstellung fuegt deshalb nur hinzu und loescht nichts: hier
    /// liegt A im Journal, die Canvas meldet nur B. Nach dem Abbruch sind A und B da.
    func testP60_F1_RecoveryAfterAKillAddsButNeverErases() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: nil))
        store.canvasChanged(pageKey: "p1", drawing: drawing(0..<1))
        await store.flush()
        store.canvasChanged(pageKey: "p1", drawing: drawing(1..<2))
        let disk = try diskAtThisMoment(fx)
        let doc = await restart(fx, from: disk)
        XCTAssertEqual(strokes(doc, "p1"), 2, "A (Journal) und B (abgesetzt, nicht umgerechnet) muessen beide da sein")
        withExtendedLifetime(store) {}
    }
}

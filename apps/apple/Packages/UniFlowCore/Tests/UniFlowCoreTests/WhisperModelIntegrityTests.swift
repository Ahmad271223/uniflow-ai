import Foundation
import XCTest
@testable import UniFlowCore

/// Sicherheitspruefung 27.11.2026: Modelle der Mitschrift nur mit passender Pruefsumme benutzen
final class WhisperModelIntegrityTests: XCTestCase {
    func testManifestCoversBothOfferedModelsWithPlausibleSizes() {
        for choice in WhisperModels.all {
            let files = WhisperModelIntegrity.manifest[choice.variant]
            XCTAssertNotNil(files, choice.variant)
            let mb = Double((files ?? [:]).values.reduce(0) { $0 + $1.size }) / 1_000_000
            XCTAssertEqual(mb, Double(choice.megabytes), accuracy: Double(choice.megabytes) * 0.05, choice.variant)
            XCTAssertTrue((files ?? [:]).values.allSatisfy { $0.sha256.count == 64 })
        }
        XCTAssertEqual(WhisperModelIntegrity.revision.count, 40)
    }

    func testMissingWrongAndForeignFilesAreReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(WhisperModelIntegrity.problems(variant: "gibt-es-nicht", folder: dir), ["Unbekanntes Modell gibt-es-nicht"])
        let variant = WhisperModels.klein.variant
        let empty = WhisperModelIntegrity.problems(variant: variant, folder: dir)
        XCTAssertEqual(empty.count, WhisperModelIntegrity.manifest[variant]?.count, "leerer Ordner: jede Datei fehlt")
        XCTAssertTrue(empty.allSatisfy { $0.hasPrefix("fehlt: ") })
        // eine Datei mit richtiger Groesse, aber anderem Inhalt; eine fremde Datei in einem .mlmodelc-Ordner
        let (rel, e) = try XCTUnwrap(WhisperModelIntegrity.manifest[variant]?.min { $0.value.size < $1.value.size })
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: Int(e.size)).write(to: url)
        let foreign = dir.appendingPathComponent("AudioEncoder.mlmodelc/boese.bin")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: foreign)
        let p = WhisperModelIntegrity.problems(variant: variant, folder: dir)
        XCTAssertTrue(p.contains("Prüfsumme: \(rel)"), "\(p)")
        XCTAssertTrue(p.contains("unbekannt: AudioEncoder.mlmodelc/boese.bin"), "\(p)")
    }

    func testSha256InChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(WhisperModelIntegrity.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// Gegenprobe mit einem echt geladenen Modell (nur auf dem Mac des Inhabers, Pfad in UF_WHISPER_REAL_DIR, sonst
/// uebersprungen): der Ordner, wie WhisperKit ihn von Hugging Face anlegt, passt zur Liste.
final class WhisperModelIntegrityRealTests: XCTestCase {
    func testRealDownloadedSmallModelPasses() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_WHISPER_REAL_DIR"] else { throw XCTSkip("kein echtes Modell") }
        let folder = URL(fileURLWithPath: path).appendingPathComponent(WhisperModels.klein.variant)
        XCTAssertEqual(WhisperModelIntegrity.problems(variant: WhisperModels.klein.variant, folder: folder), [])
    }
}

import AVFoundation
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Vorlesung aufnehmen in der App ohne Mikrofon (docs/VORLESUNG-AUFNEHMEN.md): Ablage im Container des Geraets
/// (`recordings/eigene/<id>.m4a` und `.txt`), Karte "Eigene Aufnahmen" mit Zeilen in der gehosteten Ansicht, Hilfsfunktionen
/// des Dialogs. Die Aufnahme selbst (AVAudioEngine, Spracherkennung) laeuft nur am echten iPad.
@MainActor
final class OwnRecordingsAppTests: XCTestCase {

    private struct Device {
        let layout: DataContainerLayout
        let host: LocalBackendHost
    }

    private nonisolated static let clock = UniFlowClock.fixed(berlin: "2026-11-10T10:20:00")!

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    /// Container (erfundener Apple-Nutzer, LUH) wie in der App mit einem Modul "Analysis I"
    private func device() async throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ownrec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let layout = DataContainerLayout(base: c, key: DataContainerKey(userID: "001234.erfunden.ownrec", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Analysis I', '#123456', ?)", [.text(Self.clock.nowISO)])
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (2, 'Physik', '#654321', ?)", [.text(Self.clock.nowISO)])
        }
        return Device(layout: layout, host: host)
    }

    // MARK: Ablage im Container

    func testRecordingAndTranscriptLiveInTheContainer() async throws {
        let dev = try await device()
        let api = APIClient.local(dev.host)
        let created = try await api.value("/api/recordings/own", method: "POST",
                                          body: ["id": "abc123", "module_id": 1, "event_title": "Analysis I", "duration": 125, "language": "de-DE"])
        XCTAssertEqual(created.s("title"), "Analysis I · 10.11.2026")
        XCTAssertEqual(created.s("audio_path"), "recordings/eigene/abc123.m4a")
        // der Pfad der Aufnahme zeigt in den Container, wie der Recorder ihn ueber LocalFiles bekommt
        let files = try XCTUnwrap(dev.host.files)
        let audio = try XCTUnwrap(files.url(stored: OwnRecordingFiles.audioPath("abc123")))
        XCTAssertEqual(audio, dev.layout.root.appendingPathComponent("recordings/eigene/abc123.m4a"))
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: audio)
        // Mitschrift per PATCH: Abschnitte in der Datenbank, Textdatei neben der Aufnahme
        let sections: JSONValue = [["start": 0, "end": 60, "text": "Grenzwerte von Folgen."], ["start": 60, "end": 125, "text": "Konvergenz und Divergenz."]]
        let patched = try await api.value("/api/recordings/own/abc123", method: "PATCH", body: ["transcript": sections])
        XCTAssertEqual(patched.i("sections"), 2)
        XCTAssertEqual(patched.s("transcript_status"), "done")
        let txt = dev.layout.root.appendingPathComponent("recordings/eigene/abc123.txt")
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), "[00:00] Grenzwerte von Folgen.\n\n[01:00] Konvergenz und Divergenz.\n")
        // Suche findet die Mitschrift, die Zeile erscheint nur bei ihrem Modul
        let search = try await api.value("/api/search?q=divergenz")
        XCTAssertEqual(search["recordings"]?.array?.first?["start"]?.double, 60)
        let physik = try await api.value("/api/recordings/own?module_id=2")
        XCTAssertEqual(physik.array?.count, 0)
        let analysis = try await api.value("/api/recordings/own?module_id=1")
        XCTAssertEqual(analysis.array?.count, 1)
        // Loeschen entfernt Datei, Mitschrift und Eintrag
        _ = try await api.value("/api/recordings/own/abc123", method: "DELETE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: txt.path))
        let rest = try await api.value("/api/recordings/own")
        XCTAssertEqual(rest.array?.count, 0)
    }

    // MARK: Karte "Eigene Aufnahmen" (Ansichten mit festen Antworten wie die anderen Ansichtstests; die Ablage selbst
    // prueft der Test oben gegen das lokale Backend)

    private func api(_ t: AIViewsAppTests.Transport) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    func testSectionShowsRowsAndEmptyText() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own", [
            ["id": "r1", "module_id": 1, "title": "VL 5: Grenzwerte", "duration": 5400, "recorded_at": "2026-11-10T10:20:00",
             "transcript_status": "done", "sections": 2, "transcript": [["start": 0, "end": 60, "text": "a"], ["start": 60, "end": 120, "text": "b"]]],
            ["id": "r2", "module_id": 1, "title": "Ohne Text", "duration": 90, "recorded_at": "2026-11-03T08:15:00", "transcript_status": "unavailable",
             "sections": 0, "transcript": []],
        ])
        let env = try hostWithEnvironment(OwnRecordingsSection(moduleID: 1).padding(), api: api(t), size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("VL 5: Grenzwerte") } }, "\(env.labels())")
        let labels = env.labels()
        XCTAssertTrue(labels.contains("Eigene Aufnahmen"), "\(labels)")
        XCTAssertTrue(labels.contains("Aufnehmen"), "\(labels)")
        let row = try XCTUnwrap(labels.first { $0.hasPrefix("VL 5: Grenzwerte") })
        XCTAssertTrue(row.contains("10.11.2026") && row.contains("10:20") && row.contains("1:30 h") && row.contains("Mitschrift · 2 Abschnitte"), row)
        let other = try XCTUnwrap(labels.first { $0.hasPrefix("Ohne Text") })
        XCTAssertTrue(other.contains("Ohne Mitschrift") && other.contains("2 min"), other)
        XCTAssertTrue(labels.contains("Öffnen") && labels.contains("Löschen"), "\(labels)")
        XCTAssertEqual(t.count("GET", "/api/recordings/own"), 1, "einmal geladen, keine KI-Aufrufe")

        // ohne Aufnahmen: leer mit Erklaerung, der Knopf bleibt
        let none = AIViewsAppTests.Transport()
        none.answer("/api/recordings/own", [])
        let empty = try hostWithEnvironment(OwnRecordingsSection(moduleID: 2).padding(), api: api(none), size: CGSize(width: 900, height: 600))
        XCTAssertTrue(empty.wait { empty.labels().contains { $0.hasPrefix("Noch keine eigene Aufnahme") } }, "\(empty.labels())")
        XCTAssertTrue(empty.labels().contains("Aufnehmen"))
        XCTAssertFalse(empty.labels().contains { $0.hasPrefix("VL 5") })
    }

    /// Die Ansicht einer Aufnahme zeigt Abschnitte mit Zeitmarken; ohne ChatGPT keine KI-Knoepfe, nur der Hinweis; nichts
    /// wird von selbst an die KI geschickt
    func testDetailShowsSectionsWithoutAIButtons() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own/r1", ["id": "r1", "module_id": 1, "module_name": "Analysis I", "title": "VL 5", "duration": 130,
                                            "recorded_at": "2026-11-10T10:20:00", "transcript_status": "done", "sections": 2,
                                            "audio_path": "recordings/eigene/r1.m4a",
                                            "transcript": [["start": 0, "end": 61, "text": "Heute Grenzwerte."], ["start": 61, "end": 130, "text": "Dann Stetigkeit."]]])
        let env = try hostWithEnvironment(OwnRecordingDetail(id: "r1") {}.padding(), api: api(t), size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Heute Grenzwerte.") }, "\(env.labels())")
        let labels = env.labels()
        XCTAssertTrue(labels.contains("Dann Stetigkeit."), "\(labels)")
        XCTAssertTrue(labels.contains("Springe zu 00:00") && labels.contains("Springe zu 01:01"), "\(labels)")
        XCTAssertTrue(labels.contains("Die Audiodatei liegt nicht mehr auf diesem \(UFDevice.name)."), "ohne Container keine Datei: \(labels)")
        XCTAssertFalse(labels.contains("Zusammenfassen") || labels.contains("Kernpunkte") || labels.contains("Karteikarten"), "ohne KI keine Knoepfe")
        // ChatGPT verbinden ist vorerst aus (0ad0319): dann verweist der Hinweis auf die StudiNow-KI in Pro AI
        let hint = ChatGPTLink.isEnabled ? "Zusammenfassung, Kernpunkte und Karteikarten aus der Mitschrift gibt es, sobald ChatGPT"
                                         : "Zusammenfassung, Kernpunkte und Karteikarten aus der Mitschrift kommen mit der StudiNow-KI"
        XCTAssertTrue(labels.contains { $0.hasPrefix(hint) }, "\(labels)")
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0, "0 KI-Aufrufe ohne Antippen")
    }

    /// Mit verbundenem ChatGPT: Knoepfe da, aber erst das Antippen sendet - nur Text des Teils, ohne Datei
    func testDetailSendsTranscriptTextOnlyAfterTap() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/recordings/own/r1", ["id": "r1", "module_id": 1, "title": "VL 5", "duration": 130, "recorded_at": "2026-11-10T10:20:00",
                                            "transcript_status": "done", "sections": 1, "transcript": [["start": 0, "end": 61, "text": "Heute Grenzwerte."]]])
        t.answer("/api/ai/tutor", ["answer": "**Kurz:** Grenzwerte.", "cards": .null, "sources": [], "explain": .null])
        let env = try hostWithEnvironment(OwnRecordingDetail(id: "r1") {}.environment(\.ufAIEnabled, true).padding(), api: api(t),
                                          size: CGSize(width: 900, height: 900))
        XCTAssertTrue(env.wait { env.labels().contains("Zusammenfassen") }, "\(env.labels())")
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0)
        XCTAssertTrue(tap("Zusammenfassen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/ai/tutor").first)
        XCTAssertEqual(body["mode"], "summary")
        XCTAssertEqual(body["page_text"], "[00:00] Heute Grenzwerte.")
        XCTAssertEqual(body["file_id"], .null)
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("Grenzwerte.") && $0.contains("Kurz") } }, "\(env.labels())")
    }

    // MARK: Antippen im Bedienungshilfen-Baum (wie AIViewsAppTests)

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
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

    @discardableResult
    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) && e.accessibilityLabel == label {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: Hilfsfunktionen

    func testDialogHelpers() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"), year: 2026, month: 11, day: 10, hour: 10))!
        XCTAssertEqual(LectureRecordDialog.defaultTitle(event: "Analysis I", date: date), "Analysis I · 10.11.2026")
        XCTAssertEqual(LectureRecordDialog.defaultTitle(event: "", date: date), "Vorlesung vom 10.11.2026")
        XCTAssertEqual(LectureRecordDialog.label(["title": "Analysis I", "start": "10:15", "end": "11:45", "room": "E001"]), "Analysis I · 10:15–11:45 · E001")
        XCTAssertEqual(LectureRecordDialog.label(["title": "Physik"]), "Physik")
        XCTAssertEqual(OwnRecordingRow.meta(["recorded_at": "2026-11-10T10:20:00", "duration": 5400, "event_title": "Analysis I", "title": "VL"]),
                       "10.11.2026 · 10:20 · 1:30 h · Analysis I")
        XCTAssertEqual(OwnRecordingRow.badge(["transcript_status": "partial", "sections": 3]).0, "Mitschrift unvollständig")
        XCTAssertEqual(OwnRecordingRow.badge(["transcript_status": "done", "sections": 1]).0, "Mitschrift · 1 Abschnitt")
        XCTAssertEqual(OwnRecordingRow.badge([:]).0, "Ohne Mitschrift")
    }

    /// Pegel aus einem Puffer (0…1) und der Zustand eines Recorders vor dem Start (kein Mikrofon noetig)
    func testLevelAndInitialState() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        for i in 0..<100 { buffer.floatChannelData![0][i] = 0.1 }
        XCTAssertEqual(TapSink.rms(buffer), 0.4, accuracy: 0.001)
        buffer.frameLength = 0
        XCTAssertEqual(TapSink.rms(buffer), 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ownrec-\(UUID().uuidString).m4a")
        let r = LectureRecorder(id: "x", fileURL: url, language: "en-US")
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.transcriptStatus, "none")
        XCTAssertEqual(r.locale.identifier, "en-US")
        XCTAssertTrue(r.sections.isEmpty)
        XCTAssertEqual(LectureRecorder.languages.map(\.value), ["de-DE", "en-US"])
        r.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

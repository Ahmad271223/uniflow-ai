import Speech
import UniFlowCore
import XCTest
@testable import UniFlow

/// Dateiarten ohne PDF in der App (docs/DATEIARTEN.md): welche Datei die Textansicht bekommt, wie ein Transkript in
/// Absaetze faellt, und dass das lokale Backend des Containers ein Transkript neben einer Audiodatei als Seiten liest.
/// Keine echte Spracherkennung (sie braucht Sprachpakete und eine Freigabe); nur gemeldet, ob sie verfuegbar waere.
final class TextDocumentAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-04T12:00:00")!

    private func file(_ name: String, kind: String, downloaded: Bool = true, pages: Int? = nil) -> LibFile {
        LibFile(id: "f-" + name, name: name, title: nil, kind: kind, module_id: nil, subject: nil, doc_type: nil, ai_title: nil,
                sub_label: nil, downloaded_at: downloaded ? "2026-11-04" : nil, has_notes: nil, page_count: pages, studip_folder: nil)
    }

    func testWhichFilesOpenAsText() {
        XCTAssertTrue(file("bericht.docx", kind: "file").opensAsText)
        XCTAssertTrue(file("Folien.PPTX", kind: "file").opensAsText)
        XCTAssertTrue(file("vl.m4a", kind: "file").opensAsText)
        XCTAssertFalse(file("vl.m4a", kind: "file", downloaded: false).opensAsText, "nicht geladen: Meldung statt Textansicht")
        XCTAssertFalse(file("alt.doc", kind: "file").opensAsText, "altes Word: QuickLook")
        XCTAssertFalse(file("skript.pdf", kind: "pdf").opensAsText, "PDF: Editor")
        XCTAssertTrue(file("skript.pdf", kind: "pdf").opensInEditor)
        XCTAssertEqual(file("bericht.docx", kind: "file").sourceKind, "docx")
        XCTAssertEqual(LibraryStyle.displayKind("pptx"), "slides")
        XCTAssertEqual(ShellState.typeIcon["audio"], "play")
        XCTAssertEqual(TextDocumentView.kindLabel("pptx"), "PowerPoint · Folientext")
        XCTAssertEqual(LibraryVideoLinks.moduleID(path: "m12"), 12)
        XCTAssertNil(LibraryVideoLinks.moduleID(path: "m12/vorlesung"))
        XCTAssertNil(LibraryVideoLinks.moduleID(path: "f3"))
    }

    func testTranscriptParagraphs() {
        let lines = AudioTranscriber.paragraphs("Guten Morgen. Heute geht es um den Spannungsteiler! Zwei Widerstände in Reihe? Ja")
        XCTAssertEqual(lines, ["Guten Morgen.", "Heute geht es um den Spannungsteiler!", "Zwei Widerstände in Reihe?", "Ja"])
        let long = AudioTranscriber.paragraphs(Array(repeating: "wort", count: 60).joined(separator: " "))
        XCTAssertEqual(long.map { $0.split(separator: " ").count }, [25, 25, 10], "ohne Satzzeichen alle 25 Woerter")
        XCTAssertEqual(AudioTranscriber.paragraphs("   "), [])
        XCTAssertTrue(AudioTranscriber.supports("Aufnahme.MP3") && !AudioTranscriber.supports("a.wav"))
    }

    func testContainerBackendReadsTranscriptBesideAudio() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: "001234.erfunden.text", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let rel = "files/ET/vorlesung.m4a"
        let url = layout.root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 0, 0, 0x1c, 0x66, 0x74, 0x79, 0x70]).write(to: url)
        let db = backend.context.database
        try await db.execute("INSERT INTO courses(id, title) VALUES ('k-et', 'Elektrotechnik')")
        try await db.execute("INSERT INTO files(id, course_id, name, chdate, local_path) VALUES ('f-vl', 'k-et', 'vorlesung.m4a', 7, ?)", [.text(rel)])
        // ohne Transkript: kein Seitentext (die Textansicht zeigt dann "Transkript erstellen")
        var r = await host.handle(LocalRequest(method: "GET", path: "/api/files/f-vl/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json?["code"]?.string, "no_content")
        // Transkript wie `AudioTranscriber` es schreibt: eine Zeile je Satz neben der Datei
        let lines = AudioTranscriber.paragraphs("Die Maschenregel. Die Summe aller Spannungen ist null.")
        _ = try XCTUnwrap(backend.context.files).write(Data((lines.joined(separator: "\n") + "\n").utf8), to: OfficeText.transcriptPath(for: rel))
        r = await host.handle(LocalRequest(method: "GET", path: "/api/files/f-vl/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["kind"]?.string, "audio")
        XCTAssertEqual(r.json?["pages"]?.int, 1)
        XCTAssertEqual(r.json?["text"]?.string, "Die Maschenregel.\nDie Summe aller Spannungen ist null.")
        r = await host.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "maschenregel")]))
        XCTAssertEqual((r.json?["pages"]?.array ?? []).map { $0["kind"]?.string ?? "" }, ["audio"])
        print("Spracherkennung auf dem Geraet verfuegbar: de-DE \(AudioTranscriber.onDeviceAvailable("de-DE")), en-US \(AudioTranscriber.onDeviceAvailable("en-US"))")
    }
}

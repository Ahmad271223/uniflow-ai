import Foundation
import XCTest
@testable import UniFlowCore

// Word (.docx) und PowerPoint (.pptx) als Seitentexte (docs/DATEIARTEN.md, 04.11.2026): dieselben Dateien und
// Erwartungen wie Python (packages/shared-contracts/fixtures/office-text, tools/gen-office-fixture.py, geprueft von
// tests/test_office_text.py). Dazu: das lokale Backend liest Word/PowerPoint von der Platte wie PDF, /pagetext und
// Seitentreffer der Suche nennen `kind`, ein Transkript neben einer Audiodatei wird zu Seiten.

private func fixtureDir() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("packages/shared-contracts/fixtures/office-text")
}

private let clock = UniFlowClock.fixed(berlin: "2026-11-04T09:00:00")!

final class OfficeTextTests: XCTestCase {
    private func cases() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: fixtureDir().appendingPathComponent("cases.json")))
    }

    func testPagesMatchPythonReference() throws {
        let fx = try cases()
        XCTAssertEqual(OfficeText.softPageChars, fx["soft_page_chars"]?.int)
        XCTAssertEqual(OfficeText.hardPageChars, fx["hard_page_chars"]?.int)
        var checked = 0
        for c in fx["files"]?.array ?? [] {
            let name = c["file"]?.string ?? ""
            let data = try Data(contentsOf: fixtureDir().appendingPathComponent(name))
            let expected = (c["pages"]?.array ?? []).map { $0.string ?? "" }
            XCTAssertEqual(try OfficeText.pages(data: data, kind: c["kind"]?.string ?? ""), expected, name)
            XCTAssertEqual(OfficeText.pages(url: fixtureDir().appendingPathComponent(name), name: name), expected, name)
            XCTAssertEqual(OfficeText.kind(name), c["kind"]?.string, name)
            checked += 1
        }
        XCTAssertEqual(checked, 3)
    }

    func testParagraphPagesAndKinds() throws {
        let fx = try cases()
        for c in fx["paragraph_pages"]?.array ?? [] {
            let paragraphs = (c["paragraphs"]?.array ?? []).map { $0.string ?? "" }
            let headings = Set((c["headings"]?.array ?? []).compactMap(\.int))
            let breaks = Set((c["breaks"]?.array ?? []).compactMap(\.int))
            XCTAssertEqual(OfficeText.pages(paragraphs: paragraphs, headings: headings, breaks: breaks),
                           (c["pages"]?.array ?? []).map { $0.string ?? "" }, c["name"]?.string ?? "")
        }
        for k in fx["kinds"]?.array ?? [] {
            let name = k["name"]?.string ?? ""
            XCTAssertEqual(OfficeText.kind(name), k["kind"]?.string, name)
            XCTAssertEqual(ScriptSearch.isTextSource(name), ["pdf", "docx", "pptx"].contains(k["kind"]?.string ?? ""), name)
        }
        // Laenge nach Codepunkten wie Pythons len (zerlegtes ä = zwei Codepunkte)
        let decomposed = String(repeating: "a\u{308}", count: 1500)
        XCTAssertEqual(OfficeText.pages(paragraphs: [decomposed, "Kapitel", "x"], headings: [1]).count, 2)
    }

    func testBrokenFilesThrowAndZipReaderHandlesStoredEntries() throws {
        XCTAssertThrowsError(try OfficeText.docxPages(Data("kein zip".utf8)))
        XCTAssertThrowsError(try OfficeText.pptxPages(Data("PK\u{3}\u{4} kaputt".utf8)))
        XCTAssertNil(OfficeText.pages(url: fixtureDir().appendingPathComponent("cases.json"), name: "cases.json"))
        let zip = try ZipReader(data: try Data(contentsOf: fixtureDir().appendingPathComponent("folien.pptx")))
        XCTAssertEqual(zip.entries["ppt/notesSlides/notesSlide1.xml"]?.method, 0, "ungepackter Eintrag")
        XCTAssertEqual(zip.entries["ppt/slides/slide1.xml"]?.method, 8, "DEFLATE")
        XCTAssertNil(try zip.read("gibt/es/nicht.xml", limit: 1 << 20))
        XCTAssertThrowsError(try zip.read("ppt/slides/slide1.xml", limit: 10))
    }

    /// Backend mit Word, PowerPoint und einer Audiodatei mit Transkript auf der Platte
    private func seeded() async throws -> (LocalBackend, URL) {
        let container = try tempContainer(self)
        let dir = container.appendingPathComponent("StudIP/files/k-et", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["bericht.docx", "folien.pptx"] {
            try FileManager.default.copyItem(at: fixtureDir().appendingPathComponent(n), to: dir.appendingPathComponent(n))
        }
        try Data([0, 0, 0, 0x1c, 0x66, 0x74, 0x79, 0x70]).write(to: dir.appendingPathComponent("aufnahme.m4a"))
        try "Guten Morgen, heute geht es um den Spannungsteiler.\n\nZwei Widerstände in Reihe.\n".write(
            to: dir.appendingPathComponent("aufnahme.m4a" + OfficeText.transcriptSuffix), atomically: true, encoding: .utf8)
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: container, dataDirectory: "", tools: NoDocumentTools()))
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (93, 'Dateiarten Test', '#223344', '2026-11-04')")
            try c.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('c-arten', 'Dateiarten Kurs', 'Dateiarten Test', 'vorlesung', 93, 1, '2026-11-04')")
            for (id, name) in [("f-word", "bericht.docx"), ("f-folien", "folien.pptx"), ("f-audio", "aufnahme.m4a"), ("f-ohne", "ohne.m4a")] {
                try c.execute("INSERT INTO files(id, course_id, name, kind, status, chdate, local_path, studip_folder) VALUES (?, 'c-arten', ?, 'file', 'neu', 1762250000, ?, 'Vorlesung')",
                              [.text(id), .text(name), .text("StudIP/files/k-et/" + name)])
                try c.execute("INSERT INTO analysis(file_id, doc_type, title) VALUES (?, 'vorlesung', ?)", [.text(id), .text(name)])
            }
        }
        return (backend, container)
    }

    func testBackendReadsOfficeFilesAndTranscriptLikePDF() async throws {
        let (backend, _) = try await seeded()
        var r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-folien/pagetext", query: [.init("page", "2")]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["kind"]?.string, "pptx")
        XCTAssertEqual(r.json?["pages"]?.int, 4)
        XCTAssertTrue(r.json?["text"]?.string?.hasPrefix("Beispiel: R1 = 2 Ω") == true, r.json?["text"]?.string ?? "")
        XCTAssertTrue(r.json?["text"]?.string?.contains("Notizen:") == true)
        r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-word/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(r.json?["kind"]?.string, "docx")
        XCTAssertEqual(r.json?["pages"]?.int, 4)
        XCTAssertTrue(r.json?["text"]?.string?.contains("Knotenregel") == true)
        // Transkript neben der Audiodatei: Zeilen werden Absaetze einer Seite
        r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-audio/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["kind"]?.string, "audio")
        XCTAssertEqual(r.json?["text"]?.string, "Guten Morgen, heute geht es um den Spannungsteiler.\nZwei Widerstände in Reihe.")
        // Audio ohne Transkript: kein Seitentext (404 no_content wie eine nie gelesene Datei)
        r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-ohne/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json?["code"]?.string, "no_content")
        // Seitentreffer der globalen Suche mit `kind`
        r = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "spannungsteiler")]))
        let hits = (r.json?["pages"]?.array ?? []).map { "\($0["file_id"]?.string ?? "")/\($0["page"]?.int ?? 0)/\($0["kind"]?.string ?? "-")" }
        XCTAssertEqual(Set(hits), ["f-folien/2/pptx", "f-audio/1/audio"])
        // Skriptsuche: Word und PowerPoint sind Quellen des Moduls (Audio nicht, wie am PC)
        let srcs = try await backend.context.database.withConnection { try ScriptSearch.sources($0, moduleID: .integer(93)) }
        XCTAssertEqual(Set(srcs.map { $0["id"]?.string ?? "" }), ["f-word", "f-folien"])
        let idx = try await ScriptSearch.index(moduleID: .integer(93), database: backend.context.database, files: backend.context.files,
                                               cache: backend.context.scriptIndex)
        XCTAssertTrue(Set(idx.docs.map { "\($0.file["id"]?.string ?? "")/\($0.page)" }).isSuperset(of: ["f-word/2", "f-word/3", "f-folien/2"]))
        // gespeichert: zweiter Abruf aus page_texts
        let stored = try await backend.context.database.rows("SELECT file_id, COUNT(*) AS n FROM page_texts GROUP BY file_id ORDER BY file_id")
        XCTAssertEqual(stored.map { "\($0["file_id"]?.string ?? "")=\($0["n"]?.int ?? 0)" }, ["f-audio=1", "f-folien=4", "f-word=4"])
    }
}

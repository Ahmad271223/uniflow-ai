import Foundation
import XCTest
@testable import UniFlowCore

/// Datei-Eingang (Auftrag 18.11.2026): welche Dateien gehen hoch, jede nur einmal, nie eine Liste mit Namen.
final class CourseFileIntakeTests: XCTestCase {

    /// Seitentext = Dateiinhalt als Text (statt PDFKit)
    private struct TextTools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { 1 }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? { (try? String(contentsOf: url, encoding: .utf8)).map { [$0] } }
    }

    /// Eingang zum Mitschreiben: kennt `known`, nimmt alles andere an
    private final class FakeIntake: CourseFileIntake.Transport, @unchecked Sendable {
        let lock = NSLock()
        var known: Set<String> = []
        var checked: [CourseFileIntake.Meta] = []
        var uploaded: [CourseFileIntake.Meta] = []
        var failUploads: CourseFileIntake.IntakeError?

        func check(_ metas: [CourseFileIntake.Meta]) async throws -> [String] {
            lock.withLock {
                checked += metas
                return metas.map(\.sha256).filter { !known.contains($0) }
            }
        }

        func upload(_ meta: CourseFileIntake.Meta, file: URL) async throws -> String {
            try lock.withLock {
                if let failUploads { throw failUploads }
                uploaded.append(meta)
                known.insert(meta.sha256)
                return "stored"
            }
        }
    }

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func backend() async throws -> LocalBackend {
        let files = LocalFiles(container: dir, dataDirectory: "", tools: TextTools())
        func put(_ name: String, _ text: String) throws { _ = try files.write(Data(text.utf8), to: name) }
        try put("vl1.pdf", "Folgen und Reihen")
        try put("vl1-kopie.pdf", "Folgen und Reihen")                  // gleicher Inhalt in einem zweiten Kurs
        try put("blatt1.pdf", "Aufgabe 1: Zeigen Sie")
        try put("ak.pdf", "Klausur WS 24, Aufgabe 1")
        try put("orga.pdf", "Termine und Raeume")
        try put("liste.pdf", "Name Matrikelnummer\nA 1234567\nB 2345678\nC 3456789\nD 4567890\nE 5678901")
        try put("gruppen.pdf", "Gruppe 1: Raum 12")
        try put("fremd.pdf", "Physik")

        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-18T10:00:00")!, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis I', '#175ee8', 0)")
            try c.execute("""
                INSERT INTO courses(id, title, number, semester, subject, kind, active, module_id, created_at) VALUES
                ('c1', 'Analysis I (Vorlesung)', '4711', 'WS 2026/27', 'Analysis I', 'vorlesung', 1, 1, 't'),
                ('c2', 'Analysis I (Übung)', '4712', 'WS 2026/27', 'Analysis I', 'uebung', 1, 1, 't'),
                ('alt', 'Alt', '1', 'SS 2026', 'Alt', 'vorlesung', 0, NULL, 't')
                """)
            try c.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene', 'sonstiges', 1, 't')")
            let rows: [(String, String, String, String?, Int64)] = [
                ("f-vl", "c1", "VL01 Folgen.pdf", "vl1.pdf", 50),
                ("f-vl2", "c2", "VL01 Folgen (Kopie).pdf", "vl1-kopie.pdf", 49),
                ("f-ub", "c2", "Blatt 1.pdf", "blatt1.pdf", 40),
                ("f-ak", "c1", "Altklausur WS 24.pdf", "ak.pdf", 30),
                ("f-orga", "c1", "Organisatorisches.pdf", "orga.pdf", 20),     // Art organisatorisch: nie
                ("f-liste", "c2", "Übung Blatt 2.pdf", "liste.pdf", 15),     // Namensliste im Text
                ("f-gruppen", "c2", "Gruppeneinteilung Übung.pdf", "gruppen.pdf", 14),   // Namensliste im Namen
                ("f-weg", "c1", "VL02.pdf", nil, 10),                         // nicht geladen
                ("f-zip", "c1", "Daten.zip", "vl1.pdf", 9),                   // keine PDF
                ("f-alt", "alt", "VL alt.pdf", "fremd.pdf", 8),               // alter Kurs
                ("f-eigen", "__user__", "Meine Notizen.pdf", "fremd.pdf", 7), // eigenes Dokument: nie
            ]
            for (id, course, name, path, ch) in rows {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status, local_path) VALUES (?,?,?,?,?,?)",
                              [.text(id), .text(course), .text(name), .integer(ch), .text("neu"), path.map(SQLiteValue.text) ?? .null])
            }
        }
        return b
    }

    func testNameListRuleMatchesTheServer() {
        XCTAssertTrue(CourseFileIntake.looksLikeNameList(text: "", fileName: "Teilnehmerliste WS.pdf"))
        XCTAssertTrue(CourseFileIntake.looksLikeNameList(text: "1234567 2345678 3456789 4567890 5678901", fileName: "x.pdf"))
        XCTAssertTrue(CourseFileIntake.looksLikeNameList(text: "Notenliste ... Unterschrift", fileName: "x.pdf"))
        XCTAssertFalse(CourseFileIntake.looksLikeNameList(text: "Satz 3.1: Jede beschränkte Folge hat eine konvergente Teilfolge. 2026", fileName: "VL03.pdf"))
        XCTAssertFalse(CourseFileIntake.looksLikeNameList(text: "Matrikelnummer bitte oben eintragen", fileName: "Blatt 1.pdf"),
                       "ein Feld für die eigene Nummer ist keine Liste")
    }

    func testSendsOnlyCourseMaterialOnceAndSorted() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        let r = try await CourseFileIntake.run(b.context, transport: fake)

        XCTAssertEqual(Set(fake.checked.map(\.fileName)), ["VL01 Folgen.pdf", "VL01 Folgen (Kopie).pdf", "Blatt 1.pdf", "Altklausur WS 24.pdf"])
        // gleicher Inhalt zweimal im Modul: einmal hochgeladen, der zweite Platz ist nur gemeldet
        XCTAssertEqual(fake.uploaded.count, 3)
        XCTAssertEqual(r.uploaded, 3)
        XCTAssertEqual(r.skippedNameLists, 2)
        let vl = try XCTUnwrap(fake.checked.first { $0.fileName == "VL01 Folgen.pdf" })
        XCTAssertEqual(vl.module, "Analysis I")
        XCTAssertEqual(vl.semester, "WS 2026/27")
        XCTAssertEqual(vl.docType, "vorlesung")
        XCTAssertEqual(vl.courseNumber, "4711")
        XCTAssertEqual(vl.sha256.count, 64)
        XCTAssertEqual(fake.checked.first { $0.fileName == "Altklausur WS 24.pdf" }?.docType, "klausur")
        XCTAssertEqual(fake.checked.first { $0.fileName == "Blatt 1.pdf" }?.docType, "uebung")
        XCTAssertNil(vl.program, "ohne gewählten Studiengang: der Eingang legt es unter „Ohne Studiengang“ ab")
        XCTAssertEqual(Set(vl.json.object?.keys ?? [:].keys), ["sha256", "program", "semester", "module", "doc_type", "file_name", "course_title", "course_number", "week", "pages"], "keine Konto-Angabe in der Karteikarte")

        // Fingerabdruck wird beim Gerät gemerkt
        let sha = try await b.context.database.withConnection { try $0.queryOne("SELECT content_sha256 FROM files WHERE id='f-vl'")?["content_sha256"]?.string }
        XCTAssertEqual(sha, vl.sha256)

        // zweiter Lauf: nichts Neues, nichts geht noch einmal hoch
        let again = try await CourseFileIntake.run(b.context, transport: fake)
        XCTAssertEqual(again, CourseFileIntake.Report())
        XCTAssertEqual(fake.uploaded.count, 3)
        let n = try await b.context.database.withConnection { try CourseFileIntake.sentCount($0) }
        XCTAssertEqual(n, 3)
    }

    func testKnownFilesAreOnlyReported() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        let sha = ContentHash.file(dir.appendingPathComponent("blatt1.pdf"))!
        fake.known = [sha]
        let r = try await CourseFileIntake.run(b.context, transport: fake)
        XCTAssertFalse(fake.uploaded.contains { $0.sha256 == sha }, "der Eingang hat die Datei schon")
        XCTAssertEqual(r.known, 2, "Blatt 1 und die zweite Kopie der Vorlesung")
    }

    func testStopsOnTicketErrorAndRetriesNextTime() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        fake.failUploads = .init(status: 429, code: "ticket_used_up")
        do {
            _ = try await CourseFileIntake.run(b.context, transport: fake)
            XCTFail("Ticketfehler beendet den Lauf")
        } catch let e as CourseFileIntake.IntakeError {
            XCTAssertEqual(e.code, "ticket_used_up")
        }
        fake.failUploads = nil
        let r = try await CourseFileIntake.run(b.context, transport: fake)
        XCTAssertEqual(r.uploaded, 3, "beim nächsten Lauf geht es weiter")
    }

    func testRejectedFileIsNotRetriedForever() async throws {
        let b = try await backend()
        let fake = FakeIntake()
        fake.failUploads = .init(status: 415, code: "http_415")
        let r = try await CourseFileIntake.run(b.context, transport: fake)
        XCTAssertEqual(r.failed, 3, "gleicher Inhalt zweimal: einmal versucht")
        fake.failUploads = nil
        let again = try await CourseFileIntake.run(b.context, transport: fake)
        XCTAssertEqual(again.uploaded, 0)
    }

    func testHTTPTransportSendsTicketAndMultipart() async throws {
        final class Recorder: ServiceHTTPTransport, @unchecked Sendable {
            var requests: [AIHTTPRequest] = []
            func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
                requests.append(request)
                if request.url.hasSuffix("/check") { return .init(status: 200, body: Data(#"{"missing": ["abc"]}"#.utf8)) }
                if request.url.hasSuffix("/file") { return .init(status: 422, body: Data(#"{"detail": {"code": "name_list", "detail": "x"}}"#.utf8)) }
                return .init(status: 500, body: Data())
            }
        }
        let rec = Recorder()
        let intake = HTTPCourseFileIntake(http: rec) { .init(token: "tok", url: "https://eingang.example", expires: Date().addingTimeInterval(3600)) }
        let meta = CourseFileIntake.Meta(sha256: "abc", program: "Informatik", semester: "WS", module: "M", docType: "skript",
                                         fileName: "S.pdf", courseTitle: nil, courseNumber: nil, week: nil, pages: 3)
        let missing = try await intake.check([meta])
        XCTAssertEqual(missing, ["abc"])
        XCTAssertEqual(rec.requests[0].url, "https://eingang.example/intake/v1/check")
        XCTAssertEqual(rec.requests[0].headers["Authorization"], "Bearer tok")
        let file = dir.appendingPathComponent("s.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        do {
            _ = try await intake.upload(meta, file: file)
            XCTFail("422 wird gemeldet")
        } catch let e as CourseFileIntake.IntakeError {
            XCTAssertEqual(e, .init(status: 422, code: "name_list"))
        }
        let body = String(decoding: rec.requests[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"meta\"") && body.contains("name=\"upload\"") && body.contains("%PDF-1.4"))
        XCTAssertTrue(rec.requests[1].headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
    }
}

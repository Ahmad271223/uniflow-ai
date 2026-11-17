import Foundation
import XCTest
@testable import UniFlowCore

/// Klausur-Generator, Stufe (a): Auswahl der Unterlagen eines Moduls mit den Grenzen des Inhabers (17.11.2026):
/// hoechstens 300 Seiten Vorlesung/Skript, 10 Altklausuren, 10 Uebungen, 1 bis 10 Probeklausuren.
final class ExamGeneratorSelectionTests: XCTestCase {
    private typealias Item = ExamGeneratorSelection.Item

    private func item(_ id: String, _ group: ExamGeneratorSelection.Group, pages: Int? = 4, solution: Bool = false, label: String = "Vorlesung",
                      chdate: Int64 = 0) -> Item {
        Item(id: id, title: id, label: label, group: group, isSolution: solution, pages: pages, chdate: chdate)
    }

    // MARK: Gruppen

    func testGroupsFollowDocumentType() {
        func g(_ t: String, _ l: String) -> String { let r = ExamGeneratorSelection.group(docType: t, label: l); return "\(r.group.rawValue)\(r.isSolution ? "+L" : "")" }
        XCTAssertEqual(g("vorlesung", "Vorlesung"), "material")
        XCTAssertEqual(g("skript", "Mitschrift"), "material")
        XCTAssertEqual(g("organisatorisch", "Organisatorisches"), "material")
        XCTAssertEqual(g("sonstiges", "Sonstiges"), "material")
        XCTAssertEqual(g("klausur", "Altklausur"), "exams")
        XCTAssertEqual(g("loesung", "Klausur-Lösung"), "exams+L")
        XCTAssertEqual(g("uebung", "Hörsaalübung"), "exercises")
        XCTAssertEqual(g("loesung", "Lösung"), "exercises+L")
    }

    // MARK: Grenzen

    func testMaterialIsLimitedByPagesNotFiles() {
        let items = (1...40).map { item("v\($0)", .material, pages: 10) }
        let ok = ExamGeneratorSelection.check(items, selected: Set(items.prefix(30).map(\.id)))
        XCTAssertEqual(ok.materialPages, 300)
        XCTAssertEqual(ok.materialFiles, 30)
        XCTAssertTrue(ok.isValid, "genau 300 Seiten sind erlaubt: \(ok.problems)")
        let over = ExamGeneratorSelection.check(items, selected: Set(items.prefix(31).map(\.id)))
        XCTAssertEqual(over.problems, ["Zu viele Seiten: höchstens 300 Seiten Vorlesung und Skript (gewählt: 310)."])
    }

    func testExamsAndExercisesAreLimitedByFilesAndPagesDoNotCount() {
        let exams = (1...11).map { item("k\($0)", .exams, pages: 40, label: "Altklausur") }
        let sheets = (1...11).map { item("u\($0)", .exercises, pages: 30, label: "Übung") }
        let all = exams + sheets
        var c = ExamGeneratorSelection.check(all, selected: Set(exams.prefix(10).map(\.id) + sheets.prefix(10).map(\.id)))
        XCTAssertTrue(c.isValid, "\(c.problems)")
        XCTAssertEqual([c.examFiles, c.exerciseFiles, c.materialPages, c.totalPages], [10, 10, 0, 700])
        c = ExamGeneratorSelection.check(all, selected: Set(all.map(\.id)))
        XCTAssertEqual(c.problems, ["Höchstens 10 Altklausuren (gewählt: 11).", "Höchstens 10 Übungen (gewählt: 11)."])
    }

    func testSolutionsDoNotCountAsExamOrExerciseButAreLimitedToo() {
        let exams = (1...10).map { item("k\($0)", .exams, label: "Altklausur") }
        let sols = (1...11).map { item("kl\($0)", .exams, solution: true, label: "Klausur-Lösung") }
        let sheet = item("u1", .exercises, label: "Übung")
        var c = ExamGeneratorSelection.check(exams + sols + [sheet], selected: Set(exams.map(\.id) + sols.prefix(10).map(\.id) + ["u1"]))
        XCTAssertTrue(c.isValid, "10 Klausuren mit 10 Lösungen: \(c.problems)")
        XCTAssertEqual([c.examFiles, c.examSolutions], [10, 10])
        c = ExamGeneratorSelection.check(exams + sols + [sheet], selected: Set(exams.map(\.id) + sols.map(\.id) + ["u1"]))
        XCTAssertEqual(c.problems, ["Höchstens 10 Lösungen zu Altklausuren (gewählt: 11)."])
    }

    func testNeedsLectureOrExerciseAndOneToTenMockExams() {
        let items = [item("k1", .exams, label: "Altklausur"), item("v1", .material), item("u1", .exercises, label: "Übung")]
        XCTAssertEqual(ExamGeneratorSelection.check(items, selected: []).problems, [ExamGeneratorSelection.textNothing])
        XCTAssertEqual(ExamGeneratorSelection.check(items, selected: ["k1"]).problems, [ExamGeneratorSelection.textNothing], "nur Altklausuren reichen nicht")
        XCTAssertTrue(ExamGeneratorSelection.check(items, selected: ["u1"]).isValid)
        XCTAssertTrue(ExamGeneratorSelection.check(items, selected: ["v1"], mockExams: 10).isValid)
        XCTAssertEqual(ExamGeneratorSelection.check(items, selected: ["v1"], mockExams: 11).problems, ["Wähle 1 bis 10 Probeklausuren."])
        XCTAssertEqual(ExamGeneratorSelection.check(items, selected: ["v1"], mockExams: 0).problems, ["Wähle 1 bis 10 Probeklausuren."])
    }

    func testHintWithoutOldExamDoesNotBlock() {
        let items = [item("k1", .exams, label: "Altklausur"), item("v1", .material)]
        let without = ExamGeneratorSelection.check(items, selected: ["v1"])
        XCTAssertTrue(without.isValid)
        XCTAssertEqual(without.hint, ExamGeneratorSelection.hintNoExam)
        XCTAssertNil(ExamGeneratorSelection.check(items, selected: ["v1", "k1"]).hint)
    }

    func testUnavailableAndUnknownFilesNeverCount() {
        let items = [item("v1", .material, pages: 5), item("fehlt", .material, pages: nil), item("leer", .material, pages: 0)]
        let c = ExamGeneratorSelection.check(items, selected: ["v1", "fehlt", "leer", "gibt-es-nicht"])
        XCTAssertEqual([c.materialFiles, c.materialPages, c.totalPages], [1, 5, 5])
    }

    // MARK: Alles auswählen

    func testSelectAllStaysInsideEveryLimit() {
        var items: [Item] = []
        items += (1...12).map { item("k\($0)", .exams, label: "Altklausur", chdate: Int64($0)) }
        items += (1...12).map { item("kl\($0)", .exams, solution: true, label: "Klausur-Lösung", chdate: Int64($0)) }
        items += (1...14).map { item("u\($0)", .exercises, label: "Übung", chdate: Int64($0)) }
        items += (1...20).map { item("v\($0)", .material, pages: 28, chdate: Int64($0)) }           // 560 Seiten
        items.append(item("orga", .material, pages: 6, label: "Organisatorisches", chdate: 1))
        items.append(item("fehlt", .material, pages: nil, chdate: 2))
        let all = ExamGeneratorSelection.all(items)
        let c = ExamGeneratorSelection.check(items, selected: all)
        XCTAssertTrue(c.isValid, "\(c.problems)")
        XCTAssertEqual([c.examFiles, c.examSolutions, c.exerciseFiles], [10, 10, 10])
        XCTAssertTrue(all.contains("k12") && all.contains("k3") && !all.contains("k2"), "die neuesten Klausuren")
        XCTAssertTrue(all.contains("u14") && !all.contains("u4"), "die neuesten Übungen")
        // 10 Vorlesungen à 28 = 280, die elfte passt nicht mehr, die kleine Orga-Datei schon (286)
        XCTAssertEqual(c.materialPages, 286)
        XCTAssertTrue(all.contains("v1") && all.contains("v10") && !all.contains("v11") && all.contains("orga"))
        XCTAssertFalse(all.contains("fehlt"))
    }

    // MARK: Endpunkt

    /// Seitenzahl = erstes Byte der Datei (statt PDFKit)
    private struct FirstByteTools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { data.first.map(Int.init) }
        func pdfFromImage(_ data: Data) -> Data? { nil }
    }

    private func call(_ b: LocalBackend, _ path: String, status: Int = 200) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!, body: Data()))
        XCTAssertEqual(r.status, status, "\(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    func testEndpointListsPDFsOfTheModuleWithGroupAndPages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("examgen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = LocalFiles(container: dir, dataDirectory: "", tools: FirstByteTools())
        func put(_ name: String, pages: UInt8) throws { _ = try files.write(Data([pages, 1, 2]), to: name) }
        try put("vl1.pdf", pages: 24); try put("blatt1.pdf", pages: 2); try put("ak.pdf", pages: 6); try put("akl.pdf", pages: 9)
        try put("gemerkt.pdf", pages: 99); try put("fremd.pdf", pages: 3); try put("kaputt.pdf", pages: 0)

        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-17T10:00:00")!, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis', '#175ee8', 0), (2, 'Physik', '#16a34a', 1)")
            try c.execute("""
                INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES
                ('c1', 'Analysis', 'Analysis', 'vorlesung', 1, 1, 't'), ('c2', 'Physik', 'Physik', 'vorlesung', 1, 2, 't'),
                ('alt', 'Analysis alt', 'Analysis', 'vorlesung', 0, 1, 't')
                """)
            let rows: [(String, String, String, String?, Int64?, Int64)] = [
                ("f-vl", "c1", "VL01 Folgen.pdf", "vl1.pdf", nil, 10),
                ("f-ub", "c1", "Blatt 1.pdf", "blatt1.pdf", nil, 20),
                ("f-ak", "c1", "Altklausur WS 24.pdf", "ak.pdf", nil, 30),
                ("f-akl", "c1", "Altklausur WS 24 Lösung.pdf", "akl.pdf", nil, 31),
                ("f-gemerkt", "c1", "Skript.pdf", "gemerkt.pdf", 120, 40),       // gemerkte Seitenzahl gewinnt
                ("f-weg", "c1", "VL02 Reihen.pdf", "nicht-da.pdf", 30, 50),       // nicht auf dem Geraet
                ("f-ohne", "c1", "VL03 Grenzwerte.pdf", nil, nil, 60),             // nie geladen
                ("f-kaputt", "c1", "VL04.pdf", "kaputt.pdf", nil, 70),            // laesst sich nicht lesen
                ("f-zip", "c1", "Daten.zip", "vl1.pdf", nil, 80),                 // keine PDF
                ("f-fremd", "c2", "VL01.pdf", "fremd.pdf", nil, 90),              // anderes Modul
                ("f-alt", "alt", "VL01 alt.pdf", "vl1.pdf", nil, 95),             // alter Kurs
            ]
            for (id, course, name, path, pages, ch) in rows {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status, local_path, page_count) VALUES (?,?,?,?,?,?,?)",
                              [.text(id), .text(course), .text(name), .integer(ch), .text("neu"), path.map(SQLiteValue.text) ?? .null,
                               pages.map(SQLiteValue.integer) ?? .null])
            }
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, local_path, deleted_at) VALUES ('f-papierkorb', 'c1', 'VL09.pdf', 99, 'neu', 'vl1.pdf', 't')")
        }

        let r = await call(b, "/api/modules/1/exam-generator/files")
        XCTAssertEqual(r["limits"]?["material_pages"]?.int, 300)
        XCTAssertEqual(r["limits"]?["exam_files"]?.int, 10)
        XCTAssertEqual(r["limits"]?["exercise_files"]?.int, 10)
        XCTAssertEqual(r["limits"]?["mock_exams"]?.int, 10)
        let items = (r["files"]?.array ?? []).compactMap(Item.init(json:))
        let line = items.map { "\($0.id):\($0.group.rawValue)\($0.isSolution ? "+L" : ""):\($0.pages.map(String.init) ?? "-")" }
        XCTAssertEqual(line, ["f-vl:material:24", "f-ub:exercises:2", "f-ak:exams:6", "f-akl:exams+L:9", "f-gemerkt:material:120",
                              "f-weg:material:-", "f-ohne:material:-", "f-kaputt:material:-"])
        XCTAssertEqual(items.first { $0.id == "f-ak" }?.label, "Altklausur")
        XCTAssertEqual(items.filter(\.isAvailable).map(\.id), ["f-vl", "f-ub", "f-ak", "f-akl", "f-gemerkt"])
        XCTAssertEqual(r["files"]?.array?.first?["available"]?.bool, true)

        let all = ExamGeneratorSelection.all(items)
        XCTAssertEqual(all, ["f-vl", "f-ub", "f-ak", "f-akl", "f-gemerkt"])
        let c = ExamGeneratorSelection.check(items, selected: all, mockExams: 3)
        XCTAssertTrue(c.isValid, "\(c.problems)")
        XCTAssertEqual([c.materialPages, c.examFiles, c.examSolutions, c.exerciseFiles, c.totalPages], [144, 1, 1, 1, 161])

        _ = await call(b, "/api/modules/99/exam-generator/files", status: 404)
    }
}

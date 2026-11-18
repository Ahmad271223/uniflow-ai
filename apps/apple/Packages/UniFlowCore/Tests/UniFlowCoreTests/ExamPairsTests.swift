import Foundation
import XCTest
@testable import UniFlowCore

/// Klausur und Loesung zusammenfuehren (`ExamPairs`) gegen app/exam_pairs.py:
/// packages/shared-contracts/fixtures/local-backend/exam-pairs.json (tools/gen-exam-pairs-fixture.py), dazu das
/// Moduldetail mit `exam_groups` im Block "Klausuren & Altklausuren" und die neue Einordnung im Aufgabenindex.
final class ExamPairsTests: XCTestCase {

    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/exam-pairs.json")))
    }

    private func scalars(_ s: String?) -> [UInt32]? { s.map { $0.unicodeScalars.map(\.value) } }

    func testKeysLikePython() throws {
        let cases = try fixture()["keys"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        for c in cases {
            let name = c["name"]?.string, key = ExamPairs.solutionKey(name)
            XCTAssertEqual(scalars(key), scalars(c["key"]?.string), "key \(name.debugDescription)")
            XCTAssertEqual(scalars(ExamPairs.plainKey(name)), scalars(c["plain"]?.string), "plain \(name.debugDescription)")
            XCTAssertEqual(ExamPairs.numbers(key), (c["numbers"]?.array ?? []).compactMap(\.int), "numbers \(name.debugDescription)")
            XCTAssertEqual(scalars(ExamPairs.tail(key)), scalars(c["tail"]?.string), "tail \(name.debugDescription)")
        }
    }

    func testTermsLikePython() throws {
        let cases = try fixture()["terms"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 35)
        for c in cases {
            let t = ExamPairs.term(folder: c["folder"]?.string, name: c["name"]?.string)
            let expected = c["term"]?.array
            XCTAssertEqual(t?.rank, expected?.first?.int, "\(c["folder"]?.string ?? "-") / \(c["name"]?.string ?? "-")")
            XCTAssertEqual(t?.label, expected?.last?.string, "\(c["folder"]?.string ?? "-") / \(c["name"]?.string ?? "-")")
        }
    }

    private func files(_ c: JSONValue) -> [[String: JSONValue]] { (c["files"]?.array ?? []).compactMap(\.object) }

    func testLinksLikePython() throws {
        let cases = try fixture()["links"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let found = ExamPairs.links(files(c))
            let expected = c["links"]?.object ?? [:]
            XCTAssertEqual(Set(found.keys), Set(expected.keys), c["case"]?.string ?? "")
            for (id, link) in found {
                XCTAssertEqual(link.kind, expected[id]?.array?.first?.string, "\(c["case"]?.string ?? ""): \(id)")
                XCTAssertEqual(link.files, (expected[id]?.array?.last?.array ?? []).compactMap(\.string), "\(c["case"]?.string ?? ""): \(id)")
            }
        }
    }

    func testGroupsLikePython() throws {
        let cases = try fixture()["groups"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for c in cases {
            let all = files(c), ids = Set((c["block"]?.array ?? []).compactMap(\.string))
            let block = all.filter { ids.contains($0["id"]?.string ?? "") }
            let groups = ExamPairs.groups(block, ExamPairs.links(all))
            XCTAssertEqual(JSONValue.array(groups), c["groups"], c["case"]?.string ?? "")
        }
    }

    /// Ordnung, die der Inhaber freigegeben hat: neuester Jahrgang zuerst, jede Klausur mit ihrer Loesung direkt
    /// darunter, Sammel-Loesung am Ende des Jahrgangs, keine Datei verschwindet
    func testOrderOfTheExamBlock() {
        func f(_ id: String, _ name: String, _ folder: String, _ type: String) -> [String: JSONValue] {
            ["id": .string(id), "name": .string(name), "course_id": "k2", "studip_folder": .string(folder), "doc_type": .string(type)]
        }
        let files = [
            f("a1", "KK1.pdf", "Alte Klausuren/WS 22/23", "klausur"), f("a1s", "KK1loes.pdf", "Alte Klausuren/WS 22/23", "loesung"),
            f("a10", "KK10.pdf", "Alte Klausuren/WS 22/23", "klausur"), f("a2", "KK2.pdf", "Alte Klausuren/WS 22/23", "klausur"),
            f("b1", "kk1b.pdf", "Alte Klausuren/WS 23/24", "klausur"), f("b1s", "sol1b.pdf", "Alte Klausuren/WS 23/24", "loesung"),
            f("c1", "KK1.pdf", "Alte Klausuren/WS 20/21", "klausur"), f("c2", "KK2.pdf", "Alte Klausuren/WS 20/21", "klausur"),
            f("cs", "Lösungen.pdf", "Alte Klausuren/WS 20/21", "loesung"), f("x", "Lösung ohne Klausur.pdf", "Alte Klausuren/WS 22/23", "loesung"),
        ]
        let groups = ExamPairs.groups(files, ExamPairs.links(files))
        XCTAssertEqual(groups.compactMap { $0["label"]?.string }, ["WS 23/24", "WS 22/23", "WS 20/21"])
        let rows = groups.map { g in (g["files"]?.array ?? []).map { "\($0["id"]?.string ?? ""):\($0["exam_role"]?.string ?? ""):\($0["solution_of"]?.string ?? "-")" } }
        XCTAssertEqual(rows[0], ["b1:klausur:-", "b1s:loesung:b1"])
        XCTAssertEqual(rows[1], ["a1:klausur:-", "a1s:loesung:a1", "a2:klausur:-", "a10:klausur:-", "x:weitere_loesung:-"])
        XCTAssertEqual(rows[2], ["c1:klausur:-", "c2:klausur:-", "cs:weitere_loesung:-"])
        XCTAssertEqual(rows.flatMap { $0 }.count, files.count, "jede Datei genau einmal")
    }

    // MARK: Moduldetail und Aufgabenindex

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-17T09:00:00")!)
    }

    private func seed(_ c: SQLiteConnection, _ files: [(String, String, String)]) throws {
        try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
        try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k2', 'Übung zu Testmathe I', 'uebung', '2026-10-01', 7, 1)")
        for (id, name, folder) in files {
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, studip_folder) VALUES (?, 'k2', ?, 1676000000, 'pdf', ?)",
                          [.text(id), .text(name), .text(folder)])
        }
    }

    func testDetailOrdersTheExamBlockAndLeavesOtherWeeksAlone() async throws {
        let b = try await backend()
        let clock = UniFlowClock.fixed(berlin: "2026-11-17T09:00:00")!
        let detail = try await b.context.database.transaction { c -> [String: JSONValue]? in
            try self.seed(c, [("e1", "KK1.pdf", "Alte Klausuren/WS 22/23"), ("s1", "KK1loes.pdf", "Alte Klausuren/WS 22/23"),
                              ("e2", "kk3a.pdf", "Alte Klausuren/WS 21/22"), ("s2", "sol3a.pdf", "Alte Klausuren/WS 21/22"),
                              ("e3", "KK2.pdf", "Alte Klausuren/WS 20/21"), ("s3", "Lösungen.pdf", "Alte Klausuren/WS 20/21"),
                              ("u1", "Blatt 3.pdf", "Übungen"), ("u1s", "Lösung Blatt 3.pdf", "Übungen")])
            return try LocalModules.detail(c, moduleID: .integer(7), clock: clock)
        }
        let weeks = detail?["weeks"]?.array ?? []
        let block = try XCTUnwrap(weeks.first { $0["week"]?.int == -2 })
        let groups = block["exam_groups"]?.array ?? []
        XCTAssertEqual(groups.compactMap { $0["label"]?.string }, ["WS 22/23", "WS 21/22", "WS 20/21"])
        XCTAssertEqual(groups.map { ($0["files"]?.array ?? []).compactMap { $0["id"]?.string } }, [["e1", "s1"], ["e2", "s2"], ["e3", "s3"]])
        XCTAssertEqual(groups.first?["files"]?.array?.last?["solution_of"]?.string, "e1")
        XCTAssertEqual(groups.last?["files"]?.array?.last?["exam_role"]?.string, "weitere_loesung")
        XCTAssertEqual(block["count"]?.int, 6)
        XCTAssertEqual((block["klausuren"]?.array ?? []).count + (block["loesungen"]?.array ?? []).count, 6, "Gruppen nach Art bleiben")
        for w in weeks where w["week"]?.int != -2 { XCTAssertNil(w["exam_groups"], "andere Wochen bleiben, wie sie sind") }
    }

    /// "sol3a.pdf" stand vor dem 17.11.2026 als Altklausur im Aufgabenindex. Mit unveraenderter Datei liest der Index
    /// sie jetzt neu (andere Einordnung), sonst bliebe die Klausur fuer immer ohne Loesung.
    func testIndexReadsAFileAgainWhenItsRoleChanged() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.seed(c, [("kx", "kk3a.pdf", "Alte Klausuren/WS 21/22"), ("sx", "sol3a.pdf", "Alte Klausuren/WS 21/22")])
            for (id, text) in [("kx", "Aufgabe 1: Berechnen Sie den Grenzwert der Folge a_n mit genug Text fuer eine Aufgabe."),
                               ("sx", "Aufgabe 1: Der Grenzwert der Folge ist 2, Herleitung mit genug Text fuer eine Aufgabe.")] {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?, 1, ?, 1676000000, ?)",
                              [.text(id), .text(text), .text(ScriptSearch.searchForm(text))])
            }
            let index = ScriptSearch.Index(docs: [], df: [:], avg: 0)             // keine Vorlesung: kein Bezug noetig
            let now = Weekly.seconds("2026-11-17T09:00:00")!
            try Weekly.indexModule(c, 7, index: index, now: now)
            XCTAssertEqual(try c.scalar("SELECT solution_file_id FROM task_index WHERE file_id='kx' AND nr='1'")?.string, "sx")
            // Stand eines Geraets von vorher: die Loesung als Altklausur im Index, Klausur ohne Loesung
            try c.execute("UPDATE task_index SET source='altklausur' WHERE file_id='sx'")
            try c.execute("UPDATE doc_index SET role='altklausur' WHERE file_id='sx'")
            try c.execute("UPDATE task_index SET solution_file_id=NULL, solution_text=NULL")
            let r = try Weekly.indexModule(c, 7, index: index, now: now + 60)
            XCTAssertEqual(r.indexed, 1, "nur die Datei mit neuer Einordnung")
            XCTAssertEqual(try c.scalar("SELECT source FROM task_index WHERE file_id='sx'")?.string, "loesung")
            XCTAssertEqual(try c.scalar("SELECT solution_file_id FROM task_index WHERE file_id='kx' AND nr='1'")?.string, "sx")
        }
    }
}

import XCTest
@testable import UniFlowCore

/// Fruehere Semester (Wunsch des Inhabers 03.11.2026): nur Dateien des aktuellen Semesters, einmal fragen, in der
/// Bibliothek je Semester nachladen (`OlderSemesters`, `OlderSemesterEndpoints`)
final class OlderSemestersTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-03T10:00:00")!
    private var today: String { clock.today }

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let now = clock.nowISO, today = self.today
        try await b.context.database.transaction { c in
            for (id, title, sem) in [("cur", "Testkurs Analysis", "WiSe 2026/27"), ("s26b", "Testkurs Werkstoffe", "SoSe 2026"),
                                     ("s26a", "Testkurs Algebra", "SoSe 2026"), ("w25", "Testkurs Mechanik", "WiSe 2025/26"),
                                     ("own", "Testkurs Statik", "SoSe 2024")] {
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: id, title: title, number: nil, semester: sem), now: now, today: today)
            }
            // alter Kurs, vom Nutzer eingeschaltet: gilt als aktuell (eigene Entscheidung)
            try c.execute("UPDATE courses SET active=1, active_custom=1 WHERE id='own'")
            _ = try UniStore.storeFiles(c, courseID: "w25", [UniStore.FileRow(id: "f1", name: "Blatt 1.pdf", size: 10, mime: "application/pdf",
                                                                               author: nil, chdate: 1, downloadURL: "https://x/f1", folder: "")],
                                        now: now, fileExists: { _ in false })
        }
        return b
    }

    private func json(_ b: LocalBackend, _ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, path: path, headers: ["Content-Type": "application/json"],
                                            body: body.map { Data($0.jsonString(sortedKeys: true).utf8) } ?? Data()))
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(decoding: r.body, as: UTF8.self))")
        return try XCTUnwrap(r.json)
    }

    /// Je frueheres Semester ein Ordner, neuestes zuerst, Kurse nach Titel; aktuelle und eingeschaltete Kurse fehlen
    func testGroupsBySemesterNewestFirst() async throws {
        let b = try await backend()
        let groups = try await b.context.database.withConnection { try OlderSemesters.groups($0, today: self.today) }
        XCTAssertEqual(groups.map(\.label), ["SoSe 2026", "WiSe 2025/26"])
        XCTAssertEqual(groups[0].courses.map(\.id), ["s26a", "s26b"])
        XCTAssertEqual(groups[1].courses.first?.files, 1)
        XCTAssertEqual(groups[1].courses.first?.downloaded, 0)

        let o = try await json(b, "/api/older-semesters")
        XCTAssertEqual(o["current"], "WiSe 2026/27")
        XCTAssertTrue(o["choice"]?.isNull ?? false)
        XCTAssertEqual(o["semesters"]?.array?.map { $0["label"] }, ["SoSe 2026", "WiSe 2025/26"])
        let files = try await json(b, "/api/older-semesters/courses/w25/files")
        XCTAssertEqual(files.array?.map { $0["name"] }, ["Blatt 1.pdf"])
        XCTAssertEqual(files.array?.first?["downloaded"], 0)
        let missing = await b.handle(LocalRequest(method: "GET", path: "/api/older-semesters/courses/gibtsnicht/files"))
        XCTAssertEqual(missing.status, 404)
    }

    /// Vorgabe: nichts frueheres laden; die Frage einmal (danach gilt die Wahl), "Dateien laden" nur fuer den Kurs,
    /// fertig geladen wird er nicht erneut abgefragt; mit "alle" kommen die uebrigen
    func testQuestionOnceRequestAndChoice() async throws {
        let b = try await backend()
        let db = b.context.database
        let today = self.today
        var pending = try await db.withConnection { try OlderSemesters.pending($0, today: today) }
        XCTAssertEqual(pending, [], "Vorgabe: nur das aktuelle Semester")
        var ask = try await db.withConnection { try OlderSemesters.needsQuestion($0, today: today) }
        XCTAssertTrue(ask)

        _ = try await json(b, "/api/older-semesters/choice", method: "POST", body: ["choice": "current"])
        ask = try await db.withConnection { try OlderSemesters.needsQuestion($0, today: today) }
        XCTAssertFalse(ask, "einmal gefragt")
        let bad = await b.handle(LocalRequest(method: "POST", path: "/api/older-semesters/choice", body: Data(#"{"choice":"x"}"#.utf8)))
        XCTAssertEqual(bad.status, 422)

        // "Dateien laden": nur fruehere Kurse zaehlen (der aktuelle und ein unbekannter nicht)
        let r = try await json(b, "/api/older-semesters/request", method: "POST", body: ["course_ids": ["w25", "cur", "gibtsnicht"]])
        XCTAssertEqual(r["requested"], 1)
        pending = try await db.withConnection { try OlderSemesters.pending($0, today: today) }
        XCTAssertEqual(pending, ["w25"])
        let now = clock.nowISO
        try await db.transaction { try OlderSemesters.markLoaded($0, courseIDs: ["w25"], now: now) }
        pending = try await db.withConnection { try OlderSemesters.pending($0, today: today) }
        XCTAssertEqual(pending, [], "fertig geladen: der naechste Abgleich fragt den Kurs nicht erneut ab")

        _ = try await json(b, "/api/older-semesters/choice", method: "POST", body: ["choice": "all"])
        pending = try await db.withConnection { try OlderSemesters.pending($0, today: today) }
        XCTAssertEqual(pending, ["s26a", "s26b"])
        let o = try await json(b, "/api/older-semesters")
        XCTAssertEqual(o["choice"], "all")
    }
}

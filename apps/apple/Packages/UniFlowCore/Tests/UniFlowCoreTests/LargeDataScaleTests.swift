import XCTest
@testable import UniFlowCore

/// Grosse Datenmenge wie ein echtes LUH-Konto (Audit Robustheit 03.11.2026): 212 Kurse ueber 8 Semester, 1000 Dateien,
/// Analysen, Module. Prueft, dass die Seiten der App (Uebersicht, Bibliothek, Module, fruehere Semester, Suche) damit
/// in vertretbarer Zeit antworten und die heissen Abfragen nicht je Kurs die ganze Dateitabelle lesen.
final class LargeDataScaleTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-03T10:00:00")!

    static let semesters = ["WiSe 2026/27", "SoSe 2026", "WiSe 2025/26", "SoSe 2025", "WiSe 2024/25", "SoSe 2024",
                            "WiSe 2023/24", "SoSe 2023"]

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let now = clock.nowISO, today = clock.today
        try await b.context.database.transaction { c in
            for i in 0..<212 {
                let sem = Self.semesters[i % Self.semesters.count]
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: "c\(i)", title: "Testkurs \(i) Vorlesung", number: "\(1000 + i)",
                                                                semester: sem), now: now, today: today)
            }
            for m in 0..<30 {
                try c.execute("INSERT INTO modules(name, semester, color, created_at) VALUES (?, 'WiSe 2026/27', '#336699', ?)",
                              [.text("Modul \(m)"), .text(now)])
            }
            // aktuelle Kurse (i % 8 == 0) je einem Modul zuordnen
            try c.execute("UPDATE courses SET module_id = (CAST(substr(id, 2) AS INTEGER) % 30) + 1 WHERE semester='WiSe 2026/27'")
            for f in 0..<1000 {
                let course = "c\(f % 212)"
                _ = try UniStore.storeFiles(c, courseID: course, [UniStore.FileRow(
                    id: "f\(f)", name: "Blatt \(f) Uebung.pdf", size: 5_500_000, mime: "application/pdf", author: nil,
                    chdate: 1_700_000_000 + f, downloadURL: "https://x/f\(f)", folder: "Ordner \(f % 5)")],
                    now: now, fileExists: { _ in false })
                // geladen und mit Seitentexten (Suche ueber page_texts): 10 Seiten zu rund 2000 Zeichen
                try c.execute("UPDATE files SET local_path=? WHERE id=?", [.text("/tmp/f\(f).pdf"), .text("f\(f)")])
                for p in 1...10 {
                    let text = String(repeating: "Lorem ipsum Integral Matrix Eigenwert \(f) Seite \(p) ", count: 40)
                    try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?, ?, ?, ?, ?)",
                                  [.text("f\(f)"), .integer(Int64(p)), .text(text), .integer(Int64(1_700_000_000 + f)),
                                   .text(ScriptSearch.searchForm(text))])
                }
                if f % 2 == 0 {
                    try c.execute("INSERT INTO analysis(file_id, doc_type, title, topics, created_at) VALUES (?, 'uebung', ?, '[]', ?)",
                                  [.text("f\(f)"), .text("Uebung \(f)"), .text(now)])
                }
            }
        }
        return b
    }

    private func timed(_ b: LocalBackend, _ path: String) async -> (status: Int, seconds: Double) {
        let start = Date()
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!))
        return (r.status, Date().timeIntervalSince(start))
    }

    /// Jede Seite antwortet mit 200 und unter zwei Sekunden (Debug-Build auf dem Mac, gemessen 03.11.2026: alle unter
    /// 0,03 s ausser dem ersten /api/due mit 0,32 s; die Grenze ist grosszuegig, weil der Mac oft unter Last steht)
    func testHotRoutesWithLargeAccount() async throws {
        let b = try await backend()
        var report: [String] = []
        for path in ["/api/dashboard", "/api/library", "/api/modules", "/api/modules/1", "/api/courses", "/api/older-semesters",
                     "/api/older-semesters/courses/c1/files", "/api/due", "/api/due", "/api/news", "/api/search?q=eigenwert%20999", "/api/search?q=gibtsnicht"] {
            let (status, seconds) = await timed(b, path)
            report.append(String(format: "%@ %d %.3f s", path, status, seconds))
            XCTAssertEqual(status, 200, path)
            XCTAssertLessThan(seconds, 2.0, "\(path) zu langsam mit 1000 Dateien und 212 Kursen")
        }
        print("LargeDataScale:\n" + report.joined(separator: "\n"))
    }
}

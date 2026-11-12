import XCTest
@testable import UniFlowCore

/// LSF der Uni Hildesheim (12.11.2026): mehrere Versuche derselben Leistung bleiben getrennt (`QISParser.numberAttempts`)
final class HildesheimGradesAttemptsTests: XCTestCase {
    private func g(_ nr: String, _ text: String, _ note: String?, _ status: String, _ datum: String?, semester: String? = nil) -> QISGrade {
        QISGrade(pruefungsnr: nr, text: text, semester: semester, note: note, status: status, credits: "5", datum: datum)
    }

    func testFailedAndPassedAttemptStaySeparate() {
        let rows = [g("4711", "Statistik I", "5,0", "NB", "20.02.2026"), g("4711", "Statistik I", "2,3", "BE", "28.07.2026"),
                    g("4711", "Statistik I", "2,3", "BE", "28.07.2026"),               // derselbe Eintrag auf zweitem Reiter
                    g("4712", "Lineare Algebra", "1,7", "BE", "01.03.2026")]
        let merged = QISParser.merge(QISParser.numberAttempts(rows))
        XCTAssertEqual(merged.map(\.versuch), ["1", "2", nil])
        XCTAssertEqual(merged.map(\.note), ["5,0", "2,3", "1,7"])
    }

    func testOrderedByDateNotByPage() {
        let rows = [g("1", "Analysis", "3,0", "BE", "10.08.2026"), g("1", "Analysis", "5,0", "NB", "05.02.2026")]
        XCTAssertEqual(QISParser.numberAttempts(rows).map(\.versuch), ["2", "1"])
    }

    func testRowsWithSemesterUnchanged() {
        let rows = [g("1", "Analysis", "3,0", "BE", "10.08.2026", semester: "SoSe 26"), g("1", "Analysis", "5,0", "NB", "05.02.2026", semester: "WiSe 25/26")]
        XCTAssertEqual(QISParser.numberAttempts(rows), rows)
    }
}

import XCTest
@testable import UniFlowCore

/// Befunde des Riesentests vom 03.11.2026 (docs/RIESENTEST-2026-11-03.md) gegen die synthetischen Hochschulen, im Kern:
/// Kurstitel der LUH, die vorher kein gemeinsames Fach ergaben; Pruefungstermin vor Raumhinweis; Kurse ohne
/// Startsemester beim ersten Abgleich. Die Python-Seite prueft tests/test_riesentest_regressions.py, die Parität
/// fixtures/hildesheim/expected.json (HildesheimSyncTests.testRulesMatchPython).
final class RiesentestRegressionTests: XCTestCase {

    func testClassifyUnifiesLUHTitlePatterns() {
        let cases: [(String, String, String)] = [
            ("Übung zur Vorlesung Signale und Systeme", "Signale und Systeme", "uebung"),
            ("Fragestunde zur Vorlesung Mathematik für Ingenieure I", "Mathematik für Ingenieure I", "uebung"),
            ("Tutorien Programmieren I", "Programmieren I", "tutorium"),
            ("Übung Programmieren I - Gruppe 7", "Programmieren I", "uebung"),
            ("Vorlesung und Übung Numerische Mathematik", "Numerische Mathematik", "vorlesung"),
            ("Vorlesung + Übung Technische Mechanik II", "Technische Mechanik II", "vorlesung"),
            ("Grundlagen der Elektrotechnik I (Gruppe B)", "Grundlagen der Elektrotechnik I", "vorlesung"),
            ("Übung Vorlesungsbegleitende Statistik", "Vorlesungsbegleitende Statistik", "uebung"),
            ("Übung zu Grundlagen der Elektrotechnik I", "Grundlagen der Elektrotechnik I", "uebung"),
            ("Tutorium Physik", "Physik", "tutorium"),
        ]
        for (title, subject, kind) in cases {
            let r = UniRules.classify(title)
            XCTAssertEqual(r.subject, subject, title)
            XCTAssertEqual(r.kind, kind, title)
        }
        let family = ["Mathematik für Ingenieure I", "Übung zur Vorlesung Mathematik für Ingenieure I", "Hörsaalübung Mathematik für Ingenieure I",
                      "Gruppenübungen zu Mathematik für Ingenieure I, Tranche 2", "Tutorien Mathematik für Ingenieure I",
                      "Fragestunde zur Vorlesung Mathematik für Ingenieure I", "Übung Mathematik für Ingenieure I - Gruppe 3"]
        XCTAssertEqual(Set(family.map { UniRules.classify($0).subject }), ["Mathematik für Ingenieure I"])
    }

    func testExamAndDeadlineBeatRoomHint() {
        let today = BerlinClock.parseISODate("2026-11-03")!
        for (text, kind) in [("Die Klausur findet am 12.02.2027 um 9 Uhr im Hörsaal F 303 statt.", "pruefung"),
                             ("Abgabe im Raum 101 bis zum 12.11.2026.", "frist"),
                             ("Raumänderung: ab 4.11. in HC.N.0.08 (Hörsaal 4).", "raum")] {
            let dates = Announcements.extractDates(text, posted: today)
            XCTAssertEqual(dates.count, 1, text)
            XCTAssertEqual(dates.first?["kind"]?.string, kind, text)
        }
    }

    /// Ein Kurs ohne `start-semester` (Vorkurs, Dauerveranstaltung) kommt beim ersten Abgleich mit, wie der PC-Abgleich
    /// ihn holt und wie `selection` ihn spaeter von selbst dazunaehme
    func testFirstSelectionKeepsCoursesWithoutSemester() {
        let today = "2026-11-03"
        let courses = [StudIPCourse(id: "a", title: "A", semesterStart: "2026-10-01"), StudIPCourse(id: "alt", title: "Alt", semesterStart: "2026-04-01"),
                       StudIPCourse(id: "vorkurs", title: "Mathe-Vorkurs")]
        XCTAssertEqual(StudIPImport.defaultSelection(courses, today: today), ["a", "vorkurs"])
        XCTAssertEqual(StudIPImport.selection(courses: courses, selected: [], known: nil, today: today).selected, ["a", "vorkurs"])
        // ohne jedes Semester wie bisher alle
        XCTAssertEqual(StudIPImport.defaultSelection([StudIPCourse(id: "x", title: "X")], today: today), ["x"])
    }

    /// Ein Kurs aus einem frueheren Semester, der laut Stud.IP "unbegrenzt" laeuft oder bis ins laufende Semester
    /// reicht, ist aktuell (Semesterregel wie am PC) und gehoert beim ersten Abgleich in die Auswahl; ein abgelaufener
    /// Kurs bleibt draussen und kommt spaeter nur als Hinweis
    func testFirstSelectionTakesCoursesCurrentBySemesterRule() {
        let today = "2026-11-03"
        let courses = [
            StudIPCourse(id: "neu", title: "Neu", semesterTitle: "WiSe 2026/27", semesterStart: "2026-10-01T00:00:00+02:00", semesterEnd: "WiSe 2026/27", semesterEndsAt: "2027-03-31T23:59:00+02:00"),
            StudIPCourse(id: "dauer", title: "Fachschaft", semesterTitle: "SoSe 2024", semesterStart: "2024-04-01T00:00:00+02:00", semesterEnd: "unbegrenzt"),
            StudIPCourse(id: "zweisem", title: "Projekt", semesterTitle: "SoSe 2026", semesterStart: "2026-04-01T00:00:00+02:00", semesterEnd: "WiSe 2026/27", semesterEndsAt: "2027-03-31T23:59:00+02:00"),
            StudIPCourse(id: "alt", title: "Alt", semesterTitle: "SoSe 2026", semesterStart: "2026-04-01T00:00:00+02:00", semesterEnd: "SoSe 2026", semesterEndsAt: "2026-09-30T23:59:00+02:00"),
        ]
        XCTAssertEqual(StudIPImport.defaultSelection(courses, today: today), ["neu", "dauer", "zweisem"])
        let first = StudIPImport.selection(courses: courses, selected: [], known: nil, today: today)
        XCTAssertEqual(first.selected, ["neu", "dauer", "zweisem"])
        // spaeter neu belegt: eine Dauerveranstaltung kommt von selbst dazu, ein abgelaufener Kurs nur als Hinweis
        let later = courses + [StudIPCourse(id: "dauer2", title: "Sport", semesterTitle: "WiSe 2023/24", semesterStart: "2023-10-01T00:00:00+02:00", semesterEnd: "unbegrenzt"),
                               StudIPCourse(id: "alt2", title: "Alt 2", semesterTitle: "SoSe 2025", semesterStart: "2025-04-01T00:00:00+02:00", semesterEnd: "SoSe 2025", semesterEndsAt: "2025-09-30T23:59:00+02:00")]
        let second = StudIPImport.selection(courses: later, selected: first.selected, known: first.known, today: today)
        XCTAssertEqual(second.selected, ["neu", "dauer", "zweisem", "dauer2"])
        XCTAssertEqual(second.newUnselected.map(\.id), ["alt2"])
    }
}

/// 429 und 5xx der JSON:API werden wie Downloads und Learnweb mit `UniRetry` wiederholt; 403/404 nicht (gesperrter Ordner)
final class RiesentestStudIPRetryTests: XCTestCase {
    private final class Scripted: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int]
        private(set) var calls = 0
        init(_ s: [Int]) { statuses = s }
        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            let st = statuses.isEmpty ? 200 : statuses.removeFirst()
            return HTTPReply(status: st, contentType: "application/vnd.api+json", finalURL: url, body: Data(#"{"data":[]}"#.utf8))
        }
    }

    private func client(_ t: Scripted) -> StudIPClient {
        StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 3, delayNanos: { _ in 0 }))
    }

    func testRateLimitAndServerErrorsAreRetried() async throws {
        let t = Scripted([429, 503, 200])
        let c = client(t)
        let (data, _) = try await c.list("jsonapi.php/v1/folders/f/file-refs?page[limit]=500")
        XCTAssertEqual(data.count, 0)
        XCTAssertEqual(t.calls, 3)
        let counted = await c.requestCount
        XCTAssertEqual(counted, 3, "jeder Versuch zaehlt zur Anfragegrenze")
    }

    func testPersistentServerErrorFailsAfterThreeAttempts() async {
        let t = Scripted([503, 503, 503, 200])
        do {
            _ = try await client(t).list("jsonapi.php/v1/courses/c/folders?page[limit]=200")
            XCTFail("sollte scheitern")
        } catch let e as StudIPError {
            XCTAssertEqual(e, .http(status: 503, path: "jsonapi.php/v1/courses/c/folders"))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.calls, 3)
    }

    func testForbiddenIsNotRetried() async {
        let t = Scripted([403])
        do {
            _ = try await client(t).list("jsonapi.php/v1/folders/f/file-refs?page[limit]=500")
            XCTFail("sollte scheitern")
        } catch let e as StudIPError {
            XCTAssertTrue(StudIPClient.isUnreadableFolder(e))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.calls, 1)
    }
}

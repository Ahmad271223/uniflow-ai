import Foundation
import XCTest
@testable import UniFlowCore

/// Uni Hildesheim: dieselben Erwartungen wie die Python-Referenz (tools/gen-hildesheim-fixture.py).
final class HildesheimFixtureTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func text(_ relative: String) throws -> String { String(decoding: try repo(relative), as: UTF8.self) }

    private lazy var expected: JSONValue = try! JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/expected.json"))

    private func opt(_ v: JSONValue?) -> String? { (v == nil || v!.isNull) ? nil : v!.string }

    func testCourseTitlesAndSections() {
        for (title, e) in expected["course-titles"]?.object ?? [:] {
            let r = Learnweb.parseCourseTitle(title)
            XCTAssertEqual(r.semester, e["semester"]?.string, title)
            XCTAssertEqual(r.number, opt(e["number"]), title)
            XCTAssertEqual(r.title, e["title"]?.string, title)
        }
        for c in expected["section-labels"]?.array ?? [] {
            XCTAssertEqual(Learnweb.sectionLabel(c["title"]?.string, number: c["number"]?.int), c["label"]?.string)
        }
        for c in expected["file-ids"]?.array ?? [] {
            XCTAssertEqual(Learnweb.fileID(cmid: String(c["cmid"]?.int ?? 0), filepath: c["filepath"]?.string ?? "",
                                           filename: c["filename"]?.string ?? ""), c["id"]?.string)
        }
    }

    func testLearnwebRestContents() throws {
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        let files = Learnweb.filesFromContents(contents)
        let want = expected["learnweb-course-contents.json"]?.array ?? []
        XCTAssertEqual(files.count, want.count)
        for (f, w) in zip(files, want) {
            XCTAssertEqual(f.id, w["id"]?.string)
            XCTAssertEqual(f.name, w["name"]?.string)
            XCTAssertEqual(f.size, w["size"]?.int)
            XCTAssertEqual(f.mime, opt(w["mime"]))
            XCTAssertEqual(f.chdate, w["chdate"]?.int)
            XCTAssertEqual(f.revision, w["revision"]?.int)
            XCTAssertEqual(f.downloadURL, w["download_url"]?.string)
            XCTAssertEqual(f.folder, w["folder"]?.string)
        }
    }

    func testPluginfileTokenAndFolderLinks() {
        for c in expected["pluginfile"]?.array ?? [] {
            let p = Learnweb.parsePluginfile(c["url"]?.string ?? "")
            let w = c["parsed"]
            if w == nil || w!.isNull { XCTAssertNil(p); continue }
            XCTAssertEqual(p?.area, w?["area"]?.string)
            XCTAssertEqual(p?.revision, w?["revision"]?.int)
            XCTAssertEqual(p?.filepath, w?["filepath"]?.string)
            XCTAssertEqual(p?.filename, w?["filename"]?.string)
        }
        // "token-download" (`learnweb.token_request`) prueft LearnwebTests.testDownloadKeepsTokenOutOfEveryAddress: der
        // Schluessel geht auf beiden Seiten im Koerper mit, nie in der Adresse
        let fh = expected["folder-html"]
        XCTAssertEqual(Learnweb.folderLinks(html: fh?["html"]?.string ?? ""), (fh?["links"]?.array ?? []).compactMap { $0.string })
    }

    func testLearnwebSessionState() {
        let s = expected["session-state"]
        let links = s?["links"]?.object ?? [:]
        let pick = { (cmid: String) in (links[cmid]?.array ?? []).compactMap { $0.string } }
        let files = Learnweb.filesFromState(s?["state"] ?? .null, resourceLinks: pick, folderLinks: pick)
        let want = s?["files"]?.array ?? []
        XCTAssertEqual(files.count, want.count)
        for (f, w) in zip(files, want) {
            XCTAssertEqual([f.id, f.name, f.downloadURL, f.folder], [w["id"], w["name"], w["download_url"], w["folder"]].map { $0?.string ?? "" })
            XCTAssertEqual(f.chdate, w["chdate"]?.int)
            XCTAssertEqual(f.size, w["size"]?.int)
            XCTAssertEqual(f.revision, w["revision"]?.int)
            XCTAssertNil(f.chdate, "die Sitzung kennt keine Aenderungszeit")
        }
    }

    func testSemesterAndLearnwebInstance() {
        for (day, label) in expected["semester-labels"]?.object ?? [:] {
            let p = day.split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(Learnweb.semesterLabel(year: p[0], month: p[1]), label.string, day)
        }
        let names = expected["learnweb-discover"]?["names"]?.object ?? [:]
        for c in expected["learnweb-discover"]?["cases"]?.array ?? [] {
            let p = (c["today"]?.string ?? "").split(separator: "-").compactMap { Int($0) }
            let alive = Set((c["alive"]?.array ?? []).compactMap { $0.int })
            let base = Learnweb.discoverBase(year: p[0], month: p[1]) { base in
                let y = Int(base.suffix(4)) ?? 0
                return alive.contains(y) ? names[String(y)]?.string : nil
            }
            XCTAssertEqual(base, c["base"]?.string, c["today"]?.string ?? "")
        }
        XCTAssertEqual(Learnweb.discoverBase(year: 2027, month: 4, override: "https://x/lw//") { _ in nil }, "https://x/lw")
        XCTAssertNil(Learnweb.discoverBase(year: 2027, month: 4) { _ in nil })
    }

    func testCAS() {
        let cas = expected["cas"]
        XCTAssertEqual(HildesheimCAS.loginURL(service: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1"), cas?["login_url"]?.string)
        XCTAssertEqual(HildesheimCAS.lsfLoginURL, cas?["login_url"]?.string)
        for c in cas?["is_cas_page"]?.array ?? [] {
            XCTAssertEqual(HildesheimCAS.isCASPage(c["url"]?.string ?? ""), c["result"]?.bool, c["url"]?.string ?? "")
        }
    }

    func testLSFCalendarCourseAndPlan() throws {
        let course = LSFCalendar.parseICS(try text("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics"))
        let plan = LSFCalendar.planEntries(try text("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        for (got, want, withNames) in [(course, expected["lsf-course.ics"]?.array ?? [], false), (plan, expected["lsf-plan.ics"]?.array ?? [], true)] {
            XCTAssertEqual(got.count, want.count)
            for (e, w) in zip(got, want) {
                XCTAssertEqual(e.weekday, w["weekday"]?.int, e.title)
                XCTAssertEqual(e.startTime, w["start_time"]?.string, e.title)
                XCTAssertEqual(e.endTime, w["end_time"]?.string, e.title)
                XCTAssertEqual(e.rrule, w["rrule"]?.string, e.title)
                XCTAssertEqual(e.dateFrom, w["date_from"]?.string, e.title)
                XCTAssertEqual(e.dateTo, opt(w["date_to"]), e.title)
                XCTAssertEqual(e.exdates, (w["exdates"]?.array ?? []).compactMap { $0.string }, e.title)
                if withNames {
                    XCTAssertEqual(e.title, w["title"]?.string)
                    XCTAssertEqual(e.number, opt(w["number"]))
                    XCTAssertEqual(e.lecturer, w["lecturer"]?.string)
                }
            }
        }
    }

    func testLSFSummaryAndPlanLink() {
        for c in expected["lsf-summary"]?.array ?? [] {
            let s = LSFCalendar.splitSummary(c["summary"]?.string ?? "")
            XCTAssertEqual(s.number, opt(c["number"]), c["summary"]?.string ?? "")
            XCTAssertEqual(s.title, c["title"]?.string, c["summary"]?.string ?? "")
            XCTAssertEqual(s.lecturer, c["lecturer"]?.string, c["summary"]?.string ?? "")
        }
        for c in expected["lsf-plan-link"]?.array ?? [] {
            XCTAssertEqual(LSFCalendar.planICSLink(html: c["html"]?.string ?? ""), opt(c["link"]))
        }
    }

    func testGradeRowsHildesheimLayout() {
        let g = expected["grade-rows"]
        let rows = (g?["rows"]?.array ?? []).map { ($0.array ?? []).compactMap { $0.string } }
        let got = GradeRows.parse(rows: rows, abschluss: g?["abschluss"]?.string ?? "")
        let want = g?["grades"]?.array ?? []
        XCTAssertEqual(got.count, want.count)
        for (a, w) in zip(got, want) {
            let fields: [String: String?] = ["pruefungsnr": a.pruefungsnr, "text": a.text, "note": a.note, "status": a.status,
                                             "credits": a.credits]
            for (k, v) in fields { XCTAssertEqual(v, opt(w[k]), k) }
            XCTAssertEqual(a.abschluss, w["abschluss"]?.string)
        }
    }

    func testShareKeyMatchesPython() throws {
        let doc = try JSONValue.parse(repo("packages/shared-contracts/fixtures/testshare/cases.json"))
        XCTAssertEqual(doc["version"]?.string, TestShare.version)
        XCTAssertEqual((doc["minute_steps"]?.array ?? []).compactMap { $0.int }, TestShare.minuteSteps)
        for c in doc["cases"]?.array ?? [] {
            let key = TestShare.shareKey(university: c["university"]?.string ?? "", minutes: c["minutes"]?.int,
                                         contentHashes: (c["materials"]?.array ?? []).map { $0.string })
            XCTAssertEqual(key, c["expected_key"]?.string, c["name"]?.string ?? "")
        }
        XCTAssertNil(TestShare.shareKey(university: "luh", minutes: 45, contentHashes: ["a", nil]))
        XCTAssertEqual([10, 15, 16, 45, 61, 500, nil, 0].map(TestShare.minutesBucket), [15, 15, 30, 45, 90, 120, 45, 45])
    }
}

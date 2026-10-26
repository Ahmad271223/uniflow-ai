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

// MARK: - Fristen, Feiertage, Ankuendigungen, LSF-Bemerkungen (PC-Stand 26.10.2026)

/// Dieselben Erwartungen wie tests/test_hildesheim.py, test_holidays.py und test_announcements.py an die neuen
/// Schluessel in expected.json: Learnweb-Fristen (`deadlines_from_events`, `deadline_kind`, `short_deadline_title`,
/// `local_iso`), Feiertage und Markierungen je Tag (`public_holidays`, `day_marks`), Termine in Ankuendigungen
/// (`extract_dates`, Forumsseiten, `from_forum_post`) und LSF-Bemerkungen (`note_text`, `is_placeholder`).
final class HildesheimPortFixtureTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func text(_ relative: String) throws -> String { String(decoding: try repo(relative), as: UTF8.self) }

    private lazy var expected: JSONValue = try! JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/expected.json"))

    private func opt(_ v: JSONValue?) -> String? { (v == nil || v!.isNull) ? nil : v!.string }

    func testLearnwebDeadlinesMatchPython() throws {
        let events = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-calendar-events.json"))["events"]?.array ?? []
        let got: JSONValue = .array(Learnweb.deadlinesFromEvents(events).map(\.json))
        XCTAssertEqual(got, expected["learnweb-deadlines"], jsonDiff(got, expected["learnweb-deadlines"]) ?? "")
        XCTAssertEqual(got.array?.count, 6, "doppeltes Ereignis einmal, ohne Zeit weg")
        for c in expected["deadline-kinds"]?.array ?? [] {
            XCTAssertEqual(Learnweb.deadlineKind(module: opt(c["module"]), eventtype: opt(c["eventtype"])), c["kind"]?.string, "\(c)")
        }
        for c in expected["deadline-titles"]?.array ?? [] {
            XCTAssertEqual(Learnweb.shortDeadlineTitle(c["title"]?.string ?? ""), c["short"]?.string, c["title"]?.string ?? "")
        }
        for c in expected["local-iso"]?.array ?? [] {
            XCTAssertEqual(Learnweb.localISO(c["ts"]?.int ?? 0), c["local"]?.string, "Sommer-/Winterzeit wie zoneinfo")
        }
    }

    func testHolidaysAndDayMarksMatchPython() {
        for (year, days) in expected["nds-holidays"]?.object ?? [:] {
            var got: [String: JSONValue] = [:]
            for (d, name) in Holidays.publicHolidays(year: Int(year) ?? 0) { got[d] = .string(name) }
            XCTAssertEqual(JSONValue.object(got), days, year)
        }
        for (uni, spans) in expected["day-marks"]?.object ?? [:] {
            for (span, want) in spans.object ?? [:] {
                let parts = span.components(separatedBy: "..")
                let a = BerlinClock.parseISODate(parts[0]) ?? 0, b = BerlinClock.parseISODate(parts[1]) ?? 0
                let got: JSONValue = .object(Holidays.dayMarks(from: a, to: b, university: uni).mapValues(JSONValue.array))
                XCTAssertEqual(got, want, "\(uni) \(span): \(jsonDiff(got, want) ?? "")")
            }
        }
        XCTAssertTrue(Holidays.lectureFree(day: BerlinClock.parseISODate("2026-12-24")!, university: "luh"))
        XCTAssertFalse(Holidays.lectureFree(day: BerlinClock.parseISODate("2026-11-04")!, university: "luh"))
        XCTAssertEqual(Holidays.defaultTerm(university: "hildesheim", today: "2026-10-25")?.name, "WiSe 2026/27")
        XCTAssertNil(Holidays.defaultTerm(university: "luh", today: "2031-01-01"))
    }

    func testAnnouncementDatesMatchPython() {
        for c in expected["announcement-dates"]?.array ?? [] {
            let posted = BerlinClock.parseISODate(c["posted"]?.string ?? "") ?? 0
            let got: JSONValue = .array(Announcements.extractDates(c["text"]?.string ?? "", posted: posted))
            XCTAssertEqual(got, c["dates"], "\(c["text"]?.string ?? ""): \(jsonDiff(got, c["dates"]) ?? "")")
        }
    }

    func testForumPagesMatchPython() throws {
        let page = try text("packages/shared-contracts/fixtures/hildesheim/learnweb-forum-discussion.html")
        let posts = Announcements.parseDiscussionHTML(page)
        let want = expected["forum-discussion"]?.array ?? []
        XCTAssertEqual(posts.count, want.count)
        for (p, w) in zip(posts, want) {
            XCTAssertEqual(p.id, w["id"]?.int)
            XCTAssertEqual(p.subject, w["subject"]?.string)
            XCTAssertEqual(p.author, w["author"]?.string)
            XCTAssertEqual(p.postedAt, w["posted_at"]?.string)
            XCTAssertEqual(Announcements.htmlToText(p.html), w["text"]?.string)
        }
        let view = try text("packages/shared-contracts/fixtures/hildesheim/learnweb-forum-view.html")
        XCTAssertEqual(JSONValue.array(Announcements.discussionLinks(view).map { .number(Double($0)) }), expected["forum-view"])
        XCTAssertTrue(Announcements.isNewsForum(bodyClass: Learnweb.bodyClass(html: view)))
        XCTAssertFalse(Announcements.isNewsForum(bodyClass: "path-mod-forum forumtype-general"))
        let a = Announcements.fromForumPost(posts[0], courseID: "lw-39", base: "https://www.uni-hildesheim.de/learnweb2026", discussionID: 5838,
                                            today: BerlinClock.parseISODate("2026-10-27")!)
        let got: JSONValue = ["id": .string(a.id), "title": .string(a.title), "text": .string(a.text), "author": .string(a.author),
                              "posted_at": .string(a.postedAt), "url": a.url.map(JSONValue.string) ?? .null,
                              "discussion": a.discussion.map(JSONValue.string) ?? .null, "dates": .array(a.dates)]
        XCTAssertEqual(got, expected["forum-announcement"], jsonDiff(got, expected["forum-announcement"]) ?? "")
    }

    func testLSFNotesMatchPython() {
        for c in expected["lsf-notes"]?.array ?? [] {
            let note = LSFCalendar.noteText(c["description"]?.string)
            XCTAssertEqual(note, c["note"]?.string, c["description"]?.string ?? "")
            XCTAssertEqual(LSFCalendar.isPlaceholder(note), c["placeholder"]?.bool, note)
        }
    }
}

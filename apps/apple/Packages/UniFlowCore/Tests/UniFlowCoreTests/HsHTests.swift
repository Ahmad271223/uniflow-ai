import Foundation
import XCTest
@testable import UniFlowCore

/// Hochschule Hannover: Profil, HISinOne-Leser und der Abgleich (Moodle + Campusmanagement) gegen nachgebaute Seiten
/// (packages/shared-contracts/fixtures/hsh, NACHGEBAUT, erfundene Daten; dieselben Dateien liest tests/test_hsh.py).
/// Kein echtes Netz.
final class HsHTests: XCTestCase {
    let moodle = "https://moodle.hs-hannover.de"
    let campus = "https://campusmanagement.hs-hannover.de"
    let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })

    private func repo(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    private func fx(_ name: String) throws -> String { try repo("packages/shared-contracts/fixtures/hsh/\(name)") }

    // MARK: Profil

    func testProfileMatchesPython() throws {
        let p = UniversityProfile.hsh
        XCTAssertEqual(UniversityKey(rawValue: "hsh"), .hsh)
        XCTAssertEqual(p.name, "Hochschule Hannover")
        XCTAssertEqual(p.filesSource, "Moodle")
        XCTAssertEqual(p.learnwebBase?.absoluteString, moodle)
        XCTAssertNil(p.studipBase)
        XCTAssertFalse(p.qisDocuments)
        XCTAssertEqual(p.tokenKeychainAccount(service: "ical", userScope: "u1"), "u1.hsh.ical.token")
        XCTAssertNil(UniversityProfile.luh.tokenKeychainAccount(service: "ical"), "kein Rueckfall auf eine andere Hochschule")
        XCTAssertTrue(UniversityProfile.isRetiredLoginSecret("u1.hsh.moodle.password"))
        // Anmeldeorte: Moodle-Formular und der SAML-IdP, nie das versteckte Dialogfeld von HISinOne
        XCTAssertTrue(p.loginService("moodle")!.allows(URL(string: "\(moodle)/login/index.php")))
        XCTAssertTrue(p.loginService("campus")!.allows(URL(string: "https://idp.hs-hannover.de/simplesaml/module.php/saml/idp/singleSignOnService?x=1")))
        XCTAssertFalse(p.loginService("campus")!.allows(URL(string: "\(campus)/qisserver/rds?state=user&type=1&category=auth.login")))
        XCTAssertFalse(p.loginService("moodle")!.allows(URL(string: "http://moodle.hs-hannover.de/login/index.php")))
        // Dienste wie HSH_SERVICES in Python (Schluessel und Reihenfolge)
        XCTAssertEqual(p.services.map(\.key), ["moodle", "campusmanagement", "accounts", "mail", "it", "termine", "mensa", "uni"])
        // Geraete-Anmeldeprofil (launch.json, tools/gen-learnweb-fixture.py)
        let launch = try JSONValue.parse(Data(repo("packages/shared-contracts/fixtures/learnweb/launch.json").utf8))
        let prof = launch["profiles"]?["hsh"]
        XCTAssertEqual(prof?["login_url"]?.string, p.loginService("moodle")?.entryURLs.first?.absoluteString)
        XCTAssertEqual(prof?["campus_login_url"]?.string, UniversityProfile.hshCampusLogin.absoluteString)
        XCTAssertEqual(prof?["campus_start_url"]?.string, UniversityProfile.hshCampusStart.absoluteString)
    }

    func testCourseTitlesOfTheHsHMoodle() {
        let t = Learnweb.parseCourseTitle("Programmieren 1, WiSe 2026/27, Prof. Muster")
        XCTAssertEqual([t.semester, t.title], ["WiSe 2026/27", "Programmieren 1"])
        let h = Learnweb.parseCourseTitle("SoSe 2026: 9406 Theorien")       // Hildesheim unveraendert
        XCTAssertEqual([h.semester, h.number, h.title], ["SoSe 2026", "9406", "9406 Theorien"])
    }

    func testSemesterDates() {
        let hsh = Holidays.semesters["hsh"] ?? []
        XCTAssertEqual(hsh.first?.name, "WiSe 2026/27")
        XCTAssertEqual(hsh.first?.start, "2026-09-21")
        XCTAssertEqual(hsh.first?.end, "2027-01-31")
    }

    // MARK: HISinOne-Leser

    func testLoginDetectionIgnoresHiddenSessionDialog() throws {
        let on = try fx("hisinone-start-angemeldet.html"), off = try fx("hisinone-start-abgemeldet.html")
        let url = UniversityProfile.hshCampusStart
        XCTAssertTrue(on.contains("name=\"fdsa\"") && off.contains("name=\"fdsa\""))
        XCTAssertTrue(HISinOne.isLoggedIn(html: on, url: url))
        XCTAssertFalse(HISinOne.isLoginPage(html: on))
        XCTAssertFalse(HISinOne.isLoggedIn(html: off, url: url))
        XCTAssertTrue(HISinOne.isLoginPage(html: off))
        XCTAssertFalse(HISinOne.isLoggedIn(html: on, url: URL(string: "https://evil.example/qisserver/")))
    }

    func testTimetableSubscriptionLink() throws {
        let link = try XCTUnwrap(HISinOne.icalLink(html: fx("hisinone-stundenplan.html")))
        XCTAssertTrue(link.absoluteString.hasPrefix("\(campus):443\(HISinOne.exportPath)?user="))
        XCTAssertFalse(link.absoluteString.contains("&amp;"))
        XCTAssertTrue(HISinOne.isExportURL(link))
        XCTAssertFalse(HISinOne.isExportURL(URL(string: "https://evil.example\(HISinOne.exportPath)?user=a&hash=b")))
        XCTAssertNil(HISinOne.icalLink(html: "<p>kein Export</p>"))
        let entries = HISinOne.planEntries(ics: try fx("stundenplan.ics"))
        XCTAssertEqual(entries.map(\.title), ["Programmieren 1 - Vorlesung", "Mathematik 1 - Übung"])
        XCTAssertEqual(entries.map(\.weekday), [0, 3])
        XCTAssertEqual(entries.map(\.rrule), ["weekly", "once"])
    }

    func testGradesFromTheTreeTable() throws {
        let g = HISinOne.grades(html: try fx("hisinone-leistungen.html"))
        XCTAssertEqual(g.map(\.pruefungsnr), ["100100", "100110", "100120", "200100", "300100"], "jede Leistung einmal")
        let p = g[1]
        XCTAssertEqual([p.text, p.note, p.status, p.credits, p.versuch, p.datum],
                       ["Programmieren 1 (Klausur)", "1,7", "bestanden", "5,0", "1", "20.02.2026"])
        XCTAssertTrue(g.allSatisfy { $0.abschluss == "Bachelor Angewandte Informatik (PO 2019)" })
        XCTAssertFalse(g.contains { $0.raw.contains("Erika") || $0.raw.contains("0000000") }, "keine Stammdaten")
    }

    func testExamRowsAreReadOnly() throws {
        let r = HISinOne.examRows(html: try fx("hisinone-pruefungen-anmelden.html"))
        XCTAssertEqual(r.map(\.number), ["100110", "200110", "300120"])
        XCTAssertEqual(r.map(\.state), [.registered, .open, .registered])
        XCTAssertEqual(r[0].title, "Programmieren 1 (Klausur)")
        XCTAssertTrue(r[0].hint.contains("zugelassen"))
    }

    func testIframeSourceStaysOnCampusHost() throws {
        let src = try XCTUnwrap(HISinOne.iframeSource(html: fx("hisinone-iframe.html")))
        XCTAssertTrue(src.absoluteString.hasPrefix("\(campus):443/qisserver/rds?state=redirect&sso=qis"))
        XCTAssertNil(HISinOne.iframeSource(html: #"<iframe src="https://evil.example/x"></iframe>"#))
    }

    // MARK: Abgleich (Moodle + Campusmanagement) gegen nachgebaute Antworten

    private func container(_ uni: UniversityKey = .hsh) async throws -> (SQLiteDatabase, DataContainerLayout) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hsh-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: "001234.erfunden.0002", university: uni))
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_793_000_000))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: uni.rawValue)
        return (db, layout)
    }

    private func campusRoutes(_ t: FakeUniTransport) throws {
        let link = try XCTUnwrap(HISinOne.icalLink(html: fx("hisinone-stundenplan.html")))
        t.on(HISinOne.timetableURL.absoluteString, ok(try fx("hisinone-stundenplan.html")))
        t.on(link.absoluteString, ok(try fx("stundenplan.ics")))
        t.on(HISinOne.gradesURL.absoluteString, ok(try fx("hisinone-leistungen.html")))
        t.on(HISinOne.examRegistrationURL.absoluteString, ok(try fx("hisinone-pruefungen-anmelden.html")))
    }

    private func moodleRoutes(_ t: FakeUniTransport) {
        t.on("\(moodle)/my/courses.php", ok(#"<script>M.cfg = {"sesskey":"hsh123","wwwroot":"x"};</script>"#))
        let state: JSONValue = .object(["section": .array([.object(["id": .string("11"), "number": .number(1), "title": .string("1")])]),
                                        "cm": .array([.object(["id": .string("7"), "module": .string("resource"), "name": .string("Folien"), "sectionid": .string("11")])])])
        t.on("\(moodle)/lib/ajax/service.php?sesskey=hsh123&info=core_course_get_enrolled_courses_by_timeline_classification",
             okJSON(.array([.object(["error": .bool(false), "data": .object(["courses": .array([
                .object(["id": .number(501), "fullname": .string("Programmieren 1, WiSe 2026/27, Prof. Muster")])])])])])))
        t.on("\(moodle)/lib/ajax/service.php?sesskey=hsh123&info=core_courseformat_get_state",
             okJSON(.array([.object(["error": .bool(false), "data": .string(state.jsonString())])])))
        t.on("\(moodle)/lib/ajax/service.php", okJSON(.array([.object(["error": .bool(false), "data": .object(["events": .array([])])])])))
        t.on("\(moodle)/mod/resource/view.php?id=7", UniResponse(status: 303, headers: ["Location": "\(moodle)/pluginfile.php/5/mod_resource/content/4/Folien.pdf"]))
        t.on("\(moodle)/pluginfile.php/5/mod_resource/content/4/Folien.pdf", UniResponse(status: 200, headers: ["Content-Type": "application/pdf"], body: Data("%PDF-1.4 erfunden".utf8)))
    }

    func testSyncWritesMoodleTimetableGradesAndUsesHsHNames() async throws {
        let (db, layout) = try await container()
        let t = FakeUniTransport()
        try campusRoutes(t)
        moodleRoutes(t)
        let campusClient = HISinOneClient(transport: t, retry: noWait)
        let sync = HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: moodle, mode: .session, transport: t, retry: noWait),
                                  lsf: campusClient, transport: t, retry: noWait, names: .hsh)
        let r = await sync.run()
        XCTAssertNil(r.refused)
        XCTAssertEqual(r.courses, 1)
        XCTAssertEqual(r.grades, 5)
        XCTAssertEqual(r.plan?.new, 2)
        XCTAssertTrue(r.messages.contains { $0.contains("Moodle-Kursen") }, "\(r.messages)")
        XCTAssertFalse(r.messages.joined().contains("Learnweb"), "\(r.messages)")
        let title = try await db.scalar("SELECT title FROM courses WHERE id='lw-501'")?.string
        XCTAssertEqual(title, "Programmieren 1")
        let found = await campusClient.foundICal
        XCTAssertTrue(HISinOne.isExportURL(found))
        // nie Anmelde-/Abmeldeknoepfe: nur GET
        XCTAssertTrue(t.requests.allSatisfy { $0.body == nil || $0.url.absoluteString.contains("/lib/ajax/") }, "keine Formulare")
    }

    func testExpiredCampusSessionUsesTheSavedSubscription() async throws {
        let (db, layout) = try await container()
        let t = FakeUniTransport()
        let link = try XCTUnwrap(HISinOne.icalLink(html: fx("hisinone-stundenplan.html")))
        // abgelaufen: HISinOne leitet zum IdP
        t.on(campus, ok("<html>Anmeldung</html>", url: "https://idp.hs-hannover.de/simplesaml/module.php/saml/idp/singleSignOnService"))
        t.on(link.absoluteString, ok(try fx("stundenplan.ics")))
        let sync = HildesheimSync(db: db, container: layout, learnweb: nil,
                                  lsf: HISinOneClient(transport: t, retry: noWait, savedICal: link), transport: t, retry: noWait, names: .hsh)
        let r = await sync.run()
        XCTAssertEqual(r.plan?.new, 2, "Stundenplan ueber die gemerkte Abo-Adresse")
        XCTAssertEqual(r.needsLogin, ["Campusmanagement"], "Leistungen brauchen die Anmeldung")
        // ohne gemerkte Adresse: Anmeldung noetig, keine Serie entfernt
        let r2 = await HildesheimSync(db: db, container: layout, learnweb: nil, lsf: HISinOneClient(transport: t, retry: noWait),
                                      transport: t, retry: noWait, names: .hsh).run()
        XCTAssertEqual(r2.needsLogin, ["Campusmanagement"])
        let n = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(n, 2)
    }

    func testRegistrationsReadOnlyFromHISinOne() async throws {
        let t = FakeUniTransport()
        try campusRoutes(t)
        t.on(HISinOne.qisIframeURL.absoluteString, ok(#"<a href="?category=auth.logout">Abmelden</a>"#))   // kein altes QIS
        let rows = try await HISinOneClient(transport: t, retry: noWait).registrations()
        XCTAssertEqual(rows.map(\.pruefungsnr), ["100110", "300120"])
        XCTAssertTrue(rows.allSatisfy(\.registered))
    }

    func testOldQISFallbackForGrades() async throws {
        let t = FakeUniTransport()
        t.on(HISinOne.gradesURL.absoluteString, ok(#"<a href="/qisserver/rds?state=user&type=3&category=auth.logout">Abmelden</a><h1>Leistungen</h1>"#))
        t.on(HISinOne.qisIframeURL.absoluteString, ok(try fx("hisinone-iframe.html")))
        let icms = "https://icms.hs-hannover.de/qisserver/rds"
        // SSO-Weiterleitung landet im alten QIS (nachgebaut wie die QIS-Seiten der LUH)
        t.on("\(campus):443/qisserver/rds?state=redirect", ok("""
            <a href="\(icms)?state=user&type=4&re=last&category=auth.logout">Abmelden</a>
            <a href="\(icms)?state=notenspiegelStudent&next=tree.vm&nextdir=qispos/notenspiegel/student&menuid=notenspiegelStudent&asi=A1">Notenspiegel</a>
            """, url: "\(icms)?state=user&type=0"))
        t.on("\(icms)?state=notenspiegelStudent", ok("""
            <a href="\(icms)?state=user&type=4&re=last&category=auth.logout">Abmelden</a>
            <table><tr><th>Prüfungsnr.</th><th>Prüfungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th></tr>
            <tr><td>4711</td><td>Erfundene Klausur</td><td>WiSe 26/27</td><td>2,0</td><td>bestanden</td><td>5</td></tr></table>
            """, url: "\(icms)?state=notenspiegelStudent&next=tree.vm"))
        let g = try await HISinOneClient(transport: t, retry: noWait).grades()
        XCTAssertEqual(g.map(\.text), ["Erfundene Klausur"])
        XCTAssertEqual(g.first?.note, "2,0")
    }

    func testSyncRefusesAnotherUniversitysContainer() async throws {
        let (db, layout) = try await container(.hildesheim)
        let r = await HildesheimSync(db: db, container: layout, learnweb: nil, lsf: HISinOneClient(transport: FakeUniTransport()),
                                     transport: FakeUniTransport(), names: .hsh).run()
        XCTAssertNotNil(r.refused)
    }
}

/// Studienservice und Aufgabenstatus (Nachtrag 2 und 3), nachgebaute Seiten
final class HsHStudyServiceTests: XCTestCase {
    private func fx(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/\(name)"), encoding: .utf8)
    }

    func testStudyServicePageAndTabs() throws {
        let html = try fx("hsh/hisinone-studienservice.html")
        XCTAssertEqual(HISinOneStudyService.reregistration(html: html), "Rückgemeldet für Wintersemester 2026/27")
        let p = HISinOneStudyService.programs(html: html)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual([p[0].group, p[0].subject, p[0].code, p[0].po], ["Bachelor - Erststudium", "Angewandte Informatik", "Hauptfach", "2019"])
        XCTAssertEqual(p[0].semester, 3)
        XCTAssertEqual(p[0].label, "Bachelor Angewandte Informatik (PO-Version 2019)")
        let tab = try XCTUnwrap(HISinOneStudyService.tabRequest(html: html, label: "Zahlungen"))
        XCTAssertEqual(tab.url.absoluteString, "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/stu/studyService/start.xhtml")
        XCTAssertTrue(tab.fields.contains { $0 == ("javax.faces.ViewState", "e1s1-ERFUNDEN") })
        XCTAssertTrue(tab.fields.contains { $0 == ("studyServiceForm:tab2", "Zahlungen") })
        XCTAssertFalse(tab.fields.contains { $0.0 == "studyServiceForm:tab1" }, "nur der eine Reiter")
        XCTAssertEqual(HISinOneStudyService.openPayments(html: try fx("hsh/hisinone-studienservice-zahlungen.html")), 0)
        XCTAssertEqual(HISinOneStudyService.documents(html: try fx("hsh/hisinone-studienservice-bescheide.html")), 0)
        XCTAssertFalse(HISinOneStudyService(reregistration: nil, programs: p, openPayments: 0, documents: 0).json.jsonString().contains("Erika"),
                       "keine Personendaten")
    }

    func testClientReadsStudyServiceAndStoresProgramForCatalog() async throws {
        let t = FakeUniTransport()
        let main = try fx("hsh/hisinone-studienservice.html")
        t.on(HISinOneStudyService.url.absoluteString, ok(main))
        let action = "https://campusmanagement.hs-hannover.de/qisserver/pages/cm/stu/studyService/start.xhtml"
        t.on(action, body: "tab2=Zahlungen", ok(try fx("hsh/hisinone-studienservice-zahlungen.html")))
        t.on(action, body: "tab3=Bescheide", ok(try fx("hsh/hisinone-studienservice-bescheide.html")))
        let s = try await HISinOneClient(transport: t, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 })).studyService()
        XCTAssertEqual(s.openPayments, 0)
        XCTAssertEqual(s.documents, 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hshss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_793_000_000)), university: "hsh")
        try await db.transaction { c in
            try UniStore.storeGrades(c, [QISGrade(pruefungsnr: "1", text: "Erfunden", note: "1,0", status: "bestanden", abschluss: "Bachelor Angewandte Informatik (PO 2019)")], now: "t")
            try HISinOneStudyService.store(c, s, now: "t")
        }
        let ab = try await db.scalar("SELECT abschluss FROM grades")?.string
        XCTAssertEqual(ab, "Bachelor Angewandte Informatik (PO-Version 2019)")
        let stored = try await db.withConnection { try HISinOneStudyService.stored($0) }
        XCTAssertEqual(stored?["reregistration"]?.string, "Rückgemeldet für Wintersemester 2026/27")
        XCTAssertFalse(t.requests.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("tab1") }, "Kontaktdaten nie")
    }

    func testAssignmentStatusTableWithoutFileNames() throws {
        let html = try fx("moodle/assign-view-submitted.html")
        let s = MoodleAssign.status(html: html)
        XCTAssertEqual(s.state, .submitted)
        XCTAssertEqual(s.grading, "Nicht bewertet")
        XCTAssertEqual(s.attempt, "Dies ist Versuch 1.")
        XCTAssertTrue(s.canEdit)
        XCTAssertFalse(s.canSubmit)
        XCTAssertNil(MoodleAssign.statusRows(html: html)["Dateiabgabe"], "Dateinamen enthalten Name und Matrikelnummer")
    }
}

/// Pruefungsanmeldung der HsH: Meldezeitraeume je Abteilung (exam-registration-hsh.json), gleiche Faelle wie Python
final class HsHExamRegistrationTests: XCTestCase {
    func testHsHPeriodCasesMatchPython() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let fx = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/exam-registration/period-cases.json")))["hsh"] ?? .null
        let data = try XCTUnwrap(ExamRegistrationPeriods.for(university: "hsh"))
        XCTAssertEqual(data.university, "hsh")
        XCTAssertEqual(data.system, "HISinOne")
        XCTAssertTrue(data.qisMenu.hasPrefix("https://campusmanagement.hs-hannover.de/"))
        XCTAssertEqual(data.programs.count, fx["count"]?.int)
        XCTAssertEqual(data.programs.filter { $0.table != nil }.count, fx["with_table"]?.int)
        XCTAssertEqual(ExamRegistrationPeriods.degreeSlugs("B.Eng."), ["beng"])
        XCTAssertEqual(ExamRegistrationPeriods.degreeSlugs("M.Eng."), ["meng"])
        for c in fx["programs"]?.array ?? [] {
            XCTAssertEqual(data.program(name: c["name"]?.string, degree: c["degree"]?.string)?.slug, c["slug"]?.string, "\(c)")
        }
        let phases = fx["phases"]?.array ?? []
        XCTAssertFalse(phases.isEmpty)
        for c in phases {
            let p = data.resolve(name: c["name"]?.string, degree: c["degree"]?.string)
            let w = data.window(p, today: c["today"]?.string ?? "", kind: c["kind"]?.string ?? "")
            XCTAssertEqual(w?.json ?? .null, c["window"] ?? .null, "\(c["today"] ?? .null)")
            XCTAssertEqual(data.periods(p, term: w?.term).count, c["periods"]?.int)
        }
    }
}

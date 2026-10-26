import Foundation
import XCTest
@testable import UniFlowCore

/// Nachgebildetes Netz: Antworten je URL-Praefix (laengster Treffer), zaehlt Anfragen, schreibt Downloads in Dateien.
final class FakeUniTransport: UniTransport, @unchecked Sendable {
    /// Antworten nacheinander; die letzte bleibt fuer alle weiteren Anfragen
    struct Route { var responses: [UniResponse] }
    private let lock = NSLock()
    /// Schluessel: URL-Praefix + "|" + Text, der im Inhalt der Anfrage stehen muss (leer = egal)
    private var routes: [String: Route] = [:]
    private(set) var requests: [UniRequest] = []

    func on(_ prefix: String, body: String = "", _ responses: UniResponse...) {
        lock.lock(); routes[prefix + "|" + body] = Route(responses: responses); lock.unlock()
    }

    func count(_ prefix: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.url.absoluteString.hasPrefix(prefix) }.count }

    func send(_ request: UniRequest) async throws -> UniResponse { respond(request) }

    /// synchron, damit das Sperren nicht in einem async-Kontext liegt (Swift 6)
    private func respond(_ request: UniRequest) -> UniResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let url = request.url.absoluteString
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        let candidates = routes.keys.filter { key in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return url.hasPrefix(parts[0]) && (parts[1].isEmpty || body.contains(parts[1]))
        }
        guard let key = candidates.max(by: { $0.count < $1.count }), var r = routes[key] else {
            return UniResponse(status: 404, finalURL: request.url)
        }
        let resp = r.responses.count > 1 ? r.responses.removeFirst() : r.responses[0]
        routes[key] = r
        return UniResponse(status: resp.status, headers: resp.headers, finalURL: resp.finalURL ?? request.url, body: resp.body)
    }

    func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
        let r = try await send(request)
        try r.body.write(to: destination)
        return UniResponse(status: r.status, headers: r.headers, finalURL: r.finalURL)
    }
}

func ok(_ s: String, url: String? = nil) -> UniResponse { UniResponse(status: 200, finalURL: url.flatMap(URL.init(string:)), body: Data(s.utf8)) }
func okJSON(_ j: JSONValue) -> UniResponse { UniResponse(status: 200, body: j.serialized()) }

final class HildesheimSyncTests: XCTestCase {
    let base = "https://www.uni-hildesheim.de/learnweb2026"
    let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })

    private func repo(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    private lazy var expected: JSONValue = try! JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/expected.json"))

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)), university: "hildesheim")
        return db
    }

    // MARK: Regeln, MD5, Moodle-Anmeldung, Ablage

    func testRulesMatchPython() {
        for c in expected["classify"]?.array ?? [] {
            let t = c["title"]?.string ?? ""
            let r = UniRules.classify(t)
            XCTAssertEqual(r.subject, c["subject"]?.string, t)
            XCTAssertEqual(r.kind, c["kind"]?.string, t)
            XCTAssertEqual(UniRules.eventKind(t), c["event_kind"]?.string, t)
        }
        for c in expected["file-kind"]?.array ?? [] {
            XCTAssertEqual(UniRules.fileKind(name: c["name"]?.string ?? "", mime: c["mime"]?.string), c["kind"]?.string)
        }
    }

    func testMD5AndMoodleLaunch() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")                       // RFC 1321
        XCTAssertEqual(MD5.hex(String(repeating: "1234567890", count: 8)), "57edf4a22be3c955ac49da2e2107b67a")         // > 64 Byte
        let m = expected["moodle-launch"]
        XCTAssertEqual(MoodleSSO.launchURL(base: m?["base"]?.string ?? "", passport: m?["passport"]?.string ?? ""), m?["launch_url"]?.string)
        for c in m?["cases"]?.array ?? [] {
            let t = MoodleSSO.parseLaunchToken(c["url"]?.string ?? "", base: m?["base"]?.string ?? "", passport: c["passport"]?.string ?? "")
            let w = c["result"]
            if w == nil || w!.isNull { XCTAssertNil(t); continue }
            XCTAssertEqual(t?.token, w?["token"]?.string)
            XCTAssertEqual(t?.privateToken, (w?["private_token"]?.isNull ?? true) ? nil : w?["private_token"]?.string)
        }
    }

    func testUniversityStorageIsSeparated() {
        let a = UniversityStorage.containerPath(appleUserID: "001234.abc", university: "hildesheim")
        let b = UniversityStorage.containerPath(appleUserID: "001234.abc", university: "luh")
        XCTAssertNotNil(a); XCTAssertNotEqual(a, b)
        XCTAssertTrue(a!.hasPrefix("users/") && a!.hasSuffix("/hildesheim"))
        XCTAssertNil(UniversityStorage.containerPath(appleUserID: "x", university: "../etc"))
        XCTAssertNil(UniversityStorage.containerPath(appleUserID: "", university: "luh"))
        XCTAssertEqual(UniversityStorage.keychainService(university: "hildesheim", purpose: "learnweb-token"), "de.uniflow.ai.hildesheim.learnweb-token")
        let u1 = UniversityStorage.websiteDataStoreID(appleUserID: "u", university: "luh")
        let u2 = UniversityStorage.websiteDataStoreID(appleUserID: "u", university: "hildesheim")
        XCTAssertNotEqual(u1, u2)
        XCTAssertEqual(u1, UniversityStorage.websiteDataStoreID(appleUserID: "u", university: "luh"))   // bleibt gleich
        XCTAssertEqual(u1?.uuidString.dropFirst(14).first, "5")                                         // Version 5
    }

    // MARK: Learnweb-Client

    /// REST wie Moodle: Antwort je wsfunction (und courseid) aus dem Formular
    private func restRoutes(_ t: FakeUniTransport, contentsByCourse: [Int: JSONValue], courses: [Int] = [35, 39]) {
        let rest = "\(base)/webservice/rest/server.php"
        t.on(rest, body: "wsfunction=core_webservice_get_site_info", okJSON(.object(["userid": .number(42)])))
        t.on(rest, body: "wsfunction=core_enrol_get_users_courses",
             okJSON(.array(courses.map { .object(["id": .number(Double($0)), "fullname": .string("SoSe 2026: 04\($0) Kurs \($0)"), "hidden": .number(0)]) })))
        for c in courses {
            t.on(rest, body: "courseid=\(c)&moodlewsrestformat=json&wsfunction=core_course_get_contents", okJSON(contentsByCourse[c] ?? .array([])))
        }
    }

    func testLearnwebTokenModeCoursesAndFiles() async throws {
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents], courses: [35])
        let api = LearnwebAPI(base: base, mode: .token("TOK"), transport: t, retry: noWait)
        let courses = try await api.courses()
        XCTAssertEqual(courses.map(\.id), ["lw-35"])
        XCTAssertEqual(courses.first?.number, "0435")
        let files = try await api.files(moodleID: 35)
        XCTAssertEqual(files.map(\.name), ["plan.pdf", "Einführung.pdf"])
        let req = await api.downloadRequest(files[0])
        XCTAssertTrue(req?.url.absoluteString.hasSuffix("plan.pdf?token=TOK") ?? false)
        XCTAssertFalse(files[0].downloadURL.contains("TOK"))                       // Schluessel nie in der Dateiliste
    }

    func testLearnwebInvalidTokenIsNotRetried() async {
        let t = FakeUniTransport()
        t.on("\(base)/webservice/rest/server.php", okJSON(.object(["exception": .string("moodle_exception"), "errorcode": .string("invalidtoken")])))
        let api = LearnwebAPI(base: base, mode: .token("ALT"), transport: t, retry: noWait)
        do { _ = try await api.courses(); XCTFail("Fehler erwartet") } catch { XCTAssertEqual(error as? HildesheimError, .invalidToken) }
        XCTAssertEqual(t.count("\(base)/webservice"), 1)
    }

    func testLearnwebSessionModeFollowsMoodleLinks() async throws {
        let t = FakeUniTransport()
        t.on("\(base)/my/courses.php", ok(#"<script>M.cfg = {"sesskey":"abc123","wwwroot":"x"};</script>"#))
        let state: JSONValue = .object([
            "section": .array([.object(["id": .string("11"), "number": .number(1), "title": .string("1")])]),
            "cm": .array([.object(["id": .string("7"), "module": .string("resource"), "name": .string("Folien"), "sectionid": .string("11")]),
                          .object(["id": .string("8"), "module": .string("folder"), "name": .string("Texte"), "sectionid": .string("11")])])])
        t.on("\(base)/lib/ajax/service.php?sesskey=abc123&info=core_course_get_enrolled_courses_by_timeline_classification",
             okJSON(.array([.object(["error": .bool(false), "data": .object(["courses": .array([.object(["id": .number(264), "fullname": .string("SoSe 2026: 0883 Sozialpsychologie")])])])])])))
        t.on("\(base)/lib/ajax/service.php?sesskey=abc123&info=core_courseformat_get_state",
             okJSON(.array([.object(["error": .bool(false), "data": .string(state.jsonString())])])))
        t.on("\(base)/mod/resource/view.php?id=7", UniResponse(status: 303, headers: ["Location": "\(base)/pluginfile.php/5/mod_resource/content/4/Folien%201.pdf"]))
        t.on("\(base)/mod/folder/view.php?id=8", ok(#"<a href="\#(base)/pluginfile.php/6/mod_folder/content/2/a.pdf?forcedownload=1">a</a>"#))
        let api = LearnwebAPI(base: base, mode: .session, transport: t, retry: noWait)
        let got1 = try await api.courses().map(\.number)
        XCTAssertEqual(got1, ["0883"])
        let files = try await api.files(moodleID: 264)
        XCTAssertEqual(files.map(\.name), ["Folien 1.pdf", "a.pdf"])
        XCTAssertEqual(files.map(\.folder), ["Woche 1", "Woche 1/Texte"])
        XCTAssertEqual(files.map(\.chdate), [4, 2])
        XCTAssertEqual(t.requests.first { $0.url.absoluteString.contains("view.php?id=7") }?.followRedirects, false)
    }

    func testLearnwebSessionExpiredOnLoginRedirect() async {
        let t = FakeUniTransport()
        t.on("\(base)/my/courses.php", ok("<html>Login</html>", url: "https://www.uni-hildesheim.de/sso/login?service=x"))
        let api = LearnwebAPI(base: base, mode: .session, transport: t, retry: noWait)
        do { _ = try await api.courses(); XCTFail("Fehler erwartet") } catch { XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb")) }
    }

    func testRetryOnServerErrorThenSuccess() async throws {
        let t = FakeUniTransport()
        t.on("\(base)/my/courses.php", UniResponse(status: 503), UniResponse(status: 502), ok(#""sesskey":"k1""#))
        t.on("\(base)/lib/ajax/service.php", okJSON(.array([.object(["error": .bool(false), "data": .object(["courses": .array([])])])])))
        let api = LearnwebAPI(base: base, mode: .session, transport: t, retry: noWait)
        let got2 = try await api.courses().count
        XCTAssertEqual(got2, 0)
        XCTAssertEqual(t.count("\(base)/my/courses.php"), 3)
    }

    func testDiscoverLearnwebOverNetwork() async {
        let t = FakeUniTransport()
        let cfg = { (name: String) in okJSON(.array([.object(["error": .bool(false), "data": .object(["sitename": .string(name)])])])) }
        t.on("https://www.uni-hildesheim.de/learnweb2025/lib/ajax/service-nologin.php", cfg("Learnweb SoSe 2025 - WiSe 2025/26"))
        t.on("https://www.uni-hildesheim.de/learnweb2026/lib/ajax/service-nologin.php", cfg("Learnweb SoSe 2026 - WiSe 2026/27"))
        let got = await Learnweb.discoverBase(year: 2026, month: 10, transport: t)       // 2027 antwortet 404
        XCTAssertEqual(got, "https://www.uni-hildesheim.de/learnweb2026")
        let fixed = await Learnweb.discoverBase(year: 2026, month: 10, override: "https://x/lw/", transport: t)
        XCTAssertEqual(fixed, "https://x/lw")
    }

    // MARK: Gesamtablauf in die lokale Datenbank

    private let gradePage = """
        <html><a href="x">Abmelden</a>
        <table summary="Stammdaten"><tr><td>Name</td><td>Erika Muster</td></tr><tr><td>Matrikelnummer</td><td>123</td></tr></table>
        <table><tr><td colspan="5">Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022</td></tr>
        <tr><th>Prüfungsnr.</th><th>Bezeichnung der Leistung / der Lehrveranstaltung</th><th>Note</th><th>Status</th><th>Bonus</th></tr>
        <tr><td>5010</td><td>Modul 1</td><td></td><td></td><td>12</td></tr>
        <tr><td>5011</td><td>TM 1: Grundlagen</td><td>1,7</td><td>bestanden</td><td>6</td></tr>
        <tr><td>5032</td><td>TM 2: Kindheit</td><td></td><td>angemeldet (SoSe 26)</td><td>0</td></tr></table></html>
        """

    private func lsfRoutes(_ t: FakeUniTransport, plan: String) {
        let lsf = HildesheimCAS.lsfBase
        t.on(LSFClient.planURL, ok(#"<a href="x">Abmelden</a><a href="\#(lsf)/qisserver/rds?state=verpublish&amp;termine=1,2&amp;moduleCall=iCalendarPlan">iCal</a>"#))
        t.on("\(lsf)/qisserver/rds?state=verpublish", ok(plan))
        t.on(LSFClient.startURL, ok(#"<a href="x">Abmelden</a><a href="rds?state=notenspiegelStudent&amp;nodeID=a">Studien-/Prüfungsleistungen (Notenspiegel)</a>"#))
        t.on("\(lsf)/qisserver/rds?state=notenspiegelStudent", ok(gradePage))
    }

    func testFullSyncStoresEverythingAndIsSafeToRepeat() async throws {
        let db = try await database()
        let root = try tempDir()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents, 39: .array([])], courses: [35, 39])
        t.on("\(base)/webservice/pluginfile.php/5", ok("%PDF-1.7 plan"))
        t.on("\(base)/webservice/pluginfile.php/6", ok("%PDF-1.7 einfuehrung"))
        lsfRoutes(t, plan: try repo("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        let sync = HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t, retry: noWait),
                                  lsf: LSFClient(transport: t, retry: noWait), transport: t, clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)))
        let r1 = await sync.run()
        XCTAssertTrue(r1.ok, r1.messages.joined(separator: "; "))
        XCTAssertEqual(r1.newFiles.count, 2)
        XCTAssertEqual(r1.plan?.new, 4)
        XCTAssertEqual(r1.grades, 2)                                                     // Modulzeile ohne Note/Status weg

        let files = try await db.rows("SELECT id, course_id, local_path, content_sha256, kind, studip_folder FROM files WHERE course_id LIKE 'lw-%' ORDER BY name")
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0]["content_sha256"]?.string, SolutionSHA256.hex(Data("%PDF-1.7 einfuehrung".utf8)))
        XCTAssertEqual(files[1]["studip_folder"]?.string, "Informationen")
        let path = files[0]["local_path"]?.string ?? ""
        XCTAssertTrue(path.hasPrefix("files/lw-80-"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "%PDF-1.7 einfuehrung")
        let grades = try await db.rows("SELECT * FROM grades")
        XCTAssertFalse(grades.contains { ($0["raw"]?.string ?? "").contains("Erika") }, "keine Stammdaten")
        let got3 = try await db.scalar("SELECT COUNT(*) FROM event_exceptions")?.int
        XCTAssertEqual(got3, 2)

        // zweiter Lauf: keine neuen Downloads, Stundenplan unveraendert
        let downloadsBefore = t.count("\(base)/webservice/pluginfile.php")
        let r2 = await sync.run()
        XCTAssertEqual(r2.newFiles.count, 0)
        XCTAssertEqual(t.count("\(base)/webservice/pluginfile.php"), downloadsBefore)
        XCTAssertEqual(r2.plan, UniStore.PlanResult(new: 0, removed: 0, kept: 4, cancelledDates: 0))
    }

    /// Wie hildesheim.sync_learnweb: erst alle Kurse (upsert_course), dann je Kurs die Dateien. Eine unlesbare
    /// Dateiliste betrifft nur ihren Kurs; der Kurs selbst steht trotzdem in der Datenbank.
    func testCourseWithUnreadableFileListIsStoredOthersLoad() async throws {
        let db = try await database()
        let root = try tempDir()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents], courses: [35, 39])
        t.on("\(base)/webservice/rest/server.php", body: "courseid=39&moodlewsrestformat=json&wsfunction=core_course_get_contents",
             UniResponse(status: 503))
        t.on("\(base)/webservice/pluginfile.php", ok("%PDF-1.7"))
        let r = await HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t, retry: noWait),
                                     lsf: nil, transport: t, clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)), retry: noWait).run()
        XCTAssertEqual(r.failedCourses, ["0439 Kurs 39"])
        XCTAssertEqual(r.newFiles.count, 2, "Dateien des lesbaren Kurses kommen an")
        let courses = try await db.rows("SELECT id, subject, kind FROM courses WHERE id LIKE 'lw-%' ORDER BY id")
        XCTAssertEqual(courses.compactMap { $0["id"]?.string }, ["lw-35", "lw-39"])
        XCTAssertEqual(courses.last?["subject"]?.string, "Kurs 39", "Fach wie classify")
        let hashes = try await db.scalar("SELECT COUNT(*) FROM files WHERE course_id='lw-35' AND content_sha256 IS NOT NULL")?.int
        XCTAssertEqual(hashes, 2)
    }

    func testFailuresStayLocalAndNeverDeleteData() async throws {
        let db = try await database()
        let root = try tempDir()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents], courses: [35])
        t.on("\(base)/webservice/pluginfile.php/5", ok("%PDF-1.7 plan"))
        t.on("\(base)/webservice/pluginfile.php/6", ok("<!DOCTYPE html><html>Bitte anmelden</html>"))   // Webseite statt Datei
        lsfRoutes(t, plan: try repo("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        let r1 = await HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t, retry: noWait),
                                      lsf: LSFClient(transport: t, retry: noWait), transport: t, clock: clock).run()
        XCTAssertEqual(r1.newFiles.count, 1)
        XCTAssertEqual(r1.failedFiles, ["Einführung.pdf"])
        let html = try await db.rows("SELECT local_path FROM files WHERE name='Einführung.pdf'")
        XCTAssertTrue(html.first?["local_path"]?.isNull ?? false, "Webseite wird nie als Datei gespeichert")
        let got4 = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(got4, 4)

        // LSF-Sitzung abgelaufen, Learnweb antwortet nur mit Fehlern: nichts wird geloescht
        let t2 = FakeUniTransport()
        t2.on("\(base)/webservice/rest/server.php", UniResponse(status: 500))
        t2.on(LSFClient.planURL, ok("<html>Login</html>", url: "https://www.uni-hildesheim.de/sso/login?service=y"))
        t2.on(LSFClient.startURL, ok("<html>Login</html>", url: "https://www.uni-hildesheim.de/sso/login?service=y"))
        let r2 = await HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t2, retry: noWait),
                                      lsf: LSFClient(transport: t2, retry: noWait), transport: t2, clock: clock).run()
        XCTAssertFalse(r2.ok)
        XCTAssertEqual(r2.needsLogin, ["LSF"])
        let got5 = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(got5, 4)
        let got6 = try await db.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL")?.int
        XCTAssertEqual(got6, 1)
        XCTAssertEqual(t2.count("\(base)/webservice/rest/server.php"), 3)                   // 3 Versuche, dann aufgegeben
    }

    /// S7 fuer Learnweb: liefert Learnweb fuer eine Datei mit Notizen eine neue Fassung (hoeheres timemodified, anderer
    /// Inhalt), bleibt die alte PDF aufbewahrt und die Notizen kommen auf die passende Seite der neuen (eine Seite davor
    /// eingefuegt); die Seitentexte stehen fuer die Suche bereit
    func testNewLearnwebVersionKeepsOldVersionAndMovesNotes() async throws {
        let db = try await database()
        let root = try tempDir()
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        let keeper = FileVersionKeeper(database: db, files: LocalFiles(container: root, dataDirectory: "", tools: FormFeedTools()),
                                       directory: "Fassungen", source: "Learnweb", clock: clock)
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        let v1 = "Seminarplan Wintersemester\u{C}Termine im Oktober mit Referaten\u{C}Termine im November mit Klausur"
        let v2 = "Seminarplan Wintersemester\u{C}Neu: Hinweise zur Anmeldung im Portal\u{C}Termine im Oktober mit Referaten\u{C}Termine im November mit Klausur"
        let t = FakeUniTransport()
        restRoutes(t, contentsByCourse: [35: contents], courses: [35])
        t.on("\(base)/webservice/pluginfile.php/5", ok(v1))
        t.on("\(base)/webservice/pluginfile.php/6", ok("%PDF-1.7 einfuehrung"))
        let sync = HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t, retry: noWait),
                                  lsf: nil, transport: t, clock: clock, retry: noWait, versions: keeper)
        _ = await sync.run()
        let idValue = try await db.scalar("SELECT id FROM files WHERE name='plan.pdf'")?.string
        let id = try XCTUnwrap(idValue)
        let indexed = try await db.scalar("SELECT COUNT(*) FROM page_texts WHERE file_id=?", [.text(id)])?.int
        XCTAssertEqual(indexed, 3, "Seitentexte beim Download")
        let notes: JSONValue = ["version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2],
                                                            ["key": "p3", "type": "pdf", "index": 3]],
                                "pages": ["p1": ["objects": []], "p2": ["objects": []], "p3": page(["klausur-merken"])]]
        try await db.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", [.text(id), .text(notes.jsonString()), "x"])

        // zweiter Abgleich: neue Fassung von plan.pdf
        let newer = try JSONValue.parse(contents.jsonString().replacingOccurrences(of: "1760000000", with: "1760100000"))
        let t2 = FakeUniTransport()
        restRoutes(t2, contentsByCourse: [35: newer], courses: [35])
        t2.on("\(base)/webservice/pluginfile.php/5", ok(v2))
        let r2 = await HildesheimSync(db: db, root: root, learnweb: LearnwebAPI(base: base, mode: .token("TOK"), transport: t2, retry: noWait),
                                      lsf: nil, transport: t2, clock: clock, retry: noWait, versions: keeper).run()
        XCTAssertEqual(r2.newFiles, [id])
        let stored = try await db.scalar("SELECT data FROM annotations WHERE file_id=?", [.text(id)])?.string
        let data = try XCTUnwrap(stored)
        let doc = AnnotationDocument(root: try JSONValue.parse(data))
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p3"), 4)
        XCTAssertEqual(doc.objects(page: "p3").compactMap { $0["id"]?.string }, ["klausur-merken"])
        let version = try await db.rows("SELECT version, source, local_path, content_sha256 FROM file_versions WHERE file_id=?", [.text(id)])
        XCTAssertEqual(version.count, 1)
        XCTAssertEqual(version.first?["source"], "Learnweb")
        XCTAssertEqual(version.first?["content_sha256"]?.string, SolutionSHA256.hex(Data(v1.utf8)))
        let kept = try XCTUnwrap(version.first?["local_path"]?.string)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(kept), encoding: .utf8), v1, "alte Fassung aufbewahrt")
        let current = try await db.scalar("SELECT local_path FROM files WHERE id=?", [.text(id)])?.string
        let path = try XCTUnwrap(current)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), v2)
    }
}

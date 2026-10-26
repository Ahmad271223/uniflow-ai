import Foundation
import XCTest
@testable import UniFlowCore

/// Nachgebildetes Netz: Antworten je URL-Praefix (laengster Treffer) oder aus einer Funktion (`init(_:)`, darf werfen,
/// z. B. `URLError`), zaehlt Anfragen, schreibt Downloads in Dateien. Kein echtes Netz.
final class FakeUniTransport: UniTransport, @unchecked Sendable {
    /// Antworten nacheinander; die letzte bleibt fuer alle weiteren Anfragen
    struct Route { var responses: [UniResponse] }
    private let lock = NSLock()
    /// Schluessel: URL-Praefix + "|" + Text, der im Inhalt der Anfrage stehen muss (leer = egal)
    private var routes: [String: Route] = [:]
    private var log: [UniRequest] = []
    private let handler: ((UniRequest) throws -> UniResponse)?

    init() { handler = nil }

    init(_ handler: @escaping (UniRequest) throws -> UniResponse) { self.handler = handler }

    var requests: [UniRequest] { lock.lock(); defer { lock.unlock() }; return log }

    func on(_ prefix: String, body: String = "", _ responses: UniResponse...) {
        lock.lock(); routes[prefix + "|" + body] = Route(responses: responses); lock.unlock()
    }

    func count(_ prefix: String) -> Int { requests.filter { $0.url.absoluteString.hasPrefix(prefix) }.count }

    func send(_ request: UniRequest) async throws -> UniResponse {
        guard let handler else { return respond(request) }
        record(request)
        let r = try handler(request)
        return UniResponse(status: r.status, headers: r.headers, finalURL: r.finalURL ?? request.url, body: r.body)
    }

    private func record(_ request: UniRequest) { lock.lock(); log.append(request); lock.unlock() }

    /// synchron, damit das Sperren nicht in einem async-Kontext liegt (Swift 6)
    private func respond(_ request: UniRequest) -> UniResponse {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
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

    let tok = LearnwebToken("TOK")!

    /// Container (erfundener Apple-Nutzer, Uni Hildesheim) in einem Temp-Ordner mit seiner Datenbank wie in der App
    private func container() async throws -> (SQLiteDatabase, DataContainerLayout) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hi-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: "001234.erfunden.0001", university: .hildesheim))
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        return (db, layout)
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
        let api = LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait)
        let courses = try await api.courses()
        XCTAssertEqual(courses.map(\.id), ["lw-35"])
        XCTAssertEqual(courses.first?.number, "0435")
        let files = try await api.files(moodleID: 35)
        XCTAssertEqual(files.map(\.name), ["plan.pdf", "Einführung.pdf"])
        let req = try await api.downloadRequest(files[0])
        XCTAssertEqual(req.url.absoluteString, files[0].downloadURL, "Schluessel nie in der Adresse")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(decoding: req.body ?? Data(), as: UTF8.self), "token=TOK", "Schluessel erst beim Abruf, im Koerper")
        XCTAssertFalse(files[0].downloadURL.contains("TOK"))                       // Schluessel nie in der Dateiliste
    }

    func testLearnwebInvalidTokenIsNotRetried() async {
        let t = FakeUniTransport()
        t.on("\(base)/webservice/rest/server.php", okJSON(.object(["exception": .string("moodle_exception"), "errorcode": .string("invalidtoken")])))
        let api = LearnwebAPI(base: base, mode: .token(LearnwebToken("ALT")!), transport: t, retry: noWait)
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
        let (db, layout) = try await container()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents, 39: .array([])], courses: [35, 39])
        t.on("\(base)/webservice/pluginfile.php/5", ok("%PDF-1.7 plan"))
        t.on("\(base)/webservice/pluginfile.php/6", ok("%PDF-1.7 einfuehrung"))
        lsfRoutes(t, plan: try repo("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        let sync = HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait),
                                  lsf: LSFClient(transport: t, retry: noWait), transport: t, clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)))
        let r1 = await sync.run()
        XCTAssertTrue(r1.ok, r1.messages.joined(separator: "; "))
        XCTAssertEqual(r1.newFiles.count, 2)
        XCTAssertEqual(r1.plan?.new, 4)
        XCTAssertEqual(r1.grades, 2)                                                     // Modulzeile ohne Note/Status weg
        XCTAssertEqual(r1.completed, ["Learnweb", "LSF-Stundenplan", "Notenspiegel"], "Stand je Teil fuer die Statusleiste")

        let files = try await db.rows("SELECT id, course_id, local_path, content_sha256, kind, studip_folder FROM files WHERE course_id LIKE 'lw-%' ORDER BY name")
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0]["content_sha256"]?.string, SolutionSHA256.hex(Data("%PDF-1.7 einfuehrung".utf8)))
        XCTAssertEqual(files[1]["studip_folder"]?.string, "Informationen")
        let path = files[0]["local_path"]?.string ?? ""
        XCTAssertTrue(path.hasPrefix("Learnweb/files/lw-80-"), "relativ zum Container wie StudIP/... der LUH")
        XCTAssertEqual(try String(contentsOf: layout.root.appendingPathComponent(path), encoding: .utf8), "%PDF-1.7 einfuehrung")
        XCTAssertTrue(layout.files().exists(stored: path))
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
        let (db, layout) = try await container()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents], courses: [35, 39])
        t.on("\(base)/webservice/rest/server.php", body: "courseid=39&moodlewsrestformat=json&wsfunction=core_course_get_contents",
             UniResponse(status: 503))
        t.on("\(base)/webservice/pluginfile.php", ok("%PDF-1.7"))
        let r = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait),
                                     lsf: nil, transport: t, clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)), retry: noWait).run()
        XCTAssertEqual(r.failedCourses, ["0439 Kurs 39"])
        XCTAssertEqual(r.completed, ["Learnweb"], "ein Kursfehler beendet den Learnweb-Teil nicht")
        XCTAssertEqual(r.newFiles.count, 2, "Dateien des lesbaren Kurses kommen an")
        let courses = try await db.rows("SELECT id, subject, kind FROM courses WHERE id LIKE 'lw-%' ORDER BY id")
        XCTAssertEqual(courses.compactMap { $0["id"]?.string }, ["lw-35", "lw-39"])
        XCTAssertEqual(courses.last?["subject"]?.string, "Kurs 39", "Fach wie classify")
        let hashes = try await db.scalar("SELECT COUNT(*) FROM files WHERE course_id='lw-35' AND content_sha256 IS NOT NULL")?.int
        XCTAssertEqual(hashes, 2)
    }

    func testFailuresStayLocalAndNeverDeleteData() async throws {
        let (db, layout) = try await container()
        let t = FakeUniTransport()
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        restRoutes(t, contentsByCourse: [35: contents], courses: [35])
        t.on("\(base)/webservice/pluginfile.php/5", ok("%PDF-1.7 plan"))
        t.on("\(base)/webservice/pluginfile.php/6", ok("<!DOCTYPE html><html>Bitte anmelden</html>"))   // Webseite statt Datei
        lsfRoutes(t, plan: try repo("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        let r1 = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait),
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
        let r2 = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t2, retry: noWait),
                                      lsf: LSFClient(transport: t2, retry: noWait), transport: t2, clock: clock).run()
        XCTAssertFalse(r2.ok)
        XCTAssertEqual(r2.needsLogin, ["LSF"])
        XCTAssertEqual(r2.completed, [], "weder Learnweb (5xx) noch LSF (Anmeldung) zu Ende gelaufen")
        let got5 = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(got5, 4)
        let got6 = try await db.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL")?.int
        XCTAssertEqual(got6, 1)
        XCTAssertEqual(t2.count("\(base)/webservice/rest/server.php"), 3)                   // 3 Versuche, dann aufgegeben
    }

    // MARK: Leere oder unvollstaendige Antworten loeschen nie etwas

    /// Kursinhalt mit einer Datei plan.pdf (Fassung `modified`, Groesse laut Learnweb 26 Byte)
    private func planContents(modified: Int) -> JSONValue {
        .array([.object(["section": .number(1), "name": .string("1"), "modules": .array([.object([
            "id": .number(77), "modname": .string("resource"), "name": .string("Seminarplan"),
            "contents": .array([.object(["type": .string("file"), "filename": .string("plan.pdf"), "filepath": .string("/"),
                                         "filesize": .number(26), "timemodified": .number(Double(modified)),
                                         "fileurl": .string("\(base)/webservice/pluginfile.php/5/mod_resource/content/1/plan.pdf")])]),
        ])])])])
    }

    /// HTTP 200 mit 0 Bytes zu einer neuen Fassung: die gute alte Datei bleibt samt Fassung und Inhalts-Hash, die
    /// Datei gilt als nicht geladen und kommt beim naechsten Abgleich (wie `empty_download` am PC).
    func testEmptyDownloadNeverReplacesAGoodFile() async throws {
        let (db, layout) = try await container()
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        func sync(_ t: FakeUniTransport) -> HildesheimSync {
            HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait),
                           lsf: nil, transport: t, clock: clock, retry: noWait)
        }
        let good = "%PDF-1.7 gute alte Fassung"
        let t1 = FakeUniTransport()
        restRoutes(t1, contentsByCourse: [35: planContents(modified: 100)], courses: [35])
        t1.on("\(base)/webservice/pluginfile.php/5", ok(good))
        let r1 = await sync(t1).run()
        XCTAssertEqual(r1.newFiles.count, 1, r1.messages.joined(separator: "; "))
        let loaded = try await db.scalar("SELECT local_path FROM files WHERE name='plan.pdf'")?.string
        let path = try XCTUnwrap(loaded)
        let file = layout.root.appendingPathComponent(path)

        let t2 = FakeUniTransport()
        restRoutes(t2, contentsByCourse: [35: planContents(modified: 200)], courses: [35])
        t2.on("\(base)/webservice/pluginfile.php/5", ok(""))
        let r2 = await sync(t2).run()
        XCTAssertEqual(r2.newFiles, [])
        XCTAssertEqual(r2.failedFiles, ["plan.pdf"], "leere Antwort ist ein Fehler dieser Datei")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), good, "alte Datei steht noch")
        let row = try await db.rows("SELECT chdate, size, content_sha256 FROM files WHERE name='plan.pdf'").first
        XCTAssertEqual(row?["chdate"]?.int, 100, "neue Fassung erst mit einem echten Download")
        XCTAssertEqual(row?["content_sha256"]?.string, SolutionSHA256.hex(Data(good.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.learnweb.appendingPathComponent(".laden").path),
                       "Zwischenordner nach dem Lauf aufgeraeumt")

        let t3 = FakeUniTransport()
        restRoutes(t3, contentsByCourse: [35: planContents(modified: 200)], courses: [35])
        t3.on("\(base)/webservice/pluginfile.php/5", ok("%PDF-1.7 neue Fassung"))
        let r3 = await sync(t3).run()
        XCTAssertEqual(r3.newFiles.count, 1, "gilt weiter als geaendert")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "%PDF-1.7 neue Fassung")
    }

    /// Export-Link vorhanden, Kalender ohne Termin: kein vollstaendig gelesener Plan. LSF-Serien bleiben mit eigener
    /// Verlegung und Teilnahme-Einstellung, der Stundenplan-Teil gilt nicht als ok (wie lsf.fetch_plan_ics).
    func testCalendarWithoutEventsRemovesNoSeries() async throws {
        let (db, layout) = try await container()
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        let t1 = FakeUniTransport()
        lsfRoutes(t1, plan: try repo("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"))
        let r1 = await HildesheimSync(db: db, container: layout, learnweb: nil, lsf: LSFClient(transport: t1, retry: noWait),
                                      transport: t1, clock: clock).run(includeGrades: false)
        XCTAssertEqual(r1.plan?.new, 4)
        let first = try await db.scalar("SELECT id FROM course_events WHERE source='lsf' ORDER BY id LIMIT 1")
        let eid = try XCTUnwrap(first)
        try await db.transaction { c in
            try c.execute("UPDATE course_events SET attend=0 WHERE id=?", [eid])
            try c.execute("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?, '2026-11-02', 'moved', 't')", [eid])
        }
        let exceptions = try await db.scalar("SELECT COUNT(*) FROM event_exceptions")?.int

        let t2 = FakeUniTransport()
        lsfRoutes(t2, plan: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//HIS//LSF//DE\r\nEND:VCALENDAR\r\n")
        let r2 = await HildesheimSync(db: db, container: layout, learnweb: nil, lsf: LSFClient(transport: t2, retry: noWait),
                                      transport: t2, clock: clock).run(includeGrades: false)
        XCTAssertNil(r2.plan)
        XCTAssertFalse(r2.completed.contains(HildesheimSync.Report.Part.plan))
        XCTAssertTrue(r2.messages.contains("LSF-Stundenplan: Unerwartete Antwort: LSF-iCal ohne Termine"), r2.messages.joined(separator: "; "))
        let series = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(series, 4)
        let attend = try await db.scalar("SELECT attend FROM course_events WHERE id=?", [eid])?.int
        XCTAssertEqual(attend, 0)
        let moved = try await db.scalar("SELECT COUNT(*) FROM event_exceptions WHERE event_id=? AND type='moved'", [eid])?.int
        XCTAssertEqual(moved, 1)
        let after = try await db.scalar("SELECT COUNT(*) FROM event_exceptions")?.int
        XCTAssertEqual(after, exceptions)
    }

    // MARK: Geloeschter Container

    /// Wird der Container waehrend des Abgleichs geloescht ("Daten dieser Hochschule löschen"), legt der Lauf ihn nicht
    /// neu an: vor jedem Anlegen und Ersetzen prueft `UniDownloads` die Kennzeichnung. Ohne Kennzeichnung laeuft nichts.
    func testDeletedContainerIsNeverRecreated() async throws {
        let contents = try JSONValue.parse(repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        /// Learnweb mit Schluessel; `onDownload` laeuft bei jedem Datei-Abruf
        func learnweb(_ onDownload: @escaping () throws -> Void) -> FakeUniTransport {
            FakeUniTransport { req in
                let form = String(decoding: req.body ?? Data(), as: UTF8.self)
                if req.url.path.contains("/webservice/pluginfile.php/") {
                    try onDownload()
                    return ok("%PDF-1.7")
                }
                if form.contains("core_webservice_get_site_info") { return okJSON(["userid": 42]) }
                if form.contains("core_enrol_get_users_courses") { return okJSON([["id": 35, "fullname": "SoSe 2026: 0435 Kurs 35"]]) }
                if form.contains("core_course_get_contents") { return okJSON(contents) }
                return UniResponse(status: 404)
            }
        }
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))

        // ganzer Container waehrend des ersten Downloads geloescht: die zweite Datei legt ihn nicht wieder an
        let (db, layout) = try await container()
        let t = learnweb { try? layout.remove() }
        let r = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t, retry: noWait),
                                     lsf: nil, transport: t, clock: clock, retry: noWait).run()
        XCTAssertEqual(r.newFiles, [])
        XCTAssertEqual(r.failedFiles.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.root.path), "Container nicht neu angelegt")

        // nur die Kennzeichnung ist schon weg (Loeschen laeuft): die geladene Datei kommt nicht an ihren Platz
        let (db2, layout2) = try await container()
        let t2 = learnweb { try? FileManager.default.removeItem(at: layout2.manifestURL) }
        let r2 = await HildesheimSync(db: db2, container: layout2, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: t2, retry: noWait),
                                      lsf: nil, transport: t2, clock: clock, retry: noWait).run()
        XCTAssertEqual(r2.newFiles, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout2.learnweb.appendingPathComponent("files").path), "keine Datei abgelegt")
        let stored = try await db2.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL")?.int
        XCTAssertEqual(stored, 0)
        XCTAssertTrue(r2.messages.contains { $0.contains("2 Dateien später erneut") }, r2.messages.joined(separator: "; "))

        let missing = DataContainerLayout(base: layout.base, key: DataContainerKey(userID: "001234.erfunden.0002", university: .hildesheim))
        let none = FakeUniTransport()
        let refused = await HildesheimSync(db: db, container: missing, learnweb: LearnwebAPI(base: base, mode: .token(tok), transport: none, retry: noWait),
                                           lsf: nil, transport: none).run()
        XCTAssertEqual(refused.refused, DataContainerError.missing.description)
        XCTAssertTrue(none.requests.isEmpty, "ohne Kennzeichnung keine Anfrage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.root.path))
    }
}

import Foundation
import XCTest
@testable import UniFlowCore

/// Feste Antworten je Pfad (ohne Host, Klammern unkodiert); merkt sich die abgerufenen Pfade.
final class StubTransport: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private var log: [String] = []

    init(_ routes: [String: HTTPReply]) { self.routes = routes }

    var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let key = url.absoluteString
            .replacingOccurrences(of: "https://studip.test", with: "")
            .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
        record(key)
        return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
    }

    private func record(_ key: String) { lock.lock(); log.append(key); lock.unlock() }   // synchron: Sperre nicht ueber await
}

private func api(_ json: String) -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let base = URL(string: "https://studip.test")!

final class StudIPClientTests: XCTestCase {

    func testCoursesFollowPaginationAndSemester() async throws {
        let t = StubTransport([
            "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester": api(#"""
            {"data":[{"id":"c1","type":"courses","attributes":{"title":"Mathematik  für\n Ingenieure","course-number":" 12345 "},
              "relationships":{"start-semester":{"data":{"type":"semesters","id":"s26"}}}}],
             "included":[{"id":"s26","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}],
             "links":{"next":"/jsonapi.php/v1/users/u1/courses?page[offset]=100&page[limit]=100&include=start-semester,end-semester"}}
            """#),
            "/jsonapi.php/v1/users/u1/courses?page[offset]=100&page[limit]=100&include=start-semester,end-semester": api(#"""
            {"data":[{"id":"c2","type":"courses","attributes":{"title":"Programmieren I","course-number":""}}],"links":{}}
            """#),
        ])
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let courses = try await c.courses(userID: "u1")
        XCTAssertEqual(courses.map(\.id), ["c1", "c2"])
        XCTAssertEqual(courses[0].title, "Mathematik für Ingenieure")
        XCTAssertEqual(courses[0].number, "12345")
        XCTAssertNil(courses[0].semesterEnd, "ohne end-semester (aeltere Stud.IP-Fassung): unbekannt, die Regel nimmt den Titel")
        XCTAssertEqual(courses[0].semesterTitle, "WiSe 2026/27")
        XCTAssertEqual(courses[0].semesterStart, "2026-10-01T00:00:00+02:00")
        XCTAssertNil(courses[1].number)
        XCTAssertNil(courses[1].semesterStart)
    }

    func testFilesWalkFolderTreeWithPaths() async throws {
        let t = StubTransport([
            "/jsonapi.php/v1/courses/k1/folders?page[limit]=200": api(#"""
            {"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}},
                     {"id":"x9","attributes":{"folder-type":"StandardFolder","name":"Nur Unterordner"}}]}
            """#),
            "/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500": api(#"""
            {"data":[{"id":"f1","attributes":{"name":"Folien 1.pdf","filesize":2048,"mime-type":"application/pdf",
              "chdate":"2026-10-20T10:00:00+02:00","is-downloadable":true}}]}
            """#),
            "/jsonapi.php/v1/folders/r1/folders?page[limit]=200": api(#"{"data":[{"id":"s1","attributes":{"name":" Übungen "}}]}"#),
            "/jsonapi.php/v1/folders/s1/file-refs?page[limit]=500": api(#"""
            {"data":[{"id":"f2","attributes":{"name":"Blatt 1.pdf","filesize":10,"chdate":"2026-10-21T08:00:00+02:00","is-downloadable":false}}]}
            """#),
            "/jsonapi.php/v1/folders/s1/folders?page[limit]=200": api(#"{"data":[]}"#),
        ])
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let files = try await c.files(courseID: "k1")
        XCTAssertEqual(files.map(\.id), ["f1", "f2"])
        XCTAssertEqual(files[0].folderPath, "")
        XCTAssertEqual(files[0].size, 2048)
        XCTAssertEqual(files[0].mimeType, "application/pdf")
        XCTAssertEqual(files[0].changed, "2026-10-20T10:00:00+02:00")
        XCTAssertEqual(files[1].folderPath, "Übungen")
        XCTAssertFalse(files[1].isDownloadable)
        XCTAssertFalse(t.requested.contains { $0.contains("folders/x9") }, "nur ab dem Wurzelordner laufen")
    }

    func testUnauthorizedMeansSessionExpired() async {
        let t = StubTransport(["/jsonapi.php/v1/users/me": HTTPReply(status: 401, contentType: "application/vnd.api+json")])
        do {
            _ = try await StudIPClient(base: base, transport: t, pauseMillis: 0).currentUserID()
            XCTFail("401 muss als abgelaufene Anmeldung gemeldet werden")
        } catch { XCTAssertEqual(error as? StudIPError, .sessionExpired) }
    }

    func testRedirectToLoginPageMeansSessionExpired() async {
        let login = HTTPReply(status: 200, contentType: "text/html; charset=UTF-8",
                              finalURL: URL(string: "https://studip.test/dispatch.php/login?cancel_login=1"),
                              body: Data("<html>Login</html>".utf8))
        let t = StubTransport(["/jsonapi.php/v1/users/me": login, "/jsonapi.php/v1/file-refs/f1/content": login])
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0)
        do { _ = try await c.currentUserID(); XCTFail("Anmeldeseite statt JSON") } catch { XCTAssertEqual(error as? StudIPError, .sessionExpired) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("studip-\(UUID().uuidString).pdf")
        do { try await c.download(fileID: "f1", to: target); XCTFail("Anmeldeseite statt Datei") } catch { XCTAssertEqual(error as? StudIPError, .sessionExpired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "keine Anmeldeseite als Datei")
    }

    func testDownloadWritesFileAndReportsHTTPErrorsWithoutIDs() async throws {
        let id = "0123456789abcdef0123456789abcdef"
        let t = StubTransport([
            "/jsonapi.php/v1/file-refs/f1/content": HTTPReply(status: 200, contentType: "application/pdf", body: Data([37, 80, 68, 70])),
            "/jsonapi.php/v1/file-refs/\(id)/content": HTTPReply(status: 403, contentType: "application/vnd.api+json", body: Data("{}".utf8)),
        ])
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await c.download(fileID: "f1", to: dir.appendingPathComponent("f1"))
        XCTAssertEqual(Array(try Data(contentsOf: dir.appendingPathComponent("f1"))), [37, 80, 68, 70])
        do { try await c.download(fileID: id, to: dir.appendingPathComponent("x")); XCTFail("403 muss als Fehler kommen") } catch {
            XCTAssertEqual(error as? StudIPError, .http(status: 403, path: "jsonapi.php/v1/file-refs/:id/content"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x").path), "Fehlerseite bleibt nicht liegen")
    }

    func testRequestLimitStopsRun() async {
        let t = StubTransport([
            "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester": api(#"{"data":[],"links":{"next":"/jsonapi.php/v1/next"}}"#),
            "/jsonapi.php/v1/next": api(#"{"data":[]}"#),
        ])
        do {
            _ = try await StudIPClient(base: base, transport: t, pauseMillis: 0, maxRequests: 1).courses(userID: "u1")
            XCTFail("Limit überschritten")
        } catch { XCTAssertEqual(error as? StudIPError, .requestLimit) }
    }

    func testForeignNextLinkIsRejected() async {
        let t = StubTransport([
            "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester": api(#"{"data":[],"links":{"next":"https://evil.test/steal"}}"#),
        ])
        do {
            _ = try await StudIPClient(base: base, transport: t, pauseMillis: 0).courses(userID: "u1")
            XCTFail("fremder Host darf nicht abgerufen werden")
        } catch {
            guard let e = error as? StudIPError, case .badResponse = e else { return XCTFail("unerwarteter Fehler \(error)") }
        }
        XCTAssertFalse(t.requested.contains { $0.contains("evil") })
    }

    func testScrubRemovesIDsAndQuery() {
        XCTAssertEqual(StudIPClient.scrub("jsonapi.php/v1/folders/0123456789abcdef0123456789abcdef/file-refs?page[limit]=500"),
                       "jsonapi.php/v1/folders/:id/file-refs")
    }
}

final class StudIPImportTests: XCTestCase {

    private func file(_ id: String, course: String = "k1", size: Int = 100, changed: String = "t1", downloadable: Bool = true) -> StudIPFile {
        StudIPFile(id: id, courseID: course, name: "\(id).pdf", size: size, changed: changed, isDownloadable: downloadable)
    }

    /// Das eine Register der geladenen Dateien ist `files`: Liste fuer StudIPView ohne Kopien und eigene Dokumente,
    /// "nicht mehr vorhanden" nur in vollstaendig gelesenen Kursen (vorher aus index.json)
    func testDownloadedFilesAndGoneComeFromTheDatabase() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-10-26T09:00:00")!, university: "luh")
        let base = URL(string: "https://studip.test")!
        let files = [file("weg"), file("da"), file("anderer", course: "k2")]
        try await db.transaction { c in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "k1", title: "Kurs A"), StudIPCourse(id: "k2", title: "Kurs B")], startedAt: "2026-10-26T09:00:00")
            _ = try StudIPLibrary.storeFiles(c, files, startedAt: "2026-10-26T09:00:00", base: base, localFiles: nil)
            for f in files {
                try UniStore.markDownloaded(c, StudIPLibrary.fileRow(f, base: base), localPath: "StudIP/files/\(f.id)/\(f.id).pdf", sha256: nil, now: "2026-10-26T09:00:00")
            }
            // Kopie ("Duplizieren") teilt Ablageort und Adresse; eigene Dokumente liegen woanders
            try c.execute("""
                INSERT INTO files(id, course_id, name, download_url, local_path, kind) SELECT 'u0123456789abcdef0123456', course_id,
                       name, download_url, local_path, kind FROM files WHERE id='da'
                """)
            try c.execute("UPDATE files SET name='da neu.pdf', studip_folder='Woche 2' WHERE id='da'")
        }
        let listed = try await db.withConnection { try StudIPLibrary.downloadedFiles($0, under: "StudIP/") }
        XCTAssertEqual(listed.map(\.id), ["weg", "da", "anderer"], "nach Kurs, Ordner und Name, ohne die Kopie")
        let da = try XCTUnwrap(listed.first { $0.id == "da" })
        XCTAssertEqual(da.name, "da neu.pdf", "Name und Ordner wie in der Datenbank, auch nach einer Umbenennung")
        XCTAssertEqual(da.folder, "Woche 2")
        XCTAssertEqual(da.courseTitle, "Kurs A")
        XCTAssertEqual(da.localPath, "StudIP/files/da/da.pdf")
        let gone = try await db.withConnection {
            try StudIPLibrary.goneRemotely($0, remoteIDs: ["da"], checkedCourses: ["k1"], under: "StudIP/")
        }
        XCTAssertEqual(gone, ["weg"], "nur in abgeglichenen Kursen, ohne Kopie")
    }

    /// Neue Kurse des juengsten Semesters kommen von selbst dazu, aeltere werden gemeldet; abgewaehlte bleiben
    /// abgewaehlt, eine leere Auswahl bleibt leer (vorher galt nur die Auswahl des ersten Abgleichs)
    func testCourseSelectionTakesNewCoursesAndKeepsChoices() {
        let wise = [StudIPCourse(id: "a", title: "A", semesterStart: "2026-10-01"), StudIPCourse(id: "b", title: "B", semesterStart: "2026-10-01"),
                    StudIPCourse(id: "alt", title: "Alt", semesterStart: "2026-04-01")]
        let first = StudIPImport.selection(courses: wise, selected: [], known: nil)
        XCTAssertEqual(first.selected, ["a", "b"])
        XCTAssertEqual(first.known, ["a", "b", "alt"])
        // b abgewaehlt; spaeter belegt: c (jetziges Semester) kommt dazu, ein altes Semester nur als Hinweis
        let later = wise + [StudIPCourse(id: "c", title: "C", semesterStart: "2026-10-01"), StudIPCourse(id: "alt2", title: "Alt 2", semesterStart: "2026-04-01")]
        let second = StudIPImport.selection(courses: later, selected: ["a"], known: first.known)
        XCTAssertEqual(second.selected, ["a", "c"])
        XCTAssertEqual(second.newUnselected.map(\.id), ["alt2"])
        // naechstes Semester: neue Kurse des neuen juengsten Semesters
        let summer = later + [StudIPCourse(id: "s1", title: "S1", semesterStart: "2027-04-01")]
        XCTAssertEqual(StudIPImport.selection(courses: summer, selected: ["a", "c"], known: second.known).selected, ["a", "c", "s1"])
        // alles abgewaehlt: bleibt leer
        XCTAssertEqual(StudIPImport.selection(courses: later, selected: [], known: second.known).selected, [])
        // eine Auswahl von vor dieser Regel bleibt, nichts kommt still dazu
        XCTAssertEqual(StudIPImport.selection(courses: later, selected: ["alt"], known: nil).selected, ["alt"])
    }

    func testSafeFileName() {
        let evil = StudIPImport.safeFileName("../../etc/passwd")
        XCTAssertFalse(evil.contains("/"))
        XCTAssertFalse(evil.hasPrefix("."))
        XCTAssertEqual(StudIPImport.safeFileName("Blatt 1: Vektoren?.pdf"), "Blatt 1_ Vektoren_.pdf")
        XCTAssertEqual(StudIPImport.safeFileName("  \n "), "datei")
        XCTAssertEqual(StudIPImport.safeFileName("a\u{0}b\\c.pdf"), "a_b_c.pdf")
        let long = StudIPImport.safeFileName(String(repeating: "x", count: 300) + ".pdf")
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        XCTAssertEqual(StudIPImport.relativePath(for: file("f1")), "files/f1/f1.pdf")
    }

    func testDefaultSelectionPicksNewestSemester() {
        let courses = [StudIPCourse(id: "alt", title: "A", semesterStart: "2026-04-01"),
                       StudIPCourse(id: "neu1", title: "B", semesterStart: "2026-10-01"),
                       StudIPCourse(id: "neu2", title: "C", semesterStart: "2026-10-01"),
                       StudIPCourse(id: "ohne", title: "D")]
        XCTAssertEqual(StudIPImport.defaultSelection(courses), ["neu1", "neu2"])
        XCTAssertEqual(StudIPImport.defaultSelection([StudIPCourse(id: "x", title: "X")]), ["x"])
    }
}

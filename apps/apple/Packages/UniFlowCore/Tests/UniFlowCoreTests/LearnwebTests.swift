import Foundation
import XCTest
@testable import UniFlowCore

/// Learnweb (Moodle) wie app/learnweb.py und tests/test_hildesheim.py, ohne Netzwerk: alle Antworten kommen aus
/// `FakeLearnweb`. Schluessel, sesskey und Kennungen sind erfunden.
final class LearnwebTests: XCTestCase {

    private func repoFile(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private let base = URL(string: "https://www.uni-hildesheim.de/learnweb2026")!
    private let token = LearnwebToken("TOKEN123abcdef0123456789")!
    /// keine echten Pausen in Tests
    private let noWait = LearnwebRetry(attempts: 3, baseDelayMillis: 1, sleep: { _ in })

    // MARK: Gemeinsame Fixtures (dieselben Erwartungen wie der PC)

    func testSharedFixtureLearnwebFilesMatchExpected() throws {
        let dir = "packages/shared-contracts/fixtures/hildesheim/"
        let expected = try JSONValue.parse(repoFile(dir + "expected.json"))
        let files = LearnwebParsing.filesFromContents(try JSONValue.parse(repoFile(dir + "learnweb-course-contents.json")))
        let want = expected["learnweb-course-contents.json"]?.array ?? []
        XCTAssertEqual(files.count, want.count)
        for (f, w) in zip(files, want) {
            XCTAssertEqual(f.id, w["id"]?.string)
            XCTAssertEqual(f.name, w["name"]?.string)
            XCTAssertEqual(f.chdate, w["chdate"]?.int)
            XCTAssertEqual(f.downloadURL, w["download_url"]?.string)
            XCTAssertEqual(f.folder, w["folder"]?.string)
        }
        // NFD im Fixture (u + U+0308) -> NFC wie auf dem PC
        let raw = try JSONValue.parse(repoFile(dir + "learnweb-course-contents.json"))
        let nfdName = raw.array?[1]["modules"]?.array?[0]["contents"]?.array?[0]["filename"]?.string ?? ""
        XCTAssertTrue(nfdName.unicodeScalars.contains("\u{0308}"), "Fixture enthaelt NFD")
        XCTAssertEqual(Array(files[1].name.unicodeScalars), Array("Einf\u{00FC}hrung.pdf".unicodeScalars))
        XCTAssertEqual(files[1].id, "lw-80-c0ee9bd7")

        let titles = expected["course-titles"]?.object ?? [:]
        XCTAssertEqual(titles.count, 3)
        for (t, w) in titles {
            let p = LearnwebParsing.parseCourseTitle(t)
            XCTAssertEqual(p.semester, w["semester"]?.string, t)
            XCTAssertEqual(p.number, w["number"]?.string, t)
            XCTAssertEqual(p.title, w["title"]?.string, t)
        }
    }

    // MARK: Hilfsfunktionen (test_hildesheim.py)

    func testSectionLabelJoinAndMime() {
        XCTAssertEqual(LearnwebParsing.sectionLabel("3"), "Woche 3")
        XCTAssertEqual(LearnwebParsing.sectionLabel(" 12 "), "Woche 12")
        XCTAssertEqual(LearnwebParsing.sectionLabel("123"), "123")
        XCTAssertEqual(LearnwebParsing.sectionLabel("Informationen", number: 0), "Informationen")
        XCTAssertEqual(LearnwebParsing.sectionLabel("", number: 4), "Abschnitt 4")
        XCTAssertEqual(LearnwebParsing.sectionLabel(nil, number: 0), "")
        XCTAssertEqual(LearnwebParsing.joinFolder("Woche 1", "/Teil 1/", "", nil, " / "), "Woche 1/Teil 1")
        XCTAssertEqual(LearnwebParsing.guessMime("a.PDF"), "application/pdf")
        XCTAssertNil(LearnwebParsing.guessMime("ohne-endung"))
        XCTAssertEqual(LearnwebParsing.stripForcedownload("https://x/a.pdf?forcedownload=1"), "https://x/a.pdf")
    }

    func testParsePluginfileLikePython() {
        let p = LearnwebParsing.parsePluginfile("https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/4711/mod_resource/content/3/01%20KP%20Garbade.pdf?forcedownload=1")
        XCTAssertEqual(p, .init(area: "resource", revision: 3, filepath: "/", filename: "01 KP Garbade.pdf"))
        let q = LearnwebParsing.parsePluginfile("https://x/learnweb2026/pluginfile.php/9/mod_folder/content/12/Kapitel%201/Text.pdf")
        XCTAssertEqual(q?.filepath, "/Kapitel 1/")
        XCTAssertEqual(q?.filename, "Text.pdf")
        XCTAssertEqual(q?.revision, 12)
        XCTAssertNil(LearnwebParsing.parsePluginfile("https://x/learnweb2026/mod/resource/view.php?id=1"))
        // NFD in der Adresse -> NFC (test_names_are_nfc)
        let n = LearnwebParsing.parsePluginfile("https://x/pluginfile.php/1/mod_resource/content/2/Einfu%CC%88hrung.pdf")
        XCTAssertEqual(n?.filename, "Einf\u{00FC}hrung.pdf")
        XCTAssertEqual(LearnwebParsing.fileID(cmid: "1", filepath: "/", filename: "Einfu\u{0308}hrung.pdf"),
                       LearnwebParsing.fileID(cmid: "1", filepath: "/", filename: "Einf\u{00FC}hrung.pdf"))
        XCTAssertEqual(LearnwebParsing.fileID(cmid: "77", filepath: "", filename: "plan.pdf"), "lw-77-ce50f85d", "leerer Pfad = '/'")
        // kaputte Prozent-Folgen stuerzen nicht ab
        XCTAssertEqual(LearnwebParsing.parsePluginfile("https://x/pluginfile.php/1/mod_resource/content/2/a%ZZ%E2.pdf")?.revision, 2)
    }

    func testFilesFromContentsRest() throws {
        let sections = try JSONValue.parse("""
        [{"id": 1, "section": 0, "name": "Informationen", "modules": [
          {"id": 77, "name": "Seminarplan", "modname": "resource", "contents": [
            {"type": "file", "filename": "plan.pdf", "filepath": "/", "filesize": 1200, "timemodified": 1760000000,
             "fileurl": "https://www.uni-hildesheim.de/learnweb2026/webservice/pluginfile.php/5/mod_resource/content/1/plan.pdf?forcedownload=1",
             "mimetype": "application/pdf"}]},
          {"id": 78, "name": "Forum", "modname": "forum"}]},
         {"id": 2, "section": 1, "name": "1", "modules": [
          {"id": 80, "name": "Literatur", "modname": "folder", "contents": [
            {"type": "file", "filename": "a.pdf", "filepath": "/Teil 1/", "filesize": 5, "timemodified": 1760000001,
             "fileurl": "https://www.uni-hildesheim.de/learnweb2026/webservice/pluginfile.php/6/mod_folder/content/2/Teil%201/a.pdf"},
            {"type": "url", "filename": "link", "fileurl": "https://example.org"}]}]}]
        """)
        let files = LearnwebParsing.filesFromContents(sections)
        XCTAssertEqual(files.map(\.name), ["plan.pdf", "a.pdf"])
        XCTAssertEqual(files[0].folder, "Informationen")
        XCTAssertEqual(files[0].chdate, 1760000000)
        XCTAssertEqual(files[0].size, 1200)
        XCTAssertFalse(files[0].downloadURL.contains("forcedownload"))
        XCTAssertFalse(files[0].downloadURL.contains("token"))
        XCTAssertEqual(files[1].folder, "Woche 1/Literatur/Teil 1")
        XCTAssertEqual(files[1].mime, "application/pdf")
        XCTAssertEqual(files[0].id, LearnwebParsing.fileID(cmid: "77", filepath: "/", filename: "plan.pdf"))
        XCTAssertEqual(files[0].moduleName, "Seminarplan")
    }

    func testFilesFromStateSessionMode() async throws {
        let state = try JSONValue.parse("""
        {"section": [{"id": "10", "number": 0, "title": "Informationen"}, {"id": "11", "number": 1, "title": "1"}],
         "cm": [{"id": "1", "module": "resource", "name": "Folien 1", "sectionid": "11"},
                {"id": "2", "module": "folder", "name": "Texte", "sectionid": "10"},
                {"id": "3", "module": "forum", "name": "Forum", "sectionid": "10"},
                {"id": "4", "module": "resource", "name": "versteckt", "sectionid": "10", "uservisible": false}]}
        """)
        let pf = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php"
        let html = "<a href=\"\(pf)/6/mod_folder/content/2/x.pdf?forcedownload=1\">x</a><a href=\"\(pf)/6/mod_folder/content/2/x.pdf\">x</a>"
        let files = try await LearnwebParsing.filesFromState(state, resourceLinks: { $0 == "1" ? ["\(pf)/5/mod_resource/content/4/Folien%201.pdf"] : [] },
                                                             folderLinks: { _ in LearnwebParsing.folderLinks(html: html) })
        XCTAssertEqual(files.map(\.name), ["Folien 1.pdf", "x.pdf"])
        XCTAssertEqual(files.map(\.folder), ["Woche 1", "Informationen/Texte"])
        XCTAssertEqual(files.map(\.chdate), [4, 2])
        XCTAssertEqual(files[1].downloadURL, "\(pf)/6/mod_folder/content/2/x.pdf")
    }

    func testCourseTitlesAndHiddenFlag() throws {
        let c = LearnwebParsing.course(try JSONValue.parse(#"{"id": 35, "fullname": "SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "hidden": 0}"#))
        XCTAssertEqual(c, LearnwebCourse(id: "lw-35", moodleID: 35, title: "0406 Theorien der Erziehungswissenschaft", number: "0406",
                                         semester: "SoSe 2026", hidden: false))
        XCTAssertEqual(LearnwebParsing.course(try JSONValue.parse(#"{"id": 9, "displayname": "WS 26: Mathe", "hidden": true}"#))?.hidden, true)
        XCTAssertNil(LearnwebParsing.course(try JSONValue.parse(#"{"fullname": "ohne id"}"#)))
    }

    func testChangeDetectionUsesHigherTimemodifiedOrRevision() {
        func f(_ id: String, _ ch: Int) -> LearnwebFile {
            LearnwebFile(id: id, name: "a.pdf", size: 1, mime: nil, author: nil, chdate: ch, downloadURL: "https://x/a.pdf", folder: "", moduleName: nil)
        }
        let remote = [f("lw-1-a", 5), f("lw-1-b", 3), f("lw-1-c", 2), f("lw-1-d", 9)]
        let known = ["lw-1-a": 5, "lw-1-b": 4, "lw-1-c": 1]
        XCTAssertEqual(LearnwebParsing.needsDownload(remote, known: known).map(\.id), ["lw-1-c", "lw-1-d"],
                       "unveraendert und niedriger: nichts laden; hoeher und neu: laden")
    }

    // MARK: REST mit Schluessel

    func testTokenClientCallsAndNeverPutsTokenIntoAddresses() async throws {
        let net = FakeLearnweb { req in
            let form = req.form
            switch form["wsfunction"] {
            case "core_webservice_get_site_info": return .json(#"{"userid": 42, "sitename": "Learnweb"}"#)
            case "core_enrol_get_users_courses":
                return .json(#"[{"id": 35, "fullname": "SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "hidden": 0}, {"id": 36, "fullname": "Alt", "hidden": 1}]"#)
            default: return .json(#"{"exception": "moodle_exception", "errorcode": "invalidrecord", "message": "Kurs fehlt TOKEN123abcdef0123456789"}"#)
            }
        }
        let c = LearnwebClient(base: URL(string: "https://www.uni-hildesheim.de/learnweb2026/")!, access: .token(token), transport: net, retry: noWait)
        let courses = try await c.courses()
        XCTAssertEqual(courses.map(\.id), ["lw-35", "lw-36"])
        XCTAssertEqual(courses[0].number, "0406")
        let reqs = net.requests
        XCTAssertEqual(reqs[0].url.absoluteString, "https://www.uni-hildesheim.de/learnweb2026/webservice/rest/server.php")
        XCTAssertEqual(reqs[0].method, .post)
        XCTAssertEqual(reqs[0].form["wstoken"], "TOKEN123abcdef0123456789")
        XCTAssertEqual(reqs[0].form["moodlewsrestformat"], "json")
        XCTAssertEqual(reqs[1].form["userid"], "42")
        for r in reqs { XCTAssertFalse(r.url.absoluteString.contains("TOKEN123"), "Token nie in der Adresse") }

        do {
            _ = try await c.files(courseID: 35)
            XCTFail("Fehler erwartet")
        } catch let e as LearnwebError {
            guard case .moodle(let fn, let code, let message) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(fn, "core_course_get_contents")
            XCTAssertEqual(code, "invalidrecord")
            XCTAssertFalse(message.contains("TOKEN123"), "Token aus Meldungen entfernt")
            XCTAssertFalse(e.description.contains("TOKEN123"))
        }
        XCTAssertFalse(String(describing: token).contains("TOKEN123"))
        XCTAssertFalse(String(reflecting: token).contains("TOKEN123"))
        XCTAssertEqual(token.keychainValue, "TOKEN123abcdef0123456789")
        XCTAssertNil(LearnwebToken("kurz"))
        XCTAssertNil(LearnwebToken("abc\nSTUDIP_USER=x0123456789abcdef"), "nur alphanumerisch")
    }

    func testInvalidTokenIsReported() async {
        let net = FakeLearnweb { _ in .json(#"{"exception": "moodle_exception", "errorcode": "invalidtoken", "message": "Ungültiges Token"}"#) }
        let c = LearnwebClient(base: base, access: .token(token), transport: net, retry: noWait)
        do { _ = try await c.courses(); XCTFail("Fehler erwartet") } catch {
            XCTAssertEqual(error as? LearnwebError, .tokenRejected)
        }
        XCTAssertEqual(net.requests.count, 1, "Moodle-Fehler werden nicht wiederholt")
    }

    func testDownloadSendsTokenOnlyInBodyAndOnlyToOwnHost() async throws {
        let pdf = Data("%PDF-1.7 test".utf8)
        let net = FakeLearnweb { _ in LearnwebReply(status: 200, contentType: "application/pdf", body: pdf) }
        let c = LearnwebClient(base: base, access: .token(token), transport: net, retry: noWait)
        let file = LearnwebParsing.filesFromContents(try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json")))[0]
        let data = try await c.download(file)
        XCTAssertEqual(data, pdf)
        let r = net.requests[0]
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.url.absoluteString, file.downloadURL)
        XCTAssertFalse(r.url.absoluteString.contains("token"))
        XCTAssertEqual(r.form["token"], "TOKEN123abcdef0123456789", "Token erst beim Abruf, im Koerper")
        XCTAssertFalse(r.description.contains("TOKEN123"))
        // fremder Rechner oder http: Token wird nie verschickt
        for bad in ["https://evil.example/learnweb2026/webservice/pluginfile.php/5/a.pdf", "http://www.uni-hildesheim.de/learnweb2026/a.pdf"] {
            let f = LearnwebFile(id: "lw-1-x", name: "a.pdf", size: 0, mime: nil, author: nil, chdate: 1, downloadURL: bad, folder: "", moduleName: nil)
            do { _ = try await c.download(f); XCTFail(bad) } catch { XCTAssertEqual(net.requests.count, 1, bad) }
        }
    }

    func testHtmlInsteadOfFileMeansSessionExpired() async throws {
        let replies: [String: LearnwebReply] = [
            "a.pdf": LearnwebReply(status: 200, contentType: "text/html", body: Data("\u{FEFF}\n  <!DOCTYPE html><html><body>Anmelden</body></html>".utf8)),
            "b.pdf": LearnwebReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"), body: Data("x".utf8)),
            "c.pdf": LearnwebReply(status: 200, contentType: "application/json", body: Data(#"{"error":"Ungültiges Token","errorcode":"invalidtoken"}"#.utf8)),
            "seite.html": LearnwebReply(status: 200, contentType: "text/html", body: Data("<html><body>Inhalt</body></html>".utf8)),
            "d.pdf": LearnwebReply(status: 404, body: Data()),
        ]
        let net = FakeLearnweb { req in replies[req.url.lastPathComponent] ?? LearnwebReply(status: 500) }
        let c = LearnwebClient(base: base, access: .session(LearnwebSession(sesskey: "abcSESS1")!), transport: net, retry: noWait)
        func file(_ name: String) -> LearnwebFile {
            LearnwebFile(id: "lw-1-\(name)", name: name, size: 0, mime: nil, author: nil, chdate: 1,
                         downloadURL: "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/5/mod_resource/content/1/\(name)", folder: "", moduleName: nil)
        }
        for (name, want) in [("a.pdf", LearnwebError.sessionExpired), ("b.pdf", .sessionExpired), ("c.pdf", .tokenRejected)] {
            do { _ = try await c.download(file(name)); XCTFail(name) } catch { XCTAssertEqual(error as? LearnwebError, want, name) }
        }
        let page = try await c.download(file("seite.html"))
        XCTAssertEqual(String(decoding: page, as: UTF8.self), "<html><body>Inhalt</body></html>", "echte HTML-Dateien bleiben erlaubt")
        do { _ = try await c.download(file("d.pdf")); XCTFail() } catch {
            guard case .http(404, let path)? = error as? LearnwebError else { return XCTFail("\(error)") }
            XCTAssertFalse(path.contains("?"))
        }
        XCTAssertEqual(net.requests.first?.method, .get, "Sitzung: GET mit Cookies, ohne Token")
    }

    // MARK: Wiederholen und Ausfallsicherheit

    func testRetriesNetworkErrorsWithBackoff() async throws {
        let sleeps = Recorder<UInt64>()
        let retry = LearnwebRetry(attempts: 3, baseDelayMillis: 100, sleep: { sleeps.add($0) })
        var calls = 0
        let net = FakeLearnweb { _ in
            calls += 1
            if calls < 3 { throw URLError(.timedOut) }
            return .json(#"{"userid": 7}"#)
        }
        let c = LearnwebClient(base: base, access: .token(token), transport: net, retry: retry)
        let info = try await c.call("core_webservice_get_site_info", [])
        XCTAssertEqual(info["userid"], 7)
        XCTAssertEqual(net.requests.count, 3)
        XCTAssertEqual(sleeps.values, [100_000_000, 200_000_000], "Pause waechst")

        let down = FakeLearnweb { _ in throw URLError(.notConnectedToInternet) }
        let c2 = LearnwebClient(base: base, access: .token(token), transport: down, retry: noWait)
        do { _ = try await c2.courses(); XCTFail() } catch {
            guard case .network? = error as? LearnwebError else { return XCTFail("\(error)") }
            XCTAssertFalse(String(describing: error).contains("TOKEN123"))
        }
        XCTAssertEqual(down.requests.count, 3, "hoechstens 3 Versuche")

        var n = 0
        let busy = FakeLearnweb { _ in n += 1; return n == 1 ? LearnwebReply(status: 503) : .json(#"{"userid": 8}"#) }
        let c3 = LearnwebClient(base: base, access: .token(token), transport: busy, retry: noWait)
        let again = try await c3.call("core_webservice_get_site_info", [])
        XCTAssertEqual(again["userid"], 8)
        XCTAssertEqual(busy.requests.count, 2)
    }

    func testOneBrokenCourseSkipsOnlyThatCourse() async throws {
        let net = FakeLearnweb { req in
            let f = req.form
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return .json(#"{"userid": 1}"#)
            case "core_enrol_get_users_courses":
                return .json(#"[{"id": 101, "fullname": "SoSe 2026: 0101 Eins"}, {"id": 102, "fullname": "SoSe 2026: 0102 Zwei"}, {"id": 103, "fullname": "WiSe 2026/27: 0103 Drei"}, {"id": 104, "fullname": "Versteckt", "hidden": 1}]"#)
            default:
                if f["courseid"] == "102" { throw URLError(.timedOut) }
                return .json(#"[{"id": 1, "section": 1, "name": "1", "modules": [{"id": 5, "modname": "resource", "name": "F", "contents": [{"type": "file", "filename": "a.pdf", "filepath": "/", "timemodified": 3, "fileurl": "https://www.uni-hildesheim.de/learnweb2026/webservice/pluginfile.php/1/mod_resource/content/1/a.pdf"}]}]}]"#)
            }
        }
        let c = LearnwebClient(base: base, access: .token(token), transport: net, retry: noWait)
        let snap = try await c.fetchAll()
        XCTAssertEqual(snap.courses.map(\.id), ["lw-101", "lw-102", "lw-103"], "versteckte Kurse nicht")
        XCTAssertEqual(Set(snap.files.keys), ["lw-101", "lw-103"])
        XCTAssertEqual(snap.files["lw-101"]?.first?.folder, "Woche 1")
        XCTAssertNotNil(snap.failures["lw-102"])
        XCTAssertFalse(snap.needsLogin)
        XCTAssertFalse(snap.failures.values.contains { $0.contains("TOKEN123") })
        let filtered = try await c.fetchAll(semesterFilter: "wise")
        XCTAssertEqual(filtered.courses.map(\.id), ["lw-103"])
    }

    func testExpiredSessionStopsAndKeepsEarlierCourses() async throws {
        let net = FakeLearnweb { req in
            let info = req.url.query ?? ""
            if info.contains("timeline_classification") {
                return .ajax(#"{"courses": [{"id": 1, "fullname": "A"}, {"id": 2, "fullname": "B"}, {"id": 3, "fullname": "C"}]}"#)
            }
            let id = (try? JSONValue.parse(req.body ?? Data()))?.array?.first?["args"]?["courseid"]?.int
            if id == 2 { return LearnwebReply(status: 200, contentType: "application/json", body: Data(#"[{"error": true, "exception": {"errorcode": "servicerequireslogin", "message": "x"}}]"#.utf8)) }
            return .ajax(.string(#"{"section": [], "cm": []}"#))
        }
        let c = LearnwebClient(base: base, access: .session(LearnwebSession(sesskey: "abcSESS1")!), transport: net, retry: noWait)
        let snap = try await c.fetchAll()
        XCTAssertTrue(snap.needsLogin)
        XCTAssertEqual(snap.files.keys.sorted(), ["lw-1"], "schon geholte Kurse bleiben")
        XCTAssertEqual(snap.notAttempted, ["lw-2", "lw-3"])
        XCTAssertTrue(snap.failures.isEmpty)
    }

    // MARK: AJAX mit Sitzung

    func testSessionModeAjaxResourceRedirectAndFolderPage() async throws {
        let pf = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php"
        let state = #"{"section": [{"id": "10", "number": 1, "title": "1"}], "cm": [{"id": "7", "module": "resource", "name": "Folien", "sectionid": "10"}, {"id": "8", "module": "folder", "name": "Texte", "sectionid": "10"}, {"id": "9", "module": "resource", "name": "Eingebettet", "sectionid": "10"}]}"#
        let net = FakeLearnweb { req in
            let u = req.url.absoluteString
            if u.contains("/lib/ajax/service.php") {
                if u.contains("info=core_courseformat_get_state") { return .ajax(.string(state)) }
                return .ajax(#"{"courses": [{"id": 35, "fullname": "SoSe 2026: 0406 Theorien", "hidden": false}]}"#)
            }
            if u.contains("mod/resource/view.php?id=7&redirect=1") {
                XCTAssertFalse(req.followRedirects)
                return LearnwebReply(status: 303, location: "\(pf)/5/mod_resource/content/4/Folien.pdf")
            }
            if u.contains("mod/resource/view.php?id=9") {
                return LearnwebReply(status: 200, contentType: "text/html", body: Data("<object data=\"\(pf)/6/mod_resource/content/2/Eingebettet.pdf\"></object>".utf8))
            }
            if u.contains("mod/folder/view.php?id=8") {
                return LearnwebReply(status: 200, contentType: "text/html", body: Data("<a href=\"\(pf)/7/mod_folder/content/3/Kap%201/x.pdf?forcedownload=1\">x</a>".utf8))
            }
            return LearnwebReply(status: 404)
        }
        let c = LearnwebClient(base: base, access: .session(LearnwebSession(sesskey: "abcSESS1")!), transport: net, retry: noWait)
        let courses = try await c.courses()
        XCTAssertEqual(courses.map(\.title), ["0406 Theorien"])
        let first = net.requests[0]
        XCTAssertEqual(first.url.absoluteString, "https://www.uni-hildesheim.de/learnweb2026/lib/ajax/service.php?sesskey=abcSESS1&info=core_course_get_enrolled_courses_by_timeline_classification")
        XCTAssertEqual(first.contentType, "application/json")
        let payload = try JSONValue.parse(first.body ?? Data())
        XCTAssertEqual(payload.array?.first?["methodname"], "core_course_get_enrolled_courses_by_timeline_classification")
        XCTAssertEqual(payload.array?.first?["args"]?["classification"], "all")
        XCTAssertFalse(first.description.contains("abcSESS1"), "sesskey nicht in Beschreibungen")
        XCTAssertFalse(String(describing: LearnwebSession(sesskey: "abcSESS1")!).contains("abcSESS1"))

        let files = try await c.files(courseID: 35)
        XCTAssertEqual(files.map(\.name), ["Folien.pdf", "x.pdf", "Eingebettet.pdf"])
        XCTAssertEqual(files.map(\.folder), ["Woche 1", "Woche 1/Texte/Kap 1", "Woche 1"])
        XCTAssertEqual(files.map(\.chdate), [4, 3, 2], "Revision im Pluginfile-Pfad")
    }

    func testSessionRedirectToLoginIsExpired() async {
        let net = FakeLearnweb { req in
            if req.url.absoluteString.contains("core_courseformat_get_state") {
                return .ajax(.string(#"{"section": [], "cm": [{"id": "7", "module": "resource", "name": "F", "sectionid": "1"}]}"#))
            }
            return LearnwebReply(status: 303, location: "https://www.uni-hildesheim.de/learnweb2026/login/index.php")
        }
        let c = LearnwebClient(base: base, access: .session(LearnwebSession(sesskey: "abc")!), transport: net, retry: noWait)
        do { _ = try await c.files(courseID: 1); XCTFail() } catch { XCTAssertEqual(error as? LearnwebError, .sessionExpired) }

        let cas = FakeLearnweb { _ in LearnwebReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"), body: Data("<html>".utf8)) }
        let c2 = LearnwebClient(base: base, access: .session(LearnwebSession(sesskey: "abc")!), transport: cas, retry: noWait)
        do { _ = try await c2.courses(); XCTFail() } catch { XCTAssertEqual(error as? LearnwebError, .sessionExpired) }
    }

    func testSesskeyFromPage() {
        let page = #"<html><body class="path-my safari"><script>M.cfg = {"wwwroot":"https:\/\/www.uni-hildesheim.de\/learnweb2026","sesskey":"Ab12Cd34Ef","sessiontimeout":"28800"};</script></body></html>"#
        XCTAssertEqual(LearnwebSession.fromPage(html: page), LearnwebSession(sesskey: "Ab12Cd34Ef"))
        let out = page.replacingOccurrences(of: "path-my safari", with: "path-login notloggedin")
        XCTAssertFalse(LearnwebSession.isLoggedIn(html: out))
        XCTAssertNil(LearnwebSession.fromPage(html: out))
        XCTAssertNil(LearnwebSession(sesskey: "a\"b"))
    }
}

// MARK: - Testhilfen

/// Learnweb ohne Netz: beantwortet jede Anfrage mit `handler` und merkt sich die Anfragen.
final class FakeLearnweb: LearnwebTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [LearnwebRequest] = []
    private let handler: (LearnwebRequest) throws -> LearnwebReply

    init(_ handler: @escaping (LearnwebRequest) throws -> LearnwebReply) { self.handler = handler }

    var requests: [LearnwebRequest] { lock.lock(); defer { lock.unlock() }; return log }

    func send(_ request: LearnwebRequest) async throws -> LearnwebReply {
        record(request)
        return try handler(request)
    }

    private func record(_ request: LearnwebRequest) {
        lock.lock()
        log.append(request)
        lock.unlock()
    }
}

final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

extension LearnwebRequest {
    /// Formular-Koerper als Woerterbuch (nur fuer Tests)
    var form: [String: String] {
        guard let body, contentType == "application/x-www-form-urlencoded" else { return [:] }
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

extension LearnwebReply {
    static func json(_ text: String) -> LearnwebReply {
        LearnwebReply(status: 200, contentType: "application/json", body: Data(text.utf8))
    }

    /// AJAX-Antwort [{"error": false, "data": ...}]
    static func ajax(_ data: String) -> LearnwebReply { ajax((try? JSONValue.parse(data)) ?? .null) }

    static func ajax(_ data: JSONValue) -> LearnwebReply {
        let v: JSONValue = [["error": false, "data": data]]
        return LearnwebReply(status: 200, contentType: "application/json", body: v.serialized())
    }
}

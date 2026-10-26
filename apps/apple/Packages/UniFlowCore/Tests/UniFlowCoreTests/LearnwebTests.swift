import Foundation
import XCTest
@testable import UniFlowCore

/// Learnweb (Moodle) wie app/learnweb.py und tests/test_hildesheim.py, ohne Netzwerk: eine Fassung (`Learnweb`,
/// `LearnwebAPI`, `HildesheimSync`), alle Antworten kommen aus `FakeUniTransport`. Schluessel, sesskey und Kennungen
/// sind erfunden. Die Faelle stammen aus beiden frueheren Fassungen (Mac `LearnwebClient`, PC `LearnwebAPI`).
final class LearnwebTests: XCTestCase {

    private func repoFile(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private let base = "https://www.uni-hildesheim.de/learnweb2026"
    private let token = LearnwebToken("TOKEN123abcdef0123456789")!
    /// keine echten Pausen in Tests
    private let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })
    private let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))

    private func form(_ r: UniRequest) -> [String: String] {
        guard let body = r.body, r.headers["Content-Type"] == "application/x-www-form-urlencoded" else { return [:] }
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// Ausgabe von `dump` (Mirror) als Text
    private func dumped(_ value: Any) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }

    private func json(_ text: String, url: String? = nil) -> UniResponse {
        UniResponse(status: 200, finalURL: url.flatMap(URL.init(string:)), body: Data(text.utf8))
    }

    /// AJAX-Antwort [{"error": false, "data": ...}]
    private func ajax(_ data: JSONValue) -> UniResponse { okJSON(.array([.object(["error": .bool(false), "data": data])])) }
    private func ajax(_ data: String) -> UniResponse { ajax((try? JSONValue.parse(data)) ?? .null) }

    private let sessionPage = #"<html><body class="path-my"><script>M.cfg = {"sesskey":"abcSESS1"};</script></body></html>"#

    /// Container der Uni Hildesheim mit Datenbank (Temp-Ordner, erfundener Nutzer)
    private func container() async throws -> (SQLiteDatabase, DataContainerLayout) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.erfunden.0001", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        return (db, layout)
    }

    // MARK: Gemeinsame Fixtures (dieselben Erwartungen wie der PC)

    func testSharedFixtureKeepsNFCAndModuleNames() throws {
        let dir = "packages/shared-contracts/fixtures/hildesheim/"
        let expected = try JSONValue.parse(repoFile(dir + "expected.json"))
        let raw = try JSONValue.parse(repoFile(dir + "learnweb-course-contents.json"))
        let files = Learnweb.filesFromContents(raw)
        // NFD im Fixture (u + U+0308) -> NFC wie auf dem PC, auch in der Datei-ID
        let nfdName = raw.array?[1]["modules"]?.array?[0]["contents"]?.array?[0]["filename"]?.string ?? ""
        XCTAssertTrue(nfdName.unicodeScalars.contains("\u{0308}"), "Fixture enthaelt NFD")
        XCTAssertEqual(Array(files[1].name.unicodeScalars), Array("Einf\u{00FC}hrung.pdf".unicodeScalars))
        XCTAssertEqual(files[1].id, expected["learnweb-course-contents.json"]?.array?[1]["id"]?.string)
        XCTAssertEqual(files.map(\.moduleName), [raw.array?[0]["modules"]?.array?[0]["name"]?.string,
                                                 raw.array?[1]["modules"]?.array?[0]["name"]?.string], "module_name wie Python")
    }

    // MARK: Hilfsfunktionen (test_hildesheim.py)

    func testSectionLabelJoinAndMime() {
        XCTAssertEqual(Learnweb.sectionLabel("3", number: nil), "Woche 3")
        XCTAssertEqual(Learnweb.sectionLabel(" 12 ", number: nil), "Woche 12")
        XCTAssertEqual(Learnweb.sectionLabel("123", number: nil), "123")
        XCTAssertEqual(Learnweb.sectionLabel("Informationen", number: 0), "Informationen")
        XCTAssertEqual(Learnweb.sectionLabel("", number: 4), "Abschnitt 4")
        XCTAssertEqual(Learnweb.sectionLabel(nil, number: 0), "")
        XCTAssertEqual(Learnweb.joinFolder("Woche 1", "/Teil 1/", "", " / "), "Woche 1/Teil 1")
        XCTAssertEqual(Learnweb.guessMime("a.PDF"), "application/pdf")
        XCTAssertEqual(Learnweb.guessMime("Folien.pptx"), "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        XCTAssertEqual(Learnweb.guessMime("Vorlesung.mp4"), "video/mp4")
        XCTAssertNil(Learnweb.guessMime("ohne-endung"))
        XCTAssertNil(Learnweb.guessMime(".versteckt"))
        XCTAssertEqual(Learnweb.stripForceDownload("https://x/a.pdf?forcedownload=1"), "https://x/a.pdf")
    }

    func testParsePluginfileLikePython() {
        let p = Learnweb.parsePluginfile("https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/4711/mod_resource/content/3/01%20KP%20Garbade.pdf?forcedownload=1")
        XCTAssertEqual(p, .init(area: "resource", revision: 3, filepath: "/", filename: "01 KP Garbade.pdf"))
        let q = Learnweb.parsePluginfile("https://x/learnweb2026/pluginfile.php/9/mod_folder/content/12/Kapitel%201/Text.pdf")
        XCTAssertEqual(q?.filepath, "/Kapitel 1/")
        XCTAssertEqual(q?.filename, "Text.pdf")
        XCTAssertEqual(q?.revision, 12)
        XCTAssertNil(Learnweb.parsePluginfile("https://x/learnweb2026/mod/resource/view.php?id=1"))
        // NFD in der Adresse -> NFC (test_names_are_nfc)
        let n = Learnweb.parsePluginfile("https://x/pluginfile.php/1/mod_resource/content/2/Einfu%CC%88hrung.pdf")
        XCTAssertEqual(n?.filename, "Einf\u{00FC}hrung.pdf")
        XCTAssertEqual(Learnweb.fileID(cmid: "1", filepath: "/", filename: "Einfu\u{0308}hrung.pdf"),
                       Learnweb.fileID(cmid: "1", filepath: "/", filename: "Einf\u{00FC}hrung.pdf"))
        XCTAssertEqual(Learnweb.fileID(cmid: "77", filepath: "", filename: "plan.pdf"), "lw-77-b77af79f", "leerer Pfad = '/' (SHA-256 wie Python)")
        // kaputte Prozent-Folgen stuerzen nicht ab und werden wie urllib.parse.unquote behandelt
        let broken = Learnweb.parsePluginfile("https://x/pluginfile.php/1/mod_resource/content/2/a%ZZ%E2.pdf")
        XCTAssertEqual(broken?.revision, 2)
        XCTAssertEqual(broken?.filename, "a%ZZ\u{FFFD}.pdf")
        // Leerzeichen in der Adresse (URLComponents lehnt sie ab): Pfad trotzdem ohne Abfrage
        XCTAssertEqual(Learnweb.parsePluginfile("https://x/pluginfile.php/1/mod_folder/content/5/mit leer.pdf?forcedownload=1")?.filename,
                       "mit leer.pdf")
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
        let files = Learnweb.filesFromContents(sections)
        XCTAssertEqual(files.map(\.name), ["plan.pdf", "a.pdf"])
        XCTAssertEqual(files[0].folder, "Informationen")
        XCTAssertEqual(files[0].chdate, 1760000000)
        XCTAssertEqual(files[0].size, 1200)
        XCTAssertFalse(files[0].downloadURL.contains("forcedownload"))
        XCTAssertFalse(files[0].downloadURL.contains("token"))
        XCTAssertEqual(files[1].folder, "Woche 1/Literatur/Teil 1")
        XCTAssertEqual(files[1].mime, "application/pdf")
        XCTAssertEqual(files[0].id, Learnweb.fileID(cmid: "77", filepath: "/", filename: "plan.pdf"))
        XCTAssertEqual(files[0].moduleName, "Seminarplan")
        XCTAssertEqual(files[1].row.folder, "Woche 1/Literatur/Teil 1")
    }

    func testFilesFromStateSessionMode() throws {
        let state = try JSONValue.parse("""
        {"section": [{"id": "10", "number": 0, "title": "Informationen"}, {"id": "11", "number": 1, "title": "1"}],
         "cm": [{"id": "1", "module": "resource", "name": "Folien 1", "sectionid": "11"},
                {"id": "2", "module": "folder", "name": "Texte", "sectionid": "10"},
                {"id": "3", "module": "forum", "name": "Forum", "sectionid": "10"},
                {"id": "4", "module": "resource", "name": "versteckt", "sectionid": "10", "uservisible": false}]}
        """)
        let pf = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php"
        let html = "<a href=\"\(pf)/6/mod_folder/content/2/x.pdf?forcedownload=1\">x</a><a href=\"\(pf)/6/mod_folder/content/2/x.pdf\">x</a>"
        let files = Learnweb.filesFromState(state, resourceLinks: { $0 == "1" ? ["\(pf)/5/mod_resource/content/4/Folien%201.pdf"] : [] },
                                            folderLinks: { _ in Learnweb.folderLinks(html: html) })
        XCTAssertEqual(files.map(\.name), ["Folien 1.pdf", "x.pdf"])
        XCTAssertEqual(files.map(\.folder), ["Woche 1", "Informationen/Texte"])
        XCTAssertEqual(files.map(\.chdate), [4, 2])
        XCTAssertEqual(files[1].downloadURL, "\(pf)/6/mod_folder/content/2/x.pdf")
        XCTAssertEqual(files.map(\.moduleName), ["Folien 1", "Texte"])
    }

    func testCourseTitlesAndHiddenFlag() throws {
        let c = Learnweb.course(try JSONValue.parse(#"{"id": 35, "fullname": "SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "hidden": 0}"#))
        XCTAssertEqual(c, Learnweb.Course(id: "lw-35", moodleID: 35, title: "0406 Theorien der Erziehungswissenschaft", number: "0406",
                                          semester: "SoSe 2026", hidden: false))
        XCTAssertEqual(Learnweb.course(try JSONValue.parse(#"{"id": 9, "displayname": "WS 26: Mathe", "hidden": true}"#))?.hidden, true)
        // wie int(c["id"]) und bool(c.get("hidden")) in Python
        XCTAssertEqual(Learnweb.course(try JSONValue.parse(#"{"id": "12", "fullname": "", "displayname": "Ersatz"}"#))?.id, "lw-12")
        XCTAssertEqual(Learnweb.course(try JSONValue.parse(#"{"id": "12", "fullname": "", "displayname": "Ersatz"}"#))?.title, "Ersatz")
        XCTAssertNil(Learnweb.course(try JSONValue.parse(#"{"fullname": "ohne id"}"#)))
    }

    // MARK: Aenderungen (UniStore, dieselbe Fassung wie Stud.IP)

    private func row(_ id: String, _ chdate: Int) -> UniStore.FileRow {
        // eigene Adresse je Datei: Kopien erkennt markDownloaded an derselben Quelle
        UniStore.FileRow(id: id, name: "a.pdf", size: 1, mime: nil, chdate: chdate, downloadURL: "https://x/\(id).pdf", folder: nil)
    }

    func testChangeDetectionUsesHigherTimemodifiedOrRevisionAndRetriesMissingCopies() async throws {
        let (db, layout) = try await container()
        let files = layout.files()
        let known = [row("lw-1-a", 5), row("lw-1-b", 4), row("lw-1-c", 1), row("lw-1-e", 5), row("lw-1-f", 4)]
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "Kurs", number: nil, semester: nil), now: "t0")
            _ = try UniStore.storeFiles(c, courseID: "lw-1", known, now: "t0", fileExists: { _ in false })
        }
        // a, b, c geladen und vorhanden; e geladen, aber lokal geloescht; f nie geladen
        for f in known.prefix(4) {
            let rel = "Learnweb/files/\(f.id)/a.pdf"
            if f.id != "lw-1-e" { _ = try files.write(Data("%PDF".utf8), to: rel) }
            try await db.transaction { try UniStore.markDownloaded($0, f, localPath: rel, sha256: nil, now: "t1") }
        }
        let remote = [row("lw-1-a", 5), row("lw-1-b", 3), row("lw-1-c", 2), row("lw-1-d", 9), row("lw-1-e", 5), row("lw-1-f", 4)]
        let todo = try await db.transaction { c in
            try UniStore.storeFiles(c, courseID: "lw-1", remote, now: "t2", fileExists: { files.exists(stored: $0) })
        }
        XCTAssertEqual(todo.map(\.id), ["lw-1-c", "lw-1-d", "lw-1-e", "lw-1-f"],
                       "unveraendert und niedriger: nichts laden; hoeher, neu, ohne lokale Kopie oder nie geladen: laden")
    }

    // MARK: REST mit Schluessel

    func testTokenClientCallsAndNeverPutsTokenIntoAddressesOrMessages() async throws {
        let net = FakeUniTransport { req in
            let f = self.form(req)
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return self.json(#"{"userid": 42, "sitename": "Learnweb"}"#)
            case "core_enrol_get_users_courses":
                return self.json(#"[{"id": 35, "fullname": "SoSe 2026: 0406 Theorien der Erziehungswissenschaft", "hidden": 0}, {"id": 36, "fullname": "Alt", "hidden": 1}]"#)
            default: return self.json(#"{"exception": "moodle_exception", "errorcode": "invalidrecord", "message": "Kurs fehlt TOKEN123abcdef0123456789"}"#)
            }
        }
        let c = LearnwebAPI(base: base + "/", mode: .token(token), transport: net, retry: noWait)
        let courses = try await c.courses()
        XCTAssertEqual(courses.map(\.id), ["lw-35", "lw-36"])
        XCTAssertEqual(courses[0].number, "0406")
        let reqs = net.requests
        XCTAssertEqual(reqs[0].url.absoluteString, "https://www.uni-hildesheim.de/learnweb2026/webservice/rest/server.php")
        XCTAssertEqual(reqs[0].method, "POST")
        XCTAssertEqual(form(reqs[0])["wstoken"], "TOKEN123abcdef0123456789")
        XCTAssertEqual(form(reqs[0])["moodlewsrestformat"], "json")
        XCTAssertEqual(form(reqs[1])["userid"], "42")
        for r in reqs { XCTAssertFalse(r.url.absoluteString.contains("TOKEN123"), "Token nie in der Adresse") }

        do {
            _ = try await c.files(moodleID: 35)
            XCTFail("Fehler erwartet")
        } catch let e as HildesheimError {
            XCTAssertEqual(e, .badResponse("core_course_get_contents: invalidrecord"))
            XCTAssertFalse(e.description.contains("TOKEN123"), "Meldungstext von Moodle wird nicht weitergegeben")
        }
        XCTAssertFalse(String(describing: token).contains("TOKEN123"))
        XCTAssertFalse(String(reflecting: token).contains("TOKEN123"))
        XCTAssertFalse(String(describing: LearnwebAPI.Mode.token(token)).contains("TOKEN123"))
        XCTAssertEqual(token.keychainValue, "TOKEN123abcdef0123456789")
        XCTAssertNil(LearnwebToken(""))
        XCTAssertNil(LearnwebToken("abc\nSTUDIP_USER=x0123456789abcdef"), "nur alphanumerisch")
        XCTAssertNil(LearnwebToken(String(repeating: "a", count: 257)))
    }

    /// Dieselben Adressen wie `with-token` in expected.json: der Schluessel geht nie in eine Adresse, nur in den Koerper,
    /// und nur an den eigenen Rechner ueber HTTPS.
    func testDownloadKeepsTokenOutOfEveryAddress() async throws {
        let expected = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/hildesheim/expected.json"))
        let api = LearnwebAPI(base: base, mode: .token(token), transport: FakeUniTransport(), retry: noWait)
        let cases = expected["with-token"]?.array ?? []
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let url = c["url"]?.string ?? ""
            let f = Learnweb.File(id: "lw-1-x", name: "a.pdf", size: 0, mime: nil, chdate: 1, downloadURL: url, folder: "")
            let r = try await api.downloadRequest(f)
            XCTAssertEqual(r.url.absoluteString, url, "Adresse unveraendert, ohne Schluessel")
            XCTAssertEqual(r.method, "POST")
            XCTAssertEqual(form(r)["token"], "TOKEN123abcdef0123456789", "Token erst beim Abruf, im Koerper")
            XCTAssertFalse(r.description.contains("TOKEN123"))
            for shown in [String(describing: r), String(reflecting: r), dumped(r)] {
                XCTAssertFalse(shown.contains("TOKEN123"), "kein Schluessel in Beschreibungen")
                XCTAssertTrue(shown.contains("POST"), shown)
            }
        }
        // fremder Rechner oder http: Token wird nie verschickt
        for bad in ["https://evil.example/learnweb2026/webservice/pluginfile.php/5/a.pdf", "http://www.uni-hildesheim.de/learnweb2026/a.pdf", "kaputt"] {
            let f = Learnweb.File(id: "lw-1-x", name: "a.pdf", size: 0, mime: nil, chdate: 1, downloadURL: bad, folder: "")
            do { _ = try await api.downloadRequest(f); XCTFail(bad) } catch { XCTAssertEqual(error as? HildesheimError, .badResponse("fremde oder ungültige Adresse")) }
        }
        // Sitzung: GET mit Cookies, ohne Token
        let session = LearnwebAPI(base: base, mode: .session, transport: FakeUniTransport(), retry: noWait)
        let r = try await session.downloadRequest(Learnweb.File(id: "x", name: "a.pdf", size: 0, mime: nil, chdate: 1,
                                                                downloadURL: base + "/pluginfile.php/5/mod_resource/content/1/a.pdf", folder: ""))
        XCTAssertEqual(r.method, "GET")
        XCTAssertNil(r.body)
    }

    /// Statt der Datei kommt eine Webseite, die CAS-Anmeldung oder eine Fehlermeldung von Moodle: nichts speichern;
    /// abgelaufene Anmeldung oder ungueltiger Schluessel beenden den Learnweb-Teil mit "neu anmelden".
    func testWrongDownloadContentIsNeverStored() async throws {
        let pf = "\(base)/webservice/pluginfile.php/5/mod_resource/content/1"
        func contents(_ names: [String]) -> JSONValue {
            .array([.object(["section": .number(1), "name": .string("1"), "modules": .array([.object([
                "id": .number(5), "modname": .string("resource"), "name": .string("F"),
                "contents": .array(names.map { n in .object(["type": .string("file"), "filename": .string(n), "filepath": .string("/"),
                                                            "timemodified": .number(3), "fileurl": .string("\(pf)/\(n)")]) }),
            ])])])])
        }
        let replies: [String: UniResponse] = [
            "a.pdf": json("\u{FEFF}\n  <!DOCTYPE html><html><body>Anmelden</body></html>"),
            "seite.html": json("<html><body>Inhalt</body></html>"),
            "daten.json": json(#"{"errorcode": "kein Fehler, echte Datei"}"#),
            "d.pdf": UniResponse(status: 404),
            "e.pdf": json(#"{"error":"Ungültiges Token","errorcode":"invalidtoken"}"#),
            "f.pdf": json("%PDF-1.7 nie erreicht"),
        ]
        let net = FakeUniTransport { req in
            let f = self.form(req)
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return self.json(#"{"userid": 1}"#)
            case "core_enrol_get_users_courses": return self.json(#"[{"id": 101, "fullname": "SoSe 2026: 0101 Eins"}, {"id": 102, "fullname": "SoSe 2026: 0102 Zwei"}]"#)
            case "core_course_get_contents":
                return okJSON(f["courseid"] == "101" ? contents(["a.pdf", "seite.html", "daten.json", "d.pdf", "e.pdf", "f.pdf"]) : .array([]))
            default: return replies[req.url.lastPathComponent] ?? UniResponse(status: 500)
            }
        }
        let (db, layout) = try await container()
        let report = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait),
                                          lsf: nil, transport: net, clock: clock, retry: noWait).run()
        let stored = try await db.rows("SELECT name, local_path FROM files WHERE local_path IS NOT NULL ORDER BY name")
        XCTAssertEqual(stored.compactMap { $0["name"]?.string }, ["daten.json", "seite.html"], "echte HTML- und JSON-Dateien bleiben erlaubt")
        XCTAssertEqual(report.failedFiles, ["a.pdf", "d.pdf"], "Webseite statt PDF und 404 nicht gespeichert")
        XCTAssertEqual(report.needsLogin, ["Learnweb"], "ungueltiger Schluessel: neu anmelden")
        XCTAssertEqual(report.notAttempted, ["lw-101", "lw-102"], "danach nichts mehr, auch nicht f.pdf und Kurs 102")
        XCTAssertEqual(report.completed, [], "an der Anmeldung gescheitert: Learnweb nicht als fertig gemeldet")
        XCTAssertEqual(net.count("\(pf)/f.pdf"), 0)
        XCTAssertFalse(report.messages.joined().contains("TOKEN123"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.learnweb.appendingPathComponent("files").path).count, 2,
                       "keine falschen Dateien im Learnweb-Ordner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.learnweb.appendingPathComponent(".laden").path),
                       "keine Reste (.part), Zwischenordner nach dem Lauf entfernt wie bei Stud.IP")
        let log = try await db.scalar("SELECT message FROM sync_log ORDER BY id DESC LIMIT 1")?.string ?? ""
        XCTAssertFalse(log.contains("TOKEN123"))
        // 404-Meldung ohne Abfrage
        XCTAssertNil(HildesheimError.http(status: 404, url: "\(pf)/d.pdf?sesskey=abcSESS1").description.range(of: "abcSESS1"))
    }

    // MARK: Wiederholen und Ausfallsicherheit

    func testRetriesNetworkErrorsWithGrowingPause() async throws {
        let pauses = Recorder<Int>()
        let retry = UniRetry(attempts: 3, delayNanos: { pauses.add($0); return 0 })
        var calls = 0
        let net = FakeUniTransport { _ in
            calls += 1
            if calls < 3 { throw URLError(.timedOut) }
            return self.json(#"[]"#)
        }
        let c = LearnwebAPI(base: base, mode: .session, transport: net, retry: retry)
        // sesskey-Seite: zwei Zeitueberschreitungen, dann die Seite (danach Kursliste)
        _ = try? await c.courses()
        XCTAssertEqual(net.count("\(base)/my/courses.php"), 3)
        XCTAssertEqual(pauses.values, [1, 2], "Pause vor Versuch 2 und 3 waechst (1,5 s, 3 s in der App)")
        XCTAssertEqual(UniRetry().delayNanos(1), 1_500_000_000)
        XCTAssertEqual(UniRetry().delayNanos(2), 3_000_000_000)

        let down = FakeUniTransport { _ in throw URLError(.notConnectedToInternet) }
        let c2 = LearnwebAPI(base: base, mode: .token(token), transport: down, retry: noWait)
        do { _ = try await c2.courses(); XCTFail() } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            XCTAssertFalse(HildesheimSync.describe(error).contains("TOKEN123"))
        }
        XCTAssertEqual(down.requests.count, 3, "hoechstens 3 Versuche")

        var n = 0
        let busy = FakeUniTransport { _ in n += 1; return n == 1 ? UniResponse(status: 503) : self.json(#"{"userid": 8}"#) }
        let c3 = LearnwebAPI(base: base, mode: .token(token), transport: busy, retry: noWait)
        _ = try? await c3.courses()
        XCTAssertEqual(busy.requests.count, 3, "503 einmal wiederholt, dann Kursliste")
        XCTAssertFalse(UniRetry.isTransient(HildesheimError.http(status: 404, url: "x")))
        XCTAssertFalse(UniRetry.isTransient(URLError(.cancelled)))
        XCTAssertTrue(UniRetry.isTransient(HildesheimError.http(status: 429, url: "x")))
    }

    func testOneBrokenCourseSkipsOnlyThatCourse() async throws {
        let pdf = "\(base)/webservice/pluginfile.php/1/mod_resource/content/1"
        let net = FakeUniTransport { req in
            let f = self.form(req)
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return self.json(#"{"userid": 1}"#)
            case "core_enrol_get_users_courses":
                return self.json(#"[{"id": 101, "fullname": "SoSe 2026: 0101 Eins"}, {"id": 102, "fullname": "SoSe 2026: 0102 Zwei"}, {"id": 103, "fullname": "WiSe 2026/27: 0103 Drei"}, {"id": 104, "fullname": "Versteckt", "hidden": 1}]"#)
            case "core_course_get_contents":
                if f["courseid"] == "102" { throw URLError(.timedOut) }
                let id = f["courseid"] ?? ""
                return self.json(#"[{"id": 1, "section": 1, "name": "1", "modules": [{"id": \#(id), "modname": "resource", "name": "F", "contents": [{"type": "file", "filename": "a.pdf", "filepath": "/", "timemodified": 3, "fileurl": "\#(pdf)/\#(id)/a.pdf"}]}]}]"#)
            default: return self.json("%PDF-1.7")
            }
        }
        let (db, layout) = try await container()
        let api = LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait)
        let r = await HildesheimSync(db: db, container: layout, learnweb: api, lsf: nil, transport: net, clock: clock, retry: noWait).run()
        XCTAssertEqual(r.courses, 3, "versteckte Kurse nicht")
        XCTAssertEqual(r.failedCourses, ["0102 Zwei"])
        XCTAssertEqual(r.newFiles.count, 2)
        XCTAssertTrue(r.needsLogin.isEmpty)
        XCTAssertFalse(r.cancelled)
        let folders = try await db.rows("SELECT DISTINCT studip_folder FROM files")
        XCTAssertEqual(folders.compactMap { $0["studip_folder"]?.string }, ["Woche 1"])
        let ids = try await db.rows("SELECT id FROM courses WHERE id LIKE 'lw-%' ORDER BY id")
        XCTAssertEqual(ids.compactMap { $0["id"]?.string }, ["lw-101", "lw-102", "lw-103"], "Kurs mit Fehler steht trotzdem in der Datenbank")
        XCTAssertFalse(r.messages.joined().contains("TOKEN123"))
        XCTAssertEqual(net.requests.filter { self.form($0)["courseid"] == "102" }.count, 3, "Zeitueberschreitung: 3 Versuche, dann Kurs ueberspringen")

        // Semesterfilter wie HILDESHEIM_SEMESTER_FILTER
        let (db2, layout2) = try await container()
        let filtered = await HildesheimSync(db: db2, container: layout2, learnweb: api, lsf: nil, transport: net, clock: clock, retry: noWait)
            .run(semesterFilter: "wise")
        XCTAssertEqual(filtered.courses, 1)
        let only = try await db2.rows("SELECT id FROM courses WHERE id LIKE 'lw-%'")
        XCTAssertEqual(only.compactMap { $0["id"]?.string }, ["lw-103"])
    }

    func testExpiredSessionStopsAndKeepsEarlierCourses() async throws {
        let net = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") { return self.json(self.sessionPage) }
            if u.contains("timeline_classification") {
                return self.ajax(#"{"courses": [{"id": 1, "fullname": "A"}, {"id": 2, "fullname": "B"}, {"id": 3, "fullname": "C"}]}"#)
            }
            let id = (try? JSONValue.parse(req.body ?? Data()))?.array?.first?["args"]?["courseid"]?.int
            if id == 2 { return self.json(#"[{"error": true, "exception": {"errorcode": "servicerequireslogin", "message": "x"}}]"#) }
            return self.ajax(.string(#"{"section": [], "cm": []}"#))
        }
        let (db, layout) = try await container()
        let r = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait),
                                     lsf: nil, transport: net, clock: clock, retry: noWait).run()
        XCTAssertEqual(r.needsLogin, ["Learnweb"])
        XCTAssertEqual(r.notAttempted, ["lw-2", "lw-3"])
        XCTAssertTrue(r.failedCourses.isEmpty, "abgelaufene Anmeldung ist kein Fehler der Kurse")
        XCTAssertEqual(r.completed, [])
        XCTAssertFalse(r.cancelled)
        XCTAssertEqual(r.courses, 3)
        XCTAssertEqual(net.requests.filter { $0.url.absoluteString.contains("core_courseformat_get_state") }.count, 2, "nach Kurs 2 nichts mehr")
    }

    /// Fuenf Kurse; beim Kurs `at` wird die Aufgabe abgebrochen und der Transport wirft `error` (wie URLSession).
    private func cancelledSync(at courseID: String, throwing error: Error) async throws -> (HildesheimSync.Report, FakeUniTransport) {
        let net = FakeUniTransport { req in
            let f = self.form(req)
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return self.json(#"{"userid": 1}"#)
            case "core_enrol_get_users_courses":
                return self.json(#"[{"id": 201, "fullname": "A"}, {"id": 202, "fullname": "B"}, {"id": 203, "fullname": "C"}, {"id": 204, "fullname": "D"}, {"id": 205, "fullname": "E"}]"#)
            default:
                if f["courseid"] == courseID {
                    withUnsafeCurrentTask { $0?.cancel() }      // z. B. Ansicht geschlossen, .task beendet
                    throw error
                }
                return self.json("[]")
            }
        }
        let (db, layout) = try await container()
        let sync = HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait),
                                  lsf: LSFClient(transport: net, retry: noWait), transport: net, clock: clock, retry: noWait)
        let r = await Task { await sync.run() }.value
        return (r, net)
    }

    func testCancelDuringSyncIsReportedAsCancelNotAsCourseFailures() async throws {
        for (at, error, expected) in [("202", URLError(.cancelled) as Error, ["lw-202", "lw-203", "lw-204", "lw-205"]),
                                      ("203", CancellationError() as Error, ["lw-203", "lw-204", "lw-205"])] {
            let (r, net) = try await cancelledSync(at: at, throwing: error)
            XCTAssertTrue(r.cancelled, at)
            XCTAssertFalse(r.ok, at)
            XCTAssertTrue(r.needsLogin.isEmpty, at)
            XCTAssertEqual(r.notAttempted, expected, at)
            XCTAssertEqual(r.completed, [], at)
            XCTAssertTrue(r.failedCourses.isEmpty, "Abbruch ist kein Fehler der Kurse: \(r.failedCourses)")
            let contents = net.requests.compactMap { self.form($0)["wsfunction"] == "core_course_get_contents" ? self.form($0)["courseid"] : nil }
            XCTAssertEqual(contents.last, at, "nach dem Abbruch keine weiteren Anfragen")
            XCTAssertEqual(contents.filter { $0 == at }.count, 1, "abgebrochene Anfrage wird nicht wiederholt")
            XCTAssertEqual(net.count(LSFClient.planURL), 0, "nach dem Abbruch auch kein LSF")
        }
    }

    func testOverloadedFolderPageFailsTheCourseInsteadOfShorterList() async throws {
        // Sitzung: Kurs 35 mit Ressource (303 auf pluginfile) und Ordner, dessen Seite immer 503 liefert;
        // Kurs 36 mit Ordner 404 (nicht sichtbar) -> leere Liste wie am PC, Kurs gilt als abgefragt
        let pf = "\(base)/pluginfile.php"
        let net = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") { return self.json(self.sessionPage) }
            if u.contains("info=core_course_get_enrolled_courses_by_timeline_classification") {
                return self.ajax(#"{"courses": [{"id": 35, "fullname": "SoSe 2026: 0406 Theorien"}, {"id": 36, "fullname": "SoSe 2026: 0407 Praxis"}]}"#)
            }
            if u.contains("info=core_courseformat_get_state") {
                let id = (try? JSONValue.parse(req.body ?? Data()))?.array?.first?["args"]?["courseid"]?.int ?? 0
                return self.ajax(.string(#"{"section": [{"id": "10", "number": 1, "title": "1"}], "cm": [{"id": "\#(id)1", "module": "resource", "name": "Folien", "sectionid": "10"}, {"id": "\#(id)2", "module": "folder", "name": "Texte", "sectionid": "10"}]}"#))
            }
            if u.contains("mod/resource/view.php?id=351") { return UniResponse(status: 303, headers: ["Location": "\(pf)/5/mod_resource/content/4/Folien.pdf"]) }
            if u.contains("mod/resource/view.php?id=361") { return UniResponse(status: 303, headers: ["Location": "\(pf)/6/mod_resource/content/1/Praxis.pdf"]) }
            if u.contains("mod/folder/view.php?id=352") { return UniResponse(status: 503) }
            if u.hasPrefix(pf) { return self.json("%PDF-1.7") }
            return UniResponse(status: 404)
        }
        let (db, layout) = try await container()
        let api = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        let r = await HildesheimSync(db: db, container: layout, learnweb: api, lsf: nil, transport: net, clock: clock, retry: noWait).run()
        XCTAssertEqual(r.failedCourses, ["0406 Theorien"], "unvollstaendige Dateiliste gilt nicht als Ergebnis")
        let files = try await db.rows("SELECT name FROM files ORDER BY name")
        XCTAssertEqual(files.compactMap { $0["name"]?.string }, ["Praxis.pdf"], "404 (nicht sichtbar) bleibt eine leere Ordnerliste")
        XCTAssertTrue(r.needsLogin.isEmpty)
        XCTAssertFalse(r.cancelled)
        XCTAssertEqual(net.count("\(base)/mod/folder/view.php?id=352"), 3, "3 Versuche, dann Kurs ueberspringen")
        XCTAssertFalse(r.messages.joined().contains("abcSESS1"))

        // dasselbe fuer eine ueberlastete Ressourcen-Seite (429); Meldung ohne Abfrage (kein sesskey, keine Kennung)
        let busy = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") { return self.json(self.sessionPage) }
            if u.contains("info=core_courseformat_get_state") {
                return self.ajax(.string(#"{"section": [], "cm": [{"id": "7", "module": "resource", "name": "F", "sectionid": "1"}]}"#))
            }
            return UniResponse(status: 429)
        }
        let c2 = LearnwebAPI(base: base, mode: .session, transport: busy, retry: noWait)
        do { _ = try await c2.files(moodleID: 1); XCTFail("Fehler erwartet") } catch {
            XCTAssertEqual(error as? HildesheimError, .http(status: 429, url: "\(base)/mod/resource/view.php"))
        }
    }

    // MARK: AJAX mit Sitzung

    func testSessionModeAjaxEmbeddedResourceAndPayload() async throws {
        let pf = "\(base)/pluginfile.php"
        let state = #"{"section": [{"id": "10", "number": 1, "title": "1"}], "cm": [{"id": "7", "module": "resource", "name": "Folien", "sectionid": "10"}, {"id": "8", "module": "folder", "name": "Texte", "sectionid": "10"}, {"id": "9", "module": "resource", "name": "Eingebettet", "sectionid": "10"}, {"id": "x1", "module": "resource", "name": "kaputt", "sectionid": "10"}]}"#
        let net = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") { return self.json(self.sessionPage) }
            if u.contains("/lib/ajax/service.php") {
                if u.contains("info=core_courseformat_get_state") { return self.ajax(.string(state)) }
                return self.ajax(#"{"courses": [{"id": 35, "fullname": "SoSe 2026: 0406 Theorien", "hidden": false}]}"#)
            }
            if u.contains("mod/resource/view.php?id=7&redirect=1") {
                XCTAssertFalse(req.followRedirects)
                return UniResponse(status: 303, headers: ["Location": "\(pf)/5/mod_resource/content/4/Folien.pdf"])
            }
            if u.contains("mod/resource/view.php?id=9") {
                return self.json("<object data=\"\(pf)/6/mod_resource/content/2/Eingebettet.pdf\"></object>")
            }
            if u.contains("mod/folder/view.php?id=8") {
                return self.json("<a href=\"\(pf)/7/mod_folder/content/3/Kap%201/x.pdf?forcedownload=1\">x</a>")
            }
            return UniResponse(status: 404)
        }
        let c = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        let courses = try await c.courses()
        XCTAssertEqual(courses.map(\.title), ["0406 Theorien"])
        let first = net.requests[1]
        XCTAssertEqual(first.url.absoluteString, "\(base)/lib/ajax/service.php?sesskey=abcSESS1&info=core_course_get_enrolled_courses_by_timeline_classification")
        XCTAssertEqual(first.headers["Content-Type"], "application/json")
        let payload = try JSONValue.parse(first.body ?? Data())
        XCTAssertEqual(payload.array?.first?["methodname"], "core_course_get_enrolled_courses_by_timeline_classification")
        XCTAssertEqual(payload.array?.first?["args"]?["classification"], "all")
        XCTAssertFalse(first.description.contains("abcSESS1"), "sesskey nicht in Beschreibungen")
        XCTAssertEqual(first.description, "POST \(base)/lib/ajax/service.php")
        for shown in [String(describing: first), String(reflecting: first), dumped(first), "\(net.requests)"] {
            XCTAssertFalse(shown.contains("abcSESS1"), shown)
        }

        let files = try await c.files(moodleID: 35)
        XCTAssertEqual(files.map(\.name), ["Folien.pdf", "x.pdf", "Eingebettet.pdf"])
        XCTAssertEqual(files.map(\.folder), ["Woche 1", "Woche 1/Texte/Kap 1", "Woche 1"])
        XCTAssertEqual(files.map(\.chdate), [4, 3, 2], "Revision im Pluginfile-Pfad")
        XCTAssertFalse(net.requests.contains { $0.url.absoluteString.contains("id=x1") }, "cmid nur aus Ziffern in Adressen")
    }

    func testSessionRedirectToLoginOrHtmlIsExpired() async {
        let net = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") { return self.json(self.sessionPage) }
            if u.contains("core_courseformat_get_state") {
                return self.ajax(.string(#"{"section": [], "cm": [{"id": "7", "module": "resource", "name": "F", "sectionid": "1"}]}"#))
            }
            return UniResponse(status: 303, headers: ["Location": "\(self.base)/login/index.php"])
        }
        let c = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        do { _ = try await c.files(moodleID: 1); XCTFail() } catch { XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb")) }

        let cas = FakeUniTransport { _ in self.json("<html>", url: "https://www.uni-hildesheim.de/sso/login?service=x") }
        let c2 = LearnwebAPI(base: base, mode: .session, transport: cas, retry: noWait)
        do { _ = try await c2.courses(); XCTFail() } catch { XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb")) }

        // Anmeldeseite von Moodle (hat auch einen sesskey, aber body "notloggedin")
        let loginPage = sessionPage.replacingOccurrences(of: "path-my", with: "path-login notloggedin")
        let c3 = LearnwebAPI(base: base, mode: .session, transport: FakeUniTransport { _ in self.json(loginPage) }, retry: noWait)
        do { _ = try await c3.courses(); XCTFail() } catch { XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb")) }

        // AJAX liefert eine Webseite statt JSON (Sitzung beendet)
        let html = FakeUniTransport { req in
            req.url.absoluteString.hasPrefix("\(self.base)/my/courses.php") ? self.json(self.sessionPage) : self.json("<!DOCTYPE html><html>Anmelden</html>")
        }
        let c4 = LearnwebAPI(base: base, mode: .session, transport: html, retry: noWait)
        do { _ = try await c4.courses(); XCTFail() } catch { XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb")) }
    }

    func testSesskeyFromPage() {
        let page = #"<html><body class="path-my safari"><script>M.cfg = {"wwwroot":"https:\/\/www.uni-hildesheim.de\/learnweb2026","sesskey":"Ab12Cd34Ef","sessiontimeout":"28800"};</script></body></html>"#
        XCTAssertEqual(Learnweb.sesskey(fromPage: page), "Ab12Cd34Ef")
        XCTAssertTrue(Learnweb.isLoggedIn(html: page))
        let out = page.replacingOccurrences(of: "path-my safari", with: "path-login notloggedin")
        XCTAssertFalse(Learnweb.isLoggedIn(html: out))
        XCTAssertNil(Learnweb.sesskey(fromPage: out))
        XCTAssertNil(Learnweb.sesskey(fromPage: #"<body>"sesskey":"a\"b"</body>"#))
        XCTAssertNil(Learnweb.sesskey(fromPage: "<html>ohne</html>"))
    }
}

final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

import Foundation
import XCTest
@testable import UniFlowCore

/// Abgleich der Learnweb-Dateien iPad gegen PC (Befund 27./28.10.2026: iPad 195, PC 539 Dateien aus denselben 9 Kursen).
/// Das iPad liest mit Schluessel (REST `core_course_get_contents`), der PC ohne Schluessel ueber die Sitzung
/// (`core_courseformat_get_state` und die Seiten der Ordner). Alle Moodle-Antworten sind erfunden und bilden das Verhalten
/// von Moodle nach (mod/folder/view.php, cmitem.mustache, folder_export_contents).
final class LearnwebFileGapTests: XCTestCase {
    private let base = "https://www.uni-hildesheim.de/learnweb2026"
    private let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })
    /// 25.10.2026 (WiSe 2026/27)
    private let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
    private let token = LearnwebToken("ERFUNDEN0123456789")!

    private func form(_ r: UniRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: r.body ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func page(_ text: String, url: String? = nil) -> UniResponse {
        UniResponse(status: 200, finalURL: url.flatMap(URL.init(string:)), body: Data(text.utf8))
    }

    private func ajax(_ data: JSONValue) -> UniResponse { okJSON(.array([.object(["error": .bool(false), "data": data])])) }

    private func container() async throws -> (SQLiteDatabase, DataContainerLayout) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lwgap-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.erfunden.0001", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        return (db, layout)
    }

    // MARK: Ordner mit der Anzeige "auf der Kursseite"

    private var pf: String { "\(base)/pluginfile.php" }

    /// Kursseite wie Moodle 4.x: je Aktivitaet `<li id="module-<cmid>" data-for="cmitem">`; die eingebetteten Ordner 8 und
    /// 9 zeigen ihren Dateibaum, Ordner 10 (eigene Seite) nur einen Link, das Textfeld 11 ein Bild
    private var coursePage: String {
        """
        <html><body class="path-course-view"><ul class="section" data-for="cmlist">
        <li class="activity resource modtype_resource" id="module-7" data-for="cmitem" data-id="7">
          <a href="\(base)/mod/resource/view.php?id=7">Folien</a></li>
        <li class="activity folder modtype_folder" id="module-8" data-for="cmitem" data-id="8">
          <div class="activity-altcontent"><div id="folder_tree0" class="filemanager"><ul>
          <li><a href="\(pf)/60/mod_folder/content/0/a.pdf?forcedownload=1">a.pdf</a></li>
          <li><span>Sub</span><ul><li><a href="\(pf)/60/mod_folder/content/0/Sub/b.pdf?forcedownload=1">b.pdf</a></li></ul></li>
          </ul></div></div></li>
        </ul><ul class="section" data-for="cmlist">
        <li class="activity folder modtype_folder" id="module-9" data-for="cmitem" data-id="9">
          <div id="folder_tree1" class="filemanager"><a href="\(pf)/61/mod_folder/content/0/Bl%C3%A4tter%20c.pdf?forcedownload=1">c</a></div></li>
        <li class="activity folder modtype_folder" id="module-10" data-for="cmitem" data-id="10">
          <a href="\(base)/mod/folder/view.php?id=10">Archiv</a></li>
        <li class="activity label modtype_label" id="module-11" data-for="cmitem" data-id="11">
          <img src="\(pf)/63/mod_label/intro/bild.png"></li>
        </ul></body></html>
        """
    }

    /// Zustand des Kurses 264 (Sitzung): Ressource 7, eingebettete Ordner 8 und 9, Ordner 10 mit eigener Seite, Textfeld 11
    private var state: JSONValue {
        .object([
            "section": .array([.object(["id": .string("11"), "number": .number(1), "title": .string("1")]),
                               .object(["id": .string("12"), "number": .number(2), "title": .string("2")])]),
            "cm": .array([
                .object(["id": .string("7"), "module": .string("resource"), "name": .string("Folien"), "sectionid": .string("11")]),
                .object(["id": .string("8"), "module": .string("folder"), "name": .string("Texte"), "sectionid": .string("11")]),
                .object(["id": .string("9"), "module": .string("folder"), "name": .string("Blätter"), "sectionid": .string("12")]),
                .object(["id": .string("10"), "module": .string("folder"), "name": .string("Archiv"), "sectionid": .string("12")]),
                .object(["id": .string("11"), "module": .string("label"), "name": .string("Hinweis"), "sectionid": .string("12")]),
            ]),
        ])
    }

    /// Learnweb ueber die Sitzung. Wie URLSession: `followRedirects` = true folgt der Weiterleitung eines eingebetteten
    /// Ordners auf die Kursseite (so liest der PC mit Playwright), false liefert die Weiterleitung selbst.
    private func sessionLearnweb() -> FakeUniTransport {
        FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") {
                return self.page(#"<html><body class="path-my"><script>M.cfg = {"sesskey":"abcSESS1"};</script></body></html>"#)
            }
            if u.contains("info=core_courseformat_get_state") { return self.ajax(.string(self.state.jsonString())) }
            if u.contains("mod/resource/view.php?id=7&redirect=1") {
                return UniResponse(status: 303, headers: ["Location": "\(self.pf)/59/mod_resource/content/3/Folien.pdf"])
            }
            for (cmid, section) in [("8", 1), ("9", 2)] where u == "\(self.base)/mod/folder/view.php?id=\(cmid)" {
                // mod/folder/view.php: FOLDER_DISPLAY_INLINE -> redirect(course_get_url($course, $cm->sectionnum))
                if req.followRedirects { return self.page(self.coursePage, url: "\(self.base)/course/view.php?id=264") }
                return UniResponse(status: 303, headers: ["Location": "\(self.base)/course/view.php?id=264#section-\(section)"])
            }
            if u == "\(self.base)/mod/folder/view.php?id=10" {
                return self.page(#"<div class="filemanager"><a href="\#(self.pf)/62/mod_folder/content/0/d.pdf?forcedownload=1">d</a><a href="\#(self.pf)/62/mod_folder/content/0/d.pdf">d</a></div>"#)
            }
            if u.hasPrefix("\(self.base)/course/view.php?id=264") { return self.page(self.coursePage) }
            return UniResponse(status: 404)
        }
    }

    /// Dieselben Ordner, wie Moodle sie mit Schluessel liefert (`core_course_get_contents`, folder_export_contents
    /// mit der Ordner-Revision in der Adresse): so liest das iPad
    private var restContents: JSONValue {
        func file(_ ctx: Int, _ area: String, _ rev: Int, _ path: String, _ name: String) -> JSONValue {
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let p = path == "/" ? "" : String(path.dropFirst())
            return .object(["type": .string("file"), "filename": .string(name), "filepath": .string(path), "filesize": .number(10),
                            "timemodified": .number(1_790_000_000),
                            "fileurl": .string("\(base)/webservice/pluginfile.php/\(ctx)/\(area)/content/\(rev)/\(p)\(enc)?forcedownload=1")])
        }
        func module(_ id: Int, _ modname: String, _ name: String, _ contents: [JSONValue]) -> JSONValue {
            .object(["id": .number(Double(id)), "modname": .string(modname), "name": .string(name), "contents": .array(contents)])
        }
        return .array([
            .object(["id": .number(11), "section": .number(1), "name": .string("1"), "modules": .array([
                module(7, "resource", "Folien", [file(59, "mod_resource", 3, "/", "Folien.pdf")]),
                module(8, "folder", "Texte", [file(60, "mod_folder", 2, "/", "a.pdf"), file(60, "mod_folder", 2, "/Sub/", "b.pdf")]),
            ])]),
            .object(["id": .number(12), "section": .number(2), "name": .string("2"), "modules": .array([
                module(9, "folder", "Blätter", [file(61, "mod_folder", 1, "/", "Blätter c.pdf")]),
                module(10, "folder", "Archiv", [file(62, "mod_folder", 4, "/", "d.pdf")]),
                .object(["id": .number(11), "modname": .string("label"), "name": .string("Hinweis")]),
            ])]),
        ])
    }

    /// Eingebettete Ordner: jede Datei genau einmal und beim richtigen Ordner, wie mit Schluessel (REST). Vorher (und am
    /// PC, `SessionClient._folder_links`) folgte die Sitzung der Weiterleitung und nahm alle Links der Kursseite: jeder
    /// eingebettete Ordner bekam die Dateien aller eingebetteten Ordner (hier 8 statt 5 Dateien).
    func testInlineFoldersCountEachFileOnceLikeREST() async throws {
        let net = sessionLearnweb()
        let api = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        let session = try await api.files(moodleID: 264)
        XCTAssertEqual(session.map(\.name), ["Folien.pdf", "a.pdf", "b.pdf", "Blätter c.pdf", "d.pdf"])
        XCTAssertEqual(session.map(\.folder), ["Woche 1", "Woche 1/Texte", "Woche 1/Texte/Sub", "Woche 2/Blätter", "Woche 2/Archiv"])
        XCTAssertEqual(Set(session.map(\.downloadURL)).count, session.count, "keine Datei doppelt")
        XCTAssertEqual(net.count("\(base)/course/view.php"), 1, "Kursseite einmal je Kurs, nicht je eingebettetem Ordner")
        XCTAssertEqual(net.requests.first { $0.url.path.hasSuffix("/course/view.php") }?.url.absoluteString, "\(base)/course/view.php?id=264")
        XCTAssertEqual(net.requests.first { $0.url.absoluteString.hasSuffix("mod/folder/view.php?id=8") }?.followRedirects, false)

        // dieselben Dateien, Kennungen und Ordner wie mit Schluessel: iPad und PC zaehlen gleich, egal welcher Weg
        let rest = Learnweb.filesFromContents(restContents)
        XCTAssertEqual(session.map(\.id), rest.map(\.id))
        XCTAssertEqual(session.map(\.folder), rest.map(\.folder))
    }

    func testInlineFolderLinksTakeOnlyTheirOwnEntry() {
        let html = coursePage
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "8"),
                       ["\(pf)/60/mod_folder/content/0/a.pdf?forcedownload=1", "\(pf)/60/mod_folder/content/0/Sub/b.pdf?forcedownload=1"])
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "9"), ["\(pf)/61/mod_folder/content/0/Bl%C3%A4tter%20c.pdf?forcedownload=1"])
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "10"), [], "Ordner mit eigener Seite: nichts auf der Kursseite")
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "1"), [], "module-1 ist nicht module-10 oder module-11")
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "99"), [], "ohne Eintrag nie fremde Links")
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: html, cmid: "8 or 1"), [])
        // letzter Eintrag der Seite, einfache Anfuehrungszeichen
        let last = "<li id='module-5'><a href=\"\(pf)/1/mod_folder/content/0/x.pdf\">x</a></li></ul><footer></footer>"
        XCTAssertEqual(Learnweb.inlineFolderLinks(coursePage: last, cmid: "5"), ["\(pf)/1/mod_folder/content/0/x.pdf"])
        XCTAssertTrue(Learnweb.isCoursePage(URL(string: "\(base)/course/view.php?id=264#section-2")!, base: base))
        XCTAssertTrue(Learnweb.isCoursePage(URL(string: "\(base)/course/section.php?id=12")!, base: base + "/"))
        XCTAssertFalse(Learnweb.isCoursePage(URL(string: "\(base)/mod/folder/view.php?id=8")!, base: base))
        XCTAssertFalse(Learnweb.isCoursePage(URL(string: "https://evil.example/learnweb2026/course/view.php?id=1")!, base: base))
        XCTAssertFalse(Learnweb.isCoursePage(URL(string: "https://www.uni-hildesheim.de/learnweb2025/course/view.php?id=1")!, base: base))
    }

    /// Weiterleitung einer Ordnerseite auf die Anmeldung: Sitzung abgelaufen (wie bei Ressourcen)
    func testFolderRedirectToLoginIsExpiredSession() async {
        let net = FakeUniTransport { req in
            let u = req.url.absoluteString
            if u.hasPrefix("\(self.base)/my/courses.php") {
                return self.page(#"<html><body class="path-my"><script>M.cfg = {"sesskey":"abcSESS1"};</script></body></html>"#)
            }
            if u.contains("info=core_courseformat_get_state") {
                return self.ajax(.string(#"{"section": [], "cm": [{"id": "8", "module": "folder", "name": "T", "sectionid": "1"}]}"#))
            }
            return UniResponse(status: 303, headers: ["Location": "\(self.base)/login/index.php"])
        }
        let api = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        do { _ = try await api.files(moodleID: 1); XCTFail("Fehler erwartet") } catch {
            XCTAssertEqual(error as? HildesheimError, .sessionExpired("Learnweb"))
        }
    }

    // MARK: Nur aktive Kurse bekommen Dateien (Wunsch des Inhabers 28.10.2026)

    /// Fuenf Kurse: alt (SoSe 2026), aktuell, alt aber vom Nutzer eingeschaltet, aktuell aber vom Nutzer ausgeschaltet,
    /// ohne Semester im Titel (bleibt, wie er ist; auch ohne Wert in `active` aktiv, wie `active_courses` am PC: nur
    /// `active = 0` faellt weg). Je Kurs eine Datei.
    private func semesterLearnweb() -> FakeUniTransport {
        FakeUniTransport { req in
            let f = self.form(req)
            switch f["wsfunction"] {
            case "core_webservice_get_site_info": return okJSON(.object(["userid": .number(1)]))
            case "core_enrol_get_users_courses":
                return okJSON(.array([
                    .object(["id": .number(301), "fullname": .string("SoSe 2026: 0301 Alt")]),
                    .object(["id": .number(302), "fullname": .string("WiSe 2026/27: 0302 Neu")]),
                    .object(["id": .number(303), "fullname": .string("SoSe 2026: 0303 Eingeschaltet")]),
                    .object(["id": .number(304), "fullname": .string("WiSe 2026/27: 0304 Ausgeschaltet")]),
                    .object(["id": .number(305), "fullname": .string("Ohne Semester")]),
                ]))
            case "core_course_get_contents":
                let id = f["courseid"] ?? ""
                return okJSON(.array([.object(["section": .number(1), "name": .string("1"), "modules": .array([.object([
                    "id": .string(id), "modname": .string("resource"), "name": .string("F"),
                    "contents": .array([.object(["type": .string("file"), "filename": .string("k\(id).pdf"), "filepath": .string("/"),
                                                 "timemodified": .number(3),
                                                 "fileurl": .string("\(self.base)/webservice/pluginfile.php/\(id)/mod_resource/content/1/k\(id).pdf")])]),
                ])])])]))
            case nil where req.url.path.contains("/webservice/pluginfile.php/"): return self.page("%PDF-1.7 erfunden")
            default: return okJSON(.object(["events": .array([])]))
            }
        }
    }

    func testFilesOnlyForActiveCoursesUserChoiceCounts() async throws {
        let (db, layout) = try await container()
        // frueherer Abgleich: Kurs 301 hat schon eine Datei; der Nutzer hat 303 ein- und 304 ausgeschaltet
        try await db.transaction { c in
            for (id, title, sem) in [("lw-301", "0301 Alt", "SoSe 2026"), ("lw-303", "0303 Eingeschaltet", "SoSe 2026"),
                                     ("lw-304", "0304 Ausgeschaltet", "WiSe 2026/27"), ("lw-305", "Ohne Semester", "")] {
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: id, title: title, number: nil, semester: sem), now: "2026-07-01T10:00:00")
            }
            try c.execute("UPDATE courses SET active=1, active_custom=1 WHERE id='lw-303'")
            try c.execute("UPDATE courses SET active=0, active_custom=1 WHERE id='lw-304'")
            try c.execute("UPDATE courses SET active=NULL WHERE id='lw-305'")
            _ = try UniStore.storeFiles(c, courseID: "lw-301", [UniStore.FileRow(id: "lw-301-alt", name: "alt.pdf", size: 1, mime: nil, chdate: 1,
                                                                                downloadURL: "\(base)/webservice/pluginfile.php/301/x/alt.pdf", folder: "")],
                                        now: "2026-07-01T10:00:00", fileExists: { _ in false })
        }
        let net = semesterLearnweb()
        func contentsRequests() -> [String] {
            net.requests.compactMap { self.form($0)["wsfunction"] == "core_course_get_contents" ? self.form($0)["courseid"] : nil }
        }
        let sync = HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait),
                                  lsf: nil, transport: net, clock: clock, retry: noWait)

        // kurzer Hintergrundlauf (nur Listen): ebenso nur aktive Kurse
        let lists = await sync.run(downloads: false)
        XCTAssertEqual(contentsRequests(), ["302", "303", "305"])
        XCTAssertEqual(lists.waiting, 3)

        let r = await sync.run()
        XCTAssertEqual(contentsRequests(), ["302", "303", "305", "302", "303", "305"], "alte und ausgeschaltete Kurse: keine Dateiliste")
        XCTAssertEqual(r.olderCourses, ["lw-301", "lw-304"])
        XCTAssertEqual(r.courses, 5, "alle sichtbaren Kurse bleiben gespeichert")
        XCTAssertEqual(r.newFiles.sorted(), ["lw-302-\(String(HText.sha256Hex("/k302.pdf").prefix(8)))",
                                             "lw-303-\(String(HText.sha256Hex("/k303.pdf").prefix(8)))",
                                             "lw-305-\(String(HText.sha256Hex("/k305.pdf").prefix(8)))"])
        XCTAssertTrue(r.ok, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.completed, ["Learnweb"])
        XCTAssertEqual(r.messages.first,
                       "3 neue/geänderte Dateien aus 3 Learnweb-Kursen, 2 Kurse aus früheren Semestern ohne Dateien (Einstellungen → Module)")
        XCTAssertEqual(net.count("\(base)/webservice/pluginfile.php/301"), 0)
        XCTAssertEqual(net.count("\(base)/webservice/pluginfile.php/304"), 0)

        let courses = try await db.rows("SELECT id, active FROM courses WHERE id LIKE 'lw-%' ORDER BY id")
        XCTAssertEqual(courses.compactMap { $0["id"]?.string }, ["lw-301", "lw-302", "lw-303", "lw-304", "lw-305"])
        XCTAssertEqual(courses.map { $0["active"]?.int }, [0, 1, 1, 0, nil], "eigene Schalter bleiben, Regel fuer die anderen")
        // Ankuendigungen wie `sync_announcements` am PC nur fuer aktive Kurse
        let forums = net.requests.filter { self.form($0)["wsfunction"] == "mod_forum_get_forums_by_courses" }.last.map(self.form)
        XCTAssertEqual(forums?.filter { $0.key.hasPrefix("courseids") }.map(\.value).sorted(), ["302", "303", "305"])
        let kept = try await db.scalar("SELECT COUNT(*) FROM files WHERE id='lw-301-alt'")?.int
        XCTAssertEqual(kept, 1, "Dateien alter Kurse bleiben stehen, nur keine neuen")
        XCTAssertEqual(HildesheimSync.learnwebMessage(courses: 1, newFiles: 0, failedFiles: 0, failedCourses: 0, older: 1),
                       "0 neue/geänderte Dateien aus 1 Learnweb-Kursen, 1 Kurs aus früheren Semestern ohne Dateien (Einstellungen → Module)")
    }

    /// Nur Kurse frueherer Semester: kein Fehler ("kein Kurs lesbar"), sondern ein fertiger Lauf ohne Dateiabruf
    func testOnlyOlderCoursesIsNoFailure() async throws {
        let (db, layout) = try await container()
        let net = FakeUniTransport { req in
            switch self.form(req)["wsfunction"] {
            case "core_webservice_get_site_info": return okJSON(.object(["userid": .number(1)]))
            case "core_enrol_get_users_courses": return okJSON(.array([.object(["id": .number(301), "fullname": .string("SoSe 2026: 0301 Alt")])]))
            case "core_course_get_contents": return UniResponse(status: 500)
            default: return okJSON(.object(["events": .array([])]))
            }
        }
        let r = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait),
                                     lsf: nil, transport: net, clock: clock, retry: noWait).run()
        XCTAssertEqual(r.failedCourses, [])
        XCTAssertEqual(r.olderCourses, ["lw-301"])
        XCTAssertEqual(r.completed, ["Learnweb"])
        XCTAssertEqual(net.requests.filter { self.form($0)["wsfunction"] == "core_course_get_contents" }.count, 0)
    }
}

import PDFKit
import PencilKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// S3 im lokalen Modus (ohne PC): Stud.IP-Abgleich in die Datenbank -> Dokumente, Kurse und Uebersicht -> im Editor
/// oeffnen, mit dem Stift schreiben, speichern, neu laden. Stud.IP antwortet mit festen, erfundenen Daten
/// (kein Netz); der "PC" ist ein Transport im Speicher, nie ein echter Server.
@MainActor
final class LocalDocumentsAppTests: XCTestCase {

    // MARK: Umgebung

    /// App-Container im Temp-Ordner: Datenbank, Stud.IP-Ordner, Datenordner, Journal
    private struct Device {
        let container: URL
        let host: LocalBackendHost
        let api: APIClient
        let studipRoot: URL
        /// AppPaths.support im Container (Journal, PDF-Zwischenspeicher)
        var support: URL { container.appendingPathComponent("Library/Application Support/UniFlow", isDirectory: true) }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-s3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

    /// Geraet mit lokalem Backend; mit `container` dasselbe Geraet nach einem Neustart der App
    private func device(_ container: URL? = nil) throws -> Device {
        let c = try container ?? tempDir()
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(container: c, host: host, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)),
                      studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-s3-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Zweiseitige Test-PDF
    private func makePDF(_ marker: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...2 {
                ctx.beginPage()
                (("\(marker) Seite \(i)") as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    /// Stud.IP mit festen Antworten (erfundener Kurs, zwei Dateien); merkt sich die Abrufe
    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var failures: [String: URLError] = [:]
        private var log: [String] = []

        var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }

        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; failures[path] = nil; lock.unlock() }

        /// Transportfehler statt Antwort (Netz weg, Zeitueberschreitung)
        func fail(_ path: String, _ error: URLError) { lock.lock(); failures[path] = error; lock.unlock() }

        func json(_ path: String, _ text: String) {
            set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8)))
        }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: StudIPSync.base.absoluteString, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock()
            log.append(key)
            let r = routes[key], failure = failures[key]
            lock.unlock()
            if let failure { throw failure }
            return r ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }

        var downloads: [String] { requested.filter { $0.hasSuffix("/content") } }
    }

    private func fakeStudIP(pdf: Data, changed: String = "2026-10-19T10:00:00+02:00") -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester", #"""
            {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
              "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
             "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
            """#)
        t.json("/jsonapi.php/v1/courses/c1/folders?page[limit]=200", #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
        t.json("/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500", #"""
            {"data":[{"id":"d1","attributes":{"name":"Blatt 3.pdf","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"\#(changed)","is-downloadable":true}},
                     {"id":"d2","attributes":{"name":"Gesperrt.pdf","filesize":5,"mime-type":"application/pdf","chdate":"2026-10-19T11:00:00+02:00","is-downloadable":false}}]}
            """#)
        t.json("/jsonapi.php/v1/folders/r1/folders?page[limit]=200", #"{"data":[]}"#)
        t.set("/jsonapi.php/v1/file-refs/d1/content", HTTPReply(status: 200, contentType: "application/pdf", body: pdf))
        return t
    }

    private func client(_ t: FakeStudIP) -> StudIPClient { StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0) }

    /// Strich wie von der PencilKit-Canvas (waagrecht, in Seitenpunkten)
    private func drawing(y: CGFloat, x0: CGFloat = 100, step: CGFloat = 20) -> PKDrawing {
        let pts = (0..<12).map { i in
            PKStrokePoint(location: CGPoint(x: x0 + CGFloat(i) * step, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func libraryFile(_ api: APIClient, _ id: String) async throws -> LibFile {
        let lib = try await api.json("/api/library", as: LibraryResponse.self)
        return try XCTUnwrap(lib.files.first { $0.id == id }, "Datei \(id) in der Bibliothek")
    }

    private func strokes(_ api: APIClient, _ id: String, page: String = "p1") async throws -> [JSONValue] {
        let v = try await api.value("/api/files/\(id)/annotations")
        return (v["data"]?["pages"]?[page]?["objects"]?.array ?? []).filter { $0["type"]?.string == "stroke" }
    }

    // MARK: Abnahme S3: Stud.IP verbinden -> Dokumente erscheinen -> im Editor oeffnen und schreiben, offline

    func testStudIPFilesAppearAndOpenInEditorOffline() async throws {
        let dev = try device()
        let pdf = makePDF("Testblatt")
        let stud = fakeStudIP(pdf: pdf)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(stud.downloads, ["/jsonapi.php/v1/file-refs/d1/content"], "gesperrte Datei wird nicht geladen")

        // Dokumente: beide Dateien, die PDF ist geladen und oeffnet sich im Editor
        let lib = try await dev.api.value("/api/library")
        let files = lib["files"]?.array ?? []
        XCTAssertEqual(Set(files.compactMap { $0["id"]?.string }), ["d1", "d2"])
        let d1 = try XCTUnwrap(files.first { $0["id"] == "d1" })
        XCTAssertEqual(d1["status"], "neu")
        XCTAssertEqual(d1["kind"], "pdf")
        XCTAssertNotNil(d1["downloaded_at"]?.string)
        XCTAssertEqual(files.first { $0["id"] == "d2" }?["downloaded_at"], .null)
        // Kursliste (Module/Einstellungen) mit dem Pseudokurs "Eigene Dokumente"
        let courses = try await dev.api.value("/api/courses").array ?? []
        XCTAssertEqual(Set(courses.compactMap { $0["id"]?.string }), ["__user__", "c1"])
        let c1 = courses.first { $0["id"] == "c1" }
        XCTAssertEqual(c1?["file_count"], 2)
        // S4: Fach und Art beim Abgleich (classify), das Modul legt /api/library an (ensure_modules); der Kurs ist damit
        // kein Kursordner mehr, seine Dokumente stehen im Modulordner, nach Art und Lehrwoche eingeordnet
        XCTAssertEqual(c1?["subject"], "Testkurs Numerik")
        XCTAssertEqual(c1?["kind"], "vorlesung")
        let modules = try await dev.api.value("/api/modules").array ?? []
        XCTAssertEqual(modules.compactMap { $0["name"]?.string }, ["Testkurs Numerik"])
        XCTAssertEqual(c1?["module_id"], modules.first?["id"])
        XCTAssertEqual(lib["modules"]?.array?.compactMap { $0["name"]?.string }, ["Testkurs Numerik"])
        XCTAssertEqual(d1["module_id"], modules.first?["id"])
        XCTAssertEqual(d1["doc_type"], "uebung")
        XCTAssertEqual(d1["week_hint"], 3, "Blatt 3")
        XCTAssertEqual(LibraryCourses.unassigned(courses), [])
        XCTAssertEqual(LibraryCourses.folders(courses, files: files).map(\.path), [])
        XCTAssertEqual(LibraryCourses.courseID("cc1"), "c1")
        XCTAssertNil(LibraryCourses.courseID("m3/f2"))
        XCTAssertNil(LibraryCourses.courseID(""))
        XCTAssertEqual(LibraryCourses.title(of: d1, in: courses), "Testkurs Numerik")
        XCTAssertNil(LibraryCourses.title(of: ["course_id": "__user__"], in: courses))
        // Uebersicht: "Neu aus Stud.IP" und letzter Abgleich
        let dash = try await dev.api.value("/api/dashboard")
        XCTAssertEqual(dash["new_total"], 2)
        XCTAssertEqual(dash["last_sync"]?["message"], "1 neue/geaenderte Dateien")
        XCTAssertEqual(dash["last_sync"]?["ok"], 1)
        // Pfad relativ zum App-Container
        let meta = try await dev.api.value("/api/files/d1")
        XCTAssertEqual(meta["local_path"], "Library/Application Support/StudIP/files/d1/Blatt 3.pdf")
        XCTAssertEqual(meta["exists"], true)

        // Ab hier offline: Stud.IP wird nicht mehr gefragt
        let before = stud.requested.count
        let file = try await libraryFile(dev.api, "d1")
        XCTAssertTrue(file.isPDF)
        let store = DocumentStore(file: file, api: dev.api, root: dev.support)
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.pdf?.pageCount, 2)
        // "Lösung teilen" braucht die unveraenderten Original-Bytes
        XCTAssertEqual(try store.originalPDFData(), pdf)
        // die Kopie im Zwischenspeicher gehoert nicht ins iCloud-Backup (Stud.IP-Dateien nur auf dem Geraet)
        let cacheValues = try store.originalPDFURL.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(cacheValues.isExcludedFromBackup, true)

        store.canvasChanged(pageKey: "p1", drawing: drawing(y: 300))
        await store.flush()
        let saved = await waitUntil { (try? await self.strokes(dev.api, "d1"))?.count == 1 }
        XCTAssertTrue(saved, "Strich in der lokalen Datenbank")
        let isSaved = await waitUntil { store.status == .saved }
        XCTAssertTrue(isSaved, store.status.label)
        await store.close()
        XCTAssertEqual(stud.requested.count, before, "Editor und Speichern ohne Netz")

        // neu laden (frisches Journal): Notiz kommt aus der Datenbank
        let other = try tempDir()
        let reopened = DocumentStore(file: file, api: dev.api, root: other)
        await reopened.load()
        XCTAssertNil(reopened.errorMessage)
        let objects = await reopened.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 1)
        await reopened.close()

        // Neustart der App: neue Datenbankverbindung auf derselben Datei
        let restarted = try device(dev.container)
        let after = try await strokes(restarted.api, "d1")
        XCTAssertEqual(after.count, 1, "Notizen bleiben nach dem Neustart erhalten")
        let versions = try await restarted.api.value("/api/files/d1/annotations/versions").array ?? []
        XCTAssertGreaterThanOrEqual(versions.count, 1)

        // erneuter Abgleich: nichts neu laden, Status und Notizen bleiben
        _ = try await restarted.api.value("/api/files/d1", method: "PATCH", body: ["status": "gelesen"])
        let again = StudIPSync(root: restarted.studipRoot, host: restarted.host, clock: Self.clock, defaults: try defaults())
        let stud2 = fakeStudIP(pdf: pdf)
        await again.run(client: client(stud2))
        XCTAssertEqual(again.phase, .idle)
        XCTAssertEqual(stud2.downloads, [], "unveraendert in Stud.IP: kein Download")
        let meta2 = try await restarted.api.value("/api/files/d1")
        XCTAssertEqual(meta2["status"], "gelesen")
        let still = try await strokes(restarted.api, "d1")
        XCTAssertEqual(still.count, 1)
    }

    // MARK: S3 + S4: Abgleich ordnet nach Fach, Art und Lehrwoche

    /// Stud.IP mit einem Fach in zwei Kursen (Vorlesung, Uebung) und einer Begruessung; Dateien in Stud.IP-Ordnern
    private func fakeStudIPWithSubjects(pdf: Data) -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester", #"""
            {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testmathematik I","course-number":"T-MA1"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}},
                     {"id":"c2","type":"courses","attributes":{"title":"Übung zu Testmathematik I"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}},
                     {"id":"c3","type":"courses","attributes":{"title":"Begrüßung der Testsemester"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
             "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
            """#)
        func ref(_ id: String, _ name: String, _ changed: String) -> String {
            #"{"id":"\#(id)","attributes":{"name":"\#(name)","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"\#(changed)","is-downloadable":true}}"#
        }
        // Ordnerbaum: Kurs -> Wurzelordner -> Unterordner mit Dateien
        let tree: [(course: String, root: String, rootFiles: [String], subs: [(id: String, name: String, files: [String])])] = [
            ("c1", "r1", [ref("k1", "Altklausur WS 2025.pdf", "2026-10-16T08:00:00+02:00")],
             [("r1v", "Vorlesung", [ref("v1", "VL01 Einführung.pdf", "2026-10-13T10:00:00+02:00"), ref("v2", "VL02.pdf", "2026-10-20T10:00:00+02:00")])]),
            ("c2", "r2", [],
             [("r2u", "Übungsblätter", [ref("u1", "Blatt 1.pdf", "2026-10-14T12:00:00+02:00"), ref("u2", "Blatt 2.pdf", "2026-10-21T12:00:00+02:00")]),
              ("r2l", "Lösungen", [ref("l1", "Lösung Blatt 1.pdf", "2026-10-21T13:00:00+02:00")])]),
            // drei Kurse laden in der Woche ab 12.10. hoch: dort beginnt die Vorlesungszeit (study.semester_start)
            ("c3", "r3", [ref("w1", "Willkommen.pdf", "2026-10-12T08:00:00+02:00")], []),
        ]
        for c in tree {
            t.json("/jsonapi.php/v1/courses/\(c.course)/folders?page[limit]=200", #"{"data":[{"id":"\#(c.root)","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            t.json("/jsonapi.php/v1/folders/\(c.root)/file-refs?page[limit]=500", #"{"data":[\#(c.rootFiles.joined(separator: ","))]}"#)
            let subs = c.subs.map { #"{"id":"\#($0.id)","attributes":{"name":"\#($0.name)"}}"# }.joined(separator: ",")
            t.json("/jsonapi.php/v1/folders/\(c.root)/folders?page[limit]=200", #"{"data":[\#(subs)]}"#)
            for s in c.subs {
                t.json("/jsonapi.php/v1/folders/\(s.id)/file-refs?page[limit]=500", #"{"data":[\#(s.files.joined(separator: ","))]}"#)
                t.json("/jsonapi.php/v1/folders/\(s.id)/folders?page[limit]=200", #"{"data":[]}"#)
            }
        }
        for id in ["k1", "v1", "v2", "u1", "u2", "l1", "w1"] {
            t.set("/jsonapi.php/v1/file-refs/\(id)/content", HTTPReply(status: 200, contentType: "application/pdf", body: pdf))
        }
        return t
    }

    /// Abnahme S4 mit Daten aus dem S3-Abgleich: Stud.IP verbinden -> Fächer geordnet (Vorlesung und Übung ein Modul),
    /// Dokumente im Modulordner nach Art, Moduldetail mit Lehrwochen; die Begrüßung bleibt ein Kursordner
    func testSyncSortsDocumentsBySubjectAndWeek() async throws {
        let dev = try device()
        let stud = fakeStudIPWithSubjects(pdf: makePDF("Fach"))
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(stud.downloads.count, 7)

        // Dokumente & Notizen (wie LibraryPage.load: erst die Bibliothek, dann die Kursliste)
        let lib = try await dev.api.value("/api/library")
        let courses = try await dev.api.value("/api/courses").array ?? []
        let mods = lib["modules"]?.array ?? []
        XCTAssertEqual(mods.compactMap { $0["name"]?.string }, ["Testmathematik I"], "ein Modul je Fach, Begrüßung ohne Modul")
        let mid = try XCTUnwrap(mods.first?["id"])
        let files = Dictionary(uniqueKeysWithValues: (lib["files"]?.array ?? []).compactMap { f in f["id"]?.string.map { ($0, f) } })
        for id in ["k1", "v1", "v2", "u1", "u2", "l1"] { XCTAssertEqual(files[id]?["module_id"], mid, id) }
        XCTAssertEqual(files["w1"]?["module_id"], .null)
        let kinds = ["v1": ("vorlesung", "Vorlesung", 1), "v2": ("vorlesung", "Vorlesung", 2), "u1": ("uebung", "Übung", 1),
                     "u2": ("uebung", "Übung", 2), "l1": ("loesung", "Lösung", 1)]
        for (id, k) in kinds {
            XCTAssertEqual(files[id]?["doc_type"]?.string, k.0, id)
            XCTAssertEqual(files[id]?["sub_label"]?.string, k.1, id)
            XCTAssertEqual(files[id]?["week_hint"]?.int, k.2, id)
        }
        XCTAssertEqual(files["k1"]?["sub_label"], "Altklausur")
        XCTAssertEqual(files["w1"]?["doc_type"], "sonstiges")
        // Kursordner nur noch fuer den Kurs ohne Modul
        XCTAssertEqual(LibraryCourses.unassigned(courses).compactMap { $0["id"]?.string }, ["c3"])
        XCTAssertEqual(LibraryCourses.folders(courses, files: lib["files"]?.array ?? []).map(\.label), ["Begrüßung der Testsemester"])
        XCTAssertEqual(Set(courses.filter { $0["module_id"] == mid }.compactMap { $0["kind"]?.string }), ["vorlesung", "uebung"])

        // Meine Module und Moduldetail mit Wochen
        let list = try await dev.api.value("/api/modules").items
        XCTAssertEqual(list.map { $0.s("name") ?? "" }, ["Testmathematik I"])
        XCTAssertEqual(list.first?.i("courses"), 2)
        XCTAssertEqual(list.first?.i("file_count"), 6)
        let detail = try await dev.api.value("/api/modules/\(mid.int ?? 0)")
        let weeks = detail.list("weeks")
        XCTAssertEqual(weeks.map { $0.s("label") ?? "" }, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
        func ids(_ i: Int, _ key: String) -> [String] { weeks.indices.contains(i) ? weeks[i].list(key).compactMap { $0.s("id") } : [] }
        XCTAssertEqual(ids(0, "vorlesungen"), ["v1"])
        XCTAssertEqual(ids(0, "uebungen"), ["u1"])
        XCTAssertEqual(ids(0, "loesungen"), ["l1"])
        XCTAssertEqual(ids(1, "vorlesungen"), ["v2"])
        XCTAssertEqual(ids(1, "uebungen"), ["u2"])
        XCTAssertEqual(ids(2, "klausuren"), ["k1"])

        // Nutzer ordnet die Uebung einem eigenen Modul zu (Einstellungen -> Module); der naechste Abgleich laedt nichts
        // doppelt und ueberschreibt weder Fach noch Zuordnung (Fach/Art nur, solange leer, wie upsert_course)
        let own = try await dev.api.value("/api/modules", method: "POST", body: ["name": "Eigenes Fach"])
        let ownID = try XCTUnwrap(own.i("id"))
        _ = try await dev.api.value("/api/courses/c2/module", method: "POST", body: ["module_id": .number(Double(ownID))])
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertEqual(stud.downloads.count, 7, "unveraendert in Stud.IP: kein Download")
        let again = try await dev.api.value("/api/modules").items
        XCTAssertEqual(again.map { $0.s("name") ?? "" }, ["Testmathematik I", "Eigenes Fach"])
        let c2 = try await dev.api.value("/api/courses").array?.first { $0["id"] == "c2" }
        XCTAssertEqual(c2?["subject"], "Eigenes Fach")
        XCTAssertEqual(c2?["module_id"]?.int, ownID)
        let moved = try await dev.api.value("/api/modules/\(ownID)")
        XCTAssertEqual(moved.list("weeks").flatMap { $0.list("uebungen") }.compactMap { $0.s("id") }, ["u1", "u2"])
    }

    /// Abgleich vor S3: die schon geladenen Dateien (index.json) erscheinen, ohne neu zu laden
    func testDownloadsFromBeforeS3AreAdoptedWithoutReloading() async throws {
        let dev = try device()
        let pdf = makePDF("Alt")
        let rel = "files/d1/Blatt 3.pdf"
        try FileManager.default.createDirectory(at: dev.studipRoot.appendingPathComponent("files/d1"), withIntermediateDirectories: true)
        try pdf.write(to: dev.studipRoot.appendingPathComponent(rel))
        let entry = StudIPLocalEntry(id: "d1", courseID: "c1", courseTitle: "Testkurs Numerik", folderPath: "", name: "Blatt 3.pdf",
                                     size: pdf.count, changed: "2026-10-19T10:00:00+02:00", mimeType: "application/pdf",
                                     relativePath: rel, downloadedAt: "2026-10-20T06:00:00Z")
        try JSONEncoder().encode([entry]).write(to: dev.studipRoot.appendingPathComponent("index.json"))
        try JSONEncoder().encode([StudIPCourse(id: "c1", title: "Testkurs Numerik", number: "T-42", semesterTitle: "WiSe 2026/27")])
            .write(to: dev.studipRoot.appendingPathComponent("courses.json"))
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        _ = await sync.adoptExistingDownloads()                         // wie beim Start (zweiter Lauf tut nichts)
        let lib = try await dev.api.value("/api/library")
        XCTAssertEqual(lib["files"]?.array?.compactMap { $0["id"]?.string }, ["d1"], "ohne Abgleich schon in Dokumente")
        let (content, http) = try await dev.api.data("/api/files/d1/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(content, pdf)
        let count = await sync.adoptExistingDownloads()
        XCTAssertEqual(count, 0)
        // naechster Abgleich mit derselben Datei: kein Download
        let stud = fakeStudIP(pdf: pdf)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertEqual(stud.downloads, [])
    }

    /// Abgleich scheitert (Sitzung abgelaufen): Protokoll mit Fehler, vorhandene Dokumente bleiben
    func testFailedSyncIsLoggedAndKeepsDocuments() async throws {
        let dev = try device()
        let pdf = makePDF("Blatt")
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(fakeStudIP(pdf: pdf)))
        // im Editor geoeffnet: Kopie im PDF-Zwischenspeicher
        let store = DocumentStore(file: try await libraryFile(dev.api, "d1"), api: dev.api, root: dev.support)
        await store.load()
        XCTAssertNil(store.errorMessage)
        await store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.originalPDFURL.path))
        let expired = FakeStudIP()
        expired.set("/jsonapi.php/v1/users/me", HTTPReply(status: 401, contentType: "application/vnd.api+json"))
        await sync.run(client: client(expired))
        XCTAssertEqual(sync.phase, .needsLogin)
        let log = try await dev.api.value("/api/sync/status")["log"]?.array ?? []
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.first?["ok"], 0)
        XCTAssertEqual(log.first?["message"], "FEHLER: Stud.IP-Anmeldung abgelaufen. Bitte neu anmelden.")
        let lib = try await dev.api.value("/api/library")
        XCTAssertEqual(lib["files"]?.array?.count, 2)
        // "Abmelden und Dateien löschen": Dokumente und Notizen bleiben, die Datei fehlt bis zum naechsten Abgleich
        _ = try await dev.api.value("/api/files/d1/annotations?base_version=0", method: "PUT", body: ["pages": ["p1": ["objects": []]]])
        await sync.removeDownloads()
        let (_, http) = try await dev.api.data("/api/files/d1/content")
        XCTAssertEqual(http.statusCode, 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalPDFURL.path), "auch die Kopie des Editors ist weg")
        let notes = try await dev.api.value("/api/files/d1/annotations")
        XCTAssertEqual(notes["version"], 1)
        // naechster Abgleich laedt die Datei neu, der Editor oeffnet sie wieder
        let stud = fakeStudIP(pdf: pdf)
        await sync.run(client: client(stud))
        XCTAssertEqual(stud.downloads, ["/jsonapi.php/v1/file-refs/d1/content"])
        let again = DocumentStore(file: try await libraryFile(dev.api, "d1"), api: dev.api, root: dev.support)
        await again.load()
        XCTAssertNil(again.errorMessage)
        XCTAssertEqual(try again.originalPDFData(), pdf)
        await again.close()
    }

    /// Wie run_sync: ein Kurs ohne lesbare Dateiliste oder eine Datei, die sich nicht laden laesst, halten den
    /// Abgleich nicht an; der naechste Abgleich holt die Datei nach.
    func testErrorInOneCourseOrFileDoesNotStopTheSync() async throws {
        let dev = try device()
        let pdf = makePDF("Blatt")
        let stud = fakeStudIP(pdf: pdf)
        stud.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester", #"""
            {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}},
                     {"id":"c2","type":"courses","attributes":{"title":"Testkurs ohne Dateien"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
             "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
            """#)
        stud.set("/jsonapi.php/v1/courses/c2/folders?page[limit]=200", HTTPReply(status: 403, contentType: "application/vnd.api+json"))
        stud.json("/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500", #"""
            {"data":[{"id":"d1","attributes":{"name":"Blatt 3.pdf","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00"}},
                     {"id":"d3","attributes":{"name":"Blatt 4.pdf","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"2026-10-19T12:00:00+02:00"}}]}
            """#)
        stud.set("/jsonapi.php/v1/file-refs/d3/content", HTTPReply(status: 500, contentType: "text/plain"))
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(Set(stud.downloads), ["/jsonapi.php/v1/file-refs/d1/content", "/jsonapi.php/v1/file-refs/d3/content"])
        let summary = try XCTUnwrap(sync.lastSummary)
        XCTAssertTrue(summary.contains("1 nicht geladen (Fehler)"), summary)
        XCTAssertTrue(summary.contains("1 Kurs nicht lesbar"), summary)
        let lib = try await dev.api.value("/api/library")["files"]?.array ?? []
        XCTAssertNotEqual(lib.first { $0["id"] == "d1" }?["downloaded_at"], .null)
        XCTAssertEqual(lib.first { $0["id"] == "d3" }?["downloaded_at"], .null, "in der Datenbank, aber noch ohne Datei")
        let log = try await dev.api.value("/api/sync/status")["log"]?.array ?? []
        XCTAssertEqual(log.first?["ok"], 1)
        XCTAssertEqual(log.first?["message"], "1 neue/geaenderte Dateien")
        let courses = try await dev.api.value("/api/courses").array ?? []
        XCTAssertEqual(Set(courses.compactMap { $0["id"]?.string }), ["__user__", "c1", "c2"], "Kurs ohne Dateiliste steht trotzdem da")

        // Stud.IP liefert die Datei wieder: nur sie wird nachgeladen
        stud.set("/jsonapi.php/v1/file-refs/d3/content", HTTPReply(status: 200, contentType: "application/pdf", body: pdf))
        let before = stud.downloads.count
        await sync.run(client: client(stud))
        XCTAssertEqual(Array(stud.downloads.dropFirst(before)), ["/jsonapi.php/v1/file-refs/d3/content"])
        let d3 = try await dev.api.value("/api/files/d3")
        XCTAssertEqual(d3["exists"], true)
    }

    /// Ist kein einziger Kurs lesbar, gilt der Lauf als gescheitert (Meldung mit "Erneut versuchen")
    func testSyncFailsWhenNoCourseIsReadable() async throws {
        let dev = try device()
        let stud = fakeStudIP(pdf: makePDF("Blatt"))
        stud.set("/jsonapi.php/v1/courses/c1/folders?page[limit]=200", HTTPReply(status: 503, contentType: "text/plain"))
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(stud))
        guard case .failed(let message) = sync.phase else { return XCTFail("\(sync.phase)") }
        XCTAssertTrue(message.contains("503"), message)
        XCTAssertEqual(stud.downloads, [])
        let log = try await dev.api.value("/api/sync/status")["log"]?.array ?? []
        XCTAssertEqual(log.first?["ok"], 0)
        XCTAssertTrue(log.first?["message"]?.string?.hasPrefix("FEHLER: ") == true)
    }

    // MARK: Neue Fassung, Transportfehler, Kopien

    /// Neue Fassung in Stud.IP, ihr Download scheitert (Fehler bei Stud.IP) oder der Lauf bricht ab (Netz weg): der
    /// naechste Abgleich laedt sie trotzdem. Vorher stand die neue Aenderungszeit schon in der Datenbank, und die alte
    /// Datei galt still als aktuell.
    func testNewVersionArrivesAfterFailedDownloadOrAbort() async throws {
        let dev = try device()
        let v1 = makePDF("Fassung 1"), v2 = makePDF("Fassung 2")
        XCTAssertNotEqual(v1, v2)
        let changed = "2026-10-22T10:00:00+02:00"
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(fakeStudIP(pdf: v1)))
        func content() async throws -> Data { try await dev.api.data("/api/files/d1/content").0 }
        let first = try await content()
        XCTAssertEqual(first, v1)

        let broken = fakeStudIP(pdf: v2, changed: changed)
        broken.set("/jsonapi.php/v1/file-refs/d1/content", HTTPReply(status: 500, contentType: "text/plain"))
        await sync.run(client: client(broken))
        XCTAssertEqual(sync.phase, .idle, "Fehler nur dieser Datei")
        let afterError = try await content()
        XCTAssertEqual(afterError, v1)

        let offline = fakeStudIP(pdf: v2, changed: changed)
        offline.fail("/jsonapi.php/v1/file-refs/d1/content", URLError(.notConnectedToInternet))
        await sync.run(client: client(offline))
        guard case .failed = sync.phase else { return XCTFail("kein Netz bricht den Lauf ab: \(sync.phase)") }
        let afterAbort = try await content()
        XCTAssertEqual(afterAbort, v1)

        let ok = fakeStudIP(pdf: v2, changed: changed)
        await sync.run(client: client(ok))
        XCTAssertEqual(sync.phase, .idle)
        XCTAssertEqual(ok.downloads, ["/jsonapi.php/v1/file-refs/d1/content"], "naechster Abgleich laedt die neue Fassung")
        let latest = try await content()
        XCTAssertEqual(latest, v2)
        let meta = try await dev.api.value("/api/files/d1")
        XCTAssertEqual(meta["chdate"]?.int, StudIPLibrary.unixTime(changed))
        XCTAssertEqual(meta["size"]?.int, v2.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dev.studipRoot.appendingPathComponent(".laden").path), "keine halben Dateien")
        let quiet = fakeStudIP(pdf: v2, changed: changed)
        await sync.run(client: client(quiet))
        XCTAssertEqual(quiet.downloads, [], "danach unveraendert")
    }

    /// Zeitueberschreitung beim Download einer (grossen) Datei: nur diese fehlt, die uebrigen kommen an; der naechste
    /// Abgleich holt sie nach. Kein Netz beendet den Lauf (jede weitere Datei schluege ebenso fehl).
    func testTimeoutOfOneDownloadDoesNotStopTheOthers() async throws {
        XCTAssertFalse(StudIPSync.endsRun(URLError(.timedOut)))
        XCTAssertFalse(StudIPSync.endsRun(URLError(.networkConnectionLost)))
        XCTAssertTrue(StudIPSync.endsRun(URLError(.notConnectedToInternet)))
        XCTAssertTrue(StudIPSync.endsRun(URLError(.cancelled)))
        let dev = try device()
        let pdf = makePDF("Blatt")
        let stud = fakeStudIP(pdf: pdf)
        stud.json("/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500", #"""
            {"data":[{"id":"d1","attributes":{"name":"Vorlesung.mp4","filesize":800000000,"mime-type":"video/mp4","chdate":"2026-10-19T10:00:00+02:00"}},
                     {"id":"d3","attributes":{"name":"Blatt 4.pdf","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"2026-10-19T12:00:00+02:00"}}]}
            """#)
        stud.fail("/jsonapi.php/v1/file-refs/d1/content", URLError(.timedOut))
        stud.set("/jsonapi.php/v1/file-refs/d3/content", HTTPReply(status: 200, contentType: "application/pdf", body: pdf))
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        let summary = try XCTUnwrap(sync.lastSummary)
        XCTAssertTrue(summary.contains("1 nicht geladen (Fehler)"), summary)
        let d3 = try await dev.api.value("/api/files/d3")
        XCTAssertEqual(d3["exists"], true, "Datei hinter der langsamen kommt an")
        let d1 = try await dev.api.value("/api/files/d1")
        XCTAssertEqual(d1["exists"], false)

        stud.set("/jsonapi.php/v1/file-refs/d1/content", HTTPReply(status: 200, contentType: "video/mp4", body: Data("Film".utf8)))
        let before = stud.downloads.count
        await sync.run(client: client(stud))
        XCTAssertEqual(Array(stud.downloads.dropFirst(before)), ["/jsonapi.php/v1/file-refs/d1/content"])
        let again = try await dev.api.value("/api/files/d1")
        XCTAssertEqual(again["exists"], true)
    }

    /// Kopie ("Duplizieren") einer Stud.IP-Datei mit Notizen: nach "Abmelden und Dateien löschen" und erneutem
    /// Abgleich oeffnet sie sich wieder im Editor, mit ihren Notizen. Vorschaubilder der Stud.IP-Dateien gehen beim
    /// Loeschen mit.
    func testCopyOfStudIPFileOpensWithNotesAfterRemovingDownloads() async throws {
        let dev = try device()
        let pdf = makePDF("Blatt")
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
        await sync.run(client: client(fakeStudIP(pdf: pdf)))
        let dup = try await dev.api.value("/api/library/files/d1", method: "PATCH", body: ["duplicate": true])
        let copyID = try XCTUnwrap(dup["id"]?.string)
        let store = DocumentStore(file: try await libraryFile(dev.api, copyID), api: dev.api, root: dev.support)
        await store.load()
        XCTAssertNil(store.errorMessage)
        store.canvasChanged(pageKey: "p1", drawing: drawing(y: 300))
        await store.flush()
        let saved = await waitUntil { (try? await self.strokes(dev.api, copyID))?.count == 1 }
        XCTAssertTrue(saved, "Notiz der Kopie")
        await store.close()
        let thumbs = dev.support.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let thumb = thumbs.appendingPathComponent(LocalJournalName.safe(UFThumbnails.key(fileID: copyID, namespace: .local, version: "v")) + ".jpg")
        try Data("jpg".utf8).write(to: thumb)

        await sync.removeDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.originalPDFURL.path), "Kopie im Zwischenspeicher des Editors weg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path), "Vorschau weg")
        let (_, gone) = try await dev.api.data("/api/files/\(copyID)/content")
        XCTAssertEqual(gone.statusCode, 404)

        let stud = fakeStudIP(pdf: pdf)
        await sync.run(client: client(stud))
        XCTAssertEqual(stud.downloads, ["/jsonapi.php/v1/file-refs/d1/content"], "nur das Original wird geladen")
        let reopened = DocumentStore(file: try await libraryFile(dev.api, copyID), api: dev.api, root: dev.support)
        await reopened.load()
        XCTAssertNil(reopened.errorMessage, "Kopie oeffnet sich wieder")
        XCTAssertEqual(try reopened.originalPDFData(), pdf)
        let objects = await reopened.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 1, "mit ihren Notizen")
        await reopened.close()
    }

    /// Download der App direkt in eine Datei (nicht im Arbeitsspeicher), mit Sitzungs-Cookie; feste Antwort ueber
    /// `URLProtocol`, kein Netz
    func testURLSessionTransportDownloadsIntoFile() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixedReplyProtocol.self]
        FixedReplyProtocol.reply = (200, "application/pdf", Data("%PDF Testinhalt".utf8))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "Seminar_Session", .value: "test-sitzung", .domain: "studip.test", .path: "/"]))
        let t = URLSessionStudIPTransport(cookies: [cookie], host: "studip.test", configuration: config)
        let dir = try tempDir()
        let file = dir.appendingPathComponent("ziel.pdf")
        try Data("alt".utf8).write(to: file)
        let c = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        try await c.download(fileID: "d1", to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("%PDF Testinhalt".utf8), "ersetzt die alte Datei")
        XCTAssertEqual(FixedReplyProtocol.lastRequest?.url?.path, "/jsonapi.php/v1/file-refs/d1/content")
        XCTAssertEqual(FixedReplyProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"), "Seminar_Session=test-sitzung")
        // Fehlerseite statt Datei: nichts bleibt liegen
        FixedReplyProtocol.reply = (403, "application/vnd.api+json", Data("{}".utf8))
        let failed = dir.appendingPathComponent("fehler.pdf")
        do { try await c.download(fileID: "d2", to: failed); XCTFail("403") } catch {
            XCTAssertEqual(error as? StudIPError, .http(status: 403, path: "jsonapi.php/v1/file-refs/d2/content"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    // MARK: Eigene Dokumente

    /// Bild importieren: wie mit Pillow am PC eine einseitige PDF in Bildgroesse (ein Pixel = ein Punkt), abgelegt im
    /// App-Container und im Editor beschreibbar
    func testImportedImageBecomesOnePagePDF() async throws {
        let dev = try device()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let created = try await dev.api.upload("/api/notebooks", fields: ["kind": "image", "title": "Testfoto"], fileField: "upload",
                                               fileName: "foto.png", mimeType: "image/png", data: png)
        let id = try XCTUnwrap(created["id"]?.string)
        XCTAssertEqual(created["name"], "Testfoto.pdf")
        XCTAssertEqual(created["page_count"], 1)
        XCTAssertEqual(created["course_id"], "__user__")
        XCTAssertEqual(created["local_path"]?.string, "Library/Application Support/UniFlow/files/Eigene Dokumente/\(id).pdf")
        let (data, http) = try await dev.api.data("/api/files/\(id)/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 40, height: 30))

        let file = try await libraryFile(dev.api, id)
        XCTAssertTrue(file.isPDF)
        let store = DocumentStore(file: file, api: dev.api, root: dev.support)
        await store.load()
        XCTAssertNil(store.errorMessage)
        store.canvasChanged(pageKey: "p1", drawing: drawing(y: 15, x0: 4, step: 3))
        await store.flush()
        let saved = await waitUntil { (try? await self.strokes(dev.api, id))?.count == 1 }
        XCTAssertTrue(saved)
        await store.close()
    }

    // MARK: Wechsel PC <-> lokal

    /// "PC" im Speicher: beantwortet Datei-Inhalt und Notizen wie app/server.py (409 bei veraltetem Stand)
    private final class FakePC: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var version = 0
        private var root: JSONValue = AnnotationDocument.emptyRoot
        let pdf: Data

        init(pdf: Data) { self.pdf = pdf }

        var stored: (Int, JSONValue) { lock.lock(); defer { lock.unlock() }; return (version, root) }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            func reply(_ status: Int, _ body: Data, _ type: String = "application/json") -> (Data, HTTPURLResponse) {
                (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
            }
            lock.lock()
            defer { lock.unlock() }
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/api/files/d1/content"): return reply(200, pdf, "application/pdf")
            case ("GET", "/api/files/d1/annotations"):
                return reply(200, JSONValue.object(["data": root, "version": .number(Double(version)), "updated_at": .null]).serialized())
            case ("PUT", "/api/files/d1/annotations"):
                let base = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "base_version" }?.value.flatMap(Int.init)
                if let base, version > 0, base != version {
                    return reply(409, JSONValue.object(["detail": "Konflikt", "version": .number(Double(version)), "data": root]).serialized())
                }
                version += 1
                root = try JSONValue.parse(request.httpBody ?? Data())
                return reply(200, JSONValue.object(["ok": true, "version": .number(Double(version))]).serialized())
            default:
                return reply(404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
    }

    func testSwitchingBetweenPCAndLocalLosesNothing() async throws {
        let dev = try device()
        let pdf = makePDF("Gemeinsam")
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(fakeStudIP(pdf: pdf)))
        let file = try await libraryFile(dev.api, "d1")

        // lokal schreiben
        let local = DocumentStore(file: file, api: dev.api, root: dev.support)
        await local.load()
        local.canvasChanged(pageKey: "p1", drawing: drawing(y: 200))
        await local.flush()
        let localSaved = await waitUntil { (try? await self.strokes(dev.api, "d1"))?.count == 1 }
        XCTAssertTrue(localSaved)
        await local.close()
        let localStroke = try await strokes(dev.api, "d1").first?["id"]

        // Wechsel zum eigenen Server (gleiche Datei-ID, eigener Namensraum), dort schreiben
        let pc = FakePC(pdf: pdf)
        let server = APIClient(base: URL(string: "http://10.0.0.2:8765")!, transport: pc)
        let remote = DocumentStore(file: file, api: server, root: dev.support)
        await remote.load()
        XCTAssertNil(remote.errorMessage)
        XCTAssertEqual(remote.namespace.id, "server-10.0.0.2-8765")
        let startObjects = await remote.objects(forPageKey: "p1")
        XCTAssertTrue(startObjects.isEmpty, "lokale Notizen gehen nicht an den Server")
        remote.canvasChanged(pageKey: "p1", drawing: drawing(y: 500))
        await remote.flush()
        let pcSaved = await waitUntil { pc.stored.0 >= 1 }
        XCTAssertTrue(pcSaved)
        await remote.close()

        // lokal unveraendert, PC hat nur seinen Strich
        let localNow = try await strokes(dev.api, "d1")
        XCTAssertEqual(localNow.map { $0["id"] }, [localStroke])
        let pcStrokes = (pc.stored.1["pages"]?["p1"]?["objects"]?.array ?? []).filter { $0["type"]?.string == "stroke" }
        XCTAssertEqual(pcStrokes.count, 1)
        XCTAssertNotEqual(pcStrokes.first?["id"], localStroke)

        // zurueck lokal: der lokale Strich ist da, der des PCs nicht; Journale getrennt
        let back = DocumentStore(file: file, api: dev.api, root: dev.support)
        await back.load()
        let objects = await back.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.map { $0["id"] }, [localStroke])
        await back.close()
        let spaces = dev.support.appendingPathComponent("journal/spaces")
        let names = try FileManager.default.contentsOfDirectory(atPath: spaces.path).sorted()
        XCTAssertEqual(names, ["local", "server-10.0.0.2-8765"])
    }
}

/// Feste HTTP-Antwort fuer eine URLSession in Tests (kein Netz); merkt sich die letzte Anfrage.
final class FixedReplyProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stored: (status: Int, type: String, body: Data) = (200, "", Data())
    private static var request: URLRequest?

    static var reply: (status: Int, type: String, body: Data) {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        Self.lock.unlock()
        let r = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": r.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import Foundation
import XCTest
@testable import UniFlowCore

/// Stud.IP mit Netzfehlern: wirft fuer einen Pfad zuerst die angegebenen Fehler, danach die feste Antwort.
private final class FlakyStudIP: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error]
    private let reply: HTTPReply
    private(set) var calls = 0

    init(failures: [Error], reply: HTTPReply) { self.failures = failures; self.reply = reply }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply { try next() }

    /// synchron, damit die Sperre nicht ueber ein await reicht
    private func next() throws -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return reply
    }
}

/// Zusammenfuehren mit dem PC-Kern: eine Fassung fuer Kurse und Dateien (`UniStore`, wie store_course_files) fuer
/// Stud.IP und Learnweb, Inhalts-Hash beim Download, Wiederholung wie stream_download, LSF-Import ueber denselben
/// Stundenplan-Import wie jeder Kalender (lsf.import_plan).
final class UniStoreTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:00:00")!
    private let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("unistore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func database(university: String = "luh") async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock, university: university)
        return db
    }

    // MARK: Inhalts-Hash (testshare.file_sha256)

    func testStreamingSHA256MatchesOneShotAndFileHash() throws {
        XCTAssertEqual(SolutionSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let dir = try tempDir()
        var gen = SystemRandomNumberGenerator()
        for size in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000, (1 << 20) + 3, 5 << 19] {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &gen) })
            var h = SolutionSHA256.Hasher()
            var i = 0
            for step in [1, 7, 64, 63, 200].cycled(upTo: size) where i < size {   // Stuecke quer ueber Blockgrenzen
                let end = min(size, i + step)
                h.update(data[i..<end])
                i = end
            }
            XCTAssertEqual(SolutionSHA256.hexString(h.finalize()), SolutionSHA256.hex(data), "\(size) Byte")
            let file = dir.appendingPathComponent("f\(size)")
            try data.write(to: file)
            XCTAssertEqual(ContentHash.file(file), SolutionSHA256.hex(data), "Datei mit \(size) Byte")
        }
        XCTAssertNil(ContentHash.file(dir.appendingPathComponent("fehlt")))
        XCTAssertNil(ContentHash.file(dir), "Ordner ist keine Datei")
    }

    // MARK: Stud.IP-Download wie stream_download

    func testStudIPDownloadRetriesBrokenConnectionButNotHTTPErrors() async throws {
        let dir = try tempDir()
        let pdf = HTTPReply(status: 200, contentType: "application/pdf", body: Data("%PDF-1.7".utf8))
        let flaky = FlakyStudIP(failures: [URLError(.networkConnectionLost), URLError(.timedOut)], reply: pdf)
        try await StudIPClient(base: URL(string: "https://studip.test")!, transport: flaky, pauseMillis: 0, retry: noWait)
            .download(fileID: "f1", to: dir.appendingPathComponent("a"), name: "a.pdf")
        XCTAssertEqual(flaky.calls, 3, "zweimal wiederholt")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a")), Data("%PDF-1.7".utf8))

        let gone = FlakyStudIP(failures: Array(repeating: URLError(.networkConnectionLost), count: 5), reply: pdf)
        do {
            try await StudIPClient(base: URL(string: "https://studip.test")!, transport: gone, pauseMillis: 0, retry: noWait)
                .download(fileID: "f1", to: dir.appendingPathComponent("b"), name: "b.pdf")
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(gone.calls, 3, "hoechstens 3 Versuche")

        let broken = FlakyStudIP(failures: [], reply: HTTPReply(status: 500, contentType: "text/plain"))
        do {
            try await StudIPClient(base: URL(string: "https://studip.test")!, transport: broken, pauseMillis: 0, retry: noWait)
                .download(fileID: "f1", to: dir.appendingPathComponent("c"), name: "c.pdf")
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? StudIPError, .http(status: 500, path: "jsonapi.php/v1/file-refs/f1/content"))
        }
        XCTAssertEqual(broken.calls, 1, "HTTP-Fehler aendern sich durch Wiederholen nicht")

        let cancelled = FlakyStudIP(failures: [URLError(.cancelled)], reply: pdf)
        do {
            try await StudIPClient(base: URL(string: "https://studip.test")!, transport: cancelled, pauseMillis: 0, retry: noWait)
                .download(fileID: "f1", to: dir.appendingPathComponent("d"), name: "d.pdf")
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(cancelled.calls, 1, "Abbruch nicht wiederholen")
    }

    func testStudIPWebPageInsteadOfFileIsNotStored() async throws {
        let dir = try tempDir()
        let page = HTTPReply(status: 200, contentType: "text/html; charset=utf-8", body: Data("  \n<!DOCTYPE html><html>Wartung</html>".utf8))
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: FlakyStudIP(failures: [], reply: page),
                                  pauseMillis: 0, retry: noWait)
        let target = dir.appendingPathComponent("blatt")
        do {
            try await client.download(fileID: "f1", to: target, name: "Blatt 1.pdf")
            XCTFail("Webseite statt Datei")
        } catch let e as StudIPError {
            XCTAssertTrue(e.affectsOnlyItem, "nur diese Datei, der Abgleich laeuft weiter")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nichts gespeichert")
        try await client.download(fileID: "f1", to: target, name: "Hinweise.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "echte HTML-Datei bleibt")
        // echte HTML-Datei mit "login" im Text: keine abgelaufene Sitzung (vorher brach jeder Abgleich an ihr ab)
        let withLogin = HTTPReply(status: 200, contentType: "text/html", body: Data("<html><a href='login.php'>Login-Hilfe</a></html>".utf8))
        let c2 = StudIPClient(base: URL(string: "https://studip.test")!, transport: FlakyStudIP(failures: [], reply: withLogin),
                              pauseMillis: 0, retry: noWait)
        let t2 = dir.appendingPathComponent("hilfe")
        try await c2.download(fileID: "f2", to: t2, name: "Login-Hilfe.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: t2.path))
        do {
            try await c2.download(fileID: "f2", to: t2, name: "Skript.pdf")
            XCTFail("Anmeldeseite statt PDF")
        } catch let e as StudIPError {
            XCTAssertEqual(e, .sessionExpired, "statt einer PDF weiter als abgelaufene Anmeldung erkannt")
        }
    }

    // MARK: Eine Fassung fuer Kurse und Dateien

    /// Stud.IP (`StudIPLibrary`) und Learnweb (`Learnweb.File.row`) schreiben ueber dieselben Funktionen und Regeln
    func testStudIPAndLearnwebShareOneStore() async throws {
        let db = try await database()
        let base = URL(string: "https://studip.test")!
        let studip = StudIPFile(id: "s1", courseID: "c1", name: "Übung 3.pdf", size: 4, mimeType: nil,
                                changed: "2026-10-19T10:00:00+02:00", folderPath: "")
        let learnweb = Learnweb.File(id: "lw-80-0123abcd", name: "plot.gif", size: 9, mime: "image/gif", author: "Dozentin Test",
                                     chdate: 100, downloadURL: "https://lw.test/pluginfile.php/5/a/1/plot.gif", folder: "")
        let wanted = try await db.transaction { c -> ([StudIPFile], [UniStore.FileRow]) in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "c1", title: "Übung zu Testmathematik I", number: "7", semesterTitle: nil)],
                                           startedAt: "2026-10-26T09:00:00")
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-35", title: "0435 Testmathematik I", number: "0435", semester: "WiSe 2026/27"),
                                      now: "2026-10-26T09:00:00")
            return (try StudIPLibrary.storeFiles(c, [studip], startedAt: "2026-10-26T09:00:00", base: base, localFiles: nil),
                    try UniStore.storeFiles(c, courseID: "lw-35", [learnweb.row], now: "2026-10-26T09:00:00", fileExists: { _ in false }))
        }
        XCTAssertEqual(wanted.0.map(\.id), ["s1"])
        XCTAssertEqual(wanted.1.map(\.id), ["lw-80-0123abcd"])
        let courses = try await db.rows("SELECT id, subject, kind, semester FROM courses WHERE id IN ('c1', 'lw-35') ORDER BY id")
        XCTAssertEqual(courses.map { $0["subject"]?.string }, ["Testmathematik I", "Testmathematik I"], "ein Fach aus beiden Quellen")
        XCTAssertEqual(courses.map { $0["kind"]?.string }, ["uebung", "vorlesung"])
        XCTAssertEqual(courses.first?["semester"]?.string, "", "Stud.IP ohne Semester wie Python")
        let files = try await db.rows("SELECT id, kind, author, studip_folder, status FROM files WHERE id IN ('s1', 'lw-80-0123abcd') ORDER BY id")
        XCTAssertEqual(files.map { $0["kind"]?.string }, ["image", "pdf"], "Dateiart aus UniRules.fileKind")
        XCTAssertEqual(files.first?["author"]?.string, "Dozentin Test", "Learnweb-Autor wie files_from_contents")
        XCTAssertEqual(files.map { $0["studip_folder"] }, [.null, .string("")], "Learnweb ohne Ordner laesst ihn leer, Stud.IP-Wurzel ist \"\"")
        XCTAssertEqual(files.map { $0["status"]?.string }, ["neu", "neu"])
    }

    /// Neue Fassung einer Learnweb-Datei erst mit dem Download (S3-Regel, jetzt fuer alle Quellen); der Inhalts-Hash
    /// gehoert immer zur Datei auf der Platte.
    func testNewVersionAndHashOnlyWithDownload() async throws {
        let db = try await database(university: "hildesheim")
        let dir = try tempDir()
        func row(_ chdate: Int, size: Int) -> UniStore.FileRow {
            UniStore.FileRow(id: "lw-1-aa", name: "Folien.pdf", size: size, mime: "application/pdf", chdate: chdate,
                             downloadURL: "https://lw.test/pluginfile.php/1/mod_resource/content/\(chdate)/Folien.pdf", folder: "Woche 1")
        }
        func store(_ r: UniStore.FileRow) async throws -> [String] {
            try await db.transaction { c in
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "0401 Testkurs", number: "0401", semester: "WiSe 2026/27"),
                                          now: "2026-10-26T09:00:00")
                return try UniStore.storeFiles(c, courseID: "lw-1", [r], now: "2026-10-26T09:00:00",
                                               fileExists: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
            }.map(\.id)
        }
        func load(_ r: UniStore.FileRow, _ text: String) async throws {
            let file = dir.appendingPathComponent("files/lw-1-aa/Folien.pdf")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            let sha = ContentHash.file(file)
            try await db.transaction { try UniStore.markDownloaded($0, r, localPath: "files/lw-1-aa/Folien.pdf", sha256: sha, now: "2026-10-26T09:00:00") }
        }
        func current() async throws -> [String: JSONValue] {
            try await db.rows("SELECT chdate, size, content_sha256, studip_folder, download_url FROM files WHERE id='lw-1-aa'")[0]
        }
        let pending = try await store(row(4, size: 10))
        XCTAssertEqual(pending, ["lw-1-aa"])
        try await load(row(4, size: 10), "%PDF Fassung 4")
        let unchanged = try await store(row(4, size: 10))
        XCTAssertEqual(unchanged, [], "unveraendert: kein zweiter Download")
        let changed = try await store(row(5, size: 12))
        XCTAssertEqual(changed, ["lw-1-aa"], "hoehere Revision")
        // Download der neuen Fassung scheitert: alte Fassung samt Hash bleibt, Adresse und Ordner sind neu
        var r = try await current()
        XCTAssertEqual(r["chdate"]?.int, 4)
        XCTAssertEqual(r["size"]?.int, 10)
        XCTAssertEqual(r["content_sha256"]?.string, SolutionSHA256.hex(Data("%PDF Fassung 4".utf8)))
        XCTAssertEqual(r["download_url"]?.string, row(5, size: 12).downloadURL)
        let again = try await store(row(5, size: 12))
        XCTAssertEqual(again, ["lw-1-aa"], "naechster Abgleich laedt die neue Fassung erneut")
        try await load(row(5, size: 12), "%PDF Fassung 5")
        r = try await current()
        XCTAssertEqual(r["chdate"]?.int, 5)
        XCTAssertEqual(r["size"]?.int, 12)
        XCTAssertEqual(r["content_sha256"]?.string, SolutionSHA256.hex(Data("%PDF Fassung 5".utf8)))
        XCTAssertEqual(r["studip_folder"]?.string, "Woche 1")
    }

    /// Learnweb ueber die Sitzung wie studip_sync.version_stamp: chdate ist eine Unix-Zeit (erste Sichtung, neue
    /// Revision = Zeitpunkt des Abgleichs), nie die Revision (vorher Lehrwoche 1970, Block "Ältere Unterlagen").
    /// Wechsel Schluessel <-> Sitzung: gleiche Revision bleibt unveraendert (kein Download, Groesse bleibt), eine
    /// hoehere wird geladen; alte Zeilen mit der Revision in chdate werden auf first_seen repariert.
    func testSessionFilesGetRealTimesAcrossKeyAndSession() async throws {
        let db = try await database(university: "hildesheim")
        let base = "https://www.uni-hildesheim.de/learnweb2026"
        func key(_ rev: Int, _ t: Int) -> UniStore.FileRow {
            UniStore.FileRow(id: "lw-9-bb", name: "Blatt 3.pdf", size: 900, mime: "application/pdf", author: "Muster", chdate: t,
                             revision: rev, downloadURL: "\(base)/webservice/pluginfile.php/7/mod_resource/content/\(rev)/Blatt%203.pdf", folder: nil)
        }
        func session(_ rev: Int) -> UniStore.FileRow {
            UniStore.FileRow(id: "lw-9-bb", name: "Blatt 3.pdf", size: nil, mime: "application/pdf", chdate: nil, revision: rev,
                             downloadURL: "\(base)/pluginfile.php/7/mod_resource/content/\(rev)/Blatt%203.pdf", folder: nil)
        }
        func store(_ r: UniStore.FileRow, at now: String) async throws -> [UniStore.FileRow] {
            try await db.transaction { c in
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-9", title: "0407 Methoden", number: "0407", semester: "SoSe 2026"),
                                          now: now)
                return try UniStore.storeFiles(c, courseID: "lw-9", [r], now: now, fileExists: { _ in true })
            }
        }
        func loaded(_ r: UniStore.FileRow, at now: String) async throws {
            var r = r
            if r.size == nil { r.size = 77 }                                  // wie UniDownloads: Groesse der geladenen Datei
            try await db.transaction { [r] in try UniStore.markDownloaded($0, r, localPath: "files/lw-9-bb/Blatt 3.pdf", sha256: "x", now: now) }
        }
        func row() async throws -> [JSONValue] {
            let r = try await db.rows("SELECT chdate, size, revision FROM files WHERE id='lw-9-bb'")[0]
            return [r["chdate"] ?? .null, r["size"] ?? .null, r["revision"] ?? .null]
        }
        let t0 = try XCTUnwrap(BerlinClock.utcSeconds(localISO: "2026-10-20T08:00:00"))
        // Sitzung, erste Sichtung: Zeitpunkt des Abgleichs
        let first = try await store(session(2), at: "2026-10-20T08:00:00")
        XCTAssertEqual(first.map(\.chdate), [t0])
        try await loaded(try XCTUnwrap(first.first), at: "2026-10-20T08:00:00")
        var r = try await row()
        XCTAssertEqual(r, [.number(Double(t0)), 77, 2])
        // gleiche Revision: kein Download, Zeitpunkt und Groesse bleiben
        var todo = try await store(session(2), at: "2026-10-21T08:00:00")
        XCTAssertEqual(todo, [])
        r = try await row()
        XCTAssertEqual(r, [.number(Double(t0)), 77, 2])
        // Wechsel zum Schluessel, gleiche Revision: echte Aenderungszeit, kein Download
        todo = try await store(key(2, 1_760_900_000), at: "2026-10-22T08:00:00")
        XCTAssertEqual(todo, [])
        r = try await row()
        XCTAssertEqual(r, [1_760_900_000, 900, 2])
        // zurueck zur Sitzung, gleiche Revision: unveraendert (vorher chdate = 2, size = 0)
        todo = try await store(session(2), at: "2026-10-23T08:00:00")
        XCTAssertEqual(todo, [])
        r = try await row()
        XCTAssertEqual(r, [1_760_900_000, 900, 2])
        // hoehere Revision ueber die Sitzung: geladen, Zeitpunkt des Abgleichs
        todo = try await store(session(3), at: "2026-10-24T08:00:00")
        let t4 = try XCTUnwrap(BerlinClock.utcSeconds(localISO: "2026-10-24T08:00:00"))
        XCTAssertEqual(todo.map(\.chdate), [t4])
        try await loaded(try XCTUnwrap(todo.first), at: "2026-10-24T08:00:00")
        r = try await row()
        XCTAssertEqual(r, [.number(Double(t4)), 77, 3])
        // Zeile von vor files.revision (Revision 3 in chdate): repariert auf first_seen, ohne Download
        try await db.execute("UPDATE files SET chdate=3, revision=NULL, first_seen='2026-10-19T10:00:00' WHERE id='lw-9-bb'")
        todo = try await store(session(3), at: "2026-10-25T08:00:00")
        XCTAssertEqual(todo, [])
        r = try await row()
        XCTAssertEqual(r, [.number(Double(try XCTUnwrap(BerlinClock.utcSeconds(localISO: "2026-10-19T10:00:00")))), 77, 3])
    }

    /// Scheitert nach dem Ersetzen der Eintrag in die Datenbank, liegt wieder die bisherige Datei am Platz (vorher die
    /// neue Fassung unter Hash und Seitentexten der alten); eine neue Datei ohne Eintrag wird wieder entfernt
    func testFailedEntryPutsThePreviousFileBack() async throws {
        let db = try await database(university: "hildesheim")
        let dir = try tempDir()
        let downloads = UniDownloads(folder: dir.appendingPathComponent("Learnweb"), files: LocalFiles(container: dir, dataDirectory: ""),
                                     container: nil, source: "Learnweb")
        try downloads.begin()
        let row = UniStore.FileRow(id: "lw-1-cc", name: "VL.pdf", size: 9, mime: "application/pdf", chdate: 10,
                                   downloadURL: "https://lw.test/pluginfile.php/1/mod_resource/content/1/VL.pdf", folder: nil)
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "0401 Testkurs", number: "0401", semester: nil), now: "2026-10-26T09:00:00")
            _ = try UniStore.storeFiles(c, courseID: "lw-1", [row], now: "2026-10-26T09:00:00", fileExists: { _ in false })
        }
        func fetch(_ text: String) -> @Sendable (URL) async throws -> Void { { try Data(text.utf8).write(to: $0) } }
        let stored = try await downloads.load(row, to: "files/lw-1-cc/VL.pdf", db: db, clock: clock, fetch: fetch("%PDF alt"))
        let file = dir.appendingPathComponent(stored)
        try await db.execute("CREATE TRIGGER kein_eintrag BEFORE UPDATE OF local_path ON files BEGIN SELECT RAISE(ABORT, 'voll'); END")
        do {
            _ = try await downloads.load(row, to: "files/lw-1-cc/VL.pdf", db: db, clock: clock, fetch: fetch("%PDF neu"))
            XCTFail("Eintrag sollte scheitern")
        } catch let e as UniDownloads.Failure {
            XCTAssertEqual(e, .notRecorded("VL.pdf"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "%PDF alt", "bisherige Datei wieder am Platz")
        do {
            _ = try await downloads.load(row, to: "files/lw-1-cc/Neu.pdf", db: db, clock: clock, fetch: fetch("%PDF neu"))
            XCTFail("Eintrag sollte scheitern")
        } catch let e as UniDownloads.Failure {
            XCTAssertEqual(e, .notRecorded("VL.pdf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Learnweb/files/lw-1-cc/Neu.pdf").path))
        let sha = try await db.scalar("SELECT content_sha256 FROM files WHERE id='lw-1-cc'")?.string
        XCTAssertEqual(sha, SolutionSHA256.hex(Data("%PDF alt".utf8)))
        downloads.end()
    }

    // MARK: LSF-Stundenplan (lsf.import_plan)

    private func lsfPlan() throws -> [LSFCalendar.Entry] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let ics = try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/hildesheim/lsf-plan.ics"), encoding: .utf8)
        return LSFCalendar.planEntries(ics)
    }

    /// Wie Python: Kurs ueber Nummer und Semester, Modul geraten (`enrich`), Ausfaelle "laut LSF" ohne Doppelte,
    /// Serien anderer Quellen und Ausnahmen des Nutzers bleiben, verschwundene LSF-Serien gehen.
    func testLSFImportLikePython() async throws {
        let db = try await database(university: "hildesheim")
        try await db.execute("INSERT INTO modules(name) VALUES ('Mit Beispielen arbeiten')")
        try await db.execute("INSERT INTO modules(name) VALUES ('Testpädagogik')")
        try await db.execute("""
            INSERT INTO courses(id, title, number, semester, module_id) VALUES
              ('lw-9505', '9505 Einführung in die Testpädagogik I', '9505', 'WiSe 2026/27', 2),
              ('lw-old', '9449 Erinnerungen', '9449', 'SoSe 2026', 2)
            """)
        try await db.execute("""
            INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
            VALUES ('Eigener Termin', 'vorlesung', 2, '08:00', '09:00', 'weekly', 1, 'manual', 'x')
            """)
        let plan = try lsfPlan()
        let clock = self.clock
        let r1 = try await db.transaction { try UniStore.importPlan($0, plan, clock: clock) }
        XCTAssertEqual(r1, UniStore.PlanResult(new: 4, removed: 0, kept: 0, cancelledDates: 2))
        let events = try await db.rows("SELECT title, kind, weekday, course_id, module_id, lecturer FROM course_events WHERE source='lsf' ORDER BY title, weekday")
        let byTitle = Dictionary(grouping: events) { $0["title"]?.string ?? "" }
        let kunst = try XCTUnwrap(byTitle["Mit Beispielen arbeiten"]?.first)
        XCTAssertEqual(kunst["module_id"]?.int, 1, "Modul wie guess_module")
        XCTAssertEqual(kunst["course_id"], .null)
        let sozial = byTitle["Einführung in die Testpädagogik I"] ?? []
        XCTAssertEqual(sozial.count, 2, "BYDAY=TU,TH: zwei Serien")
        XCTAssertEqual(sozial.compactMap { $0["course_id"]?.string }, ["lw-9505", "lw-9505"], "Kurs ueber Nummer und Semester")
        XCTAssertEqual(sozial.compactMap { $0["module_id"]?.int }, [2, 2])
        let erinnerung = try XCTUnwrap(byTitle.first { $0.key.hasPrefix("Erinnerungen") }?.value.first)
        XCTAssertEqual(erinnerung["course_id"], .null, "Nummer aus einem anderen Semester zaehlt nicht")
        XCTAssertEqual(erinnerung["lecturer"]?.string, "Muster")
        let notes = try await db.rows("SELECT note FROM event_exceptions ORDER BY date")
        XCTAssertEqual(notes.compactMap { $0["note"]?.string }, ["fällt aus laut LSF", "fällt aus laut LSF"])
        let parsed = try await db.scalar("SELECT parsed FROM schedule_imports WHERE source='lsf-auto'")?.string ?? ""
        XCTAssertEqual(try JSONValue.parse(parsed).array?.count, 4)

        // zweiter Lauf: nichts neu, keine doppelten Ausfaelle
        let r2 = try await db.transaction { try UniStore.importPlan($0, plan, clock: clock) }
        XCTAssertEqual(r2, UniStore.PlanResult(new: 0, removed: 0, kept: 4, cancelledDates: 0))

        // eine Serie verschwindet aus dem LSF: nur sie geht, der eigene Termin bleibt
        let shorter = plan.filter { $0.title != "Mit Beispielen arbeiten" }
        let r3 = try await db.transaction { try UniStore.importPlan($0, shorter, clock: clock) }
        XCTAssertEqual(r3.removed, 1)
        let manual = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='manual'")?.int
        XCTAssertEqual(manual, 1)
        let lsf = try await db.scalar("SELECT COUNT(*) FROM course_events WHERE source='lsf'")?.int
        XCTAssertEqual(lsf, 3)
    }
}

private extension Array where Element == Int {
    /// Schrittweiten der Reihe nach wiederholt, bis zusammen mindestens `total` erreicht ist
    func cycled(upTo total: Int) -> [Int] {
        var out: [Int] = [], sum = 0, i = 0
        while sum < total { out.append(self[i % count]); sum += self[i % count]; i += 1 }
        return out
    }
}

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
        for size in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000, (1 << 20) + 3] {
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
            XCTAssertEqual(TestShare.contentHash(file: file), SolutionSHA256.hex(data), "Datei mit \(size) Byte")
        }
        XCTAssertNil(TestShare.contentHash(file: dir.appendingPathComponent("fehlt")))
        XCTAssertNil(TestShare.contentHash(file: dir), "Ordner ist keine Datei")
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
            let sha = TestShare.contentHash(file: file)
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
        try await db.execute("INSERT INTO modules(name) VALUES ('Mit Kunst und Kultur arbeiten')")
        try await db.execute("INSERT INTO modules(name) VALUES ('Sozialpädagogik')")
        try await db.execute("""
            INSERT INTO courses(id, title, number, semester, module_id) VALUES
              ('lw-1505', '1505 Einführung in die Sozialpädagogik I', '1505', 'WiSe 2026/27', 2),
              ('lw-old', '0449 Erinnerungen', '0449', 'SoSe 2026', 2)
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
        let kunst = try XCTUnwrap(byTitle["Mit Kunst und Kultur arbeiten"]?.first)
        XCTAssertEqual(kunst["module_id"]?.int, 1, "Modul wie guess_module")
        XCTAssertEqual(kunst["course_id"], .null)
        let sozial = byTitle["Einführung in die Sozialpädagogik I"] ?? []
        XCTAssertEqual(sozial.count, 2, "BYDAY=TU,TH: zwei Serien")
        XCTAssertEqual(sozial.compactMap { $0["course_id"]?.string }, ["lw-1505", "lw-1505"], "Kurs ueber Nummer und Semester")
        XCTAssertEqual(sozial.compactMap { $0["module_id"]?.int }, [2, 2])
        let erinnerung = try XCTUnwrap(byTitle.first { $0.key.hasPrefix("Erinnerungen") }?.value.first)
        XCTAssertEqual(erinnerung["course_id"], .null, "Nummer aus einem anderen Semester zaehlt nicht")
        XCTAssertEqual(erinnerung["lecturer"]?.string, "Zimmermann")
        let notes = try await db.rows("SELECT note FROM event_exceptions ORDER BY date")
        XCTAssertEqual(notes.compactMap { $0["note"]?.string }, ["fällt aus laut LSF", "fällt aus laut LSF"])
        let parsed = try await db.scalar("SELECT parsed FROM schedule_imports WHERE source='lsf-auto'")?.string ?? ""
        XCTAssertEqual(try JSONValue.parse(parsed).array?.count, 4)

        // zweiter Lauf: nichts neu, keine doppelten Ausfaelle
        let r2 = try await db.transaction { try UniStore.importPlan($0, plan, clock: clock) }
        XCTAssertEqual(r2, UniStore.PlanResult(new: 0, removed: 0, kept: 4, cancelledDates: 0))

        // eine Serie verschwindet aus dem LSF: nur sie geht, der eigene Termin bleibt
        let shorter = plan.filter { $0.title != "Mit Kunst und Kultur arbeiten" }
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

import XCTest
@testable import UniFlowCore

/// Korrekturen aus docs/AUDIT-ROBUSTHEIT-2026-11-03.md
final class AuditRobustheit20261103Tests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-03T09:00:00")!

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("audit-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Das Protokoll der LSF-Anmeldung (`HildesheimConnection.pageLoaded`, privacy .public) zeigt keine Sitzungskennung,
    /// die das LSF als `;jsessionid=` an den Pfad haengt
    func testLoggablePathDropsSessionParameters() {
        let u = URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds;jsessionid=ABC123.lsf1?state=user&type=0")!
        XCTAssertTrue(u.path.contains("jsessionid"), "Voraussetzung: URL.path liefert Pfad-Parameter mit")
        XCTAssertEqual(HildesheimCAS.loggablePath(u), "/qisserver/rds")
        XCTAssertEqual(HildesheimCAS.loggablePath(URL(string: "https://x.de/a;b=1/c;d/e")!), "/a/c/e")
        XCTAssertEqual(HildesheimCAS.loggablePath(URL(string: "https://x.de/qisserver/rds")!), "/qisserver/rds")
        XCTAssertEqual(HildesheimCAS.loggablePath(URL(string: "https://x.de")!), "")
    }

    // MARK: P2-2 Zweiter Lauf desselben Containers

    /// Ein zweiter Lauf auf denselben Ordner (Wechsel A → B → A waehrend eines langen Abgleichs) beginnt, waehrend der
    /// erste gerade eine Datei laedt: vorher loeschte sein `begin()` den Zwischenordner `.laden` und damit die
    /// Zwischendatei des ersten ("Datei nicht gespeichert"). Jetzt hat jeder Lauf einen eigenen Unterordner; Reste
    /// abgebrochener Laeufe (auch aus der Zeit vor den Unterordnern) raeumt `begin()` weiter weg.
    func testSecondRunDoesNotRemoveTheTempFolderOfARunningRun() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock, university: "hildesheim")
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("Learnweb", isDirectory: true)
        let files = LocalFiles(container: dir, dataDirectory: "")
        let first = UniDownloads(folder: folder, files: files, container: nil, source: "Learnweb")
        let second = UniDownloads(folder: folder, files: files, container: nil, source: "Learnweb")
        XCTAssertNotEqual(first.partial, second.partial, "eigener Unterordner je Lauf")

        // Reste eines abgebrochenen Laufs: alte Ablage direkt in .laden und ein fremder Unterordner
        let root = UniDownloads.partial(in: folder)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("abgebrochen"), withIntermediateDirectories: true)
        try Data("halb".utf8).write(to: root.appendingPathComponent("abgebrochen/x.part"))
        try Data("halb".utf8).write(to: root.appendingPathComponent("alt.part"))

        try first.begin()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [], [], "Reste weg")
        XCTAssertTrue(UniDownloads.isRunning(in: folder, run: first.run))
        let row = UniStore.FileRow(id: "lw-1-aa", name: "Blatt.pdf", size: 8, mime: "application/pdf", chdate: 10,
                                   downloadURL: "https://lw.test/pluginfile.php/1/mod_resource/content/1/Blatt.pdf", folder: nil)
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "0401 Testkurs", number: "0401", semester: nil), now: "2026-11-03T09:00:00")
            _ = try UniStore.storeFiles(c, courseID: "lw-1", [row], now: "2026-11-03T09:00:00", fileExists: { _ in false })
        }
        // der zweite Lauf beginnt, waehrend der erste seine Zwischendatei schreibt
        let stored = try await first.load(row, to: "files/lw-1-aa/Blatt.pdf", db: db, clock: clock) { part in
            try Data("%PDF".utf8).write(to: part)
            try second.begin()
            let handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("-1.7".utf8))
            try handle.close()
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(stored), encoding: .utf8), "%PDF-1.7", "Datei des ersten Laufs gespeichert")
        let path = try await db.scalar("SELECT local_path FROM files WHERE id='lw-1-aa'")?.string
        XCTAssertEqual(path, stored)

        // der zweite Lauf laeuft noch: das Ende des ersten laesst seinen Unterordner stehen
        try FileManager.default.createDirectory(at: second.partial, withIntermediateDirectories: true)
        first.end()
        XCTAssertFalse(UniDownloads.isRunning(in: folder, run: first.run))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.partial.path), "Unterordner des laufenden Laufs bleibt")
        second.end()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nach dem letzten Lauf ist .laden weg")
    }

    // MARK: P3-1 Suchform alter Seitentexte in Stuecken

    /// Alte Seitentexte ohne Suchform: das Nachtragen laeuft in kleinen Transaktionen; dazwischen kommen andere
    /// Anfragen an die Datenbank (vorher eine Transaktion ueber alle Zeilen, 5,3 s bei 10 000 Seiten)
    func testBackfillOfSearchFormsRunsInChunksAndLetsOtherRequestsThrough() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock, university: "luh")
        let total = 3000
        try await db.transaction { c in
            for i in 0..<total {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?, ?, ?, 0)",
                              [.text("f\(i / 10)"), .integer(Int64(i % 10 + 1)), .text("Übung \(i) Eigenwerte")])
            }
        }
        // Beobachter: fragt waehrend des Nachtragens immer wieder, wie viele Zeilen noch fehlen
        let observer = Task { () -> [Int] in
            var seen: [Int] = []
            while true {
                let n = try await db.scalar("SELECT COUNT(*) FROM page_texts WHERE search IS NULL")?.int ?? 0
                seen.append(n)
                if n == 0 || seen.count > 100_000 { return seen }
                await Task.yield()
            }
        }
        let filled = try await ScriptSearch.backfillSearchForms(db, chunk: 100)
        let seen = try await observer.value
        XCTAssertEqual(filled, total)
        XCTAssertTrue(seen.contains { $0 > 0 && $0 < total }, "andere Anfragen kamen zwischen den Stuecken dran: \(seen.prefix(20))")
        let left = try await db.scalar("SELECT COUNT(*) FROM page_texts WHERE search IS NULL")?.int
        XCTAssertEqual(left, 0)
        let one = try await db.scalar("SELECT search FROM page_texts WHERE file_id='f0' AND page=1")?.string
        XCTAssertEqual(one, ScriptSearch.searchForm("Übung 0 Eigenwerte"))
        let again = try await ScriptSearch.backfillSearchForms(db, chunk: 100)
        XCTAssertEqual(again, 0, "danach nichts mehr zu tun")
    }

    /// Die Suche findet Seiten alter Datenbanken weiter (Nachtragen vor der Suche, nicht mehr in ihrer Transaktion)
    func testSearchEndpointFindsOldPageTexts() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let db = backend.context.database
        try await db.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('k1', 'Testalgebra', 'vorlesung', 1, 't')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, local_path) VALUES ('f1', 'k1', 'VL01.pdf', 5, 'StudIP/files/VL01.pdf')")
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('f1', 1, 'Eigenwerte und Übungsaufgaben', 5)")
        }
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "übungsauf")]))
        XCTAssertEqual(r.status, 200, String(decoding: r.body.prefix(300), as: UTF8.self))
        let pages = try JSONValue.parse(r.body)["pages"]?.array ?? []
        XCTAssertEqual(pages.compactMap { $0["file_id"]?.string }, ["f1"])
        let left = try await db.scalar("SELECT COUNT(*) FROM page_texts WHERE search IS NULL")?.int
        XCTAssertEqual(left, 0)
    }

    // MARK: P3-2 WAL-Groesse

    /// Die Datenbank kuerzt ihre WAL-Datei nach einem Checkpoint auf hoechstens 8 MB (`journal_size_limit`)
    func testDatabaseLimitsTheWriteAheadLog() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("uniflow.db").path
        let db = try SQLiteDatabase(path: path)
        let limit = try await db.scalar("PRAGMA journal_size_limit")?.int
        XCTAssertEqual(limit, SQLiteConnection.journalSizeLimit)
        XCTAssertEqual(SQLiteConnection.journalSizeLimit, 8 * 1024 * 1024)
        func walSize() -> Int { (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue ?? 0 }
        // grosse Runde (rund 24 MB in der WAL) und Checkpoint ohne Kuerzen: die Datei bleibt so gross
        try await db.execute("CREATE TABLE t (b BLOB)")
        let blob = Data(repeating: 7, count: 1024 * 1024)
        try await db.transaction { c in for _ in 0..<24 { try c.execute("INSERT INTO t(b) VALUES (?)", [.blob(blob)]) } }
        _ = try await db.query("PRAGMA wal_checkpoint(PASSIVE)")
        XCTAssertGreaterThan(walSize(), 16 * 1024 * 1024, "Voraussetzung: grosse WAL nach der Runde")
        // der naechste Schreibzugriff beginnt die WAL von vorn und kuerzt sie auf die Grenze (ohne Grenze blieben 24 MB)
        try await db.execute("DELETE FROM t")
        XCTAssertLessThanOrEqual(walSize(), SQLiteConnection.journalSizeLimit, "WAL danach: \(walSize()) Bytes")
    }
}

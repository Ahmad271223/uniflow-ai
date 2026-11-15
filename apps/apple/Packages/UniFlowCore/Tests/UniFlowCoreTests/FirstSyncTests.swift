import Foundation
import XCTest
@testable import UniFlowCore

/// Erster Abgleich nach dem Verbinden (Auftrag des Inhabers 15.11.2026, docs/ERST-ABGLEICH-2026-11-15.md), gegen ein
/// nachgestelltes Learnweb (nie ein echter Abruf): Fortschritt wird gemeldet, die Dateilisten aller Kurse kommen vor
/// den Downloads, kleine und neue Dateien zuerst, 3 Downloads zugleich und nach 429 nur noch einer, Unterbrechung und
/// Fortsetzen ohne Neubeginn, fruehere Semester erst auf Wunsch, "Dateien werden noch geladen" je Modul, Antippen
/// laedt eine Datei einzeln.
final class FirstSyncTests: XCTestCase {
    let base = "https://www.uni-hildesheim.de/learnweb2026"
    let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })
    /// 5.11.2026: WiSe 2026/27 laeuft, SoSe 2026 ist vorbei
    let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var steps: [SyncProgress] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        func add(_ p: SyncProgress) { lock.lock(); steps.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        var progress: [SyncProgress] { lock.lock(); defer { lock.unlock() }; return steps }
        func clear() { lock.lock(); items.removeAll(); steps.removeAll(); lock.unlock() }
    }

    /// Verzoegert jede Anfrage wie ein echtes Netz und zaehlt, wie viele Downloads zugleich laufen
    final class PacedTransport: UniTransport, @unchecked Sendable {
        let inner: FakeUniTransport
        let nanos: UInt64
        private let lock = NSLock()
        private var inFlight = 0, newInFlight = 0, throttled = false
        private(set) var peak = 0
        /// hoechste Zahl zugleich laufender Downloads, die NACH der ersten 429-Antwort begannen
        private(set) var peakAfter429 = 0
        private(set) var finished = 0

        init(_ inner: FakeUniTransport, millis: UInt64 = 0) { self.inner = inner; nanos = millis * 1_000_000 }

        var stats: (peak: Int, peakAfter429: Int, finished: Int) { lock.withLock { (peak, peakAfter429, finished) } }

        func send(_ request: UniRequest) async throws -> UniResponse {
            if nanos > 0 { try await Task.sleep(nanoseconds: nanos) }
            return try await inner.send(request)
        }

        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
            let late = lock.withLock { () -> Bool in
                inFlight += 1
                peak = max(peak, inFlight)
                if throttled { newInFlight += 1; peakAfter429 = max(peakAfter429, newInFlight) }
                return throttled
            }
            defer { lock.withLock { inFlight -= 1; if late { newInFlight -= 1 } } }
            if nanos > 0 { try await Task.sleep(nanoseconds: nanos) }
            let r = try await inner.download(request, to: destination)
            lock.withLock { if r.status == 429 { throttled = true } else { finished += 1 } }
            return r
        }
    }

    private func container() async throws -> (SQLiteDatabase, DataContainerLayout) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.erfunden.0015", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        return (db, layout)
    }

    /// Learnweb mit `current` Kursen im laufenden Semester (Moodle-ID 101 …) und `older` Kursen im SoSe 2026 (201 …),
    /// je Kurs `files` Dateien. `size(kurs, datei)`: gemeldete Groesse; `tooMany`: der so vielte Download antwortet
    /// einmal mit 429.
    private func learnweb(current: Int, files: Int, older: Int = 0, log: Log, tooMany: Int? = nil,
                          size: @escaping @Sendable (Int, Int) -> Int = { _, j in 1000 * (j + 1) }) -> FakeUniTransport {
        let base = self.base
        let courses = (0..<current).map { (101 + $0, "WiSe 2026/27") } + (0..<older).map { (201 + $0, "SoSe 2026") }
        let downloads = Counter()
        return FakeUniTransport { req in
            let body = String(decoding: req.body ?? Data(), as: UTF8.self)
            if body.contains("wsfunction=core_webservice_get_site_info") { return okJSON(.object(["userid": .number(42)])) }
            if body.contains("wsfunction=core_enrol_get_users_courses") {
                return okJSON(.array(courses.map { id, term in
                    .object(["id": .number(Double(id)), "fullname": .string("\(term): 04\(id) Kurs \(id)"), "hidden": .number(0)])
                }))
            }
            if body.contains("wsfunction=core_course_get_contents"),
               let id = body.split(separator: "&").first(where: { $0.hasPrefix("courseid=") })?.split(separator: "=").last.flatMap({ Int($0) }) {
                log.add("files-\(id)")
                return okJSON(.array([.object(["id": .number(1), "name": .string("Unterlagen"), "modules": .array((0..<files).map { j in
                    .object(["id": .number(Double(id * 100 + j)), "modname": .string("resource"), "name": .string("Datei \(j)"),
                             "contents": .array([.object([
                                "type": .string("file"), "filename": .string("k\(id)-d\(j).pdf"), "filepath": .string("/"),
                                "filesize": .number(Double(size(id, j))), "mimetype": .string("application/pdf"),
                                "timemodified": .number(Double(1_790_000_000 + j * 1000)),
                                "fileurl": .string("\(base)/webservice/pluginfile.php/\(id * 100 + j)/mod_resource/content/1/k\(id)-d\(j).pdf")])])])
                })])]))
            }
            if req.url.absoluteString.contains("pluginfile.php") {
                let name = req.url.lastPathComponent
                if let tooMany, downloads.next() == tooMany {
                    log.add("429-\(name)")
                    return UniResponse(status: 429)
                }
                log.add("download-\(name)")
                return UniResponse(status: 200, headers: ["Content-Type": "application/pdf"], body: Data("%PDF-1.4 \(name)".utf8))
            }
            return okJSON(.array([]))
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
    }

    private func sync(_ db: SQLiteDatabase, _ layout: DataContainerLayout, _ t: UniTransport, log: Log, lanes: Int = DownloadPlan.lanes) -> HildesheimSync {
        HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(LearnwebToken("TOK")!), transport: t, retry: noWait),
                       lsf: nil, transport: t, clock: clock, retry: noWait, lanes: lanes, onProgress: { log.add($0) })
    }

    private func loaded(_ db: SQLiteDatabase) async throws -> Int {
        try await db.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL AND local_path <> ''")?.int ?? -1
    }

    // MARK: Fortschritt

    func testProgressIsReportedInPlainWords() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let r = await sync(db, layout, learnweb(current: 3, files: 4, log: log), log: log).run(includeGrades: false)
        XCTAssertTrue(r.ok, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.newFiles.count, 12)
        let steps = log.progress
        XCTAssertEqual(steps.first, SyncProgress(step: .lists, coursesTotal: 3), "beginnt mit den Dateilisten: \(steps.first.map { "\($0)" } ?? "-")")
        XCTAssertEqual(steps.first?.title, "Deine Kurse werden geladen: 0 von 3 Kursen")
        let lists = steps.filter { $0.step == .lists }
        XCTAssertEqual(lists.last?.coursesDone, 3)
        XCTAssertEqual(lists.last?.title, "Deine Kurse werden geladen: 3 von 3 Kursen · bisher 12 Dateien")
        let files = steps.filter { $0.step == .files }
        XCTAssertEqual(files.first?.title, "Deine Kurse werden geladen: 0 von 12 Dateien")
        XCTAssertEqual(files.map(\.filesDone).sorted(), Array(0...12), "jede Datei meldet sich: \(files.map(\.filesDone))")
        XCTAssertEqual(files.last?.title, "Deine Kurse werden geladen: 12 von 12 Dateien")
        XCTAssertEqual(files.last?.fraction, 1)
        XCTAssertTrue(files.allSatisfy { $0.detail?.hasPrefix("Gerade: ") == true && $0.detail?.contains("Kurs 10") == true }, "der Kurs, der gerade dran ist: \(files.map { $0.detail ?? "-" })")
        // ein zweiter Lauf ohne Neues meldet keine Downloads
        log.clear()
        _ = await sync(db, layout, learnweb(current: 3, files: 4, log: log), log: log).run(includeGrades: false)
        XCTAssertEqual(log.progress.last?.filesTotal, 0)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("download-") })
    }

    // MARK: Listen vor Downloads, Reihenfolge

    func testListsOfAllCoursesComeBeforeTheFirstDownload() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let r = await sync(db, layout, learnweb(current: 6, files: 3, log: log), log: log).run(includeGrades: false)
        XCTAssertEqual(r.newFiles.count, 18)
        let calls = log.all
        let firstDownload = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("download-") })
        let lists = calls.indices.filter { calls[$0].hasPrefix("files-") }
        XCTAssertEqual(lists.count, 6)
        XCTAssertTrue(lists.allSatisfy { $0 < firstDownload }, "alle Dateilisten vor dem ersten Download: \(calls)")
    }

    func testSmallAndNewFilesAreLoadedFirst() async throws {
        let (db, layout) = try await container()
        let log = Log()
        // Datei 0: 30 MB, Datei 1: klein und alt, Datei 2: klein und neu, Datei 3: 5 MB
        let sizes = [30 * 1024 * 1024, 1000, 1000, 5 * 1024 * 1024]
        let t = learnweb(current: 2, files: 4, log: log) { _, j in sizes[j] }
        _ = await sync(db, layout, t, log: log, lanes: 1).run(includeGrades: false)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("download-") }, [
            "download-k101-d2.pdf", "download-k102-d2.pdf", "download-k101-d1.pdf", "download-k102-d1.pdf",
            "download-k101-d3.pdf", "download-k102-d3.pdf", "download-k101-d0.pdf", "download-k102-d0.pdf",
        ])
    }

    /// Dieselben Faelle wie tests/test_sync_order.py (`download_order`)
    func testDownloadOrderMatchesPython() {
        struct F { let id: String; let stage: Int; let size: Int?; let changed: Int? }
        let files = [
            F(id: "alt-klein", stage: 2, size: 10, changed: 9), F(id: "gross", stage: 0, size: 50_000_000, changed: 9),
            F(id: "klein-alt", stage: 0, size: 2_000, changed: 1), F(id: "klein-neu", stage: 0, size: 2_000, changed: 5),
            F(id: "unbekannt", stage: 0, size: nil, changed: nil), F(id: "mittel", stage: 0, size: 3_000_000, changed: 2),
            F(id: "naechstes", stage: 1, size: 10, changed: 9), F(id: "null", stage: 0, size: 0, changed: 3),
        ]
        let order = DownloadPlan.order(files, stage: \.stage, size: \.size, changed: \.changed).map(\.id)
        XCTAssertEqual(order, ["klein-neu", "klein-alt", "null", "mittel", "unbekannt", "gross", "naechstes", "alt-klein"])
        XCTAssertEqual([nil, 0, 1, 2 * 1024 * 1024, 2 * 1024 * 1024 + 1, 20 * 1024 * 1024, 20 * 1024 * 1024 + 1].map(DownloadPlan.sizeClass), [1, 1, 0, 0, 1, 1, 2])
    }

    // MARK: Gleichzeitigkeit

    func testThreeDownloadsAtOnceAndOnlyOneAfter429() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let t = PacedTransport(learnweb(current: 4, files: 6, log: log, tooMany: 7), millis: 15)
        let s = sync(db, layout, t, log: log)
        let r = await s.run(includeGrades: false)
        XCTAssertTrue(r.ok, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.newFiles.count, 24, "auch die gebremste Datei kommt (ein weiterer Versuch): \(r.failedFiles)")
        XCTAssertEqual(r.failedFiles, [])
        XCTAssertEqual(t.stats.peak, 3, "vor der Bremse drei zugleich")
        XCTAssertEqual(t.stats.peakAfter429, 1, "nach 429 nur noch einer zugleich")
        let (slowed, limit) = await (s.downloadLanes.slowed, s.downloadLanes.limit)
        XCTAssertTrue(slowed)
        XCTAssertEqual(limit, 1)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("429-") }.count, 1, "keine Welle von 429")
    }

    /// Kennzahl fuer den Bericht: 14 Kurse mit je 10 Dateien (wie das Testkonto), jede Anfrage 15 ms
    func testThreeLanesAreFasterThanOneByOne() async throws {
        func measure(lanes: Int) async throws -> (seconds: Double, peak: Int) {
            let (db, layout) = try await container()
            let log = Log()
            let t = PacedTransport(learnweb(current: 14, files: 10, log: log), millis: 15)
            let start = Date()
            let r = await sync(db, layout, t, log: log, lanes: lanes).run(includeGrades: false)
            XCTAssertEqual(r.newFiles.count, 140)
            return (Date().timeIntervalSince(start), t.stats.peak)
        }
        let one = try await measure(lanes: 1), three = try await measure(lanes: 3)
        print(String(format: "ERST-ABGLEICH Messung (140 Dateien, 14 Kurse, 15 ms je Anfrage): nacheinander %.2f s, 3 zugleich %.2f s", one.seconds, three.seconds))
        XCTAssertEqual(one.peak, 1)
        XCTAssertEqual(three.peak, 3)
        XCTAssertLessThan(three.seconds, one.seconds * 0.7, "3 zugleich muss deutlich schneller sein")
    }

    // MARK: Unterbrechung und Fortsetzen

    func testInterruptedRunContinuesWithoutStartingOver() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let fake = learnweb(current: 5, files: 12, log: log)
        let t = PacedTransport(fake, millis: 10)
        let run = Task { await self.sync(db, layout, t, log: log).run(includeGrades: false) }
        let end = Date().addingTimeInterval(20)
        while t.stats.finished < 8, Date() < end { try await Task.sleep(nanoseconds: 2_000_000) }
        run.cancel()
        let r = await run.value
        XCTAssertTrue(r.cancelled)
        XCTAssertFalse(r.completed.contains("Learnweb"), "ein unterbrochener Lauf gilt nicht als fertig")
        let first = try await loaded(db)
        XCTAssertGreaterThanOrEqual(first, 8)
        XCTAssertLessThan(first, 60, "mitten in den Downloads unterbrochen")
        // die Listen aller Kurse stehen schon da: nichts sieht leer aus, und es ist klar, dass noch etwas fehlt
        let pending = try await db.withConnection { try SyncPending.overview($0) }
        XCTAssertEqual(pending.unlisted, 0)
        XCTAssertEqual(pending.waiting, 60 - first)
        XCTAssertFalse(r.notAttempted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UniDownloads.partial(in: layout.learnweb).path), "keine halben Dateien")

        // Fortsetzen: nur die fehlenden Dateien, keine geladene noch einmal
        log.clear()
        let r2 = await sync(db, layout, fake, log: log).run(includeGrades: false)
        XCTAssertTrue(r2.ok, r2.messages.joined(separator: "; "))
        XCTAssertEqual(r2.newFiles.count, 60 - first)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("download-") }.count, 60 - first)
        XCTAssertEqual(log.progress.last?.title, "Deine Kurse werden geladen: \(60 - first) von \(60 - first) Dateien")
        let all = try await loaded(db)
        XCTAssertEqual(all, 60)
        let after = try await db.withConnection { try SyncPending.overview($0) }
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: "Dateien werden noch geladen" und Antippen

    func testModulesKnowWhatIsStillComingAndATapLoadsOneFile() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let fake = learnweb(current: 2, files: 3, log: log)
        // Kurse bekannt, Listen noch nicht gelesen (so beginnt jeder erste Abgleich)
        try await db.transaction { c in
            for id in ["lw-101", "lw-102"] {
                try UniStore.upsertCourse(c, UniStore.CourseRow(id: id, title: "Kurs", number: nil, semester: "WiSe 2026/27"), now: "2026-11-05T10:00:00")
            }
        }
        let before = try await db.withConnection { try SyncPending.overview($0) }
        XCTAssertEqual(before.unlisted, 2)
        XCTAssertEqual(SyncPending.hint(unlisted: before.unlisted, waiting: before.waiting), "Dateien werden noch geladen …")

        // nur die Listen (wie nach einer Unterbrechung vor den Downloads): die Dateien stehen da und warten
        let s = sync(db, layout, fake, log: log)
        _ = await s.run(includeGrades: false, downloads: false)
        let listed = try await db.withConnection { try SyncPending.overview($0) }
        XCTAssertEqual(listed.unlisted, 0)
        XCTAssertEqual(listed.waiting, 6)
        XCTAssertEqual(listed.course("lw-101")?.waiting, 3)
        XCTAssertEqual(SyncPending.hint(unlisted: 0, waiting: 6), "6 Dateien werden noch geladen …")
        XCTAssertEqual(SyncPending.hint(unlisted: 0, waiting: 1), "1 Datei wird noch geladen …")
        XCTAssertNil(SyncPending.hint(unlisted: 0, waiting: 0))

        // Antippen laedt genau diese Datei
        let id = try await db.scalar("SELECT id FROM files WHERE course_id='lw-101' ORDER BY name LIMIT 1")?.string ?? ""
        log.clear()
        let one = await s.loadFile(id: id)
        XCTAssertEqual(one, .loaded)
        XCTAssertEqual(log.all, ["download-k101-d0.pdf"])
        let path = try await db.scalar("SELECT local_path FROM files WHERE id=?", [.text(id)])?.string ?? ""
        XCTAssertTrue(layout.files().exists(stored: path))
        let waiting = try await db.withConnection { try SyncPending.overview($0).waiting }
        XCTAssertEqual(waiting, 5)
        // noch einmal antippen laedt nichts doppelt; eine fremde Kennung ist keine Datei dieser Quelle
        let again = await s.loadFile(id: id)
        XCTAssertEqual(again, .loaded)
        XCTAssertEqual(log.all.count, 1)
        let unknown = await s.loadFile(id: "gibt-es-nicht")
        XCTAssertEqual(unknown, .unknown)
        // der volle Lauf holt den Rest
        let r = await s.run(includeGrades: false)
        XCTAssertEqual(r.newFiles.count, 5)
    }

    func testRefusedFileDoesNotCountAsStillLoading() async throws {
        let (db, layout) = try await container()
        let log = Log()
        _ = await sync(db, layout, learnweb(current: 1, files: 2, log: log), log: log).run(includeGrades: false, downloads: false)
        let id = try await db.scalar("SELECT id FROM files ORDER BY name LIMIT 1")?.string ?? ""
        try await db.transaction { try DownloadFailures.record($0, fileID: id, message: "gesperrt", status: 403, now: "2026-11-05T10:00:00") }
        let waiting = try await db.withConnection { try SyncPending.overview($0).waiting }
        XCTAssertEqual(waiting, 1, "eine verweigerte Datei haelt die Anzeige nicht fuer immer offen")
    }

    // MARK: Fruehere Semester

    func testOlderSemestersWaitForTheAnswerAndKeepIt() async throws {
        let (db, layout) = try await container()
        let log = Log()
        let fake = learnweb(current: 2, files: 2, older: 3, log: log)
        let r = await sync(db, layout, fake, log: log).run(includeGrades: false)
        XCTAssertTrue(r.ok, r.messages.joined(separator: "; "))
        XCTAssertEqual(r.newFiles.count, 4, "nur das laufende Semester")
        XCTAssertEqual(r.olderCourses.count, 3)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("files-20") }, "kein frueheres Semester vor der Antwort: \(log.all)")
        // das laufende Semester ist vollstaendig: nichts "wird noch geladen", obwohl fruehere Semester ohne Dateien sind
        let pending = try await db.withConnection { try SyncPending.overview($0) }
        XCTAssertTrue(pending.isEmpty, "fruehere Semester lassen den ersten Abgleich nicht unfertig aussehen")
        let ask = try await db.withConnection { try OlderSemesters.needsQuestion($0, today: self.clock.today) }
        XCTAssertTrue(ask, "die Frage kommt danach")

        // Antwort "Frühere Semester auch laden": bleibt gespeichert, Stufe (d) laedt mit eigenem Fortschritt
        try await db.transaction { try OlderSemesters.setMode($0, OlderSemesters.yesMode, now: "2026-11-05T10:05:00") }
        log.clear()
        let o = await sync(db, layout, fake, log: log).run(olderOnly: true)
        XCTAssertEqual(o.newFiles.count, 6)
        XCTAssertEqual(o.olderLoaded.count, 3)
        XCTAssertEqual(log.progress.last?.title, "Frühere Semester werden geladen: 6 von 6 Dateien")
        XCTAssertFalse(log.all.contains { $0.hasPrefix("files-10") }, "Stufe (d) fragt das laufende Semester nicht erneut ab")
        // ein weiterer voller Lauf aendert die Antwort nicht und fragt nicht erneut
        _ = await sync(db, layout, fake, log: log).run(includeGrades: false)
        let (mode, again) = try await db.withConnection { (try OlderSemesters.mode($0), try OlderSemesters.needsQuestion($0, today: self.clock.today)) }
        XCTAssertEqual(mode, OlderSemesters.yesMode)
        XCTAssertFalse(again)
    }
}

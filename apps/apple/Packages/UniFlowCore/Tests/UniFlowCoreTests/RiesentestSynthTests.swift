import Foundation
import XCTest
@testable import UniFlowCore

// Riesentest 03.11.2026 (docs/RIESENTEST-2026-11-03.md): der Kern-Abgleich gegen synthetische Hochschulen aus
// tools/lasttest-uni-synth.py. Je Konto eine Datei acc-NNNNN.json mit festen Antworten je Adresse; nichts hiervon ruft
// je ein Netz auf (die Transporte antworten nur aus der Datei). Der Ablauf ist der von StudIPSync.perform in der App
// (Kurse, Dateilisten, Downloads, Stundenplan, Ergaenzungen, Schwarzes Brett, Lerntexte, QIS) bzw. HildesheimSync.
//
// Laeuft nur mit Umgebung: RIESENTEST_DIR (Ordner der Konten), RIESENTEST_OUT (Ergebnis-JSON), optional
// RIESENTEST_LIMIT, RIESENTEST_PARALLEL (gleichzeitige Konten), RIESENTEST_SHARD "i/n", RIESENTEST_KEEP=1.
// Sonst uebersprungen (XCTSkip), damit `swift test` ohne Konten nicht wartet.

/// Antworten eines Kontos wie die Hochschule: Schluessel ist der dekodierte Pfad samt Abfrage (Stud.IP) bzw. die volle
/// Adresse (QIS, LSF, Learnweb), Learnweb-REST ueber "REST|<wsfunction>|<Schluessel>". Mit Zaehlern fuer 429/5xx
/// (erste Antworten) und einen Sitzungsablauf mitten im Lauf.
final class SynthWorld: @unchecked Sendable {
    struct Route {
        let status: Int
        let type: String
        let body: Data
        var flaky: [Int]
    }

    struct FileEntry {
        let serve: Int
        let kind: String
        let html: Bool
    }

    let account: JSONValue
    let expected: JSONValue
    private(set) var routes: [String: Route] = [:]
    private var filesByID: [String: FileEntry] = [:]
    private var filesByURL: [String: FileEntry] = [:]
    let expireAfter: Int?
    private let lock = NSLock()
    private(set) var requests = 0
    private(set) var log: [String] = []

    init(json: JSONValue) {
        account = json["account"] ?? .null
        expected = json["expected"] ?? .null
        expireAfter = account["expire_after"]?.int
        for (k, v) in json["routes"]?.object ?? [:] {
            let body: Data
            if let b = v["b64"]?.string { body = Data(base64Encoded: b) ?? Data() } else { body = Data((v["body"]?.string ?? "").utf8) }
            routes[k] = Route(status: v["status"]?.int ?? 200, type: v["type"]?.string ?? "application/vnd.api+json", body: body,
                              flaky: v["flaky"]?.array?.compactMap(\.int) ?? [])
        }
        for (k, v) in json["files"]?.object ?? [:] {
            let e = FileEntry(serve: v["serve"]?.int ?? 0, kind: v["kind"]?.string ?? "pdf", html: v["html"]?.bool ?? false)
            if k.hasPrefix("http") { filesByURL[k.removingPercentEncoding ?? k] = e } else { filesByID[k] = e }
        }
    }

    static func content(_ fid: String, _ n: Int, _ kind: String) -> Data {
        let head = Data((kind == "pdf" ? "%PDF-1.4\n% synth \(fid)\n" : "SYNTH \(kind) \(fid)\n").utf8)
        guard n > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(n + head.count)
        while out.count < n { out.append(head) }
        return out.prefix(n)
    }

    /// Schluessel einer Adresse: dekodiert, ohne den Stud.IP-Host
    static func key(_ url: URL) -> String {
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let host = "https://studip.synth.invalid"
        return s.hasPrefix(host) ? String(s.dropFirst(host.count)) : s
    }

    func reply(_ key: String) -> (status: Int, type: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        log.append(key)
        if let n = expireAfter, requests > n, key.hasPrefix("/jsonapi.php/") {
            return (401, "application/vnd.api+json", Data(#"{"errors":[{"status":"401"}]}"#.utf8))
        }
        if key.hasPrefix("/jsonapi.php/v1/file-refs/"), key.hasSuffix("/content") {
            let fid = String(key.dropFirst("/jsonapi.php/v1/file-refs/".count).dropLast("/content".count))
            return fileReply(fid, filesByID[fid])
        }
        guard var r = routes[key] else {
            let plain = key.split(separator: "?", maxSplits: 1).first.map(String.init) ?? key
            if let f = filesByURL[plain] { return fileReply(plain, f) }
            return (404, "text/plain", Data("nicht in der Nachbildung: \(key)".utf8))
        }
        if !r.flaky.isEmpty {
            let st = r.flaky.removeFirst()
            routes[key] = r
            return (st, "application/vnd.api+json", Data(#"{"errors":[{"status":"\#(st)"}]}"#.utf8))
        }
        return (r.status, r.type, r.body)
    }

    private func fileReply(_ id: String, _ f: FileEntry?) -> (Int, String, Data) {
        guard let f else { return (404, "text/plain", Data("keine Datei".utf8)) }
        if f.html { return (200, "text/html", Data("<!doctype html><html><body>Wartungsseite</body></html>".utf8)) }
        return (200, f.kind == "pdf" ? "application/pdf" : "application/octet-stream", Self.content(id, f.serve, f.kind))
    }

    /// Learnweb-REST: Funktion und erster Schluessel-Parameter aus dem Formular-Koerper
    func restReply(body: Data?) -> (status: Int, type: String, body: Data) {
        var fn = "", keyParam = ""
        for pair in String(decoding: body ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            guard kv.count == 2 else { continue }
            if kv[0] == "wsfunction" { fn = kv[1] }
            if keyParam.isEmpty, ["courseid", "forumid", "aftereventid"].contains(kv[0]) { keyParam = "\(kv[0])=\(kv[1])" }
        }
        lock.lock(); requests += 1; log.append("REST \(fn) \(keyParam)"); lock.unlock()
        let r = routes["REST|\(fn)|\(keyParam)"] ?? routes["REST|\(fn)|"]
        guard let r else {
            return (200, "application/json", Data(#"{"exception":"moodle_exception","errorcode":"unknown","message":"nicht in der Nachbildung: \#(fn)"}"#.utf8))
        }
        return (r.status, r.type, r.body)
    }
}

/// Stud.IP-Transport (JSON:API, Seiten, Downloads) aus der Welt
final class SynthStudIPTransport: StudIPTransport, @unchecked Sendable {
    let world: SynthWorld
    init(_ world: SynthWorld) { self.world = world }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let r = world.reply(SynthWorld.key(url))
        return HTTPReply(status: r.status, contentType: r.type, finalURL: url, body: r.body)
    }

    func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let r = world.reply(SynthWorld.key(url))
        try r.body.write(to: file)
        return HTTPReply(status: r.status, contentType: r.type, finalURL: url)
    }
}

/// Transport fuer QIS, LSF und Learnweb (REST per POST) aus der Welt
final class SynthUniTransport: UniTransport, @unchecked Sendable {
    let world: SynthWorld
    init(_ world: SynthWorld) { self.world = world }

    private func respond(_ request: UniRequest) -> UniResponse {
        let r: (status: Int, type: String, body: Data)
        if request.method == "POST", request.url.path.hasSuffix("/webservice/rest/server.php") {
            r = world.restReply(body: request.body)
        } else {
            r = world.reply(SynthWorld.key(request.url))
        }
        return UniResponse(status: r.status, headers: ["Content-Type": r.type], finalURL: request.url, body: r.body)
    }

    func send(_ request: UniRequest) async throws -> UniResponse { respond(request) }

    func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
        let r = respond(request)
        try r.body.write(to: destination)
        return UniResponse(status: r.status, headers: r.headers, finalURL: r.finalURL)
    }
}

final class RiesentestSynthTests: XCTestCase {
    static let clock = UniFlowClock.fixed(berlin: "2026-11-03T10:00:00")!
    static let studipBase = URL(string: "https://studip.synth.invalid")!
    static let budgetSeconds = 60.0

    func testSyntheticUniversities() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["RIESENTEST_DIR"], let out = env["RIESENTEST_OUT"] else { throw XCTSkip("RIESENTEST_DIR/RIESENTEST_OUT nicht gesetzt") }
        var files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("acc-") && $0.hasSuffix(".json") }.sorted()
        if let limit = env["RIESENTEST_LIMIT"].flatMap(Int.init), limit > 0 { files = Array(files.prefix(limit)) }
        if let shard = env["RIESENTEST_SHARD"]?.split(separator: "/"), shard.count == 2, let i = Int(shard[0]), let n = Int(shard[1]), n > 0 {
            files = files.enumerated().filter { $0.offset % n == i }.map(\.element)
        }
        let parallel = max(1, env["RIESENTEST_PARALLEL"].flatMap(Int.init) ?? 1)
        let keep = env["RIESENTEST_KEEP"] == "1"
        let started = Date()
        var results: [[String: Any]] = []
        var index = 0
        while index < files.count {
            let batch = Array(files[index..<min(files.count, index + parallel)])
            index += parallel
            let got = await withTaskGroup(of: [String: Any].self) { group in
                for name in batch {
                    group.addTask { await Self.runAccount(URL(fileURLWithPath: dir).appendingPathComponent(name), keep: keep) }
                }
                var list: [[String: Any]] = []
                for await r in group { list.append(r) }
                return list
            }
            results += got
            for r in got.sorted(by: { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }) {
                let bad = ((r["checks"] as? [String: [String: Any]]) ?? [:]).filter { ($0.value["ok"] as? Bool) == false }.keys.sorted()
                print("#\(r["index"] ?? 0) \(r["university"] ?? "") \(String(format: "%.2f", r["seconds"] as? Double ?? 0))s req=\(r["requests"] ?? 0) "
                      + "files=\(((r["counts"] as? [String: Any])?["files"]) ?? 0) " + ((r["ok"] as? Bool) == true ? "OK" : "FEHLER \(bad.joined(separator: ", ")) \((r["errors"] as? [String] ?? []).joined(separator: "; ").prefix(160))"))
            }
        }
        results.sort { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        let summary: [String: Any] = ["tool": "riesentest-swift-core", "accounts": results, "wall_seconds": Date().timeIntervalSince(started),
                                      "parallel": parallel, "max_rss_mb": Self.residentMB()]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        let crashed = results.filter { !(($0["errors"] as? [String]) ?? []).isEmpty }
        XCTAssertTrue(crashed.isEmpty, "Abstuerze: \(crashed.map { "\($0["index"] ?? 0): \(($0["errors"] as? [String] ?? []).first ?? "")" })")
        print("\(results.count) Konten, \(results.filter { ($0["ok"] as? Bool) == true }.count) ok, Wanduhr \(String(format: "%.1f", summary["wall_seconds"] as? Double ?? 0))s -> \(out)")
    }

    // MARK: Ein Konto

    static func runAccount(_ file: URL, keep: Bool) async -> [String: Any] {
        var result: [String: Any] = ["errors": [String](), "checks": [String: [String: Any]](), "counts": [String: Any](), "phases": [String: Double]()]
        let t0 = Date()
        var container: URL?
        do {
            let json = try JSONValue.parse(try Data(contentsOf: file))
            let world = SynthWorld(json: json)
            let a = world.account
            result["index"] = a["index"]?.int ?? 0
            result["university"] = a["university"]?.string ?? ""
            result["program"] = a["program"]?.string ?? ""
            result["flags"] = (a["flags"]?.object ?? [:]).keys.sorted()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("riesentest-\(a["index"]?.int ?? 0)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            container = dir
            if a["university"]?.string == "luh" {
                try await runLUH(world, dir: dir, result: &result)
            } else {
                try await runHildesheim(world, dir: dir, result: &result)
            }
            result["requests"] = world.requests
        } catch {
            var errors = result["errors"] as? [String] ?? []
            errors.append("\(error)".prefix(500).description)
            result["errors"] = errors
        }
        result["seconds"] = Date().timeIntervalSince(t0)
        result["within_budget"] = (result["seconds"] as? Double ?? 0) <= budgetSeconds
        let checks = result["checks"] as? [String: [String: Any]] ?? [:]
        result["ok"] = (result["errors"] as? [String] ?? []).isEmpty && checks.values.allSatisfy { ($0["ok"] as? Bool) == true } && (result["locked"] as? Int ?? 0) == 0
        if !keep, let container { try? FileManager.default.removeItem(at: container) }
        return result
    }

    /// Ablauf wie StudIPSync.perform in der App (ohne Oberflaeche, ohne Aufzeichnungen)
    static func runLUH(_ world: SynthWorld, dir: URL, result: inout [String: Any]) async throws {
        var phases: [String: Double] = [:]
        func phase(_ name: String, _ t: Date) { phases[name, default: 0] += Date().timeIntervalSince(t) }
        let transport = SynthStudIPTransport(world)
        let client = StudIPClient(base: studipBase, transport: transport, pauseMillis: 0, maxRequests: 1_000_000, retry: UniRetry(attempts: 3, delayNanos: { _ in 0 }))
        let files = LocalFiles(container: dir, dataDirectory: "")
        let backend = try await LocalBackend.open(path: dir.appendingPathComponent("uniflow.sqlite").path, clock: clock, files: files, university: "luh")
        let db = backend.context.database
        let downloads = UniDownloads(folder: dir.appendingPathComponent("StudIP", isDirectory: true), files: files, container: nil, source: "Stud.IP")
        try downloads.begin()
        defer { downloads.end() }
        let started = clock.nowISO, today = clock.today
        var loaded = 0, failed = 0, unreadable = 0, skippedFolders = 0
        var sessionExpired = false
        var chosen: [StudIPCourse] = []
        var checked = Set<String>(), partial = Set<String>()
        var remote: [StudIPFile] = []
        do {
            var t = Date()
            let uid = try await client.currentUserID()
            let list = try await client.courses(userID: uid)
            phase("courses", t)
            let courses = list.sorted { ($0.semesterStart ?? "", $0.title) > ($1.semesterStart ?? "", $1.title) }
            let selection = StudIPImport.selection(courses: list, selected: [], known: nil, today: today)
            let selectedNow = courses.filter { selection.selected.contains($0.id) }
            let olderUnselected = courses.filter {
                !selection.selected.contains($0.id) && Semesters.isCurrent(semester: $0.semesterTitle, semesterEnd: $0.semesterEnd, endsAt: $0.semesterEndsAt, today: today) == false
            }
            t = Date()
            let (active, wantedOlder) = try await db.transaction { c -> (Set<String>, Set<String>) in
                try StudIPLibrary.storeCourses(c, selectedNow + olderUnselected, startedAt: started, today: today)
                return (Set(try c.rows("SELECT id FROM courses WHERE active=1").compactMap { $0["id"]?.string }), try OlderSemesters.pending(c, today: today))
            }
            phase("store_courses", t)
            chosen = selectedNow.filter { active.contains($0.id) }
            let olderFiles = courses.filter { wantedOlder.contains($0.id) && !active.contains($0.id) }
            let fileCourses = chosen + olderFiles
            var wanted: [StudIPFile] = []
            t = Date()
            for c in fileCourses {
                let listing: StudIPFileListing
                do {
                    listing = try await client.fileListing(courseID: c.id)
                } catch let e as StudIPError where e.affectsOnlyItem {
                    unreadable += 1
                    continue
                }
                skippedFolders += listing.unreadableFolders
                if listing.unreadableFolders > 0 { partial.insert(c.id) }
                remote += listing.files
                checked.insert(c.id)
                let complete = !partial.contains(c.id)
                let fs = listing.files
                wanted += try await db.transaction {
                    try StudIPLibrary.storeLinks($0, courseID: c.id, fs, complete: complete, now: started)
                    return try StudIPLibrary.storeFiles($0, fs, startedAt: started, base: studipBase, localFiles: files)
                }
            }
            phase("file_lists", t)
            if unreadable > 0, unreadable == fileCourses.count { throw StudIPError.badResponse("kein Kurs lesbar") }
            t = Date()
            // wie StudIPSync.perform: Videos in Kursordnern laedt das iPad nicht von selbst (Aufzeichnungen, auf Wunsch)
            for f in wanted where f.isDownloadable && !OpencastFileVideos.isVideo(f) {
                let rel = StudIPImport.relativePath(for: f)
                do {
                    try await downloads.load(StudIPLibrary.fileRow(f, base: studipBase), to: rel, db: db, clock: clock) { part in
                        try await client.download(fileID: f.id, to: part, name: f.name)
                    }
                    loaded += 1
                } catch let e as StudIPError where e.affectsOnlyItem {
                    failed += 1
                } catch is UniDownloads.Failure {
                    failed += 1
                }
            }
            phase("downloads", t)
            t = Date()
            let sched = await StudIPScheduleStore.fetch(client: client, userID: uid, courses: chosen)
            let schedResult = try await db.transaction { try StudIPScheduleStore.store(sched, in: $0, clock: clock) }
            phase("timetable", t)
            result["timetable"] = ["new": schedResult.newEvents, "pending_groups": schedResult.pendingGroups, "cycles": schedResult.cycles,
                                   "events": schedResult.events, "removed": schedResult.removedEvents, "open_questions": schedResult.openQuestions,
                                   "session_expired": sched.sessionExpired, "schedule_error": sched.scheduleError ?? "", "calendar_error": sched.calendarError ?? "",
                                   "failed_courses": sched.failedCourses.count]
            if sched.sessionExpired { throw StudIPError.sessionExpired }
            t = Date()
            let missing = try await db.withConnection { try StudIPExtras.loadMissing($0) }
            let extras = await StudIPExtras.fetch(client: client, userID: uid, missing: missing, clock: clock)
            try await db.transaction { try StudIPExtras.store(extras, in: $0, clock: clock) }
            if extras.sessionExpired { throw StudIPError.sessionExpired }
            let missing2 = try await db.withConnection { try StudIPExtras.loadMissing($0) }
            let last = try await db.withConnection { try StudIPBulletin.lastFetchedAt($0) }
            let bd = await StudIPBulletin.fetch(client: client, missing: missing2, lastFetchedAt: last, clock: clock)
            if !bd.skipped { try await db.transaction { try StudIPBulletin.store(bd, in: $0, clock: clock) } }
            if bd.sessionExpired { throw StudIPError.sessionExpired }
            phase("extras", t)
            t = Date()
            let known = try await db.withConnection { try StudIPTexts.load($0) }
            let td = try await StudIPTexts.fetch(client: client, courses: chosen, known: known.known, state: known.state, today: today, base: studipBase.absoluteString)
            let now = clock.nowISO
            let tr = try await db.transaction { try StudIPTexts.store($0, td, now: now) }
            phase("texts", t)
            result["texts_result"] = ["texts": tr.texts, "deadlines": tr.deadlines, "stopped": td.stopped]
        } catch StudIPError.sessionExpired {
            sessionExpired = true
        }
        let finished = clock.nowISO, n = loaded, ok = !sessionExpired
        let message = sessionExpired ? StudIPLibrary.failure(StudIPError.sessionExpired.description) : StudIPLibrary.summary(newFiles: loaded)
        try await db.transaction { try UniStore.logSync($0, startedAt: started, finishedAt: finished, ok: ok, newFiles: n, message: message) }
        // QIS wie QISConnection in der App (eigener Transport, dieselbe Datenbank)
        var t = Date()
        let qis = await QISGradesSync.run(db: db, transport: SynthUniTransport(world), clock: clock, retry: .none)
        phase("qis", t)
        result["qis"] = ["grades": qis.grades ?? -1, "message": qis.message, "needs_login": qis.needsLogin]
        // Module wie beim naechsten Lesen der App (ensure_modules in /api/modules)
        t = Date()
        let modules = await backend.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules")!))
        phase("ensure_modules", t)
        result["phases"] = phases
        result["sync"] = ["ok": ok, "message": message, "loaded": loaded, "failed": failed, "unreadable_courses": unreadable, "skipped_folders": skippedFolders,
                          "remote": remote.count, "checked": checked.count, "partial": partial.count, "session_expired": sessionExpired, "modules_status": modules.status]
        try await verify(world, db: db, container: dir, result: &result, sessionExpired: sessionExpired, swiftTransientCourses: nil)
    }

    /// Ablauf wie HildesheimConnection in der App: HildesheimSync mit Learnweb-Schluessel und LSF
    static func runHildesheim(_ world: SynthWorld, dir: URL, result: inout [String: Any]) async throws {
        let a = world.account
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.synth.\(a["index"]?.int ?? 0)", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        let transport = SynthUniTransport(world)
        guard let token = LearnwebToken(a["token"]?.string ?? "") else { throw HildesheimError.invalidToken }
        let api = LearnwebAPI(base: a["learnweb_base"]?.string ?? "", mode: .token(token), transport: transport, retry: .none)
        let lsf = LSFClient(transport: transport, retry: .none)
        let sync = HildesheimSync(db: db, container: layout, learnweb: api, lsf: lsf, transport: transport, clock: clock, retry: .none)
        let t = Date()
        let report = await sync.run()
        result["phases"] = ["hildesheim": Date().timeIntervalSince(t)]
        result["sync"] = ["ok": report.ok, "message": report.messages.joined(separator: ", "), "courses": report.courses, "new_files": report.newFiles.count,
                          "failed_files": report.failedFiles.count, "failed_courses": report.failedCourses, "needs_login": report.needsLogin,
                          "plan_new": report.plan?.new ?? -1, "plan_cancelled": report.plan?.cancelledDates ?? -1, "grades": report.grades ?? -1,
                          "deadlines": report.deadlines?.total ?? -1, "announcements": report.announcements?.new ?? -1, "completed": report.completed]
        try await db.transaction { try LocalModules.ensureModules($0, clock: clock) }
        try await verify(world, db: db, container: layout.root, result: &result, sessionExpired: !report.needsLogin.isEmpty, swiftTransientCourses: nil)
    }

    // MARK: Pruefung (dieselben Punkte wie tools/riesentest-python.py)

    static func verify(_ world: SynthWorld, db: SQLiteDatabase, container: URL, result: inout [String: Any], sessionExpired: Bool,
                       swiftTransientCourses: Set<String>?) async throws {
        let e = world.expected
        let uni = world.account["university"]?.string ?? "luh"
        let strict = (e["strict"]?.bool ?? true) && !sessionExpired
        var checks = result["checks"] as? [String: [String: Any]] ?? [:]
        var counts = result["counts"] as? [String: Any] ?? [:]
        func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
            var c: [String: Any] = ["ok": ok]
            if let detail { c["detail"] = detail }
            checks[name] = c
        }
        let courseRows = try await db.withConnection { try $0.rows("SELECT id, title, subject, kind, active, module_id FROM courses WHERE id != '__user__'") }
        var courses: [String: [String: JSONValue]] = [:]
        for r in courseRows { if let id = r["id"]?.string { courses[id] = r } }
        let moduleRows = try await db.withConnection { try $0.rows("SELECT id, name FROM modules") }
        var modules: [Int: String] = [:]
        for r in moduleRows { if let id = r["id"]?.int, let n = r["name"]?.string { modules[id] = n } }
        let fileRows = try await db.withConnection { try $0.rows("SELECT id, course_id, local_path, studip_folder, size FROM files WHERE course_id != '__user__'") }
        var files: [String: [String: JSONValue]] = [:]
        for r in fileRows { if let id = r["id"]?.string { files[id] = r } }
        counts["courses"] = courses.count
        counts["modules"] = modules.count
        counts["files"] = files.count
        counts["downloaded"] = files.values.filter { ($0["local_path"]?.string ?? "").isEmpty == false }.count

        // Kurse und Einordnung
        let expectedCourses = (e["courses_expected"]?.array ?? []).filter { c in
            uni == "luh" || (c["kind"]?.string != "sonstiges" && c["hidden"]?.bool != true)
        }
        // Swift (erster Abgleich): nur Kurse des juengsten Semesters und ohne Semester (StudIPImport.selection); aeltere
        // Semester kommen als inaktive Kurse mit, Kurse ohne Startsemester seit dem Riesentest ebenfalls
        let missingCourses = expectedCourses.filter { courses[$0["db_id"]?.string ?? ""] == nil }.map { $0["db_id"]?.string ?? "" }
        check("courses_present", missingCourses.isEmpty, Array(missingCourses.prefix(5)))
        var misses: [[String: Any]] = []
        for c in expectedCourses {
            guard let row = courses[c["db_id"]?.string ?? ""], let subject = c["subject"]?.string, !subject.isEmpty else { continue }
            if (row["subject"]?.string ?? "") != subject || (row["kind"]?.string ?? "") != (c["kind"]?.string ?? "") {
                misses.append(["title": c["title"]?.string ?? "", "subject": row["subject"]?.string ?? "", "kind": row["kind"]?.string ?? "",
                               "expected": [subject, c["kind"]?.string ?? ""]])
            }
        }
        counts["classify_misses"] = misses.count
        check("classification", misses.isEmpty, Array(misses.prefix(8)))
        let names = modules.values.sorted()
        let dupModules = Set(names.filter { n in names.filter { $0 == n }.count > 1 })
        check("modules_unique", dupModules.isEmpty, Array(dupModules))
        var wrongModule: [String] = []
        for c in expectedCourses {
            guard let id = c["db_id"]?.string, let row = courses[id], (row["active"]?.int ?? 1) == 1, row["kind"]?.string != "sonstiges",
                  let subject = row["subject"]?.string, !subject.isEmpty else { continue }
            if let m = row["module_id"]?.int, modules[m] == subject { continue }
            wrongModule.append(id)
        }
        check("course_has_module", wrongModule.isEmpty, Array(wrongModule.prefix(5)))
        counts["module_names"] = Array(Set(names)).sorted()
        let expectedModules = e["module_count"]?.int ?? 0
        check("module_count", Set(names).count == expectedModules, ["got": Set(names).count, "expected": expectedModules])

        // Dateien: Erwartung des Kerns = Python-Erwartung ohne Kurse mit Transportfehler (429/503/kaputtes JSON: der
        // ganze Kurs wird uebersprungen) und ohne Dateien tiefer als 6 Ebenen (StudIPClient.walk). Beides wird gezaehlt.
        let transientCourses = Set(expectedCourses.filter { $0["bad_folder"]?.string != nil }.compactMap { $0["db_id"]?.string })
        let meta = e["files_meta"]?.object ?? [:]
        let expectedAll = Set(e["files_expected"]?.array?.compactMap(\.string) ?? [])
        let deep = Set(e["files_deep"]?.array?.compactMap(\.string) ?? [])
        let skippedByCourse = Set(expectedAll.filter { transientCourses.contains(meta[$0]?["course"]?.string ?? "") })
        let expectedSwift = expectedAll.subtracting(deep).subtracting(skippedByCourse)
        let present = Set(files.keys)
        let missing = expectedSwift.subtracting(present).sorted()
        let extra = present.subtracting(expectedAll).subtracting(Set(e["files_inactive"]?.array?.compactMap(\.string) ?? [])).sorted()
        let forbidden = present.intersection(Set(e["files_forbidden"]?.array?.compactMap(\.string) ?? [])).sorted()
        counts["files_expected"] = expectedSwift.count
        counts["files_missing"] = missing.count
        counts["files_extra"] = extra.count
        counts["files_deep_skipped"] = deep.count
        counts["files_transient_skipped"] = skippedByCourse.count
        check("files_complete", strict ? missing.isEmpty : true, ["missing": Array(missing.prefix(5)), "strict": strict])
        check("no_forbidden_files", forbidden.isEmpty, Array(forbidden.prefix(5)))
        check("no_extra_files", extra.isEmpty, Array(extra.prefix(5)))
        // Videos (mp4 usw.) laedt das iPad nicht von selbst (OpencastFileVideos, Aufzeichnungen auf Wunsch): nicht erwartet
        let videos = Set(expectedSwift.filter { OpencastFileVideos.isVideo(name: meta[$0]?["name"]?.string ?? "", mime: nil) })
        let downloadable = Set(e["files_downloadable"]?.array?.compactMap(\.string) ?? []).intersection(expectedSwift).subtracting(videos)
        counts["videos_not_auto"] = videos.count
        let notLoaded = downloadable.filter { files[$0] != nil && (files[$0]?["local_path"]?.string ?? "").isEmpty }.sorted()
        var gone: [String] = []
        for (id, r) in files {
            guard let p = r["local_path"]?.string, !p.isEmpty else { continue }
            if !FileManager.default.fileExists(atPath: container.appendingPathComponent(p).path) { gone.append(id) }
        }
        counts["downloads_expected"] = downloadable.count
        counts["downloads_missing"] = notLoaded.count
        counts["downloads_file_gone"] = gone.count
        check("downloads_complete", strict ? notLoaded.isEmpty : true, ["missing": Array(notLoaded.prefix(5))])
        check("downloads_on_disk", gone.isEmpty, Array(gone.prefix(5)))
        let wrongCourse = files.filter { id, r in meta[id] != nil && r["course_id"]?.string != meta[id]?["course"]?.string }.keys.sorted()
        check("files_in_right_course", wrongCourse.isEmpty, Array(wrongCourse.prefix(5)))

        // Stundenplan
        let series = try await db.withConnection { try $0.rows("SELECT id, course_id, title, weekday, start_time, end_time, rrule, source FROM course_events") }
        let dups = try await db.withConnection {
            try $0.rows("SELECT course_id, title, weekday, start_time, end_time, COUNT(*) n FROM course_events WHERE rrule != 'once' GROUP BY course_id, title, weekday, start_time, end_time HAVING n > 1")
        }
        check("timetable_no_duplicates", dups.isEmpty, dups.prefix(5).map { $0.mapValues { $0.jsonString() } })
        let weekly = series.filter { $0["rrule"]?.string != "once" }
        counts["series_weekly"] = weekly.count
        counts["series_once"] = series.count - weekly.count
        counts["series_personal"] = series.filter { $0["course_id"]?.string == nil }.count
        let inactiveSeries = series.filter { s in
            guard let cid = s["course_id"]?.string, let c = courses[cid] else { return false }
            return (c["active"]?.int ?? 1) == 0
        }.compactMap { $0["id"]?.int }
        check("timetable_only_active_courses", inactiveSeries.isEmpty, Array(inactiveSeries.prefix(5)))
        let exc = try await db.withConnection { try $0.rows("SELECT type, note, COUNT(*) n FROM event_exceptions GROUP BY type, note") }
        var excMap: [String: Int] = [:]
        for r in exc { excMap["\(r["type"]?.string ?? "")|\(r["note"]?.string ?? "")"] = r["n"]?.int ?? 0 }
        counts["exceptions"] = excMap

        if uni == "luh" {
            let expectedWeekly = (e["series_own_device"]?.int ?? e["series_own"]?.int ?? 0) + (e["personal"]?.int ?? 0)
            counts["series_expected"] = expectedWeekly
            check("timetable_series_count", strict ? weekly.count == expectedWeekly : true, ["got": weekly.count, "expected": expectedWeekly])
            let ev = try await db.withConnection { try $0.rows("SELECT COUNT(*) n, SUM(COALESCE(cancelled,0)) c FROM studip_events") }.first
            let n = ev?["n"]?.int ?? 0, cancelled = ev?["c"]?.int ?? 0
            counts["studip_events"] = n
            counts["cancelled"] = cancelled
            check("events_complete", strict ? n == (e["events_active"]?.int ?? 0) : true, ["got": n, "expected": e["events_active"]?.int ?? 0])
            check("cancellations_detected", strict ? cancelled == (e["cancelled_events"]?.int ?? 0) : true, ["got": cancelled, "expected": e["cancelled_events"]?.int ?? 0])
            let annRows = try await db.withConnection { try $0.rows("SELECT id, dates FROM announcements WHERE source='studip'") }
            var ann: [String: [JSONValue]] = [:]
            for r in annRows { if let id = r["id"]?.string { ann[id] = (r["dates"]?.string).flatMap { try? JSONValue.parse($0) }?.array ?? [] } }
            var found = 0
            var miss: [[String: Any]] = []
            for d in e["deadlines_news"]?.array ?? [] {
                let id = d["news"]?.string ?? ""
                guard let dates = ann[id] else { miss.append(["news": id, "why": "fehlt"]); continue }
                if dates.contains(where: { $0["date"]?.string == d["date"]?.string && $0["kind"]?.string == d["kind"]?.string }) { found += 1 } else {
                    miss.append(["news": id, "expected": [d["date"]?.string ?? "", d["kind"]?.string ?? ""], "got": dates.map { [$0["date"]?.string ?? "", $0["kind"]?.string ?? ""] }])
                }
            }
            counts["deadlines_news_expected"] = e["deadlines_news"]?.array?.count ?? 0
            counts["deadlines_news_found"] = found
            counts["announcements"] = ann.count
            check("deadlines_in_news", strict ? miss.isEmpty : true, Array(miss.prefix(5)))
            let dl = Set(try await db.withConnection { try $0.rows("SELECT id FROM deadlines WHERE source='studip'") }.compactMap { $0["id"]?.string })
            let cw = (e["cw_deadlines"]?.array ?? []).compactMap { $0["id"]?.string }
            counts["cw_deadlines_expected"] = cw.count
            counts["cw_deadlines_found"] = cw.filter { dl.contains($0) }.count
            let few = (e["courses_active"]?.int ?? 0) <= 12
            check("courseware_deadlines", (strict && few) ? cw.allSatisfy { dl.contains($0) } : true, ["missing": Array(cw.filter { !dl.contains($0) }.prefix(5)), "checked": strict && few])
            let hasTexts = try await db.scalar("SELECT 1 FROM sqlite_master WHERE name='studip_texts'") != nil
            var texts: [String: Int] = [:]
            if hasTexts { for r in try await db.withConnection({ try $0.rows("SELECT kind, COUNT(*) n FROM studip_texts GROUP BY kind") }) { texts[r["kind"]?.string ?? ""] = r["n"]?.int ?? 0 } }
            counts["texts"] = texts
            let hasPeriods = try await db.scalar("SELECT 1 FROM sqlite_master WHERE name='studip_periods'") != nil
            let semesters = hasPeriods ? (try await db.scalar("SELECT COUNT(*) FROM studip_periods WHERE kind='semester'")?.int ?? 0) : 0
            let hasMsgs = try await db.scalar("SELECT 1 FROM sqlite_master WHERE name='studip_messages'") != nil
            let msgs = hasMsgs ? (try await db.scalar("SELECT COUNT(*) FROM studip_messages")?.int ?? 0) : 0
            counts["semesters"] = semesters
            counts["messages"] = msgs
            let ex = e["extras"]
            check("extras", strict ? (semesters == (ex?["semesters"]?.int ?? 0) && msgs == (ex?["messages"]?.int ?? 0)) : true, ["got": [semesters, msgs], "expected": [ex?["semesters"]?.int ?? 0, ex?["messages"]?.int ?? 0]])
            let hasBulletin = try await db.scalar("SELECT 1 FROM sqlite_master WHERE name='studip_bulletin'") != nil
            let bulletin = hasBulletin ? (try await db.scalar("SELECT COUNT(*) FROM studip_bulletin")?.int ?? 0) : 0
            counts["bulletin"] = bulletin
            check("bulletin", strict ? bulletin == (e["bulletin"]?.int ?? 0) : true, ["got": bulletin, "expected": e["bulletin"]?.int ?? 0])
            let grades = try await db.withConnection { try $0.rows("SELECT pruefungsnr, text FROM grades") }
            let got = Set(grades.map { "\($0["pruefungsnr"]?.string ?? "")|\($0["text"]?.string ?? "")" })
            let exp = Set((e["grades"]?.array ?? []).map { "\($0["pruefungsnr"]?.string ?? "")|\($0["text"]?.string ?? "")" })
            counts["grades"] = got.count
            check("qis_grades", got == exp, ["got": got.count, "expected": exp.count])
        } else {
            let dl = try await db.withConnection { try $0.rows("SELECT id, kind FROM deadlines WHERE source='learnweb'") }
            var dlMap: [String: String] = [:]
            for r in dl { dlMap[r["id"]?.string ?? ""] = r["kind"]?.string ?? "" }
            let exp = (e["learnweb_deadlines"]?.array ?? []).compactMap { $0["id"]?.string }
            counts["deadlines_expected"] = exp.count
            counts["deadlines_found"] = exp.filter { dlMap[$0] != nil }.count
            check("learnweb_deadlines", exp.allSatisfy { dlMap[$0] == "abgabe" }, Array(exp.filter { dlMap[$0] == nil }.prefix(5)))
            let annRows = try await db.withConnection { try $0.rows("SELECT id, dates FROM announcements WHERE source='learnweb'") }
            var ann: [String: [JSONValue]] = [:]
            for r in annRows { if let id = r["id"]?.string { ann[id] = (r["dates"]?.string).flatMap { try? JSONValue.parse($0) }?.array ?? [] } }
            let miss = (e["learnweb_announcements"]?.array ?? []).filter { a in
                guard let dates = ann[a["id"]?.string ?? ""] else { return true }
                return !dates.contains { $0["date"]?.string == a["date"]?.string && $0["kind"]?.string == a["kind"]?.string }
            }.compactMap { $0["id"]?.string }
            counts["announcements"] = ann.count
            counts["announcements_expected"] = e["learnweb_announcements"]?.array?.count ?? 0
            check("learnweb_announcements", miss.isEmpty, Array(miss.prefix(5)))
            let lsf = series.filter { $0["source"]?.string == "lsf" }
            counts["lsf_series"] = lsf.count
            counts["lsf_expected"] = e["lsf_series"]?.int ?? 0
            check("lsf_series_count", lsf.count == (e["lsf_series"]?.int ?? 0), ["got": lsf.count, "expected": e["lsf_series"]?.int ?? 0])
            let cancelled = try await db.scalar("SELECT COUNT(*) FROM event_exceptions WHERE note='fällt aus laut LSF'")?.int ?? 0
            counts["lsf_cancelled"] = cancelled
            check("lsf_cancellations", cancelled == (e["lsf_cancelled"]?.int ?? 0), ["got": cancelled, "expected": e["lsf_cancelled"]?.int ?? 0])
            let grades = try await db.withConnection { try $0.rows("SELECT pruefungsnr, text FROM grades") }
            let got = Set(grades.map { "\($0["pruefungsnr"]?.string ?? "")|\($0["text"]?.string ?? "")" })
            let exp2 = Set((e["grades"]?.array ?? []).map { "\($0["pruefungsnr"]?.string ?? "")|\($0["text"]?.string ?? "")" })
            counts["grades"] = got.count
            check("lsf_grades", got == exp2, ["got": got.count, "expected": exp2.count])
        }
        let log = try await db.withConnection { try $0.rows("SELECT ok, message FROM sync_log ORDER BY id DESC LIMIT 1") }.first
        result["sync_log"] = ["ok": log?["ok"]?.int ?? -1, "message": log?["message"]?.string ?? ""]
        // HildesheimSync meldet einen Lauf mit einem unlesbaren Learnweb-Kurs als nicht ok (Report.ok), der PC-Abgleich
        // protokolliert ihn als ok und nennt den Kurs nur im Protokoll: hier gilt der Lauf mit erwarteten Kursfehlern
        let expectedCourseErrors = expectedCourses.contains { $0["lw_error"]?.bool == true }
        check("sync_ok", log != nil && ((log?["ok"]?.int ?? 0) == 1 || !strict || expectedCourseErrors), result["sync_log"])
        result["checks"] = checks
        result["counts"] = counts
        result["locked"] = 0
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

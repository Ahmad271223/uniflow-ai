import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

// Riesentest 03.11.2026 (docs/RIESENTEST-2026-11-03.md), App-Schicht: der echte `StudIPSync` des Containers
// (ContainerManager wie in der App) gegen synthetische Stud.IP-Konten aus tools/lasttest-uni-synth.py, feste Antworten
// aus der Konto-Datei, nie ein Netz. Dieselben Pruefpunkte wie RiesentestSynthTests im Kern (Kurse, Einordnung,
// Module, Dateien, Downloads, Stundenplan, Ausfaelle, Fristen). Laeuft nur mit TEST_RUNNER_RIESENTEST_DIR (xcodebuild
// reicht TEST_RUNNER_-Variablen in den Testprozess); sonst uebersprungen.

/// Antworten eines Kontos (Kopie des Kerns, Stud.IP-Teil; die App fragt unter der echten LUH-Adresse, der Transport
/// faengt sie ab)
private final class SynthAppWorld: @unchecked Sendable {
    struct Route { let status: Int; let type: String; let body: Data; var flaky: [Int] }
    struct FileEntry { let serve: Int; let kind: String; let html: Bool }

    let account: JSONValue
    let expected: JSONValue
    private var routes: [String: Route] = [:]
    private var filesByID: [String: FileEntry] = [:]
    let expireAfter: Int?
    private let lock = NSLock()
    private(set) var requests = 0

    init(json: JSONValue) {
        account = json["account"] ?? .null
        expected = json["expected"] ?? .null
        expireAfter = account["expire_after"]?.int
        for (k, v) in json["routes"]?.object ?? [:] where !k.hasPrefix("REST|") {
            let body: Data
            if let b = v["b64"]?.string { body = Data(base64Encoded: b) ?? Data() } else { body = Data((v["body"]?.string ?? "").utf8) }
            routes[k] = Route(status: v["status"]?.int ?? 200, type: v["type"]?.string ?? "application/vnd.api+json", body: body,
                              flaky: v["flaky"]?.array?.compactMap(\.int) ?? [])
        }
        for (k, v) in json["files"]?.object ?? [:] where !k.hasPrefix("http") {
            filesByID[k] = FileEntry(serve: v["serve"]?.int ?? 0, kind: v["kind"]?.string ?? "pdf", html: v["html"]?.bool ?? false)
        }
    }

    static func content(_ fid: String, _ n: Int, _ kind: String) -> Data {
        let head = Data((kind == "pdf" ? "%PDF-1.4\n% synth \(fid)\n" : "SYNTH \(kind) \(fid)\n").utf8)
        guard n > 0 else { return Data() }
        var out = Data()
        while out.count < n { out.append(head) }
        return out.prefix(n)
    }

    static func key(_ url: URL) -> String {
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        for host in ["https://studip.synth.invalid", "https://studip.uni-hannover.de"] where s.hasPrefix(host) { return String(s.dropFirst(host.count)) }
        return s
    }

    func reply(_ key: String) -> (status: Int, type: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        if let n = expireAfter, requests > n, key.hasPrefix("/jsonapi.php/") {
            return (401, "application/vnd.api+json", Data(#"{"errors":[{"status":"401"}]}"#.utf8))
        }
        if key.hasPrefix("/jsonapi.php/v1/file-refs/"), key.hasSuffix("/content") {
            let fid = String(key.dropFirst("/jsonapi.php/v1/file-refs/".count).dropLast("/content".count))
            guard let f = filesByID[fid] else { return (404, "text/plain", Data("keine Datei".utf8)) }
            if f.html { return (200, "text/html", Data("<!doctype html><html><body>Wartungsseite</body></html>".utf8)) }
            return (200, f.kind == "pdf" ? "application/pdf" : "application/octet-stream", Self.content(fid, f.serve, f.kind))
        }
        guard var r = routes[key] else { return (404, "text/plain", Data("nicht in der Nachbildung: \(key)".utf8)) }
        if !r.flaky.isEmpty {
            let st = r.flaky.removeFirst()
            routes[key] = r
            return (st, "application/vnd.api+json", Data(#"{"errors":[{"status":"\#(st)"}]}"#.utf8))
        }
        return (r.status, r.type, r.body)
    }
}

private final class SynthAppTransport: StudIPTransport, @unchecked Sendable {
    let world: SynthAppWorld
    init(_ world: SynthAppWorld) { self.world = world }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let r = world.reply(SynthAppWorld.key(url))
        return HTTPReply(status: r.status, contentType: r.type, finalURL: url, body: r.body)
    }

    func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let r = world.reply(SynthAppWorld.key(url))
        try r.body.write(to: file)
        return HTTPReply(status: r.status, contentType: r.type, finalURL: url)
    }
}

@MainActor
final class RiesentestSynthAppTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-03T10:00:00")!
    private var bed: ContainerTestBed!
    private var websiteStores: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "riesentest", clock: clock)
    }

    override func tearDown() async throws {
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        await bed.tearDown()
        try await super.tearDown()
    }

    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: URLSessionUniTransport.hildesheimDomains + QISConnection.qisDomains,
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: clock, publishesCurrent: false,
                                hildesheimTransport: stub, qisTransport: stub)
    }

    /// Stud.IP-Konten des Ordners (die Hildesheimer laufen im Kern: RiesentestSynthTests), hoechstens `limit`
    func testAppSyncAgainstSyntheticStudIP() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["RIESENTEST_DIR"] else { throw XCTSkip("TEST_RUNNER_RIESENTEST_DIR nicht gesetzt") }
        let out = env["RIESENTEST_OUT"] ?? (dir as NSString).appendingPathComponent("app-ergebnis.json")
        let limit = env["RIESENTEST_LIMIT"].flatMap(Int.init) ?? 20
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("acc-") && $0.hasSuffix(".json") }.sorted()
        var results: [[String: Any]] = []
        let started = Date()
        let m = manager()
        for name in names {
            if results.count >= limit { break }
            let json = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
            guard json["account"]?["university"]?.string == "luh" else { continue }
            let world = SynthAppWorld(json: json)
            var result: [String: Any] = ["index": world.account["index"]?.int ?? 0, "university": "luh", "program": world.account["program"]?.string ?? "",
                                         "flags": (world.account["flags"]?.object ?? [:]).keys.sorted(), "errors": [String](), "checks": [String: [String: Any]](),
                                         "counts": [String: Any]()]
            let t0 = Date()
            do {
                // Konto wie in der App: angemeldet, LUH gewaehlt, Container offen, Sitzungs-Cookie im Schluesselbund
                let a = bed.account(.luh)
                a.markLoginDone()
                let c = try bed.open(m, a)
                websiteStores.append(c.websiteDataStoreID)
                try c.cookies.save([bed.cookie("Seminar_Session", "synth-sitzung", domain: "studip.uni-hannover.de")])
                let client = StudIPClient(base: StudIPSync.base, transport: SynthAppTransport(world), pauseMillis: 0, maxRequests: 1_000_000, retry: UniRetry(attempts: 3, delayNanos: { _ in 0 }))
                let end = await m.studip.run(client: client)
                result["run_end"] = "\(String(describing: end))"
                result["summary"] = m.studip.lastSummary ?? ""
                result["phase"] = "\(m.studip.phase)"
                let db = try await c.host.backend().context.database
                // Module wie beim naechsten Lesen (Uebersicht, Module)
                _ = await c.host.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules")!))
                let sessionExpired = end == .sessionExpired
                try await Self.verify(world, db: db, container: c.layout.root, result: &result, sessionExpired: sessionExpired)
                result["requests"] = world.requests
                // Container leeren wie "Daten dieser Hochschule loeschen", damit das naechste Konto frisch beginnt
                await m.deleteUniversityData(c.key)
            } catch {
                var errors = result["errors"] as? [String] ?? []
                errors.append("\(error)".prefix(500).description)
                result["errors"] = errors
            }
            result["seconds"] = Date().timeIntervalSince(t0)
            let checks = result["checks"] as? [String: [String: Any]] ?? [:]
            result["ok"] = (result["errors"] as? [String] ?? []).isEmpty && checks.values.allSatisfy { ($0["ok"] as? Bool) == true }
            let bad = checks.filter { ($0.value["ok"] as? Bool) == false }.keys.sorted()
            print("#\(result["index"] ?? 0) app \(String(format: "%.2f", result["seconds"] as? Double ?? 0))s req=\(result["requests"] ?? 0) "
                  + ((result["ok"] as? Bool) == true ? "OK" : "FEHLER \(bad.joined(separator: ", ")) \((result["errors"] as? [String] ?? []).joined(separator: "; ").prefix(200))")
                  + " · \(result["summary"] ?? "")")
            results.append(result)
        }
        let summary: [String: Any] = ["tool": "riesentest-swift-app", "accounts": results, "wall_seconds": Date().timeIntervalSince(started), "parallel": 1]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        let crashed = results.filter { !(($0["errors"] as? [String]) ?? []).isEmpty }
        XCTAssertTrue(crashed.isEmpty, "Abstuerze: \(crashed.map { "\($0["index"] ?? 0): \(($0["errors"] as? [String] ?? []).first ?? "")" })")
        print("\(results.count) Konten (App), \(results.filter { ($0["ok"] as? Bool) == true }.count) ok -> \(out)")
    }

    // MARK: Pruefung (Stud.IP-Teil wie im Kern)

    private static func verify(_ world: SynthAppWorld, db: SQLiteDatabase, container: URL, result: inout [String: Any], sessionExpired: Bool) async throws {
        let e = world.expected
        let strict = (e["strict"]?.bool ?? true) && !sessionExpired
        var checks = result["checks"] as? [String: [String: Any]] ?? [:]
        var counts = result["counts"] as? [String: Any] ?? [:]
        func check(_ name: String, _ ok: Bool, _ detail: Any? = nil) {
            var c: [String: Any] = ["ok": ok]
            if let detail { c["detail"] = detail }
            checks[name] = c
        }
        var courses: [String: [String: JSONValue]] = [:]
        for r in try await db.withConnection({ try $0.rows("SELECT id, title, subject, kind, active, module_id FROM courses WHERE id != '__user__'") }) {
            if let id = r["id"]?.string { courses[id] = r }
        }
        var modules: [Int: String] = [:]
        for r in try await db.withConnection({ try $0.rows("SELECT id, name FROM modules") }) { if let id = r["id"]?.int, let n = r["name"]?.string { modules[id] = n } }
        var files: [String: [String: JSONValue]] = [:]
        for r in try await db.withConnection({ try $0.rows("SELECT id, course_id, local_path FROM files WHERE course_id != '__user__'") }) {
            if let id = r["id"]?.string { files[id] = r }
        }
        counts["courses"] = courses.count
        counts["modules"] = modules.count
        counts["files"] = files.count
        counts["downloaded"] = files.values.filter { ($0["local_path"]?.string ?? "").isEmpty == false }.count
        let expectedCourses = e["courses_expected"]?.array ?? []
        let missingCourses = expectedCourses.filter { courses[$0["db_id"]?.string ?? ""] == nil }.map { $0["db_id"]?.string ?? "" }
        check("courses_present", missingCourses.isEmpty, Array(missingCourses.prefix(5)))
        var misses: [[String: Any]] = []
        for c in expectedCourses {
            guard let row = courses[c["db_id"]?.string ?? ""], let subject = c["subject"]?.string, !subject.isEmpty else { continue }
            if (row["subject"]?.string ?? "") != subject || (row["kind"]?.string ?? "") != (c["kind"]?.string ?? "") {
                misses.append(["title": c["title"]?.string ?? "", "subject": row["subject"]?.string ?? "", "kind": row["kind"]?.string ?? "", "expected": [subject, c["kind"]?.string ?? ""]])
            }
        }
        counts["classify_misses"] = misses.count
        check("classification", misses.isEmpty, Array(misses.prefix(8)))
        let names = modules.values.sorted()
        check("modules_unique", Set(names).count == names.count)
        var wrongModule: [String] = []
        for c in expectedCourses {
            guard let id = c["db_id"]?.string, let row = courses[id], (row["active"]?.int ?? 1) == 1, row["kind"]?.string != "sonstiges",
                  let subject = row["subject"]?.string, !subject.isEmpty else { continue }
            if let mid = row["module_id"]?.int, modules[mid] == subject { continue }
            wrongModule.append(id)
        }
        check("course_has_module", wrongModule.isEmpty, Array(wrongModule.prefix(5)))
        let expectedModules = e["module_count"]?.int ?? 0
        check("module_count", Set(names).count == expectedModules, ["got": Set(names).count, "expected": expectedModules])
        let transient = Set(expectedCourses.filter { $0["bad_folder"]?.string != nil }.compactMap { $0["db_id"]?.string })
        let meta = e["files_meta"]?.object ?? [:]
        let expectedAll = Set(e["files_expected"]?.array?.compactMap(\.string) ?? [])
        let deep = Set(e["files_deep"]?.array?.compactMap(\.string) ?? [])
        let skipped = Set(expectedAll.filter { transient.contains(meta[$0]?["course"]?.string ?? "") })
        let expectedSwift = expectedAll.subtracting(deep).subtracting(skipped)
        let present = Set(files.keys)
        let missing = expectedSwift.subtracting(present).sorted()
        let extra = present.subtracting(expectedAll).subtracting(Set(e["files_inactive"]?.array?.compactMap(\.string) ?? [])).sorted()
        let forbidden = present.intersection(Set(e["files_forbidden"]?.array?.compactMap(\.string) ?? [])).sorted()
        counts["files_expected"] = expectedSwift.count
        counts["files_missing"] = missing.count
        counts["files_deep_skipped"] = deep.count
        counts["files_transient_skipped"] = skipped.count
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
        let series = try await db.withConnection { try $0.rows("SELECT id, course_id, rrule, source FROM course_events") }
        let dups = try await db.withConnection {
            try $0.rows("SELECT course_id, title, weekday, start_time, end_time, COUNT(*) n FROM course_events WHERE rrule != 'once' GROUP BY course_id, title, weekday, start_time, end_time HAVING n > 1")
        }
        check("timetable_no_duplicates", dups.isEmpty, dups.count)
        let weekly = series.filter { $0["rrule"]?.string != "once" }
        let expectedWeekly = (e["series_own_device"]?.int ?? e["series_own"]?.int ?? 0) + (e["personal"]?.int ?? 0)
        counts["series_weekly"] = weekly.count
        counts["series_expected"] = expectedWeekly
        check("timetable_series_count", strict ? weekly.count == expectedWeekly : true, ["got": weekly.count, "expected": expectedWeekly])
        let ev = try await db.withConnection { try $0.rows("SELECT COUNT(*) n, SUM(COALESCE(cancelled,0)) c FROM studip_events") }.first
        let n = ev?["n"]?.int ?? 0, cancelled = ev?["c"]?.int ?? 0
        counts["studip_events"] = n
        counts["cancelled"] = cancelled
        check("events_complete", strict ? n == (e["events_active"]?.int ?? 0) : true, ["got": n, "expected": e["events_active"]?.int ?? 0])
        check("cancellations_detected", strict ? cancelled == (e["cancelled_events"]?.int ?? 0) : true, ["got": cancelled, "expected": e["cancelled_events"]?.int ?? 0])
        var ann: [String: [JSONValue]] = [:]
        for r in try await db.withConnection({ try $0.rows("SELECT id, dates FROM announcements WHERE source='studip'") }) {
            if let id = r["id"]?.string { ann[id] = (r["dates"]?.string).flatMap { try? JSONValue.parse($0) }?.array ?? [] }
        }
        var found = 0
        var miss: [String] = []
        for d in e["deadlines_news"]?.array ?? [] {
            let id = d["news"]?.string ?? ""
            if let dates = ann[id], dates.contains(where: { $0["date"]?.string == d["date"]?.string && $0["kind"]?.string == d["kind"]?.string }) { found += 1 } else { miss.append(id) }
        }
        counts["deadlines_news_expected"] = e["deadlines_news"]?.array?.count ?? 0
        counts["deadlines_news_found"] = found
        check("deadlines_in_news", strict ? miss.isEmpty : true, Array(miss.prefix(5)))
        let dl = Set(try await db.withConnection { try $0.rows("SELECT id FROM deadlines WHERE source='studip'") }.compactMap { $0["id"]?.string })
        let cw = (e["cw_deadlines"]?.array ?? []).compactMap { $0["id"]?.string }
        counts["cw_deadlines_expected"] = cw.count
        counts["cw_deadlines_found"] = cw.filter { dl.contains($0) }.count
        let few = (e["courses_active"]?.int ?? 0) <= 12
        check("courseware_deadlines", (strict && few) ? cw.allSatisfy { dl.contains($0) } : true, ["missing": Array(cw.filter { !dl.contains($0) }.prefix(5))])
        let hasBulletin = try await db.scalar("SELECT 1 FROM sqlite_master WHERE name='studip_bulletin'") != nil
        let bulletin = hasBulletin ? (try await db.scalar("SELECT COUNT(*) FROM studip_bulletin")?.int ?? 0) : 0
        counts["bulletin"] = bulletin
        check("bulletin", strict ? bulletin == (e["bulletin"]?.int ?? 0) : true, ["got": bulletin, "expected": e["bulletin"]?.int ?? 0])
        let log = try await db.withConnection { try $0.rows("SELECT ok, message FROM sync_log ORDER BY id DESC LIMIT 1") }.first
        result["sync_log"] = ["ok": log?["ok"]?.int ?? -1, "message": log?["message"]?.string ?? ""]
        check("sync_ok", log != nil && ((log?["ok"]?.int ?? 0) == 1 || !strict), result["sync_log"])
        result["checks"] = checks
        result["counts"] = counts
    }
}

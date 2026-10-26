import XCTest
import UniFlowCore
@testable import UniFlow

/// Opencast-Aufzeichnungen in der App ohne PC: Abruf im Stud.IP-Abgleich (feste, erfundene Seiten aus
/// packages/shared-contracts/fixtures/opencast, kein Netz) in die lokale Datenbank des Geraets, Ordnung nach Fach und
/// Lehrwoche, Laden nur auf Wunsch (die Downloads selbst ohne Netz: der Delegat wird direkt aufgerufen), Ablage im
/// Stud.IP-Ordner ohne Backup, Fortsetzungsdaten, "Dateien loeschen", gemerkte Stelle, passende Aufzeichnung.
@MainActor
final class RecordingsAppTests: XCTestCase {

    // MARK: Umgebung

    private struct Device {
        let container: URL
        let host: LocalBackendHost
        let studipRoot: URL
        var support: URL { container.appendingPathComponent("Library/Application Support/UniFlow", isDirectory: true) }
    }

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-10T12:00:00")!

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-oc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(container: c, host: host, studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-oc-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func sync(_ dev: Device) throws -> StudIPSync {
        StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support)
    }

    private static func fixture(_ name: String) throws -> String {
        // .../apps/apple/UniFlowTests/RecordingsAppTests.swift -> Repository-Wurzel
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/opencast/\(name)"), encoding: .utf8)
    }

    private static func page(_ html: String, status: Int = 200) -> HTTPReply {
        HTTPReply(status: status, contentType: "text/html; charset=UTF-8", body: Data(html.utf8))
    }

    /// Stud.IP mit festen Antworten: zwei Kurse (Analysis mit Datei und Aufzeichnungen, Programmierung ohne Opencast)
    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [URL] = []

        var requested: [URL] { lock.lock(); defer { lock.unlock() }; return log }

        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; lock.unlock() }

        func json(_ path: String, _ text: String) {
            set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8)))
        }

        /// wie `StudIPSync.base` (hier ohne MainActor)
        private static let base = "https://studip.uni-hannover.de"

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: Self.base, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            return reply(url, key)
        }

        private func reply(_ url: URL, _ key: String) -> HTTPReply {
            lock.lock(); defer { lock.unlock() }
            log.append(url)
            return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }
    }

    private func fakeStudIP() throws -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester", #"""
            {"data":[{"id":"c-ana","type":"courses","attributes":{"title":"Testanalysis I"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}},
                     {"id":"c-prog","type":"courses","attributes":{"title":"Testprogrammierung"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
             "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
            """#)
        for c in ["c-ana", "c-prog"] {
            t.json("/jsonapi.php/v1/courses/\(c)/folders?page[limit]=200", #"{"data":[{"id":"r-\#(c)","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            t.json("/jsonapi.php/v1/folders/r-\(c)/folders?page[limit]=200", #"{"data":[]}"#)
        }
        t.json("/jsonapi.php/v1/folders/r-c-ana/file-refs?page[limit]=500", #"""
            {"data":[{"id":"f-orga","attributes":{"name":"Organisatorisches.pdf","filesize":3,"mime-type":"application/pdf","chdate":"2026-10-13T10:00:00+02:00","is-downloadable":false}},
                     {"id":"f-blatt2","attributes":{"name":"Blatt02.pdf","filesize":3,"mime-type":"application/pdf","chdate":"2026-10-23T10:00:00+02:00","is-downloadable":false}}]}
            """#)
        t.json("/jsonapi.php/v1/folders/r-c-prog/file-refs?page[limit]=500", #"""
            {"data":[{"id":"f-prog","attributes":{"name":"Folien 01.pdf","filesize":3,"mime-type":"application/pdf","chdate":"2026-10-14T10:00:00+02:00","is-downloadable":false}}]}
            """#)
        t.set("/plugins.php/opencastpluginluh/media/index?cid=c-ana", Self.page(try Self.fixture("media-index-videos.html")))
        t.set("/plugins.php/opencastpluginluh/media/index?cid=c-prog", Self.page(try Self.fixture("media-index-no-plugin.html"), status: 500))
        return t
    }

    private func client(_ t: FakeStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    private func moduleID(_ dev: Device, _ name: String) async throws -> Int {
        let id = try await dev.host.backend().context.database.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int
        return try XCTUnwrap(id, name)
    }

    /// Module wie beim ersten Lesen von "Meine Module" (`ensure_modules`)
    private func ensureModules(_ dev: Device) async throws {
        let backend = try await dev.host.backend()
        let clock = backend.context.clock
        try await backend.context.database.transaction { try LocalModules.ensureModules($0, clock: clock) }
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func excluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    /// Abgleich mit festen Antworten, Module angelegt; Rueckgabe: Abgleich, Transport, Analysis-Modul
    private func synced(_ dev: Device, _ t: FakeStudIP? = nil) async throws -> (StudIPSync, FakeStudIP, Int) {
        let stud = try t ?? fakeStudIP()
        let s = try sync(dev)
        await s.run(client: client(stud))
        try await ensureModules(dev)
        return (s, stud, try await moduleID(dev, "Testanalysis I"))
    }

    // MARK: Abruf im Stud.IP-Abgleich

    func testSyncStoresRecordingsBySubjectAndWeekWithoutLoadingVideos() async throws {
        let dev = try device()
        let (s, stud, ana) = try await synced(dev)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.lastSummary?.contains("3 neue Aufzeichnungen") ?? false, s.lastSummary ?? "")
        XCTAssertFalse(s.lastSummary?.contains("Aufzeichnungen von") ?? true, "Kurs ohne Opencast ist kein Fehler: \(s.lastSummary ?? "")")

        let blocks = await s.recordings.blocks(moduleID: ana)
        XCTAssertEqual(blocks.map(\.label), ["Woche 2 · 19.10. – 25.10.", "Woche 4 · 02.11. – 08.11.", "Ältere Unterlagen"])
        XCTAssertEqual(blocks.flatMap(\.entries).map(\.video.title),
                       ["Zentralübung 02", "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen", "02. Vorlesungswoche - Ergänzung zu Teil 2 (Video aus SoSe 21)"])
        let counts = await s.recordings.weekCounts(moduleID: ana)
        XCTAssertEqual(counts, [2: 1, 4: 1, -1: 1])
        let prog = try await moduleID(dev, "Testprogrammierung")
        let progBlocks = await s.recordings.blocks(moduleID: prog)
        XCTAssertTrue(progBlocks.isEmpty)

        // Laden nur auf Wunsch: keine Anfrage an den Videoserver, kein Download gestartet, keine Datei
        XCTAssertTrue(stud.requested.allSatisfy { $0.host == StudIPSync.base.host && $0.pathExtension != "mp4" })
        XCTAssertEqual(stud.requested.filter { $0.path.hasSuffix("/media/index") }.count, 2)
        XCTAssertTrue(s.recordings.states.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.recordings.root.path))

        // zweiter Abgleich: nichts Neues, Programmierung (ohne Opencast) erst nach 7 Tagen wieder
        await s.run(client: client(stud))
        XCTAssertFalse(s.lastSummary?.contains("neue Aufzeichnung") ?? true, s.lastSummary ?? "")
        XCTAssertEqual(stud.requested.filter { $0.path.hasSuffix("/media/index") }.count, 3)
    }

    func testUnreadableCourseIsSkippedAndLoginPageMeansReLogin() async throws {
        let dev = try device()
        let stud = try fakeStudIP()
        // Wartungsseite, im Kursueberblick aber der Reiter: nicht lesbar, Dateien und Stundenplan kommen trotzdem
        stud.set("/plugins.php/opencastpluginluh/media/index?cid=c-ana", Self.page("<html><body>Wartungsarbeiten</body></html>", status: 503))
        stud.set("/dispatch.php/course/overview?cid=c-ana", Self.page(#"<a href="/plugins.php/opencastpluginluh/media/index?cid=c-ana">Aufzeichnungen</a>"#))
        let (s, _, ana) = try await synced(dev, stud)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.lastSummary?.contains("Aufzeichnungen von 1 Kurs nicht lesbar") ?? false, s.lastSummary ?? "")
        let empty = await s.recordings.blocks(moduleID: ana)
        XCTAssertTrue(empty.isEmpty)

        // Anmeldeseite statt der Liste: Sitzung abgelaufen, die Dateien bleiben
        stud.set("/plugins.php/opencastpluginluh/media/index?cid=c-ana",
                 Self.page(#"<form action="/dispatch.php/login" method="post"><input type="password" name="password"></form>"#))
        await s.run(client: client(stud))
        XCTAssertEqual(s.phase, .needsLogin)
        let files = try await dev.host.backend().context.database.scalar("SELECT COUNT(*) FROM files")?.int
        XCTAssertEqual(files, 3)
    }

    // MARK: Passende Aufzeichnung

    func testMatchOnlyForSameSubjectAndWeek() async throws {
        let dev = try device()
        let (s, _, _) = try await synced(dev)
        let sheet = await s.recordings.match(fileID: "f-blatt2", text: "")
        XCTAssertEqual(sheet?.reason, .sameWeek(2))
        XCTAssertEqual(sheet?.entries.map(\.video.title), ["Zentralübung 02"])
        let other = await s.recordings.match(fileID: "f-prog", text: "Grenzwerte & Folgen")
        XCTAssertNil(other, "anderes Fach: nie")
        let orga = await s.recordings.match(fileID: "f-orga", text: "")
        XCTAssertNil(orga, "Woche 1 ohne Aufzeichnung, kein Thema: nichts")
    }

    // MARK: Laden, Ablage, Entfernen

    private func entry(_ s: StudIPSync, _ ana: Int, _ title: String) async throws -> OpencastEntry {
        let blocks = await s.recordings.blocks(moduleID: ana)
        return try XCTUnwrap(blocks.flatMap(\.entries).first { $0.video.title == title }, title)
    }

    private func job(_ lib: RecordingLibrary, _ e: OpencastEntry, _ quality: String) throws -> RecordingDownloadDelegate.Job {
        let m = try XCTUnwrap(e.video.media(quality))
        return .init(key: e.id, courseID: e.courseID, videoID: e.video.id, quality: quality, url: m.url,
                     target: lib.target(e, quality: quality), resume: lib.resumeURL(e, quality: quality), previous: lib.localFile(e)?.url)
    }

    func testFinishedDownloadIsStoredWithoutBackupAndCanBeRemoved() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let lib = s.recordings
        let e = try await entry(s, ana, "Zentralübung 02")
        XCTAssertNil(lib.localFile(e))

        // wie didFinishDownloadingTo: Datei aus dem Temp-Ordner des Systems an ihren Platz
        let j = try job(lib, e, "480p")
        try RecordingLibrary.prepareFolder(j.target.deletingLastPathComponent())
        try RecordingLibrary.prepareFolder(lib.partialFolder)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).tmp")
        try Data("mp4".utf8).write(to: temp)
        lib.delegate.register(901, job: j)
        lib.delegate.finish(901, location: temp, status: 200, contentType: "video/mp4")
        var loaded: OpencastEntry?
        let ok = await waitUntil {
            loaded = await lib.reload(e)
            return loaded?.localPath != nil
        }
        XCTAssertTrue(ok)
        let le = try XCTUnwrap(loaded)
        XCTAssertEqual(le.localQuality, "480p")
        XCTAssertEqual(le.localPath, "Library/Application Support/StudIP/Aufzeichnungen/c-ana/aaaaaaaa-0000-4000-8000-000000000002-480p.mp4",
                       "relativ zum Container, im Stud.IP-Ordner")
        let file = try XCTUnwrap(lib.localFile(le))
        XCTAssertTrue(try excluded(file.url), "nicht im iCloud-Backup")
        XCTAssertTrue(try excluded(dev.studipRoot), "der ganze Stud.IP-Ordner ohne Backup")
        XCTAssertEqual(RecordingPlayback.source(for: le.video, local: lib.localFile(le)), .local(file.url, quality: "480p"))

        await lib.remove(le)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        let removed = await lib.reload(e)
        XCTAssertNil(removed?.localPath)
        XCTAssertNotNil(removed, "die Liste bleibt")
    }

    func testWebPageInsteadOfVideoIsNotStored() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let lib = s.recordings
        let e = try await entry(s, ana, "Zentralübung 02")
        let j = try job(lib, e, "720p")
        try RecordingLibrary.prepareFolder(j.target.deletingLastPathComponent())
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).tmp")
        try Data("<html>Anmeldung</html>".utf8).write(to: temp)
        lib.delegate.register(902, job: j)
        lib.delegate.finish(902, location: temp, status: 200, contentType: "text/html; charset=utf-8")
        let failed = await waitUntil { lib.state(e) != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(lib.state(e), .failed("Statt des Videos kam eine Webseite (vermutlich Anmeldung).", quality: "720p"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.target.path))
        let after = await lib.reload(e)
        XCTAssertNil(after?.localPath)
    }

    /// Pruefpunkt: veraltete Fortsetzungsdaten blockieren nichts; ohne neue Daten werden die alten verworfen
    func testStaleResumeDataIsDiscarded() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let lib = s.recordings
        let e = try await entry(s, ana, "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen")
        let j = try job(lib, e, "720p")
        try RecordingLibrary.prepareFolder(lib.partialFolder)

        // neue Fortsetzungsdaten (Verbindung abgerissen): gespeichert mit Adresse und Zeit, ohne Backup
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: j.url)                                       // nie gestartet
        lib.delegate.register(task.taskIdentifier, job: j)
        lib.delegate.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("neu".utf8)]))
        XCTAssertEqual(try Data(contentsOf: j.resume), Data("neu".utf8))
        XCTAssertTrue(try excluded(j.resume))
        XCTAssertTrue(lib.hasResumeData(e, quality: "720p"))
        XCTAssertTrue(RecordingLibrary.resumeUsable(j.resume, url: j.url))
        XCTAssertFalse(RecordingLibrary.resumeUsable(j.resume, url: URL(string: "https://oc.example.test/andere.mp4")!), "andere Adresse")
        XCTAssertFalse(RecordingLibrary.resumeUsable(j.resume, url: j.url, now: Date().addingTimeInterval(4 * 86400)), "zu alt")
        let failed = await waitUntil { lib.state(e) != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(lib.state(e), .failed("Download unterbrochen. „Fortsetzen“ lädt weiter.", quality: "720p"))

        // fortgesetzter Download scheitert ohne neue Daten (Temp-Datei weg, Server ohne Range): alte Daten weg
        let again = session.downloadTask(with: j.url)
        lib.delegate.register(again.taskIdentifier, job: j)
        lib.delegate.urlSession(session, task: again, didCompleteWithError: URLError(.cannotParseResponse))
        XCTAssertFalse(lib.hasResumeData(e, quality: "720p"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingLibrary.resumeInfoURL(j.resume).path))
        _ = await waitUntil { lib.state(e) == .failed("Download unterbrochen.", quality: "720p") }
        XCTAssertEqual(lib.state(e), .failed("Download unterbrochen.", quality: "720p"))
        await lib.remove(e)                                                                  // "Verwerfen"
        XCTAssertNil(lib.state(e))
    }

    /// "Fortsetzen" und "Erneut" setzen die Fassung des abgebrochenen Downloads fort (hier 1080p aus dem Kontextmenue),
    /// auch nach einem Neustart der App; die Standardfassung (720p) startet nicht nach neuer Rueckfrage von vorn
    func testResumeUsesTheQualityOfTheAbortedDownload() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let lib = s.recordings
        let e = try await entry(s, ana, "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen")
        XCTAssertEqual(RecordingPlayback.quality(for: e.video)?.quality, "720p", "Standardfassung")
        XCTAssertNil(lib.resumeMedia(e))
        let j = try job(lib, e, "1080p")
        try RecordingLibrary.prepareFolder(lib.partialFolder)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: j.url)                                       // nie gestartet
        lib.delegate.register(task.taskIdentifier, job: j)
        lib.delegate.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("teil".utf8)]))
        _ = await waitUntil { lib.state(e) != nil }
        XCTAssertEqual(lib.state(e), .failed("Download unterbrochen. „Fortsetzen“ lädt weiter.", quality: "1080p"))
        XCTAssertEqual(lib.resumeMedia(e)?.quality, "1080p", "„Erneut“ setzt 1080p fort")
        XCTAssertFalse(lib.hasResumeData(e, quality: "720p"))
        XCTAssertTrue(RecordingLibrary.resumeUsable(lib.resumeURL(e, quality: "1080p"), url: j.url), "ohne neue Rückfrage")

        // nach einem Neustart der App: kein Zustand, die Zeile zeigt "Fortsetzen" fuer 1080p
        let restarted = try sync(dev).recordings
        XCTAssertNil(restarted.state(e))
        XCTAssertEqual(restarted.pausedMedia(e)?.quality, "1080p")
        XCTAssertEqual(restarted.resumeMedia(e)?.quality, "1080p")

        // zwei abgebrochene Fassungen: die zuletzt abgebrochene
        let other = try job(lib, e, "480p")
        RecordingLibrary.saveResume(Data("alt".utf8), job: other, now: Date().addingTimeInterval(-3600))
        XCTAssertEqual(restarted.pausedMedia(e)?.quality, "1080p")
        RecordingLibrary.saveResume(Data("neu".utf8), job: other, now: Date().addingTimeInterval(60))
        XCTAssertEqual(restarted.pausedMedia(e)?.quality, "480p")

        // "Verwerfen" entfernt alle Fortsetzungsdaten
        await restarted.remove(e)
        XCTAssertNil(restarted.pausedMedia(e))
        XCTAssertNil(restarted.resumeMedia(e))
    }

    /// HEAD ohne Antwort oder mit Fehlerstatus: Meldung statt Rueckfrage zu einem Download, der nicht starten kann
    func testProbeFailureInsteadOfConfirmingAnUnstartableDownload() {
        typealias Probe = RecordingLibrary.Probe
        XCTAssertEqual(Probe(status: nil, size: nil).failure, "Der Videoserver ist nicht erreichbar. Prüfe die Internetverbindung.")
        XCTAssertEqual(Probe(status: 404, size: nil).failure,
                       "Der Videoserver antwortet mit HTTP 404. Die Liste ist vermutlich veraltet, der nächste Stud.IP-Abgleich aktualisiert sie.")
        XCTAssertEqual(Probe(status: 410, size: nil).failure?.contains("Abgleich"), true)
        XCTAssertEqual(Probe(status: 503, size: nil).failure, "Der Videoserver antwortet mit HTTP 503. Bitte später erneut versuchen.")
        // Erfolg, Anmeldung (eigener Hinweis) und HEAD unbekannt (dann Rueckfrage zur Groesse): keine Meldung
        for s in [200, 206, 401, 403, 405, 501] { XCTAssertNil(Probe(status: s, size: nil).failure, "\(s)") }
        guard case .confirm(let q) = RecordingDownloadPolicy.decide(title: "x", quality: "720p", size: Probe(status: 405, size: nil).size,
                                                                   freeBytes: 50_000_000_000) else { return XCTFail("405: Rückfrage") }
        XCTAssertTrue(q.contains("unbekannt"), q)
    }

    func testRemoveDownloadsAlsoRemovesRecordingsButKeepsTheLists() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let lib = s.recordings
        let e = try await entry(s, ana, "Zentralübung 02")
        let j = try job(lib, e, "480p")
        try RecordingLibrary.prepareFolder(j.target.deletingLastPathComponent())
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).tmp")
        try Data("mp4".utf8).write(to: temp)
        lib.delegate.register(904, job: j)
        lib.delegate.finish(904, location: temp, status: 200, contentType: "video/mp4")
        _ = await waitUntil { await lib.reload(e)?.localPath != nil }

        await s.removeDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.root.path))
        let after = await lib.reload(e)
        XCTAssertNil(after?.localPath)
        let blocks = await lib.blocks(moduleID: ana)
        XCTAssertEqual(blocks.flatMap(\.entries).count, 3)
    }

    func testRememberedPositionLivesInTheDatabase() async throws {
        let dev = try device()
        let (s, _, ana) = try await synced(dev)
        let e = try await entry(s, ana, "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen")
        XCTAssertNil(e.position)
        await s.recordings.savePosition(e, seconds: 1234.5)
        await s.recordings.savePosition(e, seconds: .infinity)                                // ungueltig: bleibt
        let later = await s.recordings.reload(e)
        XCTAssertEqual(later?.position, 1234.5)
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: later?.position, duration: Double(e.video.duration ?? 0)), 1234.5)
        // ein neuer Abgleich behaelt die Stelle
        await s.run(client: client(try fakeStudIP()))
        let synced = await s.recordings.reload(e)
        XCTAssertEqual(synced?.position, 1234.5)
    }

    func testOutcomeSummary() {
        XCTAssertEqual(RecordingLibrary.Outcome(result: OpencastStoreResult(newVideos: 1, videos: 4)).summary, ["1 neue Aufzeichnung"])
        XCTAssertEqual(RecordingLibrary.Outcome(result: OpencastStoreResult(newVideos: 0, videos: 4)).summary, [])
        XCTAssertEqual(RecordingLibrary.Outcome(result: OpencastStoreResult(newVideos: 0, videos: 0), failedCourses: 2).summary,
                       ["Aufzeichnungen von 2 Kursen nicht lesbar"])
        XCTAssertEqual(RecordingLibrary.Outcome(result: nil, unreachable: true).summary,
                       ["Aufzeichnungen nicht gespeichert", "Aufzeichnungen: Stud.IP nicht erreichbar"])
    }

    func testAutomaticSyncNeverRunsUnderXCTest() throws {
        XCTAssertTrue(StudIPSync.isUnderTest())
        XCTAssertFalse(StudIPSync.automaticRunAllowed())
        XCTAssertFalse(StudIPSync.isUnderTest(environment: [:]))
        let d = try defaults()
        XCTAssertTrue(StudIPSync.automaticRunAllowed(environment: [:], defaults: d))
        d.set(true, forKey: "UFNoStudIPSync")
        XCTAssertFalse(StudIPSync.automaticRunAllowed(environment: [:], defaults: d))
    }
}

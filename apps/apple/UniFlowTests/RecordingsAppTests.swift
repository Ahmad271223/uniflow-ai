import XCTest
import UniFlowCore
@testable import UniFlow

/// Aufzeichnungen in der App: Ablage der geladenen Videos (Pfade, kein Backup), Erkennen geladener und
/// abgebrochener Downloads, Wiedergabe-Auswahl mit lokaler Datei, gemerkte Stelle. Ohne Netz: kein Download und kein
/// Streaming in diesen Tests (siehe Bericht).
@MainActor
final class RecordingsAppTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func excluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    func testFolderUnderApplicationSupportAndNotInBackup() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(StudIPSync.recordingsFolder(support: support).path, support.path + "/UniFlow/recordings")

        let folder = root.appendingPathComponent("files/c1", isDirectory: true)
        try RecordingLibrary.prepareFolder(folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(try excluded(folder))

        let file = folder.appendingPathComponent("v1-720p.mp4")
        try Data("mp4".utf8).write(to: file)
        XCTAssertFalse(try excluded(file))
        try RecordingLibrary.excludeFromBackup(file)
        XCTAssertTrue(try excluded(file))
    }

    func testFilePathsAndRescan() throws {
        let lib = RecordingLibrary(root: root)
        let video = "aaaaaaaa-0000-4000-8000-000000000001"
        let target = lib.fileURL(course: "c1", video: video, quality: "720p")
        XCTAssertEqual(target.path, root.path + "/files/c1/\(video)-720p.mp4")
        XCTAssertTrue(lib.qualities(course: "c1", video: video).isEmpty)

        try RecordingLibrary.prepareFolder(target.deletingLastPathComponent())
        try Data("mp4".utf8).write(to: target)
        try Data("resume".utf8).write(to: root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: "c1", videoID: "Xyzab-12345-6789", quality: "480p")))
        lib.rescan()
        XCTAssertEqual(lib.qualities(course: "c1", video: video), ["720p"])
        XCTAssertTrue(lib.resumable.contains(RecordingLibrary.key(course: "c1", video: "Xyzab-12345-6789", quality: "480p")))
        XCTAssertTrue(lib.qualities(course: "c1", video: "Xyzab-12345-6789").isEmpty)    // nur angefangen, nicht geladen

        // geladene Datei vor Stream
        let v = OpencastVideo(id: video, title: "3. Vorlesung", downloads: [
            OpencastDownload(quality: "1080p", height: 1080, url: URL(string: "https://oc.example.test/1080.mp4")!),
            OpencastDownload(quality: "720p", height: 720, url: URL(string: "https://oc.example.test/720.mp4")!),
        ])
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: lib.qualities(course: "c1", video: video)), .local(quality: "720p"))

        lib.remove(course: "c1", video: video, quality: "720p")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(lib.qualities(course: "c1", video: video).isEmpty)
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: lib.qualities(course: "c1", video: video)),
                       .stream(URL(string: "https://oc.example.test/720.mp4")!, quality: "720p"))
    }

    func testRemovingStudIPDownloadsAlsoRefreshesLibrary() async throws {
        let lib = RecordingLibrary(root: root)
        let target = lib.fileURL(course: "c2", video: "v9", quality: "480p")
        try RecordingLibrary.prepareFolder(target.deletingLastPathComponent())
        try Data("mp4".utf8).write(to: target)
        lib.rescan()
        XCTAssertEqual(lib.qualities(course: "c2", video: "v9"), ["480p"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("files"))
        NotificationCenter.default.post(name: .uniflowRecordingFilesChanged, object: nil)
        for _ in 0..<20 where !lib.qualities(course: "c2", video: "v9").isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(lib.qualities(course: "c2", video: "v9").isEmpty)
    }

    func testRememberedPosition() {
        let lib = RecordingLibrary(root: root)
        let id = "test-\(UUID().uuidString)"
        XCTAssertNil(lib.position(video: id))
        lib.savePosition(1234.5, video: id)
        XCTAssertEqual(lib.position(video: id), 1234.5)
        lib.savePosition(.infinity, video: id)                                                 // ungueltig: bleibt
        XCTAssertEqual(lib.position(video: id), 1234.5)
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: lib.position(video: id), duration: 5339), 1234.5)
        var all = UserDefaults.standard.dictionary(forKey: "uniflow.recordings.positions") ?? [:]
        all[id] = nil
        UserDefaults.standard.set(all, forKey: "uniflow.recordings.positions")
    }

    // MARK: Download-Zustand (ohne Netz: Tasks werden nie gestartet, der Delegat wird direkt aufgerufen)

    private func waitForState(_ lib: RecordingLibrary, _ key: (String, String, String)) async throws {
        for _ in 0..<40 where lib.state(course: key.0, video: key.1, quality: key.2) == nil { try await Task.sleep(nanoseconds: 25_000_000) }
    }

    func testStaleResumeDataIsDiscardedWhenResumeFails() async throws {
        let lib = RecordingLibrary(root: root)
        let target = lib.fileURL(course: "c1", video: "v1", quality: "720p")
        let resume = root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: "c1", videoID: "v1", quality: "720p"))
        try RecordingLibrary.prepareFolder(target.deletingLastPathComponent())
        try Data("alte Fortsetzungsdaten".utf8).write(to: resume)
        lib.rescan()
        XCTAssertTrue(lib.isResumable(course: "c1", video: "v1", quality: "720p"))

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://oc.example.test/v1-720.mp4")!)   // nie gestartet
        let key = RecordingLibrary.key(course: "c1", video: "v1", quality: "720p")
        lib.delegate.register(task.taskIdentifier, key: key, target: target, resume: resume)
        // fortgesetzter Download scheitert ohne neue Fortsetzungsdaten (z. B. 416 oder Temp-Datei weg)
        lib.delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cannotParseResponse))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        try await waitForState(lib, ("c1", "v1", "720p"))
        XCTAssertEqual(lib.state(course: "c1", video: "v1", quality: "720p"), .failed("Download unterbrochen."))
        XCTAssertFalse(lib.isResumable(course: "c1", video: "v1", quality: "720p"))           // "Erneut" startet frisch
        XCTAssertEqual(lib.pendingQuality(course: "c1", video: "v1", qualities: ["1080p", "720p", "480p"]), "720p")
        lib.remove(course: "c1", video: "v1", quality: "720p")                                  // "Verwerfen"
        XCTAssertNil(lib.state(course: "c1", video: "v1", quality: "720p"))
        XCTAssertNil(lib.pendingQuality(course: "c1", video: "v1", qualities: ["1080p", "720p", "480p"]))
    }

    func testNewResumeDataIsKept() async throws {
        let lib = RecordingLibrary(root: root)
        let target = lib.fileURL(course: "c1", video: "v2", quality: "1080p")
        let resume = root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: "c1", videoID: "v2", quality: "1080p"))
        try RecordingLibrary.prepareFolder(target.deletingLastPathComponent())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://oc.example.test/v2-1080.mp4")!)
        lib.delegate.register(task.taskIdentifier, key: RecordingLibrary.key(course: "c1", video: "v2", quality: "1080p"), target: target, resume: resume)
        lib.delegate.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("neu".utf8)]))
        XCTAssertEqual(try Data(contentsOf: resume), Data("neu".utf8))
        XCTAssertTrue(try excluded(resume))
        try await waitForState(lib, ("c1", "v2", "1080p"))
        XCTAssertTrue(lib.isResumable(course: "c1", video: "v2", quality: "1080p"))
        // die Zeile zeigt den 1080p-Rest, nicht die Standardfassung 720p
        XCTAssertEqual(lib.pendingQuality(course: "c1", video: "v2", qualities: ["1080p", "720p", "480p"]), "1080p")
        if case .failed(let m)? = lib.state(course: "c1", video: "v2", quality: "1080p") { XCTAssertTrue(m.contains("Fortsetzen")) } else { XCTFail("kein Fehlerzustand") }
    }

    func testPendingQualityAcrossVersions() {
        let k = { (q: String) in RecordingLibrary.key(course: "c", video: "v", quality: q) }
        let qs = ["1080p", "720p", "480p"]
        XCTAssertNil(RecordingLibrary.pendingQuality(course: "c", video: "v", qualities: qs, states: [:], resumable: []))
        XCTAssertEqual(RecordingLibrary.pendingQuality(course: "c", video: "v", qualities: qs, states: [k("1080p"): .running(0.4)], resumable: []), "1080p")
        // laufend vor abgebrochen
        XCTAssertEqual(RecordingLibrary.pendingQuality(course: "c", video: "v", qualities: qs,
                                                       states: [k("1080p"): .paused, k("480p"): .running(nil)], resumable: [k("720p")]), "480p")
        XCTAssertEqual(RecordingLibrary.pendingQuality(course: "c", video: "v", qualities: qs, states: [:], resumable: [k("480p")]), "480p")
        // anderes Video zaehlt nicht
        XCTAssertNil(RecordingLibrary.pendingQuality(course: "c", video: "w", qualities: qs, states: [k("720p"): .running(0.1)], resumable: [k("720p")]))
    }

    func testServerAnswersAndProgressThrottle() {
        XCTAssertNil(RecordingDownloadDelegate.failure(status: 200, contentType: "video/mp4"))
        XCTAssertNil(RecordingDownloadDelegate.failure(status: 206, contentType: nil))
        XCTAssertEqual(RecordingDownloadDelegate.failure(status: 403, contentType: "text/html"), "Der Videoserver verlangt eine Anmeldung (HTTP 403).")
        XCTAssertEqual(RecordingDownloadDelegate.failure(status: 416, contentType: nil), "Der Videoserver antwortet mit HTTP 416.")
        XCTAssertEqual(RecordingDownloadDelegate.failure(status: 200, contentType: "text/html; charset=utf-8"), "Statt des Videos kam eine Webseite (vermutlich Anmeldung).")

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(RecordingDownloadDelegate.shouldReport(last: nil, lastAt: nil, fraction: 0.001, now: t0))          // erster Rueckruf
        XCTAssertFalse(RecordingDownloadDelegate.shouldReport(last: 0.10, lastAt: t0, fraction: 0.105, now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(RecordingDownloadDelegate.shouldReport(last: 0.10, lastAt: t0, fraction: 0.11, now: t0.addingTimeInterval(0.1)))   // 1 %
        XCTAssertTrue(RecordingDownloadDelegate.shouldReport(last: 0.10, lastAt: t0, fraction: 0.101, now: t0.addingTimeInterval(0.6)))  // 0,5 s
        XCTAssertTrue(RecordingDownloadDelegate.shouldReport(last: 0.995, lastAt: t0, fraction: 1, now: t0))                            // Ende
        XCTAssertFalse(RecordingDownloadDelegate.shouldReport(last: nil, lastAt: t0, fraction: nil, now: t0.addingTimeInterval(5)))    // Groesse unbekannt
        // 10 000 Rueckrufe ueber 0 … 100 % in 2 s ergeben hoechstens gut 100 Meldungen
        var last: Double?, lastAt: Date?, reports = 0
        for i in 0...10_000 {
            let f = Double(i) / 10_000, now = t0.addingTimeInterval(Double(i) * 0.0002)
            if RecordingDownloadDelegate.shouldReport(last: last, lastAt: lastAt, fraction: f, now: now) { reports += 1; last = f; lastAt = now }
        }
        XCTAssertLessThanOrEqual(reports, 110)
    }

    func testOrphansShownAndRemoved() throws {
        let lib = RecordingLibrary(root: root)
        let keep = lib.fileURL(course: "c1", video: "v1", quality: "720p")
        let gone = lib.fileURL(course: "c1", video: "v2", quality: "480p")
        let deselected = lib.fileURL(course: "c9", video: "v5", quality: "720p")
        for u in [keep, gone, deselected] {
            try RecordingLibrary.prepareFolder(u.deletingLastPathComponent())
            try Data(count: 1_500_000).write(to: u)
        }
        try Data("r".utf8).write(to: root.appendingPathComponent(RecordingFilesLayout.resumeDataPath(courseID: "c9", videoID: "v6", quality: "1080p")))
        lib.rescan()
        let index = RecordingsIndex(courses: [RecordingCourse(courseID: "c1", courseTitle: "Testfach A", status: .available,
                                                              videos: [OpencastVideo(id: "v1", title: "Vorlesung 1")], lastChecked: Date())])
        let orphans = lib.orphans(in: index)
        XCTAssertEqual(Set(orphans.map(\.video)), ["v2", "v5", "v6"])
        XCTAssertEqual(lib.bytes(orphans), 3_000_001)
        lib.removeOrphans(in: index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deselected.path))
        XCTAssertTrue(lib.orphans(in: index).isEmpty)
        XCTAssertEqual(lib.qualities(course: "c1", video: "v1"), ["720p"])
    }

    // MARK: Kein Stud.IP-Abgleich in Tests

    func testNoAutomaticStudIPSyncUnderXCTest() async throws {
        XCTAssertTrue(StudIPSync.isUnderTest())                                                // dieser Lauf
        XCTAssertFalse(StudIPSync.automaticRunAllowed())
        let suite = "recordings-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(StudIPSync.automaticRunAllowed(environment: [:], defaults: d))
        XCTAssertFalse(StudIPSync.automaticRunAllowed(environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"], defaults: d))
        d.set(true, forKey: "UFNoStudIPSync")
        XCTAssertFalse(StudIPSync.automaticRunAllowed(environment: [:], defaults: d))
        d.removeObject(forKey: "UFNoStudIPSync")
        d.set("#/modules", forKey: "UFRoute")
        XCTAssertFalse(StudIPSync.automaticRunAllowed(environment: [:], defaults: d))

        // auch mit Sitzung im Schluesselbund: weder runIfDue noch run starten einen Abgleich
        let studip = StudIPSync()
        let before = studip.lastRun
        studip.runIfDue()
        await studip.run()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(studip.isRunning)
        XCTAssertEqual(studip.lastRun, before)
    }

    func testFormatting() {
        XCTAssertEqual(RecordingFormat.duration(5339), "1:28 h")
        XCTAssertEqual(RecordingFormat.duration(2148), "36 min")
        XCTAssertNil(RecordingFormat.duration(nil))
        XCTAssertEqual(RecordingFormat.date(Date(timeIntervalSince1970: 1_794_045_600)), "07.11.2026")
        XCTAssertEqual(RecordingWeekBlocks.count(1), "1 Aufzeichnung")
        XCTAssertEqual(RecordingWeekBlocks.count(3), "3 Aufzeichnungen")
    }
}

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

    func testFormatting() {
        XCTAssertEqual(RecordingFormat.duration(5339), "1:28 h")
        XCTAssertEqual(RecordingFormat.duration(2148), "36 min")
        XCTAssertNil(RecordingFormat.duration(nil))
        XCTAssertEqual(RecordingFormat.date(Date(timeIntervalSince1970: 1_794_045_600)), "07.11.2026")
        XCTAssertEqual(RecordingWeekBlocks.count(1), "1 Aufzeichnung")
        XCTAssertEqual(RecordingWeekBlocks.count(3), "3 Aufzeichnungen")
    }
}

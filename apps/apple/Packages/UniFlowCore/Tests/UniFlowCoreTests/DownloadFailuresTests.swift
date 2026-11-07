import XCTest
@testable import UniFlowCore

/// Gescheiterte Downloads je Datei (Befund vom iPad 07.11.2026: Dateien "erkannt, aber nicht geladen", ohne Grund)
final class DownloadFailuresTests: XCTestCase {
    private let base = URL(string: "https://studip.example.org")!

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-11-07T21:59:00")!, university: "luh")
        return db
    }

    private func file(_ id: String, course: String = "v1", downloadable: Bool = false) -> StudIPFile {
        StudIPFile(id: id, courseID: course, name: "\(id).pdf", size: 10, mimeType: "application/pdf",
                   changed: "2026-10-19T10:00:00+02:00", isDownloadable: downloadable)
    }

    /// Wie `StudIPLibrary.storeFiles`, geladene Dateien liegen lokal vor
    private func store(_ c: SQLiteConnection, _ files: [StudIPFile], at: String) throws -> [StudIPFile] {
        try files.filter { f in
            try !UniStore.storeFiles(c, courseID: f.courseID, [StudIPLibrary.fileRow(f, base: base)], now: at, fileExists: { _ in true }).isEmpty
        }
    }

    /// Fall "Liste da, Download fehlt": gelistete Dateien ohne Ablageort meldet jeder Abgleich wieder zum Laden, auch
    /// nach einem Fehlversuch; erst der Download nimmt sie heraus und loescht den Fehler
    func testListedButNotLoadedIsOfferedAgainUntilDownloaded() async throws {
        let db = try await database()
        let files = [file("a"), file("b"), file("g", course: "sg", downloadable: true)]
        try await db.transaction { c in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "v1", title: "Vorlesung"), StudIPCourse(id: "sg", title: "Lerngruppe")],
                                           startedAt: "2026-11-07T21:59:08")
            let first = try StudIPLibrary.storeFiles(c, files, startedAt: "2026-11-07T21:59:08", base: self.base, localFiles: nil)
            XCTAssertEqual(first.map(\.id), ["a", "b", "g"])
            // Studiengruppe geladen, Vorlesung gescheitert
            try UniStore.markDownloaded(c, StudIPLibrary.fileRow(files[2], base: self.base), localPath: "StudIP/files/g/g.pdf", sha256: nil,
                                        now: "2026-11-07T22:00:00")
            try DownloadFailures.record(c, fileID: "a", message: "Stud.IP-Fehler", status: 500, now: "2026-11-07T22:00:00")
            // zweiter Abgleich (22:06): beide Vorlesungsdateien wieder dabei, die geladene nicht
            let second = try self.store(c, files, at: "2026-11-07T22:06:00")
            XCTAssertEqual(second.map(\.id), ["a", "b"])
            try DownloadFailures.record(c, fileID: "a", message: "Stud.IP-Fehler", status: 500, now: "2026-11-07T22:06:00")
            XCTAssertEqual(try DownloadFailures.entry(c, fileID: "a")?.attempts, 2)
            try UniStore.markDownloaded(c, StudIPLibrary.fileRow(files[0], base: self.base), localPath: "StudIP/files/a/a.pdf", sha256: nil,
                                        now: "2026-11-07T22:07:00")
            XCTAssertNil(try DownloadFailures.entry(c, fileID: "a"))
            let third = try self.store(c, files, at: "2026-11-07T22:10:00")
            XCTAssertEqual(third.map(\.id), ["b"])
        }
    }

    func testWithoutTableThereAreNoFailures() async throws {
        let db = try await database()
        try await db.withConnection { c in
            XCTAssertNil(try DownloadFailures.entry(c, fileID: "x"))
            XCTAssertTrue(try DownloadFailures.all(c).isEmpty)
            try DownloadFailures.clear(c, fileID: "x")                       // ohne Tabelle kein Fehler
        }
    }

    /// Absagen (403/404) ruhen im automatischen Abgleich 6 Stunden, alles andere wird jedes Mal versucht
    func testAutomaticRetryRules() {
        let refused = DownloadFailures.Entry(id: "x", message: "", status: 403, attempts: 1, failedAt: "2026-11-07T22:00:00")
        XCTAssertFalse(DownloadFailures.dueForAutomaticRetry(refused, now: "2026-11-07T22:06:00"))
        XCTAssertTrue(DownloadFailures.dueForAutomaticRetry(refused, now: "2026-11-08T04:00:00"))
        let transient = DownloadFailures.Entry(id: "x", message: "", status: 500, attempts: 3, failedAt: "2026-11-07T22:00:00")
        XCTAssertTrue(DownloadFailures.dueForAutomaticRetry(transient, now: "2026-11-07T22:01:00"))
        XCTAssertTrue(DownloadFailures.dueForAutomaticRetry(nil, now: "2026-11-07T22:01:00"))
    }

    func testMessagesAreUnderstandable() {
        XCTAssertEqual(DownloadFailures.describe(StudIPError.http(status: 403, path: "")).status, 403)
        XCTAssertTrue(DownloadFailures.describe(StudIPError.http(status: 403, path: "")).message.contains("nicht zum Herunterladen frei"))
        XCTAssertTrue(DownloadFailures.describe(StudIPError.http(status: 404, path: "")).message.contains("404"))
        XCTAssertTrue(DownloadFailures.describe(URLError(.notConnectedToInternet)).message.contains("Internetverbindung"))
        XCTAssertNil(DownloadFailures.describe(URLError(.timedOut)).status)
        XCTAssertTrue(DownloadFailures.describe(UniDownloads.Failure.empty("x")).message.contains("leer"))
    }
}

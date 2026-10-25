import Foundation
import XCTest
@testable import UniFlowCore

private func fixture(_ name: String) throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/\(name)")))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!
private let base = URL(string: "https://studip.test")!

/// Stud.IP-Abgleich in die Datenbank: gegen studip_sync.run_sync (Fixture studip-import.json), Idempotenz,
/// Nutzerfelder, relative Pfade, Uebernahme des alten Index.
final class StudIPLibraryTests: XCTestCase {

    /// Ein Durchgang wie StudIPSync.run in der App: Kurse, je Kurs die Dateiliste, Downloads, Protokoll.
    /// Rueckgabe: Dateien, die geladen werden muessten, und die geladenen.
    @discardableResult
    private func run(_ db: SQLiteDatabase, files: LocalFiles, now: String, courses: [StudIPCourse],
                     lists: [(String, [StudIPFile])], error: String? = nil) async throws -> (wanted: [String], loaded: [String]) {
        if let error {
            try await db.transaction { try StudIPLibrary.log($0, startedAt: now, finishedAt: now, ok: false, newFiles: 0, message: StudIPLibrary.failure(error)) }
            return ([], [])
        }
        try await db.transaction { try StudIPLibrary.storeCourses($0, courses, startedAt: now) }
        var wanted: [StudIPFile] = []
        for (_, list) in lists {
            wanted += try await db.transaction { try StudIPLibrary.storeFiles($0, list, startedAt: now, base: base, localFiles: files) }
        }
        var loaded: [String] = []
        for f in wanted where f.isDownloadable {
            let rel = "studip/" + StudIPImport.relativePath(for: f)
            _ = try files.write(Data("Inhalt \(f.id)".utf8), to: rel)
            try await db.transaction { try StudIPLibrary.markDownloaded($0, fileID: f.id, localPath: rel, at: now) }
            loaded.append(f.id)
        }
        let n = loaded.count
        try await db.transaction { try StudIPLibrary.log($0, startedAt: now, finishedAt: now, ok: true, newFiles: n, message: StudIPLibrary.summary(newFiles: n)) }
        return (wanted.map(\.id), loaded)
    }

    private func remoteFiles(_ j: JSONValue?, course: String) -> [StudIPFile] {
        (j?.array ?? []).map { f in
            StudIPFile(id: f["id"]?.string ?? "", courseID: course, name: f["name"]?.string ?? "", size: f["size"]?.int ?? 0,
                       mimeType: f["mime"]?.string, changed: f["changed"]?.string ?? "", isDownloadable: f["downloadable"]?.bool ?? true,
                       folderPath: f["folder"]?.string ?? "")
        }
    }

    func testRoundsMatchPythonRunSync() async throws {
        let fx = try fixture("studip-import.json")
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock)
        for round in fx["rounds"]?.array ?? [] {
            let name = round["name"]?.string ?? ""
            for sql in round["user_sql"]?.array?.compactMap(\.string) ?? [] { try await db.execute(sql) }
            for id in round["delete_local"]?.array?.compactMap(\.string) ?? [] {
                let path = try await db.scalar("SELECT local_path FROM files WHERE id=?", [.text(id)])?.string
                try FileManager.default.removeItem(at: try XCTUnwrap(files.url(stored: path ?? "")))
            }
            let courses = (round["courses"]?.array ?? []).map {
                StudIPCourse(id: $0["id"]?.string ?? "", title: $0["title"]?.string ?? "", number: $0["number"]?.string,
                             semesterTitle: $0["semester"]?.string)
            }
            // Reihenfolge der Kurse wie Python (Liste der Kurse, darin die Dateien)
            let lists = courses.map { ($0.id, remoteFiles(round["files"]?[$0.id], course: $0.id)) }
            let (wanted, loaded) = try await run(db, files: files, now: round["now"]?.string ?? "", courses: courses, lists: lists,
                                                 error: round["error"]?.string)
            XCTAssertEqual(wanted, round["attempted"]?.array?.compactMap(\.string), "\(name): zu ladende Dateien wie Python")
            XCTAssertEqual(loaded, round["downloaded"]?.array?.compactMap(\.string), "\(name): geladene Dateien")
            for table in ["courses", "files", "sync_log"] {
                var local = try await db.rows("SELECT * FROM \(table) ORDER BY id")
                for i in local.indices where local[i]["local_path"].map({ !$0.isNull }) == true { local[i]["local_path"] = "<lokal>" }
                let expected = round["tables"]?[table]?.array ?? []
                XCTAssertEqual(local.count, expected.count, "\(name): \(table)")
                for (l, e) in zip(local, expected) where JSONValue.object(l) != e {
                    XCTFail("\(name): \(table)\n  lokal  \(JSONValue.object(l).jsonString(sortedKeys: true))\n  Python \(e.jsonString(sortedKeys: true))")
                }
            }
        }
    }

    func testUnixTimesLikePython() throws {
        let fx = try fixture("studip-import.json")
        for (text, unix) in fx["unix_times"]?.object ?? [:] {
            XCTAssertEqual(StudIPLibrary.unixTime(text), unix.int, text)
        }
        XCTAssertEqual(StudIPLibrary.unixTime("2026-10-25T02:30:00+02:00"), StudIPLibrary.unixTime("2026-10-25T00:30:00Z"))
        XCTAssertEqual(StudIPLibrary.unixTime("2026-10-25"), BerlinClock.utcSeconds(day: BerlinClock.parseISODate("2026-10-25")!, minutes: 0))
        for bad in ["", "gestern", "2026-13-01T00:00:00Z", "2026-10-25T25:00:00Z", "2026-10-25T10:00:00+0x:00", "2026-10-25T10:00:00Zx"] {
            XCTAssertNil(StudIPLibrary.unixTime(bad), bad)
        }
    }

    func testFileKindLikePython() {
        XCTAssertEqual(StudIPLibrary.fileKind(name: "uebung01.py", mime: "text/x-python"), "file")
        XCTAssertEqual(StudIPLibrary.fileKind(name: "Folie.PDF", mime: nil), "pdf")
        XCTAssertEqual(StudIPLibrary.fileKind(name: "ohne", mime: "application/pdf"), "pdf")
        XCTAssertEqual(StudIPLibrary.fileKind(name: "plot.gif", mime: "image/gif"), "image")
        XCTAssertEqual(StudIPLibrary.fileKind(name: "scan", mime: "image/heic"), "image")
    }

    /// Zweiter Abgleich mit derselben Liste: nichts zu laden, nichts doppelt, Nutzerfelder und Notizen bleiben
    func testIdempotentAndUserFieldsKept() async throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let db = backend.context.database
        let course = StudIPCourse(id: "c1", title: "Testkurs", number: nil, semesterTitle: "WiSe 2026/27")
        let list = [StudIPFile(id: "a1", courseID: "c1", name: "Folien.pdf", size: 10, mimeType: "application/pdf", changed: "2026-10-19T10:00:00+02:00"),
                    StudIPFile(id: "a2", courseID: "c1", name: "Blatt.pdf", size: 5, mimeType: nil, changed: "2026-10-19T11:00:00+02:00", folderPath: "Übungen")]
        let first = try await run(db, files: files, now: "2026-10-20T08:00:00", courses: [course], lists: [("c1", list)])
        XCTAssertEqual(first.loaded, ["a1", "a2"])
        // Nutzer arbeitet: Status, Favorit, Ordner, Titel, Notizen
        try await db.execute("UPDATE files SET status='erledigt', seen_by_user=1, favorite=1, folder_id=3, title='Mein Titel' WHERE id='a1'")
        try await db.execute("INSERT INTO folders(id, name) VALUES (3, 'Eigener Ordner')")
        let put = await backend.handle(LocalRequest(method: "PUT", path: "/api/files/a1/annotations", query: [.init("base_version", "0")],
                                                    body: Data(#"{"pages": {"p1": {"objects": [{"id": "s"}]}}}"#.utf8)))
        XCTAssertEqual(put.status, 200)
        let before = try await db.rows("SELECT * FROM files ORDER BY id")
        let second = try await run(db, files: files, now: "2026-10-21T08:00:00", courses: [course], lists: [("c1", list)])
        XCTAssertEqual(second.wanted, [], "unveraendert: kein Download")
        let after = try await db.rows("SELECT * FROM files ORDER BY id")
        XCTAssertEqual(after, before, "nichts geaendert, auch nicht first_seen oder downloaded_at")
        let count = try await db.scalar("SELECT COUNT(*) FROM files")?.int
        XCTAssertEqual(count, 2)
        let notes = await backend.handle(LocalRequest(method: "GET", path: "/api/files/a1/annotations"))
        XCTAssertEqual(notes.json?["version"], 1)
        // umbenannt (neue Aenderungszeit): dieselbe ID, neue Datei, Nutzerfelder und Notizen bleiben
        let renamed = [StudIPFile(id: "a1", courseID: "c1", name: "Folien (korrigiert).pdf", size: 12, mimeType: "application/pdf",
                                  changed: "2026-10-21T09:00:00+02:00")] + [list[1]]
        let third = try await run(db, files: files, now: "2026-10-22T08:00:00", courses: [course], lists: [("c1", renamed)])
        XCTAssertEqual(third.loaded, ["a1"])
        let a1Row = try await db.queryOne("SELECT * FROM files WHERE id='a1'")
        let a1 = try XCTUnwrap(a1Row)
        XCTAssertEqual(a1["name"]?.string, "Folien (korrigiert).pdf")
        XCTAssertEqual(a1["status"]?.string, "erledigt")
        XCTAssertEqual(a1["favorite"]?.int, 1)
        XCTAssertEqual(a1["folder_id"]?.int, 3)
        XCTAssertEqual(a1["title"]?.string, "Mein Titel")
        XCTAssertEqual(a1["first_seen"]?.string, "2026-10-20T08:00:00")
        XCTAssertEqual(a1["local_path"]?.string, "studip/files/a1/Folien (korrigiert).pdf", "relativ zum Container")
        let notesAfter = await backend.handle(LocalRequest(method: "GET", path: "/api/files/a1/annotations"))
        XCTAssertEqual(notesAfter.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 1)
        // in Stud.IP geloescht: bleibt wie in Python stehen
        _ = try await run(db, files: files, now: "2026-10-23T08:00:00", courses: [course], lists: [("c1", [list[1]])])
        let still = try await db.scalar("SELECT COUNT(*) FROM files WHERE id='a1'")?.int
        XCTAssertEqual(still, 1)
        // Bibliothek zeigt die Dateien, Inhalt kommt aus der lokalen Datei
        let lib = await backend.handle(LocalRequest(method: "GET", path: "/api/library"))
        XCTAssertEqual(Set(lib.json?["files"]?.array?.compactMap { $0["id"]?.string } ?? []), ["a1", "a2"])
        let content = await backend.handle(LocalRequest(method: "GET", path: "/api/files/a2/content"))
        XCTAssertEqual(content.status, 200)
        XCTAssertEqual(String(decoding: content.body, as: UTF8.self), "Inhalt a2")
        XCTAssertEqual(content.headers["Content-Type"], "application/pdf", "ohne MIME-Typ aus der Endung geraten")
    }

    /// Dateien aus dem Index von vor S3 werden uebernommen, ohne neu zu laden
    func testAdoptsExistingDownloadsWithoutReloading() async throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let db = backend.context.database
        let root = container.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true)
        let entries = [
            StudIPLocalEntry(id: "x1", courseID: "c1", courseTitle: "Testkurs Alt", folderPath: "Vorlesung", name: "VL 1.pdf", size: 4,
                             changed: "2026-10-19T10:00:00+02:00", mimeType: "application/pdf", relativePath: "files/x1/VL 1.pdf",
                             downloadedAt: "2026-10-20T06:00:00Z"),
            StudIPLocalEntry(id: "x2", courseID: "c9", courseTitle: "Kurs ohne Liste", folderPath: "", name: "Info.txt", size: 2,
                             changed: "1792000000", mimeType: nil, relativePath: "files/x2/Info.txt", downloadedAt: "kaputt"),
        ]
        for e in entries { _ = try files.write(Data("%PDF".utf8), to: files.stored(root.appendingPathComponent(e.relativePath))!) }
        let courses = [StudIPCourse(id: "c1", title: "Testkurs Alt", number: "7", semesterTitle: "WiSe 2026/27")]
        let n = try await db.transaction { c in
            try StudIPLibrary.adopt(c, entries: entries, courses: courses, at: "2026-10-25T14:30:05", base: base,
                                    localPath: { files.stored(root.appendingPathComponent($0.relativePath)) })
        }
        XCTAssertEqual(n, 2)
        let x1Row = try await db.queryOne("SELECT * FROM files WHERE id='x1'")
        let x1 = try XCTUnwrap(x1Row)
        XCTAssertEqual(x1["local_path"]?.string, "Library/Application Support/StudIP/files/x1/VL 1.pdf")
        XCTAssertEqual(x1["downloaded_at"]?.string, "2026-10-20T08:00:00", "UTC -> Ortszeit wie db.now_iso")
        XCTAssertEqual(x1["status"]?.string, "neu")
        XCTAssertEqual(x1["seen_by_user"]?.int, 0)
        XCTAssertEqual(x1["studip_folder"]?.string, "Vorlesung")
        XCTAssertEqual(x1["chdate"]?.int, StudIPLibrary.unixTime("2026-10-19T10:00:00+02:00"))
        let x2Row = try await db.queryOne("SELECT * FROM files WHERE id='x2'")
        let x2 = try XCTUnwrap(x2Row)
        XCTAssertEqual(x2["downloaded_at"]?.string, "2026-10-25T14:30:05", "unlesbarer Zeitpunkt: jetzt")
        XCTAssertEqual(x2["kind"]?.string, "file")
        let c9 = try await db.scalar("SELECT title FROM courses WHERE id='c9'")?.string
        XCTAssertEqual(c9, "Kurs ohne Liste")
        let c1 = try await db.queryOne("SELECT number, semester FROM courses WHERE id='c1'")
        XCTAssertEqual(c1?["number"]?.string, "7")
        // zweiter Start: nichts mehr zu uebernehmen, Nutzerfelder bleiben
        try await db.execute("UPDATE files SET status='gelesen' WHERE id='x1'")
        let again = try await db.transaction { c in
            try StudIPLibrary.adopt(c, entries: entries, courses: courses, at: "2026-10-26T08:00:00", base: base,
                                    localPath: { files.stored(root.appendingPathComponent($0.relativePath)) })
        }
        XCTAssertEqual(again, 0)
        let status = try await db.scalar("SELECT status FROM files WHERE id='x1'")?.string
        XCTAssertEqual(status, "gelesen")
        // naechster Abgleich mit derselben Datei: kein Download
        let remote = StudIPFile(id: "x1", courseID: "c1", name: "VL 1.pdf", size: 4, mimeType: "application/pdf",
                                changed: "2026-10-19T10:00:00+02:00", folderPath: "Vorlesung")
        let wanted = try await db.transaction { try StudIPLibrary.storeFiles($0, [remote], startedAt: "2026-10-26T08:00:00", base: base, localFiles: files) }
        XCTAssertEqual(wanted, [])
        // im Editor: Inhalt aus der vorhandenen Datei
        let content = await backend.handle(LocalRequest(method: "GET", path: "/api/files/x1/content"))
        XCTAssertEqual(content.status, 200)
        XCTAssertEqual(content.body, Data("%PDF".utf8))
    }

    func testForgetDownloadsKeepsRowsAndNotes() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock)
        try await db.execute("INSERT INTO courses(id, title) VALUES ('c1', 'K')")
        try await db.execute("INSERT INTO files(id, course_id, name, local_path, downloaded_at) VALUES ('a', 'c1', 'a.pdf', 'Library/Application Support/StudIP/files/a/a.pdf', 'x')")
        try await db.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('u', '__user__', 'u.pdf', 'Library/Application Support/UniFlow/files/Eigene Dokumente/u.pdf')")
        try await db.execute("INSERT INTO annotations(file_id, data) VALUES ('a', '{}')")
        try await db.execute("INSERT INTO files(id, course_id, name) VALUES ('n', 'c1', 'nie geladen.pdf')")
        let ids = try await db.transaction { try StudIPLibrary.forgetDownloads($0, under: "Library/Application Support/StudIP/") }
        XCTAssertEqual(ids, ["a"], "nur geladene Stud.IP-Dateien")
        let a = try await db.queryOne("SELECT local_path, downloaded_at FROM files WHERE id='a'")
        XCTAssertEqual(a?["local_path"], .null)
        XCTAssertEqual(a?["downloaded_at"], .null)
        let u = try await db.scalar("SELECT local_path FROM files WHERE id='u'")?.string
        XCTAssertNotNil(u, "eigene Dokumente bleiben")
        let notes = try await db.scalar("SELECT COUNT(*) FROM annotations")?.int
        XCTAssertEqual(notes, 1)
    }
}

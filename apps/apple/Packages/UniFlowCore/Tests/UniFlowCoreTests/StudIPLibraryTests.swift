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
    /// `failing`: Downloads, die scheitern (Datei bleibt wie bei einem Netzfehler ungeladen), `abortBeforeDownloads`:
    /// Lauf bricht nach den Dateilisten ab (Netz weg, App beendet), ohne Protokoll.
    /// Rueckgabe: Dateien, die geladen werden muessten, und die geladenen.
    @discardableResult
    private func run(_ db: SQLiteDatabase, files: LocalFiles, now: String, courses: [StudIPCourse],
                     lists: [(String, [StudIPFile])], error: String? = nil, failing: Set<String> = [],
                     abortBeforeDownloads: Bool = false) async throws -> (wanted: [String], loaded: [String]) {
        if let error {
            try await db.transaction { try StudIPLibrary.log($0, startedAt: now, finishedAt: now, ok: false, newFiles: 0, message: StudIPLibrary.failure(error)) }
            return ([], [])
        }
        try await db.transaction { try StudIPLibrary.storeCourses($0, courses, startedAt: now) }
        var wanted: [StudIPFile] = []
        for (_, list) in lists {
            wanted += try await db.transaction { try StudIPLibrary.storeFiles($0, list, startedAt: now, base: base, localFiles: files) }
        }
        if abortBeforeDownloads { return (wanted.map(\.id), []) }
        var loaded: [String] = []
        for f in wanted where f.isDownloadable && !failing.contains(f.id) {
            let rel = "studip/" + StudIPImport.relativePath(for: f)
            _ = try files.write(Data("Inhalt \(f.id)".utf8), to: rel)
            try await db.transaction { try StudIPLibrary.markDownloaded($0, file: f, localPath: rel, at: now) }
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
            // Download scheitert trotz "ladbar" (Netz), wie `download` im Generator
            let failing = Set((round["files"]?.object ?? [:]).values.flatMap { $0.array ?? [] }
                .filter { $0["fail"]?.bool == true }.compactMap { $0["id"]?.string })
            let (wanted, loaded) = try await run(db, files: files, now: round["now"]?.string ?? "", courses: courses, lists: lists,
                                                 error: round["error"]?.string, failing: failing)
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

    /// S3 + S4 zusammen: Abgleich mit erfundenen Stud.IP-Antworten (mehrere Kurse je Fach, Stud.IP-Ordner, Lehrwochen
    /// im Namen), danach ordnen Bibliothek, Meine Module und Moduldetail die Dateien nach Fach, Art und Lehrwoche wie
    /// app/server.py auf derselben Datenbank (Fixture `classified` in studip-import.json, gleiche eingefrorene Uhr).
    func testImportThenModulesMatchPython() async throws {
        let fx = try XCTUnwrap(try fixture("studip-import.json")["classified"])
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let db = backend.context.database
        for round in fx["rounds"]?.array ?? [] {
            let courses = (round["courses"]?.array ?? []).map {
                StudIPCourse(id: $0["id"]?.string ?? "", title: $0["title"]?.string ?? "", number: $0["number"]?.string,
                             semesterTitle: $0["semester"]?.string)
            }
            let lists = courses.map { ($0.id, remoteFiles(round["files"]?[$0.id], course: $0.id)) }
            let (wanted, loaded) = try await run(db, files: files, now: round["now"]?.string ?? "", courses: courses, lists: lists)
            XCTAssertEqual(wanted, round["attempted"]?.array?.compactMap(\.string))
            XCTAssertEqual(loaded, round["downloaded"]?.array?.compactMap(\.string))
        }
        var problems: [String] = []
        for step in fx["steps"]?.array ?? [] {
            let path = step["path"]?.string ?? ""
            let r = await backend.handle(LocalRequest(method: step["method"]?.string ?? "GET", path: path))
            if r.status != step["status"]?.int { problems.append("\(path): Status \(r.status)") }
            if r.json != step["response"] {
                problems.append("\(path):\n  lokal  \(r.json?.jsonString(sortedKeys: true).prefix(2000) ?? "-")\n  Python \(step["response"]?.jsonString(sortedKeys: true).prefix(2000) ?? "-")")
            }
        }
        for table in ["courses", "modules"] {
            let local = JSONValue.array(try await db.rows("SELECT * FROM \(table) ORDER BY id").map(JSONValue.object))
            if local != fx["tables"]?[table] { problems.append("Tabelle \(table):\n  lokal  \(local.jsonString(sortedKeys: true))") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))

        // Was der Vergleich bedeutet: ein Modul je Fach, Kurse eines Fachs zusammen, Dateien nach Woche und Art
        let mods = await backend.handle(LocalRequest(method: "GET", path: "/api/modules")).json?.array ?? []
        XCTAssertEqual(mods.compactMap { $0["name"]?.string },
                       ["Testmathematik I", "Hörsaalübung Testmathematik I", "Grundlagen der Beispieltechnik"],
                       "Begrüßung ohne Modul; Hörsaalübung bleibt wie in Python ein eigenes Modul")
        XCTAssertEqual(mods.first?["courses"], 3)
        let math = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/\(mods.first?["id"]?.int ?? 0)")).json
        let weeks = math?["weeks"]?.array ?? []
        func ids(_ i: Int, _ key: String) -> [String] {
            guard weeks.indices.contains(i) else { return [] }
            return weeks[i][key]?.array?.compactMap { $0["id"]?.string } ?? []
        }
        XCTAssertEqual(weeks.compactMap { $0["label"]?.string },
                       ["Vor Vorlesungsbeginn", "Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
        XCTAssertEqual(ids(1, "vorlesungen"), ["v1"])
        XCTAssertEqual(Set(ids(1, "uebungen")), ["u1", "g1"], "Übung und Gruppenübung derselben Woche")
        XCTAssertEqual(ids(1, "loesungen"), ["u3"], "Lösung Blatt 1 bei Woche 1")
        XCTAssertEqual(Set(ids(2, "vorlesungen")), ["v2", "v3"], "Folien ohne Nummer: Woche aus der Änderungszeit")
        XCTAssertEqual(ids(0, "skripte"), ["v4"])
        XCTAssertEqual(ids(3, "klausuren"), ["v5"])
        let lib = await backend.handle(LocalRequest(method: "GET", path: "/api/library")).json
        let w1 = lib?["files"]?.array?.first { $0["id"] == "w1" }
        XCTAssertEqual(w1?["module_id"], .null, "Begrüßung: kein Modul, Ordner nach Kurs bleibt")
        let u3 = lib?["files"]?.array?.first { $0["id"] == "u3" }
        XCTAssertEqual(u3?["doc_type"], "loesung")
        XCTAssertEqual(u3?["week_hint"], 1)
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

    /// Dateinamen wie studip_sync.safe_name (46ec3d1): zuerst NFC. Verglichen werden die UTF-8-Bytes, weil Swift
    /// Zeichenketten kanonisch vergleicht ("u" + U+0308 ist dort gleich U+00FC).
    func testSafeFileNameIsNFCLikePython() throws {
        let cases = try fixture("studip-import.json")["safe_names"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        var decomposed = 0
        for c in cases {
            let input = try XCTUnwrap(String(bytes: bytes(hex: c["name_hex"]?.string ?? ""), encoding: .utf8))
            if input.unicodeScalars.count != input.precomposedStringWithCanonicalMapping.unicodeScalars.count { decomposed += 1 }
            XCTAssertEqual(hex(StudIPImport.safeFileName(input)), c["safe_hex"]?.string, c["safe"]?.string ?? "")
        }
        XCTAssertGreaterThanOrEqual(decomposed, 4, "Fixture enthaelt zerlegte Namen")
    }

    /// Zerlegter Name aus Stud.IP wie in StudIPSync.run: in der Datenbank wie geliefert (Python speichert f["name"]
    /// unveraendert), der Ablageort aus relativePath (NFC wie safe_name) und gespeichert ueber `LocalFiles.stored`
    /// der geschriebenen Datei. Auf Apple-Systemen zerlegt Foundation den Namen in der Datei-URL wieder (NFD), darum
    /// prueft der Test dort nur kanonische Gleichheit: Datei gefunden, Inhalt lesbar, der naechste Abgleich laedt nichts.
    func testDecomposedNameKeptInDatabaseFileFoundAgain() async throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let db = backend.context.database
        let nfd = "U\u{308}bungsblatt 1.pdf", nfc = "\u{DC}bungsblatt 1.pdf"
        let course = StudIPCourse(id: "c1", title: "Testkurs", number: nil, semesterTitle: "WiSe 2026/27")
        let f = StudIPFile(id: "a1", courseID: "c1", name: nfd, size: 4, mimeType: "application/pdf", changed: "2026-10-19T10:00:00+02:00")
        XCTAssertEqual(hex(StudIPImport.relativePath(for: f)), hex("files/a1/" + nfc), "Ablageort als Text in NFC")
        try await db.transaction { try StudIPLibrary.storeCourses($0, [course], startedAt: "2026-10-20T08:00:00") }
        let wanted = try await db.transaction {
            try StudIPLibrary.storeFiles($0, [f], startedAt: "2026-10-20T08:00:00", base: base, localFiles: files)
        }
        XCTAssertEqual(wanted.map(\.id), ["a1"])
        let target = try files.write(Data("Inhalt a1".utf8), to: "studip/" + StudIPImport.relativePath(for: f))
        let stored = try XCTUnwrap(files.stored(target))
        try await db.transaction { try StudIPLibrary.markDownloaded($0, file: f, localPath: stored, at: "2026-10-20T08:00:00") }
        let row = try await db.queryOne("SELECT name, local_path FROM files WHERE id='a1'")
        XCTAssertEqual(hex(row?["name"]?.string ?? ""), hex(nfd), "Name wie geliefert")
        XCTAssertEqual(row?["local_path"]?.string, "studip/files/a1/" + nfc, "kanonisch gleich (Swift vergleicht so)")
        XCTAssertTrue(files.exists(stored: row?["local_path"]?.string))
        let content = await backend.handle(LocalRequest(method: "GET", path: "/api/files/a1/content"))
        XCTAssertEqual(String(decoding: content.body, as: UTF8.self), "Inhalt a1")
        let again = try await db.transaction {
            try StudIPLibrary.storeFiles($0, [f], startedAt: "2026-10-21T08:00:00", base: base, localFiles: files)
        }
        XCTAssertEqual(again.map(\.id), [], "Datei gefunden, kein zweiter Download")
    }

    private func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }

    private func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
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

    /// Neue Fassung in Stud.IP: Bricht der Lauf vor ihrem Download ab oder scheitert der Download, laedt der naechste
    /// Abgleich sie trotzdem (vorher stand die neue Aenderungszeit schon in der Datenbank, die alte Datei blieb still)
    func testNewVersionIsLoadedAfterAbortOrFailedDownload() async throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock)
        let course = StudIPCourse(id: "c1", title: "Testkurs", number: nil, semesterTitle: "WiSe 2026/27")
        func version(_ changed: String, size: Int) -> [StudIPFile] {
            [StudIPFile(id: "a1", courseID: "c1", name: "Folien.pdf", size: size, mimeType: "application/pdf", changed: changed)]
        }
        let v1 = version("2026-10-19T10:00:00+02:00", size: 10), v2 = version("2026-10-22T10:00:00+02:00", size: 12)
        let v3 = version("2026-10-23T10:00:00+02:00", size: 14)
        let first = try await run(db, files: files, now: "2026-10-20T08:00:00", courses: [course], lists: [("c1", v1)])
        XCTAssertEqual(first.loaded, ["a1"])
        func row() async throws -> [String: JSONValue] {
            try await db.rows("SELECT chdate, size, mime, downloaded_at FROM files WHERE id='a1'").first ?? [:]
        }
        let loaded1 = try await row()

        // Lauf bricht nach der Dateiliste ab (Netz weg, Sitzung abgelaufen, App beendet): alter Stand bleibt
        let aborted = try await run(db, files: files, now: "2026-10-22T12:00:00", courses: [course], lists: [("c1", v2)],
                                    abortBeforeDownloads: true)
        XCTAssertEqual(aborted.wanted, ["a1"])
        let afterAbort = try await row()
        XCTAssertEqual(afterAbort, loaded1, "Aenderungszeit und Groesse erst mit dem Download")
        let retried = try await run(db, files: files, now: "2026-10-22T13:00:00", courses: [course], lists: [("c1", v2)])
        XCTAssertEqual(retried.loaded, ["a1"], "naechster Abgleich laedt die neue Fassung")
        let loaded2 = try await row()
        XCTAssertEqual(loaded2["chdate"]?.int, StudIPLibrary.unixTime("2026-10-22T10:00:00+02:00"))
        XCTAssertEqual(loaded2["size"]?.int, 12)
        XCTAssertEqual(loaded2["downloaded_at"]?.string, "2026-10-22T13:00:00")

        // einzelner Download scheitert (affectsOnlyItem): ebenso
        let failed = try await run(db, files: files, now: "2026-10-23T12:00:00", courses: [course], lists: [("c1", v3)], failing: ["a1"])
        XCTAssertEqual(failed.wanted, ["a1"])
        XCTAssertEqual(failed.loaded, [])
        let afterFailure = try await row()
        XCTAssertEqual(afterFailure, loaded2)
        let again = try await run(db, files: files, now: "2026-10-23T13:00:00", courses: [course], lists: [("c1", v3)])
        XCTAssertEqual(again.loaded, ["a1"])
        let quiet = try await run(db, files: files, now: "2026-10-23T14:00:00", courses: [course], lists: [("c1", v3)])
        XCTAssertEqual(quiet.wanted, [], "danach unveraendert")
    }

    /// Kopie ("Duplizieren") einer Stud.IP-Datei teilt sich deren Datei. Nach "Abmelden und Dateien löschen" und
    /// erneutem Abgleich oeffnet sie sich wieder, ihre Notizen bleiben.
    func testDuplicateOpensAgainAfterDownloadsWereRemoved() async throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let db = backend.context.database
        let course = StudIPCourse(id: "c1", title: "Testkurs", number: nil, semesterTitle: "WiSe 2026/27")
        let list = [StudIPFile(id: "a1", courseID: "c1", name: "Folien.pdf", size: 10, mimeType: "application/pdf",
                               changed: "2026-10-19T10:00:00+02:00")]
        _ = try await run(db, files: files, now: "2026-10-20T08:00:00", courses: [course], lists: [("c1", list)])
        let dup = await backend.handle(LocalRequest(method: "PATCH", path: "/api/library/files/a1", body: Data(#"{"duplicate": true}"#.utf8)))
        let copy = try XCTUnwrap(dup.json?["id"]?.string)
        let put = await backend.handle(LocalRequest(method: "PUT", path: "/api/files/\(copy)/annotations", query: [.init("base_version", "0")],
                                                    body: Data(#"{"pages": {"p1": {"objects": [{"id": "k"}]}}}"#.utf8)))
        XCTAssertEqual(put.status, 200, String(decoding: put.body, as: UTF8.self))
        let before = await backend.handle(LocalRequest(method: "GET", path: "/api/files/\(copy)/content"))
        XCTAssertEqual(before.status, 200)

        // "Abmelden und Dateien löschen": Dateien weg, Ablageorte vergessen (Original und Kopie)
        try FileManager.default.removeItem(at: container.appendingPathComponent("studip"))
        let forgotten = try await db.transaction { try StudIPLibrary.forgetDownloads($0, under: "studip/") }
        XCTAssertEqual(Set(forgotten), ["a1", copy])
        let gone = await backend.handle(LocalRequest(method: "GET", path: "/api/files/\(copy)/content"))
        XCTAssertEqual(gone.status, 404)

        let again = try await run(db, files: files, now: "2026-10-21T08:00:00", courses: [course], lists: [("c1", list)])
        XCTAssertEqual(again.loaded, ["a1"], "nur das Original wird geladen")
        for id in ["a1", copy] {
            let content = await backend.handle(LocalRequest(method: "GET", path: "/api/files/\(id)/content"))
            XCTAssertEqual(content.status, 200, id)
            XCTAssertEqual(String(decoding: content.body, as: UTF8.self), "Inhalt a1", id)
        }
        let copyRow = try await db.queryOne("SELECT local_path, downloaded_at, chdate, title FROM files WHERE id=?", [.text(copy)])
        XCTAssertEqual(copyRow?["downloaded_at"]?.string, "2026-10-21T08:00:00")
        XCTAssertEqual(copyRow?["title"]?.string, "Folien.pdf (Kopie)", "sonst bleibt die Kopie unveraendert")
        let notes = await backend.handle(LocalRequest(method: "GET", path: "/api/files/\(copy)/annotations"))
        XCTAssertEqual(notes.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 1, "Notizen der Kopie bleiben")
        // eigene Dokumente bekommen nie den Ablageort einer Stud.IP-Datei
        try await db.execute("INSERT INTO files(id, course_id, name, download_url) VALUES ('u1', '__user__', 'x.pdf', ?)",
                             [.text(StudIPLibrary.downloadURL(base: base, fileID: "a1"))])
        _ = try await db.transaction { try StudIPLibrary.forgetDownloads($0, under: "studip/") }
        try FileManager.default.removeItem(at: container.appendingPathComponent("studip"))
        _ = try await run(db, files: files, now: "2026-10-22T08:00:00", courses: [course], lists: [("c1", list)])
        let own = try await db.scalar("SELECT local_path FROM files WHERE id='u1'")
        XCTAssertEqual(own, .null)
    }
}

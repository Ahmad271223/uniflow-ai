import Foundation
import XCTest
@testable import UniFlowCore

private func repoFile(_ relative: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent(relative))
}

private func fixture(_ name: String) throws -> JSONValue {
    try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/local-backend/\(name)"))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

/// Kennungen wie `Frozen` in tools/gen-local-backend-fixture.py: n-te Kennung = 8 Hex-Ziffern Zaehler + 24 Nullen
final class HexCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    static func hex(_ n: Int) -> String { String(format: "%08x", n) + String(repeating: "0", count: 24) }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return HexCounter.hex(n)
    }
}

/// Seitenzahl wie pypdf fuer die kleinen Test-PDFs (zaehlt "/Type /Page" ohne "s"); keine Bildumwandlung
struct CountingTools: LocalDocumentTools {
    func pdfPageCount(_ data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        let n = text.components(separatedBy: "/Type /Page").dropFirst().filter { !$0.hasPrefix("s") }.count
        return n > 0 ? n : nil
    }

    func pdfFromImage(_ data: Data) -> Data? { nil }
}

func tempContainer(_ test: XCTestCase) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

/// Alle Dateien unter einem Ordner (relative Pfade, sortiert)
func listFiles(_ root: URL) -> [String] {
    let base = LocalFiles.resolved(root)
    var out: [String] = []
    if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(String(LocalFiles.resolved(url).dropFirst(base.count + 1)))
        }
    }
    return out.sorted()
}

/// Zeilen einer Tabelle als JSON (wie `dict(row)` in Python)
func tableRows(_ db: SQLiteDatabase, _ sql: String) async throws -> JSONValue {
    .array(try await db.rows(sql).map(JSONValue.object))
}

// MARK: - Bibliothek, Dateien, Notizen gegen app/server.py

final class LocalLibraryFixtureTests: XCTestCase {

    private func request(_ step: JSONValue) -> LocalRequest {
        let method = step["method"]?.string ?? "GET"
        let url = URL(string: "uniflow-local://device" + (step["path"]?.string ?? ""))!
        if let form = step["form"] {
            let b = "uniflow-fixture"
            var body = Data()
            let fields = form["fields"]?.object ?? [:]
            // Reihenfolge der Felder spielt fuer FastAPI keine Rolle
            for k in fields.keys.sorted() {
                body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(fields[k]?.string ?? "")\r\n".utf8))
            }
            for (k, f) in form["files"]?.object ?? [:] {
                body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"; filename=\"\(f["name"]?.string ?? "")\"\r\nContent-Type: \(f["type"]?.string ?? "")\r\n\r\n".utf8))
                body.append(Data(base64Encoded: f["base64"]?.string ?? "") ?? Data())
                body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(b)--\r\n".utf8))
            return LocalRequest(method: method, url: url, headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: body)
        }
        let raw = step["raw"]?.string.map { Data($0.utf8) }
        return LocalRequest(method: method, url: url, headers: raw == nil ? [:] : ["Content-Type": "application/json"], body: raw)
    }

    /// Datenbank und Dateien wie im Fixture, Backend mit eingefrorener Uhr und Kennungen
    private func seeded(_ fx: JSONValue) async throws -> (LocalBackend, URL) {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "", tools: CountingTools())
        let counter = HexCounter()
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files, newHex: { counter.next() })
        let seed = fx["seed"] ?? .null
        for table in ["courses", "folders", "files", "annotations", "annotation_versions", "sync_log"] {
            for row in seed[table]?.array ?? [] {
                let o = row.object ?? [:]
                let cols = o.keys.sorted()
                try await backend.context.database.execute(
                    "INSERT INTO \(table)(\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))",
                    cols.map { SQLiteValue(json: o[$0]!) ?? .null })
            }
        }
        for (rel, b64) in fx["disk_seed"]?.object ?? [:] {
            _ = try files.write(Data(base64Encoded: b64.string ?? "")!, to: rel)
        }
        return (backend, container)
    }

    /// Listen ohne feste Reihenfolge bei gleichem Sortierwert (gleiche chdate/deleted_at) nach ID ordnen
    private func normalized(_ v: JSONValue, path: String, s4: [String], unordered: Bool) -> JSONValue {
        func byID(_ a: [JSONValue]) -> [JSONValue] { a.sorted { ($0["id"]?.string ?? "") < ($1["id"]?.string ?? "") } }
        func strip(_ f: JSONValue) -> JSONValue {
            guard var o = f.object else { return f }
            for k in s4 { o[k] = nil }
            return .object(o)
        }
        if path == "/api/library", var o = v.object {
            o["files"] = .array(byID(o["files"]?.array ?? []).map(strip))
            o["trash"] = .array(byID(o["trash"]?.array ?? []))
            return .object(o)
        }
        if unordered, let a = v.array { return .array(byID(a)) }
        return v
    }

    func testStepsMatchPythonServer() async throws {
        let fx = try fixture("library-files.json")
        let (backend, container) = try await seeded(fx)
        let s4 = fx["s4_fields"]?.array?.compactMap(\.string) ?? []
        let unordered = Set(fx["unordered"]?.array?.compactMap(\.string) ?? [])
        var problems: [String] = []
        for (i, step) in (fx["steps"]?.array ?? []).enumerated() {
            let method = step["method"]?.string ?? "", fullPath = step["path"]?.string ?? ""
            let path = String(fullPath.split(separator: "?", maxSplits: 1).first ?? "")
            let label = "Schritt \(i): \(method) \(fullPath)"
            let r = await backend.handle(request(step))
            if let expect = fx["expect"]?["\(method) \(fullPath)"] {
                if r.status != expect["status"]?.int { problems.append("\(label): Status \(r.status) statt \(expect["status"]?.int ?? 0)") }
                if r.json?["detail"]?.string?.isEmpty != false { problems.append("\(label): Meldung fehlt") }
                continue
            }
            guard r.status == step["status"]?.int else {
                problems.append("\(label): Status \(r.status) statt \(step["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                continue
            }
            if let expected = step["response"] {
                guard let local = r.json else { problems.append("\(label): keine JSON-Antwort"); continue }
                if r.status == 422 {
                    // gleicher Fehlertyp und Ort wie FastAPI
                    let a = local["detail"]?.array?.first, b = expected["detail"]?.array?.first
                    if a?["type"] != b?["type"] || a?["loc"] != b?["loc"] { problems.append("\(label): 422 \(local) statt \(expected)") }
                    continue
                }
                if path == "/api/dashboard" {
                    for k in ["new_files", "new_total", "last_sync"] where local[k] != expected[k] {
                        problems.append("\(label): \(k) \(local[k]?.jsonString() ?? "-") statt \(expected[k]?.jsonString() ?? "-")")
                    }
                    continue
                }
                let free = method == "GET" && unordered.contains(path)
                let a = normalized(local, path: path, s4: s4, unordered: free), b = normalized(expected, path: path, s4: s4, unordered: free)
                if a != b { problems.append("\(label):\n  lokal  \(a.jsonString(sortedKeys: true).prefix(1500))\n  Python \(b.jsonString(sortedKeys: true).prefix(1500))") }
                if path == "/api/library" {
                    for f in local["files"]?.array ?? [] where s4.contains(where: { f[$0] == nil }) { problems.append("\(label): S4-Feld fehlt in \(f)") }
                    let ch = (local["files"]?.array ?? []).map { $0["chdate"]?.double ?? 0 }
                    if ch != ch.sorted(by: >) { problems.append("\(label): nicht nach chdate absteigend") }
                }
            } else {
                // Datei: Kopfzeilen und Bytes
                let headers = Dictionary(r.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
                for (k, v) in step["headers"]?.object ?? [:] where headers[k] != v.string {
                    problems.append("\(label): \(k) \(headers[k] ?? "-") statt \(v.string ?? "-")")
                }
                for k in ["content-disposition", "content-security-policy"] where step["headers"]?[k] == nil && headers[k] != nil {
                    problems.append("\(label): \(k) zu viel")
                }
                if r.body != Data(base64Encoded: step["base64"]?.string ?? "") { problems.append("\(label): andere Bytes") }
            }
        }
        // Tabellen und Dateien danach
        let db = backend.context.database
        let queries = ["files": "SELECT * FROM files ORDER BY id", "courses": "SELECT * FROM courses ORDER BY id",
                       "folders": "SELECT * FROM folders ORDER BY id", "modules": "SELECT * FROM modules ORDER BY id",
                       "annotations": "SELECT file_id, data, updated_at, version FROM annotations ORDER BY file_id",
                       "annotation_versions": "SELECT file_id, version, data, created_at FROM annotation_versions ORDER BY file_id, version"]
        for (name, sql) in queries.sorted(by: { $0.key < $1.key }) {
            let local = try await tableRows(db, sql)
            let expected = fx["tables"]?[name] ?? .null
            if local != expected {
                let l = local.array ?? [], e = expected.array ?? []
                let diff = zip(l, e).first { $0 != $1 }.map { "\n  lokal  \($0.0.jsonString(sortedKeys: true))\n  Python \($0.1.jsonString(sortedKeys: true))" }
                problems.append("Tabelle \(name): \(l.count) statt \(e.count) Zeilen\(diff ?? "")")
            }
        }
        XCTAssertEqual(listFiles(container), fx["disk"]?.array?.compactMap(\.string) ?? [], "Dateien auf der Platte")
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// Endungen wie mimetypes.guess_type (nur die, die ueberall gleich sind)
    func testMimeGuessLikePython() throws {
        let fx = try fixture("library-files.json")
        for (name, type) in fx["mime_guess"]?.object ?? [:] {
            XCTAssertEqual(LocalFileResponse.guess(name), type.string, name)
        }
    }

    func testContentDispositionLikeStarlette() {
        XCTAssertEqual(LocalFileResponse.quote("Folien 1.pdf"), "Folien%201.pdf")
        XCTAssertEqual(LocalFileResponse.quote("a/b_c-d.e~f"), "a/b_c-d.e~f")
        XCTAssertEqual(LocalFileResponse.quote("ä\""), "%C3%A4%22")
        XCTAssertEqual(LocalFileResponse.suffix("x.tar.gz"), ".gz")
        XCTAssertNil(LocalFileResponse.suffix(".png"))
        XCTAssertNil(LocalFileResponse.suffix("a."))
        XCTAssertEqual(LibraryEndpoints.stem("ordner/Skript.final.pdf"), "Skript.final")
    }
}

// MARK: - Notizen, Pfade, Dateiablage

final class LocalAnnotationsTests: XCTestCase {

    private func backend(files: LocalFiles? = nil) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        try await b.context.database.execute("INSERT INTO courses(id, title) VALUES ('k1', 'Testkurs')")
        try await b.context.database.execute("INSERT INTO files(id, course_id, name) VALUES ('d1', 'k1', 'Blatt.pdf')")
        return b
    }

    private func put(_ b: LocalBackend, _ body: String, base: Int?) async -> LocalResponse {
        await b.handle(LocalRequest(method: "PUT", path: "/api/files/d1/annotations",
                                    query: base.map { [.init("base_version", String($0))] } ?? [], body: Data(body.utf8)))
    }

    /// Zwei Geraete mit demselben Stand: das zweite bekommt 409 mit dem neueren Stand und verliert nichts
    func testConflictReturnsCurrentVersionAndKeepsData() async throws {
        let b = try await backend()
        let first = await put(b, #"{"pages": {"p1": {"objects": [{"id": "a"}]}}}"#, base: 0)
        XCTAssertEqual(first.json, ["ok": true, "version": 1])
        let stale = await put(b, #"{"pages": {}}"#, base: 0)
        XCTAssertEqual(stale.status, 409)
        XCTAssertEqual(stale.json?["version"], 1)
        XCTAssertEqual(stale.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 1)
        let get = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations"))
        XCTAssertEqual(get.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 1, "veralteter Stand ueberschreibt nichts")
        // ohne base_version: kein Konflikt (Wiederherstellen, aelteres Web)
        let forced = await put(b, #"{"pages": {}}"#, base: nil)
        XCTAssertEqual(forced.json?["version"], 2)
    }

    func testAtMostThirtyVersionsAndRestore() async throws {
        let b = try await backend()
        for i in 1...35 { _ = await put(b, #"{"n": \#(i)}"#, base: i - 1) }
        let listed = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations/versions"))
        let versions = try XCTUnwrap(listed.json?.array)
        XCTAssertEqual(versions.count, 30)
        XCTAssertEqual(versions.first?["version"], 35)
        XCTAssertEqual(versions.last?["version"], 6)
        let restored = await b.handle(LocalRequest(method: "POST", path: "/api/files/d1/annotations/restore/10"))
        XCTAssertEqual(restored.json?["version"], 36)
        let now = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations"))
        XCTAssertEqual(now.json?["data"]?["n"], 10)
        let gone = await b.handle(LocalRequest(method: "POST", path: "/api/files/d1/annotations/restore/2"))
        XCTAssertEqual(gone.status, 404)
    }

    /// Der gespeicherte Text ist derselbe wie bei Python (json.dumps mit ensure_ascii=False)
    func testStoredTextLikePythonDumps() async throws {
        let b = try await backend()
        _ = await put(b, #"{"a":1.0,"b":[1e-7,2],"t":"Ä é 😀\n\u0001","a":3}"#, base: 0)
        let text = try await b.context.database.scalar("SELECT data FROM annotations WHERE file_id='d1'")?.string
        XCTAssertEqual(text, "{\"a\": 3, \"b\": [1e-07, 2], \"t\": \"Ä é 😀\\n\\u0001\"}")
    }

    /// Unbekanntes Dokument: 409 ohne version (die App behaelt die Notizen im Journal), nichts gespeichert
    func testUnknownDocumentIsNotAConflict() async throws {
        let b = try await backend()
        let r = await b.handle(LocalRequest(method: "PUT", path: "/api/files/fremd/annotations", query: [.init("base_version", "0")],
                                            body: Data(#"{"pages": {}}"#.utf8)))
        XCTAssertEqual(r.status, 409)
        XCTAssertNil(r.json?["version"])
        XCTAssertNotNil(r.json?["detail"]?.string)
        let n = try await b.context.database.scalar("SELECT COUNT(*) FROM annotations")?.int
        XCTAssertEqual(n, 0)
    }

    func testStoredPathsAreRelativeAndCannotEscape() throws {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow")
        XCTAssertEqual(files.ownDocumentsDirectory, "Library/Application Support/UniFlow/files/Eigene Dokumente")
        XCTAssertEqual(files.assetsDirectory(fileID: "f1"), "Library/Application Support/UniFlow/assets/f1")
        let url = try files.write(Data("x".utf8), to: "Library/Application Support/StudIP/files/f1/a b.pdf")
        XCTAssertEqual(files.stored(url), "Library/Application Support/StudIP/files/f1/a b.pdf", "relativ zum Container")
        XCTAssertTrue(files.exists(stored: "Library/Application Support/StudIP/files/f1/a b.pdf"))
        for bad in ["/etc/passwd", "../aussen.pdf", "Library/../../x", "~/x", "a\\b", ""] {
            XCTAssertNil(files.url(stored: bad), bad)
            XCTAssertFalse(files.exists(stored: bad), bad)
        }
        XCTAssertNil(files.stored(URL(fileURLWithPath: "/tmp/fremd.pdf")))
        // Symlink nach aussen: gilt als nicht vorhanden
        let outside = try tempContainer(self).appendingPathComponent("geheim.pdf")
        try Data("y".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("link"), withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertNil(files.url(stored: "link/geheim.pdf"))
        // neuer Container (Neuinstallation, Backup): derselbe relative Pfad findet die Datei dort
        let moved = try tempContainer(self)
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Library/Application Support/StudIP/files/f1"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: moved.appendingPathComponent("Library/Application Support/StudIP/files/f1/a b.pdf"))
        XCTAssertTrue(LocalFiles(container: moved, dataDirectory: "").exists(stored: "Library/Application Support/StudIP/files/f1/a b.pdf"))
    }

    func testWithoutFileStorageContentIsMissingAndUploadUnavailable() async throws {
        let b = try await backend()
        try await b.context.database.execute("UPDATE files SET local_path='x/Blatt.pdf' WHERE id='d1'")
        let content = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/content"))
        XCTAssertEqual(content.status, 404)
        let form = "--b\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\nPNG\r\n--b--\r\n"
        let upload = await b.handle(LocalRequest(method: "POST", path: "/api/files/d1/assets",
                                                 headers: ["Content-Type": "multipart/form-data; boundary=b"], body: Data(form.utf8)))
        XCTAssertEqual(upload.status, 503)
        // Notizbuch ohne Datei geht auch ohne Ablage
        let nb = "--b\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nnotebook\r\n--b--\r\n"
        let created = await b.handle(LocalRequest(method: "POST", path: "/api/notebooks",
                                                  headers: ["Content-Type": "multipart/form-data; boundary=b"], body: Data(nb.utf8)))
        XCTAssertEqual(created.status, 200)
        XCTAssertEqual(created.json?["title"], "Neues Notizbuch")
        let ann = await b.handle(LocalRequest(method: "GET", path: "/api/files/\(created.json?["id"]?.string ?? "")/annotations"))
        XCTAssertEqual(ann.json?["data"]?["pageOrder"]?.array?.first?["template"], "blank")
    }

    func testS3EndpointsAreReal() async throws {
        let b = try await backend()
        let real: [(String, String)] = [
            ("GET", "/api/library"), ("GET", "/api/courses"), ("PATCH", "/api/courses/k1"), ("GET", "/api/files"),
            ("GET", "/api/files/d1"), ("PATCH", "/api/files/d1"), ("GET", "/api/files/d1/content"),
            ("GET", "/api/files/d1/annotations"), ("PUT", "/api/files/d1/annotations"), ("GET", "/api/files/d1/annotations/versions"),
            ("POST", "/api/files/d1/annotations/restore/1"), ("POST", "/api/files/d1/assets"), ("GET", "/api/assets/d1/a.png"),
            ("POST", "/api/files/mark-seen"), ("POST", "/api/files/d1/opened"), ("POST", "/api/files/d1/favorite"),
            ("POST", "/api/folders"), ("PATCH", "/api/folders/1"), ("DELETE", "/api/folders/1"), ("POST", "/api/notebooks"),
            ("PATCH", "/api/library/files/d1"), ("GET", "/api/sync/status"),
        ]
        for (m, p) in real {
            let route = try XCTUnwrap(b.route(method: m, path: p), "\(m) \(p)")
            XCTAssertFalse(route.placeholder, "\(m) \(p)")
        }
        // Uebersicht bleibt Platzhalter bis S6, kennt aber schon die neuen Dateien
        XCTAssertEqual(b.route(method: "GET", path: "/api/dashboard")?.placeholder, true)
        let dash = await b.handle(LocalRequest(method: "GET", path: "/api/dashboard"))
        XCTAssertEqual(dash.json?["new_total"], 1)
        XCTAssertEqual(dash.json?["new_files"]?.array?.first?["id"], "d1")
    }
}

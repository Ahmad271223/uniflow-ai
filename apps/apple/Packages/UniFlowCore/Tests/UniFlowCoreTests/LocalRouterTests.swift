import Foundation
import XCTest
@testable import UniFlowCore

/// Router des lokalen Backends: Pfadmuster, Vorrang, Query, JSON-Rumpf, Multipart, Fehler wie FastAPI.
final class LocalRouterTests: XCTestCase {

    private func context() throws -> LocalContext {
        LocalContext(database: try SQLiteDatabase(path: SQLiteDatabase.inMemory), clock: .fixed(berlin: "2026-10-25T14:30:05")!)
    }

    private func respond(_ r: LocalRouter, _ method: String, _ url: String, body: Data? = nil,
                         headers: [String: String] = [:]) async throws -> LocalResponse {
        await r.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + url)!, headers: headers, body: body),
                       context: try context())
    }

    /// Antwortet mit Modul, Muster und den Platzhalterwerten
    private func echo(_ tag: String) -> LocalHandler {
        { req, _ in
            .json(["tag": .string(tag), "params": .object(req.pathParams.mapValues { .string($0) })])
        }
    }

    // MARK: Muster

    func testPatternMatchesParamsAndLiterals() async throws {
        let r = LocalRouter()
        r.get("/api/files/{file_id}/content", echo("content"))
        r.get("/api/assets/{file_id}/{name}", echo("asset"))
        let a = try await respond(r, "GET", "/api/files/f%201/content").json
        XCTAssertEqual(a?["tag"], "content")
        XCTAssertEqual(a?["params"]?["file_id"], "f 1", "Pfad wird prozent-dekodiert")
        let b = try await respond(r, "GET", "/api/assets/f1/bild.png").json
        XCTAssertEqual(b?["params"], ["file_id": "f1", "name": "bild.png"])
        // falsche Laenge oder leerer Platzhalter passen nicht
        let short = try await respond(r, "GET", "/api/files/f1")
        XCTAssertEqual(short.status, 404)
        XCTAssertEqual(short.json, ["detail": "Not Found"])
        let r1 = try await respond(r, "GET", "/api/files//content")
        XCTAssertEqual(r1.status, 404)
        let r2 = try await respond(r, "GET", "/api/files/f1/content/")
        XCTAssertEqual(r2.status, 200, "abschliessender Schraegstrich")
        XCTAssertEqual(LocalPathPattern("/api/files/{file_id}/content").shape, "/api/files/{}/content")
    }

    func testLiteralBeatsParameterRegardlessOfOrder() async throws {
        let r = LocalRouter()
        r.post("/api/tasks/{task_id:int}", echo("param"))
        r.post("/api/tasks/skip", echo("literal"))
        r.get("/api/tasks/{task_id:int}", echo("get-param"))
        r.get("/api/tasks/open", echo("open"))
        let r3 = try await respond(r, "POST", "/api/tasks/skip")
        XCTAssertEqual(r3.json?["tag"], "literal")
        let r4 = try await respond(r, "POST", "/api/tasks/5")
        XCTAssertEqual(r4.json?["tag"], "param")
        let r5 = try await respond(r, "GET", "/api/tasks/open")
        XCTAssertEqual(r5.json?["tag"], "open")
        let r6 = try await respond(r, "GET", "/api/tasks/7")
        XCTAssertEqual(r6.json?["params"]?["task_id"], "7")
    }

    func testRealEndpointReplacesPlaceholder() async throws {
        let r = LocalRouter()
        r.get("/api/library", placeholder: true, echo("leer"))
        let r7 = try await respond(r, "GET", "/api/library")
        XCTAssertEqual(r7.json?["tag"], "leer")
        r.get("/api/library", echo("echt"))                        // spaeter registriert, trotzdem vorrangig
        let r8 = try await respond(r, "GET", "/api/library")
        XCTAssertEqual(r8.json?["tag"], "echt")
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertEqual(r.route(method: "GET", path: "/api/library")?.route.placeholder, false)
    }

    func testDuplicateRealEndpointsAreConflicts() throws {
        enum A: LocalEndpointModule {
            static let name = "A"
            static func register(on router: LocalRouter) { router.get("/api/x/{id}") { _, _ in .ok } }
        }
        enum B: LocalEndpointModule {
            static let name = "B"
            static func register(on router: LocalRouter) { router.get("/api/x/{other}") { _, _ in .ok } }
        }
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        XCTAssertThrowsError(try LocalBackend(database: db, modules: [A.self, B.self])) { error in
            XCTAssertTrue("\(error)".contains("GET /api/x/{other}: A und B"), "\(error)")
        }
        XCTAssertNoThrow(try LocalBackend(database: db, modules: [A.self]))
    }

    func testStandardModulesHaveNoConflicts() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        XCTAssertTrue(backend.router.conflicts.isEmpty)
        // jedes Modul hat seine Pfade selbst eingetragen
        let modules = Set(backend.router.allRoutes.map(\.module))
        XCTAssertEqual(modules, Set(LocalBackend.standardModules.map { $0.name }))
        XCTAssertFalse(backend.router.allRoutes.contains { $0.module == "?" })
    }

    func testMethodNotAllowedAndIntValidation() async throws {
        let r = LocalRouter()
        r.get("/api/modules/{module_id:int}", echo("modul"))
        let wrong = try await respond(r, "DELETE", "/api/modules/3")
        XCTAssertEqual(wrong.status, 405)
        XCTAssertEqual(wrong.json, ["detail": "Method Not Allowed"])
        let bad = try await respond(r, "GET", "/api/modules/abc")
        XCTAssertEqual(bad.status, 422)
        XCTAssertEqual(bad.json?["detail"]?.array?.first?["loc"], ["path", "module_id"])
        XCTAssertEqual(bad.json?["detail"]?.array?.first?["type"], "int_parsing")
        let r9 = try await respond(r, "GET", "/api/modules/12")
        XCTAssertEqual(r9.status, 200)
    }

    func testErrorsBecomeDetailResponses() async throws {
        let r = LocalRouter()
        r.get("/api/a") { _, _ in throw LocalHTTPError.notFound("Paket nicht gefunden") }
        r.get("/api/b") { _, ctx in
            _ = try await ctx.database.query("SELECT * FROM gibt_es_nicht")
            return .ok
        }
        r.get("/api/c") { _, _ in throw CocoaError(.fileNoSuchFile) }
        let a = try await respond(r, "GET", "/api/a")
        XCTAssertEqual(a.status, 404)
        XCTAssertEqual(a.json, ["detail": "Paket nicht gefunden"])
        XCTAssertEqual(a.headers["Content-Type"], "application/json")
        let b = try await respond(r, "GET", "/api/b")
        XCTAssertEqual(b.status, 500)
        XCTAssertTrue(b.json?["detail"]?.string?.contains("gibt_es_nicht") == true)
        let c = try await respond(r, "GET", "/api/c")
        XCTAssertEqual(c.status, 500)
        XCTAssertNotNil(c.json?["detail"]?.string)
    }

    // MARK: Query und Rumpf

    func testQueryParsingLikeStarlette() {
        let req = LocalRequest(method: "get", url: URL(string: "uniflow-local://device/api/search?q=lineare+Algebra%20I&x=&q2=a%26b&d=1&d=2")!)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/api/search")
        XCTAssertEqual(req.query("q"), "lineare Algebra I")
        XCTAssertEqual(req.query("x"), "", "leere Werte bleiben")
        XCTAssertEqual(req.query("q2"), "a&b")
        XCTAssertEqual(req.query("d"), "2", "letzter Wert gilt")
        XCTAssertNil(req.query("fehlt"))
        XCTAssertThrowsError(try req.requiredQuery("fehlt")) { e in
            XCTAssertEqual((e as? LocalHTTPError)?.status, 422)
        }
        let flags = LocalRequest(method: "GET", path: "/x", query: [.init("due", "true"), .init("b", "0"), .init("c", "vielleicht")])
        XCTAssertEqual(try flags.boolQuery("due"), true)
        XCTAssertEqual(try flags.boolQuery("b"), false)
        XCTAssertNil(try flags.boolQuery("nichts"))
        XCTAssertThrowsError(try flags.boolQuery("c"))
    }

    func testBodyValidationLikeFastAPI() throws {
        func req(_ s: String?) -> LocalRequest { LocalRequest(method: "PUT", path: "/x", body: s.map { Data($0.utf8) } ?? Data()) }
        XCTAssertEqual(try req(#"{"a": 1}"#).objectBody(), ["a": 1])
        XCTAssertEqual(try req(nil).objectBody(orEmpty: true), [:])
        for (text, type) in [(nil, "missing"), ("[1]", "dict_type"), ("{kaputt", "json_invalid")] as [(String?, String)] {
            XCTAssertThrowsError(try req(text).objectBody()) { e in
                let err = e as? LocalHTTPError
                XCTAssertEqual(err?.status, 422)
                XCTAssertEqual(err?.detail.array?.first?["type"]?.string, type)
            }
        }
        let ordered = try req(#"{"b": 1, "a": 2.0, "b": 3}"#).pythonObjectBody()
        XCTAssertEqual(ordered.map(\.key), ["b", "a"])
        XCTAssertEqual(ordered.map(\.value), [.int("3"), .float(2)])
    }

    // MARK: Multipart

    private func multipartBody(_ boundary: String, _ parts: [(String, String?, String?, Data)], lineBreak: String = "\r\n") -> Data {
        var d = Data()
        for (name, filename, type, data) in parts {
            var head = "--\(boundary)\(lineBreak)Content-Disposition: form-data; name=\"\(name)\""
            if let filename { head += "; filename=\"\(filename)\"" }
            head += lineBreak
            if let type { head += "Content-Type: \(type)\(lineBreak)" }
            d.append(Data((head + lineBreak).utf8))
            d.append(data)
            d.append(Data(lineBreak.utf8))
        }
        d.append(Data("--\(boundary)--\(lineBreak)".utf8))
        return d
    }

    func testMultipartFieldsAndBinaryFile() throws {
        // Bytes mit CRLF und "--" im Inhalt duerfen die Grenze nicht verwirren
        let pdf = Data("%PDF-1.4\r\n--nicht-die-grenze\r\n\u{00}\u{FF}ende".utf8)
        let body = multipartBody("uniflow-ABC", [("kind", nil, nil, Data("pdf".utf8)), ("title", nil, nil, Data("Übung 1".utf8)),
                                                 ("upload", "Übung 1.pdf", "application/pdf", pdf), ("leer", nil, nil, Data())])
        let form = try MultipartForm.parse(body, contentType: "multipart/form-data; boundary=uniflow-ABC")
        XCTAssertEqual(form.fields, ["kind": "pdf", "title": "Übung 1", "leer": ""])
        let f = try XCTUnwrap(form.file("upload"))
        XCTAssertEqual(f.filename, "Übung 1.pdf")
        XCTAssertEqual(f.contentType, "application/pdf")
        XCTAssertEqual(f.data, pdf)
    }

    func testMultipartQuotedBoundaryAndBareLineFeeds() throws {
        let body = multipartBody("a b", [("source", nil, nil, Data("ics".utf8))], lineBreak: "\n")
        let form = try MultipartForm.parse(body, contentType: "Multipart/Form-Data; charset=utf-8; boundary=\"a b\"")
        XCTAssertEqual(form.fields["source"], "ics")
        XCTAssertTrue(form.files.isEmpty)
    }

    func testMultipartFromAPIClientForm() throws {
        // dieselben Bytes, die APIClient.form in der App baut (Felder sortiert, Datei zuletzt)
        let boundary = "uniflow-" + UUID().uuidString
        var body = Data()
        for (k, v) in [("kind", "pdf"), ("title", "Skript")] {
            body.append(Data(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + k + "\"\r\n\r\n" + v + "\r\n").utf8))
        }
        body.append(Data(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"s.pdf\"\r\nContent-Type: application/pdf\r\n\r\n").utf8))
        body.append(Data("%PDF".utf8))
        body.append(Data("\r\n".utf8))
        body.append(Data(("--" + boundary + "--\r\n").utf8))
        let req = LocalRequest(method: "POST", path: "/api/notebooks", headers: ["Content-Type": "multipart/form-data; boundary=" + boundary], body: body)
        let form = try req.multipart()
        XCTAssertEqual(form.fields, ["kind": "pdf", "title": "Skript"])
        XCTAssertEqual(form.file("upload")?.data, Data("%PDF".utf8))
    }

    func testMalformedMultipartIs400() {
        for (body, type) in [("kein formular", "multipart/form-data; boundary=x"), ("--x\r\nohne ende", "multipart/form-data; boundary=x"),
                             ("--x--", "multipart/form-data"), ("{}", "application/json")] {
            XCTAssertThrowsError(try MultipartForm.parse(Data(body.utf8), contentType: type)) { e in
                XCTAssertEqual((e as? LocalHTTPError)?.status, 400, body)
            }
        }
        XCTAssertThrowsError(try LocalRequest(method: "POST", path: "/x").multipart())
    }

    func testAnnotationsPlaceholderKeepsNotesUnsaved() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        let get = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f1/annotations"))
        XCTAssertEqual(get.json, ["data": ["version": 2, "pages": [:], "zoom": 1.2], "updated_at": .null, "version": 0])
        let put = await backend.handle(LocalRequest(method: "PUT", path: "/api/files/f1/annotations",
                                                    query: [.init("base_version", "0")], body: Data(#"{"version":2,"pages":{}}"#.utf8)))
        XCTAssertEqual(put.status, 409)
        XCTAssertNil(put.json?["version"], "kein Konflikt mit neuerem Stand, sondern 'noch nicht moeglich'")
        XCTAssertNotNil(put.json?["detail"]?.string)
    }
}

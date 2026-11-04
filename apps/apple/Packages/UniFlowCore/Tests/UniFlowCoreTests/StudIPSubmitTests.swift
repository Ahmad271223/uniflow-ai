import Foundation
import XCTest
@testable import UniFlowCore

// Abgeben aus der App (docs/ABGEBEN-STUDIP-2026-11-05.md): Ordnerliste mit Schreibrecht, Multipart-Koerper,
// Fehlerzuordnung, Lizenz, Dateiname, Verlauf. Nur erfundene Daten, nichts geht ins Netz.

/// Schreibender Stub: GET ueber feste Antworten, POST/PATCH ueber eine Antwortfunktion; zeichnet alles auf
final class WritingStub: StudIPWritingTransport, @unchecked Sendable {
    struct Seen { let method: String; let path: String; let headers: [String: String]; let body: Data }
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private let write: @Sendable (String, String, Data) -> HTTPReply
    private var log: [Seen] = []

    init(_ routes: [String: HTTPReply], write: @escaping @Sendable (String, String, Data) -> HTTPReply) {
        self.routes = routes
        self.write = write
    }

    var seen: [Seen] { lock.withLock { log } }

    static func key(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "https://studip.test", with: "")
            .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
    }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let k = Self.key(url)
        lock.withLock { log.append(Seen(method: "GET", path: k, headers: [:], body: Data())) }
        return routes[k] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
    }

    func send(_ url: URL, method: String, headers: [String: String], body: Data) async throws -> HTTPReply {
        let k = Self.key(url)
        lock.withLock { log.append(Seen(method: method, path: k, headers: headers, body: body)) }
        return write(method, k, body)
    }
}

private func api(_ json: String, status: Int = 200) -> HTTPReply {
    HTTPReply(status: status, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let base = URL(string: "https://studip.test")!

/// Ordner eines erfundenen Kurses: Wurzel, Vorlesung (nur lesen), Uebungen/Abgabe Blatt 3 (Hausaufgaben, offen),
/// Abgabe Blatt 2 (zeitgesteuert, geschlossen), Material (Standard, beschreibbar), versteckt (nicht sichtbar)
private let foldersJSON = """
{"data":[
 {"type":"folders","id":"root","attributes":{"name":"Analysis I","folder-type":"RootFolder","is-visible":true,"is-readable":true,"is-writable":true},"relationships":{"parent":{"data":null}}},
 {"type":"folders","id":"vl","attributes":{"name":"Vorlesung","folder-type":"StandardFolder","is-visible":true,"is-readable":true,"is-writable":false},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
 {"type":"folders","id":"ue","attributes":{"name":"Übungen","folder-type":"StandardFolder","is-visible":true,"is-readable":true,"is-writable":false},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
 {"type":"folders","id":"hw3","attributes":{"name":"Abgabe Blatt 3","folder-type":"HomeworkFolder","is-visible":true,"is-readable":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"ue"}}}},
 {"type":"folders","id":"hw2","attributes":{"name":"Abgabe Blatt 2","folder-type":"TimedFolder","is-visible":true,"is-readable":true,"is-writable":false},"relationships":{"parent":{"data":{"type":"folders","id":"ue"}}}},
 {"type":"folders","id":"mat","attributes":{"name":"Material","folder-type":"StandardFolder","is-visible":true,"is-readable":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
 {"type":"folders","id":"hid","attributes":{"name":"Intern","folder-type":"HiddenFolder","is-visible":false,"is-readable":false,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}}
],"links":{}}
"""

private let termsJSON = """
{"data":[
 {"type":"terms-of-use","id":"UNDEF_LICENSE","attributes":{"name":"Ungeklärte Lizenz"}},
 {"type":"terms-of-use","id":"SELFMADE_NONPUB","attributes":{"name":"Selbst verfasstes, nicht publiziertes Werk"}},
 {"type":"terms-of-use","id":"FREE_LICENSE","attributes":{"name":"Werk mit freier Lizenz"}}
]}
"""

final class StudIPSubmitTests: XCTestCase {
    private func client(_ t: StudIPTransport) -> StudIPClient { StudIPClient(base: base, transport: t, pauseMillis: 0) }

    // MARK: Ordner

    func testFolderListOffersOnlyWritableVisibleFoldersHomeworkFirst() async throws {
        let stub = WritingStub(["/jsonapi.php/v1/courses/c1/folders?page[limit]=200": api(foldersJSON)]) { _, _, _ in HTTPReply(status: 500) }
        let f = try await client(stub).uploadFolders(courseID: "c1")
        XCTAssertEqual(f.writable.map(\.id), ["hw3", "mat", "root"])
        XCTAssertEqual(f.writable.map(\.label), ["Übungen/Abgabe Blatt 3", "Material", "Hauptordner"])
        XCTAssertEqual(f.closedSubmissionFolders.map(\.id), ["hw2"])
        XCTAssertEqual(f.suggested?.id, "hw3")
        XCTAssertTrue(f.writable[0].isHomework)
        XCTAssertFalse(f.writable.contains { $0.id == "hid" }, "unsichtbarer Ordner nie angeboten")
        XCTAssertEqual(stub.seen.map(\.method), ["GET"], "Ordnerliste ist nur lesend")
    }

    func testFolderWithoutWritableAttributeIsNotOffered() {
        let data = try! JSONValue.parse(Data(#"[{"id":"a","attributes":{"name":"Alt","folder-type":"StandardFolder"}}]"#.utf8)).array!
        let f = StudIPSubmit.folders(from: data, courseID: "c")
        XCTAssertTrue(f.writable.isEmpty)
        XCTAssertNil(f.suggested)
    }

    func testSubmissionNameWithoutHomeworkTypeIsSuggested() {
        let data = try! JSONValue.parse(Data(#"""
        [{"id":"r","attributes":{"name":"K","folder-type":"RootFolder","is-writable":true}},
         {"id":"x","attributes":{"name":"Dateien","folder-type":"StandardFolder","is-writable":true},"relationships":{"parent":{"data":{"id":"r"}}}},
         {"id":"y","attributes":{"name":"Abgaben Übung","folder-type":"StandardFolder","is-writable":true},"relationships":{"parent":{"data":{"id":"r"}}}}]
        """#.utf8)).array!
        let f = StudIPSubmit.folders(from: data, courseID: "c")
        XCTAssertEqual(f.suggested?.id, "y")
        XCTAssertEqual(f.writable.first?.id, "y")
    }

    // MARK: Hochladen

    func testUploadSendsMultipartWithFileFieldAndSetsLicense() async throws {
        let pdf = Data("%PDF-1.7\nerfunden\n%%EOF".utf8)
        let stub = WritingStub(["/jsonapi.php/v1/terms-of-use": api(termsJSON)]) { method, path, _ in
            if method == "POST" { return HTTPReply(status: 201, contentType: "application/vnd.api+json", location: "https://studip.test/jsonapi.php/v1/file-refs/neu42") }
            if method == "PATCH", path.hasSuffix("/relationships/terms-of-use") { return HTTPReply(status: 204) }
            return HTTPReply(status: 500)
        }
        let folder = StudIPUploadFolder(id: "hw3", courseID: "c1", name: "Abgabe Blatt 3", path: "Übungen/Abgabe Blatt 3", folderType: "HomeworkFolder", isWritable: true)
        let r = try await client(stub).upload(pdf, fileName: "Muster_Blatt3.pdf", folder: folder)
        XCTAssertEqual(r.fileRefID, "neu42")
        XCTAssertTrue(r.licenseSet)
        XCTAssertEqual(r.webURL.absoluteString, "https://studip.test/dispatch.php/course/files/index/hw3?cid=c1")

        let post = try XCTUnwrap(stub.seen.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/jsonapi.php/v1/folders/hw3/file-refs")
        let type = try XCTUnwrap(post.headers["Content-Type"])
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        let text = String(decoding: post.body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"Muster_Blatt3.pdf\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/pdf\r\n\r\n%PDF-1.7\nerfunden\n%%EOF\r\n--\(boundary)--\r\n"))
        XCTAssertNotNil(post.body.range(of: pdf), "PDF unveraendert im Koerper")
        XCTAssertEqual(post.headers["Accept"], "application/vnd.api+json")

        let patch = try XCTUnwrap(stub.seen.first { $0.method == "PATCH" })
        XCTAssertEqual(patch.path, "/jsonapi.php/v1/file-refs/neu42/relationships/terms-of-use")
        let j = try JSONValue.parse(patch.body)
        XCTAssertEqual(j["data"]?["id"]?.string, "SELFMADE_NONPUB")
        XCTAssertEqual(stub.seen.filter { $0.method == "POST" }.count, 1)
    }

    func testUploadIsNeverRepeatedOnServerError() async throws {
        let stub = WritingStub([:]) { _, _, _ in HTTPReply(status: 503) }
        let folder = StudIPUploadFolder(id: "f", courseID: "c", name: "F", path: "F", folderType: "StandardFolder", isWritable: true)
        do {
            _ = try await client(stub).upload(Data("x".utf8), fileName: "a.pdf", folder: folder)
            XCTFail("Fehler erwartet")
        } catch let e as StudIPUploadError {
            XCTAssertEqual(e, .http(503))
        }
        XCTAssertEqual(stub.seen.filter { $0.method == "POST" }.count, 1, "ein Versuch, sonst laege die Abgabe doppelt da")
    }

    func testUploadErrorsAreMapped() async throws {
        let cases: [(HTTPReply, StudIPUploadError)] = [
            (api(#"{"errors":[{"status":"403","title":"Forbidden"}]}"#, status: 403), .notWritable),
            (HTTPReply(status: 413), .tooLarge),
            (api(#"{"errors":[{"detail":"Die Datei ist zu groß"}]}"#, status: 422), .tooLarge),
            (api(#"{"errors":[{"detail":"Invalid security token (CSRF)"}]}"#, status: 403), .securityToken),
            (HTTPReply(status: 400), .http(400)),
        ]
        let folder = StudIPUploadFolder(id: "f", courseID: "c", name: "F", path: "F", folderType: "HomeworkFolder", isWritable: true)
        for (reply, expected) in cases {
            let stub = WritingStub([:]) { _, _, _ in reply }
            do {
                _ = try await client(stub).upload(Data("x".utf8), fileName: "a.pdf", folder: folder)
                XCTFail("Fehler erwartet fuer \(reply.status)")
            } catch let e as StudIPUploadError {
                XCTAssertEqual(e, expected, "HTTP \(reply.status)")
            }
        }
    }

    func testExpiredSessionOnUploadIsReported() async throws {
        let folder = StudIPUploadFolder(id: "f", courseID: "c", name: "F", path: "F", folderType: "HomeworkFolder", isWritable: true)
        let replies = [HTTPReply(status: 401),
                       HTTPReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://studip.test/dispatch.php/login"))]
        for reply in replies {
            let stub = WritingStub([:]) { _, _, _ in reply }
            do {
                _ = try await client(stub).upload(Data("x".utf8), fileName: "a.pdf", folder: folder)
                XCTFail("Sitzung abgelaufen erwartet")
            } catch let e as StudIPError {
                XCTAssertEqual(e, .sessionExpired)
            }
        }
    }

    func testLicenseFailureKeepsSubmission() async throws {
        let stub = WritingStub(["/jsonapi.php/v1/terms-of-use": api(termsJSON)]) { method, _, _ in
            method == "POST" ? HTTPReply(status: 201, contentType: "application/vnd.api+json",
                                         body: Data(#"{"data":{"type":"file-refs","id":"ausKoerper"}}"#.utf8))
                             : HTTPReply(status: 403)
        }
        let folder = StudIPUploadFolder(id: "f", courseID: "c", name: "F", path: "F", folderType: "HomeworkFolder", isWritable: true)
        let r = try await client(stub).upload(Data("x".utf8), fileName: "a.pdf", folder: folder)
        XCTAssertEqual(r.fileRefID, "ausKoerper")
        XCTAssertFalse(r.licenseSet)
    }

    func testReadOnlyTransportRefusesToWrite() async throws {
        final class ReadOnly: StudIPTransport, @unchecked Sendable {
            func get(_ url: URL, accept: String?) async throws -> HTTPReply { HTTPReply(status: 404) }
        }
        let folder = StudIPUploadFolder(id: "f", courseID: "c", name: "F", path: "F", folderType: "HomeworkFolder", isWritable: true)
        do {
            _ = try await client(ReadOnly()).upload(Data("x".utf8), fileName: "a.pdf", folder: folder)
            XCTFail("Ablehnung erwartet")
        } catch let e as StudIPUploadError {
            XCTAssertEqual(e, .unsupported)
        }
    }

    func testOwnNameFromUsersMe() async throws {
        let stub = WritingStub(["/jsonapi.php/v1/users/me": api(#"{"data":{"type":"users","id":"u1","attributes":{"family-name":"Müller","given-name":"Erika"}}}"#)]) { _, _, _ in HTTPReply(status: 500) }
        let n = try await client(stub).ownName()
        XCTAssertEqual(n, StudIPOwnName(id: "u1", familyName: "Müller", givenName: "Erika"))
    }

    // MARK: Regeln ohne Netz

    func testProposedFileName() {
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Müller", title: "Übungsblatt 3"), "Mueller_Blatt3.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Müller", title: "AnaI_Blatt_03.pdf"), "Mueller_Blatt3.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "von Däniken", title: "Hausaufgabe 12"), "von_Daeniken_Blatt12.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Muster", title: "Exercise Sheet 4"), "Muster_Blatt4.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Muster", title: "Lineare Algebra Zusammenfassung"),
                       "Muster_Lineare_Algebra_Zusammenfassung.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: nil, title: "Blatt 7"), "Blatt7.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Muster", title: "AnaI Ü2"), "Muster_Blatt2.pdf")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "Muster", title: "Alpha 2"), "Muster_Alpha_2.pdf", "kein Treffer mitten im Wort")
        XCTAssertEqual(StudIPSubmit.proposedFileName(familyName: "", title: "   "), "Abgabe.pdf")
    }

    func testFinalFileName() {
        XCTAssertEqual(StudIPSubmit.finalFileName("Müller Blatt 3"), "Mueller_Blatt_3.pdf")
        XCTAssertEqual(StudIPSubmit.finalFileName("a/b\\c.PDF"), "a_b_c.pdf")
        XCTAssertNil(StudIPSubmit.finalFileName("  ...  "))
    }

    func testSizeNotice() {
        XCTAssertNil(StudIPSubmit.sizeNotice(bytes: 2 * 1024 * 1024))
        XCTAssertEqual(StudIPSubmit.sizeNotice(bytes: 9 * 1024 * 1024 + 500_000),
                       "Die Datei ist 9,5 MB groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an.")
    }

    func testOwnWorkLicenseByName() throws {
        let list = try JSONValue.parse(Data(#"[{"id":"X1","attributes":{"name":"Selbst verfasst, nicht veröffentlicht"}}]"#.utf8)).array!
        XCTAssertEqual(StudIPSubmit.ownWorkLicenseID(list), "X1")
        XCTAssertNil(StudIPSubmit.ownWorkLicenseID([]))
    }

    func testSubmissionLogKeepsNewestFirstPerDocument() {
        var log = StudIPSubmissionLog()
        let d0 = Date(timeIntervalSince1970: 1_793_000_000)
        for i in 0..<3 {
            log.add(StudIPSubmissionRecord(documentID: i == 1 ? "B" : "A", at: d0.addingTimeInterval(Double(i) * 60), courseID: "c",
                                           courseTitle: "Analysis I", folderID: "f", folderLabel: "Abgabe Blatt 3", fileName: "x.pdf",
                                           url: "https://studip.test/x", withNotes: true, pages: 4))
        }
        let back = StudIPSubmissionLog.decode(log.encoded())
        XCTAssertEqual(back.records(for: "A").count, 2)
        XCTAssertEqual(back.records(for: "A").first?.at, d0.addingTimeInterval(120))
        XCTAssertEqual(back.records(for: "A").first?.line(timeZone: TimeZone(identifier: "Europe/Berlin")!),
                       "Abgegeben am \(Self.berlin(d0.addingTimeInterval(120))) in Analysis I › Abgabe Blatt 3")
        XCTAssertEqual(StudIPSubmissionLog.decode(nil).records.count, 0)
        var big = StudIPSubmissionLog()
        for i in 0..<(StudIPSubmissionLog.limit + 5) {
            big.add(StudIPSubmissionRecord(documentID: "\(i)", at: d0, courseID: "c", courseTitle: "K", folderID: "f", folderLabel: "F",
                                           fileName: "x.pdf", url: "", withNotes: false, pages: 1))
        }
        XCTAssertEqual(big.records.count, StudIPSubmissionLog.limit)
    }

    private static func berlin(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f.string(from: d)
    }
}

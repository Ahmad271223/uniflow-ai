import Foundation
import XCTest
@testable import UniFlowCore

// Stud.IP lesen (Entscheidung des Inhabers 02.11.2026): gesperrte Unterordner ueberspringen statt den ganzen Kurs zu
// verlieren, alle Seiten (`links.next`) bei Ordnern, Dateien und Ankuendigungen, Dateien "Link/Webadresse" als Link,
// Sitzungsthema und Ausfall je Einzeltermin, Kursbeschreibung. Antworten im JSON:API-Format wie Stud.IP 6.x (erfunden).

private func api(_ json: String) -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let forbidden = HTTPReply(status: 403, contentType: "application/vnd.api+json", body: Data(#"{"errors":[{"status":"403"}]}"#.utf8))
private let base = URL(string: "https://studip.test")!
private let v1 = "/jsonapi.php/v1"

private func folder(_ id: String, _ name: String, type: String = "StandardFolder") -> String {
    #"{"id": "\#(id)", "type": "folders", "attributes": {"name": "\#(name)", "folder-type": "\#(type)"}}"#
}

private func ref(_ id: String, _ name: String, downloadable: Bool = true, extra: String = "") -> String {
    #"{"id": "\#(id)", "type": "file-refs", "attributes": {"name": "\#(name)", "filesize": 10, "chdate": "2026-10-20T10:00:00+02:00", "is-downloadable": \#(downloadable)\#(extra)}}"#
}

final class StudIPRobustReadTests: XCTestCase {

    /// Kurs mit einem gesperrten (403) und einem entfernten (404) Unterordner: der Rest des Kurses wird gelesen, die zwei
    /// Ordner werden gezaehlt; Dateien auf zwei Seiten (`links.next`) kommen beide
    func testUnreadableSubfoldersAreSkippedAndCounted() async throws {
        let t = StubTransport([
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(folder("root", "", type: "RootFolder"))]}"#),
            "\(v1)/folders/root/file-refs?page[limit]=500": api(#"""
                {"data": [\#(ref("f1", "Folien 1.pdf"))], "links": {"next": "/jsonapi.php/v1/folders/root/file-refs?page[offset]=1&page[limit]=500"}}
                """#),
            "\(v1)/folders/root/file-refs?page[offset]=1&page[limit]=500": api(#"{"data": [\#(ref("f2", "Folien 2.pdf"))], "links": {}}"#),
            "\(v1)/folders/root/folders?page[limit]=200": api(#"{"data": [\#(folder("tutor", "Nur Tutoren")), \#(folder("weg", "Entfernt")), \#(folder("ue", "Übungen"))]}"#),
            "\(v1)/folders/tutor/file-refs?page[limit]=500": forbidden,
            // "weg" fehlt in den Antworten: der Stub antwortet mit 404
            "\(v1)/folders/ue/file-refs?page[limit]=500": api(#"{"data": [\#(ref("f3", "Blatt 1.pdf"))]}"#),
            "\(v1)/folders/ue/folders?page[limit]=200": api(#"{"data": []}"#),
        ])
        let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let listing = try await client.fileListing(courseID: "c1")
        XCTAssertEqual(listing.files.map(\.id), ["f1", "f2", "f3"])
        XCTAssertEqual(listing.files.map(\.folderPath), ["", "", "Übungen"])
        XCTAssertEqual(listing.unreadableFolders, 2)
        let files = try await client.files(courseID: "c1")
        XCTAssertEqual(files.map(\.id), ["f1", "f2", "f3"], "files(courseID:) wie bisher, nur ohne Ausfall des Kurses")
    }

    /// Gesperrter Wurzelordner und andere Fehler bleiben Fehler des Kurses (wie bisher "Kurs nicht lesbar"); 401 ist
    /// weiter "Anmeldung abgelaufen"
    func testRootAndSessionErrorsStillFailTheCourse() async throws {
        let rootForbidden = StubTransport([
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(folder("root", "", type: "RootFolder"))]}"#),
            "\(v1)/folders/root/file-refs?page[limit]=500": forbidden,
        ])
        do {
            _ = try await StudIPClient(base: base, transport: rootForbidden, pauseMillis: 0).fileListing(courseID: "c1")
            XCTFail("Wurzelordner gesperrt")
        } catch let e as StudIPError {
            XCTAssertEqual(e, .http(status: 403, path: "jsonapi.php/v1/folders/root/file-refs"))
            XCTAssertTrue(e.affectsOnlyItem)
        }
        let expired = StubTransport([
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(folder("root", "", type: "RootFolder"))]}"#),
            "\(v1)/folders/root/file-refs?page[limit]=500": api(#"{"data": []}"#),
            "\(v1)/folders/root/folders?page[limit]=200": api(#"{"data": [\#(folder("sub", "Sub"))]}"#),
            "\(v1)/folders/sub/file-refs?page[limit]=500": HTTPReply(status: 401),
        ])
        do {
            _ = try await StudIPClient(base: base, transport: expired, pauseMillis: 0).fileListing(courseID: "c1")
            XCTFail("Sitzung abgelaufen")
        } catch let e as StudIPError {
            XCTAssertEqual(e, .sessionExpired)
        }
        let serverError = StubTransport([
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(folder("root", "", type: "RootFolder"))]}"#),
            "\(v1)/folders/root/file-refs?page[limit]=500": api(#"{"data": []}"#),
            "\(v1)/folders/root/folders?page[limit]=200": api(#"{"data": [\#(folder("sub", "Sub"))]}"#),
            "\(v1)/folders/sub/file-refs?page[limit]=500": HTTPReply(status: 500),
        ])
        do {
            _ = try await StudIPClient(base: base, transport: serverError, pauseMillis: 0).fileListing(courseID: "c1")
            XCTFail("Serverfehler im Unterordner bleibt ein Fehler des Kurses")
        } catch let e as StudIPError {
            XCTAssertEqual(e, .http(status: 500, path: "jsonapi.php/v1/folders/sub/file-refs"))
        }
    }

    /// Datei "Link/Webadresse": nicht herunterladbar, mit Adresse -> Link; ohne Adresse oder mit fremdem Schema bleibt
    /// sie "nicht herunterladbar"; eine herunterladbare Datei bekommt nie einen Link
    func testLinkFilesCarryTheirURL() async throws {
        let t = StubTransport([
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(folder("root", "", type: "RootFolder"))]}"#),
            "\(v1)/folders/root/file-refs?page[limit]=500": api(#"""
                {"data": [\#(ref("l1", "Vorlesungsaufzeichnung", downloadable: false, extra: #", "url": "https://video.uni-hannover.de/v/123""#)),
                          \#(ref("l2", "Ohne Adresse", downloadable: false)),
                          \#(ref("l3", "Skript", downloadable: false, extra: #", "url": "javascript:alert(1)""#)),
                          {"id": "l4", "type": "file-refs", "attributes": {"name": "Meta", "is-downloadable": false}, "meta": {"url": "http://example.org/a"}},
                          \#(ref("f1", "Normal.pdf", extra: #", "url": "https://example.org/x""#))]}
                """#),
            "\(v1)/folders/root/folders?page[limit]=200": api(#"{"data": []}"#),
        ])
        let files = try await StudIPClient(base: base, transport: t, pauseMillis: 0).files(courseID: "c1")
        XCTAssertEqual(files.map { $0.linkURL ?? "-" }, ["https://video.uni-hannover.de/v/123", "-", "-", "http://example.org/a", "-"])
        XCTAssertEqual(files.map(\.isDownloadable), [false, false, false, false, true])

        // Ablage auf dem Geraet: Links eines vollstaendig gelesenen Kurses ersetzen die gespeicherten
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-11-02T10:00:00")!)
        try await backend.context.database.transaction { c in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "c1", title: "Testkurs")], startedAt: "2026-11-02T10:00:00")
            try StudIPLibrary.storeLinks(c, courseID: "c1", files, complete: true, now: "2026-11-02T10:00:00")
        }
        var links = try await backend.context.database.withConnection { try StudIPLibrary.links($0) }
        XCTAssertEqual(links.map(\.name), ["Meta", "Vorlesungsaufzeichnung"])
        XCTAssertEqual(links.first?.courseTitle, "Testkurs")
        // unvollstaendig gelesen (Ordner uebersprungen): nichts verschwindet
        try await backend.context.database.transaction { c in
            try StudIPLibrary.storeLinks(c, courseID: "c1", [], complete: false, now: "2026-11-02T11:00:00")
        }
        links = try await backend.context.database.withConnection { try StudIPLibrary.links($0) }
        XCTAssertEqual(links.count, 2)
        try await backend.context.database.transaction { c in
            try StudIPLibrary.storeLinks(c, courseID: "c1", Array(files.prefix(1)), complete: true, now: "2026-11-02T12:00:00")
        }
        links = try await backend.context.database.withConnection { try StudIPLibrary.links($0) }
        XCTAssertEqual(links.map(\.id), ["l1"])
    }

    /// Ankuendigungen ueber mehrere Seiten (vorher nur die ersten 100); scheitert eine Folgeseite, bleibt der Bestand
    func testCourseNewsFollowsNextLinks() async throws {
        let news = { (id: String) in #"{"id": "\#(id)", "type": "news", "attributes": {"title": "N \#(id)", "content": "Text", "publication-start": "2026-10-20T10:00:00+02:00"}}"# }
        let t = StubTransport([
            "\(v1)/courses/c1/news?page[limit]=100": api(#"{"data": [\#(news("n1"))], "links": {"next": "/jsonapi.php/v1/courses/c1/news?page[offset]=100&page[limit]=100"}}"#),
            "\(v1)/courses/c1/news?page[offset]=100&page[limit]=100": api(#"{"data": [\#(news("n2"))], "links": {}}"#),
            "\(v1)/courses/c2/news?page[limit]=100": api(#"{"data": [\#(news("n3"))], "links": {"next": "/jsonapi.php/v1/courses/c2/news?page[offset]=100&page[limit]=100"}}"#),
        ])
        let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let all = try await client.courseNews(courseID: "c1")
        XCTAssertEqual(all.compactMap { $0["id"]?.string }, ["n1", "n2"])
        do {
            _ = try await client.courseNews(courseID: "c2")
            XCTFail("Folgeseite fehlt: Fehler statt halber Liste")
        } catch let e as StudIPError {
            XCTAssertTrue(e.affectsOnlyItem)
        }
    }

    /// Einzeltermine: Sitzungsthema (HTML wie eine Ankuendigung als Text) und Ausfall; Kursbeschreibung und Sonstiges
    /// der Kursliste (fehlt das Feld: nil, dann bleibt der gespeicherte Text)
    func testEventTopicsCancellationsAndCourseTexts() throws {
        let data = try JSONValue.parse(Data(#"""
            [{"id": "e1", "type": "course-events", "attributes": {"title": "Sitzung", "start": "2026-11-03T10:00:00+01:00", "end": "2026-11-03T11:30:00+01:00",
              "description": "<p>Kapitel&nbsp;3:<br>Grenzwerte</p>", "location": "Hörsaal, Gebäude 1", "is-cancelled": false}},
             {"id": "e2", "type": "course-events", "attributes": {"title": "Sitzung", "start": "2026-11-10T10:00:00+01:00", "end": "2026-11-10T11:30:00+01:00",
              "description": null, "is-cancelled": true}},
             {"id": "e3", "type": "course-events", "attributes": {"title": "Sitzung", "start": "2026-11-17T10:00:00+01:00", "end": "2026-11-17T11:30:00+01:00"}}]
            """#.utf8)).array ?? []
        let events = StudIPCourseEvent.parse(data, courseID: "c1")
        XCTAssertEqual(events.map(\.description), ["Kapitel 3:\nGrenzwerte", "", ""])
        XCTAssertEqual(events.map(\.cancelled), [false, true, false])
        XCTAssertEqual(events[0].room, "Hörsaal")
        XCTAssertEqual(StudIPText.clean(.string(String(repeating: "x", count: 2500))).count, StudIPText.maxChars)
        XCTAssertNil(StudIPText.field(["title": "T"], "description"))
        XCTAssertEqual(StudIPText.field(["description": .null], "description"), "")
    }
}

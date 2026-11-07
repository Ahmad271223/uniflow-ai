import Foundation
import XCTest
@testable import UniFlowCore

// Tempo des Abgleichs (07.11.2026): flache Ordnerliste `courses/{id}/folders` mit Beziehung `parent` statt einer
// Unterordner-Abfrage je Ordner, Vergleich mit dem Baum und hoechstens N Anfragen zugleich. Erfundene Antworten im
// JSON:API-Format wie Stud.IP 6.x.

private func api(_ json: String) -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let base = URL(string: "https://studip.test")!
private let v1 = "/jsonapi.php/v1"

private func folder(_ id: String, _ name: String, parent: String? = nil, type: String = "StandardFolder") -> String {
    let rel = parent.map { #", "relationships": {"parent": {"data": {"type": "folders", "id": "\#($0)"}}}"# } ?? ""
    return #"{"id": "\#(id)", "type": "folders", "attributes": {"name": "\#(name)", "folder-type": "\#(type)"}\#(rel)}"#
}

private func refs(_ ids: [String]) -> HTTPReply {
    api(#"{"data": [\#(ids.map { #"{"id": "\#($0)", "type": "file-refs", "attributes": {"name": "\#($0).pdf", "filesize": 10, "chdate": "2026-10-20T10:00:00+02:00"}}"# }.joined(separator: ","))]}"#)
}

/// Transport mit Zaehler fuer gleichzeitige Anfragen und kurzer Wartezeit je Antwort
private final class FolderCountingTransport: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private var log: [String] = []
    private var open = 0
    private(set) var maxOpen = 0
    let delayNanos: UInt64

    init(_ routes: [String: HTTPReply], delayNanos: UInt64 = 0) {
        self.routes = routes
        self.delayNanos = delayNanos
    }

    var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let key = url.absoluteString.replacingOccurrences(of: "https://studip.test", with: "")
            .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
        begin(key)
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        end()
        return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
    }

    private func begin(_ key: String) { lock.lock(); log.append(key); open += 1; maxOpen = max(maxOpen, open); lock.unlock() }
    private func end() { lock.lock(); open -= 1; lock.unlock() }
}

final class StudIPFolderListingTests: XCTestCase {
    /// Kurs: Wurzel (r) -> Vorlesung (a) -> Folien (a1), Wurzel -> Übung (b); flache Liste mit `parent`
    private func course(flat: [String]? = nil, extraSub: Bool = false) -> [String: HTTPReply] {
        let list = flat ?? [folder("r", "", type: "RootFolder"), folder("a", "Vorlesung", parent: "r"), folder("a1", "Folien", parent: "a"),
                            folder("b", "Übung", parent: "r")]
        var routes: [String: HTTPReply] = [
            "\(v1)/courses/c1/folders?page[limit]=200": api(#"{"data": [\#(list.joined(separator: ","))]}"#),
            "\(v1)/folders/r/file-refs?page[limit]=500": refs(["r1"]),
            "\(v1)/folders/a/file-refs?page[limit]=500": refs(["a1x", "a2x"]),
            "\(v1)/folders/a1/file-refs?page[limit]=500": refs(["f1"]),
            "\(v1)/folders/b/file-refs?page[limit]=500": refs(["b1"]),
            "\(v1)/folders/r/folders?page[limit]=200": api(#"{"data": [\#(folder("a", "Vorlesung")), \#(folder("b", "Übung"))]}"#),
            "\(v1)/folders/a/folders?page[limit]=200": api(#"{"data": [\#(folder("a1", "Folien"))\#(extraSub ? "," + folder("neu", "Neu") : "")]}"#),
            "\(v1)/folders/a1/folders?page[limit]=200": api(#"{"data": []}"#),
            "\(v1)/folders/b/folders?page[limit]=200": api(#"{"data": []}"#),
        ]
        if extraSub {
            routes["\(v1)/folders/neu/file-refs?page[limit]=500"] = refs(["n1"])
            routes["\(v1)/folders/neu/folders?page[limit]=200"] = api(#"{"data": []}"#)
        }
        return routes
    }

    private static func byID(_ l: StudIPFileListing) -> [String: String] {
        Dictionary(uniqueKeysWithValues: l.files.map { ($0.id, $0.folderPath) })
    }

    /// Baum und flache Liste liefern dieselben Dateien mit denselben Ordnerpfaden; flach spart die Unterordner-Abfragen
    func testFlatListReadsSameFilesWithFewerRequests() async throws {
        let walkT = FolderCountingTransport(course())
        let walk = try await StudIPClient(base: base, transport: walkT, pauseMillis: 0).fileListing(courseID: "c1", mode: .walk)
        let flatT = FolderCountingTransport(course())
        let flat = try await StudIPClient(base: base, transport: flatT, pauseMillis: 0).fileListing(courseID: "c1", mode: .flat)
        XCTAssertEqual(Self.byID(walk), ["r1": "", "a1x": "Vorlesung", "a2x": "Vorlesung", "f1": "Vorlesung/Folien", "b1": "Übung"])
        XCTAssertEqual(Self.byID(flat), Self.byID(walk))
        XCTAssertEqual(walk.folderCheck, .confirmed)
        XCTAssertFalse(walk.usedFlatList)
        XCTAssertTrue(flat.usedFlatList)
        XCTAssertEqual(walkT.requested.count, 1 + 4 + 4, "Baum: Ordnerliste, je Ordner Dateien und Unterordner")
        XCTAssertEqual(flatT.requested.count, 1 + 4, "flach: Ordnerliste und je Ordner die Dateien")
        XCTAssertFalse(flatT.requested.contains { $0.hasPrefix("\(v1)/folders/") && $0.contains("/folders?") })
    }

    /// Flache Liste nur mit der Wurzel (aeltere Stud.IP-Fassung oder andere Lesart): der Baum findet mehr, das ist eine
    /// Abweichung; ohne `parent` liest auch `.flat` den Baum, keine Datei geht verloren
    func testFlatListWithoutChildrenIsAMismatchAndFlatFallsBack() async throws {
        let rootOnly = course(flat: [folder("r", "", type: "RootFolder")])
        let walk = try await StudIPClient(base: base, transport: FolderCountingTransport(rootOnly), pauseMillis: 0).fileListing(courseID: "c1")
        XCTAssertEqual(walk.folderCheck, .mismatch)
        XCTAssertEqual(walk.files.count, 5)

        let noParent = course(flat: [folder("r", "", type: "RootFolder"), folder("a", "Vorlesung")])
        let t = FolderCountingTransport(noParent)
        let flat = try await StudIPClient(base: base, transport: t, pauseMillis: 0).fileListing(courseID: "c1", mode: .flat)
        XCTAssertFalse(flat.usedFlatList, "Ordner ohne Elternordner: kein Baum aus der flachen Liste")
        XCTAssertEqual(flat.files.count, 5)
        XCTAssertEqual(flat.folderCheck, .mismatch)
    }

    /// Unterordner, den nur der Baum zeigt: Abweichung (spaetere Laeufe lesen dann weiter den Baum)
    func testSubfolderMissingInFlatListIsAMismatch() async throws {
        let walk = try await StudIPClient(base: base, transport: FolderCountingTransport(course(extraSub: true)), pauseMillis: 0)
            .fileListing(courseID: "c1", mode: .walk)
        XCTAssertEqual(walk.folderCheck, .mismatch)
        XCTAssertEqual(Self.byID(walk)["n1"], "Vorlesung/Neu", "Datei im neuen Ordner trotzdem gelesen")
    }

    /// Gesperrter Unterordner in der flachen Liste: gezaehlt, seine Kinder nicht gefragt, der Rest gelesen
    func testFlatUnreadableFolderSkipsItsChildren() async throws {
        var routes = course()
        routes["\(v1)/folders/a/file-refs?page[limit]=500"] = HTTPReply(status: 403, contentType: "application/vnd.api+json", body: Data("{}".utf8))
        let t = FolderCountingTransport(routes)
        let flat = try await StudIPClient(base: base, transport: t, pauseMillis: 0).fileListing(courseID: "c1", mode: .flat)
        XCTAssertEqual(flat.unreadableFolders, 1)
        XCTAssertEqual(Set(flat.files.map(\.id)), ["r1", "b1"])
        XCTAssertFalse(t.requested.contains("\(v1)/folders/a1/file-refs?page[limit]=500"))
    }

    /// Hoechstens `maxConcurrent` Anfragen zugleich, aber mehr als eine
    func testConcurrentRequestsAreLimited() async throws {
        let t = FolderCountingTransport(course(), delayNanos: 20_000_000)
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0, maxConcurrent: 2)
        async let one = c.fileListing(courseID: "c1", mode: .flat)
        async let two = c.fileListing(courseID: "c1", mode: .flat)
        async let three = c.fileListing(courseID: "c1", mode: .flat)
        let all = try await [one, two, three]
        XCTAssertEqual(all.map(\.files.count), [5, 5, 5])
        XCTAssertEqual(t.maxOpen, 2)
        let count = await c.requestCount
        XCTAssertEqual(count, 15)
    }
}

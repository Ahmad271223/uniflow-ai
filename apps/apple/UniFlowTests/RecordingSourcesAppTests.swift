import XCTest
import UniFlowCore
@testable import UniFlow

/// Aufzeichnungen aus weiteren Quellen in der App (03.11.2026): ein Kurs ohne Opencast, aber mit Videodateien im
/// Dateibaum und Video-Bloecken in der Courseware, zeigt sie im Bereich "Aufzeichnungen"; der Abgleich laedt die
/// Videodateien nicht von selbst (Entscheidung 7), "Laden" und "Abspielen" gehen ueber die JSON:API mit dem
/// Sitzungs-Cookie des Containers. Feste, erfundene Antworten (kein Netz).
@MainActor
final class RecordingSourcesAppTests: XCTestCase {

    private struct Device {
        let layout: DataContainerLayout
        let host: LocalBackendHost
    }

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-10T12:00:00")!

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ocs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let layout = DataContainerLayout(base: c, key: DataContainerKey(userID: "001234.erfunden.ocs", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        return Device(layout: layout, host: host)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-ocs-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private static func fixture(_ name: String) throws -> String {
        // Mac ("Designed for iPad"): Sandbox, dann die Kopie im Testbundle (ContainerTestBed.repoURL)
        return try String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/opencast/\(name)"), encoding: .utf8)
    }

    /// Stud.IP mit festen Antworten; merkt sich jede Adresse
    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [URL] = []
        private static let base = "https://studip.uni-hannover.de"

        var requested: [URL] { lock.lock(); defer { lock.unlock() }; return log }

        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; lock.unlock() }
        func json(_ path: String, _ text: String) { set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))) }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: Self.base, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            return reply(url, key)
        }

        private func reply(_ url: URL, _ key: String) -> HTTPReply {
            lock.lock(); defer { lock.unlock() }
            log.append(url)
            return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }
    }

    /// Ein Kurs "Testprogrammierung" ohne Opencast (500 "navigation item not found"), mit einer PDF, einer Videodatei
    /// (250 MB) und einer Courseware-Seite mit Video-Bloecken
    private func fakeStudIP() throws -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"""
            {"data":[{"id":"c-prog","type":"courses","attributes":{"title":"Testprogrammierung","description":"Begleitend: https://www.youtube.com/playlist?list=PLprog"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
             "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
            """#)
        t.json("/jsonapi.php/v1/courses/c-prog/folders?page[limit]=200", #"{"data":[{"id":"r-c-prog","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
        t.json("/jsonapi.php/v1/folders/r-c-prog/folders?page[limit]=200", #"{"data":[]}"#)
        t.json("/jsonapi.php/v1/folders/r-c-prog/file-refs?page[limit]=500", #"""
            {"data":[{"id":"f-prog","attributes":{"name":"Folien 01.pdf","filesize":3,"mime-type":"application/pdf","chdate":"2026-10-14T10:00:00+02:00","is-downloadable":true}},
                     {"id":"f-video","attributes":{"name":"VL02 Aufzeichnung.mp4","filesize":250000000,"mime-type":"video/mp4","chdate":"2026-10-21T10:00:00+02:00","is-downloadable":true}}]}
            """#)
        t.set("/jsonapi.php/v1/file-refs/f-prog/content", HTTPReply(status: 200, contentType: "application/pdf", body: Data("%PDF-1.4 x".utf8)))
        t.set("/jsonapi.php/v1/file-refs/f-video/content", HTTPReply(status: 200, contentType: "video/mp4", body: Data("mp4".utf8)))
        t.set("/plugins.php/opencastpluginluh/media/index?cid=c-prog",
              HTTPReply(status: 500, contentType: "text/html; charset=UTF-8", body: Data(try Self.fixture("media-index-no-plugin.html").utf8)))
        // Courseware: eine Seite mit den Medienbloecken der Vertragsdatei
        t.json("/jsonapi.php/v1/courses/c-prog/courseware-units?include=structural-element&page[limit]=50", #"""
            {"data":[{"id":"u1","type":"courseware-units","relationships":{"structural-element":{"data":{"type":"courseware-structural-elements","id":"e1"}}}}],
             "included":[{"id":"e1","type":"courseware-structural-elements","attributes":{"title":"Woche 1","chdate":"2026-10-30T10:00:00+01:00"}}]}
            """#)
        t.json("/jsonapi.php/v1/courseware-structural-elements/e1/containers?include=blocks&page[limit]=100", try Self.fixture("courseware-media-blocks.json"))
        t.json("/jsonapi.php/v1/courseware-structural-elements/e1/children?page[limit]=100", #"{"data":[]}"#)
        return t
    }

    private func client(_ t: FakeStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    private static let cookie = HTTPCookie(properties: [.name: "Studip_Session", .value: "erfunden", .domain: "studip.uni-hannover.de", .path: "/"])!

    private func sync(_ dev: Device) throws -> StudIPSync {
        StudIPSync(root: dev.layout.studip, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.layout.root, container: dev.layout)
    }

    private func moduleID(_ dev: Device, _ name: String) async throws -> Int {
        let id = try await dev.host.backend().context.database.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int
        return try XCTUnwrap(id, name)
    }

    func testCourseWithOnlyFileAndCoursewareVideosShowsThemWithoutLoadingThem() async throws {
        let dev = try device()
        let stud = try fakeStudIP()
        let s = try sync(dev)
        await s.run(client: client(stud))
        XCTAssertEqual(s.phase, .idle, s.lastSummary ?? "")
        let backend = try await dev.host.backend()
        let clock = backend.context.clock
        try await backend.context.database.transaction { try LocalModules.ensureModules($0, clock: clock) }
        let prog = try await moduleID(dev, "Testprogrammierung")

        let entries = await s.recordings.blocks(moduleID: prog).flatMap(\.entries)
        let bySource = Dictionary(grouping: entries, by: \.video.source)
        XCTAssertEqual(bySource[OpencastVideo.sourceFile]?.map(\.video.title), ["VL02 Aufzeichnung.mp4"])
        XCTAssertEqual(bySource[OpencastVideo.sourceCourseware]?.count, 8, "\(entries.map(\.video.id))")
        XCTAssertEqual(bySource[OpencastVideo.sourceLink]?.map(\.video.linkURL?.host), ["www.youtube.com"])
        XCTAssertNil(bySource[OpencastVideo.sourceOpencast], "kein Opencast im Kurs")

        // die Videodatei: Woche 2 aus dem Namen, Groesse aus der Liste, Stream ueber die JSON:API, noch nicht geladen
        let file = try XCTUnwrap(bySource[OpencastVideo.sourceFile]?.first)
        XCTAssertEqual(file.week, 2)
        XCTAssertEqual(file.video.size, 250_000_000)
        XCTAssertEqual(file.video.media.map(\.quality), ["Original"])
        XCTAssertEqual(file.video.media.first?.url.absoluteString, "https://studip.uni-hannover.de/jsonapi.php/v1/file-refs/f-video/content")
        XCTAssertNil(file.localPath)
        XCTAssertNil(s.recordings.localFile(file))
        XCTAssertEqual(RecordingText.primaryAction(file.video), "Abspielen")
        XCTAssertEqual(RecordingText.sourceLabel(file.video), "Datei in Stud.IP")
        XCTAssertEqual(s.recordings.target(file, quality: "Original").lastPathComponent, "file_f-video-Original.mp4")
        guard case .confirm(let question) = RecordingDownloadPolicy.decide(title: file.video.title, quality: "Original", size: file.video.size, freeBytes: 50_000_000_000) else {
            return XCTFail("250 MB nur mit Rueckfrage")
        }
        XCTAssertTrue(question.contains("250 MB"), question)

        // der Abgleich lud die PDF, nicht das Video (Entscheidung 7); keine Anfrage an einen Videoserver
        let paths = stud.requested.map(\.path)
        XCTAssertTrue(paths.contains("/jsonapi.php/v1/file-refs/f-prog/content"), "\(paths)")
        XCTAssertFalse(paths.contains("/jsonapi.php/v1/file-refs/f-video/content"), "Video nicht von selbst geladen")
        XCTAssertTrue(stud.requested.allSatisfy { $0.host == StudIPSync.base.host })
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.recordings.root.path))
        XCTAssertTrue(s.lastSummary?.contains("1 neu/geändert") ?? false, s.lastSummary ?? "")

        // Courseware-Bloecke oeffnen ihre Seite in Stud.IP; Links den Browser
        let cw = try XCTUnwrap(bySource[OpencastVideo.sourceCourseware]?.first { $0.video.id == "cw:e1:b-video-url" })
        XCTAssertEqual(RecordingText.primaryAction(cw.video), "In Stud.IP öffnen")
        XCTAssertEqual(cw.video.playerURL?.absoluteString, "https://studip.uni-hannover.de/dispatch.php/course/courseware/?cid=c-prog#/structural_element/e1")
        XCTAssertEqual(cw.video.linkURL?.host, "www.youtube.com")
        let cwFile = try XCTUnwrap(bySource[OpencastVideo.sourceCourseware]?.first { $0.video.id == "cw:e1:b-video-file" })
        XCTAssertEqual(RecordingText.primaryAction(cwFile.video), "Abspielen")
        XCTAssertTrue(cwFile.video.needsStudIPSession)
        let link = try XCTUnwrap(bySource[OpencastVideo.sourceLink]?.first)
        XCTAssertEqual(RecordingText.primaryAction(link.video), "Link öffnen")
        XCTAssertEqual(link.week, 0)

        // zweiter Abgleich: nichts doppelt, Video weiterhin nicht geladen
        s.refreshSlowPartsNextRun()
        await s.run(client: client(stud))
        let again = await s.recordings.blocks(moduleID: prog).flatMap(\.entries)
        XCTAssertEqual(again.count, entries.count)
        XCTAssertFalse(stud.requested.map(\.path).contains("/jsonapi.php/v1/file-refs/f-video/content"))
    }

    /// Sitzungs-Cookie nur fuer Dateien aus Stud.IP und nur an den Stud.IP-Host; der Videoserver bekommt keins
    func testCookiesOnlyForStudIPFiles() throws {
        let dev = try device()
        let lib = RecordingLibrary(root: dev.layout.studip.appendingPathComponent("Aufzeichnungen"), host: dev.host, container: dev.layout,
                                   cookies: { _ in [Self.cookie] })
        let studip = URL(string: "https://studip.uni-hannover.de/jsonapi.php/v1/file-refs/f-video/content")!
        let oc = URL(string: "https://oc.example.test/v/x.mp4")!
        XCTAssertEqual(lib.cookies(for: studip).map(\.name), ["Studip_Session"])
        XCTAssertTrue(lib.cookies(for: oc).isEmpty)
        XCTAssertEqual(RecordingLibrary.cookieHeader([Self.cookie], for: studip), "Studip_Session=erfunden")
        XCTAssertNil(RecordingLibrary.cookieHeader([Self.cookie], for: oc))
        XCTAssertTrue(RecordingLibrary.matches(HTTPCookie(properties: [.name: "a", .value: "b", .domain: ".uni-hannover.de", .path: "/"])!, studip))
        // der Abgleich der App gibt die Cookies seines Containers mit
        let s = try sync(dev)
        XCTAssertTrue(s.recordings.cookies(for: studip).isEmpty, "ohne gespeicherte Sitzung keine Cookies")
        XCTAssertEqual(s.recordings.sessionConfiguration.httpCookieAcceptPolicy, .never, "Antwort-Cookies des Videoservers bleiben draussen")
    }
}

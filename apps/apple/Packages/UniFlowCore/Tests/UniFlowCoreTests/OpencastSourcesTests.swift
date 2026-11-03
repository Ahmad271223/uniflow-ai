import Foundation
import XCTest
@testable import UniFlowCore

// Aufzeichnungen aus weiteren Quellen (03.11.2026): Listenseiten des LUH-Plugins mit Seitenzahlen und Reitern, Seiten
// ohne Tabelle (<video>, JSON im <script>, Player-iframe), das Opencast-Plugin V3 (JSON-Routen), Videodateien im
// Dateibaum, Medienbloecke der Courseware und Links auf Videoplattformen in der Kursbeschreibung. Erfundene Seiten aus
// packages/shared-contracts/fixtures/opencast, Rechner *.example.test.

private func fixture(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/opencast/\(name)"), encoding: .utf8)
}

private let clock = UniFlowClock.fixed(berlin: "2026-11-10T12:00:00")!
private let base = URL(string: "https://studip.example.test")!

private func unix(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Int {
    BerlinClock.utcSeconds(day: BerlinClock.dayNumber(year: y, month: m, day: d), minutes: hour * 60)
}

private func page(_ html: String, status: Int = 200, type: String = "text/html; charset=UTF-8", path: String? = nil) -> HTTPReply {
    HTTPReply(status: status, contentType: type, finalURL: path.flatMap { URL(string: "https://studip.example.test/" + $0) }, body: Data(html.utf8))
}

/// Feste Antworten je Pfad mit Abfrage; andere Pfade 404 (HTML). Merkt sich jede Adresse.
private final class SourcesTransport: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private var log: [URL] = []

    init(_ routes: [String: HTTPReply]) { self.routes = routes }

    var requested: [URL] { lock.lock(); defer { lock.unlock() }; return log }
    var keys: [String] { requested.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        record(url)
        return routes[url.path + (url.query.map { "?" + $0 } ?? "")] ?? HTTPReply(status: 404, contentType: "text/html", body: Data("<html>Nicht gefunden</html>".utf8))
    }

    private func record(_ url: URL) { lock.lock(); log.append(url); lock.unlock() }
}

private func cwVideo(_ e: String, _ n: String) -> OpencastVideo {
    OpencastVideo(id: "cw:\(e):\(n)", title: "Video \(n)", playerURL: URL(string: "https://studip.example.test/cw/\(e)"), source: OpencastVideo.sourceCourseware,
                  linkURL: URL(string: "https://vimeo.com/\(n)"))
}

private func client(_ t: SourcesTransport) -> StudIPClient { StudIPClient(base: base, transport: t, pauseMillis: 0) }
private func mediaPath(_ course: String) -> String { "/" + OpencastParser.mediaIndexPath(courseID: course) }

private let courses = [
    StudIPCourse(id: "k1", title: "Testanalysis I", semesterTitle: "WiSe 2026/27", description: "Vorlesung. Aufzeichnungen: https://www.youtube.com/playlist?list=PLabc123 und Sprechstunde https://www.example.org/institut",
                 miscellaneous: #"Zoom-Mitschnitte: <a href="https://uni.zoom.us/rec/share/abc?pwd=x&amp;y=1">Aufzeichnung 1</a>, Zoom-Raum https://uni.zoom.us/j/123456"#),
    StudIPCourse(id: "k2", title: "Testprogrammierung", semesterTitle: "WiSe 2026/27"),
]

private func backend() async throws -> LocalBackend {
    let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
    try await b.context.database.transaction { c in
        try StudIPLibrary.storeCourses(c, courses, startedAt: clock.nowISO)
        // eine Datei vom Semesterbeginn (Montag, 12.10.2026): daran haengt die Zaehlung der Lehrwochen (`StudyWeeks.semesterStart`)
        try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f-seed', 'k1', 'Organisatorisches.pdf', ?, 'pdf')",
                      [.integer(Int64(unix(2026, 10, 12)))])
        try LocalModules.ensureModules(c, clock: clock)
    }
    return b
}

private func moduleID(_ b: LocalBackend, _ name: String) async throws -> Int {
    let id = try await b.context.database.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int
    return try XCTUnwrap(id, name)
}

private func entries(_ b: LocalBackend, _ module: Int) async throws -> [OpencastEntry] {
    try await b.context.database.withConnection { try OpencastStore.moduleBlocks($0, moduleID: module, clock: clock) }.flatMap(\.entries)
}

final class OpencastSourcesTests: XCTestCase {

    // MARK: LUH-Plugin: weitere Seiten und Reiter

    func testListingFollowsPagesAndSeriesTabsOnce() async throws {
        let first = try fixture("media-index-paged.html")
        let pageURL = URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=k1")
        XCTAssertEqual(OpencastParser.furtherPages(html: first, courseID: "k1", pageURL: pageURL),
                       ["plugins.php/opencastpluginluh/media/index?cid=k1&series=serie-b", "plugins.php/opencastpluginluh/media/index?cid=k1&page=2"],
                       "Reiter und Seite 2 je einmal; nicht die Seite selbst, Hochladen, Dateien oder ein anderer Kurs")
        let t = SourcesTransport([
            mediaPath("k1"): page(first, path: OpencastParser.mediaIndexPath(courseID: "k1")),
            mediaPath("k1") + "&page=2": page(try fixture("media-index-page2.html"), path: OpencastParser.mediaIndexPath(courseID: "k1") + "&page=2"),
            mediaPath("k1") + "&series=serie-b": page(try fixture("media-index-series-b.html")),
        ])
        let listing = try await client(t).opencastListing(courseID: "k1")
        guard case .videos(let v)? = listing else { return XCTFail("keine Liste: \(String(describing: listing))") }
        XCTAssertEqual(v.map(\.id), ["p1-0001", "sb-0003", "p2-0002"], "jedes Video einmal, in der Reihenfolge der Seiten")
        XCTAssertEqual(v[2].media.map(\.quality), ["720p"])
        XCTAssertEqual(t.keys, [mediaPath("k1"), mediaPath("k1") + "&series=serie-b", mediaPath("k1") + "&page=2"], "Seite 1 nicht erneut (Link von Seite 2)")
    }

    func testPageWithoutTableButWithVideosIsAListing() throws {
        let html = try fixture("media-index-embedded.html")
        let pageURL = URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=k1")
        guard case .videos(let v) = OpencastParser.parse(html: html, status: 200, pageURL: pageURL) else { return XCTFail("keine Liste") }
        XCTAssertEqual(v.map(\.id), ["tok-0006", "emb-0005", "emb-0007"])
        let json = v[0]
        XCTAssertEqual(json.title, "6. Vorlesung – Reihen")
        XCTAssertEqual(json.duration, 5400)
        XCTAssertEqual(json.author, "Prof. Dr. Erika Beispiel")
        XCTAssertEqual(json.created, StudIPLibrary.unixTime("2026-11-13T10:15:00+01:00"))
        XCTAssertEqual(json.thumbnailURL?.lastPathComponent, "ep-0006.jpg")
        XCTAssertEqual(json.media.map(\.quality), ["1080p", "720p", "720p Folien"], "Kamera vor Folien, Audio zaehlt nicht")
        XCTAssertNil(json.playerURL, "ohne Plugin-Pfad kein Player-Link")
        let video = v[1]
        XCTAssertEqual(video.title, "5. Vorlesung – Mitschnitt")
        XCTAssertEqual(video.media.map(\.url.lastPathComponent), ["emb-0005.mp4", "emb-0005.webm"])
        XCTAssertEqual(video.thumbnailURL?.lastPathComponent, "emb-0005.jpg")
        let frame = v[2]
        XCTAssertEqual(frame.title, "7. Vorlesung – Livestream-Aufzeichnung")
        XCTAssertEqual(frame.playerURL?.path, "/plugins.php/opencastv3/redirect/perform/video/tok-0007", "Player des Plugins V3 auf dem Stud.IP-Host")
        XCTAssertTrue(frame.media.isEmpty)
        XCTAssertEqual(RecordingPlayback.source(for: frame, local: nil), .webPlayer(frame.playerURL!))
        // ohne Tabelle und ohne Videos bleibt die Seite unklar
        XCTAssertEqual(OpencastParser.parse(html: "<html><body><p>Startseite</p><script>var a = [{\"x\": 1}];</script></body></html>", status: 200), .unrecognized)
    }

    // MARK: Opencast-Plugin V3

    func testV3VideosFixture() throws {
        let json = try JSONValue.parse(try fixture("v3-course-videos.json"))
        let v = OpencastV3.videos(from: json, courseID: "k1", base: base, prefix: "opencastv3")
        XCTAssertEqual(v.map(\.id), ["tok-0021", "tok-0022"], "Papierkorb faellt weg")
        let a = v[0]
        XCTAssertEqual(a.title, "Vorlesung 3: Grenzwerte")
        XCTAssertEqual(a.description, "Mitschnitt vom 06.11.")
        XCTAssertEqual(a.duration, 5339)
        XCTAssertEqual(a.author, "Prof. Dr. Erika Beispiel")
        XCTAssertEqual(a.created, 1_793_955_600, "created (ISO) vor mkdate")
        XCTAssertEqual(a.thumbnailURL?.absoluteString, "https://oc.example.test/t/ep-0021.jpg")
        XCTAssertEqual(a.playerURL?.absoluteString, "https://studip.example.test/plugins.php/opencastv3/redirect/perform/video/tok-0021?cid=k1")
        XCTAssertEqual(a.media.map(\.quality), ["1080p", "720p", "720p Folien"], "http-Fassung und Audio fallen weg")
        XCTAssertEqual(a.media.map(\.height), [1080, 720, 720])
        XCTAssertEqual(RecordingPlayback.quality(for: a)?.url.lastPathComponent, "ep-0021-720.mp4")
        let b = v[1]
        XCTAssertNil(b.description)
        XCTAssertNil(b.author)
        XCTAssertEqual(b.created, 1_793_350_800, "mkdate, wenn created fehlt")
        XCTAssertTrue(b.media.isEmpty)
        XCTAssertNil(b.thumbnailURL)
        XCTAssertEqual(RecordingPlayback.source(for: b, local: nil), .webPlayer(b.playerURL!))
        XCTAssertTrue(OpencastV3.isPluginLink("/plugins.php/opencastv3/course/index?cid=k1"))
        XCTAssertTrue(OpencastV3.isPluginLink("https://studip.example.test/plugins.php/opencast/course/index?cid=k1"))
        XCTAssertFalse(OpencastV3.isPluginLink("/plugins.php/opencastpluginluh/media/index?cid=k1"), "das LUH-Plugin ist nicht V3")
        XCTAssertEqual(OpencastV3.height("1920 * 1080 px"), 1080)
        XCTAssertEqual(OpencastV3.height("1280x720"), 720)
        XCTAssertEqual(OpencastV3.height("128 kbit/s"), 0)
    }

    func testV3ListingWhenTheLUHPluginIsMissing() async throws {
        let api = "/plugins.php/opencastv3/api/courses/k1/videos?offset=0&limit=100&cid=k1"
        let t = SourcesTransport([
            mediaPath("k1"): page(try fixture("media-index-no-plugin.html"), status: 500),
            api: page(try fixture("v3-course-videos.json"), type: "application/json"),
        ])
        let listing = try await client(t).opencastListing(courseID: "k1")
        guard case .videos(let v)? = listing else { return XCTFail("keine Liste: \(String(describing: listing))") }
        XCTAssertEqual(v.map(\.id), ["tok-0021", "tok-0022"])
        XCTAssertEqual(t.keys, [mediaPath("k1"), api], "count 3 = Seite: keine zweite Seite")

        // beide Pfade ohne JSON: kein Opencast wie bisher; ein Kurs mit Reiter bleibt bei 404 unveraendert (keine V3-Anfrage)
        let none = SourcesTransport([mediaPath("k1"): page(try fixture("media-index-no-plugin.html"), status: 500)])
        let n = try await client(none).opencastListing(courseID: "k1")
        XCTAssertEqual(n, .noOpencast)
        XCTAssertEqual(none.keys.count, 3)
        let known = SourcesTransport([:])
        let k = try await client(known).opencastListing(courseID: "k1", knownAvailable: true)
        XCTAssertNil(k)
        XCTAssertEqual(known.keys.count, 1)

        // unklare Seite, im Kursueberblick der Reiter des Plugins V3: dessen Liste (mit dem Pfad aus dem Link)
        let overview = SourcesTransport([
            mediaPath("k1"): page("<html><body>Wartungsarbeiten</body></html>", status: 503),
            "/dispatch.php/course/overview?cid=k1": page(#"<ul id="tabs"><li><a href="/dispatch.php/course/overview?cid=k1">Übersicht</a></li><li><a href="/plugins.php/opencastv3/course/index?cid=k1">Opencast</a></li></ul>"#,
                                                        path: "dispatch.php/course/overview?cid=k1"),
            api: page(try fixture("v3-course-videos.json"), type: "application/json"),
        ])
        guard case .videos(let o)? = try await client(overview).opencastListing(courseID: "k1") else { return XCTFail("keine Liste ueber den Ueberblick") }
        XCTAssertEqual(o.count, 2)
        XCTAssertEqual(overview.keys, [mediaPath("k1"), "/dispatch.php/course/overview?cid=k1", api])
    }

    func testV3ListingReadsAllPages() async throws {
        func body(_ ids: [String], count: Int) -> HTTPReply {
            let videos = ids.map { #"{"token": "\#($0)", "episode": "e-\#($0)", "title": "Video \#($0)", "publication": {"downloads": []}}"# }.joined(separator: ",")
            return page(#"{"videos": [\#(videos)], "count": \#(count)}"#, type: "application/json")
        }
        let t = SourcesTransport([
            mediaPath("k1"): page(try fixture("media-index-no-plugin.html"), status: 500),
            "/plugins.php/opencastv3/api/courses/k1/videos?offset=0&limit=100&cid=k1": body(["a", "b"], count: 3),
            "/plugins.php/opencastv3/api/courses/k1/videos?offset=2&limit=100&cid=k1": body(["b", "c"], count: 3),
        ])
        guard case .videos(let v)? = try await client(t).opencastListing(courseID: "k1") else { return XCTFail("keine Liste") }
        XCTAssertEqual(v.map(\.id), ["a", "b", "c"])
    }

    // MARK: Courseware-Bloecke

    func testCoursewareMediaBlocks() throws {
        let json = try JSONValue.parse(try fixture("courseware-media-blocks.json"))
        let blocks = (json["included"]?.array ?? []).filter { $0["type"]?.string == "courseware-blocks" }
        let v = CoursewareMedia.videos(blocks: blocks, courseID: "k1", elementID: "e1", elementTitle: "Woche 1", base: "https://studip.example.test/")
        XCTAssertEqual(v.map(\.id), ["cw:e1:b-video-file", "cw:e1:b-video-url", "cw:e1:b-link-video", "cw:e1:b-iframe", "cw:e1:b-embed",
                                     "cw:e1:b-audio", "cw:e1:b-oc", "cw:e1:b-video-mp4"],
                       "Institutslink, interner Link, leeres Audio und leeres Video zaehlen nicht")
        let page = "https://studip.example.test/dispatch.php/course/courseware/?cid=k1#/structural_element/e1"
        XCTAssertTrue(v.allSatisfy { $0.playerURL?.absoluteString == page && $0.source == OpencastVideo.sourceCourseware }, "jeder Block oeffnet seine Seite in Stud.IP")
        XCTAssertEqual(v[0].title, "Vorlesung 1 (Aufzeichnung)")
        XCTAssertEqual(v[0].description, "Woche 1")
        XCTAssertEqual(v[0].media.map(\.url.absoluteString), ["https://studip.example.test/jsonapi.php/v1/file-refs/f-video-1/content"], "Datei aus Stud.IP ueber die JSON:API")
        XCTAssertTrue(v[0].needsStudIPSession)
        XCTAssertEqual(v[1].title, "Woche 1", "ohne eigenen Titel der der Seite")
        XCTAssertNil(v[1].description)
        XCTAssertEqual(v[1].linkURL?.host, "www.youtube.com")
        XCTAssertTrue(v[1].media.isEmpty)
        XCTAssertEqual(v[2].title, "Zusatzvideo bei Vimeo")
        XCTAssertEqual(v[2].linkURL?.absoluteString, "https://vimeo.com/123456789")
        XCTAssertEqual(v[3].linkURL?.host, "oc.example.test")
        XCTAssertEqual(v[4].linkURL?.host, "player.vimeo.com")
        XCTAssertEqual(v[5].media.first?.url.lastPathComponent, "content")
        XCTAssertNil(v[6].linkURL)
        XCTAssertTrue(v[6].media.isEmpty)
        XCTAssertEqual(v[7].media.map(\.url.absoluteString), ["https://cdn.example.test/v/uebung-1.mp4"], "mp4-Adresse ausserhalb: Stream ohne Sitzung")
        XCTAssertFalse(v[7].needsStudIPSession)
    }

    func testStoredCoursewareVideosFollowTheReadPages() async throws {
        let b = try await backend()
        let db = b.context.database
        let now = clock.nowISO
        try await db.transaction { c in
            try OpencastStore.storeCoursewareVideos(c, courseID: "k1", [cwVideo("e1", "1"), cwVideo("e1", "2"), cwVideo("e2", "3")],
                                                    readElements: ["e1", "e2"], seenElements: ["cw-e1", "cw-e2"], complete: true, now: now)
        }
        func ids() async throws -> [String] { try await db.rows("SELECT id FROM opencast_videos WHERE source='courseware' ORDER BY id").compactMap { $0["id"]?.string } }
        var list = try await ids()
        XCTAssertEqual(list, ["cw:e1:1", "cw:e1:2", "cw:e2:3"])
        // nur Seite e1 neu gelesen (ein Block weniger): e2 bleibt
        try await db.transaction { c in
            try OpencastStore.storeCoursewareVideos(c, courseID: "k1", [cwVideo("e1", "1")], readElements: ["e1"], seenElements: ["cw-e1", "cw-e2"], complete: true, now: now)
        }
        list = try await ids()
        XCTAssertEqual(list, ["cw:e1:1", "cw:e2:3"])
        // Seite e2 gibt es nicht mehr (vollstaendig gelesen, nicht gesehen): weg; unvollstaendig: bleibt
        try await db.transaction { c in
            try OpencastStore.storeCoursewareVideos(c, courseID: "k1", [], readElements: [], seenElements: ["cw-e1"], complete: false, now: now)
        }
        list = try await ids()
        XCTAssertEqual(list, ["cw:e1:1", "cw:e2:3"])
        try await db.transaction { c in
            try OpencastStore.storeCoursewareVideos(c, courseID: "k1", [], readElements: [], seenElements: ["cw-e1"], complete: true, now: now)
        }
        list = try await ids()
        XCTAssertEqual(list, ["cw:e1:1"])
        let ana = try await moduleID(b, "Testanalysis I")
        let e = try await entries(b, ana).filter { $0.video.source == OpencastVideo.sourceCourseware }
        XCTAssertEqual(e.map(\.video.title), ["Video 1"])
        XCTAssertEqual(e.first?.video.linkURL?.host, "vimeo.com")
        XCTAssertEqual(RecordingPlayback.source(for: e[0].video, local: nil), .webPlayer(URL(string: "https://studip.example.test/cw/e1")!))
    }

    // MARK: Videodateien im Dateibaum

    func testFileVideosFromTheFileTree() async throws {
        let b = try await backend()
        let db = b.context.database
        func file(_ id: String, _ name: String, size: Int = 300_000_000, mime: String? = nil, downloadable: Bool = true, changed: String = "2026-10-20T10:00:00+02:00") -> StudIPFile {
            StudIPFile(id: id, courseID: "k1", name: name, size: size, mimeType: mime, changed: changed, isDownloadable: downloadable, folderPath: "Vorlesung/Videos")
        }
        let files = [file("f1", "VL02 Aufzeichnung.mp4"), file("f2", "Folien 02.pdf", mime: "application/pdf"),
                     file("f3", "VL03.mov", downloadable: false), file("f4", "Uebung 2.webm", size: 0, mime: "video/webm", changed: "2026-10-27T10:00:00+01:00"),
                     file("f5", "Mitschnitt", mime: "video/mp4", changed: "2026-11-03T10:00:00+01:00")]
        XCTAssertTrue(OpencastFileVideos.isVideo(files[0]))
        XCTAssertFalse(OpencastFileVideos.isVideo(files[1]))
        XCTAssertFalse(OpencastFileVideos.isVideo(files[2]), "nicht herunterladbar: auch nicht abspielbar")
        XCTAssertTrue(OpencastFileVideos.isVideo(files[4]), "Typ video/* ohne Endung")
        let new = try await db.transaction { try OpencastStore.storeFileVideos($0, courseID: "k1", files, complete: true, now: clock.nowISO, base: base) }
        XCTAssertEqual(new, 3)
        let ana = try await moduleID(b, "Testanalysis I")
        let e = try await entries(b, ana).filter { $0.video.source == OpencastVideo.sourceFile }
        XCTAssertEqual(e.map(\.video.id), ["file:f1", "file:f4", "file:f5"])
        XCTAssertEqual(e.map(\.week), [2, 2, 4], "Nummer aus dem Namen (VL02, Uebung 2), sonst die Woche der Aenderung (03.11.)")
        let a = e[0]
        XCTAssertEqual(a.video.title, "VL02 Aufzeichnung.mp4")
        XCTAssertEqual(a.video.description, "Vorlesung/Videos")
        XCTAssertEqual(a.video.size, 300_000_000)
        XCTAssertEqual(a.video.media.map(\.quality), ["Original"])
        XCTAssertEqual(a.video.media.first?.url.absoluteString, "https://studip.example.test/jsonapi.php/v1/file-refs/f1/content")
        XCTAssertTrue(a.video.needsStudIPSession)
        XCTAssertEqual(a.video.fileExtension, "mp4")
        XCTAssertEqual(e[1].video.fileExtension, "webm")
        XCTAssertEqual(e[2].video.fileExtension, "mp4", "ohne Endung mp4")
        XCTAssertNil(e[1].video.size, "Groesse 0 = unbekannt")
        XCTAssertEqual(RecordingPlayback.source(for: a.video, local: nil), .stream(a.video.media[0].url, quality: "Original"))
        XCTAssertEqual(RecordingFiles.relativePath(courseID: "k1", videoID: e[1].video.id, quality: "Original", ext: e[1].video.fileExtension), "k1/file_f4-Original.webm")

        // ein Opencast-Abruf des Kurses (leere Liste) laesst die Dateien stehen; ein unvollstaendiger Dateibaum entfernt nichts
        var f = OpencastFetch(courses: courses, checkedAt: unix(2026, 11, 10))
        f.listings["k1"] = .videos([])
        let fetched = f
        _ = try await db.transaction { try OpencastStore.store(fetched, in: $0, clock: clock) }
        _ = try await db.transaction { try OpencastStore.storeFileVideos($0, courseID: "k1", [files[0]], complete: false, now: clock.nowISO, base: base) }
        var left = try await entries(b, ana).filter { $0.video.source == OpencastVideo.sourceFile }.map(\.video.id)
        XCTAssertEqual(left, ["file:f1", "file:f4", "file:f5"])
        // vollstaendige Liste ohne f4 und f5: weg (ohne geladene Datei)
        _ = try await db.transaction { try OpencastStore.storeFileVideos($0, courseID: "k1", [files[0], files[1]], complete: true, now: clock.nowISO, base: base) }
        left = try await entries(b, ana).filter { $0.video.source == OpencastVideo.sourceFile }.map(\.video.id)
        XCTAssertEqual(left, ["file:f1"])

        // vom Abgleich frueher geladene Datei: als Fassung "Original" uebernommen
        try await db.transaction { c in
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path) VALUES ('f1', 'k1', 'VL02 Aufzeichnung.mp4', 0, 'file', 'StudIP/files/f1/VL02 Aufzeichnung.mp4')")
            try OpencastStore.storeFileVideos(c, courseID: "k1", [files[0]], complete: true, now: clock.nowISO, base: base)
        }
        let loaded = try await db.withConnection { try OpencastStore.entry($0, courseID: "k1", videoID: "file:f1", clock: clock) }
        XCTAssertEqual(loaded?.localPath, "StudIP/files/f1/VL02 Aufzeichnung.mp4")
        XCTAssertEqual(loaded?.localQuality, "Original")
    }

    // MARK: Links in der Kursbeschreibung

    func testVideoLinksInCourseTexts() async throws {
        let text = courses[0].description! + "\n" + courses[0].miscellaneous!
        XCTAssertEqual(VideoLinks.links(in: text).map(\.absoluteString),
                       ["https://www.youtube.com/playlist?list=PLabc123", "https://uni.zoom.us/rec/share/abc?pwd=x&y=1"],
                       "Institutsseite und Zoom-Raum zaehlen nicht; &amp; dekodiert")
        XCTAssertEqual(VideoLinks.links(in: "Siehe https://av.tib.eu/media/12345. Oder https://panopto.example.test/Panopto/Pages/Viewer.aspx?id=1, BBB: https://bbb.example.test/playback/presentation/2.3/abc").count, 3)
        XCTAssertTrue(VideoLinks.links(in: "https://www.example.org/x.mp4 und https://example.org/index.html").map(\.lastPathComponent) == ["x.mp4"])
        XCTAssertEqual(VideoLinks.videos(in: text).map(\.title), ["youtube.com · playlist", "uni.zoom.us · abc"])

        let b = try await backend()
        let ana = try await moduleID(b, "Testanalysis I")
        let e = try await entries(b, ana)
        XCTAssertEqual(e.map(\.video.source), [OpencastVideo.sourceLink, OpencastVideo.sourceLink], "ohne Tabellen nur die Links")
        XCTAssertEqual(e.map(\.week), [0, 0])
        XCTAssertEqual(e.first?.label, "Vorlesung")
        XCTAssertEqual(e.first?.video.linkURL?.host, "www.youtube.com")
        XCTAssertNil(e.first?.video.playerURL)
        XCTAssertEqual(RecordingPlayback.source(for: e[0].video, local: nil), .unavailable, "Links oeffnet der Browser, nicht der Player")
        let blocks = try await b.context.database.withConnection { try OpencastStore.moduleBlocks($0, moduleID: ana, clock: clock) }
        XCTAssertEqual(blocks.map(\.label), ["Vor Vorlesungsbeginn"])
        let prog = try await moduleID(b, "Testprogrammierung")
        let none = try await entries(b, prog)
        XCTAssertTrue(none.isEmpty)
        // kein Vorschlag zu einem Dokument aus einem Link
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f-vl', 'k1', 'VL01 playlist.pdf', ?, 'pdf')", [.integer(Int64(unix(2026, 10, 13)))])
        }
        let m = try await b.context.database.withConnection { try OpencastStore.match($0, fileID: "f-vl", text: "youtube playlist", clock: clock) }
        XCTAssertNil(m)
    }

    // MARK: Tabellen aelterer Geraete

    func testOldTableGetsTheNewColumns() async throws {
        let b = try await backend()
        let db = b.context.database
        try await db.transaction { c in
            try c.executeScript("""
                CREATE TABLE opencast_courses (course_id TEXT PRIMARY KEY, status TEXT NOT NULL, checked_at INTEGER NOT NULL);
                CREATE TABLE opencast_videos (course_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, description TEXT, duration INTEGER,
                    author TEXT, created INTEGER, thumbnail_url TEXT, player_url TEXT, media TEXT NOT NULL DEFAULT '[]', first_seen TEXT,
                    fetched_at TEXT, gone INTEGER NOT NULL DEFAULT 0, position REAL, local_path TEXT, local_quality TEXT, PRIMARY KEY (course_id, id));
                INSERT INTO opencast_videos(course_id, id, title, position) VALUES ('k1', 'alt-1', 'Altes Video', 42);
                """)
        }
        var f = OpencastFetch(courses: courses, checkedAt: unix(2026, 11, 10))
        f.listings["k1"] = .videos([OpencastVideo(id: "alt-1", title: "Altes Video"), OpencastVideo(id: "neu-2", title: "Neues Video")])
        let fetched = f
        let r = try await db.transaction { try OpencastStore.store(fetched, in: $0, clock: clock) }
        XCTAssertEqual(r, OpencastStoreResult(newVideos: 1, videos: 2))
        let cols = try await db.withConnection { try $0.columnNames("opencast_videos") }
        XCTAssertTrue(cols.contains("source") && cols.contains("link_url") && cols.contains("size"), "\(cols)")
        let ana = try await moduleID(b, "Testanalysis I")
        let e = try await entries(b, ana).filter { $0.video.source == OpencastVideo.sourceOpencast }
        XCTAssertEqual(e.map(\.video.id), ["alt-1", "neu-2"])
        XCTAssertEqual(e.first?.position, 42)
    }
}

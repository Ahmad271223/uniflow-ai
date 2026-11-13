import Combine
import XCTest
import UniFlowCore
@testable import UniFlow

/// Tempo des Stud.IP-Abgleichs (Beschwerde des Inhabers 07.11.2026: jeder Lauf prueft alle bekannten Kurse und Ordner
/// erneut, obwohl nur wenige Dateien dazukommen). Nachbau mit erfundenen Daten (example.org-Namen, nie ein echter
/// Abruf): sechs aktuelle Kurse mit je vier Ordnern in drei Ebenen. Gezaehlt werden die Anfragen eines zweiten Laufs
/// ohne Aenderung und die Schritte nacheinander (Wartezeit bei Netzlatenz).
@MainActor
final class StudIPSyncSpeedAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-07T10:00:00")!
    private static let courseCount = 6

    private struct Device {
        let host: LocalBackendHost
        let studipRoot: URL
    }

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-speed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(host: host, studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-speed-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Stud.IP mit festen Antworten; zaehlt Abrufe und die hoechste Zahl gleichzeitiger Anfragen. `latencyMillis`:
    /// Wartezeit je Antwort (Netz)
    final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [String] = []
        private var open = 0
        private(set) var maxOpen = 0
        var latencyMillis: UInt64 = 0
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }
        func clear() { lock.lock(); log.removeAll(); maxOpen = 0; lock.unlock() }
        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; lock.unlock() }
        func json(_ path: String, _ text: String) { set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))) }
        func remove(_ path: String) { lock.lock(); routes[path] = nil; lock.unlock() }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: StudIPSync.base.absoluteString, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock()
            log.append(key)
            open += 1
            maxOpen = max(maxOpen, open)
            let r = routes[key]
            lock.unlock()
            if latencyMillis > 0 { try? await Task.sleep(nanoseconds: latencyMillis * 1_000_000) }
            lock.lock(); open -= 1; lock.unlock()
            return r ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }

        func count(_ pred: (String) -> Bool) -> Int { requested.filter(pred).count }
    }

    private static func pdf(_ marker: String) -> Data {
        // kleines gueltiges PDF reicht fuer den Abgleich (Inhalt egal, nur keine Webseite)
        Data("%PDF-1.4\n% \(marker)\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8)
    }

    /// Ordner je Kurs: Wurzel r, darunter a (darunter a1) und b; je Ordner zwei Dateien
    static let folders: [(id: String, parent: String?, name: String)] = [("r", nil, ""), ("a", "r", "Vorlesung"), ("a1", "a", "Folien"), ("b", "r", "Uebung")]

    private func fileRefs(_ course: Int, _ folder: String, extra: Int = 0, drop: Int = 0) -> String {
        let refs = ((1 + drop)...(2 + extra)).map { k in
            let file = Self.pdf("k\(course)\(folder)\(k)")
            return #"{"id":"f\#(course)\#(folder)\#(k)","type":"file-refs","attributes":{"name":"Blatt \#(folder)\#(k).pdf","filesize":\#(file.count),"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}"#
        }
        return #"{"data":[\#(refs.joined(separator: ","))]}"#
    }

    private func portal() -> FakeStudIP {
        let t = FakeStudIP()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        let courses = (1...Self.courseCount).map { i in
            #"{"id":"c\#(i)","type":"courses","attributes":{"title":"Vorlesung Beispiel \#(i)"},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}},"end-semester":{"data":{"type":"semesters","id":"s1"}}}}"#
        }.joined(separator: ",")
        let sem = #"{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00","end":"2027-03-31T23:59:59+02:00"}}"#
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"{"data":[\#(courses)],"included":[\#(sem)]}"#)
        t.json("/jsonapi.php/v1/users/u1/schedule", #"{"data":[],"links":{}}"#)
        for i in 1...Self.courseCount {
            // flache Liste aller Ordner mit Beziehung parent (Stud.IP-Doku JSON:API, Dateibereich)
            let flat = Self.folders.map { f in
                let type = f.parent == nil ? "RootFolder" : "StandardFolder"
                let parent = f.parent.map { #","relationships":{"parent":{"data":{"type":"folders","id":"\#($0)\#(i)"}}}"# } ?? ""
                return #"{"id":"\#(f.id)\#(i)","type":"folders","attributes":{"folder-type":"\#(type)","name":"\#(f.name)"}\#(parent)}"#
            }.joined(separator: ",")
            t.json("/jsonapi.php/v1/courses/c\(i)/folders?page[limit]=200", #"{"data":[\#(flat)]}"#)
            for f in Self.folders {
                t.json("/jsonapi.php/v1/folders/\(f.id)\(i)/file-refs?page[limit]=500", fileRefs(i, f.id))
                let subs = Self.folders.filter { $0.parent == f.id }.map { s in
                    #"{"id":"\#(s.id)\#(i)","type":"folders","attributes":{"folder-type":"StandardFolder","name":"\#(s.name)"}}"#
                }.joined(separator: ",")
                t.json("/jsonapi.php/v1/folders/\(f.id)\(i)/folders?page[limit]=200", #"{"data":[\#(subs)]}"#)
                for k in 1...4 {
                    t.set("/jsonapi.php/v1/file-refs/f\(i)\(f.id)\(k)/content",
                          HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("k\(i)\(f.id)\(k)")))
                }
            }
        }
        return t
    }

    private func client(_ t: FakeStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 2, delayNanos: { _ in 0 }))
    }

    private static func isListing(_ p: String) -> Bool { p.contains("/folders") || p.contains("/file-refs?") }

    private func report(_ label: String, _ t: FakeStudIP) {
        let all = t.requested
        let listing = all.filter(Self.isListing).count
        let downloads = all.filter { $0.hasSuffix("/content") }.count
        print("SPEED \(label): \(all.count) Anfragen, davon Dateilisten \(listing), Downloads \(downloads), gleichzeitig hoechstens \(t.maxOpen)")
        print("SPEED \(label) sonst: " + all.filter { !Self.isListing($0) && !$0.hasSuffix("/content") }
            .map { $0.replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression) }.joined(separator: " | "))
    }

    /// Zweiter Lauf ohne Aenderung: wenige Anfragen fuer die Dateilisten, keine Downloads, alle Dateien bleiben
    func testSecondRunWithoutChangesNeedsFewListingRequests() async throws {
        let dev = try device()
        let stud = portal()
        let defaults = try defaults()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: defaults)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        report("erster Lauf", stud)
        let firstFiles = sync.entries.count
        XCTAssertEqual(firstFiles, Self.courseCount * Self.folders.count * 2)

        stud.clear()
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        report("zweiter Lauf", stud)
        XCTAssertEqual(sync.entries.count, firstFiles, "keine Datei verloren")
        XCTAssertEqual(stud.count { $0.hasSuffix("/content") }, 0, "unveraenderte Dateien nie neu laden")
        // je Kurs: Ordnerliste + Dateiliste je Ordner (vorher zusaetzlich die Unterordner je Ordner)
        XCTAssertEqual(stud.count(Self.isListing), Self.courseCount * (1 + Self.folders.count))
        XCTAssertFalse(stud.requested.contains { $0.hasSuffix("/folders?page[limit]=200") && $0.contains("/folders/") },
                       "keine Unterordner-Abfrage je Ordner, wenn die flache Liste bestaetigt ist")
    }

    /// Neue Datei, geaenderte Datei, geloeschte Datei und ein neuer Unterordner werden im zweiten Lauf erkannt
    func testSecondRunStillFindsNewChangedGoneFilesAndNewFolder() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let before = sync.entries.count

        // Kurs 1: neue Datei in a1; Kurs 2: neuer Unterordner n unter b mit einer Datei; Kurs 3: Datei in r entfernt
        stud.json("/jsonapi.php/v1/folders/a11/file-refs?page[limit]=500", fileRefs(1, "a1", extra: 1))
        let flat2 = (Self.folders + [("n", "b", "Neu")]).map { f in
            let type = f.parent == nil ? "RootFolder" : "StandardFolder"
            let parent = f.parent.map { #","relationships":{"parent":{"data":{"type":"folders","id":"\#($0)2"}}}"# } ?? ""
            return #"{"id":"\#(f.id)2","type":"folders","attributes":{"folder-type":"\#(type)","name":"\#(f.name)"}\#(parent)}"#
        }.joined(separator: ",")
        stud.json("/jsonapi.php/v1/courses/c2/folders?page[limit]=200", #"{"data":[\#(flat2)]}"#)
        stud.json("/jsonapi.php/v1/folders/b2/folders?page[limit]=200", #"{"data":[{"id":"n2","type":"folders","attributes":{"folder-type":"StandardFolder","name":"Neu"}}]}"#)
        stud.json("/jsonapi.php/v1/folders/n2/file-refs?page[limit]=500", fileRefs(2, "n"))
        stud.json("/jsonapi.php/v1/folders/n2/folders?page[limit]=200", #"{"data":[]}"#)
        for k in 1...2 { stud.set("/jsonapi.php/v1/file-refs/f2n\(k)/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("n\(k)"))) }
        stud.json("/jsonapi.php/v1/folders/r3/file-refs?page[limit]=500", fileRefs(3, "r", drop: 1))

        stud.clear()
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        let names = Set(sync.entries.map(\.name))
        XCTAssertTrue(names.contains("Blatt a13.pdf"), "neue Datei in bekanntem Ordner")
        XCTAssertTrue(names.contains("Blatt n1.pdf"), "Datei in neuem Unterordner")
        XCTAssertTrue(stud.requested.contains("/jsonapi.php/v1/folders/n2/file-refs?page[limit]=500"))
        XCTAssertEqual(stud.count { $0.hasSuffix("/content") }, 3, "nur die drei neuen Dateien geladen")
        XCTAssertTrue(sync.lastSummary?.contains("1 in Stud.IP nicht mehr vorhanden") == true, sync.lastSummary ?? "")
        XCTAssertEqual(sync.entries.count, before + 3)
    }

    /// Mit Netzlatenz: Anfragen laufen begrenzt gleichzeitig (hoechstens 4), nicht nacheinander
    func testRequestsRunInParallelWithLimit() async throws {
        let dev = try device()
        let stud = portal()
        stud.latencyMillis = 20
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        stud.clear()
        let start = Date()
        await sync.run(client: client(stud))
        let seconds = Date().timeIntervalSince(start)
        report(String(format: "zweiter Lauf mit 20 ms Latenz, %.2f s", seconds), stud)
        XCTAssertGreaterThan(stud.maxOpen, 1, "parallel")
        XCTAssertLessThanOrEqual(stud.maxOpen, StudIPClient.defaultConcurrency)
    }

    /// 11.11.2026 ("Sync dauert ewig"): "fertig" kommt, sobald Dateien, Stundenplan und Neuigkeiten da sind;
    /// Aufzeichnungen und Lernstoff laufen danach im selben Lauf, der Lernplan losgeloest danach
    func testReadyBeforeRecordingsTextsAndStudyPlan() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        var readyAt: Int?
        let watch = sync.$phase.sink { p in if p == .idle, readyAt == nil { readyAt = stud.requested.count } }
        defer { watch.cancel() }
        var planPhase: StudIPSync.Phase?
        StudIPSync.autoPlanStarted = { p in if planPhase == nil { planPhase = p } }
        defer { StudIPSync.autoPlanStarted = nil }
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertFalse(sync.finishingUp)
        let slow = { (p: String) in
            p.contains("courseware") || p.contains("wiki-pages") || p.contains("forum-categories") || p.contains("opencast")
                || p.contains("course/overview")
        }
        let all = stud.requested
        let firstSlow = try XCTUnwrap(all.firstIndex(where: slow), "Aufzeichnungen und Lernstoff wurden gefragt")
        let ready = try XCTUnwrap(readyAt, "fertig gemeldet")
        XCTAssertGreaterThanOrEqual(firstSlow, ready, "fertig vor Aufzeichnungen und Lernstoff")
        XCTAssertTrue(all[..<ready].allSatisfy { !slow($0) })
        XCTAssertEqual(planPhase, .idle, "Lernplan erst nach fertig")
        XCTAssertEqual(sync.entries.count, Self.courseCount * Self.folders.count * 2)
        // der Abgleich der App wartet nicht mehr zwischen den Anfragen (die Grenze von 4 zugleich bleibt)
        XCTAssertEqual(sync.liveClient([]).pauseMillis, 0)
        XCTAssertEqual(StudIPClient.defaultConcurrency, 4)
    }

    /// Flache Liste ohne Unterordner (andere Stud.IP-Fassung): keine Bestaetigung, weiter der Baum, keine Datei fehlt
    func testFlatListWithoutChildrenKeepsReadingTheTree() async throws {
        let dev = try device()
        let stud = portal()
        for i in 1...Self.courseCount {
            stud.json("/jsonapi.php/v1/courses/c\(i)/folders?page[limit]=200",
                      #"{"data":[{"id":"r\#(i)","type":"folders","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
        }
        let defaults = try defaults()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: defaults)
        await sync.run(client: client(stud))
        XCTAssertFalse(defaults.bool(forKey: StudIPSync.Keys.flatFolders))
        stud.clear()
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.entries.count, Self.courseCount * Self.folders.count * 2)
        XCTAssertEqual(stud.count(Self.isListing), Self.courseCount * (1 + 2 * Self.folders.count), "Baum wie bisher")
    }

    /// Vergleich reihum: ohne Bestaetigung alles ueber den Baum; bestaetigt hoechstens alle 12 Stunden ein Kurs
    func testFolderModesCheckOneCourseInTurn() {
        let now = Date()
        XCTAssertEqual(StudIPSync.folderModes(count: 3, trusted: false, lastCheck: nil, checkIndex: 0, now: now).modes, [.walk, .walk, .walk])
        let due = StudIPSync.folderModes(count: 3, trusted: true, lastCheck: now.addingTimeInterval(-13 * 3600), checkIndex: 4, now: now)
        XCTAssertEqual(due.modes, [.flat, .walk, .flat])
        XCTAssertEqual(due.checked, 1)
        let recent = StudIPSync.folderModes(count: 3, trusted: true, lastCheck: now.addingTimeInterval(-3600), checkIndex: 0, now: now)
        XCTAssertEqual(recent.modes, [.flat, .flat, .flat])
        XCTAssertNil(recent.checked)
        XCTAssertEqual(StudIPSync.downloadStep(0, of: 3, name: "Blatt.pdf"), "3 neue Dateien – lade 1 von 3: Blatt.pdf")
        XCTAssertEqual(StudIPSync.filesNote(loaded: 0), "Keine neuen Dateien")
    }
}

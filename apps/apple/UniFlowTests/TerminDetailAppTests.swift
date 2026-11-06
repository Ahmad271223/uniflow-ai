import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Termin-Detail (06.11.2026): Termin im Stundenplan antippen -> Raum und alle Lehrenden des Kurses. Raum antippen
/// startet die Route zu Fuss in Google Maps, E-Mail einer/eines Lehrenden oeffnet eine neue Uni-Mail mit Empfaenger,
/// "Allen Lehrenden schreiben" setzt alle Adressen in "An". Daten: lokales Backend (Raumfinder mit Demo-Treffern unter
/// XCTest), Lehrende erfunden (example.org) bzw. aus der Debug-Nachbildung, Uni-Mail ueber `UniStubProtocol` mit den
/// SOGo-Fixtures. Nie Netz, nie ein Passwort, gesendet wird nichts.
@MainActor
final class TerminDetailAppTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct AuthorizedChecker: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!
    private var opened: [URL] = []
    private var bed: ContainerTestBed?

    override func setUp() async throws {
        try await super.setUp()
        opened = []
        TerminOpen.handler = { [weak self] url in self?.opened.append(url) }
        TerminLecturersSection.tried = []
        TerminLecturersSection.fetchOverride = nil
        XCTAssertTrue(Self.accessibilityAutomation(true))
    }

    override func tearDown() async throws {
        Self.accessibilityAutomation(false)
        TerminOpen.handler = nil
        TerminLecturersSection.fetchOverride = nil
        UniStubProtocol.reset()
        if let bed { await bed.tearDown() }
        bed = nil
        try await super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-termin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    /// Geraet mit Modul, Kurs "c-ma" und einer Vorlesung am Donnerstag in "1101 - F102"; `lecturers`: zwei Dozent/innen
    /// und ein Tutor des Kurses (erfunden, wie nach dem Stud.IP-Abgleich gespeichert)
    private func device(university: UniversityKey = .luh, course: String = "c-ma", room: String = "1101 - F102",
                        lecturers: Bool = true) throws -> (LocalBackendHost, APIClient, Int) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock, university: university)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let id = try awaiting { () async throws -> Int in
            let b = try await host.backend()
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Mathematik für Ingenieure I', '#4f5bd5')")
                for cid in ["c-ma", "c-ma-ue"] {
                    try c.execute("INSERT INTO courses(id, title, kind, active, module_id, created_at) VALUES (?, ?, 'vorlesung', 1, 1, 't')",
                                  [.text(cid), .text(cid == "c-ma" ? "Mathematik für Ingenieure I" : "Übung zu Mathematik für Ingenieure I")])
                }
                guard lecturers else { return }
                try c.execute("""
                    CREATE TABLE IF NOT EXISTS studip_lecturers (course_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL,
                    position INTEGER, label TEXT, name TEXT, username TEXT, email TEXT, office_hours TEXT, location TEXT, institute TEXT,
                    fetched_at TEXT, PRIMARY KEY (course_id, user_id))
                    """)
                try c.execute("CREATE TABLE IF NOT EXISTS studip_lecturer_courses (course_id TEXT PRIMARY KEY, fetched_at TEXT NOT NULL)")
                let rows: [(String, String, Int, String, String, String, String)] = [
                    ("u-a", "dozent", 0, "Prof. Dr. Erika Beispiel", "ebeispiel", "erika.beispiel@example.org", "Di 10–11 Uhr"),
                    ("u-b", "dozent", 1, "Dr. Max Muster", "mmuster", "max.muster@example.org", ""),
                    ("u-t", "tutor", 2, "Erfundener Tutor", "etutor", "", ""),
                ]
                for r in rows {
                    try c.execute("""
                        INSERT INTO studip_lecturers(course_id, user_id, role, position, label, name, username, email, office_hours, location,
                        institute, fetched_at) VALUES ('c-ma', ?, ?, ?, '', ?, ?, ?, ?, '', '', '2026-11-05T09:00:00')
                        """, [.text(r.0), .text(r.1), .integer(Int64(r.2)), .text(r.3), .text(r.4), .text(r.5), .text(r.6)])
                }
                try c.execute("INSERT INTO studip_lecturer_courses(course_id, fetched_at) VALUES ('c-ma', '2026-11-05T09:00:00')")
            }
            let created = try await api.value("/api/timetable/events", method: "POST",
                                              body: ["title": "Mathematik für Ingenieure I", "kind": "vorlesung", "weekday": 3, "start_time": "10:00",
                                                     "end_time": "11:30", "rrule": "weekly", "room": .string(room), "module_id": 1,
                                                     "course_id": .string(course)])
            return try XCTUnwrap(created.i("id"))
        }
        return (host, api, id)
    }

    // MARK: Uni-Mail (SOGo nachgebaut wie UniMailAppTests)

    private func fx(_ name: String) throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/\(name)"))
    }

    private func connectedUniMail() throws -> UniMailConnection {
        let bed = try ContainerTestBed(name: "termin", clock: clock)
        self.bed = bed
        let answers: [String: (Data, Int)] = [
            "/Mail/0/compose": (try fx("created-compose.json"), 201), "/newDraft1730800002-2/edit": (try fx("edit-compose.json"), 200),
            "/Mail/0/view": (try fx("mailboxes.json"), 200), "/Mail/unseenCount": (try fx("unseen.json"), 200),
        ]
        UniStubProtocol.install { seen in
            let path = seen.url.absoluteString.components(separatedBy: "?")[0]
            if let (d, s) = answers.first(where: { path.hasSuffix($0.key) })?.value {
                return UniStubProtocol.Reply(status: s, headers: ["Content-Type": "application/json"], body: d)
            }
            return UniStubProtocol.Reply(status: 404, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: SOGoSite.all.map(\.host), configuration: UniStubProtocol.configuration())
        }
        let m = ContainerManager(base: bed.containers,
                                 legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                     studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                 keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                 publishesCurrent: false, uniMailTransport: stub)
        _ = try bed.open(m, bed.account(.luh))
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        let store = mail.websiteDataStore.httpCookieStore
        try awaiting {
            await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: "kalender.uni-hannover.de", path: "/SOGo"))
            await store.setCookie(bed.cookie("XSRF-TOKEN", "tok%2B1", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        }
        mail.signedIn(user: "erika.muster@stud.uni-hannover.de")
        return mail
    }

    // MARK: Bedienungshilfen

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func show<V: View>(_ view: V, api: APIClient, uniMail: UniMailConnection? = nil,
                               size: CGSize = CGSize(width: 1180, height: 1400)) throws -> UIWindow {
        let overlay = UFOverlay()
        let suite = "uniflow-termin-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let root = view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay))
            .environment(\.uniMail, uniMail)
            .environmentObject(Session(local: api, defaults: defaults))
            .environmentObject(UFRouter())
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(UFToastCenter())
            .environmentObject(StudIPSync())
            .environmentObject(AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: AuthorizedChecker(), observeRevocation: false))
        let frame = CGRect(origin: .zero, size: size)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        return window
    }

    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    private func elements(in window: UIWindow) -> [NSObject] {
        var roots: [UIView] = [window]
        var vc = window.rootViewController?.presentedViewController
        while let v = vc { if let view = v.view { roots.append(view) }; vc = v.presentedViewController }
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 45 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        for r in roots { r.layoutIfNeeded(); visit(r, depth: 0) }
        return out
    }

    private func texts(_ w: UIWindow) -> [String] {
        elements(in: w).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ w: UIWindow, _ text: String) -> Bool { texts(w).contains { $0.contains(text) } }

    private func tap(_ label: String, in w: UIWindow, exact: Bool = true) -> Bool {
        for e in elements(in: w) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Bedienelemente mindestens 44 pt hoch (Knoepfe des Termin-Details)
    private func buttonFrames(_ w: UIWindow, labels: [String]) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for e in elements(in: w) where e.accessibilityTraits.contains(.button) {
            if let l = e.accessibilityLabel, labels.contains(l) { out[l] = e.accessibilityFrame }
        }
        return out
    }

    private func dump(_ w: UIWindow) -> String { texts(w).joined(separator: "\n") }

    // MARK: Tests

    /// Termin antippen -> Detail mit Modul, Raum und beiden Dozent/innen; Tutor zugeklappt; nichts vor dem Antippen aufgeloest
    func testDetailShowsRoomAndBothLecturers() throws {
        let (_, api, id) = try device()
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "Dr. Max Muster") }, dump(w))
        for t in ["Zum Modul", "Raum", "Raum 1101 - F102, Route zu Fuß starten", "Raum 1101 - F102 im Raumfinder anzeigen", "Lehrende",
                  "Prof. Dr. Erika Beispiel", "E-Mail an erika.beispiel@example.org", "E-Mail an max.muster@example.org",
                  "Sprechstunde Di 10–11 Uhr", "Allen Lehrenden schreiben", "Tutor/innen (1)"] {
            XCTAssertTrue(shows(w, t), "\(t) fehlt: \(dump(w))")
        }
        XCTAssertFalse(shows(w, "Erfundener Tutor"), "Tutor/innen zugeklappt")
        let frames = buttonFrames(w, labels: ["Raum 1101 - F102, Route zu Fuß starten", "Allen Lehrenden schreiben"])
        XCTAssertEqual(frames.count, 2, dump(w))
        for (l, f) in frames { XCTAssertGreaterThanOrEqual(f.height, 44, "\(l) zu klein: \(f)") }
        XCTAssertTrue(tap("Tutor/innen (1)", in: w, exact: false))
        XCTAssertTrue(pump { self.shows(w, "Erfundener Tutor") }, dump(w))
        XCTAssertTrue(shows(w, "Nachricht über Stud.IP"), "Tutor ohne Adresse: Stud.IP")
    }

    /// Raum antippen -> aufgeloest im Raumfinder -> Google Maps mit Route zu Fuss (App oder Web), sofort
    func testTapRoomStartsWalkingRoute() throws {
        let (_, api, id) = try device(lecturers: false)
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "Raum 1101 - F102, Route zu Fuß starten") }, dump(w))
        XCTAssertTrue(tap("Raum 1101 - F102, Route zu Fuß starten", in: w))
        XCTAssertTrue(pump { !self.opened.isEmpty }, "keine Route geoeffnet: \(dump(w))")
        let url = try XCTUnwrap(opened.first).absoluteString
        XCTAssertTrue(url == "https://www.google.com/maps/dir/?api=1&destination=52.38255%2C9.71785&travelmode=walking"
                      || url == "comgooglemaps://?daddr=52.38255%2C9.71785&directionsmode=walking", url)
    }

    /// Raum, den der Raumfinder nicht kennt -> Raumfinder mit vorbelegter Suche statt einer Route
    func testUnknownRoomOpensPrefilledRoomFinder() throws {
        let (_, api, id) = try device(room: "Hörsaal Nirgendwo", lecturers: false)
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "Raum Hörsaal Nirgendwo, Route zu Fuß starten") }, dump(w))
        XCTAssertTrue(tap("Raum Hörsaal Nirgendwo, Route zu Fuß starten", in: w))
        // Blatt "Raumfinder" mit dem Text im Suchfeld und schon gesucht (Trefferzeile)
        XCTAssertTrue(pump { self.shows(w, "Raumfinder") && self.texts(w).contains("Hörsaal Nirgendwo") && self.shows(w, "Treffer") }, dump(w))
        XCTAssertTrue(opened.isEmpty, "keine Route ohne eindeutigen Ort: \(opened)")
    }

    /// E-Mail einer Dozentin antippen -> neue Uni-Mail an sie, Betreff "Frage zu <Kurs>"; gesendet wird nichts
    func testTapLecturerOpensComposeWithRecipient() throws {
        let (_, api, id) = try device()
        let mail = try connectedUniMail()
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api, uniMail: mail)
        XCTAssertTrue(pump { self.shows(w, "E-Mail an erika.beispiel@example.org") }, dump(w))
        XCTAssertTrue(tap("E-Mail an erika.beispiel@example.org", in: w))
        XCTAssertTrue(pump(timeout: 15) { self.texts(w).contains("erika.beispiel@example.org") && self.shows(w, "Neue E-Mail") }, dump(w))
        XCTAssertTrue(texts(w).contains("Frage zu Mathematik für Ingenieure I"), dump(w))
        XCTAssertFalse(texts(w).contains("erika.beispiel@example.org, max.muster@example.org"))
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.hasSuffix("/send") }, "nichts gesendet")
        XCTAssertTrue(opened.isEmpty, "kein mailto: mit Uni-Mail")
    }

    /// "Allen Lehrenden schreiben" -> beide Adressen in "An"
    func testWriteAllPutsBothAddresses() throws {
        let (_, api, id) = try device()
        let mail = try connectedUniMail()
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api, uniMail: mail)
        XCTAssertTrue(pump { self.shows(w, "Allen Lehrenden schreiben") }, dump(w))
        XCTAssertTrue(tap("Allen Lehrenden schreiben", in: w))
        XCTAssertTrue(pump(timeout: 15) { self.texts(w).contains("erika.beispiel@example.org, max.muster@example.org") }, dump(w))
        XCTAssertTrue(texts(w).contains("Frage zu Mathematik für Ingenieure I"), dump(w))
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.hasSuffix("/send") }, "nichts gesendet")
    }

    /// Ohne Uni-Mail (z. B. nicht angeboten): mailto: mit Empfaenger und Betreff
    func testWithoutUniMailFallsBackToMailto() throws {
        let (_, api, id) = try device()
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "E-Mail an max.muster@example.org") }, dump(w))
        XCTAssertTrue(tap("E-Mail an max.muster@example.org", in: w))
        XCTAssertTrue(pump { !self.opened.isEmpty }, dump(w))
        XCTAssertEqual(opened.first?.absoluteString, "mailto:max.muster@example.org?subject=Frage%20zu%20Mathematik%20f%C3%BCr%20Ingenieure%20I")
    }

    /// Kurs ohne geladene Lehrende: werden fuer diesen Kurs nachgeladen (Debug-Nachbildung) und erscheinen
    func testMissingLecturersAreLoadedForTheCourse() throws {
        let (host, api, id) = try device(course: "c-ma-ue", lecturers: false)
        var asked: [String] = []
        TerminLecturersSection.fetchOverride = { course in
            asked.append(course)
            let client = StudIPClient(base: StudIPSync.base, transport: DebugStubTransport(directory: ContainerTestBed.stubDirectory), pauseMillis: 0)
            _ = await StudIPExtrasSync(host: host).lecturers(client: client, courses: [StudIPCourse(id: course, title: "")])
        }
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump(timeout: 15) { self.shows(w, "Dr. Beispiel Dozentin") }, dump(w))
        XCTAssertEqual(asked, ["c-ma-ue"])
        XCTAssertTrue(shows(w, "Tutor/innen (1)"), dump(w))
        XCTAssertFalse(shows(w, "Allen Lehrenden schreiben"), "nur eine Dozentin")
    }

    /// Hochschule Hannover: Raum als Text mit "In Karten suchen" (Standort der Hochschule), keine Lehrenden
    func testHsHShowsRoomAsTextWithoutLecturers() throws {
        let (_, api, id) = try device(university: .hsh, room: "1H.1.01", lecturers: false)
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api)
        XCTAssertTrue(pump { self.shows(w, "Raum 1H.1.01 in Karten suchen") }, dump(w))
        XCTAssertFalse(shows(w, "Route zu Fuß starten"))
        XCTAssertFalse(shows(w, "Lehrende"), dump(w))
        XCTAssertTrue(tap("Raum 1H.1.01 in Karten suchen", in: w))
        XCTAssertTrue(pump { !self.opened.isEmpty }, dump(w))
        let url = try XCTUnwrap(opened.first).absoluteString
        XCTAssertTrue(url.hasPrefix("https://www.google.com/maps/search/") || url.hasPrefix("comgooglemaps://?q="), url)
        XCTAssertTrue(url.contains("Hochschule%20Hannover"), url)
    }

    /// Schmal (Split View 1/2, Drawer als Blatt) und dunkel: Detail baut sich auf, nichts ragt ueber den Rand
    func testNarrowAndDark() throws {
        let (_, api, id) = try device()
        let w = try show(EventDrawer(eventID: id, date: "2026-11-05"), api: api, size: CGSize(width: 375, height: 900))
        w.overrideUserInterfaceStyle = .dark
        XCTAssertTrue(pump { self.shows(w, "Dr. Max Muster") }, dump(w))
        for e in elements(in: w) {
            let f = e.accessibilityFrame
            guard f.width > 0, let l = e.accessibilityLabel, ["Allen Lehrenden schreiben", "Raum 1101 - F102, Route zu Fuß starten",
                                                              "E-Mail an erika.beispiel@example.org"].contains(l) else { continue }
            XCTAssertLessThanOrEqual(f.maxX, w.bounds.maxX + 0.5, "\(l) ragt rechts hinaus: \(f)")
            XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(l) ragt links hinaus: \(f)")
        }
    }
}

import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Abgleich im Hintergrund (S8) in der App: Aufgaben in der Info.plist, Termine 8/15/20 Uhr, Lauf mit gefaelschtem
/// und mit echtem Abgleich (feste Antworten), Ablauf mitten im Lauf, abgelaufene Sitzung ohne Anmeldeseite und ohne
/// gemerkte Zugangsdaten, Benachrichtigung ohne Dateinamen, Stand getrennt je Container, kein Lauf waehrend eines
/// Wechsels oder neben einem laufenden Abgleich, geloeschter Container bleibt leer. Kein Netz, kein BGTaskScheduler,
/// keine echte Benachrichtigung: Planer, Aufgabe und Mitteilungen sind Attrappen; erfundene Nutzer, Kurse, Dateien.
@MainActor
final class BackgroundSyncAppTests: XCTestCase {

    // MARK: Attrappen

    /// Planer statt BGTaskScheduler
    private final class FakeScheduler: BackgroundTaskScheduling {
        var pendingRequests: [BackgroundSyncKind: Date?] = [:]
        var submitted: [(BackgroundSyncKind, Date)] = []
        var cancelled: [BackgroundSyncKind] = []
        var rejects = false

        func pending() async -> [BackgroundSyncKind: Date?] { pendingRequests }

        func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {
            if rejects { throw NSError(domain: "BGTaskSchedulerErrorDomain", code: 1) }
            submitted.append((kind, earliest))
            pendingRequests[kind] = .some(earliest)
        }

        func cancel(_ kind: BackgroundSyncKind) {
            cancelled.append(kind)
            pendingRequests[kind] = nil
        }
    }

    /// Mitteilungen statt UNUserNotificationCenter
    private final class FakeNotifier: BackgroundNotifying {
        var allowed = true
        var grants = true
        private(set) var permissionRequests = 0
        private(set) var posts: [(content: BackgroundNotice.Content, id: String, thread: String)] = []

        func requestPermission() async -> Bool {
            permissionRequests += 1
            allowed = grants
            return grants
        }

        func isAllowed() async -> Bool { allowed }

        func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts.append((content, id, thread)) }
    }

    /// Aufgabe statt BGTask; der Abschluss kann von einem anderen Thread kommen
    private final class FakeTask: BackgroundTaskHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?
        private var done: [Bool] = []

        var expirationHandler: (() -> Void)? {
            get { lock.withLock { handler } }
            set { lock.withLock { handler = newValue } }
        }

        func setTaskCompleted(success: Bool) { lock.withLock { done.append(success) } }
        var completions: [Bool] { lock.withLock { done } }

        /// wie iOS: die Zeit ist um
        func expire() { expirationHandler?() }
    }

    /// Gefaelschter Abgleich: liefert einen festen Bericht oder wartet, bis er abgebrochen wird
    private final class FakeSync: BackgroundSyncable {
        var fileSource = "Stud.IP"
        var usableSources = ["Stud.IP"]
        var isRunning = false
        var report = BackgroundSyncReport()
        var waitsForCancel = false
        /// wartet, bis der Test `release` setzt (Lauf, der nach dem Loeschen des Containers endet)
        var holds = false
        var release = false
        private(set) var kinds: [BackgroundSyncKind] = []
        private(set) var sawCancel = false

        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
            kinds.append(kind)
            isRunning = true
            defer { isRunning = false }
            if waitsForCancel {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                sawCancel = true
                return BackgroundSyncReport(cancelled: true)
            }
            while holds && !release { try? await Task.sleep(nanoseconds: 5_000_000) }
            return report
        }
    }

    /// Echter Stud.IP-Abgleich des Containers mit einem Client des Tests (statt Cookie und URLSession)
    private final class ClientTarget: BackgroundSyncable {
        let sync: StudIPSync
        let client: StudIPClient
        init(_ sync: StudIPSync, _ client: StudIPClient) { self.sync = sync; self.client = client }
        var fileSource: String { sync.fileSource }
        var usableSources: [String] { sync.usableSources }
        var isRunning: Bool { sync.isRunning }
        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport { await sync.runInBackground(kind, client: client) }
    }

    /// Stud.IP mit festen, erfundenen Antworten (ein Kurs, zwei Dateien, eine davon gesperrt); merkt sich die Abrufe.
    /// `expired`: jede Anfrage endet mit 401 bzw. auf der Anmeldeseite; `gate`: Downloads warten auf die Freigabe.
    private final class ScriptedStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var expiredMode: ExpiredMode = .no
        let gate = StubGate()
        var gated = false

        enum ExpiredMode { case no, unauthorized, loginPage }

        var requested: [String] { lock.withLock { log } }
        var downloads: [String] { requested.filter { $0.hasSuffix("/content") } }
        func expire(_ m: ExpiredMode) { lock.withLock { expiredMode = m } }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let path = (url.path + (url.query.map { "?" + $0 } ?? ""))
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            let mode = lock.withLock { () -> ExpiredMode in
                log.append(path)
                return expiredMode
            }
            switch mode {
            case .unauthorized: return HTTPReply(status: 401, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            case .loginPage:
                // Weiterleitung auf die Anmeldeseite der Hochschule: erkannt, nie ausgefuellt
                return HTTPReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO"),
                                 body: Data("<html><form><input name=\"j_username\"><input type=\"password\" name=\"j_password\"></form></html>".utf8))
            case .no: break
            }
            let json: String
            switch path {
            case "/jsonapi.php/v1/users/me": json = #"{"data":{"id":"u1","type":"users"}}"#
            case "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester":
                json = #"""
                    {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
                     "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
                    """#
            case "/jsonapi.php/v1/courses/c1/folders?page[limit]=200": json = #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#
            case "/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500":
                json = #"""
                    {"data":[{"id":"d1","attributes":{"name":"Blatt 3 Geheimthema.pdf","filesize":17,"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}},
                             {"id":"d2","attributes":{"name":"Gesperrt.pdf","filesize":5,"mime-type":"application/pdf","chdate":"2026-10-19T11:00:00+02:00","is-downloadable":false}}]}
                    """#
            case "/jsonapi.php/v1/folders/r1/folders?page[limit]=200": json = #"{"data":[]}"#
            default: return HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            }
            return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
        }

        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            let path = url.path
            lock.withLock { log.append(path) }
            // die halbe Datei liegt schon im Zwischenordner, waehrend der Download noch laeuft
            try Data("%PDF-1.7 hal".utf8).write(to: file)
            if gated {
                let gate = self.gate
                await Task.detached { gate.pass() }.value
                try Task.checkCancellation()
            }
            try Data("%PDF-1.7 LUH ganz".utf8).write(to: file)
            return HTTPReply(status: 200, contentType: "application/pdf")
        }
    }

    /// Schluesselbund-Zugriffe mitschreiben (gemerkte Zugangsdaten duerfen im Hintergrund nie gelesen werden)
    private final class SpySecrets: UniversitySecretStoring {
        let inner: UniversityKeychain
        private(set) var reads: [String] = []
        init(_ inner: UniversityKeychain) { self.inner = inner }
        func read(_ account: String) -> String? { reads.append(account); return inner.read(account) }
        func write(_ value: String, account: String) -> Bool { inner.write(value, account: account) }
        func remove(_ account: String) { inner.remove(account) }
        func accounts() -> [String] { inner.accounts() }
        func removeAll() -> Bool { inner.removeAll() }
        func resetReads() { reads = [] }
        /// gelesene Benutzernamen oder Passwoerter (nicht: Schluessel des Learnweb, Schalter)
        var credentialReads: [String] { reads.filter { $0.hasSuffix(".user") || $0.hasSuffix(".password") } }
    }

    // MARK: Umgebung

    /// Montag, 26.10.2026, 10:00 in Berlin (WiSe 2026/27 -> learnweb2026)
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    private var bed: ContainerTestBed!
    private var spy: SpySecrets!
    private var websiteStores: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "hintergrund", clock: clock)
        spy = SpySecrets(bed.keychain)
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        AppActivity.isInBackground = { UIApplication.shared.applicationState == .background }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        await bed.tearDown()
        try await super.tearDown()
    }

    /// Container-Verwaltung wie in der App mit mitgeschriebenem Schluesselbund; Hildesheim ueber `UniStubProtocol`
    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: URLSessionUniTransport.hildesheimDomains + QISConnection.qisDomains,
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: spy, cookieService: bed.cookieService, defaults: bed.defaults, clock: clock, publishesCurrent: false,
                                hildesheimTransport: stub, qisTransport: stub)
    }

    /// Konto nach der Einrichtung (Anmeldeseiten der Hochschule durch) mit offenem Container
    private func ready(_ m: ContainerManager, _ uni: UniversityKey) throws -> (AccountStore, ActiveContainer) {
        let a = bed.account(uni)
        a.markLoginDone()
        let c = try bed.open(m, a)
        websiteStores.append(c.websiteDataStoreID)
        XCTAssertEqual(a.stage, .ready)
        return (a, c)
    }

    private func controller(_ m: ContainerManager, _ a: AccountStore, notify: Bool = true)
        -> (BackgroundSyncController, FakeScheduler, FakeNotifier) {
        let s = FakeScheduler(), n = FakeNotifier()
        let settings = BackgroundSyncSettings(defaults: bed.defaults)
        settings.notify = notify
        let b = BackgroundSyncController(containers: m, account: a, settings: settings, scheduler: s, notifier: n)
        b.allowed = { true }
        b.now = { Date(timeIntervalSince1970: 1_793_005_200) }   // 2026-10-26 (Montag) 10:00 Berlin
        b.timeZone = { TimeZone(identifier: "Europe/Berlin")! }
        b.graceNanos = 3_000_000_000
        return (b, s, n)
    }

    private func client(_ t: ScriptedStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    private func cookie(_ c: ActiveContainer) throws {
        try c.cookies.save([bed.cookie("Seminar_Session", "sitzung-erfunden", domain: "studip.uni-hannover.de")])
    }

    /// Lauf wie von iOS gestartet; wartet auf den Abschluss
    @discardableResult
    private func launch(_ b: BackgroundSyncController, _ kind: BackgroundSyncKind, task: FakeTask = FakeTask(),
                        file: StaticString = #filePath, line: UInt = #line) async throws -> FakeTask {
        b.handle(task, kind: kind)
        try await bed.waitUntil("Abschluss der Aufgabe", timeout: 15, file: file, line: line) { !task.completions.isEmpty }
        try await Task.sleep(nanoseconds: 30_000_000)            // nach dem Abschluss: neu planen, kein zweiter Abschluss
        return task
    }

    private func count(_ c: ActiveContainer, _ sql: String) async throws -> Int {
        try await c.host.backend().context.database.scalar(sql)?.int ?? -1
    }

    /// Eintraege der Einstellungs-Suite eines Containers (ohne die leere Kursauswahl, die jeder frische Container hat)
    private func suiteKeys(_ c: ActiveContainer, prefix: String) -> [String] {
        let s = ActiveContainer.defaultsSuite(c.layout.identifier)
        let domain = UserDefaults(suiteName: s)?.persistentDomain(forName: s) ?? [:]
        return domain.filter { k, v in k.hasPrefix(prefix) && !(k == "uniflow.studip.courses" && (v as? [String])?.isEmpty == true) }
            .keys.sorted()
    }

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func local(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = berlin
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: Info.plist

    func testInfoPlistAllowsBothTasksAndBackgroundModes() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], BackgroundTaskID.all)
        XCTAssertEqual(BackgroundTaskID.all, ["de.uniflow.ai.sync.refresh", "de.uniflow.ai.sync.files"])
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertEqual(Set(modes), ["fetch", "processing"], "nur Hintergrundaktualisierung und Verarbeitung, kein Audio, kein Push")
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "Datenschutz-Manifest im Bundle")
        XCTAssertNil((info["NSAppTransportSecurity"] as? [String: Any])?["NSAllowsArbitraryLoads"], "keine ATS-Ausnahme")
    }

    // MARK: Termine

    func testScheduleUsesTheNextSlotAndKeepsAnEarlierPendingRequest() async throws {
        let m = manager()
        let (a, _) = try ready(m, .luh)
        let (b, s, _) = controller(m, a)
        XCTAssertTrue(BackgroundSyncSettings(defaults: bed.defaults).enabled, "Vorgabe an")

        // 10:00 -> beide um 15:00
        let first = await b.schedule()
        XCTAssertEqual(first.mapValues(local), [.refresh: "2026-10-26 15:00", .processing: "2026-10-26 15:00"])
        XCTAssertEqual(b.nextPlanned.map(local), "2026-10-26 15:00")

        // 21:00: der kurze Lauf ist dran gewesen (verbraucht), der lange steht noch auf 15:00 und bleibt
        b.now = { Date(timeIntervalSince1970: 1_793_044_800) }    // 2026-10-26 21:00
        s.pendingRequests[.refresh] = nil
        s.submitted = []
        let second = await b.schedule(ran: .refresh)
        XCTAssertEqual(second.mapValues(local), [.refresh: "2026-10-27 08:00"], "nach 20 Uhr der naechste Morgen")
        XCTAssertEqual((s.pendingRequests[.processing] ?? nil).map(local), "2026-10-26 15:00", "langer Lauf nicht nach hinten geschoben")
        // die gerade gelaufene Aufgabe bestellt immer neu, auch wenn iOS sie noch fuehrt
        let third = await b.schedule(ran: .processing)
        XCTAssertEqual(third.mapValues(local), [.processing: "2026-10-27 08:00"])
        // ein spaeterer Termin (andere Zeitzone) wird ersetzt
        s.pendingRequests[.refresh] = .some(Date(timeIntervalSince1970: 1_793_200_000))
        let fourth = await b.schedule()
        XCTAssertEqual(fourth.mapValues(local), [.refresh: "2026-10-27 08:00"])

        // abgelehnt (Hintergrundaktualisierung aus, Simulator): kein Termin, kein Absturz
        s.rejects = true
        s.pendingRequests = [:]
        let rejected = await b.schedule()
        XCTAssertEqual(rejected.count, 0)
        XCTAssertNil(b.nextPlanned)
        s.rejects = false

        // ausgeschaltet: beide abbestellt, kein neuer Termin; wieder an: bestellt
        b.setEnabled(false)
        try await bed.waitUntil("abbestellt") { s.cancelled.count == 2 }
        XCTAssertEqual(Set(s.cancelled), [.refresh, .processing])
        XCTAssertFalse(BackgroundSyncSettings(defaults: bed.defaults).enabled)
        let off = await b.schedule()
        XCTAssertEqual(off.count, 0)
        b.setEnabled(true)
        try await bed.waitUntil("wieder bestellt") { s.pendingRequests.count == 2 }

        // nie unter XCTest von selbst (Vorgabe von `allowed`), nie mit Startargumenten fuer Bildvergleiche
        let quiet = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults),
                                             scheduler: s, notifier: FakeNotifier())
        s.submitted = []
        let none = await quiet.schedule()
        XCTAssertEqual(none.count, 0)
        XCTAssertTrue(s.submitted.isEmpty)
    }

    // MARK: Lauf mit gefaelschtem Abgleich

    func testRunWithFakeSyncNotifiesOnceWithoutFileNamesAndKeepsStatePerContainer() async throws {
        let m = manager()
        let (a, luh) = try ready(m, .luh)
        let (b, s, n) = controller(m, a)
        let fake = FakeSync()
        fake.report = BackgroundSyncReport(newFiles: 3)
        b.target = { _ in fake }

        let task = try await launch(b, .refresh)
        XCTAssertEqual(task.completions, [true], "genau ein Abschluss")
        XCTAssertNil(task.expirationHandler, "Aufgabe und Lauf halten sich nicht")
        XCTAssertEqual(fake.kinds, [.refresh])
        XCTAssertEqual(n.posts.count, 1)
        XCTAssertEqual(n.posts.first?.content, BackgroundNotice.Content(title: "Neue Dateien", body: "3 neue Dateien aus Stud.IP"))
        XCTAssertEqual(n.posts.first?.thread, "de.uniflow.ai.sync." + luh.layout.identifier.uuidString, "eigene Gruppe je Container")
        XCTAssertTrue(n.posts.allSatisfy { $0.id.hasPrefix("de.uniflow.ai.sync.files.") }, "eigene Kennungen, getrennt von anderen Mitteilungen")
        XCTAssertEqual(n.permissionRequests, 0, "nie von selbst nach der Erlaubnis fragen")
        XCTAssertTrue(s.submitted.contains { $0.0 == .refresh }, "nach dem Lauf neu geplant")
        let record = try XCTUnwrap(b.lastRecord)
        XCTAssertEqual(record.kind, .refresh)
        XCTAssertEqual(record.outcome, .done(newFiles: 3))
        XCTAssertEqual(BackgroundSyncCard.lastRunText(record, now: record.finishedAt), "Letzter Hintergrundlauf: 10:00 – Listen: 3 neue Dateien")
        XCTAssertGreaterThan(b.revision, 0)

        // ohne Schalter "Benachrichtigen" keine Mitteilung; ohne Erlaubnis von iOS ebenso
        BackgroundSyncSettings(defaults: bed.defaults).notify = false
        try await launch(b, .processing)
        XCTAssertEqual(n.posts.count, 1)
        XCTAssertEqual(b.lastRecord?.kind, .processing)
        BackgroundSyncSettings(defaults: bed.defaults).notify = true
        n.allowed = false
        try await launch(b, .refresh)
        XCTAssertEqual(n.posts.count, 1)
        n.allowed = true
        fake.report = BackgroundSyncReport(newFiles: 0)
        try await launch(b, .refresh)
        XCTAssertEqual(n.posts.count, 1, "ohne neue Dateien keine Mitteilung")
        XCTAssertEqual(b.lastRecord?.outcome, .done(newFiles: 0))

        // Trennung je Container: die Uni Hildesheim desselben Nutzers hat keinen Stand, die LUH behaelt ihren
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try XCTUnwrap(m.active)
        websiteStores.append(hi.websiteDataStoreID)
        XCTAssertNotEqual(hi.layout.identifier, luh.layout.identifier)
        XCTAssertNil(b.lastRecord, "Hildesheim sieht den Stand der LUH nicht")
        XCTAssertEqual(BackgroundSyncState(defaults: luh.defaults).last?.outcome, .done(newFiles: 0))
        XCTAssertEqual(suiteKeys(hi, prefix: "uniflow.background."), [])
    }

    // MARK: Ablauf mitten im Lauf

    func testExpirationMidRunCancelsAndCompletesOnce() async throws {
        let m = manager()
        let (a, _) = try ready(m, .luh)
        let (b, _, n) = controller(m, a)
        let fake = FakeSync()
        fake.waitsForCancel = true
        b.target = { _ in fake }
        let task = FakeTask()
        b.handle(task, kind: .refresh)
        try await bed.waitUntil("Lauf laeuft") { fake.isRunning }
        XCTAssertNotNil(task.expirationHandler)
        task.expire()
        try await bed.waitUntil("Abschluss") { !task.completions.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fake.sawCancel, "der Lauf wurde abgebrochen")
        XCTAssertEqual(task.completions, [false], "genau ein Abschluss, nicht erfolgreich")
        try await bed.waitUntil("Stand") { b.lastRecord?.outcome == .expired }
        XCTAssertTrue(n.posts.isEmpty)
    }

    /// Echter Stud.IP-Abgleich (langer Lauf mit Downloads): die Zeit laeuft ab, waehrend die Datei laedt. Keine halbe
    /// Datei ist sichtbar (nicht unter StudIP/files, kein Ablageort in der Datenbank), der Zwischenordner ist leer, die
    /// Dateiliste bleibt; der naechste Lauf laedt die Datei ganz.
    func testExpirationDuringARealDownloadLeavesNoHalfFile() async throws {
        let m = manager()
        let (a, luh) = try ready(m, .luh)
        try cookie(luh)
        let (b, _, _) = controller(m, a)
        let stud = ScriptedStudIP()
        stud.gated = true
        b.target = { [unowned m] _ in ClientTarget(m.studip, self.client(stud)) }
        let task = FakeTask()
        b.handle(task, kind: .processing)
        try await bed.waitUntil("Download laeuft") { stud.gate.wasReached }
        task.expire()
        stud.gate.release()
        try await bed.waitUntil("Abschluss") { !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [false])
        try await bed.waitUntil("Lauf beendet") { !m.studip.isRunning }
        try await bed.waitUntil("Stand") { b.lastRecord?.outcome == .expired }
        let files = luh.layout.studip.appendingPathComponent("files")
        XCTAssertEqual((try? FileManager.default.subpathsOfDirectory(atPath: files.path)) ?? [], [], "keine halbe Datei sichtbar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: UniDownloads.partial(in: luh.layout.studip).path), "Zwischenordner leer")
        let listed = try await count(luh, "SELECT COUNT(*) FROM files WHERE course_id='c1'")
        XCTAssertEqual(listed, 2, "Dateiliste bleibt")
        let stored = try await count(luh, "SELECT COUNT(*) FROM files WHERE course_id='c1' AND local_path IS NOT NULL")
        XCTAssertEqual(stored, 0)
        XCTAssertNotEqual(m.studip.phase, .needsLogin)

        // naechster Lauf ohne Ablauf: die ganze Datei
        stud.gated = false
        let again = try await launch(b, .processing)
        XCTAssertEqual(again.completions, [true])
        let path = try await luh.host.backend().context.database.scalar("SELECT local_path FROM files WHERE id='d1'")?.string
        let url = luh.layout.root.appendingPathComponent(try XCTUnwrap(path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "%PDF-1.7 LUH ganz")
    }

    // MARK: Kurzer und langer Lauf mit echtem Abgleich

    func testListsRunThenDownloadRunAndOpeningComesRightAway() async throws {
        let m = manager()
        let (a, luh) = try ready(m, .luh)
        try cookie(luh)
        let (b, _, n) = controller(m, a)
        let stud = ScriptedStudIP()
        b.target = { [unowned m] _ in ClientTarget(m.studip, self.client(stud)) }

        // kurzer Lauf: Listen in die Datenbank, kein Download, keine Aufzeichnungen
        try await launch(b, .refresh)
        XCTAssertEqual(stud.downloads, [], "kein Download im kurzen Lauf")
        XCTAssertFalse(stud.requested.contains { $0.contains("media") || $0.contains("opencast") }, "\(stud.requested)")
        let listed = try await count(luh, "SELECT COUNT(*) FROM files WHERE course_id='c1' AND local_path IS NULL")
        XCTAssertEqual(listed, 2)
        XCTAssertEqual(n.posts.map(\.content.body), ["2 neue Dateien aus Stud.IP"])
        XCTAssertFalse(n.posts.contains { $0.content.title.contains("Geheimthema") || $0.content.body.contains("Geheimthema") }, "nie Dateinamen")
        XCTAssertTrue(m.studip.downloadsPending)
        XCTAssertNil(m.studip.lastRun, "der kurze Lauf setzt die 30-Minuten-Sperre nicht")
        XCTAssertEqual(b.lastRecord?.outcome, .done(newFiles: 2))
        let log = try await luh.host.backend().context.database.scalar("SELECT message FROM sync_log ORDER BY id DESC LIMIT 1")?.string
        XCTAssertEqual(log, "Hintergrund: Listen abgeglichen, 1 Datei wartet auf den Download")

        // langer Lauf: laedt die wartende Datei; nichts mehr neu, keine zweite Mitteilung
        try await launch(b, .processing)
        XCTAssertEqual(stud.downloads, ["/jsonapi.php/v1/file-refs/d1/content"])
        XCTAssertFalse(m.studip.downloadsPending)
        XCTAssertNotNil(m.studip.lastRun)
        XCTAssertEqual(n.posts.count, 1, "jede neue Datei wird nur einmal gemeldet")
        XCTAssertEqual(b.lastRecord?.outcome, .done(newFiles: 0))
        XCTAssertEqual(b.lastRecord?.text, "Listen und Dateien: nichts Neues")
    }

    // MARK: Abgelaufene Sitzung

    func testExpiredStudIPSessionNotifiesOnceWithoutLoginPageOrCredentials() async throws {
        for mode in [ScriptedStudIP.ExpiredMode.unauthorized, .loginPage] {
            let m = manager()
            let (a, luh) = try ready(m, .luh)
            try cookie(luh)
            // Zugangsdaten merkt sich die App nicht mehr (nur iOS); der Hintergrund liest auch keinen Schluessel
            spy.resetReads()
            let (b, _, n) = controller(m, a)
            let stud = ScriptedStudIP()
            stud.expire(mode)
            b.target = { [unowned m] _ in ClientTarget(m.studip, self.client(stud)) }

            let task = try await launch(b, .refresh)
            XCTAssertEqual(task.completions, [true], "\(mode)")
            XCTAssertEqual(stud.requested, ["/jsonapi.php/v1/users/me"], "nach der ersten Antwort Schluss: \(mode)")
            XCTAssertEqual(m.studip.phase, .needsLogin)
            XCTAssertTrue(m.studip.sessionKnownExpired)
            XCTAssertEqual(n.posts.map(\.content.title), ["Bitte bei Stud.IP anmelden"], "\(mode)")
            XCTAssertEqual(n.posts.first?.id, "de.uniflow.ai.sync.login." + luh.layout.identifier.uuidString, "ersetzt nur den eigenen Hinweis")
            XCTAssertEqual(b.lastRecord?.outcome, .loginNeeded(["Stud.IP"]))
            XCTAssertEqual(spy.credentialReads, [], "keine gemerkten Zugangsdaten gelesen: \(mode)")

            // naechster Lauf: keine Anfrage mit der toten Sitzung, keine zweite Mitteilung (auch nach einem Neustart:
            // der Merker steht im Container)
            try await launch(b, .refresh)
            try await launch(b, .processing)
            XCTAssertEqual(stud.requested.count, 1, "\(mode)")
            XCTAssertEqual(n.posts.count, 1, "einmal, nicht bei jedem Lauf")
            XCTAssertEqual(b.lastRecord?.outcome, .skipped(.noSession))
            let reopened = StudIPSync(root: luh.layout.studip, host: luh.host, clock: clock, defaults: luh.defaults, support: luh.layout.root,
                                      cookies: luh.cookies, container: luh.layout)
            XCTAssertTrue(reopened.sessionKnownExpired, "auch nach einem Neustart bekannt")
            XCTAssertEqual(reopened.usableSources, [])

            // neu angemeldet: der Abgleich laeuft wieder; laeuft die Sitzung spaeter erneut ab, kommt wieder einmal der Hinweis
            m.studip.signedIn(cookies: [bed.cookie("Seminar_Session", "neue-sitzung", domain: "studip.uni-hannover.de")])
            XCTAssertFalse(m.studip.sessionKnownExpired)
            stud.expire(.no)
            try await launch(b, .refresh)
            XCTAssertEqual(b.lastRecord?.outcome, .done(newFiles: 2))
            XCTAssertEqual(n.posts.count, 2)
            stud.expire(mode)
            try await launch(b, .refresh)
            XCTAssertEqual(n.posts.map(\.content.title).filter { $0 == "Bitte bei Stud.IP anmelden" }.count, 2, "neuer Ablauf, neuer Hinweis")
            XCTAssertEqual(spy.credentialReads, [])
            // naechste Runde mit leerem Container
            await m.deleteUniversityData(luh.key)
        }
    }

    /// Uni Hildesheim: iPad gesperrt (Learnweb-Schluessel nur entsperrt lesbar) und LSF-Sitzung abgelaufen. Learnweb
    /// bleibt aussen vor und gilt nicht als abgemeldet; LSF meldet einmal "Bitte beim LSF anmelden", ohne die
    /// CAS-Seite auszufuellen und ohne gemerkte Zugangsdaten. Entsperrt: nur die Learnweb-Listen, danach die Dateien.
    func testHildesheimLockedDeviceAndExpiredLSFSession() async throws {
        let base = "https://www.uni-hildesheim.de/learnweb2026", token = "TestSchluessel0123456789abcdef"
        let contents = try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        let ics = try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics"))
        UniStubProtocol.install(HildesheimAppTests.uniHildesheim(base: base, lsf: "https://lsf.uni-hildesheim.de", token: token, ics: ics, contents: contents))
        let m = manager()
        let (a, hi) = try ready(m, .hildesheim)
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        h.lsfSignedIn()                                          // ohne LSF-Sitzung in der Webansicht: abgelaufen
        spy.resetReads()
        var locked = true
        h.protectedDataAvailable = { !locked }
        let (b, _, n) = controller(m, a)
        XCTAssertEqual(h.usableSources, ["LSF", "Learnweb"])

        // gesperrt: kein Learnweb (keine Anfrage, kein Schluessel gelesen), LSF laeuft ab
        try await launch(b, .refresh)
        let seen = UniStubProtocol.requests
        XCTAssertFalse(seen.contains { $0.url.path.hasPrefix("/learnweb") }, "\(seen.map(\.url))")
        XCTAssertTrue(seen.contains { $0.url.host == "lsf.uni-hildesheim.de" })
        XCTAssertTrue(seen.filter { $0.url.path.hasPrefix("/sso") }.allSatisfy { $0.method == "GET" && $0.body.isEmpty }, "CAS nie ausgefuellt")
        XCTAssertFalse(seen.contains { $0.bodyText.contains("Erfunden-CAS-456") || $0.bodyText.contains("erfunden-hilde") })
        XCTAssertEqual(spy.reads, [], "weder Schluessel noch Zugangsdaten gelesen: \(spy.reads)")
        XCTAssertEqual(h.state(.lsf), .needsLogin)
        XCTAssertEqual(h.state(.learnweb), .connected, "gesperrt heisst nicht abgemeldet")
        XCTAssertEqual(n.posts.map(\.content.title), ["Bitte beim LSF anmelden"])
        XCTAssertEqual(b.lastRecord?.outcome, .loginNeeded(["LSF"]))
        XCTAssertEqual(h.usableSources, ["Learnweb"])

        // weiter gesperrt: nur noch Learnweb waere dran -> gar kein Lauf
        let before = UniStubProtocol.requests.count
        try await launch(b, .refresh)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        XCTAssertEqual(b.lastRecord?.outcome, .skipped(.deviceLocked))
        XCTAssertEqual(n.posts.count, 1)

        // entsperrt: Learnweb-Listen ohne Download, LSF nicht erneut; dann der lange Lauf mit den Dateien
        locked = false
        try await launch(b, .refresh)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.contains("/webservice/pluginfile.php/") }, "kein Download im kurzen Lauf")
        XCTAssertEqual(UniStubProtocol.requests.dropFirst(before).filter { $0.url.host == "lsf.uni-hildesheim.de" }.count, 0, "LSF mit toter Sitzung nicht erneut")
        XCTAssertEqual(n.posts.map(\.content.body).last, "2 neue Dateien aus Learnweb")
        XCTAssertEqual(n.posts.count, 2)
        XCTAssertTrue(h.downloadsPending)
        XCTAssertEqual(spy.credentialReads, [], "nur der Learnweb-Schluessel, nie Benutzername oder Passwort")
        XCTAssertTrue(spy.reads.allSatisfy { $0.hasSuffix(".learnweb.token") }, "\(spy.reads)")
        // beim Oeffnen (voller Lauf mit allen verbundenen Quellen): die wartenden Dateien kommen, auch wenn das LSF
        // weiter eine Anmeldung braucht
        _ = await h.run()
        let loaded = try await count(hi, "SELECT COUNT(*) FROM files WHERE course_id LIKE 'lw-%' AND local_path IS NOT NULL")
        XCTAssertEqual(loaded, 2)
        XCTAssertFalse(h.downloadsPending, "nichts wartet mehr, obwohl das LSF abgemeldet ist")
        XCTAssertEqual(h.state(.lsf), .needsLogin)
        // langer Hintergrundlauf danach: nichts Neues, keine Mitteilung, das LSF wird nicht gefragt
        let lsfBefore = UniStubProtocol.requests.filter { $0.url.host == "lsf.uni-hildesheim.de" }.count
        try await launch(b, .processing)
        XCTAssertEqual(b.lastRecord?.outcome, .done(newFiles: 0))
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.url.host == "lsf.uni-hildesheim.de" }.count, lsfBefore)
        XCTAssertEqual(n.posts.count, 2, "keine weitere Mitteilung")
        XCTAssertEqual(spy.credentialReads, [])
    }

    // MARK: Kein Lauf waehrend eines Wechsels oder neben einem Abgleich

    func testNoRunDuringSwitchSetupOrAnotherSyncOrWhenOff() async throws {
        let m = manager()
        let (a, luh) = try ready(m, .luh)
        let (b, _, n) = controller(m, a)
        let fake = FakeSync()
        fake.report = BackgroundSyncReport(newFiles: 5)
        b.target = { _ in fake }

        // ausgeschaltet
        BackgroundSyncSettings(defaults: bed.defaults).enabled = false
        try await launch(b, .refresh)
        XCTAssertEqual(b.lastRecord?.outcome, .skipped(.disabled))
        BackgroundSyncSettings(defaults: bed.defaults).enabled = true

        // ein Abgleich laeuft schon auf diesem Container (Sperre des Abgleichs)
        fake.isRunning = true
        try await launch(b, .refresh)
        XCTAssertEqual(b.lastRecord?.outcome, .skipped(.alreadyRunning))
        fake.isRunning = false

        // echter laufender Stud.IP-Abgleich desselben Containers (ContainerManager.isSyncing)
        try cookie(luh)
        let stud = ScriptedStudIP()
        stud.gated = true
        let sync = m.studip
        let foreground = Task { await sync.run(client: self.client(stud)) }
        try await bed.waitUntil("Abgleich laeuft") { stud.gate.wasReached }
        XCTAssertTrue(m.isSyncing(luh.key))
        try await launch(b, .refresh)
        XCTAssertEqual(b.lastRecord?.outcome, .skipped(.alreadyRunning))
        stud.gate.release()
        _ = await foreground.value

        // Wechsel der Hochschule begonnen, Container noch der alte: kein Lauf, nichts geschrieben
        let recordBefore = b.lastRecord
        a.chooseUniversity(.hildesheim)
        try await launch(b, .refresh)
        XCTAssertEqual(b.lastRecord, recordBefore)
        // Einrichtung noch nicht fertig (Anmeldeseiten der neuen Hochschule)
        m.sync(account: a)
        websiteStores.append(try XCTUnwrap(m.active).websiteDataStoreID)
        XCTAssertEqual(a.stage, .universityLogin)
        try await launch(b, .refresh)
        XCTAssertNil(b.lastRecord, "im neuen Container nichts")
        // ohne Konto
        a.signOut()
        m.sync(account: a)
        try await launch(b, .refresh)
        XCTAssertEqual(fake.kinds, [], "der Abgleich lief kein einziges Mal")
        XCTAssertTrue(n.posts.isEmpty)
    }

    // MARK: Geloeschter Container

    /// Daten der Hochschule loeschen waehrend eines Hintergrundlaufs: der Lauf wird angehalten, danach steht im
    /// neuen, leeren Container weder ein Stand noch eine Datei
    func testDeletingTheContainerDuringABackgroundRunLeavesNothing() async throws {
        let m = manager()
        let (a, luh) = try ready(m, .luh)
        try cookie(luh)
        let (b, _, n) = controller(m, a)
        let stud = ScriptedStudIP()
        stud.gated = true
        b.target = { [unowned m] _ in ClientTarget(m.studip, self.client(stud)) }
        let task = FakeTask()
        b.handle(task, kind: .processing)
        try await bed.waitUntil("Download laeuft") { stud.gate.wasReached }
        let deletion = Task { await m.deleteUniversityData(luh.key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        stud.gate.release()
        await deletion.value
        try await bed.waitUntil("Abschluss") { !task.completions.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(task.completions.count, 1)
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.key, luh.key)
        XCTAssertEqual(suiteKeys(fresh, prefix: "uniflow."), [], "kein Stand des alten Laufs im neuen Container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.layout.studip.appendingPathComponent("files").path))
        let files = try await count(fresh, "SELECT COUNT(*) FROM files WHERE course_id='c1'")
        XCTAssertEqual(files, 0)
        XCTAssertTrue(n.posts.isEmpty)

        // ein Abgleich, den das Loeschen nicht anhalten kann, endet erst, nachdem der Container leer neu geoeffnet ist:
        // sein Ergebnis gehoert dem alten Container und landet weder im neuen noch in einer Mitteilung
        let fake = FakeSync()
        fake.holds = true
        fake.report = BackgroundSyncReport(newFiles: 4, loginNeeded: ["Stud.IP"])
        b.target = { _ in fake }
        let late = FakeTask()
        b.handle(late, kind: .refresh)
        try await bed.waitUntil("Lauf laeuft") { fake.isRunning }
        await m.deleteUniversityData(fresh.key)
        let renewed = try XCTUnwrap(m.active)
        XCTAssertFalse(renewed === fresh)
        fake.release = true
        try await bed.waitUntil("Abschluss") { !late.completions.isEmpty }
        XCTAssertEqual(late.completions, [false])
        XCTAssertEqual(suiteKeys(renewed, prefix: "uniflow."), [], "kein Stand und kein Hinweis-Merker im neuen Container")
        XCTAssertTrue(n.posts.isEmpty, "keine Mitteilung zu einem geloeschten Container")
    }

    // MARK: Einstellungen

    func testNotificationPermissionIsAskedOnlyByTheSwitch() async throws {
        let m = manager()
        let (a, _) = try ready(m, .luh)
        let (b, _, n) = controller(m, a, notify: false)
        XCTAssertFalse(BackgroundSyncSettings(defaults: bed.defaults).notify, "Vorgabe aus")
        await b.schedule()
        let fake = FakeSync()
        fake.report = BackgroundSyncReport(newFiles: 1)
        b.target = { _ in fake }
        try await launch(b, .refresh)
        XCTAssertEqual(n.permissionRequests, 0, "Start und Hintergrundlauf fragen nie")
        XCTAssertTrue(n.posts.isEmpty)

        n.grants = false
        let denied = await b.setNotify(true)
        XCTAssertFalse(denied)
        XCTAssertFalse(b.settings.notify, "abgelehnt: bleibt aus")
        XCTAssertEqual(n.permissionRequests, 1)
        n.grants = true
        let granted = await b.setNotify(true)
        XCTAssertTrue(granted)
        XCTAssertTrue(b.settings.notify)
        let off = await b.setNotify(false)
        XCTAssertTrue(off)
        XCTAssertFalse(b.settings.notify)
        XCTAssertEqual(n.permissionRequests, 2, "Ausschalten fragt nicht")
    }

    func testCardTextsAreHonestAndTheCardRenders() async throws {
        XCTAssertTrue(BackgroundSyncCard.timingText.hasPrefix("iOS entscheidet, wann genau; frühestens 8, 15 und 20 Uhr."))
        XCTAssertTrue(BackgroundSyncCard.notifyText(.luh).contains("„Bitte bei Stud.IP anmelden“"))
        XCTAssertTrue(BackgroundSyncCard.notifyText(.hildesheim).contains("„3 neue Dateien aus Learnweb“"))
        XCTAssertTrue(BackgroundSyncCard.notifyText(.luh).contains("nie Dateinamen"))
        XCTAssertEqual(BackgroundSyncCard.lastRunText(nil, now: Date()), "Letzter Hintergrundlauf: noch keiner")
        let r = BackgroundSyncRecord(finishedAt: Date(timeIntervalSince1970: 1_793_005_200), kind: .refresh, outcome: .loginNeeded(["Stud.IP"]))
        XCTAssertEqual(BackgroundSyncCard.lastRunText(r, now: Date(timeIntervalSince1970: 1_793_200_000)),
                       "Letzter Hintergrundlauf: 26.10. 10:00 – Anmeldung nötig (Stud.IP)")

        // Karte im Fenster: ohne Hintergrundabgleich in der Umgebung nichts, mit ihm die Karte (kein Absturz)
        let m = manager()
        let (a, _) = try ready(m, .luh)
        let (b, _, _) = controller(m, a)
        b.refreshStatus = { .available }
        for env: BackgroundSyncController? in [nil, b] {
            let hosting = UIHostingController(rootView: BackgroundSyncCard().environment(\.backgroundSync, env).frame(width: 420))
            hosting.view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
            hosting.view.layoutIfNeeded()
            let size = hosting.sizeThatFits(in: CGSize(width: 420, height: 2000))
            if env == nil { XCTAssertLessThan(size.height, 5) } else { XCTAssertGreaterThan(size.height, 150) }
        }
    }
}

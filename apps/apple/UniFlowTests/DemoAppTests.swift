import PDFKit
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Demo-Inhalte fuer die App-Pruefung in der App: Karte unter Einstellungen -> Erweitert (auch im Release-Build), Weg
/// "Ohne Hochschulkonto ansehen (Demo)" aus dem ersten Start, Hinweis "Demo-Inhalte aktiv" mit "Entfernen" auf der
/// Uebersicht, keine Karten "… verbinden", kein Abgleich und keine Anfrage an die Hochschule im Demo-Betrieb, Entfernen
/// samt Kopien auf dem Geraet, Demo je Container. Erfundene Nutzer, Temp-Ordner, kein Netz (UniStubProtocol zaehlt mit).
@MainActor
final class DemoAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    /// Mittwoch, 28.10.2026, 9:30 in Berlin (Lernpaket "Übungsblatt 1" ist heute)
    private let clock = UniFlowClock.fixed(berlin: "2026-10-28T09:30:00")!

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "demo", clock: clock)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }        // jede Anfrage zaehlt
    }

    override func tearDown() async throws {
        await bed.tearDown()
        try await super.tearDown()
    }

    /// Stud.IP-Transport des Tests: merkt sich jede Anfrage, antwortet 404
    private final class RecordingStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URL] = []
        var requests: [URL] { lock.withLock { log } }
        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            lock.withLock { log.append(url) }
            return HTTPReply(status: 404, contentType: "application/json", body: Data("{}".utf8))
        }
    }

    private func client(_ t: RecordingStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    // MARK: Einstellungen -> Erweitert, Texte

    func testErweitertWithDemoCardIsThereInReleaseBuilds() {
        let release = SettingsNav.localKeys(withPlan: true, ownServer: false)
        XCTAssertTrue(release.contains("advanced"), "Prüfer von Apple finden die Demo auch ohne Entwicklungsmodus")
        XCTAssertFalse(release.contains("dev"), "Entwicklung bleibt im Release-Build verborgen")
        XCTAssertTrue(SettingsNav.localKeys(withPlan: false, ownServer: false).contains("advanced"), "auch bevor die Einstellungen geladen sind")
        XCTAssertEqual(SettingsNav.items.first { $0.0 == "advanced" }?.1, "Erweitert")
        // kurzer, ehrlicher Text
        XCTAssertTrue(DemoTexts.cardText.hasPrefix("Nur zum Ausprobieren ohne Hochschulkonto"))
        XCTAssertTrue(DemoTexts.cardText.contains("rückstandslos"))
        XCTAssertTrue(DemoTexts.cardText.contains("keine Inhalte einer Hochschule"))
        XCTAssertTrue(DemoTexts.offlineNote.contains("braucht keine Anmeldung"))
        XCTAssertEqual(DemoTexts.cardTitle, "Demo-Inhalte für die App-Prüfung")
        XCTAssertEqual(DemoTexts.firstStart, "Ohne Hochschulkonto ansehen (Demo)")
        XCTAssertEqual(DemoTexts.summary(["files": 3, "events": 3, "packages": 3]), "3 PDFs · 3 Termine · 3 Lernpakete")
        XCTAssertEqual(DemoTexts.summary(["files": 1, "events": 1, "packages": 1]), "1 PDF · 1 Termin · 1 Lernpaket")
        XCTAssertTrue(DemoTexts.syncBlocked.contains("Einstellungen → Erweitert"), "Sync im Demo-Betrieb: Weg zum Entfernen")
    }

    /// Weiche der Seiten: mit Demo keine Karte zum Verbinden, keine Statusleiste, die Seiten selbst
    func testPagesShowNoConnectCardWhileDemoIsActive() {
        let demo = UFDataMode.local(.demo)
        XCTAssertFalse(demo.showsConnectCard)
        XCTAssertTrue(demo.isDemo)
        XCTAssertFalse(demo.hasOtherSources, "auch an der Uni Hildesheim keine Karten Learnweb/LSF")
        XCTAssertTrue(demo.isOnDevice)
        XCTAssertFalse(UFDataMode.local(.notConnected).isDemo)
        for spec in [UFNoServerPage.Spec.plan, .timetable, .modules, .library, .document, .cards] {
            XCTAssertEqual(UFGatePresentation.resolve(spec: spec, mode: demo, phase: .failed("offline")), .page, spec.title)
        }
        XCTAssertEqual(UFGatePresentation.resolve(spec: .exams, mode: demo, phase: .signedOut), .empty, "Wochentests gibt es weiter nicht")
        XCTAssertNil(UFNoServerContent.resolve(kind: .dashboard, mode: demo, phase: .running("x")).status)
        XCTAssertFalse(UFNoServerContent.resolve(kind: .dashboard, mode: demo, phase: .signedOut).showsConnectCard)
        // eigener Server (Entwicklung): die Weiche bleibt beim Server
        XCTAssertEqual(UFDataMode.current(api: APIClient(base: URL(string: "http://192.0.2.1:8765/")!, pin: nil), studip: StudIPSync(), demo: true), .server)
    }

    // MARK: Erster Start ohne Hochschulkonto

    func testFirstStartWithoutAccountOpensTheDemoWithoutAnyUniversityRequest() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        XCTAssertEqual(a.stage, .universityLogin, "nach der Hochschulwahl die Anmeldeseiten")
        let c = try bed.open(m, a)
        XCTAssertTrue(FirstLoginFlow.offersDemo(studip: m.studip, qis: m.qis, hildesheim: nil), "nichts verbunden: Weg ohne Konto da")
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive), .local(.notConnected))

        try await FirstLoginFlow.startDemo(containers: m, account: a)
        XCTAssertEqual(a.stage, .ready, "gleich die Oberflaeche, keine Anmeldeseite mehr")
        XCTAssertTrue(m.demoActive)
        let mode = UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive)
        XCTAssertEqual(mode, .local(.demo))
        XCTAssertFalse(mode.showsConnectCard, "statt Stud.IP verbinden der Hinweis Demo-Inhalte aktiv")
        // Inhalte wie am PC im Container dieses Nutzers und dieser Hochschule
        let s = try await c.api.value("/api/demo")
        XCTAssertEqual([s["enabled"], s["files"], s["events"], s["packages"]], [true, 3, 3, 3])
        let dash = try await c.api.value("/api/dashboard")
        XCTAssertEqual(dash["today"]?["packages"]?.array?.first?["title"], "Übungsblatt 1")
        let lib = try await c.api.value("/api/library")
        XCTAssertEqual(Set((lib["files"]?.array ?? []).compactMap { $0["id"]?.string }), Set(DemoContent.fileIDs))
        let pdf = try await c.api.data("/api/files/demo-blatt/content")
        XCTAssertEqual(pdf.1.statusCode, 200)
        XCTAssertNotNil(PDFKitCheck.pageCount(pdf.0), "PDFKit liest die Demo-PDF")
        XCTAssertEqual(PDFKitCheck.pageCount(pdf.0), 2)
        XCTAssertTrue(PDFKitCheck.text(pdf.0).contains("Aufgabe 1"), PDFKitCheck.text(pdf.0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.layout.root.path), "Container des Nutzers und der LUH")
        XCTAssertEqual(c.key.university, .luh)
        // nichts ging an eine Hochschule
        XCTAssertEqual(UniStubProtocol.requests.map(\.url), [])
        XCTAssertFalse(m.studip.hasStoredSession)
        XCTAssertFalse(FirstLoginFlow.anyConnected(studip: m.studip, qis: m.qis, hildesheim: nil))
    }

    /// Hildesheim: derselbe Weg, die Demo statt der Karten Learnweb/LSF
    func testFirstStartDemoAtHildesheim() async throws {
        let m = bed.manager()
        let a = bed.account(.hildesheim)
        let c = try bed.open(m, a)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive), .local(.otherSources))
        try await FirstLoginFlow.startDemo(containers: m, account: a)
        XCTAssertEqual(a.stage, .ready)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive), .local(.demo))
        let week = try await c.api.value("/api/timetable/week?start=2026-10-26")
        XCTAssertTrue(week.jsonString().contains("Grundlagen der Informatik – Übung"))
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    /// Wer sich schon angemeldet hat, bekommt keinen Demo-Knopf mehr
    func testNoDemoOfferAfterALogin() throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        _ = try bed.open(m, a)
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        qis.signedIn()
        XCTAssertFalse(FirstLoginFlow.offersDemo(studip: m.studip, qis: m.qis, hildesheim: nil))
    }

    // MARK: Kein Abgleich und keine Anfrage im Demo-Betrieb

    func testNoUniversityRequestWhileDemoIsActiveLUH() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        _ = try bed.open(m, a)
        a.markLoginDone()
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        qis.signedIn()
        try await m.setDemo(true)
        let studip = RecordingStudIP()
        // Stud.IP: kein Lauf, keine Anfrage (auch im Hintergrund nicht, mit gespeicherter Sitzung)
        try m.active?.cookies.save([bed.cookie("Seminar_Session", "erfunden", domain: StudIPSync.base.host!)])
        let end = await m.studip.run(client: client(studip))
        XCTAssertNil(end, "Demo: der Abgleich beginnt nicht")
        let bg = await m.studip.runInBackground(.processing, client: client(studip))
        XCTAssertEqual(bg.skipped, .demo)
        XCTAssertEqual(studip.requests, [])
        // QIS: kein Abruf
        let report = await qis.run(force: true)
        XCTAssertNil(report)
        XCTAssertEqual(UniStubProtocol.requests.map(\.url), [])
        // Gegenprobe: nach dem Entfernen fragen beide wieder bei der Hochschule
        try await m.setDemo(false)
        XCTAssertFalse(m.demoActive)
        _ = await m.studip.run(client: client(studip))
        XCTAssertGreaterThan(studip.requests.count, 0, "ohne Demo gleicht Stud.IP wieder ab")
        _ = await qis.run(force: true)
        XCTAssertGreaterThan(UniStubProtocol.requests.count, 0, "ohne Demo fragt QIS wieder")
    }

    func testNoUniversityRequestWhileDemoIsActiveHildesheim() async throws {
        let m = bed.manager()
        let a = bed.account(.hildesheim)
        _ = try bed.open(m, a)
        a.markLoginDone()
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        h.lsfSignedIn()
        try await m.setDemo(true)
        let report = await h.run(forceGrades: true)
        XCTAssertNil(report, "Demo: kein Lauf")
        let bg = await h.runInBackground(.processing)
        XCTAssertEqual(bg.skipped, .demo)
        XCTAssertEqual(UniStubProtocol.requests.map(\.url), [])
        try await m.setDemo(false)
        _ = await h.run(forceGrades: true)
        XCTAssertGreaterThan(UniStubProtocol.requests.count, 0, "ohne Demo fragt das LSF wieder")
    }

    /// Hintergrundabgleich: mit Demo uebersprungen und so im Stand vermerkt, ohne Anfrage und ohne Mitteilung
    func testBackgroundRunIsSkippedWhileDemoIsActive() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        try c.cookies.save([bed.cookie("Seminar_Session", "erfunden", domain: StudIPSync.base.host!)])
        try await m.setDemo(true)
        let notifier = QuietNotifier()
        let settings = BackgroundSyncSettings(defaults: bed.defaults)
        let b = BackgroundSyncController(containers: m, account: a, settings: settings, scheduler: NoScheduler(), notifier: notifier)
        b.allowed = { true }
        let studip = RecordingStudIP()
        b.target = { [weak m] container in
            guard let m, m.active === container else { return nil }
            return StudIPClientTarget(sync: m.studip, client: self.client(studip))
        }
        _ = await b.perform(.processing)
        XCTAssertEqual(b.lastRecord?.outcome, .skipped(.demo))
        XCTAssertEqual(b.lastRecord?.text, "übersprungen: Demo-Inhalte aktiv")
        XCTAssertEqual(studip.requests, [])
        XCTAssertEqual(notifier.posts, 0)
        // auch wenn der Stand der Oberflaeche noch nicht geladen ist: der Abgleich fragt selbst die Datenbank
        let direct = await StudIPClientTarget(sync: m.studip, client: client(studip)).runInBackground(.refresh)
        XCTAssertEqual(direct.skipped, .demo)
        XCTAssertEqual(studip.requests, [])
    }

    // MARK: Entfernen

    func testRemoveTakesTheDemoAndItsCopiesAndKeepsOwnData() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        // eigene Daten vorher
        _ = try await c.api.value("/api/timetable/events", method: "POST", body: ["title": "Eigene Lerngruppe", "weekday": 4, "start_time": "16:00", "end_time": "17:00"])
        _ = try await c.api.value("/api/packages", method: "POST", body: ["date": "2026-10-29", "title": "Eigenes Paket"])
        try await m.setDemo(true)
        // Kopien der Demo-Datei auf dem Geraet, wie sie der Editor anlegt (PDF-Zwischenspeicher, Journal, Vorschaubild)
        let root = c.layout.root
        let pdf = AppPaths.pdf("demo-skript", namespace: .local, root: root)
        let journal = DataContainerLayout.Folder.journal.url(in: root)
            .appendingPathComponent(LocalJournal.directory(documentID: "demo-skript", namespace: .local), isDirectory: true)
        let thumbs = DataContainerLayout.Folder.thumbs.url(in: root)
        let thumb = thumbs.appendingPathComponent(UFThumbnails.fileNamePrefix(fileID: "demo-skript", namespace: .local) + "1.png")
        let ownThumb = thumbs.appendingPathComponent(UFThumbnails.fileNamePrefix(fileID: "f-eigen", namespace: .local) + "1.png")
        for (url, isDir) in [(pdf, false), (journal, true), (thumb, false), (ownThumb, false)] {
            try FileManager.default.createDirectory(at: isDir ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !isDir { try Data([1]).write(to: url) } else { try Data("{}".utf8).write(to: url.appendingPathComponent("meta.json")) }
        }
        let r = try await m.setDemo(false)
        XCTAssertEqual(r["removed"], ["files": 3, "events": 3, "packages": 3])
        XCTAssertFalse(m.demoActive)
        for url in [pdf, journal, thumb] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownThumb.path), "Vorschaubild einer eigenen Datei bleibt")
        let s = try await c.api.value("/api/demo")
        XCTAssertEqual([s["enabled"], s["files"], s["events"], s["packages"]], [false, 0, 0, 0])
        let events = try await c.api.value("/api/timetable/events")
        XCTAssertEqual((events.array ?? []).compactMap { $0["title"]?.string }, ["Eigene Lerngruppe"])
        let cal = try await c.api.value("/api/calendar?start=2026-10-26&end=2026-11-01").jsonString()
        XCTAssertTrue(cal.contains("Eigenes Paket"))
        XCTAssertFalse(cal.contains("Übungsblatt 1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.layout.root.appendingPathComponent("files/Demo").path))
        // danach wieder die Karte zum Verbinden
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive), .local(.notConnected))
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    /// Die Demo gehoert zum Container (Nutzer, Hochschule): die andere Hochschule sieht sie nicht; "Daten dieser
    /// Hochschule löschen" nimmt sie mit
    func testDemoBelongsToTheContainer() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let luh = try bed.open(m, a)
        try await m.setDemo(true)
        XCTAssertTrue(m.demoActive)
        a.chooseUniversity(.hildesheim)
        let hi = try bed.open(m, a)
        XCTAssertFalse(m.demoActive, "anderer Container: zunaechst aus")
        await m.refreshDemo()
        XCTAssertFalse(m.demoActive, "an der Uni Hildesheim keine Demo")
        let s = try await hi.api.value("/api/demo")
        XCTAssertEqual(s["files"], 0)
        a.chooseUniversity(.luh)
        let back = try bed.open(m, a)
        XCTAssertEqual(back.key, luh.key)
        await m.refreshDemo()
        XCTAssertTrue(m.demoActive, "zurueck an der LUH: die Demo ist noch da")
        await m.deleteUniversityData(back.key)
        await m.refreshDemo()
        XCTAssertFalse(m.demoActive, "Daten der Hochschule geloescht: Demo weg")
        let after = try await XCTUnwrap(m.active).api.value("/api/demo")
        XCTAssertEqual(after["files"], 0)
    }

    // MARK: Oberflaeche (Bedienungshilfen wie StudyPlanLocalAppTests)

    func testDashboardShowsTheDemoHintAndRemoves() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        try await m.setDemo(true)
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let page = try show(DashboardView(api: c.api), m: m, a: a)
        await eventually({ self.shows(page.view, DemoTexts.barTitle) && self.shows(page.view, "Übungsblatt 1") }, texts(page.view).joined(separator: "\n"))
        XCTAssertFalse(shows(page.view, "Stud.IP verbinden"), "keine Karte zum Verbinden im Demo-Betrieb")
        XCTAssertTrue(tap(DemoTexts.barRemove, in: page.view), texts(page.view).joined(separator: "\n"))
        await eventually({ page.overlay.ask != nil }, "Rueckfrage vor dem Entfernen")
        answer(page.overlay, true)
        await eventually({ !m.demoActive && page.toast.message == DemoTexts.removed }, page.toast.message ?? "keine Meldung")
        await eventually({ !self.shows(page.view, DemoTexts.barTitle) && self.shows(page.view, "Stud.IP verbinden") }, texts(page.view).joined(separator: "\n"))
        let s = try await c.api.value("/api/demo")
        XCTAssertEqual(s["files"], 0)
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    func testSettingsCardInstallsAndRemoves() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let page = try show(SettingsPage(initialTab: "advanced"), m: m, a: a)
        await eventually({ self.shows(page.view, DemoTexts.cardTitle) && self.shows(page.view, DemoTexts.install) }, texts(page.view).joined(separator: "\n"))
        XCTAssertTrue(shows(page.view, "Erweitert"))
        XCTAssertTrue(tap(DemoTexts.install, in: page.view), texts(page.view).joined(separator: "\n"))
        await eventually({ m.demoActive && self.shows(page.view, DemoTexts.remove) }, texts(page.view).joined(separator: "\n"))
        XCTAssertEqual(page.toast.message, "Demo angelegt: 3 PDFs, 3 Termine, 3 Lernpakete", "wie im Web")
        await eventually({ self.shows(page.view, "3 PDFs · 3 Termine · 3 Lernpakete") }, texts(page.view).joined(separator: "\n"))
        XCTAssertTrue(tap(DemoTexts.remove, in: page.view))
        await eventually({ page.overlay.ask != nil })
        answer(page.overlay, false)                                          // abgebrochen: bleibt
        await pump(timeout: 0.5)
        XCTAssertTrue(m.demoActive)
        XCTAssertTrue(shows(page.view, DemoTexts.remove))
        XCTAssertTrue(tap(DemoTexts.remove, in: page.view))
        await eventually({ page.overlay.ask != nil })
        answer(page.overlay, true)
        await eventually({ !m.demoActive && self.shows(page.view, DemoTexts.install) }, texts(page.view).joined(separator: "\n"))
        let s = try await c.api.value("/api/demo")
        XCTAssertEqual(s["enabled"], false)
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    // MARK: Hilfen

    private final class NoScheduler: BackgroundTaskScheduling {
        func pending() async -> [BackgroundSyncKind: Date?] { [:] }
        func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {}
        func cancel(_ kind: BackgroundSyncKind) {}
    }

    private final class QuietNotifier: BackgroundNotifying {
        private(set) var posts = 0
        func requestPermission() async -> Bool { true }
        func isAllowed() async -> Bool { true }
        func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts += 1 }
    }

    /// Echter Stud.IP-Abgleich des Containers mit einem Client des Tests
    private final class StudIPClientTarget: BackgroundSyncable {
        let sync: StudIPSync
        let client: StudIPClient
        init(sync: StudIPSync, client: StudIPClient) { self.sync = sync; self.client = client }
        var fileSource: String { sync.fileSource }
        var usableSources: [String] { sync.usableSources }
        var isRunning: Bool { sync.isRunning }
        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport { await sync.runInBackground(kind, client: client) }
    }

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private struct Hosted {
        let view: UIView
        let toast: UFToastCenter
        let overlay: UFOverlay
    }

    /// Wie die App: Demo-Stand aus dem Container in die Umgebung (`\.ufDemoActive`), Abgleich des Containers
    private struct DemoRoot<Content: View>: View {
        @ObservedObject var containers: ContainerManager
        let content: Content
        var body: some View {
            content
                .environmentObject(containers.studip)
                .environment(\.ufDemoActive, containers.demoActive)
        }
    }

    private func show<V: View>(_ view: V, m: ContainerManager, a: AccountStore) throws -> Hosted {
        let overlay = UFOverlay(), router = UFRouter(), toast = UFToastCenter()
        let root = DemoRoot(containers: m, content: view
            .modifier(UFDrawerHost(overlay: overlay))
            .modifier(UFModalHost(overlay: overlay)))
            .environmentObject(Session(local: try XCTUnwrap(m.active).api, defaults: bed.defaults))
            .environmentObject(router)
            .environmentObject(ShellState())
            .environmentObject(overlay)
            .environmentObject(toast)
            .environmentObject(m)
            .environmentObject(a)
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return Hosted(view: hosting.view, toast: toast, overlay: overlay)
    }

    /// Rueckfrage beantworten wie "OK" bzw. "Abbrechen" im Hinweis
    private func answer(_ overlay: UFOverlay, _ ok: Bool) {
        guard case .confirm(_, let c) = overlay.ask else { return XCTFail("keine Rueckfrage") }
        overlay.ask = nil
        c.resume(returning: ok)
    }

    /// Wie XCTAssertTrue, aber wartend (bis 10 s), Meldung erst beim Scheitern
    private func eventually(_ done: () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
        if !(await pump(until: done)) { XCTFail(message(), file: file, line: line) }
    }

    /// Warten, bis die Bedingung gilt; gibt den Hauptthread frei (async-Test: die Ansicht und ihre Ladevorgaenge laufen
    /// auf dem MainActor weiter)
    @discardableResult
    private func pump(timeout: Double = 10, until done: () -> Bool = { false }) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        return done()
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
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
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard e.accessibilityLabel == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}

/// PDFKit fuer die Demo-PDFs (wie der Editor)
enum PDFKitCheck {
    static func pageCount(_ data: Data) -> Int? { PDFDocument(data: data)?.pageCount }
    static func text(_ data: Data) -> String { PDFDocument(data: data)?.string ?? "" }
}

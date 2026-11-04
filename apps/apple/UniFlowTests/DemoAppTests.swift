import PDFKit
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Demo-Inhalte nur fuer die App-Pruefung (Entscheidung 04.11.2026 "Nur für Prüfer"): einziger Weg ist der kleine
/// Textlink "Ohne Hochschulkonto ansehen (Demo)" ganz unten auf der Anmeldeseite (`FirstLoginBottomBar`, dahinter
/// `FirstLoginFlow.startDemo`), keiner in den Einstellungen; solange die Demo aktiv ist, die schmale Leiste
/// "Demo-Inhalte – erfunden, ohne Hochschule" mit "Beenden" in der App-Huelle ("Beenden" entfernt alles und fuehrt zur
/// Anmeldeseite), keine Karten "… verbinden", kein Abgleich und keine Anfrage an die Hochschule im Demo-Betrieb,
/// Entfernen samt Kopien auf dem Geraet, Demo je Container. Erfundene Nutzer, Temp-Ordner, kein Netz (UniStubProtocol
/// zaehlt mit).
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

    // MARK: Texte

    func testTextsNameOnlyTheLoginLinkAndBeenden() {
        XCTAssertEqual(DemoTexts.firstStart, "Ohne Hochschulkonto ansehen (Demo)", "die Pruefhinweise nennen ihn wortgleich")
        XCTAssertEqual(DemoTexts.barTitle, "Demo-Inhalte – erfunden, ohne Hochschule")
        XCTAssertEqual(DemoTexts.barEnd, "Beenden")
        XCTAssertTrue(DemoTexts.syncBlocked.contains("„Beenden“"), "Sync im Demo-Betrieb: Weg hinaus")
        XCTAssertFalse(DemoTexts.syncBlocked.contains("Einstellungen"), "kein Weg ueber die Einstellungen mehr")
        XCTAssertTrue(DemoTexts.confirmEnd.contains("Anmeldeseite"))
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

    // MARK: Oberflaeche (Bedienungshilfen wie StoreScreenshotTests)

    /// Einstellungen: nirgends ein Weg zur Demo (Erweitert und Zugang & Darstellung), auch nicht bei aktiver Demo
    func testSettingsHaveNoDemoEntry() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { HostedEnvironment.accessibilityAutomation(false) }
        for (tab, marker) in [("advanced", "Erweitert"), ("account", "Konto & Tarif")] {
            for demo in [false, true] {
                if demo != m.demoActive { try await m.setDemo(demo) }
                let env = try hostApp(SettingsPage(initialTab: tab), m: m, a: a, api: c.api)
                await eventually({ self.shows(env.view, marker) }, "\(tab): " + texts(env.view).joined(separator: "\n"))
                await pump(timeout: 1.0)                                       // Karten laden nach
                let demoTexts = texts(env.view).filter { $0.localizedCaseInsensitiveContains("demo") }
                XCTAssertEqual(demoTexts, [], "\(tab), Demo \(demo ? "an" : "aus"): kein Demo-Eintrag")
                XCTAssertFalse(shows(env.view, "Demo-Inhalte anlegen"))
                env.window.isHidden = true
            }
        }
        XCTAssertEqual(SettingsNav.localKeys(withPlan: true, ownServer: false), ["account", "modules", "plan", "advanced"])
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    /// Anmeldeseite: ganz unten der kleine Textlink (kein Knopf mit Symbol), unter "Später anmelden"; antippen startet
    /// die Demo; ohne Angebot (schon angemeldet) fehlt er
    func testLoginPageHasTheDemoLinkAtTheBottom() async throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { HostedEnvironment.accessibilityAutomation(false) }
        var taps = 0
        let env = try hostWithEnvironment(VStack { Spacer(); FirstLoginBottomBar(demo: .offered, onLater: {}, onDemo: { taps += 1 }) })
        await eventually({ self.shows(env.view, DemoTexts.firstStart) }, texts(env.view).joined(separator: "\n"))
        let link = try XCTUnwrap(element(DemoTexts.firstStart, in: env.view))
        let later = try XCTUnwrap(element("Später anmelden", in: env.view))
        XCTAssertTrue(link.accessibilityTraits.contains(.button))
        XCTAssertGreaterThanOrEqual(link.accessibilityFrame.midY, later.accessibilityFrame.maxY - 1, "Link ganz unten, unter „Später anmelden“")
        XCTAssertTrue(tap(DemoTexts.firstStart, in: env.view))
        XCTAssertEqual(taps, 1)
        env.window.isHidden = true

        let starting = try hostWithEnvironment(FirstLoginBottomBar(demo: .starting, onLater: {}))
        await eventually({ self.shows(starting.view, DemoTexts.firstStartRunning) }, texts(starting.view).joined(separator: "\n"))
        starting.window.isHidden = true

        let hidden = try hostWithEnvironment(FirstLoginBottomBar(demo: .hidden, onLater: {}))
        await eventually({ self.shows(hidden.view, "Später anmelden") })
        XCTAssertFalse(shows(hidden.view, DemoTexts.firstStart))
    }

    /// Leiste nur bei aktiver Demo (ueber jeder Seite der App-Huelle); in den Store-Bildern mit `\.ufDemoBarHidden` aus
    func testDemoBarShowsOnlyWhileDemoIsActive() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        a.markLoginDone()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { HostedEnvironment.accessibilityAutomation(false) }
        // ohne Demo: Karte zum Verbinden, keine Leiste
        let off = try hostApp(MainView(), m: m, a: a, api: c.api)
        await eventually({ self.shows(off.view, "Stud.IP verbinden") }, texts(off.view).joined(separator: "\n"))
        XCTAssertFalse(shows(off.view, DemoTexts.barTitle))
        off.window.isHidden = true
        // mit Demo: die Leiste auf der Uebersicht und auf anderen Seiten (Einstellungen)
        try await m.setDemo(true)
        let on = try hostApp(MainView(), m: m, a: a, api: c.api)
        await eventually({ self.shows(on.view, DemoTexts.barTitle) && self.shows(on.view, "Übungsblatt 1") }, texts(on.view).joined(separator: "\n"))
        XCTAssertNotNil(element(DemoTexts.barEnd, in: on.view))
        XCTAssertFalse(shows(on.view, "Stud.IP verbinden"), "keine Karte zum Verbinden im Demo-Betrieb")
        on.router.go(.settings(tab: "account"))
        await eventually({ self.shows(on.view, "Konto & Tarif") && self.shows(on.view, DemoTexts.barTitle) }, texts(on.view).joined(separator: "\n"))
        on.window.isHidden = true
        // Store-Bilder: Schalter nur fuer Tests
        let shot = try hostApp(MainView().environment(\.ufDemoBarHidden, true), m: m, a: a, api: c.api)
        await eventually({ self.shows(shot.view, "Übungsblatt 1") }, texts(shot.view).joined(separator: "\n"))
        XCTAssertFalse(shows(shot.view, DemoTexts.barTitle))
        XCTAssertFalse(shows(shot.view, DemoTexts.barEnd))
        shot.window.isHidden = true
        XCTAssertEqual(UniStubProtocol.requests.count, 0)
    }

    /// "Beenden": Rueckfrage (Abbrechen laesst alles), dann ist alles weg, was die Demo angelegt hat (Datenbank, Ordner,
    /// Kopien auf dem Geraet), eigene Daten bleiben, und es geht zur Anmeldeseite der Hochschule zurueck
    func testBeendenClearsTheDemoAndReturnsToTheLoginPage() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        let c = try bed.open(m, a)
        // wie der Link auf der Anmeldeseite
        XCTAssertEqual(a.stage, .universityLogin)
        _ = try await c.api.value("/api/packages", method: "POST", body: ["date": "2026-10-29", "title": "Eigenes Paket"])
        try await FirstLoginFlow.startDemo(containers: m, account: a)
        XCTAssertEqual(a.stage, .ready)
        let pdf = AppPaths.pdf("demo-skript", namespace: .local, root: c.layout.root)
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: pdf)
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostApp(MainView(), m: m, a: a, api: c.api)
        await eventually({ self.shows(env.view, DemoTexts.barTitle) }, texts(env.view).joined(separator: "\n"))
        env.router.go(.settings(tab: "account"))
        await eventually({ self.shows(env.view, "Konto & Tarif") })
        XCTAssertTrue(tap(DemoTexts.barEnd, in: env.view), texts(env.view).joined(separator: "\n"))
        await eventually({ env.overlay.ask != nil }, "Rueckfrage vor dem Beenden")
        answer(env.overlay, false)                                             // abgebrochen: bleibt
        await pump(timeout: 0.5)
        XCTAssertTrue(m.demoActive)
        XCTAssertEqual(a.stage, .ready)
        XCTAssertTrue(tap(DemoTexts.barEnd, in: env.view))
        await eventually({ env.overlay.ask != nil })
        answer(env.overlay, true)
        await eventually({ !m.demoActive && env.toast.message == DemoTexts.ended }, env.toast.message ?? "keine Meldung")
        XCTAssertEqual(a.stage, .universityLogin, "zurueck zur Anmeldeseite (dort wieder der Link)")
        XCTAssertTrue(FirstLoginFlow.offersDemo(studip: m.studip, qis: m.qis, hildesheim: nil))
        XCTAssertEqual(env.router.route, .dashboard, "nach erneutem Anmelden nicht auf einer Demo-Seite")
        await eventually({ !self.shows(env.view, DemoTexts.barTitle) }, texts(env.view).joined(separator: "\n"))
        // alles weg, was die Demo angelegt hat
        let s = try await c.api.value("/api/demo")
        XCTAssertEqual([s["enabled"], s["files"], s["events"], s["packages"]], [false, 0, 0, 0])
        let lib = try await c.api.value("/api/library")
        XCTAssertEqual(lib["files"]?.array?.count ?? 0, 0, lib.jsonString())
        let week = try await c.api.value("/api/timetable/week?start=2026-10-26").jsonString()
        XCTAssertFalse(week.contains("Grundlagen der Informatik"), week)
        let cal = try await c.api.value("/api/calendar?start=2026-10-26&end=2026-11-01").jsonString()
        XCTAssertFalse(cal.contains("Übungsblatt 1"))
        XCTAssertTrue(cal.contains("Eigenes Paket"), "eigene Daten bleiben")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path), "Kopie auf dem Geraet weg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.layout.root.appendingPathComponent("files/Demo").path))
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip, demo: m.demoActive), .local(.notConnected))
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
        func schedule(_ content: BackgroundNotice.Content, id: String, thread: String, at date: Date) async {}
        func cancel(id: String) {}
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

    /// Wie die App (alle Umgebungsobjekte, `HostedEnvironment`), mit Container, Konto und Abgleich des Tests und dem
    /// Demo-Stand des Containers in der Umgebung
    private func hostApp<V: View>(_ view: V, m: ContainerManager, a: AccountStore, api: APIClient) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(DemoRoot(containers: m, content: view.environmentObject(m).environmentObject(a)),
                                          api: api, size: CGSize(width: 1180, height: 1400), studip: m.studip)
        addTeardownBlock { @MainActor in env.window.isHidden = true }
        return env
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
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
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

    private func element(_ label: String, in view: UIView) -> NSObject? {
        elements(in: view).first { $0.accessibilityLabel == label }
    }

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

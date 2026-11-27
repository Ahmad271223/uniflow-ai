import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Georg-August-Universitaet Goettingen in der App (26.11.2026, docs/GOETTINGEN-2026-11-26.md): Hochschulwahl hinter dem
/// Schalter, Anmeldung ueber das eigene Formular von Stud.IP, Erstabgleich gegen die Nachbildung des echten Stud.IP
/// Goettingen (apps/apple/DebugStub/goettingen: erfundene Daten im gesehenen Aufbau, samt der Antworten, die dort nicht
/// gehen), Mensa ohne Preise und alles, was es dort (noch) nicht gibt, ausgeblendet. Nie ein Netz.
@MainActor
final class GoettingenAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    /// Donnerstag, 26.11.2026, 10:00 in Berlin
    private let clock = UniFlowClock.fixed(berlin: "2026-11-26T10:00:00")!
    private let base = URL(string: "https://studip.uni-goettingen.de")!

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "goettingen", clock: clock)
    }

    override func tearDown() async throws {
        await bed.tearDown()
        try await super.tearDown()
    }

    private static var stubDirectory: URL { ContainerTestBed.repoURL("apps/apple/DebugStub/goettingen") }
    private var stub: DebugStubTransport { DebugStubTransport(directory: Self.stubDirectory) }

    /// Zaehlt die Anfragen an die Nachbildung
    private final class Counting: StudIPTransport, @unchecked Sendable {
        let inner: DebugStubTransport
        private let lock = NSLock()
        private var log: [String] = []
        init(_ inner: DebugStubTransport) { self.inner = inner }
        var calls: [String] { lock.withLock { log } }
        func count(_ part: String) -> Int { calls.filter { $0.contains(part) }.count }
        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            lock.withLock { log.append(url.absoluteString.removingPercentEncoding ?? url.absoluteString) }
            return try await inner.get(url, accept: accept)
        }
        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            lock.withLock { log.append(url.absoluteString) }
            return try await inner.download(url, to: file)
        }
    }

    // MARK: Schalter und Hochschulwahl

    func testBehindTheSwitch() {
        // Debug (Simulator, Tests): zur Wahl; der Store-Stand (Release "luh hildesheim") nicht
        XCTAssertEqual(UFReleaseUniversities.parse(Bundle.main.infoDictionary?[UFReleaseUniversities.infoKey] as? String)?.contains(.goettingen), true,
                       "project.yml Debug: UF_SHIPPED_UNIVERSITIES nennt goettingen")
        UFReleaseUniversities.withShipped([.luh, .hildesheim]) {
            XCTAssertEqual(UFReleaseUniversities.choices(), [.luh, .hildesheim], "Store: Göttingen steht nicht in der Hochschulwahl")
        }
        UFReleaseUniversities.withShipped([.luh, .hildesheim, .goettingen]) {
            XCTAssertEqual(UFReleaseUniversities.choices(), [.luh, .hildesheim, .goettingen])
        }
        let text = UniversityOption.services(.goettingen)
        XCTAssertTrue(text.contains("Stud.IP") && text.contains("Schwarze Brett") && text.contains("Mensen"))
        XCTAssertTrue(text.contains("FlexNow"), "ehrlich: Noten bleiben im Browser")
        XCTAssertFalse(text.contains("QIS") || text.contains("LUH"))
        XCTAssertEqual(FirstLoginStep.steps(for: .goettingen), [.studip], "nur Stud.IP, kein zweiter Schritt")
        XCTAssertEqual(FirstLoginStep.steps(for: .luh), [.studip, .qis])
        XCTAssertTrue(FirstLoginStep.studip.intro(for: .goettingen).contains("„Benutzername“"))
        XCTAssertFalse(FirstLoginStep.studip.intro(for: .goettingen).contains("Aufzeichnungen"))
        XCTAssertEqual(FirstLoginStep.studip.intro(for: .luh), FirstLoginStep.studip.intro, "LUH unverändert")
        XCTAssertEqual(UniAutoLoginCard.services(.goettingen), "Stud.IP")
        XCTAssertEqual(UniAutoLoginCard.slots(sameEverywhere: false, university: .goettingen).count, 1, "ein Zugang, keine Portale")
        XCTAssertEqual(UniversitySyncStart.connectHint(.goettingen), UniversitySyncStart.connectHint(.luh))
    }

    // MARK: Anmeldung

    func testLoginEntryHostsAndRules() {
        // Einstieg: die Anmeldeseite von Stud.IP selbst; an der LUH weiter das WebSSO
        XCTAssertEqual(StudIPSync.loginEntryURL(university: .goettingen, base: base).absoluteString, "https://studip.uni-goettingen.de/dispatch.php/login")
        XCTAssertEqual(StudIPSync.loginEntryURL(base: base).absoluteString, "https://studip.uni-goettingen.de/dispatch.php/login")
        XCTAssertEqual(StudIPSync.loginEntryURL(university: .luh, base: StudIPSync.luhBase), StudIPSync.ssoLoginURL(base: StudIPSync.luhBase))
        XCTAssertEqual(StudIPSync.loginEntryURL(base: StudIPSync.luhBase), StudIPSync.ssoLoginURL(base: StudIPSync.luhBase))
        // "angekommen" erst hinter der Anmeldung: die Anmeldeseite liegt dort auf demselben Rechner wie Stud.IP
        func past(_ s: String, _ u: UniversityKey = .goettingen) -> Bool {
            StudIPSync.isPastLogin(URL(string: s)!, university: u, base: u == .luh ? StudIPSync.luhBase : base)
        }
        XCTAssertFalse(past("https://studip.uni-goettingen.de/dispatch.php/login"))
        XCTAssertFalse(past("https://studip.uni-goettingen.de/dispatch.php/login?again=yes&sso=casgoe&cancel_login=1"))
        XCTAssertTrue(past("https://studip.uni-goettingen.de/dispatch.php/start"))
        XCTAssertTrue(past("https://studip.uni-goettingen.de/dispatch.php/start/index"))
        XCTAssertFalse(past("https://cas.uni-goettingen.de/cas/login"))
        XCTAssertFalse(past("https://studip.uni-hannover.de/dispatch.php/start"), "nie das Stud.IP einer anderen Hochschule")
        XCTAssertTrue(past("https://studip.uni-hannover.de/dispatch.php/start", .luh))
        XCTAssertTrue(past("https://studip.uni-hannover.de/dispatch.php/login?sso=shib&again=yes", .luh), "LUH wie bisher (kein eigenes Formular)")
        XCTAssertFalse(past("https://studip.uni-hannover.de/Shibboleth.sso/Login", .luh))
        // Anfragen des Abgleichs: nur der eigene Rechner, nie die Anmeldeseiten der LUH
        XCTAssertEqual(URLSessionUniTransport.studipDomains(host: "studip.uni-goettingen.de"), ["studip.uni-goettingen.de"])
        XCTAssertEqual(URLSessionUniTransport.studipDomains(host: "studip.uni-hannover.de"), ["sso.idm.uni-hannover.de", "studip.uni-hannover.de"])
        XCTAssertEqual(URLSessionUniTransport.studipDomains, ["sso.idm.uni-hannover.de", "studip.uni-hannover.de"], "LUH unverändert")
        XCTAssertEqual(UniWebSessions.domains(.goettingen), ["uni-goettingen.de"])
        // In-App-Browser: Stud.IP und (seit 27.11.2026) FlexNow in der App; eCampus und E-Mail gehen an den Browser des Systems
        XCTAssertEqual(UniLinks.route(URL(string: "https://studip.uni-goettingen.de/dispatch.php/my_courses")!, university: .goettingen),
                       .inApp(URL(string: "https://studip.uni-goettingen.de/dispatch.php/my_courses")!))
        XCTAssertEqual(UniLinks.route(URL(string: "https://flexnow2.uni-goettingen.de/")!, university: .goettingen),
                       .inApp(URL(string: "https://flexnow2.uni-goettingen.de/")!))
        for outside in ["https://ecampus.uni-goettingen.de/", "https://email.stud.uni-goettingen.de/",
                        "https://studip.uni-hannover.de/"] {
            XCTAssertEqual(UniLinks.route(URL(string: outside)!, university: .goettingen), .system, outside)
        }
        XCTAssertTrue(UniLoginHelper.idpTargets(.goettingen).isEmpty, "kein Identitätsanbieter: das Formular gehört Stud.IP")
        // Mitlesen nur auf dem Formular der eigenen Hochschule
        XCTAssertNotNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: "studip.uni-goettingen.de", port: 0,
                                                    frameURL: URL(string: "https://studip.uni-goettingen.de/dispatch.php/login"),
                                                    body: ["user": "erika.muster", "pass": "geheim"], university: .goettingen))
        XCTAssertNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: "studip.uni-goettingen.de", port: 0,
                                                 frameURL: URL(string: "https://studip.uni-goettingen.de/dispatch.php/login"),
                                                 body: ["user": "erika.muster", "pass": "geheim"], university: .luh))
        XCTAssertNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: "studip.uni-goettingen.de", port: 0,
                                                 frameURL: URL(string: "https://studip.uni-goettingen.de/dispatch.php/start"),
                                                 body: ["user": "erika.muster", "pass": "geheim"], university: .goettingen))
    }

    // MARK: Erstabgleich gegen die Nachbildung

    func testFirstSyncFillsTheApp() async throws {
        let m = bed.manager()
        let a = bed.account(.goettingen)
        XCTAssertEqual(a.stage, .universityLogin)
        let c = try bed.open(m, a)
        XCTAssertEqual(c.key.university, .goettingen)
        // nur Stud.IP: kein QIS, keine Uni-Mail, keine Verbindung einer anderen Hochschule
        XCTAssertTrue(m.studip.offersStudIP)
        XCTAssertEqual(m.studip.base, base)
        XCTAssertEqual(m.studip.loginEntry.absoluteString, "https://studip.uni-goettingen.de/dispatch.php/login")
        XCTAssertNil(m.qis)
        XCTAssertNil(m.uniMail)
        XCTAssertNil(m.hildesheim)
        XCTAssertNil(m.hsh)
        XCTAssertTrue(m.syncsAllPortals)
        XCTAssertEqual(m.portalNames, [OpenSync.studIP], "der Sync-Knopf gleicht dort genau Stud.IP ab")
        XCTAssertFalse(FirstLoginFlow.anyConnected(studip: m.studip, qis: nil, hildesheim: nil))

        // angemeldet (die Anmeldeansicht uebergibt die Cookies; Name wie am echten Rechner)
        m.studip.signedIn(cookies: [bed.cookie("Studip_Session", "s1", domain: base.host!)])
        XCTAssertTrue(m.studip.hasStoredSession)
        XCTAssertTrue(FirstLoginFlow.isConnected(.studip, studip: m.studip, qis: nil, hildesheim: nil))
        let counting = Counting(stub)
        await m.studip.run(client: StudIPClient(base: base, transport: counting, pauseMillis: 0, retry: UniRetry(attempts: 1)))
        XCTAssertEqual(m.studip.phase, .idle, m.studip.lastSummary ?? "")
        try await bed.waitUntil("Aufzeichnungen und Lernstoff nach „fertig“", timeout: 20) { !m.studip.finishingUp }
        let summary = try XCTUnwrap(m.studip.lastSummary)
        XCTAssertTrue(summary.hasPrefix("5 neu/geändert"), summary)
        for bad in ["nicht lesbar", "Fehler", "abgelaufen", "nicht erreichbar", "nicht gespeichert"] {
            XCTAssertFalse(summary.contains(bad), "Fehlende Bereiche des Göttinger Stud.IP dürfen nicht als Fehler erscheinen: \(summary)")
        }
        // Erstabgleich-Seite: drei Zeilen, alle fertig; keine Zeile "Noten aus QIS"
        let rows = FirstSyncView.rows(studip: m.studip, qis: nil)
        XCTAssertEqual(rows.map(\.id), ["files", "timetable", "recordings"])
        XCTAssertEqual(rows.map(\.title), ["Kurse und Dateien aus Stud.IP", "Stundenplan", "Videos aus Stud.IP"], "kein „Opencast“")
        XCTAssertEqual(rows.map(\.state), [.done, .done, .done])
        XCTAssertTrue(FirstSyncProgress.isFinished(rows))

        // Dateien (samt Unterordner), ganz geladen
        let lib = try await c.api.value("/api/library")
        let names = (lib["files"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(names, ["01_Vorlesung_Mengen_und_Abbildungen.pdf", "02_Vorlesung_Folgen.pdf", "Fall_01_Kaufvertrag.pdf", "Skript_BGB_AT.pdf",
                               "Uebungsblatt_01.pdf"])
        XCTAssertEqual(m.studip.entries.count, 5)
        for e in m.studip.entries {
            let url = try XCTUnwrap(m.studip.fileURL(e))
            XCTAssertTrue(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)), e.name)
        }
        XCTAssertEqual(counting.count("/content"), 5, "je Datei ein Abruf der ganzen Datei")

        // Stundenplan aus `schedule` (seminar-cycle-dates), Raeume wie im echten Stud.IP geschrieben
        let week = try await c.api.value("/api/timetable/week?start=2026-11-30")
        let days = week.list("days")
        XCTAssertEqual(days.first?.list("events").map { $0.s("start") ?? "" }, ["10:15"], "Mathematik montags")
        XCTAssertEqual(days.first?.list("events").first?.s("room"), "ZHG010 (ZHG)")
        XCTAssertEqual(days.dropFirst(3).first?.list("events").first?.s("kind"), "seminar", "Art 4 ist in Göttingen das Seminar")
        // Module, Kurs frueherer Semester nicht aktiv
        let modules = (try await c.api.value("/api/modules").array ?? []).compactMap { $0["name"]?.string }
        XCTAssertTrue(modules.contains { $0.contains("Mathematik") }, "\(modules)")
        XCTAssertTrue(modules.contains { $0.contains("Bürgerliche") }, "\(modules)")
        XCTAssertFalse(modules.contains { $0.contains("Statistik") }, "Sommersemester: nicht aktiv")
        // Nachrichten und Neuigkeiten
        let messages = try await c.api.value("/api/studip/messages")
        XCTAssertEqual(messages["total"], 2)
        let dash = try await c.api.value("/api/dashboard")
        XCTAssertNotNil(dash["today"])
        // Schwarzes Brett
        let board = try await c.api.value("/api/studip/bulletin")
        XCTAssertEqual(board["available"], true)
        XCTAssertEqual(board.list("topics").compactMap { $0.s("title") }, ["Biete", "Suche", "Wohnen & Zimmer"])
        XCTAssertEqual(board.list("entries").count, 4)
        XCTAssertEqual(board.s("url"), "https://studip.uni-goettingen.de/plugins.php/schwarzesbrettplugin/category/list")
        // Dienste, Mensa, Raeume der eigenen Hochschule
        let services = try await c.api.value("/api/services")
        XCTAssertEqual(services["university"]?.s("key"), "goettingen")
        XCTAssertEqual(services.list("services").compactMap { $0.s("key") }.prefix(3), ["studip", "flexnow", "ecampus"])
        let canteens = try await c.api.value("/api/mensa/canteens")
        XCTAssertEqual(canteens.s("default"), "goe-zentralmensa")
        XCTAssertEqual(canteens.list("canteens").prefix(3).compactMap { $0.s("id") }, ["goe-zentralmensa", "goe-cgin", "goe-turm"])
        let room = try await c.api.value("/api/rooms/resolve?text=ZHG010%20(ZHG)")
        XCTAssertEqual(room.s("university"), "goettingen")
        // was es dort nicht gibt: keine Noten, keine Meldezeitraeume
        let grades = try await c.api.value("/api/grades")
        XCTAssertEqual(grades.list("grades").count, 0)
        // seit 27.11.2026: nur die aus FlexNow gelesenen Anmeldungen (noch keine), keine Meldezeitraeume, keine Vorschlaege
        let registration = try await c.api.value("/api/exam-registration")
        XCTAssertEqual(registration["system"]?.string, "FlexNow", "\(registration)")
        XCTAssertEqual(registration["window"], .null)
        XCTAssertEqual(registration.list("suggestions").count, 0)
        XCTAssertEqual(registration.list("registered").count, 0)
        XCTAssertEqual(registration["show_card"]?.bool, false)

        // fehlende Wege: gemerkt statt jedes Mal gefragt; die Erweiterung der LUH fuer Aufzeichnungen nie gefragt
        XCTAssertEqual(counting.count("consultation-bookings"), 1)
        XCTAssertEqual(counting.count("studip/news"), 1)
        XCTAssertEqual(counting.count("opencastpluginluh"), 0)
        let db = try await c.host.backend().context.database
        let missing = try await db.withConnection { try StudIPExtras.loadMissing($0) }
        let failing = try await db.withConnection { try StudIPExtras.loadFailing($0) }
        XCTAssertNotNil(missing["consultations"])
        XCTAssertEqual(failing["studip-news"]?.string, clock.today)

        // zweiter Abgleich: nichts Neues, keine erneute Frage nach den fehlenden Wegen, keine Datei noch einmal
        await m.studip.run(client: StudIPClient(base: base, transport: counting, pauseMillis: 0, retry: UniRetry(attempts: 1)))
        XCTAssertEqual(m.studip.phase, .idle, m.studip.lastSummary ?? "")
        XCTAssertTrue(m.studip.lastSummary?.hasPrefix("0 neu/geändert") ?? false, m.studip.lastSummary ?? "")
        XCTAssertEqual(counting.count("consultation-bookings"), 1)
        XCTAssertEqual(counting.count("studip/news"), 1)
        XCTAssertEqual(counting.count("/content"), 5)

        a.markLoginDone()
        XCTAssertEqual(a.stage, .ready)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.connected))
    }

    /// Eine abgelaufene Sitzung (Stud.IP leitet auf seine Anmeldeseite um): "Anmeldung nötig", nichts geht verloren
    func testExpiredSessionAsksForLogin() async throws {
        final class Expired: StudIPTransport, @unchecked Sendable {
            func get(_ url: URL, accept: String?) async throws -> HTTPReply {
                HTTPReply(status: 200, contentType: "text/html;charset=utf-8",
                          finalURL: URL(string: "https://studip.uni-goettingen.de/dispatch.php/login")!, body: Data("<html></html>".utf8))
            }
            func download(_ url: URL, to file: URL) async throws -> HTTPReply { try await get(url, accept: nil) }
        }
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.goettingen))
        m.studip.signedIn(cookies: [bed.cookie("Studip_Session", "alt", domain: base.host!)])
        let end = await m.studip.run(client: StudIPClient(base: base, transport: Expired(), pauseMillis: 0))
        XCTAssertEqual(end, .sessionExpired)
        XCTAssertEqual(m.studip.phase, .needsLogin)
        XCTAssertTrue(m.studip.sessionKnownExpired)
        XCTAssertEqual(ServicesPage.tileStatus(studip: m.studip.phase, hasSession: true), .badge("Anmeldung nötig", .warn))
    }

    // MARK: Was es dort nicht gibt, ist ausgeblendet

    /// Hinweis „neu in StudiNow“ (Inhaber 26.11.2026: Goettingen in 1.0.8 „mit Verweis …, dass aktuell nur folgende
    /// Funktionen vorhanden sind und … nachgezogen werden“): nur fuer Goettingen, nennt Vorhandenes und Fehlendes, kein Datum
    func testNewUniversityNotice() throws {
        let n = try XCTUnwrap(UFUniversityScope.newNotice(.goettingen))
        XCTAssertEqual(n.title, "Universität Göttingen – neu in StudiNow")
        for part in ["Stud.IP", "Dateien", "Stundenplan", "Terminen", "Nachrichten", "Ankündigungen", "Lehrenden", "Schwarze Brett",
                     "Mensen (noch ohne Preise)"] {
            XCTAssertTrue(n.have.contains(part), part)
        }
        for part in ["FlexNow", "eCampus", "Uni-Mail", "Vorlesungsaufzeichnungen", "sobald das möglich ist"] {
            XCTAssertTrue(n.missing.contains(part), part)
        }
        let all = n.title + n.have + n.missing
        XCTAssertNil(all.range(of: #"\d{4}|Januar|Februar|März|Sommer|Winter|Woche|Monat"#, options: .regularExpression), "kein Datum versprechen")
        XCTAssertFalse(all.contains("iPad") || all.contains("iPhone"), "auf allen Geräten gleich")
        for u in [UniversityKey.luh, .hildesheim, .hsh] { XCTAssertNil(UFUniversityScope.newNotice(u), u.rawValue) }
        XCTAssertNil(UFUniversityScope.newNotice(nil))
        // Kasten: fuer Goettingen mit Inhalt (mehrere Zeilen hoch), fuer andere Hochschulen leer
        func height(_ u: UniversityKey) -> CGFloat {
            UIHostingController(rootView: UFUniversityNewNotice(university: u)).sizeThatFits(in: CGSize(width: 600, height: 2000)).height
        }
        XCTAssertGreaterThan(height(.goettingen), 120, "Titel und zwei Absätze")
        XCTAssertLessThan(height(.luh), 1, "kein Kasten an der LUH")
    }

    /// Erinnerungen an Abgaben: „Fristen aus dem Learnweb-Kalender“ nur an der Universitaet Hildesheim (Inhaber
    /// 27.11.2026 „Ja, korrigieren“: in Build 51 sahen Goettingen und LUH den Satz, weil der Build Hildesheim anbietet)
    func testLearnwebOnlyAtHildesheim() {
        UFReleaseUniversities.withShipped([.luh, .hildesheim, .goettingen]) {
            XCTAssertFalse(DueTexts.reminderText(for: .goettingen).contains("Learnweb"), DueTexts.reminderText(for: .goettingen))
            XCTAssertFalse(DueTexts.reminderText(for: .luh).contains("Learnweb"))
            XCTAssertTrue(DueTexts.reminderText(for: .hildesheim).contains("Fristen aus dem Learnweb-Kalender"))
            XCTAssertTrue(DueTexts.reminderText(for: .goettingen).contains("erkannten Termine und eingetragene Klausurtermine"))
            XCTAssertTrue(DueTexts.reminderText(for: nil).contains("Learnweb"), "ohne Container (eigener Server) wie bisher")
        }
        UFReleaseUniversities.withShipped([.luh]) { XCTAssertFalse(DueTexts.reminderText(for: nil).contains("Learnweb")) }
        // Herkunft einer Frist im Kalender: Learnweb nur bei Fristen aus dem Learnweb-Kalender, nie als Rueckfall
        func source(_ src: String?) -> String {
            var o: [String: JSONValue] = ["id": "f1", "title": "Abgabe 1", "kind": "abgabe", "date": "2026-12-01"]
            if let src { o["source"] = .string(src) }
            return UFHint.deadline(.object(o), date: "2026-12-01").source
        }
        XCTAssertEqual(source("studip"), "Aufgabe aus Stud.IP Courseware")
        XCTAssertEqual(source("learnweb"), "Frist aus dem Learnweb-Kalender")
        XCTAssertEqual(source(nil), "Frist")
        XCTAssertEqual(source("moodle"), "Frist")
    }

    func testNotOfferedAreasAreHidden() {
        XCTAssertFalse(UFUniversityScope.readsGrades(.goettingen))
        XCTAssertFalse(UFUniversityScope.offersStudyPlan(.goettingen))
        XCTAssertFalse(UFUniversityScope.offersCertificates(.goettingen))
        for u in [UniversityKey.luh, .hildesheim, .hsh] {
            XCTAssertTrue(UFUniversityScope.readsGrades(u) && UFUniversityScope.offersStudyPlan(u) && UFUniversityScope.offersCertificates(u), u.rawValue)
        }
        XCTAssertTrue(UFUniversityScope.readsGrades(nil) && UFUniversityScope.offersStudyPlan(nil), "ohne Container (eigener Server) wie bisher")
        // Menue: kein "Studienverlauf"; "Uni & Noten" bleibt (Dienste, Stundenplan, Schwarzes Brett)
        let hidden = UFNavItem.visible(local: true, gradesOnDevice: true, community: false, studyPlan: false).map(\.id)
        let shown = UFNavItem.visible(local: true, gradesOnDevice: true, community: false, studyPlan: true).map(\.id)
        XCTAssertFalse(hidden.contains("studyplan"))
        XCTAssertTrue(hidden.contains("services"))
        XCTAssertTrue(shown.contains("studyplan"))
        XCTAssertEqual(shown.filter { $0 != "studyplan" }, hidden, "sonst dasselbe Menü")
        // Wege zu den Seiten der Hochschule (Browser des Systems)
        XCTAssertEqual(UFUniversityScope.serviceURL("flexnow", .goettingen)?.absoluteString, "https://flexnow2.uni-goettingen.de/")
        XCTAssertEqual(UFUniversityScope.serviceURL("ecampus", .goettingen)?.absoluteString, "https://ecampus.uni-goettingen.de/")
        XCTAssertNil(UFUniversityScope.serviceURL("flexnow", .luh))
        // Texte: ehrlich und ohne QIS
        XCTAssertEqual(UFUniversityScope.gradesTitle(.goettingen), "Noten (FlexNow)")
        for text in [UFUniversityScope.gradesText(.goettingen), UFUniversityScope.servicesSub(.goettingen), UFUniversityScope.studyPlanText(.goettingen),
                     UFUniversityScope.studyPlanTitle(.goettingen), LUHSourcesCard.text(.goettingen), UFUniversityScope.settingsHint(.goettingen),
                     CertificatePortal.note(.goettingen)] {
            XCTAssertFalse(text.contains("QIS") || text.contains("LUH") || text.contains("Leibniz") || text.contains("Hannover"), text)
        }
        XCTAssertTrue(UFUniversityScope.gradesText(.goettingen).contains("noch nicht"))
        XCTAssertEqual(LUHSourcesCard.text(.luh), LUHSourcesCard.text, "LUH unverändert")
        XCTAssertTrue(UFUniversityScope.settingsHint(.luh).contains("QIS"))
        XCTAssertEqual(UFUniversityScope.examSource(.goettingen), "Stud.IP")
        XCTAssertEqual(UFUniversityScope.examSource(.luh), "QIS")
        XCTAssertEqual(UFUniversityScope.examsLater(.luh), "Prüfungstermine ergänzt QIS")
        XCTAssertFalse(UFUniversityScope.examsLater(.goettingen).contains("QIS"))
        // Erstabgleich ohne die Zeile "Noten aus QIS"; an der LUH bleibt sie
        let goe = FirstSyncProgress.luh(phase: .idle, hasSession: true, summary: "5 neu/geändert", qis: nil, qisMessage: nil, grades: false)
        XCTAssertEqual(goe.map(\.id), ["files", "timetable", "recordings"])
        let luh = FirstSyncProgress.luh(phase: .idle, hasSession: true, summary: "5 neu/geändert", qis: nil, qisMessage: nil)
        XCTAssertEqual(luh.map(\.id), ["files", "timetable", "recordings", "grades"])
    }

    // MARK: Mensa ohne Preise

    func testMensaShowsNoPriceWhereTheSourceHasNone() throws {
        let raw = try JSONValue.parse(Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/mensa/raw/stwgoe-zentralmensa.json")))
        let meals = Mensa.parseStwgoe(raw)["days"]?["2026-11-26"]?.array ?? []
        XCTAssertEqual(meals.count, 13)
        for m in meals {
            XCTAssertFalse(MensaUI.hasPrices(m))
            for role in ["student", "employee", "guest"] { XCTAssertNil(MensaUI.priceText(m, role: role), m.s("name") ?? "") }
            let spoken = MensaUI.accessibility(m, role: "student")
            XCTAssertFalse(spoken.contains("€") || spoken.contains("–,") || spoken.contains(", –"), spoken)
        }
        XCTAssertEqual(MensaUI.sorts(for: meals, priced: Mensa.sourceHasPrices("stwgoe")), ["line"],
                       "keine Sortierung nach Preis (und ohne Nährwerte keine nach Kalorien)")
        XCTAssertTrue(MensaUI.sorts(for: meals).contains("price"), "Quellen mit Preisen wie bisher")
        XCTAssertFalse(Mensa.sourceHasPrices("stwgoe"))
        // mit Preis (Hannover, Hildesheim) unveraendert
        let priced: JSONValue = ["name": "Chili", "prices": ["student": 3.8, "employee": .null, "guest": 5.2], "labels": ["rind"]]
        XCTAssertTrue(MensaUI.hasPrices(priced))
        XCTAssertEqual(MensaUI.priceText(priced, role: "student"), "3,80 €")
        XCTAssertEqual(MensaUI.priceText(priced, role: "employee"), "–", "nur diese Gruppe fehlt")
        XCTAssertTrue(MensaUI.sorts(for: [priced], priced: Mensa.sourceHasPrices("studifutter")).contains("price"))
        XCTAssertTrue(MensaUI.accessibility(priced, role: "student").contains("3,80 €"))
        XCTAssertFalse(MensaUI.noPrices.isEmpty)
        XCTAssertFalse(MensaUI.porkUnknownHint.isEmpty)
    }

    /// Die Nachbildung ist aktuell (tools/build-goettingen-stub.py) und liegt auch im Testbundle (Mac)
    func testStubFolderIsComplete() async throws {
        let dir = Self.stubDirectory
        for name in ["routes.json", "studip.html", "studip-angemeldet.html", "courses.json", "schedule.json", "events.ics", "brett-list.html"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
        let me = try await stub.get(base.appendingPathComponent("jsonapi.php/v1/users/me"), accept: nil)
        XCTAssertEqual(me.status, 200)
        let news = try await stub.get(URL(string: "https://studip.uni-goettingen.de/jsonapi.php/v1/studip/news?page%5Blimit%5D=50")!, accept: nil)
        XCTAssertEqual(news.status, 500, "wie am echten Stud.IP Göttingen")
        let wiki = try await stub.get(URL(string: "https://studip.uni-goettingen.de/jsonapi.php/v1/courses/x/wiki-pages")!, accept: nil)
        XCTAssertEqual(wiki.status, 404)
        let luh = try await stub.get(URL(string: "https://studip.uni-goettingen.de/plugins.php/opencastpluginluh/media/index?cid=x")!, accept: nil)
        XCTAssertEqual(luh.status, 403)
        XCTAssertFalse(DebugUniStub.isActive, "Tests laufen ohne -UFLoginStub")
    }
}

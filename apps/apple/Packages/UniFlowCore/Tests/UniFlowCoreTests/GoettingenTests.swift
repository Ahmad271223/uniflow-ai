import Foundation
import XCTest
@testable import UniFlowCore

/// Georg-August-Universitaet Goettingen (26.11.2026, docs/GOETTINGEN-2026-11-26.md): Profil und Schalter, eigenes
/// Anmeldeformular von Stud.IP, Abgleich gegen eine Nachbildung im Aufbau des echten Stud.IP Goettingen
/// (apps/apple/DebugStub/goettingen, erzeugt von tools/build-goettingen-stub.py) samt der Antworten, die dort nicht
/// gehen (studip/news 500, Sprechstunden 404, Erweiterung der LUH fuer Aufzeichnungen 403). Nie ein Netz.
final class GoettingenTests: XCTestCase {

    // MARK: Vorlesungszeiten (Rundgang 26.11.2026: Stundenplan zeigte die LUH-Zeit 12.10.2026-30.01.2027)

    func testLecturePeriodsOfGoettingen() throws {
        let t = Holidays.defaultTerm(university: "goettingen", today: "2026-11-26")
        XCTAssertEqual([t?.name, t?.start, t?.end], ["WiSe 2026/27", "2026-10-26", "2027-02-12"])
        XCTAssertEqual(Holidays.defaultTerm(university: "goettingen", today: "2027-03-01")?.name, "SoSe 2027")
        XCTAssertTrue(Holidays.lectureFree(day: BerlinClock.parseISODate("2027-01-04")!, university: "goettingen"))
        XCTAssertFalse(Holidays.lectureFree(day: BerlinClock.parseISODate("2027-01-11")!, university: "goettingen"))
        // alte LUH-Vorgabe in der Datenbank wird fuer Goettingen berichtigt
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.execute("CREATE TABLE terms(id INTEGER PRIMARY KEY, name TEXT, start TEXT, end TEXT, active INTEGER)")
        try c.execute("INSERT INTO terms(name, start, end, active) VALUES ('WiSe 2026/27', '2026-10-12', '2027-01-30', 1)")
        try Migrations.ensureTerm(c, university: "goettingen", today: "2026-11-26")
        XCTAssertEqual(try LocalTerms.current(c)["start"]?.string, "2026-10-26")
    }

    // MARK: Nachbildung (routes.json wie `DebugStubTransport` der App)

    static let base = URL(string: "https://studip.uni-goettingen.de")!

    static var stubDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }             // .../apps/apple
        return url.appendingPathComponent("DebugStub/goettingen", isDirectory: true)
    }

    /// Feste Antworten aus `routes.json`; zaehlt jede Anfrage (Adresse ohne Rechner)
    final class Stub: StudIPTransport, @unchecked Sendable {
        struct Route: Decodable {
            let match: String
            var status: Int?
            var file: String?
            var body: String?
            var contentType: String?
        }

        let directory: URL
        let routes: [Route]
        private let lock = NSLock()
        private var log: [String] = []

        init(directory: URL = GoettingenTests.stubDirectory) throws {
            self.directory = directory
            routes = try JSONDecoder().decode([Route].self, from: Data(contentsOf: directory.appendingPathComponent("routes.json")))
        }

        var calls: [String] { lock.withLock { log } }
        func count(_ part: String) -> Int { calls.filter { $0.contains(part) }.count }

        private func reply(_ url: URL) -> (Int, String, Data) {
            let address = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            lock.withLock { log.append(String(address.dropFirst(GoettingenTests.base.absoluteString.count + 1))) }
            guard let r = routes.first(where: { address.contains($0.match) }) else { return (404, "text/plain", Data("nicht im Stub".utf8)) }
            let body = r.file.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) } ?? Data((r.body ?? "").utf8)
            let type = r.contentType ?? (r.file?.hasSuffix(".json") == true ? "application/vnd.api+json"
                                         : r.file?.hasSuffix(".pdf") == true ? "application/pdf" : "text/html; charset=utf-8")
            return (r.status ?? 200, type, body)
        }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let (status, type, body) = reply(url)
            return HTTPReply(status: status, contentType: type, finalURL: url, body: body)
        }

        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            let (status, type, body) = reply(url)
            try body.write(to: file)
            return HTTPReply(status: status, contentType: type, finalURL: url)
        }
    }

    private func client(_ stub: Stub) -> StudIPClient {
        StudIPClient(base: Self.base, transport: stub, pauseMillis: 0, retry: UniRetry(attempts: 1))
    }

    private func json(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: Self.stubDirectory.appendingPathComponent(name)))
    }

    // MARK: Profil und Schalter

    func testProfile() {
        let g = UniversityProfile.goettingen
        XCTAssertEqual(UniversityKey(rawValue: "goettingen"), .goettingen)
        XCTAssertEqual(UniversityKey.goettingen.profile, g)
        XCTAssertTrue(UniversityProfile.all.contains(g))
        XCTAssertEqual([g.name, g.short, g.filesSource, g.gradesSource], ["Georg-August-Universität Göttingen", "Uni Göttingen", "Stud.IP", "FlexNow"])
        XCTAssertEqual(g.studipBase, Self.base)
        XCTAssertNil(g.casBase)
        XCTAssertNil(g.learnwebBase)
        XCTAssertNil(g.lsfBase)
        XCTAssertNil(g.gradeLayout, "FlexNow 2 ist nicht angebunden: die App liest dort keine Noten")
        XCTAssertFalse(g.qisDocuments)
        XCTAssertTrue(g.hasBulletinBoard, "dieselbe Erweiterung wie an der LUH")
        XCTAssertEqual(g.keychainPrefix, "goettingen")
        XCTAssertTrue(g.tokenServices.isEmpty)
        // eigener Schluesselbund-Bereich, kein Rueckfall auf eine andere Hochschule
        XCTAssertTrue(g.ownsKeychainAccount("goettingen.studip.token"))
        XCTAssertFalse(UniversityProfile.luh.ownsKeychainAccount("goettingen.studip.token"))
        XCTAssertTrue(UniversityProfile.isRetiredLoginSecret("u0123456789abcdef.goettingen.studip.password"))
        // Dienste: nur Stud.IP ist verbunden; FlexNow, eCampus und E-Mail sind Links ohne Anbindung
        XCTAssertEqual(g.services.map(\.key), ["studip", "flexnow", "ecampus", "mail", "sub", "mensa", "lageplan", "studit", "uni"])
        XCTAssertEqual(g.services.filter(\.connected).map(\.key), ["studip"])
        XCTAssertTrue(g.services.allSatisfy { !$0.connector && $0.url.hasPrefix("https://") })
        XCTAssertEqual(SOGoSite.for(.goettingen)?.isIMAP, true, "E-Mail liegt bei Exchange: Uni-Mail über IMAP/SMTP, kein SOGo (27.11.2026)")
        XCTAssertNil(ExamRegistrationPeriods.for(university: "goettingen"), "keine Meldezeiträume (FlexNow)")
        XCTAssertFalse(CertificatePortal.isOffered(.goettingen))
        XCTAssertTrue(CertificatePortal.isOffered(.luh) && CertificatePortal.isOffered(.hildesheim) && CertificatePortal.isOffered(.hsh))
        XCTAssertEqual(CertificatePortal.name(.goettingen), "eCampus")
    }

    /// Der Schalter: Goettingen steht im Code, im Store-Stand aber nicht zur Wahl
    func testNotShippedUntilReleased() {
        XCTAssertFalse(UFReleaseUniversities.storeDefault.contains(.goettingen))
        XCTAssertEqual(UFReleaseUniversities.parse("luh hildesheim"), [.luh, .hildesheim], "Release-Wert am 26.11.2026")
        XCTAssertEqual(UFReleaseUniversities.parse("luh hildesheim goettingen"), [.luh, .hildesheim, .goettingen])
        UFReleaseUniversities.withShipped([.luh, .hildesheim]) {
            XCTAssertFalse(UFReleaseUniversities.isShipped(.goettingen))
            XCTAssertEqual(UFReleaseUniversities.choices(), [.luh, .hildesheim])
            XCTAssertEqual(UFReleaseUniversities.choices(current: .goettingen), [.luh, .hildesheim, .goettingen], "schon gewählt: bleibt nutzbar")
            XCTAssertEqual(UFReleaseUniversities.filePlatforms, "Stud.IP bzw. Learnweb")
        }
        UFReleaseUniversities.withShipped([.luh, .goettingen]) {
            XCTAssertEqual(UFReleaseUniversities.filePlatforms, "Stud.IP", "beide Stud.IP: einmal genannt")
            XCTAssertEqual(UFReleaseUniversities.gradePlatforms, "QIS", "Göttingen hat keine Notenquelle in der App")
        }
    }

    // MARK: Anmeldung (eigenes Formular von Stud.IP)

    func testLoginForm() throws {
        let form = UniLoginForms.goettingenStudIP
        func u(_ s: String) -> URL { URL(string: s)! }
        XCTAssertEqual(UniLoginForms.forms(.goettingen), [form])
        XCTAssertEqual(UniLoginForms.hosts(.goettingen), ["studip.uni-goettingen.de"])
        XCTAssertEqual(UniLoginForms.form(for: u("https://studip.uni-goettingen.de/dispatch.php/login"), university: .goettingen), form)
        XCTAssertEqual(UniLoginForms.form(for: u("https://studip.uni-goettingen.de/dispatch.php/login?again=yes"), university: .goettingen), form)
        XCTAssertNil(UniLoginForms.form(for: u("https://studip.uni-goettingen.de/dispatch.php/start"), university: .goettingen), "angemeldete Seite")
        XCTAssertNil(UniLoginForms.form(for: u("http://studip.uni-goettingen.de/dispatch.php/login"), university: .goettingen), "nur HTTPS")
        XCTAssertNil(UniLoginForms.form(for: u("https://cas.uni-goettingen.de/cas/login"), university: .goettingen), "CAS füllt die App nie aus")
        XCTAssertNil(UniLoginForms.form(for: u("https://studip.uni-goettingen.de/dispatch.php/login"), university: .luh), "nie an einer anderen Hochschule")
        XCTAssertNil(UniLoginForms.form(for: u("https://studip.uni-hannover.de/dispatch.php/login"), university: .goettingen))
        XCTAssertTrue(UniLoginForms.allowsCapture(scheme: "https", host: "studip.uni-goettingen.de", port: 0, path: "/dispatch.php/login", university: .goettingen))
        XCTAssertFalse(UniLoginForms.allowsCapture(scheme: "https", host: "studip.uni-goettingen.de", port: 0, path: "/dispatch.php/start", university: .goettingen))
        let service = try XCTUnwrap(UniversityProfile.goettingen.loginService("studip"))
        XCTAssertEqual(service.entryURLs.map(\.absoluteString), ["https://studip.uni-goettingen.de/dispatch.php/login"])
        XCTAssertTrue(service.allows(u("https://studip.uni-goettingen.de/dispatch.php/login")))
        XCTAssertFalse(service.allows(u("https://studip.uni-goettingen.de/dispatch.php/my_courses")))

        // die Nachbildung traegt die Feldnamen der echten Seite (am 26.11.2026 ohne Anmeldung gelesen)
        let html = try String(contentsOf: Self.stubDirectory.appendingPathComponent("studip.html"), encoding: .utf8)
        XCTAssertTrue(form.appears(in: html))
        XCTAssertFalse(form.showsFailure(in: html))
        let scanned = try XCTUnwrap(UniFormScanner.forms(html).first)
        XCTAssertEqual(scanned.method, "post")
        XCTAssertEqual(scanned.fields.map(\.name), ["loginname", "password", "security_token", "login_ticket", "resolution"])
        XCTAssertEqual(scanned.submits.map(\.name), ["Login"])
        XCTAssertNotNil(UniFormLogin.loginForm([scanned], spec: form), "Benutzername und Passwort über die Selektoren gefunden")
        XCTAssertFalse(UniFormLogin.needsHuman(scanned, spec: form))

        // Ablauf der stillen Anmeldung: Formular einmal ausfüllen; kommt es mit Fehlermeldung wieder, ist das Passwort abgelehnt
        let login = u("https://studip.uni-goettingen.de/dispatch.php/login")
        let domains = ["uni-goettingen.de"]
        XCTAssertEqual(UniAutoLoginFlow.step(url: login, html: html, university: .goettingen, domains: domains, submitted: [], isDone: false), .fill(form))
        let rejected = html.replacingOccurrences(of: "<form", with: #"<div class="messagebox messagebox_error">Bei der Anmeldung trat ein Fehler auf!</div><form"#)
        XCTAssertEqual(UniAutoLoginFlow.step(url: login, html: rejected, university: .goettingen, domains: domains, submitted: [form.id], isDone: false), .rejected)
        XCTAssertEqual(UniAutoLoginFlow.step(url: login, html: html, university: .goettingen, domains: domains, submitted: [form.id], isDone: false), .giveUp,
                       "ohne Fehlertext kein Urteil über das Passwort")
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://studip.uni-goettingen.de/dispatch.php/start"), html: "<html></html>", university: .goettingen,
                                             domains: domains, submitted: [form.id], isDone: true), .done)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://sso.idm.uni-hannover.de/idp/x"), html: html, university: .goettingen, domains: domains,
                                             submitted: [], isDone: false), .abort, "nie auf den Rechnern einer anderen Hochschule")
        // ohne Webansicht (Hintergrund) ist das Formular bewusst nicht freigegeben: erst nach einem Test mit echtem Konto
        XCTAssertFalse(UniFormLogin.allowedForms.contains(form.id))
    }

    /// Abgelaufene Sitzung: Stud.IP leitet auf dispatch.php/login um bzw. antwortet der JSON:API mit 401
    func testExpiredSessionIsRecognised() async throws {
        final class Expired: StudIPTransport, @unchecked Sendable {
            let mode: Int
            init(_ mode: Int) { self.mode = mode }
            func get(_ url: URL, accept: String?) async throws -> HTTPReply {
                mode == 0 ? HTTPReply(status: 401, contentType: "text/html; charset=UTF-8", finalURL: url, body: Data())
                    : HTTPReply(status: 200, contentType: "text/html;charset=utf-8",
                                finalURL: URL(string: "https://studip.uni-goettingen.de/dispatch.php/login")!, body: Data("<html></html>".utf8))
            }
            func download(_ url: URL, to file: URL) async throws -> HTTPReply { try await get(url, accept: nil) }
        }
        for mode in 0...1 {
            let c = StudIPClient(base: Self.base, transport: Expired(mode), pauseMillis: 0)
            do {
                _ = try await c.currentUserID()
                XCTFail("Modus \(mode)")
            } catch {
                XCTAssertEqual(error as? StudIPError, .sessionExpired, "Modus \(mode)")
            }
        }
    }

    // MARK: Abgleich gegen die Nachbildung

    func testCoursesScheduleAndFiles() async throws {
        let stub = try Stub()
        let c = client(stub)
        let me = try await c.currentUserID()
        XCTAssertEqual(me, try json("me.json")["data"]?["id"]?.string)
        let courses = try await c.courses(userID: me)
        XCTAssertEqual(courses.count, 6)
        let mathe = try XCTUnwrap(courses.first { $0.title == "Mathematik für Wirtschaftswissenschaftler" })
        XCTAssertEqual(mathe.number, "700011")
        XCTAssertEqual(mathe.semesterTitle, "WiSe 2026/27")
        XCTAssertEqual(mathe.semesterEnd, "WiSe 2026/27")
        XCTAssertEqual(mathe.courseType, 111)
        // ein Kurs ohne Beziehung end-semester (so gesehen): Ende unbekannt, kein Fehler
        let forum = try XCTUnwrap(courses.first { $0.title.hasPrefix("Erstsemester-Forum") })
        XCTAssertNil(forum.semesterEnd)
        XCTAssertNil(forum.number)
        // Dateien samt Unterordner; Download der ganzen Datei (kein Teilabruf: der Transport kennt gar keine Kopfzeilen)
        let ue = try XCTUnwrap(courses.first { $0.title.hasPrefix("Übung zu") })
        let listing = try await c.fileListing(courseID: ue.id)
        XCTAssertEqual(listing.files.map(\.name), ["Uebungsblatt_01.pdf"])
        XCTAssertEqual(listing.unreadableFolders, 0)
        let file = try XCTUnwrap(listing.files.first)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("goe-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        try await c.download(fileID: file.id, to: target, name: file.name)
        let data = try Data(contentsOf: target)
        XCTAssertEqual(data.count, file.size, "ganze Datei")
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(stub.count("/content"), 1, "ein Abruf, keine Teile")
        // eigener Kalender (events.ics)
        let ics = try await c.calendarICS(userID: me)
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR"))
        XCTAssertFalse(StudIPCalendar.dateIDs(ics: ics).isEmpty)
    }

    /// Nummern der Veranstaltungsarten: in Goettingen ist 4 "Seminar" (Stud.IP-Standard: Praktikum), 21 "Übung"
    func testCourseTypes() {
        let g = StudIPSchedule.courseTypes(university: "goettingen")
        XCTAssertEqual(g[4], .seminar)
        XCTAssertEqual(g[21], .uebung)
        XCTAssertEqual(g[26], .tutorium)
        XCTAssertEqual(g[16], .labor)
        XCTAssertEqual(g[134], .hoersaaluebung)
        XCTAssertNil(g[1], "Vorlesung braucht keinen Eintrag")
        XCTAssertNil(g[111], "„Vorlesung mit Übung“ bleibt Vorlesung")
        XCTAssertNil(g[2], "in Göttingen „Grundstudium“, nicht Seminar")
        XCTAssertNil(g[3], "in Göttingen „Hauptstudium“, nicht Übung")
        XCTAssertEqual(StudIPSchedule.courseTypes(university: "luh"), StudIPSchedule.standardCourseTypes)
        XCTAssertEqual(StudIPSchedule.courseTypes(university: nil), StudIPSchedule.standardCourseTypes)
        // Art eines Kurses ohne Hinweis im Titel: aus der Nummer der Hochschule
        XCTAssertEqual(StudIPSchedule.art(title: "Unternehmensführung", courseType: 4, courseTypes: g), .seminar)
        XCTAssertEqual(StudIPSchedule.art(title: "Unternehmensführung", courseType: 4), .labor, "Standard: darum die eigene Tabelle")
        XCTAssertEqual(StudIPSchedule.art(title: "Mathematik", courseType: 111, courseTypes: g), .vorlesung)
        XCTAssertTrue(StudIPStudyGroups.isStudyGroup(StudIPCourse(id: "x", title: "Lerngruppe", courseType: 99)), "99 ist auch dort die Studiengruppe")
    }

    /// Ergaenzungen: was dort nicht geht, stoert nicht - 404 wird 30 Tage gemerkt, ein Serverfehler bis zum naechsten Tag
    func testExtrasToleratesMissingAndFailingEndpoints() async throws {
        let stub = try Stub()
        let c = client(stub)
        let me = try await c.currentUserID()
        let day = BerlinClock.parseISODate("2026-11-26") ?? 0
        let first = await StudIPExtras.fetch(client: c, userID: me, missing: [:], today: day, failing: [:])
        XCTAssertFalse(first.sessionExpired)
        XCTAssertEqual(first.semesters?.count, 2)
        XCTAssertEqual(first.messages?.count, 2)
        XCTAssertEqual(first.activity?.count, 1)
        XCTAssertNil(first.globalNews, "studip/news antwortet dort mit 500: nichts gelesen, der Bestand bleibt")
        XCTAssertNil(first.bookings, "Sprechstunden gibt es dort nicht")
        XCTAssertEqual(first.missing, ["consultations": "2026-11-26"])
        XCTAssertEqual(first.failing, ["studip-news": "2026-11-26"])
        XCTAssertEqual(stub.count("studip/news"), 1)
        XCTAssertEqual(stub.count("consultation-bookings"), 1, "404 ist kein 400: kein zweiter Pfad")
        // zweiter Abgleich am selben Tag: beide Endpunkte werden nicht noch einmal gefragt
        let second = await StudIPExtras.fetch(client: c, userID: me, missing: first.missing, today: day, failing: first.failing)
        XCTAssertEqual(stub.count("studip/news"), 1)
        XCTAssertEqual(stub.count("consultation-bookings"), 1)
        XCTAssertEqual(second.messages?.count, 2)
        // am naechsten Tag fragt er den Serverfehler wieder (einmal), die 404 weiter nicht
        _ = await StudIPExtras.fetch(client: c, userID: me, missing: second.missing, today: day + 1, failing: second.failing ?? [:])
        XCTAssertEqual(stub.count("studip/news"), 2)
        XCTAssertEqual(stub.count("consultation-bookings"), 1)
        // Regeln des Merkers
        XCTAssertTrue(StudIPExtras.failedToday(["x": "2026-11-26"], "x", today: "2026-11-26"))
        XCTAssertFalse(StudIPExtras.failedToday(["x": "2026-11-25"], "x", today: "2026-11-26"))
        XCTAssertEqual(StudIPExtras.rememberFailure(["x": "2026-11-25"], "x", status: 200, today: "2026-11-26"), [:])
        XCTAssertEqual(StudIPExtras.rememberFailure([:], "x", status: 503, today: "2026-11-26"), ["x": "2026-11-26"])
        XCTAssertEqual(StudIPExtras.rememberFailure(["x": "2026-11-25"], "x", status: 404, today: "2026-11-26"), [:], "404 steht in `missing`")
        // ohne `failing` (aeltere Aufrufer): wie bisher, nichts wird gemerkt
        let plain = await StudIPExtras.fetch(client: client(try Stub()), userID: me, missing: [:], today: day)
        XCTAssertNil(plain.failing)
    }

    /// Schwarzes Brett: dieselbe Erweiterung wie an der LUH (Themenliste `sb-categories`, RSS je Thema)
    func testBulletinBoard() async throws {
        let stub = try Stub()
        let d = await StudIPBulletin.fetch(client: client(stub), missing: [:], lastFetchedAt: nil, clock: .fixed(berlin: "2026-11-26T12:00:00")!)
        XCTAssertFalse(d.sessionExpired)
        XCTAssertFalse(d.feedUnavailable)
        XCTAssertEqual(d.topics.map(\.title), ["Biete", "Suche", "Wohnen & Zimmer"])
        XCTAssertEqual(d.topics.map(\.count), [2, 1, 1])
        XCTAssertEqual(d.entries?.count, 4)
        let first = try XCTUnwrap(d.entries?.first)
        XCTAssertEqual(first.topic, "Biete")
        XCTAssertEqual(first.title, "Lehrbuch Mathematik für Wirtschaftswissenschaftler")
        XCTAssertEqual(first.text, "Gut erhalten, 12 Euro. Abholung am Zentralcampus.")
        XCTAssertTrue(first.url.hasPrefix("https://studip.uni-goettingen.de/plugins.php/schwarzesbrettplugin/article/view/"))
        XCTAssertEqual(first.postedAt, "2026-11-24T10:10:00")
        XCTAssertNil(d.missing[StudIPBulletin.missingName])
        XCTAssertEqual(StudIPBulletin.boardURL(base: Self.base.absoluteString), "https://studip.uni-goettingen.de/plugins.php/schwarzesbrettplugin/category/list")
    }

    /// Aufzeichnungen: die Erweiterung der LUH (dort 403) wird gar nicht gefragt; der Kursueberblick ohne Reiter
    /// "Aufzeichnungen" heisst "keine" - kein Fehler, auch nicht mit dem Reiter "Medien" (Mediacast)
    func testRecordingsWithoutErrors() async throws {
        XCTAssertFalse(OpencastParser.hasLUHPlugin(Self.base))
        XCTAssertTrue(OpencastParser.hasLUHPlugin(URL(string: "https://studip.uni-hannover.de")!))
        XCTAssertTrue(OpencastParser.hasLUHPlugin(URL(string: "https://studip.example.org")!), "unbekannter Rechner (Tests) wie bisher")
        let stub = try Stub()
        let c = client(stub)
        let courses = try await c.courses(userID: try await c.currentUserID())
        let fetched = await OpencastStore.fetch(client: c, courses: courses, known: [:], now: 1_795_000_000, width: 4)
        XCTAssertTrue(fetched.failed.isEmpty, "kein „Aufzeichnungen von N Kursen nicht lesbar“")
        XCTAssertFalse(fetched.sessionExpired)
        XCTAssertFalse(fetched.unreachable)
        XCTAssertEqual(fetched.listings.count, courses.count)
        XCTAssertTrue(fetched.listings.values.allSatisfy { $0 == .noOpencast })
        XCTAssertEqual(stub.count("opencastpluginluh"), 0, "die Erweiterung der LUH wird dort nicht gefragt")
        XCTAssertEqual(stub.count("dispatch.php/course/overview"), courses.count, "eine Anfrage je Kurs")
    }

    /// Lernstoff: Courseware-Fristen (400/404) und Wiki (404) fehlen dort; der Lauf endet ohne Fehler
    func testTextsWithoutErrors() async throws {
        let stub = try Stub()
        let c = client(stub)
        let courses = Array(try await c.courses(userID: try await c.currentUserID()).prefix(4))
        let d = try await StudIPTexts.fetch(client: c, courses: courses, known: [:], state: [:], today: "2026-11-26",
                                            base: Self.base.absoluteString)
        XCTAssertFalse(d.stopped)
        XCTAssertEqual(d.courses.count, courses.count)
        XCTAssertTrue(d.courses.allSatisfy { $0.rows.isEmpty }, "nichts gelesen, nichts erfunden")
        // als fehlend gemerkt, auch fuer die ganze Hochschule (mehrere Kurse, keiner mit Erfolg): der naechste Lauf fragt
        // Wiki und Courseware-Fristen dort nicht wieder
        XCTAssertNotNil(d.stateSet["absent|wiki"], "\(d.stateSet.keys.sorted())")
        XCTAssertNotNil(d.stateSet["absent|tasks"], "\(d.stateSet.keys.sorted())")
        let again = try await StudIPTexts.fetch(client: c, courses: courses, known: [:], state: d.stateSet, today: "2026-11-27",
                                                base: Self.base.absoluteString)
        XCTAssertFalse(again.stopped)
        let before = stub.count("wiki-pages")
        XCTAssertEqual(before, courses.count, "am zweiten Tag keine Wiki-Anfrage mehr")
    }

    // MARK: Raeume

    /// Lehrende kommen wie an der LUH aus Stud.IP (Rundgang 26.11.2026: Seite sagte "vorerst nur LUH")
    func testLecturersFromStudIP() async throws {
        XCTAssertTrue(StudIPLecturers.offered("goettingen"))
        XCTAssertTrue(TerminDetail.showsLecturers(university: "goettingen"))
        XCTAssertFalse(StudIPLecturers.offered("hildesheim"))
        XCTAssertFalse(StudIPLecturers.offered("hsh"))
        let stub = try Stub()
        let c = client(stub)
        let courses = try await c.courses(userID: try await c.currentUserID())
        let math = try XCTUnwrap(courses.first { $0.title == "Mathematik für Wirtschaftswissenschaftler" })
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-26T10:00:00"))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { conn in
            for k in courses {
                try conn.execute("INSERT INTO courses(id, title, active, created_at) VALUES (?,?,1,'t')", [.text(k.id), .text(k.title)])
            }
        }
        let d = await StudIPLecturers.run(client: c, database: backend.context.database, courseIDs: courses.map(\.id), clock: clock,
                                          university: "goettingen")
        XCTAssertFalse(d.sessionExpired)
        XCTAssertGreaterThan(stub.count("memberships?filter[permission]=dozent"), 0)
        let v = try await backend.context.database.withConnection {
            try StudIPLecturers.overview($0, university: "goettingen", base: Self.base.absoluteString, courseID: math.id)
        }
        XCTAssertEqual(v["available"]?.bool, true)
        let people = v["people"]?.array ?? []
        XCTAssertEqual(people.first?["name"]?.string, "Prof. Dr. Beispiel Dozentin")
        XCTAssertEqual(people.first?["email"]?.string, "beispiel.dozentin@example.org")
    }

    func testRoomNamesAsSeenInStudIP() {
        func campus(_ text: String) -> String? { Rooms.parse(text, university: "goettingen")["parts"]?.array?.first?["campus"]?.string }
        XCTAssertEqual(Rooms.knownUniversity("goettingen"), "goettingen", "nie die Regeln der LUH")
        XCTAssertEqual(campus("ZHG010 (ZHG)"), "zentralcampus")
        XCTAssertEqual(campus("E-Prüfungsraum MZG 1.116 (MZG/Blauer Turm)"), "zentralcampus")
        XCTAssertEqual(campus("Kursraum Waldweg 26"), "waldweg")
        XCTAssertNil(campus("Hörsaal 3"))
        let parsed = Rooms.parse("ZHG010 (ZHG)", university: "goettingen")
        XCTAssertEqual(parsed["university"], "goettingen")
        XCTAssertEqual(parsed["parts"]?.array?.first?["room"], .null, "keine Gebäudenummern der LUH hineingelesen")
        XCTAssertEqual(Rooms.campuses(university: "goettingen")["finder"], false)
        XCTAssertEqual(Rooms.campuses(university: "goettingen")["campuses"]?.array?.count, 3)
    }
}

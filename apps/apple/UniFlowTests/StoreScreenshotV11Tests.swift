import PencilKit
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// App-Store-Bildschirmfotos fuer Version 1.0 (Build 11) in der Fassung **nur mit Plus** (Pro AI wird nicht mit
/// eingereicht): zehn Motive ohne KI (keine KI-Hilfe, kein KI-Dokument, kein Wochentest, kein "Pro AI holen"), dafuer
/// mit den neuen Funktionen Uni-Mail, Termin-Detail mit Lehrenden, Raumfinder, geteilte Ansicht und Bescheinigungen.
/// Reihenfolge, Dateinamen und Bildunterschriften: docs/release/SCREENSHOTS.md (Abschnitt "Satz Build 11").
///
/// iPad Pro 13" wie `StoreScreenshotTests` (Fenster 1032 x 1376 Punkte bei Massstab 2 = 2064 x 2752 Pixel, quer
/// 2752 x 2064), je Motiv hell und dunkel, hoch und quer. Mit UF_SCREENSHOT_DIR (xcodebuild:
/// TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test die PNGs dorthin; ohne prueft er nur, dass jede Ansicht mit den
/// erfundenen Inhalten erscheint.
///
/// Alles erfunden, nichts geht ins Netz: Demo-Inhalte (`DemoContent`) mit den Zusaetzen der Store-Bilder, Rufname
/// "Tobi"; Uni-Mail aus einer Nachbildung von SOGo im Speicher (`DemoSOGo`: Posteingang mit acht erfundenen Mails,
/// Adressen unter example.org); zwei erfundene Lehrende am Demo-Kurs; Bescheinigungen als gespeicherte Liste des QIS
/// (erfundene Kopie mit Datum); Raumfinder und Mensa aus den Testdaten des lokalen Backends (`RoomFinderDemoHTTP`,
/// `MensaDemoHTTP`). Uni-Mail mit Demo-Inhalten und der feste Tag der Mensa gibt es nur im Debug-Build
/// (`UniMailConnection.readsDemoForScreenshots`, `UFFmt.todayOverride`); die App setzt sie nie.
@MainActor
final class StoreScreenshotV11Tests: XCTestCase {

    private static let portrait = CGSize(width: 1032, height: 1376)
    private static let landscape = CGSize(width: 1376, height: 1032)
    static let demoName = "Tobi"
    /// erfundenes Uni-Postfach (SOGo-Konto)
    static let mailUser = "tobi.muster@stud.example.org"

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var uniMail: UniMailConnection!
    private var outDir: URL?
    /// Kennung der Demo-Vorlesung am Donnerstag (Termin-Detail)
    private var lectureID = 0

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots11", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        UniMailConnection.readsDemoForScreenshots = true
        let sogo = DemoSOGo()                                                      // eine Nachbildung je Test (merkt gelesene Mails)
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true,
            uniMailTransport: { _ in sogo })
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        try await StoreScreenshotTests.installStoreExtras(container.host)
        lectureID = try await Self.installV11Extras(container, now: bed.clock.nowISO)
        Rufname.write(Self.demoName, container.defaults)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        // Uni-Mail verbunden (erfundene Cookies), Posteingang einmal gelesen: Menuepunkt mit Zahl der ungelesenen
        uniMail = try XCTUnwrap(manager.uniMail, "LUH hat Uni-Mail")
        uniMail.refreshesAfterSignIn = false
        let store = uniMail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: SOGoSite.luh.host, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "erfunden", domain: SOGoSite.luh.host, path: "/SOGo"))
        uniMail.signedIn(user: Self.mailUser)
        let report = await uniMail.refreshInbox()
        XCTAssertEqual(report.unseen, 2, "Posteingang der Nachbildung gelesen: \(report)")
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UniMailConnection.readsDemoForScreenshots = false
        UFFmt.todayOverride = nil
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Erfundene Zusaetze (nur diese Bilder)

    /// Lehrende des Demo-Kurses (wie nach dem Stud.IP-Abgleich gespeichert) und die Liste der Bescheinigungen mit einer
    /// gespeicherten Kopie; alles erfunden, Adressen unter example.org. Rueckgabe: Kennung der Demo-Vorlesung am
    /// Donnerstag (Termin-Detail); auch fuer `StoreScreenshotFinalTests`
    static func installV11Extras(_ container: ActiveContainer, now: String) async throws -> Int {
        let backend = try await container.host.backend()
        let today = String(now.prefix(10))
        try await backend.context.database.transaction { c in
            try c.execute("""
                CREATE TABLE IF NOT EXISTS studip_lecturers (course_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL,
                position INTEGER, label TEXT, name TEXT, username TEXT, email TEXT, office_hours TEXT, location TEXT, institute TEXT,
                fetched_at TEXT, PRIMARY KEY (course_id, user_id))
                """)
            try c.execute("CREATE TABLE IF NOT EXISTS studip_lecturer_courses (course_id TEXT PRIMARY KEY, fetched_at TEXT NOT NULL)")
            let people: [(String, String, Int, String, String, String, String)] = [
                ("u-demo-a", "dozent", 0, "Prof. Dr. Anna Beispiel", "abeispiel", "anna.beispiel@example.org", "Di 10–11 Uhr"),
                ("u-demo-b", "dozent", 1, "Dr. Jonas Muster", "jmuster", "jonas.muster@example.org", "Do 14–15 Uhr"),
                ("u-demo-t", "tutor", 2, "Lena Probe", "lprobe", "lena.probe@example.org", ""),
            ]
            for p in people {
                try c.execute("""
                    INSERT OR REPLACE INTO studip_lecturers(course_id, user_id, role, position, label, name, username, email, office_hours,
                    location, institute, fetched_at) VALUES ('demo-vorlesung', ?, ?, ?, '', ?, ?, ?, ?, '', '', ?)
                    """, [.text(p.0), .text(p.1), .integer(Int64(p.2)), .text(p.3), .text(p.4), .text(p.5), .text(p.6), .text(now)])
            }
            try c.execute("INSERT OR REPLACE INTO studip_lecturer_courses(course_id, fetched_at) VALUES ('demo-vorlesung', ?)", [.text(now)])
        }
        // Bescheinigungen: Liste von heute, die Immatrikulationsbescheinigung als Kopie mit Datum (erfundene PDF)
        let rel = ((backend.context.files?.dataDirectory).map { $0.isEmpty ? "" : $0 + "/" } ?? "") + "qis/Bescheinigung-demo-imma.pdf"
        let pdf = DemoContent.pdf([DemoContent.Page("Immatrikulationsbescheinigung", ["Erfundenes Muster für die Store-Bilder.", "Tobi Muster, Informatik B.Sc."])])
        _ = try backend.context.files?.write(pdf, to: rel)
        func offer(_ id: String, _ title: String, _ kind: String, _ kinds: [String], _ semester: String?) -> JSONValue {
            ["id": .string(id), "title": .string(title), "kind": .string(kind), "kinds": .array(kinds.map(JSONValue.string)),
             "semester": semester.map(JSONValue.string) ?? .null, "semesters": [], "source": "bescheinigungen", "portal": "qis",
             "address": .null, "confirmed": true]
        }
        let state: JSONValue = [
            "university": "luh", "checked_at": .string(today + "T09:10:00"), "status": "ok", "message": "4 Dokumente im Portal",
            "offers": [offer("demo-imma", "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG", "immatrikulation",
                             ["immatrikulation", "bafoeg"], "WiSe 2026/27"),
                       offer("demo-enrol", "Enrolment Certificate (englisch)", "immatrikulation", ["immatrikulation"], "WiSe 2026/27"),
                       offer("demo-noten", "Notenspiegel (alle Leistungen) deutsch", "notenspiegel", ["notenspiegel"], nil),
                       offer("demo-noten-en", "Transcript of Records (englisch)", "notenspiegel", ["notenspiegel"], nil)],
            "files": ["demo-imma": ["path": .string(rel), "fetched_at": .string(today + "T09:12:00"), "size": .number(Double(pdf.count)),
                                    "semester": "WiSe 2026/27"]],
        ]
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                          [.text(CertificatesSync.settingsKey), .text(state.jsonString())])
        }
        let lectureID = try await backend.context.database.withConnection { c in
            try c.rows("SELECT id FROM course_events WHERE course_id='demo-vorlesung' AND weekday=3").first?["id"]?.int ?? 0
        }
        XCTAssertGreaterThan(lectureID, 0, "Demo-Vorlesung am Donnerstag")
        return lectureID
    }

    // MARK: - Uni-Mail (SOGo nachgebaut, erfunden)

    /// SOGo der LUH im Speicher: Ordner, Posteingang (acht erfundene Mails), eine Mail einer erfundenen Dozentin;
    /// Markieren beantwortet es leer, alles andere 404. Nichts verlaesst den Prozess, gesendet wird nichts.
    final class DemoSOGo: UniTransport, @unchecked Sendable {
        /// gelesene Mails (Lesen markiert wie SOGo als gelesen)
        private let lock = NSLock()
        private var opened: Set<Int> = []

        static let me: JSONValue = [["name": "Tobi Muster", "email": .string(StoreScreenshotV11Tests.mailUser)]]

        /// uid, Absender, Adresse, Betreff, Datum der Liste, gelesen, Anhang
        static let inbox: [(uid: Int, name: String, email: String, subject: String, date: String, read: Bool, attachment: Bool)] = [
            (212, "Prof. Dr. Anna Beispiel", "anna.beispiel@example.org", "Klausur Grundlagen der Informatik: Termin und Probeklausur", "09:24", false, true),
            (211, "Tutorium Grundlagen der Informatik", "tutorium-gdi@example.org", "Übungsblatt 2 ist online", "08:10", false, false),
            (210, "Dr. Jonas Muster", "jonas.muster@example.org", "Re: Frage zu Aufgabe 3 (Zweierkomplement)", "Gestern", true, false),
            (209, "Studierendensekretariat", "sekretariat@example.org", "Rückmeldung zum Sommersemester 2027", "Gestern", true, false),
            (208, "Prüfungsamt", "pruefungsamt@example.org", "Prüfungsanmeldung WiSe 26/27: 09.–22.11.", "05.11.2026", true, false),
            (207, "Bibliothek", "bibliothek@example.org", "Leihfrist endet in 3 Tagen", "04.11.2026", true, false),
            (206, "Fachschaft Informatik", "fachschaft@example.org", "Einladung: Spieleabend am Freitag", "03.11.2026", true, false),
            (205, "Hochschulsport", "hochschulsport@example.org", "Kurse im Wintersemester: Anmeldung offen", "02.11.2026", true, true),
        ]

        static func folder(opened: Set<Int>) -> JSONValue {
            let names: JSONValue = ["To", "hasAttachment", "isFlagged", "Subject", "From", "isRead", "Priority", "RelativeDate", "Size", "Flags",
                                    "uid", "isAnswered", "isForwarded"]
            let rows: [JSONValue] = inbox.map { m in
                [me, .number(m.attachment ? 1 : 0), 0, .string(m.subject), [["name": .string(m.name), "email": .string(m.email)]],
                 .number(m.read || opened.contains(m.uid) ? 1 : 0), ["level": 3, "name": "normal"], .string(m.date), .string(m.attachment ? "184 KB" : "6 KB"), [],
                 .number(Double(m.uid)), .number(m.uid == 210 ? 1 : 0), 0]
            }
            let unseen = inbox.filter { !$0.read && !opened.contains($0.uid) }.count
            return ["uids": .array(inbox.map { .number(Double($0.uid)) }), "headers": .array([names] + rows), "unseenCount": .number(Double(unseen))]
        }

        static let mailboxes: JSONValue = ["mailboxes": [
            ["name": "INBOX", "path": "INBOX", "type": "inbox", "flags": [], "children": []],
            ["name": "Drafts", "path": "Drafts", "type": "draft", "flags": [], "children": []],
            ["name": "Sent", "path": "Sent", "type": "sent", "flags": [], "children": []],
            ["name": "Trash", "path": "Trash", "type": "trash", "flags": [], "children": []],
        ]]

        /// Text der geoeffneten Mail (erfunden)
        static let body = """
            <p>Liebe Studierende,</p>
            <p>die Klausur zu <b>Grundlagen der Informatik</b> schreiben wir am 16.&nbsp;Februar 2027 um 10&nbsp;Uhr \
            im Hörsaal&nbsp;A. Anmeldung im QIS: 9.–22.&nbsp;November.</p>
            <p>Im Anhang finden Sie eine Probeklausur. Fragen gern in meiner Sprechstunde (Di 10–11&nbsp;Uhr).</p>
            <p>Viele Grüße<br>Anna Beispiel</p>
            """

        static func message(_ uid: Int) -> JSONValue {
            let m = inbox.first { $0.uid == uid } ?? inbox[0]
            let base = "/SOGo/so/\(StoreScreenshotV11Tests.mailUser)/Mail/0/folderINBOX/\(uid)"
            var parts: [JSONValue] = [["type": "UIxMailPartHTMLViewer", "contentType": "text/html",
                                       "content": .string(uid == 212 ? body : "<p>\(m.subject)</p>")]]
            if m.attachment {
                parts.append(["type": "UIxMailPartLinkViewer", "contentType": "application/pdf", "filename": "Probeklausur_GdI.pdf",
                              "size": "184 KB", "downloadURL": .string(base + "/2/asAttachment/Probeklausur_GdI.pdf")])
            }
            return ["subject": .string(m.subject), "date": .string(uid == 212 ? "Heute, 09:24" : m.date), "isRead": 1, "isDraft": false,
                    "from": [["name": .string(m.name), "email": .string(m.email)]], "to": me,
                    "parts": ["type": "UIxMailPartMixedViewer", "contentType": "multipart/mixed", "content": .array(parts)]]
        }

        func send(_ request: UniRequest) async throws -> UniResponse {
            let path = request.url.path
            func json(_ v: JSONValue, _ status: Int = 200) -> UniResponse {
                UniResponse(status: status, headers: ["Content-Type": "application/json"], finalURL: request.url, body: v.serialized())
            }
            if path.hasSuffix("/Mail/0/view") { return json(Self.mailboxes) }
            let seen = lock.withLock { opened }
            if path.hasSuffix("/folderINBOX/view") { return json(Self.folder(opened: seen)) }
            if path.hasSuffix("/Mail/unseenCount") {
                return json(["0/folderINBOX": .number(Double(Self.inbox.filter { !$0.read && !seen.contains($0.uid) }.count))])
            }
            if path.hasSuffix("/view"), let uid = Int(path.components(separatedBy: "/").dropLast().last ?? "") {
                _ = lock.withLock { opened.insert(uid) }
                return json(Self.message(uid))
            }
            if ["/markMessageRead", "/markMessageUnread", "/markMessageFlagged"].contains(where: path.hasSuffix) { return json([:]) }
            return json([:], 404)
        }

        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
            UniResponse(status: 404, finalURL: request.url)
        }
    }

    // MARK: - Hosten, Warten, Fotografieren

    /// Die ganze App-Huelle mit Demo-Inhalten, Uni-Mail und Plus, ohne Demo-Leiste und ohne "Pro AI holen"
    private func host<V: View>(_ view: V) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufProAIOfferHidden, true)
            .environment(\.ufAIEnabled, false)
            .environment(\.uniMail, uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: container.api, size: Self.portrait, studip: manager.studip)
    }

    /// Hell und dunkel, hoch und quer; `present`: Blatt ueber der Seite (nach den Seiten ohne Blatt geoeffnet)
    private func shoot(_ env: HostedEnvironment, _ name: String, ink: Bool = false, settle: Double = 1.0,
                       sizes: [(CGSize, String)]? = nil, present: (() -> Void)? = nil, sheetReady: @escaping () -> Bool = { true }) {
        // ohne Ordner nur pruefen; KI darf in keinem Bild stehen
        for word in ["KI-Hilfe", "Pro AI", "Wochentest", "KI-Dokument"] {
            XCTAssertFalse(shows(env, word), "\(name): „\(word)“ im Bild")
        }
        guard let outDir else { return }
        StoreScreenshotTests.shoot(env, name, folder: outDir, sizes: sizes ?? [(Self.portrait, "portrait"), (Self.landscape, "landscape")],
                                   scale: 2, ink: ink, settle: settle, present: present, sheetReady: sheetReady)
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

    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(in: env.window).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: "\n") }

    @discardableResult
    private func tap(_ label: String, in env: HostedEnvironment, exact: Bool = true) -> Bool {
        for e in elements(in: env.window) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.hasPrefix(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    /// Eine asynchrone Arbeit ausfuehren und dabei die Hauptschleife laufen lassen (die Tests bleiben synchron wie
    /// `StoreScreenshotTests`, sonst stehen die `.task`-Ladevorgaenge der Ansichten)
    private func pumping(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> Void) {
        var done = false
        var failure: String?
        Task { @MainActor in
            do { try await body() } catch { failure = "\(error)" }
            done = true
        }
        let end = Date().addingTimeInterval(timeout)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done, "nicht fertig")
        XCTAssertNil(failure, failure ?? "")
    }

    /// Wartet, bis `count` Zeichenflaechen Striche zeigen, dann Zeit fuer die PDF-Kacheln
    private func waitForInk(_ env: HostedEnvironment, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { StoreScreenshotTests.canvases(in: env.view).filter { !$0.drawing.strokes.isEmpty }.count >= count }
        XCTAssertTrue(ok, "Editor zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    /// ISO-Tag in Berlin
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Montag der laufenden Woche plus `weekday` (0 = Montag) als ISO-Tag
    static func dayThisWeek(_ weekday: Int, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let today = (cal.component(.weekday, from: now) + 5) % 7             // 0 = Montag
        return isoDay(cal.date(byAdding: .day, value: weekday - today, to: now) ?? now)
    }

    /// Heute, am Wochenende der naechste Montag (Mensa hat dann einen Speiseplan)
    static func nextServiceDay(now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let wd = (cal.component(.weekday, from: now) + 5) % 7
        return isoDay(cal.date(byAdding: .day, value: wd >= 5 ? 7 - wd : 0, to: now) ?? now)
    }

    // MARK: - Satz Build 11 (01-10)

    /// 1 Uebersicht: Begruessung, Pruefungsanmeldung, Lernpaket fuer heute
    func test01Uebersicht() throws {
        let env = try host(MainView())
        expect(env, Self.demoName + " – lass uns gemeinsam lernen.")
        expect(env, "Grundlagen der Informatik")
        expect(env, "Uni-Mail")                                                   // Menuepunkt (verbunden)
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "ohne Demo-Leiste")
        XCTAssertFalse(shows(env, "Pro AI holen"), "Fassung nur mit Plus")
        if outDir != nil { expect(env, "Prüfungsanmeldung") }                     // nur im Meldezeitraum (Bilder: 09.–22.11.2026)
        env.pump(1.0)
        shoot(env, "01-uebersicht")
    }

    /// 2 Uni-Mail: Posteingang (acht erfundene Mails) und die Mail einer erfundenen Dozentin mit Anhang
    func test02UniMail() throws {
        let env = try host(MainView())
        env.router.go(.uniMail)
        expect(env, "8 E-Mails")
        env.pump(1.5)                                                              // Liste frisch gelesen (nach dem Zwischenspeicher)
        XCTAssertTrue(tap("Ungelesen, Prof. Dr. Anna Beispiel", in: env, exact: false), dump(env))
        expect(env, "Anhang Probeklausur_GdI.pdf öffnen oder teilen")
        expect(env, "Antworten")
        env.pump(2.5)                                                              // HTML der Mail (WKWebView)
        shoot(env, "02-uni-mail", settle: 2.0)
    }

    /// 3 Stundenplan mit Termin-Detail: Raum mit Route zu Fuss, zwei erfundene Lehrende mit E-Mail und Sprechstunde
    func test03StundenplanTermin() throws {
        let env = try host(MainView())
        env.router.go(.timetable())
        expect(env, "Stundenplan")
        env.pump(1.0)
        env.overlay.openDrawer { EventDrawer(eventID: self.lectureID, date: Self.dayThisWeek(3)) }
        expect(env, "Prof. Dr. Anna Beispiel")
        expect(env, "E-Mail an jonas.muster@example.org")
        expect(env, TerminDetailText.routeLabel("Hörsaal A"))
        expect(env, TerminDetailText.writeAll)
        env.pump(1.0)
        shoot(env, "03-stundenplan-termin")
    }

    /// 4 Raumfinder: Suche "F102", Treffer, darueber das Detail mit Google Maps, Route und Apple Karten
    func test04Raumfinder() throws {
        let env = try host(MainView())
        env.router.go(.rooms)
        expect(env, "Raumfinder")
        _ = env.wait { self.tap("F102", in: env) }
        expect(env, "1 Treffer")
        env.pump(1.0)
        shoot(env, "04-raumfinder", present: { XCTAssertTrue(self.tap("Raum F102", in: env, exact: false), self.dump(env)) },
              sheetReady: { self.shows(env, "In Google Maps öffnen") && self.shows(env, "Route zu Fuß in Google Maps") })
        if outDir == nil {
            XCTAssertTrue(tap("Raum F102", in: env, exact: false), dump(env))
            expect(env, "In Google Maps öffnen")
        }
    }

    /// 5 Geteilte Ansicht (Plus): Uebungsblatt mit Handschrift, daneben das Skript mit Handschrift. Hoch und quer je
    /// ein eigenes Fenster, das schon in seiner Groesse oeffnet (sonst stuende quer die Mitte der Seiten oben)
    func test05Geteilt() throws {
        StoreScreenshotTests.seedNotesPumping("demo-blatt", api: container.api)
        StoreScreenshotTests.seedNotesPumping("demo-skript", api: container.api)
        for (size, orientation) in [(Self.portrait, "portrait"), (Self.landscape, "landscape")] {
            let env = try openSplit(size: size)
            shoot(env, "05-geteilt", ink: true, settle: 1.5, sizes: [(size, orientation)])
            env.window.isHidden = true                                            // Editor schliessen, bevor der naechste oeffnet
            env.window.rootViewController = nil
            env.pump(1.0)
        }
    }

    /// Wie "Weitermachen wie zuvor": das Blatt mit dem Skript daneben (ResumeState, ein Pfad der App)
    private func openSplit(size: CGSize) throws -> HostedEnvironment {
        var state = ResumeState.forRoute(.doc("demo-blatt"))
        state.companionID = "demo-skript"
        let data = try JSONEncoder().encode(state)
        let env = try host(MainView())
        env.window.frame = CGRect(origin: .zero, size: size)
        env.view.frame = env.window.bounds
        env.pump(0.5)
        let api = container.api, defaults = container.defaults
        pumping {
            defaults.set(data, forKey: ResumeState.lastKey)                     // direkt davor (die Uebersicht merkt sich sonst selbst)
            await env.router.resume.restoreIfNeeded(api: api, router: env.router)
        }
        XCTAssertEqual(env.router.route, .doc("demo-blatt"))
        waitForInk(env, count: 2)
        expect(env, "Teilung beenden")
        return env
    }

    func test06Karteikarten() throws {
        let env = try host(MainView())
        env.router.go(.cards)
        expect(env, "heute fällig")
        expect(env, "Stapel öffnen: Skript Kapitel 1 – Zahlensysteme")
        shoot(env, "06-karteikarten")
    }

    func test07Studienverlauf() throws {
        let env = try host(MainView())
        env.router.go(.studyPlan())
        expect(env, "Theoretische Informatik")
        if outDir != nil { expect(env, "Prüfungsanmeldung") }
        XCTAssertFalse(shows(env, StudyPlanText.noQIS), "Studienverlauf mit Katalog")
        shoot(env, "07-studienverlauf")
    }

    /// 8 Bescheinigungen: gespeicherte Liste des QIS (erfunden), Immatrikulationsbescheinigung mit Kopie von heute
    func test08Bescheinigungen() throws {
        let qis = try XCTUnwrap(manager.qis)
        qis.syncsAfterSignIn = false
        qis.signedIn()                                                             // verbunden, liest nichts (Liste ist frisch)
        let env = try host(MainView().environment(\.qis, qis))
        env.router.go(.certificates)
        expect(env, "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG")
        expect(env, "Notenspiegel (alle Leistungen) deutsch")
        expect(env, "Öffnen")
        XCTAssertFalse(shows(env, "Anmeldung nötig"), dump(env))
        env.pump(1.0)
        shoot(env, "08-bescheinigungen")
    }

    /// 9 Mensa: Speiseplan (erfunden) an einem Werktag; am Wochenende der naechste Montag als "heute"
    func test09Mensa() throws {
        UFFmt.todayOverride = Self.nextServiceDay()
        let env = try host(MainView())
        env.router.go(.mensa)
        expect(env, "Gemüse-Kichererbsen-Curry mit Reis")
        expect(env, "Hähnchenbrust mit Kräuterkartoffeln")
        XCTAssertFalse(shows(env, "Geschlossen"), "Werktag mit Speiseplan:\n" + dump(env))
        env.pump(1.0)
        shoot(env, "09-mensa")
    }

    func test10Community() throws {
        let env = try host(MainView())
        env.router.go(.community)
        expect(env, "Deine Communities")
        expect(env, "Grundlagen der Informatik")
        shoot(env, "10-community")
    }
}

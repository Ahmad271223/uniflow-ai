import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Pruefungsanmeldung in der App (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Karte auf der Uebersicht nur rund um den
/// Meldezeitraum, Abschnitt im Studienverlauf, Block "Prüfung anmelden" am Modul, Abzeichen in "Nächste Klausuren",
/// "Im QIS anmelden" oeffnet nur die QIS-Seite im In-App-Browser, "Angemeldete Prüfungen abrufen" liest ueber den
/// QIS-Stub (kein Netz) und hakt ab - nie wird eine Seite der Pruefungsanmeldung aufgerufen. Erfundene Daten,
/// eingefrorene Uhr.
@MainActor
final class ExamRegistrationAppTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-examreg-\(UUID().uuidString)", isDirectory: true)
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

    static func mod(_ id: String, _ title: String, sem: Int, exam: String = "Klausur 90 min", kind: String = "pflicht",
                    turnus: String = "WS", code: String? = nil) -> JSONValue {
        ["id": .string(id), "title": .string(title), "code": code.map(JSONValue.string) ?? .null, "area": "a", "kind": .string(kind),
         "lp": 5, "semester": .number(Double(sem)), "turnus": .string(turnus), "exam": .string(exam), "coursework": .null,
         "prerequisites": [], "language": "deutsch", "workload_h": 150, "source_page": 1]
    }

    static let catalog: JSONValue = [
        "v": 1, "university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022",
        "catalog_term": "WS 2025/26", "code": "TIBSc22", "regular_semesters": 6, "total_lp": 180,
        "source": ["url": "https://modkat.example/x.pdf", "fetched_at": "t", "sha256": "x"],
        "areas": [["id": "a", "name": "Pflicht", "lp_required": 150, "kind": "pflicht"]],
        "modules": [
            mod("programmieren-1", "Programmieren I", sem: 1),
            mod("mathematik-1", "Mathematik I", sem: 1),
            mod("algorithmen", "Algorithmen und Datenstrukturen", sem: 3),
            mod("datenbanken", "Grundlagen der Datenbanksysteme", sem: 3),
            mod("rechnernetze", "Rechnernetze", sem: 3, code: "4711"),
            mod("softwaretechnik", "Softwaretechnik", sem: 4, turnus: "SS"),
        ],
    ]

    /// Lokales Backend wie auf dem iPad: Katalog, Noten (bestanden, nicht bestanden, AN), Klausur aus Stud.IP
    private func seed(_ db: SQLiteDatabase) async throws {
        try await db.transaction { c in
            _ = try StudyCatalogStore.store(c, payload: String(decoding: Self.catalog.serialized(), as: UTF8.self), texts: nil,
                                            origin: "fixture", now: "t")
            try UniStore.storeGrades(c, [
                QISGrade(pruefungsnr: "1", text: "Programmieren I", semester: "WiSe 25/26", note: "1,7", status: "bestanden", credits: "5",
                         versuch: "1", abschluss: "Technische Informatik (PO-Version 2017)"),
                QISGrade(pruefungsnr: "2", text: "Mathematik I", semester: "WiSe 25/26", note: "5,0", status: "nicht bestanden",
                         credits: "5", versuch: "1", abschluss: "Technische Informatik (PO-Version 2017)"),
                QISGrade(pruefungsnr: "3", text: "Grundlagen der Datenbanksysteme", semester: "WiSe 26/27", status: "AN", versuch: "1",
                         abschluss: "Technische Informatik (PO-Version 2017)"),
            ], now: "t")
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Algorithmen und Datenstrukturen', '#4f5bd5', 't')")
            _ = try c.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES ('c-algo', 'Algorithmen und Datenstrukturen', 'vorlesung', 1, 1, 't')")
            _ = try c.execute("""
                INSERT INTO studip_events(id, course_id, title, start, end, room, description, cancelled, category, fetched_at)
                VALUES ('e1', 'c-algo', 'Klausur', '2027-02-15T09:00:00', '2027-02-15T11:00:00', 'HS A', '', 0, 'Klausur', 't')
                """)
        }
    }

    private func seededAPI(now: String) async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: now)!)
        try await seed(try await host.backend().context.database)
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    /// Element mit dieser Beschriftung (Anfang) im Bedienungshilfen-Baum (Kennungen liest dieser Baum nicht zuverlaessig)
    private func element(_ root: UIView, label: String) -> NSObject? {
        root.layoutIfNeeded()
        var found: NSObject?
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard found == nil, depth < 60 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.hasPrefix(label) == true { found = o; return }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return found
    }

    // MARK: Daten und Texte

    func testStateTextsAndQISLinkStaysInApp() throws {
        let (st, soon, exams) = try awaiting { () -> (ExamRegistrationState?, ExamRegistrationState?, [JSONValue]) in
            let api = try await self.seededAPI(now: "2026-11-20T10:00:00")
            return (await ExamRegistrationState.load(api), await ExamRegistrationState.load(try await self.seededAPI(now: "2026-11-05T10:00:00")),
                    await UFExam.load(api))
        }
        let s = try XCTUnwrap(st)
        XCTAssertTrue(s.showCard)
        XCTAssertTrue(s.verified)
        XCTAssertEqual(s.suggestions.map(\.id), ["algorithmen", "mathematik-1", "rechnernetze", "datenbanken"])
        XCTAssertEqual(s.suggestions.map(\.registered), [false, false, false, true])
        let w = try XCTUnwrap(s.window)
        XCTAssertEqual(ExamRegistrationText.windowLine(w), "Meldezeitraum 09.11.–22.11.2026 · noch 2 Tage")
        XCTAssertEqual(ExamRegistrationText.windowLine(try XCTUnwrap(soon?.window)), "Anmeldung ab Mo, 09.11. bis So, 22.11. (WiSe 26/27)")
        let algo = try XCTUnwrap(s.suggestion(catalogID: "algorithmen"))
        XCTAssertEqual(algo.reason, "laut deinem Plan im 3. Semester")
        XCTAssertEqual(ExamRegistrationText.examLine(algo), "Termin Mo, 15.02.2027 · 09:00 Uhr · HS A · Rücktritt bis Mo, 08.02.")
        XCTAssertEqual(s.suggestion(appModuleID: 1)?.id, "algorithmen")
        XCTAssertEqual(s.suggestion(catalogID: "mathematik-1")?.reason, "Wiederholung – 2. Versuch (nicht bestanden im WiSe 25/26)")
        XCTAssertEqual(ExamRegistrationText.via(try XCTUnwrap(s.suggestion(catalogID: "datenbanken"))), "im Notenspiegel als angemeldet (AN) geführt")
        XCTAssertEqual(s.warnings.map(\.text), ["Die Anmeldung endet in 2 Tagen. 3 geplante Prüfungen sind noch nicht angemeldet."])
        // Klausur der Liste "Nächste Klausuren" -> Vorschlag (Abzeichen "nicht angemeldet")
        XCTAssertEqual(exams.count, 1)
        XCTAssertEqual(s.suggestion(exam: try XCTUnwrap(exams.first))?.id, "algorithmen")
        // "Im QIS anmelden": Mein Studium des QIS, im In-App-Browser der LUH (nicht Safari, keine Formulardaten)
        let url = try XCTUnwrap(s.qisURL)
        XCTAssertEqual(url.host, "qis.verwaltung.uni-hannover.de")
        XCTAssertTrue(url.absoluteString.contains("moduleParameter=studyPOSMenu"))
        XCTAssertFalse(url.absoluteString.lowercased().contains("anmeld"), "nie direkt die Pruefungsanmeldung")
        XCTAssertEqual(UniLinks.route(url, university: .luh), .inApp(url))
    }

    // MARK: Uni Hildesheim (LSF, POS-Anmeldung ohne einheitliche Frist)

    /// Lokales Backend der Uni Hildesheim mit einer gelesenen Zeile aus "Meine POS-Anmeldungen" (erfunden)
    private func hildesheimAPI(now: String) async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: now)!,
                                    university: .hildesheim)
        try await host.backend().context.database.transaction { c in
            try QISRegistrationsSync.store(c, [QISRegistration(pruefungsnr: "4711", text: "Grundlagen der Informatik (Klausur)",
                                                               semester: "WiSe 26/27", datum: "15.02.2027", time: "10:00", room: "Forum HS 1",
                                                               status: "zugelassen", raw: "")], now: "t")
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    func testHildesheimTextsSayLSFAndLinkOpensLSFInApp() throws {
        let st = try awaiting { await ExamRegistrationState.load(try await self.hildesheimAPI(now: "2026-11-05T10:00:00")) }
        let s = try XCTUnwrap(st)
        XCTAssertEqual(s.system, "LSF")
        XCTAssertEqual(s.openLabel, "Im LSF anmelden")
        XCTAssertTrue(s.showCard, "POS-Anmeldung beginnt in 6 Tagen")
        XCTAssertTrue(s.warnings.isEmpty)
        let w = try XCTUnwrap(s.window)
        XCTAssertTrue(w.openEnd)
        XCTAssertEqual(ExamRegistrationText.windowLine(w, system: s.system), "Anmeldung im LSF ab Mi, 11.11. (WiSe 26/27) · Fristen je Prüfung")
        XCTAssertEqual(s.periods.map(ExamRegistrationText.periodRange), ["ab 11.11.2026"])
        XCTAssertTrue(s.periodNote?.hasPrefix("Die Uni Hildesheim hat keine einheitliche Anmeldefrist") == true)
        XCTAssertEqual(ExamRegistrationText.infoPage(s.system), "Meine POS-Anmeldungen")
        XCTAssertTrue(ExamRegistrationText.checked(s).contains("als angemeldet führt"))
        XCTAssertFalse(s.hint.contains("QIS"), s.hint)
        XCTAssertFalse(s.disclaimer.contains("QIS"), s.disclaimer)
        XCTAssertFalse(s.rules.contains { $0.contains("QIS") })
        // "Im LSF anmelden": Startseite des LSF im In-App-Browser der Uni Hildesheim
        let url = try XCTUnwrap(s.qisURL)
        XCTAssertEqual(url, UniversityProfile.hildesheimLSFStart)
        XCTAssertEqual(UniLinks.route(url, university: .hildesheim), .inApp(url))
    }

    func testHildesheimSectionShowsLSFButtonAndNote() throws {
        let api = try awaiting { try await self.hildesheimAPI(now: "2026-11-12T10:00:00") }
        var opened: [URL] = []
        let view = ScrollView { ExamRegistrationSection(api: api) }
            .environment(\.openURL, OpenURLAction { u in opened.append(u); return .handled })
        let env = try hostWithEnvironment(view, api: api)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Anmeldung im LSF seit Mi, 11.11.") } }, env.labels().joined(separator: " | "))
        let labels = env.labels()
        XCTAssertTrue(labels.contains { $0.hasPrefix("Die Uni Hildesheim hat keine einheitliche Anmeldefrist") }, labels.joined(separator: " | "))
        XCTAssertFalse(labels.contains { $0.hasPrefix("Die Zeiträume für") }, "kein 'nicht sicher' fuer die Uni Hildesheim")
        XCTAssertTrue(labels.contains("Im LSF angemeldet"), labels.joined(separator: " | "))
        XCTAssertFalse(labels.contains { $0.contains("Im QIS") }, labels.joined(separator: " | "))
        let button = try XCTUnwrap(element(env.view, label: "Im LSF anmelden"))
        XCTAssertTrue(button.accessibilityActivate())
        env.pump()
        XCTAssertEqual(opened, [UniversityProfile.hildesheimLSFStart])
    }

    // MARK: Karte, Abschnitt, Modul

    func testCardInPeriodWithWarningAndQISButton() throws {
        let api = try awaiting { try await self.seededAPI(now: "2026-11-20T10:00:00") }
        var opened: [URL] = []
        let view = ExamRegistrationCard(api: api, token: "t")
            .environment(\.openURL, OpenURLAction { u in opened.append(u); return .handled })
        let env = try hostWithEnvironment(view, api: api)
        XCTAssertTrue(env.wait { env.labels().contains("Diese Prüfungen solltest du anmelden:") }, env.labels().joined(separator: " | "))
        let labels = env.labels()
        XCTAssertTrue(labels.contains("Prüfungsanmeldung"))
        XCTAssertTrue(labels.contains("Meldezeitraum 09.11.–22.11.2026 · noch 2 Tage"), labels.joined(separator: " | "))
        XCTAssertTrue(labels.contains("Die Anmeldung endet in 2 Tagen. 3 geplante Prüfungen sind noch nicht angemeldet."))
        XCTAssertTrue(labels.contains { $0.hasPrefix("Algorithmen und Datenstrukturen, nicht angemeldet, laut deinem Plan im 3. Semester") })
        XCTAssertTrue(labels.contains { $0.hasPrefix("Grundlagen der Datenbanksysteme, angemeldet") })
        XCTAssertTrue(labels.contains(ExamRegistrationAPI.hint), "Hinweis: selbst anmelden")
        XCTAssertTrue(labels.contains("Im Studienverlauf"))
        let button = try XCTUnwrap(element(env.view, label: "Im QIS anmelden"))
        XCTAssertTrue(button.accessibilityActivate())
        env.pump()
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.absoluteString.contains("moduleParameter=studyPOSMenu") == true)
    }

    func testNoCardOutsideThePeriod() throws {
        let api = try awaiting { try await self.seededAPI(now: "2026-12-10T10:00:00") }
        let env = try hostWithEnvironment(VStack { ExamRegistrationCard(api: api, token: "t"); Text("Ende") }, api: api)
        XCTAssertTrue(env.wait { env.labels().contains("Ende") }, env.labels().joined(separator: " | "))
        env.pump(1)
        XCTAssertFalse(env.labels().contains("Prüfungsanmeldung"), "nach dem Meldezeitraum keine Karte")
    }

    func testSectionModuleBlocksAndExamBadges() throws {
        let api = try awaiting { try await self.seededAPI(now: "2026-11-20T10:00:00") }
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ExamRegistrationSection(api: api)
                ExamRegistrationModuleBlock(api: api, catalogID: "algorithmen")
                ExamRegistrationModuleBlock(api: api, catalogID: "programmieren-1")     // bestanden: kein Block
                UpcomingExamsCard(api: api, token: "t")
            }
        }
        let env = try hostWithEnvironment(view, api: api, size: CGSize(width: 1180, height: 2400))
        XCTAssertTrue(env.wait {
            let l = env.labels()
            return l.contains("Prüfungsanmeldung · WiSe 26/27") && l.contains { $0.hasPrefix("Prüfungsanmeldung: ") }
        }, env.labels().joined(separator: " | "))
        let labels = env.labels()
        let all = labels.joined(separator: " | ")
        XCTAssertTrue(labels.contains("Diese Prüfungen solltest du anmelden"), all)
        XCTAssertTrue(labels.contains("Quelle: Terminseite des Prüfungsamts (gelesen am 05.11.2026)"), all)
        XCTAssertTrue(labels.contains { $0.hasPrefix("• Klausur (auch mit Antwortwahl): Abmeldung bis 7 Tage") }, all)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Angemeldete Prüfungen noch nicht abgerufen.") }, all)
        XCTAssertFalse(labels.contains { $0.contains("kennt StudiNow nicht sicher") }, "TI B.Sc. ist geprueft")
        XCTAssertTrue(labels.contains("An die Prüfungsanmeldung erinnern"), all)
        XCTAssertEqual(labels.filter { $0 == "Prüfung anmelden" }.count, 1, "nur das vorgeschlagene Modul: \(all)")
        XCTAssertTrue(labels.contains("Prüfungsanmeldung: Meldezeitraum 09.11.–22.11.2026 · noch 2 Tage"), all)
        XCTAssertTrue(labels.contains { $0.contains("Klausur Algorithmen und Datenstrukturen") && $0.hasSuffix("nicht angemeldet") }, all)
    }

    // MARK: Angemeldete Pruefungen ueber den QIS-Stub

    func testFetchRegistrationsReadsInfoPageAndTicksOff() async throws {
        let clock = UniFlowClock.fixed(berlin: "2026-11-20T10:00:00")!
        let bed = try ContainerTestBed(name: "examreg", clock: clock)
        addTeardownBlock { await bed.tearDown() }
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        try await seed(try await c.host.backend().context.database)
        let q = try XCTUnwrap(m.qis)
        q.syncsAfterSignIn = false
        func page(_ name: String) -> String {
            (try? String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/exam-registration/\(name)"), encoding: .utf8)) ?? ""
        }
        let pages = ["start": page("qis-start.html"), "studium": page("qis-studium.html"), "tree": page("qis-info-tree.html"),
                     "expanded": page("qis-info-expanded.html"), "list": page("qis-info-list.html")]
        XCTAssertFalse(pages.values.contains(""), "Fixtures lesbar")
        let login = "<html><body><form action=\"x\"><input type=\"password\" name=\"fdsa\"></form></body></html>"
        UniStubProtocol.install { r in
            let u = r.url.absoluteString
            guard r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(login) }
            if u.contains("state=user&type=0") { return .text(pages["start"]!) }
            if u.contains("prfAnmStudent") { return .text("VERBOTEN") }
            if u.contains("moduleParameter=studyPOSMenu") { return .text(pages["studium"]!) }
            if u.contains("state=pruefungsinfoStudent") {
                if u.contains("next=list.vm") { return .text(pages["list"]!) }
                return .text(u.contains("nodeID=") ? pages["expanded"]! : pages["tree"]!)
            }
            return .text("", status: 404)
        }
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: "qis.verwaltung.uni-hannover.de"))
        q.signedIn()
        let runs = q.finishedRuns
        let report = await q.fetchRegistrations()
        XCTAssertEqual(report?.count, 2, report?.message ?? "")
        XCTAssertEqual(q.registrationsMessage, "2 angemeldete Prüfungen gelesen.")
        XCTAssertEqual(q.finishedRuns, runs + 1, "Seiten laden danach neu")
        let seen = UniStubProtocol.requests.map(\.url.absoluteString)
        XCTAssertFalse(seen.contains { $0.contains("prfAnmStudent") }, "nie die Pruefungsanmeldung/-abmeldung")
        XCTAssertFalse(seen.contains { $0.contains("verpublish") || $0.contains("type=4") })
        XCTAssertTrue(UniStubProtocol.requests.allSatisfy { $0.url.host == "qis.verwaltung.uni-hannover.de" })

        let st = ExamRegistrationState(try await c.api.value("/api/exam-registration"))
        XCTAssertEqual(st.suggestion(catalogID: "rechnernetze")?.registered, true, "abgehakt ueber die Info-Seite")
        XCTAssertEqual(st.suggestion(catalogID: "rechnernetze")?.registeredVia, "qis_info")
        XCTAssertEqual(st.suggestion(catalogID: "algorithmen")?.registered, false, "AMD zaehlt nicht")
        XCTAssertNotNil(st.registrationsCheckedAt)
        XCTAssertEqual(st.registered.filter(\.registered).map(\.text), ["Rechnernetze", "Mündliche Prüfung Seminar"])
        // Stammdaten und Sitzung nie gespeichert
        let db = try await c.host.backend().context.database
        let dump = JSONValue.array(try await db.rows("SELECT * FROM exam_registrations").map(JSONValue.object)).jsonString()
        for secret in ["Erika", "7654321", "Beispielweg", "S1abcDEF"] { XCTAssertFalse(dump.contains(secret), secret) }
    }

    // MARK: Erinnerungen

    final class Recorder: DueNotifying {
        var status_: DueNotificationStatus = .allowed
        var pending: [String] = []
        var added: [DueReminders.Reminder] = []
        func status() async -> DueNotificationStatus { status_ }
        func requestPermission() async -> Bool { status_ = .allowed; return true }
        func pendingIdentifiers() async -> [String] { pending }
        func schedule(_ r: DueReminders.Reminder) async { added.append(r); pending.append(r.identifier) }
        func remove(_ identifiers: [String]) { pending.removeAll { identifiers.contains($0) } }
    }

    func testRemindersScheduleAndSwitchOff() async throws {
        let suite = "uniflow.examreg.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rec = Recorder()
        rec.pending = ["de.uniflow.ai.due.C1.x.d1", "de.uniflow.ai.examreg.C0.alt.d2"]
        let s = ExamRegistrationReminderScheduler(notifier: rec, defaults: defaults)
        s.now = { UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!.now }
        XCTAssertTrue(s.enabled, "Vorgabe an")
        let api = try await seededAPI(now: "2026-11-05T10:00:00")
        await s.refresh(api: api, container: "C1")
        XCTAssertEqual(s.scheduled, 3)
        XCTAssertEqual(rec.added.map(\.title), ["Prüfungsanmeldung beginnt heute", "Prüfungsanmeldung: noch 7 Tage", "Prüfungsanmeldung endet übermorgen"])
        XCTAssertTrue(rec.pending.contains("de.uniflow.ai.due.C1.x.d1"), "Erinnerungen an Abgaben bleiben")
        XCTAssertFalse(rec.pending.contains("de.uniflow.ai.examreg.C0.alt.d2"), "alte eigene zurueckgenommen")
        XCTAssertEqual(DueNotificationDelegate.route(identifier: rec.added[0].identifier, userInfo: ["route": "#/studyplan"]), "#/studyplan")
        await s.setEnabled(false)
        XCTAssertEqual(rec.pending, ["de.uniflow.ai.due.C1.x.d1"])
        XCTAssertFalse(ExamRegistrationReminderScheduler(notifier: rec, defaults: defaults).enabled, "Schalter bleibt aus")
        rec.status_ = .denied
        let ok = await s.setEnabled(true)
        XCTAssertFalse(ok)
        XCTAssertTrue(s.denied)
    }
}

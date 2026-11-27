import Foundation
import XCTest
@testable import UniFlowCore

/// Uni Goettingen, FlexNow 2 (27.11.2026, docs/GOETTINGEN-FLEXNOW-2026-11-27.md): Anmeldeformular, Leser fuer "Aktuelles
/// -> Aktuelle Prüfungen" gegen die Nachbildung im gesehenen Aufbau (apps/apple/DebugStub/goettingen-flexnow), Speichern,
/// Antwort von /api/exam-registration und Erinnerungen vor dem Ende der Abmeldefrist. Nie ein Netz, nie ein Absenden.
final class FlexNowTests: XCTestCase {
    static var stubDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }             // .../apps/apple
        return url.appendingPathComponent("DebugStub/goettingen-flexnow", isDirectory: true)
    }

    static func page(_ name: String) throws -> String {
        try String(contentsOf: stubDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-27T10:00:00")!

    private func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: Anmeldeformular

    func testLoginForm() throws {
        let form = UniLoginForms.goettingenFlexNow
        XCTAssertEqual(UniLoginForms.forms(.goettingen), [UniLoginForms.goettingenStudIP, form])
        XCTAssertEqual(UniLoginForms.hosts(.goettingen), ["studip.uni-goettingen.de", "flexnow2.uni-goettingen.de"])
        XCTAssertEqual(UniLoginForms.form(for: u("https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), university: .goettingen), form)
        XCTAssertEqual(UniLoginForms.form(for: u("https://flexnow2.uni-goettingen.de/FN2AUTH/FN2AuthServlet?op=Login"), university: .goettingen), form)
        XCTAssertNil(UniLoginForms.form(for: u("https://flexnow2.uni-goettingen.de/FN2SSS/"), university: .goettingen), "angemeldete Seite")
        XCTAssertNil(UniLoginForms.form(for: u("http://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), university: .goettingen), "nur HTTPS")
        XCTAssertNil(UniLoginForms.form(for: u("https://www.uni-goettingen.de/de/45574.html"), university: .goettingen),
                     "derselbe Kasten auf der Uni-Seite: dort fuellt und liest die App nichts")
        XCTAssertNil(UniLoginForms.form(for: u("https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), university: .luh))
        XCTAssertTrue(UniLoginForms.allowsCapture(scheme: "https", host: "flexnow2.uni-goettingen.de", port: 0, path: "/FN2AUTH/login.jsp", university: .goettingen))
        XCTAssertFalse(UniLoginForms.allowsCapture(scheme: "https", host: "flexnow2.uni-goettingen.de", port: 0, path: "/FN2SSS/FrontControllerSS", university: .goettingen))
        // ohne Webansicht (Hintergrund per POST) erst nach einem echten Test freigeben
        XCTAssertFalse(UniFormLogin.allowedForms.contains(form.id))

        // die Nachbildung traegt die Feldnamen der echten Seite (26.11.2026 gelesen)
        let html = try Self.page("flexnow.html")
        XCTAssertTrue(form.appears(in: html))
        XCTAssertFalse(form.showsFailure(in: html))
        XCTAssertTrue(FlexNowPage.showsLoginForm(html))
        let scanned = try XCTUnwrap(UniFormScanner.forms(html).first)
        XCTAssertEqual(scanned.method, "post")
        XCTAssertEqual(scanned.fields.map(\.name), ["kennung", "kennwort", "emrexSessionId", "emrexReUrl"])
        XCTAssertNotNil(UniFormLogin.loginForm([scanned], spec: form))
        // stille Anmeldung in der Webansicht: einmal ausfuellen; mit Fehlertext wieder da -> abgelehnt
        let login = u("https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp")
        let domains = ["uni-goettingen.de"]
        XCTAssertEqual(UniAutoLoginFlow.step(url: login, html: html, university: .goettingen, domains: domains, submitted: [], isDone: false), .fill(form))
        let rejected = html.replacingOccurrences(of: "<form", with: "<div class=\"error\">Anmeldung fehlgeschlagen</div><form")
        XCTAssertEqual(UniAutoLoginFlow.step(url: login, html: rejected, university: .goettingen, domains: domains, submitted: [form.id], isDone: false), .rejected)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://flexnow2.uni-goettingen.de/FN2SSS/"), html: try Self.page("flexnow-angemeldet.html"),
                                             university: .goettingen, domains: domains, submitted: [form.id], isDone: true), .done)
    }

    func testSignedInPage() throws {
        let start = FlexNowPage.start
        XCTAssertTrue(FlexNowPage.isSignedIn(url: start, html: try Self.page("flexnow-angemeldet.html")))
        XCTAssertFalse(FlexNowPage.isSignedIn(url: start, html: try Self.page("flexnow.html")), "Anmeldeformular")
        XCTAssertFalse(FlexNowPage.isSignedIn(url: u("https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), html: ""))
        XCTAssertFalse(FlexNowPage.isSignedIn(url: u("https://www.uni-goettingen.de/de/45574.html"), html: ""), "Uni-Seite")
        XCTAssertFalse(FlexNowPage.isSignedIn(url: u("http://flexnow2.uni-goettingen.de/FN2SSS/"), html: ""))
        XCTAssertFalse(FlexNowPage.isSignedIn(url: u("https://flexnow2.uni-goettingen.de:8443/FN2SSS/"), html: ""))
    }

    // MARK: Leser

    func testReadsCurrentExamsAsSeen() throws {
        let r = FlexNowParser.parse(html: try Self.page("flexnow-angemeldet.html"))
        XCTAssertTrue(r.sectionFound)
        XCTAssertTrue(r.reached)
        XCTAssertEqual(r.containers, 2)
        XCTAssertEqual(r.skipped, 0)
        XCTAssertEqual(r.registrations.count, 2)
        let a = r.registrations[0], b = r.registrations[1]
        XCTAssertEqual(a.pruefungsnr, "B.WIWI-QMW.0001.Prvor")
        XCTAssertEqual(a.text, "Mathematik für Wirtschaftswissenschaften")
        XCTAssertEqual(a.form, "Prüfungsvorleistung")
        XCTAssertEqual(a.semester, "WS26/27")
        XCTAssertEqual(a.pruefer, "Prof. Dr. Erika Beispiel")
        XCTAssertEqual(a.status, "angemeldet")
        XCTAssertTrue(a.registered)
        XCTAssertEqual(a.withdraw, "10.12.2026, 23:59 Uhr", "Ende des Zeitraums aus span.fristBis")
        XCTAssertEqual(a.isoWithdraw, "2026-12-10")
        XCTAssertEqual(RegistrationRows.clock(a.withdraw), "23:59")
        XCTAssertNil(a.datum, "ein Pruefungstermin steht dort nicht")
        XCTAssertEqual(a.abschluss, "B.WIWI-QMW.0001: Mathematik für Wirtschaftswissenschaften")
        XCTAssertTrue(a.raw.contains("Abmeldung möglich: 02.11.2026 - 10.12.2026, 23:59 Uhr"), a.raw)
        XCTAssertFalse(a.raw.contains("stub1"), "die versteckten Kennungen der Anmeldung werden nie gelesen")
        XCTAssertEqual(b.pruefungsnr, "B.WIWI-OPH.0004.Mp")
        XCTAssertEqual(b.text, "Einführung in die Volkswirtschaftslehre")
        XCTAssertEqual(b.form, "Klausur (90 Minuten)")
        XCTAssertEqual(b.pruefer, "Dr. Max Muster")
        XCTAssertEqual(b.isoWithdraw, "2027-01-15")
        XCTAssertEqual(b.abschluss, "B.WIWI-OPH.0004: Einführung in die Volkswirtschaftslehre")
    }

    func testOnlyRegisteredBlocksAreRead() throws {
        // ein Block ohne Klasse "angemeldet" (am echten Konto nicht gesehen): nicht gelesen, nur gezaehlt
        let html = try Self.page("flexnow-angemeldet.html")
        let first = try XCTUnwrap(html.range(of: "prfangBlock angemeldet first"))
        let changed = html.replacingCharacters(in: first, with: "prfangBlock first")
        let r = FlexNowParser.parse(html: changed)
        XCTAssertEqual(r.registrations.map(\.pruefungsnr), ["B.WIWI-OPH.0004.Mp"])
        XCTAssertEqual(r.skipped, 1)
        XCTAssertTrue(r.reached)
    }

    func testEmptyUnfinishedAndLoginPages() throws {
        let empty = FlexNowParser.parse(html: try Self.page("aktuelles-leer.html"))
        XCTAssertTrue(empty.sectionFound)
        XCTAssertTrue(empty.saidEmpty)
        XCTAssertTrue(empty.reached)
        XCTAssertEqual(empty.registrations, [])
        // Ueberschrift da, Liste noch nicht nachgeladen: "keine" aus anderen Kaesten oder der Fusszeile zaehlt nicht
        let unfinished = FlexNowParser.parse(html: try Self.page("aktuelles-unfertig.html"))
        XCTAssertTrue(unfinished.sectionFound)
        XCTAssertFalse(unfinished.saidEmpty)
        XCTAssertFalse(unfinished.reached)
        // anderer Bereich offen (keine Ueberschrift)
        XCTAssertFalse(FlexNowParser.parse(html: "<html><body><h2>Studierendendaten</h2><ul class=\"treeview\"></ul></body></html>").reached)
        let login = FlexNowParser.parse(html: try Self.page("flexnow.html"))
        XCTAssertTrue(login.loginPage)
        XCTAssertFalse(login.reached)
    }

    func testTextHelpers() {
        XCTAssertEqual(FlexNowParser.splitHead("Modul: B.X.0001: Titel: mit Doppelpunkt").code, "B.X.0001")
        XCTAssertEqual(FlexNowParser.splitHead("Modul: B.X.0001: Titel: mit Doppelpunkt").title, "Titel: mit Doppelpunkt")
        XCTAssertNil(FlexNowParser.splitHead("Prüfung: Hausarbeit ohne Kürzel").code)
        XCTAssertEqual(FlexNowParser.splitHead("Prüfung: Hausarbeit ohne Kürzel").title, "Hausarbeit ohne Kürzel")
        XCTAssertEqual(FlexNowParser.splitForm("Statistik (Klausur (90 Minuten))").form, "Klausur (90 Minuten)")
        XCTAssertEqual(FlexNowParser.splitForm("Statistik (Klausur (90 Minuten))").title, "Statistik")
        XCTAssertNil(FlexNowParser.splitForm("Statistik").form)
        XCTAssertNil(FlexNowParser.splitForm("(nur Klammer)").form)
        XCTAssertEqual(FlexNowParser.deadline("02.11.2026 - 10.12.2026, 23:59 Uhr"), "10.12.2026, 23:59 Uhr")
        XCTAssertEqual(FlexNowParser.deadline("– X: An-/Abmeldung bis 10.12.2026, 23 Uhr"), "10.12.2026, 23:00 Uhr")
        XCTAssertEqual(FlexNowParser.deadline("bis 10.12.2026"), "10.12.2026")
        XCTAssertNil(FlexNowParser.deadline("ohne Datum"))
        XCTAssertEqual(FlexNowParser.dropLabel("Abmeldung möglich im Zeitraum: 02.11.2026 - 10.12.2026, 23:59 Uhr"),
                       "02.11.2026 - 10.12.2026, 23:59 Uhr")
    }

    // MARK: Speichern, Antwort, Erinnerungen

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: Self.clock, university: "goettingen")
    }

    private func registrations(_ b: LocalBackend) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/exam-registration"))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json)
    }

    func testStoreKeepsRowsWhenListNotReached() async throws {
        let b = try await backend()
        let db = b.context.database
        var v = try await registrations(b)
        XCTAssertEqual(v["supported"]?.bool, true)
        XCTAssertEqual(v["system"]?.string, "FlexNow")
        XCTAssertEqual(v["registered"]?.array?.count, 0)

        let full = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("flexnow-angemeldet.html"), clock: Self.clock)
        XCTAssertEqual(full.count, 2)
        XCTAssertEqual(full.message, "2 angemeldete Prüfungen aus FlexNow gelesen.")
        v = try await registrations(b)
        let regs = v["registered"]?.array ?? []
        XCTAssertEqual(regs.map { $0["text"]?.string }, ["Mathematik für Wirtschaftswissenschaften", "Einführung in die Volkswirtschaftslehre"])
        XCTAssertEqual(regs.first?["withdraw_until"]?.string, "2026-12-10")
        XCTAssertEqual(regs.first?["withdraw_time"]?.string, "23:59")
        XCTAssertEqual(regs.first?["withdraw_text"]?.string, "10.12.2026, 23:59 Uhr")
        XCTAssertEqual(regs.first?["module"]?.string, "B.WIWI-QMW.0001: Mathematik für Wirtschaftswissenschaften")
        XCTAssertEqual(regs.first?["form"]?.string, "Prüfungsvorleistung")
        XCTAssertEqual(v["registrations_message"]?.string, "2 angemeldete Prüfungen aus FlexNow gelesen.")
        XCTAssertEqual(v["registrations_checked_at"]?.string, "2026-11-27T10:00:00")
        // keine Meldezeitraeume, keine Vorschlaege, keine Karte auf der Uebersicht
        XCTAssertEqual(v["window"], .null)
        XCTAssertEqual(v["suggestions"]?.array?.count, 0)
        XCTAssertEqual(v["show_card"]?.bool, false)
        XCTAssertEqual(v["qis_url"]?.string, "https://flexnow2.uni-goettingen.de/")
        XCTAssertEqual(v["withdraw_reminders"]?.bool, true)

        // Liste nicht erreicht (noch nicht nachgeladen) bzw. Anmeldeseite: nichts geloescht
        let unfinished = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("aktuelles-unfertig.html"), clock: Self.clock)
        XCTAssertNil(unfinished.count)
        XCTAssertEqual(unfinished.message, FlexNowRegistrationsSync.notReached)
        let login = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("flexnow.html"), clock: Self.clock)
        XCTAssertTrue(login.needsLogin)
        v = try await registrations(b)
        XCTAssertEqual(v["registered"]?.array?.count, 2)
        XCTAssertEqual(v["registrations_ok"]?.bool, false)

        // zweimal dasselbe: keine doppelten Zeilen; abgemeldet (Liste sagt "keine"): Zeilen weg
        _ = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("flexnow-angemeldet.html"), clock: Self.clock)
        _ = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("flexnow-angemeldet.html"), clock: Self.clock)
        let count = try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM exam_registrations")?.int }
        XCTAssertEqual(count, 2)
        let empty = await FlexNowRegistrationsSync.read(db: db, html: try Self.page("aktuelles-leer.html"), clock: Self.clock)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.message, "In FlexNow sind gerade keine Prüfungen angemeldet.")
        v = try await registrations(b)
        XCTAssertEqual(v["registered"]?.array?.count, 0)
    }

    func testRemindersBeforeEndOfWithdrawal() async throws {
        let b = try await backend()
        _ = await FlexNowRegistrationsSync.read(db: b.context.database, html: try Self.page("flexnow-angemeldet.html"), clock: Self.clock)
        let v = try await registrations(b)
        let plan = ExamRegistrationReminders.plan(v, container: "C1", now: Self.clock.now)
        XCTAssertEqual(plan.map(\.identifier), [
            "de.uniflow.ai.examreg.C1.abmeldung.2026-12-10.d7",
            "de.uniflow.ai.examreg.C1.abmeldung.2026-12-10.d2",
            "de.uniflow.ai.examreg.C1.abmeldung.2027-01-15.d7",
            "de.uniflow.ai.examreg.C1.abmeldung.2027-01-15.d2",
        ])
        XCTAssertEqual(plan.map { r in UniFlowClock { r.fireAt }.nowISO },
                       ["2026-12-03T09:00:00", "2026-12-08T09:00:00", "2027-01-08T09:00:00", "2027-01-13T09:00:00"])
        XCTAssertEqual(plan[1].title, "Abmeldefrist endet übermorgen")
        XCTAssertEqual(plan[1].body, "Mathematik für Wirtschaftswissenschaften: Abmeldung in FlexNow möglich bis Do, 10.12., 23:59 Uhr.")
        XCTAssertEqual(plan[0].title, "Abmeldefrist: noch 7 Tage")
        XCTAssertEqual(plan[0].route, "#/services")
        // spaeter: nur kuenftige
        let late = ExamRegistrationReminders.plan(v, container: "C1", now: UniFlowClock.fixed(berlin: "2026-12-05T10:00:00")!.now)
        XCTAssertEqual(late.first?.identifier, "de.uniflow.ai.examreg.C1.abmeldung.2026-12-10.d2")
        // mehrere Pruefungen mit derselben Frist: eine Mitteilung
        var same = v
        if case .object(var o) = v, var regs = v["registered"]?.array, regs.count == 2, case .object(var second) = regs[1] {
            second["withdraw_until"] = "2026-12-10"
            regs[1] = .object(second)
            o["registered"] = .array(regs)
            same = .object(o)
        }
        let joined = ExamRegistrationReminders.planWithdraw(same, container: "C1", now: Self.clock.now)
        XCTAssertEqual(joined.count, 2)
        XCTAssertTrue(joined[0].body.hasPrefix("2 angemeldete Prüfungen (Mathematik für Wirtschaftswissenschaften, Einführung in die Volkswirtschaftslehre)"), joined[0].body)
        // ohne `withdraw_reminders` (LUH, Hildesheim): keine Erinnerung an Abmeldefristen
        if case .object(var o) = v {
            o["withdraw_reminders"] = nil
            XCTAssertEqual(ExamRegistrationReminders.planWithdraw(.object(o), container: "C1", now: Self.clock.now), [])
        }
    }
}

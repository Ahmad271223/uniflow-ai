import Foundation
import XCTest
@testable import UniFlowCore

/// Pruefungsanmeldung (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Meldezeitraeume aus der Datendatei (gleiche Faelle wie
/// app/exam_registration.py), Leser fuer "Info über angemeldete Prüfungen" mit erfundenen QIS-Seiten (nie die
/// Pruefungsanmeldung, nie asi oder Stammdaten gespeichert), Vorschlaege aus dem Studienverlauf, Erinnerungen.
final class ExamRegistrationTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func page(_ name: String) throws -> String {
        String(decoding: try repo("packages/shared-contracts/fixtures/exam-registration/\(name)"), as: UTF8.self)
    }

    private let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })
    private let asi = "S1abcDEF"

    // MARK: Meldezeitraeume (gleich wie Python)

    func testPeriodCasesMatchPython() throws {
        let fx = try JSONValue.parse(repo("packages/shared-contracts/fixtures/exam-registration/period-cases.json"))
        let data = ExamRegistrationPeriods.luh
        XCTAssertEqual(fx["soon_days"]?.int, ExamRegistrationPeriods.soonDays)
        XCTAssertGreaterThanOrEqual(data.programs.count, 90, "alle Terminseiten der Sitemap als Link")
        for c in fx["programs"]?.array ?? [] {
            let p = data.program(name: c["name"]?.string, degree: c["degree"]?.string)
            XCTAssertEqual(p?.slug, c["slug"]?.string, "\(c)")
            XCTAssertEqual(p?.table != nil, c["has_table"]?.bool ?? false, "\(c)")
        }
        let phases = fx["phases"]?.array ?? []
        XCTAssertGreaterThan(phases.count, 100)
        for c in phases {
            let p = data.program(name: c["name"]?.string, degree: c["degree"]?.string)
            let w = data.window(p, today: c["today"]?.string ?? "", kind: c["kind"]?.string ?? "")
            XCTAssertEqual(w?.json ?? .null, c["window"] ?? .null, "\(c["name"] ?? .null) \(c["today"] ?? .null) \(c["kind"] ?? .null)")
            XCTAssertEqual(data.periods(p, term: w?.term).count, c["periods"]?.int)
        }
        for c in fx["slugs"]?.array ?? [] {
            XCTAssertEqual(ExamRegistrationPeriods.slugify(ExamRegistrationPeriods.programName(c["text"]?.string ?? "")), c["slug"]?.string)
        }
        for c in fx["degrees"]?.array ?? [] {
            XCTAssertEqual(ExamRegistrationPeriods.degreeSlugs(c["degree"]?.string, text: c["text"]?.string ?? ""),
                           c["slugs"]?.array?.compactMap(\.string))
        }
    }

    /// Die Zeitraeume der Technischen Informatik (gelesen 05.11.2026) und die Quelle
    func testTechnischeInformatikWinter2026() throws {
        let data = ExamRegistrationPeriods.luh
        let p = try XCTUnwrap(data.program(name: "Technische Informatik (PO-Version 2017)", degree: "B.Sc."))
        XCTAssertEqual(p.url, "https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/technische-informatik-bsc/termine")
        XCTAssertEqual(p.checkedAt, "2026-11-05")
        let w = try XCTUnwrap(data.window(p, today: "2026-11-05"))
        XCTAssertEqual(w.term, "WiSe 26/27")
        XCTAssertEqual(w.period.start, "2026-11-09")
        XCTAssertEqual(w.period.end, "2026-11-22")
        XCTAssertEqual(w.phase, .soon)
        XCTAssertEqual(w.daysUntil, 4)
        XCTAssertEqual(data.rules.first { $0.form == "Klausur" }?.days, 7)
        XCTAssertTrue(data.qisMenu.contains("moduleParameter=studyPOSMenu"))
        // nicht gepruefter Studiengang: nur Link, kein Fenster
        let arch = try XCTUnwrap(data.program(name: "Architektur", degree: "B.Sc."))
        XCTAssertNil(arch.table)
        XCTAssertNil(data.window(arch, today: "2026-11-10"))
    }

    // MARK: Leser der Info-Seite

    func testRegistrationRowsTolerateHeadersStatusAndDates() {
        let rows = RegistrationRows.parse(rows: [
            ["Prüfungs-Nr.", "Bezeichnung", "Sem.", "Termin", "Ort", "Vermerk", "Abmeldung bis", "Form"],
            ["Pflichtmodule", "", "", "", "", "", "", ""],
            ["1", "Analysis", "WS 26/27", "Fr, 12.02.2027, 10:15 Uhr", "Audimax", "AN", "05.02.2027", "Klausur"],
            ["2", "Physik", "WS 26/27", "2027-02-20", "", "AMD", "", ""],
            ["3", "Seminar", "WS 26/27", "", "", "", "", "VbP"],
            ["Matrikelnummer", "7654321", "", "", "", "", "", ""],
        ])
        XCTAssertEqual(rows.map(\.text), ["Analysis", "Physik", "Seminar"])
        XCTAssertEqual(rows.map(\.registered), [true, false, true])
        XCTAssertEqual(rows[0].isoDate, "2027-02-12")
        XCTAssertEqual(rows[0].clock, "10:15")
        XCTAssertEqual(rows[0].isoWithdraw, "2027-02-05")
        XCTAssertEqual(rows[0].room, "Audimax")
        XCTAssertEqual(rows[1].isoDate, "2027-02-20")
        XCTAssertNil(rows[1].clock)
        XCTAssertEqual(rows[2].form, "VbP")
        // Notenspiegel-Kopf (mit Note) ist keine Info-Tabelle
        XCTAssertFalse(RegistrationRows.isHeader(RegistrationRows.headerMap(["Prüfungsnr", "Prüfungstext", "Semester", "Note", "Status"])))
        XCTAssertTrue(RegistrationRows.isHeader(RegistrationRows.headerMap(["Prüfungsnr.", "Prüfungstext", "Datum"])))
        for s in ["", "AN", "angemeldet", "zugelassen", "PV"] { XCTAssertTrue(RegistrationRows.isRegistered(s), s) }
        for s in ["AMD", "abgemeldet", "RTE", "RTU", "BE", "nicht bestanden", "bestanden"] { XCTAssertFalse(RegistrationRows.isRegistered(s), s) }
        XCTAssertNil(RegistrationRows.isoDate("31.02.2027"))
        XCTAssertNil(RegistrationRows.clock("12.02.2027"), "ein Datum ist keine Uhrzeit")
        XCTAssertEqual(RegistrationRows.clock("9.15 Uhr"), "09:15")
    }

    func testForbiddenLinksAreNeverInfo() {
        func link(_ text: String, _ query: String) -> QISLink {
            let a = "https://qis.verwaltung.uni-hannover.de/qisserver/rds?" + query
            return QISLink(text: text, address: a, parameters: QISParser.parameters(of: a))
        }
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("Prüfungsanmeldung/-abmeldung", "state=prfAnmStudent&next=wait.vm")))
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("Weiter", "state=prfAnmStudent")), "Parameter genuegt")
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("abmelden", "state=x&pordnr=1")))
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("Rücktritt", "state=x")))
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("Info", "state=x&menuid=abmeldungInfo")))
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("PDF-Übersicht", "state=verpublish")))
        XCTAssertTrue(QISRegistrationLinks.isForbidden(link("Abmelden", "state=user&type=4")))
        XCTAssertTrue(QISRegistrationLinks.isInfo(link("Info über angemeldete Prüfungen", "state=pruefungsinfoStudent&next=tree.vm")))
        XCTAssertTrue(QISRegistrationLinks.isInfo(link("Angemeldete Prüfungen für TI anzeigen", "state=pruefungsinfoStudent&next=list.vm")))
        XCTAssertFalse(QISRegistrationLinks.isInfo(link("Prüfungsanmeldung", "state=pruefungsinfoStudent")))
        XCTAssertFalse(QISRegistrationLinks.isInfo(link("Info über angemeldete Prüfungen", "state=prfAnmStudent")),
                       "ein Info-Link mit Anmelde-Parametern wird lieber nicht gefolgt")
    }

    /// QIS mit festen Seiten aus den Fixtures: ohne asi nur die Startseite
    private func qis(info: String = "tree", loggedIn: Bool = true) throws -> FakeUniTransport {
        let pages = try ["start": page("qis-start.html"), "studium": page("qis-studium.html"), "tree": page("qis-info-tree.html"),
                         "expanded": page("qis-info-expanded.html"), "list": page("qis-info-list.html"),
                         "empty": page("qis-info-empty.html"), "direct": page("qis-info-direct.html")]
        let login = "<html><body><form action=\"rds?state=user&amp;type=1\"><input type=\"password\" name=\"fdsa\"></form></body></html>"
        let start = QISClient.startURL.absoluteString
        let asi = self.asi
        return FakeUniTransport { r in
            let u = r.url.absoluteString
            guard loggedIn else { return ok(login) }
            if u == start { return ok(pages["start"]!) }
            guard u.contains("asi=\(asi)") else { return ok(login) }
            if u.contains("prfAnmStudent") { return ok("<html><body>VERBOTEN</body></html>") }
            if u.contains("moduleParameter=studyPOSMenu") { return ok(pages["studium"]!) }
            if u.contains("state=pruefungsinfoStudent") {
                if info != "tree" { return ok(pages[info]!) }
                if u.contains("next=list.vm") { return ok(pages["list"]!) }
                if u.contains("nodeID=") { return ok(pages["expanded"]!) }
                return ok(pages["tree"]!)
            }
            return UniResponse(status: 404)
        }
    }

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-11-20T10:00:00")!, university: "luh")
        return db
    }

    func testWalkReadsTreeAndNeverTouchesRegistration() async throws {
        let t = try qis()
        let r = try await QISRegistrationClient(transport: t, retry: noWait).fetch()
        XCTAssertEqual(r.registrations.map(\.text), ["Rechnernetze", "Algorithmen und Datenstrukturen", "Mündliche Prüfung Seminar"])
        XCTAssertEqual(r.registrations.map(\.registered), [true, false, true])
        XCTAssertEqual(r.registrations[0].isoDate, "2027-03-01")
        XCTAssertEqual(r.registrations[0].clock, "09:00")
        XCTAssertEqual(r.registrations[0].isoWithdraw, "2027-02-22")
        XCTAssertEqual(r.registrations[0].pruefer, "Prof. Dr. Erfunden")
        XCTAssertEqual(r.registrations[0].abschluss, "Technische Informatik (PO-Version 2017)")
        XCTAssertEqual(r.tables, 1)
        XCTAssertEqual(r.pages, 5, "Start, Mein Studium, Info, Abschluss, Liste")
        let urls = t.requests.map(\.url.absoluteString)
        XCTAssertFalse(urls.contains { $0.contains("prfAnmStudent") }, "nie Pruefungsanmeldung/-abmeldung")
        XCTAssertFalse(urls.contains { $0.contains("verpublish") }, "nie eine Bescheinigung")
        XCTAssertFalse(urls.contains { $0.contains("type=4") }, "nie abmelden")
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" && $0.body == nil }, "keine Formulare")
        XCTAssertEqual(urls.filter { $0.contains("expand=1") }.count, 0, "aufgeklappter Knoten wird nicht wieder zugeklappt")
    }

    func testEmptyDirectMissingAndExpired() async throws {
        let empty = try await QISRegistrationClient(transport: try qis(info: "empty"), retry: noWait).fetch()
        XCTAssertEqual(empty.registrations, [])
        let direct = try await QISRegistrationClient(transport: try qis(info: "direct"), retry: noWait).fetch()
        XCTAssertEqual(direct.registrations.map(\.text), ["Mathematik I", "Labor Technische Informatik"])
        XCTAssertEqual(direct.registrations[0].clock, "10:15")
        XCTAssertEqual(direct.registrations[0].isoWithdraw, "2027-02-05")
        do {
            _ = try await QISRegistrationClient(transport: try qis(loggedIn: false), retry: noWait).fetch()
            XCTFail("abgelaufen erwartet")
        } catch { XCTAssertEqual(error as? QISError, .sessionExpired) }
        // Mein Studium ohne Info-Link
        let start = try page("qis-start.html")
        let noInfo = FakeUniTransport { r in
            let u = r.url.absoluteString
            if u == QISClient.startURL.absoluteString { return ok(start) }
            return ok("<html><body><a href=\"rds?state=user&amp;type=4&amp;asi=S1abcDEF\">Abmelden</a><a href=\"rds?state=prfAnmStudent&amp;asi=S1abcDEF\">Prüfungsanmeldung/-abmeldung</a></body></html>")
        }
        do {
            _ = try await QISRegistrationClient(transport: noInfo, retry: noWait).fetch()
            XCTFail("nicht gefunden erwartet")
        } catch { XCTAssertEqual(error as? QISRegistrationError, .infoNotFound) }
        XCTAssertFalse(noInfo.requests.contains { $0.url.absoluteString.contains("prfAnm") })
    }

    func testSyncStoresRowsWithoutSecrets() async throws {
        let db = try await database()
        let report = await QISRegistrationsSync.run(db: db, transport: try qis(), clock: .fixed(berlin: "2026-11-20T10:00:00")!, retry: noWait)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.message, "2 angemeldete Prüfungen gelesen.")
        let (rows, run, dump) = try await db.withConnection { c -> ([QISRegistration], JSONValue?, String) in
            let all = try c.rows("SELECT * FROM exam_registrations").map { JSONValue.object($0).serialized() }
            let settings = try c.rows("SELECT * FROM settings").map { JSONValue.object($0).serialized() }
            return (try QISRegistrationsSync.rows(c), try QISRegistrationsSync.lastRun(c),
                    (all + settings).map { String(decoding: $0, as: UTF8.self) }.joined())
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(run?["ok"]?.bool, true)
        XCTAssertEqual(run?["count"]?.int, 2)
        for secret in ["Erika", "7654321", "Beispielweg", asi] { XCTAssertFalse(dump.contains(secret), secret) }
        // abgelaufene Sitzung: Stand mit Fehler, Zeilen bleiben
        let expired = await QISRegistrationsSync.run(db: db, transport: try qis(loggedIn: false), retry: noWait)
        XCTAssertTrue(expired.needsLogin)
        XCTAssertNil(expired.count)
        let after = try await db.withConnection { try QISRegistrationsSync.rows($0).count }
        XCTAssertEqual(after, 3)
    }

    // MARK: Vorschlaege

    static func mod(_ id: String, _ title: String, sem: Int?, turnus: String = "WS", exam: String? = "Klausur 90 min",
                    kind: String = "pflicht", code: String? = nil) -> JSONValue {
        ["id": .string(id), "title": .string(title), "code": code.map(JSONValue.string) ?? .null, "area": "a", "kind": .string(kind),
         "lp": 5, "semester": sem.map { .number(Double($0)) } ?? .null, "turnus": .string(turnus),
         "exam": exam.map(JSONValue.string) ?? .null, "coursework": .null, "prerequisites": [], "language": "deutsch",
         "workload_h": 150, "source_page": 1]
    }

    static let catalog: JSONValue = [
        "v": 1, "university": "luh", "program": "Technische Informatik", "degree": "B.Sc.", "po": "2022",
        "catalog_term": "WS 2025/26", "code": "TIBSc22", "regular_semesters": 6, "total_lp": 180,
        "source": ["url": "https://modkat.example/x.pdf", "fetched_at": "t", "sha256": "x"],
        "areas": [["id": "a", "name": "Pflicht", "lp_required": 150, "kind": "pflicht"]],
        "modules": [
            mod("programmieren-1", "Programmieren I", sem: 1),
            mod("mathematik-1", "Mathematik I", sem: 1, exam: "Klausur 120 min"),
            mod("digitale-systeme", "Grundlagen digitaler Systeme", sem: 1),
            mod("algorithmen", "Algorithmen und Datenstrukturen", sem: 3),
            mod("datenbanken", "Grundlagen der Datenbanksysteme", sem: 3),
            mod("rechnernetze", "Rechnernetze", sem: 3, code: "4711"),
            mod("labor", "Labor Technische Informatik", sem: 3, exam: "VbP (Laborübung)"),
            mod("studium-generale", "Studium Generale", sem: 3, exam: "keine"),
            mod("bachelorarbeit", "Bachelorarbeit", sem: 3, kind: "abschluss"),
            mod("softwaretechnik", "Softwaretechnik", sem: 4, turnus: "SS"),
        ],
    ]

    /// Lokales Backend: Katalog, Noten (bestanden, nicht bestanden, AN), Klausur in Stud.IP, Info-Zeile aus dem QIS
    private func backend(now: String, catalog: Bool = true, university: String = "luh") async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: now)!, university: university)
        try await b.context.database.transaction { c in
            if catalog {
                _ = try StudyCatalogStore.store(c, payload: String(decoding: Self.catalog.serialized(), as: UTF8.self), texts: nil,
                                                origin: "fixture", now: "t")
            }
            try UniStore.storeGrades(c, [
                QISGrade(pruefungsnr: "1", text: "Programmieren I", semester: "WiSe 25/26", note: "1,7", status: "bestanden", credits: "5",
                         versuch: "1", abschluss: "Technische Informatik (PO-Version 2017)"),
                QISGrade(pruefungsnr: "2", text: "Mathematik I", semester: "WiSe 25/26", note: "5,0", status: "nicht bestanden", credits: "5",
                         versuch: "1", abschluss: "Technische Informatik (PO-Version 2017)"),
                QISGrade(pruefungsnr: "3", text: "Grundlagen der Datenbanksysteme", semester: "WiSe 26/27", status: "AN", versuch: "1",
                         abschluss: "Technische Informatik (PO-Version 2017)"),
            ], now: "t")
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Algorithmen und Datenstrukturen', '#4f5bd5', 't')")
            _ = try c.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES ('c-algo', 'Algorithmen und Datenstrukturen', 'vorlesung', 1, 1, 't')")
            _ = try c.execute("""
                INSERT INTO studip_events(id, course_id, title, start, end, room, description, cancelled, category, fetched_at)
                VALUES ('e1', 'c-algo', 'Klausur', '2027-02-15T09:00:00', '2027-02-15T11:00:00', 'HS A', '', 0, 'Klausur', 't')
                """)
            try QISRegistrationsSync.store(c, [QISRegistration(pruefungsnr: "4711", text: "Rechnernetze", semester: "WiSe 26/27",
                                                               datum: "01.03.2027", time: "09:00", status: "AN", raw: "")], now: "t")
        }
        return b
    }

    private func get(_ b: LocalBackend) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/exam-registration"))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json)
    }

    func testSuggestionsFromPlanWithReasonsDatesAndTicks() async throws {
        let v = try await get(try await backend(now: "2026-11-20T10:00:00"))
        XCTAssertEqual(v["supported"]?.bool, true)
        XCTAssertEqual(v["program"]?["slug"]?.string, "technische-informatik-bsc")
        XCTAssertEqual(v["program"]?["verified"]?.bool, true)
        XCTAssertEqual(v["term"]?.string, "WiSe 26/27")
        XCTAssertEqual(v["window"]?["phase"]?.string, "open")
        XCTAssertEqual(v["window"]?["days_left"]?.int, 2)
        XCTAssertEqual(v["show_card"]?.bool, true)
        XCTAssertEqual(v["periods"]?.array?.count, 6)
        let s = v["suggestions"]?.array ?? []
        XCTAssertEqual(s.compactMap { $0["id"]?.string }, ["algorithmen", "mathematik-1", "digitale-systeme", "labor", "rechnernetze", "datenbanken"],
                       "offene zuerst (mit Termin vorn), ohne Bestandenes, Abschlussarbeit, Pruefung 'keine' und anderes Semester")
        func one(_ id: String) -> JSONValue { s.first { $0["id"]?.string == id } ?? .null }
        XCTAssertEqual(one("algorithmen")["reason"]?.string, "laut deinem Plan im 3. Semester")
        XCTAssertEqual(one("algorithmen")["exam_date"]?.string, "2027-02-15")
        XCTAssertEqual(one("algorithmen")["exam_time"]?.string, "09:00")
        XCTAssertEqual(one("algorithmen")["exam_room"]?.string, "HS A")
        XCTAssertEqual(one("algorithmen")["withdraw_until"]?.string, "2027-02-08", "Klausur: 7 Tage vorher")
        XCTAssertEqual(one("algorithmen")["app_module_ids"], [1])
        XCTAssertEqual(one("mathematik-1")["reason_kind"]?.string, "wiederholung")
        XCTAssertEqual(one("mathematik-1")["reason"]?.string, "Wiederholung – 2. Versuch (nicht bestanden im WiSe 25/26)")
        XCTAssertEqual(one("digitale-systeme")["reason"]?.string, "nachholen – laut Plan im WiSe 25/26")
        XCTAssertEqual(one("labor")["period"]?.string, "vbp")
        XCTAssertEqual(one("labor")["withdraw_until"], .null)
        XCTAssertEqual(one("datenbanken")["registered_via"]?.string, "notenspiegel", "Vermerk AN im Notenspiegel")
        XCTAssertEqual(one("rechnernetze")["registered_via"]?.string, "qis_info", "Pruefungsnummer = Modulkuerzel")
        XCTAssertEqual(one("rechnernetze")["exam_date"]?.string, "2027-03-01", "Termin aus der Info-Seite")
        XCTAssertEqual(v["open_count"]?.int, 4)
        XCTAssertEqual(v["registered_count"]?.int, 2)
        XCTAssertEqual(v["warnings"]?.array?.compactMap { $0["text"]?.string },
                       ["Die Anmeldung endet in 2 Tagen. 3 geplante Prüfungen sind noch nicht angemeldet."])
        XCTAssertEqual(v["registered"]?.array?.count, 1)
        XCTAssertTrue(v["qis_url"]?.string?.hasPrefix("https://qis.verwaltung.uni-hannover.de/") == true)
    }

    func testCardOnlyAroundThePeriodAndFallbackWithoutPlan() async throws {
        let soon = try await get(try await backend(now: "2026-11-05T10:00:00"))
        XCTAssertEqual(soon["window"]?["phase"]?.string, "soon")
        XCTAssertEqual(soon["show_card"]?.bool, true)
        XCTAssertEqual(soon["warnings"]?.array?.count, 0)
        let later = try await get(try await backend(now: "2026-12-10T10:00:00"))
        XCTAssertEqual(later["window"]?["term"]?.string, "SoSe 27")
        XCTAssertEqual(later["show_card"]?.bool, false)
        // ohne Katalog: kommende Klausuren der eigenen Module, Studiengang aus dem QIS allein nicht eindeutig -> nur Link
        let noPlan = try await get(try await backend(now: "2026-11-20T10:00:00", catalog: false))
        XCTAssertEqual(noPlan["plan_available"]?.bool, false)
        XCTAssertEqual(noPlan["program"], .null)
        XCTAssertEqual(noPlan["window"], .null)
        XCTAssertEqual(noPlan["source"]?["url"]?.string, ExamRegistrationPeriods.luh.generalURL)
        XCTAssertEqual(noPlan["suggestions"]?.array?.compactMap { $0["title"]?.string }, ["Algorithmen und Datenstrukturen"])
        XCTAssertEqual(noPlan["suggestions"]?.array?.first?["reason_kind"]?.string, "klausur")
        // Uni Hildesheim: nicht unterstuetzt
        let hi = try await get(try await backend(now: "2026-11-20T10:00:00", catalog: false, university: "hildesheim"))
        XCTAssertEqual(hi["supported"]?.bool, false)
        XCTAssertEqual(hi["show_card"]?.bool, false)
    }

    func testEmptyDatabaseAnswers() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-10T10:00:00")!)
        let v = try await get(b)
        XCTAssertEqual(v["supported"]?.bool, true)
        XCTAssertEqual(v["suggestions"]?.array, [])
        XCTAssertEqual(v["registrations_checked_at"], .null)
    }

    // MARK: Erinnerungen

    func testRemindersSevenAndTwoDaysBeforeEnd() async throws {
        let v = try await get(try await backend(now: "2026-11-05T10:00:00"))
        let now = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!.now
        let plan = ExamRegistrationReminders.plan(v, container: "C1", now: now)
        XCTAssertEqual(plan.map(\.identifier), [
            "de.uniflow.ai.examreg.C1.wise-26-27.meldung1.start",
            "de.uniflow.ai.examreg.C1.wise-26-27.meldung1.d7",
            "de.uniflow.ai.examreg.C1.wise-26-27.meldung1.d2",
        ], "VbP ist vorbei; kein VbP-Fenster mit Fehlendem")
        let berlin = plan.map { r in UniFlowClock { r.fireAt }.nowISO }
        XCTAssertEqual(berlin, ["2026-11-09T09:00:00", "2026-11-15T09:00:00", "2026-11-20T09:00:00"])
        XCTAssertEqual(plan[2].title, "Prüfungsanmeldung endet übermorgen")
        XCTAssertEqual(plan[2].body, "WiSe 26/27: bis So, 22.11. · 3 Prüfungen laut Plan noch nicht angemeldet")
        XCTAssertEqual(plan[0].route, "#/studyplan")
        // spaeter: nur noch kuenftige
        let late = ExamRegistrationReminders.plan(v, container: "C1", now: UniFlowClock.fixed(berlin: "2026-11-16T10:00:00")!.now)
        XCTAssertEqual(late.map { $0.identifier.components(separatedBy: ".").last }, ["d2"])
        // Abgleich nimmt nur eigene Kennungen zurueck
        let d = ExamRegistrationReminders.diff(pending: ["de.uniflow.ai.examreg.C0.x", "de.uniflow.ai.due.C1.y", plan[0].identifier], planned: plan)
        XCTAssertEqual(d.remove, ["de.uniflow.ai.examreg.C0.x"])
        XCTAssertEqual(ExamRegistrationReminders.plan(["supported": false], container: "C1", now: now), [])
    }
}

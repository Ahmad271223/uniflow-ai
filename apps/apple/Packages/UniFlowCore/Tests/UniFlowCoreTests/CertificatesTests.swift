import Foundation
import XCTest
@testable import UniFlowCore

// Bescheinigungen (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md) gegen die Python-Referenz
// packages/shared-contracts/fixtures/certificates/cases.json (tools/gen-certificates-fixture.py, NACHGEBAUTE Seiten ohne
// Personen): Art und Semester aus dem Titel, Angebote der QIS-/LSF-Seiten und der HISinOne-Seite, Anzeige
// (GET /api/certificates). Dazu Abruf mit festen Antworten: LUH (Menue "Meine Bescheinigungen" und Notenspiegel-PDF),
// Hildesheim (LSF ohne Menue), HsH (HISinOne-Zeilen mit Semesterauswahl), abgelaufene Sitzung, genau ein Aufruf je
// Herunterladen, Zwischenseite, Speichern mit Datum, kein asi im Speicher. Dazu die ECHTE Seite "Meine Bescheinigungen"
// der LUH vom 10.11.2026 (fixtures/certificates/qis-echt-bescheinigungen.html, nur gelesen, anonymisiert).

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/certificates/cases.json")))
}

private func json(_ o: CertificateOffer) -> JSONValue {
    func s(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
    return ["id": .string(o.id), "title": .string(o.title), "kind": .string(o.kind.rawValue), "kinds": .array(o.kinds.map { .string($0.rawValue) }),
            "semester": s(o.semester), "semesters": .array(o.semesters.map { ["value": .string($0.value), "label": .string($0.label)] }),
            "source": .string(o.source), "portal": .string(o.portal), "address": s(o.address), "confirmed": .bool(o.confirmed)]
}

/// Adressen vergleichen ohne Prozentkodierung (Swift kodiert |, Leerzeichen, Umlaute; Python laesst sie stehen)
private func normalized(_ v: JSONValue?) -> JSONValue? {
    guard case .object(var o)? = v else { return v }
    if let a = o["address"]?.string { o["address"] = .string(a.removingPercentEncoding ?? a) }
    return .object(o)
}

final class CertificatesTests: XCTestCase {
    private let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })

    // MARK: Regeln wie Python

    func testTextRulesMatchPython() throws {
        let fx = try fixture()
        for c in fx["kinds"]?.array ?? [] {
            XCTAssertEqual(CertificateText.kinds(c["title"]?.string ?? "").map(\.rawValue), c["kinds"]?.array?.compactMap(\.string), "\(c)")
        }
        for (k, v) in fx["kind_labels"]?.object ?? [:] {
            XCTAssertEqual(CertificateKind(rawValue: k)?.label, v.string)
        }
        for c in fx["semester"]?.array ?? [] {
            XCTAssertEqual(CertificateText.semester(c["text"]?.string ?? ""), c["semester"]?.string, "\(c)")
        }
        for c in fx["clean_title"]?.array ?? [] {
            XCTAssertEqual(CertificateText.cleanTitle(c["raw"]?.string ?? ""), c["title"]?.string, "\(c)")
        }
        for c in fx["offer_id"]?.array ?? [] {
            XCTAssertEqual(CertificateText.offerID(university: c["university"]?.string ?? "", locator: c["locator"]?.string ?? ""), c["id"]?.string)
        }
    }

    func testQISOffersMatchPython() throws {
        let fx = try fixture()
        let pages = fx["qis"]?.array ?? []
        XCTAssertEqual(pages.count, 4)
        for p in pages {
            let url = try XCTUnwrap(URL(string: p["url"]?.string ?? ""))
            let got = CertificateParser.qisOffers(html: p["html"]?.string ?? "", url: url, source: p["source"]?.string ?? "",
                                                  university: p["university"]?.string ?? "", confirmed: p["confirmed"]?.bool ?? false)
            let want = p["offers"]?.array ?? []
            XCTAssertEqual(got.count, want.count, p["name"]?.string ?? "")
            for (g, w) in zip(got, want) {
                XCTAssertNil(jsonDiff(normalized(json(g)), normalized(w)), "\(p["name"]?.string ?? ""): \(jsonDiff(normalized(json(g)), normalized(w)) ?? "")")
                XCTAssertFalse((g.address ?? "").contains("asi="), "kein Sitzungsparameter im Speicher")
                XCTAssertFalse((g.address ?? "").lowercased().contains("jsessionid"))
            }
        }
        // LUH: Immatrikulationsbescheinigung deckt § 9 BAföG mit ab; verifizierbar-Link ist kein Dokument
        let luh = pages[0]["offers"]?.array ?? []
        XCTAssertEqual(luh.first?["kinds"]?.array?.compactMap(\.string), ["immatrikulation", "bafoeg"])
        XCTAssertFalse(luh.contains { ($0["address"]?.string ?? "").contains("state=verify") })
        XCTAssertTrue((pages[3]["offers"]?.array ?? []).isEmpty, "LSF Hildesheim ohne Bescheinigungen")
    }

    func testHISinOneOffersMatchPython() throws {
        let fx = try fixture()
        for p in fx["hisinone"]?.array ?? [] {
            let html = p["html"]?.string ?? ""
            let got = CertificateParser.hisinoneOffers(html: html, university: p["university"]?.string ?? "hsh").map(json)
            XCTAssertNil(jsonDiff(.array(got), p["offers"]), "\(p["name"]?.string ?? ""): \(jsonDiff(.array(got), p["offers"]) ?? "")")
            let rows = CertificateParser.hisinoneRows(html: html)
            let wantRows = p["rows"]?.array ?? []
            XCTAssertEqual(rows.count, wantRows.count)
            for (r, w) in zip(rows, wantRows) {
                XCTAssertEqual(r.title, w["title"]?.string)
                XCTAssertEqual(r.semester, w["semester"]?.string)
                XCTAssertEqual(r.action.href, w["href"]?.string)
                XCTAssertEqual(r.action.button?.name, w["button"]?.array?.first?.string)
                XCTAssertEqual(r.action.button?.value, w["button"]?.array?.last?.string)
            }
            let sel = CertificateParser.hisinoneSemesters(html: html)
            XCTAssertEqual(sel?.name, p["select"]?["name"]?.string)
            XCTAssertEqual(sel?.options.map(\.label) ?? [], (p["select"]?["options"]?.array ?? []).compactMap { $0["label"]?.string })
            let jobs = CertificateParser.hisinoneJobButtons(html: html)
            XCTAssertEqual(jobs.map(\.title), (p["jobs"]?.array ?? []).compactMap { $0["title"]?.string })
            XCTAssertEqual(jobs.map(\.name), (p["jobs"]?.array ?? []).compactMap { $0["name"]?.string })
            XCTAssertEqual(CertificateParser.hisinonePoll(html: html), p["poll"]?.string)
            XCTAssertEqual(CertificateParser.isReportTab(html: html), p["report_tab"]?.bool)
        }
    }

    func testSummaryMatchesPython() async throws {
        let fx = try fixture()
        for c in fx["summary"]?.array ?? [] {
            let uni = c["university"]?.string ?? ""
            let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-06T10:00:00")!, university: uni)
            let state = try JSONDecoder().decode(CertificateState.self, from: (c["state"] ?? .null).serialized())
            try await backend.context.database.withConnection { try CertificatesSync.save($0, state) }
            let r = await backend.handle(LocalRequest(method: "GET", path: "/api/certificates"))
            XCTAssertEqual(r.status, 200)
            guard case .object(var got)? = r.json else { return XCTFail("kein JSON") }
            XCTAssertEqual(got["documents"], .array([]))
            got["documents"] = nil
            XCTAssertNil(jsonDiff(.object(got), c["summary"]), "\(uni): \(jsonDiff(.object(got), c["summary"]) ?? "")")
        }
    }

    // MARK: Abruf mit festen Antworten

    private let luhBase = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
    private let asi = "FixSitzung1"

    private func luhPages(fx: JSONValue) -> (start: String, reports: String, studium: String, tree: String, list: String) {
        let logout = #"<a href="\#(luhBase)?state=user&amp;type=4&amp;category=auth.logout&amp;asi=\#(asi)">Abmelden</a>"#
        let start = """
            <html><body><h1>Meine Funktionen</h1>\(logout)
            <a href="\(luhBase)?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;nextdir=change&amp;next=menu.vm&amp;asi=\(asi)">Mein Studium</a>
            <a href="\(luhBase)?state=change&amp;type=1&amp;moduleParameter=studentReportsMenu&amp;next=menu.vm&amp;asi=\(asi)">Meine Bescheinigungen</a>
            <a href="\(luhBase)?state=info&amp;moduleParameter=prfAnmStudent&amp;asi=\(asi)">Prüfungsanmeldung/-abmeldung</a></body></html>
            """
        let studium = """
            <html><body><h1>Mein Studium</h1>\(logout)
            <a href="\(luhBase)?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;menuid=notenspiegelStudent&amp;asi=\(asi)">Notenspiegel / Studienverlauf</a></body></html>
            """
        let tree = """
            <html><body><h1>Notenspiegel</h1>\(logout)
            <a href="\(luhBase)?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=079&amp;asi=\(asi)" title="Leistungen für Informatik (PO-Version 2017) anzeigen">i</a></body></html>
            """
        let pages = fx["qis"]?.array ?? []
        return (start, pages[0]["html"]?.string ?? "", studium, tree, pages[1]["html"]?.string ?? "")
    }

    /// QIS der LUH mit festen Antworten; nur Seiten mit dem asi dieser Sitzung, sonst Anmeldeformular
    private func luhTransport(_ fx: JSONValue, loggedIn: Bool = true, pdf: @escaping (String) -> UniResponse = { _ in UniResponse(status: 200, body: Data("%PDF-1.4 Bescheinigung".utf8)) }) -> FakeUniTransport {
        let p = luhPages(fx: fx)
        let login = #"<html><body><form action="x"><input name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        return FakeUniTransport { [asi] r in
            let u = r.url.absoluteString.removingPercentEncoding ?? r.url.absoluteString
            guard loggedIn else { return ok(login) }
            if u == QISClient.startURL.absoluteString { return ok(p.start) }
            guard u.contains("asi=\(asi)") else { return ok(login) }
            if u.contains("state=verpublish") || u.contains("hisreports") { return pdf(u) }
            if u.contains("studentReportsMenu") { return ok(p.reports) }
            if u.contains("studyPOSMenu") { return ok(p.studium) }
            if u.contains("next=list.vm") { return ok(p.list) }
            if u.contains("state=notenspiegelStudent") { return ok(p.tree) }
            return UniResponse(status: 404)
        }
    }

    private func database(_ uni: String) async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-11-06T10:00:00")!, university: uni)
        return db
    }

    private func tempFiles() throws -> LocalFiles {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("besch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return LocalFiles(container: dir, dataDirectory: "Daten")
    }

    func testLUHListReadsMenusAndNotenspiegelWithoutCreatingAnyDocument() async throws {
        let fx = try fixture()
        let t = luhTransport(fx)
        let db = try await database("luh")
        let clock = UniFlowClock.fixed(berlin: "2026-11-06T10:00:00")!
        let r = await CertificatesSync.refresh(db: db, transport: t, clock: clock, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.offers, 3, "eine Bescheinigung im Menue (live wie gesehen), zwei PDFs am Notenspiegel")
        let seen = t.requests.map { $0.url.absoluteString }
        XCTAssertFalse(seen.contains { $0.contains("verpublish") }, "die Liste erzeugt nie ein Dokument")
        XCTAssertFalse(seen.contains { $0.contains("prfAnm") || $0.contains("logout") }, "nie Pruefungsanmeldung, nie abmelden")
        let state = try await db.withConnection { try CertificatesSync.load($0) }
        XCTAssertEqual(state?.status, "ok")
        XCTAssertEqual(state?.checkedAt, clock.nowISO)
        XCTAssertEqual(state?.offers.map(\.source), ["bescheinigungen", "notenspiegel", "notenspiegel"])
        XCTAssertEqual(state?.offers.map(\.confirmed), [true, false, false], "Menue live bestaetigt, Notenspiegel-PDF noch nicht")
        let raw = try await db.withConnection { try $0.scalar("SELECT value FROM settings WHERE key='certificates'")?.string ?? "" }
        XCTAssertFalse(raw.contains(asi), "kein asi in der Datenbank")
        let summary = try await db.withConnection { try CertificatesSync.summary($0, files: nil) }
        let offered = (summary["kinds"]?.array ?? []).filter { $0["offered"]?.bool == true }.compactMap { $0["key"]?.string }
        XCTAssertEqual(offered, ["immatrikulation", "bafoeg", "notenspiegel"], "LUH: kein Datenkontrollblatt und keine Rueckmeldebescheinigung im QIS")
    }

    /// 11.11.2026: die Liste laeuft jetzt in jedem Sync; ein Menue-Link mit "Bescheinigung" im Text, der selbst ein
    /// Dokument erzeugt (hisreports, PDF), wird nie aufgerufen (vorher nur verpublish/verify ausgeschlossen)
    func testListNeverFollowsALinkThatCreatesADocument() {
        let base = "https://qis.verwaltung.uni-hannover.de/qisserver/rds?"
        func link(_ text: String, _ query: String) -> QISLink {
            QISLink(text: text, address: base + query, parameters: QISParser.parameters(of: base + query))
        }
        XCTAssertEqual(CertificateClient.menuPriority(link("Meine Bescheinigungen", "state=change&type=1&moduleParameter=studentReportsMenu")), 0)
        XCTAssertNil(CertificateClient.menuPriority(link("Studienbescheinigung", "state=hisreports&publishSubDir=x")))
        XCTAssertNil(CertificateClient.menuPriority(link("Studienbescheinigung", "state=verpublish&status=transform")))
        XCTAssertNil(CertificateClient.menuPriority(link("Bescheinigung (PDF)", "state=change&file=bescheinigung.pdf")))
        XCTAssertNil(CertificateClient.menuPriority(link("Bescheinigung prüfen", "state=verify&x=1")))
    }

    func testDownloadCallsTheLinkExactlyOnceAndStoresTheCopyWithDate() async throws {
        let fx = try fixture()
        let calls = Counter()
        let t = luhTransport(fx) { _ in calls.add(); return UniResponse(status: 200, body: Data("%PDF-1.4 Studienbescheinigung".utf8)) }
        let db = try await database("luh")
        let files = try tempFiles()
        _ = await CertificatesSync.refresh(db: db, transport: t, retry: noWait)
        let state = try await db.withConnection { try CertificatesSync.load($0) }
        let enrolment = try XCTUnwrap(state?.offers.first { $0.kind == .immatrikulation })
        let clock = UniFlowClock.fixed(berlin: "2026-11-06T14:03:00")!
        let r = await CertificatesSync.download(db: db, files: files, transport: t, offerID: enrolment.id, clock: clock, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(calls.value, 1, "genau ein Aufruf (jeder erzeugt im QIS ein Dokument)")
        let url = try XCTUnwrap(r.file)
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.4 Studienbescheinigung".utf8))
        XCTAssertTrue(url.path.contains("/Daten/qis/"), url.path)
        let summary = try await db.withConnection { try CertificatesSync.summary($0, files: files) }
        let row = try XCTUnwrap(summary["offers"]?.array?.first { $0["id"]?.string == enrolment.id })
        XCTAssertEqual(row["file"]?["fetched_at"]?.string, clock.nowISO, "Stand = Datum des Abrufs")
        XCTAssertEqual(row["file"]?["url"]?.string, "/api/certificates/\(enrolment.id)/file")
        // Notenspiegel-PDF: ueber den Weg zum Notenspiegel, wieder genau ein Aufruf
        let grades = try XCTUnwrap(state?.offers.first { $0.kind == .notenspiegel })
        let r2 = await CertificatesSync.download(db: db, files: files, transport: t, offerID: grades.id, retry: noWait)
        XCTAssertTrue(r2.ok, r2.message)
        XCTAssertEqual(calls.value, 2)
        // ueber das lokale Backend
        let backend = try LocalBackend(database: db, files: files)
        let file = await backend.handle(LocalRequest(method: "GET", path: "/api/certificates/\(enrolment.id)/file"))
        XCTAssertEqual(file.status, 200)
        XCTAssertEqual(file.headers["Content-Type"], "application/pdf")
        XCTAssertEqual(file.body, Data("%PDF-1.4 Studienbescheinigung".utf8))
        let missing = await backend.handle(LocalRequest(method: "GET", path: "/api/certificates/000000000000/file"))
        XCTAssertEqual(missing.status, 404)
    }

    func testIntermediatePageIsFollowedOnceAndHTMLIsNeverStoredAsPDF() async throws {
        let fx = try fixture()
        let calls = Counter()
        let t = luhTransport(fx) { u in
            calls.add()
            if u.contains("hisreports") { return UniResponse(status: 200, body: Data("%PDF-1.4 ok".utf8)) }
            if u.contains("moduleCall=Leistungen") { return ok(#"<html><body><a href="x?state=user&amp;type=4&amp;category=auth.logout">Abmelden</a>Fehler</body></html>"#) }
            return ok(#"<html><head><meta http-equiv="refresh" content="0; url=/qisserver/hisreports/doc.pdf?asi=FixSitzung1"></head><body><a href="x?state=user&amp;type=4&amp;category=auth.logout">Abmelden</a></body></html>"#)
        }
        let db = try await database("luh")
        let files = try tempFiles()
        _ = await CertificatesSync.refresh(db: db, transport: t, retry: noWait)
        let offers = try await db.withConnection { try CertificatesSync.load($0)?.offers ?? [] }
        let de = try XCTUnwrap(offers.first { $0.title.hasPrefix("Studienzeit") })
        let r = await CertificatesSync.download(db: db, files: files, transport: t, offerID: de.id, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(calls.value, 2, "Dokument und einmal der PDF-Link der Zwischenseite")
        let en = try XCTUnwrap(offers.first { $0.title.contains("Leistungen") })
        let bad = await CertificatesSync.download(db: db, files: files, transport: t, offerID: en.id, retry: noWait)
        XCTAssertFalse(bad.ok)
        XCTAssertNil(bad.file)
        let summary = try await db.withConnection { try CertificatesSync.summary($0, files: files) }
        XCTAssertEqual(summary["offers"]?.array?.first { $0["id"]?.string == en.id }?["file"], .null, "nichts gespeichert")
    }

    // MARK: echte Seiten der LUH (10.11.2026, nur gelesen, anonymisiert)

    private func echt(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/\(name)"), encoding: .utf8)
    }

    /// QIS der LUH mit den echten Seiten: Startseite und "Meine Bescheinigungen" ohne asi (Sitzung per Cookie), "Mein
    /// Studium" mit asi. Die Seite hinter "Notenspiegel" ist nachgebaut (leer). Alles andere gibt es nicht (404).
    private func echtTransport(pdf: @escaping (String) -> UniResponse) throws -> FakeUniTransport {
        let start = try echt("exam-registration/qis-echt-start.html")
        let reports = try echt("certificates/qis-echt-bescheinigungen.html")
        let studium = try echt("exam-registration/qis-echt-studium.html")
        let grades = #"<html><body><a href="?state=user&amp;type=4&amp;category=auth.logout">Logout</a><h1>Notenspiegel</h1></body></html>"#
        return FakeUniTransport { r in
            let u = r.url.absoluteString.removingPercentEncoding ?? r.url.absoluteString
            if u == QISClient.startURL.absoluteString { return ok(start, url: u) }
            if u.contains("prfAnm") || u.contains("type=4") || u.contains("state=verify") || u.contains("hisreports") { return UniResponse(status: 404) }
            if u.contains("state=verpublish") { return pdf(u) }
            if u.contains("moduleParameter=studentReportsMenu") { return ok(reports, url: u) }
            if u.contains("moduleParameter=studyPOSMenu") { return ok(studium, url: u) }
            if u.contains("state=notenspiegelStudent") { return ok(grades, url: u) }
            return UniResponse(status: 404)
        }
    }

    func testRealLUHPageOffersGermanAndEnglishCertificate() async throws {
        let calls = Counter()
        let t = try echtTransport { _ in calls.add(); return UniResponse(status: 200, body: Data("%PDF-1.4 echt".utf8)) }
        let db = try await database("luh")
        let files = try tempFiles()
        let clock = UniFlowClock.fixed(berlin: "2026-11-10T18:00:00")!
        let r = await CertificatesSync.refresh(db: db, transport: t, clock: clock, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.offers, 2, "deutsch und englisch, jeder Link steht zweimal auf der Seite")
        XCTAssertEqual(calls.value, 0, "die Liste erzeugt nie ein Dokument")
        let seen = t.requests.map { $0.url.absoluteString }
        XCTAssertFalse(seen.contains { $0.contains("verpublish") || $0.contains("state=verify") || $0.contains("hisreports") })
        XCTAssertFalse(seen.contains { $0.contains("prfAnm") || $0.contains("logout") || $0.contains("type=4") }, "nie Pruefungsanmeldung, nie abmelden")
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" && $0.body == nil }, "nur lesen")
        let offers = try await db.withConnection { try CertificatesSync.load($0)?.offers ?? [] }
        XCTAssertEqual(offers.map(\.title), ["Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG",
                                             "Certificate of study period and enrolment / Certificate in accordance with § 9 BAföG"])
        XCTAssertEqual(offers.map(\.id), ["d595729c4608", "c93f794f4b7b"], "dieselben Kennungen wie in Python")
        XCTAssertEqual(offers.map(\.kinds), [[.immatrikulation, .bafoeg], [.immatrikulation, .bafoeg]])
        XCTAssertEqual(offers.map(\.source), ["bescheinigungen", "bescheinigungen"])
        XCTAssertEqual(offers.map(\.confirmed), [true, true])
        XCTAssertTrue((offers.first?.address ?? "").hasSuffix("?state=verpublish&publishContainer=bafoegbescheinigung&menuid=bafoeg"))
        XCTAssertTrue((offers.last?.address ?? "").hasSuffix("?state=verpublish&publishContainer=studienbescheinigungEN&menuid=studbeschEN"))
        let summary = try await db.withConnection { try CertificatesSync.summary($0, files: files) }
        XCTAssertEqual(summary["status"]?.string, "ok")
        XCTAssertEqual(summary["offers"]?.array?.count, 2)
        let offered = (summary["kinds"]?.array ?? []).filter { $0["offered"]?.bool == true }.compactMap { $0["key"]?.string }
        XCTAssertEqual(offered, ["immatrikulation", "bafoeg"])
        // Herunterladen: je Dokument genau ein Aufruf des eigenen Links, auch fuer die englische Fassung
        for (i, o) in offers.enumerated() {
            let before = t.requests.count
            let d = await CertificatesSync.download(db: db, files: files, transport: t, offerID: o.id, clock: clock, retry: noWait)
            XCTAssertTrue(d.ok, d.message)
            XCTAssertEqual(calls.value, i + 1, "genau ein Aufruf (jeder erzeugt im QIS ein Dokument)")
            let called = t.requests[before...].map { $0.url.absoluteString }.filter { $0.contains("verpublish") }
            XCTAssertEqual(called.count, 1)
            XCTAssertTrue(called.first?.contains(i == 0 ? "publishContainer=bafoegbescheinigung" : "publishContainer=studienbescheinigungEN") == true, "\(called)")
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(d.file)), Data("%PDF-1.4 echt".utf8))
        }
        let all = t.requests.map { $0.url.absoluteString }
        XCTAssertFalse(all.contains { $0.contains("state=verify") || $0.contains("prfAnm") || $0.contains("logout") || $0.contains("type=4") })
    }

    func testExpiredSessionAsksForLoginAndKeepsTheList() async throws {
        let fx = try fixture()
        let db = try await database("luh")
        _ = await CertificatesSync.refresh(db: db, transport: luhTransport(fx), retry: noWait)
        let r = await CertificatesSync.refresh(db: db, transport: luhTransport(fx, loggedIn: false), retry: noWait)
        XCTAssertTrue(r.needsLogin)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message, "Anmeldung bei QIS abgelaufen. Bitte neu anmelden.")
        let state = try await db.withConnection { try CertificatesSync.load($0) }
        XCTAssertEqual(state?.status, "login")
        XCTAssertEqual(state?.offers.count, 3, "die zuletzt gelesene Liste bleibt")
        let first = try XCTUnwrap(state?.offers.first)
        let files = try tempFiles()
        let d = await CertificatesSync.download(db: db, files: files, transport: luhTransport(fx, loggedIn: false), offerID: first.id, retry: noWait)
        XCTAssertTrue(d.needsLogin)
    }

    /// HISinOne mit Berichtsknoepfen (HsH-Campusmanagement bzw. PLuS): Knopf einmal absenden, dann den Poll des
    /// Hintergrundauftrags abfragen, bis der PDF-Link kommt, und den Link einmal laden
    private func jobPortal(page: String, host: String, polls: Int = 2) -> (FakeUniTransport, Box) {
        let log = Box()
        let pollCount = Counter()
        let t = FakeUniTransport { r in
            let u = r.url.absoluteString
            guard r.url.host == host else { return UniResponse(status: 404, finalURL: r.url) }
            if r.method == "POST" {
                let body = String(decoding: r.body ?? Data(), as: UTF8.self)
                if body.contains("job2") { log.append("job"); return ok(page, url: u) }
                if body.contains("javax.faces.partial.ajax=true") {
                    log.append("poll")
                    pollCount.add()
                    if pollCount.value < polls { return ok("<partial-response><changes><update id=\"x\"><![CDATA[<span>läuft</span>]]></update></changes></partial-response>", url: u) }
                    return ok("<partial-response><changes><update id=\"x\"><![CDATA[<a href=\"/qisserver/pages/cm/exa/report/download.faces?job=ERFUNDEN\">PDF herunterladen</a>]]></update></changes></partial-response>", url: u)
                }
                return ok(page, url: u)
            }
            if u.contains("download.faces") { log.append("pdf"); return UniResponse(status: 200, finalURL: r.url, body: Data("%PDF-1.4 Bericht".utf8)) }
            if u.contains("studyservice-flow") { return ok(page, url: u) }
            if u.contains("qis_meine_funktionen") { return ok(#"<html><body><a href="/qisserver/rds?state=user&amp;type=3&amp;category=auth.logout">Abmelden</a></body></html>"#, url: u) }
            return UniResponse(status: 404, finalURL: r.url)
        }
        return (t, log)
    }

    func testHildesheimReadsPLuSNotTheLSFAndDownloadsViaBackgroundJob() async throws {
        let fx = try fixture()
        let page = fx["hisinone"]?.array?[3]["html"]?.string ?? ""
        let (t, log) = jobPortal(page: page, host: "plus.uni-hildesheim.de")
        let db = try await database("hildesheim")
        let r = await CertificatesSync.refresh(db: db, transport: t, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.offers, 8)
        XCTAssertTrue(t.requests.allSatisfy { $0.url.host == "plus.uni-hildesheim.de" }, "nur PLuS, nie das LSF")
        XCTAssertTrue(t.requests.first?.url.absoluteString.contains("initialTab=showTabReport") ?? false)
        XCTAssertFalse(t.requests.contains { $0.method == "POST" }, "die Liste schickt nichts ab (Reiter schon offen)")
        let s = try await db.withConnection { try CertificatesSync.summary($0, files: nil) }
        XCTAssertEqual(s["portal"]?.string, "PLuS")
        let offered = (s["kinds"]?.array ?? []).filter { $0["offered"]?.bool == true }.compactMap { $0["key"]?.string }
        XCTAssertEqual(offered, ["immatrikulation", "bafoeg"])
        let offers = try await db.withConnection { try CertificatesSync.load($0)?.offers ?? [] }
        let imm = try XCTUnwrap(offers.first { $0.title == "Immatrikulationsbescheinigung" })
        XCTAssertTrue(imm.confirmed)
        let files = try tempFiles()
        let d = await CertificatesSync.download(db: db, files: files, transport: t, offerID: imm.id, retry: noWait, pollDelayNanos: 0)
        XCTAssertTrue(d.ok, d.message)
        XCTAssertEqual(log.items, ["job", "poll", "poll", "pdf"], "ein Auftrag, Abfragen bis zum Link, Link einmal")
    }

    func testHsHJobButtonsAreReadDynamicallyAndHiddenSessionBlockIsIgnored() async throws {
        let fx = try fixture()
        let page = fx["hisinone"]?.array?[2]["html"]?.string ?? ""
        XCTAssertTrue(page.contains("Ihre Sitzung ist aus Sicherheitsgründen abgelaufen"), "versteckter Block steht auf der Seite")
        let (t, log) = jobPortal(page: page, host: "campusmanagement.hs-hannover.de", polls: 1)
        let db = try await database("hsh")
        let r = await CertificatesSync.refresh(db: db, transport: t, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        let offers = try await db.withConnection { try CertificatesSync.load($0)?.offers ?? [] }
        XCTAssertEqual(offers.count, 7)
        XCTAssertFalse(offers.contains { $0.kind == .immatrikulation }, "steht bei diesem Konto nicht in der Liste: nichts erfunden")
        let grades = try XCTUnwrap(offers.first { $0.title == "Bescheinigung über angemeldete Prüfungen" })
        let files = try tempFiles()
        let d = await CertificatesSync.download(db: db, files: files, transport: t, offerID: grades.id, retry: noWait, pollDelayNanos: 0)
        XCTAssertTrue(d.ok, d.message)
        XCTAssertEqual(log.items, ["job", "poll", "pdf"])
        // abgemeldet (IdP statt Campusmanagement): Anmeldung noetig
        let expired = FakeUniTransport { r in UniResponse(status: 200, finalURL: URL(string: "https://idp.hs-hannover.de/simplesaml/x"), body: Data("<html>Login</html>".utf8)) }
        let e = await CertificatesSync.refresh(db: db, transport: expired, retry: noWait)
        XCTAssertTrue(e.needsLogin)
        XCTAssertEqual(e.message, "Anmeldung bei Campusmanagement abgelaufen. Bitte neu anmelden.")
    }

    func testHsHRowsWithSemesterChoicePostTheRowButtonOnce() async throws {
        let fx = try fixture()
        let page = fx["hisinone"]?.array?[1]["html"]?.string ?? ""
        let campus = "https://campusmanagement.hs-hannover.de"
        let posts = Box()
        let t = FakeUniTransport { r in
            let u = r.url.absoluteString
            if r.method == "POST" {
                let body = String(decoding: r.body ?? Data(), as: UTF8.self)
                if body.contains("table%3A0%3Aprint") || body.contains("table:0:print") { posts.append(body); return UniResponse(status: 200, finalURL: r.url, body: Data("%PDF-1.7 HsH".utf8)) }
                return ok(page, url: u)
            }
            if u.contains("studyservice-flow") { return ok(page, url: u) }
            if u.contains("qis_meine_funktionen") { return ok(#"<html><body><a href="/qisserver/rds?state=user&amp;type=3&amp;category=auth.logout">Abmelden</a></body></html>"#, url: u) }
            if u.hasPrefix(campus) { return UniResponse(status: 404, finalURL: r.url) }
            return UniResponse(status: 404)
        }
        let db = try await database("hsh")
        let r = await CertificatesSync.refresh(db: db, transport: t, retry: noWait)
        XCTAssertTrue(r.ok, r.message)
        let offers = try await db.withConnection { try CertificatesSync.load($0)?.offers ?? [] }
        XCTAssertEqual(offers.map(\.title), ["Immatrikulationsbescheinigung", "BAföG-Bescheinigung nach § 9", "Datenkontrollblatt", "Beitragsbescheid Wintersemester 2026/27"])
        XCTAssertTrue(offers.allSatisfy { !$0.confirmed }, "HsH: Aufbau nicht am echten Konto bestaetigt")
        let imm = try XCTUnwrap(offers.first)
        XCTAssertEqual(imm.semesters.map(\.label), ["WiSe 2026/27", "SoSe 2026"])
        let files = try tempFiles()
        let d = await CertificatesSync.download(db: db, files: files, transport: t, offerID: imm.id, semester: "2026_1", retry: noWait)
        XCTAssertTrue(d.ok, d.message)
        XCTAssertEqual(posts.items.count, 1, "genau ein Absenden des Knopfs")
        let body = posts.items.first ?? ""
        XCTAssertTrue(body.contains("javax.faces.ViewState=e1s2-ERFUNDEN"), body)
        XCTAssertTrue(body.contains("studyServiceForm%3AtermSelect=2026_1"), body)
        let s = try await db.withConnection { try CertificatesSync.summary($0, files: files) }
        XCTAssertEqual(s["offers"]?.array?.first?["file"]?["semester"]?.string, "SoSe 2026")
    }
}

/// Zaehler fuer Aufrufe aus dem Transport (Sendable)
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

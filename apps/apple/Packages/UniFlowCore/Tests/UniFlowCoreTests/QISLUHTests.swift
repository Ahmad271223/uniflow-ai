import Foundation
import XCTest
@testable import UniFlowCore

/// Noten aus dem QIS der LUH auf dem Geraet (`QISClient`, `QISGradesSync`) mit erfundenen Seiten (Rechner
/// qis.verwaltung.uni-hannover.de, Person "Erika Beispiel", Sitzung "S1"): Leistungen, leerer Notenspiegel, abgelaufene
/// Sitzung, Stammdaten und asi nie gespeichert, Bescheinigungen nie aufgerufen.
final class QISLUHTests: XCTestCase {
    private let base = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
    private let asi = "S1abcDEF"
    private let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })

    private var logout: String { #"<a href="\#(base)?state=user&amp;type=4&amp;category=auth.logout&amp;asi=\#(asi)">Abmelden</a>"# }

    private var loginPage: String {
        """
        <html><body><h1>Anmeldung</h1>
        <form action="\(base)?state=user&amp;type=1" method="post">
        <input type="text" name="asdf"><input type="password" name="fdsa"><input type="submit" value="Anmelden"></form></body></html>
        """
    }

    private var startPage: String {
        """
        <html><body><h1>Meine Funktionen</h1>\(logout)
        <ul><li><a href="\(base)?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;nextdir=change&amp;next=menu.vm&amp;asi=\(asi)">Mein Studium</a></li>
        <li><a href="\(base)?state=change&amp;type=1&amp;moduleParameter=studentReportsMenu&amp;asi=\(asi)">Meine Bescheinigungen</a></li></ul></body></html>
        """
    }

    private var studiumPage: String {
        """
        <html><body><h1>Mein Studium</h1>\(logout)
        <a href="\(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;menuid=notenspiegelStudent&amp;asi=\(asi)">Notenspiegel / Studienverlauf</a>
        <a href="\(base)?state=notenspiegelStudent&amp;next=studienverlauf.vm&amp;asi=\(asi)">Studienverlauf</a></body></html>
        """
    }

    /// Stammdaten stehen auf jeder Notenspiegel-Seite: nie lesen
    private var stammdaten: String {
        """
        <table summary="Stammdaten"><tr><th>Name</th><td>Erika Beispiel</td></tr><tr><th>Geburtsdatum</th><td>02.02.2002</td></tr>
        <tr><th>Matrikelnummer</th><td>7654321</td></tr><tr><th>Anschrift</th><td>Beispielweg 1, 30159 Hannover</td></tr></table>
        """
    }

    private var treePage: String {
        """
        <html><body><h1>Notenspiegel</h1>\(logout)\(stammdaten)
        <ul><li><a href="\(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;nodeID=auswahlBaum|abschluss:abschl=82&amp;expand=0&amp;asi=\(asi)">Abschluss 82 Bachelor of Science</a></li></ul>
        </body></html>
        """
    }

    private var expandedPage: String {
        """
        <html><body><h1>Notenspiegel</h1>\(logout)\(stammdaten)
        <ul><li><a href="\(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;nodeID=auswahlBaum|abschluss:abschl=82&amp;expand=0&amp;asi=\(asi)">Abschluss 82 Bachelor of Science</a>
        <ul><li>Informatik (PO-Version 2017)
        <a href="\(base)?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=079&amp;asi=\(asi)" title="Leistungen für Informatik (PO-Version 2017) anzeigen"><img src="info.gif" alt="Leistungen für Informatik (PO-Version 2017) anzeigen"></a></li></ul></li></ul>
        </body></html>
        """
    }

    private func listPage(rows: String) -> String {
        """
        <html><body><h1>Notenspiegel</h1>\(logout)\(stammdaten)
        <p><a href="\(base)?state=verpublish&amp;status=transform&amp;moduleCall=Notenspiegel&amp;publishConfFile=reports&amp;asi=\(asi)">PDF-Notenspiegel zum Drucken</a></p>
        <table><tr><th>Prüfungsnr</th><th>Prüfungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th><th>Versuch</th><th>Datum</th></tr>
        \(rows)</table></body></html>
        """
    }

    private let twoGrades = """
        <tr><td>1001</td><td>Mathematik I</td><td>WiSe 26/27</td><td>2,0</td><td>bestanden</td><td>8</td><td>1</td><td>12.02.2027</td></tr>
        <tr><td>1002</td><td>Programmieren</td><td>WiSe 26/27</td><td>1,3</td><td>bestanden</td><td>6</td><td>1</td><td>20.02.2027</td></tr>
        """

    /// QIS mit festen Antworten: ohne asi nur die Startseite; alle anderen Seiten brauchen den asi dieser Sitzung
    private func qis(list: String, loggedIn: Bool = true) -> FakeUniTransport {
        let start = QISClient.startURL.absoluteString
        return FakeUniTransport { [asi, loginPage, startPage, studiumPage, treePage, expandedPage] r in
            let u = r.url.absoluteString
            guard loggedIn else { return ok(loginPage) }
            if u == start { return ok(startPage) }
            guard u.contains("asi=\(asi)") else { return ok(loginPage) }
            if u.contains("moduleParameter=studyPOSMenu") { return ok(studiumPage) }
            if u.contains("state=verpublish") { return UniResponse(status: 200, body: Data("%PDF-1.4 nie".utf8)) }
            if u.contains("next=list.vm") { return ok(list) }
            if u.contains("nodeID=auswahlBaum") { return ok(expandedPage) }
            if u.contains("state=notenspiegelStudent") { return ok(treePage) }
            return UniResponse(status: 404)
        }
    }

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)), university: "luh")
        return db
    }

    private func forbidden(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for secret in ["Erika", "Beispiel", "02.02.2002", "7654321", "Beispielweg", "30159", "Matrikel", "Geburtsdatum", asi] {
            XCTAssertFalse(text.contains(secret), "\(what) enthaelt \(secret)", file: file, line: line)
        }
    }

    // MARK: Leistungen

    func testFollowsStartToLeistungenAndReadsOnlyTheGradeTable() async throws {
        let t = qis(list: listPage(rows: twoGrades))
        let r = try await QISClient(transport: t, retry: noWait).fetch()
        XCTAssertEqual(r.grades.map(\.text), ["Mathematik I", "Programmieren"])
        XCTAssertEqual(r.grades.map(\.note), ["2,0", "1,3"])
        XCTAssertEqual(r.grades.first?.semester, "WiSe 26/27")
        XCTAssertEqual(r.grades.first?.credits, "8")
        XCTAssertEqual(r.grades.first?.datum, "12.02.2027")
        XCTAssertEqual(r.grades.first?.abschluss, "Informatik (PO-Version 2017)", "Studiengang aus dem Link wie qis.py")
        XCTAssertEqual(r.pages, 5, "Start, Mein Studium, Notenspiegel, Abschluss, Leistungen")
        XCTAssertEqual(r.gradeTables, 1)
        XCTAssertEqual(r.documents.count, 1, "Bescheinigungs-Link nur gezaehlt")
        let seen = t.requests.map { $0.url.absoluteString }
        XCTAssertFalse(seen.contains { $0.contains("verpublish") }, "nie eine Bescheinigung aufrufen")
        XCTAssertFalse(seen.contains { $0.contains("type=4") || $0.contains("logout") }, "nie abmelden")
        XCTAssertFalse(seen.contains { $0.contains("studienverlauf") }, "Studienverlauf wird fuer Noten nicht gebraucht")
        XCTAssertTrue(seen.dropFirst().allSatisfy { $0.contains("asi=\(asi)") }, "Folgeseiten mit der Sitzung der Seite")
        for g in r.grades { forbidden(g.raw + g.text + (g.abschluss ?? ""), "Leistung") }
        XCTAssertEqual(QISParser.summary(r.grades).average, 1.7)
    }

    func testSyncStoresGradesAndRunWithoutStammdatenOrASI() async throws {
        let db = try await database()
        let clock = UniFlowClock.fixed(berlin: "2026-10-27T09:00:00")!
        let report = await QISGradesSync.run(db: db, transport: qis(list: listPage(rows: twoGrades)), clock: clock, retry: noWait)
        XCTAssertTrue(report.ok, report.message)
        XCTAssertEqual(report.grades, 2)
        XCTAssertEqual(report.documents, 1)
        XCTAssertFalse(report.needsLogin)
        XCTAssertEqual(report.message, "2 Leistungen")
        let rows = try await db.rows("SELECT * FROM grades ORDER BY text")
        XCTAssertEqual(rows.compactMap { $0["text"]?.string }, ["Mathematik I", "Programmieren"])
        XCTAssertEqual(rows.first?["fetched_at"]?.string, "2026-10-27T09:00:00")
        let runs = try await db.rows("SELECT * FROM qis_runs")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?["ok"]?.int, 1)
        XCTAssertEqual(runs.first?["grades"]?.int, 2)
        XCTAssertEqual(runs.first?["documents"]?.int, 0, "keine Bescheinigung gespeichert")
        let docs = try await db.rows("SELECT * FROM qis_documents")
        XCTAssertTrue(docs.isEmpty)
        let everything = JSONValue.array((rows + runs).map(JSONValue.object)).jsonString()
        forbidden(everything, "Datenbank")
        forbidden(report.message, "Meldung")

        // zweiter Abruf: aktualisiert statt doppelt
        let again = await QISGradesSync.run(db: db, transport: qis(list: listPage(rows: twoGrades)), clock: clock, retry: noWait)
        XCTAssertEqual(again.grades, 2)
        let count = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(count, 2)
    }

    // MARK: Leer ist kein Fehler

    func testEmptyNotenspiegelIsASuccessfulRunWithZeroGrades() async throws {
        let db = try await database()
        let report = await QISGradesSync.run(db: db, transport: qis(list: listPage(rows: "")), clock: .fixed(berlin: "2026-10-27T09:00:00")!,
                                             retry: noWait)
        XCTAssertTrue(report.ok, "leer ist kein Fehler")
        XCTAssertEqual(report.grades, 0)
        XCTAssertFalse(report.needsLogin)
        XCTAssertTrue(report.message.hasPrefix("0 Leistungen"), report.message)
        let run = try await db.rows("SELECT ok, grades, message FROM qis_runs").first
        XCTAssertEqual(run?["ok"]?.int, 1)
        XCTAssertEqual(run?["grades"]?.int, 0)
        let stored = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(stored, 0)
        XCTAssertEqual(QISGradesSync.emptyNotice, "Im QIS sind noch keine Noten veröffentlicht.")
    }

    // MARK: Abgelaufene Sitzung

    func testLoginFormMeansSessionExpiredAndNothingIsStored() async throws {
        let db = try await database()
        // schon die Startseite verlangt die Anmeldung
        let report = await QISGradesSync.run(db: db, transport: qis(list: listPage(rows: twoGrades), loggedIn: false),
                                             clock: .fixed(berlin: "2026-10-27T09:00:00")!, retry: noWait)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.needsLogin)
        XCTAssertNil(report.grades)
        XCTAssertEqual(report.message, QISError.sessionExpired.description)
        let none = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(none, 0)
        let run = try await db.rows("SELECT ok, message FROM qis_runs").first
        XCTAssertEqual(run?["ok"]?.int, 0)
        XCTAssertTrue(run?["message"]?.string?.hasPrefix("FEHLER:") ?? false)
        forbidden(run?["message"]?.string ?? "", "qis_runs")

        // erst mitten im Weg (Leistungsseite) kommt das Anmeldeformular: ebenfalls Anmeldung noetig, nichts gespeichert
        let late = qis(list: loginPage)
        let r2 = await QISGradesSync.run(db: db, transport: late, clock: .fixed(berlin: "2026-10-27T09:05:00")!, retry: noWait)
        XCTAssertTrue(r2.needsLogin)
        let still = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(still, 0)
    }

    func testStartPageWithoutNotenspiegelIsAnErrorNotALogin() async throws {
        let t = FakeUniTransport { [logout] _ in ok("<html><body>\(logout)<p>Nichts</p></body></html>") }
        do {
            _ = try await QISClient(transport: t, retry: noWait).fetch()
            XCTFail("ohne Weg zum Notenspiegel")
        } catch let e as QISError {
            XCTAssertEqual(e, .notenspiegelNotFound)
        }
        let r = await QISGradesSync.run(db: try await database(), transport: t, retry: noWait)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.needsLogin)
        XCTAssertEqual(r.message, QISError.notenspiegelNotFound.description)
    }

    func testNetworkErrorMessageCarriesNoAddress() {
        let e = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "\(base)?asi=\(asi)"])
        let m = QISGradesSync.describe(e)
        XCTAssertFalse(m.contains(asi))
        XCTAssertTrue(m.contains("Zeitüberschreitung"))
        XCTAssertTrue(QISGradesSync.describe(URLError(.notConnectedToInternet)).contains("Keine Internetverbindung"))
        XCTAssertEqual(QISClient.startURL, UniversityProfile.luhQISStart)
    }
}

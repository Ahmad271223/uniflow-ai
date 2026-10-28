import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Externer Pruefbericht, Apple Nr. 521-570 (natives Backend, Router, Datenbank, Semester): Teile im Kern. App-Teile in
// UniFlowTests/AuditRunde14AppTests.swift; Ergebnis: docs/audit/RUNDE-14-501-570.md. Alle Daten sind erfunden.

// MARK: - 551-555 Router

final class AuditRunde14RouterTests: XCTestCase {

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-10-25T14:30:05")!)
    }

    /// Beispielpfad zu einem Muster: Platzhalter werden zu "7" (ganze Zahl) bzw. "x7"
    private func sample(_ p: LocalPathPattern) -> String {
        "/" + p.segments.map { seg -> String in
            switch seg {
            case .literal(let l): return l
            case .param(_, let isInt): return isInt ? "7" : "x7"
            }
        }.joined(separator: "/")
    }

    /// 552: Bei zwei passenden Mustern entscheidet nie die Reihenfolge der Registrierung. Alle Pfade der App,
    /// einmal in der ueblichen und einmal in umgekehrter Reihenfolge der Module und ihrer Pfade eingetragen: jeder
    /// Beispielpfad landet beim selben Endpunkt. Gleich spezifische Muster, die denselben Pfad treffen, haben dieselbe
    /// Form und sind ein Konflikt (551, `LocalBackend` startet dann nicht).
    func testRegistrationOrderNeverDecides() async throws {
        let b = try await backend()
        let reversed = LocalRouter()
        for route in b.router.allRoutes.reversed() {
            reversed.add(route.method, route.pattern.template, placeholder: route.placeholder) { _, _ in .ok }
        }
        XCTAssertTrue(reversed.conflicts.isEmpty, "\(reversed.conflicts)")
        var checked = 0
        for route in b.router.allRoutes {
            let path = sample(route.pattern)
            let a = try XCTUnwrap(b.router.route(method: route.method, path: path), "\(route.method) \(path)")
            let r = try XCTUnwrap(reversed.route(method: route.method, path: path), "\(route.method) \(path)")
            XCTAssertEqual(a.route.pattern.template, r.route.pattern.template, "\(route.method) \(path)")
            XCTAssertEqual(a.route.placeholder, r.route.placeholder, "\(route.method) \(path)")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 100, "alle Pfade der App geprueft")

        // gleich spezifisch und derselbe Pfad: immer dieselbe Form -> Konflikt
        let r = LocalRouter()
        r.get("/api/x/{a}/y") { _, _ in .ok }
        r.get("/api/x/{b}/y") { _, _ in .ok }
        XCTAssertEqual(r.conflicts, ["GET /api/x/{b}/y: ? und ?"])
    }

    /// 553: 405 bei falscher Methode fuer feste und dynamische Pfade, auch wenn nur ein Platzhalter passt; 404, wenn
    /// kein Muster passt; 422 nur bei passender Methode mit falschem Zahlenwert
    func testMethodNotAllowedForStaticDynamicAndPlaceholderRoutes() async throws {
        let b = try await backend()
        func status(_ m: String, _ p: String) async -> Int { await b.handle(LocalRequest(method: m, path: p)).status }
        let fixed = await status("DELETE", "/api/settings")
        XCTAssertEqual(fixed, 405)
        let dynamic = await status("PUT", "/api/flashcards/3")
        XCTAssertEqual(dynamic, 405)
        let placeholder = await status("DELETE", "/api/bg")
        XCTAssertEqual(placeholder, 405)
        let wrongTypeWrongMethod = await status("PUT", "/api/flashcards/abc")
        XCTAssertEqual(wrongTypeWrongMethod, 405, "falsche Methode vor falschem Typ, wie FastAPI")
        let wrongType = await status("DELETE", "/api/flashcards/abc")
        XCTAssertEqual(wrongType, 422)
        let unknown = await status("GET", "/api/gibt/es/nicht")
        XCTAssertEqual(unknown, 404)
        let tooLong = await status("GET", "/api/settings/zu/lang")
        XCTAssertEqual(tooLong, 404)
    }

    /// 554: negative, sehr grosse und vorzeichenbehaftete IDs: kein Absturz, 404 fuer unbekannte Eintraege, 422 fuer
    /// Werte ausserhalb von Int64 (FastAPI nimmt beliebig grosse Zahlen, Pythons sqlite3 scheitert dann mit 500)
    func testUnusualIntegerIDs() async throws {
        let b = try await backend()
        func call(_ m: String, _ p: String) async -> LocalResponse { await b.handle(LocalRequest(method: m, path: p)) }
        for id in ["-1", "0", "-0", "+5", "9223372036854775807", "-9223372036854775808"] {
            let get = await call("GET", "/api/packages/\(id)")
            XCTAssertEqual(get.status, 404, id)
            let del = await call("DELETE", "/api/flashcards/\(id)")
            XCTAssertEqual(del.status, 404, id)
            let patch = await b.handle(LocalRequest(method: "PATCH", path: "/api/tasks/\(id)", body: Data(#"{"title": "x"}"#.utf8)))
            XCTAssertEqual(patch.status, 404, id)
        }
        for id in ["9223372036854775808", "99999999999999999999999", "1.5", "1e3", "0x10", " 5"] {
            let r = await call("GET", "/api/packages/\(id)")
            XCTAssertEqual(r.status, 422, id)
            XCTAssertEqual(r.json?["detail"]?.array?.first?["type"], "int_parsing", id)
        }
        let count = try await b.context.database.scalar("SELECT COUNT(*) FROM study_packages")?.int
        XCTAssertEqual(count, 0, "nichts angelegt")
    }

    /// 555 (Fehler belegt): Die Antwort auf einen Datenbankfehler enthielt den Text von SQLite mit Tabellen- und
    /// Spaltennamen, die auf andere Fehler die ganze Beschreibung (bei Dateifehlern mit Pfad und Dateiname). Jetzt nur
    /// Art und Code; Speicher voll mit eigenem Text.
    func testUnexpectedErrorsNameNoInternals() async throws {
        let r = LocalRouter()
        r.get("/api/a") { _, ctx in
            _ = try await ctx.database.query("SELECT geheime_spalte FROM interne_tabelle")
            return .ok
        }
        r.get("/api/b") { _, _ in
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/private/var/mobile/Containers/Data/Klausur Mathe.pdf"])
        }
        r.get("/api/c") { _, _ in throw SQLiteError(stage: .step, code: 13, message: "database or disk is full") }
        r.get("/api/d") { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        r.get("/api/e") { _, _ in throw LocalHTTPError.notFound("Paket nicht gefunden") }
        let ctx = LocalContext(database: try SQLiteDatabase(path: SQLiteDatabase.inMemory))
        func detail(_ p: String) async -> (Int, String) {
            let resp = await r.handle(LocalRequest(method: "GET", path: p), context: ctx)
            return (resp.status, resp.json?["detail"]?.string ?? "")
        }
        let (sa, a) = await detail("/api/a")
        XCTAssertEqual(sa, 500)
        XCTAssertEqual(a, "Fehler der lokalen Datenbank (Code 1). Bitte versuche es erneut.")
        let (sb, b) = await detail("/api/b")
        XCTAssertEqual(sb, 500)
        XCTAssertEqual(b, "Interner Fehler im lokalen Backend. Bitte versuche es erneut.")
        for (p, text) in [("/api/a", a), ("/api/b", b)] {
            for secret in ["geheime_spalte", "interne_tabelle", "SELECT", "Klausur", "/private", "Containers"] {
                XCTAssertFalse(text.contains(secret), "\(p): \(text)")
            }
        }
        let (_, c) = await detail("/api/c")
        let (_, d) = await detail("/api/d")
        XCTAssertEqual(c, "Der Speicher dieses Geräts ist voll. Gib Platz frei und versuche es erneut.")
        XCTAssertEqual(d, c)
        let (se, e) = await detail("/api/e")
        XCTAssertEqual(se, 404)
        XCTAssertEqual(e, "Paket nicht gefunden", "eigene Meldungen der Endpunkte bleiben")
    }
}

// MARK: - 556-558 Datenbank

final class AuditRunde14DatabaseTests: XCTestCase {

    /// 556 (Belastung): Die Suche liest alle Dateien und Aufgaben und beim ersten Mal alle Seitentexte ohne Suchform
    /// (wie Python `db.rows`). Mit 5 000 Dateien, 20 000 Aufgaben und 10 000 Seitentexten (rund 15 MB Text) bleibt
    /// das in Sekunden, die Antwort ist begrenzt, und der zweite Aufruf liest die Texte nicht noch einmal.
    func testSearchOverLargeTablesStaysBounded() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let paragraph = String(repeating: "Eigenwerte und Eigenvektoren einer symmetrischen Matrix. ", count: 26)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, subject, active) VALUES ('c1', 'Testkurs', 'Testfach', 1)")
            for i in 0..<5_000 {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, local_path) VALUES (?, 'c1', ?, 1, ?)",
                              [.text("f\(i)"), .text("Blatt \(i).pdf"), .text("files/f\(i).pdf")])
            }
            try c.execute("INSERT INTO study_packages(id, date, subject, title) VALUES (1, '2026-10-26', 'Testfach', 'Paket')")
            for i in 0..<20_000 {
                try c.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status) VALUES (1, 'frei', ?, ?, 30, 'geplant')",
                              [.text("Aufgabe \(i)"), .integer(Int64(i))])
            }
            for i in 0..<10_000 {
                let marker = i == 4_321 ? " Quantenchromodynamik" : ""
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?, ?, ?, 1)",
                              [.text("f\(i % 5_000)"), .integer(Int64(i / 5_000 + 1)), .text(paragraph + marker)])
            }
        }
        var start = Date()
        let first = await b.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "quantenchromodynamik")]))
        let firstSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.json?["pages"]?.array?.count, 1)
        XCTAssertLessThan(firstSeconds, 30, "erster Aufruf mit Suchform fuer 10 000 Seiten")
        start = Date()
        let second = await b.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "blatt 4")]))
        let secondSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(second.json?["files"]?.array?.count, 20, "Liste begrenzt")
        XCTAssertLessThanOrEqual(second.json?["pages"]?.array?.count ?? 99, 10)
        XCTAssertLessThan(secondSeconds, 10)
        let open = try await b.context.database.scalar("SELECT COUNT(*) FROM page_texts WHERE search IS NULL")?.int
        XCTAssertEqual(open, 0)
        print("Messung 556: erste Suche \(firstSeconds) s, zweite \(secondSeconds) s")
    }

    /// 557 (Haertung): Laengen beim Binden als 64-Bit-Zahl. Vorher `Int32(count)`: ab 2 GiB brach die App ab
    /// (Gegenprobe: dieser Test stuerzt mit dem alten Code ab). Jetzt ein Fehler von SQLite, die Verbindung bleibt
    /// nutzbar. `Data(count:)` belegt den Speicher nur virtuell; SQLite prueft die Laenge vor dem Kopieren.
    func testBindingMoreThanTwoGigabytesFailsCleanly() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.execute("CREATE TABLE t(b BLOB)")
        let huge = Data(count: Int(Int32.max) + 16)
        XCTAssertThrowsError(try c.execute("INSERT INTO t(b) VALUES (?)", [.blob(huge)])) { error in
            XCTAssertEqual((error as? SQLiteError)?.code, SQLITE_TOOBIG, "\(error)")
        }
        try c.execute("INSERT INTO t(b) VALUES (?)", [.blob(Data([1, 2, 3]))])
        XCTAssertEqual(try c.scalar("SELECT length(b) FROM t"), .integer(3))
        // Texte gehen denselben Weg (ohne 2 GiB im Test): Laenge und eingebettete Nullen bleiben
        try c.execute("CREATE TABLE s(x TEXT)")
        try c.execute("INSERT INTO s(x) VALUES (?)", [.text("a\u{0}b ä")])
        XCTAssertEqual(try c.scalar("SELECT x FROM s"), .text("a\u{0}b ä"))
        XCTAssertEqual(try c.scalar("SELECT length(CAST(x AS BLOB)) FROM s"), .integer(6))
    }

    /// 558: Scheitert erst das COMMIT (hier ein aufgeschobener Fremdschluessel), wird zurueckgerollt: nichts ist
    /// gespeichert, keine Transaktion bleibt offen, die naechste gelingt. Ein ROLLBACK selbst scheitert nur nach
    /// Ein-/Ausgabefehlern; die Verbindung bliebe dann in der Transaktion und jede weitere `transaction` meldet einen
    /// Fehler, statt Aenderungen unbemerkt in die alte zu schreiben.
    func testFailedCommitRollsBackAndTheConnectionStaysUsable() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.executeScript("""
            CREATE TABLE parent(id INTEGER PRIMARY KEY);
            CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);
            """)
        var bodyRan = false
        XCTAssertThrowsError(try c.transaction { c in
            try c.execute("INSERT INTO child(id, parent_id) VALUES (1, 99)")
            bodyRan = true
        }) { error in
            XCTAssertEqual((error as? SQLiteError)?.extendedCode, 787, "SQLITE_CONSTRAINT_FOREIGNKEY beim COMMIT: \(error)")
        }
        XCTAssertTrue(bodyRan, "der Fehler kam erst beim COMMIT")
        XCTAssertFalse(c.isInTransaction)
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM child"), .integer(0))
        try c.transaction { c in
            try c.execute("INSERT INTO parent(id) VALUES (99)")
            try c.execute("INSERT INTO child(id, parent_id) VALUES (1, 99)")
        }
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM child"), .integer(1))
        // verschachtelt: Fehler, die aeussere Transaktion bleibt unberuehrt und wird zurueckgerollt
        XCTAssertThrowsError(try c.transaction { c in
            try c.execute("INSERT INTO parent(id) VALUES (100)")
            try c.transaction { _ in }
        })
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM parent"), .integer(1))
    }
}

// MARK: - 569 Semester

final class AuditRunde14TermTests: XCTestCase {

    private func put(_ b: LocalBackend, _ body: String) async -> LocalResponse {
        await b.handle(LocalRequest(method: "PUT", path: "/api/terms", body: Data(body.utf8)))
    }

    /// 569 (Fehler belegt): Ein Semester mit vertauschten Daten oder ohne gueltiges Datum wurde gespeichert. Danach
    /// verschwanden alle Serien ohne eigene Daten aus dem Stundenplan (sie gelten im Semester; Gegenprobe ohne die
    /// Pruefung: PUT 200, Woche ohne Termine). Jetzt 422 mit Meldung, das bisherige Semester bleibt aktiv und der
    /// Stundenplan unveraendert.
    func testInvalidTermRangeIsRejectedAndTheTimetableStays() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO course_events(title, weekday, start_time, end_time, rrule, kind) VALUES ('Testvorlesung', 0, '10:00', '12:00', 'weekly', 'vorlesung')")
            try c.execute("INSERT INTO course_events(title, weekday, start_time, end_time, rrule, kind) VALUES ('Testuebung', 1, '14:00', '16:00', 'biweekly', 'uebung')")
        }
        func week() async -> LocalResponse {
            await b.handle(LocalRequest(method: "GET", path: "/api/timetable/week", query: [.init("start", "2026-10-26")]))
        }
        func titles(_ r: LocalResponse) -> [String] {
            (r.json?["days"]?.array ?? []).flatMap { ($0["events"]?.array ?? []).compactMap { $0["title"]?.string } }
        }
        let before = await week()
        XCTAssertEqual(before.status, 200)
        XCTAssertEqual(titles(before), ["Testvorlesung", "Testuebung"])
        let term = await b.handle(LocalRequest(method: "GET", path: "/api/terms")).json

        for (body, message) in [
            (#"{"name": "WiSe", "start": "2027-01-30", "end": "2026-10-12"}"#, "Das Ende des Semesters liegt vor seinem Beginn."),
            (#"{"name": "WiSe", "start": "kaputt", "end": "2027-01-30"}"#, "Beginn des Semesters ist kein gültiges Datum (JJJJ-MM-TT)."),
            (#"{"name": "WiSe", "start": "2026-10-12", "end": ""}"#, "Ende des Semesters ist kein gültiges Datum (JJJJ-MM-TT)."),
            (#"{"name": "WiSe", "start": "2026-10-12", "end": "2027-02-30"}"#, "Ende des Semesters ist kein gültiges Datum (JJJJ-MM-TT)."),
            (#"{"name": "WiSe", "start": "2026-10-1", "end": "2027-01-30"}"#, "Beginn des Semesters ist kein gültiges Datum (JJJJ-MM-TT)."),
            (#"{"name": "WiSe", "start": 20261012, "end": "2027-01-30"}"#, "Beginn des Semesters ist kein gültiges Datum (JJJJ-MM-TT)."),
        ] {
            let r = await put(b, body)
            XCTAssertEqual(r.status, 422, body)
            XCTAssertEqual(r.json?["detail"]?.string, message, body)
        }
        let after = await b.handle(LocalRequest(method: "GET", path: "/api/terms")).json
        XCTAssertEqual(after, term, "bisheriges Semester bleibt aktiv")
        let still = await week()
        XCTAssertEqual(still.status, 200)
        XCTAssertEqual(titles(still), ["Testvorlesung", "Testuebung"])

        // gueltig, auch ein Tag lang
        let ok = await put(b, #"{"name": "Blockkurs", "start": "2027-03-01", "end": "2027-03-01"}"#)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.json?["start"], "2027-03-01")
    }
}

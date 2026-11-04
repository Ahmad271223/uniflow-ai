import Foundation
import XCTest
@testable import UniFlowCore

// Eigene Karteikarten (M8) gegen die Python-Referenz: flashcards.json (tools/gen-flashcards-fixture.py) mit erfundenen
// Kursen, Dateien und Karten; dazu die Leitner-Regeln, der Filter "faellig" und Regel G6 einzeln.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/flashcards.json")))
}

/// Uhr, die ein Test weiterstellt (Ortszeit Berlin)
final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ berlin: String) { date = UniFlowClock.fixed(berlin: berlin)!.now }

    func set(_ berlin: String) { lock.withLock { date = UniFlowClock.fixed(berlin: berlin)!.now } }

    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class LocalFlashcardTests: XCTestCase {

    private func backend(_ clock: SettableClock, seed: [JSONValue] = []) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock.clock)
        try await b.context.database.transaction { c in
            for s in seed { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ raw: String? = nil) async -> LocalResponse {
        let url = URL(string: "uniflow-local://device" + path)!
        return await b.handle(LocalRequest(method: method, url: url, headers: raw == nil ? [:] : ["Content-Type": "application/json"],
                                           body: raw.map { Data($0.utf8) }))
    }

    // MARK: Paritaet mit app/server.py

    func testScenariosMatchPythonServer() async throws {
        let fx = try fixture()
        let scenarios = fx["scenarios"]?.array ?? []
        XCTAssertEqual(scenarios.map { $0["name"]?.string ?? "" }, ["haupt", "grenzen", "trainer", "versteckt", "stapel"])
        XCTAssertEqual(fx["intervals"], .array(FlashcardEndpoints.intervals.map { .number(Double($0)) }))
        var problems: [String] = []
        var checked = 0
        for sc in scenarios {
            let name = sc["name"]?.string ?? ""
            let steps = sc["steps"]?.array ?? []
            let clock = SettableClock(steps.first?["now"]?.string ?? "2026-10-26T09:00:00")
            let b = try await backend(clock, seed: sc["seed"]?.array ?? [])
            for (i, step) in steps.enumerated() {
                clock.set(step["now"]?.string ?? "")
                let method = step["method"]?.string ?? "", path = step["path"]?.string ?? ""
                let label = "\(name) \(i): \(method) \(path) \(step["raw"]?.string ?? "")"
                let r = await call(b, method, path, step["raw"]?.string)
                let status = step["status"]?.int ?? 0
                guard r.status == status else {
                    problems.append("\(label): Status \(r.status) statt \(status) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                    continue
                }
                checked += 1
                guard let local = r.json else { problems.append("\(label): keine JSON-Antwort"); continue }
                // Python 500: Starlette antwortet mit Text; lokal JSON mit Meldung (nichts gespeichert, siehe Tabellen)
                if status == 500 {
                    if local["detail"]?.string?.isEmpty != false { problems.append("\(label): 500 ohne Meldung") }
                    continue
                }
                let expected = step["response"] ?? .null
                if status == 422 {
                    let a = local["detail"]?.array?.first, e = expected["detail"]?.array?.first
                    if a?["type"] != e?["type"] || a?["loc"] != e?["loc"] { problems.append("\(label): 422 \(local) statt \(expected)") }
                    continue
                }
                if local != expected {
                    problems.append("\(label):\n  lokal  \(local.jsonString(sortedKeys: true).prefix(1200))\n  Python \(expected.jsonString(sortedKeys: true).prefix(1200))")
                }
            }
            for table in ["flashcards", "flashcard_stacks"] {
                let rows = JSONValue.array(try await b.context.database.rows("SELECT * FROM \(table) ORDER BY id").map(JSONValue.object))
                let expected = sc["tables_after"]?[table] ?? .null
                if rows != expected {
                    let l = rows.array ?? [], e = expected.array ?? []
                    let diff = zip(l, e).first { $0 != $1 }.map { "\n  lokal  \($0.0.jsonString(sortedKeys: true))\n  Python \($0.1.jsonString(sortedKeys: true))" }
                    problems.append("\(name): Tabelle \(table) \(l.count) statt \(e.count) Zeilen\(diff ?? "")")
                }
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(checked, 160, "alle Schritte verglichen")
    }

    /// Gegenprobe zur Fixture: sie deckt Fach 5, falsch -> 1, Faelligkeit nach Tagen, 404 und Regel G6 wirklich ab
    func testFixtureCoversLeitnerAndErrors() throws {
        let fx = try fixture()
        let steps = fx["scenarios"]?.array?.first?["steps"]?.array ?? []
        let reviews = steps.filter { ($0["path"]?.string ?? "").hasSuffix("/review") && $0["status"]?.int == 200 }
        XCTAssertTrue(reviews.contains { $0["response"]?["box"] == 5 })
        XCTAssertGreaterThanOrEqual(reviews.filter { $0["response"]?["box"] == 5 }.count, 4, "Fach 5 bleibt Fach 5")
        XCTAssertTrue(reviews.contains { $0["raw"]?.string == #"{"correct": false}"# && $0["response"]?["box"] == 1 })
        XCTAssertTrue(steps.contains { $0["method"] == "DELETE" && $0["status"] == 404 && $0["response"]?["detail"] == "Karteikarte nicht gefunden" })
        XCTAssertTrue(steps.contains { $0["method"] == "POST" && $0["status"] == 404 && $0["response"]?["detail"] == "Not Found" })
        XCTAssertTrue(steps.contains { $0["path"]?.string == "/api/flashcards?due=true" && ($0["response"]?.array?.count ?? 0) > 0 })
        XCTAssertEqual(Set(steps.compactMap { $0["now"]?.string?.prefix(10) }).count, 4, "Uhr an vier Tagen")
    }

    /// Gegenprobe zum Szenario "stapel" (04.11.2026): Bestand bekommt Stapel wie die Migration, geschlossenes Ueben je
    /// Stapel, Bearbeiten laesst das Fach, Loeschen mit Umzug, Fehler mit Meldung
    func testStackFixtureCoversTheDecisions() throws {
        let fx = try fixture()
        let sc = try XCTUnwrap(fx["scenarios"]?.array?.first { $0["name"] == "stapel" })
        let steps = sc["steps"]?.array ?? []
        let first = try XCTUnwrap(steps.first?["response"]?.array)
        XCTAssertEqual(Set(first.compactMap { $0["name"]?.string }), ["LA_Vorlesung_01.pdf", "f-weg", "Ohne Modul", "Allgemein"], "Migration beim Lesen")
        XCTAssertTrue(first.allSatisfy { $0["cards"]?.int ?? 0 > 0 && $0["due"] != nil })
        let closed = steps.filter { $0["path"]?.string == "/api/flashcards?stack_id=5&due=1" }
        XCTAssertEqual(closed.count, 2)
        XCTAssertTrue(closed.allSatisfy { ($0["response"]?.array ?? []).allSatisfy { $0["stack_id"] == 5 } }, "nur dieser Stapel wird abgefragt")
        let edit = try XCTUnwrap(steps.first { $0["raw"]?.string?.contains("In Klausur 1 (neu)") == true }?["response"])
        XCTAssertEqual(edit["question"], "In Klausur 1 (neu)")
        XCTAssertEqual(edit["box"], 2, "Bearbeiten setzt das Fach nicht zurueck")
        XCTAssertTrue(steps.contains { $0["path"]?.string == "/api/flashcard-stacks/5?move_to=6" && $0["response"]?["moved"] == 3 })
        XCTAssertTrue(steps.contains { $0["status"] == 404 && $0["response"]?["detail"] == "Stapel nicht gefunden" })
        XCTAssertTrue(steps.contains { $0["status"] == 404 && $0["response"]?["detail"] == "Zielstapel nicht gefunden" })
        XCTAssertTrue(steps.contains { $0["status"] == 422 && $0["response"]?["detail"] == "Frage und Antwort dürfen nicht leer sein" })
        let stacks = sc["tables_after"]?["flashcard_stacks"]?.array ?? []
        XCTAssertTrue(stacks.allSatisfy { ($0["name"]?.string?.isEmpty == false) })
        XCTAssertTrue(sc["tables_after"]?["flashcards"]?.array?.allSatisfy { $0["stack_id"]?.int != nil } == true, "jede Karte hat einen Stapel")
    }

    /// Stapel einzeln: Karte ohne Angabe landet im Stapel des Dokuments bzw. "Allgemein"/"Ohne Modul"; Umzug mit
    /// Lernstand; PATCH aendert Frage, Antwort, Fach und Stapel, nie Fach und Termin der Wiederholung
    func testStacksKeepLeitnerStateAndStayClosed() async throws {
        let clock = SettableClock("2026-11-04T09:00:00")
        let b = try await backend(clock, seed: try fixture()["scenarios"]?.array?.first?["seed"]?.array ?? [])
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Datei", "answer": "a"}], "file_id": "f-la1"}"#)
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Frei", "answer": "a"}]}"#)
        let stacks = await call(b, "GET", "/api/flashcard-stacks")
        XCTAssertEqual(stacks.json?.array?.compactMap { $0["name"]?.string }, ["Ohne Modul", "LA_Vorlesung_01.pdf"])
        XCTAssertEqual(stacks.json?.array?.first?["due"], 1)
        let fileStack = try XCTUnwrap(stacks.json?.array?.last?["id"]?.int)
        let other = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "Klausur", "subject": "Analysis Beispiel"}"#)
        XCTAssertEqual(other.status, 200)
        let otherID = try XCTUnwrap(other.json?["id"]?.int)
        XCTAssertEqual(other.json?["kind"], "eigene")
        XCTAssertEqual(other.json?["week"], .null)
        // Lehrwoche und Art aus dem Dokument (Blatt_01 -> uebung, Woche 1), eigene Angabe geht vor, Fehler mit Meldung
        let sheet = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "Blatt", "file_id": "f-an1"}"#)
        XCTAssertEqual(sheet.json?["kind"], "uebung")
        XCTAssertEqual(sheet.json?["week"], 1)
        XCTAssertEqual(stacks.json?.array?.last?["kind"], "vorlesung", "LA_Vorlesung_01.pdf")
        let own = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "Eigen", "file_id": "f-an1", "kind": "eigene", "week": 4}"#)
        XCTAssertEqual(own.json?["kind"], "eigene")
        XCTAssertEqual(own.json?["week"], 4)
        let badWeek = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "x", "week": 0}"#)
        XCTAssertEqual(badWeek.status, 422)
        XCTAssertEqual(badWeek.json?["detail"], "week: ganze Zahl ab 1 oder null erwartet")
        let badKind = await call(b, "PATCH", "/api/flashcard-stacks/\(otherID)", #"{"kind": "klausur"}"#)
        XCTAssertEqual(badKind.status, 422)
        // ueben nur im Dateistapel
        let due = await call(b, "GET", "/api/flashcards?stack_id=\(fileStack)&due=true")
        XCTAssertEqual(due.json?.array?.compactMap { $0["question"]?.string }, ["Datei"])
        let id = try XCTUnwrap(due.json?.array?.first?["id"]?.int)
        _ = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": true}"#)
        let practised = await call(b, "GET", "/api/flashcard-stacks")
        XCTAssertEqual(practised.json?.array?.first { $0["id"]?.int == fileStack }?["last_practised"], "2026-11-04T09:00:00")
        XCTAssertEqual(practised.json?.array?.first { $0["id"]?.int == otherID }?["last_practised"], .null)
        // bearbeiten und verschieben: Fach 2 und Termin bleiben, Fach des Zielstapels
        let edited = await call(b, "PATCH", "/api/flashcards/\(id)", #"{"question": " Datei neu ", "stack_id": \#(otherID)}"#)
        XCTAssertEqual(edited.status, 200)
        XCTAssertEqual(edited.json?["question"], "Datei neu")
        XCTAssertEqual(edited.json?["box"], 2)
        XCTAssertEqual(edited.json?["due"], "2026-11-06")
        XCTAssertEqual(edited.json?["subject"], "Analysis Beispiel")
        XCTAssertEqual(edited.json?["stack_id"]?.int, otherID)
        let blank = await call(b, "PATCH", "/api/flashcards/\(id)", #"{"answer": " "}"#)
        XCTAssertEqual(blank.status, 422)
        let unknown = await call(b, "PATCH", "/api/flashcards/\(id)", #"{"stack_id": 9999}"#)
        XCTAssertEqual(unknown.status, 404)
        // Stapel loeschen mit Umzug in den Dateistapel (Fach des Ziels), danach ohne Umzug samt Karten
        let moved = await call(b, "DELETE", "/api/flashcard-stacks/\(otherID)?move_to=\(fileStack)")
        XCTAssertEqual(moved.json?["moved"], 1)
        let back = await call(b, "GET", "/api/flashcards?stack_id=\(fileStack)")
        XCTAssertEqual(back.json?.array?.first?["subject"], "Lineare Algebra Test")
        XCTAssertEqual(back.json?.array?.first?["box"], 2)
        let gone = await call(b, "DELETE", "/api/flashcard-stacks/\(fileStack)")
        XCTAssertEqual(gone.json?["deleted"], 1)
        let empty = await call(b, "GET", "/api/flashcards?stack_id=\(fileStack)")
        XCTAssertEqual(empty.json?.array?.count, 0)
        let again = await call(b, "DELETE", "/api/flashcard-stacks/\(fileStack)")
        XCTAssertEqual(again.status, 404)
    }

    // MARK: Leitner einzeln

    func testLeitnerBoxesAndIntervals() async throws {
        let clock = SettableClock("2026-10-26T09:00:00")
        let b = try await backend(clock)
        let created = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Testfrage A", "answer": "Testantwort A"}]}"#)
        XCTAssertEqual(created.json, ["ok": true, "count": 1, "stack_id": 1])
        let list = await call(b, "GET", "/api/flashcards")
        let card = try XCTUnwrap(list.json?.array?.first)
        XCTAssertEqual(card["box"], 1)
        XCTAssertEqual(card["due"], "2026-10-26", "neue Karte ist sofort faellig")
        XCTAssertEqual(card["created_at"], "2026-10-26T09:00:00")
        XCTAssertEqual(card["file_name"], .null)
        let id = try XCTUnwrap(card["id"]?.int)
        // richtig: Fach 2, 3, 4, 5 mit 2, 4, 8, 16 Tagen; danach bleibt Fach 5
        var expected: [(Int, String)] = [(2, "2026-10-28"), (3, "2026-10-30"), (4, "2026-11-03"), (5, "2026-11-11"), (5, "2026-11-11")]
        for (box, due) in expected {
            let r = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": true}"#)
            XCTAssertEqual(r.json, ["box": .number(Double(box)), "due": .string(due)])
        }
        // falsch: aus Fach 5 zurueck in Fach 1, morgen wieder
        let wrong = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": false}"#)
        XCTAssertEqual(wrong.json, ["box": 1, "due": "2026-10-27"])
        // falsch aus Fach 1 bleibt Fach 1
        expected = [(1, "2026-10-27")]
        let again = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": false}"#)
        XCTAssertEqual(again.json, ["box": .number(Double(expected[0].0)), "due": .string(expected[0].1)])
        // die Abstaende kommen von der Uhr, nicht von Date()
        clock.set("2027-02-26T23:30:00")
        let later = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": true}"#)
        XCTAssertEqual(later.json, ["box": 2, "due": "2027-02-28"])
        XCTAssertEqual(FlashcardEndpoints.intervals, [1, 2, 4, 8, 16])
    }

    func testDueFilterUsesClockAndFile() async throws {
        let clock = SettableClock("2026-10-26T09:00:00")
        let b = try await backend(clock, seed: [
            ["sql": "INSERT INTO courses(id, title, subject, created_at) VALUES ('k1', 'Testkurs', 'Testfach', '2026-10-01')"],
            ["sql": "INSERT INTO files(id, course_id, name, status, kind) VALUES ('d1', 'k1', 'Skript.pdf', 'neu', 'pdf')"],
        ])
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Mit Datei", "answer": "ja"}], "file_id": "d1"}"#)
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Ohne Datei", "answer": "nein"}]}"#)
        let all = await call(b, "GET", "/api/flashcards")
        XCTAssertEqual(all.json?.array?.map { $0["question"]?.string ?? "" }, ["Ohne Datei", "Mit Datei"], "neueste zuerst")
        XCTAssertEqual(all.json?.array?.last?["subject"], "Testfach", "Fach aus dem Kurs der Datei")
        XCTAssertEqual(all.json?.array?.last?["file_name"], "Skript.pdf")
        let withFile = await call(b, "GET", "/api/flashcards?file_id=d1")
        XCTAssertEqual(withFile.json?.array?.count, 1)

        // beide richtig: in zwei Tagen wieder faellig, heute nicht mehr
        for c in all.json?.array ?? [] { _ = await call(b, "POST", "/api/flashcards/\(c["id"]?.int ?? 0)/review", #"{"correct": true}"#) }
        var due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json, [])
        clock.set("2026-10-27T23:59:59")
        due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json, [], "morgen noch nicht")
        clock.set("2026-10-28T00:00:00")
        due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json?.array?.count, 2, "am uebernaechsten Tag beide")
        due = await call(b, "GET", "/api/flashcards?due=true&file_id=d1")
        XCTAssertEqual(due.json?.array?.map { $0["question"]?.string ?? "" }, ["Mit Datei"])
        let bad = await call(b, "GET", "/api/flashcards?due=bald")
        XCTAssertEqual(bad.status, 422)
    }

    /// Versteckte Karten (Trainer) sind nie faellig: "Heute faellig" und alle Zaehler (?due=true) lassen sie weg,
    /// die Liste ohne due zeigt sie weiter; Fach und Termin bleiben, wieder zeigen macht sie wieder faellig
    func testHiddenCardsAreNeverDue() async throws {
        let clock = SettableClock("2026-11-03T10:00:00")
        let b = try await backend(clock)
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Sichtbar", "answer": "a"}, {"question": "Versteckt", "answer": "b"}]}"#)
        var due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json?.array?.count, 2)
        let hide = await call(b, "PATCH", "/api/flashcards/2", #"{"hidden": true}"#)
        XCTAssertEqual(hide.json?["hidden"], 1)
        XCTAssertEqual(hide.json?["due"], "2026-11-03", "Termin bleibt")
        due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json?.array?.map { $0["question"]?.string ?? "" }, ["Sichtbar"])
        let all = await call(b, "GET", "/api/flashcards")
        XCTAssertEqual(all.json?.array?.map { $0["question"]?.string ?? "" }, ["Versteckt", "Sichtbar"], "Liste zeigt versteckte Karten")
        // NULL von aussen zaehlt als nicht versteckt
        try await b.context.database.transaction { c in _ = try c.execute("UPDATE flashcards SET hidden=NULL WHERE id=1") }
        due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json?.array?.map { $0["question"]?.string ?? "" }, ["Sichtbar"])
        _ = await call(b, "PATCH", "/api/flashcards/2", #"{"hidden": false}"#)
        due = await call(b, "GET", "/api/flashcards?due=true")
        XCTAssertEqual(due.json?.array?.count, 2, "wieder gezeigt: wieder faellig")
    }

    func testDeleteAndNotFound() async throws {
        let clock = SettableClock("2026-10-26T09:00:00")
        let b = try await backend(clock)
        _ = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "Weg damit", "answer": "gleich"}]}"#)
        let listed = await call(b, "GET", "/api/flashcards")
        let id = try XCTUnwrap(listed.json?.array?.first?["id"]?.int)
        let deleted = await call(b, "DELETE", "/api/flashcards/\(id)")
        XCTAssertEqual(deleted.status, 200)
        XCTAssertEqual(deleted.json, ["ok": true])
        let empty = await call(b, "GET", "/api/flashcards")
        XCTAssertEqual(empty.json, [])
        // Regel G6: nichts geloescht -> 404 mit Meldung, nie Erfolg
        let again = await call(b, "DELETE", "/api/flashcards/\(id)")
        XCTAssertEqual(again.status, 404)
        XCTAssertEqual(again.json?["detail"], "Karteikarte nicht gefunden")
        let review = await call(b, "POST", "/api/flashcards/\(id)/review", #"{"correct": true}"#)
        XCTAssertEqual(review.status, 404)
        XCTAssertEqual(review.json?["detail"], "Not Found")
        let badID = await call(b, "DELETE", "/api/flashcards/abc")
        XCTAssertEqual(badID.status, 422)
    }

    /// Ein Fehler mitten in einer Anfrage speichert nichts (wie db.cursor ohne commit)
    func testFailedCreateStoresNothing() async throws {
        let b = try await backend(SettableClock("2026-10-26T09:00:00"))
        let r = await call(b, "POST", "/api/flashcards", #"{"cards": [{"question": "erste", "answer": "gut"}, "kaputt"]}"#)
        XCTAssertEqual(r.status, 500)
        let after = await call(b, "GET", "/api/flashcards")
        XCTAssertEqual(after.json, [])
    }

    /// Echte Endpunkte statt Platzhalter, auch fuer das Anlegen
    func testFlashcardRoutesAreReal() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        for (m, p) in [("GET", "/api/flashcards"), ("POST", "/api/flashcards"), ("POST", "/api/flashcards/1/review"), ("DELETE", "/api/flashcards/1")] {
            let route = try XCTUnwrap(b.route(method: m, path: p), "\(m) \(p)")
            XCTAssertFalse(route.placeholder, "\(m) \(p)")
            XCTAssertEqual(route.module, FlashcardEndpoints.name)
        }
    }

    /// Karten gehoeren zur Datenbank des Containers: eine zweite Datenbank (anderes Konto oder andere Hochschule)
    /// sieht sie nicht, und eine Bewertung dort trifft die Karte der ersten nicht
    func testCardsStayInTheirDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-karten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clock = SettableClock("2026-10-26T09:00:00").clock
        let luh = try await LocalBackend.open(path: dir.appendingPathComponent("luh.db").path, clock: clock, university: "luh")
        let hi = try await LocalBackend.open(path: dir.appendingPathComponent("hi.db").path, clock: clock, university: "hildesheim")
        _ = await luh.handle(LocalRequest(method: "POST", path: "/api/flashcards", body: Data(#"{"cards": [{"question": "Nur LUH", "answer": "ja"}]}"#.utf8)))
        let other = await hi.handle(LocalRequest(method: "GET", path: "/api/flashcards"))
        XCTAssertEqual(other.json, [])
        let review = await hi.handle(LocalRequest(method: "POST", path: "/api/flashcards/1/review", body: Data(#"{"correct": true}"#.utf8)))
        XCTAssertEqual(review.status, 404)
        let own = await luh.handle(LocalRequest(method: "GET", path: "/api/flashcards"))
        XCTAssertEqual(own.json?.array?.first?["box"], 1)
    }
}

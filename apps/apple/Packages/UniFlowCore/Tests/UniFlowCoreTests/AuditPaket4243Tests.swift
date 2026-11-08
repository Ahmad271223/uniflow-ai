import Foundation
import XCTest
@testable import UniFlowCore

// Audit 08.11.2026, Pakete 42/43 (iPad: KI, Karteikarten, Wochentests) und die offenen Punkte aus Paket 30-32, die der
// Kern nachziehen muss (docs/audit/AUDIT-2026-11-08-PAKET-42-43.md):
// - 503 `ai_overloaded` / `ai_provider_busy` mit Retry-After: einmal von selbst mit derselben `request_id` nachfragen
//   (app/ai_async.py: "die Clients wiederholen mit derselben request_id"), sonst "ausgelastet" statt "nicht verfuegbar"
// - P30-10: ausdrueckliche Seitenauswahl ohne gueltige Seite -> 422 `pages_invalid` statt still der ersten Seiten
// - P30-11: Name eines Stapels hoechstens 120 Zeichen (wie `STACK_NAME_MAX` in app/server.py)
// - P32-01: Marker nur mit echtem `true` fuer den Kurs freigeben
// - P32-05: falsche Eingaben an die Marker 422 statt 500, interne Fehler ohne Einzelheiten

private final class PagesAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }
    var isMetered: Bool { false }
    func answer(system: String, prompt: String) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return #"{"cards": [{"question": "Was ist eine Reihe?", "answer": "Eine Summe."}]}"#
    }
}

final class AuditPaket4243Tests: XCTestCase {

    // MARK: Hilfen

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-08T09:00:00")!)
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ raw: String? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: raw == nil ? [:] : ["Content-Type": "application/json"], body: raw.map { Data($0.utf8) }))
    }

    private func text(_ r: LocalResponse) -> String { String(decoding: r.body, as: UTF8.self) }

    /// Modul mit einer Datei und drei Seitentexten
    private func seed(_ b: LocalBackend) async throws {
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
            try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1)")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f1', 'k1', 'vl03.pdf', 5, 'pdf')")
            for (p, t) in [(1, "Grenzwerte von Folgen"), (2, "Cauchy-Folgen"), (3, "Reihen und Konvergenzkriterien")] {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES ('f1', ?, ?, 5, ?)",
                              [.integer(Int64(p)), .text(t), .text(ScriptSearch.searchForm(t))])
            }
        }
    }

    // MARK: 503 ai_overloaded / ai_provider_busy

    private func studinow(_ fake: FakeService) -> StudiNowAI {
        StudiNowAI(base: "https://dienst.example", http: fake, tokens: MemoryTokenStore("tok"), consent: FixedConsent(true))
    }

    private func overloaded(_ code: String) -> JSONValue {
        ["detail": ["detail": "Die KI ist gerade ausgelastet, bitte gleich noch einmal.", "code": .string(code), "retry_after": 0]]
    }

    private func requestIDs(_ fake: FakeService) async -> [String] {
        await fake.requests.compactMap { r in r.body.flatMap { try? JSONValue.parse($0) }?["request_id"]?.string }
    }

    func testP43OverloadedServiceIsAskedOnceMoreWithTheSameRequestID() async throws {
        for code in ["ai_overloaded", "ai_provider_busy"] {
            let fake = FakeService()
            await fake.on("POST", "/api/ai/relay", 503, overloaded(code), headers: ["Retry-After": "0"])
            await fake.on("POST", "/api/ai/relay", 200, ["answer": "Antwort", "model": "m", "shared": false, "replay": false, "credits": .null])
            let ai = studinow(fake)
            do {
                let r = try await AIRelayTask.run(AIRelayTask("tutor:ask")) { try await ai.answer(system: "", prompt: "Frage") }
                XCTAssertEqual(r.value, "Antwort", code)
            } catch {
                XCTFail("\(code): \(error)")
            }
            let ids = await requestIDs(fake)
            XCTAssertEqual(ids.count, 2, "\(code): genau ein zweiter Versuch")
            XCTAssertEqual(Set(ids).count, 1, "\(code): dieselbe request_id (der Dienst berechnet sie nie doppelt)")
        }
    }

    func testP43StillOverloadedSaysBusyNotUnavailable() async throws {
        let fake = FakeService()
        for _ in 0..<3 { await fake.on("POST", "/api/ai/relay", 503, overloaded("ai_provider_busy"), headers: ["Retry-After": "0"]) }
        let ai = studinow(fake)
        do {
            _ = try await AIRelayTask.run(AIRelayTask("flashcards")) { try await ai.answer(system: "", prompt: "Seiten") }
            XCTFail("ausgelastet")
        } catch let e as LocalHTTPError {
            XCTAssertEqual(e.status, 503)
            XCTAssertEqual(e.detail["code"], "ai_provider_busy", "Code bleibt fuer die Oberflaeche")
            XCTAssertEqual(e.detail["detail"]?.string, "Die StudiNow-KI ist gerade ausgelastet. Bitte versuche es in ein paar Sekunden noch einmal.")
            XCTAssertNotEqual(e.detail["detail"]?.string, StudiNowAIText.unavailable)
        }
        let n = await fake.requests.count
        XCTAssertEqual(n, 2, "hoechstens ein zweiter Versuch, keine Schleife")
    }

    func testP43OtherErrorsAreNotRepeated() async throws {
        let cases: [(Int, JSONValue)] = [
            (503, ["detail": ["detail": "nicht eingerichtet", "code": "ai_not_configured_prices"]]),
            (429, ["detail": ["detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted"]]),
            (403, ["detail": ["detail": "Nur Plus", "code": "plan_required", "required_plan": "plus"]]),
            (502, ["detail": ["detail": "Anbieter", "code": "ai_provider_error"]]),
        ]
        for (status, body) in cases {
            let fake = FakeService()
            await fake.on("POST", "/api/ai/relay", status, body)
            await fake.on("POST", "/api/ai/relay", 200, ["answer": "zu spaet", "credits": .null])
            let ai = studinow(fake)
            do {
                _ = try await AIRelayTask.run(AIRelayTask("tutor:ask")) { try await ai.answer(system: "", prompt: "Frage") }
                XCTFail("\(status) muss als Fehler ankommen")
            } catch let e as LocalHTTPError {
                XCTAssertEqual(e.status, status)
            }
            let n = await fake.requests.count
            XCTAssertEqual(n, 1, "\(status) \(body["detail"]?["code"]?.string ?? ""): nie von selbst wiederholt")
        }
    }

    // MARK: P30-10 Seitenauswahl

    func testP30_10ExplicitPageChoiceWithoutAValidPageIs422() async throws {
        let b = try await backend()
        try await seed(b)
        let ai = PagesAI()
        b.context.ai.set(ai)
        for raw in [#"[9999]"#, #"["x"]"#, #""1-3""#, #"{"a": 1}"#, #"[0, -2]"#] {
            let r = await call(b, "POST", "/api/ai/flashcards", #"{"file_id": "f1", "pages": \#(raw)}"#)
            XCTAssertEqual(r.status, 422, "\(raw): \(text(r))")
            XCTAssertEqual(r.json?["detail"]?["code"], "pages_invalid", raw)
        }
        XCTAssertTrue(ai.prompts.isEmpty, "nichts an die KI, nichts berechnet")
        // ohne Angabe wie bisher die ersten Seiten; gemischte Listen gefiltert
        for (raw, pages) in [("null", [1, 2, 3]), ("[]", [1, 2, 3]), ("[2, 99]", [2])] as [(String, [Int])] {
            let r = await call(b, "POST", "/api/ai/flashcards", #"{"file_id": "f1", "pages": \#(raw)}"#)
            XCTAssertEqual(r.status, 200, "\(raw): \(text(r))")
            XCTAssertEqual(r.json?["pages"]?.array?.compactMap(\.int), pages, raw)
        }
        let none = await call(b, "POST", "/api/ai/flashcards", #"{"file_id": "f1"}"#)
        XCTAssertEqual(none.json?["pages"]?.array?.compactMap(\.int), [1, 2, 3])
    }

    // MARK: P30-11 Stapelname

    func testP30_11StackNameHasALimitOf120() async throws {
        let b = try await backend()
        let ok = String(repeating: "a", count: 120), long = String(repeating: "a", count: 121)
        let created = await call(b, "POST", "/api/flashcard-stacks", #"{"name": " \#(ok) "}"#)
        XCTAssertEqual(created.status, 200, text(created))
        let id = try XCTUnwrap(created.json?["id"]?.int)
        let tooLong = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "\#(long)"}"#)
        XCTAssertEqual(tooLong.status, 422, text(tooLong))
        XCTAssertEqual(tooLong.json?["detail"], "Name des Stapels: höchstens 120 Zeichen")
        let rename = await call(b, "PATCH", "/api/flashcard-stacks/\(id)", #"{"name": "\#(long)"}"#)
        XCTAssertEqual(rename.status, 422, text(rename))
        // gezaehlt wie Python (Codepunkte): 120 Umlaute gehen, 121 nicht
        let umlauts = await call(b, "POST", "/api/flashcard-stacks", #"{"name": "\#(String(repeating: "ä", count: 120))"}"#)
        XCTAssertEqual(umlauts.status, 200, text(umlauts))
        let stacks = await call(b, "GET", "/api/flashcard-stacks")
        XCTAssertEqual(stacks.json?.array?.first { $0["id"]?.int == id }?["name"]?.string, ok, "unveraendert nach dem abgelehnten Umbenennen")
    }

    // MARK: P32-01 / P32-05 Marker

    func testP32_01ReleaseNeedsARealTrue() async throws {
        let b = try await backend()
        for raw in [#"{"confirm": "false"}"#, #"{"confirm": "true"}"#, #"{"confirm": 1}"#, #"{"confirm": "ja"}"#, #"{"confirm": [true]}"#, #"{"confirm": {"a": 1}}"#] {
            let r = await call(b, "POST", "/api/markers/999/release", raw)
            XCTAssertEqual(r.status, 400, raw)
            XCTAssertEqual(r.json?["detail"], "Freigabe muss ausdrücklich bestätigt werden (confirm=true).", raw)
        }
        let real = await call(b, "POST", "/api/markers/999/release", #"{"confirm": true}"#)
        XCTAssertEqual(real.json?["detail"], "Marker nicht gefunden.", "mit true geht es bis zur Pruefung des Markers")
    }

    func testP32_05MarkerInputErrorsAre422Not500() async throws {
        let b = try await backend()
        let bad = [
            #"{"file_id": "f1", "page": "abc"}"#, #"{"file_id": "f1", "page": [1]}"#, #"{"file_id": "f1", "page": true}"#,
            #"{"file_id": "f1", "page": 0}"#, #"{"file_id": "f1", "page": 1000000000000}"#,
            #"{"file_id": "f1", "page": 3, "lecture_date": "gestern"}"#, #"{"file_id": "f1", "page": 3, "lecture_date": "2026-02-30"}"#,
            #"{"file_id": "f1", "page": 3, "topic": 5}"#, #"{"file_id": "f1", "page": 3, "page_key": ["x"]}"#,
        ]
        for raw in bad {
            let r = await call(b, "POST", "/api/markers", raw)
            XCTAssertEqual(r.status, 422, "\(raw): \(text(r))")
        }
        for raw in [#"{"page": "abc"}"#, #"{"topic": 5}"#, #"{"lecture_date": "gestern"}"#] {
            let r = await call(b, "PATCH", "/api/markers/1", raw)
            XCTAssertEqual(r.status, 422, "PATCH \(raw): \(text(r))")
        }
        // gueltige Form: weiter die Regel (400) bzw. "Feld fehlt"
        let rule = await call(b, "POST", "/api/markers", #"{"file_id": "f1", "page": "3", "lecture_date": "2026-11-02", "topic": null}"#)
        XCTAssertEqual(rule.status, 400, text(rule))
        let missing = await call(b, "POST", "/api/markers", #"{"page": 3}"#)
        XCTAssertEqual(missing.json?["detail"], "Feld fehlt: 'file_id'")
    }

    func testP32_05InternalMarkerErrorsCarryNoDetails() {
        struct Inner: Error, CustomStringConvertible { var description: String { "SQLiteError(code: 11, /var/mobile/…/uniflow.sqlite)" } }
        let e = WeeklyEndpoints.werr(Inner())
        XCTAssertEqual(e.status, 500)
        XCTAssertEqual(e.detail.string, "Interner Fehler bei Seitenmarkern oder Wochentests.")
        XCTAssertEqual(WeeklyEndpoints.werr(Weekly.Failure("Marker nicht gefunden.")).status, 400)
    }
}

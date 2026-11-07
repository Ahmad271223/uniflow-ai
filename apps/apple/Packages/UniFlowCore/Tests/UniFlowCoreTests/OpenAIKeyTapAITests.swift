import Foundation
import XCTest
@testable import UniFlowCore

// KI-Abnahme LUH 07.11.2026: der eigene OpenAI-Schluessel auch fuer Arbeit nach Antippen mit Bild ("Bereich an KI",
// eine Seite in den Seiten-Index aufnehmen), nie beim Vorwaermen; verstaendliche Texte bei Zeitueberschreitung und ohne
// Netz. Nur gegen einen Schein-Server, nie ins Netz.

/// Transport, der mit einem festen Fehler scheitert (Zeitueberschreitung, kein Netz)
private struct URLErrorTransport: AIHTTPTransport {
    let code: URLError.Code
    func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data) { throw URLError(code) }
}

private func stream(_ text: String) -> Data {
    let done: JSONValue = ["type": "response.completed", "response": ["model": "gpt-4o-mini", "output": [["type": "message", "content": [["type": "output_text", "text": .string(text)]]]]]]
    return Data("event: response.completed\ndata: \(String(decoding: done.serialized(), as: UTF8.self))\n\n".utf8)
}

final class OpenAIKeyTapAITests: XCTestCase {
    let key = "sk-proj-TESTSCHLUESSEL-abcdefghijklmnopqrstuvwxyz0123"

    private func session(_ http: AIHTTPTransport) -> OpenAIKeySession {
        var s = OpenAIKeyState()
        s.apiKey = key
        s.model = "gpt-4o-mini"
        return OpenAIKeySession(store: MemoryOpenAIKeyStore(s), http: http)
    }

    func testImageGoesAlongAsInputImageWithTheChosenModel() async throws {
        let http = FakeOpenAI()
        await http.on(ChatGPTConstants.responsesURL) { _ in (200, stream("Im Bild steht $x^2$.")) }
        let s = session(http)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let text = try await s.index(system: "SYS", prompt: "Was steht da?", imageJPEG: jpeg, schema: .null, small: true)
        XCTAssertEqual(text, "Im Bild steht $x^2$.")
        let last = await http.last(ChatGPTConstants.responsesURL)
        let req = try XCTUnwrap(last)
        let body = try JSONValue.parse(try XCTUnwrap(req.body))
        XCTAssertEqual(body["model"]?.string, "gpt-4o-mini", "auch bei `small` das gewaehlte Modell (der Nutzer zahlt selbst)")
        let content = body["input"]?.array?.first?["content"]?.array ?? []
        XCTAssertEqual(content.map { $0["type"]?.string }, ["input_text", "input_image"])
        XCTAssertEqual(content.last?["image_url"]?.string, "data:image/jpeg;base64," + jpeg.base64EncodedString())
        XCTAssertNil(body["text"]?["format"], "freie Antwort ohne Schema")
        XCTAssertEqual(req.headers["Authorization"], "Bearer \(key)")
        let model = await s.modelName
        XCTAssertEqual(model, "gpt-4o-mini")

        // ohne Bild wie `complete` (mit Schema)
        _ = try await s.index(system: "SYS", prompt: "P", imageJPEG: nil, schema: ["type": "object"], small: false)
        let plain = await http.last(ChatGPTConstants.responsesURL)
        let plainBody = try JSONValue.parse(try XCTUnwrap(plain?.body))
        XCTAssertEqual(plainBody["text"]?["format"]?["type"]?.string, "json_schema")
    }

    /// Nach Antippen ja, im Hintergrund nie; die StudiNow-KI baut keinen Index
    func testOnTapUsesTheKeyButPrewarmNever() async throws {
        let s = session(FakeOpenAI())
        let idx = LocalDocIndex()
        XCTAssertNil(idx.ai(from: s), "Vorwaermen: nie mit dem eigenen Schluessel")
        XCTAssertTrue(idx.aiOnTap(from: s) is OpenAIKeySession, "nach Antippen: der Schluessel mit Bild")
        XCTAssertNil(idx.aiOnTap(from: nil))
        let relay = StudiNowAI(base: "https://dienst.example", http: NoService(), tokens: NoTokens(), consent: Yes())
        XCTAssertNil(idx.aiOnTap(from: relay), "StudiNow-KI: kein Index beim Dienst")

        // Backend: Status "can_build" mit dem Schluessel wahr
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-07T10:00:00")!)
        b.context.ai.setKey(s)
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/index/status")!, headers: [:], body: nil))
        XCTAssertEqual(r.json?["can_build"], true, String(decoding: r.body, as: UTF8.self))
        b.context.ai.setKey(nil)
        let off = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/index/status")!, headers: [:], body: nil))
        XCTAssertEqual(off.json?["can_build"], false)
    }

    /// "Bereich an KI" mit dem eigenen Schluessel: das Bild geht mit (vorher fiel es still weg)
    func testTutorAreaSendsTheImageWithTheKey() async throws {
        let http = FakeOpenAI()
        await http.on(ChatGPTConstants.responsesURL) { _ in (200, stream("Das ist $\\frac{1}{2}$.")) }
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-07T10:00:00")!)
        b.context.ai.setKey(session(http))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 9, 9, 9])
        let body: JSONValue = ["mode": "explain", "page_text": "Seite", "selection": "", "image": .string(jpeg.base64EncodedString())]
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                            headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"]?.string, "Das ist $\\frac{1}{2}$.")
        let last = await http.last(ChatGPTConstants.responsesURL)
        let sent = try JSONValue.parse(try XCTUnwrap(last?.body))
        XCTAssertEqual(sent["input"]?.array?.first?["content"]?.array?.last?["type"]?.string, "input_image")
        XCTAssertEqual(r.json?["credits"], .null, "eigener Schluessel: keine Credits")
    }

    func testTimeoutAndOfflineSayWhatToDo() async throws {
        for (code, expected, text) in [(URLError.Code.timedOut, "ai_provider_timeout", "nicht rechtzeitig"),
                                       (.notConnectedToInternet, "ai_provider_unreachable", "Internetverbindung")] {
            let s = session(URLErrorTransport(code: code))
            do {
                _ = try await s.answer(system: "S", prompt: "P")
                XCTFail("muss scheitern")
            } catch let e as AIError {
                XCTAssertEqual(e.code, expected)
                XCTAssertTrue(e.message.contains(text), e.message)
                XCTAssertFalse(e.message.contains(key))
            }
            do {
                _ = try await s.test()
                XCTFail("muss scheitern")
            } catch let e as AIError { XCTAssertEqual(e.code, expected) }
        }
        // Im Backend: 503 mit dem Text, die Oberflaeche zeigt ihn (kein Haengen)
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-07T10:00:00")!)
        b.context.ai.setKey(session(URLErrorTransport(code: .timedOut)))
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                            headers: ["Content-Type": "application/json"],
                                            body: (["mode": "explain", "page_text": "Seite"] as JSONValue).serialized()))
        XCTAssertEqual(r.status, 503)
        let raw = String(decoding: r.body, as: UTF8.self)
        XCTAssertTrue(raw.contains("ai_provider_timeout") && raw.contains("nicht rechtzeitig"), raw)
    }
}

private struct NoService: ServiceHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private final class NoTokens: AccountTokenStore, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ token: String?) throws {}
}

private struct Yes: AIConsentGate {
    func ensureConsent() async -> Bool { true }
}

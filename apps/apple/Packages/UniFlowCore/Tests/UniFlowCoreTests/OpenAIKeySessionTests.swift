import Foundation
import XCTest
@testable import UniFlowCore

// Eigenes ChatGPT ueber den eigenen OpenAI-Schluessel (OpenAIKeySession.swift, 07.11.2026): Form des Schluessels,
// Ablage, Pruefung und Modellliste (`GET /v1/models`), Standardmodell, Anfragen an die Responses API mit den
// Fehlerfaellen, Schluessel nie in einer Meldung. Nur gegen einen Schein-Server, nie ins Netz.

/// Ablage im Speicher
final class MemoryOpenAIKeyStore: OpenAIKeyStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenAIKeyState?
    private(set) var saves = 0
    private(set) var removes = 0
    init(_ v: OpenAIKeyState? = nil) { value = v }
    func load() -> OpenAIKeyState? { lock.withLock { value } }
    func save(_ state: OpenAIKeyState) throws { lock.withLock { value = state; saves += 1 } }
    func remove() throws { lock.withLock { value = nil; removes += 1 } }
}

private func sse(_ text: String, model: String = "gpt-4o-mini") -> Data {
    let events: [JSONValue] = [
        ["type": "response.created", "response": ["id": "resp_1"]],
        ["type": "response.output_text.delta", "delta": .string(text)],
        ["type": "response.completed", "response": ["model": .string(model), "output": [["type": "message", "content": [["type": "output_text", "text": .string(text)]]]]]],
    ]
    return Data(events.map { "event: \($0["type"]?.string ?? "")\ndata: \(String(decoding: $0.serialized(), as: UTF8.self))\n\n" }.joined().utf8)
}

final class OpenAIKeySessionTests: XCTestCase {
    let key = "sk-proj-TESTSCHLUESSEL-abcdefghijklmnopqrstuvwxyz0123"

    private func modelsBody(_ ids: [String]) -> Data {
        JSONValue.object(["object": "list", "data": .array(ids.map { ["id": .string($0), "object": "model"] })]).serialized()
    }

    func testKeyRulesAcceptOnlyOpenAIShapedKeysAndMaskThem() {
        XCTAssertEqual(OpenAIKeyRules.normalize("  \(key)\n"), key)
        XCTAssertNil(OpenAIKeyRules.normalize("abc"), "ohne sk-")
        XCTAssertNil(OpenAIKeyRules.normalize("sk-kurz"), "zu kurz")
        XCTAssertNil(OpenAIKeyRules.normalize("sk-" + String(repeating: "a", count: 10) + " " + String(repeating: "b", count: 10)), "Leerraum innen")
        XCTAssertNil(OpenAIKeyRules.normalize("sk-" + String(repeating: "ä", count: 30)), "nur ASCII")
        XCTAssertNil(OpenAIKeyRules.normalize("sk-" + String(repeating: "a", count: 500)), "zu lang")
        XCTAssertEqual(OpenAIKeyRules.masked(key), "sk-…0123")
        XCTAssertEqual(OpenAIKeyRules.masked(""), "")
        XCTAssertFalse(OpenAIKeyRules.masked(key).contains("TESTSCHLUESSEL"))
    }

    func testChatModelsAndDefaultChoice() {
        let ids = ["whisper-1", "gpt-4o", "gpt-4o-mini", "text-embedding-3-small", "o3-mini", "gpt-4o-realtime-preview", "dall-e-3",
                   "gpt-4o-mini-tts", "gpt-5", "gpt-4.1-mini", "gpt-4o-audio-preview", "chatgpt-4o-latest", "tts-1"]
        let chat = OpenAIKeyRules.chatModels(ids)
        XCTAssertEqual(chat, ["gpt-4.1-mini", "gpt-4o-mini", "o3-mini", "gpt-4o", "gpt-5"], "mini zuerst, dann der Rest; keine Spezialmodelle")
        XCTAssertEqual(OpenAIKeyRules.pickDefault(ids), "gpt-4o-mini", "Standard, wenn die Liste es fuehrt")
        XCTAssertEqual(OpenAIKeyRules.pickDefault(["gpt-5", "gpt-5-mini", "gpt-4.1-mini", "gpt-5-mini-2026-01-01"]), "gpt-5-mini", "sonst das neueste mini ohne Datum")
        XCTAssertEqual(OpenAIKeyRules.pickDefault(["gpt-5", "gpt-4.1"]), "gpt-5", "ohne mini das Hauptmodell")
        XCTAssertNil(OpenAIKeyRules.pickDefault(["whisper-1"]))
        XCTAssertEqual(OpenAIKeyRules.defaultModel, "gpt-4o-mini")
    }

    func testSetKeyChecksModelsAndPicksTheDefault() async throws {
        let store = MemoryOpenAIKeyStore(), http = FakeOpenAI()
        let list = modelsBody(["gpt-4o", "gpt-4o-mini", "whisper-1"])
        await http.on(ChatGPTConstants.modelsURL) { r in
            r.headers["Authorization"] == "Bearer sk-proj-TESTSCHLUESSEL-abcdefghijklmnopqrstuvwxyz0123" ? (200, list) : (401, Data(#"{"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}}"#.utf8))
        }
        let s = OpenAIKeySession(store: store, http: http, now: { 1_800_000_000 })
        var st = await s.status
        XCTAssertFalse(st.hasKey)
        XCTAssertFalse(st.enabledForAI)
        do {
            try await s.setKey("nix")
            XCTFail("muss ablehnen")
        } catch let e as AIError { XCTAssertEqual(e.code, "openai_key_invalid") }
        try await s.setKey(" \(key) ")
        st = await s.status
        XCTAssertTrue(st.hasKey)
        XCTAssertEqual(st.keyHint, "sk-…0123")
        XCTAssertFalse(st.checked)
        XCTAssertFalse(st.enabledForAI, "ohne Modell noch nicht")
        XCTAssertEqual(store.load()?.apiKey, key, "im Speicher (App: Schluesselbund)")
        let models = try await s.test()
        XCTAssertEqual(models, ["gpt-4o-mini", "gpt-4o"])
        st = await s.status
        XCTAssertTrue(st.checked)
        XCTAssertEqual(st.model, "gpt-4o-mini", "Standardmodell gesetzt")
        XCTAssertTrue(st.enabledForAI)
        var calls = await http.count(ChatGPTConstants.modelsURL)
        XCTAssertEqual(calls, 1)
        _ = try await s.models()
        calls = await http.count(ChatGPTConstants.modelsURL)
        XCTAssertEqual(calls, 1, "10 Minuten gemerkt")
        _ = try await s.models(force: true)
        calls = await http.count(ChatGPTConstants.modelsURL)
        XCTAssertEqual(calls, 2)
        // Schalter und Modell
        try await s.setUseForAI(false)
        st = await s.status
        XCTAssertFalse(st.enabledForAI)
        try await s.setUseForAI(true)
        try await s.setModel("gpt-4o")
        st = await s.status
        XCTAssertEqual(st.model, "gpt-4o")
        // loeschen: alles weg
        try await s.removeKey()
        st = await s.status
        XCTAssertFalse(st.hasKey)
        XCTAssertEqual(st.keyHint, "")
        XCTAssertEqual(store.removes, 1)
        XCTAssertNil(store.load())
    }

    func testRejectedKeyIsReportedWithoutRevealingIt() async throws {
        var saved = OpenAIKeyState()
        saved.apiKey = key
        saved.model = "gpt-4o-mini"
        let store = MemoryOpenAIKeyStore(saved), http = FakeOpenAI()
        await http.on(ChatGPTConstants.modelsURL) { _ in (401, Data(#"{"error": {"message": "Incorrect API key provided: sk-proj-TEST***", "code": "invalid_api_key"}}"#.utf8)) }
        let s = OpenAIKeySession(store: store, http: http)
        let loaded = await s.status
        XCTAssertTrue(loaded.enabledForAI, "gespeicherter Stand wird geladen")
        do {
            _ = try await s.test()
            XCTFail("muss scheitern")
        } catch let e as AIError {
            XCTAssertEqual(e.code, "openai_key_invalid")
            XCTAssertFalse(e.message.contains("sk-proj"), "nie den Schluessel oder Teile davon nennen")
        }
        let after = await s.status
        XCTAssertEqual(after.lastError?.contains("lehnt den Schlüssel ab"), true)
        await http.setOffline(true)
        do {
            _ = try await s.test()
            XCTFail("muss scheitern")
        } catch let e as AIError { XCTAssertEqual(e.code, "ai_provider_unreachable") }
    }

    func testCompleteSendsTheResponsesRequestWithTheKeyAndReadsTheStream() async throws {
        var saved = OpenAIKeyState()
        saved.apiKey = key
        saved.model = "gpt-4o-mini"
        let store = MemoryOpenAIKeyStore(saved), http = FakeOpenAI()
        await http.on(ChatGPTConstants.responsesURL) { r in
            guard r.headers["Authorization"] == "Bearer sk-proj-TESTSCHLUESSEL-abcdefghijklmnopqrstuvwxyz0123" else { return (401, Data()) }
            return (200, sse("**Antwort** [1]"))
        }
        let s = OpenAIKeySession(store: store, http: http)
        let text = try await s.answer(system: "SYS", prompt: "Frage?", schema: ["type": "object"])
        XCTAssertEqual(text, "**Antwort** [1]")
        let lastRequest = await http.last(ChatGPTConstants.responsesURL)
        let req = try XCTUnwrap(lastRequest)
        let body = try JSONValue.parse(try XCTUnwrap(req.body))
        XCTAssertEqual(body["model"]?.string, "gpt-4o-mini")
        XCTAssertEqual(body["instructions"]?.string, "SYS")
        XCTAssertEqual(body["stream"]?.bool, true)
        XCTAssertEqual(body["store"]?.bool, false)
        XCTAssertEqual(body["text"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(req.headers["Accept"], "text/event-stream")
        XCTAssertNil(req.headers["chatgpt-account-id"], "kein Abo-Kopf mit dem API-Schluessel")
        XCTAssertTrue(s.isMetered, "kostet den Nutzer Geld: nie im Hintergrund")
        let ai = LocalAI()
        ai.setKey(s)
        XCTAssertNotNil(ai.provider)
        XCTAssertNil(ai.backgroundProvider, "nicht fuer Vorab einordnen")
        XCTAssertTrue(ai.keyProvider is OpenAIKeySession)
        let own = FakeOwnAI()
        ai.set(own)
        XCTAssertTrue(ai.provider is FakeOwnAI, "ChatGPT-Abo geht vor dem Schluessel")
        ai.set(nil)
        ai.setKey(nil)
        XCTAssertNil(ai.provider)
    }

    func testCompleteErrorsHaveStableCodes() async throws {
        var saved = OpenAIKeyState()
        saved.apiKey = key
        saved.model = "gpt-9-sol"
        let store = MemoryOpenAIKeyStore(saved), http = FakeOpenAI()
        let s = OpenAIKeySession(store: store, http: http)
        func expect(_ status: Int, _ body: String, _ code: String, line: UInt = #line) async {
            await http.on(ChatGPTConstants.responsesURL) { _ in (status, Data(body.utf8)) }
            do {
                _ = try await s.answer(system: "S", prompt: "P")
                XCTFail("muss scheitern", line: line)
            } catch let e as AIError {
                XCTAssertEqual(e.code, code, e.message, line: line)
                XCTAssertFalse(e.message.contains(self.key), line: line)
            } catch { XCTFail("\(error)", line: line) }
        }
        await expect(401, #"{"error": {"message": "Incorrect API key"}}"#, "openai_key_invalid")
        await expect(429, #"{"error": {"message": "You exceeded your current quota", "code": "insufficient_quota"}}"#, "openai_quota")
        await expect(429, #"{"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}"#, "openai_quota")
        await expect(404, #"{"error": {"message": "The model `gpt-9-sol` does not exist", "code": "model_not_found"}}"#, "openai_model")
        await expect(500, #"{"error": {"message": "server error"}}"#, "ai_provider_error")
        await expect(200, #"{"error": {"message": "kaputt", "code": "x"}}"#, "ai_provider_error")
        await http.setOffline(true)
        do {
            _ = try await s.answer(system: "S", prompt: "P")
            XCTFail("muss scheitern")
        } catch let e as AIError { XCTAssertEqual(e.code, "ai_provider_unreachable") }
        // ausgeschaltet oder ohne Modell: nichts wird gesendet
        await http.setOffline(false)
        try await s.setUseForAI(false)
        let before = await http.count(ChatGPTConstants.responsesURL)
        do {
            _ = try await s.answer(system: "S", prompt: "P")
            XCTFail("muss scheitern")
        } catch let e as AIError { XCTAssertEqual(e.code, "openai_key_not_enabled") }
        let afterOff = await http.count(ChatGPTConstants.responsesURL)
        XCTAssertEqual(afterOff, before)
    }
}

/// Schein-KI fuer die Reihenfolge in `LocalAI`
private final class FakeOwnAI: AIProvider, @unchecked Sendable {
    func answer(system: String, prompt: String) async throws -> String { "eigen" }
}

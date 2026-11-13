import Foundation
import XCTest
@testable import UniFlowCore

/// Feste Antwort der Einwilligung fuer Tests; zaehlt, wie oft gefragt wurde
final class FixedConsent: AIConsentGate, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool
    private var asked = 0
    init(_ answer: Bool) { self.answer = answer }
    func ensureConsent() async -> Bool { lock.withLock { asked += 1; return answer } }
    var count: Int { lock.withLock { asked } }
    func set(_ a: Bool) { lock.withLock { answer = a } }
}

/// Einwilligung vor der StudiNow-KI (06.11.2026, App Store 5.1.2(i)): ohne Zustimmung geht keine Anfrage an den Dienst,
/// weder `/api/ai/relay` noch `/api/ai/document/*`; die Zustimmung haengt am Konto und am Stand des Textes.
final class AIConsentTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "uniflow.tests.aiconsent.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testCentralGuardBlocksEveryRequestWithoutConsent() async throws {
        let fake = FakeService(), gate = FixedConsent(false)
        let ai = StudiNowAI(base: "https://dienst.example", http: fake, tokens: MemoryTokenStore("tok"), consent: gate)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "x"])
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-05T09:00:00")!)
        b.context.ai.setService(ai)
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                            headers: ["Content-Type": "application/json"],
                                            body: (["mode": "explain", "page_text": "Folgen", "selection": "Grenzwert"] as JSONValue).serialized()))
        XCTAssertEqual(r.status, 403, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["code"]?.string ?? r.json?["detail"]?["code"]?.string, AIConsentText.code)
        do {
            _ = try await ai.json("POST", "/api/ai/document/plan", body: ["file_id": "f"])
            XCTFail("ohne Einwilligung kein Plan")
        } catch let e as LocalHTTPError {
            XCTAssertEqual(e.status, 403)
        }
        let sent = await fake.requests
        XCTAssertTrue(sent.isEmpty, "nichts hat das Geraet verlassen")
        XCTAssertEqual(gate.count, 2)

        gate.set(true)
        let ok = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                             headers: ["Content-Type": "application/json"],
                                             body: (["mode": "explain", "page_text": "Folgen", "selection": "Grenzwert"] as JSONValue).serialized()))
        XCTAssertEqual(ok.status, 200, String(decoding: ok.body, as: UTF8.self))
        let after = await fake.requests
        XCTAssertEqual(after.count, 1)
    }

    func testWithoutTokenNobodyIsAsked() async throws {
        let fake = FakeService(), gate = FixedConsent(true)
        let ai = StudiNowAI(base: "https://dienst.example", http: fake, tokens: MemoryTokenStore(nil), consent: gate)
        do { _ = try await ai.json("POST", "/api/ai/relay", body: [:]); XCTFail() } catch let e as LocalHTTPError {
            XCTAssertEqual(e.status, 401)
        }
        XCTAssertEqual(gate.count, 0, "ohne Anmeldung kein Hinweis")
    }

    func testStoreIsPerAccountAndVersionAndRevocable() throws {
        let d = try defaults()
        let s = AIConsentStore(defaults: d)
        XCTAssertFalse(s.isGranted("konto:1"))
        s.grant("konto:1", at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(s.isGranted("konto:1"))
        XCTAssertEqual(s.grantedAt("konto:1"), Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(s.isGranted("konto:2"), "je Konto")
        XCTAssertFalse(s.isGranted("1"))
        XCTAssertFalse(AIConsentStore(defaults: d, version: "neuer-text").isGranted("konto:1"), "neuer Text fragt erneut")
        s.grant("x.konto:1")
        s.revoke("konto:1")
        XCTAssertFalse(s.isGranted("konto:1"))
        XCTAssertTrue(s.isGranted("x.konto:1"), "Widerruf trifft nur dieses Konto")
        s.grant("")
        XCTAssertFalse(s.isGranted(""))
    }

    func testTextNamesWhatAndWhom() {
        let all = ([AIConsentText.title, AIConsentText.intro, AIConsentText.service, AIConsentText.never, AIConsentText.revoke]
                   + AIConsentText.what + AIConsentText.recipients).joined(separator: " ")
        for needle in ["Was wird gesendet?", "app.studinow.app", "OpenAI", "Anthropic Claude", "Amazon Bedrock", "Frankfurt",
                       "Text der Seite", "Bild eines Bereichs", "Frage", "KI-Einwilligung widerrufen"] {
            XCTAssertTrue(all.contains(needle), needle)
        }
        XCTAssertFalse(all.contains("DeepSeek"), "DeepSeek ist aus")
        XCTAssertEqual(AIConsentText.accept, "Okay, los")
        for needle in ["OpenAI", "Amazon Bedrock", "Text deiner Seite", "Frage", "nie gesendet"] {
            XCTAssertTrue(AIConsentText.short.contains(needle), "Kurzfassung nennt was und an wen: " + needle)
        }
        XCTAssertFalse((AIConsentText.short + AIConsentText.service).contains("Fakih"), "kein Name des Inhabers im Hinweis")
        XCTAssertEqual(AIConsentText.privacyURL, "https://studinow.app/datenschutz")
    }
}

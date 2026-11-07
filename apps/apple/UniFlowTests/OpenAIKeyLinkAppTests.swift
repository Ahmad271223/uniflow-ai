import Security
import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Eigenes ChatGPT ueber den eigenen OpenAI-Schluessel in der App (OpenAIKeyLink.swift, 07.11.2026): Ablage nur im
/// Schluesselbund dieses Geraets je Apple-Nutzer, Anschluss ans lokale Backend, Freigabe des automatischen Lernplans
/// auch in Free, Loeschen mit dem Konto, Karte und Dialog. Nie ins Netz (OpenAI ist ein Schein-Server).
@MainActor
final class OpenAIKeyLinkAppTests: XCTestCase {
    let key = "sk-proj-TESTSCHLUESSEL-abcdefghijklmnopqrstuvwxyz0123"

    /// Schein-OpenAI: Modelle fuer den richtigen Schluessel, sonst 401; Antworten als Ereignisstrom
    actor FakeOpenAI: AIHTTPTransport {
        var requests: [AIHTTPRequest] = []
        let key: String
        init(key: String) { self.key = key }
        func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data) {
            requests.append(request)
            guard request.headers["Authorization"] == "Bearer \(key)" else {
                return (401, Data(#"{"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}}"#.utf8))
            }
            if request.url == ChatGPTConstants.modelsURL {
                return (200, JSONValue.object(["data": [["id": "gpt-4o"], ["id": "gpt-4o-mini"], ["id": "whisper-1"]]]).serialized())
            }
            let done: JSONValue = ["type": "response.completed", "response": ["model": "gpt-4o-mini", "output": [["type": "message", "content": [["type": "output_text", "text": "Antwort"]]]]]]
            return (200, Data("event: response.completed\ndata: \(String(decoding: done.serialized(), as: UTF8.self))\n\n".utf8))
        }
    }

    func testKeychainKeepsEachAppleUserApartAndOnlyOnThisDevice() throws {
        let a = OpenAIKeyKeychainStore(userScope: "test-a-\(UUID().uuidString)"), b = OpenAIKeyKeychainStore(userScope: "test-b-\(UUID().uuidString)")
        defer { OpenAIKeyKeychainStore.remove(userScope: a.userScope); OpenAIKeyKeychainStore.remove(userScope: b.userScope) }
        var s = OpenAIKeyState()
        s.apiKey = key
        s.model = "gpt-4o-mini"
        try a.save(s)
        XCTAssertEqual(a.load(), s)
        XCTAssertNil(b.load(), "anderer Apple-Nutzer sieht nichts")
        let attrs = try XCTUnwrap(KeychainStore(service: OpenAIKeyKeychainStore.service).attributes(a.userScope))
        XCTAssertEqual(attrs.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "nur dieses Geraet, kein Backup auf andere")
        XCTAssertNotEqual(attrs.synchronizable, true, "nie in der iCloud-Schluesselbund-Synchronisierung")
        try a.remove()
        XCTAssertNil(a.load())
        XCTAssertTrue(OpenAIKeyKeychainStore.remove(userScope: a.userScope), "nichts da gilt als geloescht")
        // Der Schluessel steht nirgends sonst: nicht in UserDefaults
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { "\($0)".contains("TESTSCHLUESSEL") })
    }

    func testSavedKeyFeedsTheBackendAndFreesTheAutomaticPlanEvenInFree() async throws {
        let bed = try ContainerTestBed(name: "openai-key", clock: .fixed(berlin: "2026-11-07T09:00:00")!)
        let store = OpenAIKeyKeychainStore(userScope: DataContainerKey.userScope(bed.user))
        defer { OpenAIKeyKeychainStore.remove(userScope: store.userScope) }
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.free)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before); Entitlements.shared.ownChatGPTConnected = false }
        let m = bed.manager()
        let fake = FakeOpenAI(key: key)
        m.chatgpt.apiKey.transport = fake
        let c = try bed.open(m, bed.account(.luh))
        let link = m.chatgpt.apiKey
        await link.refresh()
        XCTAssertEqual(link.status?.hasKey, false)
        XCTAssertFalse(m.chatgpt.enabled)
        XCTAssertEqual(Entitlements.shared.access(.autoPlan), .locked(.plus), "Free ohne eigenes ChatGPT")
        let backend = try await c.host.backend()
        XCTAssertNil(backend.context.ai.provider)

        // falsche Form: nichts gespeichert, nichts gesendet
        await link.save(key: "kein-schluessel")
        XCTAssertEqual(link.status?.hasKey, false)
        XCTAssertEqual(link.message?.contains("sk-"), true)
        let sentBefore = await fake.requests.count
        XCTAssertEqual(sentBefore, 0)

        // richtiger Schluessel: gepruefte Modelle, Standardmodell, Backend bekommt die KI, Lernplan frei
        await link.save(key: key)
        XCTAssertEqual(link.status?.hasKey, true)
        XCTAssertEqual(link.status?.keyHint, "sk-…0123")
        XCTAssertEqual(link.models, ["gpt-4o-mini", "gpt-4o"])
        XCTAssertEqual(link.status?.model, "gpt-4o-mini")
        XCTAssertTrue(link.lastCheckOK)
        XCTAssertEqual(link.message, OpenAIKeyLink.checkedText)
        XCTAssertTrue(link.enabled)
        XCTAssertTrue(m.chatgpt.enabled, "zaehlt als eigenes ChatGPT (ufAIEnabled)")
        XCTAssertEqual(m.chatgpt.activeModel, "gpt-4o-mini")
        XCTAssertTrue(backend.context.ai.provider is OpenAIKeySession, "das Backend antwortet ueber den Schluessel")
        XCTAssertNil(backend.context.ai.backgroundProvider, "nie im Hintergrund (kostet Geld)")
        XCTAssertTrue(Entitlements.shared.ownChatGPTConnected)
        XCTAssertEqual(Entitlements.shared.access(.autoPlan), .allowed, "Ausnahme des Inhabers: Lernplan auch in Free")
        XCTAssertEqual(store.load()?.apiKey, key, "im Schluesselbund")
        let sent = await fake.requests
        XCTAssertTrue(sent.allSatisfy { $0.url.hasPrefix("https://api.openai.com/") }, "nur direkt an OpenAI")

        // Anfrage ueber das Backend: der Schluessel geht nur in der Kopfzeile an OpenAI
        let answer = try await backend.context.ai.provider?.answer(system: "S", prompt: "P")
        XCTAssertEqual(answer, "Antwort")
        let lastSent = await fake.requests.last
        let last = try XCTUnwrap(lastSent)
        XCTAssertEqual(last.url, ChatGPTConstants.responsesURL)
        XCTAssertFalse(String(decoding: last.body ?? Data(), as: UTF8.self).contains(key), "nie im Rumpf")

        // ausschalten: KI weg, Lernplan wieder Plus
        await link.setUseForAI(false)
        XCTAssertFalse(link.enabled)
        XCTAssertNil(backend.context.ai.provider)
        XCTAssertEqual(Entitlements.shared.access(.autoPlan), .locked(.plus))
        await link.setUseForAI(true)
        XCTAssertNotNil(backend.context.ai.provider)

        // loeschen: alles weg
        await link.remove()
        XCTAssertEqual(link.status?.hasKey, false)
        XCTAssertNil(store.load())
        XCTAssertNil(backend.context.ai.provider)
        XCTAssertFalse(Entitlements.shared.ownChatGPTConnected)
    }

    func testDeleteAccountRemovesTheKey() async throws {
        let bed = try ContainerTestBed(name: "openai-key-delete", clock: .fixed(berlin: "2026-11-07T09:00:00")!)
        let store = OpenAIKeyKeychainStore(userScope: DataContainerKey.userScope(bed.user))
        var s = OpenAIKeyState()
        s.apiKey = key
        try store.save(s)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        await m.chatgpt.apiKey.refresh()
        XCTAssertEqual(m.chatgpt.apiKey.status?.hasKey, true, "gespeicherter Schluessel wird geladen")
        let problem = await m.deleteAllData(userID: bed.user)
        XCTAssertNil(problem)
        XCTAssertNil(store.load(), "Konto loeschen entfernt den Schluessel")
        Entitlements.shared.ownChatGPTConnected = false
    }

    func testContractAndCardsShowOwnChatGPTHonestly() {
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.status, .available)
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.label, "Eigenes ChatGPT verbinden: Fragen zu Folien und KI-Lernplan")
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.onDevice, .onDevice([.ownChatGPT]))
        XCTAssertEqual(UFFeature.ownChatGPT.minimumPlan, .free)
        for p in UFPlan.allCases { XCTAssertEqual(UFFeatureMatrix.access(.ownChatGPT, plan: p), .allowed, p.rawValue) }
        let free = UFPlanCard.included(.free)
        let row = free.first { $0.title == "Eigenes ChatGPT verbinden" }
        XCTAssertNotNil(row, free.map(\.title).joined(separator: " | "))
        XCTAssertTrue(row?.detail?.contains("eigenen OpenAI-Schlüssel") == true && row?.detail?.contains("in jedem Tarif") == true, row?.detail ?? "")
        XCTAssertFalse(UFPlanCard.included(.plus).contains { $0.title.contains("ChatGPT") }, "nur einmal, auf der Free-Karte")
        XCTAssertFalse(UFPlanCard.included(.proAI).contains { $0.title.contains("ChatGPT") })
        XCTAssertEqual(UFFeatureMatrix.access(.autoPlan, plan: .free, ownChatGPT: true), .allowed)
        XCTAssertEqual(UFFeatureMatrix.access(.autoPlan, plan: .free, ownChatGPT: false), .locked(.plus))
        XCTAssertTrue(ChatGPTLink.planHint.contains("Eigenes ChatGPT"), "die KI-Stellen nennen den Weg zum Schluessel")
        XCTAssertEqual(AICost.line(chatgpt: false, plan: .plus, credits: 5), "Kommt mit StudiNow Pro AI oder deinem eigenen ChatGPT (Einstellungen → Erweitert)")
        XCTAssertEqual(AIPlanSuggestDialog.sourceLine(studinowAI: false, charged: nil), "Vorschlag über dein eigenes ChatGPT · 1 Anfrage")
        XCTAssertEqual(AIPlanSuggestDialog.sourceLine(studinowAI: true, charged: 7), "Vorschlag der StudiNow-KI · 7 Credits")
    }

    func testCardOffersKeyEntryAndNoChatGPTLogin() throws {
        let was = HostedEnvironment.accessibilityAutomation(true)
        defer { _ = HostedEnvironment.accessibilityAutomation(was) }
        let link = OpenAIKeyLink()
        link.use(userScope: "test-card-\(UUID().uuidString)", host: nil)
        let env = try hostWithEnvironment(OpenAIKeyCard(link: link))
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("Prüfen und speichern") } }, env.labels().joined(separator: " | "))
        let labels = env.labels()
        XCTAssertTrue(labels.contains { $0.contains("Eigenes ChatGPT") })
        XCTAssertTrue(labels.contains { $0.contains("Schlüssel bei OpenAI erstellen") })
        XCTAssertTrue(labels.contains { $0.contains("bleibt im Schlüsselbund dieses iPads") })
        XCTAssertFalse(labels.contains { $0 == "ChatGPT verbinden" }, "keine Anmeldung bei ChatGPT")
    }

    func testGeneratePlanDialogOffersTheAISuggestionOnlyWithAI() throws {
        let was = HostedEnvironment.accessibilityAutomation(true)
        defer { _ = HostedEnvironment.accessibilityAutomation(was) }
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        let off = try hostWithEnvironment(GeneratePlanDialog(api: nil, start: "2026-11-09") {})
        XCTAssertTrue(off.wait { off.labels().contains { $0 == "Erstellen" } }, off.labels().joined(separator: " | "))
        XCTAssertFalse(off.labels().contains { $0 == "KI-Vorschlag" })
        XCTAssertTrue(off.labels().contains { $0.contains("KI-Vorschlag: mit deinem eigenen ChatGPT") }, "ohne KI der Weg dahin")
        let on = try hostWithEnvironment(GeneratePlanDialog(api: nil, start: "2026-11-09") {}.environment(\.ufAIEnabled, true))
        XCTAssertTrue(on.wait { on.labels().contains { $0 == "KI-Vorschlag" } }, on.labels().joined(separator: " | "))
        XCTAssertFalse(on.labels().contains { $0.contains("KI-Vorschlag: mit") })
    }
}

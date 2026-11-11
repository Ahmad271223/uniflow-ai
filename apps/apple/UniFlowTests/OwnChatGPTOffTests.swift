import XCTest
@testable import UniFlow

/// „Eigenes ChatGPT“ ist überall aus (Vorgabe des Inhabers 11.11.2026: „dein ChatGPT erstmal überall entfernen“):
/// keine Karte unter Einstellungen → Erweitert, keine Zeile auf den Tarifkarten, keine Hinweise auf den eigenen
/// OpenAI-Schluessel, kein „über dein ChatGPT“; ein gespeicherter Schluessel wird nicht benutzt. Gilt auf iPhone, iPad
/// und Mac (eine App).
@MainActor
final class OwnChatGPTOffTests: XCTestCase {

    func testSwitchIsOffAndNothingOffersIt() {
        XCTAssertFalse(OpenAIKeyLink.isOffered)
        for plan in UFPlan.allCases {
            XCTAssertFalse(UFFeatureMatrix.added(in: plan).contains(.ownChatGPT), plan.rawValue)
            XCTAssertFalse(UFPlanCard.included(plan).contains { $0.title == UFFeature.ownChatGPT.title }, plan.rawValue)
        }
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.onDevice, .needsService)
        for text in [ChatGPTLink.planHint, GeneratePlanDialog.aiHint, UFNoServerContent.examsText,
                     AICost.line(chatgpt: false, plan: .free, credits: 3),
                     AICost.status(chatgpt: false, model: nil, plan: .plus, requestsThisMonth: 0),
                     TutorPanel.footer(page: 1, model: nil), ExamAskPanel.footer(nr: "1", model: nil),
                     QuizComposer.aiReason(access: .planRequired, chatgpt: false),
                     QuizComposer.aiReason(access: .unavailable, chatgpt: false)] {
            XCTAssertFalse(text.contains("ChatGPT"), text)
            XCTAssertFalse(text.contains("OpenAI"), text)
        }
        XCTAssertEqual(ChatGPTLink.planHint, "Die KI-Hilfe kommt mit der StudiNow-KI in StudiNow Pro AI.")
    }

    func testStoredKeyIsNotUsed() async {
        let link = OpenAIKeyLink()
        XCTAssertFalse(link.enabled)
        await link.refresh()
        XCTAssertFalse(link.enabled)
        XCTAssertFalse(Entitlements.shared.ownChatGPTConnected, "kein freier Lernplan ueber den Schluessel")
    }
}

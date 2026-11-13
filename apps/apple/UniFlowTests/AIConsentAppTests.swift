import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Einwilligung vor der StudiNow-KI (06.11.2026, App Store Review Guideline 5.1.2(i)): Hinweis "KI-Hilfe: Was wird
/// gesendet?" genau einmal vor der ersten Anfrage, Abbrechen schickt nichts, Widerruf fragt erneut, gleichzeitige
/// Anfragen teilen sich einen Hinweis, der echte Hinweis liegt ueber allem und hat beide Knoepfe. Dazu das
/// Datenschutz-Manifest im App-Bundle. Schein-Dienst ueber URLProtocol (`StudiNowAIAppTests.StubProtocol`), nie ins Netz.
@MainActor
final class AIConsentAppTests: XCTestCase {
    typealias Stub = StudiNowAIAppTests.StubProtocol

    /// Feste Antwort fuer `StudiNowAI(consent:)` in anderen Tests
    struct Fixed: AIConsentGate {
        let answer: Bool
        init(_ answer: Bool) { self.answer = answer }
        func ensureConsent() async -> Bool { answer }
    }

    /// Schein-Hinweis: zaehlt, wie oft er gezeigt wurde, und antwortet mit der naechsten Entscheidung (nil = offen lassen)
    final class FakePrompt {
        var shown = 0
        var answers: [Bool?] = []
        var open: (@MainActor (Bool) -> Void)?
        func presenter() -> AIConsentCenter.Presenter {
            { [unowned self] decide in
                shown += 1
                let a = answers.isEmpty ? true : answers.removeFirst()
                if let a { decide(a) } else { open = decide }
                return true
            }
        }
    }

    override func setUp() {
        super.setUp()
        Stub.reset()
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    private func store() throws -> AIConsentStore {
        let name = "uniflow.tests.aiconsent.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return AIConsentStore(defaults: d)
    }

    final class Tokens: AccountTokenStore, @unchecked Sendable {
        func load() -> String? { "tok" }
        func save(_ token: String?) throws {}
    }

    /// Konto mit Pro AI, StudiNow-KI gegen den Schein-Dienst, eigene Einwilligung; Backend mit dieser KI
    private func setUpAI(_ prompt: FakePrompt) async throws -> (StudoraAccountLink, LocalBackend) {
        let link = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .proAI))
        link.consentCenter = AIConsentCenter(store: try store(), present: prompt.presenter())
        link.attachAI(base: "https://dienst.example", http: URLSessionServiceTransport(session: Stub.session()), tokens: Tokens())
        XCTAssertEqual(link.aiAccess, .ready)
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-06T09:00:00")!)
        backend.context.ai.setService(link.studinowAI)
        Stub.on("/api/ai/relay", 200, ["answer": "Antwort vom Dienst", "model": "gpt-6-luna", "shared": false])
        return (link, backend)
    }

    private func ask(_ b: LocalBackend) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                    headers: ["Content-Type": "application/json"],
                                    body: (["mode": "explain", "page_text": "Folgen", "selection": "Grenzwert"] as JSONValue).serialized()))
    }

    private func relayCount() -> Int { Stub.requests.filter { $0.path == "/api/ai/relay" }.count }

    // MARK: Ablauf

    func testConsentIsShownOnceBeforeTheFirstKIRequest() async throws {
        let prompt = FakePrompt()
        prompt.answers = [true]
        let (link, b) = try await setUpAI(prompt)
        XCTAssertNil(link.aiConsentGrantedAt)
        let first = await ask(b)
        XCTAssertEqual(first.status, 200, String(decoding: first.body, as: UTF8.self))
        XCTAssertEqual(prompt.shown, 1, "vor der ersten Anfrage gefragt")
        XCTAssertEqual(relayCount(), 1)
        XCTAssertNotNil(link.aiConsentGrantedAt)
        let second = await ask(b)
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(prompt.shown, 1, "danach nicht mehr")
        XCTAssertEqual(relayCount(), 2)
    }

    func testCancelSendsNothingAndAsksAgainNextTime() async throws {
        let prompt = FakePrompt()
        prompt.answers = [false, true]
        let (link, b) = try await setUpAI(prompt)
        let denied = await ask(b)
        XCTAssertEqual(denied.status, 403)
        let e = APIError(status: denied.status, body: denied.body)
        XCTAssertEqual(e.code, AIConsentText.code)
        XCTAssertEqual(e.errorDescription, AIConsentText.declined)
        XCTAssertTrue(Stub.requests.isEmpty, "Abbrechen: keine Anfrage an den Dienst")
        XCTAssertNil(link.aiConsentGrantedAt)
        XCTAssertNil(StudoraAccountLink.errorAction(e, account: nil), "kein Tarif- oder Anmeldeknopf")
        let ok = await ask(b)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(prompt.shown, 2)
        XCTAssertEqual(relayCount(), 1)
    }

    func testRevokeAsksAgain() async throws {
        let prompt = FakePrompt()
        prompt.answers = [true, true]
        let (link, b) = try await setUpAI(prompt)
        _ = await ask(b)
        XCTAssertNotNil(link.aiConsentGrantedAt)
        link.revokeAIConsent()
        XCTAssertNil(link.aiConsentGrantedAt)
        _ = await ask(b)
        XCTAssertEqual(prompt.shown, 2, "nach dem Widerruf wieder gefragt")
        XCTAssertEqual(relayCount(), 2)
    }

    func testConcurrentRequestsShareOneSheetAndConsentIsPerAccount() async throws {
        let prompt = FakePrompt()
        prompt.answers = [nil]
        let center = AIConsentCenter(store: try store(), present: prompt.presenter())
        async let a = center.ensure(account: "konto:1")
        async let b = center.ensure(account: "konto:1")
        let deadline = Date().addingTimeInterval(5)
        while prompt.open == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        prompt.open?(true)
        let results = await [a, b]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(prompt.shown, 1, "ein Hinweis fuer beide Anfragen")
        XCTAssertTrue(center.isGranted("konto:1"))
        XCTAssertFalse(center.isGranted("konto:2"), "je StudiNow-Konto")
        prompt.answers = [false]
        let other = await center.ensure(account: "konto:2")
        XCTAssertFalse(other)
    }

    func testWithoutWindowNothingIsSent() async throws {
        let center = AIConsentCenter(store: try store(), present: { _ in false })
        let granted = await center.ensure(account: "konto:x")
        XCTAssertFalse(granted, "Hinweis nicht zeigbar = Abbrechen")
    }

    // MARK: Echter Hinweis

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func labels(_ view: UIView) -> [String] { elements(in: view).compactMap(\.accessibilityLabel) }

    private func tap(_ label: String, in view: UIView) -> Bool {
        elements(in: view).contains { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label && $0.accessibilityActivate() }
    }

    func testSheetNamesWhatAndWhomAndBothButtonsDecide() throws {
        var decisions: [Bool] = []
        let env = try hostWithEnvironment(AIConsentSheet { decisions.append($0) }, size: CGSize(width: 600, height: 900))
        XCTAssertTrue(env.wait { self.labels(env.view).contains(AIConsentText.title) }, labels(env.view).joined(separator: "\n"))
        // kurz zuerst: was und an wen in zwei Saetzen, Details erst auf Tipp
        let short = labels(env.view).joined(separator: "\n")
        for needle in ["OpenAI", "Amazon Bedrock", "Datenschutzerklärung", AIConsentText.details, AIConsentText.accept] {
            XCTAssertTrue(short.contains(needle), needle + "\n" + short)
        }
        XCTAssertFalse(short.contains("Wohin es geht"), "Details erst nach \"Genauer ansehen\"")
        XCTAssertTrue(tap(AIConsentText.details, in: env.view))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Wohin es geht") }, labels(env.view).joined(separator: "\n"))
        let all = labels(env.view).joined(separator: "\n")
        for needle in ["Was gesendet wird", "Wohin es geht", "app.studinow.app", "OpenAI", "Amazon Bedrock", "Datenschutzerklärung",
                       AIConsentText.accept, AIConsentText.cancel] {
            XCTAssertTrue(all.contains(needle), needle + "\n" + all)
        }
        XCTAssertTrue(tap(AIConsentText.cancel, in: env.view))
        XCTAssertTrue(tap(AIConsentText.accept, in: env.view))
        XCTAssertEqual(decisions, [false, true])
    }

    /// Der echte Hinweis erscheint als Formblatt ueber dem obersten Inhalt; "Okay, los" gibt die
    /// wartende Anfrage frei und schliesst ihn
    func testRealPresenterShowsTheSheetOverTheTopController() throws {
        let env = try hostWithEnvironment(Text("Editor"), size: CGSize(width: 1180, height: 820))
        let center = AIConsentCenter(store: try store())
        var result: Bool?
        Task { @MainActor in result = await center.ensure(account: "konto:echt") }
        XCTAssertTrue(env.wait { env.hosting.presentedViewController is UIHostingController<AIConsentSheet> })
        let sheet = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(sheet.modalPresentationStyle, .formSheet)
        XCTAssertTrue(sheet.isModalInPresentation, "nur ueber die Knoepfe zu schliessen")
        XCTAssertNil(result, "die Anfrage wartet auf die Entscheidung")
        XCTAssertTrue(env.wait { self.tap(AIConsentText.accept, in: sheet.view) }, labels(sheet.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { result != nil })
        XCTAssertEqual(result, true)
        XCTAssertTrue(center.isGranted("konto:echt"))
        XCTAssertTrue(env.wait { env.hosting.presentedViewController == nil })
    }

    // MARK: Einstellungen

    func testSettingsRowShowsStateAndRevokes() throws {
        let link = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .proAI))
        link.consentCenter = AIConsentCenter(store: try store(), present: { _ in false })
        link.consentCenter.store.grant(link.aiConsentAccount)
        XCTAssertNotNil(link.aiConsentGrantedAt)
        let env = try hostWithEnvironment(AIConsentRow(link: link, center: link.consentCenter), size: CGSize(width: 700, height: 300))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("KI-Einwilligung erteilt am") } }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap(AIConsentText.revokeButton, in: env.view))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasPrefix("KI-Einwilligung: noch nicht erteilt") } }, labels(env.view).joined(separator: "\n"))
        XCTAssertFalse(labels(env.view).contains(AIConsentText.revokeButton))
        XCTAssertNil(link.aiConsentGrantedAt)
        XCTAssertTrue(AIConsentRow.text(grantedAt: Date(timeIntervalSince1970: 1_793_966_400)).contains("am 6. November 2026"))
    }

    // MARK: Datenschutz-Manifest

    /// PrivacyInfo.xcprivacy im App-Bundle: kein Tracking, keine Tracking-Domains, Datenarten wie App-Datenschutz in
    /// docs/release/APP-STORE.md (alle verknuepft, nie Tracking, nur App-Funktionalitaet), Gruende der genutzten APIs
    func testPrivacyManifestMatchesTheApp() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "Manifest im Bundle")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        // Geraete-ID seit Audit P46-04 (08.11.2026): zufaellige Installationskennung als device_id beim Dienst
        XCTAssertEqual(types, ["NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeUserID",
                               "NSPrivacyCollectedDataTypeDeviceID", "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeOtherUserContent",
                               "NSPrivacyCollectedDataTypeProductInteraction"])
        for t in collected {
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for a in apis {
            let type = try XCTUnwrap(a["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = Set(try XCTUnwrap(a["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        XCTAssertEqual(reasons, ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                                 "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
                                 "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
                                 "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]])
    }
}

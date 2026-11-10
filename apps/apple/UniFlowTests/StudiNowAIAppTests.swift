import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// StudiNow-KI auf dem iPad (05.11.2026, docs/ABO-SYSTEM.md Abschnitt 6b): Weg der KI je Tarif und Anmeldung, die echte
/// URLSession-Anbindung gegen eine URLProtocol-Attrappe (nie ins Netz, keine echte KI), KI-Hilfe und KI-Start mit
/// Antwort und Credits, Tarif-Hinweis (Plus) und Anmelde-Hinweis (Pro AI ohne Konto), Knoepfe zu Fehlern.
@MainActor
final class StudiNowAIAppTests: XCTestCase {

    /// Schein-Dienst fuer URLSession: feste Antworten je Pfad, merkt sich Anfragen mit Rumpf
    final class StubProtocol: URLProtocol {
        struct Seen { let method: String; let path: String; let headers: [String: String]; let body: JSONValue? }
        nonisolated(unsafe) static var replies: [String: (Int, JSONValue)] = [:]
        nonisolated(unsafe) static var seen: [Seen] = []
        static let lock = NSLock()

        static func reset() { lock.withLock { replies = [:]; seen = [] } }
        static func on(_ path: String, _ status: Int, _ body: JSONValue) { lock.withLock { replies[path] = (status, body) } }
        static var requests: [Seen] { lock.withLock { seen } }

        static func session() -> URLSession {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: c)
        }

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dienst.example" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
            }
            let path = request.url?.path ?? ""
            let (status, body): (Int, JSONValue) = Self.lock.withLock {
                Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: path, headers: request.allHTTPHeaderFields ?? [:],
                                      body: try? JSONValue.parse(data)))
                return Self.replies[path] ?? (404, ["detail": "nicht da"])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body.serialized())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class Tokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var t: String?
        init(_ t: String?) { self.t = t }
        func load() -> String? { lock.withLock { t } }
        func save(_ token: String?) throws { lock.withLock { t = token } }
    }

    private let credits: JSONValue = ["period": "2026-11", "allowance": 100, "used": 63, "reserved": 0, "remaining": 37, "plan": "pro_ai",
                                      "resets_at": "2026-12-01T00:00:00+01:00", "charged": 3, "replay": false]

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Dienst-Adresse und Weg der KI

    func testServiceURLDefaultsToTheStudiNowServiceAndOnlyHTTPS() {
        XCTAssertEqual(StudoraAccountLink.resolveServiceURL(info: nil, override: nil), "https://app.studinow.app")
        XCTAssertEqual(StudoraAccountLink.resolveServiceURL(info: "https://staging.studinow.app/", override: nil), "https://staging.studinow.app")
        XCTAssertNil(StudoraAccountLink.resolveServiceURL(info: "", override: nil), "leerer Eintrag schaltet den Dienst ab")
        XCTAssertNil(StudoraAccountLink.resolveServiceURL(info: "http://unsicher.example", override: nil), "nur https")
        XCTAssertEqual(StudoraAccountLink.resolveServiceURL(info: nil, override: "https://dienst.example"), "https://dienst.example",
                       "Startargument -StudoraServiceURL geht vor")
        XCTAssertEqual(StudoraAccountLink.resolveServiceURL(info: nil, override: "http://x"), "https://app.studinow.app")
    }

    /// Pro AI ohne Anmeldung -> Anmeldung; Pro AI mit Token -> bereit; Plus -> Tarif-Hinweis (nichts wird gesendet)
    func testAccessFollowsPlanAndSignIn() async throws {
        let pro = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .proAI))
        pro.use(userScope: "test-proai-\(UUID().uuidString)")
        XCTAssertEqual(pro.aiAccess, .signInRequired)
        pro.attachAI(base: "https://dienst.example", http: URLSessionServiceTransport(session: StubProtocol.session()), tokens: Tokens("tok"))
        XCTAssertEqual(pro.aiAccess, .ready)
        XCTAssertNotNil(pro.studinowAI)

        let plus = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .plus))
        plus.attachAI(base: "https://dienst.example", http: URLSessionServiceTransport(session: StubProtocol.session()), tokens: Tokens("tok"))
        XCTAssertEqual(plus.aiAccess, .planRequired)
        let free = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .free))
        free.use(userScope: "test-free-\(UUID().uuidString)")
        XCTAssertEqual(free.aiAccess, .planRequired)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "ohne Pro AI und ohne Anmeldung keine Anfrage")
        XCTAssertNil(Entitlements.shared.verifyOnServer, "ohne Anmeldung kein Melden von Kaeufen")
        XCTAssertEqual(StudoraAccountLink.errorButton(.signIn), "Mit StudiNow-Konto anmelden")
        XCTAssertEqual(StudoraAccountLink.errorButton(.plans), "Tarif ansehen")
        XCTAssertEqual(StudoraAccountCard.aiLine(.ready, credits: StudoraCredits.parse(credits), trial: false),
                       "StudiNow-KI bereit · 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertNotNil(StudoraAccountCard.aiLine(.signInRequired, credits: nil, trial: false))
        XCTAssertNil(StudoraAccountCard.aiLine(.planRequired, credits: nil, trial: false))
        // Hinweis auf der Uebersicht (Inhaber 10.11.2026): nur, wenn genau die Anmeldung fehlt
        XCTAssertTrue(ProAISignInHint.shows(.signInRequired))
        XCTAssertFalse(ProAISignInHint.shows(.ready))
        XCTAssertFalse(ProAISignInHint.shows(.planRequired))
        XCTAssertFalse(ProAISignInHint.shows(.unavailable))
        XCTAssertTrue(ProAISignInHint.text.contains("StudiNow-Konto") && ProAISignInHint.text.contains("Tests & Wiederholung"))
    }

    /// Echte Anbindung (URLSessionServiceTransport) bis ins lokale Backend: KI-Hilfe fragt den Dienst mit Token
    func testBackendAnswersThroughURLSessionAndTheStub() async throws {
        StubProtocol.on("/api/ai/relay", 200, ["answer": "Erklärung vom Dienst", "model": "claude-sonnet", "shared": false, "credits": credits])
        let box = Box()
        let ai = StudiNowAI(base: "https://dienst.example", http: URLSessionServiceTransport(session: StubProtocol.session()), tokens: Tokens("tok"),
                            consent: AIConsentAppTests.Fixed(true), onCredits: { box.set($0) })
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-05T09:00:00")!)
        backend.context.ai.setService(ai)
        let r = await backend.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                                  headers: ["Content-Type": "application/json"],
                                                  body: (["mode": "explain", "page_text": "Folgen", "selection": "Grenzwert"] as JSONValue).serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"], "Erklärung vom Dienst")
        XCTAssertEqual(r.json?["credits"]?["remaining"], 37)
        let req = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/ai/relay")
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(req.body?["task"], "tutor:explain")
        XCTAssertEqual(box.value?["remaining"], 37)

        // Dienst sagt "nur Pro AI": Status und Code kommen durch, Text verstaendlich
        StubProtocol.on("/api/ai/relay", 403, ["detail": ["detail": "x", "code": "plan_required"]])
        let denied = await backend.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                                       headers: ["Content-Type": "application/json"],
                                                       body: (["mode": "ask", "page_text": "Folgen", "question": "Warum?"] as JSONValue).serialized()))
        XCTAssertEqual(denied.status, 403)
        let e = APIError(status: denied.status, body: denied.body)
        XCTAssertEqual(e.code, "plan_required")
        XCTAssertEqual(e.errorDescription, StudiNowAIText.planRequired(nil))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v: JSONValue?
        func set(_ x: JSONValue) { lock.withLock { v = x } }
        var value: JSONValue? { lock.withLock { v } }
    }

    // MARK: Ansichten

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func button(_ label: String, in view: UIView) -> NSObject? {
        elements(in: view).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) && e.accessibilityLabel == label {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func suite() throws -> UserDefaults {
        let name = "uniflow.tests.studinowai.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func transport() -> AIViewsAppTests.Transport {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/modules", [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"]])
        t.answer("/api/library", ["files": [
            ["id": "f-1", "name": "VL01.pdf", "title": "VL01.pdf", "ai_title": "Folgen und Grenzwerte", "module_id": 1, "downloaded_at": "2026-10-20T10:00:00",
             "kind": "pdf", "last_opened": "2026-10-30T10:00:00", "page_count": 12, "chdate": 1_761_000_000, "doc_type": "vorlesung"],
        ], "modules": [], "folders": [], "trash": []])
        t.answer("/api/flashcards", [])
        t.answer("/api/tests", [])
        t.answer("/api/bg", ["running": false, "task": .null, "message": ""])
        return t
    }

    private func api(_ t: AIViewsAppTests.Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private func proLink() -> StudoraAccountLink { StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .proAI)) }

    /// KI-Start mit Pro AI und Anmeldung: Frage geht los, Antwort steht da, die Kostenzeile nennt die StudiNow-KI und den
    /// echten Rest nach der Antwort (nie "über dein ChatGPT")
    func testStartPageWithStudiNowAIAnswersAndShowsCredits() throws {
        let t = transport()
        t.answer("/api/ai/tutor", ["answer": "Ein Grenzwert ist der Wert, dem sich die Folge nähert.", "cards": .null, "sources": [],
                                   "explain": .null, "credits": credits])
        let link = proLink()
        let view = AIStartView(entitlements: Entitlements(observe: false, plan: .proAI), recents: AIRecents(defaults: try suite(), scope: "s"))
            .environment(\.ufAIEnabled, true).environment(\.ufStudiNowAI, true).environment(\.ufAIAccess, .ready)
            .environment(\.ufStudoraAccount, link)
        let env = try hostWithEnvironment(view, api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "StudiNow-KI (Pro AI)") }, texts(env.view).joined(separator: "\n"))
        XCTAssertFalse(shows(env.view, "über dein ChatGPT"))
        XCTAssertTrue(env.wait { self.elements(in: env.view).contains { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasPrefix("Erklären / PDF analysieren") == true } })
        XCTAssertTrue(elements(in: env.view).contains { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasPrefix("Erklären / PDF analysieren") == true && $0.accessibilityActivate() })
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        XCTAssertTrue(env.wait { self.shows(env.view, "dem sich die Folge nähert") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.shows(env.view, "– 3 Credits (37 übrig)") }, texts(env.view).joined(separator: "\n"))
        XCTAssertEqual(link.credits?.remaining, 37)
    }

    /// Plus: KI-Start zeigt den Tarif-Hinweis mit "Tarife ansehen", Senden gesperrt, nichts geht los
    func testPlusShowsThePlanHint() throws {
        let t = transport()
        let view = AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: AIRecents(defaults: try suite(), scope: "p"))
            .environment(\.ufAIAccess, .planRequired)
        let env = try hostWithEnvironment(view, api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Die KI-Hilfe kommt mit der StudiNow-KI") }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Tarife ansehen", in: env.view))
        XCTAssertNil(button("Mit StudiNow-Konto anmelden", in: env.view))
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0)
    }

    /// Pro AI ohne Anmeldung: Hinweis und Knopf zur Anmeldung statt Tarif-Hinweis; nichts geht los
    func testProAIWithoutSignInAsksToSignIn() throws {
        let t = transport()
        let view = AIStartView(entitlements: Entitlements(observe: false, plan: .proAI), recents: AIRecents(defaults: try suite(), scope: "a"))
            .environment(\.ufAIAccess, .signInRequired)
        let env = try hostWithEnvironment(view, api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, StudoraAccountLink.aiSignInHint) }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Mit StudiNow-Konto anmelden", in: env.view))
        XCTAssertNil(button("Tarife ansehen", in: env.view))
        XCTAssertTrue(tap("Mit StudiNow-Konto anmelden", in: env.view))
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0)
        XCTAssertEqual(TutorConnectState.reason(nil, access: .signInRequired), .signIn)
        XCTAssertEqual(TutorConnectState.reason(nil, access: .planRequired), .notConnected)
        XCTAssertEqual(TutorConnectState.Content.text(.signIn).info, StudoraAccountLink.aiSignInHint)
    }

    /// KI-Hilfe im Editor mit der StudiNow-KI: Modus antippen -> Antwort, Fusszeile "StudiNow-KI · – 3 Credits"; ein
    /// Fehler "Credits aufgebraucht" zeigt "Tarif ansehen", eine abgelaufene Anmeldung "Mit StudiNow-Konto anmelden"
    func testTutorPanelAnswersViaStudiNowAIAndOffersTheRightButtonOnErrors() throws {
        let t = transport()
        let id = "f-sn-\(UUID().uuidString.prefix(8))"
        t.answer("/api/index/file/\(id)/page/1", ["file_id": .string(id), "page": 1, "status": "none", "can_build": false])
        t.answer("/api/ai/tutor", ["answer": "Zusammenfassung vom Dienst", "cards": .null, "sources": [], "explain": .null, "credits": credits])
        let link = proLink()
        let panel = TutorPanel(fileID: id, page: { 1 }, selection: { "" }, open: { _, _ in }, close: {})
            .environment(\.ufAIEnabled, true).environment(\.ufStudiNowAI, true).environment(\.ufAIAccess, .ready)
            .environment(\.ufStudoraAccount, link)
        let env = try hostWithEnvironment(panel, api: api(t), size: CGSize(width: 420, height: 820))
        XCTAssertTrue(env.wait { self.shows(env.view, "Seite 1 · StudiNow-KI") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Zusammenfassen", in: env.view), texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.shows(env.view, "Zusammenfassung vom Dienst") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.shows(env.view, "Seite 1 · StudiNow-KI · – 3 Credits (37 übrig)") }, texts(env.view).joined(separator: "\n"))
        XCTAssertFalse(shows(env.view, "über dein ChatGPT"))

        t.fail("/api/ai/tutor", 429, ["detail": ["detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted"]])
        XCTAssertTrue(tap("Zusammenfassen", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Credits für diesen Monat aufgebraucht") }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Tarif ansehen", in: env.view))

        t.fail("/api/ai/tutor", 401, ["detail": ["detail": .string(StudiNowAIText.sessionExpired), "code": "account_required"]])
        XCTAssertTrue(tap("Zusammenfassen", in: env.view))
        XCTAssertTrue(env.wait { self.button("Mit StudiNow-Konto anmelden", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, StudiNowAIText.sessionExpired))
    }

    func testFooterAndStatusNameTheStudiNowAI() {
        let c = StudoraCredits.parse(credits)
        XCTAssertEqual(TutorPanel.footer(page: 2, model: nil, credits: c, studinow: true), "Seite 2 · StudiNow-KI · Credits: 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(TutorPanel.footer(page: 2, model: nil, credits: c, charge: .init(credits: 3, replay: false), studinow: true),
                       "Seite 2 · StudiNow-KI · – 3 Credits (37 übrig)")
        XCTAssertEqual(TutorPanel.footer(page: 2, model: nil, studinow: true), "Seite 2 · StudiNow-KI")
        XCTAssertEqual(TutorPanel.footer(page: 1, model: nil), "Seite 1 · über dein ChatGPT", "ohne StudiNow-KI wie bisher")
    }
}

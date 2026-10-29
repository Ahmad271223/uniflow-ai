import Foundation
import XCTest
@testable import UniFlowCore

// KI wie am PC: packages/shared-contracts/ai/contract.json (tools/gen-ai-contract.py aus app/ai.py und
// app/chatgpt_login.py). Prompts byte-gleich, Antworten gleich geprueft, Sign in with ChatGPT gleich gebaut.

private func contract() throws -> PyJSON {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try PyJSON.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/ai/contract.json")))
}

private func g(_ v: PyJSON?, _ key: String) -> PyJSON? { AIPrompts.get(v, key) }
private func s(_ v: PyJSON?, _ key: String) -> String { if case .string(let t)? = g(v, key) { return t }; return "" }
private func list(_ v: PyJSON?, _ key: String) -> [PyJSON] { if case .array(let a)? = g(v, key) { return a }; return [] }

final class AIContractTests: XCTestCase {

    /// Erster Unterschied zweier Texte, fuer lesbare Fehlermeldungen
    private func diff(_ a: String, _ b: String) -> String {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let i = zip(x, y).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(x.count, y.count)
        func around(_ u: [Unicode.Scalar]) -> String {
            String(String.UnicodeScalarView(u[max(0, i - 40)..<min(u.count, i + 40)]))
        }
        return "ab Zeichen \(i):\n  Swift  \(around(x).debugDescription)\n  Python \(around(y).debugDescription)"
    }

    private func same(_ swift: String, _ python: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(swift.unicodeScalars.elementsEqual(python.unicodeScalars), "\(label): \(diff(swift, python))", file: file, line: line)
    }

    func testTextsMatchPython() throws {
        let t = g(try contract(), "texts")
        same(AIPromptTexts.system, s(t, "system"), "SYSTEM")
        same(AIPromptTexts.tutorSystem, s(t, "tutor_system"), "TUTOR_SYSTEM")
        same(AIPromptTexts.analysisFields, s(t, "analysis_fields"), "ANALYSIS_FIELDS")
        guard case .object(let modes)? = g(t, "tutor_modes"), case .object(let diff)? = g(t, "week_test_difficulty") else {
            return XCTFail("tutor_modes/week_test_difficulty fehlen")
        }
        XCTAssertEqual(AIPromptTexts.tutorModes.map(\.key), modes.map(\.key), "Modi und Reihenfolge")
        for (m, p) in zip(AIPromptTexts.tutorModes, modes) { same(m.text, PyText.str(p.value), m.key) }
        XCTAssertEqual(AIPromptTexts.weekTestDifficulty.map { "\($0.level)=\($0.count)" }, diff.map { "\($0.key)=\(PyText.str($0.value))" })
        XCTAssertEqual(g(t, "week_test_total"), .int(String(AIPromptTexts.weekTestTotal)))
        XCTAssertEqual(list(t, "week_test_types"), AIPromptTexts.weekTestTypes.map { .string($0) })
    }

    func testTutorPromptsMatchPython() throws {
        let cases = list(g(try contract(), "prompts"), "tutor")
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for (i, c) in cases.enumerated() {
            let a = g(c, "in")
            var sources: [PyJSON]?
            if case .array(let src)? = g(a, "sources") { sources = src }
            let p = AIPrompts.tutor(mode: s(a, "mode"), pageText: s(a, "page_text"), selection: s(a, "selection"), question: s(a, "question"),
                                    ownSolution: s(a, "own_solution"), course: s(a, "course"), fileName: s(a, "file_name"),
                                    page: g(a, "page"), sources: sources)
            same(p, s(c, "prompt"), "Tutor \(i) \(s(a, "mode"))")
        }
    }

    func testAnalysisAndGradePromptsMatchPython() throws {
        let prompts = g(try contract(), "prompts")
        for (i, c) in list(prompts, "analysis").enumerated() {
            let a = g(c, "in")
            same(AIPrompts.analysis(course: s(a, "course"), fileName: s(a, "file_name"), text: s(a, "text")), s(c, "prompt"), "Analyse \(i)")
        }
        for (i, c) in list(prompts, "grade").enumerated() {
            let a = g(c, "in")
            same(AIPrompts.grade(subject: s(a, "subject"), questions: list(a, "questions"), answers: g(a, "answers") ?? .object([])),
                 s(c, "prompt"), "Bewertung \(i)")
        }
    }

    func testWeekPlanPromptsMatchPython() throws {
        for (i, c) in list(g(try contract(), "prompts"), "week_plan").enumerated() {
            let a = g(c, "in")
            let p = AIPrompts.weekPlan(weekStart: try XCTUnwrap(AIPrompts.Day(iso: s(a, "week_start"))), materials: list(a, "materials"),
                                       subjects: list(a, "subjects"), settings: g(a, "settings") ?? .null, carryOver: list(a, "carry_over"),
                                       today: try XCTUnwrap(AIPrompts.Day(iso: s(a, "today"))))
            same(p, s(c, "prompt"), "Wochenplan \(i)")
        }
    }

    func testWeekTestPromptsMatchPython() throws {
        for (i, c) in list(g(try contract(), "prompts"), "week_test").enumerated() {
            let a = g(c, "in")
            let block = AIPrompts.testTextBlock(list(a, "materials")), exam = AIPrompts.examTextBlock(g(a, "exam"))
            same(block, s(c, "text_block"), "Materialblock \(i)")
            same(exam, s(c, "exam_block"), "Klausurblock \(i)")
            guard case .int(let minutes)? = g(a, "duration_min") else { return XCTFail("duration_min") }
            same(AIPrompts.weekTest(subject: s(a, "subject"), durationMin: Int(minutes)!, materialsBlock: block, examBlock: exam),
                 s(c, "prompt"), "Wochentest \(i)")
        }
    }

    func testParseJSONMatchesPython() throws {
        let cases = list(try contract(), "parse_json")
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for c in cases {
            let input = s(c, "in")
            if let expected = g(c, "out") {
                XCTAssertEqual(try AIAnswers.parseJSON(input), expected, input)
            } else {
                XCTAssertThrowsError(try AIAnswers.parseJSON(input), input) { e in
                    XCTAssertEqual((e as? AIError)?.message.components(separatedBy: ":").first, s(c, "error"), input)
                }
            }
        }
    }

    func testWeekTestCheckMatchesPython() throws {
        let cases = list(try contract(), "check_week_test")
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let exam = g(c, "exam") == .bool(true)
            let expected: String? = { if case .string(let r)? = g(c, "reason") { return r }; return nil }()
            XCTAssertEqual(AIAnswers.checkWeekTest(g(c, "in") ?? .null, exam: exam), expected, s(c, "name"))
        }
    }

    func testChatGPTProtocolMatchesPython() throws {
        let cg = g(try contract(), "chatgpt")
        for (k, v) in [("auth_url", ChatGPTConstants.authURL), ("token_url", ChatGPTConstants.tokenURL), ("issuer", ChatGPTConstants.issuer),
                       ("jwks_url", ChatGPTConstants.jwksURL), ("resource", ChatGPTConstants.resource), ("responses_url", ChatGPTConstants.responsesURL),
                       ("models_url", ChatGPTConstants.modelsURL), ("usage_help_url", ChatGPTConstants.usageHelpURL), ("scope", ChatGPTConstants.scope),
                       ("usage_scope", ChatGPTConstants.usageScope), ("first_client_id", ChatGPTConstants.firstClientID),
                       ("agent_name", ChatGPTConstants.agentName), ("callback_path", ChatGPTConstants.callbackPath)] {
            XCTAssertEqual(v, s(cg, k), k)
        }
        XCTAssertEqual(ChatGPTConstants.agentName, "Studora", "sichtbarer Name auf der Zustimmungsseite")
        for a in list(cg, "authorize") {
            func opt(_ k: String) -> String? { if case .string(let v)? = g(a, k) { return v }; return nil }
            let url = ChatGPTProtocol.authorizeURL(clientID: opt("client_id"), host: s(a, "host"), redirectURI: s(a, "redirect_uri"),
                                                   state: s(a, "state"), nonce: s(a, "nonce"), challenge: s(a, "challenge"),
                                                   idTokenHint: opt("id_token_hint"))
            same(url, s(a, "url"), "Autorisierung \(s(a, "state"))")
        }
        for p in list(cg, "pkce") { XCTAssertEqual(ChatGPTProtocol.challenge(for: s(p, "verifier")), s(p, "challenge")) }
        for c in list(cg, "credentials") {
            let prev: ChatGPTProtocol.Credentials? = {
                guard let pv = g(c, "previous"), pv != .null else { return nil }
                return .init(accessToken: "alt", refreshToken: s(pv, "refresh_token"), idToken: s(pv, "id_token"), tokenType: "Bearer",
                             expiresAt: 0, scopes: list(pv, "scopes").map { PyText.str($0) })
            }()
            let resp = g(c, "response") ?? .null
            if case .string(let code)? = g(c, "error") {
                XCTAssertThrowsError(try ChatGPTProtocol.credentials(from: resp, previous: prev, now: 1000)) { XCTAssertEqual(($0 as? AIError)?.code, code) }
                continue
            }
            let got = try ChatGPTProtocol.credentials(from: resp, previous: prev, now: 1000)
            let e = g(c, "credentials")
            func opt(_ k: String) -> String? { if case .string(let v)? = g(e, k) { return v }; return nil }
            XCTAssertEqual(got.accessToken, s(e, "access_token"))
            XCTAssertEqual(got.refreshToken, opt("refresh_token"))
            XCTAssertEqual(got.idToken, opt("id_token"))
            XCTAssertEqual(got.tokenType, s(e, "token_type"))
            XCTAssertEqual(got.scopes, list(e, "scopes").map { PyText.str($0) })
            XCTAssertEqual(got.expiresAt - 1000, Double(PyText.str(g(e, "expires_in_used") ?? .null)))
        }
        for r in list(cg, "responses_request") {
            let schema: JSONValue? = { guard let v = g(r, "schema"), v != .null else { return nil }; return v.json }()
            XCTAssertEqual(ChatGPTProtocol.responsesBody(model: s(r, "model"), system: s(r, "system"), prompt: s(r, "prompt"), schema: schema),
                           g(r, "body")?.json)
        }
        for o in list(cg, "responses_output") { XCTAssertEqual(ChatGPTProtocol.outputText(g(o, "response")?.json ?? .null), s(o, "text")) }
        for e in list(cg, "errors") {
            guard case .int(let st)? = g(e, "status") else { return XCTFail("status") }
            let err = ChatGPTProtocol.error(status: Int(st)!)
            XCTAssertEqual(err.code, s(e, "code"), st)
            if g(e, "message") != nil { XCTAssertEqual(err.message, s(e, "message"), st) }
        }
        let form = ChatGPTProtocol.codeForm(clientID: "oaiapp_x", code: "c/1", verifier: "v", redirectURI: "http://127.0.0.1:5/auth/callback")
        XCTAssertEqual(form.split(separator: "&").map { String($0.split(separator: "=")[0]) },
                       ["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "resource"])
        XCTAssertTrue(form.hasPrefix("grant_type=authorization_code&") && form.contains("code=c%2F1"))
        XCTAssertTrue(ChatGPTProtocol.refreshForm(refreshToken: "rt", clientID: "id").hasPrefix("grant_type=refresh_token&refresh_token=rt&client_id=id&resource="))
    }

    func testVerifierAndTokensHaveTheRightShape() {
        var rng = SystemRandomNumberGenerator()
        let v = ChatGPTProtocol.newVerifier(using: &rng)
        XCTAssertEqual(v.count, 96)
        XCTAssertTrue(v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        XCTAssertNotEqual(v, ChatGPTProtocol.newVerifier(using: &rng))
        XCTAssertEqual(ChatGPTProtocol.randomToken(bytes: 32, using: &rng).count, 43)
    }
}

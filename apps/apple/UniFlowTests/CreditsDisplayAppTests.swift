import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Credits der StudiNow-KI auf dem iPad (04.11.2026, docs/ABO-SYSTEM.md Abschnitt 6a): Stand aus `GET /api/entitlements`
/// und aus KI-Antworten (`charged`, `replay`), die Kostenzeile aus dem echten Rest (KI-Start, KI-Hilfe, Einstellungen)
/// und der 429 `credits_exhausted` mit dem Text des Dienstes. Schein-Dienst wie in InviteAppTests; nie ins Netz.
@MainActor
final class CreditsDisplayAppTests: XCTestCase {
    /// `credits` wie `app/credits.py::_balance_dict`; `extra`: `charged`/`replay` einer KI-Antwort
    private func balance(allowance: Int = 100, used: Int = 63, reserved: Int = 0, remaining: Int? = 37,
                         resetsAt: String? = "2026-12-01T00:00:00+01:00", plan: String = "pro_ai", extra: [String: JSONValue] = [:]) -> JSONValue {
        var v: [String: JSONValue] = ["period": "2026-11", "allowance": .number(Double(allowance)), "used": .number(Double(used)),
                                      "reserved": .number(Double(reserved)), "plan": .string(plan), "credit_eur": 0.01]
        if let remaining { v["remaining"] = .number(Double(remaining)) }
        if let resetsAt { v["resets_at"] = .string(resetsAt) }
        for (k, x) in extra { v[k] = x }
        return .object(v)
    }

    private let exhaustedBody = #"{"detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted", "credits": {"period": "2026-11", "allowance": 100, "used": 98, "reserved": 0, "remaining": 2, "plan": "pro_ai", "resets_at": "2026-12-01T00:00:00+01:00", "credit_eur": 0.01, "needed": 3}}"#

    // MARK: Lesen

    func testParsesTheCreditsObjectAndStaysNilWithout() {
        let c = StudoraCredits.parse(balance())
        XCTAssertEqual(c, StudoraCredits(period: "2026-11", allowance: 100, used: 63, remaining: 37, resetsAt: "2026-12-01T00:00:00+01:00", plan: "pro_ai"))
        XCTAssertNil(StudoraCredits.parse(nil), "ohne Feld")
        XCTAssertNil(StudoraCredits.parse(.null), "am eigenen PC ist credits null")
        XCTAssertNil(StudoraCredits.parse(["period": "2026-11"]), "ohne Rahmen kein Stand")
        // ohne remaining rechnet die App selbst: Rahmen - verbraucht - reserviert, nie unter 0
        XCTAssertEqual(StudoraCredits.parse(balance(used: 90, reserved: 5, remaining: nil))?.remaining, 5)
        XCTAssertEqual(StudoraCredits.parse(balance(used: 120, remaining: nil))?.remaining, 0)
        XCTAssertNil(StudoraCredits.parse(balance(resetsAt: nil))?.resetsAt)
    }

    func testChargeComesFromTheCreditsObjectOfAnAnswer() {
        let answer: JSONValue = ["answer": "Text", "credits": balance(extra: ["charged": 3, "replay": false])]
        XCTAssertEqual(StudoraCredits.charge(in: answer), StudoraCredits.Charge(credits: 3, replay: false))
        let replayed = balance(extra: ["charged": 0, "replay": true])
        XCTAssertEqual(StudoraCredits.charge(in: ["answer": "Text", "credits": replayed]), StudoraCredits.Charge(credits: 0, replay: true))
        XCTAssertNil(StudoraCredits.charge(in: ["answer": "Text"]), "ohne Stand (ChatGPT auf dem Geraet) nichts berechnet")
        XCTAssertNil(StudoraCredits.charge(in: ["answer": "Text", "credits": .null]))
        XCTAssertEqual(StudoraCredits.charge(in: ["answer": "Text", "charged": 2]), StudoraCredits.Charge(credits: 2, replay: false), "zur Sicherheit auch oben")
    }

    func testClientReadsEntitlementsWithTheSessionToken() async throws {
        let stub = InviteAppTests.StubTransport()
        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "trial": ["active": false], "credits": balance()])
        let client = StudoraCredits.Client(base: "https://dienst.example/", http: stub, tokens: InviteAppTests.MemoryTokens("tok"))
        let c = try await client.fetch()
        XCTAssertEqual(c?.remaining, 37)
        XCTAssertEqual(c?.allowance, 100)
        let r = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(r.url, "https://dienst.example/api/entitlements", "kein doppelter Schraegstrich")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tok")

        // ohne Token keine Anfrage, ohne credits (eigener PC) und bei Fehler nil
        let silent = InviteAppTests.StubTransport()
        let none = try await StudoraCredits.Client(base: "https://dienst.example", http: silent, tokens: InviteAppTests.MemoryTokens(nil)).fetch()
        XCTAssertNil(none)
        XCTAssertEqual(silent.requests.count, 0)
        stub.on("GET", "/api/entitlements", 200, ["plan": "free", "credits": .null])
        let pc = try await client.fetch()
        XCTAssertNil(pc)
        stub.on("GET", "/api/entitlements", 401, ["detail": "Anmeldung erforderlich.", "code": "unauthenticated"])
        let failed = try await client.fetch()
        XCTAssertNil(failed)
    }

    func testTheAccountLinkKeepsTheBalanceAndTheLastCharge() async throws {
        let link = StudoraAccountLink()
        link.use(userScope: "test-credits-\(UUID().uuidString)")
        XCTAssertNil(link.credits, "ohne Dienst kein Stand")
        let stub = InviteAppTests.StubTransport()
        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "credits": balance()])
        link.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: stub, tokens: InviteAppTests.MemoryTokens("tok")))
        await link.refreshCredits()
        XCTAssertEqual(link.credits?.remaining, 37)
        XCTAssertNil(link.lastCharge)

        // eine berechnete Antwort: neuer Stand und was sie gekostet hat
        link.noteAIResponse(["answer": "Text", "credits": balance(used: 66, remaining: 34, extra: ["charged": 3, "replay": false])])
        XCTAssertEqual(link.credits?.remaining, 34)
        XCTAssertEqual(link.lastCharge, StudoraCredits.Charge(credits: 3, replay: false))
        // Antwort ohne Stand (ChatGPT auf dem Geraet, eigener PC): nichts aendert sich
        link.noteAIResponse(["answer": "Text"])
        XCTAssertEqual(link.credits?.remaining, 34)
        XCTAssertEqual(link.lastCharge?.credits, 3)

        // 429 credits_exhausted: Stand aus dem Rumpf, letzte Berechnung weg, Rueckgabe true; andere Fehler false
        let exhausted = APIError(status: 429, body: Data(exhaustedBody.utf8))
        XCTAssertTrue(link.noteAIError(exhausted))
        XCTAssertEqual(link.credits?.remaining, 2)
        XCTAssertEqual(link.credits?.used, 98)
        XCTAssertNil(link.lastCharge)
        XCTAssertFalse(link.noteAIError(APIError(status: 500, body: Data(#"{"detail": "Kaputt"}"#.utf8))))
        XCTAssertEqual(link.credits?.remaining, 2, "ein anderer Fehler laesst den Stand stehen")
        // gekuerzter Rumpf ohne JSON: der Rest ist dann 0
        let short = APIError(status: 429, message: "{\"code\": \"credits_exhausted\", \"detail\": \"abgeschnitten", detail: "abgeschnitten")
        var withCode = short
        withCode.code = "credits_exhausted"
        XCTAssertTrue(link.noteAIError(withCode))
        XCTAssertEqual(link.credits?.remaining, 0)

        // abmelden nimmt den Stand mit; ohne Token auch das Neuladen
        await link.logout()
        XCTAssertNil(link.credits)
        XCTAssertNil(link.lastCharge)
        link.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: stub, tokens: InviteAppTests.MemoryTokens(nil)))
        await link.refreshCredits()
        XCTAssertNil(link.credits)
    }

    // MARK: Kostenzeile

    func testBalanceLineWithPluralsZeroAndMissingData() {
        let c = StudoraCredits.parse(balance())
        XCTAssertEqual(AICost.balanceLine(c), "Credits: 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.balanceLine(c, labelled: false), "37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(used: 100, remaining: 0))), "Credits: 0 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(used: 99, remaining: 1))), "Credits: 1 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(resetsAt: nil))), "Credits: 37 von 100 übrig", "ohne Datum keine Erfindung")
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(resetsAt: "kein datum"))), "Credits: 37 von 100 übrig")
        XCTAssertNil(AICost.balanceLine(nil))
        // Probe: 25 im Monat, als Probe gekennzeichnet
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(allowance: 25, used: 4, remaining: 21)), trial: true),
                       "Credits: 21 von 25 übrig · Probe · neu am 1. Dezember")
        // Free/Plus/Pro Connect: kein Rahmen, ehrlich gesagt
        XCTAssertEqual(AICost.balanceLine(StudoraCredits.parse(balance(allowance: 0, used: 0, remaining: 0, plan: "plus"))), "Keine Credits in deinem Tarif")
    }

    func testResetLabelUsesGermanMonthsInBerlinTime() {
        XCTAssertEqual(AICost.resetLabel("2026-12-01T00:00:00+01:00"), "neu am 1. Dezember")
        XCTAssertEqual(AICost.resetLabel("2027-01-01T00:00:00+01:00"), "neu am 1. Januar")
        // Sommerzeit und UTC-Schreibweise (23:00Z am Vortag ist in Berlin schon der 1.)
        XCTAssertEqual(AICost.resetLabel("2026-07-01T00:00:00+02:00"), "neu am 1. Juli")
        XCTAssertEqual(AICost.resetLabel("2026-02-28T23:00:00Z"), "neu am 1. März")
        XCTAssertEqual(AICost.resetLabel("2026-12-01"), "neu am 1. Dezember", "nur das Datum")
        XCTAssertNil(AICost.resetLabel(nil))
        XCTAssertNil(AICost.resetLabel(""))
        XCTAssertEqual(AICost.germanMonths.count, 12)
    }

    func testChargeLineAndTheOrderOfFunding() {
        let c = StudoraCredits.parse(balance())
        XCTAssertEqual(AICost.chargeLine(.init(credits: 3, replay: false), remaining: 37), "– 3 Credits (37 übrig)")
        XCTAssertEqual(AICost.chargeLine(.init(credits: 1, replay: false), remaining: 37), "– 1 Credit (37 übrig)")
        XCTAssertEqual(AICost.chargeLine(.init(credits: 2, replay: false), remaining: nil), "– 2 Credits")
        XCTAssertEqual(AICost.chargeLine(.init(credits: 0, replay: true), remaining: 37), "Schon berechnet · 0 Credits")
        XCTAssertNil(AICost.chargeLine(.init(credits: 0, replay: false), remaining: 37), "nichts berechnet: der Stand gilt")

        // Reihenfolge: Geteiltes (0) -> eigenes ChatGPT (0) -> Credits
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: true, adopted: true, charge: .init(credits: 3, replay: false)), "Schon erklärt · 0 Credits")
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: true, charge: .init(credits: 3, replay: false)), "Dein ChatGPT – 0 Credits")
        XCTAssertEqual(AICost.creditsLine(credits: nil, chatgpt: true), "Dein ChatGPT – 0 Credits")
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: false, charge: .init(credits: 3, replay: false)), "– 3 Credits (37 übrig)")
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: false, charge: .init(credits: 0, replay: false)), "Credits: 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: false), "Credits: 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.creditsLine(credits: c, chatgpt: false, trial: true), "Credits: 37 von 100 übrig · Probe · neu am 1. Dezember")
        XCTAssertNil(AICost.creditsLine(credits: nil, chatgpt: false), "ohne Stand und ohne ChatGPT nichts zu sagen")
    }

    func testStatusLineOnAIStartAndFooterInTheTutorUseTheRealBalance() {
        let c = StudoraCredits.parse(balance())
        // ohne Stand wie bisher
        XCTAssertEqual(AICost.status(chatgpt: true, model: "gpt-x", plan: .plus, requestsThisMonth: 1), "1 Anfrage diesen Monat · über dein ChatGPT · gpt-x")
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .proAI, requestsThisMonth: 2), "2 Anfragen diesen Monat · StudiNow-KI (Pro AI)")
        // mit Stand: der echte Rest statt der Schaetzung
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .proAI, requestsThisMonth: 2, credits: c),
                       "2 Anfragen diesen Monat · Credits: 37 von 100 übrig · neu am 1. Dezember")
        XCTAssertEqual(AICost.status(chatgpt: true, model: "gpt-x", plan: .proAI, requestsThisMonth: 1, credits: c),
                       "1 Anfrage diesen Monat · Dein ChatGPT – 0 Credits · gpt-x")
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .proAI, requestsThisMonth: 3, credits: c, charge: .init(credits: 3, replay: false)),
                       "3 Anfragen diesen Monat · – 3 Credits (37 übrig)")
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .free, requestsThisMonth: 0, credits: StudoraCredits.parse(balance(allowance: 0, used: 0, remaining: 0, plan: "free"))),
                       "0 Anfragen diesen Monat · Keine Credits in deinem Tarif")

        XCTAssertEqual(TutorPanel.footer(page: 3, model: "gpt-x"), "Seite 3 · über dein ChatGPT · gpt-x")
        XCTAssertEqual(TutorPanel.footer(page: 3, model: "gpt-x", credits: c), "Seite 3 · Dein ChatGPT – 0 Credits · gpt-x")
        XCTAssertEqual(TutorPanel.footer(page: 3, model: nil, credits: c, adopted: true), "Seite 3 · Schon erklärt · 0 Credits")
        XCTAssertEqual(TutorPanel.footer(page: 3, model: nil, credits: c, charge: .init(credits: 3, replay: false)), "Seite 3 · – 3 Credits (37 übrig)")
        XCTAssertEqual(TutorPanel.footer(page: 1, model: nil, credits: c, charge: .init(credits: 0, replay: false)), "Seite 1 · Credits: 37 von 100 übrig · neu am 1. Dezember")
    }

    // MARK: 429

    func testExhaustedErrorShowsTheServiceTextAndItsState() {
        let e = APIError(status: 429, body: Data(exhaustedBody.utf8))
        XCTAssertEqual(e.code, "credits_exhausted")
        XCTAssertEqual(e.errorDescription, "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "der Text des Dienstes, kein eigener")
        XCTAssertTrue(StudoraCredits.isExhausted(e))
        let state = StudoraCredits.exhaustedState(e)
        XCTAssertEqual(state?.remaining, 2)
        XCTAssertEqual(state?.allowance, 100)
        // FastAPI mit Objekt in detail
        let nested = APIError(status: 429, body: Data(#"{"detail": {"detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted", "credits": {"allowance": 100, "used": 100, "remaining": 0, "needed": 3}}}"#.utf8))
        XCTAssertTrue(StudoraCredits.isExhausted(nested))
        XCTAssertEqual(nested.errorDescription, "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.")
        XCTAssertEqual(StudoraCredits.exhaustedState(nested)?.remaining, 0)
        // andere Fehler
        XCTAssertFalse(StudoraCredits.isExhausted(APIError(status: 429, body: Data(#"{"detail": "Zu viele Anfragen", "code": "rate_limited"}"#.utf8))))
        XCTAssertFalse(StudoraCredits.isExhausted(URLError(.notConnectedToInternet)))
    }

    func testSettingsExplanationIsHonestAndShort() {
        let t = StudoraCreditsRow.explanation
        XCTAssertTrue(t.contains("0,9 Cent"), "1 Credit = 0,9 Cent wie der Dienst (Entscheidung 08.11.2026)")
        XCTAssertFalse(t.contains("1 Credit ist 1 Cent"))
        XCTAssertTrue(t.contains("100"))
        XCTAssertTrue(t.contains("25"))
        XCTAssertTrue(t.contains("Tarif wechseln"))
        XCTAssertEqual(t.filter { $0 == "." }.count, 1, "ein Satz")
    }
}

import Foundation
import XCTest
@testable import UniFlowCore

// Neues Tarifmodell (Entscheidung des Inhabers vom 26.11.2026): Plus hat alle Funktionen, die StudiNow-KI darin geht
// nur mit Credits (Monats-Credits von Pro AI, Probe-Credits oder gekaufte); Pro AI = Plus + 120 Credits je Monat;
// Credits kaufen nur bezahltes Plus und Pro AI. Ausnahmen: eigener OpenAI-Schluessel und WhisperKit bleiben frei.
// Gegen einen Schein-Dienst (`FakeService`), nie ins Netz, keine echte KI.

private func plansContract() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/plans/plans.json")))
}

final class TarifeCreditsNeuTests: XCTestCase {
    private let base = "https://dienst.example"

    private func make() -> (StudiNowAI, FakeService) {
        let fake = FakeService()
        let ai = StudiNowAI(base: base, http: fake, tokens: MemoryTokenStore("tok"), consent: FixedConsent(true))
        ai.now = { Date(timeIntervalSince1970: 1_795_000_000) }          // 2026-11-17, vor dem naechsten Monat
        return (ai, fake)
    }

    private func backend(_ ai: StudiNowAI?, key: AIProvider? = nil) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-17T09:00:00")!)
        b.context.ai.setService(ai)
        b.context.ai.setKey(key)
        return b
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    /// Stand eines Plus-Kontos ohne Monats-Credits: `purchased` gekaufte, nutzbar fuer alles (seit 26.11.2026)
    private func plusBalance(purchased: Int) -> CreditPacks.Balance {
        CreditPacks.Balance(period: "2026-11", allowance: 0, remaining: 0, purchased: purchased, purchasedUsable: true,
                            purchasedScope: .all, canBuy: true, resetsAt: "2026-12-01T00:00:00+01:00", plan: "plus")
    }

    // MARK: Plus ohne Credits: keine StudiNow-KI

    func testPlusWithoutCreditsSendsNothingAndAnswersCreditsExhausted() async throws {
        let (ai, fake) = make()
        ai.creditGate = StudiNowCreditGate(plusBalance(purchased: 0))
        XCTAssertTrue(ai.creditGate.blocks(now: ai.now()))
        let b = try await backend(ai)
        // Zusammenfassung, Erklaerung, freie Frage: alles ohne Credits gesperrt ("Zusammenfassungen ohne Credits sollen nie klappen")
        for mode in ["summary", "explain", "ask"] {
            let r = await post(b, "/api/ai/tutor", ["mode": .string(mode), "page_text": "Folie 3", "question": "Was heißt das?"])
            XCTAssertEqual(r.status, 429, mode)
            XCTAssertEqual(r.json?["detail"]?["code"], "credits_exhausted", "derselbe Code wie vom Dienst: die App zeigt die Pakete (\(mode))")
            XCTAssertEqual(r.json?["detail"]?["detail"]?.string, StudiNowAIText.creditsRequired, mode)
        }
        // auch "Ganzes Dokument" geht nicht an den Dienst
        do {
            _ = try await ai.json("POST", "/api/ai/document/plan", body: ["pages": []])
            XCTFail("ohne Credits kein Dokument-Lauf")
        } catch let e as LocalHTTPError {
            XCTAssertEqual(e.status, 429)
            XCTAssertEqual(e.detail["code"]?.string, "credits_exhausted")
        }
        let sent = await fake.requests
        XCTAssertTrue(sent.isEmpty, "nichts ging an den Dienst: \(sent.map(\.url))")
        XCTAssertEqual(StudiNowAIText.action(code: "credits_exhausted"), .plans, "ohne Konto-Anschluss der Tarif; mit Kaufrecht zeigt die App die Pakete")
    }

    // MARK: Plus mit gekauften Credits: KI

    func testPlusWithPurchasedCreditsGetsTheAI() async throws {
        let (ai, fake) = make()
        ai.creditGate = StudiNowCreditGate(plusBalance(purchased: 80))
        XCTAssertFalse(ai.creditGate.blocks(now: ai.now()))
        XCTAssertEqual(ai.creditGate.available, 80)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "Kurz zusammengefasst: …", "credits": ["allowance": 0, "remaining": 0, "purchased": 77,
                                                                                                    "purchased_usable": true, "purchased_scope": "all", "charged": 3]])
        let b = try await backend(ai)
        let r = await post(b, "/api/ai/tutor", ["mode": "summary", "page_text": "Folie 3"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"], "Kurz zusammengefasst: …")
        let relay = await fake.last("/api/ai/relay")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(relay?.body))["task"], "tutor:summary", "Zusammenfassung mit Plus und Credits")
    }

    /// Ohne bekannten Stand entscheidet der Dienst; ein veralteter Stand (neuer Monat) sperrt nicht; Rueckmeldungen und
    /// Kaeufe kosten keine Credits und gehen immer
    func testGateOnlyBlocksAKnownEmptyBalanceBeforeTheNextMonth() async throws {
        XCTAssertFalse(StudiNowCreditGate().blocks(), "kein Stand: der Dienst entscheidet")
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T00:00:00+01:00"))
        let empty = StudiNowCreditGate(available: 0, resetsAt: reset)
        XCTAssertTrue(empty.blocks(now: reset.addingTimeInterval(-60)))
        XCTAssertFalse(empty.blocks(now: reset), "ab dem 1. gibt es neue Monats-Credits: wieder fragen")
        XCTAssertEqual(StudiNowCreditGate(plusBalance(purchased: 0)).resetsAt, reset)
        XCTAssertTrue(StudiNowCreditGate.isMetered(path: "/api/ai/relay"))
        XCTAssertTrue(StudiNowCreditGate.isMetered(path: "/api/ai/document/step"))
        XCTAssertFalse(StudiNowCreditGate.isMetered(path: "/api/ai/feedback"))
        XCTAssertFalse(StudiNowCreditGate.isMetered(path: "/api/exam-shop/mine"))

        let (ai, fake) = make()
        ai.creditGate = StudiNowCreditGate(available: 0, resetsAt: reset)
        await fake.on("POST", "/api/ai/feedback", 200, ["ok": true])
        let ok = try await ai.json("POST", "/api/ai/feedback", body: ["token": "t", "better": true])
        XCTAssertEqual(ok["ok"], true, "Rueckmeldung geht ohne Credits")
    }

    // MARK: Eigener OpenAI-Schluessel: ohne Credits

    func testOwnOpenAIKeyWorksWithoutCredits() async throws {
        let (ai, fake) = make()
        ai.creditGate = StudiNowCreditGate(available: 0)
        let key = FakeAI("Antwort über deinen eigenen Schlüssel")
        let b = try await backend(ai, key: key)
        XCTAssertTrue(b.context.ai.provider is FakeAI, "eigener Schluessel vor der StudiNow-KI")
        let r = await post(b, "/api/ai/tutor", ["mode": "summary", "page_text": "Folie 3"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"], "Antwort über deinen eigenen Schlüssel")
        XCTAssertEqual(key.prompts.count, 1)
        let sent = await fake.requests
        XCTAssertTrue(sent.isEmpty, "nichts an den StudiNow-Dienst, keine Credits")
        XCTAssertFalse(key.isMetered, "eigener Schluessel kostet StudiNow nichts")
    }

    // MARK: Credits kaufen: nur bezahltes Plus und Pro AI

    func testFreeAndTrialAloneCannotBuyCredits() throws {
        XCTAssertFalse(CreditPacks.canBuy(plan: "free", trialOnly: false), "Free darf keine Credits kaufen")
        XCTAssertFalse(CreditPacks.canBuy(plan: nil, trialOnly: false))
        XCTAssertFalse(CreditPacks.canBuy(plan: "plus", trialOnly: true), "die laufende Probe allein auch nicht")
        XCTAssertFalse(CreditPacks.canBuy(plan: "pro_ai", trialOnly: true))
        XCTAssertTrue(CreditPacks.canBuy(plan: "plus", trialOnly: false))
        XCTAssertTrue(CreditPacks.canBuy(plan: "pro_ai", trialOnly: false))
        XCTAssertTrue(CreditPacks.canBuy(plan: "pro_connect", trialOnly: false), "alter Schluessel wie Pro AI")
        // dieselbe Regel wie im Vertrag (plans.json `credit_packs`)
        let c = try plansContract()
        XCTAssertEqual(Set(c["credit_packs"]?["buy_plans"]?.array?.compactMap(\.string) ?? []), CreditPacks.buyPlans)
        XCTAssertEqual(c["credit_packs"]?["buy_in_trial"]?.bool, CreditPacks.buyInTrial)
        // ohne Kaufrecht des Dienstes nie ein Blatt mit Paketen
        XCTAssertFalse(CreditPacks.offersShop(CreditPacks.Balance(allowance: 0, remaining: 0, canBuy: false, plan: "free")))
    }

    // MARK: Pro AI 120 Credits, Probe 25, Plus 0

    func testProAIHas120CreditsAndTheTextsSayIt() throws {
        let c = try plansContract()
        XCTAssertEqual(c["credits"]?["pro_ai"]?.int, 120)
        XCTAssertEqual(c["credits"]?["pro_ai"]?.int, StudiNowAIText.proAIMonthlyCredits)
        XCTAssertEqual(c["credits"]?["plus"]?.int, 0)
        XCTAssertEqual(c["credits"]?["trial"]?.int, 25)
        XCTAssertEqual(c["trial"]?["plan"]?.string, "plus", "Probe: 7 Tage wie Plus")
        XCTAssertTrue(StudiNowAIText.planRequired(nil).contains("120 Credits im Monat"))
        XCTAssertFalse(StudiNowAIText.planRequired(nil).contains("80 Credits"))
        // jedes Recht mit `needs_credits` gehoert zu Plus: dieselben Tarife wie `StudiNowAIAccess.aiPlans`
        let rights = try XCTUnwrap(c["entitlements"]?.object)
        let ai = rights.filter { $0.value["needs_credits"]?.bool == true }
        XCTAssertFalse(ai.isEmpty)
        for (name, r) in ai { XCTAssertEqual(r["from"]?.string, "plus", name) }
        XCTAssertTrue(StudiNowAIAccess.aiPlans.isSuperset(of: ["plus", "pro_ai"]))
        XCTAssertFalse(StudiNowAIAccess.aiPlans.contains("free"))
    }

    // MARK: Pro AI monatlich, Bereiche und Ersparnis (27.11.2026)

    /// plans.json: Pro AI monatlich (3,99 €) gehoert zu Pro AI und bringt dieselben 120 Credits wie jaehrlich; die
    /// Angebote stehen in den Bereichen Monatlich, Jaehrlich, Unser Special; Plus jaehrlich ist kein Angebot mehr
    func testProAIMonthlyIsProAIWith120CreditsInTheContract() throws {
        let c = try plansContract()
        let offers = try XCTUnwrap(c["offers"]?.array)
        XCTAssertEqual(offers.compactMap { $0["product_id"]?.string },
                       ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly", "de.uniflow.proai.yearly", "de.uniflow.plus.fuenfjahre"])
        XCTAssertEqual(offers.compactMap { $0["group"]?.string }, ["monthly", "monthly", "yearly", "special"])
        XCTAssertEqual(c["offer_groups"]?.array?.compactMap { $0["key"]?.string }, ["special", "monthly", "yearly"])
        XCTAssertEqual(c["offer_groups"]?.array?.compactMap { $0["title"]?.string }, ["Unser Special", "Monatlich", "Jährlich"])
        let monthly = try XCTUnwrap(offers.first { $0["product_id"]?.string == "de.uniflow.proai.monthly" })
        XCTAssertEqual(monthly["plan"]?.string, "pro_ai")
        XCTAssertEqual(monthly["kind"]?.string, "auto_renewable")
        XCTAssertEqual(monthly["price_cents"]?.int, 399)
        XCTAssertEqual(monthly["period"]?.string, "month")
        XCTAssertEqual(c["plans"]?["pro_ai"]?["credits"]?.int, 120, "Pro AI monatlich: 120 Credits wie jaehrlich")
        XCTAssertEqual(StudiNowAIText.proAIMonthlyCredits, 120)
        XCTAssertFalse(offers.contains { $0["product_id"]?.string == "de.uniflow.plus.yearly" }, "Plus jaehrlich wird nicht angeboten")
        // Paket: Name, Abzeichen, Hervorhebung, nur dieses
        let special = offers.filter { $0["highlight"]?.bool == true }
        XCTAssertEqual(special.compactMap { $0["product_id"]?.string }, ["de.uniflow.plus.fuenfjahre"])
        XCTAssertEqual(special.first?["name"]?.string, "Bachelor+Master-Paket")
        XCTAssertEqual(special.first?["badge"]?.string, "Unser Special")
        XCTAssertEqual(special.first?["kind"]?.string, "non_renewing")
        XCTAssertEqual(special.first?["years"]?.int, 5)
    }

    /// Ersparnis in plans.json nachgerechnet und als Text: Pro AI jaehrlich gegen 12 x monatlich, Paket gegen 60 x Plus
    func testSavingsInTheContractAddUp() throws {
        let offers = try XCTUnwrap(try plansContract()["offers"]?.array)
        func offer(_ id: String) throws -> JSONValue { try XCTUnwrap(offers.first { $0["product_id"]?.string == id }, id) }
        let expected = [("de.uniflow.proai.yearly", "de.uniflow.proai.monthly", 12, "Du sparst 7,89 € (16 %) gegenüber 12 × 3,99 € = 47,88 €", "nur 3,33 € im Monat"),
                        ("de.uniflow.plus.fuenfjahre", "de.uniflow.plus.monthly", 60, "Du sparst 79,41 € (67 %) gegenüber 60 × 1,99 € = 119,40 €", "nur 0,67 € im Monat")]
        for (id, compare, months, text, perMonth) in expected {
            let o = try offer(id)
            XCTAssertEqual(o["compare"]?.string, compare, id)
            let s = try XCTUnwrap(o["savings"]?.object, id)
            let price = try XCTUnwrap(o["price_cents"]?.int, id)
            let comparePrice = try XCTUnwrap(try offer(compare)["price_cents"]?.int, id)
            XCTAssertEqual(s["months"]?.int, months, id)
            XCTAssertEqual(s["regular_cents"]?.int, months * comparePrice, id)
            XCTAssertEqual(s["saved_cents"]?.int, months * comparePrice - price, id)
            XCTAssertEqual(s["saved_percent"]?.int, Int((Double(months * comparePrice - price) * 100 / Double(months * comparePrice)).rounded()), id)
            XCTAssertEqual(s["text"]?.string, text, id)
            XCTAssertEqual(s["per_month_text"]?.string, perMonth, id)
        }
        for id in ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly"] {
            XCTAssertNil(try offer(id)["savings"]?.object, id)
        }
    }
}

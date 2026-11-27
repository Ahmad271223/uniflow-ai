import Foundation
import XCTest
@testable import UniFlowCore

// KI-Credits zum Nachkaufen (Auftrag des Inhabers vom 15.11.2026) gegen den Vertrag
// packages/shared-contracts/fixtures/credit-packs/contract.json (aus app/plans.py, app/credits.py, app/credit_texts.py,
// tools/gen-credit-packs-fixture.py): Pakete, Lesen des Stands beider Toepfe, Texte, Antworten auf einen Kauf und die
// Regel "erst nach der Antwort des Dienstes abschliessen".

private func creditContract() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/credit-packs/contract.json")))
}

final class CreditPacksTests: XCTestCase {
    private func flow(_ step: String) throws -> JSONValue {
        try XCTUnwrap(try creditContract()["flows"]?.array?.first { $0["step"]?.string == step }, step)
    }

    private func make(_ token: String? = "tok") -> (StudoraAccount, FakeService, MemoryTokenStore) {
        let fake = FakeService(), store = MemoryTokenStore(token)
        return (StudoraAccount(base: "https://dienst.example", http: fake, tokens: store, deviceID: "ipad-1", deviceName: "iPad"), fake, store)
    }

    private func answer(_ fake: FakeService, _ f: JSONValue) async {
        await fake.on(f["method"]?.string ?? "", f["path"]?.string ?? "", Int(f["status"]?.double ?? 0), f["response"])
    }

    // MARK: Pakete und Regeln

    func testPacksMatchTheContractAndCarryNoNumberInTheirProductID() throws {
        let c = try creditContract()
        let packs = try XCTUnwrap(c["packs"]?.array)
        XCTAssertEqual(packs.compactMap { $0["product_id"]?.string }, CreditPacks.productIDs)
        XCTAssertEqual(packs.compactMap { $0["credits"]?.double.map { Int($0) } }, CreditPacks.defaultPacks.map(\.credits))
        XCTAssertEqual(packs.compactMap { $0["label"]?.string }, CreditPacks.defaultPacks.map { CreditText.packLabel($0.credits) })
        XCTAssertEqual(CreditPacks.defaultPacks.map(\.credits), [80, 160])
        for id in CreditPacks.productIDs {
            XCTAssertTrue(CreditPacks.isPack(id))
            XCTAssertNil(id.rangeOfCharacter(from: .decimalDigits), "die Groesse stellt der Dienst ein, die ID bleibt: \(id)")
        }
        XCTAssertFalse(CreditPacks.isPack("de.uniflow.proai.yearly"))
        XCTAssertEqual(c["purchase"]?["path"]?.string, CreditPacks.purchasePath)
        XCTAssertEqual(c["credit_microeur"]?.double, 10000, "1 Credit = 1 Cent, ein Kurs fuer alle Credits (24.11.2026)")
        // die Zustaende, die der Dienst kennt, liest die App alle
        for s in c["purchase"]?["statuses"]?.array?.compactMap(\.string) ?? [] {
            XCTAssertNotNil(CreditPacks.PurchaseResult.Status(rawValue: s), s)
        }
    }

    /// Die Groesse eines Pakets kommt vom Dienst; unbekannte Produkte zaehlen nicht, ohne Angabe gilt der Vertrag
    func testPackSizesComeFromTheService() throws {
        let sent: JSONValue = ["packs": [["product_id": "de.uniflow.credits.klein", "credits": 100],
                                         ["product_id": "de.uniflow.credits.gross", "credits": 185],
                                         ["product_id": "de.uniflow.credits.riesig", "credits": 900]]]
        XCTAssertEqual(CreditPacks.packs(from: sent), [CreditPacks.Pack(productID: "de.uniflow.credits.klein", credits: 100),
                                                       CreditPacks.Pack(productID: "de.uniflow.credits.gross", credits: 185)])
        XCTAssertEqual(CreditPacks.packs(from: nil), CreditPacks.defaultPacks)
        XCTAssertEqual(CreditPacks.packs(from: ["packs": []]), CreditPacks.defaultPacks)
        XCTAssertEqual(CreditPacks.packs(from: try flow("Pro AI: Stand vor dem Kauf (beide Toepfe, Pakete, wo man kaufen kann)")["response"]?["credit_packs"]),
                       CreditPacks.defaultPacks)
    }

    /// Wer kaufen darf, entscheidet der Dienst (`can_buy`); die App hat keine eigene Regel
    func testBuyRuleIsTheServicesAnswer() throws {
        let cases = try XCTUnwrap(try creditContract()["buy_rule"]?["cases"]?.array)
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let b = CreditPacks.Balance.parse(["allowance": 0, "remaining": 0, "purchased": 5, "can_buy": c["can_buy"] ?? false,
                                               "purchased_usable": c["purchased_usable"] ?? false])
            XCTAssertEqual(CreditPacks.offersShop(b), c["can_buy"]?.bool, "\(c)")
            XCTAssertEqual(b?.available, c["purchased_usable"]?.bool == true ? 5 : 0, "\(c)")
        }
        XCTAssertFalse(CreditPacks.offersShop(nil))
        // Plus und Pro AI kaufen (bezahlt), Free nicht, in der Probe allein nicht (15.11.2026); gekaufte Credits gelten seit
        // 26.11.2026 mit Plus und Pro AI fuer alles (vorher mit Plus nur fuer den KI-Chat), mit Free ruhen sie
        let rule = try XCTUnwrap(try creditContract()["buy_rule"])
        XCTAssertEqual(rule["buy_plans"]?.array?.compactMap(\.string), ["plus", "pro_ai"])
        XCTAssertEqual(rule["buy_in_trial"]?.bool, false)
        XCTAssertEqual(Set(rule["chat_purposes"]?.array?.compactMap(\.string) ?? []), CreditPacks.chatTasks)
        let scopes = Dictionary(cases.filter { $0["trial_only"]?.bool == false }.compactMap { c in
            c["plan"]?.string.flatMap { p in c["purchased_scope"]?.string.map { (p, $0) } }
        }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(scopes, ["free": "none", "plus": "all", "pro_ai": "all", "pro_connect": "all"])
        // dieselbe Kaufregel auf dem Geraet (`CreditPacks.canBuy`) fuer jeden Fall des Vertrags
        for c in cases {
            XCTAssertEqual(CreditPacks.canBuy(plan: c["plan"]?.string, trialOnly: c["trial_only"]?.bool ?? false), c["can_buy"]?.bool, "\(c)")
        }
        for s in ["all", "chat", "none"] { XCTAssertNotNil(CreditPacks.Scope(rawValue: s)) }
        // ein Stand ohne das Feld (oder mit einem unbekannten Wert) richtet sich nach purchased_usable
        XCTAssertEqual(CreditPacks.Balance.parse(["allowance": 100, "remaining": 1, "purchased_usable": true])?.purchasedScope, .all)
        XCTAssertEqual(CreditPacks.Balance.parse(["allowance": 0, "remaining": 0, "purchased_scope": "neu"])?.purchasedScope, CreditPacks.Scope.none)
    }

    // MARK: Stand und Texte

    func testBalanceAndTextsMatchEveryCaseOfTheContract() throws {
        let cases = try XCTUnwrap(try creditContract()["balance_cases"]?.array)
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let b = try XCTUnwrap(CreditPacks.Balance.parse(c["credits"]), name)
            let e = try XCTUnwrap(c["expect"], name)
            XCTAssertEqual(CreditText.balanceLine(b), e["line"]?.string, name)
            XCTAssertEqual(CreditText.keepNote(b), e["keep_note"]?.string, name)
            XCTAssertEqual(CreditText.dormantNote(b), e["dormant_note"]?.string, name)
            XCTAssertEqual(b.purchasedScope.rawValue, e["scope"]?.string, name)
            XCTAssertEqual(CreditText.scopeNote(b), e["scope_note"]?.string, name)
            XCTAssertEqual(b.available, e["available"]?.double.map { Int($0) }, name)
            XCTAssertEqual(CreditPacks.offersShop(b), e["offers_shop"]?.bool, name)
            XCTAssertEqual(CreditText.resetDay(b.resetsAt), e["reset_day"]?.string, name)
        }
        let t = try XCTUnwrap(try creditContract()["texts"])
        XCTAssertEqual(CreditText.titleExhausted, t["title_exhausted"]?.string)
        XCTAssertEqual(CreditText.titleShop, t["title_shop"]?.string)
        XCTAssertEqual(CreditText.notNow, t["not_now"]?.string)
        XCTAssertEqual(CreditText.keep, t["keep"]?.string)
        XCTAssertEqual(CreditText.buyNeedsProAI, t["buy_needs_pro_ai"]?.string)
        XCTAssertEqual(CreditText.webHint, t["web_hint"]?.string)
        XCTAssertEqual(CreditText.noCredits, t["no_credits"]?.string)
        XCTAssertEqual(CreditText.chatOnly, t["chat_only"]?.string)
        XCTAssertEqual(CreditText.chatLock, t["chat_lock"]?.string)
        XCTAssertNil(CreditPacks.Balance.parse(nil))
        XCTAssertNil(CreditPacks.Balance.parse(.null))
        XCTAssertNil(CreditText.balanceLine(nil))
    }

    /// Texte in einfachem Deutsch, ohne Preis und ohne Centwert: der Preis kommt immer aus dem Store
    func testTextsNameNoPrice() {
        let b = CreditPacks.Balance(allowance: 100, remaining: 0, purchased: 3, purchasedUsable: true, canBuy: true, resetsAt: "2026-12-01T00:00:00+01:00")
        let granted = CreditPacks.PurchaseResult(status: .granted, creditsAdded: 100, creditsRemoved: 0, otherAccount: false, sandboxLimited: false)
        for text in [CreditText.titleExhausted, CreditText.titleShop, CreditText.keepNote(b), CreditText.buyNeedsProAI, CreditText.webHint,
                     CreditText.pendingNotice, CreditText.purchaseNotice(granted), CreditText.packLabel(100)] {
            XCTAssertFalse(text.contains("€") || text.contains("Cent") || text.contains("EUR"), text)
        }
        XCTAssertEqual(CreditText.purchaseNotice(granted), "100 Credits gutgeschrieben.")
        var other = granted
        other.otherAccount = true
        XCTAssertEqual(CreditText.purchaseNotice(other), "Die Credits stehen bei dem StudiNow-Konto, mit dem du gekauft hast.")
    }

    // MARK: Ablaeufe gegen die aufgezeichneten Antworten des Dienstes

    func testPurchaseIsBookedOnceAndRepeatsAreHarmless() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Kleines Paket kaufen: gutgeschrieben, danach darf die App abschliessen"))
        let first = try await acc.bookCreditPurchase(signedTransaction: "jws-1")
        XCTAssertEqual(first.status, .granted)
        XCTAssertEqual(first.creditsAdded, 80)
        XCTAssertEqual(first.productID, "de.uniflow.credits.klein")
        XCTAssertEqual(first.balance?.purchased, 80)
        XCTAssertEqual(first.balance?.remaining, 120, "Pro AI: 120 Monats-Credits (26.11.2026)")
        XCTAssertEqual(first.balance?.available, 200)
        XCTAssertFalse(first.otherAccount)
        let sent = await fake.last(CreditPacks.purchasePath)
        XCTAssertEqual(sent?.method, "POST")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(sent?.body))["signed_transaction"], "jws-1")
        XCTAssertEqual(sent?.headers["Authorization"], "Bearer tok")
        await answer(fake, try flow("Dieselbe Transaktion noch einmal (Wiederholung nach Netzfehler): nichts doppelt"))
        let again = try await acc.bookCreditPurchase(signedTransaction: "jws-1")
        XCTAssertEqual(again.status, .alreadyGranted)
        XCTAssertEqual(again.creditsAdded, 0)
        XCTAssertEqual(again.balance?.purchased, 80)
        await answer(fake, try flow("Grosses Paket kaufen"))
        let big = try await acc.bookCreditPurchase(signedTransaction: "jws-2")
        XCTAssertEqual(big.creditsAdded, 160)
        XCTAssertEqual(big.balance?.purchased, 240)
    }

    func testMonthlyFirstRefundAndDormantStatesAreRead() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Verbrauch: erst die 80 Monats-Credits, dann 30 gekaufte"))
        var s = try await acc.creditState()
        XCTAssertEqual(s.balance?.remaining, 10, "120 Monats-Credits, 110 verbraucht")
        XCTAssertEqual(s.balance?.purchased, 240)
        XCTAssertEqual(s.packs, CreditPacks.defaultPacks)
        await answer(fake, try flow("Stand nach der Erstattung"))
        s = try await acc.creditState()
        XCTAssertEqual(s.balance?.purchased, 160, "nur der Rest des erstatteten Kaufs (50) ging weg")
        await answer(fake, try flow("Die App meldet die erstattete Transaktion: nichts mehr gutzuschreiben, abschliessen"))
        let refunded = try await acc.bookCreditPurchase(signedTransaction: "jws-1")
        XCTAssertEqual(refunded.status, .alreadyRefunded)
        XCTAssertEqual(CreditText.purchaseNotice(refunded), "Dieser Kauf wurde erstattet.")
        await answer(fake, try flow("Pro AI ist vorbei: die gekauften Credits bleiben beim Konto und ruhen"))
        s = try await acc.creditState()
        let resting = try XCTUnwrap(s.balance)
        XCTAssertEqual([resting.purchased, resting.available, resting.allowance], [154, 0, 0])
        XCTAssertFalse(resting.purchasedUsable || resting.canBuy)
        XCTAssertEqual(resting.purchasedScope, CreditPacks.Scope.none)
        XCTAssertEqual(CreditText.balanceLine(resting), "Gekauft: 154 · nutzbar mit StudiNow Plus oder Pro AI")
        XCTAssertNotNil(CreditText.dormantNote(resting))
        await answer(fake, try flow("Pro AI laeuft wieder: die gekauften Credits sind wieder nutzbar"))
        s = try await acc.creditState()
        XCTAssertEqual(s.balance?.available, 164)
        XCTAssertEqual(s.balance?.canBuy, true)
        await answer(fake, try flow("Probe: 25 Credits, kaufen geht erst mit Pro AI"))
        s = try await acc.creditState()
        XCTAssertEqual(s.balance?.allowance, 25)
        XCTAssertEqual(s.balance?.canBuy, false)
        await answer(fake, try flow("Ein anderes Konto meldet den Kauf: die Credits gehen an das Konto, das gekauft hat"))
        let other = try await acc.bookCreditPurchase(signedTransaction: "jws-5")
        XCTAssertTrue(other.otherAccount)
        XCTAssertEqual(other.balance?.purchased, 0)
    }

    // MARK: Plus: kaufen ja, KI nur mit Credits

    /// Wechsel zu Plus: die gekauften Credits bleiben und gelten seit 26.11.2026 fuer alle KI (vorher nur der Chat); die
    /// KI laeuft ganz aus ihnen; reichen sie nicht (Erklaeren reserviert mehr) oder fehlen sie, kommt 429 mit dem Stand
    /// fuer das Blatt mit den Paketen
    func testPlusUsesPurchasedCreditsForAllAI() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Wechsel zu Plus: die gekauften Credits bleiben, gelten aber nur noch fuer den KI-Chat"))
        let s = try await acc.creditState()
        let plus = try XCTUnwrap(s.balance)
        XCTAssertEqual([plus.allowance, plus.remaining, plus.purchased, plus.available], [0, 0, 160, 160])
        XCTAssertEqual(plus.purchasedScope, .all)
        XCTAssertTrue(plus.purchasedUsable && plus.canBuy)
        XCTAssertEqual(CreditText.balanceLine(plus), "Gekauft: 160", "bei Plus kein 'Diesen Monat: x von 120'")
        XCTAssertNil(CreditText.scopeNote(plus), "kein Satz 'nur Fragen an die KI' mehr")
        XCTAssertEqual(CreditText.keepNote(plus), CreditText.keep, "ohne Monats-Credits kein Satz zum Monat")
        let chat = try flow("Plus: der KI-Chat (freie Frage) laeuft aus gekauften Credits")
        XCTAssertEqual(chat["status"]?.double, 200)
        XCTAssertEqual(chat["request"]?["mode"]?.string, "ask")
        let after = try XCTUnwrap(CreditPacks.Balance.parse(chat["response"]?["credits"]))
        XCTAssertEqual([after.used, after.purchased], [110, 154], "nichts aus einem Monatstopf, alles aus den gekauften")
        // Erklaeren ist mit Plus keine Tarif-Sperre mehr: es reicht nur der Stand nicht (429 mit `needed`, nie 403)
        let locked = try flow("Plus: Erklaeren ist KI-Lernhilfe und bleibt Pro AI (403, nichts abgebucht)")
        XCTAssertEqual(locked["status"]?.double, 429)
        XCTAssertEqual(locked["response"]?["code"]?.string, "credits_exhausted")
        XCTAssertNil(locked["response"]?["required_plan"]?.string)
        let empty = try flow("Plus ohne Credits: der KI-Chat antwortet 429 mit dem Stand (Pakete kaufen), Erklaeren 403")
        XCTAssertEqual(empty["status"]?.double, 429)
        XCTAssertEqual(empty["response"]?["code"]?.string, "credits_exhausted")
        let none = try XCTUnwrap(CreditPacks.Balance.parse(empty["response"]?["credits"]))
        XCTAssertTrue(CreditPacks.offersShop(none))
        XCTAssertEqual(none.purchasedScope, .all)
        XCTAssertEqual(CreditText.balanceLine(none), "Gekauft: 0")
        XCTAssertEqual(empty["response"]?["detail"]?.string, "Für die StudiNow-KI brauchst du Credits. Credits kaufst du in der App für iPhone und iPad.")
        // dieselbe Sperre auf dem Geraet: mit diesem Stand geht keine KI-Anfrage an den Dienst
        XCTAssertTrue(StudiNowCreditGate(none).blocks(now: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(StudiNowCreditGate(after).blocks(now: Date(timeIntervalSince1970: 0)))
    }

    /// Auf dem Geraet: mit Plus antwortet die StudiNow-KI nur auf die freie Frage; jede andere Aufgabe wird abgewiesen,
    /// ohne dass etwas an den Dienst geht
    func testChatOnlyProviderSendsOnlyTheFreeQuestion() async throws {
        let fake = FakeService(), store = MemoryTokenStore("tok")
        let ai = StudiNowAI(base: "https://dienst.example", http: fake, tokens: store, consent: FixedConsent(true))
        let chat = StudiNowChatAI(ai)
        XCTAssertTrue(chat.isMetered)
        await fake.on("POST", "/api/ai/relay", 200, ["answer": "Eine Matrix ist ein Zahlenschema.", "credits": ["allowance": 0, "remaining": 0, "purchased": 91,
                                                                                                                 "purchased_usable": true, "purchased_scope": "chat"]])
        let answer = try await AIRelayTask.$current.withValue(AIRelayTask("tutor:ask")) { try await chat.answer(system: "s", prompt: "Was ist eine Matrix?") }
        XCTAssertEqual(answer, "Eine Matrix ist ein Zahlenschema.")
        let sent = await fake.last("/api/ai/relay")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(sent?.body))["task"], "tutor:ask")
        let before = await fake.requests.count
        for task in ["tutor:explain", "tutor:summary", "tutor:flashcards", "flashcards", "week_test", "weekly", "grade", "study_plan", "mail"] {
            do {
                _ = try await AIRelayTask.$current.withValue(AIRelayTask(task)) { try await chat.answer(system: "s", prompt: "p", schema: nil) }
                XCTFail("\(task): nur der Chat darf an den Dienst")
            } catch let e as LocalHTTPError {
                XCTAssertEqual(e.status, 403, task)
                XCTAssertEqual(e.detail["code"]?.string, "plan_required", task)
                XCTAssertEqual(e.detail["required_plan"]?.string, "pro_ai", task)
                XCTAssertEqual(e.detail["detail"]?.string, CreditText.chatLock, task)
            }
        }
        do { _ = try await chat.answer(system: "s", prompt: "ohne Aufgabe"); XCTFail("ohne Aufgabe") } catch is LocalHTTPError {}
        let after = await fake.requests.count
        XCTAssertEqual(after, before, "nichts ging an den Dienst")
    }

    /// Abschliessen (finish) nur nach einem Ergebnis: jeder Fehler und jede unlesbare Antwort wirft
    func testEveryFailureThrowsSoThePurchaseStaysOpen() async throws {
        let (acc, fake, _) = make()
        for (step, code) in [("Beschaedigte Kaufdaten: 400, die App schliesst nicht ab", "jws_invalid"), ("Unbekanntes Produkt: 400", "unknown_product")] {
            await answer(fake, try flow(step))
            do {
                _ = try await acc.bookCreditPurchase(signedTransaction: "x")
                XCTFail("erwartet: Fehler bei \(step)")
            } catch let e as AccountError { XCTAssertEqual(e.code, code) }
        }
        await fake.on("POST", CreditPacks.purchasePath, 503, ["detail": "nicht eingerichtet", "code": "apple_not_configured"])
        do { _ = try await acc.bookCreditPurchase(signedTransaction: "x"); XCTFail("503") } catch let e as AccountError { XCTAssertEqual(e.code, "apple_not_configured") }
        await fake.on("POST", CreditPacks.purchasePath, 200, ["status": "etwas_neues"])
        do { _ = try await acc.bookCreditPurchase(signedTransaction: "x"); XCTFail("unbekannter Zustand") } catch let e as AccountError { XCTAssertEqual(e.code, "bad_response") }
        await fake.on("POST", CreditPacks.purchasePath, 200, nil)
        do { _ = try await acc.bookCreditPurchase(signedTransaction: "x"); XCTFail("leere Antwort") } catch let e as AccountError { XCTAssertEqual(e.code, "bad_response") }
        await fake.setOffline(true)
        do { _ = try await acc.bookCreditPurchase(signedTransaction: "x"); XCTFail("ohne Netz") } catch let e as AccountError { XCTAssertEqual(e.code, "service_unreachable") }
        // ohne Anmeldung geht nichts an den Dienst
        let (signedOut, fake2, _) = make(nil)
        do { _ = try await signedOut.bookCreditPurchase(signedTransaction: "x"); XCTFail("ohne Anmeldung") } catch let e as AccountError { XCTAssertEqual(e.code, "unauthenticated") }
        let none = await fake2.requests.count
        XCTAssertEqual(none, 0)
    }

    /// 429 der KI mit dem Stand: die App zeigt das Blatt, weil der Dienst `can_buy` meldet
    func testExhaustedAnswerCarriesTheStateForTheSheet() throws {
        let f = try flow("Credits reichen nicht: 429 mit dem Stand (die App zeigt das Blatt, weil can_buy true ist)")
        XCTAssertEqual(f["status"]?.double, 429)
        XCTAssertEqual(f["response"]?["code"]?.string, try creditContract()["purchase"]?["exhausted_code"]?.string)
        XCTAssertEqual(f["response"]?["detail"]?.string, "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "Text fuer aeltere Apps unveraendert")
        let b = try XCTUnwrap(CreditPacks.Balance.parse(f["response"]?["credits"]))
        XCTAssertEqual(b.available, 40, "es fehlt nur der Rest fuer diese Anfrage (`needed`)")
        XCTAssertTrue(CreditPacks.offersShop(b))
    }
}

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
        XCTAssertEqual(CreditPacks.defaultPacks.map(\.credits), [100, 200])
        for id in CreditPacks.productIDs {
            XCTAssertTrue(CreditPacks.isPack(id))
            XCTAssertNil(id.rangeOfCharacter(from: .decimalDigits), "die Groesse stellt der Dienst ein, die ID bleibt: \(id)")
        }
        XCTAssertFalse(CreditPacks.isPack("de.uniflow.proai.yearly"))
        XCTAssertEqual(c["purchase"]?["path"]?.string, CreditPacks.purchasePath)
        XCTAssertEqual(c["credit_microeur"]?.double, 6500, "1 Credit = 0,65 Cent, ein Kurs fuer alle Credits")
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
        XCTAssertEqual(first.creditsAdded, 100)
        XCTAssertEqual(first.productID, "de.uniflow.credits.klein")
        XCTAssertEqual(first.balance?.purchased, 100)
        XCTAssertEqual(first.balance?.remaining, 100)
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
        XCTAssertEqual(again.balance?.purchased, 100)
        await answer(fake, try flow("Grosses Paket kaufen"))
        let big = try await acc.bookCreditPurchase(signedTransaction: "jws-2")
        XCTAssertEqual(big.creditsAdded, 200)
        XCTAssertEqual(big.balance?.purchased, 300)
    }

    func testMonthlyFirstRefundAndDormantStatesAreRead() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Verbrauch: erst die 100 Monats-Credits, dann 30 gekaufte"))
        var s = try await acc.creditState()
        XCTAssertEqual(s.balance?.remaining, 0)
        XCTAssertEqual(s.balance?.purchased, 270)
        XCTAssertEqual(s.packs, CreditPacks.defaultPacks)
        await answer(fake, try flow("Stand nach der Erstattung"))
        s = try await acc.creditState()
        XCTAssertEqual(s.balance?.purchased, 200, "nur der Rest des erstatteten Kaufs (70) ging weg")
        await answer(fake, try flow("Die App meldet die erstattete Transaktion: nichts mehr gutzuschreiben, abschliessen"))
        let refunded = try await acc.bookCreditPurchase(signedTransaction: "jws-1")
        XCTAssertEqual(refunded.status, .alreadyRefunded)
        XCTAssertEqual(CreditText.purchaseNotice(refunded), "Dieser Kauf wurde erstattet.")
        await answer(fake, try flow("Pro AI ist vorbei: die gekauften Credits bleiben beim Konto und ruhen"))
        s = try await acc.creditState()
        let resting = try XCTUnwrap(s.balance)
        XCTAssertEqual([resting.purchased, resting.available, resting.allowance], [200, 0, 0])
        XCTAssertFalse(resting.purchasedUsable || resting.canBuy)
        XCTAssertEqual(CreditText.balanceLine(resting), "Gekauft: 200 · nutzbar mit StudiNow Pro AI")
        XCTAssertNotNil(CreditText.dormantNote(resting))
        await answer(fake, try flow("Pro AI laeuft wieder: die gekauften Credits sind wieder nutzbar"))
        s = try await acc.creditState()
        XCTAssertEqual(s.balance?.available, 200)
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
        XCTAssertEqual(b.available, 0)
        XCTAssertTrue(CreditPacks.offersShop(b))
    }
}

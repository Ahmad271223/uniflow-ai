import Foundation
import XCTest
@testable import UniFlowCore

// Geraete-Regel (Auftrag des Inhabers vom 14.11.2026) gegen den Vertrag
// packages/shared-contracts/fixtures/device-limit/contract.json (aus app/device_limit.py, tools/gen-device-limit-fixture.py):
// Kopfzeile der Faehigkeit, Lesen der Auskunft `device`, was die App daraus macht, und die Texte der beiden Hinweise.

private func deviceContract() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/device-limit/contract.json")))
}

final class DeviceRuleTests: XCTestCase {
    private func flow(_ step: String) throws -> JSONValue {
        try XCTUnwrap(try deviceContract()["flows"]?.array?.first { $0["step"]?.string == step }, step)
    }

    private func make(_ token: String? = "tok") -> (StudoraAccount, FakeService, MemoryTokenStore) {
        let fake = FakeService(), store = MemoryTokenStore(token)
        return (StudoraAccount(base: "https://dienst.example", http: fake, tokens: store, deviceID: "iphone-1", deviceName: "iPhone"), fake, store)
    }

    private func answer(_ fake: FakeService, _ f: JSONValue) async {
        await fake.on(f["method"]?.string ?? "", f["path"]?.string ?? "", Int(f["status"]?.double ?? 0), f["response"])
    }

    func testCapabilityAndStatesMatchTheContract() throws {
        let c = try deviceContract()
        XCTAssertEqual(c["capability"]?["header"]?.string, DeviceRule.capabilityHeader)
        XCTAssertEqual(c["capability"]?["value"]?.string, DeviceRule.capability)
        XCTAssertEqual(c["states"]?.array?.compactMap(\.string), ["ok", "blocked", "hint_plus"])
        for s in c["states"]?.array?.compactMap(\.string) ?? [] { XCTAssertNotNil(DeviceRule.State(rawValue: s), s) }
        XCTAssertEqual(c["upgrade"]?["plan"]?.string, "pro_ai")
        XCTAssertEqual(c["upgrade"]?["price_cents"]?.double, 3999)
        XCTAssertEqual(c["upgrade"]?["period"]?.string, "year")
    }

    /// Jede Anfrage der App meldet die Faehigkeit; ohne sie schickt der Dienst die Auskunft nicht
    func testEveryRequestCarriesTheCapability() async throws {
        let (acc, fake, _) = make(nil)
        await answer(fake, try flow("Free: zweites Geraet anmelden (Hinweis-Bildschirm)"))
        _ = try await acc.login(email: "free@beispiel.de", password: "sehr-geheim-123")
        let login = await fake.last("/api/account/login")
        XCTAssertEqual(login?.headers[DeviceRule.capabilityHeader], "device_limit, uni_room")
        let body = try JSONValue.parse(try XCTUnwrap(login?.body))
        XCTAssertEqual(body["device_id"], "iphone-1")
        await answer(fake, try flow("Free: Stand auf dem zweiten Geraet"))
        _ = try await acc.planStatus()
        let status = await fake.last("/api/entitlements")
        XCTAssertEqual(status?.headers[DeviceRule.capabilityHeader], "device_limit, uni_room")
        XCTAssertNotNil(status?.headers["Authorization"])
    }

    func testPlanStatusReadsBlockedSwitchAndPurchase() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Free: Stand auf dem ersten Geraet"))
        let first = try await acc.planStatus()
        XCTAssertEqual(first.device, DeviceRule.Status(state: .ok, isPrimary: true, primaryName: "iPad", priceCents: 3999, currency: "EUR", period: "year"))
        await answer(fake, try flow("Free: Stand auf dem zweiten Geraet"))
        let second = try await acc.planStatus()
        XCTAssertEqual(second.plan, "free")
        XCTAssertEqual(second.device, DeviceRule.Status(state: .blocked, isPrimary: false, primaryName: "iPad", priceCents: 3999, currency: "EUR", period: "year"))
        // "Dieses Gerät stattdessen nutzen"
        let f = try flow("Free: dieses Geraet stattdessen nutzen")
        XCTAssertEqual(f["path"]?.string, "/api/account/device/primary")
        await answer(fake, f)
        let switched = try await acc.useThisDevice()
        XCTAssertEqual(switched?.state, .ok)
        XCTAssertEqual(switched?.isPrimary, true)
        XCTAssertEqual(switched?.primaryName, "iPhone")
        let sent = await fake.last("/api/account/device/primary")
        XCTAssertEqual(sent?.method, "POST")
        XCTAssertNil(sent?.body, "ohne Rumpf: das Geraet steht in der Sitzung")
        await answer(fake, try flow("Free: danach zeigt das andere Geraet den Hinweis"))
        let other = try await acc.planStatus()
        XCTAssertEqual(other.device?.state, .blocked)
        XCTAssertEqual(other.device?.primaryName, "iPhone")
        await answer(fake, try flow("Nach dem Kauf von Pro AI: kein Hinweis mehr"))
        let bought = try await acc.planStatus()
        XCTAssertEqual(bought.plan, "pro_ai")
        XCTAssertEqual(bought.device?.state, .ok)
    }

    func testPlusHintProTrialAndOlderService() async throws {
        let (acc, fake, _) = make()
        await answer(fake, try flow("Plus: Stand auf dem zweiten Geraet"))
        let plus = try await acc.planStatus()
        XCTAssertEqual(plus.plan, "plus")
        XCTAssertEqual(plus.device?.state, .hintPlus)
        // Anmelde-Antworten tragen dieselbe Auskunft
        XCTAssertEqual(DeviceRule.Status.parse(try flow("Pro AI: zweites Geraet anmelden (keine Einschraenkung)")["response"]?["device"])?.state, .ok)
        XCTAssertEqual(DeviceRule.Status.parse(try flow("Probe: zweites Geraet anmelden (zaehlt wie Pro AI)")["response"]?["device"])?.state, .ok)
        XCTAssertEqual(DeviceRule.Status.parse(try flow("Plus: zweites Geraet anmelden (einmaliger Hinweis, nie gesperrt)")["response"]?["device"])?.state, .hintPlus)
        // ein Dienst ohne die Regel (oder eine Antwort ohne das Feld): keine Auskunft, nie gesperrt
        await answer(fake, try flow("Aeltere App: Stand ohne Feld device"))
        let old = try await acc.planStatus()
        XCTAssertNil(old.device)
        XCTAssertEqual(DeviceRule.shown(server: old.device?.state, localPlan: "free"), .ok)
    }

    func testSwitchErrorsKeepTheServiceCode() async throws {
        let (acc, fake, store) = make()
        await answer(fake, try flow("Dieses Geraet nutzen ohne Geraete-Kennung"))
        do { _ = try await acc.useThisDevice(); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.code, "device_unknown")
            XCTAssertEqual(e.status, 400)
        }
        XCTAssertNotNil(store.load(), "kein Abmelden bei diesem Fehler")
        await fake.setOffline(true)
        do { _ = try await acc.useThisDevice(); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.code, "service_unreachable")
        }
    }

    /// Unbekanntes sperrt nie: fehlendes Feld, kein Objekt, neuer Zustand
    func testParseNeverBlocksOnUnknownAnswers() throws {
        XCTAssertNil(DeviceRule.Status.parse(nil))
        XCTAssertNil(DeviceRule.Status.parse(.null))
        XCTAssertNil(DeviceRule.Status.parse("blocked"))
        XCTAssertEqual(DeviceRule.Status.parse(["state": "voellig_neu", "is_primary": false])?.state, .ok)
        XCTAssertEqual(DeviceRule.Status.parse(["is_primary": true])?.state, .ok)
        XCTAssertEqual(DeviceRule.Status.parse(["state": "blocked", "primary_name": "  "]), DeviceRule.Status(state: .blocked))
        // gemerkter Zustand uebersteht Speichern und Laden
        let s = DeviceRule.Status(state: .blocked, isPrimary: false, primaryName: "iPad", priceCents: 3999, currency: "EUR", period: "year")
        XCTAssertEqual(try JSONDecoder().decode(DeviceRule.Status.self, from: JSONEncoder().encode(s)), s)
    }

    /// Was die App zeigt (Vertrag `client_cases`, Referenz `device_limit.shown_state`)
    func testShownStateMatchesTheContract() throws {
        let cases = try XCTUnwrap(try deviceContract()["client_cases"]?.array)
        XCTAssertEqual(cases.count, 15)
        for c in cases {
            let server = c["server_state"]?.string.flatMap(DeviceRule.State.init(rawValue:))
            let plan = try XCTUnwrap(c["local_plan"]?.string)
            XCTAssertEqual(DeviceRule.shown(server: server, localPlan: plan).rawValue, c["shown"]?.string,
                           "\(c["server_state"]?.string ?? "nil") / \(plan)")
        }
        XCTAssertEqual(DeviceRule.shown(server: .blocked, localPlan: "free"), .blocked)
        XCTAssertEqual(DeviceRule.shown(server: .blocked, localPlan: "plus"), .hintPlus, "Plus wird nie gesperrt")
        XCTAssertEqual(DeviceRule.shown(server: .blocked, localPlan: "pro_ai"), .ok, "nach dem Kauf von Pro AI sofort frei")
        XCTAssertEqual(DeviceRule.shown(server: .blocked, localPlan: "pro_connect"), .ok)
        XCTAssertEqual(DeviceRule.shown(server: nil, localPlan: "free"), .ok, "ohne Auskunft (kein Netz) nie sperren")
    }

    func testTexts() throws {
        let c = try deviceContract()
        let price = DeviceRuleTexts.fallbackPrice(cents: c["upgrade"]?["price_cents"]?.double.map { Int($0) }, currency: c["upgrade"]?["currency"]?.string)
        XCTAssertEqual(price, "39,99 €")
        XCTAssertEqual(DeviceRuleTexts.fallbackPrice(), "39,99 €")
        XCTAssertEqual(DeviceRuleTexts.fallbackPrice(cents: 4900, currency: "chf"), "49,00 CHF")
        XCTAssertEqual(DeviceRuleTexts.blockedTitle, "StudiNow Free gilt für ein Gerät")
        XCTAssertEqual(DeviceRuleTexts.blockedText(primaryName: "iPad", price: price),
                       "Dein Konto läuft schon auf einem anderen Gerät (iPad). Mit Pro AI nutzt du StudiNow auf iPhone und iPad – mit Abgleich. 39,99 € im Jahr.")
        XCTAssertEqual(DeviceRuleTexts.blockedText(primaryName: nil, price: price, mac: true),
                       "Dein Konto läuft schon auf einem anderen Gerät. Mit Pro AI nutzt du StudiNow auf iPhone, iPad und Mac – mit Abgleich. 39,99 € im Jahr.")
        XCTAssertEqual([DeviceRuleTexts.showPlans, DeviceRuleTexts.useThisDevice, DeviceRuleTexts.signOut],
                       ["Pro AI ansehen", "Dieses Gerät stattdessen nutzen", "Abmelden"])
        XCTAssertEqual(DeviceRuleTexts.confirmText(primaryName: "iPad"),
                       "StudiNow Free läuft dann auf diesem Gerät. Auf dem anderen Gerät (iPad) erscheint beim nächsten Öffnen dieser Hinweis. Deine Daten bleiben auf beiden Geräten erhalten.")
        XCTAssertEqual(DeviceRuleTexts.plusTitle, "Plus läuft auf jedem Gerät für sich")
        XCTAssertEqual(DeviceRuleTexts.plusText(price: price),
                       "Deine Notizen bleiben auf dem Gerät, auf dem du sie schreibst. Den Abgleich zwischen iPhone und iPad gibt es mit Pro AI für 39,99 € im Jahr.")
    }
}

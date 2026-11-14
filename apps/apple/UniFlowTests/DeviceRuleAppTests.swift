import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Geraete-Regel in der App (Auftrag des Inhabers vom 14.11.2026, DeviceRuleViews.swift): Free auf einem zweiten Geraet
/// zeigt statt der App den Hinweis-Bildschirm (iPad und iPhone), "Dieses Gerät stattdessen nutzen" nach Rueckfrage,
/// "Abmelden", der Kauf von Pro AI hebt den Hinweis sofort auf, Plus bekommt einmal einen Hinweis. Gesperrt wird nur
/// nach einer Antwort des Dienstes, nie ohne Netz. Schein-Dienst ueber `accountFactory`, nie ins Netz, kein StoreKit.
@MainActor
final class DeviceRuleAppTests: IPhoneLearnTestCase {

    /// Schein-Dienst mit der Geraete-Regel: `device` in GET /api/entitlements, POST /api/account/device/primary
    final class Service: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(method: String, path: String, headers: [String: String])] = []
        private var _device: JSONValue?
        private var _plan = "free"
        private var _offline = false

        init(device: JSONValue? = nil, plan: String = "free") { _device = device; _plan = plan }

        var device: JSONValue? { get { lock.withLock { _device } } set { lock.withLock { _device = newValue } } }
        var plan: String { get { lock.withLock { _plan } } set { lock.withLock { _plan = newValue } } }
        var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
        var requests: [(method: String, path: String, headers: [String: String])] { lock.withLock { log } }
        func count(_ method: String, _ path: String) -> Int { requests.filter { $0.method == method && $0.path == path }.count }

        static func status(_ state: String, primary: Bool = false, name: String? = "iPad") -> JSONValue {
            .object(["state": .string(state), "is_primary": .bool(primary), "primary_name": name.map(JSONValue.string) ?? .null,
                     "primary_set_at": "2026-11-14T10:00:00Z", "upgrade_plan": "pro_ai", "price_cents": 3999, "currency": "EUR", "period": "year"])
        }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            lock.withLock { log.append((r.method, path, r.headers)) }
            if offline { throw URLError(.notConnectedToInternet) }
            func reply(_ status: Int, _ j: JSONValue) -> ServiceHTTPResponse { ServiceHTTPResponse(status: status, body: j.serialized()) }
            switch (r.method, path) {
            case ("GET", "/api/account/me"):
                return reply(200, ["user": ["id": "0123456789abcdef0123456789abcdef", "email": "relay@privaterelay.appleid.com",
                                            "email_verified": true, "university": "luh", "plan": .string(plan), "role": "user"], "sessions": []])
            case ("GET", "/api/entitlements"):
                var body: [String: JSONValue] = ["plan": .string(plan), "paid_plan": .string(plan), "needs_plan_choice": false]
                if let device { body["device"] = device }
                return reply(200, .object(body))
            case ("POST", "/api/account/device/primary"):
                let next = Self.status("ok", primary: true, name: "iPhone")
                device = next
                return reply(200, ["device": next])
            case ("POST", "/api/account/logout"):
                return reply(200, ["ok": true])
            default:
                return reply(404, ["detail": "nicht da"])
            }
        }
    }

    final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String? = nil) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    private let appleUser = "001234.erfunden-geraet.\(UUID().uuidString.prefix(8))"
    private var scope: String { DataContainerKey.userScope(appleUser) }
    private var suite = ""
    private var defaults: UserDefaults!
    private var tokens = MemoryTokens("sitzung-1")

    override func setUp() async throws {
        try await super.setUp()
        suite = "uniflow.tests.geraete.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        tokens = MemoryTokens("sitzung-1")
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        try await super.tearDown()
    }

    /// Konto-Anschluss ueber den Schein-Dienst, eigener Merker, eigener Tarif (`plan`: Kauf bzw. Probe auf dem Geraet)
    private func link(_ service: Service, plan: UFPlan = .free) -> (StudoraAccountLink, Entitlements) {
        let ent = Entitlements(observe: false, plan: plan)
        let l = StudoraAccountLink(entitlements: ent)
        l.deviceMemory = DeviceRuleMemory(defaults: defaults)
        let tokens = tokens
        l.accountFactory = { _ in StudoraAccount(base: "https://dienst.example", http: service, tokens: tokens, deviceID: "iphone-test", deviceName: "iPhone") }
        return (l, ent)
    }

    private func gate(_ l: StudoraAccountLink, _ ent: Entitlements, ready: Bool = true) -> some View {
        DeviceRuleGate(link: l, entitlements: ent, signedIn: true, ready: ready) {
            Text("Die App").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func answerConfirm(_ env: HostedEnvironment, _ yes: Bool, file: StaticString = #filePath, line: UInt = #line) -> String? {
        XCTAssertTrue(env.wait(timeout: 5) { env.overlay.ask != nil }, "Rückfrage fehlt", file: file, line: line)
        guard case .confirm(let text, let c) = env.overlay.ask else { XCTFail("keine Rückfrage", file: file, line: line); return nil }
        env.overlay.ask = nil
        c.resume(returning: yes)
        // der Systemhinweis schliesst animiert; erst danach nimmt `UFModalHost` die naechste Rueckfrage an
        env.pump(1.2)
        return text
    }

    // MARK: Regeln ohne Oberflaeche

    func testScreenDecision() {
        func screen(_ server: DeviceRule.State?, _ plan: UFPlan, loading: Bool = false, signedIn: Bool = true, canSwitch: Bool = true) -> DeviceRuleScreen {
            DeviceRuleScreen.decide(server: server, plan: plan, entitlementsLoading: loading, signedIn: signedIn, canSwitch: canSwitch)
        }
        XCTAssertEqual(screen(.blocked, .free), .blocked)
        XCTAssertEqual(screen(.blocked, .plus), .app, "Plus wird nie gesperrt")
        XCTAssertEqual(screen(.blocked, .proAI), .app, "nach dem Kauf von Pro AI sofort frei")
        XCTAssertEqual(screen(.ok, .free), .app)
        XCTAssertEqual(screen(.hintPlus, .free), .app)
        XCTAssertEqual(screen(nil, .free), .app, "ohne Auskunft des Dienstes (kein Netz, älterer Dienst) nie sperren")
        XCTAssertEqual(screen(.blocked, .free, loading: true), .waiting, "Kauf noch nicht gelesen: nicht vorschnell sperren")
        XCTAssertEqual(screen(.blocked, .free, signedIn: false), .app, "abgemeldet: Begrüßung")
        XCTAssertEqual(screen(.blocked, .free, canSwitch: false), .app, "ohne Anschluss zum Dienst gäbe es keinen Ausweg")

        func hint(_ server: DeviceRule.State?, _ plan: UFPlan, ready: Bool = true, seen: Bool = false, loading: Bool = false) -> Bool {
            DeviceRuleScreen.plusHintDue(server: server, plan: plan, entitlementsLoading: loading, signedIn: true, canSwitch: true, ready: ready, seen: seen)
        }
        XCTAssertTrue(hint(.hintPlus, .plus))
        XCTAssertTrue(hint(.hintPlus, .free), "Plus nur beim Dienst bekannt (z. B. im Web gekauft)")
        XCTAssertTrue(hint(.blocked, .plus), "Plus auf diesem Gerät gekauft, der Dienst kennt es noch nicht")
        XCTAssertFalse(hint(.hintPlus, .plus, seen: true), "einmalig")
        XCTAssertFalse(hint(.hintPlus, .plus, ready: false), "erst wenn die Oberfläche steht")
        XCTAssertFalse(hint(.hintPlus, .plus, loading: true))
        XCTAssertFalse(hint(.hintPlus, .proAI))
        XCTAssertFalse(hint(.ok, .plus), "auf dem ersten Gerät kein Hinweis")
        XCTAssertFalse(hint(nil, .plus))
    }

    func testMemoryKeepsOnlyWhatShowsSomething() {
        let m = DeviceRuleMemory(defaults: defaults)
        XCTAssertNil(m.load(scope: "a"))
        let blocked = DeviceRule.Status(state: .blocked, primaryName: "iPad", priceCents: 3999, currency: "EUR", period: "year")
        m.save(blocked, scope: "a")
        XCTAssertEqual(m.load(scope: "a"), blocked)
        XCTAssertNil(m.load(scope: "b"), "je Apple-Nutzer")
        m.save(DeviceRule.Status(state: .ok, isPrimary: true), scope: "a")
        XCTAssertNil(m.load(scope: "a"), "ok wird nicht gemerkt")
        m.save(DeviceRule.Status(state: .hintPlus), scope: "a")
        XCTAssertNil(m.load(scope: "a"), "der Plus-Hinweis kommt nur nach einer frischen Antwort des Dienstes")
        m.save(blocked, scope: "a")
        m.save(nil, scope: "a")
        XCTAssertNil(m.load(scope: "a"))
        XCTAssertFalse(m.plusHintSeen(scope: "a"))
        m.markPlusHintSeen(scope: "a")
        XCTAssertTrue(m.plusHintSeen(scope: "a"))
        XCTAssertFalse(m.plusHintSeen(scope: "b"))
        m.save(blocked, scope: "a")
        m.forget(scope: "a")
        XCTAssertNil(m.load(scope: "a"))
        XCTAssertFalse(m.plusHintSeen(scope: "a"))
        XCTAssertEqual(DeviceRulePrice.text(store: "39,99 €", status: nil), "39,99 €", "Preis aus StoreKit geht vor")
        XCTAssertEqual(DeviceRulePrice.text(store: nil, status: blocked), "39,99 €", "Rückfall: Listenpreis des Dienstes")
        XCTAssertEqual(DeviceRulePrice.text(store: "", status: nil), "39,99 €")
    }

    // MARK: Hinweis-Bildschirm auf iPad und iPhone

    private func blockedLayout(taps: @escaping (String) -> Void = { _ in }) -> some View {
        DeviceLimitLayout(primaryName: "iPad", price: "39,99 €", onPlans: { taps("plans") }, onUseThis: { taps("use") }, onSignOut: { taps("out") })
    }

    private func assertBlockedScreen(_ env: HostedEnvironment, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, DeviceRuleTexts.blockedTitle) }, "\(name): \(dump(env))", file: file, line: line)
        let title = element(env, label: DeviceRuleTexts.blockedTitle)
        XCTAssertEqual(title?.accessibilityTraits.contains(.header), true, "\(name): Überschrift für VoiceOver", file: file, line: line)
        let spoken = "Dein Konto läuft schon auf einem anderen Gerät (iPad). Mit Pro AI nutzt du StudiNow auf iPhone und iPad – mit Abgleich. 39,99 € im Jahr."
        XCTAssertNotNil(element(env, label: spoken), "\(name): \(dump(env))", file: file, line: line)
        for label in ["Pro AI ansehen", "Dieses Gerät stattdessen nutzen", "Abmelden"] {
            let b = button(env, label)
            XCTAssertNotNil(b, "\(name): Knopf „\(label)“ fehlt: \(dump(env))", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame(b).height, 30, "\(name): \(label)", file: file, line: line)
        }
        XCTAssertTrue(shows(env, DeviceRuleTexts.dataStays), name, file: file, line: line)
    }

    func testBlockedScreenOnTheIPhone() throws {
        var taps: [String] = []
        let env = try hostPhone(blockedLayout { taps.append($0) }, api: remote(Canned()))
        assertBlockedScreen(env, "iPhone")
        assertFitsOnAllPhones(env, "geraete-hinweis")
        // die drei Knöpfe stehen untereinander und sind ganz im Bild
        let frames = ["Pro AI ansehen", "Dieses Gerät stattdessen nutzen", "Abmelden"].map { frame(button(env, $0)) }
        XCTAssertLessThan(frames[0].maxY, frames[1].minY + 1)
        XCTAssertLessThan(frames[1].maxY, frames[2].minY + 1)
        XCTAssertLessThanOrEqual(frames[2].maxY, Self.phone.height)
        XCTAssertTrue(tap(env, "Pro AI ansehen") && tap(env, "Dieses Gerät stattdessen nutzen") && tap(env, "Abmelden"))
        XCTAssertEqual(taps, ["plans", "use", "out"])
        shoot(env, "iphone-geraete-hinweis")
    }

    func testBlockedScreenOnTheIPad() throws {
        var taps: [String] = []
        let env = try hostPad(blockedLayout { taps.append($0) }, api: remote(Canned()))
        assertBlockedScreen(env, "iPad")
        assertFits(env, "geraete-hinweis-ipad")
        let b = frame(button(env, "Dieses Gerät stattdessen nutzen"))
        XCTAssertLessThanOrEqual(b.width, 400, "am iPad keine Knöpfe über die ganze Breite")
        XCTAssertTrue(tap(env, "Abmelden"))
        XCTAssertEqual(taps, ["out"])
        shoot(env, "ipad-geraete-hinweis")
        // ohne Namen des anderen Geräts und mit einer Fehlermeldung
        let other = try hostPad(DeviceLimitLayout(primaryName: nil, price: "39,99 €", busy: true, problem: DeviceRuleTexts.switchFailed,
                                                  onPlans: {}, onUseThis: {}, onSignOut: {}), api: remote(Canned()))
        XCTAssertTrue(other.wait(timeout: 5) { self.shows(other, "Dein Konto läuft schon auf einem anderen Gerät. Mit Pro AI") }, dump(other))
        XCTAssertTrue(shows(other, DeviceRuleTexts.switchFailed))
    }

    // MARK: Ablauf mit dem Dienst

    /// Free auf dem zweiten Geraet: Hinweis statt der App; "Dieses Gerät stattdessen nutzen" fragt nach und macht dieses
    /// Geraet zum einen Geraet. Jede Anfrage meldet die Faehigkeit.
    func testSecondDeviceSeesTheScreenInsteadOfTheAppAndCanTakeOver() throws {
        let service = Service(device: Service.status("blocked"))
        let (l, ent) = link(service)
        let env = try hostPhone(gate(l, ent), api: remote(Canned()))
        XCTAssertTrue(shows(env, "Die App"), "vor der Antwort des Dienstes nie gesperrt")
        l.use(userScope: scope)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, DeviceRuleTexts.blockedTitle) }, dump(env))
        XCTAssertFalse(shows(env, "Die App"), "statt der App")
        XCTAssertEqual(l.deviceStatus?.state, .blocked)
        XCTAssertEqual(DeviceRuleMemory(defaults: defaults).load(scope: scope)?.state, .blocked, "für den nächsten Start gemerkt")
        XCTAssertTrue(service.requests.allSatisfy { $0.headers[DeviceRule.capabilityHeader] == StudoraAccount.capabilities })
        assertBlockedScreen(env, "zweites Gerät")

        // Rückfrage: Abbrechen ändert nichts
        XCTAssertTrue(tap(env, "Dieses Gerät stattdessen nutzen"))
        let question = answerConfirm(env, false)
        XCTAssertEqual(question, "Dieses Gerät stattdessen nutzen?\n\n" + DeviceRuleTexts.confirmText(primaryName: "iPad"))
        env.pump(0.3)
        XCTAssertEqual(service.count("POST", "/api/account/device/primary"), 0)
        XCTAssertTrue(shows(env, DeviceRuleTexts.blockedTitle))

        // ohne Netz: Meldung, weiter der Hinweis, nichts gelöscht
        service.offline = true
        XCTAssertTrue(tap(env, "Dieses Gerät stattdessen nutzen"))
        _ = answerConfirm(env, true)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, DeviceRuleTexts.switchFailed) }, dump(env))
        XCTAssertEqual(l.deviceStatus?.state, .blocked)
        service.offline = false

        // mit Netz: dieses Gerät ist jetzt das eine Gerät, die App erscheint
        XCTAssertTrue(tap(env, "Dieses Gerät stattdessen nutzen"))
        _ = answerConfirm(env, true)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Die App") }, dump(env))
        XCTAssertFalse(shows(env, DeviceRuleTexts.blockedTitle))
        XCTAssertEqual(l.deviceStatus?.state, .ok)
        XCTAssertEqual(l.deviceStatus?.isPrimary, true)
        XCTAssertNil(DeviceRuleMemory(defaults: defaults).load(scope: scope), "Merker weg")
        XCTAssertNotNil(tokens.load(), "weiter angemeldet")
    }

    /// Beim naechsten Start ist der Hinweis sofort da (auch ohne Netz); ohne gemerkte Antwort sperrt ohne Netz nichts
    func testRememberedForTheNextStartButNeverBlockedWithoutAnAnswer() throws {
        let service = Service(device: Service.status("blocked"))
        service.offline = true
        // erster Start ohne Netz, nichts gemerkt: die App
        let (fresh, ent0) = link(service)
        let env0 = try hostPad(gate(fresh, ent0), api: remote(Canned()))
        fresh.use(userScope: scope)
        env0.pump(0.8)
        XCTAssertNil(fresh.deviceStatus)
        XCTAssertTrue(shows(env0, "Die App"), "ohne Netz nie sperren")
        XCTAssertFalse(shows(env0, DeviceRuleTexts.blockedTitle))

        // der Dienst hat einmal ausdrücklich "blocked" gesagt
        DeviceRuleMemory(defaults: defaults).save(DeviceRule.Status(state: .blocked, primaryName: "iPad", priceCents: 3999, currency: "EUR", period: "year"), scope: scope)
        let (l, ent) = link(service)
        let env = try hostPad(gate(l, ent), api: remote(Canned()))
        l.use(userScope: scope)
        XCTAssertEqual(l.deviceStatus?.state, .blocked, "sofort aus dem Merker, vor jeder Antwort")
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, DeviceRuleTexts.blockedTitle) }, dump(env))
        env.pump(0.8)
        XCTAssertTrue(shows(env, DeviceRuleTexts.blockedTitle), "ohne Netz bleibt der letzte Stand")

        // wieder Netz, das andere Gerät hat inzwischen abgegeben: beim nächsten Abruf frei
        service.offline = false
        service.device = Service.status("ok", primary: true, name: "iPhone")
        var done = false
        Task { await l.refresh(); done = true }
        XCTAssertTrue(env.wait(timeout: 10) { done })
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, "Die App") }, dump(env))
        XCTAssertNil(DeviceRuleMemory(defaults: defaults).load(scope: scope))
    }

    /// Ohne Sitzung beim Dienst gibt es nichts zu zaehlen: ein alter Merker sperrt nicht, er wird entfernt. Ein Dienst
    /// ohne die Regel (kein Feld `device`) und eine unbekannte Antwort sperren ebenfalls nie.
    func testNoSessionOlderServiceAndUnknownAnswersNeverBlock() throws {
        let memory = DeviceRuleMemory(defaults: defaults)
        memory.save(DeviceRule.Status(state: .blocked, primaryName: "iPad"), scope: scope)
        tokens = MemoryTokens(nil)
        let service = Service(device: Service.status("blocked"))
        let (l, ent) = link(service)
        let env = try hostPad(gate(l, ent), api: remote(Canned()))
        l.use(userScope: scope)
        XCTAssertTrue(env.wait(timeout: 5) { l.deviceStatus == nil && self.shows(env, "Die App") }, dump(env))
        XCTAssertNil(memory.load(scope: scope))
        XCTAssertEqual(service.requests.count, 0, "ohne Sitzung keine Anfrage")

        // älterer Dienst: Antwort ohne `device` hebt einen alten Merker auf
        memory.save(DeviceRule.Status(state: .blocked, primaryName: "iPad"), scope: scope)
        tokens = MemoryTokens("sitzung-1")
        let old = Service(device: nil)
        let (l2, ent2) = link(old)
        let env2 = try hostPad(gate(l2, ent2), api: remote(Canned()))
        l2.use(userScope: scope)
        XCTAssertTrue(env2.wait(timeout: 10) { old.count("GET", "/api/entitlements") > 0 && l2.deviceStatus == nil && self.shows(env2, "Die App") }, dump(env2))
        XCTAssertNil(memory.load(scope: scope))

        // unbekannter Zustand gilt als ok
        let odd = Service(device: Service.status("voellig_neu"))
        let (l3, ent3) = link(odd)
        let env3 = try hostPad(gate(l3, ent3), api: remote(Canned()))
        l3.use(userScope: scope)
        XCTAssertTrue(env3.wait(timeout: 10) { l3.deviceStatus?.state == .ok }, dump(env3))
        XCTAssertTrue(shows(env3, "Die App"))
    }

    /// Nach einem Kauf von Pro AI verschwindet der Hinweis sofort, auch bevor der Dienst den Kauf kennt
    func testBuyingProAILiftsTheScreenAtOnce() throws {
        let service = Service(device: Service.status("blocked"))
        let (l, ent) = link(service)
        let env = try hostPhone(gate(l, ent), api: remote(Canned()))
        l.use(userScope: scope)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, DeviceRuleTexts.blockedTitle) }, dump(env))
        ent.setPlanForTesting(.proAI)
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, "Die App") }, dump(env))
        XCTAssertFalse(shows(env, DeviceRuleTexts.blockedTitle))
        XCTAssertFalse(sheetOpen(env), "mit Pro AI auch kein Plus-Hinweis")
        XCTAssertEqual(l.deviceStatus?.state, .blocked, "der Dienst kennt den Kauf noch nicht")
        XCTAssertEqual(l.deviceGate(localPlan: ent.plan), .ok)
        // endet Pro AI wieder (Ablauf), ist der Hinweis zurück
        ent.setPlanForTesting(.free)
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, DeviceRuleTexts.blockedTitle) }, dump(env))
    }

    /// "Abmelden" beendet die Sitzung beim Dienst und fuehrt zur Begruessung; nichts auf dem Geraet wird geloescht
    func testSignOutEndsTheSessionAndLeavesTheScreen() throws {
        let service = Service(device: Service.status("blocked"))
        let (l, ent) = link(service)
        let env = try hostPhone(gate(l, ent), api: remote(Canned()))
        env.account.signIn(userID: appleUser, name: "Ada Beispiel", email: nil)
        XCTAssertNotNil(env.account.account)
        l.use(userScope: scope)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, DeviceRuleTexts.blockedTitle) }, dump(env))
        XCTAssertTrue(tap(env, "Abmelden"))
        XCTAssertTrue(env.wait(timeout: 10) { env.account.account == nil }, "zurück zur Begrüßung")
        XCTAssertEqual(service.count("POST", "/api/account/logout"), 1)
        XCTAssertNil(tokens.load())
        XCTAssertNil(l.deviceStatus)
        XCTAssertNil(DeviceRuleMemory(defaults: defaults).load(scope: scope))
        XCTAssertEqual(env.account.stage, .welcome)
    }

    // MARK: Plus: einmaliger Hinweis

    func testPlusHintLayoutFitsThePhone() throws {
        var taps: [String] = []
        let env = try hostPhone(DevicePlusHint(price: "39,99 €", onPlans: { taps.append("plans") }, onClose: { taps.append("close") }),
                                api: remote(Canned()))
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, DeviceRuleTexts.plusTitle) }, dump(env))
        XCTAssertEqual(element(env, label: DeviceRuleTexts.plusTitle)?.accessibilityTraits.contains(.header), true)
        XCTAssertTrue(shows(env, "Deine Notizen bleiben auf dem Gerät, auf dem du sie schreibst. Den Abgleich zwischen iPhone und iPad gibt es mit Pro AI für 39,99 € im Jahr."), dump(env))
        assertFitsOnAllPhones(env, "geraete-plus-hinweis")
        XCTAssertTrue(tap(env, "Pro AI ansehen") && tap(env, "Verstanden"))
        XCTAssertEqual(taps, ["plans", "close"])
        shoot(env, "iphone-geraete-plus-hinweis")
    }

    /// Plus auf dem zweiten Geraet: die App laeuft, einmal erscheint der Hinweis; nach "Verstanden" nie wieder
    func testPlusRunsAndShowsTheHintOnce() throws {
        let service = Service(device: Service.status("hint_plus"), plan: "plus")
        let (l, ent) = link(service, plan: .plus)
        let env = try hostPad(gate(l, ent), api: remote(Canned()))
        l.use(userScope: scope)
        XCTAssertTrue(waitSheet(env, showing: DeviceRuleTexts.plusTitle), dump(env))
        XCTAssertTrue(shows(env, "Die App"), "Plus wird nie gesperrt")
        XCTAssertFalse(shows(env, DeviceRuleTexts.blockedTitle))
        XCTAssertFalse(l.plusHintSeen, "erst nach dem Schließen")
        XCTAssertTrue(tap(env, "Verstanden"))
        XCTAssertTrue(env.wait(timeout: 10) { !self.sheetOpen(env) && l.plusHintSeen }, dump(env))
        XCTAssertTrue(DeviceRuleMemory(defaults: defaults).plusHintSeen(scope: scope))
        // nächster Abruf: derselbe Zustand, kein zweiter Hinweis
        var done = false
        Task { await l.refresh(); done = true }
        XCTAssertTrue(env.wait(timeout: 10) { done })
        env.pump(0.8)
        XCTAssertFalse(sheetOpen(env), "einmalig")

        // nächster Start
        let (again, ent2) = link(service, plan: .plus)
        let env2 = try hostPad(gate(again, ent2), api: remote(Canned()))
        again.use(userScope: scope)
        XCTAssertTrue(env2.wait(timeout: 10) { again.deviceStatus?.state == .hintPlus }, dump(env2))
        env2.pump(0.8)
        XCTAssertFalse(sheetOpen(env2), "auch beim nächsten Start nicht")
        XCTAssertTrue(shows(env2, "Die App"))
    }

    /// Solange der erste Start laeuft (Rundgang, Fragen), wartet der Hinweis; auf dem ersten Geraet kommt er nie
    func testPlusHintWaitsForTheAppAndStaysAwayOnTheFirstDevice() throws {
        let service = Service(device: Service.status("hint_plus"), plan: "plus")
        let (l, ent) = link(service, plan: .plus)
        let env = try hostPad(gate(l, ent, ready: false), api: remote(Canned()))
        l.use(userScope: scope)
        XCTAssertTrue(env.wait(timeout: 10) { l.deviceStatus?.state == .hintPlus }, dump(env))
        env.pump(0.8)
        XCTAssertFalse(sheetOpen(env))
        XCTAssertFalse(l.plusHintSeen)

        let first = Service(device: Service.status("ok", primary: true), plan: "plus")
        let (l2, ent2) = link(first, plan: .plus)
        let env2 = try hostPad(gate(l2, ent2), api: remote(Canned()))
        l2.use(userScope: scope)
        XCTAssertTrue(env2.wait(timeout: 10) { l2.deviceStatus?.state == .ok }, dump(env2))
        env2.pump(0.8)
        XCTAssertFalse(sheetOpen(env2))
    }
}

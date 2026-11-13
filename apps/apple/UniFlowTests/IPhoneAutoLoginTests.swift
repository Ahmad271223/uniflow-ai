import Security
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Automatisch anmelden auf dem iPhone (develop Build 10, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): der Schalter
/// "Passwort auf diesem iPhone merken" unter jeder Anmeldeseite (erster Start, Anmeldeblaetter) bricht um und ragt nicht
/// ueber den Rand, auch bei grosser Schrift; die Karte in den Einstellungen mit "Gespeichertes Passwort löschen" in
/// voller Breite. Nur erfundene Zugangsdaten, kein Netz, keine Anmeldung.
final class IPhoneAutoLoginTests: IPhoneLearnTestCase {
    private var services: [String] = []
    private var bed: ContainerTestBed?

    override func tearDown() async throws {
        await MainActor.run {
            for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
            services = []
        }
        if let bed { await bed.tearDown() }
        bed = nil
        try await super.tearDown()
    }

    /// Unterer Rand einer Anmeldeseite wie in QIS-, Stud.IP- und SOGo-Anmeldung: Hinweis und Schalter
    private struct LoginBottom: View {
        let store: WKWebsiteDataStore
        var body: some View {
            Color.gray.opacity(0.1)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        UniversityLoginHint()
                        UniRememberPasswordToggle(dataStore: store)
                    }
                }
        }
    }

    @MainActor private func attachedStore() -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        let d = UserDefaults(suiteName: "uniflow.tests.iphone.autologin.\(UUID().uuidString)")!
        let service = "de.uniflow.ai.uni-login.test.\(UUID().uuidString)"
        services.append(service)
        UniAutoLogin.attach(store, university: .luh, defaults: d, vault: UniCredentialStore(service: service, container: UUID()))
        addTeardownBlock { @MainActor in UniAutoLogin.detach(store) }
        return store
    }

    func testToggleUnderLoginPageWrapsAndFits() throws {
        let store = try awaiting { self.attachedStore() }
        XCTAssertTrue(UniRememberPasswordToggle.title.hasPrefix("Passwort auf diesem \(UFDevice.name) merken"))
        let env = try hostPhone(LoginBottom(store: store), api: local(Canned()))
        XCTAssertTrue(env.wait { self.element(env, id: "login.autologin") != nil }, dump(env))
        let toggle = frame(element(env, id: "login.autologin"))
        XCTAssertGreaterThan(toggle.width, env.window.bounds.width * 0.9, "Schalter-Zeile in voller Breite: \(toggle)")
        XCTAssertLessThanOrEqual(toggle.maxY, env.window.bounds.maxY + 0.5, "Schalter sichtbar")
        assertFitsOnAllPhones(env, "Schalter Anmeldung")
        shoot(env, "iphone-automatisch-anmelden-schalter")
        let big = try hostPhone(LoginBottom(store: store).environment(\.dynamicTypeSize, .accessibility3), api: local(Canned()))
        XCTAssertTrue(big.wait { self.element(big, id: "login.autologin") != nil }, dump(big))
        assertFits(big, "Schalter, sehr grosse Schrift")
    }

    func testUniAccessCardWithWideButtons() throws {
        let bed = try ContainerTestBed(name: "iphone-autologin", clock: .fixed(berlin: "2026-11-06T10:00:00")!)
        self.bed = bed
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        services.append(m.credentialService)
        let store = m.studip.websiteDataStore
        let vault = UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
        try vault.save(UniCredential(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", savedAt: Date()))
        let env = try hostPhone(ScrollView { UniAutoLoginCard().padding(16) }.environmentObject(m), api: local(Canned()))
        // Uni-Zugang (einmal speichern, 10.11.2026): "Speichern" und "Entfernen" in voller Breite untereinander
        XCTAssertTrue(env.wait { self.element(env, id: "settings.unilogin.shared.remove") != nil }, dump(env))
        let save = frame(element(env, id: "settings.unilogin.shared.save"))
        let remove = frame(element(env, id: "settings.unilogin.shared.remove"))
        XCTAssertGreaterThan(save.width, env.window.bounds.width * 0.7, "Speichern in voller Breite")
        XCTAssertGreaterThan(remove.width, env.window.bounds.width * 0.7, "Entfernen in voller Breite")
        XCTAssertGreaterThan(remove.minY, save.maxY - 1, "untereinander")
        XCTAssertTrue(shows(env, UniAutoLoginCard.sameTitle), "Haken „überall gleich“: \(dump(env))")
        XCTAssertTrue(shows(env, "nur auf diesem \(UFDevice.name)") || shows(env, "dieses \(UFDevice.name)s"))
        assertFitsOnAllPhones(env, "Karte Uni-Zugang")
        UniAutoLogin.forget(store)
    }
}

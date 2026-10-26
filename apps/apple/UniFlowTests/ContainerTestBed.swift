import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Umgebung fuer App-Tests mit Containern (erfundener Apple-Nutzer, eigene Schluesselbund-Dienste, eigene
/// UserDefaults-Suite, Temp-Ordner): Container-Verwaltung wie in der App, Transporte der Hildesheimer Abgleiche und
/// des QIS-Abrufs ueber `UniStubProtocol` (nie ins Netz), Stud.IP ueber einen `StudIPTransport` des Tests.
/// Gemeinsam fuer FirstStartAppTests, QISAppTests und HildesheimParityAppTests (HildesheimAppTests hat dieselbe
/// Einrichtung schon in sich).
@MainActor
final class ContainerTestBed {
    final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    let appSupport: URL
    let keychain: UniversityKeychain
    let cookieService: String
    let suite: String
    let defaults: UserDefaults
    let user: String
    let clock: UniFlowClock
    private var websiteStores: [UUID] = []

    init(name: String, clock: UniFlowClock) throws {
        self.clock = clock
        user = "001234.erfunden-\(name).\(UUID().uuidString.prefix(8))"
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        cookieService = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        suite = "uniflow.tests.\(name).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        UniStubProtocol.reset()
    }

    var containers: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    /// Container-Verwaltung wie in der App; Hildesheim und QIS antworten ueber `UniStubProtocol`
    func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: URLSessionUniTransport.hildesheimDomains + QISConnection.qisDomains,
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: containers,
                                legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: keychain, cookieService: cookieService, defaults: defaults, clock: clock, publishesCurrent: false,
                                hildesheimTransport: stub, qisTransport: stub)
    }

    /// Konto nach Anmeldung und Tarifwahl mit gewaehlter Hochschule (die Anmeldeseiten noch nicht gezeigt)
    func account(_ uni: UniversityKey) -> AccountStore {
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a.signIn(userID: user, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(uni)
        return a
    }

    /// Container oeffnen; merkt sich den Datenspeicher der Webansicht zum Aufraeumen
    func open(_ m: ContainerManager, _ a: AccountStore) throws -> ActiveContainer {
        m.sync(account: a)
        let c = try XCTUnwrap(m.active, m.problem ?? "kein Container")
        websiteStores.append(c.websiteDataStoreID)
        return c
    }

    func cookie(_ name: String, _ value: String, domain: String, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
                                .expires: Date().addingTimeInterval(3600)])!
    }

    /// Datei aus dem Repository (relativ zur Wurzel)
    nonisolated static func repoURL(_ relative: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(relative)
    }

    /// Ordner des Debug-Stubs fuer den ersten Start (erfundene Antworten beider Hochschulen)
    nonisolated static var stubDirectory: URL { repoURL("apps/apple/DebugStub/erststart") }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)", file: file, line: line)
    }

    func tearDown() async {
        UniStubProtocol.reset()
        keychain.accounts().forEach(keychain.remove)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: cookieService] as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
        for layout in DataContainerLayout.all(base: containers, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            websiteStores.append(layout.identifier)
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        try? FileManager.default.removeItem(at: appSupport)
    }
}

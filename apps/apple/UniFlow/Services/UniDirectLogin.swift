import Foundation
import UniFlowCore
import WebKit

// Anmeldung im Hintergrund ohne Webansicht (Entscheidung des Inhabers 20.11.2026, docs/HINTERGRUND-ANMELDUNG-2026-11-20.md):
// der Ablauf `UniFormLogin` (Kern) mit einer URLSession und den Cookies des Containers (`URLSessionUniTransport`, nur
// HTTPS-Rechner der eigenen Hochschule). Gelingt die Anmeldung, kommen die neuen Cookies der Hochschule in den
// Datenspeicher der Webansichten (dort liest sie jeder Abgleich) und ueber `UniWebSessions` in den Schluesselbund.
// Das Passwort kommt nur aus `UniAutoLogin.handleExpiry` (Schluesselbund dieses Geraets), geht nur in den Koerper EINER
// POST-Anfrage an das Formular der Hochschule und nie an einen StudiNow-Server; es wird nie protokolliert.

@MainActor
enum UniDirectLogin {
    /// Tests: URLSession-Konfiguration mit festen Antworten (`UniStubProtocol`); ohne sie nie unter XCTest und nie mit der
    /// Debug-Nachbildung (dort bleibt alles wie bisher)
    static var configurationOverride: URLSessionConfiguration?
    /// Zeitlimit eines Ablaufs (der kurze Hintergrundlauf laesst ohnehin nur ab 25 Sekunden Restzeit anmelden)
    static var limit: TimeInterval = 25
    /// Zahl der Ablaeufe und letztes Ergebnis (Tests)
    private(set) static var runs = 0
    private(set) static var last: UniFormLogin.Result?

    static var available: Bool { configurationOverride != nil || (!StudIPSync.isUnderTest() && !DebugUniStub.isActive) }

    /// Mit dem gespeicherten Zugang (nur aus `UniAutoLogin.handleExpiry` im Hintergrund). nil: nichts gesendet und kein
    /// bekanntes Formular (`.unsupported`) - dann darf der Aufrufer es einmal mit der unsichtbaren Webansicht versuchen.
    static func attempt(_ r: UniAutoLoginRequest) async -> UniAutoLoginOutcome? {
        guard available else { return nil }
        let result = await run(store: r.store, university: r.university, entry: r.entry,
                               credential: (r.credential.username, r.credential.password), isDone: r.isDone)
        switch result {
        case .done: return .success
        case .rejected: return .wrongPassword
        case .failed: return .failed
        case .blocked: return .blocked
        case .cancelled: return .cancelled
        case .needsPassword, .unsupported: return nil
        }
    }

    /// Ohne Passwort: gilt die Uni-Anmeldung (WebSSO-Cookie des IdP bzw. TGC des CAS) noch, kommt der Ablauf von selbst
    /// beim Dienst an. `.needsPassword`: die Hochschule will das Passwort (nichts gesendet).
    static func silent(store: WKWebsiteDataStore, university: UniversityKey, entry: URL,
                       isDone: @escaping @MainActor (URL, String) async -> Bool) async -> UniFormLogin.Result {
        guard available else { return .unsupported }
        return await run(store: store, university: university, entry: entry, credential: nil, isDone: isDone)
    }

    private static func run(store: WKWebsiteDataStore, university: UniversityKey, entry: URL, credential: (String, String)?,
                            isDone: @escaping @MainActor (URL, String) async -> Bool) async -> UniFormLogin.Result {
        runs += 1
        let domains = UniWebSessions.domains(university)
        let config = (configurationOverride?.copy() as? URLSessionConfiguration) ?? .ephemeral
        let transport = await URLSessionUniTransport.make(dataStore: store, allowedDomains: domains, configuration: config)
        let result = await UniFormLogin.run(transport: transport, entry: entry, university: university, domains: domains,
                                            credential: credential.map { (username: $0.0, password: $0.1) },
                                            deadline: Date().addingTimeInterval(limit)) { url, html in await isDone(url, html) }
        last = result
        if case .done = result {
            // neue Sitzung der Hochschule in den Datenspeicher (ersetzt gleichnamige) und ueber Neustarts merken
            let fresh = (transport.cookies.cookies ?? []).filter { UniWebSessions.matches($0, domains) }
            for c in fresh { await store.httpCookieStore.setCookie(c) }
            await UniWebSessions.save(store)
        }
        return result
    }
}

import Foundation
import UniFlowCore
import WebKit

// HTTP der Hochschul-Abgleiche in der App, docs/AUFTRAG-HILDESHEIM-IPAD.md ("duenne Schicht", Punkt 1): Uni Hildesheim
// (CAS, Learnweb, LSF) direkt, Stud.IP der LUH ueber `URLSessionStudIPTransport` (StudIPSync.swift). Der Kern
// (`HildesheimSync`, `LearnwebAPI`, `LSFClient`, `StudIPClient`) kennt nur seine Transport-Protokolle; hier steckt die
// eine URLSession-Umsetzung dahinter.

/// `UniTransport` mit einer eigenen, fluechtigen URLSession je Lauf und Container (Apple-Nutzer, Hochschule). Die
/// Cookies kommen aus dem Datenspeicher der Anmelde-Webansichten genau dieses Containers
/// (`WKWebsiteDataStore(forIdentifier: DataContainerKey.websiteDataStoreID)`, `ContainerManager.websiteDataStore`);
/// Cookies, die die Uni waehrend des Laufs setzt, bleiben in dieser Sitzung (nur im Arbeitsspeicher) und gehen nie an
/// einen anderen Container.
///
/// Die Cookies setzt der Transport selbst (`httpShouldSetCookies` aus): bei jeder Anfrage und jeder Weiterleitung nur
/// die zur Zieladresse passenden, damit eine Weiterleitung auf einen anderen Rechner keine fremden Cookies mitnimmt.
/// Angefragt werden nur HTTPS-Adressen der Hochschule (`allowedDomains`); eine Weiterleitung anderswohin wird nicht
/// verfolgt, und ein Formular-Koerper (Learnweb-Schluessel) geht nie an einen anderen Rechner als den der Anfrage.
/// `followRedirects == false` (Moodle-Dateilinks): die Weiterleitung kommt als Antwort zurueck (Location-Header).
/// Downloads gehen mit `URLSession.download(for:)` direkt auf die Platte und werden an ihr Ziel verschoben.
/// Adressen, Schluessel und Cookies werden nie protokolliert.
final class URLSessionUniTransport: UniTransport, @unchecked Sendable {
    /// Rechner der Uni Hildesheim (CAS www.uni-hildesheim.de, Learnweb, LSF lsf.uni-hildesheim.de) aus dem Profil
    static var hildesheimDomains: [String] {
        let p = UniversityProfile.hildesheim
        let hosts = [p.casBase, p.learnwebBase, p.lsfBase].compactMap { $0?.host?.lowercased() }
        return Array(Set(hosts.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })).sorted()
    }

    /// Rechner des Stud.IP der LUH: Stud.IP selbst und die Anmeldeseiten aus dem Profil (WebSSO /idp/, Stud.IP-Login),
    /// auf die eine abgelaufene Sitzung weiterleitet (`StudIPClient.looksLikeLogin`)
    static var studipDomains: [String] {
        let p = UniversityProfile.luh
        let hosts = [p.studipBase?.host?.lowercased()].compactMap { $0 }
            + (p.loginServices.first { $0.key == "studip" }?.targets.map { $0.host.lowercased() } ?? [])
        return Array(Set(hosts)).sorted()
    }

    private let session: URLSession
    /// Cookies dieses Laufs (Kopie aus dem Datenspeicher des Containers, dazu Set-Cookie der Antworten)
    let cookies: HTTPCookieStorage
    let allowedDomains: [String]

    /// `configuration`: nur Tests (feste Antworten ueber `URLProtocol`); sonst fluechtig, ohne Cookie-Speicher und Cache.
    init(cookies initial: [HTTPCookie], allowedDomains: [String] = URLSessionUniTransport.hildesheimDomains,
         configuration: URLSessionConfiguration = .ephemeral) {
        // eigener Cookie-Speicher im Arbeitsspeicher (jede fluechtige Konfiguration hat einen neuen); nie ein
        // gemeinsamer oder dauerhafter Speicher (im schlimmsten Fall gehen keine Cookies mit: "Anmeldung nötig")
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        jar.cookieAcceptPolicy = .always
        for c in initial { jar.setCookie(c) }
        cookies = jar
        self.allowedDomains = allowedDomains.map { $0.lowercased() }
        let config = configuration
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 30 s ohne Daten gilt als abgerissen (wiederholbar); kein festes Gesamtlimit: vorher brach nach 10 Minuten
        // jede grosse Datei bei langsamem WLAN ab, wurde dreimal von vorn geladen und kam nie an
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Transport mit den Cookies des Datenspeichers eines Containers (Stand jetzt; spaetere Anmeldungen sieht erst
    /// der naechste Lauf)
    @MainActor
    static func make(dataStore: WKWebsiteDataStore, allowedDomains: [String] = hildesheimDomains,
                     configuration: URLSessionConfiguration = .ephemeral) async -> URLSessionUniTransport {
        await UniWebSessions.ready(dataStore)                  // Anmeldung von vor dem Neustart zuerst zurueck
        let cookies = await dataStore.httpCookieStore.allCookies()
        return URLSessionUniTransport(cookies: cookies, allowedDomains: allowedDomains, configuration: configuration)
    }

    // MARK: UniTransport

    func send(_ request: UniRequest) async throws -> UniResponse {
        let r = try prepared(request)
        let (data, response) = try await session.data(for: r, delegate: Redirects(transport: self, follow: request.followRedirects, original: r))
        return try reply(response, body: data)
    }

    func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
        let r = try prepared(request)
        let (temp, response) = try await session.download(for: r, delegate: Redirects(transport: self, follow: request.followRedirects, original: r))
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temp) }
        let out = try reply(response)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
        return out
    }

    // MARK: Anfragen

    /// Nur HTTPS auf einem Rechner der Hochschule (Port Standard)
    func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.port == nil || url.port == 443 else {
            return false
        }
        return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func prepared(_ request: UniRequest) throws -> URLRequest {
        // ohne Adresse in der Meldung (sie kann einen sesskey tragen)
        guard allows(request.url) else { throw HildesheimError.badResponse("Anfrage außerhalb der Hochschule abgelehnt") }
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers where k.lowercased() != "cookie" { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        setCookieHeader(&r)
        return r
    }

    /// Cookie-Kopfzeile genau fuer die Adresse dieser Anfrage (ersetzt eine geerbte)
    fileprivate func setCookieHeader(_ r: inout URLRequest) {
        let matching = r.url.flatMap { cookies.cookies(for: $0) } ?? []
        r.setValue(HTTPCookie.requestHeaderFields(with: matching)["Cookie"], forHTTPHeaderField: "Cookie")
    }

    /// Set-Cookie einer Antwort (auch einer Weiterleitung) in den Speicher dieses Laufs
    fileprivate func remember(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields { if let k = k as? String { fields[k] = "\(v)" } }
        let set = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !set.isEmpty { cookies.setCookies(set, for: url, mainDocumentURL: nil) }
    }

    private func reply(_ response: URLResponse, body: Data = Data()) throws -> UniResponse {
        guard let http = response as? HTTPURLResponse else { throw HildesheimError.badResponse("keine HTTP-Antwort") }
        remember(http)
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
        return UniResponse(status: http.statusCode, headers: headers, finalURL: http.url, body: body)
    }

    /// Weiterleitungen einer Aufgabe: Cookies der Zwischenantwort merken, dann folgen (mit den Cookies des neuen
    /// Ziels) oder die Weiterleitung als Antwort zurueckgeben
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let transport: URLSessionUniTransport
        let follow: Bool
        let original: URLRequest

        init(transport: URLSessionUniTransport, follow: Bool, original: URLRequest) {
            self.transport = transport
            self.follow = follow
            self.original = original
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            transport.remember(response)
            guard follow, transport.allows(request.url) else { return nil }
            // ein Koerper (z. B. token=… beim Learnweb-Download, 307/308) nie an einen anderen Rechner
            if request.httpBody != nil || request.httpBodyStream != nil,
               request.url?.host?.lowercased() != original.url?.host?.lowercased() { return nil }
            var next = request
            transport.setCookieHeader(&next)
            return next
        }
    }
}

/// Anmeldung der Hochschule ueber App-Neustarts (3.11.2026, "Studierende muessen direkt angemeldet sein").
///
/// Die Webansichten eines Containers teilen sich einen dauerhaften `WKWebsiteDataStore(forIdentifier:)`: eine Anmeldung
/// am WebSSO der LUH (Shibboleth-IdP, Stud.IP) bzw. am CAS der Uni Hildesheim (Learnweb, LSF) gilt fuer alle Dienste
/// derselben Hochschule. WebKit schreibt aber nur Cookies mit Ablaufdatum auf die Platte; Sitzungs-Cookies ohne Ablauf
/// (`shib_idp_session`, `TGC` des CAS, `JSESSIONID` des LSF, `MoodleSession`) leben nur, solange der Prozess lebt.
/// Beendete iOS die App, war die Uni-Anmeldung weg, die stille Erneuerung scheiterte, und es hiess "Anmeldung nötig".
///
/// Darum legt die App genau diese Sitzungs-Cookies der Hochschul-Rechner zusaetzlich in den Schluesselbund (wie das
/// Stud.IP-Sitzungs-Cookie: nur dieses Geraet, nicht in Backups/iCloud, je Container ein Eintrag
/// `web-sessions.<container-uuid>`) und setzt sie beim Oeffnen des Containers wieder in den Datenspeicher. Wie lange
/// die Anmeldung gilt, entscheidet weiterhin die Hochschule (ihr Server verwirft alte Sitzungen). Nie ein Passwort,
/// nie Formularinhalte, nur Cookies der Hochschul-Rechner (`domains`). Abmelden und "Daten dieser Hochschule löschen"
/// leeren den Eintrag (`forget`), bevor die Webdaten gehen: eine alte Sitzung kommt nie zurueck.
@MainActor
enum UniWebSessions {
    static let accountPrefix = "web-sessions."

    /// Eintrag im Schluesselbund eines Containers
    static func vault(service: String = StudIPCookieStore.service, container: UUID) -> StudIPCookieStore {
        StudIPCookieStore(service: service, account: accountPrefix + container.uuidString)
    }

    /// Rechner der Hochschule (registrierbare Domain aus dem Profil, z. B. uni-hannover.de, uni-hildesheim.de)
    static func domains(_ u: UniversityKey) -> [String] {
        let p = u.profile
        let urls = [p.studipBase, p.casBase, p.learnwebBase, p.lsfBase].compactMap { $0 }
            + p.loginServices.flatMap { $0.entryURLs }
        let hosts = urls.compactMap { $0.host?.lowercased() } + p.loginServices.flatMap { $0.targets.map { $0.host.lowercased() } }
        return Array(Set(hosts.map { $0.split(separator: ".").suffix(2).joined(separator: ".") })).filter { $0.contains(".") }.sorted()
    }

    static func matches(_ c: HTTPCookie, _ domains: [String]) -> Bool {
        let d = (c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain).lowercased()
        return domains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    private final class Entry {
        /// schwach: eine spaetere Instanz an derselben Adresse gilt nie als dieser Datenspeicher
        weak var store: WKWebsiteDataStore?
        let vault: StudIPCookieStore
        let domains: [String]
        var restore: Task<Void, Never>?
        init(store: WKWebsiteDataStore, vault: StudIPCookieStore, domains: [String]) {
            self.store = store
            self.vault = vault
            self.domains = domains
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    private static func entry(_ store: WKWebsiteDataStore) -> Entry? {
        guard let e = entries[ObjectIdentifier(store)], e.store === store else { return nil }
        return e
    }

    /// Datenspeicher eines Containers anmelden und die gemerkte Anmeldung sofort zuruecksetzen (`ready` wartet darauf)
    static func attach(_ store: WKWebsiteDataStore, vault: StudIPCookieStore, domains: [String]) {
        guard entry(store) == nil else { return }
        entries = entries.filter { $0.value.store != nil }           // freigegebene Datenspeicher vergessen
        let e = Entry(store: store, vault: vault, domains: domains)
        entries[ObjectIdentifier(store)] = e
        e.restore = Task { _ = await restore(into: store, from: vault, domains: domains) }
    }

    /// Datenspeicher abmelden (Container geloescht); der Eintrag im Schluesselbund geht mit `vault.clear()`
    static func detach(_ store: WKWebsiteDataStore) {
        if entry(store) != nil { entries.removeValue(forKey: ObjectIdentifier(store)) }
    }

    /// Wartet, bis die gemerkte Anmeldung wieder im Datenspeicher steht (sofort, wenn keiner angemeldet ist)
    static func ready(_ store: WKWebsiteDataStore) async { await entry(store)?.restore?.value }

    /// Aktuelle Sitzungs-Cookies der Hochschule merken (nach einer Anmeldung, beim Wechsel in den Hintergrund)
    static func save(_ store: WKWebsiteDataStore) async {
        guard let e = entry(store) else { return }
        await e.restore?.value
        _ = await save(store, to: e.vault, domains: e.domains)
    }

    /// Abmelden: Gemerktes loeschen (vor dem Leeren der Webdaten aufrufen)
    static func forget(_ store: WKWebsiteDataStore) async {
        guard let e = entry(store) else { return }
        await e.restore?.value
        e.vault.clear()
    }

    /// Gemerkte Sitzungs-Cookies in den Datenspeicher; vorhandene (neuere) bleiben. Rueckgabe: Zahl der gesetzten.
    @discardableResult
    static func restore(into store: WKWebsiteDataStore, from vault: StudIPCookieStore, domains: [String]) async -> Int {
        let saved = vault.load().filter { $0.isSessionOnly && matches($0, domains) }
        guard !saved.isEmpty else { return 0 }
        let present = await store.httpCookieStore.allCookies()
        var n = 0
        for c in saved where !present.contains(where: { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }) {
            await store.httpCookieStore.setCookie(c)
            n += 1
        }
        return n
    }

    /// Sitzungs-Cookies der Hochschule aus dem Datenspeicher in den Schluesselbund (keine: Eintrag weg). Cookies mit
    /// Ablaufdatum behaelt WebKit selbst. Rueckgabe: Zahl der gemerkten.
    @discardableResult
    static func save(_ store: WKWebsiteDataStore, to vault: StudIPCookieStore, domains: [String]) async -> Int {
        let session = await store.httpCookieStore.allCookies().filter { $0.isSessionOnly && matches($0, domains) }
        if session.isEmpty { vault.clear() } else { try? vault.save(session) }
        return session.count
    }
}

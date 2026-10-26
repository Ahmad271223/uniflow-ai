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

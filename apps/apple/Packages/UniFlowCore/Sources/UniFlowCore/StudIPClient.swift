import Foundation

// Stud.IP direkt vom Geraet: die Anmeldung laeuft auf der echten Hochschulseite (WebSSO), danach nutzt die App
// das Sitzungs-Cookie fuer die JSON:API. Dieselben Routen wie app/studip_sync.py; am 25.10.2026 an der LUH
// geprueft: Ordnerbaum ueber die API liefert dieselben 151 Dateien wie der PC-Abgleich, Download per
// file-refs/{id}/content byte-genau.

/// Antwort einer HTTP-Anfrage. Ohne URLSession, damit der Kern auch unter Linux testbar bleibt.
public struct HTTPReply: Sendable {
    public let status: Int
    public let contentType: String
    public let finalURL: URL?
    public let body: Data
    /// Kopfzeile `Location` (Abgeben: Stud.IP antwortet auf ein Hochladen mit 201 und der Adresse der neuen Datei)
    public let location: String?

    public init(status: Int, contentType: String = "", finalURL: URL? = nil, body: Data = Data(), location: String? = nil) {
        self.status = status
        self.contentType = contentType
        self.finalURL = finalURL
        self.body = body
        self.location = location
    }

    /// Erfolg mit JSON-Inhalt (Inhaltstyp `application/json` bzw. `application/vnd.api+json`; ohne Inhaltstyp zaehlt
    /// ein Koerper, der mit `{` oder `[` beginnt)
    public var isJSON: Bool {
        guard (200..<300).contains(status) else { return false }
        let t = contentType.lowercased()
        if t.contains("json") { return true }
        guard t.isEmpty || !t.contains("html") else { return false }
        let head = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("{") || head.hasPrefix("[")
    }
}

/// Transport fuer Stud.IP-Anfragen: die App setzt das Sitzungs-Cookie, Tests liefern feste Antworten.
public protocol StudIPTransport: Sendable {
    func get(_ url: URL, accept: String?) async throws -> HTTPReply
    /// Antwort direkt in `file` schreiben (grosse Dateien nicht im Arbeitsspeicher); `body` der Rueckgabe ist leer.
    func download(_ url: URL, to file: URL) async throws -> HTTPReply
}

/// Schreibende Anfrage (nur "Abgeben", docs/ABGEBEN-STUDIP-2026-11-05.md): POST/PATCH mit Koerper. Getrennt vom
/// Lese-Transport, damit der Abgleich nie schreiben kann; Transporte ohne diese Faehigkeit lehnen ab.
public protocol StudIPWritingTransport: StudIPTransport {
    func send(_ url: URL, method: String, headers: [String: String], body: Data) async throws -> HTTPReply
}

extension StudIPTransport {
    /// Ersatz fuer Transporte ohne eigenen Download (Tests): ueber `get`, danach in die Datei.
    public func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let r = try await get(url, accept: nil)
        try r.body.write(to: file, options: .atomic)
        return HTTPReply(status: r.status, contentType: r.contentType, finalURL: r.finalURL)
    }
}

public enum StudIPError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 401 oder Weiterleitung auf die Anmeldeseite: Nutzer muss sich neu anmelden.
    case sessionExpired
    case http(status: Int, path: String)
    case badResponse(String)
    case requestLimit

    public var description: String {
        switch self {
        case .sessionExpired: return "Stud.IP-Anmeldung abgelaufen. Bitte neu anmelden."
        case .http(let s, let p): return "Stud.IP antwortet mit HTTP \(s) (\(p))."
        case .badResponse(let r): return "Unerwartete Antwort von Stud.IP: \(r)"
        case .requestLimit: return "Abgleich abgebrochen: zu viele Anfragen in einem Durchgang."
        }
    }

    public var errorDescription: String? { description }

    /// Fehler, der nur einen Kurs oder eine Datei betrifft (HTTP-Fehler, unerwartete Antwort, z. B. ein Kurs ohne
    /// Dateibereich oder eine gesperrte Datei): Der Abgleich macht wie run_sync in app/studip_sync.py mit dem
    /// naechsten weiter. Abgelaufene Sitzung und Anfragegrenze brechen den Lauf ab.
    public var affectsOnlyItem: Bool {
        switch self {
        case .http, .badResponse: return true
        case .sessionExpired, .requestLimit: return false
        }
    }
}

public struct StudIPCourse: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let number: String?
    public let semesterTitle: String?
    /// Beginn des Startsemesters wie geliefert (ISO-8601), zum Sortieren und fuer die Vorauswahl.
    public let semesterStart: String?
    /// Titel des Endsemesters (`end-semester`), "unbegrenzt" bei `data: null`, nil ohne die Beziehung (aeltere
    /// Stud.IP-Fassung), wie `fetch_courses` in app/studip_sync.py (Semesterregel, `Semesters`)
    public let semesterEnd: String?
    /// Ende dieses Semesters (Attribut `end`, ISO mit Versatz) oder nil
    public let semesterEndsAt: String?
    /// Kursbeschreibung und Sonstiges als Text (`course_texts` in app/studip_sync.py); nil, wenn Stud.IP das Feld nicht
    /// liefert (dann bleibt der gespeicherte Text). Annahme: Attribute `description` und `miscellaneous` (Stud.IP 6.x)
    public let description: String?
    public let miscellaneous: String?
    /// `course-type` (Veranstaltungsart, SEM_TYPE in Stud.IP); nil ohne Angabe oder aus einer Kursliste von vor dem
    /// 12.11.2026 (courses.json). Daran erkennt `StudIPStudyGroups` Studiengruppen.
    public let courseType: Int?

    public init(id: String, title: String, number: String? = nil, semesterTitle: String? = nil, semesterStart: String? = nil,
                semesterEnd: String? = nil, semesterEndsAt: String? = nil, description: String? = nil, miscellaneous: String? = nil,
                courseType: Int? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.semesterTitle = semesterTitle
        self.semesterStart = semesterStart
        self.semesterEnd = semesterEnd
        self.semesterEndsAt = semesterEndsAt
        self.description = description
        self.miscellaneous = miscellaneous
        self.courseType = courseType
    }
}

public struct StudIPFile: Sendable, Equatable, Codable {
    public let id: String
    public let courseID: String
    public let name: String
    public let size: Int
    public let mimeType: String?
    /// Aenderungszeitpunkt wie geliefert; dient nur dem Vergleich mit dem lokalen Stand.
    public let changed: String
    public let isDownloadable: Bool
    /// Ordnerpfad im Kurs ohne Wurzelordner, z. B. "Vorlesung/Folien".
    public let folderPath: String
    /// Datei "Link/Webadresse": nicht herunterladbar, aber mit Adresse (nur http/https); die Dateiliste bietet sie
    /// zum Oeffnen im Browser an. nil fuer alle anderen Dateien
    public let linkURL: String?

    public init(id: String, courseID: String, name: String, size: Int, mimeType: String? = nil, changed: String,
                isDownloadable: Bool = true, folderPath: String = "", linkURL: String? = nil) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.changed = changed
        self.isDownloadable = isDownloadable
        self.folderPath = folderPath
        self.linkURL = linkURL
    }

    /// Adresse einer nicht herunterladbaren Datei (Stud.IP "Link/Webadresse"). Annahme (Stud.IP 6.x JSON:API, nicht an
    /// der LUH geprueft): die Adresse steht in `attributes.url`, `attributes.external-url` oder `meta.url`; fehlt sie
    /// oder ist sie kein http(s)-Link, bleibt die Datei "nicht herunterladbar" wie bisher.
    static func linkURL(_ ref: JSONValue) -> String? {
        let candidates = [ref["attributes"]?["url"], ref["attributes"]?["external-url"], ref["meta"]?["url"]]
        for c in candidates {
            guard let s = c?.string?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: s),
                  let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host?.isEmpty == false else { continue }
            return s
        }
        return nil
    }
}

/// Dateiliste eines Kurses mit den Unterordnern, die sich nicht lesen liessen (403/404): ihre Dateien fehlen in der
/// Liste, der Rest des Kurses ist gelesen.
public struct StudIPFileListing: Sendable, Equatable {
    public var files: [StudIPFile] = []
    public var unreadableFolders = 0
    /// Vergleich der flachen Ordnerliste (`courses/{id}/folders`) mit dem Ordnerbaum, den der Lauf ueber die
    /// Unterordner gelesen hat (nur `StudIPFolderMode.walk`); bestimmt, ob spaetere Laeufe die flache Liste nehmen
    public var folderCheck: StudIPFolderCheck = .inconclusive
    /// Gelesen ueber die flache Ordnerliste (ohne Unterordner-Abfrage je Ordner)
    public var usedFlatList = false

    public init(files: [StudIPFile] = [], unreadableFolders: Int = 0) {
        self.files = files
        self.unreadableFolders = unreadableFolders
    }
}

/// Wie die Dateiliste eines Kurses ihre Ordner findet (Tempo des Abgleichs, 07.11.2026)
public enum StudIPFolderMode: Sendable, Equatable {
    /// Ordnerbaum wie bisher: je Ordner Dateien und Unterordner (1 + 2 Anfragen je Ordner); vergleicht dabei den Baum
    /// mit der flachen Ordnerliste (`StudIPFileListing.folderCheck`)
    case walk
    /// Ordner aus der flachen Liste `courses/{id}/folders` (Beziehung `parent`, Stud.IP-Doku): nur die Dateien je Ordner
    /// (1 + 1 Anfrage je Ordner). Nur, wenn ein frueherer Lauf die flache Liste am Baum bestaetigt hat; passt die Liste
    /// nicht zusammen (Elternordner fehlt, keine Wurzel, keine Beziehung), liest der Kurs wie `walk`
    case flat
}

/// Ergebnis des Vergleichs flache Ordnerliste gegen Ordnerbaum
public enum StudIPFolderCheck: Sendable, Equatable {
    /// nichts zu sagen (kein Unterordner im Kurs oder nicht verglichen)
    case inconclusive
    /// jeder Ordner des Baums steht mit demselben Elternordner in der flachen Liste, und jede gelesene Unterordnerliste
    /// stimmt mit der flachen ueberein
    case confirmed
    /// Abweichung: spaetere Laeufe lesen weiter den Baum
    case mismatch
}

/// Nur lesender Zugriff auf die Stud.IP-JSON:API. Jede Anfrage mit kurzer Pause; seit 07.11.2026 (Tempo des Abgleichs)
/// hoechstens `maxConcurrent` Anfragen zugleich (Standard 4) statt streng nacheinander, damit der Abgleich die Hochschule
/// massvoll belastet, aber nicht jede Ordnerliste auf die vorige wartet. Wer nacheinander fragt, merkt keinen Unterschied.
public actor StudIPClient {
    public let base: URL
    let transport: StudIPTransport
    private let pauseNanos: UInt64
    private let maxRequests: Int
    /// Downloads: abgerissene Verbindungen wiederholen wie `stream_download` (dieselbe Regel wie fuer Learnweb)
    private let retry: UniRetry
    public private(set) var requestCount = 0
    /// Pause vor jeder Anfrage ausser der ersten (die App: `StudIPSync.livePauseMillis`)
    public nonisolated var pauseMillis: UInt64 { pauseNanos / 1_000_000 }
    /// Anfragen zugleich (Abgleich: Dateilisten mehrerer Kurse und Ordner)
    public static let defaultConcurrency = 4
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    static let jsonAPI = "application/vnd.api+json"

    public init(base: URL, transport: StudIPTransport, pauseMillis: UInt64 = 250, maxRequests: Int = 1500, retry: UniRetry = UniRetry(),
                maxConcurrent: Int = StudIPClient.defaultConcurrency) {
        self.base = base
        self.transport = transport
        self.pauseNanos = pauseMillis * 1_000_000
        self.maxRequests = maxRequests
        self.retry = retry
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Platz fuer eine Anfrage (hoechstens `maxConcurrent` zugleich); ein freiwerdender Platz geht direkt an den
    /// naechsten Wartenden
    private func acquireSlot() async {
        if inFlight < maxConcurrent { inFlight += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if waiting.isEmpty { inFlight -= 1 } else { waiting.removeFirst().resume() }
    }

    // MARK: Anfragen

    /// Pfad (mit oder ohne fuehrenden Schraegstrich) oder vollstaendiger Link aus `links.next`; nur der eigene Host.
    func url(_ pathOrLink: String) throws -> URL {
        var s = pathOrLink
        if !(s.hasPrefix("http://") || s.hasPrefix("https://")) {
            var b = base.absoluteString
            while b.hasSuffix("/") { b.removeLast() }
            s = b + (s.hasPrefix("/") ? "" : "/") + s
        }
        // eckige Klammern (page[limit]) sind in URLs nicht erlaubt; Stud.IP versteht die kodierte Form
        s = s.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
        guard let u = URL(string: s), u.host == base.host else { throw StudIPError.badResponse("fremde oder ungültige Adresse") }
        return u
    }

    /// Pfad ohne Kennungen fuer Fehlermeldungen (keine Kurs- oder Datei-IDs im Protokoll).
    static func scrub(_ path: String) -> String {
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return noQuery.replacingOccurrences(of: "[0-9a-f]{32}", with: ":id", options: .regularExpression)
    }

    private func send(_ pathOrLink: String, accept: String?, retry mode: RetryMode = .status) async throws -> HTTPReply {
        let transport = self.transport
        return try await perform(pathOrLink, retry: mode) { try await transport.get($0, accept: accept) }
    }

    /// Was `perform` wiederholt (Riesentest 03.11.2026, `UniRetry`: hoechstens 3 Versuche, 1,5 s und 3 s Pause):
    /// - `.status`: Listen und JSON mit 429 (zu viele Anfragen) oder 5xx, wie `api_get` am PC; Netzfehler nicht (sonst
    ///   wartete jeder weitere Kurs bis zum Zeitlimit)
    /// - `.transport`: Downloads bei abgerissener Verbindung oder Zeitueberschreitung wie `stream_download`; HTTP-Fehler
    ///   nicht ("aendern sich durch Wiederholen nicht")
    /// - `.none`: nichts (Lerntexte mit Anfragebudget, Seiten mit beliebigem Status)
    enum RetryMode { case status, transport, none }

    /// Eine Anfrage mit Pause und Anfragegrenze; abgelaufene Sitzung und HTTP-Fehler werden zu `StudIPError`. Mit
    /// `anyStatus` kommt jeder andere HTTP-Status zurueck (serverseitig gerenderte Seiten wie die Aufzeichnungen).
    /// 429 (zu viele Anfragen), 5xx und abgerissene Verbindungen werden wie beim Learnweb mit `UniRetry` wiederholt
    /// (hoechstens 3 Versuche, 1,5 s und 3 s Pause; jeder Versuch zaehlt zur Anfragegrenze). Vorher nur Downloads:
    /// ein einzelnes 429 auf eine Ordnerliste liess den ganzen Kurs fuer diesen Lauf aus (Riesentest 03.11.2026).
    func perform(_ pathOrLink: String, anyStatus: Bool = false, retry mode: RetryMode = .none,
                         _ call: (URL) async throws -> HTTPReply) async throws -> HTTPReply {
        var attempt = 0
        while true {
            await acquireSlot()
            let failure: Error
            do {
                defer { releaseSlot() }
                guard requestCount < maxRequests else { throw StudIPError.requestLimit }
                if requestCount > 0, pauseNanos > 0 { try await Task.sleep(nanoseconds: pauseNanos) }
                requestCount += 1
                do {
                    let reply = try await call(try url(pathOrLink))
                    if reply.status == 401 || Self.looksLikeLogin(reply) { throw StudIPError.sessionExpired }
                    if anyStatus || (200..<300).contains(reply.status) { return reply }
                    guard mode == .status else { throw StudIPError.http(status: reply.status, path: Self.scrub(pathOrLink)) }
                    failure = StudIPError.http(status: reply.status, path: Self.scrub(pathOrLink))
                } catch let e as URLError where mode == .transport {
                    failure = e
                }
            }
            attempt += 1
            guard attempt < max(1, retry.attempts), UniRetry.isTransient(failure), !Task.isCancelled else { throw failure }
            try? await Task.sleep(nanoseconds: retry.delayNanos(attempt))
            try Task.checkCancellation()
        }
    }

    /// Serverseitig gerenderte Stud.IP-Seite (z. B. Opencast-Aufzeichnungen) mit jedem HTTP-Status: das Plugin
    /// antwortet in Kursen ohne Aufzeichnungen mit 500, das ist dort kein Fehler. Eine Anmeldeseite statt der Seite
    /// heisst wie bei der JSON:API: Sitzung abgelaufen. Nur lesend, mit denselben Pausen wie die JSON:API.
    public func htmlPage(_ pathOrLink: String) async throws -> HTTPReply {
        let transport = self.transport
        let r = try await perform(pathOrLink, anyStatus: true) { try await transport.get($0, accept: "text/html") }
        if OpencastParser.looksLikeLoginPage(String(decoding: r.body.prefix(400_000), as: UTF8.self)) { throw StudIPError.sessionExpired }
        return r
    }

    /// JSON-Antwort eines Plugins mit jedem HTTP-Status (z. B. die Routen des Opencast-Plugins V3 unter
    /// `plugins.php/opencastv3/api/...`): ein Kurs ohne das Plugin antwortet mit 404 oder einer HTML-Seite, das ist kein
    /// Fehler und keine abgelaufene Sitzung. Nur die Weiterleitung auf die Anmeldung heisst "Sitzung abgelaufen".
    /// Der Aufrufer prueft Status und Inhaltstyp (`HTTPReply.isJSON`). Nur lesend, mit denselben Pausen wie die JSON:API.
    public func jsonPage(_ pathOrLink: String) async throws -> HTTPReply {
        let transport = self.transport
        return try await perform(pathOrLink, anyStatus: true) { try await transport.get($0, accept: "application/json, text/html;q=0.5") }
    }

    /// Abgelaufene Sitzung: Stud.IP leitet Seitenaufrufe auf die Anmeldung (bzw. die SSO-Seite) um.
    static func looksLikeLogin(_ r: HTTPReply) -> Bool {
        guard let u = r.finalURL else { return false }
        let p = u.path.lowercased()
        return p.contains("/dispatch.php/login") || p.contains("/idp/") || (u.host ?? "").hasPrefix("sso.")
    }

    /// Eine JSON:API-Antwort (nur GET); oeffentlich fuer Pruefungen auf dem Geraet (Geraete-Probe in den App-Tests)
    /// `retryTransient: false`: 429/5xx nicht wiederholen (Lerntexte: jede Anfrage zaehlt zum Budget, ein Fehler gilt wie am PC
    /// fuer diesen Teil, der naechste Abgleich fragt erneut)
    public func json(_ pathOrLink: String, retryTransient: Bool = true) async throws -> JSONValue {
        let r = try await send(pathOrLink, accept: Self.jsonAPI, retry: retryTransient ? .status : .none)
        if r.contentType.lowercased().contains("text/html") { throw StudIPError.sessionExpired }
        do { return try JSONValue.parse(r.body) } catch { throw StudIPError.badResponse("kein JSON (\(Self.scrub(pathOrLink)))") }
    }

    /// Alle Seiten einer Liste (JSON:API `links.next`); `included` wird mitgesammelt. Jede Seite braucht eine Liste
    /// `data` (JSON:API fuer Sammlungen): eine Antwort mit HTTP 200 ohne diese Liste ist kein leerer Bestand, sondern
    /// unbrauchbar. Sie gilt als Fehler wie eine gescheiterte Folgeseite, damit Aufrufer, die den Bestand ersetzen
    /// (Stundenplan, Dateien eines Kurses), das Gespeicherte stehen lassen.
    func list(_ path: String) async throws -> (data: [JSONValue], included: [JSONValue]) {
        var data: [JSONValue] = [], included: [JSONValue] = []
        var next: String? = path
        var seen = Set<String>()
        while let n = next, !seen.contains(n) {
            seen.insert(n)
            let j = try await json(n)
            guard let page = j["data"]?.array else { throw StudIPError.badResponse("Antwort ohne Liste (\(Self.scrub(n)))") }
            data += page
            included += j["included"]?.array ?? []
            next = j["links"]?["next"]?.string
        }
        return (data, included)
    }

    /// Eigener Kalender als iCalendar (users/{id}/events.ics, kein JSON:API): die Veranstaltungstermine, die Stud.IP
    /// dem Nutzer selbst zeigt (StudIPCalendar). Eine Anmeldeseite statt des Kalenders heisst wie bei der JSON:API:
    /// Sitzung abgelaufen; alles ohne VCALENDAR ist keine gueltige Antwort, ebenso ein abgeschnittener Kalender ohne
    /// END:VCALENDAR (sonst fehlten die restlichen Termine und ihre Kurszeiten galten als "nicht im Kalender").
    public func calendarICS(userID: String) async throws -> String {
        let path = "jsonapi.php/v1/users/\(userID)/events.ics"
        let r = try await send(path, accept: "text/calendar")
        if r.contentType.lowercased().contains("text/html") { throw StudIPError.sessionExpired }
        let text = String(decoding: r.body, as: UTF8.self)
        guard text.contains("BEGIN:VCALENDAR") else { throw StudIPError.badResponse("kein Kalender (\(Self.scrub(path)))") }
        guard text.contains("END:VCALENDAR") else { throw StudIPError.badResponse("Kalender unvollständig (\(Self.scrub(path)))") }
        return text
    }

    // MARK: Daten

    public func currentUserID() async throws -> String {
        guard let id = try await json("jsonapi.php/v1/users/me")["data"]?["id"]?.string else {
            throw StudIPError.badResponse("users/me ohne ID")
        }
        return id
    }

    /// Kursliste wie `fetch_courses`: mit Start- und Endsemester (`include=start-semester,end-semester`, seit c0721da).
    /// Endsemester: Titel und Ende des Semesters; Beziehung da, aber `data: null` heisst "unbegrenzt"; ohne Beziehung
    /// (aeltere Stud.IP-Fassung) bleibt beides nil und die Semesterregel nimmt den Titel des Startsemesters.
    public func courses(userID: String) async throws -> [StudIPCourse] {
        let (data, included) = try await list("jsonapi.php/v1/users/\(userID)/courses?page[limit]=100&include=start-semester,end-semester")
        var semesters: [String: [String: JSONValue]] = [:]
        for i in included where i["type"]?.string == "semesters" {
            if let id = i["id"]?.string { semesters[id] = i["attributes"]?.object ?? [:] }
        }
        return data.compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            let a = c["attributes"]
            let semID = c["relationships"]?["start-semester"]?["data"]?["id"]?.string
            let title = (a?["title"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let number = a?["course-number"]?.string?.trimmingCharacters(in: .whitespaces)
            // Ende: Semester-ID, ausdruecklich keines (unbegrenzt) oder unbekannt; ein Semester ohne Attribute zaehlt
            // wie in Python als unbekannt (`if end` auf ein leeres dict)
            let endRel = c["relationships"]?["end-semester"]?.object
            let endID = endRel?["data"]?["id"]?.string
            let end = endID.flatMap { semesters[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            let semesterEnd: String?
            if let end {
                semesterEnd = end["title"] == nil ? "" : end["title"]?.string      // end.get("title", ""): null bleibt None
            } else if let endRel, !endRel.isEmpty, endRel["data"] == nil || endRel["data"] == .null {
                semesterEnd = "unbegrenzt"
            } else {
                semesterEnd = nil
            }
            return StudIPCourse(id: id, title: title.isEmpty ? "Kurs" : title, number: (number?.isEmpty ?? true) ? nil : number,
                                semesterTitle: semID.flatMap { semesters[$0]?["title"]?.string }, semesterStart: semID.flatMap { semesters[$0]?["start"]?.string },
                                semesterEnd: semesterEnd, semesterEndsAt: end?["end"]?.string,
                                description: StudIPText.field(a, "description"), miscellaneous: StudIPText.field(a, "miscellaneous"),
                                courseType: StudIPSchedule.integer(a?["course-type"]))
        }
    }

    /// Tiefste gelesene Ordnerebene unter dem Wurzelordner (Wurzel = 0). Bis 03.11.2026 waren es 6: im Riesentest
    /// (docs/RIESENTEST-2026-11-03.md) fehlten Dateien tiefer als 6 Ebenen auf dem iPad. Gleicher Wert wie
    /// `MAX_FOLDER_DEPTH` in app/studip_sync.py; Schleifen faengt `seen` ab, die Grenze schuetzt nur vor Entartung.
    public static let maxFolderDepth = 12

    /// Alle Dateien eines Kurses ueber den Ordnerbaum (Wurzelordner -> Unterordner, hoechstens `maxFolderDepth` Ebenen tief).
    public func files(courseID: String) async throws -> [StudIPFile] {
        try await fileListing(courseID: courseID).files
    }

    /// Dateien eines Kurses ueber den Ordnerbaum, alle Seiten (`links.next`). Ein Unterordner, den Stud.IP mit 403 oder
    /// 404 ablehnt (z. B. nur fuer Lehrende), wird uebersprungen und gezaehlt; der Rest des Kurses wird weiter gelesen
    /// (wie `if fr.ok` in fetch_folder_paths). Wurzelordner, abgelaufene Sitzung, Netz und andere Fehler wie bisher.
    /// `mode` (07.11.2026): `.walk` liest den Baum (je Ordner Dateien und Unterordner) und vergleicht ihn mit der flachen
    /// Ordnerliste; `.flat` nimmt die Ordner aus der flachen Liste und fragt je Ordner nur die Dateien. Beide lesen bei
    /// jedem Lauf die Dateiliste jedes Ordners (neue, geaenderte und entfernte Dateien fallen also immer auf); nur die
    /// Unterordner-Abfragen entfallen. Die Ordner einer Ebene laufen gleichzeitig (Grenze `maxConcurrent`).
    public func fileListing(courseID: String, mode: StudIPFolderMode = .walk) async throws -> StudIPFileListing {
        let (tops, _) = try await list("jsonapi.php/v1/courses/\(courseID)/folders?page[limit]=200")
        let flat = FlatFolders(tops)
        if mode == .flat, let flat {
            var out = try await readLevels(courseID: courseID, roots: flat.roots.map { ($0, "") }) { id in flat.children[id, default: []] }
            out.usedFlatList = true
            return out
        }
        let roots = tops.filter { $0["attributes"]?["folder-type"]?.string == "RootFolder" }
        let rootIDs = (roots.isEmpty ? Array(tops.prefix(1)) : roots).compactMap { $0["id"]?.string }
        // Baum: je gelesenem Ordner die Unterordner (in derselben Ebene gleichzeitig); gemerkt fuer den Vergleich
        var subLists: [String: [String]] = [:]
        var out = try await readLevels(courseID: courseID, roots: rootIDs.map { ($0, "") }, subfolders: { [self] id in
            try await self.subfolders(id)
        }, record: { subLists[$0] = $1.map(\.id) })
        out.folderCheck = flat?.check(roots: rootIDs, subLists: subLists) ?? (subLists.values.contains { !$0.isEmpty } ? .mismatch : .inconclusive)
        return out
    }

    /// Ordner, den Stud.IP nicht zeigt: 403 (keine Berechtigung) oder 404 (entfernt, versteckt)
    static func isUnreadableFolder(_ error: Error) -> Bool {
        if case StudIPError.http(let status, _)? = error as? StudIPError { return status == 403 || status == 404 }
        return false
    }

    /// Ordner aus der flachen Liste `courses/{id}/folders`: Wurzeln (`RootFolder`) und Kinder je Elternordner (Beziehung
    /// `parent`), in der Reihenfolge der Liste. nil, wenn die Liste keinen Baum ergibt (keine Wurzel, ein Ordner ohne
    /// Elternordner oder mit einem, der nicht in der Liste steht): dann liest der Kurs den Baum.
    struct FlatFolders {
        var roots: [String] = []
        var children: [String: [(id: String, name: String)]] = [:]
        var parent: [String: String] = [:]

        init?(_ folders: [JSONValue]) {
            var ids = Set<String>()
            var items: [(id: String, name: String, parent: String?, root: Bool)] = []
            for f in folders {
                guard let id = f["id"]?.string else { return nil }
                let root = f["attributes"]?["folder-type"]?.string == "RootFolder"
                let p = f["relationships"]?["parent"]?["data"]?["id"]?.string
                guard root || p != nil else { return nil }
                ids.insert(id)
                items.append((id, (f["attributes"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespaces), p, root))
            }
            for i in items {
                if i.root { roots.append(i.id); continue }
                guard let p = i.parent, ids.contains(p) else { return nil }
                parent[i.id] = p
                children[p, default: []].append((i.id, i.name))
            }
            guard !roots.isEmpty else { return nil }
        }

        /// Stimmt der gelesene Baum mit der flachen Liste ueberein? Jede Unterordnerliste des Baums muss genau die
        /// Kinder der flachen Liste haben (gleiche Kennungen), die Wurzeln muessen dieselben sein
        func check(roots walkedRoots: [String], subLists: [String: [String]]) -> StudIPFolderCheck {
            guard Set(walkedRoots) == Set(roots) else { return .mismatch }
            for (folder, subs) in subLists where Set(subs) != Set(children[folder, default: []].map(\.id)) { return .mismatch }
            return subLists.values.contains { !$0.isEmpty } ? .confirmed : .inconclusive
        }
    }

    /// Unterordner eines Ordners (Kennung, Name)
    private func subfolders(_ folderID: String) async throws -> [(id: String, name: String)] {
        try await list("jsonapi.php/v1/folders/\(folderID)/folders?page[limit]=200").data.compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return (id, (s["attributes"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespaces))
        }
    }

    /// Dateien je Ordner, Ebene fuer Ebene (Ebene gleichzeitig, Ergebnis in Ordnerreihenfolge). `subfolders`: Kinder eines
    /// gelesenen Ordners (Baum: Anfrage; flach: aus der Liste). Ordner tiefer als `maxFolderDepth` und schon gesehene
    /// (Schleifen) nicht. 403/404 unterhalb der Wurzel: Ordner gezaehlt, weder Dateien noch Unterordner; ist nur die
    /// Unterordnerliste gesperrt, bleiben die Dateien.
    private func readLevels(courseID: String, roots: [(String, String)],
                            subfolders: @escaping @Sendable (String) async throws -> [(id: String, name: String)],
                            record: (String, [(id: String, name: String)]) -> Void = { _, _ in }) async throws -> StudIPFileListing {
        var out = StudIPFileListing()
        var seen = Set<String>()
        var level = roots.filter { seen.insert($0.0).inserted }
        var depth = 0
        while !level.isEmpty, depth <= Self.maxFolderDepth {
            let d = depth
            let results = try await withThrowingTaskGroup(of: (Int, FolderRead).self) { group in
                for (i, f) in level.enumerated() {
                    group.addTask { (i, try await self.readFolder(f.0, path: f.1, depth: d, courseID: courseID, subfolders: subfolders)) }
                }
                var r = [FolderRead?](repeating: nil, count: level.count)
                for try await (i, x) in group { r[i] = x }
                return r.compactMap { $0 }
            }
            var next: [(String, String)] = []
            for (f, r) in zip(level, results) {
                out.files += r.files
                out.unreadableFolders += r.unreadable
                guard let subs = r.subs else { continue }
                record(f.0, subs)
                for s in subs where seen.insert(s.id).inserted {
                    next.append((s.id, f.1.isEmpty ? s.name : "\(f.1)/\(s.name)"))
                }
            }
            level = next
            depth += 1
        }
        return out
    }

    /// Ein gelesener Ordner: Dateien, Unterordner (nil: nicht gelesen) und gezaehlte gesperrte Ordner
    private struct FolderRead: Sendable {
        var files: [StudIPFile] = []
        var subs: [(id: String, name: String)]?
        var unreadable = 0
    }

    private func readFolder(_ folderID: String, path: String, depth: Int, courseID: String,
                            subfolders: @Sendable (String) async throws -> [(id: String, name: String)]) async throws -> FolderRead {
        var out = FolderRead()
        let refs: [JSONValue]
        do {
            refs = try await list("jsonapi.php/v1/folders/\(folderID)/file-refs?page[limit]=500").data
        } catch where depth > 0 && Self.isUnreadableFolder(error) {
            out.unreadable = 1                            // Ordner gesperrt: weder Dateien noch Unterordner
            return out
        }
        for r in refs {
            guard let id = r["id"]?.string else { continue }
            let a = r["attributes"]
            let changed = a?["chdate"]?.string ?? a?["chdate"]?.double.map { JSONValue.format($0) } ?? ""
            let downloadable = a?["is-downloadable"]?.bool ?? true
            out.files.append(StudIPFile(id: id, courseID: courseID, name: a?["name"]?.string ?? id, size: a?["filesize"]?.int ?? 0,
                                        mimeType: a?["mime-type"]?.string, changed: changed, isDownloadable: downloadable,
                                        folderPath: path, linkURL: downloadable ? nil : StudIPFile.linkURL(r)))
        }
        guard depth < Self.maxFolderDepth else { return out }     // tiefere Ordner liest der Abgleich nicht
        do {
            out.subs = try await subfolders(folderID)
        } catch where depth > 0 && Self.isUnreadableFolder(error) {
            out.unreadable = 1                            // Dateien gelesen, Unterordner nicht
        }
        return out
    }

    /// Inhalt einer Datei direkt nach `file` (grosse Dateien nicht im Arbeitsspeicher), wie `stream_download` in
    /// app/studip_sync.py: eine abgerissene Verbindung oder Zeitueberschreitung wird bis zu zweimal wiederholt
    /// (`UniRetry`), HTTP-Fehler nicht. Liefert Stud.IP statt der Datei eine HTML-Anmeldeseite, ist die Sitzung
    /// abgelaufen; eine andere Webseite statt der Datei `name` (`UniStore.isWebPage`) betrifft nur diese Datei. Bei
    /// jedem Fehler bleibt keine halbe Datei liegen.
    public func download(fileID: String, to file: URL, name: String = "") async throws {
        let transport = self.transport
        let path = "jsonapi.php/v1/file-refs/\(fileID)/content"
        do {
            let r = try await perform(path, retry: .transport) { try await transport.download($0, to: file) }
            // eine echte HTML-Datei (.html/.htm) mit "login" im Text ist keine Anmeldeseite: sonst brach jeder Abgleich
            // an ihr mit "Erneut anmelden" ab (die Anmeldeseite selbst erkennt `perform` an 401 bzw. der Weiterleitung)
            if !Self.isHTMLFileName(name), r.contentType.lowercased().contains("text/html"),
               Self.head(of: file).lowercased().contains("login") {
                throw StudIPError.sessionExpired
            }
            if UniStore.isWebPage(file: file, name: name) {
                throw StudIPError.badResponse("Statt der Datei kam eine Webseite zurück (Anmeldung abgelaufen?): \(Self.scrub(path))")
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Dateiname einer Webseite (dieselbe Regel wie `UniStore.isWebPage`)
    static func isHTMLFileName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".html") || n.hasSuffix(".htm")
    }

    /// Anfang einer Datei als Text (Erkennen der Anmeldeseite, ohne die ganze Datei zu lesen)
    static func head(of file: URL, bytes: Int = 4000) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }
}

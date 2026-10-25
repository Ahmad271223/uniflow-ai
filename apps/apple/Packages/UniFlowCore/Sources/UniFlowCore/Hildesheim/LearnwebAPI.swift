import Foundation

extension Learnweb {
    public struct Course: Sendable, Equatable {
        /// "lw-<moodle-id>" wie am PC
        public let id: String
        public let moodleID: Int
        public let title: String
        public let number: String?
        public let semester: String
        public let hidden: Bool
    }

    static func course(_ c: JSONValue) -> Course? {
        guard let mid = c["id"]?.int else { return nil }
        let p = parseCourseTitle(c["fullname"]?.string ?? c["displayname"]?.string ?? "")
        return Course(id: "lw-\(mid)", moodleID: mid, title: p.title, number: p.number, semester: p.semester,
                      hidden: c["hidden"]?.bool ?? ((c["hidden"]?.int ?? 0) != 0))
    }
}

/// Learnweb lesen: mit Schluessel (REST, bevorzugt) oder mit der angemeldeten Sitzung (AJAX mit sesskey).
/// Uebertragen aus `app/learnweb.py` (TokenClient, SessionClient).
public actor LearnwebAPI {
    public enum Mode: Sendable, Equatable {
        case token(String)
        /// Cookies der CAS-/Moodle-Sitzung setzt der Transport der App
        case session
    }

    public let base: String
    public let mode: Mode
    private let transport: UniTransport
    private let retry: UniRetry
    private var sesskey: String?

    private static let sesskeyRE = HText.regex("\"sesskey\":\"([A-Za-z0-9]+)\"")
    private static let embeddedRE = HText.regex("(https?://[^\"'<>\\s]+/pluginfile\\.php/\\d+/mod_resource/content/\\d+/[^\"'<>\\s]+)")

    public init(base: String, mode: Mode, transport: UniTransport, retry: UniRetry = UniRetry()) {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.mode = mode
        self.transport = transport
        self.retry = retry
    }

    // MARK: Oeffentlich

    public func courses() async throws -> [Learnweb.Course] {
        switch mode {
        case .token:
            let site = try await rest("core_webservice_get_site_info", [:])
            guard let uid = site["userid"]?.int else { throw HildesheimError.badResponse("keine userid") }
            return (try await rest("core_enrol_get_users_courses", ["userid": String(uid)]).array ?? []).compactMap(Learnweb.course)
        case .session:
            let data = try await ajax("core_course_get_enrolled_courses_by_timeline_classification",
                                      .object(["classification": .string("all"), "limit": .number(0), "offset": .number(0),
                                               "sort": .string("fullname")]))
            return (data["courses"]?.array ?? []).compactMap(Learnweb.course)
        }
    }

    public func files(moodleID: Int) async throws -> [Learnweb.File] {
        switch mode {
        case .token:
            return Learnweb.filesFromContents(try await rest("core_course_get_contents", ["courseid": String(moodleID)]))
        case .session:
            let data = try await ajax("core_courseformat_get_state", .object(["courseid": .number(Double(moodleID))]))
            guard let text = data.string, let state = try? JSONValue.parse(text) else {
                throw HildesheimError.badResponse("core_courseformat_get_state")
            }
            // Links vorab laden (Netz), dann rein rechnen
            var links: [String: [String]] = [:]
            for cm in state["cm"]?.array ?? [] {
                let module = cm["module"]?.string ?? ""
                guard module == "resource" || module == "folder", cm["uservisible"]?.bool != false else { continue }
                let cmid = cm["id"].map(Learnweb.idString) ?? ""
                links[cmid] = module == "resource" ? try await resourceLink(cmid) : try await folderLinks(cmid)
            }
            return Learnweb.filesFromState(state, resourceLinks: { links[$0] ?? [] }, folderLinks: { links[$0] ?? [] })
        }
    }

    /// Anfrage fuer den Download einer Datei (Token erst hier anhaengen, nie speichern)
    public func downloadRequest(_ f: Learnweb.File) -> UniRequest? {
        let urlString: String
        if case .token(let t) = mode { urlString = Learnweb.withToken(f.downloadURL, token: t) } else { urlString = f.downloadURL }
        return URL(string: urlString).map { UniRequest(url: $0) }
    }

    // MARK: REST

    private func rest(_ function: String, _ params: [String: String]) async throws -> JSONValue {
        guard case .token(let token) = mode, let url = URL(string: "\(base)/webservice/rest/server.php") else {
            throw HildesheimError.badResponse("REST ohne Schluessel")
        }
        var form = ["wstoken": token, "wsfunction": function, "moodlewsrestformat": "json"]
        for (k, v) in params { form[k] = v }
        let body = form.sorted { $0.key < $1.key }.map { "\(HText.quoteAll($0.key))=\(HText.quoteAll($0.value))" }.joined(separator: "&")
        let r = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
        let resp = try await transport.fetch(r, retry: retry)
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: "\(base)/webservice/rest/server.php") }
        guard let j = try? JSONValue.parse(resp.body) else { throw HildesheimError.badResponse(function) }
        if let ex = j["exception"]?.string, !ex.isEmpty {
            let code = j["errorcode"]?.string ?? ""
            if ["invalidtoken", "accessexception"].contains(code) { throw HildesheimError.invalidToken }
            throw HildesheimError.badResponse("\(function): \(code)")
        }
        return j
    }

    // MARK: Sitzung

    private func isLogin(_ resp: UniResponse) -> Bool {
        let u = resp.finalURL?.absoluteString ?? ""
        return HildesheimCAS.isCASPage(u) || u.contains("/login/index.php")
    }

    private func currentSesskey() async throws -> String {
        if let s = sesskey { return s }
        guard let url = URL(string: "\(base)/my/courses.php") else { throw HildesheimError.badResponse(base) }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if isLogin(resp) { throw HildesheimError.sessionExpired("Learnweb") }
        guard let key = HText.match(Self.sesskeyRE, resp.text)?.groups[1] ?? nil else { throw HildesheimError.sessionExpired("Learnweb") }
        sesskey = key
        return key
    }

    private func ajax(_ function: String, _ args: JSONValue) async throws -> JSONValue {
        let key = try await currentSesskey()
        guard let url = URL(string: "\(base)/lib/ajax/service.php?sesskey=\(key)&info=\(function)") else { throw HildesheimError.badResponse(function) }
        let payload = JSONValue.array([.object(["index": .number(0), "methodname": .string(function), "args": args])])
        let r = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: payload.serialized())
        let resp = try await transport.fetch(r, retry: retry)
        if isLogin(resp) { throw HildesheimError.sessionExpired("Learnweb") }
        guard resp.status == 200, let first = (try? JSONValue.parse(resp.body))?.array?.first else {
            throw HildesheimError.badResponse(function)
        }
        if first["error"]?.bool == true {
            let code = first["exception"]?["errorcode"]?.string ?? ""
            if ["invalidsesskey", "servicerequireslogin", "requireloginerror"].contains(code) {
                sesskey = nil
                throw HildesheimError.sessionExpired("Learnweb")
            }
            throw HildesheimError.badResponse("\(function): \(code)")
        }
        return first["data"] ?? .null
    }

    private func resourceLink(_ cmid: String) async throws -> [String] {
        guard let url = URL(string: "\(base)/mod/resource/view.php?id=\(cmid)&redirect=1") else { return [] }
        let resp = try await transport.fetch(UniRequest(url: url, followRedirects: false), retry: retry)
        if let loc = resp.headers["location"], loc.contains("pluginfile.php") {
            return [URL(string: loc, relativeTo: URL(string: base + "/"))?.absoluteString ?? loc]
        }
        if let loc = resp.headers["location"], HildesheimCAS.isCASPage(loc) || loc.contains("/login/index.php") {
            throw HildesheimError.sessionExpired("Learnweb")
        }
        // Anzeigeart "eingebettet": Link steht in der Seite
        guard resp.status == 200, let m = HText.match(Self.embeddedRE, resp.text)?.groups[1] ?? nil else { return [] }
        return [m.replacingOccurrences(of: "&amp;", with: "&")]
    }

    private func folderLinks(_ cmid: String) async throws -> [String] {
        guard let url = URL(string: "\(base)/mod/folder/view.php?id=\(cmid)") else { return [] }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if isLogin(resp) { throw HildesheimError.sessionExpired("Learnweb") }
        return resp.status == 200 ? Learnweb.folderLinks(html: resp.text) : []
    }
}

extension Learnweb {
    /// Name einer Moodle-Instanz ueber die oeffentliche Schnittstelle (ohne Anmeldung); nil, wenn es sie nicht gibt.
    public static func publicSitename(base: String, transport: UniTransport) async -> String? {
        guard let url = URL(string: "\(base)/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config") else { return nil }
        let body = JSONValue.array([.object(["index": .number(0), "methodname": .string("tool_mobile_get_public_config"), "args": .object([:])])])
        guard let resp = try? await transport.send(UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: body.serialized())),
              resp.status == 200, let first = (try? JSONValue.parse(resp.body))?.array?.first, first["error"]?.bool != true else { return nil }
        return first["data"]?["sitename"]?.string ?? ""
    }

    /// Learnweb-Instanz des aktuellen Semesters ueber das Netz ermitteln (Vorjahr, aktuelles, naechstes Jahr).
    public static func discoverBase(year: Int, month: Int, override: String? = nil, transport: UniTransport) async -> String? {
        if let o = override, !o.isEmpty { return discoverBase(year: year, month: month, override: o) { _ in nil } }
        var names: [String: String] = [:]
        for y in [year + 1, year, year - 1] {
            let b = "\(root)/learnweb\(y)"
            if let n = await publicSitename(base: b, transport: transport) { names[b] = n }
        }
        return discoverBase(year: year, month: month) { names[$0] }
    }
}

/// LSF der Uni Hildesheim mit der angemeldeten Sitzung (Cookies setzt der Transport): Stundenplan und Notenspiegel.
/// Nur lesend: nie "Anmelden/abmelden", "Jetzt anmelden" oder Pruefungsanmeldung aufrufen.
public actor LSFClient {
    public static let startURL = "\(HildesheimCAS.lsfBase)/qisserver/rds?state=user&type=0"
    public static let planURL = "\(HildesheimCAS.lsfBase)/qisserver/rds?state=wplan&act=show&show=plan&P.subc=plan&week=-2"

    private let transport: UniTransport
    private let retry: UniRetry

    public init(transport: UniTransport, retry: UniRetry = UniRetry()) {
        self.transport = transport
        self.retry = retry
    }

    private func page(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw HildesheimError.badResponse(urlString) }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("LSF") }
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: urlString) }
        let html = resp.text
        // angemeldet nur mit "Abmelden"-Link
        if !html.contains("Abmelden") { throw HildesheimError.sessionExpired("LSF") }
        return html
    }

    /// Serien des persoenlichen Stundenplans; nil, wenn der Plan leer ist (kein Export-Link)
    public func planEntries() async throws -> [LSFCalendar.Entry]? {
        let html = try await page(Self.planURL)
        guard let link = LSFCalendar.planICSLink(html: html), let url = URL(string: link) else { return nil }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        let ics = resp.text
        guard resp.status == 200, ics.contains("BEGIN:VCALENDAR") else { throw HildesheimError.badResponse("LSF-iCal") }
        return LSFCalendar.planEntries(ics)
    }

    /// Leistungen aus dem Notenspiegel (alle Studiengaenge). Stammdaten-Tabellen werden nie gelesen.
    public func grades() async throws -> [GradeRows.Grade] {
        let start = try await page(Self.startURL)
        guard let link = HTMLScanner.scan(start).anchors.first(where: { $0.label.contains("Notenspiegel") }) else {
            throw HildesheimError.badResponse("Link zum Notenspiegel fehlt")
        }
        let first = absolute(link.href)
        var pages = [first], seen = Set([first]), out: [GradeRows.Grade] = []
        var i = 0
        while i < pages.count && i < 6 {
            let html = try await page(pages[i])
            let scan = HTMLScanner.scan(html)
            for table in scan.tables where !QISParser.isStammdaten(table) {
                out += GradeRows.parse(rows: table.rows.map { $0.map(\.text) }, abschluss: "")
            }
            if i == 0 {      // Reiter der Studiengaenge auf der ersten Seite
                for a in scan.anchors where a.href.contains("notenspiegelStudent") && a.href.contains("nodeID=") {
                    let u = absolute(a.href)
                    if seen.insert(u).inserted { pages.append(u) }
                }
            }
            i += 1
        }
        var keys = Set<String>()
        return out.filter { g in
            keys.insert([g["pruefungsnr"], g["text"], g["semester"], g["versuch"]].map { $0 ?? "" }.joined(separator: "|")).inserted
        }
    }

    private func absolute(_ href: String) -> String {
        let h = href.replacingOccurrences(of: "&amp;", with: "&")
        if h.hasPrefix("http") { return h }
        return "\(HildesheimCAS.lsfBase)/qisserver/" + String(h.drop(while: { $0 == "/" }))
    }
}

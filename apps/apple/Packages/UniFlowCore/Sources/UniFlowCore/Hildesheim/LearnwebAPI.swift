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

    /// `learnweb._course`: Kennung als Zahl oder Text (`int(c["id"])`), Titel aus fullname, sonst displayname,
    /// versteckt wie `bool(c.get("hidden"))`
    static func course(_ c: JSONValue) -> Course? {
        guard let mid = c["id"]?.int ?? c["id"]?.string.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let full = [c["fullname"]?.string, c["displayname"]?.string].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let p = parseCourseTitle(full)
        return Course(id: "lw-\(mid)", moodleID: mid, title: p.title, number: p.number, semester: p.semester,
                      hidden: LocalModules.truthy(c["hidden"]))
    }
}

/// Learnweb-Schluessel ("Moodle mobile web service", aus dem Moodle-SSO oder selbst erzeugt). In Beschreibungen
/// geschwaerzt und nicht Codable: die App legt ihn nur im Schluesselbund ab (`keychainValue`), nie in Adressen,
/// Meldungen oder Protokollen. Moodle-Schluessel sind alphanumerisch (PARAM_ALPHANUM); alles andere wird abgelehnt.
public struct LearnwebToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String
    /// privater Schluessel aus dem SSO (nur ueber HTTPS); wird hier nicht verwendet
    let privateToken: String?

    public init?(_ token: String, privateToken: String? = nil) {
        guard Self.isAlnum(token, 1...256) else { return nil }
        self.token = token
        self.privateToken = privateToken.flatMap { Self.isAlnum($0, 1...256) ? $0 : nil }
    }

    static func isAlnum(_ s: String, _ len: ClosedRange<Int>) -> Bool {
        len.contains(s.utf8.count) && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    /// Nur zum Ablegen im Schluesselbund der App
    public var keychainValue: String { token }

    public var description: String { "LearnwebToken(***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension Learnweb {
    private static let sesskeyRE = HText.regex(#""sesskey"\s*:\s*"([A-Za-z0-9]+)""#)
    private static let bodyClassRE = HText.regex(#"<body\b[^>]*\bclass\s*=\s*["']([^"']*)["']"#, [.caseInsensitive])

    /// Angemeldet wie LOGGED_IN_JS am PC: sesskey vorhanden und `<body>` ohne Klasse "notloggedin" (auch die
    /// Anmeldeseite von Moodle hat einen sesskey).
    public static func isLoggedIn(html: String) -> Bool {
        guard html.contains("sesskey") else { return false }
        if let cls = HText.match(bodyClassRE, html)?.groups[1] ?? nil, cls.split(separator: " ").contains("notloggedin") { return false }
        return true
    }

    /// sesskey (M.cfg) einer angemeldeten Moodle-Seite; nil auf der Anmeldeseite oder ohne gueltigen Schluessel
    public static func sesskey(fromPage html: String) -> String? {
        guard isLoggedIn(html: html), let k = HText.match(sesskeyRE, html)?.groups[1] ?? nil, LearnwebToken.isAlnum(k, 1...64) else {
            return nil
        }
        return k
    }

    /// webservice/pluginfile.php meldet Fehler als kleines JSON (`{"error": ..., "errorcode": "invalidtoken"}`) statt
    /// der Datei: nie speichern. Ungueltiger Schluessel = neu anmelden. Echte .json-Dateien bleiben erlaubt.
    static func downloadError(file: URL, name: String) -> HildesheimError? {
        guard !name.lowercased().hasSuffix(".json"),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue, size < 4096,
              let data = FileManager.default.contents(atPath: file.path), data.first == UInt8(ascii: "{"),
              let j = try? JSONValue.parse(data), let code = j["errorcode"]?.string else { return nil }
        return code == "invalidtoken" ? .invalidToken : .badResponse("pluginfile: \(code)")
    }
}

/// Learnweb lesen: mit Schluessel (REST, bevorzugt) oder mit der angemeldeten Sitzung (AJAX mit sesskey).
/// Uebertragen aus `app/learnweb.py` (TokenClient, SessionClient). Der Schluessel steht nie in einer Adresse und nie
/// in einer Meldung: REST und Downloads schicken ihn im Formular-Koerper (POST), erst beim Abruf.
public actor LearnwebAPI {
    public enum Mode: Sendable, Equatable {
        case token(LearnwebToken)
        /// Cookies der CAS-/Moodle-Sitzung setzt der Transport der App
        case session
    }

    public let base: String
    public let mode: Mode
    private let transport: UniTransport
    private let retry: UniRetry
    private var sesskey: String?

    private static let embeddedRE = HText.regex(#"(https?://[^"'<>\s]+/pluginfile\.php/\d+/mod_resource/content/\d+/[^"'<>\s]+)"#)

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

    /// Anfrage fuer den Download einer Datei, nur an den eigenen Rechner ueber HTTPS. Mit Schluessel: POST an die
    /// Pluginfile-Adresse mit `token` im Koerper (am PC `with_token` an der Adresse; hier nie in Adressen. Gegen das
    /// echte Learnweb ungeprueft; Moodle liest den Parameter aus POST und GET); mit Sitzung: GET mit den Cookies.
    public func downloadRequest(_ f: Learnweb.File) throws -> UniRequest {
        guard let url = URL(string: f.downloadURL), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == URL(string: base)?.host?.lowercased() else {
            throw HildesheimError.badResponse("fremde oder ungültige Adresse")
        }
        guard case .token(let t) = mode else { return UniRequest(url: url) }
        return UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                          body: HText.form([("token", t.token)]))
    }

    // MARK: REST

    private func rest(_ function: String, _ params: [String: String]) async throws -> JSONValue {
        guard case .token(let token) = mode, let url = URL(string: "\(base)/webservice/rest/server.php") else {
            throw HildesheimError.badResponse("REST ohne Schluessel")
        }
        var form = ["wstoken": token.token, "wsfunction": function, "moodlewsrestformat": "json"]
        for (k, v) in params { form[k] = v }
        let r = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                           body: HText.form(form.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        let resp = try await transport.fetch(r, retry: retry)
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: "\(base)/webservice/rest/server.php") }
        guard let j = try? JSONValue.parse(resp.body) else { throw HildesheimError.badResponse(function) }
        // Fehlertexte von Moodle koennen Eingaben enthalten: nur Funktion und Fehlercode weitergeben
        if j["exception"] != nil || j["errorcode"]?.string != nil {
            let code = j["errorcode"]?.string ?? ""
            if ["invalidtoken", "accessexception"].contains(code) { throw HildesheimError.invalidToken }
            throw HildesheimError.badResponse("\(function): \(code)")
        }
        return j
    }

    // MARK: Sitzung

    private func isLogin(_ url: String) -> Bool {
        HildesheimCAS.isCASPage(url) || url.contains("/login/index.php")
    }

    private func currentSesskey() async throws -> String {
        if let s = sesskey { return s }
        guard let url = URL(string: "\(base)/my/courses.php") else { throw HildesheimError.badResponse(base) }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if isLogin(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        guard let key = Learnweb.sesskey(fromPage: resp.text) else { throw HildesheimError.sessionExpired("Learnweb") }
        sesskey = key
        return key
    }

    private func ajax(_ function: String, _ args: JSONValue) async throws -> JSONValue {
        let key = try await currentSesskey()
        guard let url = URL(string: "\(base)/lib/ajax/service.php?sesskey=\(key)&info=\(function)") else {
            throw HildesheimError.badResponse(function)
        }
        let payload = JSONValue.array([.object(["index": .number(0), "methodname": .string(function), "args": args])])
        let r = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: payload.serialized())
        let resp = try await transport.fetch(r, retry: retry)
        if isLogin(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        guard resp.status == 200, let first = (try? JSONValue.parse(resp.body))?.array?.first else {
            // Webseite statt JSON: Sitzung beendet (Anmeldeseite)
            if resp.status == 200, UniStore.startsLikeWebPage(resp.body) {
                sesskey = nil
                throw HildesheimError.sessionExpired("Learnweb")
            }
            throw HildesheimError.badResponse(function)
        }
        if first["error"]?.bool == true || first["exception"] != nil {
            let code = first["exception"]?["errorcode"]?.string ?? ""
            if ["invalidsesskey", "servicerequireslogin", "requireloginerror", "sessionexpired"].contains(code) {
                sesskey = nil
                throw HildesheimError.sessionExpired("Learnweb")
            }
            throw HildesheimError.badResponse("\(function): \(code)")
        }
        return first["data"] ?? .null
    }

    /// cmid steht in der Adresse: nur Ziffern
    private static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (0x30...0x39).contains($0) } }

    private func resourceLink(_ cmid: String) async throws -> [String] {
        guard Self.isDigits(cmid), let url = URL(string: "\(base)/mod/resource/view.php?id=\(cmid)&redirect=1") else { return [] }
        let resp = try await transport.fetch(UniRequest(url: url, followRedirects: false), retry: retry)
        if isLogin(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        if let loc = resp.headers["location"] {
            let abs = URL(string: loc, relativeTo: URL(string: base + "/"))?.absoluteString ?? loc
            if isLogin(abs) { throw HildesheimError.sessionExpired("Learnweb") }
            if loc.contains("pluginfile.php") { return [abs] }
        }
        // Anzeigeart "eingebettet": Link steht in der Seite; 403/404 (nicht sichtbar) wie am PC eine leere Liste
        guard resp.status == 200, let m = HText.match(Self.embeddedRE, resp.text)?.groups[1] ?? nil else { return [] }
        return [m.replacingOccurrences(of: "&amp;", with: "&")]
    }

    private func folderLinks(_ cmid: String) async throws -> [String] {
        guard Self.isDigits(cmid), let url = URL(string: "\(base)/mod/folder/view.php?id=\(cmid)") else { return [] }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if isLogin(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        return resp.status == 200 ? Learnweb.folderLinks(html: resp.text) : []
    }
}

extension Learnweb {
    /// Name einer Moodle-Instanz ueber die oeffentliche Schnittstelle (`tool_mobile_get_public_config` ohne Anmeldung,
    /// dieselbe Abfrage wie fuer das Moodle-SSO); nil, wenn es sie nicht gibt. Ein Versuch je Instanz.
    public static func publicSitename(base: String, transport: UniTransport) async -> String? {
        guard let config = try? await MoodleSSO.publicConfig(base: base, transport: transport, retry: .none) else { return nil }
        return config.siteName ?? ""
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
    public static let startURL = UniversityProfile.hildesheimLSFStart.absoluteString
    public static let planURL = "\(HildesheimCAS.lsfBase)/qisserver/rds?state=wplan&act=show&show=plan&P.subc=plan&week=-2"

    private let transport: UniTransport
    private let retry: UniRetry

    public init(transport: UniTransport, retry: UniRetry = UniRetry()) {
        self.transport = transport
        self.retry = retry
    }

    /// Rechner des LSF (aus dem Hochschul-Profil)
    static let host = UniversityProfile.hildesheimLSF.host?.lowercased() ?? "lsf.uni-hildesheim.de"

    /// Angemeldet im LSF wie `lsf.is_logged_in` am PC: eine Seite des LSF (HTTPS, Rechner des Profils) mit
    /// "Abmelden"-Link. Die eine Regel fuer die Anmeldung in der App (`HildesheimLogin`) und jede hier gelesene Seite.
    /// Wie Playwright `a:has-text('Abmelden')` ohne Gross-/Kleinschreibung; zusaetzlich der Abmelde-Link des LSF
    /// (`category=auth.logout`), den die abgemeldete Seite nie hat (dort nur `auth.login`, Befund 27.10.2026).
    public static func isLoggedIn(html: String, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host else { return false }
        return html.contains("auth.logout") || HText.match(logoutLinkRE, html) != nil
    }

    /// Link, dessen Text "Abmelden" enthaelt (auch in einem span), nicht nur das Wort irgendwo im Fliesstext
    static let logoutLinkRE = HText.regex(#"<a\b[^>]*>(?:(?!</a>).){0,300}?abmelden"#, [.caseInsensitive, .dotMatchesLineSeparators])

    private func page(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw HildesheimError.badResponse(urlString) }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        if HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("LSF") }
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: urlString) }
        let html = resp.text
        if !Self.isLoggedIn(html: html, url: resp.finalURL ?? url) { throw HildesheimError.sessionExpired("LSF") }
        return html
    }

    /// Serien des persoenlichen Stundenplans; nil, wenn der Plan leer ist (kein Export-Link). Ein Kalender ohne einen
    /// Termin bei vorhandenem Export-Link ist eine unvollstaendige Antwort (Fehler): nichts wird uebernommen und keine
    /// LSF-Serie entfernt (`UniStore.importPlan` entfernte sonst alle samt eigener Ausnahmen und Teilnahme), wie
    /// `lsf.fetch_plan_ics` am PC.
    public func planEntries() async throws -> [LSFCalendar.Entry]? {
        let html = try await page(Self.planURL)
        guard let link = LSFCalendar.planICSLink(html: html), let url = URL(string: link) else { return nil }
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        let ics = resp.text
        guard resp.status == 200, ics.contains("BEGIN:VCALENDAR") else { throw HildesheimError.badResponse("LSF-iCal") }
        let entries = LSFCalendar.planEntries(ics)
        guard !entries.isEmpty else { throw HildesheimError.badResponse("LSF-iCal ohne Termine") }
        return entries
    }

    /// Leistungen aus dem Notenspiegel (alle Studiengaenge) wie `qis.parse_grade_rows` (`GradeRows`). Stammdaten-Tabellen
    /// werden nie gelesen.
    public func grades() async throws -> [QISGrade] {
        let start = try await page(Self.startURL)
        guard let link = HTMLScanner.scan(start).anchors.first(where: { $0.label.contains("Notenspiegel") }) else {
            throw HildesheimError.badResponse("Link zum Notenspiegel fehlt")
        }
        let first = absolute(link.href)
        var pages = [first], seen = Set([first]), out: [QISGrade] = []
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
        // dieselbe Leistung auf mehreren Reitern nur einmal (Pruefungsnr., Text, Semester, Versuch)
        return QISParser.merge(out)
    }

    /// Links aus `HTMLScanner` sind schon dekodiert (`HildesheimCAS.lsfAbsolute`)
    private func absolute(_ href: String) -> String { HildesheimCAS.lsfAbsolute(href) }
}

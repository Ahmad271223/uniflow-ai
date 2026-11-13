import Foundation

// Bescheinigungen mit der angemeldeten Sitzung lesen und auf Wunsch herunterladen (Cookies setzt der Transport der App;
// nie ein Passwort). Nur lesend bis auf den einen Aufruf, den der Mensch mit "Herunterladen" ausloest:
// - QIS (LUH, LSF Hildesheim, altes QIS der HsH): Startseite -> Menues "Meine Bescheinigungen"/"Studium"/"Mein
//   Studium" (moduleParameter studentReportsMenu, studySOSMenu, studyPOSMenu) und Links mit "Bescheinigung" im Text,
//   dazu der Weg zum Notenspiegel (PDF-Notenspiegel). Gesammelt werden nur Links; nie Pruefungsan-/abmeldung, nie Abmelden.
// - HISinOne (HsH): Studienservice -> Reiter "Bescheide und Bescheinigungen" (lesendes Absenden des Reiters wie
//   `HISinOneStudyService`), dazu das alte QIS im Iframe "Pruefungen und Studium".
// Herunterladen: Seite mit dem Link neu lesen (frischer asi bzw. ViewState), genau EIN Aufruf ohne Wiederholung (jeder
// verpublish-Aufruf erzeugt ein Dokument), PDF pruefen ("%PDF"); kommt eine Zwischenseite, ihrem PDF-Link einmal folgen.

public enum CertificateError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case sessionExpired(String)
    case notOffered
    case notPDF
    case http(Int)

    public var description: String {
        switch self {
        case .sessionExpired(let s): return "Anmeldung bei \(s) abgelaufen. Bitte neu anmelden."
        case .notOffered: return "Das Dokument steht im Portal gerade nicht zur Auswahl. Bitte die Liste aktualisieren."
        case .notPDF: return "Das Portal hat statt der PDF eine Webseite geliefert. Bitte im Portal selbst öffnen."
        case .http(let s): return "Das Portal antwortet mit HTTP \(s)."
        }
    }

    public var errorDescription: String? { description }
}

/// Portal der Hochschule fuer Bescheinigungen
public enum CertificatePortal {
    public static func name(_ university: UniversityKey) -> String {
        switch university {
        case .luh: return "QIS"
        case .hildesheim: return "PLuS"
        case .hsh: return "Campusmanagement"
        }
    }

    /// HISinOne der Hochschule (Bescheinigungen im Studienservice): HsH-Campusmanagement, PLuS der Uni Hildesheim
    public static let plusBase = URL(string: "https://plus.uni-hildesheim.de")!
    /// Kachel "Meine Bescheinigungen" im PLuS (live bestaetigt 06.11.2026): Studienservice gleich im Reiter Bescheinigungen
    public static let plusStudyService = URL(string: plusBase.absoluteString + "/qisserver/pages/cm/exa/enrollment/info/start.xhtml?_flowId=studyservice-flow&initialTab=showTabReport")!
    /// Anmeldung im PLuS: "Anmelden mit Single Sign-On (SSO Uni Hildesheim)" -> CAS (fragt eigens nach dem Passwort)
    public static let plusLogin = URL(string: plusBase.absoluteString + "/qisserver/api/identityprovider/redirect/5/login")!

    static func hisinone(_ university: UniversityKey) -> (base: URL, studyService: URL)? {
        switch university {
        case .hsh: return (UniversityProfile.hshCampus, HISinOneStudyService.url)
        case .hildesheim: return (plusBase, plusStudyService)
        case .luh: return nil
        }
    }

    /// Ehrlicher Hinweis je Hochschule (Quelle, was bestaetigt ist)
    public static func note(_ university: UniversityKey) -> String {
        switch university {
        case .luh:
            return "Quelle: QIS → „Meine Bescheinigungen“ (live bestätigt 06.11.2026): „Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG“ für das aktuelle Semester, dazu der PDF-Notenspiegel, sobald Leistungen verbucht sind. Jeder Abruf erzeugt im QIS ein neues, verifizierbares Dokument; StudiNow lädt nur, wenn du tippst."
        case .hildesheim:
            return "Quelle: PLuS → Studienservice → „Bescheide / Bescheinigungen“ (live bestätigt 06.11.2026): z. B. Immatrikulationsbescheinigung, Bescheinigung nach § 9 BAföG, Studienverlaufs-, Unbedenklichkeitsbescheinigung, Zahlungsnachweis, englische Fassungen. Das LSF hat keine Bescheinigungen. PLuS hat eine eigene Anmeldung (SSO Uni Hildesheim) und meldet nach 30 Minuten ohne Aktivität ab. Nach dem Tippen erstellt PLuS die PDF im Hintergrund."
        case .hsh:
            return "Quelle: Campusmanagement → Studienservice → „Bescheide und Bescheinigungen“ (live bestätigt 06.11.2026). Welche Berichte dort stehen (z. B. Notenspiegel, Zahlungsbeleg, Bescheinigung über angemeldete Prüfungen, Immatrikulationsbescheinigung), hängt von deinem Konto ab. Nach dem Tippen erstellt das Campusmanagement die PDF im Hintergrund."
        }
    }

    public static func loginName(_ university: UniversityKey) -> String {
        switch university {
        case .luh: return "QIS"
        case .hildesheim: return "PLuS"
        case .hsh: return "Campusmanagement"
        }
    }
}

public actor CertificateClient {
    private let transport: UniTransport
    private let retry: UniRetry
    public let university: UniversityKey
    private let qisStart: URL?
    private let pollDelayNanos: UInt64
    /// hoechstens so viele Seiten je Durchlauf (Menues und Notenspiegel)
    public static let maxPages = 16

    /// `qisStart`: Startseite des QIS (Tests); sonst je Hochschule (LUH-QIS, LSF, bei der HsH aus dem Iframe)
    public init(transport: UniTransport, university: UniversityKey, retry: UniRetry = UniRetry(), qisStart: URL? = nil,
                pollDelayNanos: UInt64 = 1_500_000_000) {
        self.transport = transport
        self.university = university
        self.retry = retry
        self.qisStart = qisStart
        self.pollDelayNanos = pollDelayNanos
    }

    var confirmed: Bool { university == .luh }

    // MARK: QIS

    private struct Loaded {
        let page: QISPage
        let html: String
        let url: URL
    }

    private func qisPage(_ url: URL) async throws -> Loaded {
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        guard resp.status == 200 else { throw CertificateError.http(resp.status) }
        let final = resp.finalURL ?? url
        let p = QISPage.parse(html: resp.text, url: final)
        if p.hasLoginForm || !p.isLoggedIn { throw CertificateError.sessionExpired(CertificatePortal.loginName(university)) }
        return Loaded(page: p, html: resp.text, url: final)
    }

    private func defaultQISStart() async throws -> URL? {
        if let qisStart { return qisStart }
        switch university {
        case .luh: return QISClient.startURL
        case .hildesheim: return UniversityProfile.hildesheimLSFStart
        case .hsh: return HISinOne.iframeSource(html: try await HISinOneClient(transport: transport, retry: retry).campusPage(HISinOne.qisIframeURL))
        }
    }

    /// Menues, die zu Bescheinigungen fuehren koennen (0 zuerst); Pruefungsanmeldung und Abmelden nie. Nie ein Link, der
    /// ein Dokument erzeugt (verpublish, hisreports, verify, PDF): die Liste liest nur Menues (11.11.2026, auch im Sync)
    static func menuPriority(_ l: QISLink) -> Int? {
        let addr = l.address.lowercased(), text = l.text.lowercased()
        if addr.contains("prfanm") || addr.contains("logout") || text.contains("abmeld") || text.contains("anmeld") { return nil }
        let state = l.state?.lowercased() ?? ""
        if ["verpublish", "verify", "hisreports"].contains(state) || addr.contains("hisreports") || addr.contains("verpublish")
            || addr.contains(".pdf") { return nil }
        let module = l.parameters["moduleparameter"]?.lowercased() ?? ""
        if module == "studentreportsmenu" || text.contains("bescheinigung") { return 0 }
        if module == "studysosmenu" { return 1 }
        if module == "studyposmenu" { return 2 }
        return nil
    }

    /// Seiten des QIS lesen und Angebote sammeln. `target`: Adresse (ohne asi) eines Links; der Durchlauf endet auf
    /// der ersten Seite mit diesem Link und gibt Seite und Link zurueck. `gradesFirst`: erst der Notenspiegel.
    private func qisWalk(start: URL, target: String?, gradesFirst: Bool) async throws -> (offers: [CertificateOffer], found: (Loaded, QISLink)?) {
        let uni = university.rawValue
        let first = try await qisPage(start)
        var fetched = 1
        var cache: [String: Loaded] = [first.page.address: first]
        var offers: [CertificateOffer] = []
        var known = Set<String>()
        let want = target.map { $0.removingPercentEncoding ?? $0 }

        func absorb(_ l: Loaded, source: String) -> (Loaded, QISLink)? {
            // live bestaetigt (06.11.2026): das Menue der LUH; PDF-Links am Notenspiegel noch nicht (keine Leistungen)
            for o in CertificateParser.qisOffers(html: l.html, url: l.url, source: source, university: uni, confirmed: confirmed && source == "bescheinigungen")
            where known.insert(o.id).inserted { offers.append(o) }
            guard let want else { return nil }
            return l.page.links.first { ($0.address.removingPercentEncoding ?? $0.address) == want }.map { (l, $0) }
        }
        func load(_ link: QISLink, from: Loaded) async throws -> Loaded? {
            if let c = cache[link.address] { return c }
            guard fetched < Self.maxPages, let url = from.page.url(for: link) else { return nil }
            try Task.checkCancellation()
            fetched += 1
            let l = try await qisPage(url)
            cache[link.address] = l
            cache[l.page.address] = l
            return l
        }

        if let hit = absorb(first, source: "bescheinigungen") { return (offers, hit) }

        func menus() async throws -> (Loaded, QISLink)? {
            var visited = Set<String>()
            var queue: [(QISLink, Loaded, Int)] = first.page.links.compactMap { l in Self.menuPriority(l).map { (l, first, $0) } }
                .enumerated().sorted { ($0.element.2, $0.offset) < ($1.element.2, $1.offset) }.map(\.element)
            var pages = 0
            while !queue.isEmpty, pages < 8 {
                let (link, from, depth) = queue.removeFirst()
                guard visited.insert(link.address).inserted, let l = try await load(link, from: from) else { continue }
                pages += 1
                if let hit = absorb(l, source: "bescheinigungen") { return hit }
                // eine Ebene tiefer nur Links mit "Bescheinigung" im Text (z. B. "Studienbescheinigungen")
                if depth < 3 {
                    queue += l.page.links.filter { Self.menuPriority($0) == 0 && !visited.contains($0.address) }.map { ($0, l, 3) }
                }
            }
            return nil
        }
        func grades() async throws -> (Loaded, QISLink)? {
            var visited = Set<String>()
            func next(_ l: Loaded) -> [QISLink] {
                var n = l.page.nextLinksTowardGrades(excluding: visited)
                if n.isEmpty {     // LSF: "Studien-/Prüfungsleistungen (Notenspiegel)" fuehrt direkt in die Liste
                    n = l.page.links.filter { k in
                        k.state?.lowercased() == "notenspiegelstudent" && !visited.contains(k.address)
                            && (k.text.lowercased().contains("notenspiegel") || k.text.lowercased().contains("leistungen"))
                    }.prefix(3).map { $0 }
                }
                return n
            }
            var pending = next(first).map { ($0, first) }
            var pages = 0
            while !pending.isEmpty, pages < 10 {
                let (link, from) = pending.removeFirst()
                guard visited.insert(link.address).inserted, let l = try await load(link, from: from) else { continue }
                visited.insert(l.page.address)
                pages += 1
                if let hit = absorb(l, source: "notenspiegel") { return hit }
                pending = next(l).map { ($0, l) } + pending
            }
            return nil
        }
        if gradesFirst {
            if let hit = try await grades() { return (offers, hit) }
            if let hit = try await menus() { return (offers, hit) }
        } else {
            if let hit = try await menus() { return (offers, hit) }
            if let hit = try await grades() { return (offers, hit) }
        }
        return (offers, nil)
    }

    // MARK: HISinOne (HsH-Campusmanagement, PLuS der Uni Hildesheim)

    private static let logoutRE = HText.regex("category=auth\\.logout", [.caseInsensitive])

    /// Angemeldet: Seite des HISinOne-Rechners mit Abmelden-Link. Der versteckte Block "Ihre Sitzung ist abgelaufen /
    /// Anmelden" steht auf jeder Seite, auch angemeldet, und zaehlt nie.
    static func hisinoneLoggedIn(_ html: String, _ url: URL, base: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == base.host?.lowercased() && HText.match(logoutRE, html) != nil
    }

    private func hisinoneCheck(_ resp: UniResponse, _ url: URL, base: URL) throws -> String {
        let final = resp.finalURL ?? url
        if final.host?.lowercased() != base.host?.lowercased() { throw CertificateError.sessionExpired(CertificatePortal.loginName(university)) }
        guard resp.status == 200 else { throw CertificateError.http(resp.status) }
        guard Self.hisinoneLoggedIn(resp.text, final, base: base) else { throw CertificateError.sessionExpired(CertificatePortal.loginName(university)) }
        return resp.text
    }

    private func hisinonePost(_ req: (url: URL, fields: [(String, String)]), base: URL, ajax: Bool = false) -> UniRequest {
        var headers = ["Content-Type": "application/x-www-form-urlencoded"]
        if ajax { headers["Faces-Request"] = "partial/ajax" }
        return UniRequest(url: req.url, method: "POST", headers: headers, body: HText.form(req.fields))
    }

    /// Studienservice -> Reiter "Bescheide und Bescheinigungen" (lesendes Absenden des Reiters, genau ein Versuch)
    private func hisinoneDocumentsPage() async throws -> (html: String, base: URL) {
        guard let h = CertificatePortal.hisinone(university) else { throw CertificateError.notOffered }
        let html = try hisinoneCheck(try await transport.fetch(UniRequest(url: h.studyService), retry: retry), h.studyService, base: h.base)
        if CertificateParser.isReportTab(html: html) { return (html, h.base) }
        guard let tab = CertificateParser.hisinoneReportTab(html: html),
              let req = CertificateParser.hisinoneFormRequest(html: html, button: tab, semester: nil, base: h.base),
              req.url.host?.lowercased() == h.base.host?.lowercased() else { return (html, h.base) }
        let page = try hisinoneCheck(try await transport.fetch(hisinonePost(req, base: h.base), retry: .none), req.url, base: h.base)
        return (page, h.base)
    }

    /// Nach dem Knopf: PDF direkt, Download-Link in der Antwort oder (HsH) ein Hintergrundauftrag, den die Seite mit
    /// `...jobDownloadPoll:pollOnStop` abfragt; dann erscheint der Link. Abfragen erzeugen nichts und duerfen wiederholt
    /// werden (hoechstens 12-mal); der Link selbst wird einmal geladen.
    private func hisinoneResult(_ resp: UniResponse, form: String, base: URL) async throws -> Data {
        if CertificateParser.isPDF(resp.body) { return resp.body }
        var html = try hisinoneCheck(resp, resp.finalURL ?? base, base: base)
        for attempt in 0..<12 {
            if let link = CertificateParser.embeddedPDF(html: html, base: base) {
                let r = try await once(UniRequest(url: link))
                guard CertificateParser.isPDF(r.body) else { throw CertificateError.notPDF }
                return r.body
            }
            guard let poll = CertificateParser.hisinonePoll(html: html) ?? CertificateParser.hisinonePoll(html: form),
                  let req = CertificateParser.hisinoneAjaxRequest(html: html.contains("javax.faces.ViewState") ? html : form, source: poll, base: base)
            else { break }
            if attempt > 0 || pollDelayNanos > 0 { try await Task.sleep(nanoseconds: pollDelayNanos) }
            let r = try await transport.send(hisinonePost(req, base: base, ajax: true))
            if CertificateParser.isPDF(r.body) { return r.body }
            guard r.status == 200 else { throw CertificateError.http(r.status) }
            html = r.text
        }
        throw CertificateError.notPDF
    }

    // MARK: Liste

    /// Alle angebotenen Dokumente (nur Links und Zeilen lesen, nichts erzeugen)
    public func discover() async throws -> [CertificateOffer] {
        var out: [CertificateOffer] = []
        if university == .hildesheim {      // LSF hat keine Bescheinigungen (Strukturnotizen 06.11.2026): nur PLuS
            return CertificateParser.hisinoneOffers(html: try await hisinoneDocumentsPage().html, university: university.rawValue)
        }
        if university == .hsh {
            out += CertificateParser.hisinoneOffers(html: try await hisinoneDocumentsPage().html, university: university.rawValue)
            // altes QIS (Fakultaeten ohne HISinOne-Leistungen); fehlt es oder ist es nicht erreichbar, bleibt HISinOne
            if let start = try? await defaultQISStart(), let r = try? await qisWalk(start: start, target: nil, gradesFirst: false) {
                out += r.offers.filter { o in !out.contains { $0.id == o.id } }
            }
            return out
        }
        guard let start = try await defaultQISStart() else { return [] }
        return try await qisWalk(start: start, target: nil, gradesFirst: false).offers
    }

    // MARK: Herunterladen

    /// Genau ein Aufruf ohne Wiederholung (er erzeugt im Portal ein Dokument); Antwort muss eine PDF sein
    private func once(_ request: UniRequest) async throws -> UniResponse {
        // erzeugt im Portal ein Dokument (genau ein Aufruf): das laengere Zeitlimit, nie das kurze der Seiten
        var request = request
        if request.timeout == nil { request.timeout = 30 }
        let resp = try await transport.send(request)
        guard resp.status == 200 else { throw CertificateError.http(resp.status) }
        return resp
    }

    private func pdf(_ resp: UniResponse, base: URL, isLoggedIn: (String, URL) -> Bool) async throws -> Data {
        if CertificateParser.isPDF(resp.body) { return resp.body }
        let html = resp.text
        let final = resp.finalURL ?? base
        if !isLoggedIn(html, final) { throw CertificateError.sessionExpired(CertificatePortal.loginName(university)) }
        guard let next = CertificateParser.embeddedPDF(html: html, base: final) else { throw CertificateError.notPDF }
        let second = try await once(UniRequest(url: next))
        guard CertificateParser.isPDF(second.body) else { throw CertificateError.notPDF }
        return second.body
    }

    /// PDF eines Angebots; `semester`: Wert der Semesterauswahl (HISinOne), sonst nil
    public func download(_ offer: CertificateOffer, semester: String? = nil) async throws -> Data {
        if offer.portal == "hisinone" {
            let (html, base) = try await hisinoneDocumentsPage()
            let uni = university.rawValue
            func id(_ title: String, _ sem: String?) -> String { CertificateText.offerID(university: uni, locator: "hisinone|\(title)|\(sem ?? "")") }
            var button: (name: String, value: String)?
            var href: String?
            if let b = CertificateParser.hisinoneJobButtons(html: html).first(where: { id($0.title, nil) == offer.id }) {
                button = (b.name, b.value)
            } else if let row = CertificateParser.hisinoneRows(html: html).first(where: { id($0.title, $0.semester) == offer.id }) {
                button = row.action.button
                href = row.action.href
            } else {
                throw CertificateError.notOffered
            }
            if let href {
                guard let abs = QISParser.resolve(href, base: base).flatMap(URL.init(string:)), abs.host?.lowercased() == base.host?.lowercased()
                else { throw CertificateError.notOffered }
                return try await hisinoneResult(try await once(UniRequest(url: abs)), form: html, base: base)
            }
            guard let button, let req = CertificateParser.hisinoneFormRequest(html: html, button: button, semester: semester, base: base),
                  req.url.host?.lowercased() == base.host?.lowercased() else { throw CertificateError.notOffered }
            return try await hisinoneResult(try await once(hisinonePost(req, base: base)), form: html, base: base)
        }
        guard let address = offer.address, let start = try await defaultQISStart() else { throw CertificateError.notOffered }
        let walk = try await qisWalk(start: start, target: address, gradesFirst: offer.source == "notenspiegel")
        guard let found = walk.found, let url = found.0.page.url(for: found.1) else { throw CertificateError.notOffered }
        let loggedIn: (String, URL) -> Bool = { h, u in
            let p = QISPage.parse(html: h, url: u)
            return !p.hasLoginForm && p.isLoggedIn
        }
        return try await pdf(try await once(UniRequest(url: url)), base: url, isLoggedIn: loggedIn)
    }
}

// MARK: - Speicher (settings.certificates) und Abgleich

public struct CertificateFile: Codable, Sendable, Equatable {
    /// Pfad relativ zum Container (`LocalFiles.stored`)
    public var path: String
    public var fetchedAt: String
    public var size: Int
    public var semester: String?

    enum CodingKeys: String, CodingKey {
        case path, size, semester
        case fetchedAt = "fetched_at"
    }
}

public struct CertificateState: Codable, Sendable, Equatable {
    public var university: String
    public var checkedAt: String?
    /// "never", "ok", "login", "error"
    public var status: String
    public var message: String
    public var offers: [CertificateOffer]
    public var files: [String: CertificateFile]

    enum CodingKeys: String, CodingKey {
        case university, status, message, offers, files
        case checkedAt = "checked_at"
    }

    public init(university: String, checkedAt: String? = nil, status: String = "never", message: String = "",
                offers: [CertificateOffer] = [], files: [String: CertificateFile] = [:]) {
        self.university = university
        self.checkedAt = checkedAt
        self.status = status
        self.message = message
        self.offers = offers
        self.files = files
    }
}

public enum CertificatesSync {
    public static let settingsKey = "certificates"

    public struct Report: Sendable, Equatable {
        public var ok = false
        public var needsLogin = false
        public var cancelled = false
        public var message = ""
        public var offers = 0
        /// gespeicherte PDF (nur Herunterladen)
        public var file: URL?
    }

    static func university(_ c: SQLiteConnection) throws -> UniversityKey {
        UniversityProfile.profile(forKey: try c.scalar("SELECT value FROM settings WHERE key='university'")?.string)?.key ?? .default
    }

    public static func load(_ c: SQLiteConnection) throws -> CertificateState? {
        guard let raw = try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(settingsKey)])?["value"]?.string else { return nil }
        return try? JSONDecoder().decode(CertificateState.self, from: Data(raw.utf8))
    }

    static func save(_ c: SQLiteConnection, _ s: CertificateState) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let text = String(decoding: try enc.encode(s), as: UTF8.self)
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(settingsKey), .text(text)])
    }

    static func isLogin(_ error: Error) -> Bool {
        if case CertificateError.sessionExpired? = error as? CertificateError { return true }
        if case HildesheimError.sessionExpired? = error as? HildesheimError { return true }
        return (error as? QISError) == .sessionExpired
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CertificateError { return e.description }
        return QISGradesSync.describe(error).replacingOccurrences(of: "QIS", with: "Das Portal")
    }

    /// Liste neu lesen (nur Links/Zeilen). Gespeicherte PDFs bleiben, auch wenn ein Angebot gerade fehlt.
    public static func refresh(db: SQLiteDatabase, transport: UniTransport, clock: UniFlowClock = .system,
                               retry: UniRetry = UniRetry(), qisStart: URL? = nil) async -> Report {
        do {
            let uni = try await db.withConnection { try university($0) }
            let offers = try await CertificateClient(transport: transport, university: uni, retry: retry, qisStart: qisStart).discover()
            let now = clock.nowISO
            try await db.transaction { c in
                var s = try load(c) ?? CertificateState(university: uni.rawValue)
                s.university = uni.rawValue
                s.offers = offers
                s.checkedAt = now
                s.status = "ok"
                s.message = offers.isEmpty ? "Das Portal bietet gerade keine Bescheinigungen an." : "\(offers.count) \(offers.count == 1 ? "Dokument" : "Dokumente") im Portal"
                try save(c, s)
            }
            return Report(ok: true, message: "\(offers.count) \(offers.count == 1 ? "Dokument" : "Dokumente") im Portal", offers: offers.count)
        } catch {
            if QISGradesSync.isCancellation(error) { return Report(cancelled: true, message: "Abgebrochen") }
            let login = isLogin(error)
            let text = describe(error)
            let now = clock.nowISO
            try? await db.transaction { c in
                var s = try load(c) ?? CertificateState(university: try university(c).rawValue)
                s.status = login ? "login" : "error"
                s.message = text
                s.checkedAt = s.checkedAt ?? now
                try save(c, s)
            }
            return Report(needsLogin: login, message: text)
        }
    }

    /// Ein Dokument herunterladen und mit Datum ablegen (ersetzt die bisherige Kopie erst, wenn die neue PDF da ist)
    public static func download(db: SQLiteDatabase, files: LocalFiles, transport: UniTransport, offerID: String,
                                semester: String? = nil, clock: UniFlowClock = .system, retry: UniRetry = UniRetry(),
                                qisStart: URL? = nil, pollDelayNanos: UInt64 = 1_500_000_000) async -> Report {
        do {
            let (uni, state) = try await db.withConnection { c in (try university(c), try load(c)) }
            guard let offer = state?.offers.first(where: { $0.id == offerID }) else { throw CertificateError.notOffered }
            let data = try await CertificateClient(transport: transport, university: uni, retry: retry, qisStart: qisStart,
                                                   pollDelayNanos: pollDelayNanos).download(offer, semester: semester)
            let rel = (files.dataDirectory.isEmpty ? "" : files.dataDirectory + "/") + "qis/Bescheinigung-\(offer.id).pdf"
            let url = try files.write(data, to: rel)
            let now = clock.nowISO
            let label = semester.flatMap { v in offer.semesters.first { $0.value == v }?.label } ?? offer.semester
            try await db.transaction { c in
                var s = try load(c) ?? CertificateState(university: uni.rawValue)
                s.files[offer.id] = CertificateFile(path: rel, fetchedAt: now, size: data.count, semester: label)
                if s.status == "login" { s.status = "ok"; s.message = "" }
                try save(c, s)
            }
            return Report(ok: true, message: "„\(offer.title)“ gespeichert", file: url)
        } catch {
            if QISGradesSync.isCancellation(error) { return Report(cancelled: true, message: "Abgebrochen") }
            let login = isLogin(error)
            if login {
                try? await db.transaction { c in
                    if var s = try load(c) { s.status = "login"; s.message = describe(error); try save(c, s) }
                }
            }
            return Report(needsLogin: login, message: describe(error))
        }
    }

    // MARK: Anzeige (GET /api/certificates, wie certificates.summary in app/certificates.py)

    static func kindOrder(_ k: CertificateKind) -> Int { CertificateKind.allCases.firstIndex(of: k) ?? 99 }

    public static func sorted(_ offers: [CertificateOffer]) -> [CertificateOffer] {
        offers.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if kindOrder(x.kind) != kindOrder(y.kind) { return kindOrder(x.kind) < kindOrder(y.kind) }
            let rx = CertificateText.semesterRank(x.semester), ry = CertificateText.semesterRank(y.semester)
            if rx != ry { return rx > ry }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func summary(_ c: SQLiteConnection, files: LocalFiles?) throws -> JSONValue {
        let uni = try university(c)
        let s = try load(c) ?? CertificateState(university: uni.rawValue)
        func str(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
        let offers: [JSONValue] = sorted(s.offers).map { o in
            var file: JSONValue = .null
            if let f = s.files[o.id], files?.exists(stored: f.path) ?? false {
                file = ["fetched_at": .string(f.fetchedAt), "size": .number(Double(f.size)), "semester": str(f.semester),
                        "url": .string("/api/certificates/\(o.id)/file")]
            }
            return ["id": .string(o.id), "title": .string(o.title), "kind": .string(o.kind.rawValue), "kind_label": .string(o.kind.label),
                    "kinds": .array(o.kinds.map { .string($0.rawValue) }), "semester": str(o.semester),
                    "semesters": .array(o.semesters.map { ["value": .string($0.value), "label": .string($0.label)] }),
                    "source": .string(o.source), "confirmed": .bool(o.confirmed), "file": file]
        }
        let covered = Set(s.offers.flatMap(\.kinds))
        let kinds: [JSONValue] = CertificateKind.standard.map { k in
            ["key": .string(k.rawValue), "label": .string(k.label), "offered": .bool(covered.contains(k))]
        }
        let docs = try c.rows("SELECT id, title, fetched_at FROM qis_documents ORDER BY id DESC").map { r -> JSONValue in
            ["id": r["id"] ?? .null, "title": r["title"] ?? .null, "fetched_at": r["fetched_at"] ?? .null]
        }
        return ["university": .string(uni.rawValue), "portal": .string(CertificatePortal.name(uni)), "status": .string(s.status),
                "message": .string(s.message), "checked_at": str(s.checkedAt), "offers": .array(offers), "kinds": .array(kinds),
                "note": .string(CertificatePortal.note(uni)), "documents": .array(docs)]
    }

    /// Gespeicherte PDF eines Angebots; nil ohne Kopie oder ausserhalb des Containers
    public static func fileURL(_ c: SQLiteConnection, files: LocalFiles?, id: String) throws -> URL? {
        guard let files, let f = try load(c)?.files[id], files.exists(stored: f.path) else { return nil }
        return files.url(stored: f.path)
    }
}

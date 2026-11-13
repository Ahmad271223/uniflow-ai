import Foundation

// Noten aus dem QIS der LUH auf dem Geraet (F4): Die Studierenden melden sich in der Webansicht der App selbst an
// (QISLoginView, nur vorausgefuellt); danach liest `QISClient` mit den Cookies dieser Sitzung ueber `UniTransport` die
// Seiten wie `qis.fetch_grades` am PC: Startseite -> "Mein Studium" -> "Notenspiegel" -> Abschluss aufklappen ->
// "Leistungen fuer <Studiengang> anzeigen" -> Tabellen (`QISPage`, `QISCollector`, `GradeRows`). `QISGradesSync`
// schreibt die Leistungen wie `qis.run` in die Datenbank (`UniStore.storeGrades`, `qis_runs`).
//
// Regeln: Der Sitzungsparameter `asi` lebt nur in den Adressen der naechsten Anfrage (`QISPage.url(for:)`) und wird
// nie gespeichert (Adressen im Sammler sind ohne asi, Meldungen ohne Adresse). Stammdaten (Name, Geburtsdatum,
// Anschrift, Matrikelnummer) verwirft schon `QISPage.parse`; sie stehen in keiner Zeile, keiner Meldung und keinem
// Protokoll. Bescheinigungen (verpublish) werden hier nur gezaehlt, nie aufgerufen (jeder Aufruf erzeugt ein Dokument);
// Liste und Herunterladen auf Tippen: Certificates/ (Seite Bescheinigungen, docs/BESCHEINIGUNGEN-2026-11-06.md).
// Leer ist kein Fehler: ein Notenspiegel ohne Leistungen ergibt 0 Leistungen und einen erfolgreichen Lauf.

/// Fehler beim Lesen des QIS; Beschreibungen ohne Adressen (kein asi) und ohne Inhalte der Seiten
public enum QISError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Anmeldeformular statt der angemeldeten Seite: neu anmelden
    case sessionExpired
    /// Startseite ohne "Mein Studium"/"Notenspiegel", oder der Weg endete, bevor eine Notenspiegel-Seite kam
    case notenspiegelNotFound
    case http(status: Int)
    case badResponse(String)

    public var description: String {
        switch self {
        case .sessionExpired: return "Anmeldung bei QIS abgelaufen. Bitte neu anmelden."
        case .notenspiegelNotFound: return "Der Notenspiegel wurde im QIS nicht gefunden. Bitte später erneut versuchen."
        case .http(let s): return "QIS antwortet mit HTTP \(s)."
        case .badResponse(let r): return "Unerwartete Antwort des QIS: \(r)"
        }
    }

    public var errorDescription: String? { description }
}

/// Ergebnis eines Durchlaufs: Leistungen und gefundene Bescheinigungs-Links (nicht aufgerufen), dazu die Zahl der
/// gelesenen Seiten und Leistungstabellen (Diagnose, ohne Inhalte)
public struct QISFetchResult: Sendable, Equatable {
    public let grades: [QISGrade]
    public let documents: [QISDocumentLink]
    public let pages: Int
    public let gradeTables: Int
    /// alle Wege bis zu den Leistungen gelesen (nicht an der Seitengrenze abgebrochen): nur dann ersetzt der Abruf den
    /// gespeicherten Notenspiegel ganz (`QISGradesSync.run`)
    public var complete = true

    public init(grades: [QISGrade], documents: [QISDocumentLink], pages: Int, gradeTables: Int, complete: Bool = true) {
        self.grades = grades
        self.documents = documents
        self.pages = pages
        self.gradeTables = gradeTables
        self.complete = complete
    }
}

/// Liest den Notenspiegel des QIS der LUH mit einer angemeldeten Sitzung (Cookies setzt der Transport der App).
/// Nur lesend: nie Abmelden, nie Pruefungsanmeldung, nie eine Bescheinigung (`QISTarget` kennt diese Ziele nicht
/// bzw. `QISPage.nextLinksTowardGrades` folgt ihnen nicht).
public actor QISClient {
    public static let startURL = UniversityProfile.luhQISStart
    /// hoechstens so viele Seiten je Durchlauf (Startseite, Mein Studium, Notenspiegel, Abschluesse, Studiengaenge).
    /// 12.11.2026 von 24 auf 60: mit mehreren Abschluessen/Studiengaengen und den Baumseiten dazwischen endete der Weg
    /// sonst still vor den letzten Leistungen; wird die Grenze doch erreicht, ist der Abruf unvollstaendig (`complete`)
    public static let defaultMaxPages = 60
    /// Schutz vor Schleifen (12.11.2026): nach so vielen Seiten in Folge ohne Leistungstabelle wird keinem Link mehr
    /// gefolgt, nur noch gelesen, was schon da ist (der Abruf ist dann unvollstaendig und ersetzt nichts)
    public static let stallLimit = 10

    private let transport: UniTransport
    private let retry: UniRetry
    private let start: URL
    private let maxPages: Int
    /// Namen des eigenen Studiengangs: bei mehreren Studiengaengen/Abschluessen zuerst gelesen
    private let preferred: [String]

    public init(transport: UniTransport, retry: UniRetry = UniRetry(), start: URL = QISClient.startURL,
                maxPages: Int = QISClient.defaultMaxPages, preferred: [String] = []) {
        self.transport = transport
        self.retry = retry
        self.start = start
        self.maxPages = maxPages
        self.preferred = preferred
    }

    /// Eine Seite lesen; ein Anmeldeformular oder eine Seite ohne "Abmelden" heisst: Sitzung abgelaufen
    private func page(_ url: URL) async throws -> QISPage {
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        guard resp.status == 200 else { throw QISError.http(status: resp.status) }
        let p = QISPage.parse(html: resp.text, url: resp.finalURL ?? url)
        if p.hasLoginForm || !p.isLoggedIn { throw QISError.sessionExpired }
        return p
    }

    /// Startseite -> Links Richtung Leistungen (Tiefe zuerst, wie `expand` in qis.py), alle Tabellen einsammeln.
    public func fetch() async throws -> QISFetchResult {
        let first = try await page(start)
        guard first.link(.notenspiegel) != nil || first.link(.meinStudium) != nil else { throw QISError.notenspiegelNotFound }
        var collector = QISCollector()
        collector.absorb(first)
        var pages = 1, tables = 0, stall = 0
        var reached = false
        var pending: [(link: QISLink, from: QISPage)] = collector.nextLinks(on: first, preferring: preferred).map { ($0, first) }
        while !pending.isEmpty, pages < maxPages, stall < Self.stallLimit {
            let next = pending.removeFirst()
            guard !collector.visited.contains(next.link.address), !QISParser.isForbiddenNavigation(next.link),
                  let url = next.from.url(for: next.link) else { continue }
            try Task.checkCancellation()
            let p = try await page(url)
            pages += 1
            collector.absorb(p, via: next.link)
            let found = p.gradeTableCount
            tables += found
            stall = found > 0 ? 0 : stall + 1
            if [QISTarget.notenspiegel, .abschluss, .leistungen].contains(where: { QISParser.match(next.link, $0) != nil }) { reached = true }
            // erst in die Tiefe (Abschluss -> Studiengang -> Leistungen), dann die uebrigen Knoten
            pending = collector.nextLinks(on: p, preferring: preferred).map { ($0, p) } + pending
        }
        guard reached else { throw QISError.notenspiegelNotFound }
        let open = pending.contains { !collector.visited.contains($0.link.address) && !QISParser.isForbiddenNavigation($0.link) }
        return QISFetchResult(grades: collector.grades, documents: collector.documents, pages: pages, gradeTables: tables,
                              complete: !open)
    }
}

/// Noten aus dem QIS in die Datenbank, wie `qis.run` am PC und `HildesheimSync.syncGrades` fuer das LSF: dieselbe
/// Leistung wird aktualisiert (`UniStore.storeGrades`), jeder Lauf steht in `qis_runs`. Bescheinigungen werden nicht
/// geladen (`documents` zaehlt nur die gefundenen Links).
public enum QISGradesSync {

    public struct Report: Sendable, Equatable {
        /// Zahl der Leistungen; nil, wenn nichts gelesen wurde (Fehler, Anmeldung, Abbruch)
        public var grades: Int?
        public var documents = 0
        /// Sitzung abgelaufen: Anmeldung anbieten
        public var needsLogin = false
        /// abgebrochen (kein Fehler, kein Eintrag in qis_runs)
        public var cancelled = false
        /// verstaendliche Meldung ohne Adressen und ohne Inhalte der Seiten
        public var message = ""
        public var ok: Bool { grades != nil }

        public init(grades: Int? = nil, documents: Int = 0, needsLogin: Bool = false, cancelled: Bool = false, message: String = "") {
            self.grades = grades
            self.documents = documents
            self.needsLogin = needsLogin
            self.cancelled = cancelled
            self.message = message
        }
    }

    /// Hinweis fuer die Oberflaeche, wenn der letzte Abruf gelang und keine Leistung kam (Inhaber: aktuell 0)
    public static let emptyNotice = "Im QIS sind noch keine Noten veröffentlicht."

    /// Meldung des Laufs wie `qis.run` ("3 Leistungen", bei 0 mit Zusatz)
    static func message(grades: Int) -> String {
        grades == 0 ? "0 Leistungen – im Notenspiegel stehen noch keine Leistungen" : "\(grades) Leistungen"
    }

    /// Meldung ohne Adresse: `URLError` traegt die volle Adresse (mit asi) in seiner Beschreibung
    static func describe(_ error: Error) -> String {
        if let e = error as? QISError { return e.description }
        if let e = error as? HildesheimError { return e.description }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .dataNotAllowed, .networkConnectionLost:
                return "Keine Internetverbindung. QIS wurde nicht abgerufen."
            case .timedOut: return "QIS antwortet nicht (Zeitüberschreitung)."
            default: return "QIS ist gerade nicht erreichbar (Fehler \(e.code.rawValue))."
            }
        }
        return (error as NSError).localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    /// Eigener Studiengang fuer `QISClient(preferred:)`: der des gewaehlten Katalogs (Einstellung Studienverlauf), dann
    /// der zuletzt gelesene Notenspiegel (wie `qis.preferred_programs`)
    static func preferredPrograms(_ c: SQLiteConnection) -> [String] {
        var out: [String] = []
        if let settings = try? StudyPlanAPI.loadSettings(c), let po = settings.po,
           let catalogs = try? DatabaseStudyCatalogSource(c).catalogs() {
            for cat in catalogs where StudyPlanEngine.pyStr(cat["po"]) == po || cat["code"]?.string == po {
                if let p = cat["program"]?.string, !p.isEmpty { out.append(p) }
            }
        }
        if let rows = try? c.rows("SELECT abschluss FROM grades ORDER BY id"), let p = StudyPlanEngine.programOf(rows) { out.append(p) }
        return out
    }

    public static func run(db: SQLiteDatabase, transport: UniTransport, clock: UniFlowClock = .system,
                           retry: UniRetry = UniRetry(), maxPages: Int = QISClient.defaultMaxPages) async -> Report {
        let started = clock.nowISO
        do {
            let preferred = (try? await db.withConnection { c in preferredPrograms(c) }) ?? []
            let r = try await QISClient(transport: transport, retry: retry, maxPages: maxPages, preferred: preferred).fetch()
            let now = clock.nowISO
            let text = message(grades: r.grades.count)
            let grades = r.grades
            try await db.transaction { conn in
                // vollstaendig gelesen: der Notenspiegel ersetzt die Tabelle (nichts Altes bleibt doppelt oder veraltet
                // stehen, Reihenfolge wie im QIS fuer die Zuordnung Pruefung -> Modul); unvollstaendig oder leer: nur
                // ergaenzen/aktualisieren, nie Leistungen verlieren (Regel des Inhabers 12.11.2026)
                if r.complete && !grades.isEmpty {
                    try UniStore.replaceGrades(conn, grades, now: now)
                } else {
                    try UniStore.storeGrades(conn, grades, now: now)
                }
                try conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,1,?,?,0)",
                                 [.text(started), .text(now), .text(text), .integer(Int64(grades.count))])
            }
            return Report(grades: grades.count, documents: r.documents.count, message: text)
        } catch {
            if isCancellation(error) { return Report(cancelled: true, message: "Abruf abgebrochen") }
            let text = describe(error)
            _ = try? await db.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,0,?,0,0)",
                                      [.text(started), .text(clock.nowISO), .text("FEHLER: \(text)")])
            return Report(needsLogin: (error as? QISError) == .sessionExpired, message: text)
        }
    }
}

/// Knopf "Diese Seite auslesen" der QIS-Ansicht (12.11.2026): haengt der automatische Weg (`QISClient`), oeffnet der
/// Mensch die Seite selbst in der Webansicht (Notenspiegel bzw. "Info über angemeldete Prüfungen") und laesst die
/// angezeigte Seite mit demselben Leser lesen (`QISPage.parse`, `GradeRows`, `RegistrationRows`). Nur lesend: kein
/// Link wird aufgerufen, kein Formular gesendet. Stammdaten verwirft schon `QISPage.parse`; asi wird nicht gespeichert.
/// Leistungen werden nur ergaenzt bzw. aktualisiert (`UniStore.storeGrades`, nie geloescht: eine Seite kann ein Teil des
/// Notenspiegels sein), angemeldete Pruefungen ersetzt wie beim Abruf (`QISRegistrationsSync.store`).
public enum QISPageImport {
    public enum Result: Sendable, Equatable {
        /// Leistungstabelle gelesen (Zahl der Zeilen)
        case grades(Int)
        /// Tabelle der angemeldeten Pruefungen gelesen (Zahl der angemeldeten)
        case registrations(Int)
        /// Anmeldeformular statt einer angemeldeten Seite
        case loginPage
        /// weder Notenspiegel noch angemeldete Pruefungen auf dieser Seite
        case nothing
    }

    public struct Report: Sendable, Equatable {
        public let result: Result
        /// verstaendliche Meldung ohne Adresse und ohne Inhalte der Seite
        public let message: String

        public init(result: Result, message: String) {
            self.result = result
            self.message = message
        }
    }

    /// Nur Seiten des QIS (HTTPS, Rechner aus `allowedHosts`)
    public static func accepts(_ url: URL, allowedHosts: [String]) -> Bool {
        url.scheme?.lowercased() == "https" && allowedHosts.contains(url.host?.lowercased() ?? "")
    }

    /// Angezeigte Seite lesen und speichern. `abschluss`: Studiengang, falls bekannt (sonst der zuletzt gelesene)
    public static func read(db: SQLiteDatabase, html: String, url: URL, clock: UniFlowClock = .system,
                            abschluss: String? = nil) async -> Report {
        let page = QISPage.parse(html: html, url: url)
        if page.hasLoginForm {
            return Report(result: .loginPage, message: "Diese Seite ist die QIS-Anmeldung. Bitte zuerst anmelden.")
        }
        let now = clock.nowISO
        if page.gradeTableCount > 0 {
            let known = (try? await db.withConnection { c in
                StudyPlanEngine.abschlussOf(try c.rows("SELECT abschluss FROM grades ORDER BY id"))
            }) ?? nil
            let grades = page.grades(abschluss: abschluss ?? known ?? "")
            let text = QISGradesSync.message(grades: grades.count) + " (angezeigte Seite)"
            do {
                try await db.transaction { conn in
                    try UniStore.storeGrades(conn, grades, now: now)
                    try conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,1,?,?,0)",
                                     [.text(now), .text(now), .text(text), .integer(Int64(grades.count))])
                }
            } catch {
                return Report(result: .nothing, message: QISGradesSync.describe(error))
            }
            return Report(result: .grades(grades.count), message: grades.isEmpty
                          ? "Der Notenspiegel auf dieser Seite enthält noch keine Leistungen."
                          : "\(grades.count) Zeilen des Notenspiegels von dieser Seite übernommen.")
        }
        let tables = QISRegistrationClient.tables(page)
        if !tables.isEmpty {
            let rows = RegistrationRows.merge(tables.flatMap { RegistrationRows.parse(rows: $0.rows.map { $0.map(\.text) }) })
            let n = rows.filter(\.registered).count
            let text = QISRegistrationsSync.message(count: n)
            do {
                try await db.transaction { c in
                    try QISRegistrationsSync.store(c, rows, now: now)
                    try QISRegistrationsSync.saveRun(c, at: now, ok: true, count: n, message: text)
                }
            } catch {
                return Report(result: .nothing, message: QISGradesSync.describe(error))
            }
            return Report(result: .registrations(n), message: text)
        }
        return Report(result: .nothing, message: "Auf dieser Seite steht kein Notenspiegel und keine Liste angemeldeter Prüfungen. Öffne „Mein Studium“ → „Notenspiegel / Studienverlauf“ → „Leistungen für … anzeigen“ oder „Info über angemeldete Prüfungen“.")
    }
}

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
// Protokoll. Bescheinigungen (verpublish) werden nur gezaehlt, nie aufgerufen (jeder Aufruf erzeugt ein Dokument).
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
}

/// Liest den Notenspiegel des QIS der LUH mit einer angemeldeten Sitzung (Cookies setzt der Transport der App).
/// Nur lesend: nie Abmelden, nie Pruefungsanmeldung, nie eine Bescheinigung (`QISTarget` kennt diese Ziele nicht
/// bzw. `QISPage.nextLinksTowardGrades` folgt ihnen nicht).
public actor QISClient {
    public static let startURL = UniversityProfile.luhQISStart
    /// hoechstens so viele Seiten je Durchlauf (Startseite, Mein Studium, Notenspiegel, Abschluesse, Studiengaenge)
    public static let defaultMaxPages = 24

    private let transport: UniTransport
    private let retry: UniRetry
    private let start: URL
    private let maxPages: Int

    public init(transport: UniTransport, retry: UniRetry = UniRetry(), start: URL = QISClient.startURL,
                maxPages: Int = QISClient.defaultMaxPages) {
        self.transport = transport
        self.retry = retry
        self.start = start
        self.maxPages = maxPages
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
        var pages = 1, tables = 0
        var reached = false
        var pending: [(link: QISLink, from: QISPage)] = collector.nextLinks(on: first).map { ($0, first) }
        while !pending.isEmpty, pages < maxPages {
            let next = pending.removeFirst()
            guard !collector.visited.contains(next.link.address), let url = next.from.url(for: next.link) else { continue }
            try Task.checkCancellation()
            let p = try await page(url)
            pages += 1
            collector.absorb(p, via: next.link)
            tables += p.gradeTableCount
            if [QISTarget.notenspiegel, .abschluss, .leistungen].contains(where: { QISParser.match(next.link, $0) != nil }) { reached = true }
            // erst in die Tiefe (Abschluss -> Studiengang -> Leistungen), dann die uebrigen Knoten
            pending = collector.nextLinks(on: p).map { ($0, p) } + pending
        }
        guard reached else { throw QISError.notenspiegelNotFound }
        return QISFetchResult(grades: collector.grades, documents: collector.documents, pages: pages, gradeTables: tables)
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

    public static func run(db: SQLiteDatabase, transport: UniTransport, clock: UniFlowClock = .system,
                           retry: UniRetry = UniRetry(), maxPages: Int = QISClient.defaultMaxPages) async -> Report {
        let started = clock.nowISO
        do {
            let r = try await QISClient(transport: transport, retry: retry, maxPages: maxPages).fetch()
            let now = clock.nowISO
            let text = message(grades: r.grades.count)
            let grades = r.grades
            try await db.transaction { conn in
                try UniStore.storeGrades(conn, grades, now: now)
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

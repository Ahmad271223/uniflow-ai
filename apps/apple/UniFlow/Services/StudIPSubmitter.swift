import Foundation
import UniFlowCore

// Abgeben aus der App (Entscheidung des Inhabers 05.11.2026, docs/ABGEBEN-STUDIP-2026-11-05.md): Ablauf des Blatts
// "In Stud.IP abgeben" ohne Oberflaeche. Sitzung, Ordner und Hochladen ueber den Kern (`StudIPClient.uploadFolders`,
// `upload`), Anmeldung wie beim Abgleich (`StudIPSync.ensureSession`: pruefen, still erneuern, sonst "Anmelden").

/// Schreibender Stud.IP-Transport, nur fuer das Abgeben: dieselbe URLSession-Umsetzung wie der Abgleich
/// (`URLSessionUniTransport`: nur HTTPS auf Stud.IP und den Anmeldeseiten, Cookies je Zieladresse, ein Koerper geht nie
/// an einen anderen Rechner). Der Abgleich bekommt diesen Transport nie (`URLSessionStudIPTransport` kann nicht schreiben).
final class URLSessionStudIPWriter: StudIPWritingTransport, @unchecked Sendable {
    private let transport: URLSessionUniTransport

    init(cookies: [HTTPCookie], host: String, configuration: URLSessionConfiguration = .ephemeral) {
        transport = URLSessionUniTransport(cookies: cookies, allowedDomains: [host] + URLSessionUniTransport.studipDomains,
                                           configuration: configuration)
    }

    private static func reply(_ r: UniResponse) -> HTTPReply {
        HTTPReply(status: r.status, contentType: r.headers["content-type"] ?? "", finalURL: r.finalURL, body: r.body,
                  location: r.headers["location"])
    }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        Self.reply(try await transport.send(UniRequest(url: url, headers: accept.map { ["Accept": $0] } ?? [:])))
    }

    /// POST/PATCH; Weiterleitungen werden nicht verfolgt (ein Hochladen soll nie an einer anderen Adresse landen; eine
    /// Weiterleitung auf die Anmeldung erkennt `StudIPClient` an `finalURL` bzw. am Status 3xx)
    func send(_ url: URL, method: String, headers: [String: String], body: Data) async throws -> HTTPReply {
        let r = try await transport.send(UniRequest(url: url, method: method, headers: headers, body: body, followRedirects: false))
        if (300..<400).contains(r.status), let loc = r.headers["location"], let to = URL(string: loc, relativeTo: url)?.absoluteURL {
            // 3xx auf ein Hochladen: fast immer die Anmeldung (Sitzung abgelaufen); als solche melden
            return HTTPReply(status: r.status == 303 || r.status == 302 ? 401 : r.status, contentType: r.headers["content-type"] ?? "",
                             finalURL: to, body: r.body, location: loc)
        }
        return Self.reply(r)
    }
}

/// Zustand und Ablauf des Blatts "In Stud.IP abgeben"
@MainActor
final class StudIPSubmitModel: ObservableObject {
    /// Kurs zur Auswahl (Stud.IP-Kurse des Containers, mit Modul fuer die Vorauswahl)
    struct Course: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let moduleID: Int?
        /// vorlesung | uebung | sonstiges (Uebungen zuerst vorgeschlagen: dort liegen die Abgabeordner)
        let kind: String?
    }

    /// Fertige PDF zum Abgeben
    struct Prepared: Equatable, Sendable {
        let data: Data
        let pages: Int
    }

    /// Abhaengigkeiten (App: `StudIPSync` und der Editor; Tests: feste Antworten)
    struct Dependencies {
        /// Stud.IP an dieser Hochschule und eine gemerkte Sitzung
        var connected: @MainActor () -> Bool
        /// Sitzung pruefen und bei Bedarf still erneuern (`StudIPSync.ensureSession`)
        var ensureSession: @MainActor (UniRenewalTrigger) async -> StudIPSync.SessionReadiness
        /// Client mit den aktuellen Cookies (nach einer Erneuerung neu bauen)
        var client: @MainActor () -> StudIPClient
        /// Kurse des Containers
        var courses: @MainActor () async -> [Course]
        /// PDF des Dokuments mit oder ohne Notizen und eingefuegte Blaetter
        var makePDF: @MainActor (_ withNotes: Bool) async throws -> Prepared
        /// Einstellungen des Containers (Verlauf)
        var defaults: UserDefaults
        var now: () -> Date = Date.init
    }

    enum Phase: Equatable {
        case loading
        /// Stud.IP nicht verbunden (andere Hochschule oder nie angemeldet)
        case notConnected
        /// Sitzung abgelaufen und still nicht zu erneuern: Anmeldeseite zeigen
        case needsLogin
        case ready
        case uploading
        case done(StudIPSubmissionRecord)
    }

    enum FolderState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let documentID: String
    let documentTitle: String
    let documentCourseID: String?
    let moduleID: Int?
    private let deps: Dependencies

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var courses: [Course] = []
    @Published var selectedCourseID: String? {
        didSet { if oldValue != selectedCourseID, phase != .loading { Task { await loadFolders() } } }
    }
    @Published private(set) var folders = StudIPUploadFolders()
    @Published private(set) var folderState: FolderState = .idle
    @Published var selectedFolderID: String?
    @Published var fileName = ""
    @Published var withNotes = true {
        didSet { if oldValue != withNotes, phase != .loading { Task { await preparePDF() } } }
    }
    @Published private(set) var prepared: Prepared?
    @Published private(set) var preparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var history: [StudIPSubmissionRecord] = []

    init(documentID: String, documentTitle: String, documentCourseID: String?, moduleID: Int?, dependencies: Dependencies) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.documentCourseID = documentCourseID
        self.moduleID = moduleID
        self.deps = dependencies
        history = StudIPSubmissionLog.decode(dependencies.defaults.data(forKey: StudIPSubmissionLog.defaultsKey)).records(for: documentID)
    }

    var selectedCourse: Course? { courses.first { $0.id == selectedCourseID } }
    var selectedFolder: StudIPUploadFolder? { folders.writable.first { $0.id == selectedFolderID } }

    /// "Jetzt abgeben" moeglich
    var canSubmit: Bool {
        phase == .ready && selectedFolder != nil && StudIPSubmit.finalFileName(fileName) != nil && prepared != nil && !preparing
    }

    /// Vorschau "4 Seiten · 1,2 MB"
    var previewLine: String? {
        guard let p = prepared else { return nil }
        return "\(p.pages) \(p.pages == 1 ? "Seite" : "Seiten") · \(StudIPSubmit.megabytes(p.data.count))"
    }

    var sizeNotice: String? { prepared.flatMap { StudIPSubmit.sizeNotice(bytes: $0.data.count) } }

    // MARK: Ablauf

    /// Blatt geoeffnet: Sitzung, Kurse mit Vorauswahl, Name, PDF, Ordner
    func start() async {
        phase = .loading
        errorMessage = nil
        guard deps.connected() else { phase = .notConnected; return }
        switch await deps.ensureSession(.userAction) {
        case .needsUser: phase = .needsLogin; return
        case .notConnected: phase = .notConnected; return
        case .ready, .renewed, .unknown: break
        }
        courses = Self.ordered(await deps.courses(), moduleID: moduleID)
        selectedCourseID = Self.preselect(courses, documentCourseID: documentCourseID, moduleID: moduleID)
        if fileName.isEmpty {
            let family = try? await deps.client().ownName().familyName
            fileName = StudIPSubmit.proposedFileName(familyName: family, title: documentTitle)
        }
        phase = .ready
        await preparePDF()
        await loadFolders()
    }

    /// Nach einer Anmeldung im Blatt
    func signedIn() async { await start() }

    func preparePDF() async {
        preparing = true
        defer { preparing = false }
        do {
            prepared = try await deps.makePDF(withNotes)
        } catch {
            prepared = nil
            errorMessage = "PDF ließ sich nicht erstellen: \(error.localizedDescription)"
        }
    }

    func loadFolders() async {
        guard let course = selectedCourseID else { folders = StudIPUploadFolders(); folderState = .idle; return }
        folderState = .loading
        selectedFolderID = nil
        do {
            let f = try await withRenewal { try await self.deps.client().uploadFolders(courseID: course) }
            guard course == selectedCourseID else { return }       // inzwischen anderer Kurs gewaehlt
            folders = f
            selectedFolderID = f.suggested?.id ?? (f.writable.count == 1 ? f.writable.first?.id : nil)
            folderState = .loaded
        } catch StudIPError.sessionExpired {
            folderState = .idle
            phase = .needsLogin
        } catch {
            folders = StudIPUploadFolders()
            folderState = .failed(Self.message(error))
        }
    }

    /// "Jetzt abgeben": genau ein Hochladen; nur bei abgelaufener Sitzung (Stud.IP hat nichts angenommen) nach der stillen
    /// Erneuerung ein zweiter Versuch
    func submit() async {
        guard canSubmit, let course = selectedCourse, let folder = selectedFolder, let name = StudIPSubmit.finalFileName(fileName),
              let pdf = prepared else { return }
        phase = .uploading
        errorMessage = nil
        do {
            let result = try await withRenewal { try await self.deps.client().upload(pdf.data, fileName: name, folder: folder) }
            let record = StudIPSubmissionRecord(documentID: documentID, at: deps.now(), courseID: course.id, courseTitle: course.title,
                                                folderID: folder.id, folderLabel: folder.label, fileName: name,
                                                url: result.webURL.absoluteString, withNotes: withNotes, pages: pdf.pages)
            var log = StudIPSubmissionLog.decode(deps.defaults.data(forKey: StudIPSubmissionLog.defaultsKey))
            log.add(record)
            deps.defaults.set(log.encoded(), forKey: StudIPSubmissionLog.defaultsKey)
            history = log.records(for: documentID)
            phase = .done(record)
        } catch StudIPError.sessionExpired {
            phase = .needsLogin
        } catch {
            errorMessage = Self.message(error)
            phase = .ready
        }
    }

    /// Eine Anfrage; meldet Stud.IP "Sitzung abgelaufen", einmal still erneuern und mit neuem Client wiederholen
    private func withRenewal<T>(_ op: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch StudIPError.sessionExpired {
            switch await deps.ensureSession(.userAction) {
            case .ready, .renewed: return try await op()
            case .needsUser, .notConnected, .unknown: throw StudIPError.sessionExpired
            }
        }
    }

    // MARK: Regeln

    static func message(_ error: Error) -> String {
        if let e = error as? StudIPUploadError { return e.errorDescription ?? "\(e)" }
        if let e = error as? StudIPError { return e.description }
        if let e = error as? URLError, e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            return "Keine Verbindung. Die Datei wurde nicht abgegeben."
        }
        return error.localizedDescription
    }

    /// Kurse des Moduls zuerst (Uebungen vor Vorlesungen), dann nach Titel
    static func ordered(_ list: [Course], moduleID: Int?) -> [Course] {
        list.sorted { a, b in
            let ma = moduleID != nil && a.moduleID == moduleID, mb = moduleID != nil && b.moduleID == moduleID
            if ma != mb { return ma }
            if ma, (a.kind == "uebung") != (b.kind == "uebung") { return a.kind == "uebung" }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Vorauswahl: Kurs der Datei, sonst die Uebung des Moduls, sonst der einzige Kurs des Moduls; sonst keiner
    static func preselect(_ list: [Course], documentCourseID: String?, moduleID: Int?) -> String? {
        if let c = documentCourseID, list.contains(where: { $0.id == c }) { return c }
        guard let moduleID else { return nil }
        let inModule = list.filter { $0.moduleID == moduleID }
        return (inModule.first { $0.kind == "uebung" } ?? inModule.first)?.id
    }

    /// Stud.IP-Kurse aus `/api/courses` (nur 32-stellige Stud.IP-Kennungen, aktive; keine eigenen Dokumente, kein Learnweb)
    static func courses(from rows: JSONValue) -> [Course] {
        (rows.array ?? []).compactMap { r in
            guard let id = r["id"]?.string, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
            if let active = r["active"]?.int, active == 0 { return nil }
            return Course(id: id, title: r["title"]?.string ?? "Kurs", moduleID: r["module_id"]?.int, kind: r["kind"]?.string)
        }
    }
}

extension StudIPSubmitModel.Dependencies {
    /// App: Sitzung und Client aus dem Abgleich des Containers, Kurse aus dem lokalen Backend, PDF aus dem Editor
    @MainActor
    static func live(studip: StudIPSync, api: APIClient, defaults: UserDefaults,
                     makePDF: @escaping @MainActor (Bool) async throws -> StudIPSubmitModel.Prepared) -> Self {
        Self(connected: { studip.offersStudIP && studip.hasStoredSession },
             ensureSession: { await studip.ensureSession($0) },
             client: {
                 let host = StudIPSync.base.host ?? ""
                 let writer: StudIPWritingTransport = DebugUniStub.studipWriter()
                     ?? URLSessionStudIPWriter(cookies: StudIPSync.ownCookies(studip.cookies.load(), host: host), host: host)
                 // wenige Anfragen auf Knopfdruck: kurze Pause, kleine Grenze
                 return StudIPClient(base: StudIPSync.base, transport: writer, pauseMillis: 100, maxRequests: 40)
             },
             courses: { StudIPSubmitModel.courses(from: (try? await api.value("/api/courses")) ?? .array([])) },
             makePDF: makePDF,
             defaults: defaults)
    }
}

extension DebugUniStub {
    /// Nachbildung auch fuer das Abgeben (nur Debug mit `-UFLoginStub`)
    static func studipWriter() -> StudIPWritingTransport? { studipTransport() as? StudIPWritingTransport }
}

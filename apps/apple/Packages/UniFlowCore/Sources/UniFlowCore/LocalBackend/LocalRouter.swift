import Foundation
#if canImport(os)
import os
#endif

/// Was ein Endpunkt fuer seine Arbeit bekommt: die Datenbank des Geraets, die Uhr und die Dateiablage.
public struct LocalContext: Sendable {
    public let database: SQLiteDatabase
    public let clock: UniFlowClock
    /// Stud.IP-Dateien, eigene Dokumente, Bilder der Notizen; nil = keine Dateien (Inhalte 404, Hochladen 503)
    public let files: LocalFiles?
    /// Neue Kennung wie `uuid.uuid4().hex` (32 Hex-Zeichen); Tests setzen dieselbe Folge wie die Python-Fixtures
    public let newHex: @Sendable () -> String
    /// Index der Skriptsuche je Modul (`_CACHE` in app/scriptsearch.py), je Datenbank
    let scriptIndex = ScriptSearch.IndexCache()

    public init(database: SQLiteDatabase, clock: UniFlowClock = .system, files: LocalFiles? = nil,
                newHex: @escaping @Sendable () -> String = LocalContext.randomHex) {
        self.database = database
        self.clock = clock
        self.files = files
        self.newHex = newHex
    }

    /// `uuid.uuid4().hex`
    public static let randomHex: @Sendable () -> String = {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Dateiablage oder 503 mit Meldung
    func requireFiles() throws -> LocalFiles {
        guard let files else { throw LocalHTTPError(status: 503, message: "Auf diesem Gerät gibt es keinen Speicherort für Dateien.") }
        return files
    }
}

public typealias LocalHandler = @Sendable (LocalRequest, LocalContext) async throws -> LocalResponse

/// Pfadmuster wie bei FastAPI: `/api/files/{file_id}/content`. `{name:int}` verlangt eine ganze Zahl; passt der
/// Pfad, der Wert aber nicht, antwortet der Router mit 422 wie FastAPI bei `file_id: int`.
public struct LocalPathPattern: Hashable, Sendable, CustomStringConvertible {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case param(String, isInt: Bool)
    }

    public let template: String
    let segments: [Segment]

    public init(_ template: String) {
        self.template = template
        segments = template.split(separator: "/", omittingEmptySubsequences: true).map { s in
            guard s.hasPrefix("{"), s.hasSuffix("}") else { return .literal(String(s)) }
            let inner = s.dropFirst().dropLast()
            let parts = inner.split(separator: ":", maxSplits: 1)
            return .param(String(parts[0]), isInt: parts.count == 2 && parts[1] == "int")
        }
    }

    /// Form ohne Parameternamen, z. B. `/api/files/{}/content` (Vergleich mit der Pfadliste der App)
    public var shape: String {
        "/" + segments.map { if case .literal(let l) = $0 { return l } else { return "{}" } }.joined(separator: "/")
    }

    public var description: String { template }

    /// Werte der Platzhalter, wenn der Pfad passt
    func match(_ parts: [Substring]) -> [String: String]? {
        guard parts.count == segments.count else { return nil }
        var params: [String: String] = [:]
        for (seg, part) in zip(segments, parts) {
            switch seg {
            case .literal(let l): if l != part { return nil }
            case .param(let name, _): if part.isEmpty { return nil } else { params[name] = String(part) }
            }
        }
        return params
    }

    /// Feste Teile gehen vor Platzhaltern (`/api/tasks/open` vor `/api/tasks/{id}`), unabhaengig von der Reihenfolge
    /// der Registrierung.
    func isMoreSpecific(than other: LocalPathPattern) -> Bool {
        for (a, b) in zip(segments, other.segments) {
            switch (a, b) {
            case (.literal, .param): return true
            case (.param, .literal): return false
            default: continue
            }
        }
        return false
    }

    var intParams: [String] {
        segments.compactMap { if case .param(let n, true) = $0 { return n } else { return nil } }
    }
}

/// Ein registrierter Endpunkt.
public struct LocalRoute: Sendable {
    public let method: String
    public let pattern: LocalPathPattern
    /// Endpunkt-Modul, das ihn registriert hat
    public let module: String
    /// Platzhalter bis zur Portierung: liefert eine gueltige Antwort in Server-Form (meist leer). Ein echter
    /// Endpunkt mit derselben Methode und demselben Muster ersetzt ihn, ohne dass der Platzhalter geaendert wird.
    public let placeholder: Bool
    let handler: LocalHandler
}

/// Leitet Anfragen an die Endpunkte der Module weiter. Jedes Modul registriert seine Pfade selbst
/// (`LocalEndpointModule.register`); doppelte echte Endpunkte werden als Konflikt gemeldet.
public final class LocalRouter: @unchecked Sendable {
    private var routes: [LocalRoute] = []
    private var currentModule = "?"
    public private(set) var conflicts: [String] = []

    public init() {}

    /// Alle Endpunkte eines Moduls eintragen (vor der ersten Anfrage, nicht nebenlaeufig).
    public func register(_ module: LocalEndpointModule.Type) {
        currentModule = module.name
        module.register(on: self)
        currentModule = "?"
    }

    public func add(_ method: String, _ template: String, placeholder: Bool = false, _ handler: @escaping LocalHandler) {
        let route = LocalRoute(method: method.uppercased(), pattern: LocalPathPattern(template), module: currentModule,
                               placeholder: placeholder, handler: handler)
        if let other = routes.first(where: { $0.method == route.method && $0.pattern.shape == route.pattern.shape && $0.placeholder == placeholder }) {
            conflicts.append("\(route.method) \(template): \(other.module) und \(route.module)")
        }
        routes.append(route)
    }

    public func get(_ t: String, placeholder: Bool = false, _ h: @escaping LocalHandler) { add("GET", t, placeholder: placeholder, h) }
    public func put(_ t: String, placeholder: Bool = false, _ h: @escaping LocalHandler) { add("PUT", t, placeholder: placeholder, h) }
    public func post(_ t: String, placeholder: Bool = false, _ h: @escaping LocalHandler) { add("POST", t, placeholder: placeholder, h) }
    public func patch(_ t: String, placeholder: Bool = false, _ h: @escaping LocalHandler) { add("PATCH", t, placeholder: placeholder, h) }
    public func delete(_ t: String, placeholder: Bool = false, _ h: @escaping LocalHandler) { add("DELETE", t, placeholder: placeholder, h) }

    public var allRoutes: [LocalRoute] { routes }

    /// Endpunkt fuer Methode und Pfad (echte vor Platzhaltern, feste Teile vor Platzhaltern im Muster).
    public func route(method: String, path: String) -> (route: LocalRoute, params: [String: String])? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let m = method.uppercased()
        var best: (LocalRoute, [String: String])?
        for r in routes where r.method == m {
            guard let params = r.pattern.match(parts) else { continue }
            if let (b, _) = best {
                let better = (b.placeholder && !r.placeholder)
                    || (b.placeholder == r.placeholder && r.pattern.isMoreSpecific(than: b.pattern))
                if !better { continue }
            }
            best = (r, params)
        }
        return best
    }

    /// Antwort wie FastAPI: 404 ohne passenden Pfad, 405 bei falscher Methode, 422 bei falschem Pfadtyp.
    public func handle(_ request: LocalRequest, context: LocalContext) async -> LocalResponse {
        guard let (route, params) = route(method: request.method, path: request.path) else {
            let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
            if routes.contains(where: { $0.pattern.match(parts) != nil }) {
                return .detail(405, "Method Not Allowed")
            }
            return .notFound
        }
        for name in route.pattern.intParams where Int(params[name] ?? "") == nil {
            return LocalHTTPError.validation(type: "int_parsing", loc: ["path", name],
                                             msg: "Input should be a valid integer, unable to parse string as an integer",
                                             input: .string(params[name] ?? "")).response
        }
        var req = request
        req.pathParams = params
        do {
            return try await route.handler(req, context)
        } catch let e as LocalHTTPError {
            return e.response
        } catch {
            LocalBackendLog.unexpected(error, method: route.method, template: route.pattern.template)
            return .detail(500, Self.internalMessage(error))
        }
    }

    /// Meldung fuer unerwartete Fehler (Pruefbericht 555). Vorher stand der Text von SQLite bzw. die ganze
    /// Fehlerbeschreibung in der Antwort: Tabellen- und Spaltennamen, Teile von SQL, bei Dateifehlern Pfade und
    /// Dateinamen. Die Antwort zeigt die App als Meldung an; sie nennt jetzt nur die Art des Fehlers und den Code,
    /// die Einzelheiten stehen nur im Geraeteprotokoll (`LocalBackendLog`, als privat markiert). Speicher voll hat
    /// einen eigenen Text, weil der Nutzer dann selbst etwas tun kann.
    public static func internalMessage(_ error: Error) -> String {
        if isStorageFull(error) { return "Der Speicher dieses Geräts ist voll. Gib Platz frei und versuche es erneut." }
        if let e = error as? SQLiteError { return "Fehler der lokalen Datenbank (Code \(e.extendedCode)). Bitte versuche es erneut." }
        return "Interner Fehler im lokalen Backend. Bitte versuche es erneut."
    }

    /// SQLITE_FULL, kein Platz beim Schreiben einer Datei (Cocoa bzw. POSIX ENOSPC), auch als zugrunde liegender Fehler
    static func isStorageFull(_ error: Error) -> Bool {
        if let e = error as? SQLiteError { return e.code == 13 }                         // SQLITE_FULL
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isStorageFull(underlying) }
        return false
    }
}

/// Protokoll unerwarteter Fehler des lokalen Backends (nur auf dem Geraet, Einzelheiten als privat markiert)
enum LocalBackendLog {
    #if canImport(os)
    private static let log = Logger(subsystem: "de.uniflow.ai", category: "LocalBackend")
    #endif

    static func unexpected(_ error: Error, method: String, template: String) {
        #if canImport(os)
        log.error("\(method, privacy: .public) \(template, privacy: .public): \(String(describing: error), privacy: .private)")
        #endif
    }
}

extension LocalRequest {
    /// Pfadwert als Text (vom Router gesetzt)
    public func param(_ name: String) -> String { pathParams[name] ?? "" }

    /// Pfadwert als ganze Zahl (Muster `{name:int}`, vom Router geprueft)
    public func intParam(_ name: String) -> Int { Int(pathParams[name] ?? "") ?? 0 }
}

/// Ein Endpunkt-Modul (Einstellungen, Semester, ...): traegt seine Pfade selbst beim Router ein. Neue Module kommen
/// in `LocalBackend.standardModules`; die Pfade stehen nur im Modul.
public protocol LocalEndpointModule {
    static var name: String { get }
    static func register(on router: LocalRouter)
}

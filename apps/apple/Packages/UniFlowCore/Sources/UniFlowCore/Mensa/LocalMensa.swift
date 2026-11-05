import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abruf eines oeffentlichen Speiseplans (Tests ersetzen ihn, nie echtes Netz)
public protocol MensaHTTP: Sendable {
    func get(_ url: String) async throws -> Data
}

public struct MensaHTTPError: Error, Sendable { public let status: Int }

/// URLSession mit 10 s Zeitlimit und eigenem User-Agent (wenige Anfragen: eine je Mensa fuer 14 Tage, 3 h Cache)
public struct URLSessionMensaHTTP: MensaHTTP {
    public init() {}
    public func get(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.setValue(Mensa.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw MensaHTTPError(status: h.statusCode) }
        return data
    }
}

/// Speiseplaene auf dem Geraet: holt direkt bei der Quelle (Studi|Futter bzw. STW-ON, Ersatz OpenMensa), Cache je Mensa als
/// JSON-Datei im Caches-Ordner (frisch 3 Stunden, ohne Netz der letzte Stand mit `stale`). Gleiche Antwort wie
/// `mensa.menu` in Python.
public final class LocalMensa: @unchecked Sendable {
    private let lock = NSLock()
    private var http: MensaHTTP = URLSessionMensaHTTP()
    private var folder: URL? = LocalMensa.defaultFolder

    public init() {}

    static var defaultFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("StudiNow-Mensa", isDirectory: true)
    }

    /// Tests und App: Abruf und Cache-Ordner setzen (nil = kein Cache auf der Platte)
    public func configure(http: MensaHTTP? = nil, folder: URL?) {
        lock.withLock {
            if let http { self.http = http }
            self.folder = folder
        }
    }

    private var current: (MensaHTTP, URL?) { lock.withLock { (http, folder) } }

    private func file(_ cid: String, _ folder: URL?) -> URL? { folder?.appendingPathComponent("\(cid).json") }

    func readCache(_ cid: String, _ folder: URL?) -> JSONValue? {
        guard let f = file(cid, folder), let d = try? Data(contentsOf: f) else { return nil }
        return try? JSONValue.parse(d)
    }

    func writeCache(_ cid: String, _ folder: URL?, _ value: JSONValue) {
        guard let folder, let f = file(cid, folder) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? value.serialized(sortedKeys: true).write(to: f, options: .atomic)
    }

    /// Quelle der Mensa, bei Fehler OpenMensa (falls vorhanden); wirft, wenn beides scheitert
    func fetch(_ c: JSONValue, start: String, end: String, http: MensaHTTP) async throws -> (JSONValue, String) {
        let primary = c["source"]?["kind"]?.string ?? ""
        let kinds = [primary] + ((c["openmensa"]?.int != nil && primary != "openmensa") ? ["openmensa"] : [])
        var last: Error = URLError(.cannotLoadFromNetwork)
        for kind in kinds {
            do {
                let raw = try JSONValue.parse(try await http.get(Mensa.sourceURL(c, start: start, end: end, kind: kind)))
                let parsed = Mensa.parse(kind: kind, raw: raw)
                if kind != "openmensa" && (parsed["days"]?.object ?? [:]).isEmpty && kinds.count > 1 {
                    last = URLError(.zeroByteResource)
                    continue
                }
                return (parsed, kind)
            } catch {
                last = error
            }
        }
        throw last
    }

    /// Antwort von GET /api/mensa/menu
    public func menu(canteen cid: String, day: String?, days: Int, clock: UniFlowClock) async throws -> JSONValue {
        guard let c = Mensa.canteen(cid) else { throw LocalHTTPError(status: 404, message: "Diese Mensa kenne ich nicht.") }
        let (http, folder) = current
        let today = clock.today
        let day = day ?? today
        let count = max(1, min(days, Mensa.windowDays))
        let wantEnd = Mensa.addDays(day, count - 1)
        let nowTS = Int(clock.now.timeIntervalSince1970)
        var cache = readCache(cid, folder)
        var stale = false
        var message: String?
        if !Mensa.isFresh(cache, wantedStart: day, wantedEnd: wantEnd, today: today, nowTS: nowTS),
           day >= Mensa.addDays(today, -Mensa.keepPastDays) {
            let ws = min(day, today), we = Mensa.addDays(min(day, today), Mensa.windowDays - 1)
            do {
                let (parsed, kind) = try await fetch(c, start: ws, end: we, http: http)
                let merged = Mensa.mergeCache(cache, parsed: parsed, start: ws, end: we, source: kind, today: today,
                                              nowISO: clock.nowISO, nowTS: nowTS)
                cache = merged
                writeCache(cid, folder, merged)
            } catch {
                stale = true
                message = cache != nil ? "Keine Verbindung zum Speiseplan. Du siehst den zuletzt geladenen Stand."
                    : "Der Speiseplan ist gerade nicht erreichbar. Versuche es später erneut."
            }
        }
        let kind = cache?["source"]?.string ?? c["source"]?["kind"]?.string ?? ""
        let src = Mensa.data["sources"]?[kind]
        let parsed: JSONValue = ["days": cache?["days"] ?? .object([:]), "closed": cache?["closed"] ?? .array([])]
        return ["canteen": Mensa.publicCanteen(c),
                "days": .array(Mensa.buildDays(start: day, count: count, parsed: parsed, since: cache?["window"]?.array?.first?.string)),
                "source": ["key": .string(kind), "name": src?["name"] ?? .null, "url": src?["url"] ?? .null,
                           "attribution": src?["attribution"] ?? .null],
                "fetched_at": cache?["fetched_at"] ?? .null, "stale": .bool(stale), "message": message.map(JSONValue.string) ?? .null]
    }
}

/// Mensa auf dem Geraet (frei in jedem Tarif):
/// - `GET /api/mensa/canteens[?university=]`: Mensen, Standard der Hochschule, Preisgruppen, Kennzeichen, Allergene
/// - `GET /api/mensa/menu?canteen=&date=&days=`: Tage mit Status open/closed/none und Speisen
public enum MensaEndpoints: LocalEndpointModule {
    public static let name = "Mensa"

    static func university(_ ctx: LocalContext) async throws -> String {
        try await ctx.database.withConnection { c in
            try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
        }
    }

    public static func register(on router: LocalRouter) {
        router.get("/api/mensa/canteens") { req, ctx in
            let u: String
            if let q = req.query("university"), !q.isEmpty { u = q } else { u = try await university(ctx) }
            return .json(Mensa.canteensResponse(university: u))
        }
        router.get("/api/mensa/menu") { req, ctx in
            var cid = req.query("canteen") ?? ""
            if cid.isEmpty {
                let u: String
                if let q = req.query("university"), !q.isEmpty { u = q } else { u = try await university(ctx) }
                cid = Mensa.defaultCanteen(university: u)
            }
            guard Mensa.canteen(cid) != nil else { throw LocalHTTPError(status: 404, message: "Diese Mensa kenne ich nicht.") }
            var day: String?
            if let d = req.query("date"), !d.isEmpty {
                guard d.count == 10, BerlinClock.parseISODate(d) != nil else {
                    throw LocalHTTPError(status: 400, message: "Datum bitte als JJJJ-MM-TT.")
                }
                day = d
            }
            let days = Int(req.query("days") ?? "") ?? 1
            return .json(try await ctx.mensa.menu(canteen: cid, day: day, days: days, clock: ctx.clock))
        }
    }
}

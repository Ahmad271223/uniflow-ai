import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Suche beim Standortfinder der LUH (Tests ersetzen sie, nie echtes Netz): Antwort `{count, data, search_term}`
public protocol RoomFinderHTTP: Sendable {
    func search(_ term: String, page: Int) async throws -> JSONValue
}

public struct RoomFinderHTTPError: Error, Sendable { public let status: Int }

/// `POST https://standortfinder.uni-hannover.de/search` mit `search=<text>&page=<n>`, Referer der Startseite, eigenem
/// User-Agent und 10 s Zeitlimit. Der Server verlangt derzeit kein CSRF-Token; meldet er 403, holt der Abruf das Cookie
/// `csrftoken` von der Startseite und schickt es als `X-CSRFToken` (gilt fuer die Sitzung der App).
public final class URLSessionRoomFinderHTTP: RoomFinderHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral          // eigene Cookies, nichts im gemeinsamen Speicher
        cfg.timeoutIntervalForRequest = 10
        session = URLSession(configuration: cfg)
    }

    private var sf: JSONValue? { Rooms.data["standortfinder"] }

    static func form(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\(PyText.quote($0.0, safe: "", plus: true))=\(PyText.quote($0.1, safe: "", plus: true))" }
            .joined(separator: "&").utf8)
    }

    private func post(_ term: String, page: Int, token: String?) async throws -> (Int, Data) {
        guard let u = URL(string: sf?["search"]?.string ?? "") else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(Rooms.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(sf?["url"]?.string, forHTTPHeaderField: "Referer")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let token {
            req.setValue(token, forHTTPHeaderField: "X-CSRFToken")
            req.setValue("csrftoken=\(token)", forHTTPHeaderField: "Cookie")
        }
        req.httpBody = Self.form([("search", term), ("page", String(page))])
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func freshToken() async throws -> String? {
        guard let u = URL(string: sf?["url"]?.string ?? "") else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.setValue(Rooms.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await session.data(for: req)
        guard let h = resp as? HTTPURLResponse else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: h.allHeaderFields as? [String: String] ?? [:], for: u)
        return cookies.first { $0.name == "csrftoken" }?.value
    }

    public func search(_ term: String, page: Int) async throws -> JSONValue {
        let current = lock.withLock { token }
        var (status, data) = try await post(term, page: page, token: current)
        if status == 403 {
            let t = try await freshToken()
            lock.withLock { token = t }
            (status, data) = try await post(term, page: page, token: t)
        }
        guard (200..<300).contains(status) else { throw RoomFinderHTTPError(status: status) }
        let out = try JSONValue.parse(data)
        guard out["data"]?.array != nil else { throw RoomFinderHTTPError(status: 502) }
        return out
    }
}

/// Raumfinder auf dem Geraet: Suche direkt beim Standortfinder, Antworten 30 Tage im Cache (Raeume ziehen selten um),
/// "nichts gefunden" einen Tag; Datei im Ordner Application Support (bleibt erhalten). Ohne Netz: Cache mit `stale`
/// oder ein einfacher Adress-Link. Gleiche Antworten wie app/rooms.py.
/// Uni Hildesheim (07.11.2026): mit gesetztem `HildesheimRoomFinder` (Raumplan im LSF, Hildesheim/HildesheimRooms.swift)
/// laufen Suche und Aufloesen dort; ohne ihn (PC, Python-Fixtures) bleibt es beim Standort der Hochschule.
public final class LocalRooms: @unchecked Sendable {
    private let lock = NSLock()
    private var http: RoomFinderHTTP = URLSessionRoomFinderHTTP()
    private var folder: URL? = LocalRooms.defaultFolder
    private var hildesheim: HildesheimRoomFinder?

    public init() {}

    public static var defaultFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StudiNow-Rooms", isDirectory: true)
    }

    /// Tests und App: Abruf und Cache-Ordner setzen (nil = kein Cache auf der Platte)
    public func configure(http: RoomFinderHTTP? = nil, folder: URL?) {
        lock.withLock {
            if let http { self.http = http }
            self.folder = folder
        }
    }

    /// Raumfinder der Uni Hildesheim setzen (App: LSF ueber URLSession, Tests: nachgebaute Seiten); nil = Standorttabelle
    public func configure(hildesheim: HildesheimRoomFinder?) {
        lock.withLock { self.hildesheim = hildesheim }
    }

    private var current: (RoomFinderHTTP, URL?) { lock.withLock { (http, folder) } }

    /// Raumfinder der Hochschule: "standortfinder" (LUH), "lsf" (Hildesheim mit gesetztem Leser), sonst nil
    public func finder(university: String) -> String? {
        if university == "luh" { return "standortfinder" }
        if university == HildesheimRooms.university, lock.withLock({ hildesheim }) != nil { return "lsf" }
        return nil
    }

    var hildesheimFinder: HildesheimRoomFinder? { lock.withLock { hildesheim } }

    // MARK: Cache

    private var memory: JSONValue = ["v": 1, "entries": [:]]

    private func file(_ folder: URL?) -> URL? { folder?.appendingPathComponent("search-cache.json") }

    func readCache(_ folder: URL?) -> JSONValue {
        if let f = file(folder), let d = try? Data(contentsOf: f), let v = try? JSONValue.parse(d), v["v"]?.int == 1,
           v["entries"]?.object != nil {
            return v
        }
        return folder == nil ? lock.withLock { memory } : ["v": 1, "entries": [:]]
    }

    func writeCache(_ folder: URL?, _ value: JSONValue) {
        var value = value
        if let entries = value["entries"]?.object, entries.count > Rooms.cacheMax {
            let keep = entries.sorted { ($0.value["ts"]?.double ?? 0) > ($1.value["ts"]?.double ?? 0) }.prefix(Rooms.cacheMax)
            value["entries"] = .object(Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) }))
        }
        guard let folder, let f = file(folder) else { lock.withLock { memory = value }; return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? value.serialized(sortedKeys: true).write(to: f, options: .atomic)
    }

    static func cacheKey(_ term: String, page: Int) -> String { "\(PyText.lower(Rooms.words(term)))|\(page)" }

    static func isFresh(_ entry: JSONValue?, nowTS: Int) -> Bool {
        guard let entry, let ts = entry["ts"]?.int else { return false }
        let days = (entry["count"]?.int ?? 0) > 0 ? Rooms.cacheDays : Rooms.missDays
        return nowTS - ts < days * 86400
    }

    /// (Antwort {count, data}, stale). Ohne Netz der alte Stand (stale) oder nil.
    func cachedSearch(_ term: String, page: Int, clock: UniFlowClock) async -> (JSONValue?, Bool) {
        let (http, folder) = current
        let key = Self.cacheKey(term, page: page)
        let nowTS = Int(clock.now.timeIntervalSince1970)
        let entry = readCache(folder)["entries"]?[key]
        if Self.isFresh(entry, nowTS: nowTS) { return (entry, false) }
        let r: JSONValue
        do { r = try await http.search(term, page: page) } catch { return (entry, true) }
        let fresh: JSONValue = ["at": .string(clock.nowISO), "ts": .number(Double(nowTS)), "count": .number(Double(r["count"]?.int ?? 0)),
                                "data": .array((r["data"]?.array ?? []).filter { $0.object != nil })]
        var cache = readCache(folder)
        cache["entries"]?[key] = fresh
        writeCache(folder, cache)
        return (fresh, false)
    }

    // MARK: Antworten

    /// Antwort von GET /api/rooms/search (Seite "Raumfinder"); Hildesheim mit LSF-Leser sucht im Raumplan des LSF
    public func search(_ q: String?, page: Int, clock: UniFlowClock, university: String = "luh") async -> JSONValue {
        if university == HildesheimRooms.university, let h = hildesheimFinder {
            return await h.search(q, page: page, clock: clock)
        }
        let term = Rooms.prefix(Rooms.words(q ?? ""), Rooms.maxQuery)
        let page = max(0, page)
        var out: JSONValue = ["query": .string(term), "count": 0, "page": .number(Double(page)), "pages": 0, "items": [],
                              "stale": false, "message": .null, "source": Rooms.source]
        guard !term.isEmpty else { return out }
        let (entry, stale) = await cachedSearch(term, page: page, clock: clock)
        guard let entry else {
            out["stale"] = true
            out["message"] = "Der Standortfinder ist gerade nicht erreichbar. Versuche es später erneut."
            return out
        }
        let count = entry["count"]?.int ?? 0
        let size = Rooms.data["standortfinder"]?["page_size"]?.int ?? 100
        out["count"] = .number(Double(count))
        out["pages"] = .number(Double(count > 0 ? (count + size - 1) / size : 0))
        out["items"] = .array((entry["data"]?.array ?? []).map(Rooms.place))
        out["stale"] = .bool(stale)
        out["message"] = stale ? .string(Rooms.offline) : .null
        return out
    }

    func resolvePart(_ part: JSONValue, university: String, clock: UniFlowClock) async -> (JSONValue, Bool) {
        var out = part
        out["status"] = "none"; out["place"] = .null; out["candidates"] = []; out["maps"] = .null; out["note"] = .null
        if part["online"]?.bool == true {
            out["status"] = "online"
            return (out, false)
        }
        if university == HildesheimRooms.university, let h = hildesheimFinder {
            return await h.resolvePart(part, clock: clock)
        }
        if university != "luh" {
            let campuses = Rooms.data["universities"]?[university]?["campuses"]?.array ?? []
            if let id = part["campus"]?.string, let c = campuses.first(where: { $0["id"]?.string == id }) {
                let p = Rooms.campusPlace(c, university: university)
                out["status"] = "campus"; out["place"] = p; out["maps"] = p["maps"] ?? .null
            } else {
                out["status"] = "search"; out["maps"] = Rooms.fallback(part, university: university)
            }
            out["note"] = Rooms.data["note_campus"] ?? .null
            return (out, false)
        }
        guard let query = part["query"]?.string else {
            out["status"] = "unknown"; out["maps"] = Rooms.fallback(part, university: university)
            out["note"] = "Keine Raum- oder Gebäudenummer erkannt; der Link sucht nach dem Text."
            return (out, false)
        }
        var (entry, stale) = await cachedSearch(query, page: 0, clock: clock)
        guard let found = entry else {
            out["status"] = "offline"; out["maps"] = Rooms.fallback(part, university: university); out["note"] = .string(Rooms.offlineEmpty)
            return (out, true)
        }
        entry = found
        let (status, hits) = Rooms.choose(part, found["data"]?.array ?? [])
        if status == "not_found", let room = part["room"]?.string, let building = part["building"]?.string {
            let (bEntry, bStale) = await cachedSearch(building, page: 0, clock: clock)
            stale = stale || bStale
            if let bEntry {
                var bPart = part
                bPart["room"] = .null; bPart["floor"] = .null
                let (bStatus, bHits) = Rooms.choose(bPart, bEntry["data"]?.array ?? [])
                if bStatus == "found" {
                    let p = Rooms.place(bHits[0])
                    out["status"] = "building"; out["place"] = p; out["maps"] = p["maps"] ?? .null
                    out["note"] = .string("Raum \(room) steht nicht im Standortfinder; gezeigt wird das Gebäude.")
                    return (out, stale)
                }
            }
        }
        switch status {
        case "found":
            let p = Rooms.place(hits[0])
            out["status"] = "found"; out["place"] = p; out["maps"] = p["maps"] ?? .null
        case "ambiguous":
            out["status"] = "ambiguous"; out["candidates"] = .array(hits.prefix(10).map(Rooms.place))
            out["maps"] = Rooms.fallback(part, university: university)
            out["note"] = .string("\(hits.count) Treffer – bitte den richtigen Ort wählen.")
        default:
            out["status"] = "not_found"; out["maps"] = Rooms.fallback(part, university: university)
            out["note"] = "Im Standortfinder nicht gefunden; der Link sucht nach dem Text."
        }
        return (out, stale)
    }

    /// Antwort von GET /api/rooms/resolve
    public func resolve(_ text: String?, university: String?, clock: UniFlowClock) async -> JSONValue {
        let parsed = Rooms.parse(text, university: university)
        let uni = parsed["university"]?.string ?? "luh"
        var parts: [JSONValue] = []
        var stale = false
        for p in parsed["parts"]?.array ?? [] {
            let (r, s) = await resolvePart(p, university: uni, clock: clock)
            parts.append(r)
            stale = stale || s
        }
        let hasPlace = parts.contains { ["found", "ambiguous", "building"].contains($0["status"]?.string ?? "") }
        let finder = finder(university: uni)
        let source: JSONValue = finder == "standortfinder" ? Rooms.source : finder == "lsf" ? HildesheimRooms.source : .null
        let offline = finder == "lsf" ? HildesheimRooms.offline : Rooms.offline
        let offlineEmpty = finder == "lsf" ? HildesheimRooms.offlineEmpty : Rooms.offlineEmpty
        return ["text": parsed["text"] ?? "", "university": .string(uni), "parts": .array(parts),
                "source": source, "stale": .bool(stale),
                "message": stale ? .string(hasPlace ? offline : offlineEmpty) : .null]
    }

    /// Antwort von GET /api/rooms/campuses: Standorte; Hildesheim mit LSF-Leser dazu `finder: true`, Quelle und alle
    /// Gebaeude des LSF (`buildings`)
    public func campuses(university: String?) -> JSONValue {
        var out = Rooms.campuses(university: university)
        if out["university"]?.string == HildesheimRooms.university, hildesheimFinder != nil {
            out["finder"] = true
            out["note"] = .null
            out["source"] = HildesheimRooms.source
            out["buildings"] = .array(HildesheimRooms.buildingPlaces())
        }
        return out
    }
}

/// Raumfinder auf dem Geraet (frei in jedem Tarif):
/// - `GET /api/rooms/search?q=&page=[&university=]`: Suche im Standortfinder der LUH bzw. im Raumplan des LSF (Hildesheim)
/// - `GET /api/rooms/resolve?text=&university=`: Raumangabe aufloesen (Stundenplan, Lernkalender, Klausuren)
/// - `GET /api/rooms/campuses[?university=]`: Standorte der Hochschule mit Kartenlinks (Hildesheim: dazu alle Gebaeude)
/// - `GET /api/rooms/place?rgid=`: ein Raum des LSF Hildesheim mit Gebaeude, Etage, Raumart, Adresse
/// - `GET /api/rooms/plan?rgid=&week=`: Belegung eines Raums des LSF Hildesheim in einer Woche ("45_2026")
public enum RoomsEndpoints: LocalEndpointModule {
    public static let name = "Raumfinder"

    static func university(_ req: LocalRequest, _ ctx: LocalContext) async throws -> String {
        if let q = req.query("university"), !q.isEmpty { return q }
        return try await MensaEndpoints.university(ctx)
    }

    static func rgid(_ req: LocalRequest) throws -> Int {
        guard let v = Int(req.query("rgid") ?? ""), v > 0 else { throw LocalHTTPError(status: 422, message: "rgid: ganze Zahl erwartet") }
        return v
    }

    static func hildesheim(_ ctx: LocalContext) throws -> HildesheimRoomFinder {
        guard let h = ctx.rooms.hildesheimFinder else { throw LocalHTTPError(status: 404, message: "Kein Raumplan für diese Hochschule") }
        return h
    }

    public static func register(on router: LocalRouter) {
        router.get("/api/rooms/search") { req, ctx in
            .json(await ctx.rooms.search(req.query("q"), page: Int(req.query("page") ?? "") ?? 0, clock: ctx.clock,
                                         university: try await university(req, ctx)))
        }
        router.get("/api/rooms/resolve") { req, ctx in
            .json(await ctx.rooms.resolve(req.query("text"), university: try await university(req, ctx), clock: ctx.clock))
        }
        router.get("/api/rooms/campuses") { req, ctx in
            .json(ctx.rooms.campuses(university: try await university(req, ctx)))
        }
        router.get("/api/rooms/place") { req, ctx in
            .json(await try hildesheim(ctx).place(rgid: try rgid(req), clock: ctx.clock))
        }
        router.get("/api/rooms/plan") { req, ctx in
            .json(await try hildesheim(ctx).plan(rgid: try rgid(req), week: req.query("week"), clock: ctx.clock))
        }
    }
}

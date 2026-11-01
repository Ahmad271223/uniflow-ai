import Foundation

/// Anfragen an `/api/community` mit der Sitzung des Kontos; wirft `AccountError` (App: `StudoraAccount`)
public protocol CommunityTransport: Sendable {
    func community(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue
}

extension StudoraAccount: CommunityTransport {
    public func community(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue {
        let r = try await request(method, "/api/community" + path, body: body)
        return (try? JSONValue.parse(r.body)) ?? .null
    }
}

/// Community ueber den Studora-Dienst (Vertrag G4, app/community_api.py), so wie Web und Windows sie nutzen.
///
/// Der Dienst kennt keine Sichtbarkeit, keine Kurs-Schluessel und keine Lerngruppen: Eine Loesung sieht jedes Konto
/// derselben Hochschule, das dieselbe PDF aus dem eigenen Abgleich gemeldet hat (`/claims`). Darum gibt es hier nur
/// `Modul` (mit Pseudonym oder leer), und eine Veroeffentlichung fuer eine Lerngruppe scheitert, statt still fuer alle
/// sichtbar zu werden. Die Kursansicht fragt je Fingerabdruck des Kurses einzeln.
public final class ServiceCommunityService: CommunityService, @unchecked Sendable {
    /// `community.MAX_CLAIMS`
    public static let maxClaims = 5_000

    private let transport: CommunityTransport
    /// Fingerabdruecke der PDFs aus dem eigenen Abgleich (`service_link.local_fingerprints`)
    private let localFingerprints: @Sendable () async -> [String]
    /// Fingerabdruecke der Dateien eines Kurs-Schluessels
    private let courseFingerprints: @Sendable (String) async -> [String]
    private let lock = NSLock()
    /// Sperren geht beim Dienst ueber eine Loesung des Autors: letzte gesehene je Pseudonym
    private var lastSolution: [String: String] = [:]

    public init(transport: CommunityTransport, localFingerprints: @escaping @Sendable () async -> [String],
                courseFingerprints: @escaping @Sendable (String) async -> [String]) {
        self.transport = transport
        self.localFingerprints = localFingerprints
        self.courseFingerprints = courseFingerprints
    }

    public var isConnected: Bool { true }
    public var isAccountService: Bool { true }

    // MARK: Anfragen

    static func serviceError(_ error: Error) -> Error {
        guard let e = error as? AccountError else { return error }
        switch (e.status, e.code) {
        case (0, _): return CommunityServiceError.offline
        case (401, _): return CommunityServiceError.accountRequired
        case (404, _): return CommunityServiceError.notFound
        case (_, "not_owner"): return CommunityServiceError.notOwner
        case (_, "file_not_owned"): return CommunityServiceError.fileNotOwned
        default: return CommunityServiceError.server(e.message)
        }
    }

    private func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        do { return try await transport.community(method, path, body: body) } catch { throw Self.serviceError(error) }
    }

    /// Weiss der Dienst nichts von der PDF, einmal alle eigenen melden und die Anfrage wiederholen
    private func withClaims(_ op: () async throws -> JSONValue) async throws -> JSONValue {
        do { return try await op() } catch let e as AccountError where e.code == "file_not_owned" {
            let fps = await localFingerprints()
            guard !fps.isEmpty else { throw Self.serviceError(e) }
            _ = try await call("POST", "/claims", body: .object(["fingerprints": .array(fps.map(JSONValue.string))]))
            do { return try await op() } catch { throw Self.serviceError(error) }
        } catch { throw Self.serviceError(error) }
    }

    private static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func summary(_ s: JSONValue) -> CommunitySolutionSummary? {
        guard let id = s["solution_id"]?.string, let fp = s["fingerprint"]?.string else { return nil }
        let owner = s["pseudonym"]?.string ?? ""
        return CommunitySolutionSummary(solutionID: id, fingerprint: fp, displayName: s["display_name"]?.string ?? "",
                                        createdAt: s["created_at"]?.string ?? "", pageCount: s["page_count"]?.int ?? 0,
                                        title: s["title"]?.string ?? "", ownerRecordName: owner, isOwn: s["mine"]?.bool ?? false)
    }

    private func solutions(_ fingerprint: String) async throws -> [CommunitySolutionSummary] {
        let path = "/solutions?fingerprint=" + Self.query(fingerprint.lowercased())
        let list = (try await withClaims { try await transport.community("GET", path, body: nil) })["solutions"]?.array ?? []
        let out = list.compactMap(summary)
        lock.withLock { for s in out where !s.isOwn && !s.ownerRecordName.isEmpty { lastSolution[s.ownerRecordName] = s.solutionID } }
        return out
    }

    // MARK: CommunityService

    public func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        guard options.visibility == .module else { throw CommunityServiceError.visibilityUnsupported }
        let body = JSONValue.object(["package": try JSONValue.parse(package.encoded()), "title": .string(options.title)])
        let r = try await withClaims { try await transport.community("POST", "/solutions", body: body) }
        guard let id = r["solution_id"]?.string else { throw CommunityServiceError.server("Antwort ohne Kennung.") }
        return CommunityPublication(solutionID: id, publishedAt: r["published_at"]?.string.flatMap(SolutionValidator.parseDate) ?? Date())
    }

    public func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] {
        try await solutions(fingerprint)
    }

    public func findForCourse(courseKey: String) async throws -> [CommunitySolutionSummary] {
        var seen = Set<String>(), out: [CommunitySolutionSummary] = []
        for fp in Set(await courseFingerprints(courseKey).map { $0.lowercased() }).sorted() {
            do {
                for s in try await solutions(fp) where seen.insert(s.solutionID).inserted { out.append(s) }
            } catch CommunityServiceError.fileNotOwned { continue }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    public func download(solutionID: String) async throws -> SolutionPackage {
        let path = "/solutions/" + Self.query(solutionID)
        let r = try await withClaims { try await transport.community("GET", path, body: nil) }
        guard let p = r["package"] else { throw CommunityServiceError.notFound }
        return try SolutionPackage.decode(p.serialized())
    }

    public func withdraw(solutionID: String) async throws {
        _ = try await call("DELETE", "/solutions/" + Self.query(solutionID))
    }

    public func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {
        var body: [String: JSONValue] = ["reason": .string(reason.rawValue)]
        if let note { body["note"] = .string(note) }
        _ = try await call("POST", "/solutions/\(Self.query(solutionID))/report", body: .object(body))
    }

    public func block(owner: String) async throws {
        guard let id = lock.withLock({ lastSolution[owner] }) else { throw CommunityServiceError.notFound }
        _ = try await call("POST", "/solutions/\(Self.query(id))/block")
    }

    public func unblock(owner: String) async throws {
        _ = try await call("DELETE", "/blocks/" + Self.query(owner))
    }

    public func blockedOwners() async throws -> [String] {
        (try await call("GET", "/blocks"))["blocked"]?.array?.compactMap(\.string) ?? []
    }

    public func createStudyGroup(name: String) async throws -> CommunityStudyGroup { throw CommunityServiceError.visibilityUnsupported }
    public func joinStudyGroup(code: String) async throws -> CommunityStudyGroup { throw CommunityServiceError.visibilityUnsupported }
    public func leaveStudyGroup(code: String) async throws {}
    public func studyGroups() async throws -> [CommunityStudyGroup] { [] }
}

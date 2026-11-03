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

/// Lerngruppen dieses Geraets (Code, Name); der Code bleibt hier, der Dienst kennt nur den Schluessel
public protocol CommunityGroupStore: Sendable {
    func groups() -> [CommunityStudyGroup]
    func add(_ group: CommunityStudyGroup)
    func remove(code: String)
}

/// Community ueber den StudiNow-Dienst (Vertrag G4, app/community_api.py), so wie Web und Windows sie nutzen.
///
/// Jeder Kurs ist eine Community, dazu Lerngruppen. Beitreten kann ein Konto Kursen, die dieses Geraet gemeldet hat
/// (`/claims`), Lerngruppen ueber den Code. Loesungen sehen nur Mitglieder, auch ohne die PDF. Kurs-IDs und Codes
/// bleiben auf dem Geraet, der Dienst kennt nur die Schluessel.
public final class ServiceCommunityService: CommunityService, @unchecked Sendable {
    /// `community.MAX_CLAIMS`
    public static let maxClaims = 5_000

    private let transport: CommunityTransport
    /// Fingerabdruecke der PDFs aus dem eigenen Abgleich (`service_link.local_fingerprints`)
    private let localFingerprints: @Sendable () async -> [String]
    /// Kurse aus dem eigenen Abgleich, je als Community
    private let localCourses: @Sendable () async -> [CommunitySpace]
    private let university: String
    private let membership: CommunityGroupStore
    private let lock = NSLock()
    /// Sperren geht beim Dienst ueber eine Loesung des Autors: letzte gesehene je Pseudonym
    private var lastSolution: [String: String] = [:]

    public init(transport: CommunityTransport, university: String, membership: CommunityGroupStore,
                localFingerprints: @escaping @Sendable () async -> [String],
                localCourses: @escaping @Sendable () async -> [CommunitySpace]) {
        self.transport = transport
        self.university = university
        self.membership = membership
        self.localFingerprints = localFingerprints
        self.localCourses = localCourses
    }

    public var isConnected: Bool { true }
    public var isAccountService: Bool { true }

    // MARK: Anfragen

    /// `report`: Anfrage war eine Meldung; dann ist 429 `rate_limited` die Tagesgrenze `report_user`
    static func serviceError(_ error: Error, report: Bool = false) -> Error {
        guard let e = error as? AccountError else { return error }
        switch (e.status, e.code) {
        case (0, _): return CommunityServiceError.offline
        case (401, _): return CommunityServiceError.accountRequired
        case (404, "group_not_found"): return CommunityServiceError.groupNotFound
        case (404, _): return CommunityServiceError.notFound
        case (_, "not_owner"): return CommunityServiceError.notOwner
        case (_, "file_not_owned"): return CommunityServiceError.fileNotOwned
        case (_, "not_a_member"): return CommunityServiceError.notAMember
        case (_, "email_unverified"): return CommunityServiceError.emailUnverified
        case (_, "rate_limited") where report: return CommunityServiceError.service(ServiceErrorText.reportLimit(retryAfter: e.retryAfter))
        case (_, "rate_limited"): return CommunityServiceError.service(e.userMessage)
        default:
            // Texte bekannter Codes stehen in ServiceErrorText, sonst die Meldung des Dienstes
            return ServiceErrorText.known(code: e.code) != nil ? CommunityServiceError.service(e.userMessage) : CommunityServiceError.server(e.message)
        }
    }

    private func call(_ method: String, _ path: String, body: JSONValue? = nil, report: Bool = false) async throws -> JSONValue {
        do { return try await transport.community(method, path, body: body) } catch { throw Self.serviceError(error, report: report) }
    }

    private static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func summary(_ s: JSONValue) -> CommunitySolutionSummary? {
        guard let id = s["solution_id"]?.string, let fp = s["fingerprint"]?.string else { return nil }
        var out = CommunitySolutionSummary(solutionID: id, fingerprint: fp, displayName: s["display_name"]?.string ?? "",
                                        createdAt: s["created_at"]?.string ?? "", pageCount: s["page_count"]?.int ?? 0,
                                        title: s["title"]?.string ?? "", ownerRecordName: s["pseudonym"]?.string ?? "",
                                        isOwn: s["mine"]?.bool ?? false, communityKey: s["community_key"]?.string)
        out.likes = s["likes"]?.int ?? 0
        out.likedByMe = s["liked_by_me"]?.bool ?? false
        out.commentCount = s["comments"]?.int ?? 0
        return out
    }

    static func comment(_ c: JSONValue) -> CommunityComment? {
        guard let id = c["id"]?.string else { return nil }
        let anchor = c["anchor"]?["x"]?.double.flatMap { x in c["anchor"]?["y"]?.double.map { CommunityComment.Anchor(x: x, y: $0) } }
        return CommunityComment(id: id, parentID: c["parent_id"]?.string, pseudonym: c["pseudonym"]?.string ?? "", pageKey: c["page_key"]?.string,
                                anchor: anchor, text: c["text"]?.string ?? "", deleted: c["deleted"]?.bool ?? false, createdAt: c["created_at"]?.string ?? "",
                                edited: c["edited_at"]?.string != nil, isMine: c["mine"]?.bool ?? false, byAuthor: c["by_author"]?.bool ?? false)
    }

    private func summaries(_ r: JSONValue) -> [CommunitySolutionSummary] {
        let out = (r["solutions"]?.array ?? []).compactMap(summary)
        lock.withLock { for s in out where !s.isOwn && !s.ownerRecordName.isEmpty { lastSolution[s.ownerRecordName] = s.solutionID } }
        return out
    }

    /// Kurse und PDFs des Geraets melden, damit der Dienst den Beitritt zulaesst
    private func claim(_ courses: [CommunitySpace]) async throws {
        let fps = await localFingerprints()
        _ = try await call("POST", "/claims", body: .object(["fingerprints": .array(fps.map(JSONValue.string)),
                                                             "course_keys": .array(courses.prefix(Self.maxClaims).map { .string($0.key) })]))
    }

    // MARK: Communities

    public func communities() async throws -> [CommunitySpace] {
        let courses = await localCourses()
        try await claim(courses)
        let rows = (try await call("GET", "/communities"))["communities"]?.array ?? []
        var byKey: [String: JSONValue] = [:]
        for r in rows { if let k = r["community_key"]?.string { byKey[k] = r } }
        func merged(_ s: CommunitySpace) -> CommunitySpace {
            var s = s
            s.joined = byKey[s.key]?["joined"]?.bool ?? s.joined
            s.members = byKey[s.key]?["members"]?.int
            s.solutions = byKey[s.key]?["solutions"]?.int
            return s
        }
        return courses.map(merged) + membership.groups().filter { byKey[$0.groupKey]?["joined"]?.bool == true }.map { merged(.group($0)) }
    }

    public func join(_ space: CommunitySpace) async throws {
        _ = try await call("POST", "/communities/\(space.key)/join", body: .object(["kind": .string(space.kind.rawValue)]))
    }

    public func leave(_ space: CommunitySpace) async throws {
        _ = try await call("DELETE", "/communities/\(space.key)/join")
    }

    public func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] {
        summaries(try await call("GET", "/communities/\(space.key)/solutions"))
    }

    // MARK: CommunityService

    public func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        guard let key = options.communityKey, package.header.isCommunityPackage else { throw CommunityServiceError.visibilityUnsupported }
        let body = JSONValue.object(["package": try JSONValue.parse(package.encoded()), "title": .string(options.title), "community_key": .string(key)])
        let r: JSONValue
        do { r = try await transport.community("POST", "/solutions", body: body) } catch let e as AccountError where e.code == "already_published" {
            // 409 nennt die vorhandene Loesung; die Kennung steht auch in /mine (die Fehlerform traegt keine Zusatzfelder)
            guard let own = try await ownSolution(fingerprint: package.header.fingerprint, communityKey: key) else { throw Self.serviceError(e) }
            throw CommunityServiceError.alreadyPublished(own.solutionID)
        } catch { throw Self.serviceError(error) }
        guard let id = r["solution_id"]?.string else { throw CommunityServiceError.server("Antwort ohne Kennung.") }
        return CommunityPublication(solutionID: id, publishedAt: r["published_at"]?.string.flatMap(SolutionValidator.parseDate) ?? Date())
    }

    /// Eigene Loesung zu PDF und Community aus `/mine` (aktiv oder verborgen, die zuletzt veroeffentlichte)
    public func ownSolution(fingerprint: String, communityKey: String) async throws -> CommunitySolutionSummary? {
        let rows = (try await call("GET", "/mine"))["solutions"]?.array ?? []
        let fp = fingerprint.lowercased()
        return rows.filter { $0["fingerprint"]?.string == fp && $0["community_key"]?.string == communityKey
                             && ["active", "hidden"].contains($0["status"]?.string ?? "") }
            .max { ($0["published_at"]?.string ?? "") < ($1["published_at"]?.string ?? "") }
            .flatMap(summary)
    }

    /// PUT /solutions/{id}: Paket der eigenen Loesung ersetzen
    public func update(solutionID: String, package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        guard let key = options.communityKey, package.header.isCommunityPackage else { throw CommunityServiceError.visibilityUnsupported }
        let body = JSONValue.object(["package": try JSONValue.parse(package.encoded()), "title": .string(options.title), "community_key": .string(key)])
        let r = try await call("PUT", "/solutions/" + Self.query(solutionID), body: body)
        return CommunityPublication(solutionID: r["solution_id"]?.string ?? solutionID,
                                    publishedAt: r["updated_at"]?.string.flatMap(SolutionValidator.parseDate) ?? Date())
    }

    /// Loesungen zu einer PDF aus den eigenen Communities
    public func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] {
        do {
            return summaries(try await transport.community("GET", "/solutions?fingerprint=" + Self.query(fingerprint.lowercased()), body: nil))
        } catch let e as AccountError where e.code == "file_not_owned" {
            return []                                                    // noch in keiner Community und keine eigene PDF
        } catch { throw Self.serviceError(error) }
    }

    public func findForCourse(courseKey: String) async throws -> [CommunitySolutionSummary] {
        do { return summaries(try await transport.community("GET", "/communities/\(courseKey)/solutions", body: nil)) } catch let e as AccountError where e.code == "not_a_member" {
            return []
        } catch { throw Self.serviceError(error) }
    }

    public func download(solutionID: String) async throws -> SolutionPackage {
        let r = try await call("GET", "/solutions/" + Self.query(solutionID))
        guard let p = r["package"] else { throw CommunityServiceError.notFound }
        return try SolutionPackage.decode(p.serialized())
    }

    public func withdraw(solutionID: String) async throws {
        _ = try await call("DELETE", "/solutions/" + Self.query(solutionID))
    }

    public func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {
        var body: [String: JSONValue] = ["reason": .string(reason.rawValue)]
        if let note { body["note"] = .string(note) }
        _ = try await call("POST", "/solutions/\(Self.query(solutionID))/report", body: .object(body), report: true)
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

    // MARK: Kommentare und Likes

    public func comments(solutionID: String) async throws -> [CommunityComment] {
        ((try await call("GET", "/solutions/\(Self.query(solutionID))/comments"))["comments"]?.array ?? []).compactMap(Self.comment)
    }

    public func addComment(solutionID: String, text: String, parentID: String?, pageKey: String?, anchor: CommunityComment.Anchor?) async throws -> CommunityComment {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let parentID { body["parent_id"] = .string(parentID) }
        if let pageKey { body["page_key"] = .string(pageKey) }
        if let anchor { body["anchor"] = .object(["x": .number(anchor.x), "y": .number(anchor.y)]) }
        guard let c = Self.comment(try await call("POST", "/solutions/\(Self.query(solutionID))/comments", body: .object(body))) else {
            throw CommunityServiceError.server("Antwort ohne Kennung.")
        }
        return c
    }

    public func editComment(id: String, text: String) async throws -> CommunityComment {
        guard let c = Self.comment(try await call("PATCH", "/comments/\(Self.query(id))", body: .object(["text": .string(text)]))) else {
            throw CommunityServiceError.server("Antwort ohne Kennung.")
        }
        return c
    }

    public func deleteComment(id: String) async throws {
        _ = try await call("DELETE", "/comments/\(Self.query(id))")
    }

    public func reportComment(id: String, reason: CommunityReportReason) async throws {
        _ = try await call("POST", "/comments/\(Self.query(id))/report", body: .object(["reason": .string(reason.rawValue)]), report: true)
    }

    public func setLiked(solutionID: String, _ liked: Bool) async throws -> Int {
        (try await call(liked ? "POST" : "DELETE", "/solutions/\(Self.query(solutionID))/like"))["likes"]?.int ?? 0
    }

    // MARK: Lerngruppen

    public func createStudyGroup(name: String) async throws -> CommunityStudyGroup {
        guard let clean = CommunityRules.validGroupName(name) else { throw CommunityServiceError.invalidGroupName }
        let group = CommunityStudyGroup(code: CommunityKeys.randomGroupCode(), name: clean, university: university)
        _ = try await call("POST", "/groups", body: .object(["group_key": .string(group.groupKey), "name": .string(clean)]))
        membership.add(group)
        return group
    }

    public func joinStudyGroup(code raw: String) async throws -> CommunityStudyGroup {
        guard let code = CommunityKeys.normalizedGroupCode(raw) else { throw CommunityServiceError.invalidGroupCode }
        let key = CommunityKeys.groupKey(university: university, code: code)
        _ = try await call("POST", "/communities/\(key)/join", body: .object(["kind": "group"]))
        let rows = (try await call("GET", "/communities"))["communities"]?.array ?? []
        let name = rows.first { $0["community_key"]?.string == key }?["name"]?.string ?? code
        let group = CommunityStudyGroup(code: code, name: name, university: university)
        membership.add(group)
        return group
    }

    public func studyGroupName(code raw: String) async throws -> String {
        guard let code = CommunityKeys.normalizedGroupCode(raw) else { throw CommunityServiceError.invalidGroupCode }
        let key = CommunityKeys.groupKey(university: university, code: code)
        guard let name = (try await call("GET", "/groups/\(key)"))["name"]?.string else { throw CommunityServiceError.groupNotFound }
        return name
    }

    public func leaveStudyGroup(code raw: String) async throws {
        guard let code = CommunityKeys.normalizedGroupCode(raw) else { return }
        _ = try await call("DELETE", "/communities/\(CommunityKeys.groupKey(university: university, code: code))/join")
        membership.remove(code: code)
    }

    public func studyGroups() async throws -> [CommunityStudyGroup] { membership.groups() }
}

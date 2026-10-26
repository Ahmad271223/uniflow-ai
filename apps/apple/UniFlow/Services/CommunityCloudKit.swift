import Foundation
import UniFlowCore

// Community ueber die oeffentliche CloudKit-Datenbank (docs/LOESUNGEN-TEILEN.md, Abschnitt 7; Entscheidung des
// Inhabers vom 26.10.2026: CloudKit fuer V1, spaeter Supabase – darum alles hinter `CommunityService`).
//
// Datensaetze (oeffentlich): `Solution` (Kopfdaten + verschluesseltes Paket als Asset, ohne Original-PDF),
// `Report` (Meldung), `StudyGroup` (Lerngruppe: Gruppen-Schluessel, Name, Hochschule). Privat: `Block` (eigene
// Sperrliste). Es gehen nie Apple-ID, Name, E-Mail oder Matrikelnummer an den Dienst; `ownerRecordName` ist die
// CloudKit-Nutzerkennung und dient nur dem Zurueckziehen, Melden und Blockieren.
//
// Sichtbarkeit: `CommunityRules` (Kern). Kurs-Schluessel entstehen aus den Kurs-IDs der lokalen Datenbank
// (`CommunityCourses`); wer die Kurs-ID nicht kennt, findet nichts. Lerngruppen: Mitgliedschaft = Kenntnis des
// Codes, gemerkt je Container (`CommunityMembership`).

/// Lerngruppen und Sperrliste (Zwischenspeicher) dieses Containers in seiner Einstellungs-Suite.
final class CommunityMembership: @unchecked Sendable {
    static let groupsKey = "uniflow.community.groups"
    static let blockedKey = "uniflow.community.blocked"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults?) { self.defaults = defaults }

    func groups() -> [CommunityStudyGroup] {
        lock.withLock {
            (defaults?.array(forKey: Self.groupsKey) as? [[String: String]] ?? []).compactMap { d in
                guard let code = d["code"], let name = d["name"], let uni = d["university"] else { return nil }
                return CommunityStudyGroup(code: code, name: name, university: uni)
            }
        }
    }

    func add(_ g: CommunityStudyGroup) {
        var list = groups().filter { $0.code != g.code }
        list.append(g)
        write(list)
    }

    func remove(code: String) { write(groups().filter { $0.code != code }) }

    private func write(_ list: [CommunityStudyGroup]) {
        lock.withLock {
            defaults?.set(list.map { ["code": $0.code, "name": $0.name, "university": $0.university] }, forKey: Self.groupsKey)
        }
    }

    func blocked() -> Set<String> { lock.withLock { Set(defaults?.stringArray(forKey: Self.blockedKey) ?? []) } }

    func setBlocked(_ owners: Set<String>) { lock.withLock { defaults?.set(owners.sorted(), forKey: Self.blockedKey) } }
}

/// Kurse und Dateien aus der lokalen Datenbank des Containers (nur lesen).
enum CommunityCourses {
    /// alle Kurs-IDs (Stud.IP bzw. Learnweb) ausser den eigenen Uploads
    static func courseIDs(host: LocalBackendHost) async -> Set<String> {
        guard let backend = try? await host.backend() else { return [] }
        let rows = (try? await backend.context.database.withConnection { c in
            try c.rows("SELECT id FROM courses WHERE id <> '__user__'")
        }) ?? []
        return Set(rows.compactMap { $0["id"]?.string })
    }

    /// Kurs-ID einer Datei; nil bei eigenen Uploads oder unbekannter Datei
    static func courseID(fileID: String, host: LocalBackendHost) async -> String? {
        guard let backend = try? await host.backend() else { return nil }
        let row = try? await backend.context.database.withConnection { c in
            try c.rows("SELECT course_id FROM files WHERE id=?", [.text(fileID)]).first
        }
        guard let id = row?["course_id"]?.string, id != "__user__" else { return nil }
        return id
    }

    /// Lehrwoche einer Datei aus der Modulansicht (`/api/modules/{id}`, dieselbe Einordnung wie im Moduldetail);
    /// 0 = unbekannt
    static func week(fileID: String, moduleID: Int?, api: APIClient) async -> Int {
        guard let moduleID, let d: JSONValue = try? await api.value("/api/modules/\(moduleID)") else { return 0 }
        return week(fileID: fileID, module: d)
    }

    static func week(fileID: String, module d: JSONValue) -> Int {
        for w in d.list("weeks") {
            for group in ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"] {
                if w.list(group).contains(where: { $0.s("id") == fileID }) { return max(0, w.i("week") ?? 0) }
            }
        }
        return 0
    }
}

/// CloudKit-Umsetzung des Community-Dienstes. `cloud == nil` = Build ohne iCloud-Container: jeder Aufruf meldet
/// "nicht verfügbar" (kein Absturz, nichts vorgetaeuscht).
final class CloudKitCommunityService: CommunityService, @unchecked Sendable {
    enum Field {
        static let solutionID = "solutionID", fingerprint = "fingerprint", university = "university", courseKey = "courseKey"
        static let visibility = "visibility", groupKey = "groupKey", displayName = "displayName", title = "title"
        static let pageCount = "pageCount", week = "week", createdAt = "createdAt", package = "package"
        static let owner = "ownerRecordName", withdrawn = "withdrawn"
        static let reason = "reason", note = "note", reporter = "reporterRecordName", name = "name"
    }

    static let maxNote = 500

    let cloud: CommunityCloud?
    let university: UniversityKey
    let membership: CommunityMembership
    /// Kurs-IDs der lokalen Datenbank (werden zu Kurs-Schluesseln)
    private let courseIDs: @Sendable () async -> Set<String>
    private let lock = NSLock()
    private var cachedUser: String?

    init(cloud: CommunityCloud?, university: UniversityKey, membership: CommunityMembership,
         courseIDs: @escaping @Sendable () async -> Set<String>) {
        self.cloud = cloud
        self.university = university
        self.membership = membership
        self.courseIDs = courseIDs
    }

    var isConnected: Bool { cloud != nil }

    // MARK: Zugang

    private func available() throws -> CommunityCloud {
        guard let cloud else { throw CommunityServiceError.unavailable }
        return cloud
    }

    /// Fuer Schreibzugriffe: iCloud-Konto vorhanden, eigene Nutzerkennung bekannt
    private func signedIn() async throws -> (CommunityCloud, String) {
        let cloud = try available()
        do {
            switch try await cloud.accountStatus() {
            case .available: break
            case .noAccount, .restricted, .unknown: throw CommunityServiceError.notSignedIn
            }
            let user = try await cloud.userRecordName()
            lock.withLock { cachedUser = user }
            return (cloud, user)
        } catch {
            throw Self.serviceError(error)
        }
    }

    /// Eigene Nutzerkennung, wenn sie sich ohne Fehler holen laesst (Lesen geht auch ohne iCloud-Konto)
    private func ownerName(_ cloud: CommunityCloud) async -> String {
        if let u = lock.withLock({ cachedUser }) { return u }
        guard let u = try? await cloud.userRecordName() else { return "" }
        lock.withLock { cachedUser = u }
        return u
    }

    static func serviceError(_ error: Error) -> CommunityServiceError {
        if let e = error as? CommunityServiceError { return e }
        if let e = error as? CommunityCloudError { return e.serviceError }
        return .server(error.localizedDescription)
    }

    private func viewer(_ cloud: CommunityCloud) async -> CommunityViewer {
        let keys = Set(await courseIDs().map { CommunityKeys.courseKey(university: university.rawValue, courseID: $0) })
        let groups = Set(membership.groups().filter { $0.university == university.rawValue }.map(\.groupKey))
        return CommunityViewer(university: university.rawValue, courseKeys: keys, groupKeys: groups,
                               blockedOwners: membership.blocked(), ownerRecordName: await ownerName(cloud))
    }

    // MARK: Datensaetze

    static func listing(_ r: CommunityRecord) -> CommunityListing? {
        guard r.type == CommunityRecordType.solution, let id = r[Field.solutionID]?.string, let fp = r[Field.fingerprint]?.string,
              let uni = r[Field.university]?.string, let vis = r[Field.visibility]?.string.flatMap(CommunityVisibility.init(rawValue:)) else {
            return nil
        }
        return CommunityListing(solutionID: id.lowercased(), fingerprint: fp, university: uni, courseKey: r[Field.courseKey]?.string ?? "",
                                visibility: vis, groupKey: r[Field.groupKey]?.string ?? "", displayName: r[Field.displayName]?.string ?? "",
                                title: r[Field.title]?.string ?? "", pageCount: r[Field.pageCount]?.int ?? 0, week: r[Field.week]?.int ?? 0,
                                createdAt: r[Field.createdAt]?.string ?? "", ownerRecordName: r[Field.owner]?.string ?? r.creator ?? "",
                                withdrawn: (r[Field.withdrawn]?.int ?? 0) != 0)
    }

    private func summaries(_ records: [CommunityRecord], cloud: CommunityCloud) async -> [CommunitySolutionSummary] {
        let v = await viewer(cloud)
        return CommunityRules.visible(records.compactMap(Self.listing), to: v)
            .map { CommunitySolutionSummary(listing: $0, isOwn: !v.ownerRecordName.isEmpty && $0.ownerRecordName == v.ownerRecordName) }
    }

    // MARK: CommunityService

    func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        try CommunityRules.validate(options)
        if options.visibility == .studyGroup, !membership.groups().contains(where: { $0.groupKey == options.groupKey }) {
            throw CommunityServiceError.groupNotFound
        }
        let (cloud, user) = try await signedIn()
        let h = package.header
        let name = CommunityRules.effectiveDisplayName(h.displayName, visibility: options.visibility)
        // das Paket als Datei fuer das Asset (nur das verschluesselte Paket, keine PDF)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("community-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(SolutionLibrary.fileName(h.solutionID))
        try package.encoded().write(to: file, options: .atomic)
        let now = Date()
        var record = CommunityRecord(type: CommunityRecordType.solution, name: h.solutionID)
        record[Field.solutionID] = .string(h.solutionID)
        record[Field.fingerprint] = .string(h.fingerprint)
        record[Field.university] = .string(university.rawValue)
        record[Field.courseKey] = .string(options.courseKey ?? "")
        record[Field.visibility] = .string(options.visibility.rawValue)
        record[Field.groupKey] = .string(options.visibility == .studyGroup ? (options.groupKey ?? "") : "")
        record[Field.displayName] = .string(name)
        record[Field.title] = .string(String(options.title.prefix(SolutionLimits.maxTitle)))
        record[Field.pageCount] = .int(h.pageCount)
        record[Field.week] = .int(max(0, options.week))
        record[Field.createdAt] = .string(h.createdAt)
        record[Field.package] = .asset(file)
        record[Field.owner] = .string(user)
        record[Field.withdrawn] = .int(0)
        do {
            try await cloud.save(record, in: .publicDB)
        } catch {
            throw Self.serviceError(error)
        }
        return CommunityPublication(solutionID: h.solutionID, publishedAt: now)
    }

    func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] {
        let cloud = try available()
        do {
            let records = try await cloud.query(CommunityQuery(type: CommunityRecordType.solution,
                                                               equals: [Field.fingerprint: .string(fingerprint.lowercased()),
                                                                        Field.university: .string(university.rawValue)]), in: .publicDB)
            return await summaries(records, cloud: cloud)
        } catch {
            throw Self.serviceError(error)
        }
    }

    func findForCourse(courseKey: String) async throws -> [CommunitySolutionSummary] {
        let cloud = try available()
        do {
            let records = try await cloud.query(CommunityQuery(type: CommunityRecordType.solution,
                                                               equals: [Field.courseKey: .string(courseKey),
                                                                        Field.university: .string(university.rawValue)]), in: .publicDB)
            return await summaries(records, cloud: cloud)
        } catch {
            throw Self.serviceError(error)
        }
    }

    func download(solutionID: String) async throws -> SolutionPackage {
        let cloud = try available()
        let record: CommunityRecord?
        do { record = try await cloud.fetch(name: solutionID.lowercased(), type: CommunityRecordType.solution, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
        guard let record, let listing = Self.listing(record), !listing.withdrawn, let url = record[Field.package]?.asset else {
            throw CommunityServiceError.notFound
        }
        guard CommunityRules.isVisible(listing, to: await viewer(cloud)) else { throw CommunityServiceError.notFound }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SolutionLimits.maxPackageBytes else { throw SolutionError.tooLarge }
        let package = try SolutionPackage.decode(try Data(contentsOf: url))
        guard package.header.solutionID == listing.solutionID, package.header.fingerprint == listing.fingerprint else {
            throw SolutionError.conflictingSolution
        }
        return package
    }

    func withdraw(solutionID: String) async throws {
        let (cloud, user) = try await signedIn()
        do {
            guard var record = try await cloud.fetch(name: solutionID.lowercased(), type: CommunityRecordType.solution, in: .publicDB) else {
                throw CommunityServiceError.notFound
            }
            guard (record[Field.owner]?.string ?? record.creator) == user else { throw CommunityServiceError.notOwner }
            record[Field.withdrawn] = .int(1)
            record[Field.package] = nil
            try await cloud.save(record, in: .publicDB)
        } catch {
            throw Self.serviceError(error)
        }
    }

    func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {
        let (cloud, user) = try await signedIn()
        var record = CommunityRecord(type: CommunityRecordType.report, name: "report-" + UUID().uuidString.lowercased())
        record[Field.solutionID] = .string(solutionID.lowercased())
        record[Field.reason] = .string(reason.rawValue)
        record[Field.note] = .string(String((note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNote)))
        record[Field.reporter] = .string(user)
        record[Field.createdAt] = .string(SolutionPackage.timestamp(Date()))
        do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
    }

    func block(owner: String) async throws {
        guard !owner.isEmpty else { return }
        let (cloud, _) = try await signedIn()
        var record = CommunityRecord(type: CommunityRecordType.block, name: "block-" + owner)
        record[Field.owner] = .string(owner)
        record[Field.createdAt] = .string(SolutionPackage.timestamp(Date()))
        do { try await cloud.save(record, in: .privateDB) } catch { throw Self.serviceError(error) }
        membership.setBlocked(membership.blocked().union([owner]))
    }

    func unblock(owner: String) async throws {
        let (cloud, _) = try await signedIn()
        do { try await cloud.delete(name: "block-" + owner, type: CommunityRecordType.block, in: .privateDB) } catch {
            throw Self.serviceError(error)
        }
        membership.setBlocked(membership.blocked().subtracting([owner]))
    }

    /// Sperrliste aus der privaten Datenbank (und im Container gemerkt); ohne Netz die gemerkte
    func blockedOwners() async throws -> [String] {
        let cloud = try available()
        do {
            let records = try await cloud.query(CommunityQuery(type: CommunityRecordType.block, equals: [:]), in: .privateDB)
            let owners = Set(records.compactMap { $0[Field.owner]?.string })
            membership.setBlocked(owners)
            return owners.sorted()
        } catch {
            let e = Self.serviceError(error)
            if e == .offline || e == .notSignedIn { return membership.blocked().sorted() }
            throw e
        }
    }

    func createStudyGroup(name: String) async throws -> CommunityStudyGroup {
        guard let clean = CommunityRules.validGroupName(name) else { throw CommunityServiceError.invalidGroupName }
        let (cloud, user) = try await signedIn()
        let group = CommunityStudyGroup(code: CommunityKeys.randomGroupCode(), name: clean, university: university.rawValue)
        var record = CommunityRecord(type: CommunityRecordType.studyGroup, name: group.groupKey)
        record[Field.groupKey] = .string(group.groupKey)
        record[Field.name] = .string(clean)
        record[Field.university] = .string(university.rawValue)
        record[Field.owner] = .string(user)
        record[Field.createdAt] = .string(SolutionPackage.timestamp(Date()))
        do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
        membership.add(group)
        return group
    }

    func joinStudyGroup(code raw: String) async throws -> CommunityStudyGroup {
        guard let code = CommunityKeys.normalizedGroupCode(raw) else { throw CommunityServiceError.invalidGroupCode }
        let cloud = try available()
        let key = CommunityKeys.groupKey(university: university.rawValue, code: code)
        let record: CommunityRecord?
        do { record = try await cloud.fetch(name: key, type: CommunityRecordType.studyGroup, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
        guard let record, record[Field.university]?.string == university.rawValue, let name = record[Field.name]?.string else {
            throw CommunityServiceError.groupNotFound
        }
        let group = CommunityStudyGroup(code: code, name: name, university: university.rawValue, groupKey: key)
        membership.add(group)
        return group
    }

    func leaveStudyGroup(code raw: String) async throws {
        membership.remove(code: CommunityKeys.normalizedGroupCode(raw) ?? raw)
    }

    func studyGroups() async throws -> [CommunityStudyGroup] {
        membership.groups().filter { $0.university == university.rawValue }
    }
}

// MARK: - Treffer je Dokument (Zwischenspeicher der Sitzung)

/// Treffer von `findMatching` je Fingerabdruck, einmal je Sitzung geholt (nie blockierend; Fehler bleiben still, die
/// Liste im Dokument zeigt sie beim erneuten Laden).
@MainActor
final class CommunityMatches {
    static let shared = CommunityMatches()

    private var cache: [String: [CommunitySolutionSummary]] = [:]
    private var running: [String: Task<[CommunitySolutionSummary], Error>] = [:]

    func cached(_ fingerprint: String) -> [CommunitySolutionSummary]? { cache[fingerprint] }

    /// Treffer holen (aus dem Zwischenspeicher, sonst beim Dienst); `force` holt neu
    func load(fingerprint: String, service: CommunityService, force: Bool = false) async throws -> [CommunitySolutionSummary] {
        if !force, let c = cache[fingerprint] { return c }
        if let t = running[fingerprint] { return try await t.value }
        let t = Task { try await service.findMatching(fingerprint: fingerprint) }
        running[fingerprint] = t
        defer { running[fingerprint] = nil }
        let result = try await t.value
        cache[fingerprint] = result
        return result
    }

    func remove(solutionID: String) {
        for (k, v) in cache { cache[k] = v.filter { $0.solutionID != solutionID } }
    }

    func invalidate() {
        cache = [:]
    }
}

extension SolutionSharing {
    /// Veroeffentlichen: Inhalt und Siegel wie beim Teilen als Datei (abseits des Hauptthreads), Kopie unter "Meine
    /// geteilten Lösungen", dann zum Dienst; danach das Datum merken ("veröffentlicht am …").
    static func publishToCommunity(_ source: SolutionSource, keys: [String], displayName: String, options: CommunityPublishOptions,
                                   service: CommunityService, library: SolutionLibrary = library) async throws -> CommunityPublication {
        let sealed = try await Task.detached(priority: .userInitiated) {
            let built = try SolutionSharing.content(source, keys: keys, displayName: displayName)
            let sealed = try SolutionSharing.package(built, originalPDF: source.originalPDF)
            try library.recordShared(sealed, title: source.title)
            return sealed
        }.value
        let publication = try await service.publish(sealed, options: options)
        try library.setPublished(publication.solutionID, at: publication.publishedAt)
        return publication
    }

    /// Eigene Veroeffentlichung zurueckziehen (Dienst, dann das Datum loeschen; die Kopie bleibt).
    static func withdrawFromCommunity(_ solutionID: String, service: CommunityService, library: SolutionLibrary = library) async throws {
        try await service.withdraw(solutionID: solutionID)
        try library.setPublished(solutionID, at: nil)
        await CommunityMatches.shared.remove(solutionID: solutionID)
    }

    /// Geladenes Paket als Datei ablegen, damit der Import denselben Weg nimmt wie "Lösung importieren …"
    /// (Kopf pruefen, verschluesselt ablegen, mit der eigenen PDF oeffnen, fremde Ebene).
    static func writeDownloaded(_ package: SolutionPackage) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("community-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SolutionLibrary.fileName(package.header.solutionID))
        try package.encoded().write(to: url, options: .atomic)
        return url
    }
}

extension DocumentStore {
    /// "Laden und anzeigen" aus der Community: Paket laden, als Datei ablegen und ueber `importSolution` uebernehmen
    /// (derselbe Weg wie die Datei: fremde Ebene, eigene Notizen unveraendert).
    func importFromCommunity(_ solutionID: String, service: CommunityService, library: SolutionLibrary = SolutionSharing.library) async throws -> SolutionImportResult {
        let package = try await service.download(solutionID: solutionID)
        let url = try SolutionSharing.writeDownloaded(package)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try await importSolution(url, library: library)
    }
}

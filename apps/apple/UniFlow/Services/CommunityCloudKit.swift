import Foundation
import UniFlowCore

// Community ueber die oeffentliche CloudKit-Datenbank (docs/LOESUNGEN-TEILEN.md, Abschnitt 7; Entscheidung des
// Inhabers vom 26.10.2026: CloudKit fuer V1, spaeter Supabase – darum alles hinter `CommunityService`).
//
// Datensaetze (oeffentlich): `Solution` (Kopfdaten + verschluesseltes Paket als Asset, ohne Original-PDF),
// `Report` (Meldung einer Loesung oder mit `commentID` eines Kommentars), `StudyGroup` (Lerngruppe: Gruppen-Schluessel,
// Name, Hochschule), `Comment` (Kommentar, Inhalt verschluesselt) und `Like` (ein Datensatz je Nutzer und Loesung).
// Privat: `Block` (eigene Sperrliste). Es gehen nie Apple-ID, Name, E-Mail oder Matrikelnummer an den Dienst; `ownerRecordName` ist die
// CloudKit-Nutzerkennung und dient nur dem Zurueckziehen, Melden und Blockieren.
//
// Sichtbarkeit: `CommunityRules` (Kern). Kurs-Schluessel entstehen an einer Stelle (`CommunityCourses`) aus den
// Kurs-IDs, Kurstiteln und Modulnamen der lokalen Datenbank; wer weder Kurs-ID noch Kursnamen kennt, findet nichts
// (Entscheidung des Inhabers 26.10.2026: das reicht als Berechtigung). Lerngruppen: Mitgliedschaft = Kenntnis des
// Codes, gemerkt je Container (`CommunityMembership`). Der Besitzer eines Datensatzes ist der Ersteller, den der
// Dienst selbst setzt (nicht faelschbar); das Feld `ownerRecordName` ist nur Anzeige fuer das Dashboard.
// Moderation macht der Inhaber im CloudKit Dashboard: `withdrawn` setzen, Datensatz `Ban` fuer gesperrte Nutzer.

/// Lerngruppen und Sperrliste (Zwischenspeicher) dieses Containers in seiner Einstellungs-Suite.
final class CommunityMembership: CommunityGroupStore, @unchecked Sendable {
    static let groupsKey = "uniflow.community.groups"
    static let joinedKey = "uniflow.community.joined"
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

    /// Beigetretene Kurs-Communities dieses Containers (CloudKit kennt keine Mitgliedschaft: Kenntnis der Kurs-ID)
    func joinedCourses() -> Set<String> { lock.withLock { Set(defaults?.stringArray(forKey: Self.joinedKey) ?? []) } }

    func setJoined(_ key: String, _ joined: Bool) {
        var keys = joinedCourses()
        if joined { keys.insert(key) } else { keys.remove(key) }
        lock.withLock { defaults?.set(keys.sorted(), forKey: Self.joinedKey) }
    }

    func blocked() -> Set<String> { lock.withLock { Set(defaults?.stringArray(forKey: Self.blockedKey) ?? []) } }

    func setBlocked(_ owners: Set<String>) { lock.withLock { defaults?.set(owners.sorted(), forKey: Self.blockedKey) } }
}

/// Kurs-Schluessel aus der lokalen Datenbank des Containers (nur lesen) – die eine Stelle in der App, an der sie
/// gebildet werden (`CommunityKeys` im Kern rechnet). Eine Datei aus dem Abgleich bekommt den Schluessel ihrer
/// Kurs-ID, ein eigenes Dokument den seines Moduls (Name); wer sucht, kennt die Schluessel aller Kurs-IDs,
/// Kurstitel und Modulnamen seiner Datenbank.
enum CommunityCourses {
    /// Community-Schluessel des Suchenden: Module seiner Veranstaltungen und seine Modulnamen, ohne den Pseudokurs der
    /// eigenen Uploads
    static func courseKeys(host: LocalBackendHost, university: String) async -> Set<String> {
        guard let backend = try? await host.backend() else { return [] }
        let rows = (try? await backend.context.database.withConnection { c in
            try (c.rows("SELECT title FROM courses WHERE id <> '__user__'"), c.rows("SELECT name FROM modules"))
        }) ?? ([], [])
        var keys = Set<String>()
        for r in rows.0 {
            if let t = r["title"]?.string, let k = CommunityKeys.moduleKey(university: university, courseTitle: t) { keys.insert(k) }
        }
        for r in rows.1 {
            if let n = r["name"]?.string, let k = CommunityKeys.courseKey(university: university, courseName: n) { keys.insert(k) }
        }
        return keys
    }

    /// PDFs aus dem eigenen Abgleich (`service_link.local_fingerprints`): Dateien mit Quelle, ohne eigene und geloeschte
    private static let syncedPDFs = """
        SELECT f.content_sha256 AS sha, f.course_id AS course_id, c.title AS title, m.name AS module_name FROM files f
        LEFT JOIN courses c ON c.id = f.course_id LEFT JOIN folders fo ON fo.id = f.folder_id LEFT JOIN modules m ON m.id = fo.module_id
        WHERE f.course_id <> '__user__' AND f.download_url IS NOT NULL AND f.download_url <> '' AND f.deleted_at IS NULL
          AND f.content_sha256 IS NOT NULL AND (f.mime LIKE '%pdf' OR lower(f.name) LIKE '%.pdf')
        """

    /// Fingerabdruecke aller eigenen Hochschul-PDFs; hoechstens `ServiceCommunityService.maxClaims` (Grenze des Dienstes)
    static func localFingerprints(host: LocalBackendHost) async -> [String] {
        guard let backend = try? await host.backend() else { return [] }
        let rows = (try? await backend.context.database.withConnection { try $0.rows(syncedPDFs) }) ?? []
        return Array(Set(rows.compactMap { $0["sha"]?.string }).sorted().prefix(ServiceCommunityService.maxClaims))
    }

    /// Eine Community je Modul des Containers (alle Veranstaltungen zusammen), ohne den Pseudokurs der eigenen Uploads
    static func spaces(host: LocalBackendHost, university: String) async -> [CommunitySpace] {
        guard let backend = try? await host.backend() else { return [] }
        let rows = (try? await backend.context.database.withConnection { try $0.rows("SELECT title FROM courses WHERE id <> '__user__' ORDER BY title") }) ?? []
        var seen = Set<String>()
        return rows.compactMap { r in
            guard let t = r["title"]?.string, let space = CommunitySpace.module(university: university, courseTitle: t) else { return nil }
            return seen.insert(space.key).inserted ? space : nil
        }.sorted { $0.name < $1.name }
    }

    /// Lokale Datei zu einem Fingerabdruck, um eine Loesung ueber der eigenen PDF zu zeigen
    static func localFile(fingerprint: String, host: LocalBackendHost) async -> String? {
        guard let backend = try? await host.backend() else { return nil }
        return (try? await backend.context.database.withConnection {
            try $0.scalar("SELECT id FROM files WHERE content_sha256=? AND deleted_at IS NULL AND local_path IS NOT NULL LIMIT 1", [.text(fingerprint)])?.string
        }) ?? nil
    }

    /// Community-Schluessel einer Datei: aus dem Modul ihres Kurses (Abgleich) oder, bei eigenen Dokumenten, aus dem
    /// Namen des Moduls (ueber den Ordner); nil ohne Kurs und Modul oder bei unbekannter Datei
    static func courseKey(fileID: String, host: LocalBackendHost, university: String) async -> String? {
        guard let backend = try? await host.backend() else { return nil }
        let row = try? await backend.context.database.withConnection { c in
            try c.rows("""
                SELECT f.course_id AS course_id, c.title AS course_title, m.name AS module_name FROM files f
                LEFT JOIN courses c ON c.id = f.course_id
                LEFT JOIN folders fo ON fo.id = f.folder_id LEFT JOIN modules m ON m.id = fo.module_id WHERE f.id=?
                """, [.text(fileID)]).first
        }
        guard let row else { return nil }
        if row["course_id"]?.string != "__user__", let t = row["course_title"]?.string,
           let key = CommunityKeys.moduleKey(university: university, courseTitle: t) { return key }
        guard let name = row["module_name"]?.string else { return nil }
        return CommunityKeys.courseKey(university: university, courseName: name)
    }

    /// Community-Schluessel eines Moduls aus seiner Detailansicht (`/api/modules/{id}`): aus den Titeln seiner Kurse und
    /// seinem Namen (eigene Dokumente), ohne Dubletten
    static func courseKeys(module d: JSONValue, university: String) -> [String] {
        var keys: [String] = []
        for c in d.list("courses") where c.s("id") != "__user__" {
            if let t = c.s("title"), let k = CommunityKeys.moduleKey(university: university, courseTitle: t) { keys.append(k) }
        }
        if let name = d["module"]?.s("name"), let k = CommunityKeys.courseKey(university: university, courseName: name) { keys.append(k) }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
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

/// Community ueber das Studora-Konto, solange eines passend angemeldet ist (`StudoraAccountLink`); sonst CloudKit.
/// Bestehende CloudKit-Eintraege werden nicht uebernommen: bisher gab es keinen Build mit iCloud-Container.
final class CommunityRoute: @unchecked Sendable {
    static let shared = CommunityRoute()
    private let lock = NSLock()
    private var account: CommunityService?

    var service: CommunityService? {
        get { lock.withLock { account } }
        set { lock.withLock { account = newValue } }
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
        static let commentID = "commentID", parentID = "parentID", status = "status", editedAt = "editedAt", payload = "payload"
        static let removedID = "removedID", order = "createdOrder"
    }

    static let maxNote = 500
    /// Ersteller-Kennung, die CloudKit fuer eigene Datensaetze zurueckgibt (statt der eigenen Nutzerkennung)
    static let defaultOwner = "__defaultOwner__"
    /// Vom Inhaber gesperrte Nutzer (`Ban`) werden hoechstens so oft neu geholt
    static let banRefresh: TimeInterval = 600

    let cloud: CommunityCloud?
    let university: UniversityKey
    let membership: CommunityMembership
    /// Kurs-Schluessel des Suchenden (`CommunityCourses.courseKeys`)
    private let courseKeys: @Sendable () async -> Set<String>
    /// Kurse aus der lokalen Datenbank (`CommunityCourses.spaces`)
    private let courses: @Sendable () async -> [CommunitySpace]
    /// Pseudonym fuer Kommentare (dasselbe wie beim Teilen, `SolutionDisplayName`); leer = anonym
    let pseudonym: @Sendable () -> String
    private let lock = NSLock()
    private var cachedUser: String?
    private var cachedBans: (owners: Set<String>, at: Date)?

    init(cloud: CommunityCloud?, university: UniversityKey, membership: CommunityMembership,
         courseKeys: @escaping @Sendable () async -> Set<String>, courses: @escaping @Sendable () async -> [CommunitySpace] = { [] },
         pseudonym: @escaping @Sendable () -> String = { "" }) {
        self.cloud = cloud
        self.university = university
        self.membership = membership
        self.courseKeys = courseKeys
        self.courses = courses
        self.pseudonym = pseudonym
    }

    var isConnected: Bool { cloud != nil }
    /// Kommentare und Likes auch ueber CloudKit (03.11.2026)
    var supportsDiscussion: Bool { true }

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

    /// Vom Inhaber im Dashboard gesperrte Nutzer (oeffentlicher Datensatz `Ban`, die App schreibt ihn nie); ohne
    /// Netz die zuletzt geholten, sonst keine
    private func bannedOwners(_ cloud: CommunityCloud) async -> Set<String> {
        if let c = lock.withLock({ cachedBans }), Date().timeIntervalSince(c.at) < Self.banRefresh { return c.owners }
        guard let records = try? await cloud.query(CommunityQuery(type: CommunityRecordType.ban, equals: [:]), in: .publicDB) else {
            return lock.withLock { cachedBans?.owners ?? [] }
        }
        let owners = Set(records.compactMap { $0[Field.owner]?.string }.filter { !$0.isEmpty })
        lock.withLock { cachedBans = (owners, Date()) }
        return owners
    }

    private func viewer(_ cloud: CommunityCloud) async -> CommunityViewer {
        let groups = Set(membership.groups().filter { $0.university == university.rawValue }.map(\.groupKey))
        return CommunityViewer(university: university.rawValue, courseKeys: await courseKeys(), groupKeys: groups,
                               blockedOwners: membership.blocked().union(await bannedOwners(cloud)), ownerRecordName: await ownerName(cloud))
    }

    // MARK: Datensaetze

    /// Besitzer eines Datensatzes: der Ersteller, den der Dienst setzt (nicht faelschbar; fuer eigene Datensaetze
    /// meldet CloudKit `__defaultOwner__`, das ist `me`). Das Feld `ownerRecordName` zaehlt nur, wenn der Dienst
    /// keinen Ersteller liefert (Nachbau in Tests ohne Anmeldung).
    static func owner(_ r: CommunityRecord, me: String) -> String {
        if let c = r.creator, !c.isEmpty { return c == defaultOwner ? me : c }
        return r[Field.owner]?.string ?? ""
    }

    static func listing(_ r: CommunityRecord, me: String) -> CommunityListing? {
        guard r.type == CommunityRecordType.solution, let id = r[Field.solutionID]?.string, let fp = r[Field.fingerprint]?.string,
              let uni = r[Field.university]?.string, let vis = r[Field.visibility]?.string.flatMap(CommunityVisibility.init(rawValue:)) else {
            return nil
        }
        return CommunityListing(solutionID: id.lowercased(), fingerprint: fp, university: uni, courseKey: r[Field.courseKey]?.string ?? "",
                                visibility: vis, groupKey: r[Field.groupKey]?.string ?? "", displayName: r[Field.displayName]?.string ?? "",
                                title: r[Field.title]?.string ?? "", pageCount: r[Field.pageCount]?.int ?? 0, week: r[Field.week]?.int ?? 0,
                                createdAt: r[Field.createdAt]?.string ?? "", ownerRecordName: owner(r, me: me),
                                withdrawn: (r[Field.withdrawn]?.int ?? 0) != 0)
    }

    private func summaries(_ records: [CommunityRecord], cloud: CommunityCloud) async -> [CommunitySolutionSummary] {
        let v = await viewer(cloud)
        let list = CommunityRules.visible(records.compactMap { Self.listing($0, me: v.ownerRecordName) }, to: v)
            .map { CommunitySolutionSummary(listing: $0, isOwn: !v.ownerRecordName.isEmpty && $0.ownerRecordName == v.ownerRecordName) }
        return await withDiscussion(list, cloud: cloud, viewer: v)
    }

    // MARK: CommunityService

    func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        try CommunityRules.validate(options)
        if options.visibility == .studyGroup, !membership.groups().contains(where: { $0.groupKey == options.groupKey }) {
            throw CommunityServiceError.groupNotFound
        }
        let (cloud, user) = try await signedIn()
        let h = package.header
        // eine Loesung je PDF und Community (03.11.2026): die App fragt dann "Aktualisieren?" und ersetzt das Paket
        if let key = Self.communityKey(options), let own = try await ownListing(cloud, user: user, fingerprint: h.fingerprint, communityKey: key),
           own.solutionID != h.solutionID.lowercased() {
            throw CommunityServiceError.alreadyPublished(own.solutionID)
        }
        let name = CommunityRules.effectiveDisplayName(h.displayName, visibility: options.visibility)
        // das Paket als Datei fuer das Asset (nur das verschluesselte Paket, keine PDF), im Zwischenspeicher des
        // Containers (AppTemp: weg nach dem Upload, spaetestens beim naechsten Start)
        let dir = try AppTemp.fresh("community-upload")
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

    /// Community eines Datensatzes: Lerngruppe ueber `groupKey`, sonst der Kurs-Schluessel; anonym gehoert zu keiner
    static func communityKey(_ options: CommunityPublishOptions) -> String? {
        let key = options.communityKey ?? (options.visibility == .studyGroup ? options.groupKey : options.courseKey)
        return options.visibility == .anonymous || (key ?? "").isEmpty ? nil : key
    }

    /// Eigene, nicht zurueckgezogene Loesung zu PDF und Community (Kurs- oder Gruppen-Schluessel); die neueste
    private func ownListing(_ cloud: CommunityCloud, user: String, fingerprint: String, communityKey: String) async throws -> CommunityListing? {
        let records: [CommunityRecord]
        do {
            records = try await cloud.query(CommunityQuery(type: CommunityRecordType.solution,
                                                           equals: [Field.fingerprint: .string(fingerprint.lowercased()),
                                                                    Field.university: .string(university.rawValue)]), in: .publicDB)
        } catch {
            throw Self.serviceError(error)
        }
        return records.compactMap { Self.listing($0, me: user) }
            .filter { $0.ownerRecordName == user && !$0.withdrawn && $0.visibility != .anonymous
                      && ($0.visibility == .studyGroup ? $0.groupKey : $0.courseKey) == communityKey }
            .max { ($0.createdAt, $0.solutionID) < ($1.createdAt, $1.solutionID) }
    }

    func ownSolution(fingerprint: String, communityKey: String) async throws -> CommunitySolutionSummary? {
        let (cloud, user) = try await signedIn()
        return try await ownListing(cloud, user: user, fingerprint: fingerprint, communityKey: communityKey)
            .map { CommunitySolutionSummary(listing: $0, isOwn: true) }
    }

    /// Paket der eigenen Loesung ersetzen: derselbe Datensatz (ID, Sichtbarkeit, Kurs, Erstellungsdatum bleiben),
    /// neues Asset, Seitenzahl, Titel und Pseudonym; das Aenderungsdatum fuehrt CloudKit selbst.
    func update(solutionID: String, package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication {
        let (cloud, user) = try await signedIn()
        let id = solutionID.lowercased(), h = package.header
        guard h.solutionID == id else { throw SolutionError.conflictingSolution }
        let dir = try AppTemp.fresh("community-upload")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            guard var record = try await cloud.fetch(name: id, type: CommunityRecordType.solution, in: .publicDB),
                  let listing = Self.listing(record, me: user), !listing.withdrawn else {
                throw CommunityServiceError.notFound
            }
            guard listing.ownerRecordName == user else { throw CommunityServiceError.notOwner }
            guard listing.fingerprint == h.fingerprint else { throw SolutionError.fingerprintMismatch }
            let file = dir.appendingPathComponent(SolutionLibrary.fileName(id))
            try package.encoded().write(to: file, options: .atomic)
            record[Field.package] = .asset(file)
            record[Field.pageCount] = .int(h.pageCount)
            record[Field.displayName] = .string(CommunityRules.effectiveDisplayName(h.displayName, visibility: listing.visibility))
            if !options.title.isEmpty { record[Field.title] = .string(String(options.title.prefix(SolutionLimits.maxTitle))) }
            try await cloud.save(record, in: .publicDB)
        } catch let e as SolutionError {
            throw e
        } catch {
            throw Self.serviceError(error)
        }
        return CommunityPublication(solutionID: id, publishedAt: Date())
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

    func communities() async throws -> [CommunitySpace] {
        let joined = membership.joinedCourses()
        return await courses().map { var s = $0; s.joined = joined.contains(s.key); return s } + membership.groups().map(CommunitySpace.group)
    }

    func join(_ space: CommunitySpace) async throws { membership.setJoined(space.key, true) }
    func leave(_ space: CommunitySpace) async throws { membership.setJoined(space.key, false) }

    /// Lerngruppen-Loesungen stehen ebenfalls unter `courseKey`: dieses Feld hat in Production den Such-Index
    func solutions(in space: CommunitySpace) async throws -> [CommunitySolutionSummary] {
        guard space.joined else { throw CommunityServiceError.notAMember }
        return try await findForCourse(courseKey: space.key)
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
        let v = await viewer(cloud)
        guard let record, let listing = Self.listing(record, me: v.ownerRecordName), !listing.withdrawn, let url = record[Field.package]?.asset else {
            throw CommunityServiceError.notFound
        }
        guard CommunityRules.isVisible(listing, to: v) else { throw CommunityServiceError.notFound }
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
            guard Self.owner(record, me: user) == user else { throw CommunityServiceError.notOwner }
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

    func studyGroupName(code raw: String) async throws -> String {
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
        return name
    }

    func leaveStudyGroup(code raw: String) async throws {
        membership.remove(code: CommunityKeys.normalizedGroupCode(raw) ?? raw)
    }

    func studyGroups() async throws -> [CommunityStudyGroup] {
        membership.groups().filter { $0.university == university.rawValue }
    }
}

// MARK: - Kommentare und Likes (03.11.2026)

// Wie app/community.py (Likes, Kommentare): Kommentare mit Antworten (eine Ebene), Stelle auf einer Seite, eigene
// bearbeiten und loeschen, fremde melden; ein Like je Nutzer, nicht fuer die eigene Loesung.
//
// Oeffentliche Datenbank: nur der Ersteller aendert oder loescht einen Datensatz. Darum
// - `Like`: ein Datensatz je Nutzer (Ersteller); Anzahl = verschiedene Ersteller zur Loesung (Abfrage, kein Zaehler).
// - `Comment`: Kopf im Klartext (Loesung, Antwort auf, Status, Zeitpunkte), Text, Pseudonym, Seite und Stelle nur
//   verschluesselt (`payload`, `CommunityDiscussion.seal` mit dem Geheimnis der Community).
// - Der Autor der Loesung entfernt fremde Kommentare mit einem eigenen `Comment`-Datensatz (Status `removal`,
//   `removedID`); er zaehlt nur, wenn sein Ersteller der Ersteller der Loesung ist.
// - Meldungen sind `Report`-Datensaetze mit `commentID`; ab `CommunityDiscussion.reportsToHide` verschiedenen Meldern ist
//   der Kommentar ausgeblendet, die Moderation setzt im Dashboard `status` = `hidden`.
// Grenzen: Tageslimits des Dienstes (comment_user, like_user) gibt es ohne Server nicht; Zahlen kommen aus Abfragen
// (der Index von CloudKit ist leicht verzoegert).
extension CloudKitCommunityService {
    static let removalStatus = "removal"
    /// so viele Loesungen je Abfrage (`IN`) fuer die Zahlen der Trefferliste
    static let countChunk = 100
    /// Obergrenze je Abfrage fuer Kommentare und Likes einer Loesung
    static let discussionLimit = 5_000

    /// Loesung, die dieses Geraet sehen darf (aktiv und sichtbar) oder die eigene (`_visible_solution`)
    private func visibleSolution(_ cloud: CommunityCloud, id: String) async throws -> (CommunityListing, CommunityViewer) {
        let record: CommunityRecord?
        do { record = try await cloud.fetch(name: id.lowercased(), type: CommunityRecordType.solution, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
        let v = await viewer(cloud)
        guard let record, let listing = Self.listing(record, me: v.ownerRecordName) else { throw CommunityServiceError.notFound }
        let own = !v.ownerRecordName.isEmpty && listing.ownerRecordName == v.ownerRecordName
        guard own || CommunityRules.isVisible(listing, to: v) else { throw CommunityServiceError.notFound }
        return (listing, v)
    }

    /// Geheimnis der Community einer Loesung (Lerngruppe oder Kurs, wie beim Paket); ohne die Community kein Kommentar
    private func secret(_ listing: CommunityListing) async throws -> Data {
        let spaces = (try? await communities()) ?? []
        let keys = [listing.visibility == .studyGroup ? listing.groupKey : listing.courseKey, listing.courseKey, listing.groupKey]
        for key in keys where !key.isEmpty {
            if let s = spaces.first(where: { $0.key == key })?.secret { return s }
        }
        throw CommunityServiceError.notAMember
    }

    private func query(_ cloud: CommunityCloud, _ q: CommunityQuery) async throws -> [CommunityRecord] {
        do { return try await cloud.query(q, in: .publicDB) } catch { throw Self.serviceError(error) }
    }

    /// Kommentar-Datensaetze einer Loesung (mit Entfernungen des Autors)
    private func commentRecords(_ cloud: CommunityCloud, solutionID: String) async throws -> [CommunityRecord] {
        try await query(cloud, CommunityQuery(type: CommunityRecordType.comment, equals: [Field.solutionID: .string(solutionID)],
                                              limit: Self.discussionLimit))
    }

    /// Melder je Kommentar; ist `Report` nicht lesbar (Rechte im Dashboard), keine
    private func commentReporters(_ cloud: CommunityCloud, solutionID: String, me: String) async -> [String: Set<String>] {
        let records = (try? await cloud.query(CommunityQuery(type: CommunityRecordType.report, equals: [Field.solutionID: .string(solutionID)],
                                                             limit: Self.discussionLimit), in: .publicDB)) ?? []
        var out: [String: Set<String>] = [:]
        for r in records {
            guard let c = r[Field.commentID]?.string, !c.isEmpty else { continue }
            out[c, default: []].insert(Self.owner(r, me: me))
        }
        return out
    }

    /// Vom Autor der Loesung entfernte Kommentare (nur seine eigenen Entfernungs-Datensaetze zaehlen)
    static func removedComments(_ records: [CommunityRecord], solutionAuthor: String, me: String) -> Set<String> {
        Set(records.compactMap { r in
            guard r[Field.status]?.string == removalStatus, !solutionAuthor.isEmpty, owner(r, me: me) == solutionAuthor else { return nil }
            return r[Field.removedID]?.string?.lowercased()
        })
    }

    /// Datensatz -> Eintrag des Verlaufs; entschluesselt nur aktive (geloeschte haben keinen Inhalt mehr)
    static func entry(_ r: CommunityRecord, solutionID: String, me: String, removed: Set<String>, reporters: [String: Set<String>],
                      secret: Data?, cipher: SolutionCipher) -> CommunityDiscussion.Entry? {
        guard r.type == CommunityRecordType.comment, r[Field.solutionID]?.string == solutionID,
              let raw = r[Field.status]?.string, raw != removalStatus else { return nil }
        let id = r.name.lowercased()
        var status = CommunityDiscussion.Status(rawValue: raw) ?? .hidden
        if status == .active, removed.contains(id) { status = .deleted }
        if status == .active, (reporters[id]?.count ?? 0) >= CommunityDiscussion.reportsToHide { status = .hidden }
        var body: CommunityDiscussion.Body?
        if status == .active, let secret, let payload = r[Field.payload]?.string {
            body = try? CommunityDiscussion.open(payload, commentID: id, solutionID: solutionID, communitySecret: secret, cipher: cipher)
        }
        let parent = r[Field.parentID]?.string.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let edited = r[Field.editedAt]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return CommunityDiscussion.Entry(id: id, parentID: parent, author: owner(r, me: me), status: status,
                                         createdAt: r[Field.createdAt]?.string ?? "", editedAt: edited, body: body,
                                         order: r[Field.order]?.int ?? 0)
    }

    /// Zahlen der Trefferliste (Likes, eigenes Like, aktive Kommentare) mit je einer Abfrage fuer bis zu `countChunk`
    /// Loesungen; scheitert die Abfrage (offline, Schema fehlt), bleiben die Zahlen 0
    func withDiscussion(_ list: [CommunitySolutionSummary], cloud: CommunityCloud, viewer v: CommunityViewer) async -> [CommunitySolutionSummary] {
        guard !list.isEmpty else { return list }
        var likes: [String: [String]] = [:], comments: [String: [CommunityRecord]] = [:]
        let ids = list.map(\.solutionID)
        for start in stride(from: 0, to: ids.count, by: Self.countChunk) {
            let chunk = Array(ids[start..<min(start + Self.countChunk, ids.count)])
            let any = [Field.solutionID: chunk]
            if let records = try? await cloud.query(CommunityQuery(type: CommunityRecordType.like, equals: [:], limit: Self.discussionLimit,
                                                                   anyOf: any), in: .publicDB) {
                for r in records { if let s = r[Field.solutionID]?.string { likes[s, default: []].append(Self.owner(r, me: v.ownerRecordName)) } }
            }
            if let records = try? await cloud.query(CommunityQuery(type: CommunityRecordType.comment, equals: [:], limit: Self.discussionLimit,
                                                                   anyOf: any), in: .publicDB) {
                for r in records { if let s = r[Field.solutionID]?.string { comments[s, default: []].append(r) } }
            }
        }
        return list.map { s in
            var s = s
            let likers = likes[s.solutionID] ?? []
            s.likes = CommunityDiscussion.likeCount(likers: likers, solutionAuthor: s.ownerRecordName, blocked: v.blockedOwners)
            s.likedByMe = !v.ownerRecordName.isEmpty && likers.contains(v.ownerRecordName)
            let records = comments[s.solutionID] ?? []
            let removed = Self.removedComments(records, solutionAuthor: s.ownerRecordName, me: v.ownerRecordName)
            let entries = records.compactMap {
                Self.entry($0, solutionID: s.solutionID, me: v.ownerRecordName, removed: removed, reporters: [:], secret: nil, cipher: SolutionSharing.cipher)
            }
            s.commentCount = CommunityDiscussion.activeCount(entries, blocked: v.blockedOwners)
            return s
        }
    }

    func comments(solutionID: String) async throws -> [CommunityComment] {
        let cloud = try available()
        let id = solutionID.lowercased()
        let (listing, v) = try await visibleSolution(cloud, id: id)
        let secret = try await secret(listing)
        let records = try await commentRecords(cloud, solutionID: id)
        let reporters = await commentReporters(cloud, solutionID: id, me: v.ownerRecordName)
        let removed = Self.removedComments(records, solutionAuthor: listing.ownerRecordName, me: v.ownerRecordName)
        let entries = records.compactMap {
            Self.entry($0, solutionID: id, me: v.ownerRecordName, removed: removed, reporters: reporters, secret: secret, cipher: SolutionSharing.cipher)
        }
        return CommunityDiscussion.thread(entries, me: v.ownerRecordName, solutionAuthor: listing.ownerRecordName, blocked: v.blockedOwners)
    }

    func addComment(solutionID: String, text: String, parentID: String?, pageKey: String?, anchor: CommunityComment.Anchor?) async throws -> CommunityComment {
        let text = try CommunityDiscussion.cleanText(text)
        var (pk, place) = try CommunityDiscussion.cleanAnchor(pageKey: pageKey, anchor: anchor)
        let (cloud, user) = try await signedIn()
        let sid = solutionID.lowercased()
        let (listing, _) = try await visibleSolution(cloud, id: sid)
        if await bannedOwners(cloud).contains(user) { throw CommunityServiceError.service("Dein Konto darf nicht mehr kommentieren.") }
        let secret = try await secret(listing)
        var parent: String?
        if let parentID, !parentID.isEmpty {
            let p: CommunityRecord?
            do { p = try await cloud.fetch(name: parentID.lowercased(), type: CommunityRecordType.comment, in: .publicDB) } catch {
                throw Self.serviceError(error)
            }
            guard let p, let e = Self.entry(p, solutionID: sid, me: user, removed: [], reporters: [:], secret: secret, cipher: SolutionSharing.cipher),
                  e.status != .hidden else {
                throw CommunityServiceError.service("Der Kommentar, auf den du antwortest, gibt es nicht.")
            }
            // eine Ebene: eine Antwort auf eine Antwort haengt am ersten Kommentar; ohne eigene Stelle die des Kommentars
            parent = e.parentID ?? e.id
            if pk == nil { pk = e.body?.pageKey; place = e.body?.anchor }
        }
        let id = UUID().uuidString.lowercased(), now = SolutionPackage.timestamp(Date())
        let body = CommunityDiscussion.Body(text: text, pseudonym: CommunityDiscussion.pseudonym(pseudonym()), pageKey: pk, anchor: place)
        var record = CommunityRecord(type: CommunityRecordType.comment, name: id)
        record[Field.solutionID] = .string(sid)
        record[Field.parentID] = .string(parent ?? "")
        record[Field.status] = .string(CommunityDiscussion.Status.active.rawValue)
        record[Field.createdAt] = .string(now)
        record[Field.order] = .int(Int(Date().timeIntervalSince1970 * 1_000_000))
        record[Field.editedAt] = .string("")
        record[Field.payload] = .string(try CommunityDiscussion.seal(body, commentID: id, solutionID: sid, communitySecret: secret,
                                                                     cipher: SolutionSharing.cipher))
        record[Field.owner] = .string(user)
        do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
        let entry = CommunityDiscussion.Entry(id: id, parentID: parent, author: user, createdAt: now, body: body)
        return CommunityDiscussion.comment(entry, me: user, solutionAuthor: listing.ownerRecordName)
    }

    /// Aktiver Kommentar (nicht geloescht, nicht entfernt, nicht ausgeblendet) mit seiner Loesung
    private func activeComment(_ cloud: CommunityCloud, id: String, me: String) async throws -> (CommunityRecord, CommunityListing, CommunityViewer) {
        let notFound = CommunityServiceError.service("Kommentar nicht gefunden.")
        let record: CommunityRecord?
        do { record = try await cloud.fetch(name: id.lowercased(), type: CommunityRecordType.comment, in: .publicDB) } catch {
            throw Self.serviceError(error)
        }
        guard let record, record[Field.status]?.string == CommunityDiscussion.Status.active.rawValue,
              let sid = record[Field.solutionID]?.string else { throw notFound }
        let (listing, v): (CommunityListing, CommunityViewer)
        do { (listing, v) = try await visibleSolution(cloud, id: sid) } catch CommunityServiceError.notFound { throw notFound }
        let others = try await commentRecords(cloud, solutionID: sid)
        guard !Self.removedComments(others, solutionAuthor: listing.ownerRecordName, me: me).contains(record.name.lowercased()) else { throw notFound }
        return (record, listing, v)
    }

    func editComment(id: String, text: String) async throws -> CommunityComment {
        let text = try CommunityDiscussion.cleanText(text)
        let (cloud, user) = try await signedIn()
        let (found, listing, _) = try await activeComment(cloud, id: id, me: user)
        var record = found
        guard Self.owner(record, me: user) == user else {
            throw CommunityServiceError.service("Nur der Verfasser kann seinen Kommentar ändern.")
        }
        let cid = record.name.lowercased(), sid = listing.solutionID
        let secret = try await secret(listing)
        // Seite, Stelle und Pseudonym bleiben; neues Salz und neue Nonce
        var body = (record[Field.payload]?.string).flatMap {
            try? CommunityDiscussion.open($0, commentID: cid, solutionID: sid, communitySecret: secret, cipher: SolutionSharing.cipher)
        } ?? CommunityDiscussion.Body(text: text, pseudonym: CommunityDiscussion.pseudonym(pseudonym()))
        body.text = text
        let now = SolutionPackage.timestamp(Date())
        record[Field.payload] = .string(try CommunityDiscussion.seal(body, commentID: cid, solutionID: sid, communitySecret: secret,
                                                                     cipher: SolutionSharing.cipher))
        record[Field.editedAt] = .string(now)
        do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
        let parent = record[Field.parentID]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let entry = CommunityDiscussion.Entry(id: cid, parentID: parent, author: user, createdAt: record[Field.createdAt]?.string ?? "",
                                              editedAt: now, body: body)
        return CommunityDiscussion.comment(entry, me: user, solutionAuthor: listing.ownerRecordName)
    }

    /// Eigenen Kommentar loeschen (Text weg, Status `deleted`); der Autor der Loesung entfernt fremde Kommentare unter
    /// seiner Loesung mit einem eigenen Entfernungs-Datensatz
    func deleteComment(id: String) async throws {
        let (cloud, user) = try await signedIn()
        let (found, listing, _) = try await activeComment(cloud, id: id, me: user)
        var record = found
        let now = SolutionPackage.timestamp(Date())
        if Self.owner(record, me: user) == user {
            record[Field.status] = .string(CommunityDiscussion.Status.deleted.rawValue)
            record[Field.payload] = nil
            record[Field.editedAt] = .string(now)
            do { try await cloud.save(record, in: .publicDB) } catch { throw Self.serviceError(error) }
            return
        }
        guard listing.ownerRecordName == user else { throw CommunityServiceError.service("Nur der Verfasser kann das.") }
        var removal = CommunityRecord(type: CommunityRecordType.comment, name: "removal-" + UUID().uuidString.lowercased())
        removal[Field.solutionID] = .string(listing.solutionID)
        removal[Field.status] = .string(Self.removalStatus)
        removal[Field.removedID] = .string(record.name.lowercased())
        removal[Field.createdAt] = .string(now)
        removal[Field.owner] = .string(user)
        do { try await cloud.save(removal, in: .publicDB) } catch { throw Self.serviceError(error) }
    }

    func reportComment(id: String, reason: CommunityReportReason) async throws {
        let (cloud, user) = try await signedIn()
        let (record, listing, _) = try await activeComment(cloud, id: id, me: user)
        guard Self.owner(record, me: user) != user else {
            throw CommunityServiceError.service("Den eigenen Kommentar kannst du löschen statt melden.")
        }
        let cid = record.name.lowercased()
        if await commentReporters(cloud, solutionID: listing.solutionID, me: user)[cid]?.contains(user) == true {
            throw CommunityServiceError.service("Du hast diesen Kommentar schon gemeldet.")
        }
        var report = CommunityRecord(type: CommunityRecordType.report, name: "report-" + UUID().uuidString.lowercased())
        report[Field.solutionID] = .string(listing.solutionID)
        report[Field.commentID] = .string(cid)
        report[Field.reason] = .string(reason.rawValue)
        report[Field.note] = .string("")
        report[Field.reporter] = .string(user)
        report[Field.createdAt] = .string(SolutionPackage.timestamp(Date()))
        do { try await cloud.save(report, in: .publicDB) } catch { throw Self.serviceError(error) }
    }

    /// Gefaellt mir setzen oder entfernen (idempotent); Ergebnis ist die neue Anzahl
    func setLiked(solutionID: String, _ liked: Bool) async throws -> Int {
        let (cloud, user) = try await signedIn()
        let sid = solutionID.lowercased()
        let (listing, v) = try await visibleSolution(cloud, id: sid)
        guard listing.ownerRecordName != user else { throw CommunityServiceError.service("Die eigene Lösung lässt sich nicht liken.") }
        let records = try await query(cloud, CommunityQuery(type: CommunityRecordType.like, equals: [Field.solutionID: .string(sid)],
                                                            limit: Self.discussionLimit))
        let mine = records.filter { Self.owner($0, me: user) == user }
        let others = records.map { Self.owner($0, me: user) }.filter { $0 != user }
        do {
            if liked, mine.isEmpty {
                var record = CommunityRecord(type: CommunityRecordType.like, name: "like-" + UUID().uuidString.lowercased())
                record[Field.solutionID] = .string(sid)
                record[Field.owner] = .string(user)
                record[Field.createdAt] = .string(SolutionPackage.timestamp(Date()))
                try await cloud.save(record, in: .publicDB)
            } else if !liked {
                for r in mine { try await cloud.delete(name: r.name, type: CommunityRecordType.like, in: .publicDB) }
            }
        } catch {
            throw Self.serviceError(error)
        }
        // aus der Abfrage vor dem Schreiben plus dem eigenen Stand (der Index von CloudKit folgt verzoegert)
        return CommunityDiscussion.likeCount(likers: others + (liked ? [user] : []), solutionAuthor: listing.ownerRecordName,
                                             blocked: v.blockedOwners)
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
    /// Veroeffentlichen: Inhalt wie beim Teilen als Datei, Kopie unter "Meine geteilten Lösungen" (an die PDF gebunden),
    /// fuer die Community mit deren Schluessel versiegelt, dann zum Dienst; danach das Datum merken.
    static func publishToCommunity(_ source: SolutionSource, keys: [String], displayName: String, options: CommunityPublishOptions,
                                   space: CommunitySpace, service: CommunityService, library: SolutionLibrary = library) async throws -> CommunityPublication {
        guard let secret = space.secret else { throw CommunityServiceError.notAMember }
        let sealed = try await Task.detached(priority: .userInitiated) {
            let built = try SolutionSharing.content(source, keys: keys, displayName: displayName)
            try library.recordShared(SolutionSharing.package(built, originalPDF: source.originalPDF), title: source.title)
            return try SolutionPackage.seal(built, communitySecret: secret, cipher: SolutionSharing.cipher)
        }.value
        let publication: CommunityPublication
        do {
            publication = try await service.publish(sealed, options: options)
        } catch CommunityServiceError.alreadyPublished(let id) {
            // nichts Neues veroeffentlicht: die eben angelegte Kopie wieder weg, die Frage stellt der Dialog
            try? library.removeShared(sealed.header.solutionID)
            throw CommunityServiceError.alreadyPublished(id)
        }
        try library.setPublished(publication.solutionID, at: publication.publishedAt)
        return publication
    }

    /// Ergebnis von `publishOrAskUpdate`: veroeffentlicht oder (schon eine eigene Loesung zu dieser PDF) fragen
    enum CommunityShareStep: Equatable {
        case published(CommunityPublication)
        case askUpdate(solutionID: String)
    }

    /// Veroeffentlichen mit vorheriger Pruefung: gibt es zu dieser PDF in dieser Community schon eine eigene Loesung,
    /// nichts senden und fragen ("Aktualisieren?"); meldet erst der Dienst das Doppel (409), ebenso.
    static func publishOrAskUpdate(_ source: SolutionSource, keys: [String], displayName: String, options: CommunityPublishOptions,
                                   space: CommunitySpace, service: CommunityService, library: SolutionLibrary = library) async throws -> CommunityShareStep {
        // Pruefung vorab ist nur eine Hilfe (ohne Netz oder iCloud entscheidet der Dienst beim Veroeffentlichen)
        if let own = (try? await service.ownSolution(fingerprint: source.fingerprint, communityKey: space.key)) ?? nil {
            return .askUpdate(solutionID: own.solutionID)
        }
        do {
            return .published(try await publishToCommunity(source, keys: keys, displayName: displayName, options: options, space: space,
                                                           service: service, library: library))
        } catch CommunityServiceError.alreadyPublished(let id) {
            return .askUpdate(solutionID: id)
        }
    }

    /// Erneut teilen zu derselben PDF ("Aktualisieren?" mit Ja): bisherige eigene Loesung laden und mit dem Schluessel
    /// der Community oeffnen, die neue Fassung damit zusammenfuehren (`SolutionBuilder.merge`: andere Seiten kommen
    /// dazu, dieselbe Seite wird ersetzt), unter der bisherigen ID neu versiegeln und das Paket beim Dienst ersetzen.
    /// Likes, Kommentare und Sichtbarkeit bleiben; die Kopie unter "Meine geteilten Lösungen" wird ersetzt.
    static func updateInCommunity(_ source: SolutionSource, keys: [String], displayName: String, options: CommunityPublishOptions,
                                  space: CommunitySpace, existingID: String, service: CommunityService,
                                  library: SolutionLibrary = library) async throws -> CommunityPublication {
        guard let secret = space.secret else { throw CommunityServiceError.notAMember }
        let previousPackage = try await service.download(solutionID: existingID)
        let sealed = try await Task.detached(priority: .userInitiated) {
            let previous = try previousPackage.open(communitySecret: secret, cipher: SolutionSharing.cipher)
            let built = try SolutionSharing.content(source, keys: keys, displayName: displayName)
            let merged = try SolutionBuilder.merge(previous: previous, new: built)
            try library.recordShared(SolutionSharing.package(merged, originalPDF: source.originalPDF), title: source.title)
            return try SolutionPackage.seal(merged, communitySecret: secret, cipher: SolutionSharing.cipher)
        }.value
        let publication = try await service.update(solutionID: existingID, package: sealed, options: options)
        try library.setPublished(publication.solutionID, at: publication.publishedAt)
        return publication
    }

    /// Community-Paket mit einem der bekannten Schluessel oeffnen (das Paket nennt seine Community nicht)
    static func openCommunity(_ package: SolutionPackage, spaces: [CommunitySpace]) throws -> SolutionContent {
        for secret in spaces.compactMap(\.secret) {
            if let c = try? package.open(communitySecret: secret, cipher: cipher) { return c }
        }
        throw SolutionError.decryptionFailed
    }

    /// Loesung laden und entschluesseln (fuer den Leser, auch ohne die PDF)
    static func loadCommunity(_ solutionID: String, service: CommunityService) async throws -> SolutionContent {
        let package = try await service.download(solutionID: solutionID)
        let spaces = try await service.communities()
        return try await Task.detached(priority: .userInitiated) { try openCommunity(package, spaces: spaces) }.value
    }

    /// Eigene Veroeffentlichung zurueckziehen (Dienst, dann das Datum loeschen; die Kopie bleibt).
    static func withdrawFromCommunity(_ solutionID: String, service: CommunityService, library: SolutionLibrary = library) async throws {
        try await service.withdraw(solutionID: solutionID)
        try library.setPublished(solutionID, at: nil)
        await CommunityMatches.shared.remove(solutionID: solutionID)
    }

    /// Geladenes Paket als Datei im Zwischenspeicher des Containers ablegen, damit der Import denselben Weg nimmt wie
    /// "Lösung importieren …" (Kopf pruefen, verschluesselt ablegen, mit der eigenen PDF oeffnen, fremde Ebene).
    static func writeDownloaded(_ package: SolutionPackage) throws -> URL {
        let url = try AppTemp.fresh("community-download").appendingPathComponent(SolutionLibrary.fileName(package.header.solutionID))
        try package.encoded().write(to: url, options: .atomic)
        return url
    }
}

extension DocumentStore {
    /// "Laden und anzeigen" aus der Community: Paket laden, als Datei ablegen und ueber `importSolution` uebernehmen
    /// (derselbe Weg wie die Datei: fremde Ebene, eigene Notizen unveraendert).
    func importFromCommunity(_ solutionID: String, service: CommunityService, library: SolutionLibrary = SolutionSharing.library) async throws -> SolutionImportResult {
        var package = try await service.download(solutionID: solutionID)
        if package.header.isCommunityPackage {
            // lokal wieder an die PDF binden: Ebene, Bibliothek und Pruefungen bleiben wie beim Dateiweg
            let pdf = try Data(contentsOf: originalPDFURL)
            let spaces = try await service.communities()
            let content = try SolutionSharing.openCommunity(package, spaces: spaces)
            package = try SolutionPackage.seal(content, originalPDF: pdf, cipher: SolutionSharing.cipher)
        }
        let url = try SolutionSharing.writeDownloaded(package)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try await importSolution(url, library: library)
    }
}

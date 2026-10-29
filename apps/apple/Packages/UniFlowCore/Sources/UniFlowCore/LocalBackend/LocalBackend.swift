import Foundation

/// Das lokale Backend des Geraets: beantwortet dieselben `/api/`-Pfade mit derselben JSON-Form wie app/server.py,
/// aus der lokalen Datenbank (docs/IPAD-OHNE-PC.md, Abschnitt 4). Die App spricht es ueber `LocalTransport` an; die
/// fertigen Ansichten merken keinen Unterschied zum PC-Server.
public final class LocalBackend: Sendable {
    /// Alle Endpunkt-Module. Ein Modul traegt seine Pfade selbst ein; Platzhalter (bis zur Portierung) werden von
    /// echten Endpunkten mit demselben Pfad automatisch ersetzt.
    public static let standardModules: [LocalEndpointModule.Type] = [
        SettingsEndpoints.self,
        TermsEndpoints.self,
        GradesEndpoints.self,
        LibraryEndpoints.self,
        FilesEndpoints.self,
        AnnotationEndpoints.self,
        TimetableEndpoints.self,
        DroppedEndpoints.self,
        AIEndpoints.self,
        ModulesEndpoints.self,
        StudyEndpoints.self,
        SearchEndpoints.self,
        FileVersionEndpoints.self,
        FlashcardEndpoints.self,
        DueEndpoints.self,
        DemoEndpoints.self,
        PendingOverviewEndpoints.self,
        PendingServicesEndpoints.self,
    ]

    public struct ConflictError: Error, CustomStringConvertible {
        public let conflicts: [String]
        public var description: String { "Doppelte Endpunkte: " + conflicts.joined(separator: "; ") }
    }

    public let router: LocalRouter
    public let context: LocalContext

    /// Mit schon migrierter Datenbank. Wirft, wenn zwei Module denselben Pfad belegen.
    public init(database: SQLiteDatabase, clock: UniFlowClock = .system, files: LocalFiles? = nil,
                newHex: @escaping @Sendable () -> String = LocalContext.randomHex,
                modules: [LocalEndpointModule.Type] = LocalBackend.standardModules) throws {
        let router = LocalRouter()
        for m in modules { router.register(m) }
        guard router.conflicts.isEmpty else { throw ConflictError(conflicts: router.conflicts) }
        self.router = router
        self.context = LocalContext(database: database, clock: clock, files: files, newHex: newHex)
    }

    /// Datenbank oeffnen (Datei oder `SQLiteDatabase.inMemory`), auf den Stand von app/db.py bringen, Backend bauen.
    /// `university`: Hochschule des Containers; gehoert die Datenbank einer anderen, wirft das `UniversityMismatch`.
    public static func open(path: String, clock: UniFlowClock = .system, files: LocalFiles? = nil,
                            university: String = Migrations.defaultUniversity,
                            newHex: @escaping @Sendable () -> String = LocalContext.randomHex,
                            modules: [LocalEndpointModule.Type] = LocalBackend.standardModules) async throws -> LocalBackend {
        let db = try SQLiteDatabase(path: path)
        try await db.migrate(clock: clock, university: university)
        return try LocalBackend(database: db, clock: clock, files: files, newHex: newHex, modules: modules)
    }

    public func handle(_ request: LocalRequest) async -> LocalResponse {
        await router.handle(request, context: context)
    }

    /// Endpunkt, der eine Anfrage beantworten wuerde (fuer Tests und die Abdeckungsliste)
    public func route(method: String, path: String) -> LocalRoute? {
        router.route(method: method, path: path)?.route
    }
}

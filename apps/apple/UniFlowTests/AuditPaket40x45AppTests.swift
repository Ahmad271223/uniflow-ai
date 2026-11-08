import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Audit 08.11.2026, Paket 40 (erweitert) und 45 (docs/audit/AUDIT-2026-11-08-PAKET-40x-45.md): spaete Antworten des
/// StudiNow-Dienstes nach einem Kontowechsel (`StudoraAccountLink.refresh`, `syncNow`; Nachtrag P37-01/P37-09/P37-05),
/// fruehere Semester nach einem Kontowechsel (`OlderSemesterLoader`), Dokument-Route zu Dokument-Route (`MainView`).
/// Schein-Dienst und erfundene Apple-Nutzer, eigene Schluesselbund-Dienste und Suiten; nie ein Netz.
@MainActor
final class AuditPaket40x45AppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let bob = "009876.erfunden-bob.\(UUID().uuidString.prefix(8))"
    private var websiteStores: [UUID] = []
    private var dirs: [URL] = []

    override func setUp() async throws {
        bed = try ContainerTestBed(name: "audit40x45", clock: .fixed(berlin: "2026-11-09T08:00:00")!)
    }

    override func tearDown() async throws {
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        for layout in DataContainerLayout.all(base: bed.containers, userID: bob) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            websiteStores.append(layout.identifier)
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        await bed.tearDown()
        bed = nil
    }

    // MARK: Schein-Dienst

    static let base = "https://dienst.example"
    static let userA = "0123456789abcdef0123456789abcdef"
    static let userB = "fedcba9876543210fedcba9876543210"

    /// Antwortet je Token mit Konto A ("tok-a") bzw. B ("tok-b"); `/api/account/me` von A und `/api/sync/changes`
    /// koennen verzoegert antworten, der Abruf der Aenderungen auch mit einem Fehler
    final class ServiceStub: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var meDelayA: UInt64 = 0
        var changesDelay: UInt64 = 0
        var changesStatus = 200
        /// Antwort auf die n-te Sendung (`POST /api/sync/push`, ab 1)
        var pushReply: @Sendable (Int, JSONValue) -> JSONValue = { _, _ in ["results": .array([]), "mapping": .array([]), "conflicts": .array([])] }

        var requests: [String] { lock.withLock { log } }
        func count(_ prefix: String) -> Int { requests.filter { $0.hasPrefix(prefix) }.count }

        static func user(_ id: String, _ mail: String) -> JSONValue {
            ["id": .string(id), "email": .string(mail), "email_verified": true, "university": "luh", "plan": "pro_ai", "role": "user"]
        }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst(AuditPaket40x45AppTests.base.count))
            let token = r.headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            let pushes: Int = lock.withLock {
                log.append("\(r.method) \(path)")
                return log.filter { $0.hasPrefix("POST /api/sync/push") }.count
            }
            func ok(_ j: JSONValue) -> ServiceHTTPResponse { ServiceHTTPResponse(status: 200, body: j.serialized()) }
            let isA = token == "tok-a"
            switch (r.method, path) {
            case ("GET", "/api/account/me"):
                if isA, meDelayA > 0 { try await Task.sleep(nanoseconds: meDelayA) }
                return ok(["user": isA ? Self.user(AuditPaket40x45AppTests.userA, "a@beispiel.de") : Self.user(AuditPaket40x45AppTests.userB, "b@beispiel.de"),
                           "sessions": .array([])])
            case ("GET", "/api/entitlements"):
                return ok(["plan": isA ? "pro_ai" : "plus", "trial": ["active": false]])
            case ("POST", "/api/account/login"):
                return ok(["token": "tok-b", "user": Self.user(AuditPaket40x45AppTests.userB, "b@beispiel.de")])
            case ("POST", "/api/sync/push"):
                let body = r.body.flatMap { try? JSONValue.parse($0) } ?? .null
                return ok(pushReply(pushes, body))
            case ("GET", _) where path.hasPrefix("/api/sync/changes"):
                if changesDelay > 0 { try await Task.sleep(nanoseconds: changesDelay) }
                guard changesStatus == 200 else {
                    return ServiceHTTPResponse(status: changesStatus, body: JSONValue.object(["detail": "Wartung", "code": "unavailable"]).serialized())
                }
                return ok(["changes": .object([:]), "tombstones": .array([]), "cursor": "2026-11-09T07:00:00.000Z", "has_more": false])
            default:
                return ServiceHTTPResponse(status: 404, body: Data())
            }
        }
    }

    final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String?) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    /// Konto-Anschluss mit Konto A ("tok-a") ueber den Schein-Dienst
    private func link(_ stub: ServiceStub, scope: String = "p45-a-\(UUID().uuidString)") -> StudoraAccountLink {
        let l = StudoraAccountLink(entitlements: Entitlements(observe: false))
        l.attachForTesting(account: StudoraAccount(base: Self.base, http: stub, tokens: MemoryTokens("tok-a"),
                                                   deviceID: "ipad-test", deviceName: "iPad"), scope: scope)
        return l
    }

    /// Eigenes lokales Backend (Datenbank in einem Temp-Ordner)
    private func backendHost() throws -> LocalBackendHost {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit40x45-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-09T08:00:00")!)
    }

    /// Konto A angemeldet, Container mit lokalem Backend, Hochschule LUH
    private func signedInLink(_ stub: ServiceStub, host: LocalBackendHost, scope: String = "p45-a-\(UUID().uuidString)") async -> StudoraAccountLink {
        let l = link(stub, scope: scope)
        l.attachHostForTesting(host, university: "luh")
        await l.refresh()
        XCTAssertEqual(l.user?.id, Self.userA)
        return l
    }

    // MARK: P37-01 / P45-01: spaete Antwort von refresh()

    /// Anderer Apple-Nutzer auf diesem iPad, waehrend `refresh()` fuer Konto A noch auf den Dienst wartet: Name,
    /// E-Mail, Tarif und Credits von A duerfen danach nicht beim neuen Apple-Nutzer stehen
    func testLateRefreshOfThePreviousAppleUserLeavesTheNewOneEmpty() async throws {
        let stub = ServiceStub()
        stub.meDelayA = 600_000_000
        let l = link(stub)
        let refresh = Task { await l.refresh() }
        try await Task.sleep(nanoseconds: 150_000_000)
        l.use(userScope: "p45-b-\(UUID().uuidString)")
        await refresh.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(l.user, "Konto A darf nicht beim neuen Apple-Nutzer stehen")
        XCTAssertNil(l.planStatus)
        XCTAssertEqual(l.sessions, [])
        XCTAssertNil(UFBillingServiceLink.accountToken, "kein appAccountToken von Konto A")
        l.use(userScope: nil)
    }

    /// Gleicher Apple-Nutzer: Konto A abmelden und Konto B anmelden, waehrend die Antwort fuer A noch unterwegs ist.
    /// Danach steht B in der Karte, nicht A mit dem Token von B.
    func testLateRefreshOfTheSignedOutAccountDoesNotReplaceTheNextOne() async throws {
        let stub = ServiceStub()
        stub.meDelayA = 700_000_000
        let l = link(stub)
        let refresh = Task { await l.refresh() }
        try await Task.sleep(nanoseconds: 150_000_000)
        await l.logout()
        await l.login(email: "b@beispiel.de", password: "geheim")
        XCTAssertEqual(l.user?.id, Self.userB)
        await refresh.value
        XCTAssertEqual(l.user?.id, Self.userB, "spaete Antwort fuer A ersetzt B nicht")
        XCTAssertEqual(l.user?.email, "b@beispiel.de")
        XCTAssertEqual(l.planStatus?.plan, "plus")
    }

    // MARK: P45-01 / P37-02: spaetes Ende des Geraete-Abgleichs

    /// Der Abgleich von A endet erst nach dem Wechsel zu einem anderen Apple-Nutzer: sein Ergebnis gilt nicht fuer B
    /// (kein "zuletzt abgeglichen" von A, keine Meldung "hat sich geaendert" fuer die Fenster von B)
    func testLateDeviceSyncOfThePreviousAccountLeavesNoStatusAtTheNewOne() async throws {
        let stub = ServiceStub()
        let host = try backendHost()
        let l = await signedInLink(stub, host: host)
        stub.changesDelay = 500_000_000
        let run = Task { await l.syncNow(force: true) }
        try await bed.waitUntil("Abgleich laeuft") { stub.count("GET /api/sync/changes") > 0 }
        l.use(userScope: "p45-b-\(UUID().uuidString)")
        let changed = await run.value
        XCTAssertFalse(changed)
        XCTAssertNil(l.lastSync, "Ergebnis von A gilt nicht fuer B")
        XCTAssertFalse(l.syncing)
        l.use(userScope: nil)
    }

    /// Gleiches Konto, anderer Container (Hochschule gewechselt): das Ergebnis des alten Containers gilt nicht, und
    /// der neue gleicht ohne die 3-Minuten-Sperre des alten ab
    func testSwitchingTheContainerResetsTheLastSync() async throws {
        let stub = ServiceStub()
        let scope = "p45-a-\(UUID().uuidString)"
        let l = await signedInLink(stub, host: try backendHost(), scope: scope)
        let first = await l.syncNow(force: true)
        XCTAssertFalse(first)
        XCTAssertEqual(l.lastSync?.ok, true)
        let before = stub.count("GET /api/sync/changes")
        l.use(userScope: scope, host: try backendHost(), university: "luh")
        XCTAssertNil(l.lastSync, "Stand des vorigen Containers")
        _ = await l.syncNow()
        XCTAssertGreaterThan(stub.count("GET /api/sync/changes"), before, "neuer Container gleicht gleich ab")
    }

    /// P37-09 / P45-08: ein fehlgeschlagener Abgleich zaehlt nicht als erledigt; der naechste automatische laeuft
    /// ohne 3 Minuten Wartezeit. Ein gelungener sperrt wie bisher.
    func testFailedDeviceSyncIsRetriedWithoutTheThreeMinuteWait() async throws {
        let stub = ServiceStub()
        let l = await signedInLink(stub, host: try backendHost())
        stub.changesStatus = 503
        _ = await l.syncNow(force: true)
        XCTAssertEqual(l.lastSync?.ok, false)
        XCTAssertEqual(stub.count("GET /api/sync/changes"), 1)
        stub.changesStatus = 200
        _ = await l.syncNow()
        XCTAssertEqual(l.lastSync?.ok, true, "nach dem Fehler gleich wieder versucht")
        let done = stub.count("GET /api/sync/changes")
        _ = await l.syncNow()
        XCTAssertEqual(stub.count("GET /api/sync/changes"), done, "nach Erfolg 3 Minuten Pause")
    }

    /// Zwei Anstoesse kurz nacheinander (Vordergrund und Knopf): nur ein Lauf, sonst sendeten beide dieselben neuen
    /// Zeilen
    func testTwoSyncRequestsAtOnceRunOnlyOnce() async throws {
        let stub = ServiceStub()
        let l = await signedInLink(stub, host: try backendHost())
        stub.changesDelay = 200_000_000
        async let a = l.syncNow(force: true)
        async let b = l.syncNow(force: true)
        _ = await (a, b)
        XCTAssertEqual(stub.count("GET /api/sync/changes"), 2, "ein Lauf: abrufen, senden, abrufen\n\(stub.requests.joined(separator: "\n"))")
        XCTAssertLessThanOrEqual(stub.count("POST /api/sync/push"), 1)
    }

    /// P37-05: Nur Notizen zusammengefuehrt (Konflikt beim Senden): `syncNow` meldet "geaendert", damit offene Fenster
    /// neu laden
    func testNotesOnlyMergeCountsAsAChange() async throws {
        let stub = ServiceStub()
        let host = try backendHost()
        let l = await signedInLink(stub, host: host)
        let file = "studip-blatt-1"
        func page(_ id: String) -> JSONValue {
            ["version": 2, "pages": ["p1": ["objects": .array([["id": .string(id), "type": "stroke", "points": .array([1, 2, 3, 4])]])]],
             "pageOrder": .array([["key": "p1", "type": "pdf", "index": 1]]), "deletedPages": .array([]), "note": "",
             "bookmarks": .array([]), "outline": .array([])]
        }
        let local = page("ipad").jsonString()
        try await host.backend().context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, semester) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27')")
            try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES (?, 'kurs-1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://x.example/1')", [.text(file)])
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", [.text(file), .text(local)])
        }
        let server = page("windows")
        stub.pushReply = { n, _ in
            let status = n == 1 ? "conflict" : "applied"
            return ["results": .array([["entity": "annotations", "id": .string(file), "status": .string(status), "data": server, "version": .number(Double(n + 1))]]),
                    "mapping": .array([]), "conflicts": .array([])]
        }
        let changed = await l.syncNow(force: true)
        let r = try XCTUnwrap(l.lastSync)
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.applied + r.deleted, 0, "nur Notizen")
        XCTAssertGreaterThan(r.notesMerged, 0)
        XCTAssertTrue(changed, "Notizen zusammengefuehrt zaehlt als Aenderung")
    }

    // MARK: P40-03: fruehere Semester nach einem Kontowechsel

    private func manager() -> ContainerManager { bed.manager() }

    private func accountStore() -> AccountStore {
        AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(), observeRevocation: false)
    }

    @discardableResult
    private func signIn(_ a: AccountStore, _ m: ContainerManager, _ id: String) throws -> ActiveContainer {
        a.signIn(userID: id, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(.luh)
        a.markLoginDone()
        m.sync(account: a)
        let c = try XCTUnwrap(m.active, m.problem ?? "kein Container")
        websiteStores.append(c.websiteDataStoreID)
        return c
    }

    private func signOut(_ a: AccountStore, _ m: ContainerManager) {
        XCTAssertTrue(a.signOut())
        m.sync(account: a)
    }

    /// Stufe (d) von A wartet zwischen zwei Semestern; in der Pause meldet sich A ab und B an. Danach beginnt kein
    /// weiteres Semester von A (es lief mit der Stud.IP-Sitzung von A weiter, obwohl A abgemeldet war); der Stand
    /// "laden weiter, sobald StudiNow offen ist" bleibt bei A.
    func testOlderSemestersStartNothingMoreAfterAnAccountSwitch() async throws {
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let db = try await ada.host.backend().context.database
        try await db.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, semester, active) VALUES ('alt-1', 'Analysis I', 'SoSe 2024', 0)")
            try OlderSemesters.setMode(c, .auto, now: "2026-11-09T08:00:00")
        }
        let pending = try await db.withConnection { try OlderSemesters.pending($0, today: "2026-11-09") }
        XCTAssertEqual(pending, ["alt-1"])
        let loader = OlderSemesterLoader.shared
        let lowPower = loader.lowPower
        loader.lowPower = { false }
        defer { loader.lowPower = lowPower }
        var switched = false
        let runs = await loader.run(m, expired: {
            if !switched {
                switched = true
                self.signOut(a, m)
                _ = try? self.signIn(a, m, self.bob)
            }
            return false
        })
        XCTAssertTrue(switched)
        XCTAssertEqual(m.active?.key.userID, bob)
        XCTAssertEqual(runs, 0, "nach dem Wechsel kein Semester von A mehr")
    }

    // MARK: P40-07: Dokument-Route zu Dokument-Route

    /// Ein Dokument ist offen (#/doc/A), dann fuehrt die App zu einem anderen (#/doc/B, z. B. nach "Teilen → StudiNow"
    /// aus der Dateien-App): angezeigt wird B, nicht weiter A unter der neuen Adresse
    /// Ohne `async`: die Ansicht laedt in Aufgaben des Hauptakteurs, die nur zwischen den Schritten des Tests laufen
    func testOpeningAnotherDocumentFromAnOpenOneShowsTheNewOne() throws {
        let host = try backendHost()
        var ready = false
        Task {
            try? await host.backend().context.database.transaction { c in
                try c.execute("INSERT INTO courses(id, title, subject, kind, created_at) VALUES ('k1', 'Analysis I', 'Analysis', 'vorlesung', '2026-10-01')")
                try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f-alpha', 'k1', 'Tabelle-Alpha.xlsx', 5, 'other')")
                try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f-beta', 'k1', 'Tabelle-Beta.xlsx', 6, 'other')")
            }
            ready = true
        }
        let end = Date().addingTimeInterval(10)
        while !ready && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(ready, "Datenbank angelegt")
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let env = try hostWithEnvironment(MainView(), api: APIClient.local(host), size: CGSize(width: 1180, height: 820))
        // Fenster statt Wurzelansicht: der Inhalt des Dokuments liegt in der geteilten Ansicht (UISplitViewController)
        func texts() -> [String] {
            LayoutWidthAuditTests.elements(in: env.window).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
        }
        env.router.go(.doc("f-alpha"))
        XCTAssertTrue(env.wait(timeout: 15) { texts().contains { $0.contains("Tabelle-Alpha") } }, texts().joined(separator: "\n"))
        env.router.go(.doc("f-beta"))
        XCTAssertTrue(env.wait(timeout: 10) { texts().contains { $0.contains("Tabelle-Beta") } }, texts().joined(separator: "\n"))
        XCTAssertFalse(texts().contains { $0.contains("Tabelle-Alpha") }, "A steht nicht mehr da")
    }
}

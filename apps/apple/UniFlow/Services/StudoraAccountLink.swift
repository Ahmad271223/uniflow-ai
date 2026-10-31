import Foundation
import SwiftUI
import UIKit
import UniFlowCore

/// Sitzungs-Token des Studora-Kontos im Schluesselbund dieses Geraets, je Apple-Nutzer; nie synchronisiert. Konto
/// loeschen in der App entfernt es (`ContainerManager.deleteAllData`).
struct StudoraAccountKeychain: AccountTokenStore {
    static let service = "de.uniflow.ai.studora-account"
    let userScope: String
    func load() -> String? { KeychainStore(service: Self.service).string(userScope) }
    func save(_ token: String?) throws {
        let k = KeychainStore(service: Self.service)
        if let token { try k.write(token, account: userScope) } else { k.remove(userScope) }
    }
    @discardableResult
    static func remove(userScope: String) -> Bool { KeychainStore(service: service).remove(userScope) }
}

/// Anfragen an den Studora-Dienst (nur https)
struct URLSessionServiceTransport: ServiceHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        guard let url = URL(string: request.url), url.scheme == "https" else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("Studora-iPad/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k)] = String(describing: v) }
        return ServiceHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

/// Studora-Konto auf dem iPad (V1, Entscheidung des Inhabers vom 29.10.2026; Plan ENTSCHEIDUNGEN-INHABER-2026-10-29 §3):
/// anmelden mit E-Mail (wer sich auf Windows registriert hat) und spaeter mit Apple, angemeldete Geraete, Datenexport,
/// Konto loeschen. Noch ohne Abgleich der Notizen (Stufe 2). Sichtbar erst mit Dienst-Adresse (`StudoraServiceURL`).
@MainActor
final class StudoraAccountLink: ObservableObject {
    /// Adresse des Dienstes aus der Info.plist; leer = es gibt noch keinen Server (Konto unsichtbar)
    nonisolated static var serviceURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "StudoraServiceURL") as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil }
    }
    nonisolated static var available: Bool { serviceURL != nil }

    /// Feste Kennung dieses Geraets fuer die Geraeteliste (nicht die Werbe-ID, nur fuer Studora)
    static var deviceID: String {
        let key = "uniflow.account.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "ipad-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    @Published private(set) var user: StudoraAccount.User?
    @Published private(set) var sessions: [StudoraAccount.Session] = []
    /// Tarif und Probe beim Dienst (nil: nicht angemeldet oder noch nicht geladen)
    @Published private(set) var planStatus: StudoraAccount.PlanStatus? {
        didSet { Entitlements.shared.useServiceTrial(planStatus?.trialPlan.flatMap(UFPlan.init(rawValue:))) }
    }
    @Published private(set) var busy = false
    @Published var message: String?

    /// Geraete-Abgleich (Vertrag G2): laeuft gerade, letztes Ergebnis in diesem Prozess
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: DeviceSyncResult?
    /// Automatisch hoechstens alle 3 Minuten (`sync_client.start_background`)
    static let autoSyncInterval: TimeInterval = 180
    private var lastSyncAt: Date?
    private var host: LocalBackendHost?
    private var university: String?

    private(set) var account: StudoraAccount?
    private var scope: String?

    /// `true`, wenn der Abgleich gerade laufen darf: angemeldet, gleiche Hochschule wie das Konto, keine Demo-Inhalte
    static func canSync(user: StudoraAccount.User?, university: String?, blocked: Bool) -> Bool {
        guard let user, !blocked else { return false }
        return user.university == nil || user.university == university
    }

    /// Abgleich mit dem Konto; Rueckgabe: hat er hier etwas geaendert? `force`: Knopf, sonst hoechstens alle 3 Minuten
    @discardableResult
    func syncNow(force: Bool = false) async -> Bool {
        guard !syncing, let account, let host, let id = user?.id,
              force || lastSyncAt.map({ Date().timeIntervalSince($0) >= Self.autoSyncInterval }) ?? true,
              let backend = try? await host.backend() else { return false }
        // Demo-Inhalte gehoeren nicht ins Konto; direkt aus der Datenbank, `demoActive` kommt beim Start erst spaeter
        let demo = (try? await backend.context.database.withConnection { try DemoContent.isEnabled($0) }) ?? true
        guard Self.canSync(user: user, university: university, blocked: demo) else { return false }
        syncing = true
        defer { syncing = false }
        let r = await DeviceSync(database: backend.context.database, transport: account, device: Self.deviceID).run(account: id)
        lastSync = r
        lastSyncAt = Date()
        return r.applied + r.deleted > 0
    }

    func use(userScope: String?, host: LocalBackendHost? = nil, university: String? = nil) {
        self.host = host
        self.university = university
        guard userScope != scope else { return }
        scope = userScope
        lastSync = nil
        lastSyncAt = nil
        user = nil
        sessions = []
        planStatus = nil
        account = nil
        guard let userScope, let base = Self.serviceURL else { return }
        account = StudoraAccount(base: base, http: URLSessionServiceTransport(), tokens: StudoraAccountKeychain(userScope: userScope),
                                 deviceID: Self.deviceID, deviceName: UIDevice.current.name)
        Task { await refresh() }
    }

    private func run(_ op: @escaping (StudoraAccount) async throws -> Void) async {
        guard let account else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await op(account) } catch let e as AccountError {
            message = e.retryAfter.map { "\(e.message) (in \(max(1, $0 / 60)) min erneut versuchen)" } ?? e.message
            if e.code == "unauthenticated" { user = nil; sessions = []; planStatus = nil }
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard let account, await account.isSignedIn else { user = nil; sessions = []; planStatus = nil; return }
        await run { a in
            let me = try await a.me()
            self.user = me.user
            self.sessions = me.sessions
            self.planStatus = try await a.planStatus()
        }
    }

    /// "Bei Free bleiben" nach der Probe
    func stayOnFree() async {
        await run { a in try await a.stayOnFree() }
        await refresh()
    }

    func login(email: String, password: String) async {
        await run { a in _ = try await a.login(email: email, password: password) }
        await refresh()
    }

    func revoke(_ id: Int) async {
        await run { a in try await a.revoke(session: id) }
        await refresh()
    }

    func logoutOthers() async {
        await run { a in _ = try await a.logoutOthers() }
        await refresh()
    }

    func logout() async {
        if let account { await account.logout() }
        user = nil
        sessions = []
        planStatus = nil
    }

    /// ZIP in eine temporaere Datei (zum Teilen); nil bei Fehler
    func export() async -> URL? {
        var out: URL?
        await run { a in
            let data = try await a.export()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("studora-export.zip")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            out = url
        }
        return out
    }

    func delete(password: String?) async -> Bool {
        var ok = false
        await run { a in _ = try await a.delete(password: password); ok = true }
        if ok { user = nil; sessions = []; planStatus = nil }
        return ok
    }
}

/// Der Konto-Anschluss fuer die Einstellungen; nil ohne Anschluss (Tests, Vorschauen)
private struct UFStudoraAccountKey: EnvironmentKey { static let defaultValue: StudoraAccountLink? = nil }

extension EnvironmentValues {
    var ufStudoraAccount: StudoraAccountLink? {
        get { self[UFStudoraAccountKey.self] }
        set { self[UFStudoraAccountKey.self] = newValue }
    }
}

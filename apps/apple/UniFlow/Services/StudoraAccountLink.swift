import Foundation
import SwiftUI
import UIKit
import UniFlowCore

/// Sitzungs-Token des StudiNow-Kontos im Schluesselbund dieses Geraets, je Apple-Nutzer; nie synchronisiert. Konto
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

/// Anfragen an den StudiNow-Dienst (nur https)
struct URLSessionServiceTransport: ServiceHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        guard let url = URL(string: request.url), url.scheme == "https" else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("StudiNow-iPad/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k)] = String(describing: v) }
        return ServiceHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

extension Notification.Name {
    /// Geraete-Abgleich hat hier etwas geaendert; offene Dokumente holen ihren Stand neu
    static let uniflowAccountSynced = Notification.Name("uniflow.accountSynced")
}

/// StudiNow-Konto auf dem iPad (V1, Entscheidung des Inhabers vom 29.10.2026; Plan ENTSCHEIDUNGEN-INHABER-2026-10-29 §3):
/// anmelden mit E-Mail (wer sich auf Windows registriert hat) und spaeter mit Apple, angemeldete Geraete, Datenexport,
/// Konto loeschen. Noch ohne Abgleich der Notizen (Stufe 2). Sichtbar erst mit Dienst-Adresse (`StudoraServiceURL`).
@MainActor
final class StudoraAccountLink: ObservableObject {
    /// Adresse des Dienstes aus der Info.plist; leer = es gibt noch keinen Server (Konto unsichtbar)
    nonisolated static var serviceURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "StudoraServiceURL") as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil }
    }
    nonisolated static var available: Bool { serviceURL != nil }

    /// Feste Kennung dieses Geraets fuer die Geraeteliste (nicht die Werbe-ID, nur fuer StudiNow)
    static var deviceID: String {
        let key = "uniflow.account.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "ipad-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    @Published private(set) var user: StudoraAccount.User? {
        didSet { updateCommunityRoute() }
    }
    @Published private(set) var sessions: [StudoraAccount.Session] = []
    /// Tarif und Probe beim Dienst (nil: nicht angemeldet oder noch nicht geladen)
    @Published private(set) var planStatus: StudoraAccount.PlanStatus? {
        didSet { Entitlements.shared.useServiceTrial(planStatus?.trialPlan.flatMap(UFPlan.init(rawValue:))) }
    }
    /// Credits der StudiNow-KI in diesem Monat (`credits` aus `GET /api/entitlements`); nil ohne Konto oder ohne Stand
    @Published private(set) var credits: StudoraCredits?
    /// Was die letzte KI-Antwort gekostet hat (`charged`), fuer die Kostenzeile; nil bis zur ersten Antwort mit Stand
    @Published private(set) var lastCharge: StudoraCredits.Charge?
    private var creditsClient: StudoraCredits.Client?
    @Published private(set) var busy = false
    @Published var message: String?
    /// Handlung zur letzten Fehlermeldung (z. B. Bestaetigungslink erneut senden)
    @Published private(set) var messageAction: ServiceErrorAction?
    /// Rueckmeldung ohne Fehler (z. B. "Link geschickt")
    @Published private(set) var notice: String?

    /// Geraete-Abgleich (Vertrag G2): laeuft gerade, letztes Ergebnis in diesem Prozess
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: DeviceSyncResult?
    /// Automatisch hoechstens alle 3 Minuten (`sync_client.start_background`)
    static let autoSyncInterval: TimeInterval = 180
    private var lastSyncAt: Date?
    private var host: LocalBackendHost?
    private var university: String?
    private var routedAccount: String?

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
        if r.applied + r.deleted + r.notesMerged > 0 { NotificationCenter.default.post(name: .uniflowAccountSynced, object: nil) }
        return r.applied + r.deleted > 0
    }

    /// Community ueber den Dienst (G4) nur mit Konto derselben Hochschule, sonst bleibt CloudKit
    private func updateCommunityRoute() {
        let id = user.map(\.id).flatMap { Self.canSync(user: user, university: university, blocked: false) ? $0 : nil }
        guard id != routedAccount else { return }
        routedAccount = id
        CommunityMatches.shared.invalidate()
        guard id != nil, let account, let host, let university else {
            CommunityRoute.shared.service = nil
            return
        }
        guard let membership = ActiveContainer.current?.membership else {
            CommunityRoute.shared.service = nil
            routedAccount = nil
            return
        }
        CommunityRoute.shared.service = ServiceCommunityService(
            transport: account, university: university, membership: membership,
            localFingerprints: { await CommunityCourses.localFingerprints(host: host) },
            localCourses: { await CommunityCourses.spaces(host: host, university: university) })
    }

    func use(userScope: String?, host: LocalBackendHost? = nil, university: String? = nil) {
        self.host = host
        self.university = university
        defer { updateCommunityRoute() }
        guard userScope != scope else { return }
        scope = userScope
        lastSync = nil
        lastSyncAt = nil
        user = nil
        sessions = []
        planStatus = nil
        clearCredits()
        account = nil
        creditsClient = nil
        guard let userScope, let base = Self.serviceURL else { return }
        let tokens = StudoraAccountKeychain(userScope: userScope)
        account = StudoraAccount(base: base, http: URLSessionServiceTransport(), tokens: tokens,
                                 deviceID: Self.deviceID, deviceName: UIDevice.current.name)
        creditsClient = StudoraCredits.Client(base: base, http: URLSessionServiceTransport(), tokens: tokens)
        Task { await refresh() }
    }

    // MARK: Credits

    /// Nur Tests und Vorschauen: Credits ueber einen Schein-Dienst laden, ohne Dienst-Adresse im Build
    func attach(creditsClient: StudoraCredits.Client?) {
        self.creditsClient = creditsClient
    }

    private func clearCredits() {
        credits = nil
        lastCharge = nil
    }

    /// Stand neu laden (`GET /api/entitlements`); ein Fehler laesst den letzten Stand stehen, abgemeldet wird er nil
    func refreshCredits() async {
        guard let creditsClient else { clearCredits(); return }
        if let c = try? await creditsClient.fetch() { credits = c } else if creditsClient.tokens.load() == nil { clearCredits() }
    }

    /// Antwort von `/api/ai/tutor` oder `/api/ai/flashcards`: neuer Stand und was sie gekostet hat (`charged`,
    /// `replay`). Ohne `credits` in der Antwort (eigener PC, ChatGPT auf dem Geraet) aendert sich nichts.
    func noteAIResponse(_ response: JSONValue) {
        guard let c = StudoraCredits.parse(response["credits"]) else { return }
        credits = c
        lastCharge = StudoraCredits.charge(in: response)
    }

    /// Fehler einer KI-Anfrage: beim 429 `credits_exhausted` den Stand aus dem Rumpf uebernehmen (Rest 0).
    /// Rueckgabe: war es dieser Fehler? Die Oberflaeche zeigt dann `localizedDescription` und den Weg zum Tarif.
    @discardableResult
    func noteAIError(_ error: Error) -> Bool {
        guard StudoraCredits.isExhausted(error) else { return false }
        if let c = StudoraCredits.exhaustedState(error) { credits = c } else if var c = credits { c.remaining = 0; credits = c }
        lastCharge = nil
        return true
    }

    private func run(_ op: @escaping (StudoraAccount) async throws -> Void) async {
        guard let account else { return }
        busy = true
        message = nil
        defer { busy = false }
        messageAction = nil
        do { try await op(account) } catch let e as AccountError {
            // Texte der Fehlercodes: ServiceErrorText (UniFlowCore), mit Retry-After
            message = e.userMessage
            messageAction = e.action
            if e.code == "unauthenticated" { user = nil; sessions = []; planStatus = nil; clearCredits() }
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard let account, await account.isSignedIn else { user = nil; sessions = []; planStatus = nil; clearCredits(); return }
        await run { a in
            let me = try await a.me()
            self.user = me.user
            self.sessions = me.sessions
            self.planStatus = try await a.planStatus()
            // Credits-Stand aus derselben Antwort (`credits`); ohne Stand bleibt die Zeile weg
            await self.refreshCredits()
        }
        if user != nil, PendingInvite.current() != nil { _ = await redeemPendingInvite() }
    }

    /// Gemerkte Einladung (`https://studinow.app/i/<CODE>`, Views/Settings/InviteView.swift) einmal beim Dienst einloesen,
    /// sobald ein Konto angemeldet ist; ohne Konto bleibt der Code liegen. Nur eine Angebotscode-Belohnung fuer die
    /// einladende Person haengt daran, nie ein Tarif fuer dieses Konto.
    func redeemPendingInvite() async -> PendingInvite.Outcome {
        let out = await PendingInvite.redeem(using: account, signedIn: user != nil)
        if out == .accepted { notice = InviteTexts.accepted }
        return out
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

    /// Bestaetigungslink fuer die E-Mail-Adresse erneut senden
    func resendVerification() async {
        notice = nil
        var text: String?
        await run { a in text = try await a.resendVerification() }
        notice = text
        // nur nach Erfolg neu laden: refresh() setzt die Fehlermeldung zurueck
        if text != nil { await refresh() }
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
        clearCredits()
    }

    /// ZIP in eine temporaere Datei (zum Teilen); nil bei Fehler
    func export() async -> URL? {
        var out: URL?
        await run { a in
            let data = try await a.export()
            let url = try Self.exportFileURL()
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            out = url
        }
        return out
    }

    /// Ablage des Exports: im Teilen-Ordner des Containers (`AppTemp`), damit ihn der naechste Start und "Konto
    /// löschen" bzw. "Daten dieser Hochschule löschen" entfernen. Vorher lag die ZIP mit allen Kontodaten dauerhaft im
    /// gemeinsamen tmp-Ordner aller Konten (Audit Robustheit 03.11.2026).
    static func exportFileURL(container: UUID? = ActiveContainer.current?.layout.identifier) throws -> URL {
        try AppTemp.file("konto-export", name: "studinow-export.zip", container: container)
    }

    func delete(password: String?) async -> Bool {
        var ok = false
        await run { a in _ = try await a.delete(password: password); ok = true }
        if ok { user = nil; sessions = []; planStatus = nil; clearCredits() }
        return ok
    }
}

/// Credits der StudiNow-KI (docs/ABO-SYSTEM.md Abschnitt 6a, app/credits.py): 1 Credit = 1 Cent echter KI-Kosten, Pro AI
/// 100 je Kalendermonat, Probe 25, andere Tarife 0. Stand aus `credits` in `GET /api/entitlements` und in den
/// KI-Antworten (`/api/ai/tutor`, `/api/ai/flashcards`: zusaetzlich `charged`, `replay`). Reihenfolge der Bezahlung:
/// Geteiltes (0) -> eigenes ChatGPT (0) -> Credits. Am eigenen PC und ohne Konto ist der Stand nil.
struct StudoraCredits: Equatable {
    /// "2026-11"
    var period: String
    var allowance: Int
    var used: Int
    var remaining: Int
    /// Beginn des naechsten Monats (ISO mit Versatz, Europe/Berlin): ab dann gibt es neue Credits
    var resetsAt: String?
    var plan: String?

    /// Was die letzte KI-Antwort gekostet hat (`charged`); `replay`: gespeicherte Antwort zur selben request_id, nichts
    /// neu berechnet
    struct Charge: Equatable {
        var credits: Int
        var replay: Bool
    }

    /// Fehlercode des Dienstes, wenn der Rest des Monats nicht reicht (429)
    static let exhaustedCode = "credits_exhausted"

    /// `credits` einer Antwort; nil, wenn es fehlt oder null ist (eigener PC, kein Konto)
    static func parse(_ v: JSONValue?) -> StudoraCredits? {
        guard let v, let allowance = v["allowance"]?.double else { return nil }
        let used = Int(v["used"]?.double ?? 0)
        let reserved = Int(v["reserved"]?.double ?? 0)
        let remaining = v["remaining"]?.double.map(Int.init) ?? max(0, Int(allowance) - used - reserved)
        return StudoraCredits(period: v["period"]?.string ?? "", allowance: Int(allowance), used: used, remaining: max(0, remaining),
                              resetsAt: v["resets_at"]?.string, plan: v["plan"]?.string)
    }

    /// `charged`/`replay` einer KI-Antwort (im `credits`-Objekt, zur Sicherheit auch oben); nil ohne Credits-Stand
    static func charge(in response: JSONValue) -> Charge? {
        let c = response["credits"]
        guard let charged = c?["charged"]?.double ?? response["charged"]?.double else { return nil }
        return Charge(credits: Int(charged), replay: c?["replay"]?.bool ?? response["replay"]?.bool ?? false)
    }

    /// Ist das der 429 `credits_exhausted` des Dienstes? Die Meldung dazu ("Credits für diesen Monat aufgebraucht – am
    /// 1. gibt es neue.") kommt als `detail` und steht schon in `localizedDescription` (APIError, AccountError).
    static func isExhausted(_ error: Error) -> Bool {
        if let e = error as? APIError { return e.code == exhaustedCode }
        if let e = error as? AccountError { return e.code == exhaustedCode }
        return false
    }

    /// Stand aus dem Rumpf des 429 (`credits` mit `needed`); nil, wenn der gekuerzte Text kein JSON mehr ist
    static func exhaustedState(_ error: Error) -> StudoraCredits? {
        guard let e = error as? APIError, e.code == exhaustedCode, let j = try? JSONValue.parse(Data(e.message.utf8)) else { return nil }
        return parse(j["credits"] ?? j["detail"]?["credits"])
    }

    /// Holt den Stand aus `GET /api/entitlements` mit dem Sitzungs-Token des Kontos (dieselbe Antwort wie
    /// `StudoraAccount.planStatus`, nur das Feld `credits`); nil ohne Token oder ohne `credits`
    struct Client: Sendable {
        let base: String
        let http: ServiceHTTPTransport
        let tokens: AccountTokenStore

        func fetch() async throws -> StudoraCredits? {
            guard let t = tokens.load() else { return nil }
            let url = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/entitlements"
            let r = try await http.send(AIHTTPRequest(method: "GET", url: url, headers: ["Accept": "application/json", "Authorization": "Bearer \(t)"], body: nil))
            guard (200..<300).contains(r.status), let j = try? JSONValue.parse(r.body) else { return nil }
            return parse(j["credits"])
        }
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

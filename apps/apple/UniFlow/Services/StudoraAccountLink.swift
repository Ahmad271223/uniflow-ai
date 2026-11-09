import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import StoreKit
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

/// Anfragen an den StudiNow-Dienst (nur https). `session` austauschbar (Tests: URLProtocol-Attrappe), `timeout` fuer
/// KI-Anfragen laenger (ein Schritt "Ganzes Dokument" dauert)
struct URLSessionServiceTransport: ServiceHTTPTransport {
    var session: URLSession = .shared
    var timeout: TimeInterval = 60

    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        guard let url = URL(string: request.url), url.scheme == "https" else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("StudiNow-iPad/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: r)
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
/// anmelden mit E-Mail (wer sich auf Windows registriert hat) oder mit Apple (nativ, Token-Tausch beim Dienst),
/// angemeldete Geraete, Datenexport, Konto loeschen. Seit 05.11.2026 der Weg zur StudiNow-KI (Pro AI, Probe): mit
/// Anmeldung und passendem Tarif haengt `use` die StudiNow-KI ins lokale Backend (`LocalAI.setService`), meldet
/// App-Store-Kaeufe an `POST /api/billing/apple/verify` und zeigt den Credits-Stand (docs/ABO-SYSTEM.md Abschnitt 6b).
@MainActor
final class StudoraAccountLink: ObservableObject {
    /// Hinweis an den KI-Stellen bei Pro AI bzw. Probe ohne Anmeldung (`StudiNowAIAccess.signInRequired`)
    nonisolated static let aiSignInHint = "Mit StudiNow Pro AI antwortet hier die StudiNow-KI. Melde dich dafür einmal mit deinem StudiNow-Konto an – am einfachsten mit Apple."

    /// Feste Adresse des Dienstes, wie `service_link.DEFAULT_SERVICE_URL` der Windows-App
    nonisolated static let defaultServiceURL = "https://app.studinow.app"
    /// Schluessel fuer eine andere Adresse (Info.plist oder Startargument `-StudoraServiceURL https://…`, z. B. Testdienst)
    nonisolated static let serviceURLKey = "StudoraServiceURL"

    /// Adresse des Dienstes: Startargument bzw. Einstellung > Info.plist > `defaultServiceURL`; nur https. Ein leerer
    /// Eintrag in der Info.plist schaltet den Dienst ab (Konto unsichtbar, keine StudiNow-KI).
    nonisolated static var serviceURL: String? {
        resolveServiceURL(info: Bundle.main.object(forInfoDictionaryKey: serviceURLKey) as? String,
                          override: UserDefaults.standard.string(forKey: serviceURLKey))
    }
    nonisolated static var available: Bool { serviceURL != nil }

    /// Reine Regel fuer `serviceURL` (testbar)
    nonisolated static func resolveServiceURL(info: String?, override: String?) -> String? {
        func https(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("https://"), URL(string: t)?.host != nil else { return nil }
            return t.hasSuffix("/") ? String(t.dropLast()) : t
        }
        if let o = https(override) { return o }
        if let info { return info.trimmingCharacters(in: .whitespaces).isEmpty ? nil : https(info) }
        return defaultServiceURL
    }

    /// Feste Kennung dieses Geraets fuer die Geraeteliste (nicht die Werbe-ID, nur fuer StudiNow)
    static var deviceID: String {
        let key = "uniflow.account.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "ipad-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    @Published private(set) var user: StudoraAccount.User? {
        didSet { updateCommunityRoute(); updateAI(); updateAccountToken() }
    }
    @Published private(set) var sessions: [StudoraAccount.Session] = []
    /// Tarif und Probe beim Dienst (nil: nicht angemeldet oder noch nicht geladen)
    @Published private(set) var planStatus: StudoraAccount.PlanStatus? {
        didSet {
            // Probe des Kontos: Freischaltung und Anzeige (Resttage, Ende) aus demselben Stand (Entscheidung 09.11.2026)
            Entitlements.shared.useServiceStatus(planStatus)
            updateAccountToken()
            updateAI()
        }
    }
    /// Weg zur StudiNow-KI (`StudiNowAIAccess`): bereit, Anmeldung fehlt, Tarif fehlt; die KI-Stellen richten sich danach
    @Published private(set) var aiAccess: StudiNowAIAccess = .planRequired
    /// StudiNow-KI dieses Apple-Nutzers (nil ohne Dienst-Adresse); haengt nur mit `aiAccess == .ready` im Backend
    private(set) var studinowAI: StudiNowAI?
    private var tokenStore: AccountTokenStore?
    private let entitlements: Entitlements
    private var planWatch: AnyCancellable?
    private var attachTask: Task<Void, Never>?
    /// Kaeufe dieses Kontos wurden in diesem Prozess schon an den Dienst gemeldet
    private var reportedPurchasesFor: String?
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
    /// Steigt bei jedem Wechsel des Kontos (anderer Apple-Nutzer, Abmelden, Konto geloescht): eine Antwort, die fuer
    /// ein frueheres Konto unterwegs war, wird danach verworfen (Audit P37-01, gleiche Ursache wie P36-03)
    private var accountEpoch = 0

    /// Gilt eine Antwort noch fuer das Konto, fuer das sie angefragt wurde?
    private func stillCurrent(_ account: StudoraAccount, _ epoch: Int) -> Bool {
        self.account === account && accountEpoch == epoch
    }

    /// `entitlements`: Tarif auf dem iPad (App Store, Probe); Tests geben einen eigenen
    init(entitlements: Entitlements? = nil) {
        let ent = entitlements ?? .shared
        self.entitlements = ent
        // Tarif auf dem iPad geaendert (Kauf, Ablauf, Probe): Weg zur KI neu bestimmen (nach dem Setzen, daher im naechsten Takt)
        planWatch = ent.$plan.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.updateAI() } }
    }

    /// `true`, wenn der Abgleich gerade laufen darf: angemeldet, gleiche Hochschule wie das Konto, keine Demo-Inhalte
    static func canSync(user: StudoraAccount.User?, university: String?, blocked: Bool) -> Bool {
        guard let user, !blocked else { return false }
        return user.university == nil || user.university == university
    }

    /// Abgleich mit dem Konto; Rueckgabe: hat er hier etwas geaendert? `force`: Knopf, sonst hoechstens alle 3 Minuten
    @discardableResult
    func syncNow(force: Bool = false) async -> Bool {
        guard !syncing, let account, let host, let id = user?.id,
              force || lastSyncAt.map({ Date().timeIntervalSince($0) >= Self.autoSyncInterval }) ?? true else { return false }
        // sofort belegt: zwei Anstoesse kurz nacheinander (Vordergrund, Knopf) starteten sonst zwei Laeufe, die beide
        // dieselben neuen Zeilen senden
        syncing = true
        defer { syncing = false }
        let epoch = accountEpoch
        // nach jedem Warten: noch dasselbe Konto, derselbe Container? Sonst gehoert das Ergebnis nicht hierher (P45-01)
        func current() -> Bool { stillCurrent(account, epoch) && self.host === host && user?.id == id }
        guard let backend = try? await host.backend(), current() else { return false }
        // Demo-Inhalte gehoeren nicht ins Konto; direkt aus der Datenbank, `demoActive` kommt beim Start erst spaeter
        let demo = (try? await backend.context.database.withConnection { try DemoContent.isEnabled($0) }) ?? true
        guard current(), Self.canSync(user: user, university: university, blocked: demo) else { return false }
        let r = await DeviceSync(database: backend.context.database, transport: account, device: Self.deviceID).run(account: id)
        // die Daten liegen in der Datenbank vom Start (eigener Container); Stand und Meldung gelten nur fuer ihn
        guard current() else { return false }
        lastSync = r
        // nur ein gelungener Lauf zaehlt fuer die 3 Minuten; nach einem Fehler versucht es der naechste Anstoss (P37-09)
        if r.ok { lastSyncAt = Date() }
        // auch eine reine Zusammenfuehrung von Notizen ist eine Aenderung: offene Fenster laden neu (P37-05)
        let changed = r.applied + r.deleted + r.notesMerged > 0
        if changed { NotificationCenter.default.post(name: .uniflowAccountSynced, object: nil) }
        return changed
    }

    #if DEBUG
    /// nur Tests: Container (lokales Backend) und Hochschule wie `use`, ohne den Konto-Anschluss neu zu bauen
    func attachHostForTesting(_ host: LocalBackendHost?, university: String?) {
        self.host = host
        self.university = university
    }
    #endif

    /// Community ueber den Dienst (G4) – vorerst AUS (07.11.2026, Geraetetest): Mit Konto wechselte die Community vom
    /// iCloud-Kanal zum Dienst, der keine Fragen und Antworten je Modul kennt ("gibt es mit diesem Dienst noch nicht"),
    /// und Pro-AI-Nutzer (Dienst) und Plus-Nutzer (iCloud) sahen getrennte Communitys. Auf dem iPad laeuft die Community
    /// deshalb fuer alle ueber CloudKit; der Dienst-Weg kommt mit der Windows-App zurueck.
    nonisolated static let communityViaService = false

    /// Community ueber den Dienst (G4) nur mit Konto derselben Hochschule, sonst bleibt CloudKit
    private func updateCommunityRoute() {
        guard Self.communityViaService else {
            if CommunityRoute.shared.service != nil { CommunityRoute.shared.service = nil; CommunityMatches.shared.invalidate() }
            routedAccount = nil
            return
        }
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
        // anderer Container (Hochschule) beim gleichen Konto: Stand und 3-Minuten-Sperre gehoeren zum alten (P37-04)
        if host !== self.host {
            lastSync = nil
            lastSyncAt = nil
        }
        self.host = host
        self.university = university
        defer { updateCommunityRoute(); updateAI() }
        guard userScope != scope else { return }
        scope = userScope
        accountEpoch += 1
        lastSync = nil
        lastSyncAt = nil
        user = nil
        sessions = []
        planStatus = nil
        clearCredits()
        account = nil
        creditsClient = nil
        studinowAI = nil
        tokenStore = nil
        reportedPurchasesFor = nil
        entitlements.verifyOnServer = nil
        guard let userScope, let base = Self.serviceURL else { return }
        let tokens = StudoraAccountKeychain(userScope: userScope)
        account = StudoraAccount(base: base, http: URLSessionServiceTransport(), tokens: tokens,
                                 deviceID: Self.deviceID, deviceName: UIDevice.current.name)
        creditsClient = StudoraCredits.Client(base: base, http: URLSessionServiceTransport(), tokens: tokens)
        attachAI(base: base, http: URLSessionServiceTransport(timeout: 180), tokens: tokens)
        Task { await refresh() }
    }

    // MARK: StudiNow-KI

    /// StudiNow-KI mit diesem Transport und Token bauen (App: URLSession; Tests: Attrappe). Haengt sie nur bei
    /// `aiAccess == .ready` ins Backend.
    func attachAI(base: String, http: ServiceHTTPTransport, tokens: AccountTokenStore) {
        tokenStore = tokens
        // Einwilligung vor der ersten Anfrage (App Store 5.1.2(i)): zentral in der StudiNow-KI, je Konto
        let gate = AppAIConsentGate(center: consentCenter) { [weak self] in self?.aiConsentAccount ?? "" }
        studinowAI = StudiNowAI(base: base, http: http, tokens: tokens, consent: gate, onCredits: { [weak self] c in
            Task { @MainActor in self?.noteAIResponse(["credits": c]) }
        }, onSignedOut: { [weak self] in
            Task { @MainActor in self?.signedOutByService() }
        })
        updateAI()
    }

    /// Wo die Einwilligung zur StudiNow-KI liegt (Tests geben eine eigene)
    var consentCenter: AIConsentCenter = .shared

    /// Konto der Einwilligung: das StudiNow-Konto, solange es noch nicht geladen ist der Apple-Nutzer dieses Geraets
    var aiConsentAccount: String {
        if let id = user?.id { return "konto:" + id }
        return "geraet:" + (scope ?? "ohne")
    }

    /// Zeitpunkt der Einwilligung fuer dieses Konto; nil = (noch) nicht zugestimmt
    var aiConsentGrantedAt: Date? { consentCenter.grantedAt(aiConsentAccount) }

    /// "KI-Einwilligung widerrufen": die naechste Anfrage an die StudiNow-KI fragt erneut
    func revokeAIConsent() {
        consentCenter.revoke(aiConsentAccount)
        objectWillChange.send()
    }

    /// Weg zur KI neu bestimmen und die StudiNow-KI ins Backend haengen bzw. herausnehmen. Ohne passenden Tarif oder
    /// ohne Anmeldung haengt nichts: dann geht keine Anfrage an den Dienst.
    func updateAI() {
        let signedIn = user != nil || tokenStore?.load() != nil
        let access = StudiNowAIAccess.decide(serviceConfigured: studinowAI != nil, signedIn: signedIn, localPlan: entitlements.plan.rawValue,
                                             servicePlan: planStatus?.plan, serviceTrialActive: planStatus?.trialActive ?? false)
        if access != aiAccess { aiAccess = access }
        guard let host else { return }
        attachTask?.cancel()
        attachTask = Task { @MainActor [weak self] in
            guard let backend = try? await host.backend(), let self, !Task.isCancelled else { return }
            backend.context.ai.setService(self.aiAccess == .ready ? self.studinowAI : nil)
        }
    }

    /// Der Dienst hat die Sitzung beendet (401 bei einer KI-Anfrage): abgemeldet, KI-Stellen zeigen die Anmeldung
    private func signedOutByService() {
        user = nil
        sessions = []
        planStatus = nil
        clearCredits()
        entitlements.verifyOnServer = nil
        updateAI()
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
        let epoch = accountEpoch
        let c = try? await creditsClient.fetch()
        guard accountEpoch == epoch else { return }                 // inzwischen anderes Konto: der Stand gehoert nicht hierher
        if let c { credits = c } else if creditsClient.tokens.load() == nil { clearCredits() }
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

    /// Knopf zu einem Fehler der KI: Tarif bei fehlendem Recht, Kontingent oder Credits (beim 429 `credits_exhausted`
    /// wird der Stand uebernommen), Anmeldung ohne gueltige Sitzung; nil = nur die Meldung
    static func errorAction(_ error: Error, account: StudoraAccountLink?) -> StudiNowAIAction? {
        if account?.noteAIError(error) ?? StudoraCredits.isExhausted(error) { return .plans }
        let code = (error as? APIError)?.code ?? (error as? AccountError)?.code
        let action = StudiNowAIText.action(code: code)
        if action == .signIn, let account { Task { await account.refresh() } }      // Sitzung beendet: Karte und KI-Stellen zeigen es
        return action
    }

    /// Beschriftung des Knopfs zu `errorAction`
    nonisolated static func errorButton(_ action: StudiNowAIAction) -> String {
        action == .signIn ? "Mit StudiNow-Konto anmelden" : "Tarif ansehen"
    }

    private func run(_ op: @escaping (StudoraAccount) async throws -> Void) async {
        guard let account else { return }
        let epoch = accountEpoch
        busy = true
        message = nil
        defer { busy = false }
        messageAction = nil
        do { try await op(account) } catch let e as AccountError {
            // der Fehler eines frueheren Kontos zeigt nichts und meldet das jetzige nicht ab
            guard stillCurrent(account, epoch) else { return }
            // Texte der Fehlercodes: ServiceErrorText (UniFlowCore), mit Retry-After
            message = e.userMessage
            messageAction = e.action
            if e.code == "unauthenticated" { user = nil; sessions = []; planStatus = nil; clearCredits(); entitlements.verifyOnServer = nil }
        } catch {
            guard stillCurrent(account, epoch) else { return }
            message = error.localizedDescription
        }
    }

    /// Konto, Geraete, Tarif und Credits neu laden. Nach jedem Warten auf den Dienst: gilt die Antwort noch fuer dieses
    /// Konto? Sonst wird sie verworfen - vorher landeten Name, E-Mail, Tarif und Credits von A bei B, wenn A sich
    /// abmeldete bzw. ein anderer Apple-Nutzer kam, waehrend die Antwort noch unterwegs war (Audit P37-01).
    func refresh() async {
        guard let account else {
            user = nil; sessions = []; planStatus = nil; clearCredits(); entitlements.verifyOnServer = nil; updateAI(); return
        }
        let epoch = accountEpoch
        let signedIn = await account.isSignedIn
        guard stillCurrent(account, epoch) else { return }
        guard signedIn else {
            user = nil; sessions = []; planStatus = nil; clearCredits(); entitlements.verifyOnServer = nil; updateAI(); return
        }
        await run { a in
            let me = try await a.me()
            guard self.stillCurrent(a, epoch) else { return }
            self.user = me.user
            self.sessions = me.sessions
            let plan = try await a.planStatus()
            guard self.stillCurrent(a, epoch) else { return }
            self.planStatus = plan
            // Credits-Stand aus derselben Antwort (`credits`); ohne Stand bleibt die Zeile weg
            await self.refreshCredits()
        }
        guard stillCurrent(account, epoch) else { return }
        updateAI()
        guard user != nil else { return }
        hookPurchases()
        if reportedPurchasesFor != user?.id { await reportPurchases() }
        if PendingInvite.current() != nil { _ = await redeemPendingInvite() }
    }

    // MARK: Abo aus dem App Store beim Dienst (docs/ABO-SYSTEM.md Abschnitt 3)

    /// Neue Transaktionen (Kauf, Verlaengerung, Wiederherstellen) gehen an den Dienst, solange ein Konto angemeldet ist.
    /// Der Kauf auf dem iPad gilt immer (StoreKit); ein Fehler des Dienstes sperrt ihn nicht.
    private func hookPurchases() {
        entitlements.verifyOnServer = { [weak self] jws in
            await self?.reportTransaction(jws)
            return true
        }
    }

    /// `appAccountToken` fuer den naechsten Kauf: das vom Dienst gemeldete Token, sonst die UniFlow-ID des angemeldeten
    /// Kontos als UUID (wie `apple_store.account_token`). So traegt ein Kauf mit Anmeldung das Konto auch dann, wenn
    /// `GET /api/entitlements` gerade nicht geantwortet hat (Audit P36-04); ohne Anmeldung kein Token.
    private func updateAccountToken() {
        UFBillingServiceLink.accountToken = UFBillingServiceLink.accountToken(service: planStatus?.appleAccountToken,
                                                                              userID: user?.id)
    }

    /// Gilt eine Antwort noch fuer dieses Konto? Nach einem Wechsel (anderer Apple-Nutzer: neues `account`; Abmelden und
    /// anderes Konto: andere `user.id`) wird ein spaetes Ergebnis verworfen, sonst landeten Tarif, Credits und
    /// `appAccountToken` des alten Kontos beim neuen (Audit P36-03).
    private func isCurrent(_ account: StudoraAccount, _ userID: String) -> Bool {
        self.account === account && user?.id == userID
    }

    /// Alle gueltigen Abos dieser Apple-ID einmal je Anmeldung melden (Wiederherstellen beim Dienst), danach den Stand
    /// neu laden; ohne Abo keine Anfrage
    func reportPurchases() async {
        guard let account, let id = user?.id else { return }
        reportedPurchasesFor = id
        var sent = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard isCurrent(account, id) else { return }
            guard case .verified = result else { continue }
            await reportTransaction(result.jwsRepresentation, reload: false)
            sent = true
        }
        guard sent, isCurrent(account, id) else { return }
        let status = try? await account.planStatus()
        guard isCurrent(account, id) else { return }
        planStatus = status ?? planStatus
        await refreshCredits()
    }

    /// Eine signierte Transaktion an `POST /api/billing/apple/verify`; 409 (Abo gehoert zu einem anderen Konto) zeigt die
    /// Karte, 503 `apple_not_configured` und Netzfehler bleiben still (das Abo gilt auf dem iPad trotzdem). Hat in der
    /// Zwischenzeit das Konto gewechselt, bleibt die Antwort ohne Folgen.
    func reportTransaction(_ jws: String, reload: Bool = true) async {
        guard let account, let id = user?.id, !jws.isEmpty else { return }
        do {
            try await account.verifyApple(signedTransaction: jws)
            guard reload, isCurrent(account, id) else { return }
            let status = try? await account.planStatus()
            guard isCurrent(account, id) else { return }
            planStatus = status ?? planStatus
            await refreshCredits()
        } catch let e as AccountError where e.code == "subscription_owned_by_other_account" {
            if isCurrent(account, id) { message = e.userMessage }
        } catch {
            // nicht erreichbar oder Pruefung im Dienst nicht eingerichtet: beim naechsten Start erneut
            if isCurrent(account, id) { reportedPurchasesFor = nil }
        }
    }

    #if DEBUG
    /// nur Tests: Konto ueber einen Schein-Dienst statt der Dienst-Adresse
    func attachForTesting(account: StudoraAccount, scope: String) {
        self.scope = scope
        self.account = account
    }
    #endif

    // MARK: Mit Apple anmelden

    /// Nonce der laufenden Apple-Anmeldung (Rohwert; an Apple geht nur sein SHA-256)
    private var appleNonce: String?

    /// "Mit Apple anmelden" (`SignInWithAppleButton`, onRequest): E-Mail-Wunsch und Nonce in die Anfrage an Apple
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        appleNonce = nonce
        request.requestedScopes = [.email]
        request.nonce = Self.sha256(nonce)
    }

    /// Ergebnis von Apple: das `identity_token` geht an `POST /api/account/login/apple`; ein neues Konto bekommt die
    /// Hochschule dieses Containers und beim Dienst die 7-Tage-Probe mit 25 Credits. Gespeichert wird nur das
    /// Sitzungs-Token (Schluesselbund). Abbruch im Apple-Fenster bleibt ohne Meldung.
    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        let nonce = appleNonce
        appleNonce = nil
        switch result {
        case .failure(let error):
            if let e = error as? ASAuthorizationError, e.code == .canceled { return }
            message = "Die Anmeldung mit Apple hat nicht geklappt: \(error.localizedDescription)"
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                message = "Apple hat keine Anmeldung geliefert. Bitte erneut versuchen."
                return
            }
            await loginWithApple(identityToken: token, nonce: nonce, email: credential.email)
        }
    }

    /// Tausch des Apple-Tokens gegen eine Sitzung beim Dienst (auch fuer Tests ohne Apple-Fenster)
    func loginWithApple(identityToken: String, nonce: String?, email: String?) async {
        let uni = university
        await run { a in _ = try await a.loginWithApple(identityToken: identityToken, nonce: nonce, university: uni, email: email) }
        await refresh()
    }

    /// Zufaelliger Nonce (32 Zeichen); an Apple geht nur sein SHA-256, an den Dienst der Rohwert
    nonisolated static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var g = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }

    nonisolated static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
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
        let (a0, epoch) = (account, accountEpoch)
        await run { a in text = try await a.resendVerification() }
        guard let a0, stillCurrent(a0, epoch) else { return }
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
        // ab jetzt gilt keine Antwort mehr, die fuer dieses Konto unterwegs ist
        accountEpoch += 1
        let epoch = accountEpoch
        if let account {
            await account.logout()
            guard stillCurrent(account, epoch) else { return }      // inzwischen anderer Apple-Nutzer: dessen Stand bleibt
        }
        lastSync = nil
        lastSyncAt = nil
        user = nil
        sessions = []
        planStatus = nil
        clearCredits()
        entitlements.verifyOnServer = nil
        reportedPurchasesFor = nil
        updateAI()
    }

    /// ZIP in eine temporaere Datei (zum Teilen); nil bei Fehler
    func export() async -> URL? {
        var out: URL?
        // Ablage im Container dieses Kontos; nach einem Wechsel waehrend des Downloads landet nichts beim neuen
        let container = ActiveContainer.current?.layout.identifier
        let (a0, epoch) = (account, accountEpoch)
        await run { a in
            let data = try await a.export()
            guard let a0, self.stillCurrent(a0, epoch) else { return }
            let url = try Self.exportFileURL(container: container)
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
        let consentAccount = aiConsentAccount
        let (a0, epoch) = (account, accountEpoch)
        await run { a in _ = try await a.delete(password: password); ok = true }
        if ok { consentCenter.revoke(consentAccount) }
        // geloescht ist das Konto, mit dem es begann; der Stand eines inzwischen anderen Kontos bleibt
        guard ok, let a0, stillCurrent(a0, epoch) else { return ok }
        accountEpoch += 1
        user = nil; sessions = []; planStatus = nil; clearCredits(); entitlements.verifyOnServer = nil; updateAI()
        return ok
    }
}

/// Credits der StudiNow-KI (docs/ABO-SYSTEM.md Abschnitt 6a, app/credits.py): 1 Credit = 0,9 Cent echter KI-Kosten, Pro AI
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

// MARK: - Weg zur KI fuer die Ansichten

/// Weg zur StudiNow-KI (`StudoraAccountLink.aiAccess`); Standard `.planRequired`, damit Ansichten ohne Anschluss
/// (Tests, Vorschauen) den Tarif-Hinweis zeigen
private struct UFAIAccessKey: EnvironmentKey { static let defaultValue: StudiNowAIAccess = .planRequired }
/// Die KI-Stellen antworten gerade ueber die StudiNow-KI (mit Credits), nicht ueber das eigene ChatGPT
private struct UFStudiNowAIKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var ufAIAccess: StudiNowAIAccess {
        get { self[UFAIAccessKey.self] }
        set { self[UFAIAccessKey.self] = newValue }
    }

    var ufStudiNowAI: Bool {
        get { self[UFStudiNowAIKey.self] }
        set { self[UFStudiNowAIKey.self] = newValue }
    }
}

/// Reicht den Weg der KI an alle Ansichten weiter (beobachtet ChatGPT und das Konto): `ufAIEnabled` (es kann gefragt
/// werden), `ufStudiNowAI` (ueber die StudiNow-KI, mit Credits) und `ufAIAccess` (Anmeldung oder Tarif fehlt).
/// Reihenfolge wie im Backend (`LocalAI.provider`): eigenes ChatGPT vor der StudiNow-KI.
struct UFAIAccessProvider: ViewModifier {
    @ObservedObject var chatgpt: ChatGPTLink
    @ObservedObject var account: StudoraAccountLink

    func body(content: Content) -> some View {
        let studinow = !chatgpt.enabled && account.aiAccess == .ready
        content
            .environment(\.ufAIEnabled, chatgpt.enabled || studinow)
            .environment(\.ufStudiNowAI, studinow)
            .environment(\.ufAIAccess, account.aiAccess)
    }
}

import AuthenticationServices
import Foundation

/// Konto der App (V1: "Mit Apple anmelden", docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a).
///
/// Nutzerkennung (`credential.user`), Name und E-Mail liegen im Schluesselbund, der Merker "Tarifwahl schon gezeigt"
/// in UserDefaults. Beim Start prueft `verifyCredential()` still den Stand bei Apple; bei `revoked`/`notFound`
/// geht es zurueck zur Begruessung, die lokalen Studiendaten bleiben. Die Pruefung bei Apple und der Speicher sind
/// hinter Protokollen, damit die Logik ohne echte Apple-ID testbar ist (UniFlowTests/AccountStoreTests.swift).
@MainActor
final class AccountStore: ObservableObject {
    /// Bildschirm beim Start: Begruessung -> (nur beim ersten Mal) Tarifwahl -> UniFlow-Oberflaeche
    enum Stage: Equatable { case welcome, planPicker, ready }

    struct Account: Equatable {
        var userID: String
        var name: String?
        var email: String?
        /// nur Debug-Builds: "Anmeldung ueberspringen (Debug)" ohne Apple-ID
        var isDebug: Bool { userID.hasPrefix(AccountStore.debugUserPrefix) }
    }

    enum Keys {
        static let user = "uniflow.apple.user"
        static let name = "uniflow.apple.name"
        static let email = "uniflow.apple.email"
        static let secrets = [user, name, email]
        static let planShown = "uniflow.onboarding.planShown"
        /// gesetzt beim ersten Start dieser Installation (UserDefaults verschwinden mit der App, der Schluesselbund nicht)
        static let installed = "uniflow.account.installed"
    }

    static let debugUserPrefix = "debug."
    /// Debug-Build? Debug-Konten und Hinweise fuer Entwickler gibt es nur dort.
    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    /// Abos kuendigt der Nutzer bei Apple (Richtlinie 5.1.1(v): Hinweis beim Loeschen des Kontos)
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    @Published private(set) var account: Account?
    @Published private(set) var planShown: Bool
    @Published var lastError: String?
    /// einmaliger Hinweis auf der Begruessung, z. B. nach "Konto loeschen"
    @Published var notice: Notice?

    enum Notice: Equatable { case deleted, signedOut }

    private let secrets: AccountSecretStore
    private let defaults: UserDefaults
    private let checker: AppleCredentialChecking
    private var revokeObserver: NSObjectProtocol?

    init(secrets: AccountSecretStore = KeychainSecretStore(), defaults: UserDefaults = .standard,
         checker: AppleCredentialChecking = AppleIDCredentialChecker(), observeRevocation: Bool = true,
         allowsDebugAccount: Bool = AccountStore.isDebugBuild) {
        self.secrets = secrets
        self.defaults = defaults
        self.checker = checker
        // Neuinstallation: alte Schluesselbund-Eintraege einer geloeschten App nicht als Anmeldung uebernehmen
        if !defaults.bool(forKey: Keys.installed) {
            Keys.secrets.forEach(secrets.delete)
            defaults.set(true, forKey: Keys.installed)
        }
        account = secrets.get(Keys.user).map { Account(userID: $0, name: secrets.get(Keys.name), email: secrets.get(Keys.email)) }
        planShown = defaults.bool(forKey: Keys.planShown)
        // Release/TestFlight ueber einem Debug-Build installiert: das Debug-Konto gilt nicht als Anmeldung,
        // sonst waere "Mit Apple anmelden" umgangen (verifyCredential prueft Debug-Konten nicht bei Apple).
        // Die Tarifwahl wurde dann nur im Debug-Build "gezeigt" und erscheint nach der echten Anmeldung erneut.
        if account?.isDebug == true && !allowsDebugAccount {
            signOut()
            planShown = false
            defaults.removeObject(forKey: Keys.planShown)
        }
        if observeRevocation {
            // Apple meldet einen Widerruf auch waehrend die App laeuft (Einstellungen -> Apple-ID -> Mit Apple anmelden)
            revokeObserver = NotificationCenter.default.addObserver(
                forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.verifyCredential() }
            }
        }
    }

    deinit {
        if let revokeObserver { NotificationCenter.default.removeObserver(revokeObserver) }
    }

    var stage: Stage {
        guard account != nil else { return .welcome }
        return planShown ? .ready : .planPicker
    }

    // MARK: Anmelden

    /// Umfang wie in Abschnitt 2a: Name und E-Mail (Apple liefert beides nur bei der ersten Zustimmung)
    nonisolated static func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// Ergebnis von `SignInWithAppleButton`
    func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let c = auth.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Die Anmeldung hat keine Apple-ID geliefert."
                return
            }
            let name = c.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            signIn(userID: c.user, name: name, email: c.email)
        case .failure(let error):
            lastError = Self.message(for: error)
        }
    }

    /// Kern der Anmeldung (auch fuer Tests): Name/E-Mail fehlen bei spaeteren Anmeldungen derselben Apple-ID,
    /// dann bleiben die gespeicherten Werte.
    func signIn(userID: String, name: String?, email: String?) {
        let same = account?.userID == userID
        let next = Account(userID: userID,
                           name: Self.clean(name) ?? (same ? account?.name : nil),
                           email: Self.clean(email) ?? (same ? account?.email : nil))
        secrets.set(next.userID, for: Keys.user)
        if let n = next.name { secrets.set(n, for: Keys.name) } else { secrets.delete(Keys.name) }
        if let e = next.email { secrets.set(e, for: Keys.email) } else { secrets.delete(Keys.email) }
        account = next
        lastError = nil
        notice = nil
    }

    /// Abbruch durch den Nutzer ist kein Fehler; sonst ein kurzer Hinweis auf der Begruessung
    nonisolated static func message(for error: Error, debugBuild: Bool = isDebugBuild) -> String? {
        if let e = error as? ASAuthorizationError {
            switch e.code {
            case .canceled: return nil
            case .unknown:
                // im Debug-Build typisch ohne die Faehigkeit "Sign in with Apple" (Build ohne bezahltes Team);
                // im App Store meist ein Geraet ohne Apple-ID oder ein Systemfehler
                return debugBuild
                    ? "„Mit Apple anmelden“ ist in diesem Build nicht verfügbar. Bitte später erneut versuchen."
                    : "Anmeldung nicht möglich. Prüfe, ob du auf diesem iPad mit deiner Apple-ID angemeldet bist."
            default: break
            }
        }
        return "Anmeldung mit Apple fehlgeschlagen: \(error.localizedDescription)"
    }

    // MARK: Start und Widerruf

    /// still beim Start: widerrufen oder unbekannt -> zurueck zur Begruessung; Fehler (z. B. offline) aendern nichts
    func verifyCredential() async {
        guard let a = account, !a.isDebug else { return }
        let state = await checker.state(forUserID: a.userID)
        guard account?.userID == a.userID else { return }               // waehrenddessen neu angemeldet
        if state == .revoked || state == .notFound {
            signOut()
            notice = .signedOut
        }
    }

    /// Abmelden ohne Loeschen der Studiendaten; die Tarifwahl gilt fuer dieses Geraet als gezeigt
    func signOut() {
        Keys.secrets.forEach(secrets.delete)
        account = nil
    }

    // MARK: Tarifwahl

    func markPlanShown() {
        planShown = true
        defaults.set(true, forKey: Keys.planShown)
    }

    // MARK: Konto loeschen

    /// Richtlinie 5.1.1(v): Konto-Eintraege und Schluesselbund entfernen, zurueck zur Begruessung.
    /// Abos laufen bei Apple weiter, bis der Nutzer sie dort kuendigt (Hinweis mit `manageSubscriptionsURL`).
    func deleteAccount() {
        signOut()
        planShown = false
        defaults.removeObject(forKey: Keys.planShown)
        lastError = nil
        notice = .deleted
    }

    /// Ganzer Ablauf "Konto loeschen" aus den Einstellungen: erst die weiteren Schluesselbund-Eintraege der App
    /// entfernen (`deletionSteps`: Stud.IP-Sitzung, Server-PIN), danach das Konto selbst -> Begruessung.
    /// Heruntergeladene Dateien und Notizen bleiben; `beforeWelcome` laeuft direkt vor dem Wechsel zur Begruessung
    /// (Dialoge schliessen, Route zuruecksetzen).
    func deleteAccount(also steps: [() async -> Void], beforeWelcome: () -> Void = {}) async {
        for step in steps { await step() }
        beforeWelcome()
        deleteAccount()
    }

    /// Schritte fuer `deleteAccount(also:)` in der App: Stud.IP abmelden (Cookie, Webansicht) und Server-PIN loeschen
    static func deletionSteps(studip: StudIPSync, session: Session) -> [() async -> Void] {
        [{ await studip.signOut() }, { session.disconnect() }]
    }

    #if DEBUG
    /// "Anmeldung ueberspringen (Debug)": lokales Konto ohne Apple-ID, wird beim Start nicht bei Apple geprueft
    func skipSignInForDebug() {
        signIn(userID: Self.debugUserPrefix + "local", name: nil, email: nil)
    }
    #endif

    private nonisolated static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

// MARK: - Speicher fuer Kontodaten

/// Schluesselbund-Zugriff fuer das Konto; in Tests ersetzt durch einen Speicher im Arbeitsspeicher
protocol AccountSecretStore {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
    func delete(_ key: String)
}

/// Schluesselbund ueber die vorhandenen Helfer in Session.swift
struct KeychainSecretStore: AccountSecretStore {
    func get(_ key: String) -> String? { Keychain.get(key) }
    func set(_ value: String, for key: String) { Keychain.set(value, for: key) }
    func delete(_ key: String) { Keychain.delete(key) }
}

// MARK: - Stand der Apple-ID

enum AppleCredentialState: Equatable { case authorized, revoked, notFound, transferred, unknown }

/// kleine Schnittstelle um `ASAuthorizationAppleIDProvider.getCredentialState(forUserID:)`
protocol AppleCredentialChecking {
    func state(forUserID id: String) async -> AppleCredentialState
}

struct AppleIDCredentialChecker: AppleCredentialChecking {
    func state(forUserID id: String) async -> AppleCredentialState {
        await withCheckedContinuation { c in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { state, error in
                // ohne Netz oder ohne Berechtigung kommt ein Fehler: dann nicht abmelden
                guard error == nil else { c.resume(returning: .unknown); return }
                switch state {
                case .authorized: c.resume(returning: .authorized)
                case .revoked: c.resume(returning: .revoked)
                case .notFound: c.resume(returning: .notFound)
                case .transferred: c.resume(returning: .transferred)
                @unknown default: c.resume(returning: .unknown)
                }
            }
        }
    }
}

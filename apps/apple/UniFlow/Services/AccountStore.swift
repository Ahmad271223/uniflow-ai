import AuthenticationServices
import Foundation
import UniFlowCore

/// Konto der App (V1: "Mit Apple anmelden", docs/AUFTRAG-APPSTORE-V1.md Abschnitt 2a).
///
/// Nutzerkennung (`credential.user`), Name und E-Mail liegen zusammen in einem Eintrag im Schluesselbund, der Merker "Tarifwahl schon gezeigt",
/// die gewaehlte Hochschule je Nutzer und der Merker "Anmeldeseiten der Hochschule gezeigt" je Nutzer und Hochschule
/// in UserDefaults (Hochschulwahl nach der Tarifwahl, docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 1; keine Erkennung aus
/// E-Mail oder Name; direkt danach die Anmeldeseiten der Hochschule, Views/Onboarding/FirstLoginFlow.swift). Aus Nutzer
/// und Hochschule folgt der Container aller Daten (`containerKey`, ContainerManager). Beim Start prueft `verifyCredential()` still den Stand bei Apple; bei `revoked`/`notFound`
/// geht es zurueck zur Begruessung, die lokalen Studiendaten bleiben. Die Pruefung bei Apple und der Speicher sind
/// hinter Protokollen, damit die Logik ohne echte Apple-ID testbar ist (UniFlowTests/AccountStoreTests.swift).
@MainActor
final class AccountStore: ObservableObject {
    /// Bildschirm beim Start: Begruessung -> (nur beim ersten Mal) Tarifwahl -> Hochschule waehlen -> (einmal je
    /// Hochschule) Anmeldeseiten der Hochschule mit Erstabgleich -> UniFlow-Oberflaeche
    enum Stage: Equatable { case welcome, planPicker, universityPicker, universityLogin, ready }

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
        /// Nutzerkennung, Name und E-Mail als ein Eintrag (JSON): ein Abbruch beim Anmelden hinterlaesst nie eine Kennung
        /// ohne Namen (Pruefbericht 513; Apple liefert Name und E-Mail nur bei der ersten Zustimmung). Bis dahin drei
        /// Eintraege `user`, `name`, `email`, die weiter gelesen werden.
        static let account = "uniflow.apple.account"
        static let secrets = [account, user, name, email]
        /// Kontodaten im Schluesselbund muessen noch weg (Neuinstallation, oder Abmelden/Loeschen liess sie stehen): bis
        /// das gelingt, gilt kein Eintrag als Anmeldung (Pruefbericht 511, 514)
        static let cleanupPending = "uniflow.account.cleanupPending"
        static let planShown = "uniflow.onboarding.planShown"
        /// gewaehlte Hochschule je Apple-Nutzer (Kurzkennung, nie die Apple-ID selbst)
        static func university(_ userID: String) -> String { "uniflow.university." + DataContainerKey.userScope(userID) }
        /// Anmeldeseiten dieser Hochschule beim ersten Start gezeigt (angemeldet oder "Später anmelden"), je Nutzer
        static func loginDone(_ userID: String, _ u: UniversityKey) -> String {
            "uniflow.onboarding.loginDone." + DataContainerKey.userScope(userID) + "." + u.rawValue
        }
        /// gesetzt beim ersten Start dieser Installation (UserDefaults verschwinden mit der App, der Schluesselbund nicht)
        static let installed = "uniflow.account.installed"
    }

    static let debugUserPrefix = "debug."
    /// feste Kennung des Debug-Kontos ohne Apple-ID (eigene Container wie ein echtes Konto)
    static let debugUserID = debugUserPrefix + "local"
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
    /// gewaehlte Hochschule des angemeldeten Nutzers; nil = noch nicht gewaehlt (Hochschulwahl)
    @Published private(set) var university: UniversityKey?
    /// Anmeldeseiten der gewaehlten Hochschule schon gezeigt (sonst `Stage.universityLogin`)
    @Published private(set) var loginDone = false
    @Published var lastError: String?
    /// einmaliger Hinweis auf der Begruessung, z. B. nach "Konto loeschen"
    @Published var notice: Notice?
    /// Nach "Konto loeschen": was sich auf diesem iPad nicht loeschen liess (Begruessung zeigt es), sonst nil
    @Published var deletionProblem: String?

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
        // Neuinstallation: alte Schluesselbund-Eintraege einer geloeschten App nicht als Anmeldung uebernehmen. Vorher
        // wurde der Merker auch gesetzt, wenn das Loeschen scheiterte; beim naechsten Start galt der alte Eintrag dann
        // als Anmeldung (511). Jetzt bleibt der Auftrag stehen, bis die Eintraege nachweislich weg sind.
        if !defaults.bool(forKey: Keys.installed) {
            defaults.set(true, forKey: Keys.cleanupPending)
            defaults.set(true, forKey: Keys.installed)
        }
        if defaults.bool(forKey: Keys.cleanupPending) {
            if Self.removeSecrets(secrets) { defaults.removeObject(forKey: Keys.cleanupPending) }
            account = nil
        } else {
            account = Self.storedAccount(secrets)
        }
        planShown = defaults.bool(forKey: Keys.planShown)
        university = account.flatMap { Self.storedUniversity($0.userID, defaults) }
        loginDone = Self.storedLoginDone(account?.userID, university, defaults)
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
        guard planShown else { return .planPicker }
        guard university != nil else { return .universityPicker }
        return loginDone ? .ready : .universityLogin
    }

    /// Container aller Daten: (Apple-Nutzer, Hochschule); nil vor Anmeldung oder Hochschulwahl
    var containerKey: DataContainerKey? {
        guard let a = account, let u = university else { return nil }
        return DataContainerKey(userID: a.userID, university: u)
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
    /// dann bleiben die gespeicherten Werte. Nimmt der Schluesselbund die Anmeldung nicht an, gilt sie nicht (vorher
    /// war man nur bis zum naechsten Start angemeldet, Pruefbericht 512).
    func signIn(userID: String, name: String?, email: String?) {
        let same = account?.userID == userID
        let next = Account(userID: userID,
                           name: Self.clean(name) ?? (same ? account?.name : nil),
                           email: Self.clean(email) ?? (same ? account?.email : nil))
        guard secrets.store(Self.encode(next), for: Keys.account) else {
            lastError = "Die Anmeldung ließ sich auf diesem iPad nicht speichern. Bitte versuche es erneut."
            return
        }
        // Eintraege von vor dem gemeinsamen Eintrag: gelten nicht mehr (der gemeinsame geht beim Lesen vor)
        for key in [Keys.user, Keys.name, Keys.email] { secrets.remove(key) }
        defaults.removeObject(forKey: Keys.cleanupPending)
        account = next
        university = Self.storedUniversity(userID, defaults)
        loginDone = Self.storedLoginDone(userID, university, defaults)
        lastError = nil
        notice = nil
        deletionProblem = nil
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

    /// Abmelden ohne Loeschen der Studiendaten; die Tarifwahl gilt fuer dieses Geraet als gezeigt. Blieb ein Eintrag
    /// im Schluesselbund stehen, gilt er beim naechsten Start nicht als Anmeldung und wird dann erneut entfernt (vorher
    /// war das Konto nach einem Neustart wieder angemeldet, Pruefbericht 514). Rueckgabe: alles entfernt.
    @discardableResult
    func signOut() -> Bool {
        let removed = Self.removeSecrets(secrets)
        if !removed { defaults.set(true, forKey: Keys.cleanupPending) }
        account = nil
        university = nil
        loginDone = false
        return removed
    }

    /// Alle Kontoeintraege entfernen (jeder wird versucht); true, wenn keiner blieb
    private static func removeSecrets(_ secrets: AccountSecretStore) -> Bool {
        Keys.secrets.map { secrets.remove($0) }.allSatisfy { $0 }
    }

    private struct StoredAccount: Codable {
        var user: String
        var name: String?
        var email: String?
    }

    private static func encode(_ a: Account) -> String {
        let data = (try? JSONEncoder().encode(StoredAccount(user: a.userID, name: a.name, email: a.email))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Gemeinsamer Eintrag, sonst die drei Eintraege von vorher
    private static func storedAccount(_ secrets: AccountSecretStore) -> Account? {
        if let raw = secrets.get(Keys.account), let s = try? JSONDecoder().decode(StoredAccount.self, from: Data(raw.utf8)), !s.user.isEmpty {
            return Account(userID: s.user, name: s.name, email: s.email)
        }
        return secrets.get(Keys.user).map { Account(userID: $0, name: secrets.get(Keys.name), email: secrets.get(Keys.email)) }
    }

    // MARK: Hochschule

    /// Hochschule waehlen (erster Start) oder wechseln (Einstellungen). Die Daten jeder Hochschule bleiben in ihrem
    /// Container; der Wechsel loescht nichts.
    func chooseUniversity(_ u: UniversityKey) {
        guard let a = account else { return }
        defaults.set(u.rawValue, forKey: Keys.university(a.userID))
        university = u
        loginDone = Self.storedLoginDone(a.userID, u, defaults)
    }

    /// nur Debug (-UFOnboarding university): Hochschulwahl erneut zeigen
    func clearUniversity() {
        guard let a = account else { return }
        defaults.removeObject(forKey: Keys.university(a.userID))
        university = nil
        loginDone = false
    }

    private static func storedUniversity(_ userID: String, _ d: UserDefaults) -> UniversityKey? {
        d.string(forKey: Keys.university(userID)).flatMap(UniversityKey.init(rawValue:))
    }

    private static func storedLoginDone(_ userID: String?, _ u: UniversityKey?, _ d: UserDefaults) -> Bool {
        guard let userID, let u else { return false }
        return d.bool(forKey: Keys.loginDone(userID, u))
    }

    // MARK: Anmeldeseiten der Hochschule (erster Start)

    /// Anmeldeseiten der gewaehlten Hochschule sind durch (angemeldet, Erstabgleich gesehen oder "Später anmelden"):
    /// ab jetzt die Oberflaeche; die bisherigen Karten "… verbinden" bleiben der Weg fuer alles Offene
    func markLoginDone() {
        guard let a = account, let u = university else { return }
        defaults.set(true, forKey: Keys.loginDone(a.userID, u))
        loginDone = true
    }

    /// nur Debug (-UFOnboarding login): die Anmeldeseiten erneut zeigen
    func resetLoginStep() {
        guard let a = account, let u = university else { return }
        defaults.removeObject(forKey: Keys.loginDone(a.userID, u))
        loginDone = false
    }

    // MARK: Tarifwahl

    func markPlanShown() {
        planShown = true
        defaults.set(true, forKey: Keys.planShown)
    }

    // MARK: Konto loeschen

    /// Richtlinie 5.1.1(v): Konto-Eintraege und Schluesselbund entfernen, zurueck zur Begruessung.
    /// Abos laufen bei Apple weiter, bis der Nutzer sie dort kuendigt (Hinweis mit `manageSubscriptionsURL`).
    /// `problems`: was die Schritte davor nicht loeschen konnten; dazu kommt ein Rest im Schluesselbund. Die Begruessung
    /// zeigt beides (`deletionProblem`) statt nur "gelöscht" (Pruefbericht 515).
    func deleteAccount(problems: [String] = []) {
        if let a = account {
            defaults.removeObject(forKey: Keys.university(a.userID))
            for u in UniversityKey.allCases { defaults.removeObject(forKey: Keys.loginDone(a.userID, u)) }
        }
        var left = problems
        if !signOut() { left.append(Self.keychainLeft) }
        planShown = false
        defaults.removeObject(forKey: Keys.planShown)
        lastError = nil
        notice = .deleted
        deletionProblem = left.isEmpty ? nil : left.joined(separator: "\n")
    }

    static let keychainLeft = "Die Anmeldung mit Apple ließ sich nicht vollständig aus dem Schlüsselbund entfernen. Sie gilt nicht mehr; beim nächsten Start versucht die App es erneut."

    /// Ganzer Ablauf "Konto loeschen" aus den Einstellungen: erst die Daten des Kontos entfernen (`deletionSteps`:
    /// alle Container des Nutzers mit Dateien, Notizen, Stud.IP-Sitzung, Webdaten und Learnweb-Schluessel; die
    /// Server-PIN), danach das Konto selbst -> Begruessung. Daten anderer Konten auf dem iPad bleiben.
    /// `beforeWelcome` laeuft direkt vor dem Wechsel zur Begruessung (Dialoge schliessen, Route zuruecksetzen).
    /// Jeder Schritt meldet, was blieb (nil = alles weg); vorher hatten die Schritte kein Ergebnis, ein Rest wurde nur
    /// ueber einen eigenen Rueckruf gemeldet, ein zweiter ueberschrieb den ersten (515).
    func deleteAccount(also steps: [() async -> String?], beforeWelcome: () -> Void = {}) async {
        deletionProblem = nil
        var problems: [String] = []
        for step in steps { if let p = await step() { problems.append(p) } }
        beforeWelcome()
        deleteAccount(problems: problems)
    }

    /// Schritte fuer `deleteAccount(also:)` in der App: alle Container dieses Nutzers (beide Hochschulen) samt
    /// Webdaten, Sitzungs-Cookies, Learnweb-Schluessel und Einstellungen loeschen, Server-PIN loeschen
    static func deletionSteps(containers: ContainerManager, session: Session, userID: String) -> [() async -> String?] {
        [{ await containers.deleteAllData(userID: userID) },
         { session.disconnect() ? nil : "Die Server-PIN ließ sich nicht aus dem Schlüsselbund entfernen." }]
    }

    #if DEBUG
    /// "Anmeldung ueberspringen (Debug)": lokales Konto ohne Apple-ID, wird beim Start nicht bei Apple geprueft
    func skipSignInForDebug() {
        signIn(userID: Self.debugUserID, name: nil, email: nil)
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
    /// Schreiben mit Ergebnis: true, wenn der Wert gespeichert ist
    func store(_ value: String, for key: String) -> Bool
    /// Entfernen mit Ergebnis: true, wenn der Eintrag danach fehlt
    @discardableResult func remove(_ key: String) -> Bool
}

extension AccountSecretStore {
    /// Speicher ohne eigenes Ergebnis (Arbeitsspeicher in Tests): schreiben und nachlesen
    func store(_ value: String, for key: String) -> Bool {
        set(value, for: key)
        return get(key) == value
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        delete(key)
        return get(key) == nil
    }
}

/// Schluesselbund ueber die vorhandenen Helfer in Session.swift; Ergebnisse aus dem Status von SecItem (ein
/// gesperrter Schluesselbund liefert beim Lesen nichts und gilt trotzdem nicht als geloescht)
struct KeychainSecretStore: AccountSecretStore {
    func get(_ key: String) -> String? { Keychain.get(key) }
    func set(_ value: String, for key: String) { Keychain.set(value, for: key) }
    func delete(_ key: String) { Keychain.delete(key) }
    func store(_ value: String, for key: String) -> Bool { Keychain.set(value, for: key) }
    @discardableResult func remove(_ key: String) -> Bool { Keychain.delete(key) }
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

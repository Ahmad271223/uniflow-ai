import AuthenticationServices
import XCTest
@testable import UniFlow

/// Ablauf "Erster Start" (docs/AUFTRAG-APPSTORE-V1.md 2a) ohne echte Apple-ID: Speicher im Arbeitsspeicher,
/// eigene UserDefaults-Suite, Pruefung bei Apple ueber einen Stellvertreter.
@MainActor
final class AccountStoreTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct FixedChecker: AppleCredentialChecking {
        var state: AppleCredentialState
        func state(forUserID id: String) async -> AppleCredentialState { state }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "uniflow.tests.account.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store(_ secrets: MemorySecrets, state: AppleCredentialState = .authorized,
                       allowsDebugAccount: Bool = true) -> AccountStore {
        AccountStore(secrets: secrets, defaults: defaults, checker: FixedChecker(state: state), observeRevocation: false,
                     allowsDebugAccount: allowsDebugAccount)
    }

    func testFirstStartShowsWelcome() {
        let s = store(MemorySecrets())
        XCTAssertNil(s.account)
        XCTAssertEqual(s.stage, .welcome)
    }

    func testSignInThenPlanPickerOnceThenReady() {
        let secrets = MemorySecrets()
        let s = store(secrets)
        s.signIn(userID: "001.abc", name: "Ada Lovelace", email: "ada@example.com")
        XCTAssertEqual(s.stage, .planPicker)
        XCTAssertEqual(secrets.values[AccountStore.Keys.user], "001.abc")
        XCTAssertEqual(secrets.values[AccountStore.Keys.name], "Ada Lovelace")
        XCTAssertEqual(secrets.values[AccountStore.Keys.email], "ada@example.com")
        s.markPlanShown()
        XCTAssertEqual(s.stage, .ready)

        // zweiter Start: direkt die Oberflaeche
        let again = store(secrets)
        XCTAssertEqual(again.account?.userID, "001.abc")
        XCTAssertEqual(again.account?.name, "Ada Lovelace")
        XCTAssertEqual(again.stage, .ready)
    }

    func testLaterSignInWithoutNameKeepsStoredValues() {
        let s = store(MemorySecrets())
        s.signIn(userID: "001.abc", name: "Ada Lovelace", email: "ada@example.com")
        s.signIn(userID: "001.abc", name: "  ", email: nil)            // Apple liefert beides nur beim ersten Mal
        XCTAssertEqual(s.account?.name, "Ada Lovelace")
        XCTAssertEqual(s.account?.email, "ada@example.com")
        s.signIn(userID: "002.other", name: nil, email: nil)          // andere Apple-ID uebernimmt nichts
        XCTAssertNil(s.account?.name)
        XCTAssertNil(s.account?.email)
    }

    func testRevokedOrNotFoundReturnsToWelcomeAndKeepsPlanFlag() async {
        for state in [AppleCredentialState.revoked, .notFound] {
            let secrets = MemorySecrets()
            let first = store(secrets)
            first.signIn(userID: "001.abc", name: "Ada", email: nil)
            first.markPlanShown()
            let s = store(secrets, state: state)
            await s.verifyCredential()
            XCTAssertEqual(s.stage, .welcome, "\(state)")
            XCTAssertEqual(s.notice, .signedOut)
            XCTAssertTrue(secrets.values.isEmpty, "Schluesselbund-Eintraege entfernt")
            XCTAssertTrue(s.planShown, "Tarifwahl erscheint nur beim ersten Mal")
        }
    }

    func testAuthorizedOrUnknownKeepsAccount() async {
        for state in [AppleCredentialState.authorized, .unknown, .transferred] {
            let secrets = MemorySecrets()
            store(secrets).signIn(userID: "001.abc", name: nil, email: nil)
            let s = store(secrets, state: state)
            await s.verifyCredential()
            XCTAssertEqual(s.account?.userID, "001.abc", "\(state)")
            XCTAssertNil(s.notice)
        }
    }

    func testDeleteAccountClearsEverythingAndShowsNotice() {
        let secrets = MemorySecrets()
        let s = store(secrets)
        s.signIn(userID: "001.abc", name: "Ada", email: "ada@example.com")
        s.markPlanShown()
        s.deleteAccount()
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertEqual(s.notice, .deleted)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: AccountStore.Keys.planShown))

        // nach erneuter Anmeldung kommt die Tarifwahl wieder
        s.signIn(userID: "001.abc", name: nil, email: nil)
        XCTAssertEqual(s.stage, .planPicker)
        XCTAssertNil(s.notice)
    }

    func testReinstallIgnoresKeychainLeftovers() {
        // Schluesselbund ueberlebt das Loeschen der App, UserDefaults nicht
        let secrets = MemorySecrets()
        secrets.values[AccountStore.Keys.user] = "001.old"
        let s = store(secrets)
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertNil(secrets.values[AccountStore.Keys.user])
        XCTAssertTrue(defaults.bool(forKey: AccountStore.Keys.installed))
    }

    func testDebugAccountIsNotCheckedWithApple() async {
        let secrets = MemorySecrets()
        store(secrets).skipSignInForDebug()
        let s = store(secrets, state: .notFound)
        XCTAssertEqual(s.account?.isDebug, true)
        await s.verifyCredential()
        XCTAssertNotNil(s.account, "Debug-Konto bleibt angemeldet")
    }

    func testDebugAccountIsDiscardedOutsideDebugBuild() {
        // Release/TestFlight ueber einem Debug-Build: Schluesselbund und Merker "installed" sind noch da
        let secrets = MemorySecrets()
        let debug = store(secrets)
        debug.skipSignInForDebug()
        debug.markPlanShown()
        let release = store(secrets, allowsDebugAccount: false)
        XCTAssertNil(release.account)
        XCTAssertEqual(release.stage, .welcome)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertFalse(release.planShown, "Tarifwahl nach der echten Anmeldung erneut zeigen")
        XCTAssertNil(release.notice)

        // ein echtes Konto bleibt auch ohne Debug-Erlaubnis angemeldet
        store(secrets).signIn(userID: "001.abc", name: nil, email: nil)
        XCTAssertEqual(store(secrets, allowsDebugAccount: false).account?.userID, "001.abc")
    }

    func testDeleteAccountRunsAllStepsAndKeepsFilesAndNotes() async throws {
        let secrets = MemorySecrets()
        let s = store(secrets)
        s.signIn(userID: "001.abc", name: "Ada", email: "ada@example.com")
        s.markPlanShown()
        // Geraeteeinstellungen und eine heruntergeladene Datei duerfen nicht verschwinden
        defaults.set("left", forKey: "uniflow.hand")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-delete-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var calls: [String] = []
        await s.deleteAccount(also: [
            { calls.append("studip:\(s.stage)") },
            { calls.append("pin:\(s.stage)") },
        ]) { calls.append("close:\(s.stage)") }

        XCTAssertEqual(calls, ["studip:ready", "pin:ready", "close:ready"], "alle Schritte vor dem Wechsel zur Begruessung")
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertEqual(s.notice, .deleted)
        XCTAssertTrue(secrets.values.isEmpty, "alle Schluesselbund-Eintraege des Kontos entfernt")
        XCTAssertFalse(defaults.bool(forKey: AccountStore.Keys.planShown))
        XCTAssertEqual(defaults.string(forKey: "uniflow.hand"), "left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Startargumente (DebugLaunch.prepare)

    func testPrepareReset() {
        let secrets = MemorySecrets()
        let s = store(secrets)
        s.signIn(userID: "001.abc", name: nil, email: nil)
        s.markPlanShown()
        defaults.set("reset", forKey: "UFOnboarding")
        DebugLaunch.prepare(account: s, defaults: defaults)
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertNil(s.notice, "kein Hinweis \"Konto geloescht\" nach -UFOnboarding reset")
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testPrepareSkipKeepsExistingAccount() {
        let s = store(MemorySecrets())
        defaults.set("skip", forKey: "UFOnboarding")
        DebugLaunch.prepare(account: s, defaults: defaults)
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(s.account?.isDebug, true)

        let real = store(MemorySecrets())
        real.signIn(userID: "001.abc", name: nil, email: nil)
        DebugLaunch.prepare(account: real, defaults: defaults)
        XCTAssertEqual(real.account?.userID, "001.abc")
        XCTAssertEqual(real.stage, .ready)
    }

    func testPreparePlanShowsPlanPicker() {
        let s = store(MemorySecrets())
        s.signIn(userID: "001.abc", name: nil, email: nil)
        s.markPlanShown()
        defaults.set("plan", forKey: "UFOnboarding")
        DebugLaunch.prepare(account: s, defaults: defaults)
        XCTAssertEqual(s.stage, .planPicker)
        XCTAssertEqual(s.account?.isDebug, true)
        XCTAssertNil(s.notice)
    }

    func testPrepareSkipsForOldScreenshotArguments() {
        for key in DebugLaunch.skipTriggers {
            let suiteName = "\(suite).\(key)"
            let d = UserDefaults(suiteName: suiteName)!
            defer { d.removePersistentDomain(forName: suiteName) }
            d.set(key == "UFDisconnect" ? "YES" : "#/settings?tab=dev", forKey: key)
            let s = AccountStore(secrets: MemorySecrets(), defaults: d, checker: FixedChecker(state: .authorized),
                                 observeRevocation: false)
            DebugLaunch.prepare(account: s, defaults: d)
            XCTAssertEqual(s.stage, .ready, key)
        }
        XCTAssertTrue(DebugLaunch.skipTriggers.contains("UFDisconnect"))
    }

    func testPrepareWithoutArgumentsChangesNothing() {
        let s = store(MemorySecrets())
        DebugLaunch.prepare(account: s, defaults: defaults)
        XCTAssertEqual(s.stage, .welcome)
        XCTAssertNil(s.account)
    }

    func testCancelIsNoError() {
        XCTAssertNil(AccountStore.message(for: ASAuthorizationError(.canceled)))
        XCTAssertNotNil(AccountStore.message(for: ASAuthorizationError(.failed)))
        XCTAssertNotNil(AccountStore.message(for: ASAuthorizationError(.unknown)))
    }

    func testUnknownErrorMentionsBuildOnlyInDebug() throws {
        let debug = try XCTUnwrap(AccountStore.message(for: ASAuthorizationError(.unknown), debugBuild: true))
        let release = try XCTUnwrap(AccountStore.message(for: ASAuthorizationError(.unknown), debugBuild: false))
        XCTAssertTrue(debug.contains("Build"))
        XCTAssertFalse(release.contains("Build"))
        XCTAssertTrue(release.contains("Apple-ID"))
    }

    func testRequestAsksForNameAndEmail() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        AccountStore.configure(request)
        XCTAssertEqual(Set(request.requestedScopes ?? []), [.fullName, .email])
    }
}

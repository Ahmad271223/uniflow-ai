import Foundation
import Security
import UIKit
import UniFlowCore
import WebKit

// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, ersetzt die vom 03.11.2026; docs/AUTOMATISCH-ANMELDEN-
// 2026-11-06.md). Nach der ersten Anmeldung fragt die App nie wieder nach dem Passwort, solange die Hochschule es
// annimmt: Stud.IP (WebSSO), QIS, Uni-Mail (SOGo), Learnweb/LSF/PLuS (CAS), Moodle und Campusmanagement (HsH).
//
// - Merken nur mit Zustimmung (Schalter "Passwort auf diesem iPad merken" unter jeder Anmeldeseite, Vorgabe an; in den
//   Einstellungen "Automatisch anmelden"): ein Eintrag je Container (Apple-Nutzer + Hochschule) im Schluesselbund,
//   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false` (nie iCloud, nie ein anderes
//   Geraet, nicht im Backup). Eine Zugangskennung je Hochschule fuer alle ihre Dienste (LUH-ID, UNI-Account, SSO-Account).
// - Mitgelesen wird nur, was der Mensch selbst in das echte Anmeldeformular tippt und absendet: kleines Skript in eigener
//   Inhaltswelt, nur im Hauptrahmen, nur auf den Formular-Rechnern der eigenen Hochschule (`UniLoginForms`). Gespeichert
//   wird erst, wenn die Anmeldung gelungen ist (`signedIn`); vorher liegt es hoechstens 15 Minuten im Arbeitsspeicher.
// - Eingesetzt wird es nur in einer unsichtbaren Webansicht mit dem Datenspeicher des Containers, nur auf diesen
//   Formular-Rechnern (das Skript prueft Rechner und Pfad selbst noch einmal); jede Weiterleitung auf einen fremden
//   Rechner bricht ab. Das Passwort geht nie an StudiNow-Server, steht nie in einem Skript-Quelltext, nie im Protokoll.
// - Abmelden, "Daten dieser Hochschule löschen", "Konto löschen" und "Gespeichertes Passwort löschen" entfernen den
//   Eintrag. Lehnt die Hochschule das Passwort ab, loescht die App nichts von selbst: "Anmeldung nötig", der Mensch
//   meldet sich neu an (das neue Passwort ersetzt das alte).

/// Gemerkte Zugangsdaten einer Hochschule (nur im Schluesselbund dieses Geraets)
struct UniCredential: Codable, Equatable, Sendable {
    let username: String
    let password: String
    let savedAt: Date
}

/// Eintrag im Schluesselbund je Container (`uni-login.<container-uuid>` im Dienst `de.uniflow.ai.uni-login`)
struct UniCredentialStore: Sendable {
    static let service = "de.uniflow.ai.uni-login"
    static let accountPrefix = "uni-login."

    let store: KeychainStore
    let account: String

    init(service: String = UniCredentialStore.service, container: UUID) {
        store = KeychainStore(service: service, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        account = Self.accountPrefix + container.uuidString
    }

    func load() -> UniCredential? {
        guard let d = store.data(account), let c = try? JSONDecoder().decode(UniCredential.self, from: d),
              UniLoginForms.isAcceptableUsername(c.username), UniLoginForms.isAcceptablePassword(c.password) else { return nil }
        return c
    }

    func save(_ c: UniCredential) throws { try store.write(try JSONEncoder().encode(c), account: account) }

    @discardableResult
    func clear() -> Bool { store.remove(account) }

    /// Schutzklasse und Synchronisation (Tests)
    func attributes() -> (accessible: String?, synchronizable: Bool?)? { store.attributes(account) }
}

/// Anfrage an die unsichtbare Webansicht
struct UniAutoLoginRequest {
    /// Dienst ("studip", "qis", "sogo", "learnweb", "lsf", "moodle", "campus")
    let portal: String
    let university: UniversityKey
    let store: WKWebsiteDataStore
    /// Seite, die die Anmeldung beginnt (Startseite des Dienstes bzw. Einstieg ins SSO)
    let entry: URL
    let credential: UniCredential
    /// Erfolgsseite des Dienstes (z. B. QIS mit Abmelden-Link)
    let isDone: @MainActor (URL, String) async -> Bool
    var timeout: TimeInterval = 30
}

@MainActor
enum UniAutoLogin {
    /// Schalter je Container ("Automatisch anmelden"); fehlt er, gilt an (Vorgabe des Inhabers)
    static let enabledKey = "uniflow.autologin.enabled"
    static let handlerName = "studinowCredential"
    static let world = WKContentWorld.world(name: "studinow-credential")
    /// mitgelesene, noch nicht bestaetigte Anmeldung verfaellt nach dieser Zeit
    static let pendingLifetime: TimeInterval = 15 * 60

    /// Tests: unsichtbare Webansicht ersetzen bzw. Vordergrund vorgeben (sonst nie unter XCTest, nie mit dem Debug-Stub)
    static var runnerOverride: ((UniAutoLoginRequest) async -> UniAutoLoginOutcome)?
    static var appActiveOverride: Bool?
    /// Zahl der Anfragen an die unsichtbare Webansicht (Tests)
    private(set) static var attempts = 0

    final class Entry {
        weak var store: WKWebsiteDataStore?
        let university: UniversityKey
        let defaults: UserDefaults
        let vault: UniCredentialStore
        var pending: (credential: UniCredential, at: Date)?
        var states: [String: UniAutoLoginState] = [:]
        /// die Hochschule hat das gespeicherte Passwort abgelehnt (fuer alle Dienste, eine Zugangskennung)
        var rejected = false
        var running: [String: Task<UniAutoLoginDecision, Never>] = [:]
        /// nie zwei unsichtbare Anmeldungen zugleich im selben Datenspeicher
        var tail: Task<Void, Never>?
        init(store: WKWebsiteDataStore, university: UniversityKey, defaults: UserDefaults, vault: UniCredentialStore) {
            self.store = store
            self.university = university
            self.defaults = defaults
            self.vault = vault
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func entry(_ store: WKWebsiteDataStore) -> Entry? {
        guard let e = entries[ObjectIdentifier(store)], e.store === store else { return nil }
        return e
    }

    /// Datenspeicher eines Containers anmelden (`ContainerManager.websiteDataStore`)
    static func attach(_ store: WKWebsiteDataStore, university: UniversityKey, defaults: UserDefaults, vault: UniCredentialStore) {
        guard entry(store) == nil else { return }
        entries = entries.filter { $0.value.store != nil }
        entries[ObjectIdentifier(store)] = Entry(store: store, university: university, defaults: defaults, vault: vault)
    }

    static func detach(_ store: WKWebsiteDataStore) { entries.removeValue(forKey: ObjectIdentifier(store)) }

    // MARK: Schalter und Anzeige

    static func isEnabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    static func isEnabled(_ store: WKWebsiteDataStore) -> Bool { entry(store).map { isEnabled($0.defaults) } ?? false }

    /// Schalter: aus loescht das gespeicherte Passwort gleich mit (aus heisst: kein Passwort auf dem Geraet)
    static func setEnabled(_ on: Bool, store: WKWebsiteDataStore) {
        guard let e = entry(store) else { return }
        e.defaults.set(on, forKey: enabledKey)
        if !on { forget(store) }
    }

    /// Gespeichertes Passwort (nur mit Schalter an)
    static func credential(_ store: WKWebsiteDataStore) -> UniCredential? {
        guard let e = entry(store), isEnabled(e.defaults) else { return nil }
        return e.vault.load()
    }

    /// Benutzername des gespeicherten Eintrags (Einstellungen)
    static func storedUsername(_ store: WKWebsiteDataStore) -> String? { entry(store)?.vault.load()?.username }

    /// Hat die Hochschule das gespeicherte Passwort abgelehnt? (Einstellungen: "Passwort abgelehnt, bitte neu anmelden")
    static func wasRejected(_ store: WKWebsiteDataStore) -> Bool { entry(store)?.rejected ?? false }

    // MARK: Mitlesen und Speichern

    /// Meldung des Mitleseskripts (schon geprueft: eigene Welt, Hauptrahmen, Formular-Rechner der Hochschule)
    static func captured(_ store: WKWebsiteDataStore, user: String, password: String, now: Date = Date()) {
        guard let e = entry(store), isEnabled(e.defaults) else { return }
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UniLoginForms.isAcceptableUsername(u), UniLoginForms.isAcceptablePassword(password) else { return }
        e.pending = (UniCredential(username: u, password: password, savedAt: now), now)
    }

    /// Die Anmeldung ist gelungen (Anmeldeansicht hat die angemeldete Seite erkannt): mitgelesenes Passwort jetzt in den
    /// Schluesselbund. Ohne frisch Mitgelesenes (stille Anmeldung, Cookie noch gueltig) aendert sich nichts.
    @discardableResult
    static func signedIn(_ store: WKWebsiteDataStore, now: Date = Date()) -> Bool {
        guard let e = entry(store), let p = e.pending else { return false }
        e.pending = nil
        guard isEnabled(e.defaults), now.timeIntervalSince(p.at) < pendingLifetime else { return false }
        guard (try? e.vault.save(p.credential)) != nil else { return false }
        e.rejected = false
        e.states = [:]
        return true
    }

    // MARK: Von Hand speichern (Einstellungen)

    /// Ergebnis von `saveTyped`
    enum TypedSave: Equatable {
        case saved
        /// kein Datenspeicher eines Containers (niemand angemeldet)
        case unavailable
        case badUsername
        case badPassword
        /// der Schluesselbund hat nicht geschrieben
        case failed
    }

    /// Einstellungen, "Uni-Zugang einmal speichern" (Entscheidung des Inhabers 10.11.2026): Benutzername und Passwort,
    /// die der Mensch dort selbst eintippt, kommen in denselben Eintrag im Schluesselbund dieses Geraets wie nach einer
    /// Anmeldung auf der Anmeldeseite. Speichern heisst zustimmen: der Schalter geht an. Ob das Passwort stimmt,
    /// entscheidet erst die Hochschule (`ContainerManager.connectWithStoredLogin`).
    static func saveTyped(username: String, password: String, store: WKWebsiteDataStore, now: Date = Date()) -> TypedSave {
        guard let e = entry(store) else { return .unavailable }
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UniLoginForms.isAcceptableUsername(u) else { return .badUsername }
        guard UniLoginForms.isAcceptablePassword(password) else { return .badPassword }
        guard (try? e.vault.save(UniCredential(username: u, password: password, savedAt: now))) != nil else { return .failed }
        e.defaults.set(true, forKey: enabledKey)
        e.pending = nil
        e.rejected = false
        e.states = [:]
        return .saved
    }

    /// Abmelden, Schalter aus, "Gespeichertes Passwort löschen": Eintrag weg, nichts Mitgelesenes mehr
    @discardableResult
    static func forget(_ store: WKWebsiteDataStore) -> Bool {
        guard let e = entry(store) else { return true }
        e.pending = nil
        e.rejected = false
        e.states = [:]
        return e.vault.clear()
    }

    // MARK: Stille Anmeldung

    static var appActive: Bool { appActiveOverride ?? (UIApplication.shared.applicationState == .active) }

    /// Unsichtbare Anmeldung moeglich: Ersatz in Tests, sonst nie unter XCTest und nie mit der Debug-Nachbildung
    static var liveAllowed: Bool { runnerOverride != nil || (!StudIPSync.isUnderTest() && !DebugUniStub.isActive) }

    /// Eine Quelle meldet "abgelaufen". Rueckgabe `.retryOnce`: still angemeldet, der Aufrufer wiederholt genau einmal;
    /// sonst bleibt es bei "Anmeldung nötig" (`UniAutoLoginMachine`).
    static func handleExpiry(portal: String, store: WKWebsiteDataStore, entry url: URL, userAction: Bool = false,
                             isDone: @escaping @MainActor (URL, String) async -> Bool) async -> UniAutoLoginDecision {
        guard let e = entry(store), liveAllowed else { return .needsUser }
        if let running = e.running[portal] { return await running.value }
        let cred = credential(store)
        var st = e.states[portal] ?? UniAutoLoginState()
        let d = UniAutoLoginMachine.expired(&st, enabled: isEnabled(e.defaults), hasCredential: cred != nil && !e.rejected,
                                            appActive: appActive, signingOut: false, userAction: userAction, now: Date())
        e.states[portal] = st
        guard d == .relogin, let cred else { return d }
        let previous = e.tail
        let task = Task { @MainActor () -> UniAutoLoginDecision in
            await previous?.value
            // inzwischen abgemeldet oder Passwort geloescht: nichts tun
            guard let now = credential(store), now == cred else { return .needsUser }
            attempts += 1
            let request = UniAutoLoginRequest(portal: portal, university: e.university, store: store, entry: url, credential: cred, isDone: isDone)
            let outcome: UniAutoLoginOutcome
            if let runner = runnerOverride { outcome = await runner(request) } else { outcome = await UniAutoLoginWeb.attempt(request) }
            let still = credential(store) == cred
            var s2 = e.states[portal] ?? UniAutoLoginState()
            let d2 = UniAutoLoginMachine.finished(&s2, outcome, signingOut: !still)
            e.states[portal] = s2
            if outcome == .wrongPassword, still { e.rejected = true }
            if d2 == .retryOnce { await UniWebSessions.save(store) }      // neue Sitzung ueber Neustarts merken
            return d2
        }
        e.running[portal] = task
        e.tail = Task { _ = await task.value }
        let r = await task.value
        e.running[portal] = nil
        return r
    }

    /// Die Wiederholung nach der stillen Anmeldung (oder sonst eine Anfrage) ist gelungen
    static func succeeded(portal: String, store: WKWebsiteDataStore) {
        guard let e = entry(store), var s = e.states[portal] else { return }
        UniAutoLoginMachine.succeeded(&s)
        e.states[portal] = s
    }

    /// Stand einer Quelle (Tests)
    static func state(portal: String, store: WKWebsiteDataStore) -> UniAutoLoginState? { entry(store)?.states[portal] }
}

// MARK: - Mitlesen auf der Anmeldeseite

/// Kanal des Mitleseskripts (`UniLoginForms.captureScript`): eigene Inhaltswelt, nur Hauptrahmen, nur Formular-Rechner
/// der Hochschule des Containers. Die Seite sieht weder Skript noch Kanal.
@MainActor
final class UniCredentialCapture: NSObject, WKScriptMessageHandler {
    let store: WKWebsiteDataStore
    let university: UniversityKey

    init(store: WKWebsiteDataStore, university: UniversityKey) {
        self.store = store
        self.university = university
    }

    /// In die Konfiguration einer Anmeldeansicht, nur fuer Datenspeicher eines Containers (der Schalter unter der Seite
    /// laesst sich noch vor dem Absenden umlegen: mit "aus" verwirft `UniAutoLogin.captured` die Meldung).
    /// Rueckgabe: eingerichtet.
    @discardableResult
    static func install(in config: WKWebViewConfiguration, dataStore: WKWebsiteDataStore) -> Bool {
        guard let e = UniAutoLogin.entry(dataStore) else { return false }
        let capture = UniCredentialCapture(store: dataStore, university: e.university)
        let source = UniLoginForms.captureScript(university: e.university, handler: UniAutoLogin.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                                                in: UniAutoLogin.world))
        config.userContentController.add(capture, contentWorld: UniAutoLogin.world, name: UniAutoLogin.handlerName)
        return true
    }

    /// Prueft eine Meldung (rein, testbar): Welt, Hauptrahmen, Herkunft und Adresse des Rahmens auf einem Formular der
    /// Hochschule, Felder als Text
    nonisolated static func accept(world: Bool, mainFrame: Bool, scheme: String, host: String, port: Int, frameURL: URL?,
                                   body: Any, university: UniversityKey) -> (user: String, password: String)? {
        guard world, mainFrame, let frameURL, let c = URLComponents(url: frameURL, resolvingAgainstBaseURL: false),
              c.host?.lowercased() == host.lowercased(),
              UniLoginForms.allowsCapture(scheme: scheme, host: host, port: port, path: c.percentEncodedPath, university: university),
              UniLoginForms.form(for: frameURL, university: university) != nil,
              let dict = body as? [String: Any], let u = dict["user"] as? String, let p = dict["pass"] as? String else { return nil }
        return (u, p)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard let v = Self.accept(world: message.world == UniAutoLogin.world, mainFrame: message.frameInfo.isMainFrame,
                                  scheme: origin.protocol, host: origin.host, port: origin.port, frameURL: message.frameInfo.request.url,
                                  body: message.body, university: university) else { return }
        UniAutoLogin.captured(store, user: v.user, password: v.password)
    }
}

// MARK: - Unsichtbare Webansicht

/// Stille Anmeldung: sehr kleine, durchsichtige Webansicht im Fenster (wie `StudIPSilentLogin`) mit der Konfiguration
/// der Anmeldeansicht (Datenspeicher des Containers, kein Mitleseskript). Auf einem Formular der Hochschule fuellt sie
/// Benutzername und Passwort ein (`UniLoginForms.fillFunctionBody`, Passwort als Argument) und sendet ab - jedes
/// Formular hoechstens einmal; erscheint es danach wieder, hat die Hochschule das Passwort abgelehnt. Eine Navigation
/// des Hauptrahmens auf einen Rechner ausserhalb der Hochschule (oder http) wird abgebrochen.
@MainActor
enum UniAutoLoginWeb {
    private final class Delegate: NSObject, WKNavigationDelegate {
        let domains: [String]
        var finished = 0
        var blocked = false
        var failed = false
        init(domains: [String]) { self.domains = domains }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame != false, !UniAutoLoginFlow.allowed(navigationAction.request.url, domains: domains) {
                blocked = true
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if UFWebLoadState.message(for: error) != nil { failed = true }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if UFWebLoadState.message(for: error) != nil { failed = true }
        }
    }

    static func attempt(_ r: UniAutoLoginRequest) async -> UniAutoLoginOutcome {
        await UniWebSessions.ready(r.store)
        let domains = UniWebSessions.domains(r.university)
        guard UniAutoLoginFlow.allowed(r.entry, domains: domains),
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return .failed }
        let delegate = Delegate(domains: domains)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: StudIPWebView.loginConfiguration(dataStore: r.store))
        web.navigationDelegate = delegate
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true
        window.addSubview(web)
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
        web.load(URLRequest(url: r.entry))
        let deadline = Date().addingTimeInterval(r.timeout)
        var handled = 0
        var submitted: [String] = []
        var stable: (url: URL, since: Date)?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if delegate.blocked { return .blocked }
            if delegate.failed { return .failed }
            guard !web.isLoading, let u = web.url else { continue }
            if delegate.finished > handled {
                handled = delegate.finished
                let html = await outerHTML(web)
                let done = await r.isDone(u, html)
                switch UniAutoLoginFlow.step(url: u, html: html, university: r.university, domains: domains, submitted: submitted, isDone: done) {
                case .done: return .success
                case .abort: return .blocked
                case .rejected: return .wrongPassword
                case .fill(let form):
                    var result = await fill(web, form: form, credential: r.credential)
                    // HISinOne: "Zur Anmeldung" blendet das Formular per Ajax ein (ohne neue Seite): kurz warten, nochmals
                    if result == "opened" {
                        for _ in 0..<8 where result == "opened" || result == "nofield" {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            result = await fill(web, form: form, credential: r.credential)
                        }
                    }
                    switch result {
                    case "submitted":
                        submitted.append(form.id)
                        stable = nil
                    case "host": return .blocked
                    default: break                                 // Formular nicht sichtbar: weiter warten
                    }
                case .wait: break
                }
            }
            if stable?.url != u { stable = (u, Date()); continue }
            // ohne Fortschritt: Seite steht (z. B. Zwischenseite, die einen Klick braucht). Steht nach dem eigenen
            // Absenden noch dasselbe Formular da (SOGo meldet Fehler ohne neue Seite), gilt das Passwort als abgelehnt:
            // nie ein zweites Mal damit (Sperre des Kontos nach Fehlversuchen)
            if Date().timeIntervalSince(stable?.since ?? Date()) > 8 {
                if let form = UniLoginForms.form(for: u, university: r.university), submitted.contains(form.id),
                   form.appears(in: await outerHTML(web)) { return .wrongPassword }
                return .failed
            }
        }
        return .failed
    }

    static func outerHTML(_ web: WKWebView) async -> String {
        await withCheckedContinuation { done in
            web.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
                done.resume(returning: (try? result.get()) as? String ?? "")
            }
        }
    }

    /// Einfuellen und Absenden in eigener Inhaltswelt; das Passwort kommt als Argument, nie in den Quelltext
    static func fill(_ web: WKWebView, form: UniLoginForm, credential: UniCredential) async -> String {
        guard form.matches(web.url) else { return "host" }
        let args: [String: Any] = ["spec": form.spec, "user": credential.username, "pass": credential.password]
        let r = try? await web.callAsyncJavaScript(UniLoginForms.fillFunctionBody, arguments: args, in: nil, contentWorld: UniAutoLogin.world)
        return (r as? String) ?? "nofield"
    }
}
